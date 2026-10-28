class_name AbilityPools
extends RefCounted
## 随机能力池（照《影之诗》「ランダムな能力」那类效果）。
##
## 一条「随机能力」效果 = 从某个池子里随机抽若干个**能力**，按抽到的顺序逐个结算。
## 池子里的每条「能力」就是一条普通效果（id / value / target / token / src / turns / cond），
## 所以「随机破坏对面随从」「随机抽牌」「随机获得护甲」都能直接配出来。
##
## 随机口径（pool.mode）：
##   repeat  可重复获得：每次独立抽，同一个能力可以被抽中多次（随机个数可以超过池子大小）；
##   unique  不可重复获得：洗牌后按顺序取，同一个能力最多出现一次（个数封顶 = 池子大小）；
##   order   随机次序触发：洗牌后取若干个（count_max = 0 表示**全部**），强调结算顺序随机。
## 随机个数：count_min ~ count_max 之间随机（count_min = count_max 就是固定个数）；
##          效果条目里的 value > 0 时以 value 为准（临时覆盖池子的个数范围）。
##
## 数据：res://data/ability_pools.json 是默认池；管理员改动写到 user://ability_pools.json。
## 这里刻意**不**静态引用 CardEffects（它反过来要用池子做卡面文本），避免循环编译依赖；
## 需要校验效果 ID 时用 load() 动态取脚本。

const DEFAULT_PATH := "res://data/ability_pools.json"
const USER_PATH := "user://ability_pools.json"
const BAK_PATH := "user://ability_pools.json.bak"

const MODE_REPEAT := "repeat"
const MODE_UNIQUE := "unique"
const MODE_ORDER := "order"
const MODE_NAMES := {
	MODE_REPEAT: "可重复获得",
	MODE_UNIQUE: "不可重复获得",
	MODE_ORDER: "随机次序触发",
}

## 个数的合理上限（超过这个数的池子没有实际意义，也防止手改 JSON 把界面拖爆）
const MAX_COUNT := 20

static var pools: Array[Dictionary] = []
static var _index: Dictionary = {}
static var _loaded := false
static var _id_regex := RegEx.create_from_string("^[a-z][a-z0-9_]*$")


# ------------------------------ 读盘 / 写盘 ------------------------------

static func _ensure() -> void:
	if not _loaded:
		load_pools()


## 读池子：优先 user://（管理员改过的），没有 / 坏了就退回 res:// 默认值。
## 坏文件先另存 .bak，绝不因为一个坏 JSON 把整份池子清空。
static func load_pools() -> void:
	_loaded = true
	pools.clear()
	_index.clear()
	var user_exists := FileAccess.file_exists(USER_PATH)
	var raw: Variant = _read_array(USER_PATH)
	if raw == null:
		if user_exists:
			# 坏存档先留证据，再用默认池启动（不要让一个手滑的 JSON 把池子清空）
			_preserve_backup()
			push_warning("[AbilityPools] 随机能力池存档损坏，已另存为 %s" % BAK_PATH)
		raw = _read_array(DEFAULT_PATH)
	if typeof(raw) == TYPE_ARRAY:
		for e in raw:
			var p := normalize(e)
			if p.is_empty() or _index.has(p["id"]):
				continue
			pools.append(p)
			_index[p["id"]] = p


static func _read_array(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if typeof(parsed) == TYPE_ARRAY else null


static func _preserve_backup() -> void:
	var src := ProjectSettings.globalize_path(USER_PATH)
	var bak := ProjectSettings.globalize_path(BAK_PATH)
	if not FileAccess.file_exists(USER_PATH):
		return
	if FileAccess.file_exists(BAK_PATH):
		DirAccess.remove_absolute(bak)
	DirAccess.rename_absolute(src, bak)


static func save_pools() -> bool:
	_ensure()
	var arr: Array = []
	for p in pools:
		arr.append(p)
	var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[AbilityPools] 无法写入：%s" % USER_PATH)
		return false
	f.store_string(JSON.stringify(arr, "\t"))
	f.close()
	return true


# ------------------------------ 查询 ------------------------------

static func all() -> Array[Dictionary]:
	_ensure()
	return pools


static func ids() -> Array[String]:
	_ensure()
	var out: Array[String] = []
	for p in pools:
		out.append(str(p.get("id", "")))
	return out


static func has(id: String) -> bool:
	_ensure()
	return _index.has(id)


static func by_id(id: String) -> Dictionary:
	_ensure()
	return _index.get(id, {})


static func pool_name(id: String) -> String:
	var p := by_id(id)
	return str(p.get("name", id)) if not p.is_empty() else id


static func mode_label(mode: String) -> String:
	return str(MODE_NAMES.get(mode, MODE_NAMES[MODE_REPEAT]))


## 顺序固定：可重复 → 不可重复 → 随机次序（界面下拉与测试都按这个顺序）
static func mode_ids() -> Array[String]:
	var out: Array[String] = [MODE_REPEAT, MODE_UNIQUE, MODE_ORDER]
	return out


static func id_valid(id: String) -> bool:
	return _id_regex != null and _id_regex.search(id) != null


# ------------------------------ 归一 / 校验 ------------------------------

static func normalize(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = raw
	var id := str(d.get("id", "")).strip_edges()
	if id == "":
		return {}
	var mode := str(d.get("mode", MODE_REPEAT))
	if not MODE_NAMES.has(mode):
		mode = MODE_REPEAT
	var lo := clampi(int(d.get("count_min", 1)), 0, MAX_COUNT)
	var hi := clampi(int(d.get("count_max", 1)), 0, MAX_COUNT)
	if hi < lo:
		hi = lo
	var abilities: Array[Dictionary] = []
	var raw_ab: Variant = d.get("abilities", [])
	if typeof(raw_ab) == TYPE_ARRAY:
		for e in raw_ab:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = e
			if str(entry.get("id", "")).strip_edges() == "":
				continue
			abilities.append(entry.duplicate(true))
	return {
		"id": id,
		"name": str(d.get("name", "")).strip_edges() if str(d.get("name", "")).strip_edges() != "" else id,
		"desc": str(d.get("desc", "")),
		"mode": mode,
		"count_min": lo,
		"count_max": hi,
		"abilities": abilities,
	}


## 池子结构自检（管理员保存 / 卡表自检共用）
static func errors(pool: Dictionary) -> Array[String]:
	var out: Array[String] = []
	if pool.is_empty():
		out.append("能力池为空")
		return out
	var mode := str(pool.get("mode", MODE_REPEAT))
	if not MODE_NAMES.has(mode):
		out.append("随机口径「%s」未登记" % mode)
	var lo := int(pool.get("count_min", 0))
	var hi := int(pool.get("count_max", 0))
	if lo < 0 or hi < 0:
		out.append("随机个数不能为负")
	if hi < lo:
		out.append("随机个数上限不能小于下限")
	var abilities: Array = pool.get("abilities", [])
	if abilities.is_empty():
		out.append("池子里一个能力都没有")
		return out
	if mode != MODE_REPEAT and lo > abilities.size():
		out.append("不可重复 / 随机次序模式下，最少个数（%d）不能超过池子大小（%d）" % [
			lo, abilities.size()])
	if mode != MODE_REPEAT and hi > abilities.size():
		out.append("不可重复 / 随机次序模式下，最多个数（%d）会被压到池子大小（%d）" % [
			hi, abilities.size()])
	var fx := _effects_script()
	for i in abilities.size():
		if typeof(abilities[i]) != TYPE_DICTIONARY:
			out.append("第 %d 个能力不是有效条目" % (i + 1))
			continue
		var e: Dictionary = abilities[i]
		var eid := str(e.get("id", ""))
		if not fx.has(eid):
			out.append("第 %d 个能力「%s」是未知效果" % [i + 1, eid])
			continue
		# 这两个 id 是 CardEffects 的稳定契约（"none" / "random_pool"），这里不通过脚本常量取，
		# 免得 AbilityPools 与 CardEffects 形成编译期的循环引用。
		if eid == "none":
			out.append("第 %d 个能力是「无效果」" % (i + 1))
		elif eid == "random_pool":
			out.append("第 %d 个能力不能再是「随机能力」（不支持嵌套，避免无限递归）" % (i + 1))
		if fx.needs_token(eid) and str(e.get("token", "")).strip_edges() == "":
			out.append("第 %d 个能力「%s」需要衍生物 ID" % [i + 1, fx.display_name(eid)])
	return out


# ------------------------------ 随机抽取 ------------------------------

## 从池子里抽一批能力（返回条目的深拷贝，按结算顺序）。
## `count_override` > 0 时覆盖池子的 count_min / count_max（效果条目的 value 用）。
static func pick(pool_id: String, count_override: int = 0) -> Array[Dictionary]:
	var pool := by_id(pool_id)
	return pick_from(pool, count_override)


static func pick_from(pool: Dictionary, count_override: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var abilities: Array = pool.get("abilities", [])
	if abilities.is_empty():
		return out
	var mode := str(pool.get("mode", MODE_REPEAT))
	var lo := int(pool.get("count_min", 1))
	var hi := int(pool.get("count_max", 1))
	if count_override > 0:
		lo = clampi(count_override, 1, MAX_COUNT)
		hi = lo
	if mode == MODE_ORDER or mode == MODE_UNIQUE:
		# 不可重复 / 随机次序：洗牌后取前 N 个。
		# 「随机次序触发」把 count_max 配成 0 = 全部能力都触发（不再随机个数）。
		var count := 0
		if mode == MODE_ORDER and hi <= 0:
			count = abilities.size()
		else:
			if hi < lo:
				hi = lo
			count = lo if hi <= lo else lo + (randi() % (hi - lo + 1))
		count = clampi(count, 0, abilities.size())
		var bag: Array = abilities.duplicate()
		for i in range(bag.size() - 1, 0, -1):
			var j := randi() % (i + 1)
			var tmp: Variant = bag[i]
			bag[i] = bag[j]
			bag[j] = tmp
		for i in count:
			out.append((bag[i] as Dictionary).duplicate(true))
		return out
	# 可重复获得：每次独立抽，同一个能力能中多次
	var count_rep := lo
	if hi > lo:
		count_rep = lo + (randi() % (hi - lo + 1))
	for _i in count_rep:
		out.append((abilities[randi() % abilities.size()] as Dictionary).duplicate(true))
	return out


# ------------------------------ 修改（管理员用） ------------------------------

static func add_pool(id: String, name: String, desc: String, mode: String,
		count_min: int, count_max: int, abilities: Array) -> bool:
	_ensure()
	if not id_valid(id) or _index.has(id):
		return false
	var p := normalize({
		"id": id, "name": name, "desc": desc, "mode": mode,
		"count_min": count_min, "count_max": count_max, "abilities": abilities,
	})
	if p.is_empty():
		return false
	pools.append(p)
	_index[id] = p
	return save_pools()


static func update_pool(id: String, name: String, desc: String, mode: String,
		count_min: int, count_max: int, abilities: Array) -> bool:
	_ensure()
	if not _index.has(id):
		return false
	var p := normalize({
		"id": id, "name": name, "desc": desc, "mode": mode,
		"count_min": count_min, "count_max": count_max, "abilities": abilities,
	})
	if p.is_empty():
		return false
	var i := pools.find(_index[id])
	if i < 0:
		return false
	pools[i] = p
	_index[id] = p
	return save_pools()


## 删除池子；引用它的卡会在 CardDB 的配置自检里报「能力池不存在」。
static func remove_pool(id: String) -> bool:
	_ensure()
	if not _index.has(id):
		return false
	var i := pools.find(_index[id])
	if i < 0:
		return false
	pools.remove_at(i)
	_index.erase(id)
	return save_pools()


## 重新从原始默认文件恢复（不碰卡表）
static func reset_pools() -> bool:
	var backup := pools.duplicate(true)
	pools.clear()
	_index.clear()
	var raw: Variant = _read_array(DEFAULT_PATH)
	if typeof(raw) != TYPE_ARRAY:
		pools = backup
		for p in pools:
			_index[p["id"]] = p
		return false
	for e in raw:
		var p := normalize(e)
		if p.is_empty() or _index.has(p["id"]):
			continue
		pools.append(p)
		_index[p["id"]] = p
	return save_pools()


# ------------------------------ 内部 ------------------------------

static func _effects_script() -> GDScript:
	return load("res://scripts/CardEffects.gd")
