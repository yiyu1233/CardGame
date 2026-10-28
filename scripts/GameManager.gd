extends Node
## 卡牌对战核心（自动加载为 GameManager）。
## 完整规则：双方英雄、随从上场与攻击、嘲讽 / 圣盾 / 冲锋 / 突袭 / 风怒、
## 战吼与亡语、法术指定目标、法力水晶、疲劳伤害、手牌与战场上限。

signal state_changed()
## 需要玩家做「三选一」的发现（界面弹窗）
signal discover_requested(pid: int, options: Array)
## 瞬念召唤的「基础机制 = 由玩家选择去向」：应召上场后请界面弹三选一
## （保留在场 / 返回手牌 / 进入墓地）。不选 = 默认留在场上。
signal invoke_choice_requested(pid: int, unit_id: int)
signal log_message(text: String)
signal game_over(winner_id: int, draw: bool)
signal card_played(pid: int, card: CardData)   ## 供记牌器统计本局已使用的卡牌
## 卡牌效果结算（带目标）：出牌特效据此打在**目标**身上，而不是打在出牌者身上
signal card_resolved(pid: int, card: CardData, target_unit_id: int, target_player_id: int)
signal game_started()                          ## 新对局开始（记牌器清零）
signal card_drawn(pid: int, count: int)        ## 抽到牌（左上角牌堆播抽牌动画）
## 需要在界面上冒一个数字（伤害 / 治疗 / 护甲）：unit_id < 0 表示英雄
signal amount_shown(pid: int, unit_id: int, amount: int, kind: String)
## 某个随从发起攻击（界面据此播该卡语音 / 攻击表现；在伤害结算完之后派发）
signal unit_attacked(pid: int, unit_id: int, target_unit_id: int, target_player_id: int)
## 某个单位**由卡牌效果召唤**入场（衍生物 / 复制 / 亡语召唤 / 瞬念召唤；不含从手牌打出那一次）
signal unit_summoned(pid: int, card: CardData)

const HAND_LIMIT := 10
const BOARD_LIMIT := 7
const START_HAND := 4
## 城邦格：每隔这么多个「自己的回合」判定一次
const CITY_SLOT_INTERVAL := 3
const MAX_MANA := 10
const HERO_MAX_HP := 30
## 死亡结算循环的安全上限（防御循环亡语；正常对局最高 14 个随从）
const DEATH_SETTLE_LIMIT := 256

const PLAYER_ID := 0
const ENEMY_ID := 1

var players: Array[PlayerState] = []
var turn_count := 0
var current_player := PLAYER_ID
var winner := -1          ## -1 表示进行中
var is_draw := false
## 本局对战模式（Formats.ROTATION「指定」/ Formats.UNLIMITED「无限」）：
## 决定能用的卡包（指定）与该模式自己的限制卡 / 张数规则。联机以房主为准（快照里同步）。
var current_mode := Formats.UNLIMITED
var busy := false         ## AI 行动期间禁止玩家操作
## 起手换牌还没确认（界面会弹「起手换牌」面板；确认前不让玩家出牌）
var mulligan_pending := false
var log_enabled := true
## 扩展包 / 机制脚本的公共状态袋（`mods/*` 里的脚本可以随便读写它，
## 内核不会碰这里；因此扩展包不需要往 GameManager 上加自己的字段）。
var mod_state: Dictionary = {}

# ------------------------------ 联机状态 ------------------------------
## true = 本机拥有权威（单机 / 房主），false = 客机（只发意图、按快照渲染）
var net_authority := true
## 待玩家选择的「发现」候选：{"pid": int, "options": Array[CardData]}；空 = 没有待选
var pending_discover: Dictionary = {}
## 待玩家选择的「瞬念召唤去向」：{"pid": int, "unit_id": int}；空 = 没有待选。
## 单位此刻已经在场上（默认留场），玩家改选后才回手 / 入墓 —— 不响应也不会卡住对局。
var pending_invoke_choice: Dictionary = {}
## true = 只读旁观（观战者、或快照还没到）：界面的一切操作都不生效
var net_locked := false
## 每回合时限（秒，0 = 不限）；联机由房主执行，客户端只显示倒计时
var turn_time_limit := 0
var turn_deadline_msec := 0
## 结算顺序确定化用的队列（同一次结算里的死亡 / 亡语按 unit_id 升序处理）
var _pending_deaths: Array = []

var _next_unit_id := 1
var _ai                                   ## EnemyAI（动态类型，避免编译顺序问题）
const EnemyAIScript = preload("res://scripts/EnemyAI.gd")


func _ready() -> void:
	CardDB.database_changed.connect(_on_database_changed)
	_ai = EnemyAIScript.new(self, ENEMY_ID)
	new_game()


# ------------------------------ 查询工具 ------------------------------

func get_player(pid: int) -> PlayerState:
	return players[pid] if pid >= 0 and pid < players.size() else null


func get_foe(pid: int) -> PlayerState:
	return get_player(1 - pid)


func game_active() -> bool:
	return winner == -1


func get_unit(pid: int, unit_id: int) -> BoardUnit:
	var p := get_player(pid)
	return p.get_unit(unit_id) if p != null else null


func find_unit(unit_id: int) -> BoardUnit:
	for p in players:
		var u := p.get_unit(unit_id)
		if u != null:
			return u
	return null


func unit_owner(unit_id: int) -> int:
	for p in players:
		if p.get_unit(unit_id) != null:
			return p.player_id
	return -1


func human_id() -> int:
	return PLAYER_ID


func finish_ai_turn() -> void:
	if busy and current_player == ENEMY_ID:
		busy = false
		_next_turn()


# ------------------------------ 对局流程 ------------------------------

func new_game() -> void:
	players.clear()
	players.append(PlayerState.new(PLAYER_ID, "我方", HERO_MAX_HP))
	players.append(PlayerState.new(ENEMY_ID, "敌方 AI", HERO_MAX_HP))
	turn_count = 0
	current_player = PLAYER_ID
	winner = -1
	is_draw = false
	busy = false
	_next_unit_id = 1
	_expiries.clear()             # 限时负累（手牌费用 +N 持续到某回合结束）不跨局
	_invoked.clear()              # 瞬念召唤「同名卡一回合一次」的记录不跨局
	pending_invoke_choice = {}    # 待选的瞬念召唤去向也不跨局
	_entrance_depth = 0

	# 对战模式（主页 / 组卡界面选的「指定 / 无限」）：决定可用卡包、限制卡与该模式的张数规则。
	current_mode = settings_mode()

	# 我方用主页选的那套**玩家自己组的卡组**（绑定到某个主战者职业，只能用本职业 + 中立）；
	# 组不出来（没组 / 卡组被删空 / 卡表被改 / 不在本模式卡包里）才回落到全卡牌组。
	# 敌方 AI 每局随机挑一个主战者职业，从「该职业 + 中立」的卡池里按同样的模式规则组牌，
	# 这样人机对手也会带上一套有职业性格的牌，而不是永远同一副全卡牌组。
	var mine_id := str(GameSettings.get("selected_deck"))
	var ai_class := CardDB.random_hero_class()
	var mode := current_mode
	for p in players:
		if p.player_id == PLAYER_ID:
			p.deck = CardDB.build_player_deck(mine_id, mode)
			if p.deck.is_empty():
				p.deck = CardDB.build_deck(-1, str(GameSettings.get("selected_class")), mode)
		else:
			p.deck = CardDB.build_deck(-1, ai_class, mode)
		if p.deck.is_empty():
			# 模式卡池凑不出牌（指定模式只勾了几个空卡包）→ 退回不限模式，保证还能开局
			p.deck = CardDB.build_deck()
			push_warning("[GameManager] %s模式凑不出牌，本局回落为不限卡包" % CardDB.mode_label(mode))
		p.deck.shuffle()
		p.hand.clear()
		p.board.clear()
		p.reset_slots()          # 战场格子重置为定长 BOARD_LIMIT 个空位
		p.graveyard.clear()
		p.units_died_turn = 0        # 死亡计数（瞬念召唤条件）跟着新局清零
		p.units_died_total = 0
		p.units_left_turn = 0        # 离场计数（含消失 / 回手；与“被破坏”分开）
		p.units_left_total = 0
		p.grave_entered_total = 0    # 累计进入墓地的张数（召唤出墓地也不回退）
		p.grave_entered.clear()
		p.troop_entered_total.clear()   # 兵种进场计数（兵种条件）跟着新局清零
		p.troop_entered_turn.clear()
		p.leader_effects.clear()        # 主战者效果也是「本局」的东西，新局从零开始
		p.mana = 0
		p.max_mana = 0
		p.fatigue = 0

	_log("=== 新对局开始（%s模式）：我方 %s %d 张／敌方（主战者 %s）%d 张，可用卡牌 %d 种 ===" % [
		CardDB.mode_label(mode), _deck_label(mine_id), get_player(PLAYER_ID).deck.size(),
		CardDB.hero_class_name(ai_class), get_player(ENEMY_ID).deck.size(), CardDB.cards.size()
	])
	draw(PLAYER_ID, START_HAND)
	draw(ENEMY_ID, START_HAND)
	_ai_mulligan()
	mulligan_pending = true
	game_started.emit()
	_start_turn(PLAYER_ID)


## 日志用：把卡组 id 翻成人话（没组 → 全卡牌组；id 已失效时如实写出来，方便排查）
func _deck_label(deck_id: String) -> String:
	if deck_id == "":
		return "全卡牌组"
	var def := CardDB.player_deck_by_id(deck_id)
	if def.is_empty():
		return "未知卡组(%s)" % deck_id
	return "「%s」（%s）" % [str(def.get("name", deck_id)),
		CardDB.hero_class_name(str(def.get("class_id", "")))]


## 主页 / 组卡界面选的模式（归一后）。界面在开局前也用它判断卡组是否可用。
func settings_mode() -> String:
	return Formats.normalized_mode(str(GameSettings.get("selected_mode")))


## 我方当前实际在用的卡组名，**空串表示还没组卡组 / 本模式用不了**（界面据此提示玩家先去组卡）
func current_deck_name() -> String:
	var id := str(GameSettings.get("selected_deck"))
	var def := CardDB.player_deck_by_id(id)
	if def.is_empty() or not CardDB.player_deck_ready(id, settings_mode()):
		return ""
	return str(def.get("name", ""))


## 我方出战卡组的主战者职业名（"" = 还没组）
func current_deck_class_name() -> String:
	var def := CardDB.player_deck_by_id(str(GameSettings.get("selected_deck")))
	if def.is_empty():
		return CardDB.hero_class_name(str(GameSettings.get("selected_class")))
	return CardDB.hero_class_name(str(def.get("class_id", "")))


## 我方是否可以开局：**必须已经组好一套卡组**（组不出来 / 本模式用不了就不给开打）
func player_deck_ready(mode: String = "") -> bool:
	var m := mode if mode != "" else settings_mode()
	return CardDB.player_deck_ready(str(GameSettings.get("selected_deck")), m)


## 起手换牌：把选中的手牌洗回牌库，再抽同样张数的新牌。
## 返回实际换掉的张数（越界 / 重复的下标会被忽略）。AI 的换牌在 new_game() 里自动完成。
func mulligan_replace(pid: int, indices: Array) -> int:
	var p := get_player(pid)
	if p == null:
		return 0
	var picks: Array[int] = []
	for i in indices:
		var idx: int = int(i)
		if idx >= 0 and idx < p.hand.size() and not picks.has(idx):
			picks.append(idx)
	if picks.is_empty():
		return 0
	picks.sort()
	var returned: Array[CardData] = []
	# 从后往前删，前面的下标才不会错位
	for k in range(picks.size() - 1, -1, -1):
		returned.append(p.hand[picks[k]])
		p.hand.remove_at(picks[k])
	for card in returned:
		p.deck.append(card)
	p.deck.shuffle()
	draw(pid, returned.size())
	_log("%s 换掉了 %d 张起手牌（洗回牌库后重抽）" % [p.display_name, returned.size()])
	return returned.size()


## 按**卡牌对象**换（界面用这条）：把这几张具体的手牌洗回牌库再重抽。
## 比下标更稳：换牌面板可能在下标漂移之后才确认（例如开局已经抽了回合牌）。
func mulligan_replace_cards(pid: int, cards: Array) -> int:
	var p := get_player(pid)
	if p == null or cards.is_empty():
		return 0
	var returned: Array[CardData] = []
	for card in cards:
		var idx: int = p.hand.find(card)
		if idx >= 0:
			returned.append(card)
			p.hand.remove_at(idx)
	if returned.is_empty():
		return 0
	for card in returned:
		p.deck.append(card)
	p.deck.shuffle()
	draw(pid, returned.size())
	_log("%s 换掉了 %d 张起手牌（洗回牌库后重抽）" % [p.display_name, returned.size()])
	return returned.size()


## 玩家确认起手（可能一张不换）：清掉待换牌状态。只能生效一次。
func finish_mulligan(pid: int, indices: Array) -> int:
	if pid == PLAYER_ID and not mulligan_pending:
		return 0
	var replaced := mulligan_replace(pid, indices)
	if pid == PLAYER_ID:
		mulligan_pending = false
	state_changed.emit()
	return replaced


## 界面用的确认入口：按卡牌对象换牌，并清掉待换牌状态。只能生效一次。
func finish_mulligan_cards(pid: int, cards: Array) -> int:
	if pid == PLAYER_ID and not mulligan_pending:
		return 0
	var replaced := mulligan_replace_cards(pid, cards)
	if pid == PLAYER_ID:
		mulligan_pending = false
	state_changed.emit()
	return replaced


## AI 的起手换牌：把高费（≥6）的起手牌换掉，最多换 2 张
func _ai_mulligan() -> void:
	var foe := get_player(ENEMY_ID)
	if foe == null:
		return
	var picks: Array[int] = []
	var i := 0
	while i < foe.hand.size() and picks.size() < 2:
		if foe.hand[i].cost >= 6:
			picks.append(i)
		i += 1
	if not picks.is_empty():
		mulligan_replace(ENEMY_ID, picks)


func end_turn() -> void:
	if not game_active():
		return
	if busy or current_player != PLAYER_ID:
		return
	_next_turn()


## 按当前行动方推进回合（联机时房主代表客机结束回合用；end_turn() 只管房主自己的座位）
func advance_turn() -> void:
	if not game_active() or busy:
		return
	_next_turn()


## 认输：直接判负（不走伤害结算，避免被护甲或圣盾挡住）
func concede(pid: int) -> void:
	if not game_active():
		return
	var p := get_player(pid)
	if p == null:
		return
	p.armor = 0
	p.hero_hp = 0
	_log("%s 认输" % p.display_name)
	_check_game_over()
	state_changed.emit()


func _next_turn() -> void:
	if not game_active():
		return
	# 回合结束：先把「临时召唤」到期的单位召回手牌，再把控制权交给对面
	_end_of_turn(current_player)
	current_player = 1 - current_player
	_start_turn(current_player)


func _start_turn(pid: int) -> void:
	if not game_active():
		return
	var p := get_player(pid)
	turn_count += 1
	p.turns_taken += 1
	p.max_mana = mini(MAX_MANA, p.max_mana + 1)
	# 过载（炉石）：法力上限照常增长，但本回合可用法力要扣掉上回合积欠的过载
	p.mana = maxi(0, p.max_mana - p.overload)
	if p.overload > 0:
		_log("  %s 承受 %d 点过载（本回合法力 %d/%d）" % [p.display_name, p.overload, p.mana, p.max_mana])
	p.overload = 0
	p.cards_played_turn = 0
	p.units_died_turn = 0
	p.units_left_turn = 0
	p.troop_entered_turn.clear()          # 兵种进场计数：本回合的那一份随回合开始清零
	# 主战者效果：先摘掉到期的（N 回合到点），再结算「我自己回合开始」的那批
	LeaderEffects.tick(self, pid)
	LeaderEffects.fire(self, pid, LeaderEffects.ON_TURN_START)
	# 卡牌触发效果：我方回合开始时（场上每张配了这个时机的卡各结算一次）
	_fire_board_triggers(pid, CardTriggers.EV_TURN_START)
	for u in board_units(pid):
		u.attacks_used = 0
	_tick_countdowns(pid)
	_log("===== 第 %d 回合：%s（法力 %d/%d，这是它的第 %d 个回合）=====" % [
		turn_count, p.display_name, p.mana, p.max_mana, p.turns_taken])
	draw(pid, 1)
	# 回合开始钩子：给这一方场上每个存活单位派发 on_turn_start（机制据此做事）
	for u in board_units(pid):
		if u != null and u.is_alive():
			Mechanics.dispatch(u, "on_turn_start", {"gm": self, "unit": u, "pid": pid, "source": u})
	state_changed.emit()
	# 城邦格：每 3 个自己的回合开始时判定一次（第 3 / 6 / 9… 个自己的回合）
	if game_active() and p.turns_taken % CITY_SLOT_INTERVAL == 0:
		_try_city_slot(pid)
		state_changed.emit()
	# 瞬念召唤（回合开始的检查点）：轮到谁才替谁判定 —— 自己回合开始时才结算
	# 「我方回合开始时」，对手的卡在这一刻不判定（瞬念召唤不在对手回合触发）。
	if game_active():
		_invoke_checkpoint(pid, [InvokeConditions.TIME_SELF_TURN_START])
	# 疲劳抽牌可能直接结束对局：此时不能再把回合交给 AI，否则 busy 会永远卡在 true
	if not game_active():
		return
	# 联机时敌方座位由真人占据：不要跑 AI（否则 AI 会替对手行动）
	if pid == ENEMY_ID and _ai != null and not net_ai_disabled():
		busy = true
		_ai.take_turn()
	_reset_turn_timer()


## 联机时对手座位是否由真人占据（此时不跑 AI）
func net_ai_disabled() -> bool:
	var net := get_node_or_null("/root/Net")
	if net == null or not net.is_online():
		return false
	# 有真人占了座位 1（或正在等它重连）就关掉 AI
	for pid in net.peers.keys():
		if int(net.peers[pid].get("seat", -1)) == ENEMY_ID:
			return true
	return net.get("_disconnected_seat") == ENEMY_ID


## 每回合时限：房主到点自动结束回合（客户端只显示倒计时）
func _reset_turn_timer() -> void:
	if turn_time_limit <= 0:
		turn_deadline_msec = 0
		return
	turn_deadline_msec = Time.get_ticks_msec() + turn_time_limit * 1000


## 剩余秒数（0 = 不限时或已到点）
func turn_seconds_left() -> int:
	if turn_deadline_msec <= 0:
		return 0
	return maxi(0, int(ceil((turn_deadline_msec - Time.get_ticks_msec()) / 1000.0)))


## 抽牌；牌库为空则造成递增疲劳伤害
func draw(pid: int, count: int) -> int:
	var p := get_player(pid)
	var drawn := 0
	for _i in count:
		if p.deck.is_empty():
			p.fatigue += 1
			_log("%s 牌库已空，受到 %d 点疲劳伤害" % [p.display_name, p.fatigue])
			damage_player(pid, p.fatigue)
			if not game_active():
				break
			continue
		var card: CardData = p.deck.pop_back()
		if p.hand.size() >= HAND_LIMIT:
			_log("%s 手牌已满，「%s」被销毁" % [p.display_name, card.card_name])
			p.note_grave_entered(card)
			continue
		p.hand.append(card)
		drawn += 1
		card_drawn.emit(pid, 1)
		# 主战者效果：「抽到 N 费卡」的监听（手牌已加入，效果里看到的手牌数是含这张的）
		LeaderEffects.fire(self, pid, LeaderEffects.ON_DRAW, card)
		if pid == PLAYER_ID:
			_log("我方抽到「%s」" % card.card_name)
	state_changed.emit()
	return drawn


# ------------------------------ 出牌 ------------------------------

func can_play(pid: int, hand_index: int) -> bool:
	if net_locked:
		return false          # 观战者 / 快照未到：一切操作都不生效
	if not game_active() or busy or current_player != pid:
		return false
	var p := get_player(pid)
	if hand_index < 0 or hand_index >= p.hand.size():
		return false
	var card := p.hand[hand_index]
	# 被禁锢的卡不能被打出（也不能被召唤 / 响应瞬念召唤，见 summon_unit / _try_invoke）
	if card.imprisoned:
		return false
	if card.cost > p.mana:
		return false
	if card.is_board_card() and not card.is_city() and board_size_used(pid) >= BOARD_LIMIT:
		return false
	# 城邦是「召唤进城邦格」的：格子被占用时打不出（它在主战者旁，不占 7 格战场）
	if card.is_city() and city_slot_unit(pid) != null:
		return false
	# 法术必须有合法目标才能释放；随从 / 护符 / 城邦的战吼即使没有目标也能上场（空放）。
	if not card.is_board_card() and card.needs_target() and get_valid_targets(pid, card).is_empty():
		return false
	return true


## 这张牌现在有没有合法目标（不需要目标的牌也算“有”——它直接能打）
func has_valid_targets(pid: int, card: CardData) -> bool:
	if not card.needs_target():
		return true
	return not get_valid_targets(pid, card).is_empty()


# ------------------------------ 融合（手牌里的融合） ------------------------------
#
# 融合卡在手牌里，吃掉 `fusion.count` 张符合 filter 的其它手牌；每张材料进墓地（计入墓地进入数）。
# 融合完成时依次：触发「融合时」词条 → 在手牌中结算 fusion.effects →
# 把 fusion.gain 永久追加到这张卡的效果链 → 若配了 transform 则整张替换成目标卡。
# 前置条件 fusion.require 走 EffectConditions 的量（离场数 / 墓地张数 / 兵种进场数…）。

## 材料卡是否满足融合 filter（兵种 / 种类 / 费用区间；空条件 = 任何手牌）
func _fusion_material_ok(card: CardData, filter: Dictionary) -> bool:
	if card == null:
		return false
	var troop := str(filter.get("troop", "")).strip_edges()
	if troop != "" and CardDB.troop_of(card) != troop:
		return false
	var t := int(filter.get("type", -1))
	if t >= 0 and int(card.card_type) != t:
		return false
	var lo := int(filter.get("cost_min", 0))
	var hi := maxi(lo, int(filter.get("cost_max", 99)))
	if card.cost < lo or card.cost > hi:
		return false
	return true


## 融合的前置条件（没配 → 恒成立）
func fusion_require_met(pid: int, card: CardData) -> bool:
	if card == null or not card.has_fusion():
		return false
	var req := card.fusion_require()
	if EffectConditions.is_empty(req):
		return true
	return EffectConditions.met(self, pid, req)


## 当前可以作为融合材料的手牌下标（不含融合卡自己）
func fusion_materials(pid: int, hand_index: int) -> Array[int]:
	var out: Array[int] = []
	var p := get_player(pid)
	if p == null or hand_index < 0 or hand_index >= p.hand.size():
		return out
	var card := p.hand[hand_index]
	if not card.has_fusion():
		return out
	var filter := card.fusion_filter()
	for i in p.hand.size():
		if i == hand_index:
			continue
		if _fusion_material_ok(p.hand[i], filter):
			out.append(i)
	return out


## 现在能不能融合（前置条件 + 手牌里材料够数）
func can_fuse(pid: int, hand_index: int) -> bool:
	var p := get_player(pid)
	if p == null or hand_index < 0 or hand_index >= p.hand.size():
		return false
	var card := p.hand[hand_index]
	if not card.has_fusion() or not fusion_require_met(pid, card):
		return false
	return fusion_materials(pid, hand_index).size() >= card.fusion_count()


## 执行一次融合；`material_indices` = 要吃掉的手牌下标（数量必须等于 fusion.count）
func fuse(pid: int, hand_index: int, material_indices: Array) -> bool:
	if not game_active() or busy or current_player != pid:
		return false
	var p := get_player(pid)
	if p == null or hand_index < 0 or hand_index >= p.hand.size():
		return false
	var card := p.hand[hand_index]
	if not card.has_fusion():
		return false
	if not fusion_require_met(pid, card):
		_log("融合条件不满足：%s" % EffectConditions.text(card.fusion_require()))
		return false
	var need := card.fusion_count()
	if material_indices.size() != need:
		_log("融合需要 %d 张材料（收到 %d 张）" % [need, material_indices.size()])
		return false
	var mats: Array[CardData] = []
	var seen := {}
	for raw in material_indices:
		var i := int(raw)
		if i < 0 or i >= p.hand.size() or i == hand_index or seen.has(i):
			_log("融合材料选择不合法")
			return false
		var m: CardData = p.hand[i]
		if m == card or not _fusion_material_ok(m, card.fusion_filter()):
			_log("「%s」不符合融合条件" % (m.card_name if m != null else "?"))
			return false
		seen[i] = true
		mats.append(m)
	# 材料离开手牌 → 进墓地（融合是“吃掉”，不是被破坏）
	for m in mats:
		p.hand.erase(m)
		p.note_grave_entered(m)
	_log("★ 融合：「%s」融合了 %d 张手牌（%s）" % [
		card.card_name, mats.size(), "、".join(mats.map(func(c: CardData) -> String: return c.card_name))])
	# ① 「融合时」词条（在手牌里触发）
	_fire_card_trigger(pid, card, CardTriggers.EV_FUSION)
	# ② 在手牌中发动的效果
	var hand_fx := card.fusion_effects()
	if not hand_fx.is_empty():
		_log("  融合后在手牌发动：%s" % card.chain_text(hand_fx))
		_resolve_chain(pid, card, hand_fx, -1, -1, null, false)
		_cleanup_deaths()
	# ③ 永久获得的效果（追加到这张卡自己的效果链）
	var gain := card.fusion_gain()
	if not gain.is_empty():
		for e in gain:
			card.effects.append(e)
		card.sync_legacy_from_chains()
		_log("  「%s」获得：%s" % [card.card_name, card.chain_text(gain)])
	# ④ 化身为另一张卡（配了就整张替换）
	var tr := card.fusion_transform()
	if tr != "":
		var tpl := CardDB.get_card(tr)
		if tpl == null:
			_log("  融合化身失败：卡表里没有「%s」" % tr)
		else:
			var nc: CardData = tpl.clone()
			var at := p.hand.find(card)
			if at >= 0:
				p.hand[at] = nc
			_log("  融合化身：「%s」→「%s」" % [card.card_name, nc.card_name])
			card = nc
	state_changed.emit()
	return true


## 打出第 index 张手牌。需要目标的卡必须传入目标。
## `to_front` = 横置进正中格（横置格）；`slot` = 指定放进第几格（0 起）：
##   * `slot < 0` = 自动放进**第一个空位**（原来的行为，老调用与测试不变）；
##   * 越界 / 该格已被占用 → 整次出牌失败：**不扣费、手牌不动、不结算**。
func play_card(pid: int, hand_index: int, target_unit_id: int = -1, target_player_id: int = -1,
		to_front: bool = false, slot: int = -1) -> bool:
	if not can_play(pid, hand_index):
		var p0 := get_player(pid)
		if hand_index >= 0 and hand_index < p0.hand.size():
			var c0 := p0.hand[hand_index]
			if c0.imprisoned:
				_log("「%s」被禁锢，无法打出" % c0.card_name)
			elif c0.cost > p0.mana:
				_log("法力不足：需要 %d，剩余 %d" % [c0.cost, p0.mana])
			elif c0.is_board_card() and board_size_used(pid) >= BOARD_LIMIT:
				_log("战场已满（上限 %d），无法上场" % BOARD_LIMIT)
		return false

	var p := get_player(pid)
	var card := p.hand[hand_index]
	# ——— 指定格子：先把格子验证做完，占用 / 越界就直接失败（不扣费、手牌不动）———
	# 城邦一律进城邦格，不占 7 格战场，所以格子参数只对随从 / 护符生效。
	var want_front := false
	var dest_slot := slot
	if card.is_board_card() and not card.is_city():
		var can_front: bool = card.is_minion() and not card.needs_target()
		if dest_slot < -1 or dest_slot >= BOARD_LIMIT:
			_log("目标格子 %d 超出战场范围（0-%d）" % [dest_slot, BOARD_LIMIT - 1])
			return false
		# 正中那一格就是横置格：拖到那里（或老界面的 to_front）＝横置进去；
		# 里面的单位先退回后排（老口径），所以这里不做「被占用就失败」的检查。
		if can_front and (to_front or dest_slot == PlayerState.FRONT_SLOT):
			# 把随从直接放进防御格也算一次「移入」：同样受「自己回合 + 一回合一次」的限制，
			# 而且**在扣法力和移除手牌之前**拦下（打不出就把牌留在手里）。
			if not can_move_front(pid):
				_log(front_move_blocked_reason(pid))
				return false
			want_front = true
			dest_slot = PlayerState.FRONT_SLOT
		elif dest_slot >= 0 and board_slot(pid, dest_slot) != null:
			_log("第 %d 格已经被占用，换一格再放" % (dest_slot + 1))
			return false
	# 需要目标的牌：有合法目标就照常指定；没有目标时，
	# 随从 / 护符 / 城邦仍然可以上场（战吼空放），法术则打不出（can_play 已经拦下）。
	var target_ok: bool = true
	if card.needs_target():
		target_ok = is_valid_target(pid, card, target_unit_id, target_player_id)
		if not target_ok:
			if not card.is_board_card():
				_log("「%s」需要一个合法的%s，当前没有合法目标 → 无法释放" % [card.card_name, card.target_name()])
				return false
			if not can_play(pid, hand_index):
				return false

	p.mana -= card.cost
	# 连击（炉石）：这张牌结算前，本回合已经打出过别的牌才算数
	var is_combo: bool = card.combo_effect_id != CardData.NO_EFFECT and p.cards_played_turn > 0
	p.cards_played_turn += 1
	if card.overload > 0:
		p.overload += card.overload
		_log("  「%s」过载 %d（下回合法力减少）" % [card.card_name, card.overload])
	p.hand.remove_at(hand_index)
	_log("%s 打出「%s」（%d 法力）" % [p.display_name, card.card_name, card.cost])
	card_played.emit(pid, card)
	card_resolved.emit(pid, card, target_unit_id, target_player_id)

	# 这次「打出」有没有在场地区域留下一个单位（随从 / 护符 / 城邦）：
	# 触发效果里的「入场（打出）时」优先以它为效果来源（吸血 / 剧毒照常生效）。
	var played_unit: BoardUnit = null
	if card.is_board_card():
		if card.is_city():
			# 城邦一律召唤进主战者旁的城邦格（不占 7 格战场）
			var city_unit := summon_city_into_slot(pid, card, "从手牌打出")
			played_unit = city_unit
			if card.has_effects():
				if target_ok:
					_resolve_effect(pid, card, target_unit_id, target_player_id, city_unit)
				else:
					_log("  场上没有「%s」的合法目标，安放效果空放" % card.card_name)
		else:
			# 随从 / 护符都占战场格子；横置格只收随从。
			# 要横置时先把正中格腾出来（老口径：「原来在格里的先退回后排」）。
			if want_front:
				_evacuate_front_slot(pid)
			var unit := summon_unit(pid, card, dest_slot, "")
			played_unit = unit
			if unit != null and want_front:
				_clear_front(pid)
				unit.in_front = true
				p.front_move_turn = turn_count      # 直接横置上场也算用掉了本回合的调整名额
				_log("  「%s」移入防御格（只受 1 点伤害、无法攻击 / 无法发动技能；被对面随从碰撞攻击才会撤出）" % card.card_name)
			# 战吼（护符是“安放”效果）在上场后结算；把该单位作为效果来源，吸血 / 剧毒同样成立。
			# 指定目标却没指定到（场上没有任何合法目标）时战吼空放，不上场就白打。
			if card.has_effects():
				if target_ok:
					_resolve_effect(pid, card, target_unit_id, target_player_id, unit)
				else:
					_log("  场上没有「%s」的合法目标，战吼空放" % card.card_name)
		_cleanup_deaths()
	elif card.needs_target() and not target_ok:
		# 走到这里说明是法术且没有合法目标，can_play 已经拦过；保险起见不结算
		return false
	else:
		_resolve_effect(pid, card, target_unit_id, target_player_id)
		p.note_grave_entered(card)
		_cleanup_deaths()

	# 连击（炉石）：本回合已经打出过别的牌时，额外再执行一次连击效果
	if is_combo:
		_log("  连击：「%s」追加结算" % card.card_name)
		var combo_card: CardData = card.clone()
		# 连击是**老字段**的机制：清空效果链，让这次结算只走 combo_effect_id，
		# 否则带效果链的卡会把整条链再打一遍。
		combo_card.effects = []
		combo_card.effect_id = card.combo_effect_id
		combo_card.value = card.combo_value
		combo_card.target = CardEffects.default_target(card.combo_effect_id)
		_resolve_effect(pid, combo_card, target_unit_id, target_player_id)
		_cleanup_deaths()

	# 卡牌触发效果：入场（从手牌打出）。随从 / 护符 / 城邦还留在场上就用它当来源；
	# 法术（没有上场单位）走卡牌级入口；占场地的卡没站住（战吼把自己打死了 / 没格子）就不算入场。
	if card.is_board_card():
		if played_unit != null and played_unit.is_alive():
			_fire_unit_trigger(pid, played_unit, CardTriggers.EV_PLAY)
	else:
		_fire_card_trigger(pid, card, CardTriggers.EV_PLAY)

	# 主战者效果：这张卡「入场（打出）」时把它的效果挂给主战者，再结算主战者侧的「打出 N 费卡」监听
	LeaderEffects.grant(self, pid, card, LeaderEffects.GRANT_PLAY)
	LeaderEffects.fire(self, pid, LeaderEffects.ON_PLAY, card)

	# 打出一张牌之后是一个检查点：「本回合已打出 N 张牌」这类条件只看得见这里
	# （只替打出牌的这一方判定 —— 它本来也只能发生在自己的回合里）
	_invoke_checkpoint(pid)
	_check_game_over()
	state_changed.emit()
	return true


## 按 ID 取卡牌（效果系统通过它访问卡表，避免产生循环编译依赖）
## 效果数值换算：**法术**的伤害性效果要加上施法方的「法术伤害 +N」（炉石风格，多张叠加）。
## 消灭 / 治疗 / 抽牌等非伤害效果不受影响。
func _effect_value(pid: int, card: CardData) -> int:
	return _chain_value(pid, card, card.effect_id, card.value)


## 效果链里**某一条**效果的最终数值（口径与改动前的 _effect_value 完全一致）
func _chain_value(pid: int, card: CardData, eid: String, base: int) -> int:
	if card.card_type != CardData.CardType.SPELL:
		return base
	if CardEffects.ai_hint(eid) != CardEffects.HINT_DAMAGE:
		return base
	var bonus := spell_damage_bonus(pid)
	if bonus > 0:
		_log("  法术伤害 +%d（本次伤害 %d -> %d）" % [bonus, base, base + bonus])
	return base + bonus


## 某一方场上所有「法术伤害」的总和
func spell_damage_bonus(pid: int) -> int:
	var p := get_player(pid)
	if p == null:
		return 0
	var total := 0
	for u in board_units(pid):
		if u.has_mechanic(CardData.Keyword.SPELL_DAMAGE):
			total += maxi(0, u.data.spell_damage)
	return total


# ------------------------------ 发现（三选一） ------------------------------
#
# 影之诗 / 炉石的「发现」：从若干随机卡牌里挑一张加入手牌。
# 效果结算本身是同步的，所以这里只**挂起**选择（pending_discover），由界面弹出三选一，
# 选完再调 `resolve_discover()` 把手牌加上去。

## 挂起一次发现；options 为候选卡（界面负责展示）。返回是否成功挂起。
func begin_discover(pid: int, options: Array) -> bool:
	if options.is_empty():
		return false
	pending_discover = {"pid": pid, "options": options}
	_log("%s 发现：从 %d 张候选里选一张" % [get_player(pid).display_name if get_player(pid) != null else "?", options.size()])
	discover_requested.emit(pid, options)
	state_changed.emit()
	return true


## 结算发现：把选中的那张加入手牌
func resolve_discover(index: int) -> bool:
	if pending_discover.is_empty():
		return false
	var options: Array = pending_discover.get("options", [])
	# 越界序号**不消耗**这次待选：玩家可以重新选（否则一次误点就白丢一张牌）
	if index < 0 or index >= options.size():
		return false
	var pick: CardData = options[index]
	var pid: int = int(pending_discover.get("pid", PLAYER_ID))
	pending_discover = {}
	if pick == null:
		return false
	var p := get_player(pid)
	if p == null:
		return false
	if p.hand.size() >= HAND_LIMIT:
		_log("手牌已满，「%s」被销毁" % pick.card_name)
		p.note_grave_entered(pick)
	else:
		p.hand.append(pick)
		_log("  发现：「%s」加入手牌" % pick.card_name)
	state_changed.emit()
	return true


## 给「发现」用的随机候选（默认从全部可收集卡里抽，排除衍生物）
func random_discover_options(count: int = 3) -> Array:
	var pool: Array[CardData] = []
	for c in CardDB.cards:
		if not c.is_token:
			pool.append(c)
	pool.shuffle()
	var out: Array = []
	for i in mini(count, pool.size()):
		out.append(pool[i].clone())
	return out



# ------------------------------ 战局阶段（对照影之诗 IPhase 流程） ------------------------------
#
# 影之诗把一场战斗拆成 Loading → Opening → Mulligan → Main → Result 五个阶段
# （见逆向文档 docs/battle-settlement.md）。这里用**派生**方式把同样的阶段暴露出来：
# 阶段由既有状态推导，不改变任何行为，界面 / 联机 / 测试可以直接问"现在处在哪个阶段"。

enum BattlePhase { LOADING = 0, OPENING = 1, MULLIGAN = 2, MAIN = 3, RESULT = 4 }
const BATTLE_PHASE_NAMES: Array[String] = ["加载", "开场", "起手换牌", "主战", "结算"]


func battle_phase() -> int:
	if players.size() < 2 or turn_count <= 0:
		return BattlePhase.LOADING if players.size() < 2 else BattlePhase.OPENING
	if winner >= 0 or is_draw:
		return BattlePhase.RESULT
	if mulligan_pending:
		return BattlePhase.MULLIGAN
	return BattlePhase.MAIN


func battle_phase_name() -> String:
	var k: int = battle_phase()
	return BATTLE_PHASE_NAMES[k] if k >= 0 and k < BATTLE_PHASE_NAMES.size() else "?"


## 是否处在"可以出牌 / 攻击"的主战阶段（界面与 AI 都该问这一句）
func in_main_phase() -> bool:
	return battle_phase() == BattlePhase.MAIN and game_active()

func card_by_id(id: String) -> CardData:
	return CardDB.get_card(id)


## 召唤一个单位上场（效果系统调用的统一入口）。
## 随从 / 护符：占一格、护符攻击力固定为 0、生命值即耐久。
## 城邦：一律进主战者旁的城邦格（不占 7 格战场）——「城邦格就是把城邦召唤到这个格子里」。
## `slot` = 放进第几格（0 起，见 PlayerState.SLOT_COUNT）：
##   * `slot < 0`：自动放进**第一个空位**（原来的行为，老调用与测试不变）；
##   * 指定格子：越界 / 该格已被占用 / 战场已满 → 返回 null（不放置）。
## 注意：横置状态由调用方设置（play_card / place_in_front），本函数只负责「放进哪一格」。
## **召唤一律不结算入场效果**（衍生物 / 复制 / 亡语召唤都走这里）：
## 入场效果只在 `play_card()` 打出时自动结算；召唤之后想再触发一次，请用 `trigger_entrance_effect()`。
## `grant_reason`：这次上场算哪种「赋予时机」（主战者效果用）：
##   召唤入场 = SUMMON（默认）；从手牌打出传 ""（由 play_card 统一按 PLAY 赋予，避免一次上场挂两遍）。
func summon_unit(pid: int, card: CardData, slot: int = -1,
		grant_reason: String = LeaderEffects.GRANT_SUMMON) -> BoardUnit:
	# 被禁锢的卡无法被召唤出来（卡留在原处：牌库 / 墓地 / 手牌都不动）
	if card.imprisoned:
		_log("「%s」被禁锢，无法召唤" % card.card_name)
		return null
	if card.is_city():
		var city := summon_city_into_slot(pid, card, "")
		# 触发效果：城邦被（效果）召唤入场 —— 从手牌打出那次由 play_card 走「入场（打出）」
		if city != null and grant_reason == LeaderEffects.GRANT_SUMMON:
			_fire_unit_trigger(pid, city, CardTriggers.EV_SUMMON)
		return city
	var p := get_player(pid)
	if p == null:
		return null
	if board_size_used(pid) >= BOARD_LIMIT:
		_log("战场已满，无法上场「%s」" % card.card_name)
		p.note_grave_entered(card)
		return null
	var dest := slot
	if dest < 0:
		dest = first_empty_slot(pid)
	if dest < 0:
		_log("战场没有空位，无法上场「%s」" % card.card_name)
		p.note_grave_entered(card)
		return null
	if dest >= BOARD_LIMIT or board_slot(pid, dest) != null:
		_log("第 %d 格被占用，无法上场「%s」" % [dest + 1, card.card_name])
		return null
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, turn_count, _next_unit_id)
	_next_unit_id += 1
	if card.is_permanent():
		u.attack = 0                                  # 护符不能攻击
		u.max_health = card.durability()
		u.health = card.durability()
	p.place_unit_at(u, dest)
	# 兵种进场计数：这条卡（以及衍生物 / 复制 / 亡语召唤）真的站到场上才算「进入战场」，
	# 所以放在放置成功之后；没选兵种的卡记在「中立」名下。
	p.note_troop_entered(card.troop_id)
	if card.is_permanent():
		_log("%s 安放「%s」（耐久 %d，第 %d 格）" % [p.display_name, card.card_name, u.health, dest + 1])
	else:
		_log("%s 召唤「%s」%d/%d（第 %d 格）" % [p.display_name, card.card_name, u.attack, u.health, dest + 1])
	# 主战者效果：这次上场的「赋予时机」（召唤入场 / 由调用方指定成打出、瞬念召唤…）
	if grant_reason != "":
		LeaderEffects.grant(self, pid, card, grant_reason)
	# 卡牌触发效果：召唤入场（衍生物 / 复制 / 亡语召唤 / 效果召唤）。
	# 从手牌打出（grant_reason = ""）不算「召唤入场」—— 那一次由 play_card 走 EV_PLAY。
	if grant_reason == LeaderEffects.GRANT_SUMMON:
		_fire_unit_trigger(pid, u, CardTriggers.EV_SUMMON)
		unit_summoned.emit(pid, u.data)
	return u


## 化身：把场上的目标随从**原地替换**成另一张随从卡（身材 / 词条 / 效果全部换成新卡）。
## 口径：
##   * 不触发旧卡的离场能力、也不触发新卡的入场能力（它是“变成了另一张卡”，不是下场再上场）；
##   * 不计入被破坏 / 离场计数；
##   * 保留格子位置、横置状态与 unit_id（界面选中与箭头不会跳）；
##   * 只能化身成**随从**（护符 / 城邦 / 法术不在此列）。
func transform_unit(u: BoardUnit, card_id: String) -> BoardUnit:
	if u == null or u.data == null:
		return null
	if u.in_city_slot:
		_log("城邦格里的城邦不能化身")
		return null
	var card := card_by_id(card_id)
	if card == null or not card.is_minion():
		_log("化身失败：卡表里没有随从「%s」" % card_id)
		return null
	var p := get_player(u.owner_id)
	if p == null:
		return null
	var old_name := u.data.card_name
	var slot := p.slot_of(u)
	var was_front := u.in_front
	var keep_uid := u.unit_id
	var summoned_turn := u.summoned_turn
	p.remove_unit(u)
	var nu := BoardUnit.new()
	nu.setup(card.clone(), p.player_id, summoned_turn, keep_uid)
	nu.in_front = was_front
	var dest := slot if slot >= 0 else first_empty_slot(p.player_id)
	if dest < 0 or not p.place_unit_at(nu, dest):
		_log("化身失败：没有空位安置「%s」" % card.card_name)
		p.note_grave_entered(nu.data)
		return null
	_log("「%s」化身成「%s」" % [old_name, card.card_name])
	state_changed.emit()
	return nu


# ------------------------------ 手牌费用 / 复制 / 牌库调度 ------------------------------
#
# 三个原语，效果层（CardEffects / EffectContext）可以随意组合：
#   * `raise_hand_cost()`      抬高某一方手牌的费用；
#   * `summon_copies()`        把单位的副本召唤到战场；
#   * `copy_unit_to_deck()` / `copy_hand_cards_to_deck()`  把副本随机洗进牌库；
#   * `summon_from_deck()`     从牌库检索一张符合口径的卡召唤上场（可指定临时登场）。
# 统一的口径：
#   * 复制的是**卡牌本体**（再次被召唤不会连锁触发它的入场效果，与既有的召唤规则一致）；
#   * 进牌库的位置是**随机位置**（抽牌走 pop_back，随机放置才不会动到已知顺序）；
#   * 任何一步都可能因为「战场满 / 手牌满 / 牌库空 / 卡不存在」失败，失败只记日志、不抛错。

# ------------------------------ 瞬念召唤 ------------------------------
#
# 瞬念召唤（影之诗 Invocation）：卡牌**自己**待在牌库里，满足条件时自动上场，
# 不需要任何人打出它 —— 它由引擎在**检查点**替它判定（见 _invoke_checkpoint）。
# 四条规则：
#   1. 它不是战吼：应召上场**不结算**入场效果（与所有召唤路径的口径一致）；
#   2. 同名卡的瞬念召唤**每个回合只结算一次**（多张同名卡同一回合只应召一张）；
#   3. **只在这一方自己的回合结算**：每个检查点只替当前行动方判定，对手在动的时候
#      这张卡不会从牌库里冒出来（详见 InvokeConditions 顶部的说明）；
#   4. **以卡面原始数值登场**：在牌库里攒下的卡面改动（费用被减半 / 身材被加减 /
#      被赋予关键字这类）不算到战场上 —— 上场的是卡表里那一张（见 `_clean_deck_card`）。

## 一张卡**从牌堆里被拉上场**之前，先把它在牌堆里攒下的卡面改动洗掉。
## 费用减半 / 身材加减 / 赋予关键字这类效果改的是「牌堆里那张卡」本身（同一个 CardData 对象），
## 而应召上场的应该是**卡表里那张原始卡**：登场数值以卡面为准，牌堆里的账不带到战场上
## （同理适用于「呼唤」这类检索召唤：见 `summon_from_source`）。
## 卡表里查不到这个 id（例如某一张临时造的卡）就原样返回 —— 没有原始卡可以对照时不瞎改。
func _clean_deck_card(card: CardData) -> CardData:
	if card == null:
		return null
	var base: CardData = CardDB.get_card(card.id)
	if base == null:
		return card
	return base.clone()


## 「本回合已经应召过的同名卡」：`"pid|卡 id" -> 当时的 turn_count`。
## 用回合号比较而不是每次清空：既不用管清零时机，也不需要额外的 per-player 字段。
var _invoked: Dictionary = {}
## 重入保护：应召过程中可能连带触发别的东西，别在同一个检查点里再套一层判定
var _invoke_busy := false


## 在一个检查点判定瞬念召唤 —— **只替行动方（这一回合属于它的那一方）判定**。
## `extra_timings` 是除了「任意时机」以外，这一刻行动方还能结算的专属时机
## （回合开始 → [TIME_SELF_TURN_START]；回合结束 → [TIME_SELF_TURN_END]）。
##
## 这里**不看 busy**：AI 接管自己的回合时 busy 一直是 true，它自己的瞬念召唤照常要判定；
## 去重与重入保护由 `_invoke_busy` 负责。
func _invoke_checkpoint(pid: int, extra_timings: Array = []) -> void:
	if not game_active() or _invoke_busy:
		return
	var allowed: Array = [InvokeConditions.TIME_ANY]
	allowed.append_array(extra_timings)
	_invoke_busy = true
	_try_invoke(pid, allowed)
	_invoke_busy = false


## 「任意时机」的检查点（我方回合内：打出牌之后 / 攻击之后）


## 替某一方扫描牌库，把这一刻该应召的卡召唤上场（可能一次应召多张**不同 id** 的卡）。
##
## 流程照 SV 的 RegisterSkillConditionCheck 分两层：
##   ① 先把不可能应召的卡筛掉（没配 / 时机不对 / 这一回合已经应召过）—— 不读局面；
##   ② 剩下的才需要「局面快照」，而快照**一个检查点只算一次**（而不是每查一张卡算一遍）。
func _try_invoke(pid: int, allowed_timings: Array) -> void:
	var p := get_player(pid)
	if p == null or (p.deck.is_empty() and p.graveyard.is_empty()):
		return
	# 先快照候选：应召过程中牌库 / 墓地会被改（卡被移除），不能边遍历边删。
	# 牌库：随从 / 护符 / 城邦走“上场”；法术走“发动 / 进手牌”。
	# 墓地：只有法术能响应瞬念召唤（随从走亡招类的 summon_deck_* + 来源=墓地）。
	var candidates: Array[Dictionary] = []
	for card in p.deck:
		if not (card is CardData):
			continue
		var c: CardData = card
		if _invoke_candidate_ok(c, allowed_timings, pid):
			candidates.append({"card": c, "zone": "deck"})
	for card in p.graveyard:
		if not (card is CardData):
			continue
		var gc: CardData = card
		if int(gc.card_type) != CardData.CardType.SPELL:
			continue
		if _invoke_candidate_ok(gc, allowed_timings, pid):
			candidates.append({"card": gc, "zone": "grave"})
	if candidates.is_empty():
		return

	var ctx := InvokeConditions.snapshot(self, pid)
	for cand in candidates:
		if not game_active():
			return
		var c: CardData = cand["card"]
		var zone := str(cand["zone"])
		var zone_list: Array = p.deck if zone == "deck" else p.graveyard
		var zone_name := "牌库" if zone == "deck" else "墓地"
		if _invoked.get(_invoke_key(pid, c.id), -1) == turn_count:
			continue                     # 同一批候选里同 id 的第二张：已经被上一张顶掉了
		# 兵种类量：判定 key 是 `量@兵种`（与 InvokeConditions.snapshot 铺的 key 对应）
		if not InvokeConditions.met(c.invoke_scoped_metric(), c.invoke_op(), c.invoke_value(), ctx):
			continue
		var cond_text := InvokeConditions.text(c.invoke_metric(), c.invoke_op(),
			c.invoke_value(), c.invoke_troop())

		# ---- 法术：在牌库 / 墓地直接发动，或进入手牌（不会“上场”）----
		if int(c.card_type) == CardData.CardType.SPELL:
			if not _remove_one(zone_list, c):
				continue
			_invoked[_invoke_key(pid, c.id)] = turn_count
			var cast_card: CardData = _clean_deck_card(c) if zone == "deck" else c
			if c.invoke_dest() == CardData.InvokeDest.HAND:
				_log("★ 瞬念召唤：「%s」满足条件（%s），从%s进入手牌" % [c.card_name, cond_text, zone_name])
				if p.hand.size() >= HAND_LIMIT:
					p.note_grave_entered(cast_card)
					_log("  手牌已满 → 进入墓地")
				else:
					p.hand.append(cast_card)
			else:
				_log("★ 瞬念召唤：「%s」满足条件（%s），从%s直接发动" % [c.card_name, cond_text, zone_name])
				_resolve_effect(pid, cast_card, -1, -1)
				_cleanup_deaths()
				# 法术使用后进墓地（与从手牌打出同一口径）
				p.note_grave_entered(cast_card)
			state_changed.emit()
			continue

		# ---- 随从 / 护符 / 城邦：只在牌库、应召上场 ----
		if zone != "deck":
			continue
		# 没有空置格 → 这张卡**消失**（影之诗的消失：从游戏中移除，不进战场 / 手牌 / 墓地）
		if not _invoke_has_room(pid, c):
			if _remove_one(p.deck, c):
				_invoked[_invoke_key(pid, c.id)] = turn_count
				# 「消失」计入离场，但不计入被破坏（units_died_* 不动）
				p.note_unit_left()
				_log("★ 瞬念召唤：「%s」满足条件（%s），但己方没有空置格 → 消失（从游戏中移除）" % [
					c.card_name, cond_text])
				# 主战者效果：「消失」也算一次赋予时机（影之诗里「消滅された時」类效果）
				LeaderEffects.grant(self, pid, c, LeaderEffects.GRANT_VANISH)
				# 卡牌触发效果：消失（从游戏中移除，不进战场 / 手牌 / 墓地）
				_fire_card_trigger(pid, c, CardTriggers.EV_VANISH)
				state_changed.emit()
			continue
		# 条件达成 → 真的应召：先从牌库移除这一张，再走普通召唤路径（不上场就把牌还回去）
		if not _remove_one(p.deck, c):
			continue
		# 洗掉它在牌堆里攒下的卡面改动：登场的是卡表里那张原始卡
		var u := summon_unit(pid, _clean_deck_card(c), -1, "")
		if u == null:
			p.deck.append(c)     # 没安置成功就把卡放回牌库，不做无谓的消耗
			continue
		_invoked[_invoke_key(pid, c.id)] = turn_count
		_log("★ 瞬念召唤：「%s」满足条件（%s）自动上场" % [c.card_name, cond_text])
		# 主战者效果：瞬念召唤是一个独立的赋予时机（与「入场 / 召唤入场」分开配）
		LeaderEffects.grant(self, pid, c, LeaderEffects.GRANT_INVOKE)
		# ① 先结算「瞬念召唤效果」——与战吼 / 亡语完全独立的一条效果链（可以留空）
		if c.invoke_has_effects():
			_log("  触发瞬念召唤效果：「%s」%s" % [c.card_name, c.invoke_effect_text()])
			_resolve_chain(pid, c, c.invoke_effect_chain(), -1, -1, u, false)
			_cleanup_deaths()
		# ② 卡牌触发效果：瞬念召唤上场时（还在场上时结算，早于「去向」）
		if u.is_alive():
			_fire_unit_trigger(pid, u, CardTriggers.EV_INVOKE)
		# ③ 再执行「基础机制」= 去向（必选，不能为空）
		_apply_invoke_destination(pid, u, c.invoke_dest())
		state_changed.emit()


## 瞬念召唤候选的公共筛选（类型 / 条件 / 时机 / 被禁锢 / 同回合一次）
func _invoke_candidate_ok(c: CardData, allowed_timings: Array, pid: int) -> bool:
	if c == null or c.invocation.is_empty():
		return false
	if c.imprisoned:
		return false                 # 被禁锢：不响应瞬念召唤
	if not c.has_invocation():
		return false                 # 没有合法的量 + 比较符 = 没配
	var is_spell := int(c.card_type) == CardData.CardType.SPELL
	if not c.is_board_card() and not is_spell:
		return false
	if not allowed_timings.has(c.invoke_timing()):
		return false
	if _invoked.get(_invoke_key(pid, c.id), -1) == turn_count:
		return false
	return true


## 己方**有没有空置格**给这张卡落脚：随从 / 护符看 7 个战场格，城邦看城邦格。
func _invoke_has_room(pid: int, card: CardData) -> bool:
	if card.is_city():
		return city_slot_unit(pid) == null
	return board_size_used(pid) < BOARD_LIMIT


## 瞬念召唤的「基础机制」：应召上场（且结算完瞬念召唤效果）之后，这张卡留在哪里。
##   KEEP / HAND / GRAVEYARD 三种直接结算；CHOOSE → 挂在场上等玩家选（不选就是留场）。
func _apply_invoke_destination(pid: int, u: BoardUnit, dest: int) -> void:
	if u == null:
		return
	match dest:
		CardData.InvokeDest.HAND:
			_log("  瞬念召唤基础机制：返回手牌")
			return_unit_to_hand(u)
		CardData.InvokeDest.GRAVEYARD:
			_log("  瞬念召唤基础机制：进入墓地")
			_send_unit_to_graveyard(u)
		CardData.InvokeDest.CHOOSE:
			# 只有本机玩家（PLAYER_ID）才弹选择；AI / 对手不打断对局，默认留在场上
			if pid == PLAYER_ID:
				pending_invoke_choice = {"pid": pid, "unit_id": u.unit_id}
				_log("  瞬念召唤基础机制：等待玩家选择（留在场上 / 返回手牌 / 进入墓地）")
				invoke_choice_requested.emit(pid, u.unit_id)
			else:
				_log("  瞬念召唤基础机制：留在场上（对手由引擎默认处理）")
		_:
			_log("  瞬念召唤基础机制：留在场上")


## 把一个**已经在场上**的单位收进墓地（不触发亡语：它是「消失式离场」之外的普通移除，
## 与瞬念召唤的「进入墓地」基础机制一致）
func _send_unit_to_graveyard(u: BoardUnit) -> void:
	if u == null:
		return
	var owner := get_player(u.owner_id)
	if owner == null:
		return
	owner.remove_unit(u)
	owner.note_grave_entered(u.data)
	_notify_leave(u)
	u.strip_granted()


## 一张卡离场（死亡 / 回手 / 进墓地 / 消失）时通知主战者效果：
## 这张卡自己的「离场」赋予时机 + 主战者侧「N 费卡离场」的监听。
## 所有离场路径都要走这里，否则「离场时赋予」会漏掉回手 / 进墓地这条。
func _notify_leave(u: BoardUnit) -> void:
	if u == null or u.data == null:
		return
	# 离场计数：死亡 / 回手 / 进墓地 / 消失都算离场（与「被破坏」的 units_died_* 分开）
	var owner := get_player(u.owner_id)
	if owner != null:
		owner.note_unit_left()
	# 被禁锢：离场能力不发动（离场本身照样计入上面的离场数）
	if u.data.imprisoned:
		_log("「%s」被禁锢：不发动退场能力" % u.data.card_name)
		return
	# 「离场能力不受沉默影响」：这里**不检查** keywords / 是否被沉默 —— 沉默只清词条与身材，
	# 亡语与离场触发照常结算（见 _trigger_deathrattle / CardTriggers）。
	LeaderEffects.grant(self, u.owner_id, u.data, LeaderEffects.GRANT_LEAVE)
	LeaderEffects.fire(self, u.owner_id, LeaderEffects.ON_LEAVE, u.data)
	# 卡牌触发效果：离场（死亡 / 回手 / 进墓地 / 消失式移除）。
	# 这里**不**做死亡收尾：本函数本身就在 _cleanup_deaths 的循环里被调用，
	# 触发链打死的单位由那一层循环接着处理（避免递归重入）。
	CardTriggers.fire_unit(self, u.owner_id, u, CardTriggers.EV_LEAVE)


## 玩家选好了瞬念召唤的去向（界面三选一之后调用）。返回是否真的执行了。
func resolve_invoke_choice(dest: int) -> bool:
	if pending_invoke_choice.is_empty():
		return false
	var uid := int(pending_invoke_choice.get("unit_id", -1))
	pending_invoke_choice = {}
	var u := find_unit(uid)
	if u == null:
		state_changed.emit()
		return false
	# 只允许 KEEP / HAND / GRAVEYARD 三种（CHOOSE 不能再选一次）
	_apply_invoke_destination(u.owner_id, u, dest)
	state_changed.emit()
	return true


## 「同名卡一回合一次」的 key：卡牌 id（对应 SV 的 same_base_card_id），
## 用 id 而不是显示名 —— 改一下卡面名字不该让这条限制失效。
func _invoke_key(pid: int, card_id: String) -> String:
	return "%d|%s" % [pid, card_id]


## 抬高某一方**全部**手牌的费用：加在这些卡实例上。
##   * `duration` = 0（缺省）：永久，与老卡表一致的口径 —— 一直持续到它们被打出去；
##   * `duration` = N > 0：限时版 —— 到这一方**第 N 个回合结束时**自动把这笔费用还回去，
##     已经被打出（已经不在手上）的那些卡自然不受还原影响。
## 传入负值就是「手牌费用减少」，两个方向都支持。
func raise_hand_cost(pid: int, amount: int, duration: int = 0) -> int:
	var p := get_player(pid)
	if p == null or amount == 0:
		return 0
	if p.hand.is_empty():
		_log("%s 手上没有牌，费用不受影响" % p.display_name)
		return 0
	var touched: Array[CardData] = []
	for c in p.hand:
		c.cost = maxi(0, int(c.cost) + amount)
		touched.append(c)
	_log("%s 的手牌费用 %+d（%d 张）%s" % [p.display_name, amount, p.hand.size(),
		"" if duration <= 0 else "，持续到它的第 %d 个回合结束" % duration])
	if duration > 0:
		_expiries.append({
			"kind": "hand_cost",
			"pid": pid,
			"amount": amount,
			"cards": touched,
			"expire_turns": p.turns_taken + duration,
		})
	return p.hand.size()


## 限时负累的登记册：{"kind", "pid", "amount", "cards", "expire_turns"}。
## 到期由 `_end_of_turn()` 统一回滚；回合数记的是**受影响那一方自己的**回合数，对手抢不走。
var _expiries: Array = []


## 回合结束：把到期的限时负累还原（到期仍在手上的那些卡）
func _expire_durations(pid: int) -> void:
	var p := get_player(pid)
	if p == null or _expiries.is_empty():
		return
	var keep: Array = []
	for e in _expiries:
		if int(e.get("pid", -1)) != pid or p.turns_taken < int(e.get("expire_turns", 0)):
			keep.append(e)
			continue
		var amount: int = int(e.get("amount", 0))
		var restored := 0
		for c in e.get("cards", []):
			if not (c is CardData):
				continue
			if p.hand.has(c):                # 已经被打出的卡不用管
				c.cost = maxi(0, int(c.cost) - amount)
				restored += 1
		_log("%s 的手牌费用恢复了 %+d（%d 张）" % [p.display_name, -amount, restored])
	_expiries = keep


## 把一个单位的 N 份副本召唤上场（放在自动空位）。战场满了就停手（多出来的不会死，直接不算），返回实际召唤数。
func summon_copies(pid: int, source: BoardUnit, count: int) -> int:
	if source == null or count <= 0:
		return 0
	var n := 0
	for _i in count:
		var u := summon_unit(pid, source.data.clone())
		if u == null:
			break
		n += 1
	if n > 0:
		_log("复制「%s」%d 份上场" % [source.data.card_name, n])
	return n


## 把一个单位的 N 份副本随机洗进某一方的牌库，返回实际洗入的张数。
func copy_unit_to_deck(pid: int, source: BoardUnit, count: int) -> int:
	if source == null:
		return 0
	return _insert_deck_copies(pid, source.data, count)


## 随机把来源一方的 N 张手牌各复制一份，洗进目标一方的牌库（来源手牌本身不动）。
func copy_hand_cards_to_deck(pid: int, from_pid: int, count: int) -> int:
	var target_p := get_player(pid)
	var from_p := get_player(from_pid)
	if target_p == null or from_p == null or count <= 0:
		return 0
	if from_p.hand.is_empty():
		_log("%s 手上没有牌可以复制" % from_p.display_name)
		return 0
	var picks: Array[CardData] = []
	var used := {}
	while picks.size() < count and used.size() < from_p.hand.size():
		var i: int = randi() % from_p.hand.size()
		if used.has(i):
			continue
		used[i] = true
		picks.append(from_p.hand[i])
	var n := 0
	for c in picks:
		n += _insert_deck_copies(pid, c, 1)
	if n > 0:
		_log("%s 的牌库里洗入了来自%s手牌的 %d 张副本" % [target_p.display_name, from_p.display_name, n])
	return n


## 把同一张卡的 N 份副本插进牌库（每份都单独随机位置，互相不一定相邻）
func _insert_deck_copies(pid: int, card: CardData, count: int) -> int:
	var p := get_player(pid)
	if p == null or card == null or count <= 0:
		return 0
	for _i in count:
		p.deck.insert(_random_deck_index(p.deck.size()), card.clone())
	if count > 0:
		_log("%s 的牌库里洗入了 %d 张「%s」的副本" % [p.display_name, count, card.card_name])
	return count


## 插入位置：0..size（size = 追加到尾部），空牌库 → 0
func _random_deck_index(size: int) -> int:
	if size <= 0:
		return 0
	return randi() % (size + 1)


## 在某一方的牌库里按口径找一张卡：找不到返回 null（不改动牌库）。
## `filter_kind` 见 EffectContext.DECK_FILTER_*；ID 口径不限类型，另外两种只认随从
## （把城邦 / 护符随机拉上场会让场面变得很难预期，需要的话就用指定 ID 口径）。
## 在**某一个区域**（牌库 / 墓地）里按口径找一张卡：找不到返回 null（不改动那个区域）。
## `filter_kind` 见 EffectContext.DECK_FILTER_*；ID 口径不限类型，另外两种只认随从
## （把城邦 / 护符随机拉上场会让场面变得很难预期，需要的话就用指定 ID 口径）。
func find_card_in(list: Array, filter_kind: int, value: int, token_id: String) -> CardData:
	if filter_kind == EffectContext.DECK_FILTER_ID:
		if token_id == "":
			return null
		for c in list:
			if c is CardData and str(c.id) == token_id:
				return c
		return null
	var pool: Array[CardData] = []
	for c in list:
		if not (c is CardData) or not c.is_minion():
			continue
		if filter_kind == EffectContext.DECK_FILTER_COST and int(c.cost) > value:
			continue
		pool.append(c)
	if pool.is_empty():
		return null
	return pool[randi() % pool.size()]


func find_deck_card(pid: int, filter_kind: int, value: int, token_id: String) -> CardData:
	var p := get_player(pid)
	if p == null:
		return null
	return find_card_in(p.deck, filter_kind, value, token_id)


## 按「来源限定」找一个再找个托管位置，返回 {"card": CardData, "from": 区域 int}
## —— 0 = 牌库，1 = 墓地。`SRC_DECK_FIRST` 时牌库找不到就再翻墓地（与城邦格的口径一致）。
func _find_card_with_source(pid: int, filter_kind: int, value: int, token_id: String,
		source: int) -> Dictionary:
	var p := get_player(pid)
	if p == null:
		return {}
	var order: Array[int] = []
	match source:
		EffectContext.SRC_GRAVE:
			order = [EffectContext.SRC_GRAVE]
		EffectContext.SRC_DECK_FIRST:
			order = [EffectContext.SRC_DECK, EffectContext.SRC_GRAVE]
		_:
			order = [EffectContext.SRC_DECK]
	for src in order:
		var list: Array = p.deck if src == EffectContext.SRC_DECK else p.graveyard
		var c := find_card_in(list, filter_kind, value, token_id)
		if c != null:
			return {"card": c, "from": src}
	return {}


## 检索一张符合口径的卡并召唤上场（瞬念召唤式呼唤）。
## `source` 决定去哪儿翻牌：牌库 / 墓地（亡招）/ 牌库优先；找到的那张**真的离开原所在地**
## （墓地里的会被亡招出来，与城邦格的兜底规则同一套口径）。
## `temporary` = 临时登场：拥有者**下一个自己的回合结束时**回到手牌，
## 期间它照常占格子、可被指定 / 被攻击，被打死了自然就没有召回这一步。
func summon_from_source(pid: int, filter_kind: int, value: int, token_id: String,
		source: int, temporary: bool) -> BoardUnit:
	var p := get_player(pid)
	if p == null:
		return null
	var hit := _find_card_with_source(pid, filter_kind, value, token_id, source)
	var card: CardData = hit.get("card", null)
	if card == null:
		var names: Array = EffectContext.SOURCE_NAMES
		_log("%s 的%s里没有符合条件的卡（口径 %d，数值 %d，指定卡「%s」）" % [
			p.display_name, str(names[source]) if source >= 0 and source < names.size() else str(source),
			filter_kind, value, token_id])
		return null
	var from: int = int(hit.get("from", EffectContext.SRC_DECK))
	var list: Array = p.deck if from == EffectContext.SRC_DECK else p.graveyard
	var where := "牌库" if from == EffectContext.SRC_DECK else "墓地"
	if not card.is_city() and board_size_used(pid) >= BOARD_LIMIT:
		_log("战场已满，「%s」留在%s里" % [card.card_name, where])
		return null
	if not _remove_one(list, card):
		return null
	# 从牌堆里翻出来的：同样先洗掉它在牌堆里攒下的卡面改动（见 _clean_deck_card）；
	# 墓地（亡招）那一侧仍用原来的卡对象，不做这一步。
	var out: CardData = _clean_deck_card(card) if from == EffectContext.SRC_DECK else card
	var u := summon_unit(pid, out)
	if u == null:
		list.append(card)            # 没安置成功就把卡放回原处，不做无谓的消耗
		return null
	_log("%s 从%s中召唤出「%s」" % [p.display_name, where, card.card_name])
	if temporary:
		u.recall_turn = turn_count + 2
		_log("  「%s」是临时召唤：它的下一个回合结束时会回到%s的手牌" % [
			card.card_name, p.display_name])
	return u


## 从牌库检索一张符合口径的卡并召唤上场（来源限定 = 牌库）
func summon_from_deck(pid: int, filter_kind: int, value: int, token_id: String,
		temporary: bool) -> BoardUnit:
	return summon_from_source(pid, filter_kind, value, token_id, EffectContext.SRC_DECK, temporary)


## 把随从移回其拥有者的手牌（手牌已满则销毁）
func return_unit_to_hand(u: BoardUnit) -> void:
	if u == null:
		return
	var owner := get_player(u.owner_id)
	if owner == null:
		return
	owner.board.erase(u)
	if owner.hand.size() >= HAND_LIMIT:
		owner.note_grave_entered(u.data)
		_log("「%s」回到手牌时手牌已满，被销毁" % u.data.card_name)
	else:
		owner.hand.append(u.data)
		_log("「%s」回到%s的手牌" % [u.data.card_name, owner.display_name])
	_notify_leave(u)
	# 赋予来的技能 / 能力不跟着回手
	u.strip_granted()


## 回合结束（含 AI 回合）：把到期的「临时召唤」单位召回手牌。
## 只对**正在结束回合的这一方**的单位生效，所以对手救不了你场上到期的临时单位。
func _end_of_turn(pid: int) -> void:
	var p := get_player(pid)
	if p == null:
		return
	var due: Array[BoardUnit] = []
	for u in p.board:
		if u == null or not u.is_alive():
			continue
		if u.recall_turn >= 0 and turn_count >= u.recall_turn:
			due.append(u)
	for u in due:
		_log("临时召唤到期：「%s」回到%s的手牌" % [u.data.card_name, p.display_name])
		return_unit_to_hand(u)
	# 限时负累（例如「手牌费用 +2，持续 2 回合」）在同一时间点到期
	_expire_durations(pid)
	# 瞬念召唤（回合结束的检查点）：同样只替正在结束回合的这一方判定。
	if game_active():
		_invoke_checkpoint(pid, [InvokeConditions.TIME_SELF_TURN_END])
	# 卡牌触发效果：我方回合结束时（场上的卡各结算一次，只替正在结束回合的这一方）
	_fire_board_triggers(pid, CardTriggers.EV_TURN_END)
	# 主战者效果：「我方回合结束时」的那批（只替正在结束回合的这一方结算）
	LeaderEffects.fire(self, pid, LeaderEffects.ON_TURN_END)
	state_changed.emit()


# ------------------------------ 攻击 ------------------------------

func get_valid_attack_targets(pid: int, unit_id: int) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var attacker := get_unit(pid, unit_id)
	if attacker == null or not game_active():
		return res
	if not attacker.can_attack(turn_count, true) and not attacker.can_attack(turn_count, false):
		return res

	var foe := get_foe(pid)
	var taunts: Array[BoardUnit] = []
	var foe_view: Array[BoardUnit] = []
	for u in unit_order(pid):
		if u.owner_id != pid:
			foe_view.append(u)
	for u in foe_view:
		if u.is_taunt() and Mechanics.can_be_targeted(u, pid):
			taunts.append(u)
	if taunts.size() > 0:
		for u in taunts:
			res.append({"kind": "unit", "unit_id": u.unit_id, "player_id": foe.player_id})
		return res

	for u in foe_view:
		if Mechanics.can_be_targeted(u, pid):
			res.append({"kind": "unit", "unit_id": u.unit_id, "player_id": foe.player_id})
	if attacker.can_attack(turn_count, false):
		res.append({"kind": "hero", "unit_id": -1, "player_id": foe.player_id})
	return res


func attack(pid: int, unit_id: int, target_unit_id: int = -1, target_player_id: int = -1) -> bool:
	if not game_active() or busy or current_player != pid:
		return false
	var attacker := get_unit(pid, unit_id)
	if attacker == null:
		return false
	var targets := get_valid_attack_targets(pid, unit_id)
	if not _contains_target(targets, target_unit_id, target_player_id):
		var why := "该随从无法攻击此目标"
		if attacker.in_front:
			why = "横置在格子里的随从无法攻击（受伤后会退回后排）"
		elif target_unit_id >= 0 and _has_taunt(1 - pid):
			why = "必须先攻击具有嘲讽的随从"
		elif not attacker.can_attack(turn_count, true):
			why = "该随从本回合无法攻击（刚上场 / 攻击次数已用尽）"
		_log(why)
		return false

	if target_unit_id >= 0:
		var defender := find_unit(target_unit_id)
		if defender == null:
			return false
		_log("「%s」攻击「%s」" % [attacker.data.card_name, defender.data.card_name])
		# 同时结算伤害：走统一的伤害管线，机制（吸血 / 剧毒 / 未来新增）在这里被派发。
		# `is_attack = true`：只有**随从的碰撞攻击**才会把防御格里的随从打出来（见伤害管线注释）。
		var dealt := deal_damage_to_unit(attacker, defender, attacker.attack, true)
		var back := deal_damage_to_unit(defender, attacker, defender.attack, true)
		var collision_immune: bool = Mechanics.flag(attacker, Mechanics.FLAG_IMMUNE_COLLISION_DAMAGE) \
			or Mechanics.flag(defender, Mechanics.FLAG_IMMUNE_COLLISION_DAMAGE)
		if dealt > 0:
			_log("  造成 %d 点伤害" % dealt)
		elif collision_immune:
			_log("  碰撞免疫：未造成伤害")
		else:
			_log("  敌方圣盾被击破，未造成伤害")
		if defender.attack <= 0:
			pass
		elif back > 0:
			_log("  受到 %d 点反击伤害" % back)
		elif collision_immune:
			_log("  碰撞免疫：未受到反击伤害")
		else:
			_log("  我方圣盾被击破，未受到反击伤害")
	else:
		_log("「%s」攻击%s英雄" % [attacker.data.card_name, get_foe(pid).display_name])
		deal_damage_to_hero(attacker, target_player_id, attacker.attack, true)

	# 攻击行为本身也要派发（潜行在攻击后解除等）
	Mechanics.dispatch(attacker, "on_attack", {"gm": self, "source": attacker,
		"source_pid": pid, "target_pid": target_player_id, "amount": attacker.attack})
	unit_attacked.emit(pid, unit_id, target_unit_id, target_player_id)
	# 「攻击时」触发（影之诗的攻撃時）：伤害已经结算完，此时看到的血量是最新的
	CardTriggers.fire_unit(self, pid, attacker, CardTriggers.EV_ATTACK)

	# 声明式标志位：带 FLAG_NO_ATTACK_COST 的机制攻击不消耗本回合次数（未来「攻击不消耗次数」类机制一行注册即可）
	if not Mechanics.flag(attacker, Mechanics.FLAG_NO_ATTACK_COST):
		attacker.attacks_used += 1
	_cleanup_deaths()
	# 攻击之后也是一个检查点：「我方随从死了几个」这类条件在这里才看得见
	# （只替发起攻击的这一方判定：被打的那一方不是当前回合方）
	_invoke_checkpoint(pid)
	_check_game_over()
	state_changed.emit()
	return true


# ------------------------------ 伤害管线 ------------------------------
#
# 所有伤害都从这里走：先让来源方机制修正数值，扣血后再把事件派发给
# 来源方（吸血 / 剧毒）与承受方（激怒之类）的机制。新增机制不需要改这一段。

## 对随从造成伤害，返回**实际造成的伤害**（被圣盾挡下为 0）。
## `is_attack = true` 表示这次伤害来自**随从的碰撞攻击**（`attack()` 才会传 true）；
## 防御格（战场正中那一格）的规则靠它区分来源：
##   * **1 点以上的伤害一律限定为 1**（任何来源、任何伤害类型都封顶）；
##   * 但**只有对面随从的碰撞攻击**才能把里面的随从打出来（撤出防御格）；
##     法术 / 战吼 / 技能 / 反击等非碰撞伤害只扣 1 点血，随从**留在防御格里**。
func deal_damage_to_unit(source: BoardUnit, target: BoardUnit, amount: int, is_attack: bool = false) -> int:
	if target == null or amount <= 0:
		return 0
	var ev := {
		"gm": self,
		"source": source,
		"source_pid": source.owner_id if source != null else -1,
		"target": target,
		"target_pid": target.owner_id,
		"amount": amount,
	}
	if source != null:
		Mechanics.dispatch(source, "modify_damage", ev)
	var final_amount: int = maxi(0, int(ev["amount"]))
	# 碰撞免疫：碰撞双方**任意一张**有这个效果时，双方都受 0 点伤害（攻击主战者同理，见 deal_damage_to_hero）
	if is_attack:
		var attacker_immune: bool = source != null \
			and Mechanics.flag(source, Mechanics.FLAG_IMMUNE_COLLISION_DAMAGE)
		if attacker_immune or Mechanics.flag(target, Mechanics.FLAG_IMMUNE_COLLISION_DAMAGE):
			_log("  「%s」碰撞免疫：这次碰撞双方都不受伤害" % target.data.card_name)
			return 0
	# 术法免疫：非碰撞伤害一律 0；碰撞伤害照常，也能被“消灭”类能力破坏
	if not is_attack and Mechanics.flag(target, Mechanics.FLAG_IMMUNE_ABILITY_DAMAGE):
		_log("  「%s」术法免疫：不受 %d 点能力伤害" % [target.data.card_name, final_amount])
		return 0
	# 伤害减免：按伤害来源各扣一档（能力伤害减免 / 碰撞伤害减免），可叠加
	var reduction: int = target.collision_damage_reduction if is_attack else target.ability_damage_reduction
	if reduction > 0 and final_amount > 0:
		var before_reduce := final_amount
		final_amount = maxi(0, final_amount - reduction)
		_log("  「%s」伤害减免 %d（%d → %d）" % [
			target.data.card_name, reduction, before_reduce, final_amount])
	# 声明式标志位：免疫所有伤害 / 受到的任何伤害减为 1（横置格用的是同一个"减为 1"口径）
	if Mechanics.flag(target, Mechanics.FLAG_IMMUNE):
		if final_amount > 0:
			_log("  「%s」免疫伤害（本应受到 %d 点）" % [target.data.card_name, final_amount])
		return 0
	if Mechanics.flag(target, Mechanics.FLAG_ONLY_ONE_DAMAGE) and final_amount > 1:
		final_amount = 1
	# 防御格：**1 点以上的伤害一律限定为 1**（不管来源是随从碰撞、法术、战吼还是技能）
	if target.in_front and final_amount > 1:
		final_amount = 1
	var dealt: int = final_amount if target.take_damage(final_amount) else 0
	if dealt > 0:
		amount_shown.emit(target.owner_id, target.unit_id, dealt, "damage")
	ev["amount"] = dealt
	Mechanics.dispatch(target, "on_damaged", ev)
	if source != null and dealt > 0:
		Mechanics.dispatch(source, "on_damage_dealt", ev)
	# 「受到伤害时」触发（影之诗的ダメージを受けた時）：只有真的掉血才结算
	if dealt > 0:
		CardTriggers.fire_unit(self, target.owner_id, target, CardTriggers.EV_DAMAGED)
	# 只有**对面随从的碰撞攻击**才会把防御格里的随从打出来：
	#   * 攻击方必须是随从（护符 / 城邦不能攻击，这里再兜一层）；
	#   * 真的造成了伤害（圣盾 / 免疫挡下时为 0，那就留在防御格里）；
	#   * 法术 / 战吼 / 技能 / 反击等非碰撞伤害一律不撤出，只记一条说明。
	if dealt > 0 and target.in_front:
		var from_minion_attack: bool = is_attack and source != null and not source.is_permanent()
		if from_minion_attack:
			target.in_front = false
			_log("  「%s」被随从的碰撞攻击打中，撤出防御格" % target.data.card_name)
		else:
			_log("  「%s」在防御格里只受 1 点伤害；非随从碰撞，不会撤出防御格" % target.data.card_name)
	# 扣血后一定要通知界面：卡面上的生命宝石 / 状态计数要跟着变（界面按帧合并，不会重复重建）
	state_changed.emit()
	return dealt


## 对英雄造成伤害，返回**实际造成的伤害**（护甲吸收后剩下的部分）
## `is_attack = true`：这次是**随从碰撞攻击英雄**（碰撞免疫只在这一种伤害上生效）
func deal_damage_to_hero(source: BoardUnit, target_pid: int, amount: int,
		is_attack: bool = false) -> int:
	if amount <= 0:
		return 0
	if is_attack and source != null \
			and Mechanics.flag(source, Mechanics.FLAG_IMMUNE_COLLISION_DAMAGE):
		_log("  「%s」碰撞免疫：攻击英雄也不造成伤害" % source.data.card_name)
		return 0
	var ev := {
		"gm": self,
		"source": source,
		"source_pid": source.owner_id if source != null else -1,
		"target": null,
		"target_pid": target_pid,
		"amount": amount,
	}
	if source != null:
		Mechanics.dispatch(source, "modify_damage", ev)
	var dealt: int = damage_player(target_pid, maxi(0, int(ev["amount"])))
	ev["amount"] = dealt
	if source != null and dealt > 0:
		Mechanics.dispatch(source, "on_damage_dealt", ev)
	return dealt


func _has_taunt(pid: int) -> bool:
	var p := get_player(pid)
	if p == null:
		return false
	for u in board_units(pid):
		if u.is_taunt():
			return true
	return false


# ------------------------------ 横置格（中线前的那一格） ------------------------------
#
# 规则：进格子的随从只受 1 点伤害、不能发动主动行为（攻击 / 主动技能）、
# 敌方用技能指定这一侧的随从时只能选它；受伤后自动退回后排并失去横置效果。
# 随从自身的战吼 / 亡语 / 关键字不受影响（它仍然在 p.board 里，所有既有流程都照旧）。
#
# 与「定长格子」并存的口径（不变式）：**横置格 = 战场正中那一格（PlayerState.FRONT_SLOT）**，
#   * `in_front == true` 的单位一定在正中格里；把它换到别的格子会清掉 in_front；
#   * 放进正中格的随从才有资格横置：`play_card(..., to_front=true)` / 拖到正中格、
#     `place_in_front()` 都会把单位**移动**到那一格；正中格原有的单位先退回后排（不移动其它格）。

## 这一侧横置格里的随从（同时只允许一个）
func front_unit(pid: int) -> BoardUnit:
	var p := get_player(pid)
	if p == null:
		return null
	var at_front := board_slot(pid, PlayerState.FRONT_SLOT)
	if at_front != null and at_front.in_front:
		return at_front
	for u in board_units(pid):
		if u.in_front:
			return u
	return null


func has_front_unit(pid: int) -> bool:
	return front_unit(pid) != null


## 把一个随从放进它自己一侧的防御格（原横置格；原来在正中的那个先退回后排）。双方都能用。
## 为了让「只有正中格里的随从才是防御态」恒成立，这里会把单位**移动**到正中格。
##
## 门禁（用户要求）：**只能在自己的回合调整**，而且**移入 / 移出共用一个名额、一回合只能用一次**。
func place_in_front(pid: int, unit_id: int) -> bool:
	var target := find_unit(unit_id)
	if target == null or target.owner_id != pid or not target.is_alive():
		return false
	if target.in_city_slot:
		return false
	if target.in_front:
		return true                     # 已经在防御格里：不算一次调整、不吃名额
	var p := get_player(pid)
	if p == null:
		return false
	if not can_move_front(pid):
		_log(front_move_blocked_reason(pid))
		return false
	_clear_front(pid)
	var occupant := board_slot(pid, PlayerState.FRONT_SLOT)
	if occupant != null and occupant != target:
		_evacuate_front_slot(pid)
	if slot_of_unit(target) != PlayerState.FRONT_SLOT:
		if not place_unit_at(pid, target, PlayerState.FRONT_SLOT):
			return false
	target.in_front = true
	p.front_move_turn = turn_count       # 用掉本回合唯一的「调整防御格」名额
	_log("「%s」移入防御格：只受 1 点伤害、无法攻击 / 无法发动技能；只有被对面随从碰撞攻击才会撤出" % target.data.card_name)
	state_changed.emit()
	return true


## 把防御格里的随从**移出**到后排（用户要求的第二个动作，与移入共用同一名额）。
## `to_slot` 给定且空着就放那儿；否则放第一个空的后排格；后排没有空位 → 失败且**不消耗名额**。
func leave_front(pid: int, unit_id: int, to_slot: int = -1) -> bool:
	var target := find_unit(unit_id)
	if target == null or target.owner_id != pid or not target.is_alive() or not target.in_front:
		return false
	var p := get_player(pid)
	if p == null:
		return false
	if not can_move_front(pid):
		_log(front_move_blocked_reason(pid))
		return false
	var dest := -1
	if to_slot >= 0 and to_slot < BOARD_LIMIT and to_slot != PlayerState.FRONT_SLOT \
			and board_slot(pid, to_slot) == null:
		dest = to_slot
	else:
		dest = _first_empty_back_slot(pid)
	if dest < 0:
		_log("后排没有空位，「%s」暂时移不出防御格（本次不算调整，名额还在）" % target.data.card_name)
		return false
	target.in_front = false
	if not place_unit_at(pid, target, dest):
		target.in_front = true          # 放不进去就还原，别让状态半途而废
		return false
	p.front_move_turn = turn_count
	_log("「%s」移出防御格，回到后排第 %d 格" % [target.data.card_name, dest + 1])
	state_changed.emit()
	return true


## 本回合还能不能调整防御格（自己的回合 + 本回合还没用过名额）
func can_move_front(pid: int) -> bool:
	return front_move_blocked_reason(pid) == ""


## 为什么现在不能调整防御格（可用 → ""；否则中文原因，界面直接拿去提示）
func front_move_blocked_reason(pid: int) -> String:
	if not game_active():
		return "对局已经结束，不能再调整防御格"
	if busy:
		return "敌方（AI）正在行动，暂时不能调整防御格"
	if net_locked:
		return "观战 / 快照未到时不能调整防御格"
	var p := get_player(pid)
	if p == null:
		return "找不到玩家"
	if current_player != pid:
		return "只能在自己的回合调整防御格（移入或移出，一回合一次）"
	if p.front_move_turn == turn_count:
		return "本回合已经调整过防御格了：移入与移出共用一个名额，一回合只能用一次"
	return ""


## 把正中格让出来：里面原来的单位退回第一个空的后排格（空位保留、其它格不动）。
## 对应老口径「原来在格里的先退回后排」。
func _evacuate_front_slot(pid: int) -> void:
	var occupant := board_slot(pid, PlayerState.FRONT_SLOT)
	if occupant == null:
		return
	var free := _first_empty_back_slot(pid)
	if free < 0:
		return                                   # 后排没有空位（战场已满）：保持原样
	occupant.in_front = false
	place_unit_at(pid, occupant, free)
	_log("  正中的格子让出来，「%s」退回后排第 %d 格" % [occupant.data.card_name, free + 1])


## 第一个空着的**后排**格子（不含正中格；没有 → -1）
func _first_empty_back_slot(pid: int) -> int:
	for i in BOARD_LIMIT:
		if i == PlayerState.FRONT_SLOT:
			continue
		if board_slot(pid, i) == null:
			return i
	return -1


## 清空某一侧的横置格（随从本身留在战场上，只是退回后排）
func _clear_front(pid: int) -> void:
	var p := get_player(pid)
	if p == null:
		return
	for u in board_units(pid):
		u.in_front = false


# ------------------------------ 城邦格（主战者旁） ------------------------------
#
# 规则：主战者旁有一个「城邦格」，**不占 7 格战场**，里面最多放一个城邦。
#   * 每 3 个自己的回合判定一次（第 3 / 6 / 9… 个自己的回合开始时）；
#   * 格子里空着时：先从**牌堆**里随机召唤一个城邦（从牌堆移出），牌堆没有就从**墓地**里召唤（从墓地移出）；
#   * 牌堆与墓地都没有 → 这个回合不召唤；
#   * 同一回合只会召唤一次（不会因为别的时机再来一次）。
# 格子里的城邦与普通城邦一样有耐久、可被指定 / 被攻击 / 被摧毁（摧毁后进墓地，之后可以再被召唤回来）。

## 城邦格里的城邦（没有则 null）
func city_slot_unit(pid: int) -> BoardUnit:
	var p := get_player(pid)
	if p == null:
		return null
	for u in p.board:
		if u.in_city_slot:
			return u
	return null


# ------------------------------ 战场格子 API ------------------------------
#
# 战场是**定长 7 格**（BOARD_LIMIT），空位用 null 保留：随从死亡后它那一格空着，
# 其它随从**不移动**，下一位随从可以补进这个空位（与原版《影之诗》的连续排列不同，
# 这是明确选定的规则）。格子数据在 PlayerState.slots，`board` 是紧凑的场地名单，
# 两者由 PlayerState.sync_slots() 自动对账（旧代码直接读写 board 仍然成立）。

## 某一方第 slot 格里的单位（越界 / 空位 → null）
func board_slot(pid: int, slot: int) -> BoardUnit:
	var p := get_player(pid)
	if p == null:
		return null
	p.sync_slots()
	return p.slot_at(slot)


## 某一方第一个空位的格子号（没有空位 → -1）
func first_empty_slot(pid: int) -> int:
	var p := get_player(pid)
	if p == null:
		return -1
	p.sync_slots()
	return p.first_empty_slot()


## 把单位放进某一方第 slot 格：越界 / 该格已被占用 → false（不会挤掉别人）
func place_unit_at(pid: int, unit: BoardUnit, slot: int) -> bool:
	var p := get_player(pid)
	if p == null or unit == null:
		return false
	if slot < 0 or slot >= BOARD_LIMIT:
		return false
	if not p.place_unit_at(unit, slot):
		return false
	# 不变式：只有正中格（横置格）里的随从才允许保持 in_front
	if unit.in_front and slot != PlayerState.FRONT_SLOT:
		unit.in_front = false
	state_changed.emit()
	return true


## 单位在第几格（找不到 / 城邦格里的城邦 → -1）
func slot_of_unit(unit: BoardUnit) -> int:
	if unit == null:
		return -1
	for p in players:
		if p != null and p.board.has(unit):
			p.sync_slots()               # 旧代码可能刚直接 append 过 board
			return p.slot_of(unit)
	return -1


## 按**格子顺序**返回某一方战场上的单位（跳过空位；城邦格里的城邦不计）
func board_units(pid: int) -> Array[BoardUnit]:
	var p := get_player(pid)
	if p == null:
		return []
	p.sync_slots()
	return p.units_in_slot_order()


## 结算顺序 / 目标列表用：格子顺序的战场单位，外加城邦格里的城邦（它没有格子，排在最后）。
## 城邦必须留在这里——它照旧可被指定 / 被攻击 / 被群体效果命中。
func board_units_in_order(pid: int) -> Array[BoardUnit]:
	var p := get_player(pid)
	if p == null:
		return []
	p.sync_slots()
	return p.units_in_order()


## 一个玩家「占用了战场格」的单位数（= 真实随从数；城邦格不计入 7 格上限）。
## 语义与改动前一致：空位不算，城邦不算。
func board_size_used(pid: int) -> int:
	var p := get_player(pid)
	if p == null:
		return 0
	p.sync_slots()
	return p.used_count()


## 把一张城邦卡放进城邦格（不占战场格子）。格子已占用 / 不是城邦则失败。
## 这里**不结算安放（入场）效果**：每 3 回合判定自动召唤、以及所有召唤路径都不结算入场效果，
## 只有「从手牌打出」和卡牌效果「触发一次入场效果」会结算。
func summon_city_into_slot(pid: int, card: CardData, from_where: String = "") -> BoardUnit:
	var p := get_player(pid)
	if p == null or card == null or not card.is_city():
		return null
	if card.imprisoned:
		_log("「%s」被禁锢，无法召唤" % card.card_name)
		return null
	if city_slot_unit(pid) != null:
		return null
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, turn_count, _next_unit_id)
	_next_unit_id += 1
	u.attack = 0
	u.max_health = card.durability()
	u.health = card.durability()
	u.in_city_slot = true
	# 城邦住在 `board` 名单里（这样才能像以前一样被指定 / 被攻击 / 被结算），
	# 但它**不占** slots 的 7 个战场格（PlayerState.sync_slots / units_in_slot_order 会跳过它）。
	p.board.append(u)
	_log("%s 的城邦格里%s「%s」（耐久 %d）" % [
		p.display_name, from_where, card.card_name, u.health])
	return u


## 每 3 个自己的回合判定一次：先牌堆、再墓地、都没有就不召唤
func _try_city_slot(pid: int) -> bool:
	var p := get_player(pid)
	if p == null:
		return false
	if city_slot_unit(pid) != null:
		return false
	# 同一回合不进行第二次召唤
	if p.city_summon_turn == turn_count:
		return false
	var pool: Array[CardData] = []
	for c in p.deck:
		if c.is_city():
			pool.append(c)
	var from_where := "从牌堆中召唤出"
	if pool.is_empty():
		for c in p.graveyard:
			if c.is_city():
				pool.append(c)
		from_where = "从墓地中召唤出"
	if pool.is_empty():
		_log("%s 的城邦格：牌堆与墓地都没有城邦，这个回合不召唤" % p.display_name)
		return false
	var pick: CardData = pool[randi() % pool.size()]
	# 从原来的地方移出（牌堆优先，其次墓地）
	var moved := false
	if from_where == "从牌堆中召唤出":
		moved = _remove_one(p.deck, pick)
	else:
		moved = _remove_one(p.graveyard, pick)
	if not moved:
		return false
	var unit := summon_city_into_slot(pid, pick, from_where)
	if unit != null:
		p.city_summon_turn = turn_count
		# 卡牌触发效果：城邦被规则召唤入场（从手牌打出那次由 play_card 走「入场（打出）」）
		_fire_unit_trigger(pid, unit, CardTriggers.EV_SUMMON)
		return true
	return false


## 从数组里移除一个「同一张卡」的实例（按 id 找，避免克隆体引用不同）
func _remove_one(list: Array, card: CardData) -> bool:
	for i in list.size():
		if list[i].id == card.id:
			list.remove_at(i)
			return true
	return false


# ------------------------------ 目标选取 ------------------------------

## 一张牌在当前局面下所有合法目标。
## `_minion_targets` 会按机制（潜行 / 魔免等）过滤掉敌方不可指定的随从。
## 效果链上的卡：把链里**每一条需要选目标的效果**的目标取并集（按链顺序、去重），
## 这样玩家选中的那个目标只要对链里任意一条合法就能出牌，链里的其它条目再自动选目标。
## 老卡（只有 target 字段）的链就是那一条，取并集后的结果与改动前逐字一致。
func get_valid_targets(pid: int, card: CardData) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	if not card.needs_target():
		return res
	for kind in card.effect_target_kinds():
		res = _merge_targets(res, _targets_for_kind(pid, kind))
	return res


## 某一种目标类型在当前局面下的合法目标（顺序确定：敌方随从 → 我方随从 → 敌方英雄 → 我方英雄）
func _targets_for_kind(pid: int, target_kind: int) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var me := get_player(pid)
	var foe := get_foe(pid)

	match target_kind:
		CardData.Targeting.ANY_CHARACTER:
			res += _minion_targets(foe, pid)
			res += _minion_targets(me, pid)
			res += _hero_targets(foe)
			res += _hero_targets(me)
		CardData.Targeting.ANY_MINION:
			res += _minion_targets(foe, pid)
			res += _minion_targets(me, pid)
		CardData.Targeting.ENEMY_MINION:
			res += _minion_targets(foe, pid)
		CardData.Targeting.ALLY_MINION:
			res += _minion_targets(me, pid)
		CardData.Targeting.ENEMY_HERO:
			res += _hero_targets(foe)
		CardData.Targeting.ALLY_HERO:
			res += _hero_targets(me)
	return res


## 把 more 里还没出现过的目标追加到 base（保持 base 的顺序，避免重复高亮）
func _merge_targets(base: Array[Dictionary], more: Array[Dictionary]) -> Array[Dictionary]:
	for t in more:
		if not _contains_target(base, int(t.get("unit_id", -1)), int(t.get("player_id", -1))):
			base.append(t)
	return base


func is_valid_target(pid: int, card: CardData, target_unit_id: int, target_player_id: int) -> bool:
	if not card.needs_target():
		return true
	var list := get_valid_targets(pid, card)
	return _contains_target(list, target_unit_id, target_player_id)


## `by_pid` = 想把它们指定为目标的一方；机制可以否决（潜行只挡敌方指定）。
## 横置格：敌方用**技能**指定这一侧的随从时，只能选横置格里的那一个
## （群体 / 随机效果不受此限制，它们用 by_pid = -1 调用）。
func _minion_targets(p: PlayerState, by_pid: int = -1) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	if p == null:
		return res
	if by_pid >= 0 and by_pid != p.player_id:
		var front := front_unit(p.player_id)
		if front != null:
			res.append({"kind": "unit", "unit_id": front.unit_id, "player_id": p.player_id})
			return res
	# 按格子顺序遍历（跳过空位）；含城邦格里的城邦，与改动前一致
	for u in p.units_in_order():
		if by_pid >= 0 and not Mechanics.can_be_targeted(u, by_pid):
			continue
		res.append({"kind": "unit", "unit_id": u.unit_id, "player_id": p.player_id})
	return res


func _hero_targets(p: PlayerState) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	if p == null:
		return res
	res.append({"kind": "hero", "unit_id": -1, "player_id": p.player_id})
	return res


func _contains_target(list: Array[Dictionary], unit_id: int, player_id: int) -> bool:
	for t in list:
		var t_player: int = t["player_id"]
		var t_unit: int = t["unit_id"]
		if t_player != player_id:
			continue
		if unit_id >= 0 and t_unit == unit_id:
			return true
		if unit_id < 0 and t["kind"] == "hero":
			return true
	return false


# ------------------------------ 效果结算 ------------------------------

## 把“卡牌的目标设置”解析为具体的目标列表
func _targets_for(pid: int, target_kind: int, target_unit_id: int, target_player_id: int) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	match target_kind:
		CardData.Targeting.NONE:
			res.append({"kind": "self", "unit_id": -1, "player_id": pid})
		CardData.Targeting.ALL_ENEMY_MINIONS:
			res += _minion_targets(get_foe(pid))
		CardData.Targeting.ALL_ALLY_MINIONS:
			res += _minion_targets(get_player(pid))
		_:
			res.append({"kind": "unit" if target_unit_id >= 0 else "hero",
				"unit_id": target_unit_id, "player_id": target_player_id})
	return res


## 战吼 / 法术 / 安放效果：把 card.effect_chain() 逐条按顺序结算。
## `source_unit` 是造成这次效果的随从（战吼 / 亡语 / 技能），法术为 null——
## 吸血 / 剧毒这类“由来源造成伤害”的机制靠它才能生效。
## 老卡（只有 effect_id）的链就是一条，行为与改动前逐字一致。
func _resolve_effect(pid: int, card: CardData, target_unit_id: int, target_player_id: int,
		source_unit: BoardUnit = null) -> void:
	if not card.has_effects():
		return
	_resolve_chain(pid, card, card.effect_chain(), target_unit_id, target_player_id, source_unit, false)
	state_changed.emit()


## 「入场效果」的第二个（也是唯一的另一个）结算入口：让**已经在场上**的单位再触发一次。
##
## 规则：**所有召唤入场都不结算入场效果**（衍生物 / 复制 / 亡语召唤 / 城邦格判定……），
## 入场效果只在 `play_card()` 从手牌打出时自动结算。想在召唤之后再让它结算一次，
## 只能走卡牌效果「触发一次入场效果」（trigger_entrance），即本函数 —— 别处不要抄 `_resolve_chain`。
##
## 回环保护：卡面可以把「触发入场效果」配成指向自己（或互相指对方），这里限制嵌套层数，
## 超过就直接停手，保证不会把主线程拖进无限递归。
const MAX_ENTRANCE_DEPTH := 3
var _entrance_depth: int = 0
## 主战者效果的连锁层数：效果链里再触发主战者效果时用，防止无限递归（见 LeaderEffects.fire）
var _leader_depth: int = 0
## 卡牌触发效果的连锁层数：触发链里再触发别的卡的触发时用，防止无限递归（见 CardTriggers）
var _trigger_depth: int = 0
## 随机能力池的嵌套层数：能力里再写「随机能力」时用，防止手改卡表造成无限递归
const MAX_RANDOM_DEPTH := 2
var _random_depth: int = 0


func trigger_entrance_effect(u: BoardUnit) -> bool:
	if u == null or not u.is_alive():
		return false
	var card := u.data
	# 被禁锢：入场能力不发动
	if card != null and card.imprisoned:
		_log("「%s」被禁锢：不发动入场能力" % card.card_name)
		return false
	if card == null or not card.has_effects():
		_log("「%s」没有入场效果" % (card.card_name if card != null else "该单位"))
		return false
	if _entrance_depth >= MAX_ENTRANCE_DEPTH:
		_log("  入场效果的触发层数已到上限（%d 层），本次不再继续" % MAX_ENTRANCE_DEPTH)
		return false
	_entrance_depth += 1
	_log("「%s」触发一次入场效果" % card.card_name)
	# 目标不明：每条效果按自己的默认目标自动挑（见 _resolve_entry 的「自动选择目标」日志）
	_resolve_chain(u.owner_id, card, card.effect_chain(), -1, -1, u, false)
	# 结算完可能有单位死亡（入场效果里带伤害 / 消灭），这套收尾与其它效果结算保持一致
	_entrance_depth -= 1
	_cleanup_deaths()
	state_changed.emit()
	return true


# ------------------------------ 卡牌触发效果（CardTriggers） ------------------------------
#
# 一张卡「在某个时机自动结算一条效果链」：入场（打出）/ 召唤入场 / 离场 / 瞬念召唤上场 /
# 消失 / 我方回合开始 / 我方回合结束。数据在 CardData.triggers 里，结算管线与战吼 / 亡语
# 完全相同（_resolve_chain）。
#
# 维护口径：加一个触发时机 = CardTriggers._build() 里加一行 + 在下面每个触发点各调一次
# `_fire_card_trigger` / `_fire_unit_trigger`。除此之外没有任何硬编码的效果。

## 卡牌级触发（没有场上单位可当来源：入场（法术 / 城邦）、消失）
func _fire_card_trigger(pid: int, card: CardData, event: String) -> int:
	if card == null or not card.has_triggers():
		return 0
	var fired := CardTriggers.fire_card(self, pid, card, event)
	if fired > 0:
		_cleanup_deaths()
	return fired


## 单位级触发（召唤入场 / 离场 / 瞬念召唤上场 / 回合开始·结束）：
## 把单位本身作为效果来源，吸血 / 剧毒这类「由来源造成」的机制照常生效。
func _fire_unit_trigger(pid: int, u: BoardUnit, event: String) -> int:
	if u == null or u.data == null or not u.data.has_triggers():
		return 0
	var fired := CardTriggers.fire_unit(self, pid, u, event)
	if fired > 0:
		_cleanup_deaths()
	return fired


## 让某一方场上每个存活单位各结算一次某个时机（回合开始 / 回合结束）。
## 先复制一份清单：触发链里可能召唤 / 消灭单位，边遍历边改 board 会漏算。
func _fire_board_triggers(pid: int, event: String) -> int:
	var fired := 0
	for u in board_units_in_order(pid).duplicate():
		if u == null or not u.is_alive():
			continue
		fired += _fire_unit_trigger(pid, u, event)
	return fired


# ------------------------------ 随机能力（能力池） ------------------------------
#
# 卡面效果「随机能力（能力池）」抽到一条能力后，交给这里结算：
# 把这一条能力当成**单条效果链**复用 _resolve_chain，于是目标自动选择、条件、来源
# （吸血 / 剧毒）、死亡收尾与普通效果链完全一致，不需要第二套结算代码。

## 结算一条随机能力；返回是否真的结算了
func resolve_random_ability(pid: int, card: CardData, ability: Dictionary,
		source_unit: BoardUnit, deathrattle: bool) -> bool:
	if card == null or ability.is_empty():
		return false
	var eid := str(ability.get("id", ""))
	if eid == "" or eid == CardEffects.NONE:
		return false
	if eid == CardEffects.RANDOM_POOL:
		# 池子里再放「随机能力」= 数据错误（AbilityPools.errors 也会拦），这里兜底防递归
		_log("  随机能力里不能再嵌套随机能力，本条跳过")
		return false
	if _random_depth >= MAX_RANDOM_DEPTH:
		_log("  随机能力的嵌套层数已到上限（%d 层），本次不再继续" % MAX_RANDOM_DEPTH)
		return false
	_random_depth += 1
	_resolve_chain(pid, card, [ability], -1, -1, source_unit, deathrattle)
	_random_depth -= 1
	# 能力之间可能互相影响（先打死随从，再随机消灭 / 随机强化），逐条收尾保证下一张抽到时
	# 场上已经没有“血量为 0 但还没进墓地”的单位。
	_cleanup_deaths()
	return true


# ------------------------------ 效果链结算 ------------------------------
#
# 战吼 / 法术 / 安放 / 亡语 / 主动技能都是「一条按顺序结算的效果链」：
#   * 链来自 CardData.effect_chain() / deathrattle_chain() / skill_chain()；
#   * 每条效果自己解析目标：显式 target（>= 0）优先，缺省 / -1 → CardEffects.default_target(id)；
#   * 需要选目标的效果优先用玩家这次选的目标（本体这一条合法才用），否则**自动挑第一个合法目标**
#     并记日志「自动选择目标：…」；该条没有任何合法目标 → 跳过这一条（不崩）；
#   * 群体（is_aoe / ALL_*）与“不需要目标”的效果照旧以 self 上下文结算一次；
#   * 整条链结算完只由调用方发一次 state_changed（免得界面每条都重建）。

## 逐条结算一条效果链（不负责 state_changed / 死亡结算与胜负，由调用方统一收尾）
func _resolve_chain(pid: int, card: CardData, chain: Array, target_unit_id: int,
		target_player_id: int, source_unit: BoardUnit = null, deathrattle: bool = false) -> void:
	for i in chain.size():
		var e: Variant = chain[i]
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = e
		var eid := str(entry.get("id", ""))
		if eid == "" or eid == CardEffects.NONE:
			continue                      # 空条目直接跳过（链里可以留占位）
		# 条目条件（可选）：不满足就跳过这一条，链继续往下走（例：本局某兵种进场 ≥ 3 才结算）
		var cond := EffectConditions.normalized(entry.get("cond", {}))
		if not EffectConditions.is_empty(cond) and not EffectConditions.met(self, pid, cond):
			_log("  条件不满足，跳过「%s」的第 %d 条：%s" % [
				card.card_name, i + 1, EffectConditions.text(cond)])
			continue
		_resolve_entry(pid, card, eid, _chain_value(pid, card, eid, int(entry.get("value", 0))),
			str(entry.get("token", "")), int(entry.get("target", -1)),
			int(entry.get("src", EffectContext.SRC_DECK)), int(entry.get("turns", 0)),
			target_unit_id, target_player_id, source_unit, deathrattle)


## 结算链里的一条效果；返回是否真的结算了
func _resolve_entry(pid: int, card: CardData, eid: String, value: int, token_id: String,
		raw_target: int, entry_src: int, entry_turns: int,
		target_unit_id: int, target_player_id: int,
		source_unit: BoardUnit, deathrattle: bool) -> bool:
	var self_ctx := {"kind": "self", "unit_id": -1, "player_id": pid}
	# 群体效果内部会遍历所有目标，只需结算一次；单体效果按选中的目标结算
	if CardEffects.is_aoe(eid):
		CardEffects.apply(eid, EffectContext.create(self, pid, value, token_id, self_ctx,
			card.card_name, deathrattle, source_unit, entry_src, entry_turns, card))
		return true
	var entry_target: int = raw_target if raw_target >= 0 else CardEffects.default_target(eid)
	# 卡表配置保护：单体效果被配成“不需要目标”时，不能退化成“以自己为目标”，
	# 否则 damage / heal / destroy 之类的效果会打到施法者自己或无效目标上。
	if entry_target == CardData.Targeting.NONE:
		if CardEffects.default_target(eid) != CardData.Targeting.NONE:
			_log("「%s」卡表配置有误：效果「%s」需要目标，本次不结算" % [
				card.card_name, CardEffects.display_name(eid)])
			return false
		CardEffects.apply(eid, EffectContext.create(self, pid, value, token_id, self_ctx,
			card.card_name, deathrattle, source_unit, entry_src, entry_turns, card))
		return true
	# 群体目标（ALL_*）：沿用既有口径，逐个目标各结算一次
	if entry_target == CardData.Targeting.ALL_ENEMY_MINIONS \
			or entry_target == CardData.Targeting.ALL_ALLY_MINIONS:
		var group := _targets_for(pid, entry_target, -1, -1)
		if group.is_empty():
			_log("「%s」没有合法目标" % card.card_name)
			return false
		for t in group:
			CardEffects.apply(eid, EffectContext.create(self, pid, value, token_id, t,
				card.card_name, deathrattle, source_unit, entry_src, entry_turns, card))
		return true
	# 需要选目标：优先玩家这次选的目标（这一条合法才用），否则自动挑第一个合法目标
	var valid := _targets_for_kind(pid, entry_target)
	var chosen: Dictionary = {}
	if _contains_target(valid, target_unit_id, target_player_id):
		chosen = {"kind": "unit" if target_unit_id >= 0 else "hero",
			"unit_id": target_unit_id, "player_id": target_player_id}
	elif not valid.is_empty():
		chosen = valid[0]
		_log("  自动选择目标：%s（「%s」的%s未指定，按顺序取第一个合法目标）" % [
			_target_label(chosen, pid), card.card_name,
			CardData.TARGET_NAMES.get(entry_target, str(entry_target))])
	else:
		_log("「%s」没有合法目标" % card.card_name)
		return false
	CardEffects.apply(eid, EffectContext.create(self, pid, value, token_id, chosen,
		card.card_name, deathrattle, source_unit, entry_src, entry_turns, card))
	return true


## 自动选目标时的日志文案（随从用卡名，英雄分敌我）
func _target_label(t: Dictionary, pid: int) -> String:
	var uid := int(t.get("unit_id", -1))
	if uid >= 0:
		var u := find_unit(uid)
		return "「%s」" % u.data.card_name if u != null else "随从 #%d" % uid
	return "我方英雄" if int(t.get("player_id", -1)) == pid else "敌方英雄"


# ------------------------------ 主动技能 ------------------------------
#
# 随从 / 护符 / 城邦都能配置主动技能（CardData.skill）：玩家消耗**现有能量点**（= 法力 / PP）发动，
# 默认每回合一次（用 turn_count 与 BoardUnit.skill_used_turn 比较，不需要在回合开始重置）。
#
# 与「攻击」的区别：护符 / 城邦不能攻击，但**可以**用技能——所以这里不走 can_use_active_skill()
# （那个函数的口径是“能不能攻击 / 发动主动行为”，护符 / 城邦一直返回 false，语义不动）。
#
# 能量点：`turn_count` 比较天然满足“每回合一次 + 下一回合可再发动”，也不需要清零。

## 现在能不能发动 unit_id 这个单位的主动技能
func can_use_skill(pid: int, unit_id: int) -> bool:
	return skill_blocked_reason(pid, unit_id) == ""


## 不能发动技能的原因（可以发动时返回 ""）
func skill_blocked_reason(pid: int, unit_id: int) -> String:
	if net_locked:
		return "观战 / 快照未到，暂时不能操作"
	if not game_active():
		return "对局已经结束"
	if busy:
		return "对手正在行动，请稍候"
	if current_player != pid:
		return "现在不是你的回合"
	var u := get_unit(pid, unit_id)
	if u == null:
		return "找不到这个单位（或它不是你的单位）"
	if not u.is_alive():
		return "这个单位已经阵亡"
	var card := u.data
	if card == null or not card.has_skill():
		return "这个单位没有主动技能"
	if card.skill_chain().is_empty():
		return "「%s」的技能没有配置任何效果" % card.card_name
	if u.in_front:
		return "横置在格子里的单位不能发动技能（受伤退回后排后才行）"
	if u.is_frozen(turn_count):
		return "「%s」被冻结，本回合无法行动" % card.card_name
	var p := get_player(pid)
	if p == null:
		return "找不到玩家"
	var cost := card.skill_cost()
	if p.mana < cost:
		return "PP 不足：技能「%s」需要 %d PP，你现在只有 %d（PP = 法力，与出牌共用）" % [
			card.skill_name(), cost, p.mana]
	if card.skill_once_per_turn() and u.skill_used_turn == turn_count:
		return "「%s」本回合已经发动过了" % card.skill_name()
	return ""


## 技能的目标列表：目标类型取技能链里第一条需要选目标的条目（CardData.skill_target()）；
## 不需要选目标 → 空数组（技能直接发得出来）
func get_valid_skill_targets(pid: int, unit_id: int) -> Array[Dictionary]:
	var res: Array[Dictionary] = []
	var u := get_unit(pid, unit_id)
	if u == null or u.data == null:
		return res
	var kind := u.data.skill_target()
	if not CardData.target_needs_selection(kind):
		return res
	return _targets_for_kind(pid, kind)


## 发动主动技能：扣能量点 → 记下本回合已用 → 按 skill_chain() 顺序结算。
## **失败时一定不扣能量点、不改任何状态**并返回 false。
func use_skill(pid: int, unit_id: int, target_unit_id: int = -1, target_player_id: int = -1) -> bool:
	var why := skill_blocked_reason(pid, unit_id)
	if why != "":
		_log(why)
		return false
	var u := get_unit(pid, unit_id)
	var card := u.data
	var p := get_player(pid)
	# 技能需要选目标却没有合法目标：不扣能量点、不消耗本回合次数
	var kind := card.skill_target()
	if CardData.target_needs_selection(kind) and get_valid_skill_targets(pid, unit_id).is_empty():
		_log("「%s」的技能「%s」需要一个合法的%s，当前没有合法目标 → 无法发动" % [
			card.card_name, card.skill_name(), CardData.TARGET_NAMES.get(kind, str(kind))])
		return false
	var cost := card.skill_cost()
	p.mana = maxi(0, p.mana - cost)
	u.skill_used_turn = turn_count
	_log("%s 发动技能「%s」（%s，%s，剩余 %d PP）" % [
		p.display_name, card.card_name, card.skill_name(),
		"免费" if cost <= 0 else "花费 %d PP" % cost, p.mana])
	_resolve_chain(pid, card, card.skill_chain(), target_unit_id, target_player_id, u, false)
	_cleanup_deaths()
	_check_game_over()
	state_changed.emit()
	return true


## 对英雄造成伤害；返回**实际掉血量**（护甲吸收的部分不算，吸血按它回血）
func damage_player(pid: int, amount: int) -> int:
	var p := get_player(pid)
	if p == null or amount <= 0:
		return 0
	var absorbed := mini(p.armor, amount)
	p.armor -= absorbed
	var rest := amount - absorbed
	if absorbed > 0:
		_log("%s 护甲吸收 %d 点伤害（剩余护甲 %d）" % [p.display_name, absorbed, p.armor])
	if rest > 0:
		p.hero_hp = maxi(0, p.hero_hp - rest)
		_log("%s 英雄剩余生命 %d" % [p.display_name, p.hero_hp])
	_check_game_over()
	# 主战者掉血后同样要通知界面（血量徽章 / 护甲徽章立刻刷新；界面按帧合并）
	state_changed.emit()
	return rest


## 为主战者恢复生命（不超过上限）；返回**实际恢复量**。
## 与 `damage_player` 对称：扩展包 / 机制脚本做「吸血 / 亡语回血」时不用自己去改 hero_hp。
func heal_player(pid: int, amount: int) -> int:
	var p := get_player(pid)
	if p == null or amount <= 0:
		return 0
	var before: int = p.hero_hp
	p.hero_hp = mini(p.hero_max_hp, p.hero_hp + amount)
	var healed: int = p.hero_hp - before
	if healed > 0:
		amount_shown.emit(pid, -1, healed, "heal")
		_log("%s 恢复 %d 点生命（当前 %d）" % [p.display_name, healed, p.hero_hp])
		state_changed.emit()
	return healed
#
# 座位约定：PLAYER_ID(0) = 房主，ENEMY_ID(1) = 客机。
# 客机拿到的快照是**镜像过**的：把客机自己的那份放在下标 0，这样界面代码（一律用 PLAYER_ID
# 表示“我方”）完全不用改；观战者看房主视角。
# 隐藏信息：只有「接收者自己的座位」会下发手牌内容与牌库内容，其余只给张数。

## 生成给某个座位看的状态快照（房主调用）。`for_seat` < 0 表示观战者。
func net_snapshot(for_seat: int) -> Dictionary:
	var mirror := for_seat == ENEMY_ID
	var order: Array[int] = []
	if mirror:
		order = [ENEMY_ID, PLAYER_ID]
	else:
		order = [PLAYER_ID, ENEMY_ID]
	var reveal := for_seat if for_seat >= 0 else -99
	var out_players: Array = []
	for pid in order:
		var p := get_player(pid)
		if p == null:
			continue
		var entry := {
			"id": PLAYER_ID if pid == reveal else (ENEMY_ID if mirror else pid),
			"name": p.display_name,
			"hp": p.hero_hp, "max_hp": p.hero_max_hp, "armor": p.armor,
			"mana": p.mana, "max_mana": p.max_mana, "fatigue": p.fatigue,
			"deck_count": p.deck.size(), "hand_count": p.hand.size(),
			"grave_count": p.graveyard.size(),
			"turns_taken": p.turns_taken, "city_summon_turn": p.city_summon_turn,
			"hand": [], "board": [], "grave": [],
		}
		if pid == reveal:
			for c in p.hand:
				entry["hand"].append(c.id)
		p.sync_slots()
		for u in p.board:
			var owner_net: int = (PLAYER_ID if pid == reveal else ENEMY_ID) if mirror else pid
			entry["board"].append({
				"uid": u.unit_id, "owner": owner_net, "card": u.data.id,
				# 身材 / 伤害减免 / 禁锢：客机要显示正确的数字，也要按同一套战斗规则画提示
				"atk": u.attack, "hp": u.health, "max": u.max_health,
				"adr": u.ability_damage_reduction, "cdr": u.collision_damage_reduction,
				"imprisoned": u.data.imprisoned,
				"kw": u.keywords.duplicate(), "shield": u.divine_shield,
				"summoned": u.summoned_turn, "used": u.attacks_used, "frozen": u.frozen_until,
				"front": u.in_front, "city": u.in_city_slot,
				# 主动技能本回合是否已经用过（客机界面据此把技能按钮变灰）
				"skill_turn": u.skill_used_turn,
				# 格子号（-1 = 城邦格 / 没有格子）：客机据此把随从摆在正确的格子里
				"slot": p.slot_of(u),
			})
		out_players.append(entry)
	return {
		"turn": turn_count,
		"current": (PLAYER_ID if current_player == reveal else ENEMY_ID) if mirror else current_player,
		"winner": winner, "draw": is_draw, "busy": busy,
		"mulligan": mulligan_pending,
		# 对战模式以房主为准：客机界面显示的「指定 / 无限」跟着快照走
		"mode": current_mode,
		"time_left": turn_seconds_left() if net_authority else 0,
		"discover": _discover_snapshot(),
		"invoke_choice": _invoke_choice_snapshot(),
		"players": out_players,
	}


## 发现候选的对外形式（联机时随快照下发，客机据此弹窗）
func _discover_snapshot() -> Dictionary:
	if pending_discover.is_empty():
		return {}
	var ids: Array = []
	for c in pending_discover.get("options", []):
		ids.append(c.id)
	return {"pid": int(pending_discover.get("pid", PLAYER_ID)), "options": ids}


## 待选的瞬念召唤去向（联机时随快照下发，客机据此弹窗）
func _invoke_choice_snapshot() -> Dictionary:
	if pending_invoke_choice.is_empty():
		return {}
	return {"pid": int(pending_invoke_choice.get("pid", PLAYER_ID)),
		"unit_id": int(pending_invoke_choice.get("unit_id", -1))}


## 客户端应用房主下发的快照（把本地 GameManager 变成一份镜像）。
## 权威侧（房主 / 单机）永远不应用远端快照——这也是同一个进程里跑自测时不会互相覆盖的保证。
func apply_net_snapshot(state: Dictionary) -> bool:
	if net_authority:
		return false
	if typeof(state) != TYPE_DICTIONARY or state.is_empty():
		return false
	var list: Array = state.get("players", [])
	if list.size() != 2:
		return false
	players.clear()
	for entry in list:
		var pid := int(entry.get("id", 0))
		var p := PlayerState.new(pid, str(entry.get("name", "玩家")), int(entry.get("max_hp", HERO_MAX_HP)))
		p.hero_hp = int(entry.get("hp", HERO_MAX_HP))
		p.hero_max_hp = int(entry.get("max_hp", HERO_MAX_HP))
		p.armor = int(entry.get("armor", 0))
		p.mana = int(entry.get("mana", 0))
		p.max_mana = int(entry.get("max_mana", 0))
		p.fatigue = int(entry.get("fatigue", 0))
		p.turns_taken = int(entry.get("turns_taken", 0))
		p.city_summon_turn = int(entry.get("city_summon_turn", -1))
		# 牌库内容不下发：用同样张数的占位卡让「牌库 123」这类读数正确，内容无从得知
		var deck_n := int(entry.get("deck_count", 0))
		var placeholder := CardData.new()
		placeholder.id = "__hidden__"
		placeholder.card_name = "？？？"
		for _i in deck_n:
			p.deck.append(placeholder)
		for cid in entry.get("hand", []):
			var c := CardDB.get_card(str(cid))
			if c != null:
				p.hand.append(c.clone())
		for uid in entry.get("grave", []):
			var gc := CardDB.get_card(str(uid))
			if gc != null:
				p.graveyard.append(gc.clone())
		for ue in entry.get("board", []):
			var card := CardDB.get_card(str(ue.get("card", "")))
			if card == null:
				continue
			var u := BoardUnit.new()
			u.setup(card.clone(), int(ue.get("owner", pid)), int(ue.get("summoned", -1)), int(ue.get("uid", 0)))
			u.attack = int(ue.get("atk", 0))
			u.health = int(ue.get("hp", 0))
			u.max_health = int(ue.get("max", u.health))
			var kw: Array[int] = []
			for k in ue.get("kw", []):
				kw.append(int(k))
			u.keywords = kw
			u.divine_shield = bool(ue.get("shield", false))
			u.attacks_used = int(ue.get("used", 0))
			u.frozen_until = int(ue.get("frozen", -1))
			u.in_front = bool(ue.get("front", false))
			u.in_city_slot = bool(ue.get("city", false))
			u.skill_used_turn = int(ue.get("skill_turn", -1))
			u.ability_damage_reduction = int(ue.get("adr", 0))
			u.collision_damage_reduction = int(ue.get("cdr", 0))
			u.data.imprisoned = bool(ue.get("imprisoned", false))
			p.board.append(u)
			# 格子号：把随从摆回房主给的那一格（-1 = 城邦格 / 老快照没带格子 → 自动补位）
			var uslot := int(ue.get("slot", -1))
			if not u.in_city_slot and uslot >= 0 and uslot < BOARD_LIMIT:
				p.place_unit_at(u, uslot)
		players.append(p)
	turn_count = int(state.get("turn", 0))
	current_player = int(state.get("current", PLAYER_ID))
	current_mode = Formats.normalized_mode(str(state.get("mode", current_mode)))
	winner = int(state.get("winner", -1))
	is_draw = bool(state.get("draw", false))
	busy = bool(state.get("busy", false))
	mulligan_pending = bool(state.get("mulligan", false))
	pending_discover = {}
	var disc: Dictionary = state.get("discover", {})
	if not disc.is_empty():
		var opts: Array = []
		for cid in disc.get("options", []):
			var dc := CardDB.get_card(str(cid))
			if dc != null:
				opts.append(dc.clone())
		if not opts.is_empty():
			pending_discover = {"pid": int(disc.get("pid", PLAYER_ID)), "options": opts}
	# 待选的瞬念召唤去向（客机端据此弹窗）
	pending_invoke_choice = {}
	var ich: Dictionary = state.get("invoke_choice", {})
	if not ich.is_empty():
		pending_invoke_choice = {"pid": int(ich.get("pid", PLAYER_ID)),
			"unit_id": int(ich.get("unit_id", -1))}
	var left := int(state.get("time_left", 0))
	turn_deadline_msec = Time.get_ticks_msec() + left * 1000 if left > 0 else 0
	state_changed.emit()
	return true


## 座位掉线超时判负（房主调用）
func net_judge_disconnect(seat: int) -> void:
	if not game_active():
		return
	var p := get_player(seat)
	if p == null:
		return
	p.armor = 0
	p.hero_hp = 0
	_log("%s 掉线超时，判负" % p.display_name)
	_check_game_over()
	state_changed.emit()


# ------------------------------ 联机：界面统一的操作入口 ------------------------------
# 单机 / 房主：直接执行；客机：打包成意图发给房主，等快照回来。
# 界面只认这几个入口，就不需要到处判断自己是哪种身份。

func request_play(hand_index: int, tu: int = -1, tp: int = -1, to_front: bool = false,
		slot: int = -1) -> bool:
	if net_locked:
		return false
	if net_authority:
		return play_card(PLAYER_ID, hand_index, tu, tp, to_front, slot)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "play_card", "hand": hand_index, "tu": tu, "tp": tp,
		"front": to_front, "slot": slot})
	return true


func request_attack(unit_id: int, target_unit_id: int, target_player_id: int) -> bool:
	if net_locked:
		return false
	if net_authority:
		return attack(PLAYER_ID, unit_id, target_unit_id, target_player_id)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "attack", "unit": unit_id, "target": target_unit_id, "tp": target_player_id})
	return true


func request_front(unit_id: int) -> bool:
	if net_locked:
		return false
	if net_authority:
		return place_in_front(PLAYER_ID, unit_id)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "front", "unit": unit_id})
	return true


## 把防御格里的随从移出的界面入口（单人 / 房主直接执行；客机发意图）。
func request_leave_front(unit_id: int, to_slot: int = -1) -> bool:
	if net_locked:
		return false
	if net_authority:
		return leave_front(PLAYER_ID, unit_id, to_slot)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "leave_front", "unit": unit_id, "slot": to_slot})
	return true


## 融合的界面入口：单人 / 房主直接执行；客机发意图给房主（与出牌 / 技能同一套 intent）。
func request_fuse(hand_index: int, material_indices: Array) -> bool:
	if net_locked:
		return false
	if net_authority:
		return fuse(PLAYER_ID, hand_index, material_indices)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "fuse", "hand": hand_index, "mats": material_indices})
	return true


## 发动主动技能的界面入口：单人 / 房主直接执行；客机按现有 intent 模式发给房主。
func request_use_skill(unit_id: int, target_unit_id: int = -1, target_player_id: int = -1) -> bool:
	if net_locked:
		return false
	if net_authority:
		return use_skill(PLAYER_ID, unit_id, target_unit_id, target_player_id)
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "use_skill", "unit": unit_id,
		"target": target_unit_id, "tp": target_player_id})
	return true


func request_end_turn() -> bool:
	if net_locked:
		return false
	if net_authority:
		if not game_active() or busy or current_player != PLAYER_ID:
			return false
		_next_turn()
		return true
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "end_turn"})
	return true


func request_concede() -> bool:
	if net_locked:
		return false
	if net_authority:
		concede(PLAYER_ID)
		return true
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	net.send_intent({"kind": "concede"})
	return true


## 每帧驱动回合计时（只有权威侧执行；客户端只显示房主给的剩余秒数）
func _process(_delta: float) -> void:
	if not game_active() or net_locked or not net_authority:
		return
	if turn_time_limit <= 0 or turn_deadline_msec <= 0 or busy:
		return
	if Time.get_ticks_msec() >= turn_deadline_msec:
		_log("回合超时（%d 秒），自动结束回合" % turn_time_limit)
		_next_turn()


## 倒计时（影之诗护符风格）：每到自己回合开始 -1，归零的护符 / 城邦被摧毁
func _tick_countdowns(pid: int) -> void:
	var p := get_player(pid)
	if p == null:
		return
	var expired: Array[BoardUnit] = []
	for u in p.board:
		if u.countdown <= 0:
			continue
		u.countdown -= 1
		if u.countdown <= 0:
			expired.append(u)
			_log("「%s」的倒计时归零，被摧毁" % u.data.card_name)
		else:
			_log("「%s」倒计时剩 %d" % [u.data.card_name, u.countdown])
	for u in expired:
		p.remove_unit(u)                 # 它那一格置 null：空位保留，其它随从不移动
		p.note_grave_entered(u.data)
		_notify_leave(u)
		u.strip_granted()


## 复生（炉石风格）：第一次死亡时以 1 点生命回到战场（亡语已经结算过一次）
## 落点用「第一个空位」——复生发生在阵亡结算中间，通常正好回到它自己刚空出来的那一格。
func _try_reborn(dead: BoardUnit) -> void:
	if dead == null or not dead.has_mechanic(CardData.Keyword.REBORN) or dead.reborn_used:
		return
	# 被禁锢：不能被召唤出来（复生也是召唤）
	if dead.data != null and dead.data.imprisoned:
		_log("  「%s」被禁锢，无法复生" % dead.data.card_name)
		return
	var p := get_player(dead.owner_id)
	if p == null or board_size_used(dead.owner_id) >= BOARD_LIMIT:
		return
	var dest := first_empty_slot(dead.owner_id)
	if dest < 0:
		return
	var u := BoardUnit.new()
	u.setup(dead.data.clone(), dead.owner_id, dead.summoned_turn, _next_unit_id)
	_next_unit_id += 1
	u.reborn_used = true
	u.health = 1
	u.max_health = maxi(1, dead.max_health)
	p.place_unit_at(u, dest)
	_log("  「%s」复生：以 1 点生命回到战场（第 %d 格）" % [dead.data.card_name, dest + 1])


# ------------------------------ 死亡与胜负 ------------------------------

## 反复结算所有生命归零的随从，直到没有死亡为止（亡语可能引发新的死亡）。
## **结算顺序确定化**：每一轮把当轮所有死亡单位按 `unit_id` 升序排列后再依次处理，
## 而不是按“遍历 board 时先撞上谁就先处理谁”。联机时房主与（将来可能的）回放 / 客户端
## 只要拿到同一份状态，死亡与亡语的处理顺序就完全一致，不会再出现两边结果不同的隐患。
## 场上随从的**统一结算顺序**（一条规则，所有遍历都走这里）：
##   * 己方 = 自己视角的左→右（**格子索引 0 → SLOT_COUNT-1**）
##   * 敌方 = 镜像（对方视角的左→右，也就是本视角的右→左，格子索引从大到小）
##   * 空位（null）自动跳过，不占位置也不影响顺序；
##   * 城邦格里的城邦没有格子，排在它那一方的最后（与改动前一致，保持可被攻击 / 被指定）。
## `viewer_pid` = 以谁的视角结算（通常是效果发起者 / 当前回合方）。
func unit_order(viewer_pid: int) -> Array[BoardUnit]:
	var viewer: int = viewer_pid if viewer_pid == PLAYER_ID or viewer_pid == ENEMY_ID else PLAYER_ID
	var out: Array[BoardUnit] = []
	for u in board_units_in_order(viewer):
		out.append(u)
	var foe_units := board_units_in_order(1 - viewer)
	for i in range(foe_units.size() - 1, -1, -1):
		out.append(foe_units[i])
	return out


## 只看某一方自己的场面时用：那一方自己视角的左→右（按格子顺序；例如己方回合开始的倒计时）。
## 与 `board_units_in_order` 一样包含城邦格里的城邦。
func side_order(pid: int) -> Array[BoardUnit]:
	return board_units_in_order(pid)


func _cleanup_deaths() -> void:
	var guard := 0
	while guard < DEATH_SETTLE_LIMIT:
		guard += 1
		# 同轮多个随从死亡：按「己方左→右、敌方镜像」的顺序处理（位置决定顺序，可复现）
		var dying: Array[BoardUnit] = []
		for u in unit_order(current_player):
			if not u.is_alive() and not dying.has(u):
				dying.append(u)
		if dying.is_empty():
			return
		for dead in dying:
			var owner := get_player(dead.owner_id)
			if owner != null:
				# 只把它那一格置 null（空位保留），其它随从**不移动**；随后再给它补位
				owner.remove_unit(dead)
				owner.note_grave_entered(dead.data)
				_notify_leave(dead)
				# 死亡钩子：进墓地之后立刻派发 on_death（机制据此做事），随后才是亡语
				Mechanics.dispatch(dead, "on_death", {"gm": self, "unit": dead,
					"source": dead, "pid": dead.owner_id})
				# 死亡计数（「已经死了几个随从」这类瞬念召唤条件靠它）
				owner.units_died_turn += 1
				owner.units_died_total += 1
			_log("「%s」被消灭" % dead.data.card_name)
			_trigger_deathrattle(dead)
			# 赋予来的技能 / 能力只属于「在场期间」：亡语结算完就摘掉，再进复生判定
			dead.strip_granted()
			_try_reborn(dead)
	push_warning("[Game] 死亡结算次数达到上限（%d），可能出现了循环亡语" % DEATH_SETTLE_LIMIT)


## 亡语：遍历 deathrattle_chain() 按顺序结算，目标用与战吼**同一套**自动选目标规则
## （施法方 = 亡语拥有者；随机改成“第一个合法目标”，顺序确定、可复现）。
## 老卡的亡语被包成一条，目标推导口径与改动前一致（默认目标 → 自动选目标）。
func _trigger_deathrattle(u: BoardUnit) -> void:
	var card := u.data
	if not card.has_deathrattle():
		return
	# 被禁锢：退场能力（亡语）不发动 —— 离场仍计数，但不结算能力
	if card.imprisoned:
		_log("  「%s」被禁锢：亡语不发动" % card.card_name)
		return
	_log("  触发亡语：「%s」%s" % [card.card_name, card.deathrattle_text()])
	# 亡语伤害同样带来源随从，这样「吸血 / 剧毒」之类的机制对亡语也成立
	_resolve_chain(u.owner_id, card, card.deathrattle_chain(), -1, -1, u, true)
	state_changed.emit()


func _check_game_over() -> void:
	if not game_active():
		return
	var p0 := get_player(PLAYER_ID)
	var p1 := get_player(ENEMY_ID)
	if p0 == null or p1 == null:
		return
	if not p0.is_alive() and not p1.is_alive():
		winner = -2
		is_draw = true
		_log("=== 双方同时倒下，平局 ===")
		game_over.emit(-1, true)
	elif not p0.is_alive():
		winner = ENEMY_ID
		_log("=== 我方英雄阵亡，失败 ===")
		game_over.emit(ENEMY_ID, false)
	elif not p1.is_alive():
		winner = PLAYER_ID
		_log("=== 敌方英雄阵亡，胜利！ ===")
		game_over.emit(PLAYER_ID, false)
	if not game_active():
		busy = false
		state_changed.emit()


func _log(text: String) -> void:
	print("[Game] " + text)
	if log_enabled:
		log_message.emit(text)


## 对外（效果系统）使用的日志入口
func log_line(text: String) -> void:
	_log(text)


# ------------------------------ 管理员同步 ------------------------------

func _on_database_changed() -> void:
	var valid := {}
	for c in CardDB.cards:
		valid[c.id] = true
	var removed := 0
	var synced := 0
	for p in players:
		removed += _prune_hand(p, valid)
		removed += _prune_deck_and_grave(p, valid)
		removed += _prune_board(p, valid)
		synced += _resync_player(p)
	if removed > 0:
		_log("卡表已更新：清除 %d 张失效卡牌" % removed)
	if synced > 0:
		_log("卡表已更新：同步 %d 张卡牌的最新数据" % synced)
	state_changed.emit()


## 管理员改动要立刻作用到对局里已有的副本（手牌 / 牌库 / 墓地 / 战场）
func _resync_player(p: PlayerState) -> int:
	var n := 0
	n += _resync_cards(p.hand)
	n += _resync_cards(p.deck)
	n += _resync_cards(p.graveyard)
	for u in p.board:
		var fresh: CardData = CardDB.get_card(u.data.id)
		if fresh == null or _same_card(u.data, fresh):
			continue
		u.data = fresh.clone()
		n += 1
	return n


func _resync_cards(list: Array[CardData]) -> int:
	var n := 0
	for i in list.size():
		var fresh: CardData = CardDB.get_card(list[i].id)
		if fresh == null or _same_card(list[i], fresh):
			continue
		list[i] = fresh.clone()
		n += 1
	return n


func _same_card(a: CardData, b: CardData) -> bool:
	return JSON.stringify(a.to_dict()) == JSON.stringify(b.to_dict())


func _prune_hand(p: PlayerState, valid: Dictionary) -> int:
	var n := 0
	for i in range(p.hand.size() - 1, -1, -1):
		if not valid.has(p.hand[i].id):
			p.hand.remove_at(i)
			n += 1
	return n


func _prune_deck_and_grave(p: PlayerState, valid: Dictionary) -> int:
	var n := 0
	for arr in [p.deck, p.graveyard]:
		for i in range(arr.size() - 1, -1, -1):
			if not valid.has(arr[i].id):
				arr.remove_at(i)
				n += 1
	return n


func _prune_board(p: PlayerState, valid: Dictionary) -> int:
	var n := 0
	for i in range(p.board.size() - 1, -1, -1):
		if not valid.has(p.board[i].data.id):
			p.remove_unit(p.board[i])     # 同时把它那一格留成空位
			n += 1
	return n
