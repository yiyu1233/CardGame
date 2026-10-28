extends SceneTree
## Shadowverse 素材导入工具（逆向工程导出物 → 本项目）
##
## 用法：godot --path <项目目录> --script res://tools/import_sv_art.gd [-- 数量]
##
## 做三件事：
##   ① 从 `D:\逆向工程\export\cards\...\card\field\textures` 取卡面大图，
##      等比缩到宽 256 存进 `res://assets/sv/card_art/`（原图 ~2MB，缩图 ~100KB）；
##   ② 把卡图**按顺序分配给本项目卡表**里的随从 / 法术 / 护符（写入卡表 JSON 的 art_path）；
##   ③ 从 `D:\逆向工程\export\voice` 取若干语音存进 `res://assets/sv/voice/`，
##      并按约定重命名成 `<事件>.wav`，供 SoundFx 直接当真实音效播放。
##
## 素材版权属于 Cygames；本工具只在你本机把已有素材接进自己的项目，不随项目分发。

const SV_ROOT := "D:/逆向工程"
const CARD_TEX_DIR := "D:/逆向工程/export/cards/assets/_wizardresources2/resources/jpn/card/field/textures"
const VOICE_DIR := "D:/逆向工程/export/voice"
const ART_OUT := "res://assets/sv/card_art"
const VOICE_OUT := "res://assets/sv/voice"
## 卡图映射表：卡 id → 卡图路径（游戏读它做「一卡一图」，不靠哈希）
const ART_MAP_OUT := "res://data/card_art_map.json"
const ART_WIDTH := 256
const DEFAULT_ART_COUNT := 96
const DEFAULT_VOICE_COUNT := 12
## 语音事件绑定：按顺序取语音文件并改名成这些事件名（事件名同 SoundFx 的 _EVENTS）
const VOICE_EVENTS: Array[String] = ["play", "attack", "win", "lose", "button", "turn_start",
	"damage", "heal", "draw", "error", "death", "summon"]

var _cards = null
var _fails := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var art_count: int = int(args[0]) if args.size() > 0 else DEFAULT_ART_COUNT
	var voice_count: int = int(args[1]) if args.size() > 1 else DEFAULT_VOICE_COUNT
	print("[导入] 起点：%s" % SV_ROOT)
	if not DirAccess.dir_exists_absolute(CARD_TEX_DIR):
		push_error("找不到卡面目录：%s（请确认逆向工程已导出）" % CARD_TEX_DIR)
		quit(1)
		return
	_cards = root.get_node_or_null("CardDB")
	if _cards == null:
		push_error("CardDB 未加载")
		quit(1)
		return
	_cards.load_cards()          # --script 阶段自动加载的 _ready 尚未执行，这里显式载入
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ART_OUT))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VOICE_OUT))
	var arts := _import_card_art(art_count)
	var voices := _import_voice(voice_count)
	var assigned := _assign_art(arts)
	print("[导入] 卡图 %d 张 / 语音 %d 条 / 已分配给 %d 张卡" % [arts.size(), voices.size(), assigned])
	var ok: bool = _cards.save_cards()
	if not ok:
		# CardDB 的保存会先做配置校验；校验不过就直接写盘，保证卡图分配不丢
		print("[导入] CardDB.save_cards() 被校验拦下，改用直接写盘兜底：%s" % str(_cards.config_errors()))
		var arr := []
		for c in _cards.cards:
			arr.append(c.to_dict())
		var out := FileAccess.open("user://cards.json", FileAccess.WRITE)
		if out == null:
			push_error("卡表写入失败：user://cards.json")
			_fails += 1
		else:
			out.store_string(JSON.stringify(arr, "  "))
			out.close()
			ok = true
	print("[导入] 卡表已保存到 user://cards.json（卡图已分配：%s）" % ("成功" if ok else "失败"))
	# 同时写进项目的默认卡表：这样即使 user:// 存档被重置，卡图也不会丢
	var arr2 := []
	for c2 in _cards.cards:
		arr2.append(c2.to_dict())
	var f2 := FileAccess.open("res://data/default_cards.json", FileAccess.WRITE)
	if f2 != null:
		f2.store_string(JSON.stringify(arr2, "  "))
		f2.close()
		print("[导入] 默认卡表也已写入：res://data/default_cards.json")
	quit(0 if _fails == 0 else 1)


func _import_card_art(limit: int) -> Array[String]:
	var out: Array[String] = []
	var names := _list_files(CARD_TEX_DIR, ".png")
	names.sort()
	if names.is_empty():
		push_error("卡面目录里没有 png：%s" % CARD_TEX_DIR)
		return out
	# 均匀取样：不要只取文件名最靠前的一批（那基本集中在同一个卡包，风格单一）
	var step: int = maxi(1, names.size() / maxi(1, limit))
	var i := 0
	while out.size() < limit and i < names.size():
		var name: String = names[i]
		var src := "%s/%s" % [CARD_TEX_DIR, name]
		var target := "%s/%s" % [ART_OUT, name]
		if FileAccess.file_exists(target):
			out.append(target)          # 已经导入过：只登记，不重复缩放（省时间）
			i += step
			continue
		var img := Image.new()
		if img.load(src) != OK or img.get_width() < 64:
			i += step
			continue
		var h: int = int(round(float(img.get_height()) * ART_WIDTH / float(img.get_width())))
		img.resize(ART_WIDTH, h, Image.INTERPOLATE_LANCZOS)
		if img.save_png(target) != OK:
			_fails += 1
			i += step
			continue
		out.append(target)
		i += step
	print("[导入] 卡图：%d 张（缩到宽 %d，均匀取样）→ %s" % [out.size(), ART_WIDTH, ART_OUT])
	return out


func _import_voice(limit: int) -> Array[String]:
	var out: Array[String] = []
	var names := _list_files(VOICE_DIR, ".wav")
	names.sort()
	if names.is_empty():
		print("[导入] 语音：源目录没有 wav，跳过")
		return out
	# 事件音要**互相听得出区别**：不要连着取同一个角色的前几条（原先是 vo_01001_000_001…006），
	# 而是把整个语音库按等间隔取样，再逐个绑到一个事件名上。
	var seen := {}
	var picked: Array[String] = []
	var step: int = maxi(1, names.size() / maxi(1, limit))
	var i := 0
	while picked.size() < limit and i < names.size():
		var name: String = names[i]
		var chr := name.substr(0, name.find("_", 3))     # 角色前缀（vo_01001_000_001 → vo_01001）
		# 同一个角色最多取 2 条，尽量让每个事件来自不同角色的音色
		var used: int = int(seen.get(chr, 0))
		if used < 2:
			seen[chr] = used + 1
			picked.append(name)
		i += step
		if i >= names.size() and picked.size() < limit:
			i = picked.size()          # 兜底：间隔取不够就从头按顺序补齐
	for idx in range(mini(picked.size(), VOICE_EVENTS.size())):
		var event := VOICE_EVENTS[idx]
		var target := "%s/%s.wav" % [VOICE_OUT, event]
		var bytes := FileAccess.get_file_as_bytes("%s/%s" % [VOICE_DIR, picked[idx]])
		if bytes.is_empty():
			_fails += 1
			continue
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f == null:
			_fails += 1
			continue
		f.store_buffer(bytes)
		f.close()
		out.append(target)
	print("[导入] 语音：%d 条（按事件命名）→ %s" % [out.size(), VOICE_OUT])
	return out


## 把导入的卡图按顺序分配给卡表里"还没有卡图"的卡（随从 / 法术 / 护符 / 城邦都会分到）
func _assign_art(arts: Array[String]) -> int:
	if arts.is_empty():
		return 0
	var idx := 0
	var assigned := 0
	var mapping: Dictionary = {}
	for c in _cards.cards:
		if c.is_token:
			continue
		if idx >= arts.size():
			idx = 0                      # 图不够就循环复用，保证每张卡都有画
		c.art_path = arts[idx]
		mapping[c.id] = arts[idx]
		idx += 1
		assigned += 1
	# 写出「卡 id → 卡图」映射：游戏侧（ArtStore.default_card_art）读它，
	# 于是**即使 user:// 存档被重置**，每张卡也还是自己那一张图，不会退化成哈希随机。
	var f := FileAccess.open(ART_MAP_OUT, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(mapping, "  "))
		f.close()
		print("[导入] 卡图映射已写出：%s（%d 条）" % [ART_MAP_OUT, mapping.size()])
	else:
		push_warning("[导入] 卡图映射写出失败：%s" % ART_MAP_OUT)
	return assigned


func _list_files(dir: String, ext: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not d.current_is_dir() and name.to_lower().ends_with(ext):
			out.append(name)
		name = d.get_next()
	d.list_dir_end()
	return out
