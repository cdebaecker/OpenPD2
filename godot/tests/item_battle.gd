extends SceneTree
## The item command in the battle: a DoLL is given a sensor round and uses it through the
## Item button on a hex of its target map: the sensor goes into the list (4 turns), the
## pocket loses a round, the AP is paid. The turn start's tick then counts it down, and
## the recon pass searches from it.

func _round(w: Pd2World, wh: int) -> int:
	for a in 96:
		if w.ammo(a, 8) & 15 == wh and w.ammo(a, 8) & 0x20 and w.ammo(a, 3) > 0:
			return a
	return -1


func _init() -> void:
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 1
	b.auto_react = true
	root.add_child(b)
	await process_frame
	var w: Pd2World = b.w
	var u := -1
	for k in b.squad:
		if w.active(k):
			u = k
			break
	var a := _round(w, 9)
	print("unit %d, sensor round %d" % [u, a])
	var ok := u != -1 and a != -1
	if ok:
		w.setb(u, 0x1B, a)
		w.setb(u, 0x1C, 3)
		w.setb(u, 0xE, 40)
		b._select(u)
		b._cmd_item_mode()
		var fm: Move.MoveMap = b.fire_map
		var target := Vector2i(-1, -1)
		if fm != null:
			for ly in fm.h:
				for lx in fm.w:
					if fm.at(lx, ly) == 1 and target.x == -1:
						target = Vector2i(fm.x0 + lx, fm.y0 + ly)
		print("item mode %s, pocket %d, target %s" % [b.mode, b.item_pocket, str(target)])
		ok = b.mode == "item" and target.x != -1
		if ok:
			var ap0 := w.sb(u, 0xE)
			b._cmd_item_click(target)
			var placed := -1
			for i in 42:
				if w.sensors[4 * i] == target.x and w.sensors[4 * i + 1] == target.y:
					placed = i
					break
			print("sensor entry %d (turns %d), rounds %d, AP %d -> %d" % [placed, w.sensors[4 * placed + 2] if placed != -1 else -1,
				w.pocket_count(u, 0), ap0, w.sb(u, 0xE)])
			ok = placed != -1 and w.sensors[4 * placed + 2] == 4 and w.pocket_count(u, 0) == 2 \
				and w.sb(u, 0xE) == ap0 - Item.use_ap(w, u, 0)
			Item.sensors_tick(w)
			print("after a tick: turns %d" % w.sensors[4 * placed + 2])
			ok = ok and w.sensors[4 * placed + 2] == 3
		b._end_turn()
		print("a whole turn after: fault '%s'" % w.fault)
		ok = ok and w.fault == ""
	print("item battle: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
