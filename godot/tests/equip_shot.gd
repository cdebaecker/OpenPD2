extends SceneTree
## Render the armament screen (0x454E60) for a group's first member, or the first air /
## armoured pilot: godot --path engine/godot -s tests/equip_shot.gd -- pd2 0 out.png
## <group|air|armour> [region to press first | menu | debug] [answers ...]
## (debug: the Ctrl + Alt menu 0x4595F0, the answers given in turn before the shot)
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	for a in args.duplicate():
		if a.begins_with("lang="):                 # (lang=ja|en|fr anywhere: the language)
			root.get_node("GameData").language = a.substr(5)
			args.erase(a)
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.pick_window = false
	b.plan_window = false
	root.add_child(b)
	for i in 10:
		await process_frame
	var k := -1
	if args[3] in ["air", "armour"]:
		# the first pilot of that layout (crew +3 = 1; an armoured machine's +0 & 0xF != 0)
		for c in 64:
			var m := Flight.s8(b.w.ub(c, 0xC))
			if args[3] == "air" and b.w.cb(c, 3) == 1 and b.w.cb(c, 2) == 0:
				k = c
				break
			if args[3] == "armour" and b.w.cb(c, 3) == 0 and m >= 0 and b.w.machine(m, 0) & 15 != 0 and b.w.cb(c, 2) == 0:
				k = c
				break
		if k == -1 and args[3] == "armour":
			# (none in this mission: the first ground pilot given the first armoured machine,
			# for the picture only)
			for c in 64:
				if b.w.cb(c, 3) == 0 and b.w.cb(c, 2) == 0 and Flight.s8(b.w.ub(c, 0xC)) >= 0:
					for m in 32:
						if b.w.machine(m, 0) & 15 != 0:
							b.w.units[c * Pd2World.UNIT + 0xC] = m
							k = c
							break
					break
		print("unit ", k)
	else:
		k = Flight.gb(b.w, int(args[3]), 6)
	b._equip_begin(k)
	if args.size() > 4 and args[4] == "debug":
		for i in range(5, args.size()):
			b.scripted.append(int(args[i]))
		b._equip_debug()
		for i in 10:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_viewport().get_texture().get_image().save_png(args[2])
		b.scripted = [-2, -2, -2, -2]
		b.react_answer = -2
		b.react_sem.post()
		while b.debug_thread != null:
			await process_frame
		quit(0)
		return
	if args.size() > 4:
		if args[4] == "menu":
			b.equip_cursor = Vector2(0x30, 0x90)
			b._equip_press("menu")
		else:
			b._equip_region(int(args[4]))
	for i in range(5, args.size()):        # answers to the windows that open
		if b.equip_request != null and b.equip_request[0] == "pick" and int(args[i]) >= 0 and int(args[i]) < b.equip_request[2].size() and str(b.equip_request[2][int(args[i])]).begins_with("crew"):
			b.equip_preview = b.equip_request[2][int(args[i])]       # (as a click on that row sets it)
		b._equip_answer(int(args[i]))
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
