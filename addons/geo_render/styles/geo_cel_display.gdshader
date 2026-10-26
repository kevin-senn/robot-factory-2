// Draws a GeoFigure's rendered cell (see geo_cel_lighting.gdshader) in the cel
// style (cel.tres): flat bands of color with dark, sketchy outlines.
//
// A texel is drawn as line if, after straying by some noise, it's within
// line_width of an edge: between shapes, between a shape and empty space, and
// (with crease_lines) between surfaces of one shape. Lines can fall outside the
// shapes, so the style's margin must cover wobble + line_width (plus their
// variance) and a texel. The noise changes with line_seed, which GeoFigure
// changes whenever its pose does, so each animation frame gets new lines.
// Shapes with GeoShape.outlined off get no lines.
shader_type canvas_item;

#include "res://addons/geo_render/pixel/geo_pixel_common.gdshaderinc"

uniform vec4 line_color : source_color = vec4(0.08, 0.06, 0.1, 1.0);
// Half a line's thickness, in texels.
uniform float line_width : hint_range(0.0, 6.0) = 1.3;
// How much the thickness varies along a line (0: not at all, 1: from nothing
// to double).
uniform float width_variance : hint_range(0.0, 1.0) = 0.35;
// How far lines stray from the shapes' edges, in texels.
uniform float wobble : hint_range(0.0, 6.0) = 0.9;
// How often lines wiggle along an edge (higher is wigglier).
uniform float wiggle : hint_range(0.01, 1.0) = 0.12;
uniform bool crease_lines = false;

// Per figure (see GeoFigure).
instance uniform vec4 flash_color : source_color = vec4(1.0);
instance uniform float flash_amount = 0.0;
instance uniform float line_seed = 0.0;

varying vec4 modulate;

void vertex() {
	modulate = COLOR;
}

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// Smooth noise from 0 to 1.
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

int key_at(sampler2D tex, vec2 texel) {
	return geo_decode_key(texelFetch(tex, ivec2(floor(texel)), 0).a);
}

// Whether a line goes between texels with these keys.
bool separates(int a, int b) {
	if (a == b) {
		return false;
	}
	if ((a >= 0 && !geo_key_is_outlined(a)) || (b >= 0 && !geo_key_is_outlined(b))) {
		return false;
	}
	if (a < 0 || b < 0) {
		return true;
	}
	int region_a = geo_key_region(a);
	int region_b = geo_key_region(b);
	if (region_a / GEO_SURFACES != region_b / GEO_SURFACES) {
		return true;
	}
	return crease_lines;
}

void fragment() {
	// The nudge settles pixels exactly on a texel edge the same way in any
	// texture (an atlas cell or a cached frame), despite rounding.
	vec2 texel = UV / TEXTURE_PIXEL_SIZE + vec2(0.001);
	vec2 n = texel * wiggle + vec2(line_seed * 7.31, line_seed * 3.17);
	vec2 stray = (vec2(value_noise(n), value_noise(n + vec2(41.3, 17.9))) * 2.0 - 1.0) * wobble;
	float width = line_width * (1.0 + (value_noise(n + vec2(-23.1, 61.7)) * 2.0 - 1.0)
			* width_variance);
	vec2 at = texel + stray;
	int here = key_at(TEXTURE, at);
	bool line = false;
	for (int i = 0; i < 8; i++) {
		float angle = float(i) * (PI / 4.0);
		if (separates(here, key_at(TEXTURE, at + vec2(cos(angle), sin(angle)) * width))) {
			line = true;
			break;
		}
	}
	vec4 color = line_color;
	if (!line) {
		vec4 fill = texelFetch(TEXTURE, ivec2(floor(texel)), 0);
		if (geo_decode_key(fill.a) < 0) {
			discard;
		}
		color = vec4(fill.rgb, 1.0);
	}
	color.rgb = mix(color.rgb, flash_color.rgb, flash_amount);
	COLOR = color * modulate;
}
