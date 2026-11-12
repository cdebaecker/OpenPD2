class_name Pockets
extends RefCounted
## The machine status window's pocket actions (rules.py, emulated): the slot menu
## (ui_slot_picker 0x427530, also behind a weapon picker's magazine column in cmd_fire
## 0x425AF0 and the mine dialog 0x4756A0), the pocket menu (0x427FF0), the pocket picker
## (0x4E95C0), the magazine swaps (0x427930 / 0x427980) and handing over (0x4287A0).
## RULES.md 5.18.

const MAP := 72
const ABORT := [0x10000, 0x20000, 0x40000]
## the menus' actions and their texts (exe 0x514008 ...)
const SWAP := 0
const RELOAD := 1
const HAND_OVER := 2
const DISCARD := 3
const UNEQUIP := 4
const THROW := 5
const SEARCH := 6
const SET := 7
const ACTION_TEXT := {0: 0x514008, 1: 0x514018, 2: 0x514028, 3: 0x514038, 4: 0x514048,
	5: 0x514058, 6: 0x514068, 7: 0x514078}
## the pocket picker's state texts (pointed at by DS:0x51F6A0 / A4 / A8) and colours
const STATE_TEXT := [0x51F6B4, 0x51F6B8, 0x51F6BC]
const STATE_COLOUR := [0xF0, 0x40, 0x43]


## The launcher record byte the game reads: -1 reads machine 31's tail.
static func launcher_rec(w: Pd2World, lid: int, f: int) -> int:
	if lid == -1:
		return w.machine(31, 14 + f)
	if lid < 0 or lid >= 96:
		w.fault = "launcher %d outside the table" % lid
		return 0
	return w.launcher(lid, f)


## The ammo record byte the game reads: -1 reads launcher 95's tail.
static func ammo_rec(w: Pd2World, a: int, f: int) -> int:
	if a < -1 or a >= 96:
		w.fault = "ammo %d outside the table" % a
		return 0
	return w.ammo(a, f)


## 0x4507C0: the AP of handing slot s's launcher over (before the menu's + 1), & 0xFF.
static func slot_hand_ap(w: Pd2World, u: int, s: int) -> int:
	var lid := w.sb(u, 0xF + 2 * s)
	if lid == -1:
		return 0
	var k := w.ub(u, 0x10 + 2 * s) & 15
	var a := w.sb(u, 0x1B + 2 * k)
	var load := ammo_rec(w, a, 6) & 0x1F
	var c := w.ub(u, 0x1C + 2 * k) & 0x3F
	if c & 0x20:
		c -= 64
	var cap := Pd2World.s8(ammo_rec(w, a, 0)) & 0xFFFFFFFF
	if cap == 0:
		if not w.safe_hit("D5", "hand-over AP: round capacity 0, an emptied pocket (the game divides by zero): taken as 1"):
			w.fault = "slot_hand_ap: round capacity 0 (division by zero)"
			return 0
		cap = 1
	var v := (((c * 200) & 0xFFFFFFFF) / cap * load) & 0xFFFFFFFF
	var lb := (v / 100) & 0xFF
	if load < lb:
		lb = load
	var L := launcher_rec(w, lid, 7) & 0x1F
	return ((L - 32 if L & 0x10 else L) + lb) & 0xFF


## ui_slot_picker (0x427530): slot s's menu, [[action, ap]]; picker: from a weapon
## picker's magazine column (only the swaps).
static func slot_menu(w: Pd2World, u: int, s: int, picker: bool) -> Array:
	var man := Ai.manipulator_state(w, u)
	var lid := w.launcher_id(u, s)
	var out := []
	if launcher_rec(w, lid, 9) & 8 and man != 2:
		if w.slot_count(u, s) != 0:
			var a := w.ammo_id(u, s)
			out.append([SWAP, 0 if a == -1 else (ammo_rec(w, a, 7) & 0x1F) * 2])
		out.append([RELOAD, ammo_rec(w, Pd2World.s8(launcher_rec(w, lid, 0xA)), 7) & 0x1F])
	if s >= 2 and man != 2 and not picker:
		out.append([HAND_OVER, slot_hand_ap(w, u, s) + 1])
		out.append([DISCARD, 1])
	elif s < 2 and not picker:
		out.append([UNEQUIP, 1])
	return out


## The pocket menu (0x427FF0): [[action, ap]] for u's pocket p.
static func pocket_menu(w: Pd2World, u: int, p: int) -> Array:
	var a := w.pocket_ammo(u, p)
	var cnt := w.pocket_count(u, p)
	var rel := ammo_rec(w, a, 7) & 0x1F
	var wh8 := ammo_rec(w, a, 8)
	var out := []
	if wh8 & 0x20 and cnt != 0:
		out.append([THROW, rel])
	var wh := wh8 & 15
	if wh == 10 and cnt != 0:
		out.append([SEARCH, rel])
	elif wh == 13 and cnt != 0 and w.pocket_state(u, p) != 2:
		out.append([SET, rel / (2 if w.ucrew(u, 8) >> 1 & 1 else 1)])
	out.append([HAND_OVER, (ammo_rec(w, a, 6) & 0x1F) + 1])
	out.append([DISCARD, 1])
	return out


## ui_pocket_picker (0x4E95C0): the pockets slot s may load from, each with its 0x1D8 row:
## [pocket, ammo, count, ground attack, air attack, recon range, recon pen, -load,
## reload AP, colour, state text address]. Empty: the game says 0x1D9 and returns -2.
static func magazine_rows(w: Pd2World, u: int, s: int) -> Array:
	var rows := []
	for p in Ai.reload_pockets(w, u, s):
		var a := w.pocket_ammo(u, p)
		var st := w.pocket_state(u, p)
		if st == 3:
			w.fault = "pocket picker: state 3 prints a NULL text"
			return rows
		rows.append([p, a, w.pocket_count(u, p), ammo_rec(w, a, 1), ammo_rec(w, a, 2),
			ammo_rec(w, a, 4), ammo_rec(w, a, 5), -(ammo_rec(w, a, 6) & 0x1F),
			ammo_rec(w, a, 7) & 0x1F, STATE_COLOUR[st], STATE_TEXT[st]])
	return rows


## pick_magazine (0x427930) / pick_magazine_reload (0x427980) with the picker's pocket p
## (-2: nothing, 0): slot s feeds from p; the reload clears the pocket it fed from. 1.
static func pick_magazine(w: Pd2World, u: int, s: int, p: int, reload := false) -> int:
	if p == -2:
		return 0
	var old := w.ub(u, 0x10 + 2 * s) & 15
	w.setb(u, 0x10 + 2 * s, (w.ub(u, 0x10 + 2 * s) & 0xF0) | (p & 15))
	if reload:
		w.setb(u, 0x1B + 2 * old, 0xFF)
	return 1


## 0x4287A0's marks: the neighbours u may hand item (slot < 10, pocket item - 10) to for
## ap AP; each gets F bit 1. [Vector2i].
static func hand_over_marks(w: Pd2World, u: int, item: int, ap: int) -> Array:
	var up := w.pos(u)
	var h0 := w.H[up.x + MAP * up.y]
	var out := []
	for d in 6:
		var h := MissionScripts.hex_step(up.x, up.y, d)
		var o := MissionScripts.occupant_raw(w, h.x, h.y)
		if w.fault != "":
			return out
		if o == -1 or w.sb(o, 0x36) != 0 or absi(h0 - w.H[h.x + MAP * h.y]) >= 2 or ap > w.sb(o, 0xE):
			continue
		var ok := false
		if item < 10:
			var lid := w.launcher_id(u, item)
			var mount := launcher_rec(w, lid, 0) | launcher_rec(w, lid, 1) << 8
			var m2 := w.umachine(o, 0xF) | w.umachine(o, 0x10) << 8
			var m3 := w.umachine(o, 0x11) | w.umachine(o, 0x12) << 8
			ok = (w.launcher_id(o, 2) == -1 and mount & m2 != 0) or (w.launcher_id(o, 3) == -1 and mount & m3 != 0)
		else:
			var fed := {}
			for i in 4:
				if w.launcher_id(o, i) != -1:
					fed[w.ub(o, 0x10 + 2 * i) & 15] = true
			var n := 0
			for q in 12:
				if not fed.has(q) and w.pocket_ammo(o, q) != -1:
					n += 1
			ok = n < w.umachine(o, 0x17)
		if ok:
			MissionScripts.set_target_mark(w, h.x, h.y)
			out.append(h)
	return out


## 0x4287A0's transfer of item to o: returns o, or -1 (a pocket item when o has no empty
## pocket). A slot item goes to o's slot 2 when empty, else 3, its round into o's LAST
## empty pocket (pocket 0 when none).
static func hand_over_transfer(w: Pd2World, u: int, item: int, o: int) -> int:
	if item < 10:
		var s := item
		var t := 3 if w.launcher_id(o, 2) != -1 else 2
		w.setb(o, 0xF + 2 * t, w.ub(u, 0xF + 2 * s))
		w.setb(o, 0x10 + 2 * t, (w.ub(o, 0x10 + 2 * t) & 0xCF) | (w.slot_state(u, s) << 4))
		var last := 0
		for q in 12:
			if w.pocket_ammo(o, q) == -1:
				last = q
		w.setb(o, 0x10 + 2 * t, (w.ub(o, 0x10 + 2 * t) & 0xF0) | last)
		var k := w.ub(u, 0x10 + 2 * s) & 15
		w.setb(o, 0x1B + 2 * last, w.ub(u, 0x1B + 2 * k))
		w.setb(o, 0x1C + 2 * last, (w.ub(o, 0x1C + 2 * last) & 0x3F) | (w.ub(u, 0x1C + 2 * k) & 0xC0))
		w.set_slot_count(o, t, w.slot_count(u, s))
		w.setb(u, 0x1B + 2 * k, 0xFF)
		w.set_slot_count(u, s, 0)
		w.setb(u, 0x1C + 2 * k, w.ub(u, 0x1C + 2 * k) & 0x3F)
		w.setb(u, 0xF + 2 * s, 0xFF)
		w.setb(u, 0x10 + 2 * s, w.ub(u, 0x10 + 2 * s) & 0xCF)
		return o
	var p := item - 10
	for q in 12:
		if w.pocket_ammo(o, q) == -1:
			if w.ub(u, 0x1B + 2 * p) < 0x80:          # 0x47CB20 ignores a negative id
				w.setb(o, 0x1B + 2 * q, w.ub(u, 0x1B + 2 * p))
			w.setb(o, 0x1C + 2 * q, w.ub(u, 0x1C + 2 * p))
			w.setb(u, 0x1B + 2 * p, 0xFF)
			return o
	return -1


## What 0x4287A0 asks the player.
class HandHooks extends RefCounted:
	## a hex clicked (Vector2i), null to cancel, or an abort code
	func click() -> Variant:
		return null

	## the 0x1E8 box (ap): 1 = yes
	func ask(ap: int) -> int:
		return 0

	func line(msg: int) -> int:
		return 0


## 0x4287A0 whole (rules.hand_over): the receiving unit or -1; the caller charges ap to both.
static func hand_over(w: Pd2World, u: int, item: int, ap: int, hooks: HandHooks) -> int:
	if hand_over_marks(w, u, item, ap).is_empty():
		var res := hooks.line(0x1E7)
		return res if res in ABORT else -1
	while w.fault == "":
		var h: Variant = hooks.click()
		if h is int and h in ABORT:
			return h
		if h == null or not MissionScripts.target_mark_at(w, h.x, h.y):
			MissionScripts.clear_target_marks(w)
			return -1
		var o := MissionScripts.occupant_raw(w, h.x, h.y)
		if o == -1:
			continue
		var res := hooks.ask(ap)
		if res in ABORT:
			return res
		if res == 1:
			var got := hand_over_transfer(w, u, item, o)
			MissionScripts.clear_target_marks(w)
			return got
	return -1


## What 0x428400 / 0x4284F0 ask: the question msg (0x1B6 discard, 0x1B7 unequip) naming
## the item: kind "launcher" or "ammo", idx its id (1 = yes).
class DiscardHooks extends RefCounted:
	func box(msg: int, kind: String, idx: int) -> int:
		return 0


## 0x428400 (discard) / 0x4284F0 (unequip), one routine (rules.drop_item): yes takes a
## slot's launcher and the pocket it fed from, or clears a pocket. 1 (1 AP), 0, an abort.
static func drop_item(w: Pd2World, u: int, item: int, msg: int, hooks: DiscardHooks) -> int:
	var res: int
	if item < 10:
		res = hooks.box(msg, "launcher", w.launcher_id(u, item))
	else:
		res = hooks.box(msg, "ammo", w.pocket_ammo(u, item - 10))
	if res in ABORT:
		return res
	if res != 1:
		return 0
	if item < 10:
		w.setb(u, 0x1B + 2 * (w.ub(u, 0x10 + 2 * item) & 15), 0xFF)
		if u < 0xFE and item < 6:
			w.setb(u, 0xF + 2 * item, 0xFF)
	else:
		w.setb(u, 0x1B + 2 * (item - 10), 0xFF)
	return 1


## What 0x4285E0 asks: the 0x1C8 prompt (0 search, -2 cancel, other: a look at the map,
## click(), then asked again) and the 0x47E790 window for each computer unit found.
class ReconHooks extends RefCounted:
	func prompt() -> int:
		return 0

	func click() -> int:
		return 0

	func discovered(o: int) -> int:
		return 0


## 0x4285E0, the pocket menu's "recon" (rules.recon_round): step_search in mode 0xC with
## the round's recon range and penetration. 1 when searched, 0, or an abort from a window.
static func recon_round(w: Pd2World, u: int, p: int, hooks: ReconHooks) -> int:
	var a := w.pocket_ammo(u, p)
	var rng_ := 0 if a == -1 else ammo_rec(w, a, 4)
	var pen := 0 if a == -1 else ammo_rec(w, a, 5)
	var up := w.pos(u)
	var smap := Sight.search_map(w, up.x, up.y, rng_, pen)
	if smap == null:
		return 0
	while true:
		var res := hooks.prompt()
		if res in ABORT or res == -2:
			return 0
		if res == 0:
			var side := 3 if w.is_enemy(u) else 0
			for ly in smap.h:
				for lx in smap.w:
					if smap.at(lx, ly) != 0xFF:
						Ai.set_view(w, smap.x0 + lx, smap.y0 + ly, side)
			for o in Sight.spot_in_map(w, u, smap, 8):
				if w.sb(o, 0x36) > 2:
					var r := hooks.discovered(o)
					if r in ABORT:
						return r
			return 1
		if hooks.click() in ABORT:
			return 0
	return 0


## After a recon: u pays ap, the pocket loses a round (low 6 bits), cleared at 0.
static func recon_spend(w: Pd2World, u: int, p: int, ap: int) -> void:
	Ai.spend_ap(w, u, ap)
	w.setb(u, 0x1C + 2 * p, (w.ub(u, 0x1C + 2 * p) & 0xC0) | ((w.pocket_count(u, p) - 1) & 0x3F))
	if w.pocket_count(u, p) == 0:
		w.setb(u, 0x1B + 2 * p, 0xFF)
