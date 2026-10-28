class_name StatusPanel
extends Control
## 状态信息框：竞技区角上的一块小面板，2×2 显示**牌库 / 手牌 / 墓地 / 疲劳**。
##
## 照参考图里的计数块做的：深色半透明底 + 金属描边，每格左边一枚**手绘图标**
## （牌库＝叠牌 / 手牌＝扇形牌 / 墓地＝墓碑 / 疲劳＝火苗），右边是「牌36」这样的读数。
## 位置（由 Main / 场景锚点决定）：敌方在主战者框右上方、我方在左下方，
## 与主战者框分开，头像盘里只留名字与血量 / 护甲 —— 参考影之诗把计数做成边缘信息块的做法。
##
## 样式与文字沿用 `StatusCounters` 里那一处定义（文案 + 配色 + 关键状态变色），
## 所以这里只负责“把四个格子摆好并显示出来”。

const PANEL_SIZE := Vector2(112, 52)
const CELL_SIZE := Vector2(52, 22)
const CELL_GAP := 2.0
const FONT_SIZE := 10
const PAD := 2.0
## 图标占的宽度（读数往右让出这一段）
const ICON_W := 13.0

const COLOR_ACCENT_ENEMY := Color("#e57373")
const COLOR_ACCENT_PLAYER := Color("#64b5f6")
const COLOR_BG := Color(0.07, 0.10, 0.09, 0.94)

var player_id := 0

var _deck: Label
var _hand: Label
var _grave: Label
var _fatigue: Label
var _frame_style := StyleBoxFlat.new()
var _cell_style := StyleBoxFlat.new()
## 每格图标的颜色（跟着读数变色，见 update_state）
var _icon_colors := [Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]
## 计数图标的画法（刻意不写 class_name，用 preload 保证任何环境都能跑）
const CounterIconsRef := preload("res://scripts/CounterIcons.gd")


func _ready() -> void:
	# 纯展示：不吃鼠标事件，底下的卡牌 / 战场照常操作
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = PANEL_SIZE
	size = PANEL_SIZE
	_build()


func setup(pid: int) -> void:
	player_id = pid
	_apply_accent()
	queue_redraw()


## 边框用所属一侧的强调色（敌方红 / 我方蓝），与主战者框同色
func _apply_accent() -> void:
	var accent: Color = COLOR_ACCENT_ENEMY if player_id == GameManager.ENEMY_ID else COLOR_ACCENT_PLAYER
	_frame_style.border_color = Color(accent.r, accent.g, accent.b, 0.55)


func _build() -> void:
	_frame_style.bg_color = COLOR_BG
	_frame_style.set_border_width_all(2)
	_frame_style.set_corner_radius_all(8)
	_frame_style.anti_aliasing = true
	_frame_style.shadow_color = Color(0, 0, 0, 0.45)
	_frame_style.shadow_size = 3
	_frame_style.shadow_offset = Vector2(0, 2)
	_apply_accent()

	_cell_style.bg_color = Color(0.10, 0.13, 0.17, 0.92)
	_cell_style.border_color = Color(0.45, 0.50, 0.58, 0.6)
	_cell_style.set_border_width_all(1)
	_cell_style.set_corner_radius_all(5)
	_cell_style.anti_aliasing = true

	_deck = _make_cell(0)
	_hand = _make_cell(1)
	_grave = _make_cell(2)
	_fatigue = _make_cell(3)


func _make_cell(index: int) -> Label:
	var col: int = index % 2
	var row: int = index / 2
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.position = Vector2(PAD + float(col) * (CELL_SIZE.x + CELL_GAP) + ICON_W,
		PAD + float(row) * (CELL_SIZE.y + CELL_GAP))
	label.size = Vector2(CELL_SIZE.x - ICON_W, CELL_SIZE.y)
	add_child(label)
	return label


func update_state(p: PlayerState, hand_limit: int) -> void:
	if p == null or _deck == null:
		return
	_deck.text = StatusCounters.deck_text(p)
	_hand.text = StatusCounters.hand_text(p)
	_grave.text = StatusCounters.grave_text(p)
	_fatigue.text = StatusCounters.fatigue_text(p)
	_deck.add_theme_color_override("font_color", StatusCounters.deck_color(p))
	_hand.add_theme_color_override("font_color", StatusCounters.hand_color(p, hand_limit))
	_grave.add_theme_color_override("font_color", StatusCounters.grave_color(p))
	_fatigue.add_theme_color_override("font_color", StatusCounters.fatigue_color(p))
	_icon_colors = [
		StatusCounters.deck_color(p), StatusCounters.hand_color(p, hand_limit),
		StatusCounters.grave_color(p), StatusCounters.fatigue_color(p),
	]
	queue_redraw()


# 供布局测试核对读数
func deck_text() -> String:
	return "" if _deck == null else _deck.text


func hand_text() -> String:
	return "" if _hand == null else _hand.text


func grave_text() -> String:
	return "" if _grave == null else _grave.text


func fatigue_text() -> String:
	return "" if _fatigue == null else _fatigue.text


func _draw() -> void:
	draw_style_box(_frame_style, Rect2(Vector2.ZERO, size))
	for i in 4:
		var col: int = i % 2
		var row: int = i / 2
		var r := Rect2(Vector2(PAD + float(col) * (CELL_SIZE.x + CELL_GAP), PAD + float(row) * (CELL_SIZE.y + CELL_GAP)), CELL_SIZE)
		draw_style_box(_cell_style, r)
		_draw_icon(i, r)


## 每格左边的手绘图标（牌库 / 手牌 / 墓地 / 疲劳），颜色跟着读数走；
## 画法与记牌器的计数条共用 `CounterIcons`，两处永远是一致的。
func _draw_icon(index: int, cell: Rect2) -> void:
	var col: Color = _icon_colors[index] if index < _icon_colors.size() else Color.WHITE
	CounterIconsRef.draw_icon(self, index, cell, col)

