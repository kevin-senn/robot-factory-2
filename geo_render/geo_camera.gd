@tool
class_name GeoCamera
extends Resource
## View settings shared by GeoFigures. Figures use default_geo_camera.tres
## unless given another one, so editing that file changes every figure.

const DEFAULT_ELEVATION_DEGREES := 25.0

## How far above the figures the (orthographic) camera is, as the angle it
## looks down at. 0 looks at figures head on; 90 looks straight down.
@export_range(-90.0, 90.0, 0.1, "suffix:°") var elevation_degrees := DEFAULT_ELEVATION_DEGREES:
	set(value):
		elevation_degrees = value
		emit_changed()


## Rotates figure space into view space, where x and y are screen coordinates
## and z points toward the camera.
func get_view_basis() -> Basis:
	return GeoCamera.make_view_basis(elevation_degrees)


static func make_view_basis(elevation: float) -> Basis:
	return Basis(Vector3.RIGHT, -deg_to_rad(elevation))
