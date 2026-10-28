class_name LoginDialog
extends Window
## 管理员登录窗口（纯代码构建，无需额外场景文件）。
##
## 两种形态共用一个窗口：
##   * 未登录 -> 账号 / 口令表单 + 登录按钮；
##   * 已登录 -> 登录状态 + 「修改口令」/「退出登录」。
## 登录成功后不再直接关窗（原先会 queue_free），而是就地切成已登录形态：
## 管理员常常还要立刻改掉默认口令，关掉窗口反而要多点一次「管理员登录」。
## 关闭窗口只隐藏不销毁（需要的成员还在），重复打开时复用同一个实例不会残留状态。

signal login_succeeded()

var user_edit: LineEdit
var pass_edit: LineEdit
var tip_label: Label

## 最近一次失败原因（测试与调试用；tip_label.text 就是它）
var fail_msg := ""

var _form_root: VBoxContainer
var _status_root: VBoxContainer
var _show_btn: Button
var _account_dialog: Control = null
## 不加类型标注：避免在 --script 上下文里静态解析自动加载标识符
var _auth = null


func _ready() -> void:
	title = "管理员登录"
	size = Vector2i(400, 300)
	unresizable = true
	transient = true
	close_requested.connect(_on_close_requested)
	_build_ui()
	_refresh_state()


func _auth_node():
	if _auth == null or not is_instance_valid(_auth):
		_auth = get_node_or_null("/root/AdminAuth")
	return _auth


# ------------------------------ 构建 ------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	# 表单容器与状态容器都挂在这一个 VBox 里，切换形态时只替换它们的内容
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	_form_root = VBoxContainer.new()
	_form_root.add_theme_constant_override("separation", 10)
	_form_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_form_root)

	_status_root = VBoxContainer.new()
	_status_root.add_theme_constant_override("separation", 10)
	_status_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_status_root.visible = false
	vbox.add_child(_status_root)

	_build_form()
	_build_status()


func _build_form() -> void:
	user_edit = LineEdit.new()
	user_edit.placeholder_text = "admin"
	user_edit.text = "admin"
	pass_edit = LineEdit.new()
	pass_edit.placeholder_text = "请输入密码"
	pass_edit.secret = true

	var title_label := Label.new()
	title_label.text = "请输入管理员账号"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_form_root.add_child(title_label)

	# 账号
	_form_root.add_child(_make_hint("账号"))
	_form_root.add_child(user_edit)

	# 口令（右侧一个显示 / 隐藏按钮，避免全角字符打错时看不见）
	_form_root.add_child(_make_hint("口令"))
	var pw_row := HBoxContainer.new()
	pw_row.add_theme_constant_override("separation", 6)
	_form_root.add_child(pw_row)

	pass_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw_row.add_child(pass_edit)

	_show_btn = Button.new()
	_show_btn.text = "显示"
	_show_btn.tooltip_text = "显示 / 隐藏口令"
	_show_btn.custom_minimum_size = Vector2(56, 0)
	_show_btn.toggle_mode = true
	_show_btn.toggled.connect(_on_show_toggled)
	pw_row.add_child(_show_btn)

	tip_label = Label.new()
	tip_label.text = ""
	tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip_label.custom_minimum_size = Vector2(0, 44)
	tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_form_root.add_child(tip_label)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	_form_root.add_child(btn_row)

	var ok_btn := Button.new()
	ok_btn.text = "登录"
	ok_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_btn.pressed.connect(_on_login_pressed)
	btn_row.add_child(ok_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(_on_close_requested)
	btn_row.add_child(cancel_btn)

	# 两个输入框都按回车提交
	user_edit.text_submitted.connect(_on_field_submitted)
	pass_edit.text_submitted.connect(_on_field_submitted)
	user_edit.grab_focus()


func _build_status() -> void:
	var title_label := Label.new()
	title_label.text = "管理员已登录"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_root.add_child(title_label)

	var tip := Label.new()
	tip.name = "StatusTip"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.custom_minimum_size = Vector2(0, 44)
	_status_root.add_child(tip)

	var pw_btn := Button.new()
	pw_btn.text = "修改口令"
	pw_btn.pressed.connect(_on_change_password_pressed)
	_status_root.add_child(pw_btn)

	var out_btn := Button.new()
	out_btn.text = "退出登录"
	out_btn.pressed.connect(_on_logout_pressed)
	_status_root.add_child(out_btn)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(_on_close_requested)
	_status_root.add_child(close_btn)

	# 这是展示性文字，不参与交互（按钮保持可点，所以只对这段文字用装饰化）
	UiUtil.make_decorative(title_label)
	UiUtil.make_decorative(tip)


func _make_hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	UiUtil.make_decorative(l)
	return l


# ------------------------------ 形态切换 ------------------------------

func _refresh_state() -> void:
	var auth = _auth_node()
	var logged_in := auth != null and bool(auth.is_logged_in)
	_form_root.visible = not logged_in
	_status_root.visible = logged_in
	if logged_in:
		var body := "当前：%s\n" % str(auth.user_name)
		if bool(auth.using_default_password()):
			body += "仍在使用默认口令，建议立即修改。"
		else:
			body += "口令已修改。"
		var tip := _status_root.get_node_or_null("StatusTip")
		if tip != null:
			(tip as Label).text = body
		fail_msg = ""
	else:
		pass_edit.text = ""
		_show_btn.set_pressed_no_signal(false)
		pass_edit.secret = true
		_update_show_btn_text()
		if fail_msg == "":
			# 提示默认口令：首次使用的人不会知道该输什么。
			# 文本从 AdminAuth 的常量拼，避免改了口令却忘了改提示。
			if _using_default():
				var auth2 = _auth_node()
				tip_label.text = "默认账号 %s / %s，登录后请尽快修改口令。" % [
					str(auth2.ADMIN_USER), str(auth2.DEFAULT_PASSWORD)]
			else:
				tip_label.text = ""
		else:
			tip_label.text = fail_msg
		user_edit.grab_focus()


func _using_default() -> bool:
	var auth = _auth_node()
	return auth != null and bool(auth.using_default_password())


## 已登录形态里的状态说明文字（界面与测试都读它，避免去猜节点路径）
func status_text() -> String:
	if _status_root == null:
		return ""
	var tip := _status_root.get_node_or_null("StatusTip")
	return (tip as Label).text if tip != null else ""


func _on_show_toggled(on: bool) -> void:
	pass_edit.secret = not on
	_update_show_btn_text()


func _update_show_btn_text() -> void:
	_show_btn.text = "隐藏" if not pass_edit.secret else "显示"


func _on_field_submitted(_text: String) -> void:
	_on_login_pressed()


# ------------------------------ 登录 ------------------------------

func _on_login_pressed() -> void:
	var auth = _auth_node()
	if auth == null:
		fail_msg = "内部错误：AdminAuth 不可用"
		tip_label.text = fail_msg
		return

	var user := user_edit.text
	var pw := pass_edit.text

	# 先做本地校验，给出比「账号或密码错误」更有用的提示
	if user.strip_edges() == "":
		fail_msg = "请输入账号"
		_fail()
		return
	if pw == "":
		fail_msg = "请输入口令"
		_fail()
		return

	# 锁定期内不必浪费一次比对，先报剩余秒数
	var remain := int(auth.remaining_lock_seconds())
	if remain > 0:
		fail_msg = "账号已锁定，请在 %d 秒后重试" % remain
		_fail()
		return

	if bool(auth.login(user, pw)):
		fail_msg = ""
		# 登录成功后立刻抹掉窗口里残留的口令文本
		pass_edit.text = ""
		login_succeeded.emit()
		_refresh_state()
		return

	fail_msg = _describe_failure(auth)
	_fail()


## 登录失败后的具体原因：锁定 > 口令错误
func _describe_failure(auth) -> String:
	var remain := int(auth.remaining_lock_seconds())
	if remain > 0:
		return "连续失败 %d 次，账号已锁定，请在 %d 秒后重试" % [int(auth.MAX_FAILURES), remain]
	return "口令错误（已失败 %d 次，连续 %d 次将锁定 %d 秒）" % [
		int(auth.failed_attempts()), int(auth.MAX_FAILURES), int(auth.LOCK_SECONDS)]


func _fail() -> void:
	tip_label.text = fail_msg
	if pass_edit != null:
		pass_edit.text = ""
		pass_edit.grab_focus()


# ------------------------------ 已登录形态 ------------------------------

func _on_change_password_pressed() -> void:
	if _account_dialog != null and is_instance_valid(_account_dialog):
		_account_dialog.queue_free()
	var script = load("res://scripts/AdminAccountDialog.gd")
	if script == null:
		return
	_account_dialog = script.new()
	add_child(_account_dialog)
	if _account_dialog.has_method("setup"):
		_account_dialog.setup(_auth_node())


func _on_logout_pressed() -> void:
	var auth = _auth_node()
	if auth != null:
		auth.logout()
	fail_msg = ""
	_refresh_state()


func _on_close_requested() -> void:
	# 不销毁：登录窗口会被复用，且登录后可能还挂着修改口令的对话框
	hide()
