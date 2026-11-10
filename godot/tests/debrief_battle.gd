extends SceneTree
## The end of PD2 mission 1 and the way to the next: the withdraw command (the scenario
## hook 0x49A6C0 sets the end code 0x80), the mission's end, the debrief 0x48FA40 (PD2 step
## 1 cleared: step 2, mission 3, the recruits, the groups emptied, the stock), then the next
## battle from the debrief's save (game_mode_loop: chunk DS:0x50663D). Then the end code set
## by a command ends the player's phase: the mission ends at mission_loop's check.

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var formed: bool = w.groups[5] > 0 or w.groups[2 * 35 + 5] > 0
	print("mission 1: script %d, step %d, groups 0 / 2: %d / %d members" % [b.script_no, w.ds16(0x50AD8E),
		w.groups[5], w.groups[2 * 35 + 5]])
	var stock_before := w.stock.duplicate()
	b._cmd_withdraw()
	var ended: bool = b.mission_over and b.debrief_result == 0x80
	var step := w.ds16(0x50AD8E)
	var empty := true
	for g in 12:
		if w.groups[g * 35 + 5]:
			empty = false
	var nxt: Array = Debrief.next_mission(w)
	print("withdraw: debrief 0x%X, step %d (DS:0x50AD92 %d), mission %d, chunk %d, flag %d, groups empty %s, next %s" % [
		b.debrief_result, step, w.ds16(0x50AD92), w.script_no, Debrief.chunk(w), w.ds8(0x50AD42), empty, str(nxt)])
	var debriefed := ended and step == 2 and w.ds16(0x50AD92) == 2 and w.script_no == 3 and Debrief.chunk(w) == 3 \
		and w.ds8(0x50AD42) == 1 and empty and nxt == [1, 3] and w.stock != stock_before
	var lines := 0
	for c in b.debrief_panel.get_children()[0].get_children():
		if c is RichTextLabel:
			lines = c.text.count("\n") + 1
	print("debrief panel: %d lines" % lines)
	# the next mission: the battle scene again, from the debrief's save
	var script = b.get_script()
	b._next_mission(nxt)
	await process_frame
	await process_frame
	var b2 := []
	for n in root.get_children():
		if is_instance_valid(n) and n.get_script() == script and n.mission_index == 2:
			b2.append(n)
	var chained := false
	var ended2 := false
	if not b2.is_empty():
		var nb = b2[0]
		var w2: Pd2World = nb.w
		chained = nb.campaign == "pd2" and nb.mission_index == 2 and nb.script_no == 3 \
			and w2.ds16(0x50AD8E) == 2 and w2.ds8(0x50AD42) == 1 and Debrief.campaign_mode(w2) == 1
		print("next battle: %s chunk %d, script %d, step %d, mission 1's flag %d, %d enemy units" % [
			nb.campaign, nb.mission_index + 1, nb.script_no, w2.ds16(0x50AD8E), w2.ds8(0x50AD42), nb._count_side(3)])
		# an end code set during the player's phase ends it; mission_loop ends the mission
		w2.set_ds8(0x50ADF2, 0x82)
		nb._after_command()
		ended2 = nb.mission_over and nb.debrief_result == 0x80 and w2.ds16(0x50AD8E) == 3 and w2.ds8(0x50AD43) == 0
		print("end code 0x82 after a command: over %s, debrief 0x%X, step %d, mission 3's flag %d" % [
			nb.mission_over, nb.debrief_result, w2.ds16(0x50AD8E), w2.ds8(0x50AD43)])
	quit(0 if formed and debriefed and lines > 3 and chained and ended2 else 1)
