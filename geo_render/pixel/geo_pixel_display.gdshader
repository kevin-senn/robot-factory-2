// Draws a pixelated GeoFigure from its GeoPixelAtlas cell, one crisp square per
// texel, with outlines in a darker version of each outline pixel's own color.
// Shared by every pixelated figure, through geo_pixel_display.tres.
//
// A texel is an outline if any of its four neighbors is empty, belongs to a
// shape drawn behind it, or (with outline_creases) belongs to another surface
// of the same shape, such as the next side of a box. So each shape is outlined
// along its visible edge, inside its silhouette, and shapes in front outline
// themselves against shapes behind them.
//
// The parameters are regular uniforms rather than instance uniforms: every
// figure shares one material, so they're set once, and figures sharing a
// material and the atlas texture can be batched together.
shader_type canvas_item;

#include "res://geo_render/pixel/geo_pixel_common.gdshaderinc"

uniform float outline_darkening : hint_range(0.0, 1.0) = 0.5;
uniform bool outline_creases = true;

varying vec4 modulate;

void vertex() {
	modulate = COLOR;
}

// Whether the texel with the given key should be an outline, given a
// neighbor's key.
bool is_outline(int key, int neighbor_key) {
	if (neighbor_key < 0) {
		return true;
	}
	int rank = key / GEO_SURFACES;
	int neighbor_rank = neighbor_key / GEO_SURFACES;
	if (neighbor_rank != rank) {
		return neighbor_rank < rank;
	}
	// Different surfaces of one shape: outline just one side of the crease.
	return outline_creases && neighbor_key < key;
}

void fragment() {
	// texelFetch reads exact texels, whatever the texture filter.
	ivec2 texel = ivec2(UV / TEXTURE_PIXEL_SIZE);
	vec4 color = texelFetch(TEXTURE, texel, 0);
	int key = geo_decode_key(color.a);
	if (key < 0) {
		discard;
	}
	vec3 rgb = color.rgb;
	if (is_outline(key, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(1, 0), 0).a))
			|| is_outline(key, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(-1, 0), 0).a))
			|| is_outline(key, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(0, 1), 0).a))
			|| is_outline(key, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(0, -1), 0).a))) {
		rgb *= 1.0 - outline_darkening;
	}
	COLOR = vec4(rgb, 1.0) * modulate;
}
