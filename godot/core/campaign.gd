class_name Campaign
extends RefCounted
## Starting a campaign and loading a mission, ported from rules.py and checked against the
## game by emulation (verify_group_join, verify_new_campaign): the save image
## (SAVEDATA.ORG), the new campaign's pilot choice and first sortie (0x421B90 with
## 0x422050), a unit joining a player group (0x454690) and the mission load of 0x416CF0.

const AI_ABORT := [0x10000, 0x20000, 0x40000]
const UNITS := 0x506C93
const GROUPS := 0x50A35C
const CREWS := 0x506734
const MACHS := 0x50ADF5
const PICK_COUNT := {1: 5, 0: 11}              # 0x422050: pilots to pick, PD2 / DASH
const PICK_TEXT := {1: {"done": 0x513AF0, "fill": 0x513B00, "full": 0x513B5C, "pick": 0x513B8C, "drop": 0x513B44},
		0: {"done": 0x513B18, "fill": 0x513B2C, "full": 0x513BA8, "pick": 0x513BD8, "drop": 0x513B44}}
const T_PD2_FIRST := 0x5138A0
const T_PD2_GROUP0 := 0x5138D7
const T_PD2_GROUP2 := 0x51390E
const T_DASH_PILOT := 0x513948
const T_DASH_SET := 0x513750
const T_DASH_SET_END := 0x513899


## The C runtime's rand() (0x4F5F90; state DS:0x51FD84, seeded from the clock in 0x48F7A0).
class CrtRand:
	var state: int

	func _init(seed := 0) -> void:
		state = seed & 0xFFFFFFFF

	func next() -> int:
		state = (state * 0x343FD + 0x269EC3) & 0xFFFFFFFF
		return (state >> 16) & 0x7FFF


## The pilot choice's windows (rules.CampaignHooks): the list (0x452A10: -2 done, 9 + j
## entry j; 0-8 sort it, not ported), its questions (0x451E30: 1 yes, 0 no, -1 / -2 / -3)
## and notes (0x452170), named by their string's address.
class Hooks:
	func pick_list(entries: Array, picked: Array) -> int:
		return -2

	func pick_ask(text: int, arg: Variant) -> int:
		return 1

	func pick_note(text: int) -> int:
		return 0


static func _crew(w: Pd2World, c: int, f: int) -> int:
	return w.crew[c * 16 + f]


static func _set_crew(w: Pd2World, c: int, f: int, v: int) -> void:
	w.crew[c * 16 + f] = v & 0xFF


## 0x454690: put player unit k into group g, if its machine fits (rules.group_join).
## Returns the game's code: 0 joined, 1 full, 2-4 / 6-8 refused, 5 joined but not in the
## free-pilot list.
static func group_join(w: Pd2World, g: int, k: int) -> int:
	var m := Flight.s8(Flight.ub(w, k, 0xC))
	if m == -1:
		return 4
	var cat := w.mem8(MACHS + 31 * m) & 0xF
	var n := 0
	var first := 0x40
	if cat >= 2 and cat <= 5:
		for i in Flight.gb(w, g, 5):
			var mm := Flight.gb(w, g, 6 + i)
			if w.mem8(CREWS + 16 * mm + 3) == 1:
				if first == 0x40:
					first = mm
				n += 1
	var other := func() -> bool:
		var fm := Flight.s8(Flight.ub(w, first, 0xC))
		return w.mem8(MACHS + 31 * fm) & 0xF != cat
	var gf := Flight.gb(w, g, 2)
	if cat == 0:
		if gf & 0xE:
			return 2
	elif cat == 1:
		if gf & 0xE != 4:
			return 2
	elif cat == 2 or cat == 3:
		if n == 2:
			return 6
		if not g in [0, 2, 4, 6, 8, 10]:
			return 2
		if n and other.call():
			return 3
		if not Flight.gb(w, g, 3) & 1:
			return 7
		if g > 5 and cat == 3:
			return 8
	elif cat == 4 or cat == 5:
		if n == 2:
			return 6
		if g < 12 or g > 19:
			return 2
		if n and other.call():
			return 3
	var cnt := Flight.gb(w, g, 5)
	if g < 12 or g > 19:
		if cnt == 16:
			return 1
	elif cnt == 2:
		return 1
	Flight.setgb(w, g, 6 + cnt, k)
	Flight.setgb(w, g, 5, cnt + 1)
	w.mem_write(CREWS + 16 * k + 5, g)
	var pn := w.crew_pool_n
	var i := 0
	while i < pn and w.ds[2 + i] != k & 0xFF:
		i += 1
	if i == pn:
		return 5
	for j in range(i, pn - 1):
		w.ds[2 + j] = w.ds[3 + j]
	w.crew_pool_n = pn - 1
	w.mem_write(UNITS + 55 * k, Flight.ub(w, k, 0) | 4)
	return 0


## 0x422950: the pilots offered (PD2 crews 2-15, DASH crews 2-63 with +2 = 0 and +3 = 0),
## each with +4 set to -1 as it is listed.
static func candidates(w: Pd2World) -> Array:
	var out := []
	if w.campaign:
		out = range(2, 16)
	else:
		for c in range(2, 64):
			if _crew(w, c, 2) == 0 and _crew(w, c, 3) == 0:
				out.append(c)
	for c in out:
		_set_crew(w, c, 4, 0xFF)
	return out


## 0x422050, the new campaign's pilot choice (rules.campaign_pick).
static func campaign_pick(w: Pd2World, crt: CrtRand, hooks: Hooks) -> int:
	var pd2 := 1 if w.campaign else 0
	var texts: Dictionary = PICK_TEXT[pd2]
	var need: int = PICK_COUNT[pd2]
	var cands := candidates(w)
	var picked := []
	picked.resize(cands.size())
	picked.fill(false)
	var count := 0
	var codes := {-1: 0x10000, -2: 0x40000, -3: 0x20000}
	while true:
		var ch := hooks.pick_list(cands, picked)
		if ch == -11:
			return 0x40000
		if ch == -12:
			return 0x20000
		var a := 0
		if ch == -2:
			if count == need:
				a = hooks.pick_ask(texts.done, 0xB)
				if a == 1:
					break
			else:
				a = hooks.pick_ask(texts.fill, null)
				if a == 1:
					for _i in need - count:
						var r := 0
						while true:
							r = crt.next() % 0xE
							if not picked[r]:
								break
						picked[r] = true
					break
			if codes.has(a):
				return codes[a]
			continue
		if ch >= 0 and ch <= 8:
			w.fault = "campaign_pick: the list sort (0x4172B0) is not ported"
			return 0
		var j := ch - 9
		if not picked[j]:
			if count == need:
				a = hooks.pick_note(texts.full)
				if codes.has(a):
					return codes[a]
				continue
			a = hooks.pick_ask(texts.pick, null)
			if a == 1:
				picked[j] = true
				count += 1
		else:
			a = hooks.pick_ask(texts.drop, null)
			if a == 1:
				picked[j] = false
				count -= 1
		if codes.has(a):
			return codes[a]
	for idx in cands.size():
		var c: int = cands[idx]
		var ok: bool = c != 0 and picked[idx] and (c <= 15 or not pd2)
		_set_crew(w, c, 4, 0 if ok else 0xFF)
	if pd2:
		var n := 0
		for c in range(2, 16):
			if _crew(w, c, 4) == 0:
				if n > 1:
					_set_crew(w, c, 4, (n + 2) / 2 + 1)
				n += 1
	return 0


static func _template(w: Pd2World, k: int, addr: int) -> void:
	for i in 55:
		w.setb(k, i, w.mem8(addr + i))


## 0x421B90, a new campaign's first sortie (rules.new_campaign). Returns 0x80 or an abort code.
static func new_campaign(w: Pd2World, crt: CrtRand, hooks: Hooks) -> int:
	var pd2 := w.campaign != 0
	if not pd2:
		w.crew_pool_n = 0
		for c in 64:
			if _crew(w, c, 2) < 3 and _crew(w, c, 3) == 0:
				_set_crew(w, c, 4, 0xFF)
	var res := campaign_pick(w, crt, hooks)
	if res in AI_ABORT or w.fault != "":
		return res
	_set_crew(w, 1, 4, 0)
	w.crew_pool_n = 0
	var t92 := w.ds16(0x50AD92)
	for c in 64:
		var ok := false
		if pd2:
			ok = _crew(w, c, 4) <= t92 and _crew(w, c, 2) < 3 and _crew(w, c, 5) == 0xFF
		else:
			ok = _crew(w, c, 4) != 0xFF and _crew(w, c, 2) < 3 and _crew(w, c, 5) == 0xFF
		if ok and not _crew(w, c, 6) & 3:
			w.pool_set(w.crew_pool_n, c)
			w.crew_pool_n += 1
	if pd2:
		_template(w, 1, T_PD2_FIRST)
		w.setb(1, 0xB, 1)
		group_join(w, 0, 1)
	var count := 0
	var placed := false
	for k in 64:
		if pd2:
			if _crew(w, k, 4) <= t92 and _crew(w, k, 2) == 0 and _crew(w, k, 5) == 0xFF:
				if placed:
					_template(w, k, T_PD2_GROUP2)
					w.setb(k, 0xB, k)
					group_join(w, 2, k)
					break
				_template(w, k, T_PD2_GROUP0)
				w.setb(k, 0xB, k)
				group_join(w, 0, k)
				placed = true
		elif _crew(w, k, 4) != 0xFF and _crew(w, k, 2) == 0 and _crew(w, k, 5) == 0xFF:
			if _crew(w, k, 3) == 0:
				if k != 1 and count < 6 and crt.next() % 100 & 1:
					count += 1
					_set_crew(w, k, 4, 3)
			elif _crew(w, k, 3) == 1:
				_template(w, k, T_DASH_PILOT)
				_set_crew(w, k, 4, 3)
			w.setb(k, 0xB, k)
	if not pd2:
		while count < 6:
			if w.crew_pool_n == 0:
				w.fault = "new_campaign: an empty free-pilot list (the game divides by it)"
				return 0
			var b: int = w.ds[2 + crt.next() % w.crew_pool_n]
			if b != 1 and _crew(w, b, 4) == 0 and _crew(w, b, 3) == 0:
				_set_crew(w, b, 4, 3)
				count += 1
		var a := T_DASH_SET
		var b2 := T_DASH_SET
		for k in 64:
			if a > T_DASH_SET_END and b2 > T_DASH_SET_END:
				break
			if _crew(w, k, 4) != 0xFF and _crew(w, k, 2) == 0 and _crew(w, k, 5) == 0xFF:
				if _crew(w, k, 3):
					break
				if _crew(w, k, 4) == 0:
					_template(w, k, a)
					a += 55
				else:
					_template(w, k, b2)
					b2 += 55
				w.setb(k, 0xB, k)
	return 0x80


## 0x416CF0's load of a new mission (rules.mission_load): INIT over units 27-254 and the
## groups, NPC over crews 27-36; chunk 1 keeps groups 0 and 2, others empty the player
## groups with +2 bit 0 and free the crews whose time has come.
static func mission_load(w: Pd2World, chunk: int, init: PackedByteArray, npc: PackedByteArray) -> void:
	var keep := []
	if chunk == 1:
		for g in [0, 2]:
			keep.append(w.groups.slice(35 * g + 5, 35 * g + 22))
	var n := mini(init.size(), 0x39BC)
	for i in mini(n, 228 * 55):
		w.units[27 * 55 + i] = init[i]
	for i in range(228 * 55, n):
		w.groups[i - 228 * 55] = init[i]
	for i in mini(npc.size(), 0xA0):
		w.crew[27 * 16 + i] = npc[i]
	if chunk == 1:
		for j in 2:
			var g: int = [0, 2][j]
			var src: PackedByteArray = keep[j]
			for i in 17:
				w.groups[35 * g + 5 + i] = src[i]
	else:
		for g in 20:
			if w.groups[35 * g + 2] & 1:
				w.groups[35 * g + 5] = 0
				for i in 16:
					w.groups[35 * g + 6 + i] = 0xFF
		var t92 := w.ds16(0x50AD92)
		for c in 64:
			if _crew(w, c, 4) <= t92 and _crew(w, c, 2) == 0:
				_set_crew(w, c, 5, 0xFF)
	w.mode_663a = 0
	w.mission_turn = 0
