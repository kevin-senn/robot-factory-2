// The lighting pass of the pixel dither style (pixel_dither.tres): a few flat
// levels of brightness, like the cel lighting (geo_cel_lighting.gdshader), but
// the edges between levels are an ordered dither of them, like the limited
// palettes of old computers. Writes the shape and surface key to alpha, for
// the pixel display shader's outlines.
//
// The dither pattern follows the atlas texels, so it stays put on screen as
// shapes move across it (as it did on old hardware). Atlas cells start at
// multiples of 16 texels, so a figure's pattern is the same in every cell and
// cached frame.
shader_type canvas_item;
// Write alpha (the key) as is, instead of blending with it.
render_mode blend_disabled;

#include "res://addons/geo_render/pixel/geo_pixel_common.gdshaderinc"

// Direction toward the light, in view space (x right, y down, z toward the
// camera). The default is up, left and in front.
uniform vec3 light_direction = vec3(-0.4, -0.7, 0.6);
// The brightness levels: in shadow, in the middle, and in the light (1 shows
// shapes' own colors).
uniform float shadow_brightness : hint_range(0.0, 1.0) = 0.6;
uniform float middle_brightness : hint_range(0.0, 1.0) = 0.8;
uniform float light_brightness : hint_range(0.0, 1.0) = 1.0;
// The amounts of light (0 to 1) where the middle and light levels start. (A
// surface facing the camera gets about 0.6 with the default light direction.)
uniform float middle_from : hint_range(0.0, 1.0) = 0.15;
uniform float light_from : hint_range(0.0, 1.0) = 0.42;
// How much light around each of those is dithered between the two levels;
// the rest is solid. 0 makes hard edges, like the pixel cel style.
uniform float dither_width : hint_range(0.0, 0.5) = 0.14;

varying vec3 normal;
varying flat float key;

// A 4x4 Bayer matrix: thresholds from 0 to 1 that spread evenly in any 4x4
// block, so a fraction f of the texels pass f.
const float BAYER[16] = float[](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

void vertex() {
	normal = CUSTOM0.xyz;
	// CUSTOM1.z is the shape's draw rank; CUSTOM1.w is the face's surface * 2,
	// plus 1 if the shape isn't outlined.
	key = geo_encode_key(CUSTOM1.z, CUSTOM1.w);
}

void fragment() {
	float light = max(dot(normalize(normal), normalize(light_direction)), 0.0);
	ivec2 texel = ivec2(FRAGCOORD.xy) % 4;
	float threshold = (BAYER[texel.y * 4 + texel.x] + 0.5) / 16.0;
	// How far into the dithered zone around each level's start the light is (0
	// below it, 1 above it): the fraction of texels that show that level.
	float width = max(dither_width, 0.0001);
	float to_middle = clamp((light - middle_from) / width + 0.5, 0.0, 1.0);
	float to_light = clamp((light - light_from) / width + 0.5, 0.0, 1.0);
	float brightness = to_light > threshold ? light_brightness
			: to_middle > threshold ? middle_brightness : shadow_brightness;
	COLOR = vec4(COLOR.rgb * brightness, key);
}
