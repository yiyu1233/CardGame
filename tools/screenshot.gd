extends SceneTree
## 界面截图工具：把**真实渲染**的画面存成 PNG，用来核对界面（不需要人操作、也不必盯着运行中的窗口）。
##
## 运行（**必须带窗口**，无头模式没有渲染结果）：
##   godot --path <项目目录> --script res://tools/screenshot.gd
## 输出到 `user://`（= `%APPDATA%\Godot\app_userdata\<项目名>\`）：
##   shot_1_idle.png    常规局面：主战者框在上下正中、手牌停靠右侧
##   shot_2_select.png  选目标状态：整条手牌滑到下方正中、可指定目标高亮
##   shot_3_tracker.png 记牌器抽屉从右侧滑出

var _f := 0
var _main
var _gm


func _process(_d: float) -> bool:
	_f += 1
	_gm = root.get_node_or_null("GameManager")
	if _f == 2:
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _f == 20:
		_gm.new_game()
		_main.hand_slide_time = 0.0
		var me: PlayerState = _gm.get_player(0)
		var foe: PlayerState = _gm.get_player(1)
		me.max_mana = 7
		me.mana = 5
		me.hero_hp = 18
		me.armor = 4
		foe.max_mana = 6
		foe.mana = 3
		foe.hero_hp = 22
		_gm.summon_unit(0, _gm.card_by_id("c001"))
		_gm.summon_unit(0, _gm.card_by_id("c027"))
		_gm.summon_unit(1, _gm.card_by_id("c011"))
		_main._refresh()
		return false
	if _f == 24:
		# 开局会弹出起手换牌面板：先拍它，再跳过（否则后面的截图都被它盖住）
		_save("shot_0_mulligan")
		_main.skip_mulligan()
		return false
	if _f == 30:
		_save("shot_1_idle")
		return false
	if _f == 36:
		# 选一张需要目标的牌 → 整条手牌滑到下方正中
		var me: PlayerState = _gm.get_player(0)
		var idx := -1
		for i in me.hand.size():
			var c: CardData = me.hand[i]
			if c.needs_target() and c.cost <= me.mana and c.target == CardData.Targeting.ANY_CHARACTER:
				idx = i
				break
		if idx < 0:
			var db = root.get_node_or_null("CardDB")
			for c in db.cards:
				if c.needs_target() and not c.is_token and c.cost <= me.mana and c.target == CardData.Targeting.ANY_CHARACTER:
					me.hand.append(c.clone())
					_main._refresh()
					idx = me.hand.size() - 1
					break
		if idx >= 0:
			_main._on_hand_card_clicked(idx)
			_main._refresh()
		return false
	if _f == 46:
		_save("shot_2_select")
		return false
	if _f == 52:
		_main._clear_mode()
		_main._refresh()
		_main._open_tracker()
		var d: Variant = _main._tracker_panel
		d.slide_time = 0.0
		d.close()
		d.open()
		return false
	if _f == 60:
		_save("shot_3_tracker")
		return false
	if _f == 64:
		# 「打不出的牌拿起来比划」：红色禁止样式的幽灵卡 + 操作栏写明原因
		var d2: Variant = _main._tracker_panel
		if d2 != null and is_instance_valid(d2):
			d2.close()
		var me2: PlayerState = _gm.get_player(0)
		me2.mana = 0
		_main._refresh()
		var idx2 := -1
		for i in me2.hand.size():
			if me2.hand[i].cost > 0:
				idx2 = i
				break
		if idx2 >= 0:
			_main._on_hand_card_drag_started(idx2)
			_main._drag_mouse = Vector2(560, 430)
			if _main._ghost != null:
				_main._ghost.position = _main._drag_mouse - _main._ghost.size * 0.5
			_main._update_drop_feedback(_main._drag_mouse)
		return false
	if _f == 70:
		_save("shot_4_forbidden")
		_main._end_drag()
		return false
	if _f == 74:
		# 横置格：把一个随从横放到中线前那一格
		var me3: PlayerState = _gm.get_player(0)
		me3.mana = 10
		_main._refresh()
		var front_unit: BoardUnit = null
		for u in me3.board:
			front_unit = u
			break
		if front_unit == null:
			front_unit = _gm.summon_unit(0, _gm.card_by_id("c011"))   # 8/8 嘲讽，横置后很难被解掉
		if front_unit != null:
			_gm.place_in_front(0, front_unit.unit_id)
		_main._refresh()
		return false
	if _f == 80:
		_save("shot_5_front_slot")
		return false
	if _f == 84:
		# 四类卡牌：手里放一张护符与一张城邦（卡面显示类型 / 耐久），战场上摆一个护符与一个城邦
		var me4: PlayerState = _gm.get_player(0)
		me4.hand.clear()
		me4.hand.append(_gm.card_by_id("a001").clone())
		me4.hand.append(_gm.card_by_id("y001").clone())
		me4.hand.append(_gm.card_by_id("c011").clone())
		_gm.summon_unit(0, _gm.card_by_id("a002"))
		_gm.summon_unit(0, _gm.card_by_id("y002"))
		_main._refresh()
		return false
	if _f == 90:
		_save("shot_6_card_types")
		return false
	if _f == 94:
		# 指定目标规则：场上没有合法目标时，战吼随从照样能上场（不暗），法术则打不出（变暗）
		var me5: PlayerState = _gm.get_player(0)
		me5.board.clear()
		_gm.get_player(1).board.clear()
		me5.mana = 10
		me5.max_mana = 10
		me5.hand.clear()
		me5.hand.append(_gm.card_by_id("s013").clone())   # 冰封术：需要指定敌方随从
		me5.hand.append(_gm.card_by_id("c013").clone())   # 战地指挥官：战吼需要指定我方随从
		_main._refresh()
		# 直接把原因写进日志（点卡会弹详情面板挡住手牌，截图里看不清两张卡的明暗差别）
		_main._append_log(_main._cannot_play_reason(0))
		return false
	if _f == 100:
		_save("shot_7_target_rule")
		return false
	if _f == 104:
		# 城邦格：主战者旁各放一个城邦（不占战场格子）
		_gm.new_game()
		_main.skip_mulligan()
		_main._append_log("城邦格：每 3 个自己的回合，空着时从牌堆（没有则墓地）随机召唤一个城邦")
		_gm.summon_city_into_slot(0, _gm.card_by_id("y001"), "从牌堆中召唤出")
		_gm.summon_city_into_slot(1, _gm.card_by_id("y002"), "从牌堆中召唤出")
		_main._refresh()
		return false
	if _f == 110:
		_save("shot_8_city_slot")
		quit(0)
		return true
	return false


func _save(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png("user://%s.png" % name)
	print("[shot] ", name, " ", img.get_size())
