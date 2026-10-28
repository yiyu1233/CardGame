extends SceneTree
## 关键字（词条）矩阵测试：逐个验证「满足条件时能触发」，并给出词条之间的相互作用清单。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/keyword_matrix_test.gd
##
## 覆盖：
##   1. 注册表自检：Mechanics.audit() 干净（枚举 / 注册表 / 名次 / key 四方对齐）
##   2. 12 个词条逐个跑一遍「满足条件 → 触发」+「条件不满足 → 不触发」的反例
##   3. 词条两两组合：冲突 / 压制 / 叠加 三分类清单（结尾打印成表）；
##   4. 冲突时**后到者覆盖**：运行时被赋予的效果会把与之互斥的旧效果摘掉
##      （卡自带的一对互斥词条没有先后，不参与这条规则）。
##
## 之所以每个词条都用**合成卡**（而不是卡表里某一张具体的卡）：卡表是内容，会随
## 文案调整变动；这里要钉住的是「机制本身在高亮条件下必然生效」，与具体卡无关。

const ME := 0
const FOE := 1

## 组合关系的三种分类
const K_CONFLICT := "冲突"    ## 互相抵消 / 一方让另一方彻底失效（配卡时要注意）
const K_OVERRIDE := "压制"    ## 一方盖过另一方（结果确定，符合常见口径）
const K_STACK := "叠加"       ## 各自生效，互不干扰

var _fails := 0
var _frames := 0
var _db
var _gm
var _fail_lines: Array[String] = []
var _uid := 700000
var _covered := {}            ## CardData.Keyword -> true（跑过正面用例的词条）
var _pairs: Array[Dictionary] = []


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
	return _frames > 300


func _run() -> void:
	_test_registry()
	# ---- 逐个词条 ----
	_test_taunt()
	_test_charge()
	_test_rush()
	_test_divine_shield()
	_test_windfury()
	_test_lifesteal()
	_test_poisonous()
	_test_stealth()
	_test_reborn()
	_test_spell_damage()
	_test_stalwart()
	_test_sluggish()
	_test_indestructible()
	_test_ability_immune()
	_test_collision_immune()
	_test_awaken()
	_test_coverage()
	# ---- 组合矩阵 ----
	_pair_stealth_taunt()
	_pair_charge_sluggish()
	_pair_rush_sluggish()
	_pair_windfury_sluggish()
	_pair_charge_rush()
	_pair_windfury_charge()
	_pair_shield_stalwart()
	_pair_poison_shield()
	_pair_poison_stalwart()
	_pair_lifesteal_poison()
	_pair_stealth_spell_damage()
	_pair_sluggish_spell_damage()
	_pair_reborn_stealth()
	_pair_reborn_sluggish()
	_pair_taunt_shield()
	# ---- 冲突时谁来占这一格：后到者覆盖 ----
	_override_registry()
	_override_stealth_then_taunt()
	_override_taunt_then_stealth()
	_override_sluggish_then_charge()
	_override_frozen_then_charge()
	_override_charge_then_frozen()
	_override_keeps_printed_combo()
	_override_no_conflict_stacks()
	_print_matrix()


# ------------------------------ 1. 注册表 ------------------------------

func _test_registry() -> void:
	var audit: Dictionary = Mechanics.audit()
	var problems := PackedStringArray(audit.get("missing", []))
	problems.append_array(PackedStringArray(audit.get("unnamed", [])))
	problems.append_array(PackedStringArray(audit.get("unkeyed", [])))
	problems.append_array(PackedStringArray(audit.get("unknown_flags", [])))
	problems.append_array(PackedStringArray(audit.get("bad_conflicts", [])))
	_check(bool(audit.get("ok", false)), "机制注册表自检干净（%s）" % str(problems))
	_check(int(audit.get("count", 0)) == CardData.all_keyword_ids().size(),
		"注册表收录 %d 个词条" % int(audit.get("count", 0)))


# ------------------------------ 2. 嘲讽 ------------------------------

func _test_taunt() -> void:
	_prepare()
	var atk := _spawn(ME, _mk("kw_t", "攻击者", 3, 3))
	var taunt := _spawn(FOE, _mk("kw_taunt", "嘲讽墙", 2, 5, ["taunt"]))
	var weak := _spawn(FOE, _mk("kw_weak", "后排", 2, 2))
	var targets: Array = _gm.get_valid_attack_targets(ME, atk.unit_id)
	var only_taunt: bool = targets.size() == 1 and targets[0]["unit_id"] == taunt.unit_id
	_check(only_taunt, "嘲讽：攻击目标里只剩它一个（实际 %d 个）" % targets.size())
	_check(not _gm.attack(ME, atk.unit_id, -1, FOE), "嘲讽：打不到英雄")
	_check(not _gm.attack(ME, atk.unit_id, weak.unit_id, FOE), "嘲讽：打不到它身后的随从")
	_check(_gm.attack(ME, atk.unit_id, taunt.unit_id, FOE), "嘲讽：只能打它")
	_mark(CardData.Keyword.TAUNT)

	# 反例：它一走英雄就露出来了
	_prepare()
	var atk2 := _spawn(ME, _mk("kw_t2", "攻击者", 3, 3))
	var gone := _spawn(FOE, _mk("kw_gone", "嘲讽墙", 2, 5, ["taunt"]))
	_gm.get_player(FOE).remove_unit(gone)
	var t2: Array = _gm.get_valid_attack_targets(ME, atk2.unit_id)
	_check(_has_hero(t2), "反例：场上没有嘲讽时英雄可以被攻击")


# ------------------------------ 3. 冲锋 ------------------------------

func _test_charge() -> void:
	_prepare()
	var c := _spawn(ME, _mk("kw_c", "冲锋兵", 3, 3, ["charge"]), true)
	var foe: PlayerState = _gm.get_player(FOE)
	_check(c.can_attack(_gm.turn_count, true), "冲锋：召唤当回合就能攻击随从")
	_check(c.can_attack(_gm.turn_count, false), "冲锋：召唤当回合也能攻击英雄")
	var target := _spawn(FOE, _mk("kw_c_v", "靶子", 2, 2))
	var before_hp: int = foe.hero_hp
	_check(_gm.attack(ME, c.unit_id, -1, FOE), "冲锋：当回合直接打脸")
	_check(foe.hero_hp == before_hp - 3, "英雄掉 %d 点血（%d → %d）" % [
		before_hp - foe.hero_hp, before_hp, foe.hero_hp])
	target.health = target.health    # 占位：靶子只是为了让场上有随从
	_mark(CardData.Keyword.CHARGE)

	# 反例：没有冲锋的同回合随从动不了
	_prepare()
	var plain := _spawn(ME, _mk("kw_plain", "普通兵", 3, 3), true)
	_check(not plain.can_attack(_gm.turn_count, true), "反例：没冲锋的同回合随从不能攻击")


# ------------------------------ 4. 突袭 ------------------------------

func _test_rush() -> void:
	_prepare()
	var r := _spawn(ME, _mk("kw_r", "突袭兵", 3, 3, ["rush"]), true)
	var victim := _spawn(FOE, _mk("kw_r_v", "敌方随从", 2, 4))
	_check(r.can_attack(_gm.turn_count, true), "突袭：当回合能打随从")
	_check(not r.can_attack(_gm.turn_count, false), "突袭：当回合不能打英雄")
	var targets: Array = _gm.get_valid_attack_targets(ME, r.unit_id)
	_check(targets.size() == 1 and targets[0]["unit_id"] == victim.unit_id,
		"突袭：可攻击目标里没有英雄")
	_check(not _gm.attack(ME, r.unit_id, -1, FOE), "突袭：强制打脸不生效")
	_check(_gm.attack(ME, r.unit_id, victim.unit_id, FOE), "突袭：打随从正常生效")
	_mark(CardData.Keyword.RUSH)

	# 反例：过了召唤回合就能打脸了
	_prepare()
	var r2 := _spawn(ME, _mk("kw_r2", "突袭兵", 3, 3, ["rush"]))
	_check(r2.can_attack(_gm.turn_count, false), "反例：不是召唤当回合时可以打英雄")


# ------------------------------ 5. 圣盾 ------------------------------

func _test_divine_shield() -> void:
	_prepare()
	var s := _spawn(FOE, _mk("kw_ds", "圣盾兵", 2, 3, ["shield"]))
	_check(s.divine_shield, "圣盾：上场时带盾")
	var before: int = s.health
	var dealt: int = _gm.deal_damage_to_unit(null, s, 5)
	_check(dealt == 0 and s.health == before, "圣盾：第一次伤害被完全免掉（掉血 %d）" % dealt)
	_check(not s.divine_shield, "圣盾：挡完就消失")
	# 破盾后不该还留着「圣盾」这个词条：否则卡面标签 / 搬运效果会把它当成还在
	_check(not s.has_mechanic(CardData.Keyword.DIVINE_SHIELD),
		"圣盾：破盾后不再携带该词条（%s）" % "，".join(s.mechanic_names()))
	var dealt2: int = _gm.deal_damage_to_unit(null, s, 2)
	_check(dealt2 == 2 and s.health == before - 2, "反例：盾破之后伤害照常结算（%d）" % dealt2)
	_mark(CardData.Keyword.DIVINE_SHIELD)


# ------------------------------ 6. 风怒 ------------------------------

func _test_windfury() -> void:
	_prepare()
	var w := _spawn(ME, _mk("kw_wf", "风怒兵", 2, 6, ["windfury"]))
	var dummy := _spawn(FOE, _mk("kw_dummy", "沙包", 0, 12))
	_check(w.max_attacks() == 2, "风怒：每回合两次攻击上限（%d）" % w.max_attacks())
	_check(_gm.attack(ME, w.unit_id, dummy.unit_id, FOE), "风怒：第一次攻击")
	_check(_gm.attack(ME, w.unit_id, dummy.unit_id, FOE), "风怒：同一回合第二次攻击")
	_check(w.attacks_used == 2, "两次都记进召唤Attack次数（%d）" % w.attacks_used)
	_check(not _gm.attack(ME, w.unit_id, dummy.unit_id, FOE), "反例：第三次打不出去")
	_mark(CardData.Keyword.WINDFURY)


# ------------------------------ 7. 吸血 ------------------------------

func _test_lifesteal() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var ls := _spawn(ME, _mk("kw_ls", "吸血鬼", 3, 4, ["lifesteal"]))
	var victim := _spawn(FOE, _mk("kw_ls_v", "猎物", 2, 4))
	me.hero_hp = 20
	_check(_gm.attack(ME, ls.unit_id, victim.unit_id, FOE), "吸血：攻击随从")
	_check(me.hero_hp == 23, "吸血：按实际伤害回血（20 → %d）" % me.hero_hp)
	# 被圣盾挡下 = 没造成伤害 = 不回血
	_prepare()
	var me2: PlayerState = _gm.get_player(ME)
	var ls2 := _spawn(ME, _mk("kw_ls2", "吸血鬼", 3, 4, ["lifesteal"]))
	_spawn(FOE, _mk("kw_ls_s", "圣盾兵", 2, 3, ["shield"]))
	me2.hero_hp = 20
	_check(_gm.attack(ME, ls2.unit_id, _gm.get_player(FOE).board[0].unit_id, FOE),
		"吸血：攻击带盾随从")
	_check(me2.hero_hp == 20, "反例：伤害被挡下时不回血（%d）" % me2.hero_hp)
	_mark(CardData.Keyword.LIFESTEAL)


# ------------------------------ 8. 剧毒 ------------------------------

func _test_poisonous() -> void:
	_prepare()
	var ps := _spawn(ME, _mk("kw_ps", "毒刺客", 2, 2, ["poisonous"]))
	var big := _spawn(FOE, _mk("kw_big", "巨兽", 8, 8))
	_check(_gm.attack(ME, ps.unit_id, big.unit_id, FOE), "剧毒：攻击大随从")
	_check(not big.is_alive() and _gm.get_player(FOE).board.size() == 0,
		"剧毒：造成过伤害就把它消灭（敌方场上 %d）" % _gm.get_player(FOE).board.size())
	# 打英雄只是掉血，不能"-1 血直接没了"
	_prepare()
	var ps2 := _spawn(ME, _mk("kw_ps2", "毒刺客", 2, 2, ["poisonous"]))
	var foe2: PlayerState = _gm.get_player(FOE)
	foe2.hero_hp = 30
	_check(_gm.attack(ME, ps2.unit_id, -1, FOE), "剧毒：攻击英雄")
	_check(foe2.hero_hp == 28, "反例：英雄只是掉血，不会被毒死（%d）" % foe2.hero_hp)
	_mark(CardData.Keyword.POISONOUS)


# ------------------------------ 9. 潜行 ------------------------------

func _test_stealth() -> void:
	_prepare()
	var st := _spawn(FOE, _mk("kw_st", "潜行者", 3, 2, ["stealth"]))
	_check(not Mechanics.can_be_targeted(st, ME), "潜行：敌方不能指定它")
	_check(Mechanics.can_be_targeted(st, FOE), "潜行：自己人照样能指定它")
	var atk := _spawn(ME, _mk("kw_st_a", "攻击者", 3, 3))
	var targets: Array[Dictionary] = _gm.get_valid_attack_targets(ME, atk.unit_id)
	_check(not _has_unit(targets, st.unit_id), "潜行：敌方打不到它（它不在攻击目标里）")
	var dealt: int = _gm.deal_damage_to_unit(null, st, 2)
	_check(dealt == 2 and not st.is_alive(), "潜行：挡不住随机 / 群体效果（造成 %d）" % dealt)
	# 攻击后解除
	_prepare()
	var mine := _spawn(ME, _mk("kw_st2", "我方潜行", 3, 2, ["stealth"]))
	var victim := _spawn(FOE, _mk("kw_st_v", "靶子", 2, 4))
	_check(_gm.attack(ME, mine.unit_id, victim.unit_id, FOE), "潜行：自己发起攻击")
	_check(not mine.has_mechanic(CardData.Keyword.STEALTH), "潜行：攻击后解除")
	_check(Mechanics.can_be_targeted(mine, FOE), "解除后敌方就能指定它了")
	_mark(CardData.Keyword.STEALTH)


# ------------------------------ 10. 复生 ------------------------------

func _test_reborn() -> void:
	_prepare()
	var rb := _spawn(ME, _mk("kw_rb", "复生者", 3, 3, ["reborn"]))
	_gm.deal_damage_to_unit(null, rb, 5)
	_gm._cleanup_deaths()
	var back: BoardUnit = _find_unit(ME, "kw_rb")
	_check(back != null and back.is_alive(), "复生：第一次死亡后回到战场")
	_check(back != null and back.health == 1 and back.max_health == 3,
		"复生：以 1 点生命回来（%d/%d）" % [back.health if back != null else -1,
			back.max_health if back != null else -1])
	_check(back != null and back.reborn_used, "复生：名额已用（一个单位只复活一次）")
	if back != null:
		_gm.deal_damage_to_unit(null, back, 2)
		_gm._cleanup_deaths()
		_check(_find_unit(ME, "kw_rb") == null, "反例：第二次死亡真的死了")
	_mark(CardData.Keyword.REBORN)


# ------------------------------ 11. 法术伤害 ------------------------------

func _test_spell_damage() -> void:
	_prepare()
	_spawn(ME, _mk("kw_sd1", "法伤学徒", 1, 3, ["spell_damage"], 1))
	_spawn(ME, _mk("kw_sd2", "法伤导师", 1, 3, ["spell_damage"], 2))
	_check(_gm.spell_damage_bonus(ME) == 3, "法术伤害：同侧多个叠加（+%d）" % _gm.spell_damage_bonus(ME))
	var victim := _spawn(FOE, _mk("kw_sd_v", "靶子", 2, 6))
	_check(_play_card(ME, _mk_spell("kw_sd_sp", "火球", "damage", 2,
		CardData.Targeting.ANY_CHARACTER), victim.unit_id, FOE), "打出 2 点伤害法术")
	_check(victim.health == 1, "法伤让 2 点变 5 点（6 → %d）" % victim.health)
	# 反例：治疗法术不吃加成（只对伤害性效果生效）
	_prepare()
	_spawn(ME, _mk("kw_sd3", "法伤导师", 1, 3, ["spell_damage"], 2))
	var hurt := _spawn(ME, _mk("kw_sd_h", "伤员", 2, 6))
	hurt.health = 2
	_check(_play_card(ME, _mk_spell("kw_sd_heal", "治疗术", "heal", 3,
		CardData.Targeting.ALLY_MINION), hurt.unit_id, ME), "打出 3 点治疗法术")
	_check(hurt.health == 5, "反例：治疗只吃原数值（2 → %d）" % hurt.health)
	_mark(CardData.Keyword.SPELL_DAMAGE)


# ------------------------------ 12. 坚壁 ------------------------------

func _test_stalwart() -> void:
	_prepare()
	var sw := _spawn(FOE, _mk("kw_sw", "坚壁墙", 2, 5, ["stalwart"]))
	var dealt: int = _gm.deal_damage_to_unit(null, sw, 5)
	_check(dealt == 1 and sw.health == 4, "坚壁：5 点伤害压到 1 点（实际 %d）" % dealt)
	# 随从碰撞同样被压成 1
	_prepare()
	var sw2 := _spawn(FOE, _mk("kw_sw2", "坚壁墙", 2, 5, ["stalwart"]))
	var big := _spawn(ME, _mk("kw_sw_a", "大力士", 7, 7))
	_check(_gm.attack(ME, big.unit_id, sw2.unit_id, FOE), "坚壁：被随从攻击")
	_check(sw2.is_alive() and sw2.health == 4, "碰撞伤害同样封顶 1 点（剩 %d）" % sw2.health)
	_mark(CardData.Keyword.STALWART)


# ------------------------------ 13. 迟钝 ------------------------------

func _test_sluggish() -> void:
	_prepare()
	var sl := _spawn(ME, _mk("kw_sl", "迟钝者", 3, 3, ["sluggish"]))
	_check(not Mechanics.has_flag(CardData.Keyword.SLUGGISH, "spell_damage")
		or Mechanics.has_flag(CardData.Keyword.SLUGGISH, Mechanics.FLAG_CANNOT_ATTACK),
		"迟钝：声明式标志位 cannot_attack 已注册")
	_check(not sl.can_attack(_gm.turn_count, true), "迟钝：不能攻击")
	_check(_gm.get_valid_attack_targets(ME, sl.unit_id).is_empty(), "迟钝：没有可攻击目标")
	var victim := _spawn(FOE, _mk("kw_sl_v", "靶子", 2, 4))
	_check(not _gm.attack(ME, sl.unit_id, victim.unit_id, FOE), "迟钝：攻击不生效")
	_check(Mechanics.can_be_targeted(sl, FOE), "迟钝：站在场上照样能被对面指定")
	_mark(CardData.Keyword.SLUGGISH)


# ------------------------------ 14. 不灭（无法被能力破坏） ------------------------------

func _test_indestructible() -> void:
	_prepare()
	var u := _spawn(FOE, _mk("kw_ind", "不灭者", 2, 5, ["indestructible"]))
	var ctx := EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": FOE})
	ctx.kill_unit(u)
	_gm._cleanup_deaths()
	_check(u.is_alive() and u.health == 5, "不灭：消灭类能力对它无效")
	_check(_gm.get_player(FOE).units_died_total == 0, "不灭：没有被计入被破坏")
	# 伤害仍然能把它打死（不灭只挡“破坏”，不挡伤害）
	_gm.deal_damage_to_unit(null, u, 99, false)
	_gm._cleanup_deaths()
	_check(not u.is_alive(), "不灭：伤害仍然能打死它")
	_mark(CardData.Keyword.INDESTRUCTIBLE)


# ------------------------------ 15. 术法免疫（不受能力伤害） ------------------------------

func _test_ability_immune() -> void:
	_prepare()
	var u := _spawn(FOE, _mk("kw_aim", "术免者", 2, 5, ["ability_immunity"]))
	var dealt: int = _gm.deal_damage_to_unit(null, u, 4, false)
	_check(dealt == 0 and u.health == 5, "术法免疫：能力伤害为 0")
	# 碰撞伤害照常
	var atk := _spawn(ME, _mk("kw_aim_a", "攻击者", 3, 3), true)
	var combat: int = _gm.deal_damage_to_unit(atk, u, 3, true)
	_check(combat == 3, "术法免疫：碰撞伤害照常（%d）" % combat)
	# 仍可被能力破坏
	var ctx := EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": FOE})
	ctx.kill_unit(u)
	_gm._cleanup_deaths()
	_check(not u.is_alive(), "术法免疫：能被能力破坏")
	_mark(CardData.Keyword.ABILITY_DAMAGE_IMMUNE)


# ------------------------------ 16. 碰撞免疫（双方都不受伤害） ------------------------------

func _test_collision_immune() -> void:
	_prepare()
	var atk := _spawn(ME, _mk("kw_cim_a", "碰撞免疫者", 5, 5,
		["collision_immunity", "charge", "windfury"]), true)
	var defender := _spawn(FOE, _mk("kw_cim_d", "靶子", 4, 8))
	var foe_p = _gm.get_player(FOE)
	var me_p = _gm.get_player(ME)
	_check(_gm.attack(ME, atk.unit_id, defender.unit_id, FOE), "碰撞免疫：攻击照常可以发起")
	_check(atk.health == 5, "碰撞免疫：自己不受反击伤害（%d）" % atk.health)
	_check(defender.health == 8, "碰撞免疫：对方也不受伤害（%d）" % defender.health)
	# 攻击英雄同样为 0
	var hp_before: int = foe_p.hero_hp
	_check(_gm.attack(ME, atk.unit_id, -1, FOE), "碰撞免疫：可以攻击英雄")
	_check(foe_p.hero_hp == hp_before, "碰撞免疫：攻击主战者同样 0 点（%d）" % foe_p.hero_hp)
	_check(me_p.units_died_total == 0, "碰撞免疫：没有人被打死")
	_mark(CardData.Keyword.COLLISION_DAMAGE_IMMUNE)


# ------------------------------ 16. 觉醒（影之诗「覚醒」） ------------------------------

func _test_awaken() -> void:
	_prepare()
	var u := _spawn(ME, _mk("kw_awk", "觉醒者", 2, 3, ["awaken"]))
	var me: PlayerState = _gm.get_player(ME)
	me.hero_hp = 20
	Mechanics.dispatch(u, "on_turn_start", {"gm": _gm, "unit": u, "pid": ME, "source": u})
	_check(u.attack == 2 and u.health == 3, "觉醒：生命 20 时不加身材（%d/%d）" % [u.attack, u.health])
	me.hero_hp = Mechanics.AWAKEN_HP
	Mechanics.dispatch(u, "on_turn_start", {"gm": _gm, "unit": u, "pid": ME, "source": u})
	_check(u.attack == 3 and u.health == 4,
		"觉醒：主战者生命 ≤ %d 时 +1/+1（%d/%d）" % [Mechanics.AWAKEN_HP, u.attack, u.health])
	# 只结算一次：再触发一次不会继续叠加（生命回到 20 也不会撤销）
	Mechanics.dispatch(u, "on_damaged", {"gm": _gm, "unit": u, "target": u, "amount": 1, "source": null})
	_check(u.attack == 3 and u.health == 4, "觉醒：只结算一次（%d/%d）" % [u.attack, u.health])
	# 反例：主战者生命充足时，己方与敌方都不该被加身材
	_prepare()
	var v := _spawn(FOE, _mk("kw_awk2", "觉醒者", 2, 3, ["awaken"]))
	_gm.get_player(FOE).hero_hp = 25
	Mechanics.dispatch(v, "on_turn_start", {"gm": _gm, "unit": v, "pid": FOE, "source": v})
	_check(v.attack == 2 and v.health == 3, "觉醒：敌方生命充足时同样不触发")
	_mark(CardData.Keyword.AWAKEN)


# ------------------------------ 词条覆盖检查 ------------------------------

func _test_coverage() -> void:
	var missed: Array[String] = []
	for k in CardData.KEYWORD_NAMES:
		if not bool(_covered.get(k, false)):
			missed.append(CardData.KEYWORD_NAMES[k])
	_check(missed.is_empty(), "全部 %d 个词条都跑了「满足条件就该触发」的用例（缺：%s）" % [
		CardData.KEYWORD_NAMES.size(), "、".join(missed)])


# ------------------------------ 14. 组合矩阵 ------------------------------

## 潜行 + 嘲讽：嘲讽要「能被敌方指定」才成立 —— 潜行期间它不吃嘲讽
func _pair_stealth_taunt() -> void:
	_prepare()
	var st := _spawn(FOE, _mk("pm_st", "潜行嘲讽", 2, 6, ["stealth", "taunt"]))
	var atk := _spawn(ME, _mk("pm_atk", "攻击者", 3, 3))
	var targets: Array = _gm.get_valid_attack_targets(ME, atk.unit_id)
	_check(_has_hero(targets), "潜行+嘲讽：敌方照样能打脸（嘲讽不成立）")
	_record(CardData.Keyword.STEALTH, CardData.Keyword.TAUNT, K_CONFLICT,
		"嘲讽要靠「敌方必须先打它」生效，而潜行让它不能被指定 → 潜行期间嘲讽形同虚设")
	# 潜行一解除嘲讽就恢复
	_gm.get_player(FOE).board.erase(st)
	st.remove_keyword(CardData.Keyword.STEALTH)
	_gm.get_player(FOE).place_unit_at(st, 0)
	var t2: Array = _gm.get_valid_attack_targets(ME, atk.unit_id)
	_check(t2.size() == 1 and t2[0]["unit_id"] == st.unit_id, "潜行解除后嘲讽立刻生效")


## 冲锋 + 迟钝：声明式标志位在 can_attack 里排在前面，迟钝吃掉冲锋
func _pair_charge_sluggish() -> void:
	_prepare()
	var u := _spawn(ME, _mk("pm_cs", "冲锋迟钝", 3, 3, ["charge", "sluggish"]), true)
	_check(not u.can_attack(_gm.turn_count, false), "冲锋+迟钝：当回合动不了")
	_record(CardData.Keyword.CHARGE, CardData.Keyword.SLUGGISH, K_CONFLICT,
		"迟钝的 cannot_attack 标志位优先：有冲锋也只能站着（配在同一张卡上等于白给）")


func _pair_rush_sluggish() -> void:
	_prepare()
	var u := _spawn(ME, _mk("pm_rs", "突袭迟钝", 3, 3, ["rush", "sluggish"]), true)
	_check(not u.can_attack(_gm.turn_count, true), "突袭+迟钝：当回合也打不了随从")
	_record(CardData.Keyword.RUSH, CardData.Keyword.SLUGGISH, K_CONFLICT,
		"同冲锋：迟钝让突袭完全失效")


func _pair_windfury_sluggish() -> void:
	_prepare()
	var u := _spawn(ME, _mk("pm_ws", "风怒迟钝", 3, 3, ["windfury", "sluggish"]))
	_check(u.max_attacks() == 2 and not u.can_attack(_gm.turn_count, true),
		"风怒+迟钝：上限仍是两次，但一次都用不出来")
	_record(CardData.Keyword.WINDFURY, CardData.Keyword.SLUGGISH, K_CONFLICT,
		"攻击次数上限照算，但攻击本身被禁用 → 风怒没有意义")


## 冲锋 + 突袭：两个「当回合可攻击」条件并存时按宽松的那个来
func _pair_charge_rush() -> void:
	_prepare()
	var u := _spawn(ME, _mk("pm_cr", "冲锋突袭", 3, 3, ["charge", "rush"]), true)
	_check(u.can_attack(_gm.turn_count, false), "冲锋+突袭：当回合能打英雄")
	_check(u.can_attack(_gm.turn_count, true), "冲锋+突袭：当回合也能打随从")
	_record(CardData.Keyword.CHARGE, CardData.Keyword.RUSH, K_OVERRIDE,
		"冲锋盖过突袭（能打英雄）；突袭在这里没有任何额外贡献")


func _pair_windfury_charge() -> void:
	_prepare()
	var u := _spawn(ME, _mk("pm_wc", "风怒冲锋", 2, 6, ["windfury", "charge"]), true)
	var foe: PlayerState = _gm.get_player(FOE)
	var before: int = foe.hero_hp
	_check(_gm.attack(ME, u.unit_id, -1, FOE), "风怒+冲锋：当回合第一次打脸")
	_check(_gm.attack(ME, u.unit_id, -1, FOE), "风怒+冲锋：当回合第二次打脸")
	_check(foe.hero_hp == before - 4, "两次共 %d 点伤害（%d → %d）" % [
		before - foe.hero_hp, before, foe.hero_hp])
	_record(CardData.Keyword.WINDFURY, CardData.Keyword.CHARGE, K_STACK,
		"各自生效：当回合两次攻击都可以打英雄")


## 圣盾 + 坚壁：圣盾先挡下一次（一点血都不掉），破盾之后坚壁再接管
func _pair_shield_stalwart() -> void:
	_prepare()
	var u := _spawn(FOE, _mk("pm_ss", "圣盾坚壁", 2, 5, ["shield", "stalwart"]))
	var d1: int = _gm.deal_damage_to_unit(null, u, 6)
	_check(d1 == 0 and u.health == 5, "圣盾+坚壁：第一次伤害被盾吃掉（实际 %d）" % d1)
	var d2: int = _gm.deal_damage_to_unit(null, u, 6)
	_check(d2 == 1 and u.health == 4, "破盾之后坚壁把伤害压到 1（实际 %d）" % d2)
	_record(CardData.Keyword.DIVINE_SHIELD, CardData.Keyword.STALWART, K_OVERRIDE,
		"结算顺序固定：圣盾先生效（该次伤害为 0），之后才轮到坚壁减伤")


## 剧毒（攻） + 圣盾（守）：没造成伤害 → 剧毒不触发
func _pair_poison_shield() -> void:
	_prepare()
	var ps := _spawn(ME, _mk("pm_poi", "毒刺客", 2, 2, ["poisonous"]))
	var sh := _spawn(FOE, _mk("pm_sh", "圣盾兵", 2, 3, ["shield"]))
	_check(_gm.attack(ME, ps.unit_id, sh.unit_id, FOE), "剧毒攻击圣盾随从")
	_check(sh.is_alive() and sh.health == 3, "剧毒+圣盾：盾挡下伤害，目标活下来（%d）" % sh.health)
	_record(CardData.Keyword.POISONOUS, CardData.Keyword.DIVINE_SHIELD, K_OVERRIDE,
		"圣盾挡下的那一次算「没造成伤害」→ 剧毒不结算")


## 剧毒（攻） + 坚壁（守）：坚壁只压伤害，压不住剧毒的直接消灭
func _pair_poison_stalwart() -> void:
	_prepare()
	var ps := _spawn(ME, _mk("pm_poi2", "毒刺客", 2, 2, ["poisonous"]))
	var sw := _spawn(FOE, _mk("pm_sw", "坚壁墙", 2, 5, ["stalwart"]))
	_check(_gm.attack(ME, ps.unit_id, sw.unit_id, FOE), "剧毒攻击坚壁随从")
	_check(not sw.is_alive(), "剧毒+坚壁：坚壁挡不住剧毒（生命 %d）" % sw.health)
	_record(CardData.Keyword.POISONOUS, CardData.Keyword.STALWART, K_CONFLICT,
		"「任何伤害减为 1」挡不住剧毒：剧毒是直接把生命置 0，与减伤不在同一层（文案要说清楚）")


## 吸血 + 剧毒：两个钩子挂同一个事件 → 一条都不能少
func _pair_lifesteal_poison() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var u := _spawn(ME, _mk("pm_lp", "吸血毒刃", 3, 4, ["lifesteal", "poisonous"]))
	var victim := _spawn(FOE, _mk("pm_lp_v", "猎物", 8, 8))
	me.hero_hp = 20
	_check(_gm.attack(ME, u.unit_id, victim.unit_id, FOE), "吸血剧毒随从攻击")
	_check(me.hero_hp == 23, "吸血照常回血（20 → %d）" % me.hero_hp)
	_check(not victim.is_alive(), "剧毒照常消灭（敌方场上 %d）" % _gm.get_player(FOE).board.size())
	_record(CardData.Keyword.LIFESTEAL, CardData.Keyword.POISONOUS, K_STACK,
		"同一份伤害事件上两个钩子都跑：先回血再消灭")


## 潜行 + 法术伤害：站在后面的法伤单位照样给法术加成
func _pair_stealth_spell_damage() -> void:
	_prepare()
	_spawn(ME, _mk("pm_sd_st", "潜行法伤", 1, 3, ["stealth", "spell_damage"], 2))
	var victim := _spawn(FOE, _mk("pm_sd_v", "靶子", 2, 6))
	_check(_gm.spell_damage_bonus(ME) == 2, "潜行法伤仍计入 +%d" % _gm.spell_damage_bonus(ME))
	_check(_play_card(ME, _mk_spell("pm_sd_sp", "火球", "damage", 2,
		CardData.Targeting.ANY_CHARACTER), victim.unit_id, FOE), "打出 2 点伤害法术")
	_check(victim.health == 2, "2 点变 4 点（6 → %d）" % victim.health)
	_record(CardData.Keyword.STEALTH, CardData.Keyword.SPELL_DAMAGE, K_STACK,
		"互不影响：潜行不影响它对全队法术的加成")


## 迟钝 + 法术伤害：不能攻击不等于不能提供加成
func _pair_sluggish_spell_damage() -> void:
	_prepare()
	var u := _spawn(ME, _mk("pm_sd_sl", "迟钝法伤", 1, 3, ["sluggish", "spell_damage"], 2))
	_check(not u.can_attack(_gm.turn_count, true), "它确实不能攻击")
	var victim := _spawn(FOE, _mk("pm_sd_v2", "靶子", 2, 6))
	_check(_play_card(ME, _mk_spell("pm_sd_sp2", "火球", "damage", 2,
		CardData.Targeting.ANY_CHARACTER), victim.unit_id, FOE), "打出 2 点伤害法术")
	_check(victim.health == 2, "照样吃到 +2（6 → %d）" % victim.health)
	_record(CardData.Keyword.SLUGGISH, CardData.Keyword.SPELL_DAMAGE, K_STACK,
		"迟钝只禁攻击，法术伤害照给")


## 复生 + 潜行：复生是按**卡数据**重建单位，已经解除的潜行会被一并「洗」回来
func _pair_reborn_stealth() -> void:
	_prepare()
	var rb := _spawn(ME, _mk("pm_rbs", "潜行复生", 3, 3, ["reborn", "stealth"]))
	rb.remove_keyword(CardData.Keyword.STEALTH)      # 比如它攻击过，潜行已解除
	_check(not rb.has_mechanic(CardData.Keyword.STEALTH), "攻击后潜行已解除")
	_gm.deal_damage_to_unit(null, rb, 5)
	_gm._cleanup_deaths()
	var back: BoardUnit = _find_unit(ME, "pm_rbs")
	_check(back != null, "复生成功")
	_check(back != null and back.has_mechanic(CardData.Keyword.STEALTH),
		"复生把已经解除的潜行还了回来（%s）" % ("，".join(back.mechanic_names()) if back != null else "无"))
	_record(CardData.Keyword.REBORN, CardData.Keyword.STEALTH, K_CONFLICT,
		"复生用卡数据重建单位 → 运行时已经解除的潜行（同理还有沉默掉的临时状态）会被还原")


## 复生 + 迟钝：上限 / 状态是照搬的，迟钝不会因为死过一次就消失
func _pair_reborn_sluggish() -> void:
	_prepare()
	var rb := _spawn(ME, _mk("pm_rbsl", "迟钝复生", 3, 3, ["reborn", "sluggish"]))
	_gm.deal_damage_to_unit(null, rb, 5)
	_gm._cleanup_deaths()
	var back: BoardUnit = _find_unit(ME, "pm_rbsl")
	_check(back != null and not back.can_attack(_gm.turn_count, true), "复生回来还是迟钝")
	_record(CardData.Keyword.REBORN, CardData.Keyword.SLUGGISH, K_STACK,
		"复生只改生命值，词条照旧保留")


## 嘲讽 + 圣盾：各管一段，互不打扰
func _pair_taunt_shield() -> void:
	_prepare()
	var t := _spawn(FOE, _mk("pm_ts", "嘲讽圣盾", 2, 3, ["taunt", "shield"]))
	var atk := _spawn(ME, _mk("pm_ts_a", "攻击者", 3, 3))
	var targets: Array = _gm.get_valid_attack_targets(ME, atk.unit_id)
	_check(targets.size() == 1 and targets[0]["unit_id"] == t.unit_id, "嘲讽成立：只能打它")
	_check(_gm.attack(ME, atk.unit_id, t.unit_id, FOE), "攻击它")
	_check(t.is_alive() and t.health == 3, "圣盾把这次伤害吃掉了（剩 %d）" % t.health)
	_record(CardData.Keyword.TAUNT, CardData.Keyword.DIVINE_SHIELD, K_STACK,
		"一个管选目标、一个管减伤，互不干扰")


# ------------------------------ 15. 后到者覆盖：冲突的效果 ------------------------------
#
# 口径（本作）：效果冲突时**后给予的那个说话** —— 它把与之冲突的旧机制 / 旧状态覆盖掉。
# 只管**运行时被赋予**的效果：卡上本来就印着两个互斥词条时没有先后之分，两个都留着
# （上一节那些标成「冲突」的组合记的就是这种配卡层面的取舍）。

func _override_registry() -> void:
	var audit: Dictionary = Mechanics.audit()
	_check(PackedStringArray(audit.get("bad_conflicts", [])).is_empty(),
		"互斥表自检干净（指向未注册 / 不对称的项：%s）" % str(audit.get("bad_conflicts", [])))
	_check(int(audit.get("conflict_pairs", 0)) >= 3, "互斥表里有 %d 对" % int(
		audit.get("conflict_pairs", 0)))
	_check(Mechanics.conflicts_with(CardData.Keyword.STEALTH, CardData.Keyword.TAUNT),
		"潜行 ↔ 嘲讽 互斥")
	_check(Mechanics.conflicts_with(CardData.Keyword.TAUNT, CardData.Keyword.STEALTH),
		"互斥是双向的")
	_check(not Mechanics.conflicts_with(CardData.Keyword.TAUNT, CardData.Keyword.LIFESTEAL),
		"不冲突的组合不会被覆盖")


## 先潜行、后嘲讽：后到的嘲讽把潜行顶掉，嘲讽真的成立
func _override_stealth_then_taunt() -> void:
	_prepare()
	var st := _spawn(ME, _mk("ov_st", "潜行兵", 2, 6, ["stealth"]))
	var atk := _spawn(FOE, _mk("ov_st_a", "敌方攻击者", 3, 3))
	_play_card(ME, _mk_spell("ov_st_s", "贴上嘲讽", "grant_taunt", 0,
		int(CardData.Targeting.ANY_MINION)), st.unit_id, ME)
	_check(st.has_keyword(CardData.Keyword.TAUNT), "后赋予的嘲讽挂上了")
	_check(not st.has_keyword(CardData.Keyword.STEALTH), "潜行被覆盖掉（现剩：%s）" % (
		"，".join(st.mechanic_names())))
	var targets: Array = _gm.get_valid_attack_targets(FOE, atk.unit_id)
	_check(targets.size() == 1 and _has_unit(targets, st.unit_id),
		"覆盖之后嘲讽成立：敌方只能打它（%d 个目标）" % targets.size())
	_check(not _has_hero(targets), "敌方再也不能越过它直接打脸")


## 反过来：先嘲讽、后潜行 → 嘲讽被顶掉
func _override_taunt_then_stealth() -> void:
	_prepare()
	var t := _spawn(ME, _mk("ov_ts", "嘲讽墙", 2, 6, ["taunt"]))
	var atk := _spawn(FOE, _mk("ov_ts_a", "敌方攻击者", 3, 3))
	_play_card(ME, _mk_spell("ov_ts_s", "来一手潜行", "grant_stealth", 0,
		int(CardData.Targeting.ALLY_MINION)), t.unit_id, ME)
	_check(t.has_keyword(CardData.Keyword.STEALTH), "后赋予的潜行挂上了")
	_check(not t.has_keyword(CardData.Keyword.TAUNT), "嘲讽被覆盖掉（现剩：%s）" % (
		"，".join(t.mechanic_names())))
	var targets: Array = _gm.get_valid_attack_targets(FOE, atk.unit_id)
	_check(_has_hero(targets), "覆盖之后潜行说了算：敌方又能直接打脸了")


## 迟钝 + 后赋予的冲锋：后到的冲锋把迟钝顶掉 → 当回合就能打
func _override_sluggish_then_charge() -> void:
	_prepare()
	var u := _spawn(ME, _mk("ov_sc", "迟钝兵", 3, 3, ["sluggish"]), true)
	_check(not u.can_attack(_gm.turn_count, false), "（对照）迟钝的时候不能攻击")
	_play_card(ME, _mk_spell("ov_sc_s", "给它冲锋", "grant_charge", 0,
		int(CardData.Targeting.ALLY_MINION)), u.unit_id, ME)
	_check(u.has_keyword(CardData.Keyword.CHARGE), "后赋予的冲锋挂上了")
	_check(not u.has_keyword(CardData.Keyword.SLUGGISH), "迟钝被覆盖掉（现剩：%s）" % (
		"，".join(u.mechanic_names())))
	_check(u.can_attack(_gm.turn_count, false), "覆盖之后它当回合就能打脸")


## 冻结 + 后赋予的冲锋：后到的冲锋把冻结顶掉 → 解冻
func _override_frozen_then_charge() -> void:
	_prepare()
	var u := _spawn(ME, _mk("ov_fc", "被冻住的兵", 3, 3), true)
	u.frozen_until = _gm.turn_count + 1
	_check(not u.can_attack(_gm.turn_count, false), "（对照）冻结的时候不能攻击")
	_play_card(ME, _mk_spell("ov_fc_s", "给它冲锋", "grant_charge", 0,
		int(CardData.Targeting.ALLY_MINION)), u.unit_id, ME)
	_check(not u.is_frozen(_gm.turn_count + 1), "冻结被覆盖掉 → 解冻")
	_check(u.can_attack(_gm.turn_count, false), "解冻之后它就能攻击了")


## 反过来：带着冲锋的单位被冻结 → 后到的冻结把冲锋顶掉
func _override_charge_then_frozen() -> void:
	_prepare()
	var u := _spawn(FOE, _mk("ov_cf", "冲锋兵", 3, 3, ["charge"]), true)
	_play_card(ME, _mk_spell("ov_cf_s", "冻住它", "freeze", 0,
		int(CardData.Targeting.ENEMY_MINION)), u.unit_id, FOE)
	_check(u.is_frozen(_gm.turn_count + 1), "冻结生效")
	_check(not u.has_keyword(CardData.Keyword.CHARGE), "冲锋被覆盖掉（现剩：%s）" % (
		"，".join(u.mechanic_names())))
	_check(not u.can_attack(_gm.turn_count, false), "它当回合动不了")


## 对照：卡上本来就印着两个互斥词条的（没有先后）不会被这条规则改写
func _override_keeps_printed_combo() -> void:
	_prepare()
	var both := _spawn(FOE, _mk("ov_both", "自带潜行+嘲讽", 2, 6, ["stealth", "taunt"]))
	_check(both.has_keyword(CardData.Keyword.STEALTH) and both.has_keyword(CardData.Keyword.TAUNT),
		"卡自带的一对互斥词条：不谈先后，两个都留着")
	var sluggish_charge := _spawn(FOE, _mk("ov_both2", "自带冲锋+迟钝", 3, 3,
		["charge", "sluggish"]))
	_check(sluggish_charge.has_keyword(CardData.Keyword.CHARGE)
		and sluggish_charge.has_keyword(CardData.Keyword.SLUGGISH), "自带冲锋+迟钝同样都留着")


## 对照：不冲突的效果照常叠加，谁也不挤谁
func _override_no_conflict_stacks() -> void:
	_prepare()
	var u := _spawn(ME, _mk("ov_stack", "嘲讽兵", 2, 3, ["taunt"]))
	_play_card(ME, _mk_spell("ov_stack_s", "给它吸血", "grant_lifesteal", 0,
		int(CardData.Targeting.ALLY_MINION)), u.unit_id, ME)
	_check(u.has_keyword(CardData.Keyword.TAUNT) and u.has_keyword(CardData.Keyword.LIFESTEAL),
		"不冲突：嘲讽照旧，吸血也挂上了（%s）" % "，".join(u.mechanic_names()))


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	_gm.current_player = ME
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	me.reset_slots()
	foe.reset_slots()
	me.mana = 10
	me.max_mana = 10
	foe.mana = 10
	foe.max_mana = 10


## 合成一张随从卡（用它在每一格里跑引擎）
func _mk(id: String, name_: String, atk: int, hp: int, keys: Array = [],
		spell_dmg: int = 0) -> CardData:
	var d := {
		"id": id, "card_name": name_, "cost": 1,
		"card_type": int(CardData.CardType.MINION),
		"attack": atk, "health": hp, "keywords": keys,
	}
	if spell_dmg != 0:
		d["spell_damage"] = spell_dmg
	return CardData.from_dict(d)


func _mk_spell(id: String, name_: String, eid: String, value: int, target: int) -> CardData:
	return CardData.from_dict({
		"id": id, "card_name": name_, "cost": 1,
		"card_type": int(CardData.CardType.SPELL),
		"effects": [{"id": eid, "value": value, "target": int(target), "token": ""}],
	})


## `this_turn` = 当成「刚刚召唤上场」（用于验证冲锋 / 突袭的当回合条件）
func _spawn(pid: int, card: CardData, this_turn: bool = false) -> BoardUnit:
	var u := BoardUnit.new()
	_uid += 1
	u.setup(card.clone(), pid, _gm.turn_count if this_turn else -1, _uid)
	var p: PlayerState = _gm.get_player(pid)
	p.place_unit_at(u, p.first_empty_slot())
	return u


func _play_card(pid: int, card: CardData, unit_id: int, player_id: int) -> bool:
	var p: PlayerState = _gm.get_player(pid)
	p.mana = 10
	p.hand.append(card.clone())
	return _gm.play_card(pid, p.hand.size() - 1, unit_id, player_id)


func _find_unit(pid: int, card_id: String) -> BoardUnit:
	var p: PlayerState = _gm.get_player(pid)
	for u in p.board:
		if u != null and u.data.id == card_id:
			return u
	return null


func _has_unit(targets: Array, unit_id: int) -> bool:
	for t in targets:
		if str(t.get("kind", "")) == "unit" and int(t.get("unit_id", -1)) == unit_id:
			return true
	return false


func _has_hero(targets: Array) -> bool:
	for t in targets:
		if str(t.get("kind", "")) == "hero":
			return true
	return false


func _mark(keyword: int) -> void:
	_covered[keyword] = true


func _record(a: int, b: int, kind: String, note: String) -> void:
	_pairs.append({"a": a, "b": b, "kind": kind, "note": note})


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _print_matrix() -> void:
	print("")
	print("=========== 词条相互作用清单 ===========")
	for kind in [K_CONFLICT, K_OVERRIDE, K_STACK]:
		for e in _pairs:
			if str(e["kind"]) != kind:
				continue
			print("[%s] %s + %s" % [kind, Mechanics.display_name(int(e["a"])),
				Mechanics.display_name(int(e["b"]))])
			print("      " + str(e["note"]))
	print("----------------------------------------")
	print("合计 %d 组：冲突 %d / 压制 %d / 叠加 %d" % [_pairs.size(),
		_count_kind(K_CONFLICT), _count_kind(K_OVERRIDE), _count_kind(K_STACK)])


func _count_kind(kind: String) -> int:
	var n := 0
	for e in _pairs:
		if str(e["kind"]) == kind:
			n += 1
	return n


func _finish() -> void:
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 关键字矩阵测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
