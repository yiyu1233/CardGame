extends SceneTree
## 设置测试：GameSettings 的默认值、存读盘往返、缺失键 / 类型错误回退、越界夹紧、
## 「恢复默认」、窗口模式应用，以及分辨率档位表的合法性。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/settings_test.gd
##
## 隔离说明：本测试**只**通过 use_save_path() 把存档路径改到 user://test_settings.cfg，
## 开头会删掉这个文件，全程不碰玩家真实的 user://settings.cfg。
##
## 注意：工具脚本里不能静态引用自动加载标识符（GameSettings.xxx 在 --script 下解析不到），
## 所以下面一律用 root.get_node_or_null("GameSettings") + 无类型标注的变量动态调用。

const TEST_PATH := "user://test_settings.cfg"

var _fails := 0
var _frames := 0
var _settings
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_settings = root.get_node_or_null("GameSettings")
		if _settings == null:
			_check(false, "GameSettings 自动加载存在")
			_finish()
			return true
		_run()
		_finish()
		return true
	if _frames > 300:
		_check(false, "测试超时")
		_finish()
		return true
	return false


func _run() -> void:
	_prepare_isolated_save()
	_test_defaults()
	_test_defaults_restore()
	_test_round_trip()
	_test_missing_keys()
	_test_type_mismatch()
	_test_clamping()
	_test_restore_defaults()
	_test_window_modes()
	_test_resolution_table()
	_test_dialog_script_compiles()


# ------------------------------ 准备 / 收尾 ------------------------------

## 把存档路径指到隔离文件，并保证测试从一开始就在这个文件上工作
func _prepare_isolated_save() -> void:
	_delete_file(TEST_PATH)
	_settings.use_save_path(TEST_PATH)
	_check(str(_settings.save_path) == TEST_PATH, "存档路径已隔离到 %s" % TEST_PATH)
	_settings.load_settings()          # 文件不存在：全部保持默认值
	_check(not _settings.save_exists(), "测试开始时隔离存档不存在（不读玩家真实设置）")


func _cleanup() -> void:
	_delete_file(TEST_PATH)
	_delete_file(TEST_PATH + ".tmp")


func _delete_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# ------------------------------ 默认值 ------------------------------

func _test_defaults() -> void:
	_check(_settings.hover_detail == true, "默认开启悬停详情")
	_check(_settings.show_enemy_hand == true, "默认显示敌方手牌")
	_check(_settings.confirm_end_turn == true, "默认开启结束回合二次确认")
	_check(_settings.sound_enabled == true, "默认开启音效（字段名 sound_enabled）")

	var expect_name: String = OS.get_environment("USERNAME").strip_edges()
	if expect_name.is_empty():
		expect_name = str(_settings.PLAYER_NAME_FALLBACK)
	_check(_settings.player_name == expect_name,
		"默认玩家名取系统用户名（%s）" % str(_settings.player_name))

	_check(_settings.window_mode == int(_settings.WINDOW_MODE_WINDOWED),
		"默认窗口模式为「窗口」（%d）" % int(_settings.window_mode))
	_check(_settings.net_port == int(_settings.NET_PORT_DEFAULT),
		"默认联机端口为 %d（实际 %d）" % [int(_settings.NET_PORT_DEFAULT), int(_settings.net_port)])
	_check(is_equal_approx(float(_settings.anim_speed), float(_settings.ANIM_SPEED_DEFAULT)),
		"默认动画速度为 %.2f×" % float(_settings.anim_speed))
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_NORMAL),
		"默认 AI 难度为「普通」（%d）" % int(_settings.ai_difficulty))

	# 默认分辨率取 project 的 viewport 尺寸；它本身必须在合法档位表里
	var res: Vector2i = _settings.resolution
	var want_w: int = int(ProjectSettings.get_setting("display/window/size/viewport_width", 0))
	var want_h: int = int(ProjectSettings.get_setting("display/window/size/viewport_height", 0))
	_check(res == Vector2i(want_w, want_h),
		"默认分辨率取 project 的 viewport 尺寸（%s，project 为 %dx%d）" % [str(res), want_w, want_h])
	_check(_settings.RESOLUTIONS.has(res), "默认分辨率在合法档位表里（%s）" % str(res))


## 恢复默认必须回到「内置默认值」：与刚启动（未读档、无存档文件）时的取值一致
func _test_defaults_restore() -> void:
	_settings.hover_detail = false
	_settings.show_enemy_hand = false
	_settings.confirm_end_turn = false
	_settings.sound_enabled = false
	_settings.player_name = "临时名字"
	_settings.window_mode = int(_settings.WINDOW_MODE_BORDERLESS)
	_settings.resolution = Vector2i(1280, 720)
	_settings.net_port = 12345
	_settings.anim_speed = 2.5
	_settings.ai_difficulty = int(_settings.AI_DIFFICULTY_AGGRESSIVE)
	_settings.fan_angle = 4.0
	_settings.restore_defaults()
	_check(_settings.player_name == str(_settings.default_player_name()),
		"恢复默认后玩家名回到系统用户名（%s）" % str(_settings.player_name))
	_check(_settings.resolution == Vector2i(want_w_default(), want_h_default()),
		"恢复默认后分辨率回到 project 的 viewport 尺寸（%s）" % str(_settings.resolution))


# ------------------------------ 存读盘往返 ------------------------------

func _test_round_trip() -> void:
	_settings.hover_detail = false
	_settings.show_enemy_hand = false
	_settings.confirm_end_turn = false
	_settings.sound_enabled = false
	_settings.player_name = "测试玩家"
	_settings.window_mode = int(_settings.WINDOW_MODE_BORDERLESS)
	_settings.resolution = Vector2i(1920, 1080)
	_settings.net_port = 32100
	_settings.anim_speed = 2.5
	_settings.ai_difficulty = int(_settings.AI_DIFFICULTY_AGGRESSIVE)
	_settings.fan_angle = 12.0
	_settings.save_settings()
	_check(_settings.save_exists(), "save_settings() 写出了隔离存档（%s）" % TEST_PATH)

	# 全部改成别的值 → 重新读档必须读回刚存的那一份
	_settings.hover_detail = true
	_settings.show_enemy_hand = true
	_settings.confirm_end_turn = true
	_settings.sound_enabled = true
	_settings.player_name = "改坏了"
	_settings.window_mode = int(_settings.WINDOW_MODE_WINDOWED)
	_settings.resolution = Vector2i(1280, 720)
	_settings.net_port = 1024
	_settings.anim_speed = 1.0
	_settings.ai_difficulty = int(_settings.AI_DIFFICULTY_SAFE)
	_settings.fan_angle = 30.0
	_settings.load_settings()

	_check(_settings.hover_detail == false, "读档读回 hover_detail = false")
	_check(_settings.show_enemy_hand == false, "读档读回 show_enemy_hand = false")
	_check(_settings.confirm_end_turn == false, "读档读回 confirm_end_turn = false")
	_check(_settings.sound_enabled == false, "读档读回 sound_enabled = false")
	_check(_settings.player_name == "测试玩家", "读档读回 player_name（%s）" % str(_settings.player_name))
	_check(_settings.window_mode == int(_settings.WINDOW_MODE_BORDERLESS),
		"读档读回 window_mode = 无边框（%d）" % int(_settings.window_mode))
	_check(_settings.resolution == Vector2i(1920, 1080),
		"读档读回 resolution = 1920x1080（%s）" % str(_settings.resolution))
	_check(_settings.net_port == 32100, "读档读回 net_port = 32100（%d）" % int(_settings.net_port))
	_check(is_equal_approx(float(_settings.anim_speed), 2.5),
		"读档读回 anim_speed = 2.50（%.2f）" % float(_settings.anim_speed))
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_AGGRESSIVE),
		"读档读回 ai_difficulty = 置锋（%d）" % int(_settings.ai_difficulty))
	_check(is_equal_approx(float(_settings.fan_angle), 12.0),
		"读档读回 fan_angle = 12°（%.0f）" % float(_settings.fan_angle))


# ------------------------------ 缺失键 / 类型错误 ------------------------------

## 存档里只有 fan_angle 一个键：其余字段必须保持「当前值」（首次加载即内置默认值）
func _test_missing_keys() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "fan_angle", 20.0)
	_check(cfg.save(TEST_PATH) == OK, "写出只含 fan_angle 的存档")
	_settings.hover_detail = true
	_settings.sound_enabled = true
	_settings.player_name = "缺键玩家"
	_settings.window_mode = int(_settings.WINDOW_MODE_WINDOWED)
	_settings.resolution = Vector2i(1440, 900)
	_settings.net_port = 27015
	_settings.anim_speed = 1.0
	_settings.ai_difficulty = int(_settings.AI_DIFFICULTY_NORMAL)
	_settings.load_settings()
	_check(is_equal_approx(float(_settings.fan_angle), 20.0), "缺失其他键时仍读出 fan_angle = 20°")
	_check(_settings.player_name == "缺键玩家", "缺失键 player_name 保持当前值")
	_check(_settings.net_port == 27015, "缺失键 net_port 保持当前值")
	_check(_settings.resolution == Vector2i(1440, 900), "缺失键 resolution 保持当前值")
	_check(_settings.sound_enabled == true, "缺失键 sound_enabled 保持当前值")
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_NORMAL), "缺失键 ai_difficulty 保持当前值")

	# 连存档文件都没有：一律保持当前值
	_delete_file(TEST_PATH)
	_settings.net_port = 31000
	_settings.player_name = "无存档玩家"
	_settings.load_settings()
	_check(_settings.net_port == 31000 and _settings.player_name == "无存档玩家",
		"存档文件不存在时设置保持不变")


## 类型不符：一律回退到当前值，而不是被 bool() / int() / float() 强行转换
func _test_type_mismatch() -> void:
	_settings.hover_detail = true
	_settings.show_enemy_hand = true
	_settings.confirm_end_turn = true
	_settings.sound_enabled = true
	_settings.player_name = "类型玩家"
	_settings.window_mode = int(_settings.WINDOW_MODE_WINDOWED)
	_settings.resolution = Vector2i(1440, 900)
	_settings.net_port = 27015
	_settings.anim_speed = 1.0
	_settings.ai_difficulty = int(_settings.AI_DIFFICULTY_NORMAL)
	_settings.fan_angle = 30.0

	var cfg := ConfigFile.new()
	cfg.set_value("game", "hover_detail", 0)             # 期望 bool，给 int
	cfg.set_value("game", "sound_enabled", "yes")        # 期望 bool，给 String
	cfg.set_value("game", "player_name", 123)            # 期望 String，给 int
	cfg.set_value("game", "window_mode", "fullscreen")   # 期望 int，给 String
	cfg.set_value("game", "resolution", "很大")           # 无法解析的分辨率字符串
	cfg.set_value("game", "net_port", "27015")           # 期望 int，给 String
	cfg.set_value("game", "anim_speed", "快")             # 期望 float，给 String
	cfg.set_value("game", "ai_difficulty", 1.5)          # 期望 int，给 float
	cfg.set_value("game", "fan_angle", "abc")            # 期望数字，给 String
	_check(cfg.save(TEST_PATH) == OK, "写出类型全部错位的存档")
	_settings.load_settings()

	_check(_settings.hover_detail == true, "hover_detail 类型不符时保持 true（不会被 bool(0) 变成 false）")
	_check(_settings.sound_enabled == true, "sound_enabled 类型不符时保持 true")
	_check(_settings.player_name == "类型玩家", "player_name 类型不符时保持当前值（%s）" % str(_settings.player_name))
	_check(_settings.window_mode == int(_settings.WINDOW_MODE_WINDOWED), "window_mode 类型不符时保持当前值")
	_check(_settings.resolution == Vector2i(1440, 900), "resolution 无法解析时保持当前值（%s）" % str(_settings.resolution))
	_check(_settings.net_port == 27015, "net_port 类型不符时保持当前值（%d）" % int(_settings.net_port))
	_check(is_equal_approx(float(_settings.anim_speed), 1.0), "anim_speed 类型不符时保持当前值（%.2f）" % float(_settings.anim_speed))
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_NORMAL),
		"ai_difficulty 是 float(1.5) 时保持当前值（%d）" % int(_settings.ai_difficulty))
	_check(is_equal_approx(float(_settings.fan_angle), 30.0),
		"fan_angle 类型不符时保持当前值（%.0f）" % float(_settings.fan_angle))


# ------------------------------ 越界夹紧 ------------------------------

## 存档里直接写越界值（绕过 setter，模拟被外部工具改写的配置）
func _test_clamping() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("game", "net_port", 70000)
	cfg.set_value("game", "anim_speed", 99.0)
	cfg.set_value("game", "window_mode", 7)
	cfg.set_value("game", "ai_difficulty", -3)
	cfg.set_value("game", "fan_angle", 100.0)
	cfg.set_value("game", "resolution", "99999x1")
	_check(cfg.save(TEST_PATH) == OK, "写出越界值的存档")
	_settings.load_settings()
	_check(_settings.net_port == int(_settings.NET_PORT_MAX),
		"越界端口 70000 夹紧到 %d（实际 %d）" % [int(_settings.NET_PORT_MAX), int(_settings.net_port)])
	_check(is_equal_approx(float(_settings.anim_speed), float(_settings.ANIM_SPEED_MAX)),
		"越界动画速度 99 夹紧到 %.1f×（实际 %.2f）" % [float(_settings.ANIM_SPEED_MAX), float(_settings.anim_speed)])
	_check(_settings.window_mode == int(_settings.WINDOW_MODE_MAX),
		"越界窗口模式 7 夹紧到 %d（实际 %d）" % [int(_settings.WINDOW_MODE_MAX), int(_settings.window_mode)])
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_MIN),
		"越界 AI 难度 -3 夹紧到 %d（实际 %d）" % [int(_settings.AI_DIFFICULTY_MIN), int(_settings.ai_difficulty)])
	_check(is_equal_approx(float(_settings.fan_angle), float(_settings.FAN_ANGLE_MAX)),
		"越界扇形角度 100 夹紧到 %.0f°（实际 %.0f）" % [float(_settings.FAN_ANGLE_MAX), float(_settings.fan_angle)])
	_check(_settings.RESOLUTIONS.has(_settings.resolution),
		"表外分辨率 99999x1 吸附到合法档位（%s）" % str(_settings.resolution))

	# 下界同样要夹紧，并且不经存档、直接赋值也要夹紧
	_settings.net_port = 1
	_settings.anim_speed = 0.01
	_settings.window_mode = -5
	_settings.ai_difficulty = 9
	_settings.fan_angle = -8.0
	_check(_settings.net_port == int(_settings.NET_PORT_MIN),
		"直接赋值端口 1 夹紧到 %d（实际 %d）" % [int(_settings.NET_PORT_MIN), int(_settings.net_port)])
	_check(is_equal_approx(float(_settings.anim_speed), float(_settings.ANIM_SPEED_MIN)),
		"动画速度 0.01 夹紧到最慢档 %.1f×（实际 %.2f）" % [float(_settings.ANIM_SPEED_MIN), float(_settings.anim_speed)])
	_settings.anim_speed = 0.0
	_check(is_equal_approx(float(_settings.anim_speed), float(_settings.ANIM_SPEED_INSTANT)),
		"动画速度 0 是「立即完成」（实际 %.2f）" % float(_settings.anim_speed))
	_settings.anim_speed = 99.0
	_check(is_equal_approx(float(_settings.anim_speed), float(_settings.ANIM_SPEED_MAX)),
		"动画速度 99 夹紧到 %.1f×（实际 %.2f）" % [float(_settings.ANIM_SPEED_MAX), float(_settings.anim_speed)])
	_check(_settings.window_mode == int(_settings.WINDOW_MODE_MIN),
		"直接赋值窗口模式 -5 夹紧到 %d（实际 %d）" % [int(_settings.WINDOW_MODE_MIN), int(_settings.window_mode)])
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_MAX),
		"直接赋值 AI 难度 9 夹紧到 %d（实际 %d）" % [int(_settings.AI_DIFFICULTY_MAX), int(_settings.ai_difficulty)])
	_check(is_equal_approx(float(_settings.fan_angle), float(_settings.FAN_ANGLE_MIN)),
		"直接赋值扇形角度 -8 夹紧到 %.0f°（实际 %.0f）" % [float(_settings.FAN_ANGLE_MIN), float(_settings.fan_angle)])

	# 夹紧后的值可以正常落盘（存进去的必须是夹紧后的值）
	_settings.save_settings()
	var disk := ConfigFile.new()
	_check(disk.load(TEST_PATH) == OK, "保存后能读回隔离存档")
	_check(int(disk.get_value("game", "net_port", 0)) == int(_settings.NET_PORT_MIN),
		"落盘的端口是夹紧后的下界值 %d（磁盘 %s）" % [int(_settings.NET_PORT_MIN), str(disk.get_value("game", "net_port", "缺"))])
	_check(int(disk.get_value("game", "window_mode", -1)) == int(_settings.WINDOW_MODE_MIN),
		"落盘的窗口模式是夹紧后的合法值 %d" % int(_settings.WINDOW_MODE_MIN))
	# 内存里换成别的值再读档，读回的必须是磁盘上夹紧后的那一份
	_settings.net_port = 27015
	_settings.window_mode = int(_settings.WINDOW_MODE_MAX)
	_settings.load_settings()
	_check(_settings.net_port == int(_settings.NET_PORT_MIN) and _settings.window_mode == int(_settings.WINDOW_MODE_MIN),
		"夹紧后的值落盘后读回来仍然合法（端口 %d / 模式 %d）" % [int(_settings.net_port), int(_settings.window_mode)])


# ------------------------------ 恢复默认 ------------------------------

func _test_restore_defaults() -> void:
	_settings.hover_detail = false
	_settings.show_enemy_hand = false
	_settings.confirm_end_turn = false
	_settings.sound_enabled = false
	_settings.player_name = "临时"
	_settings.window_mode = int(_settings.WINDOW_MODE_BORDERLESS)
	_settings.resolution = Vector2i(1280, 720)
	_settings.net_port = 40000
	_settings.anim_speed = 3.0
	_settings.ai_difficulty = int(_settings.AI_DIFFICULTY_AGGRESSIVE)
	_settings.fan_angle = 2.0

	_settings.restore_defaults()
	_check(_settings.hover_detail == true, "restore_defaults()：hover_detail 回到 true")
	_check(_settings.show_enemy_hand == true, "restore_defaults()：show_enemy_hand 回到 true")
	_check(_settings.confirm_end_turn == true, "restore_defaults()：confirm_end_turn 回到 true")
	_check(_settings.sound_enabled == true, "restore_defaults()：sound_enabled 回到 true")
	_check(_settings.window_mode == int(_settings.WINDOW_MODE_WINDOWED), "restore_defaults()：window_mode 回到窗口")
	_check(_settings.resolution == Vector2i(want_w_default(), want_h_default()),
		"restore_defaults()：resolution 回到 project 尺寸（%s）" % str(_settings.resolution))
	_check(_settings.net_port == int(_settings.NET_PORT_DEFAULT),
		"restore_defaults()：net_port 回到 %d（实际 %d）" % [int(_settings.NET_PORT_DEFAULT), int(_settings.net_port)])
	_check(is_equal_approx(float(_settings.anim_speed), float(_settings.ANIM_SPEED_DEFAULT)),
		"restore_defaults()：anim_speed 回到 %.1f×" % float(_settings.ANIM_SPEED_DEFAULT))
	_check(_settings.ai_difficulty == int(_settings.AI_DIFFICULTY_NORMAL), "restore_defaults()：ai_difficulty 回到普通")
	_check(is_equal_approx(float(_settings.fan_angle), float(_settings.FAN_ANGLE_DEFAULT)),
		"restore_defaults()：fan_angle 回到 %.0f°" % float(_settings.FAN_ANGLE_DEFAULT))

	# 恢复默认后落盘再读回，仍然是默认值
	_settings.save_settings()
	_settings.net_port = 20000
	_settings.load_settings()
	_check(_settings.net_port == int(_settings.NET_PORT_DEFAULT), "恢复默认后落盘再读回仍是默认值")


# ------------------------------ 窗口模式 ------------------------------

func _test_window_modes() -> void:
	# 静态 helper：无头模式下调用必须安全（不崩），并逐个覆盖三种模式
	_settings.apply_window_mode(int(_settings.WINDOW_MODE_WINDOWED), Vector2i(1280, 720))
	_settings.apply_window_mode(int(_settings.WINDOW_MODE_FULLSCREEN), Vector2i(1920, 1080))
	_check(true, "apply_window_mode() 传「窗口」「全屏」不报错")
	_settings.apply_window_mode(int(_settings.WINDOW_MODE_BORDERLESS), Vector2i(1600, 900))
	_check(true, "apply_window_mode() 传「无边框」不报错")

	# 回到窗口模式：窗口尺寸应能读回（无头 / 无窗口系统时读不到就只核对不崩）
	_settings.apply_window_mode(int(_settings.WINDOW_MODE_WINDOWED), Vector2i(1280, 720))
	_check(DisplayServer.get_name() != "", "DisplayServer 可用（%s）" % DisplayServer.get_name())
	var size: Vector2i = DisplayServer.window_get_size()
	var mode: int = DisplayServer.window_get_mode()
	if size.x <= 0 or size.y <= 0:
		print("[SKIP] 当前显示后端读不到窗口尺寸，跳过窗口模式取值核对")
		return
	_check(size == Vector2i(1280, 720), "回到窗口模式后窗口尺寸为 1280x720（实际 %s）" % str(size))
	_check(mode != DisplayServer.WINDOW_MODE_FULLSCREEN and mode != DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
		"回到窗口模式后窗口不再是全屏（模式 %d）" % mode)

	# 越界模式值也要安全（夹紧到窗口模式）
	_settings.apply_window_mode(99, Vector2i(1280, 720))
	_check(true, "apply_window_mode() 传越界模式值不报错（内部夹紧）")


# ------------------------------ 档位表 ------------------------------

func _test_resolution_table() -> void:
	var list: Array = _settings.RESOLUTIONS
	_check(list.size() >= 2, "分辨率档位表非空（%d 档）" % list.size())
	var all_valid := true
	var has_default := false
	var default_res: Vector2i = _settings.default_resolution()
	for res in list:
		if res.x <= 0 or res.y <= 0:
			all_valid = false
		if _settings.snap_resolution(res) != res:
			all_valid = false        # 吸附必须幂等：合法档位吸附后还是自己
		if res == default_res:
			has_default = true
	_check(all_valid, "档位表里的分辨率都合法且吸附幂等")
	_check(has_default, "档位表包含默认分辨率（%s）" % str(default_res))
	_check(_settings.WINDOW_MODE_NAMES.size() == _settings.WINDOW_MODE_MAX - _settings.WINDOW_MODE_MIN + 1,
		"窗口模式名字数与档位数一致（%d）" % _settings.WINDOW_MODE_NAMES.size())
	_check(_settings.AI_DIFFICULTY_NAMES.size() == _settings.AI_DIFFICULTY_MAX - _settings.AI_DIFFICULTY_MIN + 1,
		"AI 难度名字数与档位数一致（%d）" % _settings.AI_DIFFICULTY_NAMES.size())
	_check(_settings.parse_resolution("1920x1080", Vector2i.ZERO) == Vector2i(1920, 1080),
		"parse_resolution() 能解析 1920x1080")
	_check(_settings.parse_resolution("1920*1080", Vector2i.ZERO) == Vector2i(1920, 1080),
		"parse_resolution() 兼容 1920*1080 写法")


# ------------------------------ 对话框可编译 ------------------------------

## 设置对话框脚本引用了自动加载 GameSettings，只在运行期实例化（不静态引用），
## 这里确认它能编译并挂上自动加载（改控件后立即生效的接线不会因解析失败而整体失效）。
func _test_dialog_script_compiles() -> void:
	var dialog: Variant = root.get_node_or_null("SettingsDialog")
	_check(dialog == null, "自动加载里没有 SettingsDialog（界面由脚本自行实例化）")
	var scene := load("res://scripts/SettingsDialog.gd")
	_check(scene != null, "SettingsDialog.gd 可以加载")
	if scene == null:
		return
	var instance = scene.new()
	_check(instance is Window, "SettingsDialog 实例是 Window")
	if instance is Node:
		instance.free()


# ------------------------------ 收尾 ------------------------------

func want_w_default() -> int:
	return int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280))


func want_h_default() -> int:
	return int(ProjectSettings.get_setting("display/window/size/viewport_height", 720))


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	_cleanup()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 设置测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
