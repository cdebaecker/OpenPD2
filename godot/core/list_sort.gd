class_name ListSort
extends RefCounted
## The lists' sort buttons (Pd2.exe 0x4172B0 and its comparator tables), ported from
## rules.py (list_sort, ROSTER_SORTS ..) and checked against the game by emulation
## (verify_new_campaign, verify_sortie, verify_equipment). A list window (0x452A10) returns
## its column headers as 0, 1, .. before its rows; the screen then sorts its rows with
## the column's comparator. 0x4172B0 is an exchange sort -- for i, for j > i, rows i and j
## swap when cmp(row i, row j) > 0 -- not stable, and some comparators swap equal rows.

const STOCK_MACH := 0x506654
const STOCK_LAUN := 0x506674
const STOCK_AMMO := 0x5066D4
const MACHS := 0x50ADF5
const LAUNS := 0x50B1D5
const AMMOS := 0x50B835

## the tables: their comparator count
const ROSTER := "roster"      # 0x5170F0, the sortie's pilot roster (0x46A240): crews
const PICK := "pick"          # 0x513980, the new campaign's pilot choice (0x422050): crews
const MACHINE := "machine"    # 0x5152E8, the armament screen's machines (0x457380)
const SLOT := "slot"          # 0x515300, its (launcher, round) pairs (0x457C80)
const ITEM := "item"          # 0x515338, its pocket items and magazines (0x458E40)
const COLUMNS := {"roster": 12, "pick": 9, "machine": 6, "slot": 13, "item": 7}


## 0x4172B0(rows, n, size, cmp), in place, with table's column col.
static func sort(w: Pd2World, rows: Array, table: String, col: int) -> void:
	var n := rows.size()
	for i in n - 1:
		for j in range(i + 1, n):
			if cmp(w, table, col, rows[i], rows[j]) > 0:
				var t: Variant = rows[i]
				rows[i] = rows[j]
				rows[j] = t


static func _desc(a: int, b: int) -> int:
	return 1 if a < b else -1


static func _s8(v: int) -> int:
	v &= 0xFF
	return v - 256 if v > 127 else v


static func _crew(w: Pd2World, c: int, f: int) -> int:
	return w.crew[c * 16 + f]


static func _lb(w: Pd2World, l: int, f: int) -> int:
	return w.mem8(LAUNS + 17 * l + f)


static func _ab(w: Pd2World, a: int, f: int) -> int:
	return w.mem8(AMMOS + 12 * a + f)


static func _roster_state(w: Pd2World, c: int) -> int:
	var s6 := _crew(w, c, 6)
	if s6 & 1:
		return 4
	if s6 & 2:
		return 3
	return 2 if _crew(w, c, 5) != 0xFF else 1


static func _sext5(v: int) -> int:
	v &= 0x1F
	return v - 32 if v & 0x10 else v


## 0x459410 / 0x458AC0: by the round's +0, signed, largest first; 0xFF ones last.
static func _cap_first(w: Pd2World, a: int, b: int) -> int:
	var ca := _ab(w, a, 0)
	var cb := _ab(w, b, 0)
	if ca == 0xFF:
		return 1
	if cb == 0xFF:
		return -1
	return _desc(_s8(ca), _s8(cb))


## The comparator: > 0 swaps the rows.
static func cmp(w: Pd2World, table: String, col: int, a: Variant, b: Variant) -> int:
	match table:
		ROSTER:
			match col:
				0: return 1 if b < a else -1                                   # 0x46AD50
				1: return 1 if _roster_state(w, a) > _roster_state(w, b) else -1
				2, 3, 4, 5, 6: return _desc(_s8(_crew(w, a, 7 + col)), _s8(_crew(w, b, 7 + col)))
				7, 8, 9, 10:
					var bit := 1 << (col - 7)
					return _desc(_crew(w, a, 8) & bit, _crew(w, b, 8) & bit)
				_: return 1 if _s8(w.ub(a, 0xC)) >= _s8(w.ub(b, 0xC)) else -1      # 0x46AA20
		PICK:
			if col <= 4:
				return _desc(_s8(_crew(w, a, 9 + col)), _s8(_crew(w, b, 9 + col)))
			var bit := 1 << (col - 5)
			return _desc(_crew(w, a, 8) & bit, _crew(w, b, 8) & bit)
		MACHINE:
			if col == 5:
				return _desc(w.mem8(STOCK_MACH + a), w.mem8(STOCK_MACH + b))
			var f: int = [4, 5, 6, 7, 0x18][col]
			return _desc(w.mem8(MACHS + 31 * a + f), w.mem8(MACHS + 31 * b + f))
		SLOT:
			var la: int = a[0]
			var ra: int = a[1]
			var lb: int = b[0]
			var rb: int = b[1]
			match col:
				0: return _desc((_lb(w, la, 4) + _ab(w, ra, 3)) & 0xFF, (_lb(w, lb, 4) + _ab(w, rb, 3)) & 0xFF)
				1: return _desc(_lb(w, la, 2), _lb(w, lb, 2))
				2: return _desc((_ab(w, ra, 1) + _lb(w, la, 3)) & 0xFF, (_ab(w, rb, 1) + _lb(w, lb, 3)) & 0xFF)
				3: return _desc(_lb(w, la, 5), _lb(w, lb, 5))
				4: return _desc((_lb(w, la, 6) + _ab(w, ra, 2)) & 0xFF, (_lb(w, lb, 6) + _ab(w, rb, 2)) & 0xFF)
				5: return _desc(_ab(w, ra, 4), _ab(w, rb, 4))
				6: return _desc((_sext5(_lb(w, la, 7)) + (_ab(w, ra, 6) & 0x1F)) & 0xFF,
						(_sext5(_lb(w, lb, 7)) + (_ab(w, rb, 6) & 0x1F)) & 0xFF)
				7: return _desc(_s8((_lb(w, la, 8) << 3) & 0xFF), _s8((_lb(w, lb, 8) << 3) & 0xFF))
				8: return 1 if _lb(w, la, 9) & 7 > _lb(w, lb, 9) & 7 else -1
				9: return _desc(w.mem8(STOCK_LAUN + la), w.mem8(STOCK_LAUN + lb))
				10: return _desc(_lb(w, la, 9) & 8, _lb(w, lb, 9) & 8)
				11: return _cap_first(w, ra, rb)
				_:                                                                  # 0x458B10
					var ca := _s8(_ab(w, ra, 0))
					var cb := _s8(_ab(w, rb, 0))
					if ca < 0:
						return 1 if cb >= 0 else 0
					if cb < 0:
						return -1
					return _desc(w.mem8(STOCK_AMMO + ra), w.mem8(STOCK_AMMO + rb))
		_:
			match col:
				0: return _cap_first(w, a, b)
				1: return _desc(_ab(w, a, 1), _ab(w, b, 1))
				2: return _desc(_ab(w, a, 2), _ab(w, b, 2))
				3: return _desc(_ab(w, a, 4), _ab(w, b, 4))
				4: return _desc(_ab(w, a, 6) & 0x1F, _ab(w, b, 6) & 0x1F)
				5: return _desc(_ab(w, a, 7) & 0x1F, _ab(w, b, 7) & 0x1F)
				_: return _desc(w.mem8(STOCK_AMMO + a), w.mem8(STOCK_AMMO + b))
	return -1
