@tool
class_name GeoCompiledModel
extends RefCounted
## A GeoShape tree flattened into arrays (depth-first, so parents come before
## their children), plus mesh data built from it. Built once per root shape and
## shared by every GeoFigure drawing it.
##
## The vertices of every shape are concatenated, in shape order, into a single
## mesh surface. Each GeoFigure gets its own copy of that surface, and each
## redraw it overwrites the positions, the normals, the draw ranks, and the index
## buffer (which picks the faces to draw, in order) in place. The layout never
## changes, so the mesh never has to be rebuilt.

const _MAX_DEPTH := 64
## Pixelated figures encode (draw rank, surface, outlined) per pixel in 8 bits,
## which limits how many shapes they can tell apart.
const MAX_DRAWABLE_SHAPES := 255 / (2 * (GeoGeometry.MAX_SURFACE + 1)) - 1
const FORMAT := (Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)

var shapes: Array[GeoShape] = []
## Index of each shape's parent, or -1 for the root.
var parents := PackedInt32Array()
var geometries: Array[GeoGeometry] = []
var depth_biases := PackedFloat32Array()
## Each shape's distance from its origin to its farthest vertex.
var radii := PackedFloat32Array()
## Each shape's first vertex in the combined vertex arrays, and its vertex count.
var vertex_offsets := PackedInt32Array()
var vertex_counts := PackedInt32Array()
## Distance from the root's origin to the farthest vertex in the rest pose.
## (Overriding positions can move shapes past it.)
var bounding_radius := 0.0
## Indices of the shapes that have faces and aren't hidden.
var drawable_shapes := PackedInt32Array()
## Shape name -> shape index. If names repeat, the first shape wins.
var shape_indices: Dictionary[StringName, int] = {}

var vertex_count := 0
## RenderingServer surface data (see RenderingServer.mesh_add_surface()), or
## empty if there's nothing to draw. Its vertex and index data are placeholders.
var surface: Dictionary = {}
## Byte offsets of the normal (CUSTOM0.xyz) and the draw rank (CUSTOM1.z) within
## each vertex's attribute data.
var normal_offset := 0
var rank_offset := 0
## Bytes of attribute data per vertex.
var attribute_stride := 0
## Per shape, an Array with each face's triangle indices, offset into the
## combined vertex arrays and encoded as index buffer bytes.
var face_index_bytes: Array[Array] = []
## Size of the index buffer: enough to draw every face at once. Unused space is
## filled with degenerate triangles.
var index_capacity_bytes := 0

# Combined vertex data, used to build the surface.
var _positions := PackedVector3Array()
var _normals := PackedVector3Array()
var _colors := PackedColorArray()
var _uvs := PackedVector2Array()
var _custom1 := PackedFloat32Array()
var _face_indices: Array[Array] = []


func _init(root: GeoShape) -> void:
	_add_shape(root, -1, false, 0, 0.0)
	if drawable_shapes.size() > MAX_DRAWABLE_SHAPES:
		push_warning(("GeoShape tree has %d visible shapes with faces; pixel outlines"
				+ " support up to %d.") % [drawable_shapes.size(), MAX_DRAWABLE_SHAPES])
	if drawable_shapes.is_empty():
		return

	var all_indices := PackedInt32Array()
	for i in drawable_shapes:
		for indices: PackedInt32Array in _face_indices[i]:
			all_indices.append_array(indices)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _positions
	arrays[Mesh.ARRAY_COLOR] = _colors
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_CUSTOM0] = _normals.to_byte_array().to_float32_array()
	arrays[Mesh.ARRAY_CUSTOM1] = _custom1
	arrays[Mesh.ARRAY_INDEX] = all_indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, FORMAT)
	surface = RenderingServer.mesh_get_surface(mesh.get_rid(), 0)

	var format: int = surface.format
	normal_offset = RenderingServer.mesh_surface_get_format_offset(
			format, vertex_count, Mesh.ARRAY_CUSTOM0)
	rank_offset = RenderingServer.mesh_surface_get_format_offset(
			format, vertex_count, Mesh.ARRAY_CUSTOM1) + 8
	attribute_stride = RenderingServer.mesh_surface_get_format_attribute_stride(
			format, vertex_count)
	var index_stride := RenderingServer.mesh_surface_get_format_index_stride(
			format, vertex_count)
	index_capacity_bytes = all_indices.size() * index_stride
	for faces in _face_indices:
		var shape_bytes: Array[PackedByteArray] = []
		for indices: PackedInt32Array in faces:
			shape_bytes.append(_encode_indices(indices, index_stride))
		face_index_bytes.append(shape_bytes)


# parent_reach is the farthest the parent's origin can be from the root's.
func _add_shape(shape: GeoShape, parent: int, parent_hidden: bool, depth: int,
		parent_reach: float) -> void:
	if depth > _MAX_DEPTH:
		push_error("GeoShape tree is too deep. Does a shape contain itself?")
		return

	var index := shapes.size()
	var hidden := parent_hidden or not shape.visible
	var geometry := shape.get_geometry()
	shapes.append(shape)
	parents.append(parent)
	geometries.append(geometry)
	depth_biases.append(shape.depth_bias)
	if shape.name and not shape_indices.has(shape.name):
		shape_indices[shape.name] = index
	if not hidden and geometry.face_count() > 0:
		drawable_shapes.append(index)

	var radius := 0.0
	for p in geometry.positions:
		radius = maxf(radius, p.length())
	radii.append(radius)
	var reach := parent_reach + shape.position.length()
	bounding_radius = maxf(bounding_radius, reach + radius)
	vertex_offsets.append(vertex_count)
	vertex_counts.append(geometry.positions.size())

	var faces: Array[PackedInt32Array] = []
	for local_indices in geometry.face_indices:
		var indices := local_indices.duplicate()
		for i in indices.size():
			indices[i] += vertex_count
		faces.append(indices)
	_face_indices.append(faces)

	_positions.append_array(geometry.positions)
	_normals.append_array(geometry.normals)
	_uvs.append_array(geometry.uvs)
	var shape_colors := PackedColorArray()
	shape_colors.resize(geometry.positions.size())
	shape_colors.fill(shape.color)
	_colors.append_array(shape_colors)
	for face in geometry.vertex_faces:
		# The draw rank (z) is filled in by GeoFigure each redraw.
		_custom1.append(index)
		_custom1.append(face)
		_custom1.append(0.0)
		_custom1.append(geometry.face_surfaces[face] * 2 + (0 if shape.outlined else 1))
	vertex_count += geometry.positions.size()

	for child in shape.children:
		if child:
			_add_shape(child, index, hidden, depth + 1, reach)


static func _encode_indices(indices: PackedInt32Array, stride: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(indices.size() * stride)
	for i in indices.size():
		if stride == 2:
			bytes.encode_u16(i * 2, indices[i])
		else:
			bytes.encode_u32(i * 4, indices[i])
	return bytes
