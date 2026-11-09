extends SceneTree
## PD2 mission 1's scripts in the battle: the indoor search on the target hex (20 AP, the
## escape flag DS:0x50AD7A), then an escape from an exit hex at the end of the turn.

func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2"
	b.mission_index = 0
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var ok: bool = b.script_no == 1 and w.exits.size() == 14
	print("script %d, %d exits, camera (%d, %d)" % [b.script_no, w.exits.size(), w.ds16(0x50AD95), w.ds16(0x50AD97)])
	var a: int = b.squad[0]
	var p := w.pos(a)
	w.O[p.x + 72 * p.y] = 0
	w.setb(a, 9, 47)
	w.setb(a, 10, 24)
	w.O[47 + 72 * 24] = a + 1
	w.setb(a, 0xE, 30)
	b._select(a)
	b._cmd_mission()
	var found := w.ds8(0x50AD7A) & 1 == 1 and w.sb(a, 0xE) == 10
	print("indoor search on (47, 24): %s (AP %d, flag 0x%X)" % [found, w.sb(a, 0xE), w.ds8(0x50AD7A)])
	var c: int = b.squad[1]
	var q := w.pos(c)
	var e: Vector2i = w.exits[0]
	w.O[q.x + 72 * q.y] = 0
	w.setb(c, 9, e.x)
	w.setb(c, 10, e.y)
	w.O[e.x + 72 * e.y] = c + 1
	b._end_turn()
	var escaped := w.sb(c, 9) == -1 and w.O[e.x + 72 * e.y] != c + 1
	print("escape from %s: %s" % [e, escaped])
	quit(0 if ok and found and escaped else 1)
