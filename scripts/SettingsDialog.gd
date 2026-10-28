class_name SettingsDialog
extends Window
## 游戏设置：界面、窗口、联机、动画与音效偏好。
## 任何改动都立即写入 GameSettings 并 save_settings()（落盘 + emit changed()），对当前对局生效。
##
## 注意：窗口模式 / 分辨率只写进配置，真正套用窗口由主界面在开局时调
## GameSettings.apply_window_mode()，所以窗口顶部的说明写「重新开局后生效」。

signal closed()
## 玩家在设置里换了战场底图（主界面对接它刷新背景）
signal board_changed()

var _hover_check: CheckBox
var _enemy_hand_check: CheckBox
var _confirm_check: CheckBox
var _name_edit: LineEdit
var _window_mode_option: OptionButton
var _resolution_option: OptionButton
var _port_spin: SpinBox
var _anim_slider: HSlider
var _anim_value: Label
var _ai_option: OptionButton
var _sound_check: CheckBox
var _voice_check: CheckBox
## 战场底图下拉（`assets/art/board/` 的预设）
var _board_option: OptionButton
var _fan_slider: HSlider
var _fan_value: Label


func _ready() -> void:
	title = "设置"
	size = Vector2i(520, 660)
	unresizable = true
	transient = true
	close_requested.connect(_on_close_requested)
	_build_ui()
	_load_from_settings()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var note := Label.new()
	note.text = "窗口模式 / 分辨率在重新开局后生效（关闭并重新运行游戏）。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(note)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 12)
	scroll.add_child(body)

	_hover_check = CheckBox.new()
	_hover_check.text = "悬停卡牌 / 随从时显示完整效果"
	_hover_check.toggled.connect(func(on: bool) -> void: _apply("hover_detail", on))
	body.add_child(_hover_check)

	_enemy_hand_check = CheckBox.new()
	_enemy_hand_check.text = "显示敌方手牌（卡背）"
	_enemy_hand_check.toggled.connect(func(on: bool) -> void: _apply("show_enemy_hand", on))
	body.add_child(_enemy_hand_check)

	_confirm_check = CheckBox.new()
	_confirm_check.text = "还有法力或可攻击随从时，结束回合前二次确认"
	_confirm_check.toggled.connect(func(on: bool) -> void: _apply("confirm_end_turn", on))
	body.add_child(_confirm_check)

	_sound_check = CheckBox.new()
	_sound_check.text = "音效"
	_sound_check.toggled.connect(func(on: bool) -> void: _apply("sound_enabled", on))
	body.add_child(_sound_check)

	_voice_check = CheckBox.new()
	_voice_check.text = "卡牌语音（出牌 / 攻击 / 死亡时播放该卡语音，需自备或导入素材）"
	_voice_check.toggled.connect(func(on: bool) -> void: _apply("card_voice", on))
	body.add_child(_voice_check)

	# ---- 玩家名 ----
	var name_label := Label.new()
	name_label.text = "玩家名（最多 %d 个字符）" % GameSettings.PLAYER_NAME_MAX_LENGTH
	body.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.max_length = GameSettings.PLAYER_NAME_MAX_LENGTH
	_name_edit.placeholder_text = GameSettings.PLAYER_NAME_FALLBACK
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(_t: String) -> void: _commit_name())
	_name_edit.focus_exited.connect(_commit_name)
	body.add_child(_name_edit)

	# ---- 窗口模式 / 分辨率 ----
	_window_mode_option = OptionButton.new()
	_window_mode_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in GameSettings.WINDOW_MODE_NAMES.size():
		_window_mode_option.add_item(GameSettings.WINDOW_MODE_NAMES[i], i)
	_window_mode_option.item_selected.connect(func(idx: int) -> void:
		_apply("window_mode", _window_mode_option.get_item_id(idx))
	)
	body.add_child(_labeled_row("窗口模式", _window_mode_option))

	_resolution_option = OptionButton.new()
	_resolution_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for res in GameSettings.RESOLUTIONS:
		_resolution_option.add_item("%d × %d" % [res.x, res.y], res.x)
		_resolution_option.set_item_metadata(_resolution_option.item_count - 1, res.y)
	_resolution_option.item_selected.connect(func(idx: int) -> void:
		_apply("resolution", Vector2i(_resolution_option.get_item_id(idx),
			int(_resolution_option.get_item_metadata(idx))))
	)
	body.add_child(_labeled_row("分辨率", _resolution_option))

	# ---- 战场底图（= `assets/art/board/` 里的预设；`ArtStore` 是唯一解析处） ----
	_board_option = OptionButton.new()
	_board_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_option.add_item("自动（预设第一张）", 0)
	_board_option.set_item_metadata(0, "")
	var presets := ArtStore.board_presets()
	for i in presets.size():
		_board_option.add_item(presets[i].get_file().get_basename(), i + 1)
		_board_option.set_item_metadata(i + 1, presets[i])
	var none_idx := _board_option.item_count
	_board_option.add_item("纯色底（不用图）", none_idx)
	_board_option.set_item_metadata(none_idx, ArtStore.BG_NONE)
	_board_option.item_selected.connect(func(idx: int) -> void:
		ArtStore.set_background_path(str(_board_option.get_item_metadata(idx)))
		_sync_board_option()
		board_changed.emit()
	)
	body.add_child(_labeled_row("战场底图", _board_option))

	# ---- 联机端口 ----
	_port_spin = SpinBox.new()
	_port_spin.min_value = GameSettings.NET_PORT_MIN
	_port_spin.max_value = GameSettings.NET_PORT_MAX
	_port_spin.step = 1
	_port_spin.allow_greater = false
	_port_spin.allow_lesser = false
	_port_spin.custom_minimum_size = Vector2(140, 0)
	_port_spin.value_changed.connect(func(v: float) -> void: _apply("net_port", int(v)))
	body.add_child(_labeled_row("联机端口（%d–%d）" % [GameSettings.NET_PORT_MIN, GameSettings.NET_PORT_MAX], _port_spin))

	# ---- AI 难度 ----
	_ai_option = OptionButton.new()
	_ai_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in GameSettings.AI_DIFFICULTY_NAMES.size():
		_ai_option.add_item(GameSettings.AI_DIFFICULTY_NAMES[i], i)
	_ai_option.item_selected.connect(func(idx: int) -> void: _apply("ai_difficulty", _ai_option.get_item_id(idx)))
	body.add_child(_labeled_row("AI 难度", _ai_option))

	# ---- AI 助手（浮窗的接口配置在独立窗口里，这里只放入口） ----
	var assistant_row := HBoxContainer.new()
	assistant_row.add_theme_constant_override("separation", 10)
	var assistant_label := Label.new()
	assistant_label.text = "AI 助手浮窗"
	assistant_label.custom_minimum_size = Vector2(180, 0)
	assistant_row.add_child(assistant_label)
	var assistant_btn := Button.new()
	assistant_btn.text = "配置接口 / 密钥 / 模型…"
	assistant_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	assistant_btn.tooltip_text = "打开 AI 助手设置（Base URL、API Key、模型名、系统提示词）"
	assistant_btn.pressed.connect(_open_ai_settings)
	assistant_row.add_child(assistant_btn)
	body.add_child(assistant_row)

	# ---- 动画速度 ----
	var anim_row := VBoxContainer.new()
	anim_row.add_theme_constant_override("separation", 4)
	body.add_child(anim_row)
	var anim_title := Label.new()
	anim_title.text = "动画速度（0 = 立即完成）"
	anim_row.add_child(anim_title)
	var anim_line := HBoxContainer.new()
	anim_line.add_theme_constant_override("separation", 10)
	anim_row.add_child(anim_line)
	_anim_slider = HSlider.new()
	_anim_slider.min_value = GameSettings.ANIM_SPEED_INSTANT
	_anim_slider.max_value = GameSettings.ANIM_SPEED_MAX
	_anim_slider.step = 0.05
	_anim_slider.custom_minimum_size = Vector2(280, 0)
	_anim_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_anim_slider.value_changed.connect(_on_anim_changed)
	# 拖动过程中只实时预览速度；松手后才真正落盘，避免一次拖动写几十遍配置
	_anim_slider.drag_ended.connect(func(_changed: bool) -> void: GameSettings.save_settings())
	anim_line.add_child(_anim_slider)
	_anim_value = Label.new()
	_anim_value.custom_minimum_size = Vector2(70, 0)
	anim_line.add_child(_anim_value)

	# ---- 手牌扇形角度 ----
	var fan_row := VBoxContainer.new()
	fan_row.add_theme_constant_override("separation", 4)
	body.add_child(fan_row)
	var fan_title := Label.new()
	fan_title.text = "手牌扇形展开角度（0° 为平铺）"
	fan_row.add_child(fan_title)
	var slider_row := HBoxContainer.new()
	slider_row.add_theme_constant_override("separation", 10)
	fan_row.add_child(slider_row)
	_fan_slider = HSlider.new()
	_fan_slider.min_value = GameSettings.FAN_ANGLE_MIN
	_fan_slider.max_value = GameSettings.FAN_ANGLE_MAX
	_fan_slider.step = 2.0
	_fan_slider.custom_minimum_size = Vector2(280, 0)
	_fan_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fan_slider.value_changed.connect(_on_fan_changed)
	_fan_slider.drag_ended.connect(func(_changed: bool) -> void: GameSettings.save_settings())
	slider_row.add_child(_fan_slider)
	_fan_value = Label.new()
	_fan_value.custom_minimum_size = Vector2(60, 0)
	slider_row.add_child(_fan_value)

	# ---- 按钮（不跟随滚动，始终可见） ----
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	vbox.add_child(buttons)
	var reset_btn := Button.new()
	reset_btn.text = "恢复默认设置"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_reset_pressed)
	buttons.add_child(reset_btn)
	var close_btn := Button.new()
	close_btn.text = "完成"
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.pressed.connect(_on_close_requested)
	buttons.add_child(close_btn)


## 左侧标题 + 右侧控件的通用一行
func _labeled_row(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(180, 0)
	row.add_child(label)
	row.add_child(control)
	return row


# ------------------------------ 读写绑定 ------------------------------

## 任一控件改动 → 立即写进 GameSettings、落盘并通知（changed 由 save_settings 发出）
func _apply(prop: String, value: Variant) -> void:
	GameSettings.set(prop, value)
	GameSettings.save_settings()


## 把「战场底图」下拉拨到当前生效的那一项
func _sync_board_option() -> void:
	if _board_option == null:
		return
	var saved := ArtStore.saved_background()      # "" = 自动用第一张预设，"-" = 纯色底
	for i in _board_option.item_count:
		if str(_board_option.get_item_metadata(i)) == saved:
			_board_option.select(i)
			return
	_board_option.select(0)


func _load_from_settings() -> void:
	_hover_check.set_pressed_no_signal(GameSettings.hover_detail)
	_enemy_hand_check.set_pressed_no_signal(GameSettings.show_enemy_hand)
	_confirm_check.set_pressed_no_signal(GameSettings.confirm_end_turn)
	_sound_check.set_pressed_no_signal(GameSettings.sound_enabled)
	_voice_check.set_pressed_no_signal(GameSettings.card_voice)
	_sync_board_option()
	_name_edit.text = GameSettings.player_name

	_window_mode_option.select(_index_of_id(_window_mode_option, GameSettings.window_mode))
	_resolution_option.select(_resolution_index(GameSettings.resolution))

	_port_spin.set_value_no_signal(float(GameSettings.net_port))
	_ai_option.select(_index_of_id(_ai_option, GameSettings.ai_difficulty))

	_anim_slider.set_value_no_signal(GameSettings.anim_speed)
	_update_anim_label()

	_fan_slider.set_value_no_signal(GameSettings.fan_angle)
	_update_fan_label()


func _commit_name() -> void:
	var text := _name_edit.text
	GameSettings.player_name = text
	# 空名 / 含换行 / 超长都由 GameSettings 清洗，这里把清洗后的结果写回输入框
	if GameSettings.player_name != text:
		_name_edit.text = GameSettings.player_name
	GameSettings.save_settings()


func _on_anim_changed(value: float) -> void:
	GameSettings.anim_speed = value
	_update_anim_label()
	GameSettings.save_settings(false)   # 拖动的中间过程不写盘，drag_ended 再落盘


func _on_fan_changed(value: float) -> void:
	GameSettings.fan_angle = value
	_update_fan_label()
	GameSettings.save_settings(false)


## 标签读滑块的实际值，保证与滑块取值永远一致（不会出现 thumb 40 / 标签 100°）
func _update_fan_label() -> void:
	_fan_value.text = "%.0f°" % _fan_slider.value


func _update_anim_label() -> void:
	var v: float = _anim_slider.value
	# 0.05–0.45 这种落在「立即」与最慢档之间的取值没有意义：吸附到最近的合法档（0 或 0.5）
	if not is_zero_approx(v) and v < GameSettings.ANIM_SPEED_MIN:
		v = GameSettings.ANIM_SPEED_INSTANT if v < GameSettings.ANIM_SPEED_MIN * 0.5 else GameSettings.ANIM_SPEED_MIN
		_anim_slider.set_value_no_signal(v)
		GameSettings.anim_speed = v
	_anim_value.text = "立即" if v < GameSettings.ANIM_SPEED_ZERO_EPSILON else "%.2f×" % v


func _on_reset_pressed() -> void:
	GameSettings.restore_defaults()
	GameSettings.save_settings()
	_load_from_settings()


## 打开 AI 助手设置窗（接口 / 密钥 / 模型 / 提示词）。窗口归 AiAssistant 所有，
## 这里只转交调用（它会在需要时创建窗口）。
func _open_ai_settings() -> void:
	var ai := get_node_or_null("/root/AiAssistant")
	if ai != null and ai.has_method("open_settings"):
		ai.open_settings()


func _on_close_requested() -> void:
	# 关闭时补一次落盘：名输入框还没失焦、滑块只拖到一半就关窗也不会丢设置
	_commit_name()
	GameSettings.save_settings()
	hide()
	closed.emit()


# ------------------------------ 选项辅助 ------------------------------

## OptionButton 里 id 为 value 的那一项的下标；没有就退回第一项
func _index_of_id(option: OptionButton, value: int) -> int:
	for i in option.item_count:
		if option.get_item_id(i) == value:
			return i
	return 0


## 当前分辨率在列表里的下标；表外 / 非法分辨率吸附到最接近的一档
func _resolution_index(res: Vector2i) -> int:
	var best := 0
	var best_d := -1
	for i in GameSettings.RESOLUTIONS.size():
		var d: int = (GameSettings.RESOLUTIONS[i] - res).length_squared()
		if best_d < 0 or d < best_d:
			best_d = d
			best = i
	return best
