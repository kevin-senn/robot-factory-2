@tool
class_name GeoPanel
extends GeoShape
## A flat rectangle centered on its position, facing the camera (+z) when not
## rotated. Useful for details on the surface of other shapes.

@export var size := Vector2(16.0, 16.0):
	set(value):
		size = value
		_geometry_changed()

## If false, the panel disappears when it faces away from the camera.
@export var double_sided := false:
	set(value):
		double_sided = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	var half := size / 2.0
	var points := PackedVector3Array([
		Vector3(-half.x, -half.y, 0.0),
		Vector3(half.x, -half.y, 0.0),
		Vector3(half.x, half.y, 0.0),
		Vector3(-half.x, half.y, 0.0),
	])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	geometry.add_flat_face(points, uvs, Vector3.BACK)
	if double_sided:
		# Mirror u, so the back reads correctly when viewed from behind.
		var back_uvs := PackedVector2Array()
		for uv in uvs:
			back_uvs.append(Vector2(1.0 - uv.x, uv.y))
		geometry.add_flat_face(points, back_uvs, Vector3.FORWARD)
