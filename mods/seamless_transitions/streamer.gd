extends RefCounted
## Streams a region (map scene) into the running game in small time-sliced steps while the player
## is still in the current region, then activates it when the player crosses the gate.
##
## Phases (each step() call spends at most `budget_usec`):
##   LOADING   threaded ResourceLoader load of the PackedScene
##   BUILDING  SceneBuilder recreates the nodes off-tree, a few hundred per step
##   PLANNING  cut the tree into chunks (children of the root, QodotMap, big plain containers)
##   STREAMING add chunks to the tree. The region is "dormant": root process disabled,
##             every chunk hidden, collision layers/masks zeroed (static bodies and areas still
##             join the physics space, so that cost is paid now), audio stopped.
##   READY     fully in the tree, waiting for activate()
## activate() swaps players/environment/current_scene in one frame, then restore_step() wakes the
## region up in rings around the player (geometry first, then scripted nodes).

const Builder = preload("scene_builder.gd")

enum { LOADING, BUILDING, PLANNING, STREAMING, READY, ACTIVE, DONE, FAILED }

const HELD_SCRIPTS := ["player.gd", "race_start.gd", "karta.gd", "quick_karta.gd"]
const SPLIT_SCRIPTS := ["qodot_map.gd"]
const SPLIT_MIN_CHILDREN := 8
# Scripts that look up other nodes by group in _ready (lever chains, black hole pairs...). In vanilla
# every node is in the tree before any _ready runs; here chunks arrive over many frames, so chunks
# containing these scripts are streamed last, when everything they look for is already there.
const LATE_SCRIPTS := ["logicgate_and.gd", "black_hole.gd", "lever_black.gd", "pressure_plate.gd", "falling.gd",
	"mover_pathfollow.gd", "lockevent_trigger.gd",
	# raycast in _ready (2 physics frames later) against walls that must already be there
	"e_laser_wheel.gd", "e_magnet.gd", "e_sawblade.gd", "ceiling_lamp.gd", "door_energy.gd",
	"door_red_eye.gd", "impact_area.gd"]

var path: String
var phase := LOADING
var budget_usec := 3000
var error := ""

var root: Node                 # new region root (Stage)
var next_player: Node          # the new region's Player (held until activation)

var _tree: SceneTree
var _builder
var _plan_queue: Array = []
var _chunks: Array = []        # [parent, node, is_leaf]
var _held: Array = []          # [parent, node]
var _owners := {}              # node -> owner (only nodes owned by root)
var _ci := 0
var _leaves: Array = []        # restore records for leaf chunks
var _root_process_mode := Node.PROCESS_MODE_INHERIT
var _restore_queue: Array = []
var _region_suffix := ""
var _late_chunks: Array = []   # chunks streamed after all others (see LATE_SCRIPTS)
var _canvas: Array = []        # [CanvasItem, visibility_layer] not drawn while dormant
var _karta_path := ""          # the region's pause-menu map, loaded by the game on stage_entered
var _karta: Resource = null    # kept so the game's load() of it is a cache hit
var _fall_gates: Array = []    # floor/ceiling gates of this region (arrival points)
var _race_checkpoints: Array = []  # race_end nodes, registered with RaceManager at activation
var _props := {}               # prop scene path -> loaded PackedScene (null while loading)

# timing stats (for the log)
var stats := {"frames": 0, "worst_usec": 0}
var slow_chunks: Array = []
var linked_groups := 0
var _waits: Array = []         # dormant scripts waiting for the next frame (see _capture_waits)


func _init(tree: SceneTree, scene_path: String) -> void:
	_tree = tree
	path = scene_path
	_tree.physics_frame.connect(_on_physics_frame)
	_region_suffix = scene_path.get_file().get_basename().trim_prefix("map_")
	if ResourceLoader.load_threaded_request(path) != OK:
		_fail("load request failed")
	_karta_path = "res://kartor/karta_%s.tscn" % _region_suffix
	if ResourceLoader.exists(_karta_path):
		ResourceLoader.load_threaded_request(_karta_path)
	else:
		_karta_path = ""


func is_ready() -> bool:
	return phase == READY


func progress() -> String:
	match phase:
		LOADING: return "loading"
		BUILDING: return "building %d%%" % int(_builder.progress() * 100)
		PLANNING: return "planning"
		STREAMING: return "streaming %d/%d" % [_ci, _chunks.size()]
		READY: return "ready"
	return str(phase)


func _fail(msg: String) -> void:
	error = msg
	phase = FAILED
	push_warning("[SeamlessTransitions] streaming %s failed: %s" % [path, msg])


## Advance the background work by one budgeted slice. Call once per frame.
func step() -> void:
	var t0 := Time.get_ticks_usec()
	match phase:
		LOADING:
			var st := ResourceLoader.load_threaded_get_status(path)
			if st == ResourceLoader.THREAD_LOAD_LOADED:
				var ps: PackedScene = ResourceLoader.load_threaded_get(path)
				_builder = Builder.new(ps)
				_builder.name_suffix = _region_suffix
				phase = BUILDING
			elif st != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				_fail("load failed")
		BUILDING:
			if _karta_path != "" and _karta == null and ResourceLoader.load_threaded_get_status(_karta_path) == ResourceLoader.THREAD_LOAD_LOADED:
				_karta = ResourceLoader.load_threaded_get(_karta_path)
			if _builder.step(budget_usec):
				root = _builder.root
				_builder = null
				if root.get("seamless_dormant") == null:
					_fail("region root is not a Stage")
					return
				root.seamless_dormant = true
				_plan_queue = [root]
				phase = PLANNING
		PLANNING:
			_plan_step(t0)
		STREAMING:
			_stream_step(t0)
	var dt := Time.get_ticks_usec() - t0
	stats.frames += 1
	stats.worst_usec = max(stats.worst_usec, dt)


func _script_file(n: Node) -> String:
	var sc = n.get_script()
	if sc == null:
		return ""
	var f: String = sc.resource_path.get_file()
	# our extensions keep vanilla names in their base; check base script too
	var base = sc.get_base_script()
	if f.ends_with("_ext.gd") and base != null:
		f = base.resource_path.get_file()
	return f.replace(".gdc", ".gd")


func _is_held(n: Node) -> bool:
	if n is WorldEnvironment:
		return true
	return _script_file(n) in HELD_SCRIPTS


func _is_split(n: Node) -> bool:
	if n == root:
		return true
	var f := _script_file(n)
	if f in SPLIT_SCRIPTS:
		return true
	var cls := n.get_class()
	return f == "" and (cls == "Node3D" or cls == "Node") and n.get_child_count() > SPLIT_MIN_CHILDREN


func _record_owners(n: Node, deep: bool) -> void:
	if n.owner == root:
		_owners[n] = root
	if deep:
		for c in n.get_children():
			_record_owners(c, true)


func _plan_step(t0: int) -> void:
	while not _plan_queue.is_empty():
		var n: Node = _plan_queue[0]
		# children are taken one at a time (in order) so a big container (QodotMap: 600-900
		# entities) is spread over several frames too
		while n.get_child_count() > 0:
			if Time.get_ticks_usec() - t0 >= budget_usec:
				return
			var c: Node = n.get_child(0)
			var split := _is_split(c) and not _is_held(c)
			_record_owners(c, not split)
			n.remove_child(c)
			if _is_held(c):
				_held.append([n, c])
				if _script_file(c) == "player.gd":
					next_player = c
				continue
			if not split and _has_late_script(c):
				_late_chunks.append([n, c, true, ""])
			else:
				_chunks.append([n, c, not split, _request_prop(c) if not split else ""])
			if split:
				_plan_queue.append(c)
		_plan_queue.pop_front()
	_chunks.append_array(_order_late(_late_chunks))
	_late_chunks.clear()
	_group_linked()
	if next_player == null:
		_fail("no player in region")
		return
	_root_process_mode = root.process_mode
	root.process_mode = Node.PROCESS_MODE_DISABLED
	phase = STREAMING
	_ci = 0


## prop_loader nodes load their prop scene synchronously in _enter_tree (~10 ms the first time).
## Load it on the background loader thread instead; the chunk is added once it is in the cache.
func _request_prop(n: Node) -> String:
	if _script_file(n) != "prop_loader.gd":
		return ""
	var name: String = n.properties.get("propname", "") if n.get("properties") is Dictionary else ""
	if name == "":
		return ""
	var path := "res://assets/props/" + name + ".tscn"
	if not ResourceLoader.exists(path):
		path = "res://assets/props/" + name + "/" + name + ".tscn"
		if not ResourceLoader.exists(path):
			return ""
	if not _props.has(path):
		if ResourceLoader.has_cached(path):
			_props[path] = load(path)
		elif ResourceLoader.load_threaded_request(path) == OK:
			_props[path] = null
		else:
			return ""
	return path


func _prop_ready(path: String) -> bool:
	if path == "" or _props.get(path) != null:
		return true
	var st := ResourceLoader.load_threaded_get_status(path)
	if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return false
	if st == ResourceLoader.THREAD_LOAD_LOADED:
		_props[path] = ResourceLoader.load_threaded_get(path)
	else:
		_props[path] = true  # failed: let the game report it as usual
	return true


## Late chunks can feed each other (a logic gate whose inputs are other logic gates): put every
## node after the nodes that target it, so its _ready finds them.
func _order_late(list: Array) -> Array:
	var by_target := {}  # target name -> chunks whose node targets it
	for ch in list:
		var pr = ch[1].get("properties")
		if pr is Dictionary and str(pr.get("target", "")) != "":
			by_target.get_or_add(str(pr.target), []).append(ch)
	var depth := {}
	var visiting := {}
	var depth_of := func(self_ref: Callable, ch: Array) -> int:
		if depth.has(ch[1]):
			return depth[ch[1]]
		if visiting.has(ch[1]):
			return 0  # cycle
		visiting[ch[1]] = true
		var d := 0
		var pr = ch[1].get("properties")
		if pr is Dictionary and str(pr.get("targetname", "")) != "":
			for src in by_target.get(str(pr.targetname), []):
				d = max(d, self_ref.call(self_ref, src) + 1)
		depth[ch[1]] = d
		return d
	var keyed: Array = []
	for i in list.size():
		keyed.append([depth_of.call(depth_of, list[i]), i, list[i]])
	keyed.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	return keyed.map(func(k): return k[2])


## Names that link entities: a source's target is its receivers' targetname (also a lock event's
## eventname), a moving platform's path is its path points' pathname.
func _link_keys(n: Node) -> Array:
	var pr = n.get("properties")
	if not pr is Dictionary:
		return []
	var out := []
	for k in ["target", "targetname", "eventname"]:
		var v := str(pr.get(k, ""))
		if v != "":
			out.append("t:" + v)
	for k in ["path", "pathname"]:
		var v := str(pr.get(k, ""))
		if v != "":
			out.append("p:" + v)
	return out


func _uf_find(uf: Array, i: int) -> int:
	while uf[i] != i:
		uf[i] = uf[uf[i]]
		i = uf[i]
	return i


## Vanilla adds the whole map before any _ready runs: a lit torch or a saved lever that alerts its
## targets in _ready reaches them, and a logic gate counts all of its inputs. Added one at a time,
## those signals went nowhere (castle: lit torches, door of the torch puzzle stayed shut).
## Entities linked by name are moved under one holder node and added together in a single
## add_child, so all of them enter the tree before any of their _ready runs, like in vanilla.
## They go last (after the geometry), like the LATE_SCRIPTS.
func _group_linked() -> void:
	var uf: Array = range(_chunks.size())
	var first := {}
	for i in _chunks.size():
		var ch: Array = _chunks[i]
		if not ch[2]:
			continue  # split container, its children are chunks of their own
		for k in _link_keys(ch[1]):
			var key: String = str(ch[0].get_instance_id()) + "|" + k
			if first.has(key):
				var a := _uf_find(uf, i)
				var b := _uf_find(uf, first[key])
				if a != b:
					uf[max(a, b)] = min(a, b)
			else:
				first[key] = i
	var groups := {}
	for i in _chunks.size():
		groups.get_or_add(_uf_find(uf, i), []).append(i)
	var grouped := {}
	var holders: Array = []
	for r in groups:
		var idx: Array = groups[r]
		if idx.size() < 2:
			continue
		idx.sort()
		var holder := Node3D.new()
		holder.name = "SeamlessLinked%d" % holders.size()
		var members: Array = []
		var props: Array = []
		for i in idx:
			grouped[i] = true
			var m: Node = _chunks[i][1]
			holder.add_child(m)
			members.append(m)
			if _chunks[i][3] != "":
				props.append(_chunks[i][3])
		holders.append([_chunks[idx[0]][0], holder, true, props, members])
	if holders.is_empty():
		return
	var rest: Array = []
	for i in _chunks.size():
		if not grouped.has(i):
			rest.append(_chunks[i])
	_chunks = rest + holders
	linked_groups = holders.size()


func _has_late_script(n: Node) -> bool:
	if _script_file(n) in LATE_SCRIPTS:
		return true
	for c in n.get_children():
		if _has_late_script(c):
			return true
	return false


func _restore_owner_tree(n: Node) -> void:
	if _owners.has(n) and n.owner != _owners[n]:
		n.owner = _owners[n]
	for c in n.get_children():
		_restore_owner_tree(c)


func _stream_step(t0: int) -> void:
	if _ci == 0 and not root.is_inside_tree():
		_tree.root.add_child(root)  # root alone first: Stage._ready is deferred (dormant)
	var old_scene := _tree.current_scene
	Engine.set_meta("seamless_next_player", next_player)
	_tree.current_scene = root
	_resume_waits()
	# race checkpoints register with RaceManager when they enter the tree; that belongs to the
	# region you are in now, so take ours back out and register them at activation
	var race_n: int = RaceManager.checkpoints.size()
	var race_total: int = RaceManager.checkpoints_total
	while _ci < _chunks.size():
		var ch: Array = _chunks[_ci]
		var waiting := false
		for pp in (ch[3] if ch[3] is Array else [ch[3]]):
			if not _prop_ready(pp):
				waiting = true
		if waiting:
			break  # prop scene still loading in the background, try next frame
		var parent: Node = ch[0]
		var node: Node = ch[1]
		var leaf: bool = ch[2]
		var members: Array = ch[4] if ch.size() > 4 else []
		var orig_proc := node.process_mode
		var member_proc: Array = []
		if not members.is_empty():
			for m in members:
				member_proc.append(m.process_mode)
				m.process_mode = Node.PROCESS_MODE_DISABLED
		elif leaf:
			node.process_mode = Node.PROCESS_MODE_DISABLED
		var tc := Time.get_ticks_usec()
		var before := _wait_snapshot()
		parent.add_child(node)
		_capture_waits(before)
		if not members.is_empty():
			# linked entities: one dormant record each, so they wake by their own distance
			for i in members.size():
				_restore_owner_tree(members[i])
				_make_dormant(members[i], member_proc[i])
		elif leaf:
			_restore_owner_tree(node)
			_make_dormant(node, orig_proc)
		else:
			_restore_owner_tree_shallow(node)
		var dc := Time.get_ticks_usec() - tc
		if dc > 2500:
			slow_chunks.append("%s %.1fms" % [node.name, dc / 1000.0])
		_ci += 1
		if Time.get_ticks_usec() - t0 >= budget_usec:
			break
	_tree.current_scene = old_scene
	if RaceManager.checkpoints.size() > race_n:
		_race_checkpoints.append_array(RaceManager.checkpoints.slice(race_n))
		RaceManager.checkpoints.resize(race_n)
	RaceManager.checkpoints_total = race_total
	if Engine.has_meta("seamless_next_player"):
		Engine.remove_meta("seamless_next_player")
	if _ci >= _chunks.size():
		phase = READY


## Scripts often wait a frame in _ready (`await get_tree().process_frame`) and then check
## `current_scene.is_ready()`, `_time_in_stage`... (levers alert their targets, movers snap or
## animate, toggle platforms play the switch sound). In vanilla, current_scene is then the region
## that is still loading. Here it would be the region you are in: platforms played their switch
## sound near gates, doors animated open after you arrived. So the waits registered by dormant
## nodes are taken off the tree's signals and resumed by the streamer, with current_scene set to
## the dormant region.
const WAIT_SIGNALS := ["process_frame", "physics_frame"]

func _wait_snapshot() -> Dictionary:
	var d := {}
	for sig in WAIT_SIGNALS:
		for c in _tree.get_signal_connection_list(sig):
			d[c.callable] = true
	return d


func _capture_waits(before: Dictionary) -> void:
	for sig in WAIT_SIGNALS:
		for c in _tree.get_signal_connection_list(sig):
			var cb: Callable = c.callable
			if before.has(cb) or not (c.flags & CONNECT_ONE_SHOT):
				continue
			if cb.get_method() != &"_signal_callback":
				continue  # only coroutine resumes (await), not regular handlers
			_tree.disconnect(sig, cb)
			# [resume, physics?, frame count when captured]
			var phys: bool = sig == "physics_frame"
			_waits.append([cb, phys, Engine.get_physics_frames() if phys else Engine.get_process_frames()])


## Resume dormant waits of one kind whose frame has come. Call with current_scene = root.
## physics_frame waits are resumed from the tree's physics_frame signal (_on_physics_frame), like
## in vanilla: at high FPS several frames are drawn between two physics ticks, and doors that wait
## two ticks for their raycasts read them before they ran (red key / soul doors opened hundreds of
## metres wide or stayed shut). Also keeps vanilla order with the doors' own timer chain, which
## waits on the same signal and opens the door with the measured width.
func _resume_waits(phys := false) -> void:
	if _waits.is_empty():
		return
	var list := _waits
	_waits = []
	var pf := Engine.get_physics_frames()
	var f := Engine.get_process_frames()
	var due: Array = []
	for w in list:
		if w[1] == phys and (pf if phys else f) > w[2]:
			due.append(w[0])
		else:
			_waits.append(w)
	if due.is_empty():
		return
	var before := _wait_snapshot()
	for cb in due:
		if cb.is_valid():
			cb.call()
	_capture_waits(before)  # waits chained from there


## Called by the mod every frame while the region is dormant (also once it is READY).
func pump(phys := false) -> void:
	if _waits.is_empty() or root == null or not is_instance_valid(root) or not root.is_inside_tree():
		return
	if phase >= ACTIVE:
		return
	var old_scene := _tree.current_scene
	Engine.set_meta("seamless_next_player", next_player)
	_tree.current_scene = root
	_resume_waits(phys)
	_tree.current_scene = old_scene
	if Engine.has_meta("seamless_next_player"):
		Engine.remove_meta("seamless_next_player")


## Connected first to the tree's physics_frame, so dormant waits resume before anything
## connected later (same order as vanilla).
func _on_physics_frame() -> void:
	pump(true)


func _disconnect_physics() -> void:
	if _tree.physics_frame.is_connected(_on_physics_frame):
		_tree.physics_frame.disconnect(_on_physics_frame)


## At activation: what is still waiting goes back to the tree's signal.
func _release_waits() -> void:
	for w in _waits:
		if w[0].is_valid():
			(_tree.physics_frame if w[1] else _tree.process_frame).connect(w[0], CONNECT_ONE_SHOT)
	_waits.clear()
	_disconnect_physics()


func _restore_owner_tree_shallow(n: Node) -> void:
	if _owners.has(n) and n.owner != _owners[n]:
		n.owner = _owners[n]


## Neutralize a freshly added leaf chunk; remember how to wake it up.
func _make_dormant(node: Node, orig_proc: int) -> void:
	var rec := {"node": node, "proc": orig_proc, "vis": null,
		"bodies": [], "rays": [], "audio": [], "nav": [], "scripted": false}
	if node is Node3D:
		rec.vis = node.visible
		node.visible = false
	elif node is CanvasItem or node is CanvasLayer:
		_canvas_hide(node)
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_script() != null:
			rec.scripted = true
			if n.has_method("seamless_arrive"):
				_fall_gates.append(n)
			# a script that joins a hard-coded "targetname_X" group must still be found by the
			# region's triggers, whose targets were renamed to X@region
			for g in n.get_groups():
				var gs := String(g)
				if gs.begins_with("targetname_") and not "@" in gs:
					n.add_to_group(gs + "@" + _region_suffix)
		if n.is_in_group("enemy"):
			n.set_meta("seamless_region", _region_suffix)
		# 2D UI inside 3D prefabs (dialog boxes, pickup messages...) isn't hidden by its hidden 3D
		# parent and would draw placeholder text on screen until the region's ready.
		if n != node and (n is CanvasLayer or (n is CanvasItem and not n.get_parent() is CanvasItem)):
			_canvas_hide(n)
		# Collisions: the dormant region lives on its own copy of the game's layers (shifted up by
		# DORMANT_SHIFT bits), so it only touches itself: its raycasts and areas work like in a
		# normal load (laser end points, arena enemies...), but nothing reaches the player or the
		# region you are in.
		if n is CollisionObject3D:
			var b: CollisionObject3D = n
			rec.bodies.append([b, b.collision_layer, b.collision_mask, b.disable_mode])
			b.collision_layer = _dormant_bits(b.collision_layer)
			b.collision_mask = _dormant_bits(b.collision_mask)
			if not n is RigidBody3D:
				b.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE
		elif n is CSGShape3D and n.use_collision:
			rec.bodies.append([n, n.collision_layer, n.collision_mask, -1])
			n.collision_layer = _dormant_bits(n.collision_layer)
			n.collision_mask = _dormant_bits(n.collision_mask)
		elif n is RayCast3D or n is ShapeCast3D:
			# raycasts update in physics processing, which the dormant region doesn't get
			rec.rays.append([n, n.collision_mask, n.process_mode])
			n.collision_mask = _dormant_bits(n.collision_mask)
			n.process_mode = Node.PROCESS_MODE_ALWAYS
		elif n is AudioStreamPlayer or n is AudioStreamPlayer3D or n is AudioStreamPlayer2D:
			# muted while dormant: scripts start sounds in _ready or right after (laser wheel hum,
			# logic chain clicks), and the region is right next to you
			var was_playing: bool = n.playing
			var pos: float = n.get_playback_position() if was_playing else -1.0
			if was_playing:
				n.stop()
			rec.audio.append([n, pos, n.volume_db])
			n.volume_db = DORMANT_DB
		elif n is NavigationRegion3D:
			rec.nav.append([n, n.enabled])
			n.enabled = false
		stack.append_array(n.get_children())
	var p := Vector3.ZERO
	if node is Node3D:
		p = node.global_position
	rec["pos"] = p
	_leaves.append(rec)


## Called by the transition when the player crosses the gate (one frame).
## `old_scene` is the region being left. Returns false if the region isn't ready.
var act_times := {}

func _mark(k: String, t: int) -> int:
	var n := Time.get_ticks_usec()
	act_times[k] = (n - t) / 1000.0
	return n

func activate(old_scene: Node) -> bool:
	if phase != READY:
		return false
	var t := Time.get_ticks_usec()
	# a race in the region being left ends here (vanilla just drops it when the scene changes;
	# we emit race_ended so checkpoints of both regions switch off)
	var race_enemies: Array = []
	if RaceManager.race_active:
		for e in RaceManager.enemies:
			if not is_instance_valid(e):
				continue
			if e.get_meta("seamless_region", "") == _region_suffix:
				race_enemies.append(e)  # ours, taken out by start_race while dormant
			elif e.get_parent() == null:
				e.queue_free()  # the old region's, it is going away
		RaceManager.enemies.clear()
		RaceManager.stop_race()
	# vanilla order: old region's stage_exited first
	if old_scene != null and old_scene.get("seamless_suppress_exit") != null:
		old_scene.seamless_suppress_exit = true
	Events.stage_exited.emit()
	for cp in _race_checkpoints:
		if is_instance_valid(cp):
			RaceManager.checkpoints.push_back(cp)
			RaceManager.checkpoints_total += 1
	_race_checkpoints.clear()
	t = _mark("stage_exited", t)
	# held nodes of the old region that set globals must go before ours enter
	if is_instance_valid(Events.player) and Events.player.is_inside_tree():
		var op: Node = Events.player
		op.get_parent().remove_child(op)
		op.queue_free()
	t = _mark("old_player", t)
	if old_scene != null:
		var oenv = old_scene.get("world_environment")
		if oenv is Node and is_instance_valid(oenv) and oenv.is_inside_tree():
			oenv.get_parent().remove_child(oenv)
			oenv.queue_free()
	_tree.current_scene = root
	_release_waits()
	for e in race_enemies:
		if e.get_parent() == null:
			root.add_child(e)
	t = _mark("old_env", t)
	for h in _held:
		h[0].add_child(h[1])
		_restore_owner_tree(h[1])
	t = _mark("held_add", t)
	root.process_mode = _root_process_mode
	t = _mark("root_enable", t)
	phase = ACTIVE
	# geometry (unscripted) first, then scripted chunks; each sorted by distance in restore_step
	return true


## The floor/ceiling gate of this region that leads back to `from_map` (e.g. "map_dark").
func find_fall_gate(from_map: String) -> Area3D:
	for g in _fall_gates:
		if is_instance_valid(g) and g._to_stage == from_map:
			return g
	return null


## 2D is kept from drawing through its visibility layer (no layer = culled by every viewport), not
## `visible`: scripts hide their UI when the region is ready (Perdition Passways intro overlay,
## dialog boxes), and restoring `visible` afterwards showed it again (the intro played each time).
func _canvas_hide(n: Node) -> void:
	if n is CanvasItem:
		if n.visibility_layer != 0:
			_canvas.append([n, n.visibility_layer])
			n.visibility_layer = 0
	elif n is CanvasLayer:
		for c in n.get_children():
			if c is CanvasItem:
				_canvas_hide(c)


## Let the 2D UI draw again (call after the region's ready has been emitted, when the prefabs have
## set up their UI like in vanilla).
func restore_canvas() -> void:
	for c in _canvas:
		if is_instance_valid(c[0]) and c[0].visibility_layer == 0:
			c[0].visibility_layer = c[1]
	_canvas.clear()


## Wake up leaf chunks near `center` first. Returns true when everything is restored.
func restore_step(center: Vector3, budget: int, radius_all: float = 0.0) -> bool:
	if _restore_queue.is_empty() and not _leaves.is_empty():
		var geo := _leaves.filter(func(r): return not r.scripted)
		var scr := _leaves.filter(func(r): return r.scripted)
		geo.sort_custom(func(a, b): return a.pos.distance_squared_to(center) < b.pos.distance_squared_to(center))
		scr.sort_custom(func(a, b): return a.pos.distance_squared_to(center) < b.pos.distance_squared_to(center))
		_restore_queue = geo + scr
		_leaves.clear()
	var t0 := Time.get_ticks_usec()
	while not _restore_queue.is_empty():
		var rec: Dictionary = _restore_queue[0]
		var near: bool = radius_all > 0 and rec.pos.distance_to(center) <= radius_all
		if not near and Time.get_ticks_usec() - t0 >= budget:
			return false
		_restore_queue.pop_front()
		_wake(rec)
	phase = DONE
	return true


const DORMANT_SHIFT := 16
const DORMANT_DB := -80.0

func _dormant_bits(v: int) -> int:
	if v >= (1 << DORMANT_SHIFT):
		return 0  # not expected (the game uses bits 0-13); keep it out of everything
	return v << DORMANT_SHIFT


## Value to restore when waking: the original, unless a script changed it while dormant.
func _live_bits(current: int, original: int) -> int:
	if current == _dormant_bits(original):
		return original
	if current & ((1 << DORMANT_SHIFT) - 1) == 0:
		return current >> DORMANT_SHIFT  # changed while dormant, set on the dormant layers
	return current  # set to a live value by a script: keep it


func _wake(rec: Dictionary) -> void:
	var node: Node = rec.node
	if not is_instance_valid(node) or not node.is_inside_tree():
		return
	for b in rec.bodies:
		var o = b[0]
		if not is_instance_valid(o):
			continue
		o.collision_layer = _live_bits(o.collision_layer, b[1])
		o.collision_mask = _live_bits(o.collision_mask, b[2])
		if b[3] != -1:
			o.disable_mode = b[3]
	for r in rec.rays:
		var o = r[0]
		if not is_instance_valid(o):
			continue
		o.collision_mask = _live_bits(o.collision_mask, r[1])
		o.process_mode = r[2]
	for nv in rec.nav:
		if is_instance_valid(nv[0]):
			nv[0].enabled = nv[1]
	node.process_mode = rec.proc
	if rec.vis != null:
		node.visible = rec.vis
	for a in rec.audio:
		var o = a[0]
		if not is_instance_valid(o):
			continue
		if o.volume_db == DORMANT_DB:
			o.volume_db = a[2]
		if a[1] >= 0.0 and not o.playing:
			o.play(a[1])


## Throw away a region that was never activated. `now` frees immediately (game shutting down).
func abort(now := false) -> void:
	if phase == LOADING:
		# can't cancel a threaded load; take it when finished so it is released
		pass
	if root != null and is_instance_valid(root) and root.is_inside_tree():
		for t in _tree.get_nodes_in_group("seamless_arena"):
			if root.is_ancestor_of(t):
				for e in t.enemies:
					if is_instance_valid(e) and e.get_parent() == null:
						_free(e, now)
	if root != null and is_instance_valid(root):
		if root.is_inside_tree():
			root.get_parent().remove_child(root)
		_free(root, now)
	if _builder != null and _builder.root != null and is_instance_valid(_builder.root):
		_free(_builder.root, now)  # aborted while building
	_builder = null
	for h in _held:
		if is_instance_valid(h[1]) and h[1].get_parent() == null:
			_free(h[1], now)
	for c in _chunks.slice(_ci) + _late_chunks:
		if is_instance_valid(c[1]) and c[1].get_parent() == null:
			_free(c[1], now)
	# split containers waiting in the planning queue still hold their children
	for n in _plan_queue:
		if is_instance_valid(n) and n.get_parent() == null and n != root:
			_free(n, now)
	_plan_queue.clear()
	_waits.clear()
	_disconnect_physics()
	_late_chunks.clear()
	_canvas.clear()
	_chunks.clear()
	_held.clear()
	_leaves.clear()
	phase = DONE


func _free(n: Node, now: bool) -> void:
	if now:
		n.free()
	else:
		n.queue_free()
