extends Node2D
## Spawns many spinning GeoFigures to measure rendering cost.

@export var robot: GeoShape = preload("res://demo/robot.tres")
@export var count := 400
@export var columns := 25
@export var spacing := Vector2(44.0, 64.0)

var _figures: Array[GeoFigure] = []
var _time := 0.0

@onready var _stats: Label = $Stats


func _ready() -> void:
	for i in count:
		var figure := GeoFigure.new()
		figure.shape = robot
		figure.position = Vector2(30.0, 90.0) + Vector2(i % columns, i / columns) * spacing
		figure.scale = Vector2(0.7, 0.7)
		add_child(figure)
		_figures.append(figure)


func _process(delta: float) -> void:
	_time += delta
	for i in _figures.size():
		var figure := _figures[i]
		var t := _time + i * 0.37
		figure.model_rotation_degrees.y = fmod(t * 60.0, 360.0)
		figure.set_shape_rotation_degrees(&"dome", Vector3(0.0, sin(t * 2.0) * 50.0, 0.0))
	_stats.text = "%d figures, %d FPS, process %.1f ms" % [_figures.size(),
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0]
