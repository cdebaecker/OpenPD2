class_name Plan
extends RefCounted
## The briefing (0x4DD2F0), the operation plan (0x443F60, "plan_g.pac") and the loop of the
## mission start 0x416CF0 around them and the sortie screen (rules.briefing, plan_screen,
## pre_battle; emulated by verify_briefing, verify_plan and verify_pre_battle).
##
## 0x416CF0, after the mission load: briefing -> DS:0x50AD94 = 1 -> plan -> sortie, round
## again while its code stays 0 (the sortie's result 2), the briefing and the mission's
## init included. The plan's pages (the mission's hooks A-D, tables 0x51EAE8 / 0x51EB48 /
## 0x51EBA8 / 0x51EC08) only draw; its orders (0x444730) set the player's groups' name
## (+0), plan type (+0x21), time (+0x1D), target (+0x1A / +0x1B) and direction or site
## (+0x1F).

const ABORTS := [0x20000, 0x40000]
const SCENARIO := 0x50DE41
const SITES_A := 0x50ADB1          # a kind-2 plan's sites (eight (x, y) words)
const SITES_B := 0x50ADD1          # a kind-3 plan's
const DEFAULT_REGION := {9: 6, 6: 0, 3: 2}   # an exhausted script presses done / leave / back
const NAMES := 34                  # the group names at DS:0x50C881


## 0x4DD2F0: the mission's SCN_MIS.PCK entry (0x1C6 B) to DS:0x50DE41 (w.scenario), then
## the mission's init and its result; no record (no entry, a failed read): 1 and the
## record left as it was.
static func briefing(w: Pd2World, record: PackedByteArray, hooks: MissionScripts.Hooks = null) -> int:
	if record.is_empty():
		return 1
	if record.size() < 0x1C6:
		w.fault = "briefing: a short SCN_MIS read (part of the record written)"
		return 1
	w.scenario = record.slice(0, 0x1C6)
	return MissionScripts.run_init(w, hooks)


## One round of 0x416CF0's loop: [code, save, reset] from the briefing's, the plan's and the
## sortie's results (0 goes round again; save: savedata.tmp written; reset: DS:0x50AD94
## and the mission turn cleared first).
static func pre_battle_code(brief: int, plan: int, sortie: int) -> Array:
	var code := 0
	if brief <= 0x80:
		if brief == 0x80:
			code = 0x80
		elif brief == 1:
			code = 0x65
	elif brief in [0x10000, 0x20000, 0x40000]:
		code = 0x7F
	if plan in [0x10000, 0x20000, 0x40000]:
		code = 0x7F
	var save := false
	var reset := false
	if sortie <= 0x20000:
		if sortie == 0x20000:
			code = 0x68
		elif sortie == 0 or sortie == 3:
			reset = sortie == 0
			save = true
			code = 0x80
		elif sortie == 1:
			code = 0x81
		elif sortie == -1:
			code = 0x66
	elif sortie == 0x40000:
		code = 0x67
	return [code, save, reset]


## The rounds' effects on the world (rules.pre_battle): DS:0x50663A and the mission turn 0
## at the start, DS:0x50AD94 = 1 after each briefing, and with the sortie's 0 DS:0x50AD94
## and the mission turn 0 again.
static func pre_battle_begin(w: Pd2World) -> void:
	w.mode_663a = 0
	w.mission_turn = 0


static func pre_battle_round(w: Pd2World, brief: int, plan: int, sortie: int) -> Array:
	w.set_ds8(0x50AD94, 1)
	var r := pre_battle_code(brief, plan, sortie)
	if r[2]:
		w.set_ds8(0x50AD94, 0)
		w.mission_turn = 0
	return r


## The plan's windows (rules.PlanHooks): the fades (0x4875D0: -3 / -2 / -1 abort), the
## pages (B's code), the displays (0x446320, 0x446E80, 0x445750: 0 or an abort), the
## objective dialog (0x4DD390: 0 leaves, -100 / -101 / -102), the lists (0x452A10: an
## index, -2 none, -12 / -11), the target pick (0x4459E0: [1, x, y], 0, -2 / -1), the
## site question (0x451E30: 1 yes, -3 / -2 / -1) and the XMS box (0x452200).
class Hooks:
	func fade(_level: int) -> int:
		return 0

	func page(_k: int) -> int:
		return 0

	func show(_g: int) -> int:
		return 0

	func blink() -> int:
		return 0

	func flash(_what: Array) -> int:
		return 0

	func objective(_msg: int) -> int:
		return 0

	func pick(_which: String, _rows: Array) -> int:
		return -2

	func pick_target(x: int, y: int) -> Array:
		return [0, x, y]

	func ask_site() -> int:
		return 1

	func xms() -> int:
		return 0

	func plan_list() -> void:
		pass

	func area_map(_i: int) -> void:
		pass


static func _rec(w: Pd2World, o: int) -> int:
	return w.scenario[o] if o >= 0 and o < w.scenario.size() else 0


static func _rec16(w: Pd2World, o: int) -> int:
	return _rec(w, o) | _rec(w, o + 1) << 8


## the record's entry for plan type t (its low nibble): its offset in w.scenario
static func entry(t: int) -> int:
	return 6 + 0x1C * (t & 15)


## a plan type's kind (entry +0x1A): 0 a target cell, 1 a direction, 2 / 3 a site, else none
static func kind(w: Pd2World, g: int) -> int:
	return _rec(w, entry(Flight.gb(w, g, 0x21)) + 0x1A)


## button 1's list: groups 0-19 with +2 bit 0, the odd ones below 12 left out
static func rows_groups(w: Pd2World) -> Array:
	var out := []
	for h in 20:
		if Flight.gb(w, h, 2) & 1 and (h > 11 or h % 2 == 0):
			out.append(h)
	return out


## button 3's list: the types whose bit (0x8000 >> i) is set in the record's word for the
## group's class (+0: groups 0-5, +2: 6-11, +4: 12 on)
static func rows_types(w: Pd2World, g: int) -> Array:
	var mask := _rec16(w, 0 if g < 6 else 2 if g < 12 else 4)
	var out := []
	for i in 16:
		if mask & (0x8000 >> i):
			out.append(i)
	return out


## the sites of a kind-2 (DS:0x50ADB1) or kind-3 (DS:0x50ADD1) plan: x not -1
static func sites(w: Pd2World, base: int) -> Array:
	var out := []
	for i in 8:
		if w.ds16(base + 4 * i) != -1:
			out.append(i)
	return out


## button 3's pick of type t: +0x21 = entry +0x1B << 4 | t, +0x1D = its first time, then
## by its kind: 0 aims +0x1A / +0x1B at the camera point (DS:0x50AD95's byte, DS:0x50AD97
## less 1 or 1 at 0); 0 and 2 take the first site of DS:0x50ADB1, 3 of DS:0x50ADD1
static func set_type(w: Pd2World, g: int, t: int) -> void:
	var e := entry(t)
	Flight.setgb(w, g, 0x21, ((_rec(w, e + 0x1B) << 4) | t) & 0xFF)
	Flight.setgb(w, g, 0x1D, _rec(w, e + 0x16))
	Flight.setgb(w, g, 0x1E, _rec(w, e + 0x17))
	var k := kind(w, g)
	if k == 0:
		Flight.setgb(w, g, 0x1A, w.ds8(0x50AD95))
		var y := w.ds16(0x50AD97)
		Flight.setgb(w, g, 0x1B, 1 if y == 0 else (y - 1) & 0xFF)
	if k == 0 or k == 2 or k == 3:
		var s := sites(w, SITES_B if k == 3 else SITES_A)
		if not s.is_empty():
			Flight.setgb(w, g, 0x1F, s[0])


## button 4's list: [first, count] of the type's times (count < 0: the game's allocation
## fails and the plan ends with 0x10000)
static func times(w: Pd2World, g: int) -> Array:
	var e := entry(Flight.gb(w, g, 0x21))
	var first := _rec16(w, e + 0x16)
	return [first, _rec16(w, e + 0x18) - first + 1]


static func set_time(w: Pd2World, g: int, t: int) -> void:
	Flight.setgb(w, g, 0x1D, t & 0xFF)
	Flight.setgb(w, g, 0x1E, (t >> 8) & 0xFF)


## the orders' leave (button 0): the mission's objective message (0x51ED28), -1 none
static func objective(w: Pd2World) -> int:
	return MissionScripts.run_objective(w)


## 0x446F50: a site plan's list until one is confirmed (1) or none (0), or an abort
static func _site(w: Pd2World, hooks: Hooks, g: int, base: int) -> int:
	var rows := sites(w, base)
	var r := hooks.blink()
	if r in ABORTS:
		return r
	while true:
		var c := hooks.pick("site", rows)
		if c == -12:
			return 0x20000
		if c == -11:
			return 0x40000
		if c == -2:
			return 0
		if c < 0 or c >= rows.size():      # the game indexes its tables with the answer
			w.fault = "plan site: list answer %d" % c
			return 0x10000
		r = hooks.flash(["site", rows[c]])
		if r in ABORTS:
			return r
		var a := hooks.ask_site()
		if a == 1:
			Flight.setgb(w, g, 0x1F, rows[c])
			return 1
		if a == -3:
			return 0x20000
		if a == -2:
			return 0x40000
		if a == -1:
			return 0x10000
	return 0


static func _pop(regions: Array, n: int) -> int:
	return DEFAULT_REGION[n] if regions.is_empty() else int(regions.pop_front())


## 0x444730, the orders (rules.plan_orders): 1 when left, else the abort
static func orders(w: Pd2World, hooks: Hooks, regions: Array) -> int:
	var g := 0
	var r := hooks.show(0)
	if r in ABORTS:
		return r
	while true:
		var v := _pop(regions, 6)
		if v in ABORTS:
			return v
		var redraw := false
		match v:
			0:
				var m := objective(w)
				var leave := m < 0
				if not leave:
					var a := hooks.objective(m + 0x20)
					if a == -102:
						return 0x20000
					if a == -101:
						return 0x40000
					if a == -100:
						return 0x10000
					leave = a == 0
				if leave:
					return 1
			1:
				var rows := rows_groups(w)
				var c := hooks.pick("group", rows)
				if c == -12:
					return 0x20000
				if c == -11:
					return 0x40000
				if c >= 0 and rows[c] != g:
					g = rows[c]
					redraw = true
			2:
				var c := hooks.pick("name", range(NAMES))
				if c == -12:
					return 0x20000
				if c == -11:
					return 0x40000
				if c >= 0 and c != Flight.gb(w, g, 0):
					Flight.setgb(w, g, 0, c)
					redraw = true
			3:
				var rows := rows_types(w, g)
				if not rows.is_empty():
					var c := hooks.pick("type", rows)
					if c == -12:
						return 0x20000
					if c == -11:
						return 0x40000
					if c >= 0 and rows[c] != Flight.gb(w, g, 0x21) & 15:
						set_type(w, g, rows[c])
						redraw = true
			4:
				var t := times(w, g)
				if t[1] < 0:
					return 0x10000
				if t[1] > 0:
					var c := hooks.pick("time", range(t[0], t[0] + t[1]))
					if c == -12:
						return 0x20000
					if c == -11:
						return 0x40000
					if c >= 0:
						set_time(w, g, t[0] + c)
						redraw = true
			5:
				var k := kind(w, g)
				if k == 0:
					var p := hooks.pick_target(Flight.s8(Flight.gb(w, g, 0x1A)), Flight.s8(Flight.gb(w, g, 0x1B)))
					if p[0] == -2:
						return 0x20000
					if p[0] == -1:
						return 0x40000
					if p[0] == 1:
						Flight.setgb(w, g, 0x1A, p[1] & 0xFF)
						Flight.setgb(w, g, 0x1B, p[2] & 0xFF)
						redraw = true
				elif k == 1:
					r = hooks.blink()
					if r in ABORTS:
						return r
					var c := hooks.pick("direction", range(8))
					if c == -12:
						return 0x20000
					if c == -11:
						return 0x40000
					if c >= 0 and c != Flight.s8(Flight.gb(w, g, 0x1F)):
						r = hooks.flash(["direction", c])
						if r in ABORTS:
							return r
						Flight.setgb(w, g, 0x1F, c)
						r = hooks.show(g)
						if r in ABORTS:
							return r
				elif k == 2 or k == 3:
					r = _site(w, hooks, g, SITES_A if k == 2 else SITES_B)
					if r == 0x10000 or r in ABORTS:
						return r
					redraw = r == 1
		if redraw:
			r = hooks.show(g)
			if r in ABORTS:
				return r
	return 1


## 0x444500, the area maps: 0 the next, 1 the one before (both wrap), 2 back
static func maps(hooks: Hooks, regions: Array) -> int:
	var i := 0
	while true:
		hooks.area_map(i)
		var v := _pop(regions, 3)
		if v in ABORTS:
			return v
		if v == 2:
			return 0
		i = (0 if i == 3 else i + 1) if v == 0 else (3 if i == 0 else i - 1)
	return 0


static func _fade(hooks: Hooks, level: int) -> int:
	return {-3: 0x20000, -2: 0x40000, -1: 0x10000}.get(hooks.fade(level), 0)


## 0x443F60 as its buttons drive it (rules.plan_screen): regions consumed in place; 0 when
## done, else 0x10000 / 0x20000 / 0x40000
static func plan_screen(w: Pd2World, hooks: Hooks, regions: Array) -> int:
	var r := _fade(hooks, 0)
	if r:
		return r
	r = _fade(hooks, 100)
	if r:
		return r
	hooks.page(0)
	while true:
		var v := _pop(regions, 9)
		if v in ABORTS:
			return v
		match v:
			0, 2, 3:
				hooks.page(v)
			1:
				r = hooks.page(1)
				if r:
					return r
			4:
				r = orders(w, hooks, regions)
				if r == 0x10000 or r in ABORTS:
					return r
				hooks.page(0)
			5:
				hooks.plan_list()
			6:
				break
			7:
				r = maps(hooks, regions)
				if r in ABORTS:
					return r
			8:
				r = {-3: 0x20000, -2: 0x40000, -1: 0x10000}.get(hooks.xms(), 0)
				if r:
					return r
	return _fade(hooks, 0)


# --- what the plan's windows show (display only) ---------------------------------------

## the pages' titles (A 状況 situation, B 目的 objective, C 敵兵力 enemy forces, D 味方兵力
## friendly forces), the orders' and the plans' list's (作戦立案, 作戦確認): exe strings
const PAGE_TITLES := [0x50E029, 0x50E032, 0x50E03B, 0x50E046]
const ORDERS_TITLE := 0x50E053
const LIST_TITLE := 0x50E060
const OBJECTIVE_BUTTONS := 0x50E06D     # 無視 (leave anyway) / 再考 (think again)
const DIRECTIONS := 0x50E009            # eight pointers: 北 .. 北西
const SITE_NAMES := 0x50E075            # eight pointers: ALPHA .. HOTEL
const TYPE_NAMES := 0x50C965            # the record entries' +0: 18 pointers
const SITE_QUESTION := 0x514BB8         # the site question ("is this point right?")
## Each mission's pages (its hooks in tables 0x51EAE8 / 0x51EB48 / 0x51EBA8 / 0x51EC08, as
## the emulator ran them): the MES lines in order, -1 where the page waits for a click (its
## blinking map points); null for the three that read the state (page()).
const PAGES := {
	1: [[0x121], [0x124, -1, 0x125, -1, 0x126, 0x127, -1, 0x128, -1, 0x129], [0x122], [0x123]],
	2: [[0x121], [0x126, -1, 0x127, 0x128, 0x129], [0x122, 0x123], [0x124, 0x125]],
	3: [[0x121], [0x124, 0x14C, -1, 0x125, -1, 0x126, 0x127, -1, 0x128, -1, 0x129], [0x122], [0x123]],
	4: [[0x121], [0x125, 0x126, 0x127, 0x128, 0x129], [0x122], [0x123, 0x124]],
	5: [[0x121], [0x124, -1, 0x125], [0x122], [0x123]],
	6: [[0x121], [0x124, 0x125, 0x126, 0x127, 0x128, 0x129], [0x122], [0x123]],
	7: [[0x121], [0x124, -1, 0x125, 0x126, 0x127, -1, 0x128, -1, 0x129], [0x122], [0x123]],
	8: [[0x121], [0x124, -1, 0x125, 0x126], [0x122], [0x123]],
	9: [[0x121], [0x124, 0x125, 0x126, 0x127, 0x128, 0x129], [0x122], [0x123]],
	10: [[0x121], [0x125, -1, 0x126], [0x122], [0x123, 0x124]],
	11: [[0x121, 0x122], [0x126, 0x127, -1, 0x128, -1, 0x129, -1, 0x12A, 0x12B], [0x123, 0x124], [0x125]],
	12: [[0x121], [0x126, 0x127, -1, 0x128], [0x122, 0x123], [0x124, 0x125]],
	13: [[0x121], [0x124, 0x125, -1, 0x126, -1, 0x127], [0x122], [0x123]],
	14: [[0x121], [0x122], [0x123, 0x124, -1, 0x125, -1, 0x126, -1, 0x127], [0x128, 0x129, 0x12A]],
	15: [[0x121], [0x12A, 0x12B, -1, 0x12C, -1, 0x12D, -1, 0x12E], [0x124], [0x127]],
	16: [[0x121], [0x124, 0x126], [0x122, 0x125], [0x123]],
	17: [[0x121, 0x122], [0x125, -1, 0x126, 0x129, 0x12A, 0x12B, 0x12C], [0x123], [0x124]],
	18: [[0x121], [0x124, 0x125, -1, 0x126, -1, 0x127, 0x128, 0x129, 0x12A, -1, 0x12B], [0x122], [0x123]],
	19: [[0x121, 0x122], [0x126, -1, 0x127, 0x128, 0x129], [0x123, 0x124], [0x125]],
	20: [[0x121], [0x124, 0x125, 0x126, -1, 0x127, -1, 0x128, 0x129, -1, 0x12A, -1, 0x12B, -1, 0x12C, 0x12D, 0x12E, -1, 0x12F, 0x130, 0x131], [0x122], [0x123]],
	21: [[0x121, 0x122], [0x12D, 0x12E, 0x12F, 0x130, 0x131], null, null],
	22: [null, [0x12E], [0x125], [0x126]],
}


## A page's lines: [mes id, format args] or [-1] (a wait). m21 C / D count the units 0-39
## of machine 0x1D at +0x36 = 0 (0x4D34A0: the first one's crew +0xB); m22 A counts the
## crews with +2 = 0, +6 bit 0 and +4 not 0x0F / 0xFF, by +3 (0 or not), and names the
## first of each (DS:0x50BCB5, the crew's +0; none: crew -1, the byte before the table).
static func page(w: Pd2World, k: int) -> Array:
	var p: Variant = PAGES.get(w.script_no, [[], [], [], []])[k]
	var out := []
	if p != null:
		for id in p:
			out.append([id, []] if id >= 0 else [-1])
		return out
	if w.script_no == 21:
		var n := 0
		var first := -1
		for u in 40:
			if Flight.ub(w, u, 0x36) == 0 and Flight.ub(w, u, 0xC) == 0x1D:
				if first == -1:
					first = Flight.s8(Flight.ub(w, u, 0xB))
				n += 1
		if k == 2:
			out.append([0x129, []])
			out.append([0x12B, []] if n == 0 else [0x12A, [["crew_of", first]]])
			out.append([0x12C, []])
		else:
			out.append([0x123, []])
			if n:
				out.append([0x124, [n]])
		return out
	var a := 0
	var b := 0
	var fa := -1
	var fb := -1
	for c in 64:
		var q := 0x506734 + 16 * c
		if w.mem8(q + 2) == 0 and w.mem8(q + 6) & 1 and w.mem8(q + 4) != 0x0F and w.mem8(q + 4) != 0xFF:
			if w.mem8(q + 3) == 0:
				if fa == -1:
					fa = c
				a += 1
			else:
				if fb == -1:
					fb = c
				b += 1
	out.append([0x122 if a < 2 else 0x121, [["crew_of", fa]]])
	if b >= 2:
		out.append([0x123, [["crew_of", fb]]])
	elif b == 1:
		out.append([0x124, [["crew_of", fb]]])
	return out


## the given-name index a page names for crew c: its +0 (signed; crew -1 is the byte
## before the crew table, the stock's last)
static func crew_name_id(w: Pd2World, c: int) -> int:
	return Flight.s8(w.mem8(0x506734 + 16 * c))


## 0x446320's requirement lines for group g: the type's three (record entry +1, 7 B each:
## the kind (0xFF none), the test (1 time within, 2 time outside, 3 time equal), two words,
## a direction mask for a kind-1 plan), MES 0x31 + 9 t + 3 j for each that holds
static func requirements(w: Pd2World, g: int) -> Array:
	var t := Flight.gb(w, g, 0x21) & 15
	var e := entry(t) + 1
	var time := Flight.s16(Flight.gb(w, g, 0x1D) | Flight.gb(w, g, 0x1E) << 8)
	var out := []
	for j in 3:
		var r := e + 7 * j
		if _rec(w, r) == 0xFF:
			continue
		var c := _rec(w, r + 1)
		var lo := _rec16(w, r + 2)
		var hi := _rec16(w, r + 4)
		var ok := true
		if c == 1:
			ok = not (time < lo or hi < time)
		elif c == 2:
			ok = not (lo < time and time < hi)
		elif c == 3:
			ok = lo == time
		if kind(w, g) == 1 and _rec(w, r + 6) & (0x80 >> (Flight.gb(w, g, 0x1F) & 0x1F)) == 0:
			ok = false
		if ok:
			out.append(0x31 + 9 * t + 3 * j)
	return out


## 0x4442C0's rows (button 5): the groups 0, 2, .., 10, 12-19 with +2 bit 0
static func list_rows(w: Pd2World) -> Array:
	var out := []
	for g in [0, 2, 4, 6, 8, 10, 12, 13, 14, 15, 16, 17, 18, 19]:
		if Flight.gb(w, g, 2) & 1:
			out.append(g)
	return out
