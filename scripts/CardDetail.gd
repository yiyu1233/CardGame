class_name CardDetail
extends PanelContainer
## 悬停 / 点击卡牌时，在卡牌右侧弹出的“完整效果说明”面板。
## 挂在主场景的 DragLayer（顶层 CanvasLayer）下，不会被其他控件裁切，且不接收鼠标事件。

const PANEL_W := 290.0

var _title: Label
var _sub: Label
var _stats: Label
var _keyword: Label
var _body: RichTextLabel
var _anchor := Rect2()
var _card: CardData = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	custom_minimum_size = Vector2(PANEL_W, 0)
	_build()
	_apply_style()
	# 详情面板不该抢任何鼠标事件（它是纯展示），内部一次性全部设为 IGNORE
	UiUtil.make_decorative(self)
	# 面板常驻在 DragLayer 下：不可见时没必要每帧重新定位
	set_process(false)


func _build() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(vbox)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(_title)

	_sub = Label.new()
	_sub.add_theme_color_override("font_color", Color("#b0bec5"))
	vbox.add_child(_sub)

	_stats = Label.new()
	_stats.add_theme_color_override("font_color", Color("#ffe082"))
	vbox.add_child(_stats)

	_keyword = Label.new()
	_keyword.add_theme_color_override("font_color", Color("#80cbc4"))
	vbox.add_child(_keyword)

	var sep := HSeparator.new()
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(sep)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.scroll_active = false
	_body.selection_enabled = false
	_body.custom_minimum_size = Vector2(PANEL_W - 24.0, 0.0)
	# 面板整体 mouse_filter = IGNORE 不会传递给子节点：RichTextLabel / HSeparator
	# 默认是 STOP，会把悬停与点击从它下面盖住的卡牌、随从、英雄按钮上吞掉。
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_body)


func _apply_style() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.08, 0.11, 0.97)
	style.border_color = Color("#ffd54f")
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 2
	style.content_margin_right = 2
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	add_theme_stylebox_override("panel", style)


func show_card(card: CardData, anchor: Rect2) -> void:
	if card == null:
		hide_card()
		return
	_anchor = anchor
	# 同一张卡重复悬停时不必重填内容
	if _card != card:
		_card = card
		_fill(card)
	visible = true
	set_process(true)
	_position_panel.call_deferred()


func hide_card() -> void:
	visible = false
	set_process(false)
	_card = null


func _process(_delta: float) -> void:
	if visible:
		_position_panel()


## 默认显示在卡牌右侧；右侧空间不足则显示在左侧，并保证不超出屏幕
func _position_panel() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var my_size: Vector2 = size
	var x: float = _anchor.position.x + _anchor.size.x + 12.0
	if x + my_size.x > vp.x - 8.0:
		x = _anchor.position.x - my_size.x - 12.0
	x = clampf(x, 8.0, maxf(8.0, vp.x - my_size.x - 8.0))
	var y: float = _anchor.position.y + _anchor.size.y * 0.5 - my_size.y * 0.5
	y = clampf(y, 8.0, maxf(8.0, vp.y - my_size.y - 8.0))
	position = Vector2(x, y)


func _fill(c: CardData) -> void:
	_title.text = c.card_name
	_title.add_theme_color_override("font_color", c.color.lightened(0.3))

	var line := "%d 法力　%s%s" % [c.cost, c.type_name(), "　（衍生物）" if c.is_token else ""]
	# 兵种词条：中立是默认值，不逐张标注（避免每张卡都写一遍「中立」）；
	# 挂了别的兵种就在这一行后面带上，玩家一眼能看出它是「士兵 / 指挥官 / 机械…」
	var troop := CardDB.troop_of(c)
	if not CardDB.is_neutral_troop(troop):
		line += "　·%s" % CardDB.troop_name(troop)
	# 卡包：基础卡包不标注，别的卡包跟在后面（组卡 / 对战时能看出这张卡来自哪个扩展）
	var pack := CardDB.pack_of(c)
	if pack != CardDB.DEFAULT_PACK:
		line += "　·%s" % CardDB.pack_name(pack)
	_sub.text = line

	if c.is_minion():
		_stats.text = "攻击 %d　/　生命 %d" % [c.attack, c.health]
		_stats.visible = true
	elif c.is_permanent():
		_stats.text = "%s　耐久 %d" % [c.type_name(), c.durability()]
		_stats.visible = true
	else:
		_stats.visible = false

	var kn := c.keyword_names()
	_keyword.text = "关键字：" + " ".join(kn)
	_keyword.visible = kn.size() > 0

	# 卡名 / 描述是管理端自由文本，可能含 "["，不转义会让 BBCode 渲染错乱
	var lines := PackedStringArray()
	if c.has_effect():
		var prefix := "[b]效果：[/b]"
		if c.is_minion():
			prefix = "[b]战吼：[/b]"
		elif c.is_permanent():
			prefix = "[b]安放：[/b]"
		lines.append(prefix + _esc(c.effect_text()))
		if c.needs_target():
			lines.append("[b]目标：[/b]" + _esc(c.target_name()))
	elif c.needs_target():
		lines.append("[b]目标：[/b]" + _esc(c.target_name()))

	if c.is_city():
		lines.append("[b]城邦：[/b]每套牌组最多 %d 张（占一格、不能攻击）" % CardData.CITY_DECK_LIMIT)
	elif c.is_permanent():
		lines.append("[b]护符：[/b]占一格、不能攻击，可被伤害或效果解掉")

	if CardEffects.needs_token(c.effect_id) or CardEffects.needs_token(c.deathrattle_id):
		var token_name := _token_name(c.token_id)
		if token_name != "":
			lines.append("[b]衍生物：[/b]" + _esc(token_name))

	if c.has_deathrattle():
		lines.append("[b]" + _esc(c.deathrattle_text()) + "[/b]")

	if c.has_skill():
		# 主动技能：名称 / PP 花费 / 目标 / 每回合一次 / 完整效果链
		var cost_bit := "免费" if c.skill_cost() <= 0 else "花费 %d PP" % c.skill_cost()
		var sk := "[b]技能「%s」：[/b]%s" % [_esc(c.skill_name()), cost_bit]
		if c.skill_target() != CardData.Targeting.NONE:
			sk += "，" + _esc(CardData.TARGET_NAMES.get(c.skill_target(), "需要目标"))
		if c.skill_once_per_turn():
			sk += "，每回合一次"
		lines.append(sk)
		lines.append("　└ " + _esc(c.chain_text(c.skill_chain())))

	# 主战者效果（照影之诗一代）：卡牌在某个时机给主战者挂的效果
	if not c.leader_effects.is_empty():
		var lead := c.leader_effects_text()
		if lead != "":
			lines.append("[b]主战者效果：[/b]" + _esc(lead))

	# 触发效果：某个时机自动结算的一条链（入场 / 召唤 / 离场 / 瞬念召唤 / 消失 / 回合开始·结束）
	if c.has_triggers():
		var trg := c.triggers_text()
		if trg != "":
			lines.append("[b]触发：[/b]" + _esc(trg))

	if c.description.strip_edges() != "":
		lines.append("[i]" + _esc(c.description) + "[/i]")

	# 只有关键字、没有其它内容时不必再写一行“无特殊效果”（关键字已单独显示）
	if lines.is_empty() and kn.size() == 0:
		lines.append("（无特殊效果）")
	_body.text = "\n".join(lines)


static func _esc(text: String) -> String:
	return text.replace("[", "[lb]")


func _token_name(token_id: String) -> String:
	if token_id.strip_edges() == "":
		return ""
	var t := CardDB.get_card(token_id)
	if t == null:
		return token_id + "（未找到）"
	return "%s %d/%d" % [t.card_name, t.attack, t.health]
