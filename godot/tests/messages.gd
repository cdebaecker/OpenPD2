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
	# the radio lines: DASH reuses PD2's but adds a click to 0x45 (not in entry 7), and the
	# lines an entry leaves empty stay empty
	gd.language = "en"
	gd._translations.clear()
	var r1: String = gd.battle_text("dash", 0x21, ["SilverFox", "EagleClaw"], 0)
	var r2: String = gd.battle_text("dash", 0x45, [], 0)
	var r3: String = gd.battle_text("dash", 0x45, [], 7)
	var r4: String = gd.battle_text("dash", 0x21, ["SilverFox", "EagleClaw"], 9)
	var r5: String = gd.battle_text("pd2", 0x45, [], 3)
	print("   radio: ", r1, " | ", r2, " | ", r3, " | '", r4, "' | ", r5)
	ok = ok and r4 == "" and r2.ends_with("@") and not r3.ends_with("@")
	if gd._translated("wmes", "dash.21") != "":        # the translations are installed
		ok = ok and r1 == "SilverFox to EagleClaw: approaching the target area.@" \
			and r5 == "Awaiting ground-attack orders."
	ok = ok and GD.format_text("%3d|%5s|%x|%%|%a70x%b|%x", [7, "ab", -3, 9, 26]) == "  7|ab   |-3|%|x|1A"
	print(GD.format_text("%3d|%5s|%x|%%|%a70x%b", [7, "ab", -3, 9]))
	quit(0 if ok else 1)
