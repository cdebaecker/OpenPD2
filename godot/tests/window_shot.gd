extends SceneTree
## The game's windows over a battle, saved as a picture: godot --path engine/godot -s
## tests/window_shot.gd -- pd2 0 out.png prompt|box|line|select|status|menu|weapon|reaction|command|units|arms|all|map|height|relief|orders|confirm|support [ja|en|fr]
##   all: 一斉's popup (0x429540); map: マップ's (0x43A3E0); height: its corners (0x43A900);
##   relief: the height map from the south-east, its last text up; orders: 指令書 (0x43BA20,
##   WMES 0x1A2); confirm: the area map's question (0x5146F0); support: the support
##   request's unit picker (0x4DFE70) with a support group set up
##   prompt: the move's question 0x1DC at the cursor (0x47EBE0); box: the mine's 0x1A3
##   (ui_message_box, kind 0); line: 0x1AE (ui_message_line) with its click wait lit;
##   select: a select window with 12 items (the scroll bar), the second outlined;
##   weapon: the first DoLL's weapon picker in mode 0 (0x4E7EE0) with 3 AP;
##   reaction: the reaction menu (0x4730E0) for three DoLLs;
##   command: the first DoLL's command menu (0x4EE8D0);
##   menu: the first DoLL's slot menu at the cursor (0x427530);
##   status: the machine status window (0x4E8930 / 0x467880) of the first active DoLL.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	if args.size() > 4:
		root.get_node("GameData").language = args[4]
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.sortie_window = false
	root.add_child(b)
	for i in 5:
		await process_frame
	b.cursor_override = Vector2(260, 220)
	var gw
	match args[3]:
		"prompt":
			gw = b.open_prompt(b.msg(0x1DC, [12, 30, 20]))
			gw._hover = 0
		"box":
			b._open_choice(b.msg(0x1A3), [[root.get_node("GameData").exe_text(b.campaign, 0x510444), true],
					[root.get_node("GameData").exe_text(b.campaign, 0x51044C), false]], "box")
			gw = b.react_panel.get_child(1)
			gw._hover = 0
		"line":
			b.show_line(b.msg(0x1AE, [12]))
			gw = b._line_open.get_child(0)
			gw.waits = true
			gw.print_text("\n")
			gw._waiting = true
			gw._bar = true
		"status":
			var u: int = b.squad[0]
			for k in b.squad:
				if b.w.active(k):
					u = k
					break
			b.w.setb(u, 1, (b.w.ub(u, 1) & 0xF0) | 0x01 | 0x08)      # head outlined, a gear filled
			gw = b.open_status(u, load("res://ui/status_view.gd").rows(b, u))
			gw._hover = 0
		"menu":
			var u: int = b.squad[0]
			var opts := []
			for e in load("res://core/pockets.gd").slot_menu(b.w, u, 0, false):
				opts.append(b.pocket_action_text(e[0], e[1]))
			gw = b.open_menu(opts)
			gw._hover = 0
		"weapon":
			var u: int = b.squad[0]
			b.w.setb(u, 0xE, 3)                               # short of AP: the AP column refused
			gw = b.open_weapon_picker(u, 0, 0)
			gw._hover = 0
		"reaction":
			var e := -1
			for k in b.w.n_units:
				if b.w.is_enemy(k) and b.w.active(k):
					e = k
					break
			b._show_reaction_units(b.squad.slice(0, 3), e, 5)
			gw = b.react_panel.get_child(0)
			gw._hover = 2
		"units":
			var u0: int = b.squad[0]
			b.info_panel.readouts(b.w.pos(u0).x, b.w.pos(u0).y, u0)      # (the hover's read-outs)
			b._units_list()
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 1
		"arms":
			b._arms_list(1)
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 0
		"command":
			var u: int = b.squad[0]
			b.open_command_menu(u)
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 3
		"all":
			b._all_orders()
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 0
		"map":
			b._map_menu()
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 1
		"height":
			b._height_menu()
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			gw._hover = 0
		"relief", "profile":
			b.height_map(0)
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
			for i in 3:
				await process_frame
			if args[3] == "relief":
				gw.outside(MOUSE_BUTTON_LEFT)    # past the profiles' '@'
				for i in 10:
					await process_frame
				for i in 3:
					await process_frame
		"orders":
			b._orders_sheet()
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(0)
		"confirm":
			var gd = root.get_node("GameData")
			b.open_order(gd.exe_text(b.campaign, 0x5146F0, [gd.call_sign(b.campaign, 0), 7, 4]),
					[gd.exe_text(b.campaign, 0x510454), gd.exe_text(b.campaign, 0x51045C)], 4)
			gw = b.win_root.get_child(b.win_root.get_child_count() - 1).get_child(1)
			gw._hover = 0
		"support":
			var k := 39
			for f in 55:
				b.w.setb(k, f, b.w.ub(b.squad[1], f))
			b.w.setb(k, 6, 0)
			for f in 35:
				b.w.groups[35 * 19 + f] = 0xFF if f >= 6 and f < 22 else 0
			b.w.groups[35 * 19 + 2] = 0x20
			b.w.groups[35 * 19 + 5] = 2
			b.w.groups[35 * 19 + 6] = k
			b.w.groups[35 * 19 + 7] = b.squad[2]
			b.w.groups[35 * 19 + 22] = 10
			b.w.groups[35 * 19 + 23] = 10
			b.w.groups[35 * 19 + 33] = 0x50
			b.w.setb(b.squad[2], 6, 1)
			var rows = b.support_unit_rows(load("res://core/strike.gd").support_units(b.w))
			gw = b.open_table([], rows, 0x3B)
			gw._hover = 0
		"select":
			var labels := []
			for i in 12:
				labels.append("%s %d" % [root.get_node("GameData").exe_text(b.campaign, 0x514008), i + 1])
			gw = b.open_select(b.ui("UI_PICK_WEAPON"), labels, true)
			gw._hover = 1
	gw.set_process(false)
	gw.queue_redraw()
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
