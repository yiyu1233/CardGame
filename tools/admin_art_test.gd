extends SceneTree
## 本轮四项的回归测试：
##   ① 卡面宝石（_draw 绘制，**不遮文字**，可测试 `gem_circles()`）
##   ② 伤害 / 治疗飘字（`amount_shown` 信号 → FloatText）
##   ③ 手牌与抽牌堆摆布（牌堆移到手牌之外、逐张核对互不重叠；两者共用一套牌背设计）
##   ④ 管理员美术：场景图片（ArtStore 存盘 + 竞技区背景）、卡牌卡图、出牌特效
##   ⑤ 约定素材目录 `assets/art/`：卡面按卡 id 命名即生效、特效按文件夹名即生效（加素材不改代码）
##
## 运行（需要窗口，坐标/布局才真实）：godot --path <项目目录> --script res://tools/admin_art_test.gd

const CardSkin := preload("res://scripts/CardSkin.gd")

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
var _card = null
var _auth = null
var _bg_png := "user://test_bg.png"
var _art_png := "user://test_card_art.png"
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		_auth = root.get_node_or_null("AdminAuth")
		if _gm == null or _db == null:
			_check(false, "GameManager / CardDB 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		_make_test_images()
		_test_art_store()
		_test_card_data_fields()
		_test_art_convention()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		return false
	if _frames == 8:
		_card = load("res://scenes/Card.tscn").instantiate()
		root.add_child(_card)
		_card.size = Vector2(118, 170)
		return false
	if _frames == 12:
		_test_gems()
		_test_piles_layout()
		_test_one_card_design()
		_test_background()
		_test_card_art()
		_test_floats()
		return false
	if _frames == 14:
		_test_art_button()
		return false
	if _frames == 18:
		_main.queue_free()
		_db.reset_to_default()
		return false
	if _frames >= 22:
		_finish()
		return true
	return _frames > 400


# ------------------------------ 工具：造两张测试图片 ------------------------------

func _make_test_images() -> void:
	var img := Image.create(64, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.5, 0.8))
	img.save_png(_bg_png)
	var img2 := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img2.fill(Color(0.8, 0.3, 0.2))
	img2.save_png(_art_png)
	_check(FileAccess.file_exists(_bg_png) and FileAccess.file_exists(_art_png), "测试图片已生成")


# ------------------------------ ④ ArtStore ------------------------------

func _test_art_store() -> void:
	ArtStore.use_save_path("user://test_art.cfg")
	# 没显式设置时回落到**战场预设**（assets/art/board/ 里的第一张）；没有预设才是纯色背景
	var preset := ArtStore.default_board_preset()
	_check(ArtStore.background_path() == preset,
		"默认用战场预设（%s）" % ("无预设" if preset == "" else preset))
	_check(ArtStore.background_texture() == ArtStore.texture(preset),
		"没有显式设置时背景纹理 = 预设纹理（界面回落纯色 / 预设图）")
	_check(not ArtStore.has_texture("user://不存在的图.png"), "无效路径判定为没有纹理（不崩）")
	_check(ArtStore.has_texture(_bg_png), "有效图片可以被加载")
	_check(ArtStore.texture(_bg_png).get_width() == 64, "图片尺寸读取正确（64）")
	ArtStore.set_background_path(_bg_png)
	_check(ArtStore.background_path() == _bg_png, "场景图片路径已保存")
	# 重新读盘验证持久化
	ArtStore.use_save_path("user://test_art.cfg")
	_check(ArtStore.background_path() == _bg_png, "场景图片路径能写盘并读回")
	_check(ArtStore.vfx_display("fire") == "火焰" and ArtStore.vfx_color("fire") != ArtStore.vfx_color(""),
		"特效名与颜色映射可用（%s）" % ArtStore.vfx_display("fire"))
	_check(ArtStore.vfx_options().size() >= 5 and ArtStore.vfx_display("不存在的特效") == "无",
		"特效未知名字按「无」处理")


func _test_card_data_fields() -> void:
	var fresh := CardData.new()
	_check(fresh.art_path == "" and fresh.vfx == "", "卡牌字段缺省时回落为空（兼容旧存档 / 旧卡表）")
	var c: CardData = _db.get_card("c011")
	c.art_path = _art_png
	c.vfx = "fire"
	var back: CardData = CardData.from_dict(c.to_dict())
	_check(back.art_path == _art_png and back.vfx == "fire", "卡图与特效字段可以 JSON 往返")
	c.art_path = ""
	c.vfx = ""


# ------------------------------ ⑤ ArtStore：约定素材目录（加素材只改文件名） ------------------------------

func _test_art_convention() -> void:
	var root := "user://test_art_root"
	_remove_dir(root)
	ArtStore.use_art_root(root)
	_check(ArtStore.card_art_dir() == root + "/card_art" and ArtStore.vfx_dir() == root + "/vfx",
		"约定素材目录可重定向（%s）" % ArtStore.art_root())

	# 卡面：文件名 = 卡 id → 不改卡表就生效，且优先于卡表里的 art_path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root + "/card_art"))
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.9, 0.3))
	var by_id := "%s/card_art/c_conv.png" % root
	_check(img.save_png(by_id) == OK, "按卡 id 命名放一张卡面（%s）" % by_id)
	_check(ArtStore.card_art_for("c_conv") == by_id, "按卡 id 命中的卡面（%s）" % ArtStore.card_art_for("c_conv"))
	_check(ArtStore.card_art_for("c_none") == "", "没有同名文件时返回空（回落卡表 / 默认卡图）")
	var conv := CardData.from_dict({"id": "c_conv", "card_name": "约定卡面", "art_path": _art_png})
	_check(ArtStore.art_for(conv) == by_id, "约定文件优先于卡表里的 art_path（%s）" % ArtStore.art_for(conv))
	_check(ArtStore.has_texture(ArtStore.art_for(conv)), "约定文件能被读成纹理")
	conv.art_path = ""
	_check(ArtStore.default_card_art("c_conv") == by_id,
		"默认卡图也认这个文件（%s）" % ArtStore.default_card_art("c_conv"))

	# 特效：文件夹名 = 特效 id；color.txt 定颜色，不写就按名字散列出一个稳定颜色
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root + "/vfx/poison"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root + "/vfx/静默"))
	var f := FileAccess.open(root + "/vfx/poison/color.txt", FileAccess.WRITE)
	if f != null:
		f.store_line("#7b1fa2")
		f.close()
	var ids := ArtStore.custom_vfx_ids()
	_check(ids.has("poison") and ids.has("静默"), "特效目录被扫成新特效（%s）" % str(ids))
	_check(ArtStore.vfx_options().has("poison") and ArtStore.vfx_options().has("fire"),
		"下拉清单 = 内置 + 自己加的")
	_check(ArtStore.vfx_display("poison") == "poison", "新特效显示名 = 文件夹名")
	_check(ArtStore.vfx_color("poison") == Color.html("#7b1fa2"),
		"color.txt 决定光环颜色（%s）" % ArtStore.vfx_color("poison").to_html())
	_check(ArtStore.vfx_color("静默") != ArtStore.vfx_color(""),
		"没写 color.txt 时按名字散列出一个颜色（%s）" % ArtStore.vfx_color("静默").to_html())
	_check(ArtStore.vfx_display("不存在的特效") == "无" and not ArtStore.vfx_options().has("不存在的特效"),
		"没登记的名字仍按「无」处理")

	# 清理：还原约定目录，删掉测试素材
	ArtStore.use_art_root(ArtStore.ART_ROOT)
	_remove_dir(root)
	_check(ArtStore.card_art_dir() == ArtStore.ART_ROOT + "/card_art" and ArtStore.card_art_for("c_conv") == "",
		"恢复默认约定目录后测试素材不再命中")


func _remove_dir(path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	var d := DirAccess.open(path)
	if d != null:
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			if d.current_is_dir():
				_remove_dir("%s/%s" % [path, f])
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [path, f]))
			f = d.get_next()
		d.list_dir_end()
	DirAccess.remove_absolute(abs_path)


# ------------------------------ ① 卡面宝石 ------------------------------

func _test_gems() -> void:
	_card.setup(_db.get_card("c011"), 0, true)          # 随从
	var gems: Array = _card.gem_circles()
	_check(gems.size() == 3, "随从卡有 3 颗宝石（费用 / 攻击 / 生命），实际 %d" % gems.size())
	var kinds := []
	for g in gems:
		kinds.append(str(g["kind"]))
	_check(kinds.has("cost") and kinds.has("attack") and kinds.has("health"), "宝石种类齐全（%s）" % str(kinds))
	# 关键：宝石不得盖住卡面文字（卡名 / 关键字 / 描述）
	# 两侧都用**卡面自身坐标系**（`text_rects_local()` 与 `gem_circles()` 同口径），
	# 否则比的是两个不同的坐标系，结论不可信。
	var text_rects: Array = _card.text_rects_local()
	var clear := true
	var worst := ""
	for g in gems:
		var center: Vector2 = g["center"]
		var radius: float = float(g["radius"])
		for r in text_rects:
			if r.size.x <= 0.0:
				continue
			if r.grow(radius).has_point(center):
				clear = false
				worst = "%s 落在 %s 上" % [str(g["kind"]), str(r)]
	_check(clear, "宝石不遮挡卡名 / 关键字 / 描述文字%s" % ("" if clear else "（%s）" % worst))
	# 法术只有费用宝石
	_card.setup(_db.get_card("s001"), 1, true)
	_check(_card.gem_circles().size() == 1, "法术卡只有费用宝石（%d 颗）" % _card.gem_circles().size())


# ------------------------------ ③ 手牌与牌堆摆布 ------------------------------

func _test_piles_layout() -> void:
	var pile = _main.player_pile()
	var hand: Rect2 = _main.hand_area.get_global_rect()
	_check(pile != null, "我方牌堆存在")
	if pile == null:
		return
	var pr := Rect2(pile.global_position, pile.size)
	_check(not pr.intersects(hand), "我方牌堆不再与手牌区重叠（牌堆底 %.0f ≤ 手牌顶 %.0f）" % [pr.end.y, hand.position.y])
	# 逐张核对：牌堆连**任何一张手牌**都不能压住（曾经手牌被抬高半张牌高、正好顶进牌堆里）
	var under := 0
	for ui in _main.hand_cards:
		if ui == null or not is_instance_valid(ui):
			continue
		if pr.intersects(ui.get_global_rect()):
			under += 1
	_check(under == 0, "牌堆没有压住任何一张手牌（被压 %d 张）" % under)
	var foe = _main.enemy_pile()
	var foe_row: Rect2 = _main.enemy_hand_row.get_global_rect()
	if foe != null:
		var fr := Rect2(foe.global_position, foe.size)
		_check(not fr.intersects(foe_row), "敌方牌堆与敌方手牌行也不重叠")
		var foe_under := 0
		for back in _main.enemy_hand_cards:
			if back != null and is_instance_valid(back) and fr.intersects(back.get_global_rect()):
				foe_under += 1
		_check(foe_under == 0, "敌方牌堆没有压住敌方手牌（被压 %d 张）" % foe_under)


# ------------------------------ ③b 手牌 / 牌堆同一套设计 ------------------------------

func _test_one_card_design() -> void:
	# 牌堆的牌背与手牌卡**同宽高比**（看起来是同一种牌）
	var pile = _main.player_pile()
	if pile != null:
		var ratio: float = float(pile.CARD_SIZE.x) / float(pile.CARD_SIZE.y)
		_check(absf(ratio - CardSkin.CARD_RATIO) < 0.01,
			"牌堆牌背与手牌卡同宽高比（%.3f vs %.3f）" % [ratio, CardSkin.CARD_RATIO])
	# 敌方手牌卡背也用同一套配色与圆角比例
	if not _main.enemy_hand_cards.is_empty():
		var back = _main.enemy_hand_cards[0]
		var st = back.get_theme_stylebox("panel")
		_check(st is StyleBoxFlat and (st as StyleBoxFlat).bg_color == CardSkin.BACK_BG,
			"敌方手牌卡背底色 = 牌堆牌背底色（%s）" % (str((st as StyleBoxFlat).bg_color) if st is StyleBoxFlat else "非 StyleBoxFlat"))
		_check(st is StyleBoxFlat and (st as StyleBoxFlat).border_color == CardSkin.BACK_EDGE,
			"敌方手牌卡背描边 = 牌堆牌背描边")
		_check(st is StyleBoxFlat
			and absf(float((st as StyleBoxFlat).corner_radius_top_left) - CardSkin.radius_for(Vector2(_main.ENEMY_CARD_W, _main.ENEMY_CARD_H))) <= 1.0,
			"敌方卡背圆角按同一比例")
		# 宽高比同样与手牌一致
		var eratio: float = float(_main.ENEMY_CARD_W) / float(_main.ENEMY_CARD_H)
		_check(absf(eratio - CardSkin.CARD_RATIO) < 0.01, "敌方卡背也与手牌同宽高比（%.3f）" % eratio)
	# 手牌卡自己的圆角比例就是 CardSkin 的基准（UiSkin.CARD_RADIUS / 卡宽）
	_check(absf(float(UiSkin.CARD_RADIUS) / 118.0 - CardSkin.RADIUS_RATIO) < 0.01,
		"手牌卡圆角比例 = CardSkin.RADIUS_RATIO（%.3f）" % (float(UiSkin.CARD_RADIUS) / 118.0))


# ------------------------------ ④ 场景图片 / 卡图 ------------------------------

func _test_background() -> void:
	ArtStore.set_background_path(_bg_png)
	_main._apply_background()
	var rect = _main.background_rect()
	_check(rect != null and rect.visible and rect.texture != null,
		"设置了场景图片后，竞技区背景铺上图片")
	ArtStore.set_background_path("")
	_main._apply_background()
	var preset := ArtStore.default_board_preset()
	if preset == "":
		_check(_main.background_rect() == null or not _main.background_rect().visible,
			"清空场景图片、且没有战场预设时回落到默认纯色背景")
	else:
		_check(_main.background_rect() != null and _main.background_rect().visible,
			"清空场景图片后回落到战场预设（%s）" % preset)


func _test_card_art() -> void:
	_card.setup(_db.get_card("c011"), 0, true)
	var art_before = _card.art_node()
	_check(art_before == null or not art_before.visible, "没配卡图时卡面不显示卡图")
	_card.data.art_path = _art_png
	_card.apply_art()
	var art_after = _card.art_node()
	_check(art_after != null and art_after.visible and art_after.texture != null, "配了卡图后卡面显示卡图")
	_check(art_after != null and art_after.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"卡图不吃鼠标事件（不影响出牌 / 拖拽）")
	_check(_card.name_label.visible and _card.desc_label.visible, "卡图不遮挡卡面文字节点")
	# 卡图应该放进"画框"（ArtFrame），并且画框始终占位（无卡图时也不塌陷）
	var frame = _card.get_node_or_null("Margin/VBox/ArtFrame")
	_check(frame != null and frame.visible, "卡面有独立画框（ArtFrame）且始终占位")
	_check(art_after != null and art_after.get_parent() == frame, "卡图被放进画框内（而不是整卡底图）")
	_card.data.art_path = ""
	_test_vfx_target()


# ------------------------------ ② 伤害 / 治疗飘字 ------------------------------

func _test_vfx_target() -> void:
	# 出牌特效应打在**目标**身上：card_resolved 携带目标，特效落点 = 目标中心
	var target: BoardUnit = _gm.summon_unit(1, _db.get_card("c002"))
	_main._refresh()
	var targeted: CardData = _db.get_card("s001")     # 火焰冲击：指定任意角色
	targeted.vfx = "fire"
	_main._on_card_resolved_vfx(0, targeted, target.unit_id, 1)
	var want: Vector2 = _main._unit_center(target.unit_id)
	_check(want != Vector2.ZERO, "取到目标随从的屏幕中心")
	_check(_main.last_vfx_position().distance_to(want) < 2.0,
		"特效落点 = 目标随从中心（偏差 %.1fpx）" % _main.last_vfx_position().distance_to(want))
	# 打英雄时落在英雄框上
	_main._on_card_resolved_vfx(0, targeted, -1, 1)
	var hero_center: Vector2 = _main.enemy_hero_frame.get_global_rect().get_center()
	_check(_main.last_vfx_position().distance_to(hero_center) < 2.0,
		"打英雄时特效落在敌方英雄框上（偏差 %.1fpx）" % _main.last_vfx_position().distance_to(hero_center))
	# 没有目标的牌：落在出牌者主战者上（不崩）
	targeted.vfx = "holy"
	_main._on_card_resolved_vfx(0, targeted, -1, -1)
	_check(_main.last_vfx_position() != Vector2.ZERO, "无目标牌的特效也有落点（不崩）")
	targeted.vfx = ""


func _test_floats() -> void:
	var before: int = _main.floating_texts().size()
	var unit: BoardUnit = _gm.summon_unit(1, _db.get_card("c002"))
	_gm.deal_damage_to_unit(null, unit, 3)
	var after: Array = _main.floating_texts()
	_check(after.size() > before or after.size() > 0, "受到伤害后冒出飘字（%d 个）" % after.size())
	var found_damage := false
	for f in after:
		# 飘字本体只画数字 0-9（原版数字图集，见 docs/shadowverse-damage-floattext.md）：
		# 传入的 "-" 前缀会被 FloatText 过滤掉，符号/颜色属于 2D 表现层的附加信息。
		if f.text == "3":
			found_damage = true
	_check(found_damage, "伤害飘字只画数字（3，不带符号）")
	# 飘字会向上飘并最终结束
	if after.size() > 0:
		var f0 = after[0]
		var start: Vector2 = f0.current_pos()
		for i in 6:
			f0._process(0.05)
		_check(f0.current_pos().y < start.y, "飘字向上移动（%.1f -> %.1f）" % [start.y, f0.current_pos().y])
	# 治疗飘字
	var hero_before: int = _main.floating_texts().size()
	_gm.amount_shown.emit(0, -1, 4, "heal")
	var healed := false
	for f in _main.floating_texts():
		if f.text == "4":
			healed = true
	_check(healed, "治疗飘字为数字（4）")
	_check(_main.floating_texts().size() >= hero_before, "治疗飘字同样会显示")
	# 英雄受伤也飘字
	_gm.amount_shown.emit(1, -1, 6, "damage")
	var hero_hit := false
	for f in _main.floating_texts():
		if f.text == "6":
			hero_hit = true
	_check(hero_hit, "英雄受伤也冒飘字（6）")

	# ---- 飘字必须落在**对应的那张牌 / 那位主战者**身上（用户要求）----
	# ① 随从：锚点 = 它所在格子的中心（即使控件这一帧还没重建也算得准）
	var slot: int = _gm.slot_of_unit(unit)
	var surface: BoardSurface = _main.enemy_board
	var want: Vector2 = surface.global_position + surface.slot_rect(slot).get_center()
	var got: Vector2 = _main.float_anchor(1, unit.unit_id)
	_check(got.distance_to(want) < 2.0,
		"随从飘字落在该随从的格子上（偏差 %.1fpx）" % got.distance_to(want))
	var hero_rect: Rect2 = _main.enemy_hero_frame.visual_rect()
	_check(not hero_rect.has_point(got),
		"打随从时飘字**不会**跑到主战者框上（%s ∉ %s）" % [str(got), str(hero_rect)])
	# ② 主战者：锚点落在头像盘内（贴近盘心），而不是主战者框之外
	#    （这里刻意用**无类型**变量：SceneTree 脚本在 load 期就编译 HeroFrame 依赖时
	#      拿不到 autoload 名字，写 `var frame: HeroFrame` 会编译失败）
	var frame = _main.enemy_hero_frame
	var disc_center: Vector2 = frame.global_position + frame.disc_center_local()
	var hero_anchor: Vector2 = _main.float_anchor(1, -1)
	_check(hero_anchor.distance_to(disc_center) <= frame.disc_radius(),
		"主战者飘字落在头像盘内（离盘心 %.1fpx ≤ 半径 %.1fpx）" % [
			hero_anchor.distance_to(disc_center), frame.disc_radius()])
	# ③ 我方主战者也一样（上下镜像各测一次）
	var mine_anchor: Vector2 = _main.float_anchor(0, -1)
	var my_frame = _main.player_hero_frame
	var my_disc: Vector2 = my_frame.global_position + my_frame.disc_center_local()
	_check(mine_anchor.distance_to(my_disc) <= my_frame.disc_radius(),
		"我方主战者的飘字同样落在头像盘内")


# ------------------------------ 管理员入口 ------------------------------

func _test_art_button() -> void:
	var btn = _main.art_button()
	_check(btn != null, "顶栏有「美术」按钮")
	if btn == null:
		return
	var logged: bool = _auth != null and _auth.is_logged_in
	_check(btn.visible == logged, "「美术」按钮可见性跟随管理员登录状态")
	if not logged:
		_main._open_art_dialog()
		_check(_main.art_dialog() == null, "未登录时点「美术」不会打开对话框")
	else:
		_main._open_art_dialog()
		_check(_main.art_dialog() != null, "已登录时可以打开美术设置")
		_main.art_dialog().queue_free()


# ------------------------------ 辅助 ------------------------------

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
	print("=== 美术 / 飘字 / 摆布测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
