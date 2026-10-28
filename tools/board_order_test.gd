extends SceneTree
## 场上结算顺序测试：**己方从左到右，敌方镜像**。
##
## 规则落在一处：`GameManager.unit_order(viewer_pid)`
##   * 己方 = 自己视角的左→右（board 下标 0 → n-1）
##   * 敌方 = 镜像（对方视角的左→右 = 本视角的右→左，board 下标 n-1 → 0）
## 本测试验证它贯穿了：死亡结算、效果取随从（己方/敌方/全体）、攻击目标列表；
## 并固定**显示约定**：两排战场都按各自 board 下标从左到右摆放，
## 因此"敌方结算顺序"在屏幕上表现为右→左（这正是"镜像"的含义）。
##
## 运行：godot --headless --path <项目目录> --script res://tools/board_order_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
var _logs: Array[String] = []
var _ui_done := false
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
		_test_unit_order()
		_test_effect_order()
		_test_death_order()
		_test_attack_target_order()
		_test_slot_semantics()
		# 界面相关留到后面几帧：节点要先经过一次布局才有坐标
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_check(_main != null, "主场景可实例化")
		return false
	if _frames == 12 and not _ui_done:
		_ui_done = true
		_test_display_order()
		_main.queue_free()
		return false
	if _frames == 16:
		_finish()
		return true
	return _frames > 400


# ------------------------------ 顺序函数本身 ------------------------------

func _test_unit_order() -> void:
	_prepare()
	# 故意让 unit_id 顺序与位置顺序**相反**，这样"按 id 排序"的实现会被抓出来
	var mine_left: BoardUnit = _spawn(ME, "c001", 500)
	var mine_right: BoardUnit = _spawn(ME, "c002", 100)
	var foe_left: BoardUnit = _spawn(FOE, "c001", 400)     # 对方视角的左
	var foe_right: BoardUnit = _spawn(FOE, "c002", 200)    # 对方视角的右
	var order: Array[BoardUnit] = _gm.unit_order(ME)
	_check(order.size() == 4, "顺序里有 4 个随从（%d）" % order.size())
	_check(order[0] == mine_left and order[1] == mine_right, "己方：自己视角左→右")
	_check(order[2] == foe_right and order[3] == foe_left, "敌方：镜像（对方视角的左→右 = 本视角的右→左）")
	var side: Array[BoardUnit] = _gm.side_order(ME)
	_check(side.size() == 2 and side[0] == mine_left and side[1] == mine_right, "side_order 只看己方，仍是左→右")
	var foe_order: Array[BoardUnit] = _gm.unit_order(FOE)
	_check(foe_order[0] == foe_left and foe_order[1] == foe_right, "换对手视角：他的随从变成左→右")
	_check(foe_order[2] == mine_right and foe_order[3] == mine_left, "换对手视角：我方的随从镜像")


# ------------------------------ 效果取随从的顺序 ------------------------------

func _test_effect_order() -> void:
	_prepare()
	var a1: BoardUnit = _spawn(ME, "c001", 501)
	var a2: BoardUnit = _spawn(ME, "c002", 101)
	var e0: BoardUnit = _spawn(FOE, "c001", 401)
	var e1: BoardUnit = _spawn(FOE, "c002", 201)
	var ctx := EffectContext.create(_gm, ME, 1, "", {"kind": "self", "unit_id": -1, "player_id": ME}, "测试")
	var ally: Array[BoardUnit] = ctx.ally_minions()
	var enemy: Array[BoardUnit] = ctx.enemy_minions()
	var all: Array[BoardUnit] = ctx.all_minions()
	_check(ally.size() == 2 and ally[0] == a1 and ally[1] == a2, "效果里我方随从：左→右")
	_check(enemy.size() == 2 and enemy[0] == e1 and enemy[1] == e0, "效果里敌方随从：镜像")
	_check(all.size() == 4 and all[0] == a1 and all[1] == a2 and all[2] == e1 and all[3] == e0,
		"全体效果：己方左→右，随后敌方镜像")


# ------------------------------ 死亡结算顺序（同一批一起死） ------------------------------

func _test_death_order() -> void:
	_prepare()
	_gm.log_enabled = true
	_logs.clear()
	_gm.log_message.connect(func(text: String) -> void: _logs.append(text))
	# 4 张名字互不相同的普通随从，方便从日志里按名字认顺序
	var ids := _pick_minions(4)
	_check(ids.size() == 4, "挑到 4 张互不相同的随从用于死亡顺序（%s）" % str(ids))
	var units: Array[BoardUnit] = []
	var uids := [506, 106, 406, 206]     # 己方左、己方右、对方左、对方右（id 顺序与位置顺序相反）
	for i in 4:
		units.append(_spawn(ME if i < 2 else FOE, ids[i], uids[i]))
	_gm.current_player = ME
	# 先把血打空（不结算），再一次性 _cleanup_deaths()，保证四人是**同一批**
	for u in units:
		_gm.deal_damage_to_unit(null, u, 9)
	_check(_gm.get_player(ME).board.size() == 2 and _gm.get_player(FOE).board.size() == 2,
		"伤害已打空但还没结算死亡")
	_gm._cleanup_deaths()
	var died: Array[String] = []
	for line in _logs:
		if line.contains("被消灭"):
			for u in units:
				if line.contains(u.data.card_name) and not died.has(u.data.card_name):
					died.append(u.data.card_name)
	_check(died.size() == 4, "四个随从都结算了死亡（%d：%s）" % [died.size(), str(died)])
	if died.size() == 4:
		_check(died[0] == units[0].data.card_name and died[1] == units[1].data.card_name,
			"死亡结算：先己方左→右（%s）" % str(died))
		_check(died[2] == units[3].data.card_name and died[3] == units[2].data.card_name,
			"死亡结算：再敌方镜像（%s）" % str(died))
	_check(_gm.get_player(ME).board.is_empty() and _gm.get_player(FOE).board.is_empty(), "战场清空")


# ------------------------------ 攻击目标列表的顺序 ------------------------------

func _test_attack_target_order() -> void:
	_prepare()
	var attacker: BoardUnit = _spawn(ME, "c001", 503)
	attacker.summoned_turn = -1
	attacker.attacks_used = 0
	var ids := _pick_minions(2)
	var e0: BoardUnit = _spawn(FOE, ids[0], 403)          # 对方视角的左
	var e1: BoardUnit = _spawn(FOE, ids[1], 203)          # 对方视角的右
	var got: Array[int] = []
	for t in _gm.get_valid_attack_targets(ME, attacker.unit_id):
		got.append(int(t["unit_id"]))
	_check(got.size() >= 2 and got[0] == e1.unit_id and got[1] == e0.unit_id,
		"攻击目标列表按本视角的镜像顺序（最左 = 列表第一个）：%s" % str(got))


# ------------------------------ 定长格子 / 空位保留 ------------------------------
#
# 用户的规则：战场是**定长 7 格**；随从死亡后**不收紧**，空位留着，下一位随从可以补进来
# （与原版《影之诗》的连续排列不同，这是明确选定的规则）；
# 出牌 / 召唤时可以**指定放进哪一格**（拖到哪一格就放哪一格）。
# 这一节把「指定格子放置」「空位保留」「按格子索引结算」「占用计数」全部钉死。

func _test_slot_semantics() -> void:
	var gm = _gm
	var plain: CardData = _db.get_card("c001")      # 见习法师 2/3：无战吼无关键字，放格子最干净
	var other: CardData = _db.get_card("c006")      # 雷霆骑士 3/4：同样不需要目标

	# ---- ① 指定的格子放置成功；被占用 / 越界时失败 ----
	_prepare()
	var at5: BoardUnit = gm.summon_unit(ME, plain, 5)
	_check(at5 != null and gm.board_slot(ME, 5) == at5, "指定第 6 格召唤成功")
	_check(gm.slot_of_unit(at5) == 5, "slot_of_unit 返回所在格子号（%d）" % gm.slot_of_unit(at5))
	_check(gm.first_empty_slot(ME) == 0, "第一个空位仍是最左边那一格（%d）" % gm.first_empty_slot(ME))
	var blocked: BoardUnit = gm.summon_unit(ME, other, 5)
	_check(blocked == null and gm.board_slot(ME, 5) == at5, "格子被占用时召唤失败，且不会挤掉原来的随从")
	_check(gm.summon_unit(ME, other, gm.BOARD_LIMIT) == null, "越界格子召唤失败")
	var at0: BoardUnit = gm.summon_unit(ME, plain, 0)
	_check(at0 != null and gm.board_slot(ME, 0) == at0, "另一格指定召唤成功")
	_check(not gm.place_unit_at(ME, at5, 0), "place_unit_at 放进已占用的格子 → false")
	_check(gm.board_slot(ME, 0) == at0 and gm.board_slot(ME, 5) == at5, "失败后两边都还在自己的格子里")

	# ---- ② 死亡后空位保留、其它随从不移动 ----
	_prepare()
	var left: BoardUnit = gm.summon_unit(ME, plain, 1)
	var middle: BoardUnit = gm.summon_unit(ME, other, 4)
	var right: BoardUnit = gm.summon_unit(ME, plain, 6)
	_kill(middle)
	_check(gm.board_slot(ME, 4) == null, "阵亡随从那一格留成空位（第 5 格）")
	_check(gm.slot_of_unit(left) == 1 and gm.slot_of_unit(right) == 6,
		"其它随从**不移动**：仍在第 2 / 第 7 格")
	_check(gm.board_size_used(ME) == 2, "占用计数扣掉阵亡的那个（%d）" % gm.board_size_used(ME))

	# ---- ③ 下一位随从可以补进留空的格子 ----
	var refill: BoardUnit = gm.summon_unit(ME, other, 4)
	_check(refill != null and gm.board_slot(ME, 4) == refill, "指定补进刚空出来的那一格")
	_prepare()
	gm.summon_unit(ME, plain, 0)
	var dying: BoardUnit = gm.summon_unit(ME, other, 1)
	gm.summon_unit(ME, plain, 2)
	_kill(dying)
	var auto_fill: BoardUnit = gm.summon_unit(ME, other)
	_check(auto_fill != null and gm.board_slot(ME, 1) == auto_fill,
		"自动上场的随从优先补进最早的空位（第 2 格）")

	# ---- ④ 有空洞时 unit_order 仍按**格子索引**排序（空位跳过、不影响顺序） ----
	_prepare()
	var mine1: BoardUnit = gm.summon_unit(ME, plain, 1)
	var mine4: BoardUnit = gm.summon_unit(ME, other, 4)
	var mine6: BoardUnit = gm.summon_unit(ME, plain, 6)
	var foe0: BoardUnit = gm.summon_unit(FOE, plain, 0)
	var foe3: BoardUnit = gm.summon_unit(FOE, other, 3)
	var foe5: BoardUnit = gm.summon_unit(FOE, plain, 5)
	var order: Array[BoardUnit] = gm.unit_order(ME)
	_check(order.size() == 6, "有空洞时顺序里只有真实随从（%d）" % order.size())
	if order.size() == 6:
		_check(order[0] == mine1 and order[1] == mine4 and order[2] == mine6,
			"己方按格子索引 1 → 4 → 6 排序")
		_check(order[3] == foe5 and order[4] == foe3 and order[5] == foe0,
			"敌方镜像：格子索引 5 → 3 → 0（本视角右→左）")
	var side: Array[BoardUnit] = gm.side_order(ME)
	_check(side.size() == 3 and side[0] == mine1 and side[2] == mine6, "side_order 同样按格子顺序、跳过空位")
	_check(gm.board_units(ME).size() == 3 and gm.board_size_used(ME) == 3,
		"board_units / board_size_used 只数真实随从（%d / %d）" % [
			gm.board_units(ME).size(), gm.board_size_used(ME)])

	# ---- ⑤ 指定格子出牌：占用时失败且不扣费；空位时成功；to_front 走正中格 ----
	_prepare()
	gm.summon_unit(ME, plain, 0)
	var me: PlayerState = gm.get_player(ME)
	me.hand.clear()
	me.hand.append(other.clone())
	var mana_before: int = me.mana
	_check(not gm.play_card(ME, 0, -1, -1, false, 0), "指定已被占用的格子出牌被拒绝")
	_check(me.hand.size() == 1 and me.mana == mana_before, "被拒绝时不扣费、手牌不动")
	_check(gm.play_card(ME, 0, -1, -1, false, 5), "指定空位出牌成功")
	_check(gm.board_slot(ME, 5) != null and gm.board_slot(ME, 5).data.id == "c006",
		"随从确实落在指定的第 6 格里")
	# to_front：正中格（横置格）此时空着 → 新随从横置进那一格
	me.mana = 10
	me.hand.clear()
	me.hand.append(plain.clone())
	_check(gm.board_slot(ME, gm.BOARD_LIMIT / 2) == null, "正中格（横置格）此时是空的")
	_check(gm.play_card(ME, 0, -1, -1, true), "to_front 把随从横置上场")
	var front: BoardUnit = gm.front_unit(ME)
	_check(front != null and gm.slot_of_unit(front) == gm.BOARD_LIMIT / 2,
		"横置的随从就在正中格里（第 %d 格）" % (gm.BOARD_LIMIT / 2 + 1))

	# ---- ⑤b 占用计数：空洞不影响；满 7 个时拦住出牌 ----
	_prepare()
	var kept: BoardUnit = gm.summon_unit(ME, plain, 2)
	_kill(gm.summon_unit(ME, other, 5))
	_check(gm.board_size_used(ME) == 1, "死亡留空位后占用计数 = 真实随从数（%d）" % gm.board_size_used(ME))
	_check(gm.board_slot(ME, 5) == null and gm.board_slot(ME, 2) == kept, "空洞与原随从的位置都对")
	for i in gm.BOARD_LIMIT:
		gm.summon_unit(ME, plain, i)
	_check(gm.board_size_used(ME) == gm.BOARD_LIMIT,
		"补满后占用计数 = %d（空洞被补上）" % gm.board_size_used(ME))
	me = gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.hand.clear()
	me.hand.append(other.clone())
	_check(not gm.can_play(ME, 0), "战场满 %d 个时新的随从牌打不出" % gm.BOARD_LIMIT)
	_check(not gm.play_card(ME, 0, -1, -1, false, 3), "指定格子也拦得住")
	_check(me.hand.size() == 1 and me.mana == 10, "满场被拒时手牌与法力都没动")


## 把一个随从打死并结算（走真实的伤害管线 + 死亡结算）
func _kill(u: BoardUnit) -> void:
	if u == null:
		return
	_gm.deal_damage_to_unit(null, u, 999)
	_gm._cleanup_deaths()


# ------------------------------ 显示约定 vs 结算顺序 ------------------------------

func _test_display_order() -> void:
	_gm.new_game()
	_main.skip_mulligan()
	var e0: BoardUnit = _spawn(FOE, "c001", 404)          # 对方视角的左（board 下标 0）
	var e1: BoardUnit = _spawn(FOE, "c002", 204)          # 对方视角的右（board 下标 1）
	var a0: BoardUnit = _spawn(ME, "c001", 504)
	var a1: BoardUnit = _spawn(ME, "c002", 104)
	_main._refresh()
	var foe_lane: Dictionary = _row_unit_lane(_main.enemy_board)
	var my_lane: Dictionary = _row_unit_lane(_main.player_board)
	_check(my_lane.has(a0.unit_id) and my_lane.has(a1.unit_id) and foe_lane.has(e0.unit_id) and foe_lane.has(e1.unit_id),
		"两排各画出 2 个随从（车道 %s / %s）" % [str(my_lane), str(foe_lane)])
	if my_lane.size() >= 2:
		_check(my_lane[a0.unit_id] < my_lane[a1.unit_id], "我方显示：board 下标 0 在左、1 在右")
	if foe_lane.size() >= 2:
		_check(foe_lane[e0.unit_id] < foe_lane[e1.unit_id], "敌方显示同样按下标从左到右")
		var order: Array[BoardUnit] = _gm.unit_order(ME)
		_check(order.find(e1) < order.find(e0), "但结算顺序里敌方下标 1 先于下标 0（镜像：屏幕右→左）")


## 把一排战场里「unit_id → 车道序号」抓出来（车道的先后 = 屏幕上的左→右）
func _row_unit_lane(row) -> Dictionary:
	var out: Dictionary = {}
	if row == null:
		return out
	var lane := -1
	for cell in row.get_children():
		lane += 1
		for child in cell.get_children():
			if child == null or not child.has_method("set_front"):
				continue                       # set_front 是 UnitUI 独有的接口
			var u = child.get("unit")
			if u == null or not (u is BoardUnit):
				continue
			out[int(u.unit_id)] = lane
	return out


# ------------------------------ 辅助 ------------------------------

func _pick_minions(count: int) -> Array[String]:
	var out: Array[String] = []
	var blocked := ["嘲讽", "潜行", "复生", "坚壁", "迟钝"]
	for c in _db.cards:
		if c.is_token or c.card_type != CardData.CardType.MINION or c.attack <= 0:
			continue
		var skip := false
		for kn in c.keyword_names():
			if blocked.has(kn):
				skip = true
		if skip:
			continue
		out.append(c.id)
		if out.size() >= count:
			break
	return out


func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		p.max_mana = 10
		p.mana = 10
		p.board.clear()
		p.hand.clear()
		p.graveyard.clear()
	_gm.current_player = ME
	_gm.busy = false


func _spawn(pid: int, card_id: String, uid: int) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, uid)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


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
	print("=== 场上结算顺序测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
