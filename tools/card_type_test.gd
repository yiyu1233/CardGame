extends SceneTree
## 卡牌四分类测试：随从 / 法术 / 护符 / 城邦。
##
## 规则：
##   * 随从：占一格、可攻击；
##   * 法术：结算后进墓地；
##   * 护符：占一格、不能攻击、有耐久，可被伤害 / 被指定解掉；
##   * 城邦：与护符同形，但**整副牌组合计最多 CardData.CITY_DECK_LIMIT 张**。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/card_type_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _db
var _gm
var _fail_lines: Array[String] = []
## 管理员真实卡组规则的快照（见 _normalize_rules）
var _rules_backup := {}


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
		_normalize_rules()
		_test_enum_and_table()
		_test_permanent_on_board()
		_test_permanent_killable()
		_test_city_deck_limit()
		_test_text_and_ui()
		_finish()
	return _frames > 400


# ------------------------------ 类型与卡表 ------------------------------

func _test_enum_and_table() -> void:
	_check(CardData.TYPE_NAMES.size() == 4, "卡牌分为 4 类（实际 %d）" % CardData.TYPE_NAMES.size())
	_check(CardData.TYPE_NAMES[0] == "随从" and CardData.TYPE_NAMES[1] == "法术"
		and CardData.TYPE_NAMES[2] == "护符" and CardData.TYPE_NAMES[3] == "城邦",
		"四类名称正确：%s" % str(CardData.TYPE_NAMES))
	_check(CardData.CardType.MINION == 0 and CardData.CardType.SPELL == 1
		and CardData.CardType.AMULET == 2 and CardData.CardType.CITY == 3, "四种类型的枚举值稳定（兼容旧卡表）")
	_check(CardData.CITY_DECK_LIMIT == 2, "城邦的牌组上限是 2 张")

	var amulet: CardData = _db.get_card("a001")
	var city: CardData = _db.get_card("y001")
	var minion: CardData = _db.get_card("c001")
	var spell: CardData = _db.get_card("s001")
	_check(amulet != null and amulet.is_permanent() and not amulet.is_city(), "护符示例卡存在且是护符")
	_check(city != null and city.is_city() and city.is_permanent(), "城邦示例卡存在且是城邦")
	_check(minion != null and minion.is_minion() and not minion.is_permanent(), "随从不是护符")
	_check(spell != null and not spell.is_board_card(), "法术不占战场格子")
	_check(amulet != null and amulet.is_board_card() and city.is_board_card(), "护符 / 城邦都要占战场格子")
	_check(amulet != null and amulet.durability() == amulet.health, "护符的耐久取卡表里的 health（%d）" % (0 if amulet == null else amulet.durability()))
	_check(amulet != null and amulet.type_name() == "护符" and city.type_name() == "城邦", "type_name() 正确")

	var counts := {"minion": 0, "spell": 0, "amulet": 0, "city": 0}
	for c in _db.cards:
		match c.card_type:
			CardData.CardType.MINION:
				counts["minion"] += 1
			CardData.CardType.SPELL:
				counts["spell"] += 1
			CardData.CardType.AMULET:
				counts["amulet"] += 1
			CardData.CardType.CITY:
				counts["city"] += 1
	_check(counts["amulet"] >= 3 and counts["city"] >= 2,
		"卡表里有示例护符 %d 张、城邦 %d 张" % [counts["amulet"], counts["city"]])
	_check(_db.city_card_count() == counts["city"], "city_card_count() 与卡表一致（%d）" % _db.city_card_count())


# ------------------------------ 护符 / 城邦 上场 ------------------------------

func _test_permanent_on_board() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	_check(me.deck.size() + me.hand.size() > 0, "牌库可用（%d 张）" % me.deck.size())
	var deck_cities: int = _db.deck_city_count(me.deck) + _db.deck_city_count(me.hand)
	_check(deck_cities == CardData.CITY_DECK_LIMIT,
		"整副牌组（牌库 + 起手）里城邦卡合计 %d 张（上限 %d）" % [deck_cities, CardData.CITY_DECK_LIMIT])

	# 安放护符
	me.mana = 10
	me.max_mana = 10
	me.board.clear()
	_give_hand(ME, "a001")
	var uid: BoardUnit = _gm.summon_unit(ME, _db.get_card("a001"))
	_check(uid != null, "护符可以安放到战场")
	if uid == null:
		return
	_check(me.board.has(uid), "护符占了一个战场格子（战场上 %d 个）" % me.board.size())
	_check(uid.is_permanent(), "战场上的护符被识别为护符 / 城邦")
	_check(uid.attack == 0, "护符攻击力为 0（实际 %d）" % uid.attack)
	_check(uid.health == _db.get_card("a001").durability(), "护符耐久来自卡表（%d）" % uid.health)
	_check(not uid.can_attack(_gm.turn_count, true), "护符不能攻击")
	_check(not uid.can_act() and not uid.can_use_active_skill(), "护符不能发动主动行为 / 主动技能")
	_check(_gm.get_valid_attack_targets(ME, uid.unit_id).is_empty(), "护符没有可攻击目标")

	# 城邦：一律进主战者旁的城邦格（不占 7 格战场）
	var used_before_city: int = _gm.board_size_used(ME)
	var city_unit: BoardUnit = _gm.summon_unit(ME, _db.get_card("y001"))
	_check(city_unit != null and city_unit.is_permanent() and not city_unit.can_attack(_gm.turn_count, true),
		"城邦也是不能攻击的场上卡")
	_check(city_unit != null and city_unit.in_city_slot, "城邦被召唤进城邦格（不是战场格子）")
	_check(city_unit != null and city_unit.health == _db.get_card("y001").durability(),
		"城邦耐久来自卡表（%d）" % (0 if city_unit == null else city_unit.health))
	_check(_gm.board_size_used(ME) == used_before_city, "城邦不占战场格子（占用 %d）" % _gm.board_size_used(ME))

	# 横置格只收随从：护符即使被要求横置上场（to_front）也不会进横置格
	# （summon_unit 的第 3 个参数现在是「放第几格」的 slot，横置改为走 play_card 的 to_front）
	_prepare()
	me = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	_give_hand(ME, "a001")
	_check(_gm.play_card(ME, 0, -1, -1, true), "护符照常上场（to_front 只对随从生效）")
	var u2: BoardUnit = _gm.board_slot(ME, 0)
	_check(u2 != null and not u2.in_front, "护符不会被放进横置格（横置格只收随从）")

	# 战场已满时打不出护符
	_prepare()
	me = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	for i in _gm.BOARD_LIMIT:
		_gm.summon_unit(ME, _db.get_card("c001"))
	_check(me.board.size() == _gm.BOARD_LIMIT, "战场已铺满 %d 个" % me.board.size())
	_give_hand(ME, "a001")
	_check(not _gm.can_play(ME, 0), "战场已满时护符也打不出")
	_check(_main_reason_like(ME) , "战场满时也能给出「战场已满」的原因文案")


# ------------------------------ 可被解掉 ------------------------------

func _test_permanent_killable() -> void:
	_prepare()
	_gm.current_player = FOE
	var amulet: BoardUnit = _gm.summon_unit(ME, _db.get_card("a002"))      # 守护结界 耐久 5
	_check(amulet != null, "护符上场成功")
	if amulet == null:
		return

	# 可以被敌方技能指定
	var spell: CardData = _db.get_card("s001")
	var targets: Array[Dictionary] = _gm.get_valid_targets(FOE, spell)
	var ids: Array[int] = []
	for t in targets:
		if str(t["kind"]) == "unit":
			ids.append(int(t["unit_id"]))
	_check(ids.has(amulet.unit_id), "敌方技能可以指定护符（%d 个可选目标）" % ids.size())

	# 可以被随从攻击
	var attacker: BoardUnit = _gm.summon_unit(FOE, _db.get_card("c011"))   # 巨型石魔 8/8
	if attacker != null:
		attacker.summoned_turn = -1
		attacker.attacks_used = 0
	var atk_targets: Array[Dictionary] = _gm.get_valid_attack_targets(FOE, attacker.unit_id)
	var atk_ids: Array[int] = []
	for t in atk_targets:
		atk_ids.append(int(t["unit_id"]))
	_check(atk_ids.has(amulet.unit_id), "敌方随从可以攻击护符")

	# 掉耐久：伤害照常结算（不是横置，所以吃满伤害）
	var before: int = amulet.health
	var dealt: int = _gm.deal_damage_to_unit(attacker, amulet, 8)
	_check(dealt == 8 and amulet.health == before - 8, "护符受到的伤害照常结算（%d -> %d）" % [before, amulet.health])
	_check(amulet.health <= 0, "耐久被打空")
	_gm._cleanup_deaths()
	_check(not _gm.get_player(ME).board.has(amulet), "耐久耗尽的护符被摧毁、离开战场")
	var in_grave := false
	for c in _gm.get_player(ME).graveyard:
		if c.id == "a002":
			in_grave = true
	_check(in_grave, "被摧毁的护符进入墓地")

	# 护符的“安放”效果在场上立即结算
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var hand_before: int = me.hand.size()
	var tower: BoardUnit = _gm.summon_unit(ME, _db.get_card("a001"))       # 魔法水晶塔：安放时抽 1 张
	_check(tower != null, "魔法水晶塔上场")
	_gm._resolve_effect(ME, _db.get_card("a001"), -1, -1, tower)
	_check(me.hand.size() == hand_before + 1, "护符的安放效果照常结算（手牌 %d -> %d）" % [hand_before, me.hand.size()])

	# 群体效果同时打到随从与护符
	_prepare()
	var unit: BoardUnit = _gm.summon_unit(ME, _db.get_card("c011"))
	var ward: BoardUnit = _gm.summon_unit(ME, _db.get_card("a002"))
	var unit_hp: int = unit.health
	var ward_hp: int = ward.health
	var ctx := EffectContext.create(_gm, FOE, 2, "", {"kind": "self", "unit_id": -1, "player_id": FOE}, "测试")
	CardEffects.apply("aoe_all", ctx)
	_check(unit.health == unit_hp - 2, "群体伤害对随从照常（%d -> %d）" % [unit_hp, unit.health])
	_check(ward.health == ward_hp - 2, "群体伤害对护符照常（%d -> %d）" % [ward_hp, ward.health])


# ------------------------------ 城邦的牌组上限 ------------------------------

func _test_city_deck_limit() -> void:
	var deck: Array[CardData] = _db.build_deck()
	var city_n: int = _db.deck_city_count(deck)
	_check(city_n == CardData.CITY_DECK_LIMIT,
		"build_deck() 里城邦卡合计 %d 张（上限 %d）" % [city_n, CardData.CITY_DECK_LIMIT])
	_check(city_n <= CardData.CITY_DECK_LIMIT, "城邦不超过上限")

	# 普通卡照旧每种 2 张
	var amulet_n := 0
	var minion_n := 0
	var spell_n := 0
	for c in deck:
		if c.is_city():
			continue
		match c.card_type:
			CardData.CardType.AMULET:
				amulet_n += 1
			CardData.CardType.MINION:
				minion_n += 1
			CardData.CardType.SPELL:
				spell_n += 1
	_check(amulet_n == _collectible_count(CardData.CardType.AMULET) * _db.COPIES_PER_CARD,
		"护符仍按每种 %d 张入牌库（%d 张）" % [_db.COPIES_PER_CARD, amulet_n])
	_check(minion_n > 0 and spell_n > 0, "随从与法术照常入牌库（随从 %d / 法术 %d）" % [minion_n, spell_n])
	_check(deck.size() == minion_n + spell_n + amulet_n + city_n, "牌库总数 = 各类之和（%d）" % deck.size())
	var token_in_deck := 0
	for c in deck:
		if c.is_token:
			token_in_deck += 1
	_check(token_in_deck == 0, "牌库里没有衍生物（%d）" % token_in_deck)

	# 人为塞进更多城邦卡：牌库里的城邦仍然只有上限那么多
	var backup: Array[CardData] = _db.cards.duplicate()
	var city_kinds_before: int = _db.city_card_count()
	var extra: CardData = _db.get_card("y001").clone()
	extra.id = "y999"
	extra.card_name = "测试城邦"
	extra.card_type = CardData.CardType.CITY
	_db.cards.append(extra)
	_db._index["y999"] = extra
	var deck2: Array[CardData] = _db.build_deck()
	_check(_db.deck_city_count(deck2) == CardData.CITY_DECK_LIMIT,
		"多塞城邦卡后牌库仍只带上限张数（%d）" % _db.deck_city_count(deck2))
	_check(_db.city_card_count() == city_kinds_before + 1,
		"city_card_count() 统计的是卡表里的城邦种类（%d -> %d）" % [city_kinds_before, _db.city_card_count()])
	# 复原
	_db.cards.clear()
	for c in backup:
		_db.cards.append(c)
	_db._index.erase("y999")
	_db.rebuild_index()
	_check(_db.get_card("y999") == null and _db.deck_city_count(_db.build_deck()) == CardData.CITY_DECK_LIMIT,
		"恢复卡表后一切正常")


# ------------------------------ 文本与界面 ------------------------------

func _test_text_and_ui() -> void:
	var amulet: CardData = _db.get_card("a001")
	var city: CardData = _db.get_card("y001")
	var amulet_text := "|".join(amulet.summary_lines())
	var city_text := "|".join(city.summary_lines())
	_check(amulet_text.contains("耐久"), "护符卡面文本显示耐久：%s" % amulet_text)
	_check(amulet_text.contains("安放"), "护符的效果前缀是「安放」：%s" % amulet_text)
	_check(city_text.contains("每套牌组最多 %d 张" % CardData.CITY_DECK_LIMIT),
		"城邦卡面写明牌组上限：%s" % city_text)
	_check(not city_text.contains("城邦：") or city_text.contains("城邦：每套牌组最多"),
		"城邦的提示文字正确")

	# 卡面控件：护符显示耐久、不显示攻/血
	var ui = load("res://scenes/Card.tscn").instantiate()
	root.add_child(ui)
	ui.setup(amulet, 0, true)
	_check(ui.type_label.text == "护符", "卡面类型标签显示「护符」（%s）" % ui.type_label.text)
	_check(ui.stats_label.visible and ui.stats_label.text.contains("耐久"),
		"卡面数值区显示耐久（%s）" % ui.stats_label.text)
	ui.queue_free()

	var ui2 = load("res://scenes/Card.tscn").instantiate()
	root.add_child(ui2)
	ui2.setup(city, 0, true)
	_check(ui2.type_label.text == "城邦", "卡面类型标签显示「城邦」（%s）" % ui2.type_label.text)
	ui2.queue_free()


# ------------------------------ 测试辅助 ------------------------------

## 把卡组规则临时调成「不会因为张数上限而被裁牌」：
## 管理员可能把规则设成「最多 50 张 + 同名 3 张」，而全卡池自然生成 233 张，
## 多出来的会被从尾部裁掉（城邦 / 护符全被截掉），那样本测试根本无法验证
## 「四类卡都能进牌库 + 城邦有合计上限」。这里只改内存不落盘，结束在 _finish() 还原。
func _normalize_rules() -> void:
	_rules_backup = {"min": _db.deck_min, "max": _db.deck_max, "copies": _db.max_copies}
	_db.deck_min = 30
	_db.deck_max = 1000
	_db.max_copies = 2


func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.board.clear()
	_gm.get_player(FOE).board.clear()


func _give_hand(pid: int, card_id: String) -> void:
	var p: PlayerState = _gm.get_player(pid)
	p.hand.clear()
	p.hand.append(_db.get_card(card_id).clone())


func _collectible_count(t: int) -> int:
	var n := 0
	for c in _db.cards:
		if c.card_type == t and not c.is_token:
			n += 1
	return n


## 「战场已满」时的出牌口径：战场满 + 手牌是护符 ⇒ can_play 为假
func _main_reason_like(pid: int) -> bool:
	var p: PlayerState = _gm.get_player(pid)
	return p.board.size() >= _gm.BOARD_LIMIT and not _gm.can_play(pid, 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if _db != null and not _rules_backup.is_empty():
		_db.deck_min = int(_rules_backup.get("min", 30))
		_db.deck_max = int(_rules_backup.get("max", 200))
		_db.max_copies = int(_rules_backup.get("copies", 2))
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 卡牌分类测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
