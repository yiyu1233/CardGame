class_name Formats
extends RefCounted
## 对战模式表（照《影之诗》的「指定 / 无限」两种赛制）：
##
##   * **指定（rotation）**：只能用管理员勾选的**几个卡包**里的卡，另有指定模式自己的
##     卡组规则（张数 / 同名上限 / 种类上限）与限制卡表；
##   * **无限（unlimited）**：所有卡包都能用，用全局卡组规则 + 无限模式自己的限制卡表。
##
## 两个模式的规则**互不影响**：同一张卡可以在指定里被禁用、在无限里照常使用
## （限制卡表按模式分别存，见 CardDatabase.format_limits）。
##
## 这里只放「模式清单 + 名字 + 归一」，规则数据本身由 CardDatabase 持有：
## 这样规则层（CardData / 效果）不需要认识模式，界面与卡组校验只认模式 id。

const ROTATION := "rotation"
const UNLIMITED := "unlimited"

const ROTATION_NAME := "指定"
const UNLIMITED_NAME := "无限"
const ROTATION_DESC := "只能用管理员勾选的卡包里的卡（另有一套独立的张数与限制卡规则）。"
const UNLIMITED_DESC := "所有卡包都能用（用全局卡组规则，限制卡表与指定模式各自独立）。"

const DEFAULT_MODE := UNLIMITED

static var _modes: Dictionary = {}
static var _order: Array[String] = []


static func _ensure() -> void:
	if _modes.is_empty():
		_build()


static func _build() -> void:
	_reg(ROTATION, ROTATION_NAME, ROTATION_DESC)
	_reg(UNLIMITED, UNLIMITED_NAME, UNLIMITED_DESC)


static func _reg(id: String, label: String, desc: String) -> void:
	_modes[id] = {"id": id, "label": label, "desc": desc}
	_order.append(id)


static func mode_ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


static func mode_label(id: String) -> String:
	_ensure()
	return str(_modes[id]["label"]) if _modes.has(id) else id


static func mode_desc(id: String) -> String:
	_ensure()
	return str(_modes[id]["desc"]) if _modes.has(id) else ""


static func has_mode(id: String) -> bool:
	_ensure()
	return _modes.has(id)


## 空串 / 未登记的模式一律按「无限」处理（旧存档没有模式字段 = 不限卡包，行为不变）
static func normalized_mode(raw: String) -> String:
	var m := raw.strip_edges()
	return m if has_mode(m) else DEFAULT_MODE


## 是不是「指定」（只有它受卡包范围限制）
static func is_rotation(mode: String) -> bool:
	return normalized_mode(mode) == ROTATION
