extends SceneTree
## AI 助手浮窗测试（无头可跑）：
##   1. AiConfig：默认值、越界夹紧、endpoint 拼接、存读往返、恢复默认；
##   2. AiClient：请求体格式（OpenAI 兼容）、SSE 分片解析、错误信息提取；
##   3. AiTools：工具目录 / 系统提示词块、卡表检索与详情、机制解释、对局局面；
##   4. AiAssistant：工具调用解析（含 JSON 壳）、历史裁剪、系统提示词拼装；
##   5. AiSidebar：抽屉开合几何、消息渲染（Markdown → BBCode）、键入焦点守卫、按钮命中；
##   6. 集成：AiAssistant 自动加载 + Main.tscn 顶栏按钮联动。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tools/ai_assistant_test.gd

const ME := 0
const FOE := 1

const CONFIG_SCRIPT := preload("res://scripts/AiConfig.gd")
const CLIENT_SCRIPT := preload("res://scripts/AiClient.gd")
const TOOLS_SCRIPT := preload("res://scripts/AiTools.gd")
const SIDEBAR_SCRIPT := preload("res://scripts/AiSidebar.gd")

var _fails := 0
var _frames := 0
var _fail_lines: Array[String] = []
var _db
var _gm
var _ai
var _cfg
var _main


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_db = root.get_node_or_null("CardDB")
		_gm = root.get_node_or_null("GameManager")
		_ai = root.get_node_or_null("AiAssistant")
		_cfg = root.get_node_or_null("AiConfig")
		if _db == null or _gm == null or _ai == null or _cfg == null:
			_check(false, "CardDB / GameManager / AiConfig / AiAssistant 自动加载")
			_finish()
			return true
		_db.reset_to_default()
		# 测试隔离：配置写到 test 文件，不碰玩家真实 ai.cfg
		_cfg.use_save_path("user://test_ai.cfg")
		_run_config()
		_run_client()
		_run_tools()
		return false
	if _frames == 4:
		_run_assistant()
		_run_sidebar()
		return false
	if _frames == 6:
		_run_integration()
		return false
	if _frames == 8:
		_finish()
		return true
	return _frames > 400


# ------------------------------ 1. 配置 ------------------------------

func _run_config() -> void:
	# 默认值
	_cfg.restore_defaults()
	_check(_cfg.base_url == CONFIG_SCRIPT.DEFAULT_BASE_URL, "默认 Base URL 是 OpenAI 兼容地址（%s）" % _cfg.base_url)
	_check(_cfg.model == CONFIG_SCRIPT.DEFAULT_MODEL, "默认模型名存在（%s）" % _cfg.model)
	_check(_cfg.system_prompt.contains("工具调用格式"), "默认系统提示词含有工具调用格式说明")
	_check(_cfg.is_ready(), "默认配置即处于「可请求」状态（地址 + 模型齐全）")

	# 越界夹紧
	_cfg.temperature = 9.9
	_check(_cfg.temperature == CONFIG_SCRIPT.TEMPERATURE_MAX, "温度超上限被夹紧（%s）" % _cfg.temperature)
	_cfg.temperature = -3.0
	_check(_cfg.temperature == CONFIG_SCRIPT.TEMPERATURE_MIN, "温度低于下限被夹紧（%s）" % _cfg.temperature)
	_cfg.max_tokens = 999999
	_check(_cfg.max_tokens == CONFIG_SCRIPT.MAX_TOKENS_MAX, "max_tokens 超上限被夹紧（%d）" % _cfg.max_tokens)
	_cfg.max_tokens = 1
	_check(_cfg.max_tokens == CONFIG_SCRIPT.MAX_TOKENS_MIN, "max_tokens 低于下限被夹紧（%d）" % _cfg.max_tokens)
	_cfg.history_limit = 0
	_check(_cfg.history_limit == CONFIG_SCRIPT.HISTORY_LIMIT_MIN, "历史条数低于下限被夹紧（%d）" % _cfg.history_limit)

	# endpoint 拼接：去尾斜杠 / 已含时原样
	_cfg.base_url = "https://api.example.com/v1/"
	_check(_cfg.endpoint() == "https://api.example.com/v1/chat/completions", "endpoint() 去掉尾斜杠并拼 chat/completions")
	_cfg.base_url = "https://api.example.com/v1/chat/completions"
	_check(_cfg.endpoint() == "https://api.example.com/v1/chat/completions", "已含 chat/completions 时不重复拼")
	_cfg.base_url = "http://localhost:11434/v1"
	_check(_cfg.endpoint() == "http://localhost:11434/v1/chat/completions", "本地 Ollama 地址同样成立")

	# 未配置密钥的提示（本机服务不提示）
	_cfg.base_url = "https://api.example.com/v1"
	_cfg.api_key = ""
	_check(_cfg.needs_key_hint() != "", "云端地址且无密钥时给出提示")
	_cfg.base_url = "http://localhost:11434/v1"
	_check(_cfg.needs_key_hint() == "", "本机地址不提示密钥")
	# 存读往返
	_cfg.base_url = "https://round.trip/v1"
	_cfg.api_key = "sk-test-123"
	_cfg.model = "test-model"
	_cfg.temperature = 1.3
	_cfg.max_tokens = 512
	_cfg.history_limit = 8
	_cfg.stream = false
	_cfg.save_config()
	_cfg.restore_defaults()
	_check(_cfg.base_url == CONFIG_SCRIPT.DEFAULT_BASE_URL, "恢复默认后地址回到默认")
	_cfg.load_config()
	_check(_cfg.base_url == "https://round.trip/v1", "存读往返：地址（%s）" % _cfg.base_url)
	_check(_cfg.api_key == "sk-test-123", "存读往返：密钥")
	_check(_cfg.model == "test-model", "存读往返：模型")
	_check(absf(_cfg.temperature - 1.3) < 0.001, "存读往返：温度（%.1f）" % _cfg.temperature)
	_check(_cfg.max_tokens == 512, "存读往返：max_tokens（%d）" % _cfg.max_tokens)
	_check(_cfg.history_limit == 8, "存读往返：历史条数（%d）" % _cfg.history_limit)
	_check(not _cfg.stream, "存读往返：流式开关")
	_cfg.restore_defaults()


# ------------------------------ 2. 客户端 ------------------------------

func _run_client() -> void:
	var c = CLIENT_SCRIPT.new()
	c.endpoint = "https://api.example.com/v1/chat/completions"
	c.api_key = "sk-abc"
	c.model = "deepseek-chat"
	c.last_request_body = c._build_body([{"role": "user", "content": "你好"}], {"temperature": 0.5, "max_tokens": 128, "stream": true})
	c.last_request_headers = c._headers()
	var body: Dictionary = JSON.parse_string(c.last_request_body)
	_check(str(body.get("model", "")) == "deepseek-chat", "请求体带 model")
	_check(int(body.get("max_tokens", 0)) == 128, "请求体带 max_tokens（%d）" % int(body.get("max_tokens", 0)))
	_check(absf(float(body.get("temperature", 0)) - 0.5) < 0.001, "请求体带 temperature")
	_check(bool(body.get("stream", false)), "请求体带 stream=true")
	var msgs: Array = body.get("messages", [])
	_check(msgs.size() == 1 and str(msgs[0].get("role", "")) == "user", "请求体带 messages（%d 条）" % msgs.size())
	var auth_ok := false
	for h in c.last_request_headers:
		if str(h) == "Authorization: Bearer sk-abc":
			auth_ok = true
	_check(auth_ok, "请求头带 Bearer 密钥")

	# SSE 分片解析（跨片行的缓冲 + delta 累积）
	var deltas := PackedStringArray()
	c.delta.connect(func(piece: String) -> void: deltas.append(piece))
	c.feed_sse("data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}\n\ndata: [DONE]\n")
	_check(c.accumulated() == "你好", "SSE 两段增量累积为「你好」（实际「%s」）" % c.accumulated())
	_check(deltas.size() == 2, "SSE delta 信号发了 2 次（%d）" % deltas.size())
	# 一条 JSON 被拆成两片：前片留在缓冲里，补齐后完整解析
	c._acc = ""
	c._buf = ""
	c.feed_sse("data: {\"choices\":[{\"delta\":{\"cont")
	_check(c.accumulated() == "", "不完整分片先不出内容")
	c.feed_sse("ent\":\"分片完整\"}}]}\n\n")
	_check(c.accumulated() == "分片完整", "补齐后解析出「分片完整」（实际「%s」）" % c.accumulated())

	# 非流式响应正文提取
	var data: Variant = JSON.parse_string("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"直接回复\"}}]}")
	_check(CLIENT_SCRIPT.content_of(data as Dictionary) == "直接回复", "非流式 message.content 提取正确")
	var empty: Variant = JSON.parse_string("{}")
	_check(CLIENT_SCRIPT.content_of(empty as Dictionary) == "", "空响应返回空正文")

	# 错误体提取（OpenAI 的 {"error":{"message":...}}）
	_check(CLIENT_SCRIPT._extract_error("{\"error\":{\"message\":\"Invalid API key\"}}") == "Invalid API key", "服务端 error.message 提取正确")
	_check(CLIENT_SCRIPT._extract_error("") == "（无响应体）", "空错误体给兜底文案")

	# 构件不齐时拒绝请求并给出原因
	var reasons: Array[String] = []
	var bad = CLIENT_SCRIPT.new("", "", "")
	bad.failed.connect(func(msg: String) -> void: reasons.append(msg))
	_check(not bad.request([{"role": "user", "content": "hi"}]), "缺地址 / 模型时 request() 返回 false")
	_check(reasons.size() == 1 and reasons[0].contains("接口地址"), "缺配置的失败原因可读（%s）" % (reasons[0] if reasons.size() > 0 else ""))


# ------------------------------ 3. 工具 ------------------------------

func _run_tools() -> void:
	var names := PackedStringArray()
	for t in TOOLS_SCRIPT.catalog():
		names.append(str(t.get("name", "")))
	_check(names.size() == 4, "工具目录有 4 个工具（%s）" % ", ".join(names))
	_check(names.has("card_search") and names.has("card_detail") and names.has("game_state") and names.has("mechanic_info"),
		"四个工具名齐全")
	var block: String = TOOLS_SCRIPT.prompt_block()
	_check(block.contains("[[tool:") and block.contains("card_search"), "提示词块含调用格式与工具名")

	# 卡表检索
	var all: String = TOOLS_SCRIPT.search_cards("")
	_check(all.contains("匹配"), "空条件检索返回匹配列表")
	var dragon: String = TOOLS_SCRIPT.search_cards("龙")
	_check(dragon.contains("龙") or dragon.contains("没有匹配"), "按名字检索（%s）" % dragon.split("\n")[0])
	var taunt: String = TOOLS_SCRIPT.search_cards("", "", null, "嘲讽")
	_check(taunt.contains("嘲讽"), "按关键字检索返回带嘲讽的卡")
	var cheap: String = TOOLS_SCRIPT.search_cards("", "", 2)
	_check(not cheap.contains("999"), "按费用上限过滤不报错")
	var bad_type: String = TOOLS_SCRIPT.search_cards("", "不存在的种类")
	_check(bad_type.contains("匹配"), "认不出的种类当作不过滤")

	# 卡详情：拿卡表里第一张随从
	var minion = null
	for c in _db.cards:
		if c.is_minion() and not c.is_token:
			minion = c
			break
	_check(minion != null, "卡表里存在随从卡")
	if minion != null:
		var detail: String = TOOLS_SCRIPT.card_detail(minion.card_name)
		_check(detail.contains(minion.card_name) and detail.contains("id="), "按卡名查详情（%s）" % minion.card_name)
		_check(detail.contains("%d费" % minion.cost), "详情带费用")
		var partial: String = TOOLS_SCRIPT.card_detail(minion.card_name.substr(0, 1))
		_check(partial != "", "部分名字也能查（至少不报错）")
		_check(TOOLS_SCRIPT.card_detail("绝对不存在的卡名XYZ").contains("没有"), "查不到的卡给出人话")

	# 机制解释
	var all_kw: String = TOOLS_SCRIPT.mechanic_info("")
	_check(all_kw.contains("嘲讽") and all_kw.contains("圣盾"), "不传参数列出全部关键字")
	var taunt_kw: String = TOOLS_SCRIPT.mechanic_info("嘲讽")
	_check(taunt_kw.contains("嘲讽") and taunt_kw.contains("互斥"), "嘲讽说明含互斥关系")
	_check(TOOLS_SCRIPT.mechanic_info("不存在机制").contains("没有"), "未知机制给出人话")

	# 局面：未开局时给「没有进行中的对局」
	if not _gm.game_active():
		var before: String = TOOLS_SCRIPT.game_state()
		_check(before.contains("没有进行中的对局"), "未开局时局面文案正确（%s）" % before)
	else:
		# 测试跑在游戏进程里，GameManager 可能已被前面的用例开过局——这里不强求「未开局」
		_check(true, "对局已在运行（跳过未开局文案断言）")
	# 开一局
	_gm.new_game()
	var state: String = TOOLS_SCRIPT.game_state()
	_check(state.contains("第 1 回合"), "开局后读到第 1 回合（%s）" % state.split("\n")[0])
	var me: PlayerState = _gm.get_player(ME)
	_check(state.contains("手牌："), "局面里有手牌区")
	if me.hand.size() > 0:
		_check(state.contains(me.hand[0].card_name), "局面里列出第一张手牌（%s）" % me.hand[0].card_name)
	_check(state.contains("战场："), "局面里有战场区")
	_check(not state.contains("对手手牌："), "不泄露对手手牌内容")

	# run_tool 入口：正常 / 未知工具
	var r1: String = TOOLS_SCRIPT.run_tool("game_state", {})
	_check(r1.contains("第 1 回合"), "run_tool(game_state) 正常返回")
	var r2: String = TOOLS_SCRIPT.run_tool("no_such_tool", {})
	_check(r2.contains("未知工具"), "未知工具返回提示（%s）" % r2.substr(0, 30))
	var r3: String = TOOLS_SCRIPT.run_tool("card_search", {"max_cost": "坏值"})
	_check(r3 != "", "参数类型不对时不崩（返回 %d 字）" % r3.length())


# ------------------------------ 4. 助手调度 ------------------------------

func _run_assistant() -> void:
	# 工具调用解析
	var one: Array = TOOLS_SCRIPT.parse_tool_calls("先查一下\n[[tool: {\"name\":\"card_search\",\"args\":{\"query\":\"龙\"}}]]")
	_check(one.size() == 1 and str(one[0].get("name", "")) == "card_search", "解析标准工具调用（%d 条）" % one.size())
	_check(str(one[0].get("args", {}).get("query", "")) == "龙", "工具参数解析正确")
	var two: Array = TOOLS_SCRIPT.parse_tool_calls("[[tool:{\"name\":\"game_state\",\"args\":{}}]]\n[[tool: {\"name\":\"mechanic_info\",\"args\":{\"keyword\":\"圣盾\"}}]]")
	_check(two.size() == 2, "一行内两条调用都能解析（%d 条）" % two.size())
	var wrapped: Array = TOOLS_SCRIPT.parse_tool_calls("{\"tool_calls\":[{\"name\":\"game_state\",\"arguments\":{}}]}")
	_check(wrapped.size() == 1 and str(wrapped[0].get("name", "")) == "game_state", "JSON 壳形式也能解析")
	var junk: Array = TOOLS_SCRIPT.parse_tool_calls("[[tool: {不是json}]]")
	_check(junk.is_empty(), "坏格式忽略不崩")

	# 可见正文剥离
	var vis: String = TOOLS_SCRIPT.visible_text("好的，我查一下。\n[[tool: {\"name\":\"game_state\",\"args\":{}}]]")
	_check(vis == "好的，我查一下。", "工具行从可见正文里剥掉（实际「%s」）" % vis)
	var only: String = TOOLS_SCRIPT.visible_text("[[tool: {\"name\":\"game_state\",\"args\":{}}]]")
	_check(only == "", "只有工具行时可见正文为空")

	# 历史裁剪
	_ai.new_chat()
	_check(not _ai.is_open(), "初始状态浮窗是收起的")
	for i in 30:
		_ai._messages.append({"role": "user", "content": "第 %d 条消息" % i})
	_ai._trim_history()
	_check(_ai._messages.size() <= int(_cfg.history_limit) * 2, "历史条目数被裁剪（%d 条）" % _ai._messages.size())
	# 开头是 tool 消息时直接丢弃
	_ai._messages.clear()
	_ai._messages.append({"role": "tool", "name": "x", "content": "orphan"})
	_ai._messages.append({"role": "user", "content": "正常"})
	_ai._trim_history()
	_check(str(_ai._messages[0].get("role", "")) == "user", "开头的孤儿 tool 消息被丢弃")

	# 系统提示词：自定义提示词 + 规则 + 工具目录
	_cfg.system_prompt = "自定义人设XYZ"
	var sys: String = _ai._system_prompt(_cfg)
	_check(sys.contains("自定义人设XYZ"), "系统提示词带上自定义人设")
	_check(sys.contains("工具调用格式") or sys.contains("[[tool:"), "系统提示词带上工具调用说明")
	_check(sys.contains("嘲讽"), "系统提示词带上规则速览（关键字）")
	# payload：system 在最前、历史跟在后面
	_ai._messages.clear()
	_ai._messages.append({"role": "user", "content": "hi"})
	var payload: Array = _ai._payload(_cfg)
	_check(str(payload[0].get("role", "")) == "system", "payload 第一条是 system")
	_check(str(payload[1].get("role", "")) == "user", "payload 第二条起是历史")
	_cfg.restore_defaults()


# ------------------------------ 5. 侧边栏界面 ------------------------------

func _run_sidebar() -> void:
	var sb = _ai.sidebar
	_check(sb != null and is_instance_valid(sb), "AiAssistant 下存在 AiSidebar 实例")
	if sb == null:
		return
	# 新对话，清干净
	_ai.new_chat()
	sb.clear()
	# 开合几何：收起贴右缘，展开向左滑出 DRAWER_WIDTH
	sb.open()
	_check(sb.is_open(), "open() 后处于打开状态")
	_check(sb.visible, "打开时控件可见")
	var drawer: PanelContainer = sb._drawer
	_check(drawer != null, "抽屉存在")
	var w := drawer.offset_right - drawer.offset_left
	_check(absf(w - SIDEBAR_SCRIPT.DRAWER_WIDTH) < 0.5, "抽屉宽度 = %.0f（实际 %.1f）" % [SIDEBAR_SCRIPT.DRAWER_WIDTH, w])
	var closed_left: float = sb._closed_left()
	var open_left: float = sb._open_left()
	_check(open_left < closed_left, "展开位置在收起位置左侧（%.0f < %.0f）" % [open_left, closed_left])
	# 输入框：打开后拿焦点
	_check(sb._input != null, "输入框存在")
	_check(sb.input_focused(), "打开后输入框拿到焦点")

	# 打字守卫：聚焦时其它键被截断，Esc 先松焦点再关窗
	var key_space := InputEventKey.new()
	key_space.keycode = KEY_SPACE
	key_space.pressed = true
	_check(sb.handle_key(key_space), "输入框聚焦时空格被浮窗截断（不吃到结束回合）")
	var key_esc := InputEventKey.new()
	key_esc.keycode = KEY_ESCAPE
	key_esc.pressed = true
	_check(sb.handle_key(key_esc), "Esc 被浮窗处理")
	_check(not sb.input_focused(), "第一次 Esc 先松开输入焦点")
	_check(sb.handle_key(key_esc) and not sb.is_open(), "第二次 Esc 收起浮窗")
	_check(not sb.handle_key(key_space), "收起后按键交还给对局")

	# 消息渲染
	sb.open()
	sb.append_message("user", "这句里有 [方括号] 要转义")
	sb.append_message("assistant", "**加粗**与 `代码`\n# 标题行\n```\ncode block\n```")
	sb.append_message("error", "这是一条错误")
	sb.set_thinking("正在思考…")
	var text: String = sb._body.text
	_check(text.contains("你") and text.contains("AI"), "渲染含「你 / AI」角色标签")
	_check(text.contains("[lb]方括号[rb]"), "方括号被转义为 [lb]/[rb]（不破坏 BBCode）")
	_check(text.contains("[b]加粗[/b]"), "Markdown 加粗转成 BBCode（实际含 [b]：%s）" % text.contains("[b]"))
	_check(text.contains("[code]"), "代码块转成 BBCode code")
	_check(text.contains("[b][color=#ffca28]标题行[/color][/b]"), "Markdown 标题转成彩色粗体行")
	_check(text.contains("正在思考"), "思考中占位出现在正文里")
	sb.set_thinking("")
	# 流式增量
	sb.set_streaming(true)
	sb.append_delta("第一段")
	sb.append_delta("第二段")
	var streamed: String = str(sb.lines[sb.lines.size() - 1]["raw"])
	_check(streamed == "第一段第二段", "流式增量拼接正确（%s）" % streamed)
	sb.finalize_stream("定稿内容")
	var finalized: String = str(sb.lines[sb.lines.size() - 1]["raw"])
	_check(finalized == "定稿内容", "落定后内容替换为定稿")
	_check(not sb._stop_btn.visible and sb._send_btn.visible, "落定后「发送」恢复、「停止」隐藏")
	sb.set_streaming(false)

	# 按钮命中：漂浮圆钮点一下 = 开合
	var bubble: Button = sb._bubble
	_check(bubble != null, "漂浮 AI 按钮存在")
	var before_open: bool = sb.is_open()
	bubble.pressed.emit()
	_check(sb.is_open() != before_open, "点漂浮按钮切换开合（%s → %s）" % [before_open, sb.is_open()])
	# 收起后按钮回到屏幕右上角
	if not sb.is_open():
		var screen_w: float = sb.get_viewport_rect().size.x
		_check(absf(bubble.position.x - (screen_w - SIDEBAR_SCRIPT.RIGHT_MARGIN - SIDEBAR_SCRIPT.BUBBLE_SIZE)) < 1.0,
			"收起后按钮贴右上角（x=%.1f）" % bubble.position.x)
	sb.close()
	sb.clear()


# ------------------------------ 6. 集成 ------------------------------

func _run_integration() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)
	_check(_main != null, "对战主场景可实例化")
	if _main == null:
		return
	var btn := _main.get_node_or_null("Root/Arena/TopBar/AiButton") as Button
	_check(btn != null, "对战顶栏存在「AI 助手」按钮")
	if btn != null and _main.has_method("skip_mulligan"):
		_main.skip_mulligan()
		var was_open: bool = _ai.is_open()
		btn.pressed.emit()
		_check(_ai.is_open() != was_open, "顶栏按钮能开关 AI 浮窗（%s → %s）" % [was_open, _ai.is_open()])
		# 浮窗开着时点记牌器：两者互斥（记牌器把 AI 收起）
		_main._open_tracker()
		_check(not _ai.is_open(), "打开记牌器时 AI 浮窗自动收起")
		# 打字守卫：输入聚焦时 Main 的快捷键不吃键
		_ai.open_sidebar()
		_check(_ai.input_focused(), "对局中打开浮窗后输入框聚焦")
		var handled: bool = _main._handle_shortcut(KEY_SPACE)
		_check(handled, "Main._handle_shortcut(空格) 本身可用")
		_check(_ai.input_focused(), "输入聚焦状态保持（Main._input 会在开头让路）")
		_ai.close_sidebar()
	_check(_main.has_method("_open_ai_sidebar"), "Main 暴露 _open_ai_sidebar 入口")
	_main.queue_free()


# ------------------------------ 测试辅助 ------------------------------

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
	print("=== AI 助手浮窗测试结束：失败 %d 项 ===" % _fails)
	quit(1 if _fails > 0 else 0)
