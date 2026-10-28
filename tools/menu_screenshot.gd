extends SceneTree
## 标题界面 / 主界面截图（需要窗口运行，无头模式没有渲染结果）。
## 运行：godot --path <项目目录> --script res://tools/menu_screenshot.gd

var _f := 0
var _title
var _home


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 10:
		_title = load("res://scenes/Title.tscn").instantiate()
		root.add_child(_title)
		return false
	if _f == 30:
		_save("shot_9_title")
		_title.queue_free()
		_home = load("res://scenes/Home.tscn").instantiate()
		root.add_child(_home)
		return false
	if _f == 50:
		_save("shot_10_home")
		# 顺手演示匹配状态：开始匹配 → 等不到房间就自己开房等对手
		var net := root.get_node_or_null("Net")
		if net != null:
			net.match_host_delay = 0.05
			_home._on_match()
		return false
	if _f == 70:
		_save("shot_11_matchmaking")
		_home.queue_free()
		quit(0)
		return true
	return _f > 400


func _save(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png("user://%s.png" % name)
	print("[shot] ", name, " ", img.get_size())
