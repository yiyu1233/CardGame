extends SceneTree
## 抽牌堆测试：右侧（我方）/ 左侧（敌方镜像）的牌堆，**厚度 = 剩余牌库数量**，抽牌有动画。
##
## 覆盖：
##   ① 两块牌堆都存在、不被鼠标穿透（不影响操作）；
##   ② 厚度与剩余牌数对应（0 张 = 不画；张数越多越厚；上限封顶）；
##   ③ 计数文案显示真实剩余张数；
##   ④ 抽卡动画时序照原版 Shadowverse（`docs/shadowverse-draw-animation.md` §10.1）：
##      **0.40s 翻牌（easeOutCirc）+ 0.25s 入手（easeOutQuad）= 0.65s**，
##      牌堆在动画**开始那一帧**就少一张（原版瞬时隐藏一张），`count` 始终是真实值；
##      飞牌先飞向「翻牌落点（屏幕中心偏右）」再飞向手牌槽位；
##   ⑤ 真实抽牌（GameManager.draw）会触发对应牌堆的动画，并把厚度刷成新的真实值；
##   ⑥ 位置：我方牌堆在手牌区**右侧**、敌方牌堆镜像在其手牌行左侧。
##
## 注意：动画按时长推进，所以这里按**累计时间**判定，不按帧数（帧率随环境变化）；
##       引擎时钟在低帧率下比累计 delta 略慢，所以等待量都留了余量。
##
## 运行（需要窗口，坐标/布局才真实）：godot --path <项目目录> --script res://tools/deck_pile_test.gd

const PILE_SCRIPT := "res://scripts/DeckPile.gd"

var _fails := 0
var _frames := 0
var _t := 0.0
var _stage := 0
var _gm
var _main
var _loose = null
var _deck_before := 0
var _fail_lines: Array[String] = []
## ④ 飞行时间轴的中间量
var _orig_draw_target := Vector2.ZERO
var _flight_reveal_target := Vector2.ZERO
var _pile_start := Vector2.ZERO
var _d_start := 0.0
var _d_mid := 0.0
var _mid_pos := Vector2.ZERO


func _process(delta: float) -> bool:
	_frames += 1
	_t += delta
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		if _gm == null:
			_check(false, "GameManager 自动加载")
			_finish()
			return true
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _frames == 8:
		_setup_loose_pile()
		_test_piles()
		# ④ 飞行时间轴（离线推进，不占真实时间）：翻牌落点 → 手牌终点
		_orig_draw_target = _loose.draw_target
		_flight_reveal_target = _loose.global_position + Vector2(420.0, 120.0)
		_loose.reveal_target = _flight_reveal_target
		_loose.animate_draw()
		_check(_loose.is_animating(), "animate_draw 后进入动画状态")
		_pile_start = _loose.flying_center()
		_d_start = _pile_start.distance_to(_flight_reveal_target)
		_advance_flight(0)
		return false
	# 离线推进已把动画跑完，交给真实时钟走「⑤ 真实抽牌」两段
	if _stage == 3 and _t > 1.2:
		_check(not _loose.is_animating(), "动画约 0.65 秒后自动结束（离线推进到 %.2fs）" % _loose._anim_t)
		_check(_loose.count_text() == "牌库 22", "动画结束时显示张数 -1（%s）" % _loose.count_text())
		_loose.queue_free()
		# ⑤ 真实抽牌：触发动画 + 厚度刷新为新牌数
		_deck_before = _gm.get_player(0).deck.size()
		_gm.draw(0, 1)
		_main._update_piles()
		var pile = _main.player_pile()
		_check(pile != null and pile.count == _deck_before - 1,
			"真实抽牌后牌堆厚度对应新牌数（%d -> %d）" % [_deck_before, 0 if pile == null else pile.count])
		_check(pile != null and pile.is_animating(), "真实抽牌会触发牌堆动画")
		if pile != null:
			_check(is_equal_approx(pile.TOTAL_TIME, 0.65),
				"抽卡动画总时长 = 原版 0.65s（0.40 翻牌 + 0.25 入手，实际 %.2f）" % pile.TOTAL_TIME)
		_stage = 4
		_t = 0.0
		return false
	if _stage == 4 and _t > 1.2:
		var pile = _main.player_pile()
		_check(pile != null and not pile.is_animating(), "抽牌动画播完自动结束")
		_check(pile != null and pile.count == _deck_before - 1, "动画结束后厚度仍是真实剩余数（%d）" % (0 if pile == null else pile.count))
		_main.queue_free()
		_stage = 5
		return false
	if _stage == 5 and _t > 0.2:
		_finish()
		return true
	return _frames > 3000


# ------------------------------ ④ 飞行时间轴 ------------------------------

## 离线推进整段动画（0.40s 翻牌 + 0.25s 入手），途中检查「朝落点飞」与两段衔接。
func _advance_flight(step: int) -> void:
	if _loose == null:
		return
	# 翻牌段：推进到 0.45s（0.40s 之后进入入手段）
	while _loose.is_animating() and _loose._anim_t < 0.45:
		_loose._process(0.02)
	_mid_pos = _loose.flying_center()
	_d_mid = _mid_pos.distance_to(_flight_reveal_target)
	_check(_d_mid < _d_start, "飞牌朝翻牌落点移动（%.0fpx -> %.0fpx）" % [_d_start, _d_mid])
	_check(_loose.reveal_progress() >= 1.0, "翻牌段 0.40s 结束（reveal=%.2f）" % _loose.reveal_progress())
	_check(_loose.hand_progress() > 0.0, "接着进入 0.25s 入手段（hand=%.2f）" % _loose.hand_progress())
	# 入手段：跑完（结束时会复位动画状态，所以落点要在结束前取）
	var landing := Vector2.ZERO
	while _loose.is_animating():
		landing = _loose.flying_center()
		_loose._process(0.02)
	_check(not _loose.is_animating(), "两个阶段串行、总时长 0.65s 后结束")
	_check(landing.distance_to(_orig_draw_target) < 1.0,
		"飞牌最终落在手牌终点（偏差 %.1fpx）" % landing.distance_to(_orig_draw_target))
	_stage = 3
	_t = 0.0


func _setup_loose_pile() -> void:
	_loose = load(PILE_SCRIPT).new()
	root.add_child(_loose)
	_loose.set_count(0)
	_check(_loose.layers() == 0 and _loose.thickness() == 0.0, "0 张牌时牌堆不画（厚度 0）")
	_loose.set_count(5)
	var t5: float = _loose.thickness()
	_loose.set_count(50)
	var t50: float = _loose.thickness()
	_loose.set_count(1000)
	var tmax: float = _loose.thickness()
	_check(t5 > 0.0 and t50 > t5, "张数越多牌堆越厚（5 张 %.1fpx < 50 张 %.1fpx）" % [t5, t50])
	_check(tmax == float(_loose.get_script().get_script_constant_map()["MAX_LAYERS"])
			* float(_loose.get_script().get_script_constant_map()["LAYER_STEP"]),
		"厚度有上限封顶（1000 张 → %.0fpx）" % tmax)
	_loose.set_count(23)
	_check(_loose.count_text() == "牌库 23", "计数文案显示张数（%s）" % _loose.count_text())


func _test_piles() -> void:
	var me_pile = _main.player_pile()
	var foe_pile = _main.enemy_pile()
	_check(me_pile != null and foe_pile != null, "我方与敌方各有一块牌堆")
	if me_pile == null or foe_pile == null:
		return
	_check(me_pile.mouse_filter == Control.MOUSE_FILTER_IGNORE, "牌堆不吃鼠标事件（不影响出牌/拖拽）")
	var me_deck: int = _gm.get_player(0).deck.size()
	var foe_deck: int = _gm.get_player(1).deck.size()
	_check(me_pile.count == me_deck, "我方牌堆张数 = 牌库剩余（%d / %d）" % [me_pile.count, me_deck])
	_check(foe_pile.count == foe_deck, "敌方牌堆张数 = 牌库剩余（%d / %d）" % [foe_pile.count, foe_deck])
	_check(me_pile.count_text() == "牌库 %d" % me_deck, "牌堆文案与张数一致（%s）" % me_pile.count_text())
	# 原版抽牌落点：num = aspect*0.9；屏幕中心 + (0.25n, -0.23n)
	var vp: Vector2 = _main.get_viewport_rect().size
	var num: float = (vp.x / vp.y) * 0.9
	var want: Vector2 = vp * 0.5 + Vector2(0.25 * num, -0.23 * num)
	_check(_main.reveal_point().distance_to(want) < 0.5,
		"翻牌落点照原版归一化公式（%.0f,%.0f）" % [_main.reveal_point().x, _main.reveal_point().y])
	me_pile.set_count(0)
	_check(me_pile.thickness() == 0.0, "牌库抽空时牌堆不画")
	me_pile.set_count(me_deck)
	var hand_rect: Rect2 = _main.hand_area.get_global_rect()
	var foe_rect: Rect2 = _main.enemy_hand_row.get_global_rect()
	_check(me_pile.global_position.x > hand_rect.get_center().x,
		"我方牌堆在手牌区右侧（%.0f > %.0f）" % [me_pile.global_position.x, hand_rect.get_center().x])
	_check(foe_pile.global_position.x < foe_rect.get_center().x,
		"敌方牌堆镜像在手牌行左侧（%.0f < %.0f）" % [foe_pile.global_position.x, foe_rect.get_center().x])


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
	print("=== 抽牌堆测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
