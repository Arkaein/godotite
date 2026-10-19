@tool
extends RefCounted

## Timestamped output for everything Godotite prints.
##
## An import blocks the editor's main thread, so the Output dock cannot repaint until it returns and
## the messages all arrive at once, after the wait they were meant to explain. (Regenerate builds in
## the background and does not have this problem.) While blocked, progress is only watchable on
## stdout, so launch the editor from a terminal to follow an import live. [br][br]
##
## The log file is NOT an alternative for the editor. It flushes as it goes — a line printed before
## a 20-second blocking loop appeared within seconds — but that was a headless run; the editor
## itself writes no log file (checked 2026-09-24: a whole editor session left nothing in
## user://logs). Headless runs do log, to
## ~/.local/share/godot/app_userdata/<project>/logs/godot.log. [br][br]
##
## Timestamps are what make that worth reading. Without them a stall is indistinguishable from slow
## progress, and the output is useless afterwards for working out where the time actually went. [br][br]
##
## Format is `HH:MM:SS.mmm_uuu`, local wall clock. Wall clock rather than time-since-start
## specifically so a log can be lined up against other evidence — a file's mtime, another process's
## log, the moment a button was pressed. Diagnosing the detail-256 stall came down to noticing the
## DAG resource was written nine minutes before the editor stopped working, and elapsed-time stamps
## could not have shown that.

## Local wall-clock time, in microseconds, at the moment the tick counter read zero. [br][br]
##
## Captured once and every stamp derived from it plus the monotonic tick counter, rather than asking
## the system clock per line: ticks are microsecond-resolution and never jump, so intervals between
## two lines stay exact even if the system clock is adjusted underneath.
static var _epoch_usec: int = -1


static func _epoch() -> int:
	if _epoch_usec < 0:
		# `bias` is the local offset in MINUTES; the unix time is UTC.
		var bias_usec: int = int(Time.get_time_zone_from_system().get("bias", 0)) * 60 * 1_000_000
		var unix_usec := int(Time.get_unix_time_from_system() * 1_000_000.0)
		_epoch_usec = unix_usec + bias_usec - Time.get_ticks_usec()
	return _epoch_usec


## Prints one timestamped line. [br][br]
##
## Named `log` to match the original. Inside THIS class that shadows GDScript's built-in `log()`, the
## natural logarithm — harmless here because nothing in this file does maths, and callers reach it as
## `GodotiteLog.log(...)` where there is no ambiguity.
static func log(message: String) -> void:
	var now := _epoch() + Time.get_ticks_usec()
	@warning_ignore("integer_division")
	var second_of_day := (now / 1_000_000) % 86_400
	@warning_ignore("integer_division")
	print("%02d:%02d:%02d.%03d_%03d: %s" % [
		second_of_day / 3600,
		(second_of_day % 3600) / 60,
		second_of_day % 60,
		(now % 1_000_000) / 1000,
		now % 1000,
		message,
	])
