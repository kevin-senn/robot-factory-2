@tool
class_name GeoFigure
extends Node2D
## Draws a tree of GeoShapes as fake-3D geometry, projected by an orthographic
## camera looking down at the figure from GeoCamera.elevation_degrees.
##
## The whole figure is a single mesh, drawn with a single draw call. Each
## redraw, it transforms every shape's vertices, culls back faces, and sorts
## shapes back to front, so shapes closer to the camera draw on top, then
## updates the mesh in place. Figures that don't change don't redraw. Sorting
## only happens within a figure; order figures against each other as you would
## any other CanvasItems (e.g. with y_sort_enabled on their parent).
##
## With a style (pixel art by default; see GeoStyle), the mesh is rendered
## into GeoPixelAtlas by the style's lighting material, one texel per
## pixel_size units, and the figure draws that, scaled up, with the style's
## display material, e.g. pixelated with outlines (pixel/geo_pixel_display.gdshader).
##
## With no style, the mesh is drawn directly, with this node's
## material. Set a ShaderMaterial there to shade the shapes. Either way, the
## mesh provides, per vertex:
## - VERTEX: the projected position.
## - COLOR: the shape's color (times modulate, as usual).
## - UV: face-local coordinates, from 0 to 1 across each face.
## - CUSTOM0.xyz: the view-space normal (x right, y down, z toward the camera).
##   Smooth across curved surfaces. Only readable in vertex(); pass it to
##   fragment() with a varying.
## - CUSTOM1.x: the index of the shape (depth-first, parents before children).
## - CUSTOM1.y: the index of the face within the shape.
## - CUSTOM1.z: the shape's position in this redraw's back-to-front draw order.
## - CUSTOM1.w: the face's surface (see GeoGeometry.face_surfaces) * 2, plus 1
##   if the shape isn't outlined (see GeoShape.outlined).
## See geo_shading_example.gdshader.

## Faces must point at least this much toward the camera to be drawn.
const _FACING_EPSILON := 0.0001

# The fields of each shape that figures can override (and animate), as the
# properties "shapes/<shape name>/<field>".
const _SHAPE_FIELDS: Array[StringName] = [&"position", &"rotation_degrees", &"scale", &"visible"]

# Property name -> [shape name, field] for "shapes/..." properties, or [] for
# any other property, so _get() and _set() don't parse names every call.
static var _property_parse_cache: Dictionary[StringName, Array] = {}

## The root of the shape tree to draw. Usually saved as its own resource, so
## many figures can share it.
@export var shape: GeoShape:
	set(value):
		if shape:
			shape.changed.disconnect(queue_redraw)
		shape = value
		if shape:
			shape.changed.connect(queue_redraw)
		_requested_frames = null
		queue_redraw()
		update_configuration_warnings()
		if _owns_player:
			_player.remove_animation_library(&"")
			if shape and shape.animations:
				_player.add_animation_library(&"", shape.animations)
		notify_property_list_changed()

@export var camera: GeoCamera = preload("res://addons/geo_render/default_geo_camera.tres"):
	set(value):
		if camera:
			camera.changed.disconnect(queue_redraw)
		camera = value
		_requested_frames = null
		if camera:
			camera.changed.connect(queue_redraw)
		queue_redraw()

## Rotates the whole figure in 3D, before it's projected. (Node2D.rotation
## instead rotates the projected image.)
@export_custom(PROPERTY_HINT_RANGE, "-180,180,1,or_less,or_greater,suffix:°")
var model_rotation_degrees := Vector3.ZERO:
	set(value):
		model_rotation_degrees = value
		_requested_frames = null
		queue_redraw()

## How the figure looks, e.g. pixel art (styles/pixel_art.tres) or cel shading
## (styles/cel.tres). See GeoStyle. If null, the figure is drawn as smooth
## geometry instead, with material.
@export var style: GeoStyle = preload("res://addons/geo_render/styles/pixel_art.tres"):
	set(value):
		if style and style.changed.is_connected(_on_style_changed):
			style.changed.disconnect(_on_style_changed)
		style = value
		if style:
			style.changed.connect(_on_style_changed)
		_on_style_changed()

## The color the whole figure flashes toward (e.g. white or red when hit).
## Needs a style.
@export var flash_color := Color.WHITE:
	set(value):
		flash_color = value
		set_instance_shader_parameter(&"flash_color", value)

## How far the figure is mixed toward flash_color, from 0 (not at all) to 1
## (a solid silhouette). Animate it for flashes.
@export_range(0.0, 1.0, 0.01) var flash_amount := 0.0:
	set(value):
		flash_amount = value
		set_instance_shader_parameter(&"flash_amount", value)

@export_group("Animation")
## The animation to play when the game starts (see play()).
@export var autoplay: StringName

## 0 plays animations smoothly. Otherwise they advance in steps of
## 1 / animation_fps seconds, like hand-drawn frames, though their keys stay
## smooth. Stepped figures also cost less, since they only change on each
## step. (Only in game: the editor's Animation panel always plays smoothly.)
@export_range(0, 60, 1, "or_greater", "suffix:fps") var animation_fps := 0:
	set(value):
		animation_fps = maxi(value, 0)
		_requested_frames = null
		_update_processing()

@export_group("Explosion")
## How long the pieces fly (and fade) for, in seconds.
@export_range(0.05, 10.0, 0.05, "or_greater", "suffix:s") var explosion_duration := 1.0
## How fast pieces fly at intensity 1, in local units per second.
@export_range(0.0, 1000.0, 1.0, "or_greater") var explosion_max_speed := 150.0
## How far pieces spin over the explosion at intensity 1.
@export_range(0.0, 3600.0, 1.0, "or_greater", "suffix:°") var explosion_max_spin_degrees := 720.0
## How far each piece's direction can stray from its evenly spaced slot, as a
## fraction of the angle between slots. Below 1, neighboring pieces never cross.
@export_range(0.0, 1.0, 0.05) var explosion_direction_jitter := 0.5
## The most a piece's direction tilts toward or away from the camera (z). Small
## values keep the spread visible on screen.
@export_range(0.0, 1.0, 0.05) var explosion_max_depth_tilt := 0.3
@export_group("")

## Emitted when an explosion's pieces have faded away.
signal explosion_finished

# This figure's copy of the model's mesh, updated in place each redraw.
var _mesh := RenderingServer.mesh_create()
var _mesh_model: GeoCompiledModel
# The mesh's attribute data, as an Image of 32-bit floats, one row per vertex.
# Each redraw, the new normals and draw ranks are copied into it. (Using Images
# to copy ranges of bytes keeps the work in native code.)
var _attributes: Image
var _normals_image := Image.new()

# When pixelated, this figure's cell in GeoPixelAtlas, and the canvas item that
# draws the mesh there.
var _atlas_cell := Rect2i()
var _atlas_item := RID()
# The material last set on this node's canvas item.
var _applied_material := RID()

# Per-figure overrides of shapes' fields (see _SHAPE_FIELDS): shape name ->
# field -> value.
var _overrides: Dictionary[StringName, Dictionary] = {}

# Each shape's transform relative to its parent, and whether it's hidden
# (itself or by an ancestor), with overrides applied.
var _pose: Array[Transform3D] = []
var _hidden := PackedByteArray()

# The current explosion: seconds since it started (-1 if not exploding), and,
# per shape, the index of the shape at the root of its piece. Pieces' velocities
# and spins (in view space) are stored at their roots' indices.
var _explosion_time := -1.0
var _piece_roots := PackedInt32Array()
var _piece_velocities := PackedVector3Array()
var _piece_spin_axes := PackedVector3Array()
var _piece_spin_angles := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()

# The player for play() (see get_animation_player()), whether this figure made
# it, its callback mode before stepping took it over, and the time not yet
# stepped.
var _player: AnimationPlayer
var _owns_player := false
var _player_callback_mode := AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
var _step_time := 0.0

# The cached frames drawn instead of the live shapes (see GeoAnimationCache),
# and which one. While they're drawn, the pose (_pose) isn't kept up to date;
# _pose_dirty says it needs rebuilding. _live_shapes is set when code overrides
# shapes, which cached frames can't show, until the next play() or stop().
var _cached_frames: GeoAnimationCache.Frames
var _cached_frame := -1
var _pose_dirty := false
var _live_shapes := false
# The frames last requested from GeoAnimationCache (maybe not built yet), and
# for which animation. Requested again when the view or frame rate changes.
var _requested_frames: GeoAnimationCache.Frames
var _requested_animation: Animation
# The pose sampled by _residual_pose(), and for which animation and time.
var _sampled_pose: Dictionary[StringName, Dictionary] = {}
var _sampled_animation: Animation
var _sampled_time := -1.0

# Set as the line_seed instance uniform (see GeoStyle.display_material): a
# random base per figure, plus the cached frame, or a count of live redraws.
var _line_seed_base := 0.0
var _redraw_count := 0


func _init() -> void:
	# The setters don't run for the default values.
	if camera:
		camera.changed.connect(queue_redraw)
	if style:
		style.changed.connect(_on_style_changed)
	_line_seed_base = _rng.randf() * 1000.0


func _ready() -> void:
	_update_processing()
	# The setters don't run for default values.
	set_instance_shader_parameter(&"flash_color", flash_color)
	set_instance_shader_parameter(&"flash_amount", flash_amount)
	if autoplay and not Engine.is_editor_hint():
		play(autoplay)


func _process(delta: float) -> void:
	if _is_stepping():
		if _player.is_playing():
			_step_time += delta
			var step := 1.0 / animation_fps
			if _step_time >= step:
				var steps := floorf(_step_time / step)
				_step_time -= steps * step
				_player.advance(steps * step) # advance() applies speed_scale itself.
		_update_cached_frames()
	if _is_explosion_running():
		_explosion_time = minf(_explosion_time + delta, explosion_duration)
		queue_redraw()
		if not _is_explosion_running():
			explosion_finished.emit()
	_update_processing()


## Plays an animation from shape.animations (or from a child AnimationPlayer's
## libraries, if the figure has one). With from_start false, an animation that's
## already playing carries on. Shape fields the animation doesn't set take their
## values from the RESET animation (the player is made deterministic).
func play(animation_name: StringName, from_start := true) -> void:
	var player := get_animation_player()
	if not player or not player.has_animation(animation_name):
		push_warning("GeoFigure has no animation named '%s'." % animation_name)
		return
	if from_start or player.assigned_animation != animation_name:
		player.play(animation_name)
		player.seek(0.0, true)
		# Stepped figures start their step clocks at random points, so figures
		# that start together don't all redraw in the same frames.
		_step_time = _rng.randf() / animation_fps if animation_fps > 0 else 0.0
	elif not player.is_playing():
		player.play()
	_update_processing()
	_live_shapes = false
	_update_cached_frames()


## Stops the playing animation, leaving the figure posed as it is.
func stop() -> void:
	if _player:
		_player.stop(true)
	_update_processing()
	_live_shapes = false
	_update_cached_frames()


func is_playing() -> bool:
	return _player != null and _player.is_playing()


## The AnimationPlayer that play() uses: a child AnimationPlayer, if the figure
## has one (e.g. so the Animation panel can edit its animations), else one made
## on first use from shape.animations, which isn't part of the scene (it's an
## internal child, never saved). Null if there are no animations.
func get_animation_player() -> AnimationPlayer:
	if _player and is_instance_valid(_player) and _player.get_parent() == self:
		return _player
	_player = null
	_owns_player = false
	for child in get_children():
		if child is AnimationPlayer:
			_player = child
			break
	if not _player and shape and shape.animations:
		_player = AnimationPlayer.new()
		_player.add_animation_library(&"", shape.animations)
		add_child(_player, false, INTERNAL_MODE_BACK)
		_owns_player = true
	if _player:
		_player_callback_mode = _player.callback_mode_process
		if not Engine.is_editor_hint():
			# Fields an animation doesn't set take their RESET values, rather than
			# whatever the last animation left (which cached frames can't know).
			_player.deterministic = true
	return _player


# Called before code overrides a shape: cached frames can't show that, so the
# figure renders live until the next play() or stop().
func _override_live() -> void:
	if not _live_shapes:
		_live_shapes = true
		_update_cached_frames()


# Switches between drawing cached frames and the live shapes, and picks the
# frame for the animation's time. With redraw, redraws if that changed what's
# drawn.
func _update_cached_frames(redraw := true) -> void:
	var frames := _usable_cached_frames()
	var frame := frames.frame_at(_player.current_animation_position) if frames else -1
	if frames == _cached_frames and frame == _cached_frame:
		return
	var was_cached := _cached_frames != null
	_cached_frames = frames
	_cached_frame = frame
	if was_cached != (frames != null):
		_use_residual_library(frames != null)
	if not frames and _pose_dirty and _mesh_model:
		_rebuild_pose()
	if redraw:
		queue_redraw()


# The cached frames of the animation being played, if the figure can draw them:
# in game, pixelated, stepped, not exploding and with no shapes overridden by
# code. Null if not (or if they're still being built).
func _usable_cached_frames() -> GeoAnimationCache.Frames:
	if Engine.is_editor_hint() or not GeoAnimationCache.enabled or not _is_styled() \
			or animation_fps <= 0 or _live_shapes or is_exploding() or not shape \
			or not _player or not is_instance_valid(_player):
		return null
	var animation := _source_animation(StringName(_player.assigned_animation))
	if not animation:
		return null
	if animation != _requested_animation or not _requested_frames or not _requested_frames.valid:
		_requested_frames = GeoAnimationCache.get_frames(self, animation, animation_fps)
		_requested_animation = animation
	return _requested_frames if _requested_frames.ready else null


# The animation with the given name, as the player has it (not the residual
# copy the figure's own player plays while drawing cached frames). Null if none.
func _source_animation(animation_name: StringName) -> Animation:
	if not animation_name or not _player:
		return null
	if _owns_player and shape and shape.animations:
		return shape.animations.get_animation(animation_name) \
				if shape.animations.has_animation(animation_name) else null
	return _player.get_animation(animation_name) if _player.has_animation(animation_name) else null


# Whether the figure's own player is playing the residual library, so nothing
# sets the shapes' fields (see _residual_pose()).
func _is_residual() -> bool:
	return _cached_frames != null and _owns_player and shape != null and shape.animations != null \
			and _player.get_animation_library(&"") != shape.animations


# While playing the residual library, the pose the full animation would set
# now, sampled when asked for (e.g. when code reads "shapes/..." properties).
func _residual_pose() -> Dictionary[StringName, Dictionary]:
	var animation := _source_animation(StringName(_player.assigned_animation))
	var time := _player.current_animation_position
	if animation != _sampled_animation or time != _sampled_time:
		_sampled_animation = animation
		_sampled_time = time
		var reset := _source_animation(&"RESET")
		var base: Dictionary[StringName, Dictionary] = _sample_overrides(reset, 0.0, self) \
				if reset else {}
		_sampled_pose = _sample_overrides(animation, time, self, base) if animation else base
	return _sampled_pose


# Switches the figure's own player between its full animation library and the
# residual one (without shape tracks, see GeoAnimationCache.residual_library())
# used while cached frames are drawn, carrying on from the same time. (A child
# AnimationPlayer is left alone; _set() keeps its shape tracks cheap instead.)
func _use_residual_library(residual: bool) -> void:
	if not _owns_player or not shape or not shape.animations:
		return
	var library := GeoAnimationCache.residual_library(shape.animations) if residual \
			else shape.animations
	if _player.get_animation_library(&"") == library:
		return
	var animation_name := StringName(_player.assigned_animation)
	var playing := _player.is_playing()
	var time := _player.current_animation_position if animation_name else 0.0
	_player.remove_animation_library(&"")
	_player.add_animation_library(&"", library)
	if animation_name:
		_player.play(animation_name)
		_player.seek(time, true)
		if not playing:
			_player.pause()


func _draw_cached_frame() -> void:
	var texel_size := style.get_texel_size(camera)
	var region := _cached_frames.regions[_cached_frame]
	RenderingServer.canvas_item_add_texture_rect_region(get_canvas_item(),
			Rect2(-_cached_frames.origin * texel_size, region.size * texel_size),
			_cached_frames.texture.get_rid(), region)
	set_instance_shader_parameter(&"line_seed", _line_seed_base + _cached_frame)


# Whether the figure is drawn with a style (through GeoPixelAtlas).
func _is_styled() -> bool:
	return style != null and style.lighting_material != null and style.display_material != null


func _on_style_changed() -> void:
	# The atlas item gets the new lighting material when it's made again.
	_release_atlas_cell()
	_requested_frames = null
	queue_redraw()


# For GeoAnimationCache: a mesh of the figure posed at each of times seconds
# into animation (with its shapes' own values for fields it doesn't animate),
# as [mesh RID, reach (see _update_mesh())]. Free the meshes when done.
func _make_frame_meshes(animation: Animation, times: PackedFloat32Array) -> Array:
	var result := []
	var model := shape.get_compiled()
	if model != _mesh_model:
		_set_model(model)
	if model.surface.is_empty():
		return result
	var root: Node = _player.get_node_or_null(_player.root_node) if _player else self
	# Like the (deterministic) AnimationPlayer, fields the
	# animation doesn't set take their RESET values.
	var base: Dictionary[StringName, Dictionary] = {}
	var reset := _source_animation(&"RESET")
	if reset:
		base = _sample_overrides(reset, 0.0, root)
	var saved := _overrides
	for time in times:
		_overrides = _sample_overrides(animation, time, root, base)
		_rebuild_pose()
		var mesh := RenderingServer.mesh_create()
		RenderingServer.mesh_add_surface(mesh, model.surface)
		var attributes := Image.create_from_data(model.attribute_stride / 4, model.vertex_count,
				false, Image.FORMAT_RF, model.surface.attribute_data)
		result.append([mesh, _update_mesh(mesh, attributes, model, _compute_transforms(model))])
	_overrides = saved
	_rebuild_pose()
	return result


# The shape fields animation sets on this figure at time, as overrides (shape
# name -> field -> value), on top of base. root is the node its track paths
# are relative to.
func _sample_overrides(animation: Animation, time: float, root: Node,
		base: Dictionary[StringName, Dictionary] = {}) -> Dictionary[StringName, Dictionary]:
	var overrides: Dictionary[StringName, Dictionary] = base.duplicate(true)
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_VALUE \
				or not animation.track_is_enabled(track) or animation.track_get_key_count(track) == 0:
			continue
		var path := animation.track_get_path(track)
		if path.get_subname_count() == 0:
			continue
		var parsed := _parse_shape_property(StringName(path.get_subname(0)))
		if parsed.is_empty() or (root and root.get_node_or_null(
				NodePath(path.get_concatenated_names())) != self):
			continue
		var found := _find_shape(parsed[0])
		if not found:
			continue
		var value: Variant
		if animation.value_track_get_update_mode(track) == Animation.UPDATE_CONTINUOUS:
			value = animation.value_track_interpolate(track, time)
		else:
			# Discrete (e.g. visible): the last key at or before time.
			value = animation.track_get_key_value(track, maxi(animation.track_find_key(track, time), 0))
		if not overrides.has(parsed[0]):
			overrides[parsed[0]] = {}
		var fields: Dictionary = overrides[parsed[0]]
		if path.get_subname_count() > 1:
			var whole: Variant = fields.get(parsed[1], found.get(parsed[1]))
			whole[path.get_subname(1)] = value
			value = whole
		fields[parsed[1]] = value
	return overrides


# Animations are stepped (by _process()) when animation_fps is set, in game.
func _is_stepping() -> bool:
	return animation_fps > 0 and _player != null and is_instance_valid(_player) \
			and not Engine.is_editor_hint()


# Whether pieces are still flying (an exploded figure stays exploded, faded
# out, until reassemble()).
func _is_explosion_running() -> bool:
	return is_exploding() and _explosion_time < explosion_duration


func _update_processing() -> void:
	var stepping := _is_stepping()
	if _player and is_instance_valid(_player) and not Engine.is_editor_hint():
		var mode := AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL if stepping \
				else _player_callback_mode
		if _player.callback_mode_process != mode:
			_player.callback_mode_process = mode
	set_process(stepping or _is_explosion_running())


## Breaks the figure into pieces (see GeoShape.glued) that fly apart and fade
## away. intensity, from 0 to 1, scales how fast and how far the pieces fly and
## spin. Pieces fly in straight lines, relative to the figure. (Moving the
## figure itself, e.g. for momentum or gravity, is up to its parent.)
##
## Pieces' directions are spread evenly around the screen (x and y), each in
## roughly the direction it already is from the others, then jittered a little.
## So pieces always fly away from each other, never together.
func explode(intensity: float) -> void:
	if not shape:
		return
	var model := shape.get_compiled()
	if model != _mesh_model:
		_set_model(model)
	intensity = clampf(intensity, 0.0, 1.0)
	var transforms := _compute_transforms(model)

	# Find the pieces. The root's piece stays in place; the rest fly.
	var count := model.shapes.size()
	_piece_roots.resize(count)
	_piece_velocities.resize(count)
	_piece_spin_axes.resize(count)
	_piece_spin_angles.resize(count)
	_piece_velocities.fill(Vector3.ZERO)
	_piece_spin_angles.fill(0.0)
	var flying: Array[int] = []
	for i in count:
		var parent := model.parents[i]
		if parent >= 0 and model.shapes[i].glued:
			_piece_roots[i] = _piece_roots[parent]
		else:
			_piece_roots[i] = i
			if parent >= 0:
				flying.append(i)

	# Order the flying pieces by their angle (on screen) around their middle.
	var centers: Dictionary[int, Vector2] = {}
	var middle := Vector2.ZERO
	for i in flying:
		var center := transforms[i] * model.geometries[i].sort_point
		centers[i] = Vector2(center.x, center.y)
		middle += centers[i]
	middle /= maxf(flying.size(), 1)
	var angles: Dictionary[int, float] = {}
	for i in flying:
		angles[i] = (centers[i] - middle).angle()
	flying.sort_custom(func(a: int, b: int) -> bool: return angles[a] < angles[b])

	# Give them evenly spaced directions, in that order, turned to best match
	# the directions they already are from the middle.
	var spacing := TAU / maxf(flying.size(), 1)
	var alignment := Vector2.ZERO
	for slot in flying.size():
		alignment += Vector2.from_angle(angles[flying[slot]] - slot * spacing)
	var start := alignment.angle() if not alignment.is_zero_approx() else _rng.randf() * TAU

	for slot in flying.size():
		var i := flying[slot]
		var angle := start + (slot + _rng.randf_range(-0.5, 0.5) * explosion_direction_jitter) \
				* spacing
		var direction := Vector3(cos(angle), sin(angle), _rng.randf_range(-1.0, 1.0)
				* explosion_max_depth_tilt).normalized()
		var speed := explosion_max_speed * intensity * _rng.randf_range(0.7, 1.0)
		_piece_velocities[i] = direction * speed
		_piece_spin_axes[i] = _random_direction()
		_piece_spin_angles[i] = deg_to_rad(explosion_max_spin_degrees) * intensity \
				* _rng.randf_range(0.5, 1.0)

	_explosion_time = 0.0
	_update_processing()
	_update_cached_frames()
	queue_redraw()


## Puts an exploded figure back together.
func reassemble() -> void:
	_explosion_time = -1.0
	_update_processing()
	_update_cached_frames()
	queue_redraw()


func is_exploding() -> bool:
	return _explosion_time >= 0.0


func _random_direction() -> Vector3:
	return Vector3(_rng.randfn(), _rng.randfn(), _rng.randfn()).normalized()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_EXIT_TREE:
			_release_atlas_cell()
		NOTIFICATION_VISIBILITY_CHANGED:
			if _atlas_item.is_valid():
				RenderingServer.canvas_item_set_visible(_atlas_item, is_visible_in_tree())
				_request_atlas_update()
		NOTIFICATION_PREDELETE:
			_release_atlas_cell()
			RenderingServer.free_rid(_mesh)


## Overrides the position (relative to its parent) of the shape with the given
## name, for this figure only. Same as setting "shapes/<name>/position".
func set_shape_position(shape_name: StringName, value: Vector3) -> void:
	_override_live()
	_set_shape_field(shape_name, &"position", value)


## Overrides the rotation (relative to its parent) of the shape with the given
## name, for this figure only.
func set_shape_rotation_degrees(shape_name: StringName, value: Vector3) -> void:
	_override_live()
	_set_shape_field(shape_name, &"rotation_degrees", value)


## Overrides the scale of the shape with the given name, for this figure only.
func set_shape_scale(shape_name: StringName, value: Vector3) -> void:
	_override_live()
	_set_shape_field(shape_name, &"scale", value)


## Overrides whether the shape with the given name is visible, for this figure
## only.
func set_shape_visible(shape_name: StringName, value: bool) -> void:
	_override_live()
	_set_shape_field(shape_name, &"visible", value)


## Removes all overrides of shapes' fields.
func clear_shape_overrides() -> void:
	_overrides.clear()
	if _mesh_model:
		_rebuild_pose()
	queue_redraw()
	notify_property_list_changed()


# Returns the shape with the given (usable) name, or null.
func _find_shape(shape_name: StringName) -> GeoShape:
	if not shape:
		return null
	var model := shape.get_compiled()
	var index: int = model.shape_indices.get(shape_name, -1)
	return model.shapes[index] if index >= 0 else null


func _get_shape_field(shape_name: StringName, field: StringName) -> Variant:
	var overrides: Dictionary = _residual_pose().get(shape_name, {}) if _is_residual() \
			else _overrides.get(shape_name, {})
	if overrides.has(field):
		return overrides[field]
	var found := _find_shape(shape_name)
	return found.get(field) if found else null


func _set_shape_field(shape_name: StringName, field: StringName, value: Variant) -> void:
	# Values equal to the shape's own aren't overrides (and aren't saved).
	var found := _find_shape(shape_name)
	if found and found.get(field) == value:
		if _overrides.has(shape_name):
			_overrides[shape_name].erase(field)
			if _overrides[shape_name].is_empty():
				_overrides.erase(shape_name)
	else:
		if not _overrides.has(shape_name):
			_overrides[shape_name] = {}
		_overrides[shape_name][field] = value
	if _cached_frames:
		# The cached frame shows the pose; it's only needed again if that stops.
		_pose_dirty = true
		return
	queue_redraw()
	if not _mesh_model:
		return # _draw() will apply all overrides.
	var index: int = _mesh_model.shape_indices.get(shape_name, -1)
	if index < 0:
		push_warning("GeoFigure has no shape named '%s'." % shape_name)
	elif field == &"visible":
		_rebuild_hidden()
	else:
		_pose[index] = _make_pose_transform(_mesh_model.shapes[index])


func _rebuild_pose() -> void:
	_pose.resize(_mesh_model.shapes.size())
	for i in _mesh_model.shapes.size():
		_pose[i] = _make_pose_transform(_mesh_model.shapes[i])
	_rebuild_hidden()


func _rebuild_hidden() -> void:
	var count := _mesh_model.shapes.size()
	_hidden.resize(count)
	for i in count:
		var pose_shape := _mesh_model.shapes[i]
		var overrides: Dictionary = _overrides.get(pose_shape.name, {})
		var parent := _mesh_model.parents[i]
		var hidden: bool = (parent >= 0 and _hidden[parent] == 1) \
				or not overrides.get(&"visible", pose_shape.visible)
		_hidden[i] = 1 if hidden else 0


func _make_pose_transform(pose_shape: GeoShape) -> Transform3D:
	var overrides: Dictionary = _overrides.get(pose_shape.name, {})
	return GeoShape.make_transform(
			overrides.get(&"position", pose_shape.position),
			overrides.get(&"rotation_degrees", pose_shape.rotation_degrees),
			overrides.get(&"scale", pose_shape.scale))


# Returns [shape name, field] if property is "shapes/<shape name>/<field>",
# otherwise [].
static func _parse_shape_property(property: StringName) -> Array:
	var parsed: Variant = _property_parse_cache.get(property)
	if parsed == null:
		parsed = []
		var parts := String(property).split("/")
		if parts.size() == 3 and parts[0] == "shapes" and StringName(parts[2]) in _SHAPE_FIELDS:
			parsed = [StringName(parts[1]), StringName(parts[2])]
		_property_parse_cache[property] = parsed
	return parsed


# Suggests the shape's animations for autoplay.
func _validate_property(property: Dictionary) -> void:
	if property.name == "autoplay" and shape and shape.animations:
		var names := PackedStringArray()
		for animation_name in shape.animations.get_animation_list():
			if animation_name != &"RESET":
				names.append(animation_name)
		property.hint = PROPERTY_HINT_ENUM_SUGGESTION
		property.hint_string = ",".join(names)


func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	if not shape:
		return properties
	var model := shape.get_compiled()
	if model.shape_indices.is_empty():
		return properties
	# The group's prefix is hidden, and the inspector makes a subsection per shape.
	properties.append({name = "Shapes", type = TYPE_NIL, usage = PROPERTY_USAGE_GROUP,
			hint_string = "shapes/"})
	var names := model.shape_indices.keys()
	names.sort_custom(func(a: StringName, b: StringName) -> bool:
		return model.shape_indices[a] < model.shape_indices[b])
	for shape_name: StringName in names:
		var prefix := "shapes/%s/" % shape_name
		# Only overridden fields are saved; the rest come from the shape.
		var overrides: Dictionary = _overrides.get(shape_name, {})
		var usage := func(field: StringName) -> int:
			return PROPERTY_USAGE_DEFAULT if overrides.has(field) else PROPERTY_USAGE_EDITOR
		properties.append({name = prefix + "position", type = TYPE_VECTOR3,
				hint = PROPERTY_HINT_RANGE, hint_string = "-128,128,0.5,or_less,or_greater",
				usage = usage.call(&"position")})
		properties.append({name = prefix + "rotation_degrees", type = TYPE_VECTOR3,
				hint = PROPERTY_HINT_RANGE, hint_string = "-180,180,1,or_less,or_greater,suffix:°",
				usage = usage.call(&"rotation_degrees")})
		properties.append({name = prefix + "scale", type = TYPE_VECTOR3,
				hint = PROPERTY_HINT_RANGE, hint_string = "0,4,0.05,or_less,or_greater",
				usage = usage.call(&"scale")})
		properties.append({name = prefix + "visible", type = TYPE_BOOL,
				usage = usage.call(&"visible")})
	return properties


func _get(property: StringName) -> Variant:
	var parsed := _parse_shape_property(property)
	return _get_shape_field(parsed[0], parsed[1]) if parsed else null


func _property_can_revert(property: StringName) -> bool:
	return not _parse_shape_property(property).is_empty()


func _property_get_revert(property: StringName) -> Variant:
	var parsed := _parse_shape_property(property)
	if not parsed:
		return null
	var found := _find_shape(parsed[0])
	return found.get(parsed[1]) if found else null


func _set_model(model: GeoCompiledModel) -> void:
	_mesh_model = model
	_rebuild_pose()
	# The "shapes/..." properties follow the tree.
	notify_property_list_changed()
	update_configuration_warnings()
	if is_exploding():
		reassemble() # The pieces were for the old model.
	RenderingServer.mesh_clear(_mesh)
	if model.surface.is_empty():
		_attributes = null
		return
	RenderingServer.mesh_add_surface(_mesh, model.surface)
	_attributes = Image.create_from_data(model.attribute_stride / 4, model.vertex_count, false,
			Image.FORMAT_RF, model.surface.attribute_data)


func _set(property: StringName, value: Variant) -> bool:
	if property == &"material":
		# CanvasItem will set its material on the canvas item, so _draw() must
		# set it again.
		_applied_material = RID()
		queue_redraw()
		return false
	var parsed := _parse_shape_property(property)
	if not parsed:
		return false
	if _cached_frames:
		# A cached frame shows the pose, so just keep the value, as cheaply as
		# possible (animations set every track every step). The pose is rebuilt
		# if the figure goes back to rendering live.
		if not _overrides.has(parsed[0]):
			_overrides[parsed[0]] = {}
		_overrides[parsed[0]][parsed[1]] = value
		_pose_dirty = true
		return true
	_set_shape_field(parsed[0], parsed[1], value)
	return true


func _request_atlas_update() -> void:
	GeoPixelAtlas.request_update(get_viewport().get_viewport_rid() if is_inside_tree() else RID())


func _release_atlas_cell() -> void:
	if _atlas_item.is_valid():
		RenderingServer.free_rid(_atlas_item)
		_atlas_item = RID()
	if _atlas_cell.has_area():
		GeoPixelAtlas.release(_atlas_cell)
		_atlas_cell = Rect2i()


func _draw() -> void:
	if _atlas_item.is_valid():
		RenderingServer.canvas_item_clear(_atlas_item)
		_request_atlas_update()
	if not _is_styled():
		_release_atlas_cell()
	var draw_material := style.display_material.get_rid() if _is_styled() \
			else material.get_rid() if material else RID()
	if draw_material != _applied_material:
		RenderingServer.canvas_item_set_material(get_canvas_item(), draw_material)
		_applied_material = draw_material
	if not shape:
		return
	var model := shape.get_compiled()
	if model != _mesh_model:
		_set_model(model)
	if model.surface.is_empty():
		return
	_update_cached_frames(false)
	if _cached_frames:
		_release_atlas_cell()
		_draw_cached_frame()
		return
	var fade := 1.0
	if is_exploding():
		var progress := _explosion_time / explosion_duration
		fade = 1.0 - progress * progress
		if fade <= 0.0:
			return

	if _pose_dirty:
		_rebuild_pose()
	var transforms := _compute_transforms(model)
	if is_exploding():
		_apply_explosion(transforms)
	var reach := _update_mesh(_mesh, _attributes, model, transforms)
	if reach < 0.0:
		return
	var modulate_color := Color(1.0, 1.0, 1.0, fade)
	if _is_styled():
		_draw_pixelated(reach, modulate_color)
	else:
		RenderingServer.canvas_item_add_mesh(get_canvas_item(), _mesh, Transform2D(),
				modulate_color)


# Fills mesh (a copy of model's surface, with attributes its attribute data)
# with the shapes at transforms: their vertices in view space, front faces only,
# sorted back to front. Returns how far the drawn shapes reach from the origin,
# or -1 if nothing is drawn.
func _update_mesh(mesh: RID, attributes: Image, model: GeoCompiledModel,
		transforms: Array[Transform3D]) -> float:
	var shape_count := model.shapes.size()
	# Transform every shape's vertices and normals into view space. (The
	# transform of packed arrays happens in native code.) Normals transform by
	# the inverse transpose, which keeps them perpendicular to scaled surfaces.
	# They're left unnormalized: culling only needs their sign, and shaders
	# normalize them. Shapes scaled to nothing can't be drawn (or inverted).
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var normal_transforms: Array[Transform3D] = []
	normal_transforms.resize(shape_count)
	var collapsed := PackedByteArray()
	collapsed.resize(shape_count)
	for i in shape_count:
		var xform := transforms[i]
		var geometry := model.geometries[i]
		if absf(xform.basis.determinant()) < 0.000001:
			collapsed[i] = 1
		else:
			normal_transforms[i] = Transform3D(xform.basis.inverse().transposed(), Vector3.ZERO)
		if not geometry.positions.is_empty():
			positions.append_array(xform * geometry.positions)
			# Keep the vertex layout fixed, even for collapsed shapes.
			normals.append_array(geometry.normals if collapsed[i] == 1
					else normal_transforms[i] * geometry.normals)

	# Sort the shapes being drawn back to front by depth (view-space z), and find
	# their bounds and how far they reach from the figure's origin.
	var depths := PackedFloat32Array()
	depths.resize(shape_count)
	var order: Array[int] = []
	var bounds := AABB()
	var reach := 0.0
	for i in model.drawable_shapes:
		if _hidden[i] == 1 or collapsed[i] == 1:
			continue
		var xform := transforms[i]
		depths[i] = (xform * model.geometries[i].sort_point).z + model.depth_biases[i]
		var scale_3d := xform.basis.get_scale().abs()
		var radius := model.radii[i] * scale_3d[scale_3d.max_axis_index()]
		var shape_bounds := AABB(xform.origin - Vector3.ONE * radius, Vector3.ONE * radius * 2.0)
		bounds = shape_bounds if order.is_empty() else bounds.merge(shape_bounds)
		reach = maxf(reach, xform.origin.length() + radius)
		order.append(i)
	if order.is_empty():
		return -1.0
	order.sort_custom(func(a: int, b: int) -> bool:
		return depths[a] < depths[b] if depths[a] != depths[b] else a < b)

	# Fill the index buffer with the front-facing faces, in order, then pad it
	# with degenerate triangles.
	var indices := PackedByteArray()
	for i in order:
		var facing := normal_transforms[i] * model.geometries[i].face_normals
		var faces: Array = model.face_index_bytes[i]
		for face in facing.size():
			if facing[face].z > _FACING_EPSILON:
				indices.append_array(faces[face])
	if indices.is_empty():
		return -1.0
	indices.resize(model.index_capacity_bytes)

	# Copy in the normals and draw ranks. Assumes single-precision floats (the
	# default engine build).
	_normals_image.set_data(3, model.vertex_count, false, Image.FORMAT_RF,
			normals.to_byte_array())
	attributes.blit_rect(_normals_image, Rect2i(0, 0, 3, model.vertex_count),
			Vector2i(model.normal_offset / 4, 0))
	for rank in order.size():
		var i := order[rank]
		attributes.fill_rect(Rect2i(model.rank_offset / 4, model.vertex_offsets[i],
				1, model.vertex_counts[i]), Color(rank, 0.0, 0.0))

	RenderingServer.mesh_surface_update_vertex_region(mesh, 0, 0, positions.to_byte_array())
	RenderingServer.mesh_surface_update_attribute_region(mesh, 0, 0, attributes.get_data())
	RenderingServer.mesh_surface_update_index_region(mesh, 0, 0, indices)
	RenderingServer.mesh_set_custom_aabb(mesh, bounds)
	return reach


# Returns each shape's transform into view space.
func _compute_transforms(model: GeoCompiledModel) -> Array[Transform3D]:
	var elevation := camera.elevation_degrees if camera \
			else GeoCamera.DEFAULT_ELEVATION_DEGREES
	var rotation_radians := Vector3(deg_to_rad(model_rotation_degrees.x),
			deg_to_rad(model_rotation_degrees.y), deg_to_rad(model_rotation_degrees.z))
	var view := Transform3D(
			GeoCamera.make_view_basis(elevation) * Basis.from_euler(rotation_radians),
			Vector3.ZERO)
	var transforms: Array[Transform3D] = []
	transforms.resize(model.shapes.size())
	for i in model.shapes.size():
		var parent := model.parents[i]
		transforms[i] = (view if parent < 0 else transforms[parent]) * _pose[i]
	return transforms


# Moves and spins each piece (around its root's origin), in view space.
func _apply_explosion(transforms: Array[Transform3D]) -> void:
	var progress := _explosion_time / explosion_duration
	var piece_moves: Dictionary[int, Transform3D] = {}
	for i in transforms.size():
		var piece := _piece_roots[i]
		if piece == _piece_roots[0]:
			continue # The root's piece stays in place.
		if not piece_moves.has(piece):
			var pivot := transforms[piece].origin
			var spin := Basis(_piece_spin_axes[piece], _piece_spin_angles[piece] * progress)
			var offset := _piece_velocities[piece] * _explosion_time
			piece_moves[piece] = Transform3D(spin, pivot + offset - spin * pivot)
		transforms[i] = piece_moves[piece] * transforms[i]


# reach is how far the drawn shapes extend from the figure's origin.
func _draw_pixelated(reach: float, modulate_color: Color) -> void:
	var pixel_size := style.get_texel_size(camera)
	var cell_size := GeoPixelAtlas.get_cell_size(reach / pixel_size + style.margin)
	# Grow the cell right away, but only shrink it once it's far too big, so a
	# figure that's animating near a size boundary doesn't keep reallocating.
	if cell_size > _atlas_cell.size.x or cell_size * 4 <= _atlas_cell.size.x:
		_release_atlas_cell()
		_atlas_cell = GeoPixelAtlas.allocate(cell_size)
		if not _atlas_cell.has_area():
			return
		_atlas_item = GeoPixelAtlas.create_item(style.lighting_material)
		RenderingServer.canvas_item_set_visible(_atlas_item, is_visible_in_tree())
	_redraw_count += 1
	set_instance_shader_parameter(&"line_seed", _line_seed_base + _redraw_count)

	# Draw the mesh into the cell, with the figure's origin at the cell's center
	# and one texel per art pixel.
	RenderingServer.canvas_item_set_transform(_atlas_item, Transform2D(
			0.0, Vector2.ONE / pixel_size, 0.0, Vector2(_atlas_cell.get_center())))
	RenderingServer.canvas_item_add_mesh(_atlas_item, _mesh)
	_request_atlas_update()

	# Then draw the cell here, scaled back up.
	var size := _atlas_cell.size.x * pixel_size
	RenderingServer.canvas_item_add_texture_rect_region(get_canvas_item(),
			Rect2(-size / 2.0, -size / 2.0, size, size), GeoPixelAtlas.get_texture(),
			Rect2(_atlas_cell), modulate_color)


func _get_configuration_warnings() -> PackedStringArray:
	if not shape:
		return ["Set a shape (e.g. a GeoGroup) to draw."]
	return shape.get_compiled().name_problems
