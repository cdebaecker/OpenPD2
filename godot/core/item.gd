class_name Item
extends RefCounted
## The item command (Pd2.exe 0x4ECC60, rules.item_command): a pocket round used from the
## machine status window -- a sensor placed, or a round thrown (0x4ED380 with its own
## damage 0x4EDA00 and hit 0x4EDEB0) -- and the sensors: their search as "unit -1"
## (0x4806A0, 0x47F150), the turn tick (0x480910) and the recon pass's scan. RULES.md 5.16.

const W := preload("res://core/world.gd")
const MAP := 72
const ABORT := [0x10000, 0x20000, 0x40000]
const UNITS := 0x506C93
const MACHS := 0x50ADF5
const M1_AMMO := 0x50ADF5 + 0x3E0 + 0x660   # the working ammunition table

## 0x4EDCC0: damage class by target armour x warhead (14 per row, read on past a row).
const DAMAGE_CLASS := [
	200, 200, 200, 100, 100, 100, 50, 100, 0, 0, 0, 0, 0, 200,
	200, 200, 200, 20, 20, 100, 201, 201, 0, 0, 0, 0, 0, 200,
	200, 200, 200, 201, 100, 201, 201, 201, 0, 0, 0, 0, 0, 200,
	0, 0, 0, 100, 100, 100, 100, 100, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 100, 100, 100, 100, 201, 0, 0, 0, 0, 0, 0,
]


## What the item command leaves to the game.
class Hooks extends RefCounted:
	func mine_blast(x: int, y: int) -> void:
		pass

	## The throw question (0x1CB / 0x1CC with ap): 0 = yes.
	func ask(msg: int, ap: int) -> int:
		return 0

	## The "enemy discovered" window (0x47E790) for a unit a placed sensor spots.
	func discovered(u: int) -> int:
		return 0

	## The animations play (option 0x10 clear; rules.ItemHooks' default)
	var anims := true
	var anim_rec: Array = []      # [kind, x, y] of the record (display)

	## An animation player's frame (as AiHooks.anim_frame): true when a click skipped it.
	func anim_frame(player: int, x: int, y: int, i: int, dy: int, dx: int) -> bool:
		return false


## The round's AP to use it (the pocket menu's "use" entry: ammo +7 low 5 bits).
static func use_ap(w: Pd2World, u: int, p: int) -> int:
	return w.ammo(w.pocket_ammo(u, p), 7) & 0x1F


static func damage_class(w: Pd2World, u: int, p: int, t: int) -> int:
	var wh := 13 if u == -1 else w.ammo(w.pocket_ammo(u, p), 8) & 15
	var i := wh + 14 * w.armour(t)
	if i >= DAMAGE_CLASS.size():
		w.fault = "item damage class past the table (the game reads its stack)"
		return 0
	return DAMAGE_CLASS[i]


## 0x4EDA00: an item's damage on t.
static func damage(w: Pd2World, rng: Pd2Random, u: int, p: int, t: int, easy := false) -> int:
	var dclass := damage_class(w, u, p, t)
	var a_id := w.pocket_ammo(u, p)
	var a: int
	if w.unit_class(u) < 2:
		a = W.s8(w.ucrew(u, 10)) + (w.ammo(a_id, 1) if a_id != -1 else 0)
	else:
		a = W.cdiv(W.s8(w.ucrew(u, 11)), 2) + (w.ammo(a_id, 2) if a_id != -1 else 0)
	if a == 0:
		return 0
	var tp := w.pos(t)
	var cov := w.terrain[608 + 16 * (5 + w.unit_class(t)) + w.terrain[w.layer(w.T, tp.x, tp.y)]]
	if w.ub(t, 0) & 0x10:
		cov *= 2
	var div := W.cdiv(cov + 10, 10)
	var armour := w.umachine(t, 4 if w.unit_class(u) < 2 else 5)
	var crew_def := W.s8(w.ucrew(t, 13))
	var dmg: int
	if dclass == 200:
		var n := W.cdiv(W.cdiv(a - crew_def, div) * (100 - armour), 100)
		dmg = (rng.r16(n) + rng.r16(n) + rng.r16(n)) / 2
	else:
		var v := W.cdiv(W.cdiv(a - crew_def, div) * (100 - armour) * dclass, 10000)
		var spread := mini(10, maxi(2, W.cdiv(v, 4)))
		dmg = maxi(1, rng.r16(spread) + 1 + v - W.cdiv(spread, 2))
	var enemy := w.sb(t, 0x36) >= 3
	var cond := w.ub(t, 0xD)
	if cond < 11:
		dmg = dmg * 2 if enemy else W.cdiv(dmg, 2)
	elif cond < 21:
		dmg = W.cdiv(dmg * 3, 2) if enemy else W.cdiv(dmg * 8, 10)
	if not enemy and easy:
		dmg >>= 4
	return dmg if dmg > 0 else 1


## 0x4EDEB0: an item's hit on t (one part-damage roll); 1 when t is the thrower and dies.
static func hit(w: Pd2World, rng: Pd2Random, t: int, dmg: int, u: int) -> int:
	if dmg < w.ub(t, 0xD):
		w.setb(t, 0xD, w.ub(t, 0xD) - dmg)
		var k := rng.r16(12)
		var p1 := w.ub(t, 1)
		if k == 0:
			if p1 & 3 < 2:
				w.setb(t, 1, (p1 & 0xFC) | ((p1 & 3) + 1))
		elif k == 1:
			var a := p1 & 0x0C
			var c := p1 & 0x30
			if a != 8 and c != 0x20:
				if (a == 0 and c == 0) or (a == 4 and c == 0x10):
					if rng.r16(2) == 0:
						w.setb(t, 1, (p1 & 0xCF) | ((c + 0x10) & 0x30))
					else:
						w.setb(t, 1, (p1 & 0xF3) | ((a + 4) & 0x0C))
				elif (p1 >> 2) & 0x0C < a:
					w.setb(t, 1, (p1 & 0xCF) | ((c + 0x10) & 0x30))
				else:
					w.setb(t, 1, (p1 & 0xF3) | ((a + 4) & 0x0C))
		elif k <= 5:
			var s := k - 2
			if w.launcher_id(t, s) != -1:
				var st := w.slot_state(t, s)
				if st < 2:
					w.setb(t, 0x10 + 2 * s, (w.ub(t, 0x10 + 2 * s) & 0xCF) | (st + 1) << 4)
		elif k <= 9:
			var p := k - 6
			if w.pocket_ammo(t, p) != -1:
				var st := w.pocket_state(t, p)
				if st < 2:
					w.setb(t, 0x1C + 2 * p, (w.ub(t, 0x1C + 2 * p) & 0x3F) | (st + 1) << 6)
		elif k == 10:
			if w.unit_class(t) == 0 and p1 >> 6 < 2:
				w.setb(t, 1, p1 + 0x40)
		else:
			var p2 := w.ub(t, 2)
			if w.unit_class(t) == 0 and p2 & 3 < 2:
				w.setb(t, 2, (p2 & 0xFC) | ((p2 & 3) + 1))
		return 0
	w.setb(t, 0xD, 0)
	w.setb(t, 0, w.ub(t, 0) | 1)
	if u == t:
		return 1
	Action.destroy(w, t)
	return 0


## 0x4ED380: u's pocket p round (warhead wh) thrown at (x, y), over pts or the single hex.
static func throw(w: Pd2World, rng: Pd2Random, u: int, p: int, wh: int, x: int, y: int, pts: Variant, hooks: Hooks, easy := false) -> int:
	var side := 0 if w.sb(u, 0x36) < 3 else 3
	var self_hit := false
	var anims := hooks.anims
	if anims:
		hooks.anim_rec = [4, w.pos(u).x, w.pos(u).y]      # (display: 0x40F590(-1, 2))
		Action.anim_play(w, rng, hooks, 0x40F730, x, y)
	var hexes: Array = pts if pts != null else [Vector2i(x, y)]
	for q in hexes:
		var tx: int = q.x
		var ty: int = q.y
		var laid := false
		if wh == Action.SMOKE_WARHEAD:
			if anims:
				Action.anim_hit(w, rng, hooks, 4, tx, ty)
			if w.on_map(tx, ty):
				w.F[tx + MAP * ty] |= 1
			continue
		var o := Strike._occupant(w, tx, ty)
		if o == -1:
			if not w.campaign and wh == Action.MINE_WARHEAD:
				Action.lay_mine(w, tx, ty, side)
				laid = true
			elif anims:
				Action.anim_hit(w, rng, hooks, 4, tx, ty)
		else:
			var h := 100 if wh == 8 else (0x62 if rng.r16(100) < 0x62 else 0)
			if h == 0 or w.unit_class(o) > 1:
				w.events.append(["grow", o, "DEF", 1])
			else:
				if anims:
					Action.anim_hit(w, rng, hooks, 4, tx, ty)
				var dmg := damage(w, rng, u, p, o, easy)
				if w.ub(o, 0xD) - dmg < 1:
					if anims:
						Action.anim_kill(w, rng, hooks, tx, ty)
					Melee.kill_credit(w, u, o)
				if hit(w, rng, o, dmg, u) == 1:
					self_hit = true
		if not w.campaign and not laid and (wh < 3 or wh == Action.MINE_WARHEAD) and tx + MAP * ty >= 0 \
				and Action.mine_at(w, tx, ty):
			hooks.mine_blast(tx, ty)
			if anims:
				Action.anim_bomb(w, rng, hooks, tx, ty)
			w.F[tx + MAP * ty] &= 0x3F
			if o != -1 and w.unit_class(o) < 3:
				var dmg2 := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
				if anims and w.ub(o, 0xD) - dmg2 < 1:
					Action.anim_kill(w, rng, hooks, tx, ty)
				if Fire.apply_hit(w, rng, o, dmg2, -1, 12, easy) == "destroyed":
					Action.destroy(w, o)
	if self_hit:
		Action.destroy(w, u)
	return 0


static func _m1(w: Pd2World, f: int) -> int:     # unit -1's field f (the bytes before the unit table)
	return w.mem8(UNITS - 55 + f)


## recon_range of unit -1's record (the 55 bytes before the unit table).
static func _m1_recon(w: Pd2World) -> Vector2i:
	if _m1(w, 1) & 3 == 2:
		return Vector2i(2, 2)
	var rng_ := 0
	var pen := 0
	for k in 6:
		if _m1(w, 0xF + 2 * k) == 0xFF or (_m1(w, 0x10 + 2 * k) & 0x30) == 0x20:
			continue
		# unit -1's bytes are combat records: its round and machine can be any number; the
		# game reads the memory there, past the tables too (RULES.md 5.23)
		var a := W.s8(_m1(w, 0x1B + 2 * (_m1(w, 0x10 + 2 * k) & 15)))
		rng_ = (rng_ + w.mem8(M1_AMMO + 12 * a + 4)) & 0xFF
		pen = (pen + w.mem8(M1_AMMO + 12 * a + 5)) & 0xFF
	var m := W.s8(_m1(w, 0xC))
	return Vector2i((rng_ + w.mem8(MACHS + 31 * m + 7)) & 0xFF, (pen + w.mem8(MACHS + 31 * m + 8)) & 0xFF)


## sees_unit(o, -1) (0x412190): unit -1's recon, from (vx, vy), sees unit o.
static func _m1_sees(w: Pd2World, o: int, vx: int, vy: int) -> bool:
	var r := _m1_recon(w)
	var op := w.pos(o)
	if r.x < W.hexdist(vx, vy, op.x, op.y):
		return false
	return Sight.line_of_sight(w, vx, vy, op.x, op.y, r.y, 0, true) or Sight.line_of_sight(w, vx, vy, op.x, op.y, r.y, 1, true)


## 0x4806A0: a sensor's search from (x, y) as unit -1 (mode 13: the round's recon).
static func sensor_search(w: Pd2World, x: int, y: int, ammo: int, announce: bool, hooks: Hooks) -> Variant:
	if ammo < 0 or ammo >= 96:
		w.fault = "a sensor without a round (the game reads past the table)"
		return []
	var smap := Sight.search_map(w, x, y, w.ammo(ammo, 4), w.ammo(ammo, 5))
	if smap == null:
		return []
	var side := 3 if W.s8(_m1(w, 0x36)) > 2 else 0
	for ly in smap.h:
		for lx in smap.w:
			if smap.at(lx, ly) != 0xFF:
				Ai.set_view(w, smap.x0 + lx, smap.y0 + ly, side)
	var out := []
	for ly in smap.h:
		for lx in smap.w:
			if smap.at(lx, ly) != 1:
				continue
			var o := Strike._occupant(w, smap.x0 + lx, smap.y0 + ly)
			if o == -1 or w.armour(o) == 3:
				continue
			if not w.ub(o, 0) & 0x10 and (3 if w.sb(o, 0x36) > 2 else 0) != side:
				w.setb(o, 0, w.ub(o, 0) | 0x10)
				out.append(o)
	var vx := W.s8(_m1(w, 9))
	var vy := W.s8(_m1(w, 10))
	var m := W.s8(_m1(w, 0xC))
	var climb: bool = Pd2World.CLASS_BY_CATEGORY[w.mem8(MACHS + 31 * m) & 15] > 1
	var saved := 0
	if climb:
		if vx + MAP * vy < 0 or vx + MAP * vy >= MAP * MAP:
			w.fault = "unit -1 off the grid (the game writes past the layer)"
			return out
		saved = w.H[vx + MAP * vy]
		w.H[vx + MAP * vy] = (saved + 6) & 0xFF
	for o in w.n_units:
		var f := w.ub(o, 0)
		if w.unit_class(o) > 1 and w.active(o) and f & 4 and f & 8 and _m1_sees(w, o, vx, vy) \
				and (3 if w.sb(o, 0x36) > 2 else 0) != side and not f & 0x10:
			w.setb(o, 0, f | 0x10)
			out.append(o)
	if climb:
		w.H[vx + MAP * vy] = saved
	if announce:
		for o in out:
			if w.sb(o, 0x36) > 2:
				var res := hooks.discovered(o)
				if res in ABORT:
					return res
	return out


## The end of the recon pass: every sensor on the map with turns left searches.
static func sensors_scan(w: Pd2World, hooks: Hooks = null) -> void:
	if hooks == null:
		hooks = Hooks.new()
	for i in 42:
		var x := W.s8(w.sensors[4 * i])
		var y := W.s8(w.sensors[4 * i + 1])
		if w.on_map(x, y) and W.s8(w.sensors[4 * i + 2]) > 0:
			sensor_search(w, x, y, W.s8(w.sensors[4 * i + 3]), false, hooks)


## 0x480910, at the turn start: the sensors count down and search; spent ones are dropped.
static func sensors_tick(w: Pd2World, hooks: Hooks = null) -> int:
	if hooks == null:
		hooks = Hooks.new()
	for i in 42:
		var x := W.s8(w.sensors[4 * i])
		var y := W.s8(w.sensors[4 * i + 1])
		if w.on_map(x, y) and W.s8(w.sensors[4 * i + 2]) > 0:
			w.sensors[4 * i + 2] = (w.sensors[4 * i + 2] - 1) & 0xFF
			sensor_search(w, x, y, W.s8(w.sensors[4 * i + 3]), false, hooks)
		else:
			w.sensors[4 * i] = 0xFF
		if w.on_map(x, y) and w.sensors[4 * i + 2] == 0:
			w.sensors[4 * i] = 0xFF
	return 0


static func _use(w: Pd2World, u: int, p: int, ap: int) -> void:
	Ai.spend_ap(w, u, ap)
	var c := w.pocket_count(u, p)
	var k := 0x1C + 2 * p
	w.setb(u, k, (w.ub(u, k) & 0xC0) | ((c - 1) & 0x3F))


## 0x4ECC60 once the target (x, y) is clicked (a hex of fire_target_map(u, 0x80 + p)).
## Returns 1 or an abort code.
static func command(w: Pd2World, rng: Pd2Random, u: int, p: int, ap: int, x: int, y: int, hooks: Hooks = null, easy := false) -> int:
	if hooks == null:
		hooks = Hooks.new()
	var a_id := w.pocket_ammo(u, p)
	var wh := w.ammo(a_id, 8) & 15
	var radius := 0 if wh == Action.MINE_WARHEAD else (w.ammo(a_id, 4) if wh == 9 else 1)
	var up := w.pos(u)
	var dist := W.hexdist(up.x, up.y, x, y)
	if wh == 9:
		var i := 0
		while i < 42:
			var sx := W.s8(w.sensors[4 * i])
			var sy := W.s8(w.sensors[4 * i + 1])
			if sx == -1 or sx < 1 or 71 - (sy & 1) < sx or sy < 1 or 71 < sy:
				w.sensors[4 * i] = x & 0xFF
				w.sensors[4 * i + 1] = y & 0xFF
				w.sensors[4 * i + 2] = 4
				w.sensors[4 * i + 3] = a_id & 0xFF
				i = 0x15
			i += 1
		var res = sensor_search(w, x, y, a_id, true, hooks)
		if res is int and res in ABORT:
			return res
		_use(w, u, p, ap)
		return 1
	var pts: Variant = Strike.area(w, rng, x, y, radius) if radius else null
	var msg := 0x1CC if (radius < dist or wh != 1) else 0x1CB
	var ans := hooks.ask(msg, ap)
	if ans in ABORT:
		return ans
	if ans == 0:
		throw(w, rng, u, p, wh, x, y, pts, hooks, easy)
		_use(w, u, p, ap)
	return 1
