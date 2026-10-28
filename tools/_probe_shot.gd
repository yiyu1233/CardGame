extends SceneTree
## 临时截图：复刻后的抽卡动画与伤害飘字（用完即删）

var _frames := 0
var _t := 0.0
var _gm
var _main
var _stage := 0


func _process(delta: float) -> bool:
	_frames += 1
	_t += delta
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
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
		# 同时来一发 7 点强击（飘字放大 + 震屏 + 冲击环）
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
		print("[shot] done")
		quit(0)
		return true
	return false


func _shot(name: String) -> void:
	var img := root.get_texture().get_image()
	var path := "user://%s.png" % name
	img.save_png(path)
	print("[shot] ", ProjectSettings.globalize_path(path))
