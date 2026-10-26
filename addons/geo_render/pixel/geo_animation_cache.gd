@tool
class_name GeoAnimationCache
extends Object
## Pre-rendered frames of figures' animations, so styled figures (see GeoStyle)
## playing stepped animations (GeoFigure.animation_fps) can draw a cached frame
## instead of transforming, sorting and rendering their shapes every step.
##
## A frame is the figure's GeoPixelAtlas cell as rendered by its style's
## lighting material (colors, plus the shape and surface keys in alpha), so
## drawing it with the style's display material looks exactly like the live
## figure: outlines, flashes and modulate still work.
##
## Frames are built the first time they're needed, in game only, and shared by
## every figure with the same shape, animation, frame rate, model rotation,
## camera and style. Building takes a single render: every frame is drawn into
## the atlas at once, then the atlas is read back into a sprite sheet, cropped to
## what the frames show (plus the style's margin). Until then (or if building
## fails), figures render live. Changing the shapes, the animation, the camera
## or the style drops the frames built from them.


## One animation's frames, for one view of one shape.
class Frames:
	extends RefCounted
	## A sprite sheet of the frames, each a regions[i].size texels across.
	var texture: Texture2D
	var regions: Array[Rect2] = []
	## Where the figure's origin is in each frame, in texels from its corner.
	var origin := Vector2.ZERO
	var fps := 0
	## Whether the frames have been built (and can be drawn).
	var ready := false
	## False once the shapes, animation, camera or style they were built from
	## change.
	var valid := true

	## The frame to show at time seconds into the animation.
	func frame_at(time: float) -> int:
		return clampi(floori(time * fps + 0.0001), 0, regions.size() - 1)


## Turn off to render every figure live (e.g. to compare, or to debug).
static var enabled := true

static var _frames: Dictionary[String, Frames] = {}
static var _residual_libraries: Dictionary[AnimationLibrary, AnimationLibrary] = {}


## The frames of animation for figure (its shape and view) at fps. They're
## built on first request, so check ready (they're ready in a frame or two).
## Once they're no longer valid, request them again.
static func get_frames(figure: GeoFigure, animation: Animation, fps: int) -> Frames:
	var key := _key(figure, animation, fps)
	var frames: Frames = _frames.get(key)
	if frames:
		return frames
	frames = Frames.new()
	frames.fps = fps
	_frames[key] = frames
	var forget := func() -> void:
		frames.valid = false
		_frames.erase(key)
	for source: Resource in [figure.shape, animation, figure.camera, figure.style]:
		if source:
			source.changed.connect(forget, CONNECT_ONE_SHOT)
	_build(frames, figure, animation, key)
	return frames


## A copy of library without the tracks that animate figures' shapes
## ("shapes/..." properties), with the same animation names. Figures drawing
## cached frames play it instead, since the frames already show the shapes, and
## setting them every step is most of a figure's cost. The rest (e.g.
## flash_amount, method calls) still plays.
static func residual_library(library: AnimationLibrary) -> AnimationLibrary:
	var residual: AnimationLibrary = _residual_libraries.get(library)
	if residual:
		return residual
	residual = AnimationLibrary.new()
	for animation_name in library.get_animation_list():
		var copy: Animation = library.get_animation(animation_name).duplicate()
		for track in range(copy.get_track_count() - 1, -1, -1):
			var path := copy.track_get_path(track)
			if path.get_subname_count() > 0 and path.get_subname(0).begins_with("shapes/"):
				copy.remove_track(track)
		residual.add_animation(animation_name, copy)
	_residual_libraries[library] = residual
	var forget := func(_a: Variant = null, _b: Variant = null) -> void:
		_residual_libraries.erase(library)
	for signal_name in [&"animation_changed", &"animation_added", &"animation_removed",
			&"animation_renamed"]:
		library.connect(signal_name, forget, CONNECT_ONE_SHOT)
	return residual


## Drops every cached frame.
static func clear() -> void:
	_residual_libraries.clear()
	for frames in _frames.values():
		frames.valid = false
	_frames.clear()


## The times (in seconds) of an animation's frames at fps: every 1 / fps
## seconds, ending before the length if it loops, or at it if it doesn't.
static func frame_times(animation: Animation, fps: int) -> PackedFloat32Array:
	var length := animation.length
	var count := floori(length * fps - 0.0001) + 1 if animation.loop_mode != Animation.LOOP_NONE \
			else floori(length * fps + 0.0001) + 1
	var times := PackedFloat32Array()
	for i in maxi(count, 1):
		times.append(minf(float(i) / fps, length))
	return times


static func _key(figure: GeoFigure, animation: Animation, fps: int) -> String:
	var camera := figure.camera
	var style := figure.style
	return "%d|%d|%d|%s|%s|%s|%d|%d" % [figure.shape.get_instance_id(),
			animation.get_instance_id(), fps, figure.model_rotation_degrees,
			camera.elevation_degrees if camera else GeoCamera.DEFAULT_ELEVATION_DEGREES,
			style.get_texel_size(camera), style.lighting_material.get_instance_id(), style.margin]


static func _build(frames: Frames, figure: GeoFigure, animation: Animation, key: String) -> void:
	var meshes: Array = figure._make_frame_meshes(animation, frame_times(animation, frames.fps))
	var style := figure.style
	var texel_size := style.get_texel_size(figure.camera)
	var reach := 0.0
	for entry: Array in meshes:
		reach = maxf(reach, entry[1])
	var cell_size := GeoPixelAtlas.get_cell_size(reach / texel_size + style.margin)

	# Draw every frame into its own atlas cell, in one render.
	var cells: Array[Rect2i] = []
	var items: Array[RID] = []
	for entry: Array in meshes:
		var cell := GeoPixelAtlas.allocate(cell_size)
		cells.append(cell)
		if not cell.has_area() or entry[1] < 0.0:
			continue
		var item := GeoPixelAtlas.create_item(style.lighting_material)
		RenderingServer.canvas_item_set_transform(item, Transform2D(
				0.0, Vector2.ONE / texel_size, 0.0, Vector2(cell.get_center())))
		RenderingServer.canvas_item_add_mesh(item, entry[0])
		items.append(item)
	var viewport := figure.get_viewport().get_viewport_rid() if figure.is_inside_tree() else RID()
	GeoPixelAtlas.request_update(viewport)
	await RenderingServer.frame_post_draw

	var atlas_texture := GeoPixelAtlas.get_texture()
	var atlas: Image = RenderingServer.texture_2d_get(atlas_texture) if atlas_texture.is_valid() \
			else null
	if atlas and not atlas.is_empty() and _frames.get(key) == frames:
		atlas.convert(Image.FORMAT_RGBA8)
		# Crop the frames to what any of them shows, plus room for the display
		# shader to draw beyond the shapes and read their neighboring texels.
		var used := Rect2i()
		for cell in cells:
			if cell.has_area():
				var shown := atlas.get_region(cell).get_used_rect()
				if shown.has_area():
					used = shown if not used.has_area() else used.merge(shown)
		used = used.grow(style.margin + 1).intersection(
				Rect2i(Vector2i.ZERO, Vector2i(cell_size, cell_size)))
		var columns := ceili(sqrt(cells.size()))
		var rows := ceili(float(cells.size()) / columns)
		var sheet := Image.create_empty(maxi(columns * used.size.x, 1),
				maxi(rows * used.size.y, 1), false, Image.FORMAT_RGBA8)
		for i in cells.size():
			var at := Vector2i(i % columns, i / columns) * used.size
			if cells[i].has_area():
				sheet.blit_rect(atlas, Rect2i(cells[i].position + used.position, used.size), at)
			frames.regions.append(Rect2(at, used.size))
		frames.texture = ImageTexture.create_from_image(sheet)
		# The figure's origin is at each cell's center.
		frames.origin = Vector2(cell_size, cell_size) / 2.0 - Vector2(used.position)
		frames.ready = true

	for item in items:
		RenderingServer.free_rid(item)
	for entry: Array in meshes:
		RenderingServer.free_rid(entry[0])
	for cell in cells:
		if cell.has_area():
			GeoPixelAtlas.release(cell)
