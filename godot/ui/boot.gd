extends Control
## The title (game_mode_loop 0x487D70, core/title.gd), drawn by ui/title_view.gd: once a run
## the CD-DA / MIDI list and the logos, then pd2title.pac and its regions (DS:0x50D878): 0 the
## list DS:0x50D86C (start the campaign after the question 0x518A08, the scenario select,
## the rescue mission), 1 the continue, 2 the exit, 3 the opening, 4 the version. The starts
## run 0x46D780 (Title.title_start) on a worker thread, its windows answered here, then the
## mission start with savedata.tmp (the battle scene with Battle.carry). F2 shows the engine's
## own list of every mission chunk (each from its campaign's SAVEDATA.ORG as it is).

const BATTLE := "res://ui/battle.tscn"

var box: VBoxContainer
var dialog: PanelContainer = null
var sem := Semaphore.new()
var answer: Variant = null
var worker: Thread = null
var busy := false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	if not GameData.available():
		box = VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 24
		box.offset_top = 16
		add_child(box)
		var msg := Label.new()
		msg.autowrap_mode = TextServer.AUTOWRAP_WORD
		msg.text = ("No game data found in %s.\n\nRun the importer on your own copy of "
			+ "POWER DoLLS 2 plus DASH:\n    python -X utf8 engine/importer/pd2_import.py <CD image or game folder>") % ProjectSettings.globalize_path(GameData.ROOT)
		box.add_child(msg)
		return
	title = TitleView.new()
	title.fast = DisplayServer.get_name() == "headless"
	add_child(title)
	_fit()
	get_viewport().size_changed.connect(_fit)
	_sandbox_panel()
	_sequence()


var title: TitleView = null


func _fit() -> void:
	## the 640 x 400 screen scaled into the window (as the battle's main window)
	if title == null:
		return
	var vs := get_viewport().get_visible_rect().size
	var sc := minf(vs.x / TitleView.W, vs.y / TitleView.H)
	title.scale = Vector2(sc, sc)
	title.position = ((vs - Vector2(TitleView.W, TitleView.H) * sc) / 2).floor()


func _sandbox_panel() -> void:
	## the engine's own list of every mission chunk (each from its campaign's SAVEDATA.ORG as
	## it is), behind F2 (not the game's)
	var panel := ColorRect.new()
	panel.color = Color(0.06, 0.07, 0.09, 0.95)
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.visible = false
	add_child(panel)
	box = VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 24
	box.offset_top = 16
	box.offset_right = -24
	box.offset_bottom = -16
	box.visible = false
	add_child(box)
	box.visibility_changed.connect(func(): panel.visible = box.visible)
	var ver := Label.new()
	ver.text = "Data: %s" % GameData.manifest.get("version", "?")
	box.add_child(ver)
	var note := Label.new()
	note.text = ui("UI_TITLE_SANDBOX")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(note)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	scroll.add_child(grid)
	for camp in ["pd2", "dash"]:
		for m in GameData.mission_count(camp):
			var b := Button.new()
			b.text = "%s  mission chunk %d" % [camp.to_upper(), m]
			b.pressed.connect(_start.bind(camp, m))
			grid.add_child(b)


func _unhandled_key_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and ev.keycode == KEY_F2 and box != null and title != null:
		box.visible = not box.visible


func _sequence() -> void:
	## game_mode_loop (0x487D70) up to its title loop: once a run the CD-DA / MIDI list (with
	## the CD there: blk.pac, DS:0x50D6A1's colours, else MIDI) and the logos; then the title.
	## (userdisk.id's check is the import's: GameData.available.)
	busy = true
	if not TitleView.logos_done:
		title.clear()
		if not GameAudio.mode_asked:
			GameAudio.mode_asked = true
			GameAudio.mode = 1
			if GameAudio.cd_present():
				if title.fast:
					GameAudio.mode = 0
				else:
					title.win_palette(0x50D6A1, title.level)
					title.pac("blk", 0, 0, 0)
					await title.fade(100)
					var c: Array = GameAudio.choices()
					var pick: int = await list_window(0x120, 0xD8, 10, c, false)
					GameAudio.mode = 0 if pick == 0 else 1
		await title.logos()
	await _show_title()


func _show_title() -> void:
	## the title loop's redraw: the first time pd2title.pac fades in from the logos' white and
	## title2.wav plays to its end (0x40D440(0, 2)); later it is drawn and shown at once
	## (0x487A20(100)); then music_start(5) and the menu
	busy = true
	title.win_palette(0x50D82C, title.level)
	title.pac("pd2title", 0, 0, 0)
	if not GameAudio.title_shown:
		await title.fade(100)
		GameAudio.title_shown = true
		var secs := GameAudio.wave("title2", true)
		if secs > 0.0 and not title.fast:
			await get_tree().create_timer(secs).timeout
	else:
		title.pal_a20(100)
	GameAudio.music_start(5)
	_menu()


func _menu() -> void:
	## the title's regions (0x438210(5, DS:0x50D878), 0x437AC0) and game_mode_loop's switch
	busy = false
	title.menu_start()
	var i: int = await title.region_picked
	busy = true
	match i:
		0:
			var pick: int = await list_window(0x120, 0xD8, 20, SaveFiles.choice_texts(0x50D86C), true)
			if pick == 0:
				if await question(SaveFiles.exe(0x518A08), 0):
					_run("0")
				else:
					_menu()
			elif pick == 1:
				_run("2")
			elif pick == 2:
				_run("3")
			else:
				_menu()
		1:
			_run("1")
		2:
			if await question(SaveFiles.exe(0x518A20), 1):
				GameAudio.music_stop()            # 0x40AF80, then userinf.dat and WM_CLOSE
				get_tree().quit()
			else:
				_menu()
		3:
			await title.opening()                 # 0x4783A0 (its result is not looked at)
			await _show_title()
		_:
			await version_box()
			_menu()


# --- the game's windows over the title ------------------------------------------------------

const BOX_LABELS := [[0x510444, 0x51044C], [0x510454, 0x51045C]]


func _window_hold(gw: GameWindow) -> Control:
	var hold := Control.new()
	hold.size = Vector2(TitleView.W, TitleView.H)
	hold.mouse_filter = Control.MOUSE_FILTER_STOP
	hold.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			gw.outside(ev.button_index))
	title.holder.add_child(hold)
	return hold


func list_window(x: int, y: int, cols: int, labels: Array, cancel: bool) -> int:
	## 0x452A10(NULL, n, list, x, y, cols, .., right click allowed): the pick; -2 on a right
	## click when allowed
	var gw := GameWindow.select_window(x, y, cols, 0, 1, labels, cols, [], cancel)
	gw.pal16 = title.pal16()
	gw.role = "title_list"
	var hold := _window_hold(gw)
	hold.add_child(gw)
	var v: int = await gw.chosen
	hold.queue_free()
	return v


func question(text: String, kind: int) -> bool:
	## 0x451E30(text, kind): the text's line at y 0xAA, its two answers (了解 / 中止 or 実行 /
	## 中止) under its right end; true for the first
	var t := text.replace("@", "").strip_edges()
	var n := GameWindow.text_cols(t)
	var x := ((80 - (n + 2)) / 2) * 8
	var mw := GameWindow.text_window(x, 0xAA, n, 1, 1)
	mw.pal16 = title.pal16()
	mw.waits = false
	var l: Array = BOX_LABELS[kind]
	var labels := [GameData.exe_text("pd2", l[0]), GameData.exe_text("pd2", l[1])]
	var ic := 4
	for s in labels:
		ic = maxi(ic, GameWindow.text_cols(str(s)))
	var right := (((80 - (n + 2)) / 2) + n + 2) * 8
	var bw := GameWindow.select_window(right - 16 - ic * 8, 0xAA + 0x20, 0, 0, 0, labels, ic, [], true)
	bw.pal16 = mw.pal16
	bw.role = "title_question"
	var hold := _window_hold(bw)
	hold.add_child(mw)
	hold.add_child(bw)
	mw.print_text(t)
	var v: int = await bw.chosen
	hold.queue_free()
	return v == 0


func version_box() -> void:
	## the title's region 4 (the pixel (639, 0)): 0x452200(DS:0x5188E0, flag 0), a framed line
	## of 54 columns at (96, 0xAA) whose line end waits for a click
	var t := SaveFiles.exe(0x5188E0)
	var n := maxi(54, GameWindow.text_cols(t))
	var tw := GameWindow.text_window(((80 - (n + 2)) / 2) * 8, 0xAA, n, 1, 1)
	tw.pal16 = title.pal16()
	tw.role = "title_version"
	tw.waits = not title.fast
	var hold := _window_hold(tw)
	hold.add_child(tw)
	await tw.print_text(t + "\n")
	hold.queue_free()


func _ask_async(text: String, opts: Array) -> Variant:
	var box_done := [false, null]
	_show(text, opts, func(i):
		box_done[0] = true
		box_done[1] = i)
	while not box_done[0]:
		await get_tree().process_frame
	return box_done[1]


func ui(key: String) -> String:
	return GameData.ui_text(key)


# --- the title's windows, asked from the worker thread -----------------------------------

func _show(text: String, opts: Array, done: Callable) -> void:
	if dialog:
		dialog.queue_free()
	dialog = PanelContainer.new()
	dialog.position = Vector2(160, 90)
	add_child(dialog)
	var v := VBoxContainer.new()
	dialog.add_child(v)
	if text != "":
		var l := Label.new()
		l.text = text
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		l.custom_minimum_size = Vector2(420, 0)
		v.add_child(l)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, mini(28 * opts.size(), 420))
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	for o in opts:
		var b := Button.new()
		b.text = o[0]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(func():
			dialog.queue_free()
			dialog = null
			done.call(o[1]))
		list.add_child(b)


func ask(text: String, opts: Array) -> Variant:
	## on the worker thread: the window on the main thread, then its answer
	call_deferred("_show", text, opts, func(a):
		answer = a
		sem.post())
	sem.wait()
	return answer


func note_text(text: Variant) -> String:
	## a title note: an exe address, a MES0.SLD id (below 0x100) or [address, n]
	if text is Array:
		return SaveFiles.exe(text[0], [text[1]])
	if int(text) < 0x100:
		return GameData.title_note(int(text))
	return SaveFiles.exe(int(text))


class BootTitleHooks extends Title.Hooks:
	var boot

	func box(text: Variant) -> int:
		boot.ask(boot.note_text(text), [[boot.ui("UI_OK"), 0]])
		return 0

	func pick(kind: String, items: Array) -> int:
		var opts := []
		if kind == "scenario":
			for i in items.size():
				opts.append([SaveFiles.mission_name(items[i]), i])
		else:
			var t: Array = SaveFiles.choice_texts(0x5173A0)
			for i in t.size():
				opts.append([t[i], i])
		opts.append([boot.ui("UI_CANCEL"), -2])
		return int(boot.ask("", opts))

	func savedata_org(flag: int) -> Variant:
		var img: Array = GameData.save_image("pd2" if flag else "dash")
		if img.size() != 2:
			return null
		var out := Title.magic()
		out.append_array(img[1])
		return out

	func saves() -> int:
		var n := 0
		for s in Title.SLOTS:
			var d: Variant = save_file(s)
			if d != null and (d as PackedByteArray).slice(0, 8) == Title.magic():
				n += 1
		return n

	func slot() -> int:
		return boot.ask_slot(false)

	func confirm(s: int) -> int:
		return int(boot.ask(SaveFiles.slot_line(s, 0x519EE8), [[boot.ui("UI_YES"), 1], [boot.ui("UI_NO"), 0]]))

	func save_file(s: int) -> Variant:
		return SaveFiles.read("PD2REC%02d.BIN" % s)

	func member_file(s: int) -> Variant:
		return SaveFiles.read("MEMBER%02d.DAT" % s)

	func write_tmp(data: PackedByteArray) -> void:
		SaveFiles.write("savedata.tmp", data)


func ask_slot(saving: bool) -> int:
	## 0x498290 / 0x497A10: the 41 slots; 0x29 none
	var opts := []
	for s in Title.SLOTS:
		if saving or SaveFiles.read("PD2REC%02d.BIN" % s) != null:
			opts.append([SaveFiles.slot_line(s, 0x519ED8 if saving else 0x519EE8), s])
	opts.append([ui("UI_CANCEL"), 0x29])
	return int(ask("", opts))


func _run(entry: String) -> void:
	## 0x46D780 on the worker thread, over a world of the exe's data
	if worker != null:
		return
	busy = true
	var w := SaveFiles.title_world()
	w.play_safe = true          # in play: RULES.md 5.23's logged safe paths
	var hk := BootTitleHooks.new()
	hk.boot = self
	worker = Thread.new()
	worker.start(func():
		var res := Title.title_start(w, entry, hk)
		call_deferred("_title_done", entry, res, w))


func _title_done(entry: String, res: Array, w: Pd2World) -> void:
	## game_mode_loop after 0x46D780: below 1 the title again; bit 0x80 a battle's save
	## (0x436530 at once: the battle resumes, Title.mission_resume); bit 0x40 a single mission; the new campaign
	## (0x421B90) for button 0's entries returning 1 but the single mission; past 20 the
	## title; else the mission start with savedata.tmp
	worker.wait_to_finish()
	worker = null
	busy = false
	Title.saved_list = w.title_list
	var ret: int = res[0]
	if res[1] or w.fault != "":
		_show(ui("UI_TITLE_FAULT") % (w.fault if w.fault != "" else "0x%X" % res[1]), [[ui("UI_OK"), 0]], func(_a): _menu())
		return
	if ret < 1:
		_menu()                               # the title again, not redrawn (game_mode_loop)
		return
	var resume := ret & 0x80 != 0
	ret &= 0x7F
	var single := ret & 0x40 != 0
	ret &= 0x3F
	var new_campaign := ret == 1 and entry != "1" and not single
	if ret > 20:
		_menu()
		return
	var scene: PackedScene = load(BATTLE)
	var battle := scene.instantiate()
	battle.campaign = "pd2" if w.campaign else "dash"
	battle.mission_index = Debrief.chunk(w) - 1
	battle.title_carry = {"image": Debrief.save_image(w), "script": w.script_no, "stash": w.stash,
		"new_campaign": new_campaign and not resume, "resume": resume}
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	queue_free()


func _start(camp: String, m: int) -> void:
	if busy:
		return
	var scene: PackedScene = load(BATTLE)
	var battle := scene.instantiate()
	battle.campaign = camp
	battle.mission_index = m
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	queue_free()
