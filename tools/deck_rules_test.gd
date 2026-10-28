extends SceneTree
## 卡组规则测试：管理员可改「卡组最少 / 最多张数」与「同名卡最大携带数」。
##
## 运行方式：
##   godot --path <项目目录> --script res://tools/deck_rules_test.gd
##
## 覆盖：
##   ① 默认配置必须**不改变现状**（最少 30 / 最多 200 / 同名 2 张 → 牌库张数 = 改动前的自然张数）；
##   ② 同名卡最大携带数：1 张 → 变少、3 张 → 变多（每种都跟着变）；
##   ③ 卡组最少张数：调高 → 自动轮转补足到最少张数；
##   ④ 卡组最多张数：调低 → 自动裁到不超过最多张数；
##   ⑤ 非法配置（最少 > 最多、同名 0 张、同名 99 张）被拒绝，且**不改动**当前配置；
##   ⑥ 持久化：写进 user://deck_rules.cfg，重新 load_deck_rules() 后还能读回来；
##   ⑦ 牌库卫生：不含衍生物、城邦合计 ≤ CITY_DECK_LIMIT、每张都来自卡表；
##   ⑧ 管理员面板：三个输入框初值 = 当前配置，「应用卡组规则」写进 CardDB 且提示里带上实际张数，
##      非法值只提示不改配置，「恢复默认」回到默认三值。

var _fails := 0
var _fail_lines: Array[String] = []
var _frames := 0
var _db
var _panel = null
var _phase := 0
var _wait := 0
## 管理员真实配置的快照：本测试会把规则改来改去（最后还测「恢复默认」），
## 跑完必须把人家原来的值放回去，否则每跑一次测试就把管理员的设置抹成默认值。
var _rules_backup := {}


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_db = root.get_node_or_null("CardDB")
		if _db == null:
			_check(false, "CardDB 自动加载")
			_finish()
			return true
		print("--- 卡组规则测试 ---")
		_rules_backup = {"min": _db.deck_min, "max": _db.deck_max, "copies": _db.max_copies}
		return false
	if _frames == 2:
		_db.reset_deck_rules()
		_test_defaults()
		_test_copies()
		_test_min_max()
		_test_invalid()
		_test_persistence()
		_phase = 1
		return false
	# 面板部分要等一帧让控件排布好
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
		_test_panel_apply()
		_test_panel_reset()
		if _panel != null and is_instance_valid(_panel):
			_panel.queue_free()
		_db.reset_deck_rules()          # 别把测试配置留给别的测试
		_finish()
		return true
	return false


# ------------------------------ ① 默认值不变现状 ------------------------------

func _test_defaults() -> void:
	_check(_db.deck_min == 30 and _db.deck_max == 200,
		"默认张数区间是 30–200（%d–%d）" % [_db.deck_min, _db.deck_max])
	_check(_db.max_copies == 2, "默认同名卡最大携带数 = 2（%d）" % _db.max_copies)
	var pool := 0
	var cities := 0
	for c in _db.cards:
		if c.is_token:
			continue
		if c.is_city():
			cities += 1
		else:
			pool += 1
	var expected := pool * 2 + mini(CardData.CITY_DECK_LIMIT, cities * 2)
	var deck: Array = _db.build_deck()
	_check(deck.size() == expected,
		"默认配置下牌库 = 每种 2 张 + 城邦合计 ≤ %d（%d = %d 种 × 2 + %d）" % [
			CardData.CITY_DECK_LIMIT, deck.size(), pool, deck.size() - pool * 2])
	_check(_db.deck_rules_report().is_empty() or deck.size() >= _db.deck_min,
		"默认配置不会触发「凑不出合法卡组」")


# ------------------------------ ② 同名卡最大携带数 ------------------------------

func _test_copies() -> void:
	var base: int = _db.build_deck().size()
	_check(_db.set_deck_rules(_db.deck_min, _db.deck_max, 1), "把同名卡上限改成 1")
	var one: Array = _db.build_deck()
	_check(one.size() < base, "同名 1 张 → 牌库变少（%d < %d）" % [one.size(), base])
	var counts: Dictionary = {}
	for c in one:
		counts[c.id] = int(counts.get(c.id, 0)) + 1
	var over := 0
	for id in counts:
		if int(counts[id]) > 1 and not _db.get_card(id).is_city():
			over += 1
	_check(over == 0, "同名 1 张时每种最多 1 张（超出 %d 种）" % over)

	_check(_db.set_deck_rules(_db.deck_min, _db.deck_max, 3), "把同名卡上限改成 3")
	var three: Array = _db.build_deck()
	_check(three.size() > base, "同名 3 张 → 牌库变多（%d > %d）" % [three.size(), base])
	_check(_db.get_card("c001") != null, "卡表里有 c001 用来数份数")
	var n3 := 0
	for c in three:
		if c.id == "c001":
			n3 += 1
	_check(n3 == 3, "c001 在牌库里正好 3 张（%d）" % n3)
	_db.reset_deck_rules()


# ------------------------------ ③④ 最少 / 最多张数 ------------------------------

func _test_min_max() -> void:
	var natural: int = _db.build_deck().size()
	_check(_db.set_deck_rules(natural + 20, natural + 60, 2), "把最少张数提到 %d" % (natural + 20))
	var padded: Array = _db.build_deck()
	_check(padded.size() == natural + 20, "不足最少张数时轮转补足到 %d（实际 %d）" % [natural + 20, padded.size()])
	_check(padded.size() >= _db.deck_min, "生成结果 ≥ 最少张数")
	var all_real := true
	for c in padded:
		if _db.get_card(c.id) == null:
			all_real = false
	_check(all_real, "补出来的副本也都来自卡表")

	_db.reset_deck_rules()
	var small: int = 40
	_check(_db.set_deck_rules(10, small, 2), "把最多张数压到 %d" % small)
	var trimmed: Array = _db.build_deck()
	_check(trimmed.size() == small, "超过最多张数时裁到 %d（实际 %d）" % [small, trimmed.size()])
	_check(trimmed.size() <= _db.deck_max, "生成结果 ≤ 最多张数")
	_db.reset_deck_rules()


# ------------------------------ ⑤ 非法配置 ------------------------------

func _test_invalid() -> void:
	_db.reset_deck_rules()
	var before := [_db.deck_min, _db.deck_max, _db.max_copies]
	_check(not _db.set_deck_rules(200, 30, 2), "最少 > 最多会被拒绝")
	_check(not _db.set_deck_rules(10, 20, 0), "同名 0 张会被拒绝")
	_check(not _db.set_deck_rules(10, 20, 99), "同名 99 张会被拒绝（上限 %d）" % _db.MAX_COPIES_LIMIT)
	_check(not _db.set_deck_rules(0, 20, 2), "最少 0 张会被拒绝")
	_check([_db.deck_min, _db.deck_max, _db.max_copies] == before,
		"被拒绝后配置完全不变（%s）" % str([_db.deck_min, _db.deck_max, _db.max_copies]))
	var cfg := ConfigFile.new()
	if cfg.load(_db.RULES_PATH) == OK:
		_check(int(cfg.get_value("deck", "min", -1)) == _db.deck_min
			and int(cfg.get_value("deck", "max_copies", -1)) == _db.max_copies,
			"被拒绝的配置没有写进 deck_rules.cfg")


# ------------------------------ ⑥ 持久化 ------------------------------

func _test_persistence() -> void:
	_check(_db.set_deck_rules(35, 120, 3), "写入一组自定义规则（35 / 120 / 3）")
	_check(FileAccess.file_exists(_db.RULES_PATH), "规则写进了 %s" % _db.RULES_PATH)
	_db.deck_min = 1
	_db.deck_max = 2
	_db.max_copies = 1
	_db.load_deck_rules()
	_check(_db.deck_min == 35 and _db.deck_max == 120 and _db.max_copies == 3,
		"重新加载后读回原值（%d / %d / %d）" % [_db.deck_min, _db.deck_max, _db.max_copies])
	_db.reset_deck_rules()
	_db.load_deck_rules()
	_check(_db.deck_min == 30 and _db.deck_max == 200 and _db.max_copies == 2, "恢复默认并重新加载成功")


# ------------------------------ ⑦ 牌库卫生 ------------------------------

func _check_deck_hygiene(label: String) -> void:
	var deck: Array = _db.build_deck()
	var tokens := 0
	var cities := 0
	var unknown := 0
	for c in deck:
		if c.is_token:
			tokens += 1
		if c.is_city():
			cities += 1
		if _db.get_card(c.id) == null:
			unknown += 1
	_check(tokens == 0, "%s：牌库不含衍生物" % label)
	_check(cities <= CardData.CITY_DECK_LIMIT, "%s：城邦合计 %d ≤ %d" % [label, cities, CardData.CITY_DECK_LIMIT])
	_check(unknown == 0, "%s：牌库里的卡都来自卡表" % label)


func _test_panel_build() -> void:
	_check_deck_hygiene("默认配置")
	_db.set_deck_rules(30, 60, 1)
	_check_deck_hygiene("同名 1 张 + 最多 60 张")
	_db.reset_deck_rules()


# ------------------------------ ⑧ 面板 ------------------------------

func _test_panel_apply() -> void:
	if _panel == null:
		_check(false, "管理员面板可实例化")
		return
	_db.reset_deck_rules()
	_check(_panel._deck_min_spin != null and _panel._deck_max_spin != null and _panel._deck_copies_spin != null,
		"面板有卡组规则三个输入框")
	if _panel._deck_min_spin == null:
		return
	_check(int(_panel._deck_min_spin.value) == _db.deck_min
		and int(_panel._deck_max_spin.value) == _db.deck_max
		and int(_panel._deck_copies_spin.value) == _db.max_copies,
		"输入框初值 = 当前配置（%d / %d / %d）" % [
			int(_panel._deck_min_spin.value), int(_panel._deck_max_spin.value), int(_panel._deck_copies_spin.value)])
	_check(_panel._deck_rules_label.text.contains(str(_db.build_deck().size())),
		"说明标签里有实际生成张数（%s）" % _panel._deck_rules_label.text)

	# 非法值：只提示、不改配置
	_panel._deck_min_spin.value = 500
	_panel._deck_max_spin.value = 10
	_panel._deck_apply_button.pressed.emit()
	_check(_panel._status_label.text.contains("不合法"), "非法规则有提示（%s）" % _panel._status_label.text)
	_check(_db.deck_min == 30 and _db.deck_max == 200 and _db.max_copies == 2, "非法规则没有生效")

	# 合法值：写进 CardDB，并刷新说明
	_panel._deck_min_spin.value = 40
	_panel._deck_max_spin.value = 80
	_panel._deck_copies_spin.value = 1
	_panel._deck_apply_button.pressed.emit()
	_check(_db.deck_min == 40 and _db.deck_max == 80 and _db.max_copies == 1,
		"应用后面板的值写进了 CardDB（%d / %d / %d）" % [_db.deck_min, _db.deck_max, _db.max_copies])
	_check(_db.build_deck().size() >= 40 and _db.build_deck().size() <= 80,
		"应用后生成的牌库落在 40–80 张（%d）" % _db.build_deck().size())
	_check(_panel._status_label.text.contains("已应用"), "应用有回执（%s）" % _panel._status_label.text)
	_check(_panel._deck_rules_label.text.contains(str(_db.build_deck().size())),
		"说明标签跟着刷新（%s）" % _panel._deck_rules_label.text)


func _test_panel_reset() -> void:
	if _panel == null:
		return
	_panel._on_reset_deck_rules()
	_check(_db.deck_min == 30 and _db.deck_max == 200 and _db.max_copies == 2,
		"「恢复默认」把三项都还原（%d / %d / %d）" % [_db.deck_min, _db.deck_max, _db.max_copies])
	_check(int(_panel._deck_min_spin.value) == 30 and int(_panel._deck_copies_spin.value) == 2,
		"输入框也回到默认值")
	_check(_db.build_deck().size() == 152 or _db.build_deck().size() >= _db.deck_min,
		"恢复默认后牌库张数恢复正常（%d）" % _db.build_deck().size())


# ------------------------------ 断言 ------------------------------

func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	# 把管理员原本的卡组规则放回去（本测试过程中的改动**只该活在测试里**）
	if _db != null and not _rules_backup.is_empty():
		_db.set_deck_rules(int(_rules_backup.get("min", 30)),
			int(_rules_backup.get("max", 200)),
			int(_rules_backup.get("copies", 2)))
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 卡组规则测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
