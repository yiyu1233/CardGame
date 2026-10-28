extends Control
## 一枚计数图标（牌库 / 手牌 / 墓地 / 疲劳）：**画法只有一个来源** —— `CounterIcons`。
##
## 这是给「容器里需要一枚固定宽度的小图标」的场景用的（记牌器的计数条）；
## 状态信息框（`StatusPanel`）自己在 `_draw()` 里调 `CounterIcons.draw_icon()`。
##
## 用法：`var ic := CounterIcon.new(); ic.index = 1; ic.set_color(c)`（刻意不写 class_name，
## 调用方用 `preload` 即可，见 `TrackerPanel`）。

const CounterIconsRef := preload("res://scripts/CounterIcons.gd")
const SIZE := Vector2(CounterIconsRef.ICON_W, CounterIconsRef.ICON_H)

var index := 0
var color := Color.WHITE


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = SIZE


func set_color(c: Color) -> void:
	color = c
	queue_redraw()


func _draw() -> void:
	CounterIconsRef.draw_icon(self, index, Rect2(Vector2.ZERO, size), color)
