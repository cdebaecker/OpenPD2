extends SceneTree
## The area map (マップ entry 0, 0x43A570) in PD2 mission 1: the flight window opens over the
## side panel (it is 640 x 400 in the game: its status rows and close button were under the
## port's panel) and its close button (region 20) ends it.
## Windowed: godot --path engine/godot -s tests/area_map_view.gd

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.pick_window = false
	b.plan_window = false
	b.sortie_window = false
	root.add_child(b)
	for i in 300:
		await process_frame
	b._area_map()
	var r = null
	for i in 120:
		await process_frame
		r = b.radar_view
		if r != null and r.visible and r.pick == "region":
			break
	var over: bool = r != null and r.visible and r.get_parent() == b.info_panel.get_parent() 			and r.get_index() > b.info_panel.get_index()
	var p := Vector2(0x260, 0x187)
	for pressed in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = pressed
		ev.position = p
		r._gui_input(ev)
	for i in 60:
		await process_frame
	var closed: bool = not b.busy and not r.visible
	var ok := over and closed
	print("flight window over the panel %s, closed by its button %s: %s" % [over, closed, "ok" if ok else "FAILED"])
	quit(0 if ok else 1)
