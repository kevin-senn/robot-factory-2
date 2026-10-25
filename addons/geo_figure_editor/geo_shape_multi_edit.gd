@tool
extends RefCounted
## Inspected in place of the selected shapes when several are selected (the
## Inspector can only edit several nodes at once, not several resources). It
## shows the first shape's values; changing one sets it on every shape, as one
## undo action. For vectors, only the components that changed are set, so
## setting position.y lines the shapes up without moving them in x or z.
##
## In animation mode it's inspected for one shape too, and shows only the
## fields figures can animate, as posed on the figure.

const _FIELDS := {
	&"color": [TYPE_COLOR, PROPERTY_HINT_NONE, ""],
	&"visible": [TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	&"outlined": [TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	&"glued": [TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	&"position": [TYPE_VECTOR3, PROPERTY_HINT_RANGE, "-128,128,0.5,or_less,or_greater"],
	&"rotation_degrees": [TYPE_VECTOR3, PROPERTY_HINT_RANGE, "-180,180,1,or_less,or_greater,suffix:°"],
	&"scale": [TYPE_VECTOR3, PROPERTY_HINT_RANGE, "0,4,0.05,or_less,or_greater"],
	&"depth_bias": [TYPE_FLOAT, PROPERTY_HINT_RANGE, "-50,50,0.5,or_less,or_greater"],
}
const _ANIMATED_FIELDS: Array[StringName] = [&"position", &"rotation_degrees", &"scale", &"visible"]

## The GeoFigure editor (geo_figure_editor.gd), which applies the changes.
var editor: Object
var shapes: Array[GeoShape] = []


func _get_property_list() -> Array[Dictionary]:
	var title := "%d Shapes" % shapes.size() if shapes.size() != 1 else String(shapes[0].name)
	if _animating():
		title += " (posing)"
	var properties: Array[Dictionary] = [{
		"name": title,
		"type": TYPE_NIL,
		"usage": PROPERTY_USAGE_CATEGORY,
	}]
	for field: StringName in _FIELDS:
		if _animating() and not field in _ANIMATED_FIELDS:
			continue
		var info: Array = _FIELDS[field]
		properties.append({"name": field, "type": info[0], "hint": info[1],
				"hint_string": info[2], "usage": PROPERTY_USAGE_EDITOR})
	return properties


func _validate_property(property: Dictionary) -> void:
	if property.name == "script":
		property.usage = PROPERTY_USAGE_NONE


func _get(property: StringName) -> Variant:
	if _FIELDS.has(property) and not shapes.is_empty():
		return editor.field_value(shapes[0], property)
	return null


func _set(property: StringName, value: Variant) -> bool:
	if not _FIELDS.has(property):
		return false
	if not shapes.is_empty():
		editor.set_on_shapes(shapes, property, value, editor.field_value(shapes[0], property))
	return true


# Tells the Inspector not to make its own undo action (the editor makes one
# with every shape's old value).
func _dont_undo_redo() -> bool:
	return true


func _animating() -> bool:
	return editor != null and editor.animating
