class_name MulliganDialog
extends Control
## 起手换牌面板：开局抽完 4 张后弹出，点选想换掉的牌，确认后由主界面洗回牌库重抽。
##
## 纯展示 + 一个选择状态：真正的换牌逻辑在 `GameManager.mulligan_replace()`。
## 面板铺满整个竞技区并吃掉鼠标事件，确认之前玩家点不到底下的手牌 / 战场。

signal confirmed(cards: Array)   ## 参数是“要换掉的卡牌对象”（按对象换牌，抗下标漂移）

const CARD_SCENE := preload("res://scenes/Card.tscn")
const CARD_SCALE := 1.0
const TITLE := "起手换牌"
const HINT := "点击想换掉的牌（可多选），确认后洗回牌库重抽同样张数；不想换就直接「全部保留」。"

var _cards: Array[CardData] = []
var _uis: Array[CardUI] = []
var _picked: Array[int] = []
var _open := false
var _row: HBoxContainer
var _confirm_btn: Button
var _title_label: Label
var _hint_label: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP      # 吃住鼠标：确认前不允许操作底下的牌
	visible = false
	_build()


func _build() -> void:
	var backdrop := Panel.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bd := StyleBoxFlat.new()
	bd.bg_color = Color(0.02, 0.03, 0.05, 0.72)
	backdrop.add_theme_stylebox_override("panel", bd)
	add_child(backdrop)

	# 用 CenterContainer 居中：直接给 PanelContainer 设居中锚点时，它会以屏幕中心为左上角往右下长
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(760, 300)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.11, 0.15, 0.98)
	style.border_color = Color(0.32, 0.38, 0.46, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	box.add_child(vbox)

	_title_label = Label.new()
	_title_label.text = TITLE
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 20)
	_title_label.add_theme_color_override("font_color", Color("#ffee58"))
	vbox.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.text = HINT
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_font_size_override("font_size", 12)
	_hint_label.add_theme_color_override("font_color", Color(0.75, 0.79, 0.85))
	vbox.add_child(_hint_label)

	var row_center := CenterContainer.new()
	row_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(row_center)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 14)
	row_center.add_child(_row)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	vbox.add_child(buttons)

	_confirm_btn = Button.new()
	_confirm_btn.custom_minimum_size = Vector2(180, 34)
	_confirm_btn.pressed.connect(_on_confirm)
	buttons.add_child(_confirm_btn)

	var keep := Button.new()
	keep.text = "全部保留"
	keep.custom_minimum_size = Vector2(140, 34)
	keep.pressed.connect(skip)
	buttons.add_child(keep)


# ------------------------------ 打开 / 交互 ------------------------------

func open(cards: Array[CardData]) -> void:
	_cards = cards
	_picked.clear()
	for child in _row.get_children():
		child.queue_free()
	_uis.clear()
	for i in _cards.size():
		# 必须用 Card.tscn 实例化：CardUI 的标签都在场景里，直接 new() 出来没有子节点
		var ui := CARD_SCENE.instantiate() as CardUI
		if ui == null:
			continue
		_row.add_child(ui)
		ui.setup(_cards[i], i, true)
		ui.scale = Vector2(CARD_SCALE, CARD_SCALE)
		ui.clicked.connect(_on_card_clicked)
		_uis.append(ui)
	_open = true
	visible = true
	_update_buttons()


func close() -> void:
	_open = false
	visible = false


func is_open() -> bool:
	return _open


func card_buttons() -> Array[CardUI]:
	return _uis


func picked_indices() -> Array[int]:
	return _picked.duplicate()


func toggle(i: int) -> void:
	if i < 0 or i >= _cards.size():
		return
	if _picked.has(i):
		_picked.erase(i)
	else:
		_picked.append(i)
	_uis[i].set_selected(_picked.has(i))
	_update_buttons()


func _on_card_clicked(index: int) -> void:
	toggle(index)


func _on_confirm() -> void:
	_confirm_picks(picked_cards())


## 一张都不换（面板上的「全部保留」/ 测试里跳过）
func skip() -> void:
	_confirm_picks([])


## 选中的卡牌对象（主界面按对象换牌）
func picked_cards() -> Array:
	var out := []
	for i in _picked:
		out.append(_cards[i])
	return out


func _confirm_picks(cards: Array) -> void:
	if not _open:
		return
	close()
	confirmed.emit(cards)


func _update_buttons() -> void:
	if _confirm_btn == null:
		return
	# 没选牌时「确认换牌」不可用，保留 → 用右边的「全部保留」
	_confirm_btn.disabled = _picked.is_empty()
	if _picked.is_empty():
		_confirm_btn.text = "请先点选要换的牌"
	else:
		_confirm_btn.text = "确认换掉这 %d 张" % _picked.size()
