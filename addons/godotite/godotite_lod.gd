@tool
@icon("res://addons/godotite/icons/godotite_lod.svg")
class_name GodotiteLOD
extends Node3D

## Draws a large mesh at the detail the screen needs, from a [GodotiteDAG].
##
## A GodotiteLOD draws a mesh that has been built into clusters: small pieces at full detail, and
## coarser versions of them up to a single root. Every frame it chooses, from the camera, the
## coarsest clusters whose error stays under the error threshold on screen, so nearby parts are
## drawn at full detail and distant ones with far fewer triangles. Neighbouring clusters always meet
## exactly, whatever detail each is drawn at, so no cracks open. [br][br]
##
## [b]Making one:[/b] import a mesh with Build Lod ticked in the Import dock, or add a
## [GodotiteBuilder] to a scene and press Regenerate. Either makes this node and its [member dag].
## This is the only Godotite node a game needs, and it needs no C#. [br][br]
##
## [b]Quality:[/b] the error threshold is the largest error, in pixels, a drawn cluster may show.
## It is set for the whole project in Project Settings (Godotite > LOD > Error Threshold), and at
## runtime with [method set_global_error_threshold], for example from a graphics setting. A node's
## own [member error_threshold] overrides it; leave it at 0 to follow the project. [br][br]
##
## [b]At runtime[/b] clusters are drawn as RenderingServer instances rather than nodes
## ([member use_rendering_server]), and the choice is updated from the last frame's
## ([member incremental_selection]), so its cost follows what changed. [member draw_call_budget]
## can cap draw calls. In the editor, [member editor_preview] makes the viewport show the detail the
## game would. [br][br]
##
## Materials come from the source mesh ([member materials]); [member material] overrides them, for
## example with a debug material. The Debug group and its buttons show what is drawn, check the
## hierarchy ([method validate_dag]) and measure the error actually seen ([method measure_error]).
## The node draws only: it has no collision.


# --- CONFIGURATION ---

# How cluster meshes reach the renderer.
#
# NODES keeps the MeshInstance3D per cluster that the builder produces: visible in the Scene dock,
# individually selectable, and moved by the scene tree for free.
#
# RENDERING_SERVER hands the same meshes to the server directly and frees the nodes. Identical
# geometry and identical draw calls — the win is that a cluster stops costing a Node3D, an
# inspector entry and a transform-propagation slot. Nothing ever moves a cluster independently of
# its neighbours, so that machinery is pure overhead, and at tens of thousands of clusters it is
# the difference between a scene tree that can be walked and one that cannot.
## How cluster meshes reach the renderer; see Use Rendering Server.
enum Backend {
	NODES,             ## One MeshInstance3D per cluster. Always used in the editor.
	RENDERING_SERVER,  ## Server instances, no nodes. Runtime only.
}

## The built cluster hierarchy, meshes included. Set by the builder or the import pipeline. A DAG
## saved in its own file is loaded through [member dag_file] and saved only as that reference; one
## kept inside the scene, as an import keeps it, is saved with the scene.
@export var dag: GodotiteDAG = null:
	set(value):
		dag = value
		# A DAG with its own file is referred to by dag_file, so the scene does not depend on the file
		# existing: missing, the node warns instead of the scene failing to load.
		if value != null and value.resource_path.begins_with("res://") \
				and not value.resource_path.contains("::"):
			var uid := ResourceLoader.get_resource_uid(value.resource_path)
			dag_file_path = value.resource_path
			dag_file = ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID \
					else value.resource_path
		elif value != null:
			dag_file_path = ""
			dag_file = ""
		update_configuration_warnings()

## Where [member dag_file] was last found: the fallback when its UID is unknown, as on a fresh clone
## where the file has not been built yet, and where a rebuild writes it.
@export_storage var dag_file_path: String = ""

## The file this node's DAG is loaded from, as a UID, or a path. Set by the builder; a scene saves
## this reference rather than the DAG, so a missing file (not built yet, or not in version control)
## leaves the node empty with a warning, and the scene still opens. Empty for a DAG kept inside the
## scene.
@export_file("*.res") var dag_file: String = "":
	set(value):
		dag_file = value
		_load_dag_file()
		update_configuration_warnings()

## This node's own error threshold, overriding the project's; 0 uses the project's (Project
## Settings, Godotite > LOD > Error Threshold), as nearly every node should. The threshold is the
## largest error, in pixels on screen, a drawn cluster may show: lower draws more detail. 2 is the
## default, 1 close to full detail, 5 a performance setting.
@export_range(0.0, 100.0, 0.1, "or_greater") var error_threshold: float = 0.0

@export_group("Selection")

## Choose which clusters to draw every frame, from the active camera. Runtime only; in the editor see
## Editor Preview.
@export var auto_update: bool = true

## Update the last frame's choice of clusters rather than choosing from scratch. Cheaper while the
## camera moves smoothly; leave on.
@export var incremental_selection: bool = true

## The most draw calls a frame may take, 0 for no limit. Over it, the error threshold is raised a
## little each frame until the frame fits.
@export var draw_call_budget: int = 0

## In the editor, choose clusters from the viewport's camera as it moves, so the viewport shows the
## detail the game would. Turn off if a very large mesh makes the viewport sluggish.
@export var editor_preview: bool = true

@export_group("Rendering")

## At runtime, draw clusters through the RenderingServer and free their nodes: the same image with
## far less scene-tree overhead. The editor always uses nodes.
@export var use_rendering_server: bool = true

## The render layers its clusters are drawn on, as a VisualInstance3D's Layers: lights and cameras
## whose cull mask leaves them out do not see it.
@export_flags_3d_render var layers: int = 1:
	set(value):
		layers = value
		_apply_layers()

# The source mesh's materials, one per material. Set by the builder.
## The source mesh's materials, one per source surface. Set by the builder.
@export var materials: Array[Material] = []:
	set(value):
		materials = value
		apply_material()

## Overrides every cluster's material, for debug views such as the cluster colour shader. Empty uses
## Materials.
@export var material: Material = null:
	set(value):
		material = value
		apply_material()
		# A newly assigned debug material has none of its uniforms set yet, so without this the
		# cluster view came up with the shader's own defaults — max_level and max_error_fraction at
		# 1.0, which makes the LEVEL and ERROR views wrong — and stayed that way until something else
		# happened to change color_mode. Assigning a material re-establishes the debug state.
		apply_cluster_colors()

@export_group("Debug")

## With a debug colour material, how clusters are tinted: by cluster, by level or by error.
@export var color_mode: ColorMode = ColorMode.CLUSTER:
	set(value):
		color_mode = value
		apply_cluster_colors()

## Saturation of the debug tints.
@export var color_saturation: float = 0.45

## Brightness of the debug tints.
@export var color_value: float = 1.0

## Which clusters Apply Debug View shows: the real choice from the view point, one level, or all.
@export var debug_view: DebugView = DebugView.CUT

## The level the Level debug view shows; 0 is the most detailed.
@export var debug_level: int = 0

## The point the Cut debug view chooses from; set from the editor's camera when Apply Debug View is
## pressed.
@export var debug_view_point := Vector3.ZERO

## Show the clusters Debug View picks. Changing the debug settings does nothing until this is
## pressed.
@export_tool_button("Apply Debug View") var apply_debug_view_action := apply_debug_view

## Check the hierarchy's structure and its cuts, and print a report.
@export_tool_button("Validate DAG") var validate_action := validate_dag

## Sweep the error threshold from the current view and print, for each, the measured screen error,
## triangles and draw calls.
@export_tool_button("Measure Error") var measure_action := measure_error

@export_group("")

# Coarsest the budget may drive the threshold.
const _BUDGET_SCALE_FLOOR := 0.02

# How much of the remaining budget error the controller corrects each frame.
#
# **Proportional, not a fixed rate**, because the two costs pull in opposite directions and a fixed
# rate can only trade one for the other. Big steps every frame make LODs flip while the camera
# moves; small steps take forever to settle once it stops, which is worse — a LOD changing with
# nothing moving has no motion to hide it. Measured both ways: 8% per frame settled in about 4
# frames but swapped up to 30 clusters at once, and 1% per frame cut that to baseline churn but
# then took ~98 frames to stop adjusting after the camera parked.
#
# Sizing the step by how far off budget we are gets both. Far out it converges in a handful of
# frames; near the target the steps become tiny on their own.
#
# Tuned against three measurements at once, because two of them pull opposite ways — a higher gain
# settles faster but flips more clusters while the camera moves. 0.3 with a 5% cap settles in 24
# frames against 98, and reverses FEWER clusters than the fixed rate did (147 against 157).
#
# Surfaces turn out to be close to LINEAR in the threshold scale — measured 90.6, 42.4 and 21.8
# surfaces at scales 1.0, 0.495 and 0.219 — so `target / average` is a direct estimate of the
# correction needed, and the gain is just how much of it to take per frame.
const _BUDGET_GAIN := 0.3

# Largest fraction the threshold scale may move in one frame, whatever the error. Bounds how many
# clusters a single correction can flip at once, which is the failure mode of a fast fixed rate.
const _BUDGET_MAX_STEP := 0.05

# Fraction of the budget below which the controller starts relaxing again.
#
# Wide on purpose, so the controller spends most of its time doing NOTHING. Every frame it moves the
# threshold it drags the global LOD boundary across clusters independently of camera motion, and a
# cluster sitting near that boundary gets pushed over and pulled back. With a 10% band it nudged
# almost every frame: measured at 460 of those reversals across 34 clusters over 600 frames,
# against 2 with no budget at all. An idle controller cannot cause any.
const _BUDGET_DEADBAND := 0.75

# Frames of `drawn_surfaces` averaged before the controller reacts, so a one-frame spike does not
# move the threshold for the whole mesh.
const _BUDGET_SMOOTHING_FRAMES := 8

# How far the view point may still move before ANY cluster in the cut could change decision: the
# smallest slack in the cut, spent down as the camera travels. Zero forces a full update.
var _slack_floor: float = 0.0

# Camera travel accumulated while the floor held, owed to every cluster's slack on the next real
# pass. Without it the floor and the per-cluster budgets drift apart and the cut stops updating.
var _pending_travel: float = 0.0

# Effective-threshold multiplier maintained by draw_call_budget. Below 1.0 means coarsening.
var _budget_scale := 1.0
# Latch so an unmeetable budget is reported once rather than every frame.
var _budget_exhausted := false
# Running mean of drawn_surfaces, the controller's actual input.
var _budget_average := 0.0

# Clamp on the distance used to project error, so a cluster containing the view point does not
# divide by zero and select as if infinitely detailed.
## The least distance error is projected over, so a cluster around the camera does not divide by
## zero.
const MIN_PROJECTION_DISTANCE := 0.01

# Refine/merge passes select_cut_incremental() will run before giving up. A single frame's motion
# needs one or two; the cap only exists so a bug cannot hang the frame.
const _MAX_INCREMENTAL_PASSES := 16

# Slack value meaning "evaluate this cluster on the next incremental pass".
const _NEEDS_RETEST := -1.0

# Loaded by PATH, not by class name, on purpose.
#
# The tools behind Validate DAG and Measure Error, and the timestamped log they write to, loaded by
# path when a button is pressed: never a dependency of this script, which a game needs on its own.
# Exporting selected scenes does not follow a script's preloads, so a preload here left the exported
# game unable to compile this script, and nothing drew. And by path, not class name: a
# `class_name` resolves through the editor's global class cache, and a stale cache breaks this whole
# script, which then stops running `_notification`, disabling the save hook below and letting
# 4.3 MB of geometry back into the scene. That happened once.
const _MEASURE_PATH := "res://addons/godotite/tools/godotite_measure.gd"
const _VALIDATOR_PATH := "res://addons/godotite/tools/godotite_validate.gd"
const _LOG_PATH := "res://addons/godotite/godotite_log.gd"


# --- CLUSTER VISUALISATION ---

# The values are pushed straight into cluster_debug.gdshader's `color_mode` uniform, so the enum
# order is part of the contract. The shader reads the debug channel the builder bakes into the
# cluster meshes (GodotiteDAG.debug_channel).
## How a debug colour material (the addon's [code]tools/cluster_debug.gdshader[/code]) tints the
## clusters.
enum ColorMode {
	NONE,     ## Leave the material's own colour alone.
	CLUSTER,  ## A distinct hue per cluster. The "which cluster am I looking at" view.
	LEVEL,    ## Hue by LOD level, so a mixed cut shows where detail changes.
	ERROR,    ## Blue (accurate) to red (coarse), by the cluster's simplification error.
}


# --- DEBUG VIEW ---
# One-shot visibility control, applied only when the button is pressed rather than per frame, so
# manually toggling individual cluster meshes keeps working until the next press.

## Which clusters Apply Debug View shows.
enum DebugView {
	CUT,    ## A valid mixed-LOD cut, selected from debug_view_point against the error threshold.
	LEVEL,  ## Only clusters at debug_level. A level may not cover the whole mesh.
	ALL,    ## Every cluster at once, all levels overlapping.
}

# cluster index -> its MeshInstance3D. Rebuilt from node metadata on load; never serialised.
# Empty once the RENDERING_SERVER backend has been adopted and the nodes freed.
var _render_nodes: Array[MeshInstance3D] = []

var _backend: Backend = Backend.NODES

# Valid only under RENDERING_SERVER. The mesh references are load-bearing, not bookkeeping: freeing
# a MeshInstance3D drops the last reference to its ArrayMesh, and the instance's base RID dies with
# it. The transforms are each cluster's offset from this node, so instances can follow it when it
# moves — a Node3D child did that for free, a server instance does not.
var _instances: Array[RID] = []
var _meshes: Array[Mesh] = []
var _local_transforms: Array[Transform3D] = []
var _tree_visible := true

# Which clusters are currently drawn. THE source of truth: both backends are views onto this, so
# is_drawn(), the validator and the cut bitstring read the same answer under either one, and a
# backend cannot silently disagree with the selection that produced it.
var _visible := PackedByteArray()

# The cut drawn by the last select_cut(), so the next one can clear it without touching every
# cluster. _drawn_valid goes false whenever something else changes visibility behind our back.
var _drawn: Array[int] = []
var _drawn_valid := false

# cluster -> the clusters of the group it was folded into, i.e. its parents in the DAG. Derived from
# child_indices at bind time rather than stored, because it is pure redundancy in the resource.
#
# Needed only by the incremental selector, which has to walk UP to merge a group back into its
# coarser form. The descent only ever needs children.
var _parents: Array[PackedInt32Array] = []

# How far the view point may still move before a drawn cluster's decision could change.
#
# Every distance used in selection is 1-Lipschitz in the view point — move the camera by d and no
# distance changes by more than d — so a cluster sitting `s` away from flipping is safe for `s` of
# camera travel, whatever direction it takes. Subtracting the frame's movement is a float op per cut
# member; re-testing one is a shell distance, two divisions and a walk over its parents, which is
# far dearer. That difference is the whole point: the cut is large, the part of it near a threshold
# is not.
#
# _NEEDS_RETEST forces a member to be evaluated on the next pass.
var _slack := PackedFloat32Array()
var _last_view := Vector3.ZERO
var _last_threshold := -1.0
var _last_scale := -1.0

# Stats for the last selection, accumulated during the descent so reading them costs nothing.
## Clusters drawn by the last selection.
var drawn_clusters: int = 0
## The actual draw-call count for the cut. A cluster carries one surface per material it contains,
## so surfaces exceed clusters wherever clustering straddles a material border.
var drawn_surfaces: int = 0
## Triangles drawn by the last selection.
var drawn_triangles: int = 0
# Clusters popped off the descent stack for the last selection, i.e. what the traversal actually
# cost. Compare against drawn_clusters: the gap is the overhead pruning has not removed, and
# against half of it, which is what a group-level tree could hope to reach.
## Clusters the last selection visited: its cost, against drawn_clusters for what it drew.
var last_visited: int = 0
## How long the last selection took, in microseconds.
var last_select_usec: int = 0
var _full_detail_triangles: int = -1

# How often the editor preview may re-cut while the camera is moving.
const _EDITOR_PREVIEW_HZ := 15

# The project setting holding the error threshold every node without its own uses, and its default.
# Registered by the plugin; a game without the plugin reads the default.
## The project setting holding the error threshold of every node without its own. The plugin
## registers it; without it, [constant DEFAULT_ERROR_THRESHOLD] applies.
const ERROR_THRESHOLD_SETTING := "godotite/lod/error_threshold"
## The project's error threshold when the setting is not set: 2 pixels.
const DEFAULT_ERROR_THRESHOLD := 2.0

# Set by set_global_error_threshold(), replacing the project setting for this run; NAN when unset.
static var _global_error_threshold := NAN

# The threshold of the selection in progress, resolved once per selection by
# effective_error_threshold().
var _threshold := DEFAULT_ERROR_THRESHOLD

var _editor_camera := Transform3D()
var _editor_next_usec: int = 0

# The full-detail vertices Measure Error measures at most, evenly spaced: enough for a max and
# percentiles that hold, few enough that a large mesh measures in seconds.
const _MEASURE_SAMPLES := 20_000

# True while Validate DAG or Measure Error runs: they work across several frames, during which the
# editor preview must not change the cut under them, nor a second press start another.
var _tool_running := false


func _ready() -> void:
	if dag == null and not dag_file.is_empty():
		push_warning("Godotite: %s: %s" % [ name, missing_dag_message() ])
	refresh_rendering()
	apply_material()
	apply_cluster_colors()


## The error threshold every node without its own uses: the project setting, or the value given to
## set_global_error_threshold().
static func get_global_error_threshold() -> float:
	if not is_nan(_global_error_threshold):
		return _global_error_threshold
	return ProjectSettings.get_setting(ERROR_THRESHOLD_SETTING, DEFAULT_ERROR_THRESHOLD)


## Sets the error threshold of every node without its own, for this run only (the project setting is
## left alone): the one call a graphics-quality setting needs. Takes effect on the next selection.
static func set_global_error_threshold(value: float) -> void:
	_global_error_threshold = value


## The error threshold this node selects with: its own if set, otherwise the global one.
func effective_error_threshold() -> float:
	return error_threshold if error_threshold > 0.0 else get_global_error_threshold()


func _get_configuration_warnings() -> PackedStringArray:
	if dag == null and not dag_file.is_empty():
		return PackedStringArray([ missing_dag_message() ])
	if dag == null:
		return PackedStringArray([ "No DAG to draw. Build one with a GodotiteBuilder (Regenerate), or "
				+ "import a mesh with Build Lod ticked in the Import dock." ])
	if not dag.format_problem().is_empty():
		return PackedStringArray([ "The DAG cannot be drawn. " + dag.format_problem() ])
	return PackedStringArray()


# Bind to the DAG and bring the chosen backend up.
#
# Public because the builder assigns `dag` AFTER adding this node to the tree — `_ready()` has
# already run by then, against a null DAG, so something has to bring rendering up afterwards. That
# was invisible while the node backend was the only one the editor used, because binding was called
# explicitly and needed no second step; with RenderingServer it meant nothing was drawn at all.
#
# Safe to call repeatedly: adoption frees whatever it allocated last time.
## The path [member dag_file] refers to: the file its UID names, or the last path it was found at
## when the UID is unknown. Empty when there is no file reference.
func resolved_dag_path() -> String:
	return resolve_dag_reference(dag_file, dag_file_path)


## The path a [member dag_file] and [member dag_file_path] pair refers to, as
## [method resolved_dag_path] gives it; for tools reading saved scenes without loading them.
static func resolve_dag_reference(file: String, fallback_path: String) -> String:
	if file.begins_with("uid://"):
		var id := ResourceUID.text_to_id(file)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
		return fallback_path
	return file


## Whether [member dag_file] names a file that does not exist.
func is_dag_missing() -> bool:
	return not dag_file.is_empty() and not ResourceLoader.exists(resolved_dag_path())


## What to do about a missing DAG file.
func missing_dag_message() -> String:
	return ("DAG file missing (%s). Press Regenerate on the GodotiteBuilder that makes it, or run "
			+ "Project > Tools > Godotite: Rebuild Missing DAGs.") % resolved_dag_path()


# Loads the file dag_file refers to, unless it is the DAG already held. A missing file leaves the
# DAG unset, and the configuration warning says so.
func _load_dag_file() -> void:
	if dag_file.is_empty():
		return
	var path := resolved_dag_path()
	if dag != null and dag.resource_path == path:
		return
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	dag = load(path) as GodotiteDAG


# A DAG with its own file is saved as dag_file alone.
func _validate_property(property: Dictionary) -> void:
	if property.name == "dag" and not dag_file.is_empty():
		property.usage &= ~PROPERTY_USAGE_STORAGE


## Binds to the DAG and starts drawing it. Called when the node enters the tree; call it after
## assigning a DAG to a node already in the tree. Safe to call repeatedly.
func refresh_rendering() -> void:
	# An unreadable format draws nothing (is_valid() is false), so say why rather than stay blank.
	if dag != null and not dag.format_problem().is_empty():
		push_error("Godotite: %s cannot draw its DAG. %s" % [ name, dag.format_problem() ])
	bind_render_nodes()
	# The editor used to be excluded from the server backend, which made cluster nodes the editor's
	# renderer and impossible to dispense with. Both now run the same backend, so a scene needs no
	# per-cluster nodes and the DAG is the single source of truth for what is drawn.
	if use_rendering_server:
		_adopt_rendering_server()

	# Pick a cut immediately in the editor, or nothing is drawn there at all.
	#
	# `_process()` returns early under is_editor_hint(), so the editor never selects one on its own.
	# That was invisible while cluster nodes were the editor's renderer — a saved node is visible by
	# default, and binding seeded visibility from the nodes — but every server instance starts
	# hidden, so an imported scene showed an empty viewport until something called select_cut().
	#
	# From `debug_view_point` rather than the editor camera: this is runtime code, and reaching for
	# EditorInterface here would tie it to an editor API for a one-off. Press Apply Debug View to
	# re-cut from wherever the camera actually is.
	if Engine.is_editor_hint() and dag != null and dag.is_valid():
		var camera := get_active_camera()
		if camera != null:
			select_cut(camera.global_transform.origin, screen_error_scale(camera))
		else:
			select_cut(debug_view_point)


# Layers onto whatever draws: the server's instances, or the cluster nodes.
func _apply_layers() -> void:
	for instance in _instances:
		if instance.is_valid():
			RenderingServer.instance_set_layer_mask(instance, layers)
	for node in _render_nodes:
		if is_instance_valid(node):
			node.layers = layers


# Move every cluster mesh onto the RenderingServer and free the nodes.
#
# Done once, in _ready(), rather than at build time, so the builder keeps producing plain nodes and
# the saved scene stays inspectable. The swap is invisible to everything above it: selection,
# statistics and validation all go through _visible and cluster_mesh(), never the nodes.
# Move rendering off the scene tree and onto RenderingServer instances.
#
# Driven by the DAG, not by the cluster nodes. It used to require them — it returned early on an
# empty node list and read each node's transform — which made one MeshInstance3D per cluster a hard
# prerequisite for drawing anything. On a detail-256 sphere that is ~7,000 nodes the editor has to
# create, own, track for undo and repaint, and it took minutes: far longer than the build itself.
#
# Cluster nodes never carried a transform of their own, so the transform they contributed was always
# identity relative to this node; nothing is lost by not consulting them.
func _adopt_rendering_server() -> void:
	var world := get_world_3d()
	if world == null or dag == null or not dag.is_valid():
		return

	_free_instances()
	var count := dag.cluster_count
	_instances.resize(count)
	_meshes.resize(count)
	_local_transforms.resize(count)
	var inverse := global_transform.affine_inverse()

	for index in range(count):
		var mesh := cluster_mesh(index)
		if mesh == null:
			_instances[index] = RID()
			continue
		# Keeps the ArrayMesh alive past the node that owned it, where there was one; see _meshes.
		_meshes[index] = mesh
		var node: MeshInstance3D = _render_nodes[index] if index < _render_nodes.size() else null
		_local_transforms[index] = (inverse * node.global_transform if is_instance_valid(node)
				else Transform3D.IDENTITY)
		var instance := RenderingServer.instance_create()
		RenderingServer.instance_set_base(instance, mesh.get_rid())
		RenderingServer.instance_set_scenario(instance, world.scenario)
		RenderingServer.instance_set_transform(instance,
				global_transform * _local_transforms[index])
		RenderingServer.instance_set_visible(instance, _visible[index] != 0)
		RenderingServer.instance_set_layer_mask(instance, layers)
		_instances[index] = instance

	_backend = Backend.RENDERING_SERVER
	for node in _render_nodes:
		if is_instance_valid(node):
			node.free()
	_render_nodes.clear()

	# A Node3D child tracked this node's transform for free. Server instances do not, so ask to be
	# told when it moves.
	set_notify_transform(true)
	_tree_visible = is_visible_in_tree()


func _notification(what: int) -> void:
	# Keep cluster geometry out of the saved scene.
	#
	# The meshes are assigned to the nodes for display, so a plain save would write all of them back
	# into the `.tscn` as sub-resources — which is exactly the 4.28 MB this arrangement exists to
	# avoid. Strip them for the duration of the save and put them straight back; the DAG resource
	# holds the only reference that matters, so nothing is lost in between.
	if what == NOTIFICATION_EDITOR_PRE_SAVE or what == NOTIFICATION_EDITOR_POST_SAVE:
		var restore := what == NOTIFICATION_EDITOR_POST_SAVE
		# Bind first if something saved before _ready() got to it. An unbound node list would strip
		# nothing and silently put all 4 MB back into the scene — the one way this arrangement can
		# fail quietly, so it is worth the redundant call.
		if _render_nodes.is_empty():
			bind_render_nodes()
		for index in range(_render_nodes.size()):
			var node := _render_nodes[index]
			if not is_instance_valid(node):
				continue
			node.mesh = (dag.meshes[index] if restore and dag != null
					and index < dag.meshes.size() else null)
		return

	if _backend != Backend.RENDERING_SERVER:
		return
	match what:
		NOTIFICATION_TRANSFORM_CHANGED:
			var xform := global_transform
			for index in range(_instances.size()):
				if _instances[index].is_valid():
					RenderingServer.instance_set_transform(_instances[index],
							xform * _local_transforms[index])
		NOTIFICATION_VISIBILITY_CHANGED:
			# Hiding the GodotiteLOD node hid its children automatically. Server instances have no
			# such parent, so the tree's answer has to be folded into each one by hand.
			_tree_visible = is_visible_in_tree()
			for index in range(_instances.size()):
				if _instances[index].is_valid():
					RenderingServer.instance_set_visible(_instances[index],
							_tree_visible and _visible[index] != 0)
		NOTIFICATION_EXIT_TREE:
			# Detach from the scenario rather than free: leaving them attached would keep drawing
			# clusters for a node that is no longer in the scene.
			for instance in _instances:
				if instance.is_valid():
					RenderingServer.instance_set_scenario(instance, RID())
		NOTIFICATION_ENTER_TREE:
			var world := get_world_3d()
			if world != null:
				for instance in _instances:
					if instance.is_valid():
						RenderingServer.instance_set_scenario(instance, world.scenario)
		NOTIFICATION_PREDELETE:
			for instance in _instances:
				if instance.is_valid():
					RenderingServer.free_rid(instance)
			_instances.clear()


# The one place cluster visibility changes, under either backend.
func _set_cluster_visible(index: int, value: bool) -> void:
	_visible[index] = 1 if value else 0
	if _backend == Backend.NODES:
		var node := _render_nodes[index]
		if is_instance_valid(node):
			node.visible = value
	elif _instances[index].is_valid():
		RenderingServer.instance_set_visible(_instances[index], value and _tree_visible)


# Whether anything can actually put this cluster on screen.
#
# Deliberately separate from cluster_mesh(), which answers "is there geometry" and since Phase 14b
# reads the DAG first — so it returns non-null even when nothing is bound to draw it. A cluster can
# have perfect geometry and still be invisible, and that is not a hypothetical: regenerating writes
# the DAG resource to disk immediately while the cluster NODES only persist when the scene is saved,
# so a regenerate-without-save leaves the DAG holding more clusters than the scene has nodes. The
# extra ones are the highest indices, and the ordering is leaves-first, so the missing ones are the
# COARSEST — the mesh then vanishes when the camera pulls back far enough to select them.
## Whether anything is bound to draw a cluster. A cluster can have geometry ([method cluster_mesh])
## and still not be drawable: when a DAG was rebuilt and the scene not saved, the coarsest
## clusters have no nodes to draw them.
func cluster_is_renderable(index: int) -> bool:
	if _backend == Backend.RENDERING_SERVER:
		return index < _instances.size() and _instances[index].is_valid()
	var node: MeshInstance3D = _render_nodes[index] if index < _render_nodes.size() else null
	return is_instance_valid(node)


# The mesh drawn for a cluster, whichever backend is live. Read geometry through this rather than
# reaching into _render_nodes, which is empty once the nodes are gone.
## The mesh drawn for a cluster, whichever way clusters are drawn.
func cluster_mesh(index: int) -> Mesh:
	# The DAG owns the geometry, so it answers regardless of backend, and regardless of whether a
	# save has momentarily stripped the nodes.
	if dag != null and index < dag.meshes.size() and dag.meshes[index] != null:
		return dag.meshes[index]
	if _backend == Backend.RENDERING_SERVER:
		return _meshes[index] if index < _meshes.size() else null
	var node: MeshInstance3D = _render_nodes[index] if index < _render_nodes.size() else null
	return node.mesh if is_instance_valid(node) else null


# Rebind only if the node backend is live and has drifted out of step with the DAG.
func _ensure_bound() -> void:
	var count: int = dag.cluster_count if dag != null else 0
	if _backend == Backend.NODES and _render_nodes.size() != count:
		bind_render_nodes()


func _process(_delta: float) -> void:
	if not auto_update:
		return
	if Engine.is_editor_hint():
		_update_editor_preview()
		return
	var camera := get_active_camera()
	if camera != null:
		select_cut_for_camera(camera)


# Re-select the cut as the editor viewport camera moves.
#
# Without this the editor holds whichever cut was chosen when the scene loaded, forever. That is
# actively misleading rather than merely stale: a cut picked for one viewpoint persists into every
# scene that instances the asset, so flying in to inspect a detail shows the LOD that was right from
# far away and reads as broken geometry.
#
# Throttled on two conditions, because this runs on every editor frame for every GodotiteLOD in the
# scene. A still camera does no work at all, and a moving one re-cuts at _EDITOR_PREVIEW_HZ rather
# than at the editor's frame rate. The incremental selector is what makes that affordable — it
# updates the previous cut instead of rebuilding it.
func _update_editor_preview() -> void:
	# Any debug view other than CUT is a deliberate choice to look at something else, and silently
	# overwriting it a few times a second would make those views unusable.
	if not editor_preview or debug_view != DebugView.CUT or _tool_running:
		return
	if dag == null or not dag.is_valid() or not is_drawn_state_ready():
		return
	var camera := get_active_camera()
	if camera == null:
		return
	var camera_transform := camera.global_transform
	if camera_transform.is_equal_approx(_editor_camera):
		return
	var now := Time.get_ticks_usec()
	if now < _editor_next_usec:
		return
	_editor_camera = camera_transform
	@warning_ignore("integer_division")
	_editor_next_usec = now + 1_000_000 / _EDITOR_PREVIEW_HZ
	select_cut_for_camera(camera)


# Rebuild the cluster index -> node mapping by reading the "cluster_index" metadata the builder
# stamped on each mesh node.
#
# Keyed on metadata rather than node name or child order so it survives renaming, reordering, and
# the coverage suffix the level folders carry.
## Matches cluster nodes to clusters by the "cluster_index" metadata the builder gives them. Only
## the node backend (the editor, or Use Rendering Server off) draws with nodes.
func bind_render_nodes() -> void:
	_render_nodes.clear()
	_drawn.clear()
	_drawn_valid = false
	_full_detail_triangles = -1
	_visible.clear()
	if dag == null or not dag.is_valid():
		return
	_render_nodes.resize(dag.cluster_count)
	_visible.resize(dag.cluster_count)
	# Cluster meshes that arrived embedded in the scene rather than from the DAG resource. Should
	# always be zero; anything else means a save leaked geometry back into the `.tscn`.
	var embedded := 0
	var stack: Array[Node] = [ self ]
	while stack.size() > 0:
		var node: Node = stack.pop_back()
		for child in node.get_children():
			var index: int = child.get_meta("cluster_index", -1)
			if index >= 0 and index < _render_nodes.size() and child is MeshInstance3D:
				_render_nodes[index] = child
				# Cluster nodes are saved WITHOUT their mesh — the geometry lives in the DAG
				# resource, and the node is only a handle. Reattach it for display.
				if child.mesh == null and index < dag.meshes.size():
					child.mesh = dag.meshes[index]
				elif child.mesh != null:
					embedded += 1
				# Seed the model from the nodes as saved, so is_drawn() agrees with what is on
				# screen before any selection has run.
				_visible[index] = 1 if child.visible else 0
				child.layers = layers
			stack.append(child)

	# Loud on purpose. The geometry is meant to live only in the DAG resource, and a leak is
	# invisible in the editor — the scene looks and behaves identically while quietly carrying
	# megabytes of duplicated mesh text into every commit. The most likely cause is a GDScript parse
	# error in this file at the moment of the last save, which stops NOTIFICATION_EDITOR_PRE_SAVE
	# from running; adding a new `class_name` and referencing it here does exactly that until the
	# editor rescans. Re-saving the scene with this script healthy cleans it.
	_build_parent_map()

	# Only meaningful when the nodes are what draws. Under the RenderingServer backend their absence
	# is the normal, intended state, and warning about it would fire on every well-formed scene.
	var unbound := 0
	if not use_rendering_server:
		for index in range(dag.cluster_count):
			if index >= _render_nodes.size() or not is_instance_valid(_render_nodes[index]):
				unbound += 1
	if unbound > 0:
		push_warning(("%s: %d of %d clusters have no render node and will never be drawn. "
				+ "The DAG resource is written on Regenerate but the cluster nodes only persist "
				+ "when the SCENE is saved, so these are almost certainly a regenerate that was "
				+ "not followed by a save. Save the scene. Ordering is leaves-first, so the missing "
				+ "clusters are the coarsest and the mesh will vanish when the camera pulls back.")
				% [ name, unbound, dag.cluster_count ])

	if embedded > 0:
		push_warning(("%s: %d cluster meshes are embedded in the scene file instead of the DAG "
				+ "resource. Save the scene to strip them. If it recurs, check the Godot output for "
				+ "a parse error in godotite_lod.gd, then Project > Reload Current Project.")
				% [ name, embedded ])


# Releases every server instance this node owns. Idempotent, and the counterpart to adoption, which
# may run more than once — a rebind after a rebuild would otherwise leak a whole DAG of RIDs.
# Forget the drawn DAG before a new one is set: frees its server instances and any cluster nodes.
# The builder calls it when it updates this node in place.
## Lets go of the drawn DAG: frees its server instances and cluster nodes. The builder calls it
## before it publishes a new DAG to this node.
func clear_rendering() -> void:
	_free_instances()
	_backend = Backend.NODES
	for child in get_children():
		if child.has_meta("lod_level") or child.has_meta("cluster_index"):
			remove_child(child)
			child.queue_free()
	_render_nodes.clear()


func _free_instances() -> void:
	for instance in _instances:
		if instance.is_valid():
			RenderingServer.free_rid(instance)
	_instances.clear()
	_meshes.clear()
	_local_transforms.clear()


# Whether binding has produced a usable visibility model.
#
# A cut cannot be selected before this is true — the visibility array is sized by binding, and
# selecting into an empty one floods the log with out-of-bounds writes and draws nothing. Exposed
# so a caller driving the node from outside the tree lifecycle can check rather than assume.
## Whether the node is bound to its DAG, so a cut can be selected. A caller driving the node from
## outside the tree should check it first.
func is_drawn_state_ready() -> bool:
	return dag != null and dag.is_valid() and _visible.size() == dag.cluster_count


# Reverse of children_of(): for each cluster, the clusters of the group it was folded into.
#
# O(edges), rebuilt whenever the DAG is bound. The DAG is leaves-first, so a cluster's parents
# always sit at higher indices than it does.
func _build_parent_map() -> void:
	_parents.clear()
	if dag == null or not dag.is_valid():
		return
	_parents.resize(dag.cluster_count)
	for index in range(dag.cluster_count):
		_parents[index] = PackedInt32Array()
	for parent in range(dag.cluster_count):
		for child in dag.children_of(parent):
			_parents[child].append(parent)


## Gives every cluster surface its material: Material if set, otherwise its entry in Materials.
## Called when either property is set; call it after changing a material inside Materials.
func apply_material() -> void:
	if dag == null:
		return
	for index in range(_visible.size()):
		var node: MeshInstance3D = _render_nodes[index] if index < _render_nodes.size() else null
		var instance: RID = _instances[index] if index < _instances.size() else RID()
		var has_render_node := is_instance_valid(node)
		if not has_render_node and not instance.is_valid():
			continue

		# An override wins over everything, which is what makes the debug views work unchanged.
		if has_render_node:
			node.material_override = material
		else:
			RenderingServer.instance_geometry_set_material_override(instance,
					material.get_rid() if material != null else RID())
		if material != null:
			continue

		# Otherwise bind the real material to each surface by its source material index. The DAG is
		# the authority on surface count, which is also what lets this work with no node to ask.
		var surface_materials := dag.surface_materials_of(index)
		for surface in range(surface_materials.size()):
			var source_index: int = surface_materials[surface]
			var surface_material: Material = materials[source_index] \
					if source_index >= 0 and source_index < materials.size() else null
			if has_render_node:
				node.set_surface_override_material(surface, surface_material)
			else:
				RenderingServer.instance_set_surface_override_material(instance, surface,
						surface_material.get_rid() if surface_material != null else RID())
	apply_cluster_colors()


# Bring the cluster debug view up to date: the view mode and the DAG's ranges onto any material that
# reads the debug channels the builder bakes into vertex colour (cluster_debug.gdshader). One
# uniform assignment on the shared material, nothing per cluster. (A per-cluster `cluster_color`
# instance uniform did this once; instance uniforms share one fixed buffer, which a large DAG
# overflowed, and it was removed on 2026-10-06.)
## Brings the debug colour material up to date: Color Mode, Color Saturation and Color Value, and
## the DAG's levels and errors. Called when they change.
func apply_cluster_colors() -> void:
	if dag == null or not dag.is_valid() or _visible.size() != dag.cluster_count:
		return
	_apply_debug_view_uniforms()


# Push the view mode onto any material that reads the baked debug channels.
#
# Cheap and unconditional: a material without these uniforms ignores the assignment, and setting
# them costs nothing per cluster — which is the whole point of moving the tint into vertex colour.
func _apply_debug_view_uniforms() -> void:
	var max_level := 1
	# The error channel is baked as a fraction of each cluster's own diameter, which is scale-free but
	# leaves the view using a fraction of the hue range — real clusters sit far below the clamp. The
	# DAG's largest such fraction is only knowable here, once every cluster exists, so it is passed in
	# and the shader rescales against it.
	var max_error_fraction := 0.0
	for index in range(dag.cluster_count):
		max_level = maxi(max_level, dag.levels[index])
		var radius: float = dag.lod_radii[index]
		var error: float = dag.errors[index]
		if radius > 0.0 and not is_inf(error):
			max_error_fraction = maxf(max_error_fraction, minf(error / (2.0 * radius), 1.0))
	for candidate in _debug_materials():
		candidate.set_shader_parameter("color_mode", int(color_mode))
		candidate.set_shader_parameter("debug_channel", maxi(dag.debug_channel, 0))
		candidate.set_shader_parameter("max_level", float(max_level))
		candidate.set_shader_parameter("max_error_fraction", maxf(max_error_fraction, 0.0001))
		candidate.set_shader_parameter("saturation", color_saturation)
		candidate.set_shader_parameter("value", color_value)


func _debug_materials() -> Array:
	var found: Array = []
	if material is ShaderMaterial:
		found.append(material)
	for entry in materials:
		if entry is ShaderMaterial:
			found.append(entry)
	return found


# --- LOD SELECTION ---

# Projected error of the cluster itself: how wrong it looks from view_point.
#
# view_point is in THIS NODE'S LOCAL SPACE, because the DAG's centres and radii came from
# surface_get_arrays() and are local to the mesh they were built from. Callers convert with
# to_local(); select_cut() does it once for the whole descent.
#
# Divides by distance to the NEAREST point on the LOD sphere, the worst case within those bounds,
# which keeps the estimate conservative.
## How wrong a cluster looks from [param view_point], before scaling to pixels: its error over its
## distance. [param view_point] is in this node's local space.
func projected_error(index: int, view_point: Vector3) -> float:
	var error: float = dag.errors[index]
	if is_inf(error):
		return INF
	return error / _shell_distance(view_point, dag.lod_centers[index], dag.lod_radii[index],
			dag.lod_inner_radii[index] if index < dag.lod_inner_radii.size() else 0.0)


# Lower bound on the distance from `view_point` to geometry lying in the shell between `inner` and
# `outer` radius of `center`.
#
# Outside the shell this is the old ball test. Inside the hollow core it is `inner - distance`,
# which is the whole point: a viewer at the centre of a planet is a full inner-radius away from its
# surface, where a ball bound reports zero and drives projected error to infinity, pinning the
# selector to the finest levels no matter what the threshold says.
#
# A lower bound is the safe form — it can only overstate projected error and refine too much, never
# too little.
func _shell_distance(view_point: Vector3, center: Vector3, outer: float, inner: float) -> float:
	var distance := view_point.distance_to(center)
	return maxf(maxf(distance - outer, inner - distance), MIN_PROJECTION_DISTANCE)


## Projected error of the coarser alternative that would replace this cluster.
func projected_parent_error(index: int, view_point: Vector3) -> float:
	var error: float = dag.parent_errors[index]
	if is_inf(error):
		return INF
	return error / _shell_distance(view_point, dag.parent_centers[index],
			dag.parent_radii[index],
			dag.parent_inner_radii[index] if index < dag.parent_inner_radii.size() else 0.0)


# Select the cut by descending from the root and stopping as soon as a cluster is accurate enough.
#
# Cost is proportional to the size of the cut, not to the size of the DAG. Since the cut is bounded
# by screen area rather than world size, this stays roughly constant as the mesh grows — which is
# the difference between viable and not at millions of triangles.
#
# Pruning at a drawn cluster is exact, not an approximation. A child's parent_error IS its parent's
# own error — same group, same value, same sphere — so once `proj(error) <= threshold` holds for a
# cluster, the "parent too coarse" test fails for every child, and monotonic error extends that to
# the entire subtree. Nothing below a drawn cluster can be drawn.
#
# The DAG's shared children are safe for the same reason: the two clusters a group splits into
# carry identical error and bounds, so they always decide alike. Either both refine (both descend,
# and `visited` dedupes) or both draw (neither descends). They cannot disagree, which is exactly
# the failure that made the pre-Phase-5 descent produce overlapping geometry.
#
# select_cut_flat() is the reference implementation and must always agree with this.
## Chooses the clusters to draw from [param view_point] (in world space), from scratch: a descent from
## the root that stops at each cluster accurate enough. [param error_scale] turns projected error into
## pixels; see [method screen_error_scale]. Its cost follows the size of the cut, not of the mesh.
func select_cut(view_point: Vector3, error_scale: float = 1.0) -> void:
	if dag == null or not dag.is_valid():
		return
	_threshold = effective_error_threshold()

	# Clear only what was drawn last frame. Hiding all N clusters would put the O(N) cost straight
	# back in, and the cut barely changes between frames.
	if _drawn_valid:
		for index in _drawn:
			_set_cluster_visible(index, false)
	else:
		_hide_all()
		_drawn_valid = true
	var start_usec := Time.get_ticks_usec()
	_drawn.clear()
	drawn_clusters = 0
	drawn_surfaces = 0
	drawn_triangles = 0

	# Errors and bounds are in local space, so the view point has to come with them. The error/
	# distance ratio is unaffected by a uniform scale on this node - both scale together - but a
	# non-uniform scale would distort it.
	var local_view := to_local(view_point)

	var visited: Dictionary = {}
	# A full descent leaves no slack behind, so the next incremental pass has to do real work rather
	# than trust a floor left over from a different cut.
	_slack_floor = 0.0
	_pending_travel = 0.0

	var stack: Array[int] = [ dag.root_index ]
	last_visited = 0
	while stack.size() > 0:
		var index: int = stack.pop_back()
		if visited.has(index):
			continue
		visited[index] = true
		last_visited += 1

		# A leaf is the finest geometry available, so it is drawn whatever its error says.
		if dag.is_leaf(index) or projected_error(index, local_view) * error_scale <= _threshold:
			_set_cluster_visible(index, true)
			_drawn.append(index)
			drawn_clusters += 1
			drawn_surfaces += maxi(dag.surface_material_counts[index], 1)
			drawn_triangles += dag.triangle_counts[index]
			continue

		for child in dag.children_of(index):
			stack.append(child)

	last_select_usec = Time.get_ticks_usec() - start_usec


# Update the existing cut in place instead of rebuilding it from the root.
#
# The premise, measured before this was written: **the cut barely changes between frames.** Over a
# 240-frame camera path only 1.0% to 4.7% of the cut flips per frame. The descent, by contrast,
# costs O(visited) — 158 to 456 node visits — and that cost grows with the MESH, not the screen:
# measured 46 -> 153 -> 242 us as the source went 12k -> 49k -> 110k triangles, about mesh^0.76,
# which extrapolates to milliseconds at the millions of triangles this project is aimed at.
#
# Working from the cut instead makes the per-frame cost proportional to what actually changed.
#
# Two moves, applied until nothing changes:
#   * **refine** a drawn cluster that has become too coarse, replacing it with its children;
#   * **merge** a whole group back into the coarser clusters it came from.
#
# Merging is all-or-nothing per group and that is not a nicety — drawing half a group's coarse form
# alongside half its fine form is exactly the overlapping-geometry bug Phase 5 fixed. A merge is
# only taken when every child of the parent group is currently drawn.
#
# Must agree exactly with select_cut(). It is validated against it, and against select_cut_flat(),
# so three independent selectors have to produce the same cut.
## Like [method select_cut], but updates the last cut instead of starting again: refining
## clusters that became too coarse and merging groups that became too fine. Gives the same cut,
## and costs what changed rather than what is drawn. What Incremental Selection uses.
func select_cut_incremental(view_point: Vector3, error_scale: float = 1.0) -> void:
	if dag == null or not dag.is_valid():
		return
	_threshold = effective_error_threshold()
	# No usable cut to update — nothing drawn, or something changed visibility behind our back.
	if not _drawn_valid or _drawn.is_empty() or _parents.size() != dag.cluster_count:
		select_cut(view_point, error_scale)
		return

	var start_usec := Time.get_ticks_usec()
	var local_view := to_local(view_point)

	# Slack is measured against a fixed threshold and projection, so a change to either retires every
	# stored value at once.
	if _slack.size() != dag.cluster_count or _threshold != _last_threshold \
			or error_scale != _last_scale:
		_slack.resize(dag.cluster_count)
		_slack.fill(_NEEDS_RETEST)
		_last_threshold = _threshold
		_last_scale = error_scale
		_last_view = local_view
		_slack_floor = 0.0
		_pending_travel = 0.0

	var moved := local_view.distance_to(_last_view)
	_last_view = local_view

	# Nothing can have changed yet, so do not look.
	#
	# Slack is how far the view point may move before one cluster's decision could flip, and shell
	# distance is 1-Lipschitz in the view point — so the SMALLEST slack in the cut is a distance the
	# camera can travel with provably nothing to do. Spending travel against that one float replaces
	# six passes over the drawn set, a dictionary rebuild and two `keys()` allocations per frame.
	#
	# This matters at scale rather than in principle: a grid of sixteen terrain tiles selects sixteen
	# cuts per frame, and that cost was measurable with the camera standing still — several
	# milliseconds for a result that could not have differed from the previous frame's.
	# Travel is banked while the floor holds, and spent against every member the moment it does not.
	#
	# Decrementing only the floor on a skipped frame is what broke this the first time: the stored
	# per-cluster slacks kept their values from the last real pass, so when the floor finally expired
	# the refine pass saw everyone still in credit, skipped them all, recharged the floor from those
	# same stale numbers, and froze the cut permanently. It showed up as nodes stuck at one cluster
	# no matter how close the camera came.
	_pending_travel += moved
	_slack_floor -= moved
	if _slack_floor > 0.0:
		last_visited = 0
		last_select_usec = Time.get_ticks_usec() - start_usec
		return

	var cut: Dictionary = {}
	for index in _drawn:
		cut[index] = true

	# One subtraction per member spends ALL the travel banked since the last pass, not just this
	# frame's, so a cluster's budget reflects every metre the camera has moved.
	for index in cut:
		if _slack[index] != _NEEDS_RETEST:
			_slack[index] -= _pending_travel
			if _slack[index] <= 0.0:
				_slack[index] = _NEEDS_RETEST
	_pending_travel = 0.0

	last_visited = 0
	# Bounded because every refine moves strictly down the DAG and every merge strictly up, but a
	# cap keeps a mistake from hanging the frame rather than showing up as a wrong cut.
	for iteration in range(_MAX_INCREMENTAL_PASSES):
		var changed := false

		# Refine: a drawn cluster whose own error no longer fits is replaced by its children.
		for index in cut.keys():
			if dag.is_leaf(index) or _slack[index] != _NEEDS_RETEST:
				continue
			last_visited += 1
			if projected_error(index, local_view) * error_scale <= _threshold:
				continue
			cut.erase(index)
			for child in dag.children_of(index):
				cut[child] = true
				_slack[child] = _NEEDS_RETEST
			changed = true

		# Merge: a group whose coarser form now fits is folded back up.
		for index in cut.keys():
			if not cut.has(index) or _slack[index] != _NEEDS_RETEST:
				continue  # already removed as a sibling, or not near a threshold yet
			for parent in _parents[index]:
				last_visited += 1
				if projected_error(parent, local_view) * error_scale > _threshold:
					continue
				var siblings := dag.children_of(parent)
				var complete := true
				for sibling in siblings:
					if not cut.has(sibling):
						complete = false
						break
				if not complete:
					continue
				for sibling in siblings:
					cut.erase(sibling)
				# Every cluster the parent group produced, so the group stays whole.
				for group_member in _parents[siblings[0]]:
					cut[group_member] = true
					_slack[group_member] = _NEEDS_RETEST
				changed = true
				break

		if not changed:
			break

	# Recharge every member that was evaluated this frame with the camera travel it can absorb before
	# its decision could change again, and remember the smallest — that is how long the whole cut can
	# be left alone.
	_slack_floor = INF
	for index in cut:
		if _slack[index] == _NEEDS_RETEST:
			_slack[index] = _decision_slack(index, local_view, error_scale)
		_slack_floor = minf(_slack_floor, _slack[index])
	if is_inf(_slack_floor):
		_slack_floor = 0.0

	# Apply the difference only. Touching every cluster here would put back the O(N) cost that the
	# incremental update exists to avoid.
	for index in _drawn:
		if not cut.has(index):
			_set_cluster_visible(index, false)
	_drawn.clear()
	drawn_clusters = 0
	drawn_surfaces = 0
	drawn_triangles = 0
	for index in cut:
		if not is_drawn(index):
			_set_cluster_visible(index, true)
		_drawn.append(index)
		drawn_clusters += 1
		drawn_surfaces += maxi(dag.surface_material_counts[index], 1)
		drawn_triangles += dag.triangle_counts[index]

	last_select_usec = Time.get_ticks_usec() - start_usec


# How far the view point may move before this drawn cluster could stop being the right choice.
#
# A cluster is drawn while its own error fits and its parent's does not, and each of those is a
# comparison on the same shell distance `d`:
#
#     own fits        <=>  d >= error * scale / threshold
#     parent too big  <=>  d <  parent_error * scale / threshold
#
# so the cluster is correct for `d` anywhere inside that band, and the slack is simply how far `d`
# sits from the nearer edge. Because `d` is 1-Lipschitz in the view point, camera travel converts
# one-for-one into distance change, and no motion smaller than the slack can flip the decision.
#
# The root has an infinite parent error and so no upper edge.
func _decision_slack(index: int, local_view: Vector3, error_scale: float) -> float:
	if _threshold <= 0.0 or error_scale <= 0.0:
		return 0.0
	var distance := _shell_distance(local_view, dag.lod_centers[index], dag.lod_radii[index],
			dag.lod_inner_radii[index] if index < dag.lod_inner_radii.size() else 0.0)

	# A leaf is drawn however large its error is, so its lower edge does not exist.
	var slack := INF
	if not dag.is_leaf(index):
		slack = distance - dag.errors[index] * error_scale / _threshold

	var parent_error: float = dag.parent_errors[index]
	if not is_inf(parent_error):
		var parent_distance := _shell_distance(local_view, dag.parent_centers[index],
				dag.parent_radii[index],
				dag.parent_inner_radii[index] if index < dag.parent_inner_radii.size() else 0.0)
		slack = minf(slack, parent_error * error_scale / _threshold - parent_distance)

	# Never hand back a negative or infinite budget: the first means it should have flipped already,
	# the second would freeze the cluster forever.
	return clampf(slack, 0.0, 1e9)


## Total triangles if every leaf were drawn, i.e. the source mesh. Cached on first use.
func full_detail_triangles() -> int:
	if _full_detail_triangles < 0:
		_full_detail_triangles = 0
		for index in range(dag.cluster_count):
			if dag.is_leaf(index):
				_full_detail_triangles += dag.triangle_counts[index]
	return _full_detail_triangles


# Reference implementation of the same selection, testing every cluster independently with no
# traversal: draw when the parent is too coarse and this cluster is accurate enough.
#
# This is the form Nanite evaluates in parallel on the GPU, and it is O(clusters) — too slow to run
# per frame on the CPU at scale. Kept because two independent selectors that must agree is a much
# stronger check than either alone; see the validation harness in GODOTITE.md Phase 8.
## Like [method select_cut], but tests every cluster on its own: draws a cluster when it is
## accurate enough and its parent is not. Slow, and for checking the other selectors, which must
## agree with it; Validate DAG does.
func select_cut_flat(view_point: Vector3, error_scale: float = 1.0) -> void:
	if dag == null or not dag.is_valid():
		return
	_threshold = effective_error_threshold()
	_drawn_valid = false
	var local_view := to_local(view_point)
	for index in range(dag.cluster_count):
		var parent_too_coarse := projected_parent_error(index, local_view) * error_scale > _threshold
		var accurate_enough := projected_error(index, local_view) * error_scale <= _threshold
		_set_cluster_visible(index, parent_too_coarse and accurate_enough)


# Select against a camera, with error in pixels of screen error.
# Frustum skipping was tried here and removed. It looks free — a node nobody can see does not need
# a cut — but skipping does not avoid the work, it defers it: the cut goes stale while the camera
# moves, and every skipped node pays in full on the frame it comes back into view. Measured by
# creeping forward and then turning 180 degrees, it saved 0.010 ms per frame and cost 0.061 ms on
# the turn, breaking even at about one turn per six frames, and turning quickly is ordinary.
#
# It was also largely redundant: a node that is off screen is usually far away, so its slack is
# large, so `_slack_floor` already skips it for many frames at the cost of one subtraction.
## Chooses the clusters to draw from a camera, in pixels of screen error: what Auto Update does
## each frame.
func select_cut_for_camera(camera: Camera3D) -> void:
	var error_scale := screen_error_scale(camera) * _budget_scale
	if incremental_selection:
		select_cut_incremental(camera.global_transform.origin, error_scale)
	else:
		select_cut(camera.global_transform.origin, error_scale)
	_update_budget_scale()


# Steer the effective threshold toward the draw-call budget, one frame at a time.
#
# Asymmetric on purpose: pull back hard when over budget so a spike is corrected quickly, and creep
# back toward full detail slowly so the cut does not oscillate around the limit.
func _update_budget_scale() -> void:
	if draw_call_budget <= 0:
		_budget_scale = 1.0
		_budget_average = 0.0
		return

	# React to a smoothed surface count rather than this frame's, so transient spikes do not move a
	# threshold that applies to the whole mesh.
	if _budget_average <= 0.0:
		_budget_average = float(drawn_surfaces)
	else:
		_budget_average += (drawn_surfaces - _budget_average) / _BUDGET_SMOOTHING_FRAMES

	# Aim at the MIDDLE of the deadband rather than at the budget itself. Aiming at an edge leaves
	# the controller parked against it, where the smallest wobble pushes it back out and it starts
	# correcting again; aiming at the centre means a correction ends comfortably inside the band and
	# the controller genuinely idles.
	var target: float = draw_call_budget * (1.0 + _BUDGET_DEADBAND) * 0.5
	var over: bool = _budget_average > draw_call_budget
	var under: bool = _budget_average < draw_call_budget * _BUDGET_DEADBAND

	if over or under:
		var correction: float = pow(target / maxf(_budget_average, 1.0), _BUDGET_GAIN)
		correction = clampf(correction, 1.0 - _BUDGET_MAX_STEP, 1.0 + _BUDGET_MAX_STEP)
		_budget_scale = clampf(_budget_scale * correction, _BUDGET_SCALE_FLOOR, 1.0)

	if over:
		# Pinned at the floor and STILL over: raising the threshold has stopped buying anything, so
		# the budget cannot be met and silently missing it would be worse than saying so. This is
		# the expected state with the camera inside a closed mesh, where the selector saturates —
		# measured at 163 surfaces against a budget of 25. Latched, so it is said once per episode.
		if _budget_scale <= _BUDGET_SCALE_FLOOR and not _budget_exhausted:
			_budget_exhausted = true
			push_warning(("%s: draw_call_budget %d cannot be met — %d surfaces at the coarsest "
					+ "selection available. Inside a closed mesh the threshold has little effect; "
					+ "see GODOTITE.md Phase 4.6.") % [ name, draw_call_budget, drawn_surfaces ])
	elif under:
		_budget_exhausted = false


## Pixels of screen error per unit of projected error, for this camera.
func screen_error_scale(camera: Camera3D) -> float:
	var viewport := camera.get_viewport()
	if viewport == null:
		return 1.0
	var height: float = viewport.get_visible_rect().size.y
	return height / (2.0 * tan(deg_to_rad(camera.fov) * 0.5))


# The camera to select against: the editor viewport camera at edit time, the active scene camera
# at runtime.
#
# EditorInterface is reached through Engine.get_singleton() rather than named directly, because
# editor classes are absent from release export templates and a bare reference would fail to
# resolve there and take the whole script down with it.
## The camera clusters are chosen from: the editor's viewport camera in the editor, the active
## camera at runtime.
func get_active_camera() -> Camera3D:
	if Engine.is_editor_hint():
		if not Engine.has_singleton("EditorInterface"):
			return null
		var editor_interface := Engine.get_singleton("EditorInterface")
		var editor_viewport: SubViewport = editor_interface.get_editor_viewport_3d(0)
		return editor_viewport.get_camera_3d() if editor_viewport != null else null
	var viewport := get_viewport()
	return viewport.get_camera_3d() if viewport != null else null


# --- DEBUG VIEW ---

## Shows the clusters Debug View picks and prints a summary: what the Apply Debug View button does.
func apply_debug_view() -> void:
	if dag == null or not dag.is_valid():
		push_warning("No DAG assigned. Run Regenerate on the builder first.")
		return
	_ensure_bound()

	# Use the camera's pixel scale here too. Without it the error threshold would mean pixels at runtime
	# and error-per-unit-distance in the editor, so a value tuned in one place would be wrong in the
	# other by a factor of several hundred.
	var camera := get_active_camera()
	var error_scale := 1.0
	if camera != null:
		debug_view_point = camera.global_transform.origin
		error_scale = screen_error_scale(camera)

	match debug_view:
		DebugView.CUT:
			select_cut(debug_view_point, error_scale)
		DebugView.LEVEL:
			_set_all_visible(false)
			_show_level(debug_level)
		DebugView.ALL:
			_set_all_visible(true)

	print("debug view %s: %s" % [ DebugView.keys()[debug_view], debug_view_summary() ])


## Checks the DAG (see GodotiteValidator) and prints the report: what the Validate DAG button does.
## One check per frame, with a progress line before each, so the editor keeps drawing; await it.
func validate_dag() -> void:
	if not _begin_tool("Validate DAG"):
		return
	_ensure_bound()
	var started := Time.get_ticks_msec()
	_tool_log("[godotite] Validate DAG: %s, %d clusters" % [ name, dag.cluster_count ])
	var report: String = await load(_VALIDATOR_PATH).validate_async(self, true, _tool_progress)
	print(report)
	_tool_log("[godotite] Validate DAG done in %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	_tool_running = false


## Sweeps the error threshold from the active camera and prints the measured screen error against
## triangles and draw calls (see GodotiteMeasure): what the Measure Error button does. One threshold
## per frame, with a progress line before each; await it. Measures at most 20,000 full-detail
## vertices, evenly spaced. [br][br]
##
## Restores the threshold afterwards, but leaves a cut selected, same as Apply Debug View.
func measure_error() -> void:
	if not _begin_tool("Measure Error"):
		return
	_ensure_bound()
	var camera := get_active_camera()
	var point: Vector3 = camera.global_transform.origin if camera != null else debug_view_point
	var started := Time.get_ticks_msec()
	_tool_log("[godotite] Measure Error: %s, %d clusters, from %s" % [ name, dag.cluster_count,
			"the camera" if camera != null else "Debug View Point" ])
	var report: String = await load(_MEASURE_PATH).sweep(self, [ 20.0, 40.0, 80.0, 120.0, 240.0, 480.0 ],
			point, _MEASURE_SAMPLES, _tool_progress)
	print(report)
	_tool_log("[godotite] Measure Error done in %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	_tool_running = false


# Whether a tool may start: there is a DAG, and no tool is already running.
func _begin_tool(tool_name: String) -> bool:
	if dag == null or not dag.is_valid():
		push_warning("Godotite: %s: no DAG to check; Regenerate its builder first." % name)
		return false
	if _tool_running:
		push_warning("Godotite: %s: %s waits for the check already running." % [ name, tool_name ])
		return false
	_tool_running = true
	return true


func _tool_progress(step: String) -> void:
	_tool_log("[godotite]   " + step)


func _tool_log(line: String) -> void:
	load(_LOG_PATH).log(line)


func _hide_all() -> void:
	for index in range(_visible.size()):
		_set_cluster_visible(index, false)


func _set_all_visible(value: bool) -> void:
	for index in range(_visible.size()):
		_set_cluster_visible(index, value)
	_drawn_valid = false


func _show_level(level: int) -> void:
	_drawn_valid = false
	for index in range(dag.cluster_count):
		if dag.levels[index] == level:
			_set_cluster_visible(index, true)


## Whether a cluster is drawn by the current cut.
func is_drawn(index: int) -> bool:
	return index < _visible.size() and _visible[index] != 0


# Report what is drawn, and whether it is a valid cut.
#
# A valid cut means every root-to-leaf path crosses exactly ONE drawn cluster: 0 leaves a hole, 2
# draws the same surface twice at different detail.
#
# Counting "leaf clusters covered" instead does NOT work here and looks convincing while being
# wrong. Children is a dependency relation, not spatial containment — the two clusters a group
# splits into share all of that group's children — so a leaf-based count sees every leaf twice even
# when those two clusters together tile the region exactly once.
## What is drawn, as one line: clusters, triangles, and whether it is a valid cut (every part of
## the mesh drawn exactly once).
func debug_view_summary() -> String:
	var drawn := 0
	var tris := 0
	for index in range(dag.cluster_count):
		if is_drawn(index):
			drawn += 1
			tris += dag.triangle_counts[index]

	# Clusters are ordered leaves first, so walking backwards visits every parent before its
	# children and one pass is enough to propagate path counts.
	var path_min := PackedInt32Array()
	var path_max := PackedInt32Array()
	path_min.resize(dag.cluster_count)
	path_max.resize(dag.cluster_count)
	path_min.fill(-1)
	path_max.fill(-1)
	var root_step: int = 1 if is_drawn(dag.root_index) else 0
	path_min[dag.root_index] = root_step
	path_max[dag.root_index] = root_step

	for index in range(dag.cluster_count - 1, -1, -1):
		if path_min[index] < 0:
			continue
		for child in dag.children_of(index):
			var step: int = 1 if is_drawn(child) else 0
			var low: int = path_min[index] + step
			var high: int = path_max[index] + step
			if path_min[child] < 0:
				path_min[child] = low
				path_max[child] = high
			else:
				path_min[child] = mini(path_min[child], low)
				path_max[child] = maxi(path_max[child], high)

	var lowest := 99
	var highest := 0
	for index in range(dag.cluster_count):
		if dag.is_leaf(index):
			lowest = mini(lowest, maxi(path_min[index], 0))
			highest = maxi(highest, maxi(path_max[index], 0))

	var verdict := "VALID CUT"
	if lowest != 1 or highest != 1:
		verdict = "BROKEN: paths cross %d..%d drawn clusters (want 1..1)" % [ lowest, highest ]
	return "%d clusters visible, %d tris, %s" % [ drawn, tris, verdict ]
