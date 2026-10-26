# GeoRender

Fake-3D figures for Godot 4 2D scenes: trees of simple 3D shapes, drawn
smooth or in a style (pixel art, cel shading, or your own), that can be rotated,
animated per part
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
| `geo_figure.gd` | **GeoFigure**: the node that draws a shape tree. Per-part animation (`shapes/<name>/...` properties), flashing (`flash()`), exploding. |
| `geo_shape.gd` | **GeoShape**: the base class for shapes, with name, colour, transform and children. |
| `geo_camera.gd`, `default_geo_camera.tres` | **GeoCamera**: elevation and pixel size, shared by figures. Edit the default to change every figure. |
| `geo_geometry.gd`, `geo_compiled_model.gd` | Shape geometry, and shape trees flattened for drawing. |
| `shapes/` | Built-in shapes: Box, Cylinder, Disc, Group, Line, Panel, Sphere, Triangle. |
| `geo_style.gd` | **GeoStyle**: how figures look (a lighting pass and a display shader). |
| `styles/` | Built-in styles: `pixel_art.tres` (the default), `pixel_cel.tres`, `pixel_dither.tres` and `cel.tres` (flat shading, sketchy outlines), with their shaders. |
| `pixel/` | Styled drawing: the shared atlas, the animation frame cache, and the pixel art shaders. |
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
frames, while their keys stay smooth.

Stepped, styled figures in game draw pre-rendered frames rather than
rendering their shapes. The frames are built automatically the first time an
animation plays, in one render, and shared by every figure with the same shape,
animation, frame rate, `model_rotation_degrees`, camera and style (see
`pixel/geo_animation_cache.gd`). They look the same as live rendering, with
outlines and flashes, and cost a fraction as much. Figures render live instead:
- in the editor;
- while exploding;
- after code overrides a shape with `set_shape_*()`, until the next `play()`
  or `stop()`;
- when smooth or unstyled.

Turn the cache off with `GeoAnimationCache.enabled = false`.

Animations play deterministically: shape fields an animation doesn't set take
their RESET values.

The GeoFigure Editor sets this up for you, and can key poses into these
animations. Its Explode and Hit buttons preview `explode()` and `flash()` in its
views; Reset puts the figure back together.

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

## Styles

A figure's `style` (a GeoStyle) sets how it looks.

**How a style draws.** The shapes are first rendered into a shared atlas by the
style's `lighting_material`, one texel per `pixel_size` units. Each texel gets
its colour, plus a key in alpha saying which shape and surface it shows. The
figure then draws that, scaled up, with the style's `display_material`, which
can use the keys to find edges, e.g. for outlines.

**Built-in styles:**
- `styles/pixel_art.tres`: uses the camera's `pixel_size`.
- `styles/pixel_cel.tres`: pixel art with flat bands of shading instead of smooth
  shading, like an old computer's limited palette.
- `styles/pixel_dither.tres`: pixel art shaded with an ordered dither between
  three brightness levels.
- `styles/cel.tres`: 0.5 units per texel, with a margin for lines drawn
  outside the shapes. Its display shader's parameters set the line colour,
  width, wobble and wiggle. Lines re-squiggle whenever the figure's pose
  changes, so each animation frame gets new lines.

**Writing your own style.** Copy one of these and change the shaders. A display
shader must declare the instance uniforms GeoFigure sets: `flash_color`,
`flash_amount` and `line_seed`.

**Smooth figures.** With no style, the figure's mesh is drawn directly with its
`material` (see `geo_shading_example.gdshader`).
