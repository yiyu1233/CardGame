extends SceneTree
## 主战者效果测试（照《影之诗》一代的「主战者に付与される効果」，不是二代纹章）：
##   卡牌在某个时机（入场 / 离场 / 瞬念召唤 / 召唤 / 消失）把一条「监听器」挂到主战者身上，
##   之后由引擎在事件（回合开始 / 回合结束 / 打出 N 费卡 / 抽到 N 费卡 / N 费卡离场）发生时结算。
##
## 覆盖内容：
##   ① 注册表：赋予时机 / 监听事件 / 人话文本 / 归一 / 结构自检；
##   ② 赋予：打出带主战者效果的卡 → 挂到自己（或对手）主战者身上，字段（费用 / 回合 / 目标）正确；
##   ③ 触发：回合开始、打出（按费用过滤）、抽到（按费用过滤）、离场；
##   ④ 持续回合：N 回合到点自动失效（按该主战者自己的回合数算）；
##   ⑤ 面板：清单 / 控件回填 / 保存写回 / 保存前校验；
##   ⑥ 卡牌详情显示主战者效果。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/leader_effect_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _admin = null
var _fail_lines: Array[String] = []
var _created: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		var auth = root.get_node_or_null("AdminAuth")
		if _db == null or _gm == null or auth == null:
			_check(false, "CardDB / GameManager / AdminAuth 自动加载")
			_finish()
			return true
		var panel_script = load("res://scripts/AdminPanel.gd")
		_admin = panel_script.new() if panel_script != null else null
		_check(_admin != null, "卡牌管理面板可实例化（编译通过）")
		if _admin == null:
			_finish()
			return true
		root.add_child(_admin)
		_phase = 1
		return false
	if _phase == 1 and _frames >= 4:
		_phase = 2
		_run()
		_finish()
		return false
	return _frames > 600


func _run() -> void:
	_test_registry()
	_test_grant_on_play()
	_test_turn_start_and_duration()
	_test_cost_filtered_events()
	_test_leave_event()
	_test_opponent_target()
	_test_admin_ui()
	_test_card_detail()
	_cleanup()


# ------------------------------ ① 注册表 ------------------------------

func _test_registry() -> void:
	_check(LeaderEffects.grant_ids().has(LeaderEffects.GRANT_PLAY), "赋予时机里有「入场（打出）」")
	_check(LeaderEffects.grant_ids().has(LeaderEffects.GRANT_INVOKE), "赋予时机里有「瞬念召唤」")
	_check(LeaderEffects.grant_ids().has(LeaderEffects.GRANT_VANISH), "赋予时机里有「消失」")
	_check(LeaderEffects.event_ids().has(LeaderEffects.ON_TURN_START), "监听事件里有「回合开始」")
	_check(LeaderEffects.event_needs_cost(LeaderEffects.ON_PLAY), "「打出」按费用过滤")
	_check(not LeaderEffects.event_needs_cost(LeaderEffects.ON_TURN_START), "「回合开始」不需要费用")

	var spec := LeaderEffects.normalized({
		"grant": "play", "on": "play", "cost": 2, "turns": 3, "target": 0,
		"effects": [{"id": "armor", "value": 2, "target": -1}],
	})
	_check(int(spec.get("turns", -1)) == 3 and int(spec.get("cost", 0)) == 2, "归一保留回合数与费用过滤")
	var text := LeaderEffects.text(spec)
	_check(text.contains("入场（打出）") and text.contains("2 费的") and text.contains("3 回合"),
		"人话文本（%s）" % text)
	_check(LeaderEffects.errors(spec).is_empty(), "合法配置没有自检错误")
	_check(not LeaderEffects.errors({"grant": "ghost", "on": "play"}).is_empty(),
		"未登记的赋予时机会被自检抓出来")
	_check(not LeaderEffects.errors({"grant": "play", "on": "play"}).is_empty(),
		"没配效果链的主战者效果会被自检抓出来")


# ------------------------------ ② 赋予（入场时） ------------------------------

func _test_grant_on_play() -> void:
	var me := _prepare_game()
	var spell := _card("le_grant", "测试·赋予主战者", int(CardData.CardType.SPELL), 1)
	spell.leader_effects = [_spec("play", "turn_start", -1, 2, 0, [{"id": "armor", "value": 2, "target": -1}])]
	me.hand.append(spell)
	me.mana = 10
	_check(_gm.play_card(ME, 0), "打出带「主战者效果」的卡")
	_check(me.leader_effects.size() == 1, "主战者身上挂上了 1 条效果（%d）" % me.leader_effects.size())
	if me.leader_effects.size() == 1:
		var e: Dictionary = me.leader_effects[0]
		_check(str(e.get("on", "")) == "turn_start", "监听事件是回合开始（%s）" % str(e.get("on", "")))
		_check(str(e.get("source", "")) == "le_grant", "记下了来源卡（%s）" % str(e.get("source", "")))
		_check(int(e.get("expire_turn", -1)) == me.turns_taken + 2,
			"到期回合 = 当前回合 + 持续数（%d）" % int(e.get("expire_turn", -1)))
	# 数据往返：to_dict / from_dict / clone 都带着它
	var back := CardData.from_dict(spell.to_dict())
	_check(back.leader_effects.size() == 1 and back.clone().leader_effects.size() == 1,
		"主战者效果能序列化 / clone")
	_check(back.leader_effects_text() != "", "能写成人话（%s）" % back.leader_effects_text())
	_check(CardData.from_dict({"id": "le_old", "card_name": "老卡"}).leader_effects.is_empty(),
		"老卡表（没有这个键）读成空数组")


# ------------------------------ ③ 回合开始 + 持续回合 ------------------------------

func _test_turn_start_and_duration() -> void:
	var me := _prepare_game()
	me.armor = 0
	me.add_leader_effect(LeaderEffects.normalized(_spec("play", "turn_start", -1, 2, 0,
		[{"id": "armor", "value": 2, "target": -1}])), "le_src", me.turns_taken)
	_check(me.armor == 0, "刚挂上时不会立刻结算")

	_gm._start_turn(ME)                     # 自己的第 2 个回合
	_check(me.armor == 2, "回合开始时结算一次（护甲 %d）" % me.armor)
	me.armor = 0
	_gm._start_turn(ME)                     # 第 3 个回合：2 回合到点
	_check(me.armor == 0, "持续 2 回合的效果到点后不再结算（护甲 %d）" % me.armor)
	_check(me.leader_effects.is_empty(), "到点后被摘掉（剩 %d 条）" % me.leader_effects.size())

	# 永久效果（turns = 0）不掉
	me.add_leader_effect(LeaderEffects.normalized(_spec("play", "turn_start", -1, 0, 0,
		[{"id": "armor", "value": 1, "target": -1}])), "le_forever", me.turns_taken)
	_gm._start_turn(ME)
	_gm._start_turn(ME)
	_check(me.leader_effects.size() == 1, "持续 0 = 本局永久（还在 %d 条）" % me.leader_effects.size())


# ------------------------------ ④ 按费用过滤的事件 ------------------------------

func _test_cost_filtered_events() -> void:
	# 打出：只认 2 费
	var me := _prepare_game()
	me.armor = 0
	me.add_leader_effect(LeaderEffects.normalized(_spec("play", "play", 2, 0, 0,
		[{"id": "armor", "value": 1, "target": -1}])), "le_src", me.turns_taken)
	me.hand.append(_card("le_c1", "测试·1费", int(CardData.CardType.SPELL), 1))
	me.mana = 10
	_gm.play_card(ME, 0)
	_check(me.armor == 0, "打出 1 费卡不触发「2 费」的监听（护甲 %d）" % me.armor)
	me.hand.append(_card("le_c2", "测试·2费", int(CardData.CardType.SPELL), 2))
	me.mana = 10
	_gm.play_card(ME, 0)
	_check(me.armor == 1, "打出 2 费卡触发（护甲 %d）" % me.armor)

	# 抽到：只认 3 费
	var me2 := _prepare_game()
	me2.armor = 0
	me2.add_leader_effect(LeaderEffects.normalized(_spec("play", "draw", 3, 0, 0,
		[{"id": "armor", "value": 2, "target": -1}])), "le_src", me2.turns_taken)
	me2.deck.append(_card("le_d1", "测试·抽1费", int(CardData.CardType.MINION), 1))
	_gm.draw(ME, 1)
	_check(me2.armor == 0, "抽到 1 费卡不触发「3 费」的监听（护甲 %d）" % me2.armor)
	me2.deck.append(_card("le_d3", "测试·抽3费", int(CardData.CardType.MINION), 3))
	_gm.draw(ME, 1)
	_check(me2.armor == 2, "抽到 3 费卡触发（护甲 %d）" % me2.armor)


# ------------------------------ ⑤ 离场 ------------------------------

func _test_leave_event() -> void:
	var me := _prepare_game()
	me.armor = 0
	me.add_leader_effect(LeaderEffects.normalized(_spec("play", "leave", -1, 0, 0,
		[{"id": "armor", "value": 1, "target": -1}])), "le_src", me.turns_taken)
	var u: BoardUnit = _gm.summon_unit(ME, _card("le_u1", "测试·会离场的随从", int(CardData.CardType.MINION), 1))
	_check(u != null, "先召唤一个随从")
	me.armor = 0
	_gm._send_unit_to_graveyard(u)
	_check(me.armor == 1, "随从离场触发「离场」监听（护甲 %d）" % me.armor)

	# 离场时赋予：这张卡离场时把效果挂给主战者
	var me2 := _prepare_game()
	var dying := _card("le_leave_grant", "测试·离场赋予", int(CardData.CardType.MINION), 1)
	dying.leader_effects = [_spec("leave", "turn_start", -1, 0, 0,
		[{"id": "armor", "value": 3, "target": -1}])]
	var u2: BoardUnit = _gm.summon_unit(ME, dying)
	_check(me2.leader_effects.is_empty(), "还在场上时没有挂效果")
	_gm._send_unit_to_graveyard(u2)
	_check(me2.leader_effects.size() == 1, "离场时把效果挂给了主战者（%d 条）" % me2.leader_effects.size())


# ------------------------------ ⑥ 目标 = 对手主战者 ------------------------------

func _test_opponent_target() -> void:
	var me := _prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.armor = 0
	var spell := _card("le_foe", "测试·给对手挂", int(CardData.CardType.SPELL), 1)
	spell.leader_effects = [_spec("play", "turn_start", -1, 0, 1,
		[{"id": "armor", "value": 2, "target": -1}])]
	me.hand.append(spell)
	me.mana = 10
	_gm.play_card(ME, 0)
	_check(me.leader_effects.is_empty() and foe.leader_effects.size() == 1,
		"目标 = 对手时挂到对手主战者身上（我方 %d / 对手 %d）" % [
			me.leader_effects.size(), foe.leader_effects.size()])
	foe.armor = 0
	_gm._start_turn(FOE)
	_check(foe.armor == 2, "对手的回合开始时替对手结算（护甲 %d）" % foe.armor)


# ------------------------------ ⑦ 管理员面板 ------------------------------

func _test_admin_ui() -> void:
	var c := _track(_card("le_ui", "测试·面板主战者效果", int(CardData.CardType.SPELL), 1))
	_admin._load_card(c)
	_check(_admin._leader_list.get_item_count() == 0, "没配时清单是空的")
	_check(not _admin._leader_editor.visible, "没选中时效果链编辑器隐藏")

	_admin._on_leader_add()
	_check(_admin._leader_list.get_item_count() == 1, "「新增主战者效果」加了一条")
	_check(_admin._leader_editor.visible, "选中后效果链编辑器出现")
	# 控件 → 数据
	_select_meta(_admin._leader_grant_option, "leave")
	_select_meta(_admin._leader_event_option, "draw")
	_admin._leader_cost_spin.value = 4
	_admin._leader_turns_spin.value = 2
	_admin._leader_target_option.selected = 0
	# 「新增主战者效果」已经给了一条空效果：把它的 ID / 数值填上即可
	var st: Dictionary = _admin._leader_editor.row_state(0)
	var ids: Array = st["ids"]
	(st["id_option"] as OptionButton).selected = ids.find("armor")
	(st["value_spin"] as SpinBox).value = 3
	var form: CardData = _admin._form_to_data()
	_check(form.leader_effects.size() == 1, "保存后卡上有 1 条主战者效果（%d）" % form.leader_effects.size())
	if form.leader_effects.size() == 1:
		var e: Dictionary = form.leader_effects[0]
		_check(str(e.get("grant", "")) == "leave" and str(e.get("on", "")) == "draw",
			"赋予时机 / 监听事件写对（%s / %s）" % [str(e.get("grant", "")), str(e.get("on", ""))])
		_check(int(e.get("cost", -2)) == 4 and int(e.get("turns", -1)) == 2, "费用过滤 / 持续回合写对")
		_check((e.get("effects", []) as Array).size() == 1, "效果链跟着写回（%d 条）" % (e.get("effects", []) as Array).size())
	_check(_admin._leader_list.get_item_text(0).contains("4 费的"), "清单文本跟着刷新（%s）" % _admin._leader_list.get_item_text(0))

	# 回填：重新载入这张卡
	_admin._load_card(form)
	_check(_admin._leader_list.get_item_count() == 1, "重新载入后清单有 1 条")
	_check(_admin._leader_turns_spin.value == 2 and _admin._leader_cost_spin.value == 4, "控件被正确回填")

	# 保存前校验：空效果链会被拦下
	_admin._leader_editor.clear()
	_check(_admin._validate_leader_effects().contains("没有配效果"), "保存前校验拦下「空效果链」")

	# 删除
	_admin._leader_list.select(0)
	_admin._on_leader_remove()
	_check(_admin._leader_list.get_item_count() == 0, "删除所选后清单清空")
	_check(not _admin._leader_editor.visible, "清空后效果链编辑器又隐藏了")


# ------------------------------ ⑧ 卡牌详情 ------------------------------

func _test_card_detail() -> void:
	var script = load("res://scripts/CardDetail.gd")
	if script == null:
		_check(false, "卡牌详情脚本可加载")
		return
	var detail = script.new()
	root.add_child(detail)
	var c := _card("le_detail", "测试·详情主战者", int(CardData.CardType.SPELL), 1)
	c.leader_effects = [_spec("play", "turn_start", -1, 2, 0, [{"id": "draw", "value": 1}])]
	detail._fill(c)
	_check(detail._body.text.contains("主战者效果"), "卡牌详情里显示主战者效果")
	detail.queue_free()


# ------------------------------ 测试辅助 ------------------------------

func _spec(grant: String, on: String, cost: int, turns: int, target: int, effects: Array) -> Dictionary:
	return {
		"grant": grant, "on": on, "cost": cost, "turns": turns,
		"target": target, "effects": effects,
	}


func _card(id: String, name_: String, card_type: int, cost_: int = 1) -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": cost_, "card_type": card_type,
		"attack": 1, "health": 2, "keywords": [], "effects": [], "deathrattle_effects": [],
	})
	c.sync_legacy_from_chains()
	return c


func _track(c: CardData) -> CardData:
	_created.append(c.id)
	return c


func _prepare_game() -> PlayerState:
	_gm.new_game()
	_gm.log_enabled = true
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.graveyard.clear()
	me.deck.clear()
	me.turns_taken = 1
	me.city_summon_turn = -1
	me.troop_entered_total.clear()
	me.troop_entered_turn.clear()
	me.leader_effects.clear()
	# 牌库垫几张：回合开始会抽牌，空牌库的疲劳伤害会把护甲吃掉（干扰断言）
	for i in 10:
		me.deck.append(_card("le_fill_%d" % i, "填充%d" % i, int(CardData.CardType.MINION), 1))
	var foe: PlayerState = _gm.get_player(FOE)
	foe.leader_effects.clear()
	foe.deck.clear()
	for i in 10:
		foe.deck.append(_card("le_ffill_%d" % i, "敌方填充%d" % i, int(CardData.CardType.MINION), 1))
	return me


static func _select_meta(option: OptionButton, value: String) -> void:
	for i in option.item_count:
		var meta = option.get_item_metadata(i)
		if meta != null and str(meta) == value:
			option.select(i)
			return
	option.select(0)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 主战者效果测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _cleanup() -> void:
	for id in _created:
		_db.remove_card(id)
