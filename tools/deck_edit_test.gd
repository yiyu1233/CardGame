extends SceneTree
## 效果「替换卡牌 / 破坏牌库卡牌 / 向牌库加牌」测试。
##
## 覆盖：
##   * replace_cards：手牌 / 牌库替换成指定卡，或对手手牌 / 对手牌堆里的牌；
##   * destroy_deck_cards：随机 / 指定卡 / 同名 / 费用 / 带某效果的卡；
##   * add_cards_to_deck：指定卡 / 卡包范围内随机；
##   * 复合 token「区域|目标」的卡面文本、管理面板输入框、保存自检、卡表自检。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/deck_edit_test.gd

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
	_test_replace()
	_test_destroy()
	_test_add()
	_test_text_and_validation()
	_test_admin_ui()
	_cleanup()


# ------------------------------ 造卡 ------------------------------

func _seed() -> void:
	for c in _db.cards.duplicate():
		if str(c.id).begins_with("de_"):
			_db.remove_card(c.id)
	_add(_card("de_repl", "测试·替换目标", 1))
	_add(_card("de_a", "测试·甲", 1))
	_add(_card("de_b", "测试·乙", 2))
	_add(_card("de_c", "测试·丙", 3))
	_add(_card("de_same1", "测试·同名", 1))
	_add(_card("de_same2", "测试·同名", 3))
	_add(_card("de_armor", "测试·护甲效果", 1, [{"id": "armor", "value": 1, "target": -1}]))
	_add(_card("de_damage", "测试·伤害效果", 1, [{"id": "damage", "value": 1, "target": -1}]))
	_add(_card("de_add", "测试·加入牌库", 1))


func _card(id: String, name_: String, cost: int = 1, effects: Array = []) -> CardData:
	return CardData.from_dict({
		"id": id, "card_name": name_, "cost": cost,
		"card_type": CardData.CardType.MINION, "attack": 1, "health": 1,
		"effects": effects,
	})


func _add(c: CardData) -> void:
	if _db.add_card(c):
		_created.append(c.id)


func _fresh(id: String) -> CardData:
	var c: CardData = _db.get_card(id)
	return c.clone() if c != null else null


func _apply(effect_id: String, value: int, token: String) -> void:
	var ctx := EffectContext.create(_gm, ME, value, token, {
		"kind": "self", "unit_id": -1, "player_id": ME})
	CardEffects.apply(effect_id, ctx)


# ------------------------------ 替换 ------------------------------

func _test_replace() -> void:
	# 手牌 → 指定卡
	var me := _prepare()
	me.hand.append(_fresh("de_a"))
	me.hand.append(_fresh("de_b"))
	me.hand.append(_fresh("de_c"))
	_apply(CardEffects.REPLACE_CARDS, 2, "hand|card:de_repl")
	_check(me.hand.size() == 3, "替换后手牌数量不变（%d）" % me.hand.size())
	var repl := _count_id(me.hand, "de_repl")
	_check(repl == 2, "手牌有 2 张换成指定卡（%d）" % repl)
	_check(me.graveyard.size() == 2, "被替换掉的 2 张手牌进入墓地（%d）" % me.graveyard.size())

	# 牌库 → 对手手牌（来源不消耗）
	me = _prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	me.deck.append(_fresh("de_a"))
	me.deck.append(_fresh("de_b"))
	foe.hand.append(_fresh("de_c"))
	_apply(CardEffects.REPLACE_CARDS, 2, "deck|enemy_hand")
	_check(me.deck.size() == 2, "替换后牌库数量不变（%d）" % me.deck.size())
	_check(_count_id(me.deck, "de_c") == 2, "牌库的牌被换成对手手牌里的牌")
	_check(foe.hand.size() == 1, "对手手牌没有被消耗（%d）" % foe.hand.size())

	# 敌方手牌 → 对手牌堆（对手 = 发动者的对手，即 FOE 自己）
	me = _prepare()
	foe = _gm.get_player(FOE)
	foe.deck.clear()
	foe.hand.append(_fresh("de_a"))
	foe.deck.append(_fresh("de_b"))
	_apply(CardEffects.REPLACE_CARDS, 1, "enemy_hand|enemy_deck")
	_check(_count_id(foe.hand, "de_b") == 1, "敌方手牌被换成本方（敌方）牌堆里的牌")


# ------------------------------ 破坏牌库 ------------------------------

func _test_destroy() -> void:
	var me := _prepare()
	for id in ["de_a", "de_b", "de_c", "de_a", "de_b"]:
		me.deck.append(_fresh(id))
	_apply(CardEffects.DESTROY_DECK_CARDS, 2, "deck|random")
	_check(me.deck.size() == 3, "随机破坏 2 张牌（剩 %d）" % me.deck.size())
	_check(me.graveyard.size() == 2, "被破坏的牌进入墓地（%d）" % me.graveyard.size())

	# 指定卡
	me = _prepare()
	me.deck.append(_fresh("de_a"))
	me.deck.append(_fresh("de_b"))
	me.deck.append(_fresh("de_a"))
	_apply(CardEffects.DESTROY_DECK_CARDS, 0, "deck|card:de_a")
	_check(_count_id(me.deck, "de_a") == 0 and me.deck.size() == 1, "指定卡全部被破坏")

	# 同名（两个不同 ID、同一个卡名）
	me = _prepare()
	me.deck.append(_fresh("de_same1"))
	me.deck.append(_fresh("de_same2"))
	me.deck.append(_fresh("de_a"))
	_apply(CardEffects.DESTROY_DECK_CARDS, 0, "deck|name:测试·同名")
	_check(me.deck.size() == 1 and me.deck[0].id == "de_a", "同名卡全部被破坏")

	# 费用
	me = _prepare()
	for id in ["de_a", "de_b", "de_c", "de_b"]:
		me.deck.append(_fresh(id))
	_apply(CardEffects.DESTROY_DECK_CARDS, 0, "deck|cost:2")
	_check(_count_id(me.deck, "de_b") == 0 and me.deck.size() == 2, "费用为 2 的牌全部被破坏")

	# 带某个效果的卡
	me = _prepare()
	for id in ["de_armor", "de_damage", "de_a", "de_armor"]:
		me.deck.append(_fresh(id))
	_apply(CardEffects.DESTROY_DECK_CARDS, 0, "deck|effect:armor")
	_check(_count_id(me.deck, "de_armor") == 0 and me.deck.size() == 2,
		"带「护甲」效果的牌全部被破坏")

	# 张数上限
	me = _prepare()
	for id in ["de_a", "de_a", "de_a"]:
		me.deck.append(_fresh(id))
	_apply(CardEffects.DESTROY_DECK_CARDS, 2, "deck|card:de_a")
	_check(me.deck.size() == 1, "筛选口径下 value 是张数上限（剩 %d）" % me.deck.size())

	# 敌方牌库
	me = _prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.deck.append(_fresh("de_a"))
	foe.deck.append(_fresh("de_b"))
	_apply(CardEffects.DESTROY_DECK_CARDS, 1, "enemy_deck|random")
	_check(foe.deck.size() == 1 and me.deck.is_empty(), "只破坏敌方牌库（敌方剩 %d）" % foe.deck.size())


# ------------------------------ 加入牌库 ------------------------------

func _test_add() -> void:
	var me := _prepare()
	_apply(CardEffects.ADD_CARDS_TO_DECK, 3, "deck|card:de_add")
	_check(me.deck.size() == 3 and _count_id(me.deck, "de_add") == 3,
		"指定卡按数量加入牌库（%d）" % me.deck.size())

	me = _prepare()
	_apply(CardEffects.ADD_CARDS_TO_DECK, 2, "deck|pack:basic")
	_check(me.deck.size() == 2, "卡包范围内随机加入 2 张（%d）" % me.deck.size())
	_check(not _has_token_card(me.deck), "不会把衍生物加进牌库")

	me = _prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	_apply(CardEffects.ADD_CARDS_TO_DECK, 2, "enemy_deck|card:de_add")
	_check(foe.deck.size() == 2 and me.deck.is_empty(), "可以向敌方牌库加牌")


# ------------------------------ 文本 / 自检 ------------------------------

func _test_text_and_validation() -> void:
	var rtext := CardEffects.text(CardEffects.REPLACE_CARDS, 2, 0, 0, "hand|card:de_repl")
	_check(rtext.contains("本方手牌") and rtext.contains("测试·替换目标") and rtext.contains("2"),
		"替换文本带区域 / 卡名 / 张数（%s）" % rtext)
	var dtext := CardEffects.text(CardEffects.DESTROY_DECK_CARDS, 0, 0, 0, "deck|cost:2")
	_check(dtext.contains("所有") and dtext.contains("费用为 2"), "破坏文本带筛选口径（%s）" % dtext)
	var atext := CardEffects.text(CardEffects.ADD_CARDS_TO_DECK, 3, 0, 0, "deck|pack:basic")
	_check(atext.contains("3") and atext.contains("基础卡包"), "加牌文本带数量与卡包（%s）" % atext)

	_check(CardEffects.needs_spec(CardEffects.REPLACE_CARDS)
		and CardEffects.needs_spec(CardEffects.DESTROY_DECK_CARDS)
		and CardEffects.needs_spec(CardEffects.ADD_CARDS_TO_DECK), "三条效果都要求复合参数")
	_check(CardEffects.context_warning(CardEffects.REPLACE_CARDS, "play", "") != "",
		"没填参数时管理面板会标红")
	_check(CardEffects.context_warning(CardEffects.REPLACE_CARDS, "play", "hand|card:de_repl") == "",
		"合法参数不会被误标")
	_check(CardEffects.context_warning(CardEffects.REPLACE_CARDS, "play", "bogus|card:de_repl") != "",
		"非法区域会标红")
	_check(CardEffects.context_warning(CardEffects.DESTROY_DECK_CARDS, "play", "deck|cost:x") != "",
		"非法费用会标红")
	_check(CardEffects.context_warning(CardEffects.DESTROY_DECK_CARDS, "play", "deck|effect:no_such") != "",
		"未知效果筛选会标红")
	_check(CardEffects.context_warning(CardEffects.ADD_CARDS_TO_DECK, "play", "deck|pack:no_such") != "",
		"不存在的卡包会标红")

	var c := _card("de_validate", "测试·参数自检")
	c.effects = [{"id": CardEffects.REPLACE_CARDS, "token": "hand|bogus", "target": -1}]
	var errs: Array[String] = _db._chain_errors(c, c.effects, "战吼")
	_check(_has_text(errs, "无法识别"), "卡表自检报「替换来源无法识别」")


# ------------------------------ 管理员面板 ------------------------------

func _test_admin_ui() -> void:
	_admin._battlecry_editor.clear()
	_admin._battlecry_editor.add_row(CardEffects.REPLACE_CARDS, 2, -1, "hand|enemy_hand")
	var st: Dictionary = _admin._battlecry_editor.row_state(0)
	var token_edit: LineEdit = st["token_edit"]
	_check(token_edit.visible, "复合参数输入框可见")
	_check(token_edit.placeholder_text.contains("区域|目标"),
		"输入框提示为「区域|目标」（%s）" % token_edit.placeholder_text)
	var chain: Array[Dictionary] = _admin._battlecry_editor.chain()
	_check(chain.size() == 1 and str(chain[0].get("token", "")) == "hand|enemy_hand",
		"复合参数会写进效果链")

	var missing: String = _admin._validate_chain(
		[{"id": CardEffects.ADD_CARDS_TO_DECK, "token": "", "target": -1}], "测试", false)
	_check(missing.contains("区域|目标"), "面板自检拦下「没填参数」")
	var bad_zone: String = _admin._validate_chain(
		[{"id": CardEffects.ADD_CARDS_TO_DECK, "token": "hand|card:de_add", "target": -1}], "测试", false)
	_check(bad_zone.contains("无法识别"), "面板自检拦下「加牌用了手牌区域」")
	var ok: String = _admin._validate_chain(
		[{"id": CardEffects.ADD_CARDS_TO_DECK, "token": "deck|card:de_add", "target": -1}], "测试", false)
	_check(ok == "", "合法复合参数通过自检（%s）" % ok)


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


func _count_id(cards: Array, id: String) -> int:
	var n := 0
	for c in cards:
		if c != null and str(c.id) == id:
			n += 1
	return n


func _has_token_card(cards: Array) -> bool:
	for c in cards:
		if c != null and c.is_token:
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
	print("=== 替换 / 破坏 / 加入牌库测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
