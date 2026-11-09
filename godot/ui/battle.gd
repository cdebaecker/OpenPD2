extends Node2D
## The tactical battle, sandbox edition: one mission's map and enemy force (INIT), a
## stand-in squad (Mission.sandbox_squad), the player's commands and the computer's
## whole turn, all through the ported rules in core/. What is not ported yet (briefing,
## event scripts, melee resolution, the player's fire / reaction menus, the strike
## executor) is replaced by the simplest stand-in and listed in engine/README.md.

const TILE_W := 48
const TILE_H := 36
const MAP := 72

var campaign := "dash"
var mission_index := 0

var w: Pd2World
var rng: Pd2Random
var hooks: SandboxHooks
var squad: Array = []
var names := {}
var selected := -1
var mode := "move"          # move / fire / aimed
var move_mode := 1          # 0 high speed, 1 normal, 2 careful
var slot := 0
var mm: Move.MoveMap = null
var fire_map: Move.MoveMap = null
var carry_hexes: Array = []
var turn := 1
var alert := 0
var busy := false
## The computer's turn runs on a worker thread so that the player's reaction menu can
## pause it; auto_react answers the menu without asking (tests, headless runs).
var auto_react := false
var react_policy := Callable()     # auto_react's answers (tests); default: strongest weapon
var ai_thread: Thread = null
var ai_running := false
var react_sem := Semaphore.new()
var react_answer: Variant = 1
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
		var p := w.pos(k)
		if w.on_map(p.x, p.y) and w.O[p.x + MAP * p.y] == k + 1:
			w.O[p.x + MAP * p.y] = 0
		w.setb(k, 0, w.ub(k, 0) | 1)
		battle.say("[color=orange]%s destroyed[/color]" % battle.unit_name(k))

	func mine_blast(x: int, y: int) -> void:
		battle.say("mine explodes at %d, %d" % [x, y])


func _ready() -> void:
	var tables := GameData.tables(campaign)
	var doc := GameData.mission(campaign, mission_index)
	w = Mission.build(tables, doc, campaign)
	rng = Pd2Random.new(int(Time.get_ticks_usec()) & 0xFFFF)
	hooks = SandboxHooks.new(w, false, rng)
	hooks.battle = self
	names = {"crew": tables.crew_names, "machine": tables.machine_names}
	squad = Mission.sandbox_squad(w, 4)
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
	_clear_spotted()
	_recon_pass(3)
	_recon_pass(0)
	Turn.refill_ap(w, 0)
	if not squad.is_empty():
		_select(squad[0])
		cam.position = hex_center(w.pos(squad[0]))
	say("Turn 1. %d DoLLS dropped; %d enemy units on the map." % [squad.size(), _count_side(3)])


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
	for b in [["Search [S]", _cmd_search], ["Conceal [C]", _cmd_conceal], ["Carry / release [K]", _cmd_carry_mode],
			["Next [Tab]", _next_unit], ["End turn [E]", _end_turn]]:
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
			KEY_E: _end_turn()
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
	if selected != -1 and w.active(selected):
		mm = Move.move_map(w, selected, move_mode)
		if mode in FIRE_MODES and w.launcher_id(selected, slot) != -1:
			fire_map = Action.fire_target_map(w, selected, slot, FIRE_MODES[mode])
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
	if mode == "move":
		_cmd_move(h)
	else:
		_cmd_fire(h, FIRE_MODES[mode])


# --- commands ------------------------------------------------------------------

func _cmd_move(h: Vector2i) -> void:
	if mm == null:
		return
	var c := mm.cell(h.x, h.y)
	if c <= 0 or c == 0xFF:
		return
	var u := selected
	if c & Move.MELEE_FLAG:
		_cmd_melee(u, h, c & 0x7F)
		return
	hooks.flag = 0
	var p := w.pos(u)
	var res: int
	if Pd2World.hexdist(p.x, p.y, h.x, h.y) == 1:
		res = Action.ai_walk(w, rng, u, h.x, h.y, move_mode, mm, hooks)
	else:
		res = Action.ai_path(w, rng, u, h.x, h.y, move_mode, mm, hooks)
	if res & 1:
		say("%s: contact." % unit_name(u))
	if res & 4 or not w.active(u):
		say("%s lost." % unit_name(u))
	_after_command()


func _cmd_melee(u: int, h: Vector2i, cost: int) -> void:
	## Entering a hex held by a spotted enemy starts a melee, as the AI's charge does
	## (0x430660): the hex's AP, the melee, then the winner's follow-up. The player's own
	## melee command flow is not ported; this mirrors the AI's.
	var o := w.O[h.x + MAP * h.y] - 1
	if o == -1:
		return
	Ai.spend_ap(w, u, cost)
	var res := hooks.melee(u, o)
	if res == 0:
		hooks.destroy(o)
		if w.O[h.x + MAP * h.y] - 1 == -1:
			Action.ai_walk(w, rng, u, h.x, h.y, (w.ub(u, 4) >> 4) & 3, mm, hooks)
	elif res == 2 or res == 3:
		hooks.destroy(u)
		if res == 3:
			hooks.destroy(o)
	_after_command()


const FIRE_MODES := {"fire": 0, "aimed": 1, "aa": 6}
const FIRE_MESSAGES := {0x1A8: "Both manipulators are broken: no hand weapons.",
	0x1A9: "No target there.", 0x1AA: "Helicopters need anti-air fire.",
	0x1AB: "Anti-air fire only at helicopters.",
	0x1AC: "The target is within the blast radius. Fire?", 0x1AD: "Fire? (%d AP)"}


func _fire_message(id: int, cost := 0) -> String:
	## Stand-in texts: the game's own (message_text) come with the translation tables.
	var t: String = FIRE_MESSAGES.get(id, "")
	return t % cost if "%d" in t else t


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
		say("Not enough AP (%d needed)." % cost)
		return
	if fire_map == null or fire_map.cell(h.x, h.y) != 1:
		return
	var check := Action.fire_check(w, u, slot, fmode, h.x, h.y)
	if check[0] == Action.FIRE_REFUSED:
		if check[1] != -1:
			say(_fire_message(check[1]))
		return
	if check[0] == Action.FIRE_CONFIRM:
		var dlg := ConfirmationDialog.new()
		dlg.dialog_text = _fire_message(check[1], cost)
		dlg.confirmed.connect(_do_fire.bind(u, fmode, h))
		dlg.confirmed.connect(dlg.queue_free)
		dlg.canceled.connect(dlg.queue_free)
		add_child(dlg)
		dlg.popup_centered()
		return
	_do_fire(u, fmode, h)


func _do_fire(u: int, fmode: int, h: Vector2i) -> void:
	var before := {}
	for q in w.n_units:
		before[q] = w.ub(q, 0xD)
	Action.player_fire(w, rng, u, slot, fmode, h.x, h.y, hooks, false, alert)
	var hit := false
	for q in w.n_units:
		if w.ub(q, 0xD) < before[q]:
			hit = true
			say("%s hits %s: %d damage" % [unit_name(u), unit_name(q), before[q] - w.ub(q, 0xD)])
	if not hit:
		say("%s fires: no hit." % unit_name(u))
	_after_command()


const CMD_MESSAGES := {0x1AF: "Already concealed.", 0x1B0: "Conceal here? (%d AP)",
	0x1B1: "No free hex to set the unit down.", 0x1B2: "Set the unit down here?",
	0x1B3: "No DoLL next to this unit to carry.", 0x1B4: "That unit is carrying another.",
	0x1B5: "Carry this unit?", 0x1C8: "Search this area? (%d AP)",
	0x1DD: "Both manipulators are broken: cannot carry.", 0x212: "Aircraft cannot carry."}


func _cmd_message(id: Variant, n := 0) -> String:
	## Stand-in texts until the game's own (message_text) come with the translation tables.
	if id is String:
		return "Not enough AP."
	var t: String = CMD_MESSAGES.get(id, "")
	return t % n if "%d" in t else t


func _confirm(text: String, then: Callable) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = text
	dlg.confirmed.connect(then)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _cmd_search() -> void:
	## cmd_search (Action.player_search, emulated).
	if selected == -1:
		return
	var u := selected
	if w.sb(u, 0xE) < Action.search_cost(w, u):
		say(_cmd_message("ap"))
		return
	_confirm(_cmd_message(0x1C8, Action.search_cost(w, u)), func():
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
	if not (why is String and why == ""):
		say(_cmd_message(why))
		return
	var cost := 3 if (w.ucrew(u, 8) >> 3) & 1 else 6
	_confirm(_cmd_message(0x1B0, cost), func():
		Ai.ai_conceal(w, u)
		say("%s conceals." % unit_name(u))
		_after_command())


func _cmd_carry_mode() -> void:
	## Carry when the unit carries nobody, release otherwise (the unit menu's entry 10).
	if selected == -1:
		return
	var u := selected
	var res: Array = Action.carry_candidates(w, u) if w.ub(u, 0x34) == 0xFF else Action.release_candidates(w, u)
	if res[0].is_empty():
		say(_cmd_message(res[1]))
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
		_confirm(_cmd_message(0x1B5), func():
			var why := Action.player_carry(w, u, o)
			if why != -1:
				say(_cmd_message(why))
			else:
				say("%s picks up %s." % [unit_name(u), unit_name(o)])
			_set_mode("move")
			_after_command())
	else:
		var carried := w.ub(u, 0x34)
		_confirm(_cmd_message(0x1B2), func():
			Action.player_release(w, u, h.x, h.y)
			if not carried in squad:
				pass
			say("%s sets down %s." % [unit_name(u), unit_name(carried)])
			_set_mode("move")
			_after_command())


func _after_command() -> void:
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	_update_move_map()
	_check_end()


# --- the turn --------------------------------------------------------------------

func _recon_pass(side: int) -> void:
	## 0x483490(0): with the campaign flag set, F-layer bit 5 is cleared first; then
	## each active unit of the side searches with its movement mode (0x47F500 without the
	## command's prompt and cost: what step_search does).
	if w.campaign:
		for y in MAP:
			for x in MAP:
				if w.on_map(x, y):
					w.F[x + MAP * y] &= 0xDF
	for u in w.n_units:
		if w.active(u) and (3 if w.is_enemy(u) else 0) == side:
			Action.step_search(w, u, (w.ub(u, 4) >> 4) & 3)


func _clear_spotted() -> void:
	## 0x437440: every spotted flag is cleared (units 0-253).
	for u in w.n_units:
		w.setb(u, 0, w.ub(u, 0) & ~0x10)


func _clear_view(side: int) -> void:
	## 0x47D5C0(side): the side's view marks (F-layer bit 3 for the player, 2 for the enemy).
	var bit := 0x08 if side < 3 else 0x04
	for y in MAP:
		for x in MAP:
			if w.on_map(x, y):
				w.F[x + MAP * y] &= ~bit


func _end_turn() -> void:
	## The mission loop's turn (0x436690; RULES.md 5.7), less the event scripts, the
	## strike executor and support fire, which are not ported.
	if busy:
		return
	busy = true
	say("[b]Enemy phase[/b]")
	_clear_spotted()
	_clear_view(0)
	_recon_pass(0)
	Turn.turn_upkeep(w, rng, Turn.PHASE_ENEMY)
	Turn.refill_ap(w, Turn.PHASE_ENEMY)
	_clear_view(3)
	_recon_pass(3)
	for u in w.n_units:                  # 0x4361A0: the reacted flags
		w.setb(u, 0, w.ub(u, 0) & ~0x40)
	hooks.flag = 0
	if auto_react:
		var undefined0 := []
		_end_turn_finish(AiTurn.run(w, rng, hooks, alert, false, undefined0), undefined0)
		return
	ai_running = true
	ai_thread = Thread.new()
	ai_thread.start(_ai_phase)


func _ai_phase() -> void:
	## Worker thread: the computer's turn. Only the reaction menu talks to the main
	## thread meanwhile (ask_reaction); input is blocked by `busy`.
	var undefined := []
	var res := AiTurn.run(w, rng, hooks, alert, false, undefined)
	call_deferred("_ai_done", res, undefined)


func _ai_done(res: int, undefined: Array) -> void:
	ai_thread.wait_to_finish()
	ai_thread = null
	ai_running = false
	overlay.queue_redraw()
	_end_turn_finish(res, undefined)


func _end_turn_finish(res: int, undefined: Array) -> void:
	last_ai_result = res
	if not undefined.is_empty():
		say("[color=gray](%d unit(s) reached a case the game leaves undefined; their orders ended there)[/color]" % undefined.size())
	if res in Ai.AI_ABORT:
		say("The computer's turn ended early (code 0x%X: its path-search pool ran out)." % res)
	if w.fault != "":
		say("[color=red]rules fault: %s[/color]" % w.fault)
		w.fault = ""
	Turn.turn_upkeep(w, rng, Turn.PHASE_PLAYER)
	Turn.refill_ap(w, Turn.PHASE_PLAYER)
	# the next player turn starts (0x436B39): spotting and views are redone
	_clear_spotted()
	_clear_view(3)
	_recon_pass(3)
	_clear_view(0)
	_recon_pass(0)
	turn += 1
	say("[b]Turn %d[/b]" % turn)
	busy = false
	if selected != -1 and not w.active(selected):
		_next_unit()
	_update_move_map()
	_check_end()


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
	if squad.all(func(u): return not w.active(u)):
		say("[color=red]The squad is lost.[/color]")
	elif _count_side(3) == 0:
		say("[color=lime]No enemy unit left.[/color]")


# --- drawing ---------------------------------------------------------------------

func _draw_overlay() -> void:
	if w == null or (ai_running and react_panel == null):
		return
	if mode == "carry":
		for hx in carry_hexes:
			overlay.draw_circle(hex_center(hx), 14, Color(0.4, 1, 0.6, 0.35))
	if fire_map != null and mode != "move" and mode != "carry":
		for ly in fire_map.h:
			for lx in fire_map.w:
				if fire_map.at(lx, ly) == 1:
					overlay.draw_circle(hex_center(Vector2i(fire_map.x0 + lx, fire_map.y0 + ly)), 10, Color(1, 0.8, 0.2, 0.25))
	if mm != null and mode == "move":
		for ly in mm.h:
			for lx in mm.w:
				var c := mm.at(lx, ly)
				if c != 0 and c != 0xFF:
					var col := Color(1, 0.3, 0.2, 0.35) if c & Move.MELEE_FLAG else Color(0.3, 0.8, 1.0, 0.22)
					overlay.draw_circle(hex_center(Vector2i(mm.x0 + lx, mm.y0 + ly)), 14, col)
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
