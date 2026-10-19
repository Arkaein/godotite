@tool
class_name GodotiteMeasure
extends RefCounted

## Measures how far a GodotiteLOD's drawn clusters really look from full detail, in pixels.
##
## What the Measure Error button on a [GodotiteLOD] runs: [method sweep] tries a range of error
## thresholds from a view point and reports, for each, the measured error and what it cost in
## triangles and draw calls, so a threshold can be chosen from numbers. [br][br]
##
## The deviation is measured geometrically, from the meshes drawn: for every vertex of the
## full-detail surface, the distance to the closest point on the surface the cut draws, divided by
## the distance to the camera and scaled by the projection.
#
# `error_threshold` is a promise: "no cluster will show more than T pixels of error". Nothing has
# ever checked whether the promise is kept. The DAG's own stored error cannot check it — that is the
# number making the claim, and validating a claim against itself is the mistake this project has
# made eight times. So the deviation here is measured GEOMETRICALLY, from the meshes that shipped,
# with no reference to any error value the builder computed.
#
# The measurement: for every vertex of the full-detail surface, find the closest point on the
# surface the cut actually draws. That distance is how far the drawn surface sits from the truth at
# that spot. Divided by the distance to the camera and scaled by the projection, it becomes pixels.
#
# Direction matters and the obvious one is wrong. Measuring from CUT vertices to the source surface
# always reports ~0, because collapses snap to existing vertices — every cut vertex IS a source
# vertex and sits exactly on it. The error lives in the surface *between* those vertices, which is
# only visible from the other side: source detail that the coarse surface no longer passes through.

# The camera the pixel figures are quoted against. Pixel error is meaningless without one, so it is
# stated and reported rather than read from whatever viewport happens to exist.
## The screen height, in pixels, the measured pixel errors are quoted at.
const REFERENCE_HEIGHT := 1080.0
## The reference camera's vertical field of view, Godot's Camera3D default.
const REFERENCE_FOV := 75.0

# `height / (2 * tan(fov / 2))`, the same formula as GodotiteLOD.screen_error_scale(). Derived
# rather than written as a literal, so it cannot drift from that function. Works out at ~704.
## Pixels of screen error per unit of projected error for the reference camera
## ([constant REFERENCE_HEIGHT], [constant REFERENCE_FOV]), as GodotiteLOD.screen_error_scale()
## gives for a real one.
static func reference_screen_scale() -> float:
	return REFERENCE_HEIGHT / (2.0 * tan(deg_to_rad(REFERENCE_FOV) * 0.5))

# Cells per axis in the lookup grid over drawn triangles. Rebuilt per cut.
const _GRID_DIM := 48

# Guard against a pathological search on a degenerate cut.
const _MAX_RING := 24


# One worker thread's share of a measurement: the reference points start..end, and what it found.
class _Part:
	var start := 0
	var end := 0
	var max_world := 0.0
	var world_sum := 0.0
	var pixel_distances := PackedFloat32Array()
	var uv_errors := PackedFloat32Array()


## One measurement of a cut: how far it sits from full detail, and what it cost.
class Deviation:
	## World-space distance from the full-detail surface to the drawn surface.
	var max_world := 0.0
	## Mean world-space distance, as max_world.
	var mean_world := 0.0
	## The same distances converted to pixels using each sample's own camera distance, so a far
	## cluster is not penalised for errors the viewer cannot resolve.
	var max_pixels := 0.0
	## Mean pixel distance, as max_pixels.
	var mean_pixels := 0.0
	## 95th percentile pixel distance, as max_pixels.
	var p95_pixels := 0.0
	# How far the drawn surface's TEXTURE has slid, in UV units.
	#
	# Reported as median and p95, never as max or mean. Absolute-UV comparison is confounded at a
	# seam: a reference point on one side matches a triangle on the other, and the wrap registers as
	# a near-maximal error that is not distortion at all. Measured on the test sphere, `max` sat at
	# 1.41 — the diagonal of the whole UV square — at EVERY threshold including the finest, and the
	# mean came out above the p95. The order statistics are unaffected by a thin tail of those.
	## Median texture slide, in UV units: how far the drawn surface's texture has moved from full
	## detail. Median and 95th percentile rather than max and mean, which UV seams make meaningless.
	var uv_median := 0.0
	## 95th percentile texture slide, as uv_median.
	var uv_p95 := 0.0

	## Clusters the measured cut drew.
	var clusters := 0
	## Surfaces (draw calls) the measured cut drew.
	var surfaces := 0
	## Triangles the measured cut drew.
	var triangles := 0
	## Full-detail vertices measured.
	var samples := 0


# Sweep `error_threshold` and report measured error against cost at each value.
#
# `max_samples` subsamples the reference vertices, evenly; 0 measures every one. The distances are
# a max and a mean over sample points, so subsampling can only ever UNDERSTATE the max — worth
# remembering when reading a subsampled run. A threshold that selects the same cut as one already
# measured reuses its result: neighbouring thresholds often do.
## Measures the cut at each of [param thresholds] from [param view_point] and returns the report,
## restoring the LOD's threshold afterwards; await it. One threshold per frame, so the editor keeps
## drawing, and [param progress], if given, is called with a line before each, and after any that
## took over a second with how long it took. [param max_samples]
## caps the full-detail vertices measured (0 for all); a capped run can only understate the max.
static func sweep(lod: GodotiteLOD, thresholds: Array, view_point: Vector3,
		max_samples: int = 0, progress: Callable = Callable()) -> String:
	var lines := PackedStringArray()
	if lod == null or lod.dag == null or not lod.dag.is_valid():
		return "no valid DAG"

	var reference_uvs := PackedVector2Array()
	var reference_points := _reference_points(lod, 1, reference_uvs)
	if reference_points.is_empty():
		return "no level-0 geometry to measure against"
	var unique := reference_points.size()
	if max_samples > 0 and unique > max_samples:
		var step := ceili(float(unique) / max_samples)
		var kept_points := PackedVector3Array()
		var kept_uvs := PackedVector2Array()
		for i in range(0, unique, step):
			kept_points.append(reference_points[i])
			kept_uvs.append(reference_uvs[i])
		reference_points = kept_points
		reference_uvs = kept_uvs

	var saved := lod.error_threshold
	lines.append("measured error vs cost, %d reference points%s, view point %s" % [
			reference_points.size(),
			"" if reference_points.size() == unique else " (every %s of %d)" % [
				_ordinal(ceili(float(unique) / reference_points.size())), unique ],
			view_point ])
	lines.append("screen scale %.0f (%dp @ %.0f deg vertical FOV)" %
			[ reference_screen_scale(), int(REFERENCE_HEIGHT), REFERENCE_FOV ])
	lines.append("")
	# max/T is the calibration: error_threshold PROMISES no more than T pixels of error, so a ratio
	# above 1.0 is a broken promise and one far below it means the threshold is buying detail nobody
	# can see. It is the only column that says whether a value of T is right rather than merely
	# expensive.
	lines.append("  thresh | clusters | draws |   tris | max px | max/T | p95 px | uv med | uv p95")
	var measured := {}
	for i in thresholds.size():
		var threshold: float = thresholds[i]
		if progress.is_valid():
			progress.call("threshold %s (%d of %d)..." % [ threshold, i + 1, thresholds.size() ])
		# A frame before the work, so the line just printed shows while it runs.
		await Engine.get_main_loop().process_frame
		var started := Time.get_ticks_msec()
		lod.error_threshold = threshold
		lod.select_cut(view_point, reference_screen_scale())
		var cut := PackedInt32Array()
		for index in lod.dag.cluster_count:
			if lod.is_drawn(index):
				cut.append(index)
		var result: Deviation = measured.get(cut)
		if result == null:
			result = measure(lod, reference_points, view_point, reference_uvs)
			measured[cut] = result
		lines.append("  %6.1f |   %6d | %5d | %6d | %6.2f | %5.2f | %6.2f | %6.4f | %6.4f" % [
				threshold, result.clusters, result.surfaces, result.triangles, result.max_pixels,
				result.max_pixels / maxf(threshold, 0.001), result.p95_pixels,
				result.uv_median, result.uv_p95 ])
		var seconds := (Time.get_ticks_msec() - started) / 1000.0
		if progress.is_valid() and seconds >= 1.0:
			progress.call("threshold %s took %.1f s" % [ threshold, seconds ])
	lod.error_threshold = saved
	return "\n".join(lines)


static func _ordinal(n: int) -> String:
	if n % 100 in [ 11, 12, 13 ]:
		return "%dth" % n
	return "%d%s" % [ n, { 1: "st", 2: "nd", 3: "rd" }.get(n % 10, "th") ]


## Distances from each reference point to the currently drawn surface.
static func measure(lod: GodotiteLOD, reference_points: PackedVector3Array, view_point: Vector3,
		reference_uvs: PackedVector2Array = PackedVector2Array()) -> Deviation:
	var result := Deviation.new()
	result.clusters = lod.drawn_clusters
	result.surfaces = lod.drawn_surfaces
	result.triangles = lod.drawn_triangles

	var drawn_uvs := PackedVector2Array()
	var corners := _drawn_triangles(lod, drawn_uvs)
	if corners.is_empty():
		return result

	var bounds := AABB(corners[0], Vector3.ZERO)
	for corner in corners:
		bounds = bounds.expand(corner)

	# Cell size is the LARGER of a fixed subdivision and the mean triangle extent. Sizing the grid
	# from the bounds alone works only while triangles are small: a coarse cut's triangles each span
	# a large part of the mesh, get registered into thousands of cells, and the build cost explodes
	# — which killed a sweep at 2400 s. Matching the cells to the triangles keeps the cells-per-
	# triangle count near constant at every level of coarseness.
	var extent_sum := 0.0
	@warning_ignore("integer_division")
	var triangle_count := corners.size() / 3
	for triangle in range(triangle_count):
		var a := corners[triangle * 3]
		var b := corners[triangle * 3 + 1]
		var c := corners[triangle * 3 + 2]
		extent_sum += (a.max(b).max(c) - a.min(b).min(c)).length()
	var cell_size: float = maxf(
			maxf(bounds.size[bounds.get_longest_axis_index()], 0.001) / _GRID_DIM,
			extent_sum / maxi(triangle_count, 1))
	var grid := _build_grid(corners, cell_size)
	var runs: Dictionary = grid.runs
	var grid_triangles: PackedInt32Array = grid.triangles
	var spheres := PackedVector4Array()
	spheres.resize(triangle_count)
	for triangle in range(triangle_count):
		var a := corners[triangle * 3]
		var b := corners[triangle * 3 + 1]
		var c := corners[triangle * 3 + 2]
		var center := (a + b + c) / 3.0
		var radius := maxf(center.distance_to(a), maxf(center.distance_to(b), center.distance_to(c)))
		spheres[triangle] = Vector4(center.x, center.y, center.z, radius)

	# Cluster meshes are in the LOD node's local space, so the view point has to join them there.
	# select_cut() does the same conversion internally. Identical while the node sits at identity,
	# which is the only reason this was not visibly wrong.
	var local_view := lod.to_local(view_point) if lod.is_inside_tree() else view_point

	# The search for each point is independent and only reads what was built above, so it runs on
	# the worker threads, in parts each written by one thread only; the parts are merged here.
	var measure_uvs := reference_uvs.size() == reference_points.size()
	var part_count := clampi(OS.get_processor_count() * 4, 1, maxi(reference_points.size(), 1))
	var parts: Array[_Part] = []
	for p in part_count:
		var part := _Part.new()
		@warning_ignore("integer_division")
		part.start = reference_points.size() * p / part_count
		@warning_ignore("integer_division")
		part.end = reference_points.size() * (p + 1) / part_count
		parts.append(part)
	var search := func(p: int) -> void:
		var part := parts[p]
		var hit := PackedInt32Array([ -1 ])
		for index in range(part.start, part.end):
			var point := reference_points[index]
			var distance := _closest_distance(point, corners, runs, grid_triangles, spheres, cell_size,
					hit)
			if distance < 0.0:
				continue
			if measure_uvs and hit[0] >= 0:
				var t: int = hit[0]
				var weights := _barycentric(point, corners[t * 3], corners[t * 3 + 1],
						corners[t * 3 + 2])
				var found: Vector2 = (drawn_uvs[t * 3] * weights.x + drawn_uvs[t * 3 + 1] * weights.y
						+ drawn_uvs[t * 3 + 2] * weights.z)
				part.uv_errors.append(found.distance_to(reference_uvs[index]))
			# Each sample is priced at its OWN distance to the camera. Using one distance for the
			# whole mesh would make a near cluster and a far one look equally wrong.
			var to_camera: float = maxf(point.distance_to(local_view),
					GodotiteLOD.MIN_PROJECTION_DISTANCE)
			var pixels := distance * reference_screen_scale() / to_camera
			part.max_world = maxf(part.max_world, distance)
			part.world_sum += distance
			part.pixel_distances.append(pixels)
	WorkerThreadPool.wait_for_group_task_completion(
			WorkerThreadPool.add_group_task(search, part_count, -1, false, "Godotite measure"))

	var pixel_distances := PackedFloat32Array()
	var uv_errors := PackedFloat32Array()
	var world_sum := 0.0
	var pixel_sum := 0.0
	for part in parts:
		result.max_world = maxf(result.max_world, part.max_world)
		world_sum += part.world_sum
		pixel_distances.append_array(part.pixel_distances)
		uv_errors.append_array(part.uv_errors)
	for pixels in pixel_distances:
		result.max_pixels = maxf(result.max_pixels, pixels)
		pixel_sum += pixels

	if uv_errors.size() > 0:
		uv_errors.sort()
		@warning_ignore("integer_division")
		result.uv_median = uv_errors[uv_errors.size() / 2]
		result.uv_p95 = uv_errors[mini(int(uv_errors.size() * 0.95), uv_errors.size() - 1)]

	result.samples = pixel_distances.size()
	if result.samples > 0:
		result.mean_world = world_sum / result.samples
		result.mean_pixels = pixel_sum / result.samples
		pixel_distances.sort()
		result.p95_pixels = pixel_distances[mini(int(result.samples * 0.95), result.samples - 1)]
	return result


# Barycentric weights of the point on the triangle's plane, clamped into the triangle.
#
# Used only to read an interpolated attribute, so a point slightly off the surface is projected
# rather than rejected — the reference points sit on the SOURCE surface, which by definition is not
# quite where the simplified one is.
static func _barycentric(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := point - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denominator := d00 * d11 - d01 * d01
	if is_zero_approx(denominator):
		return Vector3(1.0, 0.0, 0.0)
	var v := (d11 * d20 - d01 * d21) / denominator
	var w := (d00 * d21 - d01 * d20) / denominator
	v = clampf(v, 0.0, 1.0)
	w = clampf(w, 0.0, 1.0 - v)
	return Vector3(1.0 - v - w, v, w)


# Unique vertex positions of the level-0 clusters, which are the source triangles unchanged.
#
# Deduplicated by quantised position so a seam vertex, which exists once per attribute island, does
# not get weighted several times in the mean.
static func _reference_points(lod: GodotiteLOD, stride: int,
		uvs_out: PackedVector2Array = PackedVector2Array()) -> PackedVector3Array:
	var seen := {}
	var points := PackedVector3Array()
	var kept := 0
	for index in range(lod.dag.cluster_count):
		if lod.dag.levels[index] != 0:
			continue
		var mesh := lod.cluster_mesh(index)
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			var arrays: Array = mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var surface_uvs = arrays[Mesh.ARRAY_TEX_UV]
			for i in range(vertices.size()):
				var key := Vector3i((vertices[i]
						/ GodotiteValidator.BOUNDARY_WELD_TOLERANCE).round())
				if seen.has(key):
					continue
				seen[key] = true
				kept += 1
				if kept % stride == 0:
					points.append(vertices[i])
					uvs_out.append(surface_uvs[i] if surface_uvs != null
							and i < surface_uvs.size() else Vector2.ZERO)
	return points


# Every triangle of every drawn cluster, flattened to three corners each, with the matching UVs in
# a parallel array so a point located on the surface can be asked what it is textured with.
static func _drawn_triangles(lod: GodotiteLOD, uvs_out: PackedVector2Array = PackedVector2Array()
		) -> PackedVector3Array:
	var corners := PackedVector3Array()
	for index in range(lod.dag.cluster_count):
		if not lod.is_drawn(index):
			continue
		var mesh := lod.cluster_mesh(index)
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			var arrays: Array = mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var surface_uvs = arrays[Mesh.ARRAY_TEX_UV]
			for corner in GodotiteValidator.corner_indices(arrays):
				corners.append(vertices[corner])
				uvs_out.append(surface_uvs[corner] if surface_uvs != null
						and corner < surface_uvs.size() else Vector2.ZERO)
	return corners


# cell -> the triangles overlapping it, as { "runs": cell -> Vector2i(start, count) into
# "triangles" }. A triangle is registered in every cell its AABB
# spans, so a large coarse triangle is found from anywhere along its length.
static func _build_grid(corners: PackedVector3Array, cell_size: float) -> Dictionary:
	var grid := {}
	@warning_ignore("integer_division")
	for triangle in range(corners.size() / 3):
		var a := corners[triangle * 3]
		var b := corners[triangle * 3 + 1]
		var c := corners[triangle * 3 + 2]
		var low := Vector3i((a.min(b).min(c) / cell_size).floor())
		var high := Vector3i((a.max(b).max(c) / cell_size).floor())
		for x in range(low.x, high.x + 1):
			for y in range(low.y, high.y + 1):
				for z in range(low.z, high.z + 1):
					var key := Vector3i(x, y, z)
					if not grid.has(key):
						grid[key] = PackedInt32Array()
					grid[key].append(triangle)
	# Flattened: each cell's triangles as a run in one array, the cell holding (start, count). Read by
	# every worker thread at once, and a lookup that returns a plain Vector2i shares nothing between
	# them, where returning each cell's own array made every thread update its shared reference
	# count, which held the speed-up to under 3x on 12 cores.
	var runs := {}
	var triangles := PackedInt32Array()
	for key in grid:
		runs[key] = Vector2i(triangles.size(), grid[key].size())
		triangles.append_array(grid[key])
	return { "runs": runs, "triangles": triangles }


# Distance from a point to the nearest drawn triangle, searching outward a ring at a time.
#
# The stop condition is what makes this exact rather than approximate: a ring at radius r cannot
# contain anything closer than (r - 1) * cell_size, so once the best distance found is under that,
# no further ring can improve it.
#
# Each candidate is first tested against its bounding sphere (`bounds`: centre and radius per
# triangle), inline: a triangle whose sphere is already farther than the best found cannot be
# closer, and skipping the call for it matters, since a GDScript call costs more than the test
# itself and slows every thread together (they share the script's reference count).
static func _closest_distance(point: Vector3, corners: PackedVector3Array, runs: Dictionary,
		triangles: PackedInt32Array, bounds: PackedVector4Array, cell_size: float,
		hit_out: PackedInt32Array = PackedInt32Array()) -> float:
	var center := Vector3i((point / cell_size).floor())
	var best := INF
	var best_triangle := -1
	for ring in range(_MAX_RING):
		if best < float(ring - 1) * cell_size:
			break
		for x in range(center.x - ring, center.x + ring + 1):
			for y in range(center.y - ring, center.y + ring + 1):
				for z in range(center.z - ring, center.z + ring + 1):
					# Only the shell of the cube; the interior was covered by smaller rings.
					if (absi(x - center.x) != ring and absi(y - center.y) != ring
							and absi(z - center.z) != ring):
						continue
					var run: Vector2i = runs.get(Vector3i(x, y, z), Vector2i.ZERO)
					for slot in range(run.x, run.x + run.y):
						var triangle := triangles[slot]
						var sphere := bounds[triangle]
						if (point - Vector3(sphere.x, sphere.y, sphere.z)).length() - sphere.w >= best:
							continue
						var distance := _point_triangle_distance(point,
								corners[triangle * 3], corners[triangle * 3 + 1],
								corners[triangle * 3 + 2])
						if distance < best:
							best = distance
							best_triangle = triangle
	if hit_out.size() > 0:
		hit_out[0] = best_triangle
	return -1.0 if is_inf(best) else best


# Closest distance from a point to a triangle, by region test on the triangle's plane basis.
static func _point_triangle_distance(point: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var ab := b - a
	var ac := c - a
	var ap := point - a

	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return ap.length()

	var bp := point - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return bp.length()

	var cp := point - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return cp.length()

	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		var v := d1 / (d1 - d3) if not is_equal_approx(d1, d3) else 0.0
		return (point - (a + ab * v)).length()

	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		var w := d2 / (d2 - d6) if not is_equal_approx(d2, d6) else 0.0
		return (point - (a + ac * w)).length()

	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		var denominator := (d4 - d3) + (d5 - d6)
		var w := (d4 - d3) / denominator if not is_zero_approx(denominator) else 0.0
		return (point - (b + (c - b) * w)).length()

	var denom := va + vb + vc
	if is_zero_approx(denom):
		return ap.length()
	return (point - (a + ab * (vb / denom) + ac * (vc / denom))).length()
