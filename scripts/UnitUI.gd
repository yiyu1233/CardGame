class_name UnitUI
extends PanelContainer
## 战场上一个随从的显示控件（代码构建，无需独立场景文件）。

signal unit_clicked(unit_id: int)
signal unit_right_clicked(unit_id: int)
signal unit_drag_started(unit_id: int)   ## 拖拽我方随从到敌方目标发起攻击
signal unit_hovered(data: CardData, rect: Rect2)   ## 鼠标悬停：请求显示完整效果
signal unit_hover_ended()

const UNIT_SIZE := Vector2(104, 132)
const DRAG_THRESHOLD := 8.0

var unit: BoardUnit
var owner_friendly := false
var can_attack := false
var highlighted := false
var dragging := false
var frozen := false
var stealthed := false   ## 潜行：无法被敌方指定为目标，画成半透明便于识别
var in_front := false    ## 横置格：画成横放的牌（旋转 90°），只受 1 点伤害、无法攻击
## `setup()` 传入的当前回合数：主动技能徽章据此判断「本回合是否已经发动过」
var current_turn := 0

var _press_pos := Vector2.ZERO
var _pressing := false
var _drag_began := false

var _name_label: Label
var _keyword_label: Label
var _atk_label: Label
var _hp_label: Label
var _frame_color := Color("#5d4037")
## 卡图（`ArtStore.art_for()` 解析出来的那张；`setup()` 时查一次并缓存，避免每帧查文件）
var _art_tex: Texture2D = null
## 技能角标：`_badge_layer` 是一块**普通 Control**（不是 Container），
## 所以它自己不会把角标的最小尺寸算进卡面的最小尺寸里——`UNIT_SIZE` 因此保持不变。
var _badge_layer: Control
var _skill_badge: PanelContainer
var _skill_badge_label: Label


func _ready() -> void:
	custom_minimum_size = UNIT_SIZE
	pivot_offset = UNIT_SIZE * 0.5
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_build()
	# 随从卡面里的标签 / 撑高占位 Control / 中缝同样是纯装饰：
	# 普通 Control 默认 STOP，会把「按住随从中间往敌方拖」的按下与拖动事件吃掉。
	UiUtil.make_decorative(self)


func setup(u: BoardUnit, friendly: bool, turn: int, my_turn: bool) -> void:
	unit = u
	owner_friendly = friendly
	current_turn = turn
	can_attack = friendly and my_turn and u.can_attack(turn, true)
	frozen = u.is_frozen(turn)
	stealthed = u.has_mechanic(CardData.Keyword.STEALTH)
	# 卡图只在这里查一次（`ArtStore.texture` 自带缓存），之后每帧只是画一张贴图
	_art_tex = ArtStore.texture(ArtStore.art_for(u.data)) if u.data != null else null
	_refresh()


## 战场卡面：把这张卡的卡图淡淡地铺在卡面底部（**不建任何子节点**，所以布局 / 命中判定不变）
func _draw() -> void:
	if _art_tex == null or size.x < 8.0 or size.y < 8.0:
		return
	var inset := 4.0
	var r := Rect2(Vector2(inset, inset), size - Vector2(inset * 2.0, inset * 2.0))
	var alpha := 0.34 if dragging else (0.30 if stealthed else 0.52)
	draw_texture_rect_region(_art_tex, r, _cover_src(_art_tex, r.size), Color(1, 1, 1, alpha))


## 等比裁切（cover）的源矩形：把方形的卡图铺满卡面矩形而不变形
func _cover_src(tex: Texture2D, target: Vector2) -> Rect2:
	var ts := tex.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0 or target.x <= 0.0 or target.y <= 0.0:
		return Rect2(Vector2.ZERO, ts)
	var ta := target.x / target.y
	var sa := ts.x / ts.y
	if sa > ta:
		var w := ts.y * ta
		return Rect2((ts.x - w) * 0.5, 0.0, w, ts.y)
	var h := ts.x / ta
	return Rect2(0.0, (ts.y - h) * 0.5, ts.x, h)


func _build() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_name_label)

	_keyword_label = Label.new()
	_keyword_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_keyword_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_keyword_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(_keyword_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	var footer := HBoxContainer.new()
	vbox.add_child(footer)

	_atk_label = Label.new()
	_atk_label.add_theme_color_override("font_color", Color("#ffe082"))
	footer.add_child(_atk_label)

	var mid := Control.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(mid)

	_hp_label = Label.new()
	_hp_label.add_theme_color_override("font_color", Color("#ef9a9a"))
	footer.add_child(_hp_label)

	_build_skill_badge()


## 卡面右上角的「技能」角标（有主动技能的单位才显示）。
## 放在一层**普通 Control** 里：PanelContainer 只按直接子节点的最小尺寸算自己的最小尺寸，
## 而普通 Control 的最小尺寸恒为 `custom_minimum_size`（这里是 0），
## 所以角标完全不会把卡面撑大（`UNIT_SIZE` 与世界布局保持不变）。
func _build_skill_badge() -> void:
	_badge_layer = Control.new()
	_badge_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_badge_layer)                 # 加在 margin 之后 → 叠在卡面内容之上
	_badge_layer.resized.connect(_place_skill_badge)

	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(7)
	style.set_border_width_all(1)
	style.content_margin_left = 5
	style.content_margin_right = 5
	style.content_margin_top = 1
	style.content_margin_bottom = 1
	style.bg_color = Color(0.99, 0.76, 0.35, 0.95)
	style.border_color = Color("#ffe082")

	_skill_badge = PanelContainer.new()
	_skill_badge.add_theme_stylebox_override("panel", style)
	_skill_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_badge.visible = false            # `_refresh()` 里按单位是否带技能再显示
	_badge_layer.add_child(_skill_badge)

	_skill_badge_label = Label.new()
	_skill_badge_label.text = "技能"
	_skill_badge_label.add_theme_font_size_override("font_size", 12)
	_skill_badge_label.add_theme_color_override("font_color", Color("#3e2a10"))
	_skill_badge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skill_badge.add_child(_skill_badge_label)
	_place_skill_badge()


## 角标贴在卡面右上角（卡面尺寸变化时由 `resized` 重算）
func _place_skill_badge() -> void:
	if _skill_badge == null or _badge_layer == null or not is_instance_valid(_badge_layer):
		return
	var s: Vector2 = _skill_badge.get_combined_minimum_size()
	_skill_badge.size = s
	_skill_badge.position = Vector2(maxf(0.0, _badge_layer.size.x - s.x - 3.0), 3.0)


## 卡面是否带「技能」角标（= 这张卡声明了主动技能）——供测试断言
func has_skill_badge() -> bool:
	return _skill_badge != null and _skill_badge.visible


## 技能本回合是否还没发动（角标亮着 = 现在点它就能发动）——供测试断言
func skill_ready() -> bool:
	return has_skill_badge() and not _skill_used_this_turn()


func _refresh() -> void:
	if unit == null:
		return
	_name_label.text = unit.data.card_name

	var tags := PackedStringArray()
	for k in unit.keywords:
		tags.append(CardData.KEYWORD_NAMES.get(k, str(k)))
	if unit.divine_shield and not tags.has("圣盾"):
		tags.append("圣盾")
	if frozen:
		tags.append("❄冻结")
	if stealthed and not tags.has("潜行"):
		tags.append("潜行")
	if in_front and not tags.has("横置"):
		tags.append("横置")
	_keyword_label.text = " ".join(tags)

	# 护符 / 城邦：没有攻击力，只显示耐久
	if unit.is_permanent():
		_atk_label.text = unit.data.type_name()
		_hp_label.text = "耐久 %d" % unit.durability()
	else:
		_atk_label.text = "⚔%d" % unit.attack
		_hp_label.text = "❤%d" % maxi(0, unit.health)
	# 拖拽中半透明；潜行的随从整体压暗，一眼能看出“现在打不到它”
	if dragging:
		modulate = Color(1.0, 1.0, 1.0, 0.32)
	elif stealthed:
		modulate = Color(0.72, 0.72, 0.85, 0.85)
	else:
		modulate = Color.WHITE
	if unit.health < unit.max_health:
		_hp_label.add_theme_color_override("font_color", Color("#ef5350"))
	else:
		_hp_label.add_theme_color_override("font_color", Color("#a5d6a7"))
	if can_attack:
		_name_label.add_theme_color_override("font_color", Color("#b9f6ca"))
	else:
		_name_label.add_theme_color_override("font_color", Color("#ffffff"))
	_apply_style()
	_refresh_skill_badge()


## 技能角标：有技能才显示；本回合已经发动过 → 压暗成「已用过」的样式
## （沿用 `set_front` / `set_highlight` 那套「同一个控件只换配色」的做法）。
func _refresh_skill_badge() -> void:
	if _skill_badge == null:
		return
	var has_skill: bool = _unit_has_skill()
	_skill_badge.visible = has_skill
	if not has_skill:
		return
	var ready_now: bool = skill_ready()
	# 角标直接写出花费：`技能 2PP`（0 = 免费技能，只写「技能」）——
	# 玩家一眼就知道点它要花多少 PP（能量点 = 法力），不用去翻详情
	var cost := 0
	if unit != null and unit.data != null and unit.data.has_skill():
		cost = unit.data.skill_cost()
	if _skill_badge_label != null:
		_skill_badge_label.text = "技能 %dPP" % cost if cost > 0 else "技能 免费"
		_place_skill_badge()
	var style := _skill_badge.get_theme_stylebox("panel") as StyleBoxFlat
	if style != null:
		style.bg_color = Color(0.99, 0.76, 0.35, 0.95) if ready_now else Color(0.24, 0.24, 0.28, 0.9)
		style.border_color = Color("#ffe082") if ready_now else Color(0.42, 0.42, 0.48)
	if _skill_badge_label != null:
		_skill_badge_label.add_theme_color_override("font_color",
			Color("#3e2a10") if ready_now else Color(0.62, 0.62, 0.68))
	_skill_badge.modulate = Color.WHITE if ready_now else Color(0.9, 0.9, 0.95, 0.9)


## 这张卡是否声明了主动技能。规则层（CardData.has_skill）与界面并行开发中，
## 所以用 `has_method()` 兜底：接口还没落地时按「没有技能」处理，不会崩。
func _unit_has_skill() -> bool:
	if unit == null or unit.data == null or not unit.data.has_method("has_skill"):
		return false
	return bool(unit.data.call("has_skill"))


## 本回合是否已经发动过技能（`BoardUnit.skill_used_turn == 当前回合数`）。
## `skill_used_turn` 还没落地时按「没发动过」处理。
func _skill_used_this_turn() -> bool:
	if unit == null or current_turn <= 0:
		return false
	var used: Variant = unit.get("skill_used_turn")
	if used == null:
		return false
	return int(used) == current_turn


func _apply_style() -> void:
	var style := StyleBoxFlat.new()
	style.set_corner_radius_all(8)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_width_top = 3
	style.border_width_bottom = 3

	if highlighted:
		style.border_color = Color("#ffee58")
		style.bg_color = Color(0.35, 0.3, 0.15, 1.0)
	elif in_front:
		style.border_color = Color("#ffca28")
		style.bg_color = Color(0.24, 0.20, 0.10, 1.0)
	elif frozen:
		style.border_color = Color("#4fc3f7")
		style.bg_color = Color(0.13, 0.20, 0.26, 1.0)
	elif unit != null and unit.is_permanent():
		# 护符 / 城邦：褐色 / 紫色边框，一眼和随从区分开
		if unit.data.is_city():
			style.border_color = Color("#9575cd")
			style.bg_color = Color(0.20, 0.17, 0.28, 1.0)
		else:
			style.border_color = Color("#a1887f")
			style.bg_color = Color(0.21, 0.19, 0.17, 1.0)
	elif can_attack:
		style.border_color = Color("#66bb6a")
		style.bg_color = Color(0.16, 0.22, 0.16, 1.0)
	elif unit != null and unit.is_taunt():
		style.border_color = Color("#90a4ae")
		style.bg_color = Color(0.20, 0.22, 0.26, 1.0)
	elif owner_friendly:
		style.border_color = Color("#546e7a")
		style.bg_color = Color(0.15, 0.18, 0.22, 1.0)
	else:
		style.border_color = Color("#7e57c2")
		style.bg_color = Color(0.22, 0.16, 0.25, 1.0)
	add_theme_stylebox_override("panel", style)
	# 卡图要透出来：底色留一点透明度（文字底下仍有一层暗色，可读性不受影响）
	var bg := style.bg_color
	style.bg_color = Color(bg.r, bg.g, bg.b, 0.80)
	queue_redraw()


func set_highlight(enabled: bool) -> void:
	highlighted = enabled
	scale = Vector2(1.08, 1.08) if enabled else Vector2.ONE
	_refresh()


## 横置：整张牌旋转 90°、略微缩小以落在正中那一格里，并用暖色边框区分
func set_front(enabled: bool) -> void:
	in_front = enabled
	if in_front and not highlighted:
		rotation = PI * 0.5
		scale = Vector2(0.8, 0.8)
	else:
		rotation = 0.0
		scale = Vector2(1.08, 1.08) if highlighted else Vector2.ONE
	_refresh()


func set_dragging(enabled: bool) -> void:
	dragging = enabled
	# 走 _refresh 而不是直接改 modulate，避免覆盖掉潜行的压暗效果
	_refresh()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_pos = event.position
				_pressing = true
				_drag_began = false
			elif _pressing:
				_pressing = false
				if not _drag_began:
					unit_clicked.emit(unit.unit_id)
				accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			unit_right_clicked.emit(unit.unit_id)
			accept_event()
	elif event is InputEventMouseMotion:
		if _pressing and not _drag_began and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_drag_began = true
			unit_drag_started.emit(unit.unit_id)
			accept_event()


func _on_mouse_entered() -> void:
	if not highlighted and not dragging:
		scale = Vector2(1.05, 1.05)
	unit_hovered.emit(unit.data, get_global_rect())


func _on_mouse_exited() -> void:
	if not highlighted and not dragging:
		scale = Vector2.ONE
	unit_hover_ended.emit()
