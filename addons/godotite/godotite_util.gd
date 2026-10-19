@tool
class_name GodotiteUtil
extends RefCounted

## Helpers for build sources: keeping only a source mesh's path, so it is not loaded until a build.
##
## A [GodotiteBuilder]'s source is needed only while building. A builder hides its source on the
## first build and, while it is hidden, lets go of its mesh with [method release_mesh]: the path of
## the mesh's file is kept in the node's metadata ([constant MESH_PATH_META]), so neither the editor
## nor the game loads it when the scene opens. A build, or showing the source again, loads it from
## that path ([method resolve_mesh]). Only a mesh saved in its own file can be let go of. Code
## managing its own sources, as a world generator might, can use the same calls.


## Metadata naming the file a MeshInstance3D's mesh can be loaded from, when the node does not hold
## the mesh itself. A build input needs its mesh only while building, and a game never: a hidden
## source that keeps only the path is neither loaded when the scene opens nor when the game runs.
const MESH_PATH_META := "godotite_mesh_path"


## True for a mesh that lives in its own file, so a node can let go of it and load it again later.
## A mesh embedded in a scene has no file to come back from.
static func is_reloadable(mesh: Mesh) -> bool:
	return mesh != null and not mesh.resource_path.is_empty() and not mesh.resource_path.contains("::")


## Lets go of a node's mesh, keeping its path, if it can be loaded again. Returns true if released.
static func release_mesh(node: MeshInstance3D) -> bool:
	if not is_reloadable(node.mesh):
		return false
	node.set_meta(MESH_PATH_META, node.mesh.resource_path)
	node.mesh = null
	return true


## A node's mesh: the one it holds, or else the one its path names, loaded. Null if neither.
static func resolve_mesh(node: MeshInstance3D) -> Mesh:
	if node.mesh != null:
		return node.mesh
	var path: String = node.get_meta(MESH_PATH_META, "")
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as Mesh


## The mesh as an ArrayMesh, which building needs: itself if it is one, otherwise a copy of its
## triangle surfaces and their materials (for a PrimitiveMesh such as a TorusMesh, or any other
## Mesh). Null for null.
static func to_array_mesh(mesh: Mesh) -> ArrayMesh:
	if mesh == null or mesh is ArrayMesh:
		return mesh as ArrayMesh
	var copy := ArrayMesh.new()
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.is_empty():
			continue
		copy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		copy.surface_set_material(copy.get_surface_count() - 1, mesh.surface_get_material(surface))
	return copy


# In the editor, flags the edited scene as changed, so its tab shows it unsaved and saving before
# running a scene includes it. Changes made by code, such as a build's results, are not flagged on
# their own: the run then loaded the scene as last saved, beside files already rewritten. Looked up
# by name, since EditorInterface does not exist in an exported game, which may run this code too.
## In the editor, marks the edited scene as changed, so it is saved before the project runs. Code
## that changes a scene, such as a build, needs to call it. Does nothing in a game.
static func mark_scene_unsaved() -> void:
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		Engine.get_singleton("EditorInterface").mark_scene_as_unsaved()
