extends Control
## 游戏主界面（标题界面点「开始游戏」之后进来）：
##   * **开始匹配** → 线上对战（先找局域网空房间，找不到就自己开房等对手，匹配到就进对局）
##   * 人机对战 → 单机对 AI
##   * 创建 / 加入房间 → 老的大厅面板（手动指定房间）
##   * 组建卡组 → 先选主战者职业、再从「本职业 + 中立」的卡池里自由组一套（存在
##     GameSettings.selected_deck / selected_class，下次开局生效）；**没组好不给开局**
##   * 设置 / 卡牌管理 / 返回标题
##
## 匹配状态由 `Net`（NetSession）驱动，匹配成功时自动切到对局场景。

const BATTLE_SCENE := "res://scenes/Main.tscn"
const TITLE_SCENE := "res://scenes/Title.tscn"

var _btn_match: Button
var _btn_cancel: Button
var _btn_ai: Button
var _btn_room: Button
var _btn_deck: Button
var _btn_settings: Button
var _btn_admin: Button
## AI 助手入口（全局浮窗，与「人机对战」的 _btn_ai 不是同一个东西）
var _btn_assistant: Button
var _btn_title: Button
## 对战模式（指定 / 无限）：决定可用卡包与该模式的限制卡规则
var _mode_option: OptionButton
var _status: Label
var _tip: Label
var _lobby = null
var _deck_dialog = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	var net := _net()
	if net != null:
		net.matchmaking_changed.connect(_refresh)
		net.match_found.connect(_on_match_found)
		net.roster_changed.connect(_refresh)
		net.log_line.connect(func(text: String) -> void: _status.text = text)
		net.session_ended.connect(func(reason: String) -> void:
			_status.text = "会话结束：%s" % reason
			_refresh())
	GameSettings.changed.connect(_refresh)
	AdminAuth.login_state_changed.connect(func(_v: bool) -> void: _refresh())
	_refresh()


func _net() -> Node:
	return get_node_or_null("/root/Net")


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.07)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(560, 490)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.10, 0.14, 0.98)
	style.border_color = Color(0.30, 0.36, 0.45, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.content_margin_left = 28
	style.content_margin_right = 28
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	box.add_child(v)

	var title := Label.new()
	title.text = "主界面"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color("#ffee58"))
	v.add_child(title)

	# ---- 对战模式（指定 / 无限）：开局与组卡都用它 ----
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 8)
	mode_row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(mode_row)
	var mode_label := Label.new()
	mode_label.text = "对战模式"
	mode_row.add_child(mode_label)
	_mode_option = OptionButton.new()
	_mode_option.custom_minimum_size = Vector2(220, 32)
	for m in Formats.mode_ids():
		_mode_option.add_item(Formats.mode_label(m))
		_mode_option.set_item_metadata(_mode_option.item_count - 1, m)
	_mode_option.item_selected.connect(_on_mode_selected)
	mode_row.add_child(_mode_option)

	_btn_match = _menu_button(v, "开始匹配（线上对战）", _on_match)
	_btn_cancel = _menu_button(v, "取消匹配", _on_cancel)
	_btn_ai = _menu_button(v, "人机对战", _on_ai)
	_btn_room = _menu_button(v, "创建 / 加入房间…", _on_room)
	_btn_deck = _menu_button(v, "组建卡组…", _on_deck)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(row)
	_btn_settings = _menu_button(row, "设置", _on_settings)
	_btn_admin = _menu_button(row, "卡牌管理", _on_admin)
	_btn_assistant = _menu_button(row, "AI 助手", _on_assistant)
	_btn_title = _menu_button(row, "返回标题", _on_title)

	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color("#b9f6ca"))
	v.add_child(_status)

	_tip = Label.new()
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.add_theme_font_size_override("font_size", 11)
	_tip.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
	v.add_child(_tip)


func _menu_button(parent: Node, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 38)
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _refresh() -> void:
	var net := _net()
	if net == null or _status == null:
		return
	var making: bool = net.matchmaking
	_btn_match.disabled = making
	_btn_cancel.disabled = not making
	_btn_cancel.visible = making
	var st := str(net.matchmaking_text())
	if st != "":
		_status.text = st
	_btn_admin.text = "卡牌管理" if AdminAuth.is_logged_in else "管理员登录"
	_refresh_mode_option()
	var mode := Formats.normalized_mode(str(GameSettings.get("selected_mode")))
	# 没组好卡组 / 当前模式用不了时不给开局：按钮文字直接把该做的事说出来
	var deck_name := GameManager.current_deck_name()
	if deck_name == "":
		var def := CardDB.player_deck_by_id(str(GameSettings.get("selected_deck")))
		if def.is_empty():
			_btn_deck.text = "组建卡组…（还没有出战卡组，点此组建）"
		else:
			_btn_deck.text = "组建卡组…（「%s」在%s模式不可用，点此调整）" % [
				str(def.get("name", "")), CardDB.mode_label(mode)]
	else:
		_btn_deck.text = "出战卡组：%s（主战者 %s）" % [deck_name, GameManager.current_deck_class_name()]
	_tip.text = "玩家：%s　｜　%s模式（可用卡包 %d 个）　｜　端口 %d　｜　每回合 %s　｜　%s" % [
		str(GameSettings.get("player_name")), CardDB.mode_label(mode),
		CardDB.mode_allowed_packs(mode).size(),
		int(GameSettings.get("net_port")),
		"不限时" if int(net.turn_time_limit) <= 0 else "%d 秒" % int(net.turn_time_limit),
		"联机中：" + ("房主" if net.is_host() else ("观战" if net.is_spectator() else "客机")) if net.is_online() else "未联机"]


## 模式下拉回填（不触发 item_selected，避免和 _refresh 互相刷）
func _refresh_mode_option() -> void:
	if _mode_option == null:
		return
	var mode := Formats.normalized_mode(str(GameSettings.get("selected_mode")))
	for i in _mode_option.item_count:
		if str(_mode_option.get_item_metadata(i)) == mode:
			_mode_option.select(i)
			break
	_mode_option.tooltip_text = Formats.mode_desc(mode)


func _on_mode_selected(index: int) -> void:
	if _mode_option == null or index < 0:
		return
	var meta = _mode_option.get_item_metadata(index)
	GameSettings.set("selected_mode", Formats.normalized_mode(str(meta) if meta != null else ""))
	GameSettings.save_settings()
	SoundFx.play("button")
	_refresh()


# ------------------------------ 按钮 ------------------------------

func _on_match() -> void:
	var net := _net()
	if net == null:
		return
	if not GameManager.player_deck_ready():
		_refuse_start()
		return
	SoundFx.play("button")
	net.start_matchmaking(str(GameSettings.get("player_name")), int(GameSettings.get("net_port")),
		_net_turn_limit())
	_refresh()


func _on_cancel() -> void:
	var net := _net()
	if net == null:
		return
	net.cancel_matchmaking()
	_status.text = "已取消匹配"
	_refresh()


func _on_ai() -> void:
	if not GameManager.player_deck_ready():
		_refuse_start()
		return
	SoundFx.play("button")
	var net := _net()
	if net != null and net.is_online():
		net.leave_game()          # 人机对战不需要联机会话
	GameManager.new_game()
	get_tree().change_scene_to_file(BATTLE_SCENE)


## 还没组卡组 / 当前模式用不了：说清楚该做什么，而不是让玩家开着空牌库进对局
func _refuse_start() -> void:
	if CardDB.hero_classes.is_empty():
		_status.text = "管理员还没有添加主战者职业，请先在「卡牌管理」里添加。"
		_refresh()
		return
	var mode := Formats.normalized_mode(str(GameSettings.get("selected_mode")))
	var def := CardDB.player_deck_by_id(str(GameSettings.get("selected_deck")))
	var errs := CardDB.player_deck_errors(def, mode)
	if not errs.is_empty():
		_status.text = "%s模式：「%s」%s" % [CardDB.mode_label(mode),
			str(def.get("name", "出战卡组")), errs[0]]
		_refresh()
		return
	var range_text := "至少 %d 张" % CardDB.mode_deck_min(mode)
	if CardDB.mode_deck_max(mode) > 0:
		range_text = "%d–%d 张" % [CardDB.mode_deck_min(mode), CardDB.mode_deck_max(mode)]
	_status.text = "请先点「组建卡组…」：在%s模式的卡包里组一套 %s 的卡组才能开局。" % [
		CardDB.mode_label(mode), range_text]
	_refresh()


func _on_deck() -> void:
	SoundFx.play("button")
	if _deck_dialog == null or not is_instance_valid(_deck_dialog):
		# 用 load() 而不是全局类名：脚本的 class_name 依赖 .godot 里的类缓存，
		# 新加的脚本在缓存刷新之前解析不到（AdminPanel / NetLobby 也是这么用的）。
		_deck_dialog = load("res://scripts/DeckBuilderDialog.gd").new()
		_deck_dialog.deck_changed.connect(_on_deck_selected)
		_deck_dialog.closed.connect(func() -> void: _deck_dialog = null)
		add_child(_deck_dialog)
	_deck_dialog.popup_centered()


## 组卡界面保存 / 切卡组后**不会自己关掉**，所以这里只刷新主页状态：
## 要是把引用清空，玩家再点一次按钮就会开出第二个组卡窗口。
func _on_deck_selected(_deck_id: String) -> void:
	_refresh()


func _on_room() -> void:
	SoundFx.play("button")
	if _lobby == null or not is_instance_valid(_lobby):
		_lobby = load("res://scripts/NetLobby.gd").new()
		add_child(_lobby)
	_lobby.open()


func _on_settings() -> void:
	SoundFx.play("button")
	var dlg := SettingsDialog.new()
	add_child(dlg)
	dlg.popup_centered()


## AI 助手：开合全局浮窗（挂在与标题界面共用的一层上，切场景也不销毁）
func _on_assistant() -> void:
	SoundFx.play("button")
	var ai := get_node_or_null("/root/AiAssistant")
	if ai != null and ai.has_method("toggle_sidebar"):
		ai.toggle_sidebar()


func _on_admin() -> void:
	SoundFx.play("button")
	if not AdminAuth.is_logged_in:
		var login := LoginDialog.new()
		add_child(login)
		login.login_succeeded.connect(func() -> void: _open_admin_panel())
		login.popup_centered()
	else:
		_open_admin_panel()


func _open_admin_panel() -> void:
	var panel = load("res://scripts/AdminPanel.gd").new()
	add_child(panel)
	if panel.has_method("popup_centered"):
		panel.popup_centered()
	_refresh()


func _on_title() -> void:
	var net := _net()
	if net != null:
		net.cancel_matchmaking()
		net.leave_game()
	get_tree().change_scene_to_file(TITLE_SCENE)


# ------------------------------ 匹配成功 ------------------------------

func _on_match_found() -> void:
	if not GameManager.player_deck_ready():
		var net := _net()
		if net != null:
			net.cancel_matchmaking()
		_refuse_start()
		return
	_status.text = "匹配成功，进入对局…"
	_start_net_battle()
	SoundFx.play("turn_start")
	get_tree().change_scene_to_file(BATTLE_SCENE)


## 匹配成功后开打：房主负责开局（发牌 + 广播快照），客机等房主的快照即可。
## 单独抽出来是为了让测试能只验证「开局」而不用真的切场景。
func _start_net_battle() -> void:
	var net := _net()
	if net != null and net.is_host():
		net.start_session()


func _net_turn_limit() -> int:
	# 主界面默认用 90 秒（联机防挂机）；想改就在大厅里创建房间时选
	return 90
