extends SceneTree
## 融合 / 词条大类 / 法术瞬念召唤 测试。
##
## 覆盖：
##   * CardData.fusion 数据往返与卡面文本；
##   * 融合材料筛选（兵种 / 种类 / 费用）、前置条件（墓地 / 离场数）；
##   * 融合结算：材料进墓地 → 「融合时」词条 → 手牌效果 → 永久获得效果 → 化身；
##   * 词条大类：入场 / 谢幕 / 瞬念召唤 / 被召唤 / 融合 / 离场 / 在；
##     法术只允许「瞬念召唤 / 被召唤」；
##   * 法术瞬念召唤：牌库/墓地 → 进入手牌 或 直接发动；法术伤害算能力伤害；
##   * 管理员面板的融合编辑 / 自检 / 融合选择窗。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/fusion_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _admin = null
var _fail_lines: Array[String] = []
var _created: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null or root.get_node_or_null("AdminAuth") == null:
			_check(false, "CardDB / GameManager / AdminAuth 自动加载")
			_finish()
			return true
		var panel_script = load("res://scripts/AdminPanel.gd")
		_admin = panel_script.new() if panel_script != null else null
		_check(_admin != null, "管理员面板可实例化（编译通过）")
		if _admin == null:
			_finish()
			return true
		root.add_child(_admin)
		_phase = 1
		return false
	if _phase == 1 and _frames >= 4:
		_phase = 2
		_run()
		_finish()
		return false
	return _frames > 900


func _run() -> void:
	_seed()
	_test_data()
	_test_fusion_engine()
	_test_require()
	_test_transform()
	_test_categories()
	_test_spell_invoke()
	_test_admin()
	_test_dialog()
	_cleanup()


# ------------------------------ 造卡 ------------------------------

func _seed() -> void:
	# 上次跑测试中途退出时可能留下 fu_*：先清掉，避免重名被自动改名
	for c in _db.cards.duplicate():
		if str(c.id).begins_with("fu_"):
			_db.remove_card(c.id)
	var target := CardData.from_dict({
		"id": "fu_form", "card_name": "测试·融合形态", "cost": 5,
		"card_type": CardData.CardType.MINION, "attack": 5, "health": 5,
	})
	_check(_db.add_card(target), "化身目标卡进入卡表")
	_created.append("fu_form")


func _card(id: String, name_: String, cost_: int = 1, troop: String = "") -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": cost_,
		"card_type": CardData.CardType.MINION, "attack": 1, "health": 2,
		"troop_id": troop,
	})
	return c


func _fusion_card(id: String, name_: String, fusion: Dictionary) -> CardData:
	var c := _card(id, name_)
	c.fusion = CardData._read_fusion(fusion)
	c.triggers = [{"on": CardTriggers.EV_FUSION,
		"effects": [{"id": "armor", "value": 1, "target": -1}]}]
	return c


# ------------------------------ 数据 ------------------------------

func _test_data() -> void:
	var c := _fusion_card("fu_data", "测试·融合数据", {
		"enabled": true, "count": 1,
		"filter": {"troop": "soldier", "type": -1, "cost_min": 1, "cost_max": 4},
		"require": {"metric": "grave_count", "op": ">=", "value": 2},
		"effects": [{"id": "draw", "value": 1}],
		"gain": [{"id": "armor", "value": 2}],
	})
	_check(c.has_fusion(), "融合数据被识别")
	_check(c.fusion_count() == 1, "融合材料数往返（%d）" % c.fusion_count())
	_check(str(c.fusion_filter().get("troop", "")) == "soldier", "材料兵种往返")
	_check(c.fusion_require().get("metric", "") == "grave_count", "融合前置条件往返")
	_check(c.fusion_effects().size() == 1, "融合时效果往返")
	_check(c.fusion_gain().size() == 1, "融合获得效果往返")
	var text := c.fusion_text()
	_check(text.contains("融合") and text.contains("条件"), "融合卡面文本（%s）" % text)
	var back := CardData.from_dict(c.to_dict())
	_check(back.has_fusion() and back.fusion_gain().size() == 1, "to_dict / from_dict 保留融合")
	_check(not CardData.from_dict({"id": "x"}).has_fusion(), "老卡表没有融合 → 空")


# ------------------------------ 融合结算 ------------------------------

func _test_fusion_engine() -> void:
	var me := _prepare()
	var fusion := _fusion_card("fu_engine", "测试·融合卡", {
		"enabled": true, "count": 1,
		"filter": {"troop": "soldier", "type": -1, "cost_min": 0, "cost_max": 9},
		"effects": [{"id": "armor", "value": 2, "target": -1}],
		"gain": [{"id": "armor", "value": 3, "target": -1}],
	})
	var mat := _card("fu_mat_a", "测试·士兵", 2, "soldier")
	var other := _card("fu_mat_b", "测试·平民", 2, "")
	me.hand.clear()
	me.hand.append(fusion)
	me.hand.append(mat)
	me.hand.append(other)
	me.armor = 0
	var mats: Array = _gm.fusion_materials(ME, 0)
	_check(mats == [1], "材料筛选只收符合兵种的那张（%s）" % str(mats))
	_check(_gm.can_fuse(ME, 0), "材料够 → 可以融合")
	_check(not _gm.fuse(ME, 0, [2]), "不符合兵种的材料被拒绝")
	_check(me.hand.size() == 3, "失败时手牌不变（%d）" % me.hand.size())
	_check(_gm.fuse(ME, 0, [1]), "融合执行成功")
	_check(me.hand.size() == 2 and me.hand.has(other), "材料离开手牌、融合卡留下（%d）" % me.hand.size())
	_check(me.grave_count("fu_mat_a") == 1, "材料进入墓地并计数（%d）" % me.grave_count("fu_mat_a"))
	_check(me.armor == 3, "融合时词条 1 + 手牌效果 2 = 3（%d）" % me.armor)
	_check(fusion.effects.size() == 1, "融合后永久获得 1 条效果（%d）" % fusion.effects.size())
	_check(str(fusion.effects[0].get("id", "")) == "armor", "获得的效果内容正确")

	# 数量不对（材料 1 张但要求 1 张 → 传 0 张）
	_check(not _gm.fuse(ME, 0, []), "材料数量不对被拒绝")


func _test_require() -> void:
	var me := _prepare()
	var fusion := _fusion_card("fu_req", "测试·条件融合", {
		"enabled": true, "count": 1,
		"filter": {"troop": "", "type": -1, "cost_min": 0, "cost_max": 9},
		"require": {"metric": "grave_count", "op": ">=", "value": 2},
	})
	var mat := _card("fu_req_mat", "测试·材料")
	me.hand.clear()
	me.hand.append(fusion)
	me.hand.append(mat)
	me.graveyard.clear()
	_check(not _gm.can_fuse(ME, 0), "墓地不够 → 不能融合")
	me.note_grave_entered(_card("fu_g1", "墓1"))
	me.note_grave_entered(_card("fu_g2", "墓2"))
	_check(_gm.can_fuse(ME, 0), "墓地够了 → 可以融合")


func _test_transform() -> void:
	var me := _prepare()
	var fusion := _fusion_card("fu_tr", "测试·化身融合", {
		"enabled": true, "count": 1,
		"filter": {"troop": "", "type": -1, "cost_min": 0, "cost_max": 9},
		"transform": "fu_form",
	})
	var mat := _card("fu_tr_mat", "测试·材料")
	me.hand.clear()
	me.hand.append(fusion)
	me.hand.append(mat)
	_check(_gm.fuse(ME, 0, [1]), "带化身的融合执行成功")
	_check(me.hand.size() == 1 and me.hand[0].id == "fu_form", "融合后手牌变成目标卡（%s）" % me.hand[0].id)
	_check(me.armor == 1, "融合时词条先结算（%d）" % me.armor)


# ------------------------------ 词条大类 ------------------------------

func _test_categories() -> void:
	_check(CardTriggers.category_of(CardTriggers.EV_PLAY) == CardTriggers.CAT_ENTRY, "入场大类")
	_check(CardTriggers.category_of(CardTriggers.EV_INVOKE) == CardTriggers.CAT_INVOKE, "瞬念召唤大类")
	_check(CardTriggers.category_of(CardTriggers.EV_SUMMON) == CardTriggers.CAT_SUMMONED, "被召唤大类")
	_check(CardTriggers.category_of(CardTriggers.EV_FUSION) == CardTriggers.CAT_FUSION, "融合大类")
	_check(CardTriggers.category_of(CardTriggers.EV_LEAVE) == CardTriggers.CAT_LEAVE, "离场大类")
	_check(CardTriggers.category_of(CardTriggers.EV_VANISH) == CardTriggers.CAT_LEAVE, "消失归入离场大类")
	_check(CardTriggers.category_of(CardTriggers.EV_TURN_START) == CardTriggers.CAT_ON_FIELD, "在（回合开始）大类")
	_check(CardTriggers.category_label(CardTriggers.CAT_CURTAIN) == "谢幕", "谢幕大类名称")
	_check(CardTriggers.dropdown_label(CardTriggers.EV_PLAY).begins_with("[入场]"),
		"下拉文本带大类（%s）" % CardTriggers.dropdown_label(CardTriggers.EV_PLAY))
	_check(CardTriggers.event_allowed_for_type(CardData.CardType.SPELL, CardTriggers.EV_INVOKE),
		"法术允许瞬念召唤")
	_check(CardTriggers.event_allowed_for_type(CardData.CardType.SPELL, CardTriggers.EV_SUMMON),
		"法术允许被召唤（进入手牌）")
	_check(not CardTriggers.event_allowed_for_type(CardData.CardType.SPELL, CardTriggers.EV_PLAY),
		"法术不允许入场大类")
	_check(CardTriggers.event_allowed_for_type(CardData.CardType.MINION, CardTriggers.EV_LEAVE),
		"非法术卡允许离场大类")


# ------------------------------ 法术瞬念召唤 ------------------------------

func _test_spell_invoke() -> void:
	# ① 牌库法术 → 进入手牌
	var me := _prepare()
	var to_hand := _spell("fu_sp_hand", "测试·检索法术", CardData.InvokeDest.HAND)
	me.deck.clear()
	me.deck.append(to_hand)
	_gm._try_invoke(ME, [InvokeConditions.TIME_ANY])
	_check(not me.deck.has(to_hand), "法术从牌库离开")
	_check(_hand_has(me, "fu_sp_hand"), "法术进入手牌（不会上场）")
	_check(me.graveyard.is_empty(), "进入手牌的法术不进墓地")

	# ② 牌库法术 → 直接发动 → 进墓地
	var me2 := _prepare()
	var cast := _spell("fu_sp_cast", "测试·发动法术", CardData.InvokeDest.KEEP)
	me2.deck.clear()
	me2.deck.append(cast)
	me2.armor = 0
	_gm._try_invoke(ME, [InvokeConditions.TIME_ANY])
	_check(me2.armor == 5, "法术从牌库直接发动（护甲 %d）" % me2.armor)
	_check(me2.graveyard.size() == 1 and me2.grave_count("fu_sp_cast") == 1,
		"发动后进入墓地并计数（%d）" % me2.grave_count("fu_sp_cast"))

	# ③ 墓地法术 → 满足条件时直接发动
	var me3 := _prepare()
	var grave_spell := _spell("fu_sp_grave", "测试·墓地法术", CardData.InvokeDest.KEEP)
	me3.graveyard.clear()
	me3.grave_entered.clear()
	me3.grave_entered_total = 0
	me3.note_grave_entered(grave_spell)
	me3.armor = 0
	_gm._try_invoke(ME, [InvokeConditions.TIME_ANY])
	_check(me3.armor == 5, "墓地法术直接发动（护甲 %d）" % me3.armor)
	_check(me3.graveyard.size() == 1, "发动后回到墓地（%d）" % me3.graveyard.size())

	# ④ 法术伤害算能力伤害：术法免疫的随从不受法术伤害
	var me4 := _prepare()
	var foe = _gm.get_player(FOE)
	var u: BoardUnit = _gm.summon_unit(FOE, _card("fu_immune", "测试·术免靶子"))
	u.add_keyword(CardData.Keyword.ABILITY_DAMAGE_IMMUNE)
	var spell := _card("fu_sp_dmg", "测试·法术伤害")
	spell.card_type = CardData.CardType.SPELL
	spell.effects = [{"id": "damage", "value": 4, "target": 2}]
	spell.sync_legacy_from_chains()
	me4.hand.clear()
	me4.hand.append(spell)
	me4.mana = 10
	_gm.play_card(ME, 0, u.unit_id, FOE)
	_check(u.health == 2, "法术伤害被术法免疫挡下（%d）" % u.health)


func _spell(id: String, name_: String, dest: int) -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": 1,
		"card_type": CardData.CardType.SPELL,
		"effects": [{"id": "armor", "value": 5, "target": -1}],
		"invocation": {"enabled": true, "timing": InvokeConditions.TIME_ANY,
			"metric": "hand", "op": ">=", "value": 0, "destination": dest},
	})
	return c


func _hand_has(p: PlayerState, card_id: String) -> bool:
	for c in p.hand:
		if c != null and c.id == card_id:
			return true
	return false


# ------------------------------ 管理员 ------------------------------

func _test_admin() -> void:
	var c := _fusion_card("fu_admin", "测试·面板融合", {
		"enabled": true, "count": 2,
		"filter": {"troop": "soldier", "type": 0, "cost_min": 1, "cost_max": 3},
		"require": {"metric": "units_left", "op": ">=", "value": 2, "troop": CardData.NEUTRAL_TROOP},
		"effects": [{"id": "armor", "value": 1}],
		"gain": [{"id": "draw", "value": 1}],
		"transform": "fu_form",
	})
	_admin._load_card(c)
	_check(_admin._fusion_check.button_pressed, "面板回填：融合已启用")
	_check(int(_admin._fusion_count_spin.value) == 2, "面板回填：材料数")
	_check(_admin._fusion_editor.row_count() == 1, "面板回填：融合时效果")
	_check(_admin._fusion_gain_editor.row_count() == 1, "面板回填：融合获得")
	var form: CardData = _admin._form_to_data()
	_check(form.has_fusion(), "面板保存后仍是融合卡")
	_check(form.fusion_count() == 2, "面板保存：材料数")
	_check(form.fusion_transform() == "fu_form", "面板保存：化身目标")
	_check(_admin._validate_fusion(form) == "", "合法融合配置通过自检")

	var spell := _card("fu_bad_spell", "测试·法术融合")
	spell.card_type = CardData.CardType.SPELL
	spell.fusion = c.fusion
	_check(_admin._validate_fusion(spell).contains("法术"), "法术配融合被自检拦下")

	# 法术的触发时机下拉只剩「瞬念召唤 / 被召唤」（先新建一张空卡，别把融合卡的触发带过来）
	_admin._on_new_pressed()
	_admin._type_option.selected = CardData.CardType.SPELL
	_admin._refresh_trigger_event_options()
	var labels: Array[String] = []
	for i in _admin._trigger_event_option.item_count:
		labels.append(_admin._trigger_event_option.get_item_text(i))
	_check(labels.size() == 2, "法术的时机下拉只有 2 项（%s）" % str(labels))
	_check(_contains(labels, "瞬念召唤") and _contains(labels, "被召唤"),
		"下拉里是瞬念召唤 / 被召唤")

	# 时机逻辑问题标红（只提示，不自动删除）
	_check(not CardEffects.context_warning("copy_self", "leave").is_empty(),
		"离场时机配「复制本随从」会提示逻辑问题")
	_check(CardEffects.context_warning("armor", "leave") == "", "正常效果不会被误标")
	_check(not CardEffects.context_warning("random_pool", "leave", "ghost").is_empty(),
		"随机能力池不存在会提示")
	var warn_card := _card("fu_warn", "测试·时机警告")
	warn_card.triggers = [{"on": CardTriggers.EV_LEAVE,
		"effects": [{"id": "copy_self", "value": 1, "target": -1}]}]
	_admin._load_card(warn_card)
	_admin._trigger_list.select(0)
	_admin._on_trigger_selected(0)
	var st: Dictionary = _admin._trigger_editor.row_state(0)
	var lbl: Label = st["warn_label"]
	_check(lbl.visible and lbl.text.contains("不会生效"), "离场链里的「复制本随从」被标红（%s）" % lbl.text)
	_check(_admin._trigger_editor.row_count() == 1, "只标红，不自动删除这一条")
	# 换成「被召唤」→ 来源还在场上，提示消失
	_admin._select_option_meta(_admin._trigger_event_option, CardTriggers.EV_SUMMON)
	_admin._on_trigger_edited()
	var st2: Dictionary = _admin._trigger_editor.row_state(0)
	_check(not (st2["warn_label"] as Label).visible, "换到「被召唤」后红色提示消失")


func _test_dialog() -> void:
	var me := _prepare()
	var fusion := _fusion_card("fu_dlg", "测试·窗融合", {
		"enabled": true, "count": 1,
		"filter": {"troop": "", "type": -1, "cost_min": 0, "cost_max": 9},
	})
	var mat := _card("fu_dlg_mat", "测试·窗材料")
	me.hand.clear()
	me.hand.append(fusion)
	me.hand.append(mat)
	# 动态加载：`--script` 模式下静态引用带自动加载依赖的脚本会编译失败
	var dlg_script = load("res://scripts/FusionDialog.gd")
	_check(dlg_script != null, "融合窗口脚本可加载")
	var dlg = dlg_script.new()
	root.add_child(dlg)
	dlg.open_for(_gm, ME, 0)
	_check(dlg._list.item_count == 1, "融合窗列出 1 张材料（%d）" % dlg._list.item_count)
	dlg._list.select(0)
	dlg._on_confirm()
	_check(me.hand.size() == 1 and me.hand[0].id == "fu_dlg", "融合窗确认后材料被吃掉")
	dlg.queue_free()


# ------------------------------ 测试辅助 ------------------------------

func _prepare() -> PlayerState:
	_gm.new_game()
	_gm.current_player = ME
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.reset_slots()
	me.graveyard.clear()
	me.grave_entered.clear()
	me.grave_entered_total = 0
	me.units_left_total = 0
	me.units_died_total = 0
	me.deck.clear()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hand.clear()
	foe.board.clear()
	foe.reset_slots()
	foe.graveyard.clear()
	foe.grave_entered.clear()
	foe.grave_entered_total = 0
	return me


func _cleanup() -> void:
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		if p == null:
			continue
		p.board.clear()
		p.reset_slots()
		p.hand.clear()
		p.graveyard.clear()
		p.deck.clear()


func _contains(lines: Array[String], part: String) -> bool:
	for t in lines:
		if t.contains(part):
			return true
	return false


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	for id in _created:
		_db.remove_card(id)
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 融合 / 词条大类测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
