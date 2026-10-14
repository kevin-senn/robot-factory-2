@tool
class_name GeoBox
extends GeoShape
## A box centered on its position.

@export_custom(PROPERTY_HINT_RANGE, "0,128,0.5,or_greater")
var size := Vector3(32.0, 32.0, 32.0):
	set(value):
		size = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	# Each face's u and v axes are its right and down directions when viewed
	# from outside, so its UVs read naturally.
	_add_face(geometry, Vector3.BACK, Vector3.RIGHT, Vector3.UP, 0) # Front (+z).
	_add_face(geometry, Vector3.FORWARD, Vector3.LEFT, Vector3.UP, 0) # Back.
	_add_face(geometry, Vector3.RIGHT, Vector3.FORWARD, Vector3.UP, 1)
	_add_face(geometry, Vector3.LEFT, Vector3.BACK, Vector3.UP, 1)
	_add_face(geometry, Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, 2) # Top (-y).
	_add_face(geometry, Vector3.UP, Vector3.RIGHT, Vector3.FORWARD, 2) # Bottom.


# Note that Godot's 3D constants assume y is up and -z is forward. In this
# space, y is down and +z is toward the camera, so DOWN is the top, UP is the
# bottom, and BACK is the front.
func _add_face(geometry: GeoGeometry, normal: Vector3, u: Vector3, v: Vector3,
		surface: int) -> void:
	var half := size / 2.0
	var center := normal * half
	var half_u := u * half
	var half_v := v * half
	geometry.add_flat_face(
			PackedVector3Array([
				center - half_u - half_v,
				center + half_u - half_v,
				center + half_u + half_v,
				center - half_u + half_v,
			]),
			PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]),
			normal, surface)
