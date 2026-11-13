class_name SortieView
extends GameWindow
## The sortie screen (0x45ED60) as Pd2.exe draws it in its 640 x 400 window (DS:0x554FAC,
## the palette DS:0x50D6A1 by 0x487120) --
## - three pages (DS:0x50D741, 1 when the screen opens): every region's x and the centre's
##   windows move by -0xD8 a page; hensei_g.pac (208 x 400) at x (2 - page) x 0xD8;
## - the side windows (unframed, 16 px, printed "\x0c": their patterns): page 1 (0, 0)
##   27 x 25 DS:0x50D731 and (0x1A8, 0) 27 x 25 DS:0x50D739; page 0 (0, 0) 54 x 25
##   DS:0x50D731; page 2 (0xD0, 0) 54 x 25 DS:0x50D739;
## - the cards 0x4649C0: the free pilots (0x4645A0, DS:0x50AD02) at (8, 4 + 0x62 k) on page
##   1, k 0-7 at x 0xE0 (k < 4) / 8 on page 0; the group's members (0x464140) at (0x1A8, 4 +
##   0x62 k) on page 1, x 0xD0 (k < 4) / 0x1A8 on page 2. A card: the face (face.pac by
##   crew +1, 96 x 96) at (x, y), a text window (x + 0x60, y) 14 x 12 of 8 px: "%aC9" (air,
##   crew +3 = 1) / "%aCB", MES 0x1D1 (the machine's code DS:0x50C2E5, the slots 0-3'
##   launcher codes DS:0x50BF65), ground "%5s%5s%4s%5s%5s%4s" (the pockets' rounds' codes
##   DS:0x50C665) / air "%14s%14s" (slots 4, 5), "%a59" / "%a5B", MES 0x1D0 (the names
##   "given family", crew +9, +0xA, +0xC, +0xB, +0xD, SCOUT / COVER / COM / ENG for crew +8
##   bits 0, 3, 2, 1); no pilot: the face's square filled with colour 0 and MES 0x1D2 with
##   " No Character ";
## - the centre (0x463790): the group's name DS:0x50C881 and call sign DS:0x50C7E5 at
##   (0x1F0, 0x18 / 0x26) 16 x 1 of 12 px (DS:0x50D719, solid 0xC0); its requirements at
##   (0x1C0, 0x36) 22 x 3 of 16 px (DS:0x50D721, solid 0xC0: "%c%a0D", then MES 0x31 + 9 t
##   + 3 j); the formable groups' call signs "%a0F%12s" at (0x1D8, y) 12 x 1 of 8 px
##   (DS:0x50D729, solid 0x8F), y from 0xA2 by 0xC, 0x1C after each third pair below 12;
##   their counts (0x463D80) "%b%2d" at (0x240, y) and (600, y);
## - the scroll thumbs (0x453560) of both lists;
## - the 79 regions DS:0x515FC8 (0x438210), answered as the screen's loop answers them.
## Solid colours: the record's +0x65 + 10 (0x4F0A10) in the pictures' table.

signal pressed(r: int, at: Vector2)

const W := 640
const H := 400

var battle: Node
var page := 1
var pool_first := 0        # the free pilots' first shown (the loop's local)
var member_first := 0      # the group's members' first shown
var regions_doc: Array = []
var _pal: Array = []
var _last := Vector2.ZERO


static func make(b: Node, regs: Array) -> SortieView:
	var v := SortieView.new()
	v.battle = b
	v.regions_doc = regs
	v.cols = W / 8
	v.rows = H / 16
	v.lh = 16
	v.framed = false
	v.black = true
	v.waits = false
	return v


func palette16() -> Array:
	## 0x487120 from DS:0x50D6A1: B, G, R and a pad each (the drawing codes 0-15)
	if _pal.is_empty():
		for k in 16:
			var a := 0x50D6A1 + 4 * k
			_pal.append(Color8(battle.w.mem8(a + 2), battle.w.mem8(a + 1), battle.w.mem8(a)))
	return _pal


static func fmt(t: String, args: Array) -> String:
	## format_text with the colour codes kept for the printer: %aHH -> 0x01 HH, %b -> 0x01
	## and its argument
	var out := ""
	var i := 0
	while i < t.length():
		if t[i] == "%" and i + 1 < t.length():
			if t[i + 1] == "a" and i + 3 < t.length():
				out += "\u0001" + char(("0x" + t.substr(i + 2, 2)).hex_to_int())
				i += 4
				continue
			if t[i + 1] == "b":
				out += "\u0001%c"
				i += 2
				continue
		out += t[i]
		i += 1
	return GameData.format_text(out, args)


func _win(x: int, y: int, c: int, r: int, h: int, flags: int, pat: String, solid: int) -> GameWindow:
	## ui_window_create(0, .., x, y, c, r, h, flags, pattern) unframed in this window
	var gw := GameWindow.new()
	gw.cols = c
	gw.rows = r
	gw.lh = h
	gw.framed = false
	gw.code = ((flags & 3) << 2) | 0x71
	gw.waits = false
	gw.pal16 = palette16()
	if pat != "":
		gw.pattern = GameWindow.ui_data().get("patterns", {}).get(pat, [])
	else:
		gw.black = true
	gw.solid_raw = solid + 10 if solid >= 0 else 0
	gw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gw.position = Vector2((x >> 3) << 3, y)
	gw._layout()
	add_child(gw)
	return gw


func refresh() -> void:
	for c in get_children():
		c.queue_free()
	pal16 = palette16()
	_layout()
	var w: Pd2World = battle.w
	var root: String = GameData.ROOT
	blit(root + "/images/hensei_g/00.bmp", (2 - page) * 0xD8, 0)
	# the side windows, cleared with their patterns (drawn here: the cards' faces go over them)
	match page:
		0:
			_side(0, 0x36, "50D731")
		1:
			_side(0, 0x1B, "50D731")
			_side(0x1A8, 0x1B, "50D739")
		2:
			_side(0xD0, 0x36, "50D739")
	# the free pilots' cards (0x4645A0)
	var n: int = w.crew_pool_n
	if page == 0:
		for k in 8:
			_card(0xE0 - (k >> 2) * 0xD8, 4 + 0x62 * (k & 3), w.ds[2 + pool_first + k] if pool_first + k < n else -1)
	elif page == 1:
		for k in 4:
			_card(8, 4 + 0x62 * k, w.ds[2 + pool_first + k] if pool_first + k < n else -1)
	# the members' (0x464140)
	var g: int = battle.sortie_sel
	var units := Flight.gb(w, g, 5)
	if page == 1:
		for k in 4:
			_card(0x1A8, 4 + 0x62 * k, Flight.gb(w, g, 6 + member_first + k) if member_first + k < units else -1)
	elif page == 2:
		for k in 8:
			_card(0xD0 + (k >> 2) * 0xD8, 4 + 0x62 * (k & 3), Flight.gb(w, g, 6 + member_first + k) if member_first + k < units else -1)
	# the thumbs (0x4645A0 / 0x464140's ends)
	var dx := -page * 0xD8
	if page == 2:
		_thumb(2, 0xB4, 0xD, 0x15B, 4, 0, 3)
	elif n < (4 if page != 0 else 8) + pool_first:
		_thumb(0x1B2 + dx, 0xB4, 0x1BD + dx, 0x15B, n, pool_first, n - 1)
	else:
		_thumb(0x1B2 + dx, 0xB4, 0x1BD + dx, 0x15B, n, pool_first, pool_first - page * 4 + 7)
	if page == 0:
		_thumb(0x272, 0xB4, 0x27D, 0x15B, 4, 0, 3)
	elif units < (4 if page != 2 else 8) + member_first:
		_thumb(0x272 + dx, 0xB4, 0x27D + dx, 0x15B, units, member_first, units - 1)
	else:
		_thumb(0x272 + dx, 0xB4, 0x27D + dx, 0x15B, units, member_first, member_first - 1 + page * 4)
	_centre(g, dx)
	var regs := []
	for r in regions_doc:
		regs.append([int(r[0]) + dx, int(r[1]), int(r[2]) + dx, int(r[3]), int(r[4])])
	regions = regs
	_all_regions = regs
	queue_redraw()


func _side(x: int, c: int, pat: String) -> void:
	## ui_window_create(0, x, 0, c x 25 of 16 px, the pattern) printed "\x0c"
	var keep := pattern
	pattern = GameWindow.ui_data().get("patterns", {}).get(pat, [])
	_back(x, 0, c * 8, 0x19 * 0x10)
	pattern = keep


func _card(x: int, y: int, c: int) -> void:
	## 0x4649C0
	var w: Pd2World = battle.w
	var tw := _win(x + 0x60, y, 0xE, 0xC, 8, 2, "", -1)
	if c < 0 or c > 0xFF:
		_rect(x, y, x + 0x5F, y + 0x5F, 0, 0, 2)
		tw.print_text(fmt(GameData.base_raw(battle.campaign, 0x1D2, battle.mission_index), [" No Character "]))
		return
	var face := Flight.s8(w.cb(c, 1))
	blit("%s/images/face/%02d.bmp" % [GameData.ROOT, face], x, y)
	var t: Dictionary = GameData.tables(battle.campaign)
	var air := w.cb(c, 3) == 1
	var codes: Array = t.get("machine_codes", [])
	var lc: Dictionary = t.get("launcher_codes", {})
	var ac: Array = t.get("ammo_codes", [])
	var m := Flight.s8(w.ub(c, 0xC))
	var s := "\u0001" + char(0xC9 if air else 0xCB)
	var la := func(off: int) -> String:
		var v := Flight.s8(w.ub(c, off))
		return str(lc.get(str(v), "")) if v != -1 else ""
	var aa := func(off: int) -> String:
		var v := Flight.s8(w.ub(c, off))
		return str(ac[v]) if v >= 0 and v < ac.size() else ""
	s += fmt(GameData.base_raw(battle.campaign, 0x1D1, battle.mission_index),
		[str(codes[m]) if m >= 0 and m < codes.size() else "", la.call(0xF), la.call(0x11), la.call(0x13), la.call(0x15)])
	if not air:
		s += GameData.format_text("%5s%5s%4s%5s%5s%4s", [aa.call(0x1B), aa.call(0x1D), aa.call(0x1F), aa.call(0x21), aa.call(0x23), aa.call(0x25)])
	else:
		s += GameData.format_text("%14s%14s", [la.call(0x17), la.call(0x19)])
	s += "\u0001" + char(0x59 if air else 0x5B)
	var nm: Array = battle.names.crew[w.cb(c, 0)] if w.cb(c, 0) < battle.names.crew.size() else ["", ""]
	var sk := w.cb(c, 8)
	s += fmt(GameData.base_raw(battle.campaign, 0x1D0, battle.mission_index),
		[str(nm[0]) + " " + str(nm[1] if nm.size() > 1 else ""), Flight.s8(w.cb(c, 9)), Flight.s8(w.cb(c, 0xA)),
		Flight.s8(w.cb(c, 0xC)), Flight.s8(w.cb(c, 0xB)), Flight.s8(w.cb(c, 0xD)),
		"SCOUT" if sk & 1 else "", "COVER" if sk & 8 else "", "COM" if sk & 4 else "", "ENG" if sk & 2 else ""])
	tw.print_text(s)


func _group_on(g: int) -> bool:
	## +2 bit 0 (past the 20 groups the table's memory runs on, as the game reads it)
	var w: Pd2World = battle.w
	return (Flight.gb(w, g, 2) if g < 20 else w.mem8(0x50A35C + 0x23 * g + 2)) & 1 != 0


func _centre(g: int, dx: int) -> void:
	## 0x463790(1)
	var w: Pd2World = battle.w
	var camp: String = battle.campaign
	for e in [[0x18, GameData.call_sign(camp, 39 + Flight.gb(w, g, 0))], [0x26, GameData.call_sign(camp, Flight.gb(w, g, 1))]]:
		# (engine-side: a longer translation widens the window over the picture)
		var c := maxi(0x10, GameWindow.text_cols(e[1])) if GameWindow.translated(e[1]) else 0x10
		_win(0x1F0 + dx, e[0], c, 1, 0xC, 1, "50D719", 0xC0).print_text(e[1])
	var rq := _win(0x1C0 + dx, 0x36, 0x16, 3, 0x10, 1, "50D721", 0xC0)
	var reqs := Plan.requirements(w, g)
	var rt := "\u000c\u0001" + char(0x0D)
	for i in reqs.size():
		var tx := GameData.base_raw(camp, reqs[i], battle.mission_index)
		if GameWindow.translated(tx):
			tx = GameWindow.fit(tx, 0x16)
		rt += fmt(tx, []) + ("\n" if i < 2 and i < reqs.size() - 1 else "")
	rq.print_text(rt)
	var y := 0xA2
	for k in 64:
		if k >= 12 or k % 2 == 0:
			if _group_on(k):
				_win(0x1D8 + dx, y, 0xC, 1, 8, 2, "50D729", 0x8F).print_text(fmt("%a0F%12s", [GameData.call_sign(camp, Flight.gb(w, k, 1)) if k < 20 else ""]))
				if k < 20:
					_counts(k, dx)
			y += 0x1C if k < 12 and (k / 2) % 3 == 2 else 0xC


func _counts(g: int, dx: int) -> void:
	## 0x463D80
	var w: Pd2World = battle.w
	var y := 0
	var c1 := 0xFF
	var c2 := 0xFF
	var v1 := 0
	var v2 := 2
	var gg := g
	if g < 12:
		gg = (g / 2) * 2
		y = 0xA2 + 0xC * (gg / 2) if g < 6 else 0xD6 + 0xC * ((gg - 6) / 2)
		v2 = 0
		var last := 0
		for i in Flight.gb(w, gg, 5):
			var k := Flight.gb(w, gg, 6 + i)
			var mm := Flight.s8(w.ub(k, 0xC))
			if w.cb(k, 3) == 0:
				v1 += w.machine(mm, 0xA)
			elif w.cb(k, 3) == 1:
				last = w.machine(mm, 9)
				v2 += last
		if v1 == 0:
			c2 = 0x4F if v2 != 0 else 0xFF
		elif v2 < v1:
			c1 = 0x4F if Flight.gb(w, gg, 3) & 1 else 0xFF
		elif v2 == 0:
			c2 = 0x4F
		elif v1 < v2:
			c2 = 0xFF if v2 - v1 < last else 0x4F
	else:
		y = 0x7A + 0xC * g
		v1 = Flight.gb(w, g, 5)
	_win(0x240 + dx, y, 2, 1, 8, 2, "", -1).print_text(fmt("%b%2d", [c1, v1]))
	var second := _win(600 + dx, y, 2, 1, 8, 2, "", -1)
	if gg < 12 and Flight.gb(w, gg, 3) & 1 == 0:
		second.print_text("\u000c")
	else:
		second.print_text(fmt("%b%2d", [c2, v2]))


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		_last = ev.position
	super(ev)


func _ready() -> void:
	chosen.connect(func(r: int):
		if r >= 0:
			pressed.emit(r, _last))
