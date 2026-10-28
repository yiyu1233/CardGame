extends SceneTree
## 机制系统 API / 扩展性测试：
##   ① 一致性自检 `Mechanics.audit()`：枚举 / 注册表 / 名称表 / key 表四方对齐，标志位名合法；
##   ② **声明式标志位**真的生效：一行 `_reg(..., [标志])` 就能改行为，不用改引擎；
##       （坚壁 = 只受 1 点伤害、迟钝 = 无法攻击、潜行 = 不能被敌方指定、免疫 = 不受伤害、
##         攻击不消耗次数 = 运行期注册一个临时机制来验证）
##   ③ 运行期注册 API（`Mechanics.register`）可用于测试 / 外挂模块；
##   ④ 写错标志位 / **钩子**名字时 audit 会报出来（挂了引擎不派发的钩子 = 静默失效）；
##   ⑤ 引擎真的会派发 on_turn_start / on_death（注册临时机制挂上这两个钩子，验证被调用）。
##
## 运行：godot --headless --path <项目目录> --script res://tools/mechanics_api_test.gd

const ME := 0
const FOE := 1
const TEMP_ID := 90                       ## 测试用的临时机制 ID（不写进 CardData 枚举）

var _fails := 0
var _frames := 0
var _gm
var _db
var _fail_lines: Array[String] = []
## 测试用钩子命中计数（回调改这个字典，验证「引擎真的派发了钩子」）
var _hook_hits: Dictionary = {}


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		if _gm == null or _db == null:
			_check(false, "GameManager / CardDB 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_test_registry_shape()
		_test_flag_stalwart()
		_test_flag_sluggish()
		_test_flag_stealth()
		_test_runtime_register()
		_test_audit_catches_typos()
		_test_hook_whitelist()
		_test_hooks_dispatched()
		_finish()
	return _frames > 300


# ------------------------------ ① 注册表形状 / 自检 ------------------------------

func _test_registry_shape() -> void:
	var report: Dictionary = Mechanics.audit()
	_check(report["ok"], "机制表一致性自检通过（%s）" % _report_text(report))
	_check(int(report["count"]) == CardData.all_keyword_ids().size(),
		"注册表覆盖全部关键字（%d / %d）" % [int(report["count"]), CardData.all_keyword_ids().size()])
	var no_name := true
	var no_desc := true
	for k in Mechanics.keywords():
		if Mechanics.display_name(k) == "":
			no_name = false
		if Mechanics.describe(k) == "":
			no_desc = false
	_check(no_name and no_desc, "每个机制都有中文名与说明（卡面 / 管理员面板直接用）")
	_check(Mechanics.summary(CardData.Keyword.TAUNT).contains("嘲讽"), "summary() 能给出「名称：说明」（%s）" % Mechanics.summary(CardData.Keyword.TAUNT))
	# 标志位常量都有说明（文档 / 自检输出）
	var flags_documented := true
	for f in [Mechanics.FLAG_CANNOT_ATTACK, Mechanics.FLAG_NO_ATTACK_COST, Mechanics.FLAG_UNTRACKABLE,
			Mechanics.FLAG_IMMUNE, Mechanics.FLAG_ONLY_ONE_DAMAGE]:
		if not Mechanics.FLAG_DESCS.has(f):
			flags_documented = false
	_check(flags_documented, "五个声明式标志位都有中文说明")
	_check(Mechanics.has_flag(CardData.Keyword.STALWART, Mechanics.FLAG_ONLY_ONE_DAMAGE),
		"坚壁声明了 only_one_damage 标志")
	_check(Mechanics.has_flag(CardData.Keyword.SLUGGISH, Mechanics.FLAG_CANNOT_ATTACK),
		"迟钝声明了 cannot_attack 标志")
	# 钩子白名单：注册表里挂的钩子必须都在「引擎真的会派发」的清单里
	_check((report.get("bad_hooks", []) as Array).is_empty(),
		"没有「挂了但引擎不会派发」的钩子（%s）" % str(report.get("bad_hooks", [])))
	_check(Mechanics.DISPATCHED_HOOKS.has("on_attack") and Mechanics.DISPATCHED_HOOKS.has("on_death")
		and Mechanics.DISPATCHED_HOOKS.has("on_turn_start"),
		"钩子白名单收录了 on_attack / on_death / on_turn_start（%d 个）" % Mechanics.DISPATCHED_HOOKS.size())


func _report_text(report: Dictionary) -> String:
	if report["ok"]:
		return "%d 个机制，无缺失" % int(report["count"])
	return "missing=%s unnamed=%s unkeyed=%s bad_flags=%s" % [
		str(report["missing"]), str(report["unnamed"]), str(report["unkeyed"]), str(report["unknown_flags"])]


# ------------------------------ ② 声明式标志位 ------------------------------

func _test_flag_stalwart() -> void:
	_prepare()
	var golem: BoardUnit = _spawn(ME, "f010")            # 石壁巨像：坚壁（8 血）
	_check(golem.has_mechanic(CardData.Keyword.STALWART), "石壁巨像带坚壁")
	var dealt: int = _gm.deal_damage_to_unit(null, golem, 9)
	_check(dealt == 1 and golem.health == 7, "坚壁：9 点伤害减为 1（实际 %d，剩 %d）" % [dealt, golem.health])
	# 群体伤害同样只吃 1 点
	var ctx := EffectContext.create(_gm, FOE, 4, "", {"kind": "self", "unit_id": -1, "player_id": FOE}, "测试")
	CardEffects.apply("aoe_all", ctx)
	_check(golem.health == 6, "坚壁对群体伤害同样只受 1 点（剩 %d）" % golem.health)
	# 1 点伤害不会被放大 / 缩小
	_gm.deal_damage_to_unit(null, golem, 1)
	_check(golem.health == 5, "坚壁不影响 1 点伤害（剩 %d）" % golem.health)


func _test_flag_sluggish() -> void:
	_prepare()
	var statue: BoardUnit = _spawn(ME, "f011")           # 沉眠石像：迟钝（6/6）
	_check(statue.has_mechanic(CardData.Keyword.SLUGGISH), "沉眠石像带迟钝")
	_check(not statue.can_attack(_gm.turn_count, true), "迟钝：无法攻击")
	_check(not statue.can_attack(_gm.turn_count, false), "迟钝：连英雄也打不了")
	var targets: Array[Dictionary] = _gm.get_valid_attack_targets(ME, statue.unit_id)
	_check(targets.is_empty(), "迟钝随从的可攻击目标列表为空（%d）" % targets.size())
	_check(not _gm.attack(ME, statue.unit_id, -1, FOE), "迟钝随从发起攻击会被拒绝")
	# 对照：同样身材但没带迟钝的随从可以攻击
	var normal: BoardUnit = _spawn(ME, "f010")
	normal.summoned_turn = -1
	normal.attacks_used = 0
	_check(normal.can_attack(_gm.turn_count, true), "对照：不带迟钝的随从可以攻击")


func _test_flag_stealth() -> void:
	_prepare()
	var sneaky: BoardUnit = _spawn(FOE, "c001")
	sneaky.keywords.append(CardData.Keyword.STEALTH)   # 直接赋予潜行，不依赖具体卡
	_check(sneaky.has_mechanic(CardData.Keyword.STEALTH), "潜行随从带潜行")
	_check(not Mechanics.can_be_targeted(sneaky, ME), "潜行由 untargetable_by_foe 标志位挡住敌方指定")
	_check(Mechanics.can_be_targeted(sneaky, FOE), "自己人仍可以指定它")
	# 攻击后解除（钩子与标志位并存）
	var attacker: BoardUnit = _spawn(ME, "c001")
	attacker.summoned_turn = -1
	attacker.attacks_used = 0
	Mechanics.dispatch(sneaky, "on_attack", {"gm": _gm, "source": sneaky})
	_check(not sneaky.has_mechanic(CardData.Keyword.STEALTH), "潜行随从攻击后解除关键字")
	_check(Mechanics.can_be_targeted(sneaky, ME), "解除后可以被指定")


func _test_runtime_register() -> void:
	# 运行期注册一个「攻击不消耗次数」的临时机制，验证标志位真的被引擎读取
	Mechanics.register(TEMP_ID, "测试·不耗次数", "测试用：攻击不消耗本回合次数。", {},
		[Mechanics.FLAG_NO_ATTACK_COST])
	_prepare()
	var unit: BoardUnit = _spawn(ME, "c001")
	unit.keywords.append(TEMP_ID)
	unit.summoned_turn = -1
	unit.attacks_used = 0
	var victim: BoardUnit = _spawn(FOE, "c001")   # 非嘲讽，否则打脸会被嘲讽拦住
	_check(_gm.attack(ME, unit.unit_id, -1, FOE), "带临时机制的随从可以攻击")
	_check(unit.attacks_used == 0, "标志位生效：攻击不消耗次数（used=%d）" % unit.attacks_used)
	_check(unit.can_attack(_gm.turn_count, true), "因此还能继续攻击")
	# 对照
	var plain: BoardUnit = _spawn(ME, "c001")
	plain.summoned_turn = -1
	plain.attacks_used = 0
	_gm.attack(ME, plain.unit_id, -1, FOE)
	_check(plain.attacks_used == 1, "对照：普通随从攻击后次数 +1（%d）" % plain.attacks_used)
	# 免疫标志位
	Mechanics.register(TEMP_ID + 1, "测试·免疫", "测试用：免疫所有伤害。", {}, [Mechanics.FLAG_IMMUNE])
	_prepare()
	var warded: BoardUnit = _spawn(ME, "c001")
	warded.keywords.append(TEMP_ID + 1)
	var hp: int = warded.health
	var dealt: int = _gm.deal_damage_to_unit(null, warded, 5)
	_check(dealt == 0 and warded.health == hp, "免疫标志位生效：不受伤害（%d -> %d）" % [hp, warded.health])
	_check(Mechanics.has_flag(TEMP_ID, Mechanics.FLAG_NO_ATTACK_COST), "运行期注册的机制进了注册表")
	# clone() 必须按 ID 原样复制关键字：否则运行期赋予的（未登记名字的）关键字会丢
	var src_card: CardData = _db.get_card("c001").clone()
	src_card.keywords.append(TEMP_ID)
	var copied: CardData = src_card.clone()
	_check(copied.keywords.has(TEMP_ID), "clone() 保留运行期赋予的关键字（按 ID 复制，不走名字往返）")


func _test_audit_catches_typos() -> void:
	# 故意注册一个标志位名字写错的机制，audit 必须报出来（否则就是静默失效）
	Mechanics.register(TEMP_ID + 2, "测试·写错标志", "测试用：标志位名字拼错。", {}, ["only_one_damag"])
	var report: Dictionary = Mechanics.audit()
	_check(not report["ok"], "标志位写错时 audit 会报错（不会静默失效）")
	_check(not (report["unknown_flags"] as Array).is_empty(),
		"报出非法标志位：%s" % str(report["unknown_flags"]))
	# 清理：把测试机制摘掉，让后续套件看到的仍是干净的表
	for k in [TEMP_ID + 2, TEMP_ID + 1, TEMP_ID]:
		Mechanics.register(k, Mechanics.display_name(k), Mechanics.describe(k), {}, [])
	_check(Mechanics.audit()["ok"], "清理非法标志位后 audit 恢复通过")


func _test_hook_whitelist() -> void:
	# 故意注册一个钩子名字写错的机制：挂上去也不会被派发（= 静默失效），audit 必须报出来
	Mechanics.register(TEMP_ID + 5, "测试·写错钩子", "测试用：钩子名字拼错。",
		{"on_atack": Callable(self, "_on_test_turn_start")})
	var report: Dictionary = Mechanics.audit()
	_check(not report["ok"], "钩子名字写错时 audit 会报错（不会静默失效）")
	var bad: Array = report.get("bad_hooks", [])
	_check(not bad.is_empty(), "报出「引擎不会派发的钩子」：%s" % str(bad))
	# 清理
	Mechanics.register(TEMP_ID + 5, "测试·写错钩子", "测试用。", {}, [])
	_check(Mechanics.audit()["ok"], "清理非法钩子后 audit 恢复通过")


func _test_hooks_dispatched() -> void:
	# 引擎真的会派发 on_turn_start / on_death：注册临时机制挂上它们，看回合开始 / 死亡时是否被调用
	Mechanics.register(TEMP_ID + 3, "测试·回合开始钩子", "测试用。",
		{"on_turn_start": Callable(self, "_on_test_turn_start")})
	Mechanics.register(TEMP_ID + 4, "测试·死亡钩子", "测试用。",
		{"on_death": Callable(self, "_on_test_death")})
	_check(Mechanics.audit()["ok"], "这两个测试机制的钩子都在白名单里（audit 干净）")

	# on_turn_start：回合开始流程里派发给己方场上的单位
	_prepare()
	var starter: BoardUnit = _spawn(ME, "c001")
	starter.keywords.append(TEMP_ID + 3)
	_hook_hits.clear()
	_gm._start_turn(ME)
	_check(int(_hook_hits.get("turn_start", 0)) >= 1,
		"on_turn_start 被引擎派发（命中 %d）" % int(_hook_hits.get("turn_start", 0)))

	# on_death：死亡结算里派发
	_prepare()
	var doomed: BoardUnit = _spawn(ME, "c001")
	doomed.keywords.append(TEMP_ID + 4)
	_hook_hits.clear()
	doomed.health = 0
	_gm._cleanup_deaths()
	_check(int(_hook_hits.get("death", 0)) >= 1,
		"on_death 被引擎派发（命中 %d）" % int(_hook_hits.get("death", 0)))

	# 清理：摘掉钩子，让后续套件看到干净的表
	for k in [TEMP_ID + 3, TEMP_ID + 4]:
		Mechanics.register(k, Mechanics.display_name(k), Mechanics.describe(k), {}, [])
	_check(Mechanics.audit()["ok"], "清理钩子后 audit 仍通过")


func _on_test_turn_start(_ev: Dictionary) -> void:
	_hook_hits["turn_start"] = int(_hook_hits.get("turn_start", 0)) + 1


func _on_test_death(_ev: Dictionary) -> void:
	_hook_hits["death"] = int(_hook_hits.get("death", 0)) + 1


# ------------------------------ 辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		p.max_mana = 10
		p.mana = 10
		p.board.clear()
		p.hand.clear()
	_gm.current_player = ME
	_gm.busy = false


func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 90000 + randi() % 9000)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


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
	print("=== 机制系统 API 测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
