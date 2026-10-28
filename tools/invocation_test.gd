extends SceneTree
## 瞬念召唤（影之诗 Invocation 风格）测试。
##
## 覆盖内容：
##   1. 注册表：量 × 比较符（SV 的 SkillCompareFuncCreator 六件套）+ 快照能被算出来；
##   2. 基本应召：牌库里满足条件的一张卡在自己的回合开始时自动上场，且**离开牌库**；
##   3. **它不是战吼**：应召上场不结算入场效果（对比「从手牌打出」会结算）；
##   4. **同名卡一回合只应召一次**（牌库里放 3 张同 id + 同一回合多个检查点 → 只出来 1 张）；
##   5. **触发时机**：「我方回合开始 / 结束时」各只在自己回合对应的那个检查点结算；
##   6. **只在自己的回合触发**：对手在动的时候（它的回合开始 / 中间 / 结束、它打出牌）
##      我方牌库里的卡一次都不会结算；旧的「对手回合」时机被迁到对应的「我方回合」；
##   7. 打出牌后 / 攻击后这两个「任意时机」检查点（「已打出牌数 ≥ N」）；
##   8. 没有空置格 → **消失**（从游戏中移除，不进战场 / 手牌 / 墓地）；条件没达成 → 不动牌库；
##   8a. **瞬念召唤效果**（与战吼 / 亡语独立，可留空）与**基础机制（去向）**：
##       留在场上 / 返回手牌 / 进入墓地 / 由玩家选择；顺序 = 先效果、后基础机制；
##   8b. **以卡面原始数值登场**：在牌库里被改过的副本（费用减半 / 身材加减 / 赋予关键字）
##       应召上场后回到卡表里那张原始卡的数值；
##   9. 数据往返：to_dict / from_dict 保住 invocation；未知的量被 CardDB 报错而不是静默失效；
##      **旧格式**（"hand_at_least" 这种把比较符焊在 ID 里的）读取时自动转成「量 + 比较符」。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/invocation_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _db
var _gm
var _hooks := false
var _fail_lines: Array[String] = []
var _logs: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		_run()
		_finish()
		return true
	return _frames > 400


func _run() -> void:
	if not _hooks:
		_gm.log_message.connect(func(t: String) -> void: _logs.append(t))
		_hooks = true
	if _db.cards.is_empty():
		_db.reset_to_default()
	_check(_db.cards.size() > 0, "卡表可用（%d 张）" % _db.cards.size())
	_check(_db.config_errors().is_empty(), "官方卡表没有瞬念召唤配置错误（%s）" % (
		"；".join(_db.config_errors()) if not _db.config_errors().is_empty() else "无"))

	_test_registry()
	_test_basic_invoke()
	_test_not_battlecry()
	_test_once_per_turn_same_id()
	_test_timing()
	_test_enemy_turn()
	_test_checkpoint_after_play()
	_test_checkpoint_after_attack()
	_test_board_full_and_unmet()
	_test_destination()
	_test_invoke_effect()
	_test_deck_buffs_cleared()
	_test_data_roundtrip()


# ------------------------------ 1. 注册表：量 × 比较符 ------------------------------

func _test_registry() -> void:
	var metrics := InvokeConditions.metrics()
	_check(metrics.size() >= 10, "可读的量有 %d 个" % metrics.size())
	var no_label: Array[String] = []
	for m in metrics:
		var empty_label: bool = InvokeConditions.metric_label(m).strip_edges() == ""
		if empty_label or InvokeConditions.default_op(m) == "" or InvokeConditions.text(m, ">=", 1) == "":
			no_label.append(m)
	_check(no_label.is_empty(), "每个量都有名字 / 默认比较符 / 卡面文本（缺：%s）" % (
		"、".join(no_label) if not no_label.is_empty() else "无"))
	_check(InvokeConditions.OPS.size() == 6, "六种比较符（%s）" % " ".join(InvokeConditions.OPS))
	_check(not InvokeConditions.has_metric("iv_no_such_metric"), "未登记的量 has_metric() = false")
	_check(not InvokeConditions.has_op("=="), "等号写成 %s 才算数（没有 '==' 这一种）" % "=")
	_check(InvokeConditions.text("iv_no_such_metric", ">=", 1) == "", "未登记的量的文本为空")
	_check(InvokeConditions.TIME_NAMES.size() == 3, "三种触发时机（%s）" % (
		"、".join(InvokeConditions.TIME_NAMES)))
	_check(InvokeConditions.default_op("self_hp") == "<=", "生命的默认比较符是 ≤（%s）" % (
		InvokeConditions.default_op("self_hp")))
	_check(InvokeConditions.default_op("turn") == ">=", "回合数的默认比较符是 ≥（%s）" % (
		InvokeConditions.default_op("turn")))

	# 六种比较符逐个走过一遍（SV 的 SkillCompareFuncCreator.Create 同款）
	var ops_checks := {
		"<=": [3, 3, true], ">=": [3, 3, true], "=": [3, 3, true],
		"!=": [3, 4, true], "<": [3, 4, true], ">": [4, 3, true],
	}
	for op in ops_checks:
		var row: Array = ops_checks[op]
		var got: bool = InvokeConditions.met("turn", op, row[1], {"turn": row[0]})
		_check(got == row[2], "比较符 %s：%d %s %d = %s" % [op, row[0], op, row[1], row[2]])
	_check(not InvokeConditions.met("turn", "<=", 2, {"turn": 3}), "3 ≤ 2 不成立")
	_check(not InvokeConditions.met("turn", "?", 3, {"turn": 3}), "没登记的比较符 → 不成立")
	_check(not InvokeConditions.met("iv_no_such_metric", ">=", 3, {"turn": 3}), "没登记的量 → 不成立")

	# 快照：一次算好所有要读的量（对应 SV 的 SkillConditionCheckerOption）
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.deck.clear()
	me.hand.clear()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hero_hp = 7
	me.graveyard.append(_minion("iv_z", "墓地里的", 1))
	var ctx := InvokeConditions.snapshot(_gm, ME)
	_check(ctx.has("turn") and ctx.has("self_hp") and ctx.has("enemy_hp") and ctx.has("graveyard"),
		"快照把要读的量都算好了（%d 项）" % ctx.size())
	_check(int(ctx.get("turn", -1)) == _gm.turn_count, "快照里的回合数 = 当前回合（%d）" % int(
		ctx.get("turn", -1)))
	_check(int(ctx.get("enemy_hp", -1)) == 7, "快照里的敌方生命 = 7（%d）" % int(
		ctx.get("enemy_hp", -1)))
	_check(int(ctx.get("graveyard", -1)) == 1, "快照里的我方墓地 = 1（%d）" % int(
		ctx.get("graveyard", -1)))
	_check(InvokeConditions.snapshot(null, ME).is_empty(), "没有战局时快照是空的")


# ------------------------------ 2. 基本应召 ------------------------------

func _test_basic_invoke() -> void:
	var me := _prepare_game()
	me.deck.append(_invoke_minion("iv_basic", "应召随从", 3, "turn", 3,
		InvokeConditions.TIME_SELF_TURN_START))
	var foe: PlayerState = _gm.get_player(FOE)
	foe.deck.append(_invoke_minion("iv_never", "条件太高的随从", 3, "turn", 50,
		InvokeConditions.TIME_SELF_TURN_START))
	# 现在是第 1 回合：条件没达成 → 不会应召
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(me.board, "应召随从") == 0, "条件没达成时留在牌库里（场上 %d）" % (
		_count_name(me.board, "应召随从")))
	_check(_count_name(me.deck, "应召随从") == 1, "它还留在牌库里（%d）" % (
		_count_name(me.deck, "应召随从")))
	# 快进到第 3 回合
	_gm.turn_count = 3
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(me.board, "应召随从") == 1, "条件达成后自动上场（场上 %d）" % (
		_count_name(me.board, "应召随从")))
	_check(_count_name(me.deck, "应召随从") == 0, "它离开了牌库（%d）" % (
		_count_name(me.deck, "应召随从")))
	_check(_has_log("瞬念召唤：「应召随从」"), "应召有日志")
	_check(_count_name(foe.board, "条件太高的随从") == 0 and _count_name(foe.deck, "条件太高的随从") == 1,
		"条件太高的那张（各方各自的牌库）不受影响")
	me.board.clear()
	me.reset_slots()

	# 关掉瞬念召唤 → 条件达成也不应召
	me.deck.clear()
	var off := _invoke_minion("iv_off", "没启用瞬念召唤", 2, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_START)
	off.invocation = {"enabled": false, "metric": "turn", "op": ">=", "value": 1, "timing": 1}
	me.deck.append(off)
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(me.board, "没启用瞬念召唤") == 0, "没启用瞬念召唤的卡不会自动上场")

	# 同一个量换个比较符就是另一张卡：「手牌 ≤ 2」vs「手牌 ≥ 5」
	var me2 := _prepare_game()
	me2.hand.append(_minion("iv_h1", "手牌甲", 1))
	me2.hand.append(_minion("iv_h2", "手牌乙", 1))
	me2.deck.append(_invoke_minion("iv_le", "手牌少时来", 2, "hand", 2,
		InvokeConditions.TIME_ANY, "<="))
	me2.deck.append(_invoke_minion("iv_ge", "手牌多时来", 2, "hand", 5,
		InvokeConditions.TIME_ANY, ">="))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me2.board, "手牌少时来") == 1, "手牌 2 ≤ 2：满足的那张上场了")
	_check(_count_name(me2.board, "手牌多时来") == 0, "手牌 2 ≥ 5：不满足的那张还在牌库里")
	_check(_count_name(me2.deck, "手牌多时来") == 1, "它还等着（牌库 %d）" % (
		_count_name(me2.deck, "手牌多时来")))


# ------------------------------ 3. 它不是战吼 ------------------------------

func _test_not_battlecry() -> void:
	var me := _prepare_game()
	# 这张卡有战吼（抽 1 张），配了瞬念召唤
	var card := _invoke_minion("iv_bc", "带战吼的应召随从", 3, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_START)
	card.effects = [{"id": "draw", "value": 1, "target": int(CardData.Targeting.NONE), "token": ""}]
	card.sync_legacy_from_chains()
	me.deck.append(card)
	me.deck.append(_minion("iv_pile", "牌库底下的", 1))   # 牌库有牌，抽牌效果才看得出来
	var hand_before: int = me.hand.size()
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(me.board, "带战吼的应召随从") == 1, "它应召上场了")
	_check(me.hand.size() == hand_before, "应召**不结算**入场效果（手牌 %d → %d）" % [
		hand_before, me.hand.size()])
	# 对照：同一张卡从手牌打出去是要结算战吼的
	var me2 := _prepare_game()
	me2.deck.append(_minion("iv_pile2", "牌库里的", 1))
	var hand_card := _invoke_minion("iv_bc", "带战吼的应召随从", 1, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_START)
	hand_card.effects = [{"id": "draw", "value": 1, "target": int(CardData.Targeting.NONE),
		"token": ""}]
	hand_card.sync_legacy_from_chains()
	me2.hand.append(hand_card)
	var before2: int = me2.hand.size()
	var ok: bool = _gm.play_card(ME, me2.hand.size() - 1)
	_check(ok, "同一张卡从手牌可以打出")
	_check(_count_name(me2.board, "带战吼的应召随从") == 1, "从手牌打出也上了场")
	_check(me2.hand.size() == before2, "从手牌打出**会**结算战吼（打出 -1 抽 1：%d → %d）" % [
		before2, me2.hand.size()])


# ------------------------------ 4. 同名卡一回合只应召一次 ------------------------------

func _test_once_per_turn_same_id() -> void:
	var me := _prepare_game()
	for i in 3:
		me.deck.append(_invoke_minion("iv_once", "同名应召随从", 3, "turn", 1,
			InvokeConditions.TIME_ANY))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "同名应召随从") == 1,
		"同一回合第一次检查只应召一张同名卡（场上 %d）" % _count_name(me.board, "同名应召随从"))
	_check(_count_name(me.deck, "同名应召随从") == 2, "另外两张还在牌库里（%d）" % (
		_count_name(me.deck, "同名应召随从")))
	# 同一回合再多来几个检查点：仍然不再应召
	_gm._invoke_checkpoint(ME)
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "同名应召随从") == 1,
		"同一回合再检查几次也不会多应召（场上 %d）" % _count_name(me.board, "同名应召随从"))
	# 换一个回合 → 可以再应召一张
	_gm.turn_count = _gm.turn_count + 1
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "同名应召随从") == 2,
		"换回合后可以再应召一张同名卡（场上 %d）" % _count_name(me.board, "同名应召随从"))
	_check(_count_name(me.deck, "同名应召随从") == 1, "牌库里还剩一张（%d）" % (
		_count_name(me.deck, "同名应召随从")))

	# key 是**卡牌 id**：同一张 id 的不同副本算同名；改名也拦得住
	var me2 := _prepare_game()
	for i in 2:
		var c := _invoke_minion("iv_id", "原名", 3, "turn", 1, InvokeConditions.TIME_ANY)
		c.card_name = "改名%d" % i       # 名字不一样，id 一样 → 仍然受限
		me2.deck.append(c)
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me2.board, "改名0") + _count_name(me2.board, "改名1") == 1,
		"同名判定按卡 id：改了名字也只出来一张（场上 %d）" % (
			_count_name(me2.board, "改名0") + _count_name(me2.board, "改名1")))

	# 不同 id 的卡互不干扰：同一回合里各自应召一张
	var me3 := _prepare_game()
	me3.deck.append(_invoke_minion("iv_a", "甲", 3, "turn", 1, InvokeConditions.TIME_ANY))
	me3.deck.append(_invoke_minion("iv_b", "乙", 3, "turn", 1, InvokeConditions.TIME_ANY))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me3.board, "甲") == 1 and _count_name(me3.board, "乙") == 1,
		"不同 id 的卡同一个回合各自应召一张（甲 %d / 乙 %d）" % [
			_count_name(me3.board, "甲"), _count_name(me3.board, "乙")])

	# 我方与敌方互不占用名额（各自的回合各自结算）
	_prepare_game()
	var me4: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	me4.deck.append(_invoke_minion("iv_mine", "我方的应召随从", 3, "turn", 1,
		InvokeConditions.TIME_ANY))
	foe.deck.append(_invoke_minion("iv_foe", "敌方的应召随从", 3, "turn", 1,
		InvokeConditions.TIME_ANY))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me4.board, "我方的应召随从") == 1, "我方回合结算我方那张（场上 %d）" % (
		_count_name(me4.board, "我方的应召随从")))
	_check(_count_name(foe.board, "敌方的应召随从") == 0, "同一个检查点不动对手的牌库")
	_gm._invoke_checkpoint(FOE)
	_check(_count_name(foe.board, "敌方的应召随从") == 1, "轮到对手自己回合时才结算它（场上 %d）" % (
		_count_name(foe.board, "敌方的应召随从")))


# ------------------------------ 5. 触发时机 ------------------------------

func _test_timing() -> void:
	var me := _prepare_game()
	me.deck.append(_invoke_minion("iv_ts", "回合开始应召", 2, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_START))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "回合开始应召") == 0,
		"时机不对的检查点（任意时机）不会结算它（场上 %d）" % _count_name(me.board, "回合开始应召"))
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_END])
	_check(_count_name(me.board, "回合开始应召") == 0,
		"「我方回合结束时」的检查点也不结算它（场上 %d）" % _count_name(me.board, "回合开始应召"))
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(me.board, "回合开始应召") == 1,
		"匹配时机（我方回合开始）时才结算（场上 %d）" % _count_name(me.board, "回合开始应召"))

	# 「我方回合结束时」：反过来
	var me2 := _prepare_game()
	me2.deck.append(_invoke_minion("iv_te", "回合结束应召", 2, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_END))
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(me2.board, "回合结束应召") == 0,
		"回合开始时不结算「回合结束时」的卡（场上 %d）" % _count_name(me2.board, "回合结束应召"))
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_END])
	_check(_count_name(me2.board, "回合结束应召") == 1,
		"自己的回合结束时应召（场上 %d）" % _count_name(me2.board, "回合结束应召"))


# ------------------------------ 6. 只在自己的回合结算 ------------------------------

func _test_enemy_turn() -> void:
	# ① 我方回合开始的检查点：只结算我自己，不会顺手把对手的卡拉出来
	_prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.deck.append(_invoke_minion("iv_any_foe", "任意时机的对面卡", 2, "turn", 1,
		InvokeConditions.TIME_ANY))
	foe.deck.append(_invoke_minion("iv_start_foe", "回合开始的对面卡", 2, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_START))
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_START])
	_check(foe.board.is_empty(),
		"我方回合开始：对手的卡一张都不会应召（场上 %d）" % foe.board.size())
	_check(_count_name(foe.deck, "任意时机的对面卡") == 1 and _count_name(foe.deck,
		"回合开始的对面卡") == 1, "它们都还在对手的牌库里等着")
	# 轮到对手自己回合开始时它们才应召
	_gm._invoke_checkpoint(FOE, [InvokeConditions.TIME_SELF_TURN_START])
	_check(_count_name(foe.board, "任意时机的对面卡") == 1 and _count_name(foe.board,
		"回合开始的对面卡") == 1, "轮到对手自己回合开始时它就来（任意 %d / 回合开始 %d）" % [
			_count_name(foe.board, "任意时机的对面卡"),
			_count_name(foe.board, "回合开始的对面卡")])

	# ② 我方回合结束的检查点：同样只结算我自己
	_prepare_game()
	var foe2: PlayerState = _gm.get_player(FOE)
	foe2.deck.append(_invoke_minion("iv_end_foe", "回合结束的对面卡", 2, "turn", 1,
		InvokeConditions.TIME_SELF_TURN_END))
	_gm._invoke_checkpoint(ME, [InvokeConditions.TIME_SELF_TURN_END])
	_check(_count_name(foe2.board, "回合结束的对面卡") == 0,
		"我方回合结束：对手的「回合结束时」卡不会应召（场上 %d）" % _count_name(foe2.board,
			"回合结束的对面卡"))
	_gm._invoke_checkpoint(FOE, [InvokeConditions.TIME_SELF_TURN_END])
	_check(_count_name(foe2.board, "回合结束的对面卡") == 1,
		"轮到对手自己回合结束时它才来（场上 %d）" % _count_name(foe2.board, "回合结束的对面卡"))

	# ③ 打出牌之后：只替打出牌的这一方判定 —— 反过来自己打出的牌也只能带动自己牌库里的卡
	var me3 := _prepare_game()
	var foe3: PlayerState = _gm.get_player(FOE)
	foe3.hand.append(_minion("iv_foe_play", "对手要打出的牌", 1))
	foe3.deck.append(_invoke_minion("iv_any_foe2", "对面任意时机卡", 2, "cards_played", 1,
		InvokeConditions.TIME_ANY))
	me3.deck.append(_invoke_minion("iv_any_me", "我方任意时机卡", 2, "cards_played", 1,
		InvokeConditions.TIME_ANY))
	var foe_hand_idx: int = foe3.hand.size() - 1
	_gm.current_player = FOE        # 出牌只能发生在自己的回合，can_play 会拦别的回合
	var played: bool = _gm.play_card(FOE, foe_hand_idx)
	_check(played, "对手在自己回合打出一张牌")
	_check(foe3.cards_played_turn == 1, "对手本回合已打出 1 张（%d）" % foe3.cards_played_turn)
	_check(_count_name(foe3.board, "对面任意时机卡") == 1,
		"它带动的是**对手自己**牌库里那张（场上 %d）" % _count_name(foe3.board, "对面任意时机卡"))
	_check(_count_name(me3.board, "我方任意时机卡") == 0 and _count_name(me3.deck,
		"我方任意时机卡") == 1, "「任意时机」的卡不会被对手的出牌带动（我方场上 %d / 牌库 %d）" % [
			_count_name(me3.board, "我方任意时机卡"), _count_name(me3.deck, "我方任意时机卡")])

	# ④ 走真实的回合切换：对手的整个回合里，我方的卡一次都不结算
	_prepare_game()
	var me4: PlayerState = _gm.get_player(ME)
	var foe4: PlayerState = _gm.get_player(FOE)
	me4.deck.append(_invoke_minion("iv_me_turn", "我方第 2 回合卡", 2, "turn", 2,
		InvokeConditions.TIME_ANY))
	_gm.current_player = ME
	_gm.turn_count = 2
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me4.board, "我方第 2 回合卡") == 1, "自己回合满足条件时照常应召")
	me4.deck.append(_invoke_minion("iv_me_turn2", "我方第 2 回合卡乙", 2, "turn", 2,
		InvokeConditions.TIME_ANY))
	# 换成对手行动：它的回合开始 / 回合结束都碰不到我方的卡
	_gm._invoke_checkpoint(FOE, [InvokeConditions.TIME_SELF_TURN_START])
	_gm._invoke_checkpoint(FOE)
	_gm._invoke_checkpoint(FOE, [InvokeConditions.TIME_SELF_TURN_END])
	_check(_count_name(me4.deck, "我方第 2 回合卡乙") == 1,
		"对手回合里（开始 / 中间 / 结束）我方的卡一张都不应召（牌库 %d）" % _count_name(me4.deck,
			"我方第 2 回合卡乙"))
	_check(_count_name(me4.board, "我方第 2 回合卡乙") == 0, "场上也没有多出来（场上 %d）" % (
		_count_name(me4.board, "我方第 2 回合卡乙")))

	# ⑤ 旧数据里的「对手回合」时机（3 / 4）读进来被迁到对应的「我方回合」，
	#    而不是留在原地变成一个永不触发的配置
	var legacy_start := CardData.from_dict({"id": "iv_lt3", "card_name": "旧对手回合开始卡",
		"cost": 1, "card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1,
		"invocation": {"enabled": true, "metric": "turn", "op": ">=", "value": 1, "timing": 3}})
	var legacy_end := CardData.from_dict({"id": "iv_lt4", "card_name": "旧对手回合结束卡",
		"cost": 1, "card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1,
		"invocation": {"enabled": true, "metric": "turn", "op": ">=", "value": 1, "timing": 4}})
	_check(legacy_start.invoke_timing() == InvokeConditions.TIME_SELF_TURN_START,
		"旧「对手回合开始」迁到「我方回合开始」（%s）" % InvokeConditions.timing_name(
			legacy_start.invoke_timing()))
	_check(legacy_end.invoke_timing() == InvokeConditions.TIME_SELF_TURN_END,
		"旧「对手回合结束」迁到「我方回合结束」（%s）" % InvokeConditions.timing_name(
			legacy_end.invoke_timing()))
	_check(InvokeConditions.TIME_NAMES.size() == 3, "现在只有三种时机（%s）" % (
		"、".join(InvokeConditions.TIME_NAMES)))
	_check(not "、".join(InvokeConditions.TIME_NAMES).contains("对手回合"),
		"下拉里已经没有「对手回合」这种时机了")


# ------------------------------ 7. 打出牌后 / 攻击后的检查点 ------------------------------

func _test_checkpoint_after_play() -> void:
	var me := _prepare_game()
	me.hand.clear()
	me.deck.append(_invoke_minion("iv_after2", "打出两张牌后登场", 2, "cards_played", 2,
		InvokeConditions.TIME_ANY))
	me.hand.append(_minion("iv_e1", "垫牌甲", 1))
	me.hand.append(_minion("iv_e2", "垫牌乙", 1))
	var ok: bool = _gm.play_card(ME, 0)
	_check(ok, "打出第一张垫牌")
	_check(_count_name(me.board, "打出两张牌后登场") == 0,
		"只打出 1 张牌时还不应召（场上 %d）" % _count_name(me.board, "打出两张牌后登场"))
	ok = _gm.play_card(ME, 0)
	_check(ok, "打出第二张垫牌")
	_check(me.cards_played_turn == 2, "本回合已打出 2 张（%d）" % me.cards_played_turn)
	_check(_count_name(me.board, "打出两张牌后登场") == 1,
		"「任意时机」= 打出牌后也会结算（场上 %d）" % _count_name(me.board, "打出两张牌后登场"))


func _test_checkpoint_after_attack() -> void:
	var me := _prepare_game()
	var foe: PlayerState = _gm.get_player(FOE)
	me.board.clear()
	me.reset_slots()
	foe.board.clear()
	foe.reset_slots()
	me.hand.clear()
	me.deck.append(_invoke_minion("iv_die", "同伴阵亡后来", 3, "units_died", 1,
		InvokeConditions.TIME_ANY))
	# 攻击者带冲锋：刚上场的随从本来攻不了人，只是这里要的是一次能结算完的攻击
	var atk_card := _minion("iv_atk", "攻击者", 1)
	atk_card.keywords = [CardData.Keyword.CHARGE]
	var attacker: BoardUnit = _gm.summon_unit(ME, atk_card)
	var victim: BoardUnit = _gm.summon_unit(FOE, _minion("iv_vic", "受害者", 1))
	_check(attacker != null and victim != null, "双方各放一个随从")
	victim.health = 1
	_gm.current_player = ME
	var ok: bool = _gm.attack(ME, attacker.unit_id, victim.unit_id, FOE)
	_check(ok, "攻击结算成功")
	_check(me.units_died_turn == 0 and foe.units_died_turn == 1,
		"死亡计数累计给目标那一方（我方 %d / 敌方 %d）" % [me.units_died_turn, foe.units_died_turn])
	_check(_count_name(me.board, "同伴阵亡后来") == 0,
		"我方没死随从 → 不触发（场上 %d）" % _count_name(me.board, "同伴阵亡后来"))
	# 换一个量（累计死亡）：条件达成后应召
	me.deck.clear()
	me.deck.append(_invoke_minion("iv_die_total", "本局累计死亡后来", 3, "total_units_died", 1,
		InvokeConditions.TIME_ANY))
	_check(me.units_died_total == 0, "我方累计死亡还是 0（%d）" % me.units_died_total)
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "本局累计死亡后来") == 0,
		"累计死亡 0 时不触发（场上 %d）" % _count_name(me.board, "本局累计死亡后来"))
	me.units_died_total = 1
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "本局累计死亡后来") == 1,
		"累计条件达成后应召（场上 %d）" % _count_name(me.board, "本局累计死亡后来"))


# ------------------------------ 8. 战场满 / 条件没达成 ------------------------------

func _test_board_full_and_unmet() -> void:
	var me := _prepare_game()
	me.board.clear()
	me.reset_slots()
	var limit: int = _gm.BOARD_LIMIT
	for i in limit:
		var u: BoardUnit = _gm.summon_unit(ME, _minion("iv_full_%d" % i, "占位的", 1))
		_check(u != null, "占位随从 %d" % (i + 1))
	_check(_gm.board_size_used(ME) == limit, "战场已满（%d）" % _gm.board_size_used(ME))
	me.deck.append(_invoke_minion("iv_nowhere", "没地方站的随从", 2, "turn", 1,
		InvokeConditions.TIME_ANY))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.deck, "没地方站的随从") == 0,
		"没有空置格时它「消失」：牌库里也没有了（%d）" % _count_name(me.deck, "没地方站的随从"))
	_check(_count_name(me.board, "没地方站的随从") == 0, "消失的卡没有上场")
	_check(_count_name(me.graveyard, "没地方站的随从") == 0, "消失不进墓地（影之诗式消失）")
	_check(_has_log("消失"), "消失有日志")

	# 从来没有配过瞬念召唤的卡：任何检查点都不动它
	var plain := _minion("iv_plain", "普通随从", 2)
	me.deck.append(plain)
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.deck, "普通随从") == 1, "没配瞬念召唤的卡不会被拉出来")
	_check(not plain.has_invocation(), "没配瞬念召唤：has_invocation() = false")


# ------------------------------ 9. 数据往返 ------------------------------

func _test_data_roundtrip() -> void:
	var c := _invoke_minion("iv_rt", "往返测试", 4, "self_hp", 12,
		InvokeConditions.TIME_SELF_TURN_END, "<=")
	var back := CardData.from_dict(c.to_dict())
	_check(back.has_invocation(), "to_dict / from_dict 保住瞬念召唤")
	_check(back.invoke_metric() == "self_hp", "条件里的量往返一致（%s）" % back.invoke_metric())
	_check(back.invoke_op() == "<=", "比较符往返一致（%s）" % back.invoke_op())
	_check(back.invoke_value() == 12, "阈值往返一致（%d）" % back.invoke_value())
	_check(back.invoke_timing() == InvokeConditions.TIME_SELF_TURN_END, "触发时机往返一致（%d）" % (
		back.invoke_timing()))
	_check(back.invoke_text().contains("瞬念召唤"), "卡面文本带瞬念召唤一行（%s）" % back.invoke_text())
	_check(back.invoke_text().contains("我方英雄生命 ≤ 12"), "卡面文本写清了量和比法（%s）" % (
		back.invoke_text()))
	_check(InvokeConditions.op_symbol("<=") == "≤" and InvokeConditions.op_symbol(">=") == "≥",
		"卡面上用 ≤ ≥ 而不是 <= >=")
	_check(back.summary_lines().has(back.invoke_text()), "summary_lines 里能看到它")

	# 老卡表（没有 invocation 键）→ 空字典，不会配上任何东西
	var old := CardData.from_dict({"id": "iv_old", "card_name": "老卡", "cost": 1,
		"card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1})
	_check(old.invocation.is_empty(), "老卡表缺省 = 没有瞬念召唤")
	_check(not old.has_invocation(), "老卡不会被判定")

	# **旧格式**（把比较符焊在条件 ID 里）读取时自动转成「量 + 比较符」
	var legacy := CardData.from_dict({"id": "iv_legacy", "card_name": "旧格式卡", "cost": 1,
		"card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1,
		"invocation": {"enabled": true, "condition": "hand_at_least", "value": 3, "timing": 2}})
	_check(legacy.has_invocation(), "旧格式的条件被自动迁移过来")
	_check(legacy.invoke_metric() == "hand", "旧格式 hand_at_least → 量 hand（%s）" % (
		legacy.invoke_metric()))
	_check(legacy.invoke_op() == ">=", "旧格式 _at_least → 比较符 >=（%s）" % legacy.invoke_op())
	_check(legacy.invoke_value() == 3, "旧格式的阈值保留（%d）" % legacy.invoke_value())
	_check(legacy.invoke_timing() == InvokeConditions.TIME_SELF_TURN_END, "旧格式的时机保留（%d）" % (
		legacy.invoke_timing()))
	var legacy2 := CardData.from_dict({"id": "iv_legacy2", "card_name": "旧格式卡2", "cost": 1,
		"card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1,
		"invocation": {"enabled": true, "condition": "self_hp_at_most", "value": 10, "timing": 0}})
	_check(legacy2.invoke_metric() == "self_hp" and legacy2.invoke_op() == "<=",
		"旧格式 _at_most → 比较符 <=（%s %s）" % [legacy2.invoke_metric(), legacy2.invoke_op()])

	# 未知的量：引擎侧当没配（不判定），但 CardDB 自检会报出来
	var bad := CardData.from_dict({"id": "iv_bad", "card_name": "配错条件的卡", "cost": 1,
		"card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1,
		"invocation": {"enabled": true, "metric": "iv_no_such_metric", "op": ">=",
			"value": 1, "timing": 0}})
	_check(not bad.has_invocation(), "未知的量：引擎当没配（不会判定）")
	_check(bad.invocation.get("metric") == "iv_no_such_metric", "未知的量被保留，没被静默吞掉")
	_db.cards.append(bad)
	var errs: Array[String] = _db.config_errors()
	var hit := false
	for e in errs:
		if e.contains("iv_bad"):
			hit = true
	_check(hit, "CardDB 自检报出这张卡的坏配置（%d 条里）" % errs.size())
	_db.cards.erase(bad)

	# 配了瞬念召唤的**法术**：可以配（牌库 / 墓地直接发动或进入手牌），只是不会上场
	var spell := CardData.from_dict({"id": "iv_spell", "card_name": "会瞬念召唤的法术", "cost": 1,
		"card_type": int(CardData.CardType.SPELL),
		"invocation": {"enabled": true, "metric": "turn", "op": ">=", "value": 1, "timing": 0}})
	_check(not spell.is_board_card(), "它是法术（不占场地）")
	_check(spell.has_invocation(), "数据层面它确实配了瞬念召唤")
	_check(spell.summary_lines().has(spell.invoke_text()), "卡面会写瞬念召唤这一行（法术也能配）")
	_db.cards.append(spell)
	var errs2: Array[String] = _db.config_errors()
	var hit2 := false
	for e in errs2:
		if e.contains("iv_spell"):
			hit2 = true
	_check(not hit2, "CardDB 自检不再报错（法术可以配瞬念召唤）")
	_db.cards.erase(spell)

	# 引擎侧：法术不会上场，会按去向「直接发动 / 进入手牌」处理（默认 KEEP = 直接发动）
	var me := _prepare_game()
	me.deck.append(spell)
	_gm._invoke_checkpoint(ME)
	var left_in_deck := _count_name(me.deck, "会瞬念召唤的法术")
	var in_grave := _count_name(me.graveyard, "会瞬念召唤的法术")
	_check(left_in_deck == 0, "牌库里的法术会响应瞬念召唤（牌库剩 %d）" % left_in_deck)
	_check(in_grave == 1, "默认去向 = 直接发动 → 使用后进墓地（墓地 %d）" % in_grave)
	_check(_gm.board_size_used(ME) == 0, "法术不会上场（%d）" % _gm.board_size_used(ME))


# ------------------------------ 8a. 基础机制（去向）与瞬念召唤效果 ------------------------------

## 基础机制 = 应召（并结算完效果）之后这张卡留在哪：KEEP / HAND / GRAVEYARD / CHOOSE（必选，不能为空）
func _test_destination() -> void:
	# KEEP：留在场上（默认，也是老数据的行为）
	var me := _prepare_game()
	me.deck.append(_invoke_minion("iv_d_keep", "留场卡", 2, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.KEEP))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "留场卡") == 1, "KEEP：应召后留在场上")
	_check(_count_name(me.hand, "留场卡") == 0 and _count_name(me.graveyard, "留场卡") == 0,
		"KEEP：既没回手也没进墓地")

	# HAND：返回手牌
	me = _prepare_game()
	me.deck.append(_invoke_minion("iv_d_hand", "回手卡", 2, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.HAND))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "回手卡") == 0, "HAND：不在场上")
	_check(_count_name(me.hand, "回手卡") == 1, "HAND：返回手牌（手牌 %d）" % _count_name(me.hand, "回手卡"))

	# GRAVEYARD：进入墓地
	me = _prepare_game()
	me.deck.append(_invoke_minion("iv_d_grave", "入墓卡", 2, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.GRAVEYARD))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "入墓卡") == 0, "GRAVEYARD：不在场上")
	_check(_count_name(me.graveyard, "入墓卡") == 1, "GRAVEYARD：进入墓地")

	# CHOOSE：上场后由玩家选；不选 = 留在场上
	me = _prepare_game()
	me.deck.append(_invoke_minion("iv_d_choose", "待选卡", 2, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.CHOOSE))
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "待选卡") == 1, "CHOOSE：先留在场上等玩家选")
	_check(not _gm.pending_invoke_choice.is_empty(), "CHOOSE：挂起了待选")
	_gm.resolve_invoke_choice(CardData.InvokeDest.HAND)
	_check(_count_name(me.board, "待选卡") == 0 and _count_name(me.hand, "待选卡") == 1,
		"CHOOSE：玩家选「返回手牌」后才回手（场上 %d / 手牌 %d）" % [
			_count_name(me.board, "待选卡"), _count_name(me.hand, "待选卡")])
	_check(_gm.pending_invoke_choice.is_empty(), "选完待选清空")

	# CHOOSE 选「进入墓地」
	me = _prepare_game()
	me.deck.append(_invoke_minion("iv_d_choose2", "待选卡乙", 2, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.CHOOSE))
	_gm._invoke_checkpoint(ME)
	_gm.resolve_invoke_choice(CardData.InvokeDest.GRAVEYARD)
	_check(_count_name(me.graveyard, "待选卡乙") == 1, "CHOOSE：选「进入墓地」后进墓地")
	_check(not _gm.resolve_invoke_choice(CardData.InvokeDest.KEEP), "没有待选时 resolve 返回 false")


## 瞬念召唤效果：与战吼 / 亡语独立的一条链（可留空），**先结算效果、再执行基础机制**
func _test_invoke_effect() -> void:
	var me := _prepare_game()
	me.deck.append(_minion("iv_fx_pile", "牌库底下的", 1))     # 牌库有牌才看得出抽牌
	var card := _invoke_minion("iv_fx", "带应召效果的卡", 3, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.KEEP,
		[{"id": "draw", "value": 1, "target": int(CardData.Targeting.NONE), "token": ""}])
	me.deck.append(card)
	var hand_before: int = me.hand.size()
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "带应召效果的卡") == 1, "带应召效果的卡应召上场了")
	_check(me.hand.size() == hand_before + 1, "应召后结算了瞬念召唤效果（手牌 %d → %d）" % [
		hand_before, me.hand.size()])
	_check(card.invoke_has_effects(), "invoke_has_effects() = true")
	_check(card.invoke_effect_text() != "", "效果有一行说明（%s）" % card.invoke_effect_text())

	# 对照：不配应召效果的卡不会因此多抽牌
	me = _prepare_game()
	me.deck.append(_minion("iv_fx_pile2", "牌库底下的", 1))
	me.deck.append(_invoke_minion("iv_nofx", "没有应召效果的卡", 3, "turn", 1, InvokeConditions.TIME_ANY))
	var h2: int = me.hand.size()
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "没有应召效果的卡") == 1, "没有应召效果的卡也照常应召")
	_check(me.hand.size() == h2, "没有应召效果就不抽牌（手牌 %d → %d）" % [h2, me.hand.size()])

	# 顺序：先效果、后基础机制 —— 回手的卡也能先抽牌再回手
	me = _prepare_game()
	me.deck.append(_minion("iv_fx_pile3", "牌库底下的", 1))
	me.deck.append(_invoke_minion("iv_fx_hand", "抽完就回手", 3, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.HAND,
		[{"id": "draw", "value": 1, "target": int(CardData.Targeting.NONE), "token": ""}]))
	var h3: int = me.hand.size()
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.hand, "抽完就回手") == 1, "先结算效果再执行基础机制：它回手了")
	_check(me.hand.size() == h3 + 2, "抽 1 张 + 自己回手 1 张（手牌 %d → %d）" % [h3, me.hand.size()])

	# 数据往返：效果 + 去向都存得住
	var base := _invoke_minion("iv_fx_rt", "往返效果卡", 3, "turn", 1, InvokeConditions.TIME_ANY,
		"", CardData.InvokeDest.HAND,
		[{"id": "draw", "value": 1, "target": int(CardData.Targeting.NONE), "token": ""}])
	var rt := CardData.from_dict(base.to_dict())
	_check(rt.invoke_has_effects(), "往返后瞬念召唤效果还在")
	_check(rt.invoke_dest() == CardData.InvokeDest.HAND, "往返后基础机制还在（%s）" % rt.invoke_dest_name())
	_check(rt.invoke_text().contains("之后"), "卡面文本写出基础机制（%s）" % rt.invoke_text())
	# 越界去向回落 KEEP（老卡表 / 坏数据不会读崩）
	var bad := CardData.from_dict({"id": "iv_bad_dest", "card_name": "坏去向", "cost": 1,
		"card_type": int(CardData.CardType.MINION), "attack": 1, "health": 1,
		"invocation": {"enabled": true, "metric": "turn", "op": ">=", "value": 1,
			"timing": 0, "destination": 99}})
	_check(bad.invoke_dest() == CardData.InvokeDest.KEEP, "越界的去向回落 KEEP（%d）" % bad.invoke_dest())


# ------------------------------ 8b. 登场数值：以卡面原始数值为准 ------------------------------

## 规则 4：应召上场的是**卡表里那张卡**，它在牌库里攒的账（费用减半 / 身材加减 / 关键字）不带过来
func _test_deck_buffs_cleared() -> void:
	# 卡表里登记一张原始卡：费用 5 / 2-3 / 没有关键字
	var base := _invoke_minion("iv_clean", "牌库改造卡", 5, "turn", 1, InvokeConditions.TIME_ANY)
	_db.add_card(base)
	var me := _prepare_game()
	# 牌库里放的是**被改过的副本**：费用被减半、身材被加减、还被赋予了嘲讽
	var dirty: CardData = base.clone()
	dirty.cost = 2
	dirty.attack = 4
	dirty.health = 5
	dirty.keywords.append(CardData.Keyword.TAUNT)
	me.deck.append(dirty)
	_check(dirty.cost == 2 and dirty.attack == 4 and dirty.has_mechanic(CardData.Keyword.TAUNT),
		"牌库里那张副本确实被改过（费用 %d / %d-%d）" % [dirty.cost, dirty.attack, dirty.health])

	_gm._invoke_checkpoint(ME)
	var u := _unit_named(ME, "牌库改造卡")
	_check(u != null, "满足条件时它照常应召上场")
	if u != null:
		_check(u.data.cost == 5, "费用按卡表来，牌库里的减半不算（%d）" % u.data.cost)
		_check(u.attack == 2 and u.health == 3 and u.max_health == 3,
			"身材按卡表来，牌库里的加减不算（%d/%d，上限 %d）" % [
				u.attack, u.health, u.max_health])
		_check(not u.has_mechanic(CardData.Keyword.TAUNT), "在牌库里被赋予的嘲讽没有跟着上场")
		_check(u.keywords.is_empty(), "词条也是卡表那一套（%s）" % "，".join(u.mechanic_names()))
	_check(_count_name(me.deck, "牌库改造卡") == 0, "它确实离开了牌库（剩 %d）" % (
		_count_name(me.deck, "牌库改造卡")))

	# 卡表里查不到原始卡的临时卡：没有对照对象，就原样上场（不会被凭空改数字）
	var stray := _invoke_minion("iv_stray", "没进卡表的临时卡", 4, "turn", 1,
		InvokeConditions.TIME_ANY)
	stray.attack = 9
	var me2 := _prepare_game()
	me2.deck.append(stray)
	_gm._invoke_checkpoint(ME)
	var u2 := _unit_named(ME, "没进卡表的临时卡")
	_check(u2 != null and u2.attack == 9, "卡表里查不到的卡：原样上场（%d）" % (
		-1 if u2 == null else u2.attack))
	_db.remove_card(base.id)


# ------------------------------ 工具 ------------------------------

func _prepare_game() -> PlayerState:
	_gm.new_game()
	# new_game() 的内部流程会走一次「回合开始」的瞬念召唤检查点：如果此刻卡池里已经有本用例
	# 刚加进去的卡（`_db.add_card`），它会被应召并把同名的「本回合已应召」记下来 ——
	# 那会让本用例后面自己发起的检查点被去重掉。这里连同待选一起抹掉，保证是「干净开局」。
	_gm._invoked.clear()
	_gm.pending_invoke_choice = {}
	_gm.log_enabled = true
	_logs.clear()
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	for p in [me, foe]:
		p.max_mana = 10
		p.mana = 10
		p.hand.clear()
		p.board.clear()
		p.reset_slots()
		p.graveyard.clear()
		p.deck.clear()
		p.units_died_turn = 0
		p.units_died_total = 0
	me.turns_taken = 1
	me.city_summon_turn = -1
	foe.turns_taken = 1
	foe.city_summon_turn = -1
	return me


## 现造一张随从（只存在于内存，不写任何卡表文件）
func _minion(id: String, name_: String, cost: int = 2, effects: Array = []) -> CardData:
	return CardData.from_dict({
		"id": id, "card_name": name_, "cost": cost,
		"card_type": int(CardData.CardType.MINION),
		"attack": 2, "health": 3, "keywords": [],
		"effects": effects, "deathrattle_effects": [],
	})


## 现造一张**配了瞬念召唤**的随从：`op` 留空时取这个量的默认比较符；
## `dest` = 基础机制（去向，默认留在场上）；`inv_fx` = 瞬念召唤效果链（默认空）
func _invoke_minion(id: String, name_: String, cost: int, metric: String, value: int,
		timing: int, op: String = "", dest: int = CardData.InvokeDest.KEEP,
		inv_fx: Array = []) -> CardData:
	var c := _minion(id, name_, cost)
	c.invocation = {
		"enabled": true,
		"metric": metric,
		"op": op if op != "" else InvokeConditions.default_op(metric),
		"value": value,
		"timing": timing,
		"effects": inv_fx,
		"destination": dest,
	}
	return c


func _unit_named(pid: int, card_name: String) -> BoardUnit:
	var p: PlayerState = _gm.get_player(pid)
	for u in p.board:
		if u != null and u.data.card_name == card_name:
			return u
	return null


func _count_name(list: Array, card_name: String) -> int:
	var n := 0
	for item in list:
		if item is BoardUnit and (item as BoardUnit).data.card_name == card_name:
			n += 1
		elif item is CardData and (item as CardData).card_name == card_name:
			n += 1
	return n


func _has_log(keyword: String) -> bool:
	for l in _logs:
		if l.contains(keyword):
			return true
	return false


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
	print("=== 瞬念召唤测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
