class_name DeckBuilderDialog
extends Window
## 组卡界面（主页「组卡 / 我的卡组」按钮打开）。
##
## 流程：**先选主战者职业 → 再自由组卡**，一套卡组绑定一个职业。
## 管理员删除职业后，原本属于它的卡会自动变成中立卡（见 CardDB.remove_hero_class），
## 所以这里的「可用卡牌」永远是当下的真实口径。
##
## 设计要点：
##   * 可用卡池 = **本职业 + 中立**（CardDB.card_allowed_for_class）：别的职业的卡
##     根本不会出现在列表里，不用玩家自己背职业表；
##   * 每套卡组的合法性由 CardDB.player_deck_errors() 统一判定（张数区间、同名上限、
##     城邦上限、卡是否存在），界面提示与真正发牌是同一套口径；
##   * 卡组存在 user://decks.json（CardDB.player_decks），选中的那套写进
##     GameSettings.selected_deck，GameManager.new_game() 直接用它发牌。

signal deck_changed(deck_id: String)
signal closed()

const TYPE_NAMES := ["随从", "法术", "护符", "城邦"]
const ROW_HEIGHT := 34

## 对战模式（指定 / 无限）：决定可用卡包与该模式的限制卡 / 张数规则
var _mode_option: OptionButton
## 卡包筛选：第一项「全部卡包」，其余是当前模式允许的卡包（CardDB.packs）
var _pack_option: OptionButton
var _class_option: OptionButton
var _class_desc: Label
var _decks_box: VBoxContainer
var _pool_box: VBoxContainer
var _deck_box: VBoxContainer
var _name_edit: LineEdit
var _search_edit: LineEdit
var _type_option: OptionButton
## 兵种筛选：第一项「全部兵种」，其余是管理员创建的兵种（CardDB.troops）
var _troop_option: OptionButton
var _info_label: Label
var _status_label: Label
var _save_btn: Button
var _use_btn: Button
var _del_btn: Button
var _new_btn: Button

var _class_id: String = ""
var _deck_id: String = ""
## 当前组卡用的模式（默认取主页选的那个；这里也能改，改完写回 GameSettings）
var _mode: String = Formats.UNLIMITED
## 正在编辑的内容：卡牌 id -> 份数
var _entries: Dictionary = {}


func _ready() -> void:
	title = "组建卡组"
	size = Vector2i(1040, 660)
	unresizable = true
	transient = true
	close_requested.connect(_on_close_requested)
	_class_id = _pick_initial_class()
	_mode = Formats.normalized_mode(str(GameSettings.get("selected_mode")))
	_build_ui()
	_sync_initial_deck()
	_refresh_all()


# ------------------------------ 界面 ------------------------------

func _build_ui() -> void:
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 14)
	root.add_theme_constant_override("margin_right", 14)
	root.add_theme_constant_override("margin_top", 14)
	root.add_theme_constant_override("margin_bottom", 14)
	add_child(root)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	root.add_child(vbox)

	# ---- 第一行：主战者职业 ----
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	vbox.add_child(top)

	var title_label := Label.new()
	title_label.text = "主战者职业"
	title_label.add_theme_color_override("font_color", Color("#ffcc80"))
	top.add_child(title_label)

	_class_option = OptionButton.new()
	_class_option.custom_minimum_size = Vector2(200, 0)
	_class_option.item_selected.connect(_on_class_selected)
	top.add_child(_class_option)

	# 对战模式：指定 = 只能用管理员勾选的几个卡包；无限 = 所有卡包
	var mode_label := Label.new()
	mode_label.text = "对战模式"
	mode_label.add_theme_color_override("font_color", Color("#ffcc80"))
	top.add_child(mode_label)
	_mode_option = OptionButton.new()
	_mode_option.custom_minimum_size = Vector2(120, 0)
	for m in Formats.mode_ids():
		_mode_option.add_item(Formats.mode_label(m))
		_mode_option.set_item_metadata(_mode_option.item_count - 1, m)
	_mode_option.item_selected.connect(_on_mode_selected)
	top.add_child(_mode_option)

	_class_desc = Label.new()
	_class_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_class_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_class_desc.add_theme_font_size_override("font_size", 12)
	_class_desc.add_theme_color_override("font_color", Color(0.72, 0.77, 0.84))
	top.add_child(_class_desc)

	# ---- 三栏：我的卡组 / 可用卡牌 / 当前卡组 ----
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 12)
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(cols)

	# 左：卡组列表
	var deck_col := VBoxContainer.new()
	deck_col.add_theme_constant_override("separation", 6)
	deck_col.custom_minimum_size = Vector2(240, 0)
	cols.add_child(deck_col)
	var decks_title := Label.new()
	decks_title.text = "我的卡组"
	decks_title.add_theme_color_override("font_color", Color("#ffee58"))
	deck_col.add_child(decks_title)
	var decks_scroll := ScrollContainer.new()
	decks_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	decks_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	deck_col.add_child(decks_scroll)
	_decks_box = VBoxContainer.new()
	_decks_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_decks_box.add_theme_constant_override("separation", 4)
	decks_scroll.add_child(_decks_box)
	var deck_btn_row := HBoxContainer.new()
	deck_btn_row.add_theme_constant_override("separation", 6)
	deck_col.add_child(deck_btn_row)
	_new_btn = Button.new()
	_new_btn.text = "新建卡组"
	_new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_btn.pressed.connect(_on_new_deck)
	deck_btn_row.add_child(_new_btn)
	_del_btn = Button.new()
	_del_btn.text = "删除"
	_del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_del_btn.pressed.connect(_on_delete_deck)
	deck_btn_row.add_child(_del_btn)

	# 中：可用卡牌（本职业 + 中立）
	var pool_col := VBoxContainer.new()
	pool_col.add_theme_constant_override("separation", 6)
	pool_col.custom_minimum_size = Vector2(330, 0)
	pool_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(pool_col)
	var pool_title := Label.new()
	pool_title.text = "可用卡牌（本职业 + 中立）"
	pool_title.add_theme_color_override("font_color", Color("#90caf9"))
	pool_col.add_child(pool_title)
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	pool_col.add_child(filter_row)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "搜索卡牌名 / 效果…"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.text_changed.connect(func(_t: String) -> void: _refresh_pool())
	filter_row.add_child(_search_edit)
	_type_option = OptionButton.new()
	for t in TYPE_NAMES:
		_type_option.add_item(t)
	_type_option.add_item("全部类型", 0)
	_type_option.select(TYPE_NAMES.size())
	_type_option.item_selected.connect(func(_i: int) -> void: _refresh_pool())
	filter_row.add_child(_type_option)
	# 兵种筛选（影之诗的 士兵 / 指挥官 那类）：兵种名也能直接被上面的搜索框搜到
	_troop_option = OptionButton.new()
	_troop_option.add_item("全部兵种")
	_troop_option.set_item_metadata(0, "")
	for e in CardDB.troops:
		var tid := str(e.get("id", ""))
		_troop_option.add_item(str(e.get("name", tid)))
		_troop_option.set_item_metadata(_troop_option.item_count - 1, tid)
	_troop_option.item_selected.connect(func(_i: int) -> void: _refresh_pool())
	filter_row.add_child(_troop_option)
	# 卡包筛选（照影之诗的卡包）：只列当前模式允许的卡包，选一个就只看它
	_pack_option = OptionButton.new()
	_pack_option.item_selected.connect(func(_i: int) -> void: _refresh_pool())
	filter_row.add_child(_pack_option)
	var pool_scroll := ScrollContainer.new()
	pool_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pool_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pool_col.add_child(pool_scroll)
	_pool_box = VBoxContainer.new()
	_pool_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pool_box.add_theme_constant_override("separation", 4)
	pool_scroll.add_child(_pool_box)

	# 右：当前卡组内容
	var build_col := VBoxContainer.new()
	build_col.add_theme_constant_override("separation", 6)
	build_col.custom_minimum_size = Vector2(330, 0)
	build_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(build_col)
	var build_title := Label.new()
	build_title.text = "当前卡组"
	build_title.add_theme_color_override("font_color", Color("#ffee58"))
	build_col.add_child(build_title)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	build_col.add_child(name_row)
	_name_edit = LineEdit.new()
	_name_edit.max_length = CardDB.DECK_NAME_MAX_LENGTH
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(_name_edit)
	var template_btn := Button.new()
	template_btn.text = "载入推荐搭配"
	template_btn.pressed.connect(_on_template)
	name_row.add_child(template_btn)
	var build_scroll := ScrollContainer.new()
	build_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	build_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	build_col.add_child(build_scroll)
	_deck_box = VBoxContainer.new()
	_deck_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_box.add_theme_constant_override("separation", 4)
	build_scroll.add_child(_deck_box)

	# ---- 信息与按钮 ----
	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 12)
	_info_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	vbox.add_child(_info_label)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 10)
	bottom.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(bottom)

	_use_btn = Button.new()
	_use_btn.text = "设为出战卡组"
	_use_btn.custom_minimum_size = Vector2(140, 36)
	_use_btn.pressed.connect(_on_use)
	bottom.add_child(_use_btn)
	_save_btn = Button.new()
	_save_btn.text = "保存卡组"
	_save_btn.custom_minimum_size = Vector2(130, 36)
	_save_btn.pressed.connect(_on_save)
	bottom.add_child(_save_btn)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(100, 36)
	close_btn.pressed.connect(func() -> void: _on_close_requested())
	bottom.add_child(close_btn)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", Color("#b9f6ca"))
	vbox.add_child(_status_label)


# ------------------------------ 数据搬运 ------------------------------

func _pick_initial_class() -> String:
	var saved := str(GameSettings.get("selected_class"))
	if saved != "" and CardDB.has_hero_class(saved):
		return saved
	if not CardDB.hero_classes.is_empty():
		return str(CardDB.hero_classes[0].get("id", ""))
	return ""


## 打开界面时先展示正在出战的那套卡组（没有就展示该职业的第一套 / 空的新卡组）
func _sync_initial_deck() -> void:
	var active := str(GameSettings.get("selected_deck"))
	var def := CardDB.player_deck_by_id(active)
	if def.is_empty():
		var owned := CardDB.player_decks_of_class(_class_id)
		if not owned.is_empty():
			def = owned[0]
	if def.is_empty():
		_new_deck()
		return
	_load_deck(str(def.get("id", "")))


func _current_def() -> Dictionary:
	return {
		"id": _deck_id,
		"name": _name_edit.text.strip_edges(),
		"class_id": _class_id,
		"cards": _entries_array(),
	}


## 当前编辑内容 → 「id × 份数」清单（按费用、名字排序，存档不会因为点击顺序变来变去）
func _entries_array() -> Array:
	var out: Array = []
	for c in CardDB.cards:
		var n: int = int(_entries.get(c.id, 0))
		if n > 0:
			out.append({"id": c.id, "count": n})
	return out


func _load_deck(deck_id: String) -> void:
	var def := CardDB.player_deck_by_id(deck_id)
	if def.is_empty():
		return
	_deck_id = deck_id
	_entries.clear()
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var cid := str(e.get("id", ""))
		_entries[cid] = int(_entries.get(cid, 0)) + int(e.get("count", 1))
	if CardDB.has_hero_class(str(def.get("class_id", ""))):
		_class_id = str(def.get("class_id", ""))
	_name_edit.text = str(def.get("name", ""))


func _new_deck() -> void:
	_deck_id = ""
	_entries.clear()
	var n := CardDB.player_decks.size() + 1
	var base := "新卡组 %d" % n
	while _deck_name_taken(base):
		n += 1
		base = "新卡组 %d" % n
	_name_edit.text = base


func _deck_name_taken(name: String) -> bool:
	for d in CardDB.player_decks:
		if str(d.get("id", "")) == _deck_id:
			continue
		if str(d.get("name", "")) == name:
			return true
	return false


# ------------------------------ 刷新 ------------------------------

func _refresh_all() -> void:
	_refresh_class_option()
	_refresh_mode_option()
	_refresh_pack_option()
	_refresh_deck_list()
	_refresh_pool()
	_refresh_deck_content()
	_refresh_info()


func _refresh_mode_option() -> void:
	if _mode_option == null:
		return
	for i in _mode_option.item_count:
		if str(_mode_option.get_item_metadata(i)) == _mode:
			_mode_option.select(i)
			break
	_mode_option.tooltip_text = Formats.mode_desc(_mode)


## 卡包下拉：全部卡包 + 当前模式允许的卡包（指定模式 = 管理员勾选的；无限 = 全部）。
## 重建后尽量保留原来选中的卡包，包被移出本模式就回落到「全部卡包」。
func _refresh_pack_option() -> void:
	if _pack_option == null:
		return
	var keep := _selected_pack_filter()
	_pack_option.clear()
	_pack_option.add_item("全部卡包")
	_pack_option.set_item_metadata(0, "")
	var ids := CardDB.mode_allowed_packs(_mode)
	for pid in ids:
		_pack_option.add_item("%s（%d 种）" % [CardDB.pack_name(pid), CardDB.pack_card_count(pid)])
		_pack_option.set_item_metadata(_pack_option.item_count - 1, pid)
	var pick := 0
	for i in _pack_option.item_count:
		if str(_pack_option.get_item_metadata(i)) == keep:
			pick = i
			break
	_pack_option.select(pick)


func _refresh_class_option() -> void:
	_class_option.clear()
	if CardDB.hero_classes.is_empty():
		_class_option.add_item("（管理员未添加职业）", 0)
		_class_option.disabled = true
		_class_desc.text = "管理员还没有添加任何主战者职业，当前可以把所有卡牌加入卡组。"
		return
	_class_option.disabled = false
	for i in CardDB.hero_classes.size():
		var e: Dictionary = CardDB.hero_classes[i]
		var cid := str(e.get("id", ""))
		var label := "%s（%d 种卡 + 中立 %d 种）" % [
			str(e.get("name", cid)), CardDB.class_card_count(cid), CardDB.neutral_card_count()]
		_class_option.add_item(label, i)
		_class_option.set_item_metadata(i, cid)
	for i in _class_option.item_count:
		if str(_class_option.get_item_metadata(i)) == _class_id:
			_class_option.select(i)
			break
	var def := CardDB.hero_class_by_id(_class_id)
	_class_desc.text = str(def.get("desc", "")) if not def.is_empty() else ""


func _clear_box(box: VBoxContainer) -> void:
	for child in box.get_children():
		child.queue_free()


func _row_button(parent: VBoxContainer, text: String, color: Color, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	b.clip_text = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if color != Color():
		b.add_theme_color_override("font_color", color)
	b.pressed.connect(handler)
	parent.add_child(b)
	return b


func _refresh_deck_list() -> void:
	_clear_box(_decks_box)
	var decks := CardDB.player_decks_of_class(_class_id)
	if decks.is_empty():
		var empty := Label.new()
		empty.text = "还没有这个职业的卡组，点「新建卡组」开始。"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
		_decks_box.add_child(empty)
		return
	for d in decks:
		var did := str(d.get("id", ""))
		var def: Dictionary = d
		var errors := CardDB.player_deck_errors(def, _mode)
		var total: int = int(CardDB.player_deck_stats(def, _mode).get("total", 0))
		var color := Color("#b9f6ca") if errors.is_empty() else Color("#ef9a9a")
		if did == _deck_id:
			color = Color("#ffee58")
		var text := "%s　%d 张%s" % [str(def.get("name", did)), total, "　⚠" if not errors.is_empty() else ""]
		var b := _row_button(_decks_box, text, color, func() -> void: _on_pick_deck(did))
		b.tooltip_text = errors[0] if not errors.is_empty() else "点击编辑这套卡组"


## type_filter：0–3 = 指定类型，**-1 = 全部类型**（最后一项）
func _refresh_pool() -> void:
	_clear_box(_pool_box)
	var keyword := _search_edit.text.strip_edges().to_lower()
	var type_filter: int = _type_option.selected if _type_option.selected < TYPE_NAMES.size() else -1
	var troop_filter := _selected_troop_filter()
	var pack_filter := _selected_pack_filter()
	var count := 0
	for c in CardDB.cards:
		if c.is_token or not CardDB.card_allowed_for_class(c, _class_id):
			continue
		# 模式卡池：指定模式只显示管理员勾选卡包里的卡，且排除该模式的限制卡（禁用）
		if not CardDB.mode_allows_card(_mode, c):
			continue
		if pack_filter != "" and CardDB.pack_of(c) != pack_filter:
			continue
		if not _card_matches(c, keyword, type_filter, troop_filter):
			continue
		var chosen: int = int(_entries.get(c.id, 0))
		var per_card := CardDB.max_copies_for_mode(c, _mode)
		var own := CardDB.card_class_of(c)
		var color := CardDB.hero_class_color(own) if own != CardData.NEUTRAL_CLASS else Color(0.86, 0.89, 0.93)
		# 携带数放最前面：效果文字再长也只会被裁掉尾巴，不会把「已带 / 上限」挤没
		var b := _row_button(_pool_box, "%d/%d　%s" % [chosen, per_card, _card_detail(c)],
			color, func() -> void: _on_add(c.id))
		b.disabled = per_card <= 0 or chosen >= per_card
		b.tooltip_text = "\n".join(c.summary_lines())
		count += 1
	if count == 0:
		var empty := Label.new()
		empty.text = "没有匹配的卡牌。"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
		_pool_box.add_child(empty)


func _card_detail(c: CardData) -> String:
	var body := "%d费 %s（%s）" % [c.cost, c.card_name, c.type_name()]
	# 兵种：中立是默认值，不额外标注；别的兵种跟在类型后面
	var tid := CardDB.troop_of(c)
	if not CardDB.is_neutral_troop(tid):
		body += "·%s" % CardDB.troop_name(tid)
	# 卡包：基础包不标注，别的卡包跟在后面，方便一眼看出这张卡来自哪个包
	var pid := CardDB.pack_of(c)
	if pid != CardDB.DEFAULT_PACK:
		body += "·%s" % CardDB.pack_name(pid)
	if c.is_minion():
		body += " %d/%d" % [c.attack, c.health]
	elif c.is_permanent():
		body += " 耐久 %d" % c.durability()
	var extra := c.effect_text()
	if extra != "":
		body += "　" + extra
	return body


## 检索口径统一走 CardDB.card_matches：卡名 / 描述 / 效果 / 亡语 / 关键字 / **兵种名**，
## 别的界面（管理员卡表列表）用的是同一个函数，两边搜出来的结果不会不一致。
func _card_matches(c: CardData, keyword: String, type_filter: int, troop_filter: String = "") -> bool:
	return CardDB.card_matches(c, keyword, type_filter, troop_filter)


## 当前选中的兵种筛选（"" = 全部兵种）
func _selected_troop_filter() -> String:
	if _troop_option == null or _troop_option.selected < 0:
		return ""
	var meta = _troop_option.get_item_metadata(_troop_option.selected)
	return "" if meta == null else str(meta)


## 当前选中的卡包筛选（"" = 全部卡包）
func _selected_pack_filter() -> String:
	if _pack_option == null or _pack_option.selected < 0:
		return ""
	var meta = _pack_option.get_item_metadata(_pack_option.selected)
	return "" if meta == null else str(meta)


func _refresh_deck_content() -> void:
	_clear_box(_deck_box)
	var total := 0
	for c in CardDB.cards:
		var n: int = int(_entries.get(c.id, 0))
		if n <= 0:
			continue
		total += n
		var per_card := CardDB.max_copies_for_mode(c, _mode)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_deck_box.add_child(row)

		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size = Vector2(32, ROW_HEIGHT)
		minus.pressed.connect(func() -> void: _on_subtract(c.id))
		row.add_child(minus)

		var label := Label.new()
		label.text = "%d费 %s ×%d" % [c.cost, c.card_name, n]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		label.add_theme_font_size_override("font_size", 12)
		label.tooltip_text = "\n".join(c.summary_lines())
		if CardDB.card_class_of(c) == CardData.NEUTRAL_CLASS:
			label.add_theme_color_override("font_color", Color(0.86, 0.89, 0.93))
		else:
			label.add_theme_color_override("font_color", CardDB.hero_class_color(CardDB.card_class_of(c)))
		row.add_child(label)

		var plus := Button.new()
		plus.text = "＋"
		plus.custom_minimum_size = Vector2(32, ROW_HEIGHT)
		plus.disabled = n >= per_card
		plus.pressed.connect(func() -> void: _on_add(c.id))
		row.add_child(plus)
	if total == 0:
		var empty := Label.new()
		empty.text = "点中间列表里的卡牌就能加进卡组，这里用 −/＋ 调整份数。"
		empty.add_theme_font_size_override("font_size", 12)
		empty.add_theme_color_override("font_color", Color(0.66, 0.70, 0.78))
		_deck_box.add_child(empty)


func _refresh_info() -> void:
	var def := _current_def()
	var stats := CardDB.player_deck_stats(def, _mode)
	var total: int = int(stats.get("total", 0))
	var type_over: int = int(stats.get("type_over", 0))
	var min_size := CardDB.mode_deck_min(_mode)
	var max_size := CardDB.mode_deck_max(_mode)
	var max_text: String = "%d 张" % max_size if max_size > 0 else "不限"
	var cap_bits := PackedStringArray()
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL, CardData.CardType.AMULET, CardData.CardType.CITY]:
		var tc := CardDB.mode_type_cap(_mode, t)
		if tc > 0:
			cap_bits.append("%s≤%d" % [CardData.TYPE_NAMES[t], tc])
	var cap_text := "、".join(cap_bits) if not cap_bits.is_empty() else "各类不限"
	_info_label.text = "%s模式　共 %d 张（规则要求 %d–%s）　同名最多 %d 张　城邦 %d/%d" % [
		CardDB.mode_label(_mode), total, min_size, max_text, maxi(1, CardDB.mode_max_copies(_mode)),
		int(stats.get("city", 0)), CardData.CITY_DECK_LIMIT]
	if type_over > 0:
		_info_label.text += "　⚠ 有 %d 张超类上限（%s）" % [type_over, cap_text]
	var errors := CardDB.player_deck_errors(def, _mode)
	if not errors.is_empty():
		_info_label.text += "\n⚠ " + "\n⚠ ".join(errors)
		_info_label.add_theme_color_override("font_color", Color(0.85, 0.80, 0.80))
	else:
		_info_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	_save_btn.disabled = not errors.is_empty()
	_use_btn.disabled = _deck_id == ""
	_del_btn.disabled = _deck_id == ""


# ------------------------------ 交互 ------------------------------

## 切换对战模式：写回 GameSettings（主页 / 开局都用它），再按新模式重建卡池与提示。
## 卡组内容不丢：不合规的卡会以「⚠」形式标出来，玩家自己决定是改卡组还是切回无限。
func _on_mode_selected(index: int) -> void:
	if _mode_option == null or index < 0:
		return
	var meta = _mode_option.get_item_metadata(index)
	var mode := Formats.normalized_mode(str(meta) if meta != null else "")
	if mode == _mode:
		return
	_mode = mode
	GameSettings.selected_mode = mode
	GameSettings.save_settings()
	SoundFx.play("button")
	_refresh_all()
	_set_status("已切换到「%s」模式：%s" % [CardDB.mode_label(mode), Formats.mode_desc(mode)])


func _on_class_selected(index: int) -> void:
	SoundFx.play("button")
	var cid := str(_class_option.get_item_metadata(index))
	if cid == _class_id or CardDB.hero_classes.is_empty():
		return
	_class_id = cid
	GameSettings.selected_class = cid
	GameSettings.save_settings()
	# 换职业等于重新挑一套：正在编辑的都没意义了（所属职业不同）
	_sync_initial_deck()
	_refresh_all()
	_set_status("已切换到「%s」，可用卡牌只包含它的职业卡 + 中立卡。" % CardDB.hero_class_name(cid))


func _on_pick_deck(deck_id: String) -> void:
	SoundFx.play("button")
	_load_deck(deck_id)
	_refresh_all()


func _on_new_deck() -> void:
	SoundFx.play("button")
	_new_deck()
	_refresh_all()
	_set_status("新建卡组：%s模式加满 %d 张后点「保存卡组」。" % [
		CardDB.mode_label(_mode), CardDB.mode_deck_min(_mode)])


func _on_add(card_id: String) -> void:
	var c := CardDB.get_card(card_id)
	if c == null or not CardDB.card_allowed_for_class(c, _class_id):
		return
	if not CardDB.mode_allows_card(_mode, c):
		_set_status("这张卡不在「%s」模式的可用卡包里，或已被本模式限制。" % CardDB.mode_label(_mode))
		return
	var n: int = int(_entries.get(card_id, 0))
	if n >= CardDB.max_copies_for_mode(c, _mode):
		return
	_entries[card_id] = n + 1
	SoundFx.play("draw")
	_refresh_pool()
	_refresh_deck_content()
	_refresh_info()


func _on_subtract(card_id: String) -> void:
	var n: int = int(_entries.get(card_id, 0))
	if n <= 0:
		return
	if n == 1:
		_entries.erase(card_id)
	else:
		_entries[card_id] = n - 1
	SoundFx.play("button")
	_refresh_pool()
	_refresh_deck_content()
	_refresh_info()


func _on_save() -> void:
	SoundFx.play("button")
	var def: Dictionary = _current_def()
	var errors: Array[String] = CardDB.player_deck_errors(def, _mode)
	if not errors.is_empty():
		_set_status("还不能保存（%s模式）：%s" % [CardDB.mode_label(_mode), errors[0]])
		return
	var deck_name: String = str(def.get("name", ""))
	if deck_name == "":
		_set_status("请先给这套卡组起个名字。")
		return
	var new_id: String = CardDB.upsert_player_deck(_deck_id, deck_name, _class_id, def.get("cards", []))
	if new_id == "":
		_set_status("保存失败（写入 user://decks.json 出错）。")
		return
	_deck_id = new_id
	GameSettings.selected_deck = new_id
	GameSettings.selected_class = _class_id
	GameSettings.save_settings()
	_refresh_all()
	deck_changed.emit(new_id)
	_set_status("已保存「%s」并设为出战卡组。" % name)


func _on_use() -> void:
	SoundFx.play("button")
	if _deck_id == "":
		_set_status("这套卡组还没保存，先点「保存卡组」。")
		return
	var def := CardDB.player_deck_by_id(_deck_id)
	if def.is_empty() or str(def.get("class_id", "")) != _class_id:
		_set_status("请先保存这套卡组。")
		return
	var errors := CardDB.player_deck_errors(def, _mode)
	if not errors.is_empty():
		_set_status("这套卡组在%s模式用不了：%s" % [CardDB.mode_label(_mode), errors[0]])
		return
	GameSettings.selected_deck = _deck_id
	GameSettings.selected_class = _class_id
	GameSettings.save_settings()
	_refresh_all()
	deck_changed.emit(_deck_id)
	_set_status("出战卡组已设为「%s」。" % str(def.get("name", _deck_id)))


func _on_delete_deck() -> void:
	if _deck_id == "":
		return
	SoundFx.play("button")
	var name := str(CardDB.player_deck_by_id(_deck_id).get("name", _deck_id))
	CardDB.remove_player_deck(_deck_id)
	if str(GameSettings.get("selected_deck")) == _deck_id:
		GameSettings.selected_deck = ""
		GameSettings.save_settings()
	_deck_id = ""
	_new_deck()
	_refresh_all()
	deck_changed.emit("")
	_set_status("已删除卡组「%s」。" % name)


func _on_template() -> void:
	SoundFx.play("button")
	var allowed: Array[Dictionary] = []
	for d in CardDB.prebuilt_decks:
		if CardDB.prebuilt_deck_allowed_for_class(d, _class_id):
			allowed.append(d)
	if allowed.is_empty():
		_set_status("没有适合「%s」的推荐搭配（推荐里面的卡不属于本职业 / 中立）。" % CardDB.hero_class_name(_class_id))
		return
	var win := Window.new()
	win.title = "载入推荐搭配"
	win.size = Vector2i(420, 320)
	win.transient = true
	add_child(win)
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 12)
	win.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	m.add_child(v)
	var hint := Label.new()
	hint.text = "选一套填充到当前卡组（会替换现在的内容，之后再点保存）。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	v.add_child(hint)
	for d in allowed:
		var def: Dictionary = d
		var did := str(def.get("id", ""))
		var b := Button.new()
		b.text = "%s（%d 张）" % [str(def.get("name", did)), CardDB.prebuilt_deck_size(def, CardDB.max_copies)]
		b.custom_minimum_size = Vector2(0, ROW_HEIGHT)
		b.pressed.connect(func() -> void:
			_apply_template(def)
			win.queue_free())
		v.add_child(b)
	win.popup_centered()


func _apply_template(def: Dictionary) -> void:
	_entries.clear()
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var cid := str(e.get("id", ""))
		var tpl := CardDB.get_card(cid)
		if tpl == null or not CardDB.card_allowed_for_class(tpl, _class_id):
			continue
		if not CardDB.mode_allows_card(_mode, tpl):
			continue
		_entries[cid] = mini(int(e.get("count", 1)), CardDB.max_copies_for_mode(tpl, _mode))
	_refresh_all()
	_set_status("已载入推荐搭配「%s」，检查张数后点「保存卡组」。" % str(def.get("name", "")))


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _on_close_requested() -> void:
	closed.emit()
	queue_free()
