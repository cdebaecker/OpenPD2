extends SceneTree
## Render the operation plan before a battle and save it: godot --path engine/godot -s
## tests/plan_shot.gd -- pd2 0 out.png [page] [clicks] [orders [list]|xms|list|maps]
## page: 0-3 (A-D, default 1), clicks: the page's waits clicked through (default 0: the
## first blink shown lit); "orders" opens the orders (plan_gb.pac), "xms" the XMS box,
## "list" the plans' list (0x4442C0), "maps" the area maps (0x444500).

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.pick_window = false                         # (a campaign's first mission: no pilot choice window)
	root.add_child(b)
	for i in 5:
		await process_frame
	var k := int(args[3]) if args.size() > 3 else 1
	b._plan_region(k)
	b.plan_st.j = int(args[4]) if args.size() > 4 else 0
	match args[5] if args.size() > 5 else "":
		"orders":
			b._plan_region(4)
		"xms":
			b._plan_region(8)
		"list":
			b._plan_region(5)                 # the plans' list: its first group's text
		"maps":
			b._plan_region(7)                 # the area maps: the first
	if args.size() > 6 and args[5] == "orders":
		b._plan_order_region(int(args[6]))       # one of the orders' lists (1 group .. 4 time)
	elif not (args.size() > 5 and args[5] in ["list", "maps"]):
		b._plan_draw()
	if b.plan_view:
		b.plan_view._on = true                # the blink lit
		b.plan_view.set_process(false)
		b.plan_view.queue_redraw()
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
