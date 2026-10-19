@tool
class_name GodotiteValidator
extends RefCounted

## Checks a built [GodotiteDAG] for correctness, and reports PASS or FAIL.
##
## What the Validate DAG button on a [GodotiteLOD] runs; [method validate] returns the report. The
## checks: the hierarchy's structure; that error never decreases towards the root; that every
## selection from a range of thresholds and view points draws each part of the mesh exactly once;
## that the three ways of selecting agree; that incremental selection does not drift; and that no
## selection leaves cracks between clusters. [br][br]
##
## Everything works from the GodotiteDAG resource and the cluster meshes alone, with no builder
## state, so validation runs after a scene reload as well as straight after a build.

# These existed as throwaway scripts written fresh for each phase, and every one of them was thrown
# away afterwards. That cost real time: **four separate metrics in this project measured the wrong
# thing** and each was only caught by writing another ad hoc script to cross-check the first.
#
#   * Phase 4  - `boundary/triangle` falls on its own as clusters shrink, so it "proved" the DAG
#                change made things worse when it had not.
#   * Phase 4.5- the link condition was blamed for intersecting faces; measured, it prevented one
#                non-manifold edge in 99,000 triangles.
#   * Phase 5  - `covers N/N` was a set test and could not see the same surface drawn twice.
#   * Phase 5  - leaf-multiplicity counting double-counts, because `children` is a dependency
#                relation and the two clusters of a group share all of it.
#
# The lesson each time was the same: one metric is not evidence. So the structural checks here are
# deliberately redundant with each other, and the cut is verified by two independent selectors that
# must agree.


# Tolerance for comparing positions and errors.
const _EPSILON := 1e-4

# Thresholds and view distances swept by the cut checks. Spread over orders of magnitude, because
# bugs here show up at the extremes - all-root and all-leaf - far more readily than in the middle.
const _SWEEP_THRESHOLDS: Array[float] = [ 5.0, 20.0, 60.0, 120.0, 300.0, 1000.0, 5000.0 ]
# View distances swept by the cut checks, as multiples of the root's radius from its centre.
const _SWEEP_DISTANCE_FACTORS: Array[float] = [ 0.0, 0.3, 0.7, 0.95, 1.5, 4.0 ]

# Thresholds swept by the crack check specifically, which is far more expensive than the other cut
# checks: it assembles and welds every drawn triangle, so cost scales with the geometry on screen
# rather than with the cluster count. Four thresholds spanning the same range still put every cut
# between all-leaf and all-root through the test.
const _CRACK_SWEEP_THRESHOLDS: Array[float] = [ 5.0, 60.0, 300.0, 5000.0 ]

# The camera scale every cut check runs at — the sweeps as well as the selector paths.
#
# Not 1.0, which is what they used and which makes them vacuous: projected error is
# `error / distance * scale`, so at scale 1 a mesh whose errors are small in its own units never
# exceeds any threshold, the cut sits at the root for the whole path, and "incremental agrees with
# descent" is satisfied by a selector that does nothing at all. The existing check reported "0 of
# them changed the cut" for exactly that reason, which read as reassurance. The sweeps had the
# same flaw until later: on the terrain every one of 42 cuts drew the root alone, and "no cracks"
# was checking a single cluster.
const _SelectorMeasure := preload("res://addons/godotite/tools/godotite_measure.gd")


## Runs every check on a LOD's DAG and returns the report, headed PASS or FAIL. [param deep] adds a
## report on the cluster geometry.
static func validate(lod: GodotiteLOD, deep: bool = true) -> String:
	if lod == null or lod.dag == null or not lod.dag.is_valid():
		return "FAIL: no valid DAG assigned."
	var lines := PackedStringArray()
	var failures := 0
	for step in _steps(deep):
		failures += step[1].call(lod, lines)
	return _verdict(failures, lines)


## [method validate], one check per frame, so the editor keeps drawing; await it. [param progress],
## if given, is called with a line before each check, and after any check that took over a second
## with how long it took.
static func validate_async(lod: GodotiteLOD, deep: bool = true,
		progress: Callable = Callable()) -> String:
	if lod == null or lod.dag == null or not lod.dag.is_valid():
		return "FAIL: no valid DAG assigned."
	var lines := PackedStringArray()
	var failures := 0
	var steps := _steps(deep)
	for i in steps.size():
		if progress.is_valid():
			progress.call("%s (%d of %d)..." % [ steps[i][0], i + 1, steps.size() ])
		# A frame before the check, not only after: a check runs in one go on the main thread, so
		# without it the line just printed would only show once the check had finished.
		await Engine.get_main_loop().process_frame
		var started := Time.get_ticks_msec()
		failures += steps[i][1].call(lod, lines)
		var seconds := (Time.get_ticks_msec() - started) / 1000.0
		if progress.is_valid() and seconds >= 1.0:
			progress.call("%s took %.1f s" % [ steps[i][0], seconds ])
	return _verdict(failures, lines)


# Every check, by name, each returning its failure count; the geometry report counts none.
static func _steps(deep: bool) -> Array:
	var steps := [
		[ "structure", _check_structure ],
		[ "monotonicity", _check_monotonicity ],
		[ "cut validity", _check_cut_validity ],
		[ "selector agreement", _check_selectors_agree ],
		[ "incremental selector", _check_incremental_agrees ],
		[ "incremental drift", _check_incremental_drift ],
		[ "no cracks", _check_no_cracks ],
	]
	if deep:
		steps.append([ "geometry report", _report_geometry ])
	return steps


static func _verdict(failures: int, lines: PackedStringArray) -> String:
	var header := "PASS - all checks clean" if failures == 0 else "FAIL - %d check(s) failed" % failures
	return header + "\n" + "\n".join(lines)


# --- the incremental selector does not DRIFT over many small steps ---
#
# _check_incremental_agrees() calls select_cut() between every step, which resets the incremental
# state — so it only ever tests one step from a freshly descended cut, and cannot see an error that
# accumulates. It also jumps a full orbit in 24 steps, so the per-frame travel is always large.
#
# Both of those hid a real bug: camera travel was being spent against the cut's slack FLOOR on
# skipped frames but not against the per-cluster budgets, so after enough small steps every cluster
# looked like it still had credit, the cut stopped updating, and nodes froze at one cluster however
# close the camera came. Found by flying, not by validation.
#
# So this drives the same path twice instead — once incrementally, letting the state build up over
# many fine steps, and once by descent — and compares the two sequences of cuts. Steps are small
# enough that most of them are expected to change nothing, which is the case that was broken.
static func _check_incremental_drift(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var problems: PackedStringArray = PackedStringArray()
	var saved_threshold := lod.error_threshold
	var scale := _SelectorMeasure.reference_screen_scale()
	const STEPS := 160
	var skipped := 0
	var flips := 0

	for threshold in [ 20.0, 120.0 ]:
		lod.error_threshold = threshold
		var points: Array[Vector3] = []
		for step in range(STEPS):
			# A slow spiral inward: small movement per step, and a steady approach so slack is
			# genuinely consumed rather than oscillating about a fixed distance.
			var t := float(step) / float(STEPS - 1)
			points.append(_orbit_point(lod, t * 0.35, 1.5 - 1.1 * t))

		lod.select_cut(points[0], 1.0)
		var incremental: PackedStringArray = PackedStringArray()
		for step in range(STEPS):
			lod.select_cut_incremental(points[step], scale)
			incremental.append(_cut_bits(lod))
			if lod.last_visited == 0:
				skipped += 1

		var expected: PackedStringArray = PackedStringArray()
		for step in range(STEPS):
			lod.select_cut(points[step], scale)
			expected.append(_cut_bits(lod))
			if step > 0 and expected[step] != expected[step - 1]:
				flips += 1

		for step in range(STEPS):
			if incremental[step] != expected[step]:
				problems.append("threshold %.0f step %d of %d: incremental drew %d clusters, descent %d"
						% [ threshold, step, STEPS, incremental[step].count("1"),
							expected[step].count("1") ])
				break

	# A path whose correct cut never changes cannot distinguish a working selector from a frozen one,
	# so silence here would be meaningless rather than reassuring. Fail loudly instead.
	if flips < 4:
		problems.append(("the reference cut changed only %d times over %d steps, so this path "
				+ "cannot tell a working incremental selector from one that stopped updating")
				% [ flips, STEPS * 2 ])

	lod.error_threshold = saved_threshold
	_section(lines, "incremental drift", problems,
			"no drift over %d accumulated steps on 2 paths (%d needed no work, cut changed %d times)"
			% [ STEPS * 2, skipped, flips ])
	return 1 if problems.size() > 0 else 0


# --- the incremental selector agrees with the descent ---
#
# select_cut_incremental() updates the previous frame's cut instead of rebuilding it, and it skips
# any cluster whose stored slack says it cannot have flipped yet. Both are exactly the kind of
# optimisation that produces a *nearly* right answer, and a nearly right cut is a hole or a
# double-drawn surface. So it is driven along a continuous path here, the way a camera would move,
# and compared against a from-scratch descent at every step.
#
# Continuity is the point: a single view point would test nothing, since the first call with no
# usable cut simply delegates to select_cut() and would agree trivially.
static func _check_incremental_agrees(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var problems: PackedStringArray = PackedStringArray()
	var saved_threshold := lod.error_threshold
	var scale := _SelectorMeasure.reference_screen_scale()
	var steps := 0
	var flips := 0

	for threshold in [ 20.0, 120.0 ]:
		lod.error_threshold = threshold
		for orbit in [ 0.35, 1.4 ]:  # inside the mesh, then well outside it
			# Seed a cut, then move in small increments so each step is a genuine update.
			lod.select_cut(_orbit_point(lod, 0.0, orbit), scale)
			var previous := _cut_bits(lod)
			for step in range(1, 24):
				var point := _orbit_point(lod, float(step) / 24.0, orbit)
				lod.select_cut_incremental(point, scale)
				var incremental := _cut_bits(lod)
				lod.select_cut(point, scale)
				var expected := _cut_bits(lod)
				steps += 1
				if incremental != previous:
					flips += 1
				if incremental != expected:
					problems.append("threshold %.0f orbit %.2f step %d: incremental drew %d clusters, descent %d"
							% [ threshold, orbit, step, incremental.count("1"),
								expected.count("1") ])
				# Restore the incremental state so one divergence cannot mask every later step.
				lod.select_cut_incremental(point, scale)
				previous = _cut_bits(lod)

	lod.error_threshold = saved_threshold
	_section(lines, "incremental selector", problems,
			"matches the descent at all %d steps along 4 camera paths (%d of them changed the cut)"
			% [ steps, flips ])
	return 1 if problems.size() > 0 else 0


# A point orbiting THIS node, in world space.
#
# It used to orbit the world origin at a radius taken from the DAG, which is only the same thing
# when the node sits at the origin unscaled — true of the authoring scene and false of any imported
# instance. A grid tile at (-4912, 0, -4912) with scale 700 was being orbited from thousands of
# units away, so every cut on the path was the root and the selector checks proved nothing.
#
# `distance` is a multiple of the node's own world-space radius, so callers stay scale-free.
static func _orbit_point(lod: GodotiteLOD, t: float, distance: float) -> Vector3:
	var dag := lod.dag
	var centre: Vector3 = lod.global_transform * dag.lod_centers[dag.root_index]
	var basis_scale := lod.global_transform.basis.get_scale()
	var radius: float = maxf(dag.lod_radii[dag.root_index], 1e-6) \
			* maxf(basis_scale.x, maxf(basis_scale.y, basis_scale.z))
	return centre + Vector3(cos(t * TAU), 0.25, sin(t * TAU)) * radius * distance


static func _cut_bits(lod: GodotiteLOD) -> String:
	var bits := PackedByteArray()
	bits.resize(lod.dag.cluster_count)
	for index in range(lod.dag.cluster_count):
		bits[index] = 49 if lod.is_drawn(index) else 48
	return bits.get_string_from_ascii()


# --- structural integrity of the packed resource ---
#
# Cheap, and catches packing mistakes that would otherwise show up much later as a wrong cut.
static func _check_structure(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var dag := lod.dag
	var problems: PackedStringArray = PackedStringArray()
	var count := dag.cluster_count

	for pair in [ [ dag.levels.size(), "levels" ], [ dag.errors.size(), "errors" ],
			[ dag.triangle_counts.size(), "triangle_counts" ],
			[ dag.lod_centers.size(), "lod_centers" ], [ dag.lod_radii.size(), "lod_radii" ],
			[ dag.parent_errors.size(), "parent_errors" ],
			[ dag.parent_centers.size(), "parent_centers" ],
			[ dag.parent_radii.size(), "parent_radii" ],
			[ dag.child_offsets.size(), "child_offsets" ],
			[ dag.child_counts.size(), "child_counts" ] ]:
		if pair[0] != count:
			problems.append("%s has %d entries, expected %d" % [ pair[1], pair[0], count ])

	var expected_offset := 0
	for index in range(count):
		if dag.child_offsets[index] != expected_offset:
			problems.append("child_offsets[%d] = %d, expected %d" %
					[ index, dag.child_offsets[index], expected_offset ])
			break
		expected_offset += dag.child_counts[index]
		for child in dag.children_of(index):
			if child < 0 or child >= count:
				problems.append("cluster %d has out-of-range child %d" % [ index, child ])
			elif child >= index:
				# Leaves-first ordering is what lets the runtime propagate in one backwards pass.
				problems.append("cluster %d has child %d at a higher index (ordering broken)" %
						[ index, child ])
	if expected_offset != dag.child_indices.size():
		problems.append("child_indices has %d entries, offsets account for %d" %
				[ dag.child_indices.size(), expected_offset ])

	if not is_inf(dag.parent_errors[dag.root_index]):
		problems.append("root parent_error is %f, expected INF" % dag.parent_errors[dag.root_index])

	# Every cluster must hang off the root, or geometry exists that can never be selected.
	var reached := {}
	var stack: Array[int] = [ dag.root_index ]
	while stack.size() > 0:
		var index: int = stack.pop_back()
		if reached.has(index):
			continue
		reached[index] = true
		for child in dag.children_of(index):
			if child >= 0 and child < count:
				stack.append(child)
	if reached.size() != count:
		problems.append("%d of %d clusters unreachable from the root" %
				[ count - reached.size(), count ])

	# Two separate questions, and conflating them hid a real defect. Since Phase 14b cluster_mesh()
	# reads the DAG before the nodes, so it reports geometry that exists but that nothing is bound to
	# draw — which is exactly what a regenerate-without-save produces, and the coarsest clusters are
	# the ones that go missing.
	var no_geometry := 0
	var not_renderable := 0
	for index in range(count):
		if lod.cluster_mesh(index) == null:
			no_geometry += 1
		if not lod.cluster_is_renderable(index):
			not_renderable += 1
	if no_geometry > 0:
		problems.append("%d clusters have no geometry in the DAG" % no_geometry)
	# Only a PARTIAL binding is a defect. None bound at all means the LOD was never attached to a
	# renderer — a DAG built in code and validated directly, which the measurement harnesses do — and
	# flagging that was a false positive on every one of them. The real failure, a regenerate without
	# a save, leaves most clusters bound and the highest indices orphaned.
	if not_renderable > 0 and not_renderable < count:
		problems.append(("%d of %d clusters have geometry but nothing bound to draw them — "
				+ "save the scene after regenerating") % [ not_renderable, count ])

	_section(lines, "structure", problems,
			"%d clusters, %d levels, root %d, all reachable and bound" %
			[ count, dag.levels[dag.root_index] + 1, dag.root_index ])
	return 1 if problems.size() > 0 else 0


# --- the Phase 5 invariants that make local selection correct ---
#
# Monotonic error gives the cut a unique solution; identical error and bounds within a group are what
# stop a group being half-refined. Both are assumptions the pruned descent relies on, so a violation
# here means selection is silently unsound rather than merely suboptimal.
static func _check_monotonicity(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var dag := lod.dag
	var problems: PackedStringArray = PackedStringArray()
	var min_error := INF
	var max_error := 0.0

	for index in range(dag.cluster_count):
		var error: float = dag.errors[index]
		if not is_inf(error):
			min_error = minf(min_error, error)
			max_error = maxf(max_error, error)
		if error < 0.0:
			problems.append("cluster %d has negative error %f" % [ index, error ])

		for child in dag.children_of(index):
			if dag.errors[child] > error + _EPSILON:
				problems.append("cluster %d error %f < child %d error %f (not monotonic)" %
						[ index, error, child, dag.errors[child] ])
			# A child's parent_error must BE its parent's own error - same group, same value.
			if absf(dag.parent_errors[child] - error) > _EPSILON:
				problems.append("child %d parent_error %f != parent %d error %f (group sharing broken)"
						% [ child, dag.parent_errors[child], index, error ])
			# The parent sphere has to enclose the child's, or projected error can come out smaller
			# for the parent at some view points and break monotonicity after projection.
			var separation := dag.lod_centers[index].distance_to(dag.lod_centers[child])
			# Tolerance SCALED to the radii being compared. An absolute epsilon is only
			# right while everything is about the same size: radii are stored as float32,
			# whose precision is relative, so at a radius of 2450 rounding alone is ~3e-4
			# against a fixed threshold of 1e-4. That produced four "does not enclose"
			# failures on Sponza whose real overshoots were 0.000006 to 0.000046 — pure
			# rounding. The test sphere's radii of a few hundred kept it under the line.
			var slack := _containment_slack(dag.lod_radii[index], dag.lod_radii[child])
			if separation + dag.lod_radii[child] > dag.lod_radii[index] + slack:
				problems.append("cluster %d sphere does not enclose child %d's" % [ index, child ])
				# Shell containment, the inner half of the same requirement. The parent's shell must
				# contain the child's, or the parent can report a LARGER distance than the child at
				# some view point, projected error stops being monotonic, and the cut can draw the
				# same surface twice or leave a hole. Allowing for the centres being apart, the
				# parent's inner radius may be at most the child's minus that separation.
				if index < dag.lod_inner_radii.size() and child < dag.lod_inner_radii.size():
					var allowed: float = maxf(dag.lod_inner_radii[child] - separation, 0.0)
					if dag.lod_inner_radii[index] > allowed + _containment_slack(
							dag.lod_radii[index], dag.lod_radii[child]):
						problems.append(("cluster %d shell inner %.3f exceeds child %d's %.3f "
								+ "(centres %.3f apart)") % [ index, dag.lod_inner_radii[index],
								child, dag.lod_inner_radii[child], separation ])

	var hollow := 0
	var max_inner := 0.0
	for index in range(mini(dag.cluster_count, dag.lod_inner_radii.size())):
		if dag.lod_inner_radii[index] > 0.0:
			hollow += 1
			max_inner = maxf(max_inner, dag.lod_inner_radii[index])
	_section(lines, "monotonicity", problems,
			("error monotonic on every edge, group values shared, shells nested "
			+ "(error %.3f..%.3f; %d/%d clusters hollow, deepest inner radius %.1f)")
			% [ min_error, max_error, hollow, dag.cluster_count, max_inner ])
	return 1 if problems.size() > 0 else 0


# How much a containment test may be out by before it counts as a real violation.
#
# A fixed floor plus a term proportional to the magnitudes involved, because the radii are
# stored as float32 and float precision is relative rather than absolute. Set well above
# float32's ~1.2e-7 and far below any violation that would actually break monotonic
# projected error.
static func _containment_slack(parent_radius: float, child_radius: float) -> float:
	return _EPSILON + maxf(parent_radius, child_radius) * 1e-5


# --- the cut is a cut ---
#
# Every root-to-leaf path must cross exactly ONE drawn cluster: 0 leaves a hole, 2 draws the same
# surface twice at different detail. Counting leaf clusters covered does NOT work - see the class
# comment.
static func _check_cut_validity(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var problems: PackedStringArray = PackedStringArray()
	var saved_threshold := lod.error_threshold
	var tested := 0
	var min_drawn := 1 << 30
	var max_drawn := 0

	var scale := _SelectorMeasure.reference_screen_scale()
	for threshold in _SWEEP_THRESHOLDS:
		for view_point in _sweep_points(lod):
			lod.error_threshold = threshold
			lod.select_cut(view_point, scale)
			tested += 1
			min_drawn = mini(min_drawn, lod.drawn_clusters)
			max_drawn = maxi(max_drawn, lod.drawn_clusters)
			var range_result := _path_crossings(lod)
			if range_result.x != 1 or range_result.y != 1:
				problems.append("threshold %.0f from %s: paths cross %d..%d drawn clusters" %
						[ threshold, view_point, range_result.x, range_result.y ])

	lod.error_threshold = saved_threshold
	_section(lines, "cut validity", problems,
			"%d threshold/viewpoint combinations, every one a valid cut (%d..%d clusters drawn)"
			% [ tested, min_drawn, max_drawn ])
	return 1 if problems.size() > 0 else 0


# --- two independent selectors must agree ---
#
# The pruned descent and the flat per-cluster test share no code path beyond the projection helpers.
# Agreement across the sweep is much stronger evidence than either alone, and is what would catch a
# bad pruning rule.
static func _check_selectors_agree(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var problems: PackedStringArray = PackedStringArray()
	var saved_threshold := lod.error_threshold
	var tested := 0

	var scale := _SelectorMeasure.reference_screen_scale()
	for threshold in _SWEEP_THRESHOLDS:
		for view_point in _sweep_points(lod):
			lod.error_threshold = threshold
			lod.select_cut_flat(view_point, scale)
			var flat := _drawn_set(lod)
			lod.select_cut(view_point, scale)
			var descent := _drawn_set(lod)
			tested += 1
			if flat != descent:
				problems.append("threshold %.0f from %s: flat drew %d, descent drew %d" %
						[ threshold, view_point, flat.count("1"), descent.count("1") ])

	lod.error_threshold = saved_threshold
	_section(lines, "selector agreement", problems,
			"descent matches the flat reference on all %d combinations" % tested)
	return 1 if problems.size() > 0 else 0


# --- geometry quality, read back from the cluster meshes ---
#
# Reported rather than pass/failed: there is no threshold that is objectively wrong, and the useful
# thing is the trend across levels. Fold-over is judged against level 0's own convention, since the
# test mesh is an inside-out sphere whose winding is inverted relative to its normals.
static func _report_geometry(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var dag := lod.dag
	var by_level: Dictionary = {}
	for index in range(dag.cluster_count):
		if not by_level.has(dag.levels[index]):
			by_level[dag.levels[index]] = []
		by_level[dag.levels[index]].append(index)

	var levels: Array = by_level.keys()
	levels.sort()
	if levels.is_empty():
		return 0

	# Each cluster's meshes are read here, on the main thread, and measured on the worker threads,
	# one _ClusterShape each. Two passes, since every level is judged against level 0: its winding
	# convention and its typical UV stretch come first.
	var shapes: Array[_ClusterShape] = []
	for index in range(dag.cluster_count):
		var shape := _ClusterShape.new()
		var mesh := lod.cluster_mesh(index)
		if mesh != null:
			for surface in mesh.get_surface_count():
				shape.surfaces.append(mesh.surface_get_arrays(surface))
		shapes.append(shape)

	# Level 0's winding convention, established BEFORE counting anything. Derived at the end of
	# level 0's own pass, it meant level 0 could never report a fold — it printed 0.00% however bad
	# the input was, which a deliberately winding-flipped mesh exposed.
	var level_zero: Array = by_level[levels[0]]
	_on_workers(level_zero.size(), func(i: int) -> void:
		var shape := shapes[level_zero[i]]
		for face in _faces_of(shape.surfaces):
			if face.area > 0.0:
				shape.winding_sum += face.winding_dot
			if face.uv_span >= 0.0 and face.world_span > 0.0:
				shape.stretch_samples.append(face.uv_span / face.world_span))
	var reference_sign := 0.0
	var stretch_samples := PackedFloat32Array()
	for index in level_zero:
		reference_sign += shapes[index].winding_sum
		stretch_samples.append_array(shapes[index].stretch_samples)
	reference_sign = signf(reference_sign)

	# Typical UV stretch in the source, so the tear test is relative to this mesh's own mapping.
	var reference_stretch := 0.0
	if stretch_samples.size() > 0:
		stretch_samples.sort()
		@warning_ignore("integer_division")
		reference_stretch = stretch_samples[stretch_samples.size() / 2]

	_on_workers(dag.cluster_count, func(index: int) -> void:
		var shape := shapes[index]
		var faces := _faces_of(shape.surfaces)
		if faces.is_empty():
			return
		shape.boundary = _boundary_edge_count(shape.surfaces)
		shape.triangles = faces.size()
		for face in faces:
			shape.area += face.area
			if face.area <= 0.0:
				continue
			if face.aspect < 0.087:
				shape.thin += 1
			if face.winding_dot * reference_sign < 0.0:
				shape.folded += 1
			# UV stretch: UV span over world span. A raw UV span flags size rather than tearing,
			# since a coarse triangle legitimately covers more of the map. The ratio is scale-free —
			# a triangle bridging a collapsed seam is small in the world and huge in UV.
			if (reference_stretch > 0.0 and face.uv_span >= 0.0 and face.world_span > 0.0
					and face.uv_span / face.world_span > reference_stretch * 4.0):
				shape.torn += 1
		shape.surfaces = [])

	lines.append("")
	lines.append("geometry by level (fold% is against level 0's winding convention)")
	lines.append("   L | clusters |   tris | fold% | thin% |  torn |    area |   bnd | bnd/sqrt(t)")

	# Size-independent seam density, peaked over levels. Boundary/triangles rises as ~1/sqrt(tris)
	# on its own as clusters shrink up the DAG, so it flags nothing; dividing by sqrt(tris) removes
	# that and makes two builds comparable. See Phase 4 in GODOTITE.md for the version that misled.
	var peak_density := 0.0
	var peak_level := 0

	for level in levels:
		var clusters := 0
		var triangles := 0
		var folded := 0
		var thin := 0
		var torn := 0
		var area := 0.0
		var boundary := 0
		var density_sum := 0.0
		for index in by_level[level]:
			var shape := shapes[index]
			if shape.triangles == 0:
				continue
			clusters += 1
			boundary += shape.boundary
			# Averaged per cluster, not computed from the level totals: a level holding one large
			# and one tiny cluster is not the same as two average ones, and the totals hide that.
			density_sum += float(shape.boundary) / sqrt(maxf(float(shape.triangles), 1.0))
			triangles += shape.triangles
			area += shape.area
			thin += shape.thin
			folded += shape.folded
			torn += shape.torn
		var denominator := maxi(triangles, 1)
		var density := density_sum / maxi(clusters, 1)
		if density > peak_density:
			peak_density = density
			peak_level = level
		lines.append("  %2d |   %4d   | %6d | %5.2f | %5.2f | %6d | %9.0f | %5d | %8.2f" % [
				level, clusters, triangles, 100.0 * folded / denominator,
				100.0 * thin / denominator, torn, area, boundary, density ])

	lines.append("peak bnd/sqrt(t) = %.2f at level %d — lower is less locked perimeter per cluster"
			% [ peak_density, peak_level ])
	return 0


# One cluster's share of the geometry report: its meshes' arrays, read on the main thread, and what a
# worker thread found in them.
class _ClusterShape:
	var surfaces: Array = []
	var winding_sum := 0.0
	var stretch_samples := PackedFloat32Array()
	var triangles := 0
	var area := 0.0
	var thin := 0
	var folded := 0
	var torn := 0
	var boundary := 0


# Runs work(i) for i in 0..count on the worker threads and waits for all of them. Each call must
# write only its own results.
static func _on_workers(count: int, work: Callable) -> void:
	if count > 0:
		WorkerThreadPool.wait_for_group_task_completion(
				WorkerThreadPool.add_group_task(work, count, -1, false, "Godotite validate"))


# --- a cut must not have cracks ---
#
# The rule the whole DAG exists to honour: simplification may lose detail, never continuity. Up to
# now that rested entirely on the design being right — group boundaries locked, seam curves coarsened
# symmetrically — and nothing checked it. The existing boundary counting is a per-cluster seam DENSITY
# metric within one level; it cannot see a crack, because a crack only exists between two clusters
# drawn at DIFFERENT levels, which no single-level measurement ever assembles.
#
# So: assemble the geometry actually drawn for a cut, weld it by position, and look at every edge with
# one incident triangle.
#
# Telling a crack from a legitimately open edge is the whole difficulty. The source outline cannot be
# compared position-by-position, because Phase 19 coarsens open outlines and a level-3 outline runs
# through different points than the level-0 one. What survives coarsening is the VERTICES: an edge
# collapse snaps to an existing vertex, so a coarsened outline's endpoints are always original outline
# vertices. That gives the test:
#
#   an unpaired edge is legitimate only if BOTH endpoints are vertices of the source outline.
#
# A crack forms where two clusters at different levels fail to meet, and its endpoints are interior
# vertices — so it fails that test. The reference outline comes from the assembled level-0 clusters,
# which are a bit-exact copy of the source.
#
# The cuts are chosen first, then checked on the worker threads, several at once: in batches of at
# most _CRACK_BATCH_TRIANGLES drawn triangles, which bounds the memory the edge tables take. The
# source outline is found on a worker thread of its own meanwhile, and the outline test comes last:
# an edge is a crack only if it fails all three tests, so their order changes nothing.
static func _check_no_cracks(lod: GodotiteLOD, lines: PackedStringArray) -> int:
	var problems: PackedStringArray = PackedStringArray()
	var level_zero := []
	for index in range(lod.dag.cluster_count):
		if lod.dag.levels[index] == 0 and lod.cluster_is_renderable(index):
			level_zero.append(_cluster_surfaces(lod, index))
	var outline := _Cut.new()
	var find_outline := func() -> void:
		outline.open_vertices = _outline_vertices(level_zero)
	var outline_task := WorkerThreadPool.add_task(find_outline, false, "Godotite source outline")
	var saved_threshold := lod.error_threshold
	var worst := 0
	var levels_seen := 0

	var cuts: Array[_Cut] = []
	var scale := _SelectorMeasure.reference_screen_scale()
	for threshold in _CRACK_SWEEP_THRESHOLDS:
		for view_point in _sweep_points(lod):
			lod.error_threshold = threshold
			lod.select_cut(view_point, scale)
			var cut := _Cut.new()
			cut.threshold = threshold
			cut.view_point = view_point
			cut.clusters = lod.drawn_clusters
			cut.triangles = lod.drawn_triangles
			var mixed: Dictionary = {}
			for index in range(lod.dag.cluster_count):
				if not lod.cluster_is_renderable(index) or not lod.is_drawn(index):
					continue
				mixed[lod.dag.levels[index]] = true
				cut.drawn.append(index)
			cut.levels = mixed.size()
			cuts.append(cut)
	lod.error_threshold = saved_threshold

	var start := 0
	while start < cuts.size():
		var end := start
		var batch_triangles := 0
		while end < cuts.size() and (end == start
				or batch_triangles + cuts[end].triangles <= _CRACK_BATCH_TRIANGLES):
			batch_triangles += cuts[end].triangles
			end += 1
		# Meshes are read here, on the main thread; the worker threads only read the arrays.
		var surfaces := {}
		for cut in cuts.slice(start, end):
			for index in cut.drawn:
				if not surfaces.has(index):
					surfaces[index] = _cluster_surfaces(lod, index)
		var batch := cuts.slice(start, end)
		_on_workers(batch.size(), func(i: int) -> void:
			batch[i].candidates = _crack_candidates(surfaces, batch[i].drawn))
		start = end

	WorkerThreadPool.wait_for_task_completion(outline_task)
	var open_vertices := outline.open_vertices
	for cut in cuts:
		for i in range(0, cut.candidates.size(), 2):
			var a := cut.candidates[i]
			var b := cut.candidates[i + 1]
			if open_vertices.has(a) and open_vertices.has(b):
				continue
			# Then the slower test, which allows for compressed vertices' rounding.
			if _on_outline(open_vertices, a) and _on_outline(open_vertices, b):
				continue
			cut.cracks += 1
		cut.candidates.clear()

	for cut in cuts:
		levels_seen = maxi(levels_seen, cut.levels)
		worst = maxi(worst, cut.cracks)
		if cut.cracks > 0:
			# Drawn-cluster and level counts are part of the message because they separate the two
			# very different faults this check can catch: a tear BETWEEN clusters can only happen
			# with more than one drawn, so cracks in a single-cluster cut mean the simplifier is
			# opening holes INSIDE a cluster.
			problems.append(("threshold %.0f from %s: %d unpaired edge(s) not on the source "
					+ "outline, %d cluster(s) drawn across %d level(s)")
					% [ cut.threshold, cut.view_point, cut.cracks, cut.clusters, cut.levels ])

	_section(lines, "no cracks", problems,
			"%d cuts watertight, up to %d levels mixed in one cut, %d source outline vertices"
			% [ cuts.size(), levels_seen, open_vertices.size() ])
	return 1 if problems.size() > 0 else 0


# Drawn triangles checked at once by the crack check. An edge table takes some 200 bytes per
# triangle drawn, so a batch stays near a gigabyte. Set from the hollow world terrain, whose 24 cuts
# draw 5M triangles in all, the largest 754k.
const _CRACK_BATCH_TRIANGLES := 5_000_000


# One cut of the crack check: how it was chosen, what it drew, and the cracks found in it.
class _Cut:
	var threshold := 0.0
	var view_point := Vector3.ZERO
	var drawn := PackedInt32Array()
	var clusters := 0
	var triangles := 0
	var levels := 0
	var cracks := 0
	# The unpaired edges no near copy explains, as position pairs: cracks unless on the outline.
	var candidates: Array[Vector3i] = []
	# Only on the one holding the source outline's vertices.
	var open_vertices := {}


# The unpaired edges of a cut that no near copy explains (see _has_near_edge), as position pairs.
# Run on the worker threads, from arrays read beforehand.
static func _crack_candidates(surfaces: Dictionary, drawn: PackedInt32Array) -> Array[Vector3i]:
	var table := _EdgeTable.new()
	for index in drawn:
		table.add_surfaces(surfaces[index])
	var candidates: Array[Vector3i] = []
	for key: int in table.counts:
		if table.counts[key] != 1:
			continue
		var a := table.positions[key >> 32]
		var b := table.positions[key & 0xFFFFFFFF]
		if not _has_near_edge(table, a, b):
			candidates.append(a)
			candidates.append(b)
	return candidates


# A cluster's surfaces' arrays.
static func _cluster_surfaces(lod: GodotiteLOD, index: int) -> Array:
	var surfaces := []
	var mesh := lod.cluster_mesh(index)
	if mesh != null:
		for surface in mesh.get_surface_count():
			surfaces.append(mesh.surface_get_arrays(surface))
	return surfaces


# Quantised positions of every vertex lying on an open boundary of the source surface.
#
# Read from the assembled level-0 clusters, which reproduce the source exactly, so this stays a
# property of the shipped geometry rather than of builder state.
static func _outline_vertices(level_zero: Array) -> Dictionary:
	var table := _EdgeTable.new()
	for surfaces: Array in level_zero:
		table.add_surfaces(surfaces)
	var open_vertices: Dictionary = {}
	for key: int in table.counts:
		if table.counts[key] != 1:
			continue
		var a := table.positions[key >> 32]
		var b := table.positions[key & 0xFFFFFFFF]
		if not _has_near_edge(table, a, b):
			open_vertices[a] = true
			open_vertices[b] = true
	return open_vertices


# Edges counted by quantised endpoint positions: how many triangles each edge belongs to.
#
# Position keys rather than vertex indices, for the same reason _boundary_edge_count uses them: a
# cluster's surfaces are welded per attribute set, so one edge crossing a UV or material seam shows
# up as several index pairs. Position keying is also what makes edges comparable ACROSS clusters,
# which is the entire point here. Each position gets an id, and an edge is its two ids in one int:
# keyed by an Array of two positions, as it was, every edge cost an allocation and some 200 bytes,
# which made the crack check slow and several cuts at once too large to hold.
class _EdgeTable:
	var ids := {}
	var positions: Array[Vector3i] = []
	var counts := {}

	func add_surfaces(surfaces: Array) -> void:
		for arrays: Array in surfaces:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices := GodotiteValidator.corner_indices(arrays)
			for i in range(0, indices.size() - 2, 3):
				for corner in range(3):
					var a := Vector3i((vertices[indices[i + corner]]
							/ GodotiteValidator.BOUNDARY_WELD_TOLERANCE).round())
					var b := Vector3i((vertices[indices[i + (corner + 1) % 3]]
							/ GodotiteValidator.BOUNDARY_WELD_TOLERANCE).round())
					if a == b:
						continue
					var key := _key(_id(a), _id(b))
					counts[key] = counts.get(key, 0) + 1

	func _id(position: Vector3i) -> int:
		var id: int = ids.get(position, -1)
		if id < 0:
			id = positions.size()
			ids[position] = id
			positions.append(position)
		return id

	static func _key(id_a: int, id_b: int) -> int:
		return (mini(id_a, id_b) << 32) | maxi(id_a, id_b)


# Whether another edge's ends are each at most one key cell from this one's.
#
# With compressed vertices, clusters decode a shared vertex through different boxes, a float rounding
# apart, and now and then that lands the copies either side of a key boundary: one edge is counted
# under two keys a cell apart, not a crack. The other copy can be counted more than once, where an
# edge is non-manifold, so it is looked for among all edges, not only unpaired ones.
#
# Only cells holding a vertex can hold an end of such an edge, so those are found first, usually one
# or two of each end's 27, and only their pairs are looked up, rather than all 729.
static func _has_near_edge(table: _EdgeTable, a: Vector3i, b: Vector3i) -> bool:
	var id_a: int = table.ids.get(a, -1)
	var id_b: int = table.ids.get(b, -1)
	var near_a := PackedInt32Array()
	var near_b := PackedInt32Array()
	for offset in _neighbour_offsets:
		var id: int = table.ids.get(a + offset, -1)
		if id >= 0:
			near_a.append(id)
		id = table.ids.get(b + offset, -1)
		if id >= 0:
			near_b.append(id)
	for other_a in near_a:
		for other_b in near_b:
			if other_a == id_a and other_b == id_b:
				continue
			if table.counts.has(_EdgeTable._key(other_a, other_b)):
				return true
	return false


# A key cell and its 26 neighbours, as offsets.
static var _neighbour_offsets: Array[Vector3i] = _make_neighbour_offsets()


static func _make_neighbour_offsets() -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				cells.append(Vector3i(dx, dy, dz))
	return cells


# Whether a vertex key, or a key next to it, is on the source outline: a compressed vertex can
# decode a float rounding across a key boundary from its level-0 copy.
static func _on_outline(open_vertices: Dictionary, key: Vector3i) -> bool:
	for offset in _neighbour_offsets:
		if open_vertices.has(key + offset):
			return true
	return false


# Position quantisation for edge identity, taken from the builder rather than restated. It used to
# be a copy with a comment asking that the two be kept in sync by hand, which is the kind of
# agreement that holds right up until it does not.
## The distance within which two positions count as the same vertex: the builder's
## WELD_TOLERANCE.
const BOUNDARY_WELD_TOLERANCE := GodotiteBuilder.WELD_TOLERANCE


# Boundary edges of one cluster, counted from its geometry rather than from build-time data.
#
# These are exactly the edges the simplifier LOCKS, so this is the direct measure of how much of a
# cluster's perimeter is frozen — the objective `boundary_edge_weight` optimises. Counting it here,
# from the meshes that actually shipped, keeps it an independent check on the builder rather than
# an echo of a number the builder chose.
#
# Keyed on QUANTISED POSITION, not vertex index: cluster surfaces are welded by all attributes, so
# an edge crossing a UV or material seam inside the cluster appears as two distinct index pairs and
# would be miscounted as two boundary edges.
static func _boundary_edge_count(surfaces: Array) -> int:
	var counts: Dictionary = {}
	for arrays: Array in surfaces:
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices := corner_indices(arrays)
		for i in range(0, indices.size(), 3):
			for corner in range(3):
				var a := Vector3i((vertices[indices[i + corner]] / BOUNDARY_WELD_TOLERANCE).round())
				var b := Vector3i((vertices[indices[i + (corner + 1) % 3]]
						/ BOUNDARY_WELD_TOLERANCE).round())
				var key: Array = [ a, b ] if a < b else [ b, a ]
				counts[key] = counts.get(key, 0) + 1
	var boundary := 0
	for key in counts:
		if counts[key] == 1:
			boundary += 1
	return boundary


# Per-triangle measurements for one cluster, across ALL of its surfaces.
#
# A cluster carries one surface per material it contains, so reading only surface 0 silently drops
# most of the mesh on a multi-material build. Cluster meshes are also indexed, so the vertex array
# can no longer be walked in triples — triangles come from the index array.
static func _faces_of(surfaces: Array) -> Array[FaceInfo]:
	var faces: Array[FaceInfo] = []
	for arrays: Array in surfaces:
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs := PackedVector2Array()
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			uvs = arrays[Mesh.ARRAY_TEX_UV]
		var corners := corner_indices(arrays)

		for c in range(0, corners.size() - 2, 3):
			var i: int = corners[c]
			var j: int = corners[c + 1]
			var k: int = corners[c + 2]
			var highest := maxi(i, maxi(j, k))
			var face := FaceInfo.new()
			var cross_product := (vertices[j] - vertices[i]).cross(vertices[k] - vertices[i])
			var double_area := cross_product.length()
			face.area = double_area * 0.5
			face.world_span = maxf(vertices[i].distance_to(vertices[j]),
					maxf(vertices[j].distance_to(vertices[k]), vertices[k].distance_to(vertices[i])))
			if double_area > 0.0 and face.world_span > 0.0:
				face.aspect = (double_area / face.world_span) / face.world_span
				if normals.size() > highest:
					face.winding_dot = cross_product.normalized().dot(
							(normals[i] + normals[j] + normals[k]).normalized())
			if uvs.size() > highest:
				face.uv_span = maxf(uvs[i].distance_to(uvs[j]),
						maxf(uvs[j].distance_to(uvs[k]), uvs[k].distance_to(uvs[i])))
			faces.append(face)
	return faces


## One triangle's shape, read back from a cluster mesh for the geometry report.
class FaceInfo:
	## Area in world units.
	var area: float = 0.0
	## Height over the longest edge: about 0.87 for an equilateral triangle, near 0 for a sliver.
	var aspect: float = 1.0
	## Longest edge, in world units.
	var world_span: float = 0.0
	## The face normal against the vertex normals: negative where the triangle has folded over.
	var winding_dot: float = 0.0
	## Longest edge in UV units, -1 without UVs.
	var uv_span: float = -1.0


# Per-triangle corner indices for a surface, whether it is indexed or not.
#
# Cluster meshes are indexed since Phase 13, so walking the vertex array in triples no longer
# enumerates triangles — it would read welded vertices in arbitrary groupings and report nonsense.
## Per-triangle corner indices for a surface's arrays, whether it is indexed or not.
static func corner_indices(arrays: Array) -> PackedInt32Array:
	if arrays[Mesh.ARRAY_INDEX] != null:
		return arrays[Mesh.ARRAY_INDEX]
	var sequential := PackedInt32Array()
	sequential.resize(arrays[Mesh.ARRAY_VERTEX].size())
	for i in range(sequential.size()):
		sequential[i] = i
	return sequential


# Smallest and largest number of drawn clusters on any root-to-leaf path, as (min, max).
static func _path_crossings(lod: GodotiteLOD) -> Vector2i:
	var dag := lod.dag
	var path_min := PackedInt32Array()
	var path_max := PackedInt32Array()
	path_min.resize(dag.cluster_count)
	path_max.resize(dag.cluster_count)
	path_min.fill(-1)
	path_max.fill(-1)
	var root_step: int = 1 if lod.is_drawn(dag.root_index) else 0
	path_min[dag.root_index] = root_step
	path_max[dag.root_index] = root_step

	# Leaves-first ordering means one backwards pass reaches every parent before its children.
	for index in range(dag.cluster_count - 1, -1, -1):
		if path_min[index] < 0:
			continue
		for child in dag.children_of(index):
			var step: int = 1 if lod.is_drawn(child) else 0
			if path_min[child] < 0:
				path_min[child] = path_min[index] + step
				path_max[child] = path_max[index] + step
			else:
				path_min[child] = mini(path_min[child], path_min[index] + step)
				path_max[child] = maxi(path_max[child], path_max[index] + step)

	var lowest := 1 << 30
	var highest := 0
	for index in range(dag.cluster_count):
		if dag.is_leaf(index):
			lowest = mini(lowest, maxi(path_min[index], 0))
			highest = maxi(highest, maxi(path_max[index], 0))
	return Vector2i(lowest, highest)


static func _drawn_set(lod: GodotiteLOD) -> String:
	var bits := PackedByteArray()
	bits.resize(lod.dag.cluster_count)
	for index in range(lod.dag.cluster_count):
		bits[index] = 49 if lod.is_drawn(index) else 48  # '1' / '0'
	return bits.get_string_from_ascii()


# View points derived from the root's bounding sphere, in the node's own local space, so the sweep
# adapts to whatever mesh this is rather than assuming the test sphere's scale.
static func _sweep_points(lod: GodotiteLOD) -> Array[Vector3]:
	var centre: Vector3 = lod.dag.lod_centers[lod.dag.root_index]
	# Floored only against zero: a floor of 1 put every viewpoint far outside a model whose radius
	# is well under 1 in its own units, as the terrain's is.
	var radius: float = maxf(lod.dag.lod_radii[lod.dag.root_index], 1e-6)
	var points: Array[Vector3] = []
	for factor in _SWEEP_DISTANCE_FACTORS:
		points.append(lod.to_global(centre + Vector3(0.37, 0.55, 0.75).normalized() * radius * factor))
	return points


static func _section(lines: PackedStringArray, name: String, problems: PackedStringArray,
		summary: String) -> void:
	if problems.is_empty():
		lines.append("  ok    %-20s %s" % [ name, summary ])
		return
	lines.append("  FAIL  %-20s %d problem(s)" % [ name, problems.size() ])
	for i in range(mini(problems.size(), 8)):
		lines.append("          " + problems[i])
	if problems.size() > 8:
		lines.append("          ... and %d more" % (problems.size() - 8))
