class_name AiSettingsDialog
extends Window
## AI 助手设置：接口地址 / API Key / 模型 / 生成参数 / 系统提示词，改动即时写入 AiConfig。
##
## 与 SettingsDialog 同一套观感（独立 Window + MarginContainer + VBox），
## 但保存语义不同：**失焦或回车即落盘**（AiConfig.save_config()），没有「确定」按钮——
## 玩家在对局里调完就能直接问，不需要记住先点保存。

signal closed()

const CONFIG_SCRIPT := preload("res://scripts/AiConfig.gd")
const COLOR_HEAD := Color("#ffee58")
const COLOR_DIM := Color(0.66, 0.71, 0.78, 1.0)

var _base_edit: LineEdit
var _key_edit: LineEdit
var _model_edit: LineEdit
var _temp_slider: HSlider
var _temp_value: Label
var _tokens_spin: SpinBox
var _history_spin: SpinBox
var _stream_check: CheckBox
var _prompt_edit: TextEdit
var _status: Label


func _init() -> void:
	title = "AI 助手设置"
	size = Vector2i(560, 640)
	unresizable = true
	transient = true
	close_requested.connect(_on_close_requested)


func _ready() -> void:
	_build_ui()
	_load_from_config()


func open() -> void:
	_load_from_config()
	popup_centered()
	grab_focus()


func _on_close_requested() -> void:
	_commit_text_fields()
	closed.emit()
	hide()


# ------------------------------ 界面 ------------------------------
func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	vbox.add_child(head)
	var bar := ColorRect.new()
	bar.color = COLOR_HEAD
	bar.custom_minimum_size = Vector2(3, 20)
	head.add_child(bar)
	var title := Label.new()
	title.text = "AI 助手设置"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", COLOR_HEAD)
	head.add_child(title)

	var tip := Label.new()
	tip.text = "任何 OpenAI 兼容接口都能用：填 Base URL 与模型名即可（DeepSeek / OpenAI / 通义 / Kimi / 本地 Ollama…）。\n密钥只存在本机 user://ai.cfg，不会随游戏文件分发。"
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", 11)
	tip.add_theme_color_override("font_color", COLOR_DIM)
	vbox.add_child(tip)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	scroll.add_child(body)

	_body_label(body, "接口地址（Base URL）")
	_base_edit = _line(body, "https://api.deepseek.com/v1", "例如 https://api.deepseek.com/v1；本地 Ollama 用 http://localhost:11434/v1")
	_base_edit.text_submitted.connect(func(_t: String) -> void: _commit_text_fields())

	_body_label(body, "API Key（留空 = 不使用密钥，本地服务可以留空）")
	_key_edit = _line(body, "sk-…", "保存在 user://ai.cfg；本地 Ollama 可留空")
	_key_edit.secret = true
	_key_edit.text_submitted.connect(func(_t: String) -> void: _commit_text_fields())
	var key_row := HBoxContainer.new()
	key_row.add_theme_constant_override("separation", 6)
	body.add_child(key_row)
	var show_key := CheckBox.new()
	show_key.text = "显示密钥"
	show_key.toggled.connect(func(on: bool) -> void: _key_edit.secret = not on)
	key_row.add_child(show_key)

	_body_label(body, "模型名")
	_model_edit = _line(body, "deepseek-chat", "例如 deepseek-chat / gpt-4o-mini / qwen-plus")
	_model_edit.text_submitted.connect(func(_t: String) -> void: _commit_text_fields())

	# 温度
	var temp_row := HBoxContainer.new()
	temp_row.add_theme_constant_override("separation", 8)
	body.add_child(temp_row)
	var temp_label := Label.new()
	temp_label.text = "温度（越高越有创意）"
	temp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	temp_row.add_child(temp_label)
	_temp_value = Label.new()
	_temp_value.text = "0.7"
	temp_row.add_child(_temp_value)
	_temp_slider = HSlider.new()
	_temp_slider.min_value = 0.0
	_temp_slider.max_value = 2.0
	_temp_slider.step = 0.1
	_temp_slider.custom_minimum_size = Vector2(0, 20)
	_temp_slider.value_changed.connect(func(v: float) -> void:
		_temp_value.text = "%.1f" % v
		var cfg := _cfg()
		if cfg != null:
			cfg.temperature = v)
	_temp_slider.drag_ended.connect(func(_changed: bool) -> void: _save())
	body.add_child(_temp_slider)

	# 最大回复长度
	var tok_row := HBoxContainer.new()
	tok_row.add_theme_constant_override("separation", 8)
	body.add_child(tok_row)
	var tok_label := Label.new()
	tok_label.text = "单次回复最大 token"
	tok_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tok_row.add_child(tok_label)
	_tokens_spin = SpinBox.new()
	_tokens_spin.min_value = CONFIG_SCRIPT.MAX_TOKENS_MIN
	_tokens_spin.max_value = CONFIG_SCRIPT.MAX_TOKENS_MAX
	_tokens_spin.step = 64
	_tokens_spin.custom_minimum_size = Vector2(120, 28)
	_tokens_spin.value_changed.connect(func(v: float) -> void:
		var cfg := _cfg()
		if cfg != null:
			cfg.max_tokens = int(v))
	_tokens_spin.get_line_edit().text_submitted.connect(func(_t: String) -> void: _save())
	_tokens_spin.get_line_edit().focus_exited.connect(_save)
	tok_row.add_child(_tokens_spin)

	# 历史条数
	var his_row := HBoxContainer.new()
	his_row.add_theme_constant_override("separation", 8)
	body.add_child(his_row)
	var his_label := Label.new()
	his_label.text = "带上的历史消息条数（越大越费 token）"
	his_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	his_row.add_child(his_label)
	_history_spin = SpinBox.new()
	_history_spin.min_value = CONFIG_SCRIPT.HISTORY_LIMIT_MIN
	_history_spin.max_value = CONFIG_SCRIPT.HISTORY_LIMIT_MAX
	_history_spin.step = 2
	_history_spin.custom_minimum_size = Vector2(120, 28)
	_history_spin.value_changed.connect(func(v: float) -> void:
		var cfg := _cfg()
		if cfg != null:
			cfg.history_limit = int(v))
	_history_spin.get_line_edit().focus_exited.connect(_save)
	his_row.add_child(_history_spin)

	_stream_check = CheckBox.new()
	_stream_check.text = "流式输出（逐字显示；部分自建网关不支持，关掉后整段返回）"
	_stream_check.toggled.connect(func(on: bool) -> void:
		var cfg := _cfg()
		if cfg != null:
			cfg.stream = on
		_save())
	body.add_child(_stream_check)

	_body_label(body, "系统提示词（AI 的身份与回答纪律；建议保留工具调用格式说明）")
	_prompt_edit = TextEdit.new()
	_prompt_edit.custom_minimum_size = Vector2(0, 150)
	_prompt_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt_edit.add_theme_font_size_override("font_size", 12)
	_prompt_edit.focus_exited.connect(_commit_text_fields)
	body.add_child(_prompt_edit)

	# 底部：状态 + 恢复默认 + 关闭
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	_status.add_theme_color_override("font_color", COLOR_DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)
	var demo := Button.new()
	demo.text = "填入 DeepSeek 默认值"
	demo.pressed.connect(_fill_deepseek)
	buttons.add_child(demo)
	var reset := Button.new()
	reset.text = "恢复默认"
	reset.pressed.connect(_restore_defaults)
	buttons.add_child(reset)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(func() -> void:
		_commit_text_fields()
		hide()
		closed.emit())
	buttons.add_child(close_btn)
	UiSkin.apply_buttons(self)


func _body_label(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 12)
	parent.add_child(l)


func _line(parent: Control, placeholder: String, tip: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.tooltip_text = tip
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.custom_minimum_size = Vector2(0, 30)
	parent.add_child(e)
	return e


# ------------------------------ 读写 ------------------------------
func _cfg() -> Node:
	if Engine.get_main_loop() is SceneTree:
		return (Engine.get_main_loop() as SceneTree).root.get_node_or_null("AiConfig")
	return null


func _load_from_config() -> void:
	var cfg := _cfg()
	if cfg == null:
		return
	_base_edit.text = str(cfg.base_url)
	_key_edit.text = str(cfg.api_key)
	_model_edit.text = str(cfg.model)
	_temp_slider.value = float(cfg.temperature)
	_temp_value.text = "%.1f" % float(cfg.temperature)
	_tokens_spin.value = int(cfg.max_tokens)
	_history_spin.value = int(cfg.history_limit)
	_stream_check.button_pressed = bool(cfg.stream)
	_prompt_edit.text = str(cfg.system_prompt)
	_status.text = ""


## 文本字段（地址 / 密钥 / 模型 / 提示词）失焦或回车时提交并落盘
func _commit_text_fields() -> void:
	var cfg := _cfg()
	if cfg == null:
		return
	var changed := false
	if cfg.base_url != _base_edit.text.strip_edges():
		cfg.base_url = _base_edit.text.strip_edges()
		changed = true
	if cfg.api_key != _key_edit.text.strip_edges():
		cfg.api_key = _key_edit.text.strip_edges()
		changed = true
	if cfg.model != _model_edit.text.strip_edges():
		cfg.model = _model_edit.text.strip_edges()
		changed = true
	if cfg.system_prompt != _prompt_edit.text:
		cfg.system_prompt = _prompt_edit.text
		changed = true
	if changed:
		_save()


func _save() -> void:
	var cfg := _cfg()
	if cfg == null:
		return
	cfg.save_config()


func _fill_deepseek() -> void:
	var cfg := _cfg()
	if cfg == null:
		return
	_base_edit.text = "https://api.deepseek.com/v1"
	_model_edit.text = "deepseek-chat"
	cfg.base_url = _base_edit.text
	cfg.model = _model_edit.text
	_save()
	_status.text = "已填入 DeepSeek 默认地址与模型，记得填 API Key。"


func _restore_defaults() -> void:
	var cfg := _cfg()
	if cfg == null:
		return
	cfg.restore_defaults()
	cfg.save_config()
	_load_from_config()
	_status.text = "已恢复默认配置（密钥已清空）。"
