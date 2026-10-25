@tool
extends RefCounted
## Stateless helpers for the GeoFigure editor: shape transforms, projected
## outlines, hit tests and transform conversions. "Model space" is the space of
## the figure's root shape (before the view rotation); "view units" are the
## projected x and y, before the view's zoom and pan.

const _EULER_ORDER := EULER_ORDER_YXZ # GeoShape.rotation_degrees' order.


## Each shape's transform into model space, built like GeoFigure builds its
## pose. Fields come from values(shape, field) if given (e.g. to use a figure's
## animated pose), else from the shapes themselves.
static func model_transforms(model: GeoCompiledModel,
		values := Callable()) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	result.resize(model.shapes.size())
	for i in model.shapes.size():
		var shape := model.shapes[i]
		var local: Transform3D
		if values.is_valid():
			local = GeoShape.make_transform(values.call(shape, &"position"),
					values.call(shape, &"rotation_degrees"), values.call(shape, &"scale"))
		else:
			local = GeoShape.make_transform(shape.position, shape.rotation_degrees, shape.scale)
		var parent := model.parents[i]
		result[i] = local if parent < 0 else result[parent] * local
	return result


## 1 for each shape that's hidden, by itself or by an ancestor. values is as in
## model_transforms().
static func hidden_flags(model: GeoCompiledModel, values := Callable()) -> PackedByteArray:
	var hidden := PackedByteArray()
	hidden.resize(model.shapes.size())
	for i in model.shapes.size():
		var parent := model.parents[i]
		var visible: bool = values.call(model.shapes[i], &"visible") if values.is_valid() \
				else model.shapes[i].visible
		hidden[i] = 1 if not visible or (parent >= 0 and hidden[parent] == 1) else 0
	return hidden


## Rotates model space into view space, like a GeoFigure with this camera
## elevation and model_rotation_degrees.
static func view_basis(elevation: float, model_rotation_degrees: Vector3) -> Basis:
	return GeoCamera.make_view_basis(elevation) * Basis.from_euler(to_radians(model_rotation_degrees))


## The convex outline of points after transforming them into view space, as
## a closed polygon (the first point repeated at the end) in view units.
static func project_hull(points: PackedVector3Array, xform: Transform3D) -> PackedVector2Array:
	var flat := PackedVector2Array()
	for p in xform * points:
		flat.append(Vector2(p.x, p.y))
	return Geometry2D.convex_hull(flat)


## Whether point is inside the hull, or within tolerance of its edges (so flat
## shapes seen edge-on can still be clicked).
static func hull_contains(hull: PackedVector2Array, point: Vector2, tolerance: float) -> bool:
	if hull.size() >= 4 and Geometry2D.is_point_in_polygon(point, hull):
		return true
	if hull.size() == 1:
		return point.distance_to(hull[0]) <= tolerance
	for i in hull.size() - 1:
		var closest := Geometry2D.get_closest_point_to_segment(point, hull[i], hull[i + 1])
		if point.distance_to(closest) <= tolerance:
			return true
	return false


## Whether any part of the hull is inside rect.
static func hull_overlaps_rect(hull: PackedVector2Array, rect: Rect2) -> bool:
	for p in hull:
		if rect.has_point(p):
			return true
	var corners := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y),
			rect.end, Vector2(rect.position.x, rect.end.y)])
	if hull.size() >= 4:
		for corner in corners:
			if Geometry2D.is_point_in_polygon(corner, hull):
				return true
	for i in hull.size() - 1:
		for j in 4:
			if Geometry2D.segment_intersects_segment(hull[i], hull[i + 1],
					corners[j], corners[(j + 1) % 4]) != null:
				return true
	return false


## Splits a local transform into GeoShape's position, rotation_degrees and
## scale. (Exact unless the transform is skewed, e.g. by a rotated child of a
## non-uniformly scaled parent.)
static func decompose(xform: Transform3D) -> Dictionary:
	var shape_scale := xform.basis.get_scale()
	var rotation := Basis(xform.basis.get_rotation_quaternion())
	return {
		&"position": tidy(xform.origin),
		&"rotation_degrees": tidy(to_degrees(rotation.get_euler(_EULER_ORDER))),
		&"scale": tidy(shape_scale),
	}


## A shape's rotation_degrees after rotating it by angle (radians) around
## model_axis, about its own origin. parent_basis is its parent's model-space
## basis.
static func rotate_about_axis(rotation_degrees: Vector3, parent_basis: Basis,
		model_axis: Vector3, angle: float) -> Vector3:
	var parent_rotation := parent_basis.orthonormalized()
	var rotation := Basis.from_euler(to_radians(rotation_degrees))
	var turned := parent_rotation.inverse() * Basis(model_axis.normalized(), angle) \
			* parent_rotation * rotation
	return tidy(to_degrees(turned.orthonormalized().get_euler(_EULER_ORDER)))


## The classes that extend GeoShape and can be created, as
## [{name, class, path}], sorted by name ("Box", "Cylinder", ...).
static func shape_types() -> Array[Dictionary]:
	var classes := ProjectSettings.get_global_class_list()
	var by_name := {}
	for info in classes:
		by_name[info["class"]] = info
	var result: Array[Dictionary] = []
	for info in classes:
		if info.get("is_abstract", false):
			continue
		var base: StringName = info["base"]
		for depth in 32:
			if base == &"GeoShape" or not by_name.has(base):
				break
			base = by_name[base]["base"]
		if base == &"GeoShape":
			result.append({"name": String(info["class"]).trim_prefix("Geo"),
					"class": info["class"], "path": info["path"],
					"icon": info.get("icon", "")})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.name < b.name)
	return result


## Rounds away floating-point noise, so edited values stay readable.
static func tidy(value: Vector3) -> Vector3:
	return value.snapped(Vector3.ONE * 0.0001)


static func to_radians(degrees: Vector3) -> Vector3:
	return Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z))


static func to_degrees(radians: Vector3) -> Vector3:
	return Vector3(rad_to_deg(radians.x), rad_to_deg(radians.y), rad_to_deg(radians.z))
