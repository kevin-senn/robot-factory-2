// Shared by the pixel shaders. Each GeoPixelAtlas texel's alpha holds a key,
// divided by 255: 0 for empty, otherwise 1 + region * 2 + (1 if the shape isn't
// outlined, else 0). A texel's region is rank * GEO_SURFACES + surface, where
// rank is the shape's position in the figure's back-to-front draw order and
// surface is the face's surface (see GeoGeometry.face_surfaces).

const int GEO_SURFACES = 3; // GeoGeometry.MAX_SURFACE + 1.

// surface_and_flag is surface * 2 + (1 if the shape isn't outlined, else 0),
// as stored in CUSTOM1.w.
float geo_encode_key(float rank, float surface_and_flag) {
	return (1.0 + rank * float(GEO_SURFACES * 2) + surface_and_flag) / 255.0;
}

// Returns -1 for empty texels, otherwise the key minus 1.
int geo_decode_key(float alpha) {
	return int(round(alpha * 255.0)) - 1;
}

// Returns the region of a non-empty texel's decoded key.
int geo_key_region(int key) {
	return key / 2;
}

bool geo_key_is_outlined(int key) {
	return key % 2 == 0;
}
