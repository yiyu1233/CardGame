extends SceneTree
## ============================================================================
## 逆向复刻验收测试：Shadowverse「伤害飘字 / 卡堆」+「抽卡（牌堆）动画」
##
## 被测对象（契约已冻结，本测试只按契约断言，绝不修改被测代码 / 常量）：
##   scripts/FloatText.gd  —— 伤害 / 治疗飘字（对应原版 cmn_battle_damage_1 / heal_1）
##   scripts/DeckPile.gd   —— 抽牌堆（厚度 = 剩余牌数，抽牌有飞牌动画）
##   scripts/Main.gd       —— 信号接线（amount_shown → 飘字）与真实抽牌 → 牌堆动画
##
## 逆向依据（1:1 复刻目标）：
##   docs/shadowverse-damage-floattext.md
##     §2.1 生命周期 DAMAGE_ANIMATION_LENGTH = 2.5s
##     §2.3 数字用绝对值（min(|value|, 9999)），不带正负号
##     §2.4 字距 DAMAGE_TEXT_MARGIN = 0.26、整体以锚点居中、DamageCount 全局自增 → sortingOrder
##     §7   「卡堆」= 层级堆叠（不是位置堆叠）：全战斗单调递增、从不重置
##   docs/shadowverse-draw-animation.md
##     §6.2 / §6.3 牌堆厚度 = 剩余牌数；抽一张瞬时隐藏一张（动画开始那一帧就减显示层）
##     §10.4       抽 1 张瞬时减层 + 独立飞牌动画：0.40s 翻牌（easeOutCirc）+ 0.25s 入手 = 总 0.65s
##                 （DeckPile 常量：FLIGHT_TIME 0.40 / FLIP_TIME 0.39 / REVEAL_TIME 0.40 /
##                  HAND_TIME 0.25 / TOTAL_TIME 0.65；旧的 ANIM_TIME 已删除）
##
## 运行（需要窗口，画布尺寸 / 布局才真实；不要加 --headless）：
##   godot --path <项目目录> --script res://tools/vfx_shadowverse_test.gd
##   退出码：0 = 全部通过；1 = 有失败项（失败项会在末尾汇总打印）
##
## 覆盖点（共 46 条断言；其中 3 条带 * 的依赖被测脚本仍保留同名常量，
## 即 MAX_LAYERS / TOTAL_TIME / REVEAL_TIME+HAND_TIME，常量缺失时自动跳过而不误报；
## 另有 3 条异常兜底断言只在 autoload 缺失 / 超时 / 缺接口时触发）：
##   A. FloatText（18 项）
##      ① lifetime() == 2.5s；② mouse_filter = IGNORE；③ pop("-12") 只留数字；
##      ④ pop 后 is_playing() = 真；⑤ progress() 从 0 开始；⑥ current_pos().y 随时间持续变小；
##      ⑦ progress() ∈ [0,1]；⑧ 累计 > 2.5s 后 is_playing() = 假；
##      ⑨ "1234" → 4 个位偏移；⑩ font_size() > 0；⑪ 相邻位差 == 0.26 × font_size()（±0.5px）；
##      ⑫ offsets[0] + offsets[3] ≈ 0（整体居中）；⑬ 1 位数字只有 1 个偏移且居中；
##      ⑭ big=true 字号 > big=false；⑮ 连续 new+pop 100 次都取到 order()；
##      ⑯ order() 严格递增；⑰ order() 无重复；⑱ 跨实例共享同一计数器（第 100 个比第 1 个大 ≥ 99）
##   B. DeckPile（20 项）
##      ① animate_draw() 后 is_animating() = 真；② 累计 > 1.2s 自动结束；③ 动画不影响 count；
##      ④ 真实抽牌后 count = 抽前牌数 - 1；⑤ 真实抽牌触发 is_animating()；
##      ⑥ 累计 > 1.2s 后结束；⑦ 结束后 count = 真实牌库数；
##      ⑧ mouse_filter = IGNORE；⑨ 0 张 layers()==0；⑩ 0 张 thickness()==0；⑪ 5 张有厚度；
##      ⑫ 50 张 > 5 张；⑬ 1000 张 == 100000 张（上限封顶）；⑭ 封顶层数远小于张数；
##      ⑮ 封顶层数 == MAX_LAYERS*；⑯ 总时长 TOTAL_TIME ≈ 0.65s*；
##      ⑰ REVEAL_TIME + HAND_TIME == TOTAL_TIME*；
##      ⑱ count 属性 = 设定值；⑲ count_text() 含真实张数；⑳ draw_target 可读可写
##   C. 不回归（8 项）
##      ① amount_shown 信号 → 正在播放的飘字非空；② 飘字文案只含数字；③ 飘字数值 = 3；
##      ④ 飘字 mouse_filter = IGNORE；⑤ 层级序号全战斗单调递增、不重置；
##      ⑥ 我方 / 敌方牌堆控件都还在；⑦ 我方牌堆 mouse_filter = IGNORE；⑧ 敌方牌堆同上
##
## 说明：动画一律按**累计时间**判定（帧率随环境变化），不按帧数；不依赖鼠标输入。
## ============================================================================

const FLOAT_SCRIPT := "res://scripts/FloatText.gd"
const PILE_SCRIPT := "res://scripts/DeckPile.gd"
const PILE_COUNT := 23              ## 独立牌堆控件测试用的张数

var _fails := 0
var _frames := 0
var _t := 0.0
var _stage := 0
var _gm
var _main
var _loose = null
var _deck_before := 0
var _max_order := 0                 ## 100 次弹字里最大的层级序号（用于验证「不重置」）
var _fail_lines: Array[String] = []


func _process(delta: float) -> bool:
	_frames += 1
	_t += delta
	# 第 2 帧：等画布尺寸就绪后再实例化 Main（照 deck_pile_test 的做法）
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		if _gm == null:
			_check(false, "GameManager 自动加载（找不到就无法做真实抽牌测试）")
			_finish()
			return true
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	# 第 6 帧：飘字全部静态断言 + 牌堆静态断言，然后起一次抽牌动画
	if _frames == 6:
		_test_float_basics()
		_test_float_digits()
		_test_float_big()
		_test_float_stack()
		_setup_loose_pile()
		_test_pile_static()
		_loose.animate_draw()
		_check(_loose.is_animating(), "animate_draw() 后进入抽牌动画状态")
		_stage = 1
		_t = 0.0
		return false
	# 阶段 1：独立牌堆的一次抽卡动画（TOTAL_TIME 0.65s = 0.40 翻牌 + 0.25 入手）应已结束
	# 判据按累计时间给足余量（低帧率下引擎时钟偏慢，0.65s 可能实测 ~0.9s 累计）
	if _stage == 1 and _t > 1.2:
		_check(not _loose.is_animating(), "单张抽卡动画按时长自动结束（累计 %.2fs，TOTAL_TIME 0.65s）" % _t)
		_check(_loose.count == PILE_COUNT, "动画播放不影响真实张数（count = %d）" % _loose.count)
		_loose.queue_free()
		# 真实抽牌：牌堆厚度刷新为新牌数，并触发动画
		_deck_before = _gm.get_player(0).deck.size()
		_gm.draw(0, 1)
		_main._update_piles()
		var pile = _main.player_pile()
		_check(pile != null and pile.count == _deck_before - 1,
			"真实抽牌后牌堆厚度 = 新的真实剩余牌数（%d -> %d）" % [_deck_before, 0 if pile == null else pile.count])
		_check(pile != null and pile.is_animating(), "真实抽牌会触发牌堆抽牌动画")
		_stage = 2
		_t = 0.0
		return false
	# 阶段 2：真实抽牌动画播完 + 信号接线不回归
	if _stage == 2 and _t > 1.2:
		var pile = _main.player_pile()
		var real_deck: int = _gm.get_player(0).deck.size()
		_check(pile != null and not pile.is_animating(), "抽卡动画播完自动结束（累计 %.2fs）" % _t)
		_check(pile != null and pile.count == real_deck,
			"动画结束后牌堆张数仍是真实牌数（%d / %d）" % [0 if pile == null else pile.count, real_deck])
		_test_amount_signal()
		_test_regressions()
		_main.queue_free()
		_stage = 3
		_t = 0.0
		return false
	if _stage == 3 and _t > 0.2:
		_finish()
		return true
	if _frames > 3000:
		_check(false, "测试超时（%d 帧，约 %.0fs），流程未走完" % [_frames, _frames / 60.0])
		_finish()
		return true
	return false


# ------------------------------ A. 飘字：生命周期 / 上飘 / 只留数字 ------------------------------

func _test_float_basics() -> void:
	var f = load(FLOAT_SCRIPT).new()
	root.add_child(f)
	if _has(f, "lifetime", "飘字生命周期"):
		var life: float = float(f.lifetime())
		_check(abs(life - 2.5) < 0.001, "飘字生命周期 lifetime() == 2.5s（实际 %.3f）" % life)
	_check(f.mouse_filter == Control.MOUSE_FILTER_IGNORE, "飘字不吃鼠标事件（不挡出牌 / 拖拽）")
	f.pop("-12", Color.RED, Vector2(100, 100))
	_check(str(f.text) == "12", "pop(\"-12\") 只保留数字、去掉正负号（text = \"%s\"）" % str(f.text))
	_check(f.is_playing(), "pop() 后立即处于播放状态")
	_check(f.progress() < 0.05, "pop() 后进度从 0 开始（progress() = %.3f）" % f.progress())
	var y0: float = f.current_pos().y
	var prev: float = y0
	var rising := true
	for _i in 4:
		f._process(0.2)
		var y: float = f.current_pos().y
		if y >= prev:
			rising = false
		prev = y
	_check(rising and prev < y0, "飘字随时间持续向上飘（累计 0.8s：%.1f -> %.1f）" % [y0, prev])
	for _i in 6:
		f._process(0.5)
	if is_instance_valid(f):
		var pg: float = f.progress()
		_check(pg >= 0.0 and pg <= 1.0, "飘字进度 progress() 始终落在 [0,1]（%.3f）" % pg)
	# 结束时可能已被回收（queue_free），两种情况都算「已经不再播放」
	var ended: bool = (not is_instance_valid(f)) or (not f.is_playing())
	_check(ended, "累计超过 2.5s 后飘字结束（is_playing() = 假）")


# ------------------------------ A. 飘字：等字距 / 居中 / 放大字号 ------------------------------

func _test_float_digits() -> void:
	var f = load(FLOAT_SCRIPT).new()
	root.add_child(f)
	f.pop("1234", Color.RED, Vector2(200, 200))
	if not _has(f, "digit_offsets", "数字位横向排布"):
		return
	var offs = f.digit_offsets()
	var n := _size_of(offs)
	_check(n == 4, "「1234」返回 4 个数字位偏移（%s）" % str(offs))
	if n != 4:
		return
	if not _has(f, "font_size", "飘字字号"):
		return
	var fs: float = float(f.font_size())
	_check(fs > 0.0, "飘字字号为正（font_size() = %.1f）" % fs)
	var pitch: float = 0.26 * fs
	var pitch_ok := true
	var worst := 0.0
	for j in 3:
		var d: float = abs(float(offs[j + 1]) - float(offs[j]))
		if abs(d - pitch) > 0.5:
			pitch_ok = false
			worst = d
	var pitch_note := ""
	if not pitch_ok:
		pitch_note = "（实测 %.2fpx）" % worst
	_check(pitch_ok, "相邻数字等字距 = 0.26 × 字号 = %.2fpx%s" % [pitch, pitch_note])
	var sym: float = float(offs[0]) + float(offs[3])
	_check(abs(sym) < 0.5, "数字整体以锚点居中：offsets[0] + offsets[3] = %.2f ≈ 0" % sym)
	# 个位数：只有一个偏移且落在锚点上
	f.pop("9", Color.RED, Vector2(200, 200))
	var one = f.digit_offsets()
	var one_n := _size_of(one)
	var one_ok: bool = one_n == 1
	if one_ok:
		one_ok = abs(float(one[0])) < 0.5
	_check(one_ok, "1 位数字只有 1 个偏移且居中（%s）" % str(one))


func _test_float_big() -> void:
	var big = load(FLOAT_SCRIPT).new()
	root.add_child(big)
	var normal = load(FLOAT_SCRIPT).new()
	root.add_child(normal)
	big.pop("9", Color.RED, Vector2(200, 200), true)
	normal.pop("9", Color.RED, Vector2(200, 200), false)
	if not _has(big, "font_size", "飘字字号"):
		return
	var bf: float = float(big.font_size())
	var nf: float = float(normal.font_size())
	_check(bf > nf, "放大飘字（big=true）字号更大（%.1f > %.1f）" % [bf, nf])


# ------------------------------ A. 飘字：「卡堆」= 全局递增层级 ------------------------------

func _test_float_stack() -> void:
	var orders: Array = []
	var insts: Array = []
	for _i in 100:
		var f = load(FLOAT_SCRIPT).new()
		root.add_child(f)
		f.pop("1", Color.RED, Vector2(300, 300))
		insts.append(f)
		if not _has(f, "order", "飘字层级序号（卡堆）"):
			break
		orders.append(int(f.order()))
	_check(orders.size() == 100, "连续弹出 100 个飘字都取得层级序号（%d 个）" % orders.size())
	if orders.size() == 100:
		var strict := true
		var uniq := {}
		for i in 100:
			uniq[orders[i]] = int(uniq.get(orders[i], 0)) + 1
			if i > 0 and orders[i] <= orders[i - 1]:
				strict = false
		_check(strict, "同一帧连续弹字时层级序号严格递增（第 1 个 %d → 第 100 个 %d）" % [orders[0], orders[99]])
		_check(uniq.size() == 100, "层级序号互不重复（100 个飘字得到 %d 个不同序号）" % uniq.size())
		_check(orders[99] - orders[0] >= 99,
			"不同飘字实例共享同一全局计数器（第 100 个比第 1 个大 %d，应 ≥ 99）" % (orders[99] - orders[0]))
		_max_order = orders[99]
	for f in insts:
		if is_instance_valid(f):
			f.queue_free()


# ------------------------------ B. 牌堆：厚度映射与旧 API ------------------------------

func _setup_loose_pile() -> void:
	_loose = load(PILE_SCRIPT).new()
	root.add_child(_loose)


func _test_pile_static() -> void:
	_check(_loose.mouse_filter == Control.MOUSE_FILTER_IGNORE, "牌堆不吃鼠标事件（不影响出牌 / 拖拽）")
	_loose.set_count(0)
	_check(_loose.layers() == 0, "0 张牌时牌堆不画层（layers() = %d）" % _loose.layers())
	_check(_loose.thickness() == 0.0, "0 张牌时厚度为 0（%.1fpx）" % _loose.thickness())
	_loose.set_count(5)
	var t5: float = _loose.thickness()
	_check(t5 > 0.0, "有牌时牌堆有厚度（5 张 → %.1fpx）" % t5)
	_loose.set_count(50)
	var t50: float = _loose.thickness()
	_check(t50 > t5, "张数越多牌堆越厚（5 张 %.1fpx < 50 张 %.1fpx）" % [t5, t50])
	_loose.set_count(1000)
	var t_max: float = _loose.thickness()
	_loose.set_count(100000)
	var t_huge: float = _loose.thickness()
	_check(t_max == t_huge and t_max >= t50,
		"厚度有上限封顶（1000 张 %.1fpx == 100000 张 %.1fpx）" % [t_max, t_huge])
	_check(_loose.layers() < 1000, "封顶层数远小于张数（100000 张 → %d 层）" % _loose.layers())
	var consts: Dictionary = load(PILE_SCRIPT).get_script_constant_map()
	if consts.has("MAX_LAYERS"):
		_check(_loose.layers() == int(consts["MAX_LAYERS"]),
			"封顶层数 = MAX_LAYERS 常量（%d 层）" % int(consts["MAX_LAYERS"]))
	if consts.has("TOTAL_TIME"):
		_check(abs(float(consts["TOTAL_TIME"]) - 0.65) < 0.01,
			"抽卡动画总时长 TOTAL_TIME ≈ 0.65s（实际 %.3f）" % float(consts["TOTAL_TIME"]))
		if consts.has("REVEAL_TIME") and consts.has("HAND_TIME"):
			_check(abs(float(consts["REVEAL_TIME"]) + float(consts["HAND_TIME"]) - float(consts["TOTAL_TIME"])) < 0.001,
				"翻牌段 + 入手段 == 总时长（%.2f + %.2f = %.2f）" % [float(consts["REVEAL_TIME"]), float(consts["HAND_TIME"]), float(consts["TOTAL_TIME"])])
	_loose.set_count(PILE_COUNT)
	_check(_loose.count == PILE_COUNT, "count 属性 = 设定的真实张数（%d）" % _loose.count)
	_check(_loose.count_text().contains(str(PILE_COUNT)), "计数文案显示真实张数（%s）" % _loose.count_text())
	_loose.draw_target = Vector2(111, 222)
	_check(_loose.draw_target == Vector2(111, 222), "draw_target 可读可写（动画终点 = 手牌区中心）")


# ------------------------------ C. 信号接线 / 不回归 ------------------------------

func _test_amount_signal() -> void:
	var before: int = _main.floating_texts().size()
	_gm.amount_shown.emit(0, -1, 3, "damage")
	var playing: Array = _main.floating_texts()
	_check(playing.size() >= 1 and playing.size() > before,
		"amount_shown 信号会真的产生正在播放的飘字（%d -> %d）" % [before, playing.size()])
	if playing.is_empty():
		return
	var all_digits := true
	var found = null
	for f in playing:
		var txt := str(f.text)
		if not _is_digits(txt):
			all_digits = false
		if _is_digits(txt) and int(txt) == 3:
			found = f
	_check(all_digits, "正在播放的飘字文案只含数字（%s）" % _texts_of(playing))
	_check(found != null, "3 点伤害的飘字数值为 3（%s）" % _texts_of(playing))
	if found == null:
		return
	_check(found.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Main 里的飘字同样不吃鼠标事件")
	if _has(found, "order", "飘字层级序号（卡堆）"):
		_check(int(found.order()) > _max_order,
			"全战斗层级序号单调递增、从不重置（新飘字 %d > 此前最大 %d）" % [int(found.order()), _max_order])


func _test_regressions() -> void:
	var me = _main.player_pile()
	var foe = _main.enemy_pile()
	_check(me != null and foe != null, "我方 / 敌方牌堆控件都还在（旧接口未回归）")
	if me != null:
		_check(me.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Main 里的我方牌堆不吃鼠标事件")
	if foe != null:
		_check(foe.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Main 里的敌方牌堆不吃鼠标事件")


# ------------------------------ 辅助 ------------------------------

## 缺接口时不崩测试：报一次 FAIL 并返回 false，后续断言自行跳过
func _has(obj, method: String, label: String) -> bool:
	if obj != null and is_instance_valid(obj) and obj.has_method(method):
		return true
	_check(false, "被测实现缺少接口 %s()（%s）" % [method, label])
	return false


func _size_of(v) -> int:
	if v == null:
		return -1
	if v is Array or v is PackedFloat32Array or v is PackedFloat64Array:
		return v.size()
	return -1


func _is_digits(t: String) -> bool:
	if t.is_empty():
		return false
	for i in t.length():
		var c := t[i]
		if c < "0" or c > "9":
			return false
	return true


func _texts_of(list: Array) -> String:
	var parts := PackedStringArray()
	for f in list:
		parts.append("\"%s\"" % str(f.text))
	return ", ".join(parts)


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
	print("=== 飘字卡堆 / 抽卡动画验收测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
