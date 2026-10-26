// The lighting pass of the cel style (cel.tres): like the pixel art lighting
// (pixel/geo_pixel_lighting.gdshader), but in flat bands of brightness instead
// of smooth shading. Writes the shape and surface key to alpha, for the cel
// display shader's outlines.
shader_type canvas_item;
// Write alpha (the key) as is, instead of blending with it.
render_mode blend_disabled;

#include "res://addons/geo_render/pixel/geo_pixel_common.gdshaderinc"

// Direction toward the light, in view space (x right, y down, z toward the
// camera). The default is up, left and in front.
uniform vec3 light_direction = vec3(-0.4, -0.7, 0.6);
// The bands: brightness in shadow and in the middle (full brightness above),
// and the amounts of light (0 to 1) where each band starts.
uniform float shadow_brightness : hint_range(0.0, 1.0) = 0.62;
uniform float middle_brightness : hint_range(0.0, 1.0) = 0.84;
uniform float middle_from : hint_range(0.0, 1.0) = 0.2;
uniform float light_from : hint_range(0.0, 1.0) = 0.6;

varying vec3 normal;
varying flat float key;

void vertex() {
	normal = CUSTOM0.xyz;
	// CUSTOM1.z is the shape's draw rank; CUSTOM1.w is the face's surface * 2,
	// plus 1 if the shape isn't outlined.
	key = geo_encode_key(CUSTOM1.z, CUSTOM1.w);
}

void fragment() {
	float light = max(dot(normalize(normal), normalize(light_direction)), 0.0);
	float brightness = light < middle_from ? shadow_brightness
			: light < light_from ? middle_brightness : 1.0;
	COLOR = vec4(COLOR.rgb * brightness, key);
}
