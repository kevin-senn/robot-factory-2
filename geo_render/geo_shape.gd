@tool
@abstract
class_name GeoShape
extends Resource
## One part of a GeoFigure: a 3D primitive with a transform relative to its
## parent shape, plus child shapes that move with it.
##
## Coordinate space: x is right and y is down (as in 2D), and z points toward
## the camera. Rotations are Euler angles applied in Y, X, Z order (like
## Node3D). With no X/Y rotation, a positive Z rotation is clockwise on screen,
## like Node2D.rotation.
##
## A tree of shapes is saved as a resource and can be shared by any number of
## GeoFigures. Changing any shape in the tree emits [signal Resource.changed] on
## it and on every ancestor, so a figure only needs to watch its root shape.

## Used to find the shape from code, e.g. [method GeoFigure.set_shape_rotation_degrees].
@export var name: StringName:
	set(value):
		name = value
		resource_name = value # So the inspector shows it.
		_changed()

## Hiding a shape also hides its children.
@export var visible := true:
	set(value):
		visible = value
		_changed()

@export var color := Color.WHITE:
	set(value):
		color = value
		_changed()

## Whether pixelated figures can draw outlines on this shape. Turn it off for
## details that should keep their color, like a highlight or a shadow.
@export var outlined := true:
	set(value):
		outlined = value
		_changed()

## Whether this shape stays attached to its parent when the figure explodes
## (see GeoFigure.explode()). Shapes that aren't glued break off as pieces,
## taking their glued descendants with them. The root's piece stays in place.
@export var glued := false:
	set(value):
		glued = value
		_changed()

@export_group("Transform")
## Position relative to the parent shape.
@export var position := Vector3.ZERO:
	set(value):
		position = value
		_changed()

## Rotation relative to the parent shape, in degrees.
@export var rotation_degrees := Vector3.ZERO:
	set(value):
		rotation_degrees = value
		_changed()

## Added to this shape's depth when sorting shapes. Positive values draw it in
## front of more shapes. Only needed when the automatic sorting (by the center
## of each shape's bounds) gets it wrong.
@export var depth_bias := 0.0:
	set(value):
		depth_bias = value
		_changed()
@export_group("")

@export var children: Array[GeoShape] = []:
	set(value):
		for child in children:
			if child and child.changed.is_connected(_changed):
				child.changed.disconnect(_changed)
		children = value
		for child in children:
			if child and not child.changed.is_connected(_changed):
				child.changed.connect(_changed)
		_changed()

var _geometry: GeoGeometry
var _compiled: GeoCompiledModel


## Returns this shape's local geometry (built on first use, then cached).
func get_geometry() -> GeoGeometry:
	if not _geometry:
		_geometry = GeoGeometry.new()
		_build_geometry(_geometry)
		_geometry.finish()
	return _geometry


## Returns the tree rooted at this shape, flattened for drawing (built on first
## use, then cached until something in the tree changes).
func get_compiled() -> GeoCompiledModel:
	if not _compiled:
		_compiled = GeoCompiledModel.new(self)
	return _compiled


static func make_transform(pos: Vector3, rot_degrees: Vector3) -> Transform3D:
	var radians := Vector3(deg_to_rad(rot_degrees.x), deg_to_rad(rot_degrees.y),
			deg_to_rad(rot_degrees.z))
	return Transform3D(Basis.from_euler(radians), pos)


## Override to add this shape's faces. See GeoGeometry.
func _build_geometry(_geometry_out: GeoGeometry) -> void:
	pass


## Call from setters of properties that change the shape's geometry.
func _geometry_changed() -> void:
	_geometry = null
	_changed()


func _changed() -> void:
	_compiled = null
	emit_changed()
