@tool
extends RefCounted
## Inspected in place of the selected shapes when several are selected (the
## Inspector can only edit several nodes at once, not several resources). It
## shows the first shape's values; changing one sets it on every shape, as one
## undo action. For vectors, only the components that changed are set, so
## setting position.y lines the shapes up without moving them in x or z.

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

## The GeoFigure editor (geo_figure_editor.gd), which applies the changes.
var editor: Object
var shapes: Array[GeoShape] = []


func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = [{
		"name": "%d Shapes" % shapes.size(),
		"type": TYPE_NIL,
		"usage": PROPERTY_USAGE_CATEGORY,
	}]
	for field: StringName in _FIELDS:
		var info: Array = _FIELDS[field]
		properties.append({"name": field, "type": info[0], "hint": info[1],
				"hint_string": info[2], "usage": PROPERTY_USAGE_EDITOR})
	return properties


func _validate_property(property: Dictionary) -> void:
	if property.name == "script":
		property.usage = PROPERTY_USAGE_NONE


func _get(property: StringName) -> Variant:
	if _FIELDS.has(property) and not shapes.is_empty():
		return shapes[0].get(property)
	return null


func _set(property: StringName, value: Variant) -> bool:
	if not _FIELDS.has(property):
		return false
	if not shapes.is_empty():
		editor.set_on_shapes(shapes, property, value, shapes[0].get(property))
	return true


# Tells the Inspector not to make its own undo action (the editor makes one
# with every shape's old value).
func _dont_undo_redo() -> bool:
	return true
