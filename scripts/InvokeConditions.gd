class_name InvokeConditions
extends RefCounted
## 瞬念召唤（影之诗 Invocation 风格）的**触发条件**注册表。
##
## 设计参照《影之诗》反编译实现（`D:\逆向工程\decompiled\Assembly-CSharp`），三条照搬：
##
##   1. **条件 = 「要读的一个量」+「一个比较符」+「一个阈值」**
##      SV 的每个 SkillConditionXxx（SkillConditionTurn / PP / PlayCount / HalfLife…）只读**一个**量，
##      比较符统一由 `SkillCompareFuncCreator.Create(op)` 给出（`= != <= >= < >` 六种）。
##      于是 N 个量 × 6 个比较符 = 6N 种条件，不用为「手牌 ≥ N」和「手牌 ≤ N」写两个 ID ——
##      这里同样的：新增一个量只要加一行 `_reg(...)`，管理员的下拉框会自动多一项。
##
##   2. **判定入参是预先算好的「局面快照」**（对应 SV 的 `SkillConditionCheckerOption`，
##      它把 PlayedCard / InHandCard / DeckSelfSummonedCards… 这些整理好再交给条件读）。
##      一个检查点只算一次快照，条件只读快照 —— 不会每判断一张卡就重扫一遍棋盘。
##
##   3. **「同名卡一回合一次」= SV 的 `SkillPreprocessTimesPerTurn` 配 `same_base_card_id`**，
##      所以 key 用**卡牌 id**（即 SV 的 base_card_id），不用显示名：改卡面名字不会让限制失效。
##
## 触发时机对应 SV 技能上的 On*Start 字段：
##   TIME_SELF_TURN_START   ↔ OnSelfTurnStartStart
##   TIME_SELF_TURN_END     ↔ OnSelfTurnEndStart
##   TIME_ANY              ↔ 打出牌（OnWhenPlayOtherStart）/ 攻击（OnAfterAttackStart）之后那两处
##
## 注：SV 还有 OnOpponentTurnStartStart / OnOpponentTurnEndStart 两种「对手回合」时机，
## 本作**刻意没有照搬**：瞬念召唤只在这一方**自己的回合**结算（原因见 GameManager 的
## 瞬念召唤小节），所以这里只有上面三种（老数据里可能带 3 / 4，CardData 读取时迁过来）。

const NONE := ""

# ------------------------------ 触发时机 ------------------------------
const TIME_ANY := 0              ## 任意检查点（我方回合内：打出牌后 / 攻击后 / 回合开始 / 回合结束）
const TIME_SELF_TURN_START := 1  ## 我方回合开始时（抽牌之后）
const TIME_SELF_TURN_END := 2    ## 我方回合结束时
const TIME_NAMES := ["任意时机", "我方回合开始时", "我方回合结束时"]

## 已经废弃的「对手回合」时机（瞬念召唤不在对手回合触发了）：
## 旧卡表里可能还留着这两个值，这里给出对应的迁移目标，由 CardData 读取时改写。
const LEGACY_TIME_MAP := {3: TIME_SELF_TURN_START, 4: TIME_SELF_TURN_END}


## 旧时机值 → 现在的时机值（3 / 4 这两个「对手回合」迁到对应的「我方回合」）
static func migrate_timing(timing: int) -> int:
	_ensure()
	var mapped: int = int(LEGACY_TIME_MAP.get(timing, timing))
	return clampi(mapped, TIME_ANY, TIME_NAMES.size() - 1)

# ------------------------------ 比较符 ------------------------------
## 与 SV 的 SkillCompareFuncCreator 同款六种；存进卡表里的是**字符串**，不是下标，
## 这样以后加/减一种比较符不会让旧卡表集体错位。
const OPS := ["<=", ">=", "=", "!=", "<", ">"]

static var _metrics: Dictionary = {}
static var _metric_order: Array[String] = []
## 兵种类量：读的时候要**多一个兵种参数**（`fn(gm, pid, troop) -> int`），
## 快照里按 `量@兵种` 铺开（见 snapshot），判定时用 scope_key() 拼出同一个 key。
static var _troop_metrics: Dictionary = {}
static var _troop_order: Array[String] = []
const TROOP_SCOPE_SEP := "@"
static var _ops: Dictionary = {}


static func _ensure() -> void:
	if _metrics.is_empty():
		_build()


static func _build() -> void:
	# ---- 比较符 ----
	_ops["<="] = func(a: int, b: int) -> bool: return a <= b
	_ops[">="] = func(a: int, b: int) -> bool: return a >= b
	_ops["="] = func(a: int, b: int) -> bool: return a == b
	_ops["!="] = func(a: int, b: int) -> bool: return a != b
	_ops["<"] = func(a: int, b: int) -> bool: return a < b
	_ops[">"] = func(a: int, b: int) -> bool: return a > b

	# ---- 要读的量（label + 默认值方向 + 读取方法）----
	_reg("turn", "回合数", ">=", func(gm, pid) -> int:
		return gm.turn_count)
	_reg("self_turn", "我方已进行回合数", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.turns_taken if p != null else 0)
	_reg("mana", "我方剩余法力", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.mana if p != null else 0)
	_reg("max_mana", "我方法力上限", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.max_mana if p != null else 0)
	_reg("self_hp", "我方英雄生命", "<=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.hero_hp if p != null else 0)
	_reg("enemy_hp", "敌方英雄生命", "<=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_foe(pid)
		return p.hero_hp if p != null else 0)
	_reg("hand", "我方手牌张数", "<=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.hand.size() if p != null else 0)
	_reg("self_board", "我方随从数", ">=", func(gm, pid) -> int:
		return gm.board_size_used(pid))
	_reg("enemy_board", "敌方随从数", ">=", func(gm, pid) -> int:
		return gm.board_size_used(1 - pid))
	_reg("cards_played", "本回合已打出牌数", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.cards_played_turn if p != null else 0)
	_reg("units_died", "本回合我方死亡随从数", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.units_died_turn if p != null else 0)
	_reg("total_units_died", "本局我方累计死亡随从数", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.units_died_total if p != null else 0)
	_reg("graveyard", "我方墓地张数", ">=", func(gm, pid) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.graveyard.size() if p != null else 0)

	# ---- 兵种类量：读「某个兵种」的张数（兵种由管理员创建，所以这里不写死任何兵种 id）----
	_reg_troop("troop_entered", "本局该兵种进场数", ">=", func(gm, pid, troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return int(p.troop_entered_total.get(troop, 0)) if p != null else 0)
	_reg_troop("troop_entered_turn", "本回合该兵种进场数", ">=", func(gm, pid, troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return int(p.troop_entered_turn.get(troop, 0)) if p != null else 0)
	_reg_troop("troop_board", "我方场上该兵种随从数", ">=", func(gm, pid, troop) -> int:
		var n := 0
		for u in gm.board_units(pid):
			if u != null and u.data != null and u.data.troop_id == troop:
				n += 1
		return n)
	_reg_troop("troop_grave", "我方墓地该兵种张数", ">=", func(gm, pid, troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		if p == null:
			return 0
		var n := 0
		for c in p.graveyard:
			if c != null and c.troop_id == troop:
				n += 1
		return n)


## 注册一个「可读的量」：`fn(gm, pid) -> int` 只读它自己关心的那个数
static func _reg(id: String, label: String, default_op: String, fn: Callable) -> void:
	_metrics[id] = {"id": id, "label": label, "op": default_op, "read": fn}
	_metric_order.append(id)


## 注册一个「兵种类量」：`fn(gm, pid, troop) -> int`
static func _reg_troop(id: String, label: String, default_op: String, fn: Callable) -> void:
	_troop_metrics[id] = {"id": id, "label": label, "op": default_op, "read_troop": fn}
	_troop_order.append(id)


# ------------------------------ 兵种类量 ------------------------------

## 这个量是不是「要看某个兵种」（管理员面板因此要多给一个兵种下拉）
static func metric_wants_troop(id: String) -> bool:
	_ensure()
	return _troop_order.has(id)


## 快照里 / 判定时用的 key：兵种类量 = `量@兵种`，其余量原样返回
static func scope_key(metric: String, troop: String) -> String:
	_ensure()
	if not metric_wants_troop(metric):
		return metric
	var tid := troop if troop != "" else CardData.NEUTRAL_TROOP
	return "%s%s%s" % [metric, TROOP_SCOPE_SEP, tid]


# ------------------------------ 查询 ------------------------------

## 所有可比的量（管理员下拉框的顺序）：普通量 + 兵种类量
static func metrics() -> Array[String]:
	_ensure()
	var out: Array[String] = _metric_order.duplicate()
	out.append_array(_troop_order)
	return out


static func has_metric(id: String) -> bool:
	_ensure()
	return id != "" and id != NONE and (_metrics.has(id) or _troop_metrics.has(id))


static func has_op(op: String) -> bool:
	_ensure()
	return _ops.has(op)


## 这个量的默认比较符（配新品时给一个合理的初始方向：叫「数」的用 ≥，叫「生命 / 张数上限」的用 ≤）
static func default_op(metric: String) -> String:
	_ensure()
	if _metrics.has(metric):
		return str(_metrics[metric]["op"])
	if _troop_metrics.has(metric):
		return str(_troop_metrics[metric]["op"])
	return ">="


static func metric_label(id: String) -> String:
	_ensure()
	if _metrics.has(id):
		return str(_metrics[id]["label"])
	if _troop_metrics.has(id):
		return str(_troop_metrics[id]["label"])
	return id


## 比较符在**卡面**上的写法：数据里存 ASCII（<= >= !=），卡上显示 ≤ ≥ ≠，
## 这样既不会因为字体缺字符写不进 JSON，管理员读起来又是习惯的样子。
static func op_symbol(op: String) -> String:
	match op:
		"<=":
			return "≤"
		">=":
			return "≥"
		"!=":
			return "≠"
	return op


## 卡面文本：「我方手牌张数 ≤ 3」/「本局该兵种进场数「士兵」≥ 3」
static func text(metric: String, op: String, value: int, troop: String = "") -> String:
	_ensure()
	if not has_metric(metric) or not has_op(op):
		return ""
	if metric_wants_troop(metric):
		return "%s「%s」%s %d" % [metric_label(metric), CardData.troop_label(troop),
			op_symbol(op), value]
	return "%s %s %d" % [metric_label(metric), op_symbol(op), value]


## 一次检查点上「所有要读的量」算一次；条件只读这张表（对应 SV 的 SkillConditionCheckerOption）。
## 兵种类量按「这一方身上出现过的兵种」铺开成 `量@兵种`：没出现过的兵种读 0（met 的缺省值），
## 所以「某兵种 ≥ 0」这类条件照样成立，不需要把全部兵种 id 都塞进快照。
static func snapshot(gm, pid: int) -> Dictionary:
	_ensure()
	var ctx := {}
	if gm == null:
		return ctx
	for id in _metric_order:
		var fn: Callable = _metrics[id]["read"]
		ctx[id] = int(fn.call(gm, pid))
	var troops := _troop_ids_seen(gm, pid)
	for id in _troop_order:
		var fn: Callable = _troop_metrics[id]["read_troop"]
		for tid in troops:
			ctx[scope_key(id, tid)] = int(fn.call(gm, pid, tid))
	return ctx


## 这一方「身上出现过」的兵种 id：进场计数里记过的 + 场上 / 墓地里卡牌挂的
static func _troop_ids_seen(gm, pid: int) -> Array[String]:
	var out: Array[String] = []
	var p: PlayerState = gm.get_player(pid)
	if p == null:
		return out
	for key in p.troop_entered_total.keys():
		if not out.has(str(key)):
			out.append(str(key))
	for key in p.troop_entered_turn.keys():
		if not out.has(str(key)):
			out.append(str(key))
	for u in gm.board_units(pid):
		if u != null and u.data != null and u.data.troop_id != "" and not out.has(u.data.troop_id):
			out.append(u.data.troop_id)
	for c in p.graveyard:
		if c != null and c.troop_id != "" and not out.has(c.troop_id):
			out.append(c.troop_id)
	return out


## 用快照判定：`快照里的值 OP 阈值`（比较符没登记 → false，与 SV 的 default 分支一致）。
## `metric` 可以是兵种类量的**带兵种 key**（`量@兵种`，见 scope_key）：查登记表时只看 `量` 那一段。
static func met(metric: String, op: String, value: int, ctx: Dictionary) -> bool:
	_ensure()
	var base := metric
	var sep := metric.find(TROOP_SCOPE_SEP)
	if sep >= 0:
		base = metric.substr(0, sep)
	if not has_metric(base):
		return false
	var cmp: Callable = _ops.get(op, Callable())
	if not cmp.is_valid():
		return false
	return bool(cmp.call(int(ctx.get(metric, 0)), value))


## 触发时机名字（越界 → "未知时机"）
static func timing_name(timing: int) -> String:
	return TIME_NAMES[timing] if timing >= 0 and timing < TIME_NAMES.size() else "未知时机"


# ------------------------------ 老数据兼容 ------------------------------

## 旧格式的 condition（如 "hand_at_least" / "units_died_turn"）→ [metric, op]。
## 旧格式把比较符焊在 ID 里（手牌 ≥ 和 ≤ 各占一个 ID），这里按后缀拆出来；
## 拆不出来的返回空串，由 CardDB.config_errors 报出「未登记的触发条件」。
static func legacy_metric_op(old_condition: String) -> Array[String]:
	var id := old_condition.strip_edges()
	if id == "":
		return ["", ""]
	if id == "cards_played_turn":
		return ["cards_played", ">="]
	if id == "units_died_turn":
		return ["units_died", ">="]
	if id == "total_units_died":
		return ["total_units_died", ">="]
	if id.ends_with("_at_least"):
		return [id.substr(0, id.length() - "_at_least".length()), ">="]
	if id.ends_with("_at_most"):
		return [id.substr(0, id.length() - "_at_most".length()), "<="]
	return [id, default_op(id)]
