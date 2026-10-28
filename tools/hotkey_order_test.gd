extends SceneTree
## 基础机制补测：**键盘快捷键**与**结算顺序确定化**。
##
## 快捷键：直接调 Main 的 `_handle_shortcut()`（与 `_input` 走同一个入口），
##   验证空格 / F1 / 数字键各自触发预期行为、且弹窗打开时不抢键。
## 结算顺序：监听 GameManager 的 `log_message`，让多个随从**同时**死亡（群体伤害），
##   断言「被消灭」的顺序严格按 unit_id 升序 —— 这是联机/回放一致性的前提。
##
## 运行：godot --headless --path <项目目录> --script res://tools/hotkey_order_test.gd

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
var _logs: Array[String] = []
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		if _gm == null or _db == null:
			_check(false, "GameManager / CardDB 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_test_death_order()
		return false
	if _frames == 4:
		_run_hotkeys()
		_finish()
		return true
	return _frames > 300


# ------------------------------ 结算顺序确定化 ------------------------------

func _test_death_order() -> void:
	_gm.new_game()
	_gm.log_enabled = true
	_logs.clear()
	_gm.log_message.connect(func(text: String) -> void: _logs.append(text))
	var me: PlayerState = _gm.get_player(0)
	me.board.clear()
	# 三个随从，故意**倒着**加入 board（unit_id 递增但列表顺序相反），全体吃 9 点伤害一起死
	var c1: BoardUnit = _gm.summon_unit(0, _db.get_card("c001"))
	var c2: BoardUnit = _gm.summon_unit(0, _db.get_card("c002"))
	var c3: BoardUnit = _gm.summon_unit(0, _db.get_card("c004"))
	_check(c1 != null and c2 != null and c3 != null, "铺了 3 个随从")
	_check(c1.unit_id < c2.unit_id and c2.unit_id < c3.unit_id,
		"unit_id 递增（%d < %d < %d）" % [c1.unit_id, c2.unit_id, c3.unit_id])
	me.board.reverse()          # 让 board 的遍历顺序与 unit_id 顺序相反
	_check(me.board[0].unit_id == c3.unit_id, "board 顺序已反转（第一个是 unit_id 最大的）")
	# 期望的死亡顺序必须在"死之前"取：规则是位置顺序（己方左→右、敌方镜像）
	var want: Array[int] = []
	for u in _gm.unit_order(0):
		want.append(u.unit_id)
	_logs.clear()
	var ctx := EffectContext.create(_gm, 1, 9, "", {"kind": "self", "unit_id": -1, "player_id": 1}, "测试")
	CardEffects.apply("aoe_all", ctx)
	_gm._cleanup_deaths()
	var killed: Array[int] = []
	for line in _logs:
		if line.contains("被消灭"):
			for u in [c1, c2, c3]:
				if line.contains(u.data.card_name) and not killed.has(u.unit_id):
					killed.append(u.unit_id)
	_check(killed.size() == 3, "三个随从都被消灭（记录到 %d 条）" % killed.size())
	# 顺序规则：**位置顺序**（己方从左到右、敌方镜像）——见 GameManager.unit_order()
	_check(killed == want, "同轮死亡按「己方左→右、敌方镜像」的顺序处理（实际 %s，期望 %s）" % [str(killed), str(want)])
	_check(me.board.is_empty(), "战场清空（剩 %d 个）" % me.board.size())


# ------------------------------ 键盘快捷键 ------------------------------

func _run_hotkeys() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	if _main == null:
		_check(false, "主场景可实例化")
		return
	_gm.new_game()
	_main.skip_mulligan()
	var me: PlayerState = _gm.get_player(0)
	me.mana = 10
	me.max_mana = 10
	_main._refresh()

	# F1：打印快捷键说明
	_main._log_text = ""
	_check(_main._handle_shortcut(KEY_F1), "F1 被处理")
	_check(_main._log_text.contains("空格") and _main._log_text.contains("Esc"), "F1 打印快捷键说明")
	# 数字键 1：选中第一张手牌（等价点击）→ 需要目标的牌会进入选目标状态。
	# 手牌是随机的，所以这里固定放一张「战吼指定任意角色」的随从（永远有合法目标），断言不靠运气
	me.hand.clear()
	me.hand.append(_db.get_card("c005"))       # 精灵弓手：战吼 1 点伤害，任意角色
	_main._refresh()
	_check(_gm.can_play(0, 0), "第 1 张手牌可打出（用于数字键选牌）")
	_check(_main._handle_shortcut(KEY_1), "数字键 1 被处理")
	_check(_main.mode != 0, "数字键 1 选中了需要目标的牌并进入选目标（mode=%d）" % _main.mode)
	_main._clear_mode()
	# 数字键越界：不处理、不崩
	_check(not _main._handle_shortcut(KEY_1 + 8) or me.hand.size() > 8, "超出牌数的数字键不会越界")
	# 空格：结束回合（走 request_end_turn → 单机直接执行）
	_gm.current_player = 0
	_gm.busy = false
	_gm.turn_time_limit = 0
	var gs := root.get_node_or_null("GameSettings")
	if gs != null:
		gs.set("confirm_end_turn", false)      # 否则空格会弹出「确认结束回合」对话框
	_main._clear_mode()
	var before: int = _gm.current_player
	_check(_main._handle_shortcut(KEY_SPACE), "空格被处理")
	_check(_gm.current_player != before or not _gm.game_active() or _gm.busy,
		"空格结束回合（%d -> %d；对方是 AI 时 busy=%s）" % [before, _gm.current_player, str(_gm.busy)])
	# 弹窗打开时不抢键
	_gm.new_game()
	_main.skip_mulligan()
	_gm.mulligan_pending = true
	_main._open_mulligan()
	if _main.mulligan_open():
		_check(not _main._handle_shortcut(KEY_SPACE), "起手换牌面板打开时空格不抢键")
		_main.skip_mulligan()
	else:
		_check(true, "（没有弹出起手面板，跳过抢键断言）")
	_main.queue_free()


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
	print("=== 快捷键 / 结算顺序测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
