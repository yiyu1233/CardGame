extends Node
## 管理员登录状态（自动加载为 AdminAuth）。
##
## 账号数据存在 user://admin.cfg（ConfigFile），键：username / salt / hash /
## failed_count / lock_until / created_at / changed_at。
## 口令**不落盘**：只保存「随机盐 + 口令」的 SHA-256 哈希。
##
## 为什么加盐：不加盐时同一个口令永远算出同一个哈希，任何人拿到文件就能用彩虹表
## （或直接搜网上公开的 "admin123" 哈希）反查出口令；每个账号一份随机盐之后，
## 相同口令在不同机器上也算出不同哈希，彩虹表失效。
## 为什么用 SHA-256 而不是明文/可逆加密：配置文件是可读的文本，可逆加密的密钥
## 必须放在程序里＝等于没加密，哈希是单向的，泄密时无法还原出口令。
##
## 默认账号：admin  默认口令：admin123（首次运行自动创建，界面会提示尽快修改）。
## 首次运行自动建号，登录状态本身只是内存里的标记，不写盘。

signal login_state_changed(logged_in: bool)

const ADMIN_USER := "admin"
const DEFAULT_PASSWORD := "admin123"
const MAX_FAILURES := 5
const LOCK_SECONDS := 60
## 新口令长度下限（含）
const MIN_PASSWORD_LENGTH := 4

const CONFIG_SECTION := "account"

## 存档路径做成成员而不是常量：测试可以用 use_save_path() 指到别的文件，
## 这样测试永远不会覆盖玩家真实的 admin.cfg。
var save_path := "user://admin.cfg"

## 时间源（Unix 秒）。做成可替换的成员只是为了可测：
## 锁定期要 60 秒才到期，测试需要把「现在」直接推到锁定之后，
## 否则一次测试就得真等一分钟。正常运行时保持为空 -> 用系统挂钟。
var clock_source: Callable = Callable()

var is_logged_in := false
var user_name := ""

## 账号数据缓存（磁盘是唯一真相，这里只是免去每次登录都读盘）
var _stats := {
	"username": ADMIN_USER,
	"salt": "",
	"hash": "",
	"failed_count": 0,
	"lock_until": 0,
	"created_at": 0,
	"changed_at": 0,
}


func _ready() -> void:
	_ensure_account()


# ------------------------------ 存档路径 ------------------------------

## 切换存档路径（测试隔离用）。切换后立刻按新路径读取 /（必要时）建号。
func use_save_path(p: String) -> void:
	save_path = p
	_ensure_account()


## 替换时间源（测试用）。传空 Callable 恢复系统挂钟。
func use_clock_source(source: Callable) -> void:
	clock_source = source


# ------------------------------ 账号读写 ------------------------------

## 保证存档存在：不存在或内容坏掉时按默认账号重建。
## 每次 login / 查询前都会调用，避免用户手动删文件后程序直接崩在空数据上。
func _ensure_account() -> void:
	if not _load_account():
		_write_new_account(DEFAULT_PASSWORD)


func _load_account() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		return false
	var user := str(cfg.get_value(CONFIG_SECTION, "username", "")).strip_edges()
	var salt := str(cfg.get_value(CONFIG_SECTION, "salt", ""))
	var hash := str(cfg.get_value(CONFIG_SECTION, "hash", ""))
	if user == "" or salt == "" or hash == "":
		return false
	var now := _now()
	_stats["username"] = user
	_stats["salt"] = salt
	_stats["hash"] = hash
	_stats["failed_count"] = int(cfg.get_value(CONFIG_SECTION, "failed_count", 0))
	_stats["lock_until"] = int(cfg.get_value(CONFIG_SECTION, "lock_until", 0))
	_stats["created_at"] = int(cfg.get_value(CONFIG_SECTION, "created_at", now))
	_stats["changed_at"] = int(cfg.get_value(CONFIG_SECTION, "changed_at", now))
	return true


## 用新口令重建默认账号（首次运行 / reset_account 都走这里）。
func _write_new_account(password: String) -> void:
	var now := _now()
	var salt := _new_salt()
	_stats["username"] = ADMIN_USER
	_stats["salt"] = salt
	_stats["hash"] = _hash_password(salt, password)
	_stats["failed_count"] = 0
	_stats["lock_until"] = 0
	_stats["created_at"] = now
	_stats["changed_at"] = now
	_save_account()


func _save_account() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(CONFIG_SECTION, "username", _stats["username"])
	cfg.set_value(CONFIG_SECTION, "salt", _stats["salt"])
	cfg.set_value(CONFIG_SECTION, "hash", _stats["hash"])
	cfg.set_value(CONFIG_SECTION, "failed_count", int(_stats["failed_count"]))
	cfg.set_value(CONFIG_SECTION, "lock_until", int(_stats["lock_until"]))
	cfg.set_value(CONFIG_SECTION, "created_at", int(_stats["created_at"]))
	cfg.set_value(CONFIG_SECTION, "changed_at", int(_stats["changed_at"]))
	# 生成 user:// 下的目录（首次运行、或测试指向新目录时都要）
	var dir := save_path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := cfg.save(save_path)
	if err != OK:
		push_warning("[Admin] 账号存档写入失败（%s，错误码 %d）" % [save_path, err])


# ------------------------------ 口令哈希 ------------------------------

func _new_salt() -> String:
	var crypto := Crypto.new()
	var bytes := crypto.generate_random_bytes(16)
	if bytes.is_empty():
		# 极端情况下拿不到随机源时兜底（仍然比固定盐好）
		return "%08x%08x" % [randi(), randi()]
	return bytes.hex_encode()


## 只做「盐 + 口令」的 SHA-256，不引入外部依赖。
func _hash_password(salt: String, password: String) -> String:
	return (salt + password).sha256_text()


func _verify(salt: String, hash: String, password: String) -> bool:
	return _hash_password(salt, password) == hash


func _now() -> int:
	if clock_source.is_valid():
		return int(clock_source.call())
	return int(Time.get_unix_time_from_system())


# ------------------------------ 登录 / 退出 ------------------------------

func login(user: String, password: String) -> bool:
	if is_logged_in:
		return true
	_ensure_account()
	var now := _now()
	if _locked_now(now):
		# 锁定期内直接拒绝，并且**不加**失败计数：
		# 否则每次尝试都把 lock_until 往后推，等于锁永远解不开（越试越锁死）。
		print("[Admin] 账号锁定中，剩余 %d 秒" % int(_stats["lock_until"] - now))
		return false
	if _expired_lock(now):
		_reset_failures()
	if user.strip_edges() != str(_stats["username"]):
		_register_failure(now)
		return false
	if not _verify(str(_stats["salt"]), str(_stats["hash"]), password):
		_register_failure(now)
		return false
	_on_login_success()
	return true


func logout() -> void:
	if not is_logged_in:
		return
	is_logged_in = false
	user_name = ""
	print("[Admin] 已退出登录")
	login_state_changed.emit(false)


func _on_login_success() -> void:
	is_logged_in = true
	user_name = str(_stats["username"])
	# 成功即清零失败计数与锁定，并落盘：否则重启后还带着上次的失败次数
	_reset_failures()
	print("[Admin] %s 登录成功" % user_name)
	login_state_changed.emit(true)


func _register_failure(now: int) -> void:
	_stats["failed_count"] = int(_stats["failed_count"]) + 1
	if int(_stats["failed_count"]) >= MAX_FAILURES:
		_stats["lock_until"] = now + LOCK_SECONDS
		print("[Admin] 连续失败 %d 次，锁定 %d 秒" % [MAX_FAILURES, LOCK_SECONDS])
	else:
		print("[Admin] 登录失败（%d/%d）" % [int(_stats["failed_count"]), MAX_FAILURES])
	_save_account()


func _reset_failures() -> void:
	_stats["failed_count"] = 0
	_stats["lock_until"] = 0
	_save_account()


# ------------------------------ 查询 ------------------------------

func failed_attempts() -> int:
	_ensure_account()
	return int(_stats["failed_count"])


func remaining_lock_seconds() -> int:
	_ensure_account()
	var left := int(_stats["lock_until"]) - _now()
	return left if left > 0 else 0


## 当前口令是否仍是内置默认口令（界面据此提醒尽快修改）。
## 每次现场比对哈希，而不是存一个 "is_default" 标记：
## 标记会在用户手动改文件、改回默认口令时和事实脱节。
func using_default_password() -> bool:
	_ensure_account()
	return _verify(str(_stats["salt"]), str(_stats["hash"]), DEFAULT_PASSWORD)


func account_created_at() -> int:
	_ensure_account()
	return int(_stats["created_at"])


func account_changed_at() -> int:
	_ensure_account()
	return int(_stats["changed_at"])


# ------------------------------ 修改 / 重置口令 ------------------------------

## 修改口令。要求：当前处于登录态、旧口令正确、新口令长度 >= MIN_PASSWORD_LENGTH。
## 新旧口令相同是允许的（相当于重新确认一次）。
func change_password(old_pw: String, new_pw: String) -> bool:
	if not is_logged_in:
		print("[Admin] 尚未登录，拒绝修改口令")
		return false
	_ensure_account()
	if not _verify(str(_stats["salt"]), str(_stats["hash"]), old_pw):
		print("[Admin] 修改口令失败：旧口令错误")
		return false
	if new_pw.strip_edges().length() < MIN_PASSWORD_LENGTH:
		print("[Admin] 修改口令失败：新口令至少 %d 位" % MIN_PASSWORD_LENGTH)
		return false
	# 每次改口令都换一份新盐：旧哈希对应的盐从此不再可用于任何比对
	var salt := _new_salt()
	_stats["salt"] = salt
	_stats["hash"] = _hash_password(salt, new_pw)
	_stats["changed_at"] = _now()
	_reset_failures()
	print("[Admin] 口令已修改")
	return true


## 恢复默认账号（admin / DEFAULT_PASSWORD），并强制退出登录。供管理员与测试使用。
func reset_account() -> void:
	_write_new_account(DEFAULT_PASSWORD)
	if is_logged_in:
		is_logged_in = false
		user_name = ""
		login_state_changed.emit(false)
	print("[Admin] 账号已重置为默认口令")


# ------------------------------ 内部判断 ------------------------------

func _locked_now(now: int) -> bool:
	return int(_stats["lock_until"]) > now


## 上一次锁已经自然到期（lock_until 非 0 但已过期）
func _expired_lock(now: int) -> bool:
	return int(_stats["lock_until"]) > 0 and int(_stats["lock_until"]) <= now
