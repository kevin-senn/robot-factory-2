@tool
class_name GeoCylinder
extends GeoShape
## A vertical cylinder centered on its position.

@export var radius := 8.0:
	set(value):
		radius = value
		_geometry_changed()

@export var height := 16.0:
	set(value):
		height = value
		_geometry_changed()

@export_range(3, 64) var segments := 16:
	set(value):
		segments = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	var top := Vector3(0.0, -height / 2.0, 0.0)
	var bottom := Vector3(0.0, height / 2.0, 0.0)
	var directions := PackedVector3Array()
	for i in segments + 1:
		var angle := TAU * i / segments
		directions.append(Vector3(cos(angle), 0.0, sin(angle)))

	# Sides, with smooth (radial) normals. u goes around; v goes top to bottom.
	for i in segments:
		var d0 := directions[i]
		var d1 := directions[i + 1]
		var u0 := float(i) / segments
		var u1 := float(i + 1) / segments
		geometry.add_face(
				PackedVector3Array([top + d0 * radius, top + d1 * radius,
						bottom + d1 * radius, bottom + d0 * radius]),
				PackedVector3Array([d0, d1, d1, d0]),
				PackedVector2Array([Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, 1), Vector2(u0, 1)]),
				(d0 + d1).normalized())

	# Caps.
	for cap: Array in [[top, Vector3.DOWN], [bottom, Vector3.UP]]:
		var center: Vector3 = cap[0]
		var points := PackedVector3Array()
		var uvs := PackedVector2Array()
		for i in segments:
			var d := directions[i]
			points.append(center + d * radius)
			uvs.append(Vector2(d.x, d.z) * 0.5 + Vector2(0.5, 0.5))
		geometry.add_flat_face(points, uvs, cap[1], 1)
