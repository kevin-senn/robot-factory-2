extends Node2D
## Fires a cannonball at a BasicBot, which explodes when the ball reaches it,
## with an intensity based on the ball's speed (set with the slider). Then the
## bot reassembles and the ball fires again.

## Ball speed, in pixels per second, that makes an intensity 1 explosion.
@export var full_intensity_speed := 1500.0
## How close the ball's center gets to the bot's body before it hits.
@export var hit_distance := 168.0
## Seconds to wait after the pieces fade before firing again.
@export var pause_after_explosion := 0.5

var _ball_start := Vector2.ZERO
var _has_hit := false

@onready var _bot: GeoFigure = $BasicBot
@onready var _ball: GeoFigure = $Cannonball
@onready var _speed_slider: HSlider = $SpeedSlider
@onready var _speed_label: Label = $SpeedLabel


func _ready() -> void:
	_ball_start = _ball.position
	_speed_slider.value_changed.connect(_on_speed_changed)
	_on_speed_changed(_speed_slider.value)
	_bot.explosion_finished.connect(_on_explosion_finished)


func _process(delta: float) -> void:
	_ball.position.x += _speed_slider.value * delta
	if not _has_hit and _ball.position.x >= _bot.position.x - hit_distance:
		_has_hit = true
		_bot.explode(Vector2.RIGHT, _get_intensity())


func _get_intensity() -> float:
	return clampf(_speed_slider.value / full_intensity_speed, 0.0, 1.0)


func _on_speed_changed(speed: float) -> void:
	_speed_label.text = "Ball speed: %d px/s (intensity %.2f)" % [speed, _get_intensity()]


func _on_explosion_finished() -> void:
	await get_tree().create_timer(pause_after_explosion).timeout
	_bot.reassemble()
	_ball.position = _ball_start
	_has_hit = false
