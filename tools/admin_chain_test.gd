extends SceneTree
## 管理员卡牌管理升级（效果链 / 亡语链 / 主动技能）的界面测试。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/admin_chain_test.gd
##
## 覆盖内容：
##   1. 老卡（只有 effect_id / value / target）在链编辑器里显示成**一条**，
##      `_form_to_data()` 后 effects 长度为 1 且内容与老字段一致（未知效果 ID 也被保留）；
##   2. 「＋ 添加效果」加两条 → 上移 / 下移（点行上的「↑ / ↓」按钮）→ 保存顺序跟着变；边界不动；
##   3. 删除中间一条后剩余两条的顺序正确（亡语链复用同一套组件，衍生物输入框按需显示）；
##   4. 主动技能：名称 / 费用 / 目标 / 一条效果 → `skill` 的键与值正确；取消勾选 → 空字典；
##   5. 校验：未知效果 ID / 缺衍生物 ID / 技能空链 / 技能费用为 0 / 目标错配
##      都会给状态栏提示，并且**坏数据没有写进卡表**；
##   6. 保存往返：用面板写一张新卡 → 从 CardDB 读回来 → effects / deathrattle_effects / skill
##      的顺序与内容不变，效果预览显示整链 / 亡语链 / 技能行。
##
## 注意：AdminPanel.gd 依赖 autoload（AdminAuth / CardDB），必须运行时 load()，
## 不能编译期引用（--script 模式下自动加载单例还不是全局标识符）。

var _fails := 0
var _frames := 0
var _phase := 0
var _db = null
var _admin = null
var _fail_lines: Array[String] = []
## 本次测试新建的卡牌，结束时清理，避免污染 user://cards.json
var _created: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames >= 2:
		_db = root.get_node_or_null("CardDB")
		var auth = root.get_node_or_null("AdminAuth")
		if _db == null or auth == null:
			_check(false, "CardDB / AdminAuth 自动加载")
			_finish()
			return true
		if not CardData.new().has_method("effect_chain") or not CardData.new().has_method("skill_chain"):
			_check(false, "CardData 已实现冻结契约（effects / deathrattle_effects / skill + 效果链 API）")
			_finish()
			return true
		# 面板脚本必须在运行时 load()：编译期引用解析不到 AdminAuth / CardDB
		var panel_script = load("res://scripts/AdminPanel.gd")
		_check(panel_script != null, "卡牌管理面板脚本可加载")
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
		_run_tests()
		_finish()
		return false
	return _frames > 600


func _run_tests() -> void:
	_test_legacy_single_effect()
	_test_add_and_reorder()
	_test_delete_middle()
	_test_skill_editor()
	_test_validation()
	_test_save_roundtrip()
	_test_invocation_ui()
	_cleanup()


# ------------------------------ ① 老卡兼容 ------------------------------

func _test_legacy_single_effect() -> void:
	var old := CardData.from_dict({
		"id": "act_legacy", "card_name": "链测试老卡", "card_type": CardData.CardType.SPELL,
		"effect_id": "damage", "value": 3, "target": CardData.Targeting.ENEMY_MINION,
	})
	_admin._load_card(old)
	var ed = _admin._battlecry_editor
	_check(ed.row_count() == 1, "老卡在效果链编辑器里显示成一条（%d 行）" % ed.row_count())
	_check(_row_id(ed, 0) == "damage", "第一行回落到老卡的 effect_id（%s）" % _row_id(ed, 0))
	_check(_row_value(ed, 0) == 3, "第一行带回老卡的 value（%d）" % _row_value(ed, 0))
	_check(_row_target(ed, 0) == CardData.Targeting.ENEMY_MINION,
		"第一行带回老卡的 target（%d）" % _row_target(ed, 0))
	var form: CardData = _admin._form_to_data()
	_check(form.effects.size() == 1, "保存后 effects 长度为 1（%d）" % form.effects.size())
	_check(_chain_sig(form.effects) == "damage:3:%d:" % CardData.Targeting.ENEMY_MINION,
		"写回的链内容与老字段一致（%s）" % _chain_sig(form.effects))
	_check(form.effect_id == "damage" and form.value == 3 and form.target == CardData.Targeting.ENEMY_MINION,
		"老字段镜像保持既有行为（effect_id=%s value=%d target=%d）" % [form.effect_id, form.value, form.target])

	# 未知效果 ID：沿用「选中一下再保存不会被改写成 none」的既有口径
	var unknown := CardData.from_dict({
		"id": "act_unknown", "card_name": "未知效果卡", "card_type": CardData.CardType.SPELL,
		"effect_id": "act_burn_unknown", "value": 2,
	})
	_admin._load_card(unknown)
	_check(_row_id(_admin._battlecry_editor, 0) == "act_burn_unknown",
		"未知效果 ID 在链行里被保留（%s）" % _row_id(_admin._battlecry_editor, 0))
	_check(_admin._form_to_data().effect_id == "act_burn_unknown",
		"未知效果 ID 不会被静默改写成 none")


# ------------------------------ ② 添加 / 排序 ------------------------------

func _test_add_and_reorder() -> void:
	_admin._on_new_pressed()
	var ed = _admin._battlecry_editor
	ed.add_button.pressed.emit()                       # 等同于点「＋ 添加效果」
	_check(ed.row_count() == 1, "点「＋ 添加效果」加出第一行")
	_check(_row_id(ed, 0) == "none", "新条目默认是「无效果」（%s）" % _row_id(ed, 0))
	ed.set_row_effect(0, "damage")
	_set_row(ed, 0, 3, CardData.Targeting.ENEMY_MINION)
	_check(_row_id(ed, 0) == "damage" and _row_value(ed, 0) == 3,
		"选中效果后该行的效果 / 数值正确（%s / %d）" % [_row_id(ed, 0), _row_value(ed, 0)])

	ed.add_button.pressed.emit()                       # 第二条
	ed.set_row_effect(1, "draw")
	_set_row(ed, 1, 2, CardData.Targeting.NONE)
	_check(ed.row_count() == 2, "再加一条得到两行（%d）" % ed.row_count())
	_check(_ids_of(ed) == "damage,draw", "两行顺序 = 添加顺序（%s）" % _ids_of(ed))

	# 下移第一条（等价于交换这两条）
	_press_row_button(ed, 0, "down")
	_check(_ids_of(ed) == "draw,damage", "「↓」交换两条的顺序（%s）" % _ids_of(ed))
	_check(_row_value(ed, 0) == 2 and _row_value(ed, 1) == 3, "整行一起移动（数值跟着走）")
	_check(_form_ids(_admin) == "draw,damage", "保存的 effects 顺序跟着行顺序变（%s）" % _form_ids(_admin))

	# 再上移回去
	_press_row_button(ed, 1, "up")
	_check(_ids_of(ed) == "damage,draw", "「↑」交换回来（%s）" % _ids_of(ed))
	_check(_form_ids(_admin) == "damage,draw", "保存的 effects 顺序也跟着回来")

	# 边界：第一行上移、最后一行下移都不动
	_press_row_button(ed, 0, "up")
	_check(_ids_of(ed) == "damage,draw", "第一行「↑」是空操作（边界）")
	_press_row_button(ed, 1, "down")
	_check(_ids_of(ed) == "damage,draw", "最后一行「↓」是空操作（边界）")

	var form: CardData = _admin._form_to_data()
	_check(_chain_sig(form.effects) == "damage:3:%d:|draw:2:0:" % CardData.Targeting.ENEMY_MINION,
		"两条效果的内容与顺序都写回（%s）" % _chain_sig(form.effects))


# ------------------------------ ③ 删除中间一条 ------------------------------

func _test_delete_middle() -> void:
	_admin._on_new_pressed()
	var ed = _admin._battlecry_editor
	for id in ["damage", "draw", "armor"]:
		ed.add_row()
		ed.set_row_effect(ed.row_count() - 1, id)
	_check(ed.row_count() == 3, "先加三条（%d）" % ed.row_count())
	_press_row_button(ed, 1, "remove")
	_check(ed.row_count() == 2, "删除中间一条后剩两行（%d）" % ed.row_count())
	_check(_ids_of(ed) == "damage,armor", "剩余两条顺序正确（%s）" % _ids_of(ed))
	_check(_form_ids(_admin) == "damage,armor", "保存的 effects 也只剩两条且顺序正确（%s）" % _form_ids(_admin))

	# 亡语链复用同一套组件，写回 deathrattle_effects
	var dd = _admin._death_editor
	dd.add_button.pressed.emit()
	dd.set_row_effect(0, "summon")
	_check(_row_token_visible(dd, 0), "召唤类效果显示衍生物输入框")
	dd.add_button.pressed.emit()
	dd.set_row_effect(1, "draw")
	_check(not _row_token_visible(dd, 1), "非召唤类效果隐藏衍生物输入框")
	_check(_form_ids_of(_admin._form_to_data().deathrattle_effects) == "summon,draw",
		"亡语链独立写回 deathrattle_effects（%s）" % _form_ids_of(_admin._form_to_data().deathrattle_effects))


# ------------------------------ ④ 主动技能 ------------------------------

func _test_skill_editor() -> void:
	_admin._on_new_pressed()
	_check(_admin._form_to_data().skill.is_empty(), "默认没有技能（skill = {}）")
	_admin._skill_check.button_pressed = true
	_check(_admin._skill_box.visible, "勾选「启用主动技能」后展开技能编辑区")

	_admin._skill_name_edit.text = "链测试技能"
	_admin._skill_cost_spin.value = 3
	_admin._skill_editor.add_button.pressed.emit()
	_admin._skill_editor.set_row_effect(0, "damage")
	_set_row(_admin._skill_editor, 0, 4, CardData.Targeting.ENEMY_MINION)
	_check(_admin._skill_target_option.selected == CardData.Targeting.ENEMY_MINION,
		"技能目标自动带入链里需要选目标的那一条（%d）" % _admin._skill_target_option.selected)

	var sk: Dictionary = _admin._form_to_data().skill
	var keys := PackedStringArray()
	var raw_keys := sk.keys()
	raw_keys.sort()
	for k in raw_keys:
		keys.append(str(k))
	_check(",".join(keys) == "cost,effects,name,once_per_turn,target",
		"技能字典的键与契约一致（%s）" % ",".join(keys))
	_check(str(sk.get("name", "")) == "链测试技能", "技能名称写回（%s）" % str(sk.get("name", "")))
	_check(int(sk.get("cost", -1)) == 3, "能量点费用写回（%d）" % int(sk.get("cost", -1)))
	_check(int(sk.get("target", -1)) == CardData.Targeting.ENEMY_MINION,
		"技能目标写回（%d）" % int(sk.get("target", -1)))
	_check(bool(sk.get("once_per_turn", false)), "「每回合一次」写回（默认勾选）")
	_check(_chain_sig(sk.get("effects", [])) == "damage:4:%d:" % CardData.Targeting.ENEMY_MINION,
		"技能效果链写回（%s）" % _chain_sig(sk.get("effects", [])))

	# 「每回合一次」可关掉
	_admin._skill_once_check.button_pressed = false
	_check(not bool(_admin._form_to_data().skill.get("once_per_turn", true)), "关掉「每回合一次」后写回 false")

	# 取消勾选 → 没有技能
	_admin._skill_check.button_pressed = false
	_check(_admin._form_to_data().skill.is_empty(), "取消勾选「启用主动技能」后 skill 为空字典")
	_check(not _admin._skill_box.visible, "取消勾选后技能编辑区收起")


# ------------------------------ ⑤ 校验 ------------------------------

func _test_validation() -> void:
	var before: int = _db.cards.size()

	# ① 未知效果 ID
	_admin._on_new_pressed()
	_admin._name_edit.text = "校验：未知效果"
	_admin._battlecry_editor.add_row()
	_admin._battlecry_editor.set_row_effect(0, "act_no_such_effect")
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before, "未知效果 ID 不会写进卡表（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.contains("未知效果"),
		"未知效果 ID 有提示（%s）" % _admin._status_label.text)

	# ② 召唤类效果缺衍生物 ID
	_admin._on_new_pressed()
	_admin._name_edit.text = "校验：缺衍生物"
	_admin._battlecry_editor.add_row()
	_admin._battlecry_editor.set_row_effect(0, "summon")
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before, "缺衍生物 ID 不会写进卡表（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.contains("衍生物"),
		"缺衍生物 ID 有提示（%s）" % _admin._status_label.text)

	# ③ 技能启用但效果链为空
	_admin._on_new_pressed()
	_admin._name_edit.text = "校验：技能空链"
	_admin._skill_check.button_pressed = true
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before, "技能空链不会写进卡表（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.contains("技能") and _admin._status_label.text.contains("效果"),
		"技能空链有提示（%s）" % _admin._status_label.text)

	# ③b 技能链有内容 + PP 花费为 0 → **合法（免费技能）**，应当保存成功
	_admin._skill_editor.add_row()
	_admin._skill_editor.set_row_effect(0, "draw")
	_admin._skill_cost_spin.value = 0
	_check(_admin._skill_cost_spin.min_value == 0.0, "技能花费滑杆允许 0（免费技能）")
	_check(int(_admin._skill_cost_spin.max_value) == 10, "技能花费上限 = PP 上限 10（%d）" % int(_admin._skill_cost_spin.max_value))
	_admin._name_edit.text = "校验：免费技能"
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before + 1,
		"PP 花费 0 的技能可以保存（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.begins_with("已新增"),
		"免费技能保存成功（%s）" % _admin._status_label.text)
	if _db.cards.size() == before + 1:
		var free_card: CardData = _db.get_card(_admin._id_edit.text)
		_check(free_card != null and free_card.skill_cost() == 0 and free_card.has_skill(),
			"免费技能写进卡表（花费 %d PP）" % (free_card.skill_cost() if free_card != null else -1))
		_db.remove_card(_admin._id_edit.text)      # 清理，别影响后面的数量断言
	before = _db.cards.size()

	# ④ 目标错配：单体效果被配成「不需要目标」（沿用既有告警口径）
	_admin._on_new_pressed()
	_admin._name_edit.text = "校验：目标错配"
	_admin._battlecry_editor.add_row()
	_admin._battlecry_editor.set_row_effect(0, "damage")
	_set_row(_admin._battlecry_editor, 0, 3, CardData.Targeting.NONE)
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before, "目标错配不会写进卡表（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.contains("目标"),
		"目标错配有提示（%s）" % _admin._status_label.text)


# ------------------------------ ⑥ 保存往返 ------------------------------

func _test_save_roundtrip() -> void:
	var token_id := _find_token_id()
	_check(token_id != "", "卡表里有可用的衍生物（%s）" % token_id)

	_admin._on_new_pressed()
	_admin._name_edit.text = "链式往返测试卡"
	_admin._cost_spin.value = 4
	_admin._type_option.selected = CardData.CardType.MINION
	_admin._attack_spin.value = 3
	_admin._health_spin.value = 5
	_admin._desc_edit.text = "由 tools/admin_chain_test.gd 创建"

	var bc = _admin._battlecry_editor
	bc.add_row()
	bc.set_row_effect(0, "damage")
	_set_row(bc, 0, 2, CardData.Targeting.ENEMY_MINION)
	var want_bc := "damage:2:%d:" % CardData.Targeting.ENEMY_MINION
	bc.add_row()
	if token_id != "":
		bc.set_row_effect(1, "summon")
		_set_row(bc, 1, 1, CardData.Targeting.NONE)
		_set_row_token(bc, 1, token_id)
		want_bc += "|summon:1:0:%s" % token_id
	else:
		bc.set_row_effect(1, "draw")
		_set_row(bc, 1, 1, CardData.Targeting.NONE)
		want_bc += "|draw:1:0:"

	var dr = _admin._death_editor
	dr.add_row()
	dr.set_row_effect(0, "armor")
	_set_row(dr, 0, 2, CardData.Targeting.NONE)
	dr.add_row()
	dr.set_row_effect(1, "draw")
	_set_row(dr, 1, 1, CardData.Targeting.NONE)
	var want_dr := "armor:2:0:|draw:1:0:"

	_admin._skill_check.button_pressed = true
	_admin._skill_name_edit.text = "链式技能"
	_admin._skill_cost_spin.value = 2
	_admin._skill_editor.add_row()
	_admin._skill_editor.set_row_effect(0, "damage")
	_set_row(_admin._skill_editor, 0, 3, CardData.Targeting.ENEMY_MINION)
	var want_sk := "damage:3:%d:" % CardData.Targeting.ENEMY_MINION

	var before: int = _db.cards.size()
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before + 1, "点「保存」新建了带链的卡（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.begins_with("已新增"),
		"状态栏给出保存反馈（%s）" % _admin._status_label.text)

	var new_id: String = _admin._id_edit.text
	var back: CardData = _db.get_card(new_id)
	_check(back != null, "新卡进入卡表（ID %s）" % new_id)
	if back == null:
		return
	_created.append(new_id)
	_check(_chain_sig(back.effects) == want_bc, "effects 的顺序与内容往返不变（%s）" % _chain_sig(back.effects))
	_check(_chain_sig(back.deathrattle_effects) == want_dr,
		"deathrattle_effects 的顺序与内容往返不变（%s）" % _chain_sig(back.deathrattle_effects))
	_check(back.effect_chain().size() == 2 and back.deathrattle_chain().size() == 2,
		"链 API 读回的条数正确（%d / %d）" % [back.effect_chain().size(), back.deathrattle_chain().size()])
	_check(back.has_skill(), "读回的卡带主动技能")
	_check(back.skill_name() == "链式技能", "技能名读回（%s）" % back.skill_name())
	_check(back.skill_cost() == 2, "技能费用读回（%d）" % back.skill_cost())
	_check(back.skill_once_per_turn(), "「每回合一次」读回")
	_check(back.skill_target() == CardData.Targeting.ENEMY_MINION,
		"技能目标读回（%d）" % back.skill_target())
	_check(_chain_sig(back.skill_chain()) == want_sk, "技能效果链往返不变（%s）" % _chain_sig(back.skill_chain()))

	# 效果预览：整链 / 亡语链 / 技能行都在
	var preview: String = _admin._effect_preview.text
	_check(preview.contains("效果链") and preview.contains("伤害"), "效果预览显示整链文本")
	_check(preview.contains("亡语链"), "效果预览显示亡语链文本")
	_check(preview.contains("技能") and preview.contains("链式技能"), "效果预览显示技能行")

	# 再读一次（面板 → 卡表 → 面板）：链行数不变
	_admin._load_card(back)
	_check(_admin._battlecry_editor.row_count() == back.effect_chain().size(),
		"重新载入后链行数不变（%d）" % _admin._battlecry_editor.row_count())
	_check(_admin._death_editor.row_count() == back.deathrattle_chain().size(),
		"重新载入后亡语链行数不变（%d）" % _admin._death_editor.row_count())
	_check(_admin._skill_check.button_pressed and _admin._skill_editor.row_count() == 1,
		"重新载入后技能编辑器展开且有一条技能效果")


# ------------------------------ ⑦ 瞬念召唤编辑区 ------------------------------

func _test_invocation_ui() -> void:
	var before: int = _db.cards.size()

	# ① 启用瞬念召唤但没选条件 → 拦下
	_admin._on_new_pressed()
	_admin._name_edit.text = "瞬念：没选条件"
	_admin._type_option.selected = CardData.CardType.MINION
	_admin._invoke_check.button_pressed = true
	_check(_admin._invoke_box.visible, "勾选后展开瞬念召唤编辑区")
	_check(_admin._invoke_metric_option.item_count == InvokeConditions.metrics().size() + 1,
		"条件下拉里的项数 = 可选的量 + 「（未选择）」（%d）" % _admin._invoke_metric_option.item_count)
	_check(_admin._invoke_op_option.item_count == InvokeConditions.OPS.size(),
		"比较符下拉 = 六种（%d）" % _admin._invoke_op_option.item_count)
	_check(_admin._invoke_metric_option.selected == 0, "默认落在「（未选择）」")
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before, "没选条件不会写进卡表（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.contains("触发条件"),
		"没选条件有提示（%s）" % _admin._status_label.text)

	# ①b 选了量之后，比较符会自动跳成这个量的默认方向
	_select_invoke_metric("self_hp")
	_check(InvokeConditions.OPS[_admin._invoke_op_option.selected] == "<=",
		"选「我方英雄生命」自动配上 ≤（%s）" % InvokeConditions.OPS[_admin._invoke_op_option.selected])
	_select_invoke_metric("hand")
	_check(InvokeConditions.OPS[_admin._invoke_op_option.selected] == "<=",
		"选「我方手牌张数」自动配上 ≤（%s）" % InvokeConditions.OPS[_admin._invoke_op_option.selected])

	# ② 法术也能配瞬念召唤：在牌库 / 墓地直接发动或进入手牌（不会上场）
	_admin._type_option.selected = CardData.CardType.SPELL
	_admin._invoke_metric_option.selected = _invoke_metric_index("turn")
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before + 1, "法术配瞬念召唤可以保存（%d → %d）" % [before, _db.cards.size()])
	_check(_admin._status_label.text.begins_with("已新增"),
		"法术配瞬念召唤保存成功（%s）" % _admin._status_label.text)
	var spell_id: String = _admin._id_edit.text
	_db.remove_card(spell_id)
	_admin._on_new_pressed()
	_check(_db.cards.size() == before, "法术测试卡已清理（%d）" % _db.cards.size())

	# ③ 正常配置 → 保存 → 读回（上一步新建时把勾选框重置了，这里重新启用）
	_admin._type_option.selected = CardData.CardType.MINION
	_admin._invoke_check.button_pressed = true
	_admin._attack_spin.value = 4
	_admin._health_spin.value = 6
	_admin._name_edit.text = "瞬念往返测试卡"
	_admin._invoke_metric_option.selected = _invoke_metric_index("turn")
	_admin._invoke_op_option.selected = InvokeConditions.OPS.find(">=")
	_admin._invoke_value_spin.value = 5
	_admin._invoke_timing_option.selected = InvokeConditions.TIME_SELF_TURN_START
	_admin._save_button.pressed.emit()
	_check(_db.cards.size() == before + 1, "点「保存」新建了带瞬念召唤的卡（%d → %d）" % [
		before, _db.cards.size()])
	_check(_admin._status_label.text.begins_with("已新增"),
		"状态栏给出保存反馈（%s）" % _admin._status_label.text)

	var new_id: String = _admin._id_edit.text
	var back: CardData = _db.get_card(new_id)
	_check(back != null, "新卡进入卡表（ID %s）" % new_id)
	if back == null:
		return
	_created.append(new_id)
	_check(back.has_invocation(), "读回的卡带瞬念召唤")
	_check(back.invoke_metric() == "turn", "条件里的量往返不变（%s）" % back.invoke_metric())
	_check(back.invoke_op() == ">=", "比较符往返不变（%s）" % back.invoke_op())
	_check(back.invoke_value() == 5, "阈值往返不变（%d）" % back.invoke_value())
	_check(back.invoke_timing() == InvokeConditions.TIME_SELF_TURN_START,
		"触发时机往返不变（%d）" % back.invoke_timing())
	_check(back.invoke_text().contains("瞬念召唤"), "卡面文本带瞬念召唤（%s）" % back.invoke_text())
	_check(_admin._effect_preview.text.contains("瞬念召唤"), "效果预览显示瞬念召唤一行")

	# 面板 → 卡表 → 面板：勾选框与条件、比较符、阈值、时机都被回填
	_admin._load_card(back)
	_check(_admin._invoke_check.button_pressed, "重新载入后勾选框是勾上的")
	_check(_admin._invoke_box.visible, "重新载入后编辑区展开")
	_check(_admin._invoke_metric_option.selected == _invoke_metric_index("turn"),
		"重新载入后条件被回填（项 %d）" % _admin._invoke_metric_option.selected)
	_check(InvokeConditions.OPS[_admin._invoke_op_option.selected] == ">=",
		"重新载入后比较符被回填（%s）" % InvokeConditions.OPS[_admin._invoke_op_option.selected])
	_check(_admin._invoke_value_spin.value == 5, "重新载入后阈值被回填（%d）" % int(
		_admin._invoke_value_spin.value))
	_check(_admin._invoke_timing_option.selected == InvokeConditions.TIME_SELF_TURN_START,
		"重新载入后时机被回填（%d）" % _admin._invoke_timing_option.selected)

	# ④ 取消勾选 → 表单里是空字典（保存后卡表里的瞬念召唤被清掉）
	_admin._invoke_check.button_pressed = false
	var cleared: CardData = _admin._form_to_data()
	_check(cleared.invocation.is_empty(), "取消勾选后 invation 是空字典（%s）" % str(cleared.invocation))
	_check(not cleared.has_invocation(), "取消勾选后 has_invocation() = false")

	# ⑤ 新建卡片时编辑区是收起的（不会把上一张卡的瞬念召唤带过去）
	_admin._on_new_pressed()
	_check(not _admin._invoke_check.button_pressed, "新建模式下瞬念召唤默认是关的")
	_check(not _admin._invoke_box.visible, "新建模式下瞬念召唤编辑区收起")


# ------------------------------ 辅助 ------------------------------

## 像管理员点了一下条件下拉那样选一个「量」：置选中 + 发 `item_selected`
## （直接赋值 `selected` 不发信号，界面回调就跑不到，这里走的是和真实点击同一条路径）
func _select_invoke_metric(metric: String) -> void:
	var idx := _invoke_metric_index(metric)
	_admin._invoke_metric_option.selected = idx
	_admin._invoke_metric_option.item_selected.emit(idx)


## 条件下拉里某个「量」的下标（找不到 → 0 =「（未选择）」）
func _invoke_metric_index(metric: String) -> int:
	for i in _admin._invoke_metric_option.item_count:
		if str(_admin._invoke_metric_option.get_item_metadata(i)) == metric:
			return i
	return 0


func _cleanup() -> void:
	for id in _created:
		_db.remove_card(id)


func _find_token_id() -> String:
	for c in _db.cards:
		if c.is_token:
			return c.id
	return ""


## 编辑器第 index 行的效果 ID
func _row_id(ed, index: int) -> String:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return ""
	var opt: OptionButton = st["id_option"]
	var ids: Array = st["ids"]
	var i: int = opt.selected
	return str(ids[i]) if i >= 0 and i < ids.size() else ""


func _row_value(ed, index: int) -> int:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return -1
	var spin: SpinBox = st["value_spin"]
	return int(spin.value)


func _row_target(ed, index: int) -> int:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return -1
	var opt: OptionButton = st["target_option"]
	return int(opt.selected)


func _row_token_visible(ed, index: int) -> bool:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return false
	var te: LineEdit = st["token_edit"]
	return te.visible


## 所有行的效果 ID（按行顺序，逗号分隔）
func _ids_of(ed) -> String:
	var out := PackedStringArray()
	for i in ed.row_count():
		out.append(_row_id(ed, i))
	return ",".join(out)


func _form_ids(admin) -> String:
	return _form_ids_of(admin._form_to_data().effects)


func _form_ids_of(chain: Variant) -> String:
	var out := PackedStringArray()
	if typeof(chain) != TYPE_ARRAY:
		return ""
	for e in (chain as Array):
		if typeof(e) == TYPE_DICTIONARY:
			out.append(str((e as Dictionary).get("id", "")))
	return ",".join(out)


## 链的「id:value:target:token」签名（逗号分隔的列表用 | 连接），用于断言顺序与内容
func _chain_sig(chain: Variant) -> String:
	var out := PackedStringArray()
	if typeof(chain) != TYPE_ARRAY:
		return ""
	for e in (chain as Array):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		out.append("%s:%d:%d:%s" % [str(d.get("id", "")), int(d.get("value", 0)),
			int(d.get("target", -1)), str(d.get("token", ""))])
	return "|".join(out)


## 设置第 index 行的数值 /（可选）目标（走控件信号，等价于用户操作）
func _set_row(ed, index: int, value: int, target: int = -1) -> void:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return
	var spin: SpinBox = st["value_spin"]
	spin.value = value
	if target >= 0:
		var opt: OptionButton = st["target_option"]
		opt.selected = target
		opt.item_selected.emit(target)


func _set_row_token(ed, index: int, token: String) -> void:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return
	var te: LineEdit = st["token_edit"]
	te.text = token
	te.text_changed.emit(token)


## 点第 index 行上的「↑ / ↓ / 删除」按钮（which = "up" / "down" / "remove"）
func _press_row_button(ed, index: int, which: String) -> void:
	var st: Dictionary = ed.row_state(index)
	if st.is_empty():
		return
	var button: Button = st[which]
	button.pressed.emit()


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if _admin != null and is_instance_valid(_admin):
		_admin.queue_free()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 效果链 / 技能界面测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
