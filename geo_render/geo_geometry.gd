@tool
class_name GeoGeometry
extends RefCounted
## Tessellated geometry for one GeoShape, in the shape's local space.
##
## The geometry is a list of planar, convex faces. Every GeoShape primitive is
## a convex solid (or a single flat face), so once back faces are culled, its
## remaining faces never overlap each other and can be drawn in any order. That
## means depth sorting is only needed between shapes, never within one.
##
## Built once per shape (and cached on it), then shared by every GeoFigure that
## draws that shape.

## Surface ids range from 0 to MAX_SURFACE.
const MAX_SURFACE := 2

## Vertex positions. Vertices aren't shared between faces, so each face can have
## its own normals and UVs.
var positions := PackedVector3Array()
## Per-vertex normals. Equal to the face normal on flat faces; smooth (e.g.
## radial) on curved surfaces, so a shader can shade them smoothly.
var normals := PackedVector3Array()
## Per-vertex face-local coordinates, in [0, 1] across each face.
var uvs := PackedVector2Array()
## Which face each vertex belongs to.
var vertex_faces := PackedInt32Array()
## One outward normal per face, used for back-face culling.
var face_normals := PackedVector3Array()
## Which surface of the shape each face belongs to. Pixel outlines can be drawn
## between different surfaces (e.g. the sides of a box), but not between the
## faces of one curved surface. Faces that can be visible side by side must
## have different surfaces; opposite faces of a box can share one.
var face_surfaces := PackedInt32Array()
## Triangle indices (into positions) for each face.
var face_indices: Array[PackedInt32Array] = []
## The point used to depth-sort this shape against other shapes: the center of
## its bounds.
var sort_point := Vector3.ZERO


func face_count() -> int:
	return face_normals.size()


## Adds a convex, planar face. Its points must go around its edge in order.
func add_face(points: PackedVector3Array, point_normals: PackedVector3Array,
		point_uvs: PackedVector2Array, face_normal: Vector3, surface := 0) -> void:
	assert(points.size() >= 3)
	assert(point_normals.size() == points.size())
	assert(point_uvs.size() == points.size())
	assert(surface >= 0 and surface <= MAX_SURFACE)
	var base := positions.size()
	var face := face_normals.size()
	positions.append_array(points)
	normals.append_array(point_normals)
	uvs.append_array(point_uvs)
	face_normals.append(face_normal)
	face_surfaces.append(surface)

	# Triangulate as a fan from the first point.
	var indices := PackedInt32Array()
	for i in range(1, points.size() - 1):
		indices.append(base)
		indices.append(base + i)
		indices.append(base + i + 1)
	face_indices.append(indices)

	for i in points.size():
		vertex_faces.append(face)


## Adds a convex, planar face whose vertex normals all equal its face normal.
func add_flat_face(points: PackedVector3Array, point_uvs: PackedVector2Array,
		face_normal: Vector3, surface := 0) -> void:
	var point_normals := PackedVector3Array()
	point_normals.resize(points.size())
	point_normals.fill(face_normal)
	add_face(points, point_normals, point_uvs, face_normal, surface)


## Call once all faces have been added.
func finish() -> void:
	if positions.is_empty():
		return
	var bounds := AABB(positions[0], Vector3.ZERO)
	for p in positions:
		bounds = bounds.expand(p)
	sort_point = bounds.get_center()
