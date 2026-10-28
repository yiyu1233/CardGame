class_name TrackerPanel
extends PanelContainer
## 记牌器：从**右侧滑出**的侧边抽屉，贴在窗口右边缘，不遮挡中间的对战区域。
## 内容为 GameTracker 统计的本局双方已使用卡牌（种类 / 费用 / 类型 / 张数），
## 以及牌库剩余、手牌、墓地、疲劳、法力等对局信息。
##
## 为什么不用 Window：Window 是独立窗口，会居中弹出并正好压住场地中央。
## 抽屉挂在 DragLayer 上、用锚点贴右边缘，窗口尺寸变化时自己跟随；
## 打开/收起是一次短促的滑入滑出动画。
##
## 观感与尺寸参照 `docs/shadowverse-battle-ui.md` 的口径（原版是 NGUI 像素，抽屉只宽 300，
## 所以除颜色是【码】直取外，像素值都取「与项目现有 UI 一致、且更接近原版比例」的换算值，
## 每个数值在下面各自的注释里写明出处或换算依据）：
##   §13.6 状态栏 → `CommonPanel` / `HandCount` 的紧凑计数条；
##   §13.7 颜色表 → 手牌数三档变色、关键词高亮色；
##   §13.8 字体   → 主字体是衬线粗体，项目里没有该字体文件，只沿用字号层级。

## 宽度与右侧日志栏对齐（日志栏宽 300、距右边缘 10），这样抽屉只盖住日志栏，
## 不会压到中间的战场（战场最右侧 1118，抽屉最左侧 1130）。
const DRAWER_WIDTH := 300.0
const RIGHT_MARGIN := 10.0
const V_MARGIN := 8.0
const DEFAULT_SLIDE_TIME := 0.18
const TYPE_COLORS := {0: "#a5d6a7", 1: "#90caf9", 2: "#ffcc80"}

# --------------------------- 尺寸口径（报告 §13.6 / §13.8） ---------------------------
## 标题字号：原版 StatusPanel/Alert 的 label 28px 配面板 505px（§13.6 `ClassInfomationUIBase.cs:56-58`），
## 比例 28/505 ≈ 0.0555；抽屉内层宽 300-2*10=280，等比换算 ≈ 15.5 → 取 15。
const TITLE_FONT_SIZE := 15
## 分栏标题字号：比抽屉标题低一级（原版 Alert 的 label 28 与 StatusPanel 内的次级文字同为 28 一档，
## 此处按项目的「标题 17→14」既有层级缩小一档到 13）。
const SECTION_FONT_SIZE := 13
## 边框 10px 的强调竖条：原版 CommonPanel/StatusPanel 的装饰边框（§13.6）在抽屉里没有足够宽度做整圈，
## 只保留一条左侧色条作为层级提示；宽度按抽屉内层 280 的 1/28 ≈ 3.5 → 取 3。
const ACCENT_BAR_WIDTH := 3.0
## 字号：原版卡名（字母语言）fontSize = 32（§13.8 `Global.cs:456,652`），
## 面板基准 1920 宽 → 32/1920 = 1/60；抽屉内列宽按 300 计，等比 ≈ 5px 太小，
## 因此卡牌行取项目正文 12→11、提示 11→10（比原版更紧凑，不是照搬绝对值）。
const CARD_FONT_SIZE := 11
const TIP_FONT_SIZE := 10
## 计数条格子：原版 HandCount 面板 `(100,40,0)` 尺寸为【资源】（§13.6），
## 项目已有一处同口径的紧凑计数格 `StatusPanel.CELL_SIZE = (52,22)` / `FONT_SIZE = 10` /
## `CELL_GAP = 2`（scripts/StatusPanel.gd:12-15），本抽屉沿用同一档，
## 但抽屉要横排 4 格：格子高 18（比 22 更扁平，向 CommonPanel 的扁条靠），
## 宽度用 SIZE_EXPAND_FILL 在 4 等分里自适应（不小于 52）。
const COUNTER_CELL_MIN := Vector2(52, 18)
const COUNTER_FONT_SIZE := 10
const COUNTER_GAP := 2

# --------------------------- 颜色（报告 §13.7） ---------------------------
## 手牌数 0-6 = 白；出处 `ClassInfomationUIBase.cs:60-64`（§13.7）。原版白是 `white`（Global.cs:371）。
const HAND_COLOR_TIER0 := Color(1.0, 1.0, 1.0)
## 手牌数 7-8 = `(255/256,205/256,69/256,1)`，出处同上（§13.7）。
const HAND_COLOR_TIER1 := Color(255.0 / 256.0, 205.0 / 256.0, 69.0 / 256.0)
## 手牌数 9（及以上）= `(213/256,5/64,5/64,1)`，出处同上（§13.7）。
const HAND_COLOR_TIER2 := Color(213.0 / 256.0, 5.0 / 64.0, 5.0 / 64.0)
## 费用数字 / ×N 高亮：原版关键词高亮是 `[ffcd45]`，出处 `BattlePlayerView.cs:35`（§13.7）。
## BBCode 里要的是十六进制串，这里两处共用同一份定义，避免行内字面量和它漂移。
const COLOR_KEYWORD_HEX := "ffcd45"
## 两侧标题的强调色：沿用项目既有的黄色标题（项目口径，非报告数值）。
const COLOR_HEAD := Color("#ffee58")

signal closed()

## 滑入 / 滑出耗时；测试里设为 0 可立即到位（无头模式的帧步长不可控）
var slide_time: float = DEFAULT_SLIDE_TIME

var _open := false
var _tween: Tween = null

var _mine_head: Label
var _mine_body: RichTextLabel
var _foe_head: Label
var _foe_body: RichTextLabel
## 顶部摘要条的 4 个计数 Label（牌 / 手 / 墓 / 疲），两侧各一组
## （用无类型 Array 而不是 Array[Label]：`_make_section()` 经 Dictionary 传回，
## 无类型数组可以避免 Variant→typed array 的转换风险，元素类型由 _make_counter_row 保证）
var _mine_counters: Array = []
var _foe_counters: Array = []
## 计数条左侧的小图标（与 `_mine_counters` 一一对应；画法走 `CounterIcons`）
var _mine_icons: Array = []
var _foe_icons: Array = []
## 计数图标的控件类（刻意不写 class_name：新增全局类名要等编辑器重新扫描项目才生效）
const CounterIconScript := preload("res://scripts/CounterIcon.gd")
## 计数图标的画法 / 颜色口径
const CounterIconsRef := preload("res://scripts/CounterIcons.gd")


func _ready() -> void:
	# 贴窗口右边缘：锚点自己跟随窗口尺寸，不需要外部帮忙算坐标
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	focus_mode = Control.FOCUS_NONE
	visible = false
	_apply_offsets(_closed_left())
	_build_ui()
	GameTracker.tracker_changed.connect(refresh)
	GameManager.state_changed.connect(refresh)
	refresh()


# ------------------------------ 打开 / 收起 ------------------------------

func is_open() -> bool:
	return _open


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	refresh()
	_apply_offsets(_closed_left())
	_slide_to(_open_left(), false)


func close() -> void:
	if not _open:
		return
	_open = false
	_slide_to(_closed_left(), true)
	closed.emit()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


## 打开状态：抽屉左边缘相对窗口右边缘的偏移（负值 = 向左）
func _open_left() -> float:
	return -DRAWER_WIDTH - RIGHT_MARGIN


## 收起状态：整块移到窗口右侧之外
func _closed_left() -> float:
	return -RIGHT_MARGIN


func _apply_offsets(left: float) -> void:
	offset_left = left
	offset_right = left + DRAWER_WIDTH
	offset_top = V_MARGIN
	offset_bottom = -V_MARGIN


func _slide_to(left: float, hide_after: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if slide_time <= 0.0:
		_apply_offsets(left)
		if hide_after:
			visible = false
		return
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "offset_left", left, slide_time)
	_tween.parallel().tween_property(self, "offset_right", left + DRAWER_WIDTH, slide_time)
	if hide_after:
		_tween.tween_callback(func() -> void: visible = false)


# ------------------------------ 界面 ------------------------------

func _build_ui() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.10, 0.13, 0.97)
	style.border_color = Color(0.28, 0.32, 0.38, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	add_theme_stylebox_override("panel", style)

	# 外边距：原来 12/12/10/10，收紧到 10/10/8/8，把省下的横向空间让给计数条与卡牌行
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# 标题栏：原版 Alert 是 505×60 面板 + 462×28 label（§13.6 ClassInfomationUIBase.cs:56-58），
	# 是「一条窄横条，label 只占横条高度的一半左右」的层级；抽屉没有 505 那么宽，
	# 只借这个比例：色条 3 × 行高 20，标题 15，右侧一个 26×20 的紧凑关闭按钮。
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	var head_bar := ColorRect.new()
	head_bar.color = COLOR_HEAD
	head_bar.custom_minimum_size = Vector2(ACCENT_BAR_WIDTH, 20)
	header.add_child(head_bar)
	var title := Label.new()
	title.text = "记牌器"
	title.add_theme_font_size_override("font_size", TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", COLOR_HEAD)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.tooltip_text = "收起记牌器（Esc）"
	close_btn.custom_minimum_size = Vector2(26, 20)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.pressed.connect(close)
	header.add_child(close_btn)
	vbox.add_child(header)

	var tip := Label.new()
	tip.text = "本局双方各自打出过的卡牌（随从 / 法术 / 装备均计入）。"
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", TIP_FONT_SIZE)
	tip.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82, 1))
	vbox.add_child(tip)

	# 两侧上下排列：抽屉很窄，竖着放比并排两列更好读
	# （head/body 用带类型的局部变量接一次，避免从 Dictionary 取出 Variant 直接赋给带类型成员）
	var mine := _make_section()
	vbox.add_child(mine["root"] as Control)
	var mine_head: Label = mine["head"]
	var mine_body: RichTextLabel = mine["body"]
	_mine_head = mine_head
	_mine_body = mine_body
	_mine_counters = mine["counters"]
	_mine_icons = mine["icons"]

	var foe := _make_section()
	vbox.add_child(foe["root"] as Control)
	var foe_head: Label = foe["head"]
	var foe_body: RichTextLabel = foe["body"]
	_foe_head = foe_head
	_foe_body = foe_body
	_foe_counters = foe["counters"]
	_foe_icons = foe["icons"]

	# 标题栏、说明、分栏标题都是纯装饰：整体 IGNORE，点击穿透到抽屉自身（抽屉本身仍是 STOP，
	# 底下的战场/手牌不会被误触）；关闭按钮等交互控件不在这个子树里，不受影响。
	UiUtil.make_decorative(header)
	UiUtil.make_decorative(tip)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _make_section() -> Dictionary:
	var panel := PanelContainer.new()
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.12, 0.16, 1.0)
	style.border_color = Color(0.28, 0.32, 0.38, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", style)

	# 内边距 10/10/8/8 → 8/8/6/6：给计数条与卡牌行留出宽度
	var inner := MarginContainer.new()
	inner.add_theme_constant_override("margin_left", 8)
	inner.add_theme_constant_override("margin_right", 8)
	inner.add_theme_constant_override("margin_top", 6)
	inner.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(inner)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	inner.add_child(vbox)

	# 分栏标题行：左侧一条强调色条 + 标题，层级比抽屉标题低一档
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 5)
	var bar := ColorRect.new()
	bar.color = COLOR_HEAD
	bar.custom_minimum_size = Vector2(ACCENT_BAR_WIDTH, 16)
	head_row.add_child(bar)
	var head := Label.new()
	head.add_theme_font_size_override("font_size", SECTION_FONT_SIZE)
	head.add_theme_color_override("font_color", COLOR_HEAD)
	head_row.add_child(head)
	vbox.add_child(head_row)

	# 计数条：原版 `CommonPanel` / `HandCount`（§13.6）是一条紧凑横条，
	# 抽屉里没有整圈边框的余量，就用 4 个扁平小格横排（尺寸口径见文件头 COUNTER_CELL_* 注释）。
	var counters := _make_counter_row()
	vbox.add_child(counters["root"])

	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.scroll_active = true
	body.selection_enabled = false
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.fit_content = false
	body.add_theme_font_size_override("normal_font_size", CARD_FONT_SIZE)
	vbox.add_child(body)

	return {
		"root": panel,
		"head": head,
		"body": body,
		"counters": counters["cells"],
		"icons": counters["icons"],
	}


## 摘要计数条：4 个格子 = 牌 / 手 / 墓 / 疲，文案与配色统一走 StatusCounters
## （项目里那一处定义，牌库见底 / 手牌满 / 已有疲劳的变色规则不在这里重写一遍）。
func _make_counter_row() -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", COUNTER_GAP)
	var cells: Array = []
	var icons: Array = []
	for i in 4:
		var cell := PanelContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.custom_minimum_size = COUNTER_CELL_MIN
		var cell_style := StyleBoxFlat.new()
		cell_style.bg_color = Color(0.10, 0.13, 0.17, 0.92)
		cell_style.border_color = Color(0.45, 0.50, 0.58, 0.6)
		cell_style.set_border_width_all(1)
		cell_style.set_corner_radius_all(4)
		cell_style.content_margin_left = 4
		cell_style.content_margin_right = 4
		cell_style.content_margin_top = 1
		cell_style.content_margin_bottom = 1
		cell.add_theme_stylebox_override("panel", cell_style)
		# 行内：左边一枚图标（与状态信息框同一套画法）+ 读数
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 1)
		cell.add_child(line)
		var icon := CounterIconScript.new()
		icon.index = i
		line.add_child(icon)
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", COUNTER_FONT_SIZE)
		line.add_child(label)
		row.add_child(cell)
		cells.append(label)
		icons.append(icon)
	return {"root": row, "cells": cells, "icons": icons}


# ------------------------------ 内容 ------------------------------

func refresh() -> void:
	_refresh_side(GameManager.PLAYER_ID, _mine_head, _mine_body, _mine_counters, _mine_icons)
	_refresh_side(GameManager.ENEMY_ID, _foe_head, _foe_body, _foe_counters, _foe_icons)


func _refresh_side(pid: int, head: Label, body: RichTextLabel, counters: Array = [], icons: Array = []) -> void:
	if head == null or body == null:
		return
	var p: PlayerState = GameManager.get_player(pid)
	if p == null:
		head.text = ""
		body.text = ""
		return
	var who: String = "我方" if pid == GameManager.PLAYER_ID else "敌方 AI"

	_refresh_counters(p, counters, icons)

	# 每侧只取一次条目（entries() 会复制并排序），总数在同一次循环里累加
	var rows := GameTracker.entries(pid)
	var total := 0
	var lines := PackedStringArray()
	for e in rows:
		var type_id: int = int(e["type"])
		var tname: String = CardData.TYPE_NAMES[type_id] if type_id >= 0 and type_id < CardData.TYPE_NAMES.size() else "未知"
		var tcolor: String = TYPE_COLORS.get(type_id, "#cccccc")
		var count := int(e["count"])
		total += count
		# 卡牌行按原版卡面的三段比例排版（§13.4 `SBattleLoad.cs:335-344`：费用在右上、卡名居中、
		# 数字窄）：费用用小方块徽章、类型用彩色色块、右侧 ×N。
		# 抽屉只有 300 宽，做不成真正的圆角徽章控件，所以用 RichTextLabel 的行内
		# [bgcolor] 方块代替——好处是零子控件、滚动位置完全由现有逻辑保持。
		# 类型色块用 2 个全角方块 `█`：宽 = 2 × 字号 ≈ 22px、高 ≈ 1 个行高（≈14px），
		# 对应原版卡面右侧费用/类型徽章的「宽约为卡宽 1/10」比例（§13.4，卡宽按 200px 计）。
		lines.append("[bgcolor=#263238] [color=#%s]%d[/color] [/bgcolor][bgcolor=%s]██[/bgcolor] [color=#eceff1]%s[/color] [color=#90a4ae]%s[/color] [color=#%s]×%d[/color]" % [
			COLOR_KEYWORD_HEX, int(e["cost"]), tcolor, _esc(str(e["name"])), tname, COLOR_KEYWORD_HEX, count
		])
	head.text = "%s：已使用 %d 张 / %d 种" % [who, total, rows.size()]
	if lines.is_empty():
		lines.append("[color=#808080]本局还没有打出过卡牌。[/color]")

	lines.append("")
	lines.append("[color=#90a4ae]法力 %d/%d[/color]" % [p.mana, p.max_mana])

	# 内容没变就不要重设 text：RichTextLabel 重设会把滚动条弹回顶部，
	# 而本局每次 AI 行动都会刷新，玩家根本没法往下读。
	var rendered := "\n".join(lines)
	if body.text == rendered:
		return
	var keep: float = body.get_v_scroll_bar().value
	body.text = rendered
	body.get_v_scroll_bar().set_deferred("value", keep)


## 顶部摘要条：牌 / 手 / 墓 / 疲 四个计数（文案与「牌库见底 / 手牌已满 / 已有疲劳」的
## 关键状态变色沿用 StatusCounters），手牌数再叠一层报告 §13.7 的三档变色：
## 0-6 白、7-8 `(255,205,69)`、9+ `(213,20,20)`；手牌已满（≥ HAND_LIMIT）优先按项目的告警色。
func _refresh_counters(p: PlayerState, counters: Array, icons: Array = []) -> void:
	if counters.size() < 4:
		return
	counters[0].text = StatusCounters.deck_text(p)
	counters[1].text = StatusCounters.hand_text(p)
	counters[2].text = StatusCounters.grave_text(p)
	counters[3].text = StatusCounters.fatigue_text(p)
	var cols := CounterIconsRef.colors_for(p, GameManager.HAND_LIMIT)
	counters[0].add_theme_color_override("font_color", cols[0])
	counters[1].add_theme_color_override("font_color", _hand_color(p))
	counters[2].add_theme_color_override("font_color", cols[2])
	counters[3].add_theme_color_override("font_color", cols[3])
	# 图标跟着读数变色（手牌那枚用与读数相同的口径）
	for i in mini(icons.size(), 4):
		var col: Color = _hand_color(p) if i == 1 else cols[i]
		icons[i].set_color(col)


## 手牌数变色：先套项目既有的「已满」告警，再套报告 §13.7 的三档。
func _hand_color(p: PlayerState) -> Color:
	var warn: Color = StatusCounters.hand_color(p, GameManager.HAND_LIMIT)
	if warn != StatusCounters.COLOR_HAND:
		return warn
	return hand_count_color(p.hand.size())


## 手牌数颜色档位（出处 `ClassInfomationUIBase.cs:60-64`，见报告 §13.7）：
## 0-6 白 / 7-8 `(255,205,69)` / 9 及以上 `(213,20,20)`。
## 做成 static 便于单独核对（原版是在 SetHandCount 里按张数切色）。
static func hand_count_color(hand_size: int) -> Color:
	if hand_size >= 9:
		return HAND_COLOR_TIER2
	if hand_size >= 7:
		return HAND_COLOR_TIER1
	return HAND_COLOR_TIER0


## 卡名是管理端自由文本，可能含 "["，直接进 BBCode 会渲染错乱
static func _esc(text: String) -> String:
	return text.replace("[", "[lb]")
