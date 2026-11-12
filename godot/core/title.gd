class_name Title
extends RefCounted
## The title's starts (0x46D780) and the saves (rules.title_start and the routines
## around it). game_mode_loop's title (0x487D70): button 0 opens the list at DS:0x50D86C
## (start the campaign, scenario select, rescue mission: 0x46D780 with "0", "2", "3"),
## button 1 is "1", the continue. A save is PD2RECnn.BIN ("PD2DATA\0" and the image,
## 0x4981F0 / 0x4987C0) with MEMBERnn.DAT (DS:0x50CE72 and PD2's kept crews and units,
## 0x40D7A0), slots 0-40.

const TITLE_LIST := 0x523EE0      # the scenario list's missions (kept from one visit to the next)
const SCENARIO_OK := 0x5173C0     # by mission: 1 when the scenario select lists it
const SCENARIO_STEP := 0x5173D8   # by mission: the step its pilot check counts to
const AIR_PILOTS := 0x5173A8      # by mission: the aircraft pilots it needs
const MEMBER_SIZE := 0x77E        # MEMBERnn.DAT: DS:0x50CE72 .. 0x50D5EF
const SLOTS := 41
const TITLE_ABORT := {-3: 0x20000, -2: 0x40000, -1: 0x10000}   # a window's answer -> DS:0x523EF8
const LIST_ABORT := {-12: 0x20000, -11: 0x40000}                # 0x452A10's
const NONE := -0x7FFFFFFF        # pick(): the window failed (0x452A10 returned no pointer)

## DS:0x523EE0 between two visits of the title (bss: it keeps the last scenario list).
static var saved_list := PackedByteArray()


static func magic() -> PackedByteArray:
	var m := "PD2DATA".to_ascii_buffer()
	m.append(0)
	return m


## The title's windows and files (rules.TitleHooks). box(text): 0x452170, a note (an exe
## address, a MES0.SLD id below 0x100, or [address, n] formatted by wsprintfA); its answer,
## below 0 an abort. pick(kind, items): 0x452A10, "scenario" (the missions listed) or
## "data" (0 default data, 1 saved data): the index, -2 cancel, -12 / -11 an abort, NONE.
## savedata_org(flag): SAVEDATA.ORG's bytes (empty: it does not open). saves(): 0x4988B0.
## slot(): 0x498290 (0-40, 0x29 none, below 0 an abort). confirm(slot): 0x498070.
## save_file / member_file(slot): the files' bytes (null: no file). userdisk(): USERDISK.ID
## opens. fade(): 0x4875D0(100). write_tmp(data): savedata.tmp. campaign_set(w):
## load_campaign_set (0x409240). messages(): load_messages.
class Hooks:
	func box(text: Variant) -> int:
		return 0

	func pick(kind: String, items: Array) -> int:
		return -2

	func savedata_org(flag: int) -> Variant:
		return null

	func saves() -> int:
		return 0

	func slot() -> int:
		return 0x29

	func confirm(s: int) -> int:
		return 1

	func save_file(s: int) -> Variant:
		return null

	func member_file(s: int) -> Variant:
		return null

	func userdisk() -> bool:
		return true

	func fade() -> int:
		return 0

	func write_tmp(data: PackedByteArray) -> void:
		pass

	func campaign_set(w: Pd2World) -> void:
		pass

	func messages() -> void:
		pass


## 0x436130 over the image (rules.save_crc): CRC with the polynomial 0x1021, the first two
## bytes as the register; returns the two bytes stored at DS:0x50ADF3 (0 over a good save).
static func save_crc(img: PackedByteArray) -> PackedByteArray:
	var v := img[0] << 8 | img[1]
	for i in range(2, img.size()):
		var b := img[i]
		for k in 8:
			var top := v & 0x8000
			v = ((v << 1) & 0xFFFF) | (b >> 7)
			b = (b << 1) & 0xFF
			if top:
				v ^= 0x1021
	return PackedByteArray([v >> 8, v & 0xFF])


## 0x4981F0 (rules.write_save): DS:0x50ADF3 = the image's CRC; "PD2DATA\0" and the image.
static func write_save(w: Pd2World) -> PackedByteArray:
	w.ds[0xF3] = 0
	w.ds[0xF4] = 0
	var c := save_crc(Debrief.save_image(w))
	w.ds[0xF3] = c[0]
	w.ds[0xF4] = c[1]
	var out := magic()
	out.append_array(Debrief.save_image(w))
	return out


## 0x4987C0 on a file's bytes (rules.read_save; null: it does not open): 1 no file, 2 no
## header, 3 not "PD2DATA\0", 4 not 0x47C5 B; else loaded, the CRC left at DS:0x50ADF3: 5
## when it is not 0, else 0.
static func read_save(w: Pd2World, data: Variant) -> int:
	if data == null:
		return 1
	var d: PackedByteArray = data
	if d.size() < 8:
		return 2
	if d.slice(0, 8) != magic():
		return 3
	if d.size() != 8 + Debrief.SAVE_SIZE:
		return 4
	var img := d.slice(8)
	Debrief.load_image(w, img)
	var c := save_crc(img)
	w.ds[0xF3] = c[0]
	w.ds[0xF4] = c[1]
	return 5 if w.ds[0xF3] else 0


static func _stash(w: Pd2World) -> Array:
	var crews := PackedByteArray()
	var units := PackedByteArray()
	if w.stash.size() == 2:
		crews = (w.stash[0] as PackedByteArray).duplicate()
		units = (w.stash[1] as PackedByteArray).duplicate()
	crews.resize(0x1B0)
	units.resize(27 * 55)
	return [crews, units]


static func _from_stash(w: Pd2World) -> void:
	var s := _stash(w)
	var crews: PackedByteArray = s[0]
	var units: PackedByteArray = s[1]
	for i in 0x1B0:
		w.crew[i] = crews[i]
	for i in 27 * 55:
		w.units[i] = units[i]


## 0x40D7A0 with 0 (rules.member_write): in PD2 crews and units 0-26 kept aside first;
## MEMBERnn.DAT is DS:0x50CE72 and the kept crews and units.
static func member_write(w: Pd2World) -> PackedByteArray:
	if Pd2World.s8(w.script_no & 0xFF) < 11:
		w.stash = [w.crew.slice(0, 27 * 16), w.units.slice(0, 27 * 55)]
	var s := _stash(w)
	var out := PackedByteArray([w.script_no & 0xFF])
	out.append_array(s[0])
	out.append_array(s[1])
	return out


## 0x40D7A0 with 1 (rules.member_read): MEMBERnn.DAT into DS:0x50CE72 and the kept crews
## and units (a short file: what it holds, then -1); the campaign flag 0, or 1 with crews
## and units 0-26 back when the mission is below 11. Returns 0 or -1.
static func member_read(w: Pd2World, data: Variant) -> int:
	if data == null:
		return -1
	var d: PackedByteArray = data
	var n := mini(d.size(), MEMBER_SIZE)
	var s := _stash(w)
	var buf := PackedByteArray([w.script_no & 0xFF])
	buf.append_array(s[0])
	buf.append_array(s[1])
	for i in n:
		buf[i] = d[i]
	w.script_no = buf[0]
	w.stash = [buf.slice(1, 0x1B1), buf.slice(0x1B1, MEMBER_SIZE)]
	if n < MEMBER_SIZE:
		return -1
	w.campaign = 0
	if Pd2World.s8(w.script_no) < 11:
		w.campaign = 1
		_from_stash(w)
	return 0


## 0x4985A0 (the continue's and the sortie's load) or 0x4983A0 (rescue: no MEMBERnn.DAT)
## (rules.load_pick). Returns slot + 1, 0 (none), -1 or an abort.
static func load_pick(w: Pd2World, hooks: Hooks, rescue := false) -> int:
	while true:
		var s := hooks.slot()
		if s < 0:
			return s
		if s == 0x29:
			return 0
		var c := hooks.confirm(s)
		if c < 0:
			return c
		if c != 1:
			continue
		var code := read_save(w, hooks.save_file(s))
		if code == 5 or code == 100:
			var r := hooks.box(9 if code == 5 else (0x519F24 if rescue else 0x519F44))
			return r if r < 0 else -1
		if code:
			var r := hooks.box(0xC if code == 4 else 6)
			return r if r < 0 else 0
		if not rescue and member_read(w, hooks.member_file(s)) == -1:
			return -1
		hooks.messages()
		w.set_ds8(0x50AD94, s + 1)
		return s + 1
	return 0


## 0x4DDBA0 / 0x4DDC10 / 0x4DDC80 (rules._title_held).
static func _held(w: Pd2World, kind: int, i: int) -> int:
	var t := w.ds16(0x50AD92)
	var n := 0
	for c in 64:
		if w.cb(c, 2) < 3 and w.cb(c, 4) <= t:
			if kind == 0:
				n += 1 if w.sb(c, 0xC) == i else 0
			elif kind == 1:
				for j in 6:
					n += 1 if w.ub(c, 0xF + 2 * j) == i else 0
			else:
				for j in 12:
					n += 1 if w.ub(c, 0x1B + 2 * j) == i else 0
	n += w.stock[[0, 0x20, 0x80][kind] + i]
	return 0xFF if n > 0xFF else n


## The scenario select's and the rescue's last pass (rules._title_drop). Returns an abort.
static func _drop(w: Pd2World, hooks: Hooks, text: int) -> int:
	var t := w.ds16(0x50AD8E)
	for c in 64:
		if w.cb(c, 4) <= t and w.cb(c, 2) < 3:
			var g := w.cb(c, 5)
			if g != 0xFF:
				if g >= 64:
					w.fault = "title: crew %d in group %d (past the group table)" % [c, g]
					return 0
				if Action.group_drop_player(w, g, c):
					var r := hooks.box(text)
					if r in TITLE_ABORT:
						return TITLE_ABORT[r]
			w.setb(c, 9, 0xFF)
			w.setb(c, 0, w.ub(c, 0) & 0xFB)
	return 0


static func _list(w: Pd2World, i: int) -> int:
	if i < 0 or i >= 0x18:
		w.fault = "title: the scenario list read at %d (other memory)" % i
		return 0
	return w.title_list[i]


## The scenario select's setup of mission m (rules._scenario_setup).
static func _scenario_setup(w: Pd2World, m: int) -> void:
	w.script_no = m
	var s := w.mem8(SCENARIO_STEP + Pd2World.s8(m))
	var step: int
	if Pd2World.s8(m) < 11:
		w.campaign = 1
		step = s - 10 if s > 0x11 else s
		Debrief.set_head_byte(w, 5, m)
	else:
		w.campaign = 0
		step = s - 7
		Debrief.set_head_byte(w, 5, m - 10)
	w.set_ds16(0x50AD8E, step)
	w.set_ds16(0x50AD92, step)


## 0x4987C0 on SAVEDATA.ORG (rules._org): 0, or after the note its abort (-1 when none).
static func _org(w: Pd2World, hooks: Hooks, flag: int, text: int) -> int:
	var d: Variant = hooks.savedata_org(flag)
	if read_save(w, d):
		var r := hooks.box(text)
		return TITLE_ABORT.get(r, -1)
	return 0


## 0x46D780, the title's start (rules.title_start): entry "0" the new campaign, "1" the
## continue, "2" the scenario select, "3" the rescue mission. Returns [code, abort]: code
## -1 / 0 nothing to start, else the step or mission for game_mode_loop with bit 0x40 (a
## single mission) and 0x80 (a save made in a battle); abort DS:0x523EF8 or 0. Where the
## Python raises (undefined behaviour) w.fault is set.
static func title_start(w: Pd2World, entry: String, hooks: Hooks) -> Array:
	if w.head.size() < Debrief.HEAD_SIZE:
		w.head.resize(Debrief.HEAD_SIZE)
	Debrief.set_head_byte(w, 5, 0)
	w.mode_663a = 0xFF
	if w.title_list.size() < 0x18:
		w.title_list.resize(0x18)
	var ret := 0
	match entry:
		"0":
			var img: Variant = hooks.savedata_org(1)
			w.campaign = 1
			if read_save(w, img):
				var r := hooks.box(0x517448)
				return [0, TITLE_ABORT.get(r, 0)]
			ret = Debrief.new_game(w, (img as PackedByteArray).slice(8))
		"1":
			var s := load_pick(w, hooks)
			if s in TITLE_ABORT:
				return [0, TITLE_ABORT[s]]
			ret = -1
			if s != 0 and member_read(w, hooks.member_file(s - 1)) != -1:
				# local_74 is read here unset (the stack's leftover): taken as not -1
				ret = Pd2World.s8(w.script_no)
				if ret < 11:
					_from_stash(w)
					Debrief.set_head_byte(w, 5, w.script_no)
					if w.ds16(0x50AD8E) > 0x11:
						w.set_ds16(0x50AD8E, w.ds16(0x50AD8E) - 10)
					w.campaign = 1
				else:
					ret -= 10
					w.campaign = 0
					Debrief.set_head_byte(w, 5, ret)
				w.set_ds16(0x50AD92, w.ds16(0x50AD8E))
				if w.mode_663a:
					ret |= 0x80
		"2":
			var res := _scenario(w, hooks)
			if res[2] or w.fault != "":
				return [0, res[1]]
			ret = res[0]
		"3":
			var res := _rescue(w, hooks)
			if res[2] or w.fault != "":
				return [0, res[1]]
			ret = res[0]
		_:
			w.fault = "title entry %s" % entry
			return [0, 0]
	# the end (LAB_0046dab3)
	var mode := Debrief.campaign_mode(w)
	if w.campaign == 0:
		if ret == -1:
			return [0, 0]
		if entry != "1":
			if mode == 2:
				Debrief.set_head_byte(w, 5, w.script_no - 10)
				ret = Pd2World.s8(_list(w, ret)) | ret & 0x80 | 0x40
			elif mode != 3:
				Debrief.set_head_byte(w, 5, w.script_no - 10)
			w.set_ds16(0x50AD92, w.ds16(0x50AD8E))
		if not ret & 0x80:
			if not hooks.userdisk():
				var f := hooks.fade()
				if f in TITLE_ABORT:
					return [0, TITLE_ABORT[f]]
				var b := hooks.box(0x517664)
				if b in TITLE_ABORT:
					return [0, TITLE_ABORT[b]]
				return [1, 0]
			if entry != "1":
				for ki in [[0, 6], [1, 6], [1, 7], [1, 0x15]]:
					var o: int = [0, 0x20, 0x80][ki[0]] + ki[1]
					var d := _held(w, ki[0], ki[1]) - 13
					w.stock[o] = 0 if w.stock[o] < d else (w.stock[o] - d) & 0xFF
				for i in [0xF, 0x10, 0x29]:
					w.stock[0x80 + i] = 0
					w.stock[0x80 + i] = (99 - _held(w, 2, i)) & 0xFF
	else:
		if ret == -1:
			hooks.campaign_set(w)
			return [-1, 0]
		if mode == 2:
			ret = Pd2World.s8(_list(w, ret)) | ret & 0x80 | 0x40
		if w.ds16(0x50AD8E) > 0x11:
			w.set_ds16(0x50AD8E, w.ds16(0x50AD8E) - 10)
		Debrief.set_head_byte(w, 5, w.script_no)
		w.set_ds16(0x50AD92, w.ds16(0x50AD8E))
	if w.fault != "":
		return [0, 0]
	hooks.write_tmp(write_save(w))
	hooks.campaign_set(w)
	return [ret, 0]


## "2", the scenario select: [the list index or -1, abort, stop] (stop: the title returns
## [0, abort] at once).
static func _scenario(w: Pd2World, hooks: Hooks) -> Array:
	var lst := []
	for step in range(1, 0x17):
		var m := w.mem8(Debrief.PD2_STEPS + step)
		if w.mem8(SCENARIO_OK + m):
			w.title_list[lst.size()] = m
			lst.append(m)
	var pick := -1
	var done := false
	while not done:
		var r := hooks.pick("scenario", lst.duplicate())
		if r == NONE:
			return [0, 0x10000, true]
		if r in LIST_ABORT:
			return [0, LIST_ABORT[r], true]
		if r == -2:
			pick = -1
			break
		var m := _list(w, r)
		if w.fault != "":
			return [0, 0, true]
		w.script_no = m
		var dash := Pd2World.s8(m) > 10
		w.campaign = 0 if dash else 1
		pick = r
		if hooks.saves() == 0:
			var a := _org(w, hooks, w.campaign, 0x5174F8)
			if a:
				return [0, maxi(a, 0), true]
			_scenario_setup(w, _list(w, r))
			w.set_ds8(0x50AD94, 0)
			done = true
		else:
			var d := hooks.pick("data", [0x5173A0, 0x5173A4])
			if d == NONE:
				return [0, 0x10000, true]
			if d in LIST_ABORT:
				return [0, LIST_ABORT[d], true]
			if d < 0:
				continue
			if d == 1:
				var s := load_pick(w, hooks)
				if s in TITLE_ABORT:
					return [0, TITLE_ABORT[s], true]
				if s != 0:
					if member_read(w, hooks.member_file(s - 1)) == -1:
						return [0, 0x10000, true]
					var text := -1
					if dash:
						if Pd2World.s8(w.script_no) < 11:
							text = 0x517490
						elif w.mode_663a:
							w.mode_663a = 0xFF
							text = 0x5174AC
					elif Pd2World.s8(w.script_no) > 10:
						text = 0x517474
					elif w.mode_663a:
						w.mode_663a = 0xFF
						text = 0x517458
					if text == -1:
						w.set_ds8(0x50AD94, 0)
						done = true
					else:
						var b := hooks.box(text)
						if b in TITLE_ABORT:
							return [0, TITLE_ABORT[b], true]
					_scenario_setup(w, _list(w, r))
			else:
				var a := _org(w, hooks, w.campaign, 0x5174D8)
				if a:
					return [0, maxi(a, 0), true]
				_scenario_setup(w, _list(w, r))
				w.set_ds8(0x50AD94, 0)
				done = true
		var need := w.mem8(AIR_PILOTS + Pd2World.s8(_list(w, r)))
		if need:
			var t := w.ds16(0x50AD92)
			var n := 0
			for c in 64:
				if w.cb(c, 2) == 0 and w.cb(c, 4) <= t and w.cb(c, 3):
					n += 1
			if n < need:
				done = false
				for text in [[0x517508, need], [0x517534, n]]:
					var b := hooks.box(text)
					if b in TITLE_ABORT:
						return [0, TITLE_ABORT[b], true]
	if pick != -1:
		Debrief.set_campaign_mode(w, 2)
		var m := Pd2World.s8(_list(w, pick))
		var step := 1
		while step < 0x17 and w.mem8(Debrief.PD2_STEPS + step) != m:
			step += 1
		if not w.campaign:
			step -= 7
		w.set_ds16(0x50AD8E, step)
		var a := _drop(w, hooks, 0x517560)
		if a:
			return [0, a, true]
		w.set_ds8(0x50AD94, 0)
	return [pick, 0, false]


## "3", the rescue mission: [the step, abort, stop] (stop: the title returns [0, abort]).
static func _rescue(w: Pd2World, hooks: Hooks) -> Array:
	while true:
		w.mode_663a = 0xFF
		var s := load_pick(w, hooks, true)
		if s in TITLE_ABORT:
			return [0, TITLE_ABORT[s], true]
		if s == 0:
			return [0, 0, true]
		if member_read(w, hooks.member_file(s - 1)) == -1:
			return [0, 0x10000, true]
		if Debrief.campaign_mode(w) == 1 and w.mode_663a == 0:
			if Pd2World.s8(w.script_no) < 11:
				var b := hooks.box(0x51759C)
				if b in TITLE_ABORT:
					return [0, TITLE_ABORT[b], true]
				continue
			w.set_ds16(0x50AD92, w.ds16(0x50AD92) - 1)
			w.set_ds16(0x50AD8E, w.ds16(0x50AD8E) - 1)
			w.campaign = 0
			w.script_no = 0x16
			Debrief.set_head_byte(w, 5, 0xC)
			var t := w.ds16(0x50AD8E)
			var n := 0
			for c in 64:
				if w.cb(c, 4) <= t and w.cb(c, 2) < 3 and w.cb(c, 7) != 0xFF and w.cb(c, 6) & 1 and w.cb(c, 3) == 0:
					n += 1
			if n == 0:
				var b := hooks.box(0x5175C8)
				if b in TITLE_ABORT:
					return [0, TITLE_ABORT[b], true]
				continue
			if w.mem8(AIR_PILOTS + _list(w, 0xC)):
				# the scenario list's 13th mission asks for pilots: the check reads local_74,
				# never set on this path (undefined)
				w.fault = "rescue: the pilot check on an unset local (scenario list %d)" % _list(w, 0xC)
				return [0, 0, true]
			var a := _drop(w, hooks, 0x517644)
			if a:
				return [0, a, true]
			w.set_ds8(0x50AD94, 0)
			Debrief.set_campaign_mode(w, 3)
			return [w.ds16(0x50AD8E), 0, false]
		var b := hooks.box(0x517574)
		if b in TITLE_ABORT:
			return [0, TITLE_ABORT[b], true]
	return [0, 0, true]


# --- the sortie's save (0x497F60) -------------------------------------------------------

const MISSION_NAMES := 0x50CB4E   # by mission (PD2 1-10, DASH 11-22): the name's address; DASH's by chunk from 0x50CB76


## The sortie's save (rules.SaveHooks): slot() 0x497A10 (0-40, 0x29 none, below 0 an
## abort); confirm(slot) 0x498070 with 0 (1 save); note(text) 0x452200 ("saved");
## write(name, data): a file written (false: it could not be).
class SaveHooks:
	func slot() -> int:
		return 0x29

	func confirm(s: int) -> int:
		return 1

	func note(text: int) -> int:
		return 0

	func write(name: String, data: PackedByteArray) -> bool:
		return true


## 0x497F60 (rules.save_game): a slot, confirmed; the mission's name copied to DS:0x50663E;
## PD2RECnn.BIN written (the note 0x519EB0). Returns slot + 1, 0, the confirm's answer or
## an abort.
static func save_game(w: Pd2World, hooks: SaveHooks) -> int:
	var s := hooks.slot()
	if s < 0 or s == 0x29:
		return s if s < 0 else 0
	var c := hooks.confirm(s)
	if c != 1:
		return c
	var table := 0x50CB76 if w.campaign == 0 else MISSION_NAMES
	var at := table + 4 * Pd2World.s8(Debrief.head_byte(w, 5))
	var p := w.mem8(at) | w.mem8(at + 1) << 8 | w.mem8(at + 2) << 16 | w.mem8(at + 3) << 24
	var i := 0
	while true:
		var v := w.mem8(p + i)
		w.mem_write(0x50663E + i, v)
		if v == 0:
			break
		i += 1
	var data := write_save(w)
	if hooks.write("PD2REC%02d.BIN" % s, data):
		var r := hooks.note(0x519EB0)
		if r < 0:
			return r
	return s + 1


## The sortie's system menu, entry 1 (rules.sortie_save): save_game; then KEMURInn.DAT
## (the image's first 0xD20 B; unwritable: 1) and MEMBERnn.DAT (member_write).
static func sortie_save(w: Pd2World, hooks: SaveHooks) -> int:
	var s := save_game(w, hooks)
	if s in [-3, -2, -1] or s == 0:
		return s
	if not hooks.write("KEMURI%02d.DAT" % (s - 1), Debrief.save_image(w).slice(0, 0xD20)):
		return 1
	hooks.write("MEMBER%02d.DAT" % (s - 1), member_write(w))
	return s


# --- the battle's saves (the system menu 0x4847C0, emulated by verify_battle_save) ------

const KEMURI_PD2 := 0xA98                 # KEMURInn.DAT's size by the campaign flag (DASH 0xD20)
const KEMURI_DASH := 0xD20
const BATTLE_ABORTS := [0x10000, 0x20000, 0x40000]
const SYSTEM_TOGGLES := {2: 0x10, 3: 0x100, 4: 0x1000, 5: 0x2000, 6: 0x4000, 7: 0x8000}   # DS:0x551D29 by entry
const SYSTEM_TEXTS := {2: [0x1F9, 0x1FA], 3: [0x209, 0x20A], 4: [0x20D, 0x20C], 5: [0x20E, 0x20F],
		6: [0x1CA, 0x210], 7: [0x214, 0x215]}     # the question by the bit: [set, clear]
const SYSTEM_LABELS := [0x518224, 0x51823C, 0x518250, 0x518264, 0x518278, 0x51828C, 0x5182A0, 0x5182B0]
const SLOT_SORTIE_TIME := 0x50CBD1        # "編成": the slot line's time for a save made outside a battle


## mission_state's write (rules.kemuri_pack): each pair of F bytes (e, o) into one (e's
## bits 0, 2, 3, 6 (PD2 5), then o's), the AI memory, DASH bit 7 of every F byte.
static func kemuri_pack(w: Pd2World) -> PackedByteArray:
	var hi := 5 if w.campaign else 6
	var out := PackedByteArray()
	for i in 0xA20:
		var e := w.F[2 * i]
		var o := w.F[2 * i + 1]
		out.append((e & 1) | (e >> 2 & 1) << 1 | (e >> 3 & 1) << 2 | (e >> hi & 1) << 3
				| (o & 1) << 4 | (o >> 2 & 1) << 5 | (o >> 3 & 1) << 6 | (o >> hi & 1) << 7)
	var mem := w.memory.duplicate()
	mem.resize(0x78)
	out.append_array(mem)
	if not w.campaign:
		for j in 0x288:
			var b := 0
			for k in 8:
				b = b << 1 | w.F[8 * j + k] >> 7
			out.append(b)
	return out


## mission_state's read (rules.kemuri_unpack): 0x484680 back into F (the other bits stay;
## e's bit 7 cleared, PD2 bit 5 and 6 both from bit 3), the AI memory, DASH 0x4845A0.
static func kemuri_unpack(w: Pd2World, data: PackedByteArray) -> void:
	for i in 0xA20:
		var p := data[i]
		var e := w.F[2 * i]
		var o := w.F[2 * i + 1]
		e = (e & 0xF2) | (p & 1) | (p & 2) << 1 | (p & 4) << 1
		e = (p & 8) << 3 | (e & 0x3F)
		if w.campaign:
			e = (p & 8) << 2 | (e & 0xDF)
		o = (o & 0xF2) | (p >> 4 & 1) | (p >> 3 & 4) | (p >> 3 & 8)
		if w.campaign:
			o = (p >> 2 & 0x20) | (o & 0xDF)
		else:
			o = (p >> 1 & 0x40) | (o & 0x3F)
		w.F[2 * i] = e
		w.F[2 * i + 1] = o
	if w.memory.size() < 0x78:
		w.memory.resize(0x78)
	for i in 0x78:
		w.memory[i] = data[0xA20 + i]
	if not w.campaign:
		for j in 0x288:
			var b := data[0xA98 + j]
			for k in 8:
				w.F[8 * j + k] |= (b << k) & 0x80


## The battle's windows and files (rules.BattleSaveHooks): menu() 0x40C090 (0-7, below 0
## none, -12 / -11 an abort, NONE failed); box(msg) a question (1 yes, 0 no, or an abort);
## slot(load) 0x477580 / 0x477770 (0-40, 0x29 none, or an abort); ask(line) the slot's
## line and question (1 yes); note(text) (an exe address or a MES id; 0 or an abort);
## error(text) 0x408B70; read / write the game folder's files; campaign_set(w); for the
## load load_script(), deselect(), start_script(), redraw(), scroll(u).
class BattleSaveHooks:
	func menu() -> int:
		return -2

	func box(_msg: int) -> int:
		return 0

	func slot(_load: bool) -> int:
		return 0x29

	func ask(_line: Array) -> int:
		return 1

	func note(_text: int) -> int:
		return 0

	func error(_text: int) -> void:
		pass

	func read(_name: String) -> Variant:
		return null

	func write(_name: String, _data: PackedByteArray) -> bool:
		return true

	func campaign_set(_w: Pd2World) -> void:
		pass

	func load_script() -> void:
		pass

	func deselect() -> int:
		return 0

	func start_script() -> int:
		return 0

	func redraw() -> int:
		return 0

	func scroll(_u: int) -> int:
		return 0


## 0x453900's text (rules.slot_time): "HH:MM" of turn t from the start d, five minutes a turn.
static func slot_time(t: int, d: int) -> String:
	var v := (t + d) * 5
	var h := v / 60
	var m := v % 60
	if h > 23:
		h %= 24
	return "%02d:%02d" % [h, m]


## 0x498070 / 0x477EB0 on a save file's bytes (rules.slot_line): null (no file, no head, not
## "PD2DATA": the answer is 1), "note" (loading another mode's save: DS:0x50663A differs,
## mode not 0xFF), or [mode text's address, name bytes, time (null: 0x50CBD1's), load].
static func slot_line(data: Variant, mode: int, load: bool) -> Variant:
	if data == null:
		return null
	var d: PackedByteArray = data
	if d.size() < 8 + 0x1C:
		return null
	var z := d.slice(0, 8).find(0)
	if d.slice(0, 7 if z == -1 else z) != "PD2DATA".to_ascii_buffer() or z != 7:
		return null
	var h := d.slice(8, 8 + 0x1C)
	if not (mode == 0xFF or mode == h[2] or not load):
		return "note"
	var word := h[0] | h[1] << 8
	var kind := 0x50CBF2 if word == 1 else (0x50CBFB if word == 2 else 0x50CC04)
	var name := h.slice(6)
	var nz := name.find(0)
	if nz != -1:
		name = name.slice(0, nz)
	var when: Variant = null if h[2] == 0 else slot_time(h[3] | h[4] << 8, h[0x19] | h[0x1A] << 8)
	return [kind, name, when, load]


## 0x477EB0 (rules.slot_confirm): 1 without a header; the note for another mode's save when
## loading (then 0 or its abort); else ask(line).
static func slot_confirm(w: Pd2World, hooks: BattleSaveHooks, name: String, load: bool, note_text: int) -> int:
	var line: Variant = slot_line(hooks.read(name), w.mode_663a & 0xFF, load)
	if line == null:
		return 1
	if line is String:
		var r := hooks.note(note_text)
		return r if r in BATTLE_ABORTS else 0
	return hooks.ask(line)


## The file names' two digits ('0' + slot / 10, '0' + slot % 10, C division).
static func digits(s: int) -> String:
	var q := absi(s) / 10 * (1 if s >= 0 else -1)
	var r := s - 10 * q
	return String.chr(0x30 + q) + String.chr(0x30 + r)


static func rec_name(s: int) -> String:
	return "PD2REC%s.BIN" % digits(s)


## mission_state 0x484160 (rules.battle_state): KEMURInn.DAT (slot -1: KEMURI__.DAT)
## written (not written: the note 0x518154, -3 0x20000, -2 0x40000, -1 0x10000, else 0;
## written 1) or read (no file or short: the error and 0x10000; else unpacked, 1).
static func battle_state(w: Pd2World, s: int, write: bool, hooks: BattleSaveHooks) -> int:
	var name := "KEMURI%s.DAT" % ("__" if s == -1 else digits(s))
	var size := KEMURI_PD2 if w.campaign else KEMURI_DASH
	if write:
		if not hooks.write(name, kemuri_pack(w).slice(0, size)):
			var r := hooks.note(0x518154)
			return {-3: 0x20000, -2: 0x40000, -1: 0x10000}.get(r, 0)
		return 1
	var data: Variant = hooks.read(name)
	if data == null or (data as PackedByteArray).size() < size:
		hooks.error(0x5181A8 if data == null else 0x5181AC)
		return 0x10000
	kemuri_unpack(w, (data as PackedByteArray).slice(0, size))
	return 1


## 0x477220 (rules.battle_save): a slot, confirmed; the mission's name by DS:0x50CE72 at
## DS:0x50663E; PD2RECnn.BIN written, the note 0x5178E0. Returns slot + 1, 0 or an abort.
static func battle_save(w: Pd2World, hooks: BattleSaveHooks) -> int:
	var s := hooks.slot(false)
	if s in BATTLE_ABORTS:
		return s
	if s == 0x29:
		return 0
	var c := slot_confirm(w, hooks, rec_name(s), false, 0x5179AC)
	if c != 1:
		return c
	var at := MISSION_NAMES + 4 * Pd2World.s8(w.script_no & 0xFF)
	var p := w.mem8(at) | w.mem8(at + 1) << 8 | w.mem8(at + 2) << 16 | w.mem8(at + 3) << 24
	var i := 0
	while true:
		var v := w.mem8(p + i)
		w.mem_write(0x50663E + i, v)
		if v == 0:
			break
		i += 1
	if hooks.write(rec_name(s), write_save(w)):
		var r := hooks.note(0x5178E0)
		if r in BATTLE_ABORTS:
			return r
	return s + 1


## 0x477370 (rules.battle_load): the slot list until a battle save is confirmed; read
## (1-3 MES 6, 4 MES 0xC: 0; 5 MES 9, 100 0x5178EC: 0x10000), MEMBERnn.DAT (-1),
## DS:0x50AD94 = slot + 1. Returns slot + 1, 0, -1 or an abort.
static func battle_load(w: Pd2World, hooks: BattleSaveHooks) -> int:
	while true:
		var s := hooks.slot(true)
		if s in BATTLE_ABORTS:
			return s
		if s == 0x29:
			return 0
		var c := slot_confirm(w, hooks, rec_name(s), true, 0x5179AC)
		if c in BATTLE_ABORTS:
			return c
		if c != 1:
			continue
		var code := read_save(w, hooks.read(rec_name(s)))
		if code == 5 or code == 100:
			var r := hooks.note(9 if code == 5 else 0x5178EC)
			return r if r in BATTLE_ABORTS else 0x10000
		if code:
			var r := hooks.note(0xC if code == 4 else 6)
			return r if r in BATTLE_ABORTS else 0
		if member_read(w, hooks.read("MEMBER%s.DAT" % digits(s))) == -1:
			return -1
		w.set_ds8(0x50AD94, s + 1)
		return s + 1
	return 0


## mission_loop on a battle save (rules.mission_resume; DS:0x50AD94 = slot + 1): the load
## script, DS:0x50ADF2 = 0, the layers reset, KEMURI read (0x10000 without it); an end
## code ends the mission; else the occupancy, the start script, the map, DS:0x50AD94's
## byte 0, refresh_strikes(0). Returns 0 (the player's phase goes on), an end code or an
## abort. (rng: the start script's.)
static func mission_resume(w: Pd2World, rng: Pd2Random, hooks: BattleSaveHooks) -> int:
	hooks.load_script()
	w.set_ds8(0x50ADF2, 0)
	Mission.layers_reset(w)
	var r := battle_state(w, (w.ds8(0x50AD94) & 0xFF) - 1, false, hooks)
	if r in BATTLE_ABORTS:
		return r
	if w.ds8(0x50ADF2):
		return Debrief.mission_exit(w, w.ds8(0x50ADF2) & 0xFF)
	Mission.rebuild_occupancy(w)
	r = hooks.start_script()
	if r in BATTLE_ABORTS:
		return r
	r = hooks.redraw()
	if r in BATTLE_ABORTS:
		return r
	w.set_ds8(0x50AD94, 0)
	AiTurn.refresh_strikes(w, 0)
	return 0


## 0x4847C0, the battle's system menu (rules.battle_menu): 0 save (PD2RECnn.BIN, KEMURInn.DAT,
## MEMBERnn.DAT), 1 load (and the mission set up again from it), 2-7 SYSTEM_TOGGLES after
## their question. Returns 0 or an abort (0x10000 also a failed load: the game ends).
static func battle_menu(w: Pd2World, hooks: BattleSaveHooks) -> int:
	var m := hooks.menu()
	if m == NONE:
		return 0x10000
	if m == -12:
		return 0x20000
	if m == -11:
		return 0x40000
	if m == 0:
		var s := battle_save(w, hooks)
		if s in BATTLE_ABORTS or s == 0:
			return s
		var r := battle_state(w, s - 1, true, hooks)
		if r in BATTLE_ABORTS:
			return r
		if not hooks.write("MEMBER%s.DAT" % digits(s - 1), member_write(w)):
			return 0x10000
		return 0
	if m == 1:
		var s := battle_load(w, hooks)
		if s in BATTLE_ABORTS or s == 0:
			return s
		hooks.load_script()
		var r := hooks.deselect()
		if r in BATTLE_ABORTS:
			return r
		if member_read(w, hooks.read("MEMBER%s.DAT" % digits(s - 1))) == -1:
			return 0x10000
		if Pd2World.s8(w.script_no & 0xFF) < 11:
			_from_stash(w)
			Debrief.set_head_byte(w, 5, w.script_no & 0xFF)
			if w.ds16(0x50AD8E) > 0x11:
				w.set_ds16(0x50AD8E, w.ds16(0x50AD8E) - 10)
			w.campaign = 1
		else:
			Debrief.set_head_byte(w, 5, (w.script_no - 10) & 0xFF)
			w.campaign = 0
		w.set_ds16(0x50AD92, w.ds16(0x50AD8E))
		hooks.campaign_set(w)
		Mission.layers_reset(w)
		r = battle_state(w, s - 1, false, hooks)
		if r in BATTLE_ABORTS:
			return r
		r = hooks.start_script()
		if r in BATTLE_ABORTS:
			return r
		Mission.rebuild_occupancy(w)
		AiTurn.refresh_strikes(w, 0)
		r = hooks.redraw()
		if r in BATTLE_ABORTS:
			return r
		for u in mini(w.units.size() / 55, 0xFE):
			if w.active(u) and w.ub(u, 0x36) == 0:
				r = hooks.scroll(u)
				if r in BATTLE_ABORTS:
					return r
				break
		return 0
	if SYSTEM_TOGGLES.has(m):
		var bit: int = SYSTEM_TOGGLES[m]
		var a := hooks.box(SYSTEM_TEXTS[m][0 if w.options & bit else 1])
		if a in BATTLE_ABORTS:
			return a
		if (a == 1) if m in [2, 3, 4] else (a != 0):
			w.options ^= bit
			if m in [4, 7]:
				var r := hooks.redraw()
				if r in [0x10000, 0x20000]:
					return r
		return 0
	return 0
