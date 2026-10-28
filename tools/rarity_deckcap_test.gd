extends SceneTree
## 稀有度 + 卡牌携带上限规则测试。
##
## 运行方式：
##   godot --path <项目目录> --script res://tools/rarity_deckcap_test.gd
##
## 覆盖：
##   ① 稀有度字段：from_dict / to_dict 往返；老卡表缺省 = 普通、deck_limit = 0；
##   ② max_copies_for：传说 = 1、普通 = 全局同名上限、单卡 deck_limit 覆盖优先级最高；
##   ③ 种类上限：player_deck_stats 按「某一种类总携带数」裁剪，并报告 type_over；
##   ④ 持久化：set_type_caps 写进 deck_rules.cfg，load_deck_rules 读回；且 set_deck_rules 不会清掉 type_caps；
##   ⑤ 配置自检：config_errors 报出越界的稀有度 / 单卡携带上限，合法值不误报；
##   ⑥ 管理员面板：卡牌编辑器有「稀有度（必选）」「携带上限」两项；卡组规则面板有 4 个种类上限框，
##      设值后「应用卡组规则」把种类上限写进 CardDB。

var _fails := 0
var _fail_lines: Array[String] = []
var _frames := 0
var _db
var _panel = null
var _phase := 0
var _wait := 0
var _caps_backup := {}


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_db = root.get_node_or_null("CardDB")
		if _db == null:
			_check(false, "CardDB 自动加载")
			_finish()
			return true
		print("--- 稀有度 / 携带上限规则测试 ---")
		_caps_backup = _db.type_caps.duplicate()
		return false
	if _frames == 2:
		_db.reset_deck_rules()
		_db.set_type_caps({})
		_test_rarity_roundtrip()
		_test_max_copies_for()
		_test_type_cap()
		_test_persistence()
		_test_config_errors()
		_db.set_type_caps({})
		_phase = 1
		return false
	if _phase == 1:
		if _wait == 0:
			_test_panel_build()
			_panel = load("res://scripts/AdminPanel.gd").new()
			root.add_child(_panel)
			_wait = 1
			return false
		_wait = 0
		_phase = 2
		return false
	if _phase == 2:
		_test_panel_caps()
		if _panel != null and is_instance_valid(_panel):
			_panel.queue_free()
		_db.reset_deck_rules()
		_db.set_type_caps(_caps_backup)   # 把管理员原本的种类上限放回去
		_finish()
		return true
	return false


# ------------------------------ ① 稀有度往返 ------------------------------

func _test_rarity_roundtrip() -> void:
	var c := CardData.from_dict({"id": "rt", "card_name": "RT", "rarity": 4, "deck_limit": 3})
	_check(c.rarity == 4, "rarity 被读入（4=传说）")
	_check(c.deck_limit == 3, "deck_limit 被读入（3）")
	var d := c.to_dict()
	_check(int(d.get("rarity", -1)) == 4, "rarity 写回")
	_check(int(d.get("deck_limit", -1)) == 3, "deck_limit 写回")

	var old := CardData.from_dict({"id": "o", "card_name": "O"})
	_check(old.rarity == CardData.Rarity.COMMON, "老卡表缺省稀有度 = 普通")
	_check(old.deck_limit == 0, "老卡表缺省 deck_limit = 0（自动按稀有度）")

	_check(CardData.RARITY_NAMES.size() == 5, "有 5 档稀有度（基本/普通/稀有/史诗/传说）")
	_check(CardData.from_dict({"id": "b", "rarity": 99}).rarity == CardData.Rarity.COMMON,
		"越界的稀有度回落普通")


# ------------------------------ ② max_copies_for ------------------------------

func _test_max_copies_for() -> void:
	_db.reset_deck_rules()   # max_copies = 2
	_check(_db.max_copies == 2, "默认同名上限 = 2")

	var common := CardData.from_dict({"id": "c", "card_name": "C", "rarity": 1})
	var legendary := CardData.from_dict({"id": "l", "card_name": "L", "rarity": 4})
	var overridden := CardData.from_dict({"id": "v", "card_name": "V", "rarity": 1, "deck_limit": 5})
	_check(_db.max_copies_for(common) == 2, "普通卡 = 全局同名上限 2")
	_check(_db.max_copies_for(legendary) == 1, "传说卡 = 1（稀有度默认）")
	_check(_db.max_copies_for(overridden) == 5, "单卡 deck_limit 覆盖优先级最高（5）")

	# 全局同名上限提到 3：普通卡跟着变，传说仍是 1
	_db.set_deck_rules(_db.deck_min, _db.deck_max, 3)
	_check(_db.max_copies_for(common) == 3, "全局提到 3 → 普通卡 = 3")
	_check(_db.max_copies_for(legendary) == 1, "传说不受全局同名上限影响（仍 1）")
	_db.reset_deck_rules()


# ------------------------------ ③ 种类上限 ------------------------------

func _test_type_cap() -> void:
	_db.reset_deck_rules()
	_db.set_type_caps({})
	# 找两张不同的法术卡（类型 SPELL = 1），绕过职业限制用 class_id = ""
	var spells := []
	for c in _db.cards:
		if c.card_type == CardData.CardType.SPELL and not c.is_token:
			spells.append(c)
	_check(spells.size() >= 2, "卡表里能找到 >=2 张法术卡（实测 %d）" % spells.size())
	if spells.size() < 2:
		return
	var a: CardData = spells[0]
	var b: CardData = spells[1]
	var def := {"class_id": "", "cards": [{"id": a.id, "count": 2}, {"id": b.id, "count": 2}]}

	var s0: Dictionary = _db.player_deck_stats(def)
	_check(int(s0.get("total", 0)) == 4, "无种类上限：法术共 4 张（实测 %d）" % s0.get("total", 0))
	_check(int(s0.get("type_over", 0)) == 0, "无种类上限：type_over = 0")

	_db.set_type_caps({CardData.CardType.SPELL: 2})
	var s1: Dictionary = _db.player_deck_stats(def)
	_check(int(s1.get("total", 0)) == 2, "法术最多 2 张：被裁到 2（实测 %d）" % s1.get("total", 0))
	_check(int(s1.get("type_over", 0)) == 2, "法术最多 2 张：type_over = 2（实测 %d）" % s1.get("type_over", 0))

	# 种类上限应同时影响校验提示
	var errs: Array = _db.player_deck_errors(def)
	var hit := false
	for e in errs:
		if str(e).contains("类") or str(e).contains("上限"):
			hit = true
	_check(hit, "player_deck_errors 会报告种类上限超限")

	# 超限不影响同名上限：传说卡仍按 1 计
	var leg := _find_legendary()
	if leg != null:
		var leg_def := {"class_id": "", "cards": [{"id": leg.id, "count": 3}]}
		var ls: Dictionary = _db.player_deck_stats(leg_def)
		_check(int(ls.get("total", 0)) == 1, "传说 + 法术上限下：同名仍只 1 张（实测 %d）" % ls.get("total", 0))
	_db.set_type_caps({})


func _find_legendary() -> CardData:
	for c in _db.cards:
		if c.rarity == CardData.Rarity.LEGENDARY and not c.is_token:
			return c
	return null


# ------------------------------ ④ 持久化 ------------------------------

func _test_persistence() -> void:
	_db.reset_deck_rules()
	_db.set_type_caps({CardData.CardType.SPELL: 7, CardData.CardType.MINION: 40})
	_check(FileAccess.file_exists(_db.RULES_PATH), "规则写进了 %s" % _db.RULES_PATH)
	# 改内存里的值，再 load 回来
	_db.type_caps = {}
	_db.load_deck_rules()
	_check(_db.type_cap(CardData.CardType.SPELL) == 7, "重新加载后法术上限 = 7（%d）" % _db.type_cap(CardData.CardType.SPELL))
	_check(_db.type_cap(CardData.CardType.MINION) == 40, "重新加载后随从上限 = 40（%d）" % _db.type_cap(CardData.CardType.MINION))

	# set_deck_rules 不能把 type_caps 清掉
	_db.set_deck_rules(_db.deck_min, _db.deck_max, 3)
	_check(_db.type_cap(CardData.CardType.SPELL) == 7, "应用卡组张数规则后种类上限仍在（%d）" % _db.type_cap(CardData.CardType.SPELL))

	_db.reset_deck_rules()
	_db.set_type_caps({})


# ------------------------------ ⑤ 配置自检 ------------------------------

func _test_config_errors() -> void:
	# 稀有度越界（有效 0–4）：数据层会把坏值夹回普通，但内存里真出现越界值时自检必须报出来
	var bad_rarity := CardData.from_dict({"id": "cfg_rarity", "card_name": "越界稀有度"})
	_db.cards.append(bad_rarity)
	bad_rarity.rarity = CardData.RARITY_NAMES.size()   # 上界越界：直接写坏，模拟手改存档 / 外部写入
	_check(_config_errs_for("cfg_rarity").contains("稀有度"),
		"自检报出稀有度上界越界（%d）" % bad_rarity.rarity)
	bad_rarity.rarity = -1                             # 下界越界
	_check(_config_errs_for("cfg_rarity").contains("稀有度"), "自检报出稀有度下界越界（-1）")
	_db.cards.erase(bad_rarity)

	# 单卡携带上限超过 MAX_COPIES_LIMIT：数据层只夹下界（maxi(0, …)），上界坏值要如实报出来
	var bad_limit := CardData.from_dict({
		"id": "cfg_limit", "card_name": "越界携带上限",
		"deck_limit": CardDB.MAX_COPIES_LIMIT + 1,
	})
	_check(bad_limit.deck_limit == CardDB.MAX_COPIES_LIMIT + 1, "超上限的 deck_limit 不会被静默夹回")
	_db.cards.append(bad_limit)
	_check(_config_errs_for("cfg_limit").contains("携带上限"),
		"自检报出单卡携带上限越界（%d > %d）" % [bad_limit.deck_limit, CardDB.MAX_COPIES_LIMIT])
	_db.cards.erase(bad_limit)

	# 合法值（含边界值）不应误报
	var ok_card := CardData.from_dict({
		"id": "cfg_ok", "card_name": "合法卡",
		"rarity": CardData.Rarity.LEGENDARY, "deck_limit": CardDB.MAX_COPIES_LIMIT,
	})
	_db.cards.append(ok_card)
	var ok_errs := _config_errs_for("cfg_ok")
	_check(ok_errs == "", "合法稀有度 / 携带上限不误报（%s）" % (ok_errs if ok_errs != "" else "无"))
	_db.cards.erase(ok_card)


## 收集某张卡的配置自检结果（多条用「；」连接），没有则返回空串
func _config_errs_for(card_id: String) -> String:
	var hits: Array[String] = []
	for e in _db.config_errors():
		if e.begins_with(card_id + "「"):
			hits.append(e)
	return "；".join(hits)


# ------------------------------ ⑥ 面板 ------------------------------

func _test_panel_build() -> void:
	_db.reset_deck_rules()
	_db.set_type_caps({})


func _test_panel_caps() -> void:
	if _panel == null:
		_check(false, "管理员面板可实例化")
		return
	_check(_panel._rarity_option != null, "卡牌编辑器有「稀有度」下拉")
	_check(_panel._copies_spin != null, "卡牌编辑器有「携带上限」框")
	_check(_panel._type_cap_spins.size() == 4, "卡组规则面板有 4 个种类上限框（%d）" % _panel._type_cap_spins.size())
	if _panel._type_cap_spins.size() != 4:
		return
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL, CardData.CardType.AMULET, CardData.CardType.CITY]:
		_check(int(_panel._type_cap_spins[t].value) == 0, "种类上限框初值 = 0（不限）")

	# 设「法术最多 9 张」并应用
	_panel._type_cap_spins[CardData.CardType.SPELL].value = 9
	_panel._deck_apply_button.pressed.emit()
	_check(_db.type_cap(CardData.CardType.SPELL) == 9, "面板应用后法术上限 = 9（%d）" % _db.type_cap(CardData.CardType.SPELL))
	_check(_panel._status_label.text.contains("种类上限") or _panel._status_label.text.contains("已应用"),
		"应用有回执（%s）" % _panel._status_label.text)

	# 恢复默认：清回 0
	_panel._on_reset_deck_rules()
	_check(_db.type_cap(CardData.CardType.SPELL) == 0, "面板恢复默认后法术上限 = 0")


# ------------------------------ 断言 ------------------------------

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
	print("=== 稀有度 / 携带上限规则测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
