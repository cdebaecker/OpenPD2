extends SceneTree
## RULES.md 5.23: the engine's play-safe paths. Off (the default, as in the fixtures), a
## case where the game crashes or hangs sets w.fault as the port does; on (the battle and
## the title), it takes the documented safe path and logs it in w.safe_log.
## godot --headless --path engine/godot -s tests/play_safe.gd


func world() -> Pd2World:
	var t := PackedByteArray()
	t.resize(1200)
	return Pd2World.new(PackedByteArray(), PackedByteArray(), PackedByteArray(), t, 255)


func _init() -> void:
	var ok := true
	# C1: mission 7's bomb hook on entry 1 without a site (hook byte 0xFF)
	for safe: bool in [false, true]:
		var w := world()
		w.play_safe = safe
		w.bombs[4 * 1 + 3] = 0xFF
		var res := MissionScripts.m07_bomb(w, Pd2Random.new(1), 1, null)
		var want_fault: bool = not safe
		var good: bool = res == 0 and (w.fault != "") == want_fault and w.safe_log.size() == (1 if safe else 0)
		print("C1 m07 bomb hook, play_safe %s: %s (fault '%s', log %s)" % [safe, "ok" if good else "BAD", w.fault, w.safe_log])
		ok = ok and good
	# D5: hand-over AP of a slot whose pocket was emptied (ammo -1: 0 rounds)
	for safe: bool in [false, true]:
		var mach := PackedByteArray()
		mach.resize(32 * 31)
		var laun := PackedByteArray()
		laun.resize(96 * 17)            # zeros: ammo -1 (launcher 95's tail) has 0 rounds, as in the game
		var amm := PackedByteArray()
		amm.resize(96 * 12)
		var w := Pd2World.new(mach, laun, amm, PackedByteArray(), 64)
		w.play_safe = safe
		w.setb(0, 0xF, 0)           # slot 0: launcher 0, pocket 0
		w.setb(0, 0x10, 0)
		w.setb(0, 0x1B, 0xFF)       # pocket 0 emptied
		w.setb(0, 0x1C, 0)
		Pockets.slot_hand_ap(w, 0, 0)
		var good: bool = (w.fault != "") == (not safe) and w.safe_log.size() == (1 if safe else 0)
		print("D5 hand-over AP, play_safe %s: %s (fault '%s', log %s)" % [safe, "ok" if good else "BAD", w.fault, w.safe_log])
		ok = ok and good
	print("play-safe: %s" % ("ok" if ok else "FAILED"))
	quit(0 if ok else 1)
