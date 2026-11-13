extends SceneTree
## Render the armament screen (0x454E60) for a group's first member, or the first air /
## armoured pilot: godot --path engine/godot -s tests/equip_shot.gd -- pd2 0 out.png
## <group|air|armour> [region to press first | menu] [answers ...]
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
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
		print("unit ", k)
	else:
		k = Flight.gb(b.w, int(args[3]), 6)
	b._equip_begin(k)
	if args.size() > 4:
		if args[4] == "menu":
			b.equip_cursor = Vector2(0x150, 0x100)
			b._equip_press("menu")
		else:
			b._equip_region(int(args[4]))
	for i in range(5, args.size()):        # answers to the windows that open
		b._equip_answer(int(args[i]))
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
