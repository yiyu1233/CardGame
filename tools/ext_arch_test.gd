extends SceneTree
## 扩展架构测试（外部插入机制 / 卡牌 / 美术 / 语音 / 特效）
##
## 覆盖：
##   ① 扩展包装载：mods/example 被扫描到，它的卡牌进了 CardDB（且**不写进存档**）；
##   ② 运行期关键字：CardData.register_keyword + Mechanics.register，卡表用 key 能读出来，
##      Mechanics.audit() 仍然干净（不会因为外部机制把自检搞红）；
##   ③ 运行期效果：CardEffects.register 之后能查到名字 / 文本，apply 不报错；
##   ④ 美术：扩展包登记的出牌特效有颜色 / 显示名；卡背贴图能被解析；
##   ⑤ 语音：CardVoice 的目录约定（按卡 id + 事件名）与回落行为；
##   ⑥ 表现层：BattleFx 的出牌 / 死亡 / 召唤 / 碎裂四种动画能创建并按时间结束；
##   ⑦ 新机制：影之诗「觉醒」，以及新增的两个触发时机 / 三个条件指标。
##
## 运行：godot --path <项目目录> --headless --script res://tools/ext_arch_test.gd

var _fails := 0
var _fail_lines: Array[String] = []
var _frames := 0
var _gm
var _db
var _mods
var _voice
var _fx
var _awaken_unit = null
var _fx_start_ms := 0


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		_mods = root.get_node_or_null("Mods")
		_voice = root.get_node_or_null("Voice")
		if _gm == null or _db == null or _mods == null or _voice == null:
			_check(false, "自动加载：GameManager / CardDB / Mods / Voice")
			_finish()
			return true
		_test_mods()
		_test_keywords()
		_test_effects()
		_test_art()
		_test_voice()
		_test_mechanics()
		_test_triggers_and_conditions()
		_test_battle_fx()
		return false
	if _frames == 4:
		_test_battle_fx_finished()
		_finish()
		return true
	return _frames > 2000000


# ------------------------------ ① 扩展包 ------------------------------

func _test_mods() -> void:
	_check(_mods.loaded_count >= 1, "扫描到扩展包（%d 个）" % _mods.loaded_count)
	_check(_mods.card_count >= 5, "扩展包带进来 %d 张卡" % _mods.card_count)
	var ids: Array = _mods.report().get("ids", [])
	_check(ids.has("example"), "示例扩展包 id 已登记（%s）" % str(ids))
	var c: CardData = _db.get_card("mod_pursuer")
	_check(c != null, "扩展包卡牌进了卡表（mod_pursuer）")
	if c != null:
		_check(c.card_name == "追猎者", "卡牌字段读取正确（%s）" % c.card_name)
		_check(c.keywords.has(CardData.MOD_KEYWORD_BASE + 1),
			"卡表里的关键字 key 被解析成运行期 ID（%s）" % str(c.keywords))
	# 扩展包卡牌不写进存档：让 CardDB 存一次，产物里不应出现它们
	_check(_db.mod_card_count() >= 5, "CardDB 记录了 %d 张扩展包卡牌" % _db.mod_card_count())
	_db.save_cards()
	_check(not _saved_contains("mod_pursuer"), "扩展包卡牌不写入 user://cards.json（卸载即消失）")
	# 再次从磁盘载入卡表，扩展包卡牌仍然在（不会因为刷新而丢）
	_db.load_cards()
	_check(_db.get_card("mod_pursuer") != null, "重载卡表后扩展包卡牌依然在")


func _saved_contains(needle: String) -> bool:
	var f := FileAccess.open("user://cards.json", FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	return text.contains(needle)


# ------------------------------ ② 运行期关键字 ------------------------------

func _test_keywords() -> void:
	var kid := CardData.MOD_KEYWORD_BASE + 1
	_check(CardData.keyword_name(kid) == "追击", "运行期关键字有中文名（%s）" % CardData.keyword_name(kid))
	_check(CardData.keyword_key(kid) == "pursuit", "运行期关键字有卡表 key（%s）" % CardData.keyword_key(kid))
	_check(CardData.has_keyword_key(kid), "has_keyword_key 认运行期关键字")
	var parsed := CardData.keywords_from_names(["pursuit", "taunt"])
	_check(parsed.has(kid) and parsed.has(CardData.Keyword.TAUNT),
		"卡表 key 同时能读出运行期与内置关键字（%s）" % str(parsed))
	_check(Mechanics.has(kid), "Mechanics 注册表里有它")
	_check(Mechanics.display_name(kid) == "追击", "机制显示名正确")
	var audit: Dictionary = Mechanics.audit()
	_check(bool(audit.get("ok", false)), "机制自检仍然干净（unkeyed=%s bad_hooks=%s）" % [
		str(audit.get("unkeyed", [])), str(audit.get("bad_hooks", []))])
	_check(CardData.runtime_keywords().has(kid), "运行期关键字清单里能列出它")


# ------------------------------ ③ 运行期效果 ------------------------------

func _test_effects() -> void:
	_check(CardEffects.has("mod_draw_heal"), "扩展包效果已登记")
	_check(CardEffects.display_name("mod_draw_heal") == "抽牌并治疗",
		"效果显示名正确（%s）" % CardEffects.display_name("mod_draw_heal"))
	var t := CardEffects.text("mod_draw_heal", 2)
	_check(t.contains("2"), "效果文本带上了数值（%s）" % t)
	# 真实跑一次：抽牌并回血
	_gm.new_game()
	_gm.finish_mulligan_cards(0, [])
	_gm.finish_mulligan_cards(1, [])
	var p = _gm.get_player(0)
	var before_hand: int = p.hand.size()
	p.hero_hp = 20
	var ctx = load("res://scripts/EffectContext.gd").new()
	ctx.gm = _gm
	ctx.caster_pid = 0
	ctx.value = 2
	CardEffects.apply("mod_draw_heal", ctx)
	_check(p.hand.size() > before_hand, "扩展包效果真的抽到了牌（%d → %d）" % [before_hand, p.hand.size()])
	_check(p.hero_hp == 22, "扩展包效果真的回了血（20 → %d）" % p.hero_hp)


# ------------------------------ ④ 美术 ------------------------------

func _test_art() -> void:
	_check(ArtStore.vfx_display("starlight") == "星辰", "扩展包特效有显示名")
	_check(ArtStore.vfx_color("starlight").is_equal_approx(Color("#7dd3fc")),
		"扩展包特效颜色生效（%s）" % ArtStore.vfx_color("starlight").to_html(false))
	_check(ArtStore.vfx_options().has("starlight"), "特效下拉里出现扩展包特效")
	_check(ArtStore.card_back_texture() != null, "卡背贴图可用（牌堆 / 敌方手牌共用）")
	_check(ArtStore.card_art_map().size() >= 50, "卡图映射表已载入（%d 条）" % ArtStore.card_art_map().size())
	var mapped := ArtStore.default_card_art("c001")
	_check(mapped != "", "按卡 id 能解析出专属卡图（c001 → %s）" % mapped.get_file())
	# 旧存档：卡图被自动分配成「循环复用的那 24 张」之一 → 载入时会被重新钉回映射表里那张
	var older: String = ""
	for c in _db.cards:
		if c.id != "c001" and c.art_path.begins_with(ArtStore.SV_CARD_ART_DIR):
			older = c.art_path
			break
	if older != "":
		var card: CardData = _db.get_card("c001")
		card.art_path = older
		_db.apply_default_art()
		_check(card.art_path == ArtStore.card_art_map().get("c001", ""),
			"旧存档里循环复用的卡图会被重新钉回专属图（%s → %s）" % [
				older.get_file(), str(card.art_path).get_file()])


# ------------------------------ ⑤ 语音 ------------------------------

func _test_voice() -> void:
	_check(_voice.has_method("play_or"), "CardVoice 提供 play_or（语音优先、通用音效兜底）")
	_check(_voice.candidates("c001", "play").size() == 0,
		"没有语音素材的卡候选为空（不报错）")
	var sfx = root.get_node_or_null("SoundFx")
	var before: int = sfx.sample_plays
	var ok: bool = _voice.play_or("play", "c001", "button")
	_check(not ok, "没有卡牌语音时 play_or 返回 false（已回落通用音效）")
	_check(sfx.sample_plays > before, "回了落到通用音效素材（SoundFx.sample_plays %d → %d）" % [before, sfx.sample_plays])
	var settings = root.get_node_or_null("GameSettings")
	_check(_voice.is_enabled() == bool(settings.card_voice),
		"卡牌语音开关跟随设置（card_voice=%s）" % str(settings.card_voice))
	# 约定目录：临时造一个 mods 风格的卡语音目录，验证命名规则能被扫到
	var dir := "user://test_card_voice/modx"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var src_bytes := FileAccess.get_file_as_bytes("res://assets/sv/voice/attack.wav")
	for name in ["play.wav", "attack.wav", "attack_01.wav", "attack_02.wav"]:
		var w := FileAccess.open("%s/%s" % [dir, name], FileAccess.WRITE)
		if w != null:
			w.store_buffer(src_bytes)
			w.close()
	_voice.add_card_dir("user://test_card_voice")
	_check(_voice.candidates("modx", "attack").size() == 3,
		"同一事件的多个文件都进候选（%d 个）" % _voice.candidates("modx", "attack").size())
	_check(_voice.has_voice("modx", "play"), "按「卡 id / 事件名」找到语音")
	_check(_voice.play("modx", "attack"), "卡牌语音真的能播")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_card_voice/modx"))


# ------------------------------ ⑥ 表现层 ------------------------------

func _test_battle_fx() -> void:
	_fx = load("res://scripts/BattleFx.gd").new()
	root.add_child(_fx)
	_check(_fx != null and _fx.speed == 1.0, "BattleFx 实例化（速度 = 1.0）")
	var card: CardData = _db.get_card("mod_pursuer")
	_fx.speed = 1.0
	_fx.play_card(Vector2(100, 100), Vector2(400, 300), card)
	_check(_fx.animating() and _fx.active_effects() == 1, "出牌飞牌动画已创建")
	_check(_fx.last_kind() == "play", "最近一次动画是出牌（%s）" % _fx.last_kind())
	_fx.death(Vector2(400, 300), Vector2(104, 132), card)
	_fx.summon(Vector2(500, 300), Vector2(104, 132))
	_fx.burst(Vector2(300, 300), Vector2(104, 132), Color.RED)
	_check(_fx.active_effects() == 4, "死亡 / 召唤 / 碎裂都能叠加播放（%d 个）" % _fx.active_effects())
	# 速度为 0（设置里「动画立即完成」）时不创建任何动画
	var fx2 = load("res://scripts/BattleFx.gd").new()
	fx2.speed = 0.0
	root.add_child(fx2)
	fx2.death(Vector2.ZERO, Vector2(10, 10), card)
	_check(fx2.active_effects() == 0, "动画速度 0 时不播动画（不卡流程）")
	fx2.queue_free()


func _test_battle_fx_finished() -> void:
	if _fx == null or not is_instance_valid(_fx):
		return
	# 动画用绝对时钟推进：这里把时间往前拨到超过最长的一段（死亡 0.55s），验证自动清空
	_check(_fx.animating(), "拨表之前动画还在播（%d 个）" % _fx.active_effects())
	_fx.advance_for_test(1.0)
	_check(not _fx.animating(), "动画播完后自动清空（残留 %d 个）" % _fx.active_effects())
	_fx.queue_free()


# ------------------------------ ⑦ 新机制 / 触发时机 / 条件 ------------------------------

func _test_mechanics() -> void:
	_check(Mechanics.has(CardData.Keyword.AWAKEN), "「觉醒」机制已注册")
	_check(Mechanics.display_name(CardData.Keyword.AWAKEN) == "觉醒", "觉醒显示名正确")
	_check(Mechanics.has_hook(CardData.Keyword.AWAKEN, "on_turn_start")
		and Mechanics.has_hook(CardData.Keyword.AWAKEN, "on_damaged"),
		"觉醒挂了两个钩子（回合开始 / 受到伤害）")
	_check(_gm.mod_state is Dictionary, "GameManager 给扩展包留了状态袋 mod_state")
	_check(_gm.has_method("heal_player"), "新增了与 damage_player 对称的 heal_player")
	_check(_gm.has_signal("unit_attacked") and _gm.has_signal("unit_summoned"),
		"新增表现层用的 unit_attacked / unit_summoned 信号")
	# 觉醒真的生效：把主战者打到 10 点，场上的觉醒随从 +1/+1，且不重复叠加
	_gm.new_game()
	_gm.finish_mulligan_cards(0, [])
	_gm.finish_mulligan_cards(1, [])
	var card: CardData = _db.get_card("mod_awakened_guard")
	_check(card != null, "卡表里有觉醒示例卡")
	if card == null:
		return
	var u: BoardUnit = _gm.summon_unit(0, card)
	_check(u != null, "觉醒随从上场")
	if u == null:
		return
	_awaken_unit = u
	var p = _gm.get_player(0)
	p.hero_hp = 20
	Mechanics.dispatch(u, "on_turn_start", {"gm": _gm, "unit": u, "pid": 0, "source": u})
	_check(u.attack == 2 and u.health == 3, "未到觉醒线时不加身材（%d/%d）" % [u.attack, u.health])
	p.hero_hp = 10
	Mechanics.dispatch(u, "on_turn_start", {"gm": _gm, "unit": u, "pid": 0, "source": u})
	_check(u.attack == 3 and u.health == 4, "主战者生命 ≤ 10 → 觉醒 +1/+1（%d/%d）" % [u.attack, u.health])
	Mechanics.dispatch(u, "on_damaged", {"gm": _gm, "unit": u, "target": u, "amount": 1, "source": null})
	_check(u.attack == 3 and u.health == 4, "觉醒只结算一次，不会重复叠加（%d/%d）" % [u.attack, u.health])


func _test_triggers_and_conditions() -> void:
	_check(CardTriggers.has_event(CardTriggers.EV_ATTACK), "新增触发时机：攻击时")
	_check(CardTriggers.has_event(CardTriggers.EV_DAMAGED), "新增触发时机：受到伤害时")
	_check(CardTriggers.event_label(CardTriggers.EV_ATTACK) == "攻击时",
		"触发时机有中文名（%s）" % CardTriggers.event_label(CardTriggers.EV_ATTACK))
	_check(EffectConditions.has_metric("own_hero_hp"), "新增条件指标：我方主战者生命")
	_check(EffectConditions.has_metric("deck_count"), "新增条件指标：我方牌库张数")
	_check(EffectConditions.has_metric("board_count"), "新增条件指标：我方场上单位数")
	# 条件判定：主战者生命 ≤ 10 在 10 点时为真、20 点时为假
	var cond := {"metric": "own_hero_hp", "op": "<=", "value": 10}
	var p = _gm.get_player(0)
	p.hero_hp = 10
	_check(EffectConditions.met(_gm, 0, cond), "条件「我方主战者生命 ≤ 10」在 10 点时成立")
	p.hero_hp = 20
	_check(not EffectConditions.met(_gm, 0, cond), "条件在同一条不成立时不触发")


# ------------------------------ 断言 ------------------------------

func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK]   " + description)
	else:
		_fails += 1
		_fail_lines.append(description)
		print("[FAIL] " + description)


func _finish() -> void:
	if not _fail_lines.is_empty():
		print("--- 失败项汇总 ---")
		for d in _fail_lines:
			print("  * " + d)
	print("=== 扩展架构测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
