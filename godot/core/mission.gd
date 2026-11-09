class_name Mission
extends RefCounted
## Builds the tactical world of a mission from the imported data (GameData.mission).
## Pd2.exe 0x417030 loads INIT at unit 27 (DS:0x507260): 228 unit records (27-254) and
## the 64 group records that follow the unit table; NPC goes to crew 27-36. The crew
## table starts as Pd2.exe's static data (crews 37-63 are the computer's pilots), with
## the roster (SAVEDATA.ORG) in 0-26. Plus the S / M / H map layers.
##
## The player's own squad is chosen and equipped in the briefing, which is not ported
## yet; sandbox_squad() stands in for it (see engine/README.md).

const UNITS := 255              # 0-254: the group table follows unit 254 (DS:0x50A35C)
const INIT_FIRST := 27
const INIT_UNITS := 228
const CAMPAIGN_FLAG := {"pd2": 1, "dash": 0}   # DS:0x554B10: 1 reads pd2\ (0x408BE0), 0 dash\


static func build(tables: Dictionary, doc: Dictionary, campaign: String) -> Pd2World:
	var w := Pd2World.new(tables.machines, tables.launchers, tables.ammo, doc.S, UNITS)
	w.n_units = 254                # the game's unit loops stop at 253
	var init: PackedByteArray = doc.init
	for i in mini(init.size(), INIT_UNITS * 55):
		w.units[INIT_FIRST * 55 + i] = init[i]
	for i in range(INIT_UNITS * 55, mini(init.size(), INIT_UNITS * 55 + 64 * 35)):
		w.groups[i - INIT_UNITS * 55] = init[i]
	var crew0: PackedByteArray = tables.get("crew", PackedByteArray())
	for i in mini(crew0.size(), 64 * 16):
		w.crew[i] = crew0[i]
	var roster: PackedByteArray = doc.roster
	for i in mini(roster.size(), 27 * 16):
		w.crew[i] = roster[i]
	var npc: PackedByteArray = doc.npc
	for i in mini(npc.size(), 37 * 16 - 27 * 16):
		w.crew[27 * 16 + i] = npc[i]
	if doc.M.size() == 72 * 72:
		w.T = doc.M
	if doc.H.size() == 72 * 72:
		w.H = doc.H
	w.campaign = CAMPAIGN_FLAG.get(campaign, 0)
	rebuild_occupancy(w)
	return w


## 0x483030: the occupancy layer emptied, then every active unit (0-253, in order) written.
static func rebuild_occupancy(w: Pd2World) -> void:
	w.O = PackedByteArray()
	w.O.resize(72 * 72)
	for u in mini(w.units.size() / 55, 254):
		if w.active(u):
			var p := w.pos(u)
			w.O[p.x + 72 * p.y] = (u + 1) & 0xFF


## The end of the mission loader 0x482910: occupancy emptied, F layer cleared but bit 5.
static func layers_reset(w: Pd2World) -> void:
	w.O = PackedByteArray()
	w.O.resize(72 * 72)
	for i in 72 * 72:
		w.F[i] &= 0x20


## 0x437490, a new mission: every unit (0-253) carries nobody and gets its maximum AP.
static func start_units(w: Pd2World) -> void:
	for u in mini(w.units.size() / 55, 254):
		w.setb(u, 0x34, 0xFF)
		w.setb(u, 0xE, Move.max_ap(w, u) & 0xFF)


## 0x429950: parts and every slot's and pocket's state repaired.
static func repair_all(w: Pd2World, u: int) -> void:
	w.setb(u, 1, 0)
	w.setb(u, 2, w.ub(u, 2) & 0xF0)
	for i in 6:
		w.setb(u, 0x10 + 2 * i, w.ub(u, 0x10 + 2 * i) & 0xCF)
	for i in 12:
		w.setb(u, 0x1C + 2 * i, w.ub(u, 0x1C + 2 * i) & 0x3F)


## When mission_loop returns: 0x4373B0 resets every unit (mode 0, not concealed or reacted,
## carrying nobody, +6 = 0, repaired, off the map) and empties the timer lists; 0x4374C0
## marks units 0-39 whose machine has +0x1C set as destroyed.
static func mission_end(w: Pd2World) -> void:
	for u in mini(w.units.size() / 55, 254):
		w.setb(u, 4, w.ub(u, 4) & 0xCF)
		w.setb(u, 0, w.ub(u, 0) & 0x9F)
		w.setb(u, 0x34, 0xFF)
		w.setb(u, 6, 0)
		repair_all(w, u)
		w.setb(u, 9, 0xFF)
		w.setb(u, 10, 0xFF)
	w.bombs.fill(0)
	w.sensors.fill(0)
	for u in 40:
		if w.machine(w.ub(u, 0xC), 0x1C):
			w.setb(u, 0, w.ub(u, 0) | 1)


## Sandbox stand-in for the briefing: `count` DoLLS (crew 1..count, X4 PLDs) take the
## unit slots 0..count-1, equipped like the mission's first enemy PLD, and are dropped on
## the passable hexes farthest from the enemy. Returns their unit indices.
static func sandbox_squad(w: Pd2World, count := 4) -> Array:
	var template := -1
	for u in w.n_units:
		if w.is_enemy(u) and w.active(u) and w.unit_class(u) == 0:
			template = u
			break
	var spots := _drop_zone(w, count)
	var out := []
	for i in count:
		if i >= spots.size():
			break
		var u := i                 # player units 0-26 (the briefing fills them in the game)
		for f in 55:
			w.setb(u, f, w.ub(template, f) if template != -1 else 0)
		w.setb(u, 0, 0x0C)
		w.setb(u, 0xB, 1 + i)
		w.setb(u, 0xC, 0)
		w.setb(u, 0xD, 100)
		w.setb(u, 0x34, 0xFF)
		w.setb(u, 0x36, 0)
		w.setb(u, 3, 0)
		w.setb(u, 4, 0x10)          # normal movement mode
		w.setb(u, 5, 1)
		w.setb(u, 6, 0)
		var p: Vector2i = spots[i]
		w.setb(u, 9, p.x)
		w.setb(u, 10, p.y)
		w.setb(u, 7, p.x)
		w.setb(u, 8, p.y)
		w.setb(u, 0xE, Move.max_ap(w, u))
		out.append(u)
	rebuild_occupancy(w)
	return out


static func _drop_zone(w: Pd2World, count: int) -> Array:
	var enemies := []
	for u in w.n_units:
		if w.is_enemy(u) and w.active(u):
			enemies.append(w.pos(u))
	var best := Vector2i(36, 36)
	var best_d := -1
	for y in range(4, 68, 3):
		for x in range(4, 66, 3):
			if not _free(w, x, y):
				continue
			var d := 999
			for e in enemies:
				d = mini(d, Pd2World.hexdist(x, y, e.x, e.y))
			if d > best_d:
				best_d = d
				best = Vector2i(x, y)
	var out := []
	for p in Ai.spiral(best.x, best.y, 3):
		if _free(w, p.x, p.y) and out.size() < count:
			out.append(p)
	return out


static func _free(w: Pd2World, x: int, y: int) -> bool:
	if not w.on_map(x, y) or w.H[x + 72 * y] == 0 or w.O[x + 72 * y] != 0:
		return false
	return Ai.passable(w, 0, x, y)
