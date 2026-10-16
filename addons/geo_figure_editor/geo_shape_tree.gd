@tool
extends VBoxContainer
## The edited figure's shapes as a tree, with buttons to add, duplicate,
## delete and reorder them. Rows toggle visible and glued, rename on
## double-click (or F2), and drag onto another row to reparent.

const M := preload("res://addons/geo_figure_editor/geo_editor_math.gd")

const _BUTTON_VISIBLE := 0
const _BUTTON_GLUED := 1
const _TYPE_ICONS := {
	&"GeoBox": &"BoxMesh",
	&"GeoCylinder": &"CylinderMesh",
	&"GeoDisc": &"CircleShape2D",
	&"GeoGroup": &"Node3D",
	&"GeoLine": &"Path3D",
	&"GeoPanel": &"PlaneMesh",
	&"GeoSphere": &"SphereMesh",
	&"GeoTriangle": &"PrismMesh",
}

## The GeoFigure editor (geo_figure_editor.gd).
var editor: Object
var tree := Tree.new()

var _add_menu := MenuButton.new()
var _items: Dictionary[GeoShape, TreeItem] = {}
var _types: Array[Dictionary] = []
var _updating := false
var _placeholder_icon: Texture2D
var _class_icons: Dictionary[StringName, Texture2D] = {}


func _init() -> void:
	var bar := HBoxContainer.new()
	add_child(bar)
	_add_menu.text = "Add"
	_add_menu.flat = false
	_add_menu.tooltip_text = "Add a shape under the selected shape."
	_add_menu.about_to_popup.connect(_fill_add_menu)
	_add_menu.get_popup().id_pressed.connect(_on_add_pressed)
	bar.add_child(_add_menu)
	_add_button(bar, "Duplicate", "Duplicate the selected shapes (Ctrl+D).",
			func() -> void: editor.duplicate_selection())
	_add_button(bar, "Delete", "Delete the selected shapes (Delete).",
			func() -> void: editor.delete_selection())
	_add_button(bar, "↑", "Move the selected shapes up among their siblings.",
			func() -> void: editor.move_selection(-1))
	_add_button(bar, "↓", "Move the selected shapes down among their siblings.",
			func() -> void: editor.move_selection(1))

	tree.size_flags_vertical = SIZE_EXPAND_FILL
	tree.select_mode = Tree.SELECT_MULTI
	tree.drop_mode_flags = Tree.DROP_MODE_ON_ITEM | Tree.DROP_MODE_INBETWEEN
	tree.multi_selected.connect(_on_multi_selected)
	tree.button_clicked.connect(_on_button_clicked)
	tree.item_activated.connect(_start_rename)
	tree.item_edited.connect(_on_item_edited)
	tree.gui_input.connect(_on_tree_input)
	tree.set_drag_forwarding(_get_drag_data_fw, _can_drop_data_fw, _drop_data_fw)
	add_child(tree)


## Recreates the rows from the edited tree (after shapes were added, removed or
## moved).
func rebuild() -> void:
	_updating = true
	var collapsed := {}
	for shape in _items:
		if _items[shape].collapsed:
			collapsed[shape] = true
	tree.clear()
	_items.clear()
	if editor.root:
		var model: GeoCompiledModel = editor.root.get_compiled()
		var items: Array[TreeItem] = []
		for i in model.shapes.size():
			var shape := model.shapes[i]
			var parent := model.parents[i]
			var item := tree.create_item(null if parent < 0 else items[parent])
			items.append(item)
			item.set_metadata(0, shape)
			item.collapsed = collapsed.has(shape)
			_items[shape] = item
			_update_item(item, shape)
	_updating = false
	sync_selection()


## Refreshes the rows' names and toggles (after shapes were edited).
func update_items() -> void:
	for shape in _items:
		_update_item(_items[shape], shape)


## Selects the rows of the editor's selected shapes.
func sync_selection() -> void:
	_updating = true
	tree.deselect_all()
	var last: TreeItem = null
	for shape: GeoShape in editor.selection:
		var item: TreeItem = _items.get(shape)
		if not item:
			continue
		var parent := item.get_parent()
		while parent:
			parent.collapsed = false
			parent = parent.get_parent()
		item.select(0)
		last = item
	if last:
		tree.scroll_to_item(last)
	_updating = false


func _update_item(item: TreeItem, shape: GeoShape) -> void:
	var type_name := _class_name(shape)
	item.set_text(0, String(shape.name) if shape.name else "(%s)" % type_name.trim_prefix("Geo"))
	item.set_tooltip_text(0, "%s (%s)" % [shape.name, type_name])
	item.set_icon(0, _type_icon(type_name))
	item.set_custom_color(0, Color(1.0, 1.0, 1.0, 1.0 if shape.visible else 0.45))
	if item.get_button_count(0) == 0:
		item.add_button(0, _icon(&"GuiVisibilityVisible"), _BUTTON_VISIBLE)
		item.add_button(0, _icon(&"Pin"), _BUTTON_GLUED)
	item.set_button(0, _BUTTON_VISIBLE, _icon(
			&"GuiVisibilityVisible" if shape.visible else &"GuiVisibilityHidden"))
	item.set_button_tooltip_text(0, _BUTTON_VISIBLE,
			"Visible. Click to hide." if shape.visible else "Hidden. Click to show.")
	item.set_button_color(0, _BUTTON_GLUED, Color(1.0, 1.0, 1.0, 1.0 if shape.glued else 0.25))
	item.set_button_tooltip_text(0, _BUTTON_GLUED,
			"Glued to its parent when the figure explodes. Click to unglue." if shape.glued
			else "Breaks off when the figure explodes. Click to glue to its parent.")


func _class_name(shape: GeoShape) -> String:
	var script: Script = shape.get_script()
	return String(script.get_global_name()) if script else "GeoShape"


# A shape type's icon: an editor icon for the built-in shapes, the class's
# @icon for custom shapes that have one, else a generic shape icon.
func _type_icon(type_name: StringName) -> Texture2D:
	if _TYPE_ICONS.has(type_name):
		return _icon(_TYPE_ICONS[type_name])
	if not _class_icons.has(type_name):
		var icon: Texture2D = null
		for info in ProjectSettings.get_global_class_list():
			if info["class"] == type_name and info.get("icon", "") != "":
				icon = _load_class_icon(info["icon"])
		_class_icons[type_name] = icon
	return _class_icons[type_name] if _class_icons[type_name] else _icon(&"Shape3D")


# Loads an @icon at the size of the editor's icons (16 pixels times the editor
# scale), like the editor does for custom classes. SVGs are redrawn at that size
# so they stay sharp.
func _load_class_icon(path: String) -> Texture2D:
	var texture := load(path) as Texture2D
	if not texture or texture.get_width() <= 0:
		return null
	var target := roundi(16.0 * (EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0))
	if texture.get_width() == target and texture.get_height() == target:
		return texture
	var image: Image
	if path.get_extension().to_lower() == "svg":
		image = Image.new()
		if image.load_svg_from_string(FileAccess.get_file_as_string(path),
				float(target) / maxi(texture.get_width(), texture.get_height())) != OK:
			image = null
	if not image:
		image = texture.get_image()
		if image.is_compressed():
			image.decompress()
		var ratio := float(target) / maxi(image.get_width(), image.get_height())
		image.resize(maxi(roundi(image.get_width() * ratio), 1),
				maxi(roundi(image.get_height() * ratio), 1), Image.INTERPOLATE_LANCZOS)
	return ImageTexture.create_from_image(image)


func _icon(icon_name: StringName) -> Texture2D:
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme.has_icon(icon_name, &"EditorIcons"):
			return theme.get_icon(icon_name, &"EditorIcons")
	if not _placeholder_icon:
		var image := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.7, 0.7, 0.7))
		_placeholder_icon = ImageTexture.create_from_image(image)
	return _placeholder_icon


func _add_button(bar: HBoxContainer, text: String, tooltip: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(action)
	bar.add_child(button)


func _fill_add_menu() -> void:
	var popup := _add_menu.get_popup()
	popup.clear()
	_types = M.shape_types()
	for i in _types.size():
		popup.add_icon_item(_type_icon(_types[i]["class"]),
				_types[i]["name"], i)


func _on_add_pressed(id: int) -> void:
	editor.add_shape(_types[id])


func _on_multi_selected(_item: TreeItem, _column: int, _selected: bool) -> void:
	if not _updating:
		_sync_to_editor.call_deferred()


func _sync_to_editor() -> void:
	if _updating:
		return
	var shapes: Array[GeoShape] = []
	var item := tree.get_next_selected(null)
	while item:
		shapes.append(item.get_metadata(0))
		item = tree.get_next_selected(item)
	editor.select(shapes)


func _on_button_clicked(item: TreeItem, _column: int, id: int, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_LEFT:
		return
	var shape: GeoShape = item.get_metadata(0)
	var property := &"visible" if id == _BUTTON_VISIBLE else &"glued"
	var value: bool = shape.get(property)
	editor.commit("Toggle %s" % property, [[shape, property, value, not value]], true)


func _start_rename() -> void:
	var item := tree.get_selected()
	if not item:
		return
	var shape: GeoShape = item.get_metadata(0)
	item.set_text(0, shape.name)
	item.set_editable(0, true)
	tree.edit_selected(true)


func _on_item_edited() -> void:
	var item := tree.get_edited()
	if not item:
		return
	item.set_editable(0, false)
	var shape: GeoShape = item.get_metadata(0)
	var new_name := StringName(item.get_text(0).strip_edges())
	if new_name != shape.name:
		editor.commit("Rename shape", [[shape, &"name", shape.name, new_name]], true)
	else:
		_update_item(item, shape)


func _on_tree_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if not key or not key.pressed or key.echo:
		return
	if key.keycode == KEY_DELETE:
		editor.delete_selection()
	elif key.keycode == KEY_D and key.is_command_or_control_pressed():
		editor.duplicate_selection()
	elif key.keycode == KEY_F2:
		_start_rename()
	else:
		return
	tree.accept_event()


func _get_drag_data_fw(_at_position: Vector2) -> Variant:
	var shapes: Array[GeoShape] = []
	for shape: GeoShape in editor.top_level_selection():
		if shape != editor.root:
			shapes.append(shape)
	if shapes.is_empty():
		return null
	var preview := Label.new()
	preview.text = ", ".join(shapes.map(func(s: GeoShape) -> String: return String(s.name)))
	tree.set_drag_preview(preview)
	return {"type": "geo_shapes", "shapes": shapes}


func _can_drop_data_fw(at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.get("type") == "geo_shapes" \
			and not _drop_target(at_position, data.shapes).is_empty()


func _drop_data_fw(at_position: Vector2, data: Variant) -> void:
	var target := _drop_target(at_position, data.shapes)
	if not target.is_empty():
		editor.reparent_shapes(data.shapes, target[0], target[1])


# Returns [new parent, index among its children] for dropping shapes at
# at_position, or [] if they can't go there.
func _drop_target(at_position: Vector2, shapes: Array) -> Array:
	var item := tree.get_item_at_position(at_position)
	if not item:
		return []
	var target: GeoShape = item.get_metadata(0)
	var section := tree.get_drop_section_at_position(at_position)
	var parent: GeoShape
	var index: int
	if section == 0:
		parent = target
		index = target.children.size()
	else:
		parent = editor.parent_of(target)
		if not parent:
			return [] # Nothing goes beside the root.
		index = parent.children.find(target) + (1 if section > 0 else 0)
	for shape: GeoShape in shapes:
		if shape == parent or editor.is_ancestor(shape, parent):
			return []
	return [parent, index]
