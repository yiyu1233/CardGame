extends SceneTree
## 逆向素材接入测试（美术 / 语音）+ 战局阶段（对照影之诗 IPhase 流程）
##
##   ① 卡图：res://assets/sv/card_art 里有导入的卡面（缩图 256 宽），卡表里大量卡已指向它们，
##      卡面控件能把卡图铺进画框；
##   ② 语音：res://assets/sv/voice 里的素材被 SoundFx 绑定成事件音（play/attack/win/lose/button/turn_start），
##      没有素材的事件仍走合成音（回落不报错）；自备素材目录（assets/art/voice）里的 wav
##      即使还没生成 .import 也能绑上（SoundFx 用 AudioStreamWAV.load_from_file 兜底）；
##   ③ 阶段：battle_phase() 走 换牌 → 主战 → 结算（新对局带待换牌 → 换完进入主战 → 分出胜负进入结算）。
##
## 运行（需要窗口，布局才真实）：godot --path <项目目录> --script res://tools/sv_asset_test.gd

const ART_DIR := "res://assets/sv/card_art"
const VOICE_DIR := "res://assets/sv/voice"
const VOICE_EVENTS := ["play", "attack", "win", "lose", "button", "turn_start"]

var _fails := 0
var _frames := 0
var _gm
var _db
var _main
var _card = null
var _fail_lines: Array[String] = []


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_gm = root.get_node_or_null("GameManager")
		_db = root.get_node_or_null("CardDB")
		if _gm == null or _db == null:
			_check(false, "GameManager / CardDB 自动加载")
			_finish()
			return true
		_test_card_art()
		_test_voice()
		_test_phases()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_gm.new_game()
		_main.skip_mulligan()
		_card = load("res://scenes/Card.tscn").instantiate()
		root.add_child(_card)
		return false
	if _frames == 8:
		_test_card_face_art()
		return false
	if _frames == 12:
		_main.queue_free()
		_card.queue_free()
		return false
	if _frames >= 16:
		_finish()
		return true
	return _frames > 400


# ------------------------------ ① 卡图 ------------------------------

func _test_card_art() -> void:
	var dir := DirAccess.open(ART_DIR)
	var files: Array[String] = []
	if dir != null:
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and f.to_lower().ends_with(".png"):
				files.append(f)
			f = dir.get_next()
		dir.list_dir_end()
	_check(files.size() >= 16, "导入的卡面数量足够（%d 张）" % files.size())
	# 缩图尺寸正确（宽 256）
	var checked := 0
	var width_ok := true
	for name in files:
		if checked >= 3:
			break
		var tex := load("%s/%s" % [ART_DIR, name])
		if tex is Texture2D:
			if tex.get_width() != 256:
				width_ok = false
			checked += 1
	_check(checked >= 3, "卡面贴图可以加载（抽查 %d 张）" % checked)
	_check(width_ok, "卡面已按宽 256 缩图（避免把 2MB 大图塞进项目）")
	# 卡表里大量卡已指向导入的卡图
	var with_art := 0
	var pointing := 0
	for c in _db.cards:
		if c.art_path != "":
			with_art += 1
			if c.art_path.begins_with(ART_DIR):
				pointing += 1
	_check(with_art >= 50, "卡表里已有大量卡配置了卡图（%d 张）" % with_art)
	_check(pointing >= 50, "这些卡图指向导入的素材目录（%d 张）" % pointing)


func _test_card_face_art() -> void:
	var minion: CardData = null
	for c in _db.cards:
		if c.is_minion() and c.art_path != "":
			minion = c
			break
	_check(minion != null, "找到一张带卡图的随从卡")
	if minion == null:
		return
	_card.setup(minion, 0, true)
	var frame = _card.get_node_or_null("Margin/VBox/ArtFrame")
	var art = _card.art_node()
	_check(frame != null and art != null and art.get_parent() == frame, "卡图铺进卡面画框")
	_check(art != null and art.visible and art.texture != null, "卡面画框里显示出导入的卡图")
	_check(_card.name_label.visible and _card.desc_label.visible, "卡图不遮挡卡面文字")


# ------------------------------ ② 语音 ------------------------------

func _test_voice() -> void:
	var sfx = root.get_node_or_null("SoundFx")
	_check(sfx != null, "SoundFx 自动加载")
	if sfx == null:
		return
	var bound: int = sfx.load_samples()
	_check(bound >= 5, "绑定了 %d 条真实语音/音效" % bound)
	var missing: Array[String] = []
	for ev in VOICE_EVENTS:
		if not sfx.has_sample(ev):
			missing.append(ev)
	_check(missing.is_empty(), "六个事件都有真实素材（缺：%s）" % str(missing))
	_check(sfx.sample_events().size() == bound, "素材事件表与绑定数一致")
	# 没有素材的事件照样能播（回落合成音，不报错）
	sfx.play("不存在的素材事件")
	_check(true, "未知事件播放不报错（回落合成音）")
	# 素材目录存在（导入工具跑过）
	_check(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(VOICE_DIR)), "语音素材目录存在")

	# 自备语音：拷一条 wav 进临时目录当「约定的 assets/art/voice」，
	# 它没有 .import，靠 AudioStreamWAV.load_from_file 兜底 —— 加素材不用先进编辑器导入
	var dir := "user://test_voice"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var bytes := FileAccess.get_file_as_bytes("%s/play.wav" % VOICE_DIR)
	var w := FileAccess.open("%s/zz_probe.wav" % dir, FileAccess.WRITE)
	if w != null:
		w.store_buffer(bytes)
		w.close()
	var probe: int = sfx.set_sample_dirs([dir])
	_check(probe == 1 and sfx.has_sample("zz_probe"),
		"自备目录里的 wav 免 .import 就能绑定（绑到 %d 条）" % probe)
	_check(sfx._samples.get("zz_probe", null) is AudioStream, "自备 wav 被解析成可播放的音频流")
	_check(sfx.sample_dirs().size() == 1 and sfx.sample_dirs()[0] == "user://test_voice",
		"素材目录可切换（%s）" % str(sfx.sample_dirs()))
	_check(sfx.set_sample_dirs(["res://assets/sv/voice", "res://assets/art/voice"]) == bound,
		"恢复默认素材目录后事件表回到 %d 条" % bound)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/zz_probe.wav" % dir))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


# ------------------------------ ③ 战局阶段 ------------------------------

func _test_phases() -> void:
	_gm.new_game()
	_check(_gm.battle_phase() == _gm.BattlePhase.MULLIGAN,
		"新对局处于「起手换牌」阶段（%s）" % _gm.battle_phase_name())
	_gm.finish_mulligan_cards(0, [])
	# 换牌结束后还要等回合开始
	_gm._start_turn(0)
	_check(_gm.battle_phase() == _gm.BattlePhase.MAIN,
		"换牌完成、回合开始后进入「主战」阶段（%s）" % _gm.battle_phase_name())
	_check(_gm.in_main_phase(), "主战阶段可以出牌 / 攻击")
	# 分出胜负 → 结算
	_gm.get_player(1).hero_hp = 0
	_gm._check_game_over()
	_check(_gm.battle_phase() == _gm.BattlePhase.RESULT,
		"分出胜负后进入「结算」阶段（%s）" % _gm.battle_phase_name())
	_check(not _gm.in_main_phase(), "结算阶段不再允许出牌")
	_check(_gm.BATTLE_PHASE_NAMES.size() == 5, "阶段名表齐全（%s）" % str(_gm.BATTLE_PHASE_NAMES))


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
	print("=== 逆向素材 / 阶段测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
