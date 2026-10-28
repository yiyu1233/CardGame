extends PanelContainer
## 美术设置（管理员）：**场景图片** + **卡牌卡图** + **卡牌特效**。
##
## - 场景图片：填路径（或点「选择文件」用系统文件对话框），应用到竞技区背景；留空 = 恢复默认纯色。
## - 卡牌卡图 / 特效：从下拉里选一张卡，填卡图路径、选特效名，保存后立即生效（写入卡表 JSON）。
## - 支持 `res://`（项目内）与 `user://` / 绝对路径（本地图片）；路径无效会提示且不写入。

signal closed()

const CARDDB_SAVE := "user://cards.json"

var _bg_edit: LineEdit
var _bg_tip: Label
var _card_option: OptionButton
var _art_edit: LineEdit
var _vfx_option: OptionButton
var _status: Label
var _file_dialog: FileDialog
var _dialog_for := ""

var _card_ids: Array[String] = []


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.11, 0.15, 0.98)
	style.border_color = Color(0.36, 0.44, 0.58, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	add_theme_stylebox_override("panel", style)
	custom_minimum_size = Vector2(560, 420)
	_build()


func _build() -> void:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	add_child(v)

	var title := Label.new()
	title.text = "美术设置（管理员）"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("#ffee58"))
	v.add_child(title)

	# ---- 场景图片 ----
	var bg_box := VBoxContainer.new()
	v.add_child(bg_box)
	var bg_label := Label.new()
	bg_label.text = "场景图片（竞技区背景，留空 = 默认纯色）"
	bg_label.add_theme_font_size_override("font_size", 13)
	bg_box.add_child(bg_label)
	var bg_row := HBoxContainer.new()
	bg_row.add_theme_constant_override("separation", 6)
	bg_box.add_child(bg_row)
	_bg_edit = LineEdit.new()
	_bg_edit.placeholder_text = "res://assets/bg.png 或 C:/图片/场地.jpg"
	_bg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bg_edit.text = ArtStore.background_path()
	bg_row.add_child(_bg_edit)
	var bg_pick := Button.new()
	bg_pick.text = "选择文件"
	bg_pick.pressed.connect(func() -> void: _open_file_dialog("bg"))
	bg_row.add_child(bg_pick)
	var bg_apply := Button.new()
	bg_apply.text = "应用"
	bg_apply.pressed.connect(_apply_background)
	bg_row.add_child(bg_apply)
	var bg_clear := Button.new()
	bg_clear.text = "清除"
	bg_clear.pressed.connect(_clear_background)
	bg_row.add_child(bg_clear)
	_bg_tip = Label.new()
	_bg_tip.add_theme_font_size_override("font_size", 11)
	_bg_tip.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
	bg_box.add_child(_bg_tip)

	var sep := HSeparator.new()
	v.add_child(sep)

	# ---- 卡牌卡图 / 特效 ----
	var card_label := Label.new()
	card_label.text = "卡牌卡图 / 出牌特效"
	card_label.add_theme_font_size_override("font_size", 13)
	v.add_child(card_label)
	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 6)
	v.add_child(card_row)
	_card_option = OptionButton.new()
	_card_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_ids.clear()
	for c in CardDB.cards:
		if c.is_token:
			continue
		_card_ids.append(c.id)
		_card_option.add_item("%s（%s）" % [c.card_name, c.id])
	card_row.add_child(_card_option)
	_card_option.item_selected.connect(func(_i: int) -> void: _load_card())

	var art_row := HBoxContainer.new()
	art_row.add_theme_constant_override("separation", 6)
	v.add_child(art_row)
	var art_label := Label.new()
	art_label.text = "卡图"
	art_row.add_child(art_label)
	_art_edit = LineEdit.new()
	_art_edit.placeholder_text = "留空 = 用 assets/art/card_art/ 里按卡 id 命名的图（再没有才用默认卡面）"
	_art_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	art_row.add_child(_art_edit)
	var art_pick := Button.new()
	art_pick.text = "选择文件"
	art_pick.pressed.connect(func() -> void: _open_file_dialog("art"))
	art_row.add_child(art_pick)

	var vfx_row := HBoxContainer.new()
	vfx_row.add_theme_constant_override("separation", 6)
	v.add_child(vfx_row)
	var vfx_label := Label.new()
	vfx_label.text = "出牌特效"
	vfx_row.add_child(vfx_label)
	_vfx_option = OptionButton.new()
	for name in ArtStore.vfx_options():
		_vfx_option.add_item(ArtStore.vfx_display(name))
	vfx_row.add_child(_vfx_option)
	var save_btn := Button.new()
	save_btn.text = "保存到卡表"
	save_btn.pressed.connect(_save_card_art)
	vfx_row.add_child(save_btn)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(func() -> void: closed.emit())
	vfx_row.add_child(close_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", 12)
	_status.add_theme_color_override("font_color", Color("#b9f6ca"))
	v.add_child(_status)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.size = Vector2i(720, 480)
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)

	_load_card()
	_refresh_bg_tip()


# ------------------------------ 场景图片 ------------------------------

func _open_file_dialog(which: String) -> void:
	_dialog_for = which
	_file_dialog.popup_centered()


func _on_file_selected(path: String) -> void:
	if _dialog_for == "bg":
		_bg_edit.text = path
		_apply_background()
	else:
		_art_edit.text = path


func _apply_background() -> void:
	var path := _bg_edit.text.strip_edges()
	if path == "":
		_clear_background()
		return
	if not ArtStore.has_texture(path):
		_status.text = "找不到可用的图片：%s" % path
		return
	ArtStore.set_background_path(path)
	_status.text = "场景图片已应用：%s" % path
	_refresh_bg_tip()


func _clear_background() -> void:
	ArtStore.set_background_path("")
	_bg_edit.text = ""
	_status.text = "已恢复默认背景"
	_refresh_bg_tip()


func _refresh_bg_tip() -> void:
	var tex := ArtStore.background_texture()
	_bg_tip.text = "当前：%s" % ("默认纯色" if tex == null else
		"%s（%d×%d）" % [ArtStore.background_path(), tex.get_width(), tex.get_height()])


# ------------------------------ 卡图 / 特效 ------------------------------

func _load_card() -> void:
	var id := _card_ids[_card_option.selected] if _card_option.selected >= 0 and _card_option.selected < _card_ids.size() else ""
	var card: CardData = CardDB.get_card(id) if id != "" else null
	if card == null:
		return
	_art_edit.text = card.art_path
	# 提示这张卡的「按 id 命名」约定路径：把图存成这个名字丢进去，不用在这里填
	_art_edit.placeholder_text = "留空 = 用 %s/%s.png（丢进项目即生效）" % [ArtStore.card_art_dir(), card.id]
	var idx := ArtStore.vfx_options().find(card.vfx)
	_vfx_option.selected = idx if idx >= 0 else 0


func _save_card_art() -> void:
	var id := _card_ids[_card_option.selected] if _card_option.selected >= 0 and _card_option.selected < _card_ids.size() else ""
	var card: CardData = CardDB.get_card(id) if id != "" else null
	if card == null:
		_status.text = "没选中卡牌"
		return
	var art := _art_edit.text.strip_edges()
	if art != "" and not ArtStore.has_texture(art):
		_status.text = "卡图路径无效，未保存：%s" % art
		return
	card.art_path = art
	var vfx := ArtStore.vfx_options()[_vfx_option.selected] if _vfx_option.selected >= 0 else ""
	card.vfx = vfx
	CardDB.save_to_file(CARDDB_SAVE)
	_status.text = "已保存「%s」：卡图 %s / 特效 %s" % [card.card_name,
		"默认" if art == "" else art, ArtStore.vfx_display(vfx)]
