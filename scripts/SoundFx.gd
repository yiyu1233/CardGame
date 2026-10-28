extends Node
## 极简音效反馈（SoundFx）：全部音色用代码合成 PCM，项目里不需要任何 .ogg / .wav 资源。
##
## 平台/接线说明：
##   * 本脚本不写 class_name（按需求），可以被手动 new 出来单测；
##     项目里通常注册成自动加载 SoundFx，注册后即成为全局单例，游戏里用 SoundFx.play("attack") 即可。
##   * 想换音色时只改 _EVENTS 表里的参数，波形/包络/混音逻辑不用动。
##
## 为什么用 AudioStreamWAV 而不是 AudioStreamGenerator：
##   AudioStreamGenerator 需要自己持续往 AudioStreamGeneratorPlayback 里 push 帧，得挂在 _process 上跑
##   播放循环；无头（dummy 音频驱动）测试下拿不到 playback、帧数也喂不满，容易卡住/报空引用。
##   AudioStreamWAV 是「一次性把整段数据交给引擎」，play() 之后不用管，无头下也安全。
##
## 为什么用「播放器池」而不是一个 AudioStreamPlayer：
##   一个 player 同一时刻只播一个 stream，后一次 play() 会把前一声直接掐掉。
##   连击/同时受伤/按钮连点这类重叠场景就会丢音，所以准备若干 player 轮流用。

## 合成参数：22050 Hz / 16 位 / 单声道（够用且体积小；8 位会有明显量化噪声）
const SAMPLE_RATE := 22050
const BITS_PER_SAMPLE := 16
const BYTES_PER_SAMPLE := 2          ## 16 位单声道 = 2 字节/采样
const PLAYER_POOL_SIZE := 6          ## 播放器池大小：够覆盖「出牌 + 攻击 + 受伤」同时发声
const NOISE_SEED := 20240607         ## 固定种子 → 噪声型音效（attack）每次生成完全一致，便于断言
const TAIL_FADE_SEC := 0.004         ## 每个片段结尾 4ms 淡出，避免波形被硬切造成「咔」声

## 未知事件名的回退策略：播放这张表里的事件（保证调用方永远不会拿到 null 播放）
const FALLBACK_EVENT := "button"

## 事件表：时长 / 音量 / 音符序列。音色统一用「音符列表」描述，见 _tone()。
##   dur  片段总时长（秒）—— 每个事件都控制在 0.04~0.40 秒之间（音效要短，不能拖节奏）
##   vol  该事件的音量（dB，-8 ~ -16 之间，整体偏轻不吵人）
##   base 基础音色：音符数组（多音事件）或单个音符（自动包成数组，见 _build_notes）
##   change 变体音色：同一事件换个写法时的备用版本（本表暂未使用，保留接口便于调音）
## 注意：音符用 (起始秒, 结束秒) 描述而不是 (起始秒, 时长)，全部音符结束点必须 <= dur，
##       否则整段会被自动拉长（这是调音时最容易踩的坑）。
var _EVENTS := {
	# 出牌：短促上行「唰」——两个音，带一点噪声让它更像卡片摩擦
	"play_card": {
		"dur": 0.14, "vol": -11.0,
		"base": _arpeggio([
			_tone(0.000, 0.050, 620.0, 1080.0, 0.55),
			_tone(0.032, 0.122, 760.0, 1320.0, 0.42, 0.14),
		]),
	},
	# 攻击：低频冲击 + 噪声，起音 2ms（听感上是「砰」而不是「嘟」）
	"attack": {
		"dur": 0.18, "vol": -9.0,
		"base": _arpeggio([
			_tone(0.0, 0.16, 340.0, 52.0, 1.0, 0.45, 2.8),
		]),
	},
	# 受伤：下降短音，衰减比攻击快，听感更「闷」
	"damage": {
		"dur": 0.14, "vol": -10.0,
		"base": _arpeggio([
			_tone(0.0, 0.13, 540.0, 180.0, 0.95, 0.08, 2.2),
		]),
	},
	# 治疗：上行柔和（起音慢、无噪声）
	"heal": {
		"dur": 0.22, "vol": -13.0,
		"base": _arpeggio([
			_tone(0.0, 0.21, 420.0, 880.0, 0.7, 0.0, 1.6, 0.18),
		]),
	},
	# 回合开始：两声轻提示（880Hz 更亮），中间留一点点停顿
	"turn_start": {
		"dur": 0.20, "vol": -14.0,
		"base": _arpeggio([
			_tone(0.000, 0.055, 660.0, 660.0, 0.6, 0.0, 1.8, 0.015),
			_tone(0.070, 0.130, 880.0, 880.0, 0.6, 0.0, 1.8, 0.015),
		]),
	},
	# 按钮：极短点击（40ms）
	"button": {
		"dur": 0.04, "vol": -15.0,
		"base": _arpeggio([_tone(0.0, 0.04, 1300.0, 950.0, 0.5, 0.0, 2.5, 0.002)]),
	},
	# 抽牌：上行「唰」（对应原版 se_sys_draw / se_sys_set_card_to_hand 的抽卡时机）
	"draw": {
		"dur": 0.16, "vol": -12.0,
		"base": _arpeggio([
			_tone(0.000, 0.070, 520.0, 980.0, 0.5, 0.10),
			_tone(0.055, 0.150, 900.0, 1500.0, 0.35, 0.08),
		]),
	},
	# 胜利：三音上行 Do-Mi-So（523.25 / 659.25 / 783.99）
	"win": {
		"dur": 0.36, "vol": -11.0,
		"base": _arpeggio([
			_tone(0.000, 0.090, 523.25, 523.25, 0.55),
			_tone(0.090, 0.185, 659.25, 659.25, 0.55),
			_tone(0.185, 0.330, 783.99, 783.99, 0.60),
		]),
	},
	# 失败：三音下行，最后一声更长，情绪下沉
	"lose": {
		"dur": 0.36, "vol": -12.0,
		"base": _arpeggio([
			_tone(0.000, 0.090, 523.25, 523.25, 0.55),
			_tone(0.090, 0.190, 392.00, 392.00, 0.55),
			_tone(0.190, 0.350, 261.63, 261.63, 0.60),
		]),
	},
	# 错误：低沉短音（非法操作）
	"error": {
		"dur": 0.16, "vol": -12.0,
		"base": _arpeggio([
			_tone(0.0, 0.15, 210.0, 150.0, 0.85, 0.05, 2.0),
		]),
	},
}

var _enabled := true                ## 总开关；_ready 时从 GameSettings 读一次，之后可被 set_enabled 覆盖
var _manual_override := false       ## 玩家手动关过/开过之后，不再被 GameSettings.changed 覆盖
var _players: Array[AudioStreamPlayer] = []
var _next_player := 0               ## 池轮转指针（所有 player 都忙时的兜底）
var _stream_cache := {}             ## 事件名 → AudioStreamWAV，缓存后同一事件永远共用同一份数据

## 只读计数（测试/调试用）：play() 调用次数、真正交给引擎发声的次数
var play_count := 0
var emitted_count := 0


# ============================== 公开 API ==============================

## 播放一个音效事件。未知事件名不会报错，会安全回退到 FALLBACK_EVENT（button）。
## **真实素材优先**：`assets/sv/voice` 或 `assets/art/voice`（以及扩展包追加的目录）里有
## 同名 wav 就播素材，没有才用代码合成的音效 —— 见 `_play_sample`。
func play(event: String) -> void:
	play_count += 1
	if not _enabled:
		return                                  ## 关闭时只记调用次数，不产生任何播放
	if _play_sample(event):
		return                                  ## 有真实语音 / 音效就优先用它
	var key := _resolve(event)
	if key == "":
		return                                  ## 连回退事件都没有（表被清空）→ 静默返回
	var stream = get_stream(key)
	if stream == null:
		return
	var player: AudioStreamPlayer = _take_player()
	if player == null:
		return
	player.stream = stream
	player.volume_db = float(_EVENTS[key]["vol"])
	player.play()
	emitted_count += 1


## 开关音效。手动设置后不再跟随 GameSettings.changed（避免玩家刚关掉又被设置信号打开）。
func set_enabled(v: bool) -> void:
	_enabled = v
	_manual_override = true
	if not v:
		stop_all()


func is_enabled() -> bool:
	return _enabled


## 当前支持的事件名（已排序）。接线时可以直接遍历它做 UI 试听列表。
func events() -> Array:
	var names: Array = _EVENTS.keys()
	names.sort()
	return names


## 事件名是否有效（未知事件会被回退到 FALLBACK_EVENT）
func has_event(event: String) -> bool:
	return _EVENTS.has(event)


## 回退目标事件名（空字符串表示连回退都没有）
func fallback_event() -> String:
	return FALLBACK_EVENT if _EVENTS.has(FALLBACK_EVENT) else ""


## 取某个事件的音频流（不带缓存，**每次都是新生成**）。
## 之所以不带缓存：波形合成是纯确定性的（噪声用固定种子），测试可以靠「两次生成字节完全相同」
## 来证明音色稳定；未知事件返回 null。
func generate_stream(event: String) -> AudioStreamWAV:
	if not _EVENTS.has(event):
		return null
	return _make_stream(_gen_bytes(event))


## 取某个事件的音频流（带缓存，播放走这里）。同一事件永远返回同一份合成结果。
func get_stream(event: String):
	if not _EVENTS.has(event):
		return null
	if not _stream_cache.has(event):
		var stream := _make_stream(_gen_bytes(event))
		if stream == null:
			return null
		_stream_cache[event] = stream
	return _stream_cache[event]


## 停止池中所有正在播放的音效（切场景 / 关闭音效时用）
func stop_all() -> void:
	for p in _players:
		if p != null and p.playing:
			p.stop()


# ============================== 生命周期 ==============================

func _ready() -> void:
	_build_pool()
	_bind_settings()


## 建播放器池。总线固定用 Master（不额外建 AudioBus，保持简单）。
## 每个 player 的 volume 逐次播放时单独设置，所以这里不预设音量。
func _build_pool() -> void:
	if not _players.is_empty():
		return
	for i in PLAYER_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "Pool%d" % i
		add_child(p)
		_players.append(p)


## 从 GameSettings 读一次开关，并在它有 changed 信号时接上，保持同步。
## 用 get_node_or_null 动态取自动加载（--script 模式下自动加载不能当全局标识符用），
## 且 GameSettings 可能还没有 sound_enabled 这个属性（由设置面板负责维护），所以全程做存在性判断。
func _bind_settings() -> void:
	var settings = get_node_or_null("/root/GameSettings")
	if settings == null and is_inside_tree():
		settings = get_tree().root.get_node_or_null("GameSettings")
	if settings == null:
		return                                  ## 单独实例化（测试 / 只想要默认开启）时走这里
	if "sound_enabled" in settings:
		var v = settings.sound_enabled
		if typeof(v) == TYPE_BOOL:
			_enabled = v
	if settings.has_signal("changed"):
		var cb := Callable(self, "_on_settings_changed")
		if not settings.is_connected("changed", cb):
			settings.changed.connect(cb)


## GameSettings.changed 的回调：没被手动覆盖过就跟随设置里的开关。
func _on_settings_changed() -> void:
	if _manual_override:
		return
	var settings = get_node_or_null("/root/GameSettings")
	if settings == null or not ("sound_enabled" in settings):
		return
	var v = settings.sound_enabled
	if typeof(v) == TYPE_BOOL:
		_enabled = v
		if not _enabled:
			stop_all()


# ============================== 内部：播放器池 ==============================

## 事件名 → 真正要生成的事件名（空白/未知都回退到 FALLBACK_EVENT，没有回退则返回空串）
func _resolve(event: String) -> String:
	var key := event.strip_edges()
	if _EVENTS.has(key):
		return key
	return fallback_event()


## 优先复用空闲的 player；全都忙时按轮转覆盖（宁可掐掉最老的一声，也不丢新音效）
func _take_player():
	for p in _players:
		if p != null and not p.playing:
			return p
	if _players.is_empty():
		return null
	var p := _players[_next_player % _players.size()]
	_next_player = (_next_player + 1) % _players.size()
	return p


# ============================== 内部：波形合成 ==============================

## 生成一个事件的整段 PCM 字节（16 位小端单声道）。
## 完全确定性：不读时间、不用全局 randi，噪声用固定种子 → 同一事件每次字节一致。
func _gen_bytes(event: String) -> PackedByteArray:
	var clean := PackedByteArray()
	if not _EVENTS.has(event):
		return clean

	var notes := _build_notes(_EVENTS[event])
	var total := _total_samples(_EVENTS[event], notes)
	if total <= 0:
		return clean

	# 先按时长开好空间，再逐采样点写入：整数索引偏移，避免每帧追加导致的反复扩容
	var bytes := PackedByteArray()
	bytes.resize(total * BYTES_PER_SAMPLE)
	bytes.fill(0)

	var rng := RandomNumberGenerator.new()   ## 每次生成用同一个种子 → 决定论
	rng.seed = NOISE_SEED

	var note_index := 0
	var note_start := 0
	var note_len := 0
	var has_note := false
	var note: Dictionary = {}

	for i in total:
		if not has_note or i >= note_start + note_len:
			if note_index >= notes.size():
				break                          ## 后面没有音符了：已经是 0，直接收尾
			note = notes[note_index]
			note_index += 1
			note_start = int(round(float(note["start"]) * SAMPLE_RATE))
			note_len = maxi(1, int(round(float(note["dur"]) * SAMPLE_RATE)))
			has_note = true
			# 每个音符只在它的第一个采样点播种一次噪声：噪声序列 = f(固定种子, 音符内第几个采样)，
			# 既保证同一事件字节稳定，也不会因为某个音符改了时长而影响别的音符。
			rng.seed = NOISE_SEED

		if i < note_start:
			continue                           ## 休止符：样本保持 0

		var t := float(i - note_start) / float(SAMPLE_RATE)
		var note_dur := float(note_len) / float(SAMPLE_RATE)
		var sample := _sample_at(note, t, note_dur, rng)
		bytes.encode_s16(i * BYTES_PER_SAMPLE, _to_i16(sample))

	_apply_tail_fade(bytes, total)
	return bytes


## 单个采样点的值（-1 ~ 1）：扫频正弦 + 可选噪声，再乘包络
func _sample_at(note: Dictionary, t: float, note_dur: float, rng: RandomNumberGenerator) -> float:
	var p := clampf(t / maxf(note_dur, 0.0001), 0.0, 1.0)
	var f0 := float(note["f0"])
	var f1: float = f0 if note["f1"] == null else float(note["f1"])

	# 相位用解析积分（∫f dt），保证扫频时波形连续：
	# 若按固定相位步长递增，频率一变就会在换向处出现不连续 → 爆音。
	var phase := TAU * (f0 * t + (f1 - f0) * t * t / (2.0 * note_dur))
	var wave := sin(phase)

	# 噪声部分：rng 由调用方在每个音符开头播种一次，逐采样点推进 →
	# 序列只跟「种子 + 音符内采样序号」有关，同一事件每次生成都一样。
	var noise_amt := float(note["noise"])
	if noise_amt > 0.0:
		wave += rng.randf_range(-1.0, 1.0) * noise_amt
		wave /= (1.0 + noise_amt)

	var env := _envelope(p, float(note["atk"]), float(note["dec"]))
	return wave * env * float(note["amp"])


## 包络：起音线性淡入 + 之后按 dec 次幂衰减（dec>1 更「打击感」，1 附近更「柔和」）
func _envelope(p: float, atk: float, dec: float) -> float:
	if dec <= 0.0:
		dec = 1.0
	var attack := 0.0
	if atk > 0.0:
		attack = p / atk if p < atk else 1.0
	var tail := 1.0
	if p > atk and atk < 1.0:
		tail = pow(1.0 - (p - atk) / (1.0 - atk), dec)
	return attack * tail


## 把最后一个采样点压成 0，避免整段波形被硬切产生「咔」声
func _apply_tail_fade(bytes: PackedByteArray, total: int) -> void:
	if total <= 1:
		return
	var first: int = total - 1
	while first > 0 and bytes.decode_s16(first * BYTES_PER_SAMPLE) == 0:
		first -= 1
	if first <= 0:
		return
	var fade := maxi(1, int(round(TAIL_FADE_SEC * SAMPLE_RATE)))
	var from: int = maxi(1, first - fade + 1)
	for i in range(from, first + 1):
		var s := bytes.decode_s16(i * BYTES_PER_SAMPLE)
		var k := float(i - from + 1) / float(first - from + 1)
		s = int(round(float(s) * (1.0 - k)))
		bytes.encode_s16(i * BYTES_PER_SAMPLE, clampi(s, -32768, 32767))


## 整段采样数：取「事件时长」和「所有音符结束点」的较大值（音符超长时自动延长，不至于被截断）
func _total_samples(spec: Dictionary, notes: Array) -> int:
	var seconds := float(spec["dur"])
	for note in notes:
		seconds = maxf(seconds, float(note["start"]) + float(note["dur"]))
	return maxi(1, int(round(seconds * SAMPLE_RATE)))


## 事件表自检：返回异常描述列表（空数组 = 表格没写错）。
## 检查项：时长在 0.04~0.40 秒、音量在 -18~-6 dB、音符结束点不超过事件时长。
## 放在这里而不是测试脚本里，是为了让运行期也能自查（测试会断言它为空）。
func table_problems() -> Array:
	var problems: Array = []
	for e in events():
		var spec: Dictionary = _EVENTS[e]
		var dur := float(spec["dur"])
		if dur < 0.04 or dur > 0.40:
			problems.append("%s:时长%.3f秒超出0.04~0.40" % [e, dur])
		var vol := float(spec["vol"])
		if vol < -18.0 or vol > -6.0:
			problems.append("%s:音量%.1fdB超出-18~-6" % [e, vol])
		for note in _build_notes(spec):
			var end := float(note["start"]) + float(note["dur"])
			if end > dur + 0.0005:
				problems.append("%s:音符结束%.3f秒超过事件时长%.3f秒" % [e, end, dur])
	return problems


## 把事件表里的音符描述展开成统一结构（base/change 两种写法都支持，便于加变体）。
## 返回类型写死成 Array：Dictionary 取值出来是 Variant，不标注的话后面会退化成 Variant/字典，
## 采样循环里 notes[i] 就会取错东西。
func _build_notes(spec: Dictionary) -> Array:
	var notes: Array = []
	if spec.has("change"):
		notes = spec["change"]
	elif spec.has("base"):
		notes = spec["base"]
	return notes


## 单音：t0 起始秒，t1 结束秒（t1<=t0 时按最短 8ms 处理），f0→f1 扫频（相等=不扫频），
## amp 振幅，noise 噪声占比（0~1），dec 衰减指数，atk 起音时长（秒）。
## 用「起止时间」而不是「起始+时长」，是为了让事件表里一眼能看出每个音落在哪一段。
func _tone(t0: float, t1: float, f0: float, f1: float, amp: float,
		noise: float = 0.0, dec: float = 2.0, atk: float = 0.003) -> Dictionary:
	var start := maxf(t0, 0.0)
	var d := maxf(t1 - start, 0.008)
	return {
		"start": start,
		"dur": d,
		"f0": f0,
		"f1": f1,
		"amp": clampf(amp, 0.0, 1.0),
		"noise": clampf(noise, 0.0, 1.0),
		"dec": maxf(dec, 0.1),
		"atk": clampf(atk, 0.0, 0.4 * d),   # 起音不超过音符时长的 40%，否则包络算不出来
	}


## 多音（旋律型事件）：只是把音符数组包一层，让「单音 / 多音」在事件表里一眼能区分。
## 注意事件表里 base 结构必须始终是 Array（即使是单音事件也要包一层，见 button）。
func _arpeggio(notes: Array) -> Array:
	return notes


## 组装 AudioStreamWAV：16 位 / 单声道 / 22050 Hz / 不循环
func _make_stream(bytes: PackedByteArray) -> AudioStreamWAV:
	if bytes.is_empty():
		return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = bytes
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	return stream


## 浮点采样 → int16（钳位到合法区间，防止叠加噪声时溢出绕回）
func _to_i16(v: float) -> int:
	return clampi(int(round(clampf(v, -1.0, 1.0) * 32767.0)), -32768, 32767)

# ------------------------------ 真实语音 / 音效（来自素材文件） ------------------------------
#
# 约定：**文件名 = 事件名**（play / attack / win / lose / button / turn_start …，与内置音效同名），
# 素材放在下面这些目录里就自动生效（靠后的目录覆盖靠前的同名事件）：
#   * res://assets/sv/voice   —— 逆向导入的素材（tools/import_sv_art.gd 写这里）
#   * res://assets/art/voice  —— 自备语音 / 音效（优先级更高，目录约定见 ArtStore 文件头）
# 有对应文件就用真实素材，没有就照旧用代码合成的音效 —— 不影响任何既有行为。
# WAV 先走 load()（编辑器导入过的资源），再接 AudioStreamWAV.load_from_file() 兜底，
# 所以**刚拷进来、还没生成 .import 的 wav 也能直接播**。

var _sample_dirs: Array[String] = [
	"res://assets/sv/voice",     # 逆向批量导入素材
	"res://assets/art/voice",    # 自备素材（同名事件优先）
]
const SAMPLE_EXT := ".wav"
const SAMPLE_POOL_SIZE := 4          ## 真实素材（语音 / 音效）的播放器数量
var _samples: Dictionary = {}
var _sample_pool: Array[AudioStreamPlayer] = []
var _sample_next := 0
## 用真实素材播放的次数（测试与调试用）
var sample_plays := 0


## 有真实素材就用素材流，否则用传入的合成流
func sample_stream(event: String, fallback: AudioStream) -> AudioStream:
	if _samples.has(event) and is_enabled():
		return _samples[event]
	return fallback


## 当前素材目录（按扫描顺序）
func sample_dirs() -> Array[String]:
	return _sample_dirs.duplicate()


## 换一组素材目录并重新扫描，返回绑定成功的事件数（测试 / 外挂素材包用）
func set_sample_dirs(dirs: Array) -> int:
	_sample_dirs.assign(dirs)
	return load_samples()


## 追加素材目录并重新扫描（扩展包用；靠后的目录覆盖靠前的同名事件）
func append_sample_dirs(dirs: Array) -> int:
	for d in dirs:
		var s := str(d).strip_edges()
		if s != "" and not _sample_dirs.has(s):
			_sample_dirs.append(s)
	return load_samples()


## 扫描全部素材目录，返回绑定成功的事件数（没有素材目录时返回 0）
func load_samples() -> int:
	_samples.clear()
	for dir in _sample_dirs:
		_scan_samples(dir)
	return _samples.size()


## 扫描一个素材目录；同名事件由后面的目录覆盖前面的
func _scan_samples(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and not f.begins_with(".") \
				and f.to_lower().ends_with(SAMPLE_EXT):
			var stream := _load_sample("%s/%s" % [dir, f])
			if stream != null:
				_samples[f.get_basename()] = stream
		f = d.get_next()
	d.list_dir_end()


## 读一条 wav：优先用编辑器导入好的资源；还没有 .import 时按文件头自己解析（免导入就能播）
func _load_sample(path: String) -> AudioStream:
	var res: Variant = load(path) if ResourceLoader.exists(path) else null
	if res is AudioStream:
		return res
	var wav := AudioStreamWAV.load_from_file(path)
	return wav if wav != null else null


func has_sample(event: String) -> bool:
	return _samples.has(event)


func sample_events() -> Array:
	var out := _samples.keys()
	out.sort()
	return out


## 播放真实素材；没有该事件或音效被关闭时返回 false（调用方继续走合成音）
func _play_sample(event: String) -> bool:
	if not _samples.has(event) or not is_enabled():
		return false
	if _sample_pool.is_empty():
		_build_sample_pool()
	var p := _take_sample_player()
	if p == null:
		return false
	p.stream = _samples[event]
	p.volume_db = 0.0
	p.play()
	sample_plays += 1
	return true


## 真实素材用的小播放器池：单独一个 player 会让「出牌语音 + 攻击语音」互相掐断，
## 这里给 4 个轮转（与合成音效池分开，互不抢占）；音频流本身已按 wav 采样率设置好。
func _build_sample_pool() -> void:
	if not _sample_pool.is_empty():
		return
	for i in SAMPLE_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.name = "Sample%d" % i
		add_child(p)
		_sample_pool.append(p)


## 找一个空闲的素材播放器（全忙时轮转覆盖最老的）
func _take_sample_player() -> AudioStreamPlayer:
	if _sample_pool.is_empty():
		return null
	for p in _sample_pool:
		if p != null and not p.playing:
			return p
	var p2 := _sample_pool[_sample_next % _sample_pool.size()]
	_sample_next = (_sample_next + 1) % _sample_pool.size()
	return p2