extends SceneTree
## 战斗限制 / 减免 / 禁锢 / 化身 / 离场计数测试。
##
## 覆盖：
##   * 最大生命 ≤ 0 同样被破坏（进墓地）；
##   * 伤害减免：能力伤害减免 / 碰撞伤害减免分开计算；
##   * 禁锢：入场 / 退场能力不发动，不能被打出 / 召唤，身材仍可加减；
##   * 化身：目标随从原地变成指定随从，不触发离场 / 入场，不计入离场 / 被破坏；
##   * 离场 ≠ 被破坏：消失计入离场、不计入被破坏；离场能力不受沉默影响；
##   * 墓地：进入墓地的累计张数只增不减；同名卡按每一张单独计算；从墓地召唤不回退计数。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/combat_effect_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _fail_lines: Array[String] = []
var _created: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		_phase = 1
		return false
	if _phase == 1 and _frames >= 4:
		_phase = 2
		_run()
		_finish()
		return false
	return _frames > 900


func _run() -> void:
	_seed_cards()
	_test_max_health_death()
	_test_damage_reduction()
	_test_imprison()
	_test_transform()
	_test_leave_vs_destroy()
	_test_vanish_counts_as_leave()
	_test_silence_keeps_leave()
	_test_grave_counters()
	_cleanup()
	_finish_cards()


# ------------------------------ 造卡 ------------------------------

func _seed_cards() -> void:
	# 上次跑测试如果中途退出，卡表里可能留下 ce_* 的卡：先清掉，避免重名被自动改名后残留
	for c in _db.cards.duplicate():
		if str(c.id).begins_with("ce_"):
			_db.remove_card(c.id)
	_add(_minion("ce_src", "测试·禁相随从", 2, 3,
		[{"id": "armor", "value": 1, "target": -1}],
		[{"id": "armor", "value": 2, "target": -1}]))
	_add(_minion("ce_form", "测试·化身目标", 4, 4))
	# 「消失」测试卡**不进卡表**：它配了“手牌 ≥ 0”的瞬念召唤，进了卡表会污染每一局自动配牌
	_add(_minion("ce_bigcost", "测试·大牌", 1, 1))


func _minion(id: String, name_: String, atk: int, hp: int, effects: Array = [],
		death: Array = [], invocation: Dictionary = {}) -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": 1,
		"card_type": CardData.CardType.MINION, "attack": atk, "health": hp,
		"keywords": [], "effects": effects, "deathrattle_effects": death,
	})
	c.invocation = invocation
	# 离场触发：与亡语分开记一笔（用来验证“离场能力不受沉默影响”/禁锢时都不发动）
	c.triggers = [{"on": CardTriggers.EV_LEAVE, "effects": [{"id": "armor", "value": 4, "target": -1}]}]
	c.sync_legacy_from_chains()
	return c


func _add(c: CardData) -> void:
	if _db.add_card(c):
		_created.append(c.id)


func _fresh(id: String) -> CardData:
	var c: CardData = _db.get_card(id)
	return c.clone() if c != null else null


## 「消失」测试卡：不进卡表，只放进这一局的牌库里
func _vanish_card() -> CardData:
	return _minion("ce_vanish", "测试·消失卡", 3, 3,
		[], [], {"enabled": true, "timing": InvokeConditions.TIME_ANY,
			"metric": "hand", "op": ">=", "value": 0, "destination": CardData.InvokeDest.KEEP})


# ------------------------------ 最大生命归零 ------------------------------

func _test_max_health_death() -> void:
	var me := _prepare()
	var foe = _gm.get_player(FOE)
	var u: BoardUnit = _gm.summon_unit(FOE, _fresh("ce_form"))
	_check(u != null, "先放一个随从当测试对象")
	# 把最大生命压到 0：按规则同样要被破坏
	var ctx := EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": FOE})
	ctx.buff_unit(u, 0, -u.health)
	_check(u.max_health <= 0, "最大生命被压到 ≤ 0（%d）" % u.max_health)
	_gm._cleanup_deaths()
	_check(not u.is_alive(), "最大生命 ≤ 0 → 被破坏")
	_check(foe.graveyard.size() == 1, "最大生命归零的随从进入墓地（%d）" % foe.graveyard.size())
	_check(foe.units_died_total == 1, "计入被破坏数（%d）" % foe.units_died_total)


# ------------------------------ 伤害减免 ------------------------------

func _test_damage_reduction() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(FOE, _fresh("ce_form"))
	u.ability_damage_reduction = 3
	var ability: int = _gm.deal_damage_to_unit(null, u, 5, false)
	_check(ability == 2, "能力伤害 5 - 减免 3 = 2（实际 %d）" % ability)
	u.collision_damage_reduction = 4
	var combat: int = _gm.deal_damage_to_unit(null, u, 6, true)
	_check(combat == 2, "碰撞伤害 6 - 减免 4 = 2（实际 %d）" % combat)
	# 两种减免互不串用
	u.ability_damage_reduction = 0
	u.collision_damage_reduction = 4
	var ability2: int = _gm.deal_damage_to_unit(null, u, 3, false)
	_check(ability2 == 3, "碰撞减免不影响能力伤害（实际 %d）" % ability2)


# ------------------------------ 禁锢 ------------------------------

func _test_imprison() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("ce_src"))
	_check(u != null, "先召唤带入场 / 亡语 / 离场触发的随从")
	u.data.imprisoned = true
	me.armor = 0
	# 入场能力不发动
	_check(not _gm.trigger_entrance_effect(u), "禁锢：入场能力不发动")
	_check(me.armor == 0, "禁锢：入场效果没有结算（护甲 %d）" % me.armor)
	# 身材仍可加减
	var ctx := EffectContext.create(_gm, ME, 0, "", {"kind": "self", "unit_id": -1, "player_id": ME})
	ctx.buff_unit(u, 1, 1)
	_check(u.attack == 3 and u.health == 4, "禁锢：身材仍可加减（%d/%d）" % [u.attack, u.health])
	# 被破坏：进墓地，但退场能力（亡语 + 离场触发）都不发动
	ctx.kill_unit(u)
	_gm._cleanup_deaths()
	_check(not u.is_alive(), "禁锢：仍然会被破坏")
	_check(me.armor == 0, "禁锢：亡语 / 离场能力都不发动（护甲 %d）" % me.armor)
	_check(me.units_died_total == 1 and me.units_left_total == 1,
		"禁锢：被破坏 / 离场计数照常（%d / %d）" % [me.units_died_total, me.units_left_total])
	_check(me.graveyard.size() == 1, "禁锢：进墓地照常（%d）" % me.graveyard.size())

	# 禁锢的卡不能被召唤
	var locked := _fresh("ce_src")
	locked.imprisoned = true
	var before_grave := me.graveyard.size()
	_check(_gm.summon_unit(ME, locked) == null, "禁锢：无法被召唤出来")
	_check(me.graveyard.size() == before_grave, "禁锢：召唤失败不会把卡丢进墓地")

	# 禁锢的卡不能被打出
	me.hand.clear()
	me.hand.append(locked)
	var mana_before: int = me.mana
	_check(not _gm.play_card(ME, 0), "禁锢：无法从手牌打出")
	_check(me.hand.size() == 1 and me.mana == mana_before, "禁锢：手牌与法力都没被消耗")


# ------------------------------ 化身 ------------------------------

func _test_transform() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("ce_src"))
	var slot: int = me.slot_of(u)
	var left_before: int = me.units_left_total
	var died_before: int = me.units_died_total
	var nu: BoardUnit = _gm.transform_unit(u, "ce_form")
	_check(nu != null, "化身：执行成功")
	if nu == null:
		return
	_check(nu.data.id == "ce_form", "化身：变成指定的卡（%s）" % nu.data.id)
	_check(me.slot_of(nu) == slot, "化身：留在原来的格子（%d）" % me.slot_of(nu))
	_check(nu.attack == 4 and nu.health == 4, "化身：身材换成新卡（%d/%d）" % [nu.attack, nu.health])
	_check(me.units_left_total == left_before, "化身：不计入离场")
	_check(me.units_died_total == died_before, "化身：不计入被破坏")
	_check(me.graveyard.is_empty(), "化身：旧卡不进墓地")
	var line := CardEffects.text("transform", 0, 0, 0, "ce_form")
	_check(line.contains("化身") and line.contains("测试·化身目标"), "化身：卡面文本带目标卡名（%s）" % line)


# ------------------------------ 离场 ≠ 被破坏 ------------------------------

func _test_leave_vs_destroy() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("ce_form"))
	_gm.return_unit_to_hand(u)
	_check(me.units_left_total == 1, "回手：计入离场（%d）" % me.units_left_total)
	_check(me.units_died_total == 0, "回手：不计入被破坏（%d）" % me.units_died_total)

	var me2 := _prepare()
	var u2: BoardUnit = _gm.summon_unit(ME, _fresh("ce_form"))
	EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u2.unit_id, "player_id": ME}).kill_unit(u2)
	_gm._cleanup_deaths()
	_check(me2.units_left_total == 1 and me2.units_died_total == 1,
		"被破坏：离场与被破坏都 +1（%d / %d）" % [me2.units_left_total, me2.units_died_total])


func _test_vanish_counts_as_leave() -> void:
	var me := _prepare()
	# 填满 7 格 → 瞬念召唤没有空位 → 这张卡“消失”
	for i in 7:
		_gm.summon_unit(ME, _fresh("ce_bigcost"))
	_check(_gm.board_size_used(ME) == 7, "先填满战场")
	var card := _vanish_card()
	me.deck.clear()
	me.deck.append(card)
	var grave_before: int = me.graveyard.size()
	_gm._try_invoke(ME, [InvokeConditions.TIME_ANY])
	_check(not me.deck.has(card), "瞬念召唤：没有空位 → 卡从牌库消失")
	_check(me.units_left_total == 1, "消失：计入离场（%d）" % me.units_left_total)
	_check(me.units_died_total == 0, "消失：不计入被破坏（%d）" % me.units_died_total)
	_check(me.graveyard.size() == grave_before, "消失：不进墓地（%d）" % me.graveyard.size())


func _test_silence_keeps_leave() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("ce_src"))
	u.silence()
	me.armor = 0
	EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": ME}).kill_unit(u)
	_gm._cleanup_deaths()
	# 亡语 2 + 离场触发 4 = 6：沉默只清词条 / 身材，不影响离场能力
	_check(me.armor == 6, "沉默不影响离场能力（亡语 2 + 离场 4 = %d）" % me.armor)


# ------------------------------ 墓地计数 ------------------------------

func _test_grave_counters() -> void:
	var me := _prepare()
	# 1) 抽牌爆牌 → 进墓地
	var burn := _fresh("ce_form")
	me.hand.clear()
	for i in int(_gm.HAND_LIMIT):
		me.hand.append(_fresh("ce_bigcost"))
	me.deck.clear()
	me.deck.append(burn)
	var total_before: int = me.grave_entered_total
	_gm.draw(ME, 1)
	_check(me.grave_entered_total == total_before + 1, "爆牌：计入墓地进入数（%d）" % me.grave_entered_total)
	_check(me.grave_count("ce_form") == 1, "爆牌：按卡 id 单独计数（%d）" % me.grave_count("ce_form"))

	# 2) 同名卡分别计算：两张同名进墓地 → 计数 2
	var a := _fresh("ce_form")
	var b := _fresh("ce_form")
	me.graveyard.clear()
	me.grave_entered_total = 0
	me.grave_entered.clear()
	me.note_grave_entered(a)
	me.note_grave_entered(b)
	_check(me.grave_entered_total == 2, "墓地：两张同名卡各算一张（%d）" % me.grave_entered_total)
	_check(me.grave_count("ce_form") == 2, "墓地：同名卡累计 2 次（%d）" % me.grave_count("ce_form"))

	# 3) 从墓地召唤：当前墓地减少，但累计计数不变（“被破坏 / 进墓地数”不回退）
	me.board.clear()
	me.reset_slots()
	var total_now: int = me.grave_entered_total
	var u: BoardUnit = _gm.summon_from_source(ME, EffectContext.DECK_FILTER_RANDOM, 0, "",
		EffectContext.SRC_GRAVE, false)
	_check(u != null, "从墓地召唤成功")
	_check(me.graveyard.size() == 1, "从墓地召唤后当前墓地剩 1 张（%d）" % me.graveyard.size())
	_check(me.grave_entered_total == total_now and me.grave_count("ce_form") == 2,
		"从墓地召唤不回退累计计数（%d / %d）" % [me.grave_entered_total, me.grave_count("ce_form")])


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> PlayerState:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.reset_slots()
	me.graveyard.clear()
	me.grave_entered_total = 0
	me.grave_entered.clear()
	me.units_died_turn = 0
	me.units_died_total = 0
	me.units_left_turn = 0
	me.units_left_total = 0
	me.deck.clear()
	for i in 6:
		me.deck.append(_fresh("ce_bigcost"))
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hand.clear()
	foe.board.clear()
	foe.reset_slots()
	foe.graveyard.clear()
	foe.grave_entered_total = 0
	foe.grave_entered.clear()
	foe.units_died_turn = 0
	foe.units_died_total = 0
	foe.units_left_turn = 0
	foe.units_left_total = 0
	foe.deck.clear()
	for i in 6:
		foe.deck.append(_fresh("ce_bigcost"))
	return me


func _cleanup() -> void:
	# 清掉可能残留的场上单位，避免影响下一项
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		if p == null:
			continue
		p.board.clear()
		p.reset_slots()
		p.hand.clear()
		p.graveyard.clear()
		p.deck.clear()


func _finish_cards() -> void:
	for id in _created:
		_db.remove_card(id)


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
	print("=== 战斗效果测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
