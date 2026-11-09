class_name Sight
extends RefCounted
## Line of sight, sight levels, the search map and spotting (rules.py "line of sight";
## RULES.md section 5).

const W := preload("res://core/world.gd")
const S_SIGHT_BLOCK := 512
const SEEN := 6
const SEEN_HIDDEN := 1
const SEEN_SPECIAL := 4
const SEARCH_MOVING := 1
const SEARCH_COMMAND := 8


## 0x4DE4A0: the point `step` steps along (X1,Y1)-(X2,Y2) in doubled-x coordinates.
static func line_point(X1: int, Y1: int, X2: int, Y2: int, step: int) -> Vector2i:
	var dx := X2 - X1
	var dy := Y2 - Y1
	var sx := -1 if dx < 0 else 1
	var sy := -1 if dy < 0 else 1
	dx = absi(dx)
	dy = absi(dy)
	if dy == 0:
		return Vector2i(X1 + sx * step, Y1)
	if dx == 0:
		return Vector2i(X1, Y1 + sy * step)
	if dx >= dy:
		var q := (dy * step * 100) / dx
		return Vector2i(X1 + sx * step, Y1 + (q * sy) / 100)
	var q2 := (dx * step * 100) / dy
	return Vector2i(X1 + (q2 * sx) / 100, Y1 + sy * step)


static func to_doubled(x: int, y: int, variant: int) -> int:
	return 2 * x + (y & 1) if variant else 2 * x - ((~y) & 1)


static func from_doubled(X: int, Y: int, variant: int) -> int:
	return (X + ((~Y) & X & 1)) >> 1 if variant else (X + ((~Y) & 1)) >> 1


static func _h(w: Pd2World, x: int, y: int) -> int:
	return w.layer(w.H, x, y)


static func _occ(w: Pd2World, x: int, y: int) -> int:
	return w.layer(w.O, x, y) - 1 if not w.O.is_empty() else -1


## 0x410A90: can a unit at (x1,y1) see (x2,y2)? One of the two line variants.
static func line_of_sight(w: Pd2World, x1: int, y1: int, x2: int, y2: int, limit := 1, variant := 0, unit_to_unit := false) -> bool:
	var h1 := _h(w, x1, y1) + (0 if unit_to_unit else 1)
	var h2 := _h(w, x2, y2) + (1 if unit_to_unit else 0)
	var occ := _occ(w, x1, y1)
	if occ != -1 and w.unit_class(occ) >= 2:
		h1 = 31 if h1 < 31 else h1 + 1
	var dist := W.hexdist(x1, y1, x2, y2)
	var dh := h2 - h1
	var n := maxi(2 * absi(x1 - x2) + 2, absi(y1 - y2) + 1)
	var X1 := to_doubled(x1, y1, variant)
	var X2 := to_doubled(x2, y2, variant)
	var px := x1
	var py := y1
	var count := 0
	for step in n + 1:
		var P := line_point(X1, y1, X2, y2, step)
		var x := from_doubled(P.x, P.y, variant)
		var y := P.y
		if W.hexdist(x1, y1, x, y) > dist or (x == px and y == py):
			continue
		var hp := _h(w, x, y)
		if hp == 0 and not unit_to_unit:
			return false
		var blocker := w.terrain[S_SIGHT_BLOCK + w.terrain[w.layer(w.T, x, y)]] & 1
		var smoke := w.layer(w.F, x, y) & 1
		var dd := W.hexdist(x1, y1, x, y)
		var rise := (hp - h1) * dist if hp != h1 and dist else 0
		var line := dd * dh
		if rise > line:
			return false
		if (smoke or blocker) and (hp - h1 + 1) * dist >= line and hp >= h1 - 1:
			count += smoke + blocker
		if count > limit:
			return false
		if count == limit and not (x == x2 and y == y2):
			return false
		px = x
		py = y
	return true


static func can_see(w: Pd2World, x1: int, y1: int, x2: int, y2: int) -> bool:
	return line_of_sight(w, x1, y1, x2, y2, 1, 0) or line_of_sight(w, x1, y1, x2, y2, 1, 1)


## 0x472410's check within 2 hexes.
static func near_sight(w: Pd2World, b: int, t: int) -> bool:
	var tp := w.pos(t)
	var bp := w.pos(b)
	var tx := tp.x
	var ty := tp.y
	var bx := bp.x
	var by := bp.y
	var ht := _h(w, tx, ty)
	var a := Vector2i(tx, ty)
	var c := Vector2i(tx, ty)
	var step := 1
	while true:
		if a == tp:
			var P := line_point(2 * tx + (tx & 1), ty, 2 * bx + (by & 1), by, step)
			a = Vector2i((P.x + ((~P.y) & P.x & 1)) >> 1, P.y)
		if c == tp:
			var Q := line_point(2 * tx - ((~tx) & 1), ty, 2 * bx - ((~by) & 1), by, step)
			c = Vector2i((Q.x + ((~Q.y) & 1)) >> 1, Q.y)
		step += 1
		if a != tp and c != tp:
			break
	var ha := _h(w, a.x, a.y) - ht
	var hc := _h(w, c.x, c.y) - ht
	return not (hc >= 2 and ha >= 2)


## 0x480EA0
static func ring_start(x: int, y: int, r: int) -> Vector2i:
	return Vector2i(x - (r + ((~y) & 1)) / 2, y - r)


static func _on(a: int, b: int) -> bool:
	return 0 < a and a < 71 - (b & 1) and 0 < b and b < 71


## 0x4113D0: the on-map hexes at distance r (the corner comes twice).
static func ring(x: int, y: int, r: int) -> Array:
	var c := ring_start(x, y, r)
	var out := []
	if _on(c.x, c.y):
		out.append(c)
	for d in [2, 3, 4, 5, 0, 1]:
		for i in r:
			c += Move.NEIGHBOURS[c.y & 1][d]
			if _on(c.x, c.y):
				out.append(c)
	return out


## 0x410F30: the hexes on the line with a visibility level each, as Vector3i(x, y, level).
static func sight_levels(w: Pd2World, x1: int, y1: int, x2: int, y2: int, penetration: int, variant: int) -> Array:
	var eye := _h(w, x1, y1) + 1
	var occ := _occ(w, x1, y1)
	if occ != -1 and w.unit_class(occ) >= 2:
		eye = 31 if eye < 31 else eye + 1
	var D := W.hexdist(x1, y1, x2, y2)
	var n := maxi(2 * absi(x1 - x2) + 2, absi(y1 - y2) + 1)
	var X1 := to_doubled(x1, y1, variant)
	var X2 := to_doubled(x2, y2, variant)
	var prev := Vector2i(x1, y1)
	var out := []
	var obst := 0
	var ob_rise := 0
	var ob_dist := 0
	var hz_rise := 0
	var hz_dist := 0
	var blocked := false
	for step in n + 1:
		var P := line_point(X1, y1, X2, y2, step)
		var x := from_doubled(P.x, P.y, variant)
		var y := P.y
		if (x == prev.x and y == prev.y) or W.hexdist(x1, y1, x, y) > D:
			continue
		prev = Vector2i(x, y)
		var h := _h(w, x, y)
		if h == 0:
			out.append(Vector3i(x, y, SEEN_SPECIAL))
			continue
		var blk := w.terrain[S_SIGHT_BLOCK + w.terrain[w.layer(w.T, x, y)]] & 1
		var smoke := w.layer(w.F, x, y) & 1
		var dd := W.hexdist(x1, y1, x, y)
		var rise := h - eye
		var cur := rise * hz_dist if rise and hz_dist else 0
		var hzline := dd * hz_rise
		var done := false
		if h >= 60:
			done = true
			out.append(Vector3i(x, y, SEEN_SPECIAL))
		elif cur < hzline and (dd > 2 or hz_rise > 0):
			done = true
			out.append(Vector3i(x, y, SEEN_HIDDEN))
		var low := false
		if rise * ob_dist <= (ob_rise + 1) * dd and h >= eye - 1:
			obst += smoke + blk
			low = true
			if ob_dist == 0 or smoke + blk:
				ob_rise = rise
				ob_dist = dd
		elif h < eye - 1:
			low = true
		if hz_dist == 0 or cur >= hzline:
			hz_rise = rise
			hz_dist = dd
		if done:
			continue
		if low and obst > penetration and dd > 2:
			out.append(Vector3i(x, y, SEEN_HIDDEN))
			blocked = true
			continue
		if blocked and low and dd > 2:
			out.append(Vector3i(x, y, SEEN_HIDDEN))
			continue
		out.append(Vector3i(x, y, SEEN))
		if obst >= penetration:
			blocked = true
	return out


## 0x450A80 / 0x450AF0: [range, penetration] of a unit's own recon.
static func recon_range(w: Pd2World, u: int) -> Vector2i:
	if w.ub(u, 1) & 3 == 2:
		return Vector2i(2, 2)
	var rng_ := 0
	var pen := 0
	for k in 6:
		if w.ub(u, 0xF + 2 * k) == 0xFF or (w.ub(u, 0x10 + 2 * k) & 0x30) == 0x20:
			continue
		var a := w.ammo_id(u, k)
		rng_ = (rng_ + w.ammo(a, 4)) & 0xFF
		pen = (pen + w.ammo(a, 5)) & 0xFF
	return Vector2i((rng_ + w.umachine(u, 7)) & 0xFF, (pen + w.umachine(u, 8)) & 0xFF)


## 0x4114C0: which hexes a search from (x, y) sees: a MoveMap of 1 (seen) / 0xFF, or null.
static func search_map(w: Pd2World, x: int, y: int, rng_: int, pen: int) -> Move.MoveMap:
	var box := Move.move_box(x, y, rng_)
	var x0: int = box[0]
	var y0: int = box[1]
	var wd: int = box[2]
	var ht: int = box[3]
	if wd * ht <= 1:
		return null
	var m := PackedByteArray()
	m.resize(wd * ht)
	m[(y - y0) * wd - x0 + x] = 6
	for r in range(rng_, 0, -1):
		for rp in ring(x, y, r):
			var c := W.s8(m[(rp.y - y0) * wd - x0 + rp.x])
			if c >= 6 or c == 4:
				continue
			for e in sight_levels(w, x, y, rp.x, rp.y, pen, 0):
				var i: int = (e.y - y0) * wd - x0 + e.x
				var c2 := W.s8(m[i])
				if c2 >= 6 or (c2 == 4 and e.z == 1):
					continue
				m[i] = 4 if e.z == 4 else (m[i] + e.z) & 0xFF
			for e in sight_levels(w, x, y, rp.x, rp.y, pen, 1):
				var i: int = (e.y - y0) * wd - x0 + e.x
				var c2 := W.s8(m[i])
				if c2 >= 6 or (c2 == 4 and e.z == 1):
					continue
				if e.z == 4:
					m[i] = 4
				elif e.z != 1:
					m[i] = e.z
	var mm := Move.MoveMap.new()
	mm.x0 = x0
	mm.y0 = y0
	mm.w = wd
	mm.h = ht
	mm.cells = PackedByteArray()
	mm.cells.resize(wd * ht)
	for i in wd * ht:
		mm.cells[i] = 1 if W.s8(m[i]) >= 6 else 0xFF
	return mm


## 0x412190: does unit v's own recon see unit u?
static func sees_unit(w: Pd2World, v: int, u: int) -> bool:
	var rp := recon_range(w, v)
	var vp := w.pos(v)
	var up := w.pos(u)
	if rp.x < W.hexdist(vp.x, vp.y, up.x, up.y):
		return false
	return (line_of_sight(w, vp.x, vp.y, up.x, up.y, rp.y, 0, true)
		or line_of_sight(w, vp.x, vp.y, up.x, up.y, rp.y, 1, true))


## 0x47EDC0: mark the other side's units inside v's search map as spotted; returns them.
static func spot_in_map(w: Pd2World, v: int, smap: Move.MoveMap, mode: int) -> Array:
	var side := 3 if w.is_enemy(v) else 0
	var vp := w.pos(v)
	var out := []
	for ly in smap.h:
		for lx in smap.w:
			if smap.at(lx, ly) != 1:
				continue
			var o := w.O[smap.x0 + lx + 72 * (smap.y0 + ly)] - 1
			if o == -1 or w.armour(o) == 3:
				continue
			var f0 := w.ub(o, 0)
			if not mode in [0, 1, 2, 8] or f0 & 0x10 or (3 if w.is_enemy(o) else 0) == side:
				continue
			if mode == 1:
				var conceal := w.cover(o) * (2 if f0 & 0x20 else 1) + 7 * (w.F[w.ub(o, 9) + 72 * w.ub(o, 10)] & 1)
				if conceal >= 10 and W.hexdist(w.ub(o, 9), w.ub(o, 10), vp.x, vp.y) > 2:
					continue
			w.setb(o, 0, f0 | 0x10)
			out.append(o)
	var vg := vp.x + 72 * vp.y
	var climb := w.unit_class(v) >= 2 and mode == 8
	var saved := 0
	if climb:
		saved = w.layer(w.H, vp.x, vp.y)
		w.H[vg] = (saved + 6) & 0xFF
	for o in w.n_units:
		var f0 := w.ub(o, 0)
		if (w.unit_class(o) > 1 and w.active(o) and f0 & 4 and f0 & 8
				and sees_unit(w, v, o) and (3 if w.is_enemy(o) else 0) != side and not (f0 & 0x10)):
			w.setb(o, 0, f0 | 0x10)
			out.append(o)
	if climb:
		w.H[vg] = saved
	return out


## 0x472410: the units that may react to t, in order.
static func reaction_candidates(w: Pd2World, t: int, alert := 0, units := 64) -> Array:
	var out := []
	var st_t := w.sb(t, 0x36)
	var tp := w.pos(t)
	for b in units:
		var st := w.sb(b, 0x36)
		if st == 1 or st == st_t or (st < 3 and st_t < 3):
			continue
		var order := (w.ub(b, 3) >> 4) if alert else (w.ub(b, 3) & 15)
		if st == 0:
			order = 0
		if order == 0xF or not w.active(b) or Move.reaction_weapon(w, b, t) == -1:
			continue
		var bp := w.pos(b)
		if _h(w, tp.x, tp.y) - _h(w, bp.x, bp.y) >= 30:
			continue
		if w.unit_class(t) == 2:
			out.append(b)
		elif W.hexdist(bp.x, bp.y, tp.x, tp.y) <= 2:
			if near_sight(w, b, t):
				out.append(b)
		elif can_see(w, bp.x, bp.y, tp.x, tp.y):
			out.append(b)
	return out
