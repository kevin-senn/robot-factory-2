@tool
class_name GeoTriangle
extends GeoShape
## A triangle in the XY plane, facing the camera (+z) when not rotated. With a
## depth, it's a solid wedge (a triangular prism) centered on that plane.

@export var point_a := Vector2(-8.0, -8.0):
	set(value):
		point_a = value
		_geometry_changed()

@export var point_b := Vector2(8.0, -8.0):
	set(value):
		point_b = value
		_geometry_changed()

@export var point_c := Vector2(-8.0, 8.0):
	set(value):
		point_c = value
		_geometry_changed()

## Thickness along z. 0 makes a flat triangle.
@export_range(0.0, 64.0, 0.1, "or_greater") var depth := 0.0:
	set(value):
		depth = value
		_geometry_changed()

## If false, a flat triangle disappears when it faces away from the camera.
## (Solid wedges always have both sides.)
@export var double_sided := false:
	set(value):
		double_sided = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	var corners := PackedVector2Array([point_a, point_b, point_c])
	var uvs := PackedVector2Array()
	var bounds := Rect2(point_a, Vector2.ZERO).expand(point_b).expand(point_c)
	for corner in corners:
		uvs.append((corner - bounds.position) / bounds.size.max(Vector2(0.001, 0.001)))

	var half_depth := depth / 2.0
	var front := PackedVector3Array()
	var back := PackedVector3Array()
	for corner in corners:
		front.append(Vector3(corner.x, corner.y, half_depth))
		back.append(Vector3(corner.x, corner.y, -half_depth))
	geometry.add_flat_face(front, uvs, Vector3.BACK)
	if depth <= 0.0 and not double_sided:
		return
	var back_uvs := PackedVector2Array()
	for uv in uvs:
		back_uvs.append(Vector2(1.0 - uv.x, uv.y))
	geometry.add_flat_face(back, back_uvs, Vector3.FORWARD)
	if depth <= 0.0:
		return

	# Sides. Up to two can be visible at once, next to each other, but there
	# are only enough surfaces for two of the three to differ.
	var center := (point_a + point_b + point_c) / 3.0
	for i in 3:
		var p0 := corners[i]
		var p1 := corners[(i + 1) % 3]
		var outward := (p1 - p0).orthogonal().normalized()
		if outward.dot(p0 - center) < 0.0:
			outward = -outward
		geometry.add_flat_face(
				PackedVector3Array([front[i], front[(i + 1) % 3], back[(i + 1) % 3], back[i]]),
				PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]),
				Vector3(outward.x, outward.y, 0.0), 1 if i != 1 else 2)
