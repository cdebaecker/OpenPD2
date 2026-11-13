class_name Strike
extends RefCounted
## The fire-support strike executor (Pd2.exe 0x4E37A0, rules.strike_executor): the
## orders the AI's fire support and the player's support calls leave on group members
## (+6 order, +7 / +8 aim, +0x35 slot) carried out for one side, the counter-battery
## answers (0x4E2CF0), the fly-in of type 3 / 4 groups (0x4E4A40 / 0x4E4B00 / 0x4E4560)
## and the group update. See RULES.md 5.13.

const W := preload("res://core/world.gd")
const MAP := 72
const ABORT := [0x10000, 0x20000, 0x40000]


## What the executor leaves to the game (display and player input).
class Hooks extends RefCounted:
	## The reaction fire a striker flying in draws (reaction_loop 0x472920, flag 10):
	## the loop's result bits (>= 4: u was destroyed) or an abort code. easy: the game's
	## easy-mode bit is forced on (DS:0x551D29 bit 1, a leaving reinforcement).
	func react(u: int, cands: Array, easy := false) -> int:
		return 0

	## Radio chatter (0x4896C0): 0 or an abort code.
	func radio(kind: int, g: int) -> int:
		return 0

	## A message line (0x205-0x208, 0x20B with ["sign", n]).
	func line(msg: int, args: Array = []) -> void:
		pass

	## The counter-battery questions (0x203 / 0x204): 1 for yes.
	func ask(msg: int) -> int:
		return 0

	## The counter-battery unit picker (0x4E3230): one of units, or -1.
	func cb_pick(units: Array) -> int:
		return -1

	## The weapon picker (0x4E0450): a slot, or -2.
	func cb_slot(u: int, g: int) -> int:
		return -2

	## the group struck (counter_battery's g): the weapon picker measures its range to it
	var cb_target := -1

	## The unit panel shown for a striker (0x466790).
	func panel(u: int) -> void:
		pass

	func mine_blast(x: int, y: int) -> void:
		pass

	## The player's interception choice (as AiHooks): a slot or -1.
	func intercept_choice(t: int, best: int) -> int:
		return -1

	## The animations play (option 0x10 clear): a strike's (Action.anim_*)
	var anims := false
	var anim_rec: Array = []      # [kind, x, y] of the record (display)

	## An animation player's frame (as AiHooks.anim_frame): true when a click skipped it.
	func anim_frame(player: int, x: int, y: int, i: int, dy: int, dx: int) -> bool:
		return false


# --- the player's support request (cmd_support_request 0x4DF680, rules.support_request) ----

const SUPPORT_STATE_TEXTS := [0x51F3B8, 0x51F3C0, 0x51F3C8, 0x51F3D0]   # SHIFT, BUSY, SUPPORT, STAND BY


## The support request's windows (rules.SupportHooks).
class SupportHooks extends RefCounted:
	## a message line (0x1C3: nobody can support)
	func line(msg: int) -> void:
		pass

	## the unit picker (0x4DFE70's list): an index of a row not of state 1, or -2
	func pick(rows: Array) -> int:
		return -2

	## ui_prompt_at_cursor (0x1C2): 0 for its first choice
	func prompt(msg: int) -> int:
		return 1

	## the weapon picker 0x4E0450(k, g, 0): a slot, or -2
	func slot(k: int, g: int) -> int:
		return -2

	## ui_map_click mode 2: Vector2i of a hex, or null (a right click)
	func click(k: int, s: int, kind: int, radius: int) -> Variant:
		return null

	## ui_message_box (0x201 / 0x202): 1 for yes
	func box(msg: int) -> int:
		return 0


## 12 AP, 6 with crew +8 bit 2.
static func support_cost(w: Pd2World, u: int) -> int:
	return 6 if (w.ucrew(u, 8) >> 2) & 1 else 12


static func _ubyte(w: Pd2World, k: int, f: int) -> int:
	## units[k] + f as the game reads it (k = -1: the 55 bytes before the table)
	return w.mem8(0x506C93 + 55 * k + f)


## 0x4DFE70's rows: [unit, state (0 may be picked, 1 refused, 2 asks 0x1C2), the state's
## text address, its colour] for the members of groups 0-19 (rules.support_units).
static func support_units(w: Pd2World) -> Array:
	var out := []
	for g in 20:
		if gb(w, g, 22) == 0xFF or gb(w, g, 2) & 0x30 != 0x20:
			continue
		var t := gb(w, g, 33) & 0xF0
		if t != 0x30 and t != 0x40 and t != 0x50:
			continue
		var other := 0
		if t != 0x50:
			for j in range(20, 64):
				var tj := gb(w, j, 33) & 0xF0
				if gb(w, j, 22) != 0xFF and (tj == 0x30 or tj == 0x40) 						and gb(w, j, 22) == gb(w, g, 22) and gb(w, j, 23) == gb(w, g, 23):
					other = j
		for i in 16:
			var k := gb(w, g, 6 + i)
			if k == 0xFF or _ubyte(w, k, 0) & 1:
				continue
			var fl := gb(w, g, 2) & 0xC0
			var row: Array
			if fl == 0:
				if other:
					row = [k, 1, SUPPORT_STATE_TEXTS[1], 0x4F]
				elif _ubyte(w, k, 6) == 1 or _ubyte(w, k, 6) == 2:
					row = [k, 1, SUPPORT_STATE_TEXTS[2], 0x4F]
				else:
					row = [k, 0, SUPPORT_STATE_TEXTS[3], 0xFF]
			elif fl == 0x40:
				row = [k, 2, SUPPORT_STATE_TEXTS[0], 0xFF] if t == 0x50 else [k, 1, SUPPORT_STATE_TEXTS[0], 0x4F]
			else:
				row = [k, 1, SUPPORT_STATE_TEXTS[1], 0x4F]
			out.append(row)
	return out


static func _active_any(w: Pd2World, k: int) -> bool:
	var f := _ubyte(w, k, 0)
	return w.on_map(Pd2World.s8(_ubyte(w, k, 9)), Pd2World.s8(_ubyte(w, k, 10))) and f & 8 != 0 			and _ubyte(w, k, 0xD) != 0 and f & 1 == 0 and f & 4 != 0


## cmd_support_request (0x4DF680) for unit u: "ap" when short of support_cost, else the
## orders given [[member, slot, x, y]] (rules.support_request; RULES.md 5.24).
static func support_request(w: Pd2World, u: int, hooks: SupportHooks) -> Variant:
	var cost := support_cost(w, u)
	if w.sb(u, 0xE) < cost:
		return "ap"
	var orders := []
	while true:
		var rows := support_units(w)
		if rows.is_empty():
			hooks.line(0x1C3)
			return orders
		var i := hooks.pick(rows)
		if i == -2:
			return orders
		var k: int = rows[i][0]
		var st: int = rows[i][1]
		if st == 1:
			w.fault = "support_request: a refused row picked"
			return orders
		var g := Ai.unit_group(w, k)
		if g < 0:
			w.fault = "support_request: a member outside any group (the game writes groups[-1])"
			return orders
		var go := st == 0
		if st == 2 and hooks.prompt(0x1C2) == 0:
			setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
			go = true
		if go:
			var s := hooks.slot(k, g)
			if s != -2:
				var lid := w.launcher_id(k, s)
				if lid == -1:
					w.fault = "support_request: an empty slot picked (0x4E0450 refuses it)"
					return orders
				var kind := w.launcher(lid, 8) >> 5
				var radius := w.launcher(lid, 9) & 7
				while true:
					var c: Variant = hooks.click(k, s, kind, radius)
					if c == null:
						break
					var x: int = c.x
					var y: int = c.y
					var o := _occupant(w, x, y)
					var ok := false
					if kind == 2:
						if Pd2World.s8(_ubyte(w, o, 0x36)) > 2 and _active_any(w, o) and hooks.box(0x201) == 1:
							w.setb(k, 7, 0xFF)
							w.setb(k, 8, o & 0xFF)
							setgb(w, g, 24, gb(w, g, 22))
							setgb(w, g, 25, gb(w, g, 23))
							ok = true
					elif hooks.box(0x202) == 1:
						w.setb(k, 7, x & 0xFF)
						w.setb(k, 8, y & 0xFF)
						var gt := gb(w, g, 33) & 0xF0
						if gt == 0x30 or gt == 0x40:
							setgb(w, g, 33, (gb(w, g, 33) & 0xF) | 0x30)
							Ai.group_retarget(w, g, w.ds8(0x50AD95), w.ds8(0x50AD97))
							setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
						ok = true
					if ok:
						w.setb(k, 6, 1)
						w.setb(k, 0x35, s)
						Ai.spend_ap(w, u, cost)
						Ai.mark_strike(w, x, y, k, s)
						orders.append([k, s, x, y])
						break
		if w.sb(u, 0xE) < cost:
			return orders
	return orders


static func gb(w: Pd2World, g: int, f: int) -> int:
	return w.groups[35 * g + f]


static func setgb(w: Pd2World, g: int, f: int, v: int) -> void:
	w.groups[35 * g + f] = v & 0xFF


## 0x47E130: a strike's hexes: (x, y), then the rest of its spiral shuffled.
static func area(w: Pd2World, rng: Pd2Random, x: int, y: int, r: int) -> Array:
	var a := Ai.spiral(x, y, r)
	var n := a.size()
	if n <= 2:
		return [Vector2i(x, y)]
	var b := [a[n - 1]] + a.slice(1, n - 1)
	var out := [Vector2i(x, y)]
	var i := n - 2
	while i:
		var k := rng.r16(i)
		out.append(b[k])
		b[k] = b[i]
		i -= 1
	out.append(b[0])
	return out


## 0x4DF3D0: a strike's hit roll (mode 9; no base, height, aim or range terms).
static func hit(w: Pd2World, rng: Pd2Random, s: int, t: int, slot: int) -> int:
	var T := Fire.hit_terms(w, s, t, slot, 9, -1, false, false)
	var e: int = T.effectiveness
	if e == 1:
		return 0
	if e == 2:
		return 98 if rng.r16(100) < 98 else 0
	var c: int = ((T.skill - T.cover - T.defense + T.posture + T.accuracy) * 10) / e
	c = 98 if c >= 99 else maxi(15, c)
	return c if rng.r16(100) < c else 0


## 0x4E2300: a type 3 / 4 group's order-2 damage.
static func damage(w: Pd2World, s: int, slot: int, t: int) -> int:
	var ga := Move.final_attack(w, s, slot, false)
	return ((100 - w.umachine(t, 4)) * ga) / 100


static func _occupant(w: Pd2World, x: int, y: int) -> int:
	if x < 0 or x >= MAP or y < 0 or y >= MAP:
		return -1
	return w.O[x + MAP * y] - 1


## 0x4E1A90: s's strike with slot `slot` at (x, y), over `pts` or the single hex.
static func fire(w: Pd2World, rng: Pd2Random, s: int, slot: int, x: int, y: int, pts: Variant, hooks: Hooks, easy := false) -> int:
	var anims := hooks.anims
	var akind := w.launcher(w.launcher_id(s, slot), 9) >> 4
	if anims:
		hooks.anim_rec = [akind, w.pos(s).x, w.pos(s).y]   # (display)
	var skipped := anims and Action.anim_play(w, rng, hooks, 0x40F730, x, y) >= 0
	var wh := w.warhead(s, slot)
	w.events.append(["grow", s, "ATTACK", 1])
	Action.count(w, s, 4, true)
	var side := 0 if w.sb(s, 0x36) < 3 else 3
	var kind := w.launcher(w.launcher_id(s, slot), 8) >> 5
	var choice := Callable(hooks, "intercept_choice")
	var hexes: Array = pts if pts != null else [Vector2i(x, y)]
	for p in hexes:
		var tx: int = p.x
		var ty: int = p.y
		var o := _occupant(w, tx, ty)
		var laid := false
		if wh == Action.SMOKE_WARHEAD:
			if anims and not skipped:
				skipped = Action.anim_hit(w, rng, hooks, akind, tx, ty)
			if w.on_map(tx, ty):
				w.F[tx + MAP * ty] |= 1
			continue
		if o == -1:
			if w.on_map(tx, ty):
				if not w.campaign and wh == Action.MINE_WARHEAD:
					if not Action.mine_at(w, tx, ty):
						Action.lay_mine(w, tx, ty, side)
						laid = true
				elif anims and not skipped:
					skipped = Action.anim_hit(w, rng, hooks, akind, tx, ty)
		else:
			var res := Fire.intercept(w, rng, s, slot, o, choice, hooks) if kind == Fire.MISSILE_KIND else Fire.NOT_STOPPED
			var h := hit(w, rng, s, o, slot)
			if anims and (res == Fire.DECOYED or (res == Fire.NOT_STOPPED and not h)):
				Action.anim_miss(w, rng, hooks, akind, tx, ty)
			if res == Fire.NOT_STOPPED and h:
				if anims and not skipped:
					skipped = Action.anim_hit(w, rng, hooks, akind, tx, ty)
				Action.count(w, s, 6, true)
				var dmg := Fire.fire_damage(w, rng, s, slot, o, 9, easy)
				if dmg:
					w.events.append(["grow", s, "ATTACK", 1])
					if w.ub(o, 0xD) - dmg < 1:
						if anims:
							Action.anim_kill(w, rng, hooks, tx, ty)
						Melee.kill_credit(w, s, o)
					if Fire.apply_hit(w, rng, o, dmg, s, slot, easy) == "destroyed" and o != s:
						Action.destroy(w, o)
			else:
				w.events.append(["grow", o, "DEF", 1])
		if not w.campaign and not laid and (wh < 3 or wh == Action.MINE_WARHEAD) and tx + MAP * ty >= 0 \
				and Action.mine_at(w, tx, ty):
			hooks.mine_blast(tx, ty)
			if anims and w.on_map(tx, ty):
				Action.anim_bomb(w, rng, hooks, tx, ty)
			w.F[tx + MAP * ty] &= 0x3F
			if o != -1 and w.unit_class(o) < 2:
				var dmg2 := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
				if anims and w.ub(o, 0xD) - dmg2 < 1:
					Action.anim_kill(w, rng, hooks, tx, ty)
				if Fire.apply_hit(w, rng, o, dmg2, -1, 12, easy) == "destroyed":
					Action.destroy(w, o)
		if w.campaign:
			continue
		for i in 40:
			if w.memory[3 * i + 2] == 0xFF:
				continue
			if w.active(i):
				var m := Ai.mem(w, i)
				if m.x != tx or m.y != ty or w.pos(i) == m or rng.r16(100) > 0x31:
					continue
				w.memory[3 * i + 2] = 0xFF
			w.memory[3 * i] = 0xFF
			w.memory[3 * i + 1] = 0xFF
	return 0


## 0x47E380: the side (0-7) a strike on (x1, y1) flies in from, for a group last at (x2, y2).
static func direction(x1: int, y1: int, x2: int, y2: int) -> int:
	var dx := x1 - x2
	var dy := y1 - y2
	var adx := absi(dx)
	var ady := absi(dy)
	if dx == 0 and dy == 0:
		return 0
	var d := 0
	if ady < adx:
		if (10 * ady) / adx < 6:
			d = 7 if dx >= 0 else 3
	elif ((10 * adx) / ady if ady else 0) < 6:
		d = 1 if dy >= 0 else 5
	if d == 0:
		if dx < 0:
			return 2 if dy >= 0 else 4
		d = 0 if dy >= 0 else 6
	return d


## 0x4E2A60(d): the first hex and the edge hex a striker from side d enters by:
## [a, b, px, py].
static func entry(rng: Pd2Random, d: int) -> Array:
	var e: Array
	match d:
		0:
			e = _top(rng.r16(18) + 1) if rng.r16(100) > 0x31 else _left(rng.r16(18) + 1)
		1:
			e = _top(rng.r16(36) + 18)
		2:
			e = _top(70 - rng.r16(18)) if rng.r16(100) < 0x32 else _right(rng.r16(18) + 1)
		3:
			e = _right(rng.r16(36) + 18)
		4:
			e = _bottom(71 - rng.r16(18)) if rng.r16(100) < 0x32 else _right(72 - rng.r16(18))
		5:
			e = _bottom(rng.r16(36) + 18)
		6:
			e = _bottom(rng.r16(18) + 1) if rng.r16(100) < 0x32 else _left(71 - rng.r16(18))
		_:
			e = _left(rng.r16(36) + 18)
	var a := maxi(e[0], 1)
	var b := maxi(e[1], 1)
	if b > 69:
		b = 70
	a = mini(a, 70 - (b & 1))
	return [a, b, e[2], e[3]]


static func _top(a: int) -> Array:
	return [a, 1, a, 0]


static func _left(b: int) -> Array:
	return [1, b, 0, b]


static func _bottom(a: int) -> Array:
	return [a, 70, a, 71]


static func _right(v: int) -> Array:
	return [70 - (v & 1), v, 71 - (v & 1), v]


## 0x480CD0: the hexes from (x1, y1) to (x2, y2), the start included.
static func path(w: Pd2World, x1: int, y1: int, x2: int, y2: int) -> Array:
	var n := W.hexdist(x1, y1, x2, y2)
	var out := [Vector2i(x1, y1)]
	var last := Vector2i(x1, y1)
	var i := 1
	while true:
		var P := Sight.line_point((y1 & 1) + 2 * x1, y1, (y2 & 1) + 2 * x2, y2, i)
		var x := (P.x + (P.x & ~P.y & 1)) >> 1
		var y := P.y
		if x == x2 and y == y2:
			out.append(Vector2i(x, y))
			break
		if not w.on_map(x, y):
			if y == 0:
				y = 1
			elif y == 71:
				y = 70
			if x == 0:
				x = 1
			else:
				x = mini(x, 70 - (y & 1))
		if n < out.size():
			break
		if Vector2i(x, y) != last:
			out.append(Vector2i(x, y))
			last = Vector2i(x, y)
		i += 1
	return out


static func _put_back(w: Pd2World, check_unit: bool) -> void:
	var k: int = w.strike_saved[0]
	var x: int = w.strike_saved[1]
	var y: int = w.strike_saved[2]
	w.setb(k, 9, x)
	w.setb(k, 10, y)
	w.O[x + MAP * y] = (k + 1) & 0xFF
	if w.sb(k, 0x36) > 2 and (k < 0xFE or not check_unit) and Ai.in_view(w, x, y, 0):
		w.setb(k, 0, w.ub(k, 0) | 0x10)


## 0x4E4560: one step of a striker flying in (mode 1: the displaced unit goes back).
static func move(w: Pd2World, rng: Pd2Random, x: int, y: int, u: int, mode: int, hooks: Hooks) -> int:
	if mode == 1:
		if w.strike_saved[0] == -1:
			return 0
		_put_back(w, true)
		w.strike_saved[0] = -1
		return 0
	var res := 0
	if w.pos(u) != Vector2i(x, y):
		var prev := Action.move_unit(w, u, x, y)
		w.setb(u, 4, w.ub(u, 4) & 0xCF)
		if w.strike_saved[0] != -1:
			_put_back(w, false)
			w.strike_saved = [-1, 0, 0]
		if prev != -1:
			w.strike_saved = [prev, x, y]
		w.setb(u, 0, (w.ub(u, 0) | 0x10) & 0xDF)
		if w.ub(u, 0) & 0x10 and not w.ub(u, 0) & 0x40:
			var cands := Sight.reaction_candidates(w, u, w.ds8(0x50ADF1))
			if not cands.is_empty():
				res = hooks.react(u, cands, false)
				if res in ABORT:
					return res
	if res < 4:
		return 0
	move(w, rng, 0, 0, u, 1, hooks)
	return 2


## 0x4E4B00: u flies toward its aim until within the slot's range.
static func fly(w: Pd2World, rng: Pd2Random, u: int, slot: int, hooks: Hooks) -> int:
	var dx := w.ub(u, 7)
	var dy := w.ub(u, 8)
	var rr := w.weapon_range(u, slot) & 0xFF
	var p := w.pos(u)
	var pts := path(w, p.x, p.y, dx, dy)
	w.setb(u, 0, w.ub(u, 0) & 0xCF)
	var res := 0
	var i := 0
	while i < pts.size() and pts[i].x != -1 and res == 0:   # (x = -1 ends the game's list)
		res = move(w, rng, pts[i].x, pts[i].y, u, 0, hooks)
		if res in ABORT:
			return res
		if W.hexdist(dx, dy, pts[i].x, pts[i].y) <= rr:
			res = 1
		i += 1
	if res == 2:
		var q: Vector2i = pts[i] if i < pts.size() else Vector2i(-1, -1)
		var a := move(w, rng, q.x, q.y, u, 1, hooks)
		if a in ABORT:
			return a
	return res


## 0x4E4A40: a type 3 / 4 group's striker enters the map and flies in.
static func fly_in(w: Pd2World, rng: Pd2Random, u: int, slot: int, g: int, hooks: Hooks) -> int:
	var d := direction(w.fire_point.x, w.fire_point.y, W.s8(gb(w, g, 0x18)), W.s8(gb(w, g, 0x19)))
	var e := entry(rng, d)
	w.setb(u, 9, e[2])
	w.setb(u, 10, e[3])
	var res := move(w, rng, e[0], e[1], u, 2, hooks)
	if res in ABORT:
		return res
	return fly(w, rng, u, slot, hooks)


## 0x4E3730: no positioned group on (x, y) has a member of side.
static func _no_side_at(w: Pd2World, side: int, x: int, y: int) -> bool:
	for g in 64:
		if gb(w, g, 0x16) != 0xFF and W.s8(gb(w, g, 0x16)) == x and W.s8(gb(w, g, 0x17)) == y:
			for i in 16:
				var k := gb(w, g, 6 + i)
				if k != 0xFF and w.sb(k, 0x36) >= side and w.sb(k, 0x36) <= side + 2:
					return false
	return true


## 0x4E2CF0(side, striker, g): the other side's support answers a strike.
static func counter_battery(w: Pd2World, rng: Pd2Random, side: int, striker: int, g: int, hooks: Hooks) -> int:
	var sx := W.s8(gb(w, g, 0x16))
	var sy := W.s8(gb(w, g, 0x17))
	var cands := []
	for gi in 64:
		if gb(w, gi, 0x16) == 0xFF:
			continue
		var t := gb(w, gi, 0x21) & 0xF0
		var g2 := gb(w, gi, 2)
		for i in 16:
			var k := gb(w, gi, 6 + i)
			if k == 0xFF or not t in [0x30, 0x40, 0x50] or g2 & 0xC0 or g2 & 0x30 != 0x20:
				continue
			var st := w.sb(k, 0x36)
			var gx := W.s8(gb(w, gi, 0x16))
			var gy := W.s8(gb(w, gi, 0x17))
			if (st >= side and st <= side + 2) or not _no_side_at(w, side, gx, gy) or w.ub(k, 6) != 0:
				continue
			var dist := Ai.grid_distance(gx, gy, sx, sy)
			var best := -1
			var ba := 0
			for s in 6:
				var lid := w.launcher_id(k, s)
				if lid == -1:
					continue
				var ga := Move.final_attack(w, k, s, false)
				var kd := w.launcher(lid, 8) >> 5
				if ga and dist <= (w.weapon_range(k, s) & 0xFF) * 10 and w.slot_state(k, s) != 2 \
						and w.slot_count(k, s) and w.ub(k, 0x1C + 2 * (w.ub(k, 0x10 + 2 * s) & 15)) >> 6 != 2 \
						and ((t != 0x50 and kd == 2) or (t == 0x50 and kd == 1)) and ba < ga:
					best = s
					ba = ga
			if best != -1:
				cands.append([k, best])
	if cands.is_empty():
		return 0
	if side == 0:
		var c: Array = cands[rng.r16(cands.size())]
		_order(w, c[0], c[1], striker)
		return 0
	var n := cands.size()
	var res := hooks.ask(0x203)
	if res in ABORT:
		return res
	var units := []
	for c in cands:
		units.append(c[0])
	hooks.cb_target = g
	while res == 1:
		var k := hooks.cb_pick(units)
		if k in ABORT:
			return k
		if k != -1:
			var s := hooks.cb_slot(k, Ai.unit_group(w, k))
			if s in ABORT:
				return s
			if s != -2:
				n -= 1
				_order(w, k, s, striker)
		if n == 0:
			break
		res = hooks.ask(0x204)
		if res in ABORT:
			return res
	return 0


static func _order(w: Pd2World, k: int, s: int, striker: int) -> void:
	w.setb(k, 0x35, s)
	w.setb(k, 7, 0xFF)
	w.setb(k, 8, striker)
	w.setb(k, 6, 2)


static func _held(w: Pd2World, g: int) -> bool:
	var g2 := gb(w, g, 2)
	return g2 & 0x30 == 0x20 and g2 & 0xC0 == 0x80


static func _ours(w: Pd2World, side: int, k: int) -> bool:
	var st := w.sb(k, 0x36)
	return st >= side and st <= side + 2


static func _used(w: Pd2World, k: int, s: int) -> void:
	w.set_slot_count(k, s, w.slot_count(k, s) - 1)


static func _area_at(w: Pd2World, rng: Pd2Random, k: int, s: int, x: int, y: int) -> Array:
	return area(w, rng, x, y, w.launcher(w.launcher_id(k, s), 9) & 7)


## Damage to the aimed unit t; at 0 the radio (8) for a player unit alone in its group,
## then t is destroyed. checked: type 5 (t's group is known and held).
static func _hurt(w: Pd2World, k: int, s: int, t: int, gi: int, hooks: Hooks) -> int:
	var dmg := damage(w, k, s, t)
	var c := w.ub(t, 0xD)
	w.setb(t, 0xD, (c - dmg) & 0xFF if dmg < c else 0)
	if w.ub(t, 0xD) == 0:
		if gi == -2:
			gi = Ai.unit_group(w, t)
		if w.sb(t, 0x36) < 3 and Flight.gb(w, gi, 5) == 1:
			var res := hooks.radio(8, gi)
			if res in ABORT:
				return res
		Action.destroy(w, t)
	return 0


# --- reinforcements entering and leaving (0x44F2E0) -----------------------------------

## 0x44F030(d): [a, b, px, py] for a type-6 member from side d (+0x1F); side 3's upper
## branch reads the previous b; another d returns [] (the caller keeps its values).
static func reinf_entry(rng: Pd2Random, d: int, stale_b: int) -> Array:
	match d:
		0:
			var a := rng.r16(36) + 18
			return [a, 1, a, 0]
		1:
			if rng.r16(100) < 0x32:
				var a := 70 - rng.r16(18)
				return [a, 1, a, 0]
			var v := rng.r16(18) + 1
			return [70 - (v & 1), v, 71 - (v & 1), v]
		2:
			var v := rng.r16(36) + 18
			return [70 - (v & 1), v, 71 - (v & 1), v]
		3:
			if rng.r16(100) > 0x31:
				var a := 70 - (stale_b & 1)
				var b := 72 - rng.r16(18)
				return [a, b, a + 1, b]
			var a2 := 71 - rng.r16(18)
			return [a2, 70, a2, 71]
		4:
			var a := rng.r16(36) + 18
			return [a, 70, a, 71]
		5:
			if rng.r16(100) < 0x32:
				var a := rng.r16(18) + 1
				return [a, 70, a, 71]
			var b := 71 - rng.r16(18)
			return [1, b, 0, b]
		6:
			var b := rng.r16(36) + 18
			return [1, b, 0, b]
		7:
			if rng.r16(100) < 0x32:
				var b := rng.r16(18) + 1
				return [1, b, 0, b]
			var a := rng.r16(18) + 1
			return [a, 1, a, 0]
	return []


## 0x44FC70: u spotted if an active computer-side unit has it within its recon range.
static func reinf_seen(w: Pd2World, u: int) -> void:
	var up := w.pos(u)
	for i in w.n_units:
		if w.sb(i, 0x36) > 2 and w.active(i):
			var p := w.pos(i)
			if W.hexdist(up.x, up.y, p.x, p.y) <= Sight.recon_range(w, i).x:
				w.setb(u, 0, w.ub(u, 0) | 0x10)
				return
	w.setb(u, 0, w.ub(u, 0) & 0xEF)


static func _o_set(w: Pd2World, x: int, y: int, v: int) -> void:
	if x + MAP * y >= 0 and x + MAP * y < MAP * MAP:   # (row 72: the game writes past the layer)
		w.O[x + MAP * y] = v


## 0x44F730: one step of an arriving or leaving member (own saved unit DS:0x514E04).
static func reinf_move(w: Pd2World, rng: Pd2Random, x: int, y: int, u: int, mode: int, hooks: Hooks, easy := false) -> int:
	var sv: Array = w.reinf_saved
	if mode == 1:
		if sv[0] == -1:
			return 0
		var k: int = sv[0]
		w.setb(k, 9, sv[1])
		w.setb(k, 10, sv[2])
		_o_set(w, sv[1], sv[2], (k + 1) & 0xFF)
		if w.sb(k, 0x36) > 2 and k < 0xFE and Ai.in_view(w, sv[1], sv[2], 0):
			w.setb(k, 0, w.ub(k, 0) | 0x10)
		sv[0] = -1
		return 0
	if w.pos(u) == Vector2i(x, y):
		return 0
	var prev := Action.move_unit(w, u, x, y)
	w.setb(u, 4, w.ub(u, 4) & 0xCF)
	if sv[0] != -1:
		var k: int = sv[0]
		_o_set(w, sv[1], sv[2], (k + 1) & 0xFF)
		w.setb(k, 9, sv[1])
		w.setb(k, 10, sv[2])
		if w.sb(k, 0x36) > 2 and Ai.in_view(w, sv[1], sv[2], 0):
			w.setb(k, 0, w.ub(k, 0) | 0x10)
		w.reinf_saved = [-1, 0, 0]
	if prev != -1:
		w.reinf_saved = [prev, x, y]
	if mode == 2:
		w.setb(u, 0, w.ub(u, 0) & 0xEF)
	else:
		reinf_seen(w, u)
	var res := 0
	if w.ub(u, 0) & 0x10 and not w.ub(u, 0) & 0x40:
		var cands := Sight.reaction_candidates(w, u, w.ds8(0x50ADF1))
		if not cands.is_empty():
			res = hooks.react(u, cands, easy)
			if res in ABORT:
				return res
	if res > 3:
		reinf_move(w, rng, 0, 0, u, 1, hooks)
		return 2
	return 0


## 0x44FD50: u goes to its destination (+7 / +8), or the first free, passable, 30+ high
## hex of the spirals around an occupied one.
static func reinf_walk(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks, easy := false) -> int:
	var tx := w.ub(u, 7)
	var ty := w.ub(u, 8)
	if _occupant(w, tx, ty) != -1:
		var found := false
		var rad := 1
		var cx := tx
		var cy := ty
		while not found and rad <= 0x47:
			for h in Ai.spiral(cx, cy, rad):
				if Ai.passable(w, 0, h.x, h.y) and w.H[h.x + MAP * h.y] > 0x1D and _occupant(w, h.x, h.y) == -1:
					tx = h.x
					ty = h.y
					found = true
					break
			rad += 1
	var p := w.pos(u)
	var pts := path(w, p.x, p.y, tx, ty)
	w.setb(u, 0, w.ub(u, 0) & 0xCF)
	var res := 0
	for q in pts:
		if res or q.x == -1:      # (x = -1 ends the game's list: a unit off the map stays)
			break
		res = reinf_move(w, rng, q.x, q.y, u, 0, hooks, easy)
		if res in ABORT:
			return res
	return 0


## 0x44F2E0, at the turn start: type-6 groups 0-19 on the called point arrive (+2 bits
## 6-7 = 0) or leave (bits 6-7 = 1). stale: the routine's locals before their first
## write (a, b, arrival x / y, departure x / y; leftover stack values in the game).
## Returns 0, an abort code, or -1 where the game would loop forever (w.fault is set).
static func reinforcements(w: Pd2World, rng: Pd2Random, hooks: Hooks = null, stale: Array = [0, 0, 0, 0, 0, 0]) -> int:
	if hooks == null:
		hooks = Hooks.new()
	var a: int = stale[0]
	var b: int = stale[1]
	var ax: int = stale[2]
	var ay: int = stale[3]
	var dx: int = stale[4]
	var dy: int = stale[5]
	for g in 20:
		if gb(w, g, 0x16) == 0xFF or gb(w, g, 0x21) & 0xF0 != 0x60 or gb(w, g, 2) & 0x30 != 0x20:
			continue
		if W.s8(gb(w, g, 0x16)) != w.fire_point.x or W.s8(gb(w, g, 0x17)) != w.fire_point.y:
			continue
		var phase := gb(w, g, 2) & 0xC0
		var n := 0
		if phase == 0:
			var i := 0
			var last := Vector2i(-1, -1)
			while i < 16:
				var k := gb(w, g, 6 + i)
				if k == 0xFF:
					i += 1
					continue
				if last == Vector2i(i, k) and (w.ub(k, 0) & 1 or w.ub(k, 0xD) == 0):
					if w.safe_hit("H3", "reinforcements: unit %d stays in its slot (the game loops): next slot" % k):
						i += 1
						continue
					w.fault = "reinforcements: the game loops on this member forever"
					return -1
				last = Vector2i(i, k)
				var e := reinf_entry(rng, W.s8(gb(w, g, 0x1F)), b)
				if not e.is_empty():
					a = e[0]
					b = e[1]
					ax = e[2]
					ay = e[3]
				a = maxi(a, 1)
				b = maxi(b, 1)
				if b > 69:
					b = 70
				a = mini(a, 70 - (b & 1))
				w.setb(k, 9, ax)
				w.setb(k, 10, ay)
				hooks.line(0x1FF, [["sign", gb(w, g, 1)], ["num", "%d", i + 1]])   # the slot counter (1-16)
				w.setb(k, 0, w.ub(k, 0) | 0x0C)
				hooks.panel(k)
				var res := reinf_move(w, rng, a, b, k, 2, hooks)
				if res in ABORT:
					return res
				res = reinf_walk(w, rng, k, hooks)
				if res in ABORT:
					return res
				if not w.ub(k, 0) & 1 and w.ub(k, 0xD):
					n += 1
					i += 1
					w.setb(k, 0x36, 1)
			if n:
				setgb(w, g, 0x20, 4)
				setgb(w, g, 2, gb(w, g, 2) & 0x3F | 0x80)
		elif phase == 0x40:
			for i in 16:
				var k := gb(w, g, 6 + i)
				if k == 0xFF:
					continue
				hooks.panel(k)
				var e := reinf_entry(rng, W.s8(gb(w, g, 0x1F)), b)
				if not e.is_empty():
					a = e[0]
					b = e[1]
					dx = e[2]
					dy = e[3]
				a = maxi(a, 1)
				b = maxi(b, 1)
				if b > 69:
					b = 70
				a = mini(a, 70 - (b & 1))
				w.setb(k, 7, dx)
				w.setb(k, 8, dy)
				var res := reinf_walk(w, rng, k, hooks, true)
				if res in ABORT:
					return res
				w.setb(k, 0x36, 0)
				if not w.ub(k, 0) & 1:
					var p := w.pos(k)
					_o_set(w, p.x, p.y, 0)
				Action.take_off_map(w, k)
				n += 1
			if n:
				Ai.group_retarget(w, g, -1, 0)
				setgb(w, g, 2, gb(w, g, 2) | 0x30)
	return 0


## 0x4E37A0(side): the strikes of one side (3 for the computer's, 0 for the player's).
static func executor(w: Pd2World, rng: Pd2Random, side: int, hooks: Hooks = null, easy := false) -> int:
	if hooks == null:
		hooks = Hooks.new()
	for g in 64:
		if gb(w, g, 0x16) == 0xFF:
			continue
		for i in 16:
			var k := gb(w, g, 6 + i)
			if k == 0xFF or w.ub(k, 0) & 1 or not _ours(w, side, k) or gb(w, g, 0x21) & 0xF0 != 0x50:
				continue
			var o := w.ub(k, 6)
			if _held(w, g) and o == 1:
				hooks.panel(k)
				var s := w.ub(k, 0x35)
				var ax := w.ub(k, 7)
				var ay := w.ub(k, 8)
				if ax == 0xFF:
					var p := w.pos(ay)
					fire(w, rng, k, s, p.x, p.y, null, hooks, easy)
					_used(w, k, s)
					var res := counter_battery(w, rng, side, k, g, hooks)
					if res in ABORT:
						return res
				elif w.on_map(ax, ay):
					fire(w, rng, k, s, ax, ay, _area_at(w, rng, k, s, ax, ay), hooks, easy)
					_used(w, k, s)
					var res := counter_battery(w, rng, side, k, g, hooks)
					if res in ABORT:
						return res
				w.setb(k, 6, 3)
			elif _held(w, g) and o == 2:
				var s := w.ub(k, 0x35)
				_used(w, k, s)
				var t := w.ub(k, 8)
				var gi := Ai.unit_group(w, t)
				if not w.ub(t, 0) & 1 and gi != -1 and _held(w, gi):
					var res := _hurt(w, k, s, t, gi, hooks)
					if res in ABORT:
						return res
				var res2 := counter_battery(w, rng, side, k, g, hooks)
				if res2 in ABORT:
					return res2
				w.setb(k, 6, 3)
	for g in 64:
		if gb(w, g, 0x16) == 0xFF:
			continue
		var i := 0
		while i < 16:
			var k := gb(w, g, 6 + i)
			if k == 0xFF or w.ub(k, 0) & 1 or not _ours(w, side, k):
				i += 1
				continue
			var typ := gb(w, g, 0x21) & 0xF0
			var o := w.ub(k, 6)
			if (typ == 0x30 or typ == 0x40) and _held(w, g) and o == 1:
				var ax := w.ub(k, 7)
				var ay := w.ub(k, 8)
				if ax == 0xFF:
					hooks.panel(k)
					var s := w.ub(k, 0x35)
					if not w.ub(ay, 0) & 1 and w.ub(ay, 0) & 0x10:
						if side == 0:
							hooks.line(0x206)
						var p := w.pos(ay)
						fire(w, rng, k, s, p.x, p.y, null, hooks, easy)
						w.setb(k, 6, 3)
						_used(w, k, s)
					else:
						if side == 0:
							hooks.line(0x205)
						w.setb(k, 6, 3)
				elif w.on_map(ax, ay):
					hooks.panel(k)
					var s := w.ub(k, 0x35)
					Turn.clear_reacted_all(w)
					if fly_in(w, rng, k, s, g, hooks) == 2:
						i -= 1
					else:
						var p := w.pos(k)
						Action.take_off_map(w, k)
						var res := move(w, rng, p.x, p.y, k, 1, hooks)
						if res in ABORT:
							return res
						_used(w, k, s)
						if side == 0:
							var wh := w.warhead(k, s)
							if wh == 0:
								hooks.line(0x207)
							elif wh == 2:
								hooks.line(0x208)
						fire(w, rng, k, s, ax, ay, _area_at(w, rng, k, s, ax, ay), hooks, easy)
						w.setb(k, 6, 3)
				else:
					w.setb(k, 6, 3)
			elif (typ == 0x30 or typ == 0x40) and _held(w, g) and o == 2:
				var t := w.ub(k, 8)
				var s := w.ub(k, 0x35)
				if side == 0:
					hooks.line(0x20B, [["sign", gb(w, g, 1)]])
				_used(w, k, s)
				var res := _hurt(w, k, s, t, -2, hooks)
				if res in ABORT:
					return res
				w.setb(k, 6, 5)
			i += 1
	for g in 64:
		if gb(w, g, 0x16) == 0xFF:
			continue
		var last := -1
		var sided := false
		var struck := false
		var five := false
		var pending := false
		var other := false
		for i in 16:
			var k := gb(w, g, 6 + i)
			if k == 0xFF or w.ub(k, 0) & 1:
				continue
			last = w.sb(k, 0x36)
			var o := w.ub(k, 6)
			if not _ours(w, side, k):
				if o == 1 or o == 2:
					other = true
			elif o == 3:
				struck = true
				sided = true
			elif o == 5:
				struck = true
				five = true
				sided = true
			else:
				if o == 1 or o == 2:
					pending = true
				sided = true
		var typ := gb(w, g, 0x21) & 0xF0
		var g2 := gb(w, g, 2)
		if sided and typ == 0x50 and g2 & 0x30 == 0x20 and g2 & 0xC0 == 0x40:
			setgb(w, g, 2, g2 & 0x3F)
		elif last != -1:
			if struck and not pending and _held(w, g):
				if last < 3:
					if not five:
						if typ == 0x50:
							setgb(w, g, 0x1A, gb(w, g, 0x16))
							setgb(w, g, 0x18, gb(w, g, 0x16))
							setgb(w, g, 0x1B, gb(w, g, 0x17))
							setgb(w, g, 0x19, gb(w, g, 0x17))
						Ai.group_retarget(w, g, -1, 0)
					setgb(w, g, 2, gb(w, g, 2) & 0xF | 0x60)
				else:
					setgb(w, g, 2, gb(w, g, 2) & 0x3F)
				for i in 16:
					var k := gb(w, g, 6 + i)
					if k != 0xFF and not w.ub(k, 0) & 1:
						w.setb(k, 6, 0)
			elif other and g2 & 0x30 == 0x20 and g2 & 0xC0 == 0:
				setgb(w, g, 2, g2 & 0x3F | 0x80)
	return 0
