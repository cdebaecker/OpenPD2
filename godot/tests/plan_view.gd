extends SceneTree
## The operation plan's window (ui/plan_view.gd) in play, on PD2's mission 1:
## 1. page B (its hook blinks four points on the mini-map, one per click): each click
##    shows the next lines and the next blink (Plan.view_step), then the page is done.
## 2. the XMS spot (region 8): its box ("XMS : USE" / "XMS : unUSE"), gone on a click.
## 3. the orders (region 4): plan_gb.pac while they are open, plan_gc.pac after them.
## 4. done (region 6): the window closes, the sortie screen opens.


func _init() -> void:
	await process_frame
	var ok := true
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	root.add_child(b)
	await process_frame
	var v: PlanView = b.plan_view
	ok = ok and v != null
	b._plan_region(1)
	var shown := []
	var n := 0
	while v.blink != null and n < 10:
		shown.append([v.lines.size(), v.blink[0]])
		v.advanced.emit()
		n += 1
	var page_ok: bool = n == 4 and v.blink == null and v.lines.size() == 6 and shown[0][0] == 1 \
		and v.views.any(func(x): return x[0] == "pic" and x[1] == "mmap.pac")
	print("page B: %d blinks, lines by step %s, done with %d lines" % [n, str(shown), v.lines.size()])
	ok = ok and page_ok
	b._plan_region(8)
	var xms: bool = v.note.begins_with("XMS")
	var ev := InputEventMouseButton.new()
	ev.pressed = true
	ev.button_index = MOUSE_BUTTON_LEFT
	v._gui_input(ev)
	xms = xms and v.note == ""
	print("XMS box: %s" % str(xms))
	ok = ok and xms
	b._plan_region(4)
	var open: bool = v.orders == "open"
	b._plan_leave()                     # (an objective question first: answered leave)
	if b.plan_st.ask != null:
		b.plan_st.ask = null
		b.plan_st.mode = "page"
	b._plan_draw()
	var closed: bool = v.orders == "closed" and b.plan_st.mode != "orders"
	print("orders: plan_gb %s, plan_gc after %s" % [str(open), str(closed)])
	ok = ok and open and closed
	b._plan_region(6)
	await process_frame
	var done: bool = b.plan_view == null and b.plan_panel == null and b.sortie_panel != null
	print("done: the sortie screen %s" % str(done))
	ok = ok and done
	b.queue_free()
	print("plan view flow: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
