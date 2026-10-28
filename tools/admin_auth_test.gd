extends SceneTree
## 管理员登录测试：默认账号、加盐哈希存档（文件里搜不到明文口令）、失败计数与锁定、
## 修改口令流程、已登录形态与登录窗口 / 修改口令对话框的界面行为。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/admin_auth_test.gd
##
## 说明：
##   * --script 模式下自动加载单例不能作为全局标识符静态引用（编译期解析不到），
##     所以这里用 root.get_node_or_null("AdminAuth") 拿到节点，再用无类型变量动态调用；
##   * 存档必须隔离：开头把 save_path 指到 user://test_admin.cfg 并删掉该文件，
##     绝不能让测试覆盖玩家真实的 user://admin.cfg。

const TEST_PATH := "user://test_admin.cfg"
# 不写成 AdminAuth.MAX_FAILURES 这类静态访问：直接用常量，锁定期也便于断言
const MAX_FAILURES := 5
const LOCK_SECONDS := 60

var _fails := 0
var _frames := 0
var _phase := 0
var _auth
var _fail_lines: Array[String] = []
var _dlg = null
var _login_dlg = null
## 人为冻结系统挂钟用的偏移（秒）。锁定期在真实环境里要等 60 秒才到期，
## 本测试把「现在」直接推到锁定之后来验证到期分支；配合一次真实短等待，
## 可证明「剩余时间确实随时间递减」。
var _clock_offset := 0


func _process(_delta: float) -> bool:
	_frames += 1
	# 每帧推进一个阶段；frozen clock 那一帧用来验证「提前推后挂钟」的到期分支
	match _phase:
		0:
			_phase = 1
			_setup()
		1:
			_phase = 2
			_run_phase1_login()
		2:
			_phase = 3
			_run_phase2_failures_and_lock()
		3:
			_phase = 4
			_run_phase2_after_adjust()
		4:
			_phase = 5
			_run_phase3_change_password()
		5:
			_phase = 6
			_run_phase4_account_dialog()
		6:
			_phase = 7
			_run_phase5_login_dialog()
		7:
			_phase = 8
			_run_phase6_reset()
		8:
			_finish()
			return true
	if _frames > 200000:
		print("[FAIL] 帧数预算用尽（%d 帧 / 已跑 %.1f 秒），测试被强制结束" % [
			_frames, float(Time.get_ticks_msec()) / 1000.0])
		_finish()
		return true
	return false


# ------------------------------ 准备 ------------------------------

func _setup() -> void:
	# 先删测试存档，保证从「首次运行」的状态开始
	if FileAccess.file_exists(TEST_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	_auth = root.get_node_or_null("AdminAuth")
	_check(_auth != null, "AdminAuth 自动加载可用（root/AdminAuth）")
	if _auth == null:
		_finish()
		return
	# 隔离存档：从这里开始所有读写都只碰 user://test_admin.cfg
	_auth.use_save_path(TEST_PATH)
	_check(str(_auth.save_path) == TEST_PATH, "测试存档已隔离到 %s" % TEST_PATH)


# ------------------------------ 阶段 1：默认账号 ------------------------------

func _run_phase1_login() -> void:
	_check(_auth.using_default_password(), "首次运行自动创建默认账号（admin / 默认口令）")
	_check(not _auth.is_logged_in, "初始状态为未登录")
	_check(_auth.failed_attempts() == 0, "初始失败次数为 0")
	_check(_auth.remaining_lock_seconds() == 0, "初始没有锁定（剩余 %d 秒）" % int(_auth.remaining_lock_seconds()))
	_check(_auth.login("admin", "admin123"), "默认账号可用默认口令登录")
	_check(bool(_auth.is_logged_in), "登录后 is_logged_in 为真")
	_check(str(_auth.user_name) == "admin", "登录后 user_name 为 admin（%s）" % str(_auth.user_name))
	_check(_auth.logout() == null and not _auth.is_logged_in, "logout() 后 is_logged_in 为假")

	# 存档必须存在且不含明文口令
	_check(FileAccess.file_exists(TEST_PATH), "登录后生成了存档文件 %s" % TEST_PATH)
	var text := _read_save_text()
	_check(text.find("admin123") < 0, "存档文本里搜不到默认明文口令")
	_check(text.find("\npassword") < 0 and text.find("\npasswd") < 0, "存档里没有 password / passwd 键")
	_check(text.find("salt") >= 0 and text.find("hash") >= 0,
		"存档以 salt + hash 形式保存口令")


# ------------------------------ 阶段 2：失败计数与锁定 ------------------------------

func _run_phase2_failures_and_lock() -> void:
	_check(not _auth.login("admin", "wrong-pass"), "错误口令登录失败")
	_check(_auth.failed_attempts() == 1, "失败计数 +1（%d）" % int(_auth.failed_attempts()))

	# 连续失败到上限
	for i in range(MAX_FAILURES - 1):
		_auth.login("admin", "wrong-pass")
	_check(_auth.failed_attempts() == MAX_FAILURES,
		"连续失败 %d 次后计数到上限（%d）" % [MAX_FAILURES, int(_auth.failed_attempts())])
	_check(_auth.remaining_lock_seconds() > 0,
		"达到上限即进入锁定（剩余 %d 秒）" % int(_auth.remaining_lock_seconds()))

	# 锁定期内：即使口令正确也拒绝，而且不增加计数
	_check(not _auth.login("admin", "admin123"), "锁定期内正确口令也拒绝登录")
	var remain_a := int(_auth.remaining_lock_seconds())
	_check(remain_a > 0, "锁定剩余时间可读出（%d 秒）" % remain_a)
	for i in range(3):
		_auth.login("admin", "wrong-pass")
	_check(_auth.failed_attempts() == MAX_FAILURES,
		"锁定期内继续尝试不增加计数（仍为 %d）" % int(_auth.failed_attempts()))
	_check(int(_auth.remaining_lock_seconds()) <= remain_a,
		"锁定期内剩余时间只会减少，不会因重试被推后")

	# 锁定期内「剩余时间会随时间递减」：这里真实地等一小会儿，再对比剩余秒数。
	# 不做「真等满 60 秒」——那样单次测试要 1 分钟以上，而且和 LOCK_SECONDS 常量耦合；
	# 到期分支改用下面的冻结挂钟偏移来验证（见 _run_phase2_after_adjust）。
	var wait_ms := 2200
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < wait_ms:
		OS.delay_msec(50)
	var remain_b := int(_auth.remaining_lock_seconds())
	_check(remain_b < remain_a,
		"锁定期剩余时间随时间递减（%d -> %d 秒）" % [remain_a, remain_b])
	_check(_auth.failed_attempts() == MAX_FAILURES,
		"等待期间没有登录尝试，计数保持 %d" % MAX_FAILURES)


func _run_phase2_after_adjust() -> void:
	# 把「现在」视为锁定到点之后：验证 lock_until 过期 -> 自动解锁并清零计数
	var lock_until := _read_cfg_value("lock_until", 0)
	var real_now := int(Time.get_unix_time_from_system())
	_check(lock_until > real_now, "存档里的 lock_until 确实在将来（+%d 秒）" % (lock_until - real_now))
	# 时间源做成可替换的，测试把「现在」直接推到锁定之后
	_auth.use_clock_source(_clock_now)
	_clock_offset = lock_until - real_now + 1
	_check(_auth.remaining_lock_seconds() == 0, "锁定到点后 remaining_lock_seconds() 归零")
	_check(_auth.login("admin", "admin123"), "锁定到点后正确口令可以登录")
	_check(_auth.failed_attempts() == 0, "到点登录成功后失败计数清零（%d）" % int(_auth.failed_attempts()))
	_auth.use_clock_source(Callable())
	_clock_offset = 0
	_auth.logout()


# ------------------------------ 阶段 3：修改口令 ------------------------------

func _run_phase3_change_password() -> void:
	_check(not _auth.change_password("admin123", "whatever1"), "未登录时拒绝修改口令")
	_auth.login("admin", "admin123")

	_check(not _auth.change_password("wrong-old", "newpass1"), "旧口令错误时拒绝修改")
	_check(not _auth.change_password("admin123", "abc"), "新口令太短（3 位）时拒绝修改")
	_check(not _auth.change_password("admin123", ""), "新口令为空时拒绝修改")
	_check(_auth.using_default_password(), "两次失败的修改都没有改动存档（仍是默认口令）")
	_check(_auth.change_password("admin123", "admin123"), "新旧口令相同是允许的")
	_check(_auth.change_password("admin123", "newpass1"), "旧口令正确且新口令 >= 4 位时修改成功")
	_check(not _auth.using_default_password(), "修改后 using_default_password() 为假")

	# 修改结果必须落盘：重新读盘后新口令生效、旧口令失效
	_auth.use_save_path(TEST_PATH)
	_check(_auth.login("admin", "newpass1"), "重新读盘后新口令可以登录")
	_auth.logout()
	_check(not _auth.login("admin", "admin123"), "重新读盘后旧口令失效")
	_check(_auth.failed_attempts() == 1, "旧口令失败计数 +1（%d）" % int(_auth.failed_attempts()))
	_auth.login("admin", "newpass1")
	_check(_auth.failed_attempts() == 0, "再次成功登录后计数清零")

	var text := _read_save_text()
	_check(text.find("newpass1") < 0, "存档文本里搜不到新明文口令（newpass1）")
	_check(text.find("admin123") < 0, "存档文本里仍然搜不到默认明文口令")

	_auth.logout()
	_check(not bool(_auth.is_logged_in), "logout() 后 is_logged_in 为假")
	_check(str(_auth.user_name) == "", "logout() 后 user_name 清空")


# ------------------------------ 阶段 4：修改口令对话框 ------------------------------

func _run_phase4_account_dialog() -> void:
	_auth.login("admin", "newpass1")
	var script = load("res://scripts/AdminAccountDialog.gd")
	_check(script != null, "可以 load() 修改口令对话框脚本（无需 class_name）")
	if script == null:
		return
	_dlg = script.new()
	root.add_child(_dlg)
	_dlg.setup(_auth)
	_dlg._build_ui()
	_check(_dlg.old_edit != null and _dlg.new_edit != null and _dlg.confirm_edit != null and _dlg.result_label != null,
		"修改口令对话框构建出旧 / 新 / 确认三个输入框与结果提示")

	_dlg.old_edit.text = "newpass1"
	_dlg.new_edit.text = "abcdef"
	_dlg.confirm_edit.text = "abcdeg"
	_dlg._on_confirm_pressed()
	_check(str(_dlg.result_msg).find("不一致") >= 0, "两次输入不一致时给出具体提示（%s）" % str(_dlg.result_msg))

	_dlg.old_edit.text = "newpass1"
	_dlg.new_edit.text = ""
	_dlg.confirm_edit.text = ""
	_dlg._on_confirm_pressed()
	_check(str(_dlg.result_msg).find("新口令") >= 0, "新口令为空时给出具体提示（%s）" % str(_dlg.result_msg))

	_dlg.old_edit.text = "newpass1"
	_dlg.new_edit.text = "abc"
	_dlg.confirm_edit.text = "abc"
	_dlg._on_confirm_pressed()
	_check(str(_dlg.result_msg).find("太短") >= 0, "新口令太短时给出具体提示（%s）" % str(_dlg.result_msg))

	_dlg.old_edit.text = "not-the-old-one"
	_dlg.new_edit.text = "zzzz99"
	_dlg.confirm_edit.text = "zzzz99"
	_dlg._on_confirm_pressed()
	_check(str(_dlg.result_msg).find("旧口令") >= 0, "旧口令错误时给出具体提示（%s）" % str(_dlg.result_msg))

	_dlg.old_edit.text = "newpass1"
	_dlg.new_edit.text = "zzzz99"
	_dlg.confirm_edit.text = "zzzz99"
	# 成功前先检查规则提示（成功后对话框会 queue_free）
	_check(_dlg.rule_text().find("至少 %d 位" % _dlg.MIN_LEN) >= 0,
		"修改口令对话框里标明了「至少 4 位」的规则（%s）" % _dlg.rule_text())
	_dlg._on_confirm_pressed()
	_check(bool(_dlg.ok), "输入合法时对话框返回成功")
	_check(str(_dlg.result_msg).find("成功") >= 0, "成功时给出成功提示（%s）" % str(_dlg.result_msg))
	_check(_dlg.is_queued_for_deletion(), "成功修改后对话框自动关闭")

	_auth.use_save_path(TEST_PATH)
	# 注意：login() 在「已登录」时直接返回 true（不会重新校验口令），
	# 所以验证旧口令失效前必须先退出登录，否则测的是登录态而不是口令。
	_auth.logout()
	_check(not _auth.login("admin", "newpass1"), "对话框改过的旧口令随即失效")
	_check(_auth.login("admin", "zzzz99"), "对话框设置的新口令可以登录")


# ------------------------------ 阶段 5：登录窗口界面 ------------------------------

func _run_phase5_login_dialog() -> void:
	if not bool(_auth.is_logged_in):
		_auth.login("admin", "zzzz99")
	# 让上一阶段 queue_free 的对话框真正离开场景树
	if _dlg != null and is_instance_valid(_dlg):
		_dlg.queue_free()
		_dlg = null

	var script = load("res://scripts/LoginDialog.gd")
	_login_dlg = script.new()
	root.add_child(_login_dlg)
	_check(_login_dlg.user_edit != null and _login_dlg.pass_edit != null and _login_dlg.tip_label != null,
		"登录窗口构建出 user_edit / pass_edit / tip_label")
	_check(not _login_dlg._form_root.visible, "已登录时打开窗口直接显示登录状态（不显示登录表单）")
	_check(_login_dlg._status_root.visible, "已登录时显示状态区（含修改口令 / 退出登录按钮）")
	_check(_find_text(_login_dlg._status_root, "修改口令"), "状态区有「修改口令」按钮")
	_check(_find_text(_login_dlg._status_root, "退出登录"), "状态区有「退出登录」按钮")
	_check(str(_login_dlg.status_text()).find("口令已修改") >= 0,
		"已登录状态文字说明了当前口令状态（%s）" % str(_login_dlg.status_text()))

	# 用真实按钮信号退出登录
	var out_btn := _find_button(_login_dlg._status_root, "退出登录")
	_check(out_btn != null, "能找到并按下「退出登录」按钮")
	if out_btn != null:
		out_btn.emit_signal("pressed")
	_check(not bool(_auth.is_logged_in), "按下「退出登录」后 AdminAuth 退出登录")
	_check(_login_dlg._form_root.visible, "退出后窗口切回登录表单")

	# 空输入的具体提示
	_login_dlg.user_edit.text = "   "
	_login_dlg.pass_edit.text = "x"
	_login_dlg._on_login_pressed()
	_check(str(_login_dlg.fail_msg).find("账号") >= 0, "账号为空时提示「请输入账号」（%s）" % str(_login_dlg.fail_msg))

	_login_dlg.user_edit.text = "admin"
	_login_dlg.pass_edit.text = ""
	_login_dlg._on_login_pressed()
	_check(str(_login_dlg.fail_msg).find("口令") >= 0, "口令为空时提示「请输入口令」（%s）" % str(_login_dlg.fail_msg))

	# 口令错误的具体提示（锁定期之外的普通失败）
	_login_dlg.pass_edit.text = "definitely-wrong"
	_login_dlg._on_login_pressed()
	_check(not bool(_auth.is_logged_in), "窗口中错误口令不会登录成功")
	_check(str(_login_dlg.fail_msg).find("口令错误") >= 0, "口令错误时给出具体提示（%s）" % str(_login_dlg.fail_msg))
	_check(str(_login_dlg.tip_label.text).find("口令错误") >= 0, "提示同时显示在窗口的 tip_label 上")
	_check(_auth.failed_attempts() == 1, "窗口里的失败也计入失败次数（%d）" % int(_auth.failed_attempts()))

	# 密码框显示 / 隐藏
	_login_dlg._show_btn.set_pressed(true)
	_check(not _login_dlg.pass_edit.secret, "切换按钮让密码框显示明文（secret = false）")
	_login_dlg._show_btn.set_pressed(false)
	_check(_login_dlg.pass_edit.secret, "再切一次恢复遮蔽（secret = true）")

	# 两个输入框回车提交（text_submitted -> 提交登录）
	_login_dlg.user_edit.text = "admin"
	_login_dlg.pass_edit.text = "zzzz99"
	_login_dlg.pass_edit.text_submitted.emit("zzzz99")
	_check(bool(_auth.is_logged_in), "口令框按回车即提交登录")
	_check(not _login_dlg._form_root.visible and _login_dlg._status_root.visible,
		"登录成功后窗口就地切换为已登录状态")
	_check(_login_dlg.pass_edit.text == "", "登录成功后窗口里不残留口令明文")

	# 已登录时再按登录按钮不应把状态搞坏
	_login_dlg._on_login_pressed()
	_check(bool(_auth.is_logged_in), "已登录时重复提交不会把登录状态弄丢")

	# 「修改口令」按钮应挂出修改口令对话框
	var pw_btn := _find_button(_login_dlg._status_root, "修改口令")
	_check(pw_btn != null, "能找到并按下「修改口令」按钮")
	if pw_btn != null:
		pw_btn.emit_signal("pressed")
	_check(_login_dlg._account_dialog != null and is_instance_valid(_login_dlg._account_dialog),
		"按下「修改口令」后挂出了修改口令对话框")
	if _login_dlg._account_dialog != null and is_instance_valid(_login_dlg._account_dialog):
		var rule_text := str(_login_dlg._account_dialog.rule_text())
		_check(rule_text.find("4 位") >= 0, "登录窗口挂出的修改口令对话框也带「至少 4 位」规则（%s）" % rule_text)


# ------------------------------ 阶段 6：reset_account 与真实存档隔离 ------------------------------

func _run_phase6_reset() -> void:
	_auth.reset_account()
	_check(_auth.using_default_password(), "reset_account() 恢复默认口令")
	_check(not bool(_auth.is_logged_in), "reset_account() 会退出登录")
	_check(_auth.failed_attempts() == 0, "reset_account() 清零失败计数")
	_check(_auth.remaining_lock_seconds() == 0, "reset_account() 清除锁定")
	_check(_auth.login("admin", "admin123"), "重置后默认口令可登录")
	_auth.logout()

	# 隔离性：切换回默认路径后再指回测试路径，测试期间没有碰真实 admin.cfg
	_auth.use_save_path("user://admin.cfg")
	_check(str(_auth.save_path) == "user://admin.cfg", "保存路径可以切回默认 user://admin.cfg")
	_check(FileAccess.file_exists(TEST_PATH), "隔离用的测试存档仍在 %s" % TEST_PATH)
	_auth.use_save_path(TEST_PATH)

	if _login_dlg != null and is_instance_valid(_login_dlg):
		_login_dlg.queue_free()
		_login_dlg = null
	if _dlg != null and is_instance_valid(_dlg):
		_dlg.queue_free()
		_dlg = null


# ------------------------------ 辅助 ------------------------------

## 人为冻结挂钟：测试要验证「锁定期到点」这条分支，但又不想真等 60 秒。
## 只影响本次进程内的判断，不写回文件。
func _clock_now() -> int:
	return int(Time.get_unix_time_from_system()) + _clock_offset


func _read_cfg_value(key: String, fallback: int) -> int:
	var cfg := ConfigFile.new()
	if cfg.load(TEST_PATH) != OK:
		return fallback
	return int(cfg.get_value("account", key, fallback))


func _read_save_text() -> String:
	var f := FileAccess.open(TEST_PATH, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


## 诊断用：打印节点的直接子节点名字
func _child_names(node: Node) -> Array:
	var names := []
	for child in node.get_children():
		names.append(child.name)
	return names


## 在子树里找按钮（按文本），用于走真实信号而不是直接调私有方法
func _find_button(root_node: Node, text: String) -> Button:
	if root_node == null:
		return null
	for child in root_node.get_children():
		if child is Button and (child as Button).text == text:
			return child as Button
		var deeper := _find_button(child, text)
		if deeper != null:
			return deeper
	return null


func _find_text(root_node: Node, text: String) -> bool:
	if root_node == null:
		return false
	for child in root_node.get_children():
		if child is Button and (child as Button).text == text:
			return true
		if _find_text(child, text):
			return true
	return false


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
	print("=== 管理员登录测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
