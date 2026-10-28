class_name AiClient
extends RefCounted
## OpenAI 兼容接口的聊天客户端（`POST {base}/chat/completions`）。
##
## 用法：
##   var c := AiClient.new(AiConfig.endpoint(), AiConfig.api_key, AiConfig.model)
##   c.delta.connect(_on_delta)      # 流式增量（stream = true 时才有）
##   c.finished.connect(_on_done)    # 整段回复
##   c.failed.connect(_on_err)       # 出错（HTTP / 解析 / 网络）
##   c.request(messages, {"temperature": 0.7, "max_tokens": 2048})
##   # 想取消（关窗 / 重新发送）时调用 c.cancel()
##
## 说明：
##   * 请求体完全按 OpenAI Chat Completions 规范（messages / temperature / max_tokens / stream），
##     兼容 DeepSeek / OpenAI / 通义 / Kimi / 本地 Ollama 等；只依赖 /chat/completions 一个端点。
##   * 流式（SSE）解析：按行切 `data: {...}`，累积 `choices[0].delta.content`；
##     [DONE] 收尾。网关不支持 SSE 时上层可以关掉 stream 再试，客户端本身不重试。
##   * 回调只在主线程触发（HTTPRequest 信号本身就在主线程）。
##   * 一次请求 = 一个 HTTPRequest 子节点；结束（完成 / 失败 / 取消）统一由 `_dispose()` 释放。

signal delta(text: String)      ## 流式增量（已解码的文本片段）
signal finished(text: String)   ## 整段回复完成
signal failed(message: String)  ## 出错（附可读原因）
## 出错时带上 HTTP 状态码与原始响应体（界面可展示服务端的 error.message）
signal failed_http(code: int, body: String)

const REQUEST_TIMEOUT := 90.0

var endpoint: String
var api_key: String
var model: String

var _req: HTTPRequest = null
## 请求期间累积的正文（流式与非流式共用）
var _acc := ""
## SSE 行缓冲：HTTP 分块不保证按行到达，收到片段先拼进这里，再按行消费
var _buf := ""
var _streaming := false
var _active := false
## 最近一次请求体与地址（测试用）
var last_request_body := ""
var last_request_headers: PackedStringArray = []


func _init(p_endpoint: String = "", p_key: String = "", p_model: String = "") -> void:
	endpoint = p_endpoint
	api_key = p_key
	model = p_model


## 是否正在等待响应
func is_active() -> bool:
	return _active


## 发起一次请求。messages 为 [{role, content}, ...]；opts 支持 temperature / max_tokens / stream。
## 返回 false 表示构件不齐（缺地址 / 模型 / 消息）或已有请求在跑。
func request(messages: Array, opts: Dictionary = {}) -> bool:
	if _active:
		return false
	if endpoint.strip_edges().is_empty() or model.strip_edges().is_empty():
		failed.emit("接口地址或模型名为空：请先在设置 → AI 助手里填写。")
		return false
	if messages.is_empty():
		failed.emit("没有要发送的消息。")
		return false

	# 节点挂在主循环上（SceneTree 永远存在；HTTPRequest 不在树里不会发请求）
	var loop := Engine.get_main_loop()
	var host: Node = null
	if loop is SceneTree:
		host = (loop as SceneTree).root
	if host == null:
		failed.emit("无法访问场景树，请求未发出。")
		return false

	_streaming = bool(opts.get("stream", true))
	var body := _build_body(messages, opts)
	last_request_body = body
	last_request_headers = _headers()
	_acc = ""
	_buf = ""

	_req = HTTPRequest.new()
	_req.timeout = REQUEST_TIMEOUT
	_req.use_threads = true
	host.add_child(_req)
	_req.request_completed.connect(_on_completed)
	var err := _req.request_raw(endpoint, last_request_headers, HTTPClient.METHOD_POST, body.to_utf8_buffer())
	if err != OK:
		_dispose()
		failed.emit("请求未发出（错误码 %d）：检查 Base URL 是否是合法的 http/https 地址。" % err)
		return false
	_active = true
	return true


## 主动取消（界面刷新 / 重发前调用，避免旧响应回来覆盖新内容）
func cancel() -> void:
	if _req == null:
		return
	_req.cancel_request()
	_dispose()


# ------------------------------ 组装请求 ------------------------------
func _build_body(messages: Array, opts: Dictionary) -> String:
	var payload := {
		"model": model,
		"messages": messages,
		"temperature": float(opts.get("temperature", 0.7)),
		"max_tokens": int(opts.get("max_tokens", 2048)),
	}
	if bool(opts.get("stream", true)):
		payload["stream"] = true
	return JSON.stringify(payload)


func _headers() -> PackedStringArray:
	var h := PackedStringArray(["Content-Type: application/json"])
	var key := api_key.strip_edges()
	if not key.is_empty():
		h.append("Authorization: Bearer " + key)
	return h


# ------------------------------ 响应处理 ------------------------------
func _on_completed(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	# cancel() 之后节点已被释放，这里只处理真正到手的响应
	if _req == null:
		return
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	var text := body.get_string_from_utf8()
	if not ok:
		_fail_with_http(result, code, text)
		return
	if _streaming:
		_finish_stream(text)
	else:
		_finish_plain(text)


func _fail_with_http(result: int, code: int, body: String) -> void:
	var reason := ""
	if result != HTTPRequest.RESULT_SUCCESS:
		reason = "网络请求失败（错误码 %d）%s" % [result, "\n" + _short(result)]
	elif code >= 400:
		reason = "服务端返回 HTTP %d：%s" % [code, _extract_error(body)]
	else:
		reason = "未知错误（HTTP %d）" % code
	failed_http.emit(code, body)
	failed.emit(reason.strip_edges())
	_dispose()


static func _short(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "无法连接到服务器：检查 Base URL 与网络。"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "域名解析失败：检查 Base URL。"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接中断：可能是网络不稳或超时。"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败：服务地址可能不是 HTTPS 或证书有问题。"
		HTTPRequest.RESULT_TIMEOUT:
			return "请求超时：服务响应太慢，或 max_tokens 太大。"
		_:
			return ""


## 从错误响应体里抠出服务端的说法（OpenAI 兼容格式 {"error":{"message":...}}）
static func _extract_error(body: String) -> String:
	var text := body.strip_edges()
	if text.is_empty():
		return "（无响应体）"
	var data: Variant = JSON.parse_string(text)
	if data is Dictionary:
		var err: Variant = (data as Dictionary).get("error", null)
		if err is Dictionary:
			var msg := str((err as Dictionary).get("message", "")).strip_edges()
			if not msg.is_empty():
				return msg
		var msg2 := str((data as Dictionary).get("message", "")).strip_edges()
		if not msg2.is_empty():
			return msg2
	if text.length() > 300:
		return text.substr(0, 300) + "…"
	return text


# ------------------------------ 非流式 ------------------------------
func _finish_plain(body: String) -> void:
	var data: Variant = JSON.parse_string(body)
	var content := ""
	if data is Dictionary:
		content = content_of(data as Dictionary)
	if content.is_empty():
		failed.emit("服务端返回了无法解析的内容（不是 OpenAI 兼容格式？）")
		_dispose()
		return
	_acc = content
	finished.emit(content)
	_dispose()


## 从一条完整响应里取正文：choices[0].message.content（公开给测试与自定义网关复用）
static func content_of(data: Dictionary) -> String:
	var choices: Variant = data.get("choices", [])
	if not (choices is Array) or (choices as Array).is_empty():
		return ""
	var first: Variant = (choices as Array)[0]
	if not (first is Dictionary):
		return ""
	var msg: Variant = (first as Dictionary).get("message", null)
	if msg is Dictionary:
		return str((msg as Dictionary).get("content", ""))
	# 部分服务把流式与非流式混用：delta 里带内容
	var d: Variant = (first as Dictionary).get("delta", null)
	if d is Dictionary:
		return str((d as Dictionary).get("content", ""))
	return ""


# ------------------------------ 流式（SSE） ------------------------------
## 服务端返回整段而不是 SSE（部分网关忽略 stream 参数）：按普通响应再解析一次
func _finish_stream(body: String) -> void:
	var trimmed := body.strip_edges()
	if trimmed.is_empty():
		failed.emit("服务端返回了空响应。")
		_dispose()
		return
	if not trimmed.contains("data:"):
		_finish_plain(trimmed)
		return
	feed_sse(trimmed)
	# 有些实现不发 [DONE]，只要累积到内容就当完成
	finished.emit(_acc)
	_dispose()


## 按行消费 SSE 文本（公开给测试与「手动灌分片」场景；HTTP 回调内部也走它）
func feed_sse(text: String) -> void:
	_buf += text
	var lines := _buf.split("\n")
	# 最后一行可能是不完整片段，留在缓冲里等下一批
	_buf = lines[lines.size() - 1]
	for i in range(lines.size() - 1):
		_handle_sse_line(lines[i])


## 当前累积的正文（流式过程中可读）
func accumulated() -> String:
	return _acc


func _handle_sse_line(line: String) -> void:
	var s := line.strip_edges()
	if s.is_empty():
		return
	if not s.begins_with("data:"):
		return
	var payload := s.substr(5).strip_edges()
	if payload == "[DONE]":
		return
	var data: Variant = JSON.parse_string(payload)
	if not (data is Dictionary):
		return
	var piece := _delta_of(data as Dictionary)
	if piece.is_empty():
		return
	_acc += piece
	delta.emit(piece)


## 从流式分片里取正文：choices[0].delta.content（少数服务用 text）
static func _delta_of(data: Dictionary) -> String:
	var choices: Variant = data.get("choices", [])
	if not (choices is Array) or (choices as Array).is_empty():
		return ""
	var first: Variant = (choices as Array)[0]
	if not (first is Dictionary):
		return ""
	var d: Variant = (first as Dictionary).get("delta", null)
	if d is Dictionary:
		return str((d as Dictionary).get("content", ""))
	if (first as Dictionary).has("text"):
		return str((first as Dictionary).get("text", ""))
	return ""


# ------------------------------ 收尾 ------------------------------
func _dispose() -> void:
	_active = false
	if _req != null:
		if _req.is_inside_tree():
			_req.queue_free()
		_req = null
