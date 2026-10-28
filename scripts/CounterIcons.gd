extends RefCounted
## 「牌库 / 手牌 / 墓地 / 疲劳」四枚计数图标的**唯一绘制处**（照参考图里的图标 + 读数做法）。
##
## 刻意不写 `class_name`：新增全局类名要等编辑器重新扫描项目才生效，
## 调用方用 `preload("res://scripts/CounterIcons.gd")` 在任何环境都能立刻跑起来。
##
## 用法：`CounterIcons.draw_icon(self, index, cell_rect, color)`（第一个参数是任意 CanvasItem）。
## 状态信息框（`StatusPanel`）与记牌器的计数条（`TrackerPanel` / `CounterIcon`）共用这一套，
## 两处的图标因此永远是同一套画法，不会慢慢长成两种样子。

const ICON_INDEX_DECK := 0
const ICON_INDEX_HAND := 1
const ICON_INDEX_GRAVE := 2
const ICON_INDEX_FATIGUE := 3
const ICON_W := 13.0         ## 图标占的宽度（读数往右让出这一段）
const ICON_H := 13.0
## 计数读数的颜色来源（`StatusCounters` 的四个 getter），集中在这里避免两处各写一套
static func colors_for(p: PlayerState, hand_limit: int) -> Array:
	return [
		StatusCounters.deck_color(p),
		StatusCounters.hand_color(p, hand_limit),
		StatusCounters.grave_color(p),
		StatusCounters.fatigue_color(p),
	]


## 在某块区域的**左边缘中央**画第 `index` 枚图标
static func draw_icon(canvas: CanvasItem, index: int, cell: Rect2, col: Color) -> void:
	if canvas == null:
		return
	var c := Vector2(cell.position.x + 7.0, cell.get_center().y)
	match index:
		ICON_INDEX_DECK:      # 牌库：两张叠起来的牌
			_card(canvas, Rect2(c + Vector2(-4.5, -6.0), Vector2(7.0, 10.0)), col)
			_card(canvas, Rect2(c + Vector2(-2.0, -4.0), Vector2(7.0, 10.0)), col.lightened(0.25))
		ICON_INDEX_HAND:      # 手牌：三张扇形展开的牌
			for k in 3:
				var ang: float = -0.35 + 0.35 * float(k)
				canvas.draw_set_transform(c + Vector2(0, 1), ang, Vector2.ONE)
				_card(canvas, Rect2(Vector2(-3.0, -6.5), Vector2(6.0, 11.0)), col.lightened(0.08 * float(k)))
				canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		ICON_INDEX_GRAVE:     # 墓地：墓碑
			canvas.draw_rect(Rect2(c + Vector2(-5.0, -3.0), Vector2(10.0, 9.0)), _a(col, 0.85))
			canvas.draw_circle(c + Vector2(0, -3.0), 5.0, _a(col, 0.85))
			canvas.draw_line(c + Vector2(-2.0, -4.0), c + Vector2(2.0, -4.0), Color(0, 0, 0, 0.6), 1.0, true)
			canvas.draw_line(c + Vector2(0, -6.0), c + Vector2(0, -2.0), Color(0, 0, 0, 0.6), 1.0, true)
		_:                    # 疲劳：火苗
			var pts := PackedVector2Array([
				c + Vector2(0, -7.0), c + Vector2(4.0, -1.0), c + Vector2(3.0, 4.0),
				c + Vector2(0, 6.0), c + Vector2(-3.0, 4.0), c + Vector2(-4.0, -1.0),
			])
			canvas.draw_colored_polygon(pts, _a(col, 0.85))
			canvas.draw_circle(c + Vector2(0, 2.0), 2.0, Color(1, 0.92, 0.7, 0.9))


static func _card(canvas: CanvasItem, r: Rect2, col: Color) -> void:
	canvas.draw_rect(r, Color(0.06, 0.07, 0.10, 0.9))
	canvas.draw_rect(r, col, false, 1.0)


static func _a(col: Color, a: float) -> Color:
	return Color(col.r, col.g, col.b, a)

