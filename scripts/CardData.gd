class_name CardData
extends Resource
## 一张卡牌的完整静态数据。
## 既可在编辑器里作为 Resource 编辑，也可与 Dictionary / JSON 互相转换。
##
## card_type 0=随从 1=法术 2=护符 3=城邦（沿用旧版数值，旧卡表可直接兼容）：
##   * 随从：占一格、可攻击；
##   * 法术：结算后进墓地；
##   * 护符：占一格、不能攻击、有耐久，可被伤害 / 指定解掉；
##   * 城邦：与护符同形，但整副牌组合计最多携带 CITY_DECK_LIMIT 张。
##
## 效果分三种形态，**共用同一条「效果链」结算管线**（见 GameManager._resolve_chain）：
##   * 效果链（新）：effects / deathrattle_effects / skill.effects —— 管理员按顺序整合多条效果；
##   * 老字段（旧卡表）：effect_id + value + target + token_id、deathrattle_id + death_value；
##   * 两者关系：链非空时链是唯一事实来源，老字段只做**链首镜像**（见 sync_legacy_from_chains）。

enum CardType { MINION = 0, SPELL = 1, AMULET = 2, CITY = 3 }

## ------------------------------ 稀有度 ------------------------------
## 炉石式稀有度，决定「每张牌组里同名卡默认带几张」（见 CardDB.max_copies_for）：
##   * 传说（LEGENDARY）= 1，其余 = 管理员配置的全局同名上限 max_copies。
## 制作卡牌时是**必选项**（下拉里总有选中项，管理员必须明确挑一种）。
## 管理员还能在卡牌上单独设 deck_limit 覆盖这个默认（见下方字段）。
enum Rarity { BASIC = 0, COMMON = 1, RARE = 2, EPIC = 3, LEGENDARY = 4 }
const RARITY_NAMES := ["基本", "普通", "稀有", "史诗", "传说"]
const RARITY_COLORS := [
	Color("#9e9e9e"),   ## 基本
	Color("#b0bec5"),   ## 普通
	Color("#42a5f5"),   ## 稀有
	Color("#ab47bc"),   ## 史诗
	Color("#ffa726"),   ## 传说
]

## ------------------------------ 瞬念召唤：基础机制（去向） ------------------------------
## 应召上场、并且结算完「瞬念召唤效果」之后，这张卡**留在哪里** —— 制作瞬念召唤时**必选**（不能为空）。
##   KEEP      留在场上（默认，与改动前的行为一致）
##   HAND      返回手牌（手牌满 → 销毁，与「临时召唤到期」同一口径）
##   GRAVEYARD 进入墓地
##   CHOOSE    进入战场后**由玩家选择**（保留在场 / 返回手牌 / 进入墓地）；不选则默认留在场上
enum InvokeDest { KEEP = 0, HAND = 1, GRAVEYARD = 2, CHOOSE = 3 }
const INVOKE_DEST_NAMES := ["留在场上", "返回手牌", "进入墓地", "由玩家选择"]

## ------------------------------ 主战者职业 ------------------------------
## 这里只存职业的 **ID 字符串**，职业清单本身由管理员维护（CardDB.hero_classes），
## 所以新增职业不需要改规则层代码：
##   * NEUTRAL_CLASS = 中立：任何主战者都能带；
##   * 空串 / 没登记的 ID 统一按中立处理（老卡表、职业被删都不会让游戏报错）。
const NEUTRAL_CLASS := "neutral"

## 效果：随从卡表示“战吼”，法术卡表示“法术效果”，deathrattle 表示“亡语”
enum EffectType { NONE = 0, DAMAGE = 1, HEAL = 2, DRAW = 3, SHIELD = 4, SUMMON = 5, DESTROY = 6, BUFF = 7, MANA = 8 }

## 关键字 / 机制。枚举只是 ID，具体效果注册在 Mechanics.gd（钩子），
## 因此新增机制 = 这里加一个 ID + Mechanics 里注册钩子，卡表与管理员面板会自动出现该选项。
enum Keyword { TAUNT = 1, CHARGE = 2, RUSH = 3, DIVINE_SHIELD = 4, WINDFURY = 5, LIFESTEAL = 6, POISONOUS = 7, STEALTH = 8,
	REBORN = 9, SPELL_DAMAGE = 10, STALWART = 11, SLUGGISH = 12,
	## 无法被能力破坏：`消灭`/`剧毒` 这类「直接破坏」对它无效；伤害仍然能把它打死。
	INDESTRUCTIBLE = 13,
	## 不受能力伤害：法术 / 战吼 / 技能等非碰撞伤害为 0；碰撞伤害照常，也能被能力破坏。
	ABILITY_DAMAGE_IMMUNE = 14,
	## 不受碰撞伤害：碰撞时**双方**都受 0 点伤害（攻击主战者同样为 0）。
	COLLISION_DAMAGE_IMMUNE = 15,
	## 觉醒（影之诗「覚醒」）：我方主战者生命 ≤ 10 时，这个随从 +1/+1（触发一次后保留）。
	AWAKEN = 16 }

## 需要选取的目标类型（ALL_ 开头为群体效果，无需选目标）
enum Targeting {
	NONE = 0,
	ANY_CHARACTER = 1,
	ENEMY_MINION = 2,
	ALLY_MINION = 3,
	ANY_MINION = 4,
	ENEMY_HERO = 5,
	ALLY_HERO = 6,
	ALL_ENEMY_MINIONS = 7,
	ALL_ALLY_MINIONS = 8,
}

const TYPE_NAMES := ["随从", "法术", "护符", "城邦"]
## 城邦卡：整副牌组合计最多携带这么多张（“每套卡组最多只能携带两张”）
const CITY_DECK_LIMIT := 2
const EFFECT_NAMES := ["无", "造成伤害", "恢复生命", "抽牌", "获得护甲", "召唤衍生物", "消灭随从", "强化随从", "获得法力"]
const DEATH_NAMES := ["无亡语", "亡语：造成伤害", "亡语：恢复生命", "亡语：抽牌", "亡语：获得护甲", "亡语：召唤衍生物", "亡语：消灭随从", "亡语：强化随从", "亡语：获得法力"]

## “无效果”的 ID（与 CardEffects.NONE 保持一致）
const NO_EFFECT := "none"

## 旧版数值效果（EffectType）到效果 ID 的映射，保证旧卡表 / 旧存档仍可读取
const LEGACY_EFFECT_IDS := [
	"none",      ## NONE
	"damage",    ## DAMAGE
	"heal",      ## HEAL
	"draw",      ## DRAW
	"armor",     ## SHIELD
	"summon",    ## SUMMON
	"destroy",   ## DESTROY
	"buff",      ## BUFF
	"mana",      ## MANA
]

const KEYWORD_NAMES := {
	Keyword.TAUNT: "嘲讽",
	Keyword.CHARGE: "冲锋",
	Keyword.RUSH: "突袭",
	Keyword.DIVINE_SHIELD: "圣盾",
	Keyword.WINDFURY: "风怒",
	Keyword.LIFESTEAL: "吸血",
	Keyword.POISONOUS: "剧毒",
	Keyword.STEALTH: "潜行",
	Keyword.REBORN: "复生",
	Keyword.SPELL_DAMAGE: "法术伤害",
	Keyword.STALWART: "坚壁",
	Keyword.SLUGGISH: "迟钝",
	Keyword.INDESTRUCTIBLE: "不灭",
	Keyword.ABILITY_DAMAGE_IMMUNE: "术法免疫",
	Keyword.COLLISION_DAMAGE_IMMUNE: "碰撞免疫",
	Keyword.AWAKEN: "觉醒",
}
const KEYWORD_KEYS := {
	Keyword.TAUNT: "taunt",
	Keyword.CHARGE: "charge",
	Keyword.RUSH: "rush",
	Keyword.DIVINE_SHIELD: "shield",
	Keyword.WINDFURY: "windfury",
	Keyword.LIFESTEAL: "lifesteal",
	Keyword.POISONOUS: "poisonous",
	Keyword.STEALTH: "stealth",
	Keyword.REBORN: "reborn",
	Keyword.SPELL_DAMAGE: "spell_damage",
	Keyword.STALWART: "stalwart",
	Keyword.SLUGGISH: "sluggish",
	Keyword.INDESTRUCTIBLE: "indestructible",
	Keyword.ABILITY_DAMAGE_IMMUNE: "ability_immunity",
	Keyword.COLLISION_DAMAGE_IMMUNE: "collision_immunity",
	Keyword.AWAKEN: "awaken",
}

## ------------------------------ 运行期关键字（外挂机制用） ------------------------------
## `KEYWORD_NAMES` / `KEYWORD_KEYS` 是 const（GDScript 里不可改），所以外部扩展包
## （`res://mods/` / `user://mods/`，见 `scripts/ModLoader.gd`）新增的机制在这里登记：
##   * `Mods` 载入扩展包的 `mechanics` 时调用 `CardData.register_keyword(id, 名称, key)`；
##   * ID 建议从 `CardData.MOD_KEYWORD_BASE` 起往上取，绝不与内置枚举冲突。
## 所有读名字 / 读 key 的地方都走下面的 `keyword_name()` / `keyword_key()`，
## 内置查 const，外部查这两张运行期表 —— 卡面文字、读取保存因此对内外部一视同仁。
const MOD_KEYWORD_BASE := 1000
static var _rt_keyword_names: Dictionary = {}   ## id → 中文名
static var _rt_keyword_keys: Dictionary = {}    ## key → id
static var _rt_keyword_ids: Dictionary = {}     ## id → key（反向；keyword_key 用它）


## 登记一个运行期关键字（扩展包用；内置机制仍写 `Mechanics._register()`）
static func register_keyword(id: int, name: String, key: String) -> void:
	var k := key.strip_edges()
	if k == "":
		k = "mod_%d" % id
	_rt_keyword_names[id] = name
	_rt_keyword_keys[k] = id
	_rt_keyword_ids[id] = k


## 关键字 ID → 中文名（内置优先，其次运行期登记，最后退化成本身）
static func keyword_name(id: int) -> String:
	if KEYWORD_NAMES.has(id):
		return KEYWORD_NAMES[id]
	return str(_rt_keyword_names.get(id, str(id)))


## 关键字 ID → 卡表 JSON 用的 key；没有则返回空串
static func keyword_key(id: int) -> String:
	if KEYWORD_KEYS.has(id):
		return KEYWORD_KEYS[id]
	return str(_rt_keyword_ids.get(id, ""))


## 该关键字是否已有卡表 key（内置或运行期）——`Mechanics.audit()` 用它做一致性校验
static func has_keyword_key(id: int) -> bool:
	return KEYWORD_KEYS.has(id) or _rt_keyword_ids.has(id)


## 运行期登记的全部关键字 ID（扩展包用；供管理面板 / 文档列出）
static func runtime_keywords() -> Array[int]:
	var out: Array[int] = []
	for k in _rt_keyword_names.keys():
		out.append(int(k))
	out.sort()
	return out


## 全部关键字 ID（内置枚举 + 运行期登记的扩展包关键字）。
## 自检 / 回归测试用它算「应该有都少个机制」，所以扩展包多带机制也不会把断言搞红。
static func all_keyword_ids() -> Array[int]:
	var out: Array[int] = []
	for k in Keyword.values():
		out.append(int(k))
	for k in runtime_keywords():
		if not out.has(k):
			out.append(k)
	return out

const TARGET_NAMES := {
	Targeting.NONE: "不需要目标",
	Targeting.ANY_CHARACTER: "任意角色",
	Targeting.ENEMY_MINION: "敌方随从",
	Targeting.ALLY_MINION: "我方随从",
	Targeting.ANY_MINION: "任意随从",
	Targeting.ENEMY_HERO: "敌方英雄",
	Targeting.ALLY_HERO: "我方英雄",
	Targeting.ALL_ENEMY_MINIONS: "全体敌方随从",
	Targeting.ALL_ALLY_MINIONS: "全体我方随从",
}

@export var id: String = ""
@export var card_name: String = "新卡牌"
@export var cost: int = 1
@export var card_type: CardType = CardType.SPELL
## 过载（炉石风格）：打出后，下一回合可用法力减少这么多（法力上限不减）
@export var overload: int = 0
## 倒计时（影之诗护符风格）：每到自己回合开始 -1，归零时被摧毁；0 = 不倒计时
@export var countdown: int = 0
## 连击（炉石风格）：本回合已经打出过其它牌时，追加执行这个效果
@export var combo_effect_id: String = NO_EFFECT
@export var combo_value: int = 0
## 法术伤害 +N（炉石风格）：我方**法术**的伤害性效果额外造成 N 点（多张可叠加）
@export var spell_damage: int = 0
## 卡图（管理员在卡牌管理里填路径；支持 res:// 与 user://，空 = 用默认卡面）
## 约定目录 `res://assets/art/card_art/<卡 id>.png` 里的同名文件优先于这里（见 ArtStore.art_for）
@export var art_path: String = ""
## 出牌特效名：内置 ArtStore.VFX_LIST 里的一个，或 `res://assets/art/vfx/<名字>/` 里自己加的一种；
## 空 = 无特效（见 ArtStore.vfx_options / vfx_display / vfx_color）
@export var vfx: String = ""
@export var attack: int = 0
@export var health: int = 0
@export var effect: EffectType = EffectType.NONE   ## 兼容旧卡表，新卡请用 effect_id
@export var effect_id: String = ""                ## 战吼 / 法术效果（见 CardEffects 注册表）
@export var value: int = 0
@export var target: Targeting = Targeting.NONE
@export var keywords: Array[int] = []
@export var token_id: String = ""          ## SUMMON 要召唤的衍生物 id
@export var deathrattle: EffectType = EffectType.NONE   ## 兼容旧卡表
@export var deathrattle_id: String = ""                 ## 亡语效果（见 CardEffects 注册表）
@export var death_value: int = 0
## 战吼 / 法术（护符 / 城邦 = 安放）的**多段效果**：按数组顺序逐条结算。
## 一条效果（Dictionary，JSON 友好）：
##   {"id": String, "value": int, "target": int, "token": String, "cond": Dictionary}
##     id      CardEffects 注册 ID（"none" = 空）
##     value   数值
##     target  CardData.Targeting；缺省或 -1 → 用 CardEffects.default_target(id)
##     token   召唤衍生物用的衍生物 ID
##     cond    可选条件（见 EffectConditions）：**不满足就跳过这一条**，链继续往下走。
##             形如 {"metric": "troop_entered", "op": ">=", "value": 3, "troop": "soldier"}
##             （本局「士兵」进场 ≥ 3 张才结算这一条）—— 兵种由管理员自己创建，条件随之可用。
## 非空时这张卡的效果**以链为准**：旧的 effect_id / value / target / token_id 会被镜像成
## 链里第一条有效效果（AI / 界面 / 旧断言看到的老字段始终与链首一致）。
@export var effects: Array[Dictionary] = []
## 亡语的多段效果，按数组顺序结算（目标在触发时自动推导，与卡表的 target 无关）
@export var deathrattle_effects: Array[Dictionary] = []
## 主动技能：{} = 没有技能
## {"name": String, "cost": int, "target": int, "once_per_turn": bool, "effects": Array[Dictionary]}
@export var skill: Dictionary = {}
## 瞬念召唤（影之诗 Invocation 风格）：这张卡**自己**待在牌库里、满足条件时自动上场。
##
## 它与「呼唤」（Effects 里的 summon_deck_*）是两回事：
##   * 呼唤是**某张牌的效果链里的一条效果**，由那张牌主动去找；
##   * 瞬念召唤是**这张卡自带的能力**，由引擎在每个检查点替它判定 —— 它自己不需要出牌者做任何事。
## 三条规则（与《影之诗》一致）：
##   * 它**不是战吼**：应召上场**不结算**入场效果（想要就得配「触发一次入场效果」）；
##   * **同名卡的瞬念召唤每个回合只结算一次**（多张同名卡在同一回合只应召一张）；
##   * 它是被动能力，**不挑回合**：对面行动时满足条件也会应召（见触发时机）。
##
## 一个键都不能少地长这样：
##   {"enabled": bool, "metric": String, "op": String, "value": int, "troop": String,
##    "timing": int, "effects": Array, "destination": int}
##     enabled     关着就完全不判定（老卡表缺省 = 关）
##     metric      要读的那个量（InvokeConditions.metrics()）
##     op          比较符（InvokeConditions.OPS：<= >= = != < >）
##     value       阈值
##     troop       只有「兵种类量」（troop_entered / troop_entered_turn / troop_board /
##                 troop_grave）才用得上：要看哪个兵种；空 = 内置「中立」
##     timing      InvokeConditions.TIME_*；缺省 0 = 任意检查点
##     effects     **瞬念召唤效果**：应召上场后单独结算的一条效果链，**与战吼 / 亡语完全独立**（可留空）
##     destination **基础机制**（去向，制作时必选、不能为空，见 InvokeDest）：效果结算完之后这张卡留在哪
## （旧格式 `{..., "condition": "hand_at_least", "value": 3}` 读取时自动转成 metric+op，见 _read_invocation）
##
## 结算顺序（用户口径）：有空置格 → 召唤到空置格 → **触发瞬念召唤效果**（effects，可为空）→ **基础机制**（destination）；
## **没有空置格 → 这张卡「消失」**（影之诗的消失：从游戏中移除，不进战场 / 手牌 / 墓地）。
@export var invocation: Dictionary = {}
## 融合（影之诗的「融合」）：这张卡在**手牌里**吃掉符合条件的其它手牌，按融合结果变强。
## 数据（JSON 友好）：
##   {
##     "enabled": true,
##     "count": 1,                        # 每次融合需要几张材料
##     "filter": {"troop": "", "type": -1, "cost_min": 0, "cost_max": 99},
##     "require": {"metric": "units_left", "op": ">=", "value": 3},   # 融合的前置条件（可空）
##     "effects": [...],                  # 融合时**在手牌中发动**的效果链（可空）
##     "gain": [...],                     # 融合后这张卡**永久获得**的效果链（可空）
##     "transform": ""                    # 融合后化身成的卡 id（可空；配了就替换整张卡）
##   }
## filter 为空 = 任何手牌都能当材料；type = -1 不限种类；require 走 EffectConditions 的量。
@export var fusion: Dictionary = {}
@export var is_token: bool = false         ## 衍生物：不进入玩家牌库
## 所属主战者职业（管理员在卡牌管理里选）：NEUTRAL_CLASS = 中立，任何主战者都能带。
## 玩家组牌时只能用「本职业 + 中立」的卡，详见 CardDB.card_allowed_for_class()。
@export var class_id: String = NEUTRAL_CLASS
## 主战者效果（照影之诗**一代**的「主战者に付与される効果」，不是二代的纹章）：
## 这张卡在某个时机把一条监听器挂到主战者身上，之后由引擎在事件发生时替它结算。
## 每条 = {"grant", "on", "cost", "turns", "target", "effects"}，字段含义见 scripts/LeaderEffects.gd。
## 例：{"grant":"play","on":"turn_start","turns":3,"target":0,"cost":-1,
##      "effects":[{"id":"draw","value":1}]} —— 入场时给我方主战者挂「回合开始抽 1 张，持续 3 回合」。
@export var leader_effects: Array[Dictionary] = []
## 卡牌**触发效果**（照《影之诗》一代的「誘発能力」）：这张卡在某个时机自动结算一条效果链，
## 不需要玩家操作，也不占用战吼 / 亡语的位置。每条 = {"on": String, "effects": Array}：
##   on      触发时机（CardTriggers.event_ids()）：入场（打出）/ 召唤入场 / 离场 /
##           瞬念召唤上场 / 消失 / 我方回合开始 / 我方回合结束
##   effects 效果链（与战吼完全同一套效果，可逐条配条件）
## 例：{"on":"summon","effects":[{"id":"draw","value":1}]} —— 被召唤入场时抽 1 张。
## 留空 = 这张卡没有触发效果（老卡表 / 老存档原样兼容）。
@export var triggers: Array[Dictionary] = []

## 兵种（影之诗的 士兵 / 指挥官 这类）：CardDB.troops 里的一个 id。
## **留空 = 中立兵种**（内置的 NEUTRAL_TROOP）：卡表里 troop_id 为 "" 或指向已删除兵种的卡，
## 一律按中立算（见 CardDB.troop_of）——所以任何卡都一定属于某个兵种，不存在「无兵种」。
## 兵种由管理员**先建后用**（见 CardDB.add_troop）；它既是检索维度，也是效果链条件
## （EffectConditions 的 troop_* 量）和进场计数的键（PlayerState.troop_entered_total）。
@export var troop_id: String = ""

## 卡包（扩展包）：CardDB.packs 里的一个 id。
## **留空 = 基础卡包**（CardDB.DEFAULT_PACK）：老卡表 / 老存档的所有卡都自动归到基础包，
## 所以「指定模式」勾上基础包就能继续用它们。卡包由管理员在「卡包」面板先建后用，
## 组卡时按当前模式允许的卡包过滤（见 CardDB.mode_allowed_packs / mode_allows_card）。
@export var pack_id: String = ""
## 运行时状态：被「禁锢」（不写进卡表：to_dict / from_dict / clone 都不带它）。
## 被禁锢的卡：不能被打出 / 召唤 / 响应瞬念召唤，入场与退场能力不发动；身材仍可加减。
var imprisoned: bool = false

## 内置「中立」兵种 id：没指定兵种 / 兵种被删掉的卡都归它（不可删除）
const NEUTRAL_TROOP := "neutral"
const NEUTRAL_TROOP_NAME := "中立"


## 兵种显示名（运行时去根节点问 CardDB；问不到就原样返回 id）。
## 放在这里而不是直接写 `CardDB.xxx`：CardDatabase 依赖 CardData / InvokeConditions /
## EffectConditions，反过来引用 CardDB 会变成循环编译（--script 模式下直接报错）。
static func troop_label(tid: String) -> String:
	if tid == "":
		return NEUTRAL_TROOP_NAME
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var db := (loop as SceneTree).root.get_node_or_null("CardDB")
		if db != null:
			var nm := str(db.troop_name(tid))
			if nm != "":
				return nm
	return tid
## 稀有度（制作卡牌必选）：决定同名卡默认携带上限（传说=1，其余=全局同名上限）。
@export var rarity: int = Rarity.COMMON
## 这张卡在「每张牌组里最多带几张」：0 = 自动（按稀有度，传说 1 / 其余走全局 max_copies）；
## >0 = 管理员给这张卡单独设的上限，优先级最高。卡牌规则面板里「某一个卡牌的最大携带数」就是它。
@export var deck_limit: int = 0
@export var description: String = ""
@export var color: Color = Color("#ffb74d")


static var _effects_reg = null


## 动态取得 CardEffects 注册表（避免两个脚本互相静态引用造成循环编译依赖）。
## 注意：不能叫 effects()——`effects` 已经是本类的效果链成员（数据契约），同名会冲突。
static func effects_registry():
	if _effects_reg == null:
		_effects_reg = load("res://scripts/CardEffects.gd")
	return _effects_reg


## 一条效果是否“真实存在”（空 ID 与 "none" 都算空）
static func is_real_effect_id(id: String) -> bool:
	return id != "" and id != NO_EFFECT


## 需要玩家**主动选择**的目标类型（群体 ALL_* 与“不需要目标”都不算）
static func target_needs_selection(t: int) -> bool:
	return t >= 0 and t != Targeting.NONE \
		and t != Targeting.ALL_ENEMY_MINIONS and t != Targeting.ALL_ALLY_MINIONS


## 读取一条效果链（安全读取 + 逐条深拷贝；非字典的垃圾条目直接丢弃）
static func _read_chain(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for item in raw:
		if typeof(item) == TYPE_DICTIONARY:
			var entry: Dictionary = item
			out.append(entry.duplicate(true))
	return out


## 链里第一条“真实”的效果（全空 / 全是 none → 空字典）
static func _first_effective(chain: Array) -> Dictionary:
	for e in chain:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if is_real_effect_id(str(e.get("id", ""))):
			return e
	return {}


## 一条效果的最终目标类型：显式 target（>= 0）优先，缺省 / -1 → 效果默认目标
static func _entry_target_kind(e: Dictionary) -> int:
	var t := int(e.get("target", -1))
	if t >= 0:
		return t
	return int(effects_registry().default_target(str(e.get("id", ""))))


static func from_dict(d: Dictionary) -> CardData:
	var c := CardData.new()
	c.id = str(d.get("id", _random_id()))
	# 兼容简写键：外部扩展包的作者写 `name` / `type` / `desc` / `pack` 也能读
	# （规范的 `card_name` / `card_type` / `description` / `pack_id` 优先）
	c.card_name = str(d.get("card_name", d.get("name", "未命名卡牌")))
	c.cost = maxi(0, int(d.get("cost", 1)))
	c.card_type = clampi(int(d.get("card_type", d.get("type", int(CardType.SPELL)))), 0, TYPE_NAMES.size() - 1)
	c.attack = maxi(0, int(d.get("attack", 0)))
	c.health = maxi(0, int(d.get("health", 0)))
	c.effect = clampi(int(d.get("effect", int(EffectType.NONE))), 0, EFFECT_NAMES.size() - 1)
	c.effect_id = str(d.get("effect_id", ""))
	if c.effect_id == "" and c.effect > 0:
		c.effect_id = LEGACY_EFFECT_IDS[c.effect] if c.effect < LEGACY_EFFECT_IDS.size() else ""
	elif c.effect_id != "":
		# 反向补全旧版数值字段：只认 effect 的旧代码 / 旧存档仍能正确读到效果
		var legacy := LEGACY_EFFECT_IDS.find(c.effect_id)
		if legacy >= 0:
			c.effect = clampi(legacy, 0, EFFECT_NAMES.size() - 1)
	c.value = maxi(0, int(d.get("value", 0)))
	c.target = clampi(int(d.get("target", int(Targeting.NONE))), 0, 8)
	c.keywords = keywords_from_names(d.get("keywords", []))
	c.token_id = str(d.get("token_id", ""))
	c.deathrattle = clampi(int(d.get("deathrattle", int(EffectType.NONE))), 0, EFFECT_NAMES.size() - 1)
	c.deathrattle_id = str(d.get("deathrattle_id", ""))
	if c.deathrattle_id == "" and c.deathrattle > 0:
		c.deathrattle_id = LEGACY_EFFECT_IDS[c.deathrattle] if c.deathrattle < LEGACY_EFFECT_IDS.size() else ""
	elif c.deathrattle_id != "":
		var legacy_dr := LEGACY_EFFECT_IDS.find(c.deathrattle_id)
		if legacy_dr >= 0:
			c.deathrattle = clampi(legacy_dr, 0, EFFECT_NAMES.size() - 1)
	c.death_value = maxi(0, int(d.get("death_value", 0)))
	# 三个新键：缺省 → 空（老卡表 / 老存档照旧）；条目一律深拷贝
	c.effects = _read_chain(d.get("effects", []))
	c.deathrattle_effects = _read_chain(d.get("deathrattle_effects", []))
	var raw_skill: Variant = d.get("skill", {})
	if typeof(raw_skill) == TYPE_DICTIONARY:
		var raw_skill_dict: Dictionary = raw_skill
		c.skill = raw_skill_dict.duplicate(true)
	c.invocation = _read_invocation(d.get("invocation", {}))
	c.fusion = _read_fusion(d.get("fusion", {}))
	# 链非空时把老字段对齐到链首：AI / 界面 / 旧断言不需要认识新键
	c.sync_legacy_from_chains()
	c.is_token = bool(d.get("is_token", false))
	# 职业：老卡表 / 老存档没有这个键 → 中立（任何主战者都能带）
	var raw_class := str(d.get("class_id", NEUTRAL_CLASS)).strip_edges()
	c.class_id = raw_class if raw_class != "" else NEUTRAL_CLASS
	var raw_rarity := int(d.get("rarity", Rarity.COMMON))
	c.rarity = raw_rarity if (raw_rarity >= 0 and raw_rarity < RARITY_NAMES.size()) else Rarity.COMMON
	# 兵种：老卡表没有这个键 → ""（= 中立）；登记与否由 CardDB.troop_of() 读时归一
	c.troop_id = str(d.get("troop_id", "")).strip_edges()
	# 卡包：老卡表没有这个键 → ""（= 基础卡包）；登记与否由 CardDB.pack_of() 读时归一
	c.pack_id = str(d.get("pack_id", d.get("pack", ""))).strip_edges()
	# 主战者效果：老卡表没有这个键 → 空数组（不影响任何既有行为）
	c.leader_effects = []
	var raw_leader: Variant = d.get("leader_effects", [])
	if typeof(raw_leader) == TYPE_ARRAY:
		for e in raw_leader:
			var spec := LeaderEffects.normalized(e)
			if not spec.is_empty():
				c.leader_effects.append(spec)
	# 触发效果：老卡表没有这个键 → 空数组（不影响任何既有行为）
	c.triggers = []
	var raw_triggers: Variant = d.get("triggers", [])
	if typeof(raw_triggers) == TYPE_ARRAY:
		for e in raw_triggers:
			var ts := CardTriggers.normalized(e)
			if not ts.is_empty():
				c.triggers.append(ts)
	c.deck_limit = maxi(0, int(d.get("deck_limit", 0)))
	c.overload = maxi(0, int(d.get("overload", 0)))
	c.countdown = maxi(0, int(d.get("countdown", 0)))
	c.combo_effect_id = str(d.get("combo_effect_id", NO_EFFECT))
	c.combo_value = maxi(0, int(d.get("combo_value", 0)))
	c.spell_damage = maxi(0, int(d.get("spell_damage", 0)))
	c.art_path = str(d.get("art_path", ""))
	c.vfx = str(d.get("vfx", ""))
	c.description = str(d.get("description", d.get("desc", "")))
	var raw_color := str(d.get("color", ""))
	c.color = Color.html(raw_color) if raw_color.begins_with("#") else _default_color(c.card_type)
	return c


func to_dict() -> Dictionary:
	sync_legacy_from_chains()
	return {
		"id": id,
		"card_name": card_name,
		"cost": cost,
		"card_type": card_type,
		"attack": attack,
		"health": health,
		"effect": effect,
		"effect_id": effect_id,
		"value": value,
		"target": target,
		"keywords": keywords_to_names(keywords),
		"token_id": token_id,
		"deathrattle": deathrattle,
		"deathrattle_id": deathrattle_id,
		"death_value": death_value,
		"effects": _chain_to_dict(effects),
		"deathrattle_effects": _chain_to_dict(deathrattle_effects),
		"skill": skill.duplicate(true),
		"invocation": invocation.duplicate(true),
		"fusion": fusion.duplicate(true),
		"is_token": is_token,
		"class_id": class_id,
		"troop_id": troop_id,
		"pack_id": pack_id,
		"leader_effects": leader_effects,
		"triggers": _chain_to_dict(triggers),
		"rarity": rarity,
		"deck_limit": deck_limit,
		"overload": overload,
		"countdown": countdown,
		"combo_effect_id": combo_effect_id,
		"combo_value": combo_value,
		"spell_damage": spell_damage,
		"art_path": art_path,
		"vfx": vfx,
		"description": description,
		"color": "#" + color.to_html(false),
	}


static func _chain_to_dict(chain: Array) -> Array:
	var out: Array = []
	for e in chain:
		if typeof(e) == TYPE_DICTIONARY:
			var entry: Dictionary = e
			out.append(entry.duplicate(true))
	return out


## 深拷贝，保证同一张卡牌在牌库/手牌/战场中互不干扰。
func clone() -> CardData:
	var c := CardData.from_dict(to_dict())
	# 关键字按 **ID** 原样复制：to_dict / from_dict 走的是"名字 ↔ ID"往返，
	# 运行期赋予的、未登记名字的关键字（临时增益 / 测试探针）会在往返中丢失
	c.keywords = keywords.duplicate()
	return c


# ------------------------------ 效果链 ------------------------------
#
# 三种形态最后都归到「链」上：链非空 → 以链为准；链为空 → 老字段被包成**一条**效果。
# 因此老卡（只有 effect_id / deathrattle_id）走的还是和改动前逐字一致的代码路径。

## 战吼 / 法术 / 安放的效果链（深拷贝，调用方随便改）
func effect_chain() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in effects:
		out.append(e.duplicate(true))
	if not out.is_empty():
		return out
	if is_real_effect_id(effect_id):
		out.append({"id": effect_id, "value": value, "target": int(target), "token": token_id})
	return out


## 亡语的效果链（深拷贝）。
## 老卡的亡语没有单独的 target 字段（卡表的 target 属于战吼），目标一直由引擎按效果默认目标推导，
## 所以这里的包装条目用 CardEffects.default_target() 当目标 —— 与改动前的推导口径一致。
func deathrattle_chain() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in deathrattle_effects:
		out.append(e.duplicate(true))
	if not out.is_empty():
		return out
	if is_real_effect_id(deathrattle_id):
		out.append({"id": deathrattle_id, "value": death_value,
			"target": int(effects_registry().default_target(deathrattle_id)), "token": token_id})
	return out


## 主动技能的效果链（深拷贝；没有技能 → 空）
func skill_chain() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if skill.is_empty():
		return out
	var raw: Variant = skill.get("effects", [])
	if typeof(raw) != TYPE_ARRAY:
		return out
	for e in raw:
		if typeof(e) == TYPE_DICTIONARY:
			var entry: Dictionary = e
			out.append(entry.duplicate(true))
	return out


## 把一条链说成人话：「造成 2 点伤害；消灭目标随从」（每段用 CardEffects.text 生成）。
## 配了条件的条目自动加前缀：「若 本局该兵种进场数「士兵」≥ 3：造成 3 点伤害」
func chain_text(chain: Array) -> String:
	var parts := PackedStringArray()
	for e in chain:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var body: String = str(effects_registry().text(str(e.get("id", "")), int(e.get("value", 0)),
			int(e.get("src", 0)), int(e.get("turns", 0)), str(e.get("token", ""))))
		if body == "":
			continue
		var cond: Variant = e.get("cond", null)
		if typeof(cond) == TYPE_DICTIONARY:
			var cond_text := EffectConditions.text(cond)
			if cond_text != "":
				body = "若 %s：%s" % [cond_text, body]
		parts.append(body)
	return "；".join(parts)


## 旧版单一 token_id 字段：取链里第一条填了衍生物 ID 的条目（没有 → 空串）。
## 只有召唤类效果的 token 才是衍生物；随机能力（池 ID）、赋予技能 / 能力（来源卡牌）、
## 随机获得类（来源范围）同样共用 token 字段，不能当成衍生物写进老字段。
static func _first_token(battlecry: Array, deathrattle: Array) -> String:
	for chain in [battlecry, deathrattle]:
		for e in chain:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = e
			if not effects_registry().needs_token(str(entry.get("id", ""))):
				continue
			var tok := str(entry.get("token", "")).strip_edges()
			if tok != "":
				return tok
	return ""


## 老字段与效果链对齐（链不存在时什么都不做 —— 老卡表逐字保持原样）。
## 链是唯一事实来源：effect_id / value / target 是战吼链首的镜像，
## deathrattle_id / death_value 是亡语链首的镜像，token_id 取链里第一条填了衍生物的条目
## （与管理员面板写回时的口径一致）。
## 管理员面板改完链之后也可以主动调它，让老字段立刻与新链一致。
func sync_legacy_from_chains() -> void:
	var e_chain := effect_chain()
	var d_chain := deathrattle_chain()
	# ---- 战吼 / 法术（护符 = 安放）----
	if not effects.is_empty():
		var head := _first_effective(e_chain)
		if head.is_empty():
			# 链里全是「无效果」：老字段也清空，别让 AI / 界面读到一条不存在的效果
			effect_id = NO_EFFECT
			effect = EffectType.NONE
			value = 0
			target = Targeting.NONE
		else:
			effect_id = str(head.get("id", ""))
			value = maxi(0, int(head.get("value", 0)))
			target = clampi(_entry_target_kind(head), 0, 8)
			var legacy := LEGACY_EFFECT_IDS.find(effect_id)
			if legacy >= 0:
				effect = clampi(legacy, 0, EFFECT_NAMES.size() - 1)
	# ---- 亡语 ----
	if not deathrattle_effects.is_empty():
		var dr := _first_effective(d_chain)
		if dr.is_empty():
			deathrattle_id = NO_EFFECT
			deathrattle = EffectType.NONE
			death_value = 0
		else:
			deathrattle_id = str(dr.get("id", ""))
			death_value = maxi(0, int(dr.get("value", 0)))
			var legacy_dr := LEGACY_EFFECT_IDS.find(deathrattle_id)
			if legacy_dr >= 0:
				deathrattle = clampi(legacy_dr, 0, EFFECT_NAMES.size() - 1)
	# ---- 旧版单一 token_id：只有配了新链的卡才重算（老卡原样保留）----
	if not effects.is_empty() or not deathrattle_effects.is_empty():
		token_id = _first_token(e_chain, d_chain)


# ------------------------------ 常用查询 ------------------------------

func type_name() -> String:
	return TYPE_NAMES[card_type] if card_type >= 0 and card_type < TYPE_NAMES.size() else "未知"


## 稀有度名称（越界回落「未知」）
func rarity_name() -> String:
	return RARITY_NAMES[rarity] if rarity >= 0 and rarity < RARITY_NAMES.size() else "未知"


## 稀有度边框色（卡面 / 列表用）
func rarity_color() -> Color:
	return RARITY_COLORS[rarity] if rarity >= 0 and rarity < RARITY_COLORS.size() else Color("#b0bec5")


## 是否是随从
func is_minion() -> bool:
	return card_type == CardType.MINION


## 护符 / 城邦：上场后占战场一格、不能攻击、有耐久，可被伤害或被指定解掉
func is_permanent() -> bool:
	return card_type == CardType.AMULET or card_type == CardType.CITY


## 城邦：与护符同形，但整副牌组合计最多 CITY_DECK_LIMIT 张
func is_city() -> bool:
	return card_type == CardType.CITY


## 中立卡：任何主战者都能带。
## 注意：**没在职业表里登记的 ID 不在这里判断** —— 那要查 CardDB.hero_classes，
## 规则层不认识管理员数据（避免规则层 ↔ 数据层循环依赖）。
func is_neutral() -> bool:
	return class_id == "" or class_id == NEUTRAL_CLASS


## 是否需要占用战场格子的卡（随从 / 护符 / 城邦）——出牌与“战场已满”判定都用它
func is_board_card() -> bool:
	return is_minion() or is_permanent()


## 护符 / 城邦的耐久（沿用 health 字段：卡表里给护符填 health 就是耐久）
func durability() -> int:
	return maxi(1, health)


func effect_name() -> String:
	if effect_id != "":
		return str(effects_registry().display_name(effect_id))
	return EFFECT_NAMES[effect] if effect >= 0 and effect < EFFECT_NAMES.size() else "无"


## 这张牌的战吼 / 法术（护符 = 安放）里有没有有效效果
func has_effects() -> bool:
	for e in effect_chain():
		if is_real_effect_id(str(e.get("id", ""))):
			return true
	return false


## 兼容旧 API：老卡只看 effect_id，新卡看效果链（两种情况下语义都是“有战吼 / 法术效果”）
func has_effect() -> bool:
	return has_effects()


## 卡牌是否声明了某个机制（运行时随从请用 BoardUnit.has_mechanic）
func has_mechanic(k: Keyword) -> bool:
	return keywords.has(k)


## 这张牌有没有亡语（老卡看 deathrattle_id，新卡看亡语链）
func has_deathrattle() -> bool:
	for e in deathrattle_chain():
		if is_real_effect_id(str(e.get("id", ""))):
			return true
	return false


## 出牌时需要玩家主动选择的目标类型（链里按顺序、去重；群体 ALL_* 与无目标效果不算）
func effect_target_kinds() -> Array[int]:
	var out: Array[int] = []
	for e in effect_chain():
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if not is_real_effect_id(str(e.get("id", ""))):
			continue
		var kind := _entry_target_kind(e)
		if target_needs_selection(kind) and not out.has(kind):
			out.append(kind)
	if out.is_empty() and target_needs_selection(int(target)):
		out.append(int(target))          # 兜底：链为空时仍然看老字段
	return out


## 卡面 / 提示用的目标名（链里有需要选目标的效果时取第一条那种）
func target_name() -> String:
	var kinds := effect_target_kinds()
	if not kinds.is_empty():
		return TARGET_NAMES.get(kinds[0], "不需要目标")
	return TARGET_NAMES.get(target, "不需要目标")


func keyword_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k in keywords:
		out.append(keyword_name(k))
	return out


## 出牌时是否需要玩家指定目标：
##   * 老字段需要目标，或
##   * 效果链里存在需要选目标的效果（链的目标由 GameManager 逐条解析）。
## **亡语链与技能不算**：亡语的目标在触发时自动推导，技能的目标走 GameManager.get_valid_skill_targets()；
## 把它们算进来，会让“不需要目标的随从”变成必须先选个目标才能上场。
func needs_target() -> bool:
	if target_needs_selection(int(target)):
		return true
	for e in effect_chain():
		if typeof(e) != TYPE_DICTIONARY:
			continue
		if not is_real_effect_id(str(e.get("id", ""))):
			continue
		if target_needs_selection(_entry_target_kind(e)):
			return true
	return false


## 效果说明文本（由 CardEffects 注册表生成，新增效果自动拥有卡面文本）
func effect_text() -> String:
	return chain_text(effect_chain())


## 亡语说明文本（自动带“亡语：”前缀；多条用「；」连接）
func deathrattle_text() -> String:
	var body := chain_text(deathrattle_chain())
	return ("亡语：" + body) if body != "" else ""


# ------------------------------ 主动技能 ------------------------------

func has_skill() -> bool:
	return not skill.is_empty()


## 技能名（没填名字时回落「技能」）
func skill_name() -> String:
	var n := str(skill.get("name", "")).strip_edges()
	return n if n != "" else "技能"


## 发动技能要消耗的**现有能量点**（= 法力 / PP；0 = 免费）
func skill_cost() -> int:
	return maxi(0, int(skill.get("cost", 0)))


## 技能需要选的目标类型（>= 0 恒成立；不需要选目标 → CardData.Targeting.NONE）
func skill_target() -> int:
	if not has_skill():
		return Targeting.NONE
	var declared := int(skill.get("target", -1))
	if target_needs_selection(declared):
		return declared
	# 声明的目标不能用来选目标时：退回技能链里**第一条**需要选目标的条目
	for e in skill_chain():
		if not is_real_effect_id(str(e.get("id", ""))):
			continue
		var kind := _entry_target_kind(e)
		if target_needs_selection(kind):
			return kind
	return declared if declared >= 0 else Targeting.NONE


## 技能是不是每回合只能用一次（缺省 = true）
func skill_once_per_turn() -> bool:
	return bool(skill.get("once_per_turn", true))


# ------------------------------ 瞬念召唤 ------------------------------

## 读取瞬念召唤配置（安全读取 + 深拷贝；不是字典 → 空字典）。
## 「空字典 = 这张卡没有瞬念召唤」，引擎只认 `has_invocation()` 为真时才判定它。
## 这里**保留**未登记的条件 ID：坏数据不被静默吞掉，由 CardDB.config_errors() 报出来
## （admin 面板 / 手改 JSON 写错条件名时管理员能看见，而不是“配了却悄悄不生效”）。
## 融合数据归一：只认 {"enabled": true, ...}；缺省 / 关掉 → 空字典（老卡表完全不受影响）
static func _read_fusion(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var src: Dictionary = raw
	if not bool(src.get("enabled", false)):
		return {}
	var filter := {"troop": "", "type": -1, "cost_min": 0, "cost_max": 99}
	var raw_filter: Variant = src.get("filter", {})
	if typeof(raw_filter) == TYPE_DICTIONARY:
		var f: Dictionary = raw_filter
		filter = {
			"troop": str(f.get("troop", "")).strip_edges(),
			"type": int(f.get("type", -1)),
			"cost_min": maxi(0, int(f.get("cost_min", 0))),
			"cost_max": int(f.get("cost_max", 99)),
		}
	return {
		"enabled": true,
		"count": clampi(int(src.get("count", 1)), 1, 3),
		"filter": filter,
		"require": EffectConditions.normalized(src.get("require", {})),
		"effects": _read_chain(src.get("effects", [])),
		"gain": _read_chain(src.get("gain", [])),
		"transform": str(src.get("transform", "")).strip_edges(),
	}


static func _read_invocation(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var src: Dictionary = raw
	var out := src.duplicate(true)
	if out.is_empty():
		return {}          # 老卡表 / 没配瞬念召唤：保持「空字典 = 没有」这条唯一的判断口径
	out["enabled"] = bool(out.get("enabled", false))
	# 条件 = 一个要读的量 + 一个比较符（见 InvokeConditions 头注释，与 SV 同一套模型）。
	# 旧格式（把比较符焊在 ID 里的 "hand_at_least" 之类）在这里自动转成 「量 + 比较符」。
	var metric := str(out.get("metric", "")).strip_edges()
	var op := str(out.get("op", "")).strip_edges()
	if metric == "":
		var old := str(out.get("condition", "")).strip_edges()
		if old == "":
			return {}      # 既没有量也没有旧条件 = 确实没配
		var pair := InvokeConditions.legacy_metric_op(old)
		metric = pair[0]
		op = pair[1]
		out.erase("condition")
	if op == "":
		op = InvokeConditions.default_op(metric)
	out["metric"] = metric
	out["op"] = op
	out["value"] = int(out.get("value", 0))
	# 兵种类量要指定兵种：空 = 内置「中立」（老卡表没有这个键 → 走中立）
	out["troop"] = str(out.get("troop", "")).strip_edges()
	# 旧版还有「对手回合开始 / 结束」两种时机（那时瞬念召唤不挑回合），现在只在自己回合
	# 结算了：读到旧值就迁到对应的「我方回合」时机上（见 InvokeConditions.migrate_timing）。
	out["timing"] = InvokeConditions.migrate_timing(int(out.get("timing", 0)))
	# 瞬念召唤效果（可留空）：与战吼 / 亡语完全独立的一条效果链
	var fx: Variant = out.get("effects", [])
	out["effects"] = fx if typeof(fx) == TYPE_ARRAY else []
	# 基础机制（去向）：**必选**，越界 / 缺省一律回落 KEEP（留场）—— 老卡表因此保持原行为
	var dest := int(out.get("destination", InvokeDest.KEEP))
	if dest < 0 or dest >= INVOKE_DEST_NAMES.size():
		dest = InvokeDest.KEEP
	out["destination"] = dest
	return out


## 这张卡有没有配瞬念召唤（启用 + 量和比较符都已登记）
func has_invocation() -> bool:
	return bool(invocation.get("enabled", false)) \
		and InvokeConditions.has_metric(str(invocation.get("metric", ""))) \
		and InvokeConditions.has_op(str(invocation.get("op", "")))


## 要读的那个量（InvokeConditions.metrics() 之一）
func invoke_metric() -> String:
	return str(invocation.get("metric", ""))


## 比较符（InvokeConditions.OPS 之一）
func invoke_op() -> String:
	return str(invocation.get("op", ""))


func invoke_value() -> int:
	return int(invocation.get("value", 0))


## 兵种类触发条件要看哪个兵种（"" = 内置「中立」；普通量用不上这个键）
func invoke_troop() -> String:
	return str(invocation.get("troop", ""))


## 判定时真正要读的 key：兵种类量拼成 `量@兵种`（与 InvokeConditions.snapshot 一致）
func invoke_scoped_metric() -> String:
	return InvokeConditions.scope_key(invoke_metric(), invoke_troop())


## 触发时机（InvokeConditions.TIME_*；缺省 = 任意检查点）
func invoke_timing() -> int:
	return clampi(int(invocation.get("timing", InvokeConditions.TIME_ANY)),
		0, InvokeConditions.TIME_NAMES.size() - 1)


## ------------------------------ 瞬念召唤：效果（可空）与基础机制（去向，必选） ------------------------------

## 瞬念召唤效果链（深拷贝；与战吼 / 亡语完全独立）。没配 / 配空 → 空数组。
func invoke_effect_chain() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = invocation.get("effects", [])
	if typeof(raw) != TYPE_ARRAY:
		return out
	for e in raw:
		if typeof(e) == TYPE_DICTIONARY:
			out.append((e as Dictionary).duplicate(true))
	return out


## 瞬念召唤有没有配有效效果（空效果 = 只走基础机制）
func invoke_has_effects() -> bool:
	for e in invoke_effect_chain():
		if is_real_effect_id(str(e.get("id", ""))):
			return true
	return false


## 基础机制 = 应召后的去向（InvokeDest；越界回落 KEEP）
func invoke_dest() -> int:
	var d := int(invocation.get("destination", InvokeDest.KEEP))
	return d if d >= 0 and d < INVOKE_DEST_NAMES.size() else InvokeDest.KEEP


## 去向的名字（「留在场上」…）
func invoke_dest_name() -> String:
	return INVOKE_DEST_NAMES[invoke_dest()]


## 瞬念召唤效果的一行说明（没配 → 空串）
func invoke_effect_text() -> String:
	var names := PackedStringArray()
	for e in invoke_effect_chain():
		var eid := str(e.get("id", ""))
		if not is_real_effect_id(eid):
			continue
		names.append("%s(%d)" % [effects_registry().display_name(eid), int(e.get("value", 0))])
	return "、".join(names)


# ------------------------------ 融合 ------------------------------

func has_fusion() -> bool:
	return bool(fusion.get("enabled", false)) and not fusion.is_empty()


func fusion_count() -> int:
	return clampi(int(fusion.get("count", 1)), 1, 3)


func fusion_filter() -> Dictionary:
	var f: Variant = fusion.get("filter", {})
	return f if typeof(f) == TYPE_DICTIONARY else {}


## 融合的前置条件（与效果链条件同一套量；空 = 无前置条件）
func fusion_require() -> Dictionary:
	var r: Variant = fusion.get("require", {})
	if typeof(r) != TYPE_DICTIONARY:
		return {}
	return EffectConditions.normalized(r)


func fusion_effects() -> Array[Dictionary]:
	return _fusion_chain("effects")


func fusion_gain() -> Array[Dictionary]:
	return _fusion_chain("gain")


func fusion_transform() -> String:
	return str(fusion.get("transform", "")).strip_edges()


func _fusion_chain(key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = fusion.get(key, [])
	if typeof(raw) != TYPE_ARRAY:
		return out
	for e in raw:
		if typeof(e) == TYPE_DICTIONARY:
			out.append((e as Dictionary).duplicate(true))
	return out


## 卡面文本：「融合 1 张「士兵」；条件：…；获得：…」
func fusion_text() -> String:
	if not has_fusion():
		return ""
	var bits := PackedStringArray()
	var f := fusion_filter()
	var who := str(f.get("troop", ""))
	var who_name := who if who != "" else "手牌"
	var line := "融合 %d 张「%s」" % [fusion_count(), who_name]
	var t := int(f.get("type", -1))
	if t >= 0 and t < TYPE_NAMES.size():
		line += "（%s）" % TYPE_NAMES[t]
	bits.append(line)
	var req := fusion_require()
	if not req.is_empty():
		bits.append("条件：" + EffectConditions.text(req))
	var tr := fusion_transform()
	if tr != "":
		bits.append("化身为「%s」" % _card_name_by_id(tr))
	var gain := fusion_gain()
	if not gain.is_empty():
		bits.append("获得：" + chain_text(gain))
	return "；".join(bits)


## 通过场景树里的 CardDB 取卡名（CardData 不静态引用自动加载，避免启动顺序问题）
func _card_name_by_id(card_id: String) -> String:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var db = (loop as SceneTree).root.get_node_or_null("CardDB")
		if db != null:
			var c = db.get_card(card_id)
			if c != null:
				return str(c.card_name)
	return card_id


## 卡面文本：「瞬念召唤：我方手牌张数 ≤ 3（我方回合开始时）」。
## 兵种类条件带上兵种名：「瞬念召唤：本局该兵种进场数「士兵」≥ 3（任意时机）」。没配 → 空串。
func invoke_text() -> String:
	if not has_invocation():
		return ""
	var body := InvokeConditions.text(invoke_metric(), invoke_op(), invoke_value(), invoke_troop())
	var t := InvokeConditions.timing_name(invoke_timing())
	var text := "瞬念召唤：%s（%s）" % [body, t]
	# 应召之后：先结算「瞬念召唤效果」（可空），再走「基础机制」（去向，必选）
	if invoke_has_effects():
		text += "，效果：%s" % invoke_effect_text()
	if card_type == CardType.SPELL:
		# 法术不能上场：去向只有「直接发动 / 进入手牌」两种
		text += "，之后%s" % ("进入手牌" if invoke_dest() == InvokeDest.HAND else "直接发动")
	else:
		text += "，之后%s" % invoke_dest_name()
	return text


## 主战者效果的一行说明（多条用「；」连接；没配 → 空串）
func leader_effects_text() -> String:
	var parts := PackedStringArray()
	for e in leader_effects:
		var t := LeaderEffects.text(e)
		if t != "":
			parts.append(t)
	return "；".join(parts)


## 触发效果的一行说明（多条用「；」连接；没配 → 空串）
func triggers_text() -> String:
	var parts := PackedStringArray()
	for e in triggers:
		var t := CardTriggers.text(CardTriggers.normalized(e))
		if t != "":
			parts.append(t)
	return "；".join(parts)


## 这张卡有没有配触发效果（引擎据此决定要不要走触发结算，省掉无谓的遍历）
func has_triggers() -> bool:
	return not triggers.is_empty()


## 卡面正面显示的说明文字（多行）
func summary_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("%s（%s·%s）" % [card_name, rarity_name(), type_name()])
	if is_minion():
		lines.append("%d / %d" % [attack, health])
		var kn := keyword_names()
		if kn.size() > 0:
			lines.append(" ".join(kn))
		if has_effects():
			lines.append("战吼：" + effect_text())
		if has_deathrattle():
			lines.append(deathrattle_text())
	elif is_permanent():
		# 护符 / 城邦：没有攻击力，只有耐久
		lines.append("耐久 %d" % durability())
		var pkn := keyword_names()
		if pkn.size() > 0:
			lines.append(" ".join(pkn))
		if has_effects():
			var pline := effect_text()
			if needs_target():
				pline += "（%s）" % target_name()
			lines.append("安放：" + pline)
		if has_deathrattle():
			lines.append(deathrattle_text())
		if is_city():
			lines.append("城邦：每套牌组最多 %d 张" % CITY_DECK_LIMIT)
	else:
		if has_effects():
			var line := effect_text()
			if needs_target():
				line += "（%s）" % target_name()
			lines.append(line)
	# 主动技能：追加一行，形如「技能（花费 2 PP）：造成 3 点伤害」／0 费写作「技能（免费）：…」
	# （技能名单独由 skill_name() 提供，界面可以把它显示在标题 / 按钮上）
	if has_skill():
		var skill_body := chain_text(skill_chain())
		if skill_body != "":
			var cost_bit: String = "免费" if skill_cost() <= 0 else "花费 %d PP" % skill_cost()
			lines.append("技能（%s）：%s" % [cost_bit, skill_body])
	# 瞬念召唤：随从 / 护符 / 城邦应召上场；法术则在牌库 / 墓地直接发动或进入手牌
	if has_invocation():
		lines.append(invoke_text())
	# 融合：手牌里吃掉符合条件的手牌，然后获得效果 / 化身
	if has_fusion():
		lines.append("融合：" + fusion_text())
	# 触发效果：某个时机自动结算的链（入场 / 召唤 / 离场 / 瞬念召唤 / 消失 / 回合开始·结束）
	if has_triggers():
		var trg := triggers_text()
		if trg != "":
			lines.append("触发：" + trg)
	if description.strip_edges() != "":
		lines.append(description)
	return lines


static func keywords_from_names(raw: Variant) -> Array[int]:
	var out: Array[int] = []
	if raw == null:
		return out
	if typeof(raw) == TYPE_INT or typeof(raw) == TYPE_FLOAT:
		out.append(int(raw))
		return out
	for item in raw:
		if typeof(item) == TYPE_INT:
			out.append(int(item))
			continue
		var key := str(item)
		if _rt_keyword_keys.has(key):
			out.append(int(_rt_keyword_keys[key]))
			continue
		for k in KEYWORD_KEYS:
			if KEYWORD_KEYS[k] == key:
				out.append(k)
				break
	return out


static func keywords_to_names(list: Array[int]) -> PackedStringArray:
	var out := PackedStringArray()
	for k in list:
		var key := keyword_key(k)
		out.append(key if key != "" else str(k))
	return out


static func _default_color(t: int) -> Color:
	match t:
		CardType.MINION:
			return Color("#ffb74d")
		CardType.AMULET:
			return Color("#a1887f")
		CardType.CITY:
			return Color("#9575cd")
		_:
			return Color("#64b5f6")


static func _random_id() -> String:
	return "c%d" % (Time.get_unix_time_from_system() * 1000 + randi() % 1000)
