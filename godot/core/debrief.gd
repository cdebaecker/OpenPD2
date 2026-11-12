class_name Debrief
extends RefCounted
## The end of a mission and the way back to the base, ported from tools/rules.py and checked
## against the game by emulation (verify_debrief): mission_loop's exit (0x436690), the
## scenario command (0x82, table 0x51F038), the debrief 0x48FA40 with its results screen
## 0x495B70, and game_mode_loop's (0x487D70) chain to the next mission. The save image
## (0x4981F0 / 0x4987C0) is DS:0x506638, 0x47BD B: w.head (the campaign mode word,
## DS:0x50663A, the mission turn, the chunk DS:0x50663D, DS:0x506651), w.stock, the crews,
## w.exp0 (record 0's experience counters), the combat records, the 255 units, the 64
## groups, the two timer lists and w.ds.

const AI_ABORT := [0x10000, 0x20000, 0x40000]
const SAVE_BASE := 0x506638
const SAVE_SIZE := 0x47BD
const HEAD_SIZE := 0x1C
const PD2_STEPS := 0x50CC0D          # the mission by step (PD2: 0x50CC17 from step 8; DASH 0x50CC14)
const PD2_STEPS_LATE := 0x50CC17
const DASH_STEPS := 0x50CC14
const AP_THRESHOLDS := 0x50CC11      # grow_ap's thresholds (by crew +9); 0x50CC4C the others
const DASH_SKIP := [0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0]   # DS:0x519020 (dwords by step)
const EXP_ADDR := 0x506B34           # record r's experience counters: EXP_ADDR + 13 r, 5 B


## The debrief's windows and files (rules.DebriefHooks): screen(kind, data) shows a picture
## with its RMES.SLD messages ("clear", "fail", "gameover", "ending", "single": data the ids),
## the results ("results": results_screen's rows), a list ("new_items", "recruits") or a note
## ("recovered", "drop_error", "handover"), 0 or an abort code; load_save(flag) SAVEDATA.ORG's image (pd2\ for 1,
## dash\ for 0); new_campaign(w) 0x421B90 on the loaded save; campaign_set(w) the record
## set of w.campaign (load_campaign_set 0x409240); clear_flag(i) clearinf.bin's byte i.
## disk: USERDISK.ID's third word (0 on the CD).
class Hooks:
	var disk := 0

	func screen(kind: String, data: Variant = null) -> int:
		return 0

	func load_save(flag: int) -> PackedByteArray:
		return PackedByteArray()

	func new_campaign(w: Pd2World) -> int:
		return 0x80

	func campaign_set(w: Pd2World) -> void:
		pass

	func clear_flag(i: int) -> void:
		pass


# --- the save image ----------------------------------------------------------------

static func head_byte(w: Pd2World, o: int) -> int:
	match o:
		2: return w.mode_663a & 0xFF
		3: return w.mission_turn & 0xFF
		4: return (w.mission_turn >> 8) & 0xFF
		0x19: return w.ds_506651 & 0xFF
	return w.head[o] if o < w.head.size() else 0


static func set_head_byte(w: Pd2World, o: int, v: int) -> void:
	v &= 0xFF
	match o:
		2: w.mode_663a = v
		3: w.mission_turn = (w.mission_turn & 0xFF00) | v
		4: w.mission_turn = (w.mission_turn & 0xFF) | (v << 8)
		0x19: w.ds_506651 = v
		_:
			if w.head.size() < HEAD_SIZE:
				w.head.resize(HEAD_SIZE)
			w.head[o] = v


## DS:0x506638 (s16): 1 a campaign, 2 a single mission, 3 (DASH) a mission played again.
static func campaign_mode(w: Pd2World) -> int:
	var v := head_byte(w, 0) | head_byte(w, 1) << 8
	return v - 0x10000 if v >= 0x8000 else v


static func set_campaign_mode(w: Pd2World, v: int) -> void:
	set_head_byte(w, 0, v & 0xFF)
	set_head_byte(w, 1, (v >> 8) & 0xFF)


## DS:0x50663D: the mission's data chunk + 1.
static func chunk(w: Pd2World) -> int:
	return head_byte(w, 5)


## The save image as 0x4981F0 writes it (after "PD2DATA\0").
static func save_image(w: Pd2World) -> PackedByteArray:
	var out := PackedByteArray()
	for o in HEAD_SIZE:
		out.append(head_byte(w, o))
	out.append_array(_sized(w.stock, 0xE0))
	out.append_array(_sized(w.crew, 0x400))
	out.append_array(_sized(w.exp0, 5))
	out.append_array(_sized(w.combat, 0x15A))
	out.append_array(_sized(w.units, 255 * 55))
	out.append_array(_sized(w.groups, 64 * 35))
	out.append_array(_sized(w.bombs, 0x3C))
	out.append_array(_sized(w.sensors, 0xA8))
	out.append_array(_sized(w.ds, 0xF5))
	return out


static func _sized(b: PackedByteArray, n: int) -> PackedByteArray:
	var r := b.slice(0, n)
	r.resize(n)
	return r


## 0x4987C0's effect on the world: every saved part from an image.
static func load_image(w: Pd2World, img: PackedByteArray) -> void:
	var at := func(a: int, n: int) -> PackedByteArray:
		return img.slice(a - SAVE_BASE, a - SAVE_BASE + n)
	w.head = at.call(SAVE_BASE, HEAD_SIZE)
	w.mode_663a = img[2]
	w.mission_turn = img[3] | img[4] << 8
	w.ds_506651 = img[0x19]
	w.stock = at.call(0x506654, 0xE0)
	w.crew = at.call(0x506734, 0x400)
	w.exp0 = at.call(EXP_ADDR, 5)
	w.combat = at.call(0x506B39, 0x15A)
	w.units = at.call(0x506C93, 255 * 55)
	w.n_units = 254
	w.groups = at.call(0x50A35C, 64 * 35)
	w.bombs = at.call(0x50AC1C, 0x3C)
	w.sensors = at.call(0x50AC58, 0xA8)
	w.ds = at.call(0x50AD00, 0xF5)


# --- the mission's end ----------------------------------------------------------------

## mission_loop's exit (LAB_0043688d): 0x99 becomes 0x82; any code but 0xC0 runs the
## mission's end (Mission.mission_end: 0x4373B0, 0x4374C0). 0x80 success, 0x83 success in
## part, 0x82 failure, 0x81 quit to the title.
static func mission_exit(w: Pd2World, code: int) -> int:
	if code == 0x99:
		code = 0x82
	if code != 0xC0:
		Mission.mission_end(w)
	return code


## The command menu's "withdraw" (entry 0xB, WMES 0x1DE answered yes: 0x82): the mission's
## hook from table 0x51F038 (MissionScripts.run_scenario; mission 1's, 0x49A6C0, sets
## DS:0x50ADF2 = 0x80; entry 0 only shows "bad story level"), then the end code
## DS:0x50ADF2 (hooks: the battle's windows, for DASH mission 9's blasts). A mission whose
## hook is not ported: -1.
static func scenario_command(w: Pd2World, script: int, rng: Pd2Random = null, hooks: MissionScripts.Hooks = null) -> int:
	if script != 0:
		var saved := w.script_no
		w.script_no = script
		var ok := MissionScripts.run_scenario(w, rng if rng != null else Pd2Random.new(0), hooks)
		w.script_no = saved
		if not ok:
			return -1
	return mission_exit(w, w.ds8(0x50ADF2))


## grow_ap / grow_attack / grow_aa / grow_cc / grow_defense (0x4710C0 .. 0x471430; ab 0-4).
static func grow_exp(w: Pd2World, c: int, ab: int, amount: int) -> int:
	var rec := Pd2World.s8(w.cb(c, 15))
	if rec < 0:
		return 1
	var a := EXP_ADDR + 13 * rec + ab
	var v := w.mem8(a) + amount
	w.mem_write(a, v if v < 0x100 else 0xFF)
	var table := AP_THRESHOLDS if ab == 0 else 0x50CC4C
	var lv := Pd2World.s8(w.cb(c, 9 + ab))
	if w.mem8(table + lv) <= w.mem8(a):
		w.mem_write(a, 0)
		var n := Pd2World.s8((w.cb(c, 9 + ab) + 1) & 0xFF)
		var cap := 40 if ab == 0 else 10
		w.crew[c * 16 + 9 + ab] = (cap if n > cap else n) & 0xFF
	return w.mem8(a)


static func _crewb(w: Pd2World, c: int, f: int) -> int:
	return w.mem8(0x506734 + 16 * c + f)


## 0x495EA0 / 0x495F00 / 0x495F70: the stock plus what units 0-63 carry (kind 0 machines,
## 1 launchers, 2 rounds) whose crew has +2 <= 2 and +4 up to DS:0x50AD92 (launchers: below).
static func _held(w: Pd2World, kind: int, i: int) -> int:
	var t := w.ds16(0x50AD92)
	var n := 0
	for c in 64:
		var c4 := w.cb(c, 4)
		if (c4 < t if kind == 1 else c4 <= t) and w.cb(c, 2) <= 2:
			if kind == 0:
				n += 1 if w.sb(c, 0xC) == i else 0
			elif kind == 1:
				for j in 6:
					n += 1 if w.sb(c, 0xF + 2 * j) == i else 0
			else:
				for j in 12:
					n += 1 if w.sb(c, 0x1B + 2 * j) == i else 0
	n += w.stock[[0, 0x20, 0x80][kind] + i]
	return 0xFF if n > 0xFF else n


## The restock of item i (rules._refill): x more below x held, else rand() % x + 1 (capped at
## 255); the count over 3 x comes off. Rounds: under 3 x the amount added comes off again.
static func _refill(w: Pd2World, crt: Campaign.CrtRand, kind: int, i: int, x: int) -> void:
	var o: int = [0, 0x20, 0x80][kind] + i
	var st := w.stock[o]
	var add := 0
	if _held(w, kind, i) < x:
		add = x
	else:
		var xd := x
		if x == 0:
			if not w.safe_hit("D2", "debrief restock: restock 0 (the game divides by zero): taken as 1"):
				w.fault = "debrief restock: a record with restock 0 (the game divides by it)"
				return
			xd = 1
		add = crt.next() % xd + 1
	if 0xFF - st < add:
		add = 0xFF - st
	w.stock[o] = (st + add) & 0xFF
	var h := _held(w, kind, i)
	if kind == 2:
		if 3 * x < h:
			add = h - 3 * x
		w.stock[o] = 0 if w.stock[o] < add else (w.stock[o] - add) & 0xFF
	elif 3 * x < h:
		var ex := h - 3 * x
		w.stock[o] = 0 if w.stock[o] < ex else w.stock[o] - ex


static func _less13(w: Pd2World, kind: int, i: int) -> void:
	var o: int = [0, 0x20, 0x80][kind] + i
	var d := _held(w, kind, i) - 13
	w.stock[o] = 0 if w.stock[o] < d else (w.stock[o] - d) & 0xFF


static func _set99(w: Pd2World, i: int) -> void:
	w.stock[0x80 + i] = 0
	w.stock[0x80 + i] = (99 - _held(w, 2, i)) & 0xFF


## 0x495B70, the results screen: one row [crew, +6 & 3, machine, condition, destroyed] per
## crew 0-63 with +4 up to DS:0x50AD92, +2 = 0 and its unit in a group; a hurt crew gets +7
## = random(2) + 1 missions in hospital (1 for crew 22, crew 1 with bit 0, crew 0 with bit 1).
static func results_screen(w: Pd2World, rng: Pd2Random) -> Array:
	var t := w.ds16(0x50AD92)
	var rows := []
	for c in 64:
		var q := c * 16
		if w.crew[q + 4] <= t and w.crew[q + 2] == 0 and w.ub(c, 0) & 4:
			if w.crew[q + 6] & 3:
				if not (w.crew[q + 6] & 1):
					w.crew[q + 7] = 1 if c in [0, 22] else (rng.roll(2) + 1) & 0xFF
				else:
					w.crew[q + 7] = 1 if c in [1, 22] else (rng.roll(2) + 1) & 0xFF
			rows.append([c, w.crew[q + 6] & 3, w.sb(c, 0xC), w.ub(c, 0xD), w.ub(c, 0) & 1])
	return rows


## The unit restore (rules._refit): off the map, not spotted, concealed or reacted, parts
## repaired; a destroyed unit loses its launchers, rounds and machine; others get full
## magazines (written to the pocket numbered like the slot; twice in DASH) moved to pocket
## 6 + slot, pockets 0-5 emptied.
static func _refit(w: Pd2World, k: int, twice: bool) -> void:
	w.setb(k, 0, w.ub(k, 0) & (0xF7 & 0xEF & 0xDF & 0xBF))
	w.setb(k, 1, 0)
	w.setb(k, 2, w.ub(k, 2) & 0xF0)
	if w.ub(k, 0) & 3:
		for j in 6:
			w.setb(k, 0xF + 2 * j, 0xFF)
		for p in 12:
			w.setb(k, 0x1B + 2 * p, 0xFF)
		w.setb(k, 0, w.ub(k, 0) & 0xFC)
		w.setb(k, 0xC, 0xFF)
		return
	for j in 6:
		if w.ub(k, 0xF + 2 * j) != 0xFF:
			w.setb(k, 0x10 + 2 * j, w.ub(k, 0x10 + 2 * j) & 0xCF)
	for _r in (2 if twice else 1):
		for p in 12:
			if w.ub(k, 0x1B + 2 * p) != 0xFF:
				for j in 6:
					if w.ub(k, 0x10 + 2 * j) & 15 == p:
						w.setb(k, 0x1C + 2 * j, w.ammo(w.sb(k, 0x1B + 2 * j), 0) & 0x3F)
						break
	var tmp := []
	var base := 0x506C93 + 55 * k
	for j in 6:
		if w.ub(k, 0xF + 2 * j) == 0xFF:
			tmp.append([0xFF, 0])
		else:
			var b := w.ub(k, 0x10 + 2 * j)
			tmp.append([w.mem8(base + 0x1B + 2 * (b & 15)), w.mem8(base + 0x1C + 2 * (b & 15)) & 0x3F])
			w.setb(k, 0x10 + 2 * j, (b & 0xF0) | (j + 6))
	for j in 6:
		w.setb(k, 0x1B + 2 * (6 + j), tmp[j][0])
		w.setb(k, 0x1C + 2 * (6 + j), tmp[j][1])
	for j in 6:
		w.setb(k, 0x1B + 2 * j, 0xFF)
		w.setb(k, 0x1C + 2 * j, 0)


static func _strip_wrecks(w: Pd2World) -> void:
	for k in mini(w.units.size() / 55, 254):
		if w.ub(k, 0xC) != 0xFF and w.ub(k, 0) & 1:
			for j in 6:
				w.setb(k, 0xF + 2 * j, 0xFF)
			for p in 12:
				w.setb(k, 0x1B + 2 * p, 0xFF)
			w.setb(k, 0xC, 0xFF)


## The campaign's end checks (rules._game_over): -1 to go on, else the message.
static func _game_over(w: Pd2World, step: int, first: int) -> int:
	var msg := -1
	if step > 2:
		var n0 := 0
		var n1 := 0
		for k in 64:
			var c := w.sb(k, 0xB)
			if w.ub(k, 0x36) == 0 and _crewb(w, c, 2) == 0 and _crewb(w, c, 4) <= step:
				if _crewb(w, c, 3) == 0:
					n0 += 1
				else:
					n1 += 1
		if n1 < 3 or n0 < 3:
			msg = first + (1 if n0 > 2 else 0)
	if step > 4:
		var won := 0
		for i in step:
			if w.ds8(0x50AD42 + i):
				won += 1
		if won * 100 / step < 50:
			msg = first + 2
	return msg


## The new step's first stock and the records that come with it (rules._new_items).
static func _new_items(w: Pd2World, step: int, disk: int, dash: bool) -> Array:
	var new := [[], [], []]
	for i in 32:
		if w.stock[i] < w.machine(i, 0x1D) and (not dash or disk or i != 6):
			w.stock[i] = w.machine(i, 0x1D)
		if w.machine(i, 0x1C) == 0 and w.machine(i, 0x1E) == step:
			new[0].append(i)
	for i in 96:
		if w.stock[0x20 + i] < w.launcher(i, 0xF) and (not dash or (disk and i in [6, 7, 0x15])):
			w.stock[0x20 + i] = w.launcher(i, 0xF)
		if w.launcher(i, 0xE) == 0 and w.launcher(i, 0x10) == step:
			new[1].append(i)
	for i in 96:
		if w.stock[0x80 + i] < Pd2World.s8(w.ammo(i, 0xA)) and (disk or not (i in [0xF, 0x10, 0x29])):
			w.stock[0x80 + i] = w.ammo(i, 0xA)
		if w.ammo(i, 9) == 0 and w.ammo(i, 0xB) == step:
			new[2].append(i)
	return new


## The recruits, the groups' end and the hospital (rules._dissolve).
static func _dissolve(w: Pd2World, step: int, dash: bool, hooks: Hooks) -> int:
	var recruits := []
	for c in 64:
		if w.cb(c, 4) == step and w.cb(c, 2) == 0:
			recruits.append(c)
			w.setb(c, 0xB, c)
			w.setb(c, 0x36, 0)
	var res := hooks.screen("recruits", recruits) if not recruits.is_empty() else 0
	if res in AI_ABORT:
		return res
	for g in 12:
		var G := g * 35
		while w.groups[G + 5]:
			var before := w.groups.slice(G + 5, G + 22)
			for i in 16:
				var m := w.groups[G + 6 + i]
				if m != 0xFF:
					Action.group_drop_player(w, g, m)
					w.setb(m, 0, w.ub(m, 0) & 0xFB)
			if w.groups.slice(G + 5, G + 22) == before:
				if w.safe_hit("H7", "debrief: group %d's members do not leave it (the game loops): the group is emptied" % g):
					w.groups[G + 5] = 0
					for i in 16:
						w.groups[G + 6 + i] = 0xFF
				else:
					w.fault = "debrief: a member its unit does not match (the game loops)"
					return 0
	for c in 64:
		if w.cb(c, 4) <= step and w.cb(c, 2) < 3:
			var g := w.cb(c, 5)
			if g != 0xFF:
				if g >= 64:
					w.fault = "debrief: crew %d in group %d" % [c, g]
					return 0
				if Action.group_drop_player(w, g, c) and w.cb(c, 2) == 0:
					res = hooks.screen("drop_error", c)
					if res in AI_ABORT:
						return res
			w.setb(c, 0, w.ub(c, 0) & 0xFB)
	var back := [0, 1, 18] if dash else [1]
	for c in 64:
		var q := c * 16
		if w.crew[q + 4] <= step and w.crew[q + 2] < 3 and (not dash or w.crew[q + 7] != 0xFF) and w.crew[q + 6] & 3:
			w.crew[q + 7] = (w.crew[q + 7] - 1) & 0xFF
			if w.crew[q + 7] == 0 or c in back:
				res = hooks.screen("recovered", [c, w.crew[q + 6] & 2])
				if res in AI_ABORT:
					return res
				w.crew[q + 6] &= 0xFC
				for j in 6:
					w.setb(c, 0xF + 2 * j, 0xFF)
				for p in 12:
					w.setb(c, 0x1B + 2 * p, 0xFF)
	return 0


## PD2's step 8 goes on in DASH (rules._to_dash).
static func _to_dash(w: Pd2World, rng: Pd2Random, hooks: Hooks) -> int:
	w.stash = [w.crew.slice(0, 27 * 16), w.units.slice(0, 27 * 55)]
	w.campaign = 0
	load_image(w, hooks.load_save(0))
	rng.state = w.ds[0x90] | w.ds[0x91] << 8
	convert_exp(w)
	var first := w.mem8(PD2_STEPS + 8)
	w.script_no = first
	set_head_byte(w, 5, first - 10)
	w.set_ds16(0x50AD92, 1)
	w.set_ds16(0x50AD8E, 1)
	w.set_ds8(0x50AD94, 0)
	set_campaign_mode(w, 1)
	var res := hooks.screen("handover", 0)
	if res in AI_ABORT:
		return res
	res = hooks.new_campaign(w)
	if res in AI_ABORT:
		return res
	w.script_no = 12
	w.set_ds16(0x50AD92, 1)
	w.set_ds16(0x50AD8E, 1)
	set_head_byte(w, 5, 2)
	w.set_ds8(0x50AD94, 0)
	set_campaign_mode(w, 1)
	w.campaign = 0
	hooks.campaign_set(w)
	_less13(w, 0, 6)
	for i in [6, 7, 0x15]:
		_less13(w, 1, i)
	for i in [0xF, 0x10, 0x29]:
		_set99(w, i)
	return 0


## DASH's last step: back to PD2's step 8 (rules._to_pd2).
static func _to_pd2(w: Pd2World, hooks: Hooks) -> void:
	w.campaign = 1
	w.set_ds16(0x50AD8E, 8)
	w.set_ds16(0x50AD92, 8)
	w.script_no = 4
	set_head_byte(w, 5, 4)
	var keep := []
	for c in 27:
		keep.append(w.crew.slice(c * 16 + 0xA, c * 16 + 0xE))
	var crews: PackedByteArray = w.stash[0] if w.stash.size() == 2 else PackedByteArray()
	var units: PackedByteArray = w.stash[1] if w.stash.size() == 2 else PackedByteArray()
	crews.resize(27 * 16)
	units.resize(27 * 55)
	for c in 27:
		for f in 16:
			w.crew[c * 16 + f] = crews[c * 16 + f]
		for f in 55:
			w.units[c * 55 + f] = units[c * 55 + f]
		for f in 4:
			w.crew[c * 16 + 0xA + f] = keep[c][f]
	hooks.campaign_set(w)


## 0x48FA40, the debrief (rules.debrief): the step's flag, the results screen, the end
## checks, the next step and its mission, the stock, recruits, groups emptied, hospital,
## units restored, restock, experience, wrecks stripped, the hand-overs between PD2 and
## DASH. random() runs on the save's word DS:0x50AD90. Returns 0x80 (next mission), 0x81
## (to the title) or an abort code.
static func debrief(w: Pd2World, result: int, rng: Pd2Random, crt: Campaign.CrtRand, hooks: Hooks) -> int:
	if w.head.size() < HEAD_SIZE:
		w.head.resize(HEAD_SIZE)
	if w.exp0.size() < 5:
		w.exp0.resize(5)
	if w.combat.size() < 0x15A:
		w.combat.resize(0x15A)
	w.mode_663a = 2
	rng.state = w.ds[0x90] | w.ds[0x91] << 8
	var res := _debrief(w, result, rng, crt, hooks)
	w.ds[0x90] = rng.state & 0xFF
	w.ds[0x91] = (rng.state >> 8) & 0xFF
	return res


static func _debrief(w: Pd2World, result: int, rng: Pd2Random, crt: Campaign.CrtRand, hooks: Hooks) -> int:
	var dash := w.campaign == 0
	var mode := campaign_mode(w)
	var step := w.ds16(0x50AD8E)
	var disk := hooks.disk
	var res := 0
	if not dash:
		if mode == 1:
			if step == 1 and result == 0x82:
				result = 0x80
			var base := chunk(w) * 6
			if result == 0x80 or result == 0x83:
				w.set_ds8(0x50AD41 + step, 1)
				if step == 10:
					w.mode_663a = 3
					hooks.screen("ending", [0x66, 0x67, 0x68, 0x69])
					return 0x81
				var b := base + (0 if result == 0x80 else 2)
				res = hooks.screen("clear", [0x20, 0x21, 0x22, 0x23, 0x24, 0x25] if step == 1 else [b + 0x20, b + 0x21])
				if res in AI_ABORT:
					return res
				hooks.screen("results", results_screen(w, rng))
			elif result == 0x82:
				w.set_ds8(0x50AD41 + step, 0)
				if step == 10:
					hooks.screen("gameover", [base + 0x24])
					return 0x81
				hooks.screen("fail", [])
				hooks.screen("results", results_screen(w, rng))
			var over := _game_over(w, step, 0x42)
			if over != -1:
				hooks.screen("gameover", [over + 0x20])
				return 0x81
			if step < 10:
				step += 1
				var ch := w.mem8((PD2_STEPS if step < 8 else PD2_STEPS_LATE) + step)
				set_head_byte(w, 5, ch)
				w.set_ds16(0x50AD8E, step)
				w.set_ds16(0x50AD92, step)
				w.script_no = ch
				hooks.screen("new_items", _new_items(w, step, disk, false))
				res = _dissolve(w, step, false, hooks)
				if res in AI_ABORT:
					return res
			var t := w.ds16(0x50AD92)
			for k in 64:
				if w.cb(k, 4) <= t and w.cb(k, 2) == 0:
					_refit(w, k, false)
			for i in 32:
				if w.machine(i, 0x1C) == 0 and w.machine(i, 0x1E) <= t:
					_refill(w, crt, 0, i, w.machine(i, 0x1D))
			for i in 96:
				if (disk or not (i in [6, 7, 0x15])) and w.launcher(i, 0xE) == 0 and w.launcher(i, 0x10) <= t:
					_refill(w, crt, 1, i, w.launcher(i, 0xF))
			for i in 96:
				if w.ammo(i, 9) == 0 and w.ammo(i, 0xB) <= t:
					_refill(w, crt, 2, i, Pd2World.s8(w.ammo(i, 0xA)))
			var amount := 30 if result == 0x80 else (10 if result == 0x83 else 0)
			var ap := 9 if result == 0x80 else (3 if result == 0x83 else 0)
			for c in 64:
				if w.cb(c, 4) <= t and w.cb(c, 2) == 0 and w.ub(c, 0) & 4:
					for ab in [1, 2, 3, 4]:
						grow_exp(w, c, ab, amount)
					grow_exp(w, c, 0, ap)
			_strip_wrecks(w)
			w.set_ds8(0x50AD94, 0)
		elif mode == 2:
			hooks.screen("single" if result == 0x80 else "gameover", [])
			hooks.screen("results", results_screen(w, rng))
		if w.ds16(0x50AD8E) == 8 and campaign_mode(w) == 1:
			res = _to_dash(w, rng, hooks)
			if res in AI_ABORT:
				return res
	else:
		if mode == 1 or mode == 3:
			if result == 0x80 or result == 0x83:
				if mode == 1:
					hooks.clear_flag(chunk(w) + 10)
					w.set_ds8(0x50AD41 + step, 1)
					var b := chunk(w) * 6 + (0 if result == 0x80 else 2)
					hooks.screen("clear", [b + 0x20, b + 0x21])
					hooks.screen("results", results_screen(w, rng))
					if step == 10:
						w.mode_663a = 3
						hooks.screen("ending", [])
				else:
					hooks.screen("single", [])
					hooks.screen("results", results_screen(w, rng))
			elif result == 0x82:
				if mode == 1:
					w.set_ds8(0x50AD41 + step, 0)
					if step == 10:
						hooks.screen("gameover", [chunk(w) * 6 + 0x24])
						return 0x81
					hooks.screen("fail", [])
					hooks.screen("results", results_screen(w, rng))
				else:
					hooks.screen("fail", [])
			if mode == 1:
				if step > 2:
					for k in 27:
						w.setb(k, 0x36, 0)
				var over := _game_over(w, step, 0x4E)
				if over != -1:
					hooks.screen("gameover", [over + 0x20])
					return 0x81
			if step < 11:
				var skip: int = DASH_SKIP[step] if step >= 0 and step < DASH_SKIP.size() else w.mem8(0x519020 + 4 * step)
				step += 2 if skip and result == 0x82 and mode != 3 else 1
				w.set_ds16(0x50AD8E, step)
				w.set_ds16(0x50AD92, step)
				var ch := w.mem8(DASH_STEPS + step)
				w.script_no = ch
				set_head_byte(w, 5, ch - 10)
				hooks.screen("new_items", _new_items(w, step, disk, true))
				res = _dissolve(w, step, true, hooks)
				if res in AI_ABORT:
					return res
			var t := w.ds16(0x50AD92)
			for k in 64:
				if w.cb(k, 4) <= t and w.cb(k, 2) == 0:
					_refit(w, k, true)
			for i in 32:
				if w.machine(i, 0x1C) == 0 and w.machine(i, 0x1E) <= t:
					_refill(w, crt, 0, i, w.machine(i, 0x1D))
				if i == 6:
					_less13(w, 0, 6)
			for i in 96:
				if w.launcher(i, 0xE) == 0 and w.launcher(i, 0x10) <= t:
					_refill(w, crt, 1, i, w.launcher(i, 0xF))
				for j in [6, 7, 0x15]:
					_less13(w, 1, j)
			for i in 96:
				if w.ammo(i, 9) == 0 and w.ammo(i, 0xB) <= t:
					_refill(w, crt, 2, i, Pd2World.s8(w.ammo(i, 0xA)))
				if i in [0xF, 0x10, 0x29]:
					for j in [0xF, 0x10, 0x29]:
						_set99(w, j)
			_strip_wrecks(w)
			w.set_ds8(0x50AD94, 0)
			set_campaign_mode(w, 1)
			if w.script_no == 4:
				_to_pd2(w, hooks)
		elif mode == 2:
			if result == 0x80 or result == 0x83:
				if chunk(w) == 3:
					hooks.clear_flag(14)
				hooks.screen("single", [])
			else:
				hooks.screen("gameover", [])
	return 0x80


## game_mode_loop after a debrief that returned 0x80: the next mission while the mode word
## is 1 and DS:0x50AD92 at most 20, [campaign flag, chunk]; else [] (the title).
static func next_mission(w: Pd2World) -> Array:
	if campaign_mode(w) != 1 or w.ds16(0x50AD92) > 20:
		return []
	return [w.campaign, chunk(w)]


## The experience counters converted (rules.convert_exp): each becomes the ability's
## threshold less the counter.
static func convert_exp(w: Pd2World) -> void:
	for c in 64:
		var rec := Pd2World.s8(w.cb(c, 15))
		if rec >= 0:
			var a := EXP_ADDR + 13 * rec
			w.mem_write(a, w.mem8(AP_THRESHOLDS + Pd2World.s8(w.cb(c, 9))) - w.mem8(a))
			for i in range(1, 5):
				w.mem_write(a + i, w.mem8(0x50CC4C + Pd2World.s8(w.cb(c, 9 + i))) - w.mem8(a + i))


## 0x46D780 with "0", the title's new game (rules.new_game): PD2's SAVEDATA.ORG, mode 1,
## step and DS:0x50AD92 1, the counters converted, chunk and mission 1, DS:0x50AD94 = 0,
## crews and units 0-26 kept aside. Returns 1 (game_mode_loop then runs the new campaign).
static func new_game(w: Pd2World, image: PackedByteArray) -> int:
	w.campaign = 1
	load_image(w, image)
	set_campaign_mode(w, 1)
	w.set_ds16(0x50AD8E, 1)
	w.set_ds16(0x50AD92, 1)
	convert_exp(w)
	set_head_byte(w, 5, w.mem8(PD2_STEPS + 1))
	w.set_ds8(0x50AD94, 0)
	w.stash = [w.crew.slice(0, 27 * 16), w.units.slice(0, 27 * 55)]
	w.script_no = 1
	set_head_byte(w, 5, w.script_no)
	return 1
