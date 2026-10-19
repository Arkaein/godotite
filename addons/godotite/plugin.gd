@tool
extends EditorPlugin

## Registers the scene post-import hook, the export plugin, the project settings (error threshold,
## DAG folder) and two Tools menu items (Rebuild Missing DAGs, Find Unused DAGs). The work is in
## import_plugin.gd, godotite_export.gd, godotite_lod.gd, godotite_builder.gd and
## godotite_project.gd.
##
## A post-import plugin rather than an EditorImportPlugin of our own. Claiming `.glb` outright would
## mean reimplementing glTF and competing with Godot's built-in importer for the extension, and
## `.blend` would need doing separately. Hooking the scene import that already exists inherits
## Godot's glTF and Blender handling, its materials and its textures, and covers every format that
## routes through it.

const GodotiteImportPlugin := preload("res://addons/godotite/import_plugin.gd")
const GodotiteExportPlugin := preload("res://addons/godotite/godotite_export.gd")
const LodScript := preload("res://addons/godotite/godotite_lod.gd")
const BuilderScript := preload("res://addons/godotite/godotite_builder.gd")
const Project := preload("res://addons/godotite/godotite_project.gd")

const REBUILD_MENU := "Godotite: Rebuild Missing DAGs"
const UNUSED_MENU := "Godotite: Find Unused DAGs"

var _import_plugin: EditorScenePostImportPlugin = null
var _export_plugin: EditorExportPlugin = null


func _enter_tree() -> void:
	_import_plugin = GodotiteImportPlugin.new()
	add_scene_post_import_plugin(_import_plugin)
	_export_plugin = GodotiteExportPlugin.new()
	add_export_plugin(_export_plugin)
	# Saved in project.godot only when changed; a game reads the defaults otherwise. Left in place
	# when the plugin is disabled, so a changed value is not lost.
	_add_setting(LodScript.ERROR_THRESHOLD_SETTING, LodScript.DEFAULT_ERROR_THRESHOLD,
			PROPERTY_HINT_RANGE, "0.1,100,0.1,or_greater")
	_add_setting(BuilderScript.DAG_FOLDER_SETTING, BuilderScript.DEFAULT_DAG_FOLDER, PROPERTY_HINT_DIR)
	add_tool_menu_item(REBUILD_MENU, _rebuild_missing_dags)
	add_tool_menu_item(UNUSED_MENU, _find_unused_dags)


func _exit_tree() -> void:
	remove_tool_menu_item(REBUILD_MENU)
	remove_tool_menu_item(UNUSED_MENU)
	if _import_plugin != null:
		remove_scene_post_import_plugin(_import_plugin)
		_import_plugin = null
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


func _add_setting(setting: String, default: Variant, hint: PropertyHint,
		hint_string: String = "") -> void:
	if not ProjectSettings.has_setting(setting):
		ProjectSettings.set_setting(setting, default)
	ProjectSettings.set_initial_value(setting, default)
	ProjectSettings.add_property_info({ "name": setting, "type": typeof(default), "hint": hint,
			"hint_string": hint_string })
	ProjectSettings.set_as_basic(setting, true)


# --- Rebuild Missing DAGs ---
# Every GodotiteLOD whose DAG file is missing (not built yet on this checkout, or deleted), rebuilt
# by the builders whose Output it is: each scene is opened, built and saved in turn. Rebuilt files
# keep the path and UID their scenes expect.

func _rebuild_missing_dags() -> void:
	var missing := {}
	for scene in Project.scene_paths():
		for reference in Project.dag_references_in_scene(scene):
			if not ResourceLoader.exists(reference.path):
				missing.get_or_add(scene, []).append("%s (%s)" % [ reference.node, reference.path ])
	if missing.is_empty():
		_tell("Rebuild Missing DAGs", "No DAG files are missing.")
		return
	var lines := PackedStringArray()
	for scene in missing:
		lines.append("%s: %s" % [ scene, ", ".join(missing[scene]) ])
	_ask("Rebuild Missing DAGs", "Build the missing DAGs of these scenes? Each is opened, built and "
			+ "saved; building can take a while.\n\n" + "\n".join(lines), "Rebuild",
			_rebuild.bind(missing.keys()))


func _rebuild(scenes: Array) -> void:
	var built := 0
	var unbuilt := PackedStringArray()
	for scene in scenes:
		EditorInterface.open_scene_from_path(scene)
		await get_tree().process_frame
		var root := EditorInterface.get_edited_scene_root()
		if root == null or root.scene_file_path != scene:
			unbuilt.append(scene + " (could not be opened)")
			continue
		# By script, not by find_children()'s type, which knows only engine classes.
		var nodes: Array[Node] = [ root ]
		nodes.append_array(root.find_children("*", "", true, false))
		var builders := nodes.filter(func(node: Node) -> bool: return node is BuilderScript)
		for lod in nodes:
			if not (lod is LodScript and lod.is_dag_missing()):
				continue
			var builder: Node = null
			for candidate in builders:
				if candidate.get_output_node() == lod:
					builder = candidate
			if builder == null:
				unbuilt.append("%s: %s (no GodotiteBuilder has it as Output)" % [ scene, lod.name ])
				continue
			await builder.build_dag()
			if lod.is_dag_missing():
				unbuilt.append("%s: %s (the build failed; see the Output panel)" % [ scene, lod.name ])
			else:
				built += 1
		EditorInterface.mark_scene_as_unsaved()
		EditorInterface.save_scene()
	var message := "Built %d DAG(s)." % built
	if not unbuilt.is_empty():
		message += "\n\nNot built:\n" + "\n".join(unbuilt)
	_tell("Rebuild Missing DAGs", message)


# --- Find Unused DAGs ---
# DAG files no saved scene, resource or script refers to, by path or by UID: left behind by deleted
# scenes, builders or LOD nodes. Every DAG can be rebuilt, so deleting one by mistake costs only the
# build.

func _find_unused_dags() -> void:
	var referenced := Project.referenced_strings()
	var dags := Project.dag_files()
	var by_uid := {}
	for path in dags:
		by_uid.get_or_add(Project.uid_text(path), []).append(path)
	var unused := PackedStringArray()
	var total := 0
	var lines := PackedStringArray()
	for path in dags:
		if referenced.has(path):
			continue
		# Used by its UID, unless another file has the same UID (a copy, or a file Godot re-saved at
		# an old path) and is the one the scene names by path.
		var uid := Project.uid_text(path)
		if not uid.is_empty() and referenced.has(uid) and not by_uid[uid].any(
				func(other: String) -> bool: return other != path and referenced.has(other)):
			continue
		var size := FileAccess.open(path, FileAccess.READ).get_length()
		unused.append(path)
		total += size
		lines.append("%s (%s)" % [ path, String.humanize_size(size) ])
	if unused.is_empty():
		_tell("Find Unused DAGs", "Every DAG file is used.")
		return
	_ask("Find Unused DAGs", ("%d DAG file(s), %s, are not used by any saved scene, resource or "
			+ "script. Only saved files are searched: save open scenes first.\n\n%s")
			% [ unused.size(), String.humanize_size(total), "\n".join(lines) ],
			"Delete", _delete.bind(unused))


func _delete(paths: PackedStringArray) -> void:
	for path in paths:
		DirAccess.remove_absolute(path)
	EditorInterface.get_resource_filesystem().scan()
	print("Godotite: deleted %d unused DAG file(s)" % paths.size())


# --- dialogs ---

func _tell(title: String, text: String) -> void:
	var dialog := AcceptDialog.new()
	_show(dialog, title, text)


func _ask(title: String, text: String, action: String, on_confirmed: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.ok_button_text = action
	dialog.confirmed.connect(on_confirmed)
	_show(dialog, title, text)


func _show(dialog: AcceptDialog, title: String, text: String) -> void:
	dialog.title = title
	dialog.dialog_text = text
	dialog.dialog_autowrap = true
	dialog.min_size = Vector2i(640, 0)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()
