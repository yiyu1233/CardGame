class_name BoardSurface
extends HBoxContainer
## 战场地面：绘制固定随从槽位（参考炉石 / 影之诗的站位格子）与「我方战场 3 / 7」计数。
##
## 随从仍然是本节点的直接子节点，所以既有的出牌 / 攻击 / 拖拽命中判定全都不用改：
## `_draw()` 画的是自己的内容，永远位于子节点之下，槽位自然就成了随从的“地面”。
##
## 对齐约定（两边必须一致，否则“随从落在格子里”就是假的）：
##   * Main 在摆放随从时会在两侧补上等宽的空槽占位控件，使整行子节点总宽恒等于
##     `slot_limit` 个槽位宽，于是随从的落点与槽位网格逐格对齐（奇数 / 偶数个随从都成立）；
##   * 槽位尺寸直接取 `UnitUI.UNIT_SIZE`，不另写一份常量，避免两边漂移；
##   * 纵向贴着随从所在的一侧：我方随从靠上（SHRINK_BEGIN），敌方随从靠下（SHRINK_END）。

const SLOT_GAP := 10.0


var slot_limit := 7
var slot_used := 0
var caption := "战场"
## true = 随从贴本行顶部（我方），false = 贴底部（敌方）
var minions_on_top := true
## 拖拽落点高亮：正在指向的格子号（-1 = 没有）+ 该落点是否可用（决定绿 / 红）
var hover_slot := -1
var hover_ok := true

var _slot_style: StyleBoxFlat
var _front_style: StyleBoxFlat
var _front_card_style: StyleBoxFlat


func _ready() -> void:
	resized.connect(queue_redraw)
	_ensure_style()


func _ensure_style() -> void:
	if _slot_style != null:
		return
	_slot_style = StyleBoxFlat.new()
	_slot_style.bg_color = Color(1.0, 1.0, 1.0, 0.045)
	_slot_style.border_color = Color(1.0, 1.0, 1.0, 0.13)
	_slot_style.set_border_width_all(1)
	_slot_style.set_corner_radius_all(10)
	_slot_style.anti_aliasing = true

	# 正中那一格是「横置格」：用暖色描边与别的格子区分开
	_front_style = StyleBoxFlat.new()
	_front_style.bg_color = Color(1.0, 0.85, 0.35, 0.08)
	_front_style.border_color = Color(1.0, 0.85, 0.35, 0.5)
	_front_style.set_border_width_all(2)
	_front_style.set_corner_radius_all(10)
	_front_style.anti_aliasing = true

	# 横置卡片的轮廓：比格子宽、比格子矮，一眼看出“牌要横着放”
	_front_card_style = StyleBoxFlat.new()
	_front_card_style.bg_color = Color(1.0, 0.85, 0.35, 0.05)
	_front_card_style.border_color = Color(1.0, 0.85, 0.35, 0.55)
	_front_card_style.set_border_width_all(2)
	_front_card_style.set_corner_radius_all(7)
	_front_card_style.anti_aliasing = true


## 横置格就是每条战场行的正中那一格（紧贴中线）
func front_lane() -> int:
	return slot_limit / 2


func is_front_lane(i: int) -> bool:
	return i == front_lane()


func front_slot_rect() -> Rect2:
	return slot_rect(front_lane())


## 后排格子（除正中横置格之外的那些），按从左到右的顺序
func back_lanes() -> Array[int]:
	var out: Array[int] = []
	for i in slot_limit:
		if not is_front_lane(i):
			out.append(i)
	return out


## 由 Main 在每次刷新时调用（随从上场 / 死亡后槽位计数会变）
func set_slots(used: int, limit: int, p_caption: String = "战场", on_top: bool = true) -> void:
	slot_used = used
	slot_limit = maxi(1, limit)
	caption = p_caption
	minions_on_top = on_top
	queue_redraw()


## 供界面设置「拖拽正在指向哪一格」：绿 = 可放置，红 = 不可放置（占用 / 不是自己的半场）
func set_hover_slot(slot: int, ok: bool = true) -> void:
	if slot == hover_slot and ok == hover_ok:
		return
	hover_slot = slot
	hover_ok = ok
	queue_redraw()


## 第 i 个槽位在本行局部坐标下的矩形。
## `_draw()`、拖拽落点判定与布局测试共用它，保证“画出来的格子”“松手落进哪一格”
## 与“随从该在的位置”只有一个来源。
func slot_rect(i: int) -> Rect2:
	var unit := UnitUI.UNIT_SIZE
	var w := size.x
	var h := size.y
	var pitch: float = unit.x + SLOT_GAP
	var natural: float = pitch * float(slot_limit) - SLOT_GAP
	# 行宽不足时整体等比缩小；下限只用于避免除零，越界由 _draw 逐格跳过
	var fit: float = clampf((w - 10.0) / maxf(natural, 1.0), 0.0, 1.0)
	var slot_w: float = unit.x * fit
	var gap: float = SLOT_GAP * fit
	var step: float = slot_w + gap
	var total: float = slot_w * float(slot_limit) + gap * float(slot_limit - 1)
	var x0: float = (w - total) * 0.5
	var slot_h: float = minf(unit.y, h)
	var top: float = 0.0 if minions_on_top else (h - slot_h)
	return Rect2(Vector2(x0 + step * float(i), top), Vector2(slot_w, slot_h))


# ------------------------------ 拖拽落点 → 格子号 ------------------------------
#
# 「拖到哪一格就放进哪一格」的判定入口：界面把鼠标位置换算成本行局部坐标后问这里，
# 保证**落点判定**与 `_draw()` 画出的格子来自同一个 `slot_rect()`，不会两边漂移。

## 局部坐标落在哪一格（不在任何格子里 → -1）
func slot_at_local_point(local_pos: Vector2) -> int:
	for i in slot_limit:
		if slot_rect(i).has_point(local_pos):
			return i
	return -1


## 全局坐标落在哪一格（不在任何格子里 → -1）
func slot_at_global_point(global_pos: Vector2) -> int:
	return slot_at_local_point(global_pos - global_position)


## 按 x 找最近的一格（落点落在格子之间的缝隙 / 行首行尾也能吸附到最近格）；
## `limit_to_rect` = true 时只接受落在本行纵向范围内的点。
func nearest_slot_local_x(local_x: float, local_y: float = -1.0, limit_to_rect := false) -> int:
	if slot_limit <= 0:
		return -1
	if limit_to_rect and local_y >= 0.0 and local_y > size.y:
		return -1
	var best := 0
	var best_d := INF
	for i in slot_limit:
		var r := slot_rect(i)
		var d: float = absf(r.get_center().x - local_x)
		if d < best_d:
			best_d = d
			best = i
	return best


func _draw() -> void:
	if size.x < 16.0 or size.y < 16.0:
		return
	_ensure_style()
	for i in slot_limit:
		var r := slot_rect(i)
		# 只画完整落在本行内的槽位，绝不画到别的面板上去
		if r.position.x >= -0.5 and r.position.x + r.size.x <= size.x + 0.5:
			if is_front_lane(i):
				_draw_front_lane(r)
			else:
				_draw_slot(r)
	# 拖拽落点高亮：正在指向的那一格描一圈绿（可放）/ 红（不可放）
	if hover_slot >= 0 and hover_slot < slot_limit:
		_draw_hover(_draw_hover_rect(hover_slot))

	# 计数放在随从对面的那一侧，不会被随从盖住
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := 12
	var text := "%s  %d / %d" % [caption, slot_used, slot_limit]
	var text_w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var y: float = size.y - 4.0 if minions_on_top else 15.0
	draw_string(font, Vector2(size.x - text_w - 8.0, y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.78, 0.82, 0.88, 0.85))


## 一个普通槽位：圆角底 + 顶部一条极淡的高光（做出「台面凹槽」的立体感）
func _draw_slot(r: Rect2) -> void:
	draw_style_box(_slot_style, r)
	var shine := Rect2(r.position + Vector2(3, 2), Vector2(r.size.x - 6, 1))
	draw_rect(shine, Color(1, 1, 1, 0.05))


## 拖拽落点高亮的矩形（略大于格子，好让描边落在格子外面）
func _draw_hover_rect(slot: int) -> Rect2:
	var r := slot_rect(slot)
	return Rect2(r.position - Vector2(3, 3), r.size + Vector2(6, 6))


## 拖拽落点高亮：绿 = 可放置 / 红 = 不可放置（占用或不是自己的半场）
func _draw_hover(rect: Rect2) -> void:
	var col := Color("#66bb6a") if hover_ok else Color("#e53935")
	var st := StyleBoxFlat.new()
	st.bg_color = Color(col.r, col.g, col.b, 0.16)
	st.border_color = Color(col.r, col.g, col.b, 0.95)
	st.set_border_width_all(3)
	st.set_corner_radius_all(10)
	st.anti_aliasing = true
	draw_style_box(st, rect)


## 横置格：格子本身 + 一张“横放的牌”轮廓 + 「横置」小字
func _draw_front_lane(lane: Rect2) -> void:
	draw_style_box(_front_style, lane)
	var card := Rect2(lane.get_center() - Vector2(66, 46), Vector2(132, 92))
	draw_style_box(_front_card_style, card)
	var font := get_theme_default_font()
	if font == null:
		return
	var label := "横置"
	var fw: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	draw_string(font, lane.get_center() - Vector2(fw * 0.5, -6.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1.0, 0.85, 0.35, 0.75))