extends Node
## 游戏设置（自动加载为 GameSettings）：界面、窗口、联机与音效偏好，持久化到 user://settings.cfg
##
## 约定：
##   * 读档时缺失的键保持当前值（首次加载即内置默认值），类型不符一律回退；
##   * 所有数值在上限 / 下限处夹紧（clamp），磁盘里出现越界值也不会影响运行；
##   * 每项都有 setter，对话框改完调 save_settings() 落盘并 emit changed()。

signal changed()

const SAVE_PATH := "user://settings.cfg"

## 手牌扇形角度的取值范围 / 默认值（设置窗口的滑块与此共用，避免两边漂移）
const FAN_ANGLE_MIN := 0.0
const FAN_ANGLE_MAX := 40.0
const FAN_ANGLE_DEFAULT := 30.0

# ------------------------------ 新增：合法档位表 ------------------------------
## 允许的分辨率（只收常见档位：project 基准 1440x900 加各类主流 16:9 / 16:10 / 21:9）；
## 存档里出现表外的分辨率时，吸附到最接近的一档，而不是照单全收。
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1440, 900),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(1920, 1200),
	Vector2i(2560, 1080),
	Vector2i(2560, 1440),
]

## 窗口模式档位（与 apply_window_mode() 的入参一一对应）
const WINDOW_MODE_WINDOWED := 0   ## 窗口
const WINDOW_MODE_FULLSCREEN := 1 ## 全屏（独占）
const WINDOW_MODE_BORDERLESS := 2 ## 无边框（全屏窗口）
const WINDOW_MODE_NAMES: Array[String] = ["窗口", "全屏", "无边框"]
const WINDOW_MODE_MIN := 0
const WINDOW_MODE_MAX := 2

## AI 难度档位（0 稳健 / 1 普通 / 2 置锋，由 EnemyAI 接线时自行解释）
const AI_DIFFICULTY_SAFE := 0
const AI_DIFFICULTY_NORMAL := 1
const AI_DIFFICULTY_AGGRESSIVE := 2
const AI_DIFFICULTY_NAMES: Array[String] = ["稳健", "普通", "置锋"]
const AI_DIFFICULTY_MIN := 0
const AI_DIFFICULTY_MAX := 2

## 动画速度倍率：1.0 为正常速度；0 是**约定值**，表示「立即完成」（跳过 / 瞬间到位），
## 其余取值夹紧到 [ANIM_SPEED_MIN, ANIM_SPEED_MAX]（即 0 与 0.5–3.0 之间没有其余合法值，
## 0.2 之类会夹到 0.5，0.001 以内当作「立即完成」）。
const ANIM_SPEED_INSTANT := 0.0
const ANIM_SPEED_MIN := 0.5
const ANIM_SPEED_MAX := 3.0
const ANIM_SPEED_DEFAULT := 1.0
const ANIM_SPEED_ZERO_EPSILON := 0.001

## 联机端口合法范围（1024 以下是特权端口）
const NET_PORT_MIN := 1024
const NET_PORT_MAX := 65535
const NET_PORT_DEFAULT := 27015

## 玩家名兜底（环境变量取不到时使用）
const PLAYER_NAME_FALLBACK := "玩家"
const PLAYER_NAME_MAX_LENGTH := 16

# ------------------------------ 当前设置 ------------------------------
var hover_detail := true       ## 悬停卡牌 / 随从时显示完整效果
var show_enemy_hand := true    ## 敌方手牌显示为卡背（关闭时只显示张数）
var confirm_end_turn := true   ## 仍有法力或可攻击随从时，结束回合弹出二次确认
var sound_enabled := true      ## 音效开关（SoundFx.gd 读这个字段）
var card_voice := true         ## 卡牌语音开关（CardVoice.gd 读这个字段）

var player_name := _default_player_name()   ## 玩家名（对局 / 日志 / 联机显示用）

## 玩家在主页选中的主战者职业 id（CardDB.hero_classes 里的 id；"" = 还没选）。
## 组卡界面拿它当默认职业，每个玩家自行挑选。
var selected_class := ""

## 玩家当前出战的卡组 id（CardDB.player_decks 里的 id；"" = 还没组，禁止开局）。
## 由 GameManager.new_game() 读取；id 失效（被删 / 卡组被清空）时那边会自动回落到全卡牌组。
var selected_deck := ""

## 玩家当前的对战模式（Formats.ROTATION 指定 / Formats.UNLIMITED 无限）：
## 主页与组卡界面共用；GameManager.new_game() 按它决定卡包范围与限制卡表。
## 空串 / 未登记的值一律归一成「无限」（旧存档没有这个键 = 老行为，所有卡都能用）。
var selected_mode := Formats.UNLIMITED

## 存档路径（可用 use_save_path() 临时改写；测试必须改写到 user://test_*.cfg，
## 绝不能覆盖玩家真实的 settings.cfg）
var save_path := SAVE_PATH

# 带 setter 的字段用显式后备变量：默认值写在声明处，赋值时统一夹紧到合法档位。
var _fan_angle: float = FAN_ANGLE_DEFAULT
var _net_port: int = NET_PORT_DEFAULT
var _window_mode: int = WINDOW_MODE_WINDOWED
var _ai_difficulty: int = AI_DIFFICULTY_NORMAL
var _anim_speed: float = ANIM_SPEED_DEFAULT
var _resolution: Vector2i = default_resolution()

var fan_angle: float:                        ## 手牌扇形最大展开角度（度，0 为平铺）
	get:
		return _fan_angle
	set(value):
		_fan_angle = clampf(float(value), FAN_ANGLE_MIN, FAN_ANGLE_MAX)

var net_port: int:                           ## 联机端口（1024–65535）
	get:
		return _net_port
	set(value):
		_net_port = clampi(int(value), NET_PORT_MIN, NET_PORT_MAX)

var window_mode: int:                        ## 0 窗口 / 1 全屏 / 2 无边框
	get:
		return _window_mode
	set(value):
		_window_mode = clampi(int(value), WINDOW_MODE_MIN, WINDOW_MODE_MAX)

var ai_difficulty: int:                      ## 0 稳健 / 1 普通 / 2 置锋
	get:
		return _ai_difficulty
	set(value):
		_ai_difficulty = clampi(int(value), AI_DIFFICULTY_MIN, AI_DIFFICULTY_MAX)

var anim_speed: float:                       ## 动画速度倍率（0 = 立即完成，见 ANIM_SPEED_* 注释）
	get:
		return _anim_speed
	set(value):
		# 0（含 0.001 以内的抖动）= 立即完成，其余夹紧到 0.5–3.0
		var v := float(value)
		if absf(v) < ANIM_SPEED_ZERO_EPSILON:
			_anim_speed = ANIM_SPEED_INSTANT
		else:
			_anim_speed = clampf(v, ANIM_SPEED_MIN, ANIM_SPEED_MAX)

var resolution: Vector2i:                    ## 窗口分辨率，只允许 RESOLUTIONS 里的档位
	get:
		return _resolution
	set(value):
		_resolution = snap_resolution(value)


func _ready() -> void:
	UiSkin.apply_global_font()      # 全局中文字体（来自游戏数据包，缺失则回落）
	var sfx := get_node_or_null("/root/SoundFx")
	if sfx != null and sfx.has_method("load_samples"):
		sfx.load_samples()          # 真实语音/音效（来自逆向素材；缺失则该事件仍用合成音）
	load_settings()


# ------------------------------ 默认值 ------------------------------
## 玩家名默认取系统用户名（Windows 下是 USERNAME），取不到就用「玩家」
static func _default_player_name() -> String:
	var n := OS.get_environment("USERNAME").strip_edges()
	if n.is_empty():
		n = OS.get_environment("USER").strip_edges()
	if n.is_empty():
		return PLAYER_NAME_FALLBACK
	return n


## 各字段默认值（对话框的「恢复默认」与测试共用同一来源）
static func default_player_name() -> String:
	return _default_player_name()


## 默认分辨率取 project 设置里的 viewport 尺寸；只有在 RESOLUTIONS 档位表里才照用，
## 否则退回表里最接近的一档（保证默认值本身一定合法）。
static func default_resolution() -> Vector2i:
	var base := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 720)))
	if base.x > 0 and base.y > 0 and RESOLUTIONS.has(base):
		return base
	return snap_resolution(base)


## 把任意分辨率吸附到 RESOLUTIONS 里最接近的一档（表外 / 非法值都不会漏出去）
static func snap_resolution(value: Vector2i) -> Vector2i:
	if RESOLUTIONS.is_empty():
		return value
	if RESOLUTIONS.has(value):
		return value
	var best: Vector2i = RESOLUTIONS[0]
	var best_d := -1
	for option in RESOLUTIONS:
		var d: int = (value - option).length_squared()
		if best_d < 0 or d < best_d:
			best_d = d
			best = option
	return best


## "1920x1080"（存档 / 外部工具交换用的规范写法）
static func resolution_to_string(res: Vector2i) -> String:
	return "%dx%d" % [res.x, res.y]


## 解析 "1920x1080" / "1920*1080" / "1920 1080"，认不出来时返回 fallback
static func parse_resolution(text: String, fallback: Vector2i) -> Vector2i:
	var parts: PackedStringArray = text.to_lower().replace("*", "x").replace(" ", "").split("x")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return fallback
	var w: int = int(parts[0])
	var h: int = int(parts[1])
	if w <= 0 or h <= 0:
		return fallback
	return snap_resolution(Vector2i(w, h))


# ------------------------------ 读 / 写 ------------------------------
## persist=false 只把改动应用到当前会话（拖动滑块的中间过程不必每一步都写磁盘）
func save_settings(persist: bool = true) -> void:
	if persist:
		var cfg := ConfigFile.new()
		cfg.set_value("game", "hover_detail", hover_detail)
		cfg.set_value("game", "show_enemy_hand", show_enemy_hand)
		cfg.set_value("game", "confirm_end_turn", confirm_end_turn)
		cfg.set_value("game", "fan_angle", fan_angle)
		cfg.set_value("game", "player_name", player_name)
		cfg.set_value("game", "window_mode", window_mode)
		cfg.set_value("game", "resolution", resolution_to_string(resolution))
		cfg.set_value("game", "net_port", net_port)
		cfg.set_value("game", "anim_speed", anim_speed)
		cfg.set_value("game", "ai_difficulty", ai_difficulty)
		cfg.set_value("game", "sound_enabled", sound_enabled)
		cfg.set_value("game", "card_voice", card_voice)
		cfg.set_value("game", "selected_deck", selected_deck)
		cfg.set_value("game", "selected_class", selected_class)
		cfg.set_value("game", "selected_mode", selected_mode)
		var err := cfg.save(save_path)
		if err != OK:
			push_warning("[GameSettings] 设置保存失败：%s（错误码 %d）" % [save_path, err])
	changed.emit()


## 读档：文件不存在 / 读不出来时保持当前值（首次加载即内置默认值）；
## 类型不符回退到「当前值」，数值越界一律夹紧。
func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		return
	hover_detail = _read_bool(cfg, "hover_detail", hover_detail)
	show_enemy_hand = _read_bool(cfg, "show_enemy_hand", show_enemy_hand)
	confirm_end_turn = _read_bool(cfg, "confirm_end_turn", confirm_end_turn)
	sound_enabled = _read_bool(cfg, "sound_enabled", sound_enabled)
	card_voice = _read_bool(cfg, "card_voice", card_voice)
	fan_angle = clampf(_read_float(cfg, "fan_angle", fan_angle), FAN_ANGLE_MIN, FAN_ANGLE_MAX)
	player_name = _clean_name(_read_string(cfg, "player_name", player_name))
	selected_deck = _read_string(cfg, "selected_deck", selected_deck)
	selected_class = _read_string(cfg, "selected_class", selected_class)
	selected_mode = Formats.normalized_mode(_read_string(cfg, "selected_mode", selected_mode))
	window_mode = clampi(_read_int(cfg, "window_mode", window_mode), WINDOW_MODE_MIN, WINDOW_MODE_MAX)
	ai_difficulty = clampi(_read_int(cfg, "ai_difficulty", ai_difficulty), AI_DIFFICULTY_MIN, AI_DIFFICULTY_MAX)
	net_port = clampi(_read_int(cfg, "net_port", net_port), NET_PORT_MIN, NET_PORT_MAX)
	var speed := _read_float(cfg, "anim_speed", anim_speed)
	anim_speed = speed if absf(speed) < ANIM_SPEED_ZERO_EPSILON else clampf(speed, ANIM_SPEED_MIN, ANIM_SPEED_MAX)
	resolution = _read_resolution(cfg, "resolution", resolution)


## 全部恢复默认值（对话框的「恢复默认设置」调这里；不会自动落盘，由调用方决定）
func restore_defaults() -> void:
	hover_detail = true
	show_enemy_hand = true
	confirm_end_turn = true
	fan_angle = FAN_ANGLE_DEFAULT
	player_name = _default_player_name()
	window_mode = WINDOW_MODE_WINDOWED
	resolution = default_resolution()
	net_port = NET_PORT_DEFAULT
	anim_speed = ANIM_SPEED_DEFAULT
	ai_difficulty = AI_DIFFICULTY_NORMAL
	sound_enabled = true
	card_voice = true
	selected_deck = ""
	selected_class = ""
	selected_mode = Formats.UNLIMITED


## 归一后的当前模式（读的地方都走这个，避免手改存档塞进别的字符串）
func current_mode() -> String:
	return Formats.normalized_mode(selected_mode)


## 测试隔离：把存档路径改到别处（例如 user://test_settings.cfg），不影响玩家真实配置
func use_save_path(p: String) -> void:
	save_path = p


## 存档是否存在于当前 save_path
func save_exists() -> bool:
	return FileAccess.file_exists(save_path)


# ------------------------------ 窗口应用（静态） ------------------------------
## 应用窗口模式与分辨率，并把窗口居中。主界面只需在开局调一次：
##   GameSettings.apply_window_mode(GameSettings.window_mode, GameSettings.resolution)
## 全屏模式下分辨率交给系统（DisplayServer 的 WINDOW_MODE_FULLSCREEN），
## 无边框 / 窗口模式按给定分辨率设尺寸再居中。无头模式调用同样安全（不崩）。
static func apply_window_mode(mode: int, res: Vector2i) -> void:
	var m := clampi(mode, WINDOW_MODE_MIN, WINDOW_MODE_MAX)
	if m == WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if res.x > 0 and res.y > 0:
		DisplayServer.window_set_size(res)
	if m == WINDOW_MODE_BORDERLESS:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_center_window(res)


## 把窗口居中到当前屏幕（窗口比屏幕大时不挪动，避免出现负坐标）
static func _center_window(res: Vector2i) -> void:
	var screen := DisplayServer.window_get_current_screen()
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	if usable.size.x <= 0 or usable.size.y <= 0:
		return
	var size := DisplayServer.window_get_size()
	if size.x <= 0 or size.y <= 0:
		size = res
	if size.x <= 0 or size.y <= 0 or size.x > usable.size.x or size.y > usable.size.y:
		return
	var pos := usable.position + (usable.size - size) / 2
	DisplayServer.window_set_position(pos)


# ------------------------------ 配置读取（严格类型） ------------------------------
func _read_bool(cfg: ConfigFile, key: String, fallback: bool) -> bool:
	var v: Variant = cfg.get_value("game", key, fallback)
	return v if typeof(v) == TYPE_BOOL else fallback


func _read_int(cfg: ConfigFile, key: String, fallback: int) -> int:
	var v: Variant = cfg.get_value("game", key, fallback)
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT:
		return int(floor(float(v)))
	return fallback


func _read_float(cfg: ConfigFile, key: String, fallback: float) -> float:
	var v: Variant = cfg.get_value("game", key, fallback)
	return float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else fallback


func _read_string(cfg: ConfigFile, key: String, fallback: String) -> String:
	var v: Variant = cfg.get_value("game", key, fallback)
	return v if typeof(v) == TYPE_STRING else fallback


## 分辨率：接受 "1920x1080" 字符串或 [w, h] 数组；认不出来就保持当前值
func _read_resolution(cfg: ConfigFile, key: String, fallback: Vector2i) -> Vector2i:
	var v: Variant = cfg.get_value("game", key, fallback)
	match typeof(v):
		TYPE_STRING:
			return parse_resolution(str(v), fallback)
		TYPE_ARRAY:
			var a: Array = v
			if a.size() == 2 and _is_number(a[0]) and _is_number(a[1]):
				return snap_resolution(Vector2i(int(a[0]), int(a[1])))
	return fallback


func _is_number(v: Variant) -> bool:
	var t := typeof(v)
	return t == TYPE_INT or t == TYPE_FLOAT


## 玩家名清洗：去首尾空白、折叠换行、限长；结果为空则退回默认名
func _clean_name(raw: String) -> String:
	var n := raw.strip_edges().replace("\n", " ").replace("\t", " ")
	if n.length() > PLAYER_NAME_MAX_LENGTH:
		n = n.substr(0, PLAYER_NAME_MAX_LENGTH)
	if n.is_empty():
		return _default_player_name()
	return n
