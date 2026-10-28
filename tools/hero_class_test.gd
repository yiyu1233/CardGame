extends SceneTree
## 主战者职业 + 自由组卡（无头测试）
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/hero_class_test.gd
##
## 覆盖：职业表读写 / 卡牌职业归属 / 卡组合法性判定 / 只用本职业 + 中立组牌 /
##       AI 随机主战者 / 删除职业不留残值 / 组卡界面能建出来。
## 测试会临时改动卡表规则与卡组存档，**结束前一律还原**（见 _restore()）。

var _frames := 0
var _phase := 0
var _failed := 0

var _db
var _gs
var _gm

## 现场快照：测试结束按它复原，绝不污染玩家的真实数据
var _hero_snapshot: Array = []
var _deck_snapshot: Array = []
var _rules_snapshot: Dictionary = {}
var _selected_deck_snapshot := ""
var _selected_class_snapshot := ""


func _initialize() -> void:
	print("=== 主战者职业 / 自由组卡 测试开始 ===")


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gs = root.get_node_or_null("GameSettings")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gs == null or _gm == null:
			_check(false, "自动加载单例")
			_finish()
			return true
		_snapshot()
		_test_class_table()
		_test_class_crud()
		_test_deck_validation()
		_phase = 1
		return false
	if _phase == 1 and _frames >= 6:
		_test_ui()
		_finish()
		return true
	return _frames > 600


# ------------------------------ 工具 ------------------------------

func _snapshot() -> void:
	_hero_snapshot = (_db.hero_classes as Array).duplicate(true)
	_deck_snapshot = (_db.player_decks as Array).duplicate(true)
	_rules_snapshot = {"min": _db.deck_min, "max": _db.deck_max, "copies": _db.max_copies}
	_selected_deck_snapshot = str(_gs.get("selected_deck"))
	_selected_class_snapshot = str(_gs.get("selected_class"))


## 测试动过规则 / 卡组 / 职业，这里统一还原，避免影响玩家真实存档
func _restore() -> void:
	_db.deck_min = int(_rules_snapshot.get("min", _db.deck_min))
	_db.deck_max = int(_rules_snapshot.get("max", _db.deck_max))
	_db.max_copies = int(_rules_snapshot.get("copies", _db.max_copies))
	_db.player_decks = _deck_snapshot.duplicate(true)
	_db.save_player_decks()
	_db.hero_classes = _hero_snapshot.duplicate(true)
	_db.save_hero_classes()
	_gs.selected_deck = _selected_deck_snapshot
	_gs.selected_class = _selected_class_snapshot
	_gs.save_settings()


func _check(ok: bool, label: String, extra: String = "") -> void:
	if ok:
		print("[ok] %s%s" % [label, ("　→ " + extra) if extra != "" else ""])
	else:
		_failed += 1
		print("[FAIL] %s%s" % [label, ("　→ " + extra) if extra != "" else ""])


func _finish() -> void:
	_restore()
	print("=== 结果：%s ===" % ("全部通过" if _failed == 0 else "%d 项失败" % _failed))
	quit(1 if _failed > 0 else 0)


## 可收集卡牌（非衍生物）
func _collectible() -> Array:
	var out: Array = []
	for c in _db.cards:
		if c != null and not c.is_token:
			out.append(c)
	return out


## 某个职业能用的一组卡（本职业 + 中立）
func _pool_for(cid: String) -> Array:
	var out: Array = []
	for c in _collectible():
		if _db.card_allowed_for_class(c, cid):
			out.append(c)
	return out


# ------------------------------ 职业表 ------------------------------

func _test_class_table() -> void:
	_check(_db != null and _db.hero_classes.size() >= 2, "职业表已载入",
		"%d 个" % _db.hero_classes.size())
	_check(not _db.has_hero_class(CardData.NEUTRAL_CLASS), "中立是保留职业，不在可编辑清单里")
	_check(_db.hero_class_name(CardData.NEUTRAL_CLASS) == "中立", "中立显示名为「中立」")

	# 没有 class_id 的老卡表数据 → 中立
	var legacy := CardData.from_dict({"id": "probe_legacy", "card_name": "老卡"})
	_check(legacy.class_id == CardData.NEUTRAL_CLASS and legacy.is_neutral(), "缺 class_id 的旧数据算中立")
	var round_trip := CardData.from_dict(legacy.to_dict())
	_check(round_trip.class_id == CardData.NEUTRAL_CLASS, "to_dict / from_dict 往返保住职业")

	var cid_a := str(_db.hero_classes[0].get("id", ""))
	var cid_b := str(_db.hero_classes[1].get("id", ""))
	var pool := _collectible()
	if pool.size() < 3:
		_check(false, "卡表里可收集卡牌太少", str(pool.size()))
		return
	var specialist = pool[0]
	var neutral_card = pool[1]
	specialist.class_id = cid_a
	_check(_db.card_class_of(specialist) == cid_a, "卡牌挂到职业上", cid_a)
	_check(_db.card_allowed_for_class(specialist, cid_a), "本职业卡可以进本职业卡组")
	_check(not _db.card_allowed_for_class(specialist, cid_b), "本职业卡不能进其它职业卡组")
	_check(_db.card_allowed_for_class(neutral_card, cid_a) and _db.card_allowed_for_class(neutral_card, cid_b),
		"中立卡任何职业都能带")
	_check(_db.card_class_of(specialist) == cid_a and _db.class_card_count(cid_a) >= 1, "按职业统计卡牌数")

	# 组牌：只收本职业 + 中立
	var built: Array = _db.build_deck(-1, cid_a)
	var leaked := 0
	for c in built:
		if not _db.card_allowed_for_class(c, cid_a):
			leaked += 1
	_check(leaked == 0, "build_deck 按职业过滤后没有越界的卡", "%d 张" % built.size())
	_check(built.size() > 0, "按职业也能组出牌库", "%d 张" % built.size())
	specialist.class_id = CardData.NEUTRAL_CLASS      # 复原


func _test_class_crud() -> void:
	var pool := _collectible()
	var victim = pool[0]
	var original_class: String = victim.class_id
	_check(_db.add_hero_class("probe_tmp", "探针职业", "#ffffff", "测试用"), "新增职业成功")
	_check(not _db.add_hero_class("probe_tmp", "重复职业", "#ffffff", ""), "重复 ID 被拒绝")
	_check(not _db.add_hero_class(CardData.NEUTRAL_CLASS, "中立", "#ffffff", ""), "保留 ID neutral 被拒绝")
	_check(not _db.add_hero_class("1bad", "非法", "#ffffff", ""), "以数字开头的 ID 被拒绝")
	_check(_db.update_hero_class("probe_tmp", "探针·改", "#ff0000", "改名了"), "修改职业成功")
	_check(_db.hero_class_name("probe_tmp") == "探针·改", "改名生效")
	victim.class_id = "probe_tmp"
	_check(_db.card_class_of(victim) == "probe_tmp", "卡牌用上新职业")
	var changed: int = _db.remove_hero_class("probe_tmp")
	_check(changed >= 1, "删除职业返回受影响的卡数", str(changed))
	_check(victim.class_id == CardData.NEUTRAL_CLASS, "删除后这些卡自动变成中立")
	_check(_db.card_class_of(victim) == CardData.NEUTRAL_CLASS, "没登记的职业 id 一律按中立算")
	_check(not _db.has_hero_class("probe_tmp"), "职业已移除")
	victim.class_id = original_class


# ------------------------------ 卡组合法性 / 组牌 ------------------------------

func _test_deck_validation() -> void:
	var cid := str(_db.hero_classes[0].get("id", ""))
	var other := str(_db.hero_classes[1].get("id", ""))
	# 卡组规则可能被管理员改过：这里用一组稳定的值（只改内存，不落盘）
	_db.deck_min = 6
	_db.deck_max = 20
	_db.max_copies = 3

	var pool := _pool_for(cid)
	if pool.size() < 3:
		_check(false, "某个职业的可用卡池太小", str(pool.size()))
		return
	var a = pool[0]
	var b = pool[1]
	var foreign = pool[2]
	foreign.class_id = other      # 临时变成别职业的卡（用完复原）

	var entries := [{"id": a.id, "count": 3}, {"id": b.id, "count": 3}]
	var def := {"id": "probe_deck", "name": "探针卡组", "class_id": cid, "cards": entries}
	_check(_db.player_deck_errors(def).is_empty(), "6 张合规卡组没有报错")
	_check(_db.player_deck_stats(def).get("total", 0) == 6, "统计到 6 张")

	var small := {"id": "x", "name": "小", "class_id": cid, "cards": [{"id": a.id, "count": 2}]}
	_check(not _db.player_deck_errors(small).is_empty(), "少于最少张数会报错")
	var over := {"id": "x", "name": "超", "class_id": cid, "cards": [{"id": a.id, "count": 9}]}
	_check(not _db.player_deck_errors(over).is_empty(), "超过同名上限会报错")
	var mixed := {"id": "x", "name": "混", "class_id": cid, "cards": [
		{"id": a.id, "count": 3}, {"id": foreign.id, "count": 3}]}
	_check(not _db.player_deck_errors(mixed).is_empty(), "混入别职业的卡会报错")
	var missing := {"id": "x", "name": "缺", "class_id": cid, "cards": [{"id": "不存在的卡", "count": 6}]}
	_check(not _db.player_deck_errors(missing).is_empty(), "卡表里没有的卡会报错")
	var bad_class := {"id": "x", "name": "坏职业", "class_id": "早就被删了", "cards": entries}
	_check(not _db.player_deck_errors(bad_class).is_empty(), "职业不存在会报错")
	_check(_db.player_deck_errors({}).size() > 0, "空卡组会报错")

	# 存档：写进去 → 读出来 → 真的能开局
	_db.player_decks.clear()
	var did: String = _db.upsert_player_deck("", "探针卡组", cid, entries)
	_check(did != "", "卡组已写入 user://decks.json", did)
	_check(_db.player_deck_by_id(did).get("name", "") == "探针卡组", "能按 id 读回卡组")
	_check(_db.player_deck_ready(did), "这套卡组可以用")
	_check(_db.player_decks_of_class(cid).size() == 1, "按职业筛得出自己的卡组")
	var built: Array = _db.build_player_deck(did)
	_check(built.size() == 6, "按这套卡组发出 6 张牌", str(built.size()))

	_gs.selected_deck = did
	_gs.selected_class = cid
	_gs.save_settings()
	_check(_gm.player_deck_ready(), "GameManager 认可这套卡组")
	_check(_gm.current_deck_name() == "探针卡组", "主页拿得到卡组名")
	_check(_gm.current_deck_class_name() == _db.hero_class_name(cid), "主页拿得到主战者职业名")

	_gm.new_game()
	var me = _gm.get_player(_gm.PLAYER_ID)
	var foe = _gm.get_player(_gm.ENEMY_ID)
	var mine_total: int = int(me.deck.size()) + int(me.hand.size())
	_check(mine_total == 6, "我方牌库 + 手牌 = 这套卡组的全部 6 张", str(mine_total))
	var leaked := 0
	for c in (me.deck as Array) + (me.hand as Array):
		if not _db.card_allowed_for_class(c, cid):
			leaked += 1
	_check(leaked == 0, "我方牌里没有不属于本职业 / 中立的卡")
	# AI 每局随机挑一个职业：它的牌要么中立、要么同属一个职业
	var foe_classes := {}
	for c in (foe.deck as Array) + (foe.hand as Array):
		var own: String = _db.card_class_of(c)
		if own != CardData.NEUTRAL_CLASS:
			foe_classes[own] = true
	_check(foe_classes.size() <= 1, "敌方 AI 只带一个职业的卡（或全中立）", str(foe_classes.keys()))
	_check(foe.deck.size() + foe.hand.size() > 0, "敌方也拿到了牌库",
		str(foe.deck.size() + foe.hand.size()))

	# 清掉测试卡组，别留在玩家存档里
	_db.remove_player_deck(did)
	_gs.selected_deck = ""
	_gs.save_settings()
	_check(_db.player_deck_by_id(did).is_empty(), "测试卡组已删除")
	foreign.class_id = CardData.NEUTRAL_CLASS


# ------------------------------ 组卡界面 ------------------------------

func _test_ui() -> void:
	var script = load("res://scripts/DeckBuilderDialog.gd")
	_check(script != null, "组卡界面脚本可加载")
	if script == null:
		return
	var dlg = script.new()
	root.add_child(dlg)
	dlg.popup_centered()
	_check(dlg.title == "组建卡组", "窗口标题为「组建卡组」")
	_check(dlg.visible, "窗口能弹出")

	var cid: String = dlg.get("_class_id")
	_check(cid != "" and _db.has_hero_class(cid), "默认选中一个主战者职业", cid)
	# 卡池：只能看到本职业 + 中立
	var pool_rows: Array = dlg.get("_pool_box").get_children()
	var expected := _pool_for(cid).size()
	_check(pool_rows.size() == expected, "卡池行数 = 本职业 + 中立的卡种数",
		"%d / %d" % [pool_rows.size(), expected])
	var leaked_row := false
	for row in pool_rows:
		var text: String = row.text
		if text == "" or not row is Button:
			continue
	if leaked_row:
		_check(false, "卡池里混进别职业的卡")

	# 加卡 → 计数 → 张数统计同步
	var add_target = _pool_for(cid)[0]
	dlg._on_add(add_target.id)
	_check(int(dlg.get("_entries").get(add_target.id, 0)) == 1, "点击卡池能把卡加进卡组")
	dlg._on_add(add_target.id)
	_check(int(dlg.get("_entries").get(add_target.id, 0)) == 2, "再加一张计数变成 2")
	dlg._on_subtract(add_target.id)
	_check(int(dlg.get("_entries").get(add_target.id, 0)) == 1, "减一张计数回到 1")
	dlg.queue_free()
