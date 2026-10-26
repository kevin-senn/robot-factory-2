@tool
class_name GeoStyle
extends Resource
## How GeoFigures look, e.g. pixel art (styles/pixel_art.tres) or cel shading
## (styles/cel.tres).
##
## A styled figure is drawn in two passes. First its shapes are rendered into
## its cell of GeoPixelAtlas with lighting_material, one texel per pixel_size
## units: lit colors in rgb, and in alpha a key saying which shape and surface
## each texel shows (see pixel/geo_pixel_common.gdshaderinc). Then the figure
## draws its cell, scaled up, with display_material, which can use the keys to
## find the shapes' edges, e.g. for outlines. Cached animation frames (see
## GeoAnimationCache) store the first pass, so the display shader still runs
## live on them.

## Renders the shapes into the atlas. Must write the key to alpha with
## render_mode blend_disabled (see pixel/geo_pixel_lighting.gdshader).
@export var lighting_material: ShaderMaterial:
	set(value):
		lighting_material = value
		emit_changed()

## Draws the rendered cell on screen. GeoFigure sets its instance uniforms
## flash_color, flash_amount and line_seed (a number that changes whenever the
## figure's pose does, e.g. to redraw sketchy lines differently each frame), so
## it must declare them.
@export var display_material: ShaderMaterial:
	set(value):
		display_material = value
		emit_changed()

## The size of each rendered texel, in the figure's units. 0 uses the
## figure's GeoCamera.pixel_size (as pixel art does). Smaller is more detailed,
## and uses more memory.
@export_range(0.0, 32.0, 0.05, "or_greater") var pixel_size := 0.0:
	set(value):
		pixel_size = maxf(value, 0.0)
		emit_changed()

## How many texels beyond the shapes the display shader can draw into, e.g. for
## outlines outside them. Must cover how far it reads neighboring texels.
@export_range(0, 32) var margin := 0:
	set(value):
		margin = maxi(value, 0)
		emit_changed()


## The texel size for a figure with the given camera.
func get_texel_size(camera: GeoCamera) -> float:
	if pixel_size > 0.0:
		return pixel_size
	return camera.pixel_size if camera else GeoCamera.DEFAULT_PIXEL_SIZE
