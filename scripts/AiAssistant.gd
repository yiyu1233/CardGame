extends Node
## AI 助手总管（自动加载为 AiAssistant）：全局浮窗 + 对话调度 + 工具循环。
##
## 职责：
##   * 建一个高层 `CanvasLayer`，挂 `AiSidebar`（右滑抽屉 + 右上角漂浮按钮），
##     不随场景切换销毁——标题 / 主界面 / 对局里都能呼出，对话历史跨界面保留；
##   * 收 `AiSidebar` 的信号，拼系统提示词（规则速览 + 工具目录 + AI 配置里的自定义提示词），
##     调 `AiClient` 发请求（支持流式）；
##   * **工具循环**（agent 味）：AI 回复里出现 `[[tool: {...}]]` 就由 `AiTools` 执行，
##     把结果作为 `tool` 消息塞回上下文再来一轮，最多 `MAX_TOOL_ROUNDS` 轮；
##   * 键盘：F2 开关浮窗；输入框聚焦时截断其它按键（对局热键不吃掉打字）。
##
## 线程 / 时序：全部在主线程；HTTPRequest 回调回来时先校验「这一轮还是不是当前轮」
## （`_request_seq`），避免旧响应回来覆盖新会话。

const SIDEBAR_SCRIPT := preload("res://scripts/AiSidebar.gd")
const CLIENT_SCRIPT := preload("res://scripts/AiClient.gd")
const TOOLS_SCRIPT := preload("res://scripts/AiTools.gd")
const CONFIG_SCRIPT := preload("res://scripts/AiConfig.gd")
const AI_SETTINGS_SCRIPT := preload("res://scripts/AiSettingsDialog.gd")

## 工具循环上限：一轮 = 一次请求 + 执行若干工具；防死循环
const MAX_TOOL_ROUNDS := 4

## UI 层：压在游戏所有元素之上（拖拽层 128 之下，拖拽幽灵卡仍盖得住浮窗）
const UI_LAYER := 64

var sidebar = null             ## AiSidebar
var _layer: CanvasLayer = null
var _client = null             ## AiClient（一次只跑一个请求）
## 上下文消息（role / content；tool 消息带 name）。**只装对话**，系统提示词每轮现拼。
var _messages: Array[Dictionary] = []
## 请求序号：每次发新请求 +1；响应对不上序号就丢弃
var _request_seq := 0
var _busy := false


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = UI_LAYER
	_layer.name = "AiLayer"
	add_child(_layer)
	# 先 add_child 再建：AiSidebar 的 _ready 只在入树后才会跑（控件构建 / 按钮定位都在那里）
	sidebar = SIDEBAR_SCRIPT.new()
	sidebar.name = "AiSidebar"
	_layer.add_child(sidebar)
	sidebar.send_requested.connect(_on_send)
	sidebar.stop_requested.connect(func() -> void: _on_stop())
	sidebar.new_chat_requested.connect(new_chat)
	sidebar.settings_requested.connect(_open_settings)
	# 界面文字随字体设置刷新（模型名 / 提示语）
	if not GameSettings.changed.is_connected(_on_settings_changed):
		GameSettings.changed.connect(_on_settings_changed)


func _on_settings_changed() -> void:
	if sidebar != null:
		sidebar._refresh_model_label()


# ------------------------------ 对外入口 ------------------------------
## 开关浮窗（主界面 / 对局顶栏按钮与 F2 都走这里）
func toggle_sidebar() -> void:
	if sidebar == null:
		return
	if sidebar.is_open():
		sidebar.close()
	else:
		sidebar.open()


func open_sidebar() -> void:
	if sidebar != null:
		sidebar.open()


func close_sidebar() -> void:
	if sidebar != null:
		sidebar.close()


func is_open() -> bool:
	return sidebar != null and sidebar.is_open()


## 输入框是否聚焦（Main 的热键守卫用）
func input_focused() -> bool:
	return sidebar != null and sidebar.input_focused()


## 清空对话（新的一局 / 玩家点「新对话」）
func new_chat() -> void:
	_on_stop("已开始新对话")
	if sidebar != null:
		sidebar.clear()
	_messages.clear()


# ------------------------------ 键盘 ------------------------------
func _input(event: InputEvent) -> void:
	if sidebar == null:
		return
	# 浮窗开的着：先让浮窗处理（Esc 关窗 / 打字截断），再轮到 F2 开关
	if sidebar.handle_key(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_F2:
			toggle_sidebar()
			get_viewport().set_input_as_handled()


# ------------------------------ 发送 / 工具循环 ------------------------------
func _on_send(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	# 配置不全时先给一条明确提示，但仍然把用户的话显示出来（不丢字）
	var cfg := _config()
	if cfg == null or not cfg.is_ready():
		sidebar.append_message("user", t)
		sidebar.append_message("error", "AI 接口还没有配置好：打开「设置」填上 Base URL、API Key 与模型名（默认是 DeepSeek，任何 OpenAI 兼容接口都行）。")
		sidebar.set_status("未配置接口", true)
		return
	_on_stop()   # 上一次没说完就重发：先断开旧请求（不显示「已中断」）
	sidebar.append_message("user", t)
	_messages.append({"role": "user", "content": t})
	_trim_history()
	_start_round()


## 发起一轮请求（工具结果回灌后再来一轮也走这里）
func _start_round() -> void:
	var cfg := _config()
	if cfg == null:
		return
	_request_seq += 1
	var my_seq := _request_seq
	_busy = true
	sidebar.set_streaming(true)
	sidebar.set_thinking("正在思考…")
	sidebar.set_status("", false)

	_client = CLIENT_SCRIPT.new(cfg.endpoint(), cfg.api_key, cfg.model)
	_client.delta.connect(_on_round_delta.bind(my_seq))
	_client.finished.connect(_on_round_finished.bind(my_seq))
	_client.failed.connect(_on_round_failed.bind(my_seq))
	var ok: bool = _client.request(_payload(cfg), {
		"temperature": cfg.temperature,
		"max_tokens": cfg.max_tokens,
		"stream": cfg.stream,
	})
	if not ok:
		# 构件不齐 / 请求没发出去：failed 信号里已经说明原因
		_busy = false
		sidebar.set_streaming(false)


func _on_round_delta(seq: int, piece: String) -> void:
	if seq != _request_seq:
		return
	sidebar.set_thinking("")
	sidebar.append_delta(piece)


func _on_round_finished(seq: int, full: String) -> void:
	if seq != _request_seq:
		return
	_client = null
	var calls: Array = TOOLS_SCRIPT.parse_tool_calls(full)
	var visible: String = TOOLS_SCRIPT.visible_text(full)
	if calls.is_empty():
		sidebar.set_thinking("")
		sidebar.finalize_stream(full)
		_messages.append({"role": "assistant", "content": full})
		_trim_history()
		_finish_round()
		return
	# 有工具调用：正文（若有）照显示，工具结果回灌后再来一轮
	if visible != "":
		sidebar.finalize_stream(visible)
	else:
		sidebar.finalize_stream("")
		sidebar.set_thinking("")
	# 上下文里存原文（带工具行）——OpenAI 规范下 assistant 消息原样回灌最稳
	_messages.append({"role": "assistant", "content": full})
	for call in calls:
		var name: String = str(call.get("name", ""))
		var args: Dictionary = call.get("args", {})
		sidebar.set_status("正在调用工具 %s…" % name)
		var result: String = TOOLS_SCRIPT.run_tool(name, args)
		_messages.append({"role": "tool", "name": name, "content": result})
	_trim_history()
	if _tool_round_count() > MAX_TOOL_ROUNDS:
		sidebar.append_message("error", "工具调用轮数超过上限（%d 轮），先停在这里。可以追问，或换个问法。" % MAX_TOOL_ROUNDS)
		_finish_round()
		return
	_start_round()


func _on_round_failed(seq: int, msg: String) -> void:
	if seq != _request_seq:
		return
	_client = null
	sidebar.set_thinking("")
	sidebar.append_message("error", msg)
	_finish_round()


func _finish_round() -> void:
	_busy = false
	sidebar.set_streaming(false)
	sidebar.set_status("", false)


## 玩家点「停止」/ 发新消息时中断当前请求。reason 非空时在界面状态行里说明。
func _on_stop(reason: String = "") -> void:
	if not _busy and _client == null:
		return
	_request_seq += 1   # 让在途响应直接作废
	if _client != null:
		_client.cancel()
		_client = null
	_busy = false
	if sidebar != null:
		sidebar.set_streaming(false)
		if reason != "":
			sidebar.set_status(reason)


## 连续出现工具轮时最多几轮（数上下文尾部连续 assistant，含 tool 的段落）
func _tool_round_count() -> int:
	var rounds := 0
	var i := _messages.size() - 1
	while i >= 0:
		var role := str(_messages[i].get("role", ""))
		if role == "tool":
			i -= 1
			continue
		if role == "assistant" and i + 1 < _messages.size() and str(_messages[i + 1].get("role", "")) == "tool":
			rounds += 1
			i -= 1
			continue
		break
	return rounds


# ------------------------------ 上下文 / 提示词 ------------------------------
## 请求体：system + 裁剪过的历史 + tool 消息
func _payload(cfg) -> Array:
	var out: Array[Dictionary] = [{"role": "system", "content": _system_prompt(cfg)}]
	# 历史裁剪：先按条数取尾部，再保证不把 tool 消息留在开头
	var limit: int = cfg.history_limit if cfg != null else 24
	var start := maxi(0, _messages.size() - limit)
	while start < _messages.size() and str(_messages[start].get("role", "")) == "tool":
		start += 1
	for i in range(start, _messages.size()):
		out.append(_messages[i])
	return out


func _system_prompt(cfg) -> String:
	var parts := PackedStringArray()
	var custom: String = ""
	if cfg != null:
		custom = str(cfg.system_prompt).strip_edges()
	if custom != "":
		parts.append(custom)
	else:
		parts.append(CONFIG_SCRIPT.DEFAULT_SYSTEM_PROMPT)
	parts.append("")
	parts.append("【本游戏】" + TOOLS_SCRIPT.rules_text())
	parts.append("")
	parts.append(TOOLS_SCRIPT.prompt_block())
	return "\n".join(parts)


## 历史裁剪：条目数上限（按配置的 2 倍留余量）+ 总量上限（字符）
func _trim_history() -> void:
	var cfg := _config()
	var limit: int = (cfg.history_limit if cfg != null else 24) * 2
	while _messages.size() > limit:
		_messages.remove_at(0)
	var total := 0
	for m in _messages:
		total += str(m.get("content", "")).length()
	while total > 40000 and _messages.size() > 2:
		total -= str(_messages[0].get("content", "")).length()
		_messages.remove_at(0)
	# 开头若是 tool 消息，它对应的 assistant 已被裁掉，直接丢弃（否则服务端可能报错）
	while _messages.size() > 0 and str(_messages[0].get("role", "")) == "tool":
		_messages.remove_at(0)


# ------------------------------ 设置窗 ------------------------------
## 打开 AI 助手设置窗（浮窗的「设置」按钮与游戏设置里的入口都走这里）
func open_settings() -> void:
	var dlg := get_node_or_null("AiSettings")
	if dlg == null:
		dlg = AI_SETTINGS_SCRIPT.new()
		dlg.name = "AiSettings"
		add_child(dlg)
	if dlg.has_method("open"):
		dlg.open()


func _open_settings() -> void:
	open_settings()


# ------------------------------ 辅助 ------------------------------
func _config() -> Node:
	return get_node_or_null("/root/AiConfig")
