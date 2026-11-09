class_name Ai
extends RefCounted
## The computer side's building blocks (rules.py "mission scripts" .. ai_fire_support;
## RULES.md section 5.8): destinations, the distance and tactical fields, the move,
## engage, reload, conceal, search and fire support.

const W := preload("res://core/world.gd")
const MAP := 72
const NB := Move.NEIGHBOURS
const S_MOVE_ROWS := 528
const S_COVER_ROWS := 688
const AI_FIELD_FAIL := 0x10000
const AI_BLOCKED := 0x7FFF
const AI_ABORT := [0x10000, 0x20000, 0x40000]
const STRIKE_FLAG := 0x10
## move mode -> [w_flag, w_area, w_cover, w_k1, w_k0, movement mode (-1 = the mode), flag]
const AI_MOVE_WEIGHTS := {
	0: [10, 0, 1, 10, 10, -1, 0], 1: [10, 4, -8, 2, 2, -1, 0], 2: [10, 1, 1, 8, 8, -1, 0],
	3: [10, 1, 0, 0, 0, 0, 0], 4: [0, 1, 10, 2, 2, 1, 6], 5: [6, -10, 0, 0, 0, 0, 0],
	6: [10, 4, -6, 3, 3, -1, 0], 7: [10, 4, -12, 2, 2, 3, 0], 8: [8, 4, -10, 4, 4, 0, 0],
	9: [10, 4, -12, 0, 0, 1, 0],
}
## result of a function the game leaves undefined (rules.py returns None / raises AiUndefined)
const UNDEFINED := -0x7FFFFFFF


static func in_view(w: Pd2World, x: int, y: int, side: int) -> int:   # 0x46F2D0
	return (w.layer(w.F, x, y) >> (3 if side < 3 else 2)) & 1


static func passable(w: Pd2World, cat: int, x: int, y: int) -> bool:
	return w.terrain[S_MOVE_ROWS + 16 * cat + w.terrain[w.layer(w.T, x, y)]] != 0


static func cat_of(w: Pd2World, u: int) -> int:
	return w.umachine(u, 0) & 15


static func mem(w: Pd2World, k: int) -> Vector2i:
	return Vector2i(W.s8(w.memory[3 * k]), W.s8(w.memory[3 * k + 1]))


## 0x42E990: [distance, x, y] of the nearest spotted active player unit; [-1, ...] if none.
static func ai_nearest_spotted(w: Pd2World, u: int) -> Array:
	var cat := cat_of(w, u)
	var up := w.pos(u)
	var best := -1
	var pos := Vector2i(-1, -1)
	for k in w.n_units:
		if not w.active(k) or w.sb(k, 0x36) != 0 or not (w.ub(k, 0) & 0x10):
			continue
		var kp := w.pos(k)
		if not passable(w, cat, kp.x, kp.y):
			continue
		var d := W.hexdist(kp.x, kp.y, up.x, up.y)
		if best == -1 or d < best:
			best = d
			pos = kp
	return [best, pos.x, pos.y]


## 0x42ED30
static func ai_nearest_unspotted(w: Pd2World, u: int) -> int:
	var cat := cat_of(w, u)
	var up := w.pos(u)
	var best := 0xFF
	var idx := -1
	for k in mini(40, w.n_units):
		if not w.active(k) or w.sb(k, 0x36) != 0 or w.ub(k, 0) & 0x10:
			continue
		var kp := w.pos(k)
		if not passable(w, cat, kp.x, kp.y):
			continue
		var d := W.hexdist(up.x, up.y, kp.x, kp.y)
		if d < best:
			best = d
			idx = k
	return idx


## 0x42EA60: [result, x, y]
static func ai_waypoint(w: Pd2World, rng: Pd2Random, u: int, dtype: int, alert := 0) -> Array:
	var s := (w.ub(u, 4) & 15) + (8 if alert else 0)
	var pts := []
	for i in 4:
		pts.append(Vector2i(w.terrain[848 + 8 * s + 2 * i], w.terrain[849 + 8 * s + 2 * i]))
	var cat := cat_of(w, u)
	var up := w.pos(u)
	var dest := Vector2i(w.ub(u, 7), w.ub(u, 8))
	if dtype == 4 and w.on_map(dest.x, dest.y):
		for i in 4:
			if pts[i] == dest:
				var nxt: Vector2i = pts[(i + 1) & 3]
				return [0, nxt.x, nxt.y]
		return [-1, 0, 0]
	var tried := [false, false, false, false]
	for j in 4:
		var i := rng.r16(4)
		while tried[i]:
			i = rng.r16(4)
		var p: Vector2i = pts[i]
		if not passable(w, cat, p.x, p.y) or not w.on_map(p.x, p.y) or p == dest:
			tried[i] = true
			continue
		return [W.hexdist(p.x, p.y, up.x, up.y), p.x, p.y]
	return [-1, 0, 0]


## 0x42E310: where unit u should go, by destination type; null if nowhere.
static func ai_destination(w: Pd2World, rng: Pd2Random, u: int, dtype: int, phase := 3, alert := 0) -> Variant:
	var up := w.pos(u)
	var cat := cat_of(w, u)
	var ns := ai_nearest_spotted(w, u)
	var cand: int = ns[0]
	var cpos := Vector2i(ns[1], ns[2])
	var mem_d := -1
	var mem_k := -1
	for k in mini(40, w.n_units):
		if not w.active(k):
			continue
		var m := mem(w, k)
		if not w.on_map(m.x, m.y) or not passable(w, cat, m.x, m.y):
			continue
		var kp := w.pos(k)
		if in_view(w, m.x, m.y, phase) or in_view(w, kp.x, kp.y, phase):
			w.memory[3 * k] = 0
			w.memory[3 * k + 1] = 0
			w.memory[3 * k + 2] = 0xFF
			continue
		var d := W.hexdist(m.x, m.y, up.x, up.y)
		if mem_d == -1 or d < mem_d:
			mem_d = d
			mem_k = k
	var wpr := ai_waypoint(w, rng, u, dtype, alert)
	var wp: int = wpr[0]
	var wpos := Vector2i(wpr[1], wpr[2])
	var dest := Vector2i(w.ub(u, 7), w.ub(u, 8))
	var at_dest := dest == up
	var wp_or_null: Variant = null if wp == -1 else wpos
	var nearer: Variant
	if cand == -1:
		nearer = wp_or_null if mem_k == -1 else mem(w, mem_k)
	elif mem_k == -1 or cand <= mem_d:
		nearer = cpos
	else:
		nearer = mem(w, mem_k)
	match dtype:
		0:
			if w.on_map(dest.x, dest.y) and not at_dest and not in_view(w, dest.x, dest.y, 3):
				return dest
			return nearer
		1:
			if at_dest:
				return null
			if w.on_map(dest.x, dest.y):
				return dest
			return wp_or_null
		2:
			var k := ai_nearest_unspotted(w, u)
			if k != -1:
				return w.pos(k)
			if mem_k != -1:
				return mem(w, mem_k)
			return wp_or_null
		3, 5:
			if w.on_map(dest.x, dest.y) and not at_dest:
				return dest
			return wp_or_null
		4:
			if not w.on_map(dest.x, dest.y) or at_dest:
				return wpos
			if w.O[dest.x + 72 * dest.y] - 1 == -1:
				return dest
			if W.hexdist(dest.x, dest.y, up.x, up.y) >= 3:
				return dest
			return wpos
		6:
			var best_m := 100
			var best_d := 100
			var best_k := -1
			for k in w.n_units:
				if not w.active(k) or w.sb(k, 0x36) != 0 or not (w.ub(k, 0) & 0x10):
					continue
				var kp := w.pos(k)
				if not passable(w, cat, kp.x, kp.y):
					continue
				var d := W.hexdist(up.x, up.y, kp.x, kp.y)
				var m := machine_melee_of(w, k)
				if best_m > m and best_d >= d:
					best_k = k
					best_m = m
					best_d = d
			if w.on_map(dest.x, dest.y) and not in_view(w, dest.x, dest.y, 3) and w.O[dest.x + 72 * dest.y] - 1 == -1:
				return dest
			if best_k != -1:
				return w.pos(best_k)
			return nearer
	return null


## 0x413110: the AI's estimate of the hit chance.
static func ai_hit_estimate(w: Pd2World, s: int, t: int, slot: int, mode: int, aim := -1) -> int:
	var terms := Fire.hit_terms(w, s, t, slot, mode, aim)
	if terms.has("error"):
		w.fault = "division by zero (weapon range 0)"
		return 0
	var e: int = terms.effectiveness
	if e == 1:
		return 0
	if e == 2:
		return 98
	var base := ((30 if w.campaign else 50) if mode == 1 else 0)
	var total: int = (terms.accuracy + base + terms.posture + terms.skill + terms.height
		+ terms.aim - terms.cover - terms.defense - terms.range)
	return maxi(15, mini(98, (total * 10) / e))


## 0x413C80: the AI's damage estimate.
static func ai_expected_damage(w: Pd2World, rng: Pd2Random, s: int, slot: int, t: int, mode: int) -> int:
	var wh := Fire.NO_SHOOTER_WARHEAD if s == -1 else w.warhead(s, slot)
	var dclass: int = Fire.DAMAGE_CLASS[w.armour(t)][wh]
	var a := Fire.attack_power(w, s, slot, t, mode)
	if a == 0:
		return 0
	var div := Fire.cover_divisor(w, t, dclass)
	var arm := w.umachine(t, 5 if (s != -1 and w.unit_class(s) > 1) else 4)
	var crew_def := W.s8(w.ucrew(t, 13))
	var d: int
	if dclass == 200:
		d = (((a - crew_def) / div) * (100 - arm)) / 100
	else:
		var v := (((a - crew_def) / div) * (100 - arm) * dclass) / 10000
		var spread := mini(10, maxi(2, v / 4))
		d = v - spread / 2
		rng.roll(d)
	return d if d > 0 else 1


## 0x42DC80
static func ai_fire_score(w: Pd2World, rng: Pd2Random, s: int, t: int, slot: int) -> int:
	var mode := 6 if w.unit_class(t) >= 3 else 0
	var ap := Move.launcher_ap(w, w.launcher_id(s, slot))
	var h := mini(100, ai_hit_estimate(w, s, t, slot, mode, -1))
	var d := ai_expected_damage(w, rng, s, slot, t, mode)
	if ap == 0:
		return 0
	return ((w.sb(s, 0xE) / ap) * h / 10) * d


## 0x4509E0 as a byte.
static func machine_melee_of(w: Pd2World, u: int) -> int:
	if w.umachine(u, 26) != 6:
		return w.umachine(u, 6) & 0xFF
	var load := 0
	for k in 6:
		var lid := w.ub(u, 0xF + 2 * k)
		if lid != 0xFF:
			var v := w.launcher(W.s8(lid), 7) & 0x1F
			load += v - 32 if v & 0x10 else v
	for p in 12:
		var a := w.ub(u, 0x1B + 2 * p)
		if a != 0xFF:
			load += w.ammo(W.s8(a), 6) & 0x1F
	return (w.umachine(u, 6) - 3 * load) & 0xFF


static func _ai_air(cat: int) -> bool:
	return cat == 9 or (cat >= 2 and cat <= 5)


## 0x42FA20: [0 or AI_FIELD_FAIL, field (PackedInt32Array 72 x 72)]
static func ai_distance_field(w: Pd2World, u: int, dx: int, dy: int) -> Array:
	var field := PackedInt32Array()
	field.resize(MAP * MAP)
	var st := {"cat": cat_of(w, u), "air": _ai_air(cat_of(w, u)), "free": 513}
	var buckets := []
	for i in 64:
		buckets.append([])
	var up := w.pos(u)
	var upos := up.x + MAP * up.y
	var dest := dx + MAP * dy
	field[dest] = -1
	if not _df_expand(w, field, buckets, st, dx, dy, 0):
		return [AI_FIELD_FAIL, field]
	var stop := 0
	var empty := 0
	var done := false
	for level in 0x400:
		if done:
			break
		var b: Array = buckets[level & 63]
		if not b.is_empty():
			empty = 0
			while not b.is_empty():
				var n: Vector2i = b.back()
				if field[n.x + MAP * n.y] >= level and not _df_expand(w, field, buckets, st, n.x, n.y, level):
					return [AI_FIELD_FAIL, field]
				b.pop_back()
				st.free += 1
		else:
			empty += 1
			if empty >= 64:
				done = true
		if stop == 0 and field[upos] != 0:
			stop = field[upos] + 20
		if stop != 0 and level >= stop:
			done = true
	for k in range(40, w.n_units):
		if w.is_enemy(k) and w.active(k) and k != u:
			var kp := w.pos(k)
			field[kp.x + MAP * kp.y] = -1
	for i in field.size():
		if field[i] == 0:
			field[i] = -1
	field[dest] = 0
	return [0, field]


static func _df_expand(w: Pd2World, field: PackedInt32Array, buckets: Array, st: Dictionary, cx: int, cy: int, level: int) -> bool:
	var hc := w.H[cx + MAP * cy]
	var cat: int = st.cat
	for o in NB[cy & 1]:
		var nx: int = cx + o.x
		var ny: int = cy + o.y
		if not w.on_map(nx, ny):
			continue
		var i := nx + MAP * ny
		if w.H[i] == 0 or field[i] == -1:
			continue
		var cost := w.terrain[S_MOVE_ROWS + 16 * cat + w.terrain[w.T[i]]]
		if cost == 0:
			continue
		if not st.air:
			var dh := w.H[i] - hc
			if w.F[i] & 1:
				cost *= 2
			if dh < -1 or dh > 1:
				continue
			if dh == 1:
				cost *= 2
		cost += level
		if field[i] != 0 and cost >= field[i]:
			continue
		field[i] = cost
		if st.free == 1:
			return false
		st.free -= 1
		buckets[cost & 63].append(Vector2i(nx, ny))
	return true


## 0x4304C0 (kind 1) / 0x4303F0 (kind 0)
static func ai_best_weapon(w: Pd2World, u: int, kind: int, cls := -1) -> int:
	var best := 0
	var slot := -1
	for s in 4:
		var lid := w.launcher_id(u, s)
		if lid == -1 or w.launcher(lid, 2) == 0:
			continue
		var rng_ := w.weapon_range(u, s)
		if rng_ <= best or w.launcher(lid, 8) >> 5 != kind or Move.final_attack(w, u, s, false) == 0:
			continue
		if Move.launcher_ap(w, lid) > w.sb(u, 0xE):
			continue
		if cls != -1 and w.launcher(lid, 9) & 7 != cls:
			continue
		best = rng_
		slot = s
	return slot


static func sight_any(sight: PackedByteArray, x: int, y: int) -> bool:   # 0x430590
	var i := 3 * (x + MAP * y)
	return (sight[i] | sight[i + 1] | sight[i + 2]) != 0


static func sight_bit(sight: PackedByteArray, x: int, y: int, k: int) -> int:   # 0x4305E0
	var i := 3 * (x + MAP * y)
	if k >= 0 and k < 16:
		return ((sight[i] | sight[i + 1] << 8) >> k) & 1
	if k >= 16 and k < 24:
		return (sight[i + 2] >> (k - 16)) & 1
	return 0


## 0x47DC60
static func spiral(x: int, y: int, r: int) -> Array:
	var out := [Vector2i(x, y)]
	if r == 0:
		return out
	for rr in range(1, r + 1):
		var o0: Vector2i = NB[y & 1][0]
		x += o0.x
		y += o0.y
		var d := 2
		for j in 6:
			for i in rr:
				var o: Vector2i = NB[y & 1][d]
				x += o.x
				y += o.y
				if 0 < x and x < 71 and 0 < y and y < 71:
					out.append(Vector2i(x, y))
			d = 0 if d == 5 else d + 1
	return out


static func _cdiv8(v: int) -> int:
	return -((-v) >> 3) if v < 0 else v >> 3


## 0x42FF00: the AI's score for every hex (lower is better).
static func ai_tactical_field(w: Pd2World, u: int, w_flag: int, w_area: int, w_cover: int, w_k1: int, w_k0: int,
		dx: int, dy: int, dfield: PackedInt32Array, sight: PackedByteArray) -> PackedInt32Array:
	var cls := w.unit_class(u)
	var s0 := ai_best_weapon(w, u, 0)
	var s1 := ai_best_weapon(w, u, 1)
	var r0 := w.weapon_range(u, s0) if s0 != -1 else 0
	var r1 := w.weapon_range(u, s1) if s1 != -1 else 0
	var watchers := []
	for k in w.n_units:
		if w.active(k) and w.sb(k, 0x36) <= 0 and w.ub(k, 0) & 0x10:
			watchers.append(k)
	var buf := PackedInt32Array()
	buf.resize(MAP * MAP)
	var low := 5000
	var has_o := not w.O.is_empty()
	for y in range(1, 71):
		for x in range(1, 71 - (y & 1)):
			var i := x + MAP * y
			var v := 4000 + _cdiv8(W.s8(w.terrain[S_COVER_ROWS + 16 * cls + w.terrain[w.T[i]]]) * w_cover)
			v += ((w.F[i] >> 4) & 1) * w_flag
			if sight_any(sight, x, y):
				var acc := 0
				for k in watchers:
					if not sight_bit(sight, x, y, k):
						continue
					var kp := w.pos(k)
					var d := W.hexdist(kp.x, kp.y, x, y)
					if d < r0:
						if d > r0 / 2:
							d = absi(r0 - d)
						acc += d * w_k0
					if d < r1:
						if d > r1 / 2:
							d = absi(r1 - d)
						acc += d * w_k1
				v -= acc
			v = AI_BLOCKED if dfield[i] == -1 else v + dfield[i]
			if w.H[i] == 0 or v < 0 or v > 10000:
				v = AI_BLOCKED
			var occ := (w.O[i] if has_o else 0) - 1
			if occ != -1 and w.sb(occ, 0x36) > 0:
				v = AI_BLOCKED
			if cls != 3 and w.F[i] & 0x80:
				v = AI_BLOCKED
			if v != AI_BLOCKED and low > v:
				low = v
			buf[i] = v
	for i in buf.size():
		if buf[i] == 0:
			buf[i] = AI_BLOCKED
	for k in watchers:
		var kp := w.pos(k)
		for p in spiral(kp.x, kp.y, w_area if w_area > 0 else 4):
			var i: int = p.x + MAP * p.y
			if 0 < p.x and p.x < 72 and 0 < p.y and p.y < 72 and buf[i] != AI_BLOCKED:
				buf[i] += w_area - W.hexdist(kp.x, kp.y, p.x, p.y)
	if buf[dx + MAP * dy] != AI_BLOCKED:
		buf[dx + MAP * dy] = low - 10
	return buf


## 0x47E270: rough hex direction 0-5; -1 if the same.
static func ai_direction(x1: int, y1: int, x2: int, y2: int) -> int:
	var dx := x2 - x1
	var dy := y2 - y1
	var adx := absi(dx)
	var ady := absi(dy)
	if dx == 0 and dy == 0:
		return -1
	if adx > ady:
		var q := 10 * ady / adx
		if dx >= 0:
			return 2 if q <= 5 else (3 if dy >= 0 else 1)
		return 5 if q <= 5 else (4 if dy >= 0 else 0)
	var q2 := 10 * adx / ady if ady else 0
	if q2 > 20:
		return 2 if dx > 0 else 5
	var shifted := not (y1 & 1) and (y2 & 1)
	if dy > 0:
		return 3 + int((dx < 0) if shifted else (dx <= 0))
	return int(dx >= 0) if shifted else int(dx > 0)


## 0x42F960
static func ai_threat_direction(w: Pd2World, u: int) -> int:
	var up := w.pos(u)
	var best := 75
	var kb := -1
	for k in w.n_units:
		if w.sb(k, 0x36) != 0 or not w.active(k):
			continue
		var kp := w.pos(k)
		var d := W.hexdist(up.x, up.y, kp.x, kp.y)
		if d < best:
			best = d
			kb = k
	if kb == -1:
		return -1
	var bp := w.pos(kb)
	return ai_direction(up.x, up.y, bp.x, bp.y)


## 0x4309D0
static func ai_players_near(w: Pd2World, u: int) -> int:
	var up := w.pos(u)
	var n := 0
	for k in mini(40, w.n_units):
		if w.active(k) and w.sb(k, 0x36) == 0 and w.ub(k, 0) & 0x10:
			var kp := w.pos(k)
			if W.hexdist(up.x, up.y, kp.x, kp.y) <= 4:
				n += 1
	return n


## 0x430660 (move mode 5): melee an adjacent player unit.
static func ai_charge(w: Pd2World, u: int, mm: Move.MoveMap, hooks: AiHooks) -> int:
	var up := w.pos(u)
	var best := -1
	var best_m := 100
	var cost := 0
	for d in 6:
		var o2: Vector2i = NB[up.y & 1][d]
		var nx := up.x + o2.x
		var ny := up.y + o2.y
		var o := w.O[nx + MAP * ny] - 1
		if o == -1 or w.sb(o, 0x36) != 0:
			continue
		if w.ub(o, 0xD) < w.ub(u, 0xD) >> 1 or machine_melee_of(w, o) < best_m:
			cost = mm.cell(nx, ny) & 0x7F
			best_m = machine_melee_of(w, o)
			best = o
	if cost == 0 or cost == 0x7F:
		return cost
	if machine_melee_of(w, u) <= best_m:
		return 7
	var tp := w.pos(best)
	spend_ap(w, u, cost)
	var res := hooks.melee(u, best)
	if res in AI_ABORT:
		return res
	if res == 0:
		hooks.destroy(best)
		if w.O[tp.x + MAP * tp.y] - 1 == -1:
			var s := hooks.step("walk", tp.x, tp.y, (w.ub(u, 4) >> 4) & 3, mm, u)
			if s in AI_ABORT:
				return s
		return 5
	if res == 1:
		return 6
	if res == 2 or res == 3:
		hooks.destroy(u)
		if res == 3:
			hooks.destroy(best)
		return -1
	return cost


## 0x42EE00(mode, u): move AI unit u one turn toward its destination. UNDEFINED where
## the game reads uninitialised data (rules.ai_move returns None).
static func ai_move(w: Pd2World, rng: Pd2Random, mode: int, u: int, sight: PackedByteArray, hooks: AiHooks = null) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var up := w.pos(u)
	var ux := up.x
	var uy := up.y
	var dx: int
	var dy: int
	if w.ub(u, 7) == 0xFF and w.ub(u, 8) != 0xFF:
		var p := w.pos(w.ub(u, 8))
		dx = p.x
		dy = p.y
	elif w.ub(u, 7) != 0xFF and w.ub(u, 8) != 0xFF:
		dx = w.ub(u, 7)
		dy = w.ub(u, 8)
	else:
		return UNDEFINED
	if dx == ux and dy == uy:
		return 3
	if not w.on_map(dx, dy):
		dx = ux
		dy = uy
	if mode < 0 or mode > 9:
		return UNDEFINED
	var wt: Array = AI_MOVE_WEIGHTS[mode]
	var w_flag: int = wt[0]
	var w_area: int = wt[1]
	var w_cover: int = wt[2]
	var w_k1: int = wt[3]
	var w_k0: int = wt[4]
	var mm_mode: int = mode if wt[5] == -1 else wt[5]
	var flag: int = wt[6]
	if w.ub(u, 1) & 0x0C == 8 or w.ub(u, 1) & 0x30 == 0x20:
		return 0
	if mm_mode == 0 or mm_mode == 6:
		var n := ai_players_near(w, u)
		mm_mode = 0 if n == 0 else (1 if n <= 3 else (2 if n == 4 else mm_mode))
	elif mm_mode == 1:
		mm_mode = 0
	elif mm_mode == 2:
		mm_mode = 1
	else:
		mm_mode = 2 if mm_mode == 3 else 1
	var ap := w.sb(u, 0xE)
	var reserve := 0
	if mm_mode == 0 and mode == 6 and rng.r16(100) < 50:
		reserve = 4 if w.ucrew(u, 8) & 1 else 8
		if ap - reserve < ap / 2:
			reserve = 0
			mm_mode = 1
	elif mode == 9:
		reserve = 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
		if ap - reserve < ap / 2:
			reserve = 0
	if not Move.MODE_FACTOR.has(mm_mode):
		return UNDEFINED
	var mm := Move.move_map(w, u, mm_mode)
	var any_ := false
	for v in mm.cells:
		if v != 0 and v != 0xFF:
			any_ = true
			break
	if not any_:
		return 0
	if mode == 5:
		var res := ai_charge(w, u, mm, hooks)
		if res in AI_ABORT:
			return 0
		if res:
			return res
	var df := ai_distance_field(w, u, dx, dy)
	if df[0]:
		return df[0]
	var field: PackedInt32Array = df[1]
	var run_in := 0
	if mode == 5 and field[ux + MAP * uy] + 2 > ap:
		w_flag = 10
		w_area = 0
		w_cover = 1
		w_k1 = 6
		w_k0 = 6
		flag = W.hexdist(ux, uy, dx, dy) / 2
		run_in = 1
	var tact := ai_tactical_field(w, u, w_flag, w_area, w_cover, w_k1, w_k0, dx, dy, field, sight)
	var threat := ai_threat_direction(w, u)
	var best := 0x7FFE
	var bx := -1
	var by := -1
	var b_dist := 0
	var b_ap := 0
	var alt_ap := 0
	var alt_x := -1
	var alt_y := -1
	var near := 1
	for ly in mm.h:
		for lx in mm.w:
			var c := W.s8(mm.at(lx, ly))
			var cx := mm.x0 + lx
			var cy := mm.y0 + ly
			if c < 0 or w.O[cx + MAP * cy] - 1 != -1:
				continue
			var dist: int
			if flag:
				dist = 0x400
				near = W.hexdist(ux, uy, cx, cy)
			else:
				dist = W.hexdist(ux, uy, cx, cy)
			var score := tact[cx + MAP * cy]
			var take := near <= 6 and (score < best or (score == best and (mm_mode != 0 or c < b_ap) and b_dist > dist))
			if take:
				if c <= ap - reserve:
					best = score
					bx = cx
					by = cy
					b_dist = dist
					b_ap = c
				continue
			if score != AI_BLOCKED and alt_ap < c and (threat == -1 or ai_direction(ux, uy, cx, cy) == threat):
				alt_ap = c
				alt_x = cx
				alt_y = cy
	if bx == ux and by == uy:
		return 3
	if bx == -1 and by == -1 and alt_x != -1 and alt_y != -1:
		bx = alt_x
		by = alt_y
	if bx <= 0 or by <= 0:
		return 0
	var fb := field[bx + MAP * by]
	var fu := field[ux + MAP * uy]
	if field[dx + MAP * dy] != -1:
		if fb == -1:
			if W.hexdist(bx, by, dx, dy) > W.hexdist(ux, uy, dx, dy):
				return 0
		elif fb >= fu and fu != -1:
			return 0
	var walk := W.hexdist(ux, uy, bx, by) == 1 and (absi(w.H[bx + MAP * by] - w.H[ux + MAP * uy]) < 2 or w.unit_class(u) >= 2)
	var s := hooks.step("walk" if walk else "path", bx, by, mm_mode, mm, u)
	if s in AI_ABORT:
		return s
	if s >= 4:
		return -1
	if s == 0 and bx == dx and by == dy:
		return 10 if run_in else 3
	if s == 1:
		return 1
	return 4 if s < 2 else 2


## 0x42C810
static func ai_any_player(w: Pd2World) -> bool:
	for k in w.n_units:
		if w.sb(k, 0x36) == 0 and w.active(k):
			return true
	return false


## 0x410D70: the indirect-fire trajectory check.
static func arc_clear(w: Pd2World, x1: int, y1: int, x2: int, y2: int, variant: int) -> bool:
	var h1 := w.layer(w.H, x1, y1) + 1
	var occ := w.layer(w.O, x1, y1) - 1
	if occ != -1 and w.unit_class(occ) >= 2:
		h1 = 31 if h1 < 31 else h1 + 1
	var dist := W.hexdist(x1, y1, x2, y2)
	var n := maxi(2 * absi(x1 - x2) + 2, absi(y1 - y2) + 1)
	var X1 := Sight.to_doubled(x1, y1, variant)
	var X2 := Sight.to_doubled(x2, y2, variant)
	var px := x1
	var py := y1
	for step in n + 1:
		var P := Sight.line_point(X1, y1, X2, y2, step)
		var x := Sight.from_doubled(P.x, P.y, variant)
		if W.hexdist(x1, y1, x, P.y) > dist or (x == px and P.y == py):
			continue
		if w.layer(w.H, x, P.y) >= h1 + 30:
			return false
		px = x
		py = P.y
	return true


## 0x47DDB0
static func blast_area(w: Pd2World, x: int, y: int, r: int) -> Array:
	var s := spiral(x, y, r)
	var out := [s[0]]
	for i in range(1, s.size()):
		var h: Vector2i = s[i]
		if arc_clear(w, x, y, h.x, h.y, 0) or arc_clear(w, x, y, h.x, h.y, 1):
			out.append(h)
	return out


static func slot_usable(w: Pd2World, u: int, s: int) -> int:
	var lid := w.launcher_id(u, s)
	if lid == -1 or w.slot_state(u, s) == 2:
		return -999
	if w.ub(u, 0x1C + 2 * (w.ub(u, 0x10 + 2 * s) & 15)) >> 6 == 2:
		return -999
	return lid


static func _ground_targets(w: Pd2World) -> Array:
	var out := []
	for k in w.n_units:
		if w.active(k) and w.sb(k, 0x36) == 0 and w.ub(k, 0) & 0x10 and w.unit_class(k) <= 1:
			out.append(k)
	return out


static func _los2(w: Pd2World, a: Vector2i, b: Vector2i) -> bool:
	return Sight.line_of_sight(w, a.x, a.y, b.x, b.y, 1, 0) or Sight.line_of_sight(w, a.x, a.y, b.x, b.y, 1, 1)


## 0x42DFF0: [slot, score, x, y] (slot -1, score 0, x, y -1 if none)
static func ai_pick_indirect(w: Pd2World, rng: Pd2Random, u: int, radius := -1) -> Array:
	var up := w.pos(u)
	var best := 0
	var b_slot := -1
	var bx := -1
	var by := -1
	for k in _ground_targets(w):
		var kp := w.pos(k)
		var d := W.hexdist(up.x, up.y, kp.x, kp.y)
		for s in 4:
			var lid := slot_usable(w, u, s)
			if lid == -999:
				continue
			var kind := w.launcher(lid, 8) >> 5
			var rad := w.launcher(lid, 9) & 7
			if not (arc_clear(w, kp.x, kp.y, up.x, up.y, 0) or arc_clear(w, kp.x, kp.y, up.x, up.y, 1)):
				continue
			if w.weapon_range(u, s) < d or not (kind == 1 or (kind == 2 and d >= 6)):
				continue
			if radius != rad and radius != -1:
				continue
			for h in blast_area(w, kp.x, kp.y, rad):
				var acc := 0
				for i in blast_area(w, h.x, h.y, rad):
					var o := w.O[i.x + MAP * i.y] - 1
					if o == -1:
						continue
					if w.sb(o, 0x36) >= 3:
						acc -= ai_fire_score(w, rng, u, o, s)
					elif w.ub(o, 0) & 0x10:
						acc += ai_fire_score(w, rng, u, o, s)
				if acc > best:
					best = acc
					b_slot = s
					bx = h.x
					by = h.y
	return [b_slot, best, bx, by]


## 0x42DD50: [target, slot, score]
static func ai_pick_direct(w: Pd2World, rng: Pd2Random, u: int, radius := -1) -> Array:
	var up := w.pos(u)
	var best := 0
	var b_slot := -1
	var b_t := -1
	for k in _ground_targets(w):
		var kp := w.pos(k)
		var d := W.hexdist(up.x, up.y, kp.x, kp.y)
		var mult := 3 if d <= 2 else 1
		for s in 4:
			var lid := slot_usable(w, u, s)
			if lid == -999:
				continue
			var kind := w.launcher(lid, 8) >> 5
			var rad := w.launcher(lid, 9) & 7
			if w.weapon_range(u, s) < d or kind != 0 or (radius != rad and radius != -1):
				continue
			if not _los2(w, up, kp):
				continue
			var acc := 0
			for h in spiral(kp.x, kp.y, rad):
				var o := w.O[h.x + MAP * h.y] - 1
				if o != -1 and w.sb(o, 0x36) == 0 and w.ub(o, 0) & 0x10:
					acc += ai_fire_score(w, rng, u, o, s) * mult
			if acc > best:
				best = acc
				b_slot = s
				b_t = k
	return [b_t, b_slot, best]


## 0x42DA50: [target, slot, score]
static func ai_pick_aa(w: Pd2World, rng: Pd2Random, u: int) -> Array:
	var up := w.pos(u)
	var best := 0
	var b_slot := -1
	var b_t := -1
	for k in w.n_units:
		if w.sb(k, 0x36) != 0 or not w.active(k) or not (w.ub(u, 0) & 0x10):
			continue
		if w.unit_class(k) <= 1:
			continue
		var kp := w.pos(k)
		var d := W.hexdist(up.x, up.y, kp.x, kp.y)
		var mult := 3 if d <= 2 else 1
		for s in 4:
			var lid := slot_usable(w, u, s)
			if lid == -999:
				continue
			if w.weapon_range(u, s) < d or (w.launcher(lid, 8) >> 5 == 2 and d < 6):
				continue
			if w.launcher(lid, 5) == 0 or Move.final_attack(w, u, s, true) == 0:
				continue
			if not _los2(w, up, kp):
				continue
			var sc := ai_fire_score(w, rng, u, k, s) * mult
			if sc > best:
				best = sc
				b_slot = s
				b_t = k
	return [b_t, b_slot, best]


## 0x42D770(u, radius, threshold, max_shots)
static func ai_engage(w: Pd2World, rng: Pd2Random, u: int, radius: int, threshold: int, max_shots: int, hooks: AiHooks = null) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	if not ai_any_player(w):
		return 0
	var shots := 0
	while true:
		var ind := ai_pick_indirect(w, rng, u, radius)
		var dir := ai_pick_direct(w, rng, u, radius)
		var aa := ai_pick_aa(w, rng, u)
		var i_score: int = ind[1]
		var d_score: int = dir[2]
		var a_score: int = aa[2]
		var shot := []
		if i_score == 0 and d_score == 0 and a_score == 0:
			pass
		elif a_score > 0:
			var p := w.pos(aa[0])
			shot = [aa[1], p.x, p.y]
		else:
			var indirect := i_score > 0 and (i_score > d_score or (i_score == d_score and rng.roll(100) & 1))
			if indirect:
				if i_score >= threshold and ind[2] > 0 and ind[3] > 0:
					shot = [ind[0], ind[2], ind[3]]
			elif i_score <= d_score and d_score > 0 and d_score >= threshold:
				var p2 := w.pos(dir[0])
				shot = [dir[1], p2.x, p2.y]
		if shot.is_empty():
			return 1
		var res := hooks.fire(u, shot[0], shot[1], shot[2])
		if res in AI_ABORT:
			return res
		if not w.active(u):
			return 0
		if w.slot_count(u, shot[0]) == 0:
			res = hooks.reload(u)
			if res == 0x10000 or res == 0x20000:
				return res
		shots += 1
		if shots > max_shots:
			return 1
	return 1


## 0x47CCA0 (less its redraw)
static func spend_ap(w: Pd2World, u: int, n: int) -> void:
	w.setb(u, 0xE, 0 if w.sb(u, 0xE) < n else w.ub(u, 0xE) - n)


## 0x42C790
static func ai_player_within(w: Pd2World, u: int, dist: int) -> int:
	var up := w.pos(u)
	for k in w.n_units:
		if w.sb(k, 0x36) == 0 and w.active(k):
			var kp := w.pos(k)
			if W.hexdist(up.x, up.y, kp.x, kp.y) <= dist:
				return 1
	return 0


## 0x42D700
static func ai_longest_range(w: Pd2World, u: int) -> int:
	var best := 0
	for s in 4:
		var lid := w.launcher_id(u, s)
		if lid == -1 or w.launcher(lid, 8) >> 5 == 2 or Move.final_attack(w, u, s, false) == 0:
			continue
		best = maxi(best, w.weapon_range(u, s))
	return best


## 0x42D3D0
static func ai_conceal(w: Pd2World, u: int) -> int:
	var cost := 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
	if cost <= w.sb(u, 0xE) and not (w.ub(u, 0) & 0x20):
		w.setb(u, 0, w.ub(u, 0) | 0x20)
		spend_ap(w, u, cost)
	return 0


## 0x47CBD0
static func manipulator_state(w: Pd2World, u: int) -> int:
	var v := (w.ub(u, 1) >> 6) + (w.ub(u, 2) & 3)
	return 0 if v == 0 else (1 if v <= 3 else (2 if v == 4 else 0))


## 0x480990
static func reload_pockets(w: Pd2World, u: int, s: int) -> Array:
	var lid := w.launcher_id(u, s)
	var takes := []
	for j in 3:
		takes.append(W.s8(w.launcher(lid, 0xA + j)))
	var out := []
	for p in 12:
		var a := w.pocket_ammo(u, p)
		if a == -1 or w.pocket_state(u, p) == 2:
			continue
		var used := false
		for i in 4:
			if w.launcher_id(u, i) != -1 and w.ub(u, 0x10 + 2 * i) & 15 == p:
				used = true
		if not used and a in takes:
			out.append(p)
	return out


## 0x42D140
static func ai_reload(w: Pd2World, u: int) -> int:
	if manipulator_state(w, u) == 2 or w.ub(u, 0xE) == 0:
		return 0
	for s in 4:
		var lid := w.launcher_id(u, s)
		if lid == -1 or w.slot_count(u, s) != 0:
			continue
		if w.ub(u, 0x1C + 2 * (w.ub(u, 0x10 + 2 * s) & 15)) >> 6 == 2:
			continue
		var pockets := reload_pockets(w, u, s) if w.launcher(lid, 9) & 8 else []
		if not pockets.is_empty():
			var cost := w.ammo(W.s8(w.launcher(lid, 0xA)), 7) & 0x1F
			if cost > w.sb(u, 0xE):
				continue
			var done := false
			for p in pockets:
				var st := w.pocket_state(u, p)
				var cnt := w.pocket_count(u, p) if st != 2 else 0
				if st != 2 and cnt != 0:
					var old := w.ub(u, 0x10 + 2 * s) & 15
					w.setb(u, 0x10 + 2 * s, (w.ub(u, 0x10 + 2 * s) & 0xF0) | p)
					w.setb(u, 0x1B + 2 * old, 0xFF)
					spend_ap(w, u, cost)
					done = true
				elif w.ub(u, 0xE) != 0:
					w.setb(u, 0x1B + 2 * p, 0xFF)
					spend_ap(w, u, 1)
				if w.ub(u, 0xE) == 0:
					done = true
				if done or cost > w.sb(u, 0xE):
					break
		elif w.ub(u, 0xE) != 0:
			w.setb(u, 0x1B + 2 * (w.ub(u, 0x10 + 2 * s) & 15), 0xFF)
			w.setb(u, 0xF + 2 * s, 0xFF)
			spend_ap(w, u, 1)
	return 0


## 0x46F320
static func set_view(w: Pd2World, x: int, y: int, side: int) -> void:
	w.F[x + MAP * y] |= 1 << (3 if side < 3 else 2)


## 0x42D430: the AI's search command. Returns the number of units spotted (or an abort code).
static func ai_search(w: Pd2World, u: int, force := 0, hooks: AiHooks = null) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var cost := 4 if w.ucrew(u, 8) & 1 else 8
	if cost > w.sb(u, 0xE):
		return 0
	var rp := Sight.recon_range(w, u)
	if (2 if w.ub(u, 1) & 3 == 2 else rp.x) < 3:
		return 0
	var up := w.pos(u)
	var g := up.x + MAP * up.y
	var climb := w.unit_class(u) == 3
	var saved := w.H[g]
	if climb:
		w.H[g] = (saved + 6) & 0xFF
	var side := 3 if w.is_enemy(u) else 0
	var found := 0
	var smap := Sight.search_map(w, up.x, up.y, rp.x, rp.y)
	if smap != null:
		var seen := []
		for ly in smap.h:
			for lx in smap.w:
				if smap.at(lx, ly) != 0xFF:
					seen.append(Vector2i(smap.x0 + lx, smap.y0 + ly))
		var fresh := force == 1
		if not fresh:
			for p in seen:
				if not in_view(w, p.x, p.y, side):
					fresh = true
					break
		if fresh:
			for p in seen:
				set_view(w, p.x, p.y, side)
			var spotted := Sight.spot_in_map(w, u, smap, 8)
			for k in spotted:
				if k < 40:
					w.memory[3 * k] = w.ub(k, 9)
					w.memory[3 * k + 1] = w.ub(k, 10)
			found = spotted.size()
			spend_ap(w, u, cost)
			w.setb(u, 4, w.ub(u, 4) | 0x30)
			if climb and w.ub(u, 0) & 0x10 and not (w.ub(u, 0) & 0x40):
				var res := hooks.react(u)
				if res in AI_ABORT:
					return res
	if climb:
		w.H[g] = saved
	return found


## 0x4539A0: Bresenham step on the plain grid.
static func line_step(x1: int, y1: int, x2: int, y2: int, step: int) -> Vector2i:
	var dx := x2 - x1
	var dy := y2 - y1
	var sx := -1 if dx < 0 else 1
	var sy := -1 if dy < 0 else 1
	dx = absi(dx)
	dy = absi(dy)
	var x := x1
	var y := y1
	if dx > dy:
		var err := -dx
		x = x1 + sx * step
		for i in step:
			err += 2 * dy
			if err >= 0:
				y += sy
				err -= 2 * dx
	else:
		var err := -dy
		y = y1 + sy * step
		for i in step:
			err += 2 * dx
			if err >= 0:
				x += sx
				err -= 2 * dy
	return Vector2i(x, y)


## 0x440FA0: line length in hundredths.
static func grid_distance(x1: int, y1: int, x2: int, y2: int) -> int:
	var n := maxi(absi(x2 - x1) & 0xFF, absi(y2 - y1) & 0xFF)
	var total := 0
	var px := x1
	var py := y1
	for i in n:
		var p := line_step(x1, y1, x2, y2, i + 1)
		var mx := absi(p.x - px) & 0xFF
		var my := absi(p.y - py) & 0xFF
		total += 140 if mx and my else (100 if mx or my else 0)
		px = p.x
		py = p.y
	return total


static func gb(w: Pd2World, g: int, f: int) -> int:
	return w.groups[35 * g + f]


static func setgb(w: Pd2World, g: int, f: int, v: int) -> void:
	w.groups[35 * g + f] = v & 0xFF


## 0x47C6D0
static func unit_group(w: Pd2World, k: int) -> int:
	for g in w.groups.size() / 35:
		if gb(w, g, 5) and gb(w, g, 22) != 0xFF:
			for i in range(6, 22):
				if gb(w, g, i) == k:
					return g
	return -1


static func can_aa(w: Pd2World, t: int) -> bool:
	for s in 4:
		if w.launcher_id(t, s) != -1 and Move.final_attack(w, t, s, true):
			return true
	return false


## 0x483B90
static func mark_strike(w: Pd2World, x: int, y: int, k: int, slot: int) -> void:
	for h in spiral(x, y, w.launcher(w.launcher_id(k, slot), 9) & 7):
		if w.on_map(h.x, h.y):
			w.F[h.x + MAP * h.y] |= STRIKE_FLAG


## 0x42CD10: [x, y] (x = -1: [-1, unit]) or null.
static func support_target(w: Pd2World, rng: Pd2Random, k: int, slot: int, easy := false) -> Variant:
	var lid := w.launcher_id(k, slot)
	var kind := w.launcher(lid, 8) >> 5
	var rad := w.launcher(lid, 9) & 7
	var found: Variant = null
	var targets := []
	for t in w.n_units:
		if w.sb(t, 0x36) == 0 and w.active(t) and w.ub(t, 0) & 0x10:
			targets.append(t)
	if kind == 2:
		var best := 200
		for t in targets:
			var c := w.ub(t, 0xD)
			if c >= best:
				continue
			if can_aa(w, t) and rng.r16(100) <= 60:
				continue
			best = c
			found = Vector2i(-1, t)
		return found
	var best2 := 0
	for t in targets:
		var tp := w.pos(t)
		var area := spiral(tp.x, tp.y, rad)
		var acc := 0
		var cnt := 0
		var marked := 0
		for h in area:
			if not w.on_map(h.x, h.y):
				continue
			if w.F[h.x + MAP * h.y] & STRIKE_FLAG and rng.r16(100) >= 5:
				continue
			cnt += 1
			var o := w.O[h.x + MAP * h.y] - 1
			if o == -1:
				continue
			if w.sb(o, 0x36) >= 3:
				acc -= Fire.fire_damage(w, rng, k, slot, o, 9, easy)
			elif w.ub(o, 0) & 0x10:
				acc += Fire.fire_damage(w, rng, k, slot, o, 9, easy)
			if w.F[h.x + MAP * h.y] & 0x80:
				marked += 1
		acc = 0 if marked >= cnt / 5 else acc - 5 * marked
		if acc > best2:
			best2 = acc
			found = area.back()
	if found == null and rng.r16(100) < 10:
		for t in mini(40, w.n_units):
			var m := mem(w, t)
			if not w.on_map(m.x, m.y) or not w.active(t) or w.sb(t, 0x36) != 0:
				continue
			if w.ub(t, 0) & 0x10:
				continue
			var bad := false
			for h in spiral(m.x, m.y, rad):
				if w.F[h.x + MAP * h.y] & 0x80:
					bad = true
					break
			if bad:
				continue
			if not (w.F[m.x + MAP * m.y] & STRIKE_FLAG):
				found = m
	return found


## 0x4410B0
static func group_retarget(w: Pd2World, g: int, x: int, y: int) -> void:
	x &= 0xFF
	y &= 0xFF
	if gb(w, g, 26) == x and gb(w, g, 27) == y:
		return
	if W.s8(x) < 0:
		x = gb(w, g, 24)
		y = gb(w, g, 25)
		setgb(w, g, 24, gb(w, g, 26))
		setgb(w, g, 25, gb(w, g, 27))
		setgb(w, g, 22, gb(w, g, 26))
		setgb(w, g, 23, gb(w, g, 27))
	else:
		setgb(w, g, 24, gb(w, g, 22))
		setgb(w, g, 25, gb(w, g, 23))
	setgb(w, g, 26, x)
	setgb(w, g, 27, y)
	var g2 := gb(w, g, 2)
	if g2 & 0x30 == 0x20 and g2 & 0xC0 != 0x80:
		setgb(w, g, 2, (g2 & 0xDF) | 0x10)
	setgb(w, g, 28, 0)
	setgb(w, g, 34, 0)


## 0x42C850(u, limit): u calls in fire support on w.fire_point.
static func ai_fire_support(w: Pd2World, rng: Pd2Random, u: int, limit := -1, easy := false) -> int:
	var cost := 6 if (w.ucrew(u, 8) >> 2) & 1 else 12
	if w.sb(u, 0xE) < cost:
		return 0
	var tx := w.fire_point.x
	var ty := w.fire_point.y
	var orders := []
	for g in range(20, 64):
		var gtype := gb(w, g, 33) & 0xF0
		if not gb(w, g, 5) or gb(w, g, 2) & 0x30 != 0x20 or not gtype in [0x30, 0x40, 0x50]:
			continue
		var shadow := 0
		for h in 20:
			if gb(w, h, 5) and (gb(w, h, 33) & 0xF0) in [0x30, 0x40] and gb(w, h, 22) == gb(w, g, 22) and gb(w, h, 23) == gb(w, g, 23):
				shadow = h
		for i in 16:
			var k := gb(w, g, 6 + i)
			if k == 0xFF or gb(w, g, 2) & 0xC0 or shadow or w.ub(k, 6) == 1 or w.ub(k, 6) == 2:
				continue
			var best := 0
			var b_slot := -1
			for s in 6:
				var lid := w.launcher_id(k, s)
				if lid == -1:
					continue
				var kind := w.launcher(lid, 8) >> 5
				if w.launcher(lid, 2) == 0 and w.warhead(k, s) != 8:
					continue
				var atk := Move.final_attack(w, k, s, false)
				if atk == 0 or w.slot_count(k, s) == 0 or w.slot_state(k, s) == 2:
					continue
				if (gtype == 0x50 or kind == 2) and 10 * w.weapon_range(k, s) < grid_distance(W.s8(gb(w, g, 22)), W.s8(gb(w, g, 23)), tx, ty):
					continue
				if kind * atk > best:
					best = kind * atk
					b_slot = s
			if b_slot != -1:
				orders.append([k, b_slot])
	for i in orders.size():
		var k: int = orders[i][0]
		var slot: int = orders[i][1]
		if limit != -1 and i >= limit:
			break
		if w.sb(u, 0xE) < cost:
			break
		var aim: Variant = support_target(w, rng, k, slot, easy)
		if aim == null:
			continue
		mark_strike(w, aim.x, aim.y, k, slot)
		w.setb(k, 7, aim.x)
		w.setb(k, 8, aim.y)
		w.setb(k, 0x35, slot)
		w.setb(k, 6, 1)
		var g := unit_group(w, k)
		if g != -1 and (gb(w, g, 33) & 0xF0) in [0x30, 0x40]:
			var keep := gb(w, g, 2) & 0x30
			group_retarget(w, g, tx, ty)
			setgb(w, g, 2, (gb(w, g, 2) & 0xCF) | keep)
		spend_ap(w, k, cost)
	return 0
