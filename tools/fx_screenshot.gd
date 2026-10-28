extends SceneTree
## 表现层截图探针：出牌飞牌 / 随从死亡消失 / 召唤登场（**需要窗口**）。
## 用法：godot --path <项目目录> --script res://tools/fx_screenshot.gd
## 产出：user://fx_1_play.png / fx_2_death.png / fx_3_summon.png

var _frames := 0
var _main
var _gm
var _shots: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _frames == 6:
		# 造一个战场：敌方一个随从、我方一个随从
		var foe_card: CardData = _gm.card_by_id("c001") if _gm.has_method("card_by_id") else null
		var my_card: CardData = null
		var db = root.get_node_or_null("CardDB")
		for c in db.cards:
			if c.is_minion() and c.cost <= 4:
				if my_card == null:
					my_card = c
				elif foe_card == null:
					foe_card = c
		if my_card != null:
			_gm.summon_unit(0, my_card)
		if foe_card != null:
			_gm.summon_unit(1, foe_card)
		return false
	if _frames == 10:
		var fx = _main.battle_fx()
		# ① 出牌飞牌（手牌 → 战场）
		var db = root.get_node_or_null("CardDB")
		var card: CardData = db.cards[0]
		fx.play_card(Vector2(700, 700), Vector2(400, 430), card)
		return false
	if _frames == 14:
		_shot("fx_1_play.png")
		return false
	if _frames == 16:
		# ② 死亡消失
		var fx = _main.battle_fx()
		var db = root.get_node_or_null("CardDB")
		fx.death(Vector2(400, 430), Vector2(104, 132), db.cards[0])
		return false
	if _frames == 20:
		_shot("fx_2_death.png")
		return false
	if _frames == 22:
		# ③ 召唤登场
		var fx = _main.battle_fx()
		fx.summon(Vector2(560, 430), Vector2(104, 132))
		return false
	if _frames == 26:
		_shot("fx_3_summon.png")
		_main.queue_free()
		return false
	if _frames >= 34:
		print("=== 表现层截图完成：%s ===" % str(_shots))
		quit(0)
		return true
	return _frames > 400


func _shot(name_: String) -> void:
	var img := root.get_texture().get_image()
	img.save_png("user://" + name_)
	_shots.append(name_)
	print("[fx] " + name_)
