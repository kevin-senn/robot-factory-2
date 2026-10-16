@tool
extends EditorPlugin
## Adds the GeoFigure main screen (next to 2D, 3D and Script) for building
## GeoShape trees. It edits the shapes of the GeoFigure selected in the scene,
## or a GeoShape file opened from the FileSystem dock.

const Editor := preload("res://addons/geo_figure_editor/geo_figure_editor.gd")

var _editor: Editor
var _active := false


func _enter_tree() -> void:
	_editor = Editor.new()
	_editor.plugin = self
	_editor.load_settings()
	_editor.hide()
	EditorInterface.get_editor_main_screen().add_child(_editor)
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)


func _exit_tree() -> void:
	EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)
	_editor.queue_free()


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return "GeoFigure"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"MeshInstance2D", &"EditorIcons")


func _make_visible(visible: bool) -> void:
	_active = visible
	_editor.visible = visible
	if visible:
		_on_selection_changed()


# GeoFigures are only claimed while this screen is showing, so selecting one
# in the 2D editor doesn't switch screens.
func _handles(object: Object) -> bool:
	return object is GeoShape or (_active and object is GeoFigure)


func _edit(object: Object) -> void:
	if object is GeoFigure:
		if object.shape:
			_editor.set_root(object.shape)
	elif object is GeoShape:
		if _editor.contains_shape(object):
			_editor.select([object], false)
		else:
			_editor.set_root(object)


func _on_selection_changed() -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	if nodes.size() == 1 and nodes[0] is GeoFigure and nodes[0].shape:
		_editor.set_root(nodes[0].shape)


func _save_external_data() -> void:
	_editor.save_changes()


func _get_unsaved_status(for_scene: String) -> String:
	if for_scene.is_empty() and _editor.has_unsaved_changes():
		return "Save changes to the edited GeoFigure shapes before closing?"
	return ""
