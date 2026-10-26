# GeoRender

Fake-3D figures for Godot 4 2D scenes: trees of simple 3D shapes, drawn
smooth or as pixel art with outlines, that can be rotated, animated per part
and exploded.

## Using it

1. Copy `addons/geo_render/` into your project. It has no plugin to enable;
   its classes are available as soon as it's in the project.
2. Create a GeoShape resource (usually a `GeoGroup` root) and add shapes to
   its `children`.
3. Add a `GeoFigure` node to a scene and set its `shape`.

The GeoFigure Editor add-on (`addons/geo_figure_editor/`) gives you a visual
editor for building shape trees.

## What's included

| File | |
|---|---|
| `geo_figure.gd` | **GeoFigure**: the node that draws a shape tree. Per-part animation (`shapes/<name>/...` properties), flashing, exploding. |
| `geo_shape.gd` | **GeoShape**: the base class for shapes, with name, colour, transform and children. |
| `geo_camera.gd`, `default_geo_camera.tres` | **GeoCamera**: elevation and pixel size, shared by figures. Edit the default to change every figure. |
| `geo_geometry.gd`, `geo_compiled_model.gd` | Shape geometry, and shape trees flattened for drawing. |
| `shapes/` | Built-in shapes: Box, Cylinder, Disc, Group, Line, Panel, Sphere, Triangle. |
| `pixel/` | Pixel-art drawing: the shared atlas, lighting, and the default display shader with outlines (`geo_pixel_display.tres`). |
| `geo_shading_example.gdshader` | An example shader for smooth (non-pixel) figures. |

## Animation

A GeoFigure exposes each named shape's `position`, `rotation_degrees`,
`scale` and `visible` as properties, `shapes/<shape name>/<field>`. These
override the shape's values for that figure only, and an AnimationPlayer can
animate them.

To share a figure's animations with every figure using its shape:
1. Store them in an AnimationLibrary (its own `.tres` file), and set it as the
   root shape's `animations`.
2. Make the tracks relative to the figure, e.g.
   `.:shapes/antenna/rotation_degrees:z`.

Duplicating a shape shares its library rather than copying it.

Play the animations with the figure itself: `play("walk")`, `stop()`, or its
`autoplay` setting. No AnimationPlayer node is needed in your scene; the figure
creates a hidden one, which isn't saved. If the figure has a child
AnimationPlayer, it uses that instead. That's handy in an editing scene, since
Godot's Animation panel needs an AnimationPlayer in the open scene.

Set `animation_fps` (e.g. 12) to play animations in steps, like hand-drawn
frames, while their keys stay smooth. Stepped figures are also much cheaper:
they only redraw on each step, and figures spread their steps across frames.

The GeoFigure Editor sets this up for you, and can key poses into these
animations.

## Custom shapes

Extend `GeoShape` (or another shape), give the class a `class_name`, and
override `_build_geometry()` to add faces with `GeoGeometry.add_face()` or
`add_flat_face()`.

- Space is x right, y down, and z toward the camera.
- Each face must be flat and convex.
- Call `_geometry_changed()` from the setters of properties that change the
  geometry.
- Faces that point toward the camera are drawn in the order you add them.
  - Convex shapes can add faces in any order.
  - A shape with holes or dents should add the faces that can be hidden behind
    its others first.
- Faces can be visible side by side with a crease between them, like a box's
  sides. Give those faces different surface ids (0 to 2), so pixel outlines
  are drawn along the crease.
- An `@icon` on the class shows in the GeoFigure Editor.

See `res://shapes/geo_hex_nut.gd` in this project for an example.
