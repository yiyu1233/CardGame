extends SceneTree
## 无头模式冒烟测试：验证卡表、回合流程、召唤 / 攻击 / 嘲讽 / 圣盾、AI 回合、管理员增删卡与界面。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/smoke_test.gd
## 说明：--script 模式下自动加载单例尚不可作为全局标识符使用，
##       因此这里通过节点查找动态调用（0=我方 1=敌方 AI）。

const ME := 0
const FOE := 1

var _frames := 0
var _phase := 0
var _failed := 0
var _db
var _auth
var _gm


func _initialize() -> void:
	print("=== 冒烟测试开始 ===")


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		0:
			if _frames >= 2:
				_db = root.get_node_or_null("CardDB")
				_auth = root.get_node_or_null("AdminAuth")
				_gm = root.get_node_or_null("GameManager")
				_run_data_tests()
				_phase = 1
		1:
			if _frames >= 10:
				_run_battle_tests()
				_phase = 2
		2:
			if _frames >= 15:
				print("[TEST] 移交回合给敌方 AI，等待其行动…")
				_gm.end_turn()
				_phase = 3
		3:
			if _frames >= 30 and not _gm.busy:
				_check(_gm.current_player == ME, "AI 行动结束后交回我方回合")
				_check(_gm.turn_count >= 2, "回合数推进到第 %d 回合" % _gm.turn_count)
				_phase = 4
		4:
			if _frames >= 40:
				_run_ui_tests()
				_finish()
	return _frames > 1500


# ------------------------------ 数据与管理员 ------------------------------

func _run_data_tests() -> void:
	_check(_db != null, "CardDB 自动加载")
	_check(_auth != null, "AdminAuth 自动加载")
	_check(_gm != null, "GameManager 自动加载")
	if _db == null or _auth == null or _gm == null:
		_finish()
		return

	_check(_db.cards.size() > 0, "读取卡表（%d 张，其中衍生物 %d 张）" % [_db.cards.size(), _db.token_count()])
	var deck = _db.build_deck()
	var has_token := false
	for c in deck:
		if c.is_token:
			has_token = true
	_check(not has_token, "生成的牌库不含衍生物（%d 张）" % deck.size())

	_check(not _auth.login("admin", "wrong"), "错误密码登录失败")
	_check(_auth.login("admin", "admin123"), "管理员登录成功")

	var before: int = _db.cards.size()
	var tmp := CardData.new()
	tmp.id = "tmp_test_card"
	tmp.card_name = "测试卡"
	tmp.cost = 1
	tmp.card_type = CardData.CardType.MINION
	tmp.attack = 2
	tmp.health = 2
	_db.add_card(tmp)
	_check(_db.cards.size() == before + 1, "新增卡牌：%d -> %d" % [before, _db.cards.size()])
	_db.remove_card("tmp_test_card")
	_check(_db.cards.size() == before, "删除卡牌后恢复为 %d" % _db.cards.size())


# ------------------------------ 战斗流程 ------------------------------

func _run_battle_tests() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	_check(me.hand.size() == 5, "我方首回合手牌 %d 张（起手 4 + 回合抽牌 1）" % me.hand.size())
	_check(foe.hand.size() == 4, "后手（AI）起手 %d 张（尚未轮到它抽牌）" % foe.hand.size())
	_check(me.deck.size() + me.hand.size() == _db.build_deck().size(), "牌库 + 手牌数量正确")

	me.mana = 10
	me.max_mana = 10

	var idx := -1
	for i in me.hand.size():
		var c: CardData = me.hand[i]
		if c.card_type != CardData.CardType.MINION:
			continue
		if c.has_effect() or c.needs_target():
			continue
		# 需要一张**能攻击**的素随从：没有冲锋 / 突袭（验证“召唤当回合不能攻击”），
		# 攻击力 > 0（0 攻随从 `can_attack()` 直接为假）、而且没有任何关键字
		# （「无法攻击」这类机制关键字也会让它打不了，起手随机时曾因此偶发失败）
		if c.attack <= 0 or not c.keywords.is_empty():
			continue
		idx = i
		break
	if idx < 0:
		# 起手是随机的：手牌里没有合适的随从时，从卡表补一张，确保这条规则一定被验证
		for c in _db.cards:
			if (c.card_type == CardData.CardType.MINION and not c.has_effect() and not c.needs_target()
					and c.attack > 0 and c.keywords.is_empty()):
				me.hand.append(c.clone())
				idx = me.hand.size() - 1
				break
	_check(_gm.play_card(ME, idx), "打出随从牌")
	_check(me.board.size() == 1, "随从进入战场")

	var unit: BoardUnit = me.board[0]
	_check(_gm.get_valid_attack_targets(ME, unit.unit_id).is_empty(), "召唤当回合无法攻击（未准备好）")

	var taunt := BoardUnit.new()
	taunt.setup(_db.get_card("c002").clone(), FOE, -1, 99001)
	foe.board.append(taunt)
	unit.summoned_turn = -1
	unit.attacks_used = 0
	var targets = _gm.get_valid_attack_targets(ME, unit.unit_id)
	_check(targets.size() == 1 and int(targets[0]["unit_id"]) == 99001, "存在嘲讽时只能攻击嘲讽随从")
	_check(not _gm.attack(ME, unit.unit_id, -1, FOE), "有嘲讽时攻击英雄被拒绝")

	var hp_before: int = foe.hero_hp
	foe.board.clear()
	unit.attacks_used = 0
	_check(_gm.attack(ME, unit.unit_id, -1, FOE), "无随从时可攻击敌方英雄")
	_check(foe.hero_hp < hp_before, "敌方英雄生命 %d -> %d" % [hp_before, foe.hero_hp])

	var shielded := BoardUnit.new()
	shielded.setup(_db.get_card("c007").clone(), FOE, -1, 99002)
	var hp_full: int = shielded.health
	shielded.take_damage(5)
	_check(shielded.health == hp_full and not shielded.divine_shield, "圣盾免疫一次伤害后消失")
	shielded.take_damage(2)
	_check(shielded.health == hp_full - 2, "圣盾消失后正常受伤")

	var victim: CardData = me.hand[0]
	_db.remove_card(victim.id)
	var still_there := false
	for c in me.hand:
		if c.id == victim.id:
			still_there = true
	_check(not still_there, "管理员删除卡牌后已从手牌移除")
	_db.add_card(victim)


# ------------------------------ 界面 ------------------------------

func _run_ui_tests() -> void:
	var card_scene = load("res://scenes/Card.tscn")
	_check(card_scene != null, "加载 Card.tscn")
	if card_scene != null:
		var card_ui = card_scene.instantiate()
		root.add_child(card_ui)
		card_ui.setup(_db.build_deck()[0], 0, true)
		_check(card_ui.get_child_count() > 0, "手牌控件可实例化")
		card_ui.queue_free()

	var panel_script = load("res://scripts/AdminPanel.gd")
	var panel = panel_script.new()
	root.add_child(panel)
	_check(panel._list.get_item_count() == _db.cards.size(),
		"管理面板列出全部 %d 张卡牌" % _db.cards.size())
	# 表单很高，窗口必须放得下「保存」：以前按钮被裁到窗口之外（用户反馈「没有保存选项」）
	var save_btn = panel._save_button
	_check(save_btn != null and save_btn.is_visible_in_tree(), "管理面板有「保存」按钮且可见")
	_check(panel.size.y >= 800.0,
		"管理窗口按内容高度开（%d 高，足够放下 13 行表单 + 保存行）" % panel.size.y)
	_check(panel._form.get_parent() is ScrollContainer,
		"表单放在滚动容器里（窗口再小也能滚到每个字段）")
	panel.queue_free()

	var main_scene = load("res://scenes/Main.tscn")
	_check(main_scene != null, "加载 Main.tscn")
	if main_scene != null:
		var main_ui = main_scene.instantiate()
		root.add_child(main_ui)
		_check(main_ui.get_child_count() > 0, "主对战场景可实例化")
		var board = main_ui.get_node_or_null("Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerBoardRow")
		_check(board != null, "主场景包含我方战场容器")
		var hand = main_ui.get_node_or_null("Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/HandArea")
		_check(hand != null, "主场景包含手牌区（扇形布局容器）")
		var eboard = main_ui.get_node_or_null("Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyBoardRow")
		_check(eboard != null, "主场景包含敌方战场容器（与我方战场互为镜像）")
		main_ui.queue_free()


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_failed += 1
		print("[FAIL] " + description)


func _finish() -> void:
	print("=== 冒烟测试结束：失败 %d 项 ===" % _failed)
	quit(1 if _failed > 0 else 0)
