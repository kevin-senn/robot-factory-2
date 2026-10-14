@tool
class_name GeoFigure
extends Node2D
## Draws a tree of GeoShapes as fake-3D geometry, projected by an orthographic
## camera looking down at the figure from GeoCamera.elevation_degrees.
##
## The whole figure is a single mesh, drawn with a single draw call. Each
## redraw, it transforms every shape's vertices, culls back faces, and sorts
## shapes back to front, so shapes closer to the camera draw on top, then
## updates the mesh in place. Figures that don't change don't redraw. Sorting
## only happens within a figure; order figures against each other as you would
## any other CanvasItems (e.g. with y_sort_enabled on their parent).
##
## With a pixel_material (the default), the figure is pixelated: its mesh is
## drawn at one texel per art pixel into GeoPixelAtlas, lit by
## geo_pixel_lighting.gdshader, and the figure draws that as a sprite with
## pixel_material. See geo_pixel_display.gdshader.
##
## With no pixel_material, the mesh is drawn directly, with this node's
## material. Set a ShaderMaterial there to shade the shapes. Either way, the
## mesh provides, per vertex:
## - VERTEX: the projected position.
## - COLOR: the shape's color (times modulate, as usual).
## - UV: face-local coordinates, from 0 to 1 across each face.
## - CUSTOM0.xyz: the view-space normal (x right, y down, z toward the camera).
##   Smooth across curved surfaces. Only readable in vertex(); pass it to
##   fragment() with a varying.
## - CUSTOM1.x: the index of the shape (depth-first, parents before children).
## - CUSTOM1.y: the index of the face within the shape.
## - CUSTOM1.z: the shape's position in this redraw's back-to-front draw order.
## - CUSTOM1.w: the face's surface (see GeoGeometry.face_surfaces) * 2, plus 1
##   if the shape isn't outlined (see GeoShape.outlined).
## See geo_shading_example.gdshader.

## Faces must point at least this much toward the camera to be drawn.
const _FACING_EPSILON := 0.0001

# The fields of each shape that figures can override (and animate), as the
# properties "shapes/<shape name>/<field>".
const _SHAPE_FIELDS: Array[StringName] = [&"position", &"rotation_degrees", &"scale", &"visible"]

# Property name -> [shape name, field] for "shapes/..." properties, or [] for
# any other property, so _get() and _set() don't parse names every call.
static var _property_parse_cache: Dictionary[StringName, Array] = {}

## The root of the shape tree to draw. Usually saved as its own resource, so
## many figures can share it.
@export var shape: GeoShape:
	set(value):
		if shape:
			shape.changed.disconnect(queue_redraw)
		shape = value
		if shape:
			shape.changed.connect(queue_redraw)
		queue_redraw()
		update_configuration_warnings()

@export var camera: GeoCamera = preload("res://geo_render/default_geo_camera.tres"):
	set(value):
		if camera:
			camera.changed.disconnect(queue_redraw)
		camera = value
		if camera:
			camera.changed.connect(queue_redraw)
		queue_redraw()

## Rotates the whole figure in 3D, before it's projected. (Node2D.rotation
## instead rotates the projected image.)
@export_custom(PROPERTY_HINT_RANGE, "-180,180,1,or_less,or_greater,suffix:°")
var model_rotation_degrees := Vector3.ZERO:
	set(value):
		model_rotation_degrees = value
		queue_redraw()

## Draws the figure pixelated, with this material (normally
## geo_render/pixel/geo_pixel_display.tres, shared by all figures).
## If null, the figure is drawn as smooth geometry instead, with material.
@export var pixel_material: ShaderMaterial = preload("res://geo_render/pixel/geo_pixel_display.tres"):
	set(value):
		pixel_material = value
		queue_redraw()

## The color the whole figure flashes toward (e.g. white or red when hit).
## Needs the pixel material.
@export var flash_color := Color.WHITE:
	set(value):
		flash_color = value
		set_instance_shader_parameter(&"flash_color", value)

## How far the figure is mixed toward flash_color, from 0 (not at all) to 1
## (a solid silhouette). Animate it for flashes.
@export_range(0.0, 1.0, 0.01) var flash_amount := 0.0:
	set(value):
		flash_amount = value
		set_instance_shader_parameter(&"flash_amount", value)

@export_group("Explosion")
## How long the pieces fly (and fade) for, in seconds.
@export_range(0.05, 10.0, 0.05, "or_greater", "suffix:s") var explosion_duration := 1.0
## How fast pieces fly at intensity 1, in local units per second.
@export_range(0.0, 1000.0, 1.0, "or_greater") var explosion_max_speed := 150.0
## How far pieces spin over the explosion at intensity 1.
@export_range(0.0, 3600.0, 1.0, "or_greater", "suffix:°") var explosion_max_spin_degrees := 720.0
## How far each piece's direction can stray from its evenly spaced slot, as a
## fraction of the angle between slots. Below 1, neighboring pieces never cross.
@export_range(0.0, 1.0, 0.05) var explosion_direction_jitter := 0.5
## The most a piece's direction tilts toward or away from the camera (z). Small
## values keep the spread visible on screen.
@export_range(0.0, 1.0, 0.05) var explosion_max_depth_tilt := 0.3
@export_group("")

## Emitted when an explosion's pieces have faded away.
signal explosion_finished

# This figure's copy of the model's mesh, updated in place each redraw.
var _mesh := RenderingServer.mesh_create()
var _mesh_model: GeoCompiledModel
# The mesh's attribute data, as an Image of 32-bit floats, one row per vertex.
# Each redraw, the new normals and draw ranks are copied into it. (Using Images
# to copy ranges of bytes keeps the work in native code.)
var _attributes: Image
var _normals_image := Image.new()

# When pixelated, this figure's cell in GeoPixelAtlas, and the canvas item that
# draws the mesh there.
var _atlas_cell := Rect2i()
var _atlas_item := RID()
# The material last set on this node's canvas item.
var _applied_material := RID()

# Per-figure overrides of shapes' fields (see _SHAPE_FIELDS): shape name ->
# field -> value.
var _overrides: Dictionary[StringName, Dictionary] = {}

# Each shape's transform relative to its parent, and whether it's hidden
# (itself or by an ancestor), with overrides applied.
var _pose: Array[Transform3D] = []
var _hidden := PackedByteArray()

# The current explosion: seconds since it started (-1 if not exploding), and,
# per shape, the index of the shape at the root of its piece. Pieces' velocities
# and spins (in view space) are stored at their roots' indices.
var _explosion_time := -1.0
var _piece_roots := PackedInt32Array()
var _piece_velocities := PackedVector3Array()
var _piece_spin_axes := PackedVector3Array()
var _piece_spin_angles := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	# The setter doesn't run for the default value.
	if camera:
		camera.changed.connect(queue_redraw)


func _ready() -> void:
	set_process(is_exploding())
	# The setters don't run for default values.
	set_instance_shader_parameter(&"flash_color", flash_color)
	set_instance_shader_parameter(&"flash_amount", flash_amount)


func _process(delta: float) -> void:
	if not is_exploding():
		set_process(false)
		return
	_explosion_time = minf(_explosion_time + delta, explosion_duration)
	queue_redraw()
	if _explosion_time >= explosion_duration:
		set_process(false)
		explosion_finished.emit()


## Breaks the figure into pieces (see GeoShape.glued) that fly apart and fade
## away. intensity, from 0 to 1, scales how fast and how far the pieces fly and
## spin. Pieces fly in straight lines, relative to the figure. (Moving the
## figure itself, e.g. for momentum or gravity, is up to its parent.)
##
## Pieces' directions are spread evenly around the screen (x and y), each in
## roughly the direction it already is from the others, then jittered a little.
## So pieces always fly away from each other, never together.
func explode(intensity: float) -> void:
	if not shape:
		return
	var model := shape.get_compiled()
	if model != _mesh_model:
		_set_model(model)
	intensity = clampf(intensity, 0.0, 1.0)
	var transforms := _compute_transforms(model)

	# Find the pieces. The root's piece stays in place; the rest fly.
	var count := model.shapes.size()
	_piece_roots.resize(count)
	_piece_velocities.resize(count)
	_piece_spin_axes.resize(count)
	_piece_spin_angles.resize(count)
	_piece_velocities.fill(Vector3.ZERO)
	_piece_spin_angles.fill(0.0)
	var flying: Array[int] = []
	for i in count:
		var parent := model.parents[i]
		if parent >= 0 and model.shapes[i].glued:
			_piece_roots[i] = _piece_roots[parent]
		else:
			_piece_roots[i] = i
			if parent >= 0:
				flying.append(i)

	# Order the flying pieces by their angle (on screen) around their middle.
	var centers: Dictionary[int, Vector2] = {}
	var middle := Vector2.ZERO
	for i in flying:
		var center := transforms[i] * model.geometries[i].sort_point
		centers[i] = Vector2(center.x, center.y)
		middle += centers[i]
	middle /= maxf(flying.size(), 1)
	var angles: Dictionary[int, float] = {}
	for i in flying:
		angles[i] = (centers[i] - middle).angle()
	flying.sort_custom(func(a: int, b: int) -> bool: return angles[a] < angles[b])

	# Give them evenly spaced directions, in that order, turned to best match
	# the directions they already are from the middle.
	var spacing := TAU / maxf(flying.size(), 1)
	var alignment := Vector2.ZERO
	for slot in flying.size():
		alignment += Vector2.from_angle(angles[flying[slot]] - slot * spacing)
	var start := alignment.angle() if not alignment.is_zero_approx() else _rng.randf() * TAU

	for slot in flying.size():
		var i := flying[slot]
		var angle := start + (slot + _rng.randf_range(-0.5, 0.5) * explosion_direction_jitter) \
				* spacing
		var direction := Vector3(cos(angle), sin(angle), _rng.randf_range(-1.0, 1.0)
				* explosion_max_depth_tilt).normalized()
		var speed := explosion_max_speed * intensity * _rng.randf_range(0.7, 1.0)
		_piece_velocities[i] = direction * speed
		_piece_spin_axes[i] = _random_direction()
		_piece_spin_angles[i] = deg_to_rad(explosion_max_spin_degrees) * intensity \
				* _rng.randf_range(0.5, 1.0)

	_explosion_time = 0.0
	set_process(true)
	queue_redraw()


## Puts an exploded figure back together.
func reassemble() -> void:
	_explosion_time = -1.0
	set_process(false)
	queue_redraw()


func is_exploding() -> bool:
	return _explosion_time >= 0.0


func _random_direction() -> Vector3:
	return Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()).normalized()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_EXIT_TREE:
			_release_atlas_cell()
		NOTIFICATION_VISIBILITY_CHANGED:
			if _atlas_item.is_valid():
				RenderingServer.canvas_item_set_visible(_atlas_item, is_visible_in_tree())
				_request_atlas_update()
		NOTIFICATION_PREDELETE:
			_release_atlas_cell()
			RenderingServer.free_rid(_mesh)


## Overrides the position (relative to its parent) of the shape with the given
## name, for this figure only. Same as setting "shapes/<name>/position".
func set_shape_position(shape_name: StringName, value: Vector3) -> void:
	_set_shape_field(shape_name, &"position", value)


## Overrides the rotation (relative to its parent) of the shape with the given
## name, for this figure only.
func set_shape_rotation_degrees(shape_name: StringName, value: Vector3) -> void:
	_set_shape_field(shape_name, &"rotation_degrees", value)


## Overrides the scale of the shape with the given name, for this figure only.
func set_shape_scale(shape_name: StringName, value: Vector3) -> void:
	_set_shape_field(shape_name, &"scale", value)


## Overrides whether the shape with the given name is visible, for this figure
## only.
func set_shape_visible(shape_name: StringName, value: bool) -> void:
	_set_shape_field(shape_name, &"visible", value)


## Removes all overrides of shapes' fields.
func clear_shape_overrides() -> void:
	_overrides.clear()
	if _mesh_model:
		_rebuild_pose()
	queue_redraw()
	notify_property_list_changed()


# Returns the shape with the given (usable) name, or null.
func _find_shape(shape_name: StringName) -> GeoShape:
	if not shape:
		return null
	var model := shape.get_compiled()
	var index: int = model.shape_indices.get(shape_name, -1)
	return model.shapes[index] if index >= 0 else null


func _get_shape_field(shape_name: StringName, field: StringName) -> Variant:
	var overrides: Dictionary = _overrides.get(shape_name, {})
	if overrides.has(field):
		return overrides[field]
	var found := _find_shape(shape_name)
	return found.get(field) if found else null


func _set_shape_field(shape_name: StringName, field: StringName, value: Variant) -> void:
	# Values equal to the shape's own aren't overrides (and aren't saved).
	var found := _find_shape(shape_name)
	if found and found.get(field) == value:
		if _overrides.has(shape_name):
			_overrides[shape_name].erase(field)
			if _overrides[shape_name].is_empty():
				_overrides.erase(shape_name)
	else:
		if not _overrides.has(shape_name):
			_overrides[shape_name] = {}
		_overrides[shape_name][field] = value
	queue_redraw()
	if not _mesh_model:
		return # _draw() will apply all overrides.
	var index: int = _mesh_model.shape_indices.get(shape_name, -1)
	if index < 0:
		push_warning("GeoFigure has no shape named '%s'." % shape_name)
	elif field == &"visible":
		_rebuild_hidden()
	else:
		_pose[index] = _make_pose_transform(_mesh_model.shapes[index])


func _rebuild_pose() -> void:
	_pose.resize(_mesh_model.shapes.size())
	for i in _mesh_model.shapes.size():
		_pose[i] = _make_pose_transform(_mesh_model.shapes[i])
	_rebuild_hidden()


func _rebuild_hidden() -> void:
	var count := _mesh_model.shapes.size()
	_hidden.resize(count)
	for i in count:
		var pose_shape := _mesh_model.shapes[i]
		var overrides: Dictionary = _overrides.get(pose_shape.name, {})
		var parent := _mesh_model.parents[i]
		var hidden: bool = (parent >= 0 and _hidden[parent] == 1) \
				or not overrides.get(&"visible", pose_shape.visible)
		_hidden[i] = 1 if hidden else 0


func _make_pose_transform(pose_shape: GeoShape) -> Transform3D:
	var overrides: Dictionary = _overrides.get(pose_shape.name, {})
	return GeoShape.make_transform(
			overrides.get(&"position", pose_shape.position),
			overrides.get(&"rotation_degrees", pose_shape.rotation_degrees),
			overrides.get(&"scale", pose_shape.scale))


# Returns [shape name, field] if property is "shapes/<shape name>/<field>",
# otherwise [].
static func _parse_shape_property(property: StringName) -> Array:
	var parsed: Variant = _property_parse_cache.get(property)
	if parsed == null:
		parsed = []
		var parts := String(property).split("/")
		if parts.size() == 3 and parts[0] == "shapes" and StringName(parts[2]) in _SHAPE_FIELDS:
			parsed = [StringName(parts[1]), StringName(parts[2])]
		_property_parse_cache[property] = parsed
	return parsed


func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	if not shape:
		return properties
	var model := shape.get_compiled()
	if model.shape_indices.is_empty():
		return properties
	# The group's prefix is hidden, and the inspector makes a subsection per shape.
	properties.append({name = "Shapes", type = TYPE_NIL, usage = PROPERTY_USAGE_GROUP,
			hint_string = "shapes/"})
	var names := model.shape_indices.keys()
	names.sort_custom(func(a: StringName, b: StringName) -> bool:
		return model.shape_indices[a] < model.shape_indices[b])
	for shape_name: StringName in names:
		var prefix := "shapes/%s/" % shape_name
		# Only overridden fields are saved; the rest come from the shape.
		var overrides: Dictionary = _overrides.get(shape_name, {})
		var usage := func(field: StringName) -> int:
			return PROPERTY_USAGE_DEFAULT if overrides.has(field) else PROPERTY_USAGE_EDITOR
		properties.append({name = prefix + "position", type = TYPE_VECTOR3,
				hint = PROPERTY_HINT_RANGE, hint_string = "-128,128,0.5,or_less,or_greater",
				usage = usage.call(&"position")})
		properties.append({name = prefix + "rotation_degrees", type = TYPE_VECTOR3,
				hint = PROPERTY_HINT_RANGE, hint_string = "-180,180,1,or_less,or_greater,suffix:°",
				usage = usage.call(&"rotation_degrees")})
		properties.append({name = prefix + "scale", type = TYPE_VECTOR3,
				hint = PROPERTY_HINT_RANGE, hint_string = "0,4,0.05,or_less,or_greater",
				usage = usage.call(&"scale")})
		properties.append({name = prefix + "visible", type = TYPE_BOOL,
				usage = usage.call(&"visible")})
	return properties


func _get(property: StringName) -> Variant:
	var parsed := _parse_shape_property(property)
	return _get_shape_field(parsed[0], parsed[1]) if parsed else null


func _property_can_revert(property: StringName) -> bool:
	return not _parse_shape_property(property).is_empty()


func _property_get_revert(property: StringName) -> Variant:
	var parsed := _parse_shape_property(property)
	if not parsed:
		return null
	var found := _find_shape(parsed[0])
	return found.get(parsed[1]) if found else null


func _set_model(model: GeoCompiledModel) -> void:
	_mesh_model = model
	_rebuild_pose()
	# The "shapes/..." properties follow the tree.
	notify_property_list_changed()
	update_configuration_warnings()
	if is_exploding():
		reassemble() # The pieces were for the old model.
	RenderingServer.mesh_clear(_mesh)
	if model.surface.is_empty():
		_attributes = null
		return
	RenderingServer.mesh_add_surface(_mesh, model.surface)
	_attributes = Image.create_from_data(model.attribute_stride / 4, model.vertex_count, false,
			Image.FORMAT_RF, model.surface.attribute_data)


func _set(property: StringName, value: Variant) -> bool:
	if property == &"material":
		# CanvasItem will set its material on the canvas item, so _draw() must
		# set it again.
		_applied_material = RID()
		queue_redraw()
		return false
	var parsed := _parse_shape_property(property)
	if not parsed:
		return false
	_set_shape_field(parsed[0], parsed[1], value)
	return true


func _request_atlas_update() -> void:
	GeoPixelAtlas.request_update(get_viewport().get_viewport_rid() if is_inside_tree() else RID())


func _release_atlas_cell() -> void:
	if _atlas_item.is_valid():
		RenderingServer.free_rid(_atlas_item)
		_atlas_item = RID()
	if _atlas_cell.has_area():
		GeoPixelAtlas.release(_atlas_cell)
		_atlas_cell = Rect2i()


func _draw() -> void:
	if _atlas_item.is_valid():
		RenderingServer.canvas_item_clear(_atlas_item)
		_request_atlas_update()
	if not pixel_material:
		_release_atlas_cell()
	var draw_material := pixel_material.get_rid() if pixel_material \
			else material.get_rid() if material else RID()
	if draw_material != _applied_material:
		RenderingServer.canvas_item_set_material(get_canvas_item(), draw_material)
		_applied_material = draw_material
	if not shape:
		return
	var model := shape.get_compiled()
	if model != _mesh_model:
		_set_model(model)
	if model.surface.is_empty():
		return
	var fade := 1.0
	if is_exploding():
		var progress := _explosion_time / explosion_duration
		fade = 1.0 - progress * progress
		if fade <= 0.0:
			return

	var shape_count := model.shapes.size()
	var transforms := _compute_transforms(model)
	if is_exploding():
		_apply_explosion(transforms)

	# Transform every shape's vertices and normals into view space. (The
	# transform of packed arrays happens in native code.) Normals transform by
	# the inverse transpose, which keeps them perpendicular to scaled surfaces.
	# They're left unnormalized: culling only needs their sign, and shaders
	# normalize them. Shapes scaled to nothing can't be drawn (or inverted).
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var normal_transforms: Array[Transform3D] = []
	normal_transforms.resize(shape_count)
	var collapsed := PackedByteArray()
	collapsed.resize(shape_count)
	for i in shape_count:
		var xform := transforms[i]
		var geometry := model.geometries[i]
		if absf(xform.basis.determinant()) < 0.000001:
			collapsed[i] = 1
		else:
			normal_transforms[i] = Transform3D(xform.basis.inverse().transposed(), Vector3.ZERO)
		if not geometry.positions.is_empty():
			positions.append_array(xform * geometry.positions)
			# Keep the vertex layout fixed, even for collapsed shapes.
			normals.append_array(geometry.normals if collapsed[i] == 1
					else normal_transforms[i] * geometry.normals)

	# Sort the shapes being drawn back to front by depth (view-space z), and find
	# their bounds and how far they reach from the figure's origin.
	var depths := PackedFloat32Array()
	depths.resize(shape_count)
	var order: Array[int] = []
	var bounds := AABB()
	var reach := 0.0
	for i in model.drawable_shapes:
		if _hidden[i] == 1 or collapsed[i] == 1:
			continue
		var xform := transforms[i]
		depths[i] = (xform * model.geometries[i].sort_point).z + model.depth_biases[i]
		var scale_3d := xform.basis.get_scale().abs()
		var radius := model.radii[i] * scale_3d[scale_3d.max_axis_index()]
		var shape_bounds := AABB(xform.origin - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
		bounds = shape_bounds if order.is_empty() else bounds.merge(shape_bounds)
		reach = maxf(reach, xform.origin.length() + radius)
		order.append(i)
	if order.is_empty():
		return
	order.sort_custom(func(a: int, b: int) -> bool:
		return depths[a] < depths[b] if depths[a] != depths[b] else a < b)

	# Fill the index buffer with the front-facing faces, in order, then pad it
	# with degenerate triangles.
	var indices := PackedByteArray()
	for i in order:
		var facing := normal_transforms[i] * model.geometries[i].face_normals
		var faces: Array = model.face_index_bytes[i]
		for face in facing.size():
			if facing[face].z > _FACING_EPSILON:
				indices.append_array(faces[face])
	if indices.is_empty():
		return
	indices.resize(model.index_capacity_bytes)

	# Copy in the normals and draw ranks. Assumes single-precision floats (the
	# default engine build).
	_normals_image.set_data(3, model.vertex_count, false, Image.FORMAT_RF,
			normals.to_byte_array())
	_attributes.blit_rect(_normals_image, Rect2i(0, 0, 3, model.vertex_count),
			Vector2i(model.normal_offset / 4, 0))
	for rank in order.size():
		var i := order[rank]
		_attributes.fill_rect(Rect2i(model.rank_offset / 4, model.vertex_offsets[i],
				1, model.vertex_counts[i]), Color(rank, 0.0, 0.0))

	RenderingServer.mesh_surface_update_vertex_region(_mesh, 0, 0, positions.to_byte_array())
	RenderingServer.mesh_surface_update_attribute_region(_mesh, 0, 0, _attributes.get_data())
	RenderingServer.mesh_surface_update_index_region(_mesh, 0, 0, indices)
	RenderingServer.mesh_set_custom_aabb(_mesh, bounds)
	var modulate_color := Color(1.0, 1.0, 1.0, fade)
	if pixel_material:
		_draw_pixelated(reach, modulate_color)
	else:
		RenderingServer.canvas_item_add_mesh(get_canvas_item(), _mesh, Transform2D(),
				modulate_color)


# Returns each shape's transform into view space.
func _compute_transforms(model: GeoCompiledModel) -> Array[Transform3D]:
	var elevation := camera.elevation_degrees if camera \
			else GeoCamera.DEFAULT_ELEVATION_DEGREES
	var rotation_radians := Vector3(deg_to_rad(model_rotation_degrees.x),
			deg_to_rad(model_rotation_degrees.y), deg_to_rad(model_rotation_degrees.z))
	var view := Transform3D(
			GeoCamera.make_view_basis(elevation) * Basis.from_euler(rotation_radians),
			Vector3.ZERO)
	var transforms: Array[Transform3D] = []
	transforms.resize(model.shapes.size())
	for i in model.shapes.size():
		var parent := model.parents[i]
		transforms[i] = (view if parent < 0 else transforms[parent]) * _pose[i]
	return transforms


# Moves and spins each piece (around its root's origin), in view space.
func _apply_explosion(transforms: Array[Transform3D]) -> void:
	var progress := _explosion_time / explosion_duration
	var piece_moves: Dictionary[int, Transform3D] = {}
	for i in transforms.size():
		var piece := _piece_roots[i]
		if piece == _piece_roots[0]:
			continue # The root's piece stays in place.
		if not piece_moves.has(piece):
			var pivot := transforms[piece].origin
			var spin := Basis(_piece_spin_axes[piece], _piece_spin_angles[piece] * progress)
			var offset := _piece_velocities[piece] * _explosion_time
			piece_moves[piece] = Transform3D(spin, pivot + offset - spin * pivot)
		transforms[i] = piece_moves[piece] * transforms[i]


# reach is how far the drawn shapes extend from the figure's origin.
func _draw_pixelated(reach: float, modulate_color: Color) -> void:
	var pixel_size := camera.pixel_size if camera else GeoCamera.DEFAULT_PIXEL_SIZE
	var cell_size := GeoPixelAtlas.get_cell_size(reach / pixel_size)
	# Grow the cell right away, but only shrink it once it's far too big, so a
	# figure that's animating near a size boundary doesn't keep reallocating.
	if cell_size > _atlas_cell.size.x or cell_size * 4 <= _atlas_cell.size.x:
		_release_atlas_cell()
		_atlas_cell = GeoPixelAtlas.allocate(cell_size)
		if not _atlas_cell.has_area():
			return
		_atlas_item = GeoPixelAtlas.create_item()
		RenderingServer.canvas_item_set_visible(_atlas_item, is_visible_in_tree())

	# Draw the mesh into the cell, with the figure's origin at the cell's center
	# and one texel per art pixel.
	RenderingServer.canvas_item_set_transform(_atlas_item, Transform2D(
			0.0, Vector2.ONE / pixel_size, 0.0, Vector2(_atlas_cell.get_center())))
	RenderingServer.canvas_item_add_mesh(_atlas_item, _mesh)
	_request_atlas_update()

	# Then draw the cell here, scaled back up.
	var size := _atlas_cell.size.x * pixel_size
	RenderingServer.canvas_item_add_texture_rect_region(get_canvas_item(),
			Rect2(-size / 2.0, -size / 2.0, size, size), GeoPixelAtlas.get_texture(),
			Rect2(_atlas_cell), modulate_color)


func _get_configuration_warnings() -> PackedStringArray:
	if not shape:
		return ["Set a shape (e.g. a GeoGroup) to draw."]
	return shape.get_compiled().name_problems
