extends Node2D
## Spins the GeoFigures in the "spinning" group (starting from their own Y
## rotations), and turns their domes back and forth.

@export var spin_degrees_per_second := 60.0

var _spinning_figures: Array[GeoFigure] = []
var _base_rotations := PackedFloat32Array()
var _time := 0.0


func _ready() -> void:
	for node in get_tree().get_nodes_in_group(&"spinning"):
		var figure := node as GeoFigure
		if figure:
			_spinning_figures.append(figure)
			_base_rotations.append(figure.model_rotation_degrees.y)


func _process(delta: float) -> void:
	_time += delta
	for i in _spinning_figures.size():
		var figure := _spinning_figures[i]
		figure.model_rotation_degrees.y = fmod(
				_base_rotations[i] + _time * spin_degrees_per_second, 360.0)
		# Turn the dome back and forth relative to the body, for this figure only.
		figure.set_shape_rotation_degrees(&"dome", Vector3(0.0, sin(_time * 2.0) * 50.0, 0.0))
