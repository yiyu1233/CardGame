class_name FusionDialog
extends Window
## 融合选择窗：把手牌里的一张「融合卡」与符合条件的手牌配对。
##
## 入口：Main 里右键点击手牌（只有带融合的卡才会打开；右键其它牌仍然是取消选择）。
## 这里只负责选材料与调用 `GameManager.fuse()`，融合规则全部在引擎侧：
##   * 材料是否符合兵种 / 种类 / 费用区间（CardData.fusion.filter）
##   * 融合前置条件（离场数 / 墓地张数…，CardData.fusion.require）
##   * 融合后触发「融合时」词条、结算手牌效果、获得效果、化身
## 选择数量必须刚好等于 fusion.count；材料从手牌进墓地。

signal fused(ok: bool)

var _gm = null
var _pid := 0
var _hand_index := -1
var _need := 1

var _title: Label = null
var _hint: Label = null
var _list: ItemList = null
var _ok: Button = null


func _ready() -> void:
	title = "融合"
	transient = true
	unresizable = false
	min_size = Vector2i(460, 380)
	close_requested.connect(_on_cancel)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 16)
	box.add_child(_title)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", Color("#90caf9"))
	box.add_child(_hint)

	_list = ItemList.new()
	_list.select_mode = ItemList.SELECT_MULTI
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.custom_minimum_size = Vector2(0, 220)
	box.add_child(_list)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(_on_cancel)
	row.add_child(cancel)
	_ok = Button.new()
	_ok.text = "融合"
	_ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ok.pressed.connect(_on_confirm)
	row.add_child(_ok)


## 打开窗口：`hand_index` = 手牌里的融合卡下标（必须是融合卡）
func open_for(gm, pid: int, hand_index: int) -> void:
	_gm = gm
	_pid = pid
	_hand_index = hand_index
	var p: PlayerState = gm.get_player(pid)
	if p == null or hand_index < 0 or hand_index >= p.hand.size():
		hide()
		return
	var card: CardData = p.hand[hand_index]
	if not card.has_fusion():
		hide()
		return
	_need = card.fusion_count()
	_title.text = "融合：「%s」" % card.card_name
	var req_text := card.fusion_text()
	var lines := PackedStringArray()
	lines.append("选择 %d 张材料（材料会进入墓地；融合卡留在手牌）。" % _need)
	if req_text != "":
		lines.append(req_text)
	_hint.text = "\n".join(lines)
	_list.clear()
	var mats: Array[int] = gm.fusion_materials(pid, hand_index)
	for i in mats:
		var m: CardData = p.hand[i]
		var troop := CardDB.troop_of(m)
		var extra := ""
		if not CardDB.is_neutral_troop(troop):
			extra = "·%s" % CardDB.troop_name(troop)
		var idx := _list.add_item("%s（%d 费，%s%s）" % [
			m.card_name, m.cost, m.type_name(), extra])
		_list.set_item_metadata(idx, i)
	_ok.disabled = mats.size() < _need
	popup_centered()
	_list.deselect_all()


func _on_confirm() -> void:
	if _gm == null:
		return
	var picks := _list.get_selected_items()
	var indices: Array[int] = []
	for p in picks:
		indices.append(int(_list.get_item_metadata(p)))
	# 单人 / 房主直接结算；客机由 request_fuse 打包成意图发给房主
	var ok := false
	if _gm.has_method("request_fuse"):
		ok = _gm.request_fuse(_hand_index, indices)
	else:
		ok = _gm.fuse(_pid, _hand_index, indices)
	fused.emit(ok)
	if ok:
		hide()
	else:
		_hint.text = "融合失败：材料数量不对或已不满足条件（可能刚被其它效果改动）"


func _on_cancel() -> void:
	fused.emit(false)
	hide()
