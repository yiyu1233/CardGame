
extends RefCounted
## ============================ 鏈哄埗锛堝叧閿瓧锛夋€昏〃 ============================
##
## 銆愭柊澧炰竴涓満鍒讹紝鍙渶瑕佹敼涓や釜鍦版柟銆?##   鈶?鍦?`CardData.Keyword` 鏋氫妇閲屽姞涓€涓?ID锛堜緥濡?`STALWART = 11`锛夛紱
##   鈶?鍦ㄦ湰鏂囦欢搴曢儴鐨勩€屾柊澧炴満鍒跺氨鍦ㄨ繖閲屽姞銆嶅尯鍧楅噷鍔?*涓€琛?* `_reg(...)`銆?## 鍗¤〃 JSON 鐨?`keywords` 鍐欏搴旂殑 key锛堝 `"stalwart"`锛夊嵆鍙敓鏁堬紝骞惰鍦?## `CardData.KEYWORD_NAMES` / `KEYWORD_KEYS` 鍚勮ˉ涓€琛岋紙鍗￠潰鏂囧瓧涓庤鍙栫敤锛夈€?##
## 鑻ヨ繖涓満鍒跺彧鏄€岄檺鍒?/ 鍏嶇柅 / 涓嶈兘鏀诲嚮銆嶈繖绫?*甯冨皵瑙勫垯**锛岀浜屾灏卞浜嗭細
## 鍦?`_reg(...)` 鐨?`flags` 閲屽啓鏍囧織鍚嶏紝寮曟搸浼氬湪瀵瑰簲鍒ゅ畾鐐硅嚜鍔ㄧ敓鏁堬紝**涓嶇敤鏀瑰紩鎿?*锛?##   cannot_attack      鏃犳硶鏀诲嚮
##   no_attack_cost     鏀诲嚮涓嶆秷鑰楁湰鍥炲悎鏀诲嚮娆℃暟
##   untargetable_by_foe 涓嶈兘琚晫鏂规寚瀹氫负鐩爣锛堣嚜宸变汉 / 缇や綋鏁堟灉鐓у父锛?##   immune_damage      鍏嶇柅鎵€鏈変激瀹?##   only_one_damage    鍙楀埌鐨勪换浣曚激瀹冲噺涓?1
##
## 鑻ユ満鍒堕渶瑕?*涓诲姩鍋氫簨**锛堜緥锛氬惛琛€銆佸墽姣掋€佹浜″娲伙級锛屽啀鍐欎竴涓挬瀛愬嚱鏁板苟鎸備笂锛?##   modify_damage        浼ゅ缁撶畻鍓嶄慨姝ｆ暟鍊硷紙ev.amount 鍙敼鍐欙級
##   on_damage_dealt      鎴戞柟閫犳垚浼ゅ涔嬪悗锛堝惛琛€ / 鍓ф瘨锛?##   on_damaged           鎴戞柟鍙楀埌浼ゅ涔嬪悗锛堟縺鎬掞級
##   on_heal              鎴戞柟琚不鐤楀悗
##   on_death             鎴戞柟姝讳骸鏃讹紙浜¤鐢?CardEffects 璐熻矗锛屼簩鑰呭彲骞跺瓨锛?##   on_attack            鎴戞柟鍙戣捣鏀诲嚮鏃讹紙娼滆瑙ｉ櫎锛?##   on_turn_start        鎴戞柟鍥炲悎寮€濮?##   can_be_targeted      鏌ヨ鍨嬶細鑳藉惁琚€滄寚瀹氫负鐩爣鈥濓紙ev.allowed 鍙敼鍐欙級
##
## 浜嬩欢 `ev`锛堝瓧鍏革級甯哥敤閿細
##   gm / source / source_pid / target / target_pid / amount / keyword /
##   unit锛堣鏌ヨ鐨勯殢浠庯級/ by_pid锛堟兂鎸囧畾鐩爣鐨勭帺瀹讹級/ allowed锛堟煡璇㈢粨鏋滐級
##
## 闄ゆ涔嬪杩樻湁涓€寮?*浜掓枼琛?*锛氫袱涓満鍒跺悓鏃舵寕鍦ㄤ竴涓崟浣嶈韩涓婁細浜掔浉鎷嗗彴銆佸叾涓竴涓鍙︿竴涓?## 褰诲簳澶辨晥鐨勭粍鍚堬紙渚嬪娼滆 vs 鍢茶銆佽繜閽?vs 鍐查攱锛夈€傚紩鎿庣殑鍙ｅ緞鏄?## **鍚庣粰浜堢殑鏁堟灉瑕嗙洊鍐茬獊鐨勯偅涓?*锛氳祴浜堜竴涓満鍒舵椂锛屽厛鎶婂畠韬笂涓庡畠浜掓枼鐨勬棫鏈哄埗鎽樻帀
## 锛堣 `Mechanics.conflicts_of()`銆乣BoardUnit.add_keyword()`銆乣EffectContext.grant_keyword()`锛夈€?## 娉ㄦ剰杩欐潯鍙**杩愯鏃惰璧嬩簣**鐨勬晥鏋滄垚绔嬶紱涓€寮犲崱鑷繁鍗扮潃涓や釜浜掓枼璇嶆潯娌℃湁鍏堝悗涔嬪垎锛屼繚鎸佸師鏍枫€?##
## 鑷锛歚Mechanics.audit()` 浼氭瘮瀵广€屾灇涓?/ 娉ㄥ唽琛?/ 鍚嶇О琛?/ key 琛ㄣ€嶆槸鍚︿竴鑷达紝
## 娴嬭瘯 `tools/mechanics_api_test.gd` 浼氭柇瑷€瀹冩槸骞插噣鐨勨€斺€旀紡娉ㄥ唽浼氳褰撳満鎶撲綇銆?## ============================================================================

## 澹版槑寮忔爣蹇椾綅锛堝紩鎿庤鍙栵紱瑙佹枃浠跺ご璇存槑锛?const FLAG_CANNOT_ATTACK := "cannot_attack"
const FLAG_NO_ATTACK_COST := "no_attack_cost"
const FLAG_UNTRACKABLE := "untargetable_by_foe"
const FLAG_IMMUNE := "immune_damage"
const FLAG_ONLY_ONE_DAMAGE := "only_one_damage"

## 鏍囧織浣?鈫?涓枃璇存槑锛堟枃妗?/ 鑷杈撳嚭鐢級
const FLAG_DESCS := {
	FLAG_CANNOT_ATTACK: "鏃犳硶鏀诲嚮",
	FLAG_NO_ATTACK_COST: "鏀诲嚮涓嶆秷鑰楁湰鍥炲悎鐨勬敾鍑绘鏁?,
	FLAG_UNTRACKABLE: "涓嶈兘琚晫鏂规寚瀹氫负鐩爣",
	FLAG_IMMUNE: "鍏嶇柅鎵€鏈変激瀹?,
	FLAG_ONLY_ONE_DAMAGE: "鍙楀埌鐨勪换浣曚激瀹冲噺涓?1",
}

static var _registry: Dictionary = {}
static var _order: Array[int] = []
## 浜掓枼琛細`鏈哄埗 -> 涓庡畠浜掓枼鐨勬満鍒跺垪琛╜锛堝绉帮紝瑙?`_reg_conflict`锛?static var _conflicts: Dictionary = {}
## 銆岀姸鎬併€嶅眰闈㈢殑浜掓枼锛氬喕缁撲笉鏄瘝鏉★紙涓嶈兘杩涗笂闈㈢殑琛級锛屼絾鍚屾牱浼氫笌鏌愪簺鏈哄埗浜掔浉鎷嗗彴銆?## 鍐荤粨 = 鍒版煇涓€鍥炲悎涓烘涓嶈兘鏀诲嚮 鈫?鍐查攱 / 绐佽 = 褰撳洖鍚堝氨鑳芥敾鍑?鈥斺€?鍚庡埌鑰呰鐩栥€?const STATUS_FROZEN := "frozen"

static func _ensure() -> void:
	if _registry.is_empty():
		_register()

## 鐧昏涓€瀵逛簰鏂ョ殑鏈哄埗锛堜袱杈归兘鑳芥煡鍒帮級
static func _reg_conflict(a: int, b: int) -> void:
	if a == b:
		return
	for pair in [[a, b], [b, a]]:
		var k: int = pair[0]
		var other: int = pair[1]
		if not _conflicts.has(k):
			_conflicts[k] = []
		var list: Array = _conflicts[k]
		if not list.has(other):
			list.append(other)

static func _reg(keyword: int, display: String, desc: String, hooks: Dictionary = {},
		flags: Array = []) -> void:
	_registry[keyword] = {
		"keyword": keyword,
		"name": display,
		"desc": desc,
		"hooks": hooks,
		"flags": flags,
	}
	if not _order.has(keyword):
		_order.append(keyword)

## 杩愯鏈熸敞鍐岋紙娴嬭瘯 / 澶栨寕妯″潡鍙敤锛涙甯告満鍒惰鍐欏湪涓嬫柟鍖哄潡閲岋級
static func register(keyword: int, display: String, desc: String, hooks: Dictionary = {},
		flags: Array = []) -> void:
	_ensure()
	if _registry.has(keyword):
		_order.erase(keyword)
	_reg(keyword, display, desc, hooks, flags)
	_order.append(keyword)

# ============================ 鏂板鏈哄埗灏卞湪杩欓噷鍔?============================
#
# 涓€琛屼竴涓細_reg(CardData.Keyword.XXX, "涓枃鍚?, "璇存槑", {閽╁瓙...}, [鏍囧織...])
#
static func _register() -> void:
	# ---- 鑷韩鐘舵€佸瀷锛堝垽瀹氬疄鐜板湪 BoardUnit 閲岋紝杩欓噷鍙櫥璁板悕绉颁笌璇存槑锛?---
	_reg(CardData.Keyword.TAUNT, "鍢茶", "鏁屾柟蹇呴』鍏堟敾鍑诲畠銆?)
	_reg(CardData.Keyword.CHARGE, "鍐查攱", "鍙敜褰撳洖鍚堝嵆鍙敾鍑伙紝涔熻兘鎵撹嫳闆勩€?)
	_reg(CardData.Keyword.RUSH, "绐佽", "鍙敜褰撳洖鍚堝嵆鍙敾鍑婚殢浠庯紝浣嗕笉鑳芥墦鑻遍泟銆?)
	_reg(CardData.Keyword.DIVINE_SHIELD, "鍦ｇ浘", "鍏嶇柅涓嬩竴娆′激瀹冲悗娑堝け銆?)
	_reg(CardData.Keyword.WINDFURY, "椋庢€?, "姣忓洖鍚堝彲浠ユ敾鍑讳袱娆°€?)

	# ---- 澹版槑寮忥細鍙啓鏍囧織浣嶏紝寮曟搸鑷姩鐢熸晥 ----
	_reg(CardData.Keyword.STEALTH, "娼滆", "鏃犳硶琚晫鏂规寚瀹氫负鐩爣锛涙敾鍑诲悗瑙ｉ櫎銆?,
		{"on_attack": Mechanics._hook_break_stealth}, [FLAG_UNTRACKABLE])
	_reg(CardData.Keyword.STALWART, "鍧氬", "鍙楀埌鐨勪换浣曚激瀹冲噺涓?1銆?, {}, [FLAG_ONLY_ONE_DAMAGE])
	_reg(CardData.Keyword.SLUGGISH, "杩熼挐", "鏃犳硶鏀诲嚮銆?, {}, [FLAG_CANNOT_ATTACK])

	# ---- 闇€瑕侀挬瀛愶細鏁板€?/ 瑙﹀彂鍨?----
	_reg(CardData.Keyword.LIFESTEAL, "鍚歌", "閫犳垚浼ゅ鍚庯紝涓轰綘鐨勮嫳闆勬仮澶嶇瓑閲忕敓鍛姐€?,
		{"on_damage_dealt": Mechanics._hook_lifesteal})
	_reg(CardData.Keyword.POISONOUS, "鍓ф瘨", "鍙楀埌瀹冧激瀹崇殑闅忎粠浼氳娑堢伃銆?,
		{"on_damage_dealt": Mechanics._hook_poisonous})

	# ---- 鐢卞紩鎿庡湪鍥哄畾浣嶇疆璇诲彇锛堟棤閽╁瓙锛?---
	_reg(CardData.Keyword.REBORN, "澶嶇敓", "绗竴娆℃浜℃椂浼氫互 1 鐐圭敓鍛藉洖鍒版垬鍦猴紙浜¤鐓у父缁撶畻涓€娆★級銆?)
	_reg(CardData.Keyword.SPELL_DAMAGE, "娉曟湳浼ゅ", "娉曟湳浼ゅ +N锛氫綘鐨勪激瀹虫€ф硶鏈澶栭€犳垚 N 鐐逛激瀹筹紙澶氬紶鍙犲姞锛夈€?)

	# ---- 浜掓枼锛氬悓鏃跺涔熸棤鎰忎箟锛岃繍琛屾椂琚祴浜堟椂**鍚庡埌鑰呰鐩?*鍏堝埌鐨勯偅涓€鏂?----
	_reg_conflict(CardData.Keyword.STEALTH, CardData.Keyword.TAUNT)      # 涓嶈兘琚墦 vs 蹇呴』琚墦
	_reg_conflict(CardData.Keyword.SLUGGISH, CardData.Keyword.CHARGE)    # 涓嶈兘鏀诲嚮 vs 褰撳洖鍚堣兘鏀诲嚮
	_reg_conflict(CardData.Keyword.SLUGGISH, CardData.Keyword.RUSH)      # 鍚屼笂锛堜篃搴斾簰鏂ワ級

# ============================ 浠ヤ笂涓哄敮涓€闇€瑕佹墜鏀圭殑鍖哄潡 ============================

# ============================ 瀵瑰鎺ュ彛 ============================

static func keywords() -> Array[int]:
	_ensure()
	return _order.duplicate()

static func has(keyword: int) -> bool:
	_ensure()
	return _registry.has(keyword)

static func display_name(keyword: int) -> String:
	_ensure()
	return str(_registry.get(keyword, {}).get("name", "鏈煡鏈哄埗"))

static func describe(keyword: int) -> String:
	_ensure()
	return str(_registry.get(keyword, {}).get("desc", ""))

static func has_hook(keyword: int, hook: String) -> bool:
	_ensure()
	var hooks: Dictionary = _registry.get(keyword, {}).get("hooks", {})
	return hooks.has(hook)