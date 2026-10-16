// Draws a pixelated GeoFigure from its GeoPixelAtlas cell, one crisp square per
// texel, with outlines in a darker version of each outline pixel's own color.
// Shared by every pixelated figure, through geo_pixel_display.tres.
//
// A texel is an outline if any of its four neighbors is empty, belongs to a
// shape drawn behind it, or (with outline_creases) belongs to another surface
// of the same shape, such as the next side of a box. So each shape is outlined
// along its visible edge, inside its silhouette, and shapes in front outline
// themselves against shapes behind them. Shapes with GeoShape.outlined off
// are never outlined.
//
// The outline parameters are regular uniforms rather than instance uniforms:
// every figure shares one material, so they're set once, and figures sharing
// a material and the atlas texture can be batched together.
shader_type canvas_item;

#include "res://addons/geo_render/pixel/geo_pixel_common.gdshaderinc"

uniform float outline_darkening : hint_range(0.0, 1.0) = 0.5;
uniform bool outline_creases = true;

// Per figure (see GeoFigure.flash_color and flash_amount), so these are
// instance uniforms: each figure can flash on its own without its own material.
instance uniform vec4 flash_color : source_color = vec4(1.0);
instance uniform float flash_amount = 0.0;

varying vec4 modulate;

void vertex() {
	modulate = COLOR;
}

// Whether a texel in the given region should be an outline, given a neighbor's
// decoded key.
bool is_outline(int region, int neighbor_key) {
	if (neighbor_key < 0) {
		return true;
	}
	int neighbor_region = geo_key_region(neighbor_key);
	int rank = region / GEO_SURFACES;
	int neighbor_rank = neighbor_region / GEO_SURFACES;
	if (neighbor_rank != rank) {
		return neighbor_rank < rank;
	}
	// Different surfaces of one shape: outline just one side of the crease.
	return outline_creases && neighbor_region < region;
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
	if (geo_key_is_outlined(key)) {
		int region = geo_key_region(key);
		if (is_outline(region, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(1, 0), 0).a))
				|| is_outline(region, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(-1, 0), 0).a))
				|| is_outline(region, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(0, 1), 0).a))
				|| is_outline(region, geo_decode_key(texelFetch(TEXTURE, texel + ivec2(0, -1), 0).a))) {
			rgb *= 1.0 - outline_darkening;
		}
	}
	rgb = mix(rgb, flash_color.rgb, flash_amount);
	COLOR = vec4(rgb, 1.0) * modulate;
}
