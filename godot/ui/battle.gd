extends Node2D
## The tactical battle, sandbox edition: one mission's map and enemy force (INIT), a
## stand-in squad (Mission.sandbox_squad), the player's commands and the computer's
## whole turn, all through the ported rules in core/. What is not ported yet (briefing,
## the battle's own windows) is replaced by the simplest
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
## The title's start (0x46D780, ui/boot.gd) hands its savedata.tmp the same way, with
## new_campaign: game_mode_loop runs 0x421B90 first (button 0's entries returning 1).
var title_carry := {}
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
## DS:0x551D29 (bit 1 easy, bit 5 training, bit 7 see all; the system menu's bits 4, 8, 12-15):
## the world's (Pd2World.options, saved with nothing: the game keeps it across battles)
var options: int:
	get: return w.options if w else 0
	set(v):
		if w:
			w.options = v
var busy := false
## The computer's turn runs on a worker thread so that the player's reaction menu can
## pause it; auto_react answers the menu without asking (tests, headless runs).
var auto_react := false
var react_policy := Callable()     # auto_react's answers (tests); default: strongest weapon
var ai_thread: Thread = null
var ai_running := false
var react_sem := Semaphore.new()
var react_answer: Variant = 1
var scripted: Array = []      # tests: the answers ask_choice / ask_table / ask_hex give, in turn
var hex_pick: Array = []         # the hexes a question on the worker thread waits a click on
var react_panel: Control = null
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
		while true:
			var pick: int = battle.ask_weapon(t, 7, 0)       # the picker in mode 7
			if pick == -2:
				return -1
			if pick < 4:
				return pick
		return -1

	# the player's move command and its mine dialogs; they run on the move's worker
	# thread and wait for the answer (auto_react: the defaults, without asking)
	func confirm(msg: int, args: Array) -> bool:
		return battle.ask_prompt(battle.msg(msg, args), true)

	func use_weapon(a: int, p: int) -> bool:
		return battle.ask_prompt(battle.msg(0x1A7), true)       # melee's own prompt (0x424490)

	func mine_found(u: int) -> void:
		battle.say_msg(0x1A6)

	func mine_clear(u: int, msg := 0x1A3) -> bool:
		return battle.ask_box(battle.msg(msg), false, 0)     # 0x475730 / 0x4737D2: kind 0

	func mine_shoot(u: int) -> Variant:
		if not battle.ask_box(battle.msg(0x1A4), false, 0):
			return null
		while true:
			# the weapon picker (mode 3): a slot shoots the mine; a magazine item (4 + slot)
			# runs the slot menu (0x427530) and asks again (step_mine_found 0x4756A0)
			var pick: int = battle.ask_weapon(u, 3, 0)       # the picker in mode 3
			if pick >= 4:
				battle.slot_menu_flow(u, pick - 4, true)
				continue
			if pick != -2:
				battle.say_msg(0x1A5)
			return [pick]
		return null


func _ready() -> void:
	var tables := GameData.tables(campaign)
	var doc := GameData.mission(campaign, mission_index)
	mission_record = doc.get("record", PackedByteArray())
	# a campaign's first mission starts a new campaign (0x421B90): the pilot choice answered
	# with its "fill at random" (rand() seeded from the clock, as 0x48F7A0 does)
	var save := GameData.save_image(campaign)
	var pick: Campaign.Hooks = Campaign.Hooks.new() if mission_index == 0 else null
	var crt := Campaign.CrtRand.new(int(Time.get_unix_time_from_system()))
	var carried := carry if title_carry.is_empty() else title_carry
	carry = {}
	if carried.has("world"):
		_ready_loaded(carried)
		return
	if not carried.is_empty():
		save = [Debrief.SAVE_BASE, carried.image]     # the debrief's (or the title's) save
		pick = Campaign.Hooks.new() if carried.get("new_campaign", false) else null
	# the sandbox's PD2 chunk 0 starts as the title's new game does (0x46D780 "0"); its
	# other chunks from their SAVEDATA.ORG as it is (the title, ui/boot.gd, starts the rest)
	if pick != null and _pick_interactive():
		# the pilot choice's windows (0x422050) wait for the player: the build runs on a
		# worker thread meanwhile
		var ph := BattlePickHooks.new()
		ph.battle = self
		var th := Thread.new()
		var fresh := carried.is_empty() and campaign == "pd2"
		th.start(func(): return Mission.build(tables, doc, campaign, save, ph, crt, fresh))
		while th.is_alive():
			await get_tree().process_frame
		w = th.wait_to_finish()
		_pick_close()
	else:
		w = Mission.build(tables, doc, campaign, save, pick, crt, carried.is_empty() and pick != null and campaign == "pd2")
	w.play_safe = true          # in play: the game's crashes / hangs take RULES.md 5.23's logged safe path
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
	mission_hooks.flight = flight_hooks
	mission_hooks.options = options
	w.map_chg = GameData.tables(campaign).get("map_chg", []) if campaign == "dash" else []   # (DASH mission 6's tide)
	var resume: bool = carried.get("resume", false)
	if not resume and not carried.get("loop", false):
		# the mission start's loop (0x416CF0, Plan): DS:0x50663A and the mission turn 0, the
		# briefing (0x4DD2F0: the SCN_MIS record, the mission's init), the plan, the sortie
		Plan.pre_battle_begin(w)
	if not resume:
		brief_code = Plan.briefing(w, doc.get("record", PackedByteArray()), mission_hooks)
		pre_battle_rounds += 1
	if script_no == 1:
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
	if resume:
		_resume_battle()
	else:
		_plan()


func _scene_setup() -> void:
	## the map, the overlay, the camera and the command bar (a battle carried from a load)
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


func _ready_loaded(carried: Dictionary) -> void:
	## The system menu's load (Title.battle_menu entry 1) has set the mission up again from
	## the save (possibly another mission: the scene is the loaded chunk's); the player's
	## phase goes on with that world, as 0x4847C0 returns to the command loop.
	w = carried.world
	rng = carried.rng
	script_no = w.script_no
	_battle_hooks()
	_scene_setup()
	_resumed_phase()


func _battle_hooks() -> void:
	mission_hooks = BattleMissionHooks.new()
	mission_hooks.battle = self
	flight_hooks = BattleFlightHooks.new()
	flight_hooks.battle = self
	flight_hooks.easy = options & 2 != 0
	mission_hooks.flight = flight_hooks
	mission_hooks.options = options
	hooks = SandboxHooks.new(w, false, rng)
	hooks.battle = self
	names = {"crew": GameData.tables(campaign).crew_names, "machine": GameData.tables(campaign).machine_names}
	w.map_chg = GameData.tables(campaign).get("map_chg", []) if campaign == "dash" else []


func _resume_battle() -> void:
	## game_mode_loop with the title's bit 0x80 (a save made in a battle): no mission start
	## (0x416CF0), DS:0x50663A = 1, then 0x436530: mission_loop on the save
	## (Title.mission_resume: the load script, KEMURInn.DAT, the start script; no
	## start_units nor upkeep), and the player's phase goes on.
	w.mode_663a = 1
	Debrief.fire_point_from_ds(w)
	var rh := ResumeHooks.new()
	rh.battle = self
	var r := Title.mission_resume(w, rng, rh)
	if r in Title.BATTLE_ABORTS:
		_game_closed(r)
		return
	if r:
		_end_mission(r, true)
		return
	_resumed_phase()


func _resumed_phase() -> void:
	## the loop's top: the date window, the flyers' list, the player's phase
	w.phase = 0
	squad = Mission.player_units(w)
	sandbox = squad.is_empty()
	_begin_done()


func _game_closed(code: int) -> void:
	## 0x10000 (a save that cannot be read back, a window gone): the game itself ends
	## there; the engine says so and goes back to the title
	mission_over = true
	say("[color=red]%s[/color]" % uif("UI_GAME_CLOSED", ["0x%X" % code]))
	_show_debrief([], [])


class ResumeHooks extends Title.BattleSaveHooks:
	## mission_resume's files (user://saves) and the mission's scripts
	var battle

	func read(name: String) -> Variant:
		return SaveFiles.read(name)

	func error(text: int) -> void:
		battle.say("[color=red]%s[/color]" % battle.menu_text(text))

	func load_script() -> void:
		MissionScripts.run_load(battle.w)

	func start_script() -> int:
		return MissionScripts.run_start(battle.w, battle.rng, battle.mission_hooks)


func _begin_battle() -> void:
	w.mode_663a = 1                      # game_mode_loop: DS:0x50663A = 1, then the battle (0x436530)
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
	MissionScripts.run_load(w)           # mission_loop's first call: the load script (0x51F1B8)
	w.set_ds8(0x50ADF2, 0)               # mission_loop clears the end code first
	Mission.layers_reset(w)
	Mission.start_units(w)
	_script_turn(2)
	if w.ds8(0x50ADF2):                  # the end code after the start script: the mission ends
		_end_mission(w.ds8(0x50ADF2))
		return
	Mission.rebuild_occupancy(w)
	MissionScripts.run_start(w, rng, mission_hooks)   # the start script (table 0x51F0F8)
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
	## screen, 0x460D60; MissionScripts.run_deploy): 1 passes; a refusal shows its dialog
	## (0x4DD390, answered with its first choice); a mission not ported passes.
	var battle

	func deploy() -> int:
		return MissionScripts.run_deploy(battle.w, battle.mission_hooks)

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


class SortieDriveHooks extends Campaign.SortieHooks:
	## The roster's and the bulk menu's lists and questions answered from a queue; past its
	## end the request is recorded and cancelled (lists -2, questions 0): a dry run finds the
	## next question (as EquipDriveHooks).
	var answers: Array
	var request: Variant = null
	var notes: Array = []

	func _init(a: Array) -> void:
		answers = a.duplicate()

	func _next(req: Array, d: int) -> int:
		if not answers.is_empty():
			return answers.pop_front()
		if request == null:
			request = req
		return d

	func roster(rows: Array) -> int:
		return _next(["roster", rows.duplicate()], -2)

	func bulk(which: String, n: int) -> int:
		return _next(["bulk", which, n], -2)

	func ask(msg: int) -> int:
		return _next(["ask", msg], 0)

	func note(code: int, who: int) -> int:
		notes.append(code)
		return 0


var sortie_act: Variant = null      # ["roster"] / ["bulk", air] being answered
var sortie_answers: Array = []
var sortie_request: Variant = null
const BULK_SCOPES := [0x510474, 0x51047C, 0x510488]      # DS:0x50D6E1's list (0x462390)
const BULK_ACTIONS := [0x510494, 0x5104A0, 0x5104B4]     # DS:0x50D6ED
const BULK_POOL_ACTIONS := [0x5104C8, 0x5104D4]          # DS:0x50D6F9 (its first two)


func _sortie_press(act: Array) -> void:
	sortie_act = act
	sortie_answers = []
	sortie_text = ""
	_sortie_advance()


func _sortie_answer(a: int) -> void:
	sortie_answers.append(a)
	_sortie_advance()


func _sortie_run(world: Pd2World, hk: SortieDriveHooks) -> Variant:
	if sortie_act[0] == "roster":
		return Campaign.sortie_roster(world, hk)
	return Campaign.sortie_bulk(world, hk, sortie_act[1], sortie_sel)


func _sortie_advance() -> void:
	## dry-run the roster / bulk menu with the answers so far; a new question shows, else
	## it runs on the world (the roster rewrites the pool and the members in its order)
	var dh := SortieDriveHooks.new(sortie_answers)
	_sortie_run(w.duplicate_world(), dh)
	sortie_request = dh.request
	var lines := []
	if sortie_request == null:
		var hk := SortieDriveHooks.new(sortie_answers)
		var r: Variant = _sortie_run(w, hk)
		if r is Array and r[1] != 0x40:
			sortie_sel = r[1]                  # a member picked: its group is selected
		sortie_act = null
		for n in hk.notes:
			lines.append(mes(n))
	else:
		for n in dh.notes:
			lines.append(mes(n))
	sortie_text = "\n".join(lines)
	_sortie_draw()


func header_words(id: int) -> Array:
	## a list window's column headers (MES 0x1AF, 0x1B2, 0x1B8, 0x1CD): the words of its
	## line, or of its two lines read down (the roster's vertical headers)
	var t := GameData.base_text(campaign, id, [], mission_index).replace("\r", "\n")
	var lines := []
	for l in t.split("\n"):
		var words := []
		for x in l.split(" ", false):
			words.append(x)
		if not words.is_empty():
			lines.append(words)
	if lines.size() == 2 and lines[0].size() == lines[1].size():
		var out := []
		for i in lines[0].size():
			out.append(lines[0][i] + lines[1][i])
		return out
	return lines[0] if not lines.is_empty() else []


func roster_row_text(c: int) -> String:
	## a roster row (0x46A6D0's columns): the pilot, its state, AP, ground / air attack,
	## melee, defence, the four skills (crew +8 bits 0-3), its machine
	var q := func(f: int) -> int: return w.crew[c * 16 + f]
	var st := "!" if q.call(6) & 1 else ("?" if q.call(6) & 2 else ("*" if q.call(5) != 0xFF else "-"))
	var skills := ""
	for b in 4:
		skills += "o" if q.call(8) & (1 << b) else "."
	return "%s  %s %2d %2d %2d %2d %2d %s" % [unit_name(c), st, Flight.s8(q.call(9)), Flight.s8(q.call(0xA)),
		Flight.s8(q.call(0xB)), Flight.s8(q.call(0xC)), Flight.s8(q.call(0xD)), skills]


func list_box(parent: Control) -> VBoxContainer:
	## a scrolling column for a list window's rows
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 200)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(sc)
	var v := VBoxContainer.new()
	sc.add_child(v)
	return v


func _sortie_request_ui(box: VBoxContainer) -> void:
	## the roster's / bulk menu's open list or question
	var q := VBoxContainer.new()
	box.add_child(q)
	match sortie_request[0]:
		"ask":
			var l := Label.new()
			l.text = mes(sortie_request[1])
			q.add_child(l)
			var hb := HBoxContainer.new()
			q.add_child(hb)
			for yes in [true, false]:
				var bt := Button.new()
				bt.text = ui("UI_YES") if yes else ui("UI_NO")
				bt.pressed.connect(_sortie_answer.bind(1 if yes else 0))
				hb.add_child(bt)
		"roster":
			var heads := HBoxContainer.new()
			q.add_child(heads)
			var words := header_words(0x1CD)
			for col in 12:
				var hb := Button.new()
				hb.text = words[col] if col < words.size() else str(col)
				hb.tooltip_text = ui("UI_SORT")
				hb.pressed.connect(_sortie_answer.bind(col))
				heads.add_child(hb)
			var rows: Array = sortie_request[1]
			var lb := list_box(q)
			for i in rows.size():
				var bt := Button.new()
				bt.text = roster_row_text(rows[i])
				bt.alignment = HORIZONTAL_ALIGNMENT_LEFT
				bt.pressed.connect(_sortie_answer.bind(12 + i))
				lb.add_child(bt)
		"bulk":
			var which: String = sortie_request[1]
			var n: int = sortie_request[2]
			var texts: Array = BULK_SCOPES if which == "scope" else (BULK_ACTIONS if n == 3 else BULK_POOL_ACTIONS)
			for i in n:
				var bt := Button.new()
				bt.text = GameData.exe_text(campaign, texts[i])
				bt.pressed.connect(_sortie_answer.bind(i))
				q.add_child(bt)
	var cb := Button.new()
	cb.text = ui("UI_CANCEL") if sortie_request[0] != "roster" else ui("UI_CLOSE")
	cb.pressed.connect(_sortie_answer.bind(-2 if sortie_request[0] != "ask" else 0))
	q.add_child(cb)


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


# --- the briefing (0x4DD2F0) and the operation plan (0x443F60, "plan_g.pac") ------------

var brief_code := 0             # the briefing's result, for 0x416CF0's loop (Plan.pre_battle_round)
var plan_code := 0              # the plan's
var plan_window := true         # false: the plan presses done at once (tests)
var plan_panel: PanelContainer
## the plan's state between buttons: mode "page" (k), "orders" (g, the selected group;
## ask: the open list or question), "list", "maps" (i)
var plan_st := {}


func _plan() -> void:
	## The operation plan before the sortie (Plan.plan_screen's buttons): the mission's
	## pages A-D, the orders (the player's groups' name, plan type, time, target), the
	## plans' list, the area maps, done. Without a window it presses done at once.
	if auto_react or not sortie_window or not plan_window:
		plan_code = Plan.plan_screen(w, Plan.Hooks.new(), [])
		_sortie()
		return
	if hud_panel:
		hud_panel.visible = false
	plan_st = {"mode": "page", "k": 0, "g": 0, "ask": null, "i": 0, "j": 0}
	_plan_view_open()
	_plan_draw()


var plan_view: PlanView = null


func _plan_view_open() -> void:
	## the plan's window drawn from the import (ui/plan_view.gd), scaled to the screen; its
	## regions and clicks drive the same state as the button row
	plan_view = PlanView.new()
	plan_view.battle = self
	plan_view.chunk = Debrief.chunk(w)
	plan_view.title = SaveFiles.mission_name(script_no)
	plan_view.pressed.connect(_plan_region)
	plan_view.maps_nav.connect(func(k: int):
		# 0x444500's loop: next and the one before wrap over the four maps; close
		match k:
			0:
				plan_view.maps_i = 0 if plan_view.maps_i == 3 else plan_view.maps_i + 1
			1:
				plan_view.maps_i = 3 if plan_view.maps_i == 0 else plan_view.maps_i - 1
			2:
				plan_view.maps_i = -1
				plan_st.mode = "page"
		plan_st.i = maxi(plan_view.maps_i, 0)
		plan_view.queue_redraw())
	plan_view.advanced.connect(func(): plan_st.j += 1; _plan_draw())
	hud_layer.add_child(plan_view)
	var vs := get_viewport().get_visible_rect().size
	var sc := minf(vs.x / PlanView.W, vs.y / PlanView.H) * 0.96
	plan_view.scale = Vector2(sc, sc)
	plan_view.position = (vs - Vector2(PlanView.W, PlanView.H) * sc) / 2


func _plan_region(i: int) -> void:
	## the screen's regions (0x438210(9), DS:0x514968): pages A-D, the orders, the plans'
	## list, done, the area maps, XMS (a note: DS:0x50CBE4 0x514A98 "XMS : USE", else
	## 0x514AA4 "XMS : unUSE")
	if plan_st.mode == "orders":
		return
	match i:
		0, 1, 2, 3:
			plan_st.mode = "page"
			plan_st.k = i
			plan_st.j = 0
		4:
			plan_st.mode = "orders"
			plan_st.g = 0
			plan_st.ask = null
		5:
			plan_st.mode = "list"
			if plan_view:
				_plan_list_show()
				return
		6:
			_plan_done()
			return
		7:
			plan_st.mode = "maps"
			plan_st.i = 0
			if plan_view:
				plan_view.maps_i = 0
		8:
			plan_view.note = plan_exe(0x514A98 if w.mem8(0x50CBE4) else 0x514AA4)
	_plan_draw()


func _plan_list_show() -> void:
	## 0x4442C0: the title DS:0x50E060 in an unframed window at (0x188, 0x18) (28 x 1, 12 px),
	## then a window at (0x188, 0x38) (28 x 11 of 16 px, flags 1, no pattern) printing each
	## listed group's MES 0xF1 + type (0x0C, then the time 0x453900(+0x1D,
	## DS:0x506651), the call signs DS:0x50C881[+0] and DS:0x50C7E5[+1], the target), each
	## clearing the window and waiting for a click
	plan_view.page_title = ""
	plan_view.lines = []
	plan_view.blink = null
	plan_view.views = []
	plan_view.queue_redraw()
	for c in plan_view.get_children():
		c.queue_free()
	var mk := func(x: int, y: int, c: int, r: int, h: int) -> GameWindow:
		var gw := GameWindow.new()
		gw.cols = c
		gw.rows = r
		gw.lh = h
		gw.framed = false
		gw.black = true
		gw.code = 0x75
		gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gw.position = Vector2(x, y)
		gw._layout()
		plan_view.add_child(gw)
		return gw
	var tw: GameWindow = mk.call(0x188, 0x18, 0x1C, 1, 12)
	tw.waits = false
	tw.print_text(plan_exe(0x50E060))
	var lw: GameWindow = mk.call(0x188, 0x38, 0x1C, 0xB, 16)
	lw.waits = not _headless()
	plan_view.list_win = lw
	for g in Plan.list_rows(w):
		var t := Flight.gb(w, g, 0x21) & 15
		var time := Flight.s16(Flight.gb(w, g, 0x1D) | Flight.gb(w, g, 0x1E) << 8)
		var tgt := plan_target(g)
		if Plan.kind(w, g) == 0:                  # (here wsprintfA "%d-%d", DS:0x514AB0)
			tgt = "%d-%d" % [Flight.s8(Flight.gb(w, g, 0x1A)), Flight.s8(Flight.gb(w, g, 0x1B))]
		var text := GameData.base_text(campaign, 0xF1 + t, [plan_time(time), GameData.call_sign(campaign, 39 + Flight.gb(w, g, 0)),
				GameData.call_sign(campaign, Flight.gb(w, g, 1)), tgt, 5 * Flight.s8(Flight.gb(w, g, 0x20))], mission_index)   # (its 0x0C and '@' kept)
		if GameWindow.translated(text):
			text = GameWindow.fit(text, 0x1C)
			if not text.begins_with(char(0x0C)):
				text = char(0x0C) + text        # (the translations leave out the clear the Japanese starts with)
		await lw.print_text(text)
		if not is_instance_valid(lw):
			return
	plan_view.list_win = null


func _plan_view_update() -> void:
	if plan_view == null:
		return
	if plan_st.mode != "list":
		plan_view.list_win = null
		for c in plan_view.get_children():
			c.queue_free()                    # (the plans' list's windows)
	if plan_st.mode != "maps":
		plan_view.maps_i = -1
	if plan_st.mode == "orders":
		plan_view.orders = "open"
	elif plan_view.orders == "open":
		plan_view.orders = "closed"           # plan_gc.pac put back (0x444730's end)
	if plan_st.mode == "page":
		var st := Plan.view_step(w, plan_st.k, plan_st.j)
		plan_view.page_title = plan_exe(Plan.PAGE_TITLES[plan_st.k])
		plan_view.lines = st.lines.map(func(it): return plan_line(it).replace("@", "\n"))
		plan_view.views = st.views
		plan_view.blink = st.blink
	else:
		plan_view.page_title = ""
		plan_view.lines = []
		plan_view.blink = null
	plan_view.queue_redraw()


func plan_exe(va: int) -> String:
	return GameData.exe_text(campaign, va).replace(char(12), "").strip_edges()


func plan_time(t: int) -> String:
	## 0x453900: "HH:MM" of (t + DS:0x506651) x 5 minutes, the hour mod 24
	var m := (t + w.ds_506651) * 5
	return "%02d:%02d" % [(m / 60) % 24, m % 60]


func plan_line(item: Array) -> String:
	## a page's line: its MES text with its arguments (a crew's given name for "crew_of")
	var args := []
	for a in item[1]:
		if a is Array and a[0] == "crew_of":
			var cn: Array = GameData.tables(campaign).crew_names
			var n := Plan.crew_name_id(w, a[1])
			args.append(cn[n][0] if n >= 0 and n < cn.size() else "")
		else:
			args.append(a)
	return mes(item[0], args)


func plan_type_name(g: int) -> String:
	var names := SaveFiles.choice_texts(Plan.TYPE_NAMES)
	var i: int = w.scenario[Plan.entry(Flight.gb(w, g, 0x21))] if w.scenario.size() > Plan.entry(Flight.gb(w, g, 0x21)) else 0
	return names[i] if i < names.size() else "#%d" % i


func plan_target(g: int) -> String:
	## the orders' target line (0x446320): a cell, a direction, a site, or none
	match Plan.kind(w, g):
		0:
			return "%2d-%2d" % [Flight.s8(Flight.gb(w, g, 0x1A)), Flight.s8(Flight.gb(w, g, 0x1B))]
		1:
			var d := SaveFiles.choice_texts(Plan.DIRECTIONS)
			var i := Flight.s8(Flight.gb(w, g, 0x1F))
			return d[i].strip_edges() if i >= 0 and i < d.size() else ""
		2, 3:
			var s := SaveFiles.choice_texts(Plan.SITE_NAMES)
			var i := Flight.s8(Flight.gb(w, g, 0x1F))
			return s[i] if i >= 0 and i < s.size() else ""
	return ""


func _plan_draw() -> void:
	_plan_view_update()
	if plan_panel:
		plan_panel.queue_free()
	plan_panel = PanelContainer.new()
	var theme := Theme.new()
	theme.default_font_size = 8
	plan_panel.theme = theme
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.12, 0.97)
	bg.set_content_margin_all(8)
	plan_panel.add_theme_stylebox_override("panel", bg)
	plan_panel.position = Vector2(4, 4)
	var box := VBoxContainer.new()
	plan_panel.add_child(box)
	if plan_view == null:
		var title := Label.new()
		title.text = "%s  %s" % [ui("UI_PLAN"), SaveFiles.mission_name(script_no)]
		box.add_child(title)
	var buttons := HBoxContainer.new()            # the screen's nine regions (0x438210(9))
	box.add_child(buttons)
	buttons.visible = plan_view == null           # (the plan's window takes its own clicks)
	var orders_open: bool = plan_st.mode == "orders"
	for k in 4:
		buttons.add_child(_plan_button(plan_exe(Plan.PAGE_TITLES[k]), func(): plan_st.mode = "page"; plan_st.k = k; plan_st.j = 0, orders_open))
	buttons.add_child(_plan_button(plan_exe(Plan.ORDERS_TITLE), func(): plan_st.mode = "orders"; plan_st.g = 0; plan_st.ask = null, orders_open))
	buttons.add_child(_plan_button(plan_exe(Plan.LIST_TITLE), func(): plan_st.mode = "list", orders_open))
	buttons.add_child(_plan_button(ui("UI_PLAN_MAPS"), func(): plan_st.mode = "maps"; plan_st.i = 0, orders_open))
	var done := Button.new()
	done.text = ui("UI_PLAN_DONE")
	done.disabled = orders_open
	done.pressed.connect(_plan_done)
	buttons.add_child(done)
	match plan_st.mode:
		"page":
			if plan_view == null:
				_plan_page_ui(box)
		"orders":
			_plan_orders_ui(box)
		"list":
			if plan_view == null:
				_plan_list_ui(box)
		"maps":
			if plan_view == null:
				_plan_maps_ui(box)
	hud_layer.add_child(plan_panel)
	plan_panel.visible = plan_view == null or plan_st.mode == "orders"


func _plan_button(text: String, f: Callable, disabled := false) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = disabled
	b.pressed.connect(func(): f.call(); _plan_draw())
	return b


func _plan_done() -> void:
	plan_code = 0
	plan_panel.queue_free()
	plan_panel = null
	if plan_view:
		plan_view.queue_free()
		plan_view = null
	_sortie()


func _plan_page_ui(box: VBoxContainer) -> void:
	## the mission's page k (its hook in tables 0x51EAE8 .. 0x51EC08): its lines, a blank
	## line where the game waits for a click
	var v := list_box(box)
	v.custom_minimum_size = Vector2(420, 0)
	var head := Label.new()
	head.text = plan_exe(Plan.PAGE_TITLES[plan_st.k])
	v.add_child(head)
	for item in Plan.page(w, plan_st.k):
		var l := Label.new()
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(400, 0)
		l.text = "" if item[0] < 0 else plan_line(item).replace("@", "\n")
		v.add_child(l)


func _plan_list_ui(box: VBoxContainer) -> void:
	## 0x4442C0: each group's call sign, then its type's line (MES 0xF1 + t) with its time
	var v := list_box(box)
	for g in Plan.list_rows(w):
		var t := Flight.gb(w, g, 0x21) & 15
		var time := Flight.s16(Flight.gb(w, g, 0x1D) | Flight.gb(w, g, 0x1E) << 8)
		var l := Label.new()
		l.text = "%s  %s" % [GameData.call_sign(campaign, Flight.gb(w, g, 1)), mes(0xF1 + t, [plan_time(time)])]
		v.add_child(l)


func _plan_maps_ui(box: VBoxContainer) -> void:
	## 0x444500: AMAP.pac entry DS:0x50663D * 4 - 4 + i; next / the one before wrap
	var t := _plan_tex("%s/%s/images/amap/%02d.bmp" % [GameData.ROOT, campaign, mission_index * 4 + plan_st.i])
	if t:
		var r := TextureRect.new()
		r.texture = t
		box.add_child(r)
	else:
		var l := Label.new()
		l.text = "%s %d / 4" % [ui("UI_PLAN_MAPS"), plan_st.i + 1]
		box.add_child(l)
	var row := HBoxContainer.new()
	box.add_child(row)
	row.add_child(_plan_button("<", func(): plan_st.i = 3 if plan_st.i == 0 else plan_st.i - 1))
	row.add_child(_plan_button(">", func(): plan_st.i = 0 if plan_st.i == 3 else plan_st.i + 1))
	row.add_child(_plan_button(ui("UI_BACK"), func(): plan_st.mode = "page"; plan_st.k = 0))


var _plan_texs := {}


func _plan_tex(path: String) -> Texture2D:
	if not _plan_texs.has(path):
		var img := Image.load_from_file(path) if FileAccess.file_exists(path) else null
		_plan_texs[path] = ImageTexture.create_from_image(img) if img else null
	return _plan_texs[path]


func _plan_orders_ui(box: VBoxContainer) -> void:
	## 0x444730: the selected group's orders (0x446320's lines) and its six buttons
	var g: int = plan_st.g
	var t := Flight.gb(w, g, 0x21) & 15
	var time := Flight.s16(Flight.gb(w, g, 0x1D) | Flight.gb(w, g, 0x1E) << 8)
	var info := VBoxContainer.new()
	box.add_child(info)
	for s in [GameData.call_sign(campaign, Flight.gb(w, g, 1)) + "  " + group_name(g),
			plan_type_name(g), mes(0xC1 + t) + "  " + plan_time(time),
			mes(0xD1 + t) + "  " + plan_target(g)]:
		var l := Label.new()
		l.text = s
		info.add_child(l)
	for id in Plan.requirements(w, g):
		var l := Label.new()
		l.text = mes(id)
		info.add_child(l)
	var ex := Label.new()
	ex.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ex.custom_minimum_size = Vector2(400, 0)
	ex.text = mes(0xE1 + t).replace("@", "\n")
	info.add_child(ex)
	if plan_st.ask != null:
		_plan_ask_ui(box)
		return
	var row := HBoxContainer.new()               # regions 0x438210(6): leave, group, name, type, time, target
	box.add_child(row)
	row.add_child(_plan_button(ui("UI_PLAN_LEAVE"), _plan_leave))
	row.add_child(_plan_button(ui("UI_PLAN_GROUP"), func(): plan_st.ask = ["group", Plan.rows_groups(w)]))
	row.add_child(_plan_button(ui("UI_PLAN_NAME"), func(): plan_st.ask = ["name", range(Plan.NAMES)]))
	row.add_child(_plan_button(ui("UI_PLAN_TYPE"), func():
		var rows := Plan.rows_types(w, g)
		if not rows.is_empty():
			plan_st.ask = ["type", rows]))
	row.add_child(_plan_button(ui("UI_PLAN_TIME"), func():
		var tt := Plan.times(w, g)
		if tt[1] > 0:
			plan_st.ask = ["time", range(tt[0], tt[0] + tt[1])]))
	row.add_child(_plan_button(ui("UI_PLAN_TARGET"), _plan_target_ask))


func _plan_target_ask() -> void:
	## button 5, by the plan's kind: 0 a cell of the map, 1 a direction, 2 / 3 a site
	var g: int = plan_st.g
	match Plan.kind(w, g):
		0:
			plan_st.ask = ["cell"]
		1:
			plan_st.ask = ["direction", range(8)]
		2:
			plan_st.ask = ["site", Plan.sites(w, Plan.SITES_A)]
		3:
			plan_st.ask = ["site", Plan.sites(w, Plan.SITES_B)]


func plan_choices(arr: int) -> Array:
	return SaveFiles.choice_texts(arr)


func _plan_leave() -> void:
	## button 0: the mission's objective message, if any, with 無視 (leave) / 再考 (stay)
	var m := Plan.objective(w)
	if m < 0:
		plan_st.mode = "page"
		plan_st.k = 0
	else:
		plan_st.ask = ["objective", m]


func _plan_ask_ui(box: VBoxContainer) -> void:
	var a: Array = plan_st.ask
	var g: int = plan_st.g
	var v := list_box(box)
	var close := func(): plan_st.ask = null; _plan_draw()
	match a[0]:
		"objective":
			var l := Label.new()
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size = Vector2(400, 0)
			l.text = mes(a[1] + 0x20).replace("@", "\n")
			v.add_child(l)
			var labels := SaveFiles.choice_texts(Plan.OBJECTIVE_BUTTONS)
			for i in 2:
				var b := Button.new()
				b.text = labels[i] if i < labels.size() else str(i)
				b.pressed.connect(func():
					plan_st.ask = null
					if i == 0:
						plan_st.mode = "page"
						plan_st.k = 0
					_plan_draw())
				v.add_child(b)
		"cell":
			var r := TextureRect.new()
			r.texture = _plan_tex("%s/%s/images/smap/%02d.bmp" % [GameData.ROOT, campaign, mission_index])
			r.custom_minimum_size = Vector2(360, 360)
			r.mouse_filter = Control.MOUSE_FILTER_STOP
			r.gui_input.connect(func(ev):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					var x := int(ev.position.x) / 24
					var y := int(ev.position.y) / 24
					# 0x4459E0: a cell of the 15 x 15 grid, not the camera point's
					if x < 15 and y < 15 and (x != w.ds16(0x50AD95) or y != w.ds16(0x50AD97)):
						Flight.setgb(w, g, 0x1A, x)
						Flight.setgb(w, g, 0x1B, y)
						plan_st.ask = null
						_plan_draw())
			v.add_child(r)
		"site":
			if a.size() > 2:                       # 0x451E30: the site question (0x514BB8)
				var q := Label.new()
				q.text = plan_exe(Plan.SITE_QUESTION)
				v.add_child(q)
				for yes in [true, false]:
					var b := Button.new()
					b.text = ui("UI_YES") if yes else ui("UI_NO")
					b.pressed.connect(func():
						if yes:
							Flight.setgb(w, g, 0x1F, a[2])
							plan_st.ask = null
						else:
							plan_st.ask = ["site", a[1]]
						_plan_draw())
					v.add_child(b)
			else:
				var names := SaveFiles.choice_texts(Plan.SITE_NAMES)
				for i in a[1]:
					var b := Button.new()
					b.text = names[i] if i < names.size() else str(i)
					b.pressed.connect(func(): plan_st.ask = ["site", a[1], i]; _plan_draw())
					v.add_child(b)
		_:
			for i in a[1].size():
				var row_v: int = a[1][i]
				var b := Button.new()
				match a[0]:
					"group":
						b.text = "%s  %s" % [GameData.call_sign(campaign, Flight.gb(w, row_v, 1)), group_name(row_v)]
					"name":
						b.text = GameData.call_sign(campaign, 39 + row_v)
					"type":
						var names := SaveFiles.choice_texts(Plan.TYPE_NAMES)
						var n: int = w.scenario[Plan.entry(row_v)] if w.scenario.size() > Plan.entry(row_v) else 0
						b.text = names[n] if n < names.size() else "#%d" % n
					"time":
						b.text = plan_time(row_v)
					"direction":
						var d := SaveFiles.choice_texts(Plan.DIRECTIONS)
						b.text = d[row_v].strip_edges() if row_v < d.size() else str(row_v)
				b.pressed.connect(func():
					match a[0]:
						"group":
							plan_st.g = row_v
						"name":
							if row_v != Flight.gb(w, g, 0):
								Flight.setgb(w, g, 0, row_v)
						"type":
							if row_v != Flight.gb(w, g, 0x21) & 15:
								Plan.set_type(w, g, row_v)
						"time":
							Plan.set_time(w, g, row_v)
						"direction":
							if row_v != Flight.s8(Flight.gb(w, g, 0x1F)):
								Flight.setgb(w, g, 0x1F, row_v)
					plan_st.ask = null
					_plan_draw())
				v.add_child(b)
	var c := Button.new()
	c.text = ui("UI_CANCEL")
	c.pressed.connect(close)
	box.add_child(c)


func _sortie() -> void:
	## The sortie screen before the battle: the formable groups (+2 bit 0), their members
	## and the free pilots; join, drop, start (the game's checks, then "start the
	## operation?"). Without a window (auto_react, sortie_window false) it presses start once.
	sortie_hooks = BattleSortieHooks.new()
	sortie_hooks.battle = self
	if auto_react or not sortie_window:
		var sr: Array = Campaign.sortie_screen(w, sortie_hooks, [["start"]])
		Plan.pre_battle_round(w, brief_code, plan_code, int(sr[0]))
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
	var tools := HBoxContainer.new()             # regions 0x31 (the roster), 0x32 / 0x33 (bulk)
	box.add_child(tools)
	for t in [["UI_ROSTER", ["roster"]], ["UI_BULK_GROUND", ["bulk", 0]], ["UI_BULK_AIR", ["bulk", 1]]]:
		var tb := Button.new()
		tb.text = ui(t[0])
		tb.disabled = sortie_request != null
		tb.pressed.connect(_sortie_press.bind(t[1]))
		tools.add_child(tb)
	if sortie_request != null:
		_sortie_request_ui(box)
	if sortie_text != "":
		var msg := Label.new()
		msg.text = sortie_text
		box.add_child(msg)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	if sortie_request != null:
		pass
	elif confirm:
		var q := Label.new()
		q.text = mes(0x1C)
		buttons.add_child(q)
		for yes in [true, false]:
			var b := Button.new()
			b.text = ui("UI_YES") if yes else ui("UI_NO")
			b.pressed.connect(func():
				Campaign.sortie_start(w, yes)
				if yes:
					Plan.pre_battle_round(w, brief_code, plan_code, 0)
					sortie_panel.queue_free()
					sortie_panel = null
					hud_panel.visible = hud_bar          # (the engine's bar stays as it was: H)
					_begin_battle()
				else:
					_sortie_draw())
			buttons.add_child(b)
	elif sortie_saving >= 0:
		_sortie_save_ui(box)
	elif sortie_loading >= 0:
		_sortie_load_ui(box)
	elif sortie_aborting:
		var q := Label.new()
		q.text = mes(0x1D9)
		buttons.add_child(q)
		for yes in [1, 0]:
			var b := Button.new()
			b.text = ui("UI_YES") if yes else ui("UI_NO")
			b.pressed.connect(_sortie_system_run.bind(0, yes))
			buttons.add_child(b)
	else:
		var st := Button.new()
		st.text = ui("UI_START")
		st.pressed.connect(func():
			sortie_text = ""
			var r := Campaign.sortie_check(w, sortie_hooks)
			_sortie_draw(r[0] == "start"))
		buttons.add_child(st)
		# region 0x45's list (DS:0x50D70D): 作戦中止, ＳＡＶＥ, ＬＯＡＤ; region 0x46, back
		var sys := SaveFiles.choice_texts(0x50D70D)
		for i in 3:
			var sv := Button.new()
			sv.text = sys[i] if sys.size() > i else ["ABORT", "SAVE", "LOAD"][i]
			sv.pressed.connect(_sortie_system_press.bind(i))
			buttons.add_child(sv)
		var bk := Button.new()
		bk.text = ui("UI_BACK")
		bk.pressed.connect(_sortie_back_press)
		buttons.add_child(bk)
	hud_layer.add_child(sortie_panel)


var sortie_saving := -1          # the sortie's save: 0x29 the slot list open, else the slot asked
var sortie_loading := -1         # the sortie's load: 0x29 the slot list open, else the slot asked
var sortie_aborting := false     # "abort the operation?" (MES 0x1D9) asked
var mission_record := PackedByteArray()     # the mission's SCN_MIS record (the briefing's, again in the loop)
var pre_battle_rounds := 0                  # 0x416CF0's rounds: briefing, plan, sortie


class SortieSystemHooks extends BattleSortieHooks:
	## Region 0x45's entries once the player has answered their windows (Campaign.
	## sortie_system): the list's entry, the abort question's answer, the save's slot and
	## answer (Title.save_game: PD2RECnn.BIN), the load's slot (Title.load_pick with rescue:
	## 0x4983A0, its confirm the slot line 0x498070 with 1); the files in user://saves.
	var entry := -2
	var answer := 0
	var pick := 0x29
	var notes: Array = []

	func system() -> int:
		return entry

	func ask(_msg: int) -> int:
		return answer

	func save_game(w: Pd2World) -> int:
		var wr := SaveFiles.Writer.new()
		wr.pick = pick
		wr.answer = answer
		var r := Title.save_game(w, wr)
		notes.append_array(wr.notes)
		return r

	func load_game(w: Pd2World) -> int:
		var lh := SortieLoadHooks.new()
		lh.chosen = pick
		lh.mode = w.mode_663a & 0xFF
		var r := Title.load_pick(w, lh, true)
		notes.append_array(lh.notes)
		return r

	func write(name: String, data: PackedByteArray) -> int:
		return 1 if SaveFiles.write(name, data) else 0

	func read(name: String) -> Variant:
		return SaveFiles.read(name)

	func campaign_set(w: Pd2World) -> void:
		var t := GameData.tables("pd2" if w.campaign else "dash")
		w.records = Pd2World.new(t.machines, t.launchers, t.ammo, PackedByteArray(), 1).records


class SortieLoadHooks extends Title.Hooks:
	## 0x4983A0's windows: the slot the player picked (then none), 0x498070 with 1 (its
	## question answered yes when the list was picked; another mode's save: the note
	## 0x519F0C and 0, back to the list, which then has nothing), the notes collected
	var chosen := 0x29
	var mode := 0
	var notes: Array = []

	func slot() -> int:
		var s := chosen
		chosen = 0x29
		return s

	func confirm(s: int) -> int:
		var line: Variant = Title.slot_line(SaveFiles.read("PD2REC%02d.BIN" % s), mode, true)
		if line is String:
			notes.append(0x519F0C)
			return 0
		return 1

	func box(text: Variant) -> int:
		notes.append(text)
		return 0

	func save_file(s: int) -> Variant:
		return SaveFiles.read("PD2REC%02d.BIN" % s)


func _sortie_system_press(entry: int) -> void:
	sortie_text = ""
	match entry:
		0:
			sortie_aborting = true
		1:
			sortie_saving = 0x29
		2:
			sortie_loading = 0x29
	_sortie_draw()


func _sortie_system_run(entry: int, answer: int, pick := 0x29) -> void:
	## Campaign.sortie_system with the player's answers; a result ends the screen
	var hk := SortieSystemHooks.new()
	hk.battle = self
	hk.entry = entry
	hk.answer = answer
	hk.pick = pick
	var r: Variant = Campaign.sortie_system(w, hk)
	sortie_text = "\n".join(hk.notes.map(func(t): return mes(int(t)) if int(t) < 0x500000 else SaveFiles.exe(int(t))))
	sortie_saving = -1
	sortie_loading = -1
	sortie_aborting = false
	if r == null:
		_sortie_draw()
		return
	_sortie_end(int(r))


func _sortie_back_press() -> void:
	_sortie_end(Campaign.sortie_back(sortie_hooks))


func _sortie_end(result: int) -> void:
	## the sortie's result into 0x416CF0's loop (Plan.pre_battle_round): 0 goes round again
	## (the briefing, the plan, the sortie), 0x80 the battle, the rest leave for the title
	if result >= 0x80000000:
		result -= 0x100000000
	var code: Array = Plan.pre_battle_round(w, brief_code, plan_code, result)
	if sortie_panel:
		sortie_panel.queue_free()
		sortie_panel = null
	if code[0] == 0:
		_pre_battle_again()
		return
	if code[0] == 0x80:
		# (the sortie's 3: a load that changed DS:0x50663A; savedata.tmp written, then the
		# battle on that save, as the title's bit 0x80)
		_reload_from_save(true)
		return
	say(uif("UI_SORTIE_LEFT", ["0x%X" % code[0]]))
	mission_over = true
	get_tree().change_scene_to_file("res://ui/boot.tscn")


func _pre_battle_again() -> void:
	## 0x416CF0's loop goes round: the briefing (0x4DD2F0, the mission's init) and the plan,
	## then the sortie again; a load of another mission's save gives that mission's scene
	if Debrief.chunk(w) - 1 != mission_index or ("pd2" if w.campaign else "dash") != campaign:
		_reload_from_save(false)
		return
	brief_code = Plan.briefing(w, mission_record, mission_hooks)
	pre_battle_rounds += 1
	_plan()


func _reload_from_save(resume: bool) -> void:
	var b: Node = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2" if w.campaign else "dash"
	b.mission_index = Debrief.chunk(w) - 1
	b.title_carry = {"image": Debrief.save_image(w), "script": w.script_no, "stash": w.stash,
		"loop": not resume, "resume": resume}
	b.auto_react = auto_react
	b.sortie_window = sortie_window
	b.plan_window = plan_window
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	queue_free()


func _sortie_save_ui(box: VBoxContainer) -> void:
	## The sortie's save (0x497F60): the slot list (0x497A10), then the slot's line and the
	## overwrite question (0x498070 with 0); Title.sortie_save writes PD2RECnn.BIN,
	## KEMURInn.DAT and MEMBERnn.DAT to user://saves.
	if sortie_saving == 0x29:
		var v := list_box(box)
		for sl in Title.SLOTS:
			var b := Button.new()
			b.text = SaveFiles.slot_line(sl, 0x519ED8)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(func(): sortie_saving = sl; _sortie_draw())
			v.add_child(b)
		var c := Button.new()
		c.text = ui("UI_CANCEL")
		c.pressed.connect(func(): sortie_saving = -1; _sortie_draw())
		box.add_child(c)
		return
	var q := Label.new()
	q.text = SaveFiles.slot_line(sortie_saving, 0x519ED8)
	box.add_child(q)
	var row := HBoxContainer.new()
	box.add_child(row)
	for yes in [1, 0]:
		var b := Button.new()
		b.text = ui("UI_YES") if yes else ui("UI_NO")
		b.pressed.connect(_sortie_system_run.bind(1, yes, sortie_saving))
		row.add_child(b)


func _sortie_load_ui(box: VBoxContainer) -> void:
	## The sortie's load (0x4983A0): the slot list (0x498290: the saves there are), then
	## the slot's line and the load question (0x498070 with 1)
	if sortie_loading == 0x29:
		var v := list_box(box)
		for sl in Title.SLOTS:
			if not Title.slot_line(SaveFiles.read("PD2REC%02d.BIN" % sl), 0xFF, true) is Array:
				continue
			var b := Button.new()
			b.text = SaveFiles.slot_line(sl, 0x519EE8)
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(func(): sortie_loading = sl; _sortie_draw())
			v.add_child(b)
		var c := Button.new()
		c.text = ui("UI_CANCEL")
		c.pressed.connect(func(): sortie_loading = -1; _sortie_draw())
		box.add_child(c)
		return
	var line: Variant = Title.slot_line(SaveFiles.read("PD2REC%02d.BIN" % sortie_loading), w.mode_663a & 0xFF, true)
	if line is String:                       # a save made in a battle: 0x498070's note 0x519F0C
		sortie_text = SaveFiles.exe(0x519F0C)
		sortie_loading = 0x29
		call_deferred("_sortie_draw")
		return
	var q := Label.new()
	q.text = SaveFiles.slot_line(sortie_loading, 0x519EE8)
	box.add_child(q)
	var row := HBoxContainer.new()
	box.add_child(row)
	for yes in [1, 0]:
		var b := Button.new()
		b.text = ui("UI_YES") if yes else ui("UI_NO")
		b.pressed.connect(func():
			if yes:
				_sortie_system_run(2, 1, sortie_loading)
			else:
				sortie_loading = 0x29
				_sortie_draw())
		row.add_child(b)


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
const PICK_OFFSET := {"machine": 6, "slot": 0xD, "item": 7, "pocket": 0, "menu": 0, "register": 0,
		"recall": 0, "copy": 0}
const PICK_HEADERS := {"machine": 0x1AF, "slot": 0x1B2, "item": 0x1B8}   # the pickers' column headers
const TEMPLATE_LABELS := {"save": 0x51571C, "load": 0x51572C, "copy": 0x51573C, "new": 0x515B90,
		"all": 0x515B18, "machine+weapons": 0x515B44, "weapons": 0x515B64, "items": 0x515B7C}
const TEMPLATE_TITLES := {"menu": 0, "register": 0x515BA8, "recall": 0x515C0C, "copy": 0x515CAC}


func _equip_begin(k: int) -> void:
	# reg_unit.dat is read each time the screen opens (0x454E60): the player's, else as shipped
	var path := "user://%s/reg_unit.dat" % campaign
	w.reg_unit = Equipment.load_reg_unit(campaign) if FileAccess.file_exists(path) else GameData.reg_unit_shipped(campaign)
	if w.reg_unit.size() != Equipment.REG_SIZE:
		w.reg_unit = Equipment.reg_unit_blank()
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
		if w.has_meta("reg_unit_written"):           # a register: the file is written (0x45CCE0)
			w.remove_meta("reg_unit_written")
			Equipment.save_reg_unit(campaign, w.reg_unit)
		var lines := []
		for n in hk.notes:
			lines.append(equip_msg(n))
		equip_text = "\n".join(lines)
		if equip_sess.done:
			equip_sess = {}
			_sortie_draw()
			return
	else:
		var lines := []
		for n in dh.notes:
			lines.append(equip_msg(n))
		equip_text = "\n".join(lines)
	_equip_draw()


func equip_msg(id: int) -> String:
	## the armament screen's texts: MES.PCK's, or Pd2.exe's own (the template menu's)
	return GameData.exe_text(campaign, id) if id >= 0x500000 else mes(id)


func _name_of(table: String, id: int) -> String:
	var t: Dictionary = GameData.tables(campaign).get(table, {})
	return str(t.get(str(id), "#%d" % id))


func _equip_entry_text(kind: String, e: Variant) -> String:
	if kind in ["menu", "register", "recall", "copy"]:
		var t: String = e
		if TEMPLATE_LABELS.has(t):
			return GameData.exe_text(campaign, TEMPLATE_LABELS[t])
		if t.begins_with("reg"):
			return GameData.exe_text(campaign, 0x515B9C, [int(t.substr(3))])
		if t.begins_with("crew"):
			var c := int(t.substr(4))
			var m := Flight.s8(w.ub(c, 0xC))
			var mn: Array = names.machine
			return "%s  %s" % [unit_name(c), mn[m] if m >= 0 and m < mn.size() else "-"]
		return t
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
			l.text = equip_msg(equip_request[1])
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
			if TEMPLATE_TITLES.get(kind, 0):
				var tl := Label.new()
				tl.text = GameData.exe_text(campaign, TEMPLATE_TITLES[kind])
				q.add_child(tl)
			if PICK_HEADERS.has(kind):                # the column headers sort the list
				var heads := HBoxContainer.new()
				q.add_child(heads)
				var words := header_words(PICK_HEADERS[kind])
				for col in PICK_OFFSET[kind]:
					var hb := Button.new()
					hb.text = words[col] if col < words.size() else str(col)
					hb.tooltip_text = ui("UI_SORT")
					hb.pressed.connect(_equip_answer.bind(col))
					heads.add_child(hb)
			var lb := list_box(q) if ents.size() > 6 else q
			for j in ents.size():
				var bt := Button.new()
				bt.text = _equip_entry_text(kind, ents[j])
				bt.pressed.connect(_equip_answer.bind(PICK_OFFSET[kind] + j))
				lb.add_child(bt)
			var cb := Button.new()
			cb.text = ui("UI_CANCEL")
			cb.pressed.connect(_equip_answer.bind(-2))
			q.add_child(cb)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for pair in [["UI_CLEAR", "clear"], ["UI_UNDO", "undo"], ["UI_TEMPLATES", "menu"], ["UI_CLOSE", "close"]]:
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
		btn.pressed.connect(_fire_command.bind(b[1]))
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
	var entry11 := MissionScripts.run_menu(w, squad[0] if not squad.is_empty() else 0)   # table 0x51EF18: the unit menu's entry 11
	if entry11[0] == 1:
		cmds.append([mission_label(entry11[1]) + " [I]", _cmd_mission])
	cmds.append([ui("UI_EXPLOSIVES") + " [X]", _cmd_explosives])
	cmds.append([ui("UI_SLOT_MENU") + " [G]", _cmd_slot_menu])
	cmds.append([ui("UI_POCKET_MENU") + " [P]", _cmd_pocket_menu])   # the machine status window (the menu's entry 7)
	cmds.append([ui("UI_SYSTEM") + " [Esc]", _cmd_system])     # the command menu's entry 0x10 (0x4847C0)
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
	# the game's own screen: the info panel (hex_g.pac) at the main window's right edge
	# (Pd2.exe places its window at x 0x1B2 with Windows' caption; the engine draws no
	# caption and puts the 208 px client at 640 - 208 so it stays on the screen); the
	# command bar above is the engine's own and stays hidden (H shows it)
	panel.visible = false
	info_panel = InfoPanel.make(self)
	info_panel.position.x = MAIN_W - 0xD0
	info_panel.region.connect(_panel_region)
	_win_root().add_child(info_panel)
	panel_refresh()


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
	panel_refresh()
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

var _rpress := Vector2(-100, -100)
var hud_bar := false              # the engine's own command bar and log shown (H)


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		if ev.button_mask & MOUSE_BUTTON_MASK_RIGHT or ev.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			cam.position = (cam.position - ev.relative / cam.zoom).clamp(Vector2.ZERO, Vector2(MAP * TILE_W, MAP * TILE_H))
		hover = hex_at(get_global_mouse_position())
		overlay.queue_redraw()
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_RIGHT:
		# a right click (not a drag): the selected unit's command menu (0x4EF600's -2)
		if ev.pressed:
			_rpress = ev.position
		elif ev.position.distance_to(_rpress) < 4 and selected != -1 and not busy and react_look.is_empty() 				and w.active(selected) and not w.is_enemy(selected) and hex_pick.is_empty():
			open_command_menu(selected)
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom = (cam.zoom * 1.15).clamp(Vector2(0.15, 0.15), Vector2(3, 3))
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom = (cam.zoom / 1.15).clamp(Vector2(0.15, 0.15), Vector2(3, 3))
		elif ev.button_index == MOUSE_BUTTON_LEFT and not react_look.is_empty():
			var rl := react_look
			react_look = []
			_show_reaction_units(rl[0], rl[1], rl[2])
		elif ev.button_index == MOUSE_BUTTON_LEFT and not hex_pick.is_empty():
			var h := hex_at(get_global_mouse_position())
			if h in hex_pick or hex_pick == ["any"]:
				_answer_hex(h)
		elif ev.button_index == MOUSE_BUTTON_LEFT and not busy:
			_click(hex_at(get_global_mouse_position()))
	elif ev is InputEventKey and ev.pressed and not ev.echo and not busy:
		match ev.keycode:
			KEY_M: _set_mode("move")
			KEY_F: _fire_command("fire")
			KEY_A: _fire_command("aimed")
			KEY_Q: _fire_command("aa")
			KEY_S: _cmd_search()
			KEY_C: _cmd_conceal()
			KEY_K: _cmd_carry_mode()
			KEY_U: _cmd_item_mode()
			KEY_E: _end_turn()
			KEY_W: _cmd_withdraw()
			KEY_I: _cmd_mission()
			KEY_X: _cmd_explosives()
			KEY_G: _cmd_slot_menu()
			KEY_P: _cmd_pocket_menu()
			KEY_ESCAPE: _cmd_system()
			KEY_TAB: _next_unit()
			KEY_H:                                    # the engine's own command bar and log (debugging)
				hud_bar = not hud_bar
				if hud_panel:
					hud_panel.visible = hud_bar
			KEY_R:                                    # the last flight window, to look at again
				if radar_view and not radar_view.snap.is_empty():
					radar_view.visible = not radar_view.visible
			KEY_1, KEY_2, KEY_3, KEY_4: _set_slot(ev.keycode - KEY_1)


# --- the command menu (unit_command_menu 0x4EE8D0) and the info panel ---------------

var info_panel: InfoPanel = null


func command_menu_labels(u: int) -> Array:
	## 0x4DDF70: the entries DS:0x517EF0 0-10 (their %aHH codes as the printer's), the AP
	## digits written into them by the crew's skills (bit 1 search 4 / 8, bit 4 support 6 /
	## 12, bit 8 conceal 3 / 6, bit 2 carry 4 / 8), entry 10 carry (0x517F20) or release
	## (0x517F2E) by +0x34; the mission's own entry 11 (the menu hook of table 0x51EF18)
	var adds: Array = GameData.tables(campaign).get("script_choices", {}).get("517EF0", [])
	var sk := w.ucrew(u, 8)
	var digits := {6: (" 6" if sk & 4 else "12"), 8: (" 4" if sk & 1 else " 8"), 9: (" 3" if sk & 8 else " 6"),
		10: (" 4" if sk & 2 else " 8")}
	var out := []
	for i in 11:
		var va: int = (0x517F20 if w.ub(u, 0x34) == 0xFF else 0x517F2E) if i == 10 else str(adds[i]).hex_to_int() if i < adds.size() else 0
		var raw := GameData.exe_raw(campaign, va)
		if digits.has(i) and not (i == 10 and va == 0x517F2E):
			if raw.find("%") != -1 and raw.find("%a") == -1:
				raw = raw.replace("%2d", digits[i])            # (a translation: the number's place)
			else:
				raw = _patch_bytes(raw, 9, digits[i])         # bytes 9-10 (Shift-JIS) as the game writes them
		out.append(_codes(raw))
	var e11 := MissionScripts.run_menu(w, u)
	if e11[0] == 1:
		out.append(mission_label(e11[1]))
	return out


func _patch_bytes(t: String, at: int, two: String) -> String:
	## t with its Shift-JIS bytes at..at+1 replaced by two half-width characters
	var n := 0
	for i in t.length():
		if n == at and i + 1 < t.length():
			return t.substr(0, i) + two + t.substr(i + 2)
		n += 1 if GameWindow.half_width(t[i]) else 2
	return t


func _codes(t: String) -> String:
	## %aHH as the printer's colour codes (format_text's %s copies them so)
	var re := RegEx.create_from_string("%a([0-9A-Fa-f]{2})")
	var out := ""
	var last := 0
	for m in re.search_all(t):
		out += t.substr(last, m.get_start() - last) + "\u0001" + char(m.get_string(1).hex_to_int())
		last = m.get_end()
	return out + t.substr(last)


func open_command_menu(u: int) -> void:
	## unit_command_menu (0x4EE8D0): a select window of 13 columns at the cursor ((x & ~7) -
	## 0x10, y; kept inside by 0x452450's size), a right click closing it; the entries:
	## 0-2 move high speed / normal / careful, 3-5 fire normal / aimed / anti-air (the
	## picker first), 6 the support request, 7 the machine status (with its pilot, damage
	## and machine windows), 8 search, 9 conceal, 10 carry / release, 11 the mission's own
	if busy or mission_over or auto_react:
		return
	var labels := command_menu_labels(u)
	var n := labels.size()
	var ww := (13 + (3 if n > GameWindow.SCROLL_SHOWN else 0)) * 8 + 16
	var hh := (mini(n, GameWindow.SCROLL_SHOWN) + 1) * 16
	var m := _mouse_main()
	var x := (int(m.x) & 0xFFF8) - 0x10
	var y := int(m.y)
	if ww - 1 + x > MAIN_W:
		x = MAIN_W - ww
	if y - 1 + hh > MAIN_H:
		y = MAIN_H - hh
	var gw := GameWindow.select_window(maxi(x, 0), maxi(y, 0), 13, 0, 0, labels, 13, [], true)
	gw.role = "command"
	_hold([gw])
	react_panel = null                  # (not a question of a waiting thread)
	gw.chosen.connect(func(v: int):
		_close_window(gw)
		_command(u, v))


func _command(u: int, v: int) -> void:
	_select(u)
	match v:
		0, 1, 2:
			_set_move_mode(v)
			_set_mode("move")
		3:
			_fire_command("fire")
		4:
			_fire_command("aimed")
		5:
			_fire_command("aa")
		6:
			say(ui("UI_NOT_PORTED"))          # cmd_support_request (0x4E4560): not ported yet
		7:
			_cmd_pocket_menu()
		8:
			_cmd_search()
		9:
			_cmd_conceal()
		10:
			_cmd_carry_mode()
		11:
			_cmd_mission()


func _panel_region(k: int) -> void:
	## the info panel's regions, as the player phase (0x4EF600) and ui_map_click (0x47AC70)
	## answer them
	if busy or mission_over:
		return
	match k:
		4:
			_next_unit()                         # the face: the next DoLL (scroll_to)
		11:
			_cmd_withdraw()                      # 撤退: 0x1DE
		14:
			_confirm(msg(0x1E0), _end_turn, 1)  # 終了: 0x1E0, a message box of kind 1
		16:
			_cmd_system()                        # システム: 0x4847C0
		22:
			if selected != -1:
				_cmd_pocket_menu()               # the weapons' box: ui_machine_status
		_:
			say(ui("UI_NOT_PORTED"))             # 部隊 0x4EFC60, 武装 0x4E9D90, マップ 0x43A3E0,
			                                     # 作戦中止 0x1DF, 一斉 0x429540, 指令書 0x43BA20, 23


func panel_refresh() -> void:
	if info_panel and is_instance_valid(info_panel):
		info_panel.unit = selected
		info_panel.refresh()


func _set_mode(m: String) -> void:
	mode = m
	_update_move_map()


func _fire_command(m: String) -> void:
	## the fire commands' own start (cmd_fire 0x425AF0): the weapon picker in the command's
	## mode (0 normal, 1 aimed, 6 anti-air); a slot goes to its target map, a magazine to
	## the slot menu as the picker's column (both arms broken: 0x1B9), a right click back
	## to moving. Without a window (auto_react), as before: the mode with the current slot.
	if selected == -1 or busy or mission_over or auto_react or not FIRE_MODES.has(m):
		_set_mode(m)
		return
	var u := selected
	_open_weapon(u, FIRE_MODES[m], 0, func(v: int):
		if v == -2:
			_set_mode("move")
		elif v < 4:
			slot = v
			_set_mode(m)
		else:
			_set_mode(m)
			slot = v - 4
			_cmd_slot_menu())


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
		if w.active(o) and not w.is_enemy(o):
			open_command_menu(o)                 # 0x4EF600: an own unit's command menu
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

func msg_raw(id: int) -> String:
	## a battle message's format, its codes kept (for the list windows' coloured columns)
	return GameData.battle_raw(campaign, id, mission_index)


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
	## a message line (ui_message_line 0x452300), also in the log
	var t := msg(id, args)
	say(t.replace("@", "\n").strip_edges())
	if not auto_react:
		show_line(t)


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
	## ui_prompt_at_cursor (0x47EBE0): the choices are written in the message; 0 = the first,
	## a right click the second
	var parts := GameData.prompt_parts(text)
	var labels: Array = parts[1] if parts[1].size() >= 2 else [ui("UI_YES"), ui("UI_NO")]
	return ask_choice(text, [[labels[0], true], [labels[1], false]], default, "prompt")


## ui_message_box's buttons by caller (the kind each call site pushes): 0 了解 / 中止
## (DS:0x510444 / 0x51044C), 1 実行 / 中止 (0x510454 / 0x51045C)
const BOX_LABELS := [[0x510444, 0x51044C], [0x510454, 0x51045C]]


func ask_box(text: String, default: bool, kind := 0) -> bool:
	## ui_message_box (0x451FB0): the game reads non-zero as yes (step_mine_found 0x4756A0)
	var l: Array = BOX_LABELS[kind]
	return ask_choice(text, [[GameData.exe_text(campaign, l[0]), true], [GameData.exe_text(campaign, l[1]), false]],
			default, "box")


func ask_choice(text: String, options: Array, default: Variant, kind := "list") -> Variant:
	## Called on a worker thread (the move, the computer's turn): shows the question on the
	## main thread and waits for the answer. auto_react: the default, without asking.
	## kind: "prompt" (0x47EBE0), "box" (0x451FB0) or "list" (a select window, 0x40C090)
	if not scripted.is_empty():
		return scripted.pop_front()
	if auto_react:
		return default
	if OS.get_thread_caller_id() == OS.get_main_thread_id():
		push_error("ask_choice on the main thread: %s" % text)   # would wait forever
		return default
	call_deferred("_open_choice", text, options, kind)
	react_sem.wait()
	return react_answer


# --- the game's list windows (0x40C090) drawn from their message formats ------------

func pal_color(code: int) -> Color:
	## a %b colour code (format_text: byte 1 + code): the window printer 0x438FE0 takes its
	## high nibble into the 16-colour palette (DS:0x554B28, the battle's: the import's
	## tactical palette), each channel + 10
	var pal: Array = GameData.palette
	var i := (code >> 4) & 0xF
	if i >= pal.size():
		return Color.WHITE
	return Color8(mini(int(pal[i][0]) + 10, 255), mini(int(pal[i][1]) + 10, 255), mini(int(pal[i][2]) + 10, 255))


func text_cells(fmt: String, args: Array) -> Array:
	## a message format cut at its %b colour codes: [[text, colour code]], each part
	## formatted with its own arguments (format_text, which skips %b)
	var out := []
	var parts := fmt.split("%b")
	var ai := 0
	for pi in parts.size():
		var part: String = parts[pi]
		var code := 0xFF
		if pi > 0:
			code = int(args[ai]) if ai < args.size() else 0xFF
			ai += 1
		var n := 0
		var i := 0
		while i < part.length():
			if part[i] == "%":
				if i + 1 < part.length() and part[i + 1] == "%":
					i += 2
					continue
				n += 1
			i += 1
		var sub := args.slice(ai, ai + n)
		ai += n
		if part != "":
			out.append([GameData.format_text(part, sub), code])
	return out


func cb_unit_rows(units: Array) -> Array:
	## 0x4E3230's rows (WMES 0x1C4): the group's call sign, the pilot's names, the machine,
	## the damage (100 - condition; colour by condition: below 35, 35-49, 50 up) and the
	## group's state (SHIFT / BUSY / SUPPORT / STAND BY); a row not standing by is refused
	var rows := []
	for k in units:
		var g := Ai.unit_group(w, k)
		var fl := Flight.gb(w, g, 2) & 0xC0
		var state := 0x51F3D0                  # STAND BY (exe texts: SHIFT, BUSY, SUPPORT, STAND BY)
		var sc := 0xFF
		var refused := true
		if fl == 0:
			if w.ub(k, 6) == 1 or w.ub(k, 6) == 2:
				state = 0x51F3C8
				sc = 0x4F
			else:
				refused = false
		elif fl == 0x40:
			state = 0x51F3B8
			sc = 0x4F
		else:
			state = 0x51F3C0
			sc = 0x4F
		var cond := w.ub(k, 0xD)
		var cc := 0x7F if cond >= 0x32 else (0xFF if cond >= 0x23 else 0x4F)
		var c := w.ucrew(k, 0)
		var cn: Array = names.crew
		var given: String = cn[c][0] if c < cn.size() else ""
		var family: String = cn[c][1] if c < cn.size() and cn[c].size() > 1 else ""
		var mn: Array = names.machine
		var m := Flight.s8(w.ub(k, 0xC))
		var args := [0xFF, GameData.call_sign(campaign, Flight.gb(w, g, 1)), given, family,
				mn[m] if m >= 0 and m < mn.size() else "", cc, 100 - cond, sc, GameData.exe_text(campaign, state)]
		rows.append({"cells": text_cells(msg_raw(0x1C4), args), "refused": refused})
	return rows


func cb_slot_rows(u: int, g: int, tg: int) -> Array:
	## 0x4E0450's rows (WMES 0x1C6 + 0x200, an empty slot 0x1D0) for unit u of group g
	## against group tg's position (-1: the fire point DS:0x50AD95): each column is red
	## (0x4F) and the row refused when out of range (types 5 or missiles), of the wrong
	## kind for the group's type, without accuracy or ground attack (unless warhead 8),
	## without rounds, or broken (state 2)
	var rows := []
	var tx := w.fire_point.x
	var ty := w.fire_point.y
	if tg >= 0:
		tx = Flight.s8(Flight.gb(w, tg, 0x16))
		ty = Flight.s8(Flight.gb(w, tg, 0x17))
	var gt := Flight.gb(w, g, 0x21) & 0xF0
	var gx := Flight.s8(Flight.gb(w, g, 0x16))
	var gy := Flight.s8(Flight.gb(w, g, 0x17))
	for s in 6:
		var lid := w.launcher_id(u, s)
		if lid == -1:
			rows.append({"cells": text_cells(msg_raw(0x1D0), [0x40]), "refused": true})
			continue
		var bad := false
		var rng_ := w.weapon_range(u, s) & 0xFF
		var kind := w.mem8(0x50B1D5 + 17 * lid + 8) >> 5
		var radius := w.mem8(0x50B1D5 + 17 * lid + 9) & 7
		var rc := 0xFF
		if gt == 0x50 or kind == 2:
			if rng_ * 10 < Ai.grid_distance(gx, gy, tx, ty):
				rc = 0x4F
				bad = true
		var kc := 0xFF
		if tg >= 0 and ((gt == 0x50 and kind != 1) or ((gt == 0x30 or gt == 0x40) and kind != 2)):
			kc = 0x4F
			bad = true
		var acc := w.mem8(0x50B1D5 + 17 * lid + 2)
		var wh := w.warhead(u, s)
		var acs := GameData.exe_text(campaign, 0x50CBE1)        # a launcher without accuracy
		var ac := 0xFF
		if acc != 0xFF:
			if acc == 0 and wh != 8:
				acs = " 0"
				ac = 0x4F
				bad = true
			else:
				acs = "%d%d" % [(acc / 10) % 10, acc % 10]
		var atk := Move.final_attack(w, u, s, false) & 0xFF
		var tc := 0xFF
		if atk == 0 and wh != 8:
			tc = 0x4F
			bad = true
		var cnt := w.slot_count(u, s)
		var cs := "x" + ("%d%d" % [(cnt / 10) % 10, cnt % 10] if cnt != 0 else " 0")
		var nc := 0xFF
		if cnt == 0:
			nc = 0x4F
			bad = true
		var st := w.slot_state(u, s)
		var sc := 0xFF
		var stt: String = GameData.exe_text(campaign, [0x51F6B4, 0x51F6B8, 0x51F6BC][st]) if st >= 0 and st <= 2 else ""
		if st == 2:
			sc = 0x4F
			bad = true
		var ln: Dictionary = GameData.tables(campaign).get("launcher_names", {})
		var an: Dictionary = GameData.tables(campaign).get("ammo_names", {})
		var a := w.ammo_id(u, s)
		var cells := text_cells(msg_raw(0x1C6), [0x40 if bad else 0xF0, str(ln.get(str(lid), "")), rc, rng_, ac, acs,
				tc, atk, kc, _kind_char(kind), 0xFF, radius])
		cells.append_array(text_cells(msg_raw(0x200), [str(an.get(str(a), "")), nc, cs, sc, stt]))
		rows.append({"cells": cells, "refused": bad})
	return rows


func _kind_char(kind: int) -> String:
	## the launcher kind's letter: DS:0x50CBAA[kind]
	var t := GameData.exe_text(campaign, 0x50CBAA)
	return t[kind] if kind < t.length() else " "


func ask_table(title: String, header: Array, rows: Array, cancel: int, cols := 0) -> int:
	## a list window on a worker thread: a row's index, or cancel; refused rows keep the
	## list open (0x4E3230 / 0x4E0450). auto_react / the main thread: cancel. title is the
	## engine's own hint (the game shows none); cols the game's width (0: the rows' widest).
	if not scripted.is_empty():
		return scripted.pop_front()
	if auto_react or OS.get_thread_caller_id() == OS.get_main_thread_id():
		return cancel
	call_deferred("_open_table", title, header, rows, cancel, cols)
	react_sem.wait()
	return react_answer


func open_table(header: Array, rows: Array, cols: int) -> GameWindow:
	## the pickers' windows: with a header (ui_pocket_picker 0x4E95C0, 45 columns; the slot
	## picker 0x4E0450, 49) a one-line window (font 16 px) at ((640 - w) / 2, 400 / 2 - 0x20)
	## and the rows' select window under it (+0x20); without (0x4E3230, 59) the rows
	## centred both ways; w and h from 0x452450 (10 rows shown, 3 columns more scrolling),
	## kept inside the main window
	var n := rows.size()
	var lw := (cols + (3 if n > GameWindow.SCROLL_SHOWN else 0)) * 8 + 16
	var lh := (mini(n, GameWindow.SCROLL_SHOWN) + 1) * 16
	var x := (MAIN_W - lw) >> 1
	if x + lw - 1 > MAIN_W:
		x = MAIN_W - lw
	x = maxi(x, 0)
	var labels := rows.map(func(r): return GameWindow.coded(r.cells))
	var wins := []
	var y: int
	if header.is_empty():
		y = maxi(0, (MAIN_H - lh) >> 1)
	else:
		y = (MAIN_H >> 1) - 0x20
		if lh + 0x1F + y > MAIN_H:
			y = MAIN_H - (lh + 0x20)
		y = maxi(y, 0)
		var hd := GameWindow.text_window(x, y, cols, 1, 0)
		hd.waits = false
		hd.print_text(GameWindow.coded(header))
		wins.append(hd)
		y += 0x20
	var lst := GameWindow.select_window(x, y, cols, 0, 0, labels, cols, [], true)
	wins.append(lst)
	_hold(wins)
	return lst


func _open_table(title: String, header: Array, rows: Array, cancel: int, cols := 0) -> void:
	if cols <= 0:
		for r in rows:
			cols = maxi(cols, GameWindow.text_cols(GameWindow.coded(r.cells)))
		cols = maxi(cols, GameWindow.text_cols(GameWindow.coded(header)))
	var lst := open_table(header, rows, cols)
	lst.chosen.connect(func(v: int):
		if v == -2:
			_answer_reaction(cancel)
		elif v >= 0 and v < rows.size() and not rows[v].refused:
			_answer_reaction(v))


func _cells_label(cells: Array) -> RichTextLabel:
	var l := RichTextLabel.new()
	l.bbcode_enabled = true
	l.fit_content = true
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.scroll_active = false
	l.custom_minimum_size = Vector2(560, 0)
	l.add_theme_font_override("normal_font", list_font())
	l.add_theme_font_size_override("normal_font_size", 12)
	var t := ""
	for c in cells:
		t += "[color=#%s]%s[/color]" % [pal_color(c[1]).to_html(false), str(c[0]).replace("[", "[lb]")]
	l.text = t
	return l


var _list_font: Font = null
func list_font() -> Font:
	## the list windows' fixed-width font: the game pads its columns for a Japanese
	## monospaced font (half-width kana half a cell)
	if _list_font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["MS Gothic", "ＭＳ ゴシック", "Noto Sans Mono CJK JP", "Noto Sans Mono", "monospace"])
		_list_font = f
	return _list_font


func ask_hex(text: String, hexes: Array, default: Variant) -> Variant:
	## a hex clicked on the map (ui_map_click), on a worker thread; hexes are marked ("any":
	## every hex is taken), the panel's button answers -2. auto_react / the main thread: default.
	if not scripted.is_empty():
		return scripted.pop_front()
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


func _open_choice(text: String, options: Array, kind := "list") -> void:
	## the question's game window; its answer goes to the waiting thread
	var gw: GameWindow
	match kind:
		"prompt":
			gw = open_prompt(text)
			gw.chosen.connect(func(v: int): _answer_reaction(options[0][1] if v == 0 else options[1][1]))
		"box":
			gw = open_box(text, [options[0][0], options[1][0]])
			gw.chosen.connect(func(v: int): _answer_reaction(options[0][1] if v == 0 else options[1][1]))
		"menu":
			var labels := []
			for o in options:
				if not (o[1] is int and o[1] == -2):
					labels.append(o[0])
			gw = open_menu(labels)
			gw.chosen.connect(func(v: int): _answer_reaction(-2 if v < 0 else options[v][1]))
		_:
			var labels := []
			var vals := []
			var cancel: Variant = null
			for o in options:
				if o[1] is int and o[1] == -2:
					cancel = o[1]           # the select windows cancel with a right click
				else:
					labels.append(o[0])
					vals.append(o[1])
			gw = open_select(text, labels, cancel != null)
			gw.chosen.connect(func(v: int): _answer_reaction(cancel if v == -2 else vals[v]))


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


func _confirm(text: String, then: Callable, box_kind := -1) -> void:
	## a question on the main thread: the prompt at the cursor (its choices from the
	## message, 0 = the first), or with box_kind a message box (BOX_LABELS); then runs on
	## the first answer
	var gw: GameWindow
	if box_kind < 0:
		gw = open_prompt(text)
	else:
		var l: Array = BOX_LABELS[box_kind]
		gw = open_box(text, [GameData.exe_text(campaign, l[0]), GameData.exe_text(campaign, l[1])])
	gw.chosen.connect(func(v: int):
		_close_window(gw)
		if v == 0:
			then.call())


# --- the game's windows (ui/game_window.gd), in the main window's 640 x 400 ------------

const MAIN_W := 640               # the main window's client (0x404AE0: 0x280 x 400)
const MAIN_H := 400
var win_root: Control
var _lines: Array = []            # message lines waiting for the one shown to be clicked away
var _line_open: Control = null


func _win_root() -> Control:
	if win_root == null or not is_instance_valid(win_root):
		win_root = Control.new()
		win_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		win_root.size = Vector2(MAIN_W, MAIN_H)
		hud_layer.add_child(win_root)
	var vs := get_viewport().get_visible_rect().size
	var sc := minf(vs.x / MAIN_W, vs.y / MAIN_H)
	win_root.scale = Vector2(sc, sc)
	hud_layer.move_child(win_root, -1)
	return win_root


func _hold(wins: Array) -> Control:
	## the windows' holder: modal over the main window (the game's windows run their own
	## message loops); a click outside them goes to the last one (a wait goes on, a right
	## click cancels where allowed)
	var r := _win_root()
	var hold := Control.new()
	hold.size = Vector2(MAIN_W, MAIN_H)
	hold.mouse_filter = Control.MOUSE_FILTER_STOP
	for gw in wins:
		hold.add_child(gw)
	var top: GameWindow = wins[-1]
	hold.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			top.outside(ev.button_index))
	r.add_child(hold)
	react_panel = hold
	return hold


func _close_window(gw: GameWindow) -> void:
	var hold := gw.get_parent()
	if hold and is_instance_valid(hold):
		if react_panel == hold:
			react_panel = null
		hold.queue_free()


var cursor_override := Vector2(-1, -1)      # tests: the cursor the prompts open at


func _mouse_main() -> Vector2:
	if cursor_override.x >= 0:
		return cursor_override
	return _win_root().get_local_mouse_position()


func open_prompt(text: String) -> GameWindow:
	## ui_prompt_at_cursor (0x47EBE0): a 20 x 4 window of 16 px lines (font 16 px) at the
	## cursor (x & ~7 - 0x28, y - 0x40; kept 0xB0 x 0x50 inside the window, not below 0),
	## the choices' regions (8, 0x38)-(0x48, 0x48) and (0x58, 0x38)-(0x98, 0x48); a right
	## click answers the second. A translation is laid out by the engine: the question
	## wrapped at its words, the choices centred in their regions on the last line (the
	## window grows when the question needs more than three lines).
	var m := _mouse_main()
	var x := (int(m.x) & 0xFFF8) - 0x28
	var y := int(m.y) - 0x40
	if (int(m.x) & 0xFFF8) + 0x88 > MAIN_W:
		x = MAIN_W - 0xB0
	if int(m.y) + 0x10 > MAIN_H:
		y = MAIN_H - 0x50
	x = maxi(x, 0)
	y = maxi(y, 0)
	var body := text
	var rows := 4
	if GameWindow.translated(text):
		var parts := GameData.prompt_parts(text)
		var head := GameWindow.fit(str(parts[0]).replace("@", "\n").strip_edges(), 20)
		var n := head.split("\n").size()
		rows = maxi(4, n + 1)
		body = head + "\n".repeat(rows - n)
		if parts[1].size() >= 2:
			body += GameWindow.centred(str(parts[1][0]), 8) + "・" + GameWindow.centred(str(parts[1][1]), 8)
	var dy := (rows - 4) * 16
	y = maxi(0, mini(y, MAIN_H - 0x50 - dy))
	var gw := GameWindow.select_window(x, y, 20, rows, 0, [], 0,
			[[8, 0x38 + dy, 0x48, 0x48 + dy, 1], [0x58, 0x38 + dy, 0x98, 0x48 + dy, 1]], true)
	gw.waits = false
	_hold([gw])
	gw.print_text(body.replace("@", ""))
	return gw


func open_box(text: String, labels: Array) -> GameWindow:
	## ui_message_box (0x451FB0): the message in a one-line window (font 12 px) centred,
	## x ((80 - (len + 2)) / 2) * 8, y (400 - 32) / 2; its two buttons a select window of 4
	## columns below it at its right ((.. + len + 2) * 8 - 0x30, y + 0x20); the first
	## answers 0, the second or a right click 1. Engine-side fit: a text wider than the
	## screen wraps (more lines), labels wider than 4 columns widen the buttons leftwards.
	var wins := box_windows(text, labels)
	_hold(wins)
	wins[0].print_text(wins[0].get_meta("text"))
	return wins[1]


func box_windows(text: String, labels: Array) -> Array:
	## ui_message_box's two windows (open_box's layout): [the message's, the buttons']
	var t := text.replace("@", "").strip_edges()
	var n := GameWindow.text_cols(t)
	var rows := 1
	if n > 76:
		t = GameWindow.fit(t, 76)
		rows = t.split("\n").size()
		n = 0
		for l in t.split("\n"):
			n = maxi(n, GameWindow.text_cols(l))
	var x := ((80 - (n + 2)) / 2) * 8
	var y := (MAIN_H - 0x20) / 2
	var mw := GameWindow.text_window(x, y, n, rows, 1)
	var ic := 4
	for l in labels:
		ic = maxi(ic, GameWindow.text_cols(str(l)))
	var right := (((80 - (n + 2)) / 2) + n + 2) * 8
	var bw := GameWindow.select_window(right - 16 - ic * 8, y + 0x20 + (rows - 1) * 16, 0, 0, 0, labels, ic, [], true)

	mw.waits = false
	mw.set_meta("text", t)
	return [mw, bw]


func open_menu(labels: Array, cols := 0xE) -> GameWindow:
	## the slot menu (0x427530) and the pocket menu (0x427FF0): a select window of 14
	## columns at the cursor (x & ~7 - 0x28, y - n x 16 / 2; x 640 - 0x80 when x & ~7 + 0x57
	## passes 640, y 400 - (n + 1) x 16 when the list would pass 400; not below 0), right
	## click cancelling
	var m := _mouse_main()
	var n := labels.size()
	var x := (int(m.x) & 0xFFF8) - 0x28
	var y := int(m.y) - (n * 16) / 2
	if (int(m.x) & 0xFFF8) + 0x57 > MAIN_W:
		x = MAIN_W - 0x80
	if y + 0xF + n * 16 > MAIN_H:
		y = MAIN_H - (n + 1) * 16
	var ic := cols
	for l in labels:
		ic = maxi(ic, GameWindow.text_cols(str(l)))     # (engine-side: a longer translation widens it)
	var gw := GameWindow.select_window(maxi(x, 0), maxi(y, 0), ic, 0, 0, labels, ic, [], true)
	_hold([gw])
	return gw


func open_select(title: String, labels: Array, cancel: bool) -> GameWindow:
	## a select window (0x40C090 with x -1: centred) with the question as its header (font
	## 16 px) and the choices as items; a right click cancels where the question has a cancel
	var head := GameWindow.fit(title.replace("@", "\n").strip_edges(), 36)
	var hl := head.split("\n")
	var hc := 0
	for l in hl:
		hc = maxi(hc, GameWindow.text_cols(l))
	var ic := 0
	for l in labels:
		ic = maxi(ic, GameWindow.text_cols(str(l)))
	var c := maxi(hc, ic + (3 if labels.size() > GameWindow.SCROLL_SHOWN else 0))
	var hh := hl.size() * 16 + 16
	var ih := (mini(labels.size(), GameWindow.SCROLL_SHOWN) + 1) * 16
	var gw := GameWindow.select_window(((MAIN_W - (c * 8 + 16)) / 2) & ~7, (MAIN_H - hh - ih) / 2, c,
			hl.size(), 0, labels, ic, [], cancel)
	gw.waits = false
	_hold([gw])
	gw.print_text(head)
	return gw


func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


func show_line(text: String, red := false) -> void:
	## ui_message_line (0x452300; 0x4521C0 starts it red, "%a4F" DS:0x50CBD6): a one-line
	## window (font 12 px) centred at y (400 - 32) / 2, until a click. Lines said while one
	## is up wait for it.
	if OS.get_thread_caller_id() != OS.get_main_thread_id():
		call_deferred("show_line", text, red)
		return
	_lines.append([text.replace("@", "").strip_edges(), red])
	if _line_open == null or not is_instance_valid(_line_open):
		_next_line()


func _next_line() -> void:
	_line_open = null
	if _lines.is_empty() or hud_layer == null:
		return
	var it: Array = _lines.pop_front()
	var t: String = it[0]
	if t == "":
		_next_line()
		return
	var n := mini(GameWindow.text_cols(t), 76)
	var rows := 1
	if GameWindow.text_cols(t) > 76:
		t = GameWindow.fit(t, 76)
		rows = t.split("\n").size()
	var gw := GameWindow.text_window(((80 - (n + 2)) / 2) * 8, (MAIN_H - 0x20) / 2, n, rows, 1)
	gw.waits = not _headless()
	var hold := _hold([gw])
	_line_open = hold
	if react_panel == hold:
		react_panel = null               # (not a question)
	await gw.print_text(("\u0001" + char(0x4F) if it[1] else "") + t + "\n")
	if is_instance_valid(hold):
		hold.queue_free()
	_next_line()


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
			_after_command(), 1)                     # 0x427410: a message box, kind 1
	else:
		var carried := w.ub(u, 0x34)
		_confirm(msg(0x1B2), func():
			Action.player_release(w, u, h.x, h.y)
			if not carried in squad:
				pass
			say("%s sets down %s." % [unit_name(u), unit_name(carried)])
			_set_mode("move")
			_after_command(), 1)                     # 0x426FD6: a message box, kind 1


var _safe_shown := 0


## RULES.md 5.23: the play-safe paths taken since the last report (the game would have
## crashed or hung there), shown in the log.
func _show_safe() -> void:
	while _safe_shown < w.safe_log.size():
		say("[color=orange]%s[/color]" % w.safe_log[_safe_shown])
		_safe_shown += 1


func _after_command() -> void:
	_script_state()
	_show_safe()
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	_update_move_map()
	_check_end()



# --- the battle's system menu (0x4847C0: Title.battle_menu) ------------------------------

class MenuDriveHooks extends Title.BattleSaveHooks:
	## The system menu's lists and questions answered from a queue (as SortieDriveHooks);
	## past its end the request is recorded and cancelled. A dry run (on a copy of the
	## world) writes no file and runs no script: it finds the next question; the real run
	## writes to user://saves and runs the mission's load and start scripts.
	var battle
	var answers: Array
	var request: Variant = null
	var dry := true
	var out := {}
	var notes: Array = []
	var loaded := false

	func _init(a: Array, b, d: bool) -> void:
		answers = a.duplicate()
		battle = b
		dry = d

	func _next(req: Array, d: int) -> int:
		if not answers.is_empty():
			return answers.pop_front()
		if request == null:
			request = req
		return d

	func menu() -> int:
		return _next(["menu"], -2)

	func box(msg: int) -> int:
		return _next(["box", msg], 0)

	func slot(load: bool) -> int:
		return _next(["slot", load], 0x29)

	func ask(line: Array) -> int:
		return _next(["ask", line], 0)

	func note(text: int) -> int:
		notes.append(text)
		return 0

	func error(text: int) -> void:
		notes.append(text)

	func read(name: String) -> Variant:
		return out[name] if out.has(name) else SaveFiles.read(name)

	func write(name: String, data: PackedByteArray) -> bool:
		if dry:
			out[name] = data
			return true
		return SaveFiles.write(name, data)

	func campaign_set(w: Pd2World) -> void:
		var t := GameData.tables("pd2" if w.campaign else "dash")
		w.records = Pd2World.new(t.machines, t.launchers, t.ammo, PackedByteArray(), 1).records

	func load_script() -> void:
		loaded = true
		if not dry:
			MissionScripts.run_load(battle.w)

	func start_script() -> int:
		return 0 if dry else MissionScripts.run_start(battle.w, battle.rng, battle.mission_hooks)


var menu_answers: Array = []
var sysmenu_panel: PanelContainer = null
var menu_answers_scripted: Array = []      # tests: the system menu's answers, taken in turn


func _cmd_system() -> void:
	## the command menu's entry 0x10: the system menu (SAVE, LOAD and the six options)
	if busy or mission_over or sysmenu_panel != null:
		return
	menu_answers = []
	_menu_advance()


func _menu_advance() -> void:
	var dry := MenuDriveHooks.new(menu_answers, self, true)
	Debrief.fire_point_to_ds(w)
	Title.battle_menu(w.duplicate_world(), dry)
	if dry.request != null:
		if not menu_answers_scripted.is_empty():
			menu_answers.append(menu_answers_scripted.pop_front())
			_menu_advance()
			return
		_menu_ask(dry.request)
		return
	_menu_close()
	var real := MenuDriveHooks.new(menu_answers, self, false)
	var r := Title.battle_menu(w, real)
	for t in real.notes:
		say(menu_text(t))
	if r in Title.BATTLE_ABORTS:
		_game_closed(r)
		return
	mission_hooks.options = w.options
	if real.loaded:
		Debrief.fire_point_from_ds(w)
		_reload_scene()
		return
	_update_move_map()
	overlay.queue_redraw()


func menu_text(t: int) -> String:
	## a note's text: a battle message (WMES) below 0x500000, else Pd2.exe's
	## (0x408B70 prints 0x5181A8, "%s", with "KEMURI open error")
	return msg(t) if t < 0x500000 else SaveFiles.exe(0x518154 if t == 0x5181A8 else t)


func _reload_scene() -> void:
	## after the system menu's load: the battle scene of the loaded mission, with the world
	## as 0x4847C0 left it (the player's phase goes on)
	var b: Node = load("res://ui/battle.tscn").instantiate()
	b.campaign = "pd2" if w.campaign else "dash"
	b.mission_index = Debrief.chunk(w) - 1
	b.title_carry = {"world": w, "rng": rng}
	b.auto_react = auto_react
	b.sortie_window = sortie_window
	b.plan_window = plan_window
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	queue_free()


func _menu_close() -> void:
	if sysmenu_panel:
		sysmenu_panel.queue_free()
		sysmenu_panel = null


func _sysmenu_pick(v: int) -> void:
	menu_answers.append(v)
	_menu_close()
	_menu_advance()


func _menu_cancel() -> void:
	menu_answers = []
	_menu_close()


func menu_slot_line(line: Array) -> String:
	## 0x477EB0's line: wsprintfA's format 0x517990 with the mode, the name, the time
	## (0x453900; 0x50CBD1 for a save made outside a battle) and the verb
	var when: String = line[2] if line[2] != null else SaveFiles.exe(Title.SLOT_SORTIE_TIME)
	return GameData.exe_raw("dash", 0x517990) % [SaveFiles.exe(line[0]), SaveFiles.saved_name(line[1]),
		when, SaveFiles.exe(0x517988 if line[3] else 0x517978)]


func _menu_ask(req: Array) -> void:
	_menu_close()
	sysmenu_panel = PanelContainer.new()
	var theme := Theme.new()
	theme.default_font_size = 8
	sysmenu_panel.theme = theme
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.12, 0.97)
	bg.set_content_margin_all(8)
	sysmenu_panel.add_theme_stylebox_override("panel", bg)
	sysmenu_panel.position = Vector2(240, 40)
	hud_layer.add_child(sysmenu_panel)
	var box := VBoxContainer.new()
	sysmenu_panel.add_child(box)
	var add := func(text: String, v: int) -> void:
		var b := Button.new()
		b.text = text
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(_sysmenu_pick.bind(v))
		box.add_child(b)
	match req[0]:
		"menu":
			for i in Title.SYSTEM_LABELS.size():
				var t := SaveFiles.exe(Title.SYSTEM_LABELS[i])
				if Title.SYSTEM_TOGGLES.has(i):
					t += "  " + (ui("UI_ON") if w.options & Title.SYSTEM_TOGGLES[i] else ui("UI_OFF"))
				add.call(t, i)
			var c := Button.new()
			c.text = ui("UI_CANCEL")
			c.pressed.connect(_menu_cancel)
			box.add_child(c)
		"box":
			var l := Label.new()
			l.text = msg(req[1]).replace("@", "
").strip_edges()
			box.add_child(l)
			add.call(ui("UI_YES"), 1)
			add.call(ui("UI_NO"), 0)
		"slot":
			## 0x477770 (load): the saves there are; 0x477580 (save): a new slot first (the
			## saves' count + 1, while there are at most 0x27) and the saves
			var saved := []
			for s in Title.SLOTS:
				var d: Variant = SaveFiles.read(Title.rec_name(s))
				if d != null and (d as PackedByteArray).size() >= 8 and (d as PackedByteArray).slice(0, 8) == Title.magic():
					saved.append(s)
			if not req[1] and saved.size() <= 0x27:
				add.call(ui("UI_SLOT_NEW"), saved.size() + 1)
			for s in saved:
				add.call(SaveFiles.slot_line(s, 0x519EE8 if req[1] else 0x519ED8), s)
			if saved.is_empty() and req[1]:
				var l := Label.new()
				l.text = msg(0xD)
				box.add_child(l)
			add.call(ui("UI_CANCEL"), 0x29)
		"ask":
			var l := Label.new()
			l.text = menu_slot_line(req[1])
			box.add_child(l)
			add.call(ui("UI_YES"), 1)
			add.call(ui("UI_NO"), 0)

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


# --- the flight window (RadarView) ----------------------------------------------------

var radar_view: RadarView


func _radar() -> RadarView:
	if radar_view == null:
		radar_view = RadarView.new()
		radar_view.battle = self
		radar_view.visible = false
		hud_layer.add_child(radar_view)
	var vs := get_viewport().get_visible_rect().size
	var sc := minf(vs.x / RadarView.W, vs.y / RadarView.H) * 0.96
	radar_view.scale = Vector2(sc, sc)
	radar_view.position = (vs - Vector2(RadarView.W, RadarView.H) * sc) / 2
	return radar_view


func radar_show(snap: Dictionary) -> void:
	var r := _radar()
	r.snap = snap
	r.visible = true
	r.queue_redraw()


func radar_update(snap: Dictionary) -> void:
	var r := _radar()
	r.snap = snap
	r.queue_redraw()


func radar_face(a: int, code: int, b: int) -> void:
	var r := _radar()
	r.visible = true
	r.radio_face(a, code, b)


func radar_say(t: String, code: int) -> void:
	var r := _radar()
	var gw = r.radio_say(t, code)
	gw.print_text(str(r.lines[(code >> 4) & 0xF][0]))


func radar_say_wait(t: String, code: int) -> void:
	var r := _radar()
	r.visible = true                       # (the radio's windows are the flight window's)
	var gw = r.radio_say(t, code)
	gw.waits = true
	await gw.print_text(str(r.lines[(code >> 4) & 0xF][0]))
	react_sem.post()


func radar_close(n: int) -> void:
	_radar().radio_close(n)


func radar_hide() -> void:
	## 0x43F060 (from the panels' refresh, ui_refresh_panels 0x4363D0): the window goes
	if radar_view:
		radar_view.visible = false
		radar_view.radio_close(-1)


func _ai_done(res: int, undefined: Array, end_code := 0) -> void:
	radar_hide()
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
	_show_safe()
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
		## 0x43BA20 with its choice labels (MissionScripts.CHOICES: the label arrays the
		## mission passes, e.g. 実行 / 中止 DS:0x50CBC1, はい / いいえ DS:0x517F88); the escape
		## question of missions 1 and 3 (0xAA) names the pilot (given and family names)
		var a := _args(args)
		var labels := [battle.ui("UI_YES"), battle.ui("UI_NO")]
		## (or the labels' own addresses, which mission 9 of DASH pushes one by one)
		var arr: Variant = MissionScripts.CHOICES.get(battle.script_no, {}).get(msg, 0)
		var ptrs: Array = []
		if arr is Array:
			for pt in arr:
				ptrs.append("%X" % pt)
		else:
			ptrs = GameData.tables(battle.campaign).get("script_choices", {}).get("%X" % arr, [])
		if ptrs.size() >= 2:
			labels = []
			for pt in ptrs:
				labels.append(GameData.exe_text(battle.campaign, str(pt).hex_to_int()))
		var nd: Variant = MissionScripts.NAME_DIALOGS.get(battle.script_no, -1)
		if (nd is Array and msg in nd) or (nd is int and nd == msg):
			var names: Array = GameData.tables(battle.campaign).crew_names
			var nm: Array = names[args[0]] if args[0] < names.size() else ["", ""]
			a = [nm[0], nm[1]]
		## (a question of Pd2.exe's own, e.g. mission 8's pickup point 0x51AEFC)
		var text: String = GameData.exe_text(battle.campaign, msg, a) if msg >= 0x500000 else battle.msg(msg, a)
		if choices > 2 and labels.size() >= choices:
			var opts := []
			for i in choices:
				opts.append([labels[i], i])
			return int(battle.ask_choice(text, opts, 0))
		return 0 if battle.ask_choice(text, [[labels[0], true], [labels[1], false]], true) else 1

	func message(msg: int, args := []) -> int:
		battle.say_msg(msg, args)
		return 0

	func note(msg: int) -> int:
		## 0x452170 from an init (the pre-battle screen: MES.PCK), e.g. mission 10's 0x1CE
		battle.say(battle.mes(msg))
		return 0

	func scroll(x: int, y: int) -> int:
		return 0

	func speech() -> int:
		## the mission's speech hook (table 0x51EEB8; mission 1's runs the flight turn and
		## the arrival scenes, 0x499830)
		return MissionScripts.run_speech(battle.w, battle.rng, self)

	func end_dialog(msg: int) -> int:
		## 0x4DD390 in the sortie: the refusal's text (MES.PCK); its first choice
		battle.sortie_say(battle.mes(msg))
		return 0

	func box(msg: int, args: Array, kind: int) -> int:
		## ui_message_box: buttons DS:0x50CBC9[kind] (了解 / 中止, 実行 / 中止): 1 the first
		var l0: int = 0x510454 if kind == 1 else 0x510444
		var text: String = battle.msg(msg, _args(args))
		return battle.ask_choice(text, [[GameData.exe_text(battle.campaign, l0), 1],
				[GameData.exe_text(battle.campaign, l0 + 8), 0]], 1)

	func line(msg: int, args := []) -> int:
		## 0x4521C0: a message, or one of Pd2.exe's own strings (an address)
		if msg >= 0x500000:
			battle.say(GameData.exe_text(battle.campaign, msg, _args(args)))
		else:
			battle.say_msg(msg, _args(args))
		return 0

	func prompt(msg: int, args := []) -> int:
		## ui_prompt_at_cursor: the text carries its own two words (設置 / 中止); 0 the first
		var text: String = battle.msg(msg, _args(args))
		return 0 if battle.ask_choice(text, [[battle.ui("UI_YES"), true], [battle.ui("UI_NO"), false]], true) else 1

	func fuse(msg: int, low: int) -> int:
		## 0x429200: the fuse list, "%3d分" from low x 5 in steps of 5 (25 - low entries)
		var opts := []
		for i in 25 - low:
			opts.append([battle.uif("UI_MINUTES", [(low + i) * 5]), i])
		opts.append([battle.ui("UI_CANCEL"), -2])
		return battle.ask_choice(battle.msg(msg), opts, 0)

	func blast_start(x: int, y: int) -> int:
		battle.say(battle.uif("UI_BLAST", [x, y]))
		return 0

	func blast(x: int, y: int) -> int:
		battle.say(battle.uif("UI_BLAST", [x, y]))
		return 0

	## DASH script 13's talk windows (0x48BF90 / 0x48C260 with a portrait and a text): the
	## message log; the base-screen lines of 0x452200 (MES.PCK), the data window's text
	func talk(face: int, msg: int, args: Array, x: int, place: int) -> int:
		battle.say(_text(msg, args))
		return 0

	func talk_more(h: int, msg: int, args: Array) -> int:
		battle.say(_text(msg, args))
		return 0

	func notice(msg: int, args := []) -> int:
		battle.say(battle.mes(msg))
		return 0

	func print_text(msg: int, args := []) -> int:
		if msg < 0x500000:
			battle.say(battle.msg(msg, _args(args)))
		return 0

	func _text(msg: int, args: Array) -> String:
		if msg >= 0x500000:                          # a format of Pd2.exe's (DS:0x51C728 "%s%s@")
			return GameData.exe_text(battle.campaign, msg, _args(args))
		return battle.msg(msg, _args(args))

	func click(mode: int) -> Variant:
		## ui_map_click: a hex of the map; the marked ones (F bit 1, set_target_mark) shown
		var marks := []
		for i in 72 * 72:
			if battle.w.F[i] & 2:
				marks.append(Vector2i(i % 72, i / 72))
		var r: Variant = battle.ask_hex(battle.ui("UI_PICK_HEX"), marks, -2)
		return r if r is Vector2i else int(r)

	func _args(args: Array) -> Array:
		## the scripts' format arguments: ["sign", n] is the radio call sign n (DS:0x50C7E5)
		var out := []
		for a in args:
			if a is Array and a.size() == 2 and str(a[0]) == "sign":
				out.append(GameData.call_sign(battle.campaign, int(a[1])))
			elif a is Array and a.size() == 2 and (str(a[0]) == "crew" or str(a[0]) == "family"):
				## a crew's given name (DS:0x50BCB5) or family name (DS:0x50BD4D), by its name id
				var names: Array = GameData.tables(battle.campaign).crew_names
				var nm: Array = names[int(a[1])] if int(a[1]) >= 0 and int(a[1]) < names.size() else ["", ""]
				out.append(nm[0] if str(a[0]) == "crew" else nm[1])
			elif a is Array and a.size() == 2 and str(a[0]) == "machine":    # a machine's name (DS:0x50C265)
				var mn: Array = GameData.tables(battle.campaign).get("machine_names", [])
				out.append(mn[int(a[1])] if int(a[1]) < mn.size() else "")
			else:
				out.append(a)
		return out


class BattleFlightHooks extends Flight.Hooks:
	## The flight engine's windows in the battle: the flight window (the radar map, its
	## status list, the radio's talk windows with their portraits: RadarView) and the
	## message log for the radio's lines; the air fight's melee asks its weapon prompt
	## (0x1A7, as 0x424490). Runs on the computer turn's thread: the world is copied here
	## and the window drawn on the main thread.
	var battle

	func radar_window(param: int) -> int:           # 0x43E510: the window opens
		battle.call_deferred("radar_show", RadarView.take(battle.w))
		return 0

	func radar_draw() -> int:                        # 0x43F150: the grid redrawn
		battle.call_deferred("radar_update", RadarView.take(battle.w))
		return 0

	func air_report() -> int:                        # 0x43E9D0: the status list
		battle.call_deferred("radar_update", RadarView.take(battle.w))
		return 0

	func radio_face(a: Variant, code: Variant, b: Variant) -> int:
		if a is int and code is int:
			battle.call_deferred("radar_face", a, code, b if b is int else a)
		return 0

	func radio_say(msg: int, args: Array, code: Variant) -> int:
		var t: String = battle.msg(msg, battle.radio_args(args))
		battle.say_msg(msg, battle.radio_args(args))
		if code is int:
			if battle.auto_react or battle._headless() or OS.get_thread_caller_id() == OS.get_main_thread_id():
				battle.call_deferred("radar_say", t, code)
			else:
				# the line's window waits for its clicks ('@', a full window), as the game's
				# printer does, before the flight engine goes on
				battle.call_deferred("radar_say_wait", t, code)
				battle.react_sem.wait()
		return 0

	func radio_close(n: int) -> int:
		battle.call_deferred("radar_close", n)
		return 0

	func use_weapon(a: int, p: int) -> bool:
		return battle.ask_prompt(battle.msg(0x1A7), true)


class BattleStrikeHooks extends Strike.Hooks:
	## The strike executor (0x4E37A0) in the battle: a striker flying in draws the reaction
	## fire of the live hooks (flag 10), the radio goes through the flight engine's, the
	## lines and questions to the message log and the question box. The pickers (0x4E3230 /
	## 0x4E0450) are drawn as the game's lists (battle.cb_unit_rows / cb_slot_rows).
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
		var rows: Array = battle.cb_unit_rows(units)
		if rows.is_empty():                   # 0x4E3230: none listed, MES 0x1C3
			battle.say_msg(0x1C3)
			return -1
		var i: int = battle.ask_table(battle.ui("UI_PICK_SUPPORT"), [], rows, -2, 0x3B)
		return -1 if i == -2 else units[i]

	func cb_slot(u: int, g: int) -> int:
		return battle.ask_table(battle.ui("UI_PICK_WEAPON"), battle.text_cells(battle.msg_raw(0x1C5), []),
				battle.cb_slot_rows(u, g, cb_target), -2, 0x31)

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
	_show_safe()
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
		## the mission's bomb hook (table 0x51F158) for entry i
		return MissionScripts.run_bomb(battle.w, battle.rng, i, battle.mission_hooks)


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
	_show_safe()
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	return res

func radio_args(args: Array) -> Array:
	## the radio's format arguments as text: a call sign (DS:0x50C7E5), the time of
	## 0x453900 ("HH:MM" of (t + d) x 5 minutes, hours past 23 wrapped) or a number (%d)
	var out := []
	for a in args:
		if not a is Array:                           # a plain number (%d)
			out.append(a)
			continue
		match a[0]:
			"sign":
				out.append(GameData.call_sign(campaign, a[1]))
			"name":
				out.append(GameData.call_sign(campaign, 39 + a[1]))   # a group name (DS:0x50C881)
			"crew":
				var cn: Array = GameData.tables(campaign).crew_names
				out.append(cn[a[1]][0] if a[1] >= 0 and a[1] < cn.size() else "")   # a crew's given name (DS:0x50BCB5)
			"exe":
				out.append(GameData.exe_text(campaign, a[1]))          # a string of Pd2.exe's (DASH mission 8's squad names)
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
	## 0 in the computer's turn (which runs the speech hook). MissionScripts.PORTED lists the
	## missions whose scripts are in.
	if MissionScripts.has_scripts(script_no):
		MissionScripts.run_turn(w, rng, stage, mission_hooks)
		_show_safe()
		if w.fault != "":
			say("[color=red]rules fault: %s[/color]" % w.fault)
			w.fault = ""


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
	_confirm(msg(0x1DE), _withdraw, 0)          # 0x4EF600: a message box of kind 0


func _withdraw() -> void:
	var code := Debrief.scenario_command(w, script_no, rng, mission_hooks)
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
	_show_safe()
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
	b.plan_window = plan_window
	get_tree().root.add_child(b)
	get_tree().current_scene = b
	queue_free()


func mission_label(addr: int) -> String:
	## entry 11's label; mission 8's menu hook writes the AP digit into its string (0x51AED2)
	var t := GameData.exe_text(campaign, addr)
	if addr == 0x51AEC8:
		t = t.replace("0", char(w.mem8(0x51AED2)))
	return t


func _cmd_mission() -> void:
	## the mission's own command (unit menu entry 11, table 0x51EF78; its label from the
	## menu hook, table 0x51EF18)
	if selected == -1 or busy or mission_over or MissionScripts.run_menu(w, selected)[0] != 1:
		return
	var u := selected
	busy = true
	if auto_react:
		MissionScripts.run_command(w, rng, u, mission_hooks)
		_mission_cmd_done()
		return
	move_thread = Thread.new()
	move_thread.start(func():
		MissionScripts.run_command(w, rng, u, mission_hooks)
		call_deferred("_mission_cmd_finished"))


func _cmd_explosives() -> void:
	## the machine status window's "set explosives" (pocket menu entry 7, 0x427FF0): the
	## first pocket with a warhead-13 round left and not broken; its AP is the round's
	## (ammo +7, low 5 bits), halved for an engineer (crew skills bit 1). Then 0x428D80
	## (MissionScripts.lay_explosive, with the mission's bomb rule); laid, the AP is paid.
	if selected == -1 or busy or mission_over:
		return
	var u := selected
	var p := -1
	for k in 4:
		var a := w.pocket_ammo(u, k)
		if a != -1 and a < 96 and w.ammo(a, 8) & 15 == 13 and w.pocket_count(u, k) and w.pocket_state(u, k) != 2:
			p = k
			break
	if p == -1:
		say(ui("UI_NO_EXPLOSIVES"))
		return
	if Ai.manipulator_state(w, u) == 2:
		say_msg(0x1B9)
		return
	var ap := (w.ammo(w.pocket_ammo(u, p), 7) & 0x1F) / (2 if (w.ucrew(u, 8) >> 1) & 1 == 1 else 1)
	busy = true
	var run := func():
		if MissionScripts.lay_explosive(w, u, p, ap, mission_hooks) == 1:
			Ai.spend_ap(w, u, ap)
	if auto_react:
		run.call()
		_mission_cmd_done()
		return
	move_thread = Thread.new()
	move_thread.start(func():
		run.call()
		call_deferred("_mission_cmd_finished"))



# --- the pocket actions (Pockets: the slot menu 0x427530, the pocket menu 0x427FF0, the
# pocket picker 0x4E95C0, the swaps 0x427930 / 0x427980, handing over 0x4287A0)

class BattleHandHooks extends Pockets.HandHooks:
	## 0x4287A0's clicks (the marked neighbours are highlighted; the panel's button cancels)
	## and its 0x1E8 box, on the command's thread
	var battle
	var marks: Array = []

	func click() -> Variant:
		var r: Variant = battle.ask_hex(battle.ui("UI_PICK_RECIPIENT"), marks, -2)
		return r if r is Vector2i else null

	func ask(ap: int) -> int:
		return 1 if battle.ask_box(battle.msg(0x1E8, [ap]), false, 1) else 0     # 0x428B44: kind 1

	func line(msg: int) -> int:
		battle.say_msg(msg)
		return 0


class BattleDiscardHooks extends Pockets.DiscardHooks:
	## 0x428400 / 0x4284F0's question (0x1B6 / 0x1B7) with the item's name
	var battle

	func box(msg: int, kind: String, idx: int) -> int:
		var t: Dictionary = GameData.tables(battle.campaign).get("launcher_names" if kind == "launcher" else "ammo_names", {})
		return 1 if battle.ask_box(battle.msg(msg, [str(t.get(str(idx), ""))]), false) else 0


class BattleReconHooks extends Pockets.ReconHooks:
	## 0x4285E0's 0x1C8 prompt (its two choices, Cancel for the right click) and the
	## 0x47E790 window for each enemy found; the map stays in view, so "check the area"
	## asks again at once
	var battle

	func prompt() -> int:
		var parts := GameData.prompt_parts(battle.msg(0x1C8))
		var labels: Array = parts[1] if parts[1].size() >= 2 else [battle.ui("UI_YES"), battle.ui("UI_NO")]
		return battle.ask_choice(parts[0], [[labels[0], 0], [labels[1], 1], [battle.ui("UI_CANCEL"), -2]], 0)

	func discovered(o: int) -> int:
		battle.say_msg(0x1C7)
		return 0


func drop_flow(u: int, item: int, act: int, ap: int) -> int:
	## discard (0x428400, 0x1B6) / unequip (0x4284F0, 0x1B7); done, the AP is paid
	var hk := BattleDiscardHooks.new()
	hk.battle = self
	if Pockets.drop_item(w, u, item, 0x1B6 if act == Pockets.DISCARD else 0x1B7, hk) == 1:
		Ai.spend_ap(w, u, ap)
		return 1
	return 0


func pocket_action_text(a: int, ap: int) -> String:
	## the menus' entries (exe 0x514008 ...: "%2dAP")
	return GameData.exe_text(campaign, Pockets.ACTION_TEXT[a], [ap])


func both_arms_broken(u: int) -> bool:
	## cmd_fire 0x425AF0, step_mine_found 0x4756A0, the machine status window 0x4279F0
	return (w.ub(u, 1) & 0xC0) == 0x80 and (w.ub(u, 2) & 3) == 2


func magazine_table(u: int, s: int) -> int:
	## ui_pocket_picker (0x4E95C0): the pocket picked for slot s, or -2 (none: 0x1D9)
	var rows := Pockets.magazine_rows(w, u, s)
	if w.fault != "":
		return -2
	if rows.is_empty():
		say_msg(0x1D9)
		return -2
	var an: Dictionary = GameData.tables(campaign).get("ammo_names", {})
	var cells := []
	for r in rows:
		var args := [0xF0, str(an.get(str(r[1]), "")), r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9],
				GameData.exe_text(campaign, r[10])]
		cells.append({"cells": text_cells(msg_raw(0x1D8), args), "refused": false})
	var i := ask_table(ui("UI_PICK_POCKET"), text_cells(msg_codes(0x1D7), []), cells, -2, 0x2D)
	return -2 if i < 0 or i >= rows.size() else int(rows[i][0])


func _menu_pick(title: String, menu: Array) -> int:
	var opts := []
	for i in menu.size():
		opts.append([pocket_action_text(menu[i][0], menu[i][1]), i])
	opts.append([ui("UI_CANCEL"), -2])
	return ask_choice(title, opts, -2, "menu")


func hand_over_flow(u: int, item: int, ap: int) -> int:
	## 0x4287A0, then the AP of both (the machine status window's entry 2)
	var hk := BattleHandHooks.new()
	hk.battle = self
	var keep := w.F.duplicate()
	hk.marks = Pockets.hand_over_marks(w, u, item, ap)
	w.F = keep                                    # hand_over sets the marks itself
	var o := Pockets.hand_over(w, u, item, ap, hk)
	if o in Pockets.ABORT or o == -1:
		return 0
	Ai.spend_ap(w, u, ap)
	Ai.spend_ap(w, o, ap)
	say(uif("UI_HANDED_OVER", [unit_name(u), unit_name(o)]))
	return 1


func slot_menu_flow(u: int, s: int, picker: bool) -> int:
	## the slot menu (0x427530) as cmd_fire / the mine dialog (picker: the magazine column)
	## and the machine status window run it: both arms broken 0x1B9; an entry; its AP
	## (ui_not_enough_ap 0x1AE); the swaps through the pocket picker, handing over
	if both_arms_broken(u):
		say_msg(0x1B9)
		return 0
	var menu := Pockets.slot_menu(w, u, s, picker)
	if w.fault != "" or menu.is_empty():
		return 0
	var i := _menu_pick(uif("UI_SLOT", [s + 1]), menu)
	if i < 0:
		return 0
	var act: int = menu[i][0]
	var ap: int = menu[i][1]
	if w.sb(u, 0xE) < ap:
		say_msg(0x1AE, [ap])
		return 0
	if act == Pockets.SWAP or act == Pockets.RELOAD:
		var p := magazine_table(u, s)
		if Pockets.pick_magazine(w, u, s, p, act == Pockets.RELOAD) == 1:
			Ai.spend_ap(w, u, ap)
			say(uif("UI_MAGAZINE_SWAPPED", [s + 1, p + 1]))
			return 1
		return 0
	if act == Pockets.HAND_OVER:
		return hand_over_flow(u, s, ap)
	return drop_flow(u, s, act, ap)


func pocket_menu_flow(u: int, p: int) -> int:
	## the machine status window's pocket (0x4279F0): manipulators broken 0x1B9; the pocket
	## menu (0x427FF0); its AP (0x1AE); handing over (0x4287A0), setting explosives
	## (0x428D80), recon (0x4285E0), discard (0x428400); "use" goes to the item command's
	## target click
	if Ai.manipulator_state(w, u) == 2:
		say_msg(0x1B9)
		return 0
	var menu := Pockets.pocket_menu(w, u, p)
	if w.fault != "":
		return 0
	var i := _menu_pick(uif("UI_POCKET", [p + 1]), menu)
	if i < 0:
		return 0
	var act: int = menu[i][0]
	var ap: int = menu[i][1]
	if w.sb(u, 0xE) < ap:
		say_msg(0x1AE, [ap])
		return 0
	match act:
		Pockets.HAND_OVER:
			return hand_over_flow(u, 10 + p, ap)
		Pockets.SET:
			if MissionScripts.lay_explosive(w, u, p, ap, mission_hooks) == 1:
				Ai.spend_ap(w, u, ap)
				return 1
			return 0
		Pockets.THROW:
			_status_stop = true                  # (the item command's target click follows)
			call_deferred("_item_pocket_mode", p)
			return 0
		Pockets.SEARCH:
			var hk := BattleReconHooks.new()
			hk.battle = self
			var res := Pockets.recon_round(w, u, p, hk)
			if res != 0 and not res in Pockets.ABORT:
				Pockets.recon_spend(w, u, p, ap)
				return 1
			return 0
	return drop_flow(u, 10 + p, act, ap)


func _item_pocket_mode(p: int) -> void:
	item_pocket = p
	mode = "item"
	var an: Dictionary = GameData.tables(campaign).get("ammo_names", {})
	say(uif("UI_ITEM_PICK", [p + 1, str(an.get(str(w.pocket_ammo(selected, p)), "")), Item.use_ap(w, selected, p)]))
	_update_move_map()


func _pocket_run(job: Callable) -> void:
	## a pocket action on the command thread (its windows wait for the player); auto_react:
	## on the main thread with the scripted answers
	busy = true
	if auto_react:
		job.call()
		_mission_cmd_done()
		return
	move_thread = Thread.new()
	move_thread.start(func():
		job.call()
		call_deferred("_mission_cmd_finished"))


func _cmd_slot_menu() -> void:
	## the current slot: in a fire mode as cmd_fire's magazine column (offered when the
	## weapon picker enables it, Action.weapon_choices), else the machine status window's
	if selected == -1 or busy or mission_over:
		return
	var u := selected
	var s := slot
	if mode in FIRE_MODES:
		if not (s + 4) in Action.weapon_choices(w, u, FIRE_MODES[mode], 0):
			say(ui("UI_NO_MAGAZINE_SWAP"))
			return
		_pocket_run(func(): slot_menu_flow(u, s, true))
		return
	_pocket_run(func(): machine_status_flow(u))


func _cmd_pocket_menu() -> void:
	## the machine status window (the command menu's 機体状況, entry 7: ui_machine_status
	## 0x4279F0 with its pilot, machine and damage windows)
	if selected == -1 or busy or mission_over:
		return
	var u := selected
	_pocket_run(func(): machine_status_flow(u))


var _status_stop := false


func machine_status_flow(u: int) -> void:
	## ui_machine_status (0x4279F0): the window (0x4E8930) until a right click; a slot's
	## row runs the slot menu, a pocket's the pocket menu (their refusals, AP and actions:
	## slot_menu_flow / pocket_menu_flow); none listed: 0x1D6
	_status_stop = false
	while not _status_stop:
		var rs := MachineStatus.rows(self, u)
		if rs.is_empty():
			say_msg(0x1D6)
			return
		var v: int = ask_status(u, rs)
		if v == -2:
			return
		if v < 4:
			slot_menu_flow(u, v, false)
		else:
			pocket_menu_flow(u, v - 10)


func ask_status(u: int, rs: Array) -> int:
	## the status window on the main thread, waited for (auto_react / scripted: as ask_choice)
	if not scripted.is_empty():
		return scripted.pop_front()
	if auto_react or OS.get_thread_caller_id() == OS.get_main_thread_id():
		return -2
	call_deferred("_open_status", u, rs)
	react_sem.wait()
	return react_answer


func msg_codes(id: int) -> String:
	## a message's format with its %aHH codes as the printer's (byte 1 + HH): format_text
	## turns them into the same
	var t := msg_raw(id)
	var re := RegEx.create_from_string("%a([0-9A-Fa-f]{2})")
	var out := ""
	var last := 0
	for m in re.search_all(t):
		out += t.substr(last, m.get_start() - last) + "" + char(m.get_string(1).hex_to_int())
		last = m.get_end()
	return out + t.substr(last)


func open_status(u: int, rs: Array) -> GameWindow:
	## 0x4E8930 / 0x467880 in the main window: the pilot's window (15 x 11) at (x, y - 0xC0),
	## the damage diagram (14 x 10, black inside: hidan.pac by machine +0x19 at (8, 4), the
	## broken parts XORed) at (x + 0x88, y - 0xB0), the machine's window (16 x 7) at
	## (x + 0x108, y - 0x80), x = (640 - 0x260) / 2, y = max(400 / 2 - 0x20, 0xC0); the header
	## 0x1D2 (74 columns, one line) and the rows' select window under it, centred on the
	## screen's width (fonts 16 px)
	var ux := maxi(0, (MAIN_W - 0x260) >> 1)
	var py := maxi((MAIN_H >> 1) - 0x20, 0xC0)
	var w1 := GameWindow.text_window(ux, py - 0xC0, 15, 11, 0)
	w1.waits = false
	var w0 := GameWindow.text_window(ux + 0x88, py - 0xB0, 14, 10, 0)
	w0.black = true
	w0.clear()
	var m := Pd2World.s8(w.ub(u, 0xC))
	var pic := w.umachine(u, 0x19) if m >= 0 else 0
	if pic > 7:
		pic = 0
	w0.blit("%s/images/hidan/%02d.bmp" % [GameData.ROOT, pic], 8, 4)
	MachineStatus.damage(w0, w, u)
	var w2 := GameWindow.text_window(ux + 0x108, py - 0x80, 16, 7, 0)
	w2.waits = false
	var lw := (0x4A + (3 if rs.size() > GameWindow.SCROLL_SHOWN else 0)) * 8 + 16
	var x := maxi(0, (MAIN_W - lw) >> 1)
	var y := py
	var hd := GameWindow.text_window(x, y, 0x4A, 1, 0)
	hd.waits = false
	var labels := rs.map(func(r): return r[0])
	var lst := GameWindow.select_window(x, y + 0x20, 0x4A, 0, 0, labels, 0x4A, [], true)
	_hold([w1, w0, w2, hd, lst])
	w1.print_text(MachineStatus.pilot_text(self, u))
	w2.print_text(MachineStatus.machine_text(self, u))
	hd.print_text(GameWindow.coded(text_cells(msg_codes(0x1D2), [])))
	return lst


func _open_status(u: int, rs: Array) -> void:
	var lst := open_status(u, rs)
	lst.chosen.connect(func(v: int): _answer_reaction(-2 if v < 0 or v >= rs.size() else int(rs[v][1])))


func _pocket_pick(u: int) -> void:
	var opts := []
	var an: Dictionary = GameData.tables(campaign).get("ammo_names", {})
	for p in 12:
		var a := w.pocket_ammo(u, p)
		if a != -1:
			opts.append([uif("UI_POCKET_ROUND", [p + 1, str(an.get(str(a), "#%d" % a)), w.pocket_count(u, p)]), p])
	if opts.is_empty():
		say(ui("UI_NO_ITEM"))
		return
	opts.append([ui("UI_CANCEL"), -2])
	var p: int = ask_choice(ui("UI_POCKET_MENU"), opts, -2)
	if p >= 0:
		pocket_menu_flow(u, p)


func _mission_cmd_finished() -> void:
	move_thread.wait_to_finish()
	move_thread = null
	_mission_cmd_done()


func _mission_cmd_done() -> void:
	busy = false
	_after_command()


# --- the new campaign's pilot choice (0x422050) --------------------------------------

class BattlePickHooks extends Campaign.Hooks:
	## Campaign.campaign_pick's windows on the build's worker thread
	var battle

	func pick_list(entries: Array, picked: Array) -> int:
		var rows := []
		for i in entries.size():
			rows.append(battle.pick_row(world, entries[i], picked[i]))
		battle.call_deferred("_open_pick", rows, picked.duplicate())
		battle.react_sem.wait()
		return battle.react_answer

	func pick_ask(text: int, arg: Variant) -> int:
		## 0x451E30: a message box of kind 1 in the start window; yes = 1
		var t: String = GameData.exe_text(battle.campaign, text, [arg] if arg != null else [])
		battle.call_deferred("_open_pick_box", t)
		battle.react_sem.wait()
		return battle.react_answer

	func pick_note(text: int) -> int:
		## 0x452170: a red line at y 0xAA, until a click
		battle.call_deferred("_open_pick_note", GameData.exe_text(battle.campaign, text))
		battle.react_sem.wait()
		return 0


var _pick_layer: CanvasLayer = null
var _pick_count := 0


func _pick_interactive() -> bool:
	return not auto_react and sortie_window and not _headless() and scripted.is_empty()


func pick_row(wd: Pd2World, c: int, picked: bool) -> String:
	## 0x422950's row for crew c: "%aFF%-14s %2d " (given and family name, crew +9), crew
	## +0xA..+0xD as "%2X " (or "%2d " when negative), the skill bits 1 2 4 8 as 有 / 無
	## ("%s %s %s %s%aFF"); a picked row's colour byte 'F' becomes 'C' (0x43, green)
	var nm: Array = GameData.tables(campaign).crew_names
	var id := Pd2World.s8(wd.crew[c * 16])
	var n: Array = nm[id] if id >= 0 and id < nm.size() else ["", ""]
	var name := "%s %s" % [n[0], n[1]]
	var pad := 14 - GameWindow.text_cols(name)
	var t := "\u0001" + char(0xCF if picked else 0xFF) + name + " ".repeat(maxi(pad, 0)) + " %2d " % Pd2World.s8(wd.crew[c * 16 + 9])
	for f in [0xA, 0xB, 0xC, 0xD]:
		var v := Pd2World.s8(wd.crew[c * 16 + f])
		t += ("%2X " % v) if v >= 0 else ("%2d " % v)
	var sk := wd.crew[c * 16 + 8]
	var yn := func(b: int) -> String: return GameData.exe_text(campaign, 0x50CBB3 if sk & b else 0x50CBB6)
	t += "%s %s %s %s" % [yn.call(1), yn.call(2), yn.call(4), yn.call(8)] + "\u0001" + char(0xFF)
	return t


func _pick_root() -> Control:
	## the start window (DS:0x554FA4, 640 x 400, empty) while the choice is up
	if _pick_layer == null:
		_pick_layer = CanvasLayer.new()
		_pick_layer.layer = 5
		add_child(_pick_layer)
		var bg := ColorRect.new()
		bg.color = Color.BLACK
		bg.size = get_viewport().get_visible_rect().size
		_pick_layer.add_child(bg)
		var r := Control.new()
		r.size = Vector2(MAIN_W, MAIN_H)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var vs := get_viewport().get_visible_rect().size
		var sc := minf(vs.x / MAIN_W, vs.y / MAIN_H)
		r.scale = Vector2(sc, sc)
		_pick_layer.add_child(r)
		r.name = "root"
	return _pick_layer.get_node("root")


func _pick_hold(wins: Array) -> Control:
	var hold := Control.new()
	hold.size = Vector2(MAIN_W, MAIN_H)
	hold.mouse_filter = Control.MOUSE_FILTER_STOP
	for gw in wins:
		hold.add_child(gw)
	var top = wins[-1]
	hold.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			top.outside(ev.button_index))
	_pick_root().add_child(hold)
	react_panel = hold
	return hold


func _open_pick(rows: Array, picked: Array) -> void:
	## 0x422050: the count line in a framed window at (0x38, 0x30) (42 x 1, flags 1:
	## "現在%2d名選択 あと%2d名です", DASH DS:0x513A80 / PD2 0x513A64), the list (0x452A10)
	## at (0x38, 0x50): its header DS:0x513A9C (42 x 2) whose nine columns (x 0x80 + 0x18 k
	## .. +0x10, y 8 .. 0x27) are the sort buttons (0-8), the rows (9 + row), a right click
	## the done / fill question (-2)
	var pd2 := campaign != "dash"
	var need: int = Campaign.PICK_COUNT[1 if pd2 else 0]
	var n := 0
	for p in picked:
		if p:
			n += 1
	var cw := GameWindow.text_window(0x38, 0x30, 0x2A, 1, 1)
	cw.waits = false
	var regs := []
	for k in 9:
		regs.append([0x80 + 0x18 * k, 8, 0x90 + 0x18 * k, 0x27, 2])
	var lst := GameWindow.select_window(0x38, 0x50, 0x2A, 2, 1, rows, 0x2A, regs, true)
	lst.role = "pick"
	lst.waits = false
	_pick_hold([cw, lst])
	cw.print_text(GameData.exe_text(campaign, 0x513A64 if pd2 else 0x513A80, [n, need - n]))
	lst.print_text(GameData.exe_text(campaign, 0x513A9C))
	lst.chosen.connect(func(v: int):
		react_panel.queue_free()
		react_panel = null
		react_answer = v
		react_sem.post())


func _open_pick_box(t: String) -> void:
	## 0x451E30: ui_message_box's layout (kind 1: 実行 / 中止) in the start window
	var l: Array = BOX_LABELS[1]
	var labels := [GameData.exe_text(campaign, l[0]), GameData.exe_text(campaign, l[1])]
	var wins := box_windows(t, labels)
	_pick_hold(wins)
	wins[0].print_text(wins[0].get_meta("text"))
	wins[1].chosen.connect(func(v: int):
		react_panel.queue_free()
		react_panel = null
		react_answer = 1 if v == 0 else 0
		react_sem.post())


func _open_pick_note(t: String) -> void:
	## 0x452200 at y 0xAA: "%a4F" then the line, a click
	var n := mini(GameWindow.text_cols(t), 76)
	var gw := GameWindow.text_window(((80 - (n + 2)) / 2) * 8, 0xAA, n, 1, 1)
	gw.waits = not _headless()
	var hold := _pick_hold([gw])
	await gw.print_text("\u0001" + char(0x4F) + t + "\n")
	hold.queue_free()
	react_panel = null
	react_sem.post()


func _pick_close() -> void:
	if _pick_layer:
		_pick_layer.queue_free()
		_pick_layer = null


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
	## reaction_menu_list (0x472ED0) and ui_reaction_menu (0x4730E0): a select window of 32
	## columns at the cursor (x & ~7 - 0x50, y - 0x30; 640 - 0x128 when x & ~7 + 0xD7 passes
	## 640, 400 - min(n, 12) x 16 - 16 when the list would pass 400; not below 0): "ignore
	## this unit" (DS:0x517838), "wait and see" (0x517850), then the units that have not
	## reacted (+0 bit 0x40), each "%b%12s　%8s %8s" (DS:0x517860: 0x7F, the machine's code
	## DS:0x50C2E5, the pilot's names); a unit goes on to the weapon picker (mode 5 / 10, the
	## distance to the target), a right click looks at the map until a click (ui_map_click
	## mode 6)
	var listed := []
	var labels := [GameData.exe_text(campaign, 0x517838), GameData.exe_text(campaign, 0x517850)]
	var codes: Array = GameData.tables(campaign).get("machine_codes", [])
	for b in menu:
		if w.ub(b, 0) & 0x40:
			continue
		listed.append(b)
		var nm := intercept_names(b)
		var m := Pd2World.s8(w.ub(b, 0xC))
		labels.append(GameWindow.coded(text_cells(GameData.exe_raw(campaign, 0x517860),
				[0x7F, str(codes[m]) if m >= 0 and m < codes.size() else "", nm[0], nm[1]])))
	var n := mini(labels.size(), 12)
	var mp := _mouse_main()
	var x := (int(mp.x) & 0xFFF8) - 0x50
	var y := int(mp.y) - 0x30
	if (int(mp.x) & 0xFFF8) + 0xD7 > MAIN_W:
		x = MAIN_W - 0x128
	if int(mp.y) - 0x21 + n * 16 > MAIN_H:
		y = MAIN_H - n * 16 - 16
	var gw := GameWindow.select_window(maxi(x, 0), maxi(y, 0), 0x20, 0, 0, labels, 0x20, [], true)
	gw.role = "reaction"
	_hold([gw])
	gw.chosen.connect(func(v: int):
		_close_window(gw)
		if v == -2:
			react_look = [menu, t, mode]
		elif v == 0 or v == 1:
			_answer_reaction(v)
		else:
			_show_reaction_weapons(menu, t, mode, listed[v - 2]))


var react_look: Array = []      # the reaction menu put away to look at the map (a click brings it back)


func _show_reaction_weapons(menu: Array, t: int, mode: int, b: int) -> void:
	## 0x472920: the weapon picker (0x4E7EE0) for b until a slot fires (reaction_shot) or a
	## right click goes back to the menu; a magazine answer shows the picker again
	var bp := w.pos(b)
	var tp := w.pos(t)
	_open_weapon(b, mode, Pd2World.hexdist(bp.x, bp.y, tp.x, tp.y), func(v: int):
		if v == -2:
			_show_reaction_units(menu, t, mode)
		elif v >= 4:
			_show_reaction_weapons(menu, t, mode, b)
		else:
			_answer_reaction([b, [v]]))



# --- the weapon picker (ui_reaction_weapon_picker 0x4E7EE0) --------------------------

func weapon_picker_rows(u: int, mode: int, dist: int) -> Array:
	## 0x4E7EE0's four rows (WMES 0x1D1 then the round 0x1CE / 0x1CF / 0x1D0, a slot without
	## a launcher 0x1D0): each column red (0x4F) where the mode refuses it, the row's name
	## 0x40 when any is; [text, refused] per slot (display: the answers are
	## Action.weapon_choices', emulated)
	var ln: Dictionary = GameData.tables(campaign).get("launcher_names", {})
	var an: Dictionary = GameData.tables(campaign).get("ammo_names", {})
	var out := []
	for k in 4:
		var lid := w.launcher_id(u, k)
		if lid == -1:
			out.append([GameWindow.coded(text_cells(msg_raw(0x1D0), [0x40])), true])
			continue
		var bad := false
		var rng_ := w.weapon_range(u, k) & 0xFF
		var rc := 0xFF
		if rng_ == 0:
			rc = 0x4F
			bad = true
		if (mode == 5 or mode == 10) and rng_ < dist:
			rc = 0x4F
			bad = true
		if k > 1 and both_arms_broken(u):
			rc = 0x4F
			bad = true
		var acs := ""
		var ac := 0xFF
		var tc := 0xFF
		var atk := 0
		var radius := w.launcher(lid, 9) & 7
		var dc := 0xFF
		if mode == 6 or mode == 7 or mode == 10:
			var acc := w.launcher(lid, 5)
			if acc == 0xFF:
				acs = GameData.exe_text(campaign, 0x50CBE1)
			elif acc != 0:
				acs = "%d%d" % [(acc / 10) % 10, acc % 10]
			else:
				acs = " 0"
				ac = 0x4F
				bad = true
			atk = Move.final_attack(w, u, k, true) & 0xFF
			if atk == 0:
				tc = 0x4F
				bad = true
		else:
			var acc := w.launcher(lid, 2)
			var wh := w.warhead(u, k)
			if acc == 0xFF:
				acs = GameData.exe_text(campaign, 0x50CBE1)
			elif acc != 0 or wh == 8:
				acs = "%d%d" % [(acc / 10) % 10, acc % 10]
			else:
				acs = " 0"
				ac = 0x4F
				bad = true
			atk = Move.final_attack(w, u, k, false) & 0xFF
			if atk == 0 and wh != 8:
				tc = 0x4F
				bad = true
			if (mode == 1 and radius != 0) or (mode == 5 and radius != 1):
				dc = 0x4F
				bad = true
		var ap := Move.launcher_ap(w, lid) * (2 if mode == 1 else 1)
		var pc := 0xFF
		if w.sb(u, 0xE) < ap and mode != 5 and mode != 10 and mode != 7:
			pc = 0x4F
			bad = true
		var kind := w.launcher(lid, 8) >> 5
		var kc := 0xFF
		if kind == 3 or (kind != 0 and (mode == 1 or mode == 5)) or (mode == 7 and kind == 2):
			kc = 0x4F
			bad = true
		var cnt := w.slot_count(u, k)
		var magazine := (w.launcher(lid, 9) & 8) != 0
		var tail := ""
		var st := w.slot_state(u, k)
		var sc := 0x4F if st == 2 else 0xFF
		if st == 2:
			bad = true
		var stt: String = GameData.exe_text(campaign, [0x51F6B4, 0x51F6B8, 0x51F6BC][st]) if st >= 0 and st <= 2 else ""
		if cnt == 0:
			bad = true
			if magazine:
				tail = GameWindow.coded(text_cells(msg_raw(0x1CF), [0x4F, sc, stt]))
			else:
				tail = GameWindow.coded(text_cells(msg_raw(0x1D0), [0x4F]))
		else:
			var amc := 0xFF
			var name := ""
			if Pd2World.s8(w.launcher(lid, 11)) != -1:
				name = str(an.get(str(w.ammo_id(u, k)), ""))
				if (w.ub(u, 0x1C + 2 * (w.ub(u, 0x10 + 2 * k) & 15)) >> 6) & 3 == 2:
					amc = 0x4F
					bad = true
			var cs := GameData.exe_text(campaign, 0x51F6C0) if cnt == -1 else "x%d%d" % [(cnt / 10) % 10, cnt % 10]
			tail = GameWindow.coded(text_cells(msg_raw(0x1CE), [amc, name, 0xFF, cs, sc, stt]))
		var head := text_cells(msg_raw(0x1D1), [0x40 if bad else 0xF0, str(ln.get(str(lid), "")), rc, rng_,
				ac, acs, tc, atk, pc, ap, kc, _kind_char(kind), dc, radius])
		out.append([GameWindow.coded(head) + tail, bad])
	return out


func open_weapon_picker(u: int, mode: int, dist: int) -> GameWindow:
	## 0x4E7EE0: a select window with no items, its header 52 x 5 of 16 px ("%s\n%s\n%s\n%s\n%s",
	## DS:0x51F6D0: 0x1CD and the four rows) centred on the screen, eight regions: the rows
	## (8, 0x18 + 16 k)-(0xF7, 0x27 + 16 k) answer slot k, their right part (0xF8 ..)-(0x187
	## ..) its magazine (4 + k); a right click cancels
	var rs := weapon_picker_rows(u, mode, dist)
	var t := GameWindow.coded(text_cells(msg_codes(0x1CD), []))
	for r in rs:
		t += "\n" + str(r[0])
	var regs := []
	for k in 4:
		regs.append([8, 0x18 + 16 * k, 0xF7, 0x27 + 16 * k, 1])
	for k in 4:
		regs.append([0xF8, 0x18 + 16 * k, 0x187, 0x27 + 16 * k, 1])
	var ww := 0x34 * 8 + 16
	var hh := 5 * 16 + 16
	var gw := GameWindow.select_window((MAIN_W - ww) >> 1, (MAIN_H - hh) >> 1, 0x34, 5, 0, [], 0, regs, true)
	gw.role = "weapon"
	gw.waits = false
	_hold([gw])
	gw.print_text(t)
	return gw


func ask_weapon(u: int, mode: int, dist: int) -> int:
	## the weapon picker on a worker thread: a slot 0-3, its magazine 4-7, or -2; a choice
	## the picker refuses (not in Action.weapon_choices) keeps it open, as its loop does.
	## auto_react / scripted: as ask_choice.
	if not scripted.is_empty():
		return scripted.pop_front()
	if auto_react or OS.get_thread_caller_id() == OS.get_main_thread_id():
		return -2
	call_deferred("_open_weapon", u, mode, dist)
	react_sem.wait()
	return react_answer


func _open_weapon(u: int, mode: int, dist: int, then := Callable()) -> void:
	var ok := Action.weapon_choices(w, u, mode, dist)
	var gw := open_weapon_picker(u, mode, dist)
	gw.chosen.connect(func(v: int):
		if v >= 0 and not v in ok:
			return                               # refused: the picker stays
		if then.is_valid():
			_close_window(gw)
			then.call(v)
		else:
			_answer_reaction(v))


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
