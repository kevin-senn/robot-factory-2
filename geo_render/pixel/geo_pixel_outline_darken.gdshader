// Pixelated GeoFigures with outlines in a darker version of each pixel's color.
shader_type canvas_item;

#define GEO_OUTLINE_DARKEN
#include "res://geo_render/pixel/geo_pixel_display.gdshaderinc"
