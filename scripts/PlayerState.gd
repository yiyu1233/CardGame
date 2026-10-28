class_name PlayerState
extends RefCounted
## 一名玩家的完整状态：英雄、法力、牌库、手牌、战场、墓地、疲劳计数。
##
## 战场有两种**互相自动对账**的视图：
##   * `slots` —— **定长 SLOT_COUNT 格**的格子数组（null = 空位），是「拖到哪一格就放进哪一格」的
##     权威来源。随从死亡只把它那一格置 null，**不收紧**其它随从：空位保留，下一位随从可以补进来。
##     （这一点与原版《影之诗》死亡后自动连续排列不同，是明确选定的规则。）
##   * `board` —— 紧凑的「场上单位」列表（只含真实单位、不含空位），语义与改动前完全一致：
##     城邦格里的城邦也在里面（带 in_city_slot 标记），但它**不占** slots。
##
## 旧写法（界面 / AI / 测试直接读 `p.board[i]`、`p.board.size()`、直接 append / erase）继续成立，
## 靠 `sync_slots()` 把两边对上：
##   1) 格子里指向「已经不在 board 里」的单位 → 置 null（保留空位，**不移动**其它单位）；
##   2) board 里还没有格子的单位（旧代码直接 `board.append` 进来的）→ 按 board 顺序补进第一个空格。

## 战场格子数（必须与 GameManager.BOARD_LIMIT 一致）
const SLOT_COUNT := 7
## 正中那一格 = 横置格（与 BoardSurface.front_lane() 一致：slot_limit / 2）
const FRONT_SLOT := 3

var player_id: int = 0
var display_name: String = "玩家"
var hero_hp: int = 30
var hero_max_hp: int = 30
var armor: int = 0
var mana: int = 0
var max_mana: int = 0
var fatigue: int = 0
## 过载：下一回合可用法力要减少这么多
var overload: int = 0
## 本回合已经打出的牌数（连击判定用）
var cards_played_turn: int = 0
## 本回合**我方**死亡的随从数 / 本局累计（瞬念召唤的「已经死了几个」类条件用）
var units_died_turn: int = 0
var units_died_total: int = 0
## 离场计数（**包含**死亡 / 回手 / 进墓地 / 消失，但不等同于「被破坏」）：
## 「消失」计入离场、不计入被破坏；被破坏只看 units_died_total（死亡结算）。
var units_left_turn: int = 0
var units_left_total: int = 0
## 墓地「进入过」的累计张数 / 每种卡进入过的次数（**只增不减**）：
## 墓地里的卡被召唤 / 回收离场时，当前墓地会减少，但这两个计数保持不变。
var grave_entered_total: int = 0
var grave_entered: Dictionary = {}
## 兵种进场计数（troop_id -> 张数）：本局累计 / 本回合。
## 「某一兵种的卡牌进入战场到一定数量就触发」这类条件（EffectConditions 的 troop_entered*）读它。
## 只在 `GameManager.summon_unit()` 成功放置时累加 —— 从手牌打出、衍生物、复制、亡语召唤都算。
var troop_entered_total: Dictionary = {}
var troop_entered_turn: Dictionary = {}

var deck: Array[CardData] = []
var hand: Array[CardData] = []
## 场上单位名单（紧凑：只含真实单位，不含空位）
var board: Array[BoardUnit] = []
## 定长战场格子（见文件头注释）。这里刻意用**无类型 Array**：
## 类型化的 `Array[BoardUnit]` 对 null 元素会做 Nil→Object 校验，装空位不保险；
## 无类型 Array 可以安全存 null（`p.slots[i] = null`），是「一定能跑通」的那一种。
var slots: Array = []
var graveyard: Array[CardData] = []
## 这是自己的第几个回合（城邦格每 3 个自己的回合判定一次）
var turns_taken: int = 0
## 上一次「城邦格召唤」发生在第几个总回合（保证同一回合不会召唤第二次）
var city_summon_turn: int = -1
## 上一次「调整防御格（移入 / 移出）」发生在第几个总回合：
## 每方每个自己的回合**只能移入或移出一次**（两个动作共用一个名额），
## 用「与 turn_count 比较」实现，回合开始不需要清零。
var front_move_turn: int = -1


func _init(pid: int = 0, pname: String = "玩家", max_hp: int = 30) -> void:
	player_id = pid
	display_name = pname
	hero_max_hp = max_hp
	hero_hp = max_hp
	reset_slots()


func is_alive() -> bool:
	return hero_hp > 0


## 主战者效果（照影之诗一代的「主战者に付与される効果」）：每条 = LeaderEffects.normalized()
## 的规格 + uid / source（赋予它的卡 id）/ expire_turn（-1 = 本局永久）。
## 由 GameManager 在事件发生时通过 LeaderEffects.fire() 结算，回合开始由 tick_leader_effects() 清到期。
var leader_effects: Array[Dictionary] = []
var _leader_seq := 0


## 挂上一条主战者效果，返回它的 uid
func add_leader_effect(spec: Dictionary, source_id: String, now_own_turn: int) -> int:
	_leader_seq += 1
	var e := spec.duplicate(true)
	e["uid"] = _leader_seq
	e["source"] = source_id
	var turns := int(spec.get("turns", 0))
	# 0 = 本局永久；N = 再过 N 个**这个主战者自己的**回合后失效
	e["expire_turn"] = -1 if turns <= 0 else now_own_turn + turns
	leader_effects.append(e)
	return _leader_seq


## 回合开始清到期（`now_own_turn` = 这个主战者已经进行到第几个自己的回合），返回摘掉几条
func tick_leader_effects(now_own_turn: int) -> int:
	var kept: Array[Dictionary] = []
	var removed := 0
	for e in leader_effects:
		var until := int(e.get("expire_turn", -1))
		if until >= 0 and now_own_turn >= until:
			removed += 1
			continue
		kept.append(e)
	leader_effects = kept
	return removed


## 一张卡进入战场：本局 / 本回合各 +1。
## **没选兵种的卡记在「中立」名下**（与 CardDB.troop_of 的口径一致：任何卡都属于某个兵种）。
func note_troop_entered(troop_id: String) -> void:
	var tid := troop_id if troop_id != "" else CardData.NEUTRAL_TROOP
	troop_entered_total[tid] = int(troop_entered_total.get(tid, 0)) + 1
	troop_entered_turn[tid] = int(troop_entered_turn.get(tid, 0)) + 1


## 一张卡进入墓地：**唯一入口**（所有“进墓地”的路径都调这里）。
## 同名卡按每一张单独记账（墓地数组里每一张都是独立条目）；累计计数只增不减，
## 之后从墓地被召唤 / 回收离场也不会回退。
func note_grave_entered(card: CardData) -> void:
	if card == null:
		return
	graveyard.append(card)
	grave_entered_total += 1
	var key := card.id if card.id != "" else card.card_name
	grave_entered[key] = int(grave_entered.get(key, 0)) + 1


## 某种卡累计进入过墓地几次（同名卡合起来算；0 = 没进过）
func grave_count(card_id: String) -> int:
	return int(grave_entered.get(card_id, 0))


## 一个单位离开场上（死亡 / 回手 / 进墓地 / 消失都算）：只记离场，不记被破坏
func note_unit_left() -> void:
	units_left_turn += 1
	units_left_total += 1


func get_unit(unit_id: int) -> BoardUnit:
	for u in board:
		if u != null and u.unit_id == unit_id:
			return u
	return null


# ------------------------------ 战场格子 ------------------------------

## 把格子数组重置为 SLOT_COUNT 个空位（新对局 / 清场时调用）
func reset_slots() -> void:
	slots.clear()
	for _i in SLOT_COUNT:
		slots.append(null)


## 保证格子数组至少有 SLOT_COUNT 个元素（旧数据可能只填了个别格子）
func _ensure_slots() -> void:
	while slots.size() < SLOT_COUNT:
		slots.append(null)


## 让 `slots` 与「场上单位名单」`board` 对账（幂等，可随时调用；见文件头注释）。
## 注意：本函数只调用 `first_empty_slot()/slot_at()`（它们**不**再对账），所以不会递归。
func sync_slots() -> void:
	_ensure_slots()
	# 1) 已经离场的单位：它那一格置 null（保留空位，其它单位一律不移动）
	for i in slots.size():
		var u: BoardUnit = slots[i]
		if u != null and not board.has(u):
			slots[i] = null
	# 2) 场上还没有格子的单位（旧代码直接 append 进来的）：按 board 顺序补进第一个空格
	for u in board:
		if u == null or u.in_city_slot or slots.has(u):
			continue
		var idx := first_empty_slot()
		if idx < 0:
			break
		slots[idx] = u


## 第 slot 格里的单位（越界 / 空位 → null）。**不**对账（对账内部会用）。
func slot_at(slot: int) -> BoardUnit:
	if slot < 0 or slot >= SLOT_COUNT:
		return null
	_ensure_slots()
	# 无类型 Array 取出来的元素是 Variant：按项目里既有的写法显式声明目标类型（运行时校验）
	var u: BoardUnit = slots[slot]
	return u


## 第一个空位的格子号（没有 → -1）
func first_empty_slot() -> int:
	for i in SLOT_COUNT:
		if slot_at(i) == null:
			return i
	return -1


## 单位所在的格子号（不在格子里 / 城邦格里的城邦 → -1）
func slot_of(u: BoardUnit) -> int:
	if u == null:
		return -1
	sync_slots()
	for i in SLOT_COUNT:
		if slots[i] == u and not u.in_city_slot:
			return i
	return -1


## 把一个单位放进第 slot 格。越界 / 该格已被占用 → false。
## 单位已经在别的格子里时视为**移动**：旧格子留空（不移动其它单位）。
func place_unit_at(u: BoardUnit, slot: int) -> bool:
	if u == null or slot < 0 or slot >= SLOT_COUNT:
		return false
	sync_slots()
	var cur := slot_of(u)
	if cur == slot:
		return true
	if slots[slot] != null:
		return false
	if cur >= 0:
		slots[cur] = null
	if not board.has(u):
		board.append(u)
	slots[slot] = u
	return true


## 把一个单位从战场上拿掉：它那一格置 null（**保留空位**），并从 board 名单里移除。
## 死亡结算 / 倒计时摧毁 / 移回手牌都走这里。
func remove_unit(u: BoardUnit) -> void:
	if u == null:
		return
	sync_slots()
	var idx := slot_of(u)
	if idx >= 0:
		slots[idx] = null
	board.erase(u)


## 真正占战场格子的单位数（城邦格里的城邦不计）
func used_count() -> int:
	var n := 0
	for u in board:
		if u != null and not u.in_city_slot:
			n += 1
	return n


## 按**格子顺序**返回战场单位（跳过空位；城邦格里的城邦**不计**）。
## 兜底：没被对账进格子的多余单位（旧代码 append 超过 7 个）按 board 顺序排在后面。
func units_in_slot_order() -> Array[BoardUnit]:
	sync_slots()
	var out: Array[BoardUnit] = []
	var seen := {}
	for i in SLOT_COUNT:
		var u: BoardUnit = slots[i]
		if u != null and not u.in_city_slot:
			out.append(u)
			seen[u] = true
	for u in board:
		if u != null and not u.in_city_slot and not seen.has(u):
			out.append(u)
	return out


## 结算 / 目标列表用的顺序：格子顺序的战场单位 + 城邦格里的城邦（它没有格子，排在最后）。
## 城邦必须留在这里：它照旧可被指定 / 被攻击 / 被群体效果命中。
func units_in_order() -> Array[BoardUnit]:
	var out := units_in_slot_order()
	for u in board:
		if u != null and u.in_city_slot:
			out.append(u)
	return out
