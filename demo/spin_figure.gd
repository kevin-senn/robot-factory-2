extends Node2D
## Spins a GeoFigure around its Y axis.

@export var figure: GeoFigure
@export var degrees_per_second := 60.0


func _process(delta: float) -> void:
	if figure:
		figure.model_rotation_degrees.y = fmod(
				figure.model_rotation_degrees.y + delta * degrees_per_second, 360.0)
