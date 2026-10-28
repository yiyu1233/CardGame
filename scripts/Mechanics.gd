class_name Mechanics
extends RefCounted
## ============================ 机制（关键字）总表 ============================
##
## 【新增一个机制，只需要改两个地方】
##   ① 在 `CardData.Keyword` 枚举里加一个 ID（例如 `STALWART = 11`）；
##   ② 在本文件底部的「新增机制就在这里加」区块里加**一行** `_reg(...)`。
## 卡表 JSON 的 `keywords` 写对应的 key（如 `"stalwart"`）即可生效，并请在
## `CardData.KEYWORD_NAMES` / `KEYWORD_KEYS` 各补一行（卡面文字与读取用）。
##
## 若这个机制只是「限制 / 免疫 / 不能攻击」这类**布尔规则**，第二步就够了：
## 在 `_reg(...)` 的 `flags` 里写标志名，引擎会在对应判定点自动生效，**不用改引擎**：
##   cannot_attack      无法攻击
##   no_attack_cost     攻击不消耗本回合攻击次数
##   untargetable_by_foe 不能被敌方指定为目标（自己人 / 群体效果照常）
##   immune_damage      免疫所有伤害
##   only_one_damage    受到的任何伤害减为 1
##
## 若机制需要**主动做事**（例：吸血、剧毒、死亡复活），再写一个钩子函数并挂上。
## 引擎**真正会派发**的钩子只有下面这几个（见常量 `DISPATCHED_HOOKS`，`audit()` 会对齐；
## 挂了清单外的名字 = 永远不会被调用，自检会报 `bad_hooks`）：
##   modify_damage        伤害结算前修正数值（ev.amount 可改写）
##   on_damage_dealt      我方造成伤害之后（吸血 / 剧毒）
##   on_damaged           我方受到伤害之后（激怒）
##   on_attack            我方发起攻击时（潜行解除）
##   on_death             我方死亡时（在死亡结算 `_cleanup_deaths` 里派发；亡语由 CardEffects 负责，二者可并存）
##   on_turn_start        我方回合开始时（在回合开始流程 `_start_turn` 里派发）
##   can_be_targeted      查询型：能否被“指定为目标”（ev.allowed 可改写）
## 尚未派发（预留，暂不能挂）：on_heal（治疗路径分散，需要时先补派发点再登记）。
##
## 事件 `ev`（字典）常用键：
##   gm / source / source_pid / target / target_pid / amount / keyword /
##   unit（被查询的随从）/ by_pid（想指定目标的玩家）/ allowed（查询结果）
##
## 除此之外还有一张**互斥表**：两个机制同时挂在一个单位身上会互相拆台、其中一个让另一个
## 彻底失效的组合（例如潜行 vs 嘲讽、迟钝 vs 冲锋）。引擎的口径是
## **后给予的效果覆盖冲突的那个**：赋予一个机制时，先把它身上与它互斥的旧机制摘掉
## （见 `Mechanics.conflicts_of()`、`BoardUnit.add_keyword()`、`EffectContext.grant_keyword()`）。
## 注意这条只对**运行时被赋予**的效果成立；一张卡自己印着两个互斥词条没有先后之分，保持原样。
##
## 自检：`Mechanics.audit()` 会比对「枚举 / 注册表 / 名称表 / key 表」是否一致，
## 测试 `tools/mechanics_api_test.gd` 会断言它是干净的——漏注册会被当场抓住。
## ============================================================================

## 声明式标志位（引擎读取；见文件头说明）
const FLAG_CANNOT_ATTACK := "cannot_attack"
const FLAG_NO_ATTACK_COST := "no_attack_cost"
const FLAG_UNTRACKABLE := "untargetable_by_foe"
const FLAG_IMMUNE := "immune_damage"
const FLAG_ONLY_ONE_DAMAGE := "only_one_damage"
## 无法被「能力破坏」：消灭 / 剧毒这类直接把血量打成 0 的破坏对它无效（伤害仍然能打死它）
const FLAG_IMMUNE_ABILITY_DESTROY := "immune_ability_destroy"
## 不受能力伤害：非碰撞伤害（法术 / 战吼 / 技能）为 0；碰撞伤害照常
const FLAG_IMMUNE_ABILITY_DAMAGE := "immune_ability_damage"
## 不受碰撞伤害：碰撞双方任意一张有这个效果 → 双方都受 0 点伤害（攻击主战者同样为 0）
const FLAG_IMMUNE_COLLISION_DAMAGE := "immune_collision_damage"

## 标志位 → 中文说明（文档 / 自检输出用）
const FLAG_DESCS := {
	FLAG_CANNOT_ATTACK: "无法攻击",
	FLAG_NO_ATTACK_COST: "攻击不消耗本回合的攻击次数",
	FLAG_UNTRACKABLE: "不能被敌方指定为目标",
	FLAG_IMMUNE: "免疫所有伤害",
	FLAG_ONLY_ONE_DAMAGE: "受到的任何伤害减为 1",
	FLAG_IMMUNE_ABILITY_DESTROY: "无法被能力破坏",
	FLAG_IMMUNE_ABILITY_DAMAGE: "不受能力伤害",
	FLAG_IMMUNE_COLLISION_DAMAGE: "不受碰撞伤害",
}

## 引擎**真正会派发**的钩子 —— 只有在这个清单里的名字才会有 `Mechanics.dispatch()` 调用点。
## 机制在 `hooks` 里挂了清单外的名字 = 那个钩子永远不会被调用（配了却不生效），
## `audit()` 会把它报成 `bad_hooks`，新增机制时挂错名字会被自检当场抓住。
const DISPATCHED_HOOKS := [
	"modify_damage",      ## 伤害结算前修正数值（GameManager 的伤害管线）
	"on_damage_dealt",    ## 造成伤害之后（吸血 / 剧毒）
	"on_damaged",         ## 受到伤害之后
	"on_attack",          ## 发起攻击时（潜行解除）
	"on_death",           ## 死亡结算时（_cleanup_deaths）
	"on_turn_start",      ## 自己回合开始时（_start_turn）
	"can_be_targeted",    ## 查询型：能否被指定为目标
]

static var _registry: Dictionary = {}
static var _order: Array[int] = []
## 互斥表：`机制 -> 与它互斥的机制列表`（对称，见 `_reg_conflict`）
static var _conflicts: Dictionary = {}
## 「状态」层面的互斥：冻结不是词条（不能进上面的表），但同样会与某些机制互相拆台。
## 冻结 = 到某一回合为止不能攻击 ↔ 冲锋 / 突袭 = 当回合就能攻击 —— 后到者覆盖。
const STATUS_FROZEN := "frozen"
## 觉醒（影之诗「覚醒」）的主战者生命阈值：我方主战者生命 ≤ 这个数就算「已觉醒」
const AWAKEN_HP := 10

static func _ensure() -> void:
	if _registry.is_empty():
		_register()

## 登记一对互斥的机制（两边都能查到）
static func _reg_conflict(a: int, b: int) -> void:
	if a == b:
		return
	for pair in [[a, b], [b, a]]:
		var k: int = pair[0]
		var other: int = pair[1]
		if not _conflicts.has(k):
			_conflicts[k] = []
		var list: Array = _conflicts[k]
		if not list.has(other):
			list.append(other)

static func _reg(keyword: int, display: String, desc: String, hooks: Dictionary = {},
		flags: Array = []) -> void:
	_registry[keyword] = {
		"keyword": keyword,
		"name": display,
		"desc": desc,
		"hooks": hooks,
		"flags": flags,
	}
	if not _order.has(keyword):
		_order.append(keyword)

## 运行期注册（测试 / 外挂模块可用；正常机制请写在下方区块里）。
## 重复注册同一个 ID = 覆盖并**移到末尾**：这里先把它从顺序表里摘掉，
## `_reg()` 会把它重新 append 回去（**注意别再 append 一次**，否则顺序表里会出现重复项，
## `keywords()` / `dispatch()` 都会跟着重复）。
static func register(keyword: int, display: String, desc: String, hooks: Dictionary = {},
		flags: Array = []) -> void:
	_ensure()
	_order.erase(keyword)
	_reg(keyword, display, desc, hooks, flags)

# ============================ 新增机制就在这里加 ============================
#
# 一行一个：_reg(CardData.Keyword.XXX, "中文名", "说明", {钩子...}, [标志...])
#
static func _register() -> void:
	# ---- 自身状态型（判定实现在 BoardUnit 里，这里只登记名称与说明）----
	_reg(CardData.Keyword.TAUNT, "嘲讽", "敌方必须先攻击它。")
	_reg(CardData.Keyword.CHARGE, "冲锋", "召唤当回合即可攻击，也能打英雄。")
	_reg(CardData.Keyword.RUSH, "突袭", "召唤当回合即可攻击随从，但不能打英雄。")
	_reg(CardData.Keyword.DIVINE_SHIELD, "圣盾", "免疫下一次伤害后消失。")
	_reg(CardData.Keyword.WINDFURY, "风怒", "每回合可以攻击两次。")

	# ---- 声明式：只写标志位，引擎自动生效 ----
	_reg(CardData.Keyword.STEALTH, "潜行", "无法被敌方指定为目标；攻击后解除。",
		{"on_attack": Mechanics._hook_break_stealth}, [FLAG_UNTRACKABLE])
	_reg(CardData.Keyword.STALWART, "坚壁", "受到的任何伤害减为 1。", {}, [FLAG_ONLY_ONE_DAMAGE])
	_reg(CardData.Keyword.SLUGGISH, "迟钝", "无法攻击。", {}, [FLAG_CANNOT_ATTACK])
	_reg(CardData.Keyword.INDESTRUCTIBLE, "不灭",
		"不会被能力破坏（消灭 / 剧毒无效）；造成的伤害仍然能把它打死。",
		{}, [FLAG_IMMUNE_ABILITY_DESTROY])
	_reg(CardData.Keyword.ABILITY_DAMAGE_IMMUNE, "术法免疫",
		"不受能力伤害（法术 / 战吼 / 技能）；碰撞伤害照常，也能被能力破坏。",
		{}, [FLAG_IMMUNE_ABILITY_DAMAGE])
	_reg(CardData.Keyword.COLLISION_DAMAGE_IMMUNE, "碰撞免疫",
		"不受碰撞伤害：碰撞双方任意一张有这个效果时双方都受 0 点伤害，攻击主战者同为 0。",
		{}, [FLAG_IMMUNE_COLLISION_DAMAGE])

	# ---- 需要钩子：数值 / 触发型 ----
	_reg(CardData.Keyword.LIFESTEAL, "吸血", "造成伤害后，为你的英雄恢复等量生命。",
		{"on_damage_dealt": Mechanics._hook_lifesteal})
	_reg(CardData.Keyword.POISONOUS, "剧毒", "受到它伤害的随从会被消灭。",
		{"on_damage_dealt": Mechanics._hook_poisonous})
	# 影之诗「覚醒」：自军主战者生命 ≤ 10 时 +1/+1。用两个钩子保证「进入觉醒线的那一刻」就能生效
	# （回合开始与受到伤害时各查一次），触发一次后保留（BoardUnit.awaken_done）。
	_reg(CardData.Keyword.AWAKEN, "觉醒",
		"我方主战者生命 ≤ %d 时，这个随从 +1/+1（触发一次后保留）。" % AWAKEN_HP,
		{"on_turn_start": Mechanics._hook_awaken, "on_damaged": Mechanics._hook_awaken})

	# ---- 由引擎在固定位置读取（无钩子）----
	_reg(CardData.Keyword.REBORN, "复生", "第一次死亡时会以 1 点生命回到战场（亡语照常结算一次）。")
	_reg(CardData.Keyword.SPELL_DAMAGE, "法术伤害", "法术伤害 +N：你的伤害性法术额外造成 N 点伤害（多张叠加）。")

	# ---- 互斥：同时对也无意义，运行时被赋予时**后到者覆盖**先到的那一方 ----
	_reg_conflict(CardData.Keyword.STEALTH, CardData.Keyword.TAUNT)      # 不能被打 vs 必须被打
	_reg_conflict(CardData.Keyword.SLUGGISH, CardData.Keyword.CHARGE)    # 不能攻击 vs 当回合能攻击
	_reg_conflict(CardData.Keyword.SLUGGISH, CardData.Keyword.RUSH)      # 同上（也应互斥）

# ============================ 以上为唯一需要手改的区块 ============================

# ============================ 对外接口 ============================

static func keywords() -> Array[int]:
	_ensure()
	return _order.duplicate()

static func has(keyword: int) -> bool:
	_ensure()
	return _registry.has(keyword)

static func display_name(keyword: int) -> String:
	_ensure()
	return str(_registry.get(keyword, {}).get("name", "未知机制"))

static func describe(keyword: int) -> String:
	_ensure()
	return str(_registry.get(keyword, {}).get("desc", ""))

static func has_hook(keyword: int, hook: String) -> bool:
	_ensure()
	var hooks: Dictionary = _registry.get(keyword, {}).get("hooks", {})
	return hooks.has(hook)

## 该机制是否声明了某个标志位
static func has_flag(keyword: int, flag: String) -> bool:
	_ensure()
	var flags: Array = _registry.get(keyword, {}).get("flags", [])
	return flags.has(flag)

## 该随从（含它身上所有机制）是否具备某个标志位 —— 引擎各判定点统一问这一句
static func flag(unit: BoardUnit, flag: String) -> bool:
	if unit == null:
		return false
	for k in unit.keywords:
		if has_flag(k, flag):
			return true
	return false

## 与 `keyword` 互斥的机制：赋予它会把这些先到的机制覆盖掉（摘掉）。
static func conflicts_of(keyword: int) -> Array[int]:
	_ensure()
	var out: Array[int] = []
	for k in _conflicts.get(keyword, []):
		if not out.has(k):
			out.append(k)
	return out


## 两个机制是否互斥
static func conflicts_with(a: int, b: int) -> bool:
	return conflicts_of(a).has(b)


## 某个**非词条状态**（目前只有 STATUS_FROZEN）与之互斥的机制
static func status_conflicts(status: String) -> Array[int]:
	if status == STATUS_FROZEN:
		return [CardData.Keyword.CHARGE, CardData.Keyword.RUSH]
	return []


## 面向管理员面板 / 卡面提示：一行的机制摘要
static func summary(keyword: int) -> String:
	return "%s：%s" % [display_name(keyword), describe(keyword)]

## 一致性自检：枚举 / 注册表 / 名称表 / key 表 是否四方对齐
static func audit() -> Dictionary:
	_ensure()
	var missing: Array[String] = []      ## 枚举里有、注册表里没有
	var unnamed: Array[String] = []      ## 注册了但没中文名
	var unkeyed: Array[String] = []      ## 有名字但没有卡表 key（JSON 读不出来）
	var unknown_flags: Array[String] = []
	var bad_hooks: Array[String] = []        ## 挂了引擎不会派发的钩子（配了也不生效）
	var bad_conflicts: Array[String] = []    ## 互斥表里指向了没注册的机制
	## 枚举里有、但 KEYWORD_NAMES 没登记：这种词条**永远不会有名字**，
	## 管理员面板不会显示它、卡表也写不进去 —— 属于「加了枚举却忘了登记」的静默失败。
	## 以前以 KEYWORD_NAMES 为基准遍历，所以这类漏登记根本查不出来；这里补上。
	var missing_meta: Array[String] = []
	for keyword in CardData.Keyword.values():
		if not CardData.KEYWORD_NAMES.has(keyword):
			missing_meta.append(str(keyword))
	for keyword in CardData.KEYWORD_NAMES.keys():
		if not has(keyword):
			missing.append(CardData.KEYWORD_NAMES.get(keyword, str(keyword)))
			continue
		if display_name(keyword) == "" or describe(keyword) == "":
			unnamed.append(str(keyword))
		if not CardData.has_keyword_key(keyword):
			unkeyed.append(display_name(keyword))
	for keyword in _order:
		for f in _registry.get(keyword, {}).get("flags", []):
			if not FLAG_DESCS.has(f):
				unknown_flags.append("%s(%s)" % [display_name(keyword), str(f)])
		# 钩子必须落在「引擎真的会派发」的白名单里，否则它永远不会被调用
		for h in _registry.get(keyword, {}).get("hooks", {}).keys():
			if not DISPATCHED_HOOKS.has(str(h)):
				bad_hooks.append("%s(%s)" % [display_name(keyword), str(h)])
	for keyword in _conflicts.keys():
		if not has(keyword):
			bad_conflicts.append("未注册(%s)" % str(keyword))
			continue
		for other in _conflicts.get(keyword, []):
			if not has(other):
				bad_conflicts.append("%s ↔ 未注册(%s)" % [display_name(keyword), str(other)])
			elif not conflicts_with(other, keyword):
				bad_conflicts.append("%s ↔ %s 不对称" % [display_name(keyword), display_name(other)])
	return {
		"ok": (missing.is_empty() and unnamed.is_empty() and unkeyed.is_empty()
			and missing_meta.is_empty() and unknown_flags.is_empty()
			and bad_hooks.is_empty() and bad_conflicts.is_empty()),
		"count": _order.size(),
		"conflict_pairs": _conflict_pair_count(),
		"missing": missing,
		"unnamed": unnamed,
		"unkeyed": unkeyed,
		"missing_meta": missing_meta,
		"unknown_flags": unknown_flags,
		"bad_hooks": bad_hooks,
		"bad_conflicts": bad_conflicts,
	}


## 互斥表里一共登记了多少**对**（无向去重）
static func _conflict_pair_count() -> int:
	_ensure()
	var seen := {}
	var out: Array[int] = []
	for keyword in _conflicts.keys():
		for other in _conflicts.get(keyword, []):
			var a: int = mini(keyword, other)
			var b: int = maxi(keyword, other)
			var key := "%d|%d" % [a, b]
			if seen.has(key):
				continue
			seen[key] = true
			out.append(a)
	return out.size()

## 把一个钩子派发给随从身上携带的所有机制，返回（可能被钩子改写过的）事件字典。
## 单向钩子也走同一条路径，保证「一个机制一个入口」，新增机制不用改引擎。
static func dispatch(unit: BoardUnit, hook: String, ev: Dictionary) -> Dictionary:
	if unit == null:
		return ev
	for k in unit.keywords:
		call_hook(k, hook, ev)
	return ev

static func call_hook(keyword: int, hook: String, ev: Dictionary) -> void:
	_ensure()
	var entry: Dictionary = _registry.get(keyword, {})
	if entry.is_empty():
		return
	var hooks: Dictionary = entry.get("hooks", {})
	if not hooks.has(hook):
		return
	ev["keyword"] = keyword
	ev["hook"] = hook          # 事件里带上钩子名，便于测试探针与调试
	var fn: Callable = hooks[hook]
	fn.call(ev)

## 能否把 `unit` 指定为目标。标志位与 `can_be_targeted` 钩子都会生效。
## 只用于“玩家 / AI 主动指定目标”，随机与群体效果不受影响（与主流卡牌游戏一致）。
static func can_be_targeted(unit: BoardUnit, by_pid: int) -> bool:
	if unit == null:
		return false
	if by_pid != unit.owner_id and flag(unit, FLAG_UNTRACKABLE):
		return false
	var ev := {"unit": unit, "by_pid": by_pid, "allowed": true}
	dispatch(unit, "can_be_targeted", ev)
	return bool(ev.get("allowed", true))

# ============================ 钩子实现 ============================

## 吸血：按“实际造成的伤害”给我方英雄回血（被圣盾挡下时为 0，不回血）

static func _hook_lifesteal(ev: Dictionary) -> void:
	var gm = ev.get("gm")
	var amount: int = int(ev.get("amount", 0))
	if gm == null or amount <= 0:
		return
	var source: BoardUnit = ev.get("source")
	if source == null:
		return
	var owner_id: int = source.owner_id
	if owner_id != int(ev.get("source_pid", owner_id)):
		return
	var p: PlayerState = gm.get_player(owner_id)
	if p == null:
		return
	var before: int = p.hero_hp
	p.hero_hp = mini(p.hero_max_hp, p.hero_hp + amount)
	var healed: int = p.hero_hp - before
	if healed > 0:
		gm.amount_shown.emit(p.player_id, -1, healed, "heal")
		gm.log_line("  「%s」吸血：%s 恢复 %d 点生命（当前 %d）" % [
			source.data.card_name, p.display_name, healed, p.hero_hp])

## 剧毒：对随从造成伤害后直接消灭它（对英雄无效）
static func _hook_poisonous(ev: Dictionary) -> void:
	var target: BoardUnit = ev.get("target")
	var source: BoardUnit = ev.get("source")
	if target == null or source == null:
		return
	if int(ev.get("amount", 0)) <= 0:
		return
	if not target.is_alive():
		return
	var gm = ev.get("gm")
	# 词条「不灭」：剧毒同样是“破坏”，对它无效（伤害本身照常结算）
	if Mechanics.flag(target, Mechanics.FLAG_IMMUNE_ABILITY_DESTROY):
		if gm != null:
			gm.log_line("  「%s」不灭：剧毒无法消灭「%s」" % [source.data.card_name, target.data.card_name])
		return
	target.health = 0
	if gm != null:
		gm.log_line("  「%s」剧毒：消灭「%s」" % [source.data.card_name, target.data.card_name])

## 潜行：攻击后解除（“不能被敌方指定”已由 FLAG_UNTRACKABLE 标志位负责）
static func _hook_break_stealth(ev: Dictionary) -> void:
	var source: BoardUnit = ev.get("source")
	if source == null:
		return
	if source.has_keyword(CardData.Keyword.STEALTH):
		source.remove_keyword(CardData.Keyword.STEALTH)
		var gm = ev.get("gm")
		if gm != null:
			gm.log_line("  「%s」的潜行解除" % source.data.card_name)


## 觉醒：我方主战者生命降到阈值以内 → 这个随从 +1/+1（只结算一次，之后保留）
static func _hook_awaken(ev: Dictionary) -> void:
	var u: BoardUnit = ev.get("unit")
	if u == null:
		u = ev.get("target")
	if u == null or u.awaken_done or u.is_permanent():
		return
	var gm = ev.get("gm")
	if gm == null:
		return
	var p: PlayerState = gm.get_player(u.owner_id)
	if p == null or p.hero_hp > AWAKEN_HP:
		return
	u.awaken_done = true
	u.attack += 1
	u.health += 1
	u.max_health += 1
	gm.log_line("  「%s」觉醒：主战者生命 %d ≤ %d → +1/+1（现在 %d/%d）" % [
		u.data.card_name, p.hero_hp, AWAKEN_HP, u.attack, u.health])
