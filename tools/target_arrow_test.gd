extends SceneTree
## 指向箭头测试：卡牌释放不再画黄色矩形，而是从卡牌/随从拉一条**弧形箭头**指向目标。
##
## 覆盖：
##   ① 箭头几何：二次贝塞尔确实是弧（`bow() > 0`）、起终点正确、`show_straight` 为直线；
##   ② 选中指定法术（CARD_TARGET）→ 箭头出现、起点在卡牌上、颜色类别为 spell；
##   ③ 鼠标压在合法目标上 → 箭头**吸附锁定**到目标中心（终点 ≈ 目标中心、locked=true）；
##   ④ 攻击指定（ATTACK_TARGET）→ 箭头起点在随从上、类别为 attack；
##   ⑤ 取消 / 结束后箭头隐藏；
##   ⑥ **没有黄色矩形标注**：UnitUI.highlighted 全为 false、英雄框未被高亮。
##
## 运行（需要窗口，鼠标坐标才真实）：godot --path <项目目录> --script res://tools/target_arrow_test.gd

const ARROW_SCRIPT := "res://scripts/TargetArrow.gd"

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
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
		_test_geometry()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_check(_main != null, "对局界面可实例化")
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _frames == 6:
		_test_spell_arrow()
		return false
	if _frames == 10:
		_test_attack_arrow()
		return false
	if _frames == 14:
		_main.queue_free()
		return false
	if _frames >= 18:
		_finish()
		return true
	return _frames > 300


# ------------------------------ ① 几何 ------------------------------

func _test_geometry() -> void:
	var arrow = load(ARROW_SCRIPT).new()
	root.add_child(arrow)
	arrow.show_arrow(Vector2(100, 500), Vector2(700, 200), "spell")
	_check(arrow.visible and arrow.active, "show_arrow 后箭头可见")
	_check(arrow.point_at(0.0).distance_to(Vector2(100, 500)) < 0.5, "曲线起点 = 卡牌位置")
	_check(arrow.point_at(1.0).distance_to(Vector2(700, 200)) < 0.5, "曲线终点 = 目标位置")
	_check(arrow.bow() > 20.0, "是弧形（中点到直线偏离 %.1fpx）" % arrow.bow())
	_check(arrow.control_point() != Vector2.ZERO, "控制点已计算（%s）" % str(arrow.control_point()))
	# 锁定：终点吸附到目标中心 + 加粗标记
	arrow.lock_to(Vector2(700, 200))
	_check(arrow.locked, "lock_to 后处于锁定状态")
	_check(arrow.point_at(1.0).distance_to(Vector2(700, 200)) < 0.5, "锁定后终点仍落在目标中心")
	# 直线（工具用）
	arrow.show_straight(Vector2(0, 0), Vector2(400, 0), "attack")
	_check(arrow.bow() < 0.5, "show_straight 是直线（偏离 %.2fpx）" % arrow.bow())
	_check(arrow.kind == "attack", "箭头类别可切换（%s）" % arrow.kind)
	arrow.hide_arrow()
	_check(not arrow.visible and not arrow.active, "hide_arrow 后隐藏")
	arrow.queue_free()


# ------------------------------ ②③ 指定法术的箭头 ------------------------------

func _test_spell_arrow() -> void:
	var me: PlayerState = _gm.get_player(0)
	# 放一张能打任意角色的法术（雷霆一击）到手牌首位
	me.hand.clear()
	var pick: CardData = null
	for c in _db.cards:
		if c.card_type != CardData.CardType.SPELL or not c.needs_target():
			continue
		for t in _gm.get_valid_targets(0, c):
			if int(t["unit_id"]) < 0 and int(t["player_id"]) == 1:
				pick = c
				break
		if pick != null:
			break
	_check(pick != null, "找到一张可以指定敌方英雄的法术（%s）" % ("无" if pick == null else pick.card_name))
	me.hand.append(pick if pick != null else _db.get_card("s005"))
	me.mana = 10
	me.max_mana = 10
	_main._refresh()
	# 把鼠标注入到一个**没有目标的空白处**再进入选目标状态：
	# `_mouse_now()` 在没有任何事件时会退回真实系统光标（自动化 / CI 下位置不可控），
	# 先注入一次 motion 事件才能保证这里真的是「还没压到目标」。
	_move_mouse(Vector2(24, 24))
	_main._enter_card_target(0)
	_check(_main.mode == 1, "选中指定法术后进入 CARD_TARGET（mode=%d）" % _main.mode)
	_main._update_target_arrow()
	_check(_main.target_arrow_active(), "选中指定法术后出现指向箭头")
	_check(_main.target_arrow() != null and not _main.target_arrow().available, "还没压到目标时箭头是「不可用」配色（红）")
	var arrow = _main.target_arrow()
	_check(arrow != null and arrow.kind == "spell", "箭头类别 = spell（%s）" % ("无" if arrow == null else arrow.kind))
	if arrow != null:
		var card_center: Vector2 = _main._hand_card_center(0)
		_check(arrow.from_point.distance_to(card_center) < 1.0, "箭头起点就在那张手牌上")
	# 鼠标压到敌方英雄上 → 锁定
	var hero: Rect2 = _main.enemy_hero_frame.get_global_rect()
	_move_mouse(hero.get_center())
	_main._last_mouse = hero.get_center()
	_main._update_target_arrow()
	if arrow != null:
		_check(arrow.locked, "鼠标压在敌方英雄上时箭头锁定目标")
		_check(arrow.available, "压在合法目标上时箭头变为「可用」配色（绿）")
		_check(arrow.to_point.distance_to(hero.get_center()) < 6.0,
			"锁定后终点 = 目标中心（偏差 %.1fpx）" % arrow.to_point.distance_to(hero.get_center()))
	# ⑥ 没有黄色矩形
	var highlighted := 0
	for row in [_main.enemy_board, _main.player_board]:
		for ui in _main._live_unit_uis(row):
			if ui.highlighted:
				highlighted += 1
	_check(highlighted == 0, "选中目标时没有随从被画成黄色矩形（%d 个）" % highlighted)
	_check(not _main.enemy_hero_frame.is_highlighted(), "敌方英雄框也没有黄色矩形高亮")
	# ⑤ 取消后箭头消失
	_main._clear_mode()
	_main._update_target_arrow()
	_check(not _main.target_arrow_active(), "取消后箭头隐藏")


# ------------------------------ ④ 攻击指定的箭头 ------------------------------

func _test_attack_arrow() -> void:
	var me: PlayerState = _gm.get_player(0)
	var foe: PlayerState = _gm.get_player(1)
	# 我方一个可攻击的随从 + 敌方一个目标
	var mine: BoardUnit = _gm.summon_unit(0, _db.get_card("c001"))
	mine.summoned_turn = -1
	mine.attacks_used = 0
	var theirs: BoardUnit = _gm.summon_unit(1, _db.get_card("c002"))
	_gm.current_player = 0
	_gm.busy = false
	_main._refresh()
	_main._enter_attack_target(mine.unit_id)
	_check(_main.mode == 2, "选择攻击目标时进入 ATTACK_TARGET（mode=%d）" % _main.mode)
	_main._update_target_arrow()
	var arrow = _main.target_arrow()
	_check(_main.target_arrow_active(), "攻击指定时也出现箭头")
	_check(arrow != null and arrow.kind == "attack", "箭头类别 = attack（%s）" % ("无" if arrow == null else arrow.kind))
	if arrow != null:
		var unit_center: Vector2 = _main._unit_center(mine.unit_id)
		_check(arrow.from_point.distance_to(unit_center) < 1.0, "箭头起点在发起攻击的随从上")
	# 鼠标压到敌方随从上 → 锁定
	_move_mouse(_unit_center_of(theirs.unit_id))
	_main._last_mouse = _unit_center_of(theirs.unit_id)
	_main._update_target_arrow()
	if arrow != null:
		_check(arrow.locked, "鼠标压在敌方随从上时箭头锁定")
	_main._clear_mode()
	_main._update_target_arrow()
	_check(not _main.target_arrow_active(), "取消攻击后箭头隐藏")


func _unit_center_of(unit_id: int) -> Vector2:
	return _main._unit_center(unit_id)


# ------------------------------ 辅助 ------------------------------

func _move_mouse(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	root.push_input(ev, true)


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
	print("=== 指向箭头测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
