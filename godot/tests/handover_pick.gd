extends SceneTree
## PD2's step 7 cleared hands over to DASH (Debrief._to_dash): the debrief's screens up to
## kabe4.pac, then the new campaign's pilot choice (0x421B90 / 0x422050) in its windows with
## DASH's texts and roster (the player's: here a pilot picked, then the right click's
## "fill at random"), then DASH's first mission (script 12) with 11 pilots picked.
## Windowed (the choice waits for the player): godot --path engine/godot -s tests/handover_pick.gd

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 5                    # step 7's mission (DS:0x50CC0D: 1, 3, 2, 5, 7, 8, 6)
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	w.set_ds16(0x50AD8E, 7)
	w.set_ds16(0x50AD92, 7)
	for k in 7:
		w.set_ds8(0x50AD42 + k, 1)          # steps 1-7 cleared
	Debrief.set_campaign_mode(w, 1)
	b.auto_react = false                   # (the debrief's windows and the choice wait)
	b._end_mission(0x80, true)
	var ok := true
	var picked_one := false
	var asked := false
	var t0 := Time.get_ticks_msec()
	var pick_texts := ""
	var script = b.get_script()
	var res := -1
	while is_instance_valid(b) and not b.debrief_done and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
		if not is_instance_valid(b):
			break
		res = b.debrief_result
		var lst = _find(b, "pick")
		if lst != null:
			if pick_texts == "":
				pick_texts = str(lst.items[0]) if lst.items.size() > 0 else ""
				var shot := OS.get_environment("PD2_SHOT")
				if shot != "":
					for i in 10:
						await process_frame
					root.get_viewport().get_texture().get_image().save_png(shot)
			if not picked_one:
				picked_one = true
				lst.answer(9)              # the first row
			else:
				lst.answer(-2)             # the right click: the done / fill question
			await process_frame
			continue
		var dl = _find(b, "debrief_list")
		if dl != null:
			dl.answer(-2)                  # the new items' lists: a right click ends each
			await process_frame
			continue
		var box = _find_box(b)
		if box != null:
			asked = true
			box.answer(0)                  # 実行
			await process_frame
			continue
		for n in b.get_tree().root.find_children("*", "Control", true, false):
			if n.get_script() != null and str(n.get_script().resource_path).ends_with("debrief_view.gd") and n.is_visible_in_tree():
				var ev := InputEventMouseButton.new()
				ev.button_index = MOUSE_BUTTON_LEFT
				ev.pressed = true
				n._gui_input(ev)              # a click (a waiting window's, or the picture's)
	# game_mode_loop goes on at once: DASH's first mission (chunk 2, script 12)
	var nb = null
	for f in 60:
		await process_frame
		for n in root.get_children():
			if is_instance_valid(n) and n != b and n.get_script() == script:
				nb = n
	print("debrief 0x%X, campaign %d, script %d, step %d, picked one %s, asked %s, first row %s" % [
		res, w.campaign, w.script_no, w.ds16(0x50AD8E), picked_one, asked, pick_texts])
	print("next battle: %s" % ("none" if nb == null else "%s chunk %d, script %d" % [nb.campaign, nb.mission_index + 1, nb.script_no]))
	ok = res == 0x80 and w.campaign == 0 and w.script_no == 12 and picked_one and asked 		and nb != null and nb.campaign == "dash" and nb.script_no == 12
	print("hand-over pick: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)


func _find(n: Node, role: String):
	if n.get("role") == role and n.is_visible_in_tree():
		return n
	for c in n.get_children():
		var r = _find(c, role)
		if r != null:
			return r
	return null


func _find_box(b) -> Variant:
	## the pick's question (_open_pick_box): the select window in the pick layer
	if b._pick_layer == null or b.react_panel == null or not is_instance_valid(b.react_panel):
		return null
	for c in b.react_panel.get_children():
		if c.has_method("answer") and c.get("role") != "pick" and c.get("items") != null and c.items.size() == 2:
			return c
	return null
