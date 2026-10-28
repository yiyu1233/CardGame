class_name UiUtil
extends RefCounted
## 界面小工具。

## 把一个**纯装饰**控件子树整体设为“不接收鼠标事件”。
##
## 为什么需要它：Control 的默认 mouse_filter 是 STOP，`RichTextLabel`、`HSeparator`、
## 以及用普通 `Control` 做的撑高占位块同样是 STOP。它们会把「在卡面上按下并拖动」这类
## 事件就地吃掉，事件不会再冒泡到真正处理交互的根控件（CardUI / UnitUI），
## 表现就是「只有部分区域能拖动、在描述文字上拖不动、悬停也不出详情」。
##
## 交互统一由子树的根控件自己处理，所以内部一律 IGNORE。
## 只对纯展示用的子树调用本函数；里面有 Button 等可交互控件时不要用。
static func make_decorative(root: Node) -> void:
	for child in root.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
			make_decorative(child)
		else:
			make_decorative(child)
