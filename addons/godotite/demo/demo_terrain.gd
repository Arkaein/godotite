@tool
extends MeshInstance3D

## The demo's terrain: a heightmap generated from noise, for a GodotiteBuilder to build.
##
## Press Generate to make the mesh: it is saved in the project's DAG folder (Project Settings,
## Godotite > Build > DAG Folder), like the DAG, and then built by the GodotiteBuilder whose Source
## is this node. Nothing is generated when the scene opens; the node warns until it has a mesh.
## [br][br]
##
## The mesh is colored by height and slope through vertex colors, so a plain StandardMaterial3D
## draws it: Godotite needs no custom shader. Set [member resolution] to try larger meshes.

## Generate the terrain from the settings below, then build its LOD.
@export_tool_button("Generate", "Reload") var generate_action := generate

## Quads along each side: the mesh has 2 x resolution^2 triangles. 512 makes 524,288 triangles,
## 2048 about 8.4 million. Larger takes longer to generate and to build.
@export_range(128, 2048, 64) var resolution: int = 1024

## Width and depth of the terrain, in metres.
@export var size: float = 2000.0

## Height of the highest peaks, in metres.
@export var height: float = 260.0

## Seed of the noise: each makes a different terrain.
@export var noise_seed: int = 7

## The size of the largest hills, in metres: smaller makes busier terrain.
@export var feature_size: float = 700.0

const _Log := preload("res://addons/godotite/godotite_log.gd")

# Colors by height, low to high, and for steep rock: saturated, so the clusters' level of detail
# reads clearly against them.
const _LOW := Color(0.18, 0.52, 0.12)
const _MID := Color(0.55, 0.42, 0.16)
const _HIGH := Color(0.95, 0.95, 0.98)
const _ROCK := Color(0.42, 0.36, 0.33)

var _generating := false


func _get_configuration_warnings() -> PackedStringArray:
	if mesh == null and not ResourceLoader.exists(get_meta(GodotiteUtil.MESH_PATH_META, "")):
		return PackedStringArray([ "No terrain yet: press Generate." ])
	return PackedStringArray()


## Makes the heightmap mesh, saves it, and builds it with the GodotiteBuilder whose Source is this
## node; await it. Editor only.
func generate() -> void:
	if not Engine.is_editor_hint() or _generating:
		return
	var root := get_tree().edited_scene_root
	if root == null or root.scene_file_path.is_empty():
		push_warning("Godotite demo: save the scene first; the terrain is saved beside its DAG.")
		return
	_generating = true
	var started := Time.get_ticks_msec()
	_Log.log("[godotite demo] generating %d x %d terrain (%s triangles)..." % [ resolution,
			resolution, String.num_int64(2 * resolution * resolution) ])
	var terrain := _build_mesh()
	var folder: String = ProjectSettings.get_setting(GodotiteBuilder.DAG_FOLDER_SETTING,
			GodotiteBuilder.DEFAULT_DAG_FOLDER)
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("%s_%s_mesh.res" % [
			root.scene_file_path.get_file().get_basename(), name ])
	terrain.take_over_path(path)
	ResourceSaver.save(terrain)
	mesh = terrain
	_Log.log("[godotite demo] terrain made in %.1f s, saved to %s" % [
			(Time.get_ticks_msec() - started) / 1000.0, path ])
	update_configuration_warnings()

	var builder := _builder()
	if builder == null:
		push_warning("Godotite demo: no GodotiteBuilder has this node as Source; add one to build it.")
	else:
		await builder.build_dag()
	# Hidden, as the source of a built LOD, it keeps only its mesh's path.
	if not visible:
		GodotiteUtil.release_mesh(self)
	GodotiteUtil.mark_scene_unsaved()
	_generating = false


func _builder() -> GodotiteBuilder:
	for node in get_tree().edited_scene_root.find_children("*", "Node3D", true, false):
		if node is GodotiteBuilder and node.get_source_node() == self:
			return node
	return null


func _build_mesh() -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = noise_seed
	noise.frequency = 1.0 / maxf(feature_size, 1.0)
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 7

	var side := resolution + 1
	var step := size / resolution
	var heights := PackedFloat32Array()
	heights.resize(side * side)
	for z in side:
		for x in side:
			heights[z * side + x] = noise.get_noise_2d(x * step, z * step)
	# Stretched to 0..1, since fractal noise seldom reaches its full range, then squared: broad low
	# valleys, fewer and sharper peaks, and the highest exactly Height.
	var lowest := heights[0]
	var highest := heights[0]
	for value in heights:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	var span := maxf(highest - lowest, 0.0001)
	for i in heights.size():
		var n := (heights[i] - lowest) / span
		heights[i] = n * n * height

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	vertices.resize(side * side)
	normals.resize(side * side)
	uvs.resize(side * side)
	colors.resize(side * side)
	var half := size * 0.5
	for z in side:
		for x in side:
			var i := z * side + x
			var h := heights[i]
			var left := heights[z * side + maxi(x - 1, 0)]
			var right := heights[z * side + mini(x + 1, resolution)]
			var back := heights[maxi(z - 1, 0) * side + x]
			var front := heights[mini(z + 1, resolution) * side + x]
			var normal := Vector3(left - right, 2.0 * step, back - front).normalized()
			vertices[i] = Vector3(x * step - half, h, z * step - half)
			normals[i] = normal
			uvs[i] = Vector2(float(x) / resolution, float(z) / resolution)
			colors[i] = _color(h / maxf(height, 0.001), normal.y)

	var indices := PackedInt32Array()
	indices.resize(resolution * resolution * 6)
	var at := 0
	for z in resolution:
		for x in resolution:
			var a := z * side + x
			var b := a + 1
			var c := a + side
			var d := c + 1
			indices[at] = a
			indices[at + 1] = b
			indices[at + 2] = c
			indices[at + 3] = b
			indices[at + 4] = d
			indices[at + 5] = c
			at += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var terrain := ArrayMesh.new()
	terrain.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 0.95
	terrain.surface_set_material(0, material)
	return terrain


static func _color(level: float, upness: float) -> Color:
	var color := _LOW.lerp(_MID, smoothstep(0.15, 0.45, level))
	color = color.lerp(_HIGH, smoothstep(0.55, 0.75, level))
	return color.lerp(_ROCK, smoothstep(0.75, 0.55, upness))
