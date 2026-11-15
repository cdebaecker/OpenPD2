extends SceneTree
## The title screen (ui/boot.gd, ui/title_view.gd) driven through its windows: region 0's list,
## the scenario select's list (DASH's mission 12), then the battle scene it starts.

func find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var b := find_button(c, text)
		if b != null:
			return b
	return null


func find_role(n: Node, role: String):
	if n.get("role") == role:
		return n
	for c in n.get_children():
		var r = find_role(c, role)
		if r != null:
			return r
	return null


func _init() -> void:
	await process_frame
	var boot = load("res://ui/boot.tscn").instantiate()
	root.add_child(boot)
	current_scene = boot
	await process_frame
	var ok := true
	# the title's region 0 (the start list, 0x452A10 at (0x120, 0xD8)), its entry 1 (シナリオ選択)
	var tv = boot.title
	for i in 50:
		if tv.menu_on:
			break
		await process_frame
	ok = ok and tv.menu_on
	tv.pick_region(0)
	var lst = null
	for i in 50:
		await process_frame
		lst = find_role(tv.holder, "title_list")
		if lst != null:
			break
	ok = ok and lst != null and lst.items.size() == 3
	if lst != null:
		lst.answer(1)
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
