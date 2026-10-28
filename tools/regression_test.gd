extends SceneTree
## 回归测试：锁定本次“分析优化”修掉的缺陷，防止再次退化。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/regression_test.gd
##
## 覆盖内容：
##   1. 攻击日志与圣盾结算一致（不再把“被圣盾挡下”写成“造成伤害”）
##   2. aoe_all 即使被配成 ALL_* 目标也只结算一次（不再按目标数放大伤害）
##   3. 单体效果被错配成“不需要目标”时不会打到施法者自己
##   4. 疲劳抽牌直接结束对局时，不会把 busy 卡在 true
##   5. 死亡结算会清空全部阵亡随从（旧实现有 40 次的硬上限）
##   6. CardDB 的 id 索引在增 / 改 / 删后保持同步，配置自检能发现错配
##   7. 损坏 / 空存档自动回退到内置卡表并修复存档文件
##   8. 一次操作只重建一次手牌控件，且不留下待销毁的旧控件
##   9. 半场分界线使用全局坐标；战斗日志长度受上限保护

const ME := 0
const FOE := 1
const SHIELD_CARD := "c007"     ## 白银护卫（圣盾）
const PLAIN_MINION := "c014"    ## 暗影刺客 4/2，无关键字与效果
const BIG_MINION := "c011"      ## 巨型石魔 8/8 嘲讽
const LOG_CAP := 20000          ## 与 Main.LOG_MAX_CHARS 保持一致

var _fails := 0
var _frames := 0
var _phase := 0
var _db
var _gm
var _settings
var _main
var _admin
var _tracker
var _created := 0
var _ui_checked := false
var _fail_lines: Array[String] = []
var _capturing := false
var _logs: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	match _phase:
		0:
			if _frames >= 2:
				_db = root.get_node_or_null("CardDB")
				_gm = root.get_node_or_null("GameManager")
				_settings = root.get_node_or_null("GameSettings")
				if _db == null or _gm == null or _settings == null:
					_check(false, "CardDB / GameManager / GameSettings 自动加载")
					_finish()
					return true
				_run_logic_tests()
				_phase = 1
		1:
			if _frames >= 4:
				_setup_main()
				_phase = 2
		2:
			if _frames >= 6:
				_start_ui_action()
				_phase = 3
		3:
			# 界面刷新是「每帧合并一次」，理论上下一帧就稳定；这里等到稳定再断言，
			# 避免因为帧调度差异出现偶发失败（真的卡住则用帧预算兜底并如实报错）
			if not _ui_checked:
				var me: PlayerState = _gm.get_player(ME)
				var settled: bool = _created > 0 and _main.hand_area.get_child_count() == me.hand.size()
				if settled or _frames >= 40:
					_ui_checked = true
					_check_ui_rebuild()
					_test_drag_play()
					_check_midline()
					_check_log_cap()
					_check_admin_panel_layout()
					_test_admin_panel_save_roundtrip()
					_finish()
	return _frames > 900


# ------------------------------ 纯逻辑回归 ------------------------------

func _run_logic_tests() -> void:
	_gm.log_message.connect(_on_log)
	_test_attack_logs()
	_test_aoe_all_settled_once()
	_test_misconfigured_effect_safe()
	_test_fatal_fatigue_ends_turn()
	_test_cleanup_deaths_settles_all()
	_test_card_index_and_config_errors()
	_test_db_change_keeps_unrelated_hand()
	_test_admin_edits_reach_hand()
	_test_corrupt_save_recovery()
	_test_tmp_save_recovery()
	_test_reset_default_backs_up()
	_test_settings_validation()
	_gm.new_game()


func _test_attack_logs() -> void:
	_gm.new_game()
	_gm.log_enabled = true
	var attacker := _spawn(ME, PLAIN_MINION)

	# 打圣盾随从：日志不能声称造成了伤害
	var shielded := _spawn(FOE, SHIELD_CARD)
	_capture_begin()
	_check(_gm.attack(ME, attacker.unit_id, shielded.unit_id, FOE), "可以攻击圣盾随从")
	_check(not _logs_have("造成 %d 点伤害" % attacker.attack),
		"圣盾挡下伤害时，日志不谎报“造成伤害”")
	_check(_logs_have("圣盾被击破"), "圣盾挡下伤害时，日志提示圣盾被击破")

	# 打普通随从：日志必须出现真实伤害
	var attacker2 := _spawn(ME, PLAIN_MINION)
	var plain := _spawn(FOE, PLAIN_MINION)
	_capture_begin()
	_check(_gm.attack(ME, attacker2.unit_id, plain.unit_id, FOE), "可以攻击普通随从")
	_check(_logs_have("造成 %d 点伤害" % attacker2.attack),
		"真实造成伤害时，日志记录伤害数值")
	_gm.log_enabled = false


func _test_aoe_all_settled_once() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.max_mana = 10
	me.mana = 10
	for _i in 3:
		_spawn(FOE, BIG_MINION)
	_spawn(ME, BIG_MINION)

	# 极端配置：全场伤害效果被配成“全体敌方随从”目标
	var card := CardData.from_dict({
		"id": "reg_aoe", "card_name": "回归全场伤害", "cost": 0,
		"card_type": CardData.CardType.SPELL,
		"effect_id": "aoe_all", "value": 2,
		"target": CardData.Targeting.ALL_ENEMY_MINIONS,
	})
	me.hand.append(card)
	_check(_gm.play_card(ME, me.hand.size() - 1, -1, FOE), "打出全场伤害法术")

	var max_lost := 0
	for p in _gm.players:
		for u in p.board:
			max_lost = maxi(max_lost, u.max_health - u.health)
	_check(max_lost == 2, "全场伤害只结算一次（每个随从掉 2 点，实际掉 %d 点）" % max_lost)


func _test_misconfigured_effect_safe() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	me.max_mana = 10
	me.mana = 10

	# 错配：需要目标的伤害效果，卡表里写成了“不需要目标”
	var card := CardData.from_dict({
		"id": "reg_bad_effect", "card_name": "错配伤害卡", "cost": 0,
		"card_type": CardData.CardType.SPELL,
		"effect_id": "damage", "value": 3,
		"target": CardData.Targeting.NONE,
	})
	me.hand.append(card)
	var my_hp: int = me.hero_hp
	var foe_hp: int = foe.hero_hp
	_check(_gm.play_card(ME, me.hand.size() - 1), "错配的卡仍可打出（不崩溃）")
	_check(me.hero_hp == my_hp, "错配的单体效果不会打到施法者自己")
	_check(foe.hero_hp == foe_hp, "错配的单体效果不会被错误结算")


func _test_fatal_fatigue_ends_turn() -> void:
	_gm.new_game()
	var foe: PlayerState = _gm.get_player(FOE)
	foe.deck.clear()
	foe.hero_hp = 1
	foe.armor = 0
	_gm.end_turn()
	_check(not _gm.game_active(), "疲劳致死时对局立即结束")
	_check(_gm.winner == ME, "疲劳致死判我方获胜")
	_check(not _gm.busy, "疲劳致死时 busy 不会卡在 true")


func _test_cleanup_deaths_settles_all() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	var grave_before: int = me.graveyard.size()
	for i in 60:
		var u := BoardUnit.new()
		u.setup(_db.get_card(PLAIN_MINION).clone(), ME, -1, 80000 + i)
		u.health = 0
		me.board.append(u)
	_gm._cleanup_deaths()
	_check(me.board.is_empty(), "死亡结算清空全部阵亡随从（60 个）")
	_check(me.graveyard.size() == grave_before + 60, "阵亡随从全部进入墓地（%d）" % me.graveyard.size())


func _test_card_index_and_config_errors() -> void:
	var before: int = _db.cards.size()
	_check(_db.get_card("c001") != null, "get_card 命中所引")
	_check(_db.get_card("reg_no_such_card") == null, "get_card 未命中返回 null")

	var tmp := CardData.new()
	tmp.id = "reg_tmp"
	tmp.card_name = "回归测试卡"
	tmp.card_type = CardData.CardType.MINION
	tmp.attack = 1
	tmp.health = 1
	_check(_db.add_card(tmp), "新增卡牌")
	_check(_db.get_card("reg_tmp") == tmp, "新增后索引立即生效")

	var renamed := tmp.clone()
	renamed.card_name = "改名卡"
	_check(_db.update_card("reg_tmp", renamed), "更新卡牌")
	_check(_db.get_card("reg_tmp") == renamed, "更新后索引指向新对象")

	_check(_db.remove_card("reg_tmp"), "删除卡牌")
	_check(_db.get_card("reg_tmp") == null, "删除后索引同步移除")
	_check(_db.cards.size() == before, "卡表数量恢复为 %d" % before)

	# 配置自检：必须能报出“单体效果 + 不需要目标”
	var bad := CardData.from_dict({
		"id": "reg_bad", "card_name": "错配卡", "card_type": CardData.CardType.SPELL,
		"effect_id": "damage", "value": 3, "target": CardData.Targeting.NONE,
	})
	_db.cards.append(bad)
	var reported := false
	for e in _db.config_errors():
		if e.contains("reg_bad"):
			reported = true
	_check(reported, "卡表配置自检能发现“单体效果被配成不需要目标”")
	_db.cards.erase(bad)

	# 配置自检：召唤类效果缺少衍生物 ID
	var no_token := CardData.from_dict({
		"id": "reg_no_token", "card_name": "缺衍生物卡", "card_type": CardData.CardType.SPELL,
		"effect_id": "summon", "value": 1,
	})
	_db.cards.append(no_token)
	var reported2 := false
	for e in _db.config_errors():
		if e.contains("reg_no_token"):
			reported2 = true
	_check(reported2, "卡表配置自检能发现“召唤效果缺少衍生物 ID”")
	_db.cards.erase(no_token)

	# 配置自检：效果自己决定目标，卡表却要求选目标（会让这张牌打不出来）
	var pointless := CardData.from_dict({
		"id": "reg_pointless_target", "card_name": "多余目标卡", "card_type": CardData.CardType.SPELL,
		"effect_id": "armor", "value": 3, "target": CardData.Targeting.ENEMY_MINION,
	})
	_db.cards.append(pointless)
	var reported3 := false
	for e in _db.config_errors():
		if e.contains("reg_pointless_target"):
			reported3 = true
	_check(reported3, "卡表配置自检能发现“效果不需要目标、卡表却要求选目标”")
	_db.cards.erase(pointless)

	# 亡语的目标由引擎自动推导，不应因为 c.target 而误报
	var dr := CardData.from_dict({
		"id": "reg_deathrattle", "card_name": "亡语目标卡", "card_type": CardData.CardType.MINION,
		"attack": 1, "health": 1, "effect_id": "silence", "target": CardData.Targeting.ENEMY_MINION,
		"deathrattle_id": "damage", "death_value": 2,
	})
	_db.cards.append(dr)
	var false_positive := false
	for e in _db.config_errors():
		if e.contains("reg_deathrattle") and e.contains("亡语"):
			false_positive = true
	_check(not false_positive, "亡语不会因为 c.target 被误报目标错配")
	_db.cards.erase(dr)


func _test_corrupt_save_recovery() -> void:
	var builtin_n: int = _db._builtin_cards().size()
	var path := "user://cards.json"
	var bak := "user://cards.json.bak"

	# 模拟写入过程中崩溃留下的半截文件
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("[ {\"id\": \"broken\"")
	file.close()
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bak))

	_db.load_cards()
	_check(_db.cards.size() == builtin_n + _db.mod_card_count(), "损坏存档自动回退到内置卡表（%d 张）" % _db.cards.size())
	_check(FileAccess.file_exists(bak), "损坏的存档已先备份为 cards.json.bak")

	var check_file := FileAccess.open(path, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(check_file.get_as_text())
	check_file.close()
	_check(typeof(parsed) == TYPE_ARRAY, "损坏存档已被立刻修复为合法 JSON 数组")
	_check(_db.get_card("c001") != null, "回退后索引可用")


func _test_db_change_keeps_unrelated_hand() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	var my_hand: int = me.hand.size()
	var foe_hand: int = foe.hand.size()
	var probe := CardData.new()
	probe.id = "reg_probe_card"
	probe.card_name = "探针卡"
	probe.card_type = CardData.CardType.MINION
	probe.attack = 1
	probe.health = 1
	_db.add_card(probe)
	_check(me.hand.size() == my_hand and foe.hand.size() == foe_hand,
		"新增卡牌不会误清双方手牌（我方 %d / 敌方 %d）" % [me.hand.size(), foe.hand.size()])
	_db.remove_card("reg_probe_card")
	_check(me.hand.size() == my_hand and foe.hand.size() == foe_hand,
		"删除卡牌不会误清无关手牌（我方 %d / 敌方 %d）" % [me.hand.size(), foe.hand.size()])
	# 真正被删除的卡牌仍然必须从手牌移除（冒烟测试里也有一条）
	me.hand.append(_db.get_card("s003").clone())
	_db.remove_card("s003")
	_check(not _has_id(me.hand, "s003"), "被删除的卡牌会从手牌中移除")
	var back: CardData = null
	for c in _db._builtin_cards():
		if c.id == "s003":
			back = c
			break
	_db.add_card(back)


func _test_admin_edits_reach_hand() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.hand.append(_db.get_card("s001").clone())
	var idx: int = me.hand.size() - 1
	_check(me.hand[idx].value == 3, "手牌里的「火焰冲击」初始为 3 点")

	var edited: CardData = _db.get_card("s001").clone()
	edited.value = 10
	_db.update_card("s001", edited)
	_check(me.hand[idx].value == 10, "管理员改动会同步到已在手牌里的卡（%d）" % me.hand[idx].value)

	var restored: CardData = _db.get_card("s001").clone()
	restored.value = 3
	_db.update_card("s001", restored)
	_check(me.hand[idx].value == 3, "再次改回同样同步到手上")


func _test_tmp_save_recovery() -> void:
	_db.save_cards()
	_check(_copy_file("user://cards.json", "user://cards.json.tmp"), "准备：写出一份完整的 .tmp 中转存档")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://cards.json"))
	_db.load_cards()
	_check(_db.get_card("c001") != null, "主存档缺失时能从 .tmp 恢复（%d 张）" % _db.cards.size())
	_check(FileAccess.file_exists("user://cards.json"), "恢复后主存档已重新生成")


func _test_reset_default_backs_up() -> void:
	var bak := "user://cards.json.bak"
	if FileAccess.file_exists(bak):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(bak))
	_check(_db.reset_to_default(), "「恢复默认卡表」执行成功")
	_check(FileAccess.file_exists(bak), "恢复默认前已把原卡表备份为 cards.json.bak")
	_check(_db.cards.size() == _db._builtin_cards().size() and _db.cards.size() > 0,
		"恢复默认后卡表可用（%d 张）" % _db.cards.size())


func _test_settings_validation() -> void:
	var settings_path := "user://settings.cfg"
	# 越界角度必须夹紧到滑块量程（上限 40°，与 SettingsDialog 的滑块一致）
	_settings.fan_angle = 100.0
	_settings.save_settings()
	_settings.fan_angle = 0.0
	_settings.load_settings()
	_check(_settings.fan_angle == 40.0,
		"越界的扇形角度会夹紧到上限（%.0f°）" % _settings.fan_angle)

	# 类型不符必须回退默认，而不是被 bool() / float() 强行转换
	var cfg := ConfigFile.new()
	cfg.set_value("game", "hover_detail", 0)      # 期望 bool，这里给 int
	cfg.set_value("game", "fan_angle", "abc")     # 期望数字，这里给字符串
	cfg.save(settings_path)
	_settings.hover_detail = true
	_settings.fan_angle = 12.0
	_settings.load_settings()
	_check(_settings.hover_detail == true, "类型不符的开关保持默认值（不会被 bool(0) 变成 false）")
	_check(_settings.fan_angle == 12.0, "类型不符的数值保持上一次的值（不会被 float(\"abc\") 变成 0）")

	# save_settings(false) 只影响当前会话
	_settings.fan_angle = 20.0
	_settings.save_settings(false)
	_settings.fan_angle = 12.0
	_settings.load_settings()
	_check(_settings.fan_angle == 12.0, "save_settings(false) 不写磁盘（滑块拖动不必每步落盘）")


# ------------------------------ 界面回归 ------------------------------

func _setup_main() -> void:
	var main_scene = load("res://scenes/Main.tscn")
	_main = main_scene.instantiate()
	root.add_child(_main)
	var hand_area: Control = _main.hand_area
	hand_area.child_entered_tree.connect(func(_n: Node) -> void: _created += 1)

	# 注意：--script 模式下自动加载单例还不是全局标识符，
	# 这两个窗口脚本必须在运行时 load()（编译期引用会解析不到 AdminAuth / GameTracker）
	_admin = load("res://scripts/AdminPanel.gd").new()
	_check(_admin != null, "卡牌管理面板脚本可实例化（编译通过）")
	root.add_child(_admin)
	_tracker = load("res://scripts/TrackerPanel.gd").new()
	_check(_tracker != null, "记牌器面板脚本可实例化（编译通过）")
	root.add_child(_tracker)


func _start_ui_action() -> void:
	_test_admin_form_round_trip()
	_test_tracker_refresh_stable()
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	var idx := _find_plain_minion(me)
	_created = 0
	_main._on_hand_card_clicked(idx)


## 手牌里挑一张不需要目标的随从，没有就往手里塞一张（保证一定测得到）
func _find_plain_minion(me: PlayerState) -> int:
	for i in me.hand.size():
		var c: CardData = me.hand[i]
		if c.card_type == CardData.CardType.MINION and not c.needs_target():
			return i
	for c in _db.cards:
		if c.card_type == CardData.CardType.MINION and not c.is_token and not c.needs_target():
			me.hand.append(c.clone())
			return me.hand.size() - 1
	return -1


## 拖拽出牌是主交互，且改动了拖拽中的视觉状态重建，这里走一遍完整流程
func _test_drag_play() -> void:
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	var board_rect: Rect2 = _main.player_board.get_global_rect()
	if board_rect.size.x < 10.0 or board_rect.size.y < 10.0:
		print("[SKIP] 无头模式下战场行尺寸异常，跳过拖拽流程")
		return

	var idx := _find_plain_minion(me)
	var played: CardData = me.hand[idx]
	var hand_before: int = me.hand.size()
	var before: int = me.board.size()
	_main._on_hand_card_drag_started(idx)
	_check(_main.drag_kind == 1, "拖拽手牌后进入「拖拽出牌」状态")
	_check(_main._ghost != null, "拖拽中会显示跟随鼠标的幽灵卡")

	# 松手位置落在我方战场行 → 应当成功召唤
	_main._drag_mouse = board_rect.get_center()
	_main._finish_drag()
	# 注意：有些随从的战吼会召唤衍生物（如征募官召唤 2 个），战场增量不一定是 1，
	# 所以这里断言“确实上场了 + 被拖出的那张牌离开了手牌”
	_check(me.board.size() > before, "拖到我方战场松手即完成出牌（战场 %d -> %d）" % [before, me.board.size()])
	_check(me.hand.size() == hand_before - 1, "被拖出的牌离开了手牌（%d -> %d）" % [hand_before, me.hand.size()])
	var still_in_hand := false
	for c in me.hand:
		if c == played:
			still_in_hand = true
	_check(not still_in_hand, "拖出的那一张牌已经不在手牌里")
	_check(_main.drag_kind == 0, "出牌后拖拽状态已被清理")
	_check(_main._ghost == null, "出牌后幽灵卡已释放")


func _check_ui_rebuild() -> void:
	var me: PlayerState = _gm.get_player(ME)
	var hand_area: Control = _main.hand_area
	_check(_main.hand_cards.size() == me.hand.size(),
		"手牌控件数量与手牌一致（%d）" % me.hand.size())
	_check(hand_area.get_child_count() == me.hand.size(),
		"手牌区没有残留待销毁控件（%d）" % hand_area.get_child_count())
	_check(_created == me.hand.size(),
		"一次操作只重建一次手牌（重建 %d 次 / 手牌 %d 张）" % [_created, me.hand.size()])


## 管理员表单：未知效果 ID 与超限数值都不能被静默改写（一选中再保存就会永久改坏卡表）
func _test_admin_form_round_trip() -> void:
	var unknown := CardData.from_dict({
		"id": "reg_unknown_fx", "card_name": "未知效果卡",
		"card_type": CardData.CardType.SPELL,
		"effect_id": "burn_unknown", "value": 2,
	})
	_admin._load_card(unknown)
	_check(_admin._form_to_data().effect_id == "burn_unknown",
		"未知效果 ID 在下拉框里被保留（不会被改写成 none）")

	var big := CardData.from_dict({
		"id": "reg_big", "card_name": "大数值卡",
		"card_type": CardData.CardType.MINION,
		"cost": 12, "attack": 40, "health": 45,
	})
	_admin._load_card(big)
	var form: CardData = _admin._form_to_data()
	_check(form.cost == 12 and form.attack == 40 and form.health == 45,
		"超出编辑器默认上限的数值不会被静默夹断（%d 费 %d/%d）" % [form.cost, form.attack, form.health])


## 记牌器刷新不能反复重设 text（重设会把滚动条弹回顶部）
func _test_tracker_refresh_stable() -> void:
	_tracker.refresh()
	var first: String = _tracker._mine_body.text
	_tracker.refresh()
	_tracker.refresh()
	_check(_tracker._mine_body.text == first, "记牌器重复刷新时内容保持稳定")


func _check_midline() -> void:
	var er: Rect2 = _main.enemy_board.get_global_rect()
	var pr: Rect2 = _main.player_board.get_global_rect()
	var expected: float = (er.position.y + er.size.y + pr.position.y) * 0.5
	_check(absf(_main._arena_midline_y() - expected) < 0.5, "半场分界线按全局坐标计算")

	var arena: Rect2 = _main.arena_panel.get_global_rect()
	if arena.size.y <= 100.0:
		print("[SKIP] 无头模式下布局尺寸异常，跳过中线命中判定")
		return
	var x: float = arena.get_center().x
	var up: Dictionary = _main._drop_target_at(Vector2(x, expected - 1.0))
	var down: Dictionary = _main._drop_target_at(Vector2(x, expected + 1.0))
	_check(not up.is_empty() and int(up["player_id"]) == FOE, "中线以上判给敌方半场")
	_check(not down.is_empty() and int(down["player_id"]) == ME, "中线以下判给我方半场")


## 卡牌管理窗口的底部按钮必须真的可见（用户反馈过「制作卡片没有保存选项」：
## 表单比窗口高，把「保存 / 状态栏」裁到窗口之外了）。这里在窗口布局稳定之后按像素核对。
## 注意 Window 里的控件 `get_global_rect()` 是**窗口内坐标**，所以拿它跟 (0,0)+size 比。
func _check_admin_panel_layout() -> void:
	if _admin == null or not is_instance_valid(_admin):
		return
	var inner := Rect2i(Vector2i.ZERO, _admin.size)
	var btn = _admin._save_button
	_check(btn != null and btn.is_visible_in_tree(), "卡牌管理面板有「保存」按钮且可见")
	if btn != null:
		_check(inner.encloses(Rect2i(btn.get_global_rect())),
			"「保存」按钮在窗口内（窗口 %s / 按钮 %s）" % [str(inner), str(btn.get_global_rect())])
	_check(_admin._status_label != null and inner.encloses(Rect2i(_admin._status_label.get_global_rect())),
		"状态提示也在窗口内（能看到「已保存」这类反馈）")


## 端到端走一遍「新建卡牌 → 点保存」（用户反馈的正是这一步找不到保存入口）
func _test_admin_panel_save_roundtrip() -> void:
	if _admin == null or not is_instance_valid(_admin):
		return
	_admin._on_new_pressed()
	_admin._name_edit.text = "回归自制卡"
	_admin._cost_spin.value = 4
	_admin._type_option.selected = 0            # 随从
	_admin._attack_spin.value = 3
	_admin._health_spin.value = 5
	var before: int = _db.cards.size()
	_admin._save_button.pressed.emit()          # 等同于用鼠标点「保存」
	var after: int = _db.cards.size()
	_check(after == before + 1, "点「保存」真的新建了一张卡（%d → %d）" % [before, after])
	var new_id: String = _admin._id_edit.text
	_check(_db.get_card(new_id) != null, "新卡进入卡表（ID %s）" % new_id)
	_check(_admin._status_label.text.begins_with("已新增") or _admin._status_label.text.begins_with("已保存"),
		"状态栏给出保存反馈（%s）" % _admin._status_label.text)
	if _db.get_card(new_id) != null:            # 清理，别污染后面的断言
		_db.remove_card(new_id)


func _check_log_cap() -> void:
	_main._append_log("回归日志标记")
	_main._append_log("X".repeat(LOG_CAP + 10000))
	var total: int = _main.log_label.get_total_character_count()
	_check(total <= LOG_CAP, "战斗日志长度受上限保护（%d <= %d）" % [total, LOG_CAP])
	# 截断后应保留后半段（不是清空）；给足余量，避免正好卡在边界上
	_check(total > LOG_CAP / 4, "日志截断后仍保留最新内容而未清空（保留 %d 字符）" % total)


# ------------------------------ 辅助 ------------------------------

func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 90000 + randi() % 9999)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


func _capture_begin() -> void:
	_logs.clear()
	_capturing = true


func _on_log(text: String) -> void:
	if _capturing:
		_logs.append(text)


func _logs_have(needle: String) -> bool:
	for l in _logs:
		if l.contains(needle):
			return true
	return false


func _has_id(list: Array[CardData], id: String) -> bool:
	for c in list:
		if c.id == id:
			return true
	return false


func _copy_file(from_path: String, to_path: String) -> bool:
	var src := FileAccess.open(from_path, FileAccess.READ)
	if src == null:
		return false
	var text := src.get_as_text()
	src.close()
	var dst := FileAccess.open(to_path, FileAccess.WRITE)
	if dst == null:
		return false
	dst.store_string(text)
	dst.close()
	return true


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	for node in [_main, _admin, _tracker]:
		if node != null and is_instance_valid(node):
			node.queue_free()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 回归测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
