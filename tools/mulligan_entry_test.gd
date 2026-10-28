extends SceneTree
## 「进入对战后能换手牌」回归测试。
##
## 背景（真 bug）：从主界面进对局时，`HomeMenu` 是 **先 `GameManager.new_game()`**（此刻发出
## `game_started`）**再切场景** → 信号发出时对局界面还没建好，`Main` 的起手换牌面板永远不弹；
## 客机侧换牌状态是随快照来的，也会错过同一个信号。
##
## 现在 `Main._sync_mulligan()` 会在 _ready（延迟一次）与每次 _refresh() 时兜底检查，
## 因此**任何入场路径**都能弹出换牌面板。本测试逐条固定这个行为。
##
## 运行：godot --headless --path <项目目录> --script res://tools/mulligan_entry_test.gd

var _fails := 0
var _frames := 0
var _gm
var _main
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		if _gm == null:
			_check(false, "GameManager 自动加载")
			_finish()
			return true
		# ① 模拟「从主界面点人机对战」：先开局，再切场景
		_gm.new_game()
		_check(_gm.mulligan_pending, "开局后处于「待换牌」状态")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_check(_main != null, "对局界面可实例化（等价于切场景后）")
		return false
	if _frames == 6:
		# ② 切场景前发出的 game_started 信号没人接，但 Main 延迟兜底后仍需弹出面板
		_check(_main.mulligan_open(), "切场景进入对局后**仍然弹出**起手换牌面板")
		_check(_main.mulligan_dialog() != null, "换牌面板对象存在（可点选要换掉的牌）")
		var dlg = _main.mulligan_dialog()
		if dlg != null:
			_check(dlg.visible, "换牌面板可见")
		# ③ 换完牌后面板关闭、待换牌状态清除
		_main.skip_mulligan()
		_check(not _gm.mulligan_pending, "换牌完成后「待换牌」状态清除")
		_check(not _main.mulligan_open(), "换牌完成后面板关闭")
		return false
	if _frames == 8:
		# ④ 客机路径：换牌状态随房主快照下发（不是 game_started 信号），刷新时要能弹出来
		_gm.mulligan_pending = true
		_main._refresh()
		_check(_main.mulligan_open(), "客机收到快照里的「待换牌」后也能弹出面板")
		_main.skip_mulligan()
		_check(not _main.mulligan_open(), "客机换完牌后面板关闭")
		# ⑤ 不属于待换牌状态时不该乱弹
		_gm.mulligan_pending = false
		_main._refresh()
		_check(not _main.mulligan_open(), "没有待换牌时不弹面板")
		_main.queue_free()
		return false
	if _frames >= 12:
		_finish()
		return true
	return _frames > 300


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 进入对局换手牌测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
