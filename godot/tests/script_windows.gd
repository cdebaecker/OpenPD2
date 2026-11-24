extends SceneTree
## DASH script 13's windows driven from a worker thread as the scripts call them: a talk
## window (0x48BF90) with its portrait, more text (0x48C260), the escape's data window
## (its clear, datau.pac then hidan.pac, its text), the centred red note (0x452200), a
## script's red line (0x4521C0), the fades, the talk windows closed. Shots at each wait.
## Windowed: godot --path engine/godot -s tests/script_windows.gd -- <shot prefix>

var b
var shots := 0
var prefix := ""


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	prefix = args[0] if args.size() > 0 else ""
	await process_frame
	b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 2                    # script 13
	b.auto_react = true
	root.add_child(b)
	await process_frame
	b.auto_react = false
	var mh = b.mission_hooks
	var th := Thread.new()
	var log := []
	th.start(func():
		var h: int = mh.talk(MissionScripts.m13_face(b.w, 0), 0x134, [], -1, 0)
		log.append(["talk", h])
		log.append(["more", mh.talk_more(h, 0x137, [])])
		mh.talk_close(h)
		var hA: int = mh.talk(MissionScripts.m13_face(b.w, 0), 0x13A, [], -1, 3)
		mh.print_text(0x51C788)
		mh.picture()
		log.append(["print", mh.print_text(0x13B, [["machine", b.w.sb(0x2F, 0xC)]])])
		mh.picture()
		log.append(["more A", mh.talk_more(hA, 0x13E, [])])
		mh.talk_close(-2)
		log.append(["notice", mh.notice(0x12D)])
		log.append(["line", mh.line(0x12F)])
		log.append(["fuse", mh.fuse(0x12F, 20)])
		mh.fade(50)
		mh.fade(100)
		return log)
	var t0 := Time.get_ticks_msec()
	var seen := {}
	while th.is_alive() and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
		var fl = _role(b, "fuse")
		if fl != null:
			for i in 4:
				await process_frame
			_shot()
			fl.answer(2)
			continue
		var waiting = _waiting(b)
		if waiting != null:
			var key := str(waiting.get_instance_id())
			if not seen.has(key):
				seen[key] = true
				for i in 4:
					await process_frame
				_shot()
			waiting.outside(MOUSE_BUTTON_LEFT)
	var res: Array = th.wait_to_finish()
	print("log %s, shots %d, talk slots in use %s" % [res, shots, b.talk_used])
	var ok: bool = res.size() == 7 and res[0][1] == 0 and res[6][1] == 2 and shots >= 6 and not true in b.talk_used
	print("script windows: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)


func _waiting(n: Node):
	if n.get("_waiting") == true and n.is_visible_in_tree():
		return n
	for c in n.get_children():
		var r = _waiting(c)
		if r != null:
			return r
	return null


func _role(n: Node, r: String):
	if n.get("role") == r and n.is_visible_in_tree():
		return n
	for c in n.get_children():
		var x = _role(c, r)
		if x != null:
			return x
	return null


func _shot() -> void:
	shots += 1
	if prefix != "":
		root.get_viewport().get_texture().get_image().save_png("%s_%d.png" % [prefix, shots])
