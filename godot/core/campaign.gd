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
## entry j; 0-8 sort it, ListSort.PICK), its questions (0x451E30: 1 yes, 0 no, -1 / -2 / -3)
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
	var last := -1
	while true:
		var ch := hooks.pick_list(cands, picked)
		if ch == -11:
			return 0x40000
		if ch == -12:
			return 0x20000
		if ch == last and last >= 0 and last <= 8:     # the same sort button again: nothing
			continue
		last = ch
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
		if ch >= 0 and ch <= 8:                         # a sort: the rows move with their marks
			var rows := []
			for i in cands.size():
				rows.append([cands[i], picked[i]])
			_sort_pairs(w, rows, ListSort.PICK, ch)
			for i in rows.size():
				cands[i] = rows[i][0]
				picked[i] = rows[i][1]
			continue
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


## ListSort.sort over [row, mark] pairs, compared by their rows.
static func _sort_pairs(w: Pd2World, rows: Array, table: String, col: int) -> void:
	var n := rows.size()
	for i in n - 1:
		for j in range(i + 1, n):
			if ListSort.cmp(w, table, col, rows[i][0], rows[j][0]) > 0:
				var t: Variant = rows[i]
				rows[i] = rows[j]
				rows[j] = t


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
			var left := {}
			for i in w.crew_pool_n:
				var q: int = w.ds[2 + i]
				if q != 1 and _crew(w, q, 4) == 0 and _crew(w, q, 3) == 0:
					left[q] = true
			if left.size() < 6 - count:            # the game draws on for ever
				w.fault = "new_campaign: too few ground pilots to draw (the game hangs)"
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


# --- the sortie screen (0x45ED60, "hensei_g.pac"; emulated by verify_sortie) -----------

const SCENARIO := 0x50DE41


## The sortie screen's windows (rules.SortieHooks): the mission's deploy check (table
## 0x51EC68: 0 refuses, 0x10000 / -0x20000 / -0x40000 abort, else passes), its message
## dialogs (0x4DD390: -100 / -101 / -102 abort), the refusal notes and the start question
## (0x451E30: 1 yes, 0 no).
class SortieHooks:
	func deploy() -> int:
		return 1

	func dialog(msg: int, arg: Array) -> int:
		return 0

	func note(code: int, arg: int) -> int:
		return 0

	func ask(msg: int) -> int:
		return 1

	## the pilot roster's list (0x452A10): 0-11 sort, 12 + i row i, -2 close
	func roster(rows: Array) -> int:
		return -2

	## the bulk menu's lists: "scope" (3 rows), then "action" (3 or 2 rows); -2 cancel
	func bulk(which: String, n: int) -> int:
		return -2


## 0x46A6D0: the roster's rows -- crews 0-63 with +4 <= DS:0x50AD92, +2 < 3 and +6 bits
## 0-1 clear, in crew order.
static func sortie_roster_rows(w: Pd2World) -> Array:
	var t92 := w.ds16(0x50AD92)
	var out := []
	for c in 64:
		if _crew(w, c, 4) <= t92 and _crew(w, c, 2) < 3 and not _crew(w, c, 6) & 3:
			out.append(c)
	return out


## 0x46A240, the sortie screen's pilot roster (region 0x31; rules.sortie_roster): sorted
## by its headers (the same one twice does nothing); on closing, the free pool and the
## groups' member lists are rewritten in its order (the counts unchanged). Returns -2,
## [crew, 0x40] (a free pilot), [crew, group], or 0x20000 / 0x40000 / -1.
static func sortie_roster(w: Pd2World, hooks: SortieHooks) -> Variant:
	var rows := sortie_roster_rows(w)
	if rows.is_empty():
		var a := hooks.note(0x1CE, 0)
		return 0x20000 if a == -3 else (0x40000 if a == -2 else -1)
	var last := -1
	var pick := -2
	while true:
		var c := hooks.roster(rows)
		if c == -12:
			return 0x20000
		if c == -11:
			return 0x40000
		if c == -1:
			return -1
		if c == last:
			continue
		last = c
		if c == -2:
			break
		if c >= 0 and c < 12:
			ListSort.sort(w, rows, ListSort.ROSTER, c)
			continue
		pick = c - 12
		break
	var counts := PackedByteArray()
	counts.resize(64)
	var n := 0
	for c in rows:
		var g := _crew(w, c, 5)
		if g == 0xFF:
			w.pool_set(n, c)
			n += 1
		elif g >= 64:
			w.fault = "sortie_roster: a crew in group %d" % g
			return -2
		else:
			Flight.setgb(w, g, 6 + counts[g], c)
			counts[g] = (counts[g] + 1) & 0xFF
	if pick == -2:
		return -2
	var crew: int = rows[pick]
	var gg := _crew(w, crew, 5)
	return [crew, 0x40] if gg == 0xFF else [crew, gg]


## 0x462390(air), the sortie screen's bulk menu (regions 0x32 ground / 0x33 air;
## rules.sortie_bulk): a scope (everyone, the selected group, the free pool), an action
## (unequip; unequip and leave; everything back and leave -- the pool's: unequip or
## everything back), then MES 0x1CF; cancelling the action shows the scopes again.
## Returns 1, 2, 3, 0, -2 or 0x20000 / 0x40000 / -1.
static func sortie_bulk(w: Pd2World, hooks: SortieHooks, air: int, sel: int) -> int:
	var ab := {-12: 0x20000, -11: 0x40000, -1: -1}
	var scope := 0
	var act := 0
	while true:
		scope = hooks.bulk("scope", 3)
		if ab.has(scope):
			return ab[scope]
		if scope == -2:
			return -2
		act = hooks.bulk("action", 3 if scope == 0 or scope == 1 else 2)
		if ab.has(act):
			return ab[act]
		if act != -2:
			break
	var a := hooks.ask(0x1CF)
	if a == -3:
		return 0x20000
	if a == -2:
		return 0x40000
	if a == -1:
		return -1
	if a != 1:
		return 0
	var t92 := w.ds16(0x50AD92)
	var res := 0
	if scope == 0 or scope == 1:
		for k in 64:
			var hit := false
			if scope == 0:
				hit = _crew(w, k, 4) <= t92 and _crew(w, k, 2) == 0 and _crew(w, k, 3) == air
			else:
				hit = _crew(w, k, 3) == air and _crew(w, k, 2) == 0 and _crew(w, k, 5) == sel
			if not hit:
				continue
			if act == 0:
				res = 1 if scope == 0 else 2
				_unequip(w, k)
				continue
			res = 1
			if act == 1:
				_unequip(w, k)
			else:
				for _i in (1 if scope == 0 else 6):
					Equipment.free_all(w, k)
			var g := _crew(w, k, 5)
			if g != 0xFF:
				if Action.group_drop_player(w, g, k):
					var r := hooks.note(0x1CE, 0)
					if r == -3:
						return 0x20000
					if r == -2:
						return 0x40000
					if r == -1:
						return -1
				w.setb(k, 0, w.ub(k, 0) & 0xFB)
	else:
		res = 3
		var i := 0
		while i < w.crew_pool_n:
			var c: int = w.ds[2 + i]
			if _crew(w, c, 3) == air and _crew(w, c, 2) == 0:
				if act == 0:
					_unequip(w, c)
				else:
					Equipment.free_all(w, c)
			i += 1
	return res


static func _unequip(w: Pd2World, k: int) -> void:
	for s in 6:
		Equipment.free_slot(w, k, s)
		Equipment.free_pocket(w, k, s)


static func _record(w: Pd2World, o: int) -> int:
	return w.scenario[o] if o < w.scenario.size() else 0


static func _machine(w: Pd2World, k: int) -> int:
	return Flight.s8(Flight.ub(w, k, 0xC))


static func _ammo12(w: Pd2World, k: int) -> int:
	var n := 0
	for p in 12:
		if Flight.s8(Flight.ub(w, k, 0x1B + 2 * p)) == 12:
			n += 1
	return n


static func _arrival(w: Pd2World, g: int) -> int:
	return Flight.s16(Flight.gb(w, g, 0x1D) | Flight.gb(w, g, 0x1E) << 8)


static func _ammo12_sum(w: Pd2World, members: Array) -> int:
	var n := 0
	for m in members:
		n += _ammo12(w, m)
	return n


## The screen's opening (rules.sortie_open): transports 1, 3, .., 11 hand their members to
## the group before them; the free-pilot list is rebuilt.
static func sortie_open(w: Pd2World) -> void:
	var pd2 := w.campaign != 0
	for j in 6:
		var e := 2 * j
		var o := e + 1
		var n := Flight.gb(w, o, 5)
		if n and (pd2 or Flight.gb(w, o, 2) & 1):
			for i in n:
				var m := Flight.gb(w, o, 6 + i)
				var c := Flight.gb(w, e, 5)
				Flight.setgb(w, e, 6 + c, m)
				Flight.setgb(w, e, 5, c + 1)
				w.mem_write(CREWS + 16 * m + 5, e)
			Flight.setgb(w, o, 5, 0)
	var t92 := w.ds16(0x50AD92)
	w.crew_pool_n = 0
	for c in 64:
		if _crew(w, c, 4) <= t92 and _crew(w, c, 2) < 3 and _crew(w, c, 5) == 0xFF and not _crew(w, c, 6) & 3:
			w.pool_set(w.crew_pool_n, c)
			w.crew_pool_n += 1


## The screen's drop (rules.sortie_drop): group_drop_player, then flag bit 2 cleared.
static func sortie_drop(w: Pd2World, g: int, k: int) -> int:
	var res := Action.group_drop_player(w, g, k)
	if res == 0:
		w.setb(k, 0, w.ub(k, 0) & 0xFB)
	return res


## The start button's checks (rules.sortie_check): ["start"], ["refused", code, group],
## ["mission"], ["need", group, i, message] or ["abort", code].
static func sortie_check(w: Pd2World, hooks: SortieHooks) -> Array:
	var pd2 := w.campaign != 0
	var ok := true
	var fail := 0
	var who := 0
	var aborts := {-102: 0x20000, -101: 0x40000, -100: -1}
	if pd2 and _crew(w, 1, 5) == 0xFF:
		fail = 1
		ok = false
	var last: Variant = null
	for g in range(0, 12, 2):
		if not (Flight.gb(w, g, 2) & 1 and Flight.gb(w, g, 3) & 1 and Flight.gb(w, g, 5)):
			continue
		var ground := 0
		var pilots := 0
		for i in Flight.gb(w, g, 5):
			var b := Flight.gb(w, g, 6 + i)
			var c3 := w.mem8(CREWS + 16 * b + 3)
			if c3 == 0:
				ground += w.mem8(MACHS + 31 * _machine(w, b) + 0xA)
			elif c3 == 1:
				last = w.mem8(MACHS + 31 * _machine(w, b) + 9)
				pilots += last
		if pilots < ground:
			fail = 2
			ok = false
			who = g
			break
		if ground != 0 or pilots == 0:
			if last == null:
				w.fault = "sortie_check: reads an unset local (no pilot seen yet)"
				return ["abort", -1]
			if pilots - ground < last:
				continue
		fail = 4
		ok = false
		who = g
		break
	var n0 := 0
	for g in [0, 2, 4]:
		for i in Flight.gb(w, g, 5):
			if Flight._machine_class(w, _machine(w, Flight.gb(w, g, 6 + i))) == 0:
				n0 += 1
	if n0 == 0:
		fail = 3
		ok = false
	var r := hooks.deploy()
	if r == -0x20000 or r == -0x40000:
		return ["abort", -r]
	if r == 0:
		ok = false
		fail = -1
	elif r == 0x10000:
		return ["abort", -1]
	if not pd2:
		var first := 10000
		for g in 6:
			if Flight.gb(w, g, 5) and Flight.gb(w, g, 2) & 1:
				first = mini(first, _arrival(w, g))
		for g in range(12, 20):
			if Flight.gb(w, g, 0x21) & 0xF0 == 0x60 and Flight.gb(w, g, 5) and _arrival(w, g) < first:
				var res := hooks.dialog(0x1E2, ["sign", Flight.gb(w, g, 1)])
				if aborts.has(res):
					return ["abort", aborts[res]]
				ok = false
				fail = -1
	for g in 20:
		if not Flight.gb(w, g, 5):
			continue
		var typ := Flight.gb(w, g, 0x21) & 0xF
		var members := []
		for j in 16:
			if Flight.gb(w, g, 6 + j) != 0xFF:
				members.append(Flight.gb(w, g, 6 + j))
		for i in 3:
			var kind := _record(w, 7 + typ * 0x1C + 7 * i)
			var bad := false
			match kind:
				0:
					bad = true
					for m in members:
						if _machine(w, m) == 10:
							bad = false
				1:
					bad = _ammo12_sum(w, members) <= 2
				2, 8:
					for m in members:
						if not _machine(w, m) in [7, 12]:
							bad = true
				3:
					for m in members:
						if _machine(w, m) != 8:
							bad = true
				4:
					bad = _ammo12_sum(w, members) == 0
				5:
					if Flight.gb(w, g, 0x21) & 0xF:
						var first := 10000
						for h in 20:
							if h != g and Flight.gb(w, h, 5) and not Flight.gb(w, h, 0x21) & 0xF and Flight.gb(w, h, 2) & 1:
								first = mini(first, _arrival(w, h))
						bad = first <= _arrival(w, g)
				6:
					bad = Flight.gb(w, g, 5) > 5
				7:
					bad = _ammo12_sum(w, members) < 10
				9:
					bad = not MissionScripts.table_byte(w, 0x3384 + 0x46 * g) & 1
				10:
					bad = not MissionScripts.table_byte(w, 0x3386 + 0x46 * g)
			if bad:
				var msg := (typ * 3 + 0x11 + i) * 3
				var res := hooks.dialog(msg, ["name", Flight.gb(w, g, 0)])
				if aborts.has(res):
					return ["abort", aborts[res]]
				return ["need", g, i, msg]
	if ok:
		return ["start"]
	if fail == -1:
		return ["mission"]
	hooks.note(fail, who)
	return ["refused", fail, who]


## After "start the operation?" (rules.sortie_start): with yes the transports take their
## pilots, escorts and drop tables place the groups, the mission flags and the explosive
## and sensor lists are cleared; then, whatever the answer, the squad is refitted.
static func sortie_start(w: Pd2World, yes := true) -> void:
	if yes:
		_sortie_split(w)
	_sortie_refit(w)


static func _sortie_split(w: Pd2World) -> void:
	for g in range(0, 12, 2):
		var o := g + 1
		if not Flight.gb(w, g, 3) & 1:
			continue
		for f in [0x1D, 0x1E, 0x1F, 0x21]:
			Flight.setgb(w, o, f, Flight.gb(w, g, f))
		if g >= 6:
			Flight.setgb(w, o, 0x1A, Flight.gb(w, g, 0x1A))
			Flight.setgb(w, o, 0x1B, Flight.gb(w, g, 0x1B))
		var i := 0
		while i < Flight.gb(w, g, 5):
			var b := Flight.gb(w, g, 6 + i)
			if w.mem8(CREWS + 16 * Flight.s8(Flight.ub(w, b, 0xB)) + 3) == 1:
				Action.group_drop_player(w, g, b)
				var c := Flight.gb(w, o, 5)
				Flight.setgb(w, o, 6 + c, b)
				Flight.setgb(w, o, 5, c + 1)
				i = 0
				w.mem_write(CREWS + 16 * b + 5, o)
			else:
				i += 1
	for g in range(12, 18):
		if Flight.gb(w, g, 0x21) & 0xF0 == 0x90 and Flight.gb(w, g, 5):
			Flight.setgb(w, g, 0x1A, MissionScripts.table_byte(w, 0x46 * g + 0x33BE))
			Flight.setgb(w, g, 0x1B, MissionScripts.table_byte(w, 0x46 * g + 0x33BF))
	for g in 20:
		var sel := _record(w, 0x20 + (Flight.gb(w, g, 0x21) & 0xF) * 0x1C)
		if sel != 2 and sel != 3:
			continue
		var base := 0x50ADB1 if sel == 2 else 0x50ADD1
		var idx := Flight.s8(Flight.gb(w, g, 0x1F))
		var t := Flight.gb(w, g, 0x21) & 0xF0
		if t == 0x10 or t == 0x80:
			for j in 16:
				var m := Flight.gb(w, g, 6 + j)
				if m != 0xFF and Flight._machine_class(w, Flight.s8(Flight.ub(w, m, 0xC))) < 2:
					w.mem_write(UNITS + 55 * m + 9, w.mem8(base + 4 * idx))
					w.mem_write(UNITS + 55 * m + 10, w.mem8(base + 4 * idx + 2))
		elif t == 0x60:
			Flight.setgb(w, g, 0x1A, w.ds8(0x50AD95))
			Flight.setgb(w, g, 0x1B, w.ds8(0x50AD97))
			for j in 16:
				var m := Flight.gb(w, g, 6 + j)
				if m != 0xFF:
					w.mem_write(UNITS + 55 * m + 7, w.mem8(base + 4 * idx))
					w.mem_write(UNITS + 55 * m + 8, w.mem8(base + 4 * idx + 2))
	for i in range(0x4E, 0x8E):
		w.ds[i] = 0
	for i in range(0, 0x3C, 4):
		w.bombs[i] = 0xFF
	for i in range(0, 0xA8, 4):
		w.sensors[i] = 0xFF


static func _sortie_refit(w: Pd2World) -> void:
	for g in 20:
		if not Flight.gb(w, g, 5):
			continue
		for j in 16:
			var m := Flight.gb(w, g, 6 + j)
			if m == 0xFF:
				continue
			var base := UNITS + 55 * m
			if m < 0x1B:
				w.mem_write(base + 0xB, m)
			w.mem_write(base + 0xD, w.mem8(MACHS + 31 * Flight.s8(w.mem8(base + 0xC)) + 2))
			for s in 6:
				if w.mem8(base + 0xF + 2 * s) != 0xFF:
					w.mem_write(base + 0x10 + 2 * s, w.mem8(base + 0x10 + 2 * s) & 0xCF)
			for p in 12:
				var am := Flight.s8(w.mem8(base + 0x1B + 2 * p))
				if am != -1:
					w.mem_write(base + 0x1C + 2 * p, w.mem8(Flight.AMMOS + 12 * am) & 0x3F)
			w.mem_write(base + 1, 0)
			w.mem_write(base + 2, w.mem8(base + 2) & 0xF0)
	var t92 := w.ds16(0x50AD92)
	for u in 254:
		var base := UNITS + 55 * u
		if w.mem8(base + 0x36) < 3:
			w.mem_write(base, w.mem8(base) & 0x84)
			w.mem_write(base + 6, 0)
			var c := Flight.s8(w.mem8(base + 0xB))
			if w.mem8(CREWS + 16 * c + 4) <= t92:
				w.mem_write(base + 0x36, 0)
		else:
			w.mem_write(base + 6, 0)
	w.set_ds8(0x50ADF1, 0)


## The screen's loop as its buttons drive it (rules.sortie_screen): sortie_open, then the
## actions ["select", g] (a formable group: the buttons reach 0, 2, .., 10, 12-19),
## ["join", p] (pool row p, 0-7), ["drop", row], ["roster"], ["bulk", air], ["start"]
## (the checks, the question, sortie_start), ["back"]. The pool and member lists scroll
## (sortie_action). Returns [result (0 started, 2 back, or an abort), log].
static func sortie_screen(w: Pd2World, hooks: SortieHooks, actions: Array) -> Array:
	var log := []
	sortie_open(w)
	var st := sortie_state()
	for a in actions:
		var r: Variant = sortie_action(w, hooks, st, a, log)
		if r != null:
			return [r, log]
	return [2, log]


## The screen's state between buttons: the selected group (DS:0x50D745) and the two
## scrolls (the pool's, local_630, and the members', local_634; the layout DS:0x50D741
## stays 1).
static func sortie_state() -> Dictionary:
	return {"sel": 0, "scroll": 0, "mscroll": 0}


## One button of the screen (see sortie_screen). Returns the screen's result when it
## ends, else null.
static func sortie_action(w: Pd2World, hooks: SortieHooks, st: Dictionary, a: Array, log: Array) -> Variant:
	var sel: int = st.sel
	match a[0]:
		"select":
			var g: int = a[1] & ~1 if a[1] < 12 else a[1]
			if Flight.gb(w, g, 2) & 1:
				st.sel = g
				st.mscroll = 0
		"join":
			var i: int = st.scroll + a[1]
			if i < w.crew_pool_n and w.crew_pool_n:
				var r := group_join(w, sel, w.ds[2 + i])
				log.append(["join", sel, r])
				if r == 0 and w.crew_pool_n <= st.scroll:
					st.scroll = 0
		"drop":
			var n := Flight.gb(w, sel, 5)
			var i: int = st.mscroll + a[1]
			if i < n and n:
				var r := sortie_drop(w, sel, Flight.gb(w, sel, 6 + i))
				log.append(["drop", sel, r])
				if r == 0 and Flight.gb(w, sel, 5) <= st.mscroll:
					st.mscroll = 0
		"roster":
			var r: Variant = sortie_roster(w, hooks)
			log.append(["roster", r])
			if r is int and r != -2:
				return r & 0xFFFFFFFF
			st.mscroll = 0
			if r is Array:
				var crew: int = r[0]
				if r[1] == 0x40:
					var idx := -1
					for q in w.crew_pool_n:
						if w.ds[2 + q] == crew:
							idx = q
							break
					if idx < 0:                       # the game then scrolls by a stale cursor
						w.fault = "sortie_roster: a free pilot outside the pool"
						return 2
					var n := w.crew_pool_n
					st.scroll = (0 if n < 4 else n - 4) if n < idx + 4 else idx
				else:
					var g: int = r[1]
					st.sel = g
					var idx := -1
					for q in Flight.gb(w, g, 5):
						if Flight.gb(w, g, 6 + q) == crew:
							idx = q
							break
					if idx < 0:
						w.fault = "sortie_roster: a member outside its group"
						return 2
					var n := Flight.gb(w, g, 5)
					st.mscroll = (0 if n < 4 else n - 4) if n < idx + 4 else idx
		"bulk":
			var r := sortie_bulk(w, hooks, a[1], sel)
			log.append(["bulk", a[1], r])
			if r == 0x20000 or r == 0x40000 or r == -1:
				return r & 0xFFFFFFFF
			if r == 1 or r == 2:
				st.mscroll = 0
		"start":
			var r := sortie_check(w, hooks)
			log.append(["check"] + r)
			if r[0] == "start":
				var yes := hooks.ask(0x1C)
				sortie_start(w, yes == 1)
				if yes == 1:
					return 0
		_:
			return 2
	return null
