extends SceneTree
## Render the flight window (the radar map, its status list and a radio talk window) as
## the battle shows it while the flight engine runs, and save it:
## godot --path engine/godot -s tests/radar_shot.gd -- pd2 0 out.png
## A live group is put in flight (on cell 6, 9); the window opens through the flight
## engine's own path (Flight.grid_init with the battle's hooks: the groups marked), then
## a talk window (code 0x1A: the first window group, kind 1, number 10) shows portrait 0 and a radio line. Exits 1 when the
## window did not open or holds no marked cell.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.sortie_window = false
	root.add_child(b)
	for i in 10:
		await process_frame
	var w: Pd2World = b.w
	var flown := -1
	for g in 64:                                  # a live group in flight, on the grid
		if Flight.group_alive(w, g) and (g > 11 or g & 1 or Flight.gb(w, g, 2) & 0x30):
			Flight.setgb(w, g, 0x16, 6)
			Flight.setgb(w, g, 0x17, 9)
			flown = g
			break
	print("in flight: group %d" % flown)
	Flight.grid_init(w, b.flight_hooks, 0)
	b.flight_hooks.radio_face(0, 0x1A, 0)
	b.flight_hooks.radio_say(0x21, [], 0x1A)
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	var marked := 0
	for v in w.grid:
		if v:
			marked += 1
	print("radar: open %s, marked cells %d, talk windows %d" % [b.radar_view != null and b.radar_view.visible,
			marked, b.radar_view.faces.size() if b.radar_view else 0])
	quit(0 if b.radar_view != null and b.radar_view.visible and marked > 0 else 1)
