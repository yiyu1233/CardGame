class_name HeroFrame
extends Control
## 主战者框（领袖头像框）：取代原来的「英雄文字按钮」。
##
## 影之诗风格的一块组合控件：双环圆盘 + 右侧血量徽章（红）+ 护甲徽章（黄，仅有时显示）；
## 盘内是名字 + 绘制的占位徽记（有立绘素材后可以在这里贴 TextureRect）；
## 敌方的 PP 珠（能量点）摆在圆盘左侧（一小排珠 + 「3/6」读数，**不是**大牌子）。
##
## 牌库 / 手牌 / 墓地 / 疲劳另由 `StatusPanel` 显示在竞技区角上的独立信息框里（见 Main 布局）。
##
## 实现要点：
##   * 圆环与徽章用 `draw_style_box` 画（圆角矩形拉满圆角就是圆，自带抗锯齿与描边），
##     文字用子 Label 承载 —— 中文走项目主题字体，测试也能按名字读到数字。
##   * 控件本体只占英雄行的高度（52px），圆盘会画到行外，因此**不改变**战场行 / 槽位几何；
##     `Main._hero_disc_offset()` 还会按战场行的实测位置把圆盘推到行外，既不遮随从也不抢点击。
##   * `_has_point()` 重写成圆形命中：点圆盘和徽章才算点到英雄，圆的四个角让给底下的卡牌。

signal pressed(player_id: int)

const FRAME_W := 420.0        ## 控件本体宽度：比圆盘宽，好把「能量点」摆在圆盘左侧（影之诗那样）
const FRAME_H := 52.0
const DISC_R := 58.0          ## 外环半径
const INNER_R := 50.0         ## 头像盘半径
const HP_SIZE := Vector2(52, 40)
const HP_OFFSET := Vector2(36, -21)      ## 血量徽章相对圆盘中心（右侧压住圆环）
const ARMOR_SIZE := Vector2(38, 20)
const ARMOR_OFFSET := Vector2(44, 21)    ## 护甲徽章相对圆盘中心（血量徽章下方）
const ORB_SIZE := 8.0
const ORB_GAP := 2.0
const ORB_LEFT := 12.0        ## 能量点条的左端（相对控件左侧）
const MANA_ORB_COUNT := ManaOrbs.ORB_COUNT
const FONT_SMALL := 11
const FONT_MANA := 9
const FONT_HP := 22

const RING_ENEMY := Color("#e57373")
const RING_PLAYER := Color("#64b5f6")
const DISC_BG := Color(0.06, 0.07, 0.10, 1.0)
const DISC_INNER := Color(0.12, 0.15, 0.21, 1.0)
const COLOR_HP := Color("#e53935")
const COLOR_ARMOR := Color("#ffca28")
const COLOR_HIGHLIGHT := Color("#ffee58")

var player_id := 0
var show_mana := false        ## 敌方显示 PP 珠（我方能量点在回合按钮周围，不重复显示）
## 圆盘相对英雄行中心的纵向偏移：由 Main 按战场行的位置算出来，
## 让圆盘**避开战场行**（既不遮住随从的边，也不会抢走随从的点击）
var disc_offset_y := 0.0

var _highlighted := false
var _dead := false
var _hovered := false

var _name_label: Label
var _hp_label: Label
var _armor_label: Label
var _mana_label: Label

# 复用的样式对象：每帧只改颜色，不重新分配
var _ring_style := StyleBoxFlat.new()
var _glow_style := StyleBoxFlat.new()
var _inner_style := StyleBoxFlat.new()
var _inner_glow := StyleBoxFlat.new()
var _hp_style := StyleBoxFlat.new()
var _armor_style := StyleBoxFlat.new()
var _orb_styles: Dictionary = {}


func _ready() -> void:
	custom_minimum_size = Vector2(FRAME_W, FRAME_H)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build_labels()
	_prepare_styles()
	mouse_entered.connect(func() -> void:
		_hovered = true
		queue_redraw()
	)
	mouse_exited.connect(func() -> void:
		_hovered = false
		queue_redraw()
	)


func setup(pid: int, display_name: String, with_mana: bool) -> void:
	player_id = pid
	show_mana = with_mana
	if _name_label == null:
		return
	_name_label.text = display_name
	_mana_label.visible = show_mana
	queue_redraw()


# ------------------------------ 几何 ------------------------------

func disc_center_local() -> Vector2:
	return Vector2(FRAME_W * 0.5, FRAME_H * 0.5 + disc_offset_y)


func set_disc_offset_y(v: float) -> void:
	if is_equal_approx(disc_offset_y, v):
		return
	disc_offset_y = v
	_layout_labels()
	queue_redraw()


func disc_radius() -> float:
	return DISC_R


## 血量 / 护甲徽章的位置：一律相对圆盘中心算，改控件宽度也不会错位
func hp_rect() -> Rect2:
	return Rect2(disc_center_local() + HP_OFFSET, HP_SIZE)


func armor_rect() -> Rect2:
	return Rect2(disc_center_local() + ARMOR_OFFSET, ARMOR_SIZE)


## 实际绘制范围（全局坐标，含溢出到行外的圆盘与徽章），供布局测试核对
func visual_rect() -> Rect2:
	var c := disc_center_local()
	var top: float = c.y - DISC_R - 6.0
	var bottom: float = c.y + DISC_R + 8.0
	var left: float = ORB_LEFT if show_mana else c.x - DISC_R - 6.0
	var right: float = c.x + DISC_R + 56.0
	return Rect2(global_position + Vector2(left, top), Vector2(right - left, bottom - top))


# ------------------------------ 命中判定 ------------------------------

## 圆形命中：圆盘（含描边）+ 血量徽章 + 护甲徽章才算英雄，四个角让给底下的卡牌
func _has_point(point: Vector2) -> bool:
	if _inside_disc(point, DISC_R + 4.0):
		return true
	if hp_rect().has_point(point):
		return true
	if _armor_visible() and armor_rect().has_point(point):
		return true
	return false


func _inside_disc(point: Vector2, radius: float) -> bool:
	return point.distance_to(disc_center_local()) <= radius


## 全局坐标命中：与 `_has_point()`/点击判定同一套形状，供拖放落点判定复用
func contains_global_point(pos: Vector2, slack: float = 10.0) -> bool:
	var local: Vector2 = pos - global_position
	if _inside_disc(local, DISC_R + slack):
		return true
	if hp_rect().grow(slack * 0.5).has_point(local):
		return true
	return _armor_visible() and armor_rect().grow(slack * 0.5).has_point(local)


# ------------------------------ 状态 ------------------------------

func set_highlight(enabled: bool) -> void:
	if _highlighted == enabled:
		return
	_highlighted = enabled
	queue_redraw()


func is_highlighted() -> bool:
	return _highlighted


func update_state(p: PlayerState) -> void:
	if p == null or _hp_label == null:
		return
	_dead = p.hero_hp <= 0
	_hp_label.text = str(maxi(0, p.hero_hp))
	var armor: int = p.armor
	_armor_label.visible = armor > 0
	if armor > 0:
		_armor_label.text = str(armor)
	if show_mana:
		_mana_label.text = "%d/%d" % [p.mana, p.max_mana]
	queue_redraw()


func hp_text() -> String:
	return "" if _hp_label == null else _hp_label.text


func armor_text() -> String:
	return "" if _armor_label == null else _armor_label.text


func armor_visible() -> bool:
	return _armor_visible()


func mana_text() -> String:
	return "" if _mana_label == null else _mana_label.text


func mana_orb_count() -> int:
	return MANA_ORB_COUNT if show_mana else 0


func name_text() -> String:
	return "" if _name_label == null else _name_label.text


# ------------------------------ 构建 ------------------------------

func _build_labels() -> void:
	_name_label = _make_label(FONT_SMALL, Color("#c5cae9"))
	_hp_label = _make_label(FONT_HP, Color.WHITE)
	_armor_label = _make_label(11, COLOR_ARMOR)
	_mana_label = _make_label(FONT_MANA, Color("#ffe082"))
	_armor_label.visible = false
	for l in [_name_label, _hp_label, _armor_label, _mana_label]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_layout_labels()


func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	add_child(l)
	return l


func _layout_labels() -> void:
	var c := disc_center_local()
	# 名字放在圆盘上部，纹章在其下方（没有立绘素材时的占位构型）
	_name_label.position = Vector2(c.x - INNER_R, c.y - INNER_R + 6.0)
	_name_label.size = Vector2(INNER_R * 2.0, 16.0)
	_hp_label.position = hp_rect().position
	_hp_label.size = hp_rect().size
	_armor_label.position = armor_rect().position
	_armor_label.size = armor_rect().size
	var orbs_w: float = MANA_ORB_COUNT * ORB_SIZE + (MANA_ORB_COUNT - 1) * ORB_GAP
	_mana_label.position = Vector2(ORB_LEFT + orbs_w + 6.0, c.y - 7.0)
	_mana_label.size = Vector2(34.0, 14.0)


func _prepare_styles() -> void:
	_ring_style.set_corner_radius_all(int(DISC_R))
	_ring_style.set_border_width_all(3)
	_ring_style.anti_aliasing = true
	_ring_style.shadow_color = Color(0, 0, 0, 0.45)
	_ring_style.shadow_size = 4

	_inner_style.set_corner_radius_all(int(INNER_R))
	_inner_style.bg_color = DISC_INNER
	_inner_style.anti_aliasing = true

	# 盘内的柔光（比内盘略小一圈、颜色略亮，做出“立绘底光”的感觉）
	_inner_glow.set_corner_radius_all(int(INNER_R) - 8)
	_inner_glow.bg_color = Color(0.20, 0.25, 0.34, 0.55)
	_inner_glow.anti_aliasing = true

	_hp_style.bg_color = COLOR_HP
	_hp_style.border_color = Color(1, 1, 1, 0.55)
	_hp_style.set_border_width_all(2)
	_hp_style.set_corner_radius_all(10)
	_hp_style.anti_aliasing = true

	_armor_style.bg_color = Color(0.55, 0.42, 0.08, 1.0)
	_armor_style.border_color = COLOR_ARMOR
	_armor_style.set_border_width_all(2)
	_armor_style.set_corner_radius_all(7)
	_armor_style.anti_aliasing = true

	_glow_style.bg_color = Color(0, 0, 0, 0)
	_glow_style.border_color = COLOR_HIGHLIGHT
	_glow_style.set_border_width_all(4)
	_glow_style.set_corner_radius_all(int(DISC_R + 7.0))
	_glow_style.anti_aliasing = true

	# 小尺寸 PP 珠（8px）：颜色与 ManaOrbs 保持一致，圆角取半径
	_orb_styles = {}
	for state in ["ready", "spent", "locked"]:
		var style := StyleBoxFlat.new()
		style.bg_color = ManaOrbs.COLOR_READY_BG if state == "ready" else (
			ManaOrbs.COLOR_SPENT_BG if state == "spent" else ManaOrbs.COLOR_LOCKED_BG)
		style.border_color = ManaOrbs.COLOR_READY_BORDER if state == "ready" else (
			ManaOrbs.COLOR_SPENT_BORDER if state == "spent" else ManaOrbs.COLOR_LOCKED_BORDER)
		style.set_border_width_all(1)
		style.set_corner_radius_all(int(ORB_SIZE * 0.5))
		style.anti_aliasing = true
		_orb_styles[state] = style


# ------------------------------ 绘制 ------------------------------

func _draw() -> void:
	var c := disc_center_local()
	var accent: Color = RING_ENEMY if player_id == GameManager.ENEMY_ID else RING_PLAYER
	if _dead:
		accent = Color(0.35, 0.36, 0.40, 1.0)

	# 外环 + 头像盘
	_ring_style.bg_color = DISC_BG
	_ring_style.border_color = accent
	draw_style_box(_ring_style, Rect2(c - Vector2(DISC_R, DISC_R), Vector2(DISC_R, DISC_R) * 2.0))
	_inner_style.bg_color = DISC_INNER.lerp(accent, 0.10 if not _dead else 0.0)
	draw_style_box(_inner_style, Rect2(c - Vector2(INNER_R, INNER_R), Vector2(INNER_R, INNER_R) * 2.0))
	draw_style_box(_inner_glow, Rect2(c - Vector2(INNER_R - 8.0, INNER_R - 8.0), Vector2(INNER_R - 8.0, INNER_R - 8.0) * 2.0))

	# 环上的刻度（影之诗那种外圈刻痕）
	var tick_color := Color(accent.r, accent.g, accent.b, 0.55)
	for i in 16:
		var a: float = TAU * float(i) / 16.0 - PI * 0.5
		var from := c + Vector2(cos(a), sin(a)) * (DISC_R - 2.0)
		var to := c + Vector2(cos(a), sin(a)) * (DISC_R + 6.0)
		draw_line(from, to, tick_color, 1.5, true)

	# 盘内徽记（没有立绘素材，用几何图形占位：盾形 + 横条 + 三个点）
	_draw_emblem(c, accent)

	# 血量徽章 / 护甲徽章
	draw_style_box(_hp_style, hp_rect())
	if _armor_visible():
		draw_style_box(_armor_style, armor_rect())

	# 敌方的 PP 珠
	if show_mana:
		_draw_mana_orbs(c)

	# 可被指定为目标时的黄圈；悬停时亮一点
	if _highlighted or _hovered:
		_glow_style.border_color = COLOR_HIGHLIGHT if _highlighted else Color(1, 1, 1, 0.35)
		var r: float = DISC_R + 7.0
		draw_style_box(_glow_style, Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0))


func _draw_emblem(c: Vector2, accent: Color) -> void:
	var soft := Color(accent.r, accent.g, accent.b, 0.30)
	var line := Color(accent.r, accent.g, accent.b, 0.65)
	# 盾形轮廓
	var shield := PackedVector2Array([
		c + Vector2(0, -20), c + Vector2(17, -9), c + Vector2(14, 12),
		c + Vector2(0, 22), c + Vector2(-14, 12), c + Vector2(-17, -9),
	])
	draw_colored_polygon(shield, soft)
	# 内描边 + 中间横条 + 三个小点（像是纹章的简化画法）
	var outline := PackedVector2Array()
	for p in shield:
		outline.append(p)
	outline.append(shield[0])
	draw_polyline(outline, line, 1.5, true)
	draw_line(c + Vector2(-11, 4), c + Vector2(11, 4), line, 2.0, true)
	for i in 3:
		draw_circle(c + Vector2(-7.0 + float(i) * 7.0, 12.0), 2.0, line)


## 敌方的 PP 珠画在圆盘**左侧**（影之诗把能量点摆在主战者旁边）：
## 画在圆盘上方会被敌方手牌卡背盖住（卡背带 z_index），摆在同一条信息带里最稳妥。
func _draw_mana_orbs(c: Vector2) -> void:
	var x: float = ORB_LEFT
	var y: float = c.y - ORB_SIZE * 0.5
	var mana: int = 0
	var max_mana: int = 0
	var p: PlayerState = GameManager.get_player(player_id)
	if p != null:
		mana = p.mana
		max_mana = p.max_mana
	for i in MANA_ORB_COUNT:
		# 状态判定复用 ManaOrbs（与回合按钮周围那一圈同一套规则），样式用这里的小尺寸版本
		var state: String = ManaOrbs.state_of(i, mana, max_mana)
		var st: StyleBoxFlat = _orb_styles.get(state, _orb_styles["locked"])
		draw_style_box(st, Rect2(Vector2(x + float(i) * (ORB_SIZE + ORB_GAP), y), Vector2(ORB_SIZE, ORB_SIZE)))


func _armor_visible() -> bool:
	return _armor_label != null and _armor_label.visible


# ------------------------------ 交互 ------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not _dead:
			pressed.emit(player_id)
		accept_event()
