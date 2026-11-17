extends "res://assets/prefabs/lever/lever.gd"
## Lever extension (installed over res://assets/prefabs/lever/lever.gd with take_over_path).
## Vanilla _ready connects to Events.player.health.died. While a region is streamed in dormant,
## Events.player is still the old region's player, so for dormant levers we point Events.player
## at the incoming region's player for the synchronous part of _ready.


func _ready() -> void:
	var cs = get_tree().current_scene
	var next_player = Engine.get_meta("seamless_next_player") if Engine.has_meta("seamless_next_player") else null
	if cs != null and cs.get("seamless_dormant") == true and is_instance_valid(next_player):
		var real = Events.player
		Events.player = next_player
		super._ready()  # runs until its first await, then returns
		Events.player = real
	else:
		super._ready()

