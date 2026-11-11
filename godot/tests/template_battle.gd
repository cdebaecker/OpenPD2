extends SceneTree
## The sortie screen's new panels in the battle, driven through their buttons (DASH mission
## 1): the armament screen's machine list sorted by its stock column (0x4172B0, table
## 0x5152E8); the template menu (0x45A700) registering a pilot's loadout to a new register
## (reg_unit.dat written to user://dash/), the loadout cleared, then recalled whole; the
## roster (0x46A240) sorted by AP and closed, which rewrites the pool in its order; the
## bulk menu (0x462390) unequipping every ground pilot. The player's reg_unit.dat is kept.

const REG := "user://dash/reg_unit.dat"


func _drive(b, press: Callable, answers: Array, request: Callable, answer: Callable) -> void:
	press.call()
	for a in answers:
		if request.call() == null:
			break
		answer.call(a)


func _init() -> void:
	await process_frame
	var kept := FileAccess.get_file_as_bytes(REG) if FileAccess.file_exists(REG) else PackedByteArray()
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = "dash"
	b.mission_index = 0
	b.plan_window = false               # the operation plan pressed done at once
	root.add_child(b)
	for i in 8:
		await process_frame
	var w: Pd2World = b.w
	var ok: bool = b.sortie_panel != null
	# a pilot with a machine 0-6 and a launcher in slot 0
	var k := -1
	for c in 27:
		var m := Flight.s8(w.ub(c, 0xC))
		if m >= 0 and m <= 6 and Flight.s8(w.ub(c, 0xF)) != -1 and w.crew[c * 16 + 4] <= w.ds16(0x50AD92):
			k = c
			break
	print("pilot with a loadout: %d" % k)
	ok = ok and k >= 0
	if ok:
		var eq := func(btn, ans): _drive(b, func(): b._equip_press(btn), ans,
				func(): return b.equip_request, func(a): b._equip_answer(a))
		b._equip_begin(k)
		# the machine list, sorted by its stock column (5)
		b._equip_press("machine")
		b._equip_answer(5)
		var ents: Array = b.equip_request[2] if b.equip_request != null else []
		var sorted := ents.size() > 0
		for i in range(1, ents.size()):
			if w.mem8(Equipment.STOCK_MACH + ents[i - 1]) < w.mem8(Equipment.STOCK_MACH + ents[i]):
				sorted = false
		print("machine list by stock: %s" % str(ents.map(func(e): return w.mem8(Equipment.STOCK_MACH + e))))
		b._equip_answer(-2)
		ok = ok and sorted
		# register the loadout (登録 -> 新規登録)
		var mach := w.ub(k, 0xC)
		var lid := w.ub(k, 0xF)
		eq.call("menu", [0, 0])
		var used := Equipment.reg_used(w)
		print("registers in use: %d, file written: %s" % [used, FileAccess.file_exists(REG)])
		ok = ok and used >= 1 and FileAccess.file_exists(REG)
		var r := used - 1
		ok = ok and w.reg_unit[Equipment.REG_LEN * r + 1] == mach and w.reg_unit[Equipment.REG_LEN * r + 3] == lid
		# clear everything back to stock, then recall the register whole (呼出 -> register -> all)
		eq.call("clear", [1])
		ok = ok and Flight.s8(w.ub(k, 0xC)) == -1
		eq.call("menu", [1, r, 0])
		print("recalled: machine %d launcher %d (want %d %d)" % [w.ub(k, 0xC), w.ub(k, 0xF), mach, lid])
		ok = ok and w.ub(k, 0xC) == mach and w.ub(k, 0xF) == lid
		eq.call("close", [1])
		ok = ok and b.equip_sess.is_empty()
	# the roster: sorted by AP (column 2), closed: the free pool follows its order
	var srt := func(act, ans): _drive(b, func(): b._sortie_press(act), ans,
			func(): return b.sortie_request, func(a): b._sortie_answer(a))
	srt.call(["roster"], [2, -2])
	var aps := []
	for i in w.crew_pool_n:
		aps.append(Flight.s8(w.crew[w.ds[2 + i] * 16 + 9]))
	var desc := true
	for i in range(1, aps.size()):
		if aps[i - 1] < aps[i]:
			desc = false
	print("pool AP after the roster: %s" % str(aps))
	ok = ok and desc and b.sortie_request == null
	# the bulk menu: everyone (全員), unequip (装備除装), yes: no ground pilot keeps a launcher
	var before := 0
	for i in 96:
		before += w.mem8(Equipment.STOCK_LAUN + i)
	srt.call(["bulk", 0], [0, 0, 1])
	var left := 0
	var after := 0
	for i in 96:
		after += w.mem8(Equipment.STOCK_LAUN + i)
	for c in 64:
		if w.crew[c * 16 + 4] <= w.ds16(0x50AD92) and w.crew[c * 16 + 2] == 0 and w.crew[c * 16 + 3] == 0:
			for s in 6:
				if w.ub(c, 0xF + 2 * s) != 0xFF:
					left += 1
	print("bulk unequip: launchers in stock %d -> %d, left fitted %d" % [before, after, left])
	ok = ok and left == 0 and after > before
	if kept.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REG))
	else:
		var f := FileAccess.open(REG, FileAccess.WRITE)
		f.store_buffer(kept)
		f.close()
	print("OK" if ok else "FAIL")
	quit(0 if ok else 1)
