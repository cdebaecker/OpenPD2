extends SceneTree
## PD2 mission 1's flight engine in the battle: the computer's turns run the speech hook
## (0x499830: the flight turn, then the arrival scenes); groups 0 and 2 arrive on their
## turn, play their scene once (flags DS:0x50AD76 / 0x50AD78) and their members are set
## down on the landing hexes (group 2 only when it has members: the sandbox squad is all
## in group 0).

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	for g in [0, 1, 2, 3]:
		var arr := Flight.s16(Flight.gb(w, g, 0x1D) | Flight.gb(w, g, 0x1E) << 8)
		print("group %d: +2 0x%02X, %d members, arrival %d, type 0x%02X" % [g, Flight.gb(w, g, 2),
			Flight.gb(w, g, 5), arr, Flight.gb(w, g, 0x21)])
	var landed := {0: false, 2: false}
	for i in 8:
		b._end_turn()
		var f0 := w.ds8(0x50AD76) & 1
		var f2 := w.ds8(0x50AD78) & 1
		print("after turn %d: mission turn %d, scenes 0x%X / 0x%X, fault '%s'" % [i + 1, w.mission_turn, f0, f2, w.fault])
		for g in [0, 2]:
			if (f0 if g == 0 else f2) and not landed[g]:
				var spots: Array = MissionScripts.M01_LANDING[g]
				var n := 0
				var ok := true
				for s in 16:
					var k := Flight.gb(w, g, 6 + s)
					if k == 0xFF:
						continue
					if w.pos(k) != spots[n]:
						ok = false
					n += 1
				landed[g] = ok
				print("  group %d set down on the landing hexes: %s" % [g, ok])
	var text: String = b.log_box.get_parsed_text()
	var lines := 0
	for id in [0xA1, 0xA2, 0xA3, 0xA4]:
		if text.find(b.msg(id).replace("@", "\n").strip_edges().get_slice("\n", 0)) != -1:
			lines += 1
	print("arrival lines in the log: %d" % lines)
	# the sandbox squad is all in group 0 (sandbox_squad): a group with nobody never arrives
	var need := [0] if Flight.gb(w, 2, 5) == 0 else [0, 2]
	var ok := lines > 0
	for g in need:
		ok = ok and landed[g]
	quit(0 if ok else 1)
