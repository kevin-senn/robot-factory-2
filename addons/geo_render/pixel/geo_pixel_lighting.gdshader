// Draws GeoFigure meshes into GeoPixelAtlas: lit color in rgb, and in alpha a
// per-pixel key that the display shader uses to find outlines (see
// geo_pixel_display.gdshader). Shared by every pixelated figure, through
// geo_pixel_lighting.tres.
shader_type canvas_item;
// Write alpha (the key) as is, instead of blending with it.
render_mode blend_disabled;

#include "res://addons/geo_render/pixel/geo_pixel_common.gdshaderinc"

// Direction toward the light, in view space (x right, y down, z toward the
// camera). The default is up, left and in front.
uniform vec3 light_direction = vec3(-0.4, -0.7, 0.6);
uniform float ambient : hint_range(0.0, 1.0) = 0.45;

varying vec3 normal;
varying flat float key;

void vertex() {
	normal = CUSTOM0.xyz;
	// CUSTOM1.z is the shape's draw rank; CUSTOM1.w is the face's surface * 2,
	// plus 1 if the shape isn't outlined.
	key = geo_encode_key(CUSTOM1.z, CUSTOM1.w);
}

void fragment() {
	float diffuse = max(dot(normalize(normal), normalize(light_direction)), 0.0);
	COLOR = vec4(COLOR.rgb * (ambient + (1.0 - ambient) * diffuse), key);
}
