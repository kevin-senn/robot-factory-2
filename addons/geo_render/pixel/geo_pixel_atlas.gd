@tool
class_name GeoPixelAtlas
extends Object
## The render target shared by every styled GeoFigure (see GeoStyle).
##
## Each styled figure has a square cell in the atlas, where its mesh is drawn
## (unrotated, at one texel per pixel_size units) by its style's lighting
## material. The figure then draws its cell as a single textured rect, scaled
## up, with its style's display material. Because the rect is drawn in the
## figure's own space, its pixels rotate and scale with the figure, like a
## sprite.
##
## The atlas is a RenderingServer viewport rather than a SubViewport node, so it
## works the same in the editor and in game without being part of any scene. It
## only re-renders on frames when some figure changed, and it's freed when the
## last figure releases its cell.
##
## Cells are allocated on shelves: rows of same-size cells across the atlas.
## Sizes are powers of two.

const WIDTH := 2048
const MAX_HEIGHT := 16384
const MIN_CELL_SIZE := 16

static var _viewport: RID
static var _canvas: RID
static var _texture: RID
static var _height := 0
# Shelf y -> [cell size, PackedInt32Array of free cell x positions].
static var _shelves: Dictionary[int, Array] = {}
static var _next_shelf_y := 0
static var _cell_count := 0
static var _update_requested_frame := -1
# The viewport the atlas renders before (see request_update()). Viewports render
# before their parents, and otherwise in the order they were created, so without
# this, the atlas (created later) would render after the editor's 2D viewport,
# which would show the previous frame's atlas.
static var _parent_viewport := RID()


## Returns the cell size for a figure that extends up to radius texels from its
## origin, with room for a one-texel border, so outline shaders can read
## neighboring texels without leaving the cell.
static func get_cell_size(radius: float) -> int:
	return maxi(MIN_CELL_SIZE, _next_power_of_2(2 * (ceili(radius) + 2)))


## Allocates a square cell of the given size (from get_cell_size()). Returns an
## empty Rect2i if the atlas is full.
static func allocate(size: int) -> Rect2i:
	if not _viewport:
		_create()
	for y in _shelves:
		var shelf := _shelves[y]
		var free_x: PackedInt32Array = shelf[1]
		if shelf[0] == size and not free_x.is_empty():
			var x := free_x[free_x.size() - 1]
			free_x.remove_at(free_x.size() - 1)
			_cell_count += 1
			return Rect2i(x, y, size, size)

	# Add a shelf, growing the atlas if needed.
	if size > WIDTH or _next_shelf_y + size > MAX_HEIGHT:
		push_error("GeoPixelAtlas is full.")
		return Rect2i()
	var y := _next_shelf_y
	_next_shelf_y += size
	if _next_shelf_y > _height:
		_height = mini(MAX_HEIGHT, _next_power_of_2(_next_shelf_y))
		RenderingServer.viewport_set_size(_viewport, WIDTH, _height)
	var free_x := PackedInt32Array()
	for x in range(WIDTH - size, -1, -size):
		free_x.append(x)
	_shelves[y] = [size, free_x]
	return allocate(size)


static func release(cell: Rect2i) -> void:
	if not _viewport or not _shelves.has(cell.position.y):
		return
	var free_x: PackedInt32Array = _shelves[cell.position.y][1]
	free_x.append(cell.position.x)
	_cell_count -= 1
	if _cell_count == 0:
		_free()
	else:
		request_update()


## Creates a canvas item that draws into the atlas with lighting_material (a
## GeoStyle's). Free it with RenderingServer.free_rid().
static func create_item(lighting_material: ShaderMaterial) -> RID:
	if not _viewport:
		_create()
	var item := RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(item, _canvas)
	RenderingServer.canvas_item_set_material(item, lighting_material.get_rid())
	return item


static func get_texture() -> RID:
	return _texture


## Re-renders the atlas this frame. Call whenever a figure's item changes, with
## the viewport the figure is drawn in, so the atlas renders before it. (If
## figures are in several viewports, it renders before the last one given.)
static func request_update(for_viewport := RID()) -> void:
	if _viewport and for_viewport.is_valid() and for_viewport != _parent_viewport:
		_parent_viewport = for_viewport
		RenderingServer.viewport_set_parent_viewport(_viewport, for_viewport)
	var frame := Engine.get_process_frames()
	if _viewport and frame != _update_requested_frame:
		_update_requested_frame = frame
		RenderingServer.viewport_set_update_mode(_viewport, RenderingServer.VIEWPORT_UPDATE_ONCE)


static func _create() -> void:
	_height = MIN_CELL_SIZE
	_viewport = RenderingServer.viewport_create()
	RenderingServer.viewport_set_size(_viewport, WIDTH, _height)
	RenderingServer.viewport_set_disable_3d(_viewport, true)
	RenderingServer.viewport_set_transparent_background(_viewport, true)
	RenderingServer.viewport_set_clear_mode(_viewport, RenderingServer.VIEWPORT_CLEAR_ALWAYS)
	RenderingServer.viewport_set_update_mode(_viewport, RenderingServer.VIEWPORT_UPDATE_ONCE)
	RenderingServer.viewport_set_active(_viewport, true)
	_canvas = RenderingServer.canvas_create()
	RenderingServer.viewport_attach_canvas(_viewport, _canvas)
	_texture = RenderingServer.viewport_get_texture(_viewport)


static func _free() -> void:
	RenderingServer.free_rid(_viewport)
	RenderingServer.free_rid(_canvas)
	_viewport = RID()
	_canvas = RID()
	_texture = RID()
	_height = 0
	_shelves.clear()
	_next_shelf_y = 0
	_cell_count = 0
	_update_requested_frame = -1
	_parent_viewport = RID()


static func _next_power_of_2(value: int) -> int:
	var result := 1
	while result < value:
		result *= 2
	return result
