// An example shader for GeoFigures, showing the data each vertex provides (see
// geo_figure.gd). Simple directional lighting, plus views of the raw data for
// debugging.
shader_type canvas_item;

uniform int debug_view : hint_enum("Lit", "Normals", "UVs", "Shape index", "Face index") = 0;
// Direction toward the light, in view space (x right, y down, z toward the
// camera). The default is up, left and in front.
uniform vec3 light_direction = vec3(-0.4, -0.7, 0.6);
uniform float ambient : hint_range(0.0, 1.0) = 0.45;

varying vec3 normal;
varying flat vec2 shape_and_face;

void vertex() {
	normal = CUSTOM0.xyz;
	shape_and_face = CUSTOM1.xy;
}

vec3 index_color(float index) {
	// Spread consecutive indices around the hue wheel.
	float hue = fract(index * 0.618034);
	return clamp(abs(fract(hue + vec3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

void fragment() {
	vec3 n = normalize(normal);
	if (debug_view == 0) {
		float diffuse = max(dot(n, normalize(light_direction)), 0.0);
		COLOR.rgb *= ambient + (1.0 - ambient) * diffuse;
	} else if (debug_view == 1) {
		COLOR.rgb = n * 0.5 + 0.5;
	} else if (debug_view == 2) {
		COLOR.rgb = vec3(UV, 0.0);
	} else if (debug_view == 3) {
		COLOR.rgb = index_color(shape_and_face.x);
	} else {
		COLOR.rgb = index_color(shape_and_face.y);
	}
}
