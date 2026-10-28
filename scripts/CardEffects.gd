class_name CardEffects
extends RefCounted
## 卡牌效果注册表（效果系统的唯一入口）。
##
## 新增一张新效果卡牌只需两步：
##   1. 在下方 _register() 里加一行 _reg(...)，写明 id / 名称 / 文本模板 / 默认目标 / 执行函数；
##   2. 在 _fx_xxx(ctx) 里用 EffectContext 的高层操作实现效果。
## 之后卡面文本、悬停详情、管理员面板下拉、AI 评估都会自动支持它。
##
## 文本模板中的 {v} 会被替换为卡牌的效果数值。

const NONE := "none"
## 随机能力：从「随机能力池」（AbilityPools）随机抽若干个能力并逐个结算。
## 效果条目里 token = 能力池 ID；value > 0 时覆盖池子的随机个数范围（0 = 用池子的 min–max）。
const RANDOM_POOL := "random_pool"
## 化身：把目标随从替换成 token 指定的另一张随从卡（不触发离场 / 入场能力）
const TRANSFORM := "transform"
## 赋予技能：把 token 指定卡牌的**主动技能**复制给目标随从（覆盖它当前的主动技能）
const GRANT_SKILL := "grant_skill"
## 赋予能力：把 token 指定卡牌的**触发能力**（triggers）追加给目标随从
const GRANT_ABILITY := "grant_ability"
## 随机获得技能 / 能力 / 效果：token = 来源范围（见 SCOPE_LABELS /
## pack:<id> / troop:<id>），value = 取几个来源。
const GAIN_RANDOM_SKILL := "gain_random_skill"
const GAIN_RANDOM_ABILITY := "gain_random_ability"
const GAIN_RANDOM_EFFECT := "gain_random_effect"

## 牌库 / 手牌改造：token 是**复合参数**「区域|目标」（竖线分隔），value = 张数。
##   * replace_cards       `deck|card:t001` / `hand|enemy_hand` / `enemy_deck|card:t001`
##       区域：deck（本方牌库）/ hand（本方手牌）/ enemy_deck / enemy_hand
##       目标：card:<卡牌 ID>（指定卡）/ enemy_hand（对手手牌）/ enemy_deck（对手牌堆）
##   * destroy_deck_cards  `deck|random` / `enemy_deck|cost:2` / `deck|effect:damage`
##       牌库：deck / enemy_deck
##       筛选：random / card:<卡牌 ID> / name:<卡名> / cost:<费用> / effect:<效果 ID>
##       value = 张数上限（0 = 所有匹配的卡；random 至少 1 张）
##   * add_cards_to_deck   `deck|card:t001` / `enemy_deck|pack:basic,chaos`
##       牌库：deck / enemy_deck
##       来源：card:<卡牌 ID>（指定卡）/ pack:<卡包 ID>[,<卡包 ID>...]（卡包范围内随机）
##       value = 加入张数（可以重复抽到同一张）
const REPLACE_CARDS := "replace_cards"
const DESTROY_DECK_CARDS := "destroy_deck_cards"
const ADD_CARDS_TO_DECK := "add_cards_to_deck"

## 费用筛选上限（与 GameManager.MAX_MANA 一致；CardEffects 被 CardData 早期依赖，
## 不能静态引用 GameManager 自动加载，否则会在自动加载注册前被拉进编译）
const SPEC_COST_LIMIT := 10

## 随机获得类的「来源范围」（写在效果条目的 token 字段里）。
## 场上随从取的是**当前**的卡面数据（含先前被赋予的技能 / 能力），手牌 / 牌库 / 卡表取卡牌本体。
##   * pack:<卡包 ID>  → 该卡包里的所有卡（CardDB.packs）
##   * troop:<兵种 ID> → 该兵种的所有卡（未登记 / 留空 = 内置「中立」）
const SCOPE_LABELS := {
	"board": "本方场上随从",
	"enemy_board": "敌方场上随从",
	"any_board": "双方场上随从",
	"hand": "本方手牌",
	"enemy_hand": "敌方手牌",
	"any_hand": "双方手牌",
	"deck": "本方牌库",
	"enemy_deck": "敌方牌库",
	"any_deck": "双方牌库",
	"all": "双方场上、手牌与牌库",
}

## AI 评估用的效果类别提示（决定 AI 如何给这张牌打分）
const HINT_DAMAGE := "damage"
const HINT_REMOVAL := "removal"
const HINT_HEAL := "heal"
const HINT_DRAW := "draw"
const HINT_BUFF := "buff"
const HINT_SUMMON := "summon"
const HINT_MANA := "mana"
const HINT_UTILITY := "utility"

static var _registry: Dictionary = {}
static var _order: Array[String] = []


# ------------------------------ 注册 ------------------------------

static func _ensure() -> void:
	if _registry.is_empty():
		_register()


static func _reg(id: String, display: String, text_tpl: String, default_target: int,
		fn: Callable, hint: String = "", needs_token: bool = false, aoe: bool = false,
		needs_src: bool = false, needs_turns: bool = false, needs_pool: bool = false,
		needs_card_ref: bool = false, needs_scope: bool = false,
		needs_spec: bool = false) -> void:
	_registry[id] = {
		"id": id,
		"name": display,
		"text": text_tpl,
		"target": default_target,
		"fn": fn,
		"hint": hint,
		"token": needs_token,
		## 能力池：随机能力效果要在条目里填「池 ID」（与衍生物 ID 共用 token 字段，
		## 但面板会按这个标记把输入框提示改成「能力池 ID」）。
		"pool": needs_pool,
		## 卡牌引用：赋予技能 / 能力的效果要在条目里填**来源卡牌 ID**（同样共用 token 字段）。
		"card_ref": needs_card_ref,
		## 来源范围：随机获得类效果在 token 里填 board / hand / pack:xxx 这类范围。
		"scope": needs_scope,
		## 复合参数：牌库 / 手牌改造类效果在 token 里填「区域|目标」（如 deck|card:t001）。
		"spec": needs_spec,
		## 限定词缀：这两项告诉面板要为这一条效果多显示哪些控件（用不上的效果不显示）。
		##   * src   来源限定（牌库 / 墓地 / 牌库优先）—— 检索类效果用它决定去哪儿翻牌；
		##   * turns 持续回合数（0 = 永久或一次性）—— 限时负累类效果用它决定什么时候自然失效。
		"need_src": needs_src,
		"need_turns": needs_turns,
		# 群体效果由效果自身遍历所有目标，结算时只能调用一次。
		# ALL_* 的默认目标天然是群体；aoe_all 这类“默认目标为 NONE”的效果必须显式声明，
		# 否则当卡表把它配成 ALL_* 目标时会被逐目标重复结算（伤害被放大 N 倍）。
		"aoe": aoe or default_target == CardData.Targeting.ALL_ENEMY_MINIONS
			or default_target == CardData.Targeting.ALL_ALLY_MINIONS,
	}
	_order.append(id)


## ------------------------------ 运行期效果（外挂扩展包用） ------------------------------
## `CardEffects._reg()` 是内置效果的登记入口；外部扩展包（`scripts/ModLoader.gd`）调用这个
## 公开包装，重复登记同一个 ID 时**覆盖并移到末尾**（避免 ids() 出现重复项）。
## 参数与 `_reg` 完全一致；`fn` 是扩展包脚本里提供的 `Callable`（签名 `func(ctx: EffectContext)`）。
static func register(id: String, display: String, text_tpl: String, default_target: int,
		fn: Callable, hint: String = "", needs_token: bool = false, aoe: bool = false,
		needs_src: bool = false, needs_turns: bool = false, needs_pool: bool = false,
		needs_card_ref: bool = false, needs_scope: bool = false,
		needs_spec: bool = false) -> void:
	_ensure()
	while _order.has(id):
		_order.erase(id)
	_reg(id, display, text_tpl, default_target, fn, hint, needs_token, aoe,
		needs_src, needs_turns, needs_pool, needs_card_ref, needs_scope, needs_spec)


static func _register() -> void:
	var T := CardData.Targeting
	_reg(NONE, "无效果", "", T.NONE, CardEffects._fx_none, "")

	# ---- 伤害 / 消灭 ----
	_reg("damage", "造成伤害", "造成 {v} 点伤害", T.ANY_CHARACTER, CardEffects._fx_damage, HINT_DAMAGE)
	_reg("damage_hero", "直伤打脸", "对敌方英雄造成 {v} 点伤害", T.NONE, CardEffects._fx_damage_hero, HINT_DAMAGE)
	_reg("aoe_enemy", "群体伤害（敌方）", "对所有敌方随从造成 {v} 点伤害", T.ALL_ENEMY_MINIONS, CardEffects._fx_aoe_enemy, HINT_DAMAGE)
	_reg("aoe_all", "群体伤害（全场）", "对所有随从造成 {v} 点伤害", T.NONE, CardEffects._fx_aoe_all, HINT_DAMAGE, false, true)
	_reg("destroy", "消灭随从", "消灭目标随从", T.ENEMY_MINION, CardEffects._fx_destroy, HINT_REMOVAL)
	_reg("destroy_random", "随机消灭敌方随从", "随机消灭一个敌方随从", T.NONE, CardEffects._fx_destroy_random, HINT_REMOVAL)

	# ---- 治疗 / 护甲 ----
	_reg("heal", "恢复生命", "恢复 {v} 点生命", T.ANY_CHARACTER, CardEffects._fx_heal, HINT_HEAL)
	_reg("heal_all_ally", "群体治疗", "为所有友方随从恢复 {v} 点生命", T.ALL_ALLY_MINIONS, CardEffects._fx_heal_all_ally, HINT_HEAL)
	_reg("armor", "获得护甲", "获得 {v} 点护甲", T.NONE, CardEffects._fx_armor, HINT_UTILITY)

	# ---- 抽牌 / 资源 ----
	_reg("draw", "抽牌", "抽 {v} 张牌", T.NONE, CardEffects._fx_draw, HINT_DRAW)
	_reg("enemy_draw", "迫使对手抽牌", "使对手抽 {v} 张牌", T.NONE, CardEffects._fx_enemy_draw, HINT_UTILITY)
	_reg("mana", "获得法力", "本回合获得 {v} 点法力", T.NONE, CardEffects._fx_mana, HINT_MANA)
	_reg("mana_crystal", "法力水晶", "获得 {v} 个法力水晶", T.NONE, CardEffects._fx_mana_crystal, HINT_MANA)
	_reg("discard_enemy", "迫使对手弃牌", "使对手随机弃 {v} 张牌", T.NONE, CardEffects._fx_discard_enemy, HINT_UTILITY)

	# ---- 召唤 ----
	_reg("summon", "召唤衍生物", "召唤 {v} 个衍生物", T.NONE, CardEffects._fx_summon, HINT_SUMMON, true)
	_reg("copy_ally", "复制友方随从", "复制一个友方随从", T.ALLY_MINION, CardEffects._fx_copy_ally, HINT_SUMMON)

	# ---- 强化 / 削弱 / 赋予关键字 ----
	_reg("buff", "强化随从", "使目标随从获得 +{v}/+{v}", T.ANY_MINION, CardEffects._fx_buff, HINT_BUFF)
	_reg("buff_attack", "强化攻击", "使目标随从获得 +{v} 攻击力", T.ANY_MINION, CardEffects._fx_buff_attack, HINT_BUFF)
	_reg("buff_health", "强化生命", "使目标随从获得 +0/+{v} 生命", T.ANY_MINION, CardEffects._fx_buff_health, HINT_BUFF)
	_reg("buff_all_ally", "群体强化", "使所有友方随从获得 +{v}/+{v}", T.ALL_ALLY_MINIONS, CardEffects._fx_buff_all_ally, HINT_BUFF)
	_reg("debuff", "削弱随从", "使目标随从获得 -{v}/-{v}", T.ENEMY_MINION, CardEffects._fx_debuff, HINT_REMOVAL)
	_reg("grant_taunt", "赋予嘲讽", "使目标随从获得嘲讽", T.ANY_MINION, CardEffects._fx_grant_taunt, HINT_BUFF)
	_reg("grant_shield", "赋予圣盾", "使目标随从获得圣盾", T.ANY_MINION, CardEffects._fx_grant_shield, HINT_BUFF)
	_reg("grant_charge", "赋予冲锋", "使目标随从获得冲锋（可立即攻击）", T.ALLY_MINION, CardEffects._fx_grant_charge, HINT_BUFF)
	_reg("grant_windfury", "赋予风怒", "使目标随从获得风怒", T.ALLY_MINION, CardEffects._fx_grant_windfury, HINT_BUFF)
	# 机制类：把 Mechanics 里注册的机制赋予随从（新增机制后照抄这三行即可）
	_reg("grant_lifesteal", "赋予吸血", "使目标随从获得吸血", T.ALLY_MINION, CardEffects._fx_grant_lifesteal, HINT_BUFF)
	_reg("grant_poisonous", "赋予剧毒", "使目标随从获得剧毒", T.ALLY_MINION, CardEffects._fx_grant_poisonous, HINT_BUFF)
	_reg("grant_stealth", "赋予潜行", "使目标随从获得潜行", T.ALLY_MINION, CardEffects._fx_grant_stealth, HINT_BUFF)

	# ---- 赋予技能 / 能力（从另一张卡的卡面复制过来）----
	# token = 来源卡牌 ID：grant_skill 复制那张卡的主动技能（覆盖当前技能），
	# grant_ability 追加那张卡的触发能力（多个触发同时生效）。
	_reg(GRANT_SKILL, "赋予技能", "使目标随从获得指定卡牌的主动技能（覆盖当前技能）", T.ANY_MINION,
		CardEffects._fx_grant_skill, HINT_BUFF, false, false, false, false, false, true)
	_reg(GRANT_ABILITY, "赋予能力", "使目标随从获得指定卡牌的触发能力", T.ANY_MINION,
		CardEffects._fx_grant_ability, HINT_BUFF, false, false, false, false, false, true)

	# ---- 随机获得技能 / 能力 / 效果（来源范围）----
	# token = 来源范围（见 SCOPE_LABELS）；value = 抽几个来源。
	#   * 技能：随从只有一个技能栏，固定抽 1 个（value 不生效），覆盖当前技能；
	#   * 能力：抽 value 个来源，把它们身上的触发能力全部追加到目标身上；
	#   * 效果：抽 value 个来源，把它们的战吼 / 法术效果链**当场按顺序结算**（不挂在目标身上）。
	_reg(GAIN_RANDOM_SKILL, "随机获得技能", "从指定范围随机获得一个主动技能（覆盖当前技能）", T.ALLY_MINION,
		CardEffects._fx_gain_random_skill, HINT_BUFF, false, false, false, false, false, false, true)
	_reg(GAIN_RANDOM_ABILITY, "随机获得能力", "从指定范围随机获得 {v} 个来源的触发能力", T.ALLY_MINION,
		CardEffects._fx_gain_random_ability, HINT_BUFF, false, false, false, false, false, false, true)
	_reg(GAIN_RANDOM_EFFECT, "随机获得效果", "从指定范围随机结算 {v} 个来源的效果", T.NONE,
		CardEffects._fx_gain_random_effect, HINT_UTILITY, false, false, false, false, false, false, true)

	# ---- 牌库 / 手牌改造（token = 区域|目标，见 REPLACE_CARDS 顶部的写法说明）----
	# 这三条都需要两个参数（动哪一方的哪个区域 + 用什么），所以 token 用竖线拼接；
	# 卡面文本由 spec_text() 动态生成，管理员改 token 后文本同步变化。
	_reg(REPLACE_CARDS, "替换卡牌", "", T.NONE, CardEffects._fx_replace_cards,
		HINT_UTILITY, false, false, false, false, false, false, false, true)
	_reg(DESTROY_DECK_CARDS, "破坏牌库卡牌", "", T.NONE, CardEffects._fx_destroy_deck_cards,
		HINT_REMOVAL, false, false, false, false, false, false, false, true)
	_reg(ADD_CARDS_TO_DECK, "向牌库加牌", "", T.NONE, CardEffects._fx_add_cards_to_deck,
		HINT_UTILITY, false, false, false, false, false, false, false, true)

	# ---- 控制 ----
	_reg("freeze", "冻结", "冻结目标随从（下回合无法攻击）", T.ENEMY_MINION, CardEffects._fx_freeze, HINT_UTILITY)
	_reg("silence", "沉默", "沉默目标随从（移除关键字与增益）", T.ANY_MINION, CardEffects._fx_silence, HINT_REMOVAL)
	_reg("return_hand", "返回手牌", "将目标随从移回其拥有者手牌", T.ANY_MINION, CardEffects._fx_return_hand, HINT_REMOVAL)
	_reg("discover", "发现", "从三张随机卡牌中发现一张加入手牌", T.NONE, CardEffects._fx_discover, HINT_UTILITY)

	# ---- 战斗限制 / 减免 / 状态（词条与效果一一对应，卡表也能直接带词条）----
	_reg("grant_indestructible", "赋予不灭", "使目标随从获得「不灭」（不会被能力破坏）",
		T.ALLY_MINION, CardEffects._fx_grant_indestructible, HINT_BUFF)
	_reg("grant_ability_immune", "赋予术法免疫", "使目标随从获得「术法免疫」（不受能力伤害）",
		T.ALLY_MINION, CardEffects._fx_grant_ability_immune, HINT_BUFF)
	_reg("grant_collision_immune", "赋予碰撞免疫", "使目标随从获得「碰撞免疫」（碰撞双方都不受伤害）",
		T.ALLY_MINION, CardEffects._fx_grant_collision_immune, HINT_BUFF)
	_reg("grant_ability_reduction", "能力伤害减免", "使目标随从受到的能力伤害减少 {v} 点",
		T.ANY_MINION, CardEffects._fx_ability_reduction, HINT_BUFF)
	_reg("grant_collision_reduction", "碰撞伤害减免", "使目标随从受到的碰撞伤害减少 {v} 点",
		T.ANY_MINION, CardEffects._fx_collision_reduction, HINT_BUFF)
	_reg("imprison", "禁锢", "禁锢目标随从：不能发动入场 / 退场，不能被召唤或响应瞬念召唤（身材仍可加减）",
		T.ANY_MINION, CardEffects._fx_imprison, HINT_UTILITY)
	_reg(TRANSFORM, "化身", "将目标随从化身成指定随从", T.ANY_MINION, CardEffects._fx_transform,
		HINT_UTILITY, true)

	# ---- 随机能力（能力池）----
	# 从「随机能力池」里随机抽若干个能力，逐个结算（池子口径：可重复 / 不可重复 / 随机次序）。
	# token = 能力池 ID；value > 0 时覆盖池子的随机个数范围。
	_reg(RANDOM_POOL, "随机能力（能力池）", "从能力池随机获得 {v} 个能力",
		T.NONE, CardEffects._fx_random_pool, HINT_UTILITY, false, false, false, false, true)

	# ---- 入场效果的手动触发 ----
	# 入场效果（随从 = 战吼，护符 / 城邦 = 安放）**只在从手牌打出时**自动结算：
	# 衍生物 / 复制 / 亡语召唤 / 城邦格判定这些「召唤入场」都不会结算它（见 GameManager.summon_unit）。
	# 这条效果是把入场效果再触发一次的唯一入口（内部走 gm.trigger_entrance_effect()，
	# 那里还带了一层回环保护，避免「入场效果里再触发入场效果」无限递归）。
	_reg("trigger_entrance", "触发一次入场效果", "使目标随从触发一次入场效果",
		T.ALLY_MINION, CardEffects._fx_trigger_entrance, HINT_UTILITY)

	# ---- 手牌费用 / 复制 / 牌库调度 ----
	# 这一组刻意拆成**最小原语**，方便在效果链里互相组合（例：复制本随从 ×2 → 手牌费用 +2）：
	#   * `hand_cost_up`        抬高某一方手牌的费用（目标选英雄 = 选哪一方）；
	#   * `copy_self`           复制来源随从到**战场**；`copy_self_to_deck` 复制到**牌库**；
	#   * `copy_unit_to_deck`   复制目标随从到牌库；`copy_hand_to_deck` 复制目标的手牌到牌库；
	#   * `summon_deck_*`       从牌库检索一张符合口径的随从召唤上场；`*_return` 版是临时登场
	#                          （拥有者**下一个自己的回合结束时回到手牌**，即瞬念召唤式登场）。
	# 复制进牌库的位置统一是**随机位置**（抽牌 pop_back，随机位置才不会影响下一张已知的牌）。
	# 第二条限定词缀「持续回合数」= 0 时是永久 / 一次性（老口径），> 0 则到期自动还原。
	# 例：「使敌方手牌费用 +2，持续到目标一方第 2 个回合结束」—— 两回合后 -2 自动失效。
	_reg("hand_cost_up", "手牌费用增加", "使目标一方的手牌费用 +{v}",
		T.ENEMY_HERO, CardEffects._fx_hand_cost_up, HINT_UTILITY, false, false, false, true)
	_reg("copy_self", "复制本随从", "在战场上复制 {v} 个本随从",
		T.NONE, CardEffects._fx_copy_self, HINT_SUMMON)
	_reg("copy_self_to_deck", "复制本随从进牌库", "把本随从的 {v} 份副本洗入牌库",
		T.NONE, CardEffects._fx_copy_self_to_deck, HINT_UTILITY)
	_reg("copy_unit_to_deck", "复制随从进牌库", "把目标随从的 {v} 份副本洗入牌库",
		T.ALLY_MINION, CardEffects._fx_copy_unit_to_deck, HINT_UTILITY)
	_reg("copy_hand_to_deck", "复制手牌进牌库", "随机把目标的 {v} 张手牌复制洗入牌库",
		T.ENEMY_HERO, CardEffects._fx_copy_hand_to_deck, HINT_UTILITY)
	# 「来源」限定词缀：这 6 条效果都允许把检索范围改成墓地 / 牌库优先→墓地，
	# 于是「瞬念召唤」这类卡（满足条件时呼唤，例如面-COPY 墓地里的那张）可以直接组成。
	_reg("summon_deck_id", "呼唤（指定卡）", "召唤指定的一张卡上场",
		T.NONE, CardEffects._fx_summon_deck_id, HINT_SUMMON, true, false, true)
	_reg("summon_deck_cost", "呼唤（费用 ≤ {v}）", "召唤一个费用 ≤ {v} 的随从上场",
		T.NONE, CardEffects._fx_summon_deck_cost, HINT_SUMMON, false, false, true)
	_reg("summon_deck_random", "随机呼唤", "随机召唤一个随从上场",
		T.NONE, CardEffects._fx_summon_deck_random, HINT_SUMMON, false, false, true)
	_reg("summon_deck_id_return", "临时呼唤（指定卡）", "召唤指定的一张卡上场，回合结束时回到手牌",
		T.NONE, CardEffects._fx_summon_deck_id_return, HINT_SUMMON, true, false, true)
	_reg("summon_deck_cost_return", "临时呼唤（费用 ≤ {v}）", "召唤一个费用 ≤ {v} 的随从上场，回合结束时回到手牌",
		T.NONE, CardEffects._fx_summon_deck_cost_return, HINT_SUMMON, false, false, true)
	_reg("summon_deck_random_return", "临时随机呼唤", "随机召唤一个随从上场，回合结束时回到手牌",
		T.NONE, CardEffects._fx_summon_deck_random_return, HINT_SUMMON, false, false, true)


# ------------------------------ 对外接口 ------------------------------

static func ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


static func has(id: String) -> bool:
	_ensure()
	return _registry.has(id)


static func display_name(id: String) -> String:
	_ensure()
	return str(_registry.get(id, {}).get("name", "未知效果"))


## 卡面文本：把 {v} 替换为数值，并把两条限定词缀（来源 / 持续回合数）拼到末尾。
## `src_kind` / `duration_turns` 直接来自效果链条目里的 "src" / "turns"，
## 卡面 / 悬停详情 / 卡表自检看到的文本与实际结算口径因此是同一套。
static func text(id: String, value: int, src_kind: int = 0, duration_turns: int = 0,
		token: String = "") -> String:
	_ensure()
	if id == "" or id == NONE or not _registry.has(id):
		return ""
	# 随机能力：文本取决于池子（名字 / 随机口径 / 能力清单），不能只靠 {v} 模板
	if id == RANDOM_POOL:
		return random_pool_text(token, value)
	if id == GRANT_SKILL or id == GRANT_ABILITY:
		return _grant_text(id, token)
	if id == TRANSFORM:
		if token.strip_edges() == "":
			return "将目标随从化身成指定随从（未选择卡牌）"
		return "将目标随从化身成「%s」" % _card_name(token.strip_edges())
	# 牌库 / 手牌改造：token 是「区域|目标」，文本按参数动态生成
	if needs_spec(id):
		return spec_text(id, token, value)
	var body := str(_registry[id]["text"]).replace("{v}", str(value))
	# 随机获得类：把来源范围写进卡面，管理员改 token 后卡面文本同步变化
	if needs_scope(id):
		body = "（来源：%s）%s" % [scope_label(token), body]
	if needs_src(id) and src_kind != 0:
		var names: Array = EffectContext.SOURCE_NAMES
		body = "（来源：%s）%s" % [
			str(names[src_kind]) if src_kind >= 0 and src_kind < names.size() else str(src_kind),
			body]
	if needs_turns(id) and duration_turns > 0:
		body += "（持续到目标一方第 %d 个回合结束）" % duration_turns
	return body


static func default_target(id: String) -> int:
	_ensure()
	return int(_registry.get(id, {}).get("target", CardData.Targeting.NONE))


static func needs_token(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("token", false))


## 这一条效果要不要显示「能力池 ID」输入框（随机能力）
static func needs_pool(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("pool", false))


## 这一条效果要不要显示「来源卡牌 ID」输入框（赋予技能 / 能力）
static func needs_card_ref(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("card_ref", false))


## 这一条效果要不要显示「来源范围」输入框（随机获得技能 / 能力 / 效果）
static func needs_scope(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("scope", false))


## 这一条效果要不要显示「区域|目标」复合参数输入框（替换卡牌 / 破坏牌库 / 向牌库加牌）
static func needs_spec(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("spec", false))


## 把复合 token 拆成「区域」「目标」两段（竖线分隔，两侧去空白；右侧允许再带冒号前缀）
static func _split_spec(token: String) -> PackedStringArray:
	var out := PackedStringArray()
	for p in token.strip_edges().split("|", true, 1):
		out.append(p.strip_edges())
	return out


## 区域 → 玩家 id（-1 = 无法识别的区域）
static func _spec_zone_pid(ctx: EffectContext, zone: String) -> int:
	match zone:
		"deck", "hand":
			return ctx.caster_pid
		"enemy_deck", "enemy_hand":
			return 1 - ctx.caster_pid
	return -1


## 区域的人话
static func _spec_zone_label(zone: String) -> String:
	match zone:
		"deck": return "本方牌库"
		"hand": return "本方手牌"
		"enemy_deck": return "敌方牌库"
		"enemy_hand": return "敌方手牌"
	return "未知区域「%s」" % zone


## 替换来源的人话（card:<id> / enemy_hand / enemy_deck）
static func _spec_replace_label(spec: String) -> String:
	if spec.begins_with("card:"):
		return "「%s」" % _card_name(spec.substr("card:".length()).strip_edges())
	if spec == "enemy_hand":
		return "对手手牌"
	if spec == "enemy_deck":
		return "对手牌堆"
	return "未知来源「%s」" % spec


## 破坏筛选中的人话（random / card / name / cost / effect）
static func _spec_filter_label(flt: String) -> String:
	if flt == "random":
		return "牌"
	if flt.begins_with("card:"):
		return "「%s」" % _card_name(flt.substr("card:".length()).strip_edges())
	if flt.begins_with("name:"):
		return "同名卡「%s」" % flt.substr("name:".length()).strip_edges()
	if flt.begins_with("cost:"):
		return "费用为 %s 的牌" % flt.substr("cost:".length()).strip_edges()
	if flt.begins_with("effect:"):
		return "带「%s」的牌" % display_name(flt.substr("effect:".length()).strip_edges())
	return "「%s」" % flt


## 加牌来源的人话（card:<id> / pack:<id>[,<id>...]）
static func _spec_add_label(src: String) -> String:
	if src.begins_with("card:"):
		return "「%s」" % _card_name(src.substr("card:".length()).strip_edges())
	if src.begins_with("pack:"):
		var ids := _spec_pack_ids(src)
		if ids.is_empty():
			return "卡包范围（未填卡包）"
		var names := PackedStringArray()
		var db = _card_db()
		for pid in ids:
			names.append(str(db.pack_name(pid)) if db != null and db.has_pack(pid) else pid)
		return "来自卡包「%s」的随机卡" % " / ".join(names)
	return "「%s」" % src


## pack:<id>[,<id>...] → 卡包 id 列表（空串忽略）
static func _spec_pack_ids(src: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not src.begins_with("pack:"):
		return out
	for raw in src.substr("pack:".length()).split(",", false):
		var pid := raw.strip_edges()
		if pid != "":
			out.append(pid)
	return out


## 复合参数的卡面文本（参数不完整时给出「未设置」而不是空串）
static func spec_text(id: String, token: String, value: int) -> String:
	var parts := _split_spec(token)
	if parts.size() < 2:
		return "未设置「区域|目标」参数"
	var zone := _spec_zone_label(parts[0])
	var arg := parts[1]
	var n := maxi(1, value)
	match id:
		REPLACE_CARDS:
			return "把%s中随机 %d 张牌替换成%s的牌" % [zone, n, _spec_replace_label(arg)]
		DESTROY_DECK_CARDS:
			if arg == "random":
				return "随机破坏%s的 %d 张牌" % [zone, n]
			if value > 0:
				return "破坏%s里至多 %d 张%s" % [zone, value, _spec_filter_label(arg)]
			return "破坏%s里所有%s" % [zone, _spec_filter_label(arg)]
		ADD_CARDS_TO_DECK:
			return "向%s洗入 %d 张%s" % [zone, n, _spec_add_label(arg)]
	return ""


## 复合参数校验（空串 = 合法）：面板保存 / 卡表自检 / 时机警告共用
static func spec_error(id: String, token: String) -> String:
	var s := token.strip_edges()
	if s == "":
		return "没有填写「区域|目标」（例如 deck|card:t001）"
	var parts := _split_spec(s)
	if parts.size() < 2:
		return "参数要写成「区域|目标」（例如 deck|card:t001）"
	var zone := parts[0]
	var arg := parts[1]
	if arg == "":
		return "「区域|目标」的右侧为空（例如 deck|card:t001）"
	match id:
		REPLACE_CARDS:
			if zone != "deck" and zone != "hand" and zone != "enemy_deck" and zone != "enemy_hand":
				return "区域「%s」无法识别（可用：deck / hand / enemy_deck / enemy_hand）" % zone
			return _replace_source_error(arg)
		DESTROY_DECK_CARDS:
			if zone != "deck" and zone != "enemy_deck":
				return "区域「%s」无法识别（可用：deck / enemy_deck）" % zone
			return _destroy_filter_error(arg)
		ADD_CARDS_TO_DECK:
			if zone != "deck" and zone != "enemy_deck":
				return "区域「%s」无法识别（可用：deck / enemy_deck）" % zone
			return _add_source_error(arg)
	return ""


static func _replace_source_error(arg: String) -> String:
	if arg == "enemy_hand" or arg == "enemy_deck":
		return ""
	if arg.begins_with("card:"):
		var cid := arg.substr("card:".length()).strip_edges()
		if cid == "":
			return "替换来源缺少卡牌 ID（写法：card:<卡牌 ID>）"
		if _card_by_id(cid) == null:
			return "替换来源卡牌「%s」不存在" % cid
		return ""
	return "替换来源「%s」无法识别（可用：card:<卡牌 ID> / enemy_hand / enemy_deck）" % arg


static func _destroy_filter_error(arg: String) -> String:
	if arg == "random":
		return ""
	if arg.begins_with("card:"):
		var cid := arg.substr("card:".length()).strip_edges()
		if cid == "":
			return "指定卡筛选缺少卡牌 ID（写法：card:<卡牌 ID>）"
		if _card_by_id(cid) == null:
			return "指定卡「%s」不存在" % cid
		return ""
	if arg.begins_with("name:"):
		if arg.substr("name:".length()).strip_edges() == "":
			return "同名筛选缺少卡名（写法：name:<卡名>）"
		return ""
	if arg.begins_with("cost:"):
		var raw := arg.substr("cost:".length()).strip_edges()
		if not raw.is_valid_int():
			return "费用筛选需要一个整数（写法：cost:<费用>）"
		if int(raw) < 0 or int(raw) > SPEC_COST_LIMIT:
			return "费用筛选超出范围（0–%d）" % SPEC_COST_LIMIT
		return ""
	if arg.begins_with("effect:"):
		var eid := arg.substr("effect:".length()).strip_edges()
		if eid == "":
			return "效果筛选缺少效果 ID（写法：effect:<效果 ID>）"
		if not has(eid):
			return "筛选用的效果「%s」不存在" % eid
		return ""
	return "筛选「%s」无法识别（可用：random / card:<卡牌 ID> / name:<卡名> / cost:<费用> / effect:<效果 ID>）" % arg


static func _add_source_error(arg: String) -> String:
	if arg.begins_with("card:"):
		var cid := arg.substr("card:".length()).strip_edges()
		if cid == "":
			return "指定卡缺少卡牌 ID（写法：card:<卡牌 ID>）"
		if _card_by_id(cid) == null:
			return "要加入的卡牌「%s」不存在" % cid
		return ""
	if arg.begins_with("pack:"):
		var ids := _spec_pack_ids(arg)
		if ids.is_empty():
			return "卡包范围没有填卡包 ID（写法：pack:<卡包 ID>[,<卡包 ID>]）"
		var db = _card_db()
		if db != null:
			for pid in ids:
				if not db.has_pack(pid):
					return "卡包「%s」不存在（先到「卡包」面板创建它）" % pid
		return ""
	return "来源「%s」无法识别（可用：card:<卡牌 ID> / pack:<卡包 ID>[,<卡包 ID>]）" % arg


## 可用的来源范围 id（不含需要具体 ID 的 pack:<id> / troop:<id>）
static func scope_ids() -> Array[String]:
	var out: Array[String] = []
	for k in SCOPE_LABELS:
		out.append(str(k))
	return out


## 来源范围的人话（卡面文本 / 日志 / 面板提示共用）
static func scope_label(scope: String) -> String:
	var s := scope.strip_edges()
	if s == "":
		return "未设置来源范围"
	if SCOPE_LABELS.has(s):
		return str(SCOPE_LABELS[s])
	var db = _card_db()
	if s.begins_with("pack:"):
		var pid := s.substr("pack:".length()).strip_edges()
		if pid == "":
			return "未填写卡包 ID"
		if db != null and db.has_pack(pid):
			return "卡包「%s」" % str(db.pack_name(pid))
		return "卡包「%s」" % pid
	if s.begins_with("troop:"):
		var tid := s.substr("troop:".length()).strip_edges()
		if tid == "":
			return "未填写兵种 ID"
		if tid == CardData.NEUTRAL_TROOP:
			return "兵种「%s」" % CardData.NEUTRAL_TROOP_NAME
		if db != null and db.has_troop(tid):
			return "兵种「%s」" % str(db.troop_name(tid))
		return "兵种「%s」" % tid
	return "未知来源范围「%s」" % s


## 校验来源范围（空串 = 合法）。面板保存 / 卡表自检 / 时机警告共用同一套口径。
static func scope_error(scope: String) -> String:
	var s := scope.strip_edges()
	if s == "":
		return "没有填写来源范围（可用：%s；或 pack:<卡包 ID> / troop:<兵种 ID>）" % " / ".join(scope_ids())
	if SCOPE_LABELS.has(s):
		return ""
	if s.begins_with("pack:"):
		var pid := s.substr("pack:".length()).strip_edges()
		if pid == "":
			return "卡包范围缺少卡包 ID（写法：pack:<卡包 ID>）"
		var db = _card_db()
		if db != null and not db.has_pack(pid):
			return "用到的卡包「%s」不存在（先到「卡包」面板创建它）" % pid
		return ""
	if s.begins_with("troop:"):
		var tid := s.substr("troop:".length()).strip_edges()
		if tid == "":
			return "兵种范围缺少兵种 ID（写法：troop:<兵种 ID>）"
		if tid == CardData.NEUTRAL_TROOP:
			return ""
		var tdb = _card_db()
		if tdb != null and not tdb.has_troop(tid):
			return "用到的兵种「%s」未登记（先到「兵种」面板创建它）" % tid
		return ""
	return "来源范围「%s」无法识别（可用：%s；或 pack:<卡包 ID> / troop:<兵种 ID>）" % [
		s, " / ".join(scope_ids())]


## 某条效果在某个时机下有没有**逻辑问题**（管理员面板据此把这一行标红，空串 = 没问题）。
##
## context：CardTriggers 的事件 id（play / summon / leave / invoke / vanish / fusion /
##          turn_start / turn_end），另有 deathrattle（谢幕 / 亡语）、play_spell（法术打出）。
## 只报「配了也一定无效」的情况；需要目标但当时可能没目标的只算运行时提示，不标红。
static func context_warning(id: String, context: String, token: String = "") -> String:
	if id == "" or id == NONE:
		return ""
	# 随机能力：池子缺失 / 配置错误 / 池中某条能力在这个时机下失效
	if id == RANDOM_POOL:
		var pid := token.strip_edges()
		if pid == "":
			return "没有选择随机能力池"
		if not AbilityPools.has(pid):
			return "随机能力池「%s」不存在" % pid
		var pool := AbilityPools.by_id(pid)
		var errs := AbilityPools.errors(pool)
		if not errs.is_empty():
			return "随机能力池配置错误：" + errs[0]
		for e in pool.get("abilities", []):
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var sub := context_warning(str(e.get("id", "")), context, str(e.get("token", "")))
			if sub != "":
				return "池中能力「%s」：%s" % [display_name(str(e.get("id", ""))), sub]
		return ""
	if id == TRANSFORM:
		return "没有选择要变成的卡牌" if token.strip_edges() == "" else ""
	# 随机获得类：来源范围必须能落地（空 / 无法识别 / 卡包兵种不存在）
	if needs_scope(id):
		return scope_error(token)
	# 牌库 / 手牌改造：区域|目标 必须能落地
	if needs_spec(id):
		return spec_error(id, token)
	# 赋予技能 / 能力：来源卡牌必须存在，而且确实带对应的内容
	if needs_card_ref(id):
		var src := _card_by_id(token)
		if token.strip_edges() == "":
			return "没有选择来源卡牌"
		if src == null:
			return "来源卡牌「%s」不存在" % token.strip_edges()
		if id == GRANT_SKILL and not src.has_skill():
			return "来源卡牌「%s」没有主动技能" % src.card_name
		if id == GRANT_ABILITY and not src.has_triggers():
			return "来源卡牌「%s」没有触发能力" % src.card_name
		return ""
	# 「复制本随从」类效果必须有**场上的来源随从**：离场 / 消失 / 谢幕 / 融合（在手牌）
	# 以及法术打出（没有场上来源）时，来源已经不在 / 根本不存在，配了也不会有效果。
	var no_source := context == "leave" or context == "vanish" or context == "deathrattle" \
		or context == "fusion" or context == "play_spell"
	if no_source and (id == "copy_self" or id == "copy_self_to_deck"):
		return "「%s」需要场上的本随从作为来源；在「%s」时来源不在场上，这一条不会生效" % [
			display_name(id), context_name(context)]
	if needs_token(id) and token.strip_edges() == "":
		return "「%s」缺少衍生物 ID" % display_name(id)
	return ""


## 时机的人话（警告文本用）
static func context_name(context: String) -> String:
	match context:
		"play": return "入场（打出）"
		"summon": return "被召唤入场"
		"leave": return "离场"
		"invoke": return "瞬念召唤"
		"vanish": return "消失"
		"fusion": return "融合"
		"turn_start": return "回合开始"
		"turn_end": return "回合结束"
		"deathrattle": return "谢幕（死亡）"
		"play_spell": return "法术打出"
	return context


## 这一条效果要不要显示「来源限定」（牌库 / 墓地 / 牌库优先）
static func needs_src(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("need_src", false))


## 这一条效果要不要显示「持续回合数」（0 = 永久）
static func needs_turns(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("need_turns", false))


static func ai_hint(id: String) -> String:
	_ensure()
	return str(_registry.get(id, {}).get("hint", ""))


## 效果自身是否为群体效果（内部会遍历所有目标，结算时只应调用一次）
static func is_aoe(id: String) -> bool:
	_ensure()
	return bool(_registry.get(id, {}).get("aoe", false))


## 执行一次效果
static func apply(id: String, ctx: EffectContext) -> void:
	_ensure()
	if id == "" or id == NONE:
		return
	if not _registry.has(id):
		ctx.log_text("未知效果：%s" % id)
		return
	_registry[id]["fn"].call(ctx)


# ------------------------------ 效果实现 ------------------------------

static func _fx_none(_ctx: EffectContext) -> void:
	pass


static func _fx_damage(ctx: EffectContext) -> void:
	ctx.damage_target(ctx.value)


static func _fx_damage_hero(ctx: EffectContext) -> void:
	ctx.damage_hero(1 - ctx.caster_pid, ctx.value)


static func _fx_aoe_enemy(ctx: EffectContext) -> void:
	for u in ctx.enemy_minions():
		ctx.damage_unit(u, ctx.value)


static func _fx_aoe_all(ctx: EffectContext) -> void:
	for u in ctx.all_minions():
		ctx.damage_unit(u, ctx.value)


static func _fx_destroy(ctx: EffectContext) -> void:
	ctx.kill_unit(ctx.unit())


static func _fx_destroy_random(ctx: EffectContext) -> void:
	ctx.kill_unit(ctx.random_enemy_minion())


static func _fx_heal(ctx: EffectContext) -> void:
	ctx.heal_target(ctx.value)


static func _fx_heal_all_ally(ctx: EffectContext) -> void:
	for u in ctx.ally_minions():
		ctx.heal_unit(u, ctx.value)


static func _fx_armor(ctx: EffectContext) -> void:
	ctx.add_armor(ctx.caster_pid, ctx.value)


static func _fx_draw(ctx: EffectContext) -> void:
	ctx.draw(ctx.caster_pid, ctx.value)


static func _fx_enemy_draw(ctx: EffectContext) -> void:
	ctx.draw(1 - ctx.caster_pid, ctx.value)


static func _fx_mana(ctx: EffectContext) -> void:
	ctx.add_mana(ctx.caster_pid, ctx.value)


static func _fx_mana_crystal(ctx: EffectContext) -> void:
	ctx.add_mana_crystal(ctx.caster_pid, maxi(1, ctx.value))


static func _fx_discard_enemy(ctx: EffectContext) -> void:
	var foe := ctx.foe()
	if foe == null:
		return
	for _i in maxi(1, ctx.value):
		if foe.hand.is_empty():
			return
		var idx: int = randi() % foe.hand.size()
		var dropped: CardData = foe.hand[idx]
		foe.hand.remove_at(idx)
		foe.note_grave_entered(dropped)
		ctx.log_text("%s 弃掉了「%s」" % [foe.display_name, dropped.card_name])


static func _fx_summon(ctx: EffectContext) -> void:
	ctx.summon(ctx.caster_pid, ctx.token_id, maxi(1, ctx.value))


static func _fx_copy_ally(ctx: EffectContext) -> void:
	ctx.summon_copy(ctx.caster_pid, ctx.unit())


static func _fx_buff(ctx: EffectContext) -> void:
	ctx.buff_unit(ctx.unit(), ctx.value, ctx.value)


static func _fx_buff_attack(ctx: EffectContext) -> void:
	ctx.buff_unit(ctx.unit(), ctx.value, 0)


static func _fx_buff_health(ctx: EffectContext) -> void:
	ctx.buff_unit(ctx.unit(), 0, ctx.value)


static func _fx_buff_all_ally(ctx: EffectContext) -> void:
	for u in ctx.ally_minions():
		ctx.buff_unit(u, ctx.value, ctx.value)


static func _fx_debuff(ctx: EffectContext) -> void:
	ctx.buff_unit(ctx.unit(), -ctx.value, -ctx.value)


static func _fx_grant_taunt(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.TAUNT)


static func _fx_grant_shield(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		return
	u.divine_shield = true
	ctx.log_text("「%s」获得圣盾" % u.data.card_name)


static func _fx_grant_charge(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		return
	ctx.grant_keyword(u, CardData.Keyword.CHARGE)
	u.attacks_used = 0


static func _fx_grant_windfury(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.WINDFURY)


static func _fx_grant_lifesteal(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.LIFESTEAL)


static func _fx_grant_poisonous(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.POISONOUS)


static func _fx_grant_stealth(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.STEALTH)


# ------------------------------ 赋予技能 / 能力 ------------------------------
#
# 与「赋予关键字」不同，这里复制的是**另一张卡**的卡面数据：
#   * grant_skill   → 复制那张卡的主动技能（CardData.skill），覆盖目标当前的技能；
#   * grant_ability → 追加那张卡的触发能力（CardData.triggers），可叠加多条。
# 被赋予的技能 / 能力在目标离场（进墓地 / 回手 / 消失）时由 BoardUnit.strip_granted() 摘掉，
# 不会跟着卡进墓地或手牌；沉默同样会摘掉。

static func _fx_grant_skill(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		return
	var src := _card_by_id(ctx.token_id)
	if src == null or not src.has_skill():
		ctx.log_text("赋予技能：来源卡牌「%s」不存在或没有主动技能" % ctx.token_id.strip_edges())
		return
	u.note_granted()
	u.data.skill = src.skill.duplicate(true)
	# 新技能本回合可以立刻发动（不继承旧技能的「本回合已用」状态）
	u.skill_used_turn = -1
	ctx.log_text("「%s」获得技能「%s」（来自「%s」）" % [
		u.data.card_name, src.skill_name(), src.card_name])


static func _fx_grant_ability(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		return
	var src := _card_by_id(ctx.token_id)
	if src == null or not src.has_triggers():
		ctx.log_text("赋予能力：来源卡牌「%s」不存在或没有触发能力" % ctx.token_id.strip_edges())
		return
	u.note_granted()
	var added := 0
	for tr in src.triggers:
		var spec := CardTriggers.normalized(tr)
		if spec.is_empty():
			continue
		var key := JSON.stringify(spec)
		var exists := false
		for old in u.data.triggers:
			if JSON.stringify(old) == key:
				exists = true
				break
		if not exists:
			u.data.triggers.append(spec)
			added += 1
	ctx.log_text("「%s」获得「%s」的 %d 条能力" % [
		u.data.card_name, src.card_name, added])


# ------------------------------ 随机获得技能 / 能力 / 效果 ------------------------------
#
# 三个效果共用一套「来源范围 → 候选卡牌」的枚举（_scope_sources）与洗牌抽样
# （_pick_scope_sources）。场上随从取**当前**卡面（含先前被赋予的技能 / 能力），
# 手牌 / 牌库 / 卡包 / 兵种取卡牌本体；候选按卡牌 ID 去重，抽到几张就用几张。
#   * 技能：随从只有一个技能栏 → 固定抽 1 个（value 不生效），覆盖当前技能；
#   * 能力：抽 value 个来源，把它们身上的触发能力全部追加到目标（按条去重）；
#   * 效果：抽 value 个来源，把它们的战吼 / 法术效果链**当场逐条结算**
#           （走 GameManager.resolve_random_ability，目标 / 条件 / 收尾与普通链一致）。

static func _fx_gain_random_skill(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		ctx.log_text("随机获得技能：没有目标随从")
		return
	# 不抽目标身上已有的同一个技能（否则等于什么都没发生）
	var current := JSON.stringify(u.data.skill)
	var want := func(c: CardData) -> bool:
		return c.has_skill() and JSON.stringify(c.skill) != current
	var picks := _pick_scope_sources(ctx, ctx.token_id, 1, want)
	if picks.is_empty():
		ctx.log_text("随机获得技能：%s里没有可获得的主动技能" % scope_label(ctx.token_id))
		return
	var src: CardData = picks[0]
	u.note_granted()
	u.data.skill = src.skill.duplicate(true)
	# 新技能本回合可以立刻发动（与「赋予技能」同一口径）
	u.skill_used_turn = -1
	ctx.log_text("「%s」从%s随机获得技能「%s」（来自「%s」）" % [
		u.data.card_name, scope_label(ctx.token_id), src.skill_name(), src.card_name])


static func _fx_gain_random_ability(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		ctx.log_text("随机获得能力：没有目标随从")
		return
	var want := func(c: CardData) -> bool:
		return c.has_triggers()
	var picks := _pick_scope_sources(ctx, ctx.token_id, maxi(1, ctx.value), want)
	if picks.is_empty():
		ctx.log_text("随机获得能力：%s里没有带触发能力的卡牌" % scope_label(ctx.token_id))
		return
	u.note_granted()
	var added := 0
	var from := PackedStringArray()
	for src in picks:
		var got := 0
		for tr in src.triggers:
			var spec := CardTriggers.normalized(tr)
			if spec.is_empty():
				continue
			var key := JSON.stringify(spec)
			var exists := false
			for old in u.data.triggers:
				if JSON.stringify(old) == key:
					exists = true
					break
			if not exists:
				u.data.triggers.append(spec)
				got += 1
		added += got
		if got > 0:
			from.append(src.card_name)
	ctx.log_text("「%s」从%s随机获得 %d 条能力（来源：%s）" % [
		u.data.card_name, scope_label(ctx.token_id), added,
		"、".join(from) if not from.is_empty() else "无新增"])


static func _fx_gain_random_effect(ctx: EffectContext) -> void:
	var want := func(c: CardData) -> bool:
		return not c.effect_chain().is_empty()
	var picks := _pick_scope_sources(ctx, ctx.token_id, maxi(1, ctx.value), want)
	if picks.is_empty():
		ctx.log_text("随机获得效果：%s里没有带效果的卡牌" % scope_label(ctx.token_id))
		return
	var names := PackedStringArray()
	for src in picks:
		names.append(src.card_name)
	ctx.log_text("随机获得效果：从%s抽到「%s」" % [
		scope_label(ctx.token_id), "」「".join(names)])
	for src in picks:
		var chain := src.effect_chain()
		ctx.log_text("  结算「%s」：%s" % [src.card_name, src.chain_text(chain)])
		for e in chain:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			# 单条效果交给随机能力管线：目标自动选择 / 条件 / 死亡收尾都复用既有实现
			ctx.gm.resolve_random_ability(ctx.caster_pid, src, e, ctx.source_unit,
				ctx.is_deathrattle)


## 来源范围 → 候选卡牌（按卡牌 ID 去重；卡牌没有 ID 时按实例区分）
static func _scope_sources(ctx: EffectContext, scope: String) -> Array[CardData]:
	var out: Array[CardData] = []
	var seen := {}
	var s := scope.strip_edges()
	var caster := ctx.caster()
	var foe := ctx.foe()
	var whole := s == "all"
	if s == "board" or s == "any_board" or whole:
		for u in ctx.ally_minions():
			if u != null:
				_add_scope_card(out, seen, u.data)
	if s == "enemy_board" or s == "any_board" or whole:
		for u in ctx.enemy_minions():
			if u != null:
				_add_scope_card(out, seen, u.data)
	if s == "hand" or s == "any_hand" or whole:
		if caster != null:
			for c in caster.hand:
				_add_scope_card(out, seen, c)
	if s == "enemy_hand" or s == "any_hand" or whole:
		if foe != null:
			for c in foe.hand:
				_add_scope_card(out, seen, c)
	if s == "deck" or s == "any_deck" or whole:
		if caster != null:
			for c in caster.deck:
				_add_scope_card(out, seen, c)
	if s == "enemy_deck" or s == "any_deck" or whole:
		if foe != null:
			for c in foe.deck:
				_add_scope_card(out, seen, c)
	var db = _card_db()
	if db == null:
		return out
	if s.begins_with("pack:"):
		var pid := s.substr("pack:".length()).strip_edges()
		for c in db.cards:
			if db.pack_of(c) == pid:
				_add_scope_card(out, seen, c)
	if s.begins_with("troop:"):
		var tid := s.substr("troop:".length()).strip_edges()
		for c in db.cards:
			if db.troop_of(c) == tid:
				_add_scope_card(out, seen, c)
	return out


static func _add_scope_card(out: Array[CardData], seen: Dictionary, card: CardData) -> void:
	if card == null:
		return
	var key := card.id.strip_edges()
	if key == "":
		key = "#%d" % card.get_instance_id()
	if seen.has(key):
		return
	seen[key] = true
	out.append(card)


## 从范围里按 want 过滤后洗牌，取前 count 个（候选不足时有多少给多少）
static func _pick_scope_sources(ctx: EffectContext, scope: String, count: int,
		want: Callable) -> Array[CardData]:
	var pool: Array[CardData] = []
	for c in _scope_sources(ctx, scope):
		if not want.is_valid() or bool(want.call(c)):
			pool.append(c)
	for i in range(pool.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp := pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	if count > 0 and pool.size() > count:
		pool.resize(count)
	return pool


# ------------------------------ 牌库 / 手牌改造 ------------------------------
#
# token 统一是「区域|目标」复合写法（见 REPLACE_CARDS 顶部注释），value = 张数。
# 被替换 / 被破坏的牌都进拥有者的墓地（note_grave_entered），会照常影响墓地计数类条件；
# 新加入 / 替换出来的牌一律是**克隆**（来源区域的牌本身不动，避免同一个对象同时存在于两处）。

static func _fx_replace_cards(ctx: EffectContext) -> void:
	var parts := _split_spec(ctx.token_id)
	if parts.size() < 2:
		ctx.log_text("替换卡牌：token 要写成「区域|目标」（例如 hand|enemy_hand）")
		return
	var zone := parts[0]
	var src_spec := parts[1]
	var pid := _spec_zone_pid(ctx, zone)
	if pid < 0:
		ctx.log_text("替换卡牌：区域「%s」无法识别（可用：deck / hand / enemy_deck / enemy_hand）" % zone)
		return
	var p: PlayerState = ctx.gm.get_player(pid)
	if p == null:
		return
	var pool := _replace_pool(ctx, src_spec)
	if pool.is_empty():
		ctx.log_text("替换卡牌：%s里没有可用的牌" % _spec_replace_label(src_spec))
		return
	var is_deck := zone.ends_with("deck")
	var list: Array = p.deck if is_deck else p.hand
	if list.is_empty():
		ctx.log_text("替换卡牌：%s里没有牌可替换" % _spec_zone_label(zone))
		return
	var n := mini(maxi(1, ctx.value), list.size())
	var idxs := _pick_indices(list.size(), n)
	idxs.sort()
	idxs.reverse()
	var old_names := PackedStringArray()
	for idx in idxs:
		var old: CardData = list[idx]
		list.remove_at(idx)
		p.note_grave_entered(old)
		old_names.append(old.card_name)
	for _i in n:
		var pick: CardData = pool[randi() % pool.size()]
		if is_deck:
			p.deck.insert(randi() % (p.deck.size() + 1), pick.clone())
		elif p.hand.size() < ctx.gm.HAND_LIMIT:
			p.hand.append(pick.clone())
		else:
			ctx.log_text("  %s 手牌已满，新牌「%s」被销毁" % [p.display_name, pick.card_name])
	ctx.log_text("%s 的%s有 %d 张牌被替换成%s的牌（原牌：%s）" % [
		p.display_name, _spec_zone_label(zone), n, _spec_replace_label(src_spec),
		"、".join(old_names)])


static func _fx_destroy_deck_cards(ctx: EffectContext) -> void:
	var parts := _split_spec(ctx.token_id)
	if parts.size() < 2:
		ctx.log_text("破坏牌库：token 要写成「牌库|筛选」（例如 deck|random）")
		return
	var zone := parts[0]
	var flt := parts[1]
	if zone != "deck" and zone != "enemy_deck":
		ctx.log_text("破坏牌库：区域「%s」无法识别（可用：deck / enemy_deck）" % zone)
		return
	var p: PlayerState = ctx.gm.get_player(_spec_zone_pid(ctx, zone))
	if p == null or p.deck.is_empty():
		ctx.log_text("破坏牌库：%s里没有牌" % _spec_zone_label(zone))
		return
	var idxs: Array[int] = []
	if flt == "random":
		idxs = _pick_indices(p.deck.size(), maxi(1, ctx.value))
	else:
		for i in p.deck.size():
			if _deck_card_matches(p.deck[i], flt):
				idxs.append(i)
		# 非随机筛选用 value 当张数上限（0 = 所有匹配的卡）
		if ctx.value > 0 and idxs.size() > ctx.value:
			for i in range(idxs.size() - 1, 0, -1):
				var j: int = randi() % (i + 1)
				var tmp := idxs[i]
				idxs[i] = idxs[j]
				idxs[j] = tmp
			idxs.resize(ctx.value)
	if idxs.is_empty():
		ctx.log_text("破坏牌库：%s里没有符合条件的牌" % _spec_zone_label(zone))
		return
	idxs.sort()
	idxs.reverse()
	var names := PackedStringArray()
	for i in idxs:
		var c: CardData = p.deck[i]
		p.deck.remove_at(i)
		p.note_grave_entered(c)
		names.append(c.card_name)
	ctx.log_text("%s 的%s里有 %d 张牌被破坏：%s" % [
		p.display_name, _spec_zone_label(zone), idxs.size(), "、".join(names)])


static func _fx_add_cards_to_deck(ctx: EffectContext) -> void:
	var parts := _split_spec(ctx.token_id)
	if parts.size() < 2:
		ctx.log_text("向牌库加牌：token 要写成「牌库|来源」（例如 deck|card:t001）")
		return
	var zone := parts[0]
	var src := parts[1]
	if zone != "deck" and zone != "enemy_deck":
		ctx.log_text("向牌库加牌：区域「%s」无法识别（可用：deck / enemy_deck）" % zone)
		return
	var p: PlayerState = ctx.gm.get_player(_spec_zone_pid(ctx, zone))
	if p == null:
		return
	var pool := _add_pool(src)
	if pool.is_empty():
		ctx.log_text("向牌库加牌：%s里没有可加入的牌" % _spec_add_label(src))
		return
	var n := maxi(1, ctx.value)
	for _i in n:
		var pick: CardData = pool[randi() % pool.size()]
		p.deck.insert(randi() % (p.deck.size() + 1), pick.clone())
	ctx.log_text("%s 的%s洗入了 %d 张%s" % [
		p.display_name, _spec_zone_label(zone), n, _spec_add_label(src)])


## 替换来源的候选牌（指定卡 / 对手手牌 / 对手牌堆；来源本身不会被消耗）
static func _replace_pool(ctx: EffectContext, spec: String) -> Array[CardData]:
	var pool: Array[CardData] = []
	if spec.begins_with("card:"):
		var c := _card_by_id(spec.substr("card:".length()))
		if c != null:
			pool.append(c)
	elif spec == "enemy_hand":
		var foe_hand := ctx.foe()
		if foe_hand != null:
			pool.append_array(foe_hand.hand)
	elif spec == "enemy_deck":
		var foe_deck := ctx.foe()
		if foe_deck != null:
			pool.append_array(foe_deck.deck)
	return pool


## 加牌来源的候选牌（指定卡 / 卡包范围内的所有非衍生物卡）
static func _add_pool(src: String) -> Array[CardData]:
	var pool: Array[CardData] = []
	if src.begins_with("card:"):
		var c := _card_by_id(src.substr("card:".length()))
		if c != null:
			pool.append(c)
		return pool
	if src.begins_with("pack:"):
		var ids := _spec_pack_ids(src)
		var db = _card_db()
		if db == null:
			return pool
		for c in db.cards:
			if c.is_token:
				continue
			if ids.has(db.pack_of(c)):
				pool.append(c)
	return pool


## 从 0..size-1 里随机取 count 个不重复的下标（候选不足时取满）
static func _pick_indices(size: int, count: int) -> Array[int]:
	var out: Array[int] = []
	if size <= 0 or count <= 0:
		return out
	var all: Array[int] = []
	for i in size:
		all.append(i)
	for i in range(all.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp := all[i]
		all[i] = all[j]
		all[j] = tmp
	for i in mini(count, all.size()):
		out.append(all[i])
	return out


## 这条筛选是否命中一张牌（random 不在这里判断，由调用方单独处理）
static func _deck_card_matches(c: CardData, flt: String) -> bool:
	if c == null:
		return false
	if flt.begins_with("card:"):
		return c.id == flt.substr("card:".length()).strip_edges()
	if flt.begins_with("name:"):
		return c.card_name == flt.substr("name:".length()).strip_edges()
	if flt.begins_with("cost:"):
		var raw := flt.substr("cost:".length()).strip_edges()
		return raw.is_valid_int() and c.cost == int(raw)
	if flt.begins_with("effect:"):
		return _card_has_effect(c, flt.substr("effect:".length()).strip_edges())
	return false


## 这张卡的任意效果链（战吼 / 亡语 / 技能 / 触发 / 融合）里有没有某条效果 ID
static func _card_has_effect(c: CardData, eid: String) -> bool:
	if c == null or eid == "":
		return false
	for chain in [c.effect_chain(), c.deathrattle_chain(), c.skill_chain(),
			c.fusion_effects(), c.fusion_gain()]:
		for e in chain:
			if typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == eid:
				return true
	for tr in c.triggers:
		var spec := CardTriggers.normalized(tr)
		for e in spec.get("effects", []):
			if typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == eid:
				return true
	return false


static func _fx_freeze(ctx: EffectContext) -> void:
	ctx.freeze_unit(ctx.unit())


static func _fx_silence(ctx: EffectContext) -> void:
	ctx.silence_unit(ctx.unit())


static func _fx_return_hand(ctx: EffectContext) -> void:
	ctx.return_to_hand(ctx.unit())


## 发现（三选一）：这里只挂起候选，真正的选择由界面弹出、再调 gm.resolve_discover()
static func _fx_discover(ctx: EffectContext) -> void:
	ctx.gm.begin_discover(ctx.caster_pid, ctx.gm.random_discover_options(3))


static func _fx_trigger_entrance(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		ctx.log_text("场上没有可以触发入场效果的随从")
		return
	ctx.trigger_entrance(u)


# ------------------------------ 手牌费用 / 复制 / 牌库调度 ------------------------------
#
# 这些实现一律只做「把 ctx 的信息翻译成一次 Engine 调用」，真正的破坏面与安全上限
# （手牌上限、战场 7 格、牌库为空、卡 ID 不存在）都在 GameManager / EffectContext 里兜住。

static func _fx_hand_cost_up(ctx: EffectContext) -> void:
	ctx.raise_hand_cost(ctx.target_pid(), ctx.value, ctx.turns)


static func _fx_copy_self(ctx: EffectContext) -> void:
	ctx.summon_copies(ctx.caster_pid, ctx.self_unit(), maxi(1, ctx.value))


static func _fx_copy_self_to_deck(ctx: EffectContext) -> void:
	ctx.copy_unit_to_deck(ctx.caster_pid, ctx.self_unit(), maxi(1, ctx.value))


static func _fx_copy_unit_to_deck(ctx: EffectContext) -> void:
	ctx.copy_unit_to_deck(ctx.caster_pid, ctx.unit(), maxi(1, ctx.value))


static func _fx_copy_hand_to_deck(ctx: EffectContext) -> void:
	ctx.copy_hand_to_deck(ctx.target_pid(), maxi(1, ctx.value))


static func _fx_summon_deck_id(ctx: EffectContext) -> void:
	ctx.summon_from_source(EffectContext.DECK_FILTER_ID, 0, ctx.token_id, ctx.src, false)


static func _fx_summon_deck_cost(ctx: EffectContext) -> void:
	ctx.summon_from_source(EffectContext.DECK_FILTER_COST, maxi(0, ctx.value), "", ctx.src, false)


static func _fx_summon_deck_random(ctx: EffectContext) -> void:
	ctx.summon_from_source(EffectContext.DECK_FILTER_RANDOM, 0, "", ctx.src, false)


static func _fx_summon_deck_id_return(ctx: EffectContext) -> void:
	ctx.summon_from_source(EffectContext.DECK_FILTER_ID, 0, ctx.token_id, ctx.src, true)


static func _fx_summon_deck_cost_return(ctx: EffectContext) -> void:
	ctx.summon_from_source(EffectContext.DECK_FILTER_COST, maxi(0, ctx.value), "", ctx.src, true)


static func _fx_summon_deck_random_return(ctx: EffectContext) -> void:
	ctx.summon_from_source(EffectContext.DECK_FILTER_RANDOM, 0, "", ctx.src, true)


# ------------------------------ 随机能力（能力池） ------------------------------
#
# 结算口径：按 AbilityPools 的随机规则抽一批「能力」（每条能力就是一个普通效果条目），
# 然后按抽到的顺序逐条走 GameManager.resolve_random_ability() —— 它内部复用 _resolve_chain，
# 于是目标自动选择、条件、亡语来源、吸血 / 剧毒、死亡收尾都与普通效果链完全一致。

static func _fx_random_pool(ctx: EffectContext) -> void:
	var pool_id := ctx.token_id.strip_edges()
	if pool_id == "":
		ctx.log_text("随机能力：没有填写能力池 ID（见「随机能力池」面板）")
		return
	if not AbilityPools.has(pool_id):
		ctx.log_text("随机能力：能力池「%s」不存在（见「随机能力池」面板）" % pool_id)
		return
	var picks := AbilityPools.pick(pool_id, maxi(0, ctx.value))
	if picks.is_empty():
		ctx.log_text("随机能力「%s」：池子里没有可结算的能力" % AbilityPools.pool_name(pool_id))
		return
	var pool := AbilityPools.by_id(pool_id)
	ctx.log_text("随机能力「%s」（%s）：抽到 %d 个能力 →" % [
		str(pool.get("name", pool_id)), AbilityPools.mode_label(str(pool.get("mode", ""))), picks.size()])
	for i in picks.size():
		var ability: Dictionary = picks[i]
		ctx.log_text("  %d) %s" % [i + 1, ability_text(ability)])
		ctx.gm.resolve_random_ability(ctx.caster_pid, ctx.card, ability,
			ctx.source_unit, ctx.is_deathrattle)


# ------------------------------ 战斗限制 / 减免 / 状态 ------------------------------

static func _fx_grant_indestructible(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.INDESTRUCTIBLE)


static func _fx_grant_ability_immune(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.ABILITY_DAMAGE_IMMUNE)


static func _fx_grant_collision_immune(ctx: EffectContext) -> void:
	ctx.grant_keyword(ctx.unit(), CardData.Keyword.COLLISION_DAMAGE_IMMUNE)


static func _fx_ability_reduction(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		return
	var n := maxi(0, ctx.value)
	u.ability_damage_reduction += n
	ctx.log_text("「%s」能力伤害减免 +%d（当前 %d）" % [
		u.data.card_name, n, u.ability_damage_reduction])


static func _fx_collision_reduction(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null:
		return
	var n := maxi(0, ctx.value)
	u.collision_damage_reduction += n
	ctx.log_text("「%s」碰撞伤害减免 +%d（当前 %d）" % [
		u.data.card_name, n, u.collision_damage_reduction])


## 禁锢：给目标随从挂上「被禁锢」状态。之后它的入场 / 退场能力都不发动，
## 也不能被召唤 / 响应瞬念召唤；身材（攻击力 / 生命）仍然能被效果加减。
static func _fx_imprison(ctx: EffectContext) -> void:
	var u := ctx.unit()
	if u == null or u.data == null:
		return
	u.data.imprisoned = true
	ctx.log_text("「%s」被禁锢（入场 / 退场能力不发动，且无法被召唤 / 响应瞬念召唤）" % u.data.card_name)


## 化身：把目标随从替换成 token 指定的随从（不触发离场 / 入场能力，不计入破坏 / 离场）
static func _fx_transform(ctx: EffectContext) -> void:
	var card_id := ctx.token_id.strip_edges()
	if card_id == "":
		ctx.log_text("化身：没有填写要变成的卡牌 ID")
		return
	ctx.gm.transform_unit(ctx.unit(), card_id)


## 卡名查询（化身文本用）：避免 CardEffects 静态引用自动加载，运行时从场景树里取 CardDB
static func _card_name(card_id: String) -> String:
	var c := _card_by_id(card_id)
	if c != null and str(c.card_name) != "":
		return str(c.card_name)
	return card_id if card_id != "" else "指定随从"


## 通过场景树取 CardDB（CardEffects 不静态引用自动加载，避免启动顺序问题）
static func _card_db():
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("CardDB")
	return null


## 通过场景树里的 CardDB 取卡牌
static func _card_by_id(card_id: String) -> CardData:
	var cid := card_id.strip_edges()
	if cid == "":
		return null
	var db = _card_db()
	if db == null:
		return null
	var c = db.get_card(cid)
	if c != null:
		return c
	return null


## 「赋予技能 / 能力」的卡面文本
static func _grant_text(id: String, token: String) -> String:
	var src := _card_by_id(token)
	if token.strip_edges() == "":
		return "使目标随从获得指定卡牌的%s（未选择卡牌）" % (
			"主动技能" if id == GRANT_SKILL else "触发能力")
	if src == null:
		return "使目标随从获得指定卡牌的%s（卡牌「%s」不存在）" % [
			"主动技能" if id == GRANT_SKILL else "触发能力", token.strip_edges()]
	if id == GRANT_SKILL:
		if not src.has_skill():
			return "使目标随从获得「%s」的主动技能（它没有技能）" % src.card_name
		return "使目标随从获得「%s」的主动技能「%s」" % [src.card_name, src.skill_name()]
	if not src.has_triggers():
		return "使目标随从获得「%s」的触发能力（它没有触发效果）" % src.card_name
	return "使目标随从获得「%s」的触发能力" % src.card_name


## 一条「能力」的卡面文本（普通效果 + 条件前缀）；随机能力不允许嵌套，这里直接给出提示
static func ability_text(entry: Dictionary) -> String:
	var eid := str(entry.get("id", ""))
	if eid == "" or eid == NONE:
		return ""
	if eid == RANDOM_POOL:
		return "随机能力（不支持嵌套）"
	var body := text(eid, int(entry.get("value", 0)), int(entry.get("src", 0)),
		int(entry.get("turns", 0)), str(entry.get("token", "")))
	var cond := EffectConditions.normalized(entry.get("cond", {}))
	if not EffectConditions.is_empty(cond):
		var cond_text := EffectConditions.text(cond)
		if cond_text != "":
			body = "若 %s：%s" % [cond_text, body]
	return body


## 「随机能力」这一条的卡面文本：池子名 + 随机个数 + 随机口径 + 能力清单。
## `value` > 0 表示卡表覆盖了池子的个数范围（见 _fx_random_pool）。
static func random_pool_text(pool_id: String, value: int = 0) -> String:
	var pid := pool_id.strip_edges()
	if pid == "":
		return "从能力池随机获得能力（未选择能力池）"
	var pool := AbilityPools.by_id(pid)
	if pool.is_empty():
		return "从能力池「%s」随机获得能力（池子不存在）" % pid
	var abilities: Array = pool.get("abilities", [])
	var lo := int(pool.get("count_min", 1))
	var hi := int(pool.get("count_max", 1))
	var mode := str(pool.get("mode", AbilityPools.MODE_REPEAT))
	var range_text := ""
	if value > 0:
		range_text = " %d 个" % value
	elif mode == AbilityPools.MODE_ORDER and hi <= 0:
		range_text = " 全部 %d 个" % abilities.size()
	elif lo == hi:
		range_text = " %d 个" % lo
	else:
		range_text = " %d–%d 个" % [lo, hi]
	var bits := PackedStringArray()
	for e in abilities:
		if typeof(e) == TYPE_DICTIONARY:
			var t := ability_text(e)
			if t != "":
				bits.append(t)
	return "从「%s」随机获得%s能力（%s）：%s" % [
		str(pool.get("name", pid)), range_text, AbilityPools.mode_label(mode),
		" / ".join(bits) if not bits.is_empty() else "（空池）"]