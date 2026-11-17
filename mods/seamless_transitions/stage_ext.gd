extends "res://src/stage/stage.gd"
## Region root script extension (installed over res://src/stage/stage.gd with take_over_path).
## Behaves exactly like vanilla, except:
## - while the region is being streamed in (dormant), _ready's side effects (music, save flags,
##   stage_entered, race reset...) are postponed until activate_deferred_ready() is called;
## - a region removed by the streamer doesn't emit stage_exited a second time.

var seamless_dormant := false
var seamless_suppress_exit := false
var _seamless_ready_pending := false


func _ready() -> void:
	if seamless_dormant:
		stage_id = _get_stage_id()
		_seamless_ready_pending = true
		return
	super._ready()


func activate_deferred_ready() -> void:
	seamless_dormant = false
	if _seamless_ready_pending:
		_seamless_ready_pending = false
		super._ready()


func _exit_tree() -> void:
	if seamless_suppress_exit:
		return
	super._exit_tree()
