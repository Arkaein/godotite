@tool
class_name GodotiteConverter
extends RefCounted

## Replaces the large meshes in a scene with [GodotiteLOD] nodes, as the importer does.
##
## The importer's Build Lod option runs [method build_lods] on each imported scene; call it from a
## script to do the same to any scene, for example one assembled in code. It takes the
## [GodotiteBuilder] settings by name, and [method build_options] lists them as the importer offers
## them. Meshes under [constant MIN_SOURCE_TRIANGLES] are left as they are.

# Deliberately NOT an editor class. `EditorScenePostImportPlugin` cannot even be instantiated
# outside the editor — `new()` returns null — so any logic living on it is untestable by anything
# except a real import. Keeping the work here and leaving the import plugin a shell that reads
# options and delegates means all of it can be driven by a plain script.
#
# The build itself is the same code the Regenerate button runs, `build_from_mesh()` on the builder
# script, instantiated off-tree. There is deliberately no second implementation to drift.

# The GodotiteBuilder script, which builds each mesh.
const _BuilderScript := preload("res://addons/godotite/godotite_builder.gd")

# Smallest mesh worth clustering — 2^17, which is a 256x256 terrain grid.
#
# Set for TESTING rather than for production. The cost model puts the real floor nearer **250,000
# triangles**: below that the triangles a cut removes are worth less than the draw calls it adds,
# and the DAG costs more in memory and build time than it returns. 131,072 sits below that
# deliberately, so a modest test asset still exercises the whole pipeline.
#
# It was 512, which is three orders of magnitude too low and dated from a period when the largest
# test mesh was a 12k-triangle sphere.
#
# **The floor drops with vertex-shader cost.** The model's break-even is
# `r < S / (S + c_draw/c_tri)`, so anything that raises the per-triangle cost — skinning,
# displacement, procedural animation, heavy vertex work of any kind — makes clustering pay on
# smaller meshes, and makes smaller clusters optimal. The 250,000 figure assumes a trivial vertex
# shader, which is the worst case for Godotite.
#
# Also still doing its original job: keeping a collision proxy or marker mesh riding along in the
# same imported file from being clustered.
## Meshes with fewer triangles are left as they are: clustering pays on large meshes, and this
## also leaves alone the small collision proxies and markers that often share a file with them.
const MIN_SOURCE_TRIANGLES := 131_072


# Builder settings that are not import options: Create Debug Nodes is for inspecting a build in an
# edited scene. (Source, Output and Material are not plain values, so never options.)
const _EXCLUDED_OPTIONS := [ &"create_debug_nodes" ]


## The import options, one per builder setting: its option name ("godotite/...", with the builder's
## group and subgroup as sections), the builder property it sets, and the property's type, hint,
## hint string and default. Only plain values (bool, int, float) are options.
static func build_options() -> Array[Dictionary]:
	var builder_script: Script = _BuilderScript
	var options: Array[Dictionary] = []
	var group := ""
	var subgroup := ""
	for property in builder_script.get_script_property_list():
		if property.usage & PROPERTY_USAGE_GROUP:
			group = property.name.to_snake_case()
			subgroup = ""
		elif property.usage & PROPERTY_USAGE_SUBGROUP:
			subgroup = property.name.to_snake_case()
		elif property.usage & PROPERTY_USAGE_EDITOR and property.type in [ TYPE_BOOL, TYPE_INT, TYPE_FLOAT ] \
				and not property.name in _EXCLUDED_OPTIONS:
			var path := "godotite/"
			for part in [ group, subgroup ]:
				if not part.is_empty():
					path += part + "/"
			options.append({ "option": path + property.name, "property": property.name,
					"type": property.type, "hint": property.hint, "hint_string": property.hint_string,
					"default": builder_script.get_property_default_value(property.name) })
	return options


# Convert every mesh in `scene` that is worth clustering. Returns how many were converted.
#
# Takes settings explicitly rather than reading import options, so it can be driven directly by a
# test with no editor and no import in progress.
## Replaces every mesh in [param scene] large enough to be worth it ([constant MIN_SOURCE_TRIANGLES])
## with a GodotiteLOD, in place, keeping its name, transform and place in the tree. [param settings] are
## GodotiteBuilder properties by name; any left out keep their defaults. Returns how many meshes
## were converted.
func build_lods(scene: Node, settings: Dictionary) -> int:
	# Collected first, then converted. Rewriting the tree while walking it is how you miss nodes.
	var targets: Array[MeshInstance3D] = []
	_collect_meshes(scene, targets)

	var converted := 0
	var skipped := 0
	for target in targets:
		var mesh := target.mesh as ArrayMesh
		if mesh == null or _triangle_count(mesh) < MIN_SOURCE_TRIANGLES:
			skipped += 1
			continue
		if _convert(scene, target, settings):
			converted += 1
		else:
			skipped += 1
	print("Godotite: built %d LOD hierarch%s, skipped %d mesh(es)"
			% [ converted, "y" if converted == 1 else "ies", skipped ])
	return converted


func _collect_meshes(node: Node, into: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.mesh is ArrayMesh:
		into.append(node)
	for child in node.get_children():
		_collect_meshes(child, into)


func _triangle_count(mesh: ArrayMesh) -> int:
	var total := 0
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = mesh.surface_get_arrays(surface)
		# A non-indexed surface stores null here, not an empty array, so this cannot be typed.
		var indices = arrays[Mesh.ARRAY_INDEX]
		if indices != null and indices.size() > 0:
			@warning_ignore("integer_division")
			total += indices.size() / 3
		else:
			@warning_ignore("integer_division")
			total += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return total


# Replace one MeshInstance3D with a GodotiteLOD built from its mesh, in place.
func _convert(scene: Node, target: MeshInstance3D, settings: Dictionary) -> bool:
	var builder: Node = _BuilderScript.new()
	# Only what was actually supplied is applied; everything else keeps the builder's own default.
	#
	# This used to restate each default here — `settings.get("min_cluster_triangles", 256)` and so
	# on — which is two sources of truth for one number. They drifted exactly once, the builder
	# saying 2048 while this said 256, and it stayed hidden for a long time because the authoring
	# scene overrode the property, so only a builder constructed in code ever saw the difference.
	for key in settings:
		if key in builder:
			builder.set(key, settings[key])

	var built: Dictionary = builder.build_from_mesh(target.mesh)
	if built.is_empty():
		builder.free()
		return false

	var lod: GodotiteLOD = builder.assemble_lod_node(built)
	# Keep the source node's identity: its name, where it sat, and what it was parented to. Anything
	# referring to it by path in the rest of the scene still resolves.
	lod.name = target.name
	lod.transform = target.transform
	var parent := target.get_parent()
	var index := target.get_index()
	var target_owner := target.owner

	parent.remove_child(target)
	target.queue_free()
	parent.add_child(lod)
	parent.move_child(lod, index)

	# Everything the import produces has to be owned by the scene root or it is dropped when the
	# result is packed. assemble_lod_node() owned the cluster nodes to the LOD node, which is right
	# for a standalone scene and wrong here, so they are re-owned to this scene's root.
	var root: Node = target_owner if target_owner != null else scene
	_own_recursive(lod, root)
	builder.free()
	return true


func _own_recursive(node: Node, root: Node) -> void:
	if node != root:
		node.owner = root
	for child in node.get_children():
		_own_recursive(child, root)
