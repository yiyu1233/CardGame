extends SceneTree
## 横置格（中线前那一格）规则测试。
##
## 规则：进格子的随从
##   1. 只受 1 点伤害（任何来源：攻击 / 法术 / 战吼 / AOE / 亡语）
##   2. 不能发动主动行为（不能攻击；主动技能走 BoardUnit.can_use_active_skill()）
##   3. 敌方用**技能**指定这一侧的随从时，只能选它（群体 / 随机效果不受限）
##   4. 受伤后自动退回后排格子，并失去横置效果
##   5. 随从自身的战吼 / 亡语 / 关键字照常生效
## 同时覆盖：从手牌直接横置上场、把场上随从移进格子、同一侧只能有一个、AI 也会用。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/front_slot_test.gd

const ME := 0
const FOE := 1

const PLAIN := "c001"       ## 见习法师 2/3
const BIG := "c011"         ## 巨型石魔 8/8 嘲讽
const BRUTE := "c028"       ## 毒蛇刺客 2/2 剧毒
const FIREBALL := "s001"    ## 火焰冲击：3 点伤害，任意目标
const AOE := "s014"         ## 视具体卡表而定（下面用效果注册表直接取）

var _fails := 0
var _frames := 0
var _db
var _gm
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_run()
		_finish()
	return _frames > 400


func _run() -> void:
	_test_placement()
	_test_damage_reduction()
	_test_retreat_after_damage()
	_test_move_budget()
	_test_skill_blocked_in_front()
	_test_attack_blocked()
	_test_enemy_skill_targeting()
	_test_own_effects_still_work()
	_test_ai_uses_front_slot()
	_test_ui_side()


# ------------------------------ 放置 ------------------------------

func _test_placement() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var u := _spawn(ME, PLAIN)
	_check(not u.in_front, "刚上场的随从不在横置格")
	_check(_gm.front_unit(ME) == null, "横置格默认为空")

	_check(_gm.place_in_front(ME, u.unit_id), "把场上随从移进横置格")
	_check(u.in_front and _gm.front_unit(ME) == u, "移进后状态与查询一致")
	# 横置格 = 战场正中那一格：进去的单位会被**移动到那一格**（口径见 GameManager 横置格注释）
	_check(_gm.slot_of_unit(u) == _gm.BOARD_LIMIT / 2,
		"横置的随从被移进正中那一格（第 %d 格）" % (_gm.BOARD_LIMIT / 2 + 1))

	# 同一侧只能有一个：再放一个进去，前一个退回后排
	# （移入 / 移出共用一个「每回合一次」的名额，所以要等到下一个自己的回合）
	var u2 := _spawn(ME, PLAIN)
	_check(not _gm.place_in_front(ME, u2.unit_id), "同一回合第二次调整防御格会被拒绝")
	_check(not u2.in_front and u.in_front, "被拒绝时状态完全不变（原来那个还在防御格里）")
	_next_my_turn(ME)
	_check(_gm.place_in_front(ME, u2.unit_id), "下一个自己的回合可以再移入")
	_check(u2.in_front and not u.in_front, "同一侧同时只能有一个防御格随从（原来那个退回后排）")
	_check(_gm.front_unit(ME) == u2, "查询到的是最新进格的那个")
	_check(_gm.slot_of_unit(u2) == _gm.BOARD_LIMIT / 2 and _gm.slot_of_unit(u) != _gm.BOARD_LIMIT / 2,
		"正中格换人：新横置的在正中，原来那个退回别的格子")

	# 从手牌直接横置上场
	_prepare()
	me = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	_prepare_hand(ME, PLAIN)
	var played: bool = _gm.play_card(ME, _hand_index(ME, PLAIN), -1, -1, true)
	_check(played, "从手牌直接把随从横置上场")
	var front: BoardUnit = _gm.front_unit(ME)
	_check(front != null and front.data.card_name == _db.get_card(PLAIN).card_name,
		"上场后确实在横置格里（%s）" % ("空" if front == null else front.data.card_name))

	# 双方各有一个互不影响
	_prepare()
	_spawn_with_front(ME, PLAIN)
	_spawn_with_front(FOE, PLAIN)
	_check(_gm.front_unit(ME) != null and _gm.front_unit(FOE) != null, "上下两侧可以各有一个横置随从")


# ------------------------------ 只受 1 点伤害 ------------------------------

func _test_damage_reduction() -> void:
	# 随从攻击：8 点攻击也只吃 1 点
	_prepare()
	_gm.current_player = FOE          # attack() 要求是行动方的回合
	var victim := _spawn_with_front(ME, BIG)      # 8/8 先进格子
	var attacker := _spawn(FOE, BIG)
	attacker.summoned_turn = -1
	attacker.attacks_used = 0
	var hp_before: int = victim.health
	_check(_gm.attack(FOE, attacker.unit_id, victim.unit_id, ME), "敌方随从可以攻击横置的随从")
	_check(victim.health == hp_before - 1,
		"被 8 点攻击也只受 1 点伤害（%d -> %d）" % [hp_before, victim.health])

	# 法术伤害
	_prepare()
	var v2 := _spawn_with_front(ME, BIG)
	var before2: int = v2.health
	_apply_card_effect(FOE, FIREBALL, v2.unit_id, ME)
	_check(v2.health == before2 - 1, "法术伤害同样减为 1（%d -> %d）" % [before2, v2.health])

	# 群体伤害
	_prepare()
	var v3 := _spawn_with_front(ME, BIG)
	var plain := _spawn(ME, PLAIN)                # 旁边一个普通随从做对照
	var before3: int = v3.health
	var plain_before: int = plain.health
	var ctx := EffectContext.create(_gm, FOE, 2, "", {"kind": "self", "unit_id": -1, "player_id": FOE}, "测试")
	CardEffects.apply("aoe_all", ctx)
	_gm._cleanup_deaths()
	_check(v3.health == before3 - 1, "群体伤害对横置随从只算 1 点（%d -> %d）" % [before3, v3.health])
	_check(plain.health == plain_before - 2,
		"同一次群体伤害对普通随从照常结算（%d -> %d）" % [plain_before, plain.health])

	# 圣盾优先：先破盾，不掉血
	_prepare()
	var shielded := _spawn_with_front(ME, "c007")   # 白银护卫 2/3 圣盾
	var before4: int = shielded.health
	_apply_card_effect(FOE, FIREBALL, shielded.unit_id, ME)
	_check(shielded.health == before4, "横置 + 圣盾：先破盾不掉血（%d）" % shielded.health)


# ------------------------------ 只有随从碰撞攻击才撤出防御格 ------------------------------

func _test_retreat_after_damage() -> void:
	# ① 法术伤害：只受 1 点，**留在防御格里**（新规则：非随从碰撞不会撤出）
	_prepare()
	var u := _spawn_with_front(ME, BIG)
	var board_before: int = _gm.get_player(ME).board.size()
	var hp_before_spell: int = u.health
	_apply_card_effect(FOE, FIREBALL, u.unit_id, ME)
	_check(u.health == hp_before_spell - 1, "法术伤害只受 1 点（%d -> %d）" % [hp_before_spell, u.health])
	_check(u.in_front, "法术伤害**不会**把它打出防御格（仍在防御态）")
	_check(_gm.front_unit(ME) == u, "防御格查询不变（还是它）")

	# 战吼 / 技能这类非碰撞伤害同理
	var hp_before_eff: int = u.health
	_gm.deal_damage_to_unit(null, u, 5)
	_check(u.health == hp_before_eff - 1 and u.in_front,
		"无来源的效果伤害也只受 1 点且不撤出（%d -> %d）" % [hp_before_eff, u.health])

	# ② 随从的碰撞攻击：撤出防御格（这就是唯一的撤出条件）
	_prepare()
	var victim := _spawn_with_front(ME, BIG)
	_gm.current_player = FOE
	var attacker := _spawn(FOE, PLAIN)
	attacker.summoned_turn = -1
	attacker.attacks_used = 0
	_check(victim.in_front, "攻击前在防御格里")
	_check(_gm.attack(FOE, attacker.unit_id, victim.unit_id, ME), "随从可以攻击防御格里的随从")
	_check(not victim.in_front, "被随从的碰撞攻击打中后撤出防御格")
	_check(_gm.front_unit(ME) == null, "撤出后防御格空出来")
	_check(_gm.get_player(ME).board.has(victim), "撤出后仍在战场上")
	_check(_gm.board_slot(ME, _gm.BOARD_LIMIT / 2) == victim,
		"撤出后留在原来的格子里（正中格不再算防御格）")

	# 撤出之后伤害恢复正常
	var hp_before: int = victim.health
	_apply_card_effect(FOE, FIREBALL, victim.unit_id, ME)
	_check(victim.health == hp_before - 3, "撤出防御格后不再减伤（%d -> %d）" % [hp_before, victim.health])

	# ③ 被圣盾挡下（没有真的受伤）时不撤出
	_prepare()
	var s := _spawn_with_front(ME, "c007")
	_gm.current_player = FOE
	var hitter := _spawn(FOE, PLAIN)
	hitter.summoned_turn = -1
	hitter.attacks_used = 0
	_check(_gm.attack(FOE, hitter.unit_id, s.unit_id, ME), "随从攻击带圣盾的防御格随从")
	_check(s.in_front and s.health == s.max_health, "没造成伤害（圣盾挡下）时不撤出防御格")

	# ④ 剧毒仍然是「消灭」而不是伤害
	_prepare()
	_gm.current_player = FOE
	var poisoned := _spawn_with_front(ME, BIG)
	var sniper := _spawn(FOE, BRUTE)
	sniper.summoned_turn = -1
	_check(_gm.attack(FOE, sniper.unit_id, poisoned.unit_id, ME), "剧毒随从攻击防御格里的随从")
	_gm._cleanup_deaths()
	_check(not _gm.get_player(ME).board.has(poisoned), "剧毒依然能消灭防御格里的随从（减伤只影响伤害数值）")


# ------------------------------ 移入 / 移出：自己的回合 + 一回合一个名额 ------------------------------

func _test_move_budget() -> void:
	_prepare()
	var a := _spawn(ME, PLAIN)
	var b := _spawn(ME, PLAIN)
	_check(_gm.can_move_front(ME), "回合开始时可以调整防御格")
	_check(_gm.front_move_blocked_reason(ME) == "", "可以调整时原因为空")

	# 移入一次 → 名额用掉
	_check(_gm.place_in_front(ME, a.unit_id), "移入防御格成功")
	_check(not _gm.can_move_front(ME), "本回合名额已用掉")
	_check(_gm.front_move_blocked_reason(ME).contains("一回合"), "原因说明了一回合只能用一次（%s）" % _gm.front_move_blocked_reason(ME))
	# 同一回合再移入 / 移出都被拒绝，且状态不变
	_check(not _gm.place_in_front(ME, b.unit_id), "同一回合第二次移入被拒绝")
	_check(not b.in_front and a.in_front, "被拒绝时没有人被挪动")
	_check(not _gm.leave_front(ME, a.unit_id), "同一回合接着移出也被拒绝（两个动作共用一个名额）")
	_check(a.in_front, "被拒绝时移出没有生效")

	# 下一个自己的回合：可以移出
	_next_my_turn(ME)
	_check(_gm.can_move_front(ME), "下一个自己的回合名额恢复")
	var slot_before: int = _gm.slot_of_unit(a)
	_check(_gm.leave_front(ME, a.unit_id), "移出防御格成功")
	_check(not a.in_front, "移出后不再处于防御态")
	_check(_gm.slot_of_unit(a) != PlayerState.FRONT_SLOT, "移出后不在正中格（%d -> %d）" % [slot_before, _gm.slot_of_unit(a)])
	_check(_gm.get_player(ME).board.has(a), "移出后仍在战场上")
	_check(not _gm.can_move_front(ME), "移出同样用掉了本回合的名额")

	# 不是自己的回合 → 移入 / 移出都失败
	_prepare()
	var c := _spawn(ME, PLAIN)
	_gm.current_player = FOE
	_check(not _gm.can_move_front(ME), "不是自己的回合不能调整")
	_check(_gm.front_move_blocked_reason(ME).contains("自己的回合"), "原因说明只能在自己回合（%s）" % _gm.front_move_blocked_reason(ME))
	_check(not _gm.place_in_front(ME, c.unit_id), "不是自己的回合移入失败")

	# 后排没有空位时移出失败，而且**不消耗名额**
	_prepare()
	var d := _spawn_with_front(ME, PLAIN)
	_next_my_turn(ME)                    # 夹具复位了名额，这里显式确认「回合内可调整」
	var me: PlayerState = _gm.get_player(ME)
	for i in _gm.BOARD_LIMIT:
		if i == PlayerState.FRONT_SLOT or _gm.board_slot(ME, i) != null:
			continue
		var filler := _spawn(ME, PLAIN)
		_gm.place_unit_at(ME, filler, i)
	_check(_gm._first_empty_back_slot(ME) < 0, "后排已经塞满（构造前置条件）")
	_check(not _gm.leave_front(ME, d.unit_id), "后排没有空位时移出失败")
	_check(d.in_front, "失败时它还在防御格里")
	_check(_gm.can_move_front(ME), "失败**不消耗名额**（腾出空位后还能移出）")
	# 腾一格出来再移出 → 成功
	var to_remove: BoardUnit = null
	for u in me.board:
		if u != d and _gm.slot_of_unit(u) != PlayerState.FRONT_SLOT:
			to_remove = u
			break
	if to_remove != null:
		me.board.erase(to_remove)       # 从战场名单里移除 → sync_slots() 之后那一格就空了
		me.sync_slots()
	_check(_gm._first_empty_back_slot(ME) >= 0, "腾出一个后排空位")
	_check(_gm.leave_front(ME, d.unit_id, -1), "腾出空位后同一回合仍可移出")


# ------------------------------ 防御格里不能发动技能 ------------------------------

func _test_skill_blocked_in_front() -> void:
	_prepare()
	var carrier: CardData = _db.get_card("c112")        # 秘法守卫：带主动技能
	_check(carrier != null and carrier.has_skill(), "卡表里有带技能的随从（c112）")
	if carrier == null:
		return
	var u := _spawn(ME, "c112")
	_gm.get_player(ME).mana = 10
	# 先把随从放进防御格（用测试铺场口径，绕过名额）
	_make_front(ME, u)
	var victim := _spawn(FOE, PLAIN)
	_check(u.in_front, "带技能的随从已在防御格里")
	_check(not _gm.can_use_skill(ME, u.unit_id), "防御格里的随从**不能**发动技能")
	_check(_gm.skill_blocked_reason(ME, u.unit_id) != "", "给出了不能发动的原因（%s）" % _gm.skill_blocked_reason(ME, u.unit_id))
	_check(not _gm.use_skill(ME, u.unit_id, victim.unit_id, FOE), "直接调 use_skill 也会被拒绝")
	_check(_gm.get_player(ME).mana == 10, "被拒绝时不扣 PP")
	# 移出防御格后技能恢复可用
	_next_my_turn(ME)
	_check(_gm.leave_front(ME, u.unit_id), "把它移出防御格")
	_check(_gm.can_use_skill(ME, u.unit_id), "移出防御格后技能又能发动了")
	_check(_gm.use_skill(ME, u.unit_id, victim.unit_id, FOE), "移出后发动技能成功")


# ------------------------------ 不能攻击 ------------------------------

func _test_attack_blocked() -> void:
	_prepare()
	var mine := _spawn_with_front(ME, PLAIN)
	mine.summoned_turn = -1
	mine.attacks_used = 0
	_check(not mine.can_attack(_gm.turn_count, true), "横置中的随从 can_attack() 为假")
	_check(not mine.can_act(), "横置中的随从不能发动主动行为")
	_check(not mine.can_use_active_skill(), "横置中的随从不能释放主动技能")
	_check(_gm.get_valid_attack_targets(ME, mine.unit_id).is_empty(), "横置中的随从没有可攻击目标")

	var foe_unit := _spawn(FOE, PLAIN)
	var attacked: bool = _gm.attack(ME, mine.unit_id, foe_unit.unit_id, FOE)
	_check(not attacked, "即使直接调用攻击接口也会被拒绝")

	# 撤出防御格后可以正常攻击
	_gm.current_player = FOE
	var hitter := _spawn(FOE, PLAIN)
	hitter.summoned_turn = -1
	hitter.attacks_used = 0
	_gm.attack(FOE, hitter.unit_id, mine.unit_id, ME)
	if mine.is_alive():
		mine.summoned_turn = -1
		mine.attacks_used = 0
		_check(not mine.in_front, "被随从攻击后离开防御格")
		_check(mine.can_attack(_gm.turn_count, true), "撤出防御格后恢复攻击能力")


# ------------------------------ 敌方技能只能选它 ------------------------------

func _test_enemy_skill_targeting() -> void:
	_prepare()
	var front := _spawn_with_front(ME, PLAIN)
	var other := _spawn(ME, PLAIN)
	var other2 := _spawn(ME, BRUTE)
	var spell: CardData = _db.get_card(FIREBALL)      # 任意目标
	var enemy_targets: Array[Dictionary] = _gm.get_valid_targets(FOE, spell)
	var unit_ids: Array[int] = []
	for t in enemy_targets:
		if str(t["kind"]) == "unit":
			unit_ids.append(int(t["unit_id"]))
	_check(unit_ids.has(front.unit_id), "敌方技能可以指定横置的随从")
	_check(not unit_ids.has(other.unit_id) and not unit_ids.has(other2.unit_id),
		"敌方技能不能指定这一侧的其它随从（可选 %d 个随从）" % unit_ids.size())
	_check(unit_ids.size() == 1, "敌方技能在这一侧只有一个合法随从目标")

	# 我方自己指定自己的随从不受限制
	var buff: CardData = _db.get_card("s011")         # 力量祝福：友方随从 +2/+2
	var own_targets: Array[Dictionary] = _gm.get_valid_targets(ME, buff)
	var own_ids: Array[int] = []
	for t in own_targets:
		own_ids.append(int(t["unit_id"]))
	_check(own_ids.has(other.unit_id) and own_ids.has(other2.unit_id),
		"我方技能仍然可以指定自己的其它随从（不受横置限制）")

	# 群体 / 随机效果不受限制
	var ctx := EffectContext.create(_gm, FOE, 2, "", {"kind": "self", "unit_id": -1, "player_id": FOE}, "测试")
	var hp_other: int = other.health
	CardEffects.apply("aoe_all", ctx)
	_check(other.health == hp_other - 2, "群体效果照常打到后排随从")

	# 横置格空着时，敌方技能照常可以指定任何随从
	_prepare()
	var a := _spawn(ME, PLAIN)
	var b := _spawn(ME, PLAIN)
	var t2: Array[Dictionary] = _gm.get_valid_targets(FOE, _db.get_card(FIREBALL))
	var ids2: Array[int] = []
	for t in t2:
		if str(t["kind"]) == "unit":
			ids2.append(int(t["unit_id"]))
	_check(ids2.has(a.unit_id) and ids2.has(b.unit_id), "横置格空着时目标不受限制")


# ------------------------------ 随从自身效果照常 ------------------------------

func _test_own_effects_still_work() -> void:
	# 亡语照常触发：用「自爆地精」（亡语对敌方英雄造成 4 点伤害）看得最清楚
	_prepare()
	var death: CardData = _db.get_card("c024")
	_check(death != null and death.has_deathrattle(), "卡表里有带亡语的随从（%s）" % ("无" if death == null else death.card_name))
	if death != null:
		var u: BoardUnit = _spawn(ME, death.id)
		_gm.place_in_front(ME, u.unit_id)
		var foe_hp: int = _gm.get_player(FOE).hero_hp
		# 用剧毒把它带走（attack 要求是行动方的回合，所以先把行动权交给敌方）
		_gm.current_player = FOE
		var killer := _spawn(FOE, BRUTE)
		killer.summoned_turn = -1
		_check(_gm.attack(FOE, killer.unit_id, u.unit_id, ME), "剧毒随从攻击横置的亡语随从")
		_gm._cleanup_deaths()
		_check(not _gm.get_player(ME).board.has(u), "横置的随从被消灭后离开战场")
		var in_grave := false
		for card_in_grave in _gm.get_player(ME).graveyard:
			if card_in_grave.id == death.id:
				in_grave = true
		_check(in_grave, "横置随从进入墓地（墓地 %d 张）" % _gm.get_player(ME).graveyard.size())
		_check(_gm.get_player(FOE).hero_hp == foe_hp - death.death_value,
			"横置随从的亡语照常结算（敌方英雄 %d -> %d，期望 -%d）" % [
				foe_hp, _gm.get_player(FOE).hero_hp, death.death_value])

	# 关键字照常（嘲讽 / 圣盾在横置时依然生效）
	_prepare()
	var taunt := _spawn_with_front(ME, BIG)             # 8/8 嘲讽
	_check(taunt.has_keyword(CardData.Keyword.TAUNT), "横置不影响随从自身的关键字（嘲讽仍在）")
	_check(taunt.has_keyword(CardData.Keyword.TAUNT) and taunt.in_front, "横置 + 嘲讽同时存在")


# ------------------------------ AI 也会使用 ------------------------------

func _test_ai_uses_front_slot() -> void:
	_prepare()
	var ai = load("res://scripts/EnemyAI.gd").new(_gm, FOE)
	_check(ai != null, "AI 脚本可实例化")

	# 1) 残血随从会被 AI 横置进格子（现在是 AI 的回合）
	var weak := _spawn(FOE, PLAIN)
	weak.health = 1
	_next_my_turn(FOE)
	_check(ai.call("_try_use_front_slot"), "AI 会把残血随从横置进格子")
	_check(weak.in_front, "AI 横置的就是那个残血随从")

	# 2) 已经有横置随从时不再重复放
	_check(not ai.call("_try_use_front_slot"), "已经有横置随从时 AI 不会重复放")

	# 3) 血少的脆弱随从会被 AI 直接横置上场
	_check(ai.call("_should_place_in_front", _db.get_card("c001")), "低血随从被 AI 判定为适合横置上场")
	_check(not ai.call("_should_place_in_front", _db.get_card(BIG)), "高血随从不会被 AI 横置上场")


# ------------------------------ UI 侧 ------------------------------

func _test_ui_side() -> void:
	# 横置格落在每行正中那一格；后排格子不含它
	var main_ui = load("res://scenes/Main.tscn").instantiate()
	root.add_child(main_ui)
	_check(main_ui != null, "主场景可实例化")
	if main_ui == null:
		return
	var surface: BoardSurface = main_ui.player_board
	_check(surface != null, "我方战场行有 BoardSurface")
	if surface != null:
		_check(surface.front_lane() == surface.slot_limit / 2,
			"横置格是正中的那一格（第 %d 格）" % (surface.front_lane() + 1))
		_check(not surface.back_lanes().has(surface.front_lane()), "后排格子列表不含横置格")
		_check(surface.back_lanes().size() == surface.slot_limit - 1,
			"除横置格外还有 %d 个后排格子（实际 %d）" % [surface.slot_limit - 1, surface.back_lanes().size()])
		var front_rect := surface.front_slot_rect()
		var mid_rect := surface.slot_rect(surface.front_lane())
		_check(front_rect.get_center().is_equal_approx(mid_rect.get_center()), "横置格矩形与正中槽位一致")
	main_ui.queue_free()


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.board.clear()
	_gm.get_player(FOE).board.clear()


func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 90000 + randi() % 9000)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


## 铺一个随从并把它移进防御格。
## **测试铺场专用**：临时把行动权交给 pid、清掉本回合名额并复位 busy，
## 这样夹具不受「一回合一次」限制；规则本身由 `_test_move_budget()` 单独覆盖。
func _spawn_with_front(pid: int, card_id: String) -> BoardUnit:
	var u := _spawn(pid, card_id)
	_make_front(pid, u)
	return u


## 直接让某个单位进入防御格。
## **夹具口径**：不吃「本回合名额」（放完把 `front_move_turn` 复位成 -1），
## 这样调用方要测名额时不会被夹具提前消耗掉。规则本身由 `_test_move_budget()` 覆盖。
func _make_front(pid: int, u: BoardUnit) -> void:
	var saved_player: int = _gm.current_player
	var saved_busy: bool = _gm.busy
	_gm.current_player = pid
	_gm.busy = false
	var p: PlayerState = _gm.get_player(pid)
	if p != null:
		p.front_move_turn = -1
	_gm.place_in_front(pid, u.unit_id)
	if p != null:
		p.front_move_turn = -1          # 夹具不吃名额
	_gm.current_player = saved_player
	_gm.busy = saved_busy


## 模拟「轮到 pid 的下一个自己的回合」：总回合 +2 回到同一个人，
## 于是 `front_move_turn` 与当前回合不再相等 → 防御格调整名额恢复。
func _next_my_turn(pid: int) -> void:
	_gm.turn_count += 2
	_gm.current_player = pid
	_gm.busy = false


func _prepare_hand(pid: int, card_id: String) -> void:
	var p: PlayerState = _gm.get_player(pid)
	p.hand.clear()
	p.hand.append(_db.get_card(card_id).clone())


func _hand_index(pid: int, card_id: String) -> int:
	var p: PlayerState = _gm.get_player(pid)
	for i in p.hand.size():
		if p.hand[i].id == card_id:
			return i
	return -1


## 用一张法术卡对指定随从结算效果（走真实的 EffectContext / CardEffects 流程）
func _apply_card_effect(caster: int, card_id: String, unit_id: int, owner: int) -> void:
	var card: CardData = _db.get_card(card_id)
	if card == null:
		_check(false, "卡表里有 %s" % card_id)
		return
	var ctx := EffectContext.create(_gm, caster, card.value, card.token_id,
		{"kind": "unit", "unit_id": unit_id, "player_id": owner}, card.card_name)
	CardEffects.apply(card.effect_id, ctx)
	_gm._cleanup_deaths()


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
	print("=== 横置格测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
