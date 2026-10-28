extends Control
## 修改管理员口令的模态对话框（纯代码构建，可复用）。
##
## 刻意 **不使用 class_name**：新增 class_name 需要编辑器刷新全局 class 缓存，
## 在只跑 --headless --script 的工作流里会带来额外干扰；外部用 load() 即可。
##
## 不依赖 Main 或任何场景文件，也不静态引用自动加载标识符：
## 目标 AdminAuth 通过 setup() 注入，注入前默认去 /root/AdminAuth 找。

## 修改成功
signal password_changed()
## 用户取消 / 关闭
signal canceled()

## 与 AdminAuth.MIN_PASSWORD_LENGTH 对齐（这里再放一份是为了让本对话框
## 在没有任何 auth 的情况下也能把规则提示画出来）
const MIN_LEN := 4

## 最近一次结果（测试与调试用）
var result_msg := ""
var ok := false

var old_edit: LineEdit
var new_edit: LineEdit
var confirm_edit: LineEdit
var result_label: Label

var _auth = null
var _dimmer: ColorRect
var _panel: PanelContainer


## 注入要操作的账号后端（通常是 AdminAuth 自动加载节点）
func setup(auth) -> void:
	_auth = auth


func _auth_node():
	if _auth == null or not is_instance_valid(_auth):
		_auth = get_node_or_null("/root/AdminAuth")
	return _auth


func _ready() -> void:
	_build_ui()


## 幂等构建：即使外部先手动调了一次、随后节点入树又触发 _ready，
## 也只会留下唯一一套控件（不会出现两块重叠面板）。
func _build_ui() -> void:
	for child in get_children():
		child.free()

	# 全屏遮罩：既是模态的视觉表现，也吃掉点击避免穿透到下层界面
	_dimmer = ColorRect.new()
	_dimmer.color = Color(0, 0, 0, 0.45)
	_dimmer.name = "Dimmer"
	_dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dimmer)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(380, 0)
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "MarginContainer"
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.name = "VBoxContainer"
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "修改管理员口令"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	vbox.add_child(_make_hint("旧口令"))
	old_edit = _make_secret_edit("请输入当前口令")
	vbox.add_child(old_edit)

	vbox.add_child(_make_hint("新口令"))
	new_edit = _make_secret_edit("至少 %d 位" % MIN_LEN)
	vbox.add_child(new_edit)

	vbox.add_child(_make_hint("确认新口令"))
	confirm_edit = _make_secret_edit("再输一次")
	vbox.add_child(confirm_edit)

	var rule := Label.new()
	rule.name = "RuleHint"
	rule.text = "规则：新口令至少 %d 位；允许与旧口令相同。" % MIN_LEN
	rule.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(rule)

	result_label = Label.new()
	result_label.name = "ResultLabel"
	result_label.text = ""
	result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result_label.custom_minimum_size = Vector2(0, 44)
	vbox.add_child(result_label)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	var ok_btn := Button.new()
	ok_btn.text = "确认修改"
	ok_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok_btn.pressed.connect(_on_confirm_pressed)
	btn_row.add_child(ok_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(cancel_btn)

	# 三个输入框回车都等于「确认修改」
	old_edit.text_submitted.connect(_on_field_submitted)
	new_edit.text_submitted.connect(_on_field_submitted)
	confirm_edit.text_submitted.connect(_on_field_submitted)

	# 纯展示文字统一装饰化（按钮等可交互控件保持原样）
	for node in [title, rule]:
		UiUtil.make_decorative(node)

	old_edit.grab_focus()
	_refresh_hint()


func _make_hint(text: String) -> Label:
	var l := Label.new()
	l.text = text
	UiUtil.make_decorative(l)
	return l


func _make_secret_edit(placeholder: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = true
	return e


## 结果提示（不改动任何输入框内容，方便调用方断言）
func _set_result(text: String) -> void:
	result_msg = text
	ok = false
	if result_label != null:
		result_label.text = text


## 规则提示文字（界面与测试都读它；不用去猜节点路径）
func rule_text() -> String:
	if _panel == null:
		return ""
	var l: Node = _panel.get_node_or_null("MarginContainer/VBoxContainer/RuleHint")
	return (l as Label).text if l != null else ""


func _refresh_hint() -> void:
	var auth = _auth_node()
	if auth != null and bool(auth.using_default_password()):
		result_label.text = "当前仍在使用默认口令，建议立即修改。"
	else:
		result_label.text = ""


func _on_field_submitted(_text: String) -> void:
	_on_confirm_pressed()


func _on_confirm_pressed() -> void:
	var auth = _auth_node()
	if auth == null:
		_set_result("内部错误：AdminAuth 不可用")
		return

	var old_pw := old_edit.text
	var new_pw := new_edit.text
	var confirm_pw := confirm_edit.text

	# 按「越早能判定、越具体」的顺序校验，提示才不至于误导
	if old_pw == "":
		_set_result("请输入旧口令")
		return
	if new_pw == "":
		_set_result("请输入新口令")
		return
	if new_pw.strip_edges().length() < MIN_LEN:
		_set_result("新口令太短：至少需要 %d 位" % MIN_LEN)
		return
	if new_pw != confirm_pw:
		_set_result("两次输入的新口令不一致")
		return

	ok = bool(auth.change_password(old_pw, new_pw))
	if ok:
		result_msg = "口令修改成功"
		result_label.text = result_msg
		old_edit.text = ""
		new_edit.text = ""
		confirm_edit.text = ""
		password_changed.emit()
		# 改完就关：留在界面上没有别的事可做
		_dismiss()
		return
	# 走到这里说明旧口令校验或长度校验被后端拒绝，给具体原因
	_set_result(_describe_reject(auth))


func _describe_reject(_auth) -> String:
	# 长度在本地已经先判过一次，能走到这里基本都是旧口令不匹配
	if new_edit.text.strip_edges().length() < MIN_LEN:
		return "新口令太短：至少需要 %d 位" % MIN_LEN
	return "旧口令错误"


func _on_cancel_pressed() -> void:
	_dismiss(true)


func _dismiss(canceled_by_user := false) -> void:
	if canceled_by_user:
		canceled.emit()
	queue_free()
