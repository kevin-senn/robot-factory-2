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
## Set a ShaderMaterial as this node's material to shade the shapes. The mesh
## provides, per vertex:
## - VERTEX: the projected position.
## - COLOR: the shape's color (times modulate, as usual).
## - UV: face-local coordinates, from 0 to 1 across each face.
## - CUSTOM0.xyz: the view-space normal (x right, y down, z toward the camera).
##   Smooth across curved surfaces. Only readable in vertex(); pass it to
##   fragment() with a varying.
## - CUSTOM1.x: the index of the shape (depth-first, parents before children).
## - CUSTOM1.y: the index of the face within the shape.
## - CUSTOM1.zw: unused for now.
## See geo_shading_example.gdshader.

## Faces must point at least this much toward the camera to be drawn.
const _FACING_EPSILON := 0.0001

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
@export var model_rotation_degrees := Vector3.ZERO:
	set(value):
		model_rotation_degrees = value
		queue_redraw()

# This figure's copy of the model's mesh, updated in place each redraw.
var _mesh := RenderingServer.mesh_create()
var _mesh_model: GeoCompiledModel
# The mesh's attribute data. Each redraw, the new normals are copied into it.
# (Using Images to copy byte ranges keeps the work in native code.)
var _attributes: Image
var _normals_image := Image.new()

# Per-figure overrides of shapes' transforms, by shape name.
var _position_overrides: Dictionary[StringName, Vector3] = {}
var _rotation_overrides: Dictionary[StringName, Vector3] = {}

# Each shape's transform relative to its parent, with overrides applied.
var _pose: Array[Transform3D] = []


func _init() -> void:
	# The setter doesn't run for the default value.
	if camera:
		camera.changed.connect(queue_redraw)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		RenderingServer.free_rid(_mesh)


## Overrides the position (relative to its parent) of the shape with the given
## name, for this figure only.
func set_shape_position(shape_name: StringName, value: Vector3) -> void:
	_position_overrides[shape_name] = value
	_update_pose(shape_name)


## Overrides the rotation (relative to its parent) of the shape with the given
## name, for this figure only.
func set_shape_rotation_degrees(shape_name: StringName, value: Vector3) -> void:
	_rotation_overrides[shape_name] = value
	_update_pose(shape_name)


## Removes all overrides of shapes' positions and rotations.
func clear_shape_overrides() -> void:
	_position_overrides.clear()
	_rotation_overrides.clear()
	if _mesh_model:
		_rebuild_pose()
	queue_redraw()


func _update_pose(shape_name: StringName) -> void:
	queue_redraw()
	if not _mesh_model:
		return # _draw() will apply all overrides.
	var index: int = _mesh_model.shape_indices.get(shape_name, -1)
	if index < 0:
		push_warning("GeoFigure has no shape named '%s'." % shape_name)
		return
	_pose[index] = _make_pose_transform(_mesh_model.shapes[index])


func _rebuild_pose() -> void:
	_pose.resize(_mesh_model.shapes.size())
	for i in _mesh_model.shapes.size():
		_pose[i] = _make_pose_transform(_mesh_model.shapes[i])


func _make_pose_transform(pose_shape: GeoShape) -> Transform3D:
	return GeoShape.make_transform(
			_position_overrides.get(pose_shape.name, pose_shape.position),
			_rotation_overrides.get(pose_shape.name, pose_shape.rotation_degrees))


func _set_model(model: GeoCompiledModel) -> void:
	_mesh_model = model
	_rebuild_pose()
	RenderingServer.mesh_clear(_mesh)
	if model.surface.is_empty():
		_attributes = null
		return
	RenderingServer.mesh_add_surface(_mesh, model.surface)
	_attributes = Image.create_from_data(model.attribute_stride, model.vertex_count, false,
			Image.FORMAT_L8, model.surface.attribute_data)


func _draw() -> void:
	if not shape:
		return
	var model := shape.get_compiled()
	if model != _mesh_model:
		_set_model(model)
	if model.surface.is_empty():
		return

	var elevation := camera.elevation_degrees if camera \
			else GeoCamera.DEFAULT_ELEVATION_DEGREES
	var rotation_radians := Vector3(deg_to_rad(model_rotation_degrees.x),
			deg_to_rad(model_rotation_degrees.y), deg_to_rad(model_rotation_degrees.z))
	var view := Transform3D(
			GeoCamera.make_view_basis(elevation) * Basis.from_euler(rotation_radians),
			Vector3.ZERO)

	# Transform every shape's vertices and normals into view space. (The
	# transform of packed arrays happens in native code.)
	var shape_count := model.shapes.size()
	var transforms: Array[Transform3D] = []
	transforms.resize(shape_count)
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	for i in shape_count:
		var parent := model.parents[i]
		var xform := (view if parent < 0 else transforms[parent]) * _pose[i]
		transforms[i] = xform
		var geometry := model.geometries[i]
		if not geometry.positions.is_empty():
			positions.append_array(xform * geometry.positions)
			# There's no scaling, so the basis is a pure rotation and can
			# transform normals as is.
			normals.append_array(Transform3D(xform.basis, Vector3.ZERO) * geometry.normals)

	# Sort shapes back to front by depth (view-space z), and find their bounds.
	var depths := PackedFloat32Array()
	depths.resize(shape_count)
	var order: Array[int] = []
	var bounds := AABB(transforms[model.drawable_shapes[0]].origin, Vector3.ZERO)
	for i in model.drawable_shapes:
		var xform := transforms[i]
		depths[i] = (xform * model.geometries[i].sort_point).z + model.depth_biases[i]
		order.append(i)
		var radius := Vector3.ONE * model.radii[i]
		bounds = bounds.merge(AABB(xform.origin - radius, radius * 2.0))
	order.sort_custom(func(a: int, b: int) -> bool:
		return depths[a] < depths[b] if depths[a] != depths[b] else a < b)

	# Fill the index buffer with the front-facing faces, in order, then pad it
	# with degenerate triangles.
	var indices := PackedByteArray()
	for i in order:
		var facing := Transform3D(transforms[i].basis, Vector3.ZERO) \
				* model.geometries[i].face_normals
		var faces: Array = model.face_index_bytes[i]
		for face in facing.size():
			if facing[face].z > _FACING_EPSILON:
				indices.append_array(faces[face])
	if indices.is_empty():
		return
	indices.resize(model.index_capacity_bytes)

	# Assumes single-precision floats (the default engine build).
	_normals_image.set_data(12, model.vertex_count, false, Image.FORMAT_L8,
			normals.to_byte_array())
	_attributes.blit_rect(_normals_image, Rect2i(0, 0, 12, model.vertex_count),
			Vector2i(model.normal_offset, 0))
	RenderingServer.mesh_surface_update_vertex_region(_mesh, 0, 0, positions.to_byte_array())
	RenderingServer.mesh_surface_update_attribute_region(_mesh, 0, 0, _attributes.get_data())
	RenderingServer.mesh_surface_update_index_region(_mesh, 0, 0, indices)
	RenderingServer.mesh_set_custom_aabb(_mesh, bounds)
	RenderingServer.canvas_item_add_mesh(get_canvas_item(), _mesh)


func _get_configuration_warnings() -> PackedStringArray:
	if not shape:
		return ["Set a shape (e.g. a GeoGroup) to draw."]
	return []
