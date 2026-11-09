class_name Move
extends RefCounted
## AP, the move map, action AP and reaction weapons (rules.py "AP and movement",
## "action AP and reaction fire"; RULES.md section 5).

const W := preload("res://core/world.gd")

const S_MOVE_ROWS := 528
const S_COVER_ROWS := 688
## hex neighbours (dx, dy) by row parity, directions 0-5 (0x47D930)
const NEIGHBOURS := {0: [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0)],
		1: [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 0)]}
const MOVE_HIGH_SPEED := 0
const MOVE_NORMAL := 1
const MOVE_CAREFUL := 2
const MOVE_SEARCH := 3
const MODE_FACTOR := {0: 1, 1: 2, 2: 3}
const MELEE_FLAG := 0x80
const FIRE_NORMAL := 0
const FIRE_AIMED := 1
const FIRE_AA := 6
const REACT_GROUND := 5
const REACT_AIR := 10


## AP per turn (0x450690).
static func max_ap(w: Pd2World, u: int) -> int:
	var crew_ap := W.s8(w.ucrew(u, 9))
	if w.ub(u, 0xC) == 0xFF:
		return crew_ap & 0xFF
	var base := ((w.umachine(u, 0x18) * crew_ap) / 10) & 0xFF
	var lload := 0
	for k in 6:
		var lid := w.ub(u, 0xF + 2 * k)
		if lid != 0xFF:
			var v := w.launcher(W.s8(lid), 7) & 0x1F
			lload += v - 32 if v & 0x10 else v
	var pload := 0
	for p in 12:
		var a := w.ub(u, 0x1B + 2 * p)
		if a == 0xFF:
			continue
		var r0 := w.ammo(W.s8(a), 0)
		var count := w.pocket_count(u, p)
		var load := w.ammo(W.s8(a), 6) & 0x1F
		var d := r0 if r0 < 128 else (r0 - 256) & 0xFFFFFFFF
		if d == 0:
			w.fault = "division by zero (max_ap: round capacity 0)"
			continue
		var part := ((((count * 200) & 0xFFFFFFFF) / d) * load) & 0xFFFFFFFF
		part = (part / 100) & 0xFF
		if W.s8(part) > load:
			part = load
		pload += part
	return (base - lload - pload) & 0xFF


## 0 ground, 1 air (categories 2-5), 2 other (category 9, machine type 12).
static func move_type(w: Pd2World, u: int) -> int:
	var cat := w.umachine(u, 0) & 15
	var t := 2 if cat == 9 else (1 if cat >= 2 and cat <= 5 else 0)
	return 2 if w.ub(u, 0xC) == 12 else t


## 0x47D7E0: the window the move map covers, [x0, y0, w, h].
static func move_box(x: int, y: int, ap: int) -> Array:
	var x0 := maxi(0, x - ap - 1)
	var y0 := maxi(0, y - ap - 1) & 0xFFFE
	var x1 := mini(71, x + ap)
	var y1 := mini(71, y + ap)
	var wd := absi(x1 - x) + absi(x - x0) + 3
	var ht := absi(y1 - y) + absi(y - y0) + 3
	if x0 + wd >= 72:
		wd = 71 - x0
	if y0 + ht >= 72:
		ht = 71 - y0
	return [x0, y0, wd, ht]


## A move map: AP needed to reach each hex (rules.move_map's (x0, y0, w, h, cells)).
class MoveMap:
	var x0: int
	var y0: int
	var w: int
	var h: int
	var cells: PackedByteArray   # h rows of w bytes

	func at(lx: int, ly: int) -> int:
		return cells[ly * w + lx]

	## the cell at map (x, y), or -1 outside the window
	func cell(x: int, y: int) -> int:
		var lx := x - x0
		var ly := y - y0
		if lx < 0 or ly < 0 or lx >= w or ly >= h:
			return -1
		return cells[ly * w + lx]


static func _side(w: Pd2World, o: int) -> int:
	return 3 if w.sb(o, 0x36) >= 3 else 0


## make_move_map() (0x471C40): the game's bucket-queue search bounded by the unit's AP.
## Cells: cost, | 0x80 when entering attacks the enemy there, 0 = own hex, 0xFF = unreachable.
static func move_map(w: Pd2World, u: int, mode: int) -> MoveMap:
	var p := w.pos(u)
	var ap := w.sb(u, 0xE)
	var box := move_box(p.x, p.y, ap)
	var mm := MoveMap.new()
	mm.x0 = box[0]
	mm.y0 = box[1]
	mm.w = box[2]
	mm.h = box[3]
	mm.cells = PackedByteArray()
	mm.cells.resize(mm.w * mm.h)
	var st := {
		"cat": w.umachine(u, 0) & 15, "mtype": move_type(w, u),
		"my_side": 3 if w.is_enemy(u) else 0, "carrying": w.ub(u, 0x34) != 0xFF, "ap": ap,
	}
	st.factor = MODE_FACTOR[mode] * (2 if st.carrying else 1)
	var buckets := []
	for i in 64:
		buckets.append([])
	var sx := p.x - mm.x0
	var sy := p.y - mm.y0
	mm.cells[sy * mm.w + sx] = 0xFF
	_expand(w, mm, st, buckets, sx, sy, 0)
	var level := 0
	var empty := 0
	while level < ap and empty < 64:
		var b: Array = buckets[level & 0x3F]
		if b.is_empty():
			empty += 1
		else:
			empty = 0
			while not b.is_empty():
				var n: Vector2i = b.back()
				if W.s8(mm.cells[n.y * mm.w + n.x]) >= level:
					_expand(w, mm, st, buckets, n.x, n.y, level)
				b.pop_back()
		level += 1
	for i in mm.cells.size():
		if mm.cells[i] == 0:
			mm.cells[i] = 0xFF
	mm.cells[sy * mm.w + sx] = 0
	return mm


static func _expand(w: Pd2World, mm: MoveMap, st: Dictionary, buckets: Array, lx: int, ly: int, cur: int) -> void:
	var x0 := mm.x0
	var y0 := mm.y0
	var h0 := W.s8(w.H[x0 + lx + 72 * (y0 + ly)])
	var mtype: int = st.mtype
	var carrying: bool = st.carrying
	var my_side: int = st.my_side
	for d in NEIGHBOURS[ly & 1]:
		var nx: int = lx + d.x
		var ny: int = ly + d.y
		if not (0 < nx and nx < mm.w and 0 < ny and ny < mm.h):
			continue
		var g := x0 + nx + 72 * (y0 + ny)
		var h := w.H[g]
		var occ := w.O[g] - 1
		var existing := W.s8(mm.cells[ny * mm.w + nx])
		var cost := w.terrain[S_MOVE_ROWS + 16 * st.cat + w.terrain[w.T[g]]] if h else 0
		if existing == -1 or cost == 0:
			continue
		if mtype == 0:
			if w.F[g] & 1:
				cost *= 2
			var dh := h - h0
			if dh < -1 or dh > 1:
				cost = 0
			elif dh == 1:
				cost *= 2
		var c: int = st.factor * cost
		if mtype != 1:
			if c and cur == 0:
				if occ != -1 and _side(w, occ) != my_side:
					if mtype == 0 and not carrying and w.armour(occ) != 4:
						c += 2
					else:
						c = 0
				elif occ != -1 and w.sb(occ, 0x36) == 1:
					c = 0
			elif occ != -1:
				if _side(w, occ) != my_side and w.ub(occ, 0) & 0x10:
					c = 0
				elif w.sb(occ, 0x36) == 1:
					c = 0
		if c:
			c += cur
		if c > st.ap:
			c = 0
		if mtype != 1 and c and cur == 0 and occ != -1 and _side(w, occ) != my_side and w.ub(occ, 0) & 0x10:
			c |= MELEE_FLAG
		if not c:
			continue
		if existing != 0 and (c & 0x7F) >= (existing & 0x7F):
			continue
		mm.cells[ny * mm.w + nx] = c & 0xFF
		buckets[c & 0x3F].append(Vector2i(nx, ny))


## Launcher +8: AP cost in the low 5 bits (signed) (0x47C450).
static func launcher_ap(w: Pd2World, lid: int) -> int:
	var v := w.launcher(lid, 8) & 0x1F
	return v - 32 if v & 0x10 else v


static func fire_ap(w: Pd2World, u: int, slot: int, mode: int) -> int:   # 0x425AF0
	var ap := launcher_ap(w, w.launcher_id(u, slot))
	return 2 * ap if mode == FIRE_AIMED else ap


static func final_attack(w: Pd2World, u: int, slot: int, air: bool) -> int:   # 0x450970 / 0x450900
	var lid := w.launcher_id(u, slot)
	if lid == -1:
		return 0
	var a := w.ammo_id(u, slot)
	return ((w.launcher(lid, 6) + w.ammo(a, 2)) if air else (w.launcher(lid, 3) + w.ammo(a, 1))) & 0xFF


## 0x472790: the slot unit b reacts with against t, or -1.
static func reaction_weapon(w: Pd2World, b: int, t: int) -> int:
	if w.ub(b, 0) & 0x40:
		return -1
	var air := w.unit_class(t) >= 2
	var pb := w.pos(b)
	var pt := w.pos(t)
	var dist := W.hexdist(pb.x, pb.y, pt.x, pt.y)
	var best := -1
	var best_atk := 0
	for k in 4:
		var lid := w.launcher_id(b, k)
		if lid == -1 or w.slot_state(b, k) == 2 or w.slot_count(b, k) == 0:
			continue
		var pk := w.ub(b, 0x10 + 2 * k) & 15
		if w.ub(b, 0x1C + 2 * pk) >> 6 == 2:
			continue
		if not air and not ((w.launcher(lid, 9) & 7) == 1 and w.launcher(lid, 8) >> 5 == 0):
			continue
		if k >= 2 and (w.ub(b, 1) & 0xC0) == 0x80 and (w.ub(b, 2) & 3) == 2:
			continue
		var rng_ := w.weapon_range(b, k)
		var atk := final_attack(w, b, k, air)
		if atk and rng_ >= dist and atk > best_atk:
			best = k
			best_atk = atk
	return best


## The computer side's reaction fire (0x472920). fire.call(b, slot) -> 6 / 2.
static func ai_reactions(w: Pd2World, rng: Pd2Random, reactors: Array, t: int, flag: int, fire: Callable) -> int:
	var result := 0
	var p := t
	var fired := false
	for b in reactors:
		var slot := reaction_weapon(w, b, t)
		if slot == -1:
			continue
		if w.ub(b, 0xD) < 40:
			p = 100
		elif flag:
			p = 80
		else:
			var mm := (w.ub(t, 4) >> 4) & 3
			p = 90 if mm == 0 else (75 if mm == 1 else (60 if mm == 2 else p))
		if rng.r16(100) <= p:
			fired = true
			result |= int(fire.call(b, slot))
			if result >= 4:
				break
	if fired and t >= 0 and t < 40:      # the AI remembers where it shot at t
		w.memory[3 * t] = w.ub(t, 9)
		w.memory[3 * t + 1] = w.ub(t, 10)
	return result


static func evasion_ap(w: Pd2World, t: int) -> int:
	var mm := (w.ub(t, 4) >> 4) & 3
	var cost := 4 if mm == 0 else (2 if mm == 1 else (1 if mm == 2 else 2))
	return cost * (2 if w.ub(t, 0x34) != 0xFF else 1)
