@tool
class_name GeoCylinder
extends GeoShape
## A vertical cylinder centered on its position. Its top and bottom edges can be
## rounded off.

@export_range(0.0, 128.0, 0.5, "or_greater") var radius := 8.0:
	set(value):
		radius = value
		_geometry_changed()

@export_range(0.0, 128.0, 0.5, "or_greater") var height := 16.0:
	set(value):
		height = value
		_geometry_changed()

## Radius of the rounding where the side meets the top. 0 is a sharp edge; the
## radius (with enough height) makes the top a dome.
@export_range(0.0, 64.0, 0.5, "or_greater") var top_rounding := 0.0:
	set(value):
		top_rounding = value
		_geometry_changed()

## Radius of the rounding where the side meets the bottom.
@export_range(0.0, 64.0, 0.5, "or_greater") var bottom_rounding := 0.0:
	set(value):
		bottom_rounding = value
		_geometry_changed()

## Number of divisions around the vertical axis.
@export_range(3, 64) var segments := 16:
	set(value):
		segments = value
		_geometry_changed()

## Number of divisions along each rounded edge.
@export_range(1, 16) var rounding_segments := 3:
	set(value):
		rounding_segments = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	# Fit the roundings within the radius and height.
	var top_r := clampf(top_rounding, 0.0, radius)
	var bottom_r := clampf(bottom_rounding, 0.0, radius)
	if top_r + bottom_r > height:
		var fit := height / (top_r + bottom_r)
		top_r *= fit
		bottom_r *= fit
	var top := -height / 2.0
	var bottom := height / 2.0

	# The profile from the bottom edge, up the side, to the top edge, as
	# (distance from axis, y) points with outward (radial, y) normals.
	var profile := PackedVector2Array()
	var profile_normals := PackedVector2Array()
	if bottom_r > 0.0:
		var center := Vector2(radius - bottom_r, bottom - bottom_r)
		for i in rounding_segments + 1:
			var angle := PI / 2.0 * i / rounding_segments
			var normal := Vector2(sin(angle), cos(angle)) # Down, then outward.
			profile.append(center + normal * bottom_r)
			profile_normals.append(normal)
	else:
		profile.append(Vector2(radius, bottom))
		profile_normals.append(Vector2.RIGHT)
	if top_r > 0.0:
		var center := Vector2(radius - top_r, top + top_r)
		for i in rounding_segments + 1:
			var angle := PI / 2.0 * i / rounding_segments
			var normal := Vector2(cos(angle), -sin(angle)) # Outward, then up.
			profile.append(center + normal * top_r)
			profile_normals.append(normal)
	else:
		profile.append(Vector2(radius, top))
		profile_normals.append(Vector2.RIGHT)

	var directions := PackedVector3Array()
	for i in segments + 1:
		var angle := TAU * i / segments
		directions.append(Vector3(cos(angle), 0.0, sin(angle)))

	# Bands between consecutive profile points, with smooth normals. u goes
	# around; v goes from the bottom of the profile to the top.
	for p in profile.size() - 1:
		var p0 := profile[p]
		var p1 := profile[p + 1]
		if p0.is_equal_approx(p1):
			continue
		var n0 := profile_normals[p]
		var n1 := profile_normals[p + 1]
		var v0 := 1.0 - float(p) / (profile.size() - 1)
		var v1 := 1.0 - float(p + 1) / (profile.size() - 1)
		for i in segments:
			var d0 := directions[i]
			var d1 := directions[i + 1]
			var u0 := float(i) / segments
			var u1 := float(i + 1) / segments
			var normals := PackedVector3Array([
				_revolve(n0, d0), _revolve(n0, d1), _revolve(n1, d1), _revolve(n1, d0)])
			geometry.add_face(
					PackedVector3Array([_revolve(p0, d0), _revolve(p0, d1),
							_revolve(p1, d1), _revolve(p1, d0)]),
					normals,
					PackedVector2Array([Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1),
							Vector2(u0, v1)]),
					(normals[0] + normals[1] + normals[2] + normals[3]).normalized())

	# Flat caps. A sharp edge is a crease, so the cap gets its own surface;
	# a rounded one blends smoothly into the side.
	_add_cap(geometry, profile[profile.size() - 1], Vector3.DOWN, directions,
			0 if top_r > 0.0 else 1)
	_add_cap(geometry, profile[0], Vector3.UP, directions, 0 if bottom_r > 0.0 else 1)


# Note that y is down in this space, so Vector3.DOWN is up (the top cap).
func _add_cap(geometry: GeoGeometry, edge: Vector2, normal: Vector3,
		directions: PackedVector3Array, surface: int) -> void:
	if edge.x <= 0.001:
		return
	var points := PackedVector3Array()
	var uvs := PackedVector2Array()
	for i in segments:
		var d := directions[i]
		points.append(_revolve(edge, d))
		uvs.append(Vector2(d.x, d.z) * 0.5 + Vector2(0.5, 0.5))
	geometry.add_flat_face(points, uvs, normal, surface)


# Turns a profile point or normal (distance from axis, y) into 3D, in the
# given direction around the axis.
static func _revolve(point: Vector2, direction: Vector3) -> Vector3:
	return direction * point.x + Vector3(0.0, point.y, 0.0)
