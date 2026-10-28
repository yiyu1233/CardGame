extends SceneTree
## 效果「随机获得技能 / 能力 / 效果」测试。
##
## 覆盖：
##   * gain_random_skill：从手牌 / 场上随机抽 1 个技能覆盖目标；
##   * gain_random_ability：从指定范围抽来源，把触发能力追加到目标；
##   * gain_random_effect：从指定范围抽来源，当场结算它的效果链；
##   * 来源范围：手牌 / 场上 / 卡包 / 兵种 / 非法值；
##   * 卡面文本、管理面板输入框、保存自检、卡表自检；
##   * token 字段不会被误当成衍生物 ID 写进老字段。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/gain_random_test.gd

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
		_seed()
		_run()
		_finish()
		return false
	return _frames > 900


func _run() -> void:
	_test_skill()
	_test_ability()
	_test_effect()
	_test_scopes()
	_test_text_and_validation()
	_test_admin_ui()
	_cleanup()


# ------------------------------ 造卡 ------------------------------

func _seed() -> void:
	for c in _db.cards.duplicate():
		if str(c.id).begins_with("gr_"):
			_db.remove_card(c.id)
	_add(_card("gr_skill_a", "测试·技能甲", 2, 2, {
		"name": "测试技能甲", "cost": 1, "target": 0, "once_per_turn": true,
		"effects": [{"id": "armor", "value": 3, "target": -1}],
	}))
	_add(_card("gr_skill_b", "测试·技能乙", 2, 2, {
		"name": "测试技能乙", "cost": 1, "target": 0, "once_per_turn": true,
		"effects": [{"id": "armor", "value": 4, "target": -1}],
	}))
	_add(_card("gr_ability", "测试·能力源", 1, 1, {}, [
		{"on": CardTriggers.EV_TURN_START,
			"effects": [{"id": "armor", "value": 2, "target": -1}]},
	]))
	_add(_card("gr_effect", "测试·效果源", 1, 1, {}, [], [
		{"id": "armor", "value": 9, "target": -1},
	]))
	_add(_card("gr_target", "测试·获得方", 3, 4, {}, [], [], "basic", "neutral"))


func _card(id: String, name_: String, atk: int, hp: int,
		skill: Dictionary = {}, triggers: Array = [], effects: Array = [],
		pack_id: String = "", troop_id: String = "") -> CardData:
	return CardData.from_dict({
		"id": id, "card_name": name_, "cost": 1,
		"card_type": CardData.CardType.MINION, "attack": atk, "health": hp,
		"skill": skill, "triggers": triggers, "effects": effects,
		"pack_id": pack_id, "troop_id": troop_id,
	})


func _add(c: CardData) -> void:
	if _db.add_card(c):
		_created.append(c.id)


func _fresh(id: String) -> CardData:
	var c: CardData = _db.get_card(id)
	return c.clone() if c != null else null


func _apply(effect_id: String, value: int, scope: String, target: Dictionary = {}) -> void:
	var ctx := EffectContext.create(_gm, ME, value, scope, target)
	CardEffects.apply(effect_id, ctx)


# ------------------------------ 随机获得技能 ------------------------------

func _test_skill() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("gr_target"))
	me.hand.append(_fresh("gr_skill_a"))
	_apply(CardEffects.GAIN_RANDOM_SKILL, 0, "hand", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": ME})
	_check(u.data.skill_name() == "测试技能甲", "从手牌随机获得技能（%s）" % u.data.skill_name())
	_check(u.skill_used_turn == -1, "新技能本回合可立刻发动")

	# 同一张卡的技能不重复抽：换成只有一个候选时不会覆盖已有技能
	_apply(CardEffects.GAIN_RANDOM_SKILL, 0, "hand", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": ME})
	_check(u.data.skill_name() == "测试技能甲", "目标已有同一个技能时不会空抽覆盖")


# ------------------------------ 随机获得能力 ------------------------------

func _test_ability() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("gr_target"))
	var foe: BoardUnit = _gm.summon_unit(FOE, _fresh("gr_ability"))
	_apply(CardEffects.GAIN_RANDOM_ABILITY, 1, "enemy_board", {
		"kind": "unit", "unit_id": u.unit_id, "player_id": ME})
	_check(u.data.triggers.size() == 1, "从敌方场上随机获得 1 条触发能力（%d）" % u.data.triggers.size())
	_check(foe != null, "来源随从仍在场上")
	me.armor = 0
	_gm._fire_board_triggers(ME, CardTriggers.EV_TURN_START)
	_check(me.armor == 2, "获得的能力按原时机结算（护甲 %d）" % me.armor)


# ------------------------------ 随机获得效果 ------------------------------

func _test_effect() -> void:
	var me := _prepare()
	me.hand.append(_fresh("gr_effect"))
	_apply(CardEffects.GAIN_RANDOM_EFFECT, 1, "hand", {
		"kind": "self", "unit_id": -1, "player_id": ME})
	_check(me.armor == 9, "从手牌随机获得并立即结算效果（护甲 %d）" % me.armor)


# ------------------------------ 来源范围 ------------------------------

func _test_scopes() -> void:
	var me := _prepare()
	var u: BoardUnit = _gm.summon_unit(ME, _fresh("gr_target"))
	var self_ctx := {"kind": "unit", "unit_id": u.unit_id, "player_id": ME}
	var ctx := EffectContext.create(_gm, ME, 1, "pack:basic", self_ctx)
	var cards := CardEffects._scope_sources(ctx, "pack:basic")
	_check(_has_card(cards, "gr_target"), "pack:basic 能枚举到该卡包里的卡")
	cards = CardEffects._scope_sources(ctx, "troop:neutral")
	_check(_has_card(cards, "gr_target"), "troop:neutral 能枚举到中立兵种的卡")
	cards = CardEffects._scope_sources(ctx, "board")
	_check(_has_card(cards, "gr_target") and not _has_card(cards, "gr_skill_a"),
		"board 只取本方场上随从")


# ------------------------------ 文本 / 自检 ------------------------------

func _test_text_and_validation() -> void:
	var text := CardEffects.text(CardEffects.GAIN_RANDOM_SKILL, 0, 0, 0, "hand")
	_check(text.contains("本方手牌"), "技能文本带来源范围（%s）" % text)
	var etext := CardEffects.text(CardEffects.GAIN_RANDOM_EFFECT, 2, 0, 0, "enemy_board")
	_check(etext.contains("敌方场上随从") and etext.contains("2"), "效果文本带范围与数量（%s）" % etext)
	var pack_text := CardEffects.text(CardEffects.GAIN_RANDOM_ABILITY, 1, 0, 0, "pack:basic")
	_check(pack_text.contains("卡包"), "卡包范围文本带卡包名（%s）" % pack_text)

	_check(CardEffects.has(CardEffects.GAIN_RANDOM_SKILL)
		and CardEffects.has(CardEffects.GAIN_RANDOM_ABILITY)
		and CardEffects.has(CardEffects.GAIN_RANDOM_EFFECT), "三个新效果已注册")
	_check(CardEffects.needs_scope(CardEffects.GAIN_RANDOM_SKILL), "技能效果要求来源范围")
	_check(CardEffects.context_warning(CardEffects.GAIN_RANDOM_SKILL, "leave", "") != "",
		"没填范围时管理面板会标红")
	_check(CardEffects.context_warning(CardEffects.GAIN_RANDOM_SKILL, "leave", "bogus") != "",
		"无法识别的范围会标红")
	_check(CardEffects.context_warning(CardEffects.GAIN_RANDOM_SKILL, "leave", "hand") == "",
		"合法范围不会被误标")
	_check(CardEffects.context_warning(CardEffects.GAIN_RANDOM_SKILL, "leave", "pack:no_such") != "",
		"不存在的卡包会标红")

	var c := _card("gr_validate", "测试·范围自检", 1, 1)
	c.effects = [{"id": CardEffects.GAIN_RANDOM_ABILITY, "token": "no_such_scope", "target": -1}]
	var errs: Array[String] = _db._chain_errors(c, c.effects, "战吼")
	_check(_has_text(errs, "无法识别"), "卡表自检报「无法识别的来源范围」")

	# token 是来源范围，不是衍生物：不能写进老字段 token_id
	c.effects = [{"id": CardEffects.GAIN_RANDOM_SKILL, "token": "hand", "target": 4}]
	c.sync_legacy_from_chains()
	_check(c.token_id == "", "来源范围不会被当成衍生物 ID（%s）" % c.token_id)


# ------------------------------ 管理员面板 ------------------------------

func _test_admin_ui() -> void:
	_admin._battlecry_editor.clear()
	_admin._battlecry_editor.add_row(CardEffects.GAIN_RANDOM_SKILL, 0, 4, "hand")
	var st: Dictionary = _admin._battlecry_editor.row_state(0)
	var token_edit: LineEdit = st["token_edit"]
	_check(token_edit.visible, "来源范围输入框可见")
	_check(token_edit.placeholder_text.contains("来源范围"),
		"输入框提示为来源范围（%s）" % token_edit.placeholder_text)
	var chain: Array[Dictionary] = _admin._battlecry_editor.chain()
	_check(chain.size() == 1 and str(chain[0].get("token", "")) == "hand",
		"来源范围会写进效果链")

	var missing: String = _admin._validate_chain(
		[{"id": CardEffects.GAIN_RANDOM_ABILITY, "token": "", "target": 4}], "测试", false)
	_check(missing.contains("没有填写来源范围"), "面板自检拦下「没填范围」")
	var bogus: String = _admin._validate_chain(
		[{"id": CardEffects.GAIN_RANDOM_ABILITY, "token": "bogus", "target": 4}], "测试", false)
	_check(bogus.contains("无法识别"), "面板自检拦下「无法识别的范围」")
	var ok: String = _admin._validate_chain(
		[{"id": CardEffects.GAIN_RANDOM_ABILITY, "token": "hand", "target": 4}], "测试", false)
	_check(ok == "", "合法来源范围通过自检（%s）" % ok)

	# 随机能力池的 pool ID 也要能写进链（同一 token 字段）
	_admin._battlecry_editor.clear()
	_admin._battlecry_editor.add_row(CardEffects.RANDOM_POOL, 0, -1, "chaos")
	var pool_chain: Array[Dictionary] = _admin._battlecry_editor.chain()
	_check(pool_chain.size() == 1 and str(pool_chain[0].get("token", "")) == "chaos",
		"能力池 ID 会写进效果链")


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
	foe.deck.clear()
	foe.armor = 0
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


func _has_card(cards: Array, id: String) -> bool:
	for c in cards:
		if c != null and str(c.id) == id:
			return true
	return false


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
	print("=== 随机获得技能 / 能力 / 效果测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
