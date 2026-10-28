class_name CardTriggers
extends RefCounted
## 卡牌**触发效果**（照影之诗一代的「誘発能力 / 起動能力」）：
## 一张卡在某个时机自动结算一条效果链，**不需要玩家操作**，也不用改引擎代码。
##
## 与既有几张表的分工（互不冲突，都能留空）：
##   * `effects`（战吼 / 安放）           —— **从手牌打出**时结算（既有行为，不动）
##   * `deathrattle_effects`（亡语）      —— 死亡时结算（既有行为，不动）
##   * `invocation`（瞬念召唤）           —— 牌库里满足条件时自动上场（既有行为，不动）
##   * `leader_effects`（主战者效果）     —— 把这个效果挂到主战者身上（见 LeaderEffects）
##   * **`triggers`（本表）**             —— 卡牌自己的「某个时机再结算一条链」：
##     入场 / 召唤 / 离场 / 瞬念召唤 / 消失 / 我方回合开始 / 我方回合结束。
##
## 数据（JSON 友好，存在 CardData.triggers 里）：
##   {"on": "summon", "effects": [{"id": "draw", "value": 1}]}
##     on      触发时机（见 event_ids()）
##     effects 效果链：与战吼完全同一套效果，链里每条还能再配「条件」（EffectConditions）
##
## 拓展方式：加一个时机 = 在 `_build()` 里 `_reg_event(...)` 一行 + 在 GameManager 对应路径
## 调一次 `CardTriggers.fire_card / fire_unit`。数据里没有硬编码的效果：全是链。

const NONE := ""

# ------------------------------ 触发时机 ------------------------------
const EV_PLAY := "play"            ## 入场（从手牌打出）
const EV_SUMMON := "summon"        ## 召唤入场（衍生物 / 复制 / 亡语召唤 / 效果召唤）
const EV_LEAVE := "leave"          ## 离场（死亡 / 回手 / 进墓地）
const EV_INVOKE := "invoke"        ## 瞬念召唤上场
const EV_VANISH := "vanish"        ## 消失（没有空位、从游戏中移除）
const EV_TURN_START := "turn_start"    ## 我方回合开始时（只在场上时结算）
const EV_TURN_END := "turn_end"        ## 我方回合结束时（只在场上时结算）
const EV_FUSION := "fusion"            ## 融合时（在手牌里吃掉材料之后）
## 照《影之诗》的「攻撃時」：这张卡发起攻击、伤害结算完之后结算一次
const EV_ATTACK := "attack"
## 照《影之诗》的「ダメージを受けた時」：这张卡实际受到伤害之后结算一次
const EV_DAMAGED := "damaged"

# ------------------------------ 词条大类 ------------------------------
# 非法术卡：入场 / 谢幕 / 瞬念召唤 / 被召唤 / 融合 / 离场 / 在
# 法术卡：瞬念召唤 / 被召唤（只会进入手牌）
const CAT_ENTRY := "entry"
const CAT_CURTAIN := "curtain"
const CAT_INVOKE := "invoke"
const CAT_SUMMONED := "summoned"
const CAT_FUSION := "fusion"
const CAT_LEAVE := "leave"
const CAT_ON_FIELD := "on_field"
const CAT_NAMES := {
	CAT_ENTRY: "入场",
	CAT_CURTAIN: "谢幕",
	CAT_INVOKE: "瞬念召唤",
	CAT_SUMMONED: "被召唤",
	CAT_FUSION: "融合",
	CAT_LEAVE: "离场",
	CAT_ON_FIELD: "在",
}
const CAT_ORDER := [CAT_ENTRY, CAT_CURTAIN, CAT_INVOKE, CAT_SUMMONED,
	CAT_FUSION, CAT_LEAVE, CAT_ON_FIELD]

static var _events: Dictionary = {}
static var _order: Array[String] = []
## 触发链的连锁层数上限（效果链里再触发别的卡 → 防止无限递归）
static var _depth_guard := 3


static func _ensure() -> void:
	if _events.is_empty():
		_build()


static func _build() -> void:
	# 按大类顺序注册：入场 → 瞬念召唤 → 被召唤 → 融合 → 离场 → 在
	_reg_event(EV_PLAY, "入场（打出）时", CAT_ENTRY)
	_reg_event(EV_INVOKE, "瞬念召唤上场时", CAT_INVOKE)
	_reg_event(EV_SUMMON, "被召唤入场时", CAT_SUMMONED)
	_reg_event(EV_FUSION, "融合时", CAT_FUSION)
	_reg_event(EV_LEAVE, "离场时", CAT_LEAVE)
	_reg_event(EV_VANISH, "消失时", CAT_LEAVE)
	_reg_event(EV_TURN_START, "我方回合开始时", CAT_ON_FIELD)
	_reg_event(EV_TURN_END, "我方回合结束时", CAT_ON_FIELD)
	_reg_event(EV_ATTACK, "攻击时", CAT_ON_FIELD)
	_reg_event(EV_DAMAGED, "受到伤害时", CAT_ON_FIELD)


static func _reg_event(id: String, label: String, category: String) -> void:
	_events[id] = {"id": id, "label": label, "category": category}
	_order.append(id)


# ------------------------------ 查询 / 文本 ------------------------------

static func event_ids() -> Array[String]:
	_ensure()
	return _order.duplicate()


static func event_label(id: String) -> String:
	_ensure()
	return str(_events[id]["label"]) if _events.has(id) else id


static func has_event(id: String) -> bool:
	_ensure()
	return _events.has(id)


## 这个时机属于哪个大类（入场 / 瞬念召唤 / 被召唤 / 融合 / 离场 / 在）
static func category_of(id: String) -> String:
	_ensure()
	return str(_events.get(id, {}).get("category", ""))


static func category_label(category: String) -> String:
	return str(CAT_NAMES.get(category, category))


static func category_order() -> Array:
	return CAT_ORDER.duplicate()


## 带大类的下拉文本：「[入场] 入场（打出）时」
static func dropdown_label(id: String) -> String:
	_ensure()
	var cat := category_of(id)
	if cat == "":
		return event_label(id)
	return "[%s] %s" % [category_label(cat), event_label(id)]


## 法术卡只有「瞬念召唤 / 被召唤」两个词条大类（被召唤 = 进入手牌）
static func spell_event_allowed(id: String) -> bool:
	return id == EV_INVOKE or id == EV_SUMMON


## 按卡牌种类判断这个时机是否合法（非法术卡全部合法；法术只允许上面两个）
static func event_allowed_for_type(card_type: int, id: String) -> bool:
	if card_type == CardData.CardType.SPELL:
		return spell_event_allowed(id)
	return true


## 一条触发的人话：「召唤入场时：抽 1 张」
static func text(spec: Dictionary) -> String:
	_ensure()
	if spec.is_empty():
		return ""
	var on := event_label(str(spec.get("on", "")))
	var body := ""
	var chain: Variant = spec.get("effects", [])
	if typeof(chain) == TYPE_ARRAY and not (chain as Array).is_empty():
		body = CardData.new().chain_text(chain)
	return "%s：%s" % [on, body] if body != "" else on


## 读卡表时的安全归一：缺键 / 类型不对一律补默认值
static func normalized(raw: Variant) -> Dictionary:
	_ensure()
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var src: Dictionary = raw
	var on := str(src.get("on", EV_PLAY)).strip_edges()
	if on == "":
		on = EV_PLAY
	var fx: Variant = src.get("effects", [])
	return {"on": on, "effects": fx if typeof(fx) == TYPE_ARRAY else []}


## 结构自检（效果链由 CardDB / 面板另外校验）
static func errors(spec: Dictionary) -> Array[String]:
	_ensure()
	var out: Array[String] = []
	if spec.is_empty():
		return out
	if not has_event(str(spec.get("on", ""))):
		out.append("触发时机 %s 未登记（可用：%s）" % [str(spec.get("on", "")), "、".join(event_ids())])
	var chain: Variant = spec.get("effects", [])
	if typeof(chain) != TYPE_ARRAY or (chain as Array).is_empty():
		out.append("这条触发效果没有配效果（触发了也不会发生任何事）")
	return out


# ------------------------------ 结算 ------------------------------

## 卡牌级触发（没有场上单位：入场 / 瞬念召唤 / 消失）
static func fire_card(gm, pid: int, card: CardData, event: String) -> int:
	_ensure()
	if gm == null or card == null or card.triggers.is_empty() or not has_event(event):
		return 0
	return _run(gm, pid, card, null, event)


## 单位级触发（召唤 / 离场 / 回合开始 / 回合结束）：`source_unit` 作为效果来源，
## 这样吸血 / 剧毒这类「由来源造成」的机制照常生效。
static func fire_unit(gm, pid: int, u: BoardUnit, event: String) -> int:
	_ensure()
	if gm == null or u == null or u.data == null or u.data.triggers.is_empty() \
			or not has_event(event):
		return 0
	return _run(gm, pid, u.data, u, event)


static func _run(gm, pid: int, card: CardData, source: BoardUnit, event: String) -> int:
	var fired := 0
	var depth := int(gm.get("_trigger_depth"))
	if depth >= _depth_guard:
		gm._log("  触发效果的连锁层数已到上限（%d），本次不再继续" % _depth_guard)
		return 0
	gm.set("_trigger_depth", depth + 1)
	for raw in card.triggers:
		var spec := normalized(raw)
		if spec.is_empty() or str(spec.get("on", "")) != event:
			continue
		var chain: Variant = spec.get("effects", [])
		if typeof(chain) != TYPE_ARRAY or (chain as Array).is_empty():
			continue
		gm._log("  ☆ 「%s」触发%s → %s" % [card.card_name, event_label(event), text(spec)])
		gm._resolve_chain(pid, card, chain, -1, -1, source, false)
		fired += 1
	gm.set("_trigger_depth", depth)
	return fired
