extends SceneTree
## 随机能力（能力池）测试：
##   * AbilityPools 数据层：默认池 / 归一 / 自检 / 增删改；
##   * 三种随机口径：可重复获得（同一能力能中多次）、不可重复获得（最多各一次）、
##     随机次序触发（洗牌后全部 / 取 N 个，强调顺序）；
##   * 随机个数：count_min ~ count_max 之间随机；效果里的 value 可以临时覆盖；
##   * 实际结算：随机破坏对面随从 / 抽牌 / 护甲 / 直伤都能落地，且逐条结算；
##   * 保护：池子不存在、空池、能力里嵌套随机能力都不会崩 / 不会无限递归；
##   * 卡面文本 / 卡表自检 / 管理员面板编辑。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/random_ability_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _admin = null
var _fail_lines: Array[String] = []
var _pool_backup: Array = []
var _created_cards: Array[String] = []


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
	# 只备份「非测试池」：万一上次跑测试中途挂了，也不会把 t_* 当成玩家数据留下来
	_pool_backup = []
	for p in AbilityPools.pools:
		if not str(p.get("id", "")).begins_with("t_"):
			_pool_backup.append((p as Dictionary).duplicate(true))
	_test_defaults()
	_test_normalize()
	_test_errors()
	_test_pick_repeat()
	_test_pick_unique()
	_test_pick_order()
	_test_count_range_and_override()
	_test_text()
	_test_runtime_destroy()
	_test_runtime_order()
	_test_runtime_repeat_and_nested()
	_test_bad_pool()
	_test_card_validation()
	_test_admin()
	_restore()
	_cleanup_cards()


# ------------------------------ 数据层 ------------------------------

func _test_defaults() -> void:
	_check(AbilityPools.all().size() >= 3, "默认随机能力池已载入（%d 个）" % AbilityPools.all().size())
	_check(AbilityPools.has("chaos"), "默认池 chaos 存在")
	_check(AbilityPools.pool_name("chaos") == "混沌召来", "默认池名称正确")
	_check(AbilityPools.ids().has("chaos_order"), "默认池里有「随机次序」示例")
	_check(AbilityPools.mode_ids() == ["repeat", "unique", "order"], "随机口径的顺序固定")
	_check(AbilityPools.mode_label(AbilityPools.MODE_UNIQUE) == "不可重复获得", "口径显示名")
	_check(AbilityPools.id_valid("chaos_1"), "合法池 ID")
	_check(not AbilityPools.id_valid("1chaos"), "数字开头的池 ID 不合法")
	_check(AbilityPools.normalize({"id": "x"}).get("mode", "") == AbilityPools.MODE_REPEAT,
		"省略口径时默认「可重复获得」")


func _test_normalize() -> void:
	var p := AbilityPools.normalize({
		"id": "t_norm", "mode": "ghost", "count_min": 5, "count_max": 2,
		"abilities": [{"id": "armor", "value": 1}, "bad", {"id": ""}],
	})
	_check(p.get("mode", "") == AbilityPools.MODE_REPEAT, "未知口径归一成「可重复获得」")
	_check(int(p.get("count_max", 0)) == 5, "上限小于下限时抬到下限（%d）" % int(p.get("count_max", 0)))
	_check((p.get("abilities", []) as Array).size() == 1, "只保留有效能力条目")
	_check(AbilityPools.normalize("nope").is_empty(), "非字典输入归一成空")


func _test_errors() -> void:
	_check(AbilityPools.errors(AbilityPools.by_id("chaos")).is_empty(),
		"默认池 chaos 没有配置错误")
	_check(AbilityPools.errors({}).size() == 1, "空池报错")
	var bad := AbilityPools.normalize({
		"id": "t_bad", "mode": "unique", "count_min": 1, "count_max": 9,
		"abilities": [{"id": "armor", "value": 1}, {"id": "no_such_effect"}],
	})
	var errs := AbilityPools.errors(bad)
	_check(_has_text(errs, "未知效果"), "未知效果 ID 被自检抓出来")
	_check(_has_text(errs, "池子大小"), "不可重复口径下个数超过池子大小有提示")
	var nested := AbilityPools.normalize({
		"id": "t_nested", "mode": "repeat", "count_min": 1, "count_max": 1,
		"abilities": [{"id": "random_pool", "token": "chaos"}],
	})
	_check(_has_text(AbilityPools.errors(nested), "不支持嵌套"), "嵌套随机能力被自检抓出来")


# ------------------------------ 随机口径 ------------------------------

func _test_pick_repeat() -> void:
	_add_pool("t_repeat", AbilityPools.MODE_REPEAT, 3, 3, [
		{"id": "armor", "value": 1, "target": -1},
		{"id": "draw", "value": 1, "target": -1},
	])
	var picks := AbilityPools.pick("t_repeat")
	_check(picks.size() == 3, "可重复获得：个数 = 3（%d）" % picks.size())
	var ids := {}
	for e in picks:
		ids[str(e.get("id", ""))] = true
	_check(ids.has("armor") or ids.has("draw"), "抽到的是池里的能力")
	# 池子里只有一个能力 → 可重复口径必须能抽到 3 次同一个
	_add_pool("t_one", AbilityPools.MODE_REPEAT, 3, 3, [{"id": "armor", "value": 1, "target": -1}])
	_check(AbilityPools.pick("t_one").size() == 3, "可重复获得：能重复抽同一个能力（3 次）")


func _test_pick_unique() -> void:
	_add_pool("t_unique", AbilityPools.MODE_UNIQUE, 3, 3, [
		{"id": "armor", "value": 1, "target": -1},
		{"id": "draw", "value": 1, "target": -1},
		{"id": "damage_hero", "value": 1, "target": -1},
	])
	for round_i in 5:
		var picks := AbilityPools.pick("t_unique")
		var ids := {}
		var dup := false
		for e in picks:
			var eid := str(e.get("id", ""))
			if ids.has(eid):
				dup = true
			ids[eid] = true
		_check(not dup and ids.size() == 3, "不可重复获得：3 个能力互不相同（第 %d 轮）" % (round_i + 1))
	# 池子大小封顶：3 个能力的池子要 5 个也只能拿到 3 个（自检会提示，但运行时自动夹紧）
	_add_pool("t_unique_big", AbilityPools.MODE_UNIQUE, 5, 5, [
		{"id": "armor", "value": 1, "target": -1},
		{"id": "draw", "value": 1, "target": -1},
	])
	_check(AbilityPools.pick("t_unique_big").size() == 2, "不可重复获得：个数被压到池子大小（2）")


func _test_pick_order() -> void:
	_add_pool("t_order", AbilityPools.MODE_ORDER, 0, 0, [
		{"id": "armor", "value": 1, "target": -1},
		{"id": "draw", "value": 1, "target": -1},
		{"id": "damage_hero", "value": 1, "target": -1},
	])
	var picks := AbilityPools.pick("t_order")
	_check(picks.size() == 3, "随机次序触发：个数 0 = 全部（%d）" % picks.size())
	var ids := {}
	for e in picks:
		ids[str(e.get("id", ""))] = true
	_check(ids.size() == 3, "随机次序触发：每个能力只触发一次")


func _test_count_range_and_override() -> void:
	_add_pool("t_range", AbilityPools.MODE_REPEAT, 1, 3, [
		{"id": "armor", "value": 1, "target": -1},
		{"id": "draw", "value": 1, "target": -1},
	])
	var seen := {}
	for i in 40:
		var n := AbilityPools.pick("t_range").size()
		seen[n] = true
		if n < 1 or n > 3:
			_check(false, "随机个数越界：%d" % n)
			break
	_check(seen.size() >= 2, "随机个数会在 1–3 之间变化（出现过 %s）" % str(seen.keys()))
	_check(AbilityPools.pick("t_unique", 1).size() == 1, "效果里的 value > 0 覆盖随机个数（=1）")


# ------------------------------ 文本 ------------------------------

func _test_text() -> void:
	_add_pool("t_text", AbilityPools.MODE_UNIQUE, 1, 2, [
		{"id": "destroy_random", "value": 1, "target": -1},
		{"id": "armor", "value": 2, "target": -1},
	])
	var text := CardEffects.random_pool_text("t_text", 0)
	_check(text.contains("随机获得"), "池子文本说明是随机获得（%s）" % text)
	_check(text.contains("不可重复"), "池子文本带上随机口径（%s）" % text)
	_check(text.contains("随机消灭") and text.contains("护甲"), "池子文本列出能力清单")
	var entry := {"id": "random_pool", "token": "t_text", "value": 0, "target": -1}
	var chain_text := CardData.new().chain_text([entry])
	_check(chain_text.contains("随机") and chain_text.contains("能力"), "卡面文本走能力池（%s）" % chain_text)
	_check(CardEffects.text("random_pool", 0, 0, 0, "").contains("未选择能力池"),
		"没填池 ID 时文本给出提示")


# ------------------------------ 实际结算 ------------------------------

## 随机能力池：随机破坏对面随从 + 获得护甲（不可重复、固定 2 个 → 两个都会触发）
func _test_runtime_destroy() -> void:
	var me := _prepare_game()
	var foe = _gm.get_player(FOE)
	var units := _db_minions(2)
	_check(units.size() == 2, "卡表里能取到两个随从当靶子")
	_gm.summon_unit(FOE, units[0])
	_gm.summon_unit(FOE, units[1])
	var before: int = foe.board.size()
	_add_pool("t_rt", AbilityPools.MODE_UNIQUE, 2, 2, [
		{"id": "destroy_random", "value": 1, "target": -1},
		{"id": "armor", "value": 2, "target": -1},
	])
	me.armor = 0
	_play_spell("t_ra_spell", "t_rt")
	_check(foe.board.size() == before - 1, "随机破坏对面随从生效（%d → %d）" % [before, foe.board.size()])
	_check(me.armor == 2, "同一个池子里的护甲能力也结算了（%d）" % me.armor)


## 随机次序触发：全部能力都会触发，只是顺序随机
func _test_runtime_order() -> void:
	var me := _prepare_game()
	var foe = _gm.get_player(FOE)
	var deck_before := me.deck.size()
	var foe_hp = foe.hero_hp
	_add_pool("t_rt_order", AbilityPools.MODE_ORDER, 0, 0, [
		{"id": "armor", "value": 1, "target": -1},
		{"id": "draw", "value": 1, "target": -1},
		{"id": "damage_hero", "value": 1, "target": -1},
	])
	me.armor = 0
	_play_spell("t_ra_order_spell", "t_rt_order")
	_check(me.armor == 1, "随机次序：护甲能力触发（%d）" % me.armor)
	_check(me.hand.size() >= 1, "随机次序：抽牌能力触发（手牌 %d）" % me.hand.size())
	_check(foe.hero_hp == foe_hp - 1, "随机次序：直伤能力触发（%d → %d）" % [foe_hp, foe.hero_hp])
	_check(me.deck.size() == deck_before - 1, "随机次序：确实只抽了 1 张")


func _test_runtime_repeat_and_nested() -> void:
	var me := _prepare_game()
	_add_pool("t_rt_repeat", AbilityPools.MODE_REPEAT, 3, 3, [
		{"id": "armor", "value": 1, "target": -1},
	])
	me.armor = 0
	_play_spell("t_ra_repeat_spell", "t_rt_repeat")
	_check(me.armor == 3, "可重复获得：同一个护甲能力触发 3 次（%d）" % me.armor)

	# value 覆盖池子的个数：池子固定 1 个，效果写 2 → 会结算 2 次
	var me2 := _prepare_game()
	_add_pool("t_rt_override", AbilityPools.MODE_REPEAT, 1, 1, [
		{"id": "armor", "value": 1, "target": -1},
	])
	me2.armor = 0
	_play_spell("t_ra_override_spell", "t_rt_override", 2)
	_check(me2.armor == 2, "value 覆盖随机个数后结算 2 次（%d）" % me2.armor)

	# 手改数据把「随机能力」放进池子：跳层，不递归
	var me3 := _prepare_game()
	_add_pool("t_rt_nested", AbilityPools.MODE_REPEAT, 1, 1, [
		{"id": "random_pool", "token": "t_rt_nested"},
	])
	me3.armor = 0
	_play_spell("t_ra_nested_spell", "t_rt_nested")
	_check(me3.armor == 0, "池子里嵌套随机能力被跳过（不会无限递归）")


func _test_bad_pool() -> void:
	var me := _prepare_game()
	me.armor = 0
	_play_spell("t_ra_ghost_spell", "no_such_pool")
	_check(me.armor == 0, "能力池不存在时不会报错 / 不会产生效果")
	_add_pool("t_empty_pool", AbilityPools.MODE_REPEAT, 1, 1, [])
	_play_spell("t_ra_empty_spell", "t_empty_pool")
	_check(me.armor == 0, "空池不结算任何东西")


# ------------------------------ 配置自检 ------------------------------

func _test_card_validation() -> void:
	var c := _card("t_ra_bad_card", "测试·坏池卡", int(CardData.CardType.SPELL), 1)
	c.effects = [{"id": "random_pool", "token": "ghost_pool", "value": 0, "target": -1}]
	var errs: Array[String] = _db._chain_errors(c, c.effects, "战吼 / 法术")
	_check(_has_text(errs, "不存在"), "卡表自检抓出「能力池不存在」")
	var c2 := _card("t_ra_no_card", "测试·空池卡", int(CardData.CardType.SPELL), 1)
	c2.effects = [{"id": "random_pool", "value": 0, "target": -1}]
	_check(_has_text(_db._chain_errors(c2, c2.effects, "战吼 / 法术"), "需要选择随机能力池"),
		"卡表自检抓出「没填能力池」")


# ------------------------------ 管理员面板 ------------------------------

func _test_admin() -> void:
	# 面板的清单是 _ready 时建的；前面的「数据层」测试往 AbilityPools 里加了不少池子，
	# 先刷新一次让清单与数据一致，再比较「保存后多了一项」。
	_admin._refresh_ability_pool_list()
	var before = _admin._ability_pool_list.get_item_count()
	_admin._on_ability_pool_new()
	_admin._ability_id_edit.text = "t_ui_pool"
	_admin._ability_name_edit.text = "测试·界面池"
	_select_meta(_admin._ability_mode_option, AbilityPools.MODE_UNIQUE)
	_admin._ability_min_spin.value = 1
	_admin._ability_max_spin.value = 2
	_admin._ability_editor.add_row("armor", 2, -1)
	_admin._ability_editor.add_row("destroy_random", 1, -1)
	_admin._on_ability_pool_save()
	_check(AbilityPools.has("t_ui_pool"), "面板保存后能力池已登记")
	_check(_admin._ability_pool_list.get_item_count() == before + 1, "池子清单多了一项")
	var saved := AbilityPools.by_id("t_ui_pool")
	_check(str(saved.get("mode", "")) == AbilityPools.MODE_UNIQUE, "保存了随机口径")
	_check((saved.get("abilities", []) as Array).size() == 2, "保存了 2 个能力")
	_check(AbilityPools.errors(saved).is_empty(), "保存后的池子通过自检")

	# 回填：重新载入
	_admin._on_ability_pool_selected(_admin._ability_pool_list.item_count - 1)
	_check(_admin._ability_id_edit.text == "t_ui_pool", "选中后回填池 ID")
	_check(_admin._ability_editor.row_count() == 2, "选中后回填能力清单")
	_check(_admin._ability_hint.text.contains("不可重复"), "提示文本跟着随机口径（%s）" % _admin._ability_hint.text)

	# 效果行的 token 提示：随机能力要提示「能力池 ID」，其他效果提示衍生物
	_admin._battlecry_editor.add_row("random_pool", 0, -1, "")
	_admin._battlecry_editor.set_row_effect(_admin._battlecry_editor.row_count() - 1, "random_pool")
	var st: Dictionary = _admin._battlecry_editor.row_state(_admin._battlecry_editor.row_count() - 1)
	var token_edit: LineEdit = st["token_edit"]
	_check(token_edit.visible, "随机能力的池 ID 输入框可见")
	_check(token_edit.placeholder_text.contains("能力池"), "输入框提示改成「能力池 ID」")
	_check(_admin._validate_chain([{"id": "random_pool", "token": "", "target": -1}], "测试", false)
		.contains("随机能力池"), "面板保存前校验拦下「没填能力池」")

	# 删除
	_admin._ability_pool_list.select(_admin._ability_pool_list.item_count - 1)
	_admin._on_ability_pool_delete()
	_check(not AbilityPools.has("t_ui_pool"), "面板删除后能力池已移除")


# ------------------------------ 测试辅助 ------------------------------

func _add_pool(id: String, mode: String, lo: int, hi: int, abilities: Array) -> void:
	if AbilityPools.has(id):
		AbilityPools.remove_pool(id)
	_check(AbilityPools.add_pool(id, id, "", mode, lo, hi, abilities), "创建测试池 %s" % id)


func _card(id: String, name_: String, card_type: int, cost_: int = 1) -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": cost_, "card_type": card_type,
		"attack": 0, "health": 1, "keywords": [], "effects": [], "deathrattle_effects": [],
	})
	c.sync_legacy_from_chains()
	return c


func _minion(id: String) -> CardData:
	return _card(id, id, int(CardData.CardType.MINION), 1)


func _play_spell(id: String, pool_id: String, value_override: int = 0) -> void:
	var c := _card(id, "测试·随机能力", int(CardData.CardType.SPELL), 0)
	c.effects = [{"id": "random_pool", "token": pool_id, "value": value_override, "target": -1}]
	c.sync_legacy_from_chains()
	_db.add_card(c)
	_created_cards.append(c.id)          # add_card 可能因为重名改 id，清理时按实际 id 删
	var me = _gm.get_player(ME)
	me.hand.clear()
	me.hand.append(c)
	_gm.play_card(ME, 0)


func _prepare_game() -> PlayerState:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.armor = 0
	me.hand.clear()
	me.board.clear()
	me.graveyard.clear()
	me.deck.clear()
	# 牌库用**卡表里真实存在的卡**：新增测试卡会触发 database_changed，
	# 卡表里没有的卡会被 GameManager 当成“失效卡”清掉，干扰“抽了 1 张”这类断言。
	var fillers := _db_minions(4)
	for i in 12:
		me.deck.append(fillers[i % fillers.size()])
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hand.clear()
	foe.board.clear()
	foe.graveyard.clear()
	foe.deck.clear()
	foe.hero_hp = foe.hero_max_hp
	for i in 12:
		foe.deck.append(fillers[i % fillers.size()])
	return me


## 卡表里前 n 张「非衍生物随从」（测试要真实存在的卡，避免被 database_changed 清掉）
func _db_minions(n: int) -> Array[CardData]:
	var out: Array[CardData] = []
	for c in _db.cards:
		if c.is_token or not c.is_minion():
			continue
		out.append(c)
		if out.size() >= n:
			break
	return out


func _restore() -> void:
	AbilityPools.pools.clear()
	for e in _pool_backup:
		AbilityPools.pools.append((e as Dictionary).duplicate(true))
	AbilityPools._index.clear()
	for p in AbilityPools.pools:
		AbilityPools._index[str(p.get("id", ""))] = p
	AbilityPools.save_pools()


func _cleanup_cards() -> void:
	for id in _created_cards:
		_db.remove_card(id)


func _has_text(lines: Array, part: String) -> bool:
	for line in lines:
		if str(line).contains(part):
			return true
	return false


static func _select_meta(option: OptionButton, value: String) -> void:
	for i in option.item_count:
		var meta = option.get_item_metadata(i)
		if meta != null and str(meta) == value:
			option.select(i)
			return
	option.select(0)


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
	print("=== 随机能力测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
