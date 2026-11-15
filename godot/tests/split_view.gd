extends SceneTree
## 0x40F870's framing in a windowed run (headless runs skip it): a near target frames
## both hexes (the origin from the game's formula), a far one splits the map window (the
## shooter's half on top, the band, the target's half below) and 0x410510 closes it, the
## view at the target's half's origin 3 rows up.
## godot --path engine/godot -s tests/split_view.gd [-- out.png]

var done := false


func _init() -> void:
	await process_frame
	var out := ""
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out = args[0]
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.sortie_window = false
	root.add_child(b)
	for i in 5:
		await process_frame
	if b._headless():
		print("split view: headless, the framing is off (run it windowed)")
		quit(0)
		return
	b.options = b.options & ~0x10
	var w: Pd2World = b.w
	var u: int = b.squad[0]
	var p: Vector2i = w.pos(u)
	var ok := true
	# a near target: the framed origin
	var v: Rect2i = b.map_view_cells()
	var t := Vector2i(clampi(p.x + 4, 1, 70), clampi(p.y + 3, 1, 70))
	await _on_worker(func(): b.anim_view(u, p.x, t.x, t.y))
	var dx := absi(p.x - t.x)
	var dy := absi(p.y - t.y)
	var ox := p.x - (v.size.x - dx) / 2 + (2 if dx > 3 else 0) if t.x >= p.x else t.x - (v.size.x - dx) / 2
	var oy := p.y - (v.size.y - dy) / 2 + (2 if dy > 5 else 0) if p.y < t.y else t.y - (v.size.y - dy) / 2
	ox = maxi(1, mini(maxi(1, ox), 0x47 - v.size.x))
	oy = maxi(1, mini(maxi(1, oy), 0x47 - v.size.y))
	var got: Rect2i = b.map_view_cells()
	print("near: origin %s, want (%d, %d); split %s" % [got.position, ox, oy, b.split_view_rect().has_area()])
	ok = ok and got.position == Vector2i(ox, oy) and not b.split_view_rect().has_area()
	# a far target: the split
	var far := Vector2i(p.x, clampi(p.y - v.size.y, 1, 70) if p.y > 36 else clampi(p.y + v.size.y, 1, 70))
	await _on_worker(func(): b.anim_view(u, p.x, far.x, far.y))
	var split: bool = b.split_view_rect().has_area()
	print("far: split %s, the target's half at %s" % [split, b.split_origin])
	ok = ok and split
	for i in 4:
		await process_frame
	if out != "":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out)
		print("saved %s" % out)
	# the missile's lines (0x41B320): split, two lines, each in its half
	var rec := [8, p.x, p.y, far.x, far.y, u]
	var segs: Array = b.anime_view.flight_segments(rec)
	var win: Dictionary = b.flight_window()
	print("flight while split: %d lines %s; halves S %s Q %s" % [segs.size(), segs, win.get("S"), win.get("Q")])
	ok = ok and segs.size() == 2 and b.anime_view.flight_points(rec, 2).size() > 0
	# an unseen shooter (record +6 = -1): one line from the window's edge
	var rec2 := [8, -1, 0, far.x, far.y, u]
	var segs2: Array = b.anime_view.flight_segments(rec2)
	var a2: Vector2i = segs2[0][0]
	var on_edge: bool = a2.x == win.L or a2.y == win.T or a2.x >= win.R or a2.y >= win.B
	print("unseen: %s from the window's edge %s (L %d T %d R %d B %d)" % [segs2, on_edge, win.L, win.T, win.R, win.B])
	ok = ok and segs2.size() == 1 and on_edge
	var want: Vector2i = b.split_origin - Vector2i(0, 3)
	await _on_worker(func(): b.anim_close())
	got = b.map_view_cells()
	print("closed: split %s, origin %s (the target's half's less 3 rows: %s)" % [b.split_view_rect().has_area(), got.position, want])
	ok = ok and not b.split_view_rect().has_area() and got.position.x == want.x and got.position.y == maxi(1, want.y)
	print("split view: %s" % ok)
	quit(0 if ok else 1)


func _on_worker(f: Callable) -> void:
	done = false
	var th := Thread.new()
	th.start(func():
		f.call()
		done = true)
	var t0 := Time.get_ticks_msec()
	while not done and Time.get_ticks_msec() - t0 < 5000:
		await process_frame
	th.wait_to_finish()
	await process_frame
