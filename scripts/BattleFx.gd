extends Control
## 战斗表现层（`Main` 挂一层，z_index 高于战场、低于拖拽幽灵卡）。
##
## 负责对局里的四类「卡片操作动画」，全部**纯绘制、不建子节点**，每帧只推进时间：
##   * `play_card()`  出牌：从手牌位置飞向落点，途中缩小 + 轻微旋转，落地时闪一下；
##   * `death()`      被破坏 / 消失：卡面从原位置**上飘 + 淡出 + 碎裂**，并炸出放射碎片与冲击环；
##   * `summon()`     召唤登场：落点一圈扩散光环 + 卡面弹一下（放大回稳）；
##   * `burst()`      通用破坏碎裂（牌库 / 攻城 / 群体清除等）。
##
## 设计要点：
##   * 用**绝对时钟**（`Time.get_ticks_msec`）推进，而不是累加 delta —— 低帧率下不会越积越偏
##     （与 `DeckPile` / `FloatText` 同一套口径）；
##   * `speed` 跟随设置里的「动画速度」（0 = 立即结束），与抽牌 / 飘字一致；
##   * 所有效果播完自动移除；没有活跃效果时 `_process` 自动关闭（不空转）。
##
## 供测试：`animating()` / `active_effects()` / `last_kind()`。

const KIND_PLAY := "play"
const KIND_DEATH := "death"
const KIND_SUMMON := "summon"
const KIND_BURST := "burst"

const PLAY_TIME := 0.26          ## 出牌飞行时长
const DEATH_TIME := 0.55         ## 死亡消失时长
const SUMMON_TIME := 0.30        ## 召唤登场时长
const BURST_TIME := 0.45         ## 碎裂时长

var speed := 1.0                 ## 动画速度倍率（<=0 = 立即完成，直接不播）
var effects: Array = []          ## 活跃效果列表

var _last_kind := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)


# ============================== 触发接口 ==============================

## 出牌：从 `from`（手牌中心）飞到 `to`（落点中心）
func play_card(from: Vector2, to: Vector2, card: CardData, size: Vector2 = Vector2(118, 170)) -> void:
	_push({
		"kind": KIND_PLAY, "from": from, "to": to, "card": card,
		"size": size, "color": _card_tint(card),
	})


## 被破坏 / 消失：在 `center` 处把卡面淡出并碎裂
func death(center: Vector2, size: Vector2, card: CardData, color: Color = Color.WHITE) -> void:
	_push({
		"kind": KIND_DEATH, "center": center, "size": size, "card": card,
		"color": color if color != Color.WHITE else _card_tint(card),
	})


## 召唤登场：落点扩散光环 + 卡面弹出
func summon(center: Vector2, size: Vector2) -> void:
	_push({"kind": KIND_SUMMON, "center": center, "size": size, "color": Color("#80cbc4")})


## 通用碎裂（带颜色；不画卡面）
func burst(center: Vector2, size: Vector2, color: Color) -> void:
	_push({"kind": KIND_BURST, "center": center, "size": size, "color": color})


func clear() -> void:
	effects.clear()
	_last_kind = ""
	queue_redraw()
	set_process(false)


func animating() -> bool:
	return not effects.is_empty()


func active_effects() -> int:
	return effects.size()


## 测试用：把所有活跃动画的时间往前拨 `seconds` 秒，然后立刻推进一帧。
## 动画本身用绝对时钟跑，测试里不必真的等 0.65 秒。
func advance_for_test(seconds: float) -> void:
	for e in effects:
		e["t0"] = float(e["t0"]) - seconds
	_process(0.0)


func last_kind() -> String:
	return _last_kind


# ============================== 内部 ==============================

func _push(e: Dictionary) -> void:
	if _speed() <= 0.0:
		return
	e["t0"] = Time.get_ticks_msec() / 1000.0
	effects.append(e)
	_last_kind = str(e.get("kind", ""))
	set_process(true)


func _speed() -> float:
	if speed <= 0.0:
		return 0.0
	return maxf(0.05, speed)


func _dur(kind: String) -> float:
	match kind:
		KIND_PLAY:
			return PLAY_TIME
		KIND_DEATH:
			return DEATH_TIME
		KIND_SUMMON:
			return SUMMON_TIME
		_:
			return BURST_TIME


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var kept: Array = []
	for e in effects:
		var dur: float = _dur(str(e.get("kind", ""))) * _speed()
		if now - float(e["t0"]) < dur:
			kept.append(e)
	effects = kept
	queue_redraw()
	if effects.is_empty():
		set_process(false)


## 本帧进度 0..1
func _p(e: Dictionary) -> float:
	var dur: float = _dur(str(e.get("kind", ""))) * _speed()
	if dur <= 0.0:
		return 1.0
	return clampf((Time.get_ticks_msec() / 1000.0 - float(e["t0"])) / dur, 0.0, 1.0)


func _draw() -> void:
	for e in effects:
		match str(e.get("kind", "")):
			KIND_PLAY:
				_draw_play(e)
			KIND_DEATH:
				_draw_death(e)
			KIND_SUMMON:
				_draw_summon(e)
			_:
				_draw_burst(e)


## 出牌：easeOutQuad 位移，缩放 1.0 → 0.86，末段闪一下
func _draw_play(e: Dictionary) -> void:
	var p := _p(e)
	var t := _ease_out_quad(p)
	var center: Vector2 = (e["from"] as Vector2).lerp(e["to"] as Vector2, t)
	var s := lerpf(1.0, 0.86, t)
	var size: Vector2 = (e["size"] as Vector2) * s
	var rot := deg_to_rad(lerpf(-6.0, 0.0, t))
	_draw_card_face(center, size, rot, e.get("card"), 1.0 - 0.35 * p)


## 死亡 / 消失：卡面沿 -Y 上飘 + 淡出 + 轻微放大，同时放射碎片 + 冲击环
func _draw_death(e: Dictionary) -> void:
	var p := _p(e)
	var center: Vector2 = e["center"]
	var fade := 1.0 - p
	var drift := -26.0 * _ease_out_quad(p)
	var size: Vector2 = (e["size"] as Vector2) * lerpf(1.0, 1.12, p)
	_draw_card_face(center + Vector2(0, drift), size, deg_to_rad(lerpf(0.0, 6.0, p)),
		e.get("card"), fade * 0.9)
	_draw_shards(e["center"] as Vector2, e["size"] as Vector2, e["color"] as Color, p)
	_draw_ring(e["center"] as Vector2, e["size"] as Vector2, e["color"] as Color, p, 0.35)


## 召唤：扩散光环 + 卡面从 0.7 弹回 1.0
func _draw_summon(e: Dictionary) -> void:
	var p := _p(e)
	var center: Vector2 = e["center"]
	var size: Vector2 = e["size"]
	var pop := _ease_out_expo(p)
	_draw_ring(center, size, e["color"] as Color, p, 0.5)
	var s := lerpf(0.7, 1.0, pop)
	var alpha := clampf(p * 2.2, 0.0, 1.0)
	_draw_card_face(center, size * s, 0.0, null, alpha * 0.85)


## 通用碎裂
func _draw_burst(e: Dictionary) -> void:
	var p := _p(e)
	_draw_shards(e["center"] as Vector2, e["size"] as Vector2, e["color"] as Color, p)
	_draw_ring(e["center"] as Vector2, e["size"] as Vector2, e["color"] as Color, p, 0.3)


## 画一张卡面幽灵：圆角底 + 描边 + 卡图（有的话）+ 卡名
func _draw_card_face(center: Vector2, size: Vector2, rot: float, card: Variant, alpha: float) -> void:
	if size.x <= 1.0 or size.y <= 1.0:
		return
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.16, 0.18, 0.26, 0.92 * alpha)
	st.border_color = Color(0.85, 0.88, 0.95, 0.85 * alpha)
	st.set_border_width_all(2)
	st.set_corner_radius_all(maxi(2, int(minf(size.x, size.y) * 0.09)))
	st.anti_aliasing = true
	var rect := Rect2(center - size * 0.5, size)
	if absf(rot) > 0.001:
		draw_set_transform(center, rot, Vector2.ONE)
		draw_style_box(st, Rect2(-size * 0.5, size))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	else:
		draw_style_box(st, rect)
	# 卡图
	if card is CardData:
		var tex := ArtStore.texture(ArtStore.art_for(card))
		if tex != null:
			var inset := size * 0.08
			var art_rect := Rect2((center - size * 0.5) + inset, size - inset * 2.0)
			var src := _cover_src(tex, art_rect.size)
			draw_texture_rect_region(tex, art_rect, src, Color(1, 1, 1, alpha))
		# 卡名
		var font := ThemeDB.fallback_font
		if font != null and size.y > 34.0:
			var label: String = card.card_name
			var fs := maxi(9, int(size.y * 0.09))
			var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var pos := center + Vector2(-tw * 0.5, size.y * 0.5 - fs * 0.4)
			draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				Color(1, 1, 1, 0.95 * alpha))


## 放射碎片：8 片小矩形沿径向飞出并淡出
func _draw_shards(center: Vector2, size: Vector2, color: Color, p: float) -> void:
	var n := 8
	var radius: float = maxf(size.x, size.y) * 0.5
	for i in n:
		var ang := TAU * float(i) / float(n) + p * 0.6
		var dir := Vector2(cos(ang), sin(ang))
		var dist := radius * (0.25 + 1.15 * _ease_out_quad(p))
		var pos := center + dir * dist
		var shard := Vector2(size.x, size.y) * 0.10
		var rot := ang + p * 2.0
		draw_set_transform(pos, rot, Vector2.ONE)
		draw_rect(Rect2(-shard * 0.5, shard), Color(color.r, color.g, color.b, (1.0 - p) * 0.85))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 冲击环：扩散的椭圆环
func _draw_ring(center: Vector2, size: Vector2, color: Color, p: float, max_scale: float) -> void:
	var r: float = maxf(size.x, size.y) * 0.5 * (1.0 + max_scale * _ease_out_quad(p))
	var alpha := (1.0 - p) * 0.7
	draw_arc(center, r, 0.0, TAU, 32, Color(color.r, color.g, color.b, alpha), 2.0, true)


## 等比裁切（cover）源矩形
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


func _card_tint(card: Variant) -> Color:
	if card is CardData:
		var c: Color = card.color
		if c.a > 0.0:
			return c
	return Color(0.75, 0.8, 0.9)


func _ease_out_quad(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - c) * (1.0 - c)


func _ease_out_expo(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - pow(2.0, -10.0 * c)
