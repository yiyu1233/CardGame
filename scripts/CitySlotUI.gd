class_name CitySlotUI
extends PanelContainer
## 主战者旁的「城邦格」：最多放一个城邦，**不占 7 格战场**。
##
## 照参考图里主战者旁边那块「插槽」的感觉重做：
##   * 左边一枚**圆形插槽**（空着时是一枚紫色虚位纹章；放了城邦就显示它的**卡图缩略**，
##     右下角挂一个耐久小徽章）；
##   * 右边两行字：卡名 + 耐久（空置时是「城邦格」+「距下次 N 回合」）。
##
## 它和战场上的随从控件一样参与交互：可以悬停看详情、可以在指定目标时被点选
## （格子里的城邦照常可被指定 / 被攻击 / 被解掉）。

signal unit_clicked(unit_id: int)
signal unit_hovered(data: CardData, rect: Rect2)
signal unit_hover_ended()

const SLOT_SIZE := Vector2(126, 50)
## 左侧插槽的几何（相对控件左上角）
const SOCKET_POS := Vector2(6, 7)
const SOCKET_SIZE := Vector2(36, 36)

const COLOR_TRIM_EMPTY := Color(0.62, 0.55, 0.86, 0.55)
const COLOR_TRIM_FULL := Color("#b39ddb")
const COLOR_TRIM_HOT := Color("#ffee58")
const COLOR_BG_EMPTY := Color(0.10, 0.10, 0.15, 0.9)
const COLOR_BG_FULL := Color(0.16, 0.13, 0.22, 0.96)

var unit: BoardUnit = null
var friendly := false
var highlighted := false

var _title: Label
var _sub: Label
var _art: TextureRect = null
var _frame_style := StyleBoxFlat.new()
var _socket_style := StyleBoxFlat.new()


func _ready() -> void:
	custom_minimum_size = SLOT_SIZE
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_build()
	_refresh()
	# 内部标签是装饰，鼠标事件交给本控件自己处理
	UiUtil.make_decorative(self)


func _build() -> void:
	_frame_style.set_corner_radius_all(10)
	_frame_style.set_border_width_all(2)
	_frame_style.anti_aliasing = true

	_socket_style.bg_color = Color(0.05, 0.05, 0.09, 0.95)
	_socket_style.border_color = COLOR_TRIM_EMPTY
	_socket_style.set_border_width_all(2)
	_socket_style.set_corner_radius_all(9)
	_socket_style.anti_aliasing = true

	# 文字整体让开左侧插槽
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", int(SOCKET_POS.x + SOCKET_SIZE.x + 6.0))
	margin.add_theme_constant_override("margin_right", 5)
	margin.add_theme_constant_override("margin_top", 3)
	margin.add_theme_constant_override("margin_bottom", 3)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	margin.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 13)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.clip_text = true
	box.add_child(_title)

	_sub = Label.new()
	_sub.add_theme_font_size_override("font_size", 11)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.clip_text = true
	_sub.add_theme_color_override("font_color", Color(0.78, 0.78, 0.86))
	box.add_child(_sub)


## `u` 为 null 表示格子空着；`hint` 是空置时的提示（距下次召唤还有几个回合）
func setup(u: BoardUnit, p_friendly: bool, hint: String = "") -> void:
	unit = u
	friendly = p_friendly
	if unit == null:
		_title.text = "城邦格"
		_sub.text = hint if hint != "" else "空"
	else:
		_title.text = unit.data.card_name
		_sub.text = "耐久 %d" % unit.durability()
	_sync_art()
	_refresh()


## 插槽里的卡图缩略（有卡图才显示）
func _sync_art() -> void:
	var tex: Texture2D = null
	if unit != null and unit.data != null:
		tex = ArtStore.texture(ArtStore.art_for(unit.data))
	if tex == null:
		if _art != null:
			_art.visible = false
		return
	if _art == null:
		_art = TextureRect.new()
		_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		add_child(_art)
	_art.texture = tex
	_art.position = SOCKET_POS + Vector2(3, 3)
	_art.size = SOCKET_SIZE - Vector2(6, 6)
	_art.visible = true


func _refresh() -> void:
	var hot: bool = highlighted
	var full: bool = unit != null
	_frame_style.bg_color = COLOR_BG_FULL if full else COLOR_BG_EMPTY
	_frame_style.border_color = COLOR_TRIM_HOT if hot else (COLOR_TRIM_FULL if full else COLOR_TRIM_EMPTY)
	add_theme_stylebox_override("panel", _frame_style)
	_title.add_theme_color_override("font_color",
		COLOR_TRIM_HOT if hot else (Color("#d1c4e9") if full else Color(0.62, 0.60, 0.70)))
	_socket_style.border_color = COLOR_TRIM_HOT if hot else (COLOR_TRIM_FULL if full else COLOR_TRIM_EMPTY)
	queue_redraw()


func set_highlight(enabled: bool) -> void:
	highlighted = enabled
	_refresh()


func _on_mouse_entered() -> void:
	if unit != null:
		unit_hovered.emit(unit.data, get_global_rect())


func _on_mouse_exited() -> void:
	unit_hover_ended.emit()


func _gui_input(event: InputEvent) -> void:
	if unit == null:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		unit_clicked.emit(unit.unit_id)
		accept_event()


func _draw() -> void:
	var rect := Rect2(SOCKET_POS, SOCKET_SIZE)
	draw_style_box(_socket_style, rect)
	var c := rect.get_center()
	if unit == null:
		# 空置：一枚淡淡的「城」字纹章，一眼看出这里可以放城邦
		var font := get_theme_default_font()
		if font != null:
			var fs := 15
			var w: float = font.get_string_size("城", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, c + Vector2(-w * 0.5, fs * 0.36), "城",
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.72, 0.66, 0.92, 0.75))
		return
	# 有城邦：插槽内一圈亮环 + 右下角耐久徽章
	draw_arc(c, SOCKET_SIZE.x * 0.5 - 2.0, 0.0, TAU, 28, Color(0.78, 0.70, 0.98, 0.65), 1.5, true)
	var badge := Rect2(rect.end - Vector2(15, 13), Vector2(15, 13))
	draw_rect(badge, Color(0.05, 0.05, 0.09, 0.9))
	draw_rect(badge, COLOR_TRIM_FULL, false, 1.0)
	var font2 := get_theme_default_font()
	if font2 != null:
		var txt := "%d" % unit.durability()
		var fs2 := 10
		var w2: float = font2.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
		draw_string(font2, badge.get_center() + Vector2(-w2 * 0.5, fs2 * 0.36), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, Color(0.86, 0.82, 0.98))
