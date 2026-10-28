extends SceneTree
## 美术总览截图：场景图片 + 卡面宝石 + 卡图 + 伤害/治疗飘字 + 牌堆摆布。
## 运行：godot --path <项目目录> --script res://tools/art_showcase_shot.gd

var _f := 0
var _gm
var _main


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 6:
		_gm = root.get_node_or_null("GameManager")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _f == 12:
		# 造一张渐变场景图 + 一张卡图
		var bg := Image.create(360, 220, false, Image.FORMAT_RGBA8)
		for y in 220:
			for x in 360:
				var k := float(x) / 360.0
				bg.set_pixel(x, y, Color(0.05 + 0.12 * k, 0.08 + 0.16 * k, 0.15 + 0.24 * k))
		bg.save_png("user://showcase_bg.png")
		var art := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		for y in 64:
			for x in 64:
				art.set_pixel(x, y, Color(0.90, 0.50 + 0.35 * float(y) / 64.0, 0.22))
		art.save_png("user://showcase_card_art.png")
		ArtStore.use_save_path("user://showcase_art.cfg")
		ArtStore.set_background_path("user://showcase_bg.png")
		_main._apply_background()
		# 给手牌里的随从配上卡图
		var me: PlayerState = _gm.get_player(0)
		for c in me.hand:
			if c.is_minion():
				c.art_path = "user://showcase_card_art.png"
		_main._refresh()
		return false
	if _f == 16:
		# 飘字：敌方英雄受伤 7、我方英雄治疗 4
		_gm.amount_shown.emit(1, -1, 7, "damage")
		_gm.amount_shown.emit(0, -1, 4, "heal")
		return false
	if _f == 20:
		var img: Image = root.get_texture().get_image()
		img.save_png("user://shot_15_art_showcase.png")
		print("[shot] shot_15_art_showcase ", img.get_size())
		ArtStore.use_save_path("user://art.cfg")
		quit(0)
		return true
	return _f > 300
