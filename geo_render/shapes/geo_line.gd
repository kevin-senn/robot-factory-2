@tool
class_name GeoLine
extends GeoShape
## A straight line from its position to end, drawn as a thin rod so it keeps
## its thickness from any angle.

## The other end of the line, relative to its position.
@export var end := Vector3(0.0, -16.0, 0.0):
	set(value):
		end = value
		_geometry_changed()

@export_range(0.1, 16.0, 0.1, "or_greater") var thickness := 2.0:
	set(value):
		thickness = value
		_geometry_changed()

## Number of sides of the rod.
@export_range(3, 16) var segments := 6:
	set(value):
		segments = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	if end.is_zero_approx():
		return
	var axis := end.normalized()
	var side := axis.cross(Vector3.BACK if absf(axis.z) < 0.9 else Vector3.RIGHT).normalized()
	var up := side.cross(axis)
	var radius := thickness / 2.0
	var directions := PackedVector3Array()
	for i in segments + 1:
		var angle := TAU * i / segments
		directions.append(side * cos(angle) + up * sin(angle))

	# Sides, with smooth normals. u goes around; v goes from start to end.
	for i in segments:
		var d0 := directions[i]
		var d1 := directions[i + 1]
		var u0 := float(i) / segments
		var u1 := float(i + 1) / segments
		geometry.add_face(
				PackedVector3Array([d0 * radius, d1 * radius, end + d1 * radius,
						end + d0 * radius]),
				PackedVector3Array([d0, d1, d1, d0]),
				PackedVector2Array([Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, 1), Vector2(u0, 1)]),
				(d0 + d1).normalized())

	# Ends.
	for cap: Array in [[Vector3.ZERO, -axis], [end, axis]]:
		var center: Vector3 = cap[0]
		var points := PackedVector3Array()
		var uvs := PackedVector2Array()
		for i in segments:
			points.append(center + directions[i] * radius)
			var angle := TAU * i / segments
			uvs.append(Vector2(cos(angle), sin(angle)) * 0.5 + Vector2(0.5, 0.5))
		geometry.add_flat_face(points, uvs, cap[1], 1)
