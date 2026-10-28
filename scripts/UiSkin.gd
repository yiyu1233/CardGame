class_name UiSkin
extends RefCounted
## 界面皮肤工具（参考炉石 / 影之诗 / MTG Arena 的观感）：
## 把「面板 / 按钮 / 宝石 / 卡面」的样式集中在这里，避免各处各写一套 StyleBox，
## 让整个界面的圆角、描边、配色、悬停反馈保持一致。
##
## 用法：
##   UiSkin.apply_panel(arena_panel, UiSkin.PANEL_ARENA)
##   UiSkin.apply_buttons(top_bar)
##   card.add_theme_stylebox_override("panel", UiSkin.card_style(color))

# ------------------------------ 配色 ------------------------------
const BG_DEEP := Color("#0b0f16")          ## 最底
const BG_ARENA := Color("#111826")         ## 竞技区面板
const BG_PANEL := Color("#161f2e")         ## 普通面板（日志 / 信息框）
const BG_RAISED := Color("#1d283b")        ## 按钮默认
const BG_RAISED_HOVER := Color("#27354d")
const BG_RAISED_PRESS := Color("#121a28")
const EDGE := Color("#3b4a63")             ## 常规描边
const EDGE_STRONG := Color("#5c7093")      ## 强调描边
const ACCENT := Color("#ffca28")           ## 主强调色（琥珀）
const TEXT := Color("#e8eef8")
const TEXT_DIM := Color("#9aa8bf")

# 卡面按类别上色（与 CardData 的默认色系一致）
const CARD_RADIUS := 10
const PANEL_RADIUS := 12
const PILL_RADIUS := 16


static func _rounded(radius: int, bg: Color, edge: Color, edge_width: int = 2,
		shadow: int = 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(edge_width)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	if shadow > 0:
		s.shadow_color = Color(0, 0, 0, 0.45)
		s.shadow_size = shadow
		s.shadow_offset = Vector2(0, 3)
	return s


# ------------------------------ 面板 / 按钮 ------------------------------

static func panel_style(kind: String = "panel") -> StyleBoxFlat:
	match kind:
		"arena":
			return _rounded(PANEL_RADIUS + 4, BG_ARENA, EDGE_STRONG, 2, 6)
		"raised":
			return _rounded(PANEL_RADIUS, BG_PANEL, EDGE_STRONG, 2, 4)
		"seam":
			return _rounded(8, Color("#1a2434"), ACCENT.darkened(0.45), 1)
		_:
			return _rounded(PANEL_RADIUS, BG_PANEL, EDGE, 2, 3)


static func apply_panel(p: PanelContainer, kind: String = "panel") -> void:
	if p == null:
		return
	p.add_theme_stylebox_override("panel", panel_style(kind))


static func apply_plain_panel(p: Panel, kind: String = "seam") -> void:
	if p == null:
		return
	p.add_theme_stylebox_override("panel", panel_style(kind))


## 统一按钮外观（含 hover / pressed / disabled / focus 四态）
static func apply_button(b: Button, accent: bool = false) -> void:
	if b == null:
		return
	var base := _rounded(PILL_RADIUS, ACCENT.darkened(0.15) if accent else BG_RAISED,
		ACCENT if accent else EDGE, 2)
	var hover := _rounded(PILL_RADIUS, ACCENT if accent else BG_RAISED_HOVER,
		ACCENT.lightened(0.2) if accent else EDGE_STRONG, 2)
	var press := _rounded(PILL_RADIUS, ACCENT.darkened(0.3) if accent else BG_RAISED_PRESS, ACCENT, 2)
	var off := _rounded(PILL_RADIUS, Color("#141a24"), EDGE.darkened(0.3), 1)
	off.bg_color.a = 0.7
	b.add_theme_stylebox_override("normal", base)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", press)
	b.add_theme_stylebox_override("disabled", off)
	b.add_theme_stylebox_override("focus", hover)
	b.add_theme_color_override("font_color", Color("#1a1206") if accent else TEXT)
	b.add_theme_color_override("font_hover_color", Color("#1a1206") if accent else Color.WHITE)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM.darkened(0.2))
	b.add_theme_font_size_override("font_size", 14)


## 已经做成"正圆"的控件（例：结束回合圆钮）不要改成胶囊，保留原设计
static func _is_circle(b: Button) -> bool:
	var st: StyleBox = b.get_theme_stylebox("normal")
	if st is StyleBoxFlat and (st as StyleBoxFlat).corner_radius_top_left >= 30:
		return true
	# 方形的大按钮（例：结束回合的圆钮）同样是"正圆设计"，不要改成胶囊
	return absf(b.size.x - b.size.y) < 1.0 and b.size.x >= 60.0


## 递归给一棵子树里的所有按钮套上统一样式
static func apply_buttons(root: Node, accent_names: Array = []) -> int:
	var n := 0
	for child in root.get_children():
		if child is Button and not _is_circle(child):
			apply_button(child, accent_names.has(child.name))
			n += 1
		n += apply_buttons(child, accent_names)
	return n


# ------------------------------ 宝石 / 卡面 ------------------------------

## 圆形宝石（法力水晶 / 攻击 / 生命）
static func gem_style(color: Color, radius: int = 14) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.border_color = color.lightened(0.35)
	s.set_border_width_all(2)
	s.set_corner_radius_all(radius)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 3
	s.shadow_offset = Vector2(0, 2)
	return s


static func gem(color: Color, radius: int = 14) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", gem_style(color, radius))
	return p


static func gem_label(p: Panel, text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 3)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.add_child(l)
	return l


## 卡面：按类别上色 + 圆角 + 描边（类别色由 CardData 给出）
static func card_style(type_color: Color) -> StyleBoxFlat:
	var s := _rounded(CARD_RADIUS, Color("#131a26"), type_color.lightened(0.1), 2, 5)
	s.bg_color = Color("#131a26").lerp(type_color.darkened(0.55), 0.28)
	# 卡面内部间距由 Card.tscn 的 Margin 节点负责，这里不要再加，避免改变命中区域
	s.content_margin_left = 0
	s.content_margin_right = 0
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	return s


static func card_colors(type_color: Color) -> Dictionary:
	return {
		"title": type_color.lightened(0.45),
		"body": TEXT,
		"dim": TEXT_DIM,
	}

# ------------------------------ 全局字体（游戏数据包里的中文字体） ------------------------------

const GAME_FONT_SANS := "res://assets/fonts/SV_DFPT_W7.ttf"
const GAME_FONT_BOLD := "res://assets/fonts/SV_DFGBWB7_900.ttf"
static var _font: Font = null


## 把资源的字体设为全局默认字体；找不到就保持 Godot 默认（静默回落，不影响任何逻辑）
static func apply_global_font() -> bool:
	if _font == null:
		for path in [GAME_FONT_SANS, GAME_FONT_BOLD]:
			if ResourceLoader.exists(path):
				var res := ResourceLoader.load(path)
				if res is Font:
					_font = res
					break
	if _font == null:
		return false
	if ThemeDB.fallback_font != _font:
		ThemeDB.fallback_font = _font
	return true


static func game_font() -> Font:
	return _font


## 字号覆盖（标题 / 正文），配合全局字体用
static func font_sizes(label: Control, size: int) -> void:
	if label != null:
		label.add_theme_font_size_override("font_size", size)