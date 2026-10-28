extends Node
## 卡牌数据库（自动加载为 CardDB）。
## 负责卡牌数据的读取、保存（JSON）以及增 / 删 / 改 / 查。
## 管理员面板的所有修改都会写入 user://cards.json，下次启动自动生效。

signal database_changed

## 玩家可编辑的存档（管理员改动保存在这里）
const SAVE_PATH := "user://cards.json"
## 写入中转文件：先写它再改名，避免中断把存档截断
const TMP_PATH := "user://cards.json.tmp"
## 存档损坏时先备份到这里，再回退到内置卡表
const BAK_PATH := "user://cards.json.bak"
## 项目内置的初始卡表，仅当存档不存在时使用
const DEFAULT_PATH := "res://data/default_cards.json"
## 每张卡在牌库中放入的份数（默认值；真正的份数由「卡组规则」里的 max_copies 决定）
const COPIES_PER_CARD := 2

## ------------------------------ 卡组规则（管理员可改） ------------------------------
## 管理员面板里的「卡组规则（全局）」改的就是这三项，存在 RULES_PATH：
##   * `deck_min`   卡组最少张数（不够就轮转补足）
##   * `deck_max`   卡组最多张数（超出就从尾部裁掉）
##   * `max_copies` 同名卡最大携带数（默认 2，与旧行为一致）
## 默认值刻意选成「不会改变现状」：`max_copies = 2`、`30 ≤ 128 ≤ 200`，
## 所以老存档 / 老对局的牌库张数与改动前完全一样。
const RULES_PATH := "user://deck_rules.cfg"
const DEFAULT_DECK_MIN := 30
const DEFAULT_DECK_MAX := 200
const MAX_COPIES_LIMIT := 9
## 某一「种类」（card_type）在每张牌组里最多带几张：0 / 缺省 = 不限。
## 管理员在「卡组规则」面板按种类设（如「法术最多 30 张」）。
const TYPE_CAP_LIMIT := 60
## 稀有度 → 同名默认携带上限：只有传说强制 1，其余回落全局 max_copies。
const LEGENDARY_COPIES := 1

var deck_min: int = DEFAULT_DECK_MIN
var deck_max: int = DEFAULT_DECK_MAX
var max_copies: int = COPIES_PER_CARD
## card_type -> 该种类在每张牌组的总携带上限（0 = 不限）；管理员在「卡组规则」面板改
var type_caps: Dictionary = {}

## 项目内置的推荐搭配（只读，res 下）：组卡界面里「载入推荐搭配」的可选项
const PREBUILT_PATH := "res://data/preconstructed_decks.json"

## ------------------------------ 主战者职业 ------------------------------
## 职业是一张**管理员维护**的表：内置默认在 res://data/hero_classes.json，
## 管理员的增删改写在 user://hero_classes.json（与卡牌存档同一套路）。
## 每张卡通过 CardData.class_id 挂到某个职业上；玩家组牌时
## **只能用「本职业 + 中立」的卡**（见 card_allowed_for_class）。
const HERO_CLASS_DEFAULT_PATH := "res://data/hero_classes.json"
const HERO_CLASS_PATH := "user://hero_classes.json"
## 中立职业的显示名（CardData.NEUTRAL_CLASS 是它的 id）
const NEUTRAL_CLASS_NAME := "中立"
const HERO_CLASS_COLOR_FALLBACK := "#b0bec5"

## ------------------------------ 兵种 ------------------------------
## 兵种是**管理员维护**的表（影之诗的 士兵 / 指挥官 那类）：内置默认在 res://data/troops.json，
## 管理员的增删改写在 user://troops.json。每张卡通过 CardData.troop_id 挂一个兵种。
## 内置「中立」（CardData.NEUTRAL_TROOP）不可删除：没指定兵种 / 兵种被删掉的卡都归它，
## 所以任何卡都一定属于某个兵种（不存在「无兵种」）。
const TROOP_DEFAULT_PATH := "res://data/troops.json"
const TROOP_PATH := "user://troops.json"
const TROOP_COLOR_FALLBACK := "#90a4ae"

## ------------------------------ 卡包（扩展包） ------------------------------
## 卡包是**管理员维护**的表（影之诗的「カードパック / 拡張」）：内置默认在 res://data/card_packs.json，
## 管理员的增删改写在 user://card_packs.json。每张卡通过 CardData.pack_id 挂一个卡包。
## 内置「基础卡包」（DEFAULT_PACK）不可删除：没指定卡包 / 卡包被删掉的卡都归它，
## 所以老卡表在「指定」模式勾上基础包就能继续用。
## 「指定」模式只用管理员勾选的几个卡包；「无限」模式所有卡包都能用（见 Formats）。
const PACK_DEFAULT_PATH := "res://data/card_packs.json"
const PACK_PATH := "user://card_packs.json"
const PACK_COLOR_FALLBACK := "#90caf9"
const DEFAULT_PACK := "basic"
const DEFAULT_PACK_NAME := "基础卡包"

## ------------------------------ 对战模式（指定 / 无限） ------------------------------
## 两个模式的规则**互相独立**（见 Formats）：
##   * `rotation_rules` 指定模式自己的张数 / 同名 / 种类上限 + 可用卡包；
##   * `format_limits`  每个模式的限制卡表：card_id -> 允许张数（0 = 禁用，N = 最多 N 张）。
## 无限模式没有自己的张数规则：它就是全局 `deck_min/deck_max/max_copies/type_caps`
## （管理员面板「卡组规则」改的那份），只额外挂一张无限模式的限制卡表。
## 落盘仍在 RULES_PATH（user://deck_rules.cfg），段名：
##   [rotation] min/max/max_copies、[rotation.type_caps]、[rotation.packs]、
##   [rotation.limits]、[unlimited.limits]。
## 旧存档没有这些段 → 指定模式沿用全局规则 + 全部卡包（行为与改动前一致）。
const LIMIT_NONE := -1

## ------------------------------ 玩家自己组的卡组 ------------------------------
## 与只读的推荐搭配不同，这是玩家在组卡界面里自由组建、可以随时改的卡组，
## **每套绑定一个主战者职业**，存在 user://decks.json。
const DECKS_PATH := "user://decks.json"
## 一套卡组里城邦卡的合计上限（写在这里方便界面提示）
const DECK_NAME_MAX_LENGTH := 20

var cards: Array[CardData] = []
## 外部扩展包追加 / 覆盖的卡牌（`Mods` 载入时写这里；**不写进 user://cards.json**，
## 所以删掉扩展包这几张卡就干净地消失，不会留在存档里）。
var _mod_cards: Array[CardData] = []
## id -> CardData 索引：get_card() 在每次召唤 / 悬停详情里都会被调用，线性扫描太浪费
var _index: Dictionary = {}
## 推荐搭配定义列表：每项 {"id","name","color","desc","cards":[{"id","count"}]}
var prebuilt_decks: Array[Dictionary] = []
## 主战者职业列表：每项 {"id","name","color","desc"}
var hero_classes: Array[Dictionary] = []
var _class_index: Dictionary = {}
## 兵种列表：每项 {"id","name","color","desc"}（管理员在「兵种」面板维护）
var troops: Array[Dictionary] = []
var _troop_index: Dictionary = {}
## 卡包列表：每项 {"id","name","color","desc"}（管理员在「卡包」面板维护）
var packs: Array[Dictionary] = []
var _pack_index: Dictionary = {}
## 指定模式自己的规则：{"min","max","copies","type_caps":Dictionary,"packs":Array[String]}
var rotation_rules: Dictionary = {}
## 限制卡表：mode -> {card_id: 允许张数}（0 = 禁用；缺键 = 不限制）
var format_limits: Dictionary = {}
## 玩家的卡组列表：每项 {"id","name","class_id","cards":[{"id","count"}]}
var player_decks: Array[Dictionary] = []


func _ready() -> void:
	load_deck_rules()
	load_packs()                 # 先有卡包表，模式规则才知道「全部卡包」是什么
	load_format_rules()
	load_hero_classes()
	load_troops()
	load_prebuilt_decks()
	load_player_decks()
	load_cards()


# ------------------------------ 卡组规则：读写 / 校验 ------------------------------

## 读卡组规则（缺文件 / 缺键 / 越界都回落到默认值，保证一定能用）
func load_deck_rules() -> void:
	deck_min = DEFAULT_DECK_MIN
	deck_max = DEFAULT_DECK_MAX
	max_copies = COPIES_PER_CARD
	type_caps = {}
	var cfg := ConfigFile.new()
	var loaded := cfg.load(RULES_PATH) == OK
	if loaded:
		deck_min = int(cfg.get_value("deck", "min", DEFAULT_DECK_MIN))
		deck_max = int(cfg.get_value("deck", "max", DEFAULT_DECK_MAX))
		max_copies = int(cfg.get_value("deck", "max_copies", COPIES_PER_CARD))
	if not rules_valid(deck_min, deck_max, max_copies):
		push_warning("[CardDB] 卡组规则非法，已回落到默认值（min=%d max=%d copies=%d）" % [deck_min, deck_max, max_copies])
		deck_min = DEFAULT_DECK_MIN
		deck_max = DEFAULT_DECK_MAX
		max_copies = COPIES_PER_CARD
	if loaded:
		type_caps = _read_type_caps(cfg)


## 从 ConfigFile 读出「种类上限」表（缺省 / 越界都回落 0 = 不限）
static func _read_type_caps(cfg: ConfigFile) -> Dictionary:
	var out: Dictionary = {}
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		var v := clampi(int(cfg.get_value("type_caps", str(t), 0)), 0, TYPE_CAP_LIMIT)
		out[t] = v
	return out


## 这一组规则是否合法（非法一律不落盘、不生效）
func rules_valid(min_size: int, max_size: int, copies: int) -> bool:
	if min_size < 1 or max_size < 1:
		return false
	if min_size > max_size:
		return false
	if copies < 1 or copies > MAX_COPIES_LIMIT:
		return false
	return true


## 种类上限表是否合法（每个值都必须是 0…TYPE_CAP_LIMIT 的整数）
func type_caps_valid(caps: Dictionary) -> bool:
	for k in caps.keys():
		var v := int(caps.get(k, 0))
		if v < 0 or v > TYPE_CAP_LIMIT:
			return false
	return true


## 应用一组新规则：非法 → false（不改动、不写盘）；合法 → 立即保存并返回 true。
## 注意：读写都先 load 现有 cfg 再 save，避免把 type_caps 段清掉。
func set_deck_rules(min_size: int, max_size: int, copies: int) -> bool:
	if not rules_valid(min_size, max_size, copies):
		return false
	deck_min = min_size
	deck_max = max_size
	max_copies = copies
	var cfg := ConfigFile.new()
	cfg.load(RULES_PATH)        # 忽略失败：保留已存的 type_caps 等段
	cfg.set_value("deck", "min", deck_min)
	cfg.set_value("deck", "max", deck_max)
	cfg.set_value("deck", "max_copies", max_copies)
	var err := cfg.save(RULES_PATH)
	if err != OK:
		push_warning("[CardDB] 卡组规则写入失败：%s" % error_string(err))
		return false
	print("[CardDB] 卡组规则：最少 %d 张 / 最多 %d 张 / 同名卡最多 %d 张" % [deck_min, deck_max, max_copies])
	database_changed.emit()
	return true


## 应用「种类上限」表（card_type -> 上限，0 = 不限）。非法或写入失败 → false。
func set_type_caps(caps: Dictionary) -> bool:
	if not type_caps_valid(caps):
		return false
	type_caps = {}
	for k in caps.keys():
		type_caps[k] = clampi(int(caps.get(k, 0)), 0, TYPE_CAP_LIMIT)
	var cfg := ConfigFile.new()
	cfg.load(RULES_PATH)        # 保留 deck 段
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		cfg.set_value("type_caps", str(t), int(type_caps.get(t, 0)))
	var err := cfg.save(RULES_PATH)
	if err != OK:
		push_warning("[CardDB] 种类上限写入失败：%s" % error_string(err))
		return false
	print("[CardDB] 种类上限：%s" % _type_caps_text())
	database_changed.emit()
	return true


## 某一种类在每张牌组里最多带几张（0 = 不限）
func type_cap(t: int) -> int:
	return int(type_caps.get(t, 0))


## 这张卡在每张牌组里「同名」最多带几张：
##   卡牌单独设了 deck_limit（>0）→ 用它（优先级最高）；
##   否则传说 = 1，其余 = 全局 max_copies。
func max_copies_for(card: CardData) -> int:
	if card == null:
		return maxi(1, max_copies)
	if card.deck_limit > 0:
		return clampi(card.deck_limit, 1, MAX_COPIES_LIMIT)
	if card.rarity == CardData.Rarity.LEGENDARY:
		return LEGENDARY_COPIES
	return maxi(1, max_copies)


func _type_caps_text() -> String:
	var parts := PackedStringArray()
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		var v := int(type_caps.get(t, 0))
		if v > 0:
			parts.append("%s≤%d" % [CardData.TYPE_NAMES[t], v])
	return "、".join(parts) if not parts.is_empty() else "无（各类不限）"


## 模式版的种类上限说明（无限模式 = 全局那份）
func _type_caps_text_for(mode: String) -> String:
	if not Formats.is_rotation(mode):
		return _type_caps_text()
	var parts := PackedStringArray()
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		var v := mode_type_cap(mode, t)
		if v > 0:
			parts.append("%s≤%d" % [CardData.TYPE_NAMES[t], v])
	return "、".join(parts) if not parts.is_empty() else "无（各类不限）"


func reset_deck_rules() -> bool:
	return set_deck_rules(DEFAULT_DECK_MIN, DEFAULT_DECK_MAX, COPIES_PER_CARD)


## 卡组规则自检：把「凑不出合法卡组」的配置说出来（管理员面板直接显示）
func deck_rules_report() -> Array[String]:
	var out: Array[String] = []
	if not rules_valid(deck_min, deck_max, max_copies):
		out.append("卡组规则非法：最少 %d / 最多 %d / 同名 %d 张" % [deck_min, deck_max, max_copies])
		return out
	var pool := collectible_card_count()
	if pool <= 0:
		out.append("卡表里没有可收集的卡牌，无法组牌")
		return out
	var natural := natural_deck_size()
	if deck_min > natural and pool * max_copies < deck_min:
		out.append("卡池最多只能凑出 %d 张（%d 种 × 同名 %d 张），达不到最少 %d 张" % [
			pool * max_copies, pool, max_copies, deck_min])
	if deck_max < pool:
		out.append("最多 %d 张装不下 %d 种卡（每种至少 1 张），建议把上限提到 %d 以上" % [deck_max, pool, pool])
	if natural < deck_min:
		out.append("按当前配置只会生成 %d 张，少于最少 %d 张 → 会自动轮转补足" % [natural, deck_min])
	elif natural > deck_max:
		out.append("按当前配置会生成 %d 张，多于最多 %d 张 → 会自动裁掉多余副本" % [natural, deck_max])
	return out


## 可收集卡牌种类数（非衍生物；城邦也算，只是另有合计上限）
func collectible_card_count() -> int:
	var n := 0
	for c in cards:
		if not c.is_token:
			n += 1
	return n


## 不补足 / 不裁剪时自然生成的张数（= 每种 max_copies 张 + 城邦合计上限）
func natural_deck_size() -> int:
	var n := 0
	for c in cards:
		if c.is_token:
			continue
		n += max_copies_for(c)
	var city_total := 0
	for c in cards:
		if not c.is_token and c.is_city():
			city_total += max_copies_for(c)
	# 城邦在 build_deck 里被单独收口到 CITY_DECK_LIMIT，这里把多算的部分减掉
	n -= maxi(0, city_total - mini(city_total, CardData.CITY_DECK_LIMIT))
	return n


# ------------------------------ 对战模式规则（指定 / 无限） ------------------------------
#
# 两个模式各用各的规则（用户口径：不同模式的限制卡牌互不影响）：
#   * 无限 = 全局 deck_min / deck_max / max_copies / type_caps（老「卡组规则」面板那份）+ 无限限制卡表；
#   * 指定 = 它自己的一份张数 / 同名 / 种类上限 + 允许的卡包 + 指定限制卡表。
# 限制卡表格式：card_id -> 允许张数（0 = 禁用，N = 最多 N 张；没有这个键 = 不额外限制）。

## 读模式规则：没有存档段 → 指定模式沿用全局规则 + 全部卡包；限制卡表为空。
func load_format_rules() -> void:
	rotation_rules = _default_rotation_rules()
	format_limits = {Formats.ROTATION: {}, Formats.UNLIMITED: {}}
	var cfg := ConfigFile.new()
	if cfg.load(RULES_PATH) != OK:
		return
	if cfg.has_section("rotation"):
		var rmin := int(cfg.get_value("rotation", "min", rotation_rules["min"]))
		var rmax := int(cfg.get_value("rotation", "max", rotation_rules["max"]))
		var rcop := int(cfg.get_value("rotation", "max_copies", rotation_rules["copies"]))
		if rules_valid(rmin, rmax, rcop):
			rotation_rules["min"] = rmin
			rotation_rules["max"] = rmax
			rotation_rules["copies"] = rcop
		else:
			push_warning("[CardDB] 指定模式规则非法，已沿用全局规则")
		if cfg.has_section("rotation.type_caps"):
			var caps := _read_mode_type_caps(cfg, "rotation.type_caps")
			if type_caps_valid(caps):
				rotation_rules["type_caps"] = caps
		var pids := _split_ids(cfg.get_value("rotation", "packs", []))
		if not pids.is_empty():
			rotation_rules["packs"] = pids
	format_limits[Formats.ROTATION] = _read_limits(cfg, "rotation.limits")
	format_limits[Formats.UNLIMITED] = _read_limits(cfg, "unlimited.limits")


## 指定模式的默认规则 = 当前的全局规则 + 全部卡包
func _default_rotation_rules() -> Dictionary:
	return {
		"min": deck_min,
		"max": deck_max,
		"copies": max_copies,
		"type_caps": type_caps.duplicate(),
		"packs": pack_ids(),
	}


static func _read_mode_type_caps(cfg: ConfigFile, section: String) -> Dictionary:
	var out: Dictionary = {}
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		out[t] = clampi(int(cfg.get_value(section, str(t), 0)), 0, TYPE_CAP_LIMIT)
	return out


static func _read_limits(cfg: ConfigFile, section: String) -> Dictionary:
	var out: Dictionary = {}
	if not cfg.has_section(section):
		return out
	for key in cfg.get_section_keys(section):
		var cid := str(key).strip_edges()
		if cid == "":
			continue
		out[cid] = clampi(int(cfg.get_value(section, cid, LIMIT_NONE)), 0, MAX_COPIES_LIMIT)
	return out


## "a,b,c" / ["a","b"] → 去重后的 id 列表（手改存档两种写法都认）
static func _split_ids(raw: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(raw) == TYPE_STRING:
		for part in str(raw).split(",", false):
			var id := part.strip_edges()
			if id != "" and not out.has(id):
				out.append(id)
	elif typeof(raw) == TYPE_ARRAY or typeof(raw) == TYPE_PACKED_STRING_ARRAY:
		for item in raw:
			var id := str(item).strip_edges()
			if id != "" and not out.has(id):
				out.append(id)
	return out


## 模式名（「指定」/「无限」）
func mode_label(mode: String) -> String:
	return Formats.mode_label(Formats.normalized_mode(mode))


## 指定模式允许的卡包（无限模式 = 全部卡包）。
## 指定模式勾的卡包全都不存在时回落到「全部」：宁可宽一点，也不要让管理员手滑删包后无法开局。
func mode_allowed_packs(mode: String) -> Array[String]:
	var all := pack_ids()
	if not Formats.is_rotation(mode):
		return all
	var out: Array[String] = []
	for id in rotation_rules.get("packs", []):
		if has_pack(str(id)):
			out.append(str(id))
	return out if not out.is_empty() else all


func mode_deck_min(mode: String) -> int:
	if Formats.is_rotation(mode):
		return int(rotation_rules.get("min", deck_min))
	return deck_min


func mode_deck_max(mode: String) -> int:
	if Formats.is_rotation(mode):
		return int(rotation_rules.get("max", deck_max))
	return deck_max


func mode_max_copies(mode: String) -> int:
	if Formats.is_rotation(mode):
		return int(rotation_rules.get("copies", max_copies))
	return max_copies


func mode_type_cap(mode: String, t: int) -> int:
	if not Formats.is_rotation(mode):
		return type_cap(t)
	return int((rotation_rules.get("type_caps", {}) as Dictionary).get(t, 0))


## 某个模式下这张卡的「限制卡」上限：-1 = 没有限制；0 = 禁用；N = 最多 N 张。
## 传空串 / 未登记的模式 → -1（不按模式限制，兼容老调用）。
func mode_limit(mode: String, card_id: String) -> int:
	if mode == "" or card_id == "":
		return LIMIT_NONE
	var m := Formats.normalized_mode(mode)
	var limits: Dictionary = format_limits.get(m, {})
	if not limits.has(card_id):
		return LIMIT_NONE
	return clampi(int(limits[card_id]), 0, MAX_COPIES_LIMIT)


## 模式感知的同名携带上限：先看限制卡（0 = 禁用），再按单卡 deck_limit / 稀有度 / 模式同名上限。
func max_copies_for_mode(card: CardData, mode: String = "") -> int:
	if card == null:
		return maxi(1, mode_max_copies(mode))
	var lim := mode_limit(mode, card.id)
	if lim == 0:
		return 0
	var base: int
	if card.deck_limit > 0:
		base = clampi(card.deck_limit, 1, MAX_COPIES_LIMIT)
	elif card.rarity == CardData.Rarity.LEGENDARY:
		base = LEGENDARY_COPIES
	else:
		base = maxi(1, mode_max_copies(mode))
	return mini(base, lim) if lim > 0 else base


## 这张卡能不能进某个模式的卡组：卡包范围（指定）+ 限制卡（0 张 = 禁用）。
## `mode` 传空串 = 不按模式限制（旧行为）。
func mode_allows_card(mode: String, card: CardData) -> bool:
	if card == null or card.is_token:
		return false
	if mode == "":
		return true
	var m := Formats.normalized_mode(mode)
	if mode_limit(m, card.id) == 0:
		return false
	if Formats.is_rotation(m):
		return mode_allowed_packs(m).has(pack_of(card))
	return true


## 应用指定模式的规则。`packs` 至少要有一个**已登记**的卡包，否则拒绝（不改动、不写盘）。
func set_rotation_rules(min_size: int, max_size: int, copies: int,
		caps: Dictionary, pack_ids_raw: Array) -> bool:
	if not rules_valid(min_size, max_size, copies) or not type_caps_valid(caps):
		return false
	var pids: Array[String] = []
	for item in pack_ids_raw:
		var id := str(item).strip_edges()
		if has_pack(id) and not pids.has(id):
			pids.append(id)
	if pids.is_empty():
		return false
	var clean_caps: Dictionary = {}
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		clean_caps[t] = clampi(int(caps.get(t, 0)), 0, TYPE_CAP_LIMIT)
	rotation_rules = {
		"min": min_size, "max": max_size, "copies": copies,
		"type_caps": clean_caps, "packs": pids,
	}
	if not _save_format_rules():
		return false
	print("[CardDB] 指定模式规则：%d–%d 张 / 同名 %d · 卡包 %s" % [
		min_size, max_size, copies, ",".join(pids)])
	database_changed.emit()
	return true


## 设置某个模式的限制卡表（card_id -> 允许张数，0 = 禁用；不在表里 = 不限制）。
func set_mode_limits(mode: String, limits: Dictionary) -> bool:
	var m := Formats.normalized_mode(mode)
	var clean: Dictionary = {}
	for key in limits.keys():
		var cid := str(key).strip_edges()
		if cid == "":
			continue
		clean[cid] = clampi(int(limits[key]), 0, MAX_COPIES_LIMIT)
	format_limits[m] = clean
	if not _save_format_rules():
		return false
	print("[CardDB] %s模式限制卡：%d 张" % [mode_label(m), clean.size()])
	database_changed.emit()
	return true


## 把指定模式恢复成「沿用当前全局规则 + 全部卡包」，并清空它的限制卡表。
func reset_rotation_rules() -> bool:
	rotation_rules = _default_rotation_rules()
	format_limits[Formats.ROTATION] = {}
	if not _save_format_rules():
		return false
	database_changed.emit()
	return true


## 清空某个模式的限制卡表
func clear_mode_limits(mode: String) -> bool:
	return set_mode_limits(mode, {})


func _save_format_rules() -> bool:
	var cfg := ConfigFile.new()
	cfg.load(RULES_PATH)          # 保留 [deck] / [type_caps] 等老段
	cfg.set_value("rotation", "min", int(rotation_rules.get("min", deck_min)))
	cfg.set_value("rotation", "max", int(rotation_rules.get("max", deck_max)))
	cfg.set_value("rotation", "max_copies", int(rotation_rules.get("copies", max_copies)))
	var caps: Dictionary = rotation_rules.get("type_caps", {})
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		cfg.set_value("rotation.type_caps", str(t), int(caps.get(t, 0)))
	cfg.set_value("rotation", "packs", ",".join(mode_allowed_packs(Formats.ROTATION)))
	for m in [Formats.ROTATION, Formats.UNLIMITED]:
		var sec := "%s.limits" % m
		if cfg.has_section(sec):
			cfg.erase_section(sec)
		var limits: Dictionary = format_limits.get(m, {})
		for cid in limits.keys():
			cfg.set_value(sec, str(cid), int(limits[cid]))
	var err := cfg.save(RULES_PATH)
	if err != OK:
		push_warning("[CardDB] 模式规则写入失败：%s" % error_string(err))
		return false
	return true


## 某种模式的配置自检（管理员面板直接显示）
func format_report(mode: String) -> Array[String]:
	var out: Array[String] = []
	var m := Formats.normalized_mode(mode)
	if Formats.is_rotation(m):
		var ids := mode_allowed_packs(m)
		if ids.is_empty():
			out.append("指定模式没有任何可用卡包")
		var pool := 0
		for c in cards:
			if not c.is_token and mode_allows_card(m, c):
				pool += 1
		if pool <= 0:
			out.append("指定模式勾选的卡包里没有任何可收集卡牌")
		else:
			var cap := int(rotation_rules.get("copies", max_copies))
			if int(rotation_rules.get("min", deck_min)) > pool * maxi(1, cap):
				out.append("指定模式的卡池最多凑出 %d 张（%d 种 × %d 张），达不到最少 %d 张" % [
					pool * maxi(1, cap), pool, cap, int(rotation_rules.get("min", deck_min))])
		var missing := 0
		for id in rotation_rules.get("packs", []):
			if not has_pack(str(id)):
				missing += 1
		if missing > 0:
			out.append("指定模式勾选了 %d 个已不存在的卡包（读取时已忽略）" % missing)
	for cid in (format_limits.get(m, {}) as Dictionary).keys():
		if not has_id(str(cid)):
			out.append("限制卡 %s 在卡表里不存在（已忽略）" % str(cid))
	return out


# ------------------------------ 持久化 ------------------------------

func load_cards() -> void:
	cards.clear()
	if _load_from(SAVE_PATH):
		_finish_load()
		return

	# 主存档缺失 / 损坏：先试上次改名失败时留下的 .tmp（那是最后一份完整数据）
	if _load_from(TMP_PATH):
		push_warning("[CardDB] 主存档不可用，已从 %s 恢复" % TMP_PATH)
		_warn_config_errors()
		save_cards()          # 内部会 emit database_changed
		return

	if FileAccess.file_exists(SAVE_PATH):
		push_warning("[CardDB] 卡牌存档无法解析：%s（已备份为 %s，回退到内置卡表）" % [SAVE_PATH, BAK_PATH])
		_preserve_save_as_backup(SAVE_PATH)
	elif FileAccess.file_exists(TMP_PATH):
		push_warning("[CardDB] 中转存档也不可解析：%s" % TMP_PATH)

	cards = _builtin_cards()
	_rebuild_index()
	apply_default_art()          # 旧存档没有 art_path 时，启动时按 id 分配卡图
	_apply_mod_cards()
	if cards.is_empty():
		push_error("[CardDB] 内置默认卡表不可用：%s" % DEFAULT_PATH)
		database_changed.emit()
		return
	print("[CardDB] 已回退到内置默认卡表（%d 张）" % cards.size())
	_warn_config_errors()
	save_cards()              # 立刻修复 / 生成存档


## 载入后校正卡图（与存档无关：旧存档也能看到正确的卡图）：
##   * 没有卡图的卡 → 按约定目录 / 卡图映射表 / 散列兜底补一张；
##   * **自动分配过逆向素材、但映射表里有专属图**的卡 → 换成映射表里那一张
##     （早期导入只循环用了 24 张图，旧存档里一批卡共用同一张；这里把它们重新钉到各自的图上）。
## 管理员 / 玩家自己挑的图（不在 `assets/sv/card_art/` 里的路径）**不会被覆盖**。
func apply_default_art() -> int:
	var mapped := ArtStore.card_art_map()
	var n := 0
	for c in cards:
		var map_path := str(mapped.get(c.id, ""))
		if c.art_path == "":
			var art := ArtStore.default_card_art(c.id)
			if art != "":
				c.art_path = art
				n += 1
		elif map_path != "" and c.art_path != map_path \
				and c.art_path.begins_with(ArtStore.SV_CARD_ART_DIR) \
				and FileAccess.file_exists(map_path):
			c.art_path = map_path
			n += 1
	return n


## ------------------------------ 外部扩展包卡牌（Mods 用） ------------------------------
## 扩展包（`scripts/ModLoader.gd`）读进来的卡牌放这里：同 id 覆盖内置 / 存档里的那张，
## 新 id 追加。它们**不写进存档**，也**不参与 save_cards()**，所以卸载扩展包即消失。
func set_mod_cards(list: Array) -> int:
	_mod_cards.clear()
	for item in list:
		if item is CardData:
			_mod_cards.append(item)
		elif typeof(item) == TYPE_DICTIONARY:
			_mod_cards.append(CardData.from_dict(item))
	_apply_mod_cards()
	return _mod_cards.size()


func mod_card_count() -> int:
	return _mod_cards.size()


## 这张卡是不是扩展包带进来的（扩展包卡牌不写进存档）
func _is_mod_card(c: CardData) -> bool:
	if c == null:
		return false
	for mc in _mod_cards:
		if mc != null and mc.id == c.id:
			return true
	return false


## 公开的自检入口：扩展包装载完之后由 `Mods` 再喊一次，
## 这样「扩展包自己登记的效果 / 关键字」不会被当成未知配置误报。
func warn_config_errors() -> void:
	_warn_config_errors()


## 把扩展包卡牌并入当前卡表（覆盖同 id、追加新 id）并重建索引。
## 每次从磁盘重新载入卡表后都会调一次，所以扩展包卡牌不会因为存档刷新而丢失。
func _apply_mod_cards() -> void:
	if _mod_cards.is_empty():
		return
	for mc in _mod_cards:
		if mc == null or mc.id == "":
			continue
		if mc.art_path == "":
			var art := ArtStore.default_card_art(mc.id)
			if art != "":
				mc.art_path = art      # 扩展包卡牌也照常拿到兜底卡图
		var replaced := false
		for i in cards.size():
			if cards[i].id == mc.id:
				cards[i] = mc
				replaced = true
				break
		if not replaced:
			cards.append(mc)
	_rebuild_index()


func _finish_load() -> void:
	_warn_config_errors()
	database_changed.emit()


## 成功读取并建立索引后返回 true
func _load_from(path: String) -> bool:
	var parsed: Variant = _read_json_array(path)
	if parsed == null:
		return false
	var loaded: Array[CardData] = []
	for item in parsed:
		if typeof(item) == TYPE_DICTIONARY:
			loaded.append(CardData.from_dict(item))
	if loaded.is_empty():
		return false
	cards = loaded
	_rebuild_index()
	apply_default_art()          # 旧存档没有 art_path 时，启动时按 id 分配卡图
	_apply_mod_cards()
	print("[CardDB] 已从 %s 载入 %d 张卡牌" % [path, cards.size()])
	return true


func _read_json_array(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if typeof(parsed) == TYPE_ARRAY else null


## 把（损坏的 / 即将被覆盖的）存档另存为 .bak，保证原始数据不丢
func _preserve_save_as_backup(path: String) -> void:
	var src_abs := ProjectSettings.globalize_path(path)
	var bak_abs := ProjectSettings.globalize_path(BAK_PATH)
	if not FileAccess.file_exists(path):
		return
	if FileAccess.file_exists(BAK_PATH):
		DirAccess.remove_absolute(bak_abs)
	DirAccess.rename_absolute(src_abs, bak_abs)


func _rebuild_index() -> void:
	_index.clear()
	for c in cards:
		if c != null and c.id != "":
			_index[c.id] = c


func save_cards() -> bool:
	var arr: Array = []
	for c in cards:
		if _is_mod_card(c):
			continue          # 扩展包卡牌不落盘：卸载扩展包它们就该干净地消失
		arr.append(c.to_dict())
	var text := JSON.stringify(arr, "\t")

	# 先写临时文件再改名：FileAccess.WRITE 会立刻截断目标文件，
	# 万一写入过程中崩溃，旧存档就被毁成空文件了。
	var file := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[CardDB] 无法写入卡牌数据：%s" % TMP_PATH)
		return false
	file.store_string(text)
	file.close()

	var dst_abs := ProjectSettings.globalize_path(SAVE_PATH)
	var tmp_abs := ProjectSettings.globalize_path(TMP_PATH)
	# 先直接覆盖改名（大多数平台可以）；不行再删旧文件重试，尽量不动原存档
	var err := DirAccess.rename_absolute(tmp_abs, dst_abs)
	if err != OK and FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(dst_abs)
		err = DirAccess.rename_absolute(tmp_abs, dst_abs)
	if err != OK:
		push_error("[CardDB] 无法替换卡牌存档 %s（错误码 %d），数据仍保留在 %s" % [
			SAVE_PATH, err, TMP_PATH])
		return false

	_rebuild_index()
	apply_default_art()          # 旧存档没有 art_path 时，启动时按 id 分配卡图
	print("[CardDB] 已保存 %d 张卡牌到 %s" % [cards.size(), SAVE_PATH])
	database_changed.emit()
	return true


## 卡表配置自检：把“能加载但打出来不对”的配置暴露出来（管理员面板 / 卡表 JSON 都可能配错）
##
## 覆盖三类：
##   * 旧字段（`effect_id` / `deathrattle_id` / `token_id`）——只有**没有效果链**的卡才走这套，
##     避免与链检查重复报同一条；
##   * **效果链**（`effects` / `deathrattle_effects`，管理员按顺序整合的多条效果）；
##   * **主动技能**（`skill`：名称 / 费用 / 目标 / 每回合一次 / 技能效果链）。
func config_errors() -> Array[String]:
	var out: Array[String] = []
	for c in cards:
		# ---- 旧字段（效果链为空时才是这张卡的唯一来源）----
		if c.effects.is_empty():
			if c.effect_id != "" and not CardEffects.has(c.effect_id):
				out.append("%s「%s」：未知战吼 / 法术效果 %s" % [c.id, c.card_name, c.effect_id])
			out.append_array(_target_errors(c, c.effect_id, "战吼 / 法术"))
			if CardEffects.needs_token(c.effect_id) and c.token_id == "":
				out.append("%s「%s」：召唤类效果没有配置衍生物 ID" % [c.id, c.card_name])
		else:
			out.append_array(_chain_errors(c, c.effects, "战吼 / 法术"))
		if c.deathrattle_effects.is_empty():
			if c.deathrattle_id != "" and not CardEffects.has(c.deathrattle_id):
				out.append("%s「%s」：未知亡语效果 %s" % [c.id, c.card_name, c.deathrattle_id])
			if CardEffects.needs_token(c.deathrattle_id) and c.token_id == "":
				out.append("%s「%s」：召唤类效果没有配置衍生物 ID" % [c.id, c.card_name])
		else:
			# 亡语的目标由 GameManager 自动推导，和 c.target 无关，所以这里只查 ID / 衍生物
			out.append_array(_chain_errors(c, c.deathrattle_effects, "亡语", false))
		if c.token_id != "" and get_card(c.token_id) == null:
			out.append("%s「%s」：衍生物 %s 不存在" % [c.id, c.card_name, c.token_id])
		# ---- 主动技能 ----
		out.append_array(_skill_errors(c))
		# ---- 瞬念召唤 ----
		out.append_array(_invocation_errors(c))
		# ---- 机制（关键字）：没在 Mechanics 注册的 ID 永远不会生效，这里报出来 ----
		for k in c.keywords:
			if not Mechanics.has(int(k)):
				out.append("%s「%s」：未知的机制 / 关键字 %d（该词条不会生效）" % [
					c.id, c.card_name, int(k)])
		# ---- 兵种：没登记的 id 不会出现在检索 / 条件里，等于挂了张空标签 ----
		if c.troop_id != "" and not has_troop(c.troop_id):
			out.append("%s「%s」：兵种 %s 未登记（先到「兵种」面板创建它）" % [
				c.id, c.card_name, c.troop_id])
		# ---- 主战者效果：结构（赋予时机 / 监听事件 / 持续回合）+ 效果链都要能落地 ----
		for le in c.leader_effects:
			var spec := LeaderEffects.normalized(le)
			for msg in LeaderEffects.errors(spec):
				out.append("%s「%s」：主战者效果不合规（%s）" % [c.id, c.card_name, msg])
			out.append_array(_chain_errors(c, spec.get("effects", []), "主战者效果"))
		# ---- 触发效果：时机必须已登记 + 每条的效果链都要能落地 ----
		# 目标与亡语同一口径（触发时由引擎自动推导），所以只查效果 ID / 衍生物 / 条件。
		for tr in c.triggers:
			var tspec := CardTriggers.normalized(tr)
			var on := str(tspec.get("on", ""))
			# 法术只有「瞬念召唤 / 被召唤」两个词条大类（被召唤 = 进入手牌）
			if not CardTriggers.event_allowed_for_type(c.card_type, on):
				out.append("%s「%s」：法术卡只能配「瞬念召唤 / 被召唤」两个词条大类（当前 %s）" % [
					c.id, c.card_name, CardTriggers.event_label(on)])
			for msg in CardTriggers.errors(tspec):
				out.append("%s「%s」：触发效果不合规（%s）" % [c.id, c.card_name, msg])
			out.append_array(_chain_errors(c, tspec.get("effects", []), "触发效果", false))
		# ---- 融合：法术不能融合；材料费用区间 / 化身目标 / 条件都要能落地 ----
		if c.has_fusion():
			if c.card_type == CardData.CardType.SPELL:
				out.append("%s「%s」：法术卡不能配融合（法术只有「瞬念召唤 / 被召唤」）" % [c.id, c.card_name])
			var ff := c.fusion_filter()
			if int(ff.get("cost_min", 0)) > int(ff.get("cost_max", 99)):
				out.append("%s「%s」：融合材料的最低费高于最高费" % [c.id, c.card_name])
			var freq := c.fusion_require()
			if not EffectConditions.is_empty(freq):
				for msg in EffectConditions.errors(freq):
					out.append("%s「%s」：融合条件不合规（%s）" % [c.id, c.card_name, msg])
			var ftr := c.fusion_transform()
			if ftr != "":
				var ftpl := get_card(ftr)
				if ftpl == null:
					out.append("%s「%s」：融合后化身的卡 %s 不存在" % [c.id, c.card_name, ftr])
				elif not ftpl.is_minion():
					out.append("%s「%s」：融合后只能化身成随从（%s 不是随从）" % [c.id, c.card_name, ftr])
			out.append_array(_chain_errors(c, c.fusion_effects(), "融合时发动", false))
			out.append_array(_chain_errors(c, c.fusion_gain(), "融合获得", false))
		# ---- 稀有度 / 单卡携带上限：越界值会被静默夹回，这里如实报出来 ----
		if c.rarity < 0 or c.rarity >= CardData.RARITY_NAMES.size():
			out.append("%s「%s」：稀有度 %d 越界（有效 0–%d）" % [
				c.id, c.card_name, c.rarity, CardData.RARITY_NAMES.size() - 1])
		if c.deck_limit > MAX_COPIES_LIMIT:
			out.append("%s「%s」：单卡携带上限 %d 超过上限（有效 0–%d，0 = 按稀有度）" % [
				c.id, c.card_name, c.deck_limit, MAX_COPIES_LIMIT])
	return out


## 瞬念召唤的配置检查：量 / 比较符必须已登记；只有随从 / 护符 / 城邦配它才有意义。
## 注：量或比较符**未登记**时引擎本来就把它当成「没配」（CardData.has_invocation() 返回 false，
## 不会判定），这里报出来是让管理员知道「配了却不起作用」的那一种。
func _invocation_errors(c: CardData) -> Array[String]:
	var out: Array[String] = []
	var map: Dictionary = c.invocation
	if map.is_empty():
		return out
	if c.is_token:
		out.append("%s「%s」：衍生物配了瞬念召唤也不会进玩家牌库" % [c.id, c.card_name])
		return out
	if not bool(map.get("enabled", false)):
		return out
	var mid := str(map.get("metric", "")).strip_edges()
	if mid == "":
		out.append("%s「%s」：瞬念召唤没有配置触发条件（没有要读的量）" % [c.id, c.card_name])
		return out
	if not InvokeConditions.has_metric(mid):
		out.append("%s「%s」：未知的瞬念召唤触发条件 %s（可用：%s）" % [
			c.id, c.card_name, mid, "、".join(InvokeConditions.metrics())])
		return out
	var op := str(map.get("op", "")).strip_edges()
	if not InvokeConditions.has_op(op):
		out.append("%s「%s」：瞬念召唤的比较符 %s 无效（可用：%s）" % [
			c.id, c.card_name, op, " / ".join(InvokeConditions.OPS)])
	# 兵种类条件：兵种必须是登记过的（"" = 中立，永远合法）
	var inv_troop := str(map.get("troop", "")).strip_edges()
	if InvokeConditions.metric_wants_troop(mid) and inv_troop != "" and not has_troop(inv_troop):
		out.append("%s「%s」：瞬念召唤的兵种条件用了未登记的兵种 %s" % [
			c.id, c.card_name, inv_troop])
	# 法术也可以配瞬念召唤：在牌库 / 墓地直接发动或进入手牌（不会上场），不需要额外限制
	var timing := int(map.get("timing", 0))
	if timing < 0 or timing >= InvokeConditions.TIME_NAMES.size():
		out.append("%s「%s」：瞬念召唤的触发时机 %d 越界" % [c.id, c.card_name, timing])
	# 基础机制（去向）：制作时必选、不能为空，越界值会被静默当成「留在场上」，这里报出来
	var dest := int(map.get("destination", CardData.InvokeDest.KEEP))
	if dest < 0 or dest >= CardData.INVOKE_DEST_NAMES.size():
		out.append("%s「%s」：瞬念召唤的基础机制（去向）%d 越界（有效 0–%d）" % [
			c.id, c.card_name, dest, CardData.INVOKE_DEST_NAMES.size() - 1])
	# 瞬念召唤效果（可留空）：未知效果 / 召唤类缺衍生物 ID（目标由引擎自动推导，跳过目标一致性）
	out.append_array(_chain_errors(c, c.invoke_effect_chain(), "瞬念召唤效果", false))
	return out


## 一条效果链的配置检查：未知 ID / 目标错配 / 召唤类缺衍生物 ID
## `check_target` = false 时跳过目标一致性（亡语的目标由引擎自动推导）
func _chain_errors(c: CardData, chain: Array, label: String, check_target: bool = true) -> Array[String]:
	var out: Array[String] = []
	var effective := 0
	for i in chain.size():
		var e: Dictionary = chain[i]
		var id := str(e.get("id", ""))
		if id == "" or id == CardEffects.NONE:
			continue
		effective += 1
		var where := "%s第 %d 条" % [label, i + 1]
		if not CardEffects.has(id):
			out.append("%s「%s」：%s 是未知效果 %s" % [c.id, c.card_name, where, id])
			continue
		# 这一条的条件（可选）：结构不合规 / 兵种没登记 → 报出来
		var cond := EffectConditions.normalized(e.get("cond", {}))
		for msg in EffectConditions.errors(cond):
			out.append("%s「%s」：%s 的条件不合规（%s）" % [c.id, c.card_name, where, msg])
		var cond_troop := str(cond.get("troop", ""))
		if cond_troop != "" and not has_troop(cond_troop):
			out.append("%s「%s」：%s 的条件用了未登记的兵种 %s" % [
				c.id, c.card_name, where, cond_troop])
		var token := str(e.get("token", "")).strip_edges()
		if CardEffects.needs_token(id) and token == "":
			out.append("%s「%s」：%s「%s」需要衍生物 ID" % [c.id, c.card_name, where, CardEffects.display_name(id)])
		# 随机能力：token 字段存的是能力池 ID，池子必须已登记（改名 / 删除后自检会报出来）
		if CardEffects.needs_pool(id):
			if token == "":
				out.append("%s「%s」：%s「%s」需要选择随机能力池" % [
					c.id, c.card_name, where, CardEffects.display_name(id)])
			elif not AbilityPools.has(token):
				out.append("%s「%s」：%s 的随机能力池「%s」不存在（见「随机能力池」面板）" % [
					c.id, c.card_name, where, token])
		# 赋予技能 / 能力：token 是来源卡牌 ID；来源不存在 / 没带对应内容 → 配了也不生效
		if CardEffects.needs_card_ref(id):
			if token == "":
				out.append("%s「%s」：%s「%s」需要选择来源卡牌" % [
					c.id, c.card_name, where, CardEffects.display_name(id)])
			else:
				var src := get_card(token)
				if src == null:
					out.append("%s「%s」：%s 的来源卡牌「%s」不存在" % [
						c.id, c.card_name, where, token])
				elif id == CardEffects.GRANT_SKILL and not src.has_skill():
					out.append("%s「%s」：%s 的来源卡牌「%s」没有主动技能" % [
						c.id, c.card_name, where, src.card_name])
				elif id == CardEffects.GRANT_ABILITY and not src.has_triggers():
					out.append("%s「%s」：%s 的来源卡牌「%s」没有触发能力" % [
						c.id, c.card_name, where, src.card_name])
		# 随机获得技能 / 能力 / 效果：token 是来源范围，范围必须能落地
		if CardEffects.needs_scope(id):
			var scope_err := CardEffects.scope_error(token)
			if scope_err != "":
				out.append("%s「%s」：%s「%s」%s" % [
					c.id, c.card_name, where, CardEffects.display_name(id), scope_err])
		# 牌库 / 手牌改造：token 是「区域|目标」，参数必须能落地
		if CardEffects.needs_spec(id):
			var spec_err := CardEffects.spec_error(id, token)
			if spec_err != "":
				out.append("%s「%s」：%s「%s」%s" % [
					c.id, c.card_name, where, CardEffects.display_name(id), spec_err])
		if not check_target:
			continue
		var declared: int = CardEffects.default_target(id)
		var got: int = int(e.get("target", -1))
		if got < 0:
			got = declared
		if declared != CardData.Targeting.NONE and got == CardData.Targeting.NONE:
			out.append("%s「%s」：%s「%s」需要选择目标，但这一条配成了“不需要目标”" % [
				c.id, c.card_name, where, CardEffects.display_name(id)])
		elif declared == CardData.Targeting.NONE and got != CardData.Targeting.NONE:
			out.append("%s「%s」：%s「%s」不需要目标，但这一条配了目标类型，该牌会因缺少目标而打不出" % [
				c.id, c.card_name, where, CardEffects.display_name(id)])
	if effective == 0 and chain.size() > 0:
		out.append("%s「%s」：%s没有任何有效效果（链里全是「无效果」）" % [c.id, c.card_name, label])
	return out


## 主动技能的配置检查：必须有非空效果链；费用 / 目标 / 链内容都要合法
func _skill_errors(c: CardData) -> Array[String]:
	var out: Array[String] = []
	if c.skill.is_empty():
		return out
	var map: Array = c.skill.get("effects", [])
	if c.skill_chain().is_empty():
		out.append("%s「%s」：启用了技能「%s」却没有配置任何技能效果" % [
			c.id, c.card_name, c.skill_name()])
	if int(c.skill.get("cost", 0)) < 0:
		out.append("%s「%s」：技能费用不能为负" % [c.id, c.card_name])
	var declared: int = c.skill_target()
	if declared < 0 or declared >= CardData.TARGET_NAMES.size():
		out.append("%s「%s」：技能目标类型越界（%d）" % [c.id, c.card_name, declared])
	out.append_array(_chain_errors(c, map, "技能"))
	# 技能声明的目标必须与链里第一条需要选目标的效果一致
	var first_need := -1
	for e in c.skill_chain():
		var id := str(e.get("id", ""))
		if id == "" or id == CardEffects.NONE:
			continue
		var d: int = CardEffects.default_target(id)
		if d != CardData.Targeting.NONE and not CardEffects.is_aoe(id):
			first_need = int(e.get("target", d))
			break
	if first_need >= 0 and declared != first_need:
		out.append("%s「%s」：技能目标（%s）与技能链里需要选目标的那一条（%s）不一致" % [
			c.id, c.card_name, CardData.TARGET_NAMES.get(declared, str(declared)),
			CardData.TARGET_NAMES.get(first_need, str(first_need))])
	return out


func _target_errors(c: CardData, effect_id: String, label: String) -> Array[String]:
	var out: Array[String] = []
	if effect_id == "" or effect_id == CardEffects.NONE or not CardEffects.has(effect_id):
		return out
	if CardEffects.is_aoe(effect_id):
		return out
	var declared: int = CardEffects.default_target(effect_id)
	if declared != CardData.Targeting.NONE and c.target == CardData.Targeting.NONE:
		# 单体效果必须配一个需要选目标的 target，否则结算时会被当成“以自己为目标”
		out.append("%s「%s」：%s「%s」需要选择目标，但卡表里配成了“不需要目标”" % [
			c.id, c.card_name, label, CardEffects.display_name(effect_id)])
	elif declared == CardData.Targeting.NONE and c.needs_target():
		# 反向错配：效果自己决定目标（如“对敌方英雄造成伤害”“获得法力”），
		# 卡表却要求选目标 → 这张牌必须有合法目标才能打出，可能根本打不出来
		out.append("%s「%s」：%s「%s」不需要目标，但卡表要求选「%s」，该牌会因缺少目标而无法打出" % [
			c.id, c.card_name, label, CardEffects.display_name(effect_id), c.target_name()])
	return out


func _warn_config_errors() -> void:
	# 扩展包还没装载完时先别报：扩展包会在装载后自己登记效果 / 机制，
	# 早报会把「扩展包卡牌用的效果」误判成未知效果（噪音）。装载完由 `Mods` 喊一次。
	var mods := get_node_or_null("/root/Mods")
	if mods != null and not bool(mods.get("ready_done")):
		return
	var errs := config_errors()
	for e in errs:
		push_warning("[CardDB] 卡表配置：" + e)


## 丢弃管理员改动，恢复为初始卡表。
## 注意先确认内置卡表可读，再备份当前卡表——否则一旦内置卡表缺失，
## 就会把用户卡表删掉后又写入空表（整个卡表丢失）。
func reset_to_default() -> bool:
	var builtin := _builtin_cards()
	if builtin.is_empty():
		push_error("[CardDB] 内置默认卡表不可用（%s），已取消恢复默认" % DEFAULT_PATH)
		return false
	_preserve_save_as_backup(SAVE_PATH)
	cards = builtin
	_rebuild_index()
	apply_default_art()          # 旧存档没有 art_path 时，启动时按 id 分配卡图
	return save_cards()


func _builtin_cards() -> Array[CardData]:
	var list: Array[CardData] = []
	var file := FileAccess.open(DEFAULT_PATH, FileAccess.READ)
	if file == null:
		return list
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) == TYPE_ARRAY:
		for item in parsed:
			if typeof(item) == TYPE_DICTIONARY:
				list.append(CardData.from_dict(item))
	return list


# ------------------------------ 增删改查 ------------------------------

func get_all() -> Array[CardData]:
	return cards


func get_card(id: String) -> CardData:
	return _index.get(id, null)


func has_id(id: String) -> bool:
	return _index.has(id)


# ------------------------------ 卡牌检索 ------------------------------
#
# 组卡界面与管理员列表**共用这里的一套口径**，避免两边搜出不一样的结果：
#   * `query` 命中卡名 / 描述 / 战吼文本 / 亡语文本 / 关键字名 / **兵种名**（兵种词条可被检索）；
#   * `type_filter` = -1 表示全部种类；`troop_filter` = "" 表示全部兵种。

## 一张卡是否命中检索条件
func card_matches(c: CardData, query: String, type_filter: int = -1, troop_filter: String = "") -> bool:
	if c == null:
		return false
	if type_filter >= 0 and int(c.card_type) != type_filter:
		return false
	if troop_filter != "" and troop_of(c) != troop_filter:
		return false
	var q := query.strip_edges().to_lower()
	if q == "":
		return true
	if q in c.card_name.to_lower():
		return true
	if q in c.description.to_lower():
		return true
	if q in c.effect_text().to_lower():
		return true
	if q in c.deathrattle_text().to_lower():
		return true
	for k in c.keywords:
		if q in str(CardData.KEYWORD_NAMES.get(int(k), "")).to_lower():
			return true
	var tname := troop_name(troop_of(c)).to_lower()
	return tname != "" and q in tname


## 按检索条件筛出卡牌（顺序 = 卡表顺序）
func search_cards(query: String, type_filter: int = -1, troop_filter: String = "") -> Array[CardData]:
	var out: Array[CardData] = []
	for c in cards:
		if card_matches(c, query, type_filter, troop_filter):
			out.append(c)
	return out


func add_card(data: CardData) -> bool:
	if data.id == "" or has_id(data.id):
		data.id = _next_id()
	cards.append(data)
	_index[data.id] = data
	return save_cards()


func update_card(id: String, new_data: CardData) -> bool:
	var i := cards.find(_index.get(id, null))
	if i < 0:
		return false
	new_data.id = id
	cards[i] = new_data
	_index[id] = new_data
	return save_cards()


## 删除卡牌（管理员“删减卡牌”调用此方法）
func remove_card(id: String) -> bool:
	var i := cards.find(_index.get(id, null))
	if i < 0:
		return false
	cards.remove_at(i)
	_index.erase(id)
	return save_cards()


## 重建 id -> 卡牌 的索引（批量改动 cards 之后调用；日常增删改会自动维护索引）
func rebuild_index() -> void:
	_index.clear()
	for c in cards:
		_index[c.id] = c


## 按当前卡表 + 卡组规则生成一副牌库（每种非衍生物卡牌 `max_copies` 张，深拷贝）。
## 城邦卡例外：**整副牌组合计最多 CardData.CITY_DECK_LIMIT 张**（轮流取，保证能带上不同的城邦）。
## 之后按管理员的规则收口：不足 `deck_min` → 轮转补足；超过 `deck_max` → 从尾部裁掉。
## 全程确定性：同样的卡表 + 同样的规则 → 同样的牌库顺序。
## `copies` 省略（-1）时用管理员配置的 `max_copies`；显式传值时按传的来（老调用点兼容）。
## `restrict_class` 传职业 id 时只收「该职业 + 中立」的卡（敌方 AI 随机主战者用它）；
## 传空串 = 不限职业（旧行为）。
## 随机 / 自动配一套牌。
## `mode` 传 Formats 的模式 id → 按该模式的卡包范围、限制卡表与张数规则配；
## 传空串 → 老口径（不按模式限制，用全局规则），兼容测试与老调用。
func build_deck(copies: int = -1, restrict_class: String = "",
		mode: String = "") -> Array[CardData]:
	var deck: Array[CardData] = []
	var cities: Array[CardData] = []
	var pool: Array[CardData] = []
	for c in cards:
		if c.is_token:
			continue
		if not card_allowed_for_class(c, restrict_class):
			continue
		if mode != "" and not mode_allows_card(mode, c):
			continue
		pool.append(c)
		if c.is_city():
			cities.append(c)
			continue
		# 每张卡各自的上限：限制卡（0 = 禁用）/ 传说=1 / 单卡 deck_limit / 模式同名上限
		# （显式传 copies > 0 时按传的来，兼容老调用）
		var per_card: int = maxi(1, copies if copies > 0 else max_copies_for_mode(c, mode))
		for _j in per_card:
			deck.append(c.clone())
	var min_size := mode_deck_min(mode)
	var max_size := mode_deck_max(mode)
	var slots: int = CardData.CITY_DECK_LIMIT
	var per_card: int = maxi(1, mode_max_copies(mode))   # 城邦轮转：每轮每个城邦最多补到这么多张
	var round_i := 0
	while slots > 0 and round_i < per_card:
		var added := false
		for c in cities:
			if slots <= 0:
				break
			deck.append(c.clone())
			slots -= 1
			added = true
		if not added:
			break
		round_i += 1
	# 不足最少张数：在可收集卡池里轮转补副本（确定性）
	if min_size > deck.size() and not pool.is_empty():
		var i := 0
		while deck.size() < min_size:
			deck.append(pool[i % pool.size()].clone())
			i += 1
	# 超过最多张数：从尾部裁掉（同样确定性）
	if max_size > 0 and deck.size() > max_size:
		deck.resize(max_size)
	return deck


# ------------------------------ 预组卡组 ------------------------------
#
# 预组卡组是 res://data/preconstructed_decks.json 里的只读清单，只存「卡牌 id + 份数」，
# 界面上给玩家选一套来对战（选择结果存在 GameSettings.selected_deck）。
# 好处是换架构强度、卡面貌小鼠的是数据，不需要改代码；缺点是它依赖卡表，
# 所以下面每一步都要处理「管理员删卡改名」导致的对不上。

## 读预组卡组清单。文件缺失 / 格式不对时清单为空，主页会退化成「只有全卡牌组」。
func load_prebuilt_decks() -> void:
	prebuilt_decks = []
	var parsed: Variant = _read_json_array(PREBUILT_PATH)
	if parsed == null:
		return
	for item in parsed:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var def: Dictionary = item
		var did := str(def.get("id", ""))
		if did == "":
			continue
		var entries: Array = []
		for e in def.get("cards", []):
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var cid := str(e.get("id", ""))
			var n := int(e.get("count", 1))
			if cid == "" or n <= 0:
				continue
			entries.append({"id": cid, "count": n})
		if entries.is_empty():
			continue
		prebuilt_decks.append({
			"id": did,
			"name": str(def.get("name", did)),
			"color": str(def.get("color", "#ffee58")),
			"desc": str(def.get("desc", "")),
			"cards": entries,
		})
	print("[CardDB] 已载入 %d 套预组卡组" % prebuilt_decks.size())


## 按 id 取一套定义；没有就返回空字典（调用方据此判断「选了不存在卡组」）
func prebuilt_deck_by_id(id: String) -> Dictionary:
	if id == "":
		return {}
	for d in prebuilt_decks:
		if str(d.get("id", "")) == id:
			return d
	return {}


## 一套预组卡组在当前卡表下的实际张数（卡牌被删 → 变少；份数超过 max_copies → 被夹紧）
static func prebuilt_deck_size(def: Dictionary, max_copies: int) -> int:
	var n := 0
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		n += mini(int(e.get("count", 1)), maxi(1, max_copies))
	return n


## 载入一套推荐搭配的内容为牌库（每张都 clone()，实例互相独立）。
## 返回空数组表示「这套用不了」（id 不存在、卡牌全被删掉等），调用方应回落到 build_deck()。
## 仍要遵守卡组规则：同名卡不超过 max_copies；不足 deck_min 就按原配比轮转补足；超过 deck_max 从尾部裁掉。
func build_prebuilt_deck(id: String, mode: String = "") -> Array[CardData]:
	var def := prebuilt_deck_by_id(id)
	if def.is_empty():
		return []
	var ratios: Array = []
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var cid := str(e.get("id", ""))
		var template := get_card(cid)
		if template == null or template.is_token:   # 卡被删了 / 变成衍生物 → 跳过
			continue
		if mode != "" and not mode_allows_card(mode, template):   # 不在本模式卡包里 / 被禁用
			continue
		# 同名上限尊重限制卡 / 稀有度 / 单卡设置（推荐搭配也可能含传说等）
		var per_card := max_copies_for_mode(template, mode)
		var want := mini(int(e.get("count", 1)), per_card)
		if cid == "" or want <= 0:
			continue
		ratios.append([template, want])
	return _expand_deck(ratios, mode)


## 「[CardData, 份数]」→ 真实牌库：城邦收口、补足 / 裁剪都在这里，
## 推荐搭配与玩家自己组的卡组共用同一套收口口径（见 _expand_deck 注释）。
func _expand_deck(ratios: Array, mode: String = "") -> Array[CardData]:
	var deck: Array[CardData] = []
	if ratios.is_empty():
		return deck
	var city_slots: int = CardData.CITY_DECK_LIMIT
	for entry in ratios:
		var tpl: CardData = entry[0]
		var want: int = int(entry[1])
		for _j in want:
			if tpl.is_city():
				if city_slots <= 0:
					continue
				city_slots -= 1
			deck.append(tpl.clone())
	# 不足最少张数：按这套自己的配比轮转补副本（保持卡组性格，比拿全卡池补好）
	var min_size := mode_deck_min(mode)
	var max_size := mode_deck_max(mode)
	if min_size > deck.size():
		var i := 0
		while deck.size() < min_size:
			var fill: CardData = ratios[i % ratios.size()][0]
			deck.append(fill.clone())
			i += 1
	if max_size > 0 and deck.size() > max_size:
		deck.resize(max_size)
	return deck


## 这套卡组在**当前卡表**下真正能凑出的张数（卡牌被删就会被跳过）。
## 0 表示这套已经组不出来，界面要标成「不可用」。
func prebuilt_deck_available_size(def: Dictionary) -> int:
	var n := 0
	var per_card := maxi(1, max_copies)
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if not has_id(str(e.get("id", ""))):
			continue
		n += mini(int(e.get("count", 1)), per_card)
	return n


## 这套卡组拿到对局里会是几张：可用张数经过卡组规则收口后的结果。
## 界面显示这个数字，免得写着「30 张」实际因为 deck_min=45 打出 45 张。
func prebuilt_deck_actual_size(def: Dictionary) -> int:
	var n := prebuilt_deck_available_size(def)
	if n == 0:
		return 0                                   # 组不出来就是组不出来，补足也救不了
	if deck_min > n:
		n = deck_min
	if deck_max > 0 and n > deck_max:
		n = deck_max
	return n


## 把一套定义整理成「卡牌名 × 份数」的可读列表（详情面板用；同样会跳过失效卡牌）
func prebuilt_deck_contents(def: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if def.is_empty():
		return out
	var per_card := maxi(1, max_copies)
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var cid := str(e.get("id", ""))
		var tpl := get_card(cid)
		if tpl == null:
			continue
		out.append({
			"id": cid,
			"name": tpl.card_name,
			"cost": tpl.cost,
			"card_type": tpl.card_type,
			"count": mini(int(e.get("count", 1)), per_card),
		})
	return out


# ------------------------------ 主战者职业 ------------------------------
#
# 职业只有「id / 名字 / 颜色 / 简介」四个字段，卡牌通过 CardData.class_id 指向它。
# 两个约定保证管理员怎么折腾都不会把游戏搞崩：
#   * **职业被删** → 原本属于它的卡立刻被改成中立（读写时用 card_class_of() 归一），
#     所以老卡组不会因为「职业没了」而报错；
#   * **id 非法 / 重复** → 一律拒绝写入，宁可不动数据也不留下说不清的职业。

## 读职业表：没有管理员存档 → 用内置默认值并落成默认存档（与卡牌存档同一套路）
func load_hero_classes() -> void:
	hero_classes = []
	var parsed: Variant = _read_json_array(HERO_CLASS_PATH)
	if parsed == null and FileAccess.file_exists(HERO_CLASS_PATH):
		push_warning("[CardDB] 职业存档无法解析：%s（本次不启用任何自定义职业）" % HERO_CLASS_PATH)
		_rebuild_class_index()
		return
	if parsed == null:
		parsed = _read_json_array(HERO_CLASS_DEFAULT_PATH)
		if parsed != null:
			hero_classes = _parse_hero_classes(parsed)
			_rebuild_class_index()
			save_hero_classes()
			print("[CardDB] 已初始化 %d 个主战者职业" % hero_classes.size())
			return
	# 有存档就用存档：即使是空数组——管理员把职业全删了就是这个结果
	hero_classes = _parse_hero_classes(parsed)
	_rebuild_class_index()
	print("[CardDB] 已载入 %d 个主战者职业" % hero_classes.size())


func _parse_hero_classes(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var cid := str(e.get("id", "")).strip_edges()
		if cid == "" or cid == CardData.NEUTRAL_CLASS or _class_at(out, cid) >= 0:
			continue
		var name := str(e.get("name", cid)).strip_edges()
		out.append({
			"id": cid,
			"name": name if name != "" else cid,
			"color": str(e.get("color", HERO_CLASS_COLOR_FALLBACK)),
			"desc": str(e.get("desc", "")),
		})
	return out


static func _class_at(list: Array, cid: String) -> int:
	for i in list.size():
		if str((list[i] as Dictionary).get("id", "")) == cid:
			return i
	return -1


func _rebuild_class_index() -> void:
	_class_index.clear()
	for e in hero_classes:
		_class_index[str(e.get("id", ""))] = e


func save_hero_classes() -> bool:
	var arr: Array = []
	for e in hero_classes:
		arr.append((e as Dictionary).duplicate(true))
	var file := FileAccess.open(HERO_CLASS_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[CardDB] 无法写入职业数据：%s" % HERO_CLASS_PATH)
		return false
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()
	_rebuild_class_index()
	database_changed.emit()
	return true


## 职业 id 是否可用作新职业（非空、不是保留的中立 id、写法合法）
static func hero_class_id_valid(cid: String) -> bool:
	var id := cid.strip_edges()
	if id == "" or id == CardData.NEUTRAL_CLASS:
		return false
	return id.is_valid_identifier()


func hero_class_by_id(cid: String) -> Dictionary:
	return _class_index.get(cid, {})


func has_hero_class(cid: String) -> bool:
	return _class_index.has(cid)


func hero_class_name(cid: String) -> String:
	if cid == "" or cid == CardData.NEUTRAL_CLASS:
		return NEUTRAL_CLASS_NAME
	return str(hero_class_by_id(cid).get("name", cid))


func hero_class_color(cid: String) -> Color:
	var raw := HERO_CLASS_COLOR_FALLBACK
	var def := hero_class_by_id(cid)
	if not def.is_empty():
		raw = str(def.get("color", raw))
	if cid == "" or cid == CardData.NEUTRAL_CLASS:
		raw = "#b0bec5"
	return Color.html(raw) if Color.html_is_valid(raw) else Color(0.69, 0.74, 0.77)


func hero_class_ids() -> Array[String]:
	var out: Array[String] = []
	for e in hero_classes:
		out.append(str(e.get("id", "")))
	return out


## 随机挑一个职业（敌方 AI 每局用）；没有配置职业时返回 ""（= 不限职业）
func random_hero_class() -> String:
	if hero_classes.is_empty():
		return ""
	return str(hero_classes[randi() % hero_classes.size()].get("id", ""))


## 一张卡**实际**所属职业：中立 / 空串 / 已被删除的职业 id 都归到「中立」
func card_class_of(c: CardData) -> String:
	if c == null or c.is_neutral():
		return CardData.NEUTRAL_CLASS
	return c.class_id if _class_index.has(c.class_id) else CardData.NEUTRAL_CLASS


## 这张卡能不能进某个主战者的卡组：**本职业 + 中立**。
## `class_id` 为空串表示管理员还没配职业，此时不限制（旧行为）。
func card_allowed_for_class(c: CardData, class_id: String) -> bool:
	if c == null or c.is_token:
		return false
	if class_id == "":
		return true
	var own := card_class_of(c)
	return own == CardData.NEUTRAL_CLASS or own == class_id


## 某个职业名下（可收集卡牌）的种类数，管理员面板 / 组卡界面都用它提示规模
func class_card_count(cid: String) -> int:
	var n := 0
	for c in cards:
		if not c.is_token and card_class_of(c) == cid:
			n += 1
	return n


## 中立卡（可收集）的种类数：任何主战者都能带
func neutral_card_count() -> int:
	var n := 0
	for c in cards:
		if not c.is_token and card_class_of(c) == CardData.NEUTRAL_CLASS:
			n += 1
	return n


## 新增职业：id 非法 / 重名 → 失败并存而不写盘
func add_hero_class(cid: String, cname: String, color: String, desc: String = "") -> bool:
	if not hero_class_id_valid(cid) or has_hero_class(cid):
		return false
	var name := cname.strip_edges()
	hero_classes.append({
		"id": cid.strip_edges(),
		"name": name if name != "" else cid,
		"color": color if color != "" else HERO_CLASS_COLOR_FALLBACK,
		"desc": desc,
	})
	return save_hero_classes()


func update_hero_class(cid: String, cname: String, color: String, desc: String = "") -> bool:
	var i := _class_at(hero_classes, cid)
	if i < 0:
		return false
	var name := cname.strip_edges()
	hero_classes[i] = {
		"id": cid,
		"name": name if name != "" else str(hero_classes[i].get("name", cid)),
		"color": color if color != "" else HERO_CLASS_COLOR_FALLBACK,
		"desc": desc,
	}
	return save_hero_classes()


## 删除职业：原本属于它的卡**立刻改成中立**并写入卡牌存档，
## 这样老卡组不会因为「职业没了」而失效，管理员也不会看到算不清的残值。
## 返回被改成中立的卡牌张数（-1 = 职业不存在）。
func remove_hero_class(cid: String) -> int:
	if not has_hero_class(cid):
		return -1
	var changed := 0
	for c in cards:
		if not c.is_neutral() and c.class_id == cid:
			c.class_id = CardData.NEUTRAL_CLASS
			changed += 1
	hero_classes.remove_at(_class_at(hero_classes, cid))
	save_hero_classes()
	if changed > 0:
		save_cards()
	return changed


# ------------------------------ 兵种 ------------------------------
#
# 兵种 = 影之诗的「士兵 / 指挥官」这类**单位分类**，与「种类（card_type）」是两回事：
#   * 种类是固定的 4 档（随从 / 法术 / 护符 / 城邦），决定规则口径（占不占格子、能不能攻击）；
#   * 兵种是**管理员自己建**的标签，一张卡最多挂一个（CardData.troop_id）。
#
# 三条约定：
#   * **先建兵种，再给卡牌选**：卡牌表单的兵种下拉只列已登记的兵种（见 AdminPanel）；
#   * **兵种被删** → 原本挂着它的卡立刻改成「中立」（读时 troop_of() 也会归一），
#     这样老卡组 / 老存档不会因为「兵种没了」留下说不清的残值；
#   * **兵种是条件与检索的键**：效果链条件（EffectConditions 的 troop_* 量）、
#     进场计数（PlayerState.troop_entered_total）、卡牌检索（card_matches）都按它算。

## 读兵种表：没有管理员存档 → 用内置默认值并落成默认存档（与职业表同一套路）。
## 老存档（这次改动之前没有「中立」）会自动补一条内置「中立」并写回。
func load_troops() -> void:
	troops = []
	var parsed: Variant = _read_json_array(TROOP_PATH)
	if parsed == null and FileAccess.file_exists(TROOP_PATH):
		push_warning("[CardDB] 兵种存档无法解析：%s（本次只用内置「中立」兵种）" % TROOP_PATH)
		_ensure_neutral_troop()
		save_troops()
		return
	var should_save := false
	if parsed == null:
		parsed = _read_json_array(TROOP_DEFAULT_PATH)
		should_save = true               # 第一次运行：把内置默认值落成存档
	if parsed != null:
		troops = _parse_troops(parsed)
	_rebuild_troop_index()
	if _ensure_neutral_troop():
		should_save = true               # 老存档没有「中立」→ 补上，保证「无兵种 = 中立」成立
	if should_save:
		save_troops()
	print("[CardDB] 已载入 %d 个兵种" % troops.size())


## 内置「中立」兵种必须存在（不可删）。补上了返回 true。
func _ensure_neutral_troop() -> bool:
	if _troop_index.has(CardData.NEUTRAL_TROOP):
		return false
	troops.push_front({
		"id": CardData.NEUTRAL_TROOP,
		"name": CardData.NEUTRAL_TROOP_NAME,
		"color": "#b0bec5",
		"desc": "不属于任何兵种的卡默认归入这个兵种。",
	})
	_rebuild_troop_index()
	return true


func _parse_troops(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var tid := str(e.get("id", "")).strip_edges()
		if tid == "" or _troop_at(out, tid) >= 0:
			continue
		var name := str(e.get("name", tid)).strip_edges()
		out.append({
			"id": tid,
			"name": name if name != "" else tid,
			"color": str(e.get("color", TROOP_COLOR_FALLBACK)),
			"desc": str(e.get("desc", "")),
		})
	return out


static func _troop_at(list: Array, tid: String) -> int:
	for i in list.size():
		if str((list[i] as Dictionary).get("id", "")) == tid:
			return i
	return -1


func _rebuild_troop_index() -> void:
	_troop_index.clear()
	for e in troops:
		_troop_index[str(e.get("id", ""))] = e


func save_troops() -> bool:
	var arr: Array = []
	for e in troops:
		arr.append((e as Dictionary).duplicate(true))
	var file := FileAccess.open(TROOP_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[CardDB] 无法写入兵种数据：%s" % TROOP_PATH)
		return false
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()
	_rebuild_troop_index()
	database_changed.emit()
	return true


## 兵种 id 是否可用作新兵种（非空、写法合法；是否重名由 add_troop 判）
static func troop_id_valid(tid: String) -> bool:
	var id := tid.strip_edges()
	return id != "" and id.is_valid_identifier()


func troop_by_id(tid: String) -> Dictionary:
	return _troop_index.get(tid, {})


func has_troop(tid: String) -> bool:
	return tid != "" and _troop_index.has(tid)


## 显示名："" = 中立兵种；未登记 → 原样返回 id（管理员能一眼看出是坏数据）
func troop_name(tid: String) -> String:
	if is_neutral_troop(tid):
		return str(troop_by_id(CardData.NEUTRAL_TROOP).get("name", CardData.NEUTRAL_TROOP_NAME))
	return str(troop_by_id(tid).get("name", tid))


## 是不是内置「中立」兵种（"" 也算中立：所有没选兵种的卡都归它）
static func is_neutral_troop(tid: String) -> bool:
	var id := tid.strip_edges()
	return id == "" or id == CardData.NEUTRAL_TROOP


func troop_color(tid: String) -> Color:
	var raw := str(troop_by_id(tid).get("color", TROOP_COLOR_FALLBACK))
	return Color.html(raw) if Color.html_is_valid(raw) else Color(0.56, 0.64, 0.68)


func troop_ids() -> Array[String]:
	var out: Array[String] = []
	for e in troops:
		out.append(str(e.get("id", "")))
	return out


## 一张卡**实际**所属兵种：没填（""）/ 兵种被删掉了 → 一律算内置「中立」。
## 检索、效果链条件、进场计数都用这个函数取兵种，所以「中立」也是能被搜到、能被当条件的正常兵种。
func troop_of(c: CardData) -> String:
	if c == null:
		return CardData.NEUTRAL_TROOP
	if c.troop_id == "" or not _troop_index.has(c.troop_id):
		return CardData.NEUTRAL_TROOP
	return c.troop_id


## 某个兵种名下（可收集卡牌）的种类数
func troop_card_count(tid: String) -> int:
	if tid == "":
		return 0
	var n := 0
	for c in cards:
		if not c.is_token and troop_of(c) == tid:
			n += 1
	return n


## 新增兵种：id 非法 / 重名 → 失败且不写盘
func add_troop(tid: String, tname: String, color: String, desc: String = "") -> bool:
	if not troop_id_valid(tid) or has_troop(tid):
		return false
	var name := tname.strip_edges()
	troops.append({
		"id": tid.strip_edges(),
		"name": name if name != "" else tid,
		"color": color if color != "" else TROOP_COLOR_FALLBACK,
		"desc": desc,
	})
	return save_troops()


func update_troop(tid: String, tname: String, color: String, desc: String = "") -> bool:
	var i := _troop_at(troops, tid)
	if i < 0:
		return false
	var name := tname.strip_edges()
	troops[i] = {
		"id": tid,
		"name": name if name != "" else str(troops[i].get("name", tid)),
		"color": color if color != "" else TROOP_COLOR_FALLBACK,
		"desc": desc,
	}
	return save_troops()


## 删除兵种：原本挂着它的卡**立刻改成「中立」**并写盘。
## 返回被清掉的卡牌张数；-1 = 兵种不存在；-2 = 内置「中立」不可删除。
func remove_troop(tid: String) -> int:
	if is_neutral_troop(tid):
		return -2
	if not has_troop(tid):
		return -1
	var changed := 0
	for c in cards:
		if c.troop_id == tid:
			c.troop_id = ""
			changed += 1
	troops.remove_at(_troop_at(troops, tid))
	save_troops()
	if changed > 0:
		save_cards()
	return changed


# ------------------------------ 卡包（扩展包） ------------------------------
#
# 卡包 = 管理员维护的「扩展包」标签，一张卡最多挂一个（CardData.pack_id）：
#   * 先建卡包，再给卡牌选（卡牌表单的卡包下拉只列已登记的卡包）；
#   * 卡包被删 → 原本挂着它的卡立刻回到「基础卡包」（读时 pack_of() 也会归一）；
#   * 「指定」模式只认管理员勾选的卡包；「无限」模式所有卡包都能用（见 mode_allowed_packs）。

## 读卡包表：没有管理员存档 → 用内置默认值并落成默认存档（与职业表 / 兵种表同一套路）。
func load_packs() -> void:
	packs = []
	var parsed: Variant = _read_json_array(PACK_PATH)
	if parsed == null and FileAccess.file_exists(PACK_PATH):
		push_warning("[CardDB] 卡包存档无法解析：%s（本次只用内置「%s」）" % [PACK_PATH, DEFAULT_PACK_NAME])
		_ensure_default_pack()
		save_packs()
		return
	var should_save := false
	if parsed == null:
		parsed = _read_json_array(PACK_DEFAULT_PATH)
		should_save = true               # 第一次运行：把内置默认值落成存档
	if parsed != null:
		packs = _parse_packs(parsed)
	_rebuild_pack_index()
	if _ensure_default_pack():
		should_save = true               # 老存档没有基础包 → 补上，保证「无卡包 = 基础包」成立
	if should_save:
		save_packs()
	print("[CardDB] 已载入 %d 个卡包" % packs.size())


## 内置基础卡包必须存在（不可删）。补上了返回 true。
func _ensure_default_pack() -> bool:
	if _pack_index.has(DEFAULT_PACK):
		return false
	packs.push_front({
		"id": DEFAULT_PACK,
		"name": DEFAULT_PACK_NAME,
		"color": PACK_COLOR_FALLBACK,
		"desc": "没有指定卡包的卡牌都归入这里。",
	})
	_rebuild_pack_index()
	return true


func _parse_packs(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var pid := str(e.get("id", "")).strip_edges()
		if pid == "" or _pack_at(out, pid) >= 0:
			continue
		var name := str(e.get("name", pid)).strip_edges()
		out.append({
			"id": pid,
			"name": name if name != "" else pid,
			"color": str(e.get("color", PACK_COLOR_FALLBACK)),
			"desc": str(e.get("desc", "")),
		})
	return out


static func _pack_at(list: Array, pid: String) -> int:
	for i in list.size():
		if str((list[i] as Dictionary).get("id", "")) == pid:
			return i
	return -1


func _rebuild_pack_index() -> void:
	_pack_index.clear()
	for e in packs:
		_pack_index[str(e.get("id", ""))] = e


func save_packs() -> bool:
	var arr: Array = []
	for e in packs:
		arr.append((e as Dictionary).duplicate(true))
	var file := FileAccess.open(PACK_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[CardDB] 无法写入卡包数据：%s" % PACK_PATH)
		return false
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()
	_rebuild_pack_index()
	database_changed.emit()
	return true


static func pack_id_valid(pid: String) -> bool:
	var id := pid.strip_edges()
	return id != "" and id.is_valid_identifier()


func pack_by_id(pid: String) -> Dictionary:
	return _pack_index.get(pid, {})


func has_pack(pid: String) -> bool:
	return pid != "" and _pack_index.has(pid)


## 显示名：未登记 → 原样返回 id（管理员能一眼看出是坏数据）
func pack_name(pid: String) -> String:
	if pid == "":
		return DEFAULT_PACK_NAME
	return str(pack_by_id(pid).get("name", pid))


func pack_color(pid: String) -> Color:
	var raw := str(pack_by_id(pid).get("color", PACK_COLOR_FALLBACK))
	return Color.html(raw) if Color.html_is_valid(raw) else Color(0.56, 0.79, 0.98)


func pack_ids() -> Array[String]:
	var out: Array[String] = []
	for e in packs:
		out.append(str(e.get("id", "")))
	return out


## 一张卡**实际**所属卡包：没填（""）/ 卡包被删掉了 → 一律算内置「基础卡包」。
## 「指定」模式的卡包范围、卡牌检索与界面显示都用这个函数取卡包。
func pack_of(c: CardData) -> String:
	if c == null:
		return DEFAULT_PACK
	if c.pack_id == "" or not _pack_index.has(c.pack_id):
		return DEFAULT_PACK
	return c.pack_id


## 某个卡包名下（可收集卡牌）的种类数
func pack_card_count(pid: String) -> int:
	if pid == "":
		return 0
	var n := 0
	for c in cards:
		if not c.is_token and pack_of(c) == pid:
			n += 1
	return n


## 新增卡包：id 非法 / 重名 → 失败且不写盘
func add_pack(pid: String, pname: String, color: String, desc: String = "") -> bool:
	if not pack_id_valid(pid) or has_pack(pid):
		return false
	var name := pname.strip_edges()
	packs.append({
		"id": pid.strip_edges(),
		"name": name if name != "" else pid,
		"color": color if color != "" else PACK_COLOR_FALLBACK,
		"desc": desc,
	})
	_rebuild_pack_index()
	return save_packs()


func update_pack(pid: String, pname: String, color: String, desc: String = "") -> bool:
	var i := _pack_at(packs, pid)
	if i < 0:
		return false
	var name := pname.strip_edges()
	packs[i] = {
		"id": pid,
		"name": name if name != "" else str(packs[i].get("name", pid)),
		"color": color if color != "" else PACK_COLOR_FALLBACK,
		"desc": desc,
	}
	_rebuild_pack_index()
	return save_packs()


## 删除卡包：原本挂着它的卡**立刻回到基础卡包**并写盘。
## 返回被清掉的卡牌张数；-1 = 卡包不存在；-2 = 内置基础卡包不可删除。
func remove_pack(pid: String) -> int:
	if pid == DEFAULT_PACK:
		return -2
	if not has_pack(pid):
		return -1
	var changed := 0
	for c in cards:
		if c.pack_id == pid:
			c.pack_id = ""
			changed += 1
	packs.remove_at(_pack_at(packs, pid))
	save_packs()
	# 指定模式还勾着这个包 → 顺手从勾选里去掉（否则读取时会被忽略并留下脏数据）
	var pids: Array[String] = []
	for id in rotation_rules.get("packs", []):
		if str(id) != pid and has_pack(str(id)):
			pids.append(str(id))
	if pids.is_empty():
		pids = pack_ids()
	rotation_rules["packs"] = pids
	_save_format_rules()
	if changed > 0:
		save_cards()
	return changed


# ------------------------------ 玩家自己组的卡组 ------------------------------
#
# 每套卡组 = {"id","name","class_id","cards":[{"id","count"}]}，存在 user://decks.json。
# 「组得起」的判定全部走 player_deck_stats()：界面提示、合法性校验、真正发牌
# 是同一套口径，不会出现「界面说能用、开局却是空牌库」这种事。

func load_player_decks() -> void:
	player_decks = []
	var parsed: Variant = _read_json_array(DECKS_PATH)
	if parsed == null:
		return
	for item in parsed:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var did := str(e.get("id", "")).strip_edges()
		if did == "" or player_deck_by_id(did).has("id"):
			continue
		var name := str(e.get("name", did)).strip_edges()
		player_decks.append({
			"id": did,
			"name": name if name != "" else did,
			"class_id": str(e.get("class_id", "")),
			"cards": _parse_deck_entries(e.get("cards", [])),
		})
	print("[CardDB] 已载入玩家卡组 %d 套" % player_decks.size())


## 读出「id × 份数」清单：非法条目（缺 id / 份数 ≤ 0）直接丢弃
static func _parse_deck_entries(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var cid := str(e.get("id", "")).strip_edges()
		var n := int(e.get("count", 1))
		if cid == "" or n <= 0:
			continue
		out.append({"id": cid, "count": n})
	return out


func save_player_decks() -> bool:
	var arr: Array = []
	for d in player_decks:
		var def: Dictionary = d
		arr.append({
			"id": str(def.get("id", "")),
			"name": str(def.get("name", "")),
			"class_id": str(def.get("class_id", "")),
			"cards": (def.get("cards", []) as Array).duplicate(true),
		})
	var file := FileAccess.open(DECKS_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[CardDB] 无法写入玩家卡组：%s" % DECKS_PATH)
		return false
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()
	database_changed.emit()
	return true


func player_deck_by_id(id: String) -> Dictionary:
	if id == "":
		return {}
	for d in player_decks:
		if str(d.get("id", "")) == id:
			return d
	return {}


## 某个主战者职业下的卡组列表（组卡界面按职业分组显示）
func player_decks_of_class(cid: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in player_decks:
		if str(d.get("class_id", "")) == cid:
			out.append(d)
	return out


func _next_deck_id() -> String:
	var n := player_decks.size() + 1
	while player_deck_by_id("deck%d" % n).has("id"):
		n += 1
	return "deck%d" % n


## 新建（deck_id = "" 时自动分配 id）/ 覆盖一套卡组。
## 只拒绝「一张牌都没有」的卡组写盘：其余偏差（张数超区间、同名超限等）
## 交给发牌时的同一套收口逻辑处理，不会因为管理员改一下规则就让旧卡组集体消失。
## 返回实际写入的 id（失败返回 ""）。
func upsert_player_deck(deck_id: String, cname: String, cid: String, entries: Array) -> String:
	var parsed := _parse_deck_entries(entries)
	if parsed.is_empty():
		return ""
	var def := {
		"id": deck_id,
		"name": cname.strip_edges(),
		"class_id": cid,
		"cards": parsed,
	}
	if deck_id != "" and not player_deck_by_id(deck_id).is_empty():
		for i in player_decks.size():
			if str(player_decks[i].get("id", "")) == deck_id:
				player_decks[i] = def
				break
	else:
		if deck_id == "":
			deck_id = _next_deck_id()
			def["id"] = deck_id
		player_decks.append(def)
	if not save_player_decks():
		return ""
	return deck_id


func remove_player_deck(id: String) -> bool:
	var i := -1
	for k in player_decks.size():
		if str(player_decks[k].get("id", "")) == id:
			i = k
			break
	if i < 0:
		return false
	player_decks.remove_at(i)
	return save_player_decks()


## 一套卡组的张数（按卡组定义原样相加，不看卡表是否还有这些卡）
static func player_deck_size(def: Dictionary) -> int:
	var n := 0
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		n += int(e.get("count", 1))
	return n


## 逐张过一遍这套卡组，得出「哪些能用、哪儿不合规」。
## 界面提示、合法性校验、真正发牌（build_player_deck）都用这一份结果。
## 返回：{"total","missing","illegal","over","city","ratios"}
##   total   能用进牌库的张数（份数已按 max_copies 夹紧、城邦已收口）
##   missing 卡表里已不存在的张数 / illegal 不属于本职业的张数 / over 超过同名上限的张数
##   city    实际带上的城邦张数 / ratios  [CardData, 份数] 列表（发牌直接用）
## `mode`：按哪个对战模式校验（Formats 的模式 id）。空串 = 老口径（不查卡包 / 限制卡），
## 兼容既有调用与测试；组卡界面与开局都用具体模式。
func player_deck_stats(def: Dictionary, mode: String = "") -> Dictionary:
	var cid := str(def.get("class_id", ""))
	var s := {"total": 0, "missing": 0, "illegal": 0, "format": 0,
		"over": 0, "city": 0, "type_over": 0, "ratios": []}
	if def.is_empty():
		return s
	var ratios: Array = []
	var missing := 0
	var illegal := 0
	var format := 0
	var over := 0
	var city := 0
	var type_over := 0
	var total := 0
	# 城邦：受「城邦上限 / 该类总上限」两者较小的约束
	var city_cap := mode_type_cap(mode, CardData.CardType.CITY)
	var city_slots: int = mini(CardData.CITY_DECK_LIMIT, city_cap) if city_cap > 0 else CardData.CITY_DECK_LIMIT
	var type_taken: Dictionary = {}    # card_type -> 已取张数（非城邦种类用）
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var card_id := str(e.get("id", ""))
		var want := int(e.get("count", 1))
		var tpl := get_card(card_id)
		if tpl == null or tpl.is_token:
			missing += want
			continue
		if not card_allowed_for_class(tpl, cid):
			illegal += want
			continue
		# 模式卡池：不在「指定」勾选的卡包里 / 被该模式禁用（限制 0 张）→ 整张不算
		if mode != "" and not mode_allows_card(mode, tpl):
			format += want
			continue
		# 同名上限：限制卡（0 = 禁用）/ 传说=1 / 单卡设置 / 模式同名上限（见 max_copies_for_mode）
		var per_card := max_copies_for_mode(tpl, mode)
		if want > per_card:
			over += want - per_card
		var take := mini(want, per_card)
		if take <= 0:
			continue
		# 种类上限：非城邦卡受「该种类在每张牌组的总携带数」约束
		if not tpl.is_city():
			var tc := mode_type_cap(mode, tpl.card_type)
			if tc > 0:
				var used := int(type_taken.get(tpl.card_type, 0))
				var allowed := tc - used
				if allowed <= 0:
					type_over += take
					continue
				var cut := mini(take, allowed)
				type_over += take - cut
				take = cut
				type_taken[tpl.card_type] = used + take
		if take <= 0:
			continue
		if tpl.is_city():
			take = mini(take, city_slots)
			if take <= 0:
				continue
			city_slots -= take
			city += take
		total += take
		ratios.append([tpl, take])
	s["total"] = total
	s["missing"] = missing
	s["illegal"] = illegal
	s["format"] = format
	s["over"] = over
	s["city"] = city
	s["type_over"] = type_over
	s["ratios"] = ratios
	return s


## 这套卡组为什么不能用：返回空数组 = 完全合法，可以直接开局。
## `mode` 传具体模式 → 连「卡包范围 / 限制卡 / 该模式张数」一起查（组卡界面、开局都是这种）。
func player_deck_errors(def: Dictionary, mode: String = "") -> Array[String]:
	var out: Array[String] = []
	if def.is_empty():
		out.append("还没有组建卡组")
		return out
	var cid := str(def.get("class_id", ""))
	if cid == "" or not has_hero_class(cid):
		out.append("这套卡组的主战者职业「%s」已不存在，请重新组建" % hero_class_name(cid))
	var s := player_deck_stats(def, mode)
	var missing: int = int(s.get("missing", 0))
	var illegal: int = int(s.get("illegal", 0))
	var format: int = int(s.get("format", 0))
	var over: int = int(s.get("over", 0))
	var type_over: int = int(s.get("type_over", 0))
	var city: int = int(s.get("city", 0))
	var total: int = int(s.get("total", 0))
	if missing > 0:
		out.append("有 %d 张卡在当前卡表里找不到（可能被管理员删除），请重新替换" % missing)
	if illegal > 0:
		out.append("有 %d 张卡不是「%s」或中立卡，只有本职业 + 中立能进这套" % [illegal, hero_class_name(cid)])
	if format > 0:
		if Formats.is_rotation(mode):
			out.append("有 %d 张不在「%s」模式的可用卡包内，或已被本模式限制（禁用）" % [
				format, mode_label(mode)])
		else:
			out.append("有 %d 张已被「%s」模式限制（禁用）" % [format, mode_label(mode)])
	if over > 0:
		out.append("有 %d 张超过同名卡携带上限（限制卡 / 传说等稀有度 / 单卡规则）" % over)
	if type_over > 0:
		out.append("有 %d 张超过某一类卡的总携带上限（%s）" % [type_over, _type_caps_text_for(mode)])
	if city > CardData.CITY_DECK_LIMIT:
		out.append("城邦卡过多：每套最多 %d 张" % CardData.CITY_DECK_LIMIT)
	if total <= 0:
		out.append("这套卡组组不出任何牌，请添加卡牌")
		return out
	var min_size := mode_deck_min(mode)
	var max_size := mode_deck_max(mode)
	if min_size > total:
		out.append("共 %d 张，还差 %d 张才到卡组最少 %d 张" % [total, min_size - total, min_size])
	if max_size > 0 and total > max_size:
		out.append("共 %d 张，超过卡组最多 %d 张" % [total, max_size])
	return out


## 这套卡组现在能不能拿去开局（存在且组得出牌）。
## 注意这里**不苛求完美**：卡组规则改过之后允许小偏差，真正发牌会按规则收口，
## 免得管理员改一下上限，玩家所有旧卡组就集体失效。
func player_deck_ready(id: String, mode: String = "") -> bool:
	var def := player_deck_by_id(id)
	if def.is_empty():
		return false
	return int(player_deck_stats(def, mode).get("total", 0)) > 0


## 展开一套玩家卡组为真实牌库；组不出来返回空数组（调用方应回落 build_deck()）
func build_player_deck(id: String, mode: String = "") -> Array[CardData]:
	var def := player_deck_by_id(id)
	if def.is_empty():
		return []
	return _expand_deck(player_deck_stats(def, mode).get("ratios", []), mode)


## 这套推荐搭配能不能拿给某个主战者当模板（里面至少得有本职业 / 中立的卡）
func prebuilt_deck_allowed_for_class(def: Dictionary, class_id: String) -> bool:
	if def.is_empty():
		return false
	for e in def.get("cards", []):
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var tpl := get_card(str(e.get("id", "")))
		if tpl == null or tpl.is_token:
			continue
		if card_allowed_for_class(tpl, class_id):
			return true
	return false


## 当前卡表里城邦卡的种类数（供界面提示“牌组最多带 N 张”）
func city_card_count() -> int:
	var n := 0
	for c in cards:
		if c.is_city() and not c.is_token:
			n += 1
	return n


## 一副牌库里城邦卡的实际张数（与上限对照用）
static func deck_city_count(deck: Array) -> int:
	var n := 0
	for c in deck:
		if c is CardData and c.is_city():
			n += 1
	return n


func token_count() -> int:
	var n := 0
	for c in cards:
		if c.is_token:
			n += 1
	return n


## 内置卡表里有、但当前存档里没有的卡牌 ID。
## 存档优先于内置卡表（管理员的增删改要保留），所以版本更新新增的卡不会自动出现——
## 用这个函数在启动时提示玩家「可以恢复默认卡表来启用新卡」，而不是悄悄覆盖管理员的改动。
func missing_builtin_ids() -> Array[String]:
	var out: Array[String] = []
	for c in _builtin_cards():
		if not has_id(c.id):
			out.append(c.id)
	return out


func _next_id() -> String:
	var max_n := 0
	for c in cards:
		var digits := ""
		for ch in c.id:
			if ch.is_valid_int():
				digits += ch
		if digits != "":
			max_n = maxi(max_n, int(digits))
	return "c%03d" % (max_n + 1)
