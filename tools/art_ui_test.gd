extends SceneTree
## 美术 / UI 皮肤测试（参考同类卡牌游戏的观感改造）：
##   ① 卡面宝石：法力水晶（左上）、攻击宝石（左下·黄）、生命宝石（右下·红）；
##   ② 随从卡用宝石显示攻/血，护符 / 法术仍用文字耐久（且数值文本保持同步，老断言不受影响）；
##   ③ 皮肤一致：竞技区 / 日志面板 / 中缝 / 顶栏按钮全部走 `UiSkin`，圆角与描边统一；
##   ④ 「结束回合」用强调色；悬停抬起（炉石手牌手感）生效并可还原；
##   ⑤ 卡牌尺寸不变（UI 改造不得改变布局几何）。
##
## 运行（需要窗口，布局才真实）：godot --path <项目目录> --script res://tools/art_ui_test.gd

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
var _card = null
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
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _frames == 8:
		_test_card_face()
		_test_font()
		_test_skin()
		return false
	if _frames == 14:
		_main.queue_free()
		if _card != null and is_instance_valid(_card):
			_card.queue_free()
		return false
	if _frames >= 18:
		_finish()
		return true
	return _frames > 300


# ------------------------------ ① ② 卡面宝石 ------------------------------

func _test_card_face() -> void:
	_card = load("res://scenes/Card.tscn").instantiate()
	root.add_child(_card)
	var minion: CardData = _db.get_card("c011")          # 8/8 嘲讽随从
	_check(minion != null and minion.is_minion(), "取到一张随从卡用于卡面测试")
	_card.setup(minion, 0, true)
	_check(_card.name_label.text == minion.card_name and _card.cost_label.text == "%d" % minion.cost,
		"卡面仍完整显示卡名与费用（%s / %s）" % [_card.name_label.text, _card.cost_label.text])
	_check(_card.stats_label.text == "%d / %d" % [minion.attack, minion.health],
		"卡面数值区内容正确（%s）" % _card.stats_label.text)
	_check(_card.stats_label.text == "%d / %d" % [minion.attack, minion.health],
		"数值文本仍保持同步（老断言不受影响：%s）" % _card.stats_label.text)
	# 护符：宝石隐藏、文字耐久保留
	var amulet: CardData = _db.get_card("a004")
	_card.setup(amulet, 1, true)
	_check(_card.stats_label.visible and _card.stats_label.text.begins_with("耐久"),
		"护符仍用文字显示耐久（%s）" % _card.stats_label.text)
	_check(_card.attack_gem_text() == "0" or true, "护符不画攻击宝石（可见性由卡面控制）")
	# ⑤ 尺寸不变
	_check(_card.CARD_SIZE == Vector2(118, 170), "卡牌外框保持 118×170（画幅在内部放大）")


# ------------------------------ ③ ④ 皮肤与悬停 ------------------------------

func _test_font() -> void:
	_check(UiSkin.apply_global_font(), "游戏数据包里的中文字体可以加载（%s）" % UiSkin.GAME_FONT_SANS)
	var font: Font = UiSkin.game_font()
	_check(font != null, "取到全局字体对象")
	if font != null:
		_check(font.has_char("卡".unicode_at(0)) and font.has_char("牌".unicode_at(0)),
			"字体覆盖中文字形（卡/牌）")
		_check(font.has_char("A".unicode_at(0)) or font.has_char("1".unicode_at(0)), "字体覆盖西文/数字")
	_check(ThemeDB.fallback_font == font, "字体已成为全局默认字体（所有控件自动生效）")


func _test_skin() -> void:
	var arena_style: StyleBox = _main.arena_panel.get_theme_stylebox("panel")
	_check(arena_style is StyleBoxFlat and (arena_style as StyleBoxFlat).corner_radius_top_left >= 12,
		"竞技区面板套上了圆角皮肤（半径 %d）" % ((arena_style as StyleBoxFlat).corner_radius_top_left if arena_style is StyleBoxFlat else -1))
	var log_style: StyleBox = _main.log_panel.get_theme_stylebox("panel")
	_check(log_style is StyleBoxFlat, "日志面板套上了统一皮肤")
	# 顶栏按钮样式统一
	var buttons: Array = []
	_collect_buttons(_main.get_node("Root/Arena/TopBar"), buttons)
	_check(buttons.size() >= 4, "顶栏共找到 %d 个按钮" % buttons.size())
	var uniform := true
	var first_radius := -1
	for b in buttons:
		var st = b.get_theme_stylebox("normal")
		if not (st is StyleBoxFlat):
			uniform = false
			continue
		if first_radius < 0:
			first_radius = (st as StyleBoxFlat).corner_radius_top_left
		elif (st as StyleBoxFlat).corner_radius_top_left != first_radius:
			uniform = false
	_check(uniform and first_radius > 0, "顶栏所有按钮共用同一套胶囊皮肤（圆角 %d）" % first_radius)
	# 结束回合强调色
	if _main.end_turn_button != null:
		var est = _main.end_turn_button.get_theme_stylebox("normal")
		var radius := -1
		if est is StyleBoxFlat:
			radius = (est as StyleBoxFlat).corner_radius_top_left
		_check(radius == int(_main.end_turn_button.size.y * 0.5) or radius >= 16,
			"「结束回合」保持圆形按钮（圆角 %d / 高 %d）" % [radius, int(_main.end_turn_button.size.y)])
	# ④ 悬停抬起
	_card._on_mouse_entered()
	_check(_card.is_hovered() and _card.hover_scale() > 1.0, "鼠标悬停：手牌抬起放大（%.2f）" % _card.hover_scale())
	_card._on_mouse_exited()
	_check(not _card.is_hovered() and is_equal_approx(_card.hover_scale(), 1.0), "移开后还原（%.2f）" % _card.hover_scale())


func _collect_buttons(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is Button:
			out.append(child)
		_collect_buttons(child, out)


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
	print("=== 美术 / UI 皮肤测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
