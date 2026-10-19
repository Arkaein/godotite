@tool
@icon("res://addons/godotite/icons/godotite_builder.svg")
class_name GodotiteBuilder
extends Node3D

## Builds a mesh into a Godotite LOD hierarchy, in the editor, for a [GodotiteLOD] to draw.
##
## Set [member source] to the MeshInstance3D holding the mesh and press Regenerate. The build runs
## in the background, with its progress in the Output panel. The first build makes a GodotiteLOD
## next to this node, named after the source, and sets [member output] to it; later builds update
## that node in place. The built [GodotiteDAG] is saved beside the scene, as
## a file of its own in the project's DAG folder (Project Settings, Godotite > Build > DAG
## Folder), so the scene file stays small; see [member dag_path]. [br][br]
##
## Building needs the .NET version of Godot and the project's C# built (the builder warns if not);
## drawing the result does not. This node does nothing in a running game, and the source mesh can
## stay hidden: see [GodotiteUtil] for keeping only its path. [br][br]
##
## [b]Settings:[/b] most meshes need none changed. [member min_cluster_triangles] trades draw
## calls against finer choices of detail. The Advanced group tunes how clusters are made and
## simplified, how seams, outlines and separate pieces are treated, and what the output stores.
## Importing a scene with Build Lod ticked offers the same settings, under the same names.

# Builds a Godotite LOD cluster DAG from a mesh, and hands it to a GodotiteLOD node.
#
# Point Source at the MeshInstance3D holding the mesh and press Regenerate. The import pipeline uses
# the same entry point, build_from_mesh(), with no scene involved. Editor-only: this script does no
# rendering and is not needed in a shipped scene. A Node3D since 2026-10-07: it was a MeshInstance3D,
# holding a copy of the source mesh, which nothing needed any more.
#
# The build itself runs in C# (native/, reached through GodotiteNative). This file is orchestration
# around it: the settings, progress reporting, packing the result into a GodotiteDAG resource, and
# publishing it to a GodotiteLOD. See ALGORITHM.md for how the build works.

## Build the LOD hierarchy from the source mesh and publish it to the Output node. Runs in the
## background, with progress in the Output panel; the settings below are read when it starts.
@export_tool_button("Regenerate", "Reload") var regenerate_action := _trigger_regeneration

## The MeshInstance3D whose mesh is built. The first build hides it, since its LOD now draws it.
## While hidden it lets go of its mesh and keeps only the mesh file's path, so neither the editor nor
## the game loads it with the scene; showing it loads the mesh again. Only a mesh saved in a file of
## its own can be let go of. [br][br]
##
## A script on the source (a mesh generator, say) should not take an empty mesh to mean "not
## generated": a hidden source has none, only the path. [method GodotiteUtil.resolve_mesh] gives
## the mesh either way.
@export_node_path("MeshInstance3D") var source: NodePath:
	set(value):
		source = value
		if is_inside_tree():
			_watch_source()
		update_configuration_warnings()

## The GodotiteLOD node a build is published to, updated in place: it keeps its place in the scene,
## its name and its settings. Left empty, the first build makes one right after this node, named
## after the source with "LOD" added, and sets this to it. Builders each have their own, so several
## can share a parent.
@export_node_path("GodotiteLOD") var output: NodePath

## The file the DAG is saved to. Leave empty: the first build names a new file in the project's DAG
## folder (Project Settings, Godotite > Build > DAG Folder), after the scene, the LOD node and the
## DAG's UID, and later builds overwrite the file the Output already uses, wherever it has been
## moved since. Set a path to choose the file yourself.
@export_file("*.res") var dag_path: String = ""

## Overrides the material of every generated cluster. Leave empty to keep the source mesh's own
## materials; set one for debug shading.
@export var material: Material = null

## The fewest triangles in a leaf cluster. Larger clusters mean fewer draw calls and cheaper
## selection; smaller ones a finer-grained choice of detail. 4096 suits most meshes. 0 picks a size
## from the mesh, between 4096 and 8192, aiming for about a thousand clusters.
@export_range(0, 16384, 1, "or_greater") var min_cluster_triangles: int = 4096:
	set(value):
		# Negative is meaningless and would produce a single cluster holding everything.
		min_cluster_triangles = maxi(value, 0)

@export_group("Advanced")

@export_subgroup("Clusters")

## Meshes with more triangles than this are built in cells of at most this many, so build memory
## follows the cell size rather than the whole mesh: about 1.5 GB plus 0.2 KB per source triangle at
## the default. The result is as deterministic; cell borders keep a thin line of full detail until
## the cells are merged. 0 always builds the mesh whole.
@export var cell_triangles: int = 4_000_000:
	set(value):
		cell_triangles = maxi(value, 0)

## How strongly clustering keeps each cluster to one material, since a cluster spanning two
## materials costs an extra draw call. 0 ignores materials.
@export var material_split_penalty: float = 0.05

## How strongly clustering prefers compact clusters with short borders. Cluster borders are
## locked while simplifying, so shorter borders simplify further. 0 clusters by bounding box alone.
@export var boundary_edge_weight: float = 0.05

@export_subgroup("Error Weights")

## How costly it is to simplify across a UV or normal seam, against moving the surface. Higher keeps
## seams detailed for longer. 0 ignores seams.
@export var attribute_weight: float = 8.0

## How costly it is to stretch or skew the texture mapping while simplifying. Higher keeps textures
## cleaner, for more triangles. 0 prices the shape alone.
@export var uv_distortion_weight: float = 1.0

## The most one simplification step may change a triangle's texel density, as a factor; steps beyond
## it are refused. Lower protects texturing and simplifies less. 0 turns the test off.
@export var uv_density_limit: float = 4.0

## How costly changes to the custom vertex channels (CUSTOM0–3) are while simplifying: for example
## material blend weights, where a change moves a visible border. At 1, swapping a value completely
## across an edge costs about as much as moving the surface by that edge's length. 0 ignores them.
@export var custom_attribute_weight: float = 0.5

## Like Custom Attribute Weight, for vertex colour. Negative uses Custom Attribute Weight. Set 0 when
## the colour channel holds data rather than visible colour.
@export var color_attribute_weight: float = -1.0

@export_subgroup("Boundaries")

## Let UV and normal seams lose vertices along their length; the seam itself is always kept. Off pins
## every seam at full detail through every level, which makes the coarsest levels far heavier.
@export var coarsen_seam_curves: bool = true

## Let the mesh's open outlines (edges with nothing on the other side) simplify, priced by how far
## the outline moves. Off keeps every outline at full detail.
@export var coarsen_mesh_boundaries: bool = true

@export_subgroup("Disconnected Pieces")

## Let clusters gather pieces of the mesh that share no edges. Needed for meshes made of many
## separate parts, as most authored scenes are: without it each small piece is a cluster of its own
## and little simplifies.
@export var bridge_disconnected: bool = true

## How far a cluster may reach for an unconnected triangle, as a multiple of its own size. Keeps
## bridged clusters compact.
@export var bridge_jump_radius: float = 1.0

## Let separate pieces disappear at a distance, once a whole piece is smaller than the error its
## level already allows. Only whole pieces go, so no holes open.
@export var drop_small_components: bool = true

## The largest piece that may be dropped, as a share of its group's size. A dropped piece's size is
## added to its cluster's error, so it only vanishes where it would be under the error threshold
## anyway.
@export var drop_component_fraction: float = 0.25

@export_subgroup("Output")

## Store cluster meshes with Godot's vertex compression: about 29 instead of 46 bytes of video memory
## per source triangle, and crack-free. Turn off only to compare.
@export var compress_vertices: bool = true

## Give clusters tangents, which normal-mapped materials need; generated where the source has none.
## Costs no video memory and a little build memory.
@export var include_tangents: bool = true

## Also make one MeshInstance3D per cluster, to select and inspect in the editor. Slow and heavy for
## large meshes: for small ones only.
@export var create_debug_nodes: bool = false

@export_group("")

# The name of a LOD node the first build makes, before it is renamed after the source.
const _LOD_NODE_NAME := "GodotiteLOD"

# How many neighbouring clusters are merged, simplified and split again at each level: 4, as Nanite
# uses. A setting until 2026-10-16, removed because no other value was ever worth having: 2 turns
# the hierarchy into a binary tree, 3 measured worse seam density, 6 too coarse a root and too few
# levels (GODOTITE_HISTORY.md, Phase 4), and the adaptive re-split is tuned around 4.
const _CLUSTER_GROUP_SIZE := 4

# Loaded by path, not by class name: a [GlobalClass] name resolves through the editor's class cache,
# which a headless run does not have, and the addon has to work in both.
const _NATIVE_SCRIPT_PATH := "res://addons/godotite/native/GodotiteNative.cs"

# Timestamped output. Preloaded by path rather than by class name, like the other tools here, so a
# stale editor class cache cannot break the builder.
const _Log := preload("res://addons/godotite/godotite_log.gd")

# Shortest gap between progress lines, in microseconds.
#
# A build can run for minutes with no way to tell working from hung, so silence is genuinely
# ambiguous. Two seconds is often enough to show life without
# the output becoming the slow part — the per-cluster line this replaces printed 1072 times on
# Sponza and 3000+ on a detail-256 sphere.
const _PROGRESS_INTERVAL_USEC := 2_000_000

var _progress_last_usec: int = 0
var _build_started_usec: int = 0

# Poll interval of the blocking build, in milliseconds. Short enough that progress lines are not
# visibly late, long enough that polling costs nothing measurable.
const _BLOCKING_POLL_MSEC := 20

# Time per editor frame spent baking finished cluster meshes during an async build. Baking as the
# build goes frees each cluster's prepared arrays early; a small budget keeps the editor responsive.
const _ASYNC_BAKE_MSEC := 4.0

# True while a background build (Regenerate) is running, so a second press cannot start another.
var _building := false

# The mesh being built, for its materials; let go once the build is published.
var _source_mesh: Mesh = null

# Cluster size in force for the current build, resolved once from `min_cluster_triangles` (which
# may be 0, meaning derive it) and passed to the native builder.
var _cluster_target: int = 4096


# Prints at most one line per _PROGRESS_INTERVAL_USEC. `force` bypasses the throttle, for the line
# that closes a stage out.
func _progress(message: String, force: bool = false) -> void:
	var now := Time.get_ticks_usec()
	if not force and now - _progress_last_usec < _PROGRESS_INTERVAL_USEC:
		return
	_progress_last_usec = now
	_Log.log("[godotite] " + message)


# Node that should own generated cluster nodes, when there is no edited scene to ask.
#
# The import pipeline builds outside any scene, so `get_tree().edited_scene_root` is null there and
# unowned nodes would simply vanish when the result is packed.
var _owner_override: Node = null

# Absolute tolerance for welding positions, as used by the C# builder (GodotiteMesh.WeldTolerance)
# — the two must agree. Kept here because the validator reads it to recognise welded vertices.
## The project setting holding the folder new DAG files are saved in, and its default.
const DAG_FOLDER_SETTING := "godotite/build/dag_folder"
## The folder new DAG files are saved in when the project does not set one.
const DEFAULT_DAG_FOLDER := "res://godotite_generated/"

## The distance within which the builder treats two vertex positions as the same.
const WELD_TOLERANCE := 0.001

# Cluster count the derivation aims for, and the range it may pick a size from.
#
# The bounds are the measured-good range: 4096 and 8192 were within a few percent of each other in
# the cluster size sweep, and everything smaller was worse on every axis. So the derivation only
# steps up to 8192 once a mesh is large enough (~8M triangles) that holding the cluster count down
# is worth the coarser cut.
const _DERIVED_TARGET_CLUSTERS := 1000
# The smallest cluster size a derived Min Cluster Triangles picks.
const _DERIVED_MIN_CLUSTER_TRIANGLES := 4096
# The largest cluster size a derived Min Cluster Triangles picks.
const _DERIVED_MAX_CLUSTER_TRIANGLES := 8192


## The mesh to build from: the source node's, held or loaded from its path.
func resolve_source_mesh() -> Mesh:
	var source_node := get_source_node()
	return GodotiteUtil.resolve_mesh(source_node) if source_node != null else null


## The resolved source node, or null when [member source] is unset or no longer points anywhere.
func get_source_node() -> MeshInstance3D:
	if source.is_empty():
		return null
	return get_node_or_null(source) as MeshInstance3D


## The resolved output node, or null when [member output] is unset or no longer points at a GodotiteLOD.
func get_output_node() -> GodotiteLOD:
	if output.is_empty():
		return null
	return get_node_or_null(output) as GodotiteLOD


func _ready() -> void:
	if Engine.is_editor_hint():
		_watch_source()


# The source holds its mesh only while visible, as the hollow world's terrain always has: the
# visibility_changed signal keeps the two in step, and a newly watched source is put in step at once.
var _watched_source: MeshInstance3D = null


func _watch_source() -> void:
	if not Engine.is_editor_hint():
		return
	if is_instance_valid(_watched_source) \
			and _watched_source.visibility_changed.is_connected(_sync_source_mesh):
		_watched_source.visibility_changed.disconnect(_sync_source_mesh)
	_watched_source = get_source_node()
	if _watched_source != null:
		_watched_source.visibility_changed.connect(_sync_source_mesh)
		_sync_source_mesh()


func _sync_source_mesh() -> void:
	var node := get_source_node()
	if node == null:
		return
	if not node.visible:
		GodotiteUtil.release_mesh(node)
	elif node.mesh == null and node.has_meta(GodotiteUtil.MESH_PATH_META):
		node.mesh = GodotiteUtil.resolve_mesh(node)
	update_configuration_warnings()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if source.is_empty():
		warnings.append("Set 'Source' to the MeshInstance3D holding the mesh to build from.")
	elif get_source_node() == null:
		warnings.append("'Source' does not resolve to a MeshInstance3D.")
	elif get_source_node().mesh == null \
			and not get_source_node().has_meta(GodotiteUtil.MESH_PATH_META):
		warnings.append("Source is set but has no mesh yet.")
	var problem := native_problem()
	if not problem.is_empty():
		warnings.append(problem)
	var source_node := get_source_node()
	if source_node != null and source_node.mesh != null:
		if not GodotiteUtil.is_reloadable(source_node.mesh):
			warnings.append("The source mesh is stored in the scene, so the scene always loads it. "
					+ "Save it to a file of its own (the Mesh property's menu > Save As...) so that, "
					+ "hidden, the source keeps only its path.")
		var triangles := 0
		for surface in source_node.mesh.get_surface_count():
			@warning_ignore("integer_division")
			triangles += source_node.mesh.surface_get_array_index_len(surface) / 3
		if triangles > 0 and triangles < GodotiteConverter.MIN_SOURCE_TRIANGLES:
			warnings.append(("The source has %d triangles. Godotite pays off on large meshes, from "
					+ "about 130,000 triangles; a smaller one is usually cheaper drawn as it is.")
					% triangles)
	var output_node := get_output_node()
	if output_node != null and output_node.dag != null and not output_node.dag.format_problem().is_empty():
		warnings.append("The Output's DAG: " + output_node.dag.format_problem())
	if output_node != null and source_node != null and source_node.visible \
			and output_node.visible and output_node.dag != null:
		warnings.append("The source and its LOD both draw. Hide the source: hidden, it lets go of "
				+ "its mesh, and shown again it loads it, to compare with the LOD.")
	if output_node != null and output_node.is_dag_missing():
		warnings.append("The Output's DAG file is missing (%s): press Regenerate."
				% output_node.resolved_dag_path())
	return warnings


# Why the C# builder cannot run, or "" if it can. Checked quietly: loading a C# script needs a .NET
# build of Godot, and the script has no methods until the project's C# is built.
## Why this project cannot build, or "" if it can: building needs the .NET version of
## Godot and the project's C# built. Shown as a warning on the node, and as the error a build fails
## with.
static func native_problem() -> String:
	if not ClassDB.class_exists("CSharpScript") or not ResourceLoader.exists(_NATIVE_SCRIPT_PATH):
		return "Building needs the .NET (C#) version of Godot. Running a built LOD does not."
	var script := load(_NATIVE_SCRIPT_PATH) as Script
	if script == null or script.get_script_method_list().is_empty():
		return "Building needs the project's C# built: press Build (the hammer) at the top right of " \
				+ "the editor, or run 'dotnet build' in the project folder. Make a C# script first " \
				+ "(Project > Tools > C# > Create C# solution) if the project has no C# yet."
	return ""


# The material for generated cluster meshes, in priority order: the exported 'material', then
# whatever the source mesh already uses. The fallback preserves the original behavior when the
# export is left unset.
func _resolve_material() -> Material:
	if material != null:
		return material
	return _source_mesh.surface_get_material(0) if _source_mesh != null else null


func _trigger_regeneration() -> void:
	await build_dag()


# The cluster size this build will actually use: `min_cluster_triangles`, or a derived value when
# that is 0.
#
# Derived to keep the cluster count near _DERIVED_TARGET_CLUSTERS, so a 262k-triangle model and a
# 10M-triangle one produce comparably sized DAGs instead of the latter producing forty times as
# many clusters.
## The cluster size a build of a mesh with this many triangles uses: Min Cluster Triangles, or
## when that is 0, a size between 4096 and 8192 chosen to give about a thousand clusters.
func resolved_min_cluster_triangles(triangle_count: int) -> int:
	if min_cluster_triangles > 0:
		return min_cluster_triangles
	@warning_ignore("integer_division")
	return clampi(triangle_count / _DERIVED_TARGET_CLUSTERS, _DERIVED_MIN_CLUSTER_TRIANGLES,
			_DERIVED_MAX_CLUSTER_TRIANGLES)


# Build a complete LOD from a mesh, with no scene, no tree and no editor involved.
#
# This is the entry point the import pipeline uses. It blocks until the build is done, but the
# build itself runs on a worker thread and this thread prints its progress as it goes, so a long
# build still reports live on stdout. In the editor the Output panel cannot redraw until an import
# returns — see import_plugin.gd. The Regenerate button runs the same build through
# build_from_mesh_async(), which keeps the editor responsive instead; the result is identical.
#
# Returns the packed DAG, cluster geometry included, and the source materials — or an empty
# dictionary if the mesh is empty or the C# assembly is not built.
## Builds a LOD hierarchy from a mesh and returns it, with no scene or editor needed: what the
## importer runs. Blocks until done (the build runs on a worker thread and prints progress as it
## goes). Returns the packed DAG and the source materials, or an empty dictionary if the mesh is
## empty or building is unavailable (see [method native_problem]). The settings are this node's.
func build_from_mesh(source_mesh: ArrayMesh) -> Dictionary:
	var native = _start_build(source_mesh)
	if native == null:
		return {}
	while native.IsBuilding():
		_report_progress(native)
		native.BakeReady(_BLOCKING_POLL_MSEC)
		OS.delay_msec(_BLOCKING_POLL_MSEC)
	return _finish_build(native)


# build_from_mesh(), without blocking: waits a frame between progress checks, so the editor keeps
# running and the Output panel shows progress as it happens. Needs the node in a tree.
## [method build_from_mesh] without blocking: await it. Checks progress once a frame, so the
## editor stays responsive. Needs the node in the tree.
func build_from_mesh_async(source_mesh: ArrayMesh) -> Dictionary:
	var native = _start_build(source_mesh)
	if native == null:
		return {}
	while native.IsBuilding():
		_report_progress(native)
		native.BakeReady(_ASYNC_BAKE_MSEC)
		await get_tree().process_frame
	return _finish_build(native)


# Starts the C# build on a worker thread and returns the builder object to poll, or null if there
# is nothing to build or the C# assembly is unavailable. Godotite needs a .NET build of Godot and
# a built solution; there is no other builder to fall back to.
func _start_build(source_mesh: ArrayMesh) -> Object:
	if source_mesh == null or source_mesh.get_surface_count() == 0:
		return null
	var problem := native_problem()
	if not problem.is_empty():
		push_error("Godotite: " + problem)
		return null
	var script = load(_NATIVE_SCRIPT_PATH)
	_source_mesh = source_mesh

	var source_triangles := 0
	for surface in range(source_mesh.get_surface_count()):
		var indices = source_mesh.surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
		source_triangles += (indices.size() if indices != null else 0) / 3
	_cluster_target = resolved_min_cluster_triangles(source_triangles)
	_build_started_usec = Time.get_ticks_usec()
	_progress_last_usec = _build_started_usec
	_progress("build starting: %d triangles, %d surface(s), %d per cluster%s"
			% [ source_triangles, source_mesh.get_surface_count(), _cluster_target,
				" (derived)" if min_cluster_triangles <= 0 else "" ], true)

	var native = script.new()
	native.StartBuild(source_mesh, attribute_weight, uv_distortion_weight, _cluster_target,
			material_split_penalty, boundary_edge_weight, bridge_disconnected, bridge_jump_radius,
			_CLUSTER_GROUP_SIZE, drop_small_components, drop_component_fraction, coarsen_seam_curves,
			coarsen_mesh_boundaries, uv_density_limit, include_tangents, custom_attribute_weight,
			color_attribute_weight, cell_triangles)
	return native


# Prints what the build has reported since the last call: every stage and level message, and the
# step in progress (done/total) at most once per _PROGRESS_INTERVAL_USEC.
func _report_progress(native: Object) -> void:
	for message in native.TakeMessages():
		_progress(message, true)
	var line: String = native.ProgressLine()
	if not line.is_empty():
		_progress(line)


# Collects a finished build: reports its last messages, then bakes the cluster meshes and packs
# the DAG, on this thread, since both create engine resources.
func _finish_build(native: Object) -> Dictionary:
	var error: String = native.FinishBuild()
	_report_progress(native)
	if not error.is_empty():
		push_error("Godotite: the build failed: " + error)
		return {}
	_progress("baking the remaining cluster meshes and packing", true)
	var packed_data: Dictionary = native.PackDag()
	if packed_data.is_empty():
		push_error("Godotite: the C# builder produced no DAG.")
		return {}
	if compress_vertices:
		_progress("compressing cluster meshes", true)
		var kept: Vector2i = native.CompressMeshes(packed_data["meshes"])
		_progress(("compressed %d of %d cluster meshes, the coarsest and any tiny ones left as they "
				+ "were; %d surfaces kept uncompressed, whose normals or tangents Godot's encoding gets "
				+ "wrong")
				% [ packed_data["meshes"].size() - kept.x, packed_data["meshes"].size(), kept.y ], true)
	var built := {
		"dag": _pack_dag_from_native(packed_data),
		"materials": _collect_source_materials(),
	}
	_progress("build finished in %.1f s" % [
			(Time.get_ticks_usec() - _build_started_usec) / 1000000.0 ], true)
	return built


# Copies the native builder's flat arrays into a GodotiteDAG; GodotiteDAG.fill() says why it is
# the DAG that does the copying.
func _pack_dag_from_native(data: Dictionary) -> GodotiteDAG:
	var packed := GodotiteDAG.new()
	packed.fill(data)
	return packed


# Assemble a GodotiteLOD holding a built DAG, ready to be packed as a scene.
#
# The nodes are owned by the LOD node itself rather than by an edited scene root, so the result can
# be handed straight to PackedScene.pack(). That is the one thing the in-scene path does
# differently, and the reason it needs `_owner_override`.
## Makes a GodotiteLOD holding a built DAG (from [method build_from_mesh]), owning its own
## children, so it can be packed into a scene as it is.
func assemble_lod_node(built: Dictionary) -> GodotiteLOD:
	var lod_node := GodotiteLOD.new()
	lod_node.name = _LOD_NODE_NAME
	lod_node.use_rendering_server = not create_debug_nodes
	lod_node.dag = built["dag"]
	lod_node.materials = built["materials"]
	lod_node.material = null if lod_node.materials.size() > 1 else _resolve_material()

	var previous_override := _owner_override
	_owner_override = lod_node
	if create_debug_nodes:
		_build_cluster_nodes(lod_node, built["dag"])
		_annotate_level_nodes(lod_node, built["dag"])
	_owner_override = previous_override

	# The cluster nodes keep their meshes. Stripping them the way the editor's PRE_SAVE hook does was
	# tried and removed: a node's `mesh` and `dag.meshes[i]` are the SAME object, so the serialiser
	# writes the geometry once and references it from both. Measured at 4.248 MB stripped against
	# 4.265 MB not — the 17 KB difference is the property lines themselves, nothing more. The hook
	# earns its keep only because it keeps geometry out of a hand-edited `.tscn` entirely, which is
	# not what an imported scene is.
	return lod_node


# --- OFFLINE DAG BUILDING ---

## Builds the hierarchy from the source mesh in the background and publishes it to the Output node,
## as Regenerate does; await it to wait for the build. Warns and returns if a build is running.
func build_dag():
	if _building:
		push_warning("Godotite: a build is already running; wait for it to finish.")
		return
	# Always build from the current source, so Regenerate never silently uses a stale copy. A hidden
	# source may hold only its path, so this can load the mesh from disk first.
	# Any Mesh, converted: a PrimitiveMesh (TorusMesh, BoxMesh, ...) is not an ArrayMesh.
	var source_mesh := GodotiteUtil.to_array_mesh(resolve_source_mesh())
	if source_mesh == null:
		push_error("Godotite: no source mesh to build from; set Source to a MeshInstance3D, or "
				+ "generate its mesh first.")
		return

	# Through the same start and finish as build_from_mesh(), so Regenerate and the import pipeline
	# cannot drift apart. Set only after every check above: an error before the build starts must
	# not leave the builder believing one is running.
	_building = true
	var built: Dictionary = await build_from_mesh_async(source_mesh)
	_building = false
	source_mesh = null
	if built.is_empty():
		push_error("Godotite: build produced nothing; is the source mesh empty?")
		return
	# The editor kept running during the build, so the scene may have been closed meanwhile.
	if not is_inside_tree():
		push_warning("Godotite: the builder left the scene during the build; result discarded.")
		return
	_publish_to_lod_node(built)
	_source_mesh = null
	GodotiteUtil.mark_scene_unsaved()


# --- OUTPUT: hand the built DAG to the runtime component ---

# Publish a build to the output node, updating it in place so it keeps its place in the scene, its
# name and its settings; or, with none yet, make one right after this node, named after the source.
func _publish_to_lod_node(built: Dictionary) -> void:
	var lod_node := get_output_node()
	# The LOD's first build: from here the LOD draws the mesh, so the source is hidden (below).
	var first_build := lod_node == null or (lod_node.dag == null and lod_node.dag_file.is_empty())
	if lod_node != null:
		lod_node.clear_rendering()
		# Taken out and put back where it was, so whatever watches for a LOD arriving in the scene
		# (a theme switcher re-theming its materials) sees the new build, as it would a new node.
		var parent := lod_node.get_parent()
		var index := lod_node.get_index()
		parent.remove_child(lod_node)
		parent.add_child(lod_node)
		parent.move_child(lod_node, index)
		_set_editor_owner(lod_node)
	else:
		var parent := get_parent()
		lod_node = GodotiteLOD.new()
		var source_instance := get_source_node()
		lod_node.name = (source_instance.name if source_instance != null else name) + "LOD"
		parent.add_child(lod_node, true)
		parent.move_child(lod_node, get_index() + 1)
		_set_editor_owner(lod_node)
		output = get_path_to(lod_node)

	# The DAG is built from surface_get_arrays(), so every vertex, bounding sphere and error in it is
	# in the source's LOCAL space. Place the LOD node where the source is, or the clusters render
	# wherever its parent happens to be rather than on top of the mesh they came from.
	var source_node := get_source_node()
	if source_node != null:
		lod_node.global_transform = source_node.global_transform
	# Debug nodes only earn their cost if they are what draws: adopting the server backend frees
	# them, so asking for them and getting the server backend would produce nothing but a pause.
	lod_node.use_rendering_server = not create_debug_nodes

	_save_dag_resource(built["dag"], lod_node)
	# After saving, so the node refers to the DAG by its file.
	lod_node.dag = built["dag"]
	lod_node.materials = built["materials"]
	lod_node.material = null if lod_node.materials.size() > 1 else _resolve_material()
	if create_debug_nodes:
		_build_cluster_nodes(lod_node, lod_node.dag)
		_annotate_level_nodes(lod_node, lod_node.dag)
	lod_node.refresh_rendering()
	lod_node.apply_material()

	if first_build and source_node != null and source_node.visible:
		source_node.visible = false
		_progress("hid %s: its LOD draws it now; show it again to compare" % source_node.name, true)

	# Both nodes' warnings may name the DAG (missing, or an old format); nothing else refreshes them.
	lod_node.update_configuration_warnings()
	update_configuration_warnings()

	var packed: GodotiteDAG = lod_node.dag
	_progress("published %d clusters over %d levels to %s"
			% [ packed.cluster_count, packed.levels[packed.root_index] + 1, lod_node.name ], true)


# One material per source surface, so the runtime can bind the right one to each cluster surface.
func _collect_source_materials() -> Array[Material]:
	var found: Array[Material] = []
	if _source_mesh == null:
		return found
	for surface in range(_source_mesh.get_surface_count()):
		found.append(_source_mesh.surface_get_material(surface))
	if found.size() == 1 and found[0] == null:
		found[0] = _resolve_material()
	return found


# Write the DAG — cluster geometry included — to its own binary `.res`, referred to from the scene
# by UID (GodotiteLOD.dag_file).
#
# Without this the whole thing serialises INTO the `.tscn` as sub-resources, which measured at
# 4.28 MB of embedded ArrayMesh text for a 49k-triangle source: 95.5% of the file, and text-encoded
# floats at that.
#
# The file is chosen once, by _dag_target(), and kept: moving or renaming the scene or the node
# then changes nothing, and a rebuild of a missing file writes it where the scene expects it, under
# the UID it expects, so a fresh clone rebuilt is byte-identical to the original.
#
# Follows the convention inner_sphere_mesh.gd already uses for source meshes: `take_over_path` then
# save, rather than setting `resource_path` directly, which makes the editor try to re-save the
# resource whenever the scene is saved.
#
# Editor-only. At runtime there is no edited scene to hang a path off, and nothing to save.
func _save_dag_resource(packed: GodotiteDAG, lod_node: GodotiteLOD) -> void:
	if not Engine.is_editor_hint():
		return
	var root := get_tree().edited_scene_root
	if root == null or root.scene_file_path.is_empty():
		push_warning("Scene has never been saved, so the DAG stays embedded in it. "
				+ "Save the scene and Regenerate to move %d cluster meshes out." % packed.cluster_count)
		return

	var target := _dag_target(lod_node, root)
	var path: String = target.path
	var uid: int = target.uid
	# Never a UID another file already has (a copy of the DAG, say): Godot would warn of the duplicate
	# and could resolve the UID to either file.
	if ResourceUID.has_id(uid) and ResourceUID.get_id_path(uid) != path \
			and FileAccess.file_exists(ResourceUID.get_id_path(uid)):
		uid = ResourceUID.create_id()
	if not DirAccess.dir_exists_absolute(path.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	packed.take_over_path(path)
	var error := ResourceSaver.save(packed)
	if error != OK:
		push_error("Could not save the DAG to %s (error %d); it will be embedded in the scene."
				% [ path, error ])
		return
	ResourceSaver.set_uid(path, uid)
	if ResourceUID.has_id(uid):
		ResourceUID.set_id(uid, path)
	else:
		ResourceUID.add_id(uid, path)
	if Engine.has_singleton("EditorInterface"):
		Engine.get_singleton("EditorInterface").get_resource_filesystem().update_file(path)
	_progress("saved DAG (%d clusters, geometry included) to %s" % [ packed.cluster_count, path ], true)


# Where a build's DAG is saved, and under which UID: dag_path if set; else the file the LOD already
# refers to, even if it is missing (a rebuild restores it, UID and all); else a new file in the DAG
# folder, named after the scene, the LOD and a new UID, which keeps names unique in one flat folder.
func _dag_target(lod_node: GodotiteLOD, root: Node) -> Dictionary:
	var path := ""
	if not dag_path.is_empty():
		path = _uid_to_path(dag_path)
	elif not lod_node.dag_file.is_empty():
		path = lod_node.resolved_dag_path()
	if not path.is_empty():
		var uid := ResourceLoader.get_resource_uid(path) if ResourceLoader.exists(path) \
				else ResourceUID.INVALID_ID
		if uid == ResourceUID.INVALID_ID and path == lod_node.resolved_dag_path() \
				and lod_node.dag_file.begins_with("uid://"):
			uid = ResourceUID.text_to_id(lod_node.dag_file)
		if uid == ResourceUID.INVALID_ID:
			uid = ResourceUID.create_id()
		return { "path": path, "uid": uid }

	var new_uid := ResourceUID.create_id()
	var folder: String = ProjectSettings.get_setting(DAG_FOLDER_SETTING, DEFAULT_DAG_FOLDER)
	var file_name := "%s_%s_%s.res" % [ root.scene_file_path.get_file().get_basename(), lod_node.name,
			ResourceUID.id_to_text(new_uid).trim_prefix("uid://") ]
	return { "path": folder.path_join(file_name), "uid": new_uid }


# A path from a file property, which may hold a UID.
static func _uid_to_path(value: String) -> String:
	if value.begins_with("uid://"):
		var id := ResourceUID.text_to_id(value)
		return ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	return value


# One MeshInstance3D per cluster, under a per-level folder. Each carries its cluster index as
# metadata so GodotiteLOD can rebind after a scene reload without depending on names or ordering.
func _build_cluster_nodes(lod_node: GodotiteLOD, packed: GodotiteDAG) -> void:
	_progress("creating %d cluster nodes" % [ packed.cluster_count ], true)
	var per_level: Dictionary[int, int] = {}
	for i in range(packed.cluster_count):
		# Reported because this stage is slow in a way that looks like a hang: the DAG is already
		# built and saved by now, and what remains is the editor tracking one node per cluster.
		_progress("creating cluster nodes: %d of %d" % [ i, packed.cluster_count ])
		var level: int = packed.levels[i]
		var count: int = per_level.get(level, 0)
		per_level[level] = count + 1

		var node := MeshInstance3D.new()
		node.mesh = packed.meshes[i]
		node.name = "LOD_Level_%d_%d" % [ level, count ]
		node.set_meta("cluster_index", i)
		_get_level_node(lod_node, level).add_child(node)
		_set_editor_owner(node)


# Per-level grouping node, created on demand. Editor organisation only: it gives each LOD level a
# collapsible parent instead of one flat list of siblings.
#
# Looked up by the "lod_level" metadata rather than by node name, because _annotate_level_nodes()
# renames these to carry their coverage and a name lookup would then miss and create a duplicate.
func _get_level_node(lod_node: GodotiteLOD, level: int) -> Node3D:
	for child in lod_node.get_children():
		if child.get_meta("lod_level", -1) == level:
			return child as Node3D
	var level_node := Node3D.new()
	level_node.name = "LOD_Level_%d" % level
	level_node.set_meta("lod_level", level)
	lod_node.add_child(level_node)
	_set_editor_owner(level_node)
	return level_node


# Rename each level folder to "LOD_Level_<n>_<covered>of<total>", counting leaf clusters.
#
# A level is NOT necessarily a usable LOD: a cluster with no merge partner keeps its original level,
# so the clusters sharing a level value do not always tile the mesh. A folder reading "8of12" is one
# of those partial levels; only "12of12" covers the mesh.
func _annotate_level_nodes(lod_node: GodotiteLOD, packed: GodotiteDAG) -> void:
	var total_leaves := 0
	var by_level: Dictionary[int, Array] = {}
	for i in range(packed.cluster_count):
		if packed.child_counts[i] == 0:
			total_leaves += 1
		var level: int = packed.levels[i]
		if not by_level.has(level):
			by_level[level] = []
		by_level[level].append(i)

	for level in by_level:
		var covered: Dictionary = {}
		for index in by_level[level]:
			_collect_covered_leaves(packed, index, covered)
		_get_level_node(lod_node, level).name = "LOD_Level_%d_%dof%d" % [
				level, covered.size(), total_leaves ]


# Which leaf clusters a cluster ultimately covers, walked over the packed child lists.
func _collect_covered_leaves(packed: GodotiteDAG, index: int, acc: Dictionary) -> void:
	if packed.child_counts[index] == 0:
		acc[index] = true
		return
	for child in packed.children_of(index):
		_collect_covered_leaves(packed, child, acc)


# Generated nodes are only owned - and therefore only saved and only visible in the Scene dock -
# when there is an edited scene to own them. At runtime edited_scene_root is null.
func _set_editor_owner(node: Node) -> void:
	if _owner_override != null:
		node.owner = _owner_override
	elif Engine.is_editor_hint():
		node.owner = get_tree().edited_scene_root
