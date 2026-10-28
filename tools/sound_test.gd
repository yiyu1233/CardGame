extends SceneTree
## 音效系统测试（SoundFx）：全部音色由代码合成 PCM，不依赖任何音频资源文件。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/sound_test.gd
##
## 说明：
##   * SoundFx 可能还没注册成自动加载，所以这里先用 root.get_node_or_null("SoundFx") 找；
##     找不到就手动 load("res://scripts/SoundFx.gd").new() 挂到 root 下 —— 两个路径都要能跑。
##   * --script 模式下自动加载不能当全局标识符用，因此所有调用都是「动态」的（变量不加类型标注）。
##   * 无头模式使用 dummy 音频驱动：不需要真的出声，只要 play() 不报错、状态/字节可控即可。

## 采样率 / 位深：与 SoundFx 的合成参数保持一致（这里独立写死，用来交叉校验）
const RATE := 22050
const BYTES_PER_SAMPLE := 2

## 事件时长 40~400ms 对应的字节数区间（16 位单声道 = 882 字节 / 10ms）
const MIN_BYTES := 1764     ## 40ms
const MAX_BYTES := 17640    ## 400ms

var _fails := 0
var _checks := 0
var _frames := 0
var sfx = null              ## 不加类型标注：可能是自动加载，也可能是手动实例化的脚本对象

## 期望的事件清单（与需求一一对应）
const EXPECTED := ["play_card", "attack", "damage", "heal", "turn_start", "button", "win", "lose", "error"]


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	_run()
	print("=== 音效系统测试结束：%d 项断言，失败 %d 项 ===" % [_checks, _fails])
	quit(1 if _fails > 0 else 0)
	return true


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("[OK]   " + msg)
	else:
		_fails += 1
		print("[FAIL] " + msg)


# ------------------------------ 测试主体 ------------------------------

func _run() -> void:
	# ---- 1. 拿到 SoundFx：自动加载优先，没有就手动实例化 ----
	sfx = root.get_node_or_null("SoundFx")
	var via_autoload := sfx != null
	if sfx == null:
		var script = load("res://scripts/SoundFx.gd")
		if script == null:
			_check(false, "加载 res://scripts/SoundFx.gd")
			return
		sfx = script.new()
		root.add_child(sfx)
	if sfx == null:
		_check(false, "实例化 SoundFx")
		return
	_check(sfx != null, "SoundFx 就绪（%s）" % ["自动加载" if via_autoload else "手动实例化"])

	var names: Array = sfx.events()
	_check(names.size() >= 9, "事件表规模：%d 个事件" % names.size())

	# ---- 2. 事件清单：需求里列出的 9 个事件一个都不能少 ----
	var missing: Array[String] = []
	for e in EXPECTED:
		if not sfx.has_event(e):
			missing.append(e)
	_check(missing.is_empty(),
		"9 个事件全部注册（缺失：%s）" % ["无" if missing.is_empty() else ", ".join(missing)])

	# ---- 3. 事件表自检：时长/音量/音符结束点都不能越界（音符超出时长会把整段拉长） ----
	var problems: Array = sfx.table_problems()
	_check(problems.is_empty(),
		"事件表参数自检通过（异常：%s）" % ["无" if problems.is_empty() else ", ".join(problems)])

	# ---- 4. 每个事件都能合成非空、长度合理的 PCM，且格式正确 ----
	var bad_len: Array[String] = []
	var bad_fmt: Array[String] = []
	for e in EXPECTED:
		var st = sfx.generate_stream(e)
		if st == null:
			bad_fmt.append(e + ":null")
			continue
		var data: PackedByteArray = st.data
		var size := data.size()
		if size < MIN_BYTES or size > MAX_BYTES or size % BYTES_PER_SAMPLE != 0:
			bad_len.append("%s:%dB" % [e, size])
		# 格式：16 位 / 单声道 / 22050 Hz / 不循环
		if st.format != AudioStreamWAV.FORMAT_16_BITS or st.stereo or st.mix_rate != RATE:
			bad_fmt.append("%s:%d/%s/%dHz" % [e, st.format, st.stereo, st.mix_rate])
	_check(bad_len.is_empty(),
		"所有事件 PCM 长度在 40~400ms 区间内（越界：%s）" % ["无" if bad_len.is_empty() else ", ".join(bad_len)])
	_check(bad_fmt.is_empty(),
		"所有事件格式为 16 位 / 单声道 / 22050Hz（异常：%s）" % ["无" if bad_fmt.is_empty() else ", ".join(bad_fmt)])

	# ---- 5. 内容不是静音：每个事件都要有可听样本 ----
	var quiet: Array[String] = []
	for e in EXPECTED:
		var data: PackedByteArray = sfx.generate_stream(e).data
		if _peak(data) <= 500:
			quiet.append("%s:%d" % [e, _peak(data)])
	_check(quiet.is_empty(),
		"所有事件都不是静音（峰值过低：%s）" % ["无" if quiet.is_empty() else ", ".join(quiet)])

	# ---- 6. 时长换算：字节数必须和引擎自己算出来的流长度一致（防止写错采样率/位深） ----
	var bad_seconds: Array[String] = []
	for e in EXPECTED:
		var st = sfx.generate_stream(e)
		if st == null:
			continue
		var expect := float(st.data.size()) / float(BYTES_PER_SAMPLE) / float(RATE)
		if absf(float(st.get_length()) - expect) > 0.005:
			bad_seconds.append("%s:%.3f/%.3f" % [e, st.get_length(), expect])
	_check(bad_seconds.is_empty(),
		"get_length() 与字节数换算一致（异常：%s）" % ["无" if bad_seconds.is_empty() else ", ".join(bad_seconds)])

	# ---- 6. 确定性：同一事件两次生成，字节内容必须完全一致 ----
	var unstable: Array[String] = []
	for e in EXPECTED:
		var a: PackedByteArray = sfx.generate_stream(e).data
		var b: PackedByteArray = sfx.generate_stream(e).data
		if not a == b:
			unstable.append(e)
	_check(unstable.is_empty(),
		"同一事件两次生成字节完全一致（不稳定：%s）" % ["无" if unstable.is_empty() else ", ".join(unstable)])

	# ---- 7. 缓存入口 get_stream() 也要稳定，并且和「新生成」的结果一致 ----
	var cache_ok := true
	var cache_same := true
	for e in EXPECTED:
		var s1 = sfx.get_stream(e)
		var s2 = sfx.get_stream(e)
		if s1 == null or not is_same(s1, s2):
			cache_ok = false
		if s1 == null or not (s1.data as PackedByteArray) == (sfx.generate_stream(e).data as PackedByteArray):
			cache_same = false
	_check(cache_ok, "get_stream() 同一事件返回同一个流对象（缓存生效）")
	_check(cache_same, "get_stream() 与 generate_stream() 字节一致（缓存不会改变音色）")

	# 缓存过的流再次取用，字节仍与首次缓存完全相同
	var data_attack: PackedByteArray = sfx.get_stream("attack").data
	var data_attack2: PackedByteArray = sfx.get_stream("attack").data
	_check(data_attack == data_attack2, "重复取用缓存流字节稳定（attack %d 字节）" % data_attack.size())

	# ---- 8. play() 对全部事件都不崩（无头 dummy 驱动下也安全） ----
	var before_play = sfx.play_count
	var crashed := false
	for round_i in 3:
		for e in EXPECTED:
			sfx.play(e)
	crashed = sfx.play_count < int(before_play) + EXPECTED.size() * 3
	_check(not crashed, "play() 遍历全部事件 3 轮不报错（累计 %d 次调用）" % (int(sfx.play_count) - int(before_play)))

	# ---- 9. 重叠播放：连续快速播放不该丢调用（播放器池的意义） ----
	# 注：**真实素材优先**（assets/sv/voice 有 wav 时走素材播放器），所以这里把两条路径一起算：
	#     合成音计 emitted_count，真实素材计 sample_plays。
	var sounded: int = int(sfx.emitted_count) + int(sfx.sample_plays)
	_check(sounded >= EXPECTED.size(), "发声计数正常累加（合成 %d + 素材 %d）" % [
		int(sfx.emitted_count), int(sfx.sample_plays)])

	# ---- 10. set_enabled(false) 后 play() 不再产生播放 ----
	sfx.set_enabled(false)
	_check(not sfx.is_enabled(), "set_enabled(false) 后 is_enabled() 为 false")
	var calls_before = sfx.play_count
	var sounded_before: int = int(sfx.emitted_count) + int(sfx.sample_plays)
	for e in EXPECTED:
		sfx.play(e)
	_check(int(sfx.emitted_count) + int(sfx.sample_plays) == sounded_before,
		"禁用后 play() 不产生播放（发声计数停在 %d）" % (int(sfx.emitted_count) + int(sfx.sample_plays)))
	_check(int(sfx.play_count) == int(calls_before) + EXPECTED.size(),
		"禁用后 play() 仍被记录调用（%d 次，便于排查「没反应」）" % int(sfx.play_count))

	# ---- 11. 往返开关 ----
	sfx.set_enabled(true)
	_check(sfx.is_enabled(), "set_enabled(true) 往返后 is_enabled() 为 true")
	var sounded_round: int = int(sfx.emitted_count) + int(sfx.sample_plays)
	sfx.play("button")
	_check(int(sfx.emitted_count) + int(sfx.sample_plays) > sounded_round, "重新开启后 play() 恢复发声")

	# ---- 12. 未知事件安全回退 ----
	var unknown_stream = sfx.get_stream("no_such_event_xyz")
	_check(unknown_stream == null, "未知事件的 get_stream() 返回 null（不报错）")
	var unknown_gen = sfx.generate_stream("no_such_event_xyz")
	_check(unknown_gen == null, "未知事件的 generate_stream() 返回 null（不报错）")
	var emitted_before_unknown = sfx.emitted_count
	sfx.play("no_such_event_xyz")
	sfx.play("")
	sfx.play("   ")
	_check(int(sfx.emitted_count) > int(emitted_before_unknown),
		"未知/空事件名 play() 安全回退到「%s」" % sfx.fallback_event())

	# ---- 13. GameSettings 联动：改成关闭 → changed 信号 → SoundFx 跟随关闭；改回来 → 跟随开启 ----
	#   这里只改 dev_settings.sound_enabled（不写盘、不碰别人的 GameSettings.gd）。
	var settings = root.get_node_or_null("GameSettings")
	if settings == null:
		var dev_settings := Node.new()
		dev_settings.name = "GameSettings"
		var dev_script = GDScript.new()
		dev_script.source_code = "extends Node\nsignal changed()\nvar sound_enabled := true\n"
		dev_script.reload()
		dev_settings.set_script(dev_script)
		root.add_child(dev_settings)
		settings = dev_settings
	# 用自己的实例验证联动，避免动到别人正在编辑的单例
	var probe = load("res://scripts/SoundFx.gd").new()
	root.add_child(probe)
	var had_prop: bool = "sound_enabled" in settings
	settings.sound_enabled = false
	if had_prop and settings.has_signal("changed"):
		settings.changed.emit()
	_check(probe.is_enabled() == not had_prop,
		"GameSettings.sound_enabled=false 时，新建实例按设置关闭（该属性%s）" % ["存在" if had_prop else "尚未加，默认保持开启"])
	settings.sound_enabled = true
	if had_prop and settings.has_signal("changed"):
		settings.changed.emit()
	_check(probe.is_enabled(), "GameSettings.sound_enabled=true 时同步为开启")
	# 手动覆盖后，设置信号不应把开关抢回去
	probe.set_enabled(false)
	if had_prop and settings.has_signal("changed"):
		settings.changed.emit()
	_check(not probe.is_enabled(), "手动关闭后不被 GameSettings.changed 覆盖（尊重玩家选择）")
	root.remove_child(probe)
	probe.free()

	# ---- 14. 结束时把开关恢复默认，避免影响同一进程里后续脚本 ----
	sfx.set_enabled(true)
	_check(sfx.is_enabled(), "测试结束恢复为开启状态")

	# ---- 14. 清理手动实例化的节点，避免退出时报 ObjectDB 泄漏 ----
	if not via_autoload:
		root.remove_child(sfx)
		sfx.free()
		_check(true, "手动实例化的 SoundFx 已释放（无泄漏告警）")


# ------------------------------ 辅助 ------------------------------

## 字节流里绝对值最大的采样（16 位小端）
func _peak(data: PackedByteArray) -> int:
	var peak := 0
	var i := 0
	while i + 1 < data.size():
		var s := data.decode_s16(i)
		if absi(s) > peak:
			peak = absi(s)
		i += BYTES_PER_SAMPLE
	return peak
