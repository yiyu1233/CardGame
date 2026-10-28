extends SceneTree
## 场地布局测试：核对上下半场的镜像对称、控件是否越界，以及新增状态控件的接线与落点对齐。
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/ui_layout_test.gd
##   godot --headless --path <项目目录> --script res://tools/ui_layout_test.gd -- size=1180x860
##
## 说明：
##   1. 界面改动无法在无头模式下“用眼睛看”，所以这里用矩形诊断代替：实测每个关键控件的
##      全局矩形，验证对称性、包含关系、控件读数与随从落点。
##   2. `--script` 模式下根窗口不会套用 project.godot 的分辨率，因此这里显式设置 Main 的尺寸；
##      而且尺寸要按 `canvas_items` + `expand` 的规则换算成 **逻辑画布** 大小——
##      expand 模式下画布永远不小于基准分辨率（1180x860 的窗口对应 1440x1050 的画布）。

const KEY_NODES := [
	"Root/Arena/TopBar",
	"Root/Arena/ArenaPanel",
	"Root/Arena/ActionBar",
	"Root/LogPanel",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHandRow",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHeroBox",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHeroBox/EnemyHeroFrame",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyBoardRow",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/MidLine",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/MidLine/SeamLine",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerBoardRow",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerHeroBox",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerHeroBox/PlayerHeroFrame",
	"Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/HandArea",
]

const ARENA_VBOX := "Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox"
const ENEMY_BOARD := ARENA_VBOX + "/EnemyHalf/EnemyBoardRow"
const PLAYER_BOARD := ARENA_VBOX + "/PlayerHalf/PlayerBoardRow"
const PLAYER_STATUS := ARENA_VBOX + "/PlayerHalf/PlayerHeroBox/PlayerStatusPanel"
const SEAM := ARENA_VBOX + "/MidLine/SeamLine"
const PROBE_CARD := "c001"   ## 见习法师 2/3，用来铺战场

var _fails := 0
var _frames := 0
var _phase := 0
var _main
var _gm
var _window := Vector2i(1440, 900)
var _canvas := Vector2i(1440, 900)
var _below_declared_min := false
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	# 一次性建场（不要与下面的阶段机共用 if/elif 链，否则阶段分支永远走不到）
	if _frames == 1:
		_read_sizes()
		return false
	if _frames == 2:
		var scene = load("res://scenes/Main.tscn")
		if scene == null:
			_check(false, "加载 Main.tscn")
			_finish()
			return true
		_main = scene.instantiate()
		root.add_child(_main)
		return false
	if _frames == 5:
		_main.position = Vector2.ZERO
		_main.size = Vector2(_canvas)
		return false
	if _frames == 10:
		_gm = root.get_node_or_null("GameManager")
		_run()
		_phase = 1
		return false
	if _frames > 900:
		_check(false, "测试超时")
		_finish()
		return true

	# 回合流转 → 敌方回合界面状态 → 交回我方 → 落点对齐（两种奇偶 + 上下半场）
	match _phase:
		1:
			if _gm != null and not _gm.busy and _gm.current_player == 0:
				_gm.end_turn()
				_phase = 2
		2:
			if _gm != null and _gm.busy:
				_phase = 3
		3:
			_check(_banner_text() == "敌方回合",
				"对手回合时横幅提示「敌方回合」（实际 %s）" % _banner_text())
			_check(_main.end_turn_button.disabled, "对手回合时「结束回合」按钮被禁用")
			_phase = 4
		4:
			# 界面刷新是每帧合并一次的，AI 交回控制权后要等下一帧才能看到横幅 / 按钮更新
			if _gm != null and not _gm.busy:
				_phase = 5
		5:
			_check(_banner_text() == "我方回合", "交回我方时横幅提示「我方回合」（实际 %s）" % _banner_text())
			_check(not _main.end_turn_button.disabled, "轮到我方时「结束回合」按钮恢复可用")
			# 我方 3 个（奇数）+ 敌方 2 个（偶数）：一次覆盖两种奇偶与两种纵向贴边
			_set_board_count(0, 3)
			_set_board_count(1, 2)
			_phase = 6
		6:
			_check_slot_alignment(PLAYER_BOARD, 0, 3)
			_check_slot_alignment(ENEMY_BOARD, 1, 2)
			_set_board_count(0, 2)   # 我方也试偶数，确认不再错开半格
			_phase = 7
		7:
			_check_slot_alignment(PLAYER_BOARD, 0, 2)
			# 横置一个随从，下一帧再量它的落点（容器要等一帧才会重新排布子节点）
			_gm.place_in_front(0, _gm.get_player(0).board[0].unit_id)
			_main._refresh()
			_phase = 8
		8:
			_check_front_slot_geometry()
			_check_slot_placement_ui()
			_phase = 9
		9:
			_check_slot_placement_cells()
			# 伤害后界面必须跟着刷新（血量徽章），并且飘字锚点落在目标身上
			_gm.deal_damage_to_hero(null, 1, 5)
			_phase = 10
		10:
			_check_damage_feedback()
			_finish()
	return false


## 横置随从在真实一帧排布后的落点：应在每行正中那一格，且后排随从全部避开它
func _check_front_slot_geometry() -> void:
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	var front: BoardUnit = _gm.front_unit(0)
	_check(pb != null and front != null, "横置随从与战场行都可用")
	if pb == null or front == null:
		return
	var ui: UnitUI = null
	var cell: Control = null
	for s in _board_slots(pb):
		if s["ui"] != null and s["ui"].unit.unit_id == front.unit_id:
			ui = s["ui"]
			cell = s["cell"]
	_check(ui != null and cell != null, "横置的随从有对应控件")
	if ui == null:
		return
	_check(ui.in_front and absf(ui.rotation - PI * 0.5) < 0.01,
		"横置随从画成横放（旋转 %.0f°）" % rad_to_deg(ui.rotation))
	var center_local: Vector2 = cell.position + cell.size * 0.5
	var want_local: Vector2 = pb.front_slot_rect().get_center()
	_check(center_local.distance_to(want_local) < 1.5,
		"横置随从落在正中那一格（偏差 %.1fpx）" % center_local.distance_to(want_local))
	for s in _board_slots(pb):
		if s["ui"] == null or s["ui"].unit.unit_id == front.unit_id:
			continue
		var lane: int = _main.back_lane_of(0, s["ui"].unit.unit_id)
		_check(not pb.is_front_lane(lane), "后排随从「%s」不占横置格（第 %d 格）" % [s["ui"].unit.data.card_name, lane + 1])


# ------------------------------ 指定格子放置（用户需求） ------------------------------
#
# 「随从与城邦卡使用时可以指定放置到己方场上的具体格子；死亡留下的空位保留、
#  后面的随从不会自动补位。」规则层已在 board_order_test 覆盖，这里量**界面层**：
# 落点判定 → 出牌 → 控件确实落在那一格里，以及拖拽指向的格子会高亮。

var _slot_placed: BoardUnit = null
var _slot_kept0: BoardUnit = null
var _slot_kept1: BoardUnit = null

func _check_slot_placement_ui() -> void:
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	if pb == null:
		_check(false, "我方战场行可用（指定格子）")
		return
	_gm.new_game()
	_main.skip_mulligan()
	var me: PlayerState = _gm.get_player(0)
	me.max_mana = 10
	me.mana = 10
	# 先占住第 1 / 2 格，方便验证「下一位补最早空位」
	_slot_kept0 = _gm.summon_unit(0, _gm.card_by_id("c001"), 0)
	_slot_kept1 = _gm.summon_unit(0, _gm.card_by_id("c002"), 1)
	_main._refresh()

	# 落点判定：拖到第 5 格的矩形中心 → kind=board / slot=4
	var pt: Vector2 = pb.global_position + pb.slot_rect(4).get_center()
	var drop: Dictionary = _main._drop_target_at(pt)
	_check(str(drop.get("kind", "")) == "board" and int(drop.get("slot", -1)) == 4,
		"拖到第 5 格时落点回传 slot=4（实际 %s）" % str(drop))

	# 出牌：手里一张随从 → 指定放进第 5 格
	me.hand.clear()
	me.hand.append(_gm.card_by_id("c006").clone())
	_main._refresh()
	_check(_gm.request_play(0, -1, -1, false, 4), "指定第 5 格出牌成功")
	_main._refresh()
	_slot_placed = _gm.board_slot(0, 4)
	_check(_slot_placed != null and _slot_placed.data.id == "c006", "随从落在指定的第 5 格")
	_check(_gm.slot_of_unit(_slot_placed) == 4, "slot_of_unit 指向第 5 格")

	# 指向已占用的格子：落点判定为「不可放」，高亮显示为红
	var occ: Vector2 = pb.global_position + pb.slot_rect(0).get_center()
	var drop2: Dictionary = _main._drop_target_at(occ)
	_main.drag_kind = _main.DragKind.CARD
	_main.drag_index = 0
	_check(not _main._drop_valid(drop2), "指向已被占用的第 1 格时判定为「不可放」")
	_main._show_slot_hover(drop2, false)
	_check(pb.hover_slot == 0 and not pb.hover_ok, "拖拽高亮指向第 1 格并显示为红")
	_main._clear_slot_hover()
	_check(pb.hover_slot == -1, "取消拖拽后高亮清掉")
	_main.drag_kind = _main.DragKind.NONE
	_main.drag_index = -1

	# 阵亡：只清那一格，其它随从不动；下一位随从补进最早的空位
	if _slot_placed != null:
		_gm.deal_damage_to_unit(null, _slot_placed, 999)
		_gm._cleanup_deaths()
		_main._refresh()
	_check(_gm.board_slot(0, 4) == null, "阵亡后第 5 格留成空位（不收紧）")
	_check(_gm.slot_of_unit(_slot_kept0) == 0 and _gm.slot_of_unit(_slot_kept1) == 1,
		"其它随从**没有被挪动**，仍在第 1 / 2 格")
	_gm.summon_unit(0, _gm.card_by_id("c001"))
	_main._refresh()


## 下一帧（容器重排完成后）核对：每个随从控件确实在自己的格子槽里
func _check_slot_placement_cells() -> void:
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	if pb == null:
		return
	var me: PlayerState = _gm.get_player(0)
	for u in me.board:
		var slot: int = _gm.slot_of_unit(u)
		if u.in_city_slot or slot < 0:
			continue
		var cell: Control = _main.unit_cell(0, u.unit_id)
		_check(cell != null and pb.get_child(slot) == cell,
			"「%s」的控件落在第 %d 个格子槽里" % [u.data.card_name, slot + 1])
	# 空洞仍然占着一个槽位（不会被后面的随从顶掉）
	var empty_cell := pb.get_child(4)
	_check(empty_cell != null and empty_cell.get_child_count() == 0, "空的第 5 格仍是空槽（保留空位）")
	var refill: BoardUnit = _gm.board_slot(0, 2)
	_check(refill != null and _main.unit_cell(0, refill.unit_id) == pb.get_child(2),
		"补进第 3 格的随从控件在对应的槽里")


## 伤害反馈：① 掉血后血量徽章立刻刷新；② 飘字锚点落在**对应的那张牌 / 那位主战者**上。
func _check_damage_feedback() -> void:
	var foe: PlayerState = _gm.get_player(1)
	var frame = _main.enemy_hero_frame
	_check(frame.hp_text() == str(foe.hero_hp),
		"主战者掉血后血量徽章当帧刷新（%s vs %s）" % [frame.hp_text(), str(foe.hero_hp)])

	# ① 随从：锚点 = 它所在格子的中心
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	var unit: BoardUnit = _gm.summon_unit(0, _gm.card_by_id("c001"), 5)
	var slot: int = _gm.slot_of_unit(unit)
	var want: Vector2 = pb.global_position + pb.slot_rect(slot).get_center()
	var got: Vector2 = _main.float_anchor(0, unit.unit_id)
	_check(got.distance_to(want) < 2.0,
		"打随从时飘字落在该随从的格子上（第 %d 格，偏差 %.1fpx）" % [slot + 1, got.distance_to(want)])
	var foe_hero_rect: Rect2 = _main.enemy_hero_frame.visual_rect()
	_check(not foe_hero_rect.has_point(got), "打随从时飘字不会画到主战者框上")

	# ② 主战者：锚点落在头像盘内（上下两侧都测）
	for side in [{"pid": 0, "frame": _main.player_hero_frame}, {"pid": 1, "frame": _main.enemy_hero_frame}]:
		var f = side["frame"]
		var disc: Vector2 = f.global_position + f.disc_center_local()
		var anchor: Vector2 = _main.float_anchor(int(side["pid"]), -1)
		_check(anchor.distance_to(disc) <= f.disc_radius(),
			"%s飘字落在主战者头像盘内（离盘心 %.1fpx）" % [
				"我方" if int(side["pid"]) == 0 else "敌方", anchor.distance_to(disc)])


# ------------------------------ 尺寸与建场 ------------------------------

func _read_sizes() -> void:
	_window = _base_size()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("size="):
			var parts: PackedStringArray = arg.substr(5).split("x")
			if parts.size() == 2:
				_window = Vector2i(int(parts[0]), int(parts[1]))
	_canvas = _canvas_for_window(_window)
	# project.godot 声明了窗口最小尺寸，比它还小的窗口用户根本拉不到
	var min_w: int = int(ProjectSettings.get_setting("display/window/size/min_width", 0))
	var min_h: int = int(ProjectSettings.get_setting("display/window/size/min_height", 0))
	_below_declared_min = _window.x < min_w or _window.y < min_h
	if _below_declared_min:
		print("[SKIP] 窗口 %s 低于 project.godot 声明的最小窗口 %dx%d" % [str(_window), min_w, min_h])


func _base_size() -> Vector2i:
	return Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 1440)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 900)))


## 按 project.godot 的 stretch 设置把窗口尺寸换算成逻辑画布尺寸。
## canvas_items + expand：画布 = 窗口 / 较小缩放比，因此永远不小于基准分辨率
## （例如 1180x860 的窗口对应 1440x1050 的画布，内容按 0.819 缩放显示）。
func _canvas_for_window(win: Vector2i) -> Vector2i:
	var base := _base_size()
	var mode: String = str(ProjectSettings.get_setting("display/window/stretch/mode", "disabled"))
	var aspect: String = str(ProjectSettings.get_setting("display/window/stretch/aspect", "keep"))
	if mode == "disabled":
		return win
	var sx := float(win.x) / float(base.x)
	var sy := float(win.y) / float(base.y)
	if aspect == "keep":
		return base
	if aspect == "keep_width":
		return Vector2i(base.x, maxi(base.y, roundi(float(win.y) / sx)))
	if aspect == "keep_height":
		return Vector2i(maxi(base.x, roundi(float(win.x) / sy)), base.y)
	var s := minf(sx, sy)
	return Vector2i(maxi(base.x, roundi(float(win.x) / s)), maxi(base.y, roundi(float(win.y) / s)))


func _set_board_count(pid: int, n: int) -> void:
	var p: PlayerState = _gm.get_player(pid)
	while p.board.size() > n:
		p.board.pop_back()
	while p.board.size() < n:
		_gm.summon_unit(pid, _gm.card_by_id(PROBE_CARD))
	_main._request_refresh()


# ------------------------------ 静态检查 ------------------------------

func _run() -> void:
	print("--- 布局矩形诊断（窗口 %s → 画布 %s）---" % [str(_window), str(_canvas)])
	for path in KEY_NODES:
		var n: Control = _main.get_node_or_null(path)
		if n == null:
			_check(false, "节点存在：%s" % path)
			continue
		var r := n.get_global_rect()
		print("  %-16s pos=(%7.1f,%7.1f)  size=(%6.1f,%6.1f)  end=(%7.1f,%7.1f)" % [
			n.name, r.position.x, r.position.y, r.size.x, r.size.y,
			r.position.x + r.size.x, r.position.y + r.size.y
		])
	_check_window_applied()
	_report_min_sizes()
	_check_no_overflow()
	_check_mirror()
	_check_status_widgets()
	_check_city_slots()
	_check_turn_control()
	_check_tracker_button()
	_check_tracker_drawer()
	_check_board_slots()
	_check_turn_banner()
	_check_concede()
	_check_hand_dock()
	_check_enemy_hand()
	_check_front_slot_ui()


func _check_window_applied() -> void:
	if _below_declared_min:
		return
	# 目标尺寸必须能被满足：Main 的最小尺寸不能超过画布，否则界面上一定会被裁切
	var min_size: Vector2 = _main.get_combined_minimum_size()
	_check(min_size.x <= float(_canvas.x) + 0.5 and min_size.y <= float(_canvas.y) + 0.5,
		"界面最小尺寸 %s 不超过画布 %s" % [str(min_size), str(_canvas)])
	_check(absf(_main.size.x - float(_canvas.x)) < 0.5 and absf(_main.size.y - float(_canvas.y)) < 0.5,
		"主界面已按画布尺寸排布（%s）" % str(_main.size))


## 打印各层容器的最小尺寸：画布被“撑大”时，就是这里某一层的 min 超过了画布
func _report_min_sizes() -> void:
	print("  Main   size=%s  min=%s" % [str(_main.size), str(_main.get_combined_minimum_size())])
	for path in ["Root", "Root/Arena", "Root/Arena/TopBar", "Root/Arena/ArenaPanel",
			ARENA_VBOX, ARENA_VBOX + "/EnemyHalf", ARENA_VBOX + "/PlayerHalf",
			ARENA_VBOX + "/EnemyHalf/EnemyHeroBox", "Root/Arena/ActionBar", "Root/LogPanel"]:
		var n: Control = _main.get_node_or_null(path)
		if n == null:
			continue
		print("  %-34s size=%-18s min=%s" % [path.replace("Root/Arena/ArenaPanel/ArenaMargin/", "…"),
			str(n.size), str(n.get_combined_minimum_size())])


func _check_no_overflow() -> void:
	if _below_declared_min:
		return
	var canvas: Vector2 = Vector2(_canvas)
	var bad: Array[String] = []
	for path in KEY_NODES:
		var n: Control = _main.get_node_or_null(path)
		if n == null:
			continue
		var r := n.get_global_rect()
		if r.position.x < -0.5 or r.position.y < -0.5 \
				or r.position.x + r.size.x > canvas.x + 0.5 or r.position.y + r.size.y > canvas.y + 0.5:
			bad.append("%s end=(%.1f,%.1f)" % [n.name, r.position.x + r.size.x, r.position.y + r.size.y])
	_check(bad.is_empty(), "所有关键控件都在画布内（%s）" % ["ok" if bad.is_empty() else ", ".join(bad)])


## 上下半场关于中线严格互为镜像：两个战场行到接缝的距离必须相等
func _check_mirror() -> void:
	var seam: Control = _main.get_node_or_null(SEAM)
	var eb: Control = _main.get_node_or_null(ENEMY_BOARD)
	var pb: Control = _main.get_node_or_null(PLAYER_BOARD)
	if seam == null or eb == null or pb == null:
		_check(false, "镜像核对所需的节点齐全")
		return
	var mid: float = seam.get_global_rect().get_center().y
	var er := eb.get_global_rect()
	var pr := pb.get_global_rect()
	var gap_enemy: float = mid - (er.position.y + er.size.y)
	var gap_player: float = pr.position.y - mid
	_check(absf(gap_enemy - gap_player) < 1.0,
		"两侧战场到中线接缝距离相等（敌 %.1fpx / 我 %.1fpx）" % [gap_enemy, gap_player])
	var arena: Control = _main.get_node_or_null("Root/Arena/ArenaPanel")
	if arena != null:
		var ac: float = arena.get_global_rect().get_center().x
		_check(absf(er.get_center().x - ac) < 1.0 and absf(pr.get_center().x - ac) < 1.0,
			"两侧战场相对场地水平居中（场地中线 %.1f）" % ac)


## 城邦格（主战者旁的那一格）：两侧各一个、与主战者框同横带、不压框也不越界；
## 放上城邦后格子里的控件显示名字与耐久。
func _check_city_slots() -> void:
	var arena: Control = _main.get_node_or_null("Root/Arena/ArenaPanel")
	var arena_rect: Rect2 = arena.get_global_rect() if arena != null else Rect2()
	var me_band: Control = _main.player_city_slot
	var foe_band: Control = _main.enemy_city_slot
	_check(me_band != null and foe_band != null, "上下两侧都有城邦格节点")
	if me_band == null or foe_band == null:
		return
	_check(me_band.get_global_rect().size.x > 100.0 and me_band.get_global_rect().size.y >= 40.0,
		"城邦格尺寸合理（%.0f x %.0f）" % [me_band.get_global_rect().size.x, me_band.get_global_rect().size.y])
	for info in [{"band": me_band, "frame": _main.player_hero_frame, "label": "我方"},
			{"band": foe_band, "frame": _main.enemy_hero_frame, "label": "敌方"}]:
		var band: Control = info["band"]
		# 不要静态标注 HeroFrame：工具脚本连编译 HeroFrame.gd 时它引用的自动加载解析不了
		var frame = info["frame"]
		var br := band.get_global_rect()
		var band_of_frame: Rect2 = frame.get_global_rect()
		_check(arena_rect.encloses(br), "%s城邦格落在竞技区内" % info["label"])
		_check(not frame.visual_rect().intersects(br), "%s城邦格不压主战者框" % info["label"])
		_check(absf(br.get_center().y - band_of_frame.get_center().y) < 10.0,
			"%s城邦格与主战者框同横带（差 %.1fpx）" % [info["label"], absf(br.get_center().y - band_of_frame.get_center().y)])
	# 两侧都在主战者**左侧**（镜像不再左右对称，但位置一致）
	_check(me_band.get_global_rect().get_center().x < _main.player_hero_frame.get_global_rect().get_center().x,
		"我方城邦格在主战者框左侧")
	_check(foe_band.get_global_rect().get_center().x < _main.enemy_hero_frame.get_global_rect().get_center().x,
		"敌方城邦格在主战者框左侧")
	# 不能压到状态信息框（我方在左、敌方在右）
	var me_panel: Control = _main.get_node_or_null(PLAYER_STATUS)
	if me_panel != null:
		_check(not me_panel.get_global_rect().intersects(me_band.get_global_rect()),
			"我方城邦格不压状态信息框（框 %s / 格 %s）" % [str(me_panel.get_global_rect()), str(me_band.get_global_rect())])
	# 放一个城邦进去：控件显示名字与耐久
	var ui: CitySlotUI = _main.city_slot_widget(0)
	_check(ui != null and ui.unit == null, "城邦格一开始是空的（显示占位）")
	_gm.summon_city_into_slot(0, _gm.card_by_id("y001"), "测试放")
	_main._refresh()
	var ui2: CitySlotUI = _main.city_slot_widget(0)
	_check(ui2 != null and ui2.unit != null, "放上城邦后控件绑定到它")
	_check(ui2 != null and ui2.find_child("*", true, false) != null, "城邦格控件内部有显示节点")
	var city: BoardUnit = _gm.city_slot_unit(0)
	_check(city != null and city.health == _gm.card_by_id("y001").durability(),
		"城邦格里的城邦耐久正确（%d）" % (0 if city == null else city.health))
	_check(_gm.board_size_used(0) == 0, "城邦格里的城邦不占 7 格战场（占用 %d）" % _gm.board_size_used(0))


## 主战者框（上下正中：圆盘 + 血量 / 护甲徽章 + 敌方 PP 珠）
## 与状态信息框（竞技区角上：敌方右上、我方左下，2×2 计数格）
func _check_status_widgets() -> void:
	var me: PlayerState = _gm.get_player(0)
	var foe: PlayerState = _gm.get_player(1)
	var arena: Control = _main.get_node_or_null("Root/Arena/ArenaPanel")
	var arena_rect: Rect2 = arena.get_global_rect() if arena != null else Rect2()
	var arena_center: float = arena_rect.get_center().x
	var seam: Rect2 = _main.mid_seam.get_global_rect()

	for side in [
			{"name": "我方", "frame": ARENA_VBOX + "/PlayerHalf/PlayerHeroBox/PlayerHeroFrame",
				"panel": ARENA_VBOX + "/PlayerHalf/PlayerHeroBox/PlayerStatusPanel",
				"p": me, "want_orbs": false, "panel_side": "left"},
			{"name": "敌方", "frame": ARENA_VBOX + "/EnemyHalf/EnemyHeroBox/EnemyHeroFrame",
				"panel": ARENA_VBOX + "/EnemyHalf/EnemyHeroBox/EnemyStatusPanel",
				"p": foe, "want_orbs": true, "panel_side": "right"}]:
		var frame: Variant = _main.get_node_or_null(side["frame"])
		_check(frame != null, "%s主战者框存在" % side["name"])
		if frame == null:
			continue
		var p: PlayerState = side["p"]

		# 位置：水平居中对齐竞技区，圆盘不许压到中线
		_check(absf(frame.get_global_rect().get_center().x - arena_center) < 1.0,
			"%s主战者框水平居中于场地（偏差 %.1fpx）" % [
				side["name"], absf(frame.get_global_rect().get_center().x - arena_center)])
		var vr: Rect2 = frame.visual_rect()
		_check(not vr.intersects(seam),
			"%s主战者框不覆盖中线接缝（框底 %.0f，接缝 %.0f）" % [side["name"], vr.position.y + vr.size.y, seam.position.y])
		_check(vr.size.x > frame.disc_radius() * 2.0, "%s主战者框的绘制范围包含血量徽章" % side["name"])

		# 圆形命中：圆心在框内、矩形四角在框外（四角让给底下的卡牌）
		var center_g: Vector2 = frame.global_position + frame.disc_center_local()
		_check(frame.contains_global_point(center_g), "%s主战者框圆心可点击（＝可以打英雄）" % side["name"])
		var corner: Vector2 = frame.global_position + Vector2(4, 4)
		_check(not frame.contains_global_point(corner, 0.0),
			"%s主战者框四角不拦截鼠标（让给底下的卡牌）" % side["name"])

		# 读数：血量 / 护甲（计数已移到独立信息框）
		_check(frame.hp_text() == str(p.hero_hp),
			"%s血量读数正确：%s（期望 %d）" % [side["name"], frame.hp_text(), p.hero_hp])
		var keep_armor: int = p.armor
		p.armor = 3
		frame.update_state(p)
		_check(frame.armor_text() == "3" and frame.armor_visible(),
			"%s有护甲时显示徽章数值（%s）" % [side["name"], frame.armor_text()])
		p.armor = 0
		frame.update_state(p)
		_check(not frame.armor_visible(), "%s护甲归零后徽章隐藏" % side["name"])
		p.armor = keep_armor
		frame.update_state(p)

		# PP 珠：敌方显示、我方不显示（我方的能量点在回合按钮周围的那一圈）
		if side["want_orbs"]:
			_check(frame.mana_orb_count() == _gm.MAX_MANA,
				"%s PP 珠为 %d 颗（实际 %d）" % [side["name"], _gm.MAX_MANA, frame.mana_orb_count()])
			frame.update_state(p)
			_check(frame.mana_text() == "%d/%d" % [p.mana, p.max_mana],
				"%s能量点读数正确：%s（期望 %d/%d）" % [side["name"], frame.mana_text(), p.mana, p.max_mana])
		else:
			_check(frame.mana_orb_count() == 0, "%s主战者框不重复显示能量点" % side["name"])

		# 高亮开关（可被指定为目标时）
		frame.set_highlight(true)
		_check(frame.is_highlighted(), "%s可被指定为目标时高亮" % side["name"])
		frame.set_highlight(false)
		_check(not frame.is_highlighted(), "%s不可指定时取消高亮" % side["name"])

		# ---- 状态信息框：竞技区角上，不与圆盘重叠，读数正确 ----
		var panel: Variant = _main.get_node_or_null(side["panel"])
		_check(panel != null, "%s状态信息框存在" % side["name"])
		if panel == null:
			continue
		var pr: Rect2 = panel.get_global_rect()
		_check(arena_rect.encloses(pr), "%s状态信息框在竞技区内（%s ⊂ %s）" % [side["name"], str(pr), str(arena_rect)])
		if side["panel_side"] == "right":
			_check(pr.position.x + pr.size.x > arena_center, "%s信息框在竞技区右上（靠右）" % side["name"])
		else:
			_check(pr.position.x < arena_center, "%s信息框在竞技区左下（靠左）" % side["name"])
		_check(not pr.intersects(frame.visual_rect()), "%s信息框不压住主战者框" % side["name"])
		_check(panel.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"%s信息框不吃鼠标事件（底下的卡牌照常操作）" % side["name"])

		var keep_deck: int = p.deck.size()
		var keep_grave: int = p.graveyard.size()
		panel.update_state(p, _gm.HAND_LIMIT)
		_check(panel.deck_text() == "牌%d" % keep_deck, "%s牌库计数正确：%s" % [side["name"], panel.deck_text()])
		_check(panel.hand_text() == "手%d" % p.hand.size(), "%s手牌计数正确：%s" % [side["name"], panel.hand_text()])
		_check(panel.grave_text() == "墓%d" % keep_grave, "%s墓地计数正确：%s" % [side["name"], panel.grave_text()])
		_check(panel.fatigue_text() == "疲%d" % p.fatigue, "%s疲劳计数正确：%s" % [side["name"], panel.fatigue_text()])


## 手牌：默认停靠右侧（给下方正中的主战者框让位），选牌 / 选目标期间滑到下方正中
func _check_hand_dock() -> void:
	var me: PlayerState = _gm.get_player(0)
	_gm.new_game()
	_main.skip_mulligan()
	me = _gm.get_player(0)
	me.max_mana = 10
	me.mana = 10
	_main.hand_slide_time = 0.0          # 无头模式的帧步长不可控，直接到位
	_main._clear_mode()
	_main._refresh()

	# 照原版《影之诗》的手牌两态（Unfocus / Focus，见 docs/shadowverse-battle-ui.md §13.2）：
	# 常态＝贴右侧的平直牌带；选牌 / 选目标＝整条抬起、张开并右移到中央偏右。
	var u: float = _main.CARD_W / _main.SV_CARD_UNITS
	_check(_main.hand_resting(), "空闲时手牌处于常态（原版 Unfocus）")
	_check(absf(_main.hand_lift()) < 0.01, "常态不抬起（抬起量 %.1f）" % _main.hand_lift())
	var area_w: float = _main.hand_area.size.x
	var docked := _hand_layout_rect()
	_check(absf(docked.position.x + docked.size.x - (area_w - _main.HAND_DOCK_MARGIN)) < 2.0,
		"手牌右缘贴手牌区右边缘（%.1f vs %.1f）" % [
			docked.position.x + docked.size.x, area_w - _main.HAND_DOCK_MARGIN])
	_check(docked.get_center().x > area_w * 0.5 + 40.0,
		"常态位置确实偏右、给正中让出空间（手牌中心 %.0f > 场地中心 %.0f）" % [
			docked.get_center().x, area_w * 0.5])
	# 常态：牌带宽度 = 0.7 × min(卡宽×(n−1), 3.5×卡宽)（叠压下限只影响极端张数）
	var n: int = me.hand.size()
	var want_spread: float = maxf(_main.SV_SPREAD_RATIO * minf(_main.CARD_W * float(n - 1),
		_main.SV_SPREAD_MAX_CARDS * _main.CARD_W), _main.SV_MIN_VISIBLE * float(n - 1))
	_check(absf(docked.size.x - (want_spread + _main.CARD_W)) < 3.0,
		"常态铺开宽度照原版 0.7×W（%.0f vs %.0f）" % [docked.size.x, want_spread + _main.CARD_W])
	# 手牌必须**完全落在手牌区内**（底边对齐下缘、外圈抬起但不出框）：
	# 之前纵轴多减了半张牌高，整条手牌被抬高 85px，直接顶进抽牌堆 —— 于是「牌堆压住手牌」。
	var area := Rect2(Vector2.ZERO, _main.hand_area.size)
	_check(area.grow(1.0).encloses(docked),
		"手牌完全落在手牌区内（%s ⊂ %s）" % [str(docked), str(area)])
	_check(absf(docked.end.y - area.end.y) < 10.0,
		"手牌底边贴着手牌区下缘（底 %.0f vs 区底 %.0f）" % [docked.end.y, area.end.y])

	# 选一张需要目标的牌 → 进入选目标状态 → 整条抬起并移到中央偏右（原版放大态）
	var idx := _playable_target_card_index(me)
	_check(idx >= 0, "手里有需要目标的牌（用于验证放大态）")
	if idx < 0:
		return
	_main._on_hand_card_clicked(idx)
	_main._refresh()
	_check(not _main.hand_resting(), "选牌后手牌离开常态")
	var mid := _hand_layout_rect()
	var want_center: float = area_w * 0.5 + _main.SV_FOCUS_OFFSET_UNITS * u
	_check(absf(mid.get_center().x - want_center) < 2.0,
		"放大态移到中央偏右（偏差 %.1fpx；原版 +130 局部单位 = %.0f px）" % [
			absf(mid.get_center().x - want_center), _main.SV_FOCUS_OFFSET_UNITS * u])
	_check(_main.hand_lift() > 10.0, "放大态整条抬起（抬起量 %.1fpx）" % _main.hand_lift())
	_check(mid.get_center().x < docked.get_center().x,
		"放大态比常态更靠中（%.0f < %.0f）" % [mid.get_center().x, docked.get_center().x])

	# 取消选择 → 回到常态
	_main._clear_mode()
	_main._refresh()
	_check(_main.hand_resting(), "取消选择后手牌回到常态")

	# 点一张「现在打不出」的牌：整条手牌同样摊开展示（本轮新增 —— 玩家点牌就是想看清手牌）
	me.mana = 0
	_main._on_hand_card_clicked(0)
	_main._refresh()
	_check(not _main.hand_resting(), "点一张打不出的牌也会把手牌摊开")
	var peek := _hand_layout_rect()
	_check(absf(peek.get_center().x - want_center) < 2.0, "摊开时与放大态同一套位置（偏差 %.1fpx）" % absf(peek.get_center().x - want_center))
	_main._clear_mode()
	_main._refresh()
	_check(_main.hand_resting(), "取消后手牌收回常态（摊开不是永久状态）")
	me.mana = 10
	var back := _hand_layout_rect()
	_check(absf(back.position.x + back.size.x - (area_w - _main.HAND_DOCK_MARGIN)) < 2.0,
		"回到常态后仍贴右边缘（%.1f vs %.1f；手牌张数可能变过，按当前布局核对）" % [
			back.position.x + back.size.x, area_w - _main.HAND_DOCK_MARGIN])


## 敌方手牌：摆在左上角（参考影之诗——对手的牌在左上、主战者框在正中），
## 且只占左半边，不压到正中圆盘；与我方「停靠右侧」的手牌左右呼应。
func _check_enemy_hand() -> void:
	var row: Control = _main.enemy_hand_row
	var backs: Array = _main.enemy_hand_cards
	_check(not backs.is_empty(), "敌方手牌卡背已生成")
	if backs.is_empty():
		return
	var min_x := INF
	var max_x := -INF
	# 用布局位置（局部坐标、不含扇形旋转）核对“靠左起排”：旋转后的外接矩形会往外扩几像素
	for b in backs:
		min_x = minf(min_x, b.position.x)
		max_x = maxf(max_x, b.position.x + b.size.x)
	var row_rect: Rect2 = row.get_global_rect()
	_check(absf(min_x - _main.ENEMY_HAND_MARGIN) < 2.0,
		"敌方手牌从左上角起排（左缘 %.0f，期望 %.0f）" % [min_x, _main.ENEMY_HAND_MARGIN])
	_check(max_x < row.get_size().x * 0.5, "敌方手牌只占左半边、不居中（右缘 %.0f）" % max_x)
	var frame: Variant = _main.enemy_hero_frame
	var disc_left_global: float = frame.global_position.x + frame.disc_center_local().x - frame.disc_radius()
	var hand_right_global: float = row_rect.position.x + max_x
	_check(hand_right_global < disc_left_global,
		"敌方手牌不压住主战者框的圆盘（%.0f < %.0f）" % [hand_right_global, disc_left_global])


## 横置格（中线前那一格）：正中那一格画成横置位，进去的随从渲染在正中并旋转 90°，
## 后排随从全部跳过这一格。
func _check_front_slot_ui() -> void:
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	if pb == null:
		_check(false, "我方战场行可用（横置格）")
		return
	_gm.new_game()
	_main.skip_mulligan()
	var me: PlayerState = _gm.get_player(0)
	var a: BoardUnit = _gm.summon_unit(0, _gm.card_by_id("c001"))
	var b: BoardUnit = _gm.summon_unit(0, _gm.card_by_id("c002"))
	var c: BoardUnit = _gm.summon_unit(0, _gm.card_by_id("c004"))
	var f: BoardUnit = _gm.summon_unit(0, _gm.card_by_id("c001"))
	_check(me.board.size() == 4, "横置用例铺了 4 个随从")
	_gm.place_in_front(0, f.unit_id)
	_main._refresh()

	_check(pb.front_lane() == pb.slot_limit / 2, "横置格在每行正中（第 %d 格）" % (pb.front_lane() + 1))
	_check(not pb.back_lanes().has(pb.front_lane()), "后排格子列表不含横置格")
	_check(pb.back_lanes().size() == pb.slot_limit - 1,
		"横置格之外还有 %d 个后排格子" % pb.back_lanes().size())

	var front_ui: UnitUI = null
	for s in _board_slots(pb):
		if s["ui"] != null and s["ui"].unit.unit_id == f.unit_id:
			front_ui = s["ui"]
	_check(front_ui != null, "横置的随从有对应控件")
	if front_ui != null:
		_check(front_ui.in_front and absf(front_ui.rotation - PI * 0.5) < 0.01,
			"横置随从画成横放（旋转 %.0f°）" % rad_to_deg(front_ui.rotation))
		# 落点几何放到相位里量（容器要等一帧才会重排子节点，见 _check_front_slot_geometry()）

	for u in [a, b, c]:
		if u == null:
			continue
		var lane: int = _main.back_lane_of(0, u.unit_id)
		_check(lane >= 0 and not pb.is_front_lane(lane),
			"后排随从「%s」跳过横置格（落在第 %d 格）" % [u.data.card_name, lane + 1])
	_check(_gm.front_unit(0) == f, "横置状态只作用于进格的那个随从")

	# ---- 防御格调整：拖回我方后排 = 移出；一回合只能移入或移出一次 ----
	# 先把本回合的名额复位（上面用 place_in_front 移入已经用掉了一次）
	me.front_move_turn = -1
	var back_slot: int = pb.back_lanes()[0]
	var drop := {"kind": "board", "player_id": 0, "unit_id": -1, "slot": back_slot,
		"rect": pb.get_global_rect()}
	_main.drag_kind = 2   # Main.DragKind.ATTACK（枚举 NONE=0 / CARD=1 / ATTACK=2）
	_main.drag_unit = f.unit_id
	_check(_main._drop_valid(drop), "拖到我方后排：防御格里的随从可以移出（落点合法）")
	_main._finish_attack_drag(drop)
	_main._end_drag()
	_check(not f.in_front, "拖到后排后随从离开防御格")
	_check(_gm.front_unit(0) == null, "防御格空出来了")
	_check(_main.back_lane_of(0, f.unit_id) >= 0, "移出后它落在后排格子（第 %d 格）" % (_main.back_lane_of(0, f.unit_id) + 1))
	_check(me.front_move_turn == _gm.turn_count, "移出用掉了本回合唯一的调整名额")

	# 同一回合再把它拖回防格 → 落点不合法 + 有原因提示
	_main.drag_kind = 2   # Main.DragKind.ATTACK（枚举 NONE=0 / CARD=1 / ATTACK=2）
	_main.drag_unit = f.unit_id
	var front_drop := {"kind": "front", "player_id": 0, "unit_id": f.unit_id, "rect": pb.front_slot_rect()}
	_check(not _main._drop_valid(front_drop), "同一个回合内不能再移入（落点不合法）")
	_check(_gm.front_move_blocked_reason(0).contains("一回合"), "给出「一回合只能一次」的原因")

	# 后排随从拖到我方后排 = 无意义操作（只有防御格里的随从能这样移动）
	_main.drag_kind = 2   # Main.DragKind.ATTACK（枚举 NONE=0 / CARD=1 / ATTACK=2）
	_main.drag_unit = a.unit_id
	_check(not _main._drop_valid(drop), "后排随从拖到后排不是合法落点（不能随便挪格子）")
	_main._end_drag()
func _hand_layout_rect() -> Rect2:
	var rect := Rect2()
	var first := true
	for ui in _main.hand_cards:
		if ui == null or not is_instance_valid(ui):
			continue
		var r := Rect2(ui.position, ui.size)
		if first:
			rect = r
			first = false
		else:
			rect = rect.merge(r)
	return rect


## 手里第一张「需要目标」且付得起的牌；优先选择任何角色都能指定的牌（保证一定有合法目标）
func _playable_target_card_index(me: PlayerState) -> int:
	for i in me.hand.size():
		var c: CardData = me.hand[i]
		if c.needs_target() and c.cost <= me.mana and c.target == CardData.Targeting.ANY_CHARACTER:
			return i
	var db = root.get_node_or_null("CardDB")
	if db == null:
		return -1
	for c in db.cards:
		if c.needs_target() and not c.is_token and c.cost <= me.mana and c.target == CardData.Targeting.ANY_CHARACTER:
			me.hand.append(c.clone())
			_main._refresh()
			return me.hand.size() - 1
	return -1


## 影之诗风格的回合控件：圆形按钮 + 按钮内的回合数 + 环绕的能量点，位于中线右端
func _check_turn_control() -> void:
	var tc: TurnControl = _main.turn_control
	_check(tc != null and is_instance_valid(tc), "回合控件存在")
	if tc == null or not is_instance_valid(tc):
		return
	_check(_main.end_turn_button == tc.button, "结束回合按钮指向圆形回合按钮")

	# 圆形：按钮是正方形，且圆角半径 = 半径
	var bs: Vector2 = tc.button.size
	var sb: StyleBoxFlat = tc.button.get_theme_stylebox("normal")
	_check(absf(bs.x - bs.y) < 0.5, "结束回合按钮为正方形（%.0f×%.0f）" % [bs.x, bs.y])
	_check(sb != null and sb.corner_radius_top_left == tc.corner_radius(),
		"圆角半径等于半径 → 正圆（%d / %d）" % [
			sb.corner_radius_top_left if sb != null else -1, tc.corner_radius()])

	# 位置：贴在中线右端、垂直居中于接缝、落在战场槽位右侧的空白条里
	var seam: Rect2 = _main.mid_seam.get_global_rect()
	var rect: Rect2 = tc.get_global_rect()
	_check(absf(rect.get_center().y - seam.get_center().y) < 1.0,
		"回合控件垂直居中于中线（偏差 %.1fpx）" % absf(rect.get_center().y - seam.get_center().y))
	_check(absf((rect.position.x + rect.size.x) - (seam.position.x + seam.size.x)) < 1.0,
		"回合控件贴在中线右端（右侧对齐）")
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	if pb != null:
		var total: float = 114.0 * float(pb.slot_limit) - 10.0
		var row: Rect2 = pb.get_global_rect()
		var slot_right: float = row.position.x + (row.size.x + total) * 0.5
		_check(rect.position.x >= slot_right,
			"回合控件在战场槽位右侧、不压住随从（%.0f ≥ %.0f）" % [rect.position.x, slot_right])

	# 按钮里显示回合数
	_check(tc.turn_text() == str(_gm.turn_count), "按钮内显示当前回合数（%s）" % tc.turn_text())

	# 环上的能量点：数量与三态都要对
	_check(tc.orb_count() == _gm.MAX_MANA,
		"按钮周围环绕 %d 颗能量点（实际 %d）" % [_gm.MAX_MANA, tc.orb_count()])
	var me: PlayerState = _gm.get_player(0)
	var keep_mana: int = me.mana
	var keep_max: int = me.max_mana
	me.max_mana = 6
	me.mana = 3
	_main._update_turn_control(me, true)
	var ready := 0
	var spent := 0
	var locked := 0
	for orb in tc.orb_panels():
		var st: StyleBoxFlat = orb.get_theme_stylebox("panel")
		if st == ManaOrbs.style_for("ready"):
			ready += 1
		elif st == ManaOrbs.style_for("spent"):
			spent += 1
		elif st == ManaOrbs.style_for("locked"):
			locked += 1
	_check(ready == 3 and spent == 3 and locked == 4,
		"环上水晶状态与法力一致（可用 %d / 已花费 %d / 未解锁 %d，期望 3/3/4）" % [ready, spent, locked])
	me.mana = keep_mana
	me.max_mana = keep_max
	_main._update_turn_control(me, true)


func _check_board_slots() -> void:
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	var eb: BoardSurface = _main.get_node_or_null(ENEMY_BOARD)
	if pb == null or eb == null:
		_check(false, "战场行挂了 BoardSurface 脚本")
		return
	_check(pb.slot_limit == _gm.BOARD_LIMIT and eb.slot_limit == _gm.BOARD_LIMIT,
		"战场固定 %d 个槽位" % _gm.BOARD_LIMIT)
	_check(pb.caption == "我方战场" and eb.caption == "敌方战场", "两侧战场标题正确（%s / %s）" % [pb.caption, eb.caption])


## 随从落点必须与画出来的槽位逐格对齐（偶数个随从时最容易错开半格）
func _check_slot_alignment(board_path: String, pid: int, n: int) -> void:
	var pb: BoardSurface = _main.get_node_or_null(board_path)
	if pb == null:
		_check(false, "战场行可用（%s）" % board_path)
		return
	_check(pb.slot_used == n, "%s %d 个随从时地面计数同步（实际 %d）" % [pb.caption, n, pb.slot_used])
	var slots := _board_slots(pb)
	var minions: Array = []
	for s in slots:
		if s["ui"] != null:
			minions.append(s)
	_check(minions.size() == n, "%s %d 个随从时控件数量正确（实际 %d）" % [pb.caption, n, minions.size()])
	if minions.size() != n or n <= 0:
		return
	# 随从按「除横置格之外的后排格子」整体居中：落点直接问 Main 取（与布局同一来源）。
	# 量的是“格子”（普通 Control，容器给的位置可靠），随从控件就铺在格子里面。
	var worst_x := 0.0
	var worst_y := 0.0
	for j in minions.size():
		var cell: Control = minions[j]["cell"]
		var ui: UnitUI = minions[j]["ui"]
		var lane: int = _main.back_lane_of(pid, ui.unit.unit_id)
		if lane < 0:
			_check(false, "%s 第 %d 个随从有对应的后排格子" % [pb.caption, j + 1])
			return
		_check(not pb.is_front_lane(lane), "%s 后排随从不会落在正中横置格（第 %d 个在第 %d 格）" % [pb.caption, j + 1, lane])
		var want := pb.slot_rect(lane)
		worst_x = maxf(worst_x, absf(cell.position.x - want.position.x))
		worst_x = maxf(worst_x, absf(cell.size.x - want.size.x))
		worst_y = maxf(worst_y, absf(cell.position.y - want.position.y))
		worst_y = maxf(worst_y, absf(cell.size.y - want.size.y))
	_check(worst_x < 1.0, "%s %d 个随从时水平落点与槽位对齐（最大偏差 %.1fpx）" % [pb.caption, n, worst_x])
	_check(worst_y < 1.0, "%s %d 个随从时纵向与槽位贴合（最大偏差 %.1fpx）" % [pb.caption, n, worst_y])


## 战场行的“格子”列表：[{cell, ui}]，空槽的 ui 为 null。
## 随从控件装在格子里（普通 Control），所以不能直接遍历行的子节点找 UnitUI。
func _board_slots(board: BoardSurface) -> Array:
	var out := []
	for child in board.get_children():
		if child.is_queued_for_deletion() or child is UnitUI:
			continue
		var ui: UnitUI = null
		for sub in child.get_children():
			if sub is UnitUI and not sub.is_queued_for_deletion():
				ui = sub
		out.append({"cell": child, "ui": ui})
	return out


func _check_turn_banner() -> void:
	var found := _banner_label()
	_check(found != null, "回合横幅存在并提示「我方回合」")
	if found != null:
		_check(found.get_global_rect().size.x > 100.0, "回合横幅横向铺满（宽 %.0f）" % found.get_global_rect().size.x)


## 中线左端的记牌器按钮：与右端回合控件对称——圆形、贴左端、垂直居中于中线、不压槽位
func _check_tracker_button() -> void:
	var btn: RoundButton = _main.tracker_button
	_check(btn != null and is_instance_valid(btn), "中线左端有记牌器按钮")
	if btn == null or not is_instance_valid(btn):
		return
	_check(btn.text == "记牌器", "记牌器按钮文字正确（%s）" % btn.text)
	var sb: StyleBoxFlat = btn.get_theme_stylebox("normal")
	_check(absf(btn.size.x - btn.size.y) < 0.5 and sb != null and sb.corner_radius_top_left == btn.corner_radius(),
		"记牌器按钮也是正圆（%.0f×%.0f，圆角 %d）" % [
			btn.size.x, btn.size.y, sb.corner_radius_top_left if sb != null else -1])

	var seam: Rect2 = _main.mid_seam.get_global_rect()
	var rect: Rect2 = btn.get_global_rect()
	_check(absf(rect.get_center().y - seam.get_center().y) < 1.0,
		"记牌器按钮垂直居中于中线（偏差 %.1fpx）" % absf(rect.get_center().y - seam.get_center().y))
	_check(absf(rect.position.x - seam.position.x) < 1.0, "记牌器按钮贴在中线左端")
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	if pb != null:
		var total: float = 114.0 * float(pb.slot_limit) - 10.0
		var row: Rect2 = pb.get_global_rect()
		var slot_left: float = row.position.x + (row.size.x - total) * 0.5
		_check(rect.position.x + rect.size.x <= slot_left,
			"记牌器按钮在战场槽位左侧、不压住随从（%.0f ≤ %.0f）" % [rect.position.x + rect.size.x, slot_left])


## 记牌器抽屉：从右侧滑出，只盖住右侧日志栏，不压到中间的战场
## 注意：这里不在编译期引用 TrackerPanel 类型（工具脚本里解析不到它的自动加载依赖），
## 所以用运行时 load() 取常量、用无类型变量访问实例。
func _check_tracker_drawer() -> void:
	var cls = load("res://scripts/TrackerPanel.gd")
	var want_w: float = cls.DRAWER_WIDTH
	var right_margin: float = cls.RIGHT_MARGIN
	var v_margin: float = cls.V_MARGIN

	_main._open_tracker()                     # 第一次点击时创建抽屉
	var drawer: Variant = _main._tracker_panel
	_check(drawer != null and is_instance_valid(drawer), "记牌器抽屉已创建")
	if drawer == null or not is_instance_valid(drawer):
		return
	_check(drawer.is_open() and drawer.visible, "打开后抽屉可见")
	var as_node: Node = drawer
	_check(not (as_node is Window), "记牌器不再是独立窗口（不会居中弹在场地中间）")

	# 无头模式的帧步长不可控，动画时间置 0 让位置立即到位
	drawer.slide_time = 0.0
	drawer.close()
	drawer.open()

	var area: Vector2 = drawer.get_parent_area_size()
	var rect: Rect2 = drawer.get_global_rect()
	_check(absf(rect.size.x - want_w) < 1.0, "抽屉宽度为 %.0f（实际 %.0f）" % [want_w, rect.size.x])
	_check(absf((rect.position.x + rect.size.x) - (area.x - right_margin)) < 1.0,
		"抽屉贴窗口右边缘（右缘 %.0f = 视口 %.0f - 边距 %.0f）" % [
			rect.position.x + rect.size.x, area.x, right_margin])
	_check(absf(rect.position.y - v_margin) < 1.0, "抽屉上边缘留出 %.0f px 边距" % v_margin)

	# 关键：不占据中间场地
	var arena: Rect2 = _main.arena_panel.get_global_rect()
	_check(rect.position.x >= arena.position.x + arena.size.x,
		"抽屉在竞技区右侧之外、不遮挡中间场地（%.0f ≥ %.0f）" % [rect.position.x, arena.position.x + arena.size.x])
	var pb: BoardSurface = _main.get_node_or_null(PLAYER_BOARD)
	if pb != null:
		var row: Rect2 = pb.get_global_rect()
		_check(rect.position.x >= row.position.x + row.size.x,
			"抽屉不压住战场行（%.0f ≥ %.0f）" % [rect.position.x, row.position.x + row.size.x])
	var log_panel: Control = _main.get_node_or_null("Root/LogPanel")
	if log_panel != null:
		var lr: Rect2 = log_panel.get_global_rect()
		_check(rect.position.x <= lr.position.x + 1.0 and rect.size.x >= lr.size.x - 1.0,
			"抽屉正好盖住右侧日志栏（日志栏 %.0f–%.0f，抽屉 %.0f–%.0f）" % [
				lr.position.x, lr.position.x + lr.size.x, rect.position.x, rect.position.x + rect.size.x])

	# 收起后滑出屏幕
	drawer.close()
	_check(not drawer.is_open(), "收起后状态为关闭")
	_check(drawer.get_global_rect().position.x >= area.x - right_margin - 1.0,
		"收起后抽屉已滑出右边缘之外（左缘 %.0f ≥ %.0f）" % [
			drawer.get_global_rect().position.x, area.x - right_margin])


## 认输：新增的对局内控件，应当能直接结束对局
func _check_concede() -> void:
	var btn: Button = _main.get_node_or_null("Root/Arena/TopBar/ConcedeButton")
	_check(btn != null and btn.text == "认输", "顶栏有「认输」按钮")
	if _gm == null:
		return
	_gm.new_game()
	_main.skip_mulligan()
	_gm.concede(0)
	_check(not _gm.game_active() and _gm.winner == 1, "认输后立即判负（winner=%d）" % _gm.winner)
	_gm.new_game()
	_main.skip_mulligan()


# ------------------------------ 辅助 ------------------------------

func _banner_label() -> Label:
	var layer: Node = _main.get_node_or_null("DragLayer")
	if layer == null:
		return null
	for child in layer.get_children():
		if child is Label and (child.text.begins_with("我方回合") or child.text.begins_with("敌方回合")):
			return child
	return null


func _banner_text() -> String:
	var l := _banner_label()
	return "（缺失）" if l == null else l.text


func _find_first(root_node: Node, type_name: String) -> Node:
	for child in root_node.get_children():
		if child.get_script() != null and str(child.get_script().get_global_name()) == type_name:
			return child
		var deeper := _find_first(child, type_name)
		if deeper != null:
			return deeper
	return null


func _badge_texts(counters: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for panel in counters.get_children():
		for child in panel.get_children():
			if child is Label:
				out.append(child.text)
	return out


func _has_text(texts: PackedStringArray, needle: String) -> bool:
	for t in texts:
		if t == needle:
			return true
	return false


func _pick(texts: PackedStringArray, prefix: String) -> String:
	for t in texts:
		if t.begins_with(prefix):
			return t
	return "（缺失）"


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	for node in [_main]:
		if node != null and is_instance_valid(node):
			node.queue_free()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 布局测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
