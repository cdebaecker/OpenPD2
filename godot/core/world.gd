class_name Pd2World
extends RefCounted
## Raw game state, laid out like Pd2.exe memory so the rules read it the same way
## (tools/rules.py World). Unit u's field f is units[u * 55 + f].
##   units: N x 55 B (DS:0x506C93; 254 in a mission, 64 in the rules fixtures)
##   crew: 64 x 16 B (DS:0x506734)
##   records: machines 32 x 31 B, launchers 96 x 17 B, ammo 96 x 12 B, contiguous as in
##     Pd2.exe (DS:0x50ADF5): a negative ammo id reads the launchers' tail, as the game does.
##   H / T / F: 72 x 72 layers (height, tile id, flags); terrain: the 976 B S layer.

const MAP := 72
const UNIT := 55
const CREW := 16
const MACH := 31
const LAUN := 17
const AMMO := 12
const LAUN_BASE := 32 * 31
const AMMO_BASE := LAUN_BASE + 96 * 17
const ACE_NAME_IDS := [0, 4, 6, 7]     # Hardy, Fan, Alice, Selma
const CLASS_BY_CATEGORY := [0, 1, 2, 2, 2, 2, 1, 1, 1, 3, 2, 2, 2, 2, 2, 2]   # 0x4538A0
const AA_MODES := [6, 10]

var n_units: int
var units: PackedByteArray
var crew: PackedByteArray
var records: PackedByteArray
var terrain: PackedByteArray
var H: PackedByteArray
var T: PackedByteArray
var F: PackedByteArray
var O: PackedByteArray          # occupancy (unit + 1), 72 x 72; empty = not used
var campaign: int = 0
var memory: PackedByteArray     # AI memory DS:0x551DA0: 40 x 3 B (x, y, 0xFF)
var groups: PackedByteArray     # 64 x 35 B (DS:0x50A35C)
var combat: PackedByteArray     # combat record, 26 x 13 B (DS:0x506B39)
var fire_point := Vector2i(0, 0)  # DS:0x50AD95: the point fire support is called on
var fault := ""                 # set where rules.py raises (division by zero): the game would crash
var events: Array = []          # side effects left to the caller: ["grow", unit, ability, n] ...


func _init(machines: PackedByteArray, launchers: PackedByteArray, ammo: PackedByteArray,
		terrain_: PackedByteArray, n: int = 64) -> void:
	n_units = n
	units = PackedByteArray()
	units.resize(n * UNIT)
	crew = PackedByteArray()
	crew.resize(64 * CREW)
	records = PackedByteArray()
	records.resize(AMMO_BASE + 96 * AMMO)
	for i in min(machines.size(), LAUN_BASE):
		records[i] = machines[i]
	for i in min(launchers.size(), 96 * LAUN):
		records[LAUN_BASE + i] = launchers[i]
	for i in min(ammo.size(), 96 * AMMO):
		records[AMMO_BASE + i] = ammo[i]
	terrain = terrain_
	H = PackedByteArray()
	H.resize(MAP * MAP)
	T = H.duplicate()
	F = H.duplicate()
	memory = PackedByteArray()
	for k in 40:
		memory.append_array([0, 0, 0xFF])
	groups = PackedByteArray()
	groups.resize(64 * 35)
	combat = PackedByteArray()
	combat.resize(26 * 13)


func duplicate_world() -> Pd2World:
	var c := Pd2World.new(PackedByteArray(), PackedByteArray(), PackedByteArray(), terrain, n_units)
	c.units = units.duplicate()
	c.crew = crew.duplicate()
	c.records = records
	c.H = H.duplicate()
	c.T = T.duplicate()
	c.F = F.duplicate()
	c.O = O.duplicate()
	c.campaign = campaign
	c.memory = memory.duplicate()
	c.groups = groups.duplicate()
	c.combat = combat.duplicate()
	c.fire_point = fire_point
	return c


# --- raw access -------------------------------------------------------------------

static func s8(b: int) -> int:
	return b - 256 if b > 127 else b


## C integer division (truncates toward zero); GDScript's int / does the same.
static func cdiv(a: int, b: int) -> int:
	return a / b


## Python's floor division, for the places rules.py uses // on signed values.
static func fdiv(a: int, b: int) -> int:
	var q := a / b
	if (a % b != 0) and ((a < 0) != (b < 0)):
		q -= 1
	return q


## Python's modulo (sign of the divisor).
static func fmod(a: int, b: int) -> int:
	var m := a % b
	if m != 0 and ((m < 0) != (b < 0)):
		m += b
	return m


func ub(u: int, f: int) -> int:
	return units[u * UNIT + f]


func sb(u: int, f: int) -> int:
	return s8(units[u * UNIT + f])


func setb(u: int, f: int, v: int) -> void:
	units[u * UNIT + f] = v & 0xFF


func cb(c: int, f: int) -> int:
	return crew[c * CREW + f]


## crew byte of unit u's crew (crew_of(u)[f])
func ucrew(u: int, f: int) -> int:
	var c := sb(u, 0xB)
	if c < 0:
		c += 64           # Python negative index into the 64-entry crew list
	return crew[c * CREW + f]


func set_ucrew(u: int, f: int, v: int) -> void:
	var c := sb(u, 0xB)
	if c < 0:
		c += 64
	crew[c * CREW + f] = v & 0xFF


## Byte f of crew record c as Pd2.exe reads it for any c (rules.crew_memory): past the
## 64 records the table runs on into the combat records and the units; elsewhere 0.
func crew_memory(c: int, f: int) -> int:
	if c >= 0 and c < 64:
		return crew[c * CREW + f]
	var a := 0x506734 + 16 * c + f
	if a >= 0x506B39 and a < 0x506B39 + 13 * 26:
		return combat[a - 0x506B39]
	if a >= 0x506C93 and a < 0x506C93 + UNIT * (units.size() / UNIT):
		return units[a - 0x506C93]
	return 0


func _rec(o: int) -> int:
	return records[o] if o >= 0 and o < records.size() else 0


func machine(m: int, f: int) -> int:
	return _rec(m * MACH + f)


## Launcher record byte. As rules.py (a Python list), launcher -1 is launcher 95.
func launcher(l: int, f: int) -> int:
	if l < 0:
		l += 96
	return _rec(LAUN_BASE + l * LAUN + f)


## Ammo record byte; a negative id reads the bytes before the table (launcher 95's tail).
func ammo(a: int, f: int) -> int:
	var o := AMMO_BASE + a * AMMO + f
	return records[o] if o >= LAUN_BASE and o < records.size() and f < AMMO else 0


func umachine(u: int, f: int) -> int:
	return machine(ub(u, 0xC), f)


func layer(L: PackedByteArray, x: int, y: int) -> int:
	if L.is_empty():
		return 0
	var i := x + MAP * y
	if i < 0:
		i += L.size()      # Python negative index
	return L[i]


func set_layer(L: String, x: int, y: int, v: int) -> void:
	match L:
		"H": H[x + MAP * y] = v & 0xFF
		"T": T[x + MAP * y] = v & 0xFF
		"F": F[x + MAP * y] = v & 0xFF
		"O": O[x + MAP * y] = v & 0xFF


# --- helpers named after the game functions (rules.World) --------------------------

func is_enemy(u: int) -> bool:                     # 0x47CD40
	return sb(u, 0x36) >= 3


func is_ace(u: int) -> bool:
	return ucrew(u, 0) in ACE_NAME_IDS


func slot_state(u: int, slot: int) -> int:         # 0x47C380
	return (ub(u, 0x10 + 2 * slot) >> 4) & 3 if slot >= 0 and slot < 6 else 0


func slot_count(u: int, slot: int) -> int:         # 0x47C990
	var k := ub(u, 0x10 + 2 * slot) & 15
	var v := ub(u, 0x1C + 2 * k) & 0x3F
	return v - 64 if v & 0x20 else v


func set_slot_count(u: int, slot: int, n: int) -> void:   # 0x47C9F0 (ignores n < 0)
	if n < 0 or slot < 0 or slot > 5:
		return
	var k := ub(u, 0x10 + 2 * slot) & 15
	setb(u, 0x1C + 2 * k, (ub(u, 0x1C + 2 * k) & 0xC0) | (n & 0x3F))


func pocket_ammo(u: int, k: int) -> int:           # 0x47CA90
	return sb(u, 0x1B + 2 * k)


func pocket_count(u: int, k: int) -> int:          # 0x47CAB0
	var v := ub(u, 0x1C + 2 * k) & 0x3F
	return v - 64 if v & 0x20 else v


func pocket_state(u: int, k: int) -> int:          # 0x47CAE0
	return ub(u, 0x1C + 2 * k) >> 6


func unit_class(u: int) -> int:                    # 0x47CC30
	return CLASS_BY_CATEGORY[umachine(u, 0) & 15]


func cover(u: int) -> int:                         # 0x47CD20 at the unit's tile
	var p := pos(u)
	var tile := layer(T, p.x, p.y)
	return terrain[608 + 16 * (5 + unit_class(u)) + terrain[tile]]


func armour(u: int) -> int:                        # 0x47C900
	return umachine(u, 0) >> 4


func launcher_id(u: int, slot: int) -> int:        # 0x47C300
	return sb(u, 0xF + 2 * slot)


func ammo_id(u: int, slot: int) -> int:            # 0x47C930
	var k := ub(u, 0x10 + 2 * slot) & 15
	return sb(u, 0x1B + 2 * k)


func warhead(u: int, slot: int) -> int:            # 0x47C690
	return ammo(ammo_id(u, slot), 8) & 15


func pos(u: int) -> Vector2i:
	return Vector2i(sb(u, 9), sb(u, 10))


func on_map(x: int, y: int) -> bool:               # 0x480240
	return 0 < x and x < 71 - (y & 1) and 0 < y and y < 71


func active(u: int) -> bool:                       # 0x482FD0
	var f0 := ub(u, 0)
	var p := pos(u)
	return on_map(p.x, p.y) and (f0 & 8) != 0 and ub(u, 0xD) != 0 and not (f0 & 1) and (f0 & 4) != 0


func weapon_range(u: int, slot: int) -> int:       # 0x450890
	var lid := launcher_id(u, slot)
	if lid == -1:
		return 0
	return (ammo(ammo_id(u, slot), 3) + launcher(lid, 4)) & 0xFF


static func hexdist(sx: int, sy: int, tx: int, ty: int) -> int:   # 0x47D8C0
	var dy := ty - sy
	var dx := tx - sx
	var ady := absi(dy)
	if sy & 1:
		if ady & 1 and dx < 0:
			dx -= 1
	elif ady & 1 and dx > 0:
		dx += 1
	var d := absi(dx) - ((ady + 1) >> 1)
	return ady + (d if d > 0 else 0)


static func skill_table(a: int, kind: int) -> int:   # 0x412EF0
	var m := absi(a) * (absi(a) + 1)
	if kind == 1:
		m /= 2
	return m if a >= 0 else -m
