@tool
extends EditorScenePostImportPlugin

## Import options for building cluster LODs: the builder's settings, and nothing else.
##
## Off by default: every imported scene gets the options, but nothing happens until Build Lod is
## ticked in the Import dock, so adding the plugin cannot change how an existing project imports.
## [br][br]
##
## The build blocks the editor for its whole duration, unlike Regenerate. That is Godot's import
## model: the scene must be finished when the import returns, and no script API lets the editor
## redraw meanwhile. The build still runs on a worker thread, so its progress reaches the output
## live.

# The ways round the blocking build (a DAG cache keyed on source geometry and settings, then
# building in the background after the import) are recorded in GODOTITE.md under Deferred.
#
# This file is a shell on purpose. `get_option_value()` is native and cannot be stubbed, and this
# class cannot be instantiated outside the editor at all, so everything testable lives in
# GodotiteConverter instead. Loaded by path rather than class name: a `class_name` reference
# resolves through the editor's class cache, and a stale cache would break this file silently.
const Converter := preload("res://addons/godotite/godotite_converter.gd")


## The builder's own settings, so an import can do anything a GodotiteBuilder node can, laid out as
## the node lays them out: the basics under Godotite, the rest under Godotite > Advanced, in the same
## subgroups. Read from the builder script's property list, not restated here, so a setting added to
## the builder reaches the importer with its type, default and range, and the two cannot drift. [br][br]
##
## Left out: what makes no sense on an import. Source and Output are the imported meshes and the
## nodes replacing them, Material is the import's own material handling, and Create Debug Nodes is
## for inspecting a build in an edited scene. The error threshold is not a build setting: it is the
## project's (Project Settings, Godotite > LOD > Error Threshold), with an override on any node. [br][br]
##
## Import options take no tooltip (Godot's API has no place for one), so the options are documented
## in the addon's README, each under the builder property it sets.
func _get_import_options(_path: String) -> void:
	# Rebuilds the dock's list when toggled, so the build settings show and hide with it: without
	# the flag the dock only asks _get_option_visibility() when a file is selected.
	add_import_option_advanced(TYPE_BOOL, "godotite/build_lod", false, PROPERTY_HINT_NONE, "",
			PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_UPDATE_ALL_IF_MODIFIED)
	for option in Converter.build_options():
		add_import_option_advanced(option.type, option.option, option.default, option.hint,
				option.hint_string)


func _get_option_visibility(_path: String, _for_animation: bool, option: String) -> Variant:
	# Hide the build settings until the feature is actually switched on.
	if option.begins_with("godotite/") and option != "godotite/build_lod":
		return get_option_value("godotite/build_lod")
	return null


func _post_process(scene: Node) -> void:
	if not bool(get_option_value("godotite/build_lod")):
		return
	var settings := {}
	for option in Converter.build_options():
		settings[option.property] = get_option_value(option.option)
	Converter.new().build_lods(scene, settings)
