extends Control
## 「发现」三选一弹窗（炉石 / 影之诗风格）：展示若干候选卡，点一张即选中。
##
## 只负责展示与选择；选完发 `picked(index)`，由主界面决定是本地结算还是把意图发给房主。
## 复用 `Card.tscn` 的卡面，所以外观与手牌一致。

signal picked(index: int)
signal closed()

const CARD_SCENE := preload("res://scenes/Card.tscn")

var options: Array = []
var _row: HBoxContainer
var _hint: Label
var _cards: Array = []


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
	box.custom_minimum_size = Vector2(660, 300)
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
	v.add_theme_constant_override("separation", 8)
	box.add_child(v)

	var title := Label.new()
	title.text = "发现"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("#ffee58"))
	v.add_child(title)

	_hint = Label.new()
	_hint.text = "从下面这些卡牌里选一张加入手牌"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color(0.75, 0.79, 0.85))
	v.add_child(_hint)

	var row_center := CenterContainer.new()
	row_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(row_center)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 14)
	row_center.add_child(_row)


## 打开并展示候选（每张都会建一个可点卡面）
func open(cards: Array) -> void:
	options = cards
	for child in _row.get_children():
		child.queue_free()
	_cards.clear()
	for i in options.size():
		var ui := CARD_SCENE.instantiate()
		if ui == null:
			continue
		_row.add_child(ui)
		ui.setup(options[i], i, true)
		ui.clicked.connect(_on_card_clicked)
		_cards.append(ui)
	_hint.text = "从下面这 %d 张里选一张加入手牌" % options.size()
	visible = true


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func card_buttons() -> Array:
	return _cards


func _on_card_clicked(index: int) -> void:
	if index < 0 or index >= options.size():
		return
	close()
	picked.emit(index)


## 供测试 / 调试：直接按序号选一张
func choose(index: int) -> void:
	_on_card_clicked(index)
