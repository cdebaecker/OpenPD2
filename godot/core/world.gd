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
var phase := 3                  # DS:0x50DDC8: 0 = the player's phase (the mine dialogs)
var memory: PackedByteArray     # AI memory DS:0x551DA0: 40 x 3 B (x, y, 0xFF)
var groups: PackedByteArray     # 64 x 35 B (DS:0x50A35C)
var combat: PackedByteArray     # combat record, 26 x 13 B (DS:0x506B39)
# DS:0x50AD00-0x50ADF4, the mission state block (rules.World.ds): the free-pilot count
# (+0) and list (+2), +0x92 (compared with crew +4), the mission scripts' flags and points,
# the alert (+0xF1) and the end code (+0xF2)
const DS := 0x50AD00
var ds := PackedByteArray()
var crew_pool_n: int:
	get: return ds16(0x50AD00)
	set(v): set_ds16(0x50AD00, v)
var time_ad92: int:
	get: return ds16(0x50AD92)
	set(v): set_ds16(0x50AD92, v)
var mode_663a := 1                   # DS:0x50663A: 1 in the battle (0x487D70 -> 0x436530)
var bombs := PackedByteArray()       # DS:0x50AC1C: timed explosives, 15 x 4 B (x, y, fuse, hook flag)
var mission_turn := 0                # DS:0x50663B (u16): counted by the mission scripts
var ds_506651 := 0                   # DS:0x506651: set by mission inits (read by 0x4361C0)
var exits: Array = []                # DS:0x519FB0: a mission's exit hexes (its load script)
var sensors := PackedByteArray()     # DS:0x50AC58: sensor list, 42 x 4 B (x, y, turns, round)
var grid := PackedByteArray()        # *DS:0x50DD40: the flight engine's 16 x 16 marks (radar display)
var radar := 0                       # DS:0x50DD44: 1 while the radar map is open
var map_chg: Array = []              # MAP_CHG.PCK's entries (PackedByteArray): DASH mission 6's tide
var static_mem := {}                 # exe data the code may read past a table: address -> bytes
var scenario := PackedByteArray()    # DS:0x50DE41: the mission's SCN_MIS record (0x1C6 B, 0x4DD2F0)
var stock := PackedByteArray()       # DS:0x506654: the base's stock (machines, launchers, rounds)
var head := PackedByteArray()        # DS:0x506638-0x506653: the save's head (campaign mode, chunk ..; Debrief)
var reg_unit := PackedByteArray()    # DS:0x50CCEA: reg_unit.dat, the armament screen's ten registers (Equipment)
var exp0 := PackedByteArray()        # DS:0x506B34-0x506B38: record 0's experience counters
var script_no := 0                   # DS:0x50CE72: the mission number (the scripts' tables; the debrief sets it)
var stash: Array = []                # DS:0x50CE73 / 0x50D023: PD2's 27 crews and units while DASH plays
var fire_point := Vector2i(0, 0)  # DS:0x50AD95: the point fire support is called on
var drop_saved := [-1, 0, 0]      # DS:0x514D18 / 0x523E34 / 0x523E38: the unit a transport displaced, its hex
var reinf_saved := [-1, 0, 0]     # DS:0x514E04 / 0x523E48 / 0x523E4C: the unit an arriving member displaced, its hex
var strike_saved := [-1, 0, 0]    # DS:0x51F3B4 / 0x5243B0 / 0x5243B4: the unit a striker flying in displaced, its hex
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
	ds.resize(0xF5)                  # up to the machine table (DS:0x50ADF5)
	bombs.resize(0x3C)
	sensors.resize(0xA8)
	grid.resize(256)


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
	c.strike_saved = strike_saved.duplicate()
	c.reinf_saved = reinf_saved.duplicate()
	c.drop_saved = drop_saved.duplicate()
	c.ds = ds.duplicate()
	c.mode_663a = mode_663a
	c.phase = phase
	c.bombs = bombs.duplicate()
	c.mission_turn = mission_turn
	c.ds_506651 = ds_506651
	c.exits = exits.duplicate()
	c.sensors = sensors.duplicate()
	c.grid = grid.duplicate()
	c.radar = radar
	c.map_chg = map_chg
	c.static_mem = static_mem
	c.scenario = scenario
	c.stock = stock.duplicate()
	c.head = head.duplicate()
	c.reg_unit = reg_unit.duplicate()
	c.exp0 = exp0.duplicate()
	c.script_no = script_no
	c.stash = stash.duplicate()
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
	## (a crew number below 0 or past 63 reads the memory around the table, as the game:
	## the stock and the save head before it; rules.World.crew_of)
	var c := sb(u, 0xB)
	if c < 0 or c * CREW >= crew.size():
		return mem8(0x506734 + CREW * c + f)
	return crew[c * CREW + f]


func set_ucrew(u: int, f: int, v: int) -> void:
	var c := sb(u, 0xB)
	if c < 0 or c * CREW >= crew.size():
		mem_write(0x506734 + CREW * c + f, v)
		return
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


## The byte at DS:addr from the parts of the data segment the world models, in the game's
## layout, for code that reads past a table as the game does (rules.ds_byte): crew
## 0x506734, combat records 0x506B39, units 0x506C93 (255 x 55; those not held read 0),
## groups 0x50A35C, timed explosives 0x50AC1C, sensors 0x50AC58, the DS block 0x50AD00,
## the record set 0x50ADF5 (machines, launchers, ammunition); else static_mem or 0.
func mem8(addr: int) -> int:
	if addr >= 0x506638 and addr < 0x506654 and not head.is_empty():
		return Debrief.head_byte(self, addr - 0x506638)
	if addr >= 0x506B34 and addr < 0x506B39 and not exp0.is_empty():
		return exp0[addr - 0x506B34]
	if addr >= 0x506654 and addr < 0x506654 + stock.size():
		return stock[addr - 0x506654]
	if addr >= 0x506734 and addr < 0x506B34:
		return crew[addr - 0x506734]
	if addr >= 0x506B39 and addr < 0x506C93:
		var o := addr - 0x506B39
		return combat[o] if o < combat.size() else 0
	if addr >= 0x506C93 and addr < 0x50A35C:
		var o := addr - 0x506C93
		return units[o] if o < units.size() else 0
	if addr >= 0x50A35C and addr < 0x50A35C + 64 * 35:
		return groups[addr - 0x50A35C]
	if addr >= 0x50AC1C and addr < 0x50AC58:
		return bombs[addr - 0x50AC1C]
	if addr >= 0x50AC58 and addr < 0x50AD00:
		return sensors[addr - 0x50AC58]
	if addr >= DS and addr < DS + 0xF5:
		return ds[addr - DS]
	if addr >= 0x50ADF5 and addr < 0x50ADF5 + AMMO_BASE + 96 * AMMO:
		return records[addr - 0x50ADF5]
	if addr >= 0x50DE41 and addr < 0x50DE41 + scenario.size():
		return scenario[addr - 0x50DE41]
	if addr >= 0x50CCEA and addr < 0x50CCEA + reg_unit.size():
		return reg_unit[addr - 0x50CCEA]
	for base in static_mem:
		var data: PackedByteArray = static_mem[base]
		if addr >= base and addr < base + data.size():
			return data[addr - base]
	return 0


## Write a byte at DS:addr where the world models it (crew, units, groups, the DS block,
## as rules.ds_write); elsewhere it sets fault.
func mem_write(addr: int, v: int) -> void:
	v &= 0xFF
	if addr >= 0x506638 and addr < 0x506654 and not head.is_empty():
		Debrief.set_head_byte(self, addr - 0x506638, v)
	elif addr >= 0x506B34 and addr < 0x506B39 and not exp0.is_empty():
		exp0[addr - 0x506B34] = v
	elif addr >= 0x506654 and addr < 0x506654 + stock.size():
		stock[addr - 0x506654] = v
	elif addr >= 0x506734 and addr < 0x506B34:
		crew[addr - 0x506734] = v
	elif addr >= 0x506B39 and addr < 0x506C93 and addr - 0x506B39 < combat.size():
		combat[addr - 0x506B39] = v
	elif addr >= 0x506C93 and addr < 0x50A35C and addr - 0x506C93 < units.size():
		units[addr - 0x506C93] = v
	elif addr >= 0x50A35C and addr < 0x50A35C + 64 * 35:
		groups[addr - 0x50A35C] = v
	elif addr >= DS and addr < DS + 0xF5:
		ds[addr - DS] = v
	elif addr >= 0x50CCEA and addr < 0x50CCEA + reg_unit.size():
		reg_unit[addr - 0x50CCEA] = v
	elif addr >= 0x50AC1C and addr < 0x50AC58 and bombs.size() == 0x3C:
		bombs[addr - 0x50AC1C] = v
	elif addr >= 0x50AC58 and addr < 0x50AD00 and sensors.size() == 0xA8:
		sensors[addr - 0x50AC58] = v
	else:
		for base in static_mem:
			var data: PackedByteArray = static_mem[base]
			if addr >= base and addr < base + data.size():
				data[addr - base] = v
				static_mem[base] = data
				return
		fault = "write at DS:0x%X" % addr


# --- helpers named after the game functions (rules.World) --------------------------

func ds8(addr: int) -> int:
	return ds[addr - DS]


func set_ds8(addr: int, v: int) -> void:
	ds[addr - DS] = v & 0xFF


func ds16(addr: int) -> int:
	var v := ds[addr - DS] | ds[addr - DS + 1] << 8
	return v - 0x10000 if v >= 0x8000 else v


func set_ds16(addr: int, v: int) -> void:
	ds[addr - DS] = v & 0xFF
	ds[addr - DS + 1] = (v >> 8) & 0xFF


## the free-pilot list, DS:0x50AD02 + i (a view of the block)
func pool_set(i: int, v: int) -> void:
	if 2 + i < ds.size():
		ds[2 + i] = v & 0xFF


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
	return cover_at(unit_class(u), p.x, p.y)


func cover_at(cls: int, x: int, y: int) -> int:    # cover(cls, tile_at(x, y)), 0x47CD20
	return terrain[608 + 16 * (5 + cls) + terrain[layer(T, x, y)]]


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
