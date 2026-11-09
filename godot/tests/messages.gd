extends SceneTree
const GD := preload("res://data/game_data.gd")
## The game's battle messages: Japanese from the import, English and French from the
## translation tables, formatted as format_text (0x435B10) does.

func _init() -> void:
	await process_frame
	var ok := true
	var gd = root.get_node("/root/GameData")
	for lang in ["ja", "en", "fr"]:
		gd.language = lang
		gd._translations.clear()
		var t: String = gd.battle_text("dash", 0x1DC, [5, 12, 3])
		var parts: Array = GD.prompt_parts(t)
		print("%s: %s | %s" % [lang, parts[0], parts[1]])
		ok = ok and parts[1].size() == 2 and t.contains("  5") and t.contains(" 12")
		print("   ", gd.battle_text("dash", 0x1AE, [8]), " / ", gd.battle_text("dash", 0x1A6))
	ok = ok and GD.format_text("%3d|%5s|%x|%%|%a70x%b|%x", [7, "ab", -3, 9, 26]) == "  7|ab   |-3|%|x|1A"
	print(GD.format_text("%3d|%5s|%x|%%|%a70x%b", [7, "ab", -3, 9]))
	quit(0 if ok else 1)
