extends SceneTree
## 起手换牌测试：开局抽 4 张、可以点选想换掉的牌、确认后洗回牌库重抽同样张数；
## 同时覆盖下标越界 / 重复、只能换一次、AI 也会换、以及换牌面板的开关与选中状态。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/mulligan_test.gd

const ME := 0
const FOE := 1
const START_HAND := 4

var _fails := 0
var _frames := 0
var _db
var _gm
var _main
var _fail_lines: Array[String] = []


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
		_run_rules()
		return false
	if _frames == 4:
		_run_ui()
		_finish()
		return true
	return _frames > 400


# ------------------------------ 规则 ------------------------------

func _run_rules() -> void:
	# 开局：双方各 4 张，等待玩家确认
	_gm.new_game()
	var me: PlayerState = _gm.get_player(ME)
	var foe: PlayerState = _gm.get_player(FOE)
	_check(me.hand.size() == START_HAND + 1, "开局抽 %d 张起手 + 回合开始抽 1 张 = %d 张（实际 %d）" % [START_HAND, START_HAND + 1, me.hand.size()])
	_check(foe.hand.size() == START_HAND, "对手起手 %d 张（尚未轮到它抽牌，实际 %d）" % [START_HAND, foe.hand.size()])
	_check(_gm.mulligan_pending, "开局处于「等待起手换牌」状态")
	var deck_total: int = me.deck.size() + me.hand.size()

	# 一张都不换
	var replaced: int = _gm.finish_mulligan(ME, [])
	_check(replaced == 0, "一张都不换时不会换牌（%d）" % replaced)
	_check(me.hand.size() == START_HAND + 1, "保留时手牌仍是 %d 张" % me.hand.size())
	_check(not _gm.mulligan_pending, "确认后不再是待换牌状态")

	# 只能换一次
	var again: int = _gm.finish_mulligan(ME, [0])
	_check(again == 0, "起手换牌只能生效一次（再次调用换了 %d 张）" % again)

	# 换 1 张：手牌张数不变、总数守恒
	_gm.new_game()
	me = _gm.get_player(ME)
	deck_total = me.deck.size() + me.hand.size()
	var keep: Array[CardData] = []
	for i in range(1, me.hand.size()):
		keep.append(me.hand[i])
	replaced = _gm.finish_mulligan(ME, [0])
	_check(replaced == 1, "选中 1 张时换掉 1 张（%d）" % replaced)
	_check(me.hand.size() == START_HAND + 1, "换牌后手牌张数不变（实际 %d）" % me.hand.size())
	_check(me.deck.size() + me.hand.size() == deck_total, "换牌不会凭空多牌或少牌（%d）" % (me.deck.size() + me.hand.size()))
	var kept_ok := true
	for c in keep:
		if not me.hand.has(c):
			kept_ok = false
	_check(kept_ok, "没选中的牌会留在手里（选了 %d 张保留）" % keep.size())

	# 换 3 张与全部 4 张
	_gm.new_game()
	me = _gm.get_player(ME)
	deck_total = me.deck.size() + me.hand.size()
	_check(_gm.finish_mulligan(ME, [0, 2, 3]) == 3, "选中 3 张时换掉 3 张")
	_check(me.hand.size() == START_HAND + 1 and me.deck.size() + me.hand.size() == deck_total,
		"换 3 张后张数守恒（手牌 %d / 牌库 %d）" % [me.hand.size(), me.deck.size()])

	_gm.new_game()
	me = _gm.get_player(ME)
	_check(_gm.finish_mulligan(ME, [0, 1, 2, 3]) == START_HAND, "可以四张全换")
	_check(me.hand.size() == START_HAND + 1, "全换后手牌张数不变（%d）" % me.hand.size())

	# 越界 / 重复下标：忽略掉，不报错
	_gm.new_game()
	me = _gm.get_player(ME)
	_check(_gm.finish_mulligan(ME, []) == 0, "空下标列表安全")
	_gm.new_game()
	me = _gm.get_player(ME)
	_check(_gm.finish_mulligan(ME, [-1, 99]) == 0, "越界下标被忽略（换了 %d 张）" % 0)
	_check(me.hand.size() == START_HAND + 1, "越界请求不会动到手牌（%d）" % me.hand.size())
	_gm.new_game()
	me = _gm.get_player(ME)
	_check(_gm.finish_mulligan(ME, [1, 1, 1]) == 1, "重复下标只算一次（换了 1 张）")

	# AI 的换牌：高费起手牌会被换掉
	_gm.new_game()
	foe = _gm.get_player(FOE)
	var foe_deck_total: int = foe.deck.size() + foe.hand.size()
	var high_cost := 0
	for c in foe.hand:
		if c.cost >= 6:
			high_cost += 1
	_gm._ai_mulligan()
	_check(foe.deck.size() + foe.hand.size() == foe_deck_total, "AI 换牌后张数守恒")
	var still_high := 0
	for c in foe.hand:
		if c.cost >= 6:
			still_high += 1
	_check(high_cost == 0 or still_high < high_cost,
		"AI 会把高费起手牌换掉（%d -> %d）" % [high_cost, still_high])

	# 换牌后仍然可以正常开始出牌（法力正常）
	me = _gm.get_player(ME)
	_check(me.max_mana >= 1, "起手换牌不影响第 1 回合法力（%d/%d）" % [me.mana, me.max_mana])


# ------------------------------ 界面 ------------------------------

func _run_ui() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	_check(_main != null, "主场景可实例化")
	if _main == null:
		return
	_gm.new_game()
	_check(_main.mulligan_open(), "开局自动弹出起手换牌面板")
	var dlg: MulliganDialog = _main.mulligan_dialog()
	_check(dlg != null and is_instance_valid(dlg), "面板实例存在")
	if dlg == null:
		return
	_check(dlg.card_buttons().size() == START_HAND, "面板里只列起手那 %d 张（实际 %d；回合抽的第 5 张不可换）" % [START_HAND, dlg.card_buttons().size()])
	_check(dlg.picked_indices().is_empty(), "初始时没有选中任何牌")

	dlg.toggle(1)
	dlg.toggle(3)
	_check(str(dlg.picked_indices()) == str([1, 3]), "点选两张后选中状态正确（%s）" % str(dlg.picked_indices()))
	_check(dlg.card_buttons()[1].selected and dlg.card_buttons()[3].selected, "被选中的卡面有选中样式")
	_check(not dlg.card_buttons()[0].selected, "未选中的卡面保持普通样式")
	dlg.toggle(1)
	_check(str(dlg.picked_indices()) == str([3]), "再点一次取消选中（%s）" % str(dlg.picked_indices()))

	# 确认换牌：面板关闭、牌换掉、状态清干净
	var before: int = _gm.get_player(ME).hand.size()
	dlg.toggle(1)
	dlg._on_confirm()
	_check(not _main.mulligan_open(), "确认后面板关闭")
	_check(not _gm.mulligan_pending, "确认后不再处于待换牌状态")
	_check(_gm.get_player(ME).hand.size() == before, "确认换牌后手牌张数不变（%d）" % _gm.get_player(ME).hand.size())

	# 再开一局：面板会重新弹出，skip_mulligan() 能一键跳过
	_gm.new_game()
	_check(_main.mulligan_open(), "重开一局会重新弹出面板")
	_main.skip_mulligan()
	_check(not _main.mulligan_open(), "skip_mulligan() 可以一键跳过")
	_check(not _gm.mulligan_pending, "跳过后状态清干净")
	_main.queue_free()


# ------------------------------ 测试辅助 ------------------------------

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
	print("=== 起手换牌测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
