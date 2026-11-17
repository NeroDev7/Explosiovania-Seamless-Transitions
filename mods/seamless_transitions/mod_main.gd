extends Node
## Seamless Transitions for Explosiovania.
##
## mode = "stream" (default): while you approach a region gate, the next region is streamed into
##   the game in small slices (dormant: hidden, frozen, no collision). Crossing the gate swaps
##   regions in one cheap frame, then the new region wakes up in rings around you and the old one
##   is freed a bit per frame. No loading screen, no flash, no big stutter.
## mode = "swap": the next region is preloaded, then swapped with a regular scene change as soon
##   as you touch the gate (short hitch, hidden by an optional flash).
## Both modes carry your speed, height, sideways offset and camera angle through the gate.

const MOD_VERSION := "0.3.3"
const GATE_SCRIPT := "res://src/stage_gate_area/stage_gate.gd"
const STAGE_SCRIPT := "res://src/stage/stage.gd"
const LEVER_SCRIPT := "res://assets/prefabs/lever/lever.gd"
const LOCKEVENT_SCRIPT := "res://definitions/solid_classes/lockevent_trigger.gd"
const FALL_ENTER_SCRIPT := "res://definitions/point_classes/gates/fall_gate_enter.gd"
const FALL_EXIT_SCRIPT := "res://definitions/point_classes/gates/fall_gate_exit.gd"
# floor/ceiling gates that keep the vanilla loading (boss fight scene)
const FALL_GATE_EXCLUDE := ["res://maps/map_boss_battle.tscn"]
const STAND_HEIGHT := 0.88  # player origin above the floor when standing (measured)
const SETTLE := 0.6
const Streamer = preload("streamer.gd")

# settings (settings.cfg)
var mode := "stream"
var stream_radius := 80.0
var stream_budget_ms := 3.0
var wake_radius := 40.0
var wake_budget_ms := 3.0
var unload_budget_ms := 3.0
var preload_radius := 45.0
var fade_out_time := 0.05
var fade_in_time := 0.25
var fade_color := Color.WHITE
var exit_depth := 3.0
var keep_momentum := true
var max_carried_speed := 0.0
var debug_log := false
var gate_style := "tinted"

var _busy := false
var _gate: Area3D
var _to_stage := ""
var _from_stage := ""
var _carry := {}
var _requested := {}  # swap mode: scene path -> true (threaded load requested, not yet taken)
var _fade: ColorRect
var _fade_tween: Tween

# stream mode state
var _streamer = null                 # streamer.gd instance (or null)
var _stream_scene: Node = null       # the region that was current when streaming started
var _gate_candidate: Area3D = null   # nearest gate reported this frame
var _gate_candidate_dist := INF
var _gate_candidate_path := ""
var _no_gate_time := 0.0
var _other_gate_time := 0.0
var _waking = null                   # streamer being woken up after activation
var _wake_center := Vector3.ZERO
var _unload_list: Array = []         # old region nodes still to free
var _unload_root: Node = null
var _cooldown := 0.0                 # no new streaming right after a crossing
var _karta: Control = null           # next region's pause-menu map, prebuilt while streaming
var _karta_added := false


func _init() -> void:
	_load_settings()
	if mode == "stream" and RenderingServer.get_current_rendering_driver_name() == "d3d12":
		# D3D12 (Godot 4.5) runs out of descriptor heaps with two regions loaded.
		push_warning("[SeamlessTransitions] D3D12 renderer: stream mode needs Vulkan, using swap mode")
		mode = "swap"
	Engine.set_meta("seamless_transitions", self)
	var dir: String = get_script().resource_path.get_base_dir()
	_install(dir, "stage_gate_ext.gd", GATE_SCRIPT)
	if mode == "stream":
		_install(dir, "stage_ext.gd", STAGE_SCRIPT)
		_install(dir, "lever_ext.gd", LEVER_SCRIPT)
		_install(dir, "lockevent_ext.gd", LOCKEVENT_SCRIPT)
		_install(dir, "fall_gate_enter_ext.gd", FALL_ENTER_SCRIPT)
		_install(dir, "fall_gate_exit_ext.gd", FALL_EXIT_SCRIPT)
	print("[SeamlessTransitions] v", MOD_VERSION, " installed, mode=", mode, ", renderer=", RenderingServer.get_current_rendering_driver_name())


func _notification(what: int) -> void:
	# Quitting with a region streamed in: free its off-tree nodes (next Player, map UI...) now,
	# otherwise they outlive the renderer and the game crashes on exit.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_drop_karta()
		if _streamer != null:
			_log("shutdown: freeing streamed region (%s)" % _streamer.progress())
			_streamer.abort(true)
			_streamer = null


func _install(dir: String, ext_file: String, target: String) -> void:
	var ext: Script = load(dir.path_join(ext_file))
	if ext == null:
		push_error("[SeamlessTransitions] could not load " + ext_file)
		return
	ext.take_over_path(target)


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_fade = ColorRect.new()
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(fade_color, 0)
	layer.add_child(_fade)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	var path := OS.get_executable_path().get_base_dir().path_join("mods/seamless_transitions/settings.cfg")
	if cfg.load(path) != OK:
		return
	var s := "transitions"
	mode = str(cfg.get_value(s, "mode", mode))
	stream_radius = float(cfg.get_value(s, "stream_radius", stream_radius))
	stream_budget_ms = float(cfg.get_value(s, "stream_budget_ms", stream_budget_ms))
	wake_radius = float(cfg.get_value(s, "wake_radius", wake_radius))
	wake_budget_ms = float(cfg.get_value(s, "wake_budget_ms", wake_budget_ms))
	unload_budget_ms = float(cfg.get_value(s, "unload_budget_ms", unload_budget_ms))
	preload_radius = float(cfg.get_value(s, "preload_radius", preload_radius))
	fade_out_time = float(cfg.get_value(s, "fade_out_time", fade_out_time))
	fade_in_time = float(cfg.get_value(s, "fade_in_time", fade_in_time))
	fade_color = cfg.get_value(s, "fade_color", fade_color)
	exit_depth = float(cfg.get_value(s, "exit_depth", exit_depth))
	keep_momentum = bool(cfg.get_value(s, "keep_momentum", keep_momentum))
	max_carried_speed = float(cfg.get_value(s, "max_carried_speed", max_carried_speed))
	debug_log = bool(cfg.get_value(s, "debug_log", debug_log))
	gate_style = str(cfg.get_value(s, "gate_style", gate_style))


func _log(msg: String) -> void:
	if debug_log:
		print("[SeamlessTransitions] ", msg)


# ---------------------------------------------------------------------------------------------
# Gates report themselves every frame while the player is near (see stage_gate_ext.gd).

func report_gate(gate: Area3D, dist: float, path: String = "") -> void:
	if path == "":
		path = gate.to_stage
	if path == "" or path in FALL_GATE_EXCLUDE:
		return
	if mode == "stream":
		if dist < stream_radius and dist < _gate_candidate_dist:
			_gate_candidate = gate
			_gate_candidate_dist = dist
			_gate_candidate_path = path
	elif dist < preload_radius:
		request_preload(path)


func is_busy() -> bool:
	return _busy


## Floor/ceiling gates: streamed in stream mode (vanilla loading otherwise).
func handles_fall_gate(gate: Area3D) -> bool:
	var path: String = gate.seamless_target()
	return mode == "stream" and path != "" and not path in FALL_GATE_EXCLUDE and ResourceLoader.exists(path)


var _trace_frames := 0
var _trace_t := 0

var _slow_last := 0

func _process(_delta: float) -> void:
	if debug_log:
		var now := Time.get_ticks_usec()
		if _slow_last > 0 and now - _slow_last > 30000:
			_log("slow frame %.1f ms: streamer %s, waking %s, unloading %d, busy %s" % [(now - _slow_last) / 1000.0, _streamer.progress() if _streamer != null else "-", _waking != null, _unload_list.size(), _busy])
		_slow_last = now
	if _trace_frames > 0:
		var now := Time.get_ticks_usec()
		if _trace_t > 0:
			_log("frame after crossing: %.1f ms (delta %.1f ms, physics %.1f ms)" % [(now - _trace_t) / 1000.0, _delta * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0])
		_trace_t = now
		_trace_frames -= 1
	if mode == "stream":
		_stream_process(_delta)
	_unload_step()
	if _waking != null and (not is_instance_valid(_waking.root) or not _waking.root.is_inside_tree()):
		_log("region left the tree while waking up (scene change)")
		_waking = null
	if _waking != null:
		if _waking.restore_step(_wake_center, int(wake_budget_ms * 1000)):
			_log("region fully awake")
			get_tree().call_group("seamless_lockevent", "seamless_capture")
			_waking = null


func _stream_process(delta: float) -> void:
	var tree := get_tree()
	var cs := tree.current_scene
	# pick the nearest gate reported last frame
	var cand := _gate_candidate
	var cand_path := _gate_candidate_path
	_gate_candidate = null
	_gate_candidate_dist = INF
	_gate_candidate_path = ""
	if _busy:
		return
	if _waking != null or not _unload_list.is_empty() or _unload_root != null:
		_cooldown = 1.0
		return
	if _cooldown > 0:
		_cooldown -= delta
		return
	if _streamer != null:
		# the region we were streaming for is gone (death reload, menu...): drop everything
		if not is_instance_valid(_stream_scene) or cs != _stream_scene:
			_abort_stream("scene changed")
			return
		if cand == null:
			_no_gate_time += delta
			if _no_gate_time > 3.0:
				_abort_stream("walked away")
				return
		else:
			_no_gate_time = 0.0
			if cand_path != _streamer.path:
				_other_gate_time += delta
				# a finished region is kept a little longer, so walking past another gate doesn't
				# throw it away
				if _streamer.phase != Streamer.READY or _other_gate_time > 1.5:
					_abort_stream("another gate is closer")
					return
			else:
				_other_gate_time = 0.0
	if _streamer == null and cand != null and cand_path != "" and cs != null:
		_streamer = Streamer.new(tree, cand_path)
		_streamer.budget_usec = int(stream_budget_ms * 1000)
		_stream_scene = cs
		_no_gate_time = 0.0
		_other_gate_time = 0.0
		_log("streaming " + cand_path)
	if _streamer != null and _streamer.phase < Streamer.READY:
		_streamer.step()
		if _streamer.phase == Streamer.READY:
			_log("ready %s: %d frames, worst slice %.1f ms, %d linked groups, slow chunks %s" % [_streamer.path, _streamer.stats.frames, _streamer.stats.worst_usec / 1000.0, _streamer.linked_groups, _streamer.slow_chunks.slice(0, 8)])
		elif _streamer.phase == Streamer.FAILED:
			_streamer = null
	elif _streamer != null and _streamer.phase == Streamer.READY:
		_streamer.pump()
		_prebuild_karta_step()


## The game builds the pause-menu map of a region when it is entered (25 ms for the Catacombs).
## Build it ahead, one step per frame: instantiate, then add it (hidden) to the map menu.
func _prebuild_karta_step() -> void:
	if _karta_added or _streamer._karta == null:
		return
	var mm := _map_menu()
	if mm == null:
		return
	if _karta == null:
		_karta = _streamer._karta.instantiate()
		_karta.stage_id = _streamer._region_suffix
		_karta.visible = false
		return
	var t := Time.get_ticks_usec()
	mm.karta_container.add_child(_karta)
	_karta_added = true
	_log("prebuilt map of %s: %.1f ms" % [_karta.stage_id, (Time.get_ticks_usec() - t) / 1000.0])


func _drop_karta() -> void:
	if _karta != null and is_instance_valid(_karta):
		if _karta.get_parent() != null:
			_karta.get_parent().remove_child(_karta)
		_karta.queue_free()
	_karta = null
	_karta_added = false


var _map_menu_node: Node = null

func _map_menu() -> Node:
	if is_instance_valid(_map_menu_node):
		return _map_menu_node
	var pm = get_tree().root.get_node_or_null("PauseMenu")
	if pm == null:
		return null
	var n = pm.get_node_or_null("PauseMenu/MarginContainer/VBoxContainer/HBoxContainer/PanelContainer/MapMenu")
	if n == null or not n.has_method("open_current_karta"):
		var found = pm.find_children("*", "", true, false).filter(func(x): return x.has_method("open_current_karta"))
		n = found[0] if found.size() > 0 else null
	if n != null and n.get("karta_container") == null:
		n = null
	_map_menu_node = n
	return n


func _abort_stream(why: String) -> void:
	_log("abort streaming (%s)" % why)
	if _streamer != null:
		_streamer.abort()
	_streamer = null
	_stream_scene = null
	_drop_karta()


# ---------------------------------------------------------------------------------------------

func request_preload(path: String) -> void:
	if _requested.has(path):
		return
	if ResourceLoader.load_threaded_request(path) == OK:
		_requested[path] = true


func begin_transition(gate: Area3D) -> void:
	if _busy:
		return
	_log("gate %s (to %s) entered, player local %s" % [gate.name, gate.to_stage.get_file(), gate.global_transform.affine_inverse() * Events.player.global_position])
	_busy = true
	_gate = gate
	_to_stage = gate.to_stage
	_from_stage = get_tree().current_scene.scene_file_path
	gate.collision_mask = 0
	gate.discover_region_connection()
	MusicPlayer.tween_volume(0, 0.3)
	if mode == "stream":
		_take_streamer(_to_stage)
		_run_stream_transition("stage", 0.0)
	else:
		request_preload(_to_stage)
		_run_transition()


func _take_streamer(path: String) -> void:
	if _streamer == null or _streamer.path != path:
		if _streamer != null:
			_abort_stream("entered a different gate")
		_streamer = Streamer.new(get_tree(), path)
		_stream_scene = get_tree().current_scene


## Floor/ceiling gate touched (fall_gate_*_ext.gd already started the vanilla fall + white fade).
## The swap happens once the screen is white, `white_at` seconds from now.
func begin_fall_transition(gate: Area3D, white_at: float) -> void:
	if _busy:
		return
	_busy = true
	_gate = gate
	_to_stage = gate.seamless_target()
	_from_stage = get_tree().current_scene.scene_file_path
	_take_streamer(_to_stage)
	_run_stream_transition("fall", white_at)


# ---------------------------------------------------------------------------------------------
# Stream mode transition

func _run_stream_transition(kind: String, wait_white: float) -> void:
	var t_start := Time.get_ticks_msec()
	# body_entered is a physics callback; bodies can't be enabled/disabled from there.
	await get_tree().process_frame
	var st = _streamer
	# Normally already READY. If not, finish quickly (bigger slices) while the player keeps walking
	# through the doorway (or while the screen fades to white).
	var held_player: CharacterBody3D = null
	var faded := false
	if st.phase < Streamer.READY:
		_log("gate touched before streaming finished (%s), hurrying" % st.progress())
		st.budget_usec = 12000
		if kind == "stage":
			# Not ready (typically: turned around right after arriving, the region you came from
			# is gone). Behind the gate there is only void, so don't let the player walk on: stop
			# them and fade to white like the vanilla loading, then finish with big slices.
			held_player = Events.player
			if is_instance_valid(held_player):
				held_player.velocity = Vector3.ZERO
				held_player.movement.move_dir = Vector2.ZERO
				held_player.allow_inputs = false
				held_player.process_mode = Node.PROCESS_MODE_DISABLED
			_tween_fade(1.0, 0.15)
			faded = true
		while st.phase < Streamer.READY:
			var white := false
			if kind == "fall":
				white = Time.get_ticks_msec() - t_start >= wait_white * 1000
			else:
				white = _fade.color.a >= 0.99
			if white:
				st.budget_usec = 50000  # screen is white, nothing to see
				_flush_unload()
			st.step()
			await get_tree().process_frame
	if st.phase != Streamer.READY:
		push_warning("[SeamlessTransitions] streaming failed, falling back to a normal load")
		_streamer = null
		_drop_karta()
		if kind == "fall":
			while Time.get_ticks_msec() - t_start < wait_white * 1000:
				await get_tree().process_frame
			FallGateManager.from_stage = _from_stage.get_file().get_basename()
			_busy = false
			get_tree().change_scene_to_file(_to_stage)
		else:
			if is_instance_valid(held_player):
				held_player.process_mode = Node.PROCESS_MODE_INHERIT
			request_preload(_to_stage)
			_run_transition()
		return
	while kind == "fall" and Time.get_ticks_msec() - t_start < wait_white * 1000:
		st.pump()
		await get_tree().process_frame

	var t0 := Time.get_ticks_usec()
	if is_instance_valid(held_player):
		held_player.process_mode = Node.PROCESS_MODE_INHERIT
	if kind == "stage":
		_capture_carry()
	var old_scene := get_tree().current_scene
	_streamer = null
	_stream_scene = null
	if not st.activate(old_scene):
		push_error("[SeamlessTransitions] activation failed")
		_busy = false
		if _fade.color.a > 0:
			_tween_fade(0.0, fade_in_time)
		return
	var ta := Time.get_ticks_usec()
	_start_unload(old_scene)
	var t1 := Time.get_ticks_usec()
	st.act_times["old_disable"] = (t1 - ta) / 1000.0

	var new_root: Node = st.root
	var p: CharacterBody3D = Events.player
	var exit_gate: Area3D
	if kind == "fall":
		exit_gate = st.find_fall_gate(_from_stage.get_file().get_basename())
	else:
		exit_gate = StageGateManager.find_gate(_from_stage)
	var center := exit_gate.global_position if exit_gate != null else (p.global_position if is_instance_valid(p) else Vector3.ZERO)
	# wake everything near the exit gate this frame, the rest over the next frames
	st.restore_step(center, 0, wake_radius)
	var t2 := Time.get_ticks_usec()
	if is_instance_valid(p) and exit_gate != null:
		if kind == "fall":
			exit_gate.seamless_arrive()
		else:
			_arrive_at(p, exit_gate)
	else:
		push_error("[SeamlessTransitions] could not find exit gate back to " + _from_stage)
		if kind == "fall":
			UserPrefs._apply_volume()
			create_tween().tween_property(FallGateManager._color_rect, "modulate:a", 0, 0.3)
			if is_instance_valid(p):
				p.allow_inputs = true
				p.head.camera_controller.enabled = true
	st.act_times["arrive"] = (Time.get_ticks_usec() - t2) / 1000.0
	_log("activated %s: swap %.1f ms, near wake %.1f ms, total %.1f ms %s" % [_to_stage, (t1 - t0) / 1000.0, (t2 - t1) / 1000.0, (Time.get_ticks_usec() - t0) / 1000.0, st.act_times])
	if debug_log:
		_trace_frames = 6

	# Next frame: vanilla Stage._ready (music, save flags, stage_entered...). It can teleport the
	# player to a saved position, so the player's state is kept as it is.
	await get_tree().process_frame
	if not is_instance_valid(new_root) or not new_root.is_inside_tree():
		_log("region left the tree before its setup (scene change)")
		_drop_karta()
		_busy = false
		if _fade.color.a > 0:
			_tween_fade(0.0, fade_in_time)
		return
	var t3 := Time.get_ticks_usec()
	var ready_waiters: int = new_root.ready.get_connections().size()
	var keep := []
	if is_instance_valid(p):
		keep = [p.global_transform, p.velocity, p.head.camera_controller.global_rotation]
	# the game's map menu rebuilds the map on stage_entered; skip that once if we prebuilt it
	var mm := _map_menu()
	var skipped := []
	var use_karta: bool = _karta_added and is_instance_valid(_karta) and mm != null and _karta.stage_id == new_root.get("stage_id")
	if use_karta:
		for c in Events.stage_entered.get_connections():
			if c.callable.get_object() == mm:
				skipped.append(c)
				Events.stage_entered.disconnect(c.callable)
	new_root.activate_deferred_ready()
	for c in skipped:
		Events.stage_entered.connect(c.callable, c.flags)
	if use_karta:
		for ch in mm.karta_container.get_children():
			if ch != _karta:
				ch.queue_free()
		_karta.visible = true
		mm._karta_scene = _karta
		mm.region_title.text = str("region_", new_root.stage_id)
		Events.current_karta = _karta
	elif _karta != null:
		_drop_karta()
	_karta = null
	_karta_added = false
	var t4 := Time.get_ticks_usec()
	new_root.ready.emit()  # scripts that `await current_scene.ready`
	var t5 := Time.get_ticks_usec()
	st.restore_canvas()
	_log("  Stage._ready %.1f ms, ready.emit %.1f ms (%d waiting)" % [(t4 - t3) / 1000.0, (t5 - t4) / 1000.0, ready_waiters])
	if is_instance_valid(p) and not keep.is_empty():
		p.global_transform = keep[0]
		p.velocity = keep[1]
		p.head.camera_controller.global_rotation = keep[2]
	_log("region setup (vanilla Stage._ready) %.1f ms" % ((Time.get_ticks_usec() - t3) / 1000.0))
	_waking = st
	_wake_center = center
	_busy = false
	if faded:
		_tween_fade(0.0, fade_in_time)


func _start_unload(old_scene: Node) -> void:
	if old_scene == null:
		return
	old_scene.process_mode = Node.PROCESS_MODE_DISABLED
	var list: Array = []
	for c in old_scene.get_children():
		if c is Node3D or c is CanvasItem or c is CanvasLayer:
			c.visible = false
		if c.get_class() == "Node3D" and c.get_child_count() > 8:
			list.append_array(c.get_children())
		list.append(c)
	# arena enemies waiting off-tree (lock events) are not children of the region any more
	for t in get_tree().get_nodes_in_group("seamless_arena"):
		if old_scene.is_ancestor_of(t):
			for e in t.enemies:
				if is_instance_valid(e) and e.get_parent() == null:
					list.append(e)
	_unload_list.append_array(list)
	_unload_root = old_scene


## Free what is left of the old region at once (screen is white).
func _flush_unload() -> void:
	if _unload_list.is_empty() and _unload_root == null:
		return
	var keep := unload_budget_ms
	unload_budget_ms = 1000000.0
	_unload_step()
	unload_budget_ms = keep


func _unload_step() -> void:
	if _unload_list.is_empty() and _unload_root == null:
		return
	var t0 := Time.get_ticks_usec()
	var budget := int(unload_budget_ms * 1000)
	while not _unload_list.is_empty():
		var n = _unload_list.pop_front()
		if is_instance_valid(n):
			n.free()
		if Time.get_ticks_usec() - t0 >= budget:
			return
	if _unload_root != null:
		if is_instance_valid(_unload_root):
			_unload_root.free()
		_unload_root = null
		var cs := get_tree().current_scene
		if cs != null and cs.name != &"Stage":
			cs.name = &"Stage"  # the old root held that name until now
		_log("old region freed")


# ---------------------------------------------------------------------------------------------
# Swap mode transition (v0.1 behaviour)

func _run_transition() -> void:
	# Wait for the threaded load (normally already done thanks to the preload).
	while ResourceLoader.load_threaded_get_status(_to_stage) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	var packed: PackedScene = ResourceLoader.load_threaded_get(_to_stage)
	_requested.erase(_to_stage)
	if packed == null:
		push_error("[SeamlessTransitions] failed to load " + _to_stage)
		_busy = false
		return

	if fade_out_time > 0:
		_tween_fade(1.0, fade_out_time)
		await _fade_tween.finished

	_capture_carry()
	_drop_unused_preloads()

	StageGateManager._from_stage = _from_stage
	StageGateManager._to_stage = _to_stage
	get_tree().change_scene_to_packed(packed)
	# The new scene is added to the tree a frame later; wait for it and its player.
	var waited := 0
	while waited < 600:
		var cs := get_tree().current_scene
		if cs != null and cs.scene_file_path == _to_stage and is_instance_valid(Events.player) and Events.player.is_inside_tree():
			break
		await get_tree().process_frame
		waited += 1
	await get_tree().physics_frame
	# We do StageGateManager's arrival work ourselves instead of emitting
	# AsyncSceneLoader.scene_changed (its only listener), because the vanilla handler relies on
	# StageGateManager._from_stage, which the exit gate clears on a 0.25 s timer.
	var p: CharacterBody3D = Events.player
	var exit_gate: Area3D = StageGateManager.find_gate(_from_stage)
	if is_instance_valid(p) and exit_gate != null:
		_arrive_at(p, exit_gate)
	else:
		push_error("[SeamlessTransitions] could not find exit gate back to " + _from_stage)
	_busy = false
	Events.can_toggle_pause_menu = true
	if _fade.color.a > 0:
		_tween_fade(0.0, fade_in_time)


# ---------------------------------------------------------------------------------------------
# Shared

func _capture_carry() -> void:
	_carry = {}
	var p: CharacterBody3D = Events.player
	if not is_instance_valid(p) or not is_instance_valid(_gate):
		return
	var gt := _gate.global_transform.orthonormalized()
	var cam: Node3D = p.head.camera_controller
	_carry = {
		"pos": gt.affine_inverse() * p.global_position,
		"vel": gt.basis.inverse() * p.velocity,
		# yaw relative to "facing into the doorway" (vanilla turns you to gate yaw + PI)
		"yaw": wrapf(cam.global_rotation.y - (_gate.global_rotation.y + PI), -PI, PI),
		"pitch": cam.global_rotation.x,
	}


func _arrive_at(p: CharacterBody3D, exit_gate: Area3D) -> void:
	# The exit gate ignores the player only until they are out of its trigger (vanilla: 1 s, with
	# input locked). Walking back into it afterwards takes you back, instead of letting you walk
	# through it into the void behind the gate.
	exit_gate._ignore_player = true
	_place_player(p, exit_gate)
	_release_exit_gate(exit_gate, p)
	RegionNameDisplay.display_region_name(get_tree().current_scene.region_name)
	StageGateManager.gate_exited.emit(exit_gate)


func _release_exit_gate(gate: Area3D, p: CharacterBody3D) -> void:
	# The trigger box reaches into the doorway, so you arrive inside it. Physics overlap info lags a
	# few frames after a teleport, so test the box geometrically.
	var boxes: Array = gate.get_children().filter(func(c): return c is CollisionShape3D and c.shape is BoxShape3D)
	var clear_frames := 0
	var t0 := Time.get_ticks_msec()
	while clear_frames < 3:
		await get_tree().physics_frame
		if not is_instance_valid(gate) or not is_instance_valid(p):
			return
		if boxes.is_empty():
			if Time.get_ticks_msec() - t0 > 1000:
				break  # unknown trigger shape: vanilla's 1 s
			continue
		var inside := false
		if gate.has_method("seamless_in_trigger"):
			# also counts the space under the box (doorways sloping down behind the gate)
			inside = gate.seamless_in_trigger(p, Vector3(0.7, 1.0, 0.7), gate.BELOW_TRIGGER)
		else:
			for c in boxes:
				var l: Vector3 = c.global_transform.affine_inverse() * p.global_position
				var h: Vector3 = c.shape.size * 0.5 + Vector3(0.7, 1.0, 0.7)
				if abs(l.x) <= h.x and abs(l.y) <= h.y and abs(l.z) <= h.z:
					inside = true
		clear_frames = 0 if inside else clear_frames + 1
		# turned around and walking back into the doorway: take them back through the gate
		var gz: float = (gate.global_transform.affine_inverse() * p.global_position).z
		if inside and gz > exit_depth + 1.5 and not _busy:
			gate._ignore_player = false
			begin_transition(gate)
			return
	gate._ignore_player = false


func _place_player(p: CharacterBody3D, exit_gate: Area3D) -> void:
	var gt := exit_gate.global_transform.orthonormalized()
	var half_w: float = max(exit_gate._width * 0.5 - 0.6, 0.0)
	var local := Vector3(0, 0, exit_depth)
	var vel := Vector3.ZERO
	var yaw := 0.0
	var pitch := 0.0
	if keep_momentum and not _carry.is_empty():
		# Mirror through the doorway: you were moving +Z into the entry gate, you come out moving -Z.
		var lp: Vector3 = _carry.pos
		local.x = clampf(-lp.x, -half_w, half_w)
		local.y = clampf(lp.y, STAND_HEIGHT, max(float(exit_gate._height) - 1.0, STAND_HEIGHT))
		var lv: Vector3 = _carry.vel
		# only carry movement into the new region (backing out of the entry gate must not push
		# you back out through the exit gate)
		lv.z = max(lv.z, 0.0)
		vel = gt.basis * Vector3(-lv.x, lv.y, -lv.z)
		if max_carried_speed > 0 and vel.length() > max_carried_speed:
			vel = vel.normalized() * max_carried_speed
		yaw = _carry.yaw
		pitch = _carry.pitch
	else:
		local.y = STAND_HEIGHT

	# Lift a bit and drop onto the doorway floor (vanilla does the same with a 7 m drop).
	p.global_position = gt * (local + Vector3(0, SETTLE, 0))
	p.move_and_collide(Vector3(0, -SETTLE, 0))
	p.velocity = vel
	var cam: Node3D = p.head.camera_controller
	cam.global_rotation.y = exit_gate.global_rotation.y + yaw
	cam.global_rotation.x = pitch
	p.movement.move_dir = Vector2.ZERO
	p.allow_inputs = true


func _drop_unused_preloads() -> void:
	# Release maps we preloaded but did not use, so they don't stay in memory.
	for path in _requested.keys():
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			ResourceLoader.load_threaded_get(path)
			_requested.erase(path)


func _tween_fade(alpha: float, time: float) -> void:
	if _fade_tween:
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_fade, "color", Color(fade_color, alpha), max(time, 0.001))
