@tool
extends VBoxContainer
## The GeoFigure main screen: the edited figure's shapes as a tree, three axis
## views (front, side and top) and an orbiting 3D view, sharing one selection.
##
## Edits go through the editor's undo history. Without a plugin (e.g. when
## run as a test), they apply directly and nothing is saved.

signal selection_changed

const M := preload("res://addons/geo_figure_editor/geo_editor_math.gd")
const View := preload("res://addons/geo_figure_editor/geo_editor_view.gd")
const ShapeTree := preload("res://addons/geo_figure_editor/geo_shape_tree.gd")
const MultiEdit := preload("res://addons/geo_figure_editor/geo_shape_multi_edit.gd")

enum Mode { MOVE, ROTATE, SCALE }

const _SETTING_SNAP := "geo_figure_editor/snap_enabled"
const _SETTING_SNAP_STEP := "geo_figure_editor/snap_step"
const _SETTING_KEEP_PLACE := "geo_figure_editor/reparent_keeps_place"
const _SETTING_PIXEL_SIZE := "geo_figure_editor/pixel_size"

## The plugin, when running in the editor.
var plugin: EditorPlugin
## The root of the shape tree being edited.
var root: GeoShape
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
var _dirty_roots: Array[GeoShape] = []
var _name_suffix := RegEx.create_from_string("_\\d+$")


func _init() -> void:
	name = &"GeoFigureEditor"
	size_flags_vertical = SIZE_EXPAND_FILL
	_multi_edit.editor = self
	_build_toolbar()
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
		["Front", 0.0, Vector3.ZERO, false, false],
		["Side", 0.0, Vector3(0.0, -90.0, 0.0), false, false],
		["Top", 90.0, Vector3.ZERO, false, false],
		["3D", GeoCamera.DEFAULT_ELEVATION_DEGREES, Vector3(0.0, -45.0, 0.0), true, true],
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
	_pixel_size_spin.tooltip_text = ("The size of each art pixel in the pixelated views, in the figure's units"
			+ " (like GeoCamera.pixel_size). Only affects this editor's views.")
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


## Loads the toolbar settings from the editor settings. The plugin calls this
## after setting plugin.
func load_settings() -> void:
	if not plugin:
		return
	var settings := EditorInterface.get_editor_settings()
	for entry: Array in [[_SETTING_SNAP, snap_enabled], [_SETTING_SNAP_STEP, snap_step],
			[_SETTING_KEEP_PLACE, reparent_keeps_place], [_SETTING_PIXEL_SIZE, pixel_size]]:
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
	set_pixel_size(saved_pixel_size)


func _save_setting(key: String, value: Variant) -> void:
	if plugin:
		EditorInterface.get_editor_settings().set_setting(key, value)


## Edits the shape tree rooted at shape.
func set_root(shape: GeoShape) -> void:
	if shape == root:
		return
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


## Applies changes, each [object, property, old value, new value], as one undo
## action. With execute false, the new values must already be set.
func commit(action_name: String, changes: Array, execute: bool) -> void:
	if changes.is_empty():
		return
	var undo: EditorUndoRedoManager = plugin.get_undo_redo() if plugin else null
	if not undo:
		if execute:
			for change: Array in changes:
				change[0].set(change[1], change[3])
		return
	undo.create_action(action_name)
	for change: Array in changes:
		undo.add_do_property(change[0], change[1], change[3])
		undo.add_undo_property(change[0], change[1], change[2])
	undo.commit_action(execute)


## Sets property on several shapes (for multi-selection editing). For vectors,
## only the components that differ from previous are set.
func set_on_shapes(shapes: Array[GeoShape], property: StringName, value: Variant,
		previous: Variant) -> void:
	var changes := []
	for shape in shapes:
		var old_value: Variant = shape.get(property)
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
	if not root:
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
	if _is_saved_to_file(root) and not _dirty_roots.has(root):
		_dirty_roots.append(root)
	if not _refresh_queued:
		_refresh_queued = true
		_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
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
		if selection.size() == 1:
			EditorInterface.inspect_object(selection[0], "", true)
		elif selection.size() > 1:
			_multi_edit.shapes = selection.duplicate()
			_multi_edit.notify_property_list_changed()
			EditorInterface.inspect_object(_multi_edit, "", true)
	selection_changed.emit()


func _update_status() -> void:
	var problems := PackedStringArray()
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
		if _dirty_roots.has(root):
			target += " (*)"
		if selection.size() > 1:
			target = "%d selected   %s" % [selection.size(), target]
	_target_label.text = target
	_save_button.disabled = not plugin or _dirty_roots.is_empty()
	_save_button.tooltip_text = "Save the figure's file (Ctrl+S also saves it)." if saved \
			else "Shapes inside a scene are saved with the scene."
	_new_button.disabled = not plugin
	_load_button.disabled = not plugin
	_save_as_button.disabled = not plugin or not root


## Saves edited figure files.
func save_changes() -> void:
	for shape in _dirty_roots:
		if _is_saved_to_file(shape):
			var error := ResourceSaver.save(shape)
			if error != OK:
				push_error("Couldn't save %s: %s" % [shape.resource_path, error_string(error)])
			elif plugin:
				EditorInterface.get_resource_filesystem().update_file(shape.resource_path)
	_dirty_roots.clear()
	_update_status()


func has_unsaved_changes() -> bool:
	return not _dirty_roots.is_empty()


func _is_saved_to_file(shape: GeoShape) -> bool:
	return shape != null and shape.resource_path.begins_with("res://") \
			and not shape.resource_path.contains("::")


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
