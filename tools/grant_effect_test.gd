extends SceneTree
## 效果「赋予技能 / 赋予能力」测试。
##
## 覆盖：
##   * grant_skill：把来源卡牌的主动技能复制给目标（可立刻发动），离场 / 沉默时摘掉；
##   * grant_ability：把来源卡牌的触发能力追加给目标，触发时按时机结算，离场时摘掉；
##   * 卡面文本（带来源卡名 / 技能名）；
##   * 管理员与卡表自检（缺来源 / 来源不存在 / 来源没有对应内容）；
##   * 面板输入框提示为「卡牌 ID」而不是衍生物 ID。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/grant_effect_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _admin = null
var _fail_lines: Array[String] = []
var _created: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null or root.get_node_or_null("AdminAuth") == null:
			_check(false, "CardDB / GameManager / AdminAuth 自动加载")
			_finish()
			return true
		var panel_script = load("res://scripts/AdminPanel.gd")
		_admin = panel_script.new() if panel_script != null else null
		_check(_admin != null, "管理员面板可实例化（编译通过）")
		if _admin == null:
			_finish()
			return true
		root.add_child(_admin)
		_phase = 1
		return false
	if _phase == 1 and _frames >= 4:
		_phase = 2
		_run()
		_finish()
		return false
	return _frames > 900


func _run() -> void:
	_seed()
	_test_skill_grant()
	_test_ability_grant()
	_test_text_and_validation()
	_test_admin_ui()
	_cleanup()


# ------------------------------ 造卡 ------------------------------

func _seed() -> void:
	for c in _db.cards.duplicate():
		if str(c.id).begins_with("ge_"):
			_db.remove_card(c.id)
	_add(_card("ge_skill_src", "测试·技能源", 2, 2, {
		"name": "测试技能", "cost": 1, "target": 0, "once_per_turn": true,
		"effects": [{"id": "armor", "value": 7, "target": -1}],
	}))
	_add(_card("ge_ability_src", "测试·能力源", 2, 2, {}, [
		{"on": CardTriggers.EV_TURN_START,
			"effects": [{"id": "armor", "value": 5, "target": -1}]},
		{"on": CardTriggers.EV_LEAVE,
			"effects": [{"id": "armor", "value": 6, "target": -1}]},
	]))
	_add(_card("ge_target", "测试·被赋予者", 3, 4))
	_add(_card("ge_plain", "测试·无技能源", 1, 1))


func _card(id: String, name_: String, atk: int, hp: int,
		skill: Dictionary = {}, triggers: Array = []) -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": 1,
		"card_type": CardData.CardType.MINION, "attack": atk, "health": hp,
		"skill": skill, "triggers": triggers,
	})
	return c


func _add(c: CardData) -> void:
	if _db.add_card(c):
		_created.append(c.id)


func _fresh(id: String) -> CardData:
	var c: CardData = _db.get_card(id)
	return c.clone() if c != null else null


func _grant(u: BoardUnit, effect_id: String, source_id: String) -> void:
	var ctx := EffectContext.create(_gm, ME, 0, source_id, {
		"kind": "unit", "unit_id": u.unit_id, "player_id": u.owner_id})
	CardEffects.apply(effect_id, ctx)


# ------------------------------ 赋予技能 ------------------------------

func _test_skill_grant() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("ge_target"))
	_check(u != null and not u.data.has_skill(), "被赋予者原本没有技能")
	_grant(u, CardEffects.GRANT_SKILL, "ge_skill_src")
	_check(u.data.has_skill(), "赋予后拥有主动技能")
	_check(u.data.skill_name() == "测试技能", "技能名来自来源卡（%s）" % u.data.skill_name())
	_check(u.skill_used_turn == -1, "新技能本回合可立刻发动")

	me.armor = 0
	me.mana = 10
	_check(_gm.use_skill(ME, u.unit_id), "赋予的技能可以发动")
	_check(me.armor == 7, "技能效果按来源卡结算（护甲 %d）" % me.armor)

	# 沉默：赋予的技能被摘掉
	_grant(u, CardEffects.GRANT_SKILL, "ge_skill_src")
	u.silence()
	_check(not u.data.has_skill(), "沉默会摘掉赋予的技能")

	# 离场：赋予的技能不跟着进墓地
	_grant(u, CardEffects.GRANT_SKILL, "ge_skill_src")
	var ctx := EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": ME})
	ctx.kill_unit(u)
	_gm._cleanup_deaths()
	var grave_card: CardData = me.graveyard[-1]
	_check(not grave_card.has_skill(), "进墓地后不再带赋予的技能")

	# 来源没有技能：不生效
	var u2: BoardUnit = _gm.summon_unit(ME, _fresh("ge_target"))
	_grant(u2, CardEffects.GRANT_SKILL, "ge_plain")
	_check(not u2.data.has_skill(), "来源没有技能时不生效")


# ------------------------------ 赋予能力 ------------------------------

func _test_ability_grant() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("ge_target"))
	_check(u.data.triggers.is_empty(), "被赋予者原本没有触发能力")
	_grant(u, CardEffects.GRANT_ABILITY, "ge_ability_src")
	_check(u.data.triggers.size() == 2, "赋予后获得 2 条触发能力（%d）" % u.data.triggers.size())

	# 回合开始：只让这一只单位触发（先清场）
	me.armor = 0
	_gm._fire_board_triggers(ME, CardTriggers.EV_TURN_START)
	_check(me.armor == 5, "赋予的「回合开始」能力结算（护甲 %d）" % me.armor)

	# 重复赋予不会叠出重复条目
	_grant(u, CardEffects.GRANT_ABILITY, "ge_ability_src")
	_check(u.data.triggers.size() == 2, "重复赋予同一张卡不会重复追加（%d）" % u.data.triggers.size())

	# 离场：赋予的「离场」能力照常结算一次，随后从卡上摘掉
	me.armor = 0
	var ctx := EffectContext.create(_gm, ME, 0, "", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": ME})
	ctx.kill_unit(u)
	_gm._cleanup_deaths()
	_check(me.armor == 6, "赋予的「离场」能力在死亡时结算（护甲 %d）" % me.armor)
	var grave_card: CardData = me.graveyard[-1]
	_check(grave_card.triggers.is_empty(), "进墓地后不再带赋予的能力")


# ------------------------------ 文本 / 自检 ------------------------------

func _test_text_and_validation() -> void:
	var stext := CardEffects.text(CardEffects.GRANT_SKILL, 0, 0, 0, "ge_skill_src")
	_check(stext.contains("测试技能") and stext.contains("测试·技能源"), "技能文本带来源卡与技能名（%s）" % stext)
	var atext := CardEffects.text(CardEffects.GRANT_ABILITY, 0, 0, 0, "ge_ability_src")
	_check(atext.contains("测试·能力源"), "能力文本带来源卡名（%s）" % atext)
	var empty_text := CardEffects.text(CardEffects.GRANT_SKILL, 0, 0, 0, "")
	_check(empty_text.contains("未选择"), "没填来源时文本给出提示")
	_check(CardEffects.has(CardEffects.GRANT_SKILL) and CardEffects.has(CardEffects.GRANT_ABILITY),
		"两个新效果已注册（面板下拉自动出现）")
	_check(not CardEffects.context_warning(CardEffects.GRANT_SKILL, "leave", "").is_empty(),
		"没填来源时管理面板会标红提示")
	_check(CardEffects.context_warning(CardEffects.GRANT_SKILL, "leave", "ge_skill_src") == "",
		"合法来源不会被误标")

	var missing: String = _admin._validate_chain([{"id": CardEffects.GRANT_SKILL, "token": "", "target": 4}], "测试", false)
	_check(missing.contains("来源卡牌"), "面板自检拦下「没填来源」")
	var ghost: String = _admin._validate_chain([{"id": CardEffects.GRANT_SKILL, "token": "no_such", "target": 4}], "测试", false)
	_check(ghost.contains("不存在"), "面板自检拦下「来源不存在」")
	var plain: String = _admin._validate_chain([{"id": CardEffects.GRANT_SKILL, "token": "ge_plain", "target": 4}], "测试", false)
	_check(plain.contains("没有主动技能"), "面板自检拦下「来源没有技能」")
	var ok: String = _admin._validate_chain([{"id": CardEffects.GRANT_SKILL, "token": "ge_skill_src", "target": 4}], "测试", false)
	_check(ok == "", "合法赋予技能通过自检（%s）" % ok)

	var c := _card("ge_validate", "测试·自检卡", 1, 1)
	c.effects = [{"id": CardEffects.GRANT_ABILITY, "token": "ge_plain", "target": 4}]
	var errs: Array[String] = _db._chain_errors(c, c.effects, "战吼")
	_check(_has_text(errs, "没有触发能力"), "卡表自检也报「来源没有触发能力」")


# ------------------------------ 管理员面板 ------------------------------

func _test_admin_ui() -> void:
	_admin._battlecry_editor.clear()
	_admin._battlecry_editor.add_row(CardEffects.GRANT_SKILL, 0, 4, "ge_skill_src")
	var st: Dictionary = _admin._battlecry_editor.row_state(0)
	var token_edit: LineEdit = st["token_edit"]
	_check(token_edit.visible, "赋予技能的来源输入框可见")
	_check(token_edit.placeholder_text.contains("卡牌 ID"), "输入框提示为卡牌 ID（%s）" % token_edit.placeholder_text)
	var chain: Array[Dictionary] = _admin._battlecry_editor.chain()
	_check(chain.size() == 1 and str(chain[0].get("token", "")) == "ge_skill_src",
		"来源卡牌 ID 会写进效果链")


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> PlayerState:
	_gm.new_game()
	_gm.current_player = ME
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.reset_slots()
	me.graveyard.clear()
	me.grave_entered.clear()
	me.grave_entered_total = 0
	me.deck.clear()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hand.clear()
	foe.board.clear()
	foe.reset_slots()
	foe.graveyard.clear()
	foe.grave_entered.clear()
	foe.grave_entered_total = 0
	return me


func _cleanup() -> void:
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		if p == null:
			continue
		p.board.clear()
		p.reset_slots()
		p.hand.clear()
		p.graveyard.clear()
		p.deck.clear()


func _has_text(lines: Array, part: String) -> bool:
	for line in lines:
		if str(line).contains(part):
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
	for id in _created:
		_db.remove_card(id)
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 赋予技能 / 能力测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
