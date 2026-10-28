extends SceneTree
## 新机制测试（炉石 / 影之诗来源；MTG 相关词条已按要求删除）：
##   复生（炉石）/ 过载（炉石）/ 倒计时（影之诗护符）/ 连击（炉石）
##
## 运行：godot --headless --path <项目目录> --script res://tools/mechanics3_test.gd

const ME := 0
const FOE := 1
const REBORN := CardData.Keyword.REBORN

var _fails := 0
var _frames := 0
var _gm
var _db
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
		_test_registry()
		_test_table()
		_test_reborn()
		_test_overload()
		_test_countdown()
		_test_combo()
		_test_mtg_removed()
		_finish()
	return _frames > 400


# ------------------------------ 注册表与卡表 ------------------------------

func _test_registry() -> void:
	_check(Mechanics.has(REBORN) and Mechanics.describe(REBORN) != "",
		"复生已注册（%s）" % Mechanics.describe(REBORN))
	_check(Mechanics.keywords().size() == CardData.all_keyword_ids().size(),
		"注册表与关键字表一致（%d / %d）" % [Mechanics.keywords().size(), CardData.all_keyword_ids().size()])


func _test_table() -> void:
	var bone: CardData = _db.get_card("f006")
	_check(bone != null and bone.keyword_names().has("复生"), "卡表 f006 带「复生」关键字")
	var over: CardData = _db.get_card("f007")
	_check(over != null and over.overload == 2, "f007 过载 2 正确读取（%d）" % (0 if over == null else over.overload))
	var cd: CardData = _db.get_card("a004")
	_check(cd != null and cd.countdown == 3 and cd.is_permanent(),
		"a004 是带倒计时 3 的护符（%s）" % ("无" if cd == null else "%d / %s" % [cd.countdown, cd.type_name()]))
	var combo: CardData = _db.get_card("s102")
	_check(combo != null and combo.combo_effect_id != CardData.NO_EFFECT and combo.combo_value == 2,
		"s020 带连击效果（%s / %d）" % ["无" if combo == null else combo.combo_effect_id, 0 if combo == null else combo.combo_value])
	if cd != null and combo != null:
		var back: CardData = CardData.from_dict(combo.to_dict())
		_check(back.combo_effect_id == combo.combo_effect_id and back.combo_value == combo.combo_value,
			"连击字段可以 JSON 往返")
		_check(CardData.from_dict(cd.to_dict()).countdown == cd.countdown, "倒计时字段可以 JSON 往返")


# ------------------------------ 复生 ------------------------------

func _test_reborn() -> void:
	_prepare()
	var bone: BoardUnit = _spawn(ME, "f006")
	_check(bone.has_mechanic(REBORN), "不灭骸骨带复生")
	_gm.deal_damage_to_unit(null, bone, 9)
	_gm._cleanup_deaths()
	var revived: BoardUnit = null
	for u in _gm.get_player(ME).board:
		if u.data.id == "f006":
			revived = u
	_check(revived != null, "第一次死亡后复生回到战场")
	_check(revived != null and revived.health == 1, "复生时只有 1 点生命（%d）" % (0 if revived == null else revived.health))
	_check(revived != null and revived.reborn_used, "复生标记已用掉")
	if revived != null:
		_gm.deal_damage_to_unit(null, revived, 9)
		_gm._cleanup_deaths()
	var still := false
	for u in _gm.get_player(ME).board:
		if u.data.id == "f006":
			still = true
	_check(not still, "第二次死亡不再复生")
	var in_grave := false
	for c in _gm.get_player(ME).graveyard:
		if c.id == "f006":
			in_grave = true
	_check(in_grave, "复生后再次死亡正常进墓地")


# ------------------------------ 过载 ------------------------------

func _test_overload() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	me.hand.clear()
	me.hand.append(_db.get_card("f007"))
	_check(_gm.play_card(ME, 0), "打出带过载的随从")
	_check(me.overload == 2, "打出后累积 2 点过载（%d）" % me.overload)
	_gm._start_turn(ME)
	_check(me.overload == 0, "结算后过载清零（%d）" % me.overload)
	_check(me.mana == me.max_mana - 2, "下回合可用法力被扣 2（%d/%d）" % [me.mana, me.max_mana])


# ------------------------------ 倒计时 ------------------------------

func _test_countdown() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	me.hand.clear()
	me.hand.append(_db.get_card("a004"))
	me.mana = 10
	me.max_mana = 10
	_check(_gm.play_card(ME, 0), "安放带倒计时的护符")
	var shard: BoardUnit = null
	for u in me.board:
		if u.data.id == "a004":
			shard = u
	_check(shard != null and shard.countdown == 3, "倒计时初值 3（%d）" % (0 if shard == null else shard.countdown))
	_gm._start_turn(ME)
	_check(shard != null and shard.countdown == 2, "第一个回合开始后 -1（%d）" % (0 if shard == null else shard.countdown))
	_gm._start_turn(ME)
	_check(shard != null and shard.countdown == 1, "第二个回合开始后 -1（%d）" % (0 if shard == null else shard.countdown))
	_gm._start_turn(ME)
	var gone := true
	for u in me.board:
		if u.data.id == "a004":
			gone = false
	_check(gone, "倒计时归零后被摧毁、离开战场")
	var in_grave := false
	for c in me.graveyard:
		if c.id == "a004":
			in_grave = true
	_check(in_grave, "被摧毁的护符进入墓地")


# ------------------------------ 连击 ------------------------------

func _test_combo() -> void:
	# 场景一：本回合第一张牌 → 不触发连击
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	me.cards_played_turn = 0
	me.hand.clear()
	me.hand.append(_db.get_card("s102"))              # 影袭：抽 1，连击打脸 2
	var foe_hp: int = _gm.get_player(FOE).hero_hp
	_check(_gm.play_card(ME, 0), "打出「影袭」")
	_check(_gm.get_player(FOE).hero_hp == foe_hp, "本回合第一张牌不触发连击（敌方英雄 %d）" % _gm.get_player(FOE).hero_hp)
	# 场景二：本回合已经出过牌 → 触发连击
	_prepare()
	me = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	me.cards_played_turn = 1                          # 已经打过一张
	me.hand.clear()
	me.hand.append(_db.get_card("s102"))
	foe_hp = _gm.get_player(FOE).hero_hp
	_check(_gm.play_card(ME, 0), "本回合第二张牌再次打出「影袭」")
	_check(_gm.get_player(FOE).hero_hp == foe_hp - 2,
		"连击触发：额外 2 点伤害（%d -> %d，期望 -2）" % [foe_hp, _gm.get_player(FOE).hero_hp])
	var before_turn: int = _gm.turn_count
	_gm._start_turn(ME)
	_check(_gm.turn_count > before_turn and me.cards_played_turn == 0,
		"新回合开始后「本回合已出牌数」清零（%d）" % me.cards_played_turn)


# ------------------------------ MTG 词条已删除 ------------------------------

func _test_mtg_removed() -> void:
	for name in ["飞行", "先攻", "践踏", "警戒", "辟邪"]:
		var found := false
		for k in Mechanics.keywords():
			if Mechanics.display_name(k) == name:
				found = true
		_check(not found, "MTG 词条「%s」已删除" % name)
	for key in ["flying", "first_strike", "trample", "vigilance", "hexproof"]:
		_check(CardData.keywords_from_names([key]).is_empty(), "卡表 key「%s」不再能解析出机制" % key)
	for id in ["f001", "f002", "f003", "f004", "f005"]:
		_check(_db.get_card(id) == null, "MTG 示例卡 %s 已从卡表移除" % id)


# ------------------------------ 辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.board.clear()
	me.hand.clear()
	me.graveyard.clear()
	me.overload = 0
	me.cards_played_turn = 0
	var foe: PlayerState = _gm.get_player(FOE)
	foe.board.clear()
	foe.hand.clear()
	_gm.current_player = ME
	_gm.busy = false


func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 90000 + randi() % 9000)
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
	print("=== 新机制测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
