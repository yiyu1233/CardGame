extends SceneTree
## 鼠标输入测试：用**真实合成事件**验证卡牌 / 随从整块都能拖拽（不是只有部分区域）。
##
## 运行方式（**必须带窗口**，不能加 --headless）：
##   godot --path <项目目录> --script res://tools/input_test.gd
##
## 两点说明：
##   1. 无头模式下 `Viewport.push_input()` / `Input.parse_input_event()` 都不会把 GUI 事件投递给
##      控件（实测 hovered 恒为 null），所以鼠标交互只能在有窗口时验证；本脚本只投递合成事件、
##      不会移动系统鼠标，窗口出现约 1 秒后自动退出。
##   2. 事件坐标必须用**视口局部**坐标（`push_input(ev, true)`），这是 `get_global_rect()` 的坐标系；
##      默认的 false 是屏幕坐标，会被窗口位置整体偏移而点不中控件。
##
## 背景：Control 默认 mouse_filter = STOP，`RichTextLabel`、`HSeparator`、以及用普通 `Control`
## 做的撑高占位块同样是 STOP。它们会把「按下并拖动」事件就地吃掉，事件不再冒泡到真正处理交互的
## 根控件，于是出现「卡牌部分区域拖不动、悬停也不出详情」。

var _fails := 0
var _frames := 0
var _db
var _gm
var _main
var _fail_lines: Array[String] = []
var _hand_index := -1
var _tracker_poll_until := 0     ## 等滑动动画推进的帧预算（>0 表示正在等）


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if DisplayServer.get_name() == "headless":
			print("[SKIP] 无头模式无法投递 GUI 事件，本测试请去掉 --headless 运行。")
			quit(0)
			return true
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		print("--- 输入测试（窗口模式，画布 %s）---" % str(root.get_visible_rect().size))
		return false
	if _frames == 2:
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _frames == 6:
		_gm.new_game()
		# 开局会弹出起手换牌面板（会吃住鼠标事件），这里先验证它出现了再跳过——
		# 后面所有用例都是合成鼠标事件，面板开着会把它们全挡住。
		_check(_main.mulligan_open(), "开局弹出起手换牌面板")
		_main.skip_mulligan()
		_check(not _main.mulligan_open(), "跳过起手换牌后面板关闭")
		var me: PlayerState = _gm.get_player(0)
		me.mana = 10
		me.max_mana = 10
		return false
	if _frames == 10:
		_test_card_regions()
		return false
	if _frames == 12:
		# 铺一个随从，等界面刷新后测随从的各个区域
		_gm.summon_unit(0, _gm.card_by_id("c002"))
		_main._request_refresh()
		return false
	if _frames == 15:
		_test_unit_regions()
		return false
	# 记牌器抽屉：先等滑入动画真的推进（生产配置 0.18s），再核对到位后的几何
	if _tracker_poll_until > 0:
		var d: Variant = _main._tracker_panel
		if d == null or not is_instance_valid(d):
			_tracker_poll_until = 0
			return false
		if d.offset_left < d._closed_left() - 5.0:
			_check(true, "抽屉滑入动画确实在推进（offset_left 已到 %.1f）" % d.offset_left)
			_tracker_poll_until = 0
			_test_tracker_geometry()
		elif _frames > _tracker_poll_until:
			_check(false, "抽屉滑入动画没有推进（offset_left 仍为 %.1f，可能卡在屏幕外）" % d.offset_left)
			_tracker_poll_until = 0
			_test_tracker_geometry()
		return false
	if _frames == 16:
		_test_tracker_open()
		return false
	if _frames == 18:
		_test_hero_frame_hit()
		return false
	if _frames == 20:
		_test_hover_detail()
		return false
	if _frames == 21:
		_test_unaffordable_card()
		return false
	if _frames == 22:
		_gm.new_game()
		_main.skip_mulligan()          # 面板会挡住后面的合成鼠标事件
		var me: PlayerState = _gm.get_player(0)
		me.mana = 10
		me.max_mana = 10
		# 在这一帧就把「可出场的随从」准备好：新加的卡要等一帧、内部布局稳定后卡面矩形才有效，
		# 否则下一帧拿到的描述区矩形还是退化值，点不到卡上（会偶发失败）。
		_check(_first_plain_minion_index() >= 0, "手里有可出场的随从（端到端）")
		return false
	if _frames >= 24 and _frames < 60:
		# new_game() 之后回合启动/AI 可能还在跑，等局面稳定（可出牌）再拖，避免偶发失败
		if not _settled_for_drag():
			return false
		_test_main_drag_from_description()
		_finish()
		return true
	if _frames > 400:
		_check(false, "测试超时")
		_finish()
		return true
	return false


# ------------------------------ 手牌 ------------------------------

## 局面是否已经稳定到「我方可以出牌」（new_game 后回合启动、AI 协程都可能还在跑）
func _settled_for_drag() -> bool:
	return _gm.game_active() and not _gm.busy and _gm.current_player == 0


func _first_plain_minion_index() -> int:
	var me: PlayerState = _gm.get_player(0)
	for i in me.hand.size():
		var c: CardData = me.hand[i]
		if c.card_type == CardData.CardType.MINION and not c.needs_target():
			return i
	for c in _db.cards:
		if c.card_type == CardData.CardType.MINION and not c.is_token and not c.needs_target():
			me.hand.append(c.clone())
			_main._refresh()
			return me.hand.size() - 1
	return -1


func _test_card_regions() -> void:
	_hand_index = _first_plain_minion_index()
	_check(_hand_index >= 0, "手里有可出场的随从")
	if _hand_index < 0:
		return
	# 法力设为 0：本阶段只验证「能不能拖起来」，不让点击/拖动意外把牌打出去
	# （一旦出牌就会触发敌方 AI，后续用例的时机就不可控了）
	_gm.get_player(0).mana = 0
	# 用**手牌最右边那张**做位置用例：停靠时扇形叠得比较紧，中间那张的边缘会被右边的牌压住，
	# 按下命中的其实是压在上面的那张（这也正是玩家看到的行为）。
	var card: CardUI = _main.hand_cards[_main.hand_cards.size() - 1]
	print("  [diag] card=%s hand_area=%s" % [
		str(card.get_global_rect()), str(_main.hand_area.get_global_rect())])
	var points := {
		"名称": "Margin/VBox/NameLabel",
		"攻防": "Margin/VBox/StatsLabel",
		"关键字": "Margin/VBox/KeywordLabel",
		"分隔线": "Margin/VBox/Separator",
		"描述文字": "Margin/VBox/DescLabel",
	}
	for label in points:
		var node: Control = card.get_node_or_null(points[label])
		if node == null:
			_check(false, "卡面子节点存在：%s" % points[label])
			continue
		_check(_card_drag_starts(card, _node_center(node)),
			"从手牌的「%s」区域按下并拖动可以开始拖拽" % label)

	# 手牌是带旋转的扇形，所以边缘点要用控件自己的变换换算，不能用外接矩形
	var w: float = card.size.x
	var h: float = card.size.y
	var edges := {
		"正中": Vector2(w * 0.5, h * 0.5),
		"上边缘": Vector2(w * 0.5, 3.0),
		"下边缘": Vector2(w * 0.5, h - 3.0),
		"左边缘": Vector2(3.0, h * 0.5),
		"右边缘": Vector2(w - 3.0, h * 0.5),
	}
	for label in edges:
		var p: Vector2 = card.get_global_transform() * edges[label]
		_check(_card_drag_starts(card, p), "从手牌%s可以开始拖拽（旋转 %.1f°）" % [
			label, rad_to_deg(card.rotation)])

	# 点击 / 右键仍然正常（设为 IGNORE 不应把点击也吃掉）——放在拖拽用例之后，
	# 因为点击一张可打出的牌会真的把它打出去。
	var clicked := [false]
	var right := [false]
	card.clicked.connect(func(_i: int) -> void: clicked[0] = true)
	card.right_clicked.connect(func(_i: int) -> void: right[0] = true)
	var center: Vector2 = card.get_global_rect().get_center()
	_press_release(center, MOUSE_BUTTON_LEFT)
	_check(clicked[0], "点一下手牌（不移动）仍然算点击")
	_press_release(center, MOUSE_BUTTON_RIGHT)
	_check(right[0], "右键手牌仍然可用")


# ------------------------------ 随从 ------------------------------

func _test_unit_regions() -> void:
	var board: BoardSurface = _main.player_board
	# 随从控件装在一格普通 Control 里（横置旋转不会被容器重置），所以要往下一层找
	var unit_ui: UnitUI = null
	for child in board.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is UnitUI:
			unit_ui = child
			break
		for sub in child.get_children():
			if sub is UnitUI and not sub.is_queued_for_deletion():
				unit_ui = sub
				break
		if unit_ui != null:
			break
	_check(unit_ui != null, "战场上出现随从控件")
	if unit_ui == null:
		return

	var r: Rect2 = unit_ui.get_global_rect()
	# 12% 名称区、50% 中段（原来是普通 Control 占位块，会吃掉事件）、88% 攻防区
	var ratios := {"名称区": 0.12, "中段": 0.5, "攻防区": 0.88}
	for label in ratios:
		var ratio: float = ratios[label]
		var p := Vector2(r.get_center().x, r.position.y + r.size.y * ratio)
		_check(_unit_drag_starts(unit_ui, p), "随从「%s」按下并拖动可以发起攻击拖拽" % label)
	_check(_unit_drag_starts(unit_ui, Vector2(r.position.x + 3.0, r.get_center().y)), "随从左边框也能拖动")
	_check(_unit_drag_starts(unit_ui, Vector2(r.position.x + r.size.x - 3.0, r.get_center().y)), "随从右边框也能拖动")

	var clicked := [false]
	unit_ui.unit_clicked.connect(func(_id: int) -> void: clicked[0] = true)
	_press_release(r.get_center(), MOUSE_BUTTON_LEFT)
	_check(clicked[0], "点一下随从仍然算点击")


# ------------------------------ 记牌器抽屉 ------------------------------

func _click_tracker_button() -> void:
	var btn: RoundButton = _main.tracker_button
	if btn == null or not is_instance_valid(btn):
		_check(false, "中线左端有记牌器按钮")
		return
	_press_release(_node_center(btn), MOUSE_BUTTON_LEFT)


## 点按钮 → 抽屉开始滑入（这里只断言「已打开 + 动画确实在跑」）
func _test_tracker_open() -> void:
	_click_tracker_button()
	var drawer: Variant = _main._tracker_panel
	_check(drawer != null and is_instance_valid(drawer) and drawer.is_open() and drawer.visible,
		"点中线左端的记牌器按钮会从右侧滑出抽屉")
	if drawer == null or not is_instance_valid(drawer):
		return
	_check(drawer.slide_time > 0.0, "抽屉使用滑入动画（%.2fs）" % drawer.slide_time)
	_tracker_poll_until = _frames + 45


## 动画推进后，核对到位位置与「不占据中间场地」，最后再点一次收起
func _test_tracker_geometry() -> void:
	var cls = load("res://scripts/TrackerPanel.gd")
	var drawer: Variant = _main._tracker_panel
	if drawer == null or not is_instance_valid(drawer):
		_check(false, "记牌器抽屉仍存在")
		return
	_click_tracker_button()                   # 再点一次 = 收起
	_check(not drawer.is_open(), "再点一次左端按钮收起抽屉")

	# 动画时间置 0，这一帧就能检查“到位”后的位置
	drawer.slide_time = 0.0
	drawer.close()
	drawer.open()
	var rect: Rect2 = drawer.get_global_rect()
	var arena: Rect2 = _main.arena_panel.get_global_rect()
	_check(absf(rect.size.x - cls.DRAWER_WIDTH) < 1.0,
		"抽屉宽度 %.0f（实际 %.0f）" % [cls.DRAWER_WIDTH, rect.size.x])
	_check(rect.position.x >= arena.position.x + arena.size.x,
		"抽屉落在竞技区右侧、不占据中间场地（%.0f ≥ %.0f）" % [rect.position.x, arena.position.x + arena.size.x])
	_check(rect.position.x + rect.size.x <= drawer.get_parent_area_size().x,
		"抽屉完全在窗口内（右缘 %.0f）" % (rect.position.x + rect.size.x))

	var log_panel: Control = _main.get_node_or_null("Root/LogPanel")
	if log_panel != null:
		var lr: Rect2 = log_panel.get_global_rect()
		_check(rect.position.x <= lr.position.x + 1.0 and rect.size.x >= lr.size.x - 1.0,
			"抽屉正好盖住右侧日志栏、不占别处（日志栏 %.0f–%.0f）" % [lr.position.x, lr.position.x + lr.size.x])
	drawer.close()


# ------------------------------ 主战者框的圆形命中 ------------------------------

func _test_hero_frame_hit() -> void:
	var frame = _main.enemy_hero_frame
	if frame == null or not is_instance_valid(frame):
		_check(false, "敌方主战者框存在（用于点击测试）")
		return
	var hits := [0]
	frame.pressed.connect(func(_pid: int) -> void: hits[0] += 1)

	# 圆心 = 点到英雄：这是「拖拽/点击指定英雄为目标」的入口
	var center: Vector2 = frame.global_position + frame.disc_center_local()
	_press_release(center, MOUSE_BUTTON_LEFT)
	_check(hits[0] == 1, "点主战者框圆心＝指定该英雄（触发 %d 次）" % hits[0])

	# 四角在圆形之外：不该被框吃掉，鼠标应落到框后面的东西上
	var corner: Vector2 = frame.global_position + Vector2(6, 6)
	_press_release(corner, MOUSE_BUTTON_LEFT)
	_check(hits[0] == 1, "点主战者框四角不触发（圆形命中，四角让给底下的卡牌）")


# ------------------------------ 法力不足的牌 ------------------------------

## 打不出的牌**可以拿起来比划**（选项 B）：幽灵卡是红色禁止样式、落点不点亮，
## 松手时说明具体原因，且手牌 / 战场都不变。
func _test_unaffordable_card() -> void:
	var me: PlayerState = _gm.get_player(0)
	me.max_mana = 10
	me.mana = 0
	_main._refresh()

	var card_ui: CardUI = null
	var cost := 0
	var name := ""
	var idx := -1
	for i in range(_main.hand_cards.size() - 1, -1, -1):
		var c: CardData = me.hand[i]
		if c.cost > 0:
			card_ui = _main.hand_cards[i]
			cost = c.cost
			name = c.card_name
			idx = i
			break
	_check(card_ui != null and cost > 0, "手里有费用 > 0 的牌（用于法力不足用例）")
	if card_ui == null:
		return
	_check(not card_ui.playable, "法力不足的牌在界面上被标记为不可打出")

	var start: Vector2 = _node_center(card_ui.get_node("Margin/VBox/DescLabel"))
	var board_center: Vector2 = _main.player_board.get_global_rect().get_center()
	var hand_before: int = me.hand.size()
	var board_before: int = me.board.size()

	# 真实拖拽：按下 → 移到战场 → 松手
	_mouse_motion(start)
	_mouse_button(start, true, MOUSE_BUTTON_LEFT)
	var steps := 6
	for i in range(1, steps + 1):
		_mouse_motion(start.lerp(board_center, float(i) / float(steps)))

	# 拖拽中：进入了拖拽状态、幽灵卡存在且是红色禁止样式、落点没被点亮
	_check(_main.drag_kind != 0, "打不出的牌也能拿起来比划（drag_kind=%d）" % _main.drag_kind)
	_check(_main.drag_forbidden, "拖拽被标记为「打不出」")
	var ghost: CardUI = _main._ghost
	_check(ghost != null and is_instance_valid(ghost), "拖拽中出现了幽灵卡")
	if ghost != null and is_instance_valid(ghost):
		_check(ghost.forbidden and ghost.modulate.r > ghost.modulate.b,
			"幽灵卡是红色禁止样式（forbidden=%s，色偏 r=%.2f b=%.2f）" % [
				str(ghost.forbidden), ghost.modulate.r, ghost.modulate.b])
	# 操作栏与落点提示每帧由 _process 刷新；同一帧内的合成事件不经过 _process，所以这里手动调一次
	_main._update_drop_feedback(_main._drag_mouse)
	_check(_main._drop_hint == null or not _main._drop_hint.visible, "打不出的牌不会点亮落点")
	_check(_main.hint_label.text.contains("法力不足"), "操作栏说明原因：%s" % _main.hint_label.text)

	_mouse_button(board_center, false, MOUSE_BUTTON_LEFT)

	_check(me.hand.size() == hand_before and me.board.size() == board_before,
		"松手后不会被释放（手牌 %d，战场 %d）" % [me.hand.size(), me.board.size()])
	var log_text: String = _main._log_text
	_check(log_text.contains("法力不足") and log_text.contains("需要 %d 点" % cost) and log_text.contains(name),
		"松手后给出具体原因（需要 %d 点 / 当前 %d 点）" % [cost, me.mana])
	_check(_main._ghost == null and _main.drag_kind == 0, "松手后拖拽状态清理干净")


# ------------------------------ 悬停详情 ------------------------------

func _test_hover_detail() -> void:
	if _main.hand_cards.is_empty():
		_check(false, "手牌仍在")
		return
	var card: CardUI = _main.hand_cards[_main.hand_cards.size() - 1]
	var desc: Control = card.get_node_or_null("Margin/VBox/DescLabel")
	if desc == null:
		_check(false, "卡面描述节点存在")
		return
	_main.card_detail.hide_card()
	_mouse_motion(Vector2(40, 40))
	_mouse_motion(_node_center(desc))
	_check(_main.card_detail.visible, "鼠标移到「描述文字」上会弹出卡牌详情")


# ------------------------------ 端到端：从描述区把牌拖到战场 ------------------------------

func _test_main_drag_from_description() -> void:
	# 局面已在上一帧准备好（new_game + 手里有可出场的随从 + 卡面布局已稳定）。
	# 这里不要再 new_game()：新加的卡要等一帧内部布局才有效，否则会把准备好的局面又打乱。
	var me: PlayerState = _gm.get_player(0)
	me.mana = 10
	var idx := _first_plain_minion_index()
	if idx < 0:
		_check(false, "手里有可出场的随从（端到端）")
		return

	var card_ui: CardUI = _main.hand_cards[idx]
	var desc: Control = card_ui.get_node("Margin/VBox/DescLabel")
	var start: Vector2 = _node_center(desc)
	var board_center: Vector2 = _main.player_board.get_global_rect().get_center()

	var hand_before: int = me.hand.size()
	var board_before: int = me.board.size()

	# 真实拖拽：先移动鼠标到描述文字上（真实操作也是先悬停再按下）→ 分几步移动到战场 → 松手
	var started := [false]
	var card_card: CardData = me.hand[idx]
	card_ui.drag_started.connect(func(_i: int) -> void: started[0] = true)
	_mouse_motion(start)
	_mouse_button(start, true, MOUSE_BUTTON_LEFT)
	var steps := 6
	for i in range(1, steps + 1):
		_mouse_motion(start.lerp(board_center, float(i) / float(steps)))
	var drop: Dictionary = _main._drop_target_at(board_center)
	var kind_during: int = _main.drag_kind
	var forbidden_during: bool = _main.drag_forbidden
	_mouse_button(board_center, false, MOUSE_BUTTON_LEFT)
	if not me.hand.size() == hand_before - 1:
		print("  [diag] 拖拽未生效：started=%s drag_kind=%d forbidden=%s card=%s(%d费) mana=%d/%d busy=%s 手牌=%d→%d" % [
			str(started[0]), kind_during, str(forbidden_during), card_card.card_name, card_card.cost,
			me.mana, me.max_mana, str(_gm.busy), hand_before, me.hand.size()])

	_check(me.hand.size() == hand_before - 1,
		"从「描述文字」区域拖到战场成功出牌（手牌 %d -> %d）" % [hand_before, me.hand.size()])
	_check(me.board.size() > board_before,
		"随从确实上场了（战场 %d -> %d）" % [board_before, me.board.size()])


# ------------------------------ 输入辅助 ------------------------------

## 节点中心点的全局坐标（用控件自己的变换，兼容手牌扇形的旋转）
func _node_center(node: Control) -> Vector2:
	return node.get_global_transform() * (node.size * 0.5)


## 在手牌上按下 → 移动 → 原地松手（落点仍在手牌区，所以只会取消，不会真的出牌）
## 注意：GDScript 的 lambda **按值捕获局部变量**，所以这里用一个数组当可变盒子，
## 否则 `flag[0] = true` 改的是副本，断言永远看到 false。
func _card_drag_starts(card: CardUI, point: Vector2) -> bool:
	var r: Rect2 = card.get_global_rect()
	point = point.clamp(r.position + Vector2(4, 4), r.end - Vector2(4, 4))
	var flag := [false]
	var cb := func(_i: int) -> void: flag[0] = true
	card.drag_started.connect(cb)
	# 真实操作一定是先把鼠标移到卡上再按下；GUI 需要一次移动来确定“鼠标下的控件”
	_mouse_motion(point)
	_mouse_button(point, true, MOUSE_BUTTON_LEFT)
	_mouse_motion(point + Vector2(0.0, -26.0))
	_mouse_button(point + Vector2(0.0, -26.0), false, MOUSE_BUTTON_LEFT)
	card.drag_started.disconnect(cb)
	return flag[0]


func _unit_drag_starts(unit_ui: UnitUI, point: Vector2) -> bool:
	var flag := [false]
	var cb := func(_id: int) -> void: flag[0] = true
	unit_ui.unit_drag_started.connect(cb)
	_mouse_motion(point)
	_mouse_button(point, true, MOUSE_BUTTON_LEFT)
	_mouse_motion(point + Vector2(0.0, 26.0))
	_mouse_button(point + Vector2(0.0, 26.0), false, MOUSE_BUTTON_LEFT)
	unit_ui.unit_drag_started.disconnect(cb)
	return flag[0]


func _press_release(point: Vector2, button: int) -> void:
	_mouse_motion(point)
	_mouse_button(point, true, button)
	_mouse_button(point, false, button)


## 第二个参数 true = 事件坐标是视口局部坐标（与 get_global_rect 同一坐标系）
func _mouse_button(pos: Vector2, pressed: bool, button: int) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	root.push_input(ev, true)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = Vector2.ZERO
	ev.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(ev, true)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 输入测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
