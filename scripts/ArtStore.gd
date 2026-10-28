class_name ArtStore
extends RefCounted
## 美术资源存储（管理员可配置）：
##   * **场景图片**：竞技区背景图路径（空 = 用默认纯色底）
##   * **卡牌卡图**：每张卡自己的卡图路径（存在卡表 JSON 的 `art_path` 字段里）
##   * **卡牌特效**：每张卡的出牌特效名（存在卡表 JSON 的 `vfx` 字段里）
##
## ------------------------------ 后续加素材：只改文件名，不改代码 ------------------------------
##
## 约定目录 `res://assets/art/`（丢进项目 + 提交进仓库即可，缺目录 / 缺文件都自动回落）：
##   * `card_art/<卡 id>.png`  —— 卡面：**文件名 = 卡牌 id**（如 `c001.png`，支持 png / jpg / webp）。
##     它的优先级高于卡表里的 `art_path`，所以「把图丢进去」这张卡立刻换图，
##     旧存档、新建的卡都不用再进管理员面板填路径；想放弃约定文件就把文件删掉。
##   * `vfx/<特效 id>/`        —— 卡牌特效：**文件夹名 = 特效 id**（如 `vfx/poison/`），
##     会自己出现在管理员面板的「出牌特效」下拉里，不用改这里的内置清单；
##     文件夹里放 `color.txt`（一行 `#rrggbb`）可指定光环颜色，不写就按名字散列出稳定颜色。
##   * `voice/<事件名>.wav`    —— 语音 / 音效：事件名同 SoundFx（play / attack / win / lose /
##     button / turn_start …），**优先于**逆向导入素材；WAV 免 `.import`，拷进去就能播。
##
## 优先级：`assets/art/`（自备素材）＞ `assets/sv/`（逆向批量导入）＞ 代码内置（纯色 / 合成音）。
##
## 场景图片存在 `user://art.cfg`（与卡表分离，删卡表不影响背景）；
## 纹理统一走 `texture(path)`：支持 `res://` 与 `user://`，找不到就返回 null（界面自动回落）。
##
## 测试可用 `use_save_path(path)` 把存档重定向到临时文件、`use_art_root(path)` 重定向约定目录。

const SAVE_PATH := "user://art.cfg"
const VFX_NONE := ""
## 约定素材目录（自备美术材料的唯一入口；见文件头注释）
const ART_ROOT := "res://assets/art"
## 逆向批量导入的卡面（tools/import_sv_art.gd 写这里）：卡表没配卡面时的散列兜底池
const SV_CARD_ART_DIR := "res://assets/sv/card_art"
## 卡面允许的扩展名（按此顺序查找）
const ART_EXTS: Array[String] = [".png", ".jpg", ".jpeg", ".webp"]
const CARD_ART_SUBDIR := "card_art"
const VFX_SUBDIR := "vfx"
## 特效文件夹里可选的颜色文件：一行 `#rrggbb`
const VFX_COLOR_FILE := "color.txt"
## 出牌 / 命中特效清单（名字 → 颜色，界面按颜色做闪光与飘字）
const VFX_LIST: Array[String] = ["", "fire", "frost", "holy", "shadow", "nature", "arcane"]
const VFX_NAMES := {
	"": "无",
	"fire": "火焰",
	"frost": "冰霜",
	"holy": "圣光",
	"shadow": "暗影",
	"nature": "自然",
	"arcane": "奥术",
}
const VFX_COLORS := {
	"": Color("#cfd8dc"),
	"fire": Color("#ff7043"),
	"frost": Color("#4fc3f7"),
	"holy": Color("#fff59d"),
	"shadow": Color("#7e57c2"),
	"nature": Color("#81c784"),
	"arcane": Color("#4dd0e1"),
}

static var _save_path := SAVE_PATH
static var _art_root := ART_ROOT
static var _background := ""
static var _cache: Dictionary = {}
## 扩展包追加的「按卡 id 命名」的卡图目录（优先级：约定目录 > 这些 > 卡表 art_path）
static var _extra_card_art_dirs: Array[String] = []
## 扩展包运行期登记的特效：id → { name, color }
static var _rt_vfx: Dictionary = {}
## 扩展包 / 自备的卡背贴图（`assets/art/card_back.png`、`assets/sv/card_back.png` 或扩展包指定）
static var _card_back := ""
const CARD_BACK_NAMES: Array[String] = [
	"res://assets/art/card_back.png",
	"res://assets/sv/card_back.png",
	"res://assets/art/card_back.jpg",
	"res://assets/sv/card_back.jpg",
]


## 测试用：把配置重定向到指定文件
static func use_save_path(path: String) -> void:
	_save_path = path
	_background = ""
	_cache.clear()
	load_config()


static func save_path() -> String:
	return _save_path


## 测试用：把「约定素材目录」重定向到别处（默认 res://assets/art）
static func use_art_root(path: String) -> void:
	_art_root = path.strip_edges().trim_suffix("/")
	_vfx_custom.clear()


static func art_root() -> String:
	return _art_root


## 卡面约定目录：`assets/art/card_art/<卡 id>.png`
static func card_art_dir() -> String:
	return "%s/%s" % [_art_root, CARD_ART_SUBDIR]


## ------------------------------ 扩展包接口（Mods 调用） ------------------------------

## 追加一个「按卡 id 命名」的卡图目录（扩展包用；清空缓存让新图立刻生效）
static func add_card_art_dir(dir: String) -> void:
	var d := dir.strip_edges().trim_suffix("/")
	if d == "" or _extra_card_art_dirs.has(d):
		return
	_extra_card_art_dirs.append(d)
	_cache.clear()


static func extra_card_art_dirs() -> Array[String]:
	return _extra_card_art_dirs.duplicate()


## 运行期登记一个特效（扩展包用）：id + 显示名 + 颜色（`#rrggbb`，可空）
static func register_vfx(id: String, display: String = "", color: String = "") -> void:
	var key := id.strip_edges()
	if key == "":
		return
	_rt_vfx[key] = {"name": display if display != "" else key, "color": color}


## 指定卡背贴图（扩展包 / 管理员用）；传空则回落到约定文件
static func set_card_back(path: String) -> void:
	_card_back = path.strip_edges()


## 卡背贴图：显式指定优先，其次是 `assets/art/card_back.png` 等约定文件；没有返回 null（用纯绘制卡背）
static func card_back_path() -> String:
	if _card_back != "" and has_texture(_card_back):
		return _card_back
	for p in CARD_BACK_NAMES:
		if FileAccess.file_exists(p):
			return p
	return ""


static func card_back_texture() -> Texture2D:
	return texture(card_back_path())


## 特效约定目录：`assets/art/vfx/<特效 id>/`
static func vfx_dir() -> String:
	return "%s/%s" % [_art_root, VFX_SUBDIR]


static func load_config() -> void:
	_background = ""
	var cfg := ConfigFile.new()
	if cfg.load(_save_path) == OK:
		_background = str(cfg.get_value("art", "background", ""))


static func save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("art", "background", _background)
	cfg.save(_save_path)


## 存档里**显式**配置的背景值（"" = 没配过（用预设），`BG_NONE` = 纯色底，其它 = 图片路径）
static func saved_background() -> String:
	if _background == "" and _save_path == SAVE_PATH:
		load_config()
	return _background


## 场景背景图路径（空 = 用**战场预设**里目录第一张；`BG_NONE` = 明确要纯色底）
## 没显式设置时自动用**预设战场**（`assets/art/board/` 里的第一张图），
## 于是「从外部换一张战场」只要把图片丢进那个目录（见 `docs/extending.md`）。
static func background_path() -> String:
	if _background == "" and _save_path == SAVE_PATH:
		load_config()
	if _background == BG_NONE:
		return ""                      # 玩家明确选了「纯色底」
	if _background != "":
		return _background
	return default_board_preset()


## ------------------------------ 战场预设（外部换图） ------------------------------
## 把战场底图放在 `assets/art/board/` 下即可（png / jpg / webp）：
##   * 目录里只有一张 → 自动成为竞技区背景；
##   * 多张 → 按文件名排序取第一张；管理员面板里显式选过的背景优先于这里的任何一张。
const BOARD_DIR := "res://assets/art/board"
## 「纯色底」的哨兵值：玩家在设置里选了「纯色」就存它（空串是「自动用第一张预设」）
const BG_NONE := "-"
static var _board_list: Array[String] = []


static func board_presets() -> Array[String]:
	if _board_list.is_empty():
		var d := DirAccess.open(BOARD_DIR)
		if d != null:
			d.list_dir_begin()
			var f := d.get_next()
			while f != "":
				if not d.current_is_dir() and not f.begins_with("."):
					var lower := f.to_lower()
					for ext in ART_EXTS:
						if lower.ends_with(ext):
							_board_list.append("%s/%s" % [BOARD_DIR, f])
							break
				f = d.get_next()
			d.list_dir_end()
			_board_list.sort()
	return _board_list


static func default_board_preset() -> String:
	var list := board_presets()
	return list[0] if not list.is_empty() else ""


## 选一个预设战场作为背景（空串 = 清掉显式背景，回到自动预设）
static func use_board_preset(path: String) -> void:
	set_background_path(path)


static func set_background_path(path: String) -> void:
	_background = path.strip_edges()
	save_config()


static func background_texture() -> Texture2D:
	return texture(background_path())


## 载入纹理（带缓存）；路径为空 / 文件不存在 / 格式不支持都返回 null
static func texture(path: String) -> Texture2D:
	var p := path.strip_edges()
	if p == "":
		return null
	if _cache.has(p):
		return _cache[p]
	var tex: Texture2D = null
	if ResourceLoader.exists(p):
		var res := ResourceLoader.load(p)
		if res is Texture2D:
			tex = res
	if tex == null and FileAccess.file_exists(p):
		var img := Image.new()
		if img.load(p) == OK:
			tex = ImageTexture.create_from_image(img)
	_cache[p] = tex
	return tex


static func has_texture(path: String) -> bool:
	return texture(path) != null


## 卡牌特效：名字 → 颜色
## 内置表 → 特效文件夹里的 color.txt（一行 `#rrggbb`）→ 按名字散列出的稳定颜色；
## 既不在内置表也不是约定目录里的目录名 → 按"无"处理
static func vfx_color(vfx: String) -> Color:
	if VFX_COLORS.has(vfx):
		return VFX_COLORS[vfx]
	if _rt_vfx.has(vfx):
		var hex := str(_rt_vfx[vfx].get("color", ""))
		if hex.begins_with("#") and Color.html_is_valid(hex):
			return Color.html(hex)
		return _hashed_color(vfx)
	if not custom_vfx_ids().has(vfx):
		return VFX_COLORS[""]
	var hex2 := _custom_vfx_color(vfx)
	if hex2.begins_with("#") and Color.html_is_valid(hex2):
		return Color.html(hex2)
	return _hashed_color(vfx)


## 显示名：内置用中文名；自己加的用文件夹名；扩展包登记的用登记的显示名；未登记 → "无"
static func vfx_display(vfx: String) -> String:
	if VFX_NAMES.has(vfx):
		return VFX_NAMES[vfx]
	if _rt_vfx.has(vfx):
		return str(_rt_vfx[vfx].get("name", vfx))
	return vfx if custom_vfx_ids().has(vfx) else VFX_NAMES[""]


## 可选的出牌特效：内置清单 + `assets/art/vfx/` 下自己加的（文件夹名 = 特效 id）+ 扩展包登记的
static func vfx_options() -> Array[String]:
	var out: Array[String] = VFX_LIST.duplicate()
	for id in custom_vfx_ids():
		if not out.has(id):
			out.append(id)
	for id in _rt_vfx.keys():
		if not out.has(id):
			out.append(str(id))
	return out


## 约定目录里自己加的特效 id（目录名；空目录不存在时返回空数组，只扫一次）
static func custom_vfx_ids() -> Array[String]:
	if _vfx_custom.is_empty():
		var d := DirAccess.open(vfx_dir())
		if d != null:
			d.list_dir_begin()
			var f := d.get_next()
			while f != "":
				if d.current_is_dir() and not f.begins_with("."):
					_vfx_custom.append(f)
				f = d.get_next()
			d.list_dir_end()
		_vfx_custom.sort()
	return _vfx_custom


static func _custom_vfx_color(vfx: String) -> String:
	var f := FileAccess.open("%s/%s/%s" % [vfx_dir(), vfx, VFX_COLOR_FILE], FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else ""


## 按 id 散列出一个稳定颜色（同一个特效名永远同一个颜色，方便不写 color.txt 也能区分）
static func _hashed_color(id: String) -> Color:
	return Color.from_hsv(float(abs(hash(id)) % 360) / 360.0, 0.55, 0.95)


# ------------------------------ 卡面（按卡 id 命名即生效） ------------------------------
#
# 卡图有两个来源，都在这里解析，界面只管拿结果：
#   ① 约定目录里**按卡 id 命名**的文件（`assets/art/card_art/c001.png`）——优先级最高，
#      把图丢进去这张卡就换图，不用动卡表、不用进管理员面板；
#   ② 卡表里的 `art_path`（管理员面板里填的 / 导入素材时分配的）；
#   ③ 都没有时，`default_card_art()` 再按**卡 id 的稳定哈希**从逆向导入素材里挑一张
#      （同一张卡每次都拿到同一张图，任何存档都能看到卡图）。

static var _vfx_custom: Array[String] = []
static var _card_art_list: Array[String] = []


## 约定目录里这张卡的卡面：`assets/art/card_art/<卡 id>.png`；
## 其次扫扩展包追加的目录。没有返回空串
static func card_art_for(card_id: String) -> String:
	var id := card_id.strip_edges()
	if id == "":
		return ""
	for ext in ART_EXTS:
		var p := "%s/%s%s" % [card_art_dir(), id, ext]
		if FileAccess.file_exists(p):
			return p
	for dir in _extra_card_art_dirs:
		for ext in ART_EXTS:
			var q := "%s/%s%s" % [dir, id, ext]
			if FileAccess.file_exists(q):
				return q
	return ""


## 这张卡最终显示哪张卡图：约定目录里按卡 id 命名的文件优先，其次是卡表里的 art_path
static func art_for(card) -> String:
	if card == null:
		return ""
	var by_id := card_art_for(str(card.id))
	if by_id != "":
		return by_id
	return str(card.art_path)


## 逆向导入的卡面清单（缓存；没有导入过就返回空）
static func card_art_list() -> Array[String]:
	if _card_art_list.is_empty():
		var d := DirAccess.open(SV_CARD_ART_DIR)
		if d != null:
			d.list_dir_begin()
			var f := d.get_next()
			while f != "":
				if not d.current_is_dir() and f.to_lower().ends_with(".png"):
					_card_art_list.append("%s/%s" % [SV_CARD_ART_DIR, f])
				f = d.get_next()
			d.list_dir_end()
		_card_art_list.sort()
	return _card_art_list


## ------------------------------ 卡图映射表（可选） ------------------------------
## `res://data/card_art_map.json`：`{ "c001": "res://assets/sv/card_art/1000110100.png", ... }`
## 由 `tools/import_sv_art.gd` 生成。有它就**每张卡一张专属卡图**（不靠哈希、不会撞图）；
## 没有就退化成「按卡 id 稳定散列」从导入素材里挑一张。
const ART_MAP_PATH := "res://data/card_art_map.json"
static var _art_map: Dictionary = {}


static func card_art_map() -> Dictionary:
	if _art_map.is_empty():
		var f := FileAccess.open(ART_MAP_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				_art_map = parsed
	return _art_map


## 某张卡的默认卡图：① 约定目录里按卡 id 命名的文件；② 卡图映射表；③ 按 id 稳定散列
static func default_card_art(card_id: String) -> String:
	var by_id := card_art_for(card_id)
	if by_id != "":
		return by_id
	var mapped := str(card_art_map().get(card_id, ""))
	if mapped != "" and FileAccess.file_exists(mapped):
		return mapped
	var list := card_art_list()
	if list.is_empty() or card_id == "":
		return ""
	var h: int = abs(hash(card_id))
	return list[h % list.size()]