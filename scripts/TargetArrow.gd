extends Control
## 卡牌 / 随从的**指向箭头**（替代原来的黄色矩形标注）：
## 从「正在释放的卡牌」或「正在攻击的随从」拉出一条**弧形**箭头指向目标；
## 鼠标悬停在合法目标上时箭头会**吸附锁定**到目标中心并加粗，松开即生效。
##
## 设计要点：
##   * 二次贝塞尔（起点 → 控制点 → 终点），控制点垂直偏移 = 距离的 28%，所以一定是"弧形"；
##   * 带宽沿曲线渐细 + 箭头尖，接近主流卡牌游戏的观感；
##   * 颜色区分用途：法术=琥珀、攻击=红、放置=绿；
##   * 全部走 `_draw()`，不产生任何额外节点，也不会影响布局。
##
## 对外接口（便于测试与外部驱动）：
##   show_arrow(from, to, kind)  show_straight(from, to, kind)  hide_arrow()
##   control_point()  point_at(t)  is_visible  from_point  to_point  locked  kind

const COLOR_OK := Color("#43a047")          ## 可用 / 可指定（绿）
const COLOR_NO := Color("#e53935")          ## 不可用 / 不可指定（红）
const COLOR_SPELL := Color("#ffca28")
const COLOR_ATTACK := Color("#ef5350")
const COLOR_PLACE := Color("#66bb6a")

const BOW_RATIO := 0.28          ## 控制点垂直偏移比例（越大越弯）
const BASE_WIDTH := 8.0          ## 起点宽度
const TIP_WIDTH := 3.0           ## 接近终点时的宽度
const LOCKED_SCALE := 1.35       ## 锁定目标后的加粗倍数
const SEGMENTS := 22

var from_point := Vector2.ZERO
var to_point := Vector2.ZERO
var kind := "spell"
var locked := false              ## 是否已吸附到合法目标
var available := true            ## 当前是否可用 / 可指定（决定箭头颜色：绿 / 红）
var active := false

var _control := Vector2.ZERO
var _color := COLOR_SPELL
var _drawn_width := BASE_WIDTH


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


## 显示一条弧形箭头：`from` = 卡牌 / 随从中心，`to` = 鼠标或目标中心
func show_arrow(from: Vector2, to: Vector2, p_kind: String = "spell", p_available: bool = true) -> void:
	from_point = from
	to_point = to
	kind = p_kind
	available = p_available
	_sync_color()
	_control = _default_control(from, to)
	active = true
	visible = true
	queue_redraw()


## 直线箭头（不需要弧度时用；控制点放在中点，所以曲率为 0）
func show_straight(from: Vector2, to: Vector2, p_kind: String = "spell") -> void:
	show_arrow(from, to, p_kind)
	_control = (from + to) * 0.5
	queue_redraw()


func hide_arrow() -> void:
	active = false
	locked = false
	visible = false
	queue_redraw()


## 吸附到目标中心（锁定）
func lock_to(center: Vector2) -> void:
	to_point = center
	locked = true
	_control = _default_control(from_point, to_point)
	queue_redraw()


func unlock_target() -> void:
	locked = false
	queue_redraw()


func set_to(point: Vector2) -> void:
	to_point = point
	if not locked:
		_control = _default_control(from_point, to_point)
	queue_redraw()


## 可用性决定颜色：可用=绿、不可用=红（卡牌能不能打、目标能不能指定）
func set_available(value: bool) -> void:
	if available == value:
		return
	available = value
	_sync_color()


func _sync_color() -> void:
	_color = COLOR_OK if available else COLOR_NO
	queue_redraw()


func _color_for(p_kind: String) -> Color:
	match p_kind:
		"attack":
			return COLOR_ATTACK
		"place":
			return COLOR_PLACE
		_:
			return COLOR_SPELL


## 控制点：把中点沿垂线偏移，形成可见的弧
func _default_control(from: Vector2, to: Vector2) -> Vector2:
	var mid := (from + to) * 0.5
	var dir := to - from
	if dir.length() < 1.0:
		return mid
	# 一律向上拱（屏幕 y 减小），看起来像"甩出去"的轨迹
	var perp := Vector2(-dir.y, dir.x).normalized()
	if perp.y > 0:
		perp = -perp
	return mid + perp * dir.length() * BOW_RATIO


## 二次贝塞尔上的点（测试用：可验证"确实是弧"）
func point_at(t: float) -> Vector2:
	var a := from_point.lerp(_control, t)
	var b := _control.lerp(to_point, t)
	return a.lerp(b, t)


## 曲率：曲线中点到直线的偏离距离（0 = 直线）
func bow() -> float:
	var mid := (from_point + to_point) * 0.5
	return point_at(0.5).distance_to(mid)


func control_point() -> Vector2:
	return _control


func _draw() -> void:
	if not active:
		return
	var width_scale: float = LOCKED_SCALE if locked else 1.0
	# 曲线本体：分段画线，宽度从起点到接近终点逐渐收细（留出箭头尖的位置）
	var outline := PackedVector2Array()
	for i in SEGMENTS + 1:
		var t := float(i) / float(SEGMENTS)
		outline.append(point_at(t))
	var body_end := SEGMENTS                       # 最后两段留给箭头
	for i in range(body_end):
		var t := float(i) / float(SEGMENTS)
		var w: float = lerpf(BASE_WIDTH, TIP_WIDTH, t) * width_scale
		draw_line(outline[i], outline[i + 1], _color, w, true)
	# 箭头尖：以一个三角形收尾，指向终点
	var tip := to_point
	var back := point_at(0.86)
	var dir := (tip - back)
	if dir.length() < 0.01:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var perp := Vector2(-dir.y, dir.x)
	var head_len: float = 26.0 * width_scale
	var head_w: float = 15.0 * width_scale
	var head := PackedVector2Array([
		tip,
		tip - dir * head_len + perp * head_w * 0.5,
		tip - dir * head_len - perp * head_w * 0.5,
	])
	draw_colored_polygon(head, _color)
	# 锁定目标时在终点画一个准心圈，强调"已锁定"
	if locked:
		draw_arc(tip, 14.0 * width_scale, 0.0, TAU, 24, _color, 2.5, true)
