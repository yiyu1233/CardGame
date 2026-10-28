extends SceneTree
## 指向箭头截图：选中一张指定法术后把箭头画面截下来（需要窗口运行）。
## 运行：godot --path <项目目录> --script res://tools/arrow_screenshot.gd

var _f := 0
var _main
var _gm
var _db


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 8:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _f == 20:
		# 手里放一张能指定任意角色的法术，并进入选目标状态
		var pick: CardData = null
		for c in _db.cards:
			if c.card_type == CardData.CardType.SPELL and c.needs_target():
				for t in _gm.get_valid_targets(0, c):
					if int(t["unit_id"]) < 0 and int(t["player_id"]) == 1:
						pick = c
						break
			if pick != null:
				break
		var me: PlayerState = _gm.get_player(0)
		me.mana = 10
		me.max_mana = 10
		me.hand.clear()
		me.hand.append(pick)
		me.hand.append(_db.get_card("c011"))      # 随从卡：展示法力水晶 + 攻击/生命宝石
		me.hand.append(_db.get_card("f006"))      # 复生随从：展示关键字行
		_main._refresh()
		_main._enter_card_target(0)
		# 鼠标压在敌方英雄上 → 箭头锁定
		_main._last_mouse = Vector2(80, 80)          # 先指到空处：应为不可用（红）
		_main._update_target_arrow()
		print("[shot] 空处 available=", _main.target_arrow().available)
		var hero: Rect2 = _main.enemy_hero_frame.get_global_rect()
		_main._last_mouse = hero.get_center()
		_main._update_target_arrow()
		print("[shot] locked=", _main.target_arrow().locked, " kind=", _main.target_arrow().kind,
			" bow=", "%.1f" % _main.target_arrow().bow())
		return false