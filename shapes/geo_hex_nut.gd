@tool
class_name GeoHexNut
extends GeoShape
## A hex nut centered on its position, facing the camera (+z) when not rotated:
## a hexagonal prism with a round hole through it, with flat top and bottom
## sides.
##
## An example of a custom shape. It isn't convex, so it adds the hole's walls
## first: faces are drawn in the order they're added, and the walls are always
## behind the nut's outside faces (see GeoGeometry).

## Distance from the center to each corner.
@export_range(0.0, 128.0, 0.5, "or_greater") var radius := 8.0:
	set(value):
		radius = value
		_geometry_changed()

## Thickness along z.
@export_range(0.0, 64.0, 0.5, "or_greater") var thickness := 5.0:
	set(value):
		thickness = value
		_geometry_changed()

## 0 for no hole. Kept a little inside the flat sides.
@export_range(0.0, 128.0, 0.5, "or_greater") var hole_radius := 3.5:
	set(value):
		hole_radius = value
		_geometry_changed()

## Number of divisions around the hole.
@export_range(3, 64) var hole_segments := 12:
	set(value):
		hole_segments = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	var front := thickness / 2.0
	var back := -thickness / 2.0
	var apothem := radius * cos(PI / 6.0)
	var hole := clampf(hole_radius, 0.0, apothem * 0.95)

	# Directions to the hexagon's corners (left and right ones on the x axis).
	var corners := PackedVector2Array()
	for k in 6:
		corners.append(Vector2.from_angle(TAU * k / 6.0))

	# The hole's walls, facing its axis, with smooth normals.
	var hole_directions := PackedVector2Array()
	for i in hole_segments + 1:
		hole_directions.append(Vector2.from_angle(TAU * i / hole_segments))
	if hole > 0.0 and thickness > 0.0:
		for i in hole_segments:
			var d0 := hole_directions[i]
			var d1 := hole_directions[i + 1]
			var n0 := Vector3(-d0.x, -d0.y, 0.0)
			var n1 := Vector3(-d1.x, -d1.y, 0.0)
			var u0 := float(i) / hole_segments
			var u1 := float(i + 1) / hole_segments
			geometry.add_face(
					PackedVector3Array([_at(d0 * hole, front), _at(d1 * hole, front),
							_at(d1 * hole, back), _at(d0 * hole, back)]),
					PackedVector3Array([n0, n1, n1, n0]),
					PackedVector2Array([Vector2(u0, 0), Vector2(u1, 0), Vector2(u1, 1),
							Vector2(u0, 1)]),
					(n0 + n1).normalized(), 0)

	# The six flat sides. Neighbors alternate surfaces, so creases between
	# them can be outlined.
	if thickness > 0.0:
		for k in 6:
			var c0 := corners[k] * radius
			var c1 := corners[(k + 1) % 6] * radius
			var normal_2d := Vector2.from_angle(TAU * (k + 0.5) / 6.0)
			geometry.add_flat_face(
					PackedVector3Array([_at(c0, front), _at(c1, front), _at(c1, back),
							_at(c0, back)]),
					PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
							Vector2(0, 1)]),
					Vector3(normal_2d.x, normal_2d.y, 0.0), k % 2)

	# The front and back faces.
	for side: Array in [[front, Vector3.BACK], [back, Vector3.FORWARD]]:
		var z: float = side[0]
		var normal: Vector3 = side[1]
		if hole <= 0.0:
			var points := PackedVector3Array()
			var uvs := PackedVector2Array()
			for c in corners:
				points.append(_at(c * radius, z))
				uvs.append(_face_uv(c * radius))
			geometry.add_flat_face(points, uvs, normal, 2)
			continue
		# A ring isn't convex, so split it into one convex piece per hole
		# segment: from the hole's edge out to the hexagon, including any
		# corner in between.
		for i in hole_segments:
			var a0 := TAU * i / hole_segments
			var a1 := TAU * (i + 1) / hole_segments
			var outline := PackedVector2Array([hole_directions[i] * hole,
					hole_directions[i + 1] * hole, _hexagon_point(a1, apothem)])
			for k in range(5, -1, -1):
				var corner_angle := TAU * k / 6.0
				if corner_angle > a0 + 0.0001 and corner_angle < a1 - 0.0001:
					outline.append(corners[k] * radius)
			outline.append(_hexagon_point(a0, apothem))
			var points := PackedVector3Array()
			var uvs := PackedVector2Array()
			for p in outline:
				points.append(_at(p, z))
				uvs.append(_face_uv(p))
			geometry.add_flat_face(points, uvs, normal, 2)


func _at(point: Vector2, z: float) -> Vector3:
	return Vector3(point.x, point.y, z)


func _face_uv(point: Vector2) -> Vector2:
	return point / (radius * 2.0) + Vector2(0.5, 0.5) if radius > 0.0 else Vector2(0.5, 0.5)


# The point on the hexagon's edge in the direction of angle.
func _hexagon_point(angle: float, apothem: float) -> Vector2:
	var side_center := (floorf(angle / (TAU / 6.0)) + 0.5) * TAU / 6.0
	return Vector2.from_angle(angle) * apothem / cos(angle - side_center)
