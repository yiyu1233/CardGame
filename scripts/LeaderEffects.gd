class_name LeaderEffects
extends RefCounted
## 主战者效果（照《影之诗》一代的「主战者に付与される効果」，不是二代的纹章）。
##
## 一句话：**卡牌在某个时机把一条「监听器」挂到主战者身上**，之后由引擎在事件发生时替它结算。
##
##   卡牌 ──(赋予时机: 入场 / 离场 / 瞬念召唤 / 召唤 / 消失)──> 主战者
##   主战者 ──(监听事件: 回合开始 / 回合结束 / 打出 N 费卡 / 抽到 N 费卡 / N 费卡离场)──> 效果链
##
## 数据（存在 CardData.leader_effects 里，JSON 友好）：
##   {"grant": "play", "on": "play", "cost": 2, "turns": 3, "target": 0, "effects": [...]}
##     grant   赋予时机：play(入场/打出) / leave(离场) / invoke(瞬念召唤) / summon(召唤) / vanish(消失)
##     on      监听事件：turn_start / turn_end / play / draw / leave（后三个可按费用过滤）
##     cost    费用过滤：-1 = 任意；>=0 = 只在事件里那张卡的费用等于它时触发
##     turns   持续回合数：0 = 本局永久；N = 该主战者再过 N 个自己的回合后失效
##     target  0 = 赋予者的主战者，1 = 对手的主战者
##     effects 效果链（与战吼 / 亡语同一套效果，复用 ChainEditor 编辑）
##
## 拓展方式：加一个**监听事件** = 在 `_build_events()` 里加一行 + 在 GameManager 对应时机调一次
## `LeaderEffects.fire(...)`；加一个**赋予时机** = 在 `_build_grants()` 里加一行 + 在对应路径调
## `LeaderEffects.grant(...)`。玩家侧看不到任何硬编码：一条数据就是一条效果。

const NONE := ""

# ------------------------------ 赋予时机（卡牌 → 主战者） ------------------------------
const GRANT_PLAY := "play"
const GRANT_LEAVE := "leave"
const GRANT_INVOKE := "invoke"
const GRANT_SUMMON := "summon"
const GRANT_VANISH := "vanish"

# ------------------------------ 监听事件（主战者侧） ------------------------------
const ON_TURN_START := "turn_start"
const ON_TURN_END := "turn_end"
const ON_PLAY := "play"
const ON_DRAW := "draw"
const ON_LEAVE := "leave"

static var _grants: Dictionary = {}
static var _grant_order: Array[String] = []
static var _events: Dictionary = {}
static var _event_order: Array[String] = []
static var _targets: Array[String] = ["自己", "对手"]
static var _depth_guard := 3


static func _ensure() -> void:
	if _events.is_empty():
		_build()


static func _build() -> void:
	# 赋予时机：卡牌自己发生这些事时，把效果挂到主战者身上
	_reg_grant(GRANT_PLAY, "入场（打出）")
	_reg_grant(GRANT_LEAVE, "离场")
	_reg_grant(GRANT_INVOKE, "瞬念召唤")
	_reg_grant(GRANT_SUMMON, "召唤入场")
	_reg_grant(GRANT_VANISH, "消失")

	# 监听事件：主战者身上挂着效果后，这些时刻会结算它
	_reg_event(ON_TURN_START, "我方回合开始时", false, ">=")
	_reg_event(ON_TURN_END, "我方回合结束时", false, ">=")
	_reg_event(ON_PLAY, "打出指定费用的卡时", true, "=")
	_reg_event(ON_DRAW, "抽到指定费用的卡时", true, "=")
	_reg_event(ON_LEAVE, "指定费用的卡离场时", true, "=")


static func _reg_grant(id: String, label: String) -> void:
	_grants[id] = {"id": id, "label": label}
	_grant_order.append(id)


static func _reg_event(id: String, label: String, needs_cost: bool, op: String) -> void:
	_events[id] = {"id": id, "label": label, "needs_cost": needs_cost, "op": op}
	_event_order.append(id)


# ------------------------------ 查询 ------------------------------

static func grant_ids() -> Array[String]:
	_ensure()
	return _grant_order.duplicate()


static func grant_label(id: String) -> String:
	_ensure()
	return str(_grants[id]["label"]) if _grants.has(id) else id


static func has_grant(id: String) -> bool:
	_ensure()
	return _grants.has(id)


static func event_ids() -> Array[String]:
	_ensure()
	return _event_order.duplicate()


static func event_label(id: String) -> String:
	_ensure()
	return str(_events[id]["label"]) if _events.has(id) else id


static func has_event(id: String) -> bool:
	_ensure()
	return _events.has(id)


## 这个事件要不要按费用过滤（回合开始 / 结束不需要）
static func event_needs_cost(id: String) -> bool:
	_ensure()
	return bool(_events[id]["needs_cost"]) if _events.has(id) else false


static func target_name(v: int) -> String:
	return _targets[clampi(v, 0, _targets.size() - 1)]


static func targets() -> Array[String]:
	return _targets.duplicate()


# ------------------------------ 文本 / 归一 / 自检 ------------------------------

## 事件的人话（带费用）：「打出 2 费卡时」
static func event_phrase(id: String, cost: int) -> String:
	_ensure()
	if not has_event(id):
		return id
	if not event_needs_cost(id):
		return event_label(id)
	if cost < 0:
		return event_label(id).replace("指定费用的", "任意费用的")
	return event_label(id).replace("指定费用的", "%d 费的" % cost)


## 一条主战者效果的人话：「入场（打出）时赋予自己主战者：我方回合开始时 → 造成 1 点伤害（本局永久）」
static func text(spec: Dictionary) -> String:
	_ensure()
	if spec.is_empty():
		return ""
	var grant := grant_label(str(spec.get("grant", GRANT_PLAY)))
	var who := target_name(int(spec.get("target", 0)))
	var on := event_phrase(str(spec.get("on", ON_TURN_START)), int(spec.get("cost", -1)))
	var body := ""
	var chain: Variant = spec.get("effects", [])
	if typeof(chain) == TYPE_ARRAY and not (chain as Array).is_empty():
		body = CardData.new().chain_text(chain)
	var turns := int(spec.get("turns", 0))
	var dur := "本局永久" if turns <= 0 else "%d 回合" % turns
	var tail := " → %s" % body if body != "" else ""
	return "%s时赋予%s主战者：%s%s（%s）" % [grant, who, on, tail, dur]


## 读卡表时的安全归一：缺键 / 类型不对一律补默认值
static func normalized(raw: Variant) -> Dictionary:
	_ensure()
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var src: Dictionary = raw
	var grant := str(src.get("grant", GRANT_PLAY)).strip_edges()
	var on := str(src.get("on", ON_TURN_START)).strip_edges()
	if grant == "":
		grant = GRANT_PLAY
	if on == "":
		on = ON_TURN_START
	var fx: Variant = src.get("effects", [])
	return {
		"grant": grant,
		"on": on,
		"cost": int(src.get("cost", -1)),
		"turns": maxi(0, int(src.get("turns", 0))),
		"target": clampi(int(src.get("target", 0)), 0, _targets.size() - 1),
		"effects": fx if typeof(fx) == TYPE_ARRAY else [],
	}


## 结构自检（效果链本身由 CardDB / 面板另外校验）
static func errors(spec: Dictionary) -> Array[String]:
	_ensure()
	var out: Array[String] = []
	if spec.is_empty():
		return out
	if not has_grant(str(spec.get("grant", ""))):
		out.append("赋予时机 %s 未登记（可用：%s）" % [
			str(spec.get("grant", "")), "、".join(grant_ids())])
	if not has_event(str(spec.get("on", ""))):
		out.append("监听事件 %s 未登记（可用：%s）" % [
			str(spec.get("on", "")), "、".join(event_ids())])
	var cost := int(spec.get("cost", -1))
	if cost < -1:
		out.append("费用过滤不能小于 -1")
	if int(spec.get("turns", 0)) < 0:
		out.append("持续回合数不能为负")
	if int(spec.get("target", 0)) < 0 or int(spec.get("target", 0)) >= _targets.size():
		out.append("目标主战者越界")
	var chain: Variant = spec.get("effects", [])
	if typeof(chain) != TYPE_ARRAY or (chain as Array).is_empty():
		out.append("这条主战者效果没有配效果（挂了也不会发生任何事）")
	return out


# ------------------------------ 运行时：赋予 / 结算 / 到期 ------------------------------

## 这张卡发生 `grant` 这件事时，把它的主战者效果挂到主战者身上。
## `owner_pid` = 这张卡属于谁（赋予目标 0 = 它，1 = 对手）。
static func grant(gm, owner_pid: int, card: CardData, grant: String) -> int:
	_ensure()
	if gm == null or card == null:
		return 0
	var granted := 0
	for raw in card.leader_effects:
		var spec := normalized(raw)
		if spec.is_empty() or str(spec.get("grant", "")) != grant:
			continue
		var pid := owner_pid if int(spec.get("target", 0)) == 0 else (1 - owner_pid)
		var p: PlayerState = gm.get_player(pid)
		if p == null:
			continue
		# 持续回合数按「这个主战者自己的回合数」算（与 tick 的钟一致）
		p.add_leader_effect(spec, card.id, p.turns_taken)
		granted += 1
		gm._log("  「%s」%s：给%s主战者挂上「%s」" % [
			card.card_name, grant_label(grant), target_name(int(spec.get("target", 0))),
			text(spec)])
	return granted


## 某个事件发生了：让这一方主战者身上的效果依次结算（`card` = 事件里那张卡，可为 null）
static func fire(gm, pid: int, event: String, card: CardData = null) -> int:
	_ensure()
	if gm == null or not has_event(event):
		return 0
	var p: PlayerState = gm.get_player(pid)
	if p == null or p.leader_effects.is_empty():
		return 0
	if int(gm.get("_leader_depth")) >= _depth_guard:
		gm._log("  主战者效果触发层数已到上限（%d），本次不再连锁" % _depth_guard)
		return 0
	var fired := 0
	gm.set("_leader_depth", int(gm.get("_leader_depth")) + 1)
	# 复制一份：效果链里可能会加 / 删主战者效果
	for entry in p.leader_effects.duplicate(true):
		if str(entry.get("on", "")) != event:
			continue
		var need_cost := int(entry.get("cost", -1))
		if need_cost >= 0:
			if card == null or card.cost != need_cost:
				continue
		var chain: Variant = entry.get("effects", [])
		if typeof(chain) != TYPE_ARRAY or (chain as Array).is_empty():
			continue
		var src := _source_card(gm, str(entry.get("source", "")))
		gm._log("  ★ 主战者效果触发（%s）：%s" % [event_label(event), text(entry)])
		gm._resolve_chain(pid, src, chain, -1, -1, null, false)
		fired += 1
	gm.set("_leader_depth", int(gm.get("_leader_depth")) - 1)
	return fired


## 回合开始：先把到期的效果摘掉（N 回合 = 该主战者再过 N 个自己的回合后失效）
static func tick(gm, pid: int) -> int:
	if gm == null:
		return 0
	var p: PlayerState = gm.get_player(pid)
	if p == null:
		return 0
	return p.tick_leader_effects(p.turns_taken)


## 效果链的「来源卡」：优先用卡表里的原卡（有名字 / 卡面），查不到就造一个占位
static func _source_card(gm, source_id: String) -> CardData:
	if source_id != "":
		var c: CardData = gm.card_by_id(source_id)
		if c != null:
			return c
	var stub := CardData.new()
	stub.id = source_id
	stub.card_name = "主战者效果"
	return stub
