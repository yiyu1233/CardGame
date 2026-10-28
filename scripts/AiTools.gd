class_name AiTools
extends RefCounted
## AI 助手的工具集（agent 用）：把「卡表 / 机制 / 当前对局局面」整理成 AI 能读的文本，
## 并执行 AI 发出的工具调用。
##
## 设计口径：
##   * **只读**：本文件只回答「是什么 / 现在怎么样」，不替玩家点按钮。想加「代打」类操作时，
##     在这里加一个执行函数、把名字注册进 `catalog()` 即可（界面上另有确认层再说）。
##   * **随叫随到**：工具目录每轮请求都拼进 system 提示词，AI 想用就发
##     `[[tool: {"name":"card_search","args":{"query":"嘲讽"}}]]`；
##     `AiAssistant` 负责解析、执行、把结果塞回去再来一轮。
##   * **不塞全卡表**：卡表 70+ 张，全量塞进提示词太贵；让 AI 按需检索。
##
## 与游戏数据的关系：卡表读 `CardDB`（自动加载），局面读 `GameManager`（自动加载），
## 两者都可能在无头测试里缺席——本文件全部做了空值保护，取不到就返回人话。

const CardDataScript := preload("res://scripts/CardData.gd")
const MechanicsScript := preload("res://scripts/Mechanics.gd")

## card_search 返回条数上限（提示词里说明，避免上下文爆掉）
const SEARCH_LIMIT := 40
## 工具结果文本上限（字符）：超出截断，防止一次检索把整轮上下文挤满
const MAX_RESULT_CHARS := 6000
## game_state 读取的最近日志行数（战斗日志可能很长，只取尾部）
const LOG_TAIL := 12


# ------------------------------ 工具目录（给 AI 看的说明书） ------------------------------

## 返回 [{name, desc, args}]；AiAssistant 把它拼进 system 提示词
static func catalog() -> Array[Dictionary]:
	return [
		{
			"name": "card_search",
			"desc": "按关键词检索卡表。query 会匹配卡名与卡 id；可选过滤：type（随从/法术/护符/城邦或 0-3）、max_cost、keyword（关键字名，如 嘲讽）。返回最多 %d 条「卡名（费用 攻/血 · 类型）」。" % SEARCH_LIMIT,
			"args": {"query": "字符串，可为空", "type": "可选，种类", "max_cost": "可选，整数", "keyword": "可选，关键字名"},
		},
		{
			"name": "card_detail",
			"desc": "查一张卡的完整资料：效果链、亡语、关键字、主动技能、瞬念召唤、融合、所属职业与兵种。入参给卡名或卡 id（支持部分匹配）。",
			"args": {"name": "卡名或卡 id"},
		},
		{
			"name": "game_state",
			"desc": "读当前对局局面：回合数、轮到谁、双方主战者血量/护甲/法力、手牌与战场明细、关键倒数与横置格。对局未开始或人机之外的模式返回说明文本。",
			"args": {},
		},
		{
			"name": "mechanic_info",
			"desc": "查关键字的含义与互斥关系（如 嘲讽、圣盾、冲锋、剧毒、潜行）。不传参数时列出全部关键字。",
			"args": {"keyword": "可选，关键字名"},
		},
	]


## 拼进 system 提示词的工具使用说明（目录 + 格式 + 示例）
static func prompt_block() -> String:
	var lines := PackedStringArray()
	lines.append("可用工具：")
	for t in catalog():
		var sig := ""
		var args: Dictionary = t.get("args", {})
		for k in args.keys():
			if sig != "":
				sig += ", "
			sig += str(k)
		lines.append("- %s(%s)：%s" % [t.get("name", ""), sig, t.get("desc", "")])
	lines.append("")
	lines.append("调用格式（独占一行）：[[tool: {\"name\":\"工具名\",\"args\":{...}}]]")
	lines.append("示例：[[tool: {\"name\":\"card_search\",\"args\":{\"query\":\"龙\",\"max_cost\":5}}]]")
	lines.append("可以一次连发多条；结果会以 [[tool_result name=...]] 回给你。")
	return "\n".join(lines)


# ------------------------------ 执行 ------------------------------

## 从 AI 回复里解析工具调用：支持
##   [[tool: {"name":"card_search","args":{...}}]]
##   [[tool:{"name":"card_search","args":{...}}]]          （冒号后可无空格）
##   {"tool_calls":[{"name":"...","arguments":{...}}]}      （部分直连模型的 JSON 壳）
## 返回 [{name, args}]；格式坏掉的行忽略。
static func parse_tool_calls(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if text.strip_edges().is_empty():
		return out
	var re := RegEx.new()
	re.compile("\\[\\[\\s*tool\\s*:\\s*(\\{.*?\\})\\s*\\]\\]")
	for m in re.search_all(text):
		var payload := m.get_string(1)
		var data: Variant = JSON.parse_string(payload)
		if data is Dictionary:
			var call := _call_from_dict(data as Dictionary)
			if not call.is_empty():
				out.append(call)
	if out.is_empty():
		# JSON 壳：{"tool_calls":[{"name":..,"arguments":..}]}（只在像 JSON 时才解析，避免报错刷屏）
		var s := text.strip_edges()
		if s.begins_with("{"):
			var wrapped: Variant = JSON.parse_string(s)
			if wrapped is Dictionary and (wrapped as Dictionary).has("tool_calls"):
				var calls: Variant = (wrapped as Dictionary).get("tool_calls")
				if calls is Array:
					for c in (calls as Array):
						if c is Dictionary:
							var call2 := _call_from_dict(c as Dictionary)
							if not call2.is_empty():
								out.append(call2)
	return out


static func _call_from_dict(d: Dictionary) -> Dictionary:
	var name := str(d.get("name", "")).strip_edges()
	var args: Variant = d.get("args", d.get("arguments", {}))
	if name.is_empty():
		return {}
	if not (args is Dictionary):
		args = {}
	return {"name": name, "args": args}


## 去掉工具调用行之后剩下给玩家看的正文（工具行整行删除，前后空行归并）
static func visible_text(text: String) -> String:
	var out := PackedStringArray()
	var in_call := false
	for line in text.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("[[tool:") or s.begins_with("[[ tool:"):
			var oneline := s.ends_with("]]") and s.find("]]") > 0
			if not oneline:
				in_call = true
			continue
		if in_call:
			if s.ends_with("]]") or s.find("]]") >= 0:
				in_call = false
			continue
		out.append(line)
	# JSON 壳整段：解析成功且有 tool_calls 就视为没有正文
	var trimmed := "\n".join(out).strip_edges()
	if trimmed.is_empty() and not parse_tool_calls(text).is_empty():
		return ""
	return trimmed


# ------------------------------ 提示词里的规则速览 ------------------------------

## 内置规则速览：借 CardData.summary_lines()（卡面详情与这里共用一份事实），
## 外加界面上的操作口径。放这里而不是直接在 AiAssistant 里拼，方便测试独立断言。
static func rules_text() -> String:
	var lines := PackedStringArray()
	lines.append("【玩法】回合制随从对战：每回合法力上限 +1（最多 10），回合开始抽 1 张、重置己方攻击次数；随从当回合召唤不能攻击（冲锋 / 突袭例外）；战场最多 7 格、手牌上限 10 张；疲劳按 1、2、3…递增扣血。")
	lines.append("【关键字】嘲讽（敌方必须先攻击它）、圣盾（免疫一次伤害）、冲锋（当回合可攻击）、突袭（当回合只能打随从）、风怒（每回合可攻击两次）、吸血（按实际伤害回血）、剧毒（伤害后消灭随从）、潜行（敌方不可指定，攻击后解除）；互斥项后到者覆盖（潜行 ↔ 嘲讽 等）。")
	lines.append("【地带】城邦格在主战者旁（不占战场，每 3 个自己的回合判定一次自动召唤；整副牌组合计最多 2 张城邦）；中线前的横置格里的随从只受 1 点伤害、不能行动，受伤后退回后排。")
	lines.append("【卡牌】随从 / 法术 / 护符（安放：效果，有耐久）/ 城邦；护符与城邦的耐久即生命值、不能攻击；法术没有合法目标时打不出。")
	lines.append("【目标】指定类战吼 / 安放没有合法目标时照样上场、效果空放；法术则无法释放。")
	lines.append("【出牌方式】战吼（从手牌打出自动结算）、亡语（死亡结算）、召唤入场不结算入场效果（要补就用「触发一次入场效果」）。")
	lines.append("【操作】拖拽手牌到战场出牌（需目标的法术拖到高亮目标）、拖随从到敌方目标攻击；空格结束回合、Tab 记牌器、F1 快捷键说明。")
	return "\n".join(lines)


## 执行一次工具调用。返回给 AI 看的纯文本；未知工具 / 参数坏掉都返回人话（不抛错）。
static func run_tool(name: String, args: Dictionary) -> String:
	var text := ""
	match name:
		"card_search":
			text = search_cards(str(args.get("query", "")).strip_edges(),
				str(args.get("type", "")), args.get("max_cost", null), str(args.get("keyword", "")))
		"card_detail":
			text = card_detail(str(args.get("name", "")).strip_edges())
		"game_state":
			text = game_state()
		"mechanic_info":
			text = mechanic_info(str(args.get("keyword", "")).strip_edges())
		_:
			text = "未知工具「%s」。可用工具：%s" % [name, _tool_names()]
	if text.length() > MAX_RESULT_CHARS:
		text = text.substr(0, MAX_RESULT_CHARS) + "\n…（结果过长已截断）"
	return text


static func _tool_names() -> String:
	var names := PackedStringArray()
	for t in catalog():
		names.append(str(t.get("name", "")))
	return ", ".join(names)


# ------------------------------ 卡表检索 ------------------------------

static func _db() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("CardDB")
	return null


static func cards() -> Array:
	var db := _db()
	if db == null:
		return []
	return db.cards


## 检索卡表。query 匹配卡名 / 卡 id；type 接受「随从 / 法术 / 护符 / 城邦」或 0-3；
## keyword 匹配关键字名（含运行时注册的机制）。全部条件是与关系。
static func search_cards(query: String, type_filter: String = "", max_cost: Variant = null,
		keyword: String = "") -> String:
	var list := cards()
	if list.is_empty():
		return "卡表为空（CardDB 未加载）。"
	var q := query.to_lower()
	var want_type := _type_value(type_filter)
	var cost_cap := -1
	if max_cost != null and (typeof(max_cost) == TYPE_INT or typeof(max_cost) == TYPE_FLOAT):
		cost_cap = int(max_cost)
	var kw := keyword.strip_edges()

	var hits: Array[CardData] = []
	for c in list:
		if q != "" and not (c.card_name.to_lower().contains(q) or c.id.to_lower().contains(q)):
			continue
		if want_type >= 0 and int(c.card_type) != want_type:
			continue
		if cost_cap >= 0 and c.cost > cost_cap:
			continue
		if kw != "" and not _has_keyword_named(c, kw):
			continue
		hits.append(c)
	hits.sort_custom(func(a: CardData, b: CardData) -> bool:
		if a.cost != b.cost:
			return a.cost < b.cost
		return a.card_name < b.card_name)

	if hits.is_empty():
		return "没有匹配的卡（条件：query=%s type=%s max_cost=%s keyword=%s）。" % [
			query, type_filter, str(max_cost), keyword]
	var lines := PackedStringArray()
	lines.append("匹配 %d 张（最多列 %d）：" % [hits.size(), SEARCH_LIMIT])
	for i in hits.size():
		if i >= SEARCH_LIMIT:
			lines.append("…（还有 %d 张未列出，请缩小条件）" % (hits.size() - SEARCH_LIMIT))
			break
		lines.append(_one_line(hits[i]))
	return "\n".join(lines)


## 单行摘要：「卡名（费用 攻/血 · 随从 · id=xxx）」
static func _one_line(c: CardData) -> String:
	var bits := PackedStringArray()
	bits.append("%d费" % c.cost)
	if c.is_minion():
		bits.append("%d/%d" % [c.attack, c.health])
	elif c.is_permanent():
		bits.append("耐久 %d" % c.durability())
	var kws := c.keyword_names()
	var line := "%s（%s · %s · id=%s）" % [c.card_name, " ".join(bits), c.type_name(), c.id]
	if kws.size() > 0:
		line += " 关键字：" + "/".join(kws)
	return line


static func card_detail(name_or_id: String) -> String:
	var list := cards()
	if list.is_empty():
		return "卡表为空（CardDB 未加载）。"
	if name_or_id.is_empty():
		return "card_detail 需要一个卡名或卡 id。"
	var exact: CardData = null
	var partial: Array[CardData] = []
	var needle := name_or_id.to_lower()
	for c in list:
		if c.id == name_or_id or c.card_name == name_or_id:
			exact = c
			break
		if c.card_name.to_lower().contains(needle) or c.id.to_lower().contains(needle):
			partial.append(c)
	if exact == null:
		if partial.is_empty():
			return "卡表里没有「%s」这张卡（可用 card_search 查相近的名字）。" % name_or_id
		if partial.size() > 1:
			var names := PackedStringArray()
			for c in partial:
				names.append(_one_line(c))
			return "「%s」匹配到多张，请用更准确的名字或卡 id：\n%s" % [name_or_id, "\n".join(names)]
		exact = partial[0]
	return detail_text(exact)


## 一张卡的完整资料（卡面 + 效果链 + 各种附加能力），供工具与提示词共用
static func detail_text(c: CardData) -> String:
	var lines := PackedStringArray()
	lines.append("%s（id=%s）" % [c.card_name, c.id])
	var head := "%s · %d费 · 稀有度 %s" % [c.type_name(), c.cost, c.rarity_name()]
	if c.is_minion():
		head += " · %d攻 %d血" % [c.attack, c.health]
	elif c.is_permanent():
		head += " · 耐久 %d" % c.durability()
	if c.overload > 0:
		head += " · 过载 %d" % c.overload
	if c.countdown > 0:
		head += " · 倒数 %d" % c.countdown
	if c.spell_damage > 0:
		head += " · 法术伤害 +%d" % c.spell_damage
	lines.append(head)
	var kws := c.keyword_names()
	if kws.size() > 0:
		var descs := PackedStringArray()
		for k in kws:
			descs.append("%s（%s）" % [str(k), _keyword_desc_for(str(k))])
		lines.append("关键字：" + "；".join(descs))
	var cls := ""
	var db := _db()
	if c.class_id != CardDataScript.NEUTRAL_CLASS:
		if db != null and db.has_method("hero_class_name"):
			cls = db.hero_class_name(c.class_id)
		if cls == "":
			cls = c.class_id
	if cls != "":
		lines.append("职业：" + cls)
	if c.troop_id != "":
		var troop := c.troop_id
		if db != null and db.has_method("troop_name"):
			var tn: String = db.troop_name(c.troop_id)
			if tn != "":
				troop = tn
		lines.append("兵种：" + troop)
	var effect := c.effect_text()
	if effect != "":
		lines.append(("安放：" if c.is_permanent() else ("战吼：" if c.is_minion() else "效果：")) + effect)
	var death := c.deathrattle_text()
	if death != "":
		lines.append("亡语：" + death)
	var skill := ""
	if c.has_skill():
		skill = "主动技能「%s」：花费 %d 法力" % [c.skill_name(), c.skill_cost()]
		if c.skill_once_per_turn():
			skill += "（每回合一次）"
		lines.append(skill)
	if c.has_invocation():
		lines.append("瞬念召唤：" + c.invoke_text())
	if c.has_fusion():
		lines.append("融合：" + c.fusion_text())
	var le := c.leader_effects_text()
	if le != "":
		lines.append("主战者效果：" + le)
	var tr := c.triggers_text()
	if tr != "":
		lines.append("触发效果：" + tr)
	if c.combo_effect_id != "" and CardDataScript.is_real_effect_id(c.combo_effect_id):
		lines.append("连击：本回合已出过牌时额外触发「%s」" % CardDataScript.effects_registry().get(c.combo_effect_id, c.combo_effect_id))
	if c.is_city():
		lines.append("城邦：每套牌组合计最多 %d 张" % CardDataScript.CITY_DECK_LIMIT)
	return "\n".join(lines)


# ------------------------------ 机制解释 ------------------------------

static func mechanic_info(keyword: String) -> String:
	var ids: Array[int] = MechanicsScript.keywords()
	if ids.is_empty():
		return "机制注册表为空。"
	var want := keyword.strip_edges()
	if want.is_empty():
		var lines := PackedStringArray()
		lines.append("全部关键字（%d 个）：" % ids.size())
		for k in ids:
			lines.append("- %s：%s" % [MechanicsScript.display_name(k), MechanicsScript.describe(k)])
		return "\n".join(lines)
	for k in ids:
		if MechanicsScript.display_name(k) == want or _keyword_matches(k, want):
			var text := "%s：%s" % [MechanicsScript.display_name(k), MechanicsScript.describe(k)]
			var conflicts := MechanicsScript.conflicts_of(k)
			if conflicts.size() > 0:
				var names := PackedStringArray()
				for other in conflicts:
					names.append(MechanicsScript.display_name(other))
				text += "\n互斥（后到者覆盖）：" + "、".join(names)
			return text
	return "没有叫「%s」的关键字。可用：%s" % [want, _all_keyword_names()]


static func _all_keyword_names() -> String:
	var names := PackedStringArray()
	for k in MechanicsScript.keywords():
		names.append(MechanicsScript.display_name(k))
	return "、".join(names)


static func _keyword_matches(k: int, needle: String) -> bool:
	var key := CardDataScript.keyword_key(k)
	if key.to_lower() == needle.to_lower():
		return true
	if MechanicsScript.display_name(k).contains(needle):
		return true
	return false


## 关键字显示名 → 机制说明（配合 CardData.keyword_names() 的字符串结果使用）
static func _keyword_desc_for(display: String) -> String:
	for k in MechanicsScript.keywords():
		if MechanicsScript.display_name(k) == display:
			return MechanicsScript.describe(k)
	return ""


# ------------------------------ 当前对局局面 ------------------------------

static func game_state() -> String:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return "当前不在游戏内。"
	var gm: Node = (loop as SceneTree).root.get_node_or_null("GameManager")
	if gm == null:
		return "当前不在游戏内（GameManager 未加载）。"
	if not gm.game_active():
		return "当前没有进行中的对局。玩家可先开一局人机对战，再让我读局面。"
	var lines := PackedStringArray()
	lines.append("第 %d 回合，轮到%s。" % [gm.turn_count, "你" if gm.current_player == gm.human_id() else "对手"])
	for pid in [gm.human_id(), 1 - gm.human_id()]:
		var p = gm.get_player(pid)
		if p == null:
			continue
		lines.append(_player_text(p, pid == gm.human_id(), gm))
	# 横置格（每侧中线前那一格）
	for pid in [gm.human_id(), 1 - gm.human_id()]:
		var p = gm.get_player(pid)
		if p != null and gm.has_method("front_unit"):
			var fu = gm.front_unit(pid)
			if fu != null:
				lines.append("%s的横置格：%s（只受 1 点伤害、不能行动，受伤后退回）" % [
					"你" if pid == gm.human_id() else "对手", fu.data.card_name])
	var tail := _log_tail()
	if tail != "":
		lines.append("最近日志：\n" + tail)
	return "\n".join(lines)


static func _player_text(p, is_human: bool, gm) -> String:
	var who := "你" if is_human else "对手"
	var head := "%s：主战者 %d/%d 血" % [who, p.hero_hp, p.hero_max_hp]
	if p.armor > 0:
		head += " +%d 护甲" % p.armor
	head += "；法力 %d/%d；牌库 %d；手牌 %d；墓地 %d" % [
		p.mana, p.max_mana, p.deck.size(), p.hand.size(), p.graveyard.size()]
	if p.fatigue > 0:
		head += "；疲劳 %d" % p.fatigue
	var out := [head]
	# 手牌：本地单机 / 自己是玩家时才展示内容；对手只给张数（防止剧透）
	if is_human:
		var hand_bits := PackedStringArray()
		for i in p.hand.size():
			var c: CardData = p.hand[i]
			var can_play := false
			if gm != null and gm.has_method("can_play"):
				can_play = gm.can_play(p.player_id, i)
			hand_bits.append("[%d] %s%s" % [i, _one_line_short(c), "（可出）" if can_play else ""])
		if hand_bits.size() > 0:
			out.append("手牌：\n" + "\n".join(hand_bits))
	# 战场
	var board_bits := PackedStringArray()
	for u in p.board:
		board_bits.append(_unit_line(u, gm))
	if board_bits.size() > 0:
		out.append("战场：\n" + "\n".join(board_bits))
	else:
		out.append("战场：空")
	return "\n".join(PackedStringArray(out))


## 手牌单行：「卡名（3费 2/1 · 随从）」
static func _one_line_short(c: CardData) -> String:
	var bits := PackedStringArray()
	bits.append("%d费" % c.cost)
	if c.is_minion():
		bits.append("%d/%d" % [c.attack, c.health])
	elif c.is_permanent():
		bits.append("耐久 %d" % c.durability())
	return "%s（%s · %s）" % [c.card_name, " ".join(bits), c.type_name()]


## 战场单位单行：「#unit_id 卡名 3/2（就绪/已攻击/召唤病）」+ 状态标注
static func _unit_line(u, gm) -> String:
	var bits := PackedStringArray()
	bits.append("#%d %s %d/%d" % [u.unit_id, u.data.card_name, u.attack, u.health])
	var kws: PackedStringArray = u.mechanic_names()
	if kws.size() > 0:
		bits.append("关键字：" + "/".join(kws))
	var states := PackedStringArray()
	if u.in_city_slot:
		states.append("城邦格")
	if u.in_front:
		states.append("横置（只受 1 点伤害、不能行动）")
	if u.durability() > 0 and not u.data.is_minion():
		states.append("耐久 %d" % u.durability())
	if gm != null and gm.has_method("current_player"):
		if u.owner_id == int(gm.current_player):
			if u.can_act():
				states.append("可行动")
			elif u.attacks_used > 0:
				states.append("本回合已攻击")
			else:
				states.append("本回合不可行动")
	if states.size() > 0:
		bits.append("（" + "；".join(states) + "）")
	return " ".join(bits)


## 战斗日志尾部：读 Main 界面的日志控件；BBCode 标记在这里剥掉，给 AI 纯文本
static func _log_tail() -> String:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return ""
	var root := (loop as SceneTree).root
	var main := root.get_node_or_null("Main")
	if main == null:
		return ""
	var label := main.get_node_or_null("Root/LogPanel/LogMargin/LogVBox/LogLabel")
	if label == null or not (label is RichTextLabel):
		return ""
	var full := _strip_bbcode((label as RichTextLabel).text)
	if full.strip_edges().is_empty():
		return ""
	var lines := full.split("\n")
	var start := maxi(0, lines.size() - LOG_TAIL)
	var tail := PackedStringArray()
	for i in range(start, lines.size()):
		var s: String = lines[i].strip_edges()
		if not s.is_empty():
			tail.append(s)
	return "\n".join(tail)


## 粗剥 BBCode：去掉 [x] / [/x]（含参数），保留文本；日志里只有颜色 / 粗体这类简单标记
static func _strip_bbcode(text: String) -> String:
	var out := ""
	var depth := 0
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]
		if ch == "[":
			depth += 1
			i += 1
			continue
		if ch == "]":
			depth = maxi(0, depth - 1)
			i += 1
			continue
		if depth == 0:
			out += ch
		i += 1
	return out


# ------------------------------ 关键字匹配辅助 ------------------------------

static func _has_keyword_named(c: CardData, name: String) -> bool:
	for k in c.keywords:
		if str(MechanicsScript.display_name(k)) == name or str(k) == name:
			return true
		if CardDataScript.keyword_key(k).to_lower() == name.to_lower():
			return true
	return false


## 「随从 / 法术 / 护符 / 城邦」或 "0".."3" → 枚举值；认不出来返回 -1（= 不过滤）
static func _type_value(text: String) -> int:
	var t := text.strip_edges()
	if t.is_empty():
		return -1
	if t.is_valid_int():
		var v := int(t)
		if v >= 0 and v <= 3:
			return v
		return -1
	match t:
		"随从", "minion", "minions":
			return CardDataScript.CardType.MINION
		"法术", "spell", "spells":
			return CardDataScript.CardType.SPELL
		"护符", "amulet", "permanent":
			return CardDataScript.CardType.AMULET
		"城邦", "city":
			return CardDataScript.CardType.CITY
	return -1
