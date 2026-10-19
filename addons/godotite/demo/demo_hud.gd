extends CanvasLayer

## An overlay for looking at Godotite LODs: what is drawn and what it costs, and keys to change the
## error threshold, freeze the cut and show the clusters.
##
## Finds every GodotiteLOD below its parent and reports them together: a frame's cost is what all of
## them draw. Settings apply to all of them. [br][br]
##
## The statistics are laid out in columns in a monospace font, numbers right-aligned to fixed widths,
## and refreshed [member refresh_rate] times a second, so they stay readable while they change.
## [br][br]
##
## To add to it, extend this script: [method _help_lines], [method _stat_rows] and
## [method _key_pressed] are there to be added to.

## Each [ or ] press divides or multiplies the error threshold by this.
const THRESHOLD_STEP := 1.25

## Seconds over which the averaged readouts are smoothed.
const SMOOTHING_SECONDS := 1.0

## Size of the overlay's text.
@export var font_size := 20

## How many times a second the statistics are rewritten; 0 for every frame. The averages are still
## taken every frame.
@export var refresh_rate := 6.0

## Start on the LODs' own materials rather than the cluster view; Tab cycles through every view.
@export var start_with_real_materials := false

## Shown when there is no LOD with a DAG to report on: how to make one in this scene.
@export_multiline var build_hint := ("Build one in the editor: press Regenerate on its\n"
		+ "GodotiteBuilder, then save the scene.")

## The GodotiteLOD nodes reported on.
var lods: Array[GodotiteLOD] = []

var _stats: Label = null
var _help: Label = null
var _camera: Camera3D = null
# The views Tab cycles through, with their names: the cluster debug material, the checker, and the
# LODs' own materials (null), last.
var _materials: Array = []
var _material_names := PackedStringArray()
var _material_index := 0
var _checker: ShaderMaterial = null
# Each LOD's own material while it wears a view's, and its own copy of each view's material: a
# LOD writes its debug settings (its debug channel, its levels) into the material it wears.
var _own_materials := {}
var _view_copies := {}
var _ema_fps := 0.0
var _ema_select := 0.0
var _ema_render_cpu := 0.0
var _ema_render_gpu := 0.0
var _since_refresh := INF

## Width the value column is right-aligned to, in characters.
const VALUE_WIDTH := 11

## In a row's third place, [code][name, text, LEFT][/code]: the text starts where the value column
## does, left-aligned, and may run past it. For long words, which right-aligned would push far out.
const LEFT := &"left"

# Totals over every LOD, sampled each frame by _sample().
var _full := 0
var _drawn := 0
var _drawn_clusters := 0
var _total_clusters := 0
var _draw_calls := 0
var _select_usec := 0
var _render_cpu := 0.0
var _render_gpu := 0.0


func _ready() -> void:
	_stats = _label(Control.PRESET_TOP_LEFT, Color(0.85, 0.95, 1.0))
	# Monospace from the system rather than a font file shipped with the addon: Consolas, Menlo,
	# DejaVu Sans Mono or whatever the system calls monospace. With none, Godot's default font
	# stands in, which only loses the alignment.
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray([ "Consolas", "Menlo", "DejaVu Sans Mono",
			"Liberation Mono", "Noto Sans Mono", "monospace" ])
	_stats.add_theme_font_override("font", mono)
	_help = _label(Control.PRESET_BOTTOM_LEFT, Color(1.0, 0.95, 0.8))
	_help.text = "\n".join(_help_lines())
	_find_lods(get_parent())
	if lods.is_empty():
		return
	_checker = load("res://addons/godotite/tools/graybox_checker.tres")
	_checker.set_shader_parameter("checker_space", 1 if _has_uvs() else 0)
	_materials = [ load("res://addons/godotite/tools/cluster_debug.tres"), _checker ]
	_material_names = PackedStringArray([ "cluster debug", "checker" ])
	# A LOD of several materials with one set over them all (an import's, say) can show either: its
	# Material, as "source", or its own per-surface ones.
	if lods[0].material != null and lods[0].materials.size() > 1:
		_materials.append(lods[0].material)
		_material_names.append("source (%s)" % _material_label(lods[0].material))
	_materials.append(null)
	_material_names.append("own materials")
	_material_index = _materials.size() - 1 if start_with_real_materials else 0
	_apply_material()
	# Without this the renderer's measured times read 0.
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)


## The help text, a line each. Extend to add lines.
func _help_lines() -> PackedStringArray:
	return PackedStringArray([
		"WASD QE move   mouse look   wheel or + - speed   Backspace reset speed   Shift fast   Ctrl slow   Esc release mouse",
		"[ ] error threshold   \\ freeze the cut   Tab material   C cluster colors   F flat shading   U checker space   V uncap fps   H hide",
	])


## The statistics shown, a row each: [code][name, value, note][/code], the note optional. Values
## are right-aligned in one column, notes follow; text reads best as [code][name, text, LEFT][/code]
## (see [constant LEFT]). Extend to add rows: format numbers to a fixed width
## (as [code]"%6.1f"[/code] does) so they keep their place as they change.
func _stat_rows() -> Array:
	var lod := lods[0]
	var camera_speed: float = _camera.get("speed") if _camera != null and "speed" in _camera else 0.0
	return [
		[ "fps", "%d" % Engine.get_frames_per_second(), "avg %4.0f%s" % [ _ema_fps,
				"" if _vsync_on() else "  UNCAPPED" ] ],
		[ "render cpu", "%.2f ms" % _render_cpu, "avg %6.2f" % _ema_render_cpu ],
		[ "render gpu", "%.2f ms" % _render_gpu, "avg %6.2f" % _ema_render_gpu ],
		[ "triangles", comma(_drawn), "of %s  %5.1f%%" % [ comma(_full),
				100.0 * _drawn / maxi(_full, 1) ] ],
		[ "clusters", comma(_drawn_clusters), "of %s" % comma(_total_clusters) ],
		[ "draw calls", comma(_draw_calls) ],
		[ "error thresh", "%.1f px" % lod.effective_error_threshold() ],
		[ "select", "%d us" % _select_usec, "avg %6.0f%s" % [ _ema_select,
				"" if lod.auto_update else "  FROZEN" ] ],
		[ "camera speed", "%.1f m/s" % camera_speed ],
		[ "material", _material_names[_material_index], LEFT ],
		[ "color", GodotiteLOD.ColorMode.keys()[lod.color_mode].to_lower(), LEFT ],
		[ "checker", "UV" if _checker != null
				and int(_checker.get_shader_parameter("checker_space")) == 1 else "world", LEFT ],
	]


# Totals over every LOD and the averages, every frame: the averages need every frame's sample even
# when the text is rewritten less often.
func _sample(delta: float) -> void:
	_full = 0
	_drawn = 0
	_drawn_clusters = 0
	_total_clusters = 0
	_draw_calls = 0
	_select_usec = 0
	for lod in lods:
		if lod.dag == null or not lod.dag.is_valid():
			continue
		_full += lod.full_detail_triangles()
		_drawn += lod.drawn_triangles
		_drawn_clusters += lod.drawn_clusters
		_total_clusters += lod.dag.cluster_count
		_draw_calls += lod.drawn_surfaces
		_select_usec += lod.last_select_usec
	var viewport := get_viewport().get_viewport_rid()
	_render_cpu = RenderingServer.viewport_get_measured_render_time_cpu(viewport)
	_render_gpu = RenderingServer.viewport_get_measured_render_time_gpu(viewport)
	_ema_fps = _smooth(_ema_fps, Engine.get_frames_per_second(), delta)
	_ema_select = _smooth(_ema_select, float(_select_usec), delta)
	_ema_render_cpu = _smooth(_ema_render_cpu, _render_cpu, delta)
	_ema_render_gpu = _smooth(_ema_render_gpu, _render_gpu, delta)


# The rows as columns: names padded to the longest, values right-aligned to VALUE_WIDTH (wider ones
# push their note along), notes after.
static func _columns(rows: Array) -> String:
	var name_width := 0
	for row: Array in rows:
		name_width = maxi(name_width, String(row[0]).length())
	var lines := PackedStringArray()
	for row: Array in rows:
		var line := String(row[0]).rpad(name_width + 2)
		if row.size() > 2 and row[2] is StringName and row[2] == LEFT:
			lines.append(line + String(row[1]))
			continue
		line += String(row[1]).lpad(VALUE_WIDTH)
		if row.size() > 2 and not String(row[2]).is_empty():
			line += "  " + String(row[2])
		lines.append(line)
	return "\n".join(lines)


## Handles a key press; returns whether it was used. Extend to add keys, calling this first.
func _key_pressed(event: InputEventKey) -> bool:
	match event.keycode:
		KEY_H:
			_stats.visible = not _stats.visible
			_help.visible = _stats.visible
		KEY_V:
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED if _vsync_on()
					else DisplayServer.VSYNC_ENABLED)
		# The global threshold, as a game's graphics setting would set it.
		KEY_BRACKETLEFT:
			GodotiteLOD.set_global_error_threshold(
					maxf(GodotiteLOD.get_global_error_threshold() / THRESHOLD_STEP, 0.1))
		KEY_BRACKETRIGHT:
			GodotiteLOD.set_global_error_threshold(
					minf(GodotiteLOD.get_global_error_threshold() * THRESHOLD_STEP, 100000.0))
		KEY_BACKSLASH:
			# Freezes the cut where it is, to fly away and see what was chosen.
			for lod in lods:
				lod.auto_update = not lod.auto_update
		KEY_TAB:
			if not _materials.is_empty():
				_material_index = (_material_index + 1) % _materials.size()
				_apply_material()
		KEY_C:
			if not lods.is_empty():
				var mode := (lods[0].color_mode + 1) % GodotiteLOD.ColorMode.size()
				for lod in lods:
					lod.color_mode = mode as GodotiteLOD.ColorMode
		KEY_F:
			for copies: Dictionary in _view_copies.values():
				for material in copies.values():
					if material is ShaderMaterial and material.get_shader_parameter("flat_shading") != null:
						material.set_shader_parameter("flat_shading",
								not bool(material.get_shader_parameter("flat_shading")))
		KEY_U:
			if _checker != null:
				var space := 1 - int(_checker.get_shader_parameter("checker_space"))
				_checker.set_shader_parameter("checker_space", space)
				for copies: Dictionary in _view_copies.values():
					if copies.has(_checker):
						copies[_checker].set_shader_parameter("checker_space", space)
		_:
			return false
	return true


## What to show when there is nothing to report on.
func _nothing_to_show() -> String:
	return ("No GodotiteLOD in the scene." if lods.is_empty() else "No DAG to draw yet.") \
			+ "\n\n" + build_hint


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_key_pressed(event)


func _process(delta: float) -> void:
	if not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
	var any_dag := false
	for lod in lods:
		any_dag = any_dag or (lod.dag != null and lod.dag.is_valid())
	if not any_dag:
		_stats.text = _nothing_to_show()
		return
	_sample(delta)
	_since_refresh += delta
	if refresh_rate > 0.0 and _since_refresh < 1.0 / refresh_rate:
		return
	_since_refresh = 0.0
	_stats.text = _columns(_stat_rows())


# Puts every LOD in the chosen view, each in its own copy of the view's material. A LOD without
# debug data keeps its own material in the cluster view.
func _apply_material() -> void:
	var chosen = _materials[_material_index]
	for lod in lods:
		var copies: Dictionary = _view_copies.get_or_add(lod, {})
		if not copies.values().has(lod.material):
			_own_materials[lod] = lod.material
		if chosen == null or (chosen.resource_path.ends_with("cluster_debug.tres")
				and (lod.dag == null or lod.dag.debug_channel < 0)):
			lod.material = _own_materials.get(lod)
			continue
		# The source view is the first LOD's own Material: the others keep theirs.
		if lod != lods[0] and _material_names[_material_index].begins_with("source"):
			lod.material = _own_materials.get(lod)
			continue
		if not copies.has(chosen):
			copies[chosen] = chosen.duplicate()
		lod.material = copies[chosen]


func _find_lods(node: Node) -> void:
	if node is GodotiteLOD:
		lods.append(node)
	for child in node.get_children():
		_find_lods(child)


static func _material_label(material: Material) -> String:
	return material.resource_path.get_file().get_basename() if not material.resource_path.is_empty() \
			else material.get_class()


func _has_uvs() -> bool:
	for mesh in (lods[0].dag.meshes if lods[0].dag != null else []):
		if mesh != null and mesh.get_surface_count() > 0:
			return mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] != null
	return false


func _label(preset: Control.LayoutPreset, color: Color) -> Label:
	var label := Label.new()
	add_child(label)
	label.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE, 12)
	# Anchored to the bottom or right, a label grows up or left as its text grows.
	if preset in [ Control.PRESET_BOTTOM_LEFT, Control.PRESET_BOTTOM_RIGHT ]:
		label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	if preset in [ Control.PRESET_TOP_RIGHT, Control.PRESET_BOTTOM_RIGHT ]:
		label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _vsync_on() -> bool:
	return DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED


# An exponential moving average whose weight follows the frame time, so it smooths over the same
# time at any frame rate.
func _smooth(current: float, sample: float, delta: float) -> float:
	if current <= 0.0:
		return sample
	return current + (sample - current) * (1.0 - exp(-delta / SMOOTHING_SECONDS))


## A count with thousands separators.
static func comma(value: int) -> String:
	var text := str(value)
	var out := ""
	for i in text.length():
		if i > 0 and (text.length() - i) % 3 == 0:
			out += ","
		out += text[i]
	return out
