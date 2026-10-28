class_name CardUI
extends PanelContainer
## 一张手牌的显示控件：负责外观与鼠标交互（拖拽出牌 / 左键出牌，右键取消选择）。

signal clicked(index: int)
signal right_clicked(index: int)
signal drag_started(index: int)   ## 按住并移动超过阈值后触发，由主界面接管拖拽
signal hovered(data: CardData, rect: Rect2)   ## 鼠标悬停：请求显示完整效果
signal hover_ended()

const CARD_SIZE := Vector2(118, 170)
const DRAG_THRESHOLD := 8.0

@onready var cost_label: Label = $Margin/VBox/Header/CostLabel
@onready var type_label: Label = $Margin/VBox/Header/TypeLabel
@onready var name_label: Label = $Margin/VBox/NameLabel
@onready var stats_label: Label = $Margin/VBox/StatsLabel
@onready var keyword_label: Label = $Margin/VBox/KeywordLabel
@onready var desc_label: RichTextLabel = $Margin/VBox/DescLabel

var data: CardData
var index := -1
var playable := false
var selected := false
var dragging := false
## 禁止样式：只在「拖着一张现在打不出的牌」的幽灵卡上用（红色边框 + 偏红色调）
var forbidden := false

var _press_pos := Vector2.ZERO
var _pressing := false
var _drag_began := false


func _ready() -> void:
	custom_minimum_size = CARD_SIZE
	pivot_offset = CARD_SIZE * 0.5
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_restructure_face()
	_clamp_content_height()
	set_process(true)
	# 卡面里的 Margin / 各种 Label / HSeparator / RichTextLabel 都是纯装饰：
	# 其中 RichTextLabel 与 HSeparator 默认是 STOP，会把按下与拖动事件吃掉，
	# 导致「只有卡牌部分区域能拖拽」。统一设为 IGNORE，交互都交给本控件处理。
	UiUtil.make_decorative(self)


## 卡面排版重排（照参考图：数值徽章在**卡面底部两角**，而不是夹在名字与描述之间）。
## 数值行挪到最后一行的同时给它留出高度，这样底角的攻/血徽章**不会压到描述文字**
## （`admin_art_test` 会核对「徽章不遮挡卡名 / 关键字 / 描述」）。
func _restructure_face() -> void:
	var vbox := get_node_or_null("Margin/VBox")
	if vbox != null and stats_label != null:
		vbox.move_child(stats_label, vbox.get_child_count() - 1)
		stats_label.custom_minimum_size = Vector2(0, 26)
		stats_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if cost_label != null:
		cost_label.add_theme_font_size_override("font_size", 16)
		cost_label.add_theme_color_override("font_color", Color.WHITE)
		cost_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		cost_label.add_theme_constant_override("outline_size", 3)
	if name_label != null:
		name_label.add_theme_font_size_override("font_size", 14)
		name_label.add_theme_color_override("font_color", Color("#f2f6ff"))


## 卡面尺寸必须**恒为** `CARD_SIZE`：内容（长描述 / 多行关键字）不得把卡撑高。
## 否则同一手牌里会高低不齐——实测带战吼 + 亡语的卡最低要 226px 高，
## 整条手牌因此溢出到手牌区之外，被抽牌堆压住、也与主战者行打架（踩过的坑）。
## 做法：把两个文本区的**最小高度**压到 0（`fit_content = false`、关键字不自动换行），
## 让 VBox 把剩余高度分给描述区，而不是让描述去决定整张卡的高度；超出部分裁掉
## （完整效果依旧可以在悬停详情面板里看到）。
func _clamp_content_height() -> void:
	clip_contents = true
	if keyword_label != null:
		keyword_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		keyword_label.clip_text = true
		keyword_label.custom_minimum_size = Vector2.ZERO
	if desc_label != null:
		desc_label.fit_content = false
		desc_label.custom_minimum_size = Vector2.ZERO


func setup(p_data: CardData, p_index: int, p_playable: bool = true) -> void:
	data = p_data
	index = p_index
	playable = p_playable
	selected = false
	_refresh()


func set_selected(value: bool) -> void:
	selected = value
	scale = Vector2(1.08, 1.08) if value else Vector2.ONE
	_refresh()


func set_dragging(value: bool) -> void:
	dragging = value
	_refresh()


## 幽灵卡用：标记「这张牌现在打不出」（红色边框 + 偏红色调）
func set_forbidden(value: bool) -> void:
	forbidden = value
	_refresh()


func _refresh() -> void:
	if data == null:
		return
	cost_label.text = "%d" % data.cost
	apply_art()                      # 卡图随卡面数据刷新
	type_label.text = data.type_name()
	name_label.text = data.card_name

	if data.is_minion():
		stats_label.text = "%d / %d" % [data.attack, data.health]
		stats_label.visible = true
		# 数值已经画进底角的攻 / 血宝石里（像参考图），所以这里把重复的文字透明化 ——
		# **不隐藏**：文本内容与可见性仍可被断言（护符 / 法术照旧显示文字耐久）。
		stats_label.modulate = Color(1, 1, 1, 0)
	elif data.is_permanent():
		# 护符 / 城邦没有攻击力，卡面上显示耐久
		stats_label.text = "耐久 %d" % data.durability()
		stats_label.visible = true
		stats_label.modulate = Color(1, 1, 1, 1)
	else:
		stats_label.visible = false

	# _sync_face_decorations()      # 同上：暂不套卡面皮肤，保持原有可读性
	var kn := data.keyword_names()
	keyword_label.text = " ".join(kn) if kn.size() > 0 else ""
	keyword_label.visible = kn.size() > 0

	var lines := PackedStringArray()
	if data.has_effect():
		var prefix := ""
		if data.is_minion():
			prefix = "战吼："
		elif data.is_permanent():
			prefix = "安放："
		lines.append(prefix + data.effect_text())
	if data.needs_target():
		lines.append("目标：" + data.target_name())
	if data.has_deathrattle():
		lines.append(data.deathrattle_text())
	if data.has_skill():
		# 主动技能：卡面也写一行，玩家能一眼看到点它能干什么、要花多少 PP（0 = 免费）
		var cost_bit := "免费" if data.skill_cost() <= 0 else "花费 %d PP" % data.skill_cost()
		lines.append("技能「%s」（%s）：%s" % [
			data.skill_name(), cost_bit, data.chain_text(data.skill_chain())])
	if data.is_city():
		lines.append("城邦：每套牌组最多 %d 张" % CardData.CITY_DECK_LIMIT)
	if data.description.strip_edges() != "":
		lines.append(data.description)
	desc_label.text = "\n".join(lines)

	var style := StyleBoxFlat.new()
	style.bg_color = data.color.darkened(0.42)
	style.set_corner_radius_all(9)
	style.content_margin_left = 7
	style.content_margin_right = 7
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	style.border_width_left = 3
	style.border_width_right = 3
	style.border_width_top = 3
	style.border_width_bottom = 3
	if selected:
		style.border_color = Color("#ffee58")
	elif forbidden:
		style.border_color = Color("#ef5350")
	elif playable:
		style.border_color = Color("#66bb6a")
	else:
		style.border_color = Color("#455a64")
	add_theme_stylebox_override("panel", style)
	if dragging:
		modulate = Color(1.0, 1.0, 1.0, 0.32)
	elif forbidden:
		modulate = Color(1.0, 0.78, 0.78, 0.92)
	else:
		modulate = Color.WHITE if playable else Color(0.68, 0.68, 0.68)
	queue_redraw()                   # 卡面装饰（费用水晶 / 攻血宝石 / 卡名缎带）跟着数据重画


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_pos = event.position
				_pressing = true
				_drag_began = false
			elif _pressing:
				_pressing = false
				# 拖动过就不再当作普通点击
				if not _drag_began:
					clicked.emit(index)
				accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			right_clicked.emit(index)
			accept_event()
	elif event is InputEventMouseMotion:
		# 任何手牌都能「拿起来比划」：打不出的牌照样起拖，
		# 幽灵卡显示成红色禁止样式、落点不亮，松手时由主界面说明原因。
		if _pressing and not _drag_began and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_drag_began = true
			drag_started.emit(index)
			accept_event()


func _on_mouse_entered() -> void:
	if not selected and not dragging:
		scale = Vector2(1.06, 1.06)
	z_index = 1
	hovered.emit(data, get_global_rect())


func _on_mouse_exited() -> void:
	if not selected and not dragging:
		scale = Vector2.ONE
	z_index = 0
	hover_ended.emit()


# ------------------------------ 卡面装饰（参考炉石 / 影之诗的卡面） ------------------------------
#
# 现在的卡面装饰（费用水晶 / 攻击宝石 / 生命宝石 / 卡名缎带）全部由本文件的 `_draw()` 绘制，
# 不再建任何子节点 —— 布局与命中区域因此完全不受影响。
# 下面这几个方法只留给老测试当兼容入口（数值以卡牌数据为准）。

var _hovered := false
var _art: TextureRect = null
## 上一次画卡面装饰时的布局签名（布局稳定前会因为尺寸变化重画几次，之后不再重画）
var _face_sig := ""


func _ensure_face_decorations() -> void:
	pass        # 装饰改为 `_draw()` 绘制，不再建子节点（保留空实现给老调用点）


func _set_hover(on: bool) -> void:
	if _hovered == on:
		return
	_hovered = on
	if dragging:
		return
	scale = Vector2(1.06, 1.06) if on else Vector2.ONE
	z_index = 20 if on else 0


func is_hovered() -> bool:
	return scale.x > 1.01


func hover_scale() -> float:
	return scale.x


func mana_gem_text() -> String:
	return "" if data == null else "%d" % data.cost


func attack_gem_text() -> String:
	return "" if data == null else "%d" % data.attack


func health_gem_text() -> String:
	return "" if data == null else "%d" % data.health


func _process(_delta: float) -> void:
	# 卡面装饰的坐标来自子控件的**实际布局**（容器要过一两帧才排版完），所以这里比对一次
	# 签名，布局变了就重画一次 —— 否则第一帧算出来的宝石位置会一直留在画面上。
	# 数据变化由 `_refresh()` 直接触发重画；签名不变时不产生任何工作。
	var sig := _face_signature()
	if sig != _face_sig:
		_face_sig = sig
		queue_redraw()


## 布局签名：卡面尺寸 + 费用 / 数值两行的实际位置（变了就说明要重画装饰）
func _face_signature() -> String:
	var cr := _local_rect(cost_label)
	var sr := _local_rect(stats_label)
	return "%.1f|%.1f|%.1f|%.1f|%.1f|%d" % [size.x, size.y, cr.get_center().x, cr.get_center().y,
		sr.get_center().y, int(data.card_type) if data != null else -1]


## 兼容入口：以前它负责把宝石子节点摆到四角，现在装饰由 `_draw()` 负责，这里只重画一次
func _sync_face_decorations() -> void:
	queue_redraw()

# ------------------------------ 卡面宝石（_draw 绘制，永远在文字之后） ------------------------------
#
# 照同类卡牌游戏（以及参考图）的卡面构型：
#   * **费用水晶**：左上角一枚**圆形徽章**，颜色按卡牌类别（随从绿 / 法术蓝 / 护符褐 / 城邦紫），
#     金色外圈 —— 数字写在原来的 CostLabel 上，所以读起来仍是同一个文本节点；
#   * **攻击宝石**（左下·金）与 **生命宝石**（右下·红）：贴在数值行两端的底角；
#   * **卡名缎带**：卡名底下压一条深色半透明带 + 一条金色细线，卡图铺满时卡名依然清楚。
# Control 的 `_draw` 在子节点**之前**渲染，所以这些装饰天然在文字下面，不会遮住卡名 / 描述。
#
# 坐标口径：`_local_rect()` 把子控件的矩形换算到**卡面自身坐标系**
# （`get_rect()` 给的是父节点坐标系，直接拿来画会跑到左上角 —— 上一个版本就是这么错的）。

const GEM_COST_R := 14.0
const GEM_STAT_R := 12.0
const GEM_COST_MINION := Color("#3f9147")
const GEM_COST_SPELL := Color("#3f6fd8")
const GEM_COST_AMULET := Color("#8d6e63")
const GEM_COST_CITY := Color("#7e57c2")
const GEM_ATK := Color("#e0a325")
const GEM_HP := Color("#c62828")
const RIBBON_BG := Color(0.05, 0.06, 0.10, 0.62)


## 子控件的矩形换算到卡面自身坐标系
func _local_rect(c: Control) -> Rect2:
	if c == null or not is_instance_valid(c):
		return Rect2()
	return Rect2(c.global_position - global_position, c.size)


## 费用水晶的颜色（按卡牌类别）
func cost_gem_color() -> Color:
	if data == null:
		return GEM_COST_SPELL
	match data.card_type:
		CardData.CardType.MINION:
			return GEM_COST_MINION
		CardData.CardType.AMULET:
			return GEM_COST_AMULET
		CardData.CardType.CITY:
			return GEM_COST_CITY
		_:
			return GEM_COST_SPELL


func _draw() -> void:
	if data == null or cost_label == null:
		return
	# 卡名缎带（先画，压在文字下面）
	if name_label != null and name_label.visible:
		var nr := _local_rect(name_label)
		if nr.size.x > 1.0:
			var band := nr.grow_individual(6.0, 2.0, 6.0, 2.0)
			draw_rect(band, RIBBON_BG)
			draw_line(Vector2(band.position.x, band.end.y), band.end,
				Color(0.85, 0.72, 0.38, 0.55), 1.0, true)
	# 费用水晶（左上角，压在卡角上；中心夹在卡面内，避免被圆角裁掉）
	var cr := _local_rect(cost_label)
	var cc := Vector2(maxf(cr.get_center().x, GEM_COST_R + 2.0),
		maxf(cr.get_center().y, GEM_COST_R + 2.0))
	_draw_gem(cc, GEM_COST_R, cost_gem_color(), true)
	# 攻 / 血宝石（数值行两端；数字直接画在宝石里，像参考图那样）
	if data.is_minion() and stats_label != null:
		var sr := _local_rect(stats_label)
		var y: float = sr.get_center().y
		_draw_gem(Vector2(GEM_STAT_R + 3.0, y), GEM_STAT_R, GEM_ATK)
		_draw_gem(Vector2(size.x - GEM_STAT_R - 3.0, y), GEM_STAT_R, GEM_HP)
		_draw_gem_value(Vector2(GEM_STAT_R + 3.0, y), "%d" % data.attack)
		_draw_gem_value(Vector2(size.x - GEM_STAT_R - 3.0, y), "%d" % data.health)


## 宝石里的数字（描边 + 实心，压在宝石中心；字号随宝石半径缩放）
func _draw_gem_value(c: Vector2, text: String) -> void:
	if text == "":
		return
	var font := get_theme_default_font()
	if font == null:
		return
	var fs := int(GEM_STAT_R * 1.25)
	var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := c + Vector2(-w * 0.5, fs * 0.36)
	draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3,
		Color(0, 0, 0, 0.85))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


## 一枚水晶：底色 + 亮圈 + 内圈 + 顶部高光（费用水晶再加一圈金属外环）
func _draw_gem(c: Vector2, r: float, col: Color, trim: bool = false) -> void:
	draw_circle(c, r, col)
	draw_circle(c + Vector2(-r * 0.25, -r * 0.3), r * 0.55, Color(1, 1, 1, 0.10))
	draw_arc(c, r, 0.0, TAU, 28, col.lightened(0.45), 2.0, true)
	draw_arc(c, r * 0.74, 0.0, TAU, 24, col.darkened(0.30), 1.0, true)
	if trim:
		draw_arc(c, r + 2.0, 0.0, TAU, 30, Color(0.85, 0.72, 0.38, 0.9), 2.0, true)


## 供测试：宝石位置与半径（卡面自身坐标系；用于校验「不遮住卡面文字区」）
func gem_circles() -> Array:
	var out := []
	if data == null or cost_label == null:
		return out
	var cr := _local_rect(cost_label)
	var cc := Vector2(maxf(cr.get_center().x, GEM_COST_R + 2.0),
		maxf(cr.get_center().y, GEM_COST_R + 2.0))
	out.append({"center": cc, "radius": GEM_COST_R, "kind": "cost"})
	if data.is_minion() and stats_label != null:
		var sr := _local_rect(stats_label)
		var y: float = sr.get_center().y
		out.append({"center": Vector2(GEM_STAT_R + 3.0, y), "radius": GEM_STAT_R, "kind": "attack"})
		out.append({"center": Vector2(size.x - GEM_STAT_R - 3.0, y), "radius": GEM_STAT_R, "kind": "health"})
	return out


## 供测试：卡名 / 关键字 / 描述三块文字的矩形（**卡面自身坐标系**，与 `gem_circles()` 同口径）
func text_rects_local() -> Array:
	var out := []
	for lbl in [name_label, keyword_label, desc_label]:
		if lbl != null and lbl.visible:
			out.append(_local_rect(lbl))
	return out


## 卡图：在文字后面铺一张半透明卡图（不改变布局）。
## 路径由 ArtStore.art_for 解析：`assets/art/card_art/<卡 id>.png` 优先，其次卡表里的 art_path
func art_texture() -> Texture2D:
	return ArtStore.texture(ArtStore.art_for(data)) if data != null else null


## 供测试：卡图节点
func art_node():
	return _art


func apply_art() -> void:
	if _art == null:
		_art = TextureRect.new()
		_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_art.modulate = Color(1, 1, 1, 0.34)
	# 卡图挂到画框里：**已经在目标父节点下就不要再 add_child**，
	# 否则 Godot 会报 "Can't add child … already has a parent"（同一个控件重复挂载）。
	var art_frame := get_node_or_null("Margin/VBox/ArtFrame")
	var want_parent: Node = art_frame if art_frame != null else self
	if _art.get_parent() != want_parent:
		if _art.get_parent() != null:
			_art.get_parent().remove_child(_art)
		want_parent.add_child(_art)
	var tex := art_texture()
	_art.texture = tex
	_art.visible = tex != null
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)