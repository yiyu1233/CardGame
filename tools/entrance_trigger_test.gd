extends SceneTree
## 入场效果（随从 = 战吼，护符 / 城邦 = 安放）的**触发规则**测试：
##   * 只有**从手牌打出**（play_card）会自动结算入场效果；
##   * 所有**召唤入场**（衍生物 / 复制 / 亡语召唤 / 城邦格每 3 回合判定）都不结算入场效果；
##   * 想让召唤上场的单位结算入场效果，只能用卡牌效果「触发一次入场效果」（trigger_entrance）；
##   * 城邦格：本回合判定但**没召唤**时不延后到下一回合补判，而是 3 个自己的回合之后再判定。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/entrance_trigger_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _db
var _gm
var _hooks := false
var _fail_lines: Array[String] = []
var _logs: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		_run()
		_finish()
		return true
	return _frames > 400


func _run() -> void:
	if not _hooks:
		_gm.log_message.connect(func(t: String) -> void: _logs.append(t))
		_hooks = true
	if _db.cards.is_empty():
		# 卡表为空极端情况：恢复内置卡表后再跑（正常运行时不会走到这里）
		_db.reset_to_default()
	_check(_db.cards.size() > 0, "卡表可用（%d 张）" % _db.cards.size())

	_test_registry()
	_test_play_triggers()
	_test_summon_never_triggers()
	_test_city_slot_summon_never_triggers()
	_test_trigger_entrance_effect()
	_test_play_card_with_trigger_effect()
	_test_target_without_entrance_effect()
	_test_loop_guard()
	_test_city_slot_no_deferral()


# ------------------------------ 1. 效果注册表 ------------------------------

func _test_registry() -> void:
	var id := "trigger_entrance"
	_check(CardEffects.has(id), "效果注册表里有「触发一次入场效果」")
	_check(CardEffects.display_name(id) == "触发一次入场效果", "效果名：%s" % CardEffects.display_name(id))
	_check(CardEffects.text(id, 0) != "", "有卡面文本：%s" % CardEffects.text(id, 0))
	_check(CardEffects.default_target(id) == CardData.Targeting.ALLY_MINION,
		"默认目标是我方随从（含城邦格里的城邦）")


# ------------------------------ 2. 打出才自动结算 ------------------------------

func _test_play_triggers() -> void:
	var me := _prepare_game()
	me.hand.append(_entrance_minion())
	me.armor = 0
	var ok: bool = _gm.play_card(ME, me.hand.size() - 1)
	_check(ok, "从手牌打出一张带入场效果的随从")
	_check(me.armor == 3, "打出时入场效果自动结算一次（护甲 %d）" % me.armor)


# ------------------------------ 3. 召唤入场一律不结算 ------------------------------

func _test_summon_never_triggers() -> void:
	var me := _prepare_game()
	me.armor = 0

	# 直接召唤
	var u: BoardUnit = _gm.summon_unit(ME, _entrance_minion())
	_check(u != null, "召唤一个带入场效果的随从上场")
	_check(me.armor == 0, "召唤入场不结算入场效果（护甲 %d）" % me.armor)

	# 复制召唤（「复制友方随从」这条效果走的路径）
	var self_target := {"kind": "self", "unit_id": -1, "player_id": ME}
	var ctx := EffectContext.create(_gm, ME, 0, "", self_target, "测试卡")
	ctx.summon_copy(ME, u)
	_check(me.armor == 0, "复制召唤同样不结算入场效果（护甲 %d）" % me.armor)

	# 衍生物召唤
	var token: CardData = _entrance_minion("tt_token", "测试衍生物")
	token.is_token = true
	_db.cards.append(token)
	_db.rebuild_index()
	var board_before: int = me.board.size()
	var ctx2 := EffectContext.create(_gm, ME, 1, "tt_token", self_target, "测试卡")
	ctx2.summon(ME, "tt_token", 1)
	_check(me.board.size() == board_before + 1, "衍生物召唤成功上场（战场 %d）" % me.board.size())
	_check(me.armor == 0, "衍生物召唤也不结算入场效果（护甲 %d）" % me.armor)


# ------------------------------ 4. 城邦格每 3 回合的自动召唤 ------------------------------

func _test_city_slot_summon_never_triggers() -> void:
	var me := _prepare_game()
	var city := _city_with_effect([{"id": "armor", "value": 3, "target": -1}], "tt_city", "测试城邦")
	_set_deck(me, [city])
	_gm._start_turn(ME)                      # 第 2 个自己的回合：不判定
	_check(me.turns_taken == 2 and _gm.city_slot_unit(ME) == null, "第 2 个回合不判定（无召唤）")
	me.armor = 0
	_gm._start_turn(ME)                      # 第 3 个自己的回合：判定 → 从牌堆召唤
	var slot: BoardUnit = _gm.city_slot_unit(ME)
	_check(slot != null, "第 3 个回合把城邦召唤进了城邦格")
	_check(slot != null and slot.in_city_slot, "它确实住在城邦格里")
	_check(me.armor == 0, "城邦格自动召唤不结算安放效果（护甲 %d）" % me.armor)


# ------------------------------ 5. 「触发一次入场效果」 ------------------------------

func _test_trigger_entrance_effect() -> void:
	var me := _prepare_game()
	var u: BoardUnit = _gm.summon_unit(ME, _entrance_minion())
	_check(u != null and me.armor == 0, "召唤上场后护甲仍是 0（%d）" % me.armor)
	var target := {"kind": "unit", "unit_id": u.unit_id, "player_id": ME}
	var ctx := EffectContext.create(_gm, ME, 0, "", target, "测试卡")
	CardEffects.apply("trigger_entrance", ctx)
	_check(me.armor == 3, "「触发一次入场效果」让它结算了一次（护甲 %d）" % me.armor)
	CardEffects.apply("trigger_entrance", ctx)
	_check(me.armor == 6, "再触发就再结算一次，**每次只结算一次**（护甲 %d）" % me.armor)


# ------------------------------ 6. 走真实出牌流程 ------------------------------

func _test_play_card_with_trigger_effect() -> void:
	var me := _prepare_game()
	var u: BoardUnit = _gm.summon_unit(ME, _entrance_minion())
	var spell: CardData = _card_with_effect(int(CardData.CardType.SPELL),
		[{"id": "trigger_entrance", "value": 0, "target": int(CardData.Targeting.ALLY_MINION)}],
		"tt_spell", "测试·再触发")
	spell.cost = 1
	me.hand.clear()
	me.hand.append(spell)
	me.mana = 10
	me.armor = 0
	var ok: bool = _gm.play_card(ME, 0, u.unit_id, ME)
	_check(ok, "打出一张「触发一次入场效果」的法术（目标 = 召唤来的那个随从）")
	_check(me.armor == 3, "通过真实出牌也能触发入场效果一次（护甲 %d）" % me.armor)


# ------------------------------ 7. 没有入场效果的目标 ------------------------------

func _test_target_without_entrance_effect() -> void:
	var me := _prepare_game()
	var u: BoardUnit = _gm.summon_unit(ME, _card_with_effect(int(CardData.CardType.MINION), [], "tt_plain", "白板随从"))
	_check(u != null, "召唤一个没有入场效果的随从")
	_logs.clear()
	var ok: bool = _gm.trigger_entrance_effect(u)
	_check(not ok, "目标没有入场效果时返回 false（不结算、不报错）")
	_check(_has_log("没有入场效果"), "日志说清了为什么没触发")


# ------------------------------ 8. 自我触发的回环保护 ------------------------------

func _test_loop_guard() -> void:
	var me := _prepare_game()
	var loop_card := _card_with_effect(int(CardData.CardType.MINION),
		[{"id": "trigger_entrance", "value": 0, "target": int(CardData.Targeting.ALLY_MINION)}],
		"tt_loop", "回环测试随从")
	var u: BoardUnit = _gm.summon_unit(ME, loop_card)
	_check(u != null, "召唤一个「入场效果 = 触发一次入场效果」的随从")
	_logs.clear()
	var ok: bool = _gm.trigger_entrance_effect(u)
	_check(ok, "第一次触发成功")
	_check(_has_log("入场效果的触发层数已到上限"), "入场效果里再触发入场效果时不会无限递归（到上限停手）")
	_check(_gm._entrance_depth == 0, "结束后层数归零（%d）" % _gm._entrance_depth)


# ------------------------------ 9. 判定失败不延后 ------------------------------

func _test_city_slot_no_deferral() -> void:
	var me := _prepare_game()
	_set_deck(me, [])                        # 牌堆 / 墓地都没有城邦
	_gm._start_turn(ME)                      # 第 2 个自己的回合
	_check(me.turns_taken == 2 and _gm.city_slot_unit(ME) == null, "第 2 个回合不判定")
	_gm._start_turn(ME)                      # 第 3 个自己的回合：判定，但没有城邦
	_check(me.turns_taken == 3 and _gm.city_slot_unit(ME) == null,
		"第 3 个回合判定时牌堆与墓地都没有城邦 → 不召唤")

	# 判定之后牌堆里才出现城邦：**不**延后到下一回合补召唤，要等到下一个第 3 个回合
	var late := _city_with_effect([], "tt_city_late", "迟到城邦")
	me.deck.insert(0, late)
	_gm._start_turn(ME)                      # 第 4 个自己的回合
	_check(me.turns_taken == 4 and _gm.city_slot_unit(ME) == null,
		"第 4 个回合不会因为「上一回合没召唤」而补召唤")
	_gm._start_turn(ME)                      # 第 5 个自己的回合
	_check(me.turns_taken == 5 and _gm.city_slot_unit(ME) == null, "第 5 个回合同样不补召唤")
	_gm._start_turn(ME)                      # 第 6 个自己的回合：再次判定
	_check(me.turns_taken == 6, "进入自己的第 6 个回合")
	_check(_gm.city_slot_unit(ME) != null, "第 6 个回合再次判定并召唤出城邦")


# ------------------------------ 测试辅助 ------------------------------

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
	print("=== 入场效果触发测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _has_log(keyword: String) -> bool:
	for l in _logs:
		if l.contains(keyword):
			return true
	return false


## 每用例一个干净的对局：牌库 / 手牌 / 战场 / 墓地都清空，留下充足法力
func _prepare_game() -> PlayerState:
	_gm.new_game()
	_gm.log_enabled = true
	_logs.clear()
	_gm._entrance_depth = 0
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.graveyard.clear()
	me.turns_taken = 1
	me.city_summon_turn = -1
	return me


## 牌堆：城邦放**最前面**（抽牌 pop_back，放前面才不会被抽走），后面补普通随从
func _set_deck(me: PlayerState, cities: Array[CardData]) -> void:
	me.deck.clear()
	for c in cities:
		me.deck.append(c)
	for i in 8:
		me.deck.append(_plain_minion().clone())


## 带入场效果的随从（入场效果 = 自己获得 3 点护甲，最容易量化）
func _entrance_minion(id: String = "tt_entrance", name_: String = "测试·入场随从") -> CardData:
	return _card_with_effect(int(CardData.CardType.MINION),
		[{"id": "armor", "value": 3, "target": -1}], id, name_)


func _plain_minion() -> CardData:
	return _card_with_effect(int(CardData.CardType.MINION), [], "tt_plain", "白板随从")


func _city_with_effect(effects: Array, id: String, name_: String) -> CardData:
	var c := _card_with_effect(int(CardData.CardType.CITY), effects, id, name_)
	c.health = 5
	return c


## 现造一张卡（只存在于内存，不写任何卡表文件）
func _card_with_effect(card_type: int, effects: Array, id: String, name_: String) -> CardData:
	var d := {
		"id": id,
		"card_name": name_,
		"cost": 1,
		"card_type": card_type,
		"attack": 1,
		"health": 2,
		"keywords": [],
		"effects": effects,
		"deathrattle_effects": [],
	}
	var c := CardData.from_dict(d)
	c.sync_legacy_from_chains()
	return c
