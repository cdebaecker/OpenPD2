extends Control
## Start screen: checks the import and lists the missions of both campaigns.

const BATTLE := "res://ui/battle.tscn"


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 24
	box.offset_top = 16
	box.offset_right = -24
	box.offset_bottom = -16
	add_child(box)
	var title := Label.new()
	title.text = "POWER DoLLS 2 — engine sandbox"
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	if not GameData.available():
		var msg := Label.new()
		msg.autowrap_mode = TextServer.AUTOWRAP_WORD
		msg.text = ("No game data found in %s.\n\nRun the importer on your own copy of "
			+ "POWER DoLLS 2 plus DASH:\n    python -X utf8 engine/importer/pd2_import.py <CD image or game folder>") % ProjectSettings.globalize_path(GameData.ROOT)
		box.add_child(msg)
		return
	var ver := Label.new()
	ver.text = "Data: %s" % GameData.manifest.get("version", "?")
	box.add_child(ver)
	var note := Label.new()
	note.text = "Sandbox: the briefing is not ported yet, so 4 DoLLS are dropped where the enemy is farthest."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(note)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	scroll.add_child(grid)
	for camp in ["pd2", "dash"]:
		for m in GameData.mission_count(camp):
			var b := Button.new()
			b.text = "%s  mission chunk %d" % [camp.to_upper(), m]
			b.pressed.connect(_start.bind(camp, m))
			grid.add_child(b)


func _start(camp: String, m: int) -> void:
	var scene: PackedScene = load(BATTLE)
	var battle := scene.instantiate()
	battle.campaign = camp
	battle.mission_index = m
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	queue_free()
