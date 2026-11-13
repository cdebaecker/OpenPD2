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
	var a := 0x506B39 + STATS_SIZE * i + off   # past the 26 records the game writes on
	if wide:
		var v := w.mem8(a) | w.mem8(a + 1) << 8
		if v < 0xFFFF:
			v += 1
		w.mem_write(a, v & 0xFF)
		w.mem_write(a + 1, v >> 8)
	elif w.mem8(a) < 0xFF:
		w.mem_write(a, w.mem8(a) + 1)


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
	var anims := hooks.anims
	var akind := w.launcher(w.launcher_id(s, slot), 9) >> 4       # 0x40F590: the record's kind
	if anims:
		hooks.anim_rec = [akind, sp.x, sp.y]             # (display: the direction players' sprite)
	var skipped := anims and anim_play(w, rng, hooks, 0x40F730) >= 0   # the shooter's (0x40F730)
	for p in pts:
		var tx: int = p.x
		var ty: int = p.y
		if w.H[tx + MAP * ty] - hs > 30:
			continue
		var blocked := 0
		if wh == SMOKE_WARHEAD:
			if anims and not skipped:
				skipped = anim_hit(w, rng, hooks, akind, tx, ty)
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
					blocked = Fire.intercept(w, rng, s, slot, o, choice, hooks)
				else:
					blocked = 1
				var terms := Fire.hit_terms(w, s, o, slot, mode, move)
				if terms.has("error"):
					w.fault = "division by zero (weapon range 0)"
					return 0
				var hit := Fire.roll_hit(rng, terms)
				if anims and (blocked == 0 or (blocked == 1 and not hit)):
					anim_miss(w, rng, hooks, akind, tx, ty)
				if blocked == 1 and hit:
					if anims and not skipped:
						skipped = anim_hit(w, rng, hooks, akind, tx, ty)
					count(w, s, 6, true)
					var dmg := Fire.fire_damage(w, rng, s, slot, o, mode, easy)
					if dmg and FIRE_GROW.has(mode):
						w.events.append(["grow", s, FIRE_GROW[mode], 1])
					if w.ub(o, 0xD) - dmg <= 0:
						if anims:
							anim_kill(w, rng, hooks, tx, ty)
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
		elif kind != 0 and kind != 3 and w.on_map(tx, ty):
			if not w.campaign and wh == MINE_WARHEAD:
				if not mine_at(w, tx, ty):
					lay_mine(w, tx, ty, side)
					blocked = 1
			elif anims and not skipped:
				skipped = anim_hit(w, rng, hooks, akind, tx, ty)
		if not w.campaign and not blocked and (wh < 3 or wh == MINE_WARHEAD) and mine_at(w, tx, ty):
			hooks.mine_blast(tx, ty)
			if anims and w.on_map(tx, ty):
				anim_bomb(w, rng, hooks, tx, ty)        # 0x473330 -> 0x417410
			w.F[tx + MAP * ty] &= 0x3F
			if o != -1 and w.unit_class(o) < 2:
				var dmg2 := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
				if anims and w.ub(o, 0xD) - dmg2 < 1:
					anim_kill(w, rng, hooks, tx, ty)
				if Fire.apply_hit(w, rng, o, dmg2, -1, 12, easy) == "destroyed":
					hooks.destroy(o)
	if shooter_dies:
		hooks.destroy(s)
	return 0


# --- the attacks' animations (option 0x10 clear): their effects (rules.anim_*, RULES.md 5.25)

const ANIM_TABLE := 0x512F40       # DS: 4 bytes per record kind (launcher +9 >> 4)
const ANIM_FRAMES := {0x40F730: 1, 0x4200D0: 6, 0x4206D0: 12, 0x4203D0: 6, 0x4209D0: 12, 0x419BE0: 6,
		0x419E20: 6, 0x4180C0: 8, 0x420CD0: 8, 0x417410: 14, 0x41CA70: 8}
const ANIM_JITTER := [0x4200D0, 0x4206D0, 0x4203D0, 0x4209D0]   # draw random(12) / random(3) a frame


## One player (rules._anim): frame by frame, the jitter drawn first for ANIM_JITTER's, then
## hooks.anim_frame (true: a click skipped there). The frame skipped at, or -1.
static func anim_play(w: Pd2World, rng: Pd2Random, hooks: Object, player: int, x := -1, y := -1) -> int:
	for i in int(ANIM_FRAMES[player]):
		var dy := 0
		var dx := 0
		if player in ANIM_JITTER:
			dy = rng.r16(12)
			dx = rng.r16(3)
		if hooks.call("anim_frame", player, x, y, i, dy, dx):
			return i
	return -1


static func _anim_ok(w: Pd2World, akind: int) -> bool:
	if akind < 0 or akind > 9:
		w.fault = "an animation kind past the table (launcher +9 >> 4 above 9)"
		return false
	return true


## 0x4101A0: true if skipped.
static func anim_hit(w: Pd2World, rng: Pd2Random, hooks: Object, akind: int, x: int, y: int) -> bool:
	if not _anim_ok(w, akind) or w.mem8(ANIM_TABLE + 4 * akind + 2) == 0xFF:
		return false
	if akind == 0 or akind == 1:
		if Strike._occupant(w, x, y) == -1:
			return false
		return anim_play(w, rng, hooks, 0x4200D0 if akind == 0 else 0x4206D0, x, y) >= 0
	return anim_play(w, rng, hooks, 0x419BE0 if akind < 9 else 0x4180C0, x, y) >= 0


## 0x4102A0 (its skip is not looked at).
static func anim_miss(w: Pd2World, rng: Pd2Random, hooks: Object, akind: int, x: int, y: int) -> void:
	if not _anim_ok(w, akind) or w.mem8(ANIM_TABLE + 4 * akind + 3) == 0xFF:
		return
	if akind in [0, 1, 2, 5]:
		if Strike._occupant(w, x, y) != -1:
			anim_play(w, rng, hooks, 0x4203D0 if akind == 0 else 0x4209D0, x, y)
	else:
		anim_play(w, rng, hooks, 0x419E20 if akind < 9 else 0x4180C0, x, y)


## 0x4103A0 with a unit on (x, y): 0x420CD0's frames, then clear_hex of its hex (skipped or not).
static func anim_kill(w: Pd2World, rng: Pd2Random, hooks: Object, x: int, y: int) -> void:
	var o := Strike._occupant(w, x, y)
	if o == -1:
		return
	anim_play(w, rng, hooks, 0x420CD0, x, y)
	var p := w.pos(o)
	anim_clear_hex(w, p.x, p.y)


## anime_bomb 0x417410 (from the mine blast 0x473330): its frames, then a unit there at
## condition 0 has the hex emptied (skipped or not).
static func anim_bomb(w: Pd2World, rng: Pd2Random, hooks: Object, x: int, y: int) -> void:
	anim_play(w, rng, hooks, 0x417410, x, y)
	var o := Strike._occupant(w, x, y)
	if o != -1 and w.ub(o, 0xD) == 0:
		anim_clear_hex(w, x, y)


## clear_hex (0x46ED80) less its redraw: on the map or its edge rows / columns.
static func anim_clear_hex(w: Pd2World, x: int, y: int) -> void:
	if w.on_map(x, y) or x == 0 or y == 0 or x == 0x47 or y == 0x47 or (y & 1 and x == 0x46):
		if x + MAP * y >= 0 and x + MAP * y < MAP * MAP:
			w.O[x + MAP * y] = 0


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
	if (w.on_map(op.x, op.y) or op.x == 0 or op.x == 71 or op.y == 0 or op.y == 71 or (op.y & 1 and op.x == 70)) 			and op.x + MAP * op.y >= 0 and op.x + MAP * op.y < MAP * MAP:   # (a striker's entry row 72)
		w.O[op.x + MAP * op.y] = 0
	var prev := 0
	if x + MAP * y >= 0 and x + MAP * y < MAP * MAP:
		prev = w.O[x + MAP * y]
		w.O[x + MAP * y] = (u + 1) & 0xFF   # (a hex on row 72: the game writes past the layer)
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
	if hooks.anims:                      # (rules.step_mine_blast: the start, anime_bomb, the kill's)
		anim_play(w, rng, hooks, 0x40F730, x, y)
		anim_bomb(w, rng, hooks, x, y)
	var res := 0
	var dmg := Fire.fire_damage(w, rng, -1, 12, u, 4, easy)
	if mmode == 0:
		Ai.spend_ap(w, u, 4)
	elif mmode == 1:
		Ai.spend_ap(w, u, 2)
	if w.ub(u, 0xD) - dmg <= 0:
		res = 1
		if hooks.anims:
			anim_kill(w, rng, hooks, x, y)
	if dmg and Fire.apply_hit(w, rng, u, dmg, -1, 12, easy) == "destroyed":
		hooks.destroy(u)
	toggle_mine(w, x, y, u)
	return res


## 0x4756A0: a mine found on a single step in careful mode. Outside the player's phase it
## is cleared for 4 AP; in it the player may clear it (4+ AP and the engineering skill)
## or shoot it (the slot's launcher AP and a round). Returns 2 when the mine is gone, else 0.
static func step_mine_found(w: Pd2World, u: int, hooks: AiHooks) -> int:
	var p := w.pos(u)
	if w.phase != 0:
		Ai.spend_ap(w, u, 4)
		toggle_mine(w, p.x, p.y, u)
		return 2
	if w.sb(u, 0xE) > 3 and (w.ucrew(u, 8) >> 1) & 1 and hooks.mine_clear(u, 0x1A3):
		Ai.spend_ap(w, u, 4)
		toggle_mine(w, p.x, p.y, u)
		return 2
	var picks: Variant = hooks.mine_shoot(u)
	if picks == null:
		return 0
	for item in picks:
		if item == -2:
			return 0
		if item < 4:
			Ai.spend_ap(w, u, Move.launcher_ap(w, w.launcher_id(u, item)))
			w.set_slot_count(u, item, w.slot_count(u, item) - 1)
			toggle_mine(w, p.x, p.y, u)
			return 2
	return 0


## 0x475AE0: one step into an adjacent hex. Returns the bits.
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
			if w.phase == 0:
				hooks.mine_found(u)
			res = step_mine_found(w, u, hooks)
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
				if w.phase == 0:
					hooks.mine_found(u)
				if w.sb(u, 0xE) >= 4 and (w.ucrew(u, 8) >> 1) & 1:
					if w.phase != 0:
						Ai.spend_ap(w, u, 4)
						toggle_mine(w, p.x, p.y, u)
						res = 2
					elif hooks.mine_clear(u, 0x1C9):   # the player is asked
						Ai.spend_ap(w, u, 4)
						toggle_mine(w, p.x, p.y, u)
						res = 1
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


# --- the player's search, conceal, carry and release (0x426B10 ... 0x427150) --------

static func search_cost(w: Pd2World, u: int) -> int:
	return 4 if w.ucrew(u, 8) & 1 else 8


## cmd_search (0x47F950 in mode 8), once confirmed: the spotted units, or null without AP.
## confirm(u), when valid, answers the 0x1C8 prompt (asked once the search map exists):
## false cancels (nothing searched, []).
static func player_search(w: Pd2World, u: int, confirm := Callable()) -> Variant:
	var cost := search_cost(w, u)
	if w.sb(u, 0xE) < cost:
		return null
	var up := w.pos(u)
	var g := up.x + MAP * up.y
	var h0 := w.H[g]
	var climb := w.unit_class(u) > 1
	if climb:
		w.H[g] = (h0 + 6) & 0xFF
	var spotted := []
	var rp := Sight.recon_range(w, u)
	var smap := Sight.search_map(w, up.x, up.y, rp.x, rp.y)
	if smap != null and confirm.is_valid() and not confirm.call(u):
		smap = null
	if smap != null:
		var side := 3 if w.is_enemy(u) else 0
		for ly in smap.h:
			for lx in smap.w:
				if smap.at(lx, ly) != 0xFF:
					Ai.set_view(w, smap.x0 + lx, smap.y0 + ly, side)
		spotted = Sight.spot_in_map(w, u, smap, 8)
		Ai.spend_ap(w, u, cost)
		w.setb(u, 4, w.ub(u, 4) | 0x30)
	if climb:
		w.H[g] = h0
	return spotted


## 一斉 entry 0 (0x429540 -> 0x4837A0(2)): with the campaign flag F bit 5 cleared on the
## map; every active unit 0-253 whose status (clamped to 3) is the phase's side, with
## search_cost AP, searches as cmd_search (its 0x1C8 prompt answered by confirm). No
## sensors. The units spotted, in order.
static func all_search(w: Pd2World, confirm := Callable(), phase := 0) -> Array:
	if w.campaign:
		for y in MAP:
			for x in MAP:
				if w.on_map(x, y):
					w.F[x + MAP * y] &= 0xDF
	var out := []
	for u in mini(254, w.n_units):
		var st := w.sb(u, 0x36)
		if (3 if st > 2 else st) != phase or not w.active(u):
			continue
		if search_cost(w, u) <= w.sb(u, 0xE):
			out.append_array(player_search(w, u, confirm))
	return out


static func _conceal_asked(w: Pd2World, u: int) -> bool:
	if w.ub(u, 0x36) != 0 or not w.active(u):
		return false
	var cost := 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
	return cost <= w.sb(u, 0xE) and not w.ub(u, 0) & 0x20


## 一斉 entry 1 (0x429540): the units asked WMES 0x1B0, in order (0-39, status 0, active,
## the conceal cost in AP, not concealed).
static func all_conceal_units(w: Pd2World) -> Array:
	var out := []
	for u in 40:
		if _conceal_asked(w, u):
			out.append(u)
	return out


## 一斉 entry 1: each unit as it comes (checked at its turn); answer(u) == 0 conceals it
## (+0 | 0x20, the cost paid). The units concealed.
static func all_conceal(w: Pd2World, answer: Callable) -> Array:
	var out := []
	for u in 40:
		if _conceal_asked(w, u) and int(answer.call(u)) == 0:
			w.setb(u, 0, w.ub(u, 0) | 0x20)
			Ai.spend_ap(w, u, 3 if (w.ucrew(u, 8) >> 3) & 1 else 6)
			out.append(u)
	return out


## cmd_conceal's refusals: 0x1AF (already concealed), "ap", or "" when it may conceal.
static func conceal_check(w: Pd2World, u: int) -> Variant:
	if w.ub(u, 0) & 0x20:
		return 0x1AF
	var cost := 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
	if w.sb(u, 0xE) < cost:
		return "ap"
	return ""


static func carry_cost(w: Pd2World, u: int) -> int:
	return 4 if (w.ucrew(u, 8) >> 1) & 1 else 8


## cmd_carry: [[Vector3i(x, y, unit)...], refusal ("" / "ap" / message id)].
static func carry_candidates(w: Pd2World, u: int) -> Array:
	if Ai.manipulator_state(w, u) == 2:
		return [[], 0x1DD]
	if w.sb(u, 0xE) < carry_cost(w, u):
		return [[], "ap"]
	if w.unit_class(u) >= 2:
		return [[], 0x212]
	var up := w.pos(u)
	var h0 := w.H[up.x + MAP * up.y]
	var out := []
	for d in 6:
		var o2: Vector2i = NB[up.y & 1][d]
		var x := up.x + o2.x
		var y := up.y + o2.y
		var o := w.O[x + MAP * y] - 1
		if o != -1 and w.unit_class(o) == 0 and w.sb(o, 0x36) == 0 and absi(h0 - w.H[x + MAP * y]) < 2:
			out.append(Vector3i(x, y, o))
	return [out, "" if not out.is_empty() else 0x1B3]


## u picks up o: -1 done, 0x1B4 when o carries a unit itself.
static func player_carry(w: Pd2World, u: int, o: int) -> int:
	if w.ub(o, 0x34) != 0xFF:
		return 0x1B4
	w.setb(u, 0x34, o)
	w.O[w.sb(o, 9) + MAP * w.sb(o, 10)] = 0
	w.setb(o, 9, 0xFF)
	w.setb(o, 10, 0xFF)
	Ai.spend_ap(w, u, carry_cost(w, u))
	return -1


## cmd_release: [[Vector2i...], refusal].
static func release_candidates(w: Pd2World, u: int) -> Array:
	if w.sb(u, 0xE) < 2:
		return [[], "ap"]
	var up := w.pos(u)
	var cat := w.umachine(u, 0) & 15
	var h0 := w.H[up.x + MAP * up.y]
	var out := []
	for d in 6:
		var o2: Vector2i = NB[up.y & 1][d]
		var x := up.x + o2.x
		var y := up.y + o2.y
		if (w.terrain[Move.S_MOVE_ROWS + 16 * cat + w.terrain[w.T[x + MAP * y]]] != 0
				and w.O[x + MAP * y] == 0 and absi(h0 - w.H[x + MAP * y]) < 2):
			out.append(Vector2i(x, y))
	return [out, "" if not out.is_empty() else 0x1B1]


static func player_release(w: Pd2World, u: int, x: int, y: int) -> void:
	var o := w.ub(u, 0x34)
	w.setb(o, 9, x)
	w.setb(o, 10, y)
	if Ai.in_view(w, x, y, 3):
		w.setb(o, 0, w.ub(o, 0) | 0x10)
	else:
		w.setb(o, 0, w.ub(o, 0) & 0xEF)
	w.setb(o, 0, w.ub(o, 0) & 0xDF)
	w.setb(u, 0x34, 0xFF)
	w.O[x + MAP * y] = (o + 1) & 0xFF
	Ai.spend_ap(w, u, 2)


# --- the player's move command (unit_command_menu 0x4EE8D0, entries 0-2) ---------------

## Why u cannot move: 0x1DA (manipulators broken while carrying), 0x1DB (movement gear
## broken), or -1.
static func move_refusal(w: Pd2World, u: int) -> int:
	if Ai.manipulator_state(w, u) == 2 and w.ub(u, 0x34) != 0xFF:
		return 0x1DA
	if w.ub(u, 1) & 0x0C == 8 or w.ub(u, 1) & 0x30 == 0x20:
		return 0x1DB
	return -1


## 0x47D780: AP left, not destroyed, movement gear not broken.
static func can_move(w: Pd2World, u: int) -> bool:
	var g := w.ub(u, 1)
	return w.ub(u, 0xE) != 0 and w.ub(u, 0xD) != 0 and (g >> 2) & 3 != 2 and (g >> 4) & 3 != 2


## 0x47CED0(map, 1): the hexes that take a click: reachable, and (except for wheeled /
## tracked machines, category 2-5) not held by a unit of u's side.
static func move_destinations(w: Pd2World, u: int, mm: Move.MoveMap) -> Array:
	var cat := w.machine(w.ub(u, 0xC), 0) & 15
	var kind := 2 if cat == 9 else (1 if cat >= 2 and cat <= 5 else 0)
	if w.ub(u, 0xC) == 12:
		kind = 2
	var side := w.is_enemy(u)
	var out := []
	for ly in mm.h:
		for lx in mm.w:
			if mm.cells[ly * mm.w + lx] == 0xFF:
				continue
			var x := mm.x0 + lx
			var y := mm.y0 + ly
			if kind != 1:
				var o := w.O[x + MAP * y] - 1 if w.on_map(x, y) else -1
				if o != -1 and w.is_enemy(o) == side:
					continue
			out.append(Vector2i(x, y))
	return out


## What a click on (x, y) does: ["walk" | "melee" | "path" | "", the AP shown, the unit there].
static func move_click(w: Pd2World, u: int, x: int, y: int, mm: Move.MoveMap) -> Array:
	var up := w.pos(u)
	var cls := w.unit_class(u)
	var o := w.O[x + MAP * y] - 1
	var cost := mm.cell(x, y) & 0x7F
	var spotted := o != -1 and w.ub(o, 0) & 0x10
	if Pd2World.hexdist(x, y, up.x, up.y) == 1 and (absi(w.H[x + MAP * y] - w.H[up.x + MAP * up.y]) < 2 or cls >= 2):
		return ["walk" if not spotted or cls == 3 else "melee", cost, o]
	return ["" if spotted else "path", cost, o]


## One click of the move command on a hex of move_destinations: [kind, result]; result
## null when the prompt was declined or nothing happens. Melee results: 0 the defender
## is destroyed and u walks in, 1 u pays the hex's AP, 2 u destroyed, 3 both.
static func player_move(w: Pd2World, rng: Pd2Random, u: int, x: int, y: int, mode: int, mm: Move.MoveMap, hooks: AiHooks, easy := false, alert := 0) -> Array:
	var mc := move_click(w, u, x, y, mm)
	var kind: String = mc[0]
	var cost: int = mc[1]
	var o: int = mc[2]
	if kind == "walk":
		return [kind, ai_walk(w, rng, u, x, y, mode, mm, hooks, easy)]
	if kind == "":
		return [null, null]
	var args := [cost] if kind == "melee" else [cost, w.sb(u, 0xE), w.cover_at(w.unit_class(u), x, y)]
	if not hooks.confirm(0x1E4 if kind == "melee" else 0x1DC, args):
		return [kind, null]
	if kind == "path":
		return [kind, ai_path(w, rng, u, x, y, mode, mm, hooks, easy)]
	var res := Melee.melee(w, rng, u, o, alert, easy, hooks.use_weapon)
	if w.fault != "":
		return [kind, null]
	if res == 0:
		hooks.destroy(o)
		ai_walk(w, rng, u, x, y, mode, mm, hooks, easy)
		hooks.melee_done()
	elif res == 1:
		Ai.spend_ap(w, u, cost)
	else:
		hooks.destroy(u)
		if res == 3:
			hooks.destroy(o)
		hooks.melee_done()
	return [kind, res]


# --- unit removal (destroy 0x480140; rules.destroy, emulated) ---------------------------

## 0x46ED80: empty a hex's occupancy (on the map, or on its edge rows / columns).
static func clear_hex(w: Pd2World, x: int, y: int) -> void:
	if (w.on_map(x, y) or x == 0 or x == 71 or y == 0 or y == 71 or (y & 1 and x == 70)) 			and x + MAP * y >= 0 and x + MAP * y < MAP * MAP:   # (row 72: the game writes past the layer)
		w.O[x + MAP * y] = 0


## 0x47FEE0: k leaves the map: its hex emptied, a carried unit put down there (not
## concealed), the status reset to its crew's (+2); then x = y = -1.
static func take_off_map(w: Pd2World, k: int) -> void:
	var p := w.pos(k)
	if w.on_map(p.x, p.y):
		clear_hex(w, p.x, p.y)
		var c := w.ub(k, 0x34)
		if c != 0xFF:
			w.setb(c, 9, w.ub(k, 9))
			w.setb(c, 10, w.ub(k, 10))
			w.setb(c, 0, w.ub(c, 0) & 0xDF)
			w.O[p.x + MAP * p.y] = (c + 1) & 0xFF
			w.setb(k, 0x34, 0xFF)
		var st := w.mem8(0x506734 + 16 * w.sb(k, 0xB) + 2)   # (a crew number below 0 reads the stock before the table)
		if st != w.ub(k, 0x36):
			w.setb(k, 0x36, st)
	w.setb(k, 9, 0xFF)
	w.setb(k, 10, 0xFF)


## crew c (signed, as the game indexes: outside 0-63 another table's byte) gets +5 = 0xFF
static func _crew_pool_add(w: Pd2World, c: int) -> void:
	if c < 0 or c * Pd2World.CREW >= w.crew.size():
		w.mem_write(0x506734 + Pd2World.CREW * c + 5, 0xFF)
	else:
		w.crew[c * Pd2World.CREW + 5] = 0xFF
	w.pool_set(w.crew_pool_n, c)
	w.crew_pool_n += 1


## 0x4549B0: take k out of player group g (rules.group_drop_player): 0 removed, 1 not listed.
static func group_drop_player(w: Pd2World, g: int, k: int) -> int:
	var G := g * 35
	var c := w.sb(k, 0xB)
	var camp := w.campaign != 0
	if camp and w.crew_pool_n > 0x40:
		w.crew_pool_n = 0
		for i in 64:
			var q := i * Pd2World.CREW
			if w.crew[q + 4] <= w.time_ad92 and w.crew[q + 2] <= 2 and w.crew[q + 5] == 0xFF and not (w.crew[q + 6] & 3):
				w.pool_set(w.crew_pool_n, i)
				w.crew_pool_n += 1
	var limit := 0x1C if camp else 0x1B
	var n := w.groups[G + 5]
	for i in n:
		var by_crew := c < limit
		if w.groups[G + 6 + i] != (c if by_crew else k):
			continue
		for j in range(i, n - 1):
			w.groups[G + 6 + j] = w.groups[G + 7 + j]
		n = (n - 1) & 0xFF
		w.groups[G + 5] = n
		if n < 16:
			for j in range(n, 16):
				w.groups[G + 6 + j] = 0xFF
		if camp and not by_crew and w.mode_663a:
			return 0
		_crew_pool_add(w, c)
		return 0
	return 1


## 0x441F40: take k out of computer group g (rules.group_drop).
static func group_drop(w: Pd2World, g: int, k: int) -> void:
	if g < 20:
		group_drop_player(w, g, k)
		return
	var G := g * 35
	for i in 16:
		if w.groups[G + 6 + i] == k:
			take_off_map(w, k)
			w.groups[G + 6 + i] = 0xFF
			w.groups[G + 5] = (w.groups[G + 5] - 1) & 0xFF
			return


## 0x480140: k is destroyed (rules.destroy): flag bit 0, condition 0, off the map, a
## player unit's weapons and pockets cleared, and its group drops it.
static func destroy(w: Pd2World, k: int) -> void:
	w.setb(k, 0, w.ub(k, 0) | 1)
	w.setb(k, 0xD, 0)
	take_off_map(w, k)
	if w.ub(k, 0x36) == 0:
		for i in 6:
			w.setb(k, 0xF + 2 * i, 0xFF)
		for i in 12:
			w.setb(k, 0x1B + 2 * i, 0xFF)
	var st := w.sb(k, 0x36)
	for g in 64:
		var G := g * 35
		if w.groups[G + 5] and w.groups[G + 2] & 0x30:
			var listed := false
			for i in 16:
				if w.groups[G + 6 + i] == k:
					listed = true
					break
			if listed:
				if st <= 2:
					group_drop_player(w, g, k)
				else:
					group_drop(w, g, k)
				return
