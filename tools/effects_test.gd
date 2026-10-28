extends SceneTree
## 临时脚本：验证效果注册表（全部效果可执行、卡表引用的效果 ID 均合法、代表效果结果正确）。

var _fails := 0
var _logs: Array[String] = []
var _frames := 0
var hooks := false


func _process(_d: float) -> bool:
	_frames += 1
	if _frames == 5:
		_run()
		return true
	return false


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[OK]   " + msg)
	else:
		_fails += 1
		print("[FAIL] " + msg)


func _gm():
	return root.get_node_or_null("GameManager")


func _db():
	return root.get_node_or_null("CardDB")


func _run() -> void:
	if not hooks:
		_gm().log_message.connect(func(t: String) -> void: _logs.append(t))
		hooks = true

	_db().reset_to_default()
	_check(_db().cards.size() >= 50, "默认卡表加载：%d 张" % _db().cards.size())

	# ---- 1. 卡表引用的所有效果 ID 都必须在注册表中 ----
	var bad: Array[String] = []
	for c in _db().cards:
		if c.effect_id != "" and not CardEffects.has(c.effect_id):
			bad.append("%s:%s" % [c.id, c.effect_id])
		if c.deathrattle_id != "" and not CardEffects.has(c.deathrattle_id):
			bad.append("%s:%s" % [c.id, c.deathrattle_id])
	_check(bad.is_empty(), "卡表效果 ID 全部合法（非法：%s）" % ["无" if bad.is_empty() else ", ".join(bad)])

	# ---- 2. 每个效果都有卡面文本 ----
	var no_text: Array[String] = []
	for id in CardEffects.ids():
		if id == CardEffects.NONE:
			continue
		if CardEffects.text(id, 3) == "":
			no_text.append(id)
	_check(no_text.is_empty(), "所有效果都能生成卡面文本（缺失：%s）" % ["无" if no_text.is_empty() else ", ".join(no_text)])

	# ---- 3. 逐个执行所有效果 ----
	var ids := CardEffects.ids()
	_check(ids.size() >= 25, "效果注册表规模：%d 个效果" % ids.size())
	for id in ids:
		if id == CardEffects.NONE:
			continue
		_logs.clear()
		_apply_effect(id)
		var unknown := false
		for l in _logs:
			if l.contains("未知效果"):
				unknown = true
		_check(not unknown, "效果「%s」可执行且不报错" % CardEffects.display_name(id))

	# ---- 4. 代表效果的结果校验 ----
	_check(_probe("damage", "enemy_minion") == "damaged", "造成伤害：目标随从生命下降")
	_check(_probe("damage_hero", "enemy_hero") == "hero_damaged", "直伤打脸：敌方英雄生命下降")
	_check(_probe("aoe_enemy", "none") == "enemy_aoe", "群体伤害：所有敌方随从受伤")
	_check(_probe("destroy", "enemy_minion") == "killed", "消灭随从：目标生命归零")
	_check(_probe("heal", "ally_hero") == "healed", "治疗：英雄生命恢复")
	_check(_probe("draw", "none") == "drew", "抽牌：手牌数量增加")
	_check(_probe("enemy_draw", "none") == "enemy_drew", "迫使抽牌：对手手牌增加")
	_check(_probe("mana", "none") == "mana", "获得法力：法力增加")
	_check(_probe("mana_crystal", "none") == "crystal", "法力水晶：上限提升")
	_check(_probe("summon", "none") == "summoned", "召唤衍生物：战场上随从增加")
	_check(_probe("copy_ally", "ally_minion") == "summoned", "复制友方随从：战场上随从增加")
	_check(_probe("buff", "ally_minion") == "buffed", "强化：攻防提升")
	_check(_probe("buff_health", "ally_minion") == "hp_buffed", "强化生命：生命提升")
	_check(_probe("buff_all_ally", "none") == "ally_buffed", "群体强化：所有友方随从提升")
	_check(_probe("debuff", "enemy_minion") == "weakened", "削弱：敌方随从攻防下降")
	_check(_probe("freeze", "enemy_minion") == "frozen", "冻结：目标下回合无法攻击")
	_check(_probe("silence", "enemy_minion") == "silenced", "沉默：关键字与增益被移除")
	_check(_probe("grant_shield", "ally_minion") == "shielded", "赋予圣盾：目标获得圣盾")
	_check(_probe("grant_taunt", "ally_minion") == "taunt", "赋予嘲讽：目标获得嘲讽")
	_check(_probe("grant_charge", "ally_minion") == "charge", "赋予冲锋：目标获得冲锋")
	_check(_probe("return_hand", "enemy_minion") == "returned", "返回手牌：随从离场并回到手牌")
	_check(_probe("destroy_random", "none") == "random_killed", "随机消灭：敌方随从被消灭")
	_check(_probe("discard_enemy", "none") == "discarded", "迫使弃牌：对手手牌减少")

	# ---- 5. 通过真实出牌流程验证新效果 ----
	_check(_play("s013", "enemy_minion") == "frozen", "打出「冰封术」：敌方随从被冻结")
	_check(_play("s011", "ally_minion") == "buffed", "打出「力量祝福」：友方随从 +2/+2")
	_check(_play("s016", "enemy_minion") == "returned", "打出「时空回溯」：随从回到手牌")
	_check(_play("s007", "none") == "aoe", "打出「烈焰风暴」：敌方全体受伤")
	_check(_play("s009", "enemy_minion") == "killed", "打出「湮灭」：目标随从被消灭")
	_check(_play("s021", "none") == "aoe_all", "打出「雷霆风暴」：全场随从受伤")
	_check(_play("s014", "enemy_minion") == "silenced", "打出「净化」：目标随从被沉默")
	_check(_play("s023", "ally_minion") == "copied", "打出「镜像术」：复制友方随从")
	_check(_deathrattle_probe("c024") == "hero_hit", "亡语「自爆地精」：对敌方英雄造成伤害")
	_check(_deathrattle_probe("c025") == "token_summoned", "亡语「骷髅召唤者」：召唤衍生物")

	print("=== 效果系统测试结束：失败 %d 项 ===" % _fails)


## 把指定卡牌放进手牌并打出，返回观察到的现象
func _play(card_id: String, target_kind: String) -> String:
	_prepare()
	var gm = _gm()
	var me: PlayerState = gm.get_player(0)
	var card = _db().get_card(card_id)
	if card == null:
		return "missing"
	me.hand.append(card.clone())
	var idx: int = me.hand.size() - 1
	var t := _target_dict(target_kind)
	var ok: bool = gm.play_card(0, idx, int(t.get("unit_id", -1)), int(t.get("player_id", -1)))
	if not ok:
		return "rejected"

	var tu: BoardUnit = gm.find_unit(int(t.get("unit_id", -1))) if target_kind.contains("minion") else null
	match card_id:
		"s013":
			return "frozen" if (tu != null and tu.is_frozen(gm.turn_count + 1)) else ""
		"s011":
			return "buffed" if (tu != null and tu.attack >= tu.data.attack + 2) else ""
		"s016":
			return "returned" if gm.get_player(1).board.size() == 1 and gm.get_player(1).hand.size() > 0 else ""
		"s007":
			var hurt := 0
			for u in gm.get_player(1).board:
				if u.health < u.max_health or not u.is_alive():
					hurt += 1
			return "aoe" if hurt >= 1 else ""
		"s009":
			return "killed" if gm.get_player(1).board.size() == 1 else ""
		"s021":
			var hurt2 := 0
			for p in gm.players:
				for u in p.board:
					if u.health < u.max_health:
						hurt2 += 1
			return "aoe_all" if hurt2 >= 2 else ""
		"s014":
			return "silenced" if (tu != null and tu.keywords.is_empty()) else ""
		"s023":
			return "copied" if gm.get_player(0).board.size() == 3 else ""
	return ""


## 放置一张带亡语的随从并杀死它，返回亡语现象
func _deathrattle_probe(card_id: String) -> String:
	_prepare()
	var gm = _gm()
	var me: PlayerState = gm.get_player(0)
	var foe: PlayerState = gm.get_player(1)
	var before_foe_hp: int = foe.hero_hp
	var before_board: int = me.board.size()
	var u: BoardUnit = _spawn(0, card_id)
	u.health = 0
	gm._cleanup_deaths()
	if card_id == "c024":
		return "hero_hit" if foe.hero_hp < before_foe_hp else ""
	if card_id == "c025":
		return "token_summoned" if me.board.size() > before_board else ""
	return ""


# ------------------------------ 测试辅助 ------------------------------

func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card = _db().get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 90000 + randi() % 9999)
	u.attacks_used = 0
	_gm().get_player(pid).board.append(u)
	return u


func _prepare() -> void:
	var gm = _gm()
	gm.new_game()
	gm.log_enabled = false
	var me: PlayerState = gm.get_player(0)
	var foe: PlayerState = gm.get_player(1)
	me.max_mana = 6          ## 留出法力水晶增长空间（上限 10）
	me.mana = 10
	me.hero_hp = 20          ## 留出治疗空间
	foe.hero_hp = 25         ## 留出伤害空间
	_spawn(0, "c001")
	_spawn(0, "c001")
	_spawn(1, "c002")
	_spawn(1, "c001")


func _target_dict(kind: String) -> Dictionary:
	var gm = _gm()
	match kind:
		"enemy_minion":
			var u = gm.get_player(1).board[0]
			return {"kind": "unit", "unit_id": u.unit_id, "player_id": 1}
		"ally_minion":
			var a = gm.get_player(0).board[0]
			return {"kind": "unit", "unit_id": a.unit_id, "player_id": 0}
		"enemy_hero":
			return {"kind": "hero", "unit_id": -1, "player_id": 1}
		"ally_hero":
			return {"kind": "hero", "unit_id": -1, "player_id": 0}
		_:
			return {"kind": "self", "unit_id": -1, "player_id": 0}


func _apply_effect(id: String) -> void:
	_prepare()
	var ctx := EffectContext.create(_gm(), 0, 3, "t001", _target_dict("enemy_minion"), "测试卡")
	CardEffects.apply(id, ctx)
	_gm()._cleanup_deaths()


## 对指定效果执行一次，返回执行结果的“现象标识”
func _probe(id: String, target_kind: String) -> String:
	_prepare()
	var gm = _gm()
	var me: PlayerState = gm.get_player(0)
	var foe: PlayerState = gm.get_player(1)
	var before_hand: int = me.hand.size()
	var before_foe_hand: int = foe.hand.size()
	var before_board: int = me.board.size()
	var before_foe_board: int = foe.board.size()
	var before_hp: int = me.hero_hp
	var before_foe_hp: int = foe.hero_hp
	var before_mana: int = me.mana
	var before_max: int = me.max_mana

	var ctx := EffectContext.create(_gm(), 0, 3, "t001", _target_dict(target_kind), "测试卡")
	CardEffects.apply(id, ctx)
	gm._cleanup_deaths()

	var tu: BoardUnit = gm.find_unit(int(_target_dict(target_kind).get("unit_id", -1))) if target_kind.contains("minion") else null

	if id == "damage":
		return "damaged" if (tu != null and tu.health < tu.max_health) or foe.hero_hp < before_foe_hp else ""
	if id == "damage_hero":
		return "hero_damaged" if foe.hero_hp < before_foe_hp else ""
	if id == "aoe_enemy":
		var hurt := 0
		for u in foe.board:
			if u.health < u.max_health:
				hurt += 1
		return "enemy_aoe" if hurt >= 1 and me.board[0].health == me.board[0].max_health else ""
	if id == "destroy":
		return "killed" if foe.board.size() < before_foe_board else ""
	if id == "destroy_random":
		return "random_killed" if foe.board.size() < before_foe_board else ""
	if id == "heal":
		return "healed" if me.hero_hp > before_hp else ""
	if id == "draw":
		return "drew" if me.hand.size() > before_hand else ""
	if id == "enemy_draw":
		return "enemy_drew" if foe.hand.size() > before_foe_hand else ""
	if id == "discard_enemy":
		return "discarded" if foe.hand.size() < before_foe_hand else ""
	if id == "mana":
		return "mana" if me.mana > before_mana else ""
	if id == "mana_crystal":
		return "crystal" if me.max_mana > before_max else ""
	if id == "summon" or id == "copy_ally":
		return "summoned" if me.board.size() > before_board else ""
	if id == "buff":
		return "buffed" if (tu != null and tu.attack > 2) else ""
	if id == "buff_health":
		return "hp_buffed" if (tu != null and tu.max_health > 3) else ""
	if id == "buff_all_ally":
		var strong := 0
		for u in me.board:
			if u.attack > u.data.attack:
				strong += 1
		return "ally_buffed" if strong >= 2 else ""
	if id == "debuff":
		return "weakened" if (tu != null and tu.attack < tu.data.attack) or foe.board.size() < before_foe_board else ""
	if id == "freeze":
		return "frozen" if (tu != null and tu.is_frozen(gm.turn_count + 1)) else ""
	if id == "silence":
		return "silenced" if (tu != null and tu.keywords.is_empty()) else ""
	if id == "grant_shield":
		return "shielded" if (tu != null and tu.divine_shield) else ""
	if id == "grant_taunt":
		return "taunt" if (tu != null and tu.is_taunt()) else ""
	if id == "grant_charge":
		return "charge" if (tu != null and tu.has_keyword(CardData.Keyword.CHARGE)) else ""
	if id == "return_hand":
		return "returned" if foe.board.size() < before_foe_board and foe.hand.size() > before_foe_hand else ""
	return ""
