extends SceneTree
## 本轮新增的两项机制测试：
##   ① 法术伤害 +N（炉石）：我方场上的法伤随从让**法术**的伤害性效果加成，可叠加；
##   ② 发现（三选一，炉石 / 影之诗）：效果挂起候选 → 界面三选一 → 选中的牌进手牌。
##
## 运行：godot --headless --path <项目目录> --script res://tools/mechanics4_test.gd

const ME := 0
const FOE := 1

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
var _fail_lines: Array[String] = []


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
		_test_spell_damage()
		_test_discover_rules()
		return false
	if _frames == 4:
		_test_discover_ui()
		_finish()
		return true
	return _frames > 300


# ------------------------------ ① 法术伤害 +N ------------------------------

func _test_spell_damage() -> void:
	# 基线：没有法伤随从时，火焰冲击 3 点就是 3 点
	_prepare()
	var victim: BoardUnit = _spawn(FOE, "c011")            # 8/8
	var dealt: int = _cast_spell("s001", victim.unit_id, FOE)
	_check(dealt == 3, "没有法伤随从时，3 点法术就打 3 点（实际 %d）" % dealt)

	# 一张法伤 +1
	_prepare()
	victim = _spawn(FOE, "c011")
	_spawn(ME, "f008")                                     # 秘法学徒：法术伤害 +1
	_check(_gm.spell_damage_bonus(ME) == 1, "法伤加成合计为 1（%d）" % _gm.spell_damage_bonus(ME))
	dealt = _cast_spell("s001", victim.unit_id, FOE)
	_check(dealt == 4, "法术伤害 +1 后打 4 点（实际 %d）" % dealt)

	# 两张叠加（+1 与 +2）
	_prepare()
	victim = _spawn(FOE, "c011")
	_spawn(ME, "f008")
	_spawn(ME, "f009")                                     # 大法师：法术伤害 +2
	_check(_gm.spell_damage_bonus(ME) == 3, "两张法伤随从叠加为 3（%d）" % _gm.spell_damage_bonus(ME))
	dealt = _cast_spell("s001", victim.unit_id, FOE)
	_check(dealt == 6, "叠加后打 6 点（实际 %d）" % dealt)

	# 打脸同样加成
	_prepare()
	_spawn(ME, "f008")
	var foe_hp: int = _gm.get_player(FOE).hero_hp
	_cast_spell("s005", -1, FOE)                           # 雷霆一击：任意角色 8 点
	_check(_gm.get_player(FOE).hero_hp == foe_hp - 9,
		"打脸也吃法伤加成（%d -> %d，期望 -9）" % [foe_hp, _gm.get_player(FOE).hero_hp])

	# 只影响伤害效果：消灭类法术不受影响
	_prepare()
	var doomed: BoardUnit = _spawn(FOE, "c011")
	_spawn(ME, "f008")
	_cast_spell("s009", doomed.unit_id, FOE)               # 湮灭：消灭一个敌方随从
	_gm._cleanup_deaths()
	_check(not _gm.get_player(FOE).board.has(doomed), "消灭类法术照常消灭目标（法伤不影响）")

	# 对手的法伤不会帮到我
	_prepare()
	victim = _spawn(FOE, "c011")
	_spawn(FOE, "f008")                                    # 法伤随从在对手场上
	dealt = _cast_spell("s001", victim.unit_id, FOE)
	_check(dealt == 3, "对手的法伤随从不给我的法术加成（实际 %d）" % dealt)

	# 随从的战吼伤害不受法术伤害影响（只作用于法术）
	_prepare()
	var foe_unit: BoardUnit = _spawn(FOE, "c011")
	_spawn(ME, "f008")
	var fire: CardData = _db.get_card("c010")              # 火焰元素：战吼 3 点伤害
	var u: BoardUnit = _gm.summon_unit(ME, fire)
	_gm._resolve_effect(ME, fire, foe_unit.unit_id, FOE, u)
	_check(foe_unit.health == 8 - 3, "随从战吼伤害不吃法术伤害加成（%d）" % foe_unit.health)


# ------------------------------ ② 发现（三选一）规则 ------------------------------

func _test_discover_rules() -> void:
	_prepare()
	var options: Array = _gm.random_discover_options(3)
	_check(options.size() == 3, "随机候选是 3 张（实际 %d）" % options.size())
	var no_token := true
	for c in options:
		if c.is_token:
			no_token = false
	_check(no_token, "候选里不含衍生物")
	_check(_gm.pending_discover.is_empty(), "一开始没有待选")

	_check(_gm.begin_discover(ME, options), "挂起一次发现")
	_check(_gm.pending_discover.get("pid", -1) == ME, "挂起的发起方正确")
	_check(not _gm.pending_discover.is_empty(), "有待选时 pending_discover 非空")
	var hand_before: int = _gm.get_player(ME).hand.size()
	var pick_id: String = options[1].id
	_check(_gm.resolve_discover(1), "结算发现（选第 2 张）")
	_check(_gm.get_player(ME).hand.size() == hand_before + 1, "选中的牌进入手牌（%d -> %d）" % [hand_before, _gm.get_player(ME).hand.size()])
	_check(_gm.get_player(ME).hand[-1].id == pick_id, "进的正是选中的那张（%s）" % _gm.get_player(ME).hand[-1].card_name)
	_check(_gm.pending_discover.is_empty(), "结算后清空待选")
	_check(not _gm.resolve_discover(0), "没有待选时结算失败（不会凭空给牌）")

	# 非法序号：不崩、不消耗待选
	_gm.begin_discover(ME, _gm.random_discover_options(3))
	_check(not _gm.resolve_discover(9), "越界序号被拒绝")
	_check(not _gm.pending_discover.is_empty(), "被拒绝后待选仍在（可以重选）")
	_gm.resolve_discover(0)

	# 快照携带：联机时客机也能弹窗
	_prepare()
	_gm.begin_discover(ME, _gm.random_discover_options(3))
	var snap: Dictionary = _gm.net_snapshot(ME)
	_check(snap.has("discover") and int(snap["discover"].get("options", []).size()) == 3,
		"快照里带上发现候选（%d 张）" % int(snap["discover"].get("options", []).size()))
	_gm.resolve_discover(0)

	# 通过卡牌效果触发：奥术研究 → 挂起发现
	_prepare()
	var me: PlayerState = _gm.get_player(ME)
	me.mana = 10
	me.max_mana = 10
	me.hand.clear()
	me.hand.append(_db.get_card("s101"))                   # 奥术研究：发现
	var pending := [false]
	_gm.discover_requested.connect(func(_pid: int, opts: Array) -> void: pending[0] = opts.size() == 3)
	_check(_gm.play_card(ME, 0), "打出「奥术研究」")
	_check(pending[0], "卡牌效果触发了发现（3 张候选）")
	_check(not _gm.pending_discover.is_empty(), "打完后处于待选状态")
	var before: int = me.hand.size()
	_gm.resolve_discover(0)
	_check(me.hand.size() == before + 1, "选完一张进手牌（%d -> %d）" % [before, me.hand.size()])


# ------------------------------ ② 发现的界面 ------------------------------

func _test_discover_ui() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	if _main == null:
		_check(false, "主场景可实例化")
		return
	_gm.new_game()
	_main.skip_mulligan()
	_prepare()
	var options: Array = _gm.random_discover_options(3)
	_gm.begin_discover(ME, options)
	_check(_main.discover_open(), "挂起发现后主界面自动弹出三选一")
	var dlg = _main.discover_dialog()
	_check(dlg != null and dlg.options.size() == 3, "弹窗里是 3 个候选")
	_check(dlg != null and dlg.card_buttons().size() == 3, "弹窗里建了 3 个可点卡面")
	var hand_before: int = _gm.get_player(ME).hand.size()
	dlg.choose(2)
	_check(not _main.discover_open(), "选完弹窗自动关闭")
	_check(_gm.get_player(ME).hand.size() == hand_before + 1, "选中的卡进入手牌（%d -> %d）" % [hand_before, _gm.get_player(ME).hand.size()])
	_check(_gm.pending_discover.is_empty(), "界面选择后待选清空")
	_main.queue_free()


# ------------------------------ 辅助 ------------------------------

func _prepare() -> void:
	_gm.new_game()
	_gm.log_enabled = false
	_gm.pending_discover = {}
	for pid in [ME, FOE]:
		var p: PlayerState = _gm.get_player(pid)
		p.max_mana = 10
		p.mana = 10
		p.board.clear()
		p.hand.clear()
		p.graveyard.clear()
	_gm.current_player = ME
	_gm.busy = false


func _spawn(pid: int, card_id: String) -> BoardUnit:
	var card: CardData = _db.get_card(card_id)
	var u := BoardUnit.new()
	u.setup(card.clone(), pid, -1, 90000 + randi() % 9000)
	u.attacks_used = 0
	_gm.get_player(pid).board.append(u)
	return u


## 用一张法术卡对指定目标结算，返回对随从造成的实际伤害（打脸返回 0）
func _cast_spell(card_id: String, unit_id: int, owner: int) -> int:
	var card: CardData = _db.get_card(card_id)
	var target: Dictionary = {"kind": "self", "unit_id": -1, "player_id": owner}
	if unit_id >= 0:
		target = {"kind": "unit", "unit_id": unit_id, "player_id": owner}
	var unit: BoardUnit = _gm.find_unit(unit_id) if unit_id >= 0 else null
	var before_hp: int = unit.health if unit != null else 0
	_gm._resolve_effect(ME, card, unit_id, owner)
	if unit != null:
		return before_hp - unit.health
	return 0


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
	print("=== 法伤 / 发现测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
