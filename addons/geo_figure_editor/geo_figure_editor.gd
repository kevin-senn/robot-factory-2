@tool
extends VBoxContainer
## The GeoFigure main screen: the edited figure's shapes as a tree, three axis
## views (front, side and top) and an orbiting 3D view, sharing one selection.
##
## Edits go through the editor's undo history. Without a plugin (e.g. when
## run as a test), they apply directly and nothing is saved.
##
## In animation mode (for a GeoFigure in a scene), the views show the figure's
## current pose, and posing shapes overrides their fields on the figure (its
## "shapes/<name>/<field>" properties) instead of changing the shapes. Key adds
## the posed fields as keyframes to the animation picked in the Animation panel,
## and every posed field gets a RESET key with the shape's own value.

signal selection_changed

const M := preload("res://addons/geo_figure_editor/geo_editor_math.gd")
const View := preload("res://addons/geo_figure_editor/geo_editor_view.gd")
const ShapeTree := preload("res://addons/geo_figure_editor/geo_shape_tree.gd")
const MultiEdit := preload("res://addons/geo_figure_editor/geo_shape_multi_edit.gd")
const Animator := preload("res://addons/geo_figure_editor/geo_figure_animator.gd")

const _PLAYER_REFRESH_SECONDS := 0.5
const _PIXEL_ART := preload("res://addons/geo_render/styles/pixel_art.tres")
const _BUILT_IN_STYLES: Array[GeoStyle] = [
	_PIXEL_ART,
	preload("res://addons/geo_render/styles/pixel_cel.tres"),
	preload("res://addons/geo_render/styles/pixel_dither.tres"),
	preload("res://addons/geo_render/styles/cel.tres"),
]

enum Mode { MOVE, ROTATE, SCALE }

const _SETTING_SNAP := "geo_figure_editor/snap_enabled"
const _SETTING_SNAP_STEP := "geo_figure_editor/snap_step"
const _SETTING_KEEP_PLACE := "geo_figure_editor/reparent_keeps_place"
const _SETTING_PIXEL_SIZE := "geo_figure_editor/pixel_size"
const _SETTING_PREVIEW_STEPPED := "geo_figure_editor/preview_stepped"
const _SETTING_PREVIEW_FPS := "geo_figure_editor/preview_fps"

## The plugin, when running in the editor.
var plugin: EditorPlugin
## The root of the shape tree being edited.
var root: GeoShape
## The GeoFigure (in the edited scene) whose shapes are being edited, if any.
var figure: GeoFigure
## Whether posing shapes animates the figure (see the class description).
var animating := false
var animator := Animator.new()
var selection: Array[GeoShape] = []
var mode := Mode.MOVE
var snap_enabled := true
## Grid size for moving shapes, and how far the arrow keys move them.
var snap_step := 0.5
## Whether a shape keeps its place on screen when it's given a new parent (or
## else keeps its position, rotation and scale relative to its parent).
var reparent_keeps_place := true
## The size of each art pixel in the pixelated views, in the figure's units.
## Only the views use it; figures in scenes keep their own camera's.
var pixel_size := GeoCamera.DEFAULT_PIXEL_SIZE
## Whether the views show playing animations in steps of 1 / preview_fps seconds
## (like GeoFigure.animation_fps in game) rather than smoothly.
var preview_stepped := false
var preview_fps := 12

var views: Array[View] = []
var shape_tree: ShapeTree

var _mode_buttons: Array[Button] = []
var _snap_check := CheckBox.new()
var _snap_spin := SpinBox.new()
var _keep_place_check := CheckBox.new()
var _pixel_size_spin := SpinBox.new()
var _target_label := Label.new()
var _status_label := Label.new()
var _save_button := Button.new()
var _new_button := Button.new()
var _load_button := Button.new()
var _save_as_button := Button.new()
var _multi_edit := MultiEdit.new()
var _structure: Array = []
var _refresh_queued := false
# Saved files (shape trees and animation libraries) with unsaved changes.
var _dirty_files: Array[Resource] = []
var _name_suffix := RegEx.create_from_string("_\\d+$")
var _message := ""

var _animation_bar := HBoxContainer.new()
var _animate_button := Button.new()
var _setup_button := Button.new()
var _player_option := OptionButton.new()
var _animation_label := Label.new()
var _key_button := Button.new()
var _reset_button := Button.new()
var _stepped_check := CheckBox.new()
var _fps_spin := SpinBox.new()
var _players: Array[AnimationPlayer] = []
var _player_refresh_time := 0.0
var _watched_library: AnimationLibrary
# The figure's pose as last copied to the views: property -> value.
var _pose_cache := {}


func _init() -> void:
	name = &"GeoFigureEditor"
	size_flags_vertical = SIZE_EXPAND_FILL
	_multi_edit.editor = self
	_build_toolbar()
	_build_animation_bar()
	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(split)
	shape_tree = ShapeTree.new()
	shape_tree.editor = self
	shape_tree.custom_minimum_size.x = 260
	split.add_child(shape_tree)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = SIZE_EXPAND_FILL
	grid.size_flags_vertical = SIZE_EXPAND_FILL
	split.add_child(grid)
	for config: Array in [
		["Front", 0.0, Vector3.ZERO, false, null],
		["Side", 0.0, Vector3(0.0, -90.0, 0.0), false, null],
		["Top", 90.0, Vector3.ZERO, false, null],
		["3D", GeoCamera.DEFAULT_ELEVATION_DEGREES, Vector3(0.0, -45.0, 0.0), true, _PIXEL_ART],
	]:
		var view := View.new()
		view.setup(self, config[0], config[1], config[2], config[3], config[4])
		view.set_pixel_size(pixel_size)
		grid.add_child(view)
		views.append(view)
	_update_status()


func _build_toolbar() -> void:
	var bar := HBoxContainer.new()
	add_child(bar)
	var group := ButtonGroup.new()
	for i in 3:
		var button := Button.new()
		button.text = ["Move (W)", "Rotate (E)", "Scale (R)"][i]
		button.tooltip_text = [
			"Drag shapes to move them in the view's plane. Ctrl: don't snap.",
			"Drag shapes to turn them around the axis the view looks along. Ctrl: don't snap.",
			"Drag shapes to scale them along the view's axes. Shift: uniformly. Ctrl: don't snap.",
		][i]
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = i == mode
		button.focus_mode = FOCUS_NONE
		button.pressed.connect(set_mode.bind(i))
		bar.add_child(button)
		_mode_buttons.append(button)
	bar.add_child(VSeparator.new())

	_snap_check.text = "Snap"
	_snap_check.button_pressed = snap_enabled
	_snap_check.focus_mode = FOCUS_NONE
	_snap_check.toggled.connect(func(on: bool) -> void:
		snap_enabled = on
		_save_setting(_SETTING_SNAP, on))
	bar.add_child(_snap_check)
	_snap_spin.min_value = 0.05
	_snap_spin.max_value = 64.0
	_snap_spin.step = 0.05
	_snap_spin.value = snap_step
	_snap_spin.tooltip_text = "Grid size for moving shapes, and how far the arrow keys move them (Shift: ×10)."
	_snap_spin.value_changed.connect(func(value: float) -> void:
		snap_step = value
		_save_setting(_SETTING_SNAP_STEP, value)
		for view in views:
			view.queue_redraw())
	bar.add_child(_snap_spin)
	_keep_place_check.text = "Reparent keeps place"
	_keep_place_check.tooltip_text = ("On: a shape dragged onto a new parent stays where it is."
			+ "\nOff: it keeps its position, rotation and scale relative to its parent.")
	_keep_place_check.button_pressed = reparent_keeps_place
	_keep_place_check.focus_mode = FOCUS_NONE
	_keep_place_check.toggled.connect(func(on: bool) -> void:
		reparent_keeps_place = on
		_save_setting(_SETTING_KEEP_PLACE, on))
	bar.add_child(_keep_place_check)
	bar.add_child(VSeparator.new())
	var pixel_label := Label.new()
	pixel_label.text = "Pixel size"
	bar.add_child(pixel_label)
	_pixel_size_spin.min_value = 0.5
	_pixel_size_spin.max_value = 32.0
	_pixel_size_spin.step = 0.5
	_pixel_size_spin.allow_greater = true
	_pixel_size_spin.value = pixel_size
	_pixel_size_spin.tooltip_text = ("The size of each art pixel in the views drawn with styles that use the"
			+ " camera's pixel size (like pixel art), in the figure's units (like GeoCamera.pixel_size)."
			+ " Only affects this editor's views.")
	_pixel_size_spin.value_changed.connect(set_pixel_size)
	bar.add_child(_pixel_size_spin)
	var frame_button := Button.new()
	frame_button.text = "Frame"
	frame_button.tooltip_text = "Fit the figure in every view (F frames one view)."
	frame_button.focus_mode = FOCUS_NONE
	frame_button.pressed.connect(frame_all)
	bar.add_child(frame_button)

	_status_label.size_flags_horizontal = SIZE_EXPAND_FILL
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.clip_text = true
	_status_label.add_theme_color_override(&"font_color", Color(1.0, 0.75, 0.3))
	bar.add_child(_status_label)
	bar.add_child(_target_label)
	_new_button.text = "New…"
	_new_button.tooltip_text = "Create a figure: a new GeoShape file with an empty group as its root."
	_new_button.pressed.connect(_on_new_pressed)
	bar.add_child(_new_button)
	_load_button.text = "Load…"
	_load_button.tooltip_text = "Open a GeoShape file to edit."
	_load_button.pressed.connect(_on_load_pressed)
	bar.add_child(_load_button)
	_save_button.text = "Save"
	_save_button.pressed.connect(save_changes)
	bar.add_child(_save_button)
	_save_as_button.text = "Save As…"
	_save_as_button.tooltip_text = "Save a copy of the figure to a new file, and edit the copy."
	_save_as_button.pressed.connect(_on_save_as_pressed)
	bar.add_child(_save_as_button)


# The second toolbar row, shown when editing a GeoFigure in a scene.
func _build_animation_bar() -> void:
	add_child(_animation_bar)
	_animation_bar.visible = false
	_animate_button.text = "Animate"
	_animate_button.toggle_mode = true
	_animate_button.focus_mode = FOCUS_NONE
	_animate_button.tooltip_text = ("Pose the figure for its animations: posing shapes changes"
			+ " the figure, not the shapes, and Key saves the pose as keyframes.\nTurning it off"
			+ " applies RESET.")
	_animate_button.toggled.connect(set_animating)
	_animation_bar.add_child(_animate_button)
	_setup_button.text = "Set Up Animation"
	_setup_button.focus_mode = FOCUS_NONE
	_setup_button.tooltip_text = ("Give the shape an animation library (saved beside its file),"
			+ " and the figure a child AnimationPlayer that plays it.")
	_setup_button.pressed.connect(setup_animation)
	_animation_bar.add_child(_setup_button)
	_player_option.focus_mode = FOCUS_NONE
	_player_option.tooltip_text = "The AnimationPlayer whose animations are edited."
	_player_option.item_selected.connect(func(index: int) -> void:
		_set_player(_players[index]))
	_animation_bar.add_child(_player_option)
	_key_button.text = "Key (K)"
	_key_button.focus_mode = FOCUS_NONE
	_key_button.tooltip_text = ("Add keyframes at the Animation panel's time for the posed"
			+ " fields.\nShift (or Shift+K): key every position, rotation and scale axis of the"
			+ " selected shapes.")
	_key_button.pressed.connect(func() -> void: key_pose(Input.is_key_pressed(KEY_SHIFT)))
	_animation_bar.add_child(_key_button)
	_reset_button.text = "Reset"
	_reset_button.focus_mode = FOCUS_NONE
	_reset_button.tooltip_text = "Apply the RESET animation, returning the figure to its rest pose."
	_reset_button.pressed.connect(apply_reset)
	_animation_bar.add_child(_reset_button)
	_animation_bar.add_child(VSeparator.new())
	_stepped_check.text = "Stepped"
	_stepped_check.focus_mode = FOCUS_NONE
	_stepped_check.tooltip_text = ("Preview playing animations in steps of 1 / FPS seconds, like"
			+ " GeoFigure.animation_fps in game (the keys stay smooth). Off: smooth.")
	_stepped_check.toggled.connect(func(on: bool) -> void:
		preview_stepped = on
		_fps_spin.editable = on
		_save_setting(_SETTING_PREVIEW_STEPPED, on))
	_animation_bar.add_child(_stepped_check)
	_fps_spin.min_value = 1
	_fps_spin.max_value = 60
	_fps_spin.step = 1
	_fps_spin.rounded = true
	_fps_spin.allow_greater = true
	_fps_spin.suffix = "fps"
	_fps_spin.value = preview_fps
	_fps_spin.editable = preview_stepped
	_fps_spin.tooltip_text = "Frames per second for the stepped preview."
	_fps_spin.value_changed.connect(func(value: float) -> void:
		preview_fps = maxi(roundi(value), 1)
		_save_setting(_SETTING_PREVIEW_FPS, preview_fps))
	_animation_bar.add_child(_fps_spin)
	_animation_label.add_theme_color_override(&"font_color", Color(1.0, 1.0, 1.0, 0.7))
	_animation_bar.add_child(_animation_label)


## Loads the toolbar settings from the editor settings. The plugin calls this
## after setting plugin.
func load_settings() -> void:
	if not plugin:
		return
	var settings := EditorInterface.get_editor_settings()
	for entry: Array in [[_SETTING_SNAP, snap_enabled], [_SETTING_SNAP_STEP, snap_step],
			[_SETTING_KEEP_PLACE, reparent_keeps_place], [_SETTING_PIXEL_SIZE, pixel_size],
			[_SETTING_PREVIEW_STEPPED, preview_stepped], [_SETTING_PREVIEW_FPS, preview_fps]]:
		if not settings.has_setting(entry[0]):
			settings.set_setting(entry[0], entry[1])
		settings.set_initial_value(entry[0], entry[1], false)
	snap_enabled = settings.get_setting(_SETTING_SNAP)
	snap_step = settings.get_setting(_SETTING_SNAP_STEP)
	reparent_keeps_place = settings.get_setting(_SETTING_KEEP_PLACE)
	var saved_pixel_size: float = settings.get_setting(_SETTING_PIXEL_SIZE)
	_snap_check.set_pressed_no_signal(snap_enabled)
	_snap_spin.set_value_no_signal(snap_step)
	_keep_place_check.set_pressed_no_signal(reparent_keeps_place)
	preview_stepped = settings.get_setting(_SETTING_PREVIEW_STEPPED)
	preview_fps = settings.get_setting(_SETTING_PREVIEW_FPS)
	_stepped_check.set_pressed_no_signal(preview_stepped)
	_fps_spin.set_value_no_signal(preview_fps)
	_fps_spin.editable = preview_stepped
	set_pixel_size(saved_pixel_size)


func _save_setting(key: String, value: Variant) -> void:
	if plugin:
		EditorInterface.get_editor_settings().set_setting(key, value)


## Edits the shape tree rooted at shape: the shape of source_figure (a node in
## the edited scene), if given.
func set_root(shape: GeoShape, source_figure: GeoFigure = null) -> void:
	if shape == root and source_figure == figure:
		return
	if animating:
		set_animating(false)
	figure = source_figure
	animator.figure = figure
	_refresh_players()
	if shape != root:
		if root and root.changed.is_connected(_on_root_changed):
			root.changed.disconnect(_on_root_changed)
		root = shape
		if root:
			root.changed.connect(_on_root_changed)
		selection.clear()
		_structure.clear()
		for view in views:
			view.set_shape(root)
		_refresh()
		_selection_updated(false)
	_update_animation_bar()


func _process(delta: float) -> void:
	if figure and not is_instance_valid(figure):
		set_root(null) # The scene was closed.
		return
	if not figure or not is_visible_in_tree():
		return
	_player_refresh_time -= delta
	if _player_refresh_time <= 0.0:
		_player_refresh_time = _PLAYER_REFRESH_SECONDS
		_refresh_players()
		_update_animation_bar()
	if animating:
		if animator.poll():
			_update_animation_bar()
		_sync_pose()


## Turns animation mode on or off. Turning it off applies RESET.
func set_animating(on: bool) -> void:
	if on == animating or (on and not (figure and animator.player and root)):
		_animate_button.set_pressed_no_signal(animating)
		return
	if not on:
		apply_reset()
	animating = on
	animator.changed.clear()
	_pose_cache.clear()
	for view in views:
		view.figure.clear_shape_overrides()
		view.invalidate()
	_sync_pose()
	_message = ""
	shape_tree.update_animating()
	_selection_updated()
	_update_animation_bar()
	_update_status()


## A shape's field as shown: the figure's (animated) value in animation mode,
## else the shape's own.
func field_value(shape: GeoShape, field: StringName) -> Variant:
	if animating and can_animate(shape):
		return figure.get(_shape_property(shape, field))
	return shape.get(field)


## Sets a shape's field without an undo action (e.g. while dragging): on the
## figure in animation mode, else on the shape.
func set_field(shape: GeoShape, field: StringName, value: Variant) -> void:
	if not animating:
		shape.set(field, value)
	elif can_animate(shape) and field in Animator.FIELDS:
		figure.set(_shape_property(shape, field), value)
		_sync_pose()


## Whether figures can override (and so animate) shape's fields: it needs a
## name no other shape has.
func can_animate(shape: GeoShape) -> bool:
	if not root or not shape or not shape.name:
		return false
	var model := root.get_compiled()
	var index: int = model.shape_indices.get(shape.name, -1)
	return index >= 0 and model.shapes[index] == shape


## Keys the posed fields (or with whole_selection, every position, rotation
## and scale axis of the selected shapes) at the Animation panel's time.
func key_pose(whole_selection := false) -> void:
	if not animating:
		return
	if not animator.current_animation():
		_show_message("Pick an animation in the Animation panel first.")
		return
	var entries := Animator.pose_entries(selection) if whole_selection \
			else animator.changed.duplicate()
	entries = entries.filter(func(entry: Array) -> bool: return can_animate(entry[0]))
	if entries.is_empty():
		_show_message("Nothing to key: pose some shapes first (Shift+K keys the selection).")
		return
	commit("Key pose", [], true, animator.key_operations(entries, field_value))
	animator.changed.clear()
	_show_message("")
	_update_animation_bar()


## Applies the player's RESET animation, as one undo action.
func apply_reset() -> void:
	commit("Reset pose", animator.reset_changes(), true)
	animator.changed.clear()
	_update_animation_bar()


## Gives the shape an animation library (saved beside its file) and the figure
## a child AnimationPlayer using it, as one undo action.
func setup_animation() -> void:
	if not figure or not root:
		return
	if animating:
		set_animating(false)
	var child_player: AnimationPlayer = null
	for child in figure.get_children():
		if child is AnimationPlayer:
			child_player = child
			break
	var changes := []
	var operations := []
	var library := root.animations
	if not library:
		if child_player and child_player.has_animation_library(&""):
			library = child_player.get_animation_library(&"")
		else:
			library = AnimationLibrary.new()
			var reset := Animation.new()
			reset.length = 0.001
			library.add_animation(Animator.RESET, reset)
		if _is_saved_to_file(root) and not _is_saved_to_file(library):
			var path := _unused_path(root.resource_path.get_basename() + "_animations", "tres")
			var error := ResourceSaver.save(library, path)
			if error != OK:
				push_error("Couldn't save %s: %s" % [path, error_string(error)])
				return
			library.take_over_path(path)
			if plugin:
				EditorInterface.get_resource_filesystem().update_file(path)
		changes.append([root, &"animations", null, library])
	if not child_player:
		var new_player := AnimationPlayer.new()
		new_player.name = &"AnimationPlayer"
		new_player.add_animation_library(&"", library)
		operations.append([_add_player.bind(new_player), figure.remove_child.bind(new_player),
				new_player])
	elif not child_player.has_animation_library(&""):
		operations.append([child_player.add_animation_library.bind(&"", library),
				child_player.remove_animation_library.bind(&"")])
	commit("Set up animation", changes, true, operations)
	# Setting animations doesn't emit changed (it doesn't affect drawing).
	if not changes.is_empty() and _is_saved_to_file(root) and not _dirty_files.has(root):
		_dirty_files.append(root)
	_watch_library()
	_refresh_players()
	_update_animation_bar()


func _add_player(new_player: AnimationPlayer) -> void:
	figure.add_child(new_player, true)
	var tree := figure.get_tree()
	var scene_root := tree.edited_scene_root if tree else null
	new_player.owner = scene_root if scene_root and scene_root != new_player else figure


func _unused_path(base: String, extension: String) -> String:
	var path := "%s.%s" % [base, extension]
	var n := 2
	while ResourceLoader.exists(path):
		path = "%s_%d.%s" % [base, n, extension]
		n += 1
	return path


func _shape_property(shape: GeoShape, field: StringName) -> StringName:
	return StringName("shapes/%s/%s" % [shape.name, field])


# Copies the figure's pose to the views' figures, if it changed.
func _sync_pose() -> void:
	if not animating or not root or not is_instance_valid(figure):
		return
	var model := root.get_compiled()
	var stepped := _stepped_values()
	var changed := false
	for shape_name: StringName in model.shape_indices:
		for field in Animator.FIELDS:
			var property := StringName("shapes/%s/%s" % [shape_name, field])
			var value: Variant = stepped[property] if stepped.has(property) else figure.get(property)
			if _pose_cache.has(property) and _pose_cache[property] == value:
				continue
			_pose_cache[property] = value
			for view in views:
				view.figure.set(property, value)
			changed = true
	if changed:
		for view in views:
			view.invalidate()
		shape_tree.update_items()


# With the stepped preview, while the animation plays: its tracks' values for
# the figure's shapes at the last whole frame, as property -> value. (Paused or
# scrubbing, the views show the figure as posed, so posing isn't hidden.)
func _stepped_values() -> Dictionary:
	var values := {}
	var player := animator.player
	var animation := animator.current_animation()
	if not preview_stepped or not animation or not player.is_playing():
		return values
	var root_node := player.get_node_or_null(player.root_node)
	if not root_node:
		return values
	var time := floorf(animator.current_time() * preview_fps + 0.0001) / preview_fps
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE \
				or not animation.track_is_enabled(track):
			continue
		var path := animation.track_get_path(track)
		if path.get_subname_count() == 0 or not path.get_subname(0).begins_with("shapes/") \
				or root_node.get_node_or_null(NodePath(path.get_concatenated_names())) != figure:
			continue
		var property := StringName(path.get_subname(0))
		var value: Variant = animation.value_track_interpolate(track, time)
		if path.get_subname_count() > 1:
			var whole: Variant = values.get(property, figure.get(property))
			whole[path.get_subname(1)] = value
			value = whole
		values[property] = value
	return values


func _refresh_players() -> void:
	var players := animator.find_players()
	if players != _players:
		_players = players
		_player_option.clear()
		for found in _players:
			_player_option.add_item(String(figure.get_path_to(found)) if figure else String(found.name))
	var player: AnimationPlayer = animator.player if _players.has(animator.player) \
			else (_players[0] if not _players.is_empty() else null)
	_set_player(player)


func _set_player(player: AnimationPlayer) -> void:
	if player == animator.player:
		return
	if animating:
		set_animating(false)
	animator.player = player
	animator.changed.clear()
	if player:
		_player_option.select(_players.find(player))


func _update_animation_bar() -> void:
	_animation_bar.visible = figure != null
	if not figure:
		return
	var player := animator.player
	_setup_button.visible = root != null and (not root.animations or not _has_child_player())
	_animate_button.disabled = not player or not root
	_animate_button.set_pressed_no_signal(animating)
	_player_option.visible = _players.size() > 1
	_key_button.disabled = not animating
	_reset_button.disabled = not animator.has_reset()
	var text := ""
	if not player:
		text = "No AnimationPlayer animates this figure. Set Up Animation adds one."
	elif animating:
		var animation_name := animator.current_animation_name()
		if not animation_name:
			text = "Pick an animation in the Animation panel."
		else:
			text = "%s @ %.2f s" % [animation_name, animator.current_time()]
			if not animator.changed.is_empty():
				text += "   %d posed field%s to key" % [animator.changed.size(),
						"" if animator.changed.size() == 1 else "s"]
	_animation_label.text = text


func _has_child_player() -> bool:
	if not figure:
		return false
	for child in figure.get_children():
		if child is AnimationPlayer:
			return true
	return false


func _show_message(text: String) -> void:
	_message = text
	_update_status()


# Watches the root's animation library for changes, so saving saves it.
func _watch_library() -> void:
	var library := root.animations if root else null
	if library == _watched_library:
		return
	if _watched_library:
		for signal_name in [&"animation_changed", &"animation_added", &"animation_removed",
				&"animation_renamed"]:
			if _watched_library.is_connected(signal_name, _on_library_changed):
				_watched_library.disconnect(signal_name, _on_library_changed)
	_watched_library = library
	if library:
		for signal_name in [&"animation_changed", &"animation_added", &"animation_removed",
				&"animation_renamed"]:
			library.connect(signal_name, _on_library_changed)


func _on_library_changed(_a: Variant = null, _b: Variant = null) -> void:
	if _is_saved_to_file(_watched_library) and not _dirty_files.has(_watched_library):
		_dirty_files.append(_watched_library)
		_update_status()


func contains_shape(shape: GeoShape) -> bool:
	return root != null and root.get_compiled().shapes.has(shape)


func set_mode(new_mode: Mode) -> void:
	mode = new_mode
	_mode_buttons[mode].set_pressed_no_signal(true)


func set_pixel_size(value: float) -> void:
	pixel_size = maxf(value, 0.5)
	_pixel_size_spin.set_value_no_signal(pixel_size)
	_save_setting(_SETTING_PIXEL_SIZE, pixel_size)
	for view in views:
		view.set_pixel_size(pixel_size)


## The styles views can draw with, as [name, GeoStyle or null for smooth]: the
## built-in ones, plus (in the editor) every GeoStyle file in the project.
func available_styles() -> Array:
	var styles := [["Smooth", null]]
	for style in _BUILT_IN_STYLES:
		styles.append([style_name(style), style])
	if plugin:
		var paths := PackedStringArray()
		_find_style_files(EditorInterface.get_resource_filesystem().get_filesystem(), paths)
		for path in paths:
			if not _BUILT_IN_STYLES.any(func(style: GeoStyle) -> bool: return style.resource_path == path):
				var style := load(path) as GeoStyle
				if style:
					styles.append([style_name(style), style])
	return styles


func style_name(style: GeoStyle) -> String:
	if not style.resource_path:
		return "Custom style"
	return style.resource_path.get_file().get_basename().capitalize()


func _find_style_files(directory: EditorFileSystemDirectory, paths: PackedStringArray) -> void:
	for i in directory.get_file_count():
		if directory.get_file_resource_script_class(i) == &"GeoStyle":
			paths.append(directory.get_file_path(i))
	for i in directory.get_subdir_count():
		_find_style_files(directory.get_subdir(i), paths)


func frame_all() -> void:
	for view in views:
		view.frame()


func select(shapes: Array, inspect := true) -> void:
	var new_selection: Array[GeoShape] = []
	for shape: GeoShape in shapes:
		if shape and not new_selection.has(shape):
			new_selection.append(shape)
	if new_selection == selection:
		return
	selection = new_selection
	_selection_updated(inspect)


func toggle_selected(shape: GeoShape) -> void:
	var new_selection := selection.duplicate()
	if new_selection.has(shape):
		new_selection.erase(shape)
	else:
		new_selection.append(shape)
	select(new_selection)


## The selected shapes, leaving out any whose ancestor is also selected (so
## moving the selection doesn't move those twice).
func top_level_selection() -> Array[GeoShape]:
	var result: Array[GeoShape] = []
	for shape in selection:
		var covered := false
		var parent := parent_of(shape)
		while parent and not covered:
			covered = selection.has(parent)
			parent = parent_of(parent)
		if not covered:
			result.append(shape)
	return result


func parent_of(shape: GeoShape) -> GeoShape:
	if not root or not shape:
		return null
	var model := root.get_compiled()
	var index := model.shapes.find(shape)
	if index < 0 or model.parents[index] < 0:
		return null
	return model.shapes[model.parents[index]]


## Whether ancestor is shape's parent, or its parent's parent, and so on.
func is_ancestor(ancestor: GeoShape, shape: GeoShape) -> bool:
	var parent := parent_of(shape)
	while parent:
		if parent == ancestor:
			return true
		parent = parent_of(parent)
	return false


## Applies changes, each [object, property, old value, new value], plus
## operations, each [do Callable, undo Callable, optional object to keep alive
## while undone], as one undo action. With execute false, the changes' new
## values must already be set (the operations still run).
##
## In animation mode, changes to shapes' fields go to the figure instead, and
## RESET gets keys for them.
func commit(action_name: String, changes: Array, execute: bool, operations := []) -> void:
	if animating:
		var entries := []
		changes = _retarget(changes, entries)
		animator.record_changes(entries)
		operations = operations + animator.reset_operations(entries)
	if changes.is_empty() and operations.is_empty():
		return
	var undo: EditorUndoRedoManager = plugin.get_undo_redo() if plugin else null
	if not undo:
		if execute:
			for change: Array in changes:
				change[0].set(change[1], change[3])
		for operation: Array in operations:
			operation[0].call()
	else:
		# Pose and animation changes (and setting up animation) belong to the
		# scene's history.
		var scene_action := figure != null and (animating or not operations.is_empty())
		undo.create_action(action_name, UndoRedo.MERGE_DISABLE, figure if scene_action else null)
		for change: Array in changes:
			undo.add_do_property(change[0], change[1], change[3])
			undo.add_undo_property(change[0], change[1], change[2])
		for operation: Array in operations:
			_add_method(undo, "add_do_method", operation[0])
			_add_method(undo, "add_undo_method", operation[1])
			if operation.size() > 2:
				undo.add_do_reference(operation[2])
		if not execute:
			for operation: Array in operations:
				operation[0].call()
		undo.commit_action(execute)
	if animating:
		_sync_pose()
		_update_animation_bar()


func _add_method(undo: EditorUndoRedoManager, method: StringName, callable: Callable) -> void:
	undo.callv(method, [callable.get_object(), callable.get_method()]
			+ callable.get_bound_arguments())


# Turns changes of shapes' fields into changes of the figure's overrides, and
# adds the changed axes to entries. Shapes' other properties can't change.
func _retarget(changes: Array, entries: Array) -> Array:
	var result := []
	for change: Array in changes:
		var shape := change[0] as GeoShape
		if not shape:
			result.append(change)
		elif not change[1] in Animator.FIELDS:
			_show_message("Only position, rotation, scale and visible can be animated.")
		elif not can_animate(shape):
			_show_message("Give '%s' a unique name to animate it." % shape.name if shape.name
					else "Name this shape to animate it.")
		else:
			result.append([figure, _shape_property(shape, change[1]), change[2], change[3]])
			entries.append_array(Animator.changed_entries(shape, change[1], change[2], change[3]))
	return result


## Sets property on several shapes (for multi-selection editing). For vectors,
## only the components that differ from previous are set.
func set_on_shapes(shapes: Array[GeoShape], property: StringName, value: Variant,
		previous: Variant) -> void:
	var changes := []
	for shape in shapes:
		var old_value: Variant = field_value(shape, property)
		var new_value: Variant = value
		if value is Vector3:
			new_value = old_value
			for axis in 3:
				if not is_equal_approx(value[axis], previous[axis]):
					new_value[axis] = value[axis]
		if new_value != old_value:
			changes.append([shape, property, old_value, new_value])
	commit("Set %s" % property, changes, true)


## Adds a shape of a type from GeoEditorMath.shape_types() under the selected
## shape (or the root), and selects it.
func add_shape(type: Dictionary) -> void:
	if not root or _blocked_while_animating():
		return
	var parent: GeoShape = selection[0] if not selection.is_empty() else root
	var shape: GeoShape = load(type["path"]).new()
	shape.name = _unique_name(String(type["name"]).to_snake_case(), _taken_names())
	var children := parent.children.duplicate()
	children.append(shape)
	commit("Add %s" % type["name"], [[parent, &"children", parent.children.duplicate(), children]],
			true)
	select([shape])


func delete_selection() -> void:
	if _blocked_while_animating():
		return
	var lists := {}
	for shape in top_level_selection():
		var parent := parent_of(shape)
		if not parent:
			continue # The root stays.
		if not lists.has(parent):
			lists[parent] = parent.children.duplicate()
		lists[parent].erase(shape)
	commit("Delete shapes", _children_changes(lists), true)
	select([])


## Duplicates the selected shapes (with their children) next to the originals.
func duplicate_selection() -> void:
	if _blocked_while_animating():
		return
	var taken := _taken_names()
	var lists := {}
	var copies: Array[GeoShape] = []
	for shape in top_level_selection():
		var parent := parent_of(shape)
		if not parent:
			continue
		if not lists.has(parent):
			lists[parent] = parent.children.duplicate()
		var copy: GeoShape = shape.duplicate_deep()
		_rename_unique(copy, taken)
		lists[parent].insert(lists[parent].find(shape) + 1, copy)
		copies.append(copy)
	commit("Duplicate shapes", _children_changes(lists), true)
	select(copies)


## Moves the selected shapes up (offset -1) or down (1) among their siblings.
func move_selection(offset: int) -> void:
	if _blocked_while_animating():
		return
	var lists := {}
	var shapes := top_level_selection()
	shapes.sort_custom(func(a: GeoShape, b: GeoShape) -> bool:
		var a_index := _index_in_parent(a)
		var b_index := _index_in_parent(b)
		return a_index < b_index if offset < 0 else a_index > b_index)
	for shape in shapes:
		var parent := parent_of(shape)
		if not parent:
			continue
		if not lists.has(parent):
			lists[parent] = parent.children.duplicate()
		var list: Array = lists[parent]
		var index := list.find(shape)
		var new_index := index + offset
		if new_index < 0 or new_index >= list.size() or selection.has(list[new_index]):
			continue
		list.remove_at(index)
		list.insert(new_index, shape)
	commit("Reorder shapes", _children_changes(lists), true)


## Moves shapes under new_parent, starting at index among its children. They
## keep their place on screen if reparent_keeps_place.
func reparent_shapes(shapes: Array, new_parent: GeoShape, index: int) -> void:
	if _blocked_while_animating():
		return
	var model := root.get_compiled()
	var xforms := M.model_transforms(model)
	var parent_xform := xforms[model.shapes.find(new_parent)]
	var lists := {}
	var changes := []
	for shape: GeoShape in shapes:
		var old_parent := parent_of(shape)
		if not old_parent or shape == new_parent or is_ancestor(shape, new_parent):
			continue
		if not lists.has(old_parent):
			lists[old_parent] = old_parent.children.duplicate()
		if not lists.has(new_parent):
			lists[new_parent] = new_parent.children.duplicate()
		var old_index: int = lists[old_parent].find(shape)
		lists[old_parent].remove_at(old_index)
		if old_parent == new_parent and old_index < index:
			index -= 1
		index = clampi(index, 0, lists[new_parent].size())
		lists[new_parent].insert(index, shape)
		index += 1
		if reparent_keeps_place and old_parent != new_parent:
			var local := parent_xform.affine_inverse() * xforms[model.shapes.find(shape)]
			var parts := M.decompose(local)
			for property: StringName in parts:
				if not shape.get(property).is_equal_approx(parts[property]):
					changes.append([shape, property, shape.get(property), parts[property]])
	commit("Reparent shapes", _children_changes(lists) + changes, true)


func _blocked_while_animating() -> bool:
	if animating:
		_show_message("Turn off Animate to change the figure's shapes.")
	return animating


func _children_changes(lists: Dictionary) -> Array:
	var changes := []
	for parent: GeoShape in lists:
		if lists[parent] != parent.children:
			changes.append([parent, &"children", parent.children.duplicate(), lists[parent]])
	return changes


func _index_in_parent(shape: GeoShape) -> int:
	var parent := parent_of(shape)
	return parent.children.find(shape) if parent else 0


func _taken_names() -> Dictionary:
	var taken := {}
	if root:
		for shape in root.get_compiled().shapes:
			taken[shape.name] = true
	return taken


func _unique_name(base: String, taken: Dictionary) -> StringName:
	var candidate := StringName(base)
	var n := 2
	while taken.has(candidate):
		candidate = StringName("%s_%d" % [base, n])
		n += 1
	taken[candidate] = true
	return candidate


func _rename_unique(shape: GeoShape, taken: Dictionary) -> void:
	if shape.name:
		shape.name = _unique_name(_name_suffix.sub(String(shape.name), ""), taken)
	for child in shape.children:
		if child:
			_rename_unique(child, taken)


func _on_root_changed() -> void:
	if _is_saved_to_file(root) and not _dirty_files.has(root):
		_dirty_files.append(root)
	if not _refresh_queued:
		_refresh_queued = true
		_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	_watch_library()
	if not root:
		shape_tree.rebuild()
		_update_status()
		return
	var model := root.get_compiled()
	var structure := []
	for i in model.shapes.size():
		structure.append(model.shapes[i])
		structure.append(model.parents[i])
	if structure != _structure:
		_structure = structure
		_pose_cache.clear()
		shape_tree.rebuild()
	else:
		shape_tree.update_items()
	var kept := selection.filter(func(shape: GeoShape) -> bool: return model.shapes.has(shape))
	if kept.size() != selection.size():
		select(kept)
	for view in views:
		view.invalidate()
	_update_status()


func _selection_updated(inspect := true) -> void:
	shape_tree.sync_selection()
	for view in views:
		view.queue_overlay()
	_update_status()
	if inspect and plugin:
		# In animation mode, even one shape is inspected through the proxy, which
		# poses the figure instead of changing the shape.
		if selection.size() == 1 and not animating:
			EditorInterface.inspect_object(selection[0], "", true)
		elif not selection.is_empty():
			_multi_edit.shapes = selection.duplicate()
			_multi_edit.notify_property_list_changed()
			EditorInterface.inspect_object(_multi_edit, "", true)
	selection_changed.emit()


func _update_status() -> void:
	var problems := PackedStringArray()
	if _message:
		problems.append(_message)
	if root:
		var model := root.get_compiled()
		problems.append_array(model.name_problems)
		if model.drawable_shapes.size() > GeoCompiledModel.MAX_DRAWABLE_SHAPES:
			problems.append("%d shapes have faces; pixel outlines support up to %d." % [
					model.drawable_shapes.size(), GeoCompiledModel.MAX_DRAWABLE_SHAPES])
	_status_label.text = "  ".join(problems)
	_status_label.tooltip_text = "\n".join(problems)

	var saved := _is_saved_to_file(root)
	var target := "No figure. Select a GeoFigure or open a GeoShape file."
	if root:
		target = root.resource_path.get_file() if saved else "%s (%s)" % [root.name,
				"in a scene" if root.resource_path else "unsaved"]
		if _dirty_files.has(root) or (root.animations and _dirty_files.has(root.animations)):
			target += " (*)"
		if selection.size() > 1:
			target = "%d selected   %s" % [selection.size(), target]
	_target_label.text = target
	_save_button.disabled = not plugin or _dirty_files.is_empty()
	_save_button.tooltip_text = "Save the figure's file and its animations (Ctrl+S also saves them)." \
			if saved else "Shapes inside a scene are saved with the scene."
	_new_button.disabled = not plugin
	_load_button.disabled = not plugin
	_save_as_button.disabled = not plugin or not root


## Saves edited figure files and animation libraries.
func save_changes() -> void:
	for resource in _dirty_files:
		if _is_saved_to_file(resource):
			var error := ResourceSaver.save(resource)
			if error != OK:
				push_error("Couldn't save %s: %s" % [resource.resource_path, error_string(error)])
			elif plugin:
				EditorInterface.get_resource_filesystem().update_file(resource.resource_path)
	_dirty_files.clear()
	_update_status()


func has_unsaved_changes() -> bool:
	return not _dirty_files.is_empty()


func _is_saved_to_file(resource: Resource) -> bool:
	return resource != null and resource.resource_path.begins_with("res://") \
			and not resource.resource_path.contains("::")


func _on_new_pressed() -> void:
	_popup_file_dialog("New GeoFigure Shapes", EditorFileDialog.FILE_MODE_SAVE_FILE,
			func(path: String) -> void:
				var figure_root := GeoGroup.new()
				figure_root.name = StringName(path.get_file().get_basename())
				if _save_as(figure_root, path):
					set_root(figure_root))


func _on_load_pressed() -> void:
	_popup_file_dialog("Load GeoFigure Shapes", EditorFileDialog.FILE_MODE_OPEN_FILE,
			func(path: String) -> void:
				var shape := load(path) as GeoShape
				if shape:
					set_root(shape)
				else:
					push_error("%s isn't a GeoShape file." % path))


# Saves a deep copy, so the original (and any figure using it) is unchanged. If
# the original has unsaved edits, they stay unsaved in it.
func _on_save_as_pressed() -> void:
	if not root:
		return
	_popup_file_dialog("Save GeoFigure Shapes As", EditorFileDialog.FILE_MODE_SAVE_FILE,
			func(path: String) -> void:
				var copy: GeoShape = root.duplicate_deep()
				if _save_as(copy, path):
					set_root(copy))


func _save_as(shape: GeoShape, path: String) -> bool:
	var error := ResourceSaver.save(shape, path)
	if error != OK:
		push_error("Couldn't save %s: %s" % [path, error_string(error)])
		return false
	# Taking over the path (rather than FLAG_CHANGE_PATH) also works when the
	# file is already loaded.
	shape.take_over_path(path)
	EditorInterface.get_resource_filesystem().update_file(path)
	return true


func _popup_file_dialog(title: String, file_mode: EditorFileDialog.FileMode,
		on_selected: Callable) -> void:
	var dialog := EditorFileDialog.new()
	dialog.file_mode = file_mode
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.title = title
	dialog.add_filter("*.tres, *.res", "GeoShape")
	if root and _is_saved_to_file(root):
		dialog.current_dir = root.resource_path.get_base_dir()
	dialog.file_selected.connect(on_selected)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered_ratio(0.6)
