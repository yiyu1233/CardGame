extends SceneTree
## 机制系统测试：验证「机制注册表 + 钩子」这套地基可用、可扩展，且吸血 / 剧毒 / 潜行行为正确。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/mechanics_test.gd
##
## 覆盖内容：
##   1. 机制注册表完整性（每个关键字都有名称与说明）与钩子查询
##   2. 卡表能用关键字 key 声明机制（JSON ↔ 枚举 往返）
##   3. 吸血：攻击随从 / 打脸 / 被圣盾挡下 / 治疗上限 / 由卡牌效果赋予
##   4. 剧毒：击杀大随从 / 被圣盾挡下不触发 / 打脸不杀英雄
##   5. 潜行：不能被指定为目标、不能被攻击、仍会被随机与群体效果命中、攻击后解除
##   6. 扩展性：未知钩子 / 未知机制 / 无机制随从都不会出错

const ME := 0
const FOE := 1

const LIFESTEAL_CARD := "c027"   ## 血族伯爵 3/4 吸血
const POISON_CARD := "c028"      ## 毒蛇刺客 2/2 剧毒
const STEALTH_CARD := "c029"     ## 夜刃刺客 3/2 潜行
const SHIELD_CARD := "c007"      ## 白银护卫 2/3 圣盾
const BIG_CARD := "c011"         ## 巨型石魔 8/8 嘲讽
const PLAIN_CARD := "c014"       ## 暗影刺客 4/2

var _fails := 0
var _frames := 0
var _db
var _gm
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
		_run()
		_finish()
	return _frames > 300


func _run() -> void:
	_test_registry()
	_test_card_data_wiring()
	_test_lifesteal()
	_test_poisonous()
	_test_stealth()
	_test_extensibility()
	_test_default_cards_playable()


# ------------------------------ 注册表 ------------------------------

func _test_registry() -> void:
	var all: Array[int] = [
		CardData.Keyword.TAUNT, CardData.Keyword.CHARGE, CardData.Keyword.RUSH,
		CardData.Keyword.DIVINE_SHIELD, CardData.Keyword.WINDFURY,
		CardData.Keyword.LIFESTEAL, CardData.Keyword.POISONOUS, CardData.Keyword.STEALTH,
	]
	# 以后再加机制：这里跟着 Keyword 枚举补齐即可（断言不再写死数量）
	_check(Mechanics.keywords().size() == CardData.all_keyword_ids().size(),
		"机制注册表收录全部 %d 个关键字（实际 %d）" % [CardData.all_keyword_ids().size(), Mechanics.keywords().size()])
	var missing: Array[String] = []
	for k in all:
		if not Mechanics.has(k) or Mechanics.display_name(k) == "" or Mechanics.describe(k) == "":
			missing.append(str(k))
	_check(missing.is_empty(), "每个机制都有名称与说明（缺失：%s）" % ["无" if missing.is_empty() else ", ".join(missing)])

	# 钩子是机制的唯一入口：有行为的机制必须有对应钩子
	_check(Mechanics.has_hook(CardData.Keyword.LIFESTEAL, "on_damage_dealt"),
		"吸血注册了 on_damage_dealt 钩子")
	_check(Mechanics.has_hook(CardData.Keyword.POISONOUS, "on_damage_dealt"),
		"剧毒注册了 on_damage_dealt 钩子")
	_check(Mechanics.has_hook(CardData.Keyword.STEALTH, "can_be_targeted")
		or Mechanics.has_flag(CardData.Keyword.STEALTH, Mechanics.FLAG_UNTRACKABLE),
		"潜行注册了 can_be_targeted 钩子")
	_check(Mechanics.has_hook(CardData.Keyword.STEALTH, "on_attack"),
		"潜行注册了 on_attack 钩子")
	_check(not Mechanics.has_hook(CardData.Keyword.TAUNT, "on_damage_dealt"),
		"嘲讽没有注册伤害钩子（自身状态类机制不需要钩子）")


func _test_card_data_wiring() -> void:
	# JSON 里写 key（如 "lifesteal"）→ 加载后应变成对应枚举
	var card := CardData.from_dict({"id": "t_mech", "card_name": "机制测试卡",
		"keywords": ["lifesteal", "poisonous", "stealth"]})
	_check(card.has_mechanic(CardData.Keyword.LIFESTEAL)
		and card.has_mechanic(CardData.Keyword.POISONOUS)
		and card.has_mechanic(CardData.Keyword.STEALTH),
		"卡牌可以用关键字 key 声明机制（吸血 / 剧毒 / 潜行）")
	_check(card.keyword_names().size() == 3, "机制名称可读（%s）" % " ".join(card.keyword_names()))

	# 卡表里的机制卡确实带上了对应机制
	for pair in [["c027", "lifesteal"], ["c028", "poisonous"], ["c029", "stealth"]]:
		var c: CardData = _db.get_card(pair[0])
		var want := _keyword_of(pair[1])
		_check(c != null and c != null and c.keyword_names().size() > 0
			and Mechanics.display_name(want) in c.keyword_names(),
			"默认卡表 %s 携带机制「%s」" % [pair[0], pair[1]])


func _keyword_of(key: String) -> int:
	for k in CardData.KEYWORD_KEYS:
		if CardData.KEYWORD_KEYS[k] == key:
			return k
	return 0


# ------------------------------ 吸血 ------------------------------

func _test_lifesteal() -> void:
	# 攻击随从：按造成的伤害回血
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	var wolf := _spawn(ME, LIFESTEAL_CARD)      # 3/4 吸血
	var victim := _spawn(FOE, BIG_CARD)         # 8/8 嘲讽
	me.hero_hp = 20
	_check(_gm.attack(ME, wolf.unit_id, victim.unit_id, FOE), "吸血随从攻击随从")
	_check(me.hero_hp == 23, "吸血按造成的伤害回血（20 -> %d，期望 23）" % me.hero_hp)

	# 打脸：按实际掉血回血
	_prepare()
	me = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	var wolf2 := _spawn(ME, LIFESTEAL_CARD)
	me.hero_hp = 20
	foe.hero_hp = 30
	_check(_gm.attack(ME, wolf2.unit_id, -1, FOE), "吸血随从攻击英雄")
	_check(me.hero_hp == 23 and foe.hero_hp == 27,
		"打脸同样吸血（我方 %d / 敌方 %d，期望 23 / 27）" % [me.hero_hp, foe.hero_hp])

	# 被圣盾挡下：没造成伤害就不回血
	_prepare()
	me = _gm.get_player(ME)
	var wolf3 := _spawn(ME, LIFESTEAL_CARD)
	var shielded := _spawn(FOE, SHIELD_CARD)
	me.hero_hp = 20
	_gm.attack(ME, wolf3.unit_id, shielded.unit_id, FOE)
	_check(me.hero_hp == 20, "伤害被圣盾挡下时不回血（%d，期望 20）" % me.hero_hp)

	# 治疗不超过上限
	_prepare()
	me = _gm.get_player(ME)
	var wolf4 := _spawn(ME, LIFESTEAL_CARD)
	_spawn(FOE, BIG_CARD)
	me.hero_hp = me.hero_max_hp - 1
	_gm.attack(ME, wolf4.unit_id, _gm.get_player(FOE).board[0].unit_id, FOE)
	_check(me.hero_hp == me.hero_max_hp, "吸血不会超过英雄生命上限（%d）" % me.hero_hp)

	# 护甲吸收的部分不算伤害 → 不吸血
	_prepare()
	me = _gm.get_player(ME)
	var foe2: PlayerState = _gm.get_player(FOE)
	var wolf5 := _spawn(ME, LIFESTEAL_CARD)
	me.hero_hp = 20
	foe2.armor = 5
	_gm.attack(ME, wolf5.unit_id, -1, FOE)
	_check(me.hero_hp == 20 and foe2.hero_hp == 30,
		"打护甲不回血（护甲吸收 %d，我方 %d）" % [foe2.armor, me.hero_hp])

	# 由卡牌效果赋予吸血：s029「血之契约」给友方随从吸血
	_prepare()
	me = _gm.get_player(ME)
	var plain := _spawn(ME, PLAIN_CARD)
	_check(not plain.has_mechanic(CardData.Keyword.LIFESTEAL), "普通随从初始没有吸血")
	_play_card(ME, "s029", plain.unit_id, ME)
	_check(plain.has_mechanic(CardData.Keyword.LIFESTEAL), "打出血之契约后获得吸血")


# ------------------------------ 剧毒 ------------------------------

func _test_poisonous() -> void:
	# 击杀本打不过的大随从
	_prepare()
	var poison := _spawn(ME, POISON_CARD)      # 2/2 剧毒
	var big := _spawn(FOE, BIG_CARD)           # 8/8
	_check(_gm.attack(ME, poison.unit_id, big.unit_id, FOE), "剧毒随从攻击大随从")
	_check(_gm.get_player(FOE).board.is_empty(), "剧毒直接消灭被伤害的随从（敌方战场剩 %d）" % _gm.get_player(FOE).board.size())

	# 被圣盾挡下 → 没有造成伤害 → 不触发剧毒
	_prepare()
	var poison2 := _spawn(ME, POISON_CARD)
	var shielded := _spawn(FOE, SHIELD_CARD)
	_gm.attack(ME, poison2.unit_id, shielded.unit_id, FOE)
	_check(not _gm.get_player(FOE).board.is_empty(), "圣盾挡下时剧毒不触发")

	# 打脸不会“消灭英雄”，只是普通伤害
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var poison3 := _spawn(ME, POISON_CARD)
	_gm.attack(ME, poison3.unit_id, -1, FOE)
	_check(_gm.game_active() and foe.hero_hp == 28, "剧毒打脸只造成伤害、不消灭英雄（敌方生命 %d）" % foe.hero_hp)

	# 效果赋予剧毒（s030 淬毒之刃）
	_prepare()
	var plain := _spawn(ME, PLAIN_CARD)
	_play_card(ME, "s030", plain.unit_id, ME)
	_check(plain.has_mechanic(CardData.Keyword.POISONOUS), "打出淬毒之刃后获得剧毒")
	var fat := _spawn(FOE, BIG_CARD)
	_gm.attack(ME, plain.unit_id, fat.unit_id, FOE)
	_check(_gm.get_player(FOE).board.is_empty(), "被赋予剧毒的随从同样能一击必杀")


# ------------------------------ 潜行 ------------------------------

func _test_stealth() -> void:
	_prepare()
	var sneak := _spawn(FOE, STEALTH_CARD)     # 敌方 3/2 潜行
	_check(sneak.has_mechanic(CardData.Keyword.STEALTH), "潜行随从带潜行机制")

	# 1) 不能被敌方指定为目标（单体法术）
	var spell: CardData = _db.get_card("s001")   # 火焰冲击 3 点任意目标
	var found := false
	for t in _gm.get_valid_targets(ME, spell):
		if int(t["unit_id"]) == sneak.unit_id:
			found = true
	_check(not found, "潜行的敌方随从不能被指定为目标")

	# 2) 也不能被攻击
	var attacker := _spawn(ME, PLAIN_CARD)
	attacker.summoned_turn = -1
	var attackable := false
	for t in _gm.get_valid_attack_targets(ME, attacker.unit_id):
		if int(t["unit_id"]) == sneak.unit_id:
			attackable = true
	_check(not attackable, "潜行的敌方随从不能被攻击")

	# 3) 但群体 / 随机效果仍然命中（与主流卡牌游戏一致）
	var hp_before: int = sneak.health
	var ctx := EffectContext.create(_gm, ME, 2, "", {"kind": "self", "unit_id": -1, "player_id": ME}, "测试")
	CardEffects.apply("aoe_all", ctx)
	_gm._cleanup_deaths()
	_check(sneak.health < hp_before, "群体效果仍然命中潜行随从（%d -> %d）" % [hp_before, sneak.health])

	# 4) 我方自己的潜行随从可以被我方指定为目标
	_prepare()
	var mine := _spawn(ME, STEALTH_CARD)
	var buff: CardData = _db.get_card("s011")    # 力量祝福：友方随从 +2/+2
	var own_found := false
	for t in _gm.get_valid_targets(ME, buff):
		if int(t["unit_id"]) == mine.unit_id:
			own_found = true
	_check(own_found, "我方潜行随从仍可被我方指定为目标")

	# 5) 攻击后解除潜行
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	var mine2 := _spawn(ME, STEALTH_CARD)
	mine2.summoned_turn = -1
	_gm.attack(ME, mine2.unit_id, -1, FOE)
	_check(not mine2.has_mechanic(CardData.Keyword.STEALTH), "潜行随从攻击后解除潜行")

	# 6) 解除后就能被指定 / 被攻击了
	var spell2: CardData = _db.get_card("s001")
	var targetable_again := false
	for t in _gm.get_valid_targets(FOE, spell2):
		if int(t["unit_id"]) == mine2.unit_id:
			targetable_again = true
	_check(targetable_again, "解除潜行后可以被敌方指定为目标")


# ------------------------------ 扩展性 ------------------------------

func _test_extensibility() -> void:
	var unit := _spawn(ME, PLAIN_CARD)

	# 未知钩子：应被静默忽略，且不影响事件字典（前向兼容，新增钩子不会让老机制报错）
	var ev := {"amount": 3, "allowed": true}
	var out := Mechanics.dispatch(unit, "no_such_hook", ev)
	_check(out.get("amount") == 3 and out.get("allowed") == true, "未知钩子被安全忽略")

	# 未知机制 ID：不崩溃
	Mechanics.call_hook(999, "on_damage_dealt", ev)
	_check(true, "未知机制 ID 不崩溃")

	# 无机制随从：派发与查询都安全
	var empty := BoardUnit.new()
	empty.setup(_db.get_card(PLAIN_CARD).clone(), ME, -1, 777001)
	Mechanics.dispatch(empty, "on_damage_dealt", ev)
	_check(Mechanics.can_be_targeted(empty, FOE), "无机制随从默认可被指定为目标")
	_check(not Mechanics.can_be_targeted(null, FOE), "空目标返回不可指定（不会崩）")

	# silence 会清掉机制（潜行 / 吸血都应消失）
	_prepare()
	var sneak := _spawn(ME, STEALTH_CARD)
	sneak.silence()
	_check(not sneak.has_mechanic(CardData.Keyword.STEALTH), "沉默会移除机制（潜行消失）")


func _test_default_cards_playable() -> void:
	# 三张机制卡都能正常打出（走完整 play_card 流程）
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	_check(_play_card(ME, LIFESTEAL_CARD, -1, -1), "打出吸血随从「血族伯爵」")
	var wolf: BoardUnit = me.board[me.board.size() - 1]
	_check(wolf.has_mechanic(CardData.Keyword.LIFESTEAL), "上场后带吸血机制")

	_check(_play_card(ME, POISON_CARD, -1, -1), "打出剧毒随从「毒蛇刺客」")
	var poison: BoardUnit = me.board[me.board.size() - 1]
	_check(poison.has_mechanic(CardData.Keyword.POISONOUS), "上场后带剧毒机制")

	_check(_play_card(ME, STEALTH_CARD, -1, -1), "打出潜行随从「夜刃刺客」")
	var sneak: BoardUnit = me.board[me.board.size() - 1]
	_check(sneak.has_mechanic(CardData.Keyword.STEALTH), "上场后带潜行机制")

	# 管理员面板的关键字复选框是按 KEYWORD_NAMES 自动生成的，新机制会自动出现
	_check(CardData.all_keyword_ids().size() == Mechanics.keywords().size(),
		"管理员面板会自动列出全部 %d 个机制复选框" % CardData.all_keyword_ids().size())

	# 存档优先于内置卡表：删掉一张后应能被“缺卡提示”发现（用于提醒玩家启用新卡）
	var probe: CardData = _db.get_card(LIFESTEAL_CARD)
	_db.remove_card(LIFESTEAL_CARD)
	_check(_db.missing_builtin_ids().has(LIFESTEAL_CARD),
		"删掉内置卡后能被「内置卡表缺卡」检测发现")
	_db.add_card(probe)
	_check(not _db.missing_builtin_ids().has(LIFESTEAL_CARD), "加回来后缺卡提示消失")


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> void:
	# 只重置对局，不预铺随从：很多用例要“打脸”或指定具体目标，
	# 起手放个嘲讽随从会把它们全部挡掉。
	_gm.new_game()
	_gm.log_enabled = false
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 6
	me.mana = 10
	me.board.clear()
	_gm.get_player(FOE).board.clear()


func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 80000 + randi() % 9000)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


func _play_card(pid: int, card_id: String, unit_id: int, player_id: int) -> bool:
	var card: CardData = _db.get_card(card_id)
	if card == null:
		return false
	var p: PlayerState = _gm.get_player(pid)
	p.mana = 10
	p.hand.append(card.clone())
	return _gm.play_card(pid, p.hand.size() - 1, unit_id, player_id)


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
	print("=== 机制系统测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
