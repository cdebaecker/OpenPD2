class_name Flight
extends RefCounted
## The group flight engine (Pd2.exe 0x43BDB0 and its routines), the radar map and the
## radio chatter, ported from rules.py and checked against the game by emulation
## (verify_flight, verify_air_fight, verify_radio, verify_radar, verify_radar_sweep,
## verify_flight_turn). Groups are 35-byte records (DS:0x50A35C): +2 flags (bits 4-5
## state: 0 waiting, 1 flying, 2 holding, 3 leaving; bits 6-7 sub-state), +5 member
## count, +6.. 16 members, +0x16/+0x17 position on the 15 x 15 grid, +0x18/+0x19 drop
## point, +0x1A/+0x1B target (x = 0xFF: follow group +0x1B), +0x1C step price, +0x1D
## arrival turn (s16), +0x1F seen, +0x20 counter, +0x21 type (high nibble), +0x22 step.

const W := preload("res://core/world.gd")
const AI_ABORT := [0x10000, 0x20000, 0x40000]
const UNITS := 0x506C93
const GROUPS := 0x50A35C
const CREWS := 0x506734
const MACHS := 0x50ADF5
const LAUNS := 0x50B1D5
const AMMOS := 0x50B835
const RADIO_SIGNS := 0x50C7E5
const RADIO_NUM_FORMAT := {0xC: 0x518B00, 0xD: 0x518B04, 0xE: 0x518B08, 0xF: 0x518B0C, 0x10: 0x518B10}
const RADIO_PAIRS := {7: [[0x65, 0x66], [0x63, 0x64], 3], 8: [[0x69, 0x6A], [0x67, 0x68], 3],
		9: [[0x6D, 0x6E], [0x6B, 0x6C], 3], 10: [[0x71, 0x72], [0x6F, 0x70], 4],
		0xB: [[0x75, 0x76], [0x73, 0x74], 4]}


## What the flight engine leaves to others (rules.FlightHooks). radio, air_fight,
## air_anim and flight_turn stand for whole game functions: null (the default) runs the
## port, anything else is taken as that function's result. The others are windows:
## 0 or an abort code. easy: option DS:0x551D29 bit 1 (the air fight's melee).
class Hooks:
	var easy := false

	func radio(kind: int, rec: Variant, arg: int) -> Variant:      # 0x4896C0
		return null

	func air_fight(g: int) -> Variant:                               # 0x441130
		return null

	func air_anim(a: Vector2i, b: Vector2i) -> Variant:             # 0x441D70
		return null

	func flight_turn() -> Variant:                                   # 0x43BDB0, from a speech hook
		return null

	func air_anim_draw(a: Vector2i, b: Vector2i) -> int:            # 0x441D70 past the radar check
		return 0

	func air_report() -> int:                                        # 0x43E9D0, the status panel
		return 0

	func radar_window(param: int) -> int:                            # 0x43E510's windows
		return 0

	func radar_draw() -> int:                                        # 0x43F150 with the radar open
		return 0

	func radar_check() -> int:                                       # 0x43CC90's window checks
		return 0

	func radar_ping(x: int, y: int) -> int:                          # 0x48BA40: a contact shown
		return 0

	func radio_face(a: Variant, code: Variant, b: Variant) -> int:   # 0x488DE0: a talk window
		return 0

	func radio_say(msg: int, args: Array, code: Variant) -> int:     # a radio line (0x489140)
		return 0

	func radio_close(n: int) -> int:                                 # 0x489390
		return 0

	func use_weapon(a: int, pocket: int) -> bool:                    # the melee's weapon prompt
		return true

	func pump() -> int:                                              # 0x4521C0: window messages
		return 0


# --- memory as the game addresses it -------------------------------------------------

static func gb(w: Pd2World, g: int, f: int) -> int:
	return w.mem8(GROUPS + 35 * g + f)


static func setgb(w: Pd2World, g: int, f: int, v: int) -> void:
	w.mem_write(GROUPS + 35 * g + f, v)


static func ub(w: Pd2World, k: int, f: int) -> int:
	return w.mem8(UNITS + 55 * k + f)


static func s8(v: int) -> int:
	return W.s8(v)


static func s16(v: int) -> int:
	v &= 0xFFFF
	return v - 0x10000 if v >= 0x8000 else v


static func gpos(w: Pd2World, g: int) -> Vector2i:
	return Vector2i(s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)))


# --- the group helpers --------------------------------------------------------------

## 0x441FF0: group g's members that are not 0xFF, have condition and are not destroyed.
static func group_alive(w: Pd2World, g: int) -> int:
	var n := 0
	for i in 16:
		var k := gb(w, g, 6 + i)
		if k != 0xFF and ub(w, k, 0xD) and not ub(w, k, 0) & 1:
			n += 1
	return n


## 0x441FB0: OR bits into the flight grid at (x, y), both in 0-14.
static func grid_mark(w: Pd2World, x: int, y: int, bits: int) -> void:
	if x >= 0 and x < 15 and y >= 0 and y < 15:
		w.grid[y * 16 + x] |= bits


## 0x440310: a type-3 group none of whose members (slots not 0) with condition carries a
## launcher with a pocket round of non-zero ground attack becomes type 4.
static func group_disarmed(w: Pd2World, g: int) -> void:
	if gb(w, g, 0x21) & 0xF0 != 0x30:
		return
	for i in 16:
		var k := gb(w, g, 6 + i)
		if k == 0 or not ub(w, k, 0xD):
			continue
		for sl in 6:
			var lid := s8(ub(w, k, 0xF + 2 * sl))
			if lid == -1:
				continue
			var am := s8(ub(w, k, 0x1B + 2 * (ub(w, k, 0x10 + 2 * sl) & 15)))
			if am != -1 and (w.mem8(AMMOS + 12 * am + 1) + w.mem8(LAUNS + 17 * lid + 3)) & 0xFF:
				return
	setgb(w, g, 0x21, (gb(w, g, 0x21) & 0xF) | 0x40)


## 0x43C560: 1 at its target point, or (following t) at t's position, or t gone.
static func group_at_goal(w: Pd2World, g: int) -> int:
	if gb(w, g, 0x1A) == 0xFF:
		var t := s8(gb(w, g, 0x1B))
		if s8(gb(w, t, 0x16)) < 0 or not group_alive(w, t):
			return 1
		return 1 if gb(w, g, 0x16) == gb(w, t, 0x16) and gb(w, g, 0x17) == gb(w, t, 0x17) else 0
	return 1 if gb(w, g, 0x16) == gb(w, g, 0x1A) and gb(w, g, 0x17) == gb(w, g, 0x1B) else 0


## 0x43CC30: a follower whose leader is off the map or dead holds where it is (0), else 1.
static func group_follow_check(w: Pd2World, g: int) -> int:
	if gb(w, g, 0x1A) != 0xFF:
		return 1
	var t := s8(gb(w, g, 0x1B))
	if s8(gb(w, t, 0x16)) >= 0 and group_alive(w, t):
		return 1
	setgb(w, g, 0x1C, 0)
	setgb(w, g, 0x1A, gb(w, g, 0x16))
	setgb(w, g, 0x18, gb(w, g, 0x16))
	setgb(w, g, 0x22, 0)
	setgb(w, g, 0x1B, gb(w, g, 0x17))
	setgb(w, g, 0x19, gb(w, g, 0x17))
	setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
	return 0


# --- the radar map and the radio chatter ---------------------------------------------

## 0x43F150: with the radar closed it clears the grid; else it draws it.
static func radar_redraw(w: Pd2World, hooks: Hooks) -> int:
	if not w.radar:
		w.grid.fill(0)
		return 0
	return hooks.radar_draw()


## 0x43E510, the radar map: a cleared grid the first time, groups marked, DS:0x50DD44 = 1.
static func grid_init(w: Pd2World, hooks: Hooks, param := 0) -> int:
	var res := hooks.radar_window(param)
	if res in AI_ABORT:
		return res
	if not w.radar:
		w.grid.fill(0)
	for g in 64:
		if (g > 11 or g & 1 or gb(w, g, 2) & 0x30) and gb(w, g, 0x16) != 0xFF and group_alive(w, g):
			grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 1)
	w.radar = 1
	res = radar_redraw(w, hooks)
	if res in AI_ABORT:
		return res
	res = hooks.air_report()
	return res if res in AI_ABORT else 0


## 0x48B880: one of the lines.
static func _radio_pick(rng: Pd2Random, items: Array) -> int:
	if rng.r16(10) < 5 or items.size() == 1:
		return items[0]
	if items.size() == 2:
		return items[1]
	return items[1 + rng.r16(items.size() - 1)]


## 0x4538A0: machines[m] +0 low nibble: 0 -> 0; 1, 6, 7, 8 -> 1; 9 -> 3; else 2.
static func _machine_class(w: Pd2World, m: int) -> int:
	var c := w.mem8(MACHS + 31 * m) & 0xF
	if c == 0:
		return 0
	if c in [1, 6, 7, 8]:
		return 1
	return 3 if c == 9 else 2


## 0x489510 on record R: [special, face, voice] (face null, voice "rec" when unset).
static func _radio_speaker(w: Pd2World, rng: Pd2Random, R: Callable) -> Array:
	var k := 0xFF
	for i in 16:
		if R.call(6 + i) != 0xFF:
			k = R.call(6 + i)
			break
	if k == 0xFF:
		return [0, null, "rec"]
	var v := s8(w.mem8(CREWS + 16 * k))
	var face := 0
	if v == 0 or (v > 1 and v < 0x10):
		face = 0xD
	elif v == 1:
		face = 10
	elif v == 0x10:
		face = rng.r16(2) + 0xB
	elif v > 0x10 and v < 0x16:
		face = rng.r16(2) + 0xE
	elif v >= 0x16 and v < 0x1D:
		face = v - 0x16
	elif v in [0x1D, 0x20, 0x22]:
		face = 5
	elif v in [0x1E, 0x24]:
		face = 0x10
	elif v in [0x1F, 0x21, 0x23]:
		face = 6
	var m := s8(ub(w, k, 0xC))
	var c := _machine_class(w, m)
	var voice: Variant = "rec"
	if c == 0:
		voice = 12 if rng.r16(2) else 3
	elif c == 1:
		voice = 0x10
	elif c == 3:
		voice = 0xB
	elif m == 7:
		voice = 0x12
	elif m == 8:
		voice = [9, 10, 14, 15][rng.r16(100) & 3]
	elif m == 9:
		voice = 7 + (rng.r16(100) & 1)
	elif m == 10:
		voice = 5 + (rng.r16(100) & 1)
	elif m == 12:
		voice = 0xB
	var special := 1 if voice is int and voice >= 0xC and voice < 0x11 else 0
	return [special, face, voice]


## 0x488DE0: a talk window; with the radar closed it first opens it.
static func _radio_face(w: Pd2World, hooks: Hooks, a: Variant, code: Variant, b: Variant) -> int:
	if not w.radar:
		var res := grid_init(w, hooks, 0)
		if res in AI_ABORT:
			return res
	return hooks.radio_face(a, code, b)


## 0x48B460: the speakers of a line: [mode or abort, code, code2, face, voice].
static func _radio_speak(w: Pd2World, rng: Pd2Random, R: Callable, hooks: Hooks, items: Array) -> Array:
	var sp := _radio_speaker(w, rng, R)
	var special: int = sp[0]
	var face: Variant = sp[1]
	var voice: Variant = sp[2]
	var k: int = items[rng.r16(items.size())]
	var code: Variant = null
	var code2: Variant = null
	var res := 0
	if k == 0:
		code = 10 + (1 if rng.r16(2) else 0)
		code |= 0x10 if special == 1 else 0x20
		res = _radio_face(w, hooks, face, code, 0)
		if res in AI_ABORT:
			hooks.radio_close(-1)
			return [res, code, code2, face, voice]
		res = _radio_face(w, hooks, voice, code, 1)
	elif k == 1:
		rng.r16(2)
		code = 10 | (0x10 if special == 1 else 0x30)
		code2 = 0xB
		res = _radio_face(w, hooks, voice, code, 1)
	elif k == 2:
		if rng.r16(2):
			code = 10
			code2 = 0xB
		else:
			code = 0xB
			code2 = 10
		code2 |= 0x10 if special == 1 else 0x30
		res = _radio_face(w, hooks, face, code, null)
	elif k == 3:
		code = 10 if rng.r16(2) else 0xB
		res = _radio_face(w, hooks, face, code, null)
	else:
		code = 10 + (1 if rng.r16(2) else 0)
		code |= 0x10 if special == 1 else 0x30
		res = _radio_face(w, hooks, voice, code, 1)
	if res in AI_ABORT:
		hooks.radio_close(-1)
		return [res, code, code2, face, voice]
	return [k, code, code2, face, voice]


## 0x48B6E0: the answer's window.
static func _radio_second(w: Pd2World, hooks: Hooks, sp: Array) -> int:
	var mode: int = sp[0]
	if mode != 1 and mode != 2:
		return 0
	var res := _radio_face(w, hooks, sp[3] if mode == 1 else sp[4], sp[2], 0 if mode == 1 else 1)
	if res in AI_ABORT:
		hooks.radio_close(-1)
		return res
	return 0


## 0x48B740: [how many, the first] of groups 0, 2, 4 holding with someone on the map;
## else [1, index - 1] for the first of groups 1, 3, .., 11 flying or holding; else [0, -1].
static func _radio_group(w: Pd2World) -> Array:
	var n := 0
	var first := -1
	for g in [0, 2, 4]:
		if group_alive(w, g) and gb(w, g, 2) & 0x30 == 0x20:
			var out := false
			for i in 16:
				var k := gb(w, g, 6 + i)
				if k != 0xFF and ub(w, k, 9) != 0xFF:
					out = true
			if out:
				n += 1
				if first == -1:
					first = g
	if n:
		return [n, first]
	for g in range(0, 12, 2):
		if group_alive(w, g + 1) and gb(w, g + 1, 2) & 0x30 in [0x10, 0x20]:
			return [1, g]
	return [0, -1]


## 0x4896C0, the radio chatter for event kind of a group record (an index, or a 35-byte
## copy for kind 9). Lines go to hooks.radio_say(message, args, code), args being
## ["sign", n], ["time", t, d] or ["num", format, arg]. Returns 0 or an abort code.
static func radio(w: Pd2World, rng: Pd2Random, kind: int, rec: Variant, hooks: Hooks, arg := 0) -> int:
	var g := -1
	var R: Callable
	if rec is int:
		g = rec
		if g >= 20 or (kind != 9 and not group_alive(w, g)):
			return 0
		R = func(o: int) -> int: return gb(w, g, o)
	else:
		var data: PackedByteArray = rec
		R = func(o: int) -> int: return data[o]
	if kind > 0x11:
		return 0
	var r := _Radio.new(w, rng, R, hooks)
	if kind == 0 or kind == 1:
		var n0 := 0
		var n1 := 0
		var nf := 0
		var holding: bool = R.call(2) & 0x30 == 0x20 and not R.call(2) & 0xC0
		for e in 20:
			if not group_alive(w, e):
				continue
			var t := gb(w, e, 0x21) & 0xF0
			if t == 0 and holding:
				n0 += 1
			if t == 0x10 and holding:
				n1 += 1
			for i in 16:
				var k := gb(w, e, 6 + i)
				if k != 0xFF and ub(w, k, 0) & 8:
					nf += 1
		if kind == 0:
			return r.kind0(n0, n1, nf)
		return r.kind1(n0, n1, nf)
	if kind == 2:
		var i := _radio_pick(rng, [0x1A, 0x1C, 0x1E])
		var sp := r.speak([1, 2])
		if sp[0] in AI_ABORT:
			return r.abort(sp[0])
		var first: Array = [r.csign(1), r.csign(-0x22)] if i in [0x1A, 0x1C] else [r.csign(-0x22)]
		var second: Array = [r.csign(1)] if i in [0x1A, 0x1C] else [r.csign(1), r.csign(-0x22)]
		var res := hooks.radio_say(i + 0x20, first, sp[1])
		if res in AI_ABORT:
			return r.abort(res)
		res = _radio_second(w, hooks, sp)
		if res in AI_ABORT:
			return r.abort(res)
		return r.final(hooks.radio_say(i + 0x21, second, sp[2]))
	if kind == 3 or kind == 4:
		var nt := _radio_group(w)
		if nt[0]:
			var i := _radio_pick(rng, [0x20, 0x22, 0x24, 0x26] if kind == 3 else [0x2B, 0x2D, 0x2F, 0x31])
			var sp := r.speak([1, 2])
			if sp[0] in AI_ABORT:
				return r.abort(sp[0])
			var res := hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(nt[1])], sp[1])
			if res in AI_ABORT:
				return r.abort(res)
			res = _radio_second(w, hooks, sp)
			if res in AI_ABORT:
				return r.abort(res)
			var when := ["time", s8(R.call(0x20)) + w.mission_turn, w.ds_506651]
			return r.final(hooks.radio_say(i + 0x21, [when], sp[2]))
		var i := _radio_pick(rng, [0x28, 0x29, 0x2A] if kind == 3 else [0x33, 0x34, 0x35])
		var sp := r.speak([4])
		if sp[0] in AI_ABORT:
			return r.abort(sp[0])
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], sp[1]))
	if kind == 5:
		var i := _radio_pick(rng, [0x36, 0x37, 0x38])
		var sp := r.speak([4])
		if sp[0] in AI_ABORT:
			return r.abort(sp[0])
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], sp[1]))
	if kind == 6:
		var nt := _radio_group(w)
		if not nt[0]:
			var i := _radio_pick(rng, [0x39, 0x3A, 0x3B])
			var sp := r.speak([0])
			if sp[0] in AI_ABORT:
				return r.abort(sp[0])
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], sp[1]))
		var i := _radio_pick(rng, [0x3C, 0x3E, 0x40])
		var sp := r.speak([1, 2])
		if sp[0] in AI_ABORT:
			return r.abort(sp[0])
		var res := 0
		if i == 0x3E:
			res = hooks.radio_say(0x5E, [r.tsign(nt[1])], sp[1])
		else:
			res = hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(nt[1])], sp[1])
		if res in AI_ABORT:
			return r.abort(res)
		res = _radio_second(w, hooks, sp)
		if res in AI_ABORT:
			return r.abort(res)
		return r.final(hooks.radio_say(i + 0x21, [], sp[2]))
	if RADIO_PAIRS.has(kind):
		var pr: Array = RADIO_PAIRS[kind]
		var a := _radio_pick(rng, pr[0])
		var b := _radio_pick(rng, pr[1])
		var sp := r.speak([pr[2]])                  # 0x48B8F0
		if sp[0] in AI_ABORT:
			hooks.radio_close(-1)
			return r.abort(sp[0])
		var nt := _radio_group(w)
		var res := 0
		if nt[0]:
			res = hooks.radio_say(b + 0x20, [r.csign(1), r.tsign(nt[1])], sp[1])
		else:
			res = hooks.radio_say(a + 0x20, [r.csign(1)], sp[1])
		hooks.radio_close(-1)
		if res in AI_ABORT:
			return r.abort(res)
		return 0
	var nt := _radio_group(w)
	var n: int = nt[0]
	var t: int = nt[1]
	if kind == 0x11:
		var sp := r.speak([1, 2])
		if sp[0] in AI_ABORT:
			return r.abort(sp[0])
		if n:
			var i := _radio_pick(rng, [0x77, 0x78])
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(t)], sp[1]))
		var i := _radio_pick(rng, [0x79, 0x7A])
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], sp[1]))
	var sp := r.speak([0, 4])
	if sp[0] in AI_ABORT:
		return r.abort(sp[0])
	var code: Variant = sp[1]
	var num := ["num", RADIO_NUM_FORMAT[kind], arg]
	var i := 0
	if kind == 0xC:
		if not n:
			i = _radio_pick(rng, [0x5A, 0x5B, 0x5C])
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1), num], code))
		i = _radio_pick(rng, [0x57, 0x58, 0x59])
		if i == 0x58:
			return r.final(hooks.radio_say(0x78, [r.csign(1), num], code))
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(t)], code))
	if kind == 0xD:
		if group_alive(w, g - 1) and R.call(-0x21) & 0x30 == 0x20:
			i = _radio_pick(rng, [0x42, 0x43, 0x44])
			if i == 0x44:
				return r.final(hooks.radio_say(0x64, [num], code))
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], code))
		if n:
			i = _radio_pick(rng, [0x45, 0x46, 0x47])
			if i == 0x47:
				return r.final(hooks.radio_say(0x67, [num], code))
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(t), num], code))
		i = _radio_pick(rng, [0x48, 0x49, 0x4A])
		if i == 0x4A:
			return r.final(hooks.radio_say(0x6A, [num], code))
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], code))
	if kind == 0xE:
		if not n:
			i = _radio_pick(rng, [0x4E, 0x4F, 0x50])
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1)], code))
		i = _radio_pick(rng, [0x4B, 0x4C, 0x4D])
		if i == 0x4B:
			return r.final(hooks.radio_say(0x6B, [r.csign(1), r.tsign(t)], code))
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1), num], code))
	if kind == 0xF:
		if n:
			i = _radio_pick(rng, [0x51, 0x52, 0x53])
			return r.final(hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(t)], code))
		i = _radio_pick(rng, [0x54, 0x55, 0x56])
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1), num], code))
	if n:                                           # 0x10
		i = _radio_pick(rng, [0x5D, 0x5E, 0x5F])
		if i == 0x5F:
			return r.final(hooks.radio_say(0x7F, [r.csign(1), num], code))
		return r.final(hooks.radio_say(i + 0x20, [r.csign(1), r.tsign(t)], code))
	i = _radio_pick(rng, [0x60, 0x61, 0x62])
	return r.final(hooks.radio_say(i + 0x20, [r.csign(1), num], code))


## The radio's shared steps (its closes, its call signs, kinds 0 and 1).
class _Radio:
	var w: Pd2World
	var rng: Pd2Random
	var R: Callable
	var hooks: Hooks

	func _init(w_: Pd2World, rng_: Pd2Random, R_: Callable, hooks_: Hooks) -> void:
		w = w_
		rng = rng_
		R = R_
		hooks = hooks_

	func csign(o: int) -> Array:
		return ["sign", R.call(o)]

	func tsign(t: int) -> Array:
		return ["sign", Flight.gb(w, t, 1)]

	func final(res: int) -> int:                  # after the last line: one close
		hooks.radio_close(-1)
		return res if res in AI_ABORT else 0

	func abort(res: int) -> int:
		hooks.radio_close(-1)
		return res

	func speak(items: Array, who := Callable()) -> Array:
		return Flight._radio_speak(w, rng, who if who.is_valid() else R, hooks, items)

	func kind0(n0: int, n1: int, nf: int) -> int:
		if nf or (not n0 and n1):
			if n0:
				return 0
			var sp := speak([4])
			if sp[0] in AI_ABORT:
				return abort(sp[0])
			var i := Flight._radio_pick(rng, [0xD, 0xE])
			return final(hooks.radio_say(i + 0x20, [csign(1), csign(-0x22)], sp[1]))
		if n0:
			return 0
		var i := Flight._radio_pick(rng, [1, 3, 5, 7, 9, 0xB])
		var sp := speak([2])
		if sp[0] in AI_ABORT:
			return abort(sp[0])
		var res := 0
		if i == 9:
			res = hooks.radio_say(i + 0x20, [csign(-0x22)], sp[1])
		else:
			res = hooks.radio_say(i + 0x20, [csign(1), csign(-0x22)], sp[1])
		if res in AI_ABORT:
			return abort(res)
		res = Flight._radio_second(w, hooks, sp)
		if res in AI_ABORT:
			return abort(res)
		return final(hooks.radio_say(i + 0x21, [csign(-0x22)], sp[2]))

	func kind1(n0: int, n1: int, nf: int) -> int:
		if nf or n0:
			if n1:
				return 0
			var sp := speak([4])
			if sp[0] in AI_ABORT:
				return abort(sp[0])
			var i := Flight._radio_pick(rng, [0x18, 0x19])
			return final(hooks.radio_say(i + 0x20, [csign(1), csign(-0x22)], sp[1]))
		if n1:
			return 0
		var sp := speak([4])
		if sp[0] in AI_ABORT:
			return abort(sp[0])
		var res := 0
		if rng.r16(10) < 5:
			res = hooks.radio_say(0x2F, [csign(-0x22)], sp[1])
		else:
			res = hooks.radio_say(0x30 + rng.r16(2), [csign(1), csign(-0x22)], sp[1])
		if res in AI_ABORT:
			return abort(res)
		hooks.radio_close(-1)
		var prev := func(o: int) -> int: return R.call(o - 0x23)     # the group before
		sp = speak([1], prev)
		if sp[0] in AI_ABORT:
			return abort(sp[0])
		var i := Flight._radio_pick(rng, [0x12, 0x14, 0x16])
		res = hooks.radio_say(i + 0x20, [], sp[1])
		if res in AI_ABORT:
			return abort(res)
		res = Flight._radio_second(w, hooks, sp)
		if res in AI_ABORT:
			return abort(res)
		return final(hooks.radio_say(i + 0x21, [], sp[2]))


## The flight engine's call of the radio: hooks.radio may stand for it.
static func _radio(w: Pd2World, rng: Pd2Random, kind: int, rec: Variant, hooks: Hooks, arg := 0) -> int:
	var res: Variant = hooks.radio(kind, rec, arg)
	if res == null:
		res = radio(w, rng, kind, rec, hooks, arg)
	return res


## 0x43D350: the last group of lst in state (holding ones also with sub-state sub), or -1.
static func _radar_watcher(w: Pd2World, state: int, sub: int, lst: Array) -> int:
	for j in range(lst.size() - 1, -1, -1):
		var g: int = lst[j]
		var f := gb(w, g, 2)
		if f & 0x30 == 0x20:
			if (f >> 4) & 3 == state and f >> 6 == sub:
				return g
		elif (f >> 4) & 3 == state:
			return g
	return -1


## 0x43CC90, the radar sweep (rules.radar_detect).
static func radar_detect(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	var res := hooks.radar_check()
	if res in AI_ABORT:
		return res
	var watch := []
	for g in 20:
		var f := gb(w, g, 2)
		var on := gb(w, g, 0x16) != 0xFF
		if (f & 0xE in [6, 8] and f & 0x30 in [0x10, 0x20] and on and group_alive(w, g) > 0) or \
				(gb(w, g, 0x21) & 0xF0 in [0x40, 0x90] and f & 0x30 == 0x30 and on and group_alive(w, g) > 0):
			watch.append(g)
	var seen := []
	for g in range(20, 64):
		var st := gb(w, g, 2) & 0x30
		if not gb(w, g, 0x1F) and gb(w, g, 2) & 0xE == 6 and st >= 0x10 and st <= 0x30 \
				and gb(w, g, 0x16) != 0xFF and group_alive(w, g):
			seen.append(g)
	if watch.is_empty() or seen.is_empty():
		return 0
	var d := -1
	for p in [[2, 0], [1, 0], [2, 1], [2, 2]]:
		d = _radar_watcher(w, p[0], p[1], watch)
		if d >= 0:
			break
	if d < 0:
		return 0
	if not w.radar:
		res = grid_init(w, hooks, 0)
		if res in AI_ABORT:
			return res
	var spots := []
	for g in seen:
		var p := gpos(w, g)
		if not p in spots:
			spots.append(p)
	for p in spots:
		res = hooks.radar_ping(p.x, p.y)
		if res in AI_ABORT:
			return res
	var total := 0
	for g in seen:
		setgb(w, g, 0x1F, 1)
		total += group_alive(w, g)
	var t := gb(w, d, 0x21) & 0xF0
	if t in [0, 0x10, 0x20, 0x60]:
		res = _radio(w, rng, 0xD, d, hooks, total)
	elif t == 0x30:
		res = _radio(w, rng, 0xE, d, hooks, total)
	elif t in [0x40, 0x90]:
		var st := gb(w, d, 2) & 0x30
		if st == 0x10 or (st == 0x20 and not gb(w, d, 2) & 0xC0):
			res = _radio(w, rng, 0xC, d, hooks, total)
			if res in AI_ABORT:
				return res
			setgb(w, d, 2, (gb(w, d, 2) & 0xF) | 0xA0)
			if gb(w, d, 0x21) & 0xF0 == 0x90:
				setgb(w, d, 0x21, (gb(w, d, 0x21) & 0xF) | 0x40)
			var best := 30000
			var near := 0
			for g in seen:
				var a := gpos(w, d)
				var b := gpos(w, g)
				var dist := Ai.grid_distance(a.x, a.y, b.x, b.y)
				if dist < best:
					best = dist
					near = g
			setgb(w, d, 0x1A, 0xFF)
			setgb(w, d, 0x1B, near)
			setgb(w, d, 0x22, 0)
			return 0
		elif st == 0x20:
			res = _radio(w, rng, 0xF, d, hooks, total)
		elif st == 0x30:
			res = _radio(w, rng, 0x10, d, hooks, total)
		else:
			return 0
	else:
		return 0
	return res if res in AI_ABORT else 0


## 0x441D70: with the radar closed it first opens it; the rest is display.
static func _air_anim(w: Pd2World, hooks: Hooks, a: Vector2i, b: Vector2i) -> int:
	var res: Variant = hooks.air_anim(a, b)
	if res != null:
		return res
	if not w.radar:
		var r := grid_init(w, hooks, 0)
		if r in AI_ABORT:
			return r
	return hooks.air_anim_draw(a, b)


static func _air_fight(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks) -> int:
	var res: Variant = hooks.air_fight(g)
	if res == null:
		res = air_fight(w, rng, g, hooks, hooks.easy)
	return res


# --- the flight routines ----------------------------------------------------------

## 0x440240: a group whose counter ran out turns back to one of its side's three points.
static func group_timeout(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks) -> int:
	if gb(w, g, 0x20):
		return 0
	var st := gb(w, g, 2) & 0x30
	if not (st == 0x10 or (st == 0x20 and not gb(w, g, 2) & 0xC0)):
		return 0
	setgb(w, g, 2, gb(w, g, 2) | 0x30)
	var k := rng.r16(3) * 4
	if g < 20:
		Ai.group_retarget(w, g, w.ds8(0x50AD99 + k), w.ds8(0x50AD9B + k))
		if gb(w, g, 0x21) & 0xF0 in [0x30, 0x40]:
			var res := _radio(w, rng, 0x11, g, hooks)
			if res in AI_ABORT:
				return res
		return 0
	Ai.group_retarget(w, g, w.ds8(0x50ADA5 + k), w.ds8(0x50ADA7 + k))
	return 0


## 0x43C3C0: does waiting group g show up this turn? 1 / 0, or 0x10000 (speed error).
static func group_appears(w: Pd2World, g: int) -> int:
	if gb(w, g, 2) & 0x30 or not gb(w, g, 5) or s16(gb(w, g, 0x1D) | gb(w, g, 0x1E) << 8) < 0:
		return 0
	if g < 12 and g % 2 == 0 and gb(w, g, 3) & 1:
		return 0
	var d := Ai.grid_distance(s8(gb(w, g, 0x18)), s8(gb(w, g, 0x19)), s8(gb(w, g, 0x1A)), s8(gb(w, g, 0x1B)))
	if d == 0:
		var arr0 := gb(w, g, 0x1D) | gb(w, g, 0x1E) << 8
		return 1 if w.mission_turn >= arr0 and arr0 != 0xFFFF else 0
	var src := g
	if gb(w, g, 0x21) & 0xF0 == 0x90 and group_alive(w, 2 * g - 23):
		src = 2 * g - 23
	var speed := 30000
	for i in 16:
		var k := gb(w, src, 6 + i)
		if k == 0xFF:
			continue
		var m := ub(w, k, 0xC)
		if m == 0xFF:
			continue
		var sp := w.mem8(MACHS + 31 * s8(m) + 1)
		if sp < speed:
			speed = sp
	if speed == 30000:
		return 0x10000
	if speed == 0:
		if not w.safe_hit("D3", "flight time: machine speed 0 (the game divides by zero): taken as 1"):
			w.fault = "division by zero (machine speed 0)"
			return 0
		speed = 1
	var n := (d + speed - 1) / speed
	var arr := s16(gb(w, src, 0x1D) | gb(w, src, 0x1E) << 8)
	if arr - n < 0:
		return 1
	return 1 if w.mission_turn >= (arr - n) & 0xFFFF else 0


static func _support_ready(w: Pd2World, g: int) -> bool:
	for i in 16:
		var k := gb(w, g, 6 + i)
		if k != 0xFF and ub(w, k, 6) in [1, 2] and ub(w, k, 7) == 0xFF:
			return false
	return true


## 0x43FC90: what a group does at its goal, by state and type (rules.group_arrive).
static func group_arrive(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks) -> int:
	var bl := gb(w, g, 2)
	var st := bl & 0x30
	if st == 0x30:
		grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 0x80)
		setgb(w, g, 0x16, 0xFF)
		for j in 64:
			if j == g or not group_alive(w, j):
				continue
			if gb(w, j, 0x16) != 0xFF and gb(w, j, 0x1A) == 0xFF and s8(gb(w, j, 0x1B)) == g:
				Ai.group_retarget(w, j, gb(w, j, 0x16), gb(w, j, 0x17))
				if gb(w, j, 2) & 0x30 == 0x20:
					setgb(w, j, 2, gb(w, j, 2) & 0x3F)
		return 0
	var t := gb(w, g, 0x21) >> 4
	if t == 0 or t == 1:
		if st != 0x10:
			return 0
		var res := _radio(w, rng, t, g, hooks)
		if res in AI_ABORT:
			return res
		var f := gb(w, g, 2)
		setgb(w, g, 2, (((((f & 0xF0) + 0x10) & 0xFF) ^ (f & 0xF)) & 0x3F))
		var e := W.cdiv(g - 1, 2) + 12
		if gb(w, e, 0x21) & 0xF0 != 0x90 or not group_alive(w, e):
			return 0
		setgb(w, e, 0x18, gb(w, e, 0x16))
		setgb(w, e, 0x19, gb(w, e, 0x17))
		setgb(w, e, 0x21, (gb(w, e, 0x21) & 0xF) | 0x40)
		var dy := -1 if w.ds16(0x50AD97) >= 8 else 1
		Ai.group_retarget(w, e, w.ds8(0x50AD95), (w.ds8(0x50AD97) + dy) & 0xFF)
		return 0
	if t == 2:
		var res := _radio(w, rng, 2, g, hooks)
		if res in AI_ABORT:
			return res
		setgb(w, g, 2, gb(w, g, 2) | 0x30)
		Ai.group_retarget(w, g, -1, 0)
		var p := g - 1
		setgb(w, p, 2, (gb(w, p, 2) & 0xF) | 0x20)
		setgb(w, p, 0x16, gb(w, g, 0x16))
		setgb(w, p, 0x18, gb(w, g, 0x16))
		setgb(w, p, 0x21, 0x50)
		setgb(w, p, 0x17, gb(w, g, 0x17))
		setgb(w, p, 0x19, gb(w, g, 0x17))
		for i in 16:
			var k := gb(w, p, 6 + i)
			if k != 0xFF and ub(w, k, 0xD):
				var base := UNITS + 55 * k
				w.mem_write(base, w.mem8(base) | 8)
				w.mem_write(base + 9, 0xFF)
				w.mem_write(base + 10, 0xFF)
		return 0
	if (t == 3 or t == 4) and st == 0x10 and not bl & 0xC0:
		var res := _radio(w, rng, t, g, hooks)
		if res in AI_ABORT:
			return res
		setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
		return 0
	if t == 3:
		if s8(gb(w, g, 0x16)) == w.ds16(0x50AD95) and s8(gb(w, g, 0x17)) == w.ds16(0x50AD97):
			setgb(w, g, 2, (bl & 0xF) | 0xA0)
			return 0
		if _support_ready(w, g):
			setgb(w, g, 2, (bl & 0xF) | 0x20)
		return 0
	if t == 4:
		if gb(w, g, 0x1A) != 0xFF:
			if _support_ready(w, g):
				setgb(w, g, 2, (bl & 0xF) | 0x20)
			return 0
		var tg := s8(gb(w, g, 0x1B))
		if not group_alive(w, tg):
			if gb(w, g, 2) & 0x30 == 0x30:
				return 0
			setgb(w, g, 0x1A, gb(w, g, 0x16))
			setgb(w, g, 0x1B, gb(w, g, 0x17))
			setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
			return 0
		var tf := gb(w, tg, 2) & 0xE
		var tt := gb(w, tg, 0x21) & 0xF0
		var fight := false
		if g < 20:
			fight = tf == 6 and tt in [0x30, 0x40]
		else:
			fight = tf < 6 and tt in [0, 0x10, 0x90, 0x30, 0x40]
		if not fight:
			setgb(w, g, 0x18, gb(w, g, 0x16))
			setgb(w, g, 0x1A, gb(w, g, 0x16))
			setgb(w, g, 0x19, gb(w, g, 0x17))
			setgb(w, g, 0x1B, gb(w, g, 0x17))
			setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
			return 0
		var res := _air_fight(w, rng, g, hooks)
		if res in AI_ABORT:
			return res
		if group_alive(w, g):
			setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
		return 0
	if t == 5:
		if st == 0x20 and bl & 0xC0 == 0x40:
			setgb(w, g, 2, bl & 0x3F)
		elif st == 0x10:
			setgb(w, g, 2, (bl & 0xF) | 0x20)
		return 0
	if t == 6:
		var res := _radio(w, rng, 6, g, hooks)
		if res in AI_ABORT:
			return res
		setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x20)
		return 0
	if t in [7, 8, 15]:
		setgb(w, g, 2, (bl & 0xF) | 0x20)
	return 0


static func _crew_lost_mark(w: Pd2World, rng: Pd2Random, c: int) -> void:
	var a := CREWS + 16 * c + 6
	w.mem_write(a, w.mem8(a) | (2 if rng.r16(100) % 2 == 0 else 1))


## 0x441A80: unit k of group g (an aircraft) went down (rules.aircraft_lost).
static func aircraft_lost(w: Pd2World, rng: Pd2Random, g: int, k: int) -> void:
	var c := s8(ub(w, k, 0xB))
	if w.mem8(CREWS + 16 * c + 2) == 0 and rng.r16(100) % 2 == 0:
		_crew_lost_mark(w, rng, c)
	if w.mem8(CREWS + 16 * c + 2) >= 2:
		return
	var t := gb(w, g, 0x21) & 0xF0
	if t == 0x60:
		for u in 254:
			var base := UNITS + 55 * u
			if w.mem8(base + 0x36) != 0:
				continue
			var cu := s8(w.mem8(base + 0xB))
			var v := w.mem8(base + 0x33)
			if v == w.mem8(base + 0x34) and v != 0xFF and v == k:
				w.mem_write(base + 0x33, 0xFF)
				w.mem_write(base + 0x34, 0xFF)
				Action.destroy(w, u)
				if rng.r16(100) % 4 != 2:
					_crew_lost_mark(w, rng, cu)
		return
	if not t in [0, 0x10, 0x20]:
		return
	var p := g - 1
	if gb(w, p, 2) & 0x30:
		return
	var cap := 2 if ub(w, k, 0xC) == 9 else 6
	var alive := group_alive(w, p)
	var n := alive - cap if alive > cap else alive
	while n:
		var i := 0
		while n and i < 16:
			var m := gb(w, p, 6 + i)
			if m == 0xFF:
				i += 1
				continue
			var cm := s8(ub(w, m, 0xB))
			if rng.r16(100) % 4 == 2:
				Action.destroy(w, m)
				n -= 1
				_crew_lost_mark(w, rng, cm)
				break
			if rng.r16(100) % 4 == 2:
				Action.destroy(w, m)
				n -= 1
				var base := UNITS + 55 * m
				w.mem_write(base, (w.mem8(base) & 0xFE) | 2)
				break
			if w.mem8(CREWS + 16 * cm + 2) != 0:
				i += 1
				continue
			if rng.r16(100) % 2 == 0:
				Action.destroy(w, m)
				n -= 1
				_crew_lost_mark(w, rng, cm)
			break


static func _first_two(w: Pd2World, g: int) -> Array:
	var out := []
	for i in 16:
		if out.size() == 2:
			break
		if gb(w, g, 6 + i) != 0xFF:
			out.append(gb(w, g, 6 + i))
	while out.size() < 2:
		out.append(0xFF)
	return out


## 0x441130: group g fights the group it follows (rules.air_fight, its slips kept).
static func air_fight(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks, easy := false) -> int:
	if gb(w, g, 0x1A) != 0xFF:
		return 0
	var t := s8(gb(w, g, 0x1B))
	if not group_alive(w, t):
		return 0
	var res := _air_anim(w, hooks, gpos(w, g), gpos(w, t))
	if res in AI_ABORT:
		return res
	var player := g < 20
	var src := g if player else t
	var before := PackedByteArray()
	for i in 35:
		before.append(gb(w, src, i))
	var a := _first_two(w, g)
	var b := _first_two(w, t)
	var a0: int = a[0]
	var a1: int = a[1]
	var b0: int = b[0]
	var b1: int = b[1]
	var alert := w.ds8(0x50ADF1)
	var uw := func(x: int, p: int) -> bool: return hooks.use_weapon(x, p)
	var lose_own := func(k: int) -> void:
		if player:
			aircraft_lost(w, rng, g, k)
			Action.destroy(w, k)
		else:
			Action.group_drop(w, g, k)
	var lose_other := func(k: int) -> void:
		if player:
			Action.group_drop(w, t, k)
		else:
			aircraft_lost(w, rng, t, k)
			Action.destroy(w, k)
	if group_alive(w, g):
		var rounds := 0
		while group_alive(w, t):
			rounds += 1
			if rounds > 1000:
				if w.safe_hit("H6", "air fight: 1000 rounds without an end: the fight ends"):
					break
				w.fault = "air fight: 1000 rounds without an end"
				return 0
			var fought := false
			if a0 != 0xFF and b0 != 0xFF:
				fought = true
				var r := Melee.melee(w, rng, a0, b0, alert, easy, uw)
				if r in AI_ABORT:
					return r
				if r == 3:
					lose_own.call(a0)
					lose_other.call(b0)
					a0 = 0xFF
					b0 = 0xFF
				elif r == 2:
					lose_own.call(a0)
					a0 = 0xFF
				elif r == 0:
					lose_other.call(b0)
					b0 = 0xFF
			if a1 != 0xFF and b1 != 0xFF:
				fought = true
				var r := Melee.melee(w, rng, a1, b1, alert, easy, uw)
				if r == 3:
					if player:
						lose_own.call(a1)
						lose_other.call(b1)
					else:
						Action.group_drop(w, g, a1)
						aircraft_lost(w, rng, t, a1)          # the game's slip: a1, not b1
						Action.destroy(w, a1)
					a1 = 0xFF
					b1 = 0xFF
				elif r == 2:
					lose_own.call(a1)
					a1 = 0xFF
				elif r == 0:
					lose_other.call(b1)
					b1 = 0xFF
			if a0 != 0xFF and b1 != 0xFF:
				fought = true
				var r := Melee.melee(w, rng, a0, b1, alert, easy, uw)
				if r == 3:
					lose_own.call(a0)
					lose_other.call(b1)
					a0 = 0xFF
					b1 = 0xFF
				elif r == 2:
					lose_own.call(a0)
					a0 = 0xFF
				elif r == 0:
					lose_other.call(b1)
					b1 = 0xFF
			if a1 != 0xFF and b0 != 0xFF:
				fought = true
				var r := Melee.melee(w, rng, a1, b0, alert, easy, uw)
				if r == 3:
					if player:
						lose_own.call(a1)
						Action.group_drop(w, t, b1)         # the game's slip: b1, not b0
					else:
						Action.group_drop(w, g, a0)         # the game's slip: a0, not a1
						aircraft_lost(w, rng, t, b0)
						Action.destroy(w, b0)
					a1 = 0xFF
					b0 = 0xFF
				elif r == 2:
					lose_own.call(a1)
					a1 = 0xFF
				elif r == 0:
					lose_other.call(b0)
					b0 = 0xFF
			if not group_alive(w, g):
				break
			if not fought:
				if w.safe_hit("H6", "air fight: no pair left while both groups live (the game loops): the fight ends"):
					break
				w.fault = "air fight: no pair left while both groups live (the game loops forever)"
				return 0
	var gone := (player and gb(w, g, 5) == 0) or (not player and gb(w, t, 5) == 0)
	if gone:
		res = _radio(w, rng, 9, before, hooks)
		if res in AI_ABORT:
			return res
		res = hooks.air_report()
		if res in AI_ABORT:
			return res
	if gb(w, g, 5) == 0:
		grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 0x80)
		setgb(w, g, 0x16, 0xFF)
	if gb(w, t, 5) == 0:
		grid_mark(w, s8(gb(w, t, 0x16)), s8(gb(w, t, 0x17)), 0x80)
		setgb(w, t, 0x16, 0xFF)
	return 0


static func _sgn16(v: int) -> int:
	v = s16(v)
	return (1 if v > 0 else 0) - (1 if v < 0 else 0)


## the flight engine's step price: 140 diagonal, 100 straight, 0 none.
static func _step_cost(dx: int, dy: int) -> int:
	if dx:
		return 140 if dy else 100
	return 100 if dy else 0


## 0x43C5E0: one move of group g (rules.group_move).
static func group_move(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks) -> int:
	if not group_follow_check(w, g):
		return 0
	var follow := gb(w, g, 0x1A) == 0xFF
	if not gb(w, g, 0x1C) and not gb(w, g, 0x22):
		var l: Vector2i
		if follow:
			var t := s8(gb(w, g, 0x1B))
			l = Ai.line_step(s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), s8(gb(w, t, 0x16)), s8(gb(w, t, 0x17)), 1)
		else:
			l = Ai.line_step(s8(gb(w, g, 0x18)), s8(gb(w, g, 0x19)), s8(gb(w, g, 0x1A)), s8(gb(w, g, 0x1B)), 1)
		setgb(w, g, 0x1C, _step_cost(_sgn16(l.x - s8(gb(w, g, 0x16))), _sgn16(l.y - s8(gb(w, g, 0x17)))))
	var speed := 0xFF
	for i in 16:
		var k := gb(w, g, 6 + i)
		if k == 0xFF:
			continue
		var m := ub(w, k, 0xC)
		if m == 0xFF:
			continue
		var sp := w.mem8(MACHS + 31 * s8(m) + 1) >> 1
		if speed > sp:
			speed = sp
	if speed == 0xFF:
		return 0x10000
	var rem := 0
	if gb(w, g, 0x1C) < speed:
		rem = speed - gb(w, g, 0x1C)
		setgb(w, g, 0x1C, 0)
	else:
		setgb(w, g, 0x1C, gb(w, g, 0x1C) - speed)
	if gb(w, g, 0x1C):
		return 0
	if follow:
		var t := s8(gb(w, g, 0x1B))
		var tx := gb(w, t, 0x16)
		var ty := gb(w, t, 0x17)
		if gb(w, g, 0x16) == tx and gb(w, g, 0x17) == ty:
			return 0
		var l := Ai.line_step(s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), s8(tx), s8(ty), 1)
		grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 0x80)
		var o := gpos(w, g)
		setgb(w, g, 0x17, l.y)
		setgb(w, g, 0x19, l.y)
		setgb(w, g, 0x16, l.x)
		setgb(w, g, 0x18, l.x)
		grid_mark(w, s8(l.x & 0xFF), s8(l.y & 0xFF), 1)
		tx = gb(w, t, 0x16)
		ty = gb(w, t, 0x17)
		if gb(w, g, 0x16) == tx and gb(w, g, 0x17) == ty:
			setgb(w, g, 0x1C, 0)
			setgb(w, g, 0x22, 0)
			return 0
		l = Ai.line_step(o.x, o.y, s8(tx), s8(ty), 2)
		var dx := _sgn16(l.x - s8(gb(w, g, 0x16)))
		var dy := _sgn16(l.y - s8(gb(w, g, 0x17)))
		setgb(w, g, 0x22, 0)
		if dx or dy:
			setgb(w, g, 0x1C, _step_cost(dx, dy))
			return 0
		var res := hooks.pump()
		if res in AI_ABORT:
			return res
		setgb(w, g, 0x1C, 0)
		return 0
	var l := Ai.line_step(s8(gb(w, g, 0x18)), s8(gb(w, g, 0x19)), s8(gb(w, g, 0x1A)), s8(gb(w, g, 0x1B)), gb(w, g, 0x22) + 1)
	grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 0x80)
	setgb(w, g, 0x16, l.x)
	setgb(w, g, 0x17, l.y)
	grid_mark(w, s8(l.x & 0xFF), s8(l.y & 0xFF), 1)
	if g < 12 and g % 2 == 1:
		var e := 12 + (g - 1) / 2
		if gb(w, e, 0x21) & 0xF0 == 0x90:
			setgb(w, e, 0x16, l.x)
			setgb(w, e, 0x17, l.y)
	if gb(w, g, 0x16) == gb(w, g, 0x1A) and gb(w, g, 0x17) == gb(w, g, 0x1B):
		var res := group_arrive(w, rng, g, hooks)
		return res if res in AI_ABORT else 0
	setgb(w, g, 0x22, gb(w, g, 0x22) + 1)
	l = Ai.line_step(s8(gb(w, g, 0x18)), s8(gb(w, g, 0x19)), s8(gb(w, g, 0x1A)), s8(gb(w, g, 0x1B)), gb(w, g, 0x22) + 1)
	var dx := _sgn16(l.x - s8(gb(w, g, 0x16)))
	var dy := _sgn16(l.y - s8(gb(w, g, 0x17)))
	if dx or dy:
		setgb(w, g, 0x1C, _step_cost(dx, dy) - rem)
		return 0
	var res := hooks.pump()
	if res in AI_ABORT:
		return res
	setgb(w, g, 0x1C, -rem)
	return 0


## 0x43D3E0: a fighter group picks a target among the other side's groups.
static func group_seek(w: Pd2World, g: int) -> void:
	if not gb(w, g, 0x21) & 0xF0 in [0x40, 0x90] or not group_alive(w, g) or s8(gb(w, g, 0x16)) < 0:
		return
	var enemy := range(20, 64) if g < 20 else range(0, 20)
	var own := range(0, 20) if g < 20 else range(20, 64)
	for pass_ in 4:
		if gb(w, g, 2) & 0x30 == 0x20 and gb(w, g, 2) & 0xC0 == 0x80:
			return
		for i in enemy:
			if gb(w, g, 2) & 0x30 == 0x20 and gb(w, g, 2) & 0xC0 == 0x80:
				break
			var et := gb(w, i, 0x21) & 0xF0
			var ok := false
			match pass_:
				0: ok = et == 0x90
				1: ok = et == 0x40
				2: ok = et == 0x30
				_: ok = et < 0x30
			if not ok or gb(w, i, 0x16) == 0xFF or not group_alive(w, i):
				continue
			var busy := false
			for j in own:
				if j != g and group_alive(w, j) and gb(w, g, 0x1A) == 0xFF and s8(gb(w, g, 0x1B)) == j:
					busy = true
					break
			if not busy:
				if gb(w, g, 0x21) & 0xF0 == 0x90:
					setgb(w, g, 0x21, (gb(w, g, 0x21) & 0xF) | 0x40)
				setgb(w, g, 0x1A, 0xFF)
				setgb(w, g, 0x1B, i)
				setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0xA0)


## 0x43E3C0: for launcher lid, the first enemy group with an aircraft within range, or -1.
static func missile_target(w: Pd2World, g: int, lid: int) -> int:
	var r := w.mem8(LAUNS + 17 * lid + 4) * 10
	for e in (range(20, 64) if g < 20 else range(0, 20)):
		if not group_alive(w, e):
			continue
		for i in 16:
			var k := gb(w, e, 6 + i)
			if k == 0xFF:
				break
			var m := s8(ub(w, k, 0xC))
			if Pd2World.CLASS_BY_CATEGORY[w.mem8(MACHS + 31 * m) & 15] > 1:
				var a := gpos(w, g)
				var b := gpos(w, e)
				if Ai.grid_distance(a.x, a.y, b.x, b.y) <= r:
					return e
	return -1


## 0x43E0C0: unit u (of group g) fires slot s at aircraft t of group e (rules.missile_shot).
static func missile_shot(w: Pd2World, rng: Pd2Random, u: int, s: int, t: int, e: int, g: int, hooks: Hooks) -> int:
	var p := w.ub(u, 0x10 + 2 * s) & 15
	var b := w.ub(u, 0x1C + 2 * p)
	w.setb(u, 0x1C + 2 * p, (b & 0xC0) | (((b & 0x3F) - 1) & 0x3F))
	var ct := s8(ub(w, t, 0xB))
	var d := s8(w.mem8(CREWS + 16 * ct + 13))
	var lid := s8(w.ub(u, 0xF + 2 * s))
	var chance := w.mem8(LAUNS + 17 * lid + 5) - d * absi(d)
	chance = 98 if chance >= 99 else maxi(chance, 15)
	Action.count(w, u, 4, true)
	w.events.append(["grow", u, "AA", 4])
	if rng.r16(100) >= chance:
		return 0
	Action.count(w, u, 6, true)
	w.events.append(["grow", u, "AA", 4])
	var am := s8(w.ub(u, 0x1B + 2 * (w.ub(u, 0x10 + 2 * s) & 15)))
	var aa := (w.mem8(LAUNS + 17 * lid + 6) + w.mem8(AMMOS + 12 * am + 2)) & 0xFF
	var mt := s8(ub(w, t, 0xC))
	var dmg := W.cdiv(aa * ((100 - w.mem8(MACHS + 31 * mt + 5)) - d), 100)
	var cond := ub(w, t, 0xD)
	if dmg < cond:
		w.mem_write(UNITS + 55 * t + 0xD, cond - dmg)
	else:
		Action.count(w, u, 3, false)
		if e < 20:
			if group_alive(w, e) == 1 or e < 12:
				var res := _radio(w, rng, 0x0B, e, hooks)
				if res in AI_ABORT:
					return res
			w.mem_write(UNITS + 55 * t + 0xD, 0)
			aircraft_lost(w, rng, e, t)
			Action.destroy(w, t)
			if ub(w, t, 0x36) in [1, 2]:
				for i in 16:
					if gb(w, e, 6 + i) == t:
						setgb(w, e, 6 + i, 0xFF)
						setgb(w, e, 5, gb(w, e, 5) - 1)
						break
		else:
			w.mem_write(UNITS + 55 * t + 0xD, 0)
			Action.group_drop(w, e, t)
			var res := _radio(w, rng, 0x12, g, hooks)
			if res in AI_ABORT:
				return res
	if not group_alive(w, e):
		grid_mark(w, s8(gb(w, e, 0x16)), s8(gb(w, e, 0x17)), 0x80)
		setgb(w, e, 0x16, 0xFF)
		var res := hooks.air_report()
		if res in AI_ABORT:
			return res
	return 0


## 0x43DF50: the missile's target group (defence: in range and flying away or engaging;
## attack: the group followed, within the round's range), or -1.
static func air_target(w: Pd2World, g: int, lid: int, am: int, mode: int) -> int:
	var a := gpos(w, g)
	if mode == 0:
		var r := w.mem8(LAUNS + 17 * lid + 4) * 10
		for e in (range(20, 64) if g < 20 else range(0, 20)):
			if group_alive(w, e) and gb(w, e, 0x16) != 0xFF and gb(w, e, 2) & 0xE in [6, 8]:
				var b := gpos(w, e)
				if Ai.grid_distance(a.x, a.y, b.x, b.y) <= r:
					return e
		return -1
	var t := s8(gb(w, g, 0x1B))
	var b := gpos(w, t)
	var d := Ai.grid_distance(a.x, a.y, b.x, b.y)
	var r := (w.mem8(AMMOS + 12 * am + 3) + w.mem8(LAUNS + 17 * lid + 4)) & 0xFF
	return t if d <= r * 10 else -1


## 0x43DD70: unit u of group g fires its missiles, at most 2 - shots.
static func air_volley(w: Pd2World, rng: Pd2Random, g: int, u: int, mode: int, shots: int, hooks: Hooks) -> int:
	var res := 0
	for s in 6:
		if mode == 1 and group_alive(w, s8(gb(w, g, 0x1B))) <= 0:
			return res
		var lid := s8(w.ub(u, 0xF + 2 * s))
		if not w.ub(u, 0xF + 2 * s) or (w.ub(u, 0x10 + 2 * s) & 0x30) >= 0x10:
			continue
		var p := w.ub(u, 0x10 + 2 * s) & 15
		if not w.ub(u, 0x1C + 2 * p) & 0x3F:
			continue
		var am := s8(w.ub(u, 0x1B + 2 * p))
		if not (w.mem8(LAUNS + 17 * lid + 6) + w.mem8(AMMOS + 12 * am + 2)) & 0xFF:
			continue
		if w.mem8(LAUNS + 17 * lid + 8) & 0xE0 != 0x40 or shots >= 2:
			continue
		var tg := air_target(w, g, lid, am, mode)
		if tg < 0:
			continue
		shots += 1
		var e := 0xFF
		for i in 16:
			if gb(w, tg, 6 + i) != 0xFF:
				e = gb(w, tg, 6 + i)
				break
		if e == 0xFF:
			continue
		res = _air_anim(w, hooks, gpos(w, g), gpos(w, tg))
		if res in AI_ABORT:
			return res
		res = missile_shot(w, rng, u, s, e, tg, g, hooks)
		if res in AI_ABORT:
			return res
	return res


## 0x441810: a set-down team meets the other side's groups on its hex (rules.ground_team).
static func ground_team(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks) -> int:
	if gb(w, g, 0x21) & 0xF0 != 0x50:
		return 0
	var n15 := 0
	var n5 := 0
	var first := -1
	for e in (range(20, 64) if g < 20 else range(0, 20)):
		if group_alive(w, e) and gb(w, g, 0x16) == gb(w, e, 0x16) and gb(w, g, 0x17) == gb(w, e, 0x17):
			var t := gb(w, e, 0x21) & 0xF0
			if t == 0xF0:
				if first < 0:
					first = e
				n15 += 1
			elif t == 0x50:
				if first < 0:
					first = e
				n5 += 1
	if rng.r16(200) < n15:
		var res := _radio(w, rng, 7, g, hooks)
		if res in AI_ABORT:
			return res
		while group_alive(w, g):
			for i in 16:
				var m := gb(w, g, 6 + i)
				if m == 0xFF:
					continue
				aircraft_lost(w, rng, g, m)
				if g < 20:
					Action.destroy(w, m)
				else:
					Action.group_drop(w, g, m)
		return 0
	if not n5:
		return 0
	var res := _air_anim(w, hooks, gpos(w, g), gpos(w, first))
	if res in AI_ABORT:
		return res
	if gb(w, g, 2) & 0x30 != 0x20 or gb(w, g, 2) & 0xC0 == 0x40:
		return 0
	res = _radio(w, rng, 0x0A, g, hooks)
	if res in AI_ABORT:
		return res
	setgb(w, g, 2, (gb(w, g, 2) & 0xF) | 0x60)
	for i in 16:
		var m := gb(w, g, 6 + i)
		if m != 0xFF:
			w.mem_write(UNITS + 55 * m + 6, 0)
	return 0


## 0x43D9C0: a group engages by type (rules.group_engage).
static func group_engage(w: Pd2World, rng: Pd2Random, g: int, hooks: Hooks) -> int:
	var t := gb(w, g, 0x21) & 0xF0
	if t > 0x50 or t == 0x10 or t == 0x20:
		return 0
	if t == 0 or t == 0x30 or t == 0x40:
		var mode := 0
		var shots := 1
		if t == 0x40:
			if gb(w, g, 2) & 0x30 != 0x20 or gb(w, g, 2) & 0xC0 != 0x80 or gb(w, g, 0x1A) != 0xFF:
				return 0
			if not group_alive(w, s8(gb(w, g, 0x1B))):
				return 0
			mode = 1
			shots = 0
		else:
			var st := gb(w, g, 2) & 0x30
			if not ((st == 0x20 and not gb(w, g, 2) & 0xC0) or st == 0x10 or st == 0x30):
				return 0
		for i in 16:
			if not group_alive(w, s8(gb(w, g, 0x1B))):
				return 0
			var k := gb(w, g, 6 + i)
			if k == 0xFF:
				continue
			var res := air_volley(w, rng, g, k, mode, shots, hooks)
			if res in AI_ABORT:
				return res
		return 0
	var res := ground_team(w, rng, g, hooks)
	if res in AI_ABORT:
		return res
	if gb(w, g, 2) & 0x30 != 0x20 or gb(w, g, 2) & 0xC0:
		return 0
	var announced := false
	for i in 16:
		var k := gb(w, g, 6 + i)
		if k == 0xFF:
			continue
		var fired := false
		for s in 6:
			if w.ub(k, 0xF + 2 * s) == 0xFF:
				continue
			var al := w.ub(k, 0x10 + 2 * s)
			if not w.ub(k, 0x1C + 2 * (al & 15)) & 0x3F or (al & 0x30) >= 0x10:
				continue
			var lid := s8(w.ub(k, 0xF + 2 * s))
			if not w.mem8(LAUNS + 17 * lid + 6) or w.mem8(LAUNS + 17 * lid + 8) & 0xE0 != 0x40:
				continue
			if fired:
				continue
			var tg := missile_target(w, g, lid)
			if tg < 0:
				continue
			var e := 0xFF
			for j in 16:
				if gb(w, tg, 6 + j) != 0xFF:
					e = gb(w, tg, 6 + j)
					break
			if e == 0xFF:
				continue
			if not announced:
				res = _radio(w, rng, 0x11, g, hooks)
				if res in AI_ABORT:
					return res
				announced = true
			fired = true
			res = missile_shot(w, rng, k, s, e, tg, g, hooks)
			if res in AI_ABORT:
				return res
	return 0


# --- the flight turn --------------------------------------------------------------

static func _group_en_route(w: Pd2World, g: int) -> bool:
	var st := gb(w, g, 2) & 0x30
	if st == 0x10 and not group_at_goal(w, g):
		return true
	if st == 0x20 and gb(w, g, 2) & 0xC0 in [0x40, 0x80] and not group_at_goal(w, g):
		return true
	return st == 0x30 and not group_at_goal(w, g)


static func _on_grid(w: Pd2World, g: int) -> bool:
	return s8(gb(w, g, 0x16)) >= 0 and group_alive(w, g) and gb(w, g, 2) & 0x30 and gb(w, g, 0x16) != 0xFF


## 0x43BDB0, the flight engine's turn (rules.flight_turn). Returns 0 or an abort code.
static func flight_turn(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	w.grid.fill(0)
	for g in 64:
		if s8(gb(w, g, 0x20)) > 0:
			var st := gb(w, g, 2) & 0x30
			if st == 0x20 or (st == 0x10 and gb(w, g, 2) & 0xC0 == 0x40):
				setgb(w, g, 0x20, gb(w, g, 0x20) - 1)
		group_disarmed(w, g)
		var res := group_timeout(w, rng, g, hooks)
		if res in AI_ABORT:
			return res
		if gb(w, g, 2) & 0x30 == 0x30 and gb(w, g, 0x16) != 0xFF and gb(w, g, 0x16) == gb(w, g, 0x1A) \
				and gb(w, g, 0x17) == gb(w, g, 0x1B):
			grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 0x80)
			setgb(w, g, 0x16, 0xFF)
		var r := group_appears(w, g)
		if w.fault != "":
			return 0
		if r == 0x10000:
			return r
		if not r:
			continue
		if g < 12 and g % 2 == 1:
			var p := 12 + (g - 1) / 2
			if gb(w, p, 0x21) & 0xF0 == 0x90:
				setgb(w, p, 2, (gb(w, p, 2) & 0xDF) | 0x10)
				setgb(w, p, 0x16, gb(w, g, 0x18))
				setgb(w, p, 0x17, gb(w, g, 0x19))
				setgb(w, p, 0x1C, 0)
				setgb(w, p, 0x22, 0)
		setgb(w, g, 0x17, gb(w, g, 0x19))
		setgb(w, g, 2, (gb(w, g, 2) & 0xDF) | 0x10)
		setgb(w, g, 0x16, gb(w, g, 0x18))
		setgb(w, g, 0x1C, 0)
		setgb(w, g, 0x22, 0)
		grid_mark(w, s8(gb(w, g, 0x16)), s8(gb(w, g, 0x17)), 1)
		res = radar_redraw(w, hooks)
		if res in AI_ABORT:
			return res
		res = hooks.air_report()
		if res in AI_ABORT:
			return res
		if gb(w, g, 0x16) == gb(w, g, 0x1A) and gb(w, g, 0x17) == gb(w, g, 0x1B):
			res = group_arrive(w, rng, g, hooks)
			if res in AI_ABORT:
				return res
	var res := radar_detect(w, rng, hooks)
	if res in AI_ABORT:
		return res
	for g in 64:
		group_follow_check(w, g)
	for _round in 2:
		w.grid.fill(0)
		for g in 64:
			if not _on_grid(w, g):
				continue
			if not _group_en_route(w, g) or gb(w, g, 2) & 0x30 == 0x10:
				group_seek(w, g)
		for g in 64:
			if not _on_grid(w, g) or gb(w, g, 0x21) & 0xF0 == 0x90:
				continue
			if _group_en_route(w, g):
				res = group_move(w, rng, g, hooks)
			elif gb(w, g, 2) & 0xC0 in [0x80, 0x40] and group_at_goal(w, g) and gb(w, g, 0x21) & 0xF0 in [0x30, 0x40, 0xF0, 0x50]:
				res = group_arrive(w, rng, g, hooks)
			else:
				continue
			if w.fault != "":
				return 0
			if res in AI_ABORT:
				return res
		if w.radar:
			res = radar_redraw(w, hooks)
			if res in AI_ABORT:
				return res
		for g in 64:
			if not _on_grid(w, g):
				continue
			res = group_engage(w, rng, g, hooks)
			if res in AI_ABORT:
				return res
		if w.radar:
			res = radar_redraw(w, hooks)
			if res in AI_ABORT:
				return res
	return 0
