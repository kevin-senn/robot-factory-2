@tool
class_name GeoDisc
extends GeoShape
## A flat circle or ellipse centered on its position, facing the camera (+z)
## when not rotated. Can be cut down to an arc, e.g. a semicircle.

@export var radius := Vector2(8.0, 8.0):
	set(value):
		radius = value
		_geometry_changed()

@export_range(1.0, 360.0, 1.0, "suffix:°") var arc_degrees := 360.0:
	set(value):
		arc_degrees = value
		_geometry_changed()

## Where the arc starts. 0 is to the right; angles go clockwise on screen. A
## semicircle with an arc start of 180 is the top half of a circle.
@export_range(-360.0, 360.0, 1.0, "suffix:°") var arc_start_degrees := 0.0:
	set(value):
		arc_start_degrees = value
		_geometry_changed()

@export_range(3, 64) var segments := 24:
	set(value):
		segments = value
		_geometry_changed()

## If false, the disc disappears when it faces away from the camera.
@export var double_sided := false:
	set(value):
		double_sided = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	# A fan around the center, which also works for arcs over 180 degrees.
	var points := PackedVector3Array([Vector3.ZERO])
	var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
	var start := deg_to_rad(arc_start_degrees)
	var arc := deg_to_rad(arc_degrees)
	var point_count := maxi(2, ceili(segments * arc_degrees / 360.0) + 1)
	for i in point_count:
		var direction := Vector2.from_angle(start + arc * i / (point_count - 1))
		points.append(Vector3(direction.x * radius.x, direction.y * radius.y, 0.0))
		uvs.append(direction * 0.5 + Vector2(0.5, 0.5))
	geometry.add_flat_face(points, uvs, Vector3.BACK)
	if double_sided:
		var back_uvs := PackedVector2Array()
		for uv in uvs:
			back_uvs.append(Vector2(1.0 - uv.x, uv.y))
		geometry.add_flat_face(points, back_uvs, Vector3.FORWARD)
