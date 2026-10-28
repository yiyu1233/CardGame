class_name BoardUnit
extends RefCounted
## 战场上一个随从的运行时实例（与静态的 CardData 区分）。

var unit_id: int = 0
var owner_id: int = 0
var data: CardData
var attack: int = 0
var health: int = 0
var max_health: int = 0
var keywords: Array[int] = []
var divine_shield := false
var summoned_turn: int = -1
var attacks_used := 0
var frozen_until: int = -1    ## 被冻结到该回合为止（turn <= frozen_until 时无法攻击）
## 是否位于「中线前的横置格」：只受 1 点伤害、不能发动主动行为（攻击 / 将来的主动技能）、
## 会被敌方技能优先指定；受伤后自动退回后排并清掉这个状态。随从自身的战吼 / 亡语 / 关键字照常。
var in_front := false
## 是否位于主战者旁的「城邦格」：不占 7 格战场，其余规则（耐久 / 可被解）与普通城邦一致
var in_city_slot := false
## 复生是否已经用过（每个单位只复活一次）
var reborn_used := false
## 主动技能本回合是否已经发动过：记的是**发动时的 turn_count**（-1 = 从没用过）。
## 用回合数比较而不是在回合开始重置——「每回合一次」天然成立，联机快照也不会漏掉。
var skill_used_turn: int = -1
## 倒计时（护符 / 城邦用）：归零时被摧毁；0 = 不倒计时
var countdown := 0
## 临时召唤（瞬念召唤式登场）的召回回合：拥有者**回合结束时** turn_count >= 它就回到手牌；
## -1 = 不是临时单位。联机不需要同步这个字段：房主才会真的执行召回，客机跟着快照重建界面即可。
var recall_turn: int = -1
## 伤害减免（效果赋予，可叠加）：能力伤害 / 碰撞伤害各一档，结算时按伤害来源扣减。
## 由效果「能力伤害减免 / 碰撞伤害减免」写入；沉默时清零（与增益同一口径）。
var ability_damage_reduction := 0
var collision_damage_reduction := 0
## 「赋予技能 / 能力」的原始值：第一次被赋予时记下卡面自带的那一份，
## 离场（进墓地 / 回手 / 消失）时恢复 —— 赋予的东西不会跟着卡进墓地或手牌。
## 注意：赋予期间 `data.skill` / `data.triggers` 就是**合并后**的视图，
## 所以技能 / 触发 / 面板读到的都是最新值，不需要改调用方。
var base_skill: Dictionary = {}
var base_triggers: Array[Dictionary] = []
var granted_dirty := false
## 觉醒（影之诗「覚醒」）是否已经结算过：一次性 +1/+1，之后不再重复触发
var awaken_done := false


func setup(card: CardData, owner: int, turn: int, uid: int) -> void:
	data = card
	owner_id = owner
	unit_id = uid
	attack = card.attack
	health = card.health
	max_health = card.health
	keywords = card.keywords.duplicate()
	divine_shield = keywords.has(CardData.Keyword.DIVINE_SHIELD)
	summoned_turn = turn
	attacks_used = 0
	frozen_until = -1
	in_front = false
	in_city_slot = false
	reborn_used = false
	skill_used_turn = -1
	countdown = card.countdown
	recall_turn = -1
	ability_damage_reduction = 0
	collision_damage_reduction = 0
	base_skill = {}
	base_triggers = []
	granted_dirty = false
	awaken_done = false


func has_keyword(k: CardData.Keyword) -> bool:
	return keywords.has(k)


## 赋予一个机制：**同时挂上去会互相拆台的旧机制会被摘掉** —— 后给予的效果覆盖冲突的那个
## （互斥表见 `Mechanics.conflicts_of()`）。返回被覆盖掉的机制，方便调用方记日志 / 做提示。
## 注意：只有**运行时赋予**走这里；卡数据自带的词条里本来就有两个互斥词条时没有先后之分，
## 保持原样（那是配卡层面的取舍，不是这一条规则要管的事）。
func add_keyword(k: CardData.Keyword) -> Array[int]:
	var dropped: Array[int] = []
	for old in Mechanics.conflicts_of(k):
		if keywords.has(old):
			remove_keyword(old)
			dropped.append(old)
	if not keywords.has(k):
		keywords.append(k)
	if k == CardData.Keyword.DIVINE_SHIELD:
		divine_shield = true
	return dropped


func remove_keyword(k: CardData.Keyword) -> void:
	keywords.erase(k)
	if k == CardData.Keyword.DIVINE_SHIELD:
		divine_shield = false


## 机制（关键字）查询：机制的具体行为注册在 Mechanics.gd
func has_mechanic(k: CardData.Keyword) -> bool:
	return keywords.has(k)


## 当前携带的所有机制名称（提示 / 调试用）
func mechanic_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k in keywords:
		out.append(Mechanics.display_name(k))
	return out


func is_frozen(turn: int) -> bool:
	return turn <= frozen_until and frozen_until >= 0


## 沉默：移除所有关键字 / 圣盾 / 冻结，并把攻防恢复到卡牌原始数值（移除增益）
func silence() -> void:
	keywords.clear()
	divine_shield = false
	frozen_until = -1
	attack = data.attack
	# 不在这里兜底到 1：最大生命已经是 0 / 负数的单位，沉默不能把它“救活”
	max_health = data.health
	health = maxi(0, mini(health, max_health))
	ability_damage_reduction = 0
	collision_damage_reduction = 0
	# 赋予来的技能 / 能力也属于增益：沉默时回到卡面自带的那一份
	strip_granted()


## 存活 = 当前生命 > 0 **且** 最大生命 > 0。
## 后者对应「最大血量等于 / 小于 0 时同样被破坏」：减益可以把最大生命压到 0 以下，
## 即使当前生命还没被扣光，也会在死亡结算里进墓地。
func is_alive() -> bool:
	return health > 0 and max_health > 0


## 被「赋予技能 / 能力」之前先记一份卡面原值（只在第一次赋予时记）
func note_granted() -> void:
	if granted_dirty or data == null:
		return
	base_skill = data.skill.duplicate(true)
	base_triggers = data.triggers.duplicate(true)
	granted_dirty = true


## 离场时把「赋予」的东西摘掉（技能 / 能力回到卡面自带的那一份）。
## 由 GameManager 在所有「进墓地 / 回手 / 消失」的路径上调用；重复调用是安全的。
func strip_granted() -> void:
	if not granted_dirty or data == null:
		return
	data.skill = base_skill.duplicate(true)
	data.triggers = base_triggers.duplicate(true)
	base_skill = {}
	base_triggers = []
	granted_dirty = false


func max_attacks() -> int:
	return 2 if has_keyword(CardData.Keyword.WINDFURY) else 1


func is_taunt() -> bool:
	return has_keyword(CardData.Keyword.TAUNT)


## 是否是护符 / 城邦（占一格、不能攻击、有耐久）
func is_permanent() -> bool:
	return data != null and data.is_permanent()


## 护符 / 城邦的耐久显示值
func durability() -> int:
	return maxi(0, health)


## 是否可以发动主动行为（现在是“攻击”；以后若加主动技能也必须过这一关）
func can_act() -> bool:
	return not in_front and not is_permanent()


## 是否可以发动**攻击类**主动行为（横置中的随从、护符 / 城邦都不能）。
## 注意：这个口径**只管攻击**。卡表配置的主动技能（CardData.skill）另有一套门禁
## ——见 GameManager.can_use_skill() / skill_blocked_reason()：护符 / 城邦也能发动技能，
## 横置 / 冻结 / 能量点不足 / 本回合已发动过才是不行的原因。
func can_use_active_skill() -> bool:
	return not in_front and not is_permanent()


## 是否可以攻击（回合数用于判断召唤当回合的“未准备好”状态）
func can_attack(turn: int, target_is_minion: bool = true) -> bool:
	if not is_alive() or attack <= 0:
		return false
	# 声明式标志位：机制只要在 _reg(..., [Mechanics.FLAG_CANNOT_ATTACK]) 里写一下就生效
	if Mechanics.flag(self, Mechanics.FLAG_CANNOT_ATTACK):
		return false
	if is_permanent():
		return false          # 护符 / 城邦不能攻击
	if in_front:
		return false
	if is_frozen(turn):
		return false
	if attacks_used >= max_attacks():
		return false
	if summoned_turn == turn:
		if has_keyword(CardData.Keyword.CHARGE):
			return true
		if has_keyword(CardData.Keyword.RUSH):
			return target_is_minion
		return false
	return true


## 返回是否真的受到了伤害（false 表示被圣盾免疫）
func take_damage(amount: int) -> bool:
	if amount <= 0:
		return false
	if divine_shield:
		# 「有两个账本」会出事：units 的 keywords 里若还留着圣盾词条，界面标签 / 搬运
		# 单位（复生、复制、快照）会把它当成还在。这里连同词条一起摘掉，只有一个记账处。
		remove_keyword(CardData.Keyword.DIVINE_SHIELD)
		return false
	health -= amount
	return true


func heal(amount: int) -> void:
	if amount <= 0:
		return
	health = mini(max_health, health + amount)


func buff(amount: int) -> void:
	attack += amount
	health += amount
	max_health += amount
