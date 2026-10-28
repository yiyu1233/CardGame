extends Control
## 伤害 / 治疗**飘字**：在目标位置冒出一个数字，向上飘并淡出。
##
## 按原版 Shadowverse `Wizard/Battle/View/Vfx/DamageVfxBase.cs`（Unity C#）复刻，
## 依据逆向报告 `docs/shadowverse-damage-floattext.md`（§0 结论速览 / §2 逐项参数 / §11 复刻参数表）：
##   · 存活 **2.5s**（`DAMAGE_ANIMATION_LENGTH`，DamageVfxBase.cs:11 与 :90 的字面量 2.5f）；
##   · 相邻数字**字距 0.26 × 字号**、整体以锚点水平居中（`DAMAGE_TEXT_MARGIN`，:13 与 :146）；
##   · **「卡堆」＝ 渲染层级堆叠，不是位置堆叠**：全场自增计数器（原版 `BattleManagerBase.DamageCount`，
##     唯一自增点 :125、唯一使用点 :148）把序号给每个飘字，后出的盖在先出的上面；
##     原版**没有**任何位置偏移 / 排队 / 错帧，同帧多次伤害完全重合（报告 §7、P11）；
##   · 只绘制数字 0-9（原版数字来自 16 帧图集，选帧 `startFrame = digit / 16`，:17,:142）。
##
## 本实现是**纯 `_draw()` 文字版**（原版是粒子预制体 `cmn_battle_damage_1` / `cmn_battle_heal_1`），
## 用等字距排布模拟图集槽位，并保留黑色描边保证任何背景可读。
## 不产生额外节点、不使用 Label，不影响布局与命中判定（mouse_filter = IGNORE）。

## 飘字存活时间（秒）。对应原版 DamageVfxBase.cs:11,90 的固定 2.5f。
const LIFE := 2.5
## 上飘总高度（像素）。
const RISE := 56.0
## 相邻数字的横向字距系数：字距 = CHAR_STEP_RATIO × 字号（原版 DAMAGE_TEXT_MARGIN = 0.26，:13）。
const CHAR_STEP_RATIO := 0.26
## 普通 / 放大（big）字号。
const FONT_SIZE := 34
const BIG_FONT_SIZE := 46
## big 时的轻微弹出缩放：progress < BIG_POP_TIME 期间从 BIG_SCALE 线性回到 1.0。
const BIG_SCALE := 1.06
const BIG_POP_TIME := 0.04
## 高位数字的额外上飘振幅（第 i 位多 i × 2px，让高位略高、逐位独立冒起）。
const DIGIT_RISE_STEP := 2.0
## 淡出起点：progress <= 0.34（≈ 0.85s / 2.5s）时 alpha 恒为 1.0，之后线性淡出到 0。
const ALPHA_HOLD := 0.34
## 黑色描边透明度（描边偏移固定为上下左右 2px）。
const OUTLINE_ALPHA := 0.9

## 「卡堆」计数器：脚本级 static、全战斗单调递增、**任何地方都不重置**
## （对应原版 `BattleManagerBase.DamageCount`，报告 §7 / P10）。多个实例共享同一个计数器。
static var _stack_counter := 0

## 本次飘字的「卡堆」序号 = pop 那一刻的 _stack_counter（等价 sortingOrder = DamageCount）。
var _order := 0
## 显示文本：pop 时已过滤为**纯数字**。
var text: String = ""
var color: Color = Color("#ff5252")

var _t := 0.0
var _start := Vector2.ZERO
var _big := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)


## 在 `pos`（全局坐标）弹出一个飘字。
## 文本只保留 `[0-9]`（去掉 `-` / `+` / 空格 / 中文符号）：原版数字图集只有 0-9 共 16 帧
## （DamageVfxBase.cs:17,142），符号既不在图集里也不参与排位。
func pop(p_text: String, p_color: Color, pos: Vector2, big: bool = false) -> void:
	text = _digits_only(p_text)
	color = p_color
	_start = pos
	_big = big
	_t = 0.0
	# 「卡堆」：先自增再取号，序号全局唯一且严格递增（DamageVfxBase.cs:125,148）。
	_stack_counter += 1
	_order = _stack_counter
	# 层级 = 序号，后出的数字盖在先出的上面（原版 sortingOrder，报告 P10）。
	# Godot 的 z_index 有取值范围，超出时钳到上限，仅影响极端长局的层级精度。
	z_index = _order if _order <= 4096 else 4096
	set_process(true)
	queue_redraw()


## 存活时长（秒），等于 LIFE。测试/调用方可据此安排回收时机。
func lifetime() -> float:
	return LIFE


## 「卡堆」序号：每次 pop 全场自增、永不重置；同一帧连续多次 pop 也严格递增且互不相同。
func order() -> int:
	return _order


func is_playing() -> bool:
	return _t < LIFE


func progress() -> float:
	return clampf(_t / LIFE, 0.0, 1.0)


## 当前字号：big = 46，普通 = 34。
func font_size() -> int:
	return BIG_FONT_SIZE if _big else FONT_SIZE


## big 的弹出缩放：progress < 0.04 时从 1.06 线性降到 1.0，其余时间恒为 1.0。
func scale_factor() -> float:
	if not _big:
		return 1.0
	var p := progress()
	if p >= BIG_POP_TIME:
		return 1.0
	return 1.0 + (BIG_SCALE - 1.0) * (1.0 - p / BIG_POP_TIME)


## 淡出曲线：progress <= 0.34 恒为 1.0，之后按 1 - (p - 0.34) / 0.66 线性淡出到 0。
func alpha() -> float:
	var p := progress()
	if p <= ALPHA_HOLD:
		return 1.0
	return clampf(1.0 - (p - ALPHA_HOLD) / (1.0 - ALPHA_HOLD), 0.0, 1.0)


## 每一位数字相对锚点 pos 的 x 偏移：等字距排布 + 整体以锚点水平居中。
## 对 n = text.length()、S = font_size()：total_w = 0.26 * S * n，
## 第 i 位（从左到右 0..n-1）= -total_w / 2 + 0.26 * S * (i + 0.5)，相邻两位差恒为 0.26 * S。
## 与原版 x_j = j * (-0.26) + digit * 0.26 * 0.5 - 0.13（DamageVfxBase.cs:146）等价
## （j 为从个位起的索引，j = n - 1 - i）。
func digit_offsets() -> Array[float]:
	var offsets: Array[float] = []
	var n := text.length()
	if n <= 0:
		return offsets
	var size := float(font_size())
	var step := CHAR_STEP_RATIO * size
	var total_w := step * float(n)
	for i in range(n):
		offsets.append(-total_w * 0.5 + step * (float(i) + 0.5))
	return offsets


## 锚点当前位置（测试用：验证「向上飘」）。y 随时间单调递减。
func current_pos() -> Vector2:
	return _start + Vector2(0.0, -RISE * _rise_ease())


## 上飘进度 1 - (1 - p)^2（easeOutQuad：先快后慢）。
func _rise_ease() -> float:
	var p := progress()
	return 1.0 - pow(1.0 - p, 2.0)


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		set_process(false)
		queue_redraw()
		return
	queue_redraw()


func _draw() -> void:
	if text == "":
		return
	var fade := alpha()
	if fade <= 0.0:
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var size := font_size()
	var offsets := digit_offsets()
	var rise := _rise_ease()
	var scale := scale_factor()
	var stroke := [Vector2(-2, 0), Vector2(2, 0), Vector2(0, -2), Vector2(0, 2)]
	# 以锚点当前位置为中心做 big 的弹出缩放。
	draw_set_transform(current_pos(), 0.0, Vector2(scale, scale))
	for i in range(text.length()):
		var code := text.unicode_at(i)
		if not _is_digit_code(code):
			continue
		var glyph := String.chr(code)
		# 每位数字各自上飘：第 i 位额外 -i * DIGIT_RISE_STEP，高位略微错开。
		var dpos := Vector2(offsets[i], -float(i) * DIGIT_RISE_STEP * rise)
		var half := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, size) * 0.5
		var origin := dpos - Vector2(half.x, font.get_height(size) * 0.5)
		# 黑色描边（上下左右 2px）+ 本体，保证任何背景可读。
		for off: Vector2 in stroke:
			draw_string(font, origin + off, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
				Color(0.0, 0.0, 0.0, fade * OUTLINE_ALPHA))
		draw_string(font, origin, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			Color(color.r, color.g, color.b, fade))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 是否 ASCII 数字 0-9（码点 48..57）。
static func _is_digit_code(code: int) -> bool:
	return code >= 48 and code <= 57


## 只保留 ASCII 数字 0-9，其余（`-` / `+` / 空格 / 中文标点等）全部丢弃。
func _digits_only(src: String) -> String:
	var out := ""
	for i in range(src.length()):
		var code := src.unicode_at(i)
		if _is_digit_code(code):
			out += String.chr(code)
	return out
