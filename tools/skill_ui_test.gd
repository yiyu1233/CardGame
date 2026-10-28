extends SceneTree
## 战斗内「技能发动界面」测试：点击自己场上有技能的单位 → 消耗能量点（= 法力 / PP）发动主动技能。
##
## 运行方式（**必须带窗口**：右键取消用的是真实合成鼠标事件）：
##   godot --path <项目目录> --script res://tools/skill_ui_test.gd
##
## 覆盖：
##   ① 枚举值：IDLE=0 / CARD_TARGET=1 / ATTACK_TARGET=2 不变，SKILL_TARGET 追加在末尾；
##   ② 无技能的单位点击 → 仍是原来的攻击选目标流程（mode == ATTACK_TARGET）；
##   ③ 有技能且**需要目标** → 进入 SKILL_TARGET、目标列表非空、提示里有技能名与费用、
##      箭头起点在发动者身上且类别为 spell、手牌进入放大态；
##   ④ 点一个合法目标 → 技能真的发动（能量点减少 = 技能费用、目标掉血 / 被消灭）、mode 回到 IDLE；
##   ⑤ once_per_turn：同回合再点该单位 → 不再进入 SKILL_TARGET（回落攻击流程）并给出原因；
##   ⑥ 能量点不足 → 不发动、法力不变、提示给出 skill_blocked_reason；
##   ⑦ 无目标技能（target = NONE）→ 点一下立刻发动、法力减少；
##   ⑧ UnitUI 角标：has_skill_badge() 为真、用过之后 skill_ready() 为假（没有技能的单位没有角标）。
##
## 说明：
##   1. 技能卡用 `CardData.from_dict({... "skill": {...}})` **自造**，不依赖卡表里恰好有技能卡；
##   2. 规则层（GameManager.can_use_skill / request_use_skill / …、CardData.has_skill / …、
##      BoardUnit.skill_used_turn）由另一路并行实现：本测试先探活，接口没落地时只跑「界面兜底」
##      用例并打印 [SKIP]（退出码仍为 0），**不会**假装通过；
##   3. 只从界面下手（`_on_unit_clicked` / 真实右键事件），断言看模式、能量点、目标血量、
##      操作栏提示与卡面角标。

## 注意：**不能** `preload("res://scripts/Main.gd")`——那会让 Main.gd 成为编译期依赖，
## 而 Main 里引用了自动加载单例（GameSettings 等），`--script` 模式下编译期拿不到这些全局名字，
## 会直接编译失败（踩过）。所以这里在运行时 load，只用于读 `Mode` 枚举值。
var MainScript = null

var _fails := 0
var _frames := 0
var _gm
var _main
var _fail_lines: Array[String] = []

var _steps: Array[Callable] = []
var _step := 0
var _wait := 0
## 场面与步骤表准备好之前不驱动用例（否则第 3 帧就会因为步骤表为空而结束）
var _prepared := false
var _skip_lines: Array[String] = []

var _uid := 5000
var _me: PlayerState
var _foe: PlayerState

## 自造的测试卡（不依赖卡表）
var _plain_card: CardData      ## 普通随从：没有技能
var _probe_card: CardData      ## 带 skill 字典的随从（规则层没落地时用来验证兜底）
var _dummy_card: CardData      ## 敌方训练假人：0 攻 / 20 血，只为当靶子
var _skill_target_card: CardData   ## 技能需要目标（敌方随从）
var _skill_none_card: CardData     ## 技能不需要目标
var _skill_costly_card: CardData   ## 技能很贵（用来测能量点不足）
var _skill_name := "火球"
var _cost_target := 2
var _cost_none := 1
var _cost_costly := 3

## 每个用例自己的场面目
var _caster: BoardUnit
var _enemy_a: BoardUnit
var _enemy_b: BoardUnit


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if DisplayServer.get_name() == "headless":
			print("[SKIP] 无头模式无法投递 GUI 事件（右键取消用例需要真实鼠标事件），请去掉 --headless 运行。")
			quit(0)
			return true
		_gm = root.get_node_or_null("GameManager")
		if _gm == null:
			_check(false, "GameManager 自动加载")
			_finish()
			return true
		MainScript = load("res://scripts/Main.gd")
		if MainScript == null:
			_check(false, "Main.gd 可加载")
			_finish()
			return true
		print("--- 技能界面测试（窗口模式，画布 %s）---" % str(root.get_visible_rect().size))
		return false
	if _frames == 2:
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _frames == 5:
		_main.position = Vector2.ZERO
		_main.size = Vector2(root.get_visible_rect().size)
		return false
	if _frames == 8:
		_make_cards()
		_prepare_steps()
		_prepared = true
		return false
	# 建场面之前不要跑用例驱动（否则第 3 帧就会因为「步骤表还是空的」直接结束）
	if not _prepared:
		return false
	if _frames > 900:
		_check(false, "测试超时")
		_finish()
		return true
	if _step >= _steps.size():
		_finish()
		return true
	# 每个步骤之间空一帧：`_request_refresh()` 是每帧合并一次的，界面要等下一帧才跟上
	if _wait > 0:
		_wait -= 1
		return false
	var next: Callable = _steps[_step]
	_step += 1
	next.call()
	_wait = 1
	return false


# ------------------------------ 用例编排 ------------------------------

func _prepare_steps() -> void:
	# ① 枚举值（永远可跑）
	_steps.append(_step_enum_values)
	# ② 界面兜底：没有技能的单位点击 → 攻击流程（规则层没落地也必须成立）
	_steps.append(_step_plain_unit_fallback.bind("普通随从", _plain_card))
	var missing := _missing_skill_api()
	if not missing.is_empty():
		for m in missing:
			_skip_lines.append("缺少 " + m)
		# 规则层没落地：再验证一次「卡上有 skill 字段但接口缺失」时界面不崩、回落攻击
		_steps.append(_step_plain_unit_fallback.bind("带 skill 字段但接口缺失", _probe_card))
		return
	# 注意：容器要等一帧才会排布新建的随从控件，所以「几何类」断言都要先经过一个
	# 只做 `_refresh()` 的空步骤（`_step_refresh_only`），下一帧再量尺寸与坐标。
	_steps.append(_step_skill_enter_target)
	_steps.append(_step_refresh_only)
	_steps.append(_step_skill_target_geometry)
	_steps.append(_step_skill_fire_at_target)
	_steps.append(_step_skill_once_per_turn)
	_steps.append(_step_skill_not_enough_mana)
	_steps.append(_step_skill_no_target)
	_steps.append(_step_badge_fresh)
	_steps.append(_step_refresh_only)
	_steps.append(_step_badge_overflow)
	_steps.append(_step_badge_after_use)
	_steps.append(_step_cancel_setup)
	_steps.append(_step_refresh_only)
	_steps.append(_step_cancel_right_click)


## 规则层（并行开发）接口探活：缺哪一项就报哪一项
func _missing_skill_api() -> Array[String]:
	var miss: Array[String] = []
	for m in ["can_use_skill", "skill_blocked_reason", "get_valid_skill_targets", "use_skill", "request_use_skill"]:
		if not _gm.has_method(m):
			miss.append("GameManager." + m)
	var probe := _make_card({
		"id": "t_probe", "card_name": "探针", "card_type": 0, "cost": 1, "attack": 1, "health": 1,
		"skill": _skill_dict("探针技能", 1, CardData.Targeting.ENEMY_MINION),
	})
	for m in ["has_skill", "skill_name", "skill_cost", "skill_target", "skill_once_per_turn"]:
		if not probe.has_method(m):
			miss.append("CardData." + m)
	if probe.has_method("has_skill") and not bool(probe.call("has_skill")):
		miss.append("CardData.from_dict 没有解析 skill 字段（has_skill() == false）")
	var bu := BoardUnit.new()
	if bu.get("skill_used_turn") == null:
		miss.append("BoardUnit.skill_used_turn")
	return miss


func _step_enum_values() -> void:
	_check(MainScript.Mode.IDLE == 0, "Mode.IDLE 仍是 0（既有测试写死了这个值）")
	_check(MainScript.Mode.CARD_TARGET == 1, "Mode.CARD_TARGET 仍是 1")
	_check(MainScript.Mode.ATTACK_TARGET == 2, "Mode.ATTACK_TARGET 仍是 2")
	_check(MainScript.Mode.SKILL_TARGET == 3, "SKILL_TARGET 追加在枚举末尾（= 3，没有打乱既有值）")


## ① 没有技能的单位：点击后照旧进入攻击选目标流程
func _step_plain_unit_fallback(tag: String, card: CardData) -> void:
	_reset_battle(10)
	_caster = _place(0, card, 0)
	_enemy_a = _place(1, _dummy_card, 0)
	_main._refresh()
	_main._on_unit_clicked(_caster.unit_id)
	_check(_main.mode == MainScript.Mode.ATTACK_TARGET,
		"%s：点击后仍是攻击选目标流程（mode=%d）" % [tag, _main.mode])
	_check(not _main.targets.is_empty(), "%s：攻击目标列表非空" % tag)
	_check(_main.pending_unit == _caster.unit_id, "%s：pending_unit = 被点的那个单位" % tag)
	_main._clear_mode()


## ② 有技能且需要目标：进入 SKILL_TARGET（状态与提示这一帧就能断言）
func _step_skill_enter_target() -> void:
	_reset_battle(5)
	_caster = _place(0, _skill_target_card, 0)
	_enemy_a = _place(1, _dummy_card, 0)
	_enemy_b = _place(1, _dummy_card, 1)
	_main._refresh()
	_main._on_unit_clicked(_caster.unit_id)
	_check(_main.mode == MainScript.Mode.SKILL_TARGET,
		"有技能且需要目标：进入 SKILL_TARGET（mode=%d）" % _main.mode)
	_check(_main.pending_unit == _caster.unit_id, "pending_unit = 发动技能的那个单位")
	_check(_main.targets.size() > 0, "技能目标列表非空（%d 个）" % _main.targets.size())
	var hint: String = _main.hint_label.text
	_check(hint.contains(_skill_name), "操作栏提示里有技能名（%s）" % hint)
	_check(hint.contains(str(_cost_target)), "操作栏提示里有能量点费用（%s）" % hint)
	_check(hint.contains("右键取消"), "操作栏提示里说了可以右键取消（%s）" % hint)


## 空步骤：只重建一次界面（容器要下一帧才会把新控件排布好），供后面的几何断言用
func _step_refresh_only() -> void:
	_main._refresh()


## ③ 等一帧后量几何：箭头起点在发动者身上、类别 spell；手牌进入放大态
func _step_skill_target_geometry() -> void:
	_main._update_target_arrow()
	var arrow = _main.target_arrow()
	_check(_main.target_arrow_active(), "选技能目标时出现指向箭头")
	if arrow != null:
		_check(arrow.kind == "spell", "技能箭头类别 = spell（%s）" % arrow.kind)
		var from_center: Vector2 = _main._unit_center(_caster.unit_id)
		_check(from_center != Vector2.ZERO,
			"发动技能的随从控件已排布（中心 %s）" % str(from_center))
		_check(arrow.from_point.distance_to(from_center) < 1.0,
			"箭头起点就在发动技能的随从上")
	_check(not _main.hand_resting(), "选技能目标时手牌进入放大态（选牌中）")


## ④ 点一个合法目标：技能真的发动
func _step_skill_fire_at_target() -> void:
	var mana_before: int = _me.mana
	var hp_before: int = _enemy_a.health
	_main._on_unit_clicked(_enemy_a.unit_id)
	_check(_main.mode == MainScript.Mode.IDLE, "点合法目标后回到 IDLE（mode=%d）" % _main.mode)
	_check(_main.targets.is_empty() and _main.pending_unit == -1, "发动后选目标状态清干净")
	_check(_me.mana == mana_before - _cost_target,
		"能量点消耗 = 技能费用（%d → %d，期望 -%d）" % [mana_before, _me.mana, _cost_target])
	var hurt: bool = _enemy_a.health < hp_before or not _enemy_a.is_alive() or _gm.find_unit(_enemy_a.unit_id) == null
	_check(hurt, "技能真的结算到目标身上（血量 %d → %d）" % [hp_before, _enemy_a.health])
	_check(_main._log_text.contains("发动技能"), "战斗日志里有「发动技能」回执")
	_check(_main.hint_label.text.contains("发动技能"), "操作栏也给出「发动技能」回执（%s）" % _main.hint_label.text)
	_check(not _main.target_arrow_active(), "发动技能后箭头收起")


## ⑤ once_per_turn：同回合再点该单位 → 不再进入 SKILL_TARGET（回落攻击），并给出原因
func _step_skill_once_per_turn() -> void:
	var reason: String = str(_gm.call("skill_blocked_reason", 0, _caster.unit_id))
	_check(reason != "", "本回合已发动过 → 规则层给出原因（%s）" % reason)
	_main._on_unit_clicked(_caster.unit_id)
	_check(_main.mode != MainScript.Mode.SKILL_TARGET,
		"同回合再点该单位 → 不再进入 SKILL_TARGET（mode=%d）" % _main.mode)
	_check(_main.mode == MainScript.Mode.ATTACK_TARGET,
		"技能用过之后回落到攻击选目标流程（mode=%d，场上还有敌方目标）" % _main.mode)
	var seen: bool = _main._log_text.contains(reason) or _main.hint_label.text.contains(reason)
	_check(seen, "提示 / 日志给出「本回合已发动」类原因（%s）" % reason)
	_main._clear_mode()


## ⑥ 能量点不足：不发动、法力不变、提示给出原因
func _step_skill_not_enough_mana() -> void:
	_reset_battle(1)
	_caster = _place(0, _skill_costly_card, 0)
	_caster.summoned_turn = _gm.turn_count     # 本回合刚上场：连攻击也做不了
	_main._refresh()
	var mana_before: int = _me.mana
	_main._on_unit_clicked(_caster.unit_id)
	_check(_main.mode == MainScript.Mode.IDLE, "能量点不足 → 不进入选目标状态（mode=%d）" % _main.mode)
	_check(_me.mana == mana_before, "能量点不足 → 技能没有发动，法力不变（%d）" % _me.mana)
	var reason: String = str(_gm.call("skill_blocked_reason", 0, _caster.unit_id))
	_check(reason != "", "规则层给出「能量点不足」类原因（%s）" % reason)
	_check(_main.hint_label.text.contains(reason) or _main._log_text.contains(reason),
		"操作栏 / 日志给出技能无法发动的原因（%s / %s）" % [_main.hint_label.text, reason])


## ⑦ 无目标技能（target = NONE）：点一下立刻发动
func _step_skill_no_target() -> void:
	_reset_battle(5)
	_caster = _place(0, _skill_none_card, 0)
	_main._refresh()
	var mana_before: int = _me.mana
	_main._on_unit_clicked(_caster.unit_id)
	_check(_main.mode == MainScript.Mode.IDLE, "无目标技能不进入选目标状态（mode=%d）" % _main.mode)
	_check(_me.mana == mana_before - _cost_none,
		"无目标技能点一下立刻发动（能量 %d → %d，期望 -%d）" % [mana_before, _me.mana, _cost_none])
	_check(_main._log_text.contains("发动技能") or _main.hint_label.text.contains("发动技能"),
		"无目标技能发动后也有回执（%s）" % _main.hint_label.text)


## ⑧ 卡面角标：有技能才显示；本回合没发动过 → 亮
func _step_badge_fresh() -> void:
	_reset_battle(5)
	_caster = _place(0, _skill_target_card, 0)
	var plain: BoardUnit = _place(0, _plain_card, 1)
	_main._refresh()
	var ui: UnitUI = _main._find_unit_ui(_caster.unit_id)
	_check(ui != null, "带技能的随从有对应控件")
	if ui != null:
		_check(ui.has_skill_badge(), "带技能的随从卡面上有「技能」角标")
		_check(ui.skill_ready(), "本回合还没发动 → skill_ready() 为真")
		_check(_has_label_prefix(ui, "技能"), "角标上写着「技能」")
		# 角标还要写出这一次要花多少 PP（用户要求技能花费可指定）
		_check(_has_label_prefix(ui, "技能 %dPP" % _cost_target),
			"角标写出了 PP 花费（技能 %dPP）" % _cost_target)
	var pui: UnitUI = _main._find_unit_ui(plain.unit_id)
	_check(pui != null and not pui.has_skill_badge(), "没有技能的单位不显示角标")
	_check(pui != null and not pui.skill_ready(), "没有技能的单位 skill_ready() 为假")


## ⑨ 角标不能把卡面撑宽（布局测试锁着 UNIT_SIZE）——等一帧量尺寸
func _step_badge_overflow() -> void:
	var ui: UnitUI = _main._find_unit_ui(_caster.unit_id)
	var cell: Control = _main.unit_cell(0, _caster.unit_id)
	_check(ui != null and cell != null, "角标用例：随从控件与格子都在")
	if ui != null and cell != null:
		_check(ui.size.x <= cell.size.x + 0.5,
			"角标没有把卡面撑宽（卡面 %.0f ≤ 格子 %.0f）" % [ui.size.x, cell.size.x])


## ⑩ 发动技能之后：角标还在，但变暗（skill_ready() 为假）
func _step_badge_after_use() -> void:
	_enemy_a = _place(1, _dummy_card, 0)
	_main._refresh()
	_main._on_unit_clicked(_caster.unit_id)
	_check(_main.mode == MainScript.Mode.SKILL_TARGET, "先进入技能选目标状态（mode=%d）" % _main.mode)
	_main._on_unit_clicked(_enemy_a.unit_id)
	_main._refresh()
	var ui: UnitUI = _main._find_unit_ui(_caster.unit_id)
	_check(ui != null, "发动技能后控件仍然可用")
	if ui != null:
		_check(ui.has_skill_badge(), "发动后角标还在（只是变暗）")
		_check(not ui.skill_ready(), "本回合已发动 → skill_ready() 为假")


## ⑪ 右键取消：先进入 SKILL_TARGET（下一帧再投递真实右键事件）
func _step_cancel_setup() -> void:
	_reset_battle(5)
	_caster = _place(0, _skill_target_card, 0)
	_enemy_a = _place(1, _dummy_card, 0)
	_main._refresh()
	_main._on_unit_clicked(_caster.unit_id)
	_main._update_target_arrow()
	_check(_main.mode == MainScript.Mode.SKILL_TARGET and _main.target_arrow_active(),
		"再次进入 SKILL_TARGET 并显示箭头（mode=%d）" % _main.mode)


## ⑫ 右键点在这张随从上 → 取消选目标状态、清空目标、收起箭头
func _step_cancel_right_click() -> void:
	var ui: UnitUI = _main._find_unit_ui(_caster.unit_id)
	if ui == null or ui.get_global_rect().size.x < 10.0:
		_check(false, "右键取消用例：随从控件已排布（%s）" % ("无控件" if ui == null else str(ui.get_global_rect())))
		return
	_press_release(ui.get_global_rect().get_center(), MOUSE_BUTTON_RIGHT)
	_check(_main.mode == MainScript.Mode.IDLE, "右键取消 → 回到 IDLE（mode=%d）" % _main.mode)
	_check(_main.targets.is_empty(), "右键取消 → 目标列表清空")
	_check(_main.pending_unit == -1, "右键取消 → pending_unit 清干净")
	_check(not _main.target_arrow_active(), "右键取消 → 箭头已隐藏")


# ------------------------------ 场面与测试卡 ------------------------------

## 开一局干净的：我方回合、指定能量点、双方战场清空
func _reset_battle(mana: int) -> void:
	_gm.new_game()
	_main.skip_mulligan()
	_gm.current_player = 0            # 我方（PLAYER_ID）
	_gm.busy = false
	_me = _gm.get_player(0)
	_foe = _gm.get_player(1)
	_me.mana = mana
	_me.max_mana = maxi(mana, 10)
	_uid = 5000
	_caster = null
	_enemy_a = null
	_enemy_b = null
	_main._clear_mode()
	_main._refresh()


## 直接摆一个单位到指定格子（不走 summon_unit，避免卡牌在 clone / to_dict 往返里丢掉技能配置）
func _place(pid: int, card: CardData, slot: int) -> BoardUnit:
	_uid += 1
	var u := BoardUnit.new()
	u.setup(card, pid, _gm.turn_count, _uid)
	u.summoned_turn = -1              # 视为已上场一回合：能攻击（才测得到「技能不可用 → 回落攻击」）
	var p: PlayerState = _gm.get_player(pid)
	if not p.place_unit_at(u, slot):
		p.board.append(u)             # 兜底：格子被占了也别让用例悄悄测了个空场
		p.sync_slots()
	return u


func _make_cards() -> void:
	_plain_card = _make_card({
		"id": "t_skill_plain", "card_name": "普通随从", "card_type": 0, "cost": 1, "attack": 2, "health": 3,
	})
	_probe_card = _make_card({
		"id": "t_skill_probe", "card_name": "半落地技能者", "card_type": 0, "cost": 1, "attack": 2, "health": 3,
		"skill": _skill_dict("探针火球", 2, CardData.Targeting.ENEMY_MINION),
	})
	_dummy_card = _make_card({
		"id": "t_skill_dummy", "card_name": "训练假人", "card_type": 0, "cost": 1, "attack": 0, "health": 20,
	})
	_skill_target_card = _make_card({
		"id": "t_skill_target", "card_name": "技能测试者", "card_type": 0, "cost": 1, "attack": 2, "health": 3,
		"skill": _skill_dict(_skill_name, _cost_target, CardData.Targeting.ENEMY_MINION),
	})
	_skill_none_card = _make_card({
		"id": "t_skill_none", "card_name": "无目标技能者", "card_type": 0, "cost": 1, "attack": 1, "health": 3,
		"skill": _skill_dict("奥术智慧", _cost_none, CardData.Targeting.NONE),
	})
	_skill_costly_card = _make_card({
		"id": "t_skill_costly", "card_name": "昂贵技能者", "card_type": 0, "cost": 1, "attack": 2, "health": 3,
		"skill": _skill_dict("陨石术", _cost_costly, CardData.Targeting.ENEMY_MINION),
	})


func _make_card(d: Dictionary) -> CardData:
	return CardData.from_dict(d)


## 技能配置（与管理员面板 / 需求里给的结构一致：name / cost / target / once_per_turn / effects）
func _skill_dict(sname: String, cost: int, target: int) -> Dictionary:
	return {
		"name": sname,
		"cost": cost,
		"target": target,
		"once_per_turn": true,
		"effects": [{"id": "damage", "value": 3, "target": target, "token": ""}],
	}


# ------------------------------ 辅助 ------------------------------

## 控件子树里有没有写着这段文字的 Label（角标文案断言用）
func _has_label_text(node: Node, text: String) -> bool:
	for child in node.get_children():
		if child is Label and (child as Label).text == text:
			return true
		if _has_label_text(child, text):
			return true
	return false


## 角标文字以「技能」开头（形如「技能 2PP」/「技能 免费」）
func _has_label_prefix(node: Node, prefix: String) -> bool:
	for child in node.get_children():
		if child is Label and (child as Label).text.begins_with(prefix):
			return true
		if _has_label_prefix(child, prefix):
			return true
	return false


func _press_release(point: Vector2, button: int) -> void:
	_mouse_motion(point)
	_mouse_button(point, true, button)
	_mouse_button(point, false, button)


## 第二个参数 true = 事件坐标是视口局部坐标（与 get_global_rect 同一坐标系）
func _mouse_button(pos: Vector2, pressed: bool, button: int) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	root.push_input(ev, true)


func _mouse_motion(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = Vector2.ZERO
	root.push_input(ev, true)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	if not _skip_lines.is_empty():
		print("--- 规则层技能 API 未落地，以下用例被跳过（不是通过！）---")
		for s in _skip_lines:
			print("[SKIP] " + s)
		print("=== 技能界面测试结束：兜底用例失败 %d 项；技能用例未跑 ===" % _fails)
		quit(1 if _fails > 0 else 0)
		return
	print("=== 技能界面测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
