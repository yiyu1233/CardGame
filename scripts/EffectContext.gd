class_name EffectContext
extends RefCounted
## 一次效果结算的上下文：封装“谁发动、数值多少、目标是谁”。
## 并提供 damage / heal / buff / summon / draw 等高层操作，
## 新增效果时只需调用这些方法，无需关心底层实现（圣盾、护甲、疲劳、上限检查等）。

## 对 GameManager 的引用（由创建者传入，避免与自动加载产生循环编译依赖）
var gm
var caster_pid: int = 0        ## 发动效果的玩家
var value: int = 0             ## 效果数值
var token_id: String = ""      ## 衍生物 ID（召唤类效果使用）
var target: Dictionary = {}    ## {"kind", "unit_id", "player_id"}
var source_name: String = ""   ## 来源卡牌名（日志用）
var card: CardData = null      ## 正在结算的卡牌（随机能力 / 需要卡名与卡数据的后续效果用）
var is_deathrattle := false    ## 是否为亡语触发
var source_unit: BoardUnit = null  ## 造成这次效果的随从（战吼 / 亡语 / 随从法术伤害），法术为 null
                                   ## —— 吸血 / 剧毒这类“由来源造成伤害”的机制靠它生效
## 限定词缀之一「来源」：检索牌库 / 墓地 / 牌库优先（见 SRC_* 常量）
var src: int = 0
## 限定词缀之二「持续回合数」：0 = 永久或一次性（老卡表语义）；N = 到第 N 个回合结束时失效
var turns: int = 0


## 从牌库 / 墓地检索一张卡时的「口径」（拆成 3 个独立效果，方便在效果链里挑一种）
const DECK_FILTER_ID := 0      ## 指定卡 ID（token 字段），不限类型
const DECK_FILTER_COST := 1    ## 费用 ≤ 数值 的**随从**
const DECK_FILTER_RANDOM := 2  ## 任意**随从**（不看条件）

## 检索的「来源」限定词缀（卡面效果多出来的那一项）：
## SRC_DECK = 只认牌库；SRC_GRAVE = 只认墓地（亡招）；SRC_DECK_FIRST = 牌库优先，牌库没有再看墓地
## —— 最后一种就是城邦格那条规则（“先从牌堆随机召唤，牌堆没有就从墓地亡招”）搬到呼唤效果上。
const SRC_DECK := 0
const SRC_GRAVE := 1
const SRC_DECK_FIRST := 2

## 来源限定词缀的名称（日志 / 卡面文本用）
const SOURCE_NAMES := ["牌库", "墓地", "牌库优先→墓地"]


static func create(gm_ref, pid: int, value: int, token_id: String, target: Dictionary,
		source_name: String = "", death: bool = false,
		source: BoardUnit = null, src_kind: int = 0, duration_turns: int = 0,
		card_ref: CardData = null) -> EffectContext:
	var ctx := EffectContext.new()
	ctx.gm = gm_ref
	ctx.caster_pid = pid
	ctx.value = value
	ctx.token_id = token_id
	ctx.target = target
	ctx.source_name = source_name
	ctx.is_deathrattle = death
	ctx.source_unit = source
	ctx.src = src_kind
	ctx.turns = duration_turns
	ctx.card = card_ref
	return ctx


# ------------------------------ 查询 ------------------------------

func caster() -> PlayerState:
	return gm.get_player(caster_pid)


func foe() -> PlayerState:
	return gm.get_foe(caster_pid)


## 目标随从（目标是英雄时返回 null）
func unit() -> BoardUnit:
	var uid: int = int(target.get("unit_id", -1))
	return gm.find_unit(uid) if uid >= 0 else null


## 「本随从」：明确指定了目标随从就用它，否则回到发动效果的来源随从（战吼 / 亡语 / 技能）。
## 没有来源也没有目标（典型是法术）→ null，调用方据此跳过。
func self_unit() -> BoardUnit:
	var u := unit()
	return u if u != null else source_unit


func target_pid() -> int:
	return int(target.get("player_id", caster_pid))


func target_player() -> PlayerState:
	return gm.get_player(target_pid())


func is_hero_target() -> bool:
	return int(target.get("unit_id", -1)) < 0


## 注意：不能命名为 log()，会与 GDScript 内置的全局 log(浮点数) 冲突
func log_text(text: String) -> void:
	gm.log_line(text)


# ------------------------------ 基础操作 ------------------------------

## 对随从造成伤害：统一走 GameManager 的伤害管线，
## 于是吸血 / 剧毒以及后续新增的机制都会在法术与战吼伤害上同样生效。
func damage_unit(u: BoardUnit, amount: int) -> void:
	if u == null or amount <= 0:
		return
	var dealt: int = gm.deal_damage_to_unit(source_unit, u, amount)
	if dealt > 0:
		log_text("「%s」受到 %d 点伤害（剩余 %d）" % [u.data.card_name, dealt, maxi(0, u.health)])
	else:
		log_text("「%s」的圣盾被击破，未受到伤害" % u.data.card_name)


func damage_hero(pid: int, amount: int) -> void:
	if amount <= 0:
		return
	gm.deal_damage_to_hero(source_unit, pid, amount)


## 目标是随从就打随从，是英雄就打英雄
func damage_target(amount: int) -> void:
	var u := unit()
	if u != null:
		damage_unit(u, amount)
	else:
		damage_hero(target_pid(), amount)


func heal_unit(u: BoardUnit, amount: int) -> void:
	if u == null or amount <= 0:
		return
	u.heal(amount)
	log_text("「%s」恢复至 %d 点生命" % [u.data.card_name, u.health])


func heal_hero(pid: int, amount: int) -> void:
	if amount <= 0:
		return
	var p: PlayerState = gm.get_player(pid)
	if p == null:
		return
	p.hero_hp = mini(p.hero_max_hp, p.hero_hp + amount)
	log_text("%s 恢复 %d 点生命（当前 %d）" % [p.display_name, amount, p.hero_hp])


func heal_target(amount: int) -> void:
	var u := unit()
	if u != null:
		heal_unit(u, amount)
	else:
		heal_hero(target_pid(), amount)


func buff_unit(u: BoardUnit, atk: int, hp: int) -> void:
	if u == null:
		return
	u.attack = maxi(0, u.attack + atk)
	# 最大生命**不兜底到 1**：减益可以把最大生命压到 0 以下，由死亡结算处理
	# （「最大血量等于 / 小于 0 时同样被破坏」）。当前生命最多扣到 0，避免界面上出现负血。
	u.max_health = u.max_health + hp
	u.health = maxi(0, u.health + hp)
	log_text("「%s」获得 %+d/%+d（现为 %d/%d）" % [u.data.card_name, atk, hp, u.attack, u.health])


func kill_unit(u: BoardUnit) -> void:
	if u == null:
		return
	# 词条「不灭」：不会被能力破坏（这是“破坏”，不是伤害，所以不派发任何受伤事件）
	if Mechanics.flag(u, Mechanics.FLAG_IMMUNE_ABILITY_DESTROY):
		log_text("「%s」不灭：不会被能力破坏" % u.data.card_name)
		return
	log_text("「%s」被消灭" % u.data.card_name)
	u.health = 0


func summon(pid: int, token_id: String, count: int = 1) -> void:
	var card: CardData = gm.card_by_id(token_id)
	if card == null:
		log_text("找不到衍生物：%s" % token_id)
		return
	for _i in maxi(1, count):
		gm.summon_unit(pid, card)


func summon_copy(pid: int, source: BoardUnit) -> void:
	if source == null:
		return
	gm.summon_unit(pid, source.data.clone())


## 让目标单位触发一次它的入场效果（随从 = 战吼，护符 / 城邦 = 安放）。
## 召唤上场的单位默认不结算入场效果，这是唯一的例外入口。
func trigger_entrance(u: BoardUnit) -> void:
	gm.trigger_entrance_effect(u)


## 把一个单位的 N 份副本召唤上场（复制的是**卡牌本体**：再次被复制 / 召唤都不会连锁触发入场效果）
func summon_copies(pid: int, source: BoardUnit, count: int) -> void:
	gm.summon_copies(pid, source, count)


## 把一个单位的 N 份副本随机洗进某一方的牌库
func copy_unit_to_deck(pid: int, source: BoardUnit, count: int) -> void:
	gm.copy_unit_to_deck(pid, source, count)


## 随机把某一方的 N 张手牌复制一份，洗进**发动效果这一方**的牌库（来源手牌不动）
func copy_hand_to_deck(from_pid: int, count: int) -> void:
	gm.copy_hand_cards_to_deck(caster_pid, from_pid, count)


## 抬高某一方手牌的费用。
## `duration` > 0 时是「限时版」：到这一方的第 N 个回合结束时自动把费用还回去。
func raise_hand_cost(pid: int, amount: int, duration: int = 0) -> void:
	gm.raise_hand_cost(pid, amount, duration)


## 检索一张卡并召唤上场；`source` 决定从牌库还是墓地找，`temporary` = 拥有者**下一个自己的回合结束时回到手牌**
func summon_from_source(filter_kind: int, value: int, token_id: String, source: int,
		temporary: bool) -> BoardUnit:
	return gm.summon_from_source(caster_pid, filter_kind, value, token_id, source, temporary)


## 从牌库检索一张卡并召唤上场（等价于来源限定 = 牌库）
func summon_from_deck(filter_kind: int, value: int, token_id: String, temporary: bool) -> BoardUnit:
	return gm.summon_from_source(caster_pid, filter_kind, value, token_id, SRC_DECK, temporary)


func draw(pid: int, count: int) -> void:
	gm.draw(pid, count)


func add_armor(pid: int, amount: int) -> void:
	var p: PlayerState = gm.get_player(pid)
	if p == null or amount <= 0:
		return
	p.armor += amount
	log_text("%s 获得 %d 点护甲（当前 %d）" % [p.display_name, amount, p.armor])


func add_mana(pid: int, amount: int) -> void:
	var p: PlayerState = gm.get_player(pid)
	if p == null or amount <= 0:
		return
	p.mana += amount
	log_text("%s 获得 %d 点法力（当前 %d）" % [p.display_name, amount, p.mana])


## 永久增加一个法力水晶（并立即补满该点法力）
func add_mana_crystal(pid: int, amount: int) -> void:
	var p: PlayerState = gm.get_player(pid)
	if p == null or amount <= 0:
		return
	p.max_mana = mini(gm.MAX_MANA, p.max_mana + amount)
	p.mana += amount
	log_text("%s 获得 %d 个法力水晶（当前 %d/%d）" % [p.display_name, amount, p.mana, p.max_mana])


## 赋予一个机制：**后到者覆盖** —— 与新机制互斥的旧机制会被摘掉（见 Mechanics.conflicts_of）。
## 「被冻结」也是一种状态：它与「当回合就能攻击」的冲锋 / 突袭互斥，同样是后到者覆盖
## —— 给冻结的单位赋予冲锋会把它解冻；反过来冻结一个带了冲锋的单位会把冲锋顶掉。
func grant_keyword(u: BoardUnit, k: CardData.Keyword) -> void:
	if u == null:
		return
	var dropped: Array = u.add_keyword(k)
	log_text("「%s」获得「%s」" % [u.data.card_name, CardData.KEYWORD_NAMES.get(k, str(k))])
	for old in dropped:
		log_text("  「%s」的「%s」被覆盖（与新获得的效果冲突）" % [
			u.data.card_name, CardData.KEYWORD_NAMES.get(old, str(old))])
	if Mechanics.status_conflicts(Mechanics.STATUS_FROZEN).has(k) and u.is_frozen(gm.turn_count):
		u.frozen_until = -1
		log_text("  「%s」解冻（与新获得的效果冲突）" % u.data.card_name)


func freeze_unit(u: BoardUnit) -> void:
	if u == null:
		return
	for old in Mechanics.status_conflicts(Mechanics.STATUS_FROZEN):
		if u.has_keyword(old):
			u.remove_keyword(old)
			log_text("「%s」的「%s」被覆盖（冻结与它冲突）" % [
				u.data.card_name, CardData.KEYWORD_NAMES.get(old, str(old))])
	u.frozen_until = gm.turn_count + 1
	log_text("「%s」被冻结（下回合无法攻击）" % u.data.card_name)


func silence_unit(u: BoardUnit) -> void:
	if u == null:
		return
	u.silence()
	log_text("「%s」被沉默（关键字与增益已移除）" % u.data.card_name)


## 将随从移回其拥有者的手牌
func return_to_hand(u: BoardUnit) -> void:
	gm.return_unit_to_hand(u)


# ------------------------------ 目标集合 ------------------------------

func ally_minions() -> Array[BoardUnit]:
	var p := caster()
	# 己方：自己视角的左→右
	return gm.side_order(caster_pid)


func enemy_minions() -> Array[BoardUnit]:
	# 敌方镜像：对方视角的左→右 = 本视角的右→左。
	# 顺序必须按**格子索引**取（空洞不再收紧，直接逆序遍历 p.board 会得到错的左右关系）。
	var out: Array[BoardUnit] = []
	var p := foe()
	if p == null:
		return out
	var ordered: Array = gm.board_units(p.player_id)
	for i in range(ordered.size() - 1, -1, -1):
		out.append(ordered[i])
	return out


func all_minions() -> Array[BoardUnit]:
	# 全体：己方左→右，然后敌方镜像
	return gm.unit_order(caster_pid)


func random_enemy_minion() -> BoardUnit:
	var list := enemy_minions()
	return list[randi() % list.size()] if list.size() > 0 else null


func random_ally_minion() -> BoardUnit:
	var list := ally_minions()
	return list[randi() % list.size()] if list.size() > 0 else null
