extends "res://src/stage_gate_area/stage_gate.gd"
## Replaces the vanilla region gate behaviour (installed with take_over_path in mod_main.gd).
## Keeps all vanilla setup (sizes, decals, labels); only swaps the "player entered" handler
## and preloads the next region while the player is near the gate.


func _ready() -> void:
	super._ready()
	for c in body_entered.get_connections():
		body_entered.disconnect(c.callable)
	body_entered.connect(_seamless_body_entered)
	var mod = (Engine.get_meta("seamless_transitions") if Engine.has_meta("seamless_transitions") else null)
	if to_stage != "" and mod != null and mod.gate_style == "tinted":
		_apply_tinted_style()


## Color of the region this gate leads to (the gate scene has a per-region color table).
func _destination_color() -> Color:
	var key := to_stage.get_file().get_basename()
	for k in [key, key.trim_suffix("s")]:
		if stage_colors.has(k):
			return stage_colors[k]
	return Color(1, 1, 1)


## Tint the vanilla white fog planes and floor glow with the destination region's color, so region
## gates are easy to tell apart from room gates.
func _apply_tinted_style() -> void:
	var col := _destination_color()
	var dark: MeshInstance3D = get_node_or_null("%Darkness")
	if dark != null and dark.material_override is StandardMaterial3D:
		var m: StandardMaterial3D = dark.material_override.duplicate()
		m.albedo_color = Color(col.lightened(0.55), m.albedo_color.a)
		if m.emission_enabled:
			m.emission = col.lightened(0.4)
		dark.material_override = m
		for c in dark.get_children():
			if c is MeshInstance3D:
				c.material_override = m
	var decal: Decal = get_node_or_null("%Decal")
	if decal != null:
		decal.modulate = col.lightened(0.3)


func _process(delta: float) -> void:
	super._process(delta)
	if to_stage == "" or not is_instance_valid(Events.player):
		return
	var mod = (Engine.get_meta("seamless_transitions") if Engine.has_meta("seamless_transitions") else null)
	if mod:
		mod.report_gate(self, global_position.distance_to(Events.player.global_position))
		# the trigger only reaches down to the gate's floor level; some doorways slope down behind
		# it (Outside, Ruins and Hollows gates), so you could walk under it into the void
		if not _ignore_player and collision_mask != 0 and not mod.is_busy() 				and seamless_in_trigger(Events.player, Vector3.ZERO, BELOW_TRIGGER, true):
			mod.begin_transition(self)


const BELOW_TRIGGER := 30.0

## Is `p` inside the trigger box (grown by `margin`), or under it down to `below` meters?
## `only_below`: true only for the part under the box (inside is the physics trigger's job).
func seamless_in_trigger(p: Node3D, margin: Vector3, below: float, only_below := false) -> bool:
	var c: CollisionShape3D = get_node_or_null("%CollisionShape3D")
	if c == null or not c.shape is BoxShape3D:
		return false
	var l: Vector3 = c.global_transform.affine_inverse() * p.global_position
	var h: Vector3 = c.shape.size * 0.5 + margin
	if abs(l.x) > h.x or abs(l.z) > h.z or l.y > h.y or l.y < -h.y - below:
		return false
	return l.y < -h.y or not only_below


func _seamless_body_entered(body: Node3D) -> void:
	if _ignore_player or not body.is_in_group("player"):
		return
	var mod = (Engine.get_meta("seamless_transitions") if Engine.has_meta("seamless_transitions") else null)
	if mod:
		mod.begin_transition(self)
	else:
		_vanilla_enter()


## Copy of the vanilla handler, used if the mod node is missing.
func _vanilla_enter() -> void:
	Events.player.velocity = Events.player.velocity.clampf(-15, 15)
	MusicPlayer.tween_volume(0, 0.4)
	StageGateManager.move_between_stages(get_tree().current_scene.scene_file_path, to_stage)
	collision_mask = 0
	create_tween().tween_property(StageGateManager._color_rect, "color:a", 1, 0.25).set_delay(0.35)
	discover_region_connection()
