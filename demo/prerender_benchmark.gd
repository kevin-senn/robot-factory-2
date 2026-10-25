extends Node2D
## Compares the cost of many animating GeoFigures ("live") with AnimatedSprite2Ds
## playing frames pre-rendered from the same animation ("sprites"), to decide
## whether pre-rendering figures to sprite sheets is worth it.
##
## Space switches between the modes; Up and Down change the count. Vsync is off.
## "update" is the CPU time per frame from processing to rendering (animation,
## scripts and the figures' _draw); it's the fairest comparison, since FPS can be
## capped by the display driver after slow frames.

@export var shape: GeoShape = preload("res://demo/basic_bot.tres")
@export var animation_name := &"bouncy_idle"
@export var count := 200
## Frames captured per second of animation for the sprites.
@export var capture_fps := 12.0
@export var model_rotation_degrees := Vector3(0.0, -45.0, 0.0)
@export var spacing := Vector2(40.0, 56.0)

## Whether the sprites are shown instead of live figures.
var sprite_mode := false

var _frames: SpriteFrames
var _items: Array[Node2D] = []
var _stats := Label.new()
# CPU time from the start of each frame's process step to the start of
# rendering (animation, scripts and figures' _draw), smoothed.
var _update_ms := 0.0
var _process_start := 0

const _CAPTURE_SIZE := Vector2i(128, 128)


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_stats.position = Vector2(8, 8)
	_stats.z_index = 10
	add_child(_stats)
	_stats.text = "Capturing frames..."
	get_tree().process_frame.connect(func() -> void: _process_start = Time.get_ticks_usec())
	RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
	await _capture_frames()
	_spawn()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if not key or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_SPACE:
			set_mode(not sprite_mode)
		KEY_UP:
			set_count(count * 2)
		KEY_DOWN:
			set_count(maxi(count / 2, 1))


func _process(_delta: float) -> void:
	_stats.text = "%s: %d figures   %d FPS   update %.2f ms   draw calls %d\n%s" % [
		"Sprites" if sprite_mode else "Live GeoFigures", _items.size(),
		Engine.get_frames_per_second(), _update_ms,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"Space: switch mode   Up/Down: count x2 / ÷2"]


func _on_frame_pre_draw() -> void:
	if _process_start > 0:
		_update_ms = lerpf(_update_ms, (Time.get_ticks_usec() - _process_start) / 1000.0, 0.1)


func set_mode(sprites: bool) -> void:
	sprite_mode = sprites
	_spawn()


func set_count(new_count: int) -> void:
	count = new_count
	_spawn()


## Whether the frames have been captured (and the benchmark is running).
func is_ready() -> bool:
	return _frames != null


func _spawn() -> void:
	for item in _items:
		item.queue_free()
	_items.clear()
	if not _frames:
		return
	var columns := maxi(int((get_viewport_rect().size.x - spacing.x) / spacing.x), 1)
	var library := shape.animations
	var length := library.get_animation(animation_name).length
	for i in count:
		var at := Vector2(spacing.x * 0.75, spacing.y * 2.0) \
				+ Vector2(i % columns, i / columns) * spacing
		var start := fmod(i * 0.37, length)
		var item: Node2D
		if sprite_mode:
			var sprite := AnimatedSprite2D.new()
			sprite.sprite_frames = _frames
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			sprite.offset = Vector2(0.0, -_CAPTURE_SIZE.y * 0.35)
			sprite.scale = Vector2(0.5, 0.5)
			sprite.play(animation_name)
			sprite.frame = int(start * capture_fps) % _frames.get_frame_count(animation_name)
			item = sprite
		else:
			var figure := _make_figure(library)
			figure.scale = Vector2(0.5, 0.5)
			var player: AnimationPlayer = figure.get_child(0)
			player.play(animation_name)
			player.seek(start, true)
			item = figure
		item.position = at
		add_child(item)
		_items.append(item)


func _make_figure(library: AnimationLibrary) -> GeoFigure:
	var figure := GeoFigure.new()
	figure.shape = shape
	figure.model_rotation_degrees = model_rotation_degrees
	var player := AnimationPlayer.new()
	player.add_animation_library(&"", library)
	figure.add_child(player)
	return figure


# Renders the animation at capture_fps through a SubViewport into _frames.
func _capture_frames() -> void:
	var viewport := SubViewport.new()
	viewport.size = _CAPTURE_SIZE
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	var figure := _make_figure(shape.animations)
	figure.position = Vector2(_CAPTURE_SIZE.x * 0.5, _CAPTURE_SIZE.y * 0.85)
	viewport.add_child(figure)
	var player: AnimationPlayer = figure.get_child(0)
	player.play(animation_name)
	player.pause()
	var frames := SpriteFrames.new()
	frames.remove_animation(&"default")
	frames.add_animation(animation_name)
	frames.set_animation_speed(animation_name, capture_fps)
	frames.set_animation_loop(animation_name, true)
	var length := shape.animations.get_animation(animation_name).length
	var frame_count := maxi(roundi(length * capture_fps), 1)
	for i in frame_count:
		player.seek(i / capture_fps, true)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var image := viewport.get_texture().get_image()
		frames.add_frame(animation_name, ImageTexture.create_from_image(image))
	viewport.queue_free()
	_frames = frames
