extends SceneTree
## A shot of the title (not a test; windowed): godot --path engine/godot -s tests/title_shot.gd --
## out.png <seconds> [hover|hover3|options|list|version|exit|continue|scenario|opening <seconds in>]
## The title runs as in play (the logos first); after <seconds> the shot is saved. hover /
## list / version / exit act once the menu is up; opening starts it and shoots after its
## own seconds.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "title.png"
	var secs := float(args[1]) if args.size() > 1 else 20.0
	var act := args[2] if args.size() > 2 else ""
	await process_frame
	var ga = root.get_node("GameAudio")
	if not "cd" in args:
		ga.mode_asked = true                # (the CD-DA / MIDI list skipped: MIDI)
	var boot = load("res://ui/boot.tscn").instantiate()
	root.add_child(boot)
	current_scene = boot
	var t0 := Time.get_ticks_msec()
	if act != "":
		while not boot.title.menu_on and Time.get_ticks_msec() - t0 < 60000:
			await process_frame
		match act:
			"hover":
				boot.title._set_outline(0)
			"hover3":                                # the port's OPTIONS (OPENING's place)
				boot.title._set_outline(3)
			"options":                               # the port's options list
				boot.title.pick_region(3)
			"list":
				boot.title.pick_region(0)
			"version":
				boot.title.pick_region(4)
			"exit":
				boot.title.pick_region(2)
			"continue":                              # the save list, or MES0 0xD's note
				boot.title.pick_region(1)
			"scenario":                              # the start list's entry 1, its list
				boot.title.pick_region(0)
				var l = null
				while l == null:
					await process_frame
					l = _find(boot.title.holder, "title_list")
				l.answer(1)
			"opening":                               # the start list's last entry (the port's)
				boot.title.pick_region(0)
				var l = null
				while l == null:
					await process_frame
					l = _find(boot.title.holder, "title_list")
				l.answer(l.items.size() - 1)
				secs = float(args[3]) if args.size() > 3 else 5.0
		t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < secs * 1000.0:
		await process_frame
	await process_frame
	root.get_viewport().get_texture().get_image().save_png(out)
	print("saved ", out)
	quit(0)


func _find(n: Node, role: String):
	if n.get("role") == role:
		return n
	for c in n.get_children():
		var r = _find(c, role)
		if r != null:
			return r
	return null
