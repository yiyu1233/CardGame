extends SceneTree
## **逆向复刻核对截图**：把「抽卡动画」与「伤害飘字卡堆」的真实渲染帧存成 PNG，
## 便于改动表现层后对照原版核对（无需在运行时盯着屏幕）。
##
## 产出（`user://`，用 `ProjectSettings.globalize_path` 打印绝对路径）：
##   shot_20_draw_midflight.png  抽牌飞牌途中（0.40s 翻牌段，卡正朝落点飞）
##   shot_21_float_strong.png    7 点强击：放大红字 + 震屏 + 冲击环；旁边一条 3 点普通飘字
##   shot_22_draw_settled.png    0.65s 结束后卡已入手、飘字上浮淡出
##
## 依赖的真实实现：
##   `scripts/DeckPile.gd`（0.40s 翻牌 + 0.25s 入手 = 0.65s，落点用原版归一化公式）
##   `scripts/FloatText.gd`（2.5s、等字距 0.26×字号、序号层级递增的「卡堆」）
##
## 运行（**需要窗口**，无头模式没有渲染结果）：
##   godot --path <项目目录> --script res://tools/vfx_screenshot.gd

var _frames := 0
var _t := 0.0
var _stage := 0
var _gm
var _main


func _process(delta: float) -> bool:
	_frames += 1
	_t += delta
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		if _gm == null:
			push_error("GameManager 未自动加载")
			quit(1)
			return true
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _frames == 10:
		# 触发一次真实抽牌，让飞牌开始
		_gm.draw(0, 1)
		_main._update_piles()
		_stage = 1
		_t = 0.0
		return false
	if _stage == 1 and _t > 0.22:
		_shot("shot_20_draw_midflight")
		# 同时来一发 7 点强击（飘字放大 + 震屏 + 冲击环）与一条 3 点普通伤害
		_gm.amount_shown.emit(1, -1, 7, "damage")
		_gm.amount_shown.emit(1, -1, 3, "damage")
		_stage = 2
		_t = 0.0
		return false
	if _stage == 2 and _t > 0.15:
		_shot("shot_21_float_strong")
		_stage = 3
		return false
	if _stage == 3 and _t > 0.9:
		_shot("shot_22_draw_settled")
		_stage = 4
		return false
	if _stage == 4 and _t > 0.3:
		print("[vfx] 三张核对截图已保存")
		quit(0)
		return true
	return false


func _shot(shot_name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		push_error("取不到渲染结果（无头模式没有画面）")
		return
	var path := "user://%s.png" % shot_name
	img.save_png(path)
	print("[vfx] ", ProjectSettings.globalize_path(path))
