@tool
extends EditorExportPlugin

## Exports the DAG files exported scenes refer to, and strips the debug channel from every
## GodotiteDAG in an exported game.
##
## A GodotiteLOD refers to its DAG file by UID (GodotiteLOD.dag_file) rather than as a dependency,
## so that a missing file does not break its scene; Godot therefore does not know to export it.
## Every DAG an exported scene refers to, and that the export would otherwise leave out (exporting
## selected scenes or resources), is added here. [br][br]
##
## The cluster meshes carry their debug data (material tag, cluster hue, level, error) in a custom
## vertex channel, 4 bytes per vertex, ~7% of a DAG's VRAM. Only the debug views read it, and a game
## has no use for them, so exports leave it out, unless the demo is the game (DEMO_FOLDER); the
## project keeps it, so the editor's debug views still work. The DAG's own resource file is left as it is; only what goes into the export changes.

const Project := preload("res://addons/godotite/godotite_project.gd")

## Where a DAG added to an export is written on its way into it.
const STAGING_FOLDER := "res://.godot/godotite_export/"

# Every file the export takes, and every DAG file its scenes refer to.
var _exported := {}
var _wanted := {}
# Whether the game's main scene is in the demo's folder, which then goes in, its DAGs keeping their
# debug channel for the demo's cluster view.
var _demo_is_game := false


func _get_name() -> String:
	return "Godotite"


# Called before the export's files are gone through, so the bookkeeping starts empty.
func _begin_customize_resources(_platform: EditorExportPlatform, _features: PackedStringArray) -> bool:
	_exported.clear()
	_wanted.clear()
	_demo_is_game = _main_scene_in_demo()
	return true


static func _main_scene_in_demo() -> bool:
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main_scene.begins_with("uid://"):
		main_scene = ResourceUID.get_id_path(ResourceUID.text_to_id(main_scene))
	return main_scene.begins_with(DEMO_FOLDER)


## The demo's folder, left out of exported games, unless the main scene is in it (Godotite's own
## repository): it is for trying Godotite in the editor. Its scripts still go in when exporting all
## resources: Godot's own export step compiles every script and takes it out of the queue before
## other plugins see it, so only the scene can be skipped.
const DEMO_FOLDER := "res://addons/godotite/demo/"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(DEMO_FOLDER) and not _demo_is_game:
		skip()
		return
	_exported[path] = true
	if path.get_extension() in [ "tscn", "scn" ]:
		for reference in Project.dag_references_in_scene(path):
			_wanted[reference.path] = true


# Called after every file has gone through _export_file(); files added here are written last.
func _end_customize_resources() -> void:
	for path in _wanted:
		if _exported.has(path):
			continue
		if not ResourceLoader.exists(path):
			push_warning(("Godotite: the export leaves out %s, which a scene refers to: the file is "
					+ "missing. Rebuild it (Project > Tools > Godotite: Rebuild Missing DAGs).") % path)
			continue
		var dag := load(path) as GodotiteDAG
		var stripped: GodotiteDAG = strip_debug(dag) if dag != null and not _demo_is_game else null
		if stripped == null:
			add_file(path, FileAccess.get_file_as_bytes(path), false)
			continue
		DirAccess.make_dir_recursive_absolute(STAGING_FOLDER)
		var staged := STAGING_FOLDER.path_join(path.get_file())
		if ResourceSaver.save(stripped, staged) != OK:
			push_error("Godotite: could not stage %s for export; exporting it as it is." % path)
			add_file(path, FileAccess.get_file_as_bytes(path), false)
			continue
		# The original's UID, so the file is the same resource to everything that loads it.
		ResourceSaver.set_uid(staged, ResourceLoader.get_resource_uid(path))
		add_file(path, FileAccess.get_file_as_bytes(staged), false)
		DirAccess.remove_absolute(staged)


## Changes whenever what _customize_resource() produces would change, so Godot's export cache knows:
## files it customized before are otherwise reused as they were.
func _get_customization_configuration_hash() -> int:
	return 4 if _main_scene_in_demo() else 3


func _customize_resource(resource: Resource, path: String) -> Resource:
	# A DAG file of its own, or a DAG embedded in a scene (an import's). Godot also offers, with an
	# empty path, every resource a scene refers to, a DAG file among them: a copy returned for that has
	# no file to point at, so the scene embeds it, and the export carried the whole DAG twice, 932 MB
	# each on the hollow world. An embedded DAG has no file, so its copy is embedded as it was.
	if _demo_is_game:
		return null
	if resource is GodotiteDAG and (not path.is_empty() or resource.resource_path.contains("::")):
		return strip_debug(resource)
	return null


## A copy of `dag` whose cluster meshes lack the debug channel, or null if it has none to strip.
static func strip_debug(dag: GodotiteDAG) -> GodotiteDAG:
	if dag.debug_channel < 0:
		return null
	var copy := dag.duplicate(false) as GodotiteDAG
	var meshes: Array[ArrayMesh] = []
	for mesh in dag.meshes:
		meshes.append(_strip_mesh(mesh, dag.debug_channel) if mesh != null else null)
	copy.meshes = meshes
	copy.debug_channel = -1
	return copy


## `mesh` rebuilt without custom channel `channel`, every other array, format and material kept. [br][br]
##
## Rebuilt through the arrays, so normals and tangents are decoded and re-encoded, which moves some
## by one step of their compressed encoding: at most 0.005° on the terrain. The same input always
## encodes the same way, so a vertex shared by two clusters still matches in both. Compressed
## positions (GodotiteBuilder.compress_vertices) stay compressed, see _renudge().
static func _strip_mesh(mesh: ArrayMesh, channel: int) -> ArrayMesh:
	var stripped := ArrayMesh.new()
	stripped.resource_name = mesh.resource_name
	for surface in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface)
		arrays[Mesh.ARRAY_CUSTOM0 + channel] = null
		# The other custom channels' formats, which add_surface_from_arrays() cannot infer.
		var format := mesh.surface_get_format(surface)
		var flags := format & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
		if flags != 0:
			arrays[Mesh.ARRAY_VERTEX] = _renudge(arrays[Mesh.ARRAY_VERTEX])
		for c in range(4):
			if c == channel:
				continue
			var shift := Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT + c * Mesh.ARRAY_FORMAT_CUSTOM_BITS
			flags |= format & (Mesh.ARRAY_FORMAT_CUSTOM_MASK << shift)
		stripped.add_surface_from_arrays(mesh.surface_get_primitive_type(surface), arrays, [], {},
				flags)
		stripped.surface_set_material(surface, mesh.surface_get_material(surface))
		stripped.surface_set_name(surface, mesh.surface_get_name(surface))
	return stripped


## Compressed positions ready to compress again. Godot truncates when it encodes, and a decoded
## position can come out a float rounding below its lattice point, which would truncate a whole step
## down and open a crack; half a step up truncates back to the same point. The bounds, set by the
## builder's two padding vertices, are kept exactly, so the lattice stays the same.
static func _renudge(positions: PackedVector3Array) -> PackedVector3Array:
	var low := positions[0]
	var high := positions[0]
	for p in positions:
		low = low.min(p)
		high = high.max(p)
	var half := (high - low) / 65535.0 * 0.5
	for i in range(positions.size()):
		var p := positions[i]
		for axis in range(3):
			if p[axis] > low[axis]:
				p[axis] = minf(p[axis] + half[axis], high[axis])
		positions[i] = p
	return positions
