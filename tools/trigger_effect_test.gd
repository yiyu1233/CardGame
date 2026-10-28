extends SceneTree
## 卡牌触发效果测试（CardTriggers / CardData.triggers）：
##   一张卡在某个时机（入场（打出）/ 召唤入场 / 离场 / 瞬念召唤上场 / 消失 /
##   我方回合开始 / 我方回合结束）**自动**结算一条效果链，不需要玩家操作。
##
## 覆盖内容：
##   ① 注册表：时机清单 / 人话文本 / 归一 / 结构自检；
##   ② 数据：from_dict / to_dict / clone 往返，老卡表（没有这个键）读成空数组；
##   ③ 结算：入场（法术 / 随从）、召唤入场（与入场互不混淆）、离场、
##            回合开始、回合结束、消失；
##   ④ 管理员面板：清单 / 时机下拉 / 保存写回 / 保存前校验 / 删除；
##   ⑤ 卡牌详情显示触发效果。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/trigger_effect_test.gd

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
	_test_roundtrip()
	_test_play_trigger()
	_test_play_vs_summon()
	_test_leave_trigger()
	_test_turn_triggers()
	_test_vanish()
	_test_admin_ui()
	_test_card_detail()
	_cleanup()


# ------------------------------ ① 注册表 ------------------------------

func _test_registry() -> void:
	for ev in [CardTriggers.EV_PLAY, CardTriggers.EV_SUMMON, CardTriggers.EV_LEAVE,
			CardTriggers.EV_INVOKE, CardTriggers.EV_VANISH,
			CardTriggers.EV_TURN_START, CardTriggers.EV_TURN_END]:
		_check(CardTriggers.has_event(ev), "触发时机 %s 已登记" % ev)
	_check(CardTriggers.event_ids().size() >= 7, "时机清单至少有 7 条")

	var spec := CardTriggers.normalized({
		"on": "summon", "effects": [{"id": "draw", "value": 1}],
	})
	_check(str(spec.get("on", "")) == "summon", "归一保留触发时机")
	var text := CardTriggers.text(spec)
	_check(text.contains("召唤入场") and text.contains("抽"), "人话文本（%s）" % text)
	_check(CardTriggers.errors(spec).is_empty(), "合法配置没有自检错误")
	_check(not CardTriggers.errors({"on": "ghost", "effects": []}).is_empty(),
		"未登记的触发时机被自检抓出来")
	_check(not CardTriggers.errors({"on": "play"}).is_empty(),
		"没配效果链的触发会被自检抓出来")
	_check(CardTriggers.normalized({"effects": []}).get("on", "") == CardTriggers.EV_PLAY,
		"省略时机时默认「入场（打出）」")


# ------------------------------ ② 数据往返 ------------------------------

func _test_roundtrip() -> void:
	var c := _card("tr_data", "测试·触发数据", int(CardData.CardType.MINION), 1)
	c.triggers = [{"on": CardTriggers.EV_SUMMON, "effects": [{"id": "armor", "value": 1}]}]
	_check(c.has_triggers(), "配了触发后 has_triggers() 为真")
	_check(c.triggers_text().contains("召唤入场"), "能写成人话（%s）" % c.triggers_text())
	var back := CardData.from_dict(c.to_dict())
	_check(back.triggers.size() == 1, "to_dict / from_dict 往返保留触发（%d 条）" % back.triggers.size())
	_check(back.clone().triggers.size() == 1, "clone 保留触发")
	_check(not back.triggers_text().is_empty(), "克隆体也能写成人话")
	_check(CardData.from_dict({"id": "tr_old", "card_name": "老卡"}).triggers.is_empty(),
		"老卡表（没有这个键）读成空数组")


# ------------------------------ ③ 结算 ------------------------------

## 法术：入场（打出）时结算触发
func _test_play_trigger() -> void:
	var me := _prepare_game()
	var spell := _card("tr_play", "测试·打出触发", int(CardData.CardType.SPELL), 1)
	spell.triggers = [_trig(CardTriggers.EV_PLAY, [{"id": "armor", "value": 2, "target": -1}])]
	me.hand.append(spell)
	_check(_gm.play_card(ME, 0), "打出带「入场（打出）」触发的法术")
	_check(me.armor == 2, "入场触发结算了（护甲 %d）" % me.armor)


## 从手牌打出的随从只结算「入场（打出）」，不重复结算「召唤入场」
func _test_play_vs_summon() -> void:
	var me := _prepare_game()
	var minion := _card("tr_both", "测试·两种时机", int(CardData.CardType.MINION), 1)
	minion.triggers = [
		_trig(CardTriggers.EV_PLAY, [{"id": "armor", "value": 1, "target": -1}]),
		_trig(CardTriggers.EV_SUMMON, [{"id": "armor", "value": 10, "target": -1}]),
	]
	me.hand.append(minion)
	_check(_gm.play_card(ME, 0), "从手牌打出带两种时机的随从")
	_check(me.armor == 1, "只结算入场（打出），不结算召唤入场（护甲 %d）" % me.armor)

	# 直接召唤（衍生物 / 复制 / 效果召唤）只结算「召唤入场」
	var me2 := _prepare_game()
	var token := _card("tr_summon", "测试·召唤触发", int(CardData.CardType.MINION), 1)
	token.triggers = [
		_trig(CardTriggers.EV_PLAY, [{"id": "armor", "value": 10, "target": -1}]),
		_trig(CardTriggers.EV_SUMMON, [{"id": "armor", "value": 3, "target": -1}]),
	]
	_check(_gm.summon_unit(ME, token) != null, "召唤一个带触发效果的随从")
	_check(me2.armor == 3, "召唤入场触发结算了（护甲 %d）" % me2.armor)


func _test_leave_trigger() -> void:
	var me := _prepare_game()
	var dying := _card("tr_leave", "测试·离场触发", int(CardData.CardType.MINION), 1)
	dying.triggers = [_trig(CardTriggers.EV_LEAVE, [{"id": "armor", "value": 2, "target": -1}])]
	var u: BoardUnit = _gm.summon_unit(ME, dying)
	_check(u != null, "先召唤一个带「离场」触发的随从")
	_check(me.armor == 0, "还在场上时不结算离场")
	_gm._send_unit_to_graveyard(u)
	_check(me.armor == 2, "离场触发结算了（护甲 %d）" % me.armor)


func _test_turn_triggers() -> void:
	var me := _prepare_game()
	var start_card := _card("tr_ts", "测试·回合开始", int(CardData.CardType.MINION), 1)
	start_card.triggers = [_trig(CardTriggers.EV_TURN_START, [{"id": "armor", "value": 1, "target": -1}])]
	_check(_gm.summon_unit(ME, start_card) != null, "召唤带「回合开始」触发的随从")
	me.armor = 0
	_gm._start_turn(ME)
	_check(me.armor == 1, "我方回合开始时结算（护甲 %d）" % me.armor)

	var me2 := _prepare_game()
	var end_card := _card("tr_te", "测试·回合结束", int(CardData.CardType.MINION), 1)
	end_card.triggers = [_trig(CardTriggers.EV_TURN_END, [{"id": "armor", "value": 3, "target": -1}])]
	_check(_gm.summon_unit(ME, end_card) != null, "召唤带「回合结束」触发的随从")
	me2.armor = 0
	_gm._end_of_turn(ME)
	_check(me2.armor == 3, "我方回合结束时结算（护甲 %d）" % me2.armor)


## 消失（没有空置格时从游戏中移除）：直接走结算入口，验证时机能落地
func _test_vanish() -> void:
	var me := _prepare_game()
	var c := _card("tr_vanish", "测试·消失触发", int(CardData.CardType.MINION), 1)
	c.triggers = [_trig(CardTriggers.EV_VANISH, [{"id": "armor", "value": 4, "target": -1}])]
	var fired := CardTriggers.fire_card(_gm, ME, c, CardTriggers.EV_VANISH)
	_check(fired == 1, "消失触发被结算（%d 条）" % fired)
	_check(me.armor == 4, "消失触发有效果（护甲 %d）" % me.armor)


# ------------------------------ ④ 管理员面板 ------------------------------

func _test_admin_ui() -> void:
	var c := _track(_card("tr_ui", "测试·面板触发", int(CardData.CardType.MINION), 1))
	_admin._load_card(c)
	_check(_admin._trigger_list.get_item_count() == 0, "没配时清单是空的")
	_check(not _admin._trigger_editor.visible, "没选中时效果链编辑器隐藏")

	_admin._on_trigger_add()
	_check(_admin._trigger_list.get_item_count() == 1, "「新增触发效果」加了一条")
	_check(_admin._trigger_editor.visible, "选中后效果链编辑器出现")
	_select_meta(_admin._trigger_event_option, CardTriggers.EV_LEAVE)
	# 「新增触发效果」已经给了一条空效果：把它的 ID / 数值填上即可
	var st: Dictionary = _admin._trigger_editor.row_state(0)
	var ids: Array = st["ids"]
	(st["id_option"] as OptionButton).selected = ids.find("armor")
	(st["value_spin"] as SpinBox).value = 2
	var form: CardData = _admin._form_to_data()
	_check(form.triggers.size() == 1, "保存后卡上有 1 条触发效果（%d）" % form.triggers.size())
	if form.triggers.size() == 1:
		var e: Dictionary = form.triggers[0]
		_check(str(e.get("on", "")) == CardTriggers.EV_LEAVE, "触发时机写对（%s）" % str(e.get("on", "")))
		_check((e.get("effects", []) as Array).size() == 1, "效果链跟着写回（%d 条）" % (e.get("effects", []) as Array).size())
	_check(_admin._trigger_list.get_item_text(0).contains("离场"), "清单文本跟着刷新（%s）" % _admin._trigger_list.get_item_text(0))

	# 回填：重新载入这张卡
	_admin._load_card(form)
	_check(_admin._trigger_list.get_item_count() == 1, "重新载入后清单有 1 条")
	_check(_admin._trigger_event_value() == CardTriggers.EV_LEAVE, "时机下拉被正确回填")

	# 保存前校验：空效果链 / 未登记时机都会被拦下
	_admin._trigger_editor.clear()
	_admin._trigger_flush()
	_check(_admin._validate_triggers().contains("没有配效果"), "保存前校验拦下「空效果链」")
	_admin._trigger_rows[0] = {"on": "ghost", "effects": [{"id": "armor", "value": 1}]}
	_check(_admin._validate_triggers().contains("未登记"), "保存前校验拦下「未登记的时机」")

	# 删除
	_admin._trigger_list.select(0)
	_admin._on_trigger_remove()
	_check(_admin._trigger_list.get_item_count() == 0, "删除所选后清单清空")
	_check(not _admin._trigger_editor.visible, "清空后效果链编辑器又隐藏了")


# ------------------------------ ⑤ 卡牌详情 ------------------------------

func _test_card_detail() -> void:
	var script = load("res://scripts/CardDetail.gd")
	if script == null:
		_check(false, "卡牌详情脚本可加载")
		return
	var detail = script.new()
	root.add_child(detail)
	var c := _card("tr_detail", "测试·详情触发", int(CardData.CardType.MINION), 1)
	c.triggers = [_trig(CardTriggers.EV_TURN_START, [{"id": "draw", "value": 1}])]
	detail._fill(c)
	_check(detail._body.text.contains("触发"), "卡牌详情里显示触发效果")
	detail.queue_free()


# ------------------------------ 测试辅助 ------------------------------

func _trig(on: String, effects: Array) -> Dictionary:
	return {"on": on, "effects": effects}


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
		me.deck.append(_card("tr_fill_%d" % i, "填充%d" % i, int(CardData.CardType.MINION), 1))
	var foe: PlayerState = _gm.get_player(FOE)
	foe.leader_effects.clear()
	foe.deck.clear()
	for i in 10:
		foe.deck.append(_card("tr_ffill_%d" % i, "敌方填充%d" % i, int(CardData.CardType.MINION), 1))
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
	print("=== 触发效果测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _cleanup() -> void:
	for id in _created:
		_db.remove_card(id)
