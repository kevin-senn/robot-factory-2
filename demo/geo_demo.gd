extends Node2D
## Shows the robot GeoFigure drawn a few ways, and animates one of them.

@export var spin_degrees_per_second := 60.0

var _time := 0.0

@onready var _spinning_robot: GeoFigure = $SpinningRobot


func _process(delta: float) -> void:
	_time += delta
	_spinning_robot.model_rotation_degrees.y = fmod(_time * spin_degrees_per_second, 360.0)
	# Turn the dome back and forth relative to the body, for this figure only.
	_spinning_robot.set_shape_rotation_degrees(&"dome", Vector3(0.0, sin(_time * 2.0) * 50.0, 0.0))
