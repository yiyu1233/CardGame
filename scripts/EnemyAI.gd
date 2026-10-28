class_name EnemyAI
extends RefCounted
## 敌方（AI）托管玩家：按启发式规则出牌与攻击。
## 通过动态调用 GameManager 的接口，避免脚本之间产生编译顺序依赖。

const STEP_DELAY := 0.45

var _gm                 ## GameManager（动态类型）
var _my_id: int = 1
var _running := false


func _init(gm, my_id: int) -> void:
	_gm = gm
	_my_id = my_id


func take_turn() -> void:
	if _running:
		return
	_running = true
	await _wait(STEP_DELAY)
	if not _my_turn():
		_running = false
		return

	var guard := 0
	while guard < 20:
		guard += 1
		if not _my_turn():
			break
		if _try_play():
			await _wait(STEP_DELAY)
		else:
			break

	# 出牌之后：如果有残血随从，把它横置进中线前的格子躲一手伤害
	if _my_turn() and _try_use_front_slot():
		await _wait(STEP_DELAY)

	guard = 0
	while guard < 30:
		guard += 1
		if not _my_turn():
			break
		if _try_attack():
			await _wait(STEP_DELAY)
		else:
			break

	if _my_turn():
		await _wait(STEP_DELAY * 0.8)
		_gm.finish_ai_turn()
	_running = false


func _my_turn() -> bool:
	return _gm.game_active() and _gm.current_player == _my_id


# ------------------------------ 出牌 ------------------------------

func _try_play() -> bool:
	var me = _gm.get_player(_my_id)
	if me == null:
		return false

	var best_index := -1
	var best_score := -1.0
	for i in me.hand.size():
		var card = me.hand[i]
		if not _gm.can_play(_my_id, i):
			continue
		# 法术没有合法目标打不出；随从 / 护符 / 城邦的战吼可以空放，照样能上场
		if card.needs_target() and not card.is_board_card() and _gm.get_valid_targets(_my_id, card).is_empty():
			continue
		var score := _card_score(card)
		if score > best_score:
			best_score = score
			best_index = i
	if best_index < 0:
		return false

	var card = me.hand[best_index]
	var unit_id := -1
	var player_id := -1
	if card.needs_target():
		var chosen = _pick_spell_target(card)
		if chosen == null:
			# 随从 / 护符 / 城邦没有合法目标时照样上场，战吼空放
			if not card.is_board_card():
				return false
		else:
			unit_id = int(chosen["unit_id"])
			player_id = int(chosen["player_id"])
	# 横置格：不需要目标的随从，如果它比较脆（容易被解掉）就横置进去吃 1 点伤害
	var to_front: bool = (card.is_minion()
		and not card.needs_target()
		and not _gm.has_front_unit(_my_id)
		and _should_place_in_front(card))
	return _gm.play_card(_my_id, best_index, unit_id, player_id, to_front)


## 是否值得把一个随从横置进格子：血少、没有冲锋/突袭（进去本来也不能攻击）时才划算
func _should_place_in_front(card) -> bool:
	if card.health > 3:
		return false
	if card.has_mechanic(CardData.Keyword.CHARGE) or card.has_mechanic(CardData.Keyword.RUSH):
		return false
	return true


## 把自己场上一个残血随从横置进格子躲伤害（每次行动最多一次）
func _try_use_front_slot() -> bool:
	var me = _gm.get_player(_my_id)
	if me == null or _gm.has_front_unit(_my_id):
		return false
	var best = null
	for u in me.board:
		if u.health <= 2 and u.is_alive():
			best = u
			break
	if best == null:
		return false
	return _gm.place_in_front(_my_id, best.unit_id)


func _card_score(card) -> float:
	if card.is_minion():
		var s: float = 10.0 + card.cost + card.attack * 0.8 + card.health * 0.6
		if card.keywords.has(CardData.Keyword.CHARGE) or card.keywords.has(CardData.Keyword.RUSH):
			s += 3.0
		return s
	if card.is_permanent():
		# 护符 / 城邦：耐久高的更值钱，城邦额外加分（一副牌只能带 2 张，都是好东西）
		var ps: float = 9.0 + card.cost + card.durability() * 0.5
		if card.is_city():
			ps += 2.0
		return ps

	# 按效果类别（注册表里声明的 hint）评估，新增效果只要声明了 hint 就自动参与评估
	match CardEffects.ai_hint(card.effect_id):
		CardEffects.HINT_DAMAGE:
			if _lethal_with_damage(card.value):
				return 40.0
			if _can_kill_with_damage(card.value):
				return 22.0
			return 8.0 + card.value * 0.4
		CardEffects.HINT_REMOVAL:
			return 18.0 if _enemy_has_minions() else 1.0
		CardEffects.HINT_DRAW:
			return 14.0
		CardEffects.HINT_MANA:
			return 16.0
		CardEffects.HINT_HEAL:
			return 15.0 if _self_damaged() else 1.0
		CardEffects.HINT_SUMMON:
			return 13.0
		CardEffects.HINT_BUFF:
			return 9.0 if _gm.get_player(_my_id).board.size() > 0 else 1.0
		CardEffects.HINT_UTILITY:
			return 6.0
		_:
			return 4.0 + card.value * 0.2


func _pick_spell_target(card):
	var targets = _gm.get_valid_targets(_my_id, card)
	if targets.is_empty():
		return null
	var foe = _gm.get_foe(_my_id)
	var me = _gm.get_player(_my_id)

	match CardEffects.ai_hint(card.effect_id):
		CardEffects.HINT_DAMAGE, CardEffects.HINT_REMOVAL:
			# 先尝试补刀，其次打脸（若能斩杀）
			var best = null
			var best_attack := -1
			for t in targets:
				var tid: int = int(t["unit_id"])
				if tid < 0:
					continue
				var u = _gm.find_unit(tid)
				if u == null:
					continue
				var owner_ok: bool = u.owner_id != _my_id
				if not owner_ok:
					continue
				var is_damage: bool = CardEffects.ai_hint(card.effect_id) == CardEffects.HINT_DAMAGE
				if is_damage and u.health <= card.value and u.attack > best_attack:
					best_attack = u.attack
					best = t
				elif not is_damage and u.attack > best_attack:
					best_attack = u.attack
					best = t
			if best != null:
				return best
			if CardEffects.ai_hint(card.effect_id) == CardEffects.HINT_DAMAGE and foe.hero_hp + foe.armor <= card.value:
				for t in targets:
					if t["kind"] == "hero" and int(t["player_id"]) != _my_id:
						return t
			for t in targets:
				if t["kind"] == "hero" and int(t["player_id"]) != _my_id:
					return t
			return targets[0]
		CardEffects.HINT_HEAL:
			var worst = null
			var worst_missing := 0
			for t in targets:
				var tid: int = int(t["unit_id"])
				if tid < 0:
					var pid: int = int(t["player_id"])
					var hero = _gm.get_player(pid)
					var missing: int = hero.hero_max_hp - hero.hero_hp
					if missing > worst_missing:
						worst_missing = missing
						worst = t
				else:
					var u = _gm.find_unit(tid)
					if u == null:
						continue
					var m2: int = u.max_health - u.health
					if m2 > worst_missing:
						worst_missing = m2
						worst = t
			if worst != null:
				return worst
			for t in targets:
				if int(t["player_id"]) == _my_id:
					return t
			return targets[0]
		CardEffects.HINT_BUFF:
			var strongest = null
			var best_hp := -1
			for t in targets:
				var tid: int = int(t["unit_id"])
				if tid < 0:
					continue
				var u = _gm.find_unit(tid)
				if u == null or u.owner_id != _my_id:
					continue
				if u.health > best_hp:
					best_hp = u.health
					strongest = t
			return strongest if strongest != null else targets[0]
		_:
			# 未分类效果：按效果的默认目标倾向选择（敌方向优先敌方，其余优先友方）
			var prefer_enemy: bool = CardEffects.default_target(card.effect_id) in [
				CardData.Targeting.ENEMY_MINION, CardData.Targeting.ENEMY_HERO,
				CardData.Targeting.ANY_MINION, CardData.Targeting.ANY_CHARACTER]
			for t in targets:
				if (int(t["player_id"]) != _my_id) == prefer_enemy:
					return t
			return targets[0]


# ------------------------------ 攻击 ------------------------------

func _try_attack() -> bool:
	if not _my_turn():
		return false
	var me = _gm.get_player(_my_id)
	if me == null:
		return false
	for u in me.board:
		if not u.is_alive():
			continue
		var targets = _gm.get_valid_attack_targets(_my_id, u.unit_id)
		if targets.is_empty():
			continue

		var chosen = null
		# 1. 优先白赚（能击杀对方且自己不死）
		for t in targets:
			var tid: int = int(t["unit_id"])
			if tid < 0:
				continue
			var d = _gm.find_unit(tid)
			if d == null:
				continue
			if d.health <= u.attack and d.attack < u.health:
				chosen = t
				break
		# 2. 其次打脸
		if chosen == null:
			for t in targets:
				if t["kind"] == "hero":
					chosen = t
					break
		# 3. 只剩随从目标（通常是嘲讽）
		if chosen == null and targets.size() > 0:
			var weakest = targets[0]
			var lowest := 999999
			for t in targets:
				var tid2: int = int(t["unit_id"])
				if tid2 < 0:
					continue
				var d2 = _gm.find_unit(tid2)
				if d2 != null and d2.health < lowest:
					lowest = d2.health
					weakest = t
			chosen = weakest
		if chosen == null:
			continue
		return _gm.attack(_my_id, u.unit_id, int(chosen["unit_id"]), int(chosen["player_id"]))
	return false


# ------------------------------ 辅助判断 ------------------------------

func _can_kill_with_damage(value: int) -> bool:
	var foe = _gm.get_foe(_my_id)
	if foe == null:
		return false
	for u in foe.board:
		if u.health <= value:
			return true
	return false


func _lethal_with_damage(value: int) -> bool:
	var foe = _gm.get_foe(_my_id)
	return foe != null and foe.hero_hp + foe.armor <= value


func _enemy_has_minions() -> bool:
	var foe = _gm.get_foe(_my_id)
	return foe != null and foe.board.size() > 0


func _self_damaged() -> bool:
	var me = _gm.get_player(_my_id)
	if me == null:
		return false
	if me.hero_hp < me.hero_max_hp:
		return true
	for u in me.board:
		if u.health < u.max_health:
			return true
	return false


func _wait(t: float) -> void:
	await _gm.get_tree().create_timer(t).timeout
