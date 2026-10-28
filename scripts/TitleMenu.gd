extends Control
## 游戏标题界面（启动后第一屏）：开始游戏 / 设置 / 退出。
##
## 界面全部代码构建，场景文件只有一个挂脚本的根节点——少一个手写 .tscn 就少一类低级错误。
## 点「开始游戏」进入主界面（Home.tscn），那里才有「开始匹配 / 人机对战」。

const HOME_SCENE := "res://scenes/Home.tscn"

var _btn_start: Button
var _btn_settings: Button
var _btn_quit: Button
var _tip: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	GameSettings.changed.connect(_refresh)
	_refresh()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(420, 340)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.10, 0.14, 0.98)
	style.border_color = Color(0.30, 0.36, 0.45, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.content_margin_left = 26
	style.content_margin_right = 26
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	box.add_child(v)

	var title := Label.new()
	title.text = "卡牌游戏框架"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color("#ffee58"))
	v.add_child(title)

	var sub := Label.new()
	sub.text = "随从 · 法术 · 护符 · 城邦　｜　横置格 · 城邦格 · 起手换牌"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
	v.add_child(sub)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	v.add_child(spacer)

	_btn_start = _menu_button(v, "开始游戏", _on_start)
	_btn_settings = _menu_button(v, "设置", _on_settings)
	_btn_quit = _menu_button(v, "退出游戏", _on_quit)

	_tip = Label.new()
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.add_theme_font_size_override("font_size", 11)
	_tip.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
	v.add_child(_tip)


func _menu_button(parent: Node, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _refresh() -> void:
	if _tip == null:
		return
	var name_text: String = str(GameSettings.get("player_name"))
	var admin := "管理员已登录" if AdminAuth.is_logged_in else "未登录管理员"
	_tip.text = "玩家：%s　｜　%s\n空格 结束回合 · Esc 取消 · 1-9 选手牌 · F1 帮助" % [name_text, admin]


func _on_start() -> void:
	SoundFx.play("button")
	get_tree().change_scene_to_file(HOME_SCENE)


func _on_settings() -> void:
	SoundFx.play("button")
	var dlg := SettingsDialog.new()
	add_child(dlg)
	dlg.popup_centered()


func _on_quit() -> void:
	SoundFx.play("button")
	get_tree().quit()
