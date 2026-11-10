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


## The screen's windows (rules.EquipHooks): its lists (0x452A10: an index, -2 cancel),
## questions (0x451E30: 1 yes) and notes (0x452170).
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


## A picker's loop: an entry out of stock is refused (a note) and the list stays.
## Returns the entry, or null (cancelled).
static func _pick(w: Pd2World, hooks: Hooks, kind: String, entries: Array, offset: int, refuse: Callable) -> Variant:
	while true:
		var c := hooks.pick(kind, entries)
		if c == -2:
			return null
		var j := c - offset
		if j < 0 or j >= entries.size():
			w.fault = "equipment: a list button that is not an entry (sorts are not ported)"
			return null
		var msg: int = refuse.call(entries[j])
		if msg == 0:
			return entries[j]
		hooks.note(msg)
	return null


## The screen's buttons for unit k (rules.equipment_screen): "machine", "clear", "close",
## "undo", ["slot", s], ["pocket", p]. Returns the log.
static func screen(w: Pd2World, k: int, hooks: Hooks, buttons: Array) -> Array:
	var sess := open(w, k)
	for b in buttons:
		if sess.done or w.fault != "":
			break
		step(w, sess, hooks, b)
	return sess.log


## Opening the screen for unit k: its copy (for undo). The session for step().
static func open(w: Pd2World, k: int) -> Dictionary:
	var copy := PackedByteArray()
	for i in 55:
		copy.append(w.mem8(UNITS + 55 * k + i))
	return {"k": k, "copy": copy, "changed": false, "done": false, "log": []}


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
