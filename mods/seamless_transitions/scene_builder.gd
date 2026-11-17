extends RefCounted
## Builds a PackedScene node by node from its SceneState, a few nodes per call to step(),
## so the cost of PackedScene.instantiate() is spread over many frames.
## The result should match ps.instantiate() (checked by the test harness against every map).

var state: SceneState
var root: Node
var done := false
## When set, the values of these keys inside a node's `properties` dictionary get "@<suffix>"
## appended, so trigger/target group names of this region can't collide with another region's.
var name_suffix := ""
const SUFFIX_KEYS := ["target", "targetname", "eventname", "pathname", "path"]

var _ps: PackedScene
var _i := 0
var _count := 0
var _nodes := []            # SceneState index -> Node
var _local := {}            # original local_to_scene Resource -> duplicate
var _deferred := []         # [node, property, NodePath or Array[NodePath]]
var _node_props := {}       # cache key -> {prop name: [type, hint, hint_string]}


func _init(ps: PackedScene) -> void:
	_ps = ps
	state = ps.get_state()
	_count = state.get_node_count()
	_nodes.resize(_count)


## Builds nodes until budget_usec is used up. Returns true when the scene is complete.
func step(budget_usec: int) -> bool:
	if done:
		return true
	var t0 := Time.get_ticks_usec()
	while _i < _count:
		_build(_i)
		_i += 1
		if Time.get_ticks_usec() - t0 >= budget_usec:
			return false
	_finish()
	done = true
	return true


func progress() -> float:
	return float(_i) / max(_count, 1)


func _build(i: int) -> void:
	var name := state.get_node_name(i)
	var type := state.get_node_type(i)
	var sub: PackedScene = state.get_node_instance(i)
	var node: Node = null
	var parent: Node = null
	var existing := false

	if i > 0:
		var ppath := state.get_node_path(i, true)
		parent = root.get_node_or_null(ppath) if str(ppath) != "." else root
		if parent == null:
			push_error("[SceneBuilder] missing parent %s for %s" % [ppath, name])
			return

	if sub != null:
		if state.is_node_instance_placeholder(i):
			push_warning("[SceneBuilder] instance placeholder loaded directly: " + name)
		node = sub.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	elif type != "":
		node = ClassDB.instantiate(type)
	else:
		# Override of a node that already exists (inside an instanced sub-scene, or the root of
		# an inherited scene).
		if i == 0:
			push_error("[SceneBuilder] inherited root scenes are not supported")
			return
		node = parent.get_node_or_null(NodePath(name))
		existing = true
		if node == null:
			push_error("[SceneBuilder] override target not found: %s/%s" % [parent.get_path(), name])
			return

	if not existing:
		node.name = name

	_apply_props(i, node)

	for g in state.get_node_groups(i):
		node.add_to_group(g, true)

	if i == 0:
		root = node
	elif not existing:
		parent.add_child(node, false)
		node.owner = root
		var idx := state.get_node_index(i)
		if idx >= 0 and idx < parent.get_child_count():
			parent.move_child(node, idx)
	_nodes[i] = node


func _apply_props(i: int, node: Node) -> void:
	var n := state.get_node_property_count(i)
	# script first, so exported script variables exist when we set them
	for p in n:
		if state.get_node_property_name(i, p) == &"script":
			node.set_script(state.get_node_property_value(i, p))
			break
	for p in n:
		var pname := state.get_node_property_name(i, p)
		if pname == &"script":
			continue
		var v = state.get_node_property_value(i, p)
		var vt := typeof(v)
		if vt == TYPE_NODE_PATH or (vt == TYPE_ARRAY and _array_has_paths(v)):
			var info = _prop_info(node, pname)
			if info != null and (info[0] == TYPE_OBJECT or (info[0] == TYPE_ARRAY and vt == TYPE_ARRAY)):
				_deferred.append([node, pname, v])
				continue
		elif vt == TYPE_OBJECT and v is Resource:
			v = _localize(v)
		elif vt == TYPE_DICTIONARY and name_suffix != "" and pname == &"properties":
			v = _suffix_names(v)
		node.set(pname, v)


func _suffix_names(d: Dictionary) -> Dictionary:
	var changed := false
	for k in SUFFIX_KEYS:
		if d.has(k) and typeof(d[k]) == TYPE_STRING and d[k] != "":
			changed = true
			break
	if not changed:
		return d
	var out := d.duplicate()
	for k in SUFFIX_KEYS:
		if out.has(k) and typeof(out[k]) == TYPE_STRING and out[k] != "":
			out[k] = out[k] + "@" + name_suffix
	return out


func _array_has_paths(a: Array) -> bool:
	return a.size() > 0 and typeof(a[0]) == TYPE_NODE_PATH


func _prop_info(node: Node, pname: StringName):
	var sc = node.get_script()
	var key: String = node.get_class() + "|" + (sc.resource_path if sc else "")
	var d: Dictionary = _node_props.get(key, {})
	if d.is_empty():
		for pi in node.get_property_list():
			d[StringName(pi.name)] = [pi.type, pi.hint, pi.hint_string]
		_node_props[key] = d
	return d.get(pname)


func _localize(r: Resource) -> Resource:
	if not r.resource_local_to_scene:
		return r
	if _local.has(r):
		return _local[r]
	var dup := r.duplicate(true)
	_local[r] = dup
	return dup


func _finish() -> void:
	for d in _deferred:
		var node: Node = d[0]
		var v = d[2]
		if typeof(v) == TYPE_NODE_PATH:
			node.set(d[1], node.get_node_or_null(v) if not v.is_empty() else null)
		else:
			var arr = node.get(d[1])
			if typeof(arr) == TYPE_ARRAY:
				arr = arr.duplicate()
				arr.clear()
			else:
				arr = []
			for p in v:
				arr.append(node.get_node_or_null(p))
			node.set(d[1], arr)
	for c in state.get_connection_count():
		var src: Node = root.get_node_or_null(state.get_connection_source(c))
		var dst: Node = root.get_node_or_null(state.get_connection_target(c))
		if src == null or dst == null:
			continue
		var cb := Callable(dst, state.get_connection_method(c))
		var binds := state.get_connection_binds(c)
		if binds.size() > 0:
			cb = cb.bindv(binds)
		var unbinds := state.get_connection_unbinds(c)
		if unbinds > 0:
			cb = cb.unbind(unbinds)
		var sig := state.get_connection_signal(c)
		if not src.is_connected(sig, cb):
			src.connect(sig, cb, state.get_connection_flags(c) | Object.CONNECT_PERSIST)
	for dup in _local.values():
		dup.setup_local_to_scene()
	root.scene_file_path = _ps.resource_path
	_nodes.clear()
