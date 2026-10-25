@tool
extends RefCounted
## Connects the GeoFigure editor to the AnimationPlayer animating a figure: the
## Animation panel's current animation and time, keyframes for posed shapes
## (and their RESET keys), and applying RESET.
##
## Changes to animations are returned as operations, [do, undo] Callables, so
## the editor can put them in one undo action with the pose changes. They find
## tracks by path rather than index, so they work in any order.

## The fields of shapes that figures can override, and so animate.
const FIELDS: Array[StringName] = [&"position", &"rotation_degrees", &"scale", &"visible"]
const RESET := &"RESET"
const _AXES: Array[String] = ["x", "y", "z"]

## The figure being animated, a node in the edited scene.
var figure: GeoFigure
## The player whose animations are edited, or null.
var player: AnimationPlayer
## The pose changes not yet keyed, as [shape, field, axis] (axis -1 for
## visible). Cleared when keyed, or when the animation or time changes.
var changed: Array = []

var _last_animation := &""
var _last_time := -1.0


## The AnimationPlayers that can animate the figure: its own children first,
## then any other in the scene whose root node is the figure or an ancestor.
func find_players() -> Array[AnimationPlayer]:
	var result: Array[AnimationPlayer] = []
	if not figure or not figure.is_inside_tree():
		return result
	for child in figure.get_children():
		if child is AnimationPlayer:
			result.append(child)
	var scene_root := figure.get_tree().edited_scene_root
	if not scene_root or not (scene_root == figure or scene_root.is_ancestor_of(figure)):
		scene_root = figure.get_tree().root
	for node in scene_root.find_children("*", "AnimationPlayer", true, false):
		var found := node as AnimationPlayer
		if result.has(found):
			continue
		var target := found.get_node_or_null(found.root_node)
		if target and (target == figure or target.is_ancestor_of(figure)):
			result.append(found)
	return result


## The animation picked in the Animation panel (the player's assigned
## animation), or "".
func current_animation_name() -> StringName:
	if not player or not player.is_inside_tree():
		return &""
	var animation_name := StringName(player.assigned_animation)
	return animation_name if player.has_animation(animation_name) else &""


func current_animation() -> Animation:
	var animation_name := current_animation_name()
	return player.get_animation(animation_name) if animation_name else null


## The Animation panel's time, in seconds.
func current_time() -> float:
	return player.current_animation_position if current_animation_name() else 0.0


## Call each frame. Forgets unkeyed changes when the animation or time
## changes. Returns whether they changed.
func poll() -> bool:
	var animation_name := current_animation_name()
	var time := current_time()
	if animation_name == _last_animation and is_equal_approx(time, _last_time):
		return false
	_last_animation = animation_name
	_last_time = time
	changed.clear()
	return true


## Records pose changes for keying: entries of [shape, field, axis].
func record_changes(entries: Array) -> void:
	for entry: Array in entries:
		if not _has_entry(changed, entry):
			changed.append(entry)


## The changed axes of a value change of a shape's field, as entries.
static func changed_entries(shape: GeoShape, field: StringName, old_value: Variant,
		new_value: Variant) -> Array:
	var entries := []
	if new_value is Vector3:
		for axis in 3:
			if not is_equal_approx(old_value[axis], new_value[axis]):
				entries.append([shape, field, axis])
	elif old_value != new_value:
		entries.append([shape, field, -1])
	return entries


## Every axis of position, rotation and scale of shapes, as entries.
static func pose_entries(shapes: Array) -> Array:
	var entries := []
	for shape: GeoShape in shapes:
		for field in [&"position", &"rotation_degrees", &"scale"]:
			for axis in 3:
				entries.append([shape, field, axis])
	return entries


## Operations that key entries at the current time in the current animation,
## with their values from values(shape, field), plus their RESET keys. Empty if
## no animation is picked.
func key_operations(entries: Array, values: Callable) -> Array:
	var animation := current_animation()
	if not animation:
		return []
	var keys := {}
	var reset := _reset_animation()
	for entry: Array in entries:
		var shape: GeoShape = entry[0]
		var target := _track_target(animation, reset, shape, entry[1], entry[2])
		keys[target[0]] = _value_for(values.call(shape, entry[1]), target[1], entry[2])
	var operations := []
	var time := current_time()
	for path: NodePath in keys:
		operations.append(_key_operation(animation, path, time, keys[path]))
	return operations + reset_operations(entries)


## Operations that give RESET (creating it if needed) a key at 0 with each
## entry's rest value (the shape's own), unless it has a track for it already.
func reset_operations(entries: Array) -> Array:
	var library := _library()
	if not library or entries.is_empty():
		return []
	var operations := []
	var reset := library.get_animation(RESET) if library.has_animation(RESET) else null
	if not reset:
		reset = Animation.new()
		reset.length = 0.001
		operations.append([library.add_animation.bind(RESET, reset),
				library.remove_animation.bind(RESET)])
	var animation := current_animation()
	var keys := {}
	for entry: Array in entries:
		var shape: GeoShape = entry[0]
		var target := _track_target(animation, reset, shape, entry[1], entry[2])
		var path: NodePath = target[0]
		var track := reset.find_track(path, Animation.TYPE_VALUE)
		if keys.has(path) or (track >= 0 and reset.track_get_key_count(track) > 0):
			continue
		keys[path] = _value_for(shape.get(entry[1]), target[1], entry[2])
	for path: NodePath in keys:
		operations.append(_key_operation(reset, path, 0.0, keys[path]))
	return operations


## The property changes that apply RESET at time 0, as [node, property, old
## value, new value].
func reset_changes() -> Array:
	var reset := _reset_animation()
	var changes := []
	if not reset:
		return changes
	var root := player.get_node_or_null(player.root_node)
	if not root:
		return changes
	var values := {}
	for track in reset.get_track_count():
		if reset.track_get_type(track) != Animation.TYPE_VALUE \
				or not reset.track_is_enabled(track) or reset.track_get_key_count(track) == 0:
			continue
		var path := reset.track_get_path(track)
		var node := root.get_node_or_null(NodePath(path.get_concatenated_names()))
		if not node or path.get_subname_count() == 0:
			continue
		var target := [node, StringName(path.get_subname(0))]
		var value: Variant = reset.value_track_interpolate(track, 0.0)
		if path.get_subname_count() > 1:
			var whole: Variant = values.get(target, node.get(target[1]))
			whole[path.get_subname(1)] = value
			value = whole
		values[target] = value
	for target: Array in values:
		var old_value: Variant = target[0].get(target[1])
		if old_value != values[target]:
			changes.append([target[0], target[1], old_value, values[target]])
	return changes


func has_reset() -> bool:
	return _reset_animation() != null


## Inserts (or replaces) a key, creating its track if needed. (An undoable
## operation.)
func set_key(animation: Animation, path: NodePath, time: float, value: Variant) -> void:
	var track := animation.find_track(path, Animation.TYPE_VALUE)
	if track < 0:
		track = animation.add_track(Animation.TYPE_VALUE)
		animation.track_set_path(track, path)
		if value is bool:
			animation.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
	var key := animation.track_find_key(track, time, Animation.FIND_MODE_APPROX)
	if key >= 0:
		animation.track_set_key_value(track, key, value)
	else:
		animation.track_insert_key(track, time, value)


## Undoes set_key(): restores the old key (or removes the key), and removes the
## track if set_key() made it.
func restore_key(animation: Animation, path: NodePath, time: float, had_track: bool,
		old_value: Variant) -> void:
	var track := animation.find_track(path, Animation.TYPE_VALUE)
	if track < 0:
		return
	var key := animation.track_find_key(track, time, Animation.FIND_MODE_APPROX)
	if old_value != null:
		if key >= 0:
			animation.track_set_key_value(track, key, old_value)
		else:
			animation.track_insert_key(track, time, old_value)
	elif key >= 0:
		animation.track_remove_key(track, key)
	if not had_track and animation.track_get_key_count(track) == 0:
		animation.remove_track(track)


func _key_operation(animation: Animation, path: NodePath, time: float, value: Variant) -> Array:
	var track := animation.find_track(path, Animation.TYPE_VALUE)
	var old_value: Variant = null
	if track >= 0:
		var key := animation.track_find_key(track, time, Animation.FIND_MODE_APPROX)
		if key >= 0:
			old_value = animation.track_get_key_value(track, key)
	return [set_key.bind(animation, path, time, value),
			restore_key.bind(animation, path, time, track >= 0, old_value)]


# The track for a shape's field (and axis), as [path, whether it's the whole
# value]. Vectors get a track per axis, unless the animation or RESET already
# has a track for the whole vector.
func _track_target(animation: Animation, reset: Animation, shape: GeoShape, field: StringName,
		axis: int) -> Array:
	var base := _base_path(shape.name, field)
	var whole := NodePath(base)
	if axis < 0:
		return [whole, true]
	for existing: Animation in [animation, reset]:
		if existing and existing.find_track(whole, Animation.TYPE_VALUE) >= 0:
			return [whole, true]
	return [NodePath("%s:%s" % [base, _AXES[axis]]), false]


# The value to key: the whole value, or one axis of it.
static func _value_for(value: Variant, whole: bool, axis: int) -> Variant:
	return value if whole or axis < 0 else value[axis]


func _base_path(shape_name: StringName, field: StringName) -> String:
	var root := player.get_node_or_null(player.root_node) if player else null
	var node_path := String(root.get_path_to(figure)) if root else "."
	return "%s:shapes/%s/%s" % [node_path, shape_name, field]


# The library to add RESET to: the current animation's, else the default one,
# else the first.
func _library() -> AnimationLibrary:
	if not player:
		return null
	var animation := current_animation()
	if animation:
		var library_name := player.find_animation_library(animation)
		return player.get_animation_library(library_name)
	if player.has_animation_library(&""):
		return player.get_animation_library(&"")
	var names := player.get_animation_library_list()
	return player.get_animation_library(names[0]) if not names.is_empty() else null


func _reset_animation() -> Animation:
	if not player:
		return null
	var library := _library()
	if library and library.has_animation(RESET):
		return library.get_animation(RESET)
	return player.get_animation(RESET) if player.has_animation(RESET) else null


static func _has_entry(entries: Array, entry: Array) -> bool:
	for existing: Array in entries:
		if existing[0] == entry[0] and existing[1] == entry[1] and existing[2] == entry[2]:
			return true
	return false
