extends SceneTree
## 城邦格测试（主战者旁的那一格）：
##   * 每 3 个**自己的**回合判定一次（第 3 / 6 / 9… 个自己的回合开始时）；
##   * 格子里空着时：先从**牌堆**随机召唤一个城邦，牌堆没有就从**墓地**召唤；
##   * 牌堆与墓地都没有 → 这个回合不召唤；
##   * **同一回合不会召唤第二次**；
##   * 城邦格**不占 7 格战场**；格子里的城邦照常可被指定 / 被攻击 / 被打空摧毁（摧毁后进墓地，之后还能被召唤回来）；
##   * 双方各自计时（AI 也有自己的城邦格）。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/city_slot_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _db
var _gm
var _main
var _fail_lines: Array[String] = []
## 管理员真实卡组规则的快照（见 _normalize_rules）
var _rules_backup := {}


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		if _db == null or _gm == null:
			_check(false, "CardDB / GameManager 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_normalize_rules()
		_run_rules()
		return false
	if _frames == 4:
		_run_ui()
		return false
	if _frames == 6:
		_check_ui_geometry()
		_finish()
		return true
	return _frames > 400


# ------------------------------ 每 3 个自己的回合 ------------------------------

## 本测试要验的是「AI 也会在自己的第 3 个回合召唤城邦」，前提是**牌堆里真有城邦**。
## 管理员如果把卡组规则调成「最多 50 张 + 同名 3 张」，全卡池自然生成的 233 张会被裁到 50 张
## （城邦会被从尾部裁掉），那样这条断言必挂——所以要先把上限放开，结束在 _finish() 还原。
func _normalize_rules() -> void:
	_rules_backup = {"min": _db.deck_min, "max": _db.deck_max, "copies": _db.max_copies}
	_db.deck_min = 30
	_db.deck_max = 1000
	_db.max_copies = 2


func _run_rules() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	_check(me.turns_taken == 1, "开局是自己的第 1 个回合（%d）" % me.turns_taken)
	_check(_gm.city_slot_unit(ME) == null, "城邦格一开始是空的")

	# 第 2 个自己的回合：不判定
	_next_my_turn()
	_check(me.turns_taken == 2, "进入自己的第 2 个回合（%d）" % me.turns_taken)
	_check(_gm.city_slot_unit(ME) == null, "第 2 个自己的回合不召唤")

	# 第 3 个自己的回合：从牌堆召唤
	var deck_cities_before: int = _city_count(me.deck)
	_check(deck_cities_before == 2, "牌堆里有 2 张城邦（%d）" % deck_cities_before)
	_next_my_turn()
	_check(me.turns_taken == 3, "进入自己的第 3 个回合（%d）" % me.turns_taken)
	var slot: BoardUnit = _gm.city_slot_unit(ME)
	_check(slot != null, "第 3 个自己的回合从牌堆召唤出了城邦")
	if slot == null:
		return
	_check(slot.is_permanent() and slot.data.is_city(), "召唤出来的确实是城邦（%s）" % slot.data.card_name)
	_check(slot.in_city_slot, "它被标记为「在城邦格里」")
	_check(_city_count(me.deck) == deck_cities_before - 1,
		"它是从牌堆里移出的（牌堆城邦 %d -> %d）" % [deck_cities_before, _city_count(me.deck)])
	_check(slot.health == slot.data.durability(), "耐久来自卡表（%d）" % slot.health)
	_check(me.city_summon_turn == _gm.turn_count, "记录了本次召唤发生的回合（%d）" % me.city_summon_turn)
	_check(not slot.can_attack(_gm.turn_count, true), "城邦格里的城邦不能攻击")

	# 同一回合不进行第二次召唤：把格子清空（模拟被打掉），再判定也不召唤
	var grave_before: int = me.graveyard.size()
	me.graveyard.append(slot.data.duplicate())
	me.board.erase(slot)
	_check(_gm.city_slot_unit(ME) == null, "清空后城邦格为空")
	_check(not _gm._try_city_slot(ME), "同一回合不会进行第二次召唤")
	_check(_gm.city_slot_unit(ME) == null, "同一回合内格子仍然是空的")
	_check(me.graveyard.size() == grave_before + 1, "墓地没有被额外消耗（%d）" % me.graveyard.size())

	# 第 4 / 5 个自己的回合：不判定
	_next_my_turn()
	_check(me.turns_taken == 4 and _gm.city_slot_unit(ME) == null, "第 4 个自己的回合不召唤")
	_next_my_turn()
	_check(me.turns_taken == 5 and _gm.city_slot_unit(ME) == null, "第 5 个自己的回合不召唤")

	# 第 6 个自己的回合：再召唤一次（牌堆里还剩 1 张城邦）
	var left: int = _city_count(me.deck)
	_next_my_turn()
	_check(me.turns_taken == 6, "进入自己的第 6 个回合")
	var slot2: BoardUnit = _gm.city_slot_unit(ME)
	_check(slot2 != null, "第 6 个自己的回合又召唤了一次")
	_check(left == 0 or _city_count(me.deck) == left - 1,
		"这次也是从牌堆移出的（牌堆城邦 %d -> %d）" % [left, _city_count(me.deck)])

	# 牌堆没有城邦 → 从墓地召唤
	_prepare()
	me = _gm.get_player(ME)
	me.deck.clear()
	for i in 6:
		me.deck.append(_db.get_card("c001").clone())
	_next_my_turn()      # 第 2 个自己的回合
	var grave_city: CardData = _db.get_card("y002").clone()
	me.graveyard.append(grave_city)
	_check(_city_count(me.deck) == 0, "牌堆里没有城邦（%d）" % _city_count(me.deck))
	_next_my_turn()      # 第 3 个 → 判定
	_check(me.turns_taken == 3, "进入自己的第 3 个回合")
	var from_grave: BoardUnit = _gm.city_slot_unit(ME)
	_check(from_grave != null and from_grave.data.id == "y002",
		"牌堆没有时从墓地召唤（%s）" % ("空" if from_grave == null else from_grave.data.card_name))
	_check(me.graveyard.size() == 0, "这张城邦从墓地移出（墓地 %d 张）" % me.graveyard.size())

	# 牌堆与墓地都没有 → 这个回合不召唤
	_prepare()
	me = _gm.get_player(ME)
	_next_my_turn()
	me.deck.clear()
	me.graveyard.clear()
	_next_my_turn()      # 第 3 个 → 判定
	_check(me.turns_taken == 3, "进入自己的第 3 个回合（牌堆与墓地都没有城邦）")
	_check(_gm.city_slot_unit(ME) == null, "牌堆与墓地都没有时不召唤")
	_check(me.city_summon_turn != _gm.turn_count, "没有召唤时不记录召唤回合")
	# 再等 3 个回合仍然不召唤
	_next_my_turn()
	_next_my_turn()
	_next_my_turn()
	_check(me.turns_taken == 6 and _gm.city_slot_unit(ME) == null, "再次判定时依旧不召唤（仍未记录）")

	# 格子已有城邦时不会重复召唤
	_prepare()
	me = _gm.get_player(ME)
	_gm.summon_city_into_slot(ME, _db.get_card("y001"), "测试放")
	_check(_gm.city_slot_unit(ME) != null, "手工放进一个城邦")
	_check(not _gm._try_city_slot(ME), "格子里已有城邦时不再召唤")
	_check(me.board.size() == 1, "没有多出第二个城邦（战场 %d）" % me.board.size())

	# 只有城邦卡能进格子
	_check(_gm.summon_city_into_slot(ME, _db.get_card("c001")) == null, "随从不能放进城邦格")
	_check(_gm.summon_city_into_slot(ME, _db.get_card("a001")) == null, "护符不能放进城邦格")

	_test_no_board_slot_used()
	_test_play_city_from_hand()
	_test_killable_and_return()
	_test_both_sides()


# ------------------------------ 不占 7 格战场 ------------------------------

func _test_no_board_slot_used() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	_gm.summon_city_into_slot(ME, _db.get_card("y001"), "测试放")
	_check(me.board.size() == 1 && _gm.board_size_used(ME) == 0,
		"城邦格里的城邦不计入战场格子（占用 %d）" % _gm.board_size_used(ME))
	var summoned := 0
	for i in _gm.BOARD_LIMIT:
		if _gm.summon_unit(ME, _db.get_card("c001")) != null:
			summoned += 1
	_check(summoned == _gm.BOARD_LIMIT,
		"有城邦在格子里时，仍然能上满 %d 个随从（实际 %d）" % [_gm.BOARD_LIMIT, summoned])
	_check(_gm.board_size_used(ME) == _gm.BOARD_LIMIT, "战场占用计数为 %d" % _gm.board_size_used(ME))
	_check(_gm.summon_unit(ME, _db.get_card("c001")) == null, "第 %d 个随从才因为战场满而失败" % (_gm.BOARD_LIMIT + 1))
	_check(me.board.size() == _gm.BOARD_LIMIT + 1, "总单位数 = 7 个随从 + 1 个城邦（%d）" % me.board.size())
	# 城邦是「召唤进城邦格」的：格子被占用就打不出（与战场满不满无关）
	me.mana = 10
	me.max_mana = 10
	me.hand.clear()
	me.hand.append(_db.get_card("y002").clone())
	_check(not _gm.can_play(ME, 0), "城邦格被占用时，城邦牌打不出")
	_check(_gm.board_size_used(ME) == _gm.BOARD_LIMIT, "城邦格里的城邦不计入占用（%d）" % _gm.board_size_used(ME))


# ------------------------------ 从手牌把城邦召唤进格子 ------------------------------

func _test_play_city_from_hand() -> void:
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	me.hand.clear()
	me.hand.append(_db.get_card("y002").clone())          # 智库城邦：安放时抽 2 张
	var mana_before: int = me.mana
	var used_before: int = _gm.board_size_used(ME)
	_check(_gm.city_slot_unit(ME) == null, "城邦格空着")
	_check(_gm.can_play(ME, 0), "城邦格空着时，手牌里的城邦可以打")
	_check(_gm.play_card(ME, 0), "打出城邦")
	var city: BoardUnit = _gm.city_slot_unit(ME)
	_check(city != null and city.in_city_slot, "城邦被召唤进了城邦格（不是战场）")
	_check(city != null and city.data.id == "y002", "格子里就是那张城邦（%s）" % ("空" if city == null else city.data.card_name))
	_check(me.hand.size() == 2, "安放效果照常结算（打掉 1 张后抽 2 张 → 手牌 %d）" % me.hand.size())
	_check(me.mana == mana_before - _db.get_card("y002").cost, "照常扣费（剩 %d）" % me.mana)
	_check(_gm.board_size_used(ME) == used_before, "不占战场格子（占用仍为 %d）" % _gm.board_size_used(ME))
	_check(city != null and city.health == _db.get_card("y002").durability(), "耐久取卡表（%d）" % (0 if city == null else city.health))

	# 格子被占用时打不出第二张
	me.mana = 10
	me.hand.clear()
	me.hand.append(_db.get_card("y001").clone())
	_check(not _gm.can_play(ME, 0), "城邦格被占用时，第二张城邦打不出")
	_check(not _gm.play_card(ME, 0), "直接调用也会被拒绝")
	_check(me.hand.size() == 1, "被拒绝时手牌没少（%d）" % me.hand.size())
	_check(_gm.city_slot_unit(ME) == city, "格子里的还是原来那个城邦")

	# 战场满了也照样打得出（它去的是城邦格，不占战场）
	_prepare()
	me = _gm.get_player(ME)
	for i in _gm.BOARD_LIMIT:
		_gm.summon_unit(ME, _db.get_card("c001"))
	me.mana = 10
	me.max_mana = 10
	me.hand.clear()
	me.hand.append(_db.get_card("y001").clone())
	_check(_gm.can_play(ME, 0), "战场铺满 7 个随从时，城邦照样打得出（进格子）")
	_check(_gm.play_card(ME, 0), "战场铺满时城邦成功召唤进城邦格")
	_check(_gm.city_slot_unit(ME) != null and _gm.board_size_used(ME) == _gm.BOARD_LIMIT,
		"战场占用不变（%d），城邦在格子里" % _gm.board_size_used(ME))


# ------------------------------ 可被解掉并能被再召唤 ------------------------------

func _test_killable_and_return() -> void:
	_prepare()
	_gm.current_player = FOE
	var me: PlayerState = _gm.get_player(ME)
	var city: BoardUnit = _gm.summon_city_into_slot(ME, _db.get_card("y001"), "测试放")
	_check(city != null, "城邦格里有城邦")

	# 可被指定为目标
	var spell: CardData = _db.get_card("s001")
	var ids: Array[int] = []
	for t in _gm.get_valid_targets(FOE, spell):
		if str(t["kind"]) == "unit":
			ids.append(int(t["unit_id"]))
	_check(ids.has(city.unit_id), "敌方技能可以指定城邦格里的城邦（可选 %d 个目标）" % ids.size())

	# 可被攻击
	var attacker: BoardUnit = _gm.summon_unit(FOE, _db.get_card("c011"))
	if attacker != null:
		attacker.summoned_turn = -1
		attacker.attacks_used = 0
	var atk_ids: Array[int] = []
	for t in _gm.get_valid_attack_targets(FOE, attacker.unit_id):
		atk_ids.append(int(t["unit_id"]))
	_check(atk_ids.has(city.unit_id), "敌方随从可以攻击城邦格里的城邦")

	# 打空耐久 → 摧毁进墓地 → 格子空出来
	var dealt: int = _gm.deal_damage_to_unit(attacker, city, 8)
	_check(dealt == 8 and city.health <= 0, "耐久被打空（造成 %d 点）" % dealt)
	_gm._cleanup_deaths()
	_check(_gm.city_slot_unit(ME) == null, "被摧毁后城邦格空出来")
	var in_grave := false
	for c in me.graveyard:
		if c.id == "y001":
			in_grave = true
	_check(in_grave, "被摧毁的城邦进入墓地（墓地 %d 张）" % me.graveyard.size())

	# 之后还能被「从墓地召唤」回来
	me.deck.clear()
	me.city_summon_turn = -1
	_check(_gm._try_city_slot(ME), "下一个判定时从墓地把城邦召唤回来")
	_check(_gm.city_slot_unit(ME) != null, "城邦格的城邦回来了")
	_check(me.graveyard.is_empty(), "墓地里的那张被移出（墓地 %d 张）" % me.graveyard.size())


# ------------------------------ 双方各自计时 ------------------------------

func _test_both_sides() -> void:
	_prepare()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.turns_taken = 3
	_check(_gm.city_slot_unit(FOE) == null, "AI 的城邦格一开始也是空的")
	_check(_gm._try_city_slot(FOE), "AI 也会在自己的第 3 个回合召唤城邦")
	var foe_slot: BoardUnit = _gm.city_slot_unit(FOE)
	_check(foe_slot != null and foe_slot.owner_id == FOE, "AI 的城邦格里有它的城邦（%s）" % ("空" if foe_slot == null else foe_slot.data.card_name))
	_check(_gm.city_slot_unit(ME) == null, "我方城邦格不受 AI 影响（仍然为空）")
	_check(_gm.board_size_used(FOE) == 0, "AI 的城邦也不占它的战场格子")


# ------------------------------ 界面 ------------------------------

func _run_ui() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	if _main == null:
		_check(false, "主场景可实例化")
		return
	_gm.new_game()
	_main.skip_mulligan()
	_main._refresh()
	_check(_main.city_slot_widget(ME) != null, "我方主战者旁有城邦格控件")
	_check(_main.city_slot_widget(FOE) != null, "敌方主战者旁也有城邦格控件")
	_check(_main.city_slot_widget(ME).unit == null, "空置时控件显示为空")

	var me: PlayerState = _gm.get_player(ME)
	var city: BoardUnit = _gm.summon_city_into_slot(ME, _db.get_card("y001"), "测试放")
	_main._refresh()
	var w: CitySlotUI = _main.city_slot_widget(ME)
	_check(w != null and w.unit != null and w.unit.unit_id == city.unit_id,
		"有城邦时控件绑定到那个城邦")
	_check(w != null and w.friendly, "我方控件标记为友方")
	_check(_main.city_slot_widget(FOE).unit == null, "敌方格子不受影响")

	# 城邦格在主战者旁、且在竞技区里 —— 布局要等一帧，所以几何检查放在 _check_ui_geometry()
	# 指定目标时城邦格里的城邦会被点亮（AI 的格子）
	_gm.summon_city_into_slot(FOE, _db.get_card("y002"), "测试放")
	var foe_city: BoardUnit = _gm.city_slot_unit(FOE)
	_main._refresh()
	_main._clear_mode()
	_main.targets = _gm.get_valid_targets(ME, _db.get_card("s001"))
	_main._highlight_drop_targets(true)
	var fw: CitySlotUI = _main.city_slot_widget(FOE)
	_check(fw != null and fw.unit != null, "敌方城邦格有城邦")
	_check(_main._is_target(foe_city.unit_id, FOE), "城邦格里的城邦确实在合法目标列表里")
	_check(fw != null and not fw.highlighted, "指定目标时城邦格不再用矩形点亮（改为指向箭头）")


## 第二帧才量几何：容器要等一帧才会重新排布子节点
func _check_ui_geometry() -> void:
	if _main == null:
		_check(false, "主场景可用（城邦格几何）")
		return
	var band: Control = _main.player_city_slot
	if band == null:
		_check(false, "我方城邦格节点可用")
		return
	var band_rect := band.get_global_rect()
	_check(band_rect.size.x > 100.0, "城邦格有实际宽度（%.0f）" % band_rect.size.x)
	_check(_main.arena_panel.get_global_rect().encloses(band_rect),
		"城邦格完全落在竞技区内（%s）" % str(band_rect))
	var frame_rect: Rect2 = _main.player_hero_frame.visual_rect()
	_check(not frame_rect.intersects(band_rect),
		"城邦格不与主战者框重叠（框 %s / 格 %s）" % [str(frame_rect), str(band_rect)])
	# 「旁」= 与主战者框同一横带。注意要用框的矩形中心，不能用 visual_rect()（那含圆盘，圆盘会按局面上下偏移）
	var frame_band: Rect2 = _main.player_hero_frame.get_global_rect()
	_check(absf(band_rect.get_center().y - frame_band.get_center().y) < 10.0,
		"城邦格与主战者框在同一横带（纵向差 %.1fpx）" % absf(band_rect.get_center().y - frame_band.get_center().y))
	# 上下两侧镜像：敌方的格子在敌方主战者旁
	var foe_band: Control = _main.enemy_city_slot
	if foe_band != null:
		var foe_band_rect := foe_band.get_global_rect()
		var foe_frame_rect: Rect2 = _main.enemy_hero_frame.visual_rect()
		_check(_main.arena_panel.get_global_rect().encloses(foe_band_rect), "敌方城邦格也在竞技区内")
		_check(not foe_frame_rect.intersects(foe_band_rect), "敌方城邦格不与敌方主战者框重叠")
		var foe_frame_band: Rect2 = _main.enemy_hero_frame.get_global_rect()
		_check(absf(foe_band_rect.get_center().y - foe_frame_band.get_center().y) < 10.0,
			"敌方城邦格与敌方主战者框在同一横带（纵向差 %.1fpx）" % absf(foe_band_rect.get_center().y - foe_frame_band.get_center().y))
	# 控件已经绑定到城邦
	var w: CitySlotUI = _main.city_slot_widget(ME)
	_check(w != null and w.unit != null, "我方城邦格控件绑定了城邦")
	var fw: CitySlotUI = _main.city_slot_widget(FOE)
	_check(fw != null and fw.unit != null, "敌方城邦格控件绑定了城邦")
	_main.queue_free()


# ------------------------------ 测试辅助 ------------------------------

## 造一个确定局面：牌堆里只留「2 张城邦 + 若干普通牌」，墓地为空
func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = true
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	me.hand.clear()
	me.board.clear()
	me.graveyard.clear()
	me.turns_taken = 1
	me.city_summon_turn = -1
	me.deck.clear()
	me.deck.append(_db.get_card("y001").clone())
	me.deck.append(_db.get_card("y002").clone())
	for i in 8:
		me.deck.append(_db.get_card("c001").clone())
	var foe: PlayerState = _gm.get_player(FOE)
	foe.hand.clear()
	foe.board.clear()
	foe.graveyard.clear()
	foe.turns_taken = 0
	foe.city_summon_turn = -1


## 推进一个「自己的回合」（只走我方回合，不会触发 AI）
func _next_my_turn() -> void:
	_gm._start_turn(ME)


func _city_count(list: Array) -> int:
	var n := 0
	for c in list:
		if c.is_city():
			n += 1
	return n


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	# 还原管理员的卡组规则（本测试为了「城邦一定会进牌库」临时把上限放开了，见 _normalize_rules）
	if _db != null and not _rules_backup.is_empty():
		_db.deck_min = int(_rules_backup.get("min", 30))
		_db.deck_max = int(_rules_backup.get("max", 200))
		_db.max_copies = int(_rules_backup.get("copies", 2))
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 城邦格测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
