extends SceneTree
## The port's Options (the title's region 3, OPENING's place): the OPTIONS word over
## OPENING, its region, the opening in START's list, the options' list, a value stepped, applied and saved
## (to a test file: the player's settings.cfg is left alone), Back; a long GameWindow list
## scrolled by the wheel. Windowed: godot --path engine/godot -s tests/options_menu.gd

func _init() -> void:
	await process_frame
	var st = root.get_node("Settings")
	st.path = "user://settings_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.path))
	st.pace = 0
	st.music = 10
	var ga = root.get_node("GameAudio")
	ga.mode_asked = true
	var boot = load("res://ui/boot.tscn").instantiate()
	root.add_child(boot)
	current_scene = boot
	var ok := true
	var t0 := Time.get_ticks_msec()
	while not boot.title.menu_on and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
	# the word: OPTIONS' S (START's, rows 63 above) at its place, OPENING's G gone
	var same := 0
	for y in range(257, 279):
		for x in 13:
			if boot.title.bits[y * 640 + 293 + x] == boot.title.bits[(y - 63) * 640 + 205 + x]:
				same += 1
	var reg: Array = boot.title.regions[3]
	var r3: int = boot.title._region_at(Vector2(300, 266))
	print("OPTIONS' S pixels as START's %d / 286, region 3 %s, (300, 266) in region %d, regions %d" % [same, reg, r3, boot.title.regions.size()])
	ok = ok and same == 286 and r3 == 3 and boot.title.regions.size() == 5
	# START's list: the game's entries, then the opening
	boot.title.pick_region(0)
	var sl = null
	while sl == null:
		await process_frame
		sl = _find(boot.title.holder, "title_list")
	print("start list: %s" % [sl.items])
	ok = ok and sl.items.size() >= 2 and str(sl.items[-1]) == root.get_node("GameData").ui_text("UI_OPENING")
	sl.answer(-2)
	while not boot.title.menu_on:
		await process_frame
	# the list: its rows, a step of the pace, saved
	boot.title.pick_region(3)
	var l = null
	while l == null:
		await process_frame
		l = _find(boot.title.holder, "title_list")
	var rows: Array = l.items if l.items.size() > 0 else []
	print("rows %d: %s" % [rows.size(), rows])
	ok = ok and rows.size() == 10
	l.answer(2)
	await process_frame
	await process_frame
	var c := ConfigFile.new()
	var loaded := c.load(st.path) == OK
	print("pace %d, saved %s (pace %s)" % [st.pace, loaded, c.get_value("options", "pace", "-")])
	ok = ok and st.pace == 1 and loaded and int(c.get_value("options", "pace", -1)) == 1
	ok = ok and is_equal_approx(st.step_secs(), 0.012) and st.flight_steps() == 5
	l = null
	while l == null:
		await process_frame
		l = _find(boot.title.holder, "title_list")
	var row2: String = str(l.items[2])
	print("pace row after the step: %s" % row2)
	l.answer(9)                                  # Back
	var back := false
	for i in 60:
		await process_frame
		if boot.title.menu_on:
			back = true
			break
	print("back to the menu %s" % back)
	ok = ok and back
	# the wheel on a long list
	var labels := []
	for i in 15:
		labels.append("row %d" % i)
	var gw = load("res://ui/game_window.gd").select_window(0x40, 0x40, 20, 0, 1, labels, 20, [], true)
	boot.title.holder.add_child(gw)
	await process_frame
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = Vector2(20, 30)
	gw._gui_input(ev)
	gw._gui_input(ev)
	var down: int = gw.scroll
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	gw._gui_input(ev)
	print("wheel: down twice %d, up once %d" % [down, gw.scroll])
	ok = ok and down == 2 and gw.scroll == 1
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.path))
	print("options: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)


func _find(n: Node, role: String):
	if n.get("role") == role:
		return n
	for c in n.get_children():
		var r = _find(c, role)
		if r != null:
			return r
	return null
