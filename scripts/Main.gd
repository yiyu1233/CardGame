extends MarginContainer
## 对战主界面：渲染双方英雄 / 战场 / 手牌，并处理“选中 → 指定目标”的操作流程。

const CARD_SCENE := preload("res://scenes/Card.tscn")
## 卡面 / 牌背样式的唯一来源（手牌、敌方卡背、抽牌堆共用一套设计）
const CardSkin := preload("res://scripts/CardSkin.gd")
## 战斗表现层（出牌飞牌 / 随从死亡消失 / 召唤登场）
const BattleFxScript := preload("res://scripts/BattleFx.gd")

## 交互状态。**枚举值只能往后追加**：IDLE=0 / CARD_TARGET=1 / ATTACK_TARGET=2 已有测试写死，
## SKILL_TARGET（= 3）= 点了带主动技能的单位、正等玩家为技能挑目标。
enum Mode { IDLE, CARD_TARGET, ATTACK_TARGET, SKILL_TARGET }

@onready var side_label: Label = $Root/Arena/TopBar/SideLabel
@onready var restart_button: Button = $Root/Arena/TopBar/RestartButton
@onready var admin_button: Button = $Root/Arena/TopBar/AdminButton
@onready var admin_status: Label = $Root/Arena/TopBar/AdminStatus
@onready var settings_button: Button = $Root/Arena/TopBar/SettingsButton
@onready var arena_panel: PanelContainer = $Root/Arena/ArenaPanel
@onready var enemy_half: VBoxContainer = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf
@onready var enemy_hero_frame: HeroFrame = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHeroBox/EnemyHeroFrame
@onready var enemy_status_panel: StatusPanel = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHeroBox/EnemyStatusPanel
@onready var enemy_hand_row: Control = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHandRow
@onready var enemy_board: BoardSurface = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyBoardRow
## 主战者旁的城邦格（不占 7 格战场）
@onready var enemy_city_slot: Control = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/EnemyHalf/EnemyHeroBox/EnemyCitySlot
@onready var player_half: VBoxContainer = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf
@onready var player_hero_frame: HeroFrame = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerHeroBox/PlayerHeroFrame
@onready var player_status_panel: StatusPanel = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerHeroBox/PlayerStatusPanel
@onready var player_board: BoardSurface = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerBoardRow
## 主战者旁的城邦格（不占 7 格战场）
@onready var player_city_slot: Control = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/PlayerHeroBox/PlayerCitySlot
@onready var mid_seam: Panel = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/MidLine/SeamLine
@onready var mid_label: Label = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/MidLine/MidLabel
@onready var hint_label: Label = $Root/Arena/ActionBar/HintLabel
@onready var concede_button: Button = $Root/Arena/TopBar/ConcedeButton
@onready var hand_area: Control = $Root/Arena/ArenaPanel/ArenaMargin/ArenaVBox/PlayerHalf/HandArea
@onready var log_panel: PanelContainer = $Root/LogPanel
@onready var log_label: RichTextLabel = $Root/LogPanel/LogMargin/LogVBox/LogLabel
@onready var drag_layer: CanvasLayer = $DragLayer
@onready var card_detail: CardDetail = $DragLayer/CardDetail

const CARD_W := 118.0
const CARD_H := 170.0
const ENEMY_CARD_W := 30.0    ## 敌方手牌卡背宽度（我方手牌的镜像缩小版）
## 高度按**手牌卡的宽高比**（`CardSkin.CARD_RATIO = 118/170`）→ 30 / 0.694 ≈ 43.2，
## 卡背样式（底色 / 描边 / 圆角比例）也取自 `CardSkin`，与抽牌堆的牌背同一套设计。
const ENEMY_CARD_H := 43.2
const ENEMY_ARC_K := 200.0    ## 敌方手牌弧线曲率（与我方手牌方向相反）
const ENEMY_HAND_MARGIN := 14.0        ## 敌方手牌靠左上角摆放，留出的左边距
const ENEMY_MIN_VISIBLE := 11.0        ## 敌方卡背之间至少露出这么宽（一叠牌的「厚度」感）
const ENEMY_HAND_FAN_MAX := 20.0       ## 敌方手牌扇形角度上限（度）
const ENEMY_HAND_ARC := 9.0            ## 敌方手牌弧高（像素；镜像的弧线朝下凸）
const LOG_MAX_CHARS := 20000  ## 战斗日志上限：RichTextLabel 无限追加会一直吃内存
## ---- 手牌布局：照原版《影之诗》（`docs/shadowverse-battle-ui.md` §13.2，卡宽 = 200 局部单位）----
const SV_CARD_UNITS := 200.0          ## 原版 CARD_WIDTH（HandTRSCalculatorBase.cs:7）
const SV_SPREAD_RATIO := 0.7          ## 常态横向铺开系数（HandTRSCalculatorPlayerFan.cs:34）
const SV_SPREAD_MAX_CARDS := 3.5      ## W 上限 700/200 = 3.5 个卡宽（同处）
const SV_FAN_REST_PER_CARD := 0.6     ## 常态扇形每张牌的角度（原版常态平直，这里给一点微弧）
const SV_FAN_FOCUS_PER_CARD := 1.5    ## 放大态扇形总量 = 1.5n 度（原版 rotZ ±0.75n）
const SV_FOCUS_OFFSET_UNITS := 130.0  ## 放大态整条手牌右移量（局部单位，同处）
const SV_FOCUS_LIFT_UNITS := 40.0     ## 放大态抬起量 / 弧高（原版 y=t2*40+40，同处）
const SV_MIN_VISIBLE := 44.0          ## 叠压下限：每张至少露出这么多像素（保证费用/数值可读；原版没有这条下限）
## 原版「强击」阈值：DamageVfx.cs:8 STRONG_DAMAGE_VALUE = 7（≥7 → 飘字放大 + 震屏 + 强打击特效）
const STRONG_DAMAGE := 7

enum DragKind { NONE, CARD, ATTACK }

var hand_cards: Array[CardUI] = []
var enemy_hand_cards: Array[Control] = []   ## 敌方手牌卡背（与我方手牌互为镜像排列）
var mode := Mode.IDLE

var drag_kind := DragKind.NONE
var drag_index := -1      ## 正在拖拽的手牌下标
## 拖着的这张牌现在打不出（法力不足 / 战场已满）：幽灵卡显示成红色禁止样式，
## 落点不点亮，松手时说明具体原因——玩家依旧可以先拿起来比划。
var drag_forbidden := false
var drag_unit := -1       ## 正在拖拽攻击的随从
var _ghost: CardUI = null
var _drop_hint: Panel = null
var _drag_mouse := Vector2.ZERO   ## 拖拽中的鼠标位置（跟随事件更新）
var _last_mouse := Vector2.ZERO   ## 最近一次鼠标位置（箭头判定目标用）
var _detail_pinned := false       ## 点击后固定显示的卡牌详情，不随鼠标移开而隐藏
var pending_index := -1      ## 等待指定目标的卡牌在手牌中的下标
var pending_unit := -1       ## 等待指定攻击目标 / 技能目标的随从
var targets: Array[Dictionary] = []
## 操作栏的「临时说明」：刚发动的技能 / 技能被拦下的原因。
## 优先级最低——只在回合提示后面追加一句，绝不覆盖选目标 / 拖拽这些既有提示（见 `_update_hint`）。
var _notice := ""

## 刷新合并：一次操作会触发多次 state_changed，逐次重建整套控件既慢又会
## 在信号回调内部拆掉发信号的控件；因此只在每帧空闲时统一重建一次。
var _refresh_dirty := false
var _enemy_back_style: StyleBoxFlat = null
var _log_text := ""    ## 日志的自有缓冲（截断时用它重建，不能依赖 RichTextLabel 的 text）

var _login_dialog: LoginDialog = null
var _admin_panel: AdminPanel = null
var _tracker_panel: TrackerPanel = null
var _settings_dialog: SettingsDialog = null
## 起手换牌面板（开局弹出，确认前挡住底下的操作）
var _mulligan: MulliganDialog = null
## 融合选择窗（右键带融合的手牌时打开；同一时刻只开一个）
var _fusion_dialog: FusionDialog = null

## 手牌状态（照原版《影之诗》的 Unfocus / Focus）：常态＝贴右侧的平直牌带；
## 选牌 / 选目标 / 拖拽＝整条抬起、张开、右移。见 `_layout_hand()` / `_sync_hand_state()`。
var _hand_resting := true
var _hand_lift := 0.0
## 玩家点过手牌 → 整条手牌**摊开展示**（原版 Focus 态）；出牌成功 / 右键 / Esc / 点空处时收回去。
## 见 `_sync_hand_state()` 与 `_on_hand_card_clicked()`。
var _hand_focus := false
var _hand_state_ready := false
var _hand_tween: Tween = null
## 常态手牌贴到手牌区右缘留出的边距（原版手牌根在右侧 `+500` 局部单位的 2D 近似）
const HAND_DOCK_MARGIN := 12.0
## 手牌滑到正中的耗时；测试里设为 0 可立即到位（无头模式的帧步长不可控）
var hand_slide_time := 0.18
## 联机：顶栏按钮 / 状态标签 / 大厅面板
var _net_button: Button = null
var _net_status: Label = null
var _net_lobby = null
## 「发现」三选一弹窗
var _discover = null
## 瞬念召唤「基础机制 = 由玩家选择去向」的三选一弹窗
var _invoke_choice = null
## 卡牌 / 随从的指向箭头（替代黄色矩形标注）
var _arrow = null
## 抽牌堆（我方在右手边、敌方镜像在左手边）
var _player_pile = null
## 伤害 / 治疗飘字（复用节点，避免频繁 new）
var _floats: Array = []
## 管理员配置的场景背景图
var _bg_rect: TextureRect = null
## 供测试：当场飘出的伤害 / 治疗打击感（红闪 + 击退的 2D 替代）——见 `_impact_flash()`
var impacts: Array = []
var _shake_tween: Tween = null

## 战斗表现层（BattleFx）：出牌飞牌 / 随从死亡消失 / 召唤登场 —— 见 scripts/BattleFx.gd
var _battle_fx: BattleFxScript = null
## 上一帧的战场随从快照（unit_id → {rect, card, friendly}）：
## 用来发现「这一帧消失的单位」，从而在它原来的位置上播死亡 / 消失动画与语音。
var _unit_snapshot: Dictionary = {}
## 本帧打出的牌：等战场重建完（拿到落点）再补飞牌动画
var _pending_play: Array = []
## 本帧打出过的卡 id（新出现的随从如果是它，就不再重复播召唤光环）
var _frame_played_ids: Dictionary = {}

## 飘字层（挂在 DragLayer 上，不受布局影响）
var _float_layer: Control = null
## 最近一次出牌特效的位置（测试用）
var _last_vfx_pos := Vector2.ZERO
var _enemy_pile = null
## 中线右端的回合控件（圆形结束回合按钮 + 环绕能量点 + 按钮内的回合数）
var turn_control: TurnControl = null
## 中线左端的记牌器按钮（与右端的回合控件对称）
var tracker_button: RoundButton = null
## 指向 TurnControl 内的圆形按钮：供结束回合状态与测试引用
var end_turn_button: Button = null
## 回合提示横幅 + 结束回合按钮的呼吸效果
var _banner: Label = null
var _banner_tween: Tween = null
var _end_pulse: Tween = null
var _end_pulse_on := false
var _turn_signature := Vector2i(-1, -1)


func _ready() -> void:
	restart_button.pressed.connect(_on_restart_pressed)
	# 结束回合按钮是代码构建的圆形按钮，它的 pressed 在 _build_turn_control() 里接
	admin_button.pressed.connect(_on_admin_pressed)
	settings_button.pressed.connect(_open_settings)
	concede_button.pressed.connect(_on_concede_pressed)
	var ai_btn := get_node_or_null("Root/Arena/TopBar/AiButton") as Button
	if ai_btn != null:
		ai_btn.pressed.connect(_open_ai_sidebar)
	GameSettings.changed.connect(_on_settings_changed)
	enemy_hero_frame.pressed.connect(_on_hero_clicked)
	player_hero_frame.pressed.connect(_on_hero_clicked)

	GameManager.state_changed.connect(_request_refresh)
	GameManager.log_message.connect(_append_log)
	GameManager.game_over.connect(_on_game_over)
	GameManager.game_started.connect(_on_game_started)
	# 从主界面进对局时，new_game() 在切场景**之前**就执行完了，game_started 信号当时没人接 →
	# 这里补一次检查，保证任何入场路径（人机 / 匹配 / 客机快照）都能弹起手换牌
	call_deferred("_sync_mulligan")
	call_deferred("_update_target_arrow")
	call_deferred("_update_piles")
	call_deferred("_apply_ui_skin")
	call_deferred("_apply_background")
	call_deferred("_setup_art_button")
	GameManager.discover_requested.connect(_on_discover_requested)
	GameManager.invoke_choice_requested.connect(_on_invoke_choice_requested)
	GameManager.card_drawn.connect(_on_card_drawn)
	GameManager.amount_shown.connect(_on_amount_shown)
	GameManager.card_resolved.connect(_on_card_resolved_vfx)
	# 出牌 / 攻击 / 召唤 三处表现与卡牌语音（原本 card_played 没人接 → 管理员配的出牌特效从未生效过）
	GameManager.card_played.connect(_on_card_played_vfx)
	GameManager.unit_attacked.connect(_on_unit_attacked_fx)
	GameManager.unit_summoned.connect(_on_unit_summoned_fx)
	CardDB.database_changed.connect(_request_refresh)
	AdminAuth.login_state_changed.connect(_on_login_state_changed)
	hand_area.resized.connect(_layout_hand)
	enemy_hand_row.resized.connect(_layout_enemy_hand)
	# 画布尺寸变化时，中线两端的控件要重新贴到中线
	arena_panel.resized.connect(_layout_midline_controls)
	mid_seam.resized.connect(_layout_midline_controls)

	_apply_theme_styles()
	_build_status_widgets()
	_build_tracker_button()
	_build_turn_control()
	_build_turn_banner()
	_build_end_turn_pulse()
	_setup_net_ui()
	_apply_saved_settings()
	_append_log("玩法：**拖拽**手牌到战场出牌，拖拽我方随从到敌方目标发起攻击；也可以点击操作。右键取消。")
	_append_log("登录管理员可在「卡牌管理」中增删卡牌，改动会立即影响当前对局。")
	_append_log("快捷键：空格 结束回合 · Esc 取消 / 收记牌器 · 1-9 选手牌 · Tab 记牌器 · F1 快捷键说明")
	_warn_about_new_builtin_cards()
	_refresh()
	_update_admin_ui()
	_layout_hand.call_deferred()
	_layout_enemy_hand.call_deferred()
	_layout_midline_controls.call_deferred()


# ------------------------------ 联机 / 设置 / 快捷键 / 音效 ------------------------------

## 顶栏加「联机」按钮与联机状态标签（代码构建，避免改场景）
func _setup_net_ui() -> void:
	var bar := settings_button.get_parent()
	if bar == null:
		return
	_net_button = Button.new()
	_net_button.text = "联机"
	_net_button.pressed.connect(_on_net_pressed)
	bar.add_child(_net_button)
	bar.move_child(_net_button, settings_button.get_index())
	_net_status = Label.new()
	_net_status.add_theme_font_size_override("font_size", 11)
	_net_status.add_theme_color_override("font_color", Color("#b9f6ca"))
	bar.add_child(_net_status)
	var net := get_node_or_null("/root/Net")
	if net != null:
		net.roster_changed.connect(_on_net_changed)
		net.latency_changed.connect(func(_ms: int) -> void: _on_net_changed())
		net.session_ended.connect(_on_net_session_ended)
		net.snapshot_applied.connect(_request_refresh)
		net.log_line.connect(func(text: String) -> void: _append_log("[联机] " + text))
	_on_net_changed()


func _on_net_pressed() -> void:
	if _net_lobby == null or not is_instance_valid(_net_lobby):
		_net_lobby = load("res://scripts/NetLobby.gd").new()
		drag_layer.add_child(_net_lobby)
		_net_lobby.closed.connect(func() -> void: _on_settings_changed())
	_net_lobby.open()


## 联机状态变化：更新身份标签，并把「谁有权威 / 谁被锁」告诉 GameManager
func _on_net_changed() -> void:
	var net := get_node_or_null("/root/Net")
	if net == null:
		return
	var online: bool = net.is_online()
	var role_text := "单机"
	if online:
		role_text = "房主" if net.is_host() else ("观战" if net.is_spectator() else "客机")
		if net.rtt_ms > 0:
			role_text += " %dms" % net.rtt_ms
		if int(net.get("_disconnected_seat")) >= 0:
			role_text += " 等待重连"
	if _net_status != null:
		_net_status.text = role_text
	if _net_button != null:
		_net_button.text = "联机" if not online else "联机中"
	# 权威与锁定：客机只发意图，观战者完全只读
	GameManager.net_authority = (not online) or net.is_host()
	GameManager.net_locked = online and net.is_spectator()
	GameManager.turn_time_limit = int(net.turn_time_limit) if online else 0
	_request_refresh()


func _on_net_session_ended(reason: String) -> void:
	_append_log("[联机] 会话结束：%s" % reason)
	_on_net_changed()


## 应用存档里的设置：窗口模式 / 分辨率 / 动画速度 / 音效开关
func _apply_saved_settings() -> void:
	if GameSettings.has_method("apply_window_mode"):
		GameSettings.apply_window_mode(GameSettings.window_mode, GameSettings.resolution)
	var fx := get_node_or_null("/root/SoundFx")
	if fx != null and fx.has_method("set_enabled"):
		fx.set_enabled(bool(GameSettings.get("sound_enabled")))


## 动画时长按设置的倍率缩放（0 或负 = 立即完成）
func _anim_time(base: float) -> float:
	var sp := float(GameSettings.get("anim_speed"))
	if sp <= 0.0:
		return 0.0
	return maxf(0.0, base / sp)


func _play_sfx(event: String) -> void:
	var fx := get_node_or_null("/root/SoundFx")
	if fx != null and fx.has_method("play"):
		fx.play(event)


func _shortcut_help() -> void:
	_append_log("快捷键：空格 结束回合 · Esc 取消选择 / 收起记牌器 · 1-9 选择第 N 张手牌 · Tab 开关记牌器 · F1 本说明 · F2 开关 AI 助手")


## 返回 true 表示这个按键已被处理（调用方会 set_input_as_handled）
func _handle_shortcut(keycode: int) -> bool:
	if mulligan_open():
		return false
	if _net_lobby != null and is_instance_valid(_net_lobby) and _net_lobby.visible:
		return false
	match keycode:
		KEY_SPACE:
			_on_end_turn_pressed()
			return true
		KEY_TAB:
			_open_tracker()
			return true
		KEY_F1:
			_shortcut_help()
			return true
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	for i in 9:
		if keycode == KEY_1 + i:
			if me != null and i < me.hand.size():
				_on_hand_card_clicked(i)
				return true
	return false


## 新对局要重新播报第 1 回合的横幅（否则签名与上一局相同，横幅不会出现），并弹出起手换牌面板
func _on_game_started() -> void:
	_turn_signature = Vector2i(-1, -1)
	# 新对局：清掉上一局的随从快照与排队中的动画，
	# 否则「上一局的随从消失」会被当成死亡，在开局摆一排死亡特效。
	_unit_snapshot.clear()
	_pending_play.clear()
	_frame_played_ids.clear()
	if _battle_fx != null and is_instance_valid(_battle_fx):
		_battle_fx.clear()
	_open_mulligan()


## 起手换牌：开局抽完 4 张后弹出面板，确认前不让玩家操作
func _open_mulligan() -> void:
	if not GameManager.mulligan_pending:
		return
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null or me.hand.is_empty():
		return
	if _mulligan == null or not is_instance_valid(_mulligan):
		_mulligan = MulliganDialog.new()
		drag_layer.add_child(_mulligan)
		_mulligan.confirmed.connect(_on_mulligan_confirmed)
	_mulligan.open(me.hand.duplicate())


func _on_mulligan_confirmed(cards: Array) -> void:
	# 客机没有权威：换牌请求发给房主，由房主在它那份手牌上执行（否则只有本机换了、对面不知道）
	if not GameManager.net_authority:
		var ids: Array = []
		for c in cards:
			ids.append(c.id)
		var net := get_node_or_null("/root/Net")
		if net != null:
			net.send_intent({"kind": "mulligan", "ids": ids})
		_append_log("已把起手换牌请求发给房主（换掉 %d 张）" % cards.size())
		_request_refresh()
		return
	GameManager.finish_mulligan_cards(GameManager.PLAYER_ID, cards)
	_request_refresh()
	_append_log("起手换牌完成（换掉 %d 张）" % cards.size())


## 「发现」三选一：打开弹窗，选完再结算
func _on_discover_requested(_pid: int, options: Array) -> void:
	if _discover == null or not is_instance_valid(_discover):
		_discover = load("res://scripts/DiscoverDialog.gd").new()
		drag_layer.add_child(_discover)
		_discover.picked.connect(_on_discover_picked)
	_discover.open(options)


func _on_discover_picked(index: int) -> void:
	# 客机没有权威：把选择发给房主执行
	if not GameManager.net_authority:
		var net := get_node_or_null("/root/Net")
		if net != null:
			net.send_intent({"kind": "discover", "index": index})
		_append_log("已把「发现」的选择发给房主")
		return
	if GameManager.resolve_discover(index):
		_play_sfx("button")
	_request_refresh()


## 供测试：当前是否有待选的「发现」
func discover_open() -> bool:
	return _discover != null and is_instance_valid(_discover) and _discover.is_open()


## 瞬念召唤「基础机制 = 由玩家选择去向」：应召上场后弹三选一（保留在场 / 返回手牌 / 进入墓地）
func _on_invoke_choice_requested(_pid: int, _unit_id: int) -> void:
	if _invoke_choice == null or not is_instance_valid(_invoke_choice):
		_invoke_choice = load("res://scripts/InvokeChoiceDialog.gd").new()
		drag_layer.add_child(_invoke_choice)
		_invoke_choice.picked.connect(_on_invoke_choice_picked)
	_invoke_choice.open()


func _on_invoke_choice_picked(dest: int) -> void:
	# 客机没有权威：把选择发给房主执行
	if not GameManager.net_authority:
		var net := get_node_or_null("/root/Net")
		if net != null:
			net.send_intent({"kind": "invoke_choice", "dest": dest})
		_append_log("已把瞬念召唤去向发给房主")
		return
	if GameManager.resolve_invoke_choice(dest):
		_play_sfx("button")
	_request_refresh()


## 供测试：当前是否有待选的瞬念召唤去向
func invoke_choice_open() -> bool:
	return _invoke_choice != null and is_instance_valid(_invoke_choice) and _invoke_choice.is_open()


func invoke_choice_dialog():
	return _invoke_choice


func discover_dialog():
	return _discover


## 供测试 / 调试：直接按“一张都不换”结束起手换牌
func skip_mulligan() -> void:
	if _mulligan != null and is_instance_valid(_mulligan) and _mulligan.is_open():
		_mulligan.skip()


func mulligan_open() -> bool:
	return _mulligan != null and is_instance_valid(_mulligan) and _mulligan.is_open()


func mulligan_dialog() -> MulliganDialog:
	return _mulligan


## 存档里的卡表比内置卡表少时（例如版本更新新增了卡牌）在日志里提示一次。
## 不自动覆盖存档——管理员可能是有意删掉那些卡的。
func _warn_about_new_builtin_cards() -> void:
	var missing := CardDB.missing_builtin_ids()
	if missing.is_empty():
		return
	var names := PackedStringArray()
	for c in CardDB._builtin_cards():
		if missing.has(c.id):
			names.append(c.card_name)
	var text := "提示：内置卡表比当前存档多 %d 张卡（%s）。想启用它们请在「卡牌管理 → 恢复默认卡表」重置卡表（原卡表会备份为 cards.json.bak）。" % [
		missing.size(), "、".join(names)]
	_append_log(text)
	print("[CardDB] " + text)


## 请求一次刷新；同一帧内的多次请求只会重建一次控件
func _request_refresh() -> void:
	_update_target_arrow()
	_refresh_dirty = true


func _apply_theme_styles() -> void:
	var arena_style := StyleBoxFlat.new()
	arena_style.bg_color = Color(0.09, 0.11, 0.15, 1.0)
	arena_style.border_color = Color(0.28, 0.32, 0.38, 1.0)
	arena_style.set_border_width_all(2)
	arena_style.set_corner_radius_all(14)
	arena_style.content_margin_left = 12
	arena_style.content_margin_right = 12
	arena_style.content_margin_top = 10
	arena_style.content_margin_bottom = 10
	arena_panel.add_theme_stylebox_override("panel", arena_style)

	var log_style := StyleBoxFlat.new()
	log_style.bg_color = Color(0.07, 0.09, 0.12, 1.0)
	log_style.border_color = Color(0.25, 0.28, 0.34, 1.0)
	log_style.set_border_width_all(2)
	log_style.set_corner_radius_all(12)
	log_panel.add_theme_stylebox_override("panel", log_style)

	# 结束回合按钮已改为「中线右端的圆形按钮」（见 _build_turn_control），
	# 它的圆形四态样式由 TurnControl 自己管理，这里不再处理。

	# 中线：一条亮色接缝，把上下半场分开（炉石 / 影之诗的场地都有明确的一条分界）。
	# 接缝画在 MidLine 这一行的垂直正中，所以两侧战场到它的距离天然相等。
	var seam_style := StyleBoxFlat.new()
	seam_style.bg_color = Color(1.0, 0.83, 0.31, 0.5)
	seam_style.set_corner_radius_all(2)
	mid_seam.add_theme_stylebox_override("panel", seam_style)
	# 「中 线」字给个底色做成压在线上的标签块，否则接缝会从字中间穿过去
	var chip := StyleBoxFlat.new()
	chip.bg_color = Color(0.09, 0.11, 0.15, 1.0)
	chip.content_margin_left = 10
	chip.content_margin_right = 10
	chip.set_corner_radius_all(6)
	mid_label.add_theme_stylebox_override("normal", chip)


# ------------------------------ 场地控件 ------------------------------
#
# 双方的“英雄 + 法力水晶 + 状态计数”组合成一块信息区（参考炉石底部的英雄 / 法力水晶条，
# 以及影之诗左下角的 PP 珠 + 领袖）。上下半场各一套，关于中线互为镜像。

func _build_status_widgets() -> void:
	# 上下两侧正中是主战者框（圆盘 + 血量 / 护甲），盘里不再放计数；
	# 计数（牌库 / 手牌 / 墓地 / 疲劳）放到竞技区角上的独立信息框里：
	#   敌方在右上、我方在左下（参考影之诗把计数做成边缘信息块）。
	enemy_hero_frame.setup(GameManager.ENEMY_ID, "敌方 AI", true)
	player_hero_frame.setup(GameManager.PLAYER_ID, "我方英雄", false)
	enemy_status_panel.setup(GameManager.ENEMY_ID)
	player_status_panel.setup(GameManager.PLAYER_ID)


## 中线左端的记牌器按钮：与右端的回合控件左右对称（影之诗式的中线两端按钮）
func _build_tracker_button() -> void:
	tracker_button = RoundButton.new()
	tracker_button.tone = RoundButton.Tone.SLATE
	tracker_button.text = "记牌器"
	tracker_button.tooltip_text = "查看本局双方已使用的卡牌"
	tracker_button.add_theme_font_size_override("font_size", 12)
	tracker_button.add_theme_color_override("font_color", Color("#e0e0e0"))
	tracker_button.z_index = -1          ## 与回合控件一致，低于卡牌详情与回合横幅
	drag_layer.add_child(tracker_button)
	tracker_button.pressed.connect(_open_tracker)
	_layout_midline_controls()


## 中线右端的回合控件：圆形结束回合按钮 + 环绕能量点 + 按钮内的回合数（影之诗风格）。
## 挂在 DragLayer 上而不是 Arena 的容器里，这样它可以**叠在两块战场之间**而不被布局挤压；
## 位置由 _layout_midline_controls() 每次刷新 / 尺寸变化时贴到中线两端。
func _build_turn_control() -> void:
	turn_control = TurnControl.new()
	turn_control.z_index = -1          ## 低于卡牌详情与回合横幅，避免盖住提示面板
	drag_layer.add_child(turn_control)
	turn_control.end_turn_pressed.connect(_on_end_turn_pressed)
	end_turn_button = turn_control.button
	_layout_midline_controls()


## 把中线两端的控件贴到接缝上：左端记牌器、右端回合控件，都垂直居中于中线
func _layout_midline_controls() -> void:
	if mid_seam == null:
		return
	var seam := mid_seam.get_global_rect()
	if seam.size.x < 1.0:
		return
	var cy: float = seam.get_center().y
	if tracker_button != null and is_instance_valid(tracker_button):
		tracker_button.position = Vector2(seam.position.x, cy - tracker_button.size.y * 0.5)
	if turn_control != null and is_instance_valid(turn_control):
		var w: float = TurnControl.CONTROL_SIZE.x
		var h: float = TurnControl.CONTROL_SIZE.y
		turn_control.size = Vector2(w, h)
		turn_control.position = Vector2(seam.position.x + seam.size.x - w, cy - h * 0.5)


## 回合切换时在场地中央闪一条提示（炉石的“你的回合”提示）
func _build_turn_banner() -> void:
	_banner = Label.new()
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 36)
	_banner.modulate = Color(1, 1, 1, 0)
	_banner.anchor_left = 0.0
	_banner.anchor_right = 1.0
	_banner.anchor_top = 0.42
	_banner.anchor_bottom = 0.42
	_banner.offset_top = -34.0
	_banner.offset_bottom = 34.0
	drag_layer.add_child(_banner)


func _show_turn_banner(text: String, color: Color) -> void:
	if _banner == null or not is_instance_valid(_banner):
		return
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner.text = text
	_banner.modulate = Color(color.r, color.g, color.b, 0.0)
	_banner_tween = _banner.create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.12)
	_banner_tween.tween_interval(0.7)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.45)


## 轮到我方时「结束回合」按钮轻微呼吸，提醒这是主要操作。
## 每次状态切换都重建（见 _update_end_turn_state），避免从暂停相位继续导致亮度跳变。
func _build_end_turn_pulse() -> void:
	if _end_pulse != null and _end_pulse.is_valid():
		_end_pulse.kill()
	_end_pulse = end_turn_button.create_tween()
	_end_pulse.set_loops()
	_end_pulse.tween_property(end_turn_button, "modulate", Color(1.15, 1.15, 1.15, 1.0), 0.9)
	_end_pulse.tween_property(end_turn_button, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.9)
	_end_pulse.pause()


func _update_end_turn_state(my_turn: bool) -> void:
	var active: bool = my_turn and not GameManager.busy and GameManager.game_active()
	end_turn_button.disabled = not active
	end_turn_button.tooltip_text = "" if active else "只有轮到我方时才能结束回合"
	concede_button.disabled = not GameManager.game_active()
	if active == _end_pulse_on:
		return
	_end_pulse_on = active
	_build_end_turn_pulse()
	if active:
		_end_pulse.play()
	else:
		end_turn_button.modulate = Color.WHITE


## 对手回合用暗色标题，我方回合用绿色，和按钮状态呼应
func _side_label_text(my_turn: bool) -> String:
	if not GameManager.game_active():
		return "对局结束"
	if GameManager.busy:
		return "敌方 AI 行动中…"
	if my_turn:
		return "▶ 我方回合"
	return "敌方回合"


# ------------------------------ 记牌器 / 设置 / AI 助手 ------------------------------

## AI 助手浮窗（全局侧边栏，挂在 AiAssistant 下）：与记牌器互斥，两个抽屉都贴右缘会叠在一起
func _open_ai_sidebar() -> void:
	var ai := get_node_or_null("/root/AiAssistant")
	if ai == null:
		return
	# 打开 AI 浮窗前先收起记牌器（反之亦然，见 _open_tracker）
	if not ai.is_open():
		_close_tracker_if_open()
	if ai.has_method("toggle_sidebar"):
		ai.toggle_sidebar()


## 记牌器：从右侧滑出的抽屉（不是独立窗口，避免居中弹出压住场地）
func _open_tracker() -> void:
	# 和 AI 浮窗互斥：两个抽屉都贴右边缘，同时开会互相盖住
	var ai := get_node_or_null("/root/AiAssistant")
	if ai != null and ai.is_open():
		ai.close_sidebar()
	if _tracker_panel == null or not is_instance_valid(_tracker_panel):
		_tracker_panel = TrackerPanel.new()
		_tracker_panel.z_index = -1          ## 低于悬停详情与回合横幅，高于棋盘与日志
		drag_layer.add_child(_tracker_panel)
		_tracker_panel.closed.connect(_on_tracker_closed)
	# 再点一次中线左端的按钮 = 收起
	_tracker_panel.toggle()


func _on_tracker_closed() -> void:
	# 抽屉常驻（收起只是滑出屏幕），这样滚动位置能保留，不用每次重建
	if _tracker_panel != null and is_instance_valid(_tracker_panel):
		_tracker_panel.refresh()


## 记牌器抽屉开着时，Esc 收起它
func _close_tracker_if_open() -> bool:
	if _tracker_panel != null and is_instance_valid(_tracker_panel) and _tracker_panel.is_open():
		_tracker_panel.close()
		return true
	return false


func _open_settings() -> void:
	if _settings_dialog != null and is_instance_valid(_settings_dialog):
		_settings_dialog.grab_focus()
		return
	_settings_dialog = SettingsDialog.new()
	add_child(_settings_dialog)
	_settings_dialog.closed.connect(_on_settings_closed)
	_settings_dialog.popup_centered()


func _on_settings_closed() -> void:
	if _settings_dialog != null and is_instance_valid(_settings_dialog):
		_settings_dialog.queue_free()
	_settings_dialog = null


func _on_settings_changed() -> void:
	_apply_saved_settings()
	_request_refresh()
	_layout_hand()


# ------------------------------ 刷新 ------------------------------

func _sync_mulligan() -> void:
	# 还挂着待换牌就弹出来（重复调用安全：面板已开时不重复弹）
	if GameManager.mulligan_pending and not mulligan_open():
		_open_mulligan()


func _refresh() -> void:
	_sync_mulligan()
	_update_piles()
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	var foe: PlayerState = GameManager.get_player(GameManager.ENEMY_ID)
	if me == null or foe == null:
		return

	var my_turn: bool = GameManager.game_active() and GameManager.current_player == GameManager.PLAYER_ID
	side_label.text = _side_label_text(my_turn)

	_update_hero_frames(me, foe)
	_update_turn_control(me, my_turn)
	_update_end_turn_state(my_turn)
	_update_turn_banner()

	# 点击固定的详情面板要跨刷新保留（README：直到出牌 / 右键 / 取消选择才隐藏）
	if drag_kind == DragKind.NONE and not _detail_pinned:
		card_detail.hide_card()

	_update_enemy_hand(foe)
	_update_board(enemy_board, foe, false, my_turn)
	_update_board(player_board, me, true, my_turn)
	_update_city_slots()
	_update_hand(me, my_turn)
	_sync_hand_state()
	_update_hint(my_turn)
	if drag_kind != DragKind.NONE:
		_reapply_drag_visuals()
	# 表现层放在最后：此时战场刚重建完，落点 / 格子矩形都是这一帧的真实值
	_flush_play_flights()
	_update_unit_snapshot()


## 主战者框的圆盘要让开战场行：圆盘比英雄行高得多，直接居中会压住随从的上下边缘，
## 还会把随从那一片的点击抢走。这里按战场行的实际位置算一个纵向偏移——
## 敌方往上、我方往下，各让开圆盘半径 + 描边的距离。
func _layout_hero_frames() -> void:
	if enemy_hero_frame == null or player_hero_frame == null:
		return
	enemy_hero_frame.set_disc_offset_y(_hero_disc_offset(enemy_hero_frame, enemy_board.get_global_rect(), true))
	player_hero_frame.set_disc_offset_y(_hero_disc_offset(player_hero_frame, player_board.get_global_rect(), false))


func _hero_disc_offset(frame: HeroFrame, board: Rect2, upward: bool) -> float:
	var band_center: float = frame.get_global_rect().get_center().y
	var clearance: float = HeroFrame.DISC_R + 8.0
	if upward:
		return minf(0.0, (board.position.y - clearance) - band_center)
	return maxf(0.0, (board.position.y + board.size.y + clearance) - band_center)


## 主战者框：血量 / 护甲徽章 + 牌库·手牌·墓地·疲劳计数格（+ 敌方的 PP 珠），
## 并在可被指定为目标时高亮（替代原先把 "▶ " 前缀加进英雄按钮文字的做法）。
func _update_hero_frames(me: PlayerState, foe: PlayerState) -> void:
	enemy_hero_frame.update_state(foe)
	player_hero_frame.update_state(me)
	enemy_status_panel.update_state(foe, GameManager.HAND_LIMIT)
	player_status_panel.update_state(me, GameManager.HAND_LIMIT)
	enemy_hero_frame.set_highlight(_is_target(-1, GameManager.ENEMY_ID))
	player_hero_frame.set_highlight(_is_target(-1, GameManager.PLAYER_ID))


## 圆形回合按钮：按钮里显示回合数，环绕的水晶反映我方当前法力
func _update_turn_control(me: PlayerState, my_turn: bool) -> void:
	if turn_control == null or not is_instance_valid(turn_control):
		return
	_layout_midline_controls()
	turn_control.set_turn(GameManager.turn_count)
	turn_control.set_mana(me.mana, me.max_mana)
	var caption := "结束回合"
	if not GameManager.game_active():
		caption = "对局结束"
	elif not my_turn:
		caption = "对手回合"
	turn_control.set_active(my_turn and not GameManager.busy and GameManager.game_active(), caption)


## 回合一变就闪一条横幅（第 1 回合的“我方回合”也会提示）
func _update_turn_banner() -> void:
	var sig := Vector2i(GameManager.current_player, GameManager.turn_count)
	if sig == _turn_signature:
		return
	_turn_signature = sig
	if not GameManager.game_active():
		return
	var mine: bool = GameManager.current_player == GameManager.PLAYER_ID
	_show_turn_banner("我方回合" if mine else "敌方回合",
		Color("#81c784") if mine else Color("#ef9a9a"))


## 敌方手牌以“背面朝上”的卡背显示，排布为我方手牌扇形的镜像（扇心在上方）
func _update_enemy_hand(foe: PlayerState) -> void:
	for child in enemy_hand_row.get_children():
		child.queue_free()
	enemy_hand_cards.clear()
	if not GameSettings.show_enemy_hand:
		_show_enemy_hand_count(foe.hand.size())
		return
	var count: int = mini(foe.hand.size(), 10)
	var style := _enemy_back_stylebox()
	enemy_hand_cards.resize(count)
	var back_tex := ArtStore.card_back_texture()
	# 倒序添加：卡背之间用**树序**决定前后（镜像扇形里左边的压在上面）。
	# 不能用正的 z_index —— 那会盖住主战者框的圆环与 PP 珠，用负的又会被竞技区背景吞掉。
	for i in range(count - 1, -1, -1):
		var back := PanelContainer.new()
		back.size = Vector2(ENEMY_CARD_W, ENEMY_CARD_H)
		back.add_theme_stylebox_override("panel", style)
		back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if back_tex != null:
			# 有卡背贴图（逆向素材 / 自备）时贴上去：与抽牌堆、飞牌用的是**同一张**牌背
			var face := TextureRect.new()
			face.texture = back_tex
			face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			face.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			face.mouse_filter = Control.MOUSE_FILTER_IGNORE
			back.add_child(face)
		enemy_hand_row.add_child(back)
		enemy_hand_cards[i] = back
	_layout_enemy_hand()


## 卡背样式只需构造一次（原来每张卡背都新建一个 StyleBoxFlat）。
## 样式取自 `CardSkin`：与**抽牌堆的牌背**同一套底色 / 描边 / 圆角比例，
## 这样「对手手里的牌背」和「牌堆里的牌」看起来是同一种牌（用户要求统一样式）；
## 另外加一层投影，牌背之间叠压时才有「一叠牌」的层次（不然会像一排贴纸）。
func _enemy_back_stylebox() -> StyleBoxFlat:
	if _enemy_back_style == null:
		_enemy_back_style = CardSkin.back_style(Vector2(ENEMY_CARD_W, ENEMY_CARD_H))
		_enemy_back_style.shadow_color = Color(0, 0, 0, 0.5)
		_enemy_back_style.shadow_size = 4
		_enemy_back_style.shadow_offset = Vector2(0, 2)
	return _enemy_back_style


## 重建控件会丢掉拖拽中的视觉状态（半透明 / 高亮），重建后补回来
func _reapply_drag_visuals() -> void:
	_mark_dragged_card(true)
	if drag_unit < 0:
		return
	for row in [enemy_board, player_board]:
		for child in _live_unit_uis(row):
			child.set_dragging(child.unit.unit_id == drag_unit)


func _update_board(container: HBoxContainer, p: PlayerState, friendly: bool, my_turn: bool) -> void:
	for child in container.get_children():
		child.queue_free()
	var limit: int = GameManager.BOARD_LIMIT
	# 城邦格里的城邦不占 7 格战场，所以计数与逐格摆放都要把它排除掉
	var used: int = GameManager.board_size_used(p.player_id)
	# 战场地面自己绘制槽位与「n / 7」计数，空场不再需要一行占位文字
	var surface := container as BoardSurface
	if surface != null:
		surface.set_slots(used, limit, "我方战场" if friendly else "敌方战场", friendly)
	# 逐格摆放：**随从待在自己的格子里**（用户要求「拖到哪个格子就放进哪个格子」，
	# 死亡留下的空位保留、后面的随从不会自动补位），所以这里不再做整体居中：
	# 第 i 个子节点永远是第 i 个格子，落点与 `BoardSurface.slot_rect(i)` 逐格对齐。
	for lane in limit:
		var u: BoardUnit = GameManager.board_slot(p.player_id, lane)
		if u == null or u.in_city_slot:
			container.add_child(_make_slot_spacer(lane))
			continue
		# 随从控件必须放在一个**普通 Control 格子**里：Container 会在布局时强制把
		# 直接子节点的旋转 / 缩放归零（横置要旋转 90°，直接挂在容器下会被重置）。
		var cell := _make_slot_spacer(lane)
		container.add_child(cell)
		var ui := UnitUI.new()
		cell.add_child(ui)
		ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# 镜像：两侧随从都紧贴在各自半场靠中线的一侧
		cell.size_flags_vertical = Control.SIZE_SHRINK_BEGIN if friendly else Control.SIZE_SHRINK_END
		ui.setup(u, friendly, GameManager.turn_count, friendly and my_turn and not GameManager.busy)
		ui.set_front(u.in_front)          # 横置：画成横放的牌
		ui.set_highlight(false)     # 同上：不再用矩形标注可指定的目标
		ui.unit_clicked.connect(_on_unit_clicked)
		ui.unit_drag_started.connect(_on_unit_drag_started)
		ui.unit_hovered.connect(_on_card_hovered)
		ui.unit_hover_ended.connect(_on_card_hover_ended)
		ui.unit_right_clicked.connect(func(_id: int) -> void: _clear_mode())


## 某个随从在战场上的格子号（-1 = 不在 7 格战场里，例如城邦格）。
## 布局、拖拽落点与布局测试共用这一个来源，避免两边各算一套。
func back_lane_of(pid: int, unit_id: int) -> int:
	var p: PlayerState = GameManager.get_player(pid)
	if p == null:
		return -1
	for u in p.board:
		if u.unit_id == unit_id:
			return GameManager.slot_of_unit(u)
	return -1


## 空槽占位控件（同时充当随从控件的“格子”）：只占一个槽位宽，不接收鼠标事件。
## 它的存在让「第 i 个子节点」恒等于「第 i 个格子」（`BoardSurface.slot_rect(i)` 与 HBoxContainer
## 的等宽排布逐格对齐），随从数与空洞都不会让落点漂移；随从控件放在它里面，
## 是为了让横置的旋转不被 Container 的布局重置。`lane` 记在 meta 里，供拖拽落点回查格子号。
func _make_slot_spacer(lane: int = -1) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(UnitUI.UNIT_SIZE.x, UnitUI.UNIT_SIZE.y)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.set_meta("slot", lane)          # 供测试 / 调试回查「这是第几格」
	return spacer


func _update_hand(me: PlayerState, my_turn: bool) -> void:
	for child in hand_area.get_children():
		child.queue_free()
	hand_cards.clear()
	for i in me.hand.size():
		var card_data: CardData = me.hand[i]
		var ui := CARD_SCENE.instantiate() as CardUI
		if ui == null:
			continue
		hand_area.add_child(ui)
		var ok: bool = my_turn and not GameManager.busy and GameManager.can_play(GameManager.PLAYER_ID, i)
		ui.setup(card_data, i, ok)
		ui.clicked.connect(_on_hand_card_clicked)
		ui.drag_started.connect(_on_hand_card_drag_started)
		ui.hovered.connect(_on_card_hovered)
		ui.hover_ended.connect(_on_card_hover_ended)
		# 右键：带融合的卡打开融合选择窗，其它卡沿用「取消当前选择」
		ui.right_clicked.connect(_on_hand_card_right_clicked)
		if mode == Mode.CARD_TARGET and i == pending_index:
			ui.set_selected(true)
		hand_cards.append(ui)
	_layout_hand()


## 手牌以底部扇形摆放（照原版《影之诗》，见 `docs/shadowverse-battle-ui.md` §13.2）：
##   · 常态（Unfocus）：手牌根在右侧（玩家 `+500` 局部单位），每张牌 y 相同（**平直牌带**），
##     横向 `W*0.7*rate - W*0.35`，其中 `W = min(200(n-1), 700)`（卡宽 = 200 局部单位）；
##   · 放大态（Focus）：改成**绝对坐标**，整条移到中央偏右 `+130`、抬起 40、宽度放大 `(1+0.04n)`，
##     并第一次出现真正的扇形 `rotZ = rate*(-1.5n) + 0.75n`（即 ±0.75n 度）。
## 2D 换算：`u = 卡宽 / 200`（1 局部单位 = u 像素）。
## **有意偏离**：原版常态缩放 0.7（更小更薄），本项目卡面有卡名 / 数值 / 描述，缩到 0.7 读不清，
## 所以卡面尺寸保持 1.0，只复刻「铺开比例 + 叠压量」；另给叠压设了可读性下限 `SV_MIN_VISIBLE`，
## 常态也保留一点微弧（原版常态是平直的）——否则「手牌扇形角度」这个设置在日常状态下看不出效果。
func _layout_hand() -> void:
	var n: int = hand_cards.size()
	if n == 0:
		return
	var area_w: float = hand_area.size.x
	var area_h: float = hand_area.size.y
	if area_w < 1.0 or area_h < 1.0:
		return

	var u := _sv_unit()
	var w: float = _sv_hand_width(n)
	# 常态：0.7W 铺开、整条贴右缘；放大态：宽度 ×(1+0.04n)、居中偏右 130 局部单位
	var spread: float = w * SV_SPREAD_RATIO
	if not _hand_resting:
		spread = w * (1.0 + 0.04 * float(n))
	spread = maxf(spread, SV_MIN_VISIBLE * float(maxi(n - 1, 0)))
	var center_x: float
	if _hand_resting:
		# 常态：整条贴右缘（最右那张牌的右缘落在边距上）
		center_x = area_w - HAND_DOCK_MARGIN - CARD_W * 0.5 - spread * 0.5
	else:
		center_x = area_w * 0.5 + SV_FOCUS_OFFSET_UNITS * u
	var base_y: float = maxf(area_h - CARD_H - 6.0, 0.0) - _hand_lift
	var per_card: float = SV_FAN_REST_PER_CARD if _hand_resting else SV_FAN_FOCUS_PER_CARD
	var total_fan: float = deg_to_rad(minf(GameSettings.fan_angle, per_card * float(n)))
	# 弧高：原版放大态 `t2*40`（40 局部单位）；常态只留 45%
	var arc: float = SV_FOCUS_LIFT_UNITS * u * (0.45 if _hand_resting else 1.0)
	for i in n:
		var ui: CardUI = hand_cards[i]
		var rate: float = 0.5 if n <= 1 else float(i) / float(n - 1)
		var angle: float = (rate - 0.5) * total_fan
		# 外圈高、中间低：原版 `t2*40` 的 2D 等价（easeOutQuad 的三角波）
		var lift: float = arc * _ease_out_quad(absf(rate * 2.0 - 1.0))
		ui.size = Vector2(CARD_W, CARD_H)
		ui.pivot_offset = Vector2(CARD_W, CARD_H) * 0.5
		# `x` 是**牌的中心**（`center_x ± spread/2`），要减去半张卡宽换成左上角；
		# `base_y` 已经是**牌的上边**（底部对齐手牌区下缘），弧线再把它往上抬。
		# 注意纵轴不能再减 `CARD_H * 0.5`——那会把整条手牌抬高半张牌、顶进牌堆与主战者行
		# （曾因此让抽牌堆压住手牌，见 ui_layout_test 的「手牌完全落在手牌区内」断言）。
		ui.position = Vector2(center_x + (rate - 0.5) * spread - CARD_W * 0.5, base_y - lift)
		ui.rotation = angle
		ui.z_index = i


## 原版卡宽锚点：`CARD_WIDTH = 200`（HandTRSCalculatorBase.cs:7）→ 1 局部单位 = 这么多像素
func _sv_unit() -> float:
	return CARD_W / SV_CARD_UNITS


## 原版手牌总宽 `W = min(200(n-1), 700)`（同上）→ 像素
func _sv_hand_width(n: int) -> float:
	return minf(CARD_W * float(maxi(n - 1, 0)), SV_SPREAD_MAX_CARDS * CARD_W)


## 手牌在 Unfocus / Focus 之间切换（`_hand_lift` 由 `hand_slide_time` 补间）
## 「摊开」的三种来源：① 任何等待指定目标的状态（出牌 / 攻击 / 技能）；
## ② 玩家点过某张手牌（`_hand_focus` —— 点一下就把整条手牌摊开给你看，见 `_on_hand_card_clicked`）；
## ③ 正在拖拽。
func _sync_hand_state() -> void:
	var want_resting: bool = mode == Mode.IDLE and drag_kind == DragKind.NONE and not _hand_focus
	var first: bool = not _hand_state_ready
	if not first and want_resting == _hand_resting:
		return
	_hand_state_ready = true
	_hand_resting = want_resting
	var target: float = 0.0 if want_resting else SV_FOCUS_LIFT_UNITS * _sv_unit()
	if first or _anim_time(hand_slide_time) <= 0.0:
		_set_hand_lift(target)          # 开局直接摆到位；测试里也可要求立即到位
		return
	if _hand_tween != null and _hand_tween.is_valid():
		_hand_tween.kill()
	_hand_tween = create_tween()
	_hand_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hand_tween.tween_method(_set_hand_lift, _hand_lift, target, _anim_time(hand_slide_time))


func _set_hand_lift(v: float) -> void:
	_hand_lift = v
	_layout_hand()


## 供测试核对：手牌是否处于常态（未选牌）= 原版的 Unfocus
func hand_resting() -> bool:
	return _hand_resting


## 供测试核对：手牌当前抬起量（放大态 > 0）
func hand_lift() -> float:
	return _hand_lift


## 静态缓动：easeOutQuad（与 Tween 的 TRANS_QUAD / EASE_OUT 同一条曲线）
static func _ease_out_quad(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return 1.0 - (1.0 - c) * (1.0 - c)


## 关闭“显示敌方手牌”设置时，只提示张数
func _show_enemy_hand_count(count: int) -> void:
	var label := Label.new()
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.text = "敌方手牌 %d 张" % count
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	enemy_hand_row.add_child(label)


## 敌方手牌：摆在上半场的**左上角**（参考影之诗——对手的牌在左上、主战者框在正中）。
## 布局与下方我方手牌**共用同一套口径**（原版我方手牌的镜像，见 `docs/shadowverse-battle-ui.md` §13.2）：
##   * `rate` 反向（原版 `rate = 1 - i/(n-1)`）、扇形与弧线方向相反（2D 里就是整体反向）；
##   * 牌带用原版 0.7×W 的**叠压比** —— 也就是薄薄一叠卡背、左边露出窄窄一条。
##
## 修过的坑：`spread` 是**整条的跨度**，而 `step = spread / (n-1)` 才是每张的间距。
## 之前把 `spread` 直接当成每张的间距（`start_x + spread * i`），于是 5 张牌被摊到
## 4×84px 宽的一条横排上，看起来是一排孤零零的卡背而不是「一叠手牌」。
func _layout_enemy_hand() -> void:
	var n: int = enemy_hand_cards.size()
	if n == 0:
		return
	var area_h: float = enemy_hand_row.size.y
	if area_h < 1.0:
		return
	var w: float = minf(ENEMY_CARD_W * float(maxi(n - 1, 0)), SV_SPREAD_MAX_CARDS * ENEMY_CARD_W)
	# 叠压下限：卡背之间至少露出 ENEMY_MIN_VISIBLE px，避免张数少时完全重合
	var span: float = maxf(w * SV_SPREAD_RATIO, ENEMY_MIN_VISIBLE * float(maxi(n - 1, 0)))
	var step: float = span / float(maxi(n - 1, 1))
	var start_x: float = ENEMY_HAND_MARGIN
	var total_fan: float = deg_to_rad(minf(ENEMY_HAND_FAN_MAX, SV_FAN_REST_PER_CARD * 1.6 * float(n)))
	var base_y: float = (area_h - ENEMY_CARD_H) * 0.5
	for i in n:
		var back: Control = enemy_hand_cards[i]
		var rate: float = 0.5 if n <= 1 else 1.0 - float(i) / float(n - 1)
		var angle: float = (rate - 0.5) * total_fan
		var lift: float = ENEMY_HAND_ARC * _ease_out_quad(absf(rate * 2.0 - 1.0))
		back.size = Vector2(ENEMY_CARD_W, ENEMY_CARD_H)
		back.pivot_offset = Vector2(ENEMY_CARD_W, ENEMY_CARD_H) * 0.5
		back.position = Vector2(start_x + step * float(i), base_y + lift)
		back.rotation = -angle


func _update_hint(my_turn: bool) -> void:
	var text := ""
	if not GameManager.game_active():
		text = "对局已结束，点击「重开一局」开始新对局。"
	elif GameManager.busy:
		text = "敌方 AI 正在行动，请稍候…"
	elif mode == Mode.CARD_TARGET:
		text = "请为「%s」选择目标（右键取消）" % _pending_card_name()
	elif mode == Mode.SKILL_TARGET:
		text = _skill_target_hint()
	elif mode == Mode.ATTACK_TARGET:
		text = "请选择攻击目标（右键取消）"
	elif drag_kind != DragKind.NONE:
		text = "拖动中：松开放置到高亮位置（右键取消）"
	elif my_turn:
		text = "我方回合：先出牌铺场，再用准备好的随从攻击。"
		var ready_text := _ready_skill_hint()
		if ready_text != "":
			text += "　" + ready_text
	else:
		text = "敌方回合。"
	# 临时说明（发动技能的回执 / 技能被拦下的原因）优先级最低：只追加一句，
	# 不覆盖回合与选目标提示；自己回合里放在最前面，方便一眼看到刚才那一手的结果。
	if _notice != "" and GameManager.game_active() and not GameManager.busy and drag_kind == DragKind.NONE:
		text = (_notice + "　" + text) if mode == Mode.IDLE else (text + "　" + _notice)
	hint_label.text = text


## 选技能目标时的操作栏提示：「X」技能：<技能名>（花费 N PP）→ 请选择目标
func _skill_target_hint() -> String:
	var u: BoardUnit = GameManager.find_unit(pending_unit)
	if u == null or u.data == null:
		return "请选择技能目标（右键取消）"
	return "「%s」技能：%s（%s）→ 请选择目标（右键取消）" % [
		u.data.card_name, _skill_name(u), _skill_cost_text(u)]


## 技能花费文案：0 = 免费（玩家在管理员面板里可以随意指定 0–10 PP）
func _skill_cost_text(u: BoardUnit) -> String:
	var cost := _skill_cost(u)
	return "免费" if cost <= 0 else "花费 %d PP" % cost


## 我方场上有没有「现在点一下就能发动」的技能：有就在回合提示里带一句
func _ready_skill_hint() -> String:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null:
		return ""
	for u in me.units_in_order():
		if u == null or not _unit_has_skill(u):
			continue
		if _can_use_skill(u.unit_id):
			return "可使用技能：%s（%s）" % [_skill_name(u), _skill_cost_text(u)]
	return ""


func _pending_card_name() -> String:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me != null and pending_index >= 0 and pending_index < me.hand.size():
		return me.hand[pending_index].card_name
	return ""


func _append_log(text: String) -> void:
	_log_text += text + "\n"
	if _log_text.length() > LOG_MAX_CHARS:
		# 超限时只保留后半段：RichTextLabel 无限追加会一直吃内存
		_log_text = _log_text.substr(_log_text.length() - LOG_MAX_CHARS / 2)
		log_label.text = _log_bbcode(_log_text)
	else:
		log_label.append_text(_log_bbcode(text + "\n"))


## 卡牌名 / 描述是管理端自由文本，可能含 "["，直接进 BBCode 会渲染错乱
static func _log_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


# ------------------------------ 目标与模式 ------------------------------

func _clear_mode() -> void:
	_detail_pinned = false
	card_detail.hide_card()
	_notice = ""
	# 取消选择时把手牌收回常态（点过牌摊开的那一次也算「选择」的一部分）
	_hand_focus = false
	if mode == Mode.IDLE and targets.is_empty():
		_request_refresh()
		return
	# 出牌 / 攻击 / 技能（SKILL_TARGET）三种「等目标」状态在这里一并清干净：
	# 状态本身是共用的，所以取消技能与取消出牌走的是同一条路径。
	var had_arrow: bool = mode != Mode.IDLE
	mode = Mode.IDLE
	pending_index = -1
	pending_unit = -1
	targets.clear()
	if had_arrow and _arrow != null and is_instance_valid(_arrow):
		# 箭头平时只在鼠标事件里更新，取消后要立刻收起来（否则会挂到下一次鼠标移动）
		_arrow.hide_arrow()
	_update_hint(_my_turn())          # 操作栏立刻从「请选择目标」改回常规提示
	_request_refresh()


# ------------------------------ 主动技能（能量点 = 法力） ------------------------------
#
# 界面这一侧只负责「点它就能发动」：点击我方带技能的单位 → 直接发动 / 进入 SKILL_TARGET。
# 规则层（GameManager.can_use_skill / skill_blocked_reason / get_valid_skill_targets /
# use_skill / request_use_skill，CardData.has_skill / skill_name / skill_cost / skill_target /
# skill_once_per_turn / skill_chain，BoardUnit.skill_used_turn）由另一路并行实现，
# 所以这里一律 `has_method()` + `call()`：接口还没落地时按「没有技能」处理，界面不会崩。

## 这张卡是否声明了主动技能
func _unit_has_skill(u: BoardUnit) -> bool:
	if u == null or u.data == null or not u.data.has_method("has_skill"):
		return false
	return bool(u.data.call("has_skill"))


func _skill_name(u: BoardUnit) -> String:
	if u == null or u.data == null or not u.data.has_method("skill_name"):
		return ""
	return str(u.data.call("skill_name"))


func _skill_cost(u: BoardUnit) -> int:
	if u == null or u.data == null or not u.data.has_method("skill_cost"):
		return 0
	return int(u.data.call("skill_cost"))


## 技能的目标类型（CardData.Targeting）；接口未落地时返回 NONE
func _skill_target_kind(u: BoardUnit) -> int:
	if u == null or u.data == null or not u.data.has_method("skill_target"):
		return CardData.Targeting.NONE
	return int(u.data.call("skill_target"))


func _can_use_skill(unit_id: int) -> bool:
	if not GameManager.has_method("can_use_skill"):
		return false
	return bool(GameManager.call("can_use_skill", GameManager.PLAYER_ID, unit_id))


func _skill_blocked_reason(unit_id: int) -> String:
	if not GameManager.has_method("skill_blocked_reason"):
		return ""
	return str(GameManager.call("skill_blocked_reason", GameManager.PLAYER_ID, unit_id))


## 技能可指定的目标（与 `GameManager.get_valid_targets` 同结构：kind / unit_id / player_id）
func _valid_skill_targets(unit_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not GameManager.has_method("get_valid_skill_targets"):
		return out
	var raw: Variant = GameManager.call("get_valid_skill_targets", GameManager.PLAYER_ID, unit_id)
	if raw is Array:
		for item in raw:
			if item is Dictionary:
				var d: Dictionary = item
				out.append(d)
	return out


func _request_use_skill(unit_id: int, target_unit_id: int = -1, target_player_id: int = -1) -> bool:
	if not GameManager.has_method("request_use_skill"):
		_append_log("技能系统尚未就绪（GameManager.request_use_skill 未落地）")
		return false
	return bool(GameManager.call("request_use_skill", unit_id, target_unit_id, target_player_id))


## 真正发动技能：成功后自己关闭选目标状态（`_clear_mode()`），并把
## 「发动技能：X（消耗 N 能量点）」的回执留在操作栏与战斗日志里；
## 失败则保持原状态（玩家可以改选目标）。
func _fire_skill(unit_id: int, target_unit_id: int = -1, target_player_id: int = -1) -> bool:
	var u: BoardUnit = GameManager.find_unit(unit_id)
	if not _request_use_skill(unit_id, target_unit_id, target_player_id):
		_append_log("技能发动失败")
		return false
	_clear_mode()
	_play_sfx("play_card")
	_set_skill_notice("发动技能：%s（%s）" % [_skill_name(u), _skill_cost_text(u)])
	return true


## 目标待选中的技能名（提示文字用）
func _pending_skill_name() -> String:
	return _skill_name(GameManager.find_unit(pending_unit))


## 写一条临时说明：同时进操作栏与战斗日志（日志留下痕迹，操作栏随时可能被别的提示顶掉）
func _set_skill_notice(text: String) -> void:
	_notice = text
	_append_log(text)
	_update_hint(_my_turn())


## 点击我方单位时先尝试发动主动技能（消耗能量点 = 法力）。
## 返回 true = 这次点击已经由技能流程处理（直接发动 / 进入 SKILL_TARGET），调用方不要再走攻击流程；
## 返回 false = 单位没有技能、或技能本回合不可用 → 照旧走攻击流程（「先技能、后攻击」）。
func _try_start_skill(unit_id: int) -> bool:
	var u: BoardUnit = GameManager.find_unit(unit_id)
	if not _unit_has_skill(u):
		return false
	var sname: String = _skill_name(u)
	if _can_use_skill(unit_id):
		var list := _valid_skill_targets(unit_id)
		var needs_target: bool = _skill_target_kind(u) != CardData.Targeting.NONE
		if not u.data.has_method("skill_target"):
			# 规则层只落了一半接口（没有 skill_target）：用「有没有可选目标」来判断
			needs_target = not list.is_empty()
		if not needs_target:
			# 不需要目标：点一下直接发动
			_fire_skill(unit_id)
			return true
		if list.is_empty():
			_set_skill_notice("技能「%s」当前没有合法目标" % sname)
			return false
		# 需要目标：进入 SKILL_TARGET（枚举值在末尾，不影响既有状态）
		mode = Mode.SKILL_TARGET
		pending_unit = unit_id
		targets = list
		_notice = ""
		_append_log("「%s」技能：%s（%s）→ 请选择目标（右键取消）" % [
			u.data.card_name, sname, _skill_cost_text(u)])
		_update_hint(_my_turn())          # 操作栏立刻给出提示（整屏刷新下一帧还会再来一次）
		_request_refresh()
		return true
	# 技能不可用：把原因说清楚（操作栏 + 日志），然后回落到攻击流程
	var reason: String = _skill_blocked_reason(unit_id)
	var why := "技能「%s」（%s）现在无法发动" % [sname, _skill_cost_text(u)]
	if reason != "":
		why += "：" + reason
	_set_skill_notice(why)
	return false


func _is_target(unit_id: int, player_id: int) -> bool:
	for t in targets:
		var t_player: int = int(t["player_id"])
		if t_player != player_id:
			continue
		var t_unit: int = int(t["unit_id"])
		if unit_id >= 0 and t_unit == unit_id:
			return true
		if unit_id < 0 and str(t["kind"]) == "hero":
			return true
	return false


func _enter_card_target(index: int) -> void:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	var card: CardData = me.hand[index]
	targets = GameManager.get_valid_targets(GameManager.PLAYER_ID, card)
	if targets.is_empty():
		_append_log("「%s」当前没有合法目标" % card.card_name)
		return
	mode = Mode.CARD_TARGET
	pending_index = index
	_request_refresh()


func _enter_attack_target(unit_id: int) -> void:
	targets = GameManager.get_valid_attack_targets(GameManager.PLAYER_ID, unit_id)
	if targets.is_empty():
		_append_log("该随从本回合没有可攻击的目标")
		return
	mode = Mode.ATTACK_TARGET
	pending_unit = unit_id
	_request_refresh()


# ------------------------------ 拖拽操作 ------------------------------
#
# 两种拖拽：
#   1) 手牌 → 战场 / 目标：出牌（需要目标的牌拖到高亮目标上）
#   2) 我方随从 → 敌方目标：发起攻击
# 拖拽中由 DragLayer 上的“幽灵卡”跟随鼠标，并高亮当前可放置的位置。

func _my_turn() -> bool:
	return GameManager.game_active() and GameManager.current_player == GameManager.PLAYER_ID and not GameManager.busy


func _on_hand_card_drag_started(index: int) -> void:
	if drag_kind != DragKind.NONE:
		return
	if not _my_turn():
		_append_log("现在不是我方回合")
		return
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null or index < 0 or index >= me.hand.size():
		return
	# 打不出的牌也允许起拖（先拿起来看/比划），但幽灵卡是红色禁止样式、落点不亮，
	# 松手时把具体原因说清楚（原来这里是直接 return，玩家会觉得“拿起来却放不下”）。
	var forbidden: bool = not GameManager.can_play(GameManager.PLAYER_ID, index)
	_clear_mode()
	card_detail.hide_card()
	var card: CardData = me.hand[index]
	drag_kind = DragKind.CARD
	drag_index = index
	drag_forbidden = forbidden
	_drag_mouse = get_viewport().get_mouse_position()
	if not forbidden and card.needs_target():
		targets = GameManager.get_valid_targets(GameManager.PLAYER_ID, card)
	else:
		targets = [] as Array[Dictionary]
	_mark_dragged_card(true)
	_ghost = _make_ghost(card, 1.0, forbidden)
	_highlight_drop_targets(not forbidden)
	_request_refresh()          # 手牌此时会滑到下方正中（见 _sync_hand_dock）


func _on_unit_drag_started(unit_id: int) -> void:
	if drag_kind != DragKind.NONE:
		return
	if not _my_turn():
		return
	if GameManager.unit_owner(unit_id) != GameManager.PLAYER_ID:
		_append_log("只能指挥我方随从")
		return
	var unit := GameManager.find_unit(unit_id)
	if unit != null and unit.in_front:
		_append_log("防御格里的随从无法攻击（可以在自己回合把它移回后排，每个回合只能调整一次）")
		return
	_clear_mode()
	card_detail.hide_card()
	targets = GameManager.get_valid_attack_targets(GameManager.PLAYER_ID, unit_id)
	if targets.is_empty():
		_append_log("该随从本回合无法攻击（刚上场需要一回合准备，或攻击次数已用尽）")
		return
	var ui := _find_unit_ui(unit_id)
	if ui == null:
		return
	drag_kind = DragKind.ATTACK
	drag_unit = unit_id
	_drag_mouse = get_viewport().get_mouse_position()
	ui.set_dragging(true)
	_ghost = _make_ghost(ui.unit.data, 0.78)
	_highlight_drop_targets(true)


func _make_ghost(card: CardData, s: float, forbidden: bool = false) -> CardUI:
	var g := CARD_SCENE.instantiate() as CardUI
	if g == null:
		return null
	drag_layer.add_child(g)
	g.setup(card, -1, true)
	g.size = Vector2(CARD_W, CARD_H)
	g.scale = Vector2(s, s)
	# 幽灵卡跟着鼠标走，必须连子节点一起对鼠标透明，
	# 否则它自己的 RichTextLabel 会吃掉拖动途中经过的事件。
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiUtil.make_decorative(g)
	# set_forbidden 会按状态设定边框与色调（红色禁止样式），所以放在最后、不再覆盖 modulate
	g.set_forbidden(forbidden)
	return g


## 城邦格：主战者旁的两个格子（空着也画出来，方便玩家看到"这里能放城邦"）
func _update_city_slots() -> void:
	for info in [
		{"box": enemy_city_slot, "pid": GameManager.ENEMY_ID, "friendly": false},
		{"box": player_city_slot, "pid": GameManager.PLAYER_ID, "friendly": true},
	]:
		var box: Control = info["box"]
		if box == null:
			continue
		for child in box.get_children():
			child.queue_free()
		var u: BoardUnit = GameManager.city_slot_unit(info["pid"])
		var ui := CitySlotUI.new()
		box.add_child(ui)
		ui.setup(u, info["friendly"], _city_slot_hint(info["pid"]))
		ui.set_highlight(_is_target(u.unit_id, info["pid"]) if u != null else false)
		ui.unit_clicked.connect(_on_unit_clicked)
		ui.unit_hovered.connect(_on_card_hovered)
		ui.unit_hover_ended.connect(_on_card_hover_ended)


## 城邦格空置时的提示：距下次召唤还有几个自己的回合（判定回合显示「本回合判定」）
func _city_slot_hint(pid: int) -> String:
	var p: PlayerState = GameManager.get_player(pid)
	if p == null:
		return "空"
	var interval: int = GameManager.CITY_SLOT_INTERVAL
	var left: int = interval - (p.turns_taken % interval)
	if p.turns_taken > 0 and p.turns_taken % interval == 0 and p.city_summon_turn != GameManager.turn_count:
		return "本回合判定"
	return "距下次 %d 回合" % left


## 城邦格里的控件（供交互与测试查找）
func _live_city_uis() -> Array[CitySlotUI]:
	var out: Array[CitySlotUI] = []
	for box in [enemy_city_slot, player_city_slot]:
		if box == null:
			continue
		for child in box.get_children():
			if child is CitySlotUI and not child.is_queued_for_deletion():
				out.append(child)
	return out


## 城邦格控件（某一侧；没有则 null）
func city_slot_widget(pid: int) -> CitySlotUI:
	var box: Control = player_city_slot if pid == GameManager.PLAYER_ID else enemy_city_slot
	if box == null:
		return null
	for child in box.get_children():
		if child is CitySlotUI and not child.is_queued_for_deletion():
			return child
	return null


## 未被释放的随从控件。随从控件现在装在“格子”里（见 _update_board），所以要往下一层找；
## queue_free 的节点要到帧末才真正销毁，直接遍历会摸到已排队销毁的旧控件。
func _live_unit_uis(row: Control) -> Array[UnitUI]:
	var out: Array[UnitUI] = []
	for child in row.get_children():
		if child.is_queued_for_deletion():
			continue
		if child is UnitUI:
			out.append(child)
			continue
		for sub in child.get_children():
			if sub is UnitUI and not sub.is_queued_for_deletion():
				out.append(sub)
	return out


## 某个随从控件所在的那一格（普通 Control），供布局测试核对落点
func unit_cell(pid: int, unit_id: int) -> Control:
	var row: Control = player_board if pid == GameManager.PLAYER_ID else enemy_board
	for child in row.get_children():
		if child.is_queued_for_deletion() or child is UnitUI:
			continue
		for sub in child.get_children():
			if sub is UnitUI and not sub.is_queued_for_deletion() and sub.unit != null and sub.unit.unit_id == unit_id:
				return child
	return null


func _find_unit_ui(unit_id: int) -> UnitUI:
	for row in [enemy_board, player_board]:
		for child in _live_unit_uis(row):
			if child.unit.unit_id == unit_id:
				return child
	return null


func _mark_dragged_card(enabled: bool) -> void:
	for ui in hand_cards:
		if ui.index == drag_index:
			ui.set_dragging(enabled)


# ------------------------------ 指向箭头（替代黄色矩形标注） ------------------------------
#
# 正在释放的卡牌 / 正在攻击的随从 → 一条弧形箭头指向当前鼠标；
# 鼠标压到合法目标上时箭头吸附锁定到目标中心并加粗，松开即生效。

# ------------------------------ 抽牌堆（右侧 / 镜像左侧） ------------------------------

# ------------------------------ 统一皮肤（对齐同类游戏的观感） ------------------------------

func _apply_ui_skin() -> void:
	UiSkin.apply_panel(arena_panel, "arena")
	UiSkin.apply_panel(log_panel, "raised")
	UiSkin.apply_plain_panel(mid_seam, "seam")
	# 顶栏 / 操作栏 / 侧栏的按钮统一成胶囊按钮，并把「结束回合」做成强调色
	# 只统一顶栏按钮；操作栏里的「结束回合」是圆形按钮，属于控件自有设计
	var styled := UiSkin.apply_buttons($Root/Arena/TopBar)
	if mid_label != null:
		mid_label.add_theme_color_override("font_color", UiSkin.ACCENT)
		mid_label.add_theme_font_size_override("font_size", 22)
	if side_label != null:
		side_label.add_theme_color_override("font_color", UiSkin.TEXT)
	print("[UI] 皮肤已应用：%d 个按钮" % styled)


# ------------------------------ 场景背景图（管理员可配） ------------------------------

# ------------------------------ 美术设置入口（管理员） ------------------------------

var _art_button: Button = null
var _art_dialog = null


func _setup_art_button() -> void:
	var bar := get_node_or_null("Root/Arena/TopBar")
	if bar == null:
		return
	_art_button = Button.new()
	_art_button.name = "ArtButton"
	_art_button.text = "美术"
	_art_button.tooltip_text = "场景图片 / 卡牌卡图 / 出牌特效（需管理员登录）"
	_art_button.pressed.connect(_open_art_dialog)
	bar.add_child(_art_button)
	UiSkin.apply_button(_art_button)
	AdminAuth.login_state_changed.connect(func(_logged: bool) -> void: _refresh_art_button())
	_refresh_art_button()


func _refresh_art_button() -> void:
	if _art_button != null and is_instance_valid(_art_button):
		_art_button.visible = AdminAuth.is_logged_in


func _open_art_dialog() -> void:
	if not AdminAuth.is_logged_in:
		_append_log("[美术] 需要先登录管理员")
		return
	if _art_dialog == null or not is_instance_valid(_art_dialog):
		_art_dialog = load("res://scripts/ArtSettingsDialog.gd").new()
		add_child(_art_dialog)
		_art_dialog.closed.connect(func() -> void:
			if _art_dialog != null and is_instance_valid(_art_dialog):
				_art_dialog.queue_free()
			_art_dialog = null
			_apply_background()
			_request_refresh())
	_art_dialog.popup_centered()
	_apply_background()


## 供测试：美术设置对话框 / 顶栏美术按钮
func art_dialog():
	return _art_dialog


func art_button():
	return _art_button


## 供测试：场景背景图控件
func background_rect():
	return _bg_rect


func _apply_background() -> void:
	var tex := ArtStore.background_texture()
	# 有背景 / 战场预设图时，把竞技区面板的底色放半透明，让图透出来（文字仍压在深色底上可读）；
	# 没有图就恢复不透明（保持原来的观感）。
	_set_arena_translucent(tex != null)
	if tex == null:
		if _bg_rect != null and is_instance_valid(_bg_rect):
			_bg_rect.visible = false
		return
	if _bg_rect == null or not is_instance_valid(_bg_rect):
		var layer := CanvasLayer.new()
		layer.layer = -1                        # 压在所有内容之下
		add_child(layer)
		_bg_rect = TextureRect.new()
		_bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_bg_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		layer.add_child(_bg_rect)
	_bg_rect.texture = tex
	_bg_rect.visible = true


# ------------------------------ 伤害 / 治疗飘字 ------------------------------

## 竞技区面板底色的透明度：有战场背景图时放半透明，让底图透出来
func _set_arena_translucent(on: bool) -> void:
	var st := arena_panel.get_theme_stylebox("panel")
	if st is StyleBoxFlat:
		var flat: StyleBoxFlat = st
		var c := flat.bg_color
		flat.bg_color = Color(c.r, c.g, c.b, 0.42 if on else 1.0)

func _ensure_float_layer() -> Control:
	if _float_layer == null or not is_instance_valid(_float_layer):
		_float_layer = Control.new()
		_float_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_float_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		drag_layer.add_child(_float_layer)
		_float_layer.z_index = 60
	return _float_layer


func _spawn_float(text: String, color: Color, pos: Vector2, big: bool = false) -> void:
	var layer := _ensure_float_layer()
	var node = null
	for f in _floats:
		if f != null and is_instance_valid(f) and not f.is_playing():
			node = f
			break
	if node == null:
		node = load("res://scripts/FloatText.gd").new()
		layer.add_child(node)
		_floats.append(node)
	node.pop(text, color, pos, big)


func _on_amount_shown(pid: int, unit_id: int, amount: int, kind: String) -> void:
	if amount <= 0:
		return
	# 飘字**就落在受伤的那张卡 / 那位主战者身上**（见 _float_anchor）：
	# 即使伤害事件先于界面刷新到达，也能按「随从所在的格子」算出准确落点。
	var pos := _float_anchor(pid, unit_id)
	if pos == Vector2.ZERO:
		return
	# 数字本体只有 0-9（原版数字图集），符号由这里加在前缀、作为反馈的一部分。
	match kind:
		"heal":
			_spawn_float("+%d" % amount, Color("#69f0ae"), pos)
		"armor":
			_spawn_float("+%d" % amount, Color("#ffd54f"), pos)
		_:
			# 原版强击阈值 STRONG_DAMAGE_VALUE = 7（DamageVfx.cs:8）：≥7 放大 + 震屏 + 强打击特效
			var strong: bool = amount >= STRONG_DAMAGE
			_spawn_float("-%d" % amount, Color("#ff5252"), pos, strong)
			if strong:
				_shake_screen(amount)
			_impact_flash(pos, strong, pid)


## 飘字锚点：**受伤的那张卡 / 那位主战者身上**。优先级：
##   ① 随从 → 按它所在的**格子**算（`BoardSurface.slot_rect()` 与画出来的槽位同源，
##      所以伤害先于界面刷新到达也不会算错，更不会跑到主战者身上）；
##   ② 城邦格里的城邦 → 主战者旁城邦格的中心；
##   ③ 控件已经建好的其它情况 → 控件中心（`_unit_center`）；
##   ④ 全都没有（极罕见）→ 该方战场行的中心，**绝不**把随从的数字画到主战者头上。
func _float_anchor(pid: int, unit_id: int) -> Vector2:
	if unit_id < 0:
		return _hero_anchor(pid)
	var unit: BoardUnit = GameManager.find_unit(unit_id)
	if unit != null:
		if unit.in_city_slot:
			var cs = player_city_slot if unit.owner_id == GameManager.PLAYER_ID else enemy_city_slot
			if cs != null and is_instance_valid(cs):
				return cs.get_global_rect().get_center()
		var slot: int = GameManager.slot_of_unit(unit)
		if slot >= 0:
			var surface: BoardSurface = player_board if pid == GameManager.PLAYER_ID else enemy_board
			if surface != null and is_instance_valid(surface):
				return surface.global_position + surface.slot_rect(slot).get_center()
	var center: Vector2 = _unit_center(unit_id)
	if center != Vector2.ZERO:
		return center
	var row: BoardSurface = player_board if pid == GameManager.PLAYER_ID else enemy_board
	if row != null and is_instance_valid(row):
		return row.get_global_rect().get_center()
	return _hero_anchor(pid)


## 主战者锚点：落在**头像盘正中**（原版对主战者用固定偏移，DamageVfxBase.cs:19,21,97-101）。
## 再朝自己半场外侧挪几像素，避免压住盘右侧的血量徽章。
func _hero_anchor(pid: int) -> Vector2:
	var frame: HeroFrame = enemy_hero_frame if pid == GameManager.ENEMY_ID else player_hero_frame
	if frame == null or not is_instance_valid(frame):
		return Vector2.ZERO
	var c: Vector2 = frame.global_position + frame.disc_center_local()
	return c + Vector2(0.0, -8.0 if pid == GameManager.ENEMY_ID else 8.0)


## 供测试：某个随从 / 英雄的飘字锚点
func float_anchor(pid: int, unit_id: int) -> Vector2:
	return _float_anchor(pid, unit_id)


## 供测试：当前正在播放的飘字数量 / 文字
func floating_texts() -> Array:
	var out := []
	for f in _floats:
		if f != null and is_instance_valid(f) and f.is_playing():
			out.append(f)
	return out


## 强击震屏：原版 `Skill_special_win.ShakeScreen(value)`——幅度 `min(10,v)*0.02`、
## 时长 `min(10,v)*0.05+0.2`（Skill_special_win.cs:8-14,67-74）。这里换算成像素幅度。
func _shake_screen(value: int) -> void:
	var v := mini(10, maxi(0, value))
	var amp := float(v) * 2.0          ## 0.02 世界单位 ≈ 2px 的 2D 口径
	var dur := float(v) * 0.05 + 0.2
	if _shake_tween != null and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = create_tween()
	var steps := maxi(2, int(dur / 0.03))
	for i in range(steps):
		var t := float(i) / float(steps - 1)
		var decay := 1.0 - t
		var ox := amp * decay * (1.0 if i % 2 == 0 else -1.0)
		var oy := amp * 0.5 * decay * (1.0 if i % 2 == 0 else -1.0)
		_shake_tween.tween_property(drag_layer, "offset", Vector2(ox, oy), dur / float(steps))
	_shake_tween.tween_property(drag_layer, "offset", Vector2.ZERO, 0.03)


## 受伤打击感：出字的那一帧闪一下并朝受击方「顶开」（原版红闪 0/0.1/0.2s + 0.1 单位击退，
## DamageVfx.cs:23-24,38-55）。这里换成 2D 的圆点闪光 + 目标控件短促位移，纯表现、不改规则。
func _impact_flash(pos: Vector2, strong: bool, pid: int) -> void:
	var flash := Panel.new()
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := StyleBoxFlat.new()
	var col := Color("#ffd166") if strong else Color("#ff5252")
	st.bg_color = Color(col.r, col.g, col.b, 0.55 if strong else 0.4)
	st.set_corner_radius_all(999)
	flash.add_theme_stylebox_override("panel", st)
	var size := 40.0 if strong else 28.0
	flash.size = Vector2(size, size)
	flash.position = pos - flash.size * 0.5
	flash.z_index = 58
	drag_layer.add_child(flash)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(flash, "size", Vector2(size * 1.8, size * 1.8), 0.18)
	t.tween_property(flash, "position", pos - Vector2(size * 0.9, size * 0.9), 0.18)
	t.tween_property(flash, "modulate:a", 0.0, 0.18)
	t.chain().tween_callback(flash.queue_free)
	impacts.append({"pos": pos, "strong": strong})
	if impacts.size() > 32:
		impacts.pop_front()


## 供测试：强击震屏的当前位移幅度（0 = 没在震）
func shake_offset() -> Vector2:
	return drag_layer.offset if drag_layer != null else Vector2.ZERO


## 供测试：最近一次伤害打击感记录（pos / strong）
func last_impact() -> Dictionary:
	return impacts[-1] if not impacts.is_empty() else {}


# ------------------------------ 卡牌出牌特效 ------------------------------

func _on_card_played_vfx(pid: int, card: CardData) -> void:
	if card == null:
		return
	# 出牌语音：这张卡自己配了 play 语音就用它，否则回落到通用出牌音
	_voice("play", str(card.id), "play_card")
	if str(card.vfx) != "":
		var frame = enemy_hero_frame if pid == GameManager.ENEMY_ID else player_hero_frame
		var pos: Vector2 = frame.get_global_rect().get_center() if frame != null else Vector2.ZERO
		if pos != Vector2.ZERO:
			_spawn_vfx(str(card.vfx), pos)
	# 飞牌动画：起点是这张牌在手牌里的位置，落点要等战场重建完才知道（见 _flush_play_flights）
	_frame_played_ids[str(card.id)] = true
	var from := Vector2.ZERO
	if pid == GameManager.PLAYER_ID:
		from = _hand_card_center_for(card)
	else:
		var er: Rect2 = enemy_hand_row.get_global_rect()
		from = er.get_center()
	if from == Vector2.ZERO:
		return
	_pending_play.append({"pid": pid, "card": card, "from": from, "board": card.is_board_card()})


## 这张牌（刚从手牌打出、控件还在）在手牌里的中心；找不到返回 ZERO
func _hand_card_center_for(card: CardData) -> Vector2:
	for ui in hand_cards:
		if ui == null or not is_instance_valid(ui):
			continue
		if ui.data == card or (ui.data != null and ui.data.id == card.id):
			return ui.get_global_rect().get_center()
	return Vector2.ZERO


## 攻击：播这张卡的 attack 语音（没有就回落到通用攻击音）+ 攻击者小幅前冲
func _on_unit_attacked_fx(pid: int, unit_id: int, target_unit_id: int, target_player_id: int) -> void:
	var u: BoardUnit = GameManager.get_unit(pid, unit_id)
	if u == null or u.data == null:
		return
	_voice("attack", str(u.data.id), "attack")


## 由效果召唤入场：播 summon 语音 + 落点光环
func _on_unit_summoned_fx(pid: int, card: CardData) -> void:
	if card == null:
		return
	_voice("summon", str(card.id), "")
	var fx := _ensure_battle_fx()
	if fx == null:
		return
	var rect := _newest_unit_rect(pid, card.id)
	if rect.size.x > 1.0:
		fx.summon(rect.get_center(), rect.size * 0.9)


# ------------------------------ 战斗表现层：飞牌 / 死亡消失 ------------------------------

func _ensure_battle_fx() -> BattleFxScript:
	if _battle_fx == null or not is_instance_valid(_battle_fx):
		_battle_fx = BattleFxScript.new()
		drag_layer.add_child(_battle_fx)
		_battle_fx.z_index = 6             # 在随从之上、拖拽幽灵卡（30+）与箭头之下
	if _battle_fx != null:
		_battle_fx.speed = _anim_speed()
	return _battle_fx


## 供测试：战斗表现层控件
func battle_fx():
	return _ensure_battle_fx()


## 动画速度：0 = 立即完成（与抽牌 / 飘字同一套口径）
func _anim_speed() -> float:
	var sp := float(GameSettings.get("anim_speed"))
	if sp <= GameSettings.ANIM_SPEED_ZERO_EPSILON:
		return 0.0
	return clampf(sp, GameSettings.ANIM_SPEED_MIN, GameSettings.ANIM_SPEED_MAX)


## 卡牌语音优先；没有就回落到通用音效（`fallback` 为空时静音）
func _voice(event: String, card_id: String, fallback: String) -> bool:
	var v := get_node_or_null("/root/Voice")
	if v == null or not v.has_method("play_or"):
		if fallback != "":
			_play_sfx(fallback)
		return false
	return bool(v.play_or(event, card_id, fallback))


## 我方 / 敌方战场上**最新召唤**的那个随从的格子矩形（找不到返回空矩形）
func _newest_unit_rect(pid: int, card_id: String = "") -> Rect2:
	var p: PlayerState = GameManager.get_player(pid)
	if p == null:
		return Rect2()
	var best: BoardUnit = null
	for u in p.board:
		if card_id != "" and (u.data == null or u.data.id != card_id):
			continue
		if best == null or u.unit_id > best.unit_id:
			best = u
	if best == null:
		return Rect2()
	var cell := unit_cell(pid, best.unit_id)
	if cell == null:
		return Rect2()
	return cell.get_global_rect()


## 出牌飞牌：把这一帧打出的牌从手牌飞向它的落点
func _flush_play_flights() -> void:
	if _pending_play.is_empty():
		_frame_played_ids.clear()
		return
	var fx := _ensure_battle_fx()
	var pending := _pending_play
	_pending_play = []
	_frame_played_ids.clear()
	if fx == null:
		return
	for item in pending:
		var pid: int = int(item["pid"])
		var card: CardData = item["card"]
		var from: Vector2 = item["from"]
		var to := Vector2.ZERO
		var size := Vector2(118, 170)
		if bool(item["board"]):
			var rect := _newest_unit_rect(pid, str(card.id))
			if rect.size.x > 1.0:
				to = rect.get_center()
				size = rect.size * 0.92
		if to == Vector2.ZERO:
			to = _last_vfx_pos if _last_vfx_pos != Vector2.ZERO else _hero_anchor(pid)
		if to == Vector2.ZERO:
			continue
		fx.play_card(from, to, card, size)


## 随从快照：发现「这一帧消失的单位」→ 在原位置播死亡 / 消失动画 + 语音；
## 发现「这一帧新出现的单位」→ 播召唤光环（从手牌打出的那张由飞牌负责，不重复）。
func _update_unit_snapshot() -> void:
	var fx := _ensure_battle_fx()
	var now: Dictionary = {}
	for pid in [GameManager.PLAYER_ID, GameManager.ENEMY_ID]:
		var p: PlayerState = GameManager.get_player(pid)
		if p == null:
			continue
		for u in p.board:
			var rect := Rect2()
			var cell := unit_cell(pid, u.unit_id)
			if cell != null:
				rect = cell.get_global_rect()
			if rect.size.x <= 1.0 and _unit_snapshot.has(u.unit_id):
				rect = _unit_snapshot[u.unit_id]["rect"]      # 布局还没跑完：沿用上一帧的矩形
			now[u.unit_id] = {"rect": rect, "card": u.data, "friendly": pid == GameManager.PLAYER_ID}
	# 消失的单位：死亡 / 消失动画 + 语音
	for uid in _unit_snapshot.keys():
		if now.has(uid):
			continue
		var old: Dictionary = _unit_snapshot[uid]
		var rect: Rect2 = old["rect"]
		var card = old.get("card")
		if fx != null and rect.size.x > 1.0:
			fx.death(rect.get_center(), rect.size * 0.95, card)
		_voice("death", str(card.id) if card != null else "", "")
	# 新出现的单位：召唤登场光环（同一张卡刚被「打出」时不重复播）
	for uid in now.keys():
		if _unit_snapshot.has(uid):
			continue
		var e: Dictionary = now[uid]
		var c = e.get("card")
		if c != null and _frame_played_ids.has(str(c.id)):
			continue
		if fx != null and e["rect"].size.x > 1.0:
			fx.summon(e["rect"].get_center(), e["rect"].size * 0.9)
	_unit_snapshot = now


## 出牌特效：一圈彩色扩散光环（颜色由 ArtStore.VFX_COLORS 决定）
func _spawn_vfx(vfx: String, pos: Vector2) -> void:
	var ring := Panel.new()
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	var col := ArtStore.vfx_color(vfx)
	style.bg_color = Color(col.r, col.g, col.b, 0.0)
	style.border_color = Color(col.r, col.g, col.b, 0.95)
	style.set_border_width_all(4)
	style.set_corner_radius_all(48)
	ring.add_theme_stylebox_override("panel", style)
	ring.size = Vector2(56, 56)
	ring.position = pos - ring.size * 0.5
	ring.z_index = 55
	_last_vfx_pos = pos
	drag_layer.add_child(ring)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(ring, "size", Vector2(150, 150), 0.45)
	tween.tween_property(ring, "position", pos - Vector2(75, 75), 0.45)
	tween.tween_property(ring, "modulate:a", 0.0, 0.5)
	tween.chain().tween_callback(ring.queue_free)


func _ensure_pile(which: String):
	var pile = _player_pile if which == "player" else _enemy_pile
	if pile == null or not is_instance_valid(pile):
		pile = load("res://scripts/DeckPile.gd").new()
		drag_layer.add_child(pile)
		pile.z_index = 5                     # 在幽灵卡 / 指向箭头之下
		pile.auto_decrement = false          # 厚度只认真实牌数，动画纯视觉
		if which == "player":
			_player_pile = pile
		else:
			_enemy_pile = pile
	return pile


## 供测试：牌堆控件
func player_pile():
	return _player_pile


func enemy_pile():
	return _enemy_pile


## 刷新牌堆位置、厚度与抽卡落点：我方在手牌区**右侧**，敌方镜像在其手牌行左侧。
## 每帧刷新时顺带把「翻牌落点」与「手牌终点」算成当前布局的真实坐标，
## 于是飞牌（0.65s）会一路跟着真实手牌槽位走（DeckPile 每帧读 draw_target）。
func _update_piles() -> void:
	var me_pile = _ensure_pile("player")
	var foe_pile = _ensure_pile("enemy")
	if me_pile == null or foe_pile == null:
		return
	var pr: Rect2 = hand_area.get_global_rect()
	var er: Rect2 = enemy_hand_row.get_global_rect()
	# 我方牌堆挪到**手牌区上方**的右侧：不再压住手牌与卡牌详情
	var pile_h: float = me_pile.custom_minimum_size.y
	me_pile.position = Vector2(pr.end.x - me_pile.custom_minimum_size.x + 6.0, pr.position.y - pile_h - 6.0)
	# 敌方镜像：放在其手牌行**下方**的左侧
	foe_pile.position = Vector2(er.position.x - 14.0, er.end.y + 6.0)
	# 翻牌落点：照原版 PlayerDrawCardVfx.cs:45-59 的归一化公式（随窗口宽高比自适应）：
	#   num = aspect * 0.9；单张 pos = (0.25*num, -0.23*num, -0.7)（世界坐标，屏幕中心为原点）
	var pt := _reveal_point()
	me_pile.draw_target = _drawn_card_target(true)
	foe_pile.draw_target = _drawn_card_target(false)
	me_pile.reveal_target = pt
	foe_pile.reveal_target = pt
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	var foe: PlayerState = GameManager.get_player(GameManager.ENEMY_ID)
	if me != null:
		me_pile.set_count(me.deck.size())
	if foe != null:
		foe_pile.set_count(foe.deck.size())


## 原版抽牌落点（全局坐标）：`num = aspect * 0.9`，卡落在屏幕中心偏右、略偏下的位置。
func _reveal_point() -> Vector2:
	var vp := get_viewport_rect().size
	if vp.x < 1.0 or vp.y < 1.0:
		return Vector2.ZERO
	var num: float = (vp.x / vp.y) * 0.9
	return vp * 0.5 + Vector2(0.25 * num, -0.23 * num)


## 抽牌动画的终点：刚抽到的那张牌在手牌里的位置（还没建控件时退化为手牌区末端）。
func _drawn_card_target(for_player: bool) -> Vector2:
	if for_player:
		var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
		if me != null and not me.hand.is_empty():
			var center := _hand_card_center(me.hand.size() - 1)
			if center != Vector2.ZERO:
				return center
		var pr: Rect2 = hand_area.get_global_rect()
		return Vector2(pr.end.x - CARD_W * 0.5, pr.get_center().y)
	var er: Rect2 = enemy_hand_row.get_global_rect()
	return er.get_center()


## 有人抽到牌：对应牌堆播**原版时序**的抽卡动画（0.40s 翻牌 + 0.25s 入手），
## 厚度在动画开始的那一帧就少一张（原版 DummyDeckChangeCardVfx.cs:41 是瞬时的）。
func _on_card_drawn(pid: int, n: int) -> void:
	if n <= 0 or GameManager.net_locked:
		return
	var for_me: bool = pid == GameManager.PLAYER_ID
	var pile = _ensure_pile("player" if for_me else "enemy")
	if pile == null:
		return
	# 刚抽到的那张牌 = 手牌最后一张（draw() 是 append 进手牌的）
	var card: CardData = null
	var p: PlayerState = GameManager.get_player(pid)
	if p != null and not p.hand.is_empty():
		card = p.hand[p.hand.size() - 1]
	_update_piles()
	# 原版 t=0：位移开始（se_sys_draw）；只有玩家自己的抽牌会翻开正面
	pile.play_draw(pile.draw_target, for_me, card, 0.0)
	_play_sfx("draw" if for_me else "button")


## 供测试：翻牌落点（原版 PlayerDrawCardVfx 的公式）
func reveal_point() -> Vector2:
	return _reveal_point()


func _ensure_arrow():
	if _arrow == null or not is_instance_valid(_arrow):
		_arrow = load("res://scripts/TargetArrow.gd").new()
		drag_layer.add_child(_arrow)
		_arrow.z_index = 40
	return _arrow


## 供测试：当前箭头控件 / 是否正在显示
func target_arrow():
	return _arrow


func target_arrow_active() -> bool:
	return _arrow != null and is_instance_valid(_arrow) and _arrow.active


## 箭头起点：正在释放的卡牌 / 正在攻击的随从 / 正在发动技能的随从；没有就返回空
func _arrow_source() -> Dictionary:
	if mode == Mode.CARD_TARGET and pending_index >= 0:
		return {"center": _hand_card_center(pending_index), "kind": "spell"}
	if mode == Mode.SKILL_TARGET and pending_unit >= 0:
		# 技能同样走「法术」箭头：从发动者指向被指定的目标（落点高亮沿用同一套逻辑）
		return {"center": _unit_center(pending_unit), "kind": "spell"}
	if mode == Mode.ATTACK_TARGET and pending_unit >= 0:
		return {"center": _unit_center(pending_unit), "kind": "attack"}
	if drag_kind == DragKind.ATTACK and (drag_unit >= 0 or drag_index >= 0):
		var c: Vector2 = _unit_center(drag_unit) if drag_unit >= 0 else _hand_card_center(drag_index)
		return {"center": c, "kind": "attack"}
	if drag_kind == DragKind.CARD and drag_index >= 0:
		var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
		var targeted := me != null and drag_index < me.hand.size() and me.hand[drag_index].needs_target()
		return {"center": _hand_card_center(drag_index), "kind": "spell" if targeted else "place", "mode": "point" if targeted else "place"}
	return {}


func _hand_card_center(index: int) -> Vector2:
	for ui in hand_cards:
		if ui != null and is_instance_valid(ui) and int(ui.index) == index:
			return ui.get_global_rect().get_center()
	return Vector2.ZERO


func _unit_center(unit_id: int) -> Vector2:
	for row in [player_board, enemy_board]:
		for ui in _live_unit_uis(row):
			if ui.unit != null and ui.unit.unit_id == unit_id:
				return ui.get_global_rect().get_center()
	for cu in _live_city_uis():
		if cu.unit != null and cu.unit.unit_id == unit_id:
			return cu.get_global_rect().get_center()
	return Vector2.ZERO


## 鼠标下的合法目标（随从 / 城邦 / 英雄）；没有则返回空
func _target_under_mouse() -> Dictionary:
	var mouse := _mouse_now()
	for info in [{"row": enemy_board, "pid": GameManager.ENEMY_ID}, {"row": player_board, "pid": GameManager.PLAYER_ID}]:
		for ui in _live_unit_uis(info["row"]):
			if ui.unit == null or not _is_target(ui.unit.unit_id, int(info["pid"])):
				continue
			var r: Rect2 = ui.get_global_rect()
			if r.has_point(mouse):
				return {"center": r.get_center(), "unit_id": ui.unit.unit_id, "player_id": int(info["pid"])}
	for cu in _live_city_uis():
		if cu.unit == null or not _is_target(cu.unit.unit_id, cu.unit.owner_id):
			continue
		var rc: Rect2 = cu.get_global_rect()
		if rc.has_point(mouse):
			return {"center": rc.get_center(), "unit_id": cu.unit.unit_id, "player_id": cu.unit.owner_id}
	for info in [{"frame": enemy_hero_frame, "pid": GameManager.ENEMY_ID}, {"frame": player_hero_frame, "pid": GameManager.PLAYER_ID}]:
		var fr = info["frame"]
		if fr == null or not is_instance_valid(fr) or not _is_target(-1, int(info["pid"])):
			continue
		var rh: Rect2 = fr.get_global_rect()
		if rh.has_point(mouse):
			return {"center": rh.get_center(), "unit_id": -1, "player_id": int(info["pid"])}
	return {}


## 当前鼠标位置：优先用最近一次事件里的坐标（无头 / 自动化下真实光标不可靠）
func _mouse_now() -> Vector2:
	if _last_mouse != Vector2.ZERO:
		return _last_mouse
	return get_viewport().get_mouse_position()


func _update_target_arrow() -> void:
	var arrow = _ensure_arrow()
	if arrow == null:
		return
	var src := _arrow_source()
	if src.is_empty():
		arrow.hide_arrow()
		return
	var from: Vector2 = src["center"]
	if from == Vector2.ZERO:
		arrow.hide_arrow()
		return
	var hit := _target_under_mouse()
	var usable := _arrow_target_usable(hit)
	if hit.is_empty():
		arrow.show_arrow(from, _mouse_now(), str(src["kind"]), usable)
		arrow.unlock_target()
	else:
		arrow.show_arrow(from, hit["center"], str(src["kind"]), usable)
		arrow.lock_to(hit["center"])


## 这次拖拽/选目标是否由箭头表达（是则不显示矩形落点提示）
## 当前是否"可用"：卡牌能不能打出去 / 指向的能不能指定 / 落点能不能放
func _arrow_target_usable(hit: Dictionary) -> bool:
	if drag_forbidden:
		return false                                # 这张牌现在根本打不出去 → 红
	if mode == Mode.CARD_TARGET or mode == Mode.ATTACK_TARGET or mode == Mode.SKILL_TARGET:
		return not hit.is_empty()                   # 点选模式：有没有压到合法目标
	if drag_kind == DragKind.ATTACK:
		return not hit.is_empty()
	if drag_kind == DragKind.CARD:
		var src := _arrow_source()
		if str(src.get("mode", "point")) == "place":
			return _drop_valid(_drop_target_at(_mouse_now()))   # 放置型：落点合法才绿
		return not hit.is_empty()
	return not hit.is_empty()


func _arrow_handles_drop() -> bool:
	if mode == Mode.CARD_TARGET or mode == Mode.ATTACK_TARGET or mode == Mode.SKILL_TARGET:
		return true
	if drag_kind == DragKind.ATTACK:
		return true
	if drag_kind == DragKind.CARD:
		var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
		return me != null and drag_index >= 0 and drag_index < me.hand.size() and me.hand[drag_index].needs_target()
	return false


func _highlight_drop_targets(enabled: bool) -> void:
	for row in [enemy_board, player_board]:
		for uu in _live_unit_uis(row):
			uu.set_highlight(false)          # 目标标注改用指向箭头（TargetArrow），不再画黄色矩形
	# 城邦格里的城邦也是可以指定的目标
	for cu in _live_city_uis():
		if cu.unit != null:
			cu.set_highlight(false)
	enemy_hero_frame.set_highlight(false)
	player_hero_frame.set_highlight(false)


func _ensure_drop_hint() -> Panel:
	if _drop_hint != null and is_instance_valid(_drop_hint):
		return _drop_hint
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.z_index = -1
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.36, 0.55, 0.42, 0.16)
	st.border_color = Color("#ffee58")
	st.set_border_width_all(3)
	st.set_corner_radius_all(10)
	p.add_theme_stylebox_override("panel", st)
	drag_layer.add_child(p)
	_drop_hint = p
	return p


func _process(_delta: float) -> void:
	if _refresh_dirty:
		_refresh_dirty = false
		_refresh()
	# 中线两端的按钮挂在 CanvasLayer 上、按中线接缝的全局矩形定位，所以每帧校正一次：
	# 只在 resized 时校正会因为“布局尚未稳定时先算了一次”而停在错误位置。
	_layout_midline_controls()
	_layout_hero_frames()
	if drag_kind == DragKind.NONE or _ghost == null:
		return
	_ghost.position = _drag_mouse - _ghost.size * 0.5
	_update_drop_feedback(_drag_mouse)


func _update_drop_feedback(mouse: Vector2) -> void:
	# 打不出的牌：不点亮任何落点，只在操作栏说明原因（幽灵卡本身是红色禁止样式）
	if drag_forbidden:
		var hint0 := _ensure_drop_hint()
		hint0.visible = false                 # 落点方框整体取消：一律用箭头表达（绿=可用 / 红=不可用）
		_clear_slot_hover()
		hint_label.text = "%s（右键取消）" % _cannot_play_reason(drag_index)
		return
	var drop := _drop_target_at(mouse)
	var ok := _drop_valid(drop)
	var hint := _ensure_drop_hint()
	hint.visible = false                 # 落点方框整体取消：一律用箭头表达（绿=可用 / 红=不可用）
	if ok:
		var rect: Rect2 = drop["rect"]
		hint.position = rect.position - Vector2(4, 4)
		hint.size = rect.size + Vector2(8, 8)
	# 「拖到哪个格子就放进哪个格子」：把正在指向的格子交给战场地面描一圈（绿=可放 / 红=不可放）
	_show_slot_hover(drop, ok)
	if drag_kind == DragKind.ATTACK:
		hint_label.text = "松开鼠标：攻击高亮目标（右键取消）"
	else:
		hint_label.text = "松开鼠标：把「%s」放到高亮位置（右键取消）" % _drag_card_name()


## 拖拽时高亮「正在指向的那一格」：只要落点是我们自己的战场（含横置格）就标出来，
## 该格可放 = 绿、被占用 / 不是这一侧 = 红。落点在别处（目标 / 手牌 / 空白）时全部清掉。
func _show_slot_hover(drop: Dictionary, ok: bool) -> void:
	var kind: String = str(drop.get("kind", "")) if not drop.is_empty() else ""
	var pid: int = int(drop.get("player_id", -1)) if not drop.is_empty() else -1
	var slot: int = int(drop.get("slot", -1)) if not drop.is_empty() else -1
	if slot < 0 or (kind != "board" and kind != "front"):
		_clear_slot_hover()
		return
	var surface: BoardSurface = player_board if pid == GameManager.PLAYER_ID else enemy_board
	var other: BoardSurface = enemy_board if pid == GameManager.PLAYER_ID else player_board
	other.set_hover_slot(-1)
	surface.set_hover_slot(slot, ok)


func _clear_slot_hover() -> void:
	player_board.set_hover_slot(-1)
	enemy_board.set_hover_slot(-1)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_last_mouse = event.position
	# AI 浮窗输入中：键盘全部让路（否则打字会撞上空格 = 结束回合等热键）
	var ai := get_node_or_null("/root/AiAssistant")
	if ai != null and ai.has_method("input_focused") and ai.input_focused():
		return
	# 快捷键（弹窗打开时不抢键；观战 / 非我方回合由 request_* 自己拦住）
	if event is InputEventKey and event.pressed and not event.echo and _handle_shortcut(event.keycode):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		# Esc 优先收起记牌器抽屉，其次取消拖拽（拖拽的取消沿用原有逻辑）
		if _close_tracker_if_open():
			get_viewport().set_input_as_handled()
			return
		# 再次：取消「等目标」状态（出牌 / 攻击 / 技能都走 _clear_mode，与右键一致）
		if mode != Mode.IDLE and drag_kind == DragKind.NONE:
			_clear_mode()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion:
		_drag_mouse = event.position
		_last_mouse = event.position
		_update_target_arrow()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_drag_mouse = event.position
		_last_mouse = event.position
		_update_target_arrow()
	if drag_kind == DragKind.NONE:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_finish_drag()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_append_log("已取消拖动")
			_end_drag()
			get_viewport().set_input_as_handled()


## 命中判定：横置格 / 随从 / 英雄 / 战场行 / 整个竞技区（两侧手牌区不作为放置区）
## 横置格先判：它压在正中那一格上，落在那里一律按“放进横置格 / 指定横置的随从”处理。
## 其余落点回传 `slot`（格子号）：这是「拖到哪个格子就放进哪个格子」的落点权威来源。
func _drop_target_at(pos: Vector2) -> Dictionary:
	if hand_area.get_global_rect().has_point(pos) or enemy_hand_row.get_global_rect().has_point(pos):
		return {}
	for info in [{"row": enemy_board, "pid": GameManager.ENEMY_ID}, {"row": player_board, "pid": GameManager.PLAYER_ID}]:
		var surface := info["row"] as BoardSurface
		if surface == null:
			continue
		var lane: int = surface.slot_at_global_point(pos)
		if lane < 0 or not surface.is_front_lane(lane):
			continue
		var local := surface.slot_rect(lane)
		var rect := Rect2(surface.global_position + local.position, local.size)
		var front := GameManager.front_unit(info["pid"])
		return {
			"kind": "front",
			"player_id": info["pid"],
			"unit_id": front.unit_id if front != null else -1,
			"rect": rect,
			"slot": lane,
		}
	for info in [{"row": enemy_board, "pid": GameManager.ENEMY_ID}, {"row": player_board, "pid": GameManager.PLAYER_ID}]:
		var row: HBoxContainer = info["row"]
		for uu in _live_unit_uis(row):
			var r := uu.get_global_rect()
			if r.has_point(pos):
				return {"kind": "unit", "player_id": info["pid"], "unit_id": uu.unit.unit_id, "rect": r}
	# 城邦格里的城邦（在主战者旁，不占战场格子）
	for cu in _live_city_uis():
		if cu.unit == null:
			continue
		var cr := cu.get_global_rect()
		if cr.has_point(pos):
			return {"kind": "unit", "player_id": cu.unit.owner_id, "unit_id": cu.unit.unit_id, "rect": cr}
	for h in [{"frame": enemy_hero_frame, "pid": GameManager.ENEMY_ID}, {"frame": player_hero_frame, "pid": GameManager.PLAYER_ID}]:
		var frame: HeroFrame = h["frame"]
		if frame.contains_global_point(pos):
			return {"kind": "hero", "player_id": h["pid"], "unit_id": -1, "rect": frame.visual_rect()}

	var pr := player_board.get_global_rect()
	if pr.has_point(pos):
		return {"kind": "board", "player_id": GameManager.PLAYER_ID, "unit_id": -1, "rect": pr,
			"slot": player_board.nearest_slot_local_x(pos.x - player_board.global_position.x)}
	var er := enemy_board.get_global_rect()
	if er.has_point(pos):
		return {"kind": "board", "player_id": GameManager.ENEMY_ID, "unit_id": -1, "rect": er,
			"slot": enemy_board.nearest_slot_local_x(pos.x - enemy_board.global_position.x)}
	var ar := arena_panel.get_global_rect()
	if ar.has_point(pos):
		var pid: int = GameManager.PLAYER_ID if pos.y > _arena_midline_y() else GameManager.ENEMY_ID
		var surface: BoardSurface = player_board if pid == GameManager.PLAYER_ID else enemy_board
		return {"kind": "board", "player_id": pid, "unit_id": -1, "rect": ar,
			"slot": surface.nearest_slot_local_x(pos.x - surface.global_position.x)}
	return {}


## 上下半场的分界线（全局坐标）：敌方战场底边与我方战场顶边的中点。
## 注意必须用 get_global_rect()：鼠标位置是全局坐标，混用局部坐标会算错归属半场。
func _arena_midline_y() -> float:
	var er := enemy_board.get_global_rect()
	var pr := player_board.get_global_rect()
	return (er.position.y + er.size.y + pr.position.y) * 0.5


## 本回合还能不能调整防御格（移入 / 移出共用一个名额，且只能在自己的回合）
func _can_move_front_now() -> bool:
	if not GameManager.has_method("can_move_front"):
		return true                     # 规则层没落地时不做限制（界面兜底，不崩）
	return bool(GameManager.can_move_front(GameManager.PLAYER_ID))


## 正在拖的这个单位是不是就在防御格里（决定「拖回我方后排」是移出还是无效操作）
func _drag_unit_is_in_front() -> bool:
	if drag_unit < 0:
		return false
	var u: BoardUnit = GameManager.find_unit(drag_unit)
	return u != null and u.in_front


func _drop_valid(drop: Dictionary) -> bool:
	if drop.is_empty():
		return false
	var uid: int = int(drop["unit_id"])
	var pid: int = int(drop["player_id"])
	var is_front: bool = str(drop["kind"]) == "front"
	if drag_kind == DragKind.ATTACK:
		if is_front:
			# 拖到自己这边的防御格＝把它移进去；拖到对面＝攻击格里的那个随从
			if pid == GameManager.PLAYER_ID:
				return _can_move_front_now()
			return _is_target(uid, pid)
		if pid == GameManager.PLAYER_ID and str(drop["kind"]) == "board":
			# 拖到**我方战场后排**：把防御格里的随从移出来（本回合唯一的调整名额）
			return _drag_unit_is_in_front() and _can_move_front_now()
		return _is_target(uid, pid)
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null or drag_index < 0 or drag_index >= me.hand.size():
		return false
	var card: CardData = me.hand[drag_index]
	if is_front:
		if pid == GameManager.PLAYER_ID:
			# 自己这边：不需要目标的随从可以直接移进防御格（但要受本回合名额限制）
			if card.card_type == CardData.CardType.MINION and not card.needs_target():
				return _can_move_front_now()
		return uid >= 0 and _is_target(uid, pid)
	if card.needs_target():
		# 战吼没有合法目标：拖到我方战场即可直接上场（战吼空放）
		if card.is_board_card() and not GameManager.has_valid_targets(GameManager.PLAYER_ID, card):
			return pid == GameManager.PLAYER_ID
		return _is_target(uid, pid)
	if card.card_type != CardData.CardType.SPELL and pid != GameManager.PLAYER_ID:
		return false
	# 指定格子落点：那一格被占用就不能放（城邦走主战者旁的城邦格，不受此限）
	var slot: int = int(drop.get("slot", -1))
	if card.is_board_card() and not card.is_city() and slot >= 0:
		if GameManager.board_slot(GameManager.PLAYER_ID, slot) != null:
			return false
	return true


func _finish_drag() -> void:
	var drop := _drop_target_at(_drag_mouse)
	if drag_kind == DragKind.CARD:
		_finish_card_drag(drop)
	elif drag_kind == DragKind.ATTACK:
		_finish_attack_drag(drop)
	_end_drag()


func _finish_card_drag(drop: Dictionary) -> void:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null or drag_index < 0 or drag_index >= me.hand.size():
		return
	# 打不出的牌：无论松在哪里都只说明原因（幽灵卡已经提示过是禁止样式）
	if drag_forbidden:
		_append_log(_cannot_play_reason(drag_index))
		return
	var card: CardData = me.hand[drag_index]
	if str(drop["kind"]) == "front":
		# 自己这边：不需要目标的随从直接移进防御格（与「移出」共用每回合一次的名额）
		var to_own_front: bool = int(drop["player_id"]) == GameManager.PLAYER_ID
		if to_own_front and card.card_type == CardData.CardType.MINION and not card.needs_target():
			if not _can_move_front_now():
				_append_log(GameManager.front_move_blocked_reason(GameManager.PLAYER_ID))
				return
			GameManager.request_play(drag_index, -1, -1, true)
			return
		# 对面：按规则这一侧只有防御格里的那个随从能被技能指定
		var fid: int = int(drop["unit_id"])
		if card.needs_target() and fid >= 0 and _is_target(fid, int(drop["player_id"])):
			GameManager.request_play(drag_index, fid, int(drop["player_id"]))
		else:
			_append_log("「%s」不能放进防御格" % card.card_name)
		return
	if card.needs_target():
		# 战吼没有合法目标：拖到我方战场就直接上场（战吼空放）
		if card.is_board_card() and not GameManager.has_valid_targets(GameManager.PLAYER_ID, card):
			if drop.is_empty() or int(drop["player_id"]) != GameManager.PLAYER_ID:
				_append_log("「%s」没有合法目标，拖到我方战场可直接上场（战吼空放）" % card.card_name)
				return
			GameManager.request_play(drag_index, -1, -1, false, int(drop.get("slot", -1)))
			return
		if drop.is_empty() or str(drop["kind"]) == "board":
			_append_log("「%s」需要指定目标：请拖到高亮的目标上" % card.card_name)
			return
		var uid: int = int(drop["unit_id"])
		var pid: int = int(drop["player_id"])
		if not _is_target(uid, pid):
			_append_log("这不是「%s」的合法目标" % card.card_name)
			return
		GameManager.request_play(drag_index, uid, pid)
		return
	if drop.is_empty():
		_append_log("拖动已取消：请把卡牌拖到战场上再松手")
		return
	if card.card_type != CardData.CardType.SPELL and int(drop["player_id"]) != GameManager.PLAYER_ID:
		_append_log("随从 / 护符 / 城邦只能放置到我方战场")
		return
	# 「拖到哪个格子就放进哪个格子」：落点回传的 slot 直接交给出牌流程
	GameManager.request_play(drag_index, -1, -1, false, int(drop.get("slot", -1)))


func _finish_attack_drag(drop: Dictionary) -> void:
	if drop.is_empty():
		_append_log("拖动已取消：请拖到要攻击的敌方目标上")
		return
	if str(drop["kind"]) == "front":
		# 拖到自己的防御格＝把随从移进去；拖到对面＝攻击格里的那个随从
		if int(drop["player_id"]) == GameManager.PLAYER_ID:
			if not _can_move_front_now():
				_append_log(GameManager.front_move_blocked_reason(GameManager.PLAYER_ID))
				return
			if not GameManager.request_front(drag_unit):
				_append_log("移入防御格失败（%s）" % GameManager.front_move_blocked_reason(GameManager.PLAYER_ID))
			return
		var fid: int = int(drop["unit_id"])
		if fid >= 0 and _is_target(fid, int(drop["player_id"])):
			GameManager.request_attack(drag_unit, fid, int(drop["player_id"]))
			_play_sfx("attack")
		else:
			_append_log("防御格里没有可以攻击的随从")
		return
	if str(drop["kind"]) == "board" and int(drop["player_id"]) == GameManager.PLAYER_ID:
		# 拖到**我方战场后排**＝把防御格里的随从移出来（与移入共用一个名额）
		if not _drag_unit_is_in_front():
			_append_log("只有防御格里的随从能这样移动；后排随从不能随意挪格子")
			return
		if not _can_move_front_now():
			_append_log(GameManager.front_move_blocked_reason(GameManager.PLAYER_ID))
			return
		var to_slot: int = int(drop.get("slot", -1))
		if not GameManager.request_leave_front(drag_unit, to_slot):
			_append_log("移出防御格失败（%s）" % GameManager.front_move_blocked_reason(GameManager.PLAYER_ID))
		return
	if str(drop["kind"]) == "board":
		_append_log("拖动已取消：请拖到要攻击的敌方目标上")
		return
	var uid: int = int(drop["unit_id"])
	var pid: int = int(drop["player_id"])
	if not _is_target(uid, pid):
		_append_log("无法攻击该目标（嘲讽限制？）")
		return
	GameManager.request_attack(drag_unit, uid, pid)


func _end_drag() -> void:
	_clear_slot_hover()
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	if _drop_hint != null and is_instance_valid(_drop_hint):
		_drop_hint.visible = false
	_mark_dragged_card(false)
	for row in [enemy_board, player_board]:
		for uu in _live_unit_uis(row):
			uu.set_dragging(false)
	_highlight_drop_targets(false)
	drag_kind = DragKind.NONE
	drag_index = -1
	drag_unit = -1
	drag_forbidden = false
	targets.clear()
	_request_refresh()


func _drag_card_name() -> String:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me != null and drag_index >= 0 and drag_index < me.hand.size():
		return me.hand[drag_index].card_name
	return "卡牌"


# ------------------------------ 卡牌详情面板 ------------------------------

func _on_card_hovered(data: CardData, rect: Rect2) -> void:
	if drag_kind != DragKind.NONE or data == null or not GameSettings.hover_detail:
		return
	_detail_pinned = false
	card_detail.show_card(data, rect)


func _on_card_hover_ended() -> void:
	if _detail_pinned or drag_kind != DragKind.NONE:
		return
	card_detail.hide_card()


## 点击后固定显示，直到出牌 / 右键 / 取消选择
func _pin_hand_detail(index: int) -> void:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null or index < 0 or index >= me.hand.size() or not GameSettings.hover_detail:
		return
	_detail_pinned = true
	card_detail.show_card(me.hand[index], _hand_card_rect(index))


func _pin_unit_detail(unit_id: int) -> void:
	var ui := _find_unit_ui(unit_id)
	if ui == null or not GameSettings.hover_detail:
		return
	_detail_pinned = true
	card_detail.show_card(ui.unit.data, ui.get_global_rect())


func _hand_card_rect(index: int) -> Rect2:
	for ui in hand_cards:
		if ui.index == index:
			return ui.get_global_rect()
	return Rect2()


# ------------------------------ 玩家交互（点击方式） ------------------------------


## 右键手牌：带融合的卡 → 打开融合窗；其它牌 → 取消当前选择（原行为）
func _on_hand_card_right_clicked(index: int) -> void:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me != null and index >= 0 and index < me.hand.size() \
			and me.hand[index].has_fusion():
		_open_fusion(index)
		return
	_clear_mode()


func _open_fusion(index: int) -> void:
	if not _my_turn():
		_append_log("现在不是我方回合")
		return
	if GameManager.busy:
		_append_log("对手正在行动，请稍候再融合")
		return
	if not GameManager.can_fuse(GameManager.PLAYER_ID, index):
		var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
		var card: CardData = me.hand[index] if me != null and index < me.hand.size() else null
		if card != null and card.has_fusion():
			var req := card.fusion_require()
			if not EffectConditions.is_empty(req) and not GameManager.fusion_require_met(
					GameManager.PLAYER_ID, card):
				_append_log("融合条件不满足：%s" % EffectConditions.text(req))
			elif GameManager.fusion_materials(GameManager.PLAYER_ID, index).size() < card.fusion_count():
				_append_log("手牌里没有足够的融合材料（需要 %d 张）" % card.fusion_count())
			else:
				_append_log("现在不能融合")
		return
	if _fusion_dialog == null:
		_fusion_dialog = FusionDialog.new()
		add_child(_fusion_dialog)
		_fusion_dialog.fused.connect(func(_ok: bool) -> void: _request_refresh())
	_fusion_dialog.open_for(GameManager, GameManager.PLAYER_ID, index)


func _on_hand_card_clicked(index: int) -> void:
	# 点一下手牌 → 整条手牌**摊开展示**（原版 Focus 态），这样所有牌的费用 / 描述都能看清；
	# 出牌成功或右键取消时会自动收回（见 `_clear_mode()`）。
	_hand_focus = true
	if not _my_turn():
		_append_log("现在不是我方回合")
		_pin_hand_detail(index)
		_request_refresh()
		return
	_clear_mode()
	_hand_focus = true          # `_clear_mode()` 会把它清掉，这里重新立起来
	_request_refresh()
	if not GameManager.can_play(GameManager.PLAYER_ID, index):
		_append_log(_cannot_play_reason(index))
		_pin_hand_detail(index)
		return
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	var card: CardData = me.hand[index]
	if card.needs_target():
		# 随从 / 护符 / 城邦的战吼没有合法目标时也能直接上场（战吼空放）；
		# 法术没有合法目标则打不出——上面 can_play 已经拦住了。
		if card.is_board_card() and not GameManager.has_valid_targets(GameManager.PLAYER_ID, card):
			_append_log("场上没有「%s」的合法目标，战吼空放" % card.card_name)
			if GameManager.request_play(index):
				_play_sfx("play_card")
				_clear_mode()
			return
		_enter_card_target(index)
		_pin_hand_detail(index)
		return
	if GameManager.request_play(index):
		_play_sfx("play_card")
		_clear_mode()


## 「为什么现在打不出这张牌」：给一个具体原因，而不是笼统的“无法打出”。
func _cannot_play_reason(index: int) -> String:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null or index < 0 or index >= me.hand.size():
		return "无法打出这张牌"
	var card: CardData = me.hand[index]
	if not GameManager.game_active():
		return "对局已经结束"
	if GameManager.busy:
		return "对手正在行动，请稍候再出牌"
	if card.cost > me.mana:
		return "法力不足：「%s」需要 %d 点，当前只有 %d 点" % [card.card_name, card.cost, me.mana]
	if card.is_city() and GameManager.city_slot_unit(GameManager.PLAYER_ID) != null:
		return "城邦格已被占用（先把格子里的城邦解掉，或等它被摧毁）"
	if card.is_board_card() and GameManager.board_size_used(GameManager.PLAYER_ID) >= GameManager.BOARD_LIMIT:
		return "战场已满（上限 %d），无法上场「%s」" % [GameManager.BOARD_LIMIT, card.card_name]
	# 法术必须有合法目标才能释放（随从 / 护符 / 城邦的战吼可以空放）
	if card.needs_target() and not GameManager.has_valid_targets(GameManager.PLAYER_ID, card):
		return "「%s」当前没有合法目标（%s），无法释放" % [card.card_name, card.target_name()]
	return "「%s」当前无法打出" % card.card_name


func _on_unit_clicked(unit_id: int) -> void:
	if not _my_turn():
		return
	if mode == Mode.CARD_TARGET:
		var owner_id: int = GameManager.unit_owner(unit_id)
		if _is_target(unit_id, owner_id):
			if GameManager.request_play(pending_index, unit_id, owner_id):
				_clear_mode()
		else:
			_append_log("这不是「%s」的合法目标" % _pending_card_name())
		return
	if mode == Mode.ATTACK_TARGET:
		var owner2: int = GameManager.unit_owner(unit_id)
		if _is_target(unit_id, owner2):
			if GameManager.request_attack(pending_unit, unit_id, owner2):
				_clear_mode()
		else:
			_append_log("无法攻击该目标（嘲讽限制？）")
		return
	if mode == Mode.SKILL_TARGET:
		var owner3: int = GameManager.unit_owner(unit_id)
		if _is_target(unit_id, owner3):
			# 成功发动后由 `_fire_skill` 自己关掉选目标状态（并把回执留在操作栏）
			_fire_skill(pending_unit, unit_id, owner3)
		else:
			_append_log("这不是技能「%s」的合法目标" % _pending_skill_name())
		return

	# 选择我方随从：**先技能、后攻击** —— 有主动技能且本回合可用就先走技能流程；
	# 没有技能 / 本回合已发动 / 能量点不足 → `_try_start_skill` 返回 false，照旧进入攻击选目标。
	if GameManager.unit_owner(unit_id) != GameManager.PLAYER_ID:
		hint_label.text = "请点击我方随从来发起攻击。"
		return
	if _try_start_skill(unit_id):
		_pin_unit_detail(unit_id)
		return
	if GameManager.get_valid_attack_targets(GameManager.PLAYER_ID, unit_id).is_empty():
		_append_log("该随从本回合无法攻击（刚上场需要一回合准备，或攻击次数已用尽）")
		_pin_unit_detail(unit_id)
		return
	_enter_attack_target(unit_id)
	_pin_unit_detail(unit_id)


func _on_hero_clicked(pid: int) -> void:
	if not _my_turn():
		return
	if mode == Mode.CARD_TARGET:
		if _is_target(-1, pid):
			if GameManager.request_play(pending_index, -1, pid):
				_clear_mode()
		else:
			_append_log("这不是「%s」的合法目标" % _pending_card_name())
		return
	if mode == Mode.ATTACK_TARGET:
		if _is_target(-1, pid):
			if GameManager.request_attack(pending_unit, -1, pid):
				_clear_mode()
		else:
			_append_log("该随从无法攻击此英雄（嘲讽限制 / 刚上场不可打脸）")
		return
	if mode == Mode.SKILL_TARGET:
		if _is_target(-1, pid):
			# 同上：成功发动后由 `_fire_skill` 关掉选目标状态
			_fire_skill(pending_unit, -1, pid)
		else:
			_append_log("技能「%s」无法指定该主战者" % _pending_skill_name())
		return


func _on_end_turn_pressed() -> void:
	_clear_mode()
	if GameSettings.confirm_end_turn and _has_unused_action():
		_confirm_end_turn()
		return
	GameManager.request_end_turn()


## 是否还有可用法力能打的牌、可攻击的随从、或可发动的主动技能
func _has_unused_action() -> bool:
	var me: PlayerState = GameManager.get_player(GameManager.PLAYER_ID)
	if me == null:
		return false
	for i in me.hand.size():
		if GameManager.can_play(GameManager.PLAYER_ID, i):
			return true
	for u in me.board:
		if u.can_attack(GameManager.turn_count, true):
			return true
		# 随从 / 护符 / 城邦的主动技能也算「还没用完的行动」（技能接口未落地时为 false）
		if u != null and _unit_has_skill(u) and _can_use_skill(u.unit_id):
			return true
	return false


func _confirm_end_turn() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "结束回合"
	dialog.dialog_text = "还有可用法力或可攻击的随从，确定结束回合吗？"
	dialog.ok_button_text = "结束回合"
	dialog.cancel_button_text = "继续操作"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		GameManager.request_end_turn()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


func _on_restart_pressed() -> void:
	_clear_mode()
	GameManager.new_game()
	_append_log("=== 已重开一局 ===")


## 认输（炉石 / 影之诗的对局内都有这个入口）
func _on_concede_pressed() -> void:
	if not GameManager.game_active():
		_append_log("对局已经结束了")
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "认输"
	dialog.dialog_text = "确定认输吗？本局会直接判负。"
	dialog.ok_button_text = "认输"
	dialog.cancel_button_text = "继续对战"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		GameManager.request_concede()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


func _on_game_over(winner_id: int, draw: bool) -> void:
	var sfx := "win" if winner_id == GameManager.PLAYER_ID else "lose"
	_play_sfx(sfx)
	_clear_mode()
	_request_refresh()
	var msg: String = "平局！" if draw else ("胜利！" if winner_id == GameManager.PLAYER_ID else "失败…")
	var dialog := ConfirmationDialog.new()
	dialog.title = "对战结束"
	dialog.dialog_text = msg + " 是否再来一局？"
	dialog.ok_button_text = "再来一局"
	dialog.cancel_button_text = "留在本局"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		GameManager.new_game()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


# ------------------------------ 管理员 ------------------------------

func _on_admin_pressed() -> void:
	if not AdminAuth.is_logged_in:
		_open_login_dialog()
	else:
		_open_admin_panel()


func _open_login_dialog() -> void:
	if _login_dialog != null and is_instance_valid(_login_dialog):
		_login_dialog.grab_focus()
		return
	_login_dialog = LoginDialog.new()
	add_child(_login_dialog)
	_login_dialog.login_succeeded.connect(_on_login_succeeded)
	_login_dialog.popup_centered()


func _on_login_succeeded() -> void:
	_login_dialog = null
	_open_admin_panel()


func _open_admin_panel() -> void:
	if _admin_panel != null and is_instance_valid(_admin_panel):
		_admin_panel.grab_focus()
		return
	_admin_panel = AdminPanel.new()
	add_child(_admin_panel)
	_admin_panel.closed.connect(_on_admin_panel_closed)
	_admin_panel.popup_centered()


func _on_admin_panel_closed() -> void:
	_admin_panel = null


func _on_login_state_changed(logged_in: bool) -> void:
	_update_admin_ui()
	if not logged_in and _admin_panel != null and is_instance_valid(_admin_panel):
		_admin_panel.queue_free()
		_admin_panel = null


func _update_admin_ui() -> void:
	if AdminAuth.is_logged_in:
		admin_button.text = "卡牌管理"
		admin_status.text = "管理员：%s（已登录）" % AdminAuth.user_name
	else:
		admin_button.text = "管理员登录"
		admin_status.text = "未登录"


## 出牌特效：打向**目标**（目标随从中心 / 目标英雄框中心）；没有目标时落在出牌者主战者身上
func _on_card_resolved_vfx(pid: int, card: CardData, target_unit_id: int, target_player_id: int) -> void:
	if card == null or str(card.vfx) == "":
		return
	var pos := Vector2.ZERO
	if target_unit_id >= 0:
		pos = _unit_center(target_unit_id)
	if pos == Vector2.ZERO and target_player_id >= 0:
		var tf = enemy_hero_frame if target_player_id == GameManager.ENEMY_ID else player_hero_frame
		if tf != null and is_instance_valid(tf):
			pos = tf.get_global_rect().get_center()
	if pos == Vector2.ZERO:
		var own = enemy_hero_frame if pid == GameManager.ENEMY_ID else player_hero_frame
		if own != null and is_instance_valid(own):
			pos = own.get_global_rect().get_center()
	if pos == Vector2.ZERO:
		return
	_spawn_vfx(str(card.vfx), pos)

## 供测试：最近一次出牌特效落点
func last_vfx_position() -> Vector2:
	return _last_vfx_pos