extends "res://definitions/point_classes/gates/fall_gate_enter.gd"
## Floor-hole region gate (fall in -> you drop into the next region from its ceiling gate).
## Installed with take_over_path in mod_main.gd. Same look and fade as vanilla, but the next region
## is streamed while you are near, and swapped in as soon as the screen is white (no load).

const _MOD_KEY := "seamless_transitions"
const WHITE_AT := 0.6  # vanilla: fade starts after 0.4 s, takes 0.15 s


func _seamless_mod():
	return Engine.get_meta(_MOD_KEY) if Engine.has_meta(_MOD_KEY) else null


func seamless_target() -> String:
	return "" if _to_stage == "" else FallGateManager.PATH_BEG + _to_stage + FallGateManager.PATH_END


func _ready() -> void:
	super._ready()  # returns at its first await
	await get_tree().process_frame
	# vanilla connects its handler after the same await; replace it
	for c in body_entered.get_connections():
		body_entered.disconnect(c.callable)
	body_entered.connect(_seamless_body_entered)


func _process(_delta: float) -> void:
	var mod = _seamless_mod()
	if mod == null or _to_stage == "" or not is_instance_valid(Events.player):
		return
	mod.report_gate(self, global_position.distance_to(Events.player.global_position), seamless_target())


func _seamless_body_entered(body: Node3D) -> void:
	if _to_stage == "": return
	if Events.player.velocity.y > 0: return
	var mod = _seamless_mod()
	if mod == null or not mod.handles_fall_gate(self):
		_vanilla_enter(body)
		return
	if mod.is_busy(): return
	_start_fall_visuals(body)
	mod.begin_fall_transition(self, WHITE_AT)


func _start_fall_visuals(body: Node3D) -> void:
	SaveGame.set_value(str("region_connection/", _to_stage.erase(0, 4), "/", get_tree().current_scene.stage_id), true)
	create_tween().set_trans(Tween.TRANS_SINE).tween_property(body, "global_position:x", global_position.x, 0.7)
	create_tween().set_trans(Tween.TRANS_SINE).tween_property(body, "global_position:z", global_position.z, 0.7)
	body.velocity.x = 0 ; body.velocity.z = 0
	body.velocity.y = max(body.velocity.y, -15)
	body.state_machine.set_state("Fall")
	body.allow_inputs = false
	body.head.camera_controller.enabled = false
	create_tween().tween_property(FallGateManager._color_rect, "modulate:a", 1, 0.15).set_delay(0.4)
	FallGateManager.fade_out_volume()
	MusicPlayer.tween_volume(0, 0.4)


## Copy of the vanilla handler (used when the mod does not stream this gate).
func _vanilla_enter(body: Node3D) -> void:
	_start_fall_visuals(body)
	get_tree().create_timer(1.6).timeout.connect(func ():
		FallGateManager.from_stage = Game.get_current_stage_name()
		get_tree().change_scene_to_file(FallGateManager.PATH_BEG + _to_stage + FallGateManager.PATH_END)
		)


## Arrival through this gate (copy of the vanilla arrival in _ready): you pop up out of the hole.
func seamless_arrive() -> void:
	FallGateManager.from_stage = ""
	UserPrefs._apply_volume()
	Events.player.velocity.y = 16
	create_tween().tween_property(Events.player, "velocity:y", 16, 0.7)
	create_tween().tween_property(Events.player, "velocity", Events.player.velocity - global_basis.z * 8, 0.2).set_delay(0.5)
	Events.player.allow_inputs = false
	Events.player.head.camera_controller.enabled = false
	Events.player.head.camera_controller.rotation.y = global_rotation.y
	Events.player.head.camera_controller.rotation_degrees.x = 0
	Events.player.global_position = global_position + Vector3(0, -9, 0)
	Events.player.state_machine.set_state("Fall")
	create_tween().tween_property(FallGateManager._color_rect, "modulate:a", 0, 0.15).set_delay(0.15)
	await Events.player.state_machine.state_changed
	RegionNameDisplay.display_region_name(get_tree().current_scene.region_name)
	Events.player.allow_inputs = true
	Events.player.head.camera_controller.enabled = true
	create_tween().set_trans(Tween.TRANS_SINE).tween_property(Events.player.head.rewinder_shake, "rotation:x", 0, 1.2)
