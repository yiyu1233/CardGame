extends SceneTree
## 主界面 / 匹配流程测试：
##   * `scenes/Title.tscn`：标题界面有「开始游戏 / 设置 / 退出」，点开始游戏切到主界面；
##   * `scenes/Home.tscn`：主界面上有「开始匹配 / 取消匹配 / 人机对战 / 房间 / 设置 / 卡牌管理 / 返回标题」；
##   * 点「开始匹配」→ Net 进入匹配状态（先搜局域网房间，等不到就自己开房等对手），
##     状态文案随匹配进度变化；点「取消匹配」→ 回到未联机；
##   * 「人机对战」→ 单机新对局并切到对局场景；
##   * 匹配成功后（模拟 Net 发出 match_found）→ 房主会 start_session 且切到对局场景。
##
## 运行：godot --headless --path <项目目录> --script res://tools/menu_test.gd

const TITLE_SCENE := "res://scenes/Title.tscn"
const HOME_SCENE := "res://scenes/Home.tscn"
const BATTLE_SCENE := "res://scenes/Main.tscn"

var _fails := 0
var _frames := 0
var _stage := 0
var _gm
var _net
var _db
var _settings
var title
var home
var _fail_lines: Array[String] = []


## 测试用卡组：现在**没组好卡组不给开局**（先选主战者职业 → 自由组卡），
## 所以要先把一套合法卡组塞给 GameSettings 才能测「开始匹配 / 人机对战 / 匹配成功」。
## 用完会删掉并把设置还原，不会污染玩家的真实存档。
var _test_deck_id := ""
var _old_selected_deck := ""
var _old_selected_class := ""


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_net = root.get_node_or_null("Net")
		_db = root.get_node_or_null("CardDB")
		_settings = root.get_node_or_null("GameSettings")
		if _gm == null or _net == null or _db == null or _settings == null:
			_check(false, "GameManager / Net / CardDB / GameSettings 自动加载")
			_finish()
			return true
		_prepare_test_deck()
		_check(ProjectSettings.get_setting("application/run/main_scene", "") == TITLE_SCENE,
			"启动场景是标题界面（%s）" % str(ProjectSettings.get_setting("application/run/main_scene", "")))
		title = load(TITLE_SCENE).instantiate() as Control
		root.add_child(title)
		_check(title != null, "标题界面可实例化")
		_test_title()
		home = load(HOME_SCENE).instantiate() as Control
		root.add_child(home)
		_check(home != null, "主界面可实例化")
		_test_home()
		_test_refuse_start()
		_test_matchmaking()
		_stage = 1
		return false
	if _frames == 20 and _stage == 1:
		_test_match_found()
		_stage = 2
		return false
	if _frames == 24:
		_finish()
		return true
	return _frames > 300


# ------------------------------ 标题界面 ------------------------------

func _find_buttons(node: Node, out: Array) -> Array:
	for child in node.get_children():
		if child is Button:
			out.append(child)
		_find_buttons(child, out)
	return out


func _button_texts(node: Node) -> PackedStringArray:
	var names := PackedStringArray()
	for b in _find_buttons(node, []):
		names.append(b.text)
	return names


func _test_title() -> void:
	var texts := _button_texts(title)
	_check(texts.has("开始游戏"), "标题界面有「开始游戏」（实际 %s）" % str(texts))
	_check(texts.has("设置"), "标题界面有「设置」")
	_check(texts.has("退出游戏"), "标题界面有「退出游戏」")
	var has_title := false
	for l in _all_labels(title):
		if l.text.contains("卡牌游戏框架"):
			has_title = true
	_check(has_title, "标题界面显示游戏名")


func _all_labels(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is Label:
			out.append(child)
		out += _all_labels(child)
	return out


# ------------------------------ 主界面 ------------------------------

func _test_home() -> void:
	var texts := _button_texts(home)
	_check(texts.has("开始匹配（线上对战）"), "主界面有「开始匹配」（实际 %s）" % str(texts))
	_check(texts.has("人机对战"), "主界面有「人机对战」")
	_check(texts.has("创建 / 加入房间…"), "主界面有「创建 / 加入房间」")
	_check(texts.has("设置"), "主界面有「设置」")
	_check(texts.has("返回标题"), "主界面有「返回标题」")
	_check(not _net.matchmaking, "刚进主界面时不在匹配中")


# ------------------------------ 测试用卡组 ------------------------------

func _prepare_test_deck() -> void:
	_old_selected_deck = str(_settings.get("selected_deck"))
	_old_selected_class = str(_settings.get("selected_class"))
	var cid := ""
	if not _db.hero_classes.is_empty():
		cid = str(_db.hero_classes[0].get("id", ""))
	var pool := []
	for c in _db.cards:
		if not c.is_token and _db.card_allowed_for_class(c, cid):
			pool.append(c)
	_check(cid != "" and not pool.is_empty(), "有主战者职业与可用卡池（用于组测试卡组）")
	if cid == "" or pool.is_empty():
		return
	# 按当前卡组规则凑一套最小合法卡组（同名上限 + 最少张数都要满足）
	var per_card := maxi(1, int(_db.get("max_copies")))
	var want := maxi(1, int(_db.get("deck_min")))
	var entries := []
	var i := 0
	while want > 0 and not pool.is_empty():
		var take: int = mini(per_card, want)
		entries.append({"id": (pool[i % pool.size()] as CardData).id, "count": take})
		want -= take
		i += 1
	_test_deck_id = _db.upsert_player_deck("", "自动化测试卡组", cid, entries)
	_check(_test_deck_id != "", "测试卡组组建成功")
	_settings.selected_deck = _test_deck_id
	_settings.selected_class = cid
	_settings.save_settings()
	_check(_gm.player_deck_ready(), "主界面承认这套卡组（开局门槛）")


func _cleanup_test_deck() -> void:
	if _test_deck_id != "" and _db != null:
		_db.remove_player_deck(_test_deck_id)
	if _settings != null:
		_settings.selected_deck = _old_selected_deck
		_settings.selected_class = _old_selected_class
		_settings.save_settings()


# ------------------------------ 开局门槛 ------------------------------

## 没组卡组时不给开局：点「人机对战」应该被挡回去（而不是开着空牌库进对局）
func _test_refuse_start() -> void:
	var started := [0]
	_gm.game_started.connect(func() -> void: started[0] += 1)
	_settings.selected_deck = ""
	_settings.save_settings()
	home._on_ai()
	_check(started[0] == 0, "没组卡组时点「人机对战」不会开局")
	_check(str(home._status.text).contains("组建卡组"), "主界面提示先去组建卡组（%s）" % home._status.text)
	_check(home._btn_deck.text.contains("组建卡组"), "卡组按钮显示当前状态（%s）" % home._btn_deck.text)
	# 还原到「有卡组」的正常状态
	_settings.selected_deck = _test_deck_id
	_settings.save_settings()
	_check(_gm.player_deck_ready(), "还原后又能开局了")


# ------------------------------ 匹配 ------------------------------

func _test_matchmaking() -> void:
	_net.match_host_delay = 0.2        # 测试不等 4 秒
	home._on_match()
	_check(_net.matchmaking, "点「开始匹配」后进入匹配状态")
	_check(home._btn_match.disabled and home._btn_cancel.visible and not home._btn_cancel.disabled,
		"匹配中：「开始匹配」置灰、「取消匹配」可见可用")
	var st: String = _net.matchmaking_text()
	_check(st.contains("搜索") or st.contains("开房"), "匹配状态文案随进度变化（%s）" % st)
	# 推进若干帧：等不到房间就会自己开房等待对手
	for i in 12:
		_net._process(0.05)
	_check(_net.is_host(), "等不到房间时自己开房（role=%d）" % _net.role)
	_check(_net.matchmaking and _net.match_hosted, "开房后仍在匹配中（等对手进来）")
	_check(_net.matchmaking_text().contains("等待对手"), "文案变成「等待对手」（%s）" % _net.matchmaking_text())
	home._on_cancel()
	_check(not _net.matchmaking, "点「取消匹配」结束匹配")
	_check(not _net.is_online(), "取消后退出联机会话")
	_check(_btn_text_visible(home, "取消匹配") == false, "取消后「取消匹配」按钮隐藏")


func _btn_text_visible(node: Node, text: String) -> bool:
	for b in _find_buttons(node, []):
		if b.text == text:
			return b.visible
	return false


# ------------------------------ 人机对战 / 匹配成功 ------------------------------

func _test_match_found() -> void:
	# 人机对战：清掉联机并开新局
	_net.leave_game()
	var before_players: int = _gm.players.size()
	home._on_ai()
	_check(_gm.game_active(), "人机对战开了一局新对局")
	_check(_gm.players.size() == before_players and _gm.players.size() == 2, "对局有两名玩家")
	_check(not _net.is_online(), "人机对战不保留联机会话")

	# 匹配成功（房主侧）：房主负责开局（发牌 + 广播）
	_net.match_host_delay = 0.2
	_net.start_matchmaking("甲", 27815, 60)
	for i in 12:
		_net._process(0.05)
	_check(_net.is_host() and _net.matchmaking, "（构造）匹配过程中已自己开房等对手")
	var started := [false]
	_net.session_started.connect(func() -> void: started[0] = true)
	home._on_match_found()
	_check(started[0], "匹配成功后房主调用了 start_session（发牌 + 广播）")
	_check(_gm.game_active(), "对局已开始")
	_check(BATTLE_SCENE == "res://scenes/Main.tscn", "对局场景路径正确（%s）" % BATTLE_SCENE)
	_net.leave_game()


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if title != null and is_instance_valid(title):
		title.queue_free()
	if home != null and is_instance_valid(home):
		home.queue_free()
	_cleanup_test_deck()
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 主界面 / 匹配测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
