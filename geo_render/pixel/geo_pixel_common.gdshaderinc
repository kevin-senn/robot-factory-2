// Shared by the pixel shaders. Each GeoPixelAtlas texel's alpha holds a key: 0 for
// empty, otherwise 1 + rank * SURFACES + surface, divided by 255, where rank is
// the shape's position in the figure's back-to-front draw order and surface
// is the face's surface (see GeoGeometry.face_surfaces).

const int GEO_SURFACES = 3; // GeoGeometry.MAX_SURFACE + 1.

float geo_encode_key(float rank, float surface) {
	return (1.0 + rank * float(GEO_SURFACES) + surface) / 255.0;
}

// Returns -1 for empty texels, otherwise rank * GEO_SURFACES + surface.
int geo_decode_key(float alpha) {
	return int(round(alpha * 255.0)) - 1;
}
