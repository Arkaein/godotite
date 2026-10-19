extends Camera3D

## A fly camera for looking round a Godotite LOD: WASD and Q/E to move, the mouse to look.
##
## Keys are read directly rather than through input actions, so the demo needs no InputMap entries
## and works in any project. [br][br]
##
## Mouse wheel or + and - change speed, Backspace resets it, Shift moves faster and Ctrl slower.
## Escape releases the mouse; a click takes it again.

## Metres per second.
@export var speed: float = 40.0
## Speed while Shift is held, as a multiple of [member speed].
@export var boost_multiplier: float = 6.0
## Speed while Ctrl is held, as a multiple of [member speed].
@export var slow_multiplier: float = 0.15
## Radians per pixel of mouse movement.
@export var mouse_sensitivity: float = 0.0025

var _yaw := 0.0
var _pitch := 0.0
var _mouse_captured := false
# Whether to take the mouse when the window first gains focus: set at start, unless the window may
# never take focus, and cleared once taken or given back with Escape.
var _capture_on_focus := false
var _start_speed := 0.0


# The mouse is taken only while the window has keyboard focus, so pointer and keys always go to the
# same window: on some systems a run window opens without focus, and capturing the pointer then
# left the keys typing into the editor. A window that may never take focus is left alone.
func _ready() -> void:
	_start_speed = speed
	reset_orientation()
	var window := get_window()
	window.focus_entered.connect(_on_focus_entered)
	window.focus_exited.connect(_on_focus_exited)
	if DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS):
		return
	_capture_on_focus = true
	DisplayServer.window_move_to_foreground()
	window.grab_focus()
	if window.has_focus():
		_on_focus_entered()


## Takes the camera's heading and pitch from where it now points. Call after moving or turning it
## from outside, or its next frame turns it back.
func reset_orientation() -> void:
	_yaw = rotation.y
	_pitch = rotation.x
	rotation = Vector3(_pitch, _yaw, 0.0)


## Captures or releases the mouse.
func set_mouse_captured(value: bool) -> void:
	_mouse_captured = value
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if value else Input.MOUSE_MODE_VISIBLE


func _on_focus_entered() -> void:
	if _capture_on_focus:
		_capture_on_focus = false
		set_mouse_captured(true)


func _on_focus_exited() -> void:
	if _mouse_captured:
		set_mouse_captured(false)


func _exit_tree() -> void:
	if _mouse_captured:
		set_mouse_captured(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_look(event.relative * mouse_sensitivity)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				speed = minf(speed * 1.25, 10000.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				speed = maxf(speed / 1.25, 0.1)
			_:
				set_mouse_captured(true)
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				_capture_on_focus = false
				set_mouse_captured(not _mouse_captured)
			KEY_EQUAL, KEY_KP_ADD:
				speed = minf(speed * 1.25, 10000.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				speed = maxf(speed / 1.25, 0.1)
			KEY_BACKSPACE:
				speed = _start_speed


# Turns the camera by a mouse movement, in radians: stopping just short of straight up or down,
# where the heading would be lost.
func _look(turn: Vector2) -> void:
	_pitch = clampf(_pitch - turn.y, -1.5, 1.5)
	_yaw -= turn.x
	rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	var direction := Vector3.ZERO
	# Physical keys, so the layout works on non-QWERTY keyboards.
	if Input.is_physical_key_pressed(KEY_W):
		direction -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		direction += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		direction -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		direction += basis.x
	if Input.is_physical_key_pressed(KEY_E):
		direction += basis.y
	if Input.is_physical_key_pressed(KEY_Q):
		direction -= basis.y
	if direction == Vector3.ZERO:
		return
	var current_speed := speed
	if Input.is_physical_key_pressed(KEY_SHIFT):
		current_speed *= boost_multiplier
	if Input.is_physical_key_pressed(KEY_CTRL):
		current_speed *= slow_multiplier
	position += direction.normalized() * current_speed * delta
