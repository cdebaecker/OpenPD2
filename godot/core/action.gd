class_name Action
extends RefCounted
## The commands' resolution: the fire resolution and AI fire command, the reaction shot,
## the movement steps (rules.py from STATS_ADDR to ai_path; RULES.md 4 and 5.8).

const W := preload("res://core/world.gd")
const MAP := 72
const NB := Move.NEIGHBOURS
const STATS_SIZE := 13
const SMOKE_WARHEAD := 8
const MINE_WARHEAD := 13
const FIRE_GROW := {0: "ATTACK", 1: "ATTACK", 5: "ATTACK", 6: "AA", 10: "AA"}   # 0x415B04 / 0x415B24
const KILL_COLUMN := {0: 0, 1: 2, 2: 3, 3: 3, 4: 3, 5: 3, 6: 1, 7: 2, 8: 2}        # 0x480B10


## 0x471510..0x4716F0: bump a field of u's combat record (crew +15; < 0: none).
static func count(w: Pd2World, u: int, off: int, wide: bool) -> void:
	var i := W.s8(w.ucrew(u, 15))
	if i < 0:
		return
	var o := STATS_SIZE * i + off
	if wide:
		var v := w.combat[o] | w.combat[o + 1] << 8
		if v < 0xFFFF:
			v += 1
		w.combat[o] = v & 0xFF
		w.combat[o + 1] = v >> 8
	elif w.combat[o] < 0xFF:
		w.combat[o] += 1


static func mine_at(w: Pd2World, x: int, y: int) -> int:   # 0x46F650(x, y, -1, 1)
	return w.F[x + MAP * y] >> 6


static func lay_mine(w: Pd2World, x: int, y: int, side: int) -> void:   # 0x46F720
	w.F[x + MAP * y] |= (2 if side == 3 else 1) << 6


## 0x47DFC0: the hexes a shot at (x, y) with blast radius r hits, in resolution order.
static func fire_area(w: Pd2World, rng: Pd2Random, x: int, y: int, r: int) -> Array:
	var a := Ai.blast_area(w, x, y, r)
	var n := a.size()
	if n <= 2:
		return [Vector2i(x, y)]
	var b := [a[n - 1]] + a.slice(1, n - 1)
	var out := [Vector2i(x, y)]
	var i := n - 2
	while true:
		var k := rng.r16(i)
		var last = b[i]
		out.append(b[k])
		b[k] = last
		i -= 1
		if i == 0:
			break
	out.append(b[0])
	return out


## 0x415150: resolve one shot of s's slot in fire mode `mode` at (x, y) over `targets`.
static func fire_resolution(w: Pd2World, rng: Pd2Random, s: int, slot: int, mode: int, x: int, y: int,
		targets: Array = [], hooks: AiHooks = null, easy := false) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var side := 3 if w.is_enemy(s) else 0
	var sp := w.pos(s)
	if Ai.in_view(w, sp.x, sp.y, 0 if side == 3 else 3):
		w.setb(s, 0, w.ub(s, 0) | 0x10)
	var hs := w.H[sp.x + MAP * sp.y]
	var pts: Array = targets if not targets.is_empty() else [Vector2i(x, y)]
	var first_y: int = pts[0].y
	var move := -1
	if mode > 0x80:
		mode -= 0x80
		move = 0
		first_y = 0
	var aa := false
	var reaction := false
	if FIRE_GROW.has(mode):
		w.events.append(["grow", s, FIRE_GROW[mode], 1])
		aa = FIRE_GROW[mode] == "AA"
		if mode == 5 or mode == 10:
			reaction = true
			move = -1 if first_y == 0 else (w.ub(s, 4) >> 4) & 3
	var wh := w.warhead(s, slot)
	count(w, s, 4, true)
	var kind := w.launcher(w.launcher_id(s, slot), 8) >> 5
	var shooter_dies := false
	var choice := Callable(hooks, "intercept_choice")
	for p in pts:
		var tx: int = p.x
		var ty: int = p.y
		if w.H[tx + MAP * ty] - hs > 30:
			continue
		var blocked := 0
		if wh == SMOKE_WARHEAD:
			if w.on_map(tx, ty):
				w.F[tx + MAP * ty] |= 1
			continue
		var o := w.O[tx + MAP * ty] - 1
		if o != -1:
			var o_side := 3 if w.is_enemy(o) else 0
			var skip := (kind == 0 and (o_side == side or not (w.ub(o, 0) & 0x10))) or \
					(w.unit_class(o) < 2 if aa else w.unit_class(o) >= 2)
			if not skip:
				if kind == 2 and not reaction:
					blocked = Fire.intercept(w, rng, s, slot, o, choice)
				else:
					blocked = 1
				var terms := Fire.hit_terms(w, s, o, slot, mode, move)
				if terms.has("error"):
					w.fault = "division by zero (weapon range 0)"
					return 0
				var hit := Fire.roll_hit(rng, terms)
				if blocked == 1 and hit:
					count(w, s, 6, true)
					var dmg := Fire.fire_damage(w, rng, s, slot, o, mode, easy)
					if dmg and FIRE_GROW.has(mode):
						w.events.append(["grow", s, FIRE_GROW[mode], 1])
					if w.ub(o, 0xD) - dmg <= 0:
						var i := W.s8(w.ucrew(s, 15))
						if i >= 0:
							var col: int = KILL_COLUMN.get(w.umachine(o, 0) & 15, 3)
							if w.combat[STATS_SIZE * i + col] < 0xFF:
								w.combat[STATS_SIZE * i + col] += 1
					if Fire.apply_hit(w, rng, o, dmg, s, slot, easy) == "destroyed":
						if o == s:
							shooter_dies = true
						else:
							hooks.destroy(o)
					blocked = 0
				else:
					w.events.append(["grow", o, "DEF", 1])
		elif kind != 0 and kind != 3 and w.on_map(tx, ty) and not w.campaign and wh == MINE_WARHEAD:
			if not mine_at(w, tx, ty):
				lay_mine(w, tx, ty, side)
				blocked = 1
		if not w.campaign and not blocked and (wh < 3 or wh == MINE_WARHEAD) and mine_at(w, tx, ty):
			hooks.mine_blast(tx, ty)
			w.F[tx + MAP * ty] &= 0x3F
			if o != -1 and w.unit_class(o) < 2:
				var dmg2 := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
				if Fire.apply_hit(w, rng, o, dmg2, -1, 12, easy) == "destroyed":
					hooks.destroy(o)
	if shooter_dies:
		hooks.destroy(s)
	return 0


## 0x415D50: the AI's fire command at (x, y).
static func ai_fire(w: Pd2World, rng: Pd2Random, s: int, slot: int, x: int, y: int, hooks: AiHooks = null, easy := false) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var lid := w.launcher_id(s, slot)
	var cost := Move.launcher_ap(w, lid)
	var o := w.O[x + MAP * y] - 1
	var rad: int
	var mode: int
	if o != -1 and w.unit_class(o) >= 2:
		rad = 0
		mode = 6
	else:
		rad = w.launcher(lid, 9) & 7
		mode = 0
	var pts := fire_area(w, rng, x, y, rad)
	fire_resolution(w, rng, s, slot, mode, x, y, pts, hooks, easy)
	if w.fault != "":
		return 0
	Ai.spend_ap(w, s, cost)
	w.set_slot_count(s, slot, w.slot_count(s, slot) - 1)
	if w.ub(s, 0) & 0x10 and not (w.ub(s, 0) & 0x40):
		var res := hooks.react(s)
		if res in Ai.AI_ABORT:
			return res
	return 0


## 0x4731F0: b's reaction shot with `slot` at t. Returns 6 if t was destroyed, else 2.
static func reaction_shot(w: Pd2World, rng: Pd2Random, b: int, slot: int, t: int, flag: int, hooks: AiHooks = null, easy := false) -> int:
	var mode := 10 if w.unit_class(t) >= 2 else 5
	if flag:
		mode += 0x80
	var keep := (w.ub(t, 4) >> 4) & 3
	var tp := w.pos(t)
	fire_resolution(w, rng, b, slot, mode, tp.x, tp.y, [], hooks, easy)
	if w.fault != "":
		return 0
	w.setb(b, 0, w.ub(b, 0) | 0x40)
	if flag == 0:
		var c := 4 if keep == 0 else (2 if keep == 1 else (1 if keep == 2 else 2))
		Ai.spend_ap(w, t, (2 if w.ub(t, 0x34) != 0xFF else 1) * c)
	w.set_slot_count(b, slot, w.slot_count(b, slot) - 1)
	w.setb(t, 4, (w.ub(t, 4) & 0xCF) | keep << 4)
	return 6 if w.ub(t, 0xD) == 0 else 2


## A move-map cell as rules.py reads it (a Python list: negative offsets wrap).
static func mm_signed(w: Pd2World, mm: Move.MoveMap, x: int, y: int) -> int:
	var lx := x - mm.x0
	var ly := y - mm.y0
	if lx < 0:
		lx += mm.w
	if ly < 0:
		ly += mm.h
	if lx < 0 or ly < 0 or lx >= mm.w or ly >= mm.h:
		w.fault = "move map read outside its window"
		return -1
	return W.s8(mm.cells[ly * mm.w + lx])


## 0x473CD0: the path to (x, y) through mm as [Vector3i(x, y, step AP)], or null.
static func move_path(w: Pd2World, u: int, x: int, y: int, mm: Move.MoveMap) -> Variant:
	var c0 := mm_signed(w, mm, x, y) & 0x7F
	if c0 == 0 or c0 == 0x7F:
		return null
	var cls := w.unit_class(u)
	var path := [Vector3i(x, y, c0)]
	var parity := 0
	while path.back().z != 0:
		var cur: Vector3i = path.back()
		var best := mm_signed(w, mm, cur.x, cur.y) & 0xFF
		var best_dir := -1
		var ties := []
		var hc := w.H[cur.x + MAP * cur.y]
		for d in 6:
			var o: Vector2i = NB[cur.y & 1][d]
			var nx := cur.x + o.x
			var ny := cur.y + o.y
			if not w.on_map(nx, ny):
				continue
			var v := mm_signed(w, mm, nx, ny)
			if v < 0 or (best & 0x7F) < (v & 0x7F):
				continue
			if cls < 2 and absi(w.H[nx + MAP * ny] - hc) >= 2:
				continue
			if (v ^ best) & 0x7F:
				ties = [d]
				best_dir = d
				best = v & 0x7F
			else:
				ties.append(d)
		if best_dir == -1:
			break
		var k := parity + ties.size() + 1
		parity = k & 1
		var d2: int = ties[k / 2 - 1]
		var o2: Vector2i = NB[cur.y & 1][d2]
		path.append(Vector3i(cur.x + o2.x, cur.y + o2.y, W.s8(best & 0xFF)))
	path.reverse()
	var out := [path[0]]
	for i in range(1, path.size()):
		out.append(Vector3i(path[i].x, path[i].y, path[i].z - path[i - 1].z))
	return out


## 0x47ED20: move u to (x, y). Returns the previous occupant of the new hex (-1 if none).
static func move_unit(w: Pd2World, u: int, x: int, y: int) -> int:
	var op := w.pos(u)
	if op.x == x and op.y == y:
		return -1
	if w.on_map(op.x, op.y) or op.x == 0 or op.x == 71 or op.y == 0 or op.y == 71 or (op.y & 1 and op.x == 70):
		w.O[op.x + MAP * op.y] = 0
	var prev := w.O[x + MAP * y]
	w.O[x + MAP * y] = (u + 1) & 0xFF
	var d := Ai.ai_direction(op.x, op.y, x, y)
	if d == -1:
		d = w.ub(u, 5) & 7
	w.setb(u, 5, (w.ub(u, 5) & 0xF8) | (d & 7))
	w.setb(u, 9, x)
	w.setb(u, 10, y)
	return prev - 1


## 0x474E20
static func step_visibility(w: Pd2World, u: int) -> void:
	var other := 0 if w.is_enemy(u) else 3
	var up := w.pos(u)
	var remember := u >= 0 and u < 40
	if Ai.in_view(w, up.x, up.y, other):
		w.setb(u, 0, w.ub(u, 0) | 0x10)
	else:
		w.setb(u, 0, w.ub(u, 0) & 0xEF)
		if w.unit_class(u) <= 1:
			return
		remember = false
		for k in w.n_units:
			if not w.active(k) or (w.is_enemy(k) != (other == 3)):
				continue
			if Sight.sees_unit(w, k, u):
				w.setb(u, 0, w.ub(u, 0) | 0x10)
				remember = u >= 0 and u < 40
				break
	if remember:
		w.memory[3 * u] = w.ub(u, 9)
		w.memory[3 * u + 1] = w.ub(u, 10)


## 0x47F950 for a movement mode: returns the units spotted.
static func step_search(w: Pd2World, u: int, mmode: int) -> Array:
	var mode := 8 if mmode == 3 else mmode
	var rp := Vector2i(2, 2) if mode == 0 else Sight.recon_range(w, u)
	var up := w.pos(u)
	var smap := Sight.search_map(w, up.x, up.y, rp.x, rp.y)
	if smap == null:
		return []
	var side := 3 if w.is_enemy(u) else 0
	for ly in smap.h:
		for lx in smap.w:
			if smap.at(lx, ly) != 0xFF:
				Ai.set_view(w, smap.x0 + lx, smap.y0 + ly, side)
	return Sight.spot_in_map(w, u, smap, mode)


static func toggle_mine(w: Pd2World, x: int, y: int, u: int) -> void:   # 0x46F7A0
	var bit := 0x40 if w.is_enemy(u) else 0x80
	var i := x + MAP * y
	w.F[i] = (w.F[i] & 0x3F) | ((w.F[i] & 0xC0) ^ bit)


static func mine_trigger(w: Pd2World, x: int, y: int, u: int) -> int:   # 0x46F650(x, y, u, 0)
	if w.unit_class(u) > 1:
		return 0
	return (w.F[x + MAP * y] >> 6) & (2 if u < 40 else 1)


## 0x474230: a mine goes off under u. Returns 1 if the blast destroys u.
static func step_mine_blast(w: Pd2World, rng: Pd2Random, x: int, y: int, u: int, mmode: int, hooks: AiHooks, easy := false) -> int:
	if not w.on_map(x, y):
		return 0
	hooks.mine_blast(x, y)
	var res := 0
	var dmg := Fire.fire_damage(w, rng, -1, 12, u, 4, easy)
	if mmode == 0:
		Ai.spend_ap(w, u, 4)
	elif mmode == 1:
		Ai.spend_ap(w, u, 2)
	if w.ub(u, 0xD) - dmg <= 0:
		res = 1
	if dmg and Fire.apply_hit(w, rng, u, dmg, -1, 12, easy) == "destroyed":
		hooks.destroy(u)
	toggle_mine(w, x, y, u)
	return res


## 0x475AE0: one step into an adjacent hex for a computer-side mover. Returns the bits.
static func ai_walk(w: Pd2World, rng: Pd2Random, u: int, x: int, y: int, mmode: int, mm: Move.MoveMap, hooks: AiHooks = null, easy := false) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var c := mm_signed(w, mm, x, y) & 0x7F
	Ai.spend_ap(w, u, c)
	move_unit(w, u, x, y)
	w.setb(u, 4, (w.ub(u, 4) & 0xCF) | (mmode & 3) << 4)
	w.setb(u, 0, w.ub(u, 0) & 0xDF)
	step_visibility(w, u)
	var res := 0
	if mine_trigger(w, x, y, u):
		if mmode == 2:
			Ai.spend_ap(w, u, 4)
			toggle_mine(w, x, y, u)
			res = 2
		else:
			res = 4 if step_mine_blast(w, rng, x, y, u, mmode, hooks, easy) else 2
	if res != 4:
		if not step_search(w, u, mmode).is_empty():
			res |= 1
		if w.ub(u, 0) & 0x10 and not (w.ub(u, 0) & 0x40):
			res |= hooks.react(u)
	return res


## 0x474510: walk along move_path to (x, y); stops after the first step with a result.
static func ai_path(w: Pd2World, rng: Pd2Random, u: int, x: int, y: int, mmode: int, mm: Move.MoveMap, hooks: AiHooks = null, easy := false) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var path: Variant = move_path(w, u, x, y, mm)
	if path == null:
		return 1
	var side := w.is_enemy(u)
	w.setb(u, 4, (w.ub(u, 4) & 0xCF) | (mmode & 3) << 4)
	var res := 0
	var under := -1
	for p in path:
		if res:
			break
		if Vector2i(p.x, p.y) == w.pos(u):
			continue
		var o := w.O[p.x + MAP * p.y] - 1
		if o != -1 and w.is_enemy(o) != side:
			res = 1
			continue
		Ai.spend_ap(w, u, p.z & 0x7F)
		var op := w.pos(u)
		var new_under := move_unit(w, u, p.x, p.y)
		if under != -1 and under != u:
			w.O[op.x + MAP * op.y] = (under + 1) & 0xFF
		under = new_under
		w.setb(u, 0, w.ub(u, 0) & 0xDF)
		step_visibility(w, u)
		if under == -1 and mine_trigger(w, p.x, p.y, u):
			if mmode == 2:
				if w.sb(u, 0xE) >= 4 and (w.ucrew(u, 8) >> 1) & 1:
					Ai.spend_ap(w, u, 4)
					toggle_mine(w, p.x, p.y, u)
					res = 2
			else:
				res = 4 if step_mine_blast(w, rng, p.x, p.y, u, mmode, hooks, easy) else 2
		if res != 4:
			if not step_search(w, u, mmode).is_empty() and under == -1:
				res |= 1
			if under == -1 and w.ub(u, 0) & 0x10 and not (w.ub(u, 0) & 0x40):
				res |= hooks.react(u)
	return res


# --- the player's fire command (cmd_fire 0x425AF0) -----------------------------------

const FIRE_FIRE := "fire"
const FIRE_CONFIRM := "confirm"
const FIRE_REFUSED := "refused"
const AA_FIRE_MODES := [6, 7, 10]


## 0x4118C0: the hexes u can fire at with `slot` in `mode` (1 / 0xFF cells), or null.
static func fire_target_map(w: Pd2World, u: int, slot: int, mode: int) -> Move.MoveMap:
	var up := w.pos(u)
	var g := up.x + MAP * up.y
	var h0 := w.H[g]
	var side := 3 if w.is_enemy(u) else 0
	var climb := w.unit_class(u) > 1
	if climb:
		w.H[g] = (h0 + 6) & 0xFF
	var res := _fire_target_map(w, u, slot, mode, up, h0, side)
	if climb:
		w.H[g] = h0
	return res


static func _fire_target_map(w: Pd2World, u: int, slot: int, mode: int, up: Vector2i, h0: int, side: int) -> Move.MoveMap:
	var rng_: int
	var kind: int
	if slot >= 0x80:
		rng_ = w.ammo(w.pocket_ammo(u, slot - 0x80), 3)
		kind = 99
	else:
		rng_ = w.weapon_range(u, slot) & 0xFF
		kind = w.launcher(w.launcher_id(u, slot), 8) >> 5
	var box := Move.move_box(up.x, up.y, rng_)
	var wd: int = box[2]
	var ht: int = box[3]
	if not kind in [0, 1, 2, 99] or wd * ht < 2:
		return null
	if kind == 0:
		return Sight.search_map(w, up.x, up.y, rng_, 1)
	var mm := Move.MoveMap.new()
	mm.x0 = box[0]
	mm.y0 = box[1]
	mm.w = wd
	mm.h = ht
	mm.cells = PackedByteArray()
	mm.cells.resize(wd * ht)
	mm.cells.fill(0xFF)
	for p in Ai.spiral(up.x, up.y, rng_):
		var i: int = (p.y - mm.y0) * wd - mm.x0 + p.x
		if kind == 2:
			if w.H[p.x + MAP * p.y] - h0 >= 30 or W.hexdist(p.x, p.y, up.x, up.y) <= 5:
				continue
			var o := w.O[p.x + MAP * p.y] - 1
			if o == -1 or (3 if w.is_enemy(o) else 0) == side or not (w.ub(o, 0) & 0x10):
				continue
			if (w.armour(o) == 4) != (mode == 6):
				continue
		mm.cells[i] = 1 if Ai.arc_clear(w, up.x, up.y, p.x, p.y, 0) or Ai.arc_clear(w, up.x, up.y, p.x, p.y, 1) else 0xFF
	return mm


## cmd_fire's decision for a clicked hex: [FIRE_FIRE / FIRE_CONFIRM / FIRE_REFUSED, message id or -1].
static func fire_check(w: Pd2World, u: int, slot: int, mode: int, x: int, y: int) -> Array:
	if slot >= 2 and Ai.manipulator_state(w, u) == 2:
		return [FIRE_REFUSED, 0x1A8]
	var lid := w.launcher_id(u, slot)
	var kind := w.launcher(lid, 8) >> 5
	var t := w.O[x + MAP * y] - 1
	if t != -1 and w.sb(t, 0x36) >= 3 and not (w.ub(t, 0) & 0x10):
		t = -1
	var enemy := t != -1 and w.sb(t, 0x36) >= 3
	if kind == 0:
		if w.warhead(u, slot) == SMOKE_WARHEAD:
			return [FIRE_FIRE, -1]
		if not enemy:
			return [FIRE_REFUSED, 0x1A9]
		if w.unit_class(t) < 2 or mode == 6:
			if w.armour(t) == 4 or mode != 6:
				return [FIRE_FIRE, -1]
			return [FIRE_REFUSED, 0x1AB]
		return [FIRE_REFUSED, 0x1AA if w.armour(t) == 4 else -1]
	if kind == 1:
		var radius := 0 if mode in AA_FIRE_MODES else w.launcher(lid, 9) & 7
		var up := w.pos(u)
		return [FIRE_CONFIRM, 0x1AC if radius >= W.hexdist(up.x, up.y, x, y) else 0x1AD]
	if kind == 2:
		if enemy and (w.unit_class(t) < 2 or mode == 6):
			return [FIRE_CONFIRM, 0x1AD]
		return [FIRE_REFUSED, 0x1A9]
	return [FIRE_REFUSED, -1]


## cmd_fire's shot: fire area, resolution, AP, round, and the other side's return fire.
static func player_fire(w: Pd2World, rng: Pd2Random, u: int, slot: int, mode: int, x: int, y: int,
		hooks: AiHooks = null, easy := false, alert := 0) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var lid := w.launcher_id(u, slot)
	var cost := Move.launcher_ap(w, lid) * (2 if mode == 1 else 1)
	var radius := 0 if mode in AA_FIRE_MODES else w.launcher(lid, 9) & 7
	var pts := fire_area(w, rng, x, y, radius)
	fire_resolution(w, rng, u, slot, mode, x, y, pts, hooks, easy)
	if w.fault != "":
		return 0
	Ai.spend_ap(w, u, cost)
	w.set_slot_count(u, slot, w.slot_count(u, slot) - 1)
	if w.ub(u, 0) & 0x10 and not (w.ub(u, 0) & 0x40):
		var cands := Sight.reaction_candidates(w, u, alert, w.units.size() / 55)
		if not cands.is_empty():
			var shot := func(b: int, s: int) -> int: return reaction_shot(w, rng, b, s, u, 1, hooks, easy)
			return Move.ai_reactions(w, rng, cands, u, 1, shot)
	return 0


# --- the weapon picker and the player's reaction menu (0x4E7EE0, 0x472920) ----------

## Launcher record byte as the picker reads it: an empty slot (-1) reads the 17 bytes
## before the launcher table, machine 31's tail.
static func _picker_launcher(w: Pd2World, lid: int, f: int) -> int:
	return w.machine(31, 14 + f) if lid == -1 else w.launcher(lid, f)


## The weapon picker's enabled items for u in `mode` (rules.weapon_choices): 0-3 the
## slots, 4-7 their magazine swaps.
static func weapon_choices(w: Pd2World, u: int, mode: int, dist := 0) -> Array:
	var out := []
	var mag_off := {}
	var hands_off := (w.ub(u, 1) & 0xC0) == 0x80 and (w.ub(u, 2) & 3) == 2
	for s in 4:
		var lid := w.launcher_id(u, s)
		var off := false
		var rng_ := w.weapon_range(u, s) & 0xFF
		if rng_ == 0 or (mode in [5, 10] and rng_ < dist):
			off = true
		if s > 1 and hands_off:
			off = true
		var wh := w.warhead(u, s)
		if mode in [6, 7, 10]:
			if _picker_launcher(w, lid, 5) == 0 or Move.final_attack(w, u, s, true) == 0:
				off = true
		else:
			if _picker_launcher(w, lid, 2) == 0 and wh != SMOKE_WARHEAD:
				off = true
			if Move.final_attack(w, u, s, false) == 0 and wh != SMOKE_WARHEAD:
				off = true
			var rad := _picker_launcher(w, lid, 9) & 7
			if (mode == 1 and rad != 0) or (mode == 5 and rad != 1):
				off = true
		var v := _picker_launcher(w, lid, 8) & 0x1F
		var cost := (v - 32 if v & 0x10 else v) * (2 if mode == 1 else 1)
		if w.sb(u, 0xE) < cost and not mode in [5, 10, 7]:
			off = true
		var kind := _picker_launcher(w, lid, 8) >> 5
		if kind == 3 or (kind != 0 and mode in [1, 5]) or (mode == 7 and kind == 2):
			off = true
		var cnt := w.slot_count(u, s)
		if not (_picker_launcher(w, lid, 9) & 8):
			mag_off[s] = true
		if cnt == 0:
			off = true
		elif _picker_launcher(w, lid, 0xB) == 0xFF:
			mag_off[s] = true
		elif w.ub(u, 0x1C + 2 * (w.ub(u, 0x10 + 2 * s) & 15)) >> 6 == 2:
			off = true
		if cnt == -1:
			mag_off[s] = true
		if w.slot_state(u, s) == 2:
			off = true
		if not off:
			out.append(s)
	for s in 4:
		if not mag_off.has(s):
			out.append(4 + s)
	return out


## The reaction loop's player branch (rules.player_reactions). choose.call(menu, t)
## returns 0 (mark t as reacted and stop), 1 or null (stop), or [unit, picks] with picks
## the picker answers (ending with a slot or -2). Returns the OR of the shot results.
static func player_reactions(w: Pd2World, rng: Pd2Random, reactors: Array, t: int, flag: int,
		choose: Callable, hooks: AiHooks = null, easy := false) -> int:
	if hooks == null:
		hooks = AiHooks.new()
	var result := 0
	while true:
		var menu := []
		for b in reactors:
			if not (w.ub(b, 0) & 0x40):
				menu.append(b)
		if menu.is_empty():
			break
		var pick: Variant = choose.call(menu, t)
		if pick == null or (pick is int and pick == 1):
			break
		if pick is int and pick == 0:
			w.setb(t, 0, w.ub(t, 0) | 0x40)
			break
		var b: int = pick[0]
		for item in pick[1]:
			if item == -2:
				break
			if item < 4:
				result |= reaction_shot(w, rng, b, item, t, flag, hooks, easy)
				break
		if result >= 4:
			break
	return result
