extends SceneTree
## 效果链 / 主动技能规则测试（规则层自测）。
##
## 覆盖：
##   1. 链顺序：战吼 = [直伤打脸 2, 消灭敌方随从]，按顺序结算（日志顺序断言「先伤害后消灭」）；
##   2. 自动选目标：链里需要选目标的那条没指定 / 指定得不合法 → 自动挑第一个合法目标并记日志；
##      该条一个合法目标都没有 → 跳过这一条且不崩；
##   3. 亡语链：两条效果的亡语随从死亡 → 都结算、顺序正确；
##   4. 旧卡兼容：只有 effect_id / deathrattle_id 的老卡，行为与卡面文本与改动前逐字一致；
##   5. 主动技能：能量点不足 / 够 / 每回合一次 / 下一回合可再发动 / 横置 / 冻结 / 不是你的回合 /
##      别人的单位；护符与城邦的技能同样能发动；skill_blocked_reason() 的口径；
##   6. 存档往返：to_dict → from_dict → clone() 后 effects / deathrattle_effects / skill_chain()
##      的内容与顺序都不变。
##
## 运行：godot --headless --path <项目目录> --script res://tools/chain_skill_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _gm
var _db
var _logs: Array[String] = []
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		if _gm == null or _db == null:
			_check(false, "GameManager / CardDB 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_gm.log_message.connect(func(text: String) -> void: _logs.append(text))
		_run()
		_finish()
		return true
	return _frames > 400


func _run() -> void:
	_test_chain_order()
	_test_multi_effect_values()
	_test_auto_target()
	_test_deathrattle_chain()
	_test_legacy_compat()
	_test_skill_gates()
	_test_skill_costs_and_turn_limit()
	_test_skill_on_permanent_and_city()
	_test_save_roundtrip()
	print("=== 效果链 / 主动技能测试结束：失败 %d 项 ===" % _fails)


# ------------------------------ 1. 链顺序 ------------------------------

func _test_chain_order() -> void:
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var victim: BoardUnit = _spawn(FOE, "c001", 501)          # 2/3 随从，用来被消灭
	var before_hp: int = foe.hero_hp

	# 卡表里现成的示例卡：c111「烈焰使者」= 战吼 [对敌方英雄 2 点伤害, 消灭一个敌方随从]
	var card: CardData = _db.get_card("c111")
	_check(card != null, "卡表里有管理员做的多段效果示例卡 c111")
	if card == null:
		return
	var chain: Array[Dictionary] = card.effect_chain()
	_check(chain.size() == 2, "c111 的战吼是两条效果（%d）" % chain.size())
	_check(str(chain[0].get("id", "")) == "damage_hero" and str(chain[1].get("id", "")) == "destroy",
		"链的顺序：先 damage_hero，再 destroy")
	_check(card.effect_text() == "对敌方英雄造成 2 点伤害；消灭目标随从",
		"链文本用「；」连接（%s）" % card.effect_text())
	_check(card.effect_id == "damage_hero" and card.value == 2,
		"老字段镜像到链首（effect_id=%s value=%d）" % [card.effect_id, card.value])

	_give_card(ME, card)
	var idx: int = _gm.get_player(ME).hand.size() - 1
	_logs.clear()
	var ok: bool = _gm.play_card(ME, idx, victim.unit_id, FOE)
	_check(ok, "带效果链的随从成功打出")
	_check(foe.hero_hp == before_hp - 2, "第一条结算：敌方英雄掉 2（%d -> %d）" % [before_hp, foe.hero_hp])
	_check(_gm.find_unit(victim.unit_id) == null and foe.board.is_empty(), "第二条结算：敌方随从被消灭")
	var i_dmg := _index_of("英雄剩余生命")
	var i_kill := _index_of("被消灭")
	_check(i_dmg >= 0 and i_kill >= 0 and i_dmg < i_kill,
		"日志顺序：先伤害（第 %d 行）后消灭（第 %d 行）" % [i_dmg, i_kill])


# ------------------------------ 1b. 每条效果用自己的数值 ------------------------------

func _test_multi_effect_values() -> void:
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var before_hp: int = foe.hero_hp
	var card := _custom({
		"id": "t_multi", "card_name": "多段数值测试", "card_type": 1, "cost": 0, "target": 0,
		"effect_id": "none", "value": 0,
		"effects": [
			{"id": "damage_hero", "value": 5, "target": 0, "token": ""},
			{"id": "damage_hero", "value": 2, "target": 0, "token": ""},
		],
	})
	_check(card.value == 5, "老字段 value 只镜像链首（%d）" % card.value)
	_give_card(ME, card)
	var idx: int = _gm.get_player(ME).hand.size() - 1
	_check(_gm.play_card(ME, idx), "多段法术成功打出")
	_check(foe.hero_hp == before_hp - 7, "两条各用自己的 value（5 + 2 = 7，实际掉 %d）" % (before_hp - foe.hero_hp))

	# 带效果链的卡 + 连击（老机制）：连击只结算 combo_effect_id，不能把整条链再打一遍
	_prepare()
	foe = _gm.get_player(FOE)
	before_hp = foe.hero_hp
	var combo_card := _custom({
		"id": "t_combo", "card_name": "链加连击测试", "card_type": 1, "cost": 0, "target": 0,
		"effect_id": "none", "value": 0,
		"combo_effect_id": "damage_hero", "combo_value": 1,
		"effects": [{"id": "damage_hero", "value": 5, "target": 0, "token": ""}],
	})
	_gm.get_player(ME).cards_played_turn = 1          # 模拟本回合已经打出过别的牌（触发连击）
	_give_card(ME, combo_card)
	idx = _gm.get_player(ME).hand.size() - 1
	_check(_gm.play_card(ME, idx), "带链的连击卡成功打出")
	_check(foe.hero_hp == before_hp - 6,
		"链打 5 + 连击打 1 = 6（实际掉 %d；不能把整条链再打一遍）" % (before_hp - foe.hero_hp))


# ------------------------------ 2. 自动选目标 ------------------------------

func _test_auto_target() -> void:
	# 2a) 玩家只选了英雄：第二条需要目标 → 自动挑第一个敌方随从
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var victim: BoardUnit = _spawn(FOE, "c001", 601)
	var hp_before: int = foe.hero_hp
	var card := _custom({
		"id": "t_auto", "card_name": "自动选目标测试", "card_type": 1, "cost": 0, "target": 0,
		"effect_id": "none", "value": 0,
		"effects": [
			{"id": "damage", "value": 2, "target": CardData.Targeting.ANY_CHARACTER},
			{"id": "destroy", "value": 0, "target": CardData.Targeting.ENEMY_MINION},
		],
	})
	_check(card.needs_target(), "链里有需要选目标的效果 → 这张牌需要选目标")
	_check(_gm.get_valid_targets(ME, card).size() >= 2, "出牌目标列表是链里各条的并集")
	_give_card(ME, card)
	var idx: int = _gm.get_player(ME).hand.size() - 1
	_logs.clear()
	_check(_gm.play_card(ME, idx, -1, FOE), "只选敌方英雄也能打出（第二条会自动选目标）")
	_check(foe.hero_hp == hp_before - 2, "第一条打在玩家选的英雄上（%d）" % foe.hero_hp)
	_check(_gm.find_unit(victim.unit_id) == null, "第二条自动挑了那个敌方随从并消灭")
	_check(_has_log("自动选择目标"), "日志里写明「自动选择目标」")

	# 2b) 该条没有任何合法目标 → 跳过这一条且不崩
	_prepare()
	foe = _gm.get_player(FOE)
	hp_before = foe.hero_hp
	_check(foe.board.is_empty(), "敌方场上没有任何随从")
	var card2 := _custom({
		"id": "t_auto2", "card_name": "无目标跳过测试", "card_type": 1, "cost": 0, "target": 0,
		"effect_id": "none", "value": 0,
		"effects": [
			{"id": "damage", "value": 2, "target": CardData.Targeting.ANY_CHARACTER},
			{"id": "destroy", "value": 0, "target": CardData.Targeting.ENEMY_MINION},
		],
	})
	_give_card(ME, card2)
	idx = _gm.get_player(ME).hand.size() - 1
	_logs.clear()
	_check(_gm.play_card(ME, idx, -1, FOE), "没有敌方随从时仍然打得出（链没崩）")
	_check(foe.hero_hp == hp_before - 2, "第一条照常结算（%d）" % foe.hero_hp)
	_check(_has_log("没有合法目标"), "没有合法目标的那条被跳过并记日志")


# ------------------------------ 3. 亡语链 ------------------------------

func _test_deathrattle_chain() -> void:
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var me: PlayerState = _gm.get_player(ME)
	var card := _custom({
		"id": "t_dr", "card_name": "亡语链测试", "card_type": 0, "attack": 1, "health": 1,
		"effect_id": "none", "target": 0, "deathrattle_id": "none",
		"deathrattle_effects": [
			{"id": "damage_hero", "value": 3, "target": 0, "token": ""},
			{"id": "armor", "value": 2, "target": 0, "token": ""},
		],
	})
	_check(card.deathrattle_text() == "亡语：对敌方英雄造成 3 点伤害；获得 2 点护甲",
		"亡语文本用「；」连接（%s）" % card.deathrattle_text())
	_check(card.deathrattle_id == "damage_hero" and card.death_value == 3,
		"亡语老字段镜像到链首（%s / %d）" % [card.deathrattle_id, card.death_value])
	var u: BoardUnit = _spawn_card(ME, card, 701)
	var hp_before: int = foe.hero_hp
	var armor_before: int = me.armor
	_logs.clear()
	u.health = 0
	_gm._cleanup_deaths()
	_check(foe.hero_hp == hp_before - 3, "亡语第一条：对敌方英雄造成 3 点伤害（%d -> %d）" % [hp_before, foe.hero_hp])
	_check(me.armor == armor_before + 2, "亡语第二条：获得 2 点护甲（%d）" % me.armor)
	var i1 := _index_of("英雄剩余生命")
	# 注意：不能用「获得」当探针——触发亡语那一行的文本里就含「获得 2 点护甲」，
	# 会匹配到链结算**之前**的日志行，误判成顺序错乱。用护甲日志独有的片段。
	var i2 := _index_of("点护甲（当前")
	_check(i1 >= 0 and i2 > i1, "亡语两条按顺序结算（第 %d 行 < 第 %d 行）" % [i1, i2])


# ------------------------------ 4. 旧卡兼容 ------------------------------

func _test_legacy_compat() -> void:
	# 老法术：s001 火焰冲击（只有 effect_id / value / target）
	var fire: CardData = _db.get_card("s001")
	_check(fire != null and fire.effects.is_empty() and fire.deathrattle_effects.is_empty(),
		"老卡没有任何效果链")
	if fire == null:
		return
	_check(fire.effect_chain().size() == 1, "老卡的效果链 = 老字段包成一条")
	_check(str(fire.effect_chain()[0].get("id", "")) == "damage"
		and int(fire.effect_chain()[0].get("value", 0)) == 3
		and int(fire.effect_chain()[0].get("target", -1)) == CardData.Targeting.ANY_CHARACTER,
		"包出来的那一条就是 effect_id / value / target")
	_check(fire.effect_text() == "造成 3 点伤害", "effect_text() 与改动前逐字一致（%s）" % fire.effect_text())
	_check(fire.needs_target() and fire.target_name() == "任意角色",
		"老卡的目标判定不变（%s）" % fire.target_name())
	# 目标列表口径不变：双方各 1 个随从 + 双方英雄 = 4
	_prepare()
	_spawn(ME, "c001", 951)
	_spawn(FOE, "c001", 952)
	_check(_gm.get_valid_targets(ME, fire).size() == 4,
		"老卡的目标列表不变（%d 个）" % _gm.get_valid_targets(ME, fire).size())

	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var before_hp: int = foe.hero_hp
	_give(ME, "s001")
	var idx: int = _gm.get_player(ME).hand.size() - 1
	_check(_gm.play_card(ME, idx, -1, FOE), "老法术照常打出")
	_check(foe.hero_hp == before_hp - 3, "老法术的行为与改动前一致（掉 %d）" % (before_hp - foe.hero_hp))

	# 老战吼随从：c005 精神掮客（战吼 1 点伤害）
	var singer: CardData = _db.get_card("c005")
	_check(singer != null and singer.effect_text() == "造成 1 点伤害",
		"老战吼卡的卡面文本不变（%s）" % ("无" if singer == null else singer.effect_text()))
	_check(singer != null and singer.skill.is_empty() and not singer.has_skill(), "老卡没有技能")

	# 老亡语随从：c024 自爆地精（亡语：对敌方英雄造成 4 点伤害）
	_prepare()
	foe = _gm.get_player(FOE)
	before_hp = foe.hero_hp
	var bomber: BoardUnit = _spawn(ME, "c024", 901)
	bomber.health = 0
	_gm._cleanup_deaths()
	_check(foe.hero_hp == before_hp - 4, "老亡语的行为与改动前一致（掉 %d）" % (before_hp - foe.hero_hp))

	# 老卡的 to_dict 仍然写出三个新键（缺省为空）
	var d: Dictionary = _db.get_card("c001").to_dict()
	_check(d.has("effects") and d.has("deathrattle_effects") and d.has("skill"),
		"to_dict() 始终写出 effects / deathrattle_effects / skill")


# ------------------------------ 5. 技能：各种不能发动的理由 ------------------------------

func _test_skill_gates() -> void:
	var c112: CardData = _db.get_card("c112")
	_check(c112 != null and c112.has_skill(), "卡表里有带主动技能的示例卡 c112")
	if c112 == null:
		return
	_check(c112.skill_cost() == 2 and c112.skill_target() == CardData.Targeting.ENEMY_MINION
		and c112.skill_once_per_turn(), "技能参数读取正确（费用 %d / 目标 %d）" % [c112.skill_cost(), c112.skill_target()])
	_check(not c112.needs_target(), "只有技能需要目标的随从，出牌时不强制先选目标（%s）" % c112.target_name())

	_prepare()
	var u: BoardUnit = _spawn_card(ME, c112, 801)
	var foe_unit: BoardUnit = _spawn(FOE, "c001", 802)
	var plain: BoardUnit = _spawn(ME, "c001", 803)
	_gm.get_player(ME).mana = 10
	_check(_gm.skill_blocked_reason(ME, u.unit_id) == "", "可以发动时原因是空串")
	_check(_gm.can_use_skill(ME, u.unit_id), "可以发动")
	_check(_gm.get_valid_skill_targets(ME, u.unit_id).size() == 1, "技能目标列表 = 敌方那个随从")

	_check(not _gm.can_use_skill(ME, foe_unit.unit_id), "别人的单位不能发动")
	_check(_gm.skill_blocked_reason(ME, foe_unit.unit_id) != "", "别人的单位给出原因")
	_check(not _gm.can_use_skill(ME, plain.unit_id), "没有技能的单位不能发动")
	_check(_gm.skill_blocked_reason(ME, plain.unit_id) != "", "没有技能的单位给出原因")

	# 横置
	_gm.place_in_front(ME, u.unit_id)
	_check(u.in_front and not _gm.can_use_skill(ME, u.unit_id), "横置中的单位不能发动技能")
	_check(_gm.skill_blocked_reason(ME, u.unit_id).contains("横置"), "原因是横置（%s）" % _gm.skill_blocked_reason(ME, u.unit_id))
	u.in_front = false

	# 冻结
	u.frozen_until = _gm.turn_count + 1
	_check(not _gm.can_use_skill(ME, u.unit_id), "被冻结的单位不能发动技能")
	_check(_gm.skill_blocked_reason(ME, u.unit_id).contains("冻结"), "原因是冻结")
	u.frozen_until = -1

	# 不是你的回合
	_gm.current_player = FOE
	_check(not _gm.can_use_skill(ME, u.unit_id), "不是你的回合不能发动技能")
	_check(_gm.skill_blocked_reason(ME, u.unit_id).contains("回合"), "原因是回合（%s）" % _gm.skill_blocked_reason(ME, u.unit_id))
	_gm.current_player = ME

	# 阵亡
	u.health = 0
	_check(not _gm.can_use_skill(ME, u.unit_id), "已经阵亡的单位不能发动技能")
	_check(_gm.skill_blocked_reason(ME, u.unit_id) != "", "阵亡也给出原因")
	u.health = u.max_health

	# 技能需要目标但场上没有合法目标：失败且不扣能量点
	var foe_board_backup: Array[BoardUnit] = _gm.get_player(FOE).board.duplicate()
	for x in foe_board_backup:
		_gm.get_player(FOE).remove_unit(x)
	_check(_gm.get_valid_skill_targets(ME, u.unit_id).is_empty(), "敌方没有随从时技能目标列表为空")
	var mana_before: int = _gm.get_player(ME).mana
	_check(not _gm.use_skill(ME, u.unit_id, -1, FOE), "技能没有合法目标 → 发动失败")
	_check(_gm.get_player(ME).mana == mana_before and u.skill_used_turn == -1, "失败时不扣能量点、不消耗本回合次数")


# ------------------------------ 5b. 技能：能量点 / 每回合一次 ------------------------------

func _test_skill_costs_and_turn_limit() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var c112: CardData = _db.get_card("c112")
	if c112 == null:
		_check(false, "缺少示例卡 c112")
		return
	var u: BoardUnit = _spawn_card(ME, c112, 811)
	var victim: BoardUnit = _spawn(FOE, "c001", 812)

	# PP 不足（PP = 法力）
	me.mana = 1
	_check(not _gm.can_use_skill(ME, u.unit_id), "PP 不足 → 不能发动")
	_check(_gm.skill_blocked_reason(ME, u.unit_id).contains("PP"),
		"原因是 PP 不足（%s）" % _gm.skill_blocked_reason(ME, u.unit_id))
	_check(not _gm.use_skill(ME, u.unit_id, victim.unit_id, FOE), "PP 不足 → use_skill 返回 false")
	_check(me.mana == 1, "失败时不扣 PP（%d）" % me.mana)
	_check(u.skill_used_turn == -1, "失败时不消耗本回合次数")
	_check(victim.health == victim.max_health, "失败时没有任何效果生效")

	# 能量点够
	me.mana = 10
	_logs.clear()
	_check(_gm.use_skill(ME, u.unit_id, victim.unit_id, FOE), "能量点够 → 发动成功")
	_check(me.mana == 8, "扣掉 2 点能量点（剩 %d）" % me.mana)
	_check(u.skill_used_turn == _gm.turn_count, "记下本回合已发动（%d）" % u.skill_used_turn)
	_check(_gm.find_unit(victim.unit_id) == null, "技能效果生效：敌方随从被打掉")
	_check(_has_log("发动") and _has_log("技能"), "发动技能记了日志")

	# 同一回合第二次
	me.mana = 10
	_check(not _gm.can_use_skill(ME, u.unit_id), "同一回合第二次 → 不能发动")
	_check(_gm.skill_blocked_reason(ME, u.unit_id).contains("本回合"), "原因是本回合已发动（%s）" % _gm.skill_blocked_reason(ME, u.unit_id))
	_check(not _gm.use_skill(ME, u.unit_id, -1, FOE), "第二次 use_skill 返回 false")
	_check(me.mana == 10, "第二次失败不扣能量点（%d）" % me.mana)

	# 下一回合：可以再发动
	_gm.turn_count += 1
	var victim2: BoardUnit = _spawn(FOE, "c001", 813)
	_check(u.skill_used_turn != _gm.turn_count, "新回合的已用标记不是本回合")
	_check(_gm.can_use_skill(ME, u.unit_id), "下一回合可以再发动")
	_check(_gm.use_skill(ME, u.unit_id, victim2.unit_id, FOE), "下一回合发动成功")
	_check(me.mana == 8 and u.skill_used_turn == _gm.turn_count, "新回合照常扣费并重新记标记")

	# 每回合一次 = false 的技能：同一回合可以连发
	_prepare()
	me = _gm.get_player(ME)
	_spawn(FOE, "c001", 821)
	_spawn(FOE, "c001", 822)
	var spam := _custom({
		"id": "t_spam", "card_name": "连发技能测试", "card_type": 0, "attack": 1, "health": 5,
		"effect_id": "none", "target": 0,
		"skill": {"name": "连发", "cost": 1, "target": 0, "once_per_turn": false,
			"effects": [{"id": "armor", "value": 1, "target": 0, "token": ""}]},
	})
	var su: BoardUnit = _spawn_card(ME, spam, 823)
	me.mana = 5
	_check(_gm.use_skill(ME, su.unit_id), "once_per_turn=false：第一次发动成功")
	_check(_gm.use_skill(ME, su.unit_id), "once_per_turn=false：同一回合第二次也能发动")
	_check(me.mana == 3 and me.armor == 2, "两次都扣了能量点并生效（法力 %d / 护甲 %d）" % [me.mana, me.armor])

	# 花费可以任意指定（0–10 PP）：0 = 免费技能，法力 0 也能发；10 = 一次花光全部 PP
	_prepare()
	me = _gm.get_player(ME)
	var free := _custom({
		"id": "t_free", "card_name": "免费技能卡", "card_type": 0, "cost": 1, "attack": 1, "health": 3,
		"skill": {"name": "白嫖", "cost": 0, "target": 0, "once_per_turn": true,
			"effects": [{"id": "armor", "value": 1, "target": 0, "token": ""}]},
	})
	var fu: BoardUnit = _spawn_card(ME, free, 824)
	me.mana = 0
	me.armor = 0
	_check(fu != null and fu.data.skill_cost() == 0, "技能花费可以配成 0（免费）")
	_check(_gm.can_use_skill(ME, fu.unit_id), "法力 0 也能发动免费技能")
	_check(_gm.use_skill(ME, fu.unit_id), "免费技能发动成功")
	_check(me.mana == 0 and me.armor == 1, "免费技能不扣 PP、效果照常生效（PP %d / 护甲 %d）" % [me.mana, me.armor])

	_prepare()
	me = _gm.get_player(ME)
	var maxi_card := _custom({
		"id": "t_maxcost", "card_name": "满费技能卡", "card_type": 0, "cost": 1, "attack": 1, "health": 3,
		"skill": {"name": "倾尽全力", "cost": 10, "target": 0, "once_per_turn": true,
			"effects": [{"id": "armor", "value": 4, "target": 0, "token": ""}]},
	})
	var mu: BoardUnit = _spawn_card(ME, maxi_card, 825)
	me.mana = 10
	me.armor = 0
	_check(mu != null and mu.data.skill_cost() == 10, "技能花费可以配成 10（PP 上限）")
	_check(_gm.use_skill(ME, mu.unit_id), "花光 10 PP 发动成功")
	_check(me.mana == 0 and me.armor == 4, "扣光 PP 且效果生效（PP %d / 护甲 %d）" % [me.mana, me.armor])
	_check(not _gm.can_use_skill(ME, mu.unit_id), "PP 用光后同回合不能再发（每回合一次 + PP 不足）")


# ------------------------------ 5c. 护符 / 城邦的技能 ------------------------------

func _test_skill_on_permanent_and_city() -> void:
	# 护符：a111（技能：抽 1 张牌，1 点能量点）
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var amulet_card: CardData = _db.get_card("a111")
	_check(amulet_card != null and amulet_card.has_skill() and amulet_card.is_permanent(),
		"卡表里有带技能的护符示例卡 a111")
	if amulet_card != null:
		var amu: BoardUnit = _gm.summon_unit(ME, amulet_card)
		_check(amu != null and amu.is_permanent(), "护符成功安放上场")
		_check(amu != null and not amu.can_use_active_skill(), "护符的 can_use_active_skill() 仍然是 false（既有语义不动）")
		me.mana = 5
		var hand_before: int = me.hand.size()
		_check(amu != null and _gm.can_use_skill(ME, amu.unit_id), "但护符的主动技能可以发动")
		_check(amu != null and _gm.use_skill(ME, amu.unit_id), "护符发动技能成功")
		_check(me.mana == 4, "护符技能扣 1 点能量点（剩 %d）" % me.mana)
		_check(me.hand.size() == hand_before + 1, "护符技能效果生效：抽了 1 张牌（%d -> %d）" % [hand_before, me.hand.size()])

	# 城邦：临时给城邦配一个技能（护甲 +2）
	_prepare()
	me = _gm.get_player(ME)
	var city_card: CardData = _db.get_card("y001").clone()
	city_card.skill = {"name": "城邦动员", "cost": 1, "target": 0, "once_per_turn": true,
		"effects": [{"id": "armor", "value": 2, "target": 0, "token": ""}]}
	_check(city_card.is_city() and city_card.has_skill(), "城邦可以配置主动技能")
	var cu: BoardUnit = _gm.summon_unit(ME, city_card)
	_check(cu != null and cu.in_city_slot, "城邦进了主战者旁的城邦格")
	me.mana = 5
	var armor_before: int = me.armor
	_check(cu != null and _gm.can_use_skill(ME, cu.unit_id), "城邦的技能可以发动")
	_check(cu != null and _gm.use_skill(ME, cu.unit_id), "城邦发动技能成功")
	_check(me.mana == 4 and me.armor == armor_before + 2, "城邦技能扣 1 点能量点并生效（法力 %d / 护甲 %d）" % [me.mana, me.armor])


# ------------------------------ 6. 存档往返 ------------------------------

func _test_save_roundtrip() -> void:
	var raw := {
		"id": "t_rt", "card_name": "存档往返测试", "card_type": 0, "cost": 3, "attack": 1, "health": 2,
		"effect_id": "none", "value": 0, "target": 0,
		"effects": [
			{"id": "damage_hero", "value": 2, "target": 0, "token": ""},
			{"id": "destroy", "value": 0, "target": 2, "token": ""},
		],
		"deathrattle_effects": [
			{"id": "draw", "value": 1, "target": 0, "token": ""},
			{"id": "armor", "value": 2, "target": 0, "token": ""},
		],
		"skill": {"name": "连环", "cost": 3, "target": 2, "once_per_turn": true, "effects": [
			{"id": "damage", "value": 4, "target": 2, "token": ""},
			{"id": "summon", "value": 1, "target": 0, "token": "t001"},
		]},
	}
	var a: CardData = CardData.from_dict(raw)
	_check(_same_chain(a.effects, raw["effects"]), "from_dict 后 effects 的内容与顺序不变")
	_check(_same_chain(a.deathrattle_effects, raw["deathrattle_effects"]), "from_dict 后 deathrattle_effects 的内容与顺序不变")
	_check(_same_chain(a.skill_chain(), raw["skill"]["effects"]), "from_dict 后 skill_chain() 的内容与顺序不变")
	_check(a.effect_id == "damage_hero" and a.value == 2 and a.target == CardData.Targeting.NONE,
		"老字段镜像到链首（%s / %d / %d）" % [a.effect_id, a.value, a.target])
	_check(a.skill_name() == "连环" and a.skill_cost() == 3, "技能名 / 费用读得到（%s / %d）" % [a.skill_name(), a.skill_cost()])

	var b: CardData = CardData.from_dict(a.to_dict())
	var c: CardData = b.clone()
	_check(_same_chain(b.effects, raw["effects"]), "to_dict → from_dict 后 effects 内容与顺序不变")
	_check(_same_chain(b.deathrattle_effects, raw["deathrattle_effects"]), "to_dict → from_dict 后 deathrattle_effects 不变")
	_check(_same_chain(b.skill_chain(), raw["skill"]["effects"]), "to_dict → from_dict 后 skill_chain() 不变")
	_check(_same_chain(c.effects, raw["effects"]), "clone() 后 effects 不变")
	_check(_same_chain(c.deathrattle_effects, raw["deathrattle_effects"]), "clone() 后 deathrattle_effects 不变")
	_check(_same_chain(c.skill_chain(), raw["skill"]["effects"]), "clone() 后 skill_chain() 不变")
	_check(c.skill.get("name", "") == "连环" and c.skill_once_per_turn(), "clone() 后技能的其它字段也在")

	# 深拷贝：改克隆体不会影响原卡
	var d: CardData = a.clone()
	if not d.effects.is_empty():
		var e0: Dictionary = d.effects[0]
		e0["value"] = 999
	_check(int(a.effects[0].get("value", 0)) == 2, "效果链是深拷贝（改克隆体不影响原卡）")

	# 老卡往返：卡面文本 / 行为字段不变
	var old_card: CardData = _db.get_card("s001")
	var old_round: CardData = CardData.from_dict(old_card.to_dict())
	_check(old_round.effect_text() == old_card.effect_text(), "老卡往返后卡面文本不变")
	_check(JSON.stringify(old_round.to_dict()) == JSON.stringify(old_card.to_dict()), "老卡往返后数据完全一致")
	# 链卡往返：数据完全一致（含镜像过的老字段）
	var chain_card: CardData = _db.get_card("c111")
	if chain_card != null:
		var chain_round: CardData = CardData.from_dict(chain_card.to_dict())
		_check(JSON.stringify(chain_round.to_dict()) == JSON.stringify(chain_card.to_dict()),
			"带效果链的卡往返后数据完全一致")


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = true
	_gm.busy = false
	_gm.net_locked = false
	_gm.current_player = ME
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		p.hand.clear()
		p.board.clear()
		p.graveyard.clear()
		p.armor = 0
		p.hero_hp = 30
		p.hero_max_hp = 30
		p.max_mana = 10
		p.mana = 10
		p.overload = 0
	_logs.clear()


## 造一张临时卡（走 from_dict，与卡表 / 存档同一条路）
func _custom(d: Dictionary) -> CardData:
	return CardData.from_dict(d)


## 把卡表里的卡（深拷贝）放进手牌，返回那张手牌
func _give(pid: int, card_id: String) -> CardData:
	var card: CardData = _db.get_card(card_id)
	if card == null:
		return null
	return _give_card(pid, card)


## 把一张卡（深拷贝）放进手牌，返回那张手牌
func _give_card(pid: int, card: CardData) -> CardData:
	var copy := card.clone()
	_gm.get_player(pid).hand.append(copy)
	return copy


## 直接往战场上放一张卡表里的卡（绕过出牌流程，与其它测试一致）
func _spawn(pid: int, card_id: String, uid: int) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	if card == null:
		return null
	return _spawn_card(pid, card, uid)


## 直接往战场上放一张卡（绕过出牌流程）
func _spawn_card(pid: int, card: CardData, uid: int) -> BoardUnit:
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, uid)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


func _index_of(needle: String) -> int:
	for i in _logs.size():
		if _logs[i].contains(needle):
			return i
	return -1


func _has_log(needle: String) -> bool:
	return _index_of(needle) >= 0


## 两条链的「内容 + 顺序」是否完全一致（用 JSON 比，能同时抓住键 / 值 / 顺序的差异）
func _same_chain(a: Array, b: Array) -> bool:
	return JSON.stringify(a) == JSON.stringify(b)


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
	print("=== 效果链 / 主动技能测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
