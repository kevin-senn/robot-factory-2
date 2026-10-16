@tool
extends Control
## One view of the figure being edited: a GeoFigure with its own camera, plus
## an overlay for outlines and selection.
##
## Axis views (orbit false): click or box-select shapes, drag them to move,
## rotate or scale (the editor's mode) in the view's plane, and nudge them with
## the arrow keys. The orbit view: drag to turn the model (left and right) and
## change the camera elevation (up and down); click to select.
## In both: the wheel zooms, middle-drag pans and F frames the figure.

const M := preload("res://addons/geo_figure_editor/geo_editor_math.gd")
const _SMOOTH_SHADER := preload("res://addons/geo_render/geo_shading_example.gdshader")

const _MIN_DRAG_PIXELS := 3.0
const _HIT_TOLERANCE_PIXELS := 3.0
const _ORBIT_DEGREES_PER_PIXEL := 0.5
const _ROTATE_SNAP_DEGREES := 15.0
const _SCALE_SNAP := 0.05
const _MIN_ZOOM := 0.25
const _MAX_ZOOM := 64.0
const _FRAME_MARGIN_PIXELS := 16.0
const _FRAME_MARGIN_FRACTION := 0.1
const _HEADER_PIXELS := 24.0
const _BACKGROUND := Color(0.15, 0.16, 0.19)
const _AXIS_COLORS: Array[Color] = [Color(0.96, 0.33, 0.37), Color(0.53, 0.84, 0.01),
		Color(0.16, 0.55, 0.96)]
const _AXIS_NAMES: Array[String] = ["X", "Y", "Z"]
const _SELECTED_COLOR := Color(1.0, 0.62, 0.16)
const _HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.55)

enum Drag { NONE, TRANSFORM, BOX, ORBIT, PAN }

# The editor's modes (geo_figure_editor.gd's Mode).
const _MOVE := 0
const _ROTATE := 1
const _SCALE := 2

## The GeoFigure editor (geo_figure_editor.gd).
var editor: Object
var orbit := false
var elevation := 0.0
var model_rotation_degrees := Vector3.ZERO
var zoom := 3.0
## Offset of the model's origin from the view's center, in pixels.
var pan := Vector2.ZERO
var figure := GeoFigure.new()

var _camera := GeoCamera.new()
var _overlay := Control.new()
var _title := Label.new()
var _pixel_check := CheckBox.new()
var _smooth_material := ShaderMaterial.new()
var _pixel_material: ShaderMaterial
var _default_elevation := 0.0
var _default_rotation := Vector3.ZERO
var _needs_frame := true

# Per shape (indices into the compiled model), in view units. Rebuilt when the
# shapes or the view's rotation change.
var _cache_valid := false
var _model: GeoCompiledModel
var _model_xforms: Array[Transform3D] = []
var _hulls: Array[PackedVector2Array] = []
var _depths := PackedFloat32Array()
var _origins := PackedVector2Array()
var _hidden := PackedByteArray()
var _hover: GeoShape

var _drag := Drag.NONE
var _drag_active := false # Moved far enough to count as a drag.
var _press_position := Vector2.ZERO
var _drag_position := Vector2.ZERO
var _press_shape: GeoShape
var _press_toggles := false
var _drag_targets: Array[GeoShape] = []
var _drag_starts: Array[Dictionary] = []
var _drag_parent_xforms: Array[Transform3D] = []
var _drag_pivot := Vector2.ZERO
var _orbit_start := Vector2.ZERO


func setup(owner_editor: Object, title: String, view_elevation: float,
		view_rotation: Vector3, is_orbit: bool, pixelated: bool) -> void:
	editor = owner_editor
	orbit = is_orbit
	elevation = view_elevation
	model_rotation_degrees = view_rotation
	_default_elevation = view_elevation
	_default_rotation = view_rotation
	name = title
	clip_contents = true
	focus_mode = FOCUS_ALL
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(160, 120)

	_smooth_material.shader = _SMOOTH_SHADER
	_pixel_material = figure.pixel_material
	figure.camera = _camera
	add_child(figure)
	_overlay.mouse_filter = MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	var header := HBoxContainer.new()
	header.mouse_filter = MOUSE_FILTER_IGNORE
	header.position = Vector2(6, 2)
	add_child(header)
	_title.mouse_filter = MOUSE_FILTER_IGNORE
	_title.add_theme_color_override(&"font_color", Color(1.0, 1.0, 1.0, 0.7))
	header.add_child(_title)
	_pixel_check.text = "Pixels"
	_pixel_check.focus_mode = FOCUS_NONE
	_pixel_check.tooltip_text = "Draw the figure pixelated, as in the game."
	_pixel_check.toggled.connect(set_pixelated)
	header.add_child(_pixel_check)
	if orbit:
		var reset := Button.new()
		reset.text = "Reset"
		reset.flat = true
		reset.focus_mode = FOCUS_NONE
		reset.tooltip_text = "Return to the default angle."
		reset.pressed.connect(func() -> void:
			set_angle(_default_elevation, _default_rotation))
		header.add_child(reset)
	_title.text = title
	_pixel_check.set_pressed_no_signal(pixelated)
	set_pixelated(pixelated)
	set_angle(view_elevation, view_rotation)
	resized.connect(_layout_figure)
	mouse_entered.connect(_on_mouse_entered)


func set_shape(shape: GeoShape) -> void:
	figure.shape = shape
	_hover = null
	_needs_frame = true
	invalidate()
	_layout_figure()


func set_pixelated(on: bool) -> void:
	# Order matters: GeoFigure applies its material when it redraws, and
	# CanvasItem.material applies right away.
	if on:
		figure.material = null
		figure.pixel_material = _pixel_material
	else:
		figure.pixel_material = null
		figure.material = _smooth_material
	_pixel_check.set_pressed_no_signal(on)


## The size of each art pixel when pixelated, in the figure's units.
func set_pixel_size(value: float) -> void:
	_camera.pixel_size = value


func is_pixelated() -> bool:
	return figure.pixel_material != null


func set_angle(new_elevation: float, new_rotation: Vector3) -> void:
	elevation = new_elevation
	model_rotation_degrees = new_rotation
	_camera.elevation_degrees = elevation
	figure.model_rotation_degrees = model_rotation_degrees
	if orbit:
		_title.text = "3D  (%d°, %d°)" % [roundi(model_rotation_degrees.y), roundi(elevation)]
	invalidate()


# Like the 2D editor, take keyboard focus when the mouse comes in, so the arrow
# keys move the selection here. Not while text is being typed elsewhere (e.g.
# renaming a shape in the tree, or a field in the Inspector).
func _on_mouse_entered() -> void:
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return
	grab_focus()


## Call when the shapes change.
func invalidate() -> void:
	_cache_valid = false
	queue_redraw()
	_overlay.queue_redraw()


func queue_overlay() -> void:
	_overlay.queue_redraw()


func get_view_basis() -> Basis:
	return M.view_basis(elevation, model_rotation_degrees)


## Zooms and pans to fit the figure.
func frame() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		_needs_frame = true
		return
	_needs_frame = false
	_ensure_cache()
	var bounds := Rect2()
	var found := false
	for i in _hulls.size():
		if _hidden[i] == 1:
			continue
		for p in _hulls[i]:
			bounds = bounds.expand(p) if found else Rect2(p, Vector2.ZERO)
			found = true
	if not found or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		zoom = 3.0
		pan = Vector2.ZERO
	else:
		# Leave a margin around the figure (and room for the header).
		var margin := maxf(_FRAME_MARGIN_PIXELS, minf(size.x, size.y) * _FRAME_MARGIN_FRACTION)
		var available := (size - Vector2(margin, margin + _HEADER_PIXELS / 2.0) * 2.0).max(Vector2.ONE)
		zoom = clampf(minf(available.x / bounds.size.x, available.y / bounds.size.y),
				_MIN_ZOOM, _MAX_ZOOM)
		pan = -bounds.get_center() * zoom + Vector2(0.0, _HEADER_PIXELS / 2.0)
	_layout_figure()


func _layout_figure() -> void:
	if _needs_frame and size.x > 0.0 and size.y > 0.0 and editor and editor.root:
		frame()
		return
	figure.position = _origin()
	figure.scale = Vector2.ONE * zoom
	queue_redraw()
	_overlay.queue_redraw()


func _origin() -> Vector2:
	return size / 2.0 + pan


func _to_units(screen: Vector2) -> Vector2:
	return (screen - _origin()) / zoom


func _to_screen(units: Vector2) -> Vector2:
	return _origin() + units * zoom


func _ensure_cache() -> void:
	if _cache_valid:
		return
	_cache_valid = true
	_hulls.clear()
	_depths.clear()
	_origins.clear()
	_model = editor.root.get_compiled() if editor and editor.root else null
	if not _model:
		_model_xforms.clear()
		_hidden.clear()
		return
	_model_xforms = M.model_transforms(_model)
	_hidden = M.hidden_flags(_model)
	var view := Transform3D(get_view_basis(), Vector3.ZERO)
	var count := _model.shapes.size()
	_hulls.resize(count)
	_depths.resize(count)
	_origins.resize(count)
	for i in count:
		var xform := view * _model_xforms[i]
		var geometry := _model.geometries[i]
		if geometry.face_count() > 0:
			_hulls[i] = M.project_hull(geometry.positions, xform)
		_depths[i] = (xform * geometry.sort_point).z + _model.depth_biases[i]
		_origins[i] = Vector2(xform.origin.x, xform.origin.y)


func _index_of(shape: GeoShape) -> int:
	return _model.shapes.find(shape) if _model and shape else -1


## The front-most visible shape under a point, or null.
func pick(screen_position: Vector2) -> GeoShape:
	_ensure_cache()
	if not _model:
		return null
	var point := _to_units(screen_position)
	var tolerance := _HIT_TOLERANCE_PIXELS / zoom
	var best := -1
	for i in _hulls.size():
		if _hidden[i] == 1 or _hulls[i].is_empty():
			continue
		if (best < 0 or _depths[i] >= _depths[best]) \
				and M.hull_contains(_hulls[i], point, tolerance):
			best = i
	return _model.shapes[best] if best >= 0 else null


## The visible shapes with any part inside a rectangle (in pixels).
func shapes_in_rect(screen_rect: Rect2) -> Array[GeoShape]:
	_ensure_cache()
	var result: Array[GeoShape] = []
	if not _model:
		return result
	var rect := Rect2(_to_units(screen_rect.position), screen_rect.size / zoom)
	for i in _hulls.size():
		if _hidden[i] == 0 and not _hulls[i].is_empty() \
				and M.hull_overlaps_rect(_hulls[i], rect):
			result.append(_model.shapes[i])
	return result


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventKey and event.pressed:
		_on_key(event)


func _on_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				var steps := event.factor if event.factor > 0.0 else 1.0
				var factor := pow(1.15, steps)
				_zoom_at(event.position,
						factor if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / factor)
		MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_cancel_drag()
				_drag = Drag.PAN
			elif _drag == Drag.PAN:
				_drag = Drag.NONE
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_cancel_drag()
		MOUSE_BUTTON_LEFT:
			if event.pressed:
				grab_focus()
				_press(event)
			else:
				_release()
		_:
			return
	accept_event()


func _press(event: InputEventMouseButton) -> void:
	_press_position = event.position
	_drag_position = event.position
	_drag_active = false
	if not editor.root:
		return
	_press_shape = pick(event.position)
	_press_toggles = event.shift_pressed or event.is_command_or_control_pressed()
	if orbit:
		_drag = Drag.ORBIT
		_orbit_start = Vector2(model_rotation_degrees.y, elevation)
	elif not _press_shape:
		_drag = Drag.BOX
	elif _press_toggles:
		editor.toggle_selected(_press_shape)
	else:
		if not editor.selection.has(_press_shape):
			editor.select([_press_shape])
		_begin_transform(_press_shape)


func _release() -> void:
	match _drag:
		Drag.TRANSFORM:
			if _drag_active:
				_commit_transform()
			elif editor.selection.size() > 1:
				editor.select([_press_shape]) # A click (not a drag) picks one shape.
		Drag.BOX:
			if _drag_active:
				var shapes: Array = shapes_in_rect(
						Rect2(_press_position, Vector2.ZERO).expand(_drag_position))
				if _press_toggles:
					shapes = editor.selection + shapes
				editor.select(shapes)
			elif not _press_toggles:
				editor.select([])
		Drag.ORBIT:
			if not _drag_active:
				if not _press_shape:
					if not _press_toggles:
						editor.select([])
				elif _press_toggles:
					editor.toggle_selected(_press_shape)
				else:
					editor.select([_press_shape])
	_drag = Drag.NONE
	_overlay.queue_redraw()


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	match _drag:
		Drag.PAN:
			pan += event.relative
			_layout_figure()
			return
		Drag.NONE:
			var hover := pick(event.position) if editor.root else null
			if hover != _hover:
				_hover = hover
				_overlay.queue_redraw()
			return
	_drag_position = event.position
	if not _drag_active and event.position.distance_to(_press_position) >= _MIN_DRAG_PIXELS:
		_drag_active = true
	if not _drag_active:
		return
	match _drag:
		Drag.TRANSFORM:
			_apply_transform(event)
		Drag.BOX:
			_overlay.queue_redraw()
		Drag.ORBIT:
			var moved := event.position - _press_position
			set_angle(clampf(_orbit_start.y + moved.y * _ORBIT_DEGREES_PER_PIXEL, -90.0, 90.0),
					Vector3(model_rotation_degrees.x,
					wrapf(_orbit_start.x + moved.x * _ORBIT_DEGREES_PER_PIXEL, -180.0, 180.0),
					model_rotation_degrees.z))


func _on_key(event: InputEventKey) -> void:
	var step: float = editor.snap_step * (10.0 if event.shift_pressed else 1.0)
	var plain := not event.is_command_or_control_pressed() and not event.alt_pressed
	match event.keycode:
		KEY_LEFT:
			_nudge(Vector2.LEFT * step)
		KEY_RIGHT:
			_nudge(Vector2.RIGHT * step)
		KEY_UP:
			_nudge(Vector2.UP * step)
		KEY_DOWN:
			_nudge(Vector2.DOWN * step)
		KEY_W when plain:
			editor.set_mode(_MOVE)
		KEY_E when plain:
			editor.set_mode(_ROTATE)
		KEY_R when plain:
			editor.set_mode(_SCALE)
		KEY_F when plain:
			frame()
		KEY_DELETE:
			editor.delete_selection()
		KEY_D when event.is_command_or_control_pressed():
			editor.duplicate_selection()
		KEY_ESCAPE:
			_cancel_drag()
		_:
			return
	accept_event()


func _zoom_at(screen_position: Vector2, factor: float) -> void:
	var units := _to_units(screen_position)
	zoom = clampf(zoom * factor, _MIN_ZOOM, _MAX_ZOOM)
	pan = screen_position - size / 2.0 - units * zoom
	_layout_figure()


func _begin_transform(grabbed: GeoShape) -> void:
	_ensure_cache()
	_drag = Drag.TRANSFORM
	_drag_targets = editor.top_level_selection()
	_drag_starts.clear()
	_drag_parent_xforms.clear()
	for shape in _drag_targets:
		_drag_starts.append({&"position": shape.position,
				&"rotation_degrees": shape.rotation_degrees, &"scale": shape.scale})
		_drag_parent_xforms.append(_parent_xform(shape))
	_drag_pivot = _to_screen(_origins[_index_of(grabbed)])


func _parent_xform(shape: GeoShape) -> Transform3D:
	var parent_index := _index_of(editor.parent_of(shape))
	return _model_xforms[parent_index] if parent_index >= 0 else Transform3D.IDENTITY


func _apply_transform(event: InputEventMouseMotion) -> void:
	var snap: bool = editor.snap_enabled and not event.is_command_or_control_pressed()
	var view := get_view_basis()
	match editor.mode:
		_MOVE:
			var moved := (event.position - _press_position) / zoom
			if snap:
				moved = moved.snapped(Vector2.ONE * editor.snap_step)
			var model_moved := view.inverse() * Vector3(moved.x, moved.y, 0.0)
			for i in _drag_targets.size():
				_drag_targets[i].position = M.tidy(_drag_starts[i][&"position"]
						+ _drag_parent_xforms[i].basis.inverse() * model_moved)
		_ROTATE:
			var angle := wrapf((event.position - _drag_pivot).angle()
					- (_press_position - _drag_pivot).angle(), -PI, PI)
			if snap:
				angle = snappedf(angle, deg_to_rad(_ROTATE_SNAP_DEGREES))
			# Clockwise on screen is a positive turn about the axis toward the
			# camera (since y points down).
			var axis := view.inverse() * Vector3.BACK
			for i in _drag_targets.size():
				_drag_targets[i].rotation_degrees = M.rotate_about_axis(
						_drag_starts[i][&"rotation_degrees"], _drag_parent_xforms[i].basis, axis, angle)
		_SCALE:
			var from := _press_position - _drag_pivot
			var to := event.position - _drag_pivot
			for i in _drag_targets.size():
				var start: Vector3 = _drag_starts[i][&"scale"]
				var new_scale := start
				if event.shift_pressed:
					new_scale = start * (to.length() / maxf(from.length(), 1.0))
				else:
					# Scale the shape's own axes that point most along the
					# screen's x and y.
					var axes := view * _drag_parent_xforms[i].basis.orthonormalized() \
							* Basis.from_euler(M.to_radians(_drag_starts[i][&"rotation_degrees"]))
					var x_axis := _most_aligned_axis(axes, 0, -1)
					var y_axis := _most_aligned_axis(axes, 1, x_axis)
					if absf(from.x) > 4.0:
						new_scale[x_axis] = start[x_axis] * to.x / from.x
					if absf(from.y) > 4.0:
						new_scale[y_axis] = start[y_axis] * to.y / from.y
				if snap:
					new_scale = new_scale.snapped(Vector3.ONE * _SCALE_SNAP)
				_drag_targets[i].scale = M.tidy(new_scale.max(Vector3.ZERO))


# The axis (column) of basis whose direction has the largest screen_component.
func _most_aligned_axis(basis: Basis, screen_component: int, exclude: int) -> int:
	var best := -1
	for axis in 3:
		if axis != exclude and (best < 0
				or absf(basis[axis][screen_component]) > absf(basis[best][screen_component])):
			best = axis
	return best


func _commit_transform() -> void:
	var changes := []
	for i in _drag_targets.size():
		for property: StringName in _drag_starts[i]:
			var old_value: Vector3 = _drag_starts[i][property]
			var new_value: Vector3 = _drag_targets[i].get(property)
			if old_value != new_value:
				changes.append([_drag_targets[i], property, old_value, new_value])
	var action: String = ["Move", "Rotate", "Scale"][editor.mode]
	editor.commit("%s shapes" % action, changes, false)


func _cancel_drag() -> void:
	if _drag == Drag.TRANSFORM:
		for i in _drag_targets.size():
			for property: StringName in _drag_starts[i]:
				_drag_targets[i].set(property, _drag_starts[i][property])
	_drag = Drag.NONE
	_overlay.queue_redraw()


func _nudge(screen_units: Vector2) -> void:
	if orbit or not editor.root:
		return
	_ensure_cache()
	var model_moved := get_view_basis().inverse() * Vector3(screen_units.x, screen_units.y, 0.0)
	var changes := []
	for shape: GeoShape in editor.top_level_selection():
		var new_position := M.tidy(shape.position
				+ _parent_xform(shape).basis.inverse() * model_moved)
		changes.append([shape, &"position", shape.position, new_position])
	editor.commit("Nudge shapes", changes, true)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _BACKGROUND)
	if orbit:
		return
	# Grid lines one snap step apart (or a power of two times that, so they
	# don't crowd), with every fourth line brighter.
	var origin := _origin()
	var spacing: float = editor.snap_step if editor else 1.0
	while spacing * zoom < 8.0:
		spacing *= 2.0
	var pixels := spacing * zoom
	for axis in 2:
		var first := ceili(-origin[axis] / pixels)
		var last := floori((size[axis] - origin[axis]) / pixels)
		for n in range(first, last + 1):
			var at := origin[axis] + n * pixels
			var color := Color(1.0, 1.0, 1.0, 0.09 if n % 4 == 0 else 0.035)
			if axis == 0:
				draw_line(Vector2(at, 0.0), Vector2(at, size.y), color)
			else:
				draw_line(Vector2(0.0, at), Vector2(size.x, at), color)

	# The axes through the origin, colored by the model axis each shows, labeled
	# in the theme's font size (which includes the editor's display scale).
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var pad := font_size * 0.4
	for screen_axis in 2:
		var direction := Vector3.ZERO
		direction[screen_axis] = 1.0
		var model_direction := get_view_basis().inverse() * direction
		var model_axis := model_direction.abs().max_axis_index()
		var color := _AXIS_COLORS[model_axis]
		var label := ("+" if model_direction[model_axis] > 0.0 else "−") + _AXIS_NAMES[model_axis]
		if screen_axis == 0:
			draw_line(Vector2(0.0, origin.y), Vector2(size.x, origin.y), color * Color(1, 1, 1, 0.6))
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			draw_string(font, Vector2(size.x - width - pad, origin.y - pad), label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		else:
			draw_line(Vector2(origin.x, 0.0), Vector2(origin.x, size.y), color * Color(1, 1, 1, 0.6))
			draw_string(font, Vector2(origin.x + pad, size.y - pad), label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_overlay() -> void:
	if editor and editor.root:
		_ensure_cache()
		var hover := _index_of(_hover)
		if hover >= 0 and not editor.selection.has(_hover) and _drag == Drag.NONE:
			_draw_outline(hover, _HOVER_COLOR, 1.0)
		for shape: GeoShape in editor.selection:
			var i := _index_of(shape)
			if i >= 0:
				_draw_outline(i, _SELECTED_COLOR, 2.0)
	if _drag == Drag.BOX and _drag_active:
		var rect := Rect2(_press_position, Vector2.ZERO).expand(_drag_position)
		_overlay.draw_rect(rect, Color(_SELECTED_COLOR, 0.12))
		_overlay.draw_rect(rect, _SELECTED_COLOR, false, 1.0)
	if has_focus():
		_overlay.draw_rect(Rect2(Vector2.ONE, size - Vector2.ONE * 2.0),
				Color(1.0, 1.0, 1.0, 0.3), false, 2.0)


# Draws a shape's outline and pivot. Shapes without faces (groups) get a
# dashed box around their descendants instead.
func _draw_outline(i: int, color: Color, width: float) -> void:
	if _hidden[i] == 1:
		color.a *= 0.5
	if not _hulls[i].is_empty():
		var points := PackedVector2Array()
		for p in _hulls[i]:
			points.append(_to_screen(p))
		if points.size() >= 2:
			_overlay.draw_polyline(points, color, width)
	else:
		var bounds := _descendant_bounds(i)
		if bounds.has_area():
			var corners: Array[Vector2] = [bounds.position, Vector2(bounds.end.x, bounds.position.y),
					bounds.end, Vector2(bounds.position.x, bounds.end.y)]
			for c in 4:
				_overlay.draw_dashed_line(_to_screen(corners[c]), _to_screen(corners[(c + 1) % 4]),
						color, width, 4.0)
	var pivot := _to_screen(_origins[i])
	_overlay.draw_circle(pivot, 3.0, color)
	_overlay.draw_circle(pivot, 3.0, Color.BLACK, false, 1.0)


func _descendant_bounds(i: int) -> Rect2:
	var bounds := Rect2()
	var found := false
	for j in range(i + 1, _hulls.size()):
		var ancestor := _model.parents[j]
		while ancestor > i:
			ancestor = _model.parents[ancestor]
		if ancestor != i:
			continue
		for p in _hulls[j]:
			bounds = bounds.expand(p) if found else Rect2(p, Vector2.ZERO)
			found = true
	return bounds
