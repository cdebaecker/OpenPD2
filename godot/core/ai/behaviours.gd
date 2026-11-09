class_name AiBehaviours
extends RefCounted
## The 11 orders of the computer side (rules.py ai_behaviour_1..11; RULES.md 5.8).
## rules.py stops a behaviour with exceptions (AiAbort for a UI abort code, AiUndefined
## where the game reads uninitialised data); here the turn object records the stop and
## every block becomes a no-op after it, so the code below mirrors the Python one.

const W := preload("res://core/world.gd")
const UNDEFINED := Ai.UNDEFINED
const ADDRESS := {1: 0x42BA90, 2: 0x430A80, 3: 0x4311C0, 4: 0x431770, 5: 0x432350, 6: 0x432690,
		7: 0x432B40, 8: 0x431E00, 9: 0x4334F0, 10: 0x433020, 11: 0x433690}
const ORDER_PRIORITY := [8, 3, 4, 9, 0, 7, 10, 2, 1, 5, 6, 11]   # 0x42A950


class T:
	var w: Pd2World
	var rng: Pd2Random
	var u: int
	var sight: PackedByteArray
	var h: AiTurnHooks
	var alert: int
	var code := -1
	var undefined := false

	func _init(w_: Pd2World, rng_: Pd2Random, u_: int, sight_: PackedByteArray, h_: AiTurnHooks, alert_: int) -> void:
		w = w_
		rng = rng_
		u = u_
		sight = sight_
		h = h_
		alert = alert_

	func stopped() -> bool:
		return code != -1 or undefined

	func _chk(res: int, codes: Array = Ai.AI_ABORT) -> bool:
		if res in codes:
			code = res
			return true
		return false

	func r(f: int) -> int:
		return w.ub(u, f)

	func destroyed() -> bool:
		return w.ub(u, 0) & 1 != 0

	func reload() -> void:
		if not stopped():
			_chk(Ai.ai_reload(w, u), [0x10000, 0x20000])

	## false: u was destroyed (or the behaviour stopped)
	func search(force: int) -> bool:
		if stopped():
			return false
		_chk(Ai.ai_search(w, u, force, h))
		return not stopped() and not destroyed()

	## the forced search whose count behaviour 3 reads, and behaviour 9's plain search
	func search_count(force: int) -> int:
		if stopped():
			return 0
		var n := Ai.ai_search(w, u, force, h)
		return 0 if _chk(n) else n

	func conceal() -> void:
		if not stopped():
			_chk(Ai.ai_conceal(w, u), [0x10000, 0x20000])

	func support(limit: int) -> void:
		if not stopped():
			_chk(Ai.ai_fire_support(w, rng, u, limit, h.easy), [0x10000])

	## 0 when engage fired nothing (or the behaviour stopped)
	func engage(radius: int, threshold: int, shots: int) -> int:
		if stopped():
			return 0
		var res := Ai.ai_engage(w, rng, u, radius, threshold, shots, h)
		return 0 if _chk(res) else res

	func longest() -> int:
		return Ai.ai_longest_range(w, u)

	func within(rg: int) -> bool:
		return Ai.ai_player_within(w, u, rg) == 1

	func ap() -> int:
		return w.sb(u, 0xE)

	func cls() -> int:
		return w.unit_class(u)

	func strong(cond := 60) -> bool:
		return w.ub(u, 0xD) >= cond and Ai.machine_melee_of(w, u) > 60

	func roll(n: int) -> int:
		return 0 if stopped() else rng.r16(n)

	func any_player() -> bool:
		return Ai.ai_any_player(w)

	func destination(dtype: int) -> Variant:
		if stopped():
			return null
		return Ai.ai_destination(w, rng, u, dtype, 3, alert)

	## dest is a destination and not where u already is and heads
	func fresh(dest: Variant) -> bool:
		if dest == null:
			return false
		var d: Vector2i = dest
		return not (r(7) == d.x and r(8) == d.y and w.pos(u) == Vector2i(r(7), r(8)))

	func set_dest(d: Vector2i) -> void:
		w.setb(u, 7, d.x)
		w.setb(u, 8, d.y)

	## ai_move with the abort checks; -1 (as the "u is gone" result) once stopped
	func move(mode: int) -> int:
		if stopped():
			return -1
		var res := Ai.ai_move(w, rng, mode, u, sight, h)
		if res == UNDEFINED:
			undefined = true
			return -1
		if _chk(res):
			return -1
		return res

	func head_for(dtype: int, mode: int) -> int:
		if stopped():
			return -1
		var dest: Variant = destination(dtype)
		if dest == null:
			return 0
		if not fresh(dest):
			return 0
		set_dest(dest)
		return move(mode)


static func _run(order: int, w: Pd2World, rng: Pd2Random, u: int, sight: PackedByteArray, hooks: AiTurnHooks, alert: int) -> int:
	if hooks == null:
		hooks = AiTurnHooks.new(w)
	if hooks.rng == null:
		hooks.rng = rng
	var t := T.new(w, rng, u, sight, hooks, alert)
	var res: int
	match order:
		1: res = _b1(t)
		2: res = _b2(t)
		3: res = _b3(t)
		4: res = _b4(t)
		5: res = _b5(t)
		6: res = _b6(t)
		7: res = _b7(t)
		8: res = _b8(t)
		9: res = _b9(t)
		10: res = _b10(t)
		_: return UNDEFINED
	if t.undefined:
		return UNDEFINED
	if t.code != -1:
		return t.code
	return res


## Run order `order` (1-11) for unit u. Returns 0, a UI abort code, or UNDEFINED.
static func run(order: int, w: Pd2World, rng: Pd2Random, u: int, sight: PackedByteArray, hooks: AiTurnHooks = null, alert := 0) -> int:
	if order == 11:
		return _b11(w, rng, u, sight, hooks, alert)
	return _run(order, w, rng, u, sight, hooks, alert)


static func _fight(t: T, threshold: int, shots: int, any_check := false) -> bool:
	var rg := t.longest()
	if rg > 0 and (not any_check or t.any_player()) and t.within(rg):
		return t.engage(-1, threshold, shots) != 0
	return true


static func _b2(t: T) -> int:
	t.reload()
	t.search(0)
	if t.destroyed():
		return 0
	t.conceal()
	t.support(1)
	var rg := t.longest()
	var ok := 0
	if rg > 0:
		ok = int(t.any_player())
		if ok and t.within(rg):
			for a in [[2, 100, 3], [1, 300, 2], [0, 65, 3], [-1, 20, 6]]:
				if t.engage(a[0], a[1], a[2]) == 0:
					return 0
	if not ok:
		return 0
	var mode := 1
	var count := 0
	var done := false
	while true:
		if t.ap() <= 0:
			done = true
		else:
			var res := t.head_for(1, mode)
			if res == -1:
				return 0
			t.support(1)
			if t.ap() > 0:
				if res == 0:
					t.conceal()
					rg = t.longest()
					t.support(2)
					if _b2_fight(t, rg) and t.engage(-1, 1, 10) == 0:
						return 0
					done = true
				elif res == 1:
					t.conceal()
					if not t.search(0):
						return 0
					rg = t.longest()
					if _b2_fight(t, rg):
						for a in [[2, 100, 3], [0, 60, 4], [1, 400, 4]]:
							if t.engage(a[0], a[1], a[2]) == 0:
								return 0
				elif res == 2:
					t.conceal()
					if not t.search(0):
						return 0
					t.support(2)
					rg = t.longest()
					if _b2_fight(t, rg) and t.engage(-1, 1, 10) == 0:
						return 0
					done = true
				elif res == 3:
					t.conceal()
					t.support(3)
					rg = t.longest()
					if _b2_fight(t, rg) and t.engage(-1, 1, 10) == 0:
						return 0
					done = true
				elif res == 4:
					mode = 2
				else:
					t.support(-1)
					done = true
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	if not t.search(1):
		return 0
	t.support(-1)
	return 0


static func _b2_fight(t: T, rg: int) -> bool:
	return rg > 0 and t.any_player() and t.within(rg)


class B1:
	## behaviour 1's locals shared with its helpers (Python nonlocal)
	var mode := 0
	var dtype := 0
	var rg := 0


static func _b1_charge_or_fall_back(t: T, s: B1) -> bool:
	if t.strong():
		s.mode = 5
		s.dtype = 6
		return true
	if t.cls() == 3:
		if not t.search(1):
			return false
		t.support(1)
	s.mode = 2
	s.dtype = 0
	return true


static func _b1_ready_or_regroup(t: T, s: B1) -> bool:
	if t.strong():
		s.mode = 5
		s.dtype = 6
		return true
	if t.cls() == 3:
		s.mode = 0
		if not t.search(1):
			return false
		t.support(1)
	else:
		s.mode = 2
	s.dtype = 0
	return true


static func _b1_shoot(t: T, s: B1, threshold: int, shots: int, fresh := true) -> bool:
	if fresh:
		s.rg = t.longest()
	return not (s.rg > 0 and t.within(s.rg) and t.engage(-1, threshold, shots) == 0)


static func _b1(t: T) -> int:
	var s := B1.new()
	if t.strong(55):
		s.mode = 5
		s.dtype = 6
		s.rg = t.longest()
		if s.rg > 0 and t.within(s.rg):
			for a in [[2, 80, 2], [1, 300, 2], [0, 40, 2]]:
				if t.engage(a[0], a[1], a[2]) == 0:
					return 0
	else:
		s.dtype = 0
		if t.cls() == 3:
			if not t.search(0):
				return 0
			t.support(1)
		s.rg = t.longest()
		if s.rg > 0 and t.within(s.rg):
			for a in [[2, 80, 3], [1, 300, 3], [0, 40, 3]]:
				if t.engage(a[0], a[1], a[2]) == 0:
					return 0
		s.mode = 0
	var count := 0
	var done := false
	while true:
		if t.ap() <= 0:
			done = true
		else:
			var res := t.head_for(s.dtype, s.mode)
			if res == -1:
				return 0
			t.support(1)
			if t.ap() > 0:
				if res == 0:
					if t.cls() == 3:
						if not t.search(1):
							return 0
						t.support(1)
					if not _b1_shoot(t, s, 1, 6):
						return 0
					done = true
				elif res == 1 or res == 2:
					if t.cls() != 3:
						t.conceal()
					t.set_dest(Vector2i(t.r(9), t.r(10)))
					if not t.search(0):
						return 0
					s.rg = t.longest()
					if s.rg > 0 and t.within(s.rg):
						var steps := [[2, 60, 2], [1, 150, 3], [0, 40, 5]] if res == 1 else [[2, 60, 3], [1, 150, 3], [0, 30, 4]]
						for a in steps:
							if t.engage(a[0], a[1], a[2]) == 0:
								return 0
					if not _b1_charge_or_fall_back(t, s):
						return 0
				elif res == 3:
					if not _b1_ready_or_regroup(t, s):
						return 0
					if s.rg > 0 and t.any_player() and t.within(s.rg) and t.engage(-1, 10, 10) == 0:
						return 0
				elif res == 4:
					if not _b1_ready_or_regroup(t, s):
						return 0
					if not _b1_shoot(t, s, 10, 2):
						return 0
				elif res == 5 or res == 6:
					if t.strong():
						s.mode = 5
						s.dtype = 6
					else:
						t.conceal()
						var x := t.longest()
						if x > 0 and t.within(x) and t.engage(-1, 10, 10) == 0:
							return 0
						s.mode = 2
						s.dtype = 0
					if not _b1_shoot(t, s, 10, 2):
						return 0
				elif res == 7:
					if not _b1_shoot(t, s, 50, 10):
						return 0
					s.mode = 2
					s.dtype = 0
				elif res == 10:
					if not _b1_shoot(t, s, 5, 10):
						return 0
				else:
					if not _b1_shoot(t, s, 10, 10):
						return 0
					done = true
		count += 1
		if done or count >= 3:
			break
	if t.cls() <= 1:
		t.conceal()
	t.reload()
	if not t.search(1):
		return 0
	var x2 := t.longest()
	if x2 > 0 and t.within(x2):
		t.engage(-1, 10, 10)
	return 0


static func _b5(t: T) -> int:
	t.reload()
	var count := 0
	var done := false
	while true:
		var res := 0
		if t.ap() <= 0:
			done = true
		else:
			res = t.head_for(3, 3)
			if res == -1:
				return 0
		if t.ap() > 0:
			if res == 0:
				t.support(1)
				if not _fight(t, 1, 10, true):
					return 0
				done = true
			elif res == 1 or res == 2:
				t.support(-1)
			elif res == 3:
				t.support(-1)
				if not _fight(t, 1, 10):
					return 0
				done = true
			elif res == 4:
				t.support(-1)
			else:
				t.support(-1)
				done = true
		else:
			done = true
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	t.support(-1)
	return 0


static func _b6(t: T) -> int:
	t.support(1)
	t.reload()
	var count := 0
	var done := false
	while true:
		t.support(1)
		if t.roll(100) < 30:
			if not t.search(0):
				return 0
		if t.ap() > 0 and not _fight(t, 1, 1):
			return 0
		var res := 0
		if t.ap() <= 0:
			done = true
		else:
			res = t.head_for(3, 3)
			if res == -1:
				return 0
		t.support(1)
		if t.ap() > 0:
			if res == 0:
				t.support(1)
				if not _fight(t, 1, 10, true):
					return 0
				t.support(-1)
				done = true
			elif res >= 1 and res <= 3:
				t.conceal()
				t.support(-1)
				if not _fight(t, 1, 10):
					return 0
				done = true
			elif res == 4:
				t.conceal()
				t.support(-1)
				if not _fight(t, 1, 10):
					return 0
			else:
				t.support(-1)
				done = true
		else:
			done = true
		t.support(1)
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	t.support(-1)
	return 0


static func _b7(t: T) -> int:
	t.reload()
	t.support(1)
	var count := 0
	var done := false
	while true:
		if t.ap() > 0 and not _fight(t, 1, 3):
			return 0
		var res := 0
		if t.ap() <= 0:
			done = true
		else:
			res = t.head_for(3, 4)
			if res == -1:
				return 0
		if t.ap() > 0:
			if not t.search(0):
				return 0
			if res == 0:
				t.support(1)
				t.conceal()
				if not _fight(t, 1, 10):
					return 0
				t.support(-1)
				done = true
			elif res == 1 or res == 2:
				t.support(-1)
				if not _fight(t, 1, 10):
					return 0
				done = true
			elif res == 3:
				t.conceal()
				t.support(1)
				if not _fight(t, 1, 10):
					return 0
				done = true
			elif res == 4:
				t.support(1)
				t.conceal()
				if not _fight(t, 1, 10):
					return 0
			else:
				done = true
		else:
			done = true
		t.support(1)
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	t.support(-1)
	return 0


static func _b3(t: T) -> int:
	if not _fight(t, 1, 5, true):
		return 0
	t.reload()
	var mode := 6
	var count := 0
	var done := false
	while true:
		if not t.search(0):
			return 0
		t.support(1)
		var res := 0
		if t.ap() <= 0:
			done = true
		else:
			res = t.head_for(2, mode)
			if res == -1:
				return 0
		if mode == 7:
			t.conceal()
		if t.ap() > 0:
			if res == 0:
				t.support(1)
				if not _fight(t, 1, 10, true):
					return 0
				t.support(-1)
				done = true
			elif res == 1:
				if t.roll(100) < 40:
					t.support(1)
					mode = 8
				else:
					t.support(1)
					t.conceal()
					if not _fight(t, 1, 10, true):
						return 0
			elif res == 2:
				var found := t.search_count(1)
				if t.destroyed() or t.stopped():
					return 0
				if found:
					t.support(1)
					mode = 7
			elif res == 3:
				if not t.search(0):
					return 0
				t.conceal()
				t.support(-1)
				if not _fight(t, 1, 10, true):
					return 0
				mode = 8
			elif res == 4:
				done = true
				t.support(1)
			else:
				t.support(-1)
				done = true
		else:
			done = true
		count += 1
		if done or count >= 3:
			break
		t.reload()
	t.conceal()
	t.reload()
	t.support(-1)
	return 0


static func _b4(t: T) -> int:
	t.reload()
	t.support(1)
	var count := 0
	var done := false
	var seen4 := 0
	while true:
		if not t.search(0):
			return 0
		if t.roll(100) < 50:
			t.support(1)
		var res := 0
		if t.ap() <= 0:
			done = true
		else:
			if not _fight(t, 1, 1, true):
				return 0
			var dest: Variant = t.destination(3)
			if t.fresh(dest):
				if t.w.on_map(dest.x, dest.y):
					t.set_dest(dest)
				res = t.move(6)
				if res == -1:
					return 0
		if t.ap() > 0 and res >= 0 and res <= 4:
			if res == 0:
				t.support(-1)
				if not t.search(0):
					return 0
				if not _fight(t, 1, 3, true):
					return 0
				done = true
			elif res == 1:
				t.support(1)
				if not _fight(t, 1, 3, true):
					return 0
			elif res == 2:
				t.support(1)
				if not t.search(0):
					return 0
				if not _fight(t, 1, 3, true):
					return 0
			elif res == 3:
				var dest2: Variant = t.destination(1)
				if t.fresh(dest2):
					t.set_dest(dest2)
				if t.roll(100) < 20:
					t.conceal()
				t.support(-1)
				if not _fight(t, 1, 10, true):
					return 0
				done = true
			else:
				t.support(1)
				if seen4 == 8:
					if not _fight(t, 1, 10, true):
						return 0
				else:
					seen4 = 8
				done = true
		else:
			done = true
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	t.support(-1)
	return 0


## 0x4334A0
static func any_spotted_player(w: Pd2World) -> bool:
	for k in w.n_units:
		if w.sb(k, 0x36) == 0 and w.active(k) and w.ub(k, 0) & 0x10:
			return true
	return false


static func _b11(w: Pd2World, rng: Pd2Random, u: int, sight: PackedByteArray, hooks: AiTurnHooks, alert: int) -> int:
	var rg := Ai.ai_longest_range(w, u)
	var res: int
	if rg > 0 and Ai.ai_player_within(w, u, rg) == 1 and any_spotted_player(w):
		res = _run(1, w, rng, u, sight, hooks, alert)
	else:
		var dest: Variant = Ai.ai_destination(w, rng, u, 3, 3, alert)
		if dest != null and not (w.ub(u, 7) == dest.x and w.ub(u, 8) == dest.y and w.pos(u) == Vector2i(w.ub(u, 7), w.ub(u, 8))):
			w.setb(u, 7, dest.x)
			w.setb(u, 8, dest.y)
		res = _run(5, w, rng, u, sight, hooks, alert)
	if res == UNDEFINED:
		return UNDEFINED
	return res if res in Ai.AI_ABORT else 0


static func _b8(t: T) -> int:
	t.reload()
	t.support(1)
	var count := 0
	var done := false
	while true:
		if not t.search(0):
			return 0
		if t.roll(100) < 50:
			t.support(1)
		var res := 0
		if t.ap() <= 0:
			done = true
		else:
			res = t.head_for(4, 4)
			if res == -1:
				return 0
		if t.ap() > 0 and res >= 0 and res <= 4:
			if res == 0:
				t.support(-1)
				done = true
			elif res == 1 or res == 2 or res == 4:
				if not t.search(0):
					return 0
				t.support(-1 if res == 4 else 1)
				if not _fight(t, 1, 10, true):
					return 0
			else:
				if t.roll(100) < 20:
					t.conceal()
				t.support(-1)
				if not _fight(t, 1, 10, true):
					return 0
				done = true
		else:
			done = true
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	t.support(-1)
	return 0


static func _b9(t: T) -> int:
	t.reload()
	var res := 0
	var dest: Variant = t.destination(5)
	if t.fresh(dest):
		t.set_dest(dest)
		res = t.move(4)
		if res == -1:
			return 0
	if t.destroyed():
		return 0
	if res >= 0 and res <= 4:
		t.conceal()
		t.support(-1)
		t.search_count(0)
	t.conceal()
	t.reload()
	t.support(2)
	return 0


static func _b10(t: T) -> int:
	t.conceal()
	if not t.search(0):
		return 0
	if any_spotted_player(t.w):
		t.support(-1)
	var count := 0
	var res: Variant = null
	var done := t.u != 0
	while true:
		if t.ap() <= 0:
			done = true
		else:
			var dest: Variant = t.destination(1)
			if t.fresh(dest):
				t.set_dest(dest)
				res = t.move(1)
				if res == -1:
					return 0
		if t.ap() > 0 and res == null:
			t.undefined = true
			return 0
		if t.ap() <= 0 or not (res >= 0 and res <= 4):
			done = true
		elif res == 0:
			if not _fight(t, 1, 5):
				return 0
			t.support(-1)
			done = true
		elif res == 1:
			t.support(-1)
			if not _fight(t, 1, 5):
				return 0
			done = true
		elif res == 2 or res == 3:
			if res == 3:
				t.conceal()
			if not t.search(0):
				return 0
			t.support(-1)
			if not _fight(t, 1, 10):
				return 0
			done = true
		else:
			t.conceal()
			if not t.search(0):
				return 0
			t.support(-1)
			if not _fight(t, 1, 10):
				return 0
		count += 1
		if done or count >= 3:
			break
	t.conceal()
	t.reload()
	t.support(-1)
	return 0
