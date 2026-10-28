extends SceneTree
## 兵种系统测试（影之诗的「士兵 / 指挥官」那类单位分类）。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/troop_type_test.gd
##
## 覆盖内容：
##   ① 兵种表：**管理员先建后用**（增 / 改 / 删 + 落盘 user://troops.json + id 校验 + 删兵种清掉卡上的 id）；
##      内置「中立」不可删除：**没选兵种 / 兵种被删掉的卡一律算中立**（不存在「无兵种」）；
##   ② 卡牌字段：troop_id 的序列化 / clone / 老卡表兼容 / 未登记兵种归一；
##   ③ 检索：兵种名能被搜到（组卡界面与管理员列表共用 CardDB.card_matches 一套口径）+ 兵种筛选；
##   ④ 进场计数：某兵种「进入战场」的张数（本局 / 本回合，回合与局长清零）；
##   ⑤ 效果链条件：选兵种当判据（不满足跳过这一条、满足结算、坏条件不放行）；
##   ⑥ 面板：兵种管理页 + 卡牌表单兵种下拉 + 链编辑器条件行 + 保存前校验；
##   ⑦ 词条拓展性：Mechanics.audit 能抓到「枚举里加了、名称表没登记」的漏登记。
##
## 注意：AdminPanel / DeckBuilderDialog 依赖 autoload（CardDB），必须在运行时 load()。

const ME := 0

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _admin = null
var _fail_lines: Array[String] = []
var _created: Array[String] = []
var _troops_backup: Array = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		var auth = root.get_node_or_null("AdminAuth")
		if _db == null or _gm == null or auth == null:
			_check(false, "CardDB / GameManager / AdminAuth 自动加载")
			_finish()
			return true
		_troops_backup = _db.troops.duplicate(true)
		var panel_script = load("res://scripts/AdminPanel.gd")
		_admin = panel_script.new() if panel_script != null else null
		_check(_admin != null, "卡牌管理面板可实例化（编译通过）")
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
	return _frames > 600


func _run() -> void:
	_test_troop_registry()
	_test_card_field()
	_test_search()
	_test_entered_counter()
	_test_chain_condition()
	_test_admin_ui()
	_test_invoke_with_troop()
	_test_card_detail_shows_troop()
	_test_keyword_audit()
	_cleanup()


# ------------------------------ ① 兵种表（先建后用） ------------------------------

func _test_troop_registry() -> void:
	_check(_db.troops.size() >= 5, "内置兵种表可用（%d 个兵种）" % _db.troops.size())
	_check(_db.has_troop("soldier") and _db.troop_name("soldier") == "士兵",
		"内置兵种「士兵」= soldier（%s）" % _db.troop_name("soldier"))
	# 内置「中立」：没选兵种的卡默认归它，所以不存在「无兵种」
	_check(_db.has_troop(CardData.NEUTRAL_TROOP), "内置「中立」兵种存在（%s）" % CardData.NEUTRAL_TROOP)
	_check(_db.troops[0].get("id", "") == CardData.NEUTRAL_TROOP, "「中立」排在兵种表第一位")
	_check(_db.troop_name("") == CardData.NEUTRAL_TROOP_NAME,
		"空 id 显示成「中立」（%s）" % _db.troop_name(""))
	var blank := _card("tt_blank", "测试·没选兵种", int(CardData.CardType.MINION))
	_check(_db.troop_of(blank) == CardData.NEUTRAL_TROOP,
		"没选兵种的卡 = 中立兵种（%s）" % _db.troop_of(blank))
	_check(_db.remove_troop(CardData.NEUTRAL_TROOP) == -2 and _db.has_troop(CardData.NEUTRAL_TROOP),
		"「中立」是内置兵种，不能删除")
	_check(not _db.troop_id_valid("") and not _db.troop_id_valid("1bad") and not _db.troop_id_valid("a-b"),
		"兵种 id 必须是合法标识符（空 / 数字开头 / 带横线都不行）")
	_check(_db.troop_id_valid("guard_captain"), "合法 id 通过校验")

	_check(not _db.add_troop("soldier", "重复兵种", "#ffffff"), "重名兵种不能新增")
	_check(_db.add_troop("tt_troop", "测试兵种", "#123456", "测试用"),
		"新增兵种成功（含配色 / 简介）")
	var raw := FileAccess.get_file_as_string("user://troops.json")
	_check(raw.contains("tt_troop"), "兵种表落盘到 user://troops.json")
	_check(_db.update_troop("tt_troop", "改名兵种", "#654321", "改过"),
		"改名保存成功")
	_check(_db.troop_name("tt_troop") == "改名兵种", "改名生效（%s）" % _db.troop_name("tt_troop"))
	_check(_db.troop_by_id("tt_troop").get("desc", "") == "改过", "简介也一起改了")

	# 删除兵种：原本挂着它的卡立刻变「中立」
	var c := _track(_card("tt_troop_card", "测试·挂兵种", int(CardData.CardType.MINION), [], "tt_troop"))
	_db.cards.append(c)
	_db.rebuild_index()
	var cleared: int = _db.remove_troop("tt_troop")
	_check(cleared == 1, "删兵种时统计到 1 张卡受影响（%d）" % cleared)
	_check(c.troop_id == "", "卡上的 troop_id 被清空（%s）" % c.troop_id)
	_check(_db.troop_of(c) == CardData.NEUTRAL_TROOP, "原兵种被删后归「中立」（%s）" % _db.troop_of(c))
	_check(not _db.has_troop("tt_troop"), "兵种已从表里删除")
	_check(FileAccess.get_file_as_string("user://troops.json").contains("tt_troop") == false,
		"删除也落盘了")


# ------------------------------ ② 卡牌字段 ------------------------------

func _test_card_field() -> void:
	var c := _card("tt_field", "测试·兵种序列化", int(CardData.CardType.MINION), [], "soldier")
	var d: Dictionary = c.to_dict()
	_check(str(d.get("troop_id", "")) == "soldier", "to_dict 带出 troop_id")
	var back := CardData.from_dict(d)
	_check(back.troop_id == "soldier", "from_dict 读回 troop_id")
	_check(back.clone().troop_id == "soldier", "clone 保留兵种")
	_check(CardData.from_dict({"id": "tt_old", "card_name": "老卡"}).troop_id == "",
		"老卡表（没有 troop_id 键）读成空 = 中立")
	_check(_db.troop_of(CardData.from_dict({"id": "tt_old2", "card_name": "老卡2"})) == CardData.NEUTRAL_TROOP,
		"老卡按「中立」参与检索 / 条件 / 计数")

	var ghost := CardData.from_dict({"id": "tt_ghost", "card_name": "坏兵种", "troop_id": "ghost"})
	_check(_db.troop_of(ghost) == CardData.NEUTRAL_TROOP,
		"未登记的兵种 id 归一成「中立」（%s）" % _db.troop_of(ghost))
	_db.cards.append(ghost)
	_db.rebuild_index()
	var hit := false
	for e in _db.config_errors():
		if str(e).contains("兵种 ghost 未登记"):
			hit = true
	_check(hit, "配置自检报出「兵种未登记」")
	_db.cards.erase(ghost)
	_db.rebuild_index()


# ------------------------------ ③ 检索（兵种词条可被搜到） ------------------------------

func _test_search() -> void:
	var soldier := _track(_card("tt_s1", "测试·持盾兵", int(CardData.CardType.MINION), [], "soldier"))
	var wolf := _track(_card("tt_n1", "测试·幼狼", int(CardData.CardType.MINION), [], "nature"))
	_db.cards.append(soldier)
	_db.cards.append(wolf)
	_db.rebuild_index()

	_check(_db.card_matches(soldier, "士兵"), "搜「士兵」能命中挂着士兵的卡（兵种名可被检索）")
	_check(not _db.card_matches(wolf, "士兵"), "别的兵种不会被搜出来")
	_check(_db.card_matches(wolf, "自然"), "搜「自然」命中自然兵种卡")
	_check(_db.card_matches(soldier, "", -1, "soldier") and not _db.card_matches(wolf, "", -1, "soldier"),
		"按兵种筛：只要士兵")
	_check(_db.card_matches(soldier, "持盾", -1, "soldier"), "关键字 + 兵种可以叠加")
	_check(not _db.card_matches(soldier, "持盾", int(CardData.CardType.SPELL), ""), "种类筛选照旧生效")

	var hits: Array = _db.search_cards("", -1, "soldier")
	_check(hits.has(soldier) and not hits.has(wolf), "search_cards 按兵种筛出对应卡（%d 张）" % hits.size())

	# 没选兵种的卡 = 中立：既搜得到，也能被「中立」筛出来
	var blank := _track(_card("tt_blank_s", "测试·没兵种可搜", int(CardData.CardType.MINION)))
	_db.cards.append(blank)
	_db.rebuild_index()
	_check(_db.card_matches(blank, "中立"), "没选兵种的卡能被「中立」搜到")
	_check(_db.card_matches(blank, "", -1, CardData.NEUTRAL_TROOP) and not _db.card_matches(soldier, "", -1, CardData.NEUTRAL_TROOP),
		"按「中立」筛只出没选兵种的卡")

	# 管理员卡表检索框：输入兵种名能搜到
	_admin._list_search.text = "持盾兵"
	_admin._refresh_list()
	_check(_admin._list.get_item_count() >= 1, "管理员卡表检索框：搜卡名有结果（%d 条）" % _admin._list.get_item_count())
	_admin._list_search.text = "士兵"
	_admin._refresh_list()
	var found := false
	for i in _admin._list.get_item_count():
		if str(_admin._list.get_item_metadata(i)) == "tt_s1":
			found = true
	_check(found, "管理员卡表检索框：搜兵种名也能搜到（%d 条）" % _admin._list.get_item_count())

	# 管理员兵种筛选
	_admin._list_search.text = ""
	_admin._refresh_troop_filter_options()
	_select_metadata(_admin._list_troop_filter, "soldier")
	_admin._refresh_list()
	var only_soldier := true
	for i in _admin._list.get_item_count():
		var cid := str(_admin._list.get_item_metadata(i))
		var card: CardData = _db.get_card(cid)
		if card != null and _db.troop_of(card) != "soldier":
			only_soldier = false
	_check(only_soldier, "管理员列表按兵种筛选后只剩该兵种（%d 条）" % _admin._list.get_item_count())
	_admin._list_troop_filter.select(0)
	_admin._refresh_list()
	_check(_admin._list.get_item_count() == _db.cards.size(),
		"清空检索后列表恢复全量（%d / %d）" % [_admin._list.get_item_count(), _db.cards.size()])

	# 组卡界面的兵种筛选下拉
	var dlg_script = load("res://scripts/DeckBuilderDialog.gd")
	_check(dlg_script != null, "组卡界面脚本可加载")
	if dlg_script != null:
		var dlg = dlg_script.new()
		root.add_child(dlg)
		dlg.popup_centered()
		_check(dlg._troop_option != null and dlg._troop_option.item_count == _db.troops.size() + 1,
			"组卡界面有兵种筛选（全部 + %d 个兵种）" % _db.troops.size())
		_check(str(dlg._troop_option.get_item_metadata(0)) == "", "第一项是「全部兵种」")
		dlg.queue_free()


# ------------------------------ ④ 进场计数 ------------------------------

func _test_entered_counter() -> void:
	var me := _prepare_game()
	var soldier := _card("tt_counter", "测试·计数兵", int(CardData.CardType.MINION), [], "soldier")
	var u: BoardUnit = _gm.summon_unit(ME, soldier)
	_check(u != null, "召唤一个士兵上场")
	_check(int(me.troop_entered_total.get("soldier", 0)) == 1,
		"进入战场 → 本局计数 +1（%d）" % int(me.troop_entered_total.get("soldier", 0)))
	_check(int(me.troop_entered_turn.get("soldier", 0)) == 1, "本回合计数 +1")

	var plain := _card("tt_counter_plain", "测试·没选兵种", int(CardData.CardType.MINION))
	_gm.summon_unit(ME, plain)
	_check(int(me.troop_entered_total.get(CardData.NEUTRAL_TROOP, 0)) == 1,
		"没选兵种的卡记在「中立」名下（%s）" % str(me.troop_entered_total))
	_check(int(me.troop_entered_total.get("soldier", 0)) == 1, "不会混进别的兵种")

	_gm._start_turn(ME)
	_check(int(me.troop_entered_turn.get("soldier", 0)) == 0, "回合开始清空「本回合」那份")
	_check(int(me.troop_entered_total.get("soldier", 0)) == 1, "「本局」那份保留")

	_gm.new_game()
	var fresh: PlayerState = _gm.get_player(ME)
	_check(fresh.troop_entered_total.is_empty() and fresh.troop_entered_turn.is_empty(),
		"新局清空兵种计数")


# ------------------------------ ⑤ 效果链条件 ------------------------------

func _test_chain_condition() -> void:
	_check(EffectConditions.metrics().size() >= 4,
		"条件量注册表有 %d 个量（%s）" % [EffectConditions.metrics().size(), "、".join(EffectConditions.metrics())])
	for m in EffectConditions.metrics():
		_check(EffectConditions.has_metric(m) and EffectConditions.metric_label(m) != "",
			"量 %s 有显示名（%s）" % [m, EffectConditions.metric_label(m)])

	var me := _prepare_game()
	me.troop_entered_total["soldier"] = 3
	var cond := {"metric": "troop_entered", "op": ">=", "value": 3, "troop": "soldier"}
	_check(EffectConditions.met(_gm, ME, cond), "本局士兵进场 ≥ 3 → 满足")
	_check(not EffectConditions.met(_gm, ME, {"metric": "troop_entered", "op": ">=", "value": 4, "troop": "soldier"}),
		"阈值 4 → 不满足")
	_check(not EffectConditions.met(_gm, ME, {"metric": "ghost", "op": ">=", "value": 1, "troop": "soldier"}),
		"未登记的量 → 按不满足处理")
	_check(EffectConditions.met(_gm, ME, {}), "空条件 = 永远满足")

	# 条件里没写兵种 = 中立兵种（与「无兵种卡默认中立」同一口径）
	me.troop_entered_total[CardData.NEUTRAL_TROOP] = 1
	_check(EffectConditions.met(_gm, ME, {"metric": "troop_entered", "op": ">=", "value": 1, "troop": ""}),
		"条件没写兵种 → 按「中立」判（满足）")
	_check(not EffectConditions.met(_gm, ME, {"metric": "troop_entered", "op": ">=", "value": 2, "troop": ""}),
		"中立计数不够时不满足")
	_check(str(EffectConditions.normalized({"metric": "troop_board", "value": 1}).get("troop", ""))
		== CardData.NEUTRAL_TROOP, "条件归一：没写兵种 → 中立")
	_check(EffectConditions.text(cond) == "本局该兵种进场数「士兵」≥ 3",
		"条件文本（%s）" % EffectConditions.text(cond))
	_check(EffectConditions.text({"metric": "troop_entered", "op": ">=", "value": 1, "troop": ""})
		== "本局该兵种进场数「中立」≥ 1", "中立的条件文本也对")
	_check(EffectConditions.op_symbol("<=") == "≤" and EffectConditions.op_symbol("!=") == "≠",
		"比较符显示成符号")

	# 场上 / 墓地两个量
	_gm.summon_unit(ME, _card("tt_board1", "测试·场上士兵", int(CardData.CardType.MINION), [], "soldier"))
	_check(EffectConditions.met(_gm, ME, {"metric": "troop_board", "op": ">=", "value": 1, "troop": "soldier"}),
		"场上该兵种数 ≥ 1 → 满足")
	me.graveyard.append(_card("tt_grave1", "测试·墓地士兵", int(CardData.CardType.MINION), [], "soldier"))
	_check(EffectConditions.met(_gm, ME, {"metric": "troop_grave", "op": ">=", "value": 1, "troop": "soldier"}),
		"墓地该兵种数 ≥ 1 → 满足")

	# 真实出牌：条件不满足跳过这一条 / 满足就结算
	var spell := _card("tt_cond_spell", "测试·条件法术", int(CardData.CardType.SPELL),
		[{"id": "armor", "value": 3, "target": -1,
			"cond": {"metric": "troop_entered", "op": ">=", "value": 2, "troop": "soldier"}}])
	me = _prepare_game()
	me.hand.append(spell)
	me.mana = 10
	me.armor = 0
	_check(_gm.play_card(ME, 0), "打出带条件的效果卡（条件未满足）")
	_check(me.armor == 0, "条件不满足 → 这一条被跳过（护甲 %d）" % me.armor)

	me.hand.append(spell.clone())
	me.mana = 10
	me.troop_entered_total["soldier"] = 2
	_check(_gm.play_card(ME, 0), "条件满足后再打一次")
	_check(me.armor == 3, "条件满足 → 正常结算（护甲 %d）" % me.armor)
	_check(spell.effect_text().begins_with("若 "),
		"卡面文本带上条件前缀（%s）" % spell.effect_text())


# ------------------------------ ⑥ 管理员面板 ------------------------------

func _test_admin_ui() -> void:
	_check(_admin._troop_list != null and _admin._troop_list.get_item_count() == _db.troops.size(),
		"左侧有「兵种」清单（%d 项）" % _admin._troop_list.get_item_count())

	# 新建兵种（面板这条路）→ 卡牌表单下拉里立刻能选到
	_admin._on_troop_new()
	_admin._troop_id_edit.text = "tt_ui_troop"
	_admin._troop_name_edit.text = "面板兵种"
	_admin._troop_desc_edit.text = "从面板创建"
	_admin._on_troop_save()
	_check(_db.has_troop("tt_ui_troop"), "面板「保存修改」能新建兵种")
	_check(_db.troop_name("tt_ui_troop") == "面板兵种", "名称写对（%s）" % _db.troop_name("tt_ui_troop"))
	_check(_admin._troop_list.get_item_count() == _db.troops.size(), "兵种清单跟着刷新")

	_check(_admin._card_troop_option.item_count == _db.troops.size(),
		"卡牌表单兵种下拉 = 全部兵种（含中立，共 %d 项）" % _admin._card_troop_option.item_count)
	_check(str(_admin._card_troop_option.get_item_metadata(0)) == CardData.NEUTRAL_TROOP,
		"第一项是「中立」（没有「无兵种」这一项）")
	_check(_has_meta(_admin._invoke_troop_option, "tt_ui_troop"),
		"瞬念召唤的「条件兵种」下拉也跟着兵种表刷新")

	var c := _track(_card("tt_ui_card", "测试·面板兵种卡", int(CardData.CardType.MINION)))
	_admin._load_card(c)
	_check(_admin._selected_card_troop() == "", "新卡默认中立（卡表里存空 = 中立）")
	_check(str(_admin._card_troop_option.get_item_metadata(_admin._card_troop_option.selected))
		== CardData.NEUTRAL_TROOP, "下拉里默认选中的是「中立」")
	_admin._select_card_troop("tt_ui_troop")
	var form: CardData = _admin._form_to_data()
	_check(form.troop_id == "tt_ui_troop", "表单能把兵种写回卡牌（%s）" % form.troop_id)

	# 链编辑器：条件行回填 / 写回
	var ed = _admin._battlecry_editor
	ed.load_chain([{"id": "armor", "value": 2, "target": -1,
		"cond": {"metric": "troop_board", "op": ">=", "value": 2, "troop": "tt_ui_troop"}}])
	var st: Dictionary = ed.row_state(0)
	_check(not st.is_empty() and st.has("cond_metric"), "链编辑器每行都有条件行")
	_check(str(st["cond_metric"].get_item_metadata(st["cond_metric"].selected)) == "troop_board",
		"回填条件量（%s）" % str(st["cond_metric"].get_item_metadata(st["cond_metric"].selected)))
	_check(str(st["cond_troop"].get_item_metadata(st["cond_troop"].selected)) == "tt_ui_troop",
		"回填条件兵种")
	_check(st["cond_op"].selected == EffectConditions.OPS.find(">="), "回填比较符")
	_check(int(st["cond_value"].value) == 2, "回填阈值（%d）" % int(st["cond_value"].value))
	var chain: Array = ed.chain()
	_check(chain.size() == 1 and chain[0].has("cond"), "保存时把条件写进链")
	_check(str(chain[0].get("cond", {}).get("troop", "")) == "tt_ui_troop"
		and int(chain[0].get("cond", {}).get("value", 0)) == 2, "条件内容写对（%s）" % str(chain[0].get("cond")))

	ed.load_chain([{"id": "armor", "value": 2, "target": -1}])
	_check(not ed.chain()[0].has("cond"), "没有条件时不写 cond 键（老卡表的链逐字不变）")

	# 保存前校验：条件用了未登记的兵种 → 拦下
	_check(_admin._validate_chain([{"id": "armor", "value": 2, "target": -1,
		"cond": {"metric": "troop_board", "op": ">=", "value": 1, "troop": "ghost_troop"}}],
		"战吼", true).contains("未登记的兵种"), "保存前校验拦下「条件用了未登记的兵种」")
	_check(_admin._validate_chain([{"id": "armor", "value": 2, "target": -1,
		"cond": {"metric": "troop_board", "op": ">=", "value": 1, "troop": "tt_ui_troop"}}],
		"战吼", true) == "", "合法条件能通过校验")

	# 面板上删「中立」会被拒绝
	_admin._refresh_troop_list()
	for i in _admin._troop_list.get_item_count():
		if str(_admin._troop_list.get_item_metadata(i)) == CardData.NEUTRAL_TROOP:
			_admin._troop_list.select(i)
	_admin._on_troop_delete()
	_check(_db.has_troop(CardData.NEUTRAL_TROOP), "面板上删「中立」被拒绝（兵种还在）")
	_check(_admin._status_label.text.contains("不能删除"),
		"状态栏说清了原因（%s）" % _admin._status_label.text)

	# 删除普通兵种 → 面板清单 / 下拉 / 卡表筛选都跟着变
	var cleared: int = _db.remove_troop("tt_ui_troop")
	_check(cleared >= 0 and not _db.has_troop("tt_ui_troop"), "删除兵种成功")
	_admin._refresh_troop_list()
	_admin._refresh_card_troop_options()
	_admin._refresh_troop_filter_options()
	_check(_admin._card_troop_option.item_count == _db.troops.size(), "删除后卡牌表单下拉也更新了")


# ------------------------------ ⑦ 瞬念召唤：兵种条件（自动触发） ------------------------------

## 「某一兵种的卡牌进入战场到一定数量就触发某张卡的效果」走的是瞬念召唤这条自动触发路径：
## 条件里选兵种类量（troop_entered 等）+ 一个兵种，引擎在检查点替牌库里的卡判定。
func _test_invoke_with_troop() -> void:
	_check(InvokeConditions.metric_wants_troop("troop_entered"), "瞬念召唤的量表里有「本局该兵种进场数」")
	_check(not InvokeConditions.metric_wants_troop("hand"), "普通量不需要兵种")
	_check(InvokeConditions.scope_key("troop_board", "soldier") == "troop_board@soldier",
		"兵种量的快照 key（%s）" % InvokeConditions.scope_key("troop_board", "soldier"))
	_check(InvokeConditions.scope_key("hand", "soldier") == "hand", "普通量的 key 不受兵种影响")
	_check(InvokeConditions.text("troop_entered", ">=", 3, "soldier") == "本局该兵种进场数「士兵」≥ 3",
		"瞬念召唤文本带兵种（%s）" % InvokeConditions.text("troop_entered", ">=", 3, "soldier"))

	var me := _prepare_game()
	var invoker := _card("tt_invoker", "测试·应召士兵", int(CardData.CardType.MINION))
	invoker.invocation = {
		"enabled": true, "metric": "troop_entered", "op": ">=", "value": 2,
		"troop": "soldier", "timing": InvokeConditions.TIME_ANY,
		"effects": [], "destination": CardData.InvokeDest.KEEP,
	}
	_check(invoker.has_invocation(), "带兵种条件的瞬念召唤可以判定")
	_check(invoker.invoke_scoped_metric() == "troop_entered@soldier",
		"判定 key 带兵种（%s）" % invoker.invoke_scoped_metric())
	_check(invoker.invoke_text().contains("士兵"), "瞬念召唤文本写明兵种（%s）" % invoker.invoke_text())

	me.deck.append(invoker)
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "测试·应召士兵") == 0, "士兵还没进场（0）→ 不应召")

	me.troop_entered_total["soldier"] = 2
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me.board, "测试·应召士兵") == 1,
		"本局士兵进场 ≥ 2 → 自动上场（「进场到一定数量触发」走通了）")
	_check(_count_name(me.deck, "测试·应召士兵") == 0, "牌库里那张已经应召走了")

	# 换兵种就互不串：中立计数满足也推不动「士兵 ≥ 1」的那张
	var me2 := _prepare_game()
	var soldier_inv := _card("tt_inv_s", "测试·应召士兵二", int(CardData.CardType.MINION))
	soldier_inv.invocation = {
		"enabled": true, "metric": "troop_entered", "op": ">=", "value": 1,
		"troop": "soldier", "timing": InvokeConditions.TIME_ANY,
		"effects": [], "destination": CardData.InvokeDest.KEEP,
	}
	var neutral_inv := _card("tt_inv_n", "测试·应召中立", int(CardData.CardType.MINION))
	neutral_inv.invocation = {
		"enabled": true, "metric": "troop_entered", "op": ">=", "value": 1,
		"troop": CardData.NEUTRAL_TROOP, "timing": InvokeConditions.TIME_ANY,
		"effects": [], "destination": CardData.InvokeDest.KEEP,
	}
	me2.deck.append(soldier_inv)
	me2.deck.append(neutral_inv)
	me2.troop_entered_total[CardData.NEUTRAL_TROOP] = 1
	_gm._invoke_checkpoint(ME)
	_check(_count_name(me2.board, "测试·应召中立") == 1, "按「中立」计数判定（没选兵种的卡都算中立）")
	_check(_count_name(me2.board, "测试·应召士兵二") == 0, "中立计数不会让士兵条件误判")

	# 面板：兵种下拉只在兵种量时出现，保存时写回 troop
	_admin._load_card(invoker)
	_check(_admin._invoke_check.button_pressed, "面板勾上了瞬念召唤")
	_check(_admin._invoke_troop_option.visible, "选兵种量时「条件兵种」行出现")
	_admin._select_option_meta(_admin._invoke_troop_option, "soldier")
	var saved: Dictionary = _admin._invoke_map()
	_check(str(saved.get("troop", "")) == "soldier", "保存时把兵种写进瞬念召唤（%s）" % str(saved.get("troop")))
	_check(str(saved.get("metric", "")) == "troop_entered", "量照旧写对（%s）" % str(saved.get("metric")))

	_admin._invoke_metric_option.select(_admin._select_invoke_metric("hand"))
	_admin._on_invoke_metric_selected(_admin._invoke_metric_option.selected)
	_check(not _admin._invoke_troop_option.visible, "换成普通量后「条件兵种」行隐藏")
	_check(not _admin._invoke_map().has("troop"), "普通量不写 troop 键（卡表保持干净）")

	# 保存前校验：兵种条件用了未登记的兵种 → 拦下
	var bad := _card("tt_bad_inv", "坏兵种瞬念", int(CardData.CardType.MINION))
	bad.invocation = {
		"enabled": true, "metric": "troop_board", "op": ">=", "value": 1,
		"troop": "ghost_troop", "timing": InvokeConditions.TIME_ANY,
		"effects": [], "destination": CardData.InvokeDest.KEEP,
	}
	_check(_admin._validate_invocation(bad).contains("未登记的兵种"), "保存前校验拦下「未登记的兵种」")
	# 配置自检同样报出来
	_db.cards.append(bad)
	_db.rebuild_index()
	var hit := false
	for e in _db.config_errors():
		if str(e).contains("兵种条件用了未登记的兵种"):
			hit = true
	_check(hit, "配置自检也报「瞬念召唤的兵种未登记」")
	_db.cards.erase(bad)
	_db.rebuild_index()


# ------------------------------ ⑧ 卡牌详情显示兵种 ------------------------------

func _test_card_detail_shows_troop() -> void:
	var script = load("res://scripts/CardDetail.gd")
	_check(script != null, "卡牌详情脚本可加载")
	if script == null:
		return
	var detail = script.new()
	root.add_child(detail)
	detail._fill(_card("tt_det_s", "测试·详情士兵", int(CardData.CardType.MINION), [], "soldier"))
	_check(detail._sub.text.contains("·士兵"), "卡牌详情里显示兵种（%s）" % detail._sub.text)
	detail._fill(_card("tt_det_n", "测试·详情中立", int(CardData.CardType.MINION)))
	_check(not detail._sub.text.contains("中立"), "中立是默认值，不逐张标注（%s）" % detail._sub.text)
	detail.queue_free()


# ------------------------------ ⑨ 词条拓展性（audit） ------------------------------

func _test_keyword_audit() -> void:
	var audit: Dictionary = Mechanics.audit()
	_check(audit.get("ok", false), "机制自检通过（%d 个机制）" % int(audit.get("count", 0)))
	_check(audit.has("missing_meta"), "自检新增「枚举漏登记」一项（%s）" % str(audit.get("missing_meta")))
	_check((audit.get("missing_meta", []) as Array).is_empty(),
		"当前枚举与名称表一一对应（没有静默漏登记）")
	# 每个枚举值都能拿到名字 / 卡表 key / 描述 —— 加新词条时必须同步登记
	for keyword in CardData.Keyword.values():
		if CardData.KEYWORD_NAMES.has(keyword) and Mechanics.has(keyword):
			_check(CardData.KEYWORD_KEYS.has(keyword) and Mechanics.describe(keyword) != "",
				"词条 %s 名字 / key / 描述齐全" % Mechanics.display_name(keyword))


# ------------------------------ 测试辅助 ------------------------------

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
	print("=== 兵种系统测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)


func _prepare_game() -> PlayerState:
	_gm.new_game()
	_gm.log_enabled = true
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.graveyard.clear()
	me.deck.clear()
	me.turns_taken = 1
	me.city_summon_turn = -1
	me.troop_entered_total.clear()
	me.troop_entered_turn.clear()
	return me


## 现造一张卡（只存在于内存，不写任何卡表文件）
func _card(id: String, name_: String, card_type: int, effects: Array = [], troop: String = "") -> CardData:
	var c := CardData.from_dict({
		"id": id,
		"card_name": name_,
		"cost": 1,
		"card_type": card_type,
		"attack": 1,
		"health": 2,
		"keywords": [],
		"effects": effects,
		"deathrattle_effects": [],
		"troop_id": troop,
	})
	c.sync_legacy_from_chains()
	return c


## 记下要清理的临时卡 id（不存在于卡表时 remove_card 会静默跳过）
func _track(c: CardData) -> CardData:
	_created.append(c.id)
	return c


## 数一个列表（战场 BoardUnit / 牌库 CardData）里叫这个名字的张数
func _count_name(list: Array, card_name: String) -> int:
	var n := 0
	for item in list:
		if item is BoardUnit and (item as BoardUnit).data.card_name == card_name:
			n += 1
		elif item is CardData and (item as CardData).card_name == card_name:
			n += 1
	return n


static func _has_meta(option: OptionButton, value: String) -> bool:
	if option == null:
		return false
	for i in option.item_count:
		var meta = option.get_item_metadata(i)
		if meta != null and str(meta) == value:
			return true
	return false


static func _select_metadata(option: OptionButton, value: String) -> void:
	for i in option.item_count:
		var meta = option.get_item_metadata(i)
		if meta != null and str(meta) == value:
			option.select(i)
			return
	option.select(0)


## 清干净：临时卡 + 兵种表恢复原样（兵种会写盘，必须还原，否则影响别的测试）
func _cleanup() -> void:
	for id in _created:
		_db.remove_card(id)
	if not _troops_backup.is_empty():
		_db.troops.assign(_troops_backup)
		_db._ensure_neutral_troop()      # 「中立」永远在（老存档备份里可能没有它）
		_db.save_troops()
