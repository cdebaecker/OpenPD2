class_name MissionScripts
extends RefCounted
## The per-mission event scripts (tables 0x51EAE8..0x51F1B8 indexed by the mission number
## DS:0x50CE72) and their shared helpers, ported from rules.py and checked against the game
## by emulation (verify_m01). Only what is ported is here; see RULES.md 5.8.

const MAP := 72
const AI_ABORT := [0x10000, 0x20000, 0x40000]
const G_FLAGS := 2
const G_UNITS := 5
const G_X := 22
const G_Y := 23
const G_PREV_X := 24
const G_PREV_Y := 25
const G_TARGET_X := 26
const G_TARGET_Y := 27
const G_F28 := 28
const G_ARRIVAL := 29            # s16: the turn the group arrives
const G_STATUS := 33
const G_F34 := 34


## What the scripts leave to the game's windows (rules.MissionHooks).
class Hooks:
	## 0x43BA20 with choices: the index chosen (0 = the first)
	func dialog(msg: int, args: Array, choices: int) -> int:
		return 0

	## 0x43BA20 without choices: its return value is passed on
	func message(msg: int, args := []) -> int:
		return 0

	## 0x4DD390: -100, -101 or -102
	func end_dialog(msg: int) -> int:
		return -100

	## the mission's speech hook (table 0x51EEB8), run by the turn script
	func speech() -> int:
		return 0

	## 0x4403D0
	func speech_window() -> int:
		return 0

	func scroll(x: int, y: int) -> int:
		return 0


static func g(w: Pd2World, grp: int, f: int) -> int:
	return w.groups[35 * grp + f]


static func set_g(w: Pd2World, grp: int, f: int, v: int) -> void:
	w.groups[35 * grp + f] = v & 0xFF


## The byte at units[0] + o: the unit table (255 x 55 B) is followed by the group table.
static func table_byte(w: Pd2World, o: int) -> int:
	if o < 255 * 55:
		return w.units[o] if o < w.units.size() else 0
	return w.groups[o - 255 * 55]


## 0x4DE090: drop points for the groups not yet placed, and the aim of groups 1, 3, .., 11.
static func group_scan(w: Pd2World) -> void:
	for grp in 20:
		if g(w, grp, 3) & 1 != 1 and g(w, grp, 2) & 0x30 == 0 and g(w, grp, 0x16) == 0xFF and g(w, grp, 5):
			if g(w, grp, 0x21) & 0xF0 == 0x90:
				var o := 0x33BC + 0x46 * grp
				set_g(w, grp, 0x18, table_byte(w, o))
				set_g(w, grp, 0x19, table_byte(w, o + 1))
			else:
				var k := (grp % 3) * 4
				set_g(w, grp, 0x18, w.ds8(0x50AD99 + k))
				set_g(w, grp, 0x19, w.ds8(0x50AD9B + k))
	for grp in range(20, 64):
		if g(w, grp, 5) and g(w, grp, 2) & 0x30 == 0 and g(w, grp, 0x16) == 0xFF:
			var k := (grp % 3) * 4
			set_g(w, grp, 0x18, w.ds8(0x50ADA5 + k))
			set_g(w, grp, 0x19, w.ds8(0x50ADA7 + k))
	for grp in range(1, 13, 2):
		if g(w, grp, 5) and g(w, grp, 2) & 0x30 == 0:
			var t := g(w, grp, 0x21) & 0xF0
			if t in [0, 0x10, 0x60]:
				set_g(w, grp, 0x1A, w.ds8(0x50AD95))
				set_g(w, grp, 0x1B, w.ds8(0x50AD97))


## 0x4716D0: crew c's combat-record shots (crew +15 = record; < 0: 0).
static func crew_shots(w: Pd2World, c: int) -> int:
	var i := Pd2World.s8(w.crew[c * Pd2World.CREW + 15])
	if i < 0:
		return 0
	return w.combat[13 * i + 4] | w.combat[13 * i + 5] << 8


# --- mission 1 (script 1: the PD2 campaign's first mission) ------------------------------

## 0x499480: 1 while group 0 or 2 has units and a clear status, else -1 (dialog 0x12B).
static func m01_state(w: Pd2World) -> int:
	for grp in [0, 2]:
		if g(w, grp, G_STATUS) & 15 == 0 and g(w, grp, G_UNITS) != 0:
			return 1
	return -1


## 0x499480 after dialog 0x12B: -102 -> 0x20000, -101 -> 0x40000, -100 -> 0x10000, else 0.
static func m01_state_result(choice: int) -> int:
	return {-102: 0x20000, -101: 0x40000, -100: 0x10000}.get(choice, 0)


## 0x4995E0: the objective message, -1 once group 0 or 2 has a clear status, else 0x10A.
static func m01_objective(w: Pd2World) -> int:
	if g(w, 0, G_STATUS) & 15 == 0 or g(w, 2, G_STATUS) & 15 == 0:
		return -1
	return 0x10A


## 0x499540: the camera point (5, 13), drop points cleared, DS:0x50ADB1..0x50ADF0 from the
## tables at DS:0x524130 / 0x524150 (not seen written: zero here), DS:0x506651 = 0.
static func m01_init(w: Pd2World, table_524130 := PackedByteArray()) -> void:
	w.set_ds16(0x50AD95, 5)
	w.set_ds16(0x50AD97, 0xD)
	for a in range(0x50AD99, 0x50ADB1, 2):
		w.set_ds16(a, 0)
	for i in 0x40:
		w.ds[0xB1 + i] = table_524130[i] if i < table_524130.size() else 0
	w.ds_506651 = 0


## 0x49A190, the turn script: stage 0 in the computer's turn, 1 after the player's, 2 at a
## new mission (rules.m01_turn). Returns 0.
static func m01_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var n_units := mini(w.units.size() / 55, 254)
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFF
		if not w.ds16(0x50AD6E) & 1:
			if not w.ds16(0x50AD74) & 1:
				var live := []
				for i in 15:
					if Pd2World.s8(w.bombs[4 * i]) != -1 and Pd2World.s8(w.bombs[4 * i + 2]) < 2:
						live.append(i)
				if not live.is_empty():
					w.set_ds16(0x50AD6E, w.ds16(0x50AD6E) | 1)
					w.set_ds16(0x50AD74, w.ds16(0x50AD74) | 1)
					w.set_ds8(0x50ADF1, 1)
					for u in n_units:
						var st := w.sb(u, 0x36)
						if st > 2 and st < 6 and w.ub(u, 0xC) != 0xFF and w.ub(u, 0xD) and w.ub(u, 3) & 0xF0 == 0x10:
							var b: int = live[rng.roll(live.size()) & 0xFFFF]
							w.setb(u, 7, w.bombs[4 * b])
							w.setb(u, 8, w.bombs[4 * b + 1])
			if not w.ds16(0x50AD6E) & 1 and not w.ds16(0x50AD74) & 1:
				var fit := 0
				var hurt := 0
				var enemies := 0
				var seen := false
				for u in n_units:
					var c := w.ub(u, 0xD)
					var f := w.ub(u, 0)
					if w.sb(u, 0x36) < 3:
						if c == 100 and not f & 1 and f & 4:
							fit += 1
						if c and w.ub(u, 9) != 0xFF and f & 0x10 and f & 4:
							seen = true
							if c != 100:
								hurt += 1
					elif c and w.ub(u, 9) != 0xFF:
						enemies += 1
				var smoke := false
				for i in MAP * MAP:
					if w.F[i] & 1:
						smoke = true
						break
				var shots := 0
				for c in 64:
					shots = crew_shots(w, c)
					if shots:
						break
				if fit < 3 or seen or smoke or enemies < 32 or hurt or shots:
					w.set_ds8(0x50ADF1, 1)
					w.set_ds16(0x50AD74, w.ds16(0x50AD74) | 1)
		hooks.speech()
	elif stage == 1 and w.ds16(0x50AD7A) & 1:
		for u in n_units:
			if w.ub(u, 0xD) and w.ub(u, 9) != 0xFF and w.sb(u, 0x36) < 3 and w.ub(u, 0) & 4:
				var p := Vector2i(w.sb(u, 9), w.sb(u, 10))
				if p in w.exits:
					hooks.scroll(p.x, p.y)
					if hooks.dialog(0xAA, [w.ucrew(u, 0)], 2) == 0:
						if w.ub(u, 0x34) == 0xFF:
							Action.take_off_map(w, u)          # 0x47FFA0
						else:
							hooks.message(0xAB)
	if not w.ds16(0x50AD4E) & 1:
		group_scan(w)
		var px := w.ds8(0x50AD95)
		var py := w.ds8(0x50AD97)
		for grp in [0, 2]:
			for f in [G_X, G_PREV_X, G_TARGET_X]:
				set_g(w, grp, f, px)
				set_g(w, grp, f + 1, py)
			set_g(w, grp, G_F28, 0)
			set_g(w, grp, G_F34, 0)
		hooks.speech_window()
		w.set_ds16(0x50AD4E, w.ds16(0x50AD4E) | 1)
	for u in n_units:
		if w.ub(u, 0xD) and w.sb(u, 0x36) <= 2 and w.ub(u, 0) & 4 and w.ub(u, 9) != 0xFF:
			return 0
	for grp in [0, 2, 4]:
		if g(w, grp, G_UNITS) and g(w, grp, G_FLAGS) & 0x30 == 0 and not w.ds16(0x50AD7A) & 1:
			return 0
	w.set_ds8(0x50ADF2, 0x80)                       # the mission ends
	return 0


## 0x499F40, the mission's own command (unit menu entry 11; rules.m01_command).
static func m01_command(w: Pd2World, u: int, hooks: Hooks) -> int:
	if w.sb(u, 0xE) < 20:
		return hooks.message(0xA9)
	var res := hooks.dialog(0xA5, [], 2)
	if res != 0:
		return res
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	if not w.ds16(0x50AD7A) & 1 and (Vector2i(x, y) == Vector2i(47, 24) or Vector2i(x, y) == Vector2i(46, 24)):
		res = hooks.message(0xA6)
		if res in AI_ABORT:
			return res
		w.setb(u, 0xE, (w.ub(u, 0xE) - 20) & 0xFF)
		w.set_ds8(0x50AD7A, (w.ub(u, 0xB) & 0x1F) << 1 | (w.ds8(0x50AD7A) & 0xC1) | 1)
		return 0
	# The game means the ring around u, but walks spiral()'s list (pairs of ints) 4 bytes at
	# a time as (x, y) shorts: it checks the T layer at offsets y0, x1, y1, x2, ...
	var ring := Ai.spiral(x, y, 1)
	var flat := []
	for p in ring:
		flat.append(p.x)
		flat.append(p.y)
	var near := false
	for i in ring.size() - 1:
		if w.terrain[w.T[flat[1 + i] & 0xFFFF]] in [7, 8]:
			near = true
	if near:
		res = hooks.message(0xA7)
		if res in AI_ABORT:
			return res
		w.setb(u, 0xE, (w.ub(u, 0xE) - 20) & 0xFF)
		return 0
	res = hooks.message(0xA8)
	return res if res in AI_ABORT else 0
