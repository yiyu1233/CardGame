extends SceneTree
## 指定目标规则测试：
##   * **随从 / 护符 / 城邦的战吼**：场上没有合法目标时**照样能上场**（战吼空放，不结算效果）；
##   * **法术**：没有合法目标时**无法释放**（卡面变暗、拖不起来、点击给出具体原因）；
##   * 不需要目标的牌（无目标法术 / 无战吼随从）照常能打。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/target_rule_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _db
var _gm
var _main
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_run_rules()
		return false
	if _frames == 4:
		_run_ui()
		_finish()
		return true
	return _frames > 400


# ------------------------------ 规则 ------------------------------

func _run_rules() -> void:
	# 1) 随从战吼指定「我方随从」，而我方场上没有随从 → 没有合法目标
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var commander: CardData = _db.get_card("c013")          # 战地指挥官：战吼使一个友方随从 +1/+1
	_check(commander != null and commander.is_minion() and commander.needs_target(), "c013 是需要指定目标（我方随从）的战吼随从")
	_check(_gm.get_valid_targets(ME, commander).is_empty(), "我方场上没有随从时，它的目标列表为空")
	_check(_gm.has_valid_targets(ME, commander) == false, "has_valid_targets() 报「没有合法目标」")
	_give(ME, "c013")
	_check(_gm.can_play(ME, 0), "没有合法目标时，战吼随从照样可以上场（can_play 为真）")
	var played: bool = _gm.play_card(ME, 0)
	_check(played, "战吼随从在无目标时成功打出")
	_check(me.hand.size() == 0, "手牌被正常移除（%d 张）" % me.hand.size())
	_check(me.board.size() == 1, "随从正常上场（战场 %d 个）" % me.board.size())
	_check(me.mana == 10 - commander.cost, "照常扣费（剩 %d）" % me.mana)
	# 战吼空放：我方场上只有刚上场的它自己，且没有被 +1/+1（1/1 仍是 1/1）
	var unit: BoardUnit = me.board[0]
	_check(unit.attack == commander.attack and unit.health == commander.health,
		"战吼空放、没有结算（%d/%d）" % [unit.attack, unit.health])

	# 2) 有合法目标时照常结算（对照）
	_prepare()
	me = _gm.get_player(ME)
	var ally: BoardUnit = _gm.summon_unit(ME, _db.get_card("c001"))    # 2/3
	_gm.summon_unit(ME, _db.get_card("c002"))
	_give(ME, "c013")
	_check(_gm.has_valid_targets(ME, commander), "有友方随从时目标列表非空")
	var ally_atk: int = ally.attack
	_check(_gm.play_card(ME, 0, ally.unit_id, ME), "有目标时战吼随从正常打出并指定目标")
	_check(ally.attack == ally_atk + 1, "战吼正常结算（+1 攻击：%d -> %d）" % [ally_atk, ally.attack])

	# 3) 法术指定「敌方随从」，而敌方场上没有随从 → 不能释放
	_prepare()
	me = _gm.get_player(ME)
	var banish: CardData = _db.get_card("s009")              # 湮灭：消灭一个敌方随从
	if banish == null or not banish.needs_target():
		for c in _db.cards:
			if c.card_type == CardData.CardType.SPELL and c.target == CardData.Targeting.ENEMY_MINION:
				banish = c
				break
	_check(banish != null and banish.needs_target(), "找到需要指定敌方随从的法术（%s）" % ("无" if banish == null else banish.card_name))
	if banish != null:
		_check(_gm.get_valid_targets(ME, banish).is_empty(), "敌方场上没有随从时，法术目标列表为空")
		_check(not _gm.has_valid_targets(ME, banish), "has_valid_targets() 对法术报「没有合法目标」")
		_give(ME, banish.id)
		var mana_before: int = me.mana
		_check(not _gm.can_play(ME, 0), "法术没有合法目标时 can_play 为假（不能释放）")
		_check(not _gm.play_card(ME, 0), "直接调用 play_card 也会被拒绝")
		_check(me.hand.size() == 1, "被拒绝时手牌没有减少（%d 张）" % me.hand.size())
		_check(me.mana == mana_before, "被拒绝时没有扣费（%d）" % me.mana)
		# 敌方有随从之后就打得出
		_gm.summon_unit(FOE, _db.get_card("c001"))
		_check(_gm.has_valid_targets(ME, banish), "敌方有随从后目标列表非空")
		_check(_gm.can_play(ME, 0), "有目标后法术可以释放")

	# 4) 不需要目标的法术：照样能打（回归）
	_prepare()
	me = _gm.get_player(ME)
	_give(ME, "s003")                                        # 智慧卷轴：抽 2 张
	var hand_before: int = me.hand.size()
	_check(_gm.can_play(ME, 0), "无目标法术不受影响，可以打出")
	_check(_gm.play_card(ME, 0), "无目标法术成功打出")
	_check(me.hand.size() == hand_before - 1 + 2, "抽牌效果照常（手牌 %d -> %d）" % [hand_before, me.hand.size()])

	# 5) 无战吼 / 无目标随从照常上场
	_prepare()
	me = _gm.get_player(ME)
	_give(ME, "c001")
	_check(_gm.can_play(ME, 0) and _gm.play_card(ME, 0), "普通随从（不需要目标）照常上场")

	# 6) 护符 / 城邦的“安放”效果同样可以空放上场
	_prepare()
	me = _gm.get_player(ME)
	var city: CardData = _db.get_card("y001").clone()
	city.target = CardData.Targeting.ENEMY_MINION       # 人为给它一个“需要指定敌方随从”的安放效果
	city.effect_id = "damage"
	city.value = 3
	_check(city.is_city() and city.needs_target(), "构造一个需要指定目标的城邦卡")
	_check(_gm.get_valid_targets(ME, city).is_empty(), "敌方场上没有随从 → 城邦没有合法目标")
	me.hand.clear()
	me.hand.append(city)
	_check(_gm.can_play(ME, 0), "城邦即使没有合法目标也能安放（战吼类空放）")
	_check(_gm.play_card(ME, 0), "城邦成功安放")
	_check(me.board.size() == 1 and me.board[0].is_permanent(), "城邦占了一格")

	# 7) 玩家英雄永远是自己法术的合法目标（不会被误判为“没目标”）
	_prepare()
	me = _gm.get_player(ME)
	var fire: CardData = _db.get_card("s001")                # 火焰冲击：任意角色
	_check(_gm.has_valid_targets(ME, fire), "任意角色类法术永远有目标（双方英雄）")


# ------------------------------ 界面 ------------------------------

func _run_ui() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	if _main == null:
		_check(false, "主场景可实例化")
		return
	_gm.new_game()
	_main.skip_mulligan()
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.board.clear()
	_gm.get_player(FOE).board.clear()

	# 无目标的战吼随从：点一下就上场（不会卡在“选择目标”状态）
	_give(ME, "c013")
	_main._refresh()
	_main._on_hand_card_clicked(0)
	_check(me.hand.size() == 0, "点无目标的战吼随从 → 直接上场（手牌 %d）" % me.hand.size())
	_check(_main.mode == 0, "没有停留在「选择目标」状态（mode=%d）" % _main.mode)
	_check(me.board.size() == 1, "随从确实上场了（战场 %d）" % me.board.size())
	_check(_main._log_text.contains("战吼空放"), "战斗日志里写明「战吼空放」")

	# 无目标法术：打不出，并且给出具体原因
	var banish: CardData = null
	for c in _db.cards:
		if c.card_type == CardData.CardType.SPELL and c.target == CardData.Targeting.ENEMY_MINION:
			banish = c
			break
	if banish != null:
		me.board.clear()
		_gm.get_player(FOE).board.clear()
		_give(ME, banish.id)
		_main._refresh()
		_check(_main._cannot_play_reason(0).contains("没有合法目标"),
			"操作栏说明原因：%s" % _main._cannot_play_reason(0))
		var before: int = me.hand.size()
		_main._on_hand_card_clicked(0)
		_check(me.hand.size() == before, "点无目标法术不会打出（手牌 %d）" % me.hand.size())
		_check(_main.mode == 0, "也不会进入选择目标状态")
	_main.queue_free()


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = true
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.hand.clear()
	me.board.clear()
	_gm.get_player(FOE).hand.clear()
	_gm.get_player(FOE).board.clear()


func _give(pid: int, card_id: String) -> void:
	var p: PlayerState = _gm.get_player(pid)
	p.hand.clear()
	p.hand.append(_db.get_card(card_id).clone())


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
	print("=== 指定目标规则测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
