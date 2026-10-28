extends Node
## 扩展包加载器（自动加载单例 `Mods`）—— **从外部给游戏加东西的唯一入口**。
##
## ============================ 怎么加一个扩展包 ============================
## 在 `res://mods/<包名>/` 或 `user://mods/<包名>/` 下放一个 `mod.json` 即可，
## 游戏启动时会自动扫描并装载（无需改任何代码、无需重新导出）：
##
##   {
##     "id": "example",              # 必填：唯一 id（重复时靠后的覆盖靠前的）
##     "name": "示例扩展包",          # 显示名
##     "version": "1.0",
##     "enabled": true,              # 可省略，默认 true；false = 临时禁用
##     "cards": ["cards.json"],                        # 追加 / 覆盖卡牌（CardData 的 JSON 数组）
##     "mechanics": ["mechanics.gd"],                  # 注册机制 / 效果的脚本
##     "mechanic_defs": [                              # 免代码的「声明式机制」（只有标志位那种）
##       {"key":"awaken","name":"觉醒","desc":"…","flags":[]}
##     ],
##     "vfx": [{"id":"star","name":"星辰","color":"#7dd3fc"}],   # 追加出牌特效
##     "voice_dirs": ["voice"],              # 追加通用音效目录（文件名 = 事件名）
##     "card_voice_dirs": ["card_voice"],    # 追加卡牌语音目录（<卡 id>/<事件>*.wav）
##     "voice_map": "voice_map.json",        # 追加「卡 id → 事件 → 路径」映射
##     "card_art_dir": "card_art",           # 追加卡图目录（<卡 id>.png）
##     "card_back": "card_back.png",         # 指定卡背贴图
##     "background": "bg.png"                # 指定竞技区背景
##   }
##
## 目录里的**相对路径**都相对该 `mod.json` 所在目录解析；文件缺失只会跳过并记一条日志，
## 不会影响游戏运行。`report()` 返回加载结果，`tools/ext_arch_test.gd` 用它做断言。
##
## 脚本契约（`mechanics` 里的每个 .gd）：继承 `RefCounted`，实现
##   `func register(mod: Node) -> void:`（优先）或 `func _register() -> void:`
## 在里面调用下面这些 helper（或直接调 `CardData` / `Mechanics` / `CardEffects`）：
##   * `mod.register_mechanic(id, name, key, desc, hooks, flags)`  —— 登记一个机制（关键字）
##   * `mod.register_effect(...)`                                  —— 登记一条卡牌效果
##   * `CardData.register_keyword(id, name, key)`                  —— 只登记名字 / key
## 例见 `mods/example/mechanics.gd`。
## ====================================================================

const ROOTS: Array[String] = ["res://mods", "user://mods"]
const MANIFEST := "mod.json"

## 只读计数（测试 / 调试）
var loaded_count := 0
var card_count := 0
var mechanic_count := 0
var effect_count := 0
var vfx_count := 0
var voice_count := 0
## 装载完成标志：CardDB 的卡表自检等它，避免把扩展包登记的效果误报成未知效果
var ready_done := false

var _mods: Array[Dictionary] = []
var _next_keyword_id := 0
## 已实例化的扩展包脚本对象：**必须留着引用**，否则 RefCounted 会被回收，
## 脚本里注册的 Callable（效果函数 / 钩子）就变成「null::func」调用而报错。
var _script_objects: Array = []


func _ready() -> void:
	load_all()


# ============================== 扫描 / 装载 ==============================

## 扫描全部扩展包根目录并装载（可重复调用：先清空再重载）
func load_all() -> Array[String]:
	_next_keyword_id = CardData.MOD_KEYWORD_BASE
	ready_done = false
	var names := _discover()
	var report_lines: Array[String] = []
	for dir in names:
		var m := _load_one(dir)
		if m.is_empty():
			continue
		_mods.append(m)
		report_lines.append("[Mods] 装载扩展包「%s」(%s) ← %s" % [
			str(m.get("name", m.get("id", ""))), str(m.get("id", "")), dir])
	loaded_count = _mods.size()
	ready_done = true
	print("[Mods] 共装载 %d 个扩展包：%d 张卡 / %d 个机制 / %d 条效果 / %d 个特效 / %d 个语音目录" % [
		loaded_count, card_count, mechanic_count, effect_count, vfx_count, voice_count])
	# 扩展包登记完效果 / 机制之后，再让 CardDB 自检一次（这时才不会误报）
	var db := get_node_or_null("/root/CardDB")
	if db != null and db.has_method("warn_config_errors"):
		db.call("warn_config_errors")
	return report_lines


func mods() -> Array[Dictionary]:
	return _mods.duplicate()


func report() -> Dictionary:
	return {
		"mods": loaded_count,
		"cards": card_count,
		"mechanics": mechanic_count,
		"effects": effect_count,
		"vfx": vfx_count,
		"voices": voice_count,
		"ids": _mods.map(func(m): return str(m.get("id", ""))),
	}


## 发现所有扩展包目录（先 res:// 后 user://，按目录名排序；重复 id 由 `_load_one` 覆盖）
func _discover() -> Array[String]:
	var out: Array[String] = []
	for root in ROOTS:
		var d := DirAccess.open(root)
		if d == null:
			continue
		var subs: Array[String] = []
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if d.current_is_dir() and not f.begins_with(".") and f != "_template":
				subs.append(f)
			f = d.get_next()
		d.list_dir_end()
		subs.sort()
		for s in subs:
			if FileAccess.file_exists("%s/%s/%s" % [root, s, MANIFEST]):
				out.append("%s/%s" % [root, s])
	return out


func _load_one(dir: String) -> Dictionary:
	var parsed: Variant = _read_json("%s/%s" % [dir, MANIFEST])
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Mods] 扩展包清单无法解析，已跳过：%s" % dir)
		return {}
	var man: Dictionary = parsed
	if man.has("enabled") and not bool(man.get("enabled", true)):
		print("[Mods] 扩展包已禁用：%s" % dir)
		return {}
	var id := str(man.get("id", ""))
	if id == "":
		push_warning("[Mods] 扩展包缺少 id，已跳过：%s" % dir)
		return {}
	man["dir"] = dir
	# 重复 id：后发现的（user:// 优先）替换先发现的，并把它移到末尾（后到者覆盖）
	for i in range(_mods.size() - 1, -1, -1):
		if str(_mods[i].get("id", "")) == id:
			_mods.remove_at(i)
	_apply_manifest(man)
	return man


## 按清单把各类内容接进游戏
func _apply_manifest(man: Dictionary) -> void:
	var dir := str(man["dir"])
	# ---- 特效 ----
	for v in _as_array(man.get("vfx", [])):
		if typeof(v) != TYPE_DICTIONARY:
			continue
		ArtStore.register_vfx(str(v.get("id", "")), str(v.get("name", "")), str(v.get("color", "")))
		vfx_count += 1
	# ---- 机制：声明式（免代码） ----
	for m in _as_array(man.get("mechanic_defs", [])):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		register_mechanic(
			int(m.get("id", 0)), str(m.get("name", "")), str(m.get("key", "")),
			str(m.get("desc", "")), {}, _as_array(m.get("flags", [])))
	# ---- 机制 / 效果：脚本 ----
	for rel in _as_array(man.get("mechanics", [])):
		_load_script("%s/%s" % [dir, str(rel)])
	# ---- 卡牌 ----
	var card_items: Array = []
	for rel in _as_array(man.get("cards", [])):
		var arr: Variant = _read_json("%s/%s" % [dir, str(rel)])
		if typeof(arr) == TYPE_ARRAY:
			card_items.append_array(arr)
		else:
			push_warning("[Mods] 卡牌文件无法解析，已跳过：%s/%s" % [dir, str(rel)])
	if not card_items.is_empty():
		# 合并进 CardDB 已有的扩展包卡牌（多个扩展包各自追加，后到的 id 覆盖先到的）
		var merged: Array = _mod_cards_snapshot()
		merged.append_array(card_items)
		var db := get_node_or_null("/root/CardDB")
		if db != null:
			card_count = db.set_mod_cards(merged)
		else:
			card_count = merged.size()
	# ---- 美术 ----
	if man.has("card_art_dir"):
		ArtStore.add_card_art_dir("%s/%s" % [dir, str(man["card_art_dir"])])
	if man.has("card_back"):
		ArtStore.set_card_back("%s/%s" % [dir, str(man["card_back"])])
	if man.has("background"):
		ArtStore.set_background_path("%s/%s" % [dir, str(man["background"])])
	# ---- 语音 ----
	var voice_dirs: Array = []
	for rel in _as_array(man.get("voice_dirs", [])):
		voice_dirs.append("%s/%s" % [dir, str(rel)])
	if not voice_dirs.is_empty():
		var fx := get_node_or_null("/root/SoundFx")
		if fx != null and fx.has_method("append_sample_dirs"):
			fx.append_sample_dirs(voice_dirs)
		voice_count += voice_dirs.size()
	var card_voice_dirs: Array = []
	for rel in _as_array(man.get("card_voice_dirs", [])):
		card_voice_dirs.append("%s/%s" % [dir, str(rel)])
	var voice := get_node_or_null("/root/Voice")
	if voice != null:
		for d in card_voice_dirs:
			voice.add_card_dir(d)
		if man.has("voice_map"):
			voice.merge_map(_read_json("%s/%s" % [dir, str(man["voice_map"])]))
		voice_count += card_voice_dirs.size()


func _load_script(path: String) -> void:
	if not ResourceLoader.exists(path):
		push_warning("[Mods] 机制脚本不存在，已跳过：%s" % path)
		return
	var script: Variant = load(path)
	if script == null or not (script is GDScript):
		push_warning("[Mods] 机制脚本不是 GDScript，已跳过：%s" % path)
		return
	var obj: Object = (script as GDScript).new()
	if obj == null:
		push_warning("[Mods] 机制脚本无法实例化：%s" % path)
		return
	if obj.has_method("register"):
		obj.call("register", self)
	elif obj.has_method("_register"):
		obj.call("_register")
	else:
		push_warning("[Mods] 机制脚本缺少 register()/_register()：%s" % path)
		return
	_script_objects.append(obj)


# ============================== 给扩展包脚本用的 helper ==============================

## 登记一个机制（关键字）。id = 0 时自动分配（从 `CardData.MOD_KEYWORD_BASE` 起递增）。
## 返回真正使用的 id（把它写进卡表的 `keywords` 即可生效）。
func register_mechanic(id: int, name: String, key: String, desc: String,
		hooks: Dictionary = {}, flags: Array = []) -> int:
	var kid := id
	if kid <= 0:
		_next_keyword_id += 1
		kid = _next_keyword_id
	CardData.register_keyword(kid, name, key)
	Mechanics.register(kid, name, desc, hooks, flags)
	mechanic_count += 1
	return kid


## 下一个可用的自动机制 id（扩展包想手动挑 id 时可用）
func next_keyword_id() -> int:
	_next_keyword_id += 1
	return _next_keyword_id


## 登记一条卡牌效果（参数与 `CardEffects._reg` 一致；`fn` 是扩展包脚本里的 `Callable`）
func register_effect(id: String, display: String, text_tpl: String, default_target: int,
		fn: Callable, hint: String = "") -> void:
	CardEffects.register(id, display, text_tpl, default_target, fn, hint)
	effect_count += 1


# ============================== 内部工具 ==============================

func _has_carddb() -> bool:
	return get_node_or_null("/root/CardDB") != null


func _mod_cards_snapshot() -> Array:
	var db := get_node_or_null("/root/CardDB")
	if db == null:
		return []
	var existing: Variant = db.get("_mod_cards")
	if typeof(existing) != TYPE_ARRAY:
		return []
	# 逐项拷进**无类型**数组：CardDB 里那份是 Array[CardData]，
	# 直接 append 新的字典条目会被类型校验拦下（Dictionary 不是 CardData）。
	var out: Array = []
	for c in (existing as Array):
		out.append(c)
	return out


static func _as_array(v: Variant) -> Array:
	if v == null:
		return []
	if typeof(v) == TYPE_ARRAY:
		return v
	return [v]


func _read_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed
