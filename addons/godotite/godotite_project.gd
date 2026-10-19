@tool
extends RefCounted

## Finds DAG files and the references to them across the project, from the saved files alone: for
## the Tools menu's Rebuild Missing DAGs and Find Unused DAGs, and for exporting the DAGs a scene
## refers to by UID. Editor only.

const LodScript := preload("res://addons/godotite/godotite_lod.gd")

## Files searched for references to DAGs: scenes and resources saved as text, scripts, settings.
const TEXT_EXTENSIONS := [ "tscn", "tres", "gd", "cs", "cfg", "godot" ]

static var _reference_pattern: RegEx = null


## Every scene in the project (.tscn and .scn), outside .godot/.
static func scene_paths() -> PackedStringArray:
	return _files_with(PackedStringArray([ "tscn", "scn" ]))


## The DAG references saved in a scene: one { "node", "dag_file", "dag_file_path", "path" } per
## GodotiteLOD node that refers to its DAG by file, "path" being where it resolves to now.
static func dag_references_in_scene(scene_path: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if scene_path.get_extension() == "tscn":
		# Read as text, so a scene is never loaded, nor anything it depends on.
		var node := ""
		var values := {}
		for line in FileAccess.get_file_as_string(scene_path).split("\n"):
			if line.begins_with("["):
				_add_reference(found, node, values)
				node = _attribute(line, "name") if line.begins_with("[node ") else ""
				values = {}
			elif not node.is_empty() and (line.begins_with("dag_file = ") or line.begins_with("dag_file_path = ")):
				values[line.get_slice(" = ", 0)] = line.get_slice(" = ", 1).trim_prefix("\"").trim_suffix("\"")
		_add_reference(found, node, values)
	else:
		var scene := load(scene_path) as PackedScene
		if scene == null:
			return found
		var state := scene.get_state()
		for i in state.get_node_count():
			var values := {}
			for j in state.get_node_property_count(i):
				var property := state.get_node_property_name(i, j)
				if property == &"dag_file" or property == &"dag_file_path":
					values[String(property)] = state.get_node_property_value(i, j)
			_add_reference(found, String(state.get_node_name(i)), values)
	return found


## Every GodotiteDAG saved in a file of its own, by path.
static func dag_files() -> PackedStringArray:
	var found := PackedStringArray()
	for path in _files_with(PackedStringArray([ "res" ])):
		if is_dag_file(path):
			found.append(path)
	return found


## Whether a binary resource file holds a GodotiteDAG, read from its header (which names the
## resource's script class) rather than by loading it: DAG files run to hundreds of megabytes.
static func is_dag_file(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	# Saved compressed (RSCC), as the editor saves resources it writes itself, the header is not
	# readable without loading the file. Builds write DAGs uncompressed, so this is rare.
	if file.get_buffer(4) == "RSCC".to_ascii_buffer():
		return ResourceLoader.load(path) is GodotiteDAG
	file.seek(0)
	var header := file.get_buffer(mini(file.get_length(), 1024))
	return header.slice(0, 4) == "RSRC".to_ascii_buffer() \
			and _contains(header, "GodotiteDAG".to_ascii_buffer())


## Every res:// path and uid:// text written in the project's text files, and every dependency of
## its binary scenes and resources: what a file must appear in to count as used.
static func referenced_strings() -> Dictionary:
	if _reference_pattern == null:
		_reference_pattern = RegEx.create_from_string("(res|uid)://[^\"'\\s)\\]]+")
	var found := {}
	for path in _files_with(PackedStringArray(TEXT_EXTENSIONS)):
		for reference in _reference_pattern.search_all(FileAccess.get_file_as_string(path)):
			found[reference.get_string()] = true
	for path in _files_with(PackedStringArray([ "scn", "res" ])):
		for dependency in ResourceLoader.get_dependencies(path):
			# "uid://...::type::path", or a bare path.
			for part in dependency.split("::"):
				if part.begins_with("res://") or part.begins_with("uid://"):
					found[part] = true
		if path.get_extension() == "scn":
			for reference in dag_references_in_scene(path):
				found[reference.dag_file] = true
	return found


## A DAG file's UID as text, or "" if it has none.
static func uid_text(path: String) -> String:
	var uid := ResourceLoader.get_resource_uid(path)
	return ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""


static func _add_reference(found: Array[Dictionary], node: String, values: Dictionary) -> void:
	var file: String = values.get("dag_file", "")
	if node.is_empty() or file.is_empty():
		return
	var fallback: String = values.get("dag_file_path", "")
	found.append({ "node": node, "dag_file": file, "dag_file_path": fallback,
			"path": LodScript.resolve_dag_reference(file, fallback) })


static func _attribute(line: String, key: String) -> String:
	var start := line.find(key + "=\"")
	if start < 0:
		return ""
	start += key.length() + 2
	return line.substr(start, line.find("\"", start) - start)


static func _contains(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	for start in haystack.size() - needle.size() + 1:
		if haystack.slice(start, start + needle.size()) == needle:
			return true
	return false


static func _files_with(extensions: PackedStringArray, folder: String = "res://") -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at(folder):
		if file.get_extension() in extensions:
			found.append(folder.path_join(file))
	for subfolder in DirAccess.get_directories_at(folder):
		if subfolder.begins_with(".") or FileAccess.file_exists(folder.path_join(subfolder).path_join(".gdignore")):
			continue
		found.append_array(_files_with(extensions, folder.path_join(subfolder)))
	return found
