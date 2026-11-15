extends SceneTree
## 部隊 (0x4EFC60) and 武装's unit list (0x4EA950) loop as the game's: a unit's command menu
## (unit_command_menu) comes back after its command (search here, its questions answered
## with their first answer), and the menu's right click opens the list again.

var b


func _init() -> void:
	await process_frame
	b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.sortie_window = false
	root.add_child(b)
	for i in 3:
		await process_frame
	var ok := true
	for path in ["units", "arms"]:
		if path == "units":
			b._units_list()
			ok = ok and await _answer("units", 0)
		else:
			b._arms_list(0)
			ok = ok and await _answer("arms_list", 0)
			ok = ok and await _answer("arms_who", 0)
		ok = ok and await _answer("command", 8)        # search
		var again: bool = await _wait_for("command")
		print("%s: the command menu again after the search: %s" % [path, again])
		ok = ok and again
		ok = ok and await _answer("command", -2)       # its right click
		var back := "units" if path == "units" else "arms_who"
		var listed: bool = await _wait_for(back)
		print("%s: its right click opens the list again: %s" % [path, listed])
		ok = ok and listed
		ok = ok and await _answer(back, -2)
	print("units loop: %s" % ok)
	quit(0 if ok else 1)


func _top() -> Variant:
	## the last window open in the main window (the lists and menus are not questions of a
	## waiting thread: react_panel stays null for them)
	var r = b.win_root
	if r == null or not is_instance_valid(r):
		return null
	for i in range(r.get_child_count() - 1, -1, -1):
		var hold = r.get_child(i)
		if hold.is_queued_for_deletion():
			continue
		var wins: Array = hold.get_children().filter(func(n): return n.has_method("answer") and not n.is_queued_for_deletion())
		if not wins.is_empty():
			return wins[-1]
	return null


func _wait_for(role: String) -> bool:
	## answers the other windows (their first answer) until one of the role is up
	for f in 600:
		await process_frame
		var gw = _top()
		if gw == null:
			continue
		if gw.role == role:
			return true
		if gw.waits and gw._waiting:
			gw.outside(MOUSE_BUTTON_LEFT)
		else:
			gw.answer(0)
	return false


func _answer(role: String, v: int) -> bool:
	if not await _wait_for(role):
		print("no %s window" % role)
		return false
	_top().answer(v)
	await process_frame
	return true
