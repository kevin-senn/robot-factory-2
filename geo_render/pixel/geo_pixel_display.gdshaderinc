// Draws a pixelated GeoFigure from its GeoPixelAtlas cell, one crisp square per
// texel. Included by the display shader variants, which choose an outline mode
// by defining one of:
//   GEO_OUTLINE_COLOR   Outlines in outline_color.
//   GEO_OUTLINE_DARKEN  Outlines in a darker version of the pixel's own color.
// (Neither: no outlines.)
//
// A texel is an outline if any of its four neighbors is empty, belongs to a
// shape drawn behind it, or (with outline_creases) belongs to another surface
// of the same shape, such as the next side of a box. So each shape is outlined
// along its visible edge, inside its silhouette, and shapes in front outline
// themselves against shapes behind them.
//
// All parameters are regular uniforms: every figure shares one material, so
// they're set once, and figures sharing a material and the atlas texture can
// be batched together.

#include "res://geo_render/pixel/geo_pixel_common.gdshaderinc"

#if defined(GEO_OUTLINE_COLOR) || defined(GEO_OUTLINE_DARKEN)
#define GEO_OUTLINES
uniform bool outline_creases = true;
#endif
#ifdef GEO_OUTLINE_COLOR
uniform vec4 outline_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
#endif
#ifdef GEO_OUTLINE_DARKEN
uniform float outline_darkening : hint_range(0.0, 1.0) = 0.5;
#endif

varying vec4 modulate;

void vertex() {
	modulate = COLOR;
}

#ifdef GEO_OUTLINES
// Whether the texel with the given key should be an outline, given a neighbor.
bool geo_is_outline(sampler2D atlas, int key, ivec2 neighbor) {
	int neighbor_key = geo_decode_key(texelFetch(atlas, neighbor, 0).a);
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
#endif

void fragment() {
	// texelFetch reads exact texels, whatever the texture filter.
	ivec2 texel = ivec2(UV / TEXTURE_PIXEL_SIZE);
	vec4 color = texelFetch(TEXTURE, texel, 0);
	int key = geo_decode_key(color.a);
	if (key < 0) {
		discard;
	}
	vec3 rgb = color.rgb;
#ifdef GEO_OUTLINES
	if (geo_is_outline(TEXTURE, key, texel + ivec2(1, 0))
			|| geo_is_outline(TEXTURE, key, texel + ivec2(-1, 0))
			|| geo_is_outline(TEXTURE, key, texel + ivec2(0, 1))
			|| geo_is_outline(TEXTURE, key, texel + ivec2(0, -1))) {
#ifdef GEO_OUTLINE_COLOR
		rgb = outline_color.rgb;
#else
		rgb *= 1.0 - outline_darkening;
#endif
	}
#endif
	COLOR = vec4(rgb, 1.0) * modulate;
}
