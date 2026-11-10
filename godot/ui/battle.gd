extends Node2D
## The tactical battle, sandbox edition: one mission's map and enemy force (INIT), a
## stand-in squad (Mission.sandbox_squad), the player's commands and the computer's
## whole turn, all through the ported rules in core/. What is not ported yet (briefing,
## event scripts, magazine swaps) is replaced by the simplest
## stand-in and listed in engine/README.md.

const TILE_W := 48
const TILE_H := 36
const MAP := 72

var campaign := "dash"
var mission_index := 0
## The campaign's state a debrief hands to the next mission (game_mode_loop 0x487D70: the
## save, savedata.tmp, read back by the next mission start 0x416CF0): the save image, the
## mission number DS:0x50CE72 and PD2's kept crews and units (DS:0x50CE73, not saved).
static var carry := {}
var debrief_panel: PanelContainer = null
var debrief_result := -1        # the debrief's code (0x80 next mission, 0x81 the title), -1 none yet

var w: Pd2World
var rng: Pd2Random
var hooks: SandboxHooks
var squad: Array = []
var sandbox := false            # the stand-in squad (no player group formed)
var names := {}
var selected := -1
var mode := "move"          # move / fire / aimed
var move_mode := 1          # 0 high speed, 1 normal, 2 careful
var slot := 0
var item_pocket := 0     # the pocket the item command uses (mode "item")
var mm: Move.MoveMap = null
var fire_map: Move.MoveMap = null
var carry_hexes: Array = []
var move_dests: Array = []
var move_thread: Thread = null
var turn := 1
var alert: int:            # DS:0x50ADF1, the alert (in the DS block)
	get: return w.ds8(0x50ADF1) if w else 0
	set(v): w.set_ds8(0x50ADF1, v)
var script_no := 0          # DS:0x50CE72
var mission_hooks: BattleMissionHooks
var flight_hooks: BattleFlightHooks
var mission_over := false
var options := 0            # DS:0x551D29 (bit 1 easy, bit 5 training, bit 7 see all): none in the sandbox
var busy := false
## The computer's turn runs on a worker thread so that the player's reaction menu can
## pause it; auto_react answers the menu without asking (tests, headless runs).
var auto_react := false
var react_policy := Callable()     # auto_react's answers (tests); default: strongest weapon
var ai_thread: Thread = null
var ai_running := false
var react_sem := Semaphore.new()
var react_answer: Variant = 1
var hex_pick: Array = []         # the hexes a question on the worker thread waits a click on
var react_panel: PanelContainer = null
var react_target := -1
var react_menu: Array = []
var hover := Vector2i(-1, -1)
var last_ai_result := 0

var cam: Camera2D
var overlay: Node2D
var info: Label
var log_box: RichTextLabel
var hud_layer: CanvasLayer
var slot_buttons: Array = []


class SandboxHooks extends AiTurnHooks:
	## The game's hooks for a live battle: reaction fire by the other side (the
	## computer's rule for both sides: the player's reaction menu is not ported),
	## melee, unit removal, mine blasts.
	var battle
	var flag := 0

	func react(u: int) -> int:
		var reactors := Sight.reaction_candidates(w, u, battle.alert, w.n_units)
		if reactors.is_empty():
			return 0
		var t := u
		var f := flag
		if w.is_enemy(u):
			# the player's units react: the game's menu loop (Action.player_reactions), with
			# an automatic answer until the battle can pause the computer's turn for a menu
			var mode := 10 if w.unit_class(t) >= 2 else 5
			if not battle.auto_react:
				var ask := func(menu: Array, tt: int) -> Variant: return battle.ask_reaction(menu, tt, mode)
				return Action.player_reactions(w, rng, reactors, t, f, ask, self, easy)
			if battle.react_policy.is_valid():
				return Action.player_reactions(w, rng, reactors, t, f, battle.react_policy, self, easy)
			var choose := func(menu: Array, tt: int) -> Variant:
				var tp := w.pos(tt)
				for b in menu:
					var bp := w.pos(b)
					var best := -1
					var best_atk := 0
					for s in Action.weapon_choices(w, b, mode, Pd2World.hexdist(bp.x, bp.y, tp.x, tp.y)):
						if s < 4:
							var atk := Move.final_attack(w, b, s, mode == 10)
							if atk > best_atk:
								best = s
								best_atk = atk
					if best != -1:
						battle.say("%s reacts at %s" % [battle.unit_name(b), battle.unit_name(tt)])
						return [b, [best]]
				return 1
			return Action.player_reactions(w, rng, reactors, t, f, choose, self, easy)
		var shot := func(b: int, s: int) -> int:
			battle.say("%s reacts at %s" % [battle.unit_name(b), battle.unit_name(t)])
			return Action.reaction_shot(w, rng, b, s, t, f, self, easy)
		return Move.ai_reactions(w, rng, reactors, u, flag, shot)

	func melee(u: int, o: int) -> int:
		var res := Melee.melee(w, rng, u, o, battle.alert, easy)
		battle.say("%s charges %s: %s" % [battle.unit_name(u), battle.unit_name(o),
			["the defender falls", "both stand", "the attacker falls", "both fall"][res]])
		return res

	func destroy(k: int) -> void:
		Action.destroy(w, k)                       # 0x480140, emulated
		battle.say("[color=orange]%s destroyed[/color]" % battle.unit_name(k))

	func mine_blast(x: int, y: int) -> void:
		battle.say("mine explodes at %d, %d" % [x, y])

	func intercept_choice(t: int, best: int) -> int:
		## intercept (0x4149F0) for a player unit: "intercept the missile?" (0x1E5: the
		## pilot's given and family names, the machine's name), then the weapon picker in
		## mode 7 until a slot or a cancel. auto_react (tests): the best slot.
		if battle.auto_react:
			return best
		if not battle.ask_prompt(battle.msg(0x1E5, battle.intercept_names(t)), false):
			return -1
		var opts := []
		for s in Action.weapon_choices(w, t, 7, 0):
			if s < 4:
				opts.append([battle.ui("UI_SLOT_ROUNDS") % [s + 1, w.slot_count(t, s)], s])
		opts.append([battle.ui("UI_CANCEL"), -2])
		var pick: int = battle.ask_choice(battle.ui("UI_PICK_WEAPON"), opts, -2)
		return -1 if pick == -2 else pick

	# the player's move command and its mine dialogs; they run on the move's worker
	# thread and wait for the answer (auto_react: the defaults, without asking)
	func confirm(msg: int, args: Array) -> bool:
		return battle.ask_prompt(battle.msg(msg, args), true)

	func use_weapon(a: int, p: int) -> bool:
		return battle.ask_prompt(battle.msg(0x1A7), true)       # melee's own prompt (0x424490)

	func mine_found(u: int) -> void:
		battle.say_msg(0x1A6)

	func mine_clear(u: int, msg := 0x1A3) -> bool:
		return battle.ask_box(battle.msg(msg), false)

	func mine_shoot(u: int) -> Variant:
		if not battle.ask_box(battle.msg(0x1A4), false):
			return null
		var opts := []
		for s in Action.weapon_choices(w, u, 3, 0):
			if s < 4:
				opts.append([battle.ui("UI_SLOT_ROUNDS_AP") % [s + 1, w.slot_count(u, s),
					Move.launcher_ap(w, w.launcher_id(u, s))], s])
		opts.append([battle.ui("UI_CANCEL"), -2])
		var pick: int = battle.ask_choice(battle.ui("UI_PICK_WEAPON"), opts, -2)
		if pick != -2:
			battle.say_msg(0x1A5)
		return [pick]


func _ready() -> void:
	var tables := GameData.tables(campaign)
	var doc := GameData.mission(campaign, mission_index)
	# a campaign's first mission starts a new campaign (0x421B90): the pilot choice answered
	# with its "fill at random" (rand() seeded from the clock, as 0x48F7A0 does)
	var save := GameData.save_image(campaign)
	var pick: Campaign.Hooks = Campaign.Hooks.new() if mission_index == 0 else null
	var crt := Campaign.CrtRand.new(int(Time.get_unix_time_from_system()))
	var carried := carry
	carry = {}
	if not carried.is_empty():
		save = [Debrief.SAVE_BASE, carried.image]     # the debrief's save: no new campaign
		pick = null
	# PD2's first mission starts as the title's new game does (0x46D780 "0"); DASH's start
	# (the title's other entries) is not ported: its SAVEDATA.ORG as it is
	w = Mission.build(tables, doc, campaign, save, pick, crt, carried.is_empty() and pick != null and campaign == "pd2")
	# DS:0x50CE72, the mission number (0x46D780): PD2 chunks are 1-10, DASH chunks 11-22;
	# after a debrief, the number it set
	script_no = mission_index + (1 if campaign == "pd2" else 11)
	if not carried.is_empty():
		script_no = int(carried.script)
		w.stash = carried.stash
	w.script_no = script_no
	mission_hooks = BattleMissionHooks.new()
	mission_hooks.battle = self
	flight_hooks = BattleFlightHooks.new()
	flight_hooks.battle = self
	flight_hooks.easy = options & 2 != 0
	if script_no == 1:
		MissionScripts.m01_init(w)           # in the game the pre-battle screen runs it (0x4DD2F0)
		for p in doc.get("exits", []):       # its load script's exit table (0x519FE8)
			w.exits.append(Vector2i(int(p[0]), int(p[1])))
	w.phase = 0
	rng = Pd2Random.new(int(Time.get_ticks_usec()) & 0xFFFF)
	hooks = SandboxHooks.new(w, false, rng)
	hooks.battle = self
	names = {"crew": tables.crew_names, "machine": tables.machine_names}
	var tex := GameData.map_texture(campaign, mission_index)
	if tex:
		var s := Sprite2D.new()
		s.texture = tex
		s.centered = false
		add_child(s)
	overlay = Node2D.new()
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	cam = Camera2D.new()
	cam.zoom = Vector2(0.5, 0.5)
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = MAP * TILE_W + TILE_W / 2
	cam.limit_bottom = MAP * TILE_H
	add_child(cam)
	_build_hud()
	_sortie()


func _begin_battle() -> void:
	# the sortie's squad: the player's groups as the sortie screen left them; with none
	# formed (the sortie refused, or left) the stand-in squad
	squad = Mission.player_units(w)
	sandbox = squad.is_empty()
	if sandbox:
		squad = Mission.sandbox_squad(w, 4)
	# a new mission (mission_loop 0x436690 with DS:0x50AD94 = 0): the loader's layer reset
	# (0x482910), start_units (0x437490), [mission script stage 2: not ported], the
	# occupancy rebuilt (0x483030), [the mission's start script: not ported], the player's
	# upkeep and AP, then the turn start (LAB_00436b39)
	w.set_ds8(0x50ADF2, 0)               # mission_loop clears the end code first
	Mission.layers_reset(w)
	Mission.start_units(w)
	_script_turn(2)
	if w.ds8(0x50ADF2):                  # the end code after the start script: the mission ends
		_end_mission(w.ds8(0x50ADF2))
		return
	Mission.rebuild_occupancy(w)
	w.phase = 0
	Turn.turn_upkeep(w, rng, Turn.PHASE_PLAYER)
	Turn.refill_ap(w, Turn.PHASE_PLAYER)
	w.phase = 3
	if auto_react or not Drop.pending(w):
		_turn_start()
		_begin_done()
		return
	# a transport waits for the player: the first turn start runs on a worker thread
	busy = true
	ai_thread = Thread.new()
	ai_thread.start(func():
		_turn_start()
		call_deferred("_begin_finished"))


func _begin_finished() -> void:
	ai_thread.wait_to_finish()
	ai_thread = null
	busy = false
	_begin_done()


func _begin_done() -> void:
	var landed := squad.filter(func(u): return w.active(u))
	if not landed.is_empty():
		_select(landed[0])
		cam.position = hex_center(w.pos(landed[0]))
	if sandbox:
		say("Turn 1. %d DoLLS dropped; %d enemy units on the map." % [squad.size(), _count_side(3)])
	else:
		say("Turn 1. %d DoLLS in the sortie, %d on the map; %d enemy units." % [squad.size(), landed.size(), _count_side(3)])


# --- the sortie screen (0x45ED60) ----------------------------------------------------

class BattleSortieHooks extends Campaign.SortieHooks:
	## The sortie screen's windows in the battle: its dialogs and refusals go to the panel
	## (MES.PCK texts). The mission's deploy hook (table 0x51EC68, called only by the sortie
	## screen, 0x460D60): mission 1's (0x499480) wants group 0 or 2 formed and clear, else
	## its dialog 0x12B and a refusal; the other missions' are not ported and pass.
	var battle

	func deploy() -> int:
		if battle.script_no != 1 or MissionScripts.m01_state(battle.w) == 1:
			return 1
		battle.sortie_say(battle.mes(0x12B))
		return MissionScripts.m01_state_result(0)

	func dialog(msg: int, arg: Array) -> int:
		battle.sortie_say(battle.mes(msg, [battle.sortie_arg(arg), ""]))
		return 0

	func note(code: int, who: int) -> int:
		battle.sortie_say(battle.mes(code + 0x20, [battle.group_name(who)]))
		return 0


var sortie_hooks: BattleSortieHooks
var sortie_window := true       # false: the sortie screen presses start at once (tests)
var sortie_sel := 0
var sortie_panel: PanelContainer
var hud_panel: PanelContainer        # the command bar, hidden while the sortie screen is up
var sortie_text := ""
const JOIN_MESSAGES := {1: 0x1D8, 2: 0x1D7, 3: 0x1D6, 4: 0x1D5, 5: 0x1D4, 6: 0x1D3, 7: 0x1DB, 8: 0x1DC}


func mes(id: int, args := []) -> String:
	## a base-screen message (MES.PCK), translated and formatted
	return GameData.base_text(campaign, id, args, mission_index).replace("@", "").replace("
", "
").strip_edges()


func group_name(g: int) -> String:
	## a group's name: entry +0 of the table at DS:0x50C881 (the call signs' second part)
	return GameData.call_sign(campaign, 39 + Flight.gb(w, g, 0))


func sortie_arg(arg: Array) -> String:
	if arg.is_empty():
		return ""
	return GameData.call_sign(campaign, arg[1] + (39 if arg[0] == "name" else 0))


func sortie_say(t: String) -> void:
	sortie_text = t


func _sortie() -> void:
	## The sortie screen before the battle: the formable groups (+2 bit 0), their members
	## and the free pilots; join, drop, start (the game's checks, then "start the
	## operation?"). Without a window (auto_react, sortie_window false) it presses start once.
	sortie_hooks = BattleSortieHooks.new()
	sortie_hooks.battle = self
	if auto_react or not sortie_window:
		Campaign.sortie_screen(w, sortie_hooks, [["start"]])
		_begin_battle()
		return
	Campaign.sortie_open(w)
	sortie_sel = 0
	for g in 20:
		if Flight.gb(w, g, 2) & 1 and (g >= 12 or g % 2 == 0):
			sortie_sel = g
			break
	_sortie_draw()


func _sortie_draw(confirm := false) -> void:
	if sortie_panel:
		sortie_panel.queue_free()
	sortie_panel = PanelContainer.new()
	var theme := Theme.new()
	theme.default_font_size = 8
	sortie_panel.theme = theme
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.12, 0.97)
	bg.set_content_margin_all(8)
	sortie_panel.add_theme_stylebox_override("panel", bg)
	sortie_panel.position = Vector2(16, 16)
	if hud_panel:
		hud_panel.visible = false
	var box := VBoxContainer.new()
	sortie_panel.add_child(box)
	var title := Label.new()
	title.text = ui("UI_SORTIE")
	box.add_child(title)
	var cols := HBoxContainer.new()
	box.add_child(cols)
	var groups_box := VBoxContainer.new()
	cols.add_child(groups_box)
	for g in 20:
		if not Flight.gb(w, g, 2) & 1 or (g < 12 and g % 2 == 1):
			continue
		var b := Button.new()
		b.text = "%s%s (%d)" % ["> " if g == sortie_sel else "", group_name(g), Flight.gb(w, g, 5)]
		b.pressed.connect(func(): sortie_sel = g; _sortie_draw())
		groups_box.add_child(b)
	var members := VBoxContainer.new()
	cols.add_child(members)
	var ml := Label.new()
	ml.text = group_name(sortie_sel)
	members.add_child(ml)
	for i in Flight.gb(w, sortie_sel, 5):
		var k := Flight.gb(w, sortie_sel, 6 + i)
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = unit_name(k)
		row.add_child(lbl)
		var arm := Button.new()
		arm.text = ui("UI_ARM")
		arm.pressed.connect(_equip_begin.bind(k))
		row.add_child(arm)
		var d := Button.new()
		d.text = ui("UI_DROP")
		d.pressed.connect(func():
			if Campaign.sortie_drop(w, sortie_sel, k) == 1:
				sortie_say(mes(0x1CE))
			_sortie_draw())
		row.add_child(d)
		members.add_child(row)
	var pool := VBoxContainer.new()
	cols.add_child(pool)
	var pl := Label.new()
	pl.text = ui("UI_SORTIE_POOL")
	pool.add_child(pl)
	for i in w.crew_pool_n:
		var c: int = w.ds[2 + i]
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = unit_name(c)
		row.add_child(lbl)
		var arm := Button.new()
		arm.text = ui("UI_ARM")
		arm.pressed.connect(_equip_begin.bind(c))
		row.add_child(arm)
		var j := Button.new()
		j.text = ui("UI_JOIN")
		j.pressed.connect(func():
			var code := Campaign.group_join(w, sortie_sel, c)
			sortie_say(mes(JOIN_MESSAGES[code]) if JOIN_MESSAGES.has(code) else "")
			_sortie_draw())
		row.add_child(j)
		pool.add_child(row)
	if sortie_text != "":
		var msg := Label.new()
		msg.text = sortie_text
		box.add_child(msg)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	if confirm:
		var q := Label.new()
		q.text = mes(0x1C)
		buttons.add_child(q)
		for yes in [true, false]:
			var b := Button.new()
			b.text = ui("UI_YES") if yes else ui("UI_NO")
			b.pressed.connect(func():
				Campaign.sortie_start(w, yes)
				if yes:
					sortie_panel.queue_free()
					sortie_panel = null
					hud_panel.visible = true
					_begin_battle()
				else:
					_sortie_draw())
			buttons.add_child(b)
	else:
		var st := Button.new()
		st.text = ui("UI_START")
		st.pressed.connect(func():
			sortie_text = ""
			var r := Campaign.sortie_check(w, sortie_hooks)
			_sortie_draw(r[0] == "start"))
		buttons.add_child(st)
	hud_layer.add_child(sortie_panel)


# --- the armament screen (0x454E60) ---------------------------------------------------

class EquipDriveHooks extends Equipment.Hooks:
	## Answers the screen's lists and questions from a queue; past its end it records the
	## request and cancels (lists -2, questions 0): a dry run finds the next question.
	var answers: Array
	var request: Variant = null
	var notes: Array = []

	func _init(a: Array) -> void:
		answers = a.duplicate()

	func pick(kind: String, entries: Array) -> int:
		if not answers.is_empty():
			return answers.pop_front()
		if request == null:
			request = ["pick", kind, entries]
		return -2

	func ask(msg: int) -> int:
		if not answers.is_empty():
			return answers.pop_front()
		if request == null:
			request = ["ask", msg]
		return 0

	func note(msg: int) -> int:
		notes.append(msg)
		return 0


var equip_sess: Dictionary = {}
var equip_button: Variant = null     # the button being answered
var equip_answers: Array = []
var equip_request: Variant = null
var equip_text := ""
const PICK_OFFSET := {"machine": 6, "slot": 0xD, "item": 7, "pocket": 0}


func _equip_begin(k: int) -> void:
	equip_sess = Equipment.open(w, k)
	equip_button = null
	equip_text = ""
	_equip_draw()


func _equip_press(b: Variant) -> void:
	equip_button = b
	equip_answers = []
	equip_text = ""
	_equip_advance()


func _equip_answer(a: int) -> void:
	equip_answers.append(a)
	_equip_advance()


func _equip_advance() -> void:
	## dry-run the button with the answers so far; a new question shows, else it runs
	var dry := w.duplicate_world()
	var ds := equip_sess.duplicate(true)
	var dh := EquipDriveHooks.new(equip_answers)
	Equipment.step(dry, ds, dh, equip_button)
	equip_request = dh.request
	if equip_request == null:
		var hk := EquipDriveHooks.new(equip_answers)
		Equipment.step(w, equip_sess, hk, equip_button)
		equip_button = null
		var lines := []
		for n in hk.notes:
			lines.append(mes(n))
		equip_text = "\n".join(lines)
		if equip_sess.done:
			equip_sess = {}
			_sortie_draw()
			return
	else:
		var lines := []
		for n in dh.notes:
			lines.append(mes(n))
		equip_text = "\n".join(lines)
	_equip_draw()


func _name_of(table: String, id: int) -> String:
	var t: Dictionary = GameData.tables(campaign).get(table, {})
	return str(t.get(str(id), "#%d" % id))


func _equip_entry_text(kind: String, e: Variant) -> String:
	if e is String:
		return ui("UI_REMOVE") if e == "remove" else ui("UI_ITEM")
	match kind:
		"machine":
			var mn: Array = names.machine
			return "%s (%s)" % [mn[e] if e < mn.size() else "#%d" % e, ui("UI_STOCK") % w.mem8(Equipment.STOCK_MACH + e)]
		"slot":
			return "%s / %s (%s, %s)" % [_name_of("launcher_names", e[0]), _name_of("ammo_names", e[1]),
				ui("UI_STOCK") % w.mem8(Equipment.STOCK_LAUN + e[0]), ui("UI_STOCK") % w.mem8(Equipment.STOCK_AMMO + e[1])]
		"pocket":
			return ui("UI_MAGAZINE") % _name_of("launcher_names", Flight.s8(e[1]))
		_:
			return "%s (%s)" % [_name_of("ammo_names", e), ui("UI_STOCK") % w.mem8(Equipment.STOCK_AMMO + e)]


func _equip_draw() -> void:
	if sortie_panel:
		sortie_panel.queue_free()
	sortie_panel = PanelContainer.new()
	var theme := Theme.new()
	theme.default_font_size = 8
	sortie_panel.theme = theme
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.12, 0.97)
	bg.set_content_margin_all(8)
	sortie_panel.add_theme_stylebox_override("panel", bg)
	sortie_panel.position = Vector2(16, 16)
	var box := VBoxContainer.new()
	sortie_panel.add_child(box)
	var k: int = equip_sess.k
	var title := Label.new()
	title.text = "%s: %s" % [ui("UI_ARMAMENT"), unit_name(k)]
	box.add_child(title)
	var m := Flight.s8(w.ub(k, 0xC))
	var rows := VBoxContainer.new()
	box.add_child(rows)
	var add_row := func(label: String, btn: String, b: Variant) -> void:
		var row := HBoxContainer.new()
		var bt := Button.new()
		bt.text = btn
		bt.disabled = equip_request != null
		bt.pressed.connect(_equip_press.bind(b))
		row.add_child(bt)
		var l := Label.new()
		l.text = label
		row.add_child(l)
		rows.add_child(row)
	var mn: Array = names.machine
	add_row.call(mn[m] if m >= 0 and m < mn.size() else ui("UI_EMPTY"), ui("UI_MACHINE"), "machine")
	if m >= 0:
		for s in 6:
			var lid := Flight.s8(w.ub(k, 0xF + 2 * s))
			var txt := ui("UI_EMPTY")
			if lid != -1:
				var p := w.ub(k, 0x10 + 2 * s) & 0xF
				var a := Flight.s8(w.ub(k, 0x1B + 2 * p))
				txt = "%s / %s" % [_name_of("launcher_names", lid), _name_of("ammo_names", a) if a != -1 else "-"]
			add_row.call(txt, ui("UI_SLOT") % (s + 1), ["slot", s])
		for p in mini(w.mem8(Equipment.MACHS + 31 * m + 0x17), 6):
			var a := Flight.s8(w.ub(k, 0x1B + 2 * p))
			add_row.call(_name_of("ammo_names", a) if a != -1 else ui("UI_EMPTY"), ui("UI_POCKET") % (p + 1), ["pocket", p])
	if equip_text != "":
		var msg := Label.new()
		msg.text = equip_text
		box.add_child(msg)
	if equip_request != null:
		var q := VBoxContainer.new()
		box.add_child(q)
		if equip_request[0] == "ask":
			var l := Label.new()
			l.text = mes(equip_request[1])
			q.add_child(l)
			var hb := HBoxContainer.new()
			q.add_child(hb)
			for yes in [true, false]:
				var bt := Button.new()
				bt.text = ui("UI_YES") if yes else ui("UI_NO")
				bt.pressed.connect(_equip_answer.bind(1 if yes else 0))
				hb.add_child(bt)
		else:
			var kind: String = equip_request[1]
			var ents: Array = equip_request[2]
			for j in ents.size():
				var bt := Button.new()
				bt.text = _equip_entry_text(kind, ents[j])
				bt.pressed.connect(_equip_answer.bind(PICK_OFFSET[kind] + j))
				q.add_child(bt)
			var cb := Button.new()
			cb.text = ui("UI_CANCEL")
			cb.pressed.connect(_equip_answer.bind(-2))
			q.add_child(cb)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for pair in [["UI_CLEAR", "clear"], ["UI_UNDO", "undo"], ["UI_CLOSE", "close"]]:
		var bt := Button.new()
		bt.text = ui(pair[0])
		bt.disabled = equip_request != null
		bt.pressed.connect(_equip_press.bind(pair[1]))
		buttons.add_child(bt)
	hud_layer.add_child(sortie_panel)


# --- geometry --------------------------------------------------------------------

static func hex_center(p: Vector2i) -> Vector2:
	return Vector2(p.x * TILE_W + TILE_W / 2 + (TILE_W / 2 if p.y & 1 else 0), p.y * TILE_H + TILE_H / 2)


static func hex_at(pt: Vector2) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := 1e9
	var ry := int(floor(pt.y / TILE_H))
	for y in range(ry - 1, ry + 2):
		var rx := int(floor((pt.x - (TILE_W / 2 if y & 1 else 0)) / TILE_W))
		for x in range(rx - 1, rx + 2):
			var d := hex_center(Vector2i(x, y)).distance_squared_to(pt)
			if d < bd:
				bd = d
				best = Vector2i(x, y)
	return best


# --- HUD -------------------------------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	hud_layer = layer
	add_child(layer)
	var panel := PanelContainer.new()
	hud_panel = panel
	panel.position = Vector2(4, 4)
	var theme := Theme.new()
	theme.default_font_size = 8
	panel.theme = theme
	panel.modulate = Color(1, 1, 1, 0.92)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	info = Label.new()
	info.custom_minimum_size = Vector2(200, 0)
	box.add_child(info)
	var row := HBoxContainer.new()
	box.add_child(row)
	for b in [["Move [M]", "move"], ["Fire [F]", "fire"], ["Aimed [A]", "aimed"], ["Anti-air [Q]", "aa"]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(_set_mode.bind(b[1]))
		row.add_child(btn)
	var row2 := HBoxContainer.new()
	box.add_child(row2)
	for i in 3:
		var btn := Button.new()
		btn.text = ["High speed", "Normal", "Careful"][i]
		btn.pressed.connect(_set_move_mode.bind(i))
		row2.add_child(btn)
	var row3 := HBoxContainer.new()
	box.add_child(row3)
	for i in 4:
		var btn := Button.new()
		btn.text = "Slot %d" % (i + 1)
		btn.pressed.connect(_set_slot.bind(i))
		row3.add_child(btn)
		slot_buttons.append(btn)
	var row4 := HBoxContainer.new()
	box.add_child(row4)
	var cmds := [["Search [S]", _cmd_search], ["Conceal [C]", _cmd_conceal], ["Carry / release [K]", _cmd_carry_mode],
			[ui("UI_ITEM_USE") + " [U]", _cmd_item_mode],
			["Next [Tab]", _next_unit], ["End turn [E]", _end_turn], [ui("UI_WITHDRAW") + " [W]", _cmd_withdraw]]
	if script_no == 1:
		cmds.append([ui("UI_INDOOR_SEARCH") + " [I]", _cmd_mission])
	for b in cmds:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(b[1])
		row4.add_child(btn)
	var back := Button.new()
	back.text = "Back to missions"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/boot.tscn"))
	box.add_child(back)
	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.custom_minimum_size = Vector2(200, 110)
	box.add_child(log_box)


func say(t: String) -> void:
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		call_deferred("say", t)
		return
	if log_box:
		log_box.append_text(t + "\n")


func unit_name(u: int) -> String:
	var c := w.ucrew(u, 0)
	var crew_names: Array = names.crew
	var nm := ""
	if not w.is_enemy(u) and c < crew_names.size():
		nm = "".join(crew_names[c])
	var mach: Array = names.machine
	var m := w.ub(u, 0xC)
	var mn: String = mach[m] if m < mach.size() else "?"
	return ("%s (%s)" % [nm, mn]) if nm != "" else ("#%d %s" % [u, mn])


func _refresh_info() -> void:
	if selected == -1:
		info.text = "No unit selected"
		return
	var u := selected
	var lines := [unit_name(u),
		"Condition %d   AP %d / %d   %s" % [w.ub(u, 0xD), w.sb(u, 0xE), Move.max_ap(w, u), ["high speed", "normal", "careful", "searching"][(w.ub(u, 4) >> 4) & 3]],
		"Command: %s   move mode: %s" % [mode, ["high speed", "normal", "careful"][move_mode]]]
	for k in 4:
		var lid := w.launcher_id(u, k)
		var txt := "-"
		if lid != -1:
			txt = "range %d  AP %d  rounds %d" % [w.weapon_range(u, k), Move.launcher_ap(w, lid), w.slot_count(u, k)]
		lines.append(("> " if k == slot else "  ") + "Slot %d: %s" % [k + 1, txt])
	lines.append("Turn %d" % turn)
	info.text = "\n".join(lines)


# --- input -----------------------------------------------------------------------

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		if ev.button_mask & MOUSE_BUTTON_MASK_RIGHT or ev.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			cam.position = (cam.position - ev.relative / cam.zoom).clamp(Vector2.ZERO, Vector2(MAP * TILE_W, MAP * TILE_H))
		hover = hex_at(get_global_mouse_position())
		overlay.queue_redraw()
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom = (cam.zoom * 1.15).clamp(Vector2(0.15, 0.15), Vector2(3, 3))
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom = (cam.zoom / 1.15).clamp(Vector2(0.15, 0.15), Vector2(3, 3))
		elif ev.button_index == MOUSE_BUTTON_LEFT and not hex_pick.is_empty():
			var h := hex_at(get_global_mouse_position())
			if h in hex_pick or hex_pick == ["any"]:
				_answer_hex(h)
		elif ev.button_index == MOUSE_BUTTON_LEFT and not busy:
			_click(hex_at(get_global_mouse_position()))
	elif ev is InputEventKey and ev.pressed and not ev.echo and not busy:
		match ev.keycode:
			KEY_M: _set_mode("move")
			KEY_F: _set_mode("fire")
			KEY_A: _set_mode("aimed")
			KEY_Q: _set_mode("aa")
			KEY_S: _cmd_search()
			KEY_C: _cmd_conceal()
			KEY_K: _cmd_carry_mode()
			KEY_U: _cmd_item_mode()
			KEY_E: _end_turn()
			KEY_W: _cmd_withdraw()
			KEY_I: _cmd_mission()
			KEY_TAB: _next_unit()
			KEY_1, KEY_2, KEY_3, KEY_4: _set_slot(ev.keycode - KEY_1)


func _set_mode(m: String) -> void:
	mode = m
	_update_move_map()


func _set_move_mode(i: int) -> void:
	move_mode = i
	_update_move_map()


func _set_slot(i: int) -> void:
	slot = i
	_update_move_map()


func _select(u: int) -> void:
	selected = u
	slot = 0
	for k in 4:
		if w.launcher_id(u, k) != -1:
			slot = k
			break
	_update_move_map()


func _update_move_map() -> void:
	mm = null
	fire_map = null
	move_dests = []
	if selected != -1 and w.active(selected):
		mm = Move.move_map(w, selected, move_mode)
		if Action.move_refusal(w, selected) == -1:
			move_dests = Action.move_destinations(w, selected, mm)
		if mode in FIRE_MODES and w.launcher_id(selected, slot) != -1:
			fire_map = Action.fire_target_map(w, selected, slot, FIRE_MODES[mode])
		elif mode == "item" and w.pocket_ammo(selected, item_pocket) != -1:
			fire_map = Action.fire_target_map(w, selected, 0x80 + item_pocket, 0)
	_refresh_info()
	overlay.queue_redraw()


func _next_unit() -> void:
	var alive := squad.filter(func(u): return w.active(u))
	if alive.is_empty():
		return
	var i := alive.find(selected)
	_select(alive[(i + 1) % alive.size()])
	cam.position = hex_center(w.pos(selected))


func _click(h: Vector2i) -> void:
	if not w.on_map(h.x, h.y):
		return
	var o := w.O[h.x + MAP * h.y] - 1
	if o != -1 and o in squad and (mode == "move" or o == selected):
		_select(o)
		return
	if selected == -1 or not w.active(selected):
		return
	if mode == "carry":
		_cmd_carry_click(h)
		return
	if mode == "item":
		_cmd_item_click(h)
		return
	if mode == "move":
		_cmd_move(h)
	else:
		_cmd_fire(h, FIRE_MODES[mode])


# --- commands ------------------------------------------------------------------

# --- the game's messages ------------------------------------------------------------

func msg(id: int, args := []) -> String:
	## a battle message (WMES.PCK, the mission's entry), translated and formatted as format_text does
	return GameData.battle_text(campaign, id, args, mission_index)


func intercept_names(t: int) -> Array:
	## 0x1E5's strings: given name (DS:0x50BCB5), family name (DS:0x50BD4D), both indexed by
	## crew_name_id (0x47C4D0: crew +0, or 1 without a crew), and the machine (DS:0x50C265,
	## the campaign's machine names)
	var tables := GameData.tables(campaign)
	var id := w.sb(t, 0xB)
	id = 1 if id < 0 else Pd2World.s8(w.ucrew(t, 0))
	var names: Array = tables.crew_names
	var mach: Array = tables.machine_names        # the campaign's set (0x409240 copies it to DS:0x50C265)
	var nm: Array = names[id] if id >= 0 and id < names.size() else ["", ""]
	return [nm[0], nm[1], mach[w.ub(t, 0xC)] if w.ub(t, 0xC) < mach.size() else ""]


func say_msg(id: int, args := []) -> void:
	say(msg(id, args).replace("@", "\n").strip_edges())


func ui(key: String) -> String:
	return GameData.ui_text(key)


func uif(key: String, args: Array) -> String:
	## a UI text with format arguments; without the translations (OpenPD2) the bare key
	var t := ui(key)
	return t % args if t.find("%") != -1 else t


func _cmd_move(h: Vector2i) -> void:
	## The move command (Action.player_move, from unit_command_menu 0x4EE8D0): only the
	## marked hexes take a click; the prompts and the mine dialogs are asked on the way.
	if mm == null:
		return
	var u := selected
	var why := Action.move_refusal(w, u)
	if why != -1:
		say_msg(why)
		return
	if not h in move_dests:
		return
	busy = true
	if auto_react:
		_move_done(u, h, Action.player_move(w, rng, u, h.x, h.y, move_mode, mm, hooks, false, alert))
		return
	move_thread = Thread.new()
	move_thread.start(_move_worker.bind(u, h, mm))


func _move_worker(u: int, h: Vector2i, map: Move.MoveMap) -> void:
	var res := Action.player_move(w, rng, u, h.x, h.y, move_mode, map, hooks, false, alert)
	call_deferred("_move_finished", u, h, res)


func _move_finished(u: int, h: Vector2i, res: Array) -> void:
	move_thread.wait_to_finish()
	move_thread = null
	_move_done(u, h, res)


func _move_done(u: int, h: Vector2i, res: Array) -> void:
	busy = false
	var kind: Variant = res[0]
	var r: Variant = res[1]
	if kind == "melee" and r != null:
		say("%s attacks in melee: %s" % [unit_name(u),
			["the defender falls", "both stand", "the attacker falls", "both fall"][r]])
	elif (kind == "walk" or kind == "path") and r != null:
		if r & 1:
			say("%s: contact." % unit_name(u))
		if r & 4 or not w.active(u):
			say("%s lost." % unit_name(u))
	_after_command()
	if w.active(u) and not Action.can_move(w, u):
		say("%s cannot move any further." % unit_name(u))


# --- the move command's questions --------------------------------------------------

func ask_prompt(text: String, default: bool) -> bool:
	## ui_prompt_at_cursor (0x47EBE0): the choices are written in the message; 0 = the first
	var parts := GameData.prompt_parts(text)
	var labels: Array = parts[1] if parts[1].size() >= 2 else [ui("UI_YES"), ui("UI_NO")]
	return ask_choice(parts[0], [[labels[0], true], [labels[1], false]], default)


func ask_box(text: String, default: bool) -> bool:
	## ui_message_box (0x451FB0): the game reads non-zero as yes (step_mine_found 0x4756A0);
	## its button labels are not read yet
	return ask_choice(text, [[ui("UI_YES"), true], [ui("UI_NO"), false]], default)


func ask_choice(text: String, options: Array, default: Variant) -> Variant:
	## Called on a worker thread (the move, the computer's turn): shows the question on the
	## main thread and waits for the answer. auto_react: the default, without asking.
	if auto_react:
		return default
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		push_error("ask_choice on the main thread: %s" % text)   # would wait forever
		return default
	call_deferred("_open_choice", text, options)
	react_sem.wait()
	return react_answer


func ask_hex(text: String, hexes: Array, default: Variant) -> Variant:
	## a hex clicked on the map (ui_map_click), on a worker thread; hexes are marked ("any":
	## every hex is taken), the panel's button answers -2. auto_react / the main thread: default.
	if auto_react or OS.get_thread_caller_id() == OS.get_main_thread_id():
		return default
	call_deferred("_open_hex", text, hexes)
	react_sem.wait()
	return react_answer


func _open_hex(text: String, hexes: Array) -> void:
	hex_pick = hexes if not hexes.is_empty() else ["any"]
	var box := _reaction_panel(text.replace("@", "\n").strip_edges())
	var btn := Button.new()
	btn.text = ui("UI_CANCEL")
	btn.pressed.connect(_answer_hex.bind(-2))
	box.add_child(btn)
	overlay.queue_redraw()


func _answer_hex(v: Variant) -> void:
	hex_pick = []
	_answer_reaction(v)


func _open_choice(text: String, options: Array) -> void:
	var box := _reaction_panel(text.replace("@", "\n").strip_edges())
	for o in options:
		var btn := Button.new()
		btn.text = o[0]
		btn.pressed.connect(_answer_reaction.bind(o[1]))
		box.add_child(btn)


const FIRE_MODES := {"fire": 0, "aimed": 1, "aa": 6}
func _cmd_fire(h: Vector2i, fmode: int) -> void:
	## The player's fire command (Action.fire_target_map / fire_check / player_fire,
	## ported from cmd_fire 0x425AF0): only hexes of the target map can be clicked.
	var u := selected
	var lid := w.launcher_id(u, slot)
	if lid == -1 or w.slot_count(u, slot) <= 0:
		say("No loaded weapon in slot %d." % (slot + 1))
		return
	var cost := Move.fire_ap(w, u, slot, fmode)
	if w.sb(u, 0xE) < cost:
		say_msg(0x1AE, [cost])                       # ui_not_enough_ap (0x426AE0)
		return
	if fire_map == null or fire_map.cell(h.x, h.y) != 1:
		return
	var check := Action.fire_check(w, u, slot, fmode, h.x, h.y)
	if check[0] == Action.FIRE_REFUSED:
		if check[1] != -1:
			say_msg(check[1])
		return
	if check[0] == Action.FIRE_CONFIRM:
		# 0x1AD shows the AP needed, the AP left and the distance (cmd_fire 0x4262DF); 0x1AC none
		var up := w.pos(u)
		var args := [cost, w.sb(u, 0xE), Pd2World.hexdist(up.x, up.y, h.x, h.y)] if check[1] == 0x1AD else []
		_confirm(msg(check[1], args), _do_fire.bind(u, fmode, h))
		return
	_do_fire(u, fmode, h)


func _do_fire(u: int, fmode: int, h: Vector2i) -> void:
	## the shot runs on a worker thread: the return fire may ask the player (intercept)
	var before := {}
	for q in w.n_units:
		before[q] = w.ub(q, 0xD)
	var s := slot
	busy = true
	if auto_react:
		Action.player_fire(w, rng, u, s, fmode, h.x, h.y, hooks, false, alert)
		_fire_done(u, before)
		return
	move_thread = Thread.new()
	move_thread.start(func():
		Action.player_fire(w, rng, u, s, fmode, h.x, h.y, hooks, false, alert)
		call_deferred("_fire_finished", u, before))


func _fire_finished(u: int, before: Dictionary) -> void:
	move_thread.wait_to_finish()
	move_thread = null
	_fire_done(u, before)


func _fire_done(u: int, before: Dictionary) -> void:
	busy = false
	var hit := false
	for q in w.n_units:
		if w.ub(q, 0xD) < before[q]:
			hit = true
			say("%s hits %s: %d damage" % [unit_name(u), unit_name(q), before[q] - w.ub(q, 0xD)])
	if not hit:
		say("%s fires: no hit." % unit_name(u))
	_after_command()


func _confirm(text: String, then: Callable) -> void:
	## a prompt on the main thread: its choices come from the message (0 = the first)
	var parts := GameData.prompt_parts(text)
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = parts[0].replace("@", "\n").strip_edges()
	if parts[1].size() >= 2:
		dlg.ok_button_text = parts[1][0]
		dlg.cancel_button_text = parts[1][1]
	dlg.confirmed.connect(then)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


# --- the item command (the machine status window's "use", 0x4279F0 -> 0x4286D0 -> 0x4ECC60)

class BattleItemHooks extends Item.Hooks:
	## the throw's question was asked on the main thread before (answer 0 = yes)
	var battle

	func mine_blast(x: int, y: int) -> void:
		battle.hooks.mine_blast(x, y)

	func discovered(u: int) -> int:
		battle.say_msg(0x1C7)                      # 0x47E790: "enemy discovered"
		return 0


func _cmd_item_mode() -> void:
	## pick a pocket whose round can be used (ammo +8 bit 5, rounds left); a second press
	## goes to the next one
	if selected == -1:
		return
	var u := selected
	var usable := []
	for p in 4:
		var a := w.pocket_ammo(u, p)
		if a != -1 and w.ammo(a, 8) & 0x20 and w.pocket_count(u, p):
			usable.append(p)
	if usable.is_empty():
		say(ui("UI_NO_ITEM"))
		return
	var i := usable.find(item_pocket)
	item_pocket = usable[(i + 1) % usable.size()] if mode == "item" and i != -1 else usable[0]
	mode = "item"
	var a := w.pocket_ammo(u, item_pocket)
	var names: Dictionary = GameData.tables(campaign).get("ammo_names", {})
	say(uif("UI_ITEM_PICK", [item_pocket + 1, str(names.get(str(a), "#%d" % a)), Item.use_ap(w, u, item_pocket)]))
	_update_move_map()


func _cmd_item_click(h: Vector2i) -> void:
	## 0x4279F0's checks (both manipulators broken: 0x1B9; AP: ui_not_enough_ap), 0x4286D0's
	## (a broken pocket: 0x1B8), the target map, then 0x4ECC60 with its question
	var u := selected
	var p := item_pocket
	if w.pocket_ammo(u, p) == -1 or not w.pocket_count(u, p):
		return
	if Ai.manipulator_state(w, u) == 2:
		say_msg(0x1B9)
		return
	var ap := Item.use_ap(w, u, p)
	if w.sb(u, 0xE) < ap:
		say_msg(0x1AE, [ap])
		return
	if w.pocket_state(u, p) == 2:
		say_msg(0x1B8)
		return
	if fire_map == null or fire_map.cell(h.x, h.y) != 1:
		return
	var a := w.pocket_ammo(u, p)
	var wh := w.ammo(a, 8) & 15
	if wh == 9:
		_do_item(u, p, ap, h)
		return
	var up := w.pos(u)
	var radius := 0 if wh == Action.MINE_WARHEAD else 1
	var dist := Pd2World.hexdist(up.x, up.y, h.x, h.y)
	var q := 0x1CC if (radius < dist or wh != 1) else 0x1CB
	# 0x1CC shows the AP needed, the AP left and the distance (0x4ED25A); 0x1CB none
	_confirm(msg(q, [ap, w.sb(u, 0xE), dist] if q == 0x1CC else []), _do_item.bind(u, p, ap, h))


func _do_item(u: int, p: int, ap: int, h: Vector2i) -> void:
	var ih := BattleItemHooks.new()
	ih.battle = self
	var before := {}
	for q in w.n_units:
		before[q] = [w.ub(q, 0xD), w.ub(q, 0) & 0x10]
	Item.command(w, rng, u, p, ap, h.x, h.y, ih, options & 2 != 0)
	if w.pocket_count(u, p) == 0:
		w.setb(u, 0x1B + 2 * p, 0xFF)          # clear_pocket (0x4286D0)
	for q in w.n_units:
		if w.ub(q, 0xD) < before[q][0]:
			say("%s: %d damage" % [unit_name(q), before[q][0] - w.ub(q, 0xD)])
		elif w.is_enemy(q) and w.ub(q, 0) & 0x10 and not before[q][1]:
			say("%s spotted" % unit_name(q))
	mode = "move"
	_after_command()


func _cmd_search() -> void:
	## cmd_search (Action.player_search, emulated).
	if selected == -1:
		return
	var u := selected
	if w.sb(u, 0xE) < Action.search_cost(w, u):
		say_msg(0x1AE, [Action.search_cost(w, u)])     # ui_not_enough_ap (cmd_search 0x426B10)
		return
	_confirm(msg(0x1C8), func():
		var found: Array = Action.player_search(w, u)
		var enemies := found.filter(func(k): return w.is_enemy(k))
		say("%s searches: %d enemy unit(s) found." % [unit_name(u), enemies.size()])
		for k in enemies:
			say("  enemy found: %s" % unit_name(k))
		_after_command())


func _cmd_conceal() -> void:
	## cmd_conceal (Action.conceal_check, then the AI's conceal rule; emulated).
	if selected == -1:
		return
	var u := selected
	var why: Variant = Action.conceal_check(w, u)
	var cost := 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
	if not (why is String and why == ""):
		if why is String:                             # "ap": ui_not_enough_ap (cmd_conceal 0x426C00)
			say_msg(0x1AE, [cost])
		else:
			say_msg(why)
		return
	# 0x1B0 shows the AP needed, the AP left and the cover of the unit's hex
	_confirm(msg(0x1B0, [cost, w.sb(u, 0xE), w.cover(u)]), func():
		Ai.ai_conceal(w, u)
		say("%s conceals." % unit_name(u))
		_after_command())


func _cmd_carry_mode() -> void:
	## Carry when the unit carries nobody, release otherwise (the unit menu's entry 10).
	if selected == -1:
		return
	var u := selected
	var carrying := w.ub(u, 0x34) != 0xFF
	var res: Array = Action.release_candidates(w, u) if carrying else Action.carry_candidates(w, u)
	if res[0].is_empty():
		if res[1] is String:                          # "ap": ui_not_enough_ap (cmd_release: 2; cmd_carry: its cost)
			say_msg(0x1AE, [2 if carrying else Action.carry_cost(w, u)])
		else:
			say_msg(res[1])
		return
	carry_hexes = []
	for v in res[0]:
		carry_hexes.append(Vector2i(v.x, v.y))
	_set_mode("carry")


func _cmd_carry_click(h: Vector2i) -> void:
	if not h in carry_hexes:
		return
	var u := selected
	if w.ub(u, 0x34) == 0xFF:
		var o := w.O[h.x + MAP * h.y] - 1
		_confirm(msg(0x1B5), func():
			var why := Action.player_carry(w, u, o)
			if why != -1:
				say_msg(why)
			else:
				say("%s picks up %s." % [unit_name(u), unit_name(o)])
			_set_mode("move")
			_after_command())
	else:
		var carried := w.ub(u, 0x34)
		_confirm(msg(0x1B2), func():
			Action.player_release(w, u, h.x, h.y)
			if not carried in squad:
				pass
			say("%s sets down %s." % [unit_name(u), unit_name(carried)])
			_set_mode("move")
			_after_command())


func _after_command() -> void:
	_script_state()
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	_update_move_map()
	_check_end()


# --- the turn --------------------------------------------------------------------

func _view_reset(side: int) -> void:
	## mission_loop: clear_view (0x47D5C0), or view_all (0x437370) with option bit 7
	if options & 0x80:
		Turn.view_all(w, side)
	else:
		Turn.clear_view(w, side)


func _turn_start() -> void:
	## mission_loop's LAB_00436b39 (w.phase is 3 here): smoke clears (0x483B50), spotted
	## flags (0x437440), the computer's view and recon pass, the AI memory of spotted
	## DoLLS (0x480C60); then the player's phase, view and recon pass, the player's
	## fire-support strikes (0x4E37A0(0)) and their marks (0x483ED0(0), as refresh_strikes),
	## the reinforcements (0x44F2E0), the sensors (0x480910), the timed explosives
	## (0x480280) and the reaction flags cleared. (The date window 0x4361C0, the camera
	## 0x436360 and 0x4F3DA0 are display.) The airdrop (0x44AEA0) comes first.
	Turn.smoke_clears(w, rng)
	Turn.clear_spotted_all(w, options)
	Turn.clear_view(w, 3)
	Turn.recon_pass(w, 3)
	Turn.memory_record(w)
	w.phase = 0
	_view_reset(0)
	Turn.recon_pass(w, 0)
	_airdrop()                            # 0x44AEA0
	_strikes(0)
	AiTurn.refresh_strikes(w, 0)         # 0x483ED0(0)
	_reinforcements()                     # 0x44F2E0
	Item.sensors_tick(w)                  # 0x480910
	_bombs()                              # 0x480280
	Turn.clear_reacted_all(w)


func _end_turn() -> void:
	## mission_loop (0x436690) after the player's commands, call by call. It runs on a
	## worker thread: the computer's turn, its strikes and the mission script may ask the
	## player (reactions, interception, counter-battery, escapes).
	if busy or mission_over:
		return
	busy = true
	say("[b]Enemy phase[/b]")
	if auto_react:
		var r := _enemy_phase()
		_end_turn_finish(r[0], r[1], r[2])
		return
	ai_running = true
	ai_thread = Thread.new()
	ai_thread.start(_ai_phase)


func _enemy_phase() -> Array:
	## [the computer's result, its undefined units, the end code]: mission_loop leaves its
	## turn loop when DS:0x50ADF2 is set after the turn script's stage 1 or stage 0
	Turn.support_fire(w, 0)
	_script_turn(1)
	if w.ds8(0x50ADF2):
		return [0, [], w.ds8(0x50ADF2)]
	Turn.clear_spotted_all(w, options)
	_view_reset(0)
	Turn.recon_pass(w, 0)                # still the player's phase
	w.phase = 3
	Turn.turn_upkeep(w, rng, Turn.PHASE_ENEMY)
	Turn.refill_ap(w, Turn.PHASE_ENEMY)
	Turn.clear_view(w, 3)
	Turn.recon_pass(w, 3)
	var sres := _strikes(3)                # 0x4E37A0(3)
	if sres in Ai.AI_ABORT:
		return [sres, [], 0]
	Turn.memory_forget(w)
	Turn.clear_reacted_all(w)
	hooks.flag = 0
	var undefined := []
	var res := AiTurn.run(w, rng, hooks, w.ds8(0x50ADF1), false, undefined)
	Turn.support_fire(w, 3)
	w.phase = 0
	Turn.turn_upkeep(w, rng, Turn.PHASE_PLAYER)
	Turn.refill_ap(w, Turn.PHASE_PLAYER)
	w.phase = 3
	_script_turn(0)
	if w.ds8(0x50ADF2):
		return [res, undefined, w.ds8(0x50ADF2)]
	Turn.clear_strikes(w)                # 0x46F590(0)
	_turn_start()
	return [res, undefined, 0]


func _ai_phase() -> void:
	## Worker thread: the enemy phase. Only the questions talk to the main thread meanwhile;
	## input is blocked by `busy`.
	var r := _enemy_phase()
	call_deferred("_ai_done", r[0], r[1], r[2])


func _ai_done(res: int, undefined: Array, end_code := 0) -> void:
	ai_thread.wait_to_finish()
	ai_thread = null
	ai_running = false
	overlay.queue_redraw()
	_end_turn_finish(res, undefined, end_code)


func _end_turn_finish(res: int, undefined: Array, end_code := 0) -> void:
	if end_code:
		busy = false
		_end_mission(end_code)
		return
	last_ai_result = res
	if not undefined.is_empty():
		say("[color=gray](%d unit(s) reached a case the game leaves undefined; their orders ended there)[/color]" % undefined.size())
	if res in Ai.AI_ABORT:
		say("The computer's turn ended early (code 0x%X: its path-search pool ran out)." % res)
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	turn += 1
	say("[b]Turn %d[/b]" % turn)
	busy = false
	if selected != -1 and not w.active(selected):
		_next_unit()
	_update_move_map()
	_check_end()


# --- the mission's event scripts (MissionScripts; DS:0x50CE72 selects them) --------------

class BattleMissionHooks extends MissionScripts.Hooks:
	var battle

	func dialog(msg: int, args: Array, choices: int) -> int:
		## 0x43BA20 with its choice labels: mission 1's escape (0xAA, the pilot's given and
		## family names) uses 実行 / 中止 (DS:0x50CBC1), its indoor search (0xA5) はい / いいえ
		## (DS:0x517F88)
		var a := args
		var labels := [battle.ui("UI_YES"), battle.ui("UI_NO")]
		if msg == 0xAA:
			var names: Array = GameData.tables(battle.campaign).crew_names
			var nm: Array = names[args[0]] if args[0] < names.size() else ["", ""]
			a = [nm[0], nm[1]]
			labels = [battle.ui("UI_GO"), battle.ui("UI_CANCEL")]
		var text: String = battle.msg(msg, a)
		return 0 if battle.ask_choice(text, [[labels[0], true], [labels[1], false]], true) else 1

	func message(msg: int, args := []) -> int:
		battle.say_msg(msg, args)
		return 0

	func scroll(x: int, y: int) -> int:
		return 0

	func speech() -> int:
		## the mission's speech hook (table 0x51EEB8): mission 1's runs the flight turn and
		## the arrival scenes (0x499830)
		if battle.script_no == 1:
			return MissionScripts.m01_speech(battle.w, battle.rng, battle.flight_hooks)
		return 0


class BattleFlightHooks extends Flight.Hooks:
	## The flight engine's windows in the battle: the radio's lines go to the message log
	## (their portraits and the radar map are not drawn yet); the air fight's melee asks
	## its weapon prompt (0x1A7, as 0x424490). Runs on the computer turn's thread.
	var battle

	func radio_say(msg: int, args: Array, code: Variant) -> int:
		battle.say_msg(msg, battle.radio_args(args))
		return 0

	func use_weapon(a: int, p: int) -> bool:
		return battle.ask_prompt(battle.msg(0x1A7), true)


class BattleStrikeHooks extends Strike.Hooks:
	## The strike executor (0x4E37A0) in the battle: a striker flying in draws the reaction
	## fire of the live hooks (flag 10), the radio goes through the flight engine's, the
	## lines and questions to the message log and the question box. The pickers (0x4E3230 /
	## 0x4E0450) are a plain choice list; their columns are not drawn yet.
	var battle
	var w: Pd2World
	var rng: Pd2Random

	func react(u: int, cands: Array, easy := false) -> int:
		var h = battle.hooks
		var f: int = h.flag
		var e: bool = h.easy
		h.flag = 10
		h.easy = h.easy or easy        # DS:0x551D29 bit 1 forced on (a leaving reinforcement)
		var res: int = h.react(u)
		h.flag = f
		h.easy = e
		return res

	func radio(kind: int, g: int) -> int:
		return Flight.radio(w, rng, kind, g, battle.flight_hooks)

	func line(msg: int, args: Array = []) -> void:
		battle.say_msg(msg, battle.radio_args(args))

	func ask(msg: int) -> int:
		return 1 if battle.ask_box(battle.msg(msg), false) else 0

	func cb_pick(units: Array) -> int:
		var opts := []
		for k in units:
			opts.append([battle.unit_name(k), k])
		opts.append([battle.ui("UI_CANCEL"), -1])
		return battle.ask_choice(battle.ui("UI_PICK_SUPPORT"), opts, -1)

	func cb_slot(u: int, g: int) -> int:
		var opts := []
		for s in 6:
			if w.launcher_id(u, s) != -1:
				opts.append([battle.ui("UI_SLOT_ROUNDS") % [s + 1, w.slot_count(u, s)], s])
		opts.append([battle.ui("UI_CANCEL"), -2])
		return battle.ask_choice(battle.ui("UI_PICK_WEAPON"), opts, -2)

	func mine_blast(x: int, y: int) -> void:
		battle.hooks.mine_blast(x, y)

	func intercept_choice(t: int, best: int) -> int:
		return battle.hooks.intercept_choice(t, best)


func _strikes(side: int) -> int:
	## strike_executor (0x4E37A0, Strike.executor): the side's fire-support orders
	var sh := BattleStrikeHooks.new()
	sh.battle = self
	sh.w = w
	sh.rng = rng
	var before := []
	for k in w.n_units:
		before.append(w.ub(k, 0) & 1)
	var res := Strike.executor(w, rng, side, sh, options & 2 != 0)
	for k in w.n_units:
		if w.ub(k, 0) & 1 and not before[k]:
			say("[color=orange]%s destroyed[/color]" % unit_name(k))
	return res


func _reinforcements() -> int:
	## 0x44F2E0 (Strike.reinforcements): type-6 groups on the called point arrive or leave.
	## The game's leftover locals start at 0.
	var sh := BattleStrikeHooks.new()
	sh.battle = self
	sh.w = w
	sh.rng = rng
	var before := []
	for k in w.n_units:
		before.append([w.ub(k, 0) & 1, w.pos(k)])
	var res := Strike.reinforcements(w, rng, sh)
	for k in w.n_units:
		if w.ub(k, 0) & 1 and not before[k][0]:
			say("[color=orange]%s destroyed[/color]" % unit_name(k))
		elif before[k][1] == Vector2i(-1, -1) and w.active(k):
			say("%s enters the map" % unit_name(k))
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	return res

class BattleBombHooks extends Turn.BombHooks:
	## The explosions go to the message log (the animation is not drawn, so none is
	## skipped). The bomb hook (table 0x51F158) is mission 1's no-op; other missions'
	## hooks are not ported.
	var battle

	func explosion(x: int, y: int) -> bool:
		battle.say("explosion at %d, %d" % [x, y])
		return false

	func mine_blast(x: int, y: int) -> void:
		battle.say("mine explodes at %d, %d" % [x, y])

	func bomb_hook(i: int) -> int:
		if battle.script_no != 1:
			battle.say("[color=gray](the mission's bomb hook is not ported)[/color]")
		return 0


func _bombs() -> int:
	## 0x480280 (Turn.timed_explosives): the fuses count down, a bomb at 0 goes off.
	var bh := BattleBombHooks.new()
	bh.battle = self
	var before := []
	for k in w.n_units:
		before.append(w.ub(k, 0) & 1)
	var res := Turn.timed_explosives(w, rng, bh, options)
	for k in w.n_units:
		if w.ub(k, 0) & 1 and not before[k]:
			say("[color=orange]%s destroyed[/color]" % unit_name(k))
	return res


class BattleDropHooks extends Drop.Hooks:
	## The airdrop in the battle: the transport's clicks, its menu, the passengers and their
	## hexes are asked on the worker thread (auto_react: the transport opens its menu at
	## once and drops everyone); melee is the game's; the reaction fire the live hooks'.
	var battle
	var w: Pd2World
	var rng: Pd2Random

	func line(msg: int, args: Array = []) -> void:
		battle.say_msg(msg, battle.radio_args(args))

	func react(u: int, cands: Array, easy := false) -> int:
		var h = battle.hooks
		var f: int = h.flag
		h.flag = 10
		var res: int = h.react(u)
		h.flag = f
		return res

	func discovered(u: int) -> int:
		battle.say_msg(0x1C7)
		return 0

	func panel(u: int) -> void:
		battle.call_deferred("_focus", u)

	func click(u: int, dests: Array) -> Variant:
		# ui_map_click mode 4 takes the marked hexes: the move command's and the transport's
		return battle.ask_hex(battle.uif("UI_TRANSPORT_MOVE", [battle.unit_name(u), w.sb(u, 0xE)]), dests + [w.pos(u)], w.pos(u))

	func ask2(msg: int, args: Array) -> int:
		return 0 if battle.ask_prompt(battle.msg(msg, args), true) else 1

	func drop_menu(u: int) -> int:
		return battle.ask_choice(battle.ui("UI_DROP_MENU"), [[battle.ui("UI_DROP_ONE"), 0],
			[battle.ui("UI_DROP_ALL"), 1], [battle.ui("UI_CANCEL"), -2]], 1)

	func pick(units: Array) -> int:
		var opts := []
		for k in units:
			opts.append([battle.unit_name(k), k])
		opts.append([battle.ui("UI_CANCEL"), -2])
		return battle.ask_choice(battle.ui("UI_DROP_WHO"), opts, -2)

	func drop_click(k: int, hexes: Array) -> Variant:
		return battle.ask_hex(battle.uif("UI_DROP_WHERE", [battle.unit_name(k)]), hexes, -2)

	func box(msg: int) -> int:
		return 1 if battle.ask_box(battle.msg(msg), true) else 0

	func melee(a: int, b: int) -> int:
		return battle.hooks.melee(a, b)


func _focus(u: int) -> void:
	if w.on_map(w.pos(u).x, w.pos(u).y):
		cam.position = hex_center(w.pos(u))


func _airdrop() -> int:
	## 0x44AEA0 (Drop.airdrop): transports on the called point bring their passengers in
	var dh := BattleDropHooks.new()
	dh.battle = self
	dh.w = w
	dh.rng = rng
	var before := []
	for k in w.n_units:
		before.append([w.ub(k, 0) & 1, w.active(k)])
	var res := Drop.airdrop(w, rng, dh)
	for k in w.n_units:
		if w.ub(k, 0) & 1 and not before[k][0]:
			say("[color=orange]%s destroyed[/color]" % unit_name(k))
		elif w.active(k) and not before[k][1]:
			say("%s lands" % unit_name(k))
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	return res

func radio_args(args: Array) -> Array:
	## the radio's format arguments as text: a call sign (DS:0x50C7E5), the time of
	## 0x453900 ("HH:MM" of (t + d) x 5 minutes, hours past 23 wrapped) or a number (%d)
	var out := []
	for a in args:
		match a[0]:
			"sign":
				out.append(GameData.call_sign(campaign, a[1]))
			"name":
				out.append(GameData.call_sign(campaign, 39 + a[1]))   # a group name (DS:0x50C881)
			"time":
				var m: int = (a[1] + a[2]) * 5
				var h := m / 60
				m = m % 60
				if h > 23:
					h = h % 24
				out.append(String.chr(48 + h / 10) + String.chr(48 + h % 10) + ":" + String.chr(48 + m / 10) + String.chr(48 + m % 10))
			_:
				out.append(str(a[2]))
	return out


func _script_turn(stage: int) -> void:
	## the turn script (table 0x51EFD8): stage 2 at a new mission, 1 after the player's turn,
	## 0 in the computer's turn (which runs the speech hook). Only mission 1's is ported.
	if script_no == 1:
		MissionScripts.m01_turn(w, rng, stage, mission_hooks)


func _script_state() -> void:
	## After a command: command_loop (0x4EF600) ends the player's phase when the end code
	## DS:0x50ADF2 is set; mission_loop then runs to its check after the turn script.
	if mission_over or busy:
		return
	if w.ds8(0x50ADF2):
		_end_turn()


func _cmd_withdraw() -> void:
	## The command menu's withdraw (entry 0xB): WMES 0x1DE, yes = 0x82; mission_loop leaves
	## its turn loop, the mission's scenario hook (table 0x51F038) sets the end code.
	if busy or mission_over:
		return
	if auto_react:
		_withdraw()
		return
	_confirm(msg(0x1DE), _withdraw)


func _withdraw() -> void:
	var code := Debrief.scenario_command(w, script_no)
	if code == -1:
		say(uif("UI_NOT_PORTED_HOOK", ["0x51F038", script_no]))
		return
	_end_mission(code, true)


func _end_mission(code: int, exited := false) -> void:
	## mission_loop's exit (Debrief.mission_exit: the mission's end, 0x4373B0 / 0x4374C0),
	## then game_mode_loop: a result from 0x80 up (but 0x81) goes to the debrief 0x48FA40
	## (DS:0x50663A = 2); its 0x80 starts the next mission while the campaign goes on.
	if mission_over:
		return
	mission_over = true
	if not exited:
		code = Debrief.mission_exit(w, code)
	say("[b]%s[/b]" % uif("UI_MISSION_END", ["0x%X" % code]))
	w.set_ds16(0x50AD90, rng.state)            # random()'s word goes into the save
	if code < 0x80 or code == 0x81:
		debrief_result = 0x81
		_show_debrief([], [])
		return
	var dh := BattleDebriefHooks.new()
	dh.battle = self
	var crt := Campaign.CrtRand.new(int(Time.get_unix_time_from_system()))
	debrief_result = Debrief.debrief(w, code, rng, crt, dh)
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	_show_debrief(dh.lines, Debrief.next_mission(w) if debrief_result == 0x80 else [])


class BattleDebriefHooks extends Debrief.Hooks:
	## The debrief's pictures and lists as lines of the debrief panel (the pictures and
	## the credits are not shown); SAVEDATA.ORG and the record sets from the import; the
	## new campaign's pilot choice (PD2's hand-over to DASH) filled at random, as the
	## battle's first mission does; clearinf.bin's flags in user://clearinf.bin.
	var battle
	var lines := []

	func screen(kind: String, data: Variant = null) -> int:
		match kind:
			"clear", "fail", "gameover", "ending", "single":
				lines.append("[b]%s[/b]" % battle.ui("UI_DEBRIEF_" + kind.to_upper()))
				for id in data:
					var t: String = GameData.debrief_text(battle.campaign, id)
					if t != "":
						lines.append(t)
			"results":
				for r in data:
					var st: String = battle.ui(["UI_DEBRIEF_OK", "UI_DEBRIEF_INJURED", "UI_DEBRIEF_HURT", "UI_DEBRIEF_INJURED"][r[1]])
					if r[4]:
						st = battle.ui("UI_DEBRIEF_LOST")
					lines.append("  %s: %s (%s %d)" % [battle.crew_name(r[0]), st, battle.machine_name(r[2]), r[3]])
			"new_items":
				for i in data[0]:
					lines.append(battle.uif("UI_DEBRIEF_NEW", [battle.machine_name(i)]))
				for i in data[1]:
					lines.append(battle.uif("UI_DEBRIEF_NEW", [battle._name_of("launcher_names", i)]))
				for i in data[2]:
					lines.append(battle.uif("UI_DEBRIEF_NEW", [battle._name_of("ammo_names", i)]))
			"recruits":
				for c in data:
					lines.append(battle.uif("UI_DEBRIEF_RECRUIT", [battle.crew_name(c)]))
			"recovered":
				lines.append(battle.uif("UI_DEBRIEF_RECOVERED", [battle.crew_name(data[0])]))
			"handover":
				lines.append("[b]%s[/b]" % battle.ui("UI_DEBRIEF_HANDOVER"))
		return 0

	func load_save(flag: int) -> PackedByteArray:
		var img: Array = GameData.save_image("pd2" if flag else "dash")
		return img[1] if img.size() == 2 else PackedByteArray()

	func new_campaign(w: Pd2World) -> int:
		return Campaign.new_campaign(w, Campaign.CrtRand.new(int(Time.get_unix_time_from_system())), Campaign.Hooks.new())

	func campaign_set(w: Pd2World) -> void:
		var t := GameData.tables("pd2" if w.campaign else "dash")
		w.records = Pd2World.new(t.machines, t.launchers, t.ammo, PackedByteArray(), 1).records

	func clear_flag(i: int) -> void:
		var path := "user://clearinf.bin"
		var buf := PackedByteArray()
		if FileAccess.file_exists(path):
			buf = FileAccess.get_file_as_bytes(path)
		if buf.size() < 0x22:
			buf = "CLEAR_FLAG".to_ascii_buffer()
			buf.resize(0x22)
		if i < buf.size():
			buf[i] = 1
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(buf)


func crew_name(c: int) -> String:
	var crew_names: Array = names.crew
	var n := w.cb(c, 0) if c >= 0 and c < 64 else -1
	return "".join(crew_names[n]) if n >= 0 and n < crew_names.size() else "#%d" % c


func machine_name(m: int) -> String:
	var mach: Array = names.machine
	return mach[m] if m >= 0 and m < mach.size() else "-"


func _show_debrief(lines: Array, nxt: Array) -> void:
	## The debrief panel: its lines, then the next mission (game_mode_loop: the mission
	## start 0x416CF0 with the debrief's save) or the way back to the mission list.
	if debrief_panel:
		debrief_panel.queue_free()
	debrief_panel = PanelContainer.new()
	var theme := Theme.new()
	theme.default_font_size = 8
	debrief_panel.theme = theme
	debrief_panel.position = Vector2(220, 20)
	hud_layer.add_child(debrief_panel)
	var box := VBoxContainer.new()
	debrief_panel.add_child(box)
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.custom_minimum_size = Vector2(420, 0)
	text.text = "\n".join(lines) if not lines.is_empty() else ui("UI_MISSION_OVER")
	box.add_child(text)
	if not nxt.is_empty():
		var go := Button.new()
		go.text = ui("UI_NEXT_MISSION")
		go.pressed.connect(_next_mission.bind(nxt))
		box.add_child(go)
	var back := Button.new()
	back.text = ui("UI_BACK_TO_MISSIONS")
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/boot.tscn"))
	box.add_child(back)


func _next_mission(nxt: Array) -> void:
	## game_mode_loop's next round: the next battle scene with the debrief's save (its
	## campaign flag and chunk DS:0x50663D), the mission number and PD2's kept crews
	carry = {"image": Debrief.save_image(w), "script": w.script_no, "stash": w.stash}
	var scene: PackedScene = load("res://ui/battle.tscn")
	var b := scene.instantiate()
	b.campaign = "pd2" if nxt[0] else "dash"
	b.mission_index = int(nxt[1]) - 1
	b.auto_react = auto_react
	b.sortie_window = sortie_window
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	queue_free()


func _cmd_mission() -> void:
	## the mission's own command (unit menu entry 11, table 0x51EF78): mission 1's indoor search
	if selected == -1 or script_no != 1 or busy or mission_over:
		return
	var u := selected
	busy = true
	if auto_react:
		MissionScripts.m01_command(w, u, mission_hooks)
		_mission_cmd_done()
		return
	move_thread = Thread.new()
	move_thread.start(func():
		MissionScripts.m01_command(w, u, mission_hooks)
		call_deferred("_mission_cmd_finished"))


func _mission_cmd_finished() -> void:
	move_thread.wait_to_finish()
	move_thread = null
	_mission_cmd_done()


func _mission_cmd_done() -> void:
	busy = false
	_after_command()


# --- the reaction menu ------------------------------------------------------------

func ask_reaction(menu: Array, t: int, mode: int) -> Variant:
	## Called on the computer's thread by Action.player_reactions: shows the menu on the
	## main thread and waits for the answer (0 ignore the enemy, 1 done, [unit, [slot]]).
	call_deferred("_open_reaction_menu", menu, t, mode)
	react_sem.wait()
	return react_answer


func _open_reaction_menu(menu: Array, t: int, mode: int) -> void:
	react_target = t
	react_menu = menu
	cam.position = hex_center(w.pos(t))
	_show_reaction_units(menu, t, mode)
	overlay.queue_redraw()


func _reaction_panel(title: String) -> VBoxContainer:
	if react_panel:
		react_panel.queue_free()
	react_panel = PanelContainer.new()
	var theme := Theme.new()
	theme.default_font_size = 8
	react_panel.theme = theme
	react_panel.position = Vector2(get_viewport().get_visible_rect().size.x - 236, 40)
	var box := VBoxContainer.new()
	react_panel.add_child(box)
	var lbl := Label.new()
	lbl.text = title
	box.add_child(lbl)
	hud_layer.add_child(react_panel)
	return box


func _show_reaction_units(menu: Array, t: int, mode: int) -> void:
	var box := _reaction_panel("%s in reach. React with:" % unit_name(t))
	var tp := w.pos(t)
	for b in menu:
		var bp := w.pos(b)
		var btn := Button.new()
		btn.text = "%s  (%d hexes, condition %d)" % [unit_name(b), Pd2World.hexdist(bp.x, bp.y, tp.x, tp.y), w.ub(b, 0xD)]
		btn.pressed.connect(_show_reaction_weapons.bind(menu, t, mode, b))
		box.add_child(btn)
	var ignore := Button.new()
	ignore.text = "Ignore this unit"
	ignore.pressed.connect(_answer_reaction.bind(0))
	box.add_child(ignore)
	var done := Button.new()
	done.text = "Done"
	done.pressed.connect(_answer_reaction.bind(1))
	box.add_child(done)


func _show_reaction_weapons(menu: Array, t: int, mode: int, b: int) -> void:
	var box := _reaction_panel("%s: weapon" % unit_name(b))
	var bp := w.pos(b)
	var tp := w.pos(t)
	var any := false
	for s in Action.weapon_choices(w, b, mode, Pd2World.hexdist(bp.x, bp.y, tp.x, tp.y)):
		if s >= 4:
			continue                # magazine swaps do nothing in this menu (0x472920)
		any = true
		var btn := Button.new()
		btn.text = "Slot %d: range %d, rounds %d, attack %d" % [s + 1, w.weapon_range(b, s), w.slot_count(b, s),
			Move.final_attack(w, b, s, mode == 10)]
		btn.pressed.connect(_answer_reaction.bind([b, [s]]))
		box.add_child(btn)
	if not any:
		var none := Label.new()
		none.text = "No weapon can fire."
		box.add_child(none)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(_show_reaction_units.bind(menu, t, mode))
	box.add_child(back)


func _answer_reaction(v: Variant) -> void:
	if react_panel:
		react_panel.queue_free()
		react_panel = null
	react_target = -1
	react_menu = []
	react_answer = v
	overlay.queue_redraw()
	react_sem.post()


func _count_side(side: int) -> int:
	var n := 0
	for u in w.n_units:
		if w.active(u) and (3 if w.is_enemy(u) else 0) == side:
			n += 1
	return n


func _check_end() -> void:
	# lost: nobody on the map nor still in a group (a group flying in lands later)
	if squad.all(func(u): return not w.active(u) and not u in Mission.player_units(w)):
		say("[color=red]The squad is lost.[/color]")
	elif _count_side(3) == 0:
		say("[color=lime]No enemy unit left.[/color]")


# --- drawing ---------------------------------------------------------------------

func _draw_overlay() -> void:
	if w == null or ((ai_running or move_thread != null) and react_panel == null):
		return
	if mode == "carry":
		for hx in carry_hexes:
			overlay.draw_circle(hex_center(hx), 14, Color(0.4, 1, 0.6, 0.35))
	for h in hex_pick:
		if h is Vector2i:
			overlay.draw_circle(hex_center(h), 11, Color(0.3, 1, 0.5, 0.35))
	if fire_map != null and mode != "move" and mode != "carry":
		for ly in fire_map.h:
			for lx in fire_map.w:
				if fire_map.at(lx, ly) == 1:
					overlay.draw_circle(hex_center(Vector2i(fire_map.x0 + lx, fire_map.y0 + ly)), 10, Color(1, 0.8, 0.2, 0.25))
	if mm != null and mode == "move":
		for hx in move_dests:
			var o := w.O[hx.x + MAP * hx.y] - 1
			var col := Color(1, 0.3, 0.2, 0.35) if o != -1 and w.ub(o, 0) & 0x10 else Color(0.3, 0.8, 1.0, 0.22)
			overlay.draw_circle(hex_center(hx), 14, col)
	for u in w.n_units:
		if not w.active(u):
			continue
		var enemy := w.is_enemy(u)
		if enemy and not (w.ub(u, 0) & 0x10):
			continue
		var p := hex_center(w.pos(u))
		var col := Color(0.95, 0.25, 0.2) if enemy else (Color(0.3, 0.9, 0.4) if u in squad else Color(0.6, 0.7, 1.0))
		var air := w.unit_class(u) >= 2
		if air:
			overlay.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -14), p + Vector2(13, 10), p + Vector2(-13, 10)]), col)
		else:
			overlay.draw_circle(p, 13, col)
		var f := w.ub(u, 5) & 7
		var dirs := [Vector2(-0.5, -0.87), Vector2(0.5, -0.87), Vector2(1, 0), Vector2(0.5, 0.87), Vector2(-0.5, 0.87), Vector2(-1, 0)]
		if f < 6:
			overlay.draw_line(p, p + dirs[f] * 18, Color.BLACK, 3)
		if w.ub(u, 0) & 0x20:
			overlay.draw_arc(p, 16, 0, TAU, 24, Color(0.2, 0.2, 0.2), 2)
		if u == selected:
			overlay.draw_arc(p, 19, 0, TAU, 32, Color.YELLOW, 3)
	if react_target != -1:
		overlay.draw_arc(hex_center(w.pos(react_target)), 22, 0, TAU, 32, Color.RED, 3)
		for b in react_menu:
			overlay.draw_arc(hex_center(w.pos(b)), 20, 0, TAU, 32, Color(0.3, 1, 0.5), 2)
	if w.on_map(hover.x, hover.y):
		overlay.draw_arc(hex_center(hover), 22, 0, TAU, 6, Color(1, 1, 1, 0.7), 2)
