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

	# the other missions' windows (rules.MissionHooks)
	var options := 0                ## DS:0x551D29 (bit 4: no explosion animations)
	var flight: Flight.Hooks = null ## the flight engine's windows, for the speech hooks

	## ui_message_box 0x451FB0, buttons DS:0x50CBC9[kind] (0: 了解 / 中止, 1: 実行 / 中止):
	## 1 for the first, 0 for the second (or cancel), or an abort code
	func box(msg: int, args: Array, kind: int) -> int:
		return 0

	## 0x4521C0 / ui_message_line 0x452300 (-1: failed)
	func line(msg: int, args := []) -> int:
		return 0

	## 0x43BDB0 from a speech hook: null runs Flight.flight_turn with flight
	func flight_turn() -> Variant:
		return null

	## 0x40F590: the explosion window
	func blast_open() -> int:
		return 0

	## 0x40F710 / 0x40F730 at (x, y): 0x80000 if skipped
	func blast_start(x: int, y: int) -> int:
		return 0

	## 0x417410's animation at (x, y): 0x80000 if skipped
	func blast(x: int, y: int) -> int:
		return 0

	## 0x410510
	func blast_close() -> int:
		return 0

	## ui_prompt_at_cursor: 0 = yes
	func prompt(msg: int, args := []) -> int:
		return 0

	## 0x429200: the fuse list's index (from low x 5), -2 cancel
	func fuse(msg: int, low: int) -> int:
		return 0

	## ui_map_click (0x47AC70) in mode: the hex clicked (Vector2i), -2 cancel, or abort
	func click(mode: int) -> Variant:
		return -2

	## 0x43E510(0) from a turn script: null runs Flight.grid_init with flight
	func radar_open() -> Variant:
		return null

	## 0x453CD0, a scene's pause: 1 / 2 the window closed
	func wait() -> int:
		return 0

	## 0x4F2150, a hex redrawn (an abort code stops a start script)
	func redraw_hex(x: int, y: int) -> int:
		return 0

	## 0x43F060: the radar map's windows closed (the script then clears DS:0x50DD44)
	func radar_close() -> int:
		return 0

	## 0x466790(0, -1): the unit panel redrawn
	func unit_panel() -> int:
		return 0

	## 0x4830E0: the map window redrawn
	func map_redraw() -> int:
		return 0

	## 0x4361C0, ui_date_window
	func date_window() -> int:
		return 0

	## 0x452170, a note (a negative answer: the window failed)
	func note(msg: int) -> int:
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
	var a := 0x506B39 + 13 * i            # past the 26 records the game reads on (into the units)
	return w.mem8(a + 4) | w.mem8(a + 5) << 8


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
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
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


## m01_speech's word table on its stack: the hexes the arriving members take.
const M01_LANDING := {0: [Vector2i(9, 30), Vector2i(8, 29), Vector2i(8, 30), Vector2i(9, 34), Vector2i(8, 33), Vector2i(8, 34)],
		2: [Vector2i(9, 34), Vector2i(8, 33), Vector2i(8, 34)]}


## 0x499830, mission 1's speech hook (rules.m01_speech): the flight turn, then groups 0
## and 2 each play their arrival scene once and are set down. Returns 0 or an abort code.
static func m01_speech(w: Pd2World, rng: Pd2Random, hooks: Flight.Hooks) -> int:
	var r0: Variant = hooks.flight_turn()
	var res: int = Flight.flight_turn(w, rng, hooks) if r0 == null else int(r0)
	if res in AI_ABORT:
		return res
	for p in [[0, 0x50AD76, 2, 0x50AD78], [2, 0x50AD78, 0, 0x50AD76]]:
		var grp: int = p[0]
		var flag: int = p[1]
		var other: int = p[2]
		var other_flag: int = p[3]
		var arr := Flight.s16(g(w, grp, 0x1D) | g(w, grp, 0x1E) << 8)
		if w.ds8(flag) & 1 or arr > w.mission_turn or not g(w, grp, 5):
			continue
		w.set_ds8(flag, w.ds8(flag) | 1)
		var R := func(o: int) -> int: return Flight.gb(w, grp, o)
		var face: Variant = Flight._radio_speaker(w, rng, R)[1]
		var steps := []
		if g(w, grp, 0x21) & 0xF == 0:
			if g(w, other, 5) and g(w, other, 0x21) & 0xF == 1 and w.ds8(other_flag) & 1:
				steps = [["face", 3, 0x3A, null], ["say", 0xA1, 0x3A], ["face", face, 0xB, null], ["say", 0xA2, 0xB]]
			else:
				steps = [["face", face, 0x1A, 0], ["face", 0xC, 0x1A, 1], ["say", 0xA3, 0x1A]]
		else:            # group 0 ignores its second window's result, group 2 checks it
			steps = [["face", face, 0x1A, 0], ["face?" if grp == 0 else "face", 0xC, 0x1A, 1], ["say", 0xA4, 0x1A]]
		for st in steps:
			if st[0] == "say":
				res = hooks.radio_say(st[1], [], st[2])
			else:
				res = Flight._radio_face(w, hooks, st[1], st[2], st[3])
				if st[0] == "face?":
					continue
			if res in AI_ABORT:
				hooks.radio_close(-1)
				return res
		hooks.radio_close(-1)
		var spots: Array = M01_LANDING[grp]
		var n := 0
		for i in 16:
			var k := g(w, grp, 6 + i)
			if k == 0xFF:
				continue
			if n >= spots.size():
				w.fault = "m01_speech: a member past the landing table (the game reads its stack)"
				return 0
			w.mem_write(Flight.UNITS + 55 * k + 9, spots[n].x)
			w.mem_write(Flight.UNITS + 55 * k + 0xA, spots[n].y)
			n += 1
	return 0


# --- the scripts' tables (rules.MISSION_SCRIPTS): what every mission has ------------------
#
# The roles (rules.py's comment above MISSION_SCRIPTS): load 0x51F1B8, init 0x51ECC8,
# objective 0x51ED28, deploy 0x51EC68, turn 0x51EFD8, speech 0x51EEB8, menu 0x51EF18,
# command 0x51EF78, scenario 0x51F038, bomb_rule 0x51F098, start 0x51F0F8, bomb 0x51F158.
# Mission 1's are the m01_ functions above; the dispatchers below pick a mission's by
# w.script_no (DS:0x50CE72). A role a mission does not have is its table's do-nothing.

const DEPLOY_RESULT := {-102: 0x20000, -101: 0x40000, -100: 0x10000}

## the label arrays the scripts pass 0x43BA20 with a choice (two string pointers each; the
## import resolves them: tables script_choices), by mission and message
const CHOICES := {1: {0xAA: 0x50CBC1, 0xA5: 0x517F88}, 2: {0xA3: 0x517F78, 0xA8: 0x517F80},
		3: {0xAA: 0x50CBC1, 0xA5: 0x517F88}, 6: {0xA3: 0x50CBC1, 0xA6: 0x50CBC1},
		7: {0xA6: 0x50CBC1, 0xB2: 0x517F88, 0xB3: 0x517F88}, 8: {0xA2: 0x50CBC1, 0xC2: 0x50CBC1, 0x51AEFC: 0x51AD78},
		9: {0xA2: 0x50CBC1}}

## the questions that name a pilot (the crew's name id: given and family names), by mission
const NAME_DIALOGS := {1: 0xAA, 3: 0xAA, 6: 0xA6, 8: 0xC2}

## the missions whose scripts are ported (rules.MISSION_SCRIPTS)
const PORTED := [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 15]


static func has_scripts(script: int) -> bool:
	return script in PORTED


static func run_load(w: Pd2World) -> void:
	match w.script_no:
		2: m02_load(w)
		3: m03_load(w)
		4: m04_load(w)
		7: m07_load(w)
		8: m08_load(w)
		9: m09_load(w)
		10: m10_load(w)
		12: m12_load(w)
		14: m14_load(w)
		15: m15_load(w)


## the init (table 0x51ECC8): its result (mission 10 returns its last store, 0x3C3C3C3C)
static func run_init(w: Pd2World, hooks: Hooks = null) -> int:
	match w.script_no:
		1:
			m01_init(w)
			return 0
		2: return m02_init(w)
		3: return m03_init(w)
		4: return m04_init(w)
		5: return m05_init(w)
		6: return m06_init(w)
		7: return m07_init(w)
		8: return m08_init(w)
		9: return m09_init(w)
		10: return m10_init(w, hooks)
		12: return m12_init(w)
		14: return m14_init(w)
		15: return m15_init(w)
	return 0


static func run_objective(w: Pd2World) -> int:
	match w.script_no:
		1: return m01_objective(w)
		2: return m02_objective(w)
		3: return m03_objective(w)
		4: return -1
		5: return -1
		6: return -1
		7: return m07_objective(w)
		8: return -1
		9: return -1
		10: return -1
		12: return m12_objective(w)
		14: return -1
		15: return -1
	return -1


## the sortie's deploy check: 1 passes, else the code the dialog's answer gives
static func run_deploy(w: Pd2World, hooks: Hooks) -> int:
	match w.script_no:
		1:
			if m01_state(w) == 1:
				return 1
			return DEPLOY_RESULT.get(hooks.end_dialog(0x12B), 0)
		2: return m02_deploy(w, hooks)
		3: return m03_deploy(w, hooks)
		4: return 1
		5: return 1
		6: return 1
		7: return m07_deploy(w, hooks)
		8: return 1
		9: return 1
		10: return 1
		12: return 1
		14: return 1
		15: return 1
	return 1


## caller: mission 7's two stack bytes (rules.m07_turn), [] leaves them
static func run_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks, caller := []) -> int:
	match w.script_no:
		1: return m01_turn(w, rng, stage, hooks)
		2: return m02_turn(w, rng, stage, hooks)
		3: return m03_turn(w, rng, stage, hooks)
		4: return m04_turn(w, rng, stage, hooks)
		5: return m05_turn(w, rng, stage, hooks)
		6: return m06_turn(w, rng, stage, hooks)
		7: return m07_turn(w, rng, stage, hooks, caller)
		8: return m08_turn(w, rng, stage, hooks, caller[0] if caller.size() == 1 else null)
		9: return m09_turn(w, rng, stage, hooks)
		10: return m10_turn(w, rng, stage, hooks)
		12: return m12_turn(w, rng, stage, hooks)
		14: return m14_turn(w, rng, stage, hooks)
		15: return m15_turn(w, rng, stage, hooks)
	return 0


static func run_speech(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	match w.script_no:
		1: return m01_speech(w, rng, hooks.flight)
		2: return m02_speech(w, rng, hooks)
		3: return m03_speech(w, rng, hooks)
		4: return flight_turn(w, rng, hooks)
		5: return flight_turn(w, rng, hooks)
		6: return flight_turn(w, rng, hooks)
		7: return flight_turn(w, rng, hooks)
		8: return flight_turn(w, rng, hooks)
		9: return flight_turn(w, rng, hooks)
		10: return flight_turn(w, rng, hooks)
		12: return flight_turn(w, rng, hooks)
		14: return flight_turn(w, rng, hooks)
		15: return flight_turn(w, rng, hooks)
	return 0


## the unit menu's entry 11: [1, label address] when the mission has one, else [0, -1]
static func run_menu(w: Pd2World, u: int) -> Array:
	match w.script_no:
		1: return [1, 0x51A020]
		2: return [1, 0x51A368]
		3: return [1, 0x51A4E8]
		4: return [1, 0x51A6B0]
		5: return [1, 0x51A770]
		6: return [1, 0x51A7B8]
		7: return [1, 0x51AB48 if w.ds8(0x50AD6E) & 1 else 0x51AB38]
		8: return m08_menu(w, u)
		9: return [1, 0x51B0F0]
		10: return [1, 0x51BAC0]
		12: return [1, 0x51C4E8]
		15: return m15_menu(w, u)
	return [0, -1]


static func run_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	match w.script_no:
		1: return m01_command(w, u, hooks)
		2: return m02_command(w, rng, u, hooks)
		3: return m03_command(w, rng, u, hooks)
		4: return m04_command(w, rng, u, hooks)
		5: return m05_command(w, rng, u, hooks)
		6: return m06_command(w, rng, u, hooks)
		7: return m07_command(w, rng, u, hooks)
		8: return m08_command(w, rng, u, hooks)
		9: return m09_command(w, rng, u, hooks)
		10: return m10_command(w, rng, u, hooks)
		12: return m12_command(w, rng, u, hooks)
		15: return m15_command(w, rng, u, hooks)
	return 0


## the withdraw (table 0x51F038): sets DS:0x50ADF2; false when the mission's is not ported
static func run_scenario(w: Pd2World, rng: Pd2Random) -> bool:
	match w.script_no:
		1: w.set_ds8(0x50ADF2, 0x80)
		2: m02_scenario(w, rng)
		3: w.set_ds8(0x50ADF2, m03_end_code(w))
		4: m04_scenario(w, rng)
		5: m05_scenario(w, rng)
		6: w.set_ds8(0x50ADF2, m06_end(w, rng, true))
		7: w.set_ds8(0x50ADF2, m07_end_code(w, rng) & 0xFF)
		8: m08_scenario(w, rng)
		9: m09_scenario(w, rng)
		10: w.set_ds8(0x50ADF2, 0x82)
		12: m12_scenario(w, rng)
		14: m14_scenario(w, rng)
		15: w.set_ds8(0x50ADF2, m15_code(w))
		_: return false
	return true


static func run_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	match w.script_no:
		2: return m02_bomb_rule(w, u, hooks)
		4: return m04_bomb_rule(w, u, hooks)
		7: return m07_bomb_rule(w, u, hooks)
		9: return m09_bomb_rule(w, u, hooks)
		10: return m10_bomb_rule(w, u, hooks)
		15: return m15_bomb_rule(w, u, hooks)
	return -1


static func run_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	match w.script_no:
		2: return m02_start(w, rng, hooks)
		4: return m04_start(w, rng, hooks)
		7: return m07_start(w, rng, hooks)
		8: return m08_start(w, rng, hooks)
		9: return m09_start(w, rng, hooks)
		10: return m10_start(w, rng, hooks)
		12: return m12_start(w, rng, hooks)
		15: return m15_start(w, rng, hooks)
	return 0


static func run_bomb(w: Pd2World, rng: Pd2Random, i: int, hooks: Hooks) -> int:
	match w.script_no:
		4: return m04_bomb(w, rng, i, hooks)
		7: return m07_bomb(w, rng, i, hooks)
		9: return m09_bomb(w, rng, i, hooks)
		10: return m10_bomb(w, rng, i, hooks)
		15: return m15_bomb(w, rng, i, hooks)
	return 0


# --- shared helpers --------------------------------------------------------------------

static func static_s16(w: Pd2World, addr: int) -> int:
	var v := w.mem8(addr) | w.mem8(addr + 1) << 8
	return v - 0x10000 if v >= 0x8000 else v


## a load script's copy of exe data (rep movsd)
static func static_copy(w: Pd2World, dst: int, src: int, n: int) -> void:
	var data := PackedByteArray()
	for i in n:
		data.append(w.mem8(src + i))
	for i in n:
		w.mem_write(dst + i, data[i])


## occupant_at (0x46EC80) as the scripts call it: no bounds check (x = -1 reads the row
## before's last hex); outside the layer the game reads other memory (a fault here)
static func occupant_raw(w: Pd2World, x: int, y: int) -> int:
	var i := x + MAP * y
	if i < 0 or i >= MAP * MAP:
		w.fault = "occupant_at outside the layer (%d, %d)" % [x, y]
		return -1
	return w.O[i] - 1


## 0x46EE30: the hex's T byte (t, -1 unchanged) and H byte (h, -1 or 0-128)
static func set_height_tile(w: Pd2World, x: int, y: int, t: int, h: int) -> void:
	if not ((t == -1 or (t >= 0 and t < 0x100)) and (h == -1 or (h >= 0 and h < 0x81))):
		return
	if t != -1:
		w.T[x + MAP * y] = t & 0xFF
	if h != -1:
		w.H[x + MAP * y] = h & 0xFF


## 0x43BD20: active units whose status is side
static func count_side_active(w: Pd2World, side: int) -> int:
	var n := 0
	for k in mini(w.units.size() / 55, 254):
		if w.active(k) and w.sb(k, 0x36) == side:
			n += 1
	return n


## 0x4DDC80: rounds of ammunition a held by units 0-63 whose crew has +2 < 3 and +4 not
## after DS:0x50AD92, plus the stock; above 0xFF the low byte reads 0xFF
static func owned_ammo(w: Pd2World, a: int) -> int:
	var n := 0
	var t := w.ds16(0x50AD92)
	for c in 64:
		if w.crew[c * 16 + 2] < 3 and Flight.s16(w.crew[c * 16 + 4] | w.crew[c * 16 + 5] << 8) <= t:
			for i in 12:
				if w.ub(c, 0x1B + 2 * i) == a:
					n += 1
	n += w.mem8(0x5066D4 + a)
	return n | 0xFF if n > 0xFF else n


## the inits' word write at DS:0x506651
static func set_506651(w: Pd2World, v: int) -> void:
	w.ds_506651 = v & 0xFF
	if not w.head.is_empty():
		w.head[0x1A] = v >> 8 & 0xFF


## 0x471000 / 0x471020: crew c's +6 |= bit
static func mark_crew(w: Pd2World, c: int, bit: int) -> void:
	var a := 0x506734 + 16 * Pd2World.s8(c) + 6
	w.mem_write(a, w.mem8(a) | bit)


## 0x417410 at (x, y) unless skipped: [code, skip]; its end empties the hex of a unit at
## condition 0 unless the player skipped it
static func blast(w: Pd2World, hooks: Hooks, x: int, y: int, skip: bool) -> Array:
	if skip:
		return [0, true]
	var r := hooks.blast(x, y)
	if r in AI_ABORT:
		return [r, skip]
	if r == 0x80000:
		return [0, true]
	Turn.explosion_clear(w, x, y, hooks.options)
	return [0, false]


static func ds_or(w: Pd2World, addr: int, bit: int) -> void:
	w.set_ds8(addr, w.ds8(addr) | bit)


## 0x428D80, "set explosives" (rules.lay_explosive): u lays its pocket p round on its hex.
## Returns 1 when laid (the caller charges ap), 0, or an abort code.
static func lay_explosive(w: Pd2World, u: int, p: int, ap: int, hooks: Hooks) -> int:
	if w.sb(u, 0xE) < ap:
		var res := hooks.line(0x1E9, [ap])
		return res if res in AI_ABORT else 0
	var a := w.pocket_ammo(u, p)
	if a >= 96:
		w.fault = "lay_explosive: no round in the pocket"
		return 0
	if w.ammo(a, 8) & 0x20:
		var res := hooks.prompt(0x1BD, [ap])
		if res in AI_ABORT:
			return res
		if res != 0:
			return 0
		var q := w.pos(u)
		_take_round(w, u, p)
		w.F[q.x + MAP * q.y] |= (2 if w.sb(u, 0x36) > 2 else 1) << 6
		return 1
	var v := run_bomb_rule(w, u, hooks)
	if v in AI_ABORT:
		return v
	if v == -1:
		var res := hooks.prompt(0x1EA, [ap])
		if res in AI_ABORT:
			return res
		if res != 0:
			return 0
		var f := hooks.fuse(0x1EB, 1)
		if f in AI_ABORT:
			return f
		if f == -2:
			return 0
		_take_round(w, u, p)
		for i in 15:
			if not w.on_map(Pd2World.s8(w.bombs[4 * i]), Pd2World.s8(w.bombs[4 * i + 1])):
				w.bombs[4 * i] = w.ub(u, 9)
				w.bombs[4 * i + 1] = w.ub(u, 10)
				w.bombs[4 * i + 2] = (f + 1) & 0xFF
				w.bombs[4 * i + 3] = 0xFF
				break
		return 1
	if v == -2:
		return 0
	var f := -1
	var flag := v - 0x14
	if v < 0x15:
		f = hooks.fuse(0x1EB, 1)
		if f in AI_ABORT:
			return f
		flag = v
	if f == -2:
		return 0
	_take_round(w, u, p)
	for i in 15:
		var x := Pd2World.s8(w.bombs[4 * i])
		var y := Pd2World.s8(w.bombs[4 * i + 1])
		if x == -1 or x < 0 or x > 0x47 - (y & 1) or y < 0 or y > 0x47:
			w.bombs[4 * i] = w.ub(u, 9)
			w.bombs[4 * i + 1] = w.ub(u, 10)
			w.bombs[4 * i + 2] = 0xFF if f == -1 else (f + 1) & 0xFF
			w.bombs[4 * i + 3] = flag & 0xFF
			break
	return 1


static func _take_round(w: Pd2World, u: int, p: int) -> void:
	var k := 0x1C + 2 * p
	var c := w.pocket_count(u, p)
	w.setb(u, k, (w.ub(u, k) & 0xC0) | ((c - 1) & 0x3F))
	if w.pocket_count(u, p) == 0:
		w.setb(u, 0x1B + 2 * p, 0xFF)


# --- mission 2 (script 2, PD2 chunk 1: the two bridges; rules.m02_*) ----------------------

const M02_POINTS := 0x517F3C


static func m02_load(w: Pd2World) -> void:
	static_copy(w, 0x51A0A8, 0x51A128, 0x80)
	static_copy(w, 0x51A1A8, 0x51A1C8, 0x20)
	static_copy(w, 0x51A1E8, 0x51A268, 0x80)
	static_copy(w, 0x51A2E8, 0x51A328, 0x40)


static func m02_init(w: Pd2World) -> int:
	for p in [[0x50AD99, 14], [0x50AD9D, 14], [0x50ADA1, 14], [0x50AD95, 8], [0x50AD97, 7],
			[0x50AD9B, 7], [0x50AD9F, 8], [0x50ADA3, 9], [0x50ADA5, 0], [0x50ADA7, 3],
			[0x50ADA9, 0], [0x50ADAB, 4], [0x50ADAD, 0], [0x50ADAF, 5]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51A048 + i)
		w.ds[0xD1 + i] = w.mem8(0x51A068 + i)
	var n := owned_ammo(w, 0xC) & 0xFF
	if n < 10:
		w.mem_write(0x5066E0, w.mem8(0x5066E0) + 10 - n)
	set_506651(w, 99)
	return 0


static func m02_objective(w: Pd2World) -> int:
	var landed := false
	for grp in [0, 2, 4]:
		if g(w, grp, 0x21) & 0xF in [2, 3]:
			landed = true
	if not landed:
		return 0x10A
	for grp in range(12, 20):
		if g(w, grp, 0x21) & 0xF == 4:
			return -1
	return 0x10B


static func m02_deploy(w: Pd2World, hooks: Hooks) -> int:
	var formed := false
	for grp in [0, 2, 4]:
		if g(w, grp, 5) and g(w, grp, 0x21) & 0xF in [2, 3]:
			formed = true
	if not formed:
		return DEPLOY_RESULT.get(hooks.end_dialog(0x12C), 0)
	for grp in range(12, 20):
		if g(w, grp, 0x21) & 0xF == 4 and g(w, grp, 5):
			for i in 16:
				var m := g(w, grp, 6 + i)
				if m != 0xFF and Pd2World.s8(table_byte(w, 55 * m + 0xC)) != -1:
					return 1
	return DEPLOY_RESULT.get(hooks.end_dialog(0x12D), 0)


static func flight_turn(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	var r: Variant = hooks.flight_turn()
	if r != null:
		return int(r)
	return Flight.flight_turn(w, rng, hooks.flight)


static func m02_speech(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	if not w.ds8(0x50AD70) & 1:
		for grp in 20:
			if g(w, grp, 0x21) & 0xF0 == 0x60 and g(w, grp, 2) & 0x30 == 0x20:
				w.set_ds8(0x50ADF1, 1)
				ds_or(w, 0x50AD70, 1)
				break
	return flight_turn(w, rng, hooks)


static func m02_blow(w: Pd2World, b: int, live: int, hooks: Hooks) -> int:
	var res := hooks.blast_open()
	if res in AI_ABORT:
		return res
	ds_or(w, 0x50AD78, 0x40 if b == 0 else 0x80)
	var c := Vector2i(0x16, 0x12) if b == 0 else Vector2i(0xD, 0x37)
	res = hooks.blast_start(c.x, c.y)
	if res in AI_ABORT:
		return res
	var skip := res == 0x80000
	for i in 16:
		var x := static_s16(w, 0x51A1E8 + 0x40 * b + 4 * i)
		var y := static_s16(w, 0x51A1EA + 0x40 * b + 4 * i)
		if live == 1 and i < 8:
			var bl := blast(w, hooks, x, y, skip)
			skip = bl[1]
			if bl[0]:
				return bl[0]
			for _j in 2:
				var o := occupant_raw(w, x, y)
				if o != -1:
					Action.destroy(w, o)
					w.setb(o, 0, w.ub(o, 0) | 1)
					w.setb(o, 0xD, 0)
		set_height_tile(w, x, y, static_s16(w, 0x51A2E8 + 4 * i), static_s16(w, 0x51A2EA + 4 * i))
	res = hooks.blast_close()
	return res if res in [0x10000, 0x20000] else 0


static func _m02_points_set(w: Pd2World, b: int) -> int:
	var n := 0
	for i in 6:
		if w.ds8(0x50AD51 + 12 * b + 2 * i) & 0xF == 1:
			n += 1
	return n


static func _m02_end_code(w: Pd2World) -> int:
	var f := w.ds8(0x50AD78)
	if f & 0x40 and f & 0x80:
		return 0x80
	if not f & 0x40 and not f & 0x80:
		return 0x82
	return 0x83


static func m02_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var n_units := mini(w.units.size() / 55, 254)
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		if count_side_active(w, 0):
			for b in 2:
				if _m02_points_set(w, b) > 2:
					var res := hooks.scroll(0x16, 0x12) if b == 0 else hooks.scroll(0xD, 0x37)
					if res in AI_ABORT:
						return res
					res = hooks.dialog(0xA8, [], 2)
					if res in AI_ABORT:
						return res
					if res == 0:
						for i in 6:
							var a := 0x50AD51 + 12 * b + 2 * i
							var x := static_s16(w, M02_POINTS + 24 * b + 4 * i)
							var y := static_s16(w, M02_POINTS + 24 * b + 4 * i + 2)
							w.set_ds8(a, w.ds8(a) & 0xF2 | 2)
							for j in 15:
								if Pd2World.s8(w.bombs[4 * j]) == x and Pd2World.s8(w.bombs[4 * j + 1]) == y:
									w.bombs[4 * j] = 0xFF
									break
						res = m02_blow(w, b, 1, hooks)
						if res in AI_ABORT:
							return res
		var res := m02_speech(w, rng, hooks)
		if res in AI_ABORT:
			return res
	elif stage == 1:
		for grp in range(12, 20):
			var f := g(w, grp, 2)
			if not (g(w, grp, 5) and g(w, grp, 0x21) & 0xF0 == 0x60 and f & 0x30 == 0x20 and f & 0xC0 == 0x80):
				continue
			var cnt := g(w, grp, 0x20)
			if cnt != 1 and cnt != 2:
				continue
			var res := hooks.box(0xAC if cnt == 2 else 0xAD, [["sign", g(w, grp, 1)]], 1)
			if res in AI_ABORT:
				return res
			if res == 0:
				var v := w.ds8(0x50AD75)
				if v & 0xF < 0xF:
					w.set_ds8(0x50AD75, v ^ ((v + 1) ^ v) & 0xF)
				if cnt == 1:
					set_g(w, grp, 0x20, 2)
			else:
				set_g(w, grp, 0x20, 0)
				set_g(w, grp, 2, g(w, grp, 2) & 0x3F | 0x40)
		var nib := w.ds8(0x50AD75) & 0xF
		if nib == 2 or nib == 4:
			var pairs := [[0x19, 8], [0x1A, 7]] if nib == 2 else [[0x1B, 8], [0x1C, 7]]
			for p in pairs:
				var t: int = (w.mission_turn + p[1]) & 0xFFFF
				set_g(w, p[0], 0x1D, t & 0xFF)
				set_g(w, p[0], 0x1E, t >> 8)
		var n20 := 0
		var n30 := 0
		var nle := 0
		for grp in range(12, 20):
			if g(w, grp, 5) and g(w, grp, 0x21) & 0xF0 == 0x60:
				var s := g(w, grp, 2) & 0x30
				if s == 0x30:
					n30 += 1
				if s <= 0x20:
					nle += 1
					if s == 0x20:
						n20 += 1
		var alive := 0
		for k in n_units:
			var f0 := w.ub(k, 0)
			if w.ub(k, 0x36) == 0 and f0 & 4 and w.ub(k, 0xD) and not f0 & 1 and w.ub(k, 9) != 0xFF:
				alive += 1
		var none_left := n20 == 0 and alive == 0
		if none_left:
			for grp in [0, 2, 4]:
				if not (g(w, grp, 2) & 0x30 or not g(w, grp, 5)):
					none_left = false
		var end := none_left
		if n30 != 0:
			if alive == 0:
				end = true if n20 == 0 else none_left
			else:
				end = true if nle == 0 else none_left
		if end:
			for k in n_units:
				if w.ub(k, 0x36) != 0 and not w.ub(k, 0) & 4:
					continue
				if w.ub(k, 9) == 0xFF or w.ub(k, 0xC) == 0xFF:
					if w.ub(k, 0x33) == w.ub(k, 0x34) and w.ub(k, 0x33) != 0xFF:
						w.setb(k, 0, w.ub(k, 0) | 1)
						w.setb(k, 0xD, 0)
						w.setb(k, 0x33, 0xFF)
						w.setb(k, 0x34, 0xFF)
				else:
					w.setb(k, 0, w.ub(k, 0) | 2)
					mark_crew(w, w.ub(k, 0xB), 1)
			w.set_ds8(0x50ADF2, _m02_end_code(w))
	if not w.ds16(0x50AD4E) & 1:
		group_scan(w)
		var v := rng.roll(3) & 0xFFFF
		if v != 2:
			for i in 16:
				var k := 0x38 + i
				w.mem_write(UNITS_ADDR + 55 * k + 9, w.mem8(0x51A0A8 + 0x40 * v + 4 * i))
				w.mem_write(UNITS_ADDR + 55 * k + 0xA, w.mem8(0x51A0AA + 0x40 * v + 4 * i))
				var f := w.mem8(UNITS_ADDR + 55 * k + 5)
				w.mem_write(UNITS_ADDR + 55 * k + 5, (w.mem8(0x51A1A8 + 0x10 * v + i) ^ f) & 7 ^ f)
		var res := hooks.speech_window()
		if res in AI_ABORT:
			return res
		w.set_ds16(0x50AD4E, w.ds16(0x50AD4E) | 1)
	return 0


const UNITS_ADDR := 0x506C93


static func m02_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	if w.ub(u, 0x34) != 0xFF:
		return {-3: 0x20000, -2: 0x40000, -1: 0x10000}.get(hooks.line(0xAE), 0)
	var ok := false
	for grp in range(12, 20):
		var f := g(w, grp, 2)
		if g(w, grp, 5) and g(w, grp, 0x21) & 0xF0 == 0x60 and f & 0x30 == 0x20 and f & 0xC0 == 0x80:
			ok = true
	if not ok:
		var res := hooks.message(0xA9)
		return res if res in AI_ABORT else 0
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	var found := -1
	for h in Ai.spiral(x, y, 2):
		var o := occupant_raw(w, h.x, h.y)
		if w.fault != "":
			return 0
		if o != -1 and w.sb(o, 0xC) == 0xC:
			found = o
			break
	if found == -1:
		var res := hooks.message(0xAA)
		return res if res in AI_ABORT else 0
	var res := hooks.box(0xAB, [], 0)
	if res in AI_ABORT:
		return res
	if res == 0:
		return 0
	res = hooks.blast_open()
	if res in AI_ABORT:
		return res
	res = hooks.blast_start(x, y)                 # (its skip is not looked at)
	if res in AI_ABORT:
		return res
	var bl := blast(w, hooks, x, y, false)
	if bl[0]:
		return bl[0]
	Action.take_off_map(w, u)                     # 0x47FFA0
	res = hooks.blast_close()
	if res in [0x10000, 0x20000]:
		return res
	w.setb(u, 0x34, found & 0xFF)
	w.setb(u, 0x33, found & 0xFF)
	return -1


static func m02_scenario(w: Pd2World, rng: Pd2Random) -> int:
	for k in mini(w.units.size() / 55, 254):
		if w.sb(k, 0x36) >= 3 or not w.ub(k, 0) & 4:
			continue
		var c := w.sb(k, 0xB)
		var qa := 0x506734 + 16 * c
		if not w.mem8(qa + 6) & 3:
			if w.ub(k, 0x33) == w.ub(k, 0x34) and w.ub(k, 0x33) != 0xFF:
				if not w.ub(k, 0) & 1:
					w.setb(k, 0, w.ub(k, 0) | 1)
					var b := w.ub(k, 0x34)
					w.setb(k, 0xD, 0)
					if b != 0xFF:
						var gb := 0x50A35C + 35 * b
						if (w.mem8(gb + 2) & 0x30 != 0x30 or w.mem8(gb + 0x16) != 0xFF) and (rng.roll(100) & 0xFFFF) & 1 == 0:
							mark_crew(w, c, 2)
			else:
				mark_crew(w, c, 1)
				if not w.ub(k, 0) & 1:
					if (rng.roll(100) & 0xFFFF) & 1 == 0:
						w.setb(k, 0, w.ub(k, 0) | 1)
						w.setb(k, 0xD, 0)
					else:
						w.setb(k, 0, w.ub(k, 0) | 2)
		var gb2 := 0x50A35C + 35 * w.mem8(qa + 5)
		if w.mem8(gb2 + 0x21) & 0xF0 == 0x60 and w.mem8(gb2 + 2) & 0x30 == 0x30 and w.mem8(gb2 + 0x16) != 0xFF:
			w.setb(k, 0, w.ub(k, 0) | 1)
			w.setb(k, 0xD, 0)
			if (rng.roll(100) & 0xFFFF) & 1 == 0:
				mark_crew(w, c, 2)
	w.set_ds8(0x50ADF2, _m02_end_code(w))
	return 0


static func m02_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	var i := -1
	for j in 15:
		if static_s16(w, M02_POINTS + 4 * j) == x and static_s16(w, M02_POINTS + 4 * j + 2) == y:
			i = j
			break
	if i == -1:
		return -1
	var b := 0 if i < 6 else 1
	var n := _m02_points_set(w, b)
	if w.ds8(0x50AD78) & (0x40 if b == 0 else 0x80):
		var res := hooks.message(0xA7)
		return res if res in AI_ABORT else -2
	var res := hooks.message(0xA1, [n, 3 - n]) if n < 3 else hooks.message(0xA2, [n])
	if res in AI_ABORT:
		return res
	var a := 0x50AD51 + 2 * i
	var st := w.mem8(a) & 0xF
	if st == 0:
		res = hooks.dialog(0xA3, [], 2)
		if res in AI_ABORT:
			return res
		if res != 0:
			return -2
		w.mem_write(a, w.mem8(a) & 0xF1 | 1)
		res = hooks.message(0xA4, [2 - n]) if n < 2 else hooks.message(0xA5)
		if res in AI_ABORT:
			return res
		return i + 0x15
	if st != 1:
		return -2
	res = hooks.message(0xA6)
	return res if res in AI_ABORT else -2


static func m02_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	if w.ds8(0x50AD51) & 0xF == 2:
		m02_blow(w, 0, 0, hooks)
	if w.ds8(0x50AD5D) & 0xF == 2:
		m02_blow(w, 1, 0, hooks)
	return 0


# --- shared by the capture-and-escape missions (rules.speech_arrival ...) ----------------

## one group's arrival scene in a speech hook: null when nothing happened, else 0 or an
## abort code; lines = [normal, pair first, pair second, other nibble]
static func speech_arrival(w: Pd2World, rng: Pd2Random, hooks: Hooks, grp: int, flag: int,
		other: int, other_flag: int, lines: Array, table: int) -> Variant:
	var arr := Flight.s16(g(w, grp, 0x1D) | g(w, grp, 0x1E) << 8)
	if w.ds8(flag) & 1 or arr > w.mission_turn or not g(w, grp, 5):
		return null
	ds_or(w, flag, 1)
	var R := func(o: int) -> int: return Flight.gb(w, grp, o)
	var face: Variant = Flight._radio_speaker(w, rng, R)[1]
	var steps := []
	if g(w, grp, 0x21) & 0xF == 0:
		if g(w, other, 5) and g(w, other, 0x21) & 0xF == 1 and w.ds8(other_flag) & 1:
			steps = [["face", 3, 0x3A, null], ["say", lines[1], 0x3A], ["face", face, 0xB, null], ["say", lines[2], 0xB]]
		else:
			steps = [["face", face, 0x1A, 0], ["face", 0xC, 0x1A, 1], ["say", lines[0], 0x1A]]
	else:
		steps = [["face", face, 0x1A, 0], ["face", 0xC, 0x1A, 1], ["say", lines[3], 0x1A]]
	for st in steps:
		var res: int
		if st[0] == "say":
			var args: Variant = st[3] if st.size() > 3 else []
			res = hooks.flight.radio_say(st[1], args.call() if args is Callable else args, st[2])
		else:
			res = Flight._radio_face(w, hooks.flight, st[1], st[2], st[3])
		if res in AI_ABORT:
			hooks.flight.radio_close(-1)
			return res
	hooks.flight.radio_close(-1)
	var n := 0
	for i in 16:
		var k := g(w, grp, 6 + i)
		if k != 0xFF:
			w.mem_write(UNITS_ADDR + 55 * k + 9, w.mem8(table + 4 * n))
			w.mem_write(UNITS_ADDR + 55 * k + 0xA, w.mem8(table + 4 * n + 2))
			n += 1
	return 0


static func place_groups_at_camera(w: Pd2World, groups := [0, 2]) -> void:
	var px := w.ds8(0x50AD95)
	var py := w.ds8(0x50AD97)
	for grp in groups:
		for f in [G_X, G_PREV_X, G_TARGET_X]:
			set_g(w, grp, f, px)
			set_g(w, grp, f + 1, py)
		set_g(w, grp, G_F28, 0)
		set_g(w, grp, G_F34, 0)


## 0x4DE1F0: does any unit 0-253 carry k?
static func carried_by_any(w: Pd2World, k: int) -> bool:
	for i in mini(w.units.size() / 55, 254):
		if w.ub(i, 0x34) == k:
			return true
	return false


static func smoke_anywhere(w: Pd2World) -> bool:
	for i in MAP * MAP:
		if w.F[i] & 1:
			return true
	return false


## the capture missions' building test (rules.spiral_terrain_quirk)
static func spiral_terrain_quirk(w: Pd2World, x: int, y: int) -> bool:
	var flat := []
	for p in Ai.spiral(x, y, 1):
		flat.append(p.x)
		flat.append(p.y)
	for k in flat.size() / 2 - 1:
		var v: int = flat[k + 1] & 0xFFFFFFFF
		var i := (Flight.s16(v >> 16 & 0xFFFF) * 0x48 + Flight.s16(v & 0xFFFF)) & 0xFFFF
		if i >= MAP * MAP:
			w.fault = "spiral quirk: T past the layer"
			return false
		if w.terrain[w.T[i]] in [7, 8]:
			return true
	return false


# --- mission 3 (script 3, PD2 chunk 2: a capture and an escape; rules.m03_*) -------------

static func m03_load(w: Pd2World) -> void:
	static_copy(w, 0x51A418, 0x51A450, 0x38)
	static_copy(w, 0x51A488, 0x51A4A0, 0x18)
	static_copy(w, 0x51A4B8, 0x51A4D0, 0x18)


static func m03_init(w: Pd2World) -> int:
	w.set_ds16(0x50AD95, 5)
	w.set_ds16(0x50AD97, 0xD)
	for a in range(0x50AD99, 0x50ADB1, 2):
		w.set_ds16(a, 0)
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x524180 + i)
		w.ds[0xD1 + i] = w.mem8(0x5241A0 + i)
	for c in 64:
		var rec := Pd2World.s8(w.crew[c * 16 + 15])
		if rec >= 0:
			for i in 8:
				w.mem_write(0x506B39 + 13 * rec + i, 0)
	set_506651(w, 0xA8)
	return 0


static func m03_objective(w: Pd2World) -> int:
	return -1 if g(w, 0, 0x21) & 0xF == 0 or g(w, 2, 0x21) & 0xF == 0 else 0x10A


static func m03_deploy(w: Pd2World, hooks: Hooks) -> int:
	for grp in [0, 2]:
		if g(w, grp, 0x21) & 0xF == 0 and g(w, grp, 5):
			return 1
	return DEPLOY_RESULT.get(hooks.end_dialog(0x12B), 0)


static func m03_speech(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	var res := flight_turn(w, rng, hooks)
	if res in AI_ABORT:
		return res
	for p in [[0, 0x50AD76, 2, 0x50AD78, [0xA3, 0xA1, 0xA2, 0xA4], 0x51A488],
			[2, 0x50AD78, 0, 0x50AD76, [0xAE, 0xA1, 0xAD, 0xA4], 0x51A4B8]]:
		var r: Variant = speech_arrival(w, rng, hooks, p[0], p[1], p[2], p[3], p[4], p[5])
		if r != null and int(r) in AI_ABORT:
			return int(r)
	return 0


static func m03_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	if w.sb(u, 0xE) < 0x14:
		var res := hooks.message(0xA9)
		return res if res in AI_ABORT else 0
	var res := hooks.dialog(0xA5, [], 2)
	if res in AI_ABORT:
		return res
	if res != 0:
		return 0
	var p := Vector2i(w.sb(u, 9), w.sb(u, 10))
	var f := w.ds8(0x50AD7A)
	if not f & 1 and (p == Vector2i(0x33, 0x35) or p == Vector2i(0x34, 0x35)):
		res = hooks.message(0xA6)
		if res in AI_ABORT:
			return res
		w.setb(u, 0xE, (w.ub(u, 0xE) - 0x14) & 0xFF)
		w.set_ds8(0x50AD7A, (w.ub(u, 0xB) & 0x1F) << 1 | (f & 0xC1) | 1)
		return 0
	var m := 0
	if (not f & 1 and not f & 0x80 and p == Vector2i(0x2F, 0x18)) or p == Vector2i(0x2E, 0x18):
		w.set_ds8(0x50AD7A, f | 0x80)
		m = 0xAC
	elif spiral_terrain_quirk(w, p.x, p.y):
		m = 0xA7
	else:
		res = hooks.message(0xA8)
		return res if res in AI_ABORT else 0
	res = hooks.message(m)
	if res in AI_ABORT:
		return res
	w.setb(u, 0xE, (w.ub(u, 0xE) - 0x14) & 0xFF)
	return 0


static func m03_end_code(w: Pd2World) -> int:
	var f := w.ds8(0x50AD7A)
	if not f & 1:
		return 0x83 if f & 0x80 else 0x82
	return 0x80 if not w.ub(f >> 1 & 0x1F, 0) & 1 else 0x82


static func m03_casualties(w: Pd2World, rng: Pd2Random) -> void:
	for k in mini(w.units.size() / 55, 254):
		if w.sb(k, 0x36) >= 3 or not w.ub(k, 0) & 4:
			continue
		var c := w.ub(k, 0xB)
		if w.ub(k, 9) == 0xFF and not carried_by_any(w, k):
			if w.ub(k, 0) & 1 and (rng.roll(100) & 0xFFFF) & 3 != 2:
				mark_crew(w, c, 2 if (rng.roll(100) & 0xFFFF) & 1 == 0 else 1)
		elif (rng.roll(100) & 0xFFFF) & 3 != 2:
			if (rng.roll(100) & 0xFFFF) & 1 == 0:
				w.setb(k, 0, w.ub(k, 0) | 1)
				w.setb(k, 0xD, 0)
				if (rng.roll(100) & 0xFFFF) & 3 != 2:
					mark_crew(w, c, 2 if (rng.roll(100) & 0xFFFF) & 1 == 0 else 1)
			else:
				w.setb(k, 0, w.ub(k, 0) | 2)
				mark_crew(w, c, 2)


static func m03_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var n_units := mini(w.units.size() / 55, 254)
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
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
						if st > 2 and st < 6 and w.ub(u, 0xD) and w.ub(u, 3) & 0xF0 == 0x10:
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
					var fl := w.ub(u, 0)
					if w.sb(u, 0x36) < 3:
						if c == 100 and not fl & 1 and fl & 4:
							fit += 1
						if c and w.ub(u, 9) != 0xFF and fl & 0x10 and fl & 4:
							seen = true
							if c != 100:
								hurt += 1
					elif c and w.ub(u, 9) != 0xFF:
						enemies += 1
						if c != 100:
							hurt += 1
				var shots := 0
				for c in 64:
					shots = crew_shots(w, c)
					if shots:
						break
				if fit < 5 or seen or smoke_anywhere(w) or enemies < 0x20 or hurt or shots:
					w.set_ds8(0x50ADF1, 1)
					w.set_ds16(0x50AD74, w.ds16(0x50AD74) | 1)
		var res := m03_speech(w, rng, hooks)
		if res in AI_ABORT:
			return res
	elif stage == 1 and w.ds8(0x50AD7A) & 1:
		var exits := []
		for i in 14:
			exits.append(Vector2i(static_s16(w, 0x51A418 + 4 * i), static_s16(w, 0x51A41A + 4 * i)))
		for u in n_units:
			if w.ub(u, 0xD) and w.ub(u, 9) != 0xFF and w.sb(u, 0x36) < 3 and w.ub(u, 0) & 4:
				var p := Vector2i(w.sb(u, 9), w.sb(u, 10))
				if p in exits:
					var res := hooks.scroll(p.x, p.y)
					if res in AI_ABORT:
						return res
					res = hooks.dialog(0xAA, [w.ucrew(u, 0)], 2)
					if res in AI_ABORT:
						return res
					if res == 0:
						if w.ub(u, 0x34) == 0xFF:
							Action.take_off_map(w, u)
						else:
							res = hooks.message(0xAB)
							if res in AI_ABORT:
								return res
	if not w.ds16(0x50AD4E) & 1:
		group_scan(w)
		place_groups_at_camera(w)
		var res := hooks.speech_window()
		if res in AI_ABORT:
			return res
		w.set_ds16(0x50AD4E, w.ds16(0x50AD4E) | 1)
	for u in n_units:
		if w.ub(u, 0xD) and w.sb(u, 0x36) <= 2 and w.ub(u, 0) & 4 and w.ub(u, 9) != 0xFF:
			return 0
	for grp in [0, 2, 4]:
		if g(w, grp, 5) and not g(w, grp, 2) & 0x30 and not w.ds8(0x50AD7A) & 1:
			return 0
	m03_casualties(w, rng)
	w.set_ds8(0x50ADF2, m03_end_code(w))
	return 0


# --- helpers of the later missions (rules.group_of_member ...) ----------------------------

## 0x4DE240: the first group 0-63 with members that lists k, or -1
static func group_of_member(w: Pd2World, k: int) -> int:
	for grp in 64:
		if g(w, grp, 5):
			for i in 16:
				if g(w, grp, 6 + i) == k:
					return grp
	return -1


## a 5-bit counter in bits 1-5 of a DS byte: + 1 while below cap
static func count5(w: Pd2World, addr: int, cap: int) -> void:
	var v := w.ds8(addr)
	if v & 0x3E < cap:
		w.set_ds8(addr, v ^ ((v & 0xFE) + 2 ^ v) & 0x3E)


## the 64 pairs at DS:0x50DC78: (n, 1), n running 0x27-0x3D and round again
static func fill_support_list(w: Pd2World) -> void:
	var n := 0x27
	for i in 64:
		w.mem_write(0x50DC78 + 2 * i, n)
		w.mem_write(0x50DC79 + 2 * i, 1)
		n += 1
		if n == 0x3E:
			n = 0x27


## a run of radio windows: [kind, a, code, slot or args, checked]; the windows close in any
## case. Returns 0 or the first checked abort code.
static func radio_lines(w: Pd2World, hooks: Hooks, steps: Array) -> int:
	for st in steps:
		var res: int
		if st[0] == "face":
			res = Flight._radio_face(w, hooks.flight, st[1], st[2], st[3])
		else:
			res = hooks.flight.radio_say(st[1], st[3], st[2])
		if st[4] and res in AI_ABORT:
			hooks.flight.radio_close(-1)
			return res
	hooks.flight.radio_close(-1)
	return 0


static func line_code(res: int) -> int:
	return {-3: 0x20000, -2: 0x40000, -1: 0x10000}.get(res, 0)


static func on_map_unit(w: Pd2World, k: int) -> bool:
	return w.ub(k, 0xD) != 0 and w.ub(k, 9) != 0xFF


# --- mission 4 (script 4, PD2 chunk 3: the breakout and four demolitions; rules.m04_*) ----

const M04_SITES := [[0x51A560, 8, 0x50AD50], [0x51A5B0, 9, 0x50AD52], [0x51A610, 8, 0x50AD54], [0x51A660, 8, 0x50AD56]]


static func m04_load(w: Pd2World) -> void:
	static_copy(w, 0x51A560, 0x51A588, 40)
	static_copy(w, 0x51A5B0, 0x51A5E0, 45)
	static_copy(w, 0x51A610, 0x51A638, 40)
	static_copy(w, 0x51A660, 0x51A688, 40)


static func m04_init(w: Pd2World) -> int:
	for p in [[0x50AD95, 7], [0x50AD97, 7], [0x50AD9B, 9], [0x50AD99, 14], [0x50AD9D, 14],
			[0x50ADA3, 14], [0x50AD9F, 11], [0x50ADA1, 11], [0x50ADA5, 0], [0x50ADA7, 0],
			[0x50ADA9, 0], [0x50ADAB, 0], [0x50ADAD, 0], [0x50ADAF, 0]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51A528 + i)
		w.ds[0xD1 + i] = w.mem8(0x5241D0 + i)
	set_506651(w, 0x84)
	return 0


static func m04_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	var n := w.ds8(0x50AD78) >> 1 & 0x1F
	var res := hooks.message(0xA1, [n, 0x15 - n])
	return res if res in AI_ABORT else 0


static func m04_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	var p := Vector2i(w.sb(u, 9), w.sb(u, 10))
	if p in [Vector2i(0x3E, 0x36), Vector2i(0x3D, 0x37), Vector2i(0x3D, 0x38)]:
		return 1
	if p in [Vector2i(0x12, 0x44), Vector2i(0x12, 0x45)]:
		return 2
	if p in [Vector2i(0x11, 0x3A), Vector2i(0x10, 0x3B), Vector2i(0x10, 0x3C)]:
		return 3
	if p in [Vector2i(0x27, 0x12), Vector2i(0x26, 0x13), Vector2i(0x26, 0x14)]:
		return 4
	return -1


static func _m04_break(w: Pd2World, site: int) -> void:
	var t: Array = M04_SITES[site]
	for i in int(t[1]):
		var a: int = t[0] + 5 * i
		set_height_tile(w, static_s16(w, a), static_s16(w, a + 2), w.mem8(a + 4), 0x1E)


static func m04_bomb(w: Pd2World, rng: Pd2Random, i: int, hooks: Hooks) -> int:
	var site := w.mem8(0x50AC1F + 4 * i)
	if site >= 1 and site <= 4:
		_m04_break(w, site - 1)
		ds_or(w, M04_SITES[site - 1][2], 1)
	return 0


static func m04_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	for s in 4:
		if w.ds8(0x50AD50 + 2 * s) & 1:
			m04_bomb(w, rng, s + 1, hooks)
	if w.ds8(0x50AD70) & 1:
		fill_support_list(w)
	for s in 4:
		if w.ds8(M04_SITES[s][2]) & 1:
			_m04_break(w, s)
	return 0


static func m04_fates(w: Pd2World, rng: Pd2Random, code: int) -> void:
	if not code in [0x80, 0x82, 0x83]:
		return
	for grp in 20:
		if not g(w, grp, 5):
			continue
		for i in 16:
			var m := g(w, grp, 6 + i)
			if m == 0xFF:
				continue
			var base := UNITS_ADDR + 55 * m
			var dead := w.mem8(base) & 1
			var c := w.mem8(base + 0xB)
			if code == 0x82:
				if not dead:
					if (rng.roll(100) & 0xFFFF) & 1 == 0:
						if (rng.roll(100) & 0xFFFF) & 1 == 0:
							w.mem_write(base, w.mem8(base) | 2)
							mark_crew(w, c, 1)
						else:
							w.mem_write(base, w.mem8(base) | 1)
							w.mem_write(base + 0xD, 0)
							mark_crew(w, c, 2 if (rng.roll(100) & 0xFFFF) & 1 else 1)
				elif (rng.roll(100) & 0xFFFF) & 1 == 0:
					mark_crew(w, c, 1 if (rng.roll(100) & 0xFFFF) & 1 == 0 else 2)
			elif dead and (rng.roll(100) & 0xFFFF) % 3 == 1:
				mark_crew(w, c, 2)


static func _drawn_group(w: Pd2World, rng: Pd2Random) -> int:
	var grp := rng.roll(3) & 0xFFFF
	while not g(w, 2 * grp, 5):
		grp = rng.roll(3) & 0xFFFF
	return 2 * grp


static func m04_escaped(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	if g(w, 0, 5) + g(w, 2, 5) + g(w, 4, 5):
		var grp := _drawn_group(w, rng)
		var res := radio_lines(w, hooks, [["face", 5, 0x3A, null, true],
				["say", 0xA2, 0x3A, [["sign", g(w, grp, 1)]], false],
				["face", 0x12, 0x1B, 0, true], ["say", 0xA3, 0x1B, [], true]])
		if res:
			return res
		var code := 0x80 if w.ds8(0x50AD78) & 0x3E < 0x14 else 0x83
		m04_fates(w, rng, code)
		return code
	var r := hooks.line(0x51A6C0)
	if r in [-3, -2, -1]:
		return line_code(r)
	m04_fates(w, rng, 0x82)
	return 0x82


static func m04_overrun(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	if g(w, 0, 5) + g(w, 2, 5) + g(w, 4, 5):
		var grp := _drawn_group(w, rng)
		var res := radio_lines(w, hooks, [["face", 5, 0x3A, null, true], ["say", 0xA4, 0x3A, [["sign", g(w, grp, 1)]], true]])
		if res:
			return res
		res = radio_lines(w, hooks, [["face", 0x12, 0x1B, 0, true], ["say", 0xA5, 0x1B, [], true]])
		if res:
			return res
		m04_fates(w, rng, 0x82)
		return 0
	return line_code(hooks.line(0x51A6D4))


static func m04_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var n_units := mini(w.units.size() / 55, 254)
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		var retreat := w.ds8(0x50AD70) & 1
		for k in n_units:
			if not (on_map_unit(w, k) and w.sb(k, 0x36) >= 3 and w.ub(k, 0) & 8):
				continue
			var x := w.sb(k, 9)
			var y := w.sb(k, 10)
			if not retreat and x > 1 and y > 0x45:
				var grp := group_of_member(w, k)
				if grp != -1:
					Action.group_drop(w, grp, k)
				count5(w, 0x50AD78, 0x28)
			elif retreat and x > 0x23 and y < 3:
				var grp := group_of_member(w, k)
				if grp != -1:
					Action.group_drop(w, grp, k)
		if w.ds8(0x50AD70) & 1 and w.ds8(0x50AD70) & 0x3E >= 6:
			for k in n_units:
				if on_map_unit(w, k) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4:
					w.set_ds8(0x50ADF2, m04_escaped(w, rng, hooks) & 0xFF)
					break
		var res := flight_turn(w, rng, hooks)
		if res in AI_ABORT:
			return res
		var n := w.ds8(0x50AD78) >> 1 & 0x1F
		res = hooks.message(0xA1, [n, 0x15 - n])
		if res in AI_ABORT:
			return res
	elif stage == 1:
		if not w.ds8(0x50AD6E) & 1:
			var fit := 0
			for k in n_units:
				if w.sb(k, 0x36) > 2 and w.ub(k, 0xD):
					fit += 1
			if fit < 0x78:
				w.set_ds8(0x50ADF1, 1)
				ds_or(w, 0x50AD6E, 1)
				for k in n_units:
					if w.sb(k, 0x36) > 2:
						w.setb(k, 7, 0)
		if not w.ds8(0x50AD70) & 1:
			var left := 0
			for k in n_units:
				var f := w.ub(k, 0)
				if w.sb(k, 0x36) > 2 and ((on_map_unit(w, k) and f & 8) or not f & 9):
					left += 1
			if left < 0x32:
				ds_or(w, 0x50AD70, 1)
				fill_support_list(w)
				for k in n_units:
					if w.sb(k, 0x36) > 2 and on_map_unit(w, k):
						w.setb(k, 7, 0)
						w.setb(k, 3, w.ub(k, 3) & 0xF | 0x50)
				for grp in range(20, 64):
					if g(w, grp, 5) and g(w, grp, 2) & 0x30 != 0x30:
						set_g(w, grp, 2, g(w, grp, 2) | 0x30)
						var p := rng.roll(3) & 0xFFFF
						Ai.group_retarget(w, grp, w.ds8(0x50ADA5 + 4 * p), w.ds8(0x50ADA7 + 4 * p))
		else:
			count5(w, 0x50AD70, 8)
		var any_on := false
		for k in n_units:
			if on_map_unit(w, k) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4:
				any_on = true
				break
		if not any_on:
			w.set_ds8(0x50ADF2, 0x82)
			m04_fates(w, rng, 0x82)
		elif w.ds8(0x50AD78) & 0x3E > 0x28:
			w.set_ds8(0x50ADF2, 0x82)
			var res := m04_overrun(w, rng, hooks)
			if res in AI_ABORT:
				return res
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var res := hooks.speech_window()
		if res in AI_ABORT:
			return res
		ds_or(w, 0x50AD4E, 1)
	return 0


static func m04_scenario(w: Pd2World, rng: Pd2Random) -> void:
	w.set_ds8(0x50ADF2, 0x82)
	m04_fates(w, rng, 0x82)


# --- mission 5 (script 5, PD2 chunk 4: clear rows 15-51; rules.m05_*) ---------------------

static func m05_init(w: Pd2World) -> int:
	for p in [[0x50AD99, 9], [0x50AD95, 7], [0x50AD97, 7], [0x50AD9D, 10], [0x50AD9B, 0],
			[0x50AD9F, 0], [0x50ADA1, 11], [0x50ADA3, 0], [0x50ADA5, 0], [0x50ADA7, 1],
			[0x50ADA9, 0], [0x50ADAB, 3], [0x50ADAD, 0], [0x50ADAF, 5]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51A738 + i)
		w.ds[0xD1 + i] = w.mem8(0x5241F8 + i)
	set_506651(w, 0x73)
	return 0


static func _m05_live(w: Pd2World, k: int) -> bool:
	var f := w.ub(k, 0)
	return f & 4 != 0 and w.ub(k, 0xD) != 0 and not f & 1


static func m05_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	var found := false
	for k in mini(w.units.size() / 55, 254):
		if w.sb(k, 0x36) >= 3 and _m05_live(w, k) and w.sb(k, 10) >= 0xF and w.sb(k, 10) <= 0x33:
			found = true
			break
	var res := hooks.line(0x127 if found else 0x126)
	return res if res in AI_ABORT else 0


static func m05_fates(w: Pd2World, rng: Pd2Random) -> void:
	for k in mini(w.units.size() / 55, 254):
		var f := w.ub(k, 0)
		if w.sb(k, 0x36) < 3 and f & 4 and f & 1 and (rng.roll(100) & 0xFFFF) & 1 == 1:
			mark_crew(w, w.ub(k, 0xB), 2)


static func m05_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		var res := flight_turn(w, rng, hooks)
		if res in AI_ABORT:
			return res
	elif stage == 1:
		var players := 0
		var enemies := 0
		var zone := 0
		for k in mini(w.units.size() / 55, 254):
			if not (_m05_live(w, k) and w.ub(k, 9) != 0xFF):
				continue
			if w.sb(k, 0x36) < 3:
				players += 1
			else:
				enemies += 1
				if w.sb(k, 10) > 0xE and w.sb(k, 10) < 0x34:
					zone += 1
		var code := 0
		if zone == 0:
			code = 0x80
		elif enemies == 0:
			code = 0x83
		elif players == 0:
			code = 0x82
		if code:
			m05_fates(w, rng)
			w.set_ds8(0x50ADF2, code)
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var res := hooks.speech_window()
		if res in AI_ABORT:
			return res
		ds_or(w, 0x50AD4E, 1)
	return 0


static func m05_scenario(w: Pd2World, rng: Pd2Random) -> void:
	var zone := 0
	var left := 0
	for k in mini(w.units.size() / 55, 254):
		var f := w.ub(k, 0)
		if w.sb(k, 0x36) > 2 and not f & 1 and f & 4:
			if w.sb(k, 10) > 0xE and w.sb(k, 10) < 0x34:
				zone += 1
			if w.ub(k, 0xD):
				left += 1
	m05_fates(w, rng)
	w.set_ds8(0x50ADF2, 0x80 if left == 0 else (0x82 if zone else 0x83))


static func hex_step(x: int, y: int, d: int) -> Vector2i:
	if d >= 0 and d < 6:
		var o: Vector2i = Ai.NB[y & 1][d]
		return Vector2i(x + o.x, y + o.y)
	return Vector2i(x, y)


static func set_target_mark(w: Pd2World, x: int, y: int) -> void:
	if w.on_map(x, y):
		w.F[x + MAP * y] |= 2


static func target_mark_at(w: Pd2World, x: int, y: int) -> int:
	var i := x + MAP * y
	if i < 0 or i >= MAP * MAP:
		w.fault = "target_mark_at outside the layer"
		return 0
	return w.F[i] >> 1 & 1


## 0x47D2A0: every hex of the map loses F bit 1
static func clear_target_marks(w: Pd2World) -> void:
	for y in MAP:
		for x in MAP:
			if w.F[x + MAP * y] & 2 and w.on_map(x, y):
				w.F[x + MAP * y] &= 0xFD


static func nibble_inc(w: Pd2World, addr: int) -> void:
	var v := w.ds8(addr)
	w.set_ds8(addr, v ^ ((v + 1) ^ v) & 0xF)


# --- mission 6 (script 6, PD2 chunk 5: inspect trailers 42-49; rules.m06_*) ---------------

static func m06_init(w: Pd2World) -> int:
	for p in [[0x50AD95, 6], [0x50AD97, 6], [0x50AD99, 4], [0x50AD9B, 0], [0x50AD9D, 5],
			[0x50AD9F, 0], [0x50ADA1, 6], [0x50ADA3, 0], [0x50ADA5, 14], [0x50ADA7, 5],
			[0x50ADA9, 14], [0x50ADAB, 6], [0x50ADAD, 14], [0x50ADAF, 7]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51A780 + i)
		w.ds[0xD1 + i] = w.mem8(0x524220 + i)
	set_506651(w, 0xA9)
	return 0


static func m06_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	if w.sb(u, 0xE) < 0x14:
		var r0 := hooks.line(0xA1)
		return r0 if r0 in AI_ABORT else 0
	var x0 := w.sb(u, 9)
	var y0 := w.sb(u, 10)
	var n := 0
	for d in 6:
		var h := hex_step(x0, y0, d)
		var o := occupant_raw(w, h.x, h.y)
		if w.fault != "":
			return 0
		if o > 0x29 and o < 0x32:
			set_target_mark(w, h.x, h.y)
			n += 1
	if not n:
		var r1 := hooks.line(0xA5)
		return r1 if r1 in AI_ABORT else 0
	var res := hooks.scroll(x0, y0)
	if res in AI_ABORT:
		return res
	while true:
		var c: Variant = hooks.click(2)
		if c is int:
			if int(c) in AI_ABORT:
				return int(c)
			clear_target_marks(w)
			return 0
		var p: Vector2i = c
		if not target_mark_at(w, p.x, p.y):
			if w.fault != "":
				return 0
			continue
		var o := occupant_raw(w, p.x, p.y)
		var base := UNITS_ADDR + 55 * o
		if w.mem8(base) & 2:
			res = hooks.message(0xA2)
			if res in AI_ABORT:
				return res
			clear_target_marks(w)
			return 0
		res = hooks.dialog(0xA3, [], 2)
		if res in AI_ABORT:
			return res
		if res != 0:
			continue
		w.mem_write(base, w.mem8(base) | 2)
		res = hooks.message(0xA4)
		if res in AI_ABORT:
			return res
		w.setb(u, 0xE, (w.ub(u, 0xE) - 0x14) & 0xFF)
		nibble_inc(w, 0x50AD6F)
		clear_target_marks(w)
		return 0
	return 0


static func m06_fates(w: Pd2World, rng: Pd2Random, withdraw: bool) -> void:
	for k in mini(w.units.size() / 55, 254):
		if not (w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4):
			continue
		if withdraw and not w.ub(k, 0) & 1 and w.ub(k, 9) != 0xFF and (rng.roll(100) & 0xFFFF) & 3 != 2:
			w.setb(k, 0, w.ub(k, 0) | 1)
			w.setb(k, 0xD, 0)
		if w.ub(k, 0) & 1 and (rng.roll(100) & 0xFFFF) & 3 != 2:
			mark_crew(w, w.ub(k, 0xB), 2)


static func m06_end(w: Pd2World, rng: Pd2Random, withdraw: bool) -> int:
	m06_fates(w, rng, withdraw)
	var v := w.ds8(0x50AD71) & 0xF
	return 0x80 if v == 2 else (0x83 if v == 1 else 0x82)


static func _m06_result(w: Pd2World) -> void:
	var n := w.ds8(0x50AD6F) & 0xF
	if n == 8:
		w.set_ds8(0x50AD71, w.ds8(0x50AD71) & 0xF2 | 2)
	elif n > 3:
		w.set_ds8(0x50AD71, w.ds8(0x50AD71) & 0xF1 | 1)


static func m06_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var n_units := mini(w.units.size() / 55, 254)
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		for k in range(0x2A, 0x32):
			var x := w.sb(k, 9)
			if x == 1 or x > 0x44:
				Action.take_off_map(w, k)
		var res := flight_turn(w, rng, hooks)
		if res in AI_ABORT:
			return res
		res = hooks.line(0xA7, [w.ds8(0x50AD6F) & 0xF])
		if res in AI_ABORT:
			return res
	elif stage == 1:
		for k in n_units:
			if w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4 and w.sb(k, 9) > 0x44:
				var res := hooks.scroll(w.sb(k, 9), w.sb(k, 10))
				if res in AI_ABORT:
					return res
				res = hooks.dialog(0xA6, [w.ucrew(k, 0)], 2)
				if res in AI_ABORT:
					return res
				if res == 0:
					Action.take_off_map(w, k)
					_m06_result(w)
		var players := 0
		var enemies := 0
		for k in n_units:
			var f := w.ub(k, 0)
			if f & 4 and w.ub(k, 0xD) and not f & 1 and w.ub(k, 9) != 0xFF:
				if w.sb(k, 0x36) < 3:
					players += 1
				else:
					enemies += 1
		if not players or not enemies:
			if not enemies:
				_m06_result(w)
			w.set_ds8(0x50ADF2, m06_end(w, rng, false))
		if not w.ds8(0x50AD76) & 1 and w.ds8(0x50AD6F) & 0xF:
			w.set_ds8(0x50ADF1, 1)
			ds_or(w, 0x50AD76, 1)
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var res := hooks.speech_window()
		if res in AI_ABORT:
			return res
		ds_or(w, 0x50AD4E, 1)
	return 0


## 0x489430: the radio portrait of member k by its crew's name id (rules.face_of)
static func face_of(w: Pd2World, rng: Pd2Random, k: int) -> int:
	if k == -1:
		return 0
	var v := Pd2World.s8(w.mem8(0x506734 + 16 * k))
	if v == 0 or (v > 1 and v < 0x10):
		return 0xD
	if v == 1:
		return 10
	if v == 0x10:
		return rng.r16(2) + 0xB
	if v > 0x10 and v < 0x16:
		return rng.r16(2) + 0xE
	if v >= 0x16 and v < 0x1D:
		return v - 0x16
	if v in [0x1D, 0x20, 0x22]:
		return 5
	if v in [0x1E, 0x24]:
		return 0x10
	if v in [0x1F, 0x21, 0x23]:
		return 6
	return 0


## a radio scene, every step checked (rules.radio_scene): ["face", a or Callable, code,
## slot], ["say", msg, code(, args or Callable)], ["close"(, n)], ["wait"] (0x453CD0)
static func radio_scene(w: Pd2World, hooks: Hooks, steps: Array) -> int:
	for st in steps:
		if st[0] == "close":
			hooks.flight.radio_close(st[1] if st.size() > 1 else -1)
			continue
		if st[0] == "wait":
			var r := hooks.wait()
			if r == 1 or r == 2:
				hooks.flight.radio_close(-1)
				return 0x40000 if r == 1 else 0x20000
			continue
		var res: int
		if st[0] == "face":
			var a: Variant = st[1].call() if st[1] is Callable else st[1]
			if w.fault != "":
				return 0
			res = Flight._radio_face(w, hooks.flight, a, st[2], st[3])
		else:
			var args: Variant = st[3] if st.size() > 3 else []
			res = hooks.flight.radio_say(st[1], args.call() if args is Callable else args, st[2])
		if res in AI_ABORT:
			hooks.flight.radio_close(-1)
			return res
	return 0


# --- mission 7 (script 7, PD2 chunk 6: the search and the escape by air; rules.m07_*) -----

const M07_SITES := [[0x51A898, 3, 0x50AD50], [0x51A8B8, 6, 0x50AD52], [0x51A8F8, 3, 0x50AD54], [0x51A918, 3, 0x50AD56],
		[0x51A938, 6, 0x50AD58], [0x51A978, 3, 0x50AD5A], [0x51A998, 20, 0x50AD5C], [0x51AA68, 20, 0x50AD5E]]

const M07_LOAD := [[0x51A828, 0x51A850, 40], [0x51A87C, 0x51A88C, 4], [0x51A89C, 0x51A8AC, 4], [0x51A8A6, 0x51A8B6, 1],
		[0x51A8B8, 0x51A8D8, 28], [0x51A878, 0x51A888, 4], [0x51A900, 0x51A910, 4], [0x51A918, 0x51A928, 4],
		[0x51A8D4, 0x51A8F4, 2], [0x51A924, 0x51A934, 2], [0x51A880, 0x51A890, 2], [0x51A898, 0x51A8A8, 4],
		[0x51A8A0, 0x51A8B0, 4], [0x51A938, 0x51A958, 28], [0x51A8A4, 0x51A8B4, 2], [0x51A97C, 0x51A98C, 4],
		[0x51A8F8, 0x51A908, 4], [0x51A8FC, 0x51A90C, 4], [0x51A954, 0x51A974, 2], [0x51A986, 0x51A996, 1],
		[0x51A904, 0x51A914, 2], [0x51A906, 0x51A916, 1], [0x51A998, 0x51AA00, 100], [0x51A91C, 0x51A92C, 4],
		[0x51A920, 0x51A930, 4], [0x51A926, 0x51A936, 1], [0x51A978, 0x51A988, 4], [0x51A980, 0x51A990, 4],
		[0x51AA68, 0x51AAD0, 100], [0x51A984, 0x51A994, 2]]

const M07_ALERT_TIMES := [7, 0xE, 0x15, 0x1C]


static func m07_load(w: Pd2World) -> void:
	for c in M07_LOAD:
		static_copy(w, c[0], c[1], c[2])


static func m07_init(w: Pd2World) -> int:
	for p in [[0x50AD99, 14], [0x50AD9D, 14], [0x50ADA1, 14], [0x50AD95, 7], [0x50AD97, 7],
			[0x50AD9B, 6], [0x50AD9F, 7], [0x50ADA3, 8], [0x50ADA5, 0], [0x50ADA7, 0],
			[0x50ADA9, 0], [0x50ADAB, 0], [0x50ADAD, 0], [0x50ADAF, 0]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51A7C8 + i)
		w.ds[0xD1 + i] = w.mem8(0x51A7E8 + i)
	set_506651(w, 0x3B)
	return 0


static func m07_objective(w: Pd2World) -> int:
	var t0 := g(w, 0, 0x21) & 0xF
	return -1 if t0 == g(w, 2, 0x21) & 0xF and t0 == g(w, 4, 0x21) & 0xF else 0x10A


static func m07_deploy(w: Pd2World, hooks: Hooks) -> int:
	var t2: int = g(w, 2, 0x21) if g(w, 2, 5) else g(w, 4, 0x21)
	var bad: bool = g(w, 0, 5) != 0 and (g(w, 2, 5) != 0 or g(w, 4, 5) != 0) and (g(w, 0, 0x21) ^ t2) & 0xF != 0
	if g(w, 2, 5) and g(w, 4, 5) and (g(w, 2, 0x21) ^ g(w, 4, 0x21)) & 0xF:
		bad = true
	if bad:
		return DEPLOY_RESULT.get(hooks.end_dialog(0x12B), 0)
	if g(w, 12, 5):
		return 1
	return DEPLOY_RESULT.get(hooks.end_dialog(0x12C), 0)


static func _m07_flag(w: Pd2World, j: int) -> int:
	return 0x50AD4E + 2 * w.mem8(0x51A878 + j)


static func m07_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	var f := w.ds8(0x50AD6E)
	if not f & 1:
		if w.sb(u, 0xE) < 0xF:
			var r0 := hooks.message(0xA5)
			return r0 if r0 in AI_ABORT else 0
		var res := hooks.dialog(0xA6, [], 2)
		if res in AI_ABORT:
			return res
		if res != 0:
			return 0
		w.setb(u, 0xE, (w.ub(u, 0xE) - 0xF) & 0xFF)
		var x := w.sb(u, 9)
		var y := w.sb(u, 10)
		var i := -1
		for j in 10:
			if static_s16(w, 0x51A828 + 4 * j) == x and static_s16(w, 0x51A82A + 4 * j) == y:
				i = j
				break
		if i == -1:
			res = hooks.line(0xA3)
			return res if res in AI_ABORT else 0
		var a := _m07_flag(w, i)
		if w.mem8(a) & 1:
			res = hooks.line(0xA4)
			return res if res in AI_ABORT else 0
		w.mem_write(a, w.mem8(a) | 1)
		var first := 0x40 if i < 5 else 0x80
		var other := 0x80 if i < 5 else 0x40
		var base := 0 if i < 5 else 5
		if not w.ds8(0x50AD6E) & other:
			ds_or(w, 0x50AD6E, first)
		var n := 0
		for j in 5:
			if w.mem8(_m07_flag(w, base + j)) & 1:
				n += 1
		if w.ds8(0x50AD6E) & other and n == 5:
			res = hooks.line(0xA1)
			if res in AI_ABORT:
				return res
			w.set_ds8(0x50AD6E, (w.ub(u, 0xB) & 0x1F) << 1 | (w.ds8(0x50AD6E) & 0xC1) | 1)
			return 0
		res = hooks.line(0xA2)
		return res if res in AI_ABORT else 0
	if w.ub(u, 0x34) != 0xFF:
		return line_code(hooks.line(0xB4))
	var gf := g(w, 12, 2)
	if not (gf & 0x30 == 0x20 and gf & 0xC0 == 0x80):
		var r1 := hooks.message(0xA7)
		return r1 if r1 in AI_ABORT else 0
	var x2 := w.sb(u, 9)
	var y2 := w.sb(u, 10)
	var found := -1
	for h in Ai.spiral(x2, y2, 2):
		var o := occupant_raw(w, h.x, h.y)
		if w.fault != "":
			return 0
		if o != -1 and w.sb(o, 0xC) == 0xC:
			found = o
			break
	if found == -1:
		var r2 := hooks.message(0xA8)
		return r2 if r2 in AI_ABORT else 0
	var r3 := hooks.box(0xA9, [], 0)
	if r3 in AI_ABORT:
		return r3
	if r3 == 0:
		return 0
	r3 = hooks.blast_open()
	if r3 in AI_ABORT:
		return r3
	r3 = hooks.blast_start(x2, y2)
	if r3 in AI_ABORT:
		return r3
	var bl := blast(w, hooks, x2, y2, false)
	if bl[0]:
		return bl[0]
	Action.take_off_map(w, u)
	r3 = hooks.blast_close()
	if r3 in [0x10000, 0x20000]:
		return r3
	w.setb(u, 0x34, found & 0xFF)
	w.setb(u, 0x33, found & 0xFF)
	if w.ds8(0x50AD6E) >> 1 & 0x1F == w.ub(u, 0xB):
		w.set_ds8(0x50AD6F, w.ds8(0x50AD6F) & 0xF1 | 1)
	return -1


static func m07_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	var sites := [[[0x1E, 0x1F], 0x31], [[0x1E, 0x1F], 0x2F], [[0x1E, 0x1F], 0x2D],
			[[0x32, 0x33], 0x31], [[0x32, 0x33], 0x2F], [[0x32, 0x33], 0x2D]]
	for v in sites.size():
		if x in sites[v][0] and y == sites[v][1]:
			return v + 1
	if x > 0x32 and x < 0x37 and y == 0x10:
		return 7
	if x >= 0xE and x <= 0x11 and y == 0x27:
		return 8
	return -1


static func _m07_height(x: int, y: int) -> int:
	var p := Vector2i(x, y)
	if p in [Vector2i(0x33, 0x10), Vector2i(0x34, 0x10), Vector2i(0x35, 0x11), Vector2i(0xE, 0x27), Vector2i(0xF, 0x27), Vector2i(0x10, 0x27)]:
		return 0x1C
	return 0x1E


static func m07_bomb(w: Pd2World, rng: Pd2Random, i: int, hooks: Hooks) -> int:
	var v := w.mem8(0x50AC1F + 4 * i)
	if v < 1 or v > 8:
		if i > 0:
			w.fault = "m07 bomb hook: an entry without a site reads low memory"
		return 0
	var t: Array = M07_SITES[v - 1]
	ds_or(w, t[2], 1)
	for j in int(t[1]):
		var a: int = t[0] + 5 * j
		var x := static_s16(w, a)
		var y := static_s16(w, a + 2)
		set_height_tile(w, x, y, w.mem8(a + 4), _m07_height(x, y))
		var o := occupant_raw(w, x, y)
		if o >= 0 and ((y == 0x10 and x > 0x32 and x < 0x37) or (y == 0x27 and x > 0xD and x < 0x12)):
			w.mem_write(UNITS_ADDR + 55 * o + 1, w.mem8(UNITS_ADDR + 55 * o + 1) & 0xEB | 0x28)
	return 0


static func m07_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	for s in M07_SITES.size():
		var t: Array = M07_SITES[s]
		if w.ds8(t[2]) & 1:
			for j in int(t[1]):
				var a: int = t[0] + 5 * j
				var x := static_s16(w, a)
				var y := static_s16(w, a + 2)
				set_height_tile(w, x, y, w.mem8(a + 4), 0x1E if s == 0 else _m07_height(x, y))
	return 0


static func m07_fates(w: Pd2World, rng: Pd2Random) -> void:
	var n := mini(w.units.size() / 55, 254)
	for u in n:
		if not (w.sb(u, 0x36) < 3 and w.ub(u, 0) & 4 and w.ub(u, 0xC) == 0xC):
			continue
		var dead := w.ub(u, 0) & 1
		if dead and (rng.roll(100) & 0xFFFF) & 3 != 2:
			mark_crew(w, w.ub(u, 0xB), 1)
		for k in n:
			if w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4 and w.ub(k, 0x33) == u and w.ub(k, 0x34) == u:
				w.setb(k, 0, w.ub(k, 0) | 1)
				w.setb(k, 0xD, 0)
				if dead and (rng.roll(100) & 0xFFFF) & 3 != 2:
					mark_crew(w, w.ub(k, 0xB), 1)
					w.setb(k, 0x33, 0xFF)
					w.setb(k, 0x34, 0xFF)
	for u in n:
		if not (w.sb(u, 0x36) < 3 and w.ub(u, 0) & 4 and w.ub(u, 0xC) != 0xC):
			continue
		if not w.ub(u, 0) & 1:
			if w.ub(u, 9) != 0xFF and (rng.roll(100) & 0xFFFF) & 3 != 2:
				mark_crew(w, w.ub(u, 0xB), 1)
				if (rng.roll(100) & 0xFFFF) & 1 == 1:
					w.setb(u, 0, w.ub(u, 0) | 2)
				else:
					w.setb(u, 0, w.ub(u, 0) | 1)
					w.setb(u, 0xD, 0)
		elif (w.ub(u, 0x33) != w.ub(u, 0x34) or w.ub(u, 0x34) == 0xFF) and (rng.roll(100) & 0xFFFF) & 3 != 2:
			mark_crew(w, w.ub(u, 0xB), 1)


static func m07_end_code(w: Pd2World, rng: Pd2Random) -> int:
	var f := w.ds8(0x50AD6E)
	if not f & 1:
		m07_fates(w, rng)
		return 0x82
	var k := f >> 1 & 0x1F
	var ok: bool = not w.ub(k, 0) & 1 and (w.mission_turn & 0xFFFF) < 0x14 and w.ub(k, 0x33) == w.ub(k, 0x34) and w.ub(k, 0x34) != 0xFF
	m07_fates(w, rng)
	return 0x80 if ok else 0x83


## caller: the two stack bytes above the call's argument (groups 29 / 30 +0x1C), or []
static func m07_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks, caller := []) -> int:
	var slot := stage
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		var res := flight_turn(w, rng, hooks)
		if res in AI_ABORT:
			return res
	elif stage == 1:
		if not w.ds8(0x50AD80) & 1:
			slot = 0x1C150E07
			var spotted := 0
			var enemy_hurt := 0
			var hurt := 0
			var dead := 0
			var k := 0
			var cnt := 0
			while cnt < 0xFE:
				var base := UNITS_ADDR + 55 * k
				var fl := w.mem8(base)
				if fl & 4:
					var st := w.mem8(base + 0x36)
					var c := w.mem8(base + 0xD)
					if st == 0:
						if fl & 0x10:
							spotted += 1
						if c < 100:
							hurt += 1
						if fl & 1:
							dead += 1
					elif Pd2World.s8(st) >= 3 and c < 100 and w.mem8(base + 0xC) != 0xFF and not fl & 1:
						enemy_hurt += 1
					if w.ds8(0x50AD4E) & 0x40 or spotted or enemy_hurt or hurt or dead:
						w.set_ds8(0x50ADF1, 1)
						ds_or(w, 0x50AD80, 1)
						var times := M07_ALERT_TIMES + (caller if caller.size() == 2 else [null, null])
						for j in 6:
							var grp := 25 + j
							Ai.group_retarget(w, grp, w.ds8(0x50AD95), w.ds8(0x50AD97))
							set_g(w, grp, 2, g(w, grp, 2) & 0xDF | 0x10)
							if times[j] != null:
								set_g(w, grp, 0x1C, int(times[j]))
						cnt = 0x1F
				k += 1
				cnt += 1
		var gf := g(w, 12, 2)
		if not w.ds8(0x50AD82) & 1 and gf & 0x30 == 0x20 and gf & 0xC0 == 0x80:
			var c20 := g(w, 12, 0x20)
			if c20 == 1 or c20 == 2:
				if c20 == 2:
					for i in 16:
						var m := g(w, 12, 6 + i)
						if m != 0xFF:
							var r0 := hooks.scroll(Pd2World.s8(table_byte(w, 55 * m + 9)), Pd2World.s8(table_byte(w, 55 * m + 10)))
							if r0 in AI_ABORT:
								return r0
							break
				var res := hooks.dialog(0xB2 if c20 == 2 else 0xB3, [["sign", g(w, 12, 1)]], 2)
				if res in AI_ABORT:
					return res
				if res == 0:
					set_g(w, 12, 0x20, 0)
					set_g(w, 12, 2, g(w, 12, 2) & 0x2F | 0x60)
					ds_or(w, 0x50AD82, 1)
				elif c20 == 1:
					set_g(w, 12, 0x20, 2)
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var rr: Variant = hooks.radar_open()
		var res: int = int(rr) if rr != null else Flight.grid_init(w, hooks.flight, 0)
		if res in AI_ABORT:
			return res
		var sel := slot
		var least := slot
		for grp in [0, 2, 4]:
			if g(w, grp, 5):
				sel = g(w, grp, 0x21) & 0xF
				least = 0xFF
				for i in 16:
					least = mini(least, g(w, grp, 6 + i))
				break
		var portrait := func() -> int:
			if least > 0xFF:
				w.fault = "m07 opening with no group 0 / 2 / 4"
				return 0
			return face_of(w, rng, least)
		if sel == 0:
			res = radio_scene(w, hooks, [["face", portrait, 10, null], ["say", 0xAA, 10], ["close"]])
			if res:
				return res
			for grp in [0, 2, 4]:
				for i in 16:
					var m := g(w, grp, 6 + i)
					if m != 0xFF:
						w.mem_write(UNITS_ADDR + 55 * m + 9, 4)
						w.mem_write(UNITS_ADDR + 55 * m + 0xA, 4)
		else:
			res = radio_scene(w, hooks, [
				["face", 2, 0x3A, null], ["say", 0xAB, 0x3A], ["face", 9, 0xB, null], ["say", 0xAC, 0xB], ["close"],
				["face", 8, 10, null], ["say", 0xAD, 10], ["face", portrait, 0x1B, 0],
				["face", 0xC, 0x1B, 1], ["say", 0xAE, 0x1B], ["say", 0xAF, 10], ["face", 9, 0x1B, 0],
				["say", 0xB0, 0x1B], ["face", 0xD, 0x1B, 1], ["wait"], ["close"],
				["face", 4, 0x3A, null], ["say", 0xB1, 0x3A], ["close"]])
			if res:
				return res
			ds_or(w, 0x50AD4E, 0x40)
		var px := w.ds8(0x50AD95)
		var py := w.ds8(0x50AD97)
		for grp in [0, 2, 4]:
			set_g(w, grp, 2, g(w, grp, 2) & 0xF | 0x20)
			for f in [G_TARGET_X, G_PREV_X, G_X]:
				set_g(w, grp, f, px)
				set_g(w, grp, f + 1, py)
		ds_or(w, 0x50AD4E, 1)
	var on := false
	for k in mini(w.units.size() / 55, 254):
		if w.ub(k, 0xD) and w.sb(k, 0x36) <= 2 and w.ub(k, 0) & 4 and w.ub(k, 9) != 0xFF:
			on = true
			break
	if not on or w.ds8(0x50AD82) & 1 or not g(w, 12, 5):
		w.set_ds8(0x50ADF2, m07_end_code(w, rng) & 0xFF)
	return 0


static func break_site(w: Pd2World, table: int, n: int, h: int) -> void:
	for j in n:
		var a := table + 5 * j
		set_height_tile(w, static_s16(w, a), static_s16(w, a + 2), w.mem8(a + 4), h)


static func hit_table(w: Pd2World, x: int, y: int, table: int, n: int) -> bool:
	for j in n:
		if static_s16(w, table + 4 * j) == x and static_s16(w, table + 4 * j + 2) == y:
			return true
	return false


static func alive_on_map(w: Pd2World, k: int) -> bool:
	var f := w.ub(k, 0)
	return f & 4 != 0 and w.ub(k, 0xD) != 0 and not f & 1 and w.ub(k, 9) != 0xFF


# --- mission 9 (script 9, PD2 chunk 8: the test shafts, two bridges; rules.m09_*) ---------

static func m09_load(w: Pd2World) -> void:
	for c in [[0x51AFD0, 0x51AFE0, 16], [0x51AFF0, 0x51B000, 16], [0x51B010, 0x51B020, 16],
			[0x51B030, 0x51B060, 45], [0x51B090, 0x51B0C0, 45]]:
		static_copy(w, c[0], c[1], c[2])


static func m09_init(w: Pd2World) -> int:
	for p in [[0x50AD95, 7], [0x50AD97, 7], [0x50AD99, 4], [0x50AD9B, 0], [0x50AD9D, 5],
			[0x50AD9F, 0], [0x50ADA1, 6], [0x50ADA3, 0], [0x50ADA5, 14], [0x50ADA7, 5],
			[0x50ADA9, 14], [0x50ADAB, 6], [0x50ADAD, 14], [0x50ADAF, 7]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51AF98 + i)
		w.ds[0xD1 + i] = w.mem8(0x524248 + i)
	set_506651(w, 0x7C)
	return 0


static func m09_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	if w.sb(u, 0xE) < 0x19:
		var r0 := hooks.line(0xA1)
		return r0 if r0 in AI_ABORT else 0
	var p := Vector2i(w.sb(u, 9), w.sb(u, 10))
	if p in [Vector2i(0x26, 0x19), Vector2i(0x21, 0x19), Vector2i(0x1C, 0x1E), Vector2i(0x1C, 0x26)]:
		var res := hooks.dialog(0xA2, [], 2)
		if res in AI_ABORT:
			return res
		if res == 0:
			res = hooks.message(0xA3)
			if res in AI_ABORT:
				return res
			w.setb(u, 0xE, (w.ub(u, 0xE) - 0x19) & 0xFF)
		return 0
	var i := -1
	for j in 4:
		if static_s16(w, 0x51AFD0 + 4 * j) == p.x and static_s16(w, 0x51AFD2 + 4 * j) == p.y:
			i = j
			break
	if i == -1:
		var r1 := hooks.line(0xA5)
		return r1 if r1 in AI_ABORT else 0
	var r2 := hooks.dialog(0xA2, [], 2)
	if r2 in AI_ABORT:
		return r2
	if r2 != 0:
		return 0
	w.setb(u, 0xE, (w.ub(u, 0xE) - 0x19) & 0xFF)
	ds_or(w, 0x50AD70 + 2 * i, 1)
	var all_done := true
	for j in 4:
		if not w.ds8(0x50AD70 + 2 * j) & 1:
			all_done = false
	if all_done:
		r2 = hooks.message(0xA4)
		if r2 in AI_ABORT:
			return r2
		ds_or(w, 0x50AD6E, 1)
		return 0
	r2 = hooks.message(0xA3)
	return r2 if r2 in AI_ABORT else 0


static func m09_fates(w: Pd2World, rng: Pd2Random, withdraw: bool) -> void:
	for k in mini(w.units.size() / 55, 254):
		if not (w.ub(k, 0) & 4 and w.sb(k, 0x36) < 3):
			continue
		if withdraw and w.ub(k, 0xD) and not w.ub(k, 0) & 1 and w.ub(k, 9) != 0xFF and (rng.roll(100) & 0xFFFF) & 3 == 2:
			w.setb(k, 0, w.ub(k, 0) | 1)
			w.setb(k, 0xD, 0)
		if w.ub(k, 0) & 1 and (rng.roll(100) & 0xFFFF) & 3 == 2:
			mark_crew(w, w.ub(k, 0xB), 2)


static func m09_end(w: Pd2World, rng: Pd2Random, withdraw: bool) -> int:
	m09_fates(w, rng, withdraw)
	if not w.ds8(0x50AD6E) & 1:
		return 0x82 | (w.ds8(0x50AD78) & 1)
	return 0x80 if w.ds8(0x50AD78) & 1 else 0x83


static func m09_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		var res := flight_turn(w, rng, hooks)
		if res in AI_ABORT:
			return res
	elif stage == 1:
		var players := 0
		var enemies := 0
		for k in mini(w.units.size() / 55, 254):
			if alive_on_map(w, k):
				if w.sb(k, 0x36) < 3:
					players += 1
				else:
					enemies += 1
		if not players or not enemies:
			if not enemies:
				ds_or(w, 0x50AD78, 1)
			w.set_ds8(0x50ADF2, m09_end(w, rng, false))
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var res := hooks.speech_window()
		if res in AI_ABORT:
			return res
		ds_or(w, 0x50AD4E, 1)
	return 0


static func m09_scenario(w: Pd2World, rng: Pd2Random) -> void:
	var any_enemy := false
	for k in mini(w.units.size() / 55, 254):
		if w.sb(k, 0x36) > 2 and alive_on_map(w, k):
			any_enemy = true
			break
	if not any_enemy:
		ds_or(w, 0x50AD78, 1)
	w.set_ds8(0x50ADF2, m09_end(w, rng, true))


static func m09_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	if hit_table(w, x, y, 0x51AFF0, 4):
		return 1
	if hit_table(w, x, y, 0x51B010, 4):
		return 2
	return -1


static func m09_bomb(w: Pd2World, rng: Pd2Random, i: int, hooks: Hooks) -> int:
	var v := w.mem8(0x50AC1F + 4 * i)
	if v == 1 or v == 2:
		ds_or(w, 0x50AD50 if v == 1 else 0x50AD52, 1)
		break_site(w, 0x51B030 if v == 1 else 0x51B090, 9, 0x22)
	elif i > 0:
		w.fault = "m09 bomb hook: an entry without a site reads low memory"
	return 0


static func m09_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	if w.ds8(0x50AD50) & 1:
		break_site(w, 0x51B030, 9, 0x22)
	if w.ds8(0x50AD52) & 1:
		break_site(w, 0x51B090, 9, 0x22)
	return 0


# --- mission 8 (script 8, PD2 chunk 7: units 40-45, the pickup by submarine; rules.m08_*) --

const M08_ALARM_TIMES := [0x1E, 0xA5, 0x3C, 0x78, 0x4B, 0x87, 0x5A, 0x2D, 0x69, 0x96]
const M08_LATE := [5, 8, 0xB, 0xE]
const M08_ZONES := {1: [0, 0xC, 0x1C, 0x23], 2: [0x1A, 0x24, 0x37, 0x3E], 3: [0x3D, 0x46, 0x12, 0x1D]}
const M08_PIERS := {1: [0x51ADE8, 8], 2: [0x51AE38, 8], 3: [0x51AE88, 6]}
const M08_LANDING := {0: 0x51AC58, 1: 0x51ACB8, 2: 0x51AD18}


static func m08_load(w: Pd2World) -> void:
	for c in [[0x51AC58, 0x51AC88, 48], [0x51ACB8, 0x51ACE8, 48], [0x51AD18, 0x51AD48, 48],
			[0x51AD88, 0x51ADB8, 48], [0x51ADE8, 0x51AE10, 40], [0x51AE38, 0x51AE60, 40],
			[0x51AE88, 0x51AEA8, 30]]:
		static_copy(w, c[0], c[1], c[2])


static func m08_init(w: Pd2World) -> int:
	for p in [[0x50ADA7, 6], [0x50AD95, 7], [0x50AD97, 7], [0x50ADA9, 4], [0x50AD99, 0],
			[0x50AD9B, 0], [0x50AD9D, 0], [0x50AD9F, 0], [0x50ADA1, 0], [0x50ADA3, 0],
			[0x50ADA5, 0], [0x50ADAB, 0], [0x50ADAD, 0xB], [0x50ADAF, 0]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51ABF8 + i)
		w.ds[0xD1 + i] = w.mem8(0x51AC18 + i)
	set_506651(w, 0xD3)
	return 0


static func m08_cost(w: Pd2World, u: int) -> int:
	return 4 if w.mem8(0x50673C + 16 * w.sb(u, 0xB)) & 4 else 8


static func m08_menu(w: Pd2World, u: int) -> Array:
	if w.ds8(0x50AD6E) & 1:
		return [0, -1]
	w.mem_write(0x51AED2, 0x30 + m08_cost(w, u))
	return [1, 0x51AEC8]


## DS:0x50DD44, kept in the exe data image too (rules.set_radar_flag)
static func set_radar_flag(w: Pd2World, v: int) -> void:
	w.radar = v
	for base in w.static_mem:
		if 0x50DD44 >= base and 0x50DD44 < base + w.static_mem[base].size():
			w.mem_write(0x50DD44, v)
			return


static func m08_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	var cost := m08_cost(w, u)
	if w.sb(u, 0xE) < cost:
		var r0 := hooks.message(0xA1, [cost])
		return r0 if r0 in AI_ABORT else 0
	var res := hooks.dialog(0xA2, [cost], 2)
	if res in AI_ABORT:
		return res
	if res != 0:
		return 0
	ds_or(w, 0x50AD6E, 1)
	w.setb(u, 0xE, (w.ub(u, 0xE) - cost) & 0xFF)
	var crew_face := func() -> int: return face_of(w, rng, w.sb(u, 0xB))
	res = radio_scene(w, hooks, [["face", crew_face, 10, null], ["say", 0xA3, 10]])
	if res:
		return res
	res = hooks.dialog(0x51AEFC, [], 3)
	if res in AI_ABORT:
		hooks.flight.radio_close(-1)
		return res
	if res >= 0 and res <= 2:
		w.set_ds8(0x50AD6F, w.ds8(0x50AD6F) & [0xF1, 0xF2, 0xF3][res] | res + 1)
	res = radio_scene(w, hooks, [["close"], ["face", 0x10, 0xB, null], ["say", 0xC3, 0xB], ["close"]])
	if res:
		return res
	if w.radar:
		hooks.radar_close()
		set_radar_flag(w, 0)
		res = hooks.unit_panel()
		if res in AI_ABORT:
			return res
		res = hooks.map_redraw()
		if res in AI_ABORT:
			return res
		res = hooks.date_window()
		if res in AI_ABORT:
			return res
		set_radar_flag(w, 0)
	return 0


static func m08_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	var p: Variant = M08_PIERS.get(w.ds8(0x50AD6F) & 0xF)
	if p == null:
		return 0
	for j in p[1]:
		var a: int = p[0] + 5 * j
		var x := static_s16(w, a)
		var y := static_s16(w, a + 2)
		set_height_tile(w, x, y, w.mem8(a + 4), 0x1E)
		if not w.radar:
			var res := hooks.redraw_hex(x, y)
			if res == 0x10000 or res == 0x20000:
				return res
	return 0


static func m08_fates(w: Pd2World, rng: Pd2Random) -> void:
	for k in mini(w.units.size() / 55, 254):
		if not (w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4):
			continue
		if not w.ub(k, 0) & 1:
			if w.ub(k, 9) == 0xFF or (rng.roll(100) & 0xFFFF) & 3 == 2:
				continue
			mark_crew(w, w.ub(k, 0xB), 1)
			if (rng.roll(100) & 0xFFFF) % 2 == 1:
				w.setb(k, 0, w.ub(k, 0) | 2)
			else:
				w.setb(k, 0, w.ub(k, 0) | 1)
				w.setb(k, 0xD, 0)
		elif (rng.roll(100) & 0xFFFF) & 3 != 2:
			mark_crew(w, w.ub(k, 0xB), 1 if (rng.roll(100) & 0xFFFF) % 2 == 1 else 2)


static func m08_end_code(w: Pd2World, rng: Pd2Random) -> int:
	var n := 0
	for k in range(40, 46):
		if w.ub(k, 0) & 1:
			n += 1
	var code := 0x80 if n == 6 else (0x83 if n == 5 else 0x82)
	m08_fates(w, rng)
	return code


static func m08_on_map(w: Pd2World) -> bool:
	for k in mini(w.units.size() / 55, 254):
		if w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4 and w.ub(k, 9) != 0xFF:
			return true
	return false


## 0x4DE290 on group 0: the lowest crew (signed) among its members, 0xFF with none
static func m08_lead(w: Pd2World) -> int:
	var least := 0xFF
	for i in 16:
		var m := g(w, 0, 6 + i)
		if m != 0xFF:
			least = mini(least, Pd2World.s8(table_byte(w, 55 * m + 0xB)))
	return least


static func m08_scenario(w: Pd2World, rng: Pd2Random) -> void:
	w.set_ds8(0x50ADF2, m08_end_code(w, rng))


static func m08_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks, stale: Variant = null) -> int:
	var lead := func() -> int: return face_of(w, rng, m08_lead(w))
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		if w.ds8(0x50AD6E) & 1:
			if not w.ds8(0x50AD72) & 1:
				ds_or(w, 0x50AD72, 1)
				var res := radio_scene(w, hooks, [["face", 1, 0x2A, 1], ["say", 0xAE, 0x2A], ["face", 0x10, 0x2A, 0],
						["say", 0xAF if w.ds8(0x50AD70) & 1 else 0xC4, 0x2A], ["close"]])
				if res:
					return res
				res = m08_start(w, rng, hooks)
				if res == 0x10000 or res == 0x20000:
					return res
			elif w.ds8(0x50AD72) & 0x3E < 0xC:
				var v := w.ds8(0x50AD72)
				w.set_ds8(0x50AD72, v ^ ((v & 0xFE) + 2 ^ v) & 0x3E)
		if w.ds8(0x50AD72) & 0x3E == 4 and not w.ds8(0x50AD74) & 1:
			ds_or(w, 0x50AD74, 1)
			var res := radio_scene(w, hooks, [
					["face", 1, 0x2A, 1], ["say", 0xB0, 0x2A], ["face", 0x10, 0x2A, 0], ["say", 0xB1, 0x2A],
					["face", lead, 0xB, null], ["say", 0xB2, 0xB], ["say", 0xB3, 0x2A], ["face", 7, 0xB, null],
					["say", 0xB4, 0xB], ["say", 0xB5, 0x2A], ["face", lead, 0xB, null], ["say", 0xB6, 0xB], ["close"]])
			if res:
				return res
		if w.ds8(0x50AD72) & 0x3E == 8 and not w.ds8(0x50AD76) & 1 and w.ds8(0x50AD74) & 1:
			ds_or(w, 0x50AD76, 1)
			var res := radio_scene(w, hooks, [
					["face", 0, 0x2A, 1], ["say", 0xB7, 0x2A], ["face", 0x10, 0x2A, 0], ["say", 0xB8, 0x2A],
					["face", lead, 0xB, null], ["say", 0xB9, 0xB], ["say", 0xBA, 0x2A], ["face", 7, 0xB, null],
					["say", 0xBB, 0xB], ["say", 0xBC, 0x2A], ["say", 0xBD, 0xB], ["say", 0xBE, 0x2A],
					["say", 0xBF, 0xB], ["say", 0xC0, 0x2A], ["face", lead, 0xB, null], ["say", 0xC1, 0xB], ["close"]])
			if res:
				return res
		var r1 := flight_turn(w, rng, hooks)
		if r1 in AI_ABORT:
			return r1
	elif stage == 1:
		if not w.ds8(0x50AD70) & 1:
			var seen := false
			for k in 254:
				var f := w.ub(k, 0)
				if not f & 4:
					continue
				if w.ub(k, 0x36) == 0:
					if f & 0x10 or w.ub(k, 0xD) < 100 or f & 1:
						seen = true
				elif w.ub(k, 0xC) != 0xFF and w.ub(k, 0xD) < 100 and k >= 40 and k <= 45:
					seen = true
			if seen:
				w.set_ds8(0x50ADF1, 1)
				for j in 11:
					var grp := 21 + j
					Ai.group_retarget(w, grp, w.ds8(0x50AD95), w.ds8(0x50AD97))
					var t: Variant = M08_ALARM_TIMES[j] if j < 10 else stale
					if t != null:
						set_g(w, grp, 0x1C, int(t))
					set_g(w, grp, 2, g(w, grp, 2) & 0xDF | 0x10)
					set_g(w, grp, 0x22, 0)
				for j in 4:
					var grp := 32 + j
					Ai.group_retarget(w, grp, w.ds8(0x50AD95), (w.ds8(0x50AD97) - 1) & 0xFF)
					var v: int = (M08_LATE[j] + w.mission_turn) & 0xFFFF
					set_g(w, grp, 0x1D, v & 0xFF)
					set_g(w, grp, 0x1E, v >> 8)
				ds_or(w, 0x50AD70, 1)
		if w.ds8(0x50AD72) & 1:
			for k in 254:
				if not (w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4 and w.ub(k, 9) != 0xFF):
					continue
				var z: Variant = M08_ZONES.get(w.ds8(0x50AD6F) & 0xF)
				var x := w.sb(k, 9)
				var y := w.sb(k, 10)
				if z == null or not (x >= z[0] and x <= z[1] and y >= z[2] and y <= z[3]):
					continue
				var res := hooks.scroll(x, y)
				if res in AI_ABORT:
					return res
				res = hooks.dialog(0xC2, [w.ucrew(k, 0)], 2)
				if res in AI_ABORT:
					return res
				if res == 0:
					Action.take_off_map(w, k)
			if not m08_on_map(w):
				w.set_ds8(0x50ADF2, m08_end_code(w, rng))
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var table := -1
		var count := [0, 0, 0]
		for grp in [0, 2, 4]:
			if not g(w, grp, 5):
				continue
			for f in [0x1A, 0x18, 0x16, 0x1B, 0x19, 0x17]:
				set_g(w, grp, f, 0xFF)
			var sel := Pd2World.s8(g(w, grp, 0x1F))
			table = M08_LANDING.get(sel, table)
			for i in 16:
				var m := g(w, grp, 6 + i)
				if m == 0xFF:
					continue
				if table == -1 or not M08_LANDING.has(sel):
					w.fault = "m08 landing: group %d +0x1F = %d reads the stack or low memory" % [grp, sel]
					return 0
				var a: int = table + 4 * count[sel]
				w.mem_write(UNITS_ADDR + 55 * m + 9, w.mem8(a))
				w.mem_write(UNITS_ADDR + 55 * m + 10, w.mem8(a + 2))
				count[sel] += 1
		var rr: Variant = hooks.radar_open()
		var res: int = int(rr) if rr != null else Flight.grid_init(w, hooks.flight, 0)
		if res in AI_ABORT:
			return res
		var first := func() -> int: return face_of(w, rng, 1)
		res = radio_scene(w, hooks, [
				["face", first, 10, null], ["say", 0xA4, 10], ["face", 0x10, 0x2B, 0], ["say", 0xA5, 0x2B],
				["face", 7, 10, null], ["say", 0xA6, 10], ["say", 0xA7, 0x2B], ["say", 0xA8, 10], ["say", 0xA9, 0x2B],
				["face", 0, 0x2B, 1], ["say", 0xAA, 0x2B], ["face", first, 10, null], ["say", 0xAB, 10],
				["face", 7, 0x2B, 0], ["say", 0xAC, 0x2B], ["face", 0x10, 0x2B, 0], ["say", 0xAD, 0x2B], ["close"]])
		if res:
			return res
		var px := w.ds8(0x50AD95)
		var py := w.ds8(0x50AD97)
		for f in [G_TARGET_X, G_PREV_X, G_X]:
			set_g(w, 0, f, px)
			set_g(w, 0, f + 1, py)
		set_g(w, 0, 2, g(w, 0, 2) & 0xF | 0x20)
		for k in range(40, 46):
			var left := false
			for i in 12:
				if static_s16(w, 0x51AD88 + 4 * i):
					left = true
			if not left:
				w.fault = "m08 targets: no unused point left (an endless loop)"
				return 0
			var i := rng.r16(12)
			while static_s16(w, 0x51AD88 + 4 * i) == 0:
				i = rng.r16(12)
			var x := w.mem8(0x51AD88 + 4 * i)
			var y := w.mem8(0x51AD8A + 4 * i)
			w.setb(k, 9, x)
			w.setb(k, 10, y)
			w.setb(k, 7, x)
			w.setb(k, 8, y)
			w.mem_write(0x51AD88 + 4 * i, 0)
			w.mem_write(0x51AD89 + 4 * i, 0)
		ds_or(w, 0x50AD4E, 1)
	if not m08_on_map(w):
		w.set_ds8(0x50ADF2, m08_end_code(w, rng))
	return 0


# --- mission 10 (script 10, PD2 chunk 9: the sites and the control room; rules.m10_*) -----

const M10_GUARDS := {2: [0x14, 0x16, 0x19], 3: [0x15, 0x22], 4: [0x21, 0x20], 5: [0x18], 6: [0x17],
		7: [0x1B], 8: [0x1A], 9: [0x1C]}

const M10_STOCK := [[0x50668A, 0, 4], [0x506654, 0x0C0C0C0C, 4], [0x50668E, 0, 4], [0x506658, 0x0C0C, 2],
		[0x506692, 0, 1], [0x506680, 0x18181818, 4], [0x506686, 0x18181818, 4], [0x506693, 0x1818, 2],
		[0x506674, 0x18181818, 4], [0x50665A, 0x0C, 1], [0x506695, 0x18, 1], [0x506678, 0x18181818, 4],
		[0x5066D4, 0, 4], [0x5066E5, 0, 4], [0x5066D8, 0, 2], [0x5066E9, 0, 4], [0x5066FE, 0, 4],
		[0x5066ED, 0, 2], [0x50667C, 0, 4], [0x506684, 0, 1], [0x506685, 0, 1], [0x5066BF, 0x18, 1],
		[0x5066F2, 0, 2], [0x506702, 0, 1], [0x506706, 0, 41], [0x5066DA, 0x3C3C3C3C, 4],
		[0x506730, 0, 4], [0x5066DE, 0x3C3C3C3C, 4], [0x5066E0, 0x0F, 1], [0x5066E2, 0x3C3C, 2],
		[0x50672F, 0x3C, 1], [0x5066F4, 0x3C3C3C3C, 4], [0x5066E4, 0x3C, 1], [0x5066EF, 0x3C3C, 2],
		[0x5066F8, 0x3C3C3C3C, 4], [0x506703, 0x3C3C, 2], [0x5066F1, 0x3C, 1], [0x5066FC, 0x3C3C, 2],
		[0x506705, 0x3C, 1]]


static func m10_load(w: Pd2World) -> void:
	static_copy(w, 0x51B1A0, 0x51B1D0, 48)
	for k in 10:
		static_copy(w, 0x51B200 + 0x30 * k, 0x51B218 + 0x30 * k, 24)
	for k in 10:
		static_copy(w, 0x51B3E0 + 0xB0 * k, 0x51B438 + 0xB0 * k, 84)


static func m10_init(w: Pd2World, hooks: Hooks) -> int:
	for a in [0x50AD99, 0x50AD9B, 0x50AD9D, 0x50AD9F, 0x50ADA1, 0x50ADA3, 0x50ADA5, 0x50ADA7,
			0x50ADA9, 0x50ADAB, 0x50ADAD, 0x50ADAF]:
		w.set_ds16(a, 0)
	w.set_ds16(0x50AD95, 7)
	w.set_ds16(0x50AD97, 7)
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51B140 + i)
		w.ds[0xD1 + i] = w.mem8(0x51B160 + i)
	set_506651(w, 0x101)
	if w.ds8(0x50AD94):
		return w.ds8(0x50AD94)
	var t92 := Flight.s16(w.ds16(0x50AD92))
	for c in 64:
		var q := c * Pd2World.CREW
		if w.crew[q + 4] > t92 or w.crew[q + 2] != 0:
			continue
		Equipment.free_all(w, c)
		var grp := w.crew[q + 5]
		if grp == 0xFF:
			continue
		if grp >= 64:
			w.fault = "m10 init: crew %d in group %d, past the group table" % [c, grp]
			return 0
		if Action.group_drop_player(w, grp, c):
			var res := hooks.note(0x1CE) if hooks != null else 0
			if res < 0:
				return res
		w.setb(c, 0, w.ub(c, 0) & 0xFB)
	for e in M10_STOCK:
		for i in e[2]:
			w.mem_write(e[0] + i, (e[1] >> 8 * i) & 0xFF if i < 4 else 0)
	return 0x3C3C3C3C


## 0x453900: "HH:MM" of turn t from the start d over the digits of DS:0x515170 (rules.time_text)
static func time_text(w: Pd2World, t: int, d: int) -> Array:
	var v := (t + d) * 5
	var h := v / 60
	var m := v % 60
	if h > 23:
		h %= 24
	for p in [[0x515170, h / 10], [0x515171, h % 10], [0x515173, m / 10], [0x515174, m % 10]]:
		for base in w.static_mem:
			if p[0] >= base and p[0] < base + w.static_mem[base].size():
				w.mem_write(p[0], 0x30 + p[1])
	return ["time", t, d]


static func m10_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	if w.sb(u, 0xE) < 0x1E:
		var r0 := hooks.line(0xA1)
		return r0 if r0 in AI_ABORT else 0
	if w.ub(u, 9) != 0x24 or w.ub(u, 10) != 0x29:
		var r1 := hooks.line(0xA4)
		return r1 if r1 in AI_ABORT else 0
	var res := Flight._radio_face(w, hooks.flight, 3, 0x3A, null)
	if not res in AI_ABORT:
		var when := time_text(w, w.mission_turn & 0xFFFF, (w.ds_506651 & 0xFF) | w.mem8(0x506652) << 8)
		res = hooks.flight.radio_say(0xA2, [when], 0x3A)
		if not res in AI_ABORT:
			res = Flight._radio_face(w, hooks.flight, face_of(w, rng, m08_lead(w)), 0xB, null)
			if not res in AI_ABORT:
				res = hooks.flight.radio_say(0xA3, [], 0xB)
				if not res in AI_ABORT:
					hooks.flight.radio_close(-1)
					if w.radar:
						hooks.radar_close()
						set_radar_flag(w, 0)
						res = hooks.unit_panel()
						if res in AI_ABORT:
							return res
						res = hooks.map_redraw()
						if res in AI_ABORT:
							return res
						res = hooks.date_window()
						if res in AI_ABORT:
							return res
						set_radar_flag(w, 0)
					w.set_ds8(0x50ADF2, 0x80)
					return 1
	hooks.flight.radio_close(-1)
	return res


static func m10_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		var r0 := flight_turn(w, rng, hooks)
		if r0 in AI_ABORT:
			return r0
	if not w.ds8(0x50AD4E) & 1:
		group_scan(w)
		var px := w.ds8(0x50AD95)
		var py := w.ds8(0x50AD97)
		for f in [G_X, G_PREV_X, G_TARGET_X]:
			set_g(w, 0, f, px)
			set_g(w, 0, f + 1, py)
		set_g(w, 0, 2, g(w, 0, 2) & 0xF | 0x20)
		set_g(w, 0, 0x1C, 0)
		set_g(w, 0, 0x22, 0)
		var a := 0x51B1A0
		for i in 16:
			var m := g(w, 0, 6 + i)
			if m != 0xFF:
				w.mem_write(UNITS_ADDR + 55 * m + 9, w.mem8(a))
				w.mem_write(UNITS_ADDR + 55 * m + 10, w.mem8(a + 2))
				a += 4
		var res := radio_scene(w, hooks, [["face", 3, 0x3A, null], ["say", 0x121, 0x3A], ["face", 10, 0xB, null],
				["say", 0x122, 0xB], ["close"]])
		if res:
			return res
		ds_or(w, 0x50AD4E, 1)
	if g(w, 0, 5) + g(w, 2, 5) + g(w, 4, 5) == 0:
		w.set_ds8(0x50ADF2, 0x82)
	return 0


static func m10_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	for n in 10:
		if hit_table(w, x, y, 0x51B200 + 0x30 * n, 6):
			return n + 1
	return -1


static func m10_break(w: Pd2World, hooks: Hooks, n: int) -> int:
	for j in 14:
		var a := 0x51B3E0 + 0xB0 * (n - 1) + 6 * j
		var x := static_s16(w, a)
		var y := static_s16(w, a + 2)
		set_height_tile(w, x, y, w.mem8(a + 4), w.mem8(a + 5))
		var res := hooks.redraw_hex(x, y)
		if res == 0x10000 or res == 0x20000:
			return res
	return 0


static func m10_bomb(w: Pd2World, rng: Pd2Random, i: int, hooks: Hooks) -> int:
	var v := w.mem8(0x50AC1F + 4 * i)
	if v < 1 or v > 10:
		if i > 0:
			w.fault = "m10 bomb hook: an entry without a site reads low memory"
		return 0
	ds_or(w, 0x50AD50 + 2 * (v - 1), 1)
	for j in 16:
		for grp in M10_GUARDS.get(v, []):
			var a: int = UNITS_ADDR + 55 * g(w, grp, 6 + j) + 3
			var o := w.mem8(a)
			w.mem_write(a, o >> 4 | o & 0xF0)
	if v == 10:
		w.set_ds8(0x50ADF1, 1)
	return m10_break(w, hooks, v)


static func m10_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	for n in range(1, 11):
		if w.ds8(0x50AD50 + 2 * (n - 1)) & 1:
			var res := m10_break(w, hooks, n)
			if res:
				return res
	return 0


# --- DASH mission 2 (script 12, DASH chunk 1: the sappers of groups 21 / 26; rules.m12_*) --

const M12_FIX21 := Vector2i(0x41, 0x3C)
const M12_FIX26 := Vector2i(0x46, 0x46)
const M12_PTS := {"a": [[0x26, 0x20], [0x27, 0x20]], "b": [[0x36, 0x28], [0x37, 0x28]],
		"c": [[0x37, 0x20], [0x38, 0x20]], "d": [[0x42, 0x28], [0x43, 0x28]]}
const M12_CHARGES := [[0x50AD50, 0x50AD51, 0x15, 0x50AD8A, [[0x37, 0x24], [0x38, 0x24]]],
		[0x50AD52, 0x50AD53, 0x1A, 0x50AD8C, [[0x26, 0x24], [0x27, 0x24]]],
		[0x50AD52, 0x50AD53, 0x1A, 0x50AD8C, [[0x36, 0x2C], [0x37, 0x2C]]],
		[0x50AD50, 0x50AD51, 0x15, 0x50AD8A, [[0x42, 0x2C], [0x43, 0x2C]]]]


static func m12_rnd(w: Pd2World, rng: Pd2Random, grp: int, pts: Array, check := -1) -> void:
	for j in 16:
		if g(w, check if check != -1 else grp, 6 + j) == 0xFF:
			continue
		var a := UNITS_ADDR + 55 * g(w, grp, 6 + j)
		w.mem_write(a + 7, pts[rng.r16(2)][0])
		w.mem_write(a + 8, pts[rng.r16(2)][1])


static func m12_fix(w: Pd2World, grp: int, p: Vector2i) -> void:
	for j in 16:
		var m := g(w, grp, 6 + j)
		if m != 0xFF:
			w.mem_write(UNITS_ADDR + 55 * m + 7, p.x)
			w.mem_write(UNITS_ADDR + 55 * m + 8, p.y)


static func m12_step(w: Pd2World, a: int) -> void:
	var v := w.ds8(a)
	w.set_ds8(a, v ^ ((v & 0xFE) + 2 ^ v) & 0x3E)


static func m12_fuse(w: Pd2World, a: int) -> bool:
	var v := w.ds8(a)
	v = (v ^ (((v - 1) ^ v) & 0xF)) & 0xFF
	w.set_ds8(a, v)
	return v & 0xF == 0


static func m12_load(w: Pd2World) -> void:
	static_copy(w, 0x51C0A8, 0x51C0E8, 64)
	static_copy(w, 0x51C128, 0x51C218, 240)
	static_copy(w, 0x51C308, 0x51C3F8, 240)


static func m12_init(w: Pd2World) -> int:
	for p in [[0x50AD97, 7], [0x50AD9B, 7], [0x50AD99, 0xE], [0x50AD9D, 0xE], [0x50ADA1, 0xE],
			[0x50AD95, 0xB], [0x50AD9F, 8], [0x50ADA3, 9], [0x50ADA5, 0], [0x50ADA7, 3],
			[0x50ADA9, 0], [0x50ADAB, 4], [0x50ADAD, 0], [0x50ADAF, 5]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51C048 + i)
		w.ds[0xD1 + i] = w.mem8(0x51C068 + i)
	w.mem_write(0x5066E0, 0)
	set_506651(w, 0x36)
	return 0


static func m12_objective(w: Pd2World) -> int:
	var any := false
	for grp in [0, 2, 4]:
		if g(w, grp, 0x21) & 0xF in [2, 3]:
			any = true
	if not any:
		return 0x10A
	for grp in range(12, 20):
		if g(w, grp, 0x21) & 0xF == 4:
			return -1
	return 0x10B


static func m12_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	var n := 0
	for k in 254:
		var f := w.ub(k, 0)
		if w.sb(k, 0x36) > 2 and w.ub(k, 0xD) and not f & 1 and f & 8 and f & 4 and w.sb(k, 9) > 0x3D and w.sb(k, 10) > 0x37:
			n += 1
	var res := hooks.message(0xAD, [n])
	return res if res in AI_ABORT else 0


static func m12_end_code(w: Pd2World, rng: Pd2Random) -> int:
	if w.ds8(0x50AD7D) & 0xF == 1 or w.ds8(0x50AD81) & 0xF == 1:
		return 0x80
	for k in 254:
		var f := w.ub(k, 0)
		if w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and f & 4 and f & 1 and (rng.roll(100) & 0xFFFF) & 3 != 2:
			mark_crew(w, w.ub(k, 0xB), 2)
	return 0x82


static func m12_scenario(w: Pd2World, rng: Pd2Random) -> void:
	w.set_ds8(0x50ADF2, m12_end_code(w, rng))
	if w.ds8(0x50AD76) & 1:
		w.set_ds8(0x50ADF2, 0x83)


static func m12_blast(w: Pd2World, rng: Pd2Random, n: int, live: int, hooks: Hooks) -> int:
	var base := 0x51C128 + 0x3C * (n - 1)
	var skip := false
	if live:
		var r0 := hooks.blast_open()
		if r0 in AI_ABORT:
			return r0
		var x0 := static_s16(w, base)
		var y0 := static_s16(w, base + 2)
		r0 = hooks.scroll(x0, y0)
		if r0 in AI_ABORT:
			return r0
		r0 = hooks.blast_start(x0, y0)
		if r0 in AI_ABORT:
			return r0
		skip = r0 == 0x80000
	var easy := hooks.options & 2 != 0
	for j in 15:
		var x := static_s16(w, base + 4 * j)
		var y := static_s16(w, base + 4 * j + 2)
		if live:
			var bl := blast(w, hooks, x, y, skip)
			skip = bl[1]
			if bl[0]:
				return bl[0]
			for _i in 2:
				var o := occupant_raw(w, x, y)
				if o != -1:
					var dmg := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
					if dmg and Fire.apply_hit(w, rng, o, dmg, -1, 12, easy) == "destroyed":
						Action.destroy(w, o)
		set_height_tile(w, x, y, static_s16(w, 0x51C308 + 0x3C * (n - 1) + 4 * j),
				static_s16(w, 0x51C30A + 0x3C * (n - 1) + 4 * j))
		var r1 := hooks.redraw_hex(x, y)
		if r1 == 0x10000 or r1 == 0x20000:
			return r1
	if live:
		var r2 := hooks.blast_close()
		if r2 == 0x10000 or r2 == 0x20000:
			return r2
	return 0


static func m12_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	for e in [[0x50AD8A, 4, 1], [0x50AD8C, 3, 2]]:
		var c := w.ds8(e[0]) >> 1 & 0x1F
		if c >= 2 and c <= 4:
			for n in ([e[1], e[2]] if c == 4 else [e[2]]):
				var res := m12_blast(w, rng, n, 0, hooks)
				if res in AI_ABORT:
					return res
	return 0


static func m12_lost(w: Pd2World, hooks: Hooks) -> int:
	return radio_scene(w, hooks, [["face", 0x14, 10, null], ["say", 0xA1, 10], ["say", 0xA6, 10], ["say", 0xA3, 10],
			["face", 0x11, 0x2B, 0], ["say", 0xA7, 0x2B], ["say", 0xA8, 10], ["close"]])


static func m12_alive(w: Pd2World, k: int) -> bool:
	var f := w.ub(k, 0)
	return w.ub(k, 0xD) != 0 and not f & 1 and f & 8 != 0


static func m12_lead_face(w: Pd2World) -> int:
	return 10 if m12_alive(w, 1) else (0xB if m12_alive(w, 16) else 0xD)


static func m12_charge(w: Pd2World, pts: Array) -> Array:
	for p in pts:
		var o := occupant_raw(w, p[0], p[1])
		if o == -1:
			continue
		var a := UNITS_ADDR + 55 * o
		if w.mem8(a + 0xD) and not w.mem8(a) & 1:
			for q in 6:
				if w.mem8(a + 0x1B + 2 * q) == 0xC:
					return [a, q]
	return []


static func m12_route(w: Pd2World, rng: Pd2Random, grp: int, other_has: int, mine: int, other: int) -> void:
	var fix := M12_FIX21 if grp == 0x15 else M12_FIX26
	var lo := "a" if grp == 0x15 else "c"
	var hi := "b" if grp == 0x15 else "d"
	var table: Dictionary
	if not other_has:
		table = {0: {0: "F", 1: lo, 2: "F", 3: hi, 4: "F"}, 2: {0: "F", 1: "F", 2: "F", 3: hi, 4: "F"}}
	else:
		table = {0: {0: lo, 1: lo, 2: hi, 3: hi, 4: "F"}, 2: {0: hi, 1: hi, 2: hi, 3: hi, 4: "F"}}
	var act: String = table.get(mine, {}).get(other, "")
	if act == "F":
		m12_fix(w, grp, fix)
	elif act != "":
		m12_rnd(w, rng, grp, M12_PTS[act])


static func m12_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var lead := func() -> int: return m12_lead_face(w)
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		if w.ds8(0x50AD76) & 1:
			for grp in range(20, 64):
				if Flight.group_alive(w, grp):
					for j in 16:
						var m := g(w, grp, 6 + j)
						if m != 0xFF and (Pd2World.s8(table_byte(w, 55 * m + 9)) == 1 or Pd2World.s8(table_byte(w, 55 * m + 10)) == 1):
							Action.take_off_map(w, m)
		var n := 0
		for grp in range(20, 64):
			if Flight.group_alive(w, grp):
				for j in 16:
					var m := g(w, grp, 6 + j)
					if m != 0xFF and Pd2World.s8(table_byte(w, 55 * m + 9)) > 0x3D and Pd2World.s8(table_byte(w, 55 * m + 10)) > 0x37:
						n += 1
		if n > 4:
			var any := false
			for j in 16:
				var m := g(w, 0, 6 + j)
				if m != 0xFF and m12_alive(w, m):
					any = true
			if not any:
				var r0 := m12_lost(w, hooks)
				if r0 in AI_ABORT:
					return r0
			else:
				var r1 := radio_scene(w, hooks, [["face", 0x14, 10, null], ["say", 0xA1, 10], ["say", 0xA9, 10],
						["face", lead, 0x2B, 0], ["say", 0xAA, 0x2B], ["close"]])
				if r1:
					return r1
			w.set_ds8(0x50AD7F, w.ds8(0x50AD7F) & 0xF2 | 2)
			w.set_ds8(0x50ADF2, m12_end_code(w, rng))
			return 0
		var r2 := flight_turn(w, rng, hooks)
		if r2 in AI_ABORT:
			return r2
	elif stage == 1:
		var players := 0
		for k in 254:
			if w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4:
				players += 1
		if w.ds8(0x50AD76) & 0x3E > 5 and players:
			var r3 := radio_scene(w, hooks, [["face", 0x14, 10, null], ["say", 0xA1, 10], ["say", 0xA2, 10],
					["face", lead, 0x2B, 0], ["say", 0xAC, 0x2B], ["close"]])
			if r3:
				return r3
			w.set_ds8(0x50AD81, w.ds8(0x50AD81) & 0xF1 | 1)
			w.set_ds8(0x50ADF2, m12_end_code(w, rng))
			return 0
		if w.ds8(0x50AD50) & 0x3E == 2 and m12_fuse(w, 0x50AD51):
			var r4 := m12_blast(w, rng, 1, 1, hooks)
			if r4 in AI_ABORT:
				return r4
			m12_rnd(w, rng, 0x15, [[0x42, 0x2C], [0x43, 0x2C]])
			w.set_ds8(0x50ADF1, 1)
			m12_step(w, 0x50AD50)
			m12_step(w, 0x50AD8A)
		if w.ds8(0x50AD52) & 0x3E == 2 and m12_fuse(w, 0x50AD53):
			var r5 := m12_blast(w, rng, 2, 1, hooks)
			if r5 in AI_ABORT:
				return r5
			m12_rnd(w, rng, 0x1A, [[0x36, 0x2C], [0x37, 0x2C]], 0x15)
			w.set_ds8(0x50ADF1, 1)
			m12_step(w, 0x50AD52)
			m12_step(w, 0x50AD8C)
		if w.ds8(0x50AD52) & 0x3E == 6 and m12_fuse(w, 0x50AD53):
			var r6 := m12_blast(w, rng, 3, 1, hooks)
			if r6 in AI_ABORT:
				return r6
			m12_fix(w, 0x1A, M12_FIX26)
			m12_step(w, 0x50AD52)
			m12_step(w, 0x50AD8C)
		if w.ds8(0x50AD50) & 0x3E == 6 and m12_fuse(w, 0x50AD51):
			var r7 := m12_blast(w, rng, 4, 1, hooks)
			if r7 in AI_ABORT:
				return r7
			m12_fix(w, 0x15, M12_FIX21)
			m12_step(w, 0x50AD50)
			m12_step(w, 0x50AD8A)
		if w.ds8(0x50AD76) & 1 and w.ds8(0x50AD76) & 0x3E < 0x3C:
			m12_step(w, 0x50AD76)
		var n21 := 0
		var n26 := 0
		for j in 16:
			for grp in [0x15, 0x1A]:
				var m := g(w, grp, 6 + j)
				if m != 0xFF:
					for q in 6:
						if table_byte(w, 55 * m + 0x1B + 2 * q) == 0xC:
							if grp == 0x15:
								n21 += 1
							else:
								n26 += 1
		var sa := w.ds8(0x50AD50) >> 1 & 0x1F
		var sb := w.ds8(0x50AD52) >> 1 & 0x1F
		if n21 == 0:
			m12_route(w, rng, 0x15, n26, sa, sb)
		if n26 == 0:
			m12_route(w, rng, 0x1A, n21, sb, sa)
		for e in M12_CHARGES:
			var want := 0 if e[4][0][1] == 0x24 else 4
			if w.ds8(e[0]) & 0x3E != want:
				continue
			var hit := m12_charge(w, e[4])
			if hit.is_empty():
				continue
			var ua: int = hit[0]
			var q: int = hit[1]
			w.mem_write(ua + 0x1B + 2 * q, 0xFF)
			w.mem_write(ua + 0x1C + 2 * q, w.mem8(ua + 0x1C + 2 * q) & 0xC0)
			w.set_ds8(e[1], w.ds8(e[1]) & 0xF2 | 2)
			for j in 16:
				var m := g(w, e[2], 6 + j)
				if m != 0xFF and table_byte(w, 55 * m + 0xD) and not table_byte(w, 55 * m) & 1:
					w.mem_write(UNITS_ADDR + 55 * m + 8, e[4][0][1] - 4)
			m12_step(w, e[0])
			m12_step(w, e[3])
		if not w.ds8(0x50AD76) & 1:
			var dead := n21
			for k in 254:
				var f := w.ub(k, 0)
				if w.sb(k, 0x36) > 2 and f & 4 and f & 8 and f & 1:
					dead += 1
			if dead > 0x31:
				for grp in range(20, 64):
					if Flight.group_alive(w, grp):
						for j in 16:
							var m := g(w, grp, 6 + j)
							if m != 0xFF:
								var a2 := UNITS_ADDR + 55 * m
								if Pd2World.s8(w.mem8(a2 + 10)) < Pd2World.s8(w.mem8(a2 + 9)):
									w.mem_write(a2 + 8, 1)
								else:
									w.mem_write(a2 + 7, 1)
				ds_or(w, 0x50AD76, 1)
		if not w.ds8(0x50AD64) & 1 and (w.ds8(0x50AD50) & 0x3E < 4 or w.ds8(0x50AD52) & 0x3E < 4):
			var nin := 0
			for k in 254:
				var f := w.ub(k, 0)
				var y := w.sb(k, 10)
				if w.ub(k, 0x36) == 0 and f & 8 and w.ub(k, 0xD) and not f & 1 and w.sb(k, 9) > 0x20 and y > 0x25 and y < 0x30:
					nin += 1
			if nin > 1:
				if w.ds8(0x50AD64) & 0x3E > 5:
					w.set_ds8(0x50AD50, w.ds8(0x50AD50) & 0xC9 | 8)
					w.set_ds8(0x50AD52, w.ds8(0x50AD52) & 0xC9 | 8)
					m12_fix(w, 0x15, M12_FIX21)
					m12_fix(w, 0x1A, M12_FIX26)
					ds_or(w, 0x50AD64, 1)
				m12_step(w, 0x50AD64)
	if w.ds8(0x50AD4E) & 1:
		var ground := 0
		for k in 254:
			if w.ub(k, 0xD) and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4 and w.mem8(0x506734 + 16 * w.sb(k, 0xB) + 3) == 0:
				ground += 1
		if not ground:
			if not w.ds8(0x50AD76) & 1:
				var r8 := m12_lost(w, hooks)
				if r8 in AI_ABORT:
					return r8
				w.set_ds8(0x50AD7D, w.ds8(0x50AD7D) & 0xF2 | 2)
			else:
				var r9 := radio_scene(w, hooks, [["face", 0x14, 10, null], ["say", 0xA1, 10], ["say", 0xA2, 10],
						["say", 0xA3, 10], ["face", 0x11, 0x2B, 0], ["say", 0xA4, 0x2B], ["say", 0xA5, 10], ["close"]])
				if r9:
					return r9
				w.set_ds8(0x50AD7D, w.ds8(0x50AD7D) & 0xF1 | 1)
			w.set_ds8(0x50ADF2, m12_end_code(w, rng))
		return 0
	group_scan(w)
	var px := w.ds8(0x50AD95)
	var py := w.ds8(0x50AD97)
	for f in [G_X, G_PREV_X, G_TARGET_X]:
		set_g(w, 0, f, px)
		set_g(w, 0, f + 1, py)
	set_g(w, 0, 2, g(w, 0, 2) & 0xF | 0x20)
	set_g(w, 0, 0x1C, 0)
	set_g(w, 0, 0x22, 0)
	var a := 0x51C0A8
	for i in 16:
		var m := g(w, 0, 6 + i)
		if m != 0xFF:
			w.mem_write(UNITS_ADDR + 55 * m + 9, w.mem8(a))
			w.mem_write(UNITS_ADDR + 55 * m + 10, w.mem8(a + 2))
			a += 4
	ds_or(w, 0x50AD4E, 1)
	return 0


# --- DASH mission 3 (script 14, DASH chunk 3: hold until the reserve arrives; rules.m14_*) -

const M14_FALLBACK := [[8, 0xE], [8, 0xE], [8, 0xE], [0xE, 8], [0xE, 8], [8, 0xE], [8, 0xE], [0xE, 8], [0xE, 8], [0xE, 8]]


static func m14_load(w: Pd2World) -> void:
	static_copy(w, 0x51C840, 0x51C878, 52)


static func m14_init(w: Pd2World) -> int:
	for p in [[0x50AD99, 0xE], [0x50ADA7, 0xE], [0x50ADA9, 0xE], [0x50ADAD, 0xE], [0x50AD95, 0xC],
			[0x50AD97, 8], [0x50AD9B, 5], [0x50AD9D, 0xC], [0x50AD9F, 5], [0x50ADA1, 10],
			[0x50ADA3, 5], [0x50ADA5, 8], [0x50ADAB, 8], [0x50ADAF, 10]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51C808 + i)
		w.ds[0xD1 + i] = w.mem8(0x5242A0 + i)
	set_506651(w, 0x5A)
	return 0


static func m14_fates(w: Pd2World, rng: Pd2Random, code: int) -> void:
	if not code in [0x80, 0x82, 0x83]:
		return
	for grp in 20:
		if not g(w, grp, 5):
			continue
		for j in 16:
			var m := g(w, grp, 6 + j)
			if m == 0xFF:
				continue
			var a := UNITS_ADDR + 55 * m
			var dead := w.mem8(a) & 1
			if code == 0x82:
				if not dead:
					if rng.r16(100) & 1 == 0 and rng.r16(100) & 1 == 0:
						w.mem_write(a, w.mem8(a) | 1)
						w.mem_write(a + 0xD, 0)
						if rng.r16(100) & 1 == 0:
							mark_crew(w, w.mem8(a + 0xB), 2)
				elif rng.r16(100) & 1 == 0 and rng.r16(100) & 1 == 0:
					mark_crew(w, w.mem8(a + 0xB), 2)
			elif dead and rng.r16(100) % 3 == 1:
				mark_crew(w, w.mem8(a + 0xB), 2)


static func m14_scenario(w: Pd2World, rng: Pd2Random) -> void:
	w.set_ds8(0x50ADF2, 0x82)
	m14_fates(w, rng, 0x82)
	for c in 64:
		var q := c * Pd2World.CREW
		if w.crew[q + 2] == 0 and w.crew[q + 4] == 2 and not w.ub(c, 0) & 8:
			w.crew[q + 6] &= 0xFC
			w.crew[q + 4] = 3
			w.crew[q + 7] = 0


static func m14_lost(w: Pd2World) -> int:
	var n := 0
	for k in 254:
		var f := w.ub(k, 0)
		if (w.sb(k, 0x36) > 2 or f & 8) and (w.ub(k, 0xD) == 0 or f & 1):
			n += 1
	return n


static func m14_call_up(w: Pd2World, grp: int, air: int, most: int) -> int:
	var n := 0
	for c in 64:
		if n >= most:
			break
		var q := c * Pd2World.CREW
		if w.crew[q + 4] != 3 or w.crew[q + 2] != 0 or w.crew[q + 3] != air:
			continue
		set_g(w, grp, 6 + n, c)
		w.crew[q + 4] = 2
		w.crew[q + 6] &= 0xFC
		w.crew[q + 7] = 0
		n += 1
		w.setb(c, 0xD, w.mem8(0x50ADF7 + 31 * w.sb(c, 0xC)))
		for i in 6:
			if w.ub(c, 0xF + 2 * i) != 0xFF:
				w.setb(c, 0x10 + 2 * i, w.ub(c, 0x10 + 2 * i) & 0xCF)
		for i in 12:
			if w.ub(c, 0x1B + 2 * i) != 0xFF:
				w.setb(c, 0x1C + 2 * i, w.mem8(0x50B835 + 12 * w.sb(c, 0x1B + 2 * i)) & 0x3F)
		w.setb(c, 1, 0)
		w.setb(c, 2, w.ub(c, 2) & 0xF0)
	set_g(w, grp, 5, n)
	return n


static func m14_form(w: Pd2World, grp: int, sticky: bool) -> void:
	if sticky:
		set_g(w, grp, 3, g(w, grp, 3) | 1)
	else:
		set_g(w, grp, 0x16, g(w, grp, 0x18))
		set_g(w, grp, 0x17, g(w, grp, 0x19))
	set_g(w, grp, 2, g(w, grp, 2) & 0xDF | 0x11)
	set_g(w, grp, 0x1C, 0)
	set_g(w, grp, 0x22, 0)


static func m14_send(w: Pd2World) -> void:
	for grp in [0x14, 0x15]:
		set_g(w, grp, 2, g(w, grp, 2) & 0xEF | 0x20)
	ds_or(w, 0x50AD50, 1)
	w.set_ds8(0x50ADF1, 2)


static func m14_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		var r0 := flight_turn(w, rng, hooks)
		if r0 in AI_ABORT:
			return r0
		if w.ds8(0x50AD76) & 1:
			for k in 254:
				var f := w.ub(k, 0)
				var x := w.sb(k, 9)
				var y := w.sb(k, 10)
				if w.sb(k, 0x36) > 2 and (f & 8 or w.ub(k, 0xD)) and not f & 1 and (x == 0x45 or x == 0x46 or y == 0x45 or y == 0x46):
					Action.take_off_map(w, k)
			if w.ds8(0x50AD76) & 0x3E < 0x3C:
				m12_step(w, 0x50AD76)
		if not w.ds8(0x50AD8C) & 1:
			var lost := 0
			var alive := 0
			for k in 254:
				if w.sb(k, 0x36) < 3 and w.ub(k, 0) & 8:
					if w.ub(k, 0xD) == 0 or w.ub(k, 0) & 1:
						lost += 1
					else:
						alive += 1
			var t := w.mission_turn & 0xFFFF
			if alive and ((not lost and t >= 0xF) or (lost and t >= 0xA)):
				m14_call_up(w, 2, 0, 3)
				m14_form(w, 2, true)
				var n3 := m14_call_up(w, 3, 1, 2)
				if n3 < (g(w, 2, 5) + 1) / 2:
					var r1 := hooks.line(0x51C8AC)
					return 0x20000 if r1 == -3 else (0x40000 if r1 == -2 else 0x10000)
				m14_form(w, 3, false)
				m14_call_up(w, 4, 0, 3)
				m14_form(w, 4, true)
				var n5 := m14_call_up(w, 5, 1, 2)
				if n5 < (g(w, 4, 5) + 1) / 2:
					var r2 := hooks.line(0x51C8BC)
					return 0x20000 if r2 == -3 else (0x40000 if r2 == -2 else 0x10000)
				m14_form(w, 5, false)
				if g(w, 3, 5) + n5:
					var rr: Variant = hooks.radar_open()
					var r3: int = int(rr) if rr != null else Flight.grid_init(w, hooks.flight, 0)
					if r3 in AI_ABORT:
						return r3
					for c in 64:
						var q := c * Pd2World.CREW
						if w.ub(c, 0x36) == 0 and w.crew[q + 4] == 2 and w.crew[q + 2] == 0:
							w.crew[q + 4] = w.ds8(0x50AD8E)
							w.setb(c, 0, w.ub(c, 0) | 4)
					var sel := func() -> int:
						if w.crew[16 + 5] == 0 and w.ub(1, 0xD) and not w.ub(1, 0) & 1:
							return 10
						return 0xB if w.crew[16 * 16 + 5] == 0 and w.ub(16, 0xD) and not w.ub(16, 0) & 1 else 0xD
					var when := func() -> Array:
						return [time_text(w, (w.mission_turn + 4) & 0xFFFF, (w.ds_506651 & 0xFF) | w.mem8(0x506652) << 8)]
					r3 = radio_scene(w, hooks, [
							["face", 8, 0x3A, null], ["say", 0xA6, 0x3A], ["face", sel, 0xB, null], ["say", 0xA7, 0xB],
							["close", 3], ["face", 8, 0x2A, 1], ["face", 1, 0x2A, 0], ["say", 0xA8, 0x2A],
							["say", 0xA9, 0xB], ["say", 0xAA, 0x2A, when], ["close"]])
					if r3:
						return r3
				ds_or(w, 0x50AD8C, 1)
	elif stage == 1:
		var go_on := 1
		if not w.ds8(0x50AD50) & 1:
			if not w.ds8(0x50AD76) & 1 and (g(w, 8, 2) & 0xC0 or g(w, 10, 2) & 0xC0) \
					and not g(w, 0x14, 2) & 0x30 and not g(w, 0x15, 2) & 0x30:
				m14_send(w)
			if not w.ds8(0x50AD50) & 1 and not w.ds8(0x50AD76) & 1:
				if w.ds8(0x50AD8C) & 1 and m14_lost(w) > 0x31:
					m14_send(w)
			elif not w.ds8(0x50AD50) & 1:
				go_on = 2
		if go_on == 1 and not w.ds8(0x50AD76) & 1:
			var n := 0
			for k in 254:
				var f := w.ub(k, 0)
				if w.sb(k, 0x36) > 2 and ((w.ub(k, 0xD) and w.ub(k, 9) != 0xFF and f & 8) or (not f & 9 and f & 4)):
					n += 1
			if n < 0x19:
				for k in 254:
					var f := w.ub(k, 0)
					if w.sb(k, 0x36) > 2 and f & 8 and w.ub(k, 0xD) and not f & 1:
						w.setb(k, 3, w.ub(k, 3) & 0xF | 0x50)
						var x := w.sb(k, 9)
						var y := w.sb(k, 10)
						if 0x45 - x < 0x46 - y:
							w.setb(k, 7, 0x45)
							w.setb(k, 8, w.ub(k, 10))
						else:
							w.setb(k, 8, 0x46)
							var bx := w.ub(k, 9)
							w.setb(k, 7, (bx - 1) & 0xFF if bx == 0x2A or bx == 0x2D else bx)
				ds_or(w, 0x50AD76, 1)
			go_on = 1 if w.ds8(0x50AD76) & 1 else 0
		if go_on != 0:
			for i in 10:
				var grp := 0x16 + i
				if g(w, grp, 2) & 0x30 != 0x30 and Flight.group_alive(w, grp):
					var any := false
					for j in 16:
						var m := g(w, grp, 6 + j)
						if m != 0xFF:
							var f := table_byte(w, 55 * m)
							if f & 8 and table_byte(w, 55 * m + 0xD) and not f & 1 and Pd2World.s8(table_byte(w, 55 * m + 9)) >= 0 \
									and Pd2World.s8(table_byte(w, 55 * m + 10)) >= 0:
								any = true
					if not any:
						set_g(w, grp, 2, g(w, grp, 2) | 0x30)
						Ai.group_retarget(w, grp, M14_FALLBACK[i][0], M14_FALLBACK[i][1])
	if w.ds8(0x50AD4E) & 1:
		var counts := []
		for grp in [0, 2]:
			var n := 0
			for j in 16:
				var m := g(w, grp, 6 + j)
				if m != 0xFF:
					var f := table_byte(w, 55 * m)
					if table_byte(w, 55 * m + 0x36) == 0 and f & 8 and (table_byte(w, 55 * m + 0xD) or not f & 1):
						n += 1
			counts.append(n)
		if counts[0] + counts[1] == 0:
			if not w.ds8(0x50AD76) & 1:
				if w.ds8(0x50AD8C) & 1 and g(w, 3, 2) & 0x30 != 0x30 and g(w, 5, 2) & 0x30 != 0x30:
					var r4 := radio_scene(w, hooks, [["face", 1, 10, null], ["say", 0xAB, 10], ["face", 0xD, 0x2B, 0],
							["face", 3, 0x2B, 1], ["say", 0xAC, 0x2B], ["say", 0xAD, 10], ["close"]])
					if r4:
						return r4
				w.set_ds8(0x50ADF2, 0x82)
				m14_fates(w, rng, 0x82)
				return 0
			var sign0 := [["sign", g(w, 0, 1)]]
			var r5 := radio_scene(w, hooks, [["face", 0x12, 10, null], ["say", 0xB5, 10, sign0], ["say", 0xB6, 10],
					["say", 0xB7, 10], ["close"]])
			if r5:
				return r5
			w.set_ds8(0x50ADF2, 0x80)
			m14_fates(w, rng, 0x80)
			return 0
		if w.ds8(0x50AD76) & 0x3E > 5:
			var grp := 0 if counts[0] else 2
			var sign := [["sign", g(w, grp, 1)]]
			var face := 0xD
			if w.crew[16 + 5] == grp and m12_alive(w, 1):
				face = 10
			elif w.crew[16 * 16 + 5] == grp and m12_alive(w, 16):
				face = 0xB
			var r6 := radio_scene(w, hooks, [["face", 0x12, 10, null], ["say", 0xB5, 10, sign], ["face", face, 0x2B, 0],
					["say", 0xB8, 0x2B, sign], ["say", 0xB6, 10, sign], ["close"]])
			if r6:
				return r6
			w.set_ds8(0x50ADF2, 0x80)
			m14_fates(w, rng, 0x80)
			return 0
	else:
		group_scan(w)
		set_g(w, 0, G_X, w.ds8(0x50AD95))
		set_g(w, 0, G_X + 1, w.ds8(0x50AD97))
		set_g(w, 0, 0x1C, 0)
		set_g(w, 0, 0x22, 0)
		var a := 0x51C840
		for i in 16:
			var m := g(w, 0, 6 + i)
			if m != 0xFF:
				var base := UNITS_ADDR + 55 * m
				w.mem_write(base + 9, w.mem8(a))
				w.mem_write(base + 10, w.mem8(a + 2))
				w.mem_write(base, w.mem8(base) | 8)
				a += 4
		ds_or(w, 0x50AD4E, 1)
	return 0


# --- DASH mission 4 (script 15, DASH chunk 4: the two bridges and their gates; rules.m15_*) -

## gate b: [its hex, its four hexes, its DS:0x50AD68 bit, its bridge's flag, its blown flag, its shut flag]
const M15_GATE := {0: [Vector2i(0x34, 0x28), [Vector2i(0x33, 0x1C), Vector2i(0x34, 0x1C), Vector2i(0x32, 0x1D), Vector2i(0x33, 0x1D)], 0x40, 0x50AD50, 0x50AD64, 0x50AD6E],
		1: [Vector2i(0x13, 0x1C), [Vector2i(0x11, 0x24), Vector2i(0x12, 0x24), Vector2i(0x10, 0x25), Vector2i(0x11, 0x25)], 0x80, 0x50AD52, 0x50AD66, 0x50AD70]}
const M15_CLOSED := [[199, 0x1E], [200, 0x1E], [0xC9, 0x1E], [0xCA, 0x20]]
const M15_OPEN := [[0xBF, 0x1E], [0xC0, 0x20], [0xB8, 0x1E], [0xC3, 0x20]]
const M15_WALLS := [[0x50AD60, 0x40, [[0x33, 0x1B, 0xDD, 0x1E], [0x34, 0x1B, 0xDE, 0x1E]]],
		[0x50AD60, 0x80, [[0x33, 0x1C, 0xDF, 0x1E], [0x34, 0x1C, 0xE0, 0x1E]]],
		[0x50AD61, 0xF, [[0x33, 0x1D, 0xE1, 0x1E], [0x34, 0x1D, 0xE2, 0x1E]]],
		[0x50AD62, 0x40, [[0x11, 0x23, 0xDD, 0x1E], [0x12, 0x23, 0xDE, 0x1E]]],
		[0x50AD62, 0x80, [[0x11, 0x24, 0xDF, 0x1E], [0x12, 0x24, 0xE0, 0x1E]]],
		[0x50AD63, 0xF, [[0x11, 0x25, 0xE1, 0x1E], [0x12, 0x25, 0xE2, 0x1E]]],
		[0x50AD64, 1, [[0x33, 0x27, 0xE4, 0x26], [0x34, 0x27, 0xE5, 0x24], [0x33, 0x28, 0xE6, 0x26], [0x34, 0x28, 0xE7, 0x24],
				[0x35, 0x28, 0xE8, 0x24], [0x33, 0x29, 0xE9, 0x26], [0x34, 0x29, 0xEA, 0x24]]],
		[0x50AD66, 1, [[0x12, 0x1B, 0xE4, 0x26], [0x13, 0x1B, 0xE5, 0x24], [0x12, 0x1C, 0xE6, 0x26], [0x13, 0x1C, 0xE7, 0x24],
				[0x14, 0x1C, 0xE8, 0x24], [0x12, 0x1D, 0xE9, 0x26], [0x13, 0x1D, 0xEA, 0x24]]]]


static func m15_load(w: Pd2World) -> void:
	for c in [[0x51C920, 0x51C930, 16], [0x51C940, 0x51C968, 40], [0x51C990, 0x51C9F0, 96],
			[0x51CA50, 0x51CA70, 28], [0x51CA90, 0x51CAB0, 28], [0x51CAD0, 0x51CAE0, 12]]:
		static_copy(w, c[0], c[1], c[2])


static func m15_init(w: Pd2World) -> int:
	for p in [[0x50AD97, 7], [0x50AD9B, 7], [0x50ADAB, 7], [0x50AD95, 9], [0x50AD99, 0], [0x50AD9D, 0],
			[0x50AD9F, 10], [0x50ADA1, 0], [0x50ADA3, 0xD], [0x50ADA5, 0xE], [0x50ADA7, 5],
			[0x50ADA9, 0xE], [0x50ADAD, 0xE], [0x50ADAF, 9]]:
		w.set_ds16(p[0], p[1])
	for i in 0x20:
		w.ds[0xB1 + i] = w.mem8(0x51C8E8 + i)
		w.ds[0xD1 + i] = w.mem8(0x5242C8 + i)
	set_506651(w, 0x54)
	var t92 := Flight.s16(w.ds16(0x50AD92))
	var n := 0
	for k in 254:
		if w.ub(k, 0x36) == 0 and w.mem8(0x506734 + 16 * w.sb(k, 0xB) + 4) <= t92:
			for p in 6:
				if w.ub(k, 0x1B + 2 * p) == 0xC and w.ub(k, 0x1C + 2 * p) & 0x3F:
					n += 1
	var old := w.mem8(0x5066E0)
	w.mem_write(0x5066E0, old + (0xE - ((n + old) & 0xFF)))
	return 0


static func m15_menu(w: Pd2World, u: int) -> Array:
	var p := Vector2i(w.ub(u, 9), w.ub(u, 10))
	if p == Vector2i(0x13, 0x1C) or p == Vector2i(0x34, 0x28):
		return [1, 0x51CB00]
	if not w.ds8(0x50AD68) & 1:
		return [1, 0x51CAF0]
	return [0, -1]


static func m15_tiles(w: Pd2World, hooks: Hooks, hexes: Array, tiles: Array) -> int:
	for i in hexes.size():
		set_height_tile(w, hexes[i].x, hexes[i].y, tiles[i][0], tiles[i][1])
	for h in hexes:
		var res := hooks.redraw_hex(h.x, h.y)
		if res == 0x10000 or res == 0x20000:
			return res
	return 0


static func m15_line_code(res: int) -> int:
	return {-3: 0x20000, -2: 0x40000, -1: 0x10000}.get(res, 0)


static func m15_command(w: Pd2World, rng: Pd2Random, u: int, hooks: Hooks) -> int:
	var pos := Vector2i(w.ub(u, 9), w.ub(u, 10))
	var gate := -1
	for gk in M15_GATE:
		if M15_GATE[gk][0] == pos:
			gate = gk
	if gate == -1:
		if w.ds8(0x50AD68) & 1:
			return 0
		if w.sb(u, 0xE) > 9:
			w.setb(u, 0xE, (w.ub(u, 0xE) - 10) & 0xFF)
			var r0 := hooks.box(0xBC, [], 0)
			if r0 in AI_ABORT:
				return r0
			if r0 != 1:
				w.setb(u, 0xE, (w.ub(u, 0xE) + 10) & 0xFF)
				return 0
			ds_or(w, 0x50AD68, 1)
			for k in range(27, 31):
				w.setb(k, 0x36, 0)
			return 0
		return m15_line_code(hooks.line(0x1E))
	var gd: Array = M15_GATE[gate]
	var hexes: Array = gd[1]
	var bit: int = gd[2]
	if w.sb(u, 0xE) < 0x14:
		return m15_line_code(hooks.line(0x1E))
	var msg := 0xB8
	if w.ds8(gd[3]) & 1:
		msg = 0xBA
	elif w.ds8(gd[4]) & 1:
		msg = 0xBB
	elif not w.ds8(0x50AD68) & bit:
		var r1 := hooks.box(0xB6, [], 0)
		if r1 in AI_ABORT:
			return r1
		if r1 != 1:
			return 0
		w.setb(u, 0xE, (w.ub(u, 0xE) - 0x14) & 0xFF)
		r1 = m15_tiles(w, hooks, hexes, M15_CLOSED)
		if r1:
			return r1
		ds_or(w, 0x50AD68, bit)
		ds_or(w, gd[5], 0x40)
	else:
		var o := occupant_raw(w, hexes[1].x, hexes[1].y)
		if o != -1:
			var r2 := hooks.line(0xB9, [["machine", table_byte(w, 55 * o + 0xC)]])
			return r2 if r2 in AI_ABORT else 0
		var r3 := hooks.box(0xB7, [], 0)
		if r3 in AI_ABORT:
			return r3
		if r3 != 1:
			return 0
		w.setb(u, 0xE, (w.ub(u, 0xE) - 0x14) & 0xFF)
		r3 = m15_tiles(w, hooks, hexes, M15_OPEN)
		if r3:
			return r3
		w.set_ds8(0x50AD68, w.ds8(0x50AD68) & ~bit & 0xFF)
	var r4 := hooks.line(msg)
	return r4 if r4 in AI_ABORT else 0


static func m15_find(w: Pd2World, x: int, y: int, table: int, base: int) -> int:
	for i in 7:
		if static_s16(w, table + 4 * i) == x and static_s16(w, table + 4 * i + 2) == y:
			return base + i
	return -1


static func m15_ask(hooks: Hooks, msg: int) -> Variant:
	var res := hooks.box(msg, [], 0)
	if res in AI_ABORT:
		return res
	return null if res == 1 else -2


static func m15_bomb_rule(w: Pd2World, u: int, hooks: Hooks) -> int:
	var x := w.sb(u, 9)
	var y := w.sb(u, 10)
	var p := Vector2i(x, y)
	var idx := m15_find(w, x, y, 0x51CA50, 0x19)
	var site := 0
	if idx == -1 or w.ds8(0x50AD50) & 1:
		idx = m15_find(w, x, y, 0x51CA90, 0x12)
		site = 1
		if idx == -1 or w.ds8(0x50AD52) & 1:
			if w.ds8(0x50AD50) & 1:
				if p == Vector2i(0x33, 0x1B):
					return -1 if w.ds8(0x50AD54) & 0x40 else 3
				if p == Vector2i(0x34, 0x1C):
					return -1 if w.ds8(0x50AD54) & 0x80 else 3
				if p == Vector2i(0x33, 0x1D):
					return -1 if w.ds8(0x50AD55) & 0xF else 3
			if w.ds8(0x50AD52) & 1:
				if p == Vector2i(0x11, 0x23):
					return -1 if w.ds8(0x50AD56) & 0x40 else 4
				if p == Vector2i(0x12, 0x24):
					return -1 if w.ds8(0x50AD56) & 0x80 else 4
				if p == Vector2i(0x11, 0x25):
					return -1 if w.ds8(0x50AD57) & 0xF else 4
			if p == Vector2i(0x34, 0x28):
				if not w.ds8(0x50AD58) & 0x41:
					return 5
			elif p == Vector2i(0x13, 0x1C) and not w.ds8(0x50AD5A) & 0x41:
				return 6
			return -1
	var flag_a := 0x50AD4E + 2 * idx
	var state := 0x50AD50 + 2 * site
	var code := 0x15 + site
	var msg := 0xC3
	if not w.ds8(state) & 0x40:
		var r0: Variant = m15_ask(hooks, 0xC0)
		if r0 != null:
			return r0
		ds_or(w, state, 0x40)
		ds_or(w, flag_a, 1)
		return code
	if not w.ds8(state) & 0x80:
		if not w.ds8(flag_a) & 1:
			var r1: Variant = m15_ask(hooks, 0xC1)
			if r1 != null:
				return r1
			ds_or(w, state, 0x80)
			ds_or(w, flag_a, 1)
			return code
	elif w.ds8(state + 1) & 0xF:
		msg = 0xC4
	elif not w.ds8(flag_a) & 1:
		var r2: Variant = m15_ask(hooks, 0xC2)
		if r2 != null:
			return r2
		var r3 := hooks.line(0xC5)
		if r3 in AI_ABORT:
			return r3
		w.set_ds8(state + 1, w.ds8(state + 1) & 0xF1 | 1)
		if site == 1:
			ds_or(w, flag_a, 1)
		return code
	var r4 := hooks.line(msg)
	return r4 if r4 in AI_ABORT else -2


static func m15_walls(w: Pd2World, hooks: Hooks) -> int:
	for i in M15_WALLS.size():
		var e: Array = M15_WALLS[i]
		if not w.ds8(e[0]) & e[1]:
			continue
		for h in e[2]:
			set_height_tile(w, h[0], h[1], h[2], h[3])
		if i == 5:
			w.set_ds8(0x50AD63, w.ds8(0x50AD63) & 0xF1 | 1)
		for h in e[2]:
			var res := hooks.redraw_hex(h[0], h[1])
			if res == 0x10000 or res == 0x20000:
				return res
	return 0


static func m15_bomb(w: Pd2World, rng: Pd2Random, i: int, hooks: Hooks) -> int:
	var p := Vector2i(Pd2World.s8(w.mem8(0x50AC1C + 4 * i)), Pd2World.s8(w.mem8(0x50AC1D + 4 * i)))
	if p == Vector2i(0x33, 0x1B):
		ds_or(w, 0x50AD60, 0x40)
	elif p == Vector2i(0x34, 0x1C):
		ds_or(w, 0x50AD60, 0x80)
	elif p == Vector2i(0x33, 0x1D) and not w.ds8(0x50AD61) & 0xF:
		w.set_ds8(0x50AD61, w.ds8(0x50AD61) & 0xF1 | 1)
	if p == Vector2i(0x11, 0x23):
		ds_or(w, 0x50AD62, 0x40)
	elif p == Vector2i(0x12, 0x24):
		ds_or(w, 0x50AD62, 0x80)
	elif p == Vector2i(0x11, 0x25) and not w.ds8(0x50AD63) & 0xF:
		w.set_ds8(0x50AD63, w.ds8(0x50AD63) & 0xF1 | 1)
	if p == Vector2i(0x34, 0x28):
		ds_or(w, 0x50AD64, 1)
	if p == Vector2i(0x13, 0x1C):
		ds_or(w, 0x50AD66, 1)
	m15_walls(w, hooks)
	return 0


static func m15_blast(w: Pd2World, rng: Pd2Random, b: int, live: int, hooks: Hooks) -> int:
	if live:
		var r0 := hooks.blast_open()
		if r0 in AI_ABORT:
			return r0
		var a := 0x51C940 + 20 * b
		var x0 := static_s16(w, a)
		var y0 := static_s16(w, a + 2)
		r0 = hooks.scroll(x0, y0)
		if r0 in AI_ABORT:
			return r0
		r0 = hooks.blast_start(x0, y0)
		if r0 in AI_ABORT:
			return r0
		var skip := r0 == 0x80000
		var easy := hooks.options & 2 != 0
		for j in 5:
			var x := static_s16(w, a + 4 * j)
			var y := static_s16(w, a + 4 * j + 2)
			var bl := blast(w, hooks, x, y, skip)
			skip = bl[1]
			if bl[0]:
				return bl[0]
			for _i in 2:
				var o := occupant_raw(w, x, y)
				if o != -1:
					var dmg := Fire.fire_damage(w, rng, -1, 12, o, 4, easy)
					if dmg and Fire.apply_hit(w, rng, o, dmg, -1, 12, easy) == "destroyed":
						Action.destroy(w, o)
		var r1 := hooks.blast_close()
		if r1 == 0x10000 or r1 == 0x20000:
			return r1
	for j in 12:
		var a2 := 0x51C990 + 0x30 * b + 4 * j
		var x2 := static_s16(w, a2)
		var y2 := static_s16(w, a2 + 2)
		set_height_tile(w, x2, y2, 0xCB + j, w.mem8(0x51CAD0 + j))
		var r2 := hooks.redraw_hex(x2, y2)
		if r2 == 0x10000 or r2 == 0x20000:
			return r2
	return 0


static func m15_start(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	for b in [0, 1]:
		var gd: Array = M15_GATE[b]
		if not w.ds8(gd[3]) & 1:
			if w.ds8(0x50AD68) & gd[2]:
				var r0 := m15_tiles(w, hooks, gd[1], M15_CLOSED)
				if r0:
					return r0
		else:
			var r1 := m15_blast(w, rng, b, 0, hooks)
			if r1 in AI_ABORT:
				return r1
	var res := m15_walls(w, hooks)
	return res if res == 0x10000 or res == 0x20000 else 0


static func m15_fates(w: Pd2World, rng: Pd2Random, code: int) -> void:
	for k in 40:
		if not (w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4):
			continue
		if w.ub(k, 0) & 1:
			if rng.r16(100) & 1 == 1:
				mark_crew(w, w.ub(k, 0xB), 2)
			elif rng.r16(100) < 0x23:
				mark_crew(w, w.ub(k, 0xB), 1)
		elif code == 0x82 and Flight._machine_class(w, w.sb(k, 0xC)) == 0 and w.ub(k, 0xD) != 100:
			if rng.r16(100) < 0x28:
				mark_crew(w, w.ub(k, 0xB), 1)
				if rng.r16(100) < 0x3C:
					w.setb(k, 0, w.ub(k, 0) | 1)
					w.setb(k, 0xD, 0)


static func m15_code(w: Pd2World) -> int:
	var c := w.ds8(0x50AD68) & 0x3E
	return 0x80 if c == 8 else (0x83 if c else 0x82)


static func m15_end_code(w: Pd2World, rng: Pd2Random) -> int:
	var code := m15_code(w)
	m15_fates(w, rng, code)
	return code


static func m15_lead(w: Pd2World) -> int:
	if not g(w, 0, 5):
		return 0
	var least := 0xFF
	for i in 16:
		least = mini(least, g(w, 0, 6 + i))
	return least


static func m15_call_out(w: Pd2World, b: int, nib: int) -> void:
	if w.ds8(nib) & 0xF:
		return
	var cx := w.ds8(0x50AD95)
	var cy := w.ds8(0x50AD97)
	if b == 0:
		w.set_ds8(0x50ADF1, 2)
		for k in 254:
			if w.sb(k, 0x36) > 2 or w.ub(k, 0) & 8:
				w.setb(k, 7, 0)
				w.setb(k, 8, 0)
		Ai.group_retarget(w, 0x15, cx, cy)
		set_g(w, 0x15, 0x1C, 10)
		Ai.group_retarget(w, 0x16, cx, cy)
		set_g(w, 0x16, 0x1C, 10)
	else:
		for grp in range(20, 64):
			if Flight.group_alive(w, grp) and g(w, grp, 0x21) & 0xF0 == 0xF0:
				for j in 16:
					var m := g(w, grp, 6 + j)
					if m != 0xFF:
						var a := UNITS_ADDR + 55 * m
						w.mem_write(a + 8, 0)
						w.mem_write(a + 7, 0)
						var v := w.mem8(a + 4)
						w.mem_write(a + 4, ((v + 4) ^ v) & 0xF ^ v)
	w.set_ds8(nib, w.ds8(nib) & 0xF1 | 1)


static func m15_pos2(w: Pd2World, grp: int, x: int, y: int) -> void:
	for f in [G_X, G_PREV_X]:
		set_g(w, grp, f, x)
		set_g(w, grp, f + 1, y)


static func m15_word(w: Pd2World, grp: int, v: int) -> void:
	set_g(w, grp, 0x1D, v & 0xFF)
	set_g(w, grp, 0x1E, v >> 8)


static func m15_copy23(w: Pd2World) -> void:
	for grp in [0x18, 0x19, 0x1A]:
		set_g(w, grp, 0x1D, g(w, 0x17, 0x1D))
		set_g(w, grp, 0x1E, g(w, 0x17, 0x1E))


static func m15_turn(w: Pd2World, rng: Pd2Random, stage: int, hooks: Hooks) -> int:
	var cx := w.ds8(0x50AD95)
	var cy := w.ds8(0x50AD97)
	var sign := [["sign", g(w, 0, 1)]]
	if stage == 0:
		w.mission_turn = (w.mission_turn + 1) & 0xFFFF
		if not w.ds8(0x50AD5C) & 1:
			var found := -1
			for grp in range(23, 27):
				if Pd2World.s8(g(w, grp, 0x16)) == Flight.s16(w.ds16(0x50AD95)) + 4:
					found = grp
					break
			if found != -1:
				var lead := m15_lead(w)
				ds_or(w, 0x50AD5C, 1)
				var rr: Variant = hooks.radar_open()
				var r0: int = int(rr) if rr != null else Flight.grid_init(w, hooks.flight, 0)
				if r0 in AI_ABORT:
					return r0
				var gx := Pd2World.s8(g(w, found, 0x16))
				var lf := func() -> int: return face_of(w, rng, lead)
				r0 = radio_scene(w, hooks, [["face", 9, 10, null], ["say", 0xCC, 10, sign], ["face", lf, 0x1B, 0],
						["say", 0xCD, 0x1B, sign], ["say", 0xCE, 10, [gx]], ["say", 0xCF, 0x1B, sign], ["close"]])
				if r0:
					return r0
		if w.ds8(0x50AD5C) & 1 and not w.ds8(0x50AD5E) & 1:
			var all_done := true
			for grp in range(23, 27):
				if g(w, grp, 2) & 0x30 != 0x30:
					all_done = false
			if all_done:
				var lead2 := m15_lead(w)
				ds_or(w, 0x50AD5E, 1)
				var rr2: Variant = hooks.radar_open()
				var r1: int = int(rr2) if rr2 != null else Flight.grid_init(w, hooks.flight, 0)
				if r1 in AI_ABORT:
					return r1
				var lf2 := func() -> int: return face_of(w, rng, lead2)
				r1 = radio_scene(w, hooks, [["face", 9, 10, null], ["say", 0xCC, 10, sign], ["face", lf2, 0x1B, 0],
						["say", 0xD0, 0x1B, sign], ["say", 0xD1, 10, [9]]])
				if r1:
					return r1
				var least := 0x48
				for k in range(27, 31):
					if w.active(k):
						least = mini(least, w.sb(k, 9))
				r1 = radio_scene(w, hooks, [["say", 0xD3 if least < 0x15 else 0xD2, 0x1B, sign], ["close"]])
				if r1:
					return r1
		for gate in [0, 1]:
			var gd: Array = M15_GATE[gate]
			var pos: Vector2i = gd[0]
			if w.ds8(gd[5]) & 0x40 and not w.ds8(0x50AD68) & gd[2] and not w.ds8(gd[3]) & 1:
				var o := occupant_raw(w, pos.x, pos.y)
				if not w.ds8(gd[4]) & 1 and o != -1 and Pd2World.s8(table_byte(w, 55 * o + 0x36)) > 2:
					var r2 := m15_tiles(w, hooks, gd[1], M15_CLOSED)
					if r2:
						return r2
					r2 = hooks.scroll(gd[1][1].x, gd[1][1].y)
					if r2 in AI_ABORT:
						return r2
					ds_or(w, 0x50AD68, gd[2])
				if w.ds8(gd[4]) & 1 or w.ds8(0x50AD68) & gd[2]:
					var table := 0x51CA50 if gate == 0 else 0x51CA90
					for k in 254:
						if w.ub(k, 7) == pos.x and w.ub(k, 8) == pos.y and w.ub(k, 0) & 8:
							var i := rng.r16(7)
							w.setb(k, 7, w.mem8(table + 4 * i))
							w.setb(k, 8, w.mem8(table + 4 * i + 2))
		for b in [0, 1]:
			var bit6 := 0x40 if b == 0 else 0x80
			var limit := 0x27 if b == 0 else 9
			var other: Vector2i = M15_GATE[1 - b][0]
			var gd2: Array = M15_GATE[b]
			if not w.ds8(0x50AD6A) & bit6 and not w.ds8(gd2[3]) & 1 and not w.ds8(0x50AD68) & gd2[2]:
				var near := false
				for k in range(27, 31):
					if w.sb(k, 9) < limit and w.ub(k, 0xD) and not w.ub(k, 0) & 1:
						near = true
				if near:
					var table2 := 0x51CA50 if b == 0 else 0x51CA90
					var n := 0
					for k in 254:
						if w.sb(k, 0x36) > 2 and w.ub(k, 0xD) and not w.ub(k, 0) & 1:
							for i in 7:
								if static_s16(w, table2 + 4 * i) == w.sb(k, 9) and static_s16(w, table2 + 4 * i + 2) == w.sb(k, 10):
									n += 1
					if n > 1:
						var r3 := m15_blast(w, rng, b, 1, hooks)
						if r3 in AI_ABORT:
							return r3
						ds_or(w, gd2[3], 1)
						ds_or(w, 0x50AD6A, bit6)
						for k in range(40, 254):
							if w.ub(k, 7) == other.x and w.ub(k, 8) == other.y and w.ub(k, 0) & 8:
								w.setb(k, 7, 0)
								w.setb(k, 8, 0)
		var r4 := flight_turn(w, rng, hooks)
		if r4 in AI_ABORT:
			return r4
		for b in [0, 1]:
			var bridge: int = 0x50AD50 + 2 * b
			if not w.ds8(bridge) & 1 and w.ds8(bridge + 1) & 0xF == 1:
				var r5 := hooks.scroll(0x34, 0x1C) if b == 0 else hooks.scroll(0x12, 0x24)
				if r5 in AI_ABORT:
					return r5
				r5 = hooks.box(0xBD, [], 0)
				if r5 in AI_ABORT:
					return r5
				if r5 == 1:
					if b == 1:
						ds_or(w, bridge, 1)
					r5 = m15_blast(w, rng, b, 1, hooks)
					if r5 in AI_ABORT:
						return r5
					if b == 0:
						ds_or(w, bridge, 1)
	elif stage == 1:
		for e in [[0x40, 0x17, 0x18, [0x27, 0x26, 0x1F], -1], [0x80, 0x19, 0x1A, [0x29, 0x28, 0x20], 1]]:
			var ga: int = e[1]
			var gb: int = e[2]
			if not w.ds8(0x50AD6C) & e[0] and g(w, ga, G_X) == g(w, ga, G_TARGET_X) and g(w, ga, G_Y) == g(w, ga, G_TARGET_Y) \
					and g(w, gb, G_X) == g(w, gb, G_TARGET_X) and g(w, gb, G_Y) == g(w, gb, G_TARGET_Y):
				for grp in e[3]:
					for f in [G_PREV_X, G_X, G_TARGET_X]:
						set_g(w, grp, f, cx)
					set_g(w, grp, G_TARGET_Y, cy)
				var y: int = (cy + e[4]) & 0xFF
				set_g(w, ga, 2, g(w, ga, 2) | 0x30)
				set_g(w, e[3][2], 0x1C, 0x18)
				set_g(w, e[3][1], 0x1C, 0xC)
				set_g(w, e[3][0], 0x1C, 0x18)
				for grp in e[3]:
					set_g(w, grp, G_PREV_Y, y)
					set_g(w, grp, G_Y, y)
				Ai.group_retarget(w, ga, -1, 0)
				set_g(w, gb, 2, g(w, gb, 2) | 0x30)
				Ai.group_retarget(w, gb, -1, 0)
				ds_or(w, 0x50AD6C, e[0])
		for b in [0, 1]:
			var gd: Array = M15_GATE[b]
			var flag := 0x50AD6E if b == 0 else 0x50AD70
			var nib := flag + 1
			if not w.ds8(flag) & 1:
				if w.ds8(0x50AD68) & gd[2] or w.ds8(gd[3]) & 1:
					m15_call_out(w, b, nib)
					ds_or(w, flag, 1)
				elif w.ds8(flag) & 0x40 and not w.ds8(0x50AD68) & gd[2]:
					m15_call_out(w, b, nib)
					if not w.ds8(gd[4]) & 1:
						for grp in range(20, 64):
							if g(w, grp, 0x21) & 0xF0 != 0xF0:
								continue
							for j in 16:
								var m := g(w, grp, 6 + j)
								if m == 0xFF:
									continue
								var a := UNITS_ADDR + 55 * m
								var f := w.mem8(a)
								var mx := Pd2World.s8(w.mem8(a + 9))
								var my := Pd2World.s8(w.mem8(a + 10))
								if w.mem8(a + 0xD) and not f & 1 and f & 8 and f & 4 and \
										((b == 0 and mx > 0x36 and my > 0x1B) or (b == 1 and my < 0x19)):
									w.mem_write(a + 7, gd[0].x)
									w.mem_write(a + 8, gd[0].y)
			elif not w.ds8(0x50AD68) & gd[2] and not w.ds8(gd[3]) & 1:
				w.set_ds8(flag, w.ds8(flag) & 0xFE)
		for k in range(27, 31):
			if w.sb(k, 9) == 1:
				var r6 := hooks.scroll(1, w.sb(k, 10))
				if r6 in AI_ABORT:
					return r6
				r6 = hooks.line(0xCA)
				if r6 in AI_ABORT:
					return r6
				Action.take_off_map(w, k)
				m12_step(w, 0x50AD68)
	if w.ds8(0x50AD4E) & 1:
		var any := false
		for k in range(27, 31):
			if w.sb(k, 9) >= 0:
				any = true
		if not any:
			w.set_ds8(0x50ADF2, m15_end_code(w, rng))
		var n2 := 0
		for k in 254:
			if k >= 27 and k <= 30:
				if w.ub(k, 0x34) != 0xFF:
					n2 += 1
			elif w.ub(k, 0xD) and w.ub(k, 9) != 0xFF and w.sb(k, 0x36) < 3 and w.ub(k, 0) & 4:
				n2 += 1
		if not n2:
			w.set_ds8(0x50ADF2, m15_end_code(w, rng))
		return 0
	var t := g(w, 0, 0x1F)
	if t == 0 or t == 5:
		m15_pos2(w, 0x24, 10, 7)
		m15_pos2(w, 0x23, 10, 7)
		set_g(w, 0x23, 0x1C, 0x3C)
		set_g(w, 0x24, 0x1C, 0x46)
		if t == 5:
			m15_word(w, 0x17, 10)
			m15_copy23(w)
		else:
			m15_word(w, 0x18, 9)
			m15_word(w, 0x17, 9)
			m15_word(w, 0x1A, 10)
			m15_word(w, 0x19, 10)
	elif t == 1 or t == 6 or t == 4:
		set_g(w, 0x21, 0x1C, 0x28 if t == 4 else 0x32)
		m15_pos2(w, 0x24, 10, 7)
		m15_pos2(w, 0x23, 10, 7)
		set_g(w, 0x23, 0x1C, 0x3C)
		set_g(w, 0x24, 0x1C, 0x50)
	elif t == 2:
		m15_pos2(w, 0x22, 0xE, 7)
		m15_pos2(w, 0x24, 0xC, 7)
		m15_pos2(w, 0x23, 0xC, 7)
		m15_word(w, 0x17, 0x10)
		m15_copy23(w)
	elif t == 3:
		m15_pos2(w, 0x22, 0xE, 7)
		m15_word(w, 0x17, 10)
		m15_copy23(w)
	elif t == 7:
		set_g(w, 0x21, 0x1C, 0x1E)
		m15_pos2(w, 0x24, 10, 7)
		m15_pos2(w, 0x23, 10, 7)
		set_g(w, 0x23, 0x1C, 0x3C)
		set_g(w, 0x24, 0x1C, 0x46)
	set_g(w, 4, 2, g(w, 4, 2) & 0x2F | 0xA0)
	for f in [G_TARGET_X, G_PREV_X, G_X]:
		set_g(w, 4, f, cx)
		set_g(w, 4, f + 1, cy)
	group_scan(w)
	var lead3 := stage
	if g(w, 0, 5):
		lead3 = 0xFF
		for i in 16:
			lead3 = mini(lead3, g(w, 0, 6 + i))
	var rr3: Variant = hooks.radar_open()
	if rr3 == null:
		Flight.grid_init(w, hooks.flight, 0)
	var lf3 := func() -> int: return face_of(w, rng, lead3)
	var r7 := radio_scene(w, hooks, [
			["face", 2, 0x3A, null], ["say", 0xAB, 0x3A], ["face", 9, 0xB, null], ["say", 0xAC, 0xB], ["close"],
			["face", 8, 10, null], ["say", 0xAD, 10], ["face", lf3, 0x1B, 0],
			["face", 0xC, 0x1B, 1], ["say", 0xAE, 0x1B], ["say", 0xAF, 10], ["face", 9, 0x1B, 0],
			["say", 0xB0, 0x1B], ["face", 0xD, 0x1B, 1], ["wait"], ["close"],
			["face", 4, 0x3A, null], ["say", 0xB1, 0x3A], ["close"]])
	if r7:
		return r7
	for j in 4:
		var k := 27 + j
		w.setb(k, 9, w.mem8(0x51C920 + 4 * j))
		w.setb(k, 10, w.mem8(0x51C922 + 4 * j))
		w.setb(k, 0, w.ub(k, 0) | 0xC)
	set_g(w, 0, 2, g(w, 0, 2) & 0xF | 0x20)
	for f in [G_TARGET_X, G_PREV_X, G_X]:
		set_g(w, 0, f, cx)
		set_g(w, 0, f + 1, cy)
	ds_or(w, 0x50AD4E, 0x41)
	return 0
