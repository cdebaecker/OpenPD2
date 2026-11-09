extends Node2D
## The tactical battle, sandbox edition: one mission's map and enemy force (INIT), a
## stand-in squad (Mission.sandbox_squad), the player's commands and the computer's
## whole turn, all through the ported rules in core/. What is not ported yet (briefing,
## event scripts, the strike executor, magazine swaps) is replaced by the simplest
## stand-in and listed in engine/README.md.

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
var move_dests: Array = []
var move_thread: Thread = null
var turn := 1
var alert := 0
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
	w = Mission.build(tables, doc, campaign)
	w.phase = 0
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
	# a new mission (mission_loop 0x436690 with DS:0x50AD94 = 0): the loader's layer reset
	# (0x482910), start_units (0x437490), [mission script stage 2: not ported], the
	# occupancy rebuilt (0x483030), [the mission's start script: not ported], the player's
	# upkeep and AP, then the turn start (LAB_00436b39)
	Mission.layers_reset(w)
	Mission.start_units(w)
	Mission.rebuild_occupancy(w)
	w.phase = 0
	Turn.turn_upkeep(w, rng, Turn.PHASE_PLAYER)
	Turn.refill_ap(w, Turn.PHASE_PLAYER)
	w.phase = 3
	_turn_start()
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
	move_dests = []
	if selected != -1 and w.active(selected):
		mm = Move.move_map(w, selected, move_mode)
		if Action.move_refusal(w, selected) == -1:
			move_dests = Action.move_destinations(w, selected, mm)
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

# --- the game's messages ------------------------------------------------------------

func msg(id: int, args := []) -> String:
	## a battle message (WMES.PCK), translated and formatted as format_text does
	return GameData.battle_text(campaign, id, args)


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
	## DoLLS (0x480C60); then the player's phase, view and recon pass. (The date window
	## 0x4361C0, the camera 0x436360 and 0x4F3DA0 are display.)
	Turn.smoke_clears(w, rng)
	Turn.clear_spotted_all(w, options)
	Turn.clear_view(w, 3)
	Turn.recon_pass(w, 3)
	Turn.memory_record(w)
	w.phase = 0
	_view_reset(0)
	Turn.recon_pass(w, 0)


func _end_turn() -> void:
	## mission_loop (0x436690) after the player's commands, call by call; the mission's
	## event scripts and the strike executor (0x4E37A0) are not ported.
	if busy:
		return
	busy = true
	say("[b]Enemy phase[/b]")
	Turn.support_fire(w, 0)
	Turn.clear_spotted_all(w, options)
	_view_reset(0)
	Turn.recon_pass(w, 0)                # still the player's phase
	w.phase = 3
	Turn.turn_upkeep(w, rng, Turn.PHASE_ENEMY)
	Turn.refill_ap(w, Turn.PHASE_ENEMY)
	Turn.clear_view(w, 3)
	Turn.recon_pass(w, 3)
	Turn.memory_forget(w)
	Turn.clear_reacted_all(w)
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
	Turn.support_fire(w, 3)
	w.phase = 0
	Turn.turn_upkeep(w, rng, Turn.PHASE_PLAYER)
	Turn.refill_ap(w, Turn.PHASE_PLAYER)
	w.phase = 3
	Turn.clear_strikes(w)                # 0x46F590(0)
	_turn_start()
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
	if w == null or ((ai_running or move_thread != null) and react_panel == null):
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
