class_name AiSidebar
extends Control
## AI 助手浮窗（侧边栏）：贴**右边缘**滑出的对话抽屉 + 右上角常驻的圆形「AI」按钮。
##
## 结构（挂在一个高层 CanvasLayer 上，从任何界面（标题 / 主界面 / 对局）都能呼出）：
##   * 圆形漂浮按钮：常驻；点它开合抽屉（按钮随抽屉打开滑到面板左缘，不再压住内容）；
##   * 抽屉本体：标题栏（模型 / 状态 + 新对话 / 设置 / 收起）→ 快捷指令 → 对话区 → 输入行。
##
## 与 TrackerPanel 的差异与理由：
##   * TrackerPanel 贴右边缘宽 300，只盖日志栏；AI 抽屉要放长回复，宽 400，同样贴右边缘；
##   * 抽屉自带输入框，打开时自动聚焦，回车即发送。
##
## 渲染约定：
##   * 对话内容存 `lines`（[{role, raw}]，raw = AI 原文）；
##   * 每次变化整体重渲染成 BBCode（`_render()`）——消息量小，简单可靠；
##     流式追加（每段 delta）与最终落定（工具轮）共用同一条路径。
##
## 线程 / 生命周期：本控件挂在自动加载单例下（AiAssistant），不随场景切换销毁，
## 所以对话历史天然跨界面保留；`reset()` 清空。

signal send_requested(text: String)   ## 用户点了发送 / 按了回车
signal stop_requested()               ## 想中断正在进行的回复
signal new_chat_requested()           ## 点了「新对话」
signal settings_requested()           ## 点了「设置」

## 动画速度的取值口径与 GameSettings 共用一份（preload 静态调用，既能拿到常量，
## 又不会在 `--script` 无头测试的编译期依赖自动加载单例的全局标识符）
const SETTINGS_SCRIPT := preload("res://scripts/GameSettings.gd")

# ------------------------------ 尺寸 ------------------------------
const DRAWER_WIDTH := 400.0
const RIGHT_MARGIN := 8.0
const V_MARGIN := 8.0
const SLIDE_TIME := 0.18
## 圆形漂浮按钮：右下角常见浮窗尺寸；放在右上角不压对局信息的横向空带里
const BUBBLE_SIZE := 46.0

# ------------------------------ 配色（沿用 UiSkin 的观感） ------------------------------
const COLOR_HEAD := Color("#ffee58")
const COLOR_USER := Color("#8ecdf7")
const COLOR_AI := Color("#a5d6a7")
const COLOR_SYS := Color("#b0bec5")
const COLOR_ERR := Color("#ef9a9a")
const COLOR_DIM := Color(0.66, 0.71, 0.78, 1.0)
const COLOR_BODY := Color(0.91, 0.93, 0.97, 1.0)

## 对话渲染项：{"role": "user"/"assistant"/"system"/"error"/"tool", "raw": String}
var lines: Array[Dictionary] = []

var _open := false
var _tween: Tween = null

var _drawer: PanelContainer
var _bubble: Button
var _model_label: Label
var _status_label: Label
var _body: RichTextLabel
var _scroll: ScrollContainer
var _input: LineEdit
var _send_btn: Button
var _stop_btn: Button
## 流式中的临时消息（直接改最后一条 assistant 的 raw，落定时归位）
var _streaming := false
## 「正在思考」提示文案（status 行 + 对话区末尾的占位）
var _thinking := ""


func _ready() -> void:
	# 铺满全屏、但不吃鼠标：只有按钮与抽屉两个子节点参与交互
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	visible = false
	_build()
	_refresh_model_label()
	# 模型名随设置变化刷新；用运行时查节点的方式接线（`--script` 测试里也能安全跑到这行）
	var settings := _settings()
	if settings != null and settings.has_signal("changed"):
		settings.changed.connect(_refresh_model_label)
	_bubble.visible = true


# ------------------------------ 构建 ------------------------------
func _build() -> void:
	_build_bubble()
	_build_drawer()


func _build_bubble() -> void:
	_bubble = Button.new()
	_bubble.text = "AI"
	_bubble.tooltip_text = "打开 / 收起 AI 助手（F2）"
	_bubble.focus_mode = Control.FOCUS_NONE
	_bubble.custom_minimum_size = Vector2(BUBBLE_SIZE, BUBBLE_SIZE)
	_bubble.add_theme_font_size_override("font_size", 16)
	# 正圆 + 琥珀强调，与中线两端的圆钮同一观感；`_is_circle()` 靠圆角 ≥ 30 识别
	_bubble.add_theme_stylebox_override("normal", _bubble_style(Color("#1d283b"), Color("#ffca28")))
	_bubble.add_theme_stylebox_override("hover", _bubble_style(Color("#27354d"), Color("#ffd54f")))
	_bubble.add_theme_stylebox_override("pressed", _bubble_style(Color("#121a28"), Color("#ffca28")))
	_bubble.add_theme_color_override("font_color", Color("#ffca28"))
	_bubble.add_theme_color_override("font_hover_color", Color("#ffe082"))
	_bubble.pressed.connect(toggle)
	add_child(_bubble)
	_place_bubble()


func _bubble_style(bg: Color, edge: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(2)
	s.set_corner_radius_all(int(BUBBLE_SIZE / 2.0))
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.shadow_size = 4
	s.shadow_offset = Vector2(0, 2)
	return s


func _build_drawer() -> void:
	_drawer = PanelContainer.new()
	_drawer.anchor_left = 1.0
	_drawer.anchor_right = 1.0
	_drawer.anchor_top = 0.0
	_drawer.anchor_bottom = 1.0
	_drawer.focus_mode = Control.FOCUS_NONE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.13, 0.97)
	style.border_color = Color(0.28, 0.32, 0.38, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	add_child(_drawer)
	_apply_offsets(_closed_left())

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_drawer.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# ---- 标题栏 ----
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	vbox.add_child(header)

	var head_bar := ColorRect.new()
	head_bar.color = COLOR_HEAD
	head_bar.custom_minimum_size = Vector2(3, 20)
	header.add_child(head_bar)

	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", 0)
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_box)
	var title := Label.new()
	title.text = "AI 助手"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", COLOR_HEAD)
	title_box.add_child(title)
	_model_label = Label.new()
	_model_label.add_theme_font_size_override("font_size", 10)
	_model_label.add_theme_color_override("font_color", COLOR_DIM)
	_model_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_box.add_child(_model_label)

	var header_buttons := HBoxContainer.new()
	header_buttons.add_theme_constant_override("separation", 4)
	header.add_child(header_buttons)
	var new_btn := _small_button("新对话", "清空当前对话，重新开始")
	new_btn.pressed.connect(func() -> void: new_chat_requested.emit())
	header_buttons.add_child(new_btn)
	var cfg_btn := _small_button("设置", "配置接口地址 / API Key / 模型")
	cfg_btn.pressed.connect(func() -> void: settings_requested.emit())
	header_buttons.add_child(cfg_btn)
	var close_btn := _small_button("收起", "收起 AI 助手（Esc）")
	close_btn.pressed.connect(close)
	header_buttons.add_child(close_btn)

	# ---- 状态行（连接 / 错误 / 思考中） ----
	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 11)
	_status_label.add_theme_color_override("font_color", COLOR_DIM)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.visible = false
	vbox.add_child(_status_label)

	# ---- 快捷指令 ----
	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 4)
	vbox.add_child(quick)
	_add_quick(quick, "分析局面", "读当前对局局面并给出形势判断：我现在的领先/落后点、需要重点防的事。")
	_add_quick(quick, "推荐出牌", "看当前对局局面，推荐这个回合的最优打法（考虑换怪、抢血、解场、留牌），并说明理由。")
	_add_quick(quick, "找卡", "帮我从卡表里找一张卡，请先问我想要什么效果或费用。")
	_add_quick(quick, "机制说明", "请解释关键字机制（如嘲讽 / 圣盾 / 潜行）的结算规则和互斥关系。")

	# ---- 对话区 ----
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_scroll)
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.scroll_active = false    # 滚动交给外层 ScrollContainer，避免嵌套两层滚动
	_body.selection_enabled = true
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.custom_minimum_size = Vector2(0, 10)
	_body.add_theme_font_size_override("normal_font_size", 12)
	_body.add_theme_color_override("default_color", COLOR_BODY)
	_body.meta_underlined = false
	_scroll.add_child(_body)

	# ---- 输入行 ----
	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 6)
	vbox.add_child(input_row)
	_input = LineEdit.new()
	_input.placeholder_text = "输入问题，回车发送…（F2 开合，Esc 收起）"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.custom_minimum_size = Vector2(0, 32)
	_input.add_theme_font_size_override("font_size", 12)
	_input.text_submitted.connect(_on_submit)
	input_row.add_child(_input)
	_send_btn = _small_button("发送", "发送（回车）")
	_send_btn.custom_minimum_size = Vector2(52, 32)
	_send_btn.pressed.connect(func() -> void: _on_submit(_input.text))
	input_row.add_child(_send_btn)
	_stop_btn = _small_button("停止", "中断当前回复")
	_stop_btn.custom_minimum_size = Vector2(52, 32)
	_stop_btn.visible = false
	_stop_btn.pressed.connect(func() -> void: stop_requested.emit())
	input_row.add_child(_stop_btn)

	# 装饰性子树不吃鼠标（同 TrackerPanel 的做法）；可交互控件都在上面的独立分支里
	UiUtil.make_decorative(header)
	UiUtil.make_decorative(title_box)
	UiUtil.make_decorative(_status_label)
	UiUtil.make_decorative(quick)
	UiUtil.make_decorative(_scroll)
	UiUtil.make_decorative(margin)


func _small_button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(44, 22)
	b.add_theme_font_size_override("font_size", 11)
	UiSkin.apply_button(b)
	return b


func _add_quick(row: HBoxContainer, label: String, prompt: String) -> void:
	var b := _small_button(label, "快捷指令：" + prompt)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(func() -> void: _use_quick(prompt))
	row.add_child(b)


## 快捷指令：填进输入框并直接发送（AI 自己会按需调 game_state 工具读局面）
func _use_quick(prompt: String) -> void:
	_input.text = prompt
	_on_submit(prompt)


func _on_submit(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	_input.text = ""
	send_requested.emit(t)


# ------------------------------ 开合 ------------------------------
func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	_apply_offsets(_closed_left())
	_slide_to(_open_left(), false)
	if _input != null:
		_input.grab_focus()


func close() -> void:
	if not _open:
		return
	_open = false
	_slide_to(_closed_left(), true)
	if _input != null:
		_input.release_focus()
	_place_bubble()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func _open_left() -> float:
	return -DRAWER_WIDTH - RIGHT_MARGIN


func _closed_left() -> float:
	return -RIGHT_MARGIN


func _apply_offsets(left: float) -> void:
	_drawer.offset_left = left
	_drawer.offset_right = left + DRAWER_WIDTH
	_drawer.offset_top = V_MARGIN
	_drawer.offset_bottom = -V_MARGIN
	_place_bubble()


func _slide_to(left: float, hide_after: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	var settings := _settings()
	var anim := 1.0
	if settings != null:
		anim = float(settings.get("anim_speed"))
	if SLIDE_TIME <= 0.0 or anim == SETTINGS_SCRIPT.ANIM_SPEED_INSTANT:
		_apply_offsets(left)
		if hide_after:
			visible = false
		return
	var speed := maxf(0.05, anim)
	var dur := SLIDE_TIME / speed
	# 动画过程中按钮跟着抽屉左缘走，避免被抽屉盖住
	var bubble_to := _bubble_x_for(left)
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_drawer, "offset_left", left, dur)
	_tween.parallel().tween_property(_drawer, "offset_right", left + DRAWER_WIDTH, dur)
	_tween.parallel().tween_property(_bubble, "position:x", bubble_to, dur)
	if hide_after:
		_tween.tween_callback(func() -> void: visible = false)


## 漂浮按钮的位置：收起时贴右上角；展开时移到抽屉左缘外侧（随抽屉一起滑动）
func _place_bubble() -> void:
	if _bubble == null:
		return
	var left := _closed_left()
	if _drawer != null:
		left = _drawer.offset_left
	_bubble.position = Vector2(_bubble_x_for(left), V_MARGIN + 6.0)


func _bubble_x_for(drawer_left: float) -> float:
	var screen_w: float = get_viewport_rect().size.x
	if _open:
		# 抽屉展开：按钮贴在抽屉左缘外侧
		return screen_w + drawer_left - BUBBLE_SIZE - 8.0
	return screen_w - RIGHT_MARGIN - BUBBLE_SIZE


# ------------------------------ 内容 ------------------------------
## 追加一条消息（role：user / assistant / system / error）；raw 为 AI 原文或纯文本
func append_message(role: String, raw: String) -> void:
	if raw.strip_edges().is_empty() and role != "assistant":
		return
	lines.append({"role": role, "raw": raw})
	_render()
	if _open:
		scroll_to_bottom()


## 流式增量：没有进行中的 assistant 消息就新起一条
func append_delta(piece: String) -> void:
	if not _streaming or lines.is_empty() or str(lines[lines.size() - 1].get("role", "")) != "assistant":
		lines.append({"role": "assistant", "raw": ""})
		_streaming = true
	var last := lines[lines.size() - 1]
	last["raw"] = str(last.get("raw", "")) + piece
	_render()
	if _open:
		scroll_to_bottom()


## 把最后一条流式 assistant 消息落定为给定整段（工具轮之后用）
func finalize_stream(text: String) -> void:
	if _streaming and not lines.is_empty() and str(lines[lines.size() - 1].get("role", "")) == "assistant":
		lines[lines.size() - 1]["raw"] = text
	else:
		lines.append({"role": "assistant", "raw": text})
	_streaming = false
	# 落定即代表这一轮结束：按钮状态一并复位（调用方不需要再补 set_streaming(false)）
	_send_btn.visible = true
	_stop_btn.visible = false
	_render()
	if _open:
		scroll_to_bottom()


## 思考中的占位（对话区末尾一条灰字；发新请求前会清掉）
func set_thinking(text: String) -> void:
	_thinking = text
	_render()
	if _open:
		scroll_to_bottom()


func set_streaming(on: bool) -> void:
	_streaming = on
	_send_btn.visible = not on
	_stop_btn.visible = on
	if not on:
		_thinking = ""
		_render()


func set_status(text: String, is_error: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", COLOR_ERR if is_error else COLOR_DIM)
	_status_label.visible = not text.strip_edges().is_empty()


func clear() -> void:
	lines.clear()
	_thinking = ""
	_streaming = false
	_render()
	set_status("")


func scroll_to_bottom() -> void:
	if _scroll == null:
		return
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _refresh_model_label() -> void:
	if _model_label == null:
		return
	var cfg := _cfg()
	if cfg == null:
		_model_label.text = ""
		return
	var hint: String = cfg.needs_key_hint()
	_model_label.text = "%s%s" % [cfg.model, ("  ·  " + hint) if hint != "" else ""]


func _cfg() -> Node:
	return Engine.get_main_loop().root.get_node_or_null("AiConfig") if Engine.get_main_loop() is SceneTree else null


## GameSettings 单例（运行时查节点，避免编译期依赖自动加载的全局标识符）
func _settings() -> Node:
	if Engine.get_main_loop() is SceneTree:
		return (Engine.get_main_loop() as SceneTree).root.get_node_or_null("GameSettings")
	return null


# ------------------------------ 渲染 ------------------------------
func _render() -> void:
	if _body == null:
		return
	var parts := PackedStringArray()
	for item in lines:
		_render_one(parts, str(item.get("role", "")), str(item.get("raw", "")))
	if _thinking != "":
		parts.append("[color=#b0bec5][i]· %s[/i][/color]" % _escape(_thinking))
	_body.text = "\n\n".join(parts)


func _render_one(parts: PackedStringArray, role: String, raw: String) -> void:
	match role:
		"user":
			parts.append("[color=#8ecdf7][b]你[/b][/color]\n" + _to_bbcode(raw))
		"assistant":
			parts.append("[color=#a5d6a7][b]AI[/b][/color]\n" + _to_bbcode(raw))
		"error":
			parts.append("[color=#ef9a9a][b]出错了[/b][/color]\n" + _to_bbcode(raw))
		"tool":
			parts.append("[color=#b0bec5][i]%s[/i][/color]" % _escape(raw))
		_:
			parts.append("[color=#b0bec5]%s[/color]" % _escape(raw))


## BBCode 转义：用户 / AI 文本里的 [ ] 必须变成字面量（防注入与渲染错乱）。
## 必须**一次扫描**完成——`text.replace("[", "[lb]").replace("]", "[rb]")` 这种链式写法
## 会把第一步插入的 `]` 又替换成 `[rb]`，得到 `[lb[rb]` 这种坏标签（踩过的坑）。
static func _escape(text: String) -> String:
	var out := ""
	for k in text.length():
		var ch := text[k]
		if ch == "[":
			out += "[lb]"
		elif ch == "]":
			out += "[rb]"
		else:
			out += ch
	return out


## 把 AI 的 Markdown 风格输出转成安全的 BBCode：先转义，再按「行内代码 → 加粗 / 斜体」的
## 优先级**单趟扫描**转换（逐字符解析，成对标记才生成标签，落单的标记原样保留）。
## 之前的实现用「逐种标记整串替换」，**加粗** 里的单星号会把结果搅乱成 `[b]x[i]*…`，
## 所以这里改成一次扫描、各标记互不干扰。
static func _to_bbcode(raw: String) -> String:
	var lines := PackedStringArray()
	var in_fence := false
	for src_line in _escape(raw).split("\n"):
		var line: String = src_line
		if line.strip_edges().begins_with("```"):
			if in_fence:
				lines.append("[/code]")
			else:
				lines.append("[code]")
			in_fence = not in_fence
			continue
		if in_fence:
			lines.append(line)
			continue
		if line.begins_with("### "):
			lines.append("[b][color=#ffca28]%s[/color][/b]" % line.substr(4))
		elif line.begins_with("## "):
			lines.append("[b][color=#ffca28]%s[/color][/b]" % line.substr(3))
		elif line.begins_with("# "):
			lines.append("[b][color=#ffca28]%s[/color][/b]" % line.substr(2))
		elif line.strip_edges() == "---" or line.strip_edges() == "***":
			lines.append("[color=#3b4a63]────────────────[/color]")
		else:
			lines.append(_inline_markup(line))
	if in_fence:
		lines.append("[/code]")
	return "\n".join(lines)


## 行内标记：`代码` / **加粗** / *斜体*。
##
## 实现（两趟，全部在「位置」层面算，不再数段内下标——那里踩过坑）：
##   1. 成对的反引号之间标为代码（代码里不解析星号）；
##   2. 星号按**连续段**处理，每段一次性吃掉：
##      * 2 颗（**）：第 1 颗发加粗开、第 2 颗发加粗闭；
##      * 3 颗（***）：第 1 颗发加粗开+斜体开、第 2 颗发斜体闭、第 3 颗发加粗闭；
##      * 1 颗：先收集，按出现顺序两两配对成斜体（落单的保持字面量）。
## 标签用私用区占位符（String.chr 构造）暂存，最后统一换回 BBCode——
## 源码里的 "\uXXXX" 字面量在某些编码下会被存成 6 个字符，chr() 永远给出真码位（踩过的坑）。
static func _inline_markup(line: String) -> String:
	var n := line.length()
	var is_code: Array[bool] = []
	is_code.resize(n)
	# 第一趟 a：成对反引号 = 行内代码
	var i := 0
	while i < n:
		if line[i] == "`":
			var j := i + 1
			while j < n and line[j] != "`":
				j += 1
			if j < n:
				is_code[i] = true
				is_code[j] = true
				i = j + 1
				continue
		i += 1
	# 第一趟 b：星号连续段（只记段的起点与长度，不再需要「段内下标」）
	var stars: Array[int] = []
	for k in n:
		if line[k] == "*" and not is_code[k]:
			stars.append(k)
	var run_start: Array[int] = []   # 每段第一颗星在 line 里的位置
	var run_size: Array[int] = []    # 每段长度
	var run_of: Array[int] = []      # line 位置 → 段编号（仅星号位置有效）
	run_of.resize(n)
	var idx := 0
	while idx < stars.size():
		var from := idx
		while idx + 1 < stars.size() and stars[idx + 1] == stars[idx] + 1:
			idx += 1
		var rid := run_start.size()
		run_start.append(stars[from])
		run_size.append(idx - from + 1)
		for k in range(from, idx + 1):
			run_of[stars[k]] = rid
		idx += 1
	# 单颗段按出现顺序两两配对（斜体）
	var single_runs: Array[int] = []
	for rid in run_start.size():
		if run_size[rid] == 1:
			single_runs.append(rid)
	# 把「星号段」两两配对成**成对的开闭**：
	#   2 颗段（**）：奇数序 = 开加粗、偶数序 = 闭加粗；
	#   3 颗段（***）：奇数序 = 开加粗+开斜体、偶数序 = 闭斜体+闭加粗；
	#   1 颗段：按出现顺序两两配对（奇数序开斜体、偶数序闭斜体），落单的保持字面量。
	# 这里的关键是「段」本身才是标记：一段只发它自己那一半的标签，开闭由段的出现顺序决定。
	var bold_runs: Array[int] = []
	var ital_runs: Array[int] = []
	for rid in run_start.size():
		var sz := run_size[rid]
		if sz == 2 or sz == 3:
			bold_runs.append(rid)
			if sz == 3:
				ital_runs.append(rid)
	# 3 颗段自己就同时开闭斜体，所以斜体配对不参与；单颗段才需要跨段配对
	var single_pair_open: Dictionary = {}
	for k in range(0, single_runs.size() - 1, 2):
		single_pair_open[single_runs[k]] = true
	# 第二趟：渲染
	var P_B_OPEN := String.chr(0xE000)
	var P_B_CLOSE := String.chr(0xE001)
	var P_I_OPEN := String.chr(0xE002)
	var P_I_CLOSE := String.chr(0xE003)
	var P_C_OPEN := String.chr(0xE004)
	var P_C_CLOSE := String.chr(0xE005)
	var out := ""
	var in_code := false
	i = 0
	while i < n:
		if line[i] == "`" and is_code[i]:
			out += P_C_CLOSE if in_code else P_C_OPEN
			in_code = not in_code
			i += 1
			continue
		if line[i] == "*" and not is_code[i]:
			var rid := run_of[i]
			var size := run_size[rid]
			var tag := ""
			if size == 2:
				var order := bold_runs.find(rid)
				tag = P_B_OPEN if order % 2 == 0 else P_B_CLOSE
			elif size == 3:
				var order2 := bold_runs.find(rid)
				tag = (P_B_OPEN + P_I_OPEN) if order2 % 2 == 0 else (P_I_CLOSE + P_B_CLOSE)
			elif size == 1:
				if single_pair_open.has(rid):
					tag = P_I_OPEN
				elif single_runs.find(rid) % 2 == 1:
					tag = P_I_CLOSE
			else:
				# 4 颗以上：按加粗的两半处理（前半开、后半闭），整段一次吃掉
				var half := size / 2
				tag = P_B_OPEN.repeat(half) + P_B_CLOSE.repeat(size - half)
			if tag == "":
				out += line[i]      # 字面量星号
				i += 1
			else:
				out += tag
				i += size           # 整段跳过
			continue
		out += line[i]
		i += 1
	if in_code:
		out += P_C_CLOSE
	# 兜底平衡：落单的开标记在行尾补上闭合标签（AI 偶尔会把 **加粗** 打成 **加粗）
	if out.count(P_B_OPEN) > out.count(P_B_CLOSE):
		out += P_B_CLOSE
	if out.count(P_I_OPEN) > out.count(P_I_CLOSE):
		out += P_I_CLOSE
	return out.replace(P_B_OPEN, "[b]").replace(P_B_CLOSE, "[/b]").replace(P_I_OPEN, "[i]").replace(P_I_CLOSE, "[/i]").replace(P_C_OPEN, "[code]").replace(P_C_CLOSE, "[/code]")


# ------------------------------ 输入 / 焦点 ------------------------------
## 打开状态下输入框是否握着焦点（对局的热键守卫据此让路）
func input_focused() -> bool:
	return _open and _input != null and _input.has_focus()


## 键盘事件入口（由 AiAssistant 在 _input 里调用；返回 true 表示已处理，调用方应 set_input_as_handled）。
## 本控件自身 mouse_filter = IGNORE、抽屉也不抢焦点，所以键盘统一从这里过一道：
##   * Esc：先松开输入焦点，再关抽屉；
##   * 其余按键：只要输入框有焦点就截断（否则对局热键会在打字时误触发，如空格 = 结束回合）。
func handle_key(event: InputEvent) -> bool:
	if not _open:
		return false
	if not (event is InputEventKey):
		return false
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return false
	if key.keycode == KEY_ESCAPE:
		if _input != null and _input.has_focus():
			_input.release_focus()
		else:
			close()
		return true
	return input_focused()
