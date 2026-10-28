extends PanelContainer
## 联机大厅：创建房间 / 局域网房间列表 / 直接 IP 加入 / 观战 / 延迟与重连状态。
##
## 它只跟 `Net`（NetSession 自动加载）与 `GameSettings` 打交道，不碰 GameManager，
## 这样"联机"这一块的界面与对战逻辑彼此独立。

signal closed()

var _room_edit: LineEdit
var _port_spin: SpinBox
var _name_edit: LineEdit
var _limit_option: OptionButton
var _spectate_check: CheckBox
var _ip_edit: LineEdit
var _list: ItemList
var _status: RichTextLabel
var _roster: Label
var _create_btn: Button
var _join_btn: Button
var _leave_btn: Button
var _start_btn: Button
var _refresh_btn: Button


func _ready() -> void:
	custom_minimum_size = Vector2(520, 460)
	_build()
	var net := _net()
	if net != null:
		net.room_list_changed.connect(_refresh_rooms)
		net.roster_changed.connect(_refresh_status)
		net.latency_changed.connect(func(_ms: int) -> void: _refresh_status())
		net.log_line.connect(_append_log)
		net.session_ended.connect(func(reason: String) -> void: _append_log("会话结束：%s" % reason))
	_refresh_rooms()
	_refresh_status()


func _net() -> Node:
	return get_node_or_null("/root/Net")


func _build() -> void:
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 14)
	pad.add_theme_constant_override("margin_right", 14)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_bottom", 12)
	add_child(pad)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	pad.add_child(v)

	var title := Label.new()
	title.text = "联机对战"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("#ffee58"))
	v.add_child(title)

	var note := Label.new()
	note.text = "房主权威：房主跑规则，客机只发改动请求并渲染房主下发的状态（只下发给自己的手牌内容）。掉线保留座位 60 秒可重连，超时判负；满员时加入会自动转为观战。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color(0.75, 0.79, 0.85))
	v.add_child(note)

	# --- 我的信息 ---
	var me_row := HBoxContainer.new()
	me_row.add_theme_constant_override("separation", 8)
	v.add_child(me_row)
	_name_edit = _add_field(me_row, "我的名字", 140)
	_port_spin = SpinBox.new()
	_port_spin.min_value = 1024
	_port_spin.max_value = 65535
	_port_spin.step = 1
	me_row.add_child(_label("端口"))
	me_row.add_child(_port_spin)
	_limit_option = OptionButton.new()
	for opt in ["不限时", "30 秒/回合", "60 秒/回合", "90 秒/回合", "120 秒/回合"]:
		_limit_option.add_item(opt)
	me_row.add_child(_label("回合时限"))
	me_row.add_child(_limit_option)

	# --- 创建 / 加入 ---
	var act_row := HBoxContainer.new()
	act_row.add_theme_constant_override("separation", 8)
	v.add_child(act_row)
	_create_btn = Button.new()
	_create_btn.text = "创建房间"
	_create_btn.custom_minimum_size = Vector2(110, 32)
	_create_btn.pressed.connect(_on_create)
	act_row.add_child(_create_btn)
	_room_edit = _add_field(act_row, "房间名", 150)
	_start_btn = Button.new()
	_start_btn.text = "开始对局"
	_start_btn.custom_minimum_size = Vector2(100, 32)
	_start_btn.pressed.connect(_on_start)
	act_row.add_child(_start_btn)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 8)
	v.add_child(join_row)
	_ip_edit = _add_field(join_row, "房主 IP", 150)
	_spectate_check = CheckBox.new()
	_spectate_check.text = "观战"
	join_row.add_child(_spectate_check)
	_join_btn = Button.new()
	_join_btn.text = "加入"
	_join_btn.custom_minimum_size = Vector2(90, 32)
	_join_btn.pressed.connect(_on_join)
	join_row.add_child(_join_btn)

	var list_row := HBoxContainer.new()
	list_row.add_theme_constant_override("separation", 8)
	list_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(list_row)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(300, 110)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(func(_i: int) -> void: _on_join())
	list_row.add_child(_list)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	list_row.add_child(side)
	_refresh_btn = Button.new()
	_refresh_btn.text = "刷新列表"
	_refresh_btn.custom_minimum_size = Vector2(110, 30)
	_refresh_btn.pressed.connect(_refresh_rooms)
	side.add_child(_refresh_btn)
	_leave_btn = Button.new()
	_leave_btn.text = "离开房间"
	_leave_btn.custom_minimum_size = Vector2(110, 30)
	_leave_btn.pressed.connect(_on_leave)
	side.add_child(_leave_btn)

	_roster = Label.new()
	_roster.add_theme_font_size_override("font_size", 12)
	_roster.add_theme_color_override("font_color", Color("#b9f6ca"))
	v.add_child(_roster)

	_status = RichTextLabel.new()
	_status.custom_minimum_size = Vector2(0, 96)
	_status.bbcode_enabled = false
	_status.add_theme_font_size_override("normal_font_size", 12)
	_status.scroll_following = true
	v.add_child(_status)

	var close := Button.new()
	close.text = "关闭"
	close.custom_minimum_size = Vector2(90, 30)
	close.pressed.connect(func() -> void:
		closed.emit()
		visible = false)
	v.add_child(close)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	return l


func _add_field(row: HBoxContainer, hint: String, width: float) -> LineEdit:
	row.add_child(_label(hint))
	var e := LineEdit.new()
	e.custom_minimum_size = Vector2(width, 28)
	row.add_child(e)
	return e


# ------------------------------ 状态刷新 ------------------------------

## 打开时从设置里预填名字与端口
func open() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs != null:
		if _name_edit.text.strip_edges() == "":
			_name_edit.text = str(gs.get("player_name"))
		if int(_port_spin.value) <= 0:
			_port_spin.value = int(gs.get("net_port"))
	var net := _net()
	if net != null:
		_limit_option.selected = _limit_index(int(net.turn_time_limit))
	visible = true
	_refresh_rooms()
	_refresh_status()


func _limit_index(seconds: int) -> int:
	match seconds:
		30:
			return 1
		60:
			return 2
		90:
			return 3
		120:
			return 4
		_:
			return 0


func _limit_seconds() -> int:
	match _limit_option.selected:
		1:
			return 30
		2:
			return 60
		3:
			return 90
		4:
			return 120
		_:
			return 0


func _refresh_rooms() -> void:
	if _list == null:
		return
	_list.clear()
	var net := _net()
	if net == null:
		return
	var rooms: Array = net.lan_rooms()
	for room in rooms:
		var idx := _list.add_item("%s  %s:%d（%d/%d）" % [
			str(room["room"]), str(room["ip"]), int(room["port"]), int(room["players"]), int(room["max"])])
		_list.set_item_metadata(idx, room)
	if _list.item_count == 0:
		_list.add_item("（局域网内暂未发现房间，可直接填房主 IP 加入）")
		_list.set_item_disabled(0, true)


func _refresh_status() -> void:
	var net := _net()
	if net == null:
		return
	var role_text := "离线（单机）"
	match int(net.role):
		1:
			role_text = "房主"
		2:
			role_text = "客机"
	_check_btn_states(int(net.role))
	var extra := ""
	if net.is_spectator():
		extra = "（观战）"
	_roster.text = "身份：%s%s   延迟：%d ms   房间：%s" % [
		role_text, extra, int(net.rtt_ms), net.room_name if net.room_name != "" else "—"]
	var lines: PackedStringArray = net.roster_lines()
	if lines.size() > 0:
		_roster.text += "   在线：" + "、".join(lines)
	if int(net.get("_disconnected_seat")) >= 0:
		_roster.text += "   ⚠ 有玩家掉线，等待重连中"


func _check_btn_states(role: int) -> void:
	var online := role != 0
	if _create_btn != null:
		_create_btn.disabled = online
	if _join_btn != null:
		_join_btn.disabled = online
	if _leave_btn != null:
		_leave_btn.disabled = not online
	if _start_btn != null:
		_start_btn.disabled = role != 1
	if _spectate_check != null:
		_spectate_check.disabled = online


func _append_log(text: String) -> void:
	if _status == null or text.strip_edges() == "":
		return
	_status.text += text + "\n"


# ------------------------------ 按钮 ------------------------------

func _on_create() -> void:
	var net := _net()
	if net == null:
		return
	if net.host_game(_room_edit.text.strip_edges(), int(_port_spin.value),
			_name_edit.text.strip_edges(), _limit_seconds()):
		_append_log("房间已创建，等待对手加入。重连令牌：%s（客机掉线后用它回来）" % net.guest_token)
		_persist()
	else:
		_append_log(net.last_error)
	_refresh_status()


func _on_join() -> void:
	var net := _net()
	if net == null:
		return
	var ip := _ip_edit.text.strip_edges()
	if ip == "":
		var sel := _list.get_selected_items()
		if sel.is_empty():
			_append_log("请先选择房间，或填写房主 IP")
			return
		ip = str(_list.get_item_metadata(sel[0])["ip"])
	if net.join_game(ip, int(_port_spin.value), _name_edit.text.strip_edges(), _spectate_check.button_pressed):
		_append_log("已发出加入请求：%s:%d%s" % [ip, int(_port_spin.value), "（观战）" if _spectate_check.button_pressed else ""])
		_persist()
	else:
		_append_log(net.last_error)
	_refresh_status()


func _on_leave() -> void:
	var net := _net()
	if net != null:
		net.leave_game()
	_append_log("已离开房间")
	_refresh_status()


func _on_start() -> void:
	var net := _net()
	if net != null:
		net.start_session()
		_append_log("对局开始")


## 名字 / 端口回写到设置，下次打开还记得
func _persist() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs == null:
		return
	var changed := false
	if str(gs.get("player_name")) != _name_edit.text.strip_edges() and _name_edit.text.strip_edges() != "":
		gs.set("player_name", _name_edit.text.strip_edges())
		changed = true
	if int(gs.get("net_port")) != int(_port_spin.value):
		gs.set("net_port", int(_port_spin.value))
		changed = true
	if changed and gs.has_method("save_settings"):
		gs.save_settings()
