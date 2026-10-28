extends Node
## 卡牌语音库（自动加载单例 `Voice`）—— **外部插入卡牌语音的唯一入口**。
##
## ============================ 放素材就能用（只改文件名，不改代码） ============================
## 支持三种来源，按下面的优先级叠加（靠后的覆盖靠前的）：
##
##   ① **显式映射** `data/voice_map.json` 或 `user://voice_map.json`
##      形如：{ "c111": { "play": "res://.../a.wav", "attack": "res://.../b.wav" } }
##      也支持简写：{ "c111": "res://.../任意.wav" }（所有事件都用它）
##
##   ② **按卡 id 的目录**：`<某素材目录>/<卡 id>/<事件>*.wav`
##      默认素材目录（可用 `add_card_dir()` 追加，扩展包就是这么挂进来的）：
##        * `res://assets/art/voice/card`   —— 自备素材（优先级最高）
##        * `res://assets/sv/voice/card`    —— 逆向导入素材
##      例：`assets/art/voice/card/c111/play.wav`、`.../c111/attack_01.wav`、`.../c111/attack_02.wav`
##      （同一事件有多个文件时**随机**挑一个，同一条事件连续播放不会永远是同一句）。
##
##   ③ **全局事件音**：上面都没有时，回落到 `SoundFx.play(事件名)`（合成音 / 全局素材）。
##
## 事件名（`CardVoice.EVENTS`）：play / attack / death / skill / summon / turn / win / lose / damage。
## WAV 免 `.import`（`AudioStreamWAV.load_from_file` 兜底），拷进去就能播。
##
## 开关：跟随 `GameSettings.card_voice`（设置面板「卡牌语音」），关闭时只记调用次数、不发声。
## =======================================================================================

const EVENTS: Array[String] = [
	"play",     ## 从手牌打出
	"summon",   ## 被召唤 / 生成上场（战吼与瞬念召唤）
	"attack",   ## 发起攻击
	"death",    ## 被破坏 / 死亡
	"skill",    ## 发动主动技能
	"damage",   ## 受到伤害
	"turn",     ## 自己回合开始
	"win",      ## 本局胜利（主战者）
	"lose",     ## 本局失败（主战者）
]
## 默认素材目录（按顺序扫描，靠后的同名事件覆盖靠前的）
const DEFAULT_CARD_DIRS: Array[String] = [
	"res://assets/sv/voice/card",
	"res://assets/art/voice/card",
]
const MAP_PATHS: Array[String] = ["res://data/voice_map.json", "user://voice_map.json"]
const EXT := ".wav"
const POOL_SIZE := 4

var enabled := true
## 只读计数（测试 / 调试）：请求次数、真正发声次数
var play_count := 0
var sample_plays := 0

var _card_dirs: Array[String] = DEFAULT_CARD_DIRS.duplicate()
## (卡 id, 事件) → PackedStringArray 候选文件；只扫一次
var _candidates: Dictionary = {}
## 卡 id → { 事件: 路径 }（来自 voice_map.json）
var _map: Dictionary = {}
var _cache: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
	_bind_settings()
	load_map()


# ============================== 配置 ==============================

## 追加一个「按卡 id 的目录」素材根并清缓存（扩展包 / 自备素材用）
func add_card_dir(dir: String) -> void:
	var d := dir.strip_edges().trim_suffix("/")
	if d == "" or _card_dirs.has(d):
		return
	_card_dirs.append(d)
	_candidates.clear()


func card_dirs() -> Array[String]:
	return _card_dirs.duplicate()


## 设置开关（手动覆盖后不再跟随 GameSettings；测试用）
func set_enabled(v: bool) -> void:
	enabled = v


func is_enabled() -> bool:
	return enabled


## 读 `data/voice_map.json` / `user://voice_map.json`
func load_map() -> int:
	_map.clear()
	for path in MAP_PATHS:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		_merge_map(parsed)
	return _map.size()


## 合并一份「卡 id → 事件 → 路径」映射（扩展包用；不落盘）
func merge_map(parsed: Variant) -> void:
	_merge_map(parsed)


func _merge_map(parsed: Variant) -> void:
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for k in parsed.keys():
		var entry: Variant = parsed[k]
		if typeof(entry) == TYPE_STRING:
			_map[str(k)] = {"*": str(entry)}
		elif typeof(entry) == TYPE_DICTIONARY:
			var d: Dictionary = _map.get(str(k), {})
			for ev in entry.keys():
				d[str(ev)] = str(entry[ev])
			_map[str(k)] = d


# ============================== 查询 ==============================

## 这张卡在这个事件上有没有语音（不触发播放）
func has_voice(card_id: String, event: String) -> bool:
	return voice_path(card_id, event) != ""


## 找这张卡这个事件的语音文件路径；找不到返回空串
func voice_path(card_id: String, event: String) -> String:
	var id := card_id.strip_edges()
	if id == "":
		return ""
	# ① 显式映射
	var m: Dictionary = _map.get(id, {})
	if m.has(event) and ResourceLoader.exists(str(m[event])):
		return str(m[event])
	if m.has("*") and ResourceLoader.exists(str(m["*"])):
		return str(m["*"])
	# ② 按卡 id 的目录
	var cand := candidates(id, event)
	if not cand.is_empty():
		return cand[randi() % cand.size()]
	return ""


## 这张卡这个事件的全部候选文件（按目录顺序；`<id>/<event>.wav` 与 `<id>/<event>_*.wav`）
func candidates(card_id: String, event: String) -> PackedStringArray:
	var key := "%s|%s" % [card_id, event]
	if _candidates.has(key):
		return _candidates[key]
	var out := PackedStringArray()
	for dir in _card_dirs:
		var base := "%s/%s" % [dir, card_id]
		var exact := "%s/%s%s" % [base, event, EXT]
		if FileAccess.file_exists(exact) and not out.has(exact):
			out.append(exact)
		var d := DirAccess.open(base)
		if d == null:
			continue
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			var lower := f.to_lower()
			if not d.current_is_dir() and not f.begins_with(".") and lower.ends_with(EXT):
				var stem := f.get_basename()
				var full := "%s/%s" % [base, f]
				if (stem == event or stem.begins_with(event + "_")) and not out.has(full):
					out.append(full)
			f = d.get_next()
		d.list_dir_end()
	_candidates[key] = out
	return out


# ============================== 播放 ==============================

## 播放卡牌语音。没有对应语音时返回 false（调用方可以决定要不要回落到通用音效）。
func play(card_id: String, event: String) -> bool:
	play_count += 1
	if not enabled or card_id == "" or event == "":
		return false
	var path := voice_path(card_id, event)
	if path == "":
		return false
	var stream: AudioStream = _load(path)
	if stream == null:
		return false
	if _pool.is_empty():
		_build_pool()
	var p := _take_player()
	if p == null:
		return false
	p.stream = stream
	p.play()
	sample_plays += 1
	return true


## 卡牌语音优先；没有就走通用音效 `SoundFx.play(fallback_event)`。
## 返回 true 表示这次由卡牌语音发声（false = 用了通用音效或静音）。
func play_or(event: String, card_id: String, fallback_event: String = "") -> bool:
	if play(card_id, event):
		return true
	if fallback_event != "":
		var fx := get_node_or_null("/root/SoundFx")
		if fx != null and fx.has_method("play"):
			fx.play(fallback_event)
	return false


func stop_all() -> void:
	for p in _pool:
		if p != null and p.playing:
			p.stop()


# ============================== 内部 ==============================

func _build_pool() -> void:
	if not _pool.is_empty():
		return
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "Voice%d" % i
		add_child(p)
		_pool.append(p)


func _take_player() -> AudioStreamPlayer:
	if _pool.is_empty():
		return null
	for p in _pool:
		if p != null and not p.playing:
			return p                # 优先挑空闲的，全忙时轮转覆盖
	_next = (_next + 1) % _pool.size()
	return _pool[_next]


func _load(path: String) -> AudioStream:
	if _cache.has(path):
		return _cache[path]
	var res: Variant = load(path) if ResourceLoader.exists(path) else null
	if not (res is AudioStream):
		res = AudioStreamWAV.load_from_file(path)
	_cache[path] = res
	return res if res is AudioStream else null


func _bind_settings() -> void:
	var settings = get_node_or_null("/root/GameSettings")
	if settings == null and is_inside_tree():
		settings = get_tree().root.get_node_or_null("GameSettings")
	if settings == null:
		return
	if "card_voice" in settings:
		var v = settings.card_voice
		if typeof(v) == TYPE_BOOL:
			enabled = v
	if settings.has_signal("changed"):
		var cb := Callable(self, "_on_settings_changed")
		if not settings.is_connected("changed", cb):
			settings.changed.connect(cb)


func _on_settings_changed() -> void:
	var settings = get_node_or_null("/root/GameSettings")
	if settings == null or not ("card_voice" in settings):
		return
	var v = settings.card_voice
	if typeof(v) == TYPE_BOOL:
		enabled = v
		if not enabled:
			stop_all()
