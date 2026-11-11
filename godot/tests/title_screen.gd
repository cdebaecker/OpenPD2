extends SceneTree
## The title screen (ui/boot.gd) driven through its windows: button 0's list, the scenario
## select's list (DASH's mission 12), then the battle scene it starts.

func find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := find_button(c, text)
		if b != null:
			return b
	return null


func _init() -> void:
	await process_frame
	var boot = load("res://ui/boot.tscn").instantiate()
	root.add_child(boot)
	current_scene = boot
	await process_frame
	var gd = root.get_node("/root/GameData")
	var ok := true
	var start := find_button(boot, gd.ui_text("UI_TITLE_START"))
	ok = ok and start != null
	start.pressed.emit()
	await process_frame
	var names: Array = load("res://ui/save_files.gd").choice_texts(0x50D86C)
	var sel := find_button(boot, names[1])          # シナリオ選択
	ok = ok and sel != null
	sel.pressed.emit()
	var mission: String = load("res://ui/save_files.gd").mission_name(12)
	var pick: Button = null
	for i in 200:
		await process_frame
		pick = find_button(boot, mission)
		if pick != null:
			break
	ok = ok and pick != null
	if pick != null:
		pick.pressed.emit()
	var b = null
	for i in 400:
		await process_frame
		if current_scene != null and current_scene != boot and current_scene.get("script_no") != null:
			b = current_scene
			break
	if b != null:
		print("title -> battle: %s chunk %d, mission %d, mode %d" % [b.campaign, b.mission_index + 1, b.script_no,
			Debrief.campaign_mode(b.w)])
		ok = ok and b.campaign == "dash" and b.script_no == 12 and Debrief.campaign_mode(b.w) == 2
	else:
		ok = false
	print("title screen: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
