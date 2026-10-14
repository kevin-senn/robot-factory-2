@tool
class_name GeoLine
extends GeoShape
## A line from its position to end, drawn as a thin rod so it keeps its
## thickness from any angle. With a bend, it's a smooth curve.
##
## A curved line isn't convex, so where it curves back across itself (seen
## from the camera), its parts may overlap in the wrong order. Thin lines in a
## single color hide this.

## The other end of the line, relative to its position.
@export var end := Vector3(0.0, -16.0, 0.0):
	set(value):
		end = value
		_geometry_changed()

## Curves the line, by moving its middle control point this far from the
## straight line's middle. (The line is a quadratic Bézier curve, so it bends
## about half this far.)
@export var bend := Vector3.ZERO:
	set(value):
		bend = value
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

## Number of straight sections a bent line is made of.
@export_range(1, 32) var curve_segments := 6:
	set(value):
		curve_segments = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	if end.is_zero_approx():
		return
	var control := end / 2.0 + bend
	var section_count := 1 if bend.is_zero_approx() else curve_segments
	var centers := PackedVector3Array()
	var tangents := PackedVector3Array()
	for i in section_count + 1:
		var t := float(i) / section_count
		centers.append(2.0 * (1.0 - t) * t * control + t * t * end)
		var tangent := 2.0 * (1.0 - t) * control + 2.0 * t * (end - control)
		tangents.append(tangent.normalized() if not tangent.is_zero_approx() else end.normalized())

	# A ring of directions around the rod at each center. Each ring's frame is
	# the previous one turned to the new tangent, so the rod doesn't twist.
	var radius := thickness / 2.0
	var axis := tangents[0]
	var side := axis.cross(Vector3.BACK if absf(axis.z) < 0.9 else Vector3.RIGHT).normalized()
	var rings: Array[PackedVector3Array] = []
	for c in centers.size():
		if c > 0:
			var turn := tangents[c - 1].cross(tangents[c])
			if not turn.is_zero_approx():
				side = side.rotated(turn.normalized(),
						tangents[c - 1].angle_to(tangents[c])).normalized()
		var up := side.cross(tangents[c])
		var ring := PackedVector3Array()
		for i in segments + 1:
			var angle := TAU * i / segments
			ring.append(side * cos(angle) + up * sin(angle))
		rings.append(ring)

	# Sides, with smooth normals. u goes around; v goes from start to end.
	for c in section_count:
		var v0 := float(c) / section_count
		var v1 := float(c + 1) / section_count
		for i in segments:
			var u0 := float(i) / segments
			var u1 := float(i + 1) / segments
			var normals := PackedVector3Array([rings[c][i], rings[c][i + 1],
					rings[c + 1][i + 1], rings[c + 1][i]])
			geometry.add_face(
					PackedVector3Array([
						centers[c] + normals[0] * radius,
						centers[c] + normals[1] * radius,
						centers[c + 1] + normals[2] * radius,
						centers[c + 1] + normals[3] * radius,
					]),
					normals,
					PackedVector2Array([Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1),
							Vector2(u0, v1)]),
					(normals[0] + normals[1] + normals[2] + normals[3]).normalized())

	# Ends.
	for cap: Array in [[0, -tangents[0]], [centers.size() - 1, tangents[tangents.size() - 1]]]:
		var c: int = cap[0]
		var points := PackedVector3Array()
		var uvs := PackedVector2Array()
		for i in segments:
			points.append(centers[c] + rings[c][i] * radius)
			var angle := TAU * i / segments
			uvs.append(Vector2(cos(angle), sin(angle)) * 0.5 + Vector2(0.5, 0.5))
		geometry.add_flat_face(points, uvs, cap[1], 1)
