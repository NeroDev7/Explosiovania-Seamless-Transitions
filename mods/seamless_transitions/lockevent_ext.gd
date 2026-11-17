extends "res://definitions/solid_classes/lockevent_trigger.gd"
## Lock-event (arena) trigger extension (installed with take_over_path in mod_main.gd).
## Vanilla _ready waits two physics frames, then takes the enemies standing in the arena out of the
## tree until the player walks in. In a dormant (streamed) region collisions are off, so nothing
## would be found; the mod calls seamless_capture() once the region is awake to do it then.

var _seamless_pending := false


func _ready() -> void:
	add_to_group("seamless_arena")  # lets the mod free captured enemies with the region
	var cs = get_tree().current_scene
	if cs != null and cs.get("seamless_dormant") == true:
		_seamless_pending = true
		add_to_group("seamless_lockevent")
	super._ready()


func seamless_capture() -> void:
	if not _seamless_pending:
		return
	_seamless_pending = false
	remove_from_group("seamless_lockevent")
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree() or locked:
		return
	# same as vanilla _ready
	for enemy in get_overlapping_bodies():
		if not enemy.is_in_group("enemy"): continue
		if enemies.has(enemy): continue
		enemies.append(enemy)
		enemy.get_parent().remove_child(enemy)
		enemy.health.died.connect(func ():
			enemies_died += 1
			if enemies_died >= enemies.size(): complete()
			)

