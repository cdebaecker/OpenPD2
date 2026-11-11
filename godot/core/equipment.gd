class_name Equipment
extends RefCounted
## The armament screen (Pd2.exe 0x454E60, "busou_g?.pac"), ported from rules.py and checked
## against the game by emulation (verify_equipment): a player unit's machine, launcher
## slots and pockets, taken from and given back to the base's stock (DS:0x506654
## machines, 0x506674 launchers, 0x5066D4 rounds; Pd2World.stock).

const STOCK_MACH := 0x506654
const STOCK_LAUN := 0x506674
const STOCK_AMMO := 0x5066D4
const UNITS := 0x506C93
const CREWS := 0x506734
const MACHS := 0x50ADF5
const LAUNS := 0x50B1D5
const AMMOS := 0x50B835


## The screen's windows (rules.EquipHooks): its lists (0x452A10: an index, -2 cancel; the
## pickers' column headers first, ListSort), questions (0x451E30: 1 yes) and notes
## (0x452170, 0x452200).
class Hooks:
	func pick(kind: String, entries: Array) -> int:
		return -2

	func ask(msg: int) -> int:
		return 1

	func note(msg: int) -> int:
		return 0


static func _add(w: Pd2World, addr: int, d: int) -> void:
	w.mem_write(addr, w.mem8(addr) + d)


static func _t92(w: Pd2World) -> int:
	return w.ds16(0x50AD92)


## 0x457320: pocket p's round back to stock, the pocket emptied.
static func free_pocket(w: Pd2World, k: int, p: int) -> void:
	var base := UNITS + 55 * k
	var a := Flight.s8(w.mem8(base + 0x1B + 2 * p))
	if a != -1:
		_add(w, STOCK_AMMO + a, 1)
		w.mem_write(base + 0x1B + 2 * p, 0xFF)


## 0x457250: slot s's launcher back to stock, with the pocket it loads from.
static func free_slot(w: Pd2World, k: int, s: int) -> void:
	var base := UNITS + 55 * k
	var lid := Flight.s8(w.mem8(base + 0xF + 2 * s))
	if lid != -1:
		_add(w, STOCK_LAUN + lid, 1)
		w.mem_write(base + 0xF + 2 * s, 0xFF)
		free_pocket(w, k, w.mem8(base + 0x10 + 2 * s) & 0xF)


## 0x457130: with a machine, every slot, pockets 0-5 and the machine back to stock.
static func free_all(w: Pd2World, k: int) -> void:
	var base := UNITS + 55 * k
	var m := Flight.s8(w.mem8(base + 0xC))
	if m == -1:
		return
	for s in 6:
		free_slot(w, k, s)
	for p in 6:
		free_pocket(w, k, p)
	_add(w, STOCK_MACH + m, 1)
	w.mem_write(base + 0xC, 0xFF)


## 0x457870: the machines offered (ground crews class 0-1, air crews class 2; +0x1C = 0,
## +0x1E <= DS:0x50AD92).
static func machine_list(w: Pd2World, k: int) -> Array:
	var air := w.crew[k * 16 + 3] != 0
	var out := []
	for m in 32:
		var c := Flight._machine_class(w, m)
		if (c == 2 if air else c < 2) and w.mem8(MACHS + 31 * m + 0x1C) == 0 and w.mem8(MACHS + 31 * m + 0x1E) <= _t92(w):
			out.append(m)
	return out


## 0x4582D0: the [launcher, round] pairs slot s takes.
static func slot_list(w: Pd2World, k: int, s: int) -> Array:
	var m := Flight.s8(Flight.ub(w, k, 0xC))
	var mask := w.mem8(MACHS + 31 * m + 0xB + 2 * s) | w.mem8(MACHS + 31 * m + 0xC + 2 * s) << 8
	var out := []
	for lid in 96:
		var lb := LAUNS + 17 * lid
		var lm := w.mem8(lb) | w.mem8(lb + 1) << 8
		if not lm & mask or w.mem8(lb + 0xE) or w.mem8(lb + 0x10) > _t92(w):
			continue
		var takes := []
		for i in 3:
			takes.append(Flight.s8(w.mem8(lb + 0xA + i)))
		for i in 3:
			var a: int = takes[i]
			if a == -1:
				break
			if i == 1 and takes[0] == takes[1]:
				continue
			if w.mem8(AMMOS + 12 * a + 0xB) <= _t92(w):
				out.append([lid, a])
	return out


## 0x458CD0 with 0x459370: the pocket items.
static func item_list(w: Pd2World) -> Array:
	var out := []
	for a in 96:
		var b := AMMOS + 12 * a
		var f := w.mem8(b + 8)
		if w.mem8(b + 9) == 0 and f & 0x10 and w.mem8(b + 0xB) <= _t92(w) and (f & 0x20 or (f & 0xF >= 10 and f & 0xF <= 13)):
			out.append(a)
	return out


## 0x458CD0 with 0x4593B0: the spare magazines for launcher lid.
static func magazine_list(w: Pd2World, lid: int) -> Array:
	var takes := []
	for i in 3:
		takes.append(Flight.s8(w.mem8(LAUNS + 17 * lid + 0xA + i)))
	var out := []
	for a in 96:
		if a in takes and w.mem8(AMMOS + 12 * a + 0xB) <= _t92(w):
			out.append(a)
	return out


## the pickers' sorts: the comparator table, the values a picker remembers below
const PICK_SORTS := {"machine": [ListSort.MACHINE, 6], "slot": [ListSort.SLOT, 0xC], "item": [ListSort.ITEM, 7]}


## A picker's loop: an entry out of stock is refused (a note) and the list stays. Its
## column headers (0 .. offset - 1) sort the rows (the slot list keeps "remove" first); a
## click equal to the last one remembered does nothing (rules._equip_pick_stock).
## Returns the entry, or null (cancelled).
static func _pick(w: Pd2World, hooks: Hooks, kind: String, entries: Array, offset: int, refuse: Callable) -> Variant:
	var table: String = PICK_SORTS[kind][0]
	var keep: int = PICK_SORTS[kind][1]
	var first := 1 if not entries.is_empty() and entries[0] is String and entries[0] == "remove" else 0
	var last := -1
	while true:
		var c := hooks.pick(kind, entries)
		if c == last:
			continue
		if c < keep:
			last = c
		if c == -2:
			return null
		if c >= 0 and c < offset:
			var rows := entries.slice(first)
			ListSort.sort(w, rows, table, c)
			for i in rows.size():
				entries[first + i] = rows[i]
			continue
		var j := c - offset
		if j < 0 or j >= entries.size():
			w.fault = "equipment: a list button that is not an entry"
			return null
		var msg: int = refuse.call(entries[j])
		if msg == 0:
			return entries[j]
		hooks.note(msg)
	return null


## The screen's buttons for unit k (rules.equipment_screen): "machine", "clear", "close",
## "undo", "menu" (the right button: the template menu), ["slot", s], ["pocket", p].
## Returns the log.
static func screen(w: Pd2World, k: int, hooks: Hooks, buttons: Array) -> Array:
	var sess := open(w, k)
	for b in buttons:
		if sess.done or w.fault != "":
			break
		step(w, sess, hooks, b)
	return sess.log


## Opening the screen for unit k: its copy (for undo) and its layout (local_ac, the
## busou_g<n>.pac shown). The session for step().
static func open(w: Pd2World, k: int) -> Dictionary:
	var copy := PackedByteArray()
	for i in 55:
		copy.append(w.mem8(UNITS + 55 * k + i))
	var m0 := Flight.s8(copy[0xC])
	var layout := 0
	if m0 == -1:
		layout = 0 if w.crew[k * 16 + 3] == 0 else 2
	elif w.crew[k * 16 + 3] == 1:
		layout = 2
	else:
		layout = 0 if w.mem8(MACHS + 31 * m0) & 0xF == 0 else 1
	return {"k": k, "copy": copy, "changed": false, "done": false, "log": [], "layout": layout}


## One button of the screen (see screen); sess.done once it is closed.
static func step(w: Pd2World, sess: Dictionary, hooks: Hooks, b: Variant) -> void:
	var k: int = sess.k
	var base := UNITS + 55 * k
	var copy: PackedByteArray = sess.copy
	var log: Array = sess.log
	if true:
		var m := Flight.s8(w.mem8(base + 0xC))
		var name: String = b if b is String else b[0]
		match name:
			"menu":                     # the right button (-2): 0x45A700's menu
				if m == -1:
					if sess.layout == 2:
						return
					if sess.layout == 1:
						sess.layout = 0
				elif m > 6:
					return
				var c := hooks.pick("menu", ["save", "load", "copy"])
				if c < 0:
					return
				var r := template_menu(w, k, c, hooks)
				log.append(["menu", c, r])
				if r == -0x66 or r == -0x67 or r == -0x65:
					sess.done = true
				return
			"machine":
				var ents := machine_list(w, k)
				if ents.is_empty():
					hooks.note(0x1AE)
					return
				var pick: Variant = _pick(w, hooks, "machine", ents, 6,
						func(e): return 0 if w.mem8(STOCK_MACH + e) else 0x1B0)
				if pick == null:
					return
				sess.changed = true
				sess.layout = Flight._machine_class(w, pick)
				free_all(w, k)
				w.mem_write(base + 0xC, pick)
				_add(w, STOCK_MACH + pick, -1)
				log.append(["machine", pick])
			"clear":
				if m == -1:
					hooks.note(0x1DE)
				elif hooks.ask(0x1A3) == 1:
					free_all(w, k)
					sess.changed = true
					log.append(["clear"])
			"undo":
				if not sess.changed:
					log.append(["close"])
					sess.done = true
					return
				if hooks.ask(0x1A5) == 1:
					free_all(w, k)
					for i in 55:
						w.mem_write(base + i, copy[i])
					if Flight.s8(w.mem8(base + 0xC)) != -1:
						for s in 6:
							var lid := Flight.s8(w.mem8(base + 0xF + 2 * s))
							if lid != -1:
								_add(w, STOCK_LAUN + lid, -1)
						for p in 6:
							var a := Flight.s8(w.mem8(base + 0x1B + 2 * p))
							if a != -1:
								_add(w, STOCK_AMMO + a, -1)
						_add(w, STOCK_MACH + Flight.s8(w.mem8(base + 0xC)), -1)
					log.append(["undo"])
					sess.done = true
					return
			"close":
				var g := w.crew[k * 16 + 5]
				if g == 0xFF:
					log.append(["close"])
					sess.done = true
					return
				var old := Flight.s8(copy[0xC])
				var leave := false
				if Flight._machine_class(w, m) == Flight._machine_class(w, old):
					if Flight._machine_class(w, old) == 2:
						var pilots := 0
						for i in Flight.gb(w, g, 5):
							if w.mem8(CREWS + 16 * Flight.gb(w, g, 6 + i) + 3) == 1:
								pilots += 1
						if pilots > 1 and old != m and (not old in [7, 12] or not m in [7, 12]):
							leave = true
						var c := w.mem8(MACHS + 31 * m) & 0xF
						if c == 2 or c == 3:
							if g > 10:
								leave = true
						elif (c == 4 or c == 5) and g < 12:
							leave = true
				else:
					leave = true
				if m == -1 or leave:
					if hooks.ask(0x1DA if m == -1 else 0x1A4) == 1:
						Action.group_drop_player(w, g, k)
						w.mem_write(base, w.mem8(base) & 0xFB)
						log.append(["close", "left group"])
						sess.done = true
						return
				else:
					log.append(["close"])
					sess.done = true
					return
			"slot":
				var s: int = b[1]
				if m == -1:
					hooks.note(0x1DE)
					return
				var ents := slot_list(w, k, s)
				var has := Flight.s8(w.mem8(base + 0xF + 2 * s)) != -1
				if ents.is_empty() and not has:
					hooks.note(0x1B1)
					return
				var full: Array = (["remove"] if has else []) + ents
				var refuse := func(e) -> int:
					if e is String:
						return 0
					if not w.mem8(STOCK_LAUN + e[0]):
						return 0x1B3
					if not w.mem8(STOCK_AMMO + e[1]):
						return 0x1B4
					return 0
				var pick: Variant = _pick(w, hooks, "slot", full, 0xD, refuse)
				if pick == null:
					return
				free_slot(w, k, s)
				if not pick is String:
					var lid: int = pick[0]
					var a: int = pick[1]
					w.mem_write(base + 0xF + 2 * s, lid)
					var st := w.mem8(base + 0x10 + 2 * s)
					w.mem_write(base + 0x10 + 2 * s, ((st & 0xF0) | ((s + 6) & 0xF)) & 0xCF)
					_add(w, STOCK_LAUN + lid, -1)
					w.mem_write(base + 0x1B + 2 * (s + 6), a)
					w.mem_write(base + 0x1C + 2 * (s + 6), w.mem8(AMMOS + 12 * a) & 0x3F)
					_add(w, STOCK_AMMO + a, -1)
				log.append(["slot", s, pick])
			"pocket":
				var p: int = b[1]
				if m == -1:
					hooks.note(0x1DE)
					return
				if p >= w.mem8(MACHS + 31 * m + 0x17):
					return
				var mags := []
				for s in 6:
					var l := w.mem8(base + 0xF + 2 * s)
					if l != 0xFF and w.mem8(LAUNS + 17 * Flight.s8(l) + 9) & 8:
						mags.append(l)
				var has := Flight.s8(w.mem8(base + 0x1B + 2 * p)) != -1
				var menu: Array = (["remove"] if has else []) + ["item"]
				for l in mags:
					menu.append(["magazine", l])
				var c := hooks.pick("pocket", menu)
				if c == -2:
					return
				var choice: Variant = menu[c]
				var got: Variant = null
				if choice is String and choice == "remove":
					got = "remove"
				else:
					var ents := item_list(w) if choice is String else magazine_list(w, Flight.s8(choice[1]))
					if ents.is_empty():                 # the picker returns -2: read as "remove"
						hooks.note(0x1B6 if choice is String else 0x1B9)
						got = "remove"
					else:
						got = _pick(w, hooks, "item", ents, 7, func(e): return 0 if w.mem8(STOCK_AMMO + e) else 0x1B0)
						if got == null:
							return
				free_pocket(w, k, p)
				if not got is String:
					w.mem_write(base + 0x1B + 2 * p, got)
					w.mem_write(base + 0x1C + 2 * p, w.mem8(AMMOS + 12 * got) & 0x3F)
					_add(w, STOCK_AMMO + got, -1)
				log.append(["pocket", p, got])


# --- the template menu (0x45A700, reg_unit.dat) -----------------------------------------
# reg_unit.dat (0x186 B at DS:0x50CCEA, Pd2World.reg_unit) is read each time the screen
# opens and written back whole after a register (0x45CCE0); in the engine it is
# user://<campaign>/reg_unit.dat (load_reg_unit / save_reg_unit). Ten registers of 0x27 B:
# +0 flags (bits 0-2; in use when one is set), +1 the machine (i16), +3 + 2 s slot s,
# +0xF + 2 p pocket p (p 0-11; pockets 6-11, the magazines, at +0x1B).

const REG_UNIT := 0x50CCEA
const REG_SIZE := 0x186
const REG_LEN := 0x27
const TEMPLATE_TEXT := {"none": 0x515BDC, "overwrite": 0x515BB4, "saved": 0x515BC4, "saved_new": 0x515BD0,
		"no_member": 0x515C6C, "load_stock": 0x515C1C, "load_stock1": 0x515C40,
		"copy_stock": 0x515CC8, "copy_stock1": 0x515CEC}


## The shipped REG_UNIT.DAT: ten empty registers (each register's odd bytes 0xFF).
static func reg_unit_blank() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(REG_SIZE)
	for i in REG_SIZE:
		b[i] = 0xFF if (i % REG_LEN) & 1 else 0
	return b


## The campaign's reg_unit.dat (user://<campaign>/reg_unit.dat), or the blank registers.
static func load_reg_unit(campaign: String) -> PackedByteArray:
	var path := "user://%s/reg_unit.dat" % campaign
	if FileAccess.file_exists(path):
		var b := FileAccess.get_file_as_bytes(path)
		if b.size() == REG_SIZE:
			return b
	return reg_unit_blank()


static func save_reg_unit(campaign: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute("user://%s" % campaign)
	var f := FileAccess.open("user://%s/reg_unit.dat" % campaign, FileAccess.WRITE)
	if f:
		f.store_buffer(data)


static func _reg(w: Pd2World, i: int, f: int) -> int:
	return w.mem8(REG_UNIT + REG_LEN * i + f)


static func _set_reg(w: Pd2World, i: int, f: int, v: int) -> void:
	w.mem_write(REG_UNIT + REG_LEN * i + f, v)


## The registers in use (flags & 7); the menu reads registers 0 .. count - 1.
static func reg_used(w: Pd2World) -> int:
	var n := 0
	for i in 10:
		if _reg(w, i, 0) & 7:
			n += 1
	return n


## stock[(char) i] -= 1 as the game addresses it.
static func _stock_dec(w: Pd2World, base: int, i: int) -> void:
	var a := base + Flight.s8(i)
	w.mem_write(a, w.mem8(a) - 1)


## A register (rules.template_save): flags |= 7, the machine, slots 0-3 with their
## magazines (not slots 4-5), pockets 0-5; a slot's state keeps the register's bits 6-7.
static func template_save(w: Pd2World, k: int, i: int) -> void:
	var u := UNITS + 55 * k
	_set_reg(w, i, 0, _reg(w, i, 0) | 3)
	var mach := Flight.s8(w.mem8(u + 0xC)) & 0xFFFF
	_set_reg(w, i, 1, mach & 0xFF)
	_set_reg(w, i, 2, mach >> 8)
	for s in 4:
		_set_reg(w, i, 3 + 2 * s, w.mem8(u + 0xF + 2 * s))
		_set_reg(w, i, 4 + 2 * s, (_reg(w, i, 4 + 2 * s) & 0xC0) | (w.mem8(u + 0x10 + 2 * s) & 0x3F))
		_set_reg(w, i, 0x1B + 2 * s, w.mem8(u + 0x27 + 2 * s))
		_set_reg(w, i, 0x1C + 2 * s, w.mem8(u + 0x28 + 2 * s))
	_set_reg(w, i, 0, _reg(w, i, 0) | 4)
	for p in 6:
		_set_reg(w, i, 0xF + 2 * p, w.mem8(u + 0x1B + 2 * p))
		_set_reg(w, i, 0x10 + 2 * p, w.mem8(u + 0x1C + 2 * p))
	w.set_meta("reg_unit_written", true)        # the game writes the file back (0x45CCE0)


## A recall shows register i (rules.template_preview_fix): in the register itself,
## launchers of slots 0-5 and rounds of pockets 0-11 not available by now become -1.
static func template_preview_fix(w: Pd2World, i: int) -> void:
	var t92 := _t92(w)
	for s in 6:
		var L := Flight.s8(_reg(w, i, 3 + 2 * s))
		if L == -1 or w.mem8(LAUNS + 17 * L + 0x10) > t92:
			_set_reg(w, i, 3 + 2 * s, 0xFF)
		var A := Flight.s8(_reg(w, i, 0x1B + 2 * s))
		if A == -1 or w.mem8(AMMOS + 12 * A + 0xB) > t92:
			_set_reg(w, i, 0x1B + 2 * s, 0xFF)
	for p in 6:
		var A := Flight.s8(_reg(w, i, 0xF + 2 * p))
		if A == -1 or w.mem8(AMMOS + 12 * A + 0xB) > t92:
			_set_reg(w, i, 0xF + 2 * p, 0xFF)


static func _fit_slot(w: Pd2World, u: int, s: int, L: int, state: int, mag: int, cnt: int, whole: bool) -> void:
	w.mem_write(u + 0xF + 2 * s, L)
	if whole:
		w.mem_write(u + 0x10 + 2 * s, state)
	else:
		w.mem_write(u + 0x10 + 2 * s, (w.mem8(u + 0x10 + 2 * s) & 0xC0) | (state & 0x3F))
	_stock_dec(w, STOCK_LAUN, L)
	w.mem_write(u + 0x27 + 2 * s, mag)
	w.mem_write(u + 0x28 + 2 * s, cnt)
	_stock_dec(w, STOCK_AMMO, mag)


static func _note_code(hooks: Hooks, t: int) -> int:
	var a := hooks.note(t)
	return -0x66 if a == -3 else (-0x67 if a == -2 else (-0x65 if a == -1 else 0))


## The four copies (rules.template_apply): 0 machine + weapons + items, 1 machine +
## weapons, 2 weapons, 3 items, from register src or (from_unit) unit src.
static func template_apply(w: Pd2World, k: int, option: int, src: int, hooks: Hooks, from_unit: bool) -> int:
	var u := UNITS + 55 * k
	var m := Flight.s8(w.mem8(u + 0xC))
	var S := (UNITS + 55 * src) if from_unit else (REG_UNIT + REG_LEN * src)
	var slot0 := 0xF if from_unit else 3          # slot s at S + slot0 + 2 s
	var pock0 := 0x1B if from_unit else 0xF       # pocket p at S + pock0 + 2 p
	var smach := Flight.s8(w.mem8(S + 0xC)) if from_unit else Flight.s16(w.mem8(S + 1) | w.mem8(S + 2) << 8)
	var nslots := 6 if from_unit else 4
	if option == 0 or option == 1:
		if not w.mem8(STOCK_MACH + smach):
			var key := ("copy_stock" if option == 0 else "copy_stock1") if from_unit \
					else ("load_stock" if option == 0 else "load_stock1")
			return _note_code(hooks, TEMPLATE_TEXT[key])
		free_all(w, k)
		w.mem_write(u + 0xC, smach)
		w.mem_write(STOCK_MACH + smach, w.mem8(STOCK_MACH + smach) - 1)
		for s in nslots:
			if _slot_ok(w, S, slot0, pock0, s, -1):
				var st := w.mem8(S + slot0 + 1 + 2 * s)
				_fit_slot(w, u, s, w.mem8(S + slot0 + 2 * s), st, w.mem8(S + pock0 + 2 * (6 + s)),
						w.mem8(S + pock0 + 1 + 2 * (6 + s)), from_unit)
		if option == 0:
			for p in 6:
				var a := w.mem8(S + pock0 + 2 * p)
				if a != 0xFF and w.mem8(STOCK_AMMO + Flight.s8(a)):
					w.mem_write(u + 0x1B + 2 * p, a)
					w.mem_write(u + 0x1C + 2 * p, w.mem8(S + pock0 + 1 + 2 * p))
					_stock_dec(w, STOCK_AMMO, a)
		return 0
	if m == -1:
		return _note_code(hooks, 0x1DE)
	if option == 2:
		for s in 4:
			free_slot(w, k, s)
		for s in nslots:
			if _slot_ok(w, S, slot0, pock0, s, m):
				var st := w.mem8(S + slot0 + 1 + 2 * s)
				_fit_slot(w, u, s, w.mem8(S + slot0 + 2 * s), st, w.mem8(S + pock0 + 2 * (6 + s)),
						w.mem8(S + pock0 + 1 + 2 * (6 + s)), from_unit)
		return 0
	for p in 6:
		free_pocket(w, k, p)
	for p in w.mem8(MACHS + 31 * m + 0x17):
		var a := w.mem8(S + pock0 + 2 * p)
		if w.mem8(STOCK_AMMO + Flight.s8(a)):
			w.mem_write(u + 0x1B + 2 * p, a)
			w.mem_write(u + 0x1C + 2 * p, w.mem8(S + pock0 + 1 + 2 * p))
			_stock_dec(w, STOCK_AMMO, a)
	return 0


## A source slot that can be fitted: its launcher and its loading pocket's round in stock,
## and (mach >= 0) the launcher fitting that machine's slot mask.
static func _slot_ok(w: Pd2World, S: int, slot0: int, pock0: int, s: int, mach: int) -> bool:
	var L := w.mem8(S + slot0 + 2 * s)
	if L == 0xFF or not w.mem8(STOCK_LAUN + Flight.s8(L)):
		return false
	if mach >= 0:
		var mm := w.mem8(MACHS + 31 * mach + 0xB + 2 * s) | w.mem8(MACHS + 31 * mach + 0xC + 2 * s) << 8
		var lm := w.mem8(LAUNS + 17 * Flight.s8(L)) | w.mem8(LAUNS + 17 * Flight.s8(L) + 1) << 8
		if not mm & lm:
			return false
	var st := w.mem8(S + slot0 + 1 + 2 * s)
	return w.mem8(STOCK_AMMO + Flight.s8(w.mem8(S + pock0 + 2 * (st & 0xF)))) != 0


## The members to copy from (rules.template_members): crews with +4 <= DS:0x50AD92, +2 < 3,
## a machine 0-6, +6 bits 0-1 clear, other than the unit's crew.
static func template_members(w: Pd2World, k: int) -> Array:
	var t92 := _t92(w)
	var me := Flight.s8(w.mem8(UNITS + 55 * k + 0xB))
	var out := []
	for c in 64:
		var mc := Flight.s8(w.mem8(UNITS + 55 * c + 0xC))
		if w.crew[c * 16 + 4] <= t92 and w.crew[c * 16 + 2] < 3 and mc != -1 and mc < 7 \
				and not w.crew[c * 16 + 6] & 3 and me != c:
			out.append(c)
	return out


## 0x45A700(mode, unit k) (rules.template_menu): 0 register, 1 recall, 2 copy. Its lists
## (hooks.pick): "register" ["new"] + the used registers; "recall" / "copy" the registers /
## members alone, then the four copies followed by them. Returns 0 or -0x66 / -0x67 /
## -0x65.
static func template_menu(w: Pd2World, k: int, mode: int, hooks: Hooks) -> int:
	if mode == 0:
		var n := reg_used(w)
		var full := n > 9
		var rows := [] if full else ["new"]
		for r in n:
			rows.append("reg%d" % r)
		var last := -1
		while true:
			var c := hooks.pick("register", rows)
			if c == -12:
				return -0x66
			if c == -11:
				return -0x67
			if c == -2:
				return 0
			if c == 0 and not full:
				template_save(w, k, rows.size() - 1)
				return _note_code(hooks, TEMPLATE_TEXT.saved_new)
			var i := c if full else c - 1
			if last != c:
				last = c
				continue
			var a := hooks.ask(TEMPLATE_TEXT.overwrite)
			if a == -3:
				return -0x66
			if a == -2:
				return -0x67
			if a == -1:
				return -0x65
			if a == 1:
				template_save(w, k, i)
				return _note_code(hooks, TEMPLATE_TEXT.saved)
		return 0
	var kind := ""
	var rows := []
	var mem := []
	if mode == 1:
		var n := reg_used(w)
		if n == 0:
			return _note_code(hooks, TEMPLATE_TEXT.none)
		kind = "recall"
		for r in n:
			rows.append("reg%d" % r)
	elif mode == 2:
		mem = template_members(w, k)
		if mem.is_empty():
			return _note_code(hooks, TEMPLATE_TEXT.no_member)
		kind = "copy"
		for c in mem:
			rows.append("crew%d" % c)
	else:
		return 0
	var first := true
	var src := 0
	var opts := ["all", "machine+weapons", "weapons", "items"]
	while true:
		var c := hooks.pick(kind, rows if first else opts + rows)
		if c == -12:
			return -0x66
		if c == -11:
			return -0x67
		if c == -2:
			return 0
		var j := c
		if first:
			first = false
		else:
			j = c - 4
			if j < 0:
				return template_apply(w, k, c, src, hooks, mode == 2)
		if mode == 1:
			src = j
			template_preview_fix(w, j)
		else:
			src = mem[j]
	return 0
