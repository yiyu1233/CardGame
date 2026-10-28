extends SceneTree
## 新一「费用 / 复制 / 牌库调度」原语测试：
##   * `hand_cost_up`：抬高某一方**全部**手牌的费用（目标是英雄 = 选哪一方）；
##   * `copy_self` / `copy_self_to_deck`：复制本随从到战场 / 到牌库；
##   * `copy_unit_to_deck` / `copy_hand_to_deck`：复制目标随从 / 目标手牌进牌库；
##   * `summon_deck_*`：从牌库检索一张符合口径的卡召唤上场（指定 ID / 费用 ≤ N / 随机）；
##   * `summon_deck_*_return`：临时登场 —— 拥有者**下一个自己的回合结束时**回到手牌。
##   * 从牌堆上场的一律**以卡面原始数值登场**（牌堆里攒下的费用 / 身材 / 关键字改动不带过来）。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/cost_copy_summon_test.gd

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
		_db.reset_to_default()
	_check(_db.cards.size() > 0, "卡表可用（%d 张）" % _db.cards.size())

	_test_registry()
	_test_hand_cost_up()
	_test_copy_self()
	_test_copy_self_respects_board_limit()
	_test_copy_self_to_deck()
	_test_copy_unit_to_deck()
	_test_copy_hand_to_deck()
	_test_summon_deck_id()
	_test_summon_deck_cost()
	_test_summon_deck_random()
	_test_summon_deck_clean_values()
	_test_summon_from_grave()
	_test_summon_deck_first()
	_test_hand_cost_limited_turns()
	_test_temporary_summon_recall()
	_test_temporary_summon_via_play_card()
	_test_temporary_summon_dies_before_recall()


# ------------------------------ 1. 注册表 ------------------------------

func _test_registry() -> void:
	var ids := [
		"hand_cost_up", "copy_self", "copy_self_to_deck", "copy_unit_to_deck",
		"copy_hand_to_deck", "summon_deck_id", "summon_deck_cost", "summon_deck_random",
		"summon_deck_id_return", "summon_deck_cost_return", "summon_deck_random_return",
	]
	var missing: Array[String] = []
	for id in ids:
		if not CardEffects.has(id):
			missing.append(id)
	_check(missing.is_empty(), "11 个新效果全部注册（缺：%s）" % ["无" if missing.is_empty() else ", ".join(missing)])
	var no_text: Array[String] = []
	for id in ids:
		if CardEffects.text(id, 2) == "":
			no_text.append(id)
	_check(no_text.is_empty(), "新效果都有卡面文本（缺：%s）" % ["无" if no_text.is_empty() else ", ".join(no_text)])
	_check(CardEffects.needs_token("summon_deck_id"), "「从牌库召唤（指定卡）」要填卡 ID")
	_check(CardEffects.needs_token("summon_deck_id_return"), "临时召唤（指定卡）也要填卡 ID")
	_check(not CardEffects.needs_token("summon_deck_cost"), "费用口径不需要卡 ID")


# ------------------------------ 2. 手牌费用 ------------------------------

func _test_hand_cost_up() -> void:
	var me := _prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	var a := _minion("cu_a", "手牌A", 3)
	var b := _minion("cu_b", "手牌B", 5)
	foe.hand.append(a)
	foe.hand.append(b)
	var mine := _minion("cu_c", "我方手牌", 4)
	me.hand.append(mine)

	var ctx := EffectContext.create(_gm, ME, 2, "", _hero_target(FOE), "测试卡")
	CardEffects.apply("hand_cost_up", ctx)
	_check(a.cost == 5 and b.cost == 7, "敌方手牌全部 +2 费（%d / %d）" % [a.cost, b.cost])
	_check(mine.cost == 4, "我方手牌不受影响（%d）" % mine.cost)

	# 反向：负值就是「费用减少」（卡面自己决定要不要用）
	var ctx_down := EffectContext.create(_gm, ME, -2, "", _hero_target(FOE), "测试卡")
	CardEffects.apply("hand_cost_up", ctx_down)
	_check(a.cost == 3 and b.cost == 5, "负值 = 费用减少（%d / %d）" % [a.cost, b.cost])

	# 对方手上没牌：不报错、也不崩，日志说明原因
	foe.hand.clear()
	_logs.clear()
	var ctx2 := EffectContext.create(_gm, ME, 3, "", _hero_target(FOE), "测试卡")
	CardEffects.apply("hand_cost_up", ctx2)
	_check(foe.hand.is_empty() and _has_log("手上没有牌"), "手牌为空时安全跳过并给出提示")


# ------------------------------ 3. 场上复制本随从 ------------------------------

func _test_copy_self() -> void:
	var me := _prepare_game()
	var card := _minion("cs1", "会分身的随从", 2, [{"id": "copy_self", "value": 2, "target": -1}])
	me.hand.append(card)
	var ok: bool = _gm.play_card(ME, me.hand.size() - 1)
	_check(ok, "打出一张「战场上复制 2 个本随从」的随从")
	_check(me.board.size() == 3, "场上 = 本体 + 2 份副本（%d）" % me.board.size())
	var n := 0
	for u in me.board:
		if u.data.id == "cs1":
			n += 1
	_check(n == 3, "三份都是同一张卡（%d）" % n)
	_check(_has_log("复制「会分身的随从」2 份上场"), "日志写明了复制数量")
	# 副本是「召唤」上场的 → 按入场规则不会再触发它的复制效果（否则会无限套娃）
	_check(me.board.size() == 3, "副本没有再次触发它的入场效果（场上仍是 %d）" % me.board.size())


func _test_copy_self_respects_board_limit() -> void:
	var me := _prepare_game()
	for i in 5:
		_gm.summon_unit(ME, _minion("fill%d" % i, "占位%d" % i, 1))
	var card := _minion("cs2", "分身2", 1, [{"id": "copy_self", "value": 3, "target": -1}])
	me.hand.append(card)
	_gm.play_card(ME, me.hand.size() - 1)
	_check(me.board.size() == _gm.BOARD_LIMIT, "复制遇到战场上限就停手（占满 %d 格）" % me.board.size())
	var n := 0
	for u in me.board:
		if u.data.id == "cs2":
			n += 1
	_check(n == 2, "本体 + 1 份副本（只塞得下一份）：%d" % n)


# ------------------------------ 4. 复制本随从进牌库 ------------------------------

func _test_copy_self_to_deck() -> void:
	var me := _prepare_game()
	for i in 3:
		me.deck.append(_minion("filler%d" % i, "牌底%d" % i, 1))
	var card := _minion("cd1", "会传宗的随从", 2, [
		{"id": "copy_self_to_deck", "value": 2, "target": -1}])
	me.hand.append(card)
	_gm.play_card(ME, me.hand.size() - 1)
	_check(me.deck.size() == 5, "牌库多了 2 张（%d）" % me.deck.size())
	_check(_count_id(me.deck, "cd1") == 2, "两张都是本随从的副本（%d）" % _count_id(me.deck, "cd1"))
	_check(me.board.size() == 1, "本体照常上场")


# ------------------------------ 5. 复制目标随从 / 手牌进牌库 ------------------------------

func _test_copy_unit_to_deck() -> void:
	var me := _prepare_game()
	var ally: BoardUnit = _gm.summon_unit(ME, _minion("src1", "被复制的随从", 4))
	_check(ally != null, "先放一个随从上场")
	var ctx := EffectContext.create(_gm, ME, 1, "", _unit_target(ally), "测试卡")
	CardEffects.apply("copy_unit_to_deck", ctx)
	_check(_count_id(me.deck, "src1") == 1, "牌库里多了一份它的副本（%d）" % _count_id(me.deck, "src1"))
	_check(me.board.size() == 1, "被复制的随从仍在场上（%d）" % me.board.size())
	var ctx3 := EffectContext.create(_gm, ME, 3, "", _unit_target(ally), "测试卡")
	CardEffects.apply("copy_unit_to_deck", ctx3)
	_check(_count_id(me.deck, "src1") == 4, "数值 = 份数（共 %d 份）" % _count_id(me.deck, "src1"))


func _test_copy_hand_to_deck() -> void:
	var me := _prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hand.append(_minion("fh1", "对方手牌1", 2))
	foe.hand.append(_minion("fh2", "对方手牌2", 3))
	var ctx := EffectContext.create(_gm, ME, 2, "", _hero_target(FOE), "测试卡")
	CardEffects.apply("copy_hand_to_deck", ctx)
	_check(me.deck.size() == 2, "我方牌库多了 2 张（%d）" % me.deck.size())
	_check(foe.hand.size() == 2, "对方手牌没有被消耗（%d）" % foe.hand.size())
	var mine_total: int = _count_id(me.deck, "fh1") + _count_id(me.deck, "fh2")
	_check(mine_total == 2, "复制的都是对方手牌里的那两张（%d）" % mine_total)


# ------------------------------ 6. 从牌库召唤 ------------------------------

func _test_summon_deck_id() -> void:
	var me := _prepare_game()
	var wanted := _minion("sid", "要找的那张", 3)
	me.deck.append(_minion("other", "另一张", 3))
	me.deck.append(wanted)
	var u: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_ID, 0, "sid", false)
	_check(u != null and u.data.id == "sid", "按 ID 从牌库召唤出了指定那张（%s）" % (
		"没找到" if u == null else u.data.card_name))
	_check(_count_id(me.deck, "sid") == 0, "它已经从牌库里移出（剩 %d）" % _count_id(me.deck, "sid"))
	_check(me.deck.size() == 1, "牌库里只剩另一张（%d）" % me.deck.size())
	_check(u != null and u.recall_turn == -1, "不是临时召唤：recall_turn = %d" % (
		-1 if u == null else u.recall_turn))

	# 牌库里没有这张卡：不召唤、牌库不动
	var before: int = me.deck.size()
	var nope: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_ID, 0, "不存在", false)
	_check(nope == null and me.deck.size() == before, "指定卡不在牌库里时不召唤，牌库也不受影响")


func _test_summon_deck_cost() -> void:
	var me := _prepare_game()
	me.deck.append(_minion("big", "高费随从", 8))
	me.deck.append(_minion("small", "低费随从", 1))
	var u: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_COST, 3, "", false)
	_check(u != null and u.data.id == "small", "只挑费用 ≤ 3 的那个（%s）" % (
		"没找到" if u == null else u.data.card_name))
	_check(me.deck.size() == 1, "被召唤的那张离开了牌库（剩 %d）" % me.deck.size())


func _test_summon_deck_random() -> void:
	var me := _prepare_game()
	me.deck.append(_minion("r1", "随机候选1", 4))
	me.deck.append(_minion("r2", "随机候选2", 4))
	var u: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_RANDOM, 0, "", false)
	_check(u != null, "随机从牌库召唤了一个随从上场")
	_check(me.board.size() == 1 and me.deck.size() == 1, "上场 1 个 / 牌库少 1 张（%d / %d）" % [
		me.board.size(), me.deck.size()])
	# 留在战场：跨回合不会自己消失
	_gm.current_player = ME
	_gm._next_turn()
	_check(me.board.size() == 1, "它是普通召唤：回合结束后仍留在场上（%d）" % me.board.size())


## 从牌堆召唤上场的：登场数值以卡表为准，牌堆里攒下的改动不带过来
func _test_summon_deck_clean_values() -> void:
	var base := _minion("clean_from_deck", "牌库改造过的随从", 4)
	_db.add_card(base)
	var me := _prepare_game()
	var dirty: CardData = base.clone()
	dirty.cost = 1
	dirty.attack = 6
	dirty.health = 7
	dirty.keywords.append(CardData.Keyword.WINDFURY)
	me.deck.append(dirty)
	_check(dirty.cost == 1 and dirty.attack == 6 and dirty.has_mechanic(
		CardData.Keyword.WINDFURY), "牌库里那张副本确实被改过（%d 费 / %d-%d）" % [
			dirty.cost, dirty.attack, dirty.health])

	var u: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_ID, 0,
		"clean_from_deck", false)
	_check(u != null, "按 ID 从牌库召唤出它")
	if u != null:
		_check(u.data.cost == 4, "费用按卡表来（%d）" % u.data.cost)
		_check(u.attack == 2 and u.health == 3 and u.max_health == 3,
			"身材按卡表来（%d/%d，上限 %d）" % [u.attack, u.health, u.max_health])
		_check(not u.has_mechanic(CardData.Keyword.WINDFURY), "在牌库里被赋予的风怒没有跟着上场")
	_db.remove_card(base.id)


# ------------------------------ 6b. 来源限定：墓地 / 牌库优先→墓地 ------------------------------

func _test_summon_from_grave() -> void:
	var me := _prepare_game()
	me.graveyard.append(_minion("g1", "墓地里的随从", 2))
	me.deck.append(_minion("d1", "牌库里的随从", 2))
	# 来源 = 墓地：只能翻墓地，牌库里那张不会动
	var u: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_ID, 0, "g1",
		EffectContext.SRC_GRAVE, false)
	_check(u != null and u.data.id == "g1", "从墓地亡招出了那张卡（%s）" % (
		"没找到" if u == null else u.data.card_name))
	_check(me.graveyard.size() == 0, "它离开了墓地（剩 %d 张）" % me.graveyard.size())
	_check(me.deck.size() == 1, "牌库没有被翻动（剩 %d 张）" % me.deck.size())

	# 来源 = 墓地时，牌库里的卡看不见（这是「限定」的意义所在）
	var none: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_ID, 0, "d1",
		EffectContext.SRC_GRAVE, false)
	_check(none == null and me.deck.size() == 1, "限定墓地时看不到牌库里的卡")

	# 费用口径同样能从墓地挑
	me.graveyard.append(_minion("g2", "墓地低费随从", 1))
	me.graveyard.append(_minion("g3", "墓地高费随从", 9))
	var cheap: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_COST, 3, "",
		EffectContext.SRC_GRAVE, false)
	_check(cheap != null and cheap.data.id == "g2", "按费用 ≤ 3 从墓地挑中低费那个（%s）" % (
		"没找到" if cheap == null else cheap.data.card_name))

	# 从墓地出来的临时召唤：召回时进手牌，而不是回到墓地
	me.graveyard.append(_minion("g4", "墓地里被临时召唤的随从", 2))
	var temp: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_ID, 0, "g4",
		EffectContext.SRC_GRAVE, true)
	_check(temp != null and temp.recall_turn > 0, "临时召唤可以指定墓地来源")
	_gm.current_player = ME
	_gm._next_turn()
	_gm._next_turn()
	_gm._next_turn()
	_check(_count_id(me.hand, "g4") == 1, "到期回到手牌（%d）" % _count_id(me.hand, "g4"))
	_check(_count_id(me.graveyard, "g4") == 0, "回的是手牌，不是回墓地（%d）" % (
		_count_id(me.graveyard, "g4")))


func _test_summon_deck_first() -> void:
	var me := _prepare_game()
	me.deck.append(_minion("p1", "牌库里的城邦替代品", 2))
	me.graveyard.append(_minion("q1", "墓地里的同一张", 2))
	# 牌库里有 → 只动牌库
	var first: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_ID, 0, "p1",
		EffectContext.SRC_DECK_FIRST, false)
	_check(first != null and first.data.id == "p1", "牌库优先：先用牌库里的那张")
	_check(me.deck.size() == 0 and me.graveyard.size() == 1, "牌库那张被用掉，墓地那张没动")
	# 牌库里没有 → 兜底翻墓地（与城邦格的规则同一套口径）
	var fallback: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_ID, 0, "q1",
		EffectContext.SRC_DECK_FIRST, false)
	_check(fallback != null and fallback.data.id == "q1", "牌库没有时兜底从墓地召唤（%s）" % (
		"没找到" if fallback == null else fallback.data.card_name))
	_check(me.graveyard.size() == 0, "墓地里那张被亡招出来（剩 %d）" % me.graveyard.size())
	# 两边都没有 → 什么都不做
	var none: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_ID, 0, "不存在",
		EffectContext.SRC_DECK_FIRST, false)
	_check(none == null and me.board.size() == 2, "两边都没有时不召唤（场上 %d）" % me.board.size())


# ------------------------------ 6c. 持续回合数限定 ------------------------------

func _test_hand_cost_limited_turns() -> void:
	var me := _prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	var a := _minion("t30", "敌方手牌A", 3)
	var b := _minion("t31", "敌方手牌B", 5)
	foe.hand.append(a)
	foe.hand.append(b)

	# 限时 1 个回合：期间 +2，到期自动还原
	var ctx := EffectContext.create(_gm, ME, 2, "", _hero_target(FOE), "测试卡",
		false, null, 0, 1)
	CardEffects.apply("hand_cost_up", ctx)
	_check(a.cost == 5 and b.cost == 7, "限时费用 +2 立即生效（%d / %d）" % [a.cost, b.cost])
	_check(CardEffects.text("hand_cost_up", 2, 0, 1).contains("持续到目标一方第 1 个回合结束"),
		"卡面文本写明了限时（%s）" % CardEffects.text("hand_cost_up", 2, 0, 1))
	# 我方回合结束：对手的限制不动（各算各的回合）
	_gm.current_player = ME
	_gm._next_turn()
	_check(a.cost == 5 and b.cost == 7, "我方回合结束时对手的限制还没到期（%d）" % a.cost)
	# 轮到对手，对手回合结束 → 到期还原
	_check(_gm.current_player == FOE, "现在是对手的回合")
	_gm._next_turn()
	_check(a.cost == 3 and b.cost == 5, "对手的第 1 个回合结束时费用还原（%d / %d）" % [a.cost, b.cost])
	_check(_has_log("手牌费用恢复了 -2"), "还原有日志")

	# 到期时已经被打出的卡不受影响：鼓两张牌，先把 A 打出再等还原
	var me2 := _prepare_game()
	foe = _gm.get_player(FOE)
	var c1 := _minion("t40", "限时A", 4)
	var c2 := _minion("t41", "限时B", 4)
	foe.hand.append(c1)
	foe.hand.append(c2)
	var ctx2 := EffectContext.create(_gm, ME, 3, "", _hero_target(FOE), "测试卡",
		false, null, 0, 1)
	CardEffects.apply("hand_cost_up", ctx2)
	_check(c1.cost == 7 and c2.cost == 7, "两张都 +3（%d / %d）" % [c1.cost, c2.cost])
	foe.hand.erase(c1)                       # 模拟「A 已经被打出」
	_gm.current_player = ME
	_gm._next_turn()                         # 我方回合结束 → 对手回合开始（turns_taken +1）
	_gm._next_turn()                         # 对手回合结束 → 到期还原
	_check(c2.cost == 4, "还在手上的那张被还原（%d）" % c2.cost)
	_check(c1.cost == 7, "已经打出（不在手上）的那张不被还原（%d）" % c1.cost)

	# turns = 0 仍然是永久版（老卡表口径不变）
	var me3 := _prepare_game()
	foe = _gm.get_player(FOE)
	var forever := _minion("t50", "永久版", 4)
	foe.hand.append(forever)
	var ctx3 := EffectContext.create(_gm, ME, 2, "", _hero_target(FOE), "测试卡",
		false, null, 0, 0)
	CardEffects.apply("hand_cost_up", ctx3)
	_gm.current_player = FOE
	_gm._next_turn()
	_gm._next_turn()
	_check(forever.cost == 6, "持续回合数 0 = 永久，跨多个回合也不还原（%d）" % forever.cost)
	var _unused_a := me
	var _unused_b := me2
	var _unused_c := me3


# ------------------------------ 7. 临时召唤（瞬念召唤式） ------------------------------

func _test_temporary_summon_recall() -> void:
	var me := _prepare_game()
	me.deck.append(_minion("temp1", "临时登场随从", 3))
	var u: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_ID, 0, "temp1", true)
	_check(u != null, "从牌库临时召唤出一个随从")
	if u == null:
		return
	var uid: int = u.unit_id
	_check(u.recall_turn > _gm.turn_count, "它被标记为临时单位（召回回合 %d > 当前 %d）" % [
		u.recall_turn, _gm.turn_count])

	# 我方回合结束（第一个）：不该召回
	_gm.current_player = ME
	_gm._next_turn()
	_check(_gm.find_unit(uid) != null, "召唤当回合结束时不会召回（还在场上）")
	# 对手回合结束：也召不回来（只有擁有者自己的回合结束才算）
	_check(_gm.current_player == FOE, "轮到对手")
	_gm._next_turn()
	_check(_gm.find_unit(uid) != null, "对手回合结束时不会召回它")
	_check(_gm.current_player == ME, "又轮到我方")
	# 我方（拥有者）下一个回合结束：召回
	_gm._next_turn()
	_check(_gm.find_unit(uid) == null, "我方下一个回合结束时它回到了手牌")
	_check(_count_id(me.hand, "temp1") == 1, "它现在在我方手牌里（%d 张）" % _count_id(me.hand, "temp1"))
	_check(_has_log("临时召唤到期"), "日志写明了为什么回手")


## 走真实出牌流程：卡面里写上这条效果也能用（管理员做卡时的两条路径之一）
func _test_temporary_summon_via_play_card() -> void:
	var me := _prepare_game()
	me.deck.append(_minion("tp1", "牌库低费打工仔", 2))
	var card := _minion("tp0", "临时召唤干活", 4, [
		{"id": "summon_deck_cost_return", "value": 3, "target": -1}])
	me.hand.append(card)
	var ok: bool = _gm.play_card(ME, me.hand.size() - 1)
	_check(ok, "打出一张「临时召唤一个费用 ≤ 3 的随从」的随从")
	_check(me.board.size() == 2, "场上 = 本体 + 召唤来的临时随从（%d）" % me.board.size())
	var called: BoardUnit = null
	for u in me.board:
		if str(u.data.id) == "tp1":
			called = u
	_check(called != null and called.recall_turn > 0, "召唤来的那个是临时单位（recall_turn %d）" % (
		-1 if called == null else called.recall_turn))
	_gm.current_player = ME
	_gm._next_turn()          # 我方回合结束
	_gm._next_turn()          # 对手回合结束 → 回到我方
	_gm._next_turn()          # 我方（拥有者）下一个回合结束 → 召回
	_check(_count_id(me.hand, "tp1") == 1, "到期后临时随从进了手牌（%d）" % _count_id(me.hand, "tp1"))
	_check(me.board.size() == 1, "场上只剩本体（%d）" % me.board.size())


func _test_temporary_summon_dies_before_recall() -> void:
	var me := _prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	me.deck.append(_minion("temp2", "短命的临时随从", 3))
	var u: BoardUnit = _gm.summon_from_deck(ME, EffectContext.DECK_FILTER_ID, 0, "temp2", true)
	_check(u != null, "临时召唤出一个随从")
	if u == null:
		return
	u.health = 0
	_gm._cleanup_deaths()
	_check(_gm.find_unit(u.unit_id) == null, "它先被打死了")
	_gm.current_player = ME
	_gm._next_turn()
	_gm._next_turn()
	_check(_count_id(me.hand, "temp2") == 0, "死了的临时单位不会被召回手牌（%d）" % _count_id(me.hand, "temp2"))
	_check(_has_log("短命的临时随从"), "墓地 / 结算照常")
	var _unused := foe


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
	print("=== 费用 / 复制 / 牌库调度测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _has_log(keyword: String) -> bool:
	for l in _logs:
		if l.contains(keyword):
			return true
	return false


func _prepare_game() -> PlayerState:
	_gm.new_game()
	_gm.log_enabled = true
	_logs.clear()
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	for p in [me, foe]:
		p.max_mana = 10
		p.mana = 10
		p.hand.clear()
		p.board.clear()
		p.graveyard.clear()
		p.deck.clear()
	me.turns_taken = 1
	me.city_summon_turn = -1
	return me


func _unit_target(u: BoardUnit) -> Dictionary:
	return {"kind": "unit", "unit_id": u.unit_id, "player_id": u.owner_id}


func _hero_target(pid: int) -> Dictionary:
	return {"kind": "hero", "unit_id": -1, "player_id": pid}


func _count_id(list: Array, card_id: String) -> int:
	var n := 0
	for c in list:
		if c is CardData and str(c.id) == card_id:
			n += 1
	return n


## 现造一张随从（只存在于内存，不写任何卡表文件）
func _minion(id: String, name_: String, cost: int = 2, effects: Array = []) -> CardData:
	var d := {
		"id": id,
		"card_name": name_,
		"cost": cost,
		"card_type": int(CardData.CardType.MINION),
		"attack": 2,
		"health": 3,
		"keywords": [],
		"effects": effects,
		"deathrattle_effects": [],
	}
	var c := CardData.from_dict(d)
	c.sync_legacy_from_chains()
	return c
