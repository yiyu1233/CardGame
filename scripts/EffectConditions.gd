class_name EffectConditions
extends RefCounted
## 效果链的**条件**：每条效果可以配一个条件，满足才结算（不满足 → 跳过这一条，链继续往下走）。
##
## 模型与 InvokeConditions 同构（都照《影之诗》的 SkillCondition 拆法）：
##     条件 = 「要读的一个量」+「一个比较符」+「一个阈值」
## 唯一的区别：效果链的条件可以**指定兵种**，因为兵种类条件读的是「某个兵种」的张数，
## 所以量表里的读取函数是 `fn(gm, pid, troop) -> int`（多一个兵种参数）。
##
## 数据（存在效果链条目的 `cond` 键里，JSON 友好）：
##   {"metric": "troop_entered", "op": ">=", "value": 3, "troop": "soldier"}
##   → 「本局「士兵」进场数 ≥ 3」才结算这一条。
## 兵种 id 由管理员自己创建（CardDB.troops），所以**新建一个兵种就多一种可用条件**；
## 条件里没写兵种时按内置「中立」（CardData.NEUTRAL_TROOP）算 —— 与 CardDB.troop_of 口径一致。
##
## 拓展方式：新增一个量 = 在 `_build()` 里加一行 `_reg(...)`；
## 管理员面板的量下拉、卡面文本、保存前自检、结算判定四处会自动跟着走。
## 比较符与 InvokeConditions 完全一致（存字符串，加减比较符不会让旧卡表错位）。

const NONE := ""

# ------------------------------ 比较符 ------------------------------
## 与 InvokeConditions.OPS 同一套（存进卡表的是字符串，不是下标）
const OPS := ["<=", ">=", "=", "!=", "<", ">"]

static var _metrics: Dictionary = {}
static var _order: Array[String] = []
static var _ops: Dictionary = {}


static func _ensure() -> void:
	if _metrics.is_empty():
		_build()


static func _build() -> void:
	_ops["<="] = func(a: int, b: int) -> bool: return a <= b
	_ops[">="] = func(a: int, b: int) -> bool: return a >= b
	_ops["="] = func(a: int, b: int) -> bool: return a == b
	_ops["!="] = func(a: int, b: int) -> bool: return a != b
	_ops["<"] = func(a: int, b: int) -> bool: return a < b
	_ops[">"] = func(a: int, b: int) -> bool: return a > b

	# ---- 要读的量：全部按「兵种」统计（troop 参数由条件里的 troop 提供）----
	_reg("troop_entered", "本局该兵种进场数", ">=", func(gm, pid, troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return int(p.troop_entered_total.get(troop, 0)) if p != null else 0)
	_reg("troop_entered_turn", "本回合该兵种进场数", ">=", func(gm, pid, troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return int(p.troop_entered_turn.get(troop, 0)) if p != null else 0)
	_reg("troop_board", "我方场上该兵种数", ">=", func(gm, pid, troop) -> int:
		var n := 0
		for u in gm.board_units(pid):
			if u != null and u.data != null and u.data.troop_id == troop:
				n += 1
		return n)
	# ---- 非兵种类量：融合条件 / 通用效果条件都能用 ----
	_reg("units_left", "本局我方离场数", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.units_left_total if p != null else 0)
	_reg("units_destroyed", "本局我方被破坏数", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.units_died_total if p != null else 0)
	_reg("grave_count", "我方墓地张数", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.graveyard.size() if p != null else 0)
	_reg("grave_entered_total", "本局我方进入墓地累计", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.grave_entered_total if p != null else 0)
	_reg("troop_grave", "我方墓地该兵种数", ">=", func(gm, pid, troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		if p == null:
			return 0
		var n := 0
		for c in p.graveyard:
			if c != null and c.troop_id == troop:
				n += 1
		return n)
	# ---- 主战者 / 区域计数（照《影之诗》的条件口径，供「觉醒 / 共鸣 / 复仇」这类机制用）----
	_reg("own_hero_hp", "我方主战者生命", "<=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.hero_hp if p != null else 0)
	_reg("foe_hero_hp", "敌方主战者生命", "<=", func(gm, pid, _troop) -> int:
		var foe: PlayerState = gm.get_foe(pid)
		return foe.hero_hp if foe != null else 0)
	_reg("hero_max_hp", "我方主战者生命上限", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.hero_max_hp if p != null else 0)
	_reg("deck_count", "我方牌库张数", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.deck.size() if p != null else 0)
	_reg("hand_count", "我方手牌张数", ">=", func(gm, pid, _troop) -> int:
		var p: PlayerState = gm.get_player(pid)
		return p.hand.size() if p != null else 0)
	_reg("board_count", "我方场上单位数", ">=", func(gm, pid, _troop) -> int:
		return gm.board_size_used(pid))


## 注册一个「可读的量」：`fn(gm, pid, troop) -> int`
static func _reg(id: String, label: String, default_op: String, fn: Callable) -> void:
	_metrics[id] = {"id": id, "label": label, "op": default_op, "read": fn}
	_order.append(id)


# ------------------------------ 查询 ------------------------------

static func metrics() -> Array[String]:
	_ensure()
	return _order.duplicate()


static func has_metric(id: String) -> bool:
	_ensure()
	return id != "" and _metrics.has(id)


static func metric_label(id: String) -> String:
	_ensure()
	return str(_metrics[id]["label"]) if has_metric(id) else id


## 这个量要不要看「兵种」（只有 troop_* 开头的兵种类量才用得上）
static func metric_wants_troop(id: String) -> bool:
	return id.begins_with("troop_")


## 新建条件时给的默认比较符（「张数」类默认 ≥）
static func default_op(metric: String) -> String:
	_ensure()
	return str(_metrics[metric]["op"]) if has_metric(metric) else ">="


static func has_op(op: String) -> bool:
	_ensure()
	return _ops.has(op)


## 卡面上的比较符写法：数据存 ASCII（<= >= !=），显示成 ≤ ≥ ≠
static func op_symbol(op: String) -> String:
	match op:
		"<=":
			return "≤"
		">=":
			return "≥"
		"!=":
			return "≠"
	return op


## 空条件 = 没有条件 = 永远满足（老卡表 / 没配条件的条目都走这条）
static func is_empty(cond: Dictionary) -> bool:
	return cond.is_empty() or str(cond.get("metric", "")) == ""


## 卡面 / 日志文本：「本局该兵种进场数「士兵」≥ 3」；坏条件返回空串
static func text(cond: Dictionary) -> String:
	_ensure()
	var metric := str(cond.get("metric", ""))
	if not has_metric(metric):
		return ""
	var op := str(cond.get("op", ""))
	if not has_op(op):
		return ""
	var troop := str(cond.get("troop", ""))
	return "%s「%s」%s %d" % [
		metric_label(metric), _troop_label(troop), op_symbol(op), int(cond.get("value", 0))]


## 兵种的显示名：运行时去场景树根上找 CardDB（**不要**在这里写 CardDB 全局名 ——
## CardDatabase.gd 依赖本脚本，写成全局名会变成循环编译，--script 模式下直接编译失败）
static func _troop_label(troop: String) -> String:
	return CardData.troop_label(troop)          # 没填 = 中立兵种（CardData 里统一处理）


## 判定：`该兵种的量 OP 阈值`。
## 坏条件（未知量 / 未选兵种 / 比较符无效）一律**不满足** —— 宁可这条效果不结算，
## 也不要把管理员配错的条件当成「无条件」悄悄放出去。
static func met(gm, pid: int, cond: Dictionary) -> bool:
	_ensure()
	if is_empty(cond):
		return true
	if gm == null:
		return false
	var metric := str(cond.get("metric", ""))
	if not has_metric(metric):
		return false
	# 没填兵种 = 内置「中立」兵种（与 CardDB.troop_of 同一口径：任何卡都属于某个兵种）
	var troop := str(cond.get("troop", ""))
	if troop == "":
		troop = CardData.NEUTRAL_TROOP
	var cmp: Callable = _ops.get(str(cond.get("op", "")), Callable())
	if not cmp.is_valid():
		return false
	var read: Callable = _metrics[metric]["read"]
	return bool(cmp.call(int(read.call(gm, pid, troop)), int(cond.get("value", 0))))


## 读卡表时的安全归一：只保留认识的键 + 统一类型；非字典 / 没有量 → 空条件
static func normalized(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var src: Dictionary = raw
	var metric := str(src.get("metric", "")).strip_edges()
	if metric == "":
		return {}
	# 没写兵种 → 默认「中立兵种」（老卡表里手写的条件、或者管理员没动过兵种下拉）
	var troop := str(src.get("troop", "")).strip_edges()
	return {
		"metric": metric,
		"op": str(src.get("op", ">=")).strip_edges(),
		"value": int(src.get("value", 0)),
		"troop": troop if troop != "" else CardData.NEUTRAL_TROOP,
	}


## 结构自检（兵种是否存在由调用方查 —— 数据层不该反过来依赖 CardDB 的私有索引）
static func errors(cond: Dictionary) -> Array[String]:
	_ensure()
	var out: Array[String] = []
	if is_empty(cond):
		return out
	var metric := str(cond.get("metric", ""))
	if not has_metric(metric):
		out.append("条件里的量 %s 未登记（可用：%s）" % [metric, "、".join(metrics())])
	var troop := str(cond.get("troop", ""))
	if troop == "":
		out.append("兵种类条件没有选择兵种")
	var op := str(cond.get("op", ""))
	if not has_op(op):
		out.append("条件的比较符 %s 无效（可用：%s）" % [op, " / ".join(OPS)])
	if int(cond.get("value", 0)) < 0:
		out.append("条件的阈值不能为负")
	return out
