extends Control
## The title (game_mode_loop 0x487D70's title menu, core/title.gd): button 0 opens the list
## DS:0x50D86C (start the campaign, after the question 0x518A08; the scenario select; the
## rescue mission), button 1 the continue; each runs 0x46D780 (Title.title_start) on a
## worker thread, its windows answered here, then the mission start with savedata.tmp
## (the battle scene with Battle.carry). Below, the sandbox's list of every mission chunk
## (each from its campaign's SAVEDATA.ORG as it is).

const BATTLE := "res://ui/battle.tscn"

var box: VBoxContainer
var dialog: PanelContainer = null
var sem := Semaphore.new()
var answer: Variant = null
var worker: Thread = null
var busy := false


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	box = VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 24
	box.offset_top = 16
	box.offset_right = -24
	box.offset_bottom = -16
	add_child(box)
	var title := Label.new()
	title.text = "POWER DoLLS 2 plus DASH"
	title.add_theme_font_size_override("font_size", 20)
	box.add_child(title)
	if not GameData.available():
		var msg := Label.new()
		msg.autowrap_mode = TextServer.AUTOWRAP_WORD
		msg.text = ("No game data found in %s.\n\nRun the importer on your own copy of "
			+ "POWER DoLLS 2 plus DASH:\n    python -X utf8 engine/importer/pd2_import.py <CD image or game folder>") % ProjectSettings.globalize_path(GameData.ROOT)
		box.add_child(msg)
		return
	var ver := Label.new()
	ver.text = "Data: %s" % GameData.manifest.get("version", "?")
	box.add_child(ver)
	var menu := HBoxContainer.new()
	box.add_child(menu)
	var start := Button.new()
	start.text = ui("UI_TITLE_START")
	start.pressed.connect(_button0)
	menu.add_child(start)
	var cont := Button.new()
	cont.text = ui("UI_TITLE_CONTINUE")
	cont.pressed.connect(_run.bind("1"))
	menu.add_child(cont)
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


func ui(key: String) -> String:
	return GameData.ui_text(key)


func _button0() -> void:
	## button 0's list (DS:0x50D86C); the campaign's start asks 0x518A08 first (0x451E30)
	if busy:
		return
	var items := SaveFiles.choice_texts(0x50D86C)
	var opts := []
	for i in items.size():
		opts.append([items[i], i])
	opts.append([ui("UI_CANCEL"), -2])
	_show("", opts, func(i):
		if i == 0:
			_show(SaveFiles.exe(0x518A08), [[ui("UI_YES"), 1], [ui("UI_NO"), 0]], func(yes):
				if yes == 1:
					_run("0"))
		elif i == 1:
			_run("2")
		elif i == 2:
			_run("3"))


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
	if busy:
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
		_show(ui("UI_TITLE_FAULT") % (w.fault if w.fault != "" else "0x%X" % res[1]), [[ui("UI_OK"), 0]], func(_a): pass)
		return
	if ret < 1:
		return
	var resume := ret & 0x80 != 0
	ret &= 0x7F
	var single := ret & 0x40 != 0
	ret &= 0x3F
	var new_campaign := ret == 1 and entry != "1" and not single
	if ret > 20:
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
