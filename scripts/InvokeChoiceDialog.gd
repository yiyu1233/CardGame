extends Control
## 瞬念召唤「基础机制 = 由玩家选择去向」的三选一弹窗：保留在场 / 返回手牌 / 进入墓地。
##
## 只负责展示与选择；选完发 `picked(dest)`，由主界面决定是本地结算还是把意图发给房主。
## 与 DiscoverDialog 同一套外观（居中面板 + 变暗背景），选择期间挡住底下的操作。

signal picked(dest: int)
signal closed()

## 玩家能选的三项（CHOOSE 本身不再出现在选项里）
const CHOICES := [CardData.InvokeDest.KEEP, CardData.InvokeDest.HAND,
	CardData.InvokeDest.GRAVEYARD]

var _buttons: Array = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP      # 选择期间挡住底下的操作
	visible = false
	_build()


func _build() -> void:
	var backdrop := Panel.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bd := StyleBoxFlat.new()
	bd.bg_color = Color(0.02, 0.03, 0.05, 0.78)
	backdrop.add_theme_stylebox_override("panel", bd)
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(420, 180)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.11, 0.15, 0.98)
	style.border_color = Color(0.62, 0.48, 0.20, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	box.add_child(v)

	var title := Label.new()
	title.text = "瞬念召唤"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("#ffee58"))
	v.add_child(title)

	var hint := Label.new()
	hint.text = "这张卡已经上场，选择它的归宿（不选则留在场上）"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.75, 0.79, 0.85))
	v.add_child(hint)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	v.add_child(row)

	_buttons.clear()
	for dest in CHOICES:
		var b := Button.new()
		b.text = CardData.INVOKE_DEST_NAMES[dest]
		b.custom_minimum_size = Vector2(110, 40)
		b.pressed.connect(func() -> void: _on_pressed(dest))
		row.add_child(b)
		_buttons.append(b)


func open() -> void:
	visible = true


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


## 供测试 / 调试：拿三个按钮
func choice_buttons() -> Array:
	return _buttons


func _on_pressed(dest: int) -> void:
	close()
	picked.emit(dest)


## 供测试 / 调试：直接选一个去向
func choose(dest: int) -> void:
	_on_pressed(dest)
