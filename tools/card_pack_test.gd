extends SceneTree
## 卡包 + 指定 / 无限模式测试：
##   * 卡包（CardData.pack_id / CardDB.packs）：增删改、默认基础卡包、删包后卡牌回收；
##   * 两种模式各用各的规则：指定模式自己的张数 / 同名 / 种类上限 + 可用卡包 + 限制卡表；
##     无限模式 = 全局张数规则 + 它自己的限制卡表（**两边互不影响**）；
##   * 组卡校验按模式过滤：不在本模式卡包里 / 被本模式禁用的卡不计入；
##   * 开局按模式发牌（GameManager.current_mode / 联机快照带模式）；
##   * 管理员面板：卡牌表单的卡包下拉、模式规则应用、限制卡清单。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/card_pack_test.gd
##
## 注意：会真实写入 user://card_packs.json / decks.json / cards.json / deck_rules.cfg，
## 结束时全部还原成进入测试前的样子（与 deck_rules_test 的做法一致）。

const ME := 0
const FOE := 1
const PACK_A := "tp_alpha"
const PACK_B := "tp_beta"
const TEST_DECK_NAME := "（测试）模式卡组"

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _gm = null
var _gs = null          ## GameSettings（--script 下不能静态引用自动加载标识符）
var _admin = null
var _fail_lines: Array[String] = []
var _created_cards: Array[String] = []

# 备份（结束时原样还原）
var _packs_backup: Array = []
var _rotation_backup: Dictionary = {}
var _limits_backup: Dictionary = {}
var _rules_backup: Dictionary = {}
var _mode_backup := ""
var _deck_backup := ""
var _class_backup := ""
var _deck_id := ""


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		_gs = root.get_node_or_null("GameSettings")
		if _db == null or _gm == null or _gs == null or root.get_node_or_null("AdminAuth") == null:
			_check(false, "CardDB / GameManager / GameSettings / AdminAuth 自动加载")
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
	_backup()
	_seed()
	_test_formats()
	_test_pack_crud()
	_test_card_pack_field()
	_test_rotation_rules()
	_test_limits_isolated()
	_test_mode_max_copies()
	_test_deck_validation_by_mode()
	_test_build_deck_by_mode()
	_test_admin_card_pack()
	_test_admin_format_rules()
	_test_game_manager_mode()
	_test_settings_mode()
	_restore()


# ------------------------------ 备份 / 造数据 ------------------------------

func _backup() -> void:
	# 只备份「非测试」的卡包 / 限制卡：万一上一次跑测试中途挂了，也不会把 tp_* 当成玩家数据留下来
	_packs_backup = []
	for e in _db.packs:
		if str(e.get("id", "")).begins_with("tp_"):
			continue
		_packs_backup.append((e as Dictionary).duplicate(true))
	_rotation_backup = _db.rotation_rules.duplicate(true)
	var clean_packs: Array = []
	for pid in _rotation_backup.get("packs", []):
		if not str(pid).begins_with("tp_") and _has_pack_in(_packs_backup, str(pid)):
			clean_packs.append(pid)
	if clean_packs.is_empty():
		for e in _packs_backup:
			clean_packs.append(str(e.get("id", "")))
	_rotation_backup["packs"] = clean_packs
	_limits_backup = {}
	for mode in _db.format_limits.keys():
		_limits_backup[mode] = {}
		for cid in (_db.format_limits[mode] as Dictionary).keys():
			if not str(cid).begins_with("tp_"):
				_limits_backup[mode][cid] = _db.format_limits[mode][cid]
	_rules_backup = {
		"min": int(_db.deck_min), "max": int(_db.deck_max),
		"copies": int(_db.max_copies), "caps": _db.type_caps.duplicate(true),
	}
	_mode_backup = str(_gs.get("selected_mode"))
	_deck_backup = str(_gs.get("selected_deck"))
	_class_backup = str(_gs.get("selected_class"))


## 两个测试卡包：A 放 40 张中立随从（足够按规则凑满 30 张），B 放 3 张
func _seed() -> void:
	if _db.has_pack(PACK_A):
		_db.remove_pack(PACK_A)
	if _db.has_pack(PACK_B):
		_db.remove_pack(PACK_B)
	_check(_db.add_pack(PACK_A, "测试卡包 A", "#80cbc4", "测试用"), "新增卡包 A")
	_check(_db.add_pack(PACK_B, "测试卡包 B", "#ef9a9a", "测试用"), "新增卡包 B")
	# 上次跑测试如果中途退出，可能留下同 id 的卡：先清掉，避免 add_card 自动改名导致重复
	for c in _db.cards.duplicate():
		if c.id.begins_with("tp_a_") or c.id.begins_with("tp_b_") or c.id == "tp_field":
			_db.remove_card(c.id)
	for i in 40:
		var c := _card("tp_a_%02d" % i, "测试A随从%d" % i)
		c.pack_id = PACK_A
		_create(c)
	for i in 3:
		var c := _card("tp_b_%02d" % i, "测试B随从%d" % i)
		c.pack_id = PACK_B
		_create(c)
	_db.set_deck_rules(30, 200, 2)
	_db.set_type_caps({})
	_db.reset_rotation_rules()


func _card(id: String, name_: String) -> CardData:
	var c := CardData.from_dict({
		"id": id, "card_name": name_, "cost": 1,
		"card_type": CardData.CardType.MINION, "attack": 1, "health": 1,
		"keywords": [], "effects": [], "deathrattle_effects": [],
	})
	c.sync_legacy_from_chains()
	return c


func _create(c: CardData) -> void:
	if _db.add_card(c):
		_created_cards.append(c.id)


func _restore() -> void:
	# 卡组规则（全局）
	_db.set_deck_rules(int(_rules_backup["min"]), int(_rules_backup["max"]), int(_rules_backup["copies"]))
	_db.set_type_caps(_rules_backup["caps"])
	# 模式规则 + 限制卡
	_db.rotation_rules = _rotation_backup.duplicate(true)
	_db.format_limits = {Formats.ROTATION: {}, Formats.UNLIMITED: {}}
	for mode in _limits_backup.keys():
		_db.format_limits[mode] = (_limits_backup[mode] as Dictionary).duplicate(true)
	_db._save_format_rules()
	# 卡包（直接还原数组，避免 remove_pack 改动卡牌）
	_db.packs.clear()
	for e in _packs_backup:
		_db.packs.append(e)
	_db._rebuild_pack_index()
	_db.save_packs()
	# 测试卡
	for id in _created_cards:
		_db.remove_card(id)
	if _deck_id != "":
		_db.remove_player_deck(_deck_id)
	# 设置
	_gs.selected_mode = Formats.normalized_mode(_mode_backup)
	_gs.selected_deck = _deck_backup
	_gs.selected_class = _class_backup
	var tmp_settings := "user://test_card_pack_settings.cfg"
	if FileAccess.file_exists(tmp_settings):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_settings))


# ------------------------------ 模式表 ------------------------------

func _test_formats() -> void:
	var ids := Formats.mode_ids()
	_check(ids.has(Formats.ROTATION) and ids.has(Formats.UNLIMITED), "模式表包含指定 / 无限")
	_check(Formats.mode_label(Formats.ROTATION) == "指定", "指定模式的显示名")
	_check(Formats.mode_label(Formats.UNLIMITED) == "无限", "无限模式的显示名")
	_check(Formats.normalized_mode("") == Formats.UNLIMITED, "空模式归一成无限")
	_check(Formats.normalized_mode("ghost") == Formats.UNLIMITED, "未知模式归一成无限")
	_check(Formats.is_rotation(Formats.ROTATION), "is_rotation 认得指定模式")
	_check(not Formats.is_rotation(Formats.UNLIMITED), "is_rotation 不把无限当指定")


# ------------------------------ 卡包增删改 ------------------------------

func _test_pack_crud() -> void:
	_check(_db.has_pack(PACK_A) and _db.has_pack(PACK_B), "两个测试卡包已登记")
	_check(_db.has_pack(_db.DEFAULT_PACK), "内置基础卡包存在")
	_check(_db.pack_name(PACK_A) == "测试卡包 A", "卡包显示名")
	_check(_db.pack_card_count(PACK_A) == 40, "卡包 A 有 40 张（%d）" % _db.pack_card_count(PACK_A))
	_check(_db.pack_id_valid("abc_1"), "合法卡包 id 通过")
	_check(not _db.pack_id_valid("1abc"), "数字开头的卡包 id 被拒绝")
	_check(not _db.add_pack(PACK_A, "重复", "#fff"), "重复 id 不能新增")
	_check(not _db.add_pack("", "空", "#fff"), "空 id 不能新增")
	_check(_db.update_pack(PACK_A, "测试卡包 A2", "#80cbc4", "改过"), "更新卡包")
	_check(_db.pack_name(PACK_A) == "测试卡包 A2", "更新后的卡包名")
	_check(_db.remove_pack(_db.DEFAULT_PACK) == -2, "基础卡包不可删除")

	# 删包：原本挂着它的卡回到基础卡包（这里用 B 的卡验证，稍后重建）
	var b_card = _db.get_card("tp_b_00")
	_check(b_card != null and _db.pack_of(b_card) == PACK_B, "B 卡原本在卡包 B")
	var rm = _db.remove_pack(PACK_B)
	_check(rm == 3, "删除卡包 B 影响 3 张卡（%d）" % int(rm))
	var after = _db.get_card("tp_b_00")
	_check(after != null and _db.pack_of(after) == _db.DEFAULT_PACK, "删包后卡牌回到基础卡包")
	_check(not _db.has_pack(PACK_B), "卡包 B 已删除")
	# 重建卡包 B，后面的模式测试还要用
	_db.add_pack(PACK_B, "测试卡包 B", "#ef9a9a", "测试用")
	var b2 = _db.get_card("tp_b_00")
	b2.pack_id = PACK_B
	_db.save_cards()


func _test_card_pack_field() -> void:
	var c := _card("tp_field", "测试·卡包字段")
	c.pack_id = PACK_A
	_check(c.to_dict().get("pack_id", "") == PACK_A, "卡包随 to_dict 写出")
	_check(CardData.from_dict({"id": "x", "card_name": "y"}).pack_id == "",
		"老卡表没有卡包字段 → 空（= 基础卡包）")
	var back := CardData.from_dict(c.to_dict())
	_check(back.pack_id == PACK_A, "卡包 from_dict 读回")
	_check(_db.pack_of(CardData.from_dict({"id": "z"})) == _db.DEFAULT_PACK,
		"没填卡包的卡归到基础卡包")
	c.pack_id = "no_such_pack"
	_check(_db.pack_of(c) == _db.DEFAULT_PACK, "卡包被删后 pack_of 归一成基础卡包")


# ------------------------------ 指定模式规则 ------------------------------

func _test_rotation_rules() -> void:
	_check(_db.mode_label(Formats.ROTATION) == "指定", "mode_label 指定")
	_check(_db.mode_deck_min(Formats.UNLIMITED) == 30, "无限模式用全局最少 30")
	_check(_db.mode_deck_min(Formats.ROTATION) == 30, "指定模式默认沿用全局最少 30")

	_check(not _db.set_rotation_rules(0, 40, 2, {}, [PACK_A]), "非法张数区间被拒绝")
	_check(not _db.set_rotation_rules(30, 40, 2, {}, []), "一个卡包都不勾被拒绝")
	_check(not _db.set_rotation_rules(30, 40, 2, {}, ["ghost"]), "只勾不存在的卡包被拒绝")
	_check(_db.set_rotation_rules(35, 60, 2, {CardData.CardType.SPELL: 5},
		[PACK_A, PACK_B]), "应用指定模式规则")
	_check(_db.mode_deck_min(Formats.ROTATION) == 35, "指定模式最少 35")
	_check(_db.mode_deck_max(Formats.ROTATION) == 60, "指定模式最多 60")
	_check(_db.mode_type_cap(Formats.ROTATION, CardData.CardType.SPELL) == 5,
		"指定模式法术上限 5")
	_check(_db.mode_deck_min(Formats.UNLIMITED) == 30, "改指定模式不影响无限的全局规则")
	_check(_db.mode_type_cap(Formats.UNLIMITED, CardData.CardType.SPELL) == 0,
		"无限模式的种类上限没被指定模式带偏")
	var packs = _db.mode_allowed_packs(Formats.ROTATION)
	_check(packs.size() == 2 and packs.has(PACK_A) and packs.has(PACK_B),
		"指定模式可用卡包 = 勾选的两个")
	_check(_db.mode_allowed_packs(Formats.UNLIMITED).size() >= 3,
		"无限模式可用全部卡包")

	# 落盘后重新读取，规则还在
	_db.load_format_rules()
	_check(_db.mode_deck_min(Formats.ROTATION) == 35, "指定模式规则重新读档后还在")
	_check(_db.mode_allowed_packs(Formats.ROTATION).size() == 2, "指定模式卡包重新读档后还在")


# ------------------------------ 限制卡互不影响 ------------------------------

func _test_limits_isolated() -> void:
	_db.reset_rotation_rules()
	_db.set_rotation_rules(30, 200, 2, {}, [PACK_A])
	_db.clear_mode_limits(Formats.ROTATION)
	_db.clear_mode_limits(Formats.UNLIMITED)
	var basic_card := _basic_collectible()
	var a_card = _db.get_card("tp_a_00")
	_check(basic_card != null, "找到一张基础卡包的普通卡")

	_check(_db.set_mode_limits(Formats.ROTATION, {basic_card.id: 0, a_card.id: 1}),
		"设置指定模式限制卡")
	_check(_db.mode_limit(Formats.ROTATION, basic_card.id) == 0, "指定模式里这张卡被禁用")
	_check(_db.mode_limit(Formats.UNLIMITED, basic_card.id) == _db.LIMIT_NONE,
		"无限模式里同一张卡不受影响")
	_check(not _db.mode_allows_card(Formats.ROTATION, basic_card), "指定模式不允许被禁用的卡")
	_check(_db.mode_allows_card(Formats.UNLIMITED, basic_card), "无限模式仍允许这张卡")
	_check(_db.max_copies_for_mode(a_card, Formats.ROTATION) == 1,
		"指定模式限制卡最多 1 张（%d）" % _db.max_copies_for_mode(a_card, Formats.ROTATION))
	_check(_db.max_copies_for_mode(a_card, Formats.UNLIMITED) == 2,
		"无限模式同名上限还是 2（%d）" % _db.max_copies_for_mode(a_card, Formats.UNLIMITED))

	# 无限模式的限制卡也不影响指定模式
	_db.set_mode_limits(Formats.UNLIMITED, {a_card.id: 0})
	_check(_db.mode_limit(Formats.UNLIMITED, a_card.id) == 0, "无限模式禁用 A 卡")
	_check(_db.mode_limit(Formats.ROTATION, a_card.id) == 1, "指定模式的限制保持 1 张")
	_db.clear_mode_limits(Formats.UNLIMITED)
	_check(_db.mode_allows_card(Formats.UNLIMITED, a_card), "清空后无限模式恢复可用")
	_db.clear_mode_limits(Formats.ROTATION)


func _test_mode_max_copies() -> void:
	var a_card = _db.get_card("tp_a_00")
	_db.set_mode_limits(Formats.ROTATION, {a_card.id: 0})
	_check(_db.max_copies_for_mode(a_card, Formats.ROTATION) == 0, "禁用卡在指定模式上限 0")
	_check(_db.max_copies_for_mode(a_card, Formats.UNLIMITED) == 2, "无限模式上限仍是 2")
	_db.clear_mode_limits(Formats.ROTATION)
	# 指定模式自己的同名上限（3）与全局（2）分开
	_db.set_rotation_rules(30, 200, 3, {}, [PACK_A])
	_check(_db.max_copies_for_mode(a_card, Formats.ROTATION) == 3, "指定模式同名上限 3")
	_check(_db.max_copies_for_mode(a_card, Formats.UNLIMITED) == 2, "无限模式同名上限仍 2")
	_db.set_rotation_rules(30, 200, 2, {}, [PACK_A])


# ------------------------------ 卡组校验（按模式） ------------------------------

func _test_deck_validation_by_mode() -> void:
	var def := {
		"id": "", "name": TEST_DECK_NAME, "class_id": "",
		"cards": [
			{"id": "tp_a_00", "count": 2},
			{"id": "tp_b_00", "count": 2},
		],
	}
	var rot = _db.player_deck_stats(def, Formats.ROTATION)
	var unl = _db.player_deck_stats(def, Formats.UNLIMITED)
	_check(int(rot.get("format", 0)) == 2, "指定模式里 B 卡不计入（%d）" % int(rot.get("format", 0)))
	_check(int(rot.get("total", 0)) == 2, "指定模式只剩 A 卡 2 张（%d）" % int(rot.get("total", 0)))
	_check(int(unl.get("total", 0)) == 4, "无限模式两张卡都计入（%d）" % int(unl.get("total", 0)))

	var rot_errs = _db.player_deck_errors(def, Formats.ROTATION)
	var unl_errs = _db.player_deck_errors(def, Formats.UNLIMITED)
	_check(_has_text(rot_errs, "不在"), "指定模式给出「不在可用卡包」提示")
	_check(not _has_text(unl_errs, "不在"), "无限模式不报卡包错误")
	_check(_has_text(rot_errs, "还差"), "指定模式还差张数有提示")

	# 卡组 id 落到 user://decks.json（测试结束会删）
	_deck_id = _db.upsert_player_deck("", TEST_DECK_NAME, "", def["cards"])
	_check(_deck_id != "", "测试卡组保存成功")
	_check(_db.player_deck_ready(_deck_id, Formats.UNLIMITED), "无限模式这套卡组可开局")
	var built = _db.build_player_deck(_deck_id, Formats.ROTATION)
	_check(not built.is_empty(), "指定模式也能展开出牌库")
	var all_a := true
	for c in built:
		if _db.pack_of(c) != PACK_A:
			all_a = false
	_check(all_a, "展开的牌库只含指定模式允许的卡包")


func _test_build_deck_by_mode() -> void:
	var rot_deck = _db.build_deck(-1, "", Formats.ROTATION)
	_check(rot_deck.size() >= 30, "指定模式自动配牌不少于 30 张（%d）" % rot_deck.size())
	var bad := 0
	for c in rot_deck:
		if _db.pack_of(c) not in [PACK_A]:
			bad += 1
	_check(bad == 0, "指定模式自动配牌只从勾选卡包里取（越界 %d）" % bad)
	var unl_deck = _db.build_deck(-1, "", Formats.UNLIMITED)
	_check(unl_deck.size() >= 30, "无限模式自动配牌不少于 30 张（%d）" % unl_deck.size())
	var has_other := false
	for c in unl_deck:
		if _db.pack_of(c) != PACK_A:
			has_other = true
			break
	_check(has_other, "无限模式会取到别的卡包的卡")


# ------------------------------ 管理员面板：卡包 ------------------------------

func _test_admin_card_pack() -> void:
	var a_card = _db.get_card("tp_a_00")
	_admin._load_card(a_card)
	_check(_admin._selected_card_pack() == PACK_A, "卡牌表单回填卡包")
	_check(_admin._card_pack_option.item_count == _db.packs.size(), "卡包下拉列出全部卡包")
	var form: CardData = _admin._form_to_data()
	_check(form.pack_id == PACK_A, "保存时写回卡包")

	# 基础卡包在表单里存成 ""（老存档兼容）
	var basic := _basic_collectible()
	if basic != null and _db.pack_of(basic) == _db.DEFAULT_PACK:
		_admin._load_card(basic)
		_check(_admin._form_to_data().pack_id == "", "基础卡包存成空串")

	# 下拉切到 B → 保存后卡在 B
	_select_meta(_admin._card_pack_option, PACK_B)
	_check(_admin._form_to_data().pack_id == PACK_B, "下拉切到卡包 B 后写回 B")


# ------------------------------ 管理员面板：模式规则 ------------------------------

func _test_admin_format_rules() -> void:
	_select_meta(_admin._format_option, Formats.ROTATION)
	_admin._on_format_mode_changed(_admin._format_option.selected)
	_check(_admin._fmt_mode == Formats.ROTATION, "面板切到指定模式")
	_check(int(_admin._fmt_min_spin.value) == _db.mode_deck_min(Formats.ROTATION),
		"指定模式最少张数回填")
	_check(_admin._fmt_pack_checks.has(PACK_A), "勾选区列出卡包 A")
	_check(_admin._fmt_pack_checks.has(PACK_B), "勾选区列出卡包 B")
	_check(_admin._fmt_pack_checks[PACK_A].button_pressed, "卡包 A 默认已勾选")
	_check(not _admin._fmt_pack_checks[PACK_B].button_pressed, "卡包 B 默认未勾选")

	# 改张数 + 勾上 B + 禁用一张卡 → 应用
	_admin._fmt_min_spin.value = 32
	_admin._fmt_pack_checks[PACK_B].button_pressed = true
	_select_meta(_admin._limit_card_option, "tp_a_01")
	_admin._limit_spin.value = 0
	_admin._on_limit_add()
	_check(_admin._fmt_limits.has("tp_a_01"), "限制卡清单里加进 A 卡")
	_admin._on_apply_format_rules()
	_check(_db.mode_deck_min(Formats.ROTATION) == 32, "应用后指定模式最少 32 张")
	_check(_db.mode_allowed_packs(Formats.ROTATION).has(PACK_B), "应用后卡包 B 进入可用范围")
	_check(_db.mode_limit(Formats.ROTATION, "tp_a_01") == 0, "应用后 A 卡在指定模式被禁用")
	_check(_db.mode_limit(Formats.UNLIMITED, "tp_a_01") == _db.LIMIT_NONE,
		"无限模式没有被这张限制卡影响")
	_check(_db.mode_deck_min(Formats.UNLIMITED) == 30, "无限模式张数规则没被改")

	# 切到无限模式：显示全局规则，勾选区置灰（全部卡包）
	_select_meta(_admin._format_option, Formats.UNLIMITED)
	_admin._on_format_mode_changed(_admin._format_option.selected)
	_check(_admin._fmt_mode == Formats.UNLIMITED, "面板切到无限模式")
	_check(int(_admin._fmt_min_spin.value) == _db.deck_min, "无限模式显示全局最少张数")
	var disabled_all := true
	for pid in _admin._fmt_pack_checks.keys():
		if not (_admin._fmt_pack_checks[pid] as CheckBox).disabled:
			disabled_all = false
	_check(disabled_all, "无限模式的卡包勾选全部置灰")

	# 恢复默认：指定模式回到沿用全局 + 全部卡包
	_select_meta(_admin._format_option, Formats.ROTATION)
	_admin._on_format_mode_changed(_admin._format_option.selected)
	_admin._on_reset_format_rules()
	_check(_db.mode_deck_min(Formats.ROTATION) == _db.deck_min, "恢复后指定模式沿用全局张数")
	_check(_db.mode_allowed_packs(Formats.ROTATION).size() == _db.packs.size(),
		"恢复后指定模式可用全部卡包")
	_check(_db.mode_limit(Formats.ROTATION, "tp_a_01") == _db.LIMIT_NONE,
		"恢复后限制卡表清空")


# ------------------------------ 开局 / 设置 ------------------------------

func _test_game_manager_mode() -> void:
	_gs.selected_mode = Formats.ROTATION
	_gs.selected_deck = ""
	_gs.selected_class = ""
	_db.set_rotation_rules(30, 200, 2, {}, [PACK_A])
	_gm.new_game()
	_check(_gm.current_mode == Formats.ROTATION, "开局记录了「指定」模式")
	_check(_gm.settings_mode() == Formats.ROTATION, "settings_mode 读的是主页选的那个")
	var me = _gm.get_player(ME)
	_check(me.deck.size() >= 30, "指定模式开局发到 ≥ 30 张（%d）" % me.deck.size())
	var bad := 0
	for c in me.deck:
		if _db.pack_of(c) != PACK_A:
			bad += 1
	_check(bad == 0, "我方牌库只含指定模式卡包（越界 %d）" % bad)
	var snap: Dictionary = _gm.net_snapshot(ME)
	_check(str(snap.get("mode", "")) == Formats.ROTATION, "联机快照带上对战模式")

	# 卡组在指定模式用不了时主页的提示口径
	var def := {
		"id": "", "name": TEST_DECK_NAME, "class_id": "",
		"cards": [{"id": "tp_b_00", "count": 2}],
	}
	var errs = _db.player_deck_errors(def, Formats.ROTATION)
	_check(not errs.is_empty(), "指定模式会用不了的卡组给出原因")


func _test_settings_mode() -> void:
	_gs.use_save_path("user://test_card_pack_settings.cfg")
	_gs.selected_mode = Formats.ROTATION
	_gs.save_settings()
	_gs.selected_mode = Formats.UNLIMITED
	_gs.load_settings()
	_check(_gs.current_mode() == Formats.ROTATION, "模式随设置存档往返")
	_gs.selected_mode = "ghost"
	_check(_gs.current_mode() == Formats.UNLIMITED, "坏值归一成无限")
	_gs.use_save_path(_gs.SAVE_PATH)
	_gs.selected_mode = Formats.normalized_mode(_mode_backup)


# ------------------------------ 工具 ------------------------------

static func _has_pack_in(list: Array, pid: String) -> bool:
	for e in list:
		if str((e as Dictionary).get("id", "")) == pid:
			return true
	return false


## 一张「基础卡包 + 可收集」的卡（卡表第一张可能是衍生物，不能拿来断言）
func _basic_collectible() -> CardData:
	for c in _db.cards:
		if not c.is_token and _db.pack_of(c) == _db.DEFAULT_PACK:
			return c
	return null


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
	print("=== 卡包 / 模式测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
