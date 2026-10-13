@tool
class_name GeoSphere
extends GeoShape
## A sphere centered on its position, or the top part of one (a dome) when the
## sweep is less than 180 degrees.

@export var radius := 16.0:
	set(value):
		radius = value
		_geometry_changed()

## How far down from the top of the sphere the surface goes. 180 is a whole
## sphere; 90 is a dome (a hemisphere) whose flat base is at its position.
@export_range(1.0, 180.0, 1.0, "suffix:°") var sweep_degrees := 180.0:
	set(value):
		sweep_degrees = value
		_geometry_changed()

## Number of divisions around the vertical axis.
@export_range(3, 64) var segments := 16:
	set(value):
		segments = value
		_geometry_changed()

## Number of divisions from the top to the bottom of the sweep.
@export_range(1, 32) var rings := 6:
	set(value):
		rings = value
		_geometry_changed()


func _build_geometry(geometry: GeoGeometry) -> void:
	var sweep := deg_to_rad(sweep_degrees)

	# Surface, with smooth normals. u goes around; v goes top to bottom.
	for ring in rings:
		for segment in segments:
			var corners: Array[Vector2i] = [
				Vector2i(segment, ring),
				Vector2i(segment + 1, ring),
				Vector2i(segment + 1, ring + 1),
				Vector2i(segment, ring + 1),
			]
			if ring == 0:
				corners.remove_at(1) # The top two corners are both the top pole.
			var points := PackedVector3Array()
			var point_normals := PackedVector3Array()
			var uvs := PackedVector2Array()
			var face_normal := Vector3.ZERO
			for corner in corners:
				var direction := _direction(corner, sweep)
				points.append(direction * radius)
				point_normals.append(direction)
				uvs.append(Vector2(float(corner.x) / segments, float(corner.y) / rings))
				face_normal += direction
			geometry.add_face(points, point_normals, uvs, face_normal.normalized())

	# Flat base.
	if sweep_degrees < 180.0:
		var points := PackedVector3Array()
		var uvs := PackedVector2Array()
		for segment in segments:
			var direction := _direction(Vector2i(segment, rings), sweep)
			points.append(direction * radius)
			var flat := Vector2(direction.x, direction.z).normalized()
			uvs.append(flat * 0.5 + Vector2(0.5, 0.5))
		geometry.add_flat_face(points, uvs, Vector3.UP, 1) # Down, in this space.


func _direction(corner: Vector2i, sweep: float) -> Vector3:
	var around := TAU * corner.x / segments
	var down := sweep * corner.y / rings
	return Vector3(sin(down) * cos(around), -cos(down), sin(down) * sin(around))
