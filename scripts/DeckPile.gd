extends Control
## 抽牌堆（牌堆）+ **抽卡动画**：按原版 Shadowverse 的抽牌时序 1:1 复刻。
##
## 逆向依据（见 `docs/shadowverse-draw-animation.md`，出处在括号里）：
##   t=0.00 卡贴到牌堆顶，位移→落点 **0.40s easeOutCirc**（`1-sqrt(1-t²)`，OpenCardVfx.cs:71）
##          同时旋转 **0.39s easeOutQuad**、缩放 **0.39s easeOutExpo** 回到正面（OpenCardVfx.cs:72-75）
##   t=0.00 牌堆**立即**少一张（瞬时、不等动画结束；DummyDeckChangeCardVfx.cs:41）
##   t=0.40 改挂到手牌并开始入手重排 **0.25s easeOutQuad**（PlayerDrawCardToHandVfx.cs:63）
##   t=0.65 入手完成（总时长 0.40+0.25 串行，报告 §10.1）
##
## 牌堆**静态样式**依据 `docs/shadowverse-battle-ui.md`（【码】= 代码里能看到的）：
##   §13.1 / §2.1  牌堆根 `CardHolder` = `(950,-190,0)`、rotZ = **80°**（`SBattleLoad.cs:79-85`）；
##                 敌方 `ECardHolder` = `(965,180,0)`、rotZ = 100°。
##   §2.2 / §13.1  每张假卡偏移 `(-0.1, 0.4, 0.1) * (idx+1)`（`SBattleLoad.cs:1055-1075`）、缩放 18；
##                 最后一张是 `sleeve_deckout` 空牌库指示卡、缩放 ×0.95（`SBattleLoad.cs:862-878`、`Global.cs:409`）。
##   §12.2         2D 换算口径：1 局部单位 ≈ 卡宽 58px / 200 = 0.29px，只借**比例**不借绝对像素。
##   §13.7 / §13.8 颜色表 / 字体（卡背与标签的取值见下面各常量注释）。
##
## 与原版的有意偏离（原版细节只在 prefab / 材质里，代码看不到，见报告 §11.2）：
##   1. 原版是「每张牌一个 3D 假卡」（步长 `(-0.1, 0.4, 0.1)*idx`，SBattleLoad.cs:1055）；
##      这里沿用本项目既有的「每 `CARDS_PER_LAYER` 张叠一层、`LAYER_STEP` 像素」简化，
##      因为按原版 0.44% 卡高算出来只有 0.35px，2D 下完全看不出厚度。
##      但**铺开方向**照原版换算（见 `SPREAD_DIR`），不再用以前的右下 45°。
##   2. 原版翻牌是 3D 绕 Y 轴旋转到位；2D 用**水平缩放**表现翻面（1→0→1），
##      旋转量按「起始 -80° → 落位 -2°」的差值（78°）映射，让手感一致。
##   3. 原版卡背是 prefab 里的 `sleeve_CardBase` / `sleeve_deckout_M` 贴图（【资源】，代码看不到）；
##      这里用 `draw_style_box` + 纯绘制近似（圆角底 + 内板 + 描边 + 中央纹章 + 斜向装饰），不引入外部贴图。
##   4. 颜色与像素尺寸是项目自己的 2D 口径；**时长与缓动严格照原版**。
##
## 对外接口（测试用）：`set_count / count / layers / thickness / animate_draw /
## play_draw / skip_anim / is_animating / count_text / draw_target /
## flying_center / flight_progress / reveal_progress / hand_progress / revealed_card`。

signal draw_finished()      ## 一张牌的完整动画（0.65s）播完
signal hand_started()       ## 0.40s 翻牌结束、开始入手（对应原版 t=0.400 的挂点）

## 牌背尺寸：宽 58，高按**手牌卡的宽高比**（`CardSkin.CARD_RATIO = 118/170`）→ 58 / 0.694 ≈ 83.6。
## 这样「牌堆里的牌」与「手里的牌」同形（同圆角比例、同宽高比），观感是一套牌。
## 配色同样是 `CardSkin` 那一套（见下面各 COLOR_* 常量），与敌方手牌卡背一致。
const CARD_SIZE := Vector2(58, 83.6)
## 厚度：每层错开像素（厚度感来源）。原版是每张一张假卡，见文件头「有意偏离」。
## 一叠牌看起来要「厚实」而不是「梳子」：步子大一点（4.2px）、层数少一点（每 9 张一层、上限 14 层），
## 于是 150 张的牌堆是 14 层 × 4.2 ≈ 59px 的**牌垛**，而不是 24 层 × 3px 的一排细线。
const LAYER_STEP := 4.2
const MAX_LAYERS := 14           ## 层数上限（避免 140+ 张堆到屏幕外）
const CARDS_PER_LAYER := 9.0     ## 约每 9 张牌 = 一层
## 越靠后的层越暗（做出纵深），最前面那张是 1.0（原色）
const LAYER_DIM_STEP := 0.055
## 原版每张假卡偏移 `(-0.1, 0.4, 0.1)`（比例 1 : 0.25 : 0.25，SBattleLoad.cs:1055）
const LAYER_OFFSET_RATIO := Vector2(0.25, 1.0)

## ---- 牌堆铺开方向（2D 单位向量：+X 右、+Y 下；由原版 3D 数据换算，改动前请读完这段）----
## 出处：牌堆根 rotZ = 80°（`SBattleLoad.cs:79-85`）+ 假卡偏移主方向 = 根的**局部 +Y**
##      （`(-0.1, 0.4, 0.1)`，`SBattleLoad.cs:1055-1058`，|x|:|y| = 0.25:1 见 `LAYER_OFFSET_RATIO`）。
## 换算（报告 §6.2 用同一套算式）：
##   1) 根的局部 +Y 经 rotZ 80° 旋转到 Unity 空间：`(0,1) --Rz(80°)--> (-sin80°, +cos80°)`
##      = **(-0.9848, +0.1736)**（Unity +Y 朝上）。
##   2) Godot 2D 的 +Y **朝下**，故 Y 取反：**(-0.9848, -0.1736)**。
##      ⇒ 每多一层就往「**左 + 略微上**」错开一格；水平 : 垂直 ≈ 1 : 0.176（抬升 ≈ 10°）。
## 注：完整 3D 向量 `Rz(80°)·(-0.1,0.4) = (-0.4113, -0.0290)`（报告 §6.2 同结果），
##     其局部 X 分量与朝相机的 +Z（2D 无法表达）会把角度从「上 10°」拉平到约「下 4°」；
##     2D 取**主方向**（局部 +Y）作为铺开方向 —— 与报告「主要沿 −X」的结论一致。
## 敌方根是 rotZ 100°（镜像 ⇒ 垂直分量反过来，略偏下）；本脚本左右两侧共用，
## 没有「我方 / 敌方」标记（Main.gd 也未传），故两侧统一用本向量，见实现说明。
const SPREAD_DIR := Vector2(-0.9848, -0.1736)
## 锚点：最前面那张牌（= 原版 index 0、会被抽走的那张）放在控件矩形的**右下角**，
## 于是「向左上铺开」正好从右下角长满整个矩形 —— Main 按 `custom_minimum_size` 摆牌堆，
## `tools/admin_art_test.gd` 用 `Rect2(global_position, size)` 判「牌堆不与手牌区重叠」，
## 所以绘制必须留在这个矩形内（实际取点在 `_pile_base()`）。
## 锚点的额外微调（0 = 最上面那张牌正好压在矩形右下角）。
const PILE_TOP_OFFSET := Vector2.ZERO
## 原版最后一张 `sleeve_deckout` 指示卡的缩放（`SBattleLoad.cs:862-878`、`Global.cs:409`）
const DECKOUT_SCALE := 0.95
## 卡背圆角半径（本项目 UiSkin 的 CARD_RADIUS = 10，这里是 58×80 的小卡背，取 6）
const BACK_CORNER := 6
## 内板（内描边）相对卡背的外缩像素
const BACK_INSET := 4.0
## 张数标签字号：原版 `DeckLabel` 的字号/颜色在 prefab 里（battle-ui 报告 §2.4、§13.6 标【资源】），
## 代码可见的只有卡名 32 / 回合结束按钮 28（§13.8）；本项目卡宽 58px ↔ 原版 200 单位（§12.2），
## 故沿用项目既有的 12px，只把颜色换成 §13.7 的三档。
const LABEL_FONT_SIZE := 12

## ---- 抽卡动画时序（全部来自原版代码，不要随手改）----
const FLIGHT_TIME := 0.40        ## 位移：0.40s easeOutCirc
const FLIP_TIME := 0.39          ## 旋转 / 缩放：0.39s easeOutQuad / easeOutExpo
const REVEAL_TIME := FLIGHT_TIME ## 翻牌段总时长（0.40s）
const HAND_TIME := 0.25          ## 入手重排：0.25s easeOutQuad
const TOTAL_TIME := REVEAL_TIME + HAND_TIME   ## 0.65s
const FLIP_START_ROT := -80.0    ## 原版 localEulerAngles.z = -80
const FLIP_END_ROT := -2.0       ## 原版落位 (0, -2, 0)

## ---- 卡背配色（battle-ui 报告 §13.7 颜色表；deckout 卡见 §2.2）----
## 深藏青底 = 攻 label 描边 `(0.2,0.2,0.4)`（`Global.cs:379`）
## 原版卡背贴图（`sleeve_md_Card` / `sleeve_deckout_M`）在【资源】里，代码看不到，这里用同族颜色近似。
const COLOR_BACK := Color(0.2, 0.2, 0.4)
## 内板 = COLOR_BACK ×0.55（§13.7 里没有这一档，是按上一条派生的「暗部」，只用于压出层次）
const COLOR_BACK_INNER := Color(0.11, 0.11, 0.22)
## 外描边 = 卡面默认文字 `white`（`Global.cs:371`），半透明以免糊成一团
const COLOR_BACK_EDGE := Color(1, 1, 1, 0.5)
## 内描边 = 关键词高亮 / 按下色 `[00d2e4]`（`BattlePlayerView.cs:35,1000`）
const COLOR_BACK_TRIM := Color("#00d2e4")
## 中央纹章金 = 关键词高亮 `[ffcd45]`（`BattlePlayerView.cs:35`）
const COLOR_BACK_GOLD := Color("#ffcd45")
## deckout 指示卡：底色 = 卡面失效灰 `(0.2,0.2,0.2)`（`Global.cs:372`），比普通卡背更暗更灰
const COLOR_DECKOUT := Color(0.2, 0.2, 0.2)
## 派生暗部（×0.6，同上无独立出处）
const COLOR_DECKOUT_INNER := Color(0.12, 0.12, 0.12)
const COLOR_DECKOUT_EDGE := Color(1, 1, 1, 0.35)
const COLOR_DECKOUT_TRIM := Color(1, 1, 1, 0.55)
## 空牌堆（0 张）时的极淡空位框（沿用改前行为；不参与层数/厚度）
const COLOR_EMPTY_HINT := Color(0.2, 0.2, 0.2, 0.5)

const COLOR_FACE := Color("#e8dcc0")
const COLOR_FACE_EDGE := Color("#7a6a4a")
const COLOR_COST := Color("#3a2f1f")
## 张数标签文字：常态 = 卡面默认文字 `white`（`Global.cs:371`）
const COLOR_TEXT := Color(1, 1, 1)
## 「见底」档：只剩最后一层 → 金黄 = 手牌数 7~8 色 `(255/256, 205/256, 69/256)`
## （`ClassInfomationUIBase.cs:60-64`，取等价的 `#ffcd45`）
const COLOR_TEXT_LOW := Color("#ffcd45")
## 「抽空」档：0 张 → 红 = 手牌数 9 色 `(213/256, 5/64, 5/64)`（同上，取等价的 `#d41414`）
const COLOR_TEXT_EMPTY := Color("#d41414")
## 徽章底 = 卡面失效灰 `(0.2,0.2,0.2)`（`Global.cs:372`）加透明；描边 = 卡面默认文字白
const COLOR_BADGE_BG := Color(0.2, 0.2, 0.2, 0.82)
const COLOR_BADGE_EDGE := Color(1, 1, 1, 0.28)

var count := 0                   ## 真实剩余牌数
var draw_target := Vector2.ZERO  ## 入手动画终点（手牌区中心，Main 每帧刷新到真实位置）
## 翻牌落点（原版 PlayerDrawCardVfx.cs:45-59 的归一化公式算出来的屏幕坐标，全局坐标）。
## 为 ZERO 时退化为 draw_target，方便单独使用牌堆（测试里常见）。
var reveal_target := Vector2.ZERO
var auto_decrement := true       ## 动画**开始时**是否自己少一张（原版行为 = true）
## 跳过动画：断线恢复 / 快进用（原版 IsRecovery 把所有 WaitVfx 归零）。置真时动画时长归零。
var skip_anim := false

var _display := 0                ## 当前显示的牌数
var _anim := -1.0                ## <0 表示没有在播动画
var _anim_t := 0.0               ## 已播时长（秒，绝对时钟口径）
var _started_at := 0.0           ## 动画开始的时刻（秒，Time.get_ticks_msec 换算）
var _revealed := false           ## 是否翻开正面（玩家自己的抽牌）
var _reveal_anim := false        ## 是否正在播「翻开」动作
var _card: CardData = null       ## 翻开的卡（可空）
var _flight_rot_extra := 0.0     ## 入手阶段额外旋转（度，手牌扇形角度）
var _label: Label
## 卡背 / 徽章样式只构造一次并复用（项目里 BoardSurface / ManaOrbs 同样做法）
var _badge_style: StyleBoxFlat = null
var _back_style: StyleBoxFlat = null
var _back_inner_style: StyleBoxFlat = null
var _outline_style: StyleBoxFlat = null    ## 用卡背贴图时只画描边的那一层
var _back_radius := -1           ## 已写进两个卡背 StyleBox 的圆角半径（变化时才改属性）
var _back_tone := -1             ## 0 = 普通卡背、1 = deckout 指示卡（配色不同）


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = CARD_SIZE + Vector2(MAX_LAYERS * LAYER_STEP, MAX_LAYERS * LAYER_STEP)
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", LABEL_FONT_SIZE)
	_label.add_theme_color_override("font_color", COLOR_TEXT)
	# 描边用攻 label 描边色（§13.7，(0.2,0.2,0.4)），比纯黑更贴原版卡面
	_label.add_theme_color_override("font_outline_color", COLOR_BACK)
	_label.add_theme_constant_override("outline_size", 2)
	# 徽章式底：原版没有这个控件（牌库数在 NGUI 状态栏的 prefab 里，报告 §2.4），
	# 这里用「圆角深灰底 + 白描边」把数字从牌堆上分离出来，文本格式不变。
	_badge_style = StyleBoxFlat.new()
	_badge_style.bg_color = COLOR_BADGE_BG
	_badge_style.border_color = COLOR_BADGE_EDGE
	_badge_style.set_border_width_all(1)
	_badge_style.set_corner_radius_all(3)
	_badge_style.anti_aliasing = true
	_badge_style.content_margin_left = 5.0
	_badge_style.content_margin_right = 5.0
	_badge_style.content_margin_top = 1.0
	_badge_style.content_margin_bottom = 1.0
	_label.add_theme_stylebox_override("normal", _badge_style)
	add_child(_label)
	_sync_label()
	set_process(false)


## 设置剩余牌数（界面每次刷新都会调，用真实值覆盖显示值）
func set_count(value: int) -> void:
	count = maxi(0, value)
	_display = count
	_sync_label()
	queue_redraw()


## 可见层数：厚度就是这个层数 × LAYER_STEP
func layers() -> int:
	if _display <= 0:
		return 0
	return clampi(int(ceil(float(_display) / CARDS_PER_LAYER)), 1, MAX_LAYERS)


func thickness() -> float:
	return float(layers()) * LAYER_STEP


func count_text() -> String:
	return _label.text if _label != null else ""


# ------------------------------ 抽卡动画 ------------------------------

## 兼容旧接口：只播动画、不指定落点（沿用 `draw_target`，按玩家抽牌翻开正面）
func animate_draw() -> void:
	play_draw(draw_target, true, null, 0.0)


## 播一次抽卡动画。
##   target    入手动画终点（手牌里的位置，全局坐标）；ZERO 时用 `draw_target`
##   reveal    true = 翻开正面（玩家自己的抽牌）；false = 只飞卡背（对手抽牌）
##   card      翻开时画出的卡（可空；空时正面只画费用位）
##   rot_extra 入手阶段额外旋转（度；对应手牌扇形的 rotation）
func play_draw(target: Vector2, reveal: bool = true, card: CardData = null, rot_extra: float = 0.0) -> void:
	if target == Vector2.ZERO:
		target = draw_target
	draw_target = target
	_card = card
	_revealed = reveal
	_reveal_anim = reveal
	_flight_rot_extra = rot_extra
	_anim = 0.0
	_anim_t = 0.0
	_started_at = Time.get_ticks_msec() / 1000.0
	if auto_decrement and _display > 0:
		# 原版：牌堆在动画**开始**的同一帧就少一张（DummyDeckChangeCardVfx.cs:41）
		_display -= 1
		_sync_label()
	if _total_time() <= 0.0:
		_finish_draw()
		return
	set_process(true)
	queue_redraw()


func is_animating() -> bool:
	return _anim >= 0.0


## 动画总进度 0..1；没在播时返回 0
func flight_progress() -> float:
	return clampf(_anim_t / maxf(_total_time(), 0.001), 0.0, 1.0)


## 翻牌段进度 0..1（0.40s 那一段）
func reveal_progress() -> float:
	return clampf(_anim_t / _reveal_time(), 0.0, 1.0)


## 入手段进度 0..1（0.25s 那一段）
func hand_progress() -> float:
	return clampf((_anim_t - _reveal_time()) / _hand_time(), 0.0, 1.0)


## 抽到的牌（翻开的卡；未播 / 无卡时 null）
func revealed_card() -> CardData:
	return _card


## 翻开的程度 0..1（0 = 卡背、1 = 正面）；测试用
func flip_amount() -> float:
	return _flip_amount()


## 飞牌当前所在的全局坐标（测试用：验证「从牌堆飞向手牌」）
func flying_center() -> Vector2:
	return global_position + _flying_local_pos() + CARD_SIZE * 0.5


## 动画总时长（按设置里的动画速度缩放；0 = 立即完成）
func _total_time() -> float:
	return (REVEAL_TIME + HAND_TIME) * _speed()


## 翻牌段时长（同样按动画速度缩放，保证两段比例不变）
func _reveal_time() -> float:
	return REVEAL_TIME * _speed()

func _hand_time() -> float:
	return HAND_TIME * _speed()

## 动画速度倍率：0（立即完成）或 [0.5, 3.0]，1.0 为正常速度
func _speed() -> float:
	if skip_anim:
		return 0.0
	var s := GameSettings.anim_speed
	if s <= GameSettings.ANIM_SPEED_ZERO_EPSILON:
		return 0.0
	return clampf(s, GameSettings.ANIM_SPEED_MIN, GameSettings.ANIM_SPEED_MAX)


func _finish_draw() -> void:
	_anim = -1.0
	_anim_t = 0.0
	_reveal_anim = false
	_card = null
	set_process(false)
	queue_redraw()
	draw_finished.emit()


func _process(_delta: float) -> void:
	if _anim < 0.0:
		set_process(false)
		return
	# 用「动画开始时刻」换算已播时长，而不是逐帧累加 delta：
	# 累加会在低帧率下越积越偏（实测 20FPS 时 0.65s 被拖到 0.9s+），
	# 原版用的是 `Time.time < startTime + 2.5f` 同样的绝对时钟口径。
	var prev := _anim_t
	_anim = Time.get_ticks_msec() / 1000.0 - _started_at
	_anim_t = maxf(0.0, _anim)
	var reveal_t := _reveal_time()
	if reveal_t > 0.0 and prev < reveal_t and _anim_t >= reveal_t:
		_reveal_anim = false
		hand_started.emit()
	if _anim >= _total_time():
		_finish_draw()
		return
	queue_redraw()


## 张数标签：徽章式（深灰圆角底 + 白描边），文本仍是 `"牌库 %d"`（测试按该字符串断言，格式不能变）。
## 颜色分三档（都取自 §13.7）：>1 层 白 / 最后 1 层 金黄 / 0 张 红。
## 位置：贴在牌堆最上面那层的**上方**（牌堆朝左下铺开，上方是空的），
## 这样标签不会越出控件矩形、也不会压到手牌区（Main 把矩形底边摆在手牌区顶边之上 6px）。
func _sync_label() -> void:
	if _label == null:
		return
	_label.text = "牌库 %d" % _display
	if _display <= 0:
		_label.add_theme_color_override("font_color", COLOR_TEXT_EMPTY)
	elif layers() <= 1:
		_label.add_theme_color_override("font_color", COLOR_TEXT_LOW)
	else:
		_label.add_theme_color_override("font_color", COLOR_TEXT)
	_label.reset_size()
	var base := _pile_base()
	var top_y: float = base.y + SPREAD_DIR.y * float(maxi(layers() - 1, 0)) * LAYER_STEP
	_label.position = Vector2(
		base.x + CARD_SIZE.x * 0.5 - _label.size.x * 0.5,
		top_y - _label.size.y - 3.0)


# ------------------------------ 牌堆几何（2D 换算） ------------------------------

## 最前面那张牌（原版 index 0、会被抽走的那张）在控件里的局部位置 = 矩形右下角。
## 铺开方向是「左 + 略微上」，锚点放在右下角，牌堆才会向内长满整个矩形而不越界
## （Main 在 `_update_piles()` 里按 `custom_minimum_size` 摆位，admin_art_test 用矩形判重叠）。
func _pile_base() -> Vector2:
	var span: Vector2 = custom_minimum_size - CARD_SIZE
	if span.x <= 0.0 or span.y <= 0.0:
		# 兜底（正常情况下 `_ready` 已经把 custom_minimum_size 设成 CARD_SIZE + 最大铺开量）
		span = Vector2(float(MAX_LAYERS) * LAYER_STEP, float(MAX_LAYERS) * LAYER_STEP)
	return span + PILE_TOP_OFFSET


## 第 i 层的局部位置：i = 0 是最前面（画在最上层、会被抽走），i 越大越靠「后」（沿 SPREAD_DIR 向左上）。
## 对应原版「每张假卡沿牌堆根**局部 +Y** 往后长出去」的观感。
func _layer_offset(i: int) -> Vector2:
	return _pile_base() + SPREAD_DIR * (float(i) * LAYER_STEP)


# ------------------------------ 绘制 ------------------------------

func _draw() -> void:
	var n := layers()
	# 牌垛底下的**投影**：一叠牌压在地面上一圈柔和的暗影（画在最下面，先画）
	if n > 0:
		_draw_pile_shadow(n)
	# 一层层错开画（最左/最后的先画，最前面那张最后画，盖在最上面）
	for i in range(n - 1, -1, -1):
		var rect := Rect2(_layer_offset(i), CARD_SIZE)
		# 原版：假卡数量 = 牌库张数 + 1，最后一张是 `sleeve_deckout` 空牌库指示卡、缩放 ×0.95
		# （`SBattleLoad.cs:862-878`、`Global.cs:409`）。2D 里按卡片中心缩到 0.95，并换更暗的配色。
		var deckout := i == n - 1
		if deckout:
			var s := CARD_SIZE * DECKOUT_SCALE
			rect = Rect2(rect.get_center() - s * 0.5, s)
		_draw_back(rect, deckout, i)
	if n == 0:
		# 0 张：`layers() == 0`、`thickness() == 0`（测试断言「不画」）；这里只留一个极淡的空位框，
		# 摆在原本最前面那张牌的位置，提示「没牌了」——不参与层数/厚度计算（沿用改前的行为）。
		draw_rect(Rect2(_pile_base(), CARD_SIZE), COLOR_EMPTY_HINT, false, 2.0)
	# 抽卡动画：最上面那张牌按原版时序飞向落点（即使牌堆抽空也照画）
	if is_animating():
		_draw_flying_card()
	# 张数徽章左边的小牌垛图标（照参考图「图标 × 数量」的做法）
	_draw_count_icon()


## 徽章左侧的小图标：一摞牌背（与牌堆同一套配色，缩小到 11px 高）
func _draw_count_icon() -> void:
	if _label == null or not _label.visible:
		return
	var y: float = _label.position.y + _label.size.y * 0.5
	var base := Vector2(_label.position.x - 13.0, y - 5.5)
	var s := Vector2(8.0, 11.0)
	var tone := COLOR_DECKOUT if _display <= 0 else COLOR_BACK
	var edge := COLOR_DECKOUT_TRIM if _display <= 0 else COLOR_BACK_GOLD
	# 两层错位的小牌背
	for k in 2:
		var o := base + Vector2(float(k) * 2.5, float(-k) * 2.0)
		draw_rect(Rect2(o, s), tone)
		draw_rect(Rect2(o, s), Color(edge.r, edge.g, edge.b, 0.75), false, 1.0)


## 飞牌本帧的局部位置（左上角）
func _flying_local_pos() -> Vector2:
	# 起点 = 牌堆最前面那张（原版 index 0）：`DummyDeckChangeCardVfx` 隐藏的正是它，
	# `OpenCardVfx` 也是先把卡贴到 `CardHolder.position`（= 根位置 = 这张牌的位置）。
	# SPREAD_DIR 朝左上，所以它也是**画在最上层**的那张，起飞时不会从牌堆背后冒出来。
	var top := _pile_base()
	# 翻牌段落向「原版落点」（屏幕中心偏右）；没给时退化为手牌终点
	var reveal_global: Vector2 = reveal_target if reveal_target != Vector2.ZERO else draw_target
	var mid: Vector2 = reveal_global - global_position - CARD_SIZE * 0.5
	# 入手阶段再飞到手牌槽位（Main 每帧把 draw_target 刷成真实槽位）
	var dest: Vector2 = draw_target - global_position - CARD_SIZE * 0.5
	var reveal_t := _reveal_time()
	if _anim_t < reveal_t:
		# 原版：0.40s easeOutCirc
		var p: float = clampf(_anim_t / maxf(reveal_t, 0.001), 0.0, 1.0)
		return top.lerp(mid, _ease_out_circ(p))
	# 原版：入手重排 0.25s easeOutQuad
	var p2: float = clampf((_anim_t - reveal_t) / maxf(_hand_time(), 0.001), 0.0, 1.0)
	return mid.lerp(dest, _ease_out_quad(p2))


## 翻牌量 0..1：0 = 卡背、1 = 正面
func _flip_amount() -> float:
	if not _reveal_anim:
		return 1.0 if _revealed else 0.0
	return clampf(_ease_out_quad(_anim_t / maxf(FLIP_TIME * _speed(), 0.001)), 0.0, 1.0)


func _draw_flying_card() -> void:
	var center := _flying_local_pos() + CARD_SIZE * 0.5
	var flip := _flip_amount()
	# 3D 里是绕 Y 轴翻面；2D 用水平缩放表示：卡背 → 侧边 → 正面
	var sx: float = maxf(absf(1.0 - 2.0 * flip), 0.04)
	var rot := 0.0
	var s := 1.0
	if _reveal_anim:
		# 原版旋转 (0,176,-80) → (0,-2,0)：取 z 分量 -80° → -2°，0.39s easeOutQuad
		var ft: float = clampf(_anim_t / maxf(FLIP_TIME * _speed(), 0.001), 0.0, 1.0)
		rot = deg_to_rad(lerpf(FLIP_START_ROT, FLIP_END_ROT, _ease_out_quad(ft)))
		# 原版缩放 → (1,1,1)：0.39s easeOutExpo
		s = lerpf(0.85, 1.0, _ease_out_expo(ft))
	else:
		rot = deg_to_rad(FLIP_END_ROT + _flight_rot_extra)
	var size := Vector2(CARD_SIZE.x * sx, CARD_SIZE.y) * s
	var rect := Rect2(center - size * 0.5, size)
	if flip < 0.5:
		_draw_back(rect)
	else:
		_draw_face(rect)


## 牌垛的投影：整摞牌底下压一块略大的柔和暗影（比逐层描边更能压出「厚度」）
func _draw_pile_shadow(n: int) -> void:
	var base := _pile_base()
	var top: Vector2 = _layer_offset(maxi(n - 1, 0))
	var rect := Rect2(top, CARD_SIZE)
	rect = rect.merge(Rect2(base, CARD_SIZE))
	rect = rect.grow_individual(5.0, 4.0, 5.0, 6.0)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0, 0, 0, 0.30)
	st.set_corner_radius_all(10)
	st.anti_aliasing = true
	draw_style_box(st, Rect2(rect.position + Vector2(0, 3), rect.size))


## 卡背：圆角矩形 + 深色底 + 内外描边 + 斜向装饰 + 中央纹章（纯绘制，不引入贴图）。
## 飞牌翻面途中也用这同一套画法（`_draw_flying_card` → 这里），只是矩形被水平压扁。
## `deckout = true` = 原版最后那张 `sleeve_deckout` 指示卡：更暗的灰底、去掉金色纹章，
## 中央改画一个「空」环 + 斜杠，代表牌库见底。配色出处见上面各 COLOR_* 常量。
## `layer` = 第几层（0 = 最前面）：越靠后压得越暗，一叠牌才有纵深。
func _draw_back(rect: Rect2, deckout: bool = false, layer: int = 0) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var dim: float = clampf(1.0 - LAYER_DIM_STEP * float(layer), 0.45, 1.0)
	var tint := Color(dim, dim, dim, 1.0)
	# 有卡背贴图（`assets/art/card_back.png` / `assets/sv/card_back.png` / 扩展包指定）时：
	# 先把贴图等比裁切铺进去，再叠一层圆角描边把「牌」的轮廓勾出来 —— 观感立刻像真牌堆。
	var tex := ArtStore.card_back_texture()
	if tex != null:
		_draw_back_texture(tex, rect, deckout, tint, layer)
		return
	# 圆角按短边收：飞牌翻到侧面时矩形只有几像素宽，圆角不能大于它
	_prepare_back_style(deckout, clampi(int(minf(rect.size.x, rect.size.y) * 0.075), 1, BACK_CORNER))
	draw_style_box(_back_style, rect)
	# 压得太扁时（翻面到侧面）跳过内板与纹章，避免出现负尺寸矩形 / 花屏
	if rect.size.x < 12.0 or rect.size.y < 16.0:
		return
	var inset := Vector2(BACK_INSET, BACK_INSET)
	var inner := Rect2(rect.position + inset, rect.size - inset * 2.0)
	draw_style_box(_back_inner_style, inner)
	var trim: Color = COLOR_DECKOUT_TRIM if deckout else COLOR_BACK_TRIM
	var emblem: Color = COLOR_DECKOUT_TRIM if deckout else COLOR_BACK_GOLD
	# 斜向装饰：内板的两条对角线（原版卡背的斜纹底）
	var weave := Color(trim.r, trim.g, trim.b, 0.32)
	draw_line(inner.position, inner.end, weave, 1.0, true)
	draw_line(Vector2(inner.position.x, inner.end.y), Vector2(inner.end.x, inner.position.y), weave, 1.0, true)
	var c := rect.get_center()
	var rx: float = rect.size.x * 0.24
	var ry: float = rect.size.y * 0.24
	if deckout:
		# 「牌库见底」：空环 + 斜杠
		draw_arc(c, minf(rx, ry) * 1.2, 0.0, TAU, 24, emblem, 1.5, true)
		draw_line(c + Vector2(-rx * 0.85, ry * 0.85), c + Vector2(rx * 0.85, -ry * 0.85), emblem, 1.5, true)
	else:
		# 中央纹章：金色菱形 + 圆心（菱形顶点都写成 rect 的比例，飞牌缩放时自动跟着缩）
		draw_polyline(PackedVector2Array([
			c + Vector2(0.0, -ry),
			c + Vector2(rx, 0.0),
			c + Vector2(0.0, ry),
			c + Vector2(-rx, 0.0),
			c + Vector2(0.0, -ry),
		]), emblem, 1.5, true)
		draw_circle(c, minf(rx, ry) * 0.42, emblem)
		draw_circle(c, minf(rx, ry) * 0.16, Color(1, 1, 1, 0.85))


## 卡背贴图版本：等比裁切铺满 + 圆角描边勾轮廓（deckout 档整体压暗、去饱和；`tint` 再按层压暗）
func _draw_back_texture(tex: Texture2D, rect: Rect2, deckout: bool, tint: Color = Color.WHITE,
		layer: int = 0) -> void:
	var src := _cover_src(tex, rect.size)
	var tone := Color(0.55, 0.55, 0.58, 1.0) if deckout else Color(1, 1, 1, 1)
	draw_texture_rect_region(tex, rect, src, Color(tone.r * tint.r, tone.g * tint.g, tone.b * tint.b, 1.0))
	var radius := clampi(int(minf(rect.size.x, rect.size.y) * 0.075), 1, BACK_CORNER)
	_prepare_back_style(deckout, radius)
	# 只画描边（bg 透明），把贴图的轮廓收进圆角里
	_outline_style.bg_color = Color(0, 0, 0, 0)
	_outline_style.border_color = COLOR_DECKOUT_EDGE if deckout else COLOR_BACK_EDGE
	draw_style_box(_outline_style, rect)
	# 最前面那张：上缘描一条细细的金色高光，看起来是「一张压在一叠上的牌」
	if layer == 0 and not deckout:
		draw_line(rect.position + Vector2(radius, 1.0), Vector2(rect.end.x - radius, rect.position.y + 1.0),
			Color(COLOR_BACK_GOLD.r, COLOR_BACK_GOLD.g, COLOR_BACK_GOLD.b, 0.55), 1.5, true)
	if rect.size.x < 12.0 or rect.size.y < 16.0:
		return
	var c := rect.get_center()
	var emblem: Color = COLOR_DECKOUT_TRIM if deckout else COLOR_BACK_GOLD
	draw_circle(c, minf(rect.size.x, rect.size.y) * 0.05, Color(emblem.r, emblem.g, emblem.b, 0.55))


## 等比裁切（cover）的源矩形
func _cover_src(tex: Texture2D, target: Vector2) -> Rect2:
	var ts := tex.get_size()
	if ts.x <= 0.0 or ts.y <= 0.0 or target.x <= 0.0 or target.y <= 0.0:
		return Rect2(Vector2.ZERO, ts)
	var ta := target.x / target.y
	var sa := ts.x / ts.y
	if sa > ta:
		var w := ts.y * ta
		return Rect2((ts.x - w) * 0.5, 0.0, w, ts.y)
	var h := ts.x / ta
	return Rect2(0.0, (ts.y - h) * 0.5, ts.x, h)


## 卡背的两个 StyleBox 只建一次，之后只在「圆角半径 / 配色档」变化时改属性（避免每帧 new）。
func _prepare_back_style(deckout: bool, radius: int) -> void:
	if _back_style == null:
		_back_style = StyleBoxFlat.new()
		_back_style.anti_aliasing = true
		_back_style.set_border_width_all(1)
		_back_inner_style = StyleBoxFlat.new()
		_back_inner_style.anti_aliasing = true
		_back_inner_style.set_border_width_all(1)
		_outline_style = StyleBoxFlat.new()
		_outline_style.anti_aliasing = true
		_outline_style.set_border_width_all(2)
		_back_radius = -1
		_back_tone = -1
	if _back_radius != radius:
		_back_radius = radius
		_back_style.set_corner_radius_all(radius)
		_back_inner_style.set_corner_radius_all(maxi(radius - 2, 1))
		_outline_style.set_corner_radius_all(radius)
	var tone := 1 if deckout else 0
	if _back_tone != tone:
		_back_tone = tone
		_back_style.bg_color = COLOR_DECKOUT if deckout else COLOR_BACK
		_back_style.border_color = COLOR_DECKOUT_EDGE if deckout else COLOR_BACK_EDGE
		_back_inner_style.bg_color = COLOR_DECKOUT_INNER if deckout else COLOR_BACK_INNER
		_back_inner_style.border_color = COLOR_DECKOUT_TRIM if deckout else COLOR_BACK_TRIM


## 卡面（翻开后）：底色 + 费用数字；有卡数据时补一行卡名
func _draw_face(rect: Rect2) -> void:
	draw_rect(rect, COLOR_FACE)
	draw_rect(Rect2(rect.position + Vector2(3, 3), rect.size - Vector2(6, 6)), COLOR_FACE_EDGE, false, 2.0)
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var body := maxi(int(rect.size.y) - 46, 18)
	var cost := "-"
	var card_name := ""
	if _card != null:
		cost = "%d" % _card.cost
		card_name = _card.card_name
	# 费用：左上角
	draw_string(font, rect.position + Vector2(6, body), cost, HORIZONTAL_ALIGNMENT_LEFT, -1, body, COLOR_COST)
	# 卡名：底部居中
	if card_name != "":
		var name_size := 11
		var tw := font.get_string_size(card_name, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size).x
		var pos := rect.position + Vector2(rect.size.x * 0.5 - tw * 0.5, rect.size.y - 8)
		draw_string(font, pos, card_name, HORIZONTAL_ALIGNMENT_LEFT, -1, name_size, COLOR_COST)


# ------------------------------ 缓动（与 iTween / MotionUtils 同名曲线一致） ------------------------------

## easeOutCirc：1 - sqrt(1 - t²)
func _ease_out_circ(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - sqrt(maxf(0.0, 1.0 - c * c))


## easeOutQuad：1 - (1 - t)²
func _ease_out_quad(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - c) * (1.0 - c)


## easeOutExpo：1 - 2^(-10t)
func _ease_out_expo(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - pow(2.0, -10.0 * c)
