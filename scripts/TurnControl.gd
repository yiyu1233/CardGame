class_name TurnControl
extends Control
## 影之诗风格的回合控件：**圆形**的「结束回合」按钮 + 环绕它的能量点 + 按钮内的回合数。
##
## 放在中线右端的空白处（战场槽位右侧、两块战场之间的空档），因此：
##   * 它正好在中线上，和影之诗把回合按钮放在场地右侧中部一致；
##   * 右侧那一条本来就没有槽位，圆环不会压到任何随从，也不会挡到出牌 / 攻击的落点。
##
## 能量点复用 `ManaOrbs` 的状态判定与样式（`state_of` / `style_for`），
## 保证环上的水晶与其它地方的法力显示永远是同一套规则。

signal end_turn_pressed()

const CONTROL_SIZE := Vector2(120, 138)
const RING_CENTER := Vector2(60, 60)
const BUTTON_DIAMETER := 72.0
const RING_RADIUS := 50.0
const ORB_COUNT := ManaOrbs.ORB_COUNT

const COLOR_NUMBER := Color("#e8f5e9")
const COLOR_UNIT := Color("#c8e6c9")
const COLOR_CAPTION := Color("#b0bec5")
const COLOR_CAPTION_DIM := Color("#78909c")

var button: RoundButton
var _orbs: Array[Panel] = []
var _number: Label
var _unit: Label
var _caption: Label


func _ready() -> void:
	custom_minimum_size = CONTROL_SIZE
	size = CONTROL_SIZE
	# 自身不吃鼠标事件，让底下的战场照常拖拽；只有按钮本体接收点击
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _build() -> void:
	if button != null:
		return

	# 圆形按钮的四态样式由 RoundButton 统一提供（与中线左端的记牌器按钮共用）
	button = RoundButton.new()
	button.tone = RoundButton.Tone.GREEN
	button.diameter = BUTTON_DIAMETER
	button.text = ""
	button.size = Vector2(BUTTON_DIAMETER, BUTTON_DIAMETER)
	button.position = RING_CENTER - Vector2(BUTTON_DIAMETER, BUTTON_DIAMETER) * 0.5
	button.pressed.connect(func() -> void: end_turn_pressed.emit())
	add_child(button)

	# 能量点绕按钮一圈（从正上方开始顺时针）
	for i in ORB_COUNT:
		var orb := Panel.new()
		orb.custom_minimum_size = ManaOrbs.ORB_SIZE
		orb.size = ManaOrbs.ORB_SIZE
		var angle: float = -PI * 0.5 + TAU * float(i) / float(ORB_COUNT)
		orb.position = RING_CENTER + Vector2(cos(angle), sin(angle)) * RING_RADIUS \
			- ManaOrbs.ORB_SIZE * 0.5
		orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(orb)
		_orbs.append(orb)

	# 按钮内的回合数
	_number = _make_label(26, COLOR_NUMBER)
	_number.position = Vector2(10, 30)
	_number.size = Vector2(CONTROL_SIZE.x - 20, 32)
	_unit = _make_label(11, COLOR_UNIT)
	_unit.position = Vector2(10, 60)
	_unit.size = Vector2(CONTROL_SIZE.x - 20, 14)
	_unit.text = "回合"

	# 圆环下方的功能说明
	_caption = _make_label(11, COLOR_CAPTION)
	_caption.position = Vector2(0, CONTROL_SIZE.y - 18)
	_caption.size = Vector2(CONTROL_SIZE.x, 16)
	_caption.text = "结束回合"


func _make_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	add_child(l)
	return l


## 圆形按钮的四种状态样式：圆角半径取直径的一半即为正圆


# ------------------------------ 对外接口 ------------------------------

## 按钮里的回合数
func set_turn(turn: int) -> void:
	if button == null:
		_build()
	_number.text = "%d" % turn


## 环绕按钮的能量点（套用与 ManaOrbs 完全相同的状态规则）
func set_mana(mana: int, max_mana: int) -> void:
	if button == null:
		_build()
	for i in _orbs.size():
		_orbs[i].add_theme_stylebox_override("panel",
			ManaOrbs.style_for(ManaOrbs.state_of(i, mana, max_mana)))


## active = 现在可以结束回合；caption 显示在圆环下方
func set_active(active: bool, caption: String = "") -> void:
	if button == null:
		_build()
	button.disabled = not active
	_caption.text = caption if caption != "" else ("结束回合" if active else "对手回合")
	_caption.add_theme_color_override("font_color", COLOR_CAPTION if active else COLOR_CAPTION_DIM)
	queue_redraw()      # 光环跟着「能不能行动」变色


## 供布局测试核对：圆角半径是否等于半径（正圆）
func corner_radius() -> int:
	if button == null:
		return int(BUTTON_DIAMETER * 0.5)
	return button.corner_radius()


func orb_count() -> int:
	return _orbs.size()


## 供布局测试核对每颗水晶的状态样式
func orb_panels() -> Array[Panel]:
	return _orbs


func turn_text() -> String:
	return "" if _number == null else _number.text


func caption_text() -> String:
	return "" if _caption == null else _caption.text


## 圆钮背后的**发光光环**（照参考图里那颗发光的大圆：可行动时亮绿，对手回合时压暗）。
## 自己在 `_draw()` 里画，圆钮是子节点 → 光环天然在按钮之下、不挡任何点击。
func _draw() -> void:
	var c := RING_CENTER
	var active: bool = button != null and not button.disabled
	var base := Color("#7fe3a0") if active else Color(0.42, 0.50, 0.58)
	# 三层由外到内、由淡到浓的柔光
	for i in 3:
		var t := float(i + 1)
		var r: float = BUTTON_DIAMETER * 0.5 + 6.0 + t * 7.0
		draw_circle(c, r, Color(base.r, base.g, base.b, 0.055 * (4.0 - t)))
	draw_arc(c, BUTTON_DIAMETER * 0.5 + 5.0, 0.0, TAU, 48,
		Color(base.r, base.g, base.b, 0.55 if active else 0.28), 2.0, true)
