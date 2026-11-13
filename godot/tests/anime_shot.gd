extends SceneTree
## The animations' frames over a battle's map, saved as a picture (not a test):
##   godot --path engine/godot -s tests/anime_shot.gd -- dash 1 out.png [frame]
## Around the first DoLL: a kind 0 hit (0x4200D0, the sprite of the shooter's direction),
## a kind 1 miss (0x4209D0), a kind 8 hit (0x419BE0), a kill (0x420CD0) and anime_bomb
## (0x417410), each at frame `frame` (default 3), on hexes next to each other.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	await process_frame
	var b = load("res://ui/battle.tscn").instantiate()
	b.campaign = args[0]
	b.mission_index = int(args[1])
	b.sortie_window = false
	root.add_child(b)
	for i in 5:
		await process_frame
	var fr := int(args[3]) if args.size() > 3 else 3
	var u: int = b.squad[0]
	var p: Vector2i = b.w.pos(u)
	var plays := [[0x4200D0, 0, 2, 0], [0x4209D0, 1, 4, 0], [0x419BE0, 8, 6, 0], [0x420CD0, 0, 0, 2], [0x417410, 0, 3, 2]]
	for pl in plays:
		var v = load("res://ui/anime_view.gd").new()
		v.battle = b
		v.load_pack(b.campaign)
		b.add_child(v)
		var x: int = p.x + pl[2] - 3
		var y: int = p.y + pl[3]
		v.show_frame(pl[0], [pl[1], p.x - 3, p.y - 3], x, y, fr if pl[0] != 0x4200D0 else 0, 0, 0)
	b.cam.position = b.hex_center(p + Vector2i(0, 1))
	b.cam.zoom = Vector2(1.6, 1.6)
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_viewport().get_texture().get_image().save_png(args[2])
	quit(0)
