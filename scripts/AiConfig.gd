extends Node
## AI 助手配置（自动加载为 AiConfig）：接口地址 / 密钥 / 模型 / 生成参数，持久化到 user://ai.cfg。
##
## 单独开一个配置文件（不动 settings.cfg）的原因：密钥与生成参数属于「可选功能」的配置，
## 与游戏偏好分开存更干净；即使不配置，游戏本身照常运行，只是 AI 浮窗会提示「尚未配置」。
##
## 约定与 GameSettings 一致：
##   * 读档时缺失的键保持当前值（首次加载即内置默认值），类型不符一律回退；
##   * 数值越界一律夹紧；
##   * 每项都有 setter / 保存入口，改完调 save_config() 落盘并 emit changed()。
##
## 默认值指向 OpenAI 兼容接口（DeepSeek 官方地址，国内直连即可用）；
## 任何兼容 /v1/chat/completions 的服务（OpenAI、通义、Kimi、本地 Ollama、LM Studio…）
## 只要改 Base URL 与模型名就能用。

signal changed()

const SAVE_PATH := "user://ai.cfg"

# ------------------------------ 默认值 ------------------------------
## Base URL：不带结尾斜杠；请求时拼 /chat/completions
const DEFAULT_BASE_URL := "https://api.deepseek.com/v1"
const DEFAULT_MODEL := "deepseek-chat"
const DEFAULT_TEMPERATURE := 0.7
const DEFAULT_MAX_TOKENS := 2048
## 多轮上下文里最多回带多少条历史消息（user + assistant，不含 system）
const DEFAULT_HISTORY_LIMIT := 24

const TEMPERATURE_MIN := 0.0
const TEMPERATURE_MAX := 2.0
const MAX_TOKENS_MIN := 64
const MAX_TOKENS_MAX := 8192
const HISTORY_LIMIT_MIN := 2
const HISTORY_LIMIT_MAX := 100

## 内置的系统提示词：把 AI 定位成「卡牌对战游戏助手」。
## 注意：这里给的是**身份与纪律**（怎么回答、怎么调工具），游戏规则细节尽量交给工具去查，
## 避免把整张卡表塞进每轮请求里。
const DEFAULT_SYSTEM_PROMPT := """你是《卡牌游戏框架》对战助手的 AI 副手，随时待命帮玩家答疑、读局面、找卡、讲规则。

回答纪律：
1. 始终用简体中文回答，语气简洁、直接，像坐在旁边的牌手，不客套、不重复问题。
2. 回答里提到具体卡牌时，用「卡名（费用 攻/血）」的写法，例如「灰烬使者（2费 3/2）」。
3. 不确定的事（卡表里查不到的卡、规则没写到的细节）要直说「卡表里没有 / 规则未说明」，不要编造。
4. 需要事实时先查工具，不要凭空猜：卡牌数据用 card_detail / card_search，当前对局局面用 game_state，
   关键字机制用 mechanic_info。一次可以调用多个工具。
5. 工具调用格式（独占一行，可连发多条）：
   [[tool: {"name":"工具名","args":{...}}]]
   工具结果会以 [[tool_result ...]] 的形式回到你这轮上下文里。
6. 发给玩家的最终答复不要包含工具调用行；通常一两段话即可，建议清单用「1. 2. 3.」短句排列。
7. 玩家问「怎么打」时，先看 game_state 的真实局面（法力、手牌、战场、双方血量），只推荐当前真能打出的操作，
   并给出取舍理由（换怪、抢血、解场、留牌），不要推荐无法执行的combo。
8. 不主动剧透对手未公开的信息（对手手牌内容、牌库内容）。"""

# ------------------------------ 当前配置 ------------------------------
var base_url := DEFAULT_BASE_URL
var api_key := ""
var model := DEFAULT_MODEL
var _temperature: float = DEFAULT_TEMPERATURE
var _max_tokens: int = DEFAULT_MAX_TOKENS
var _history_limit: int = DEFAULT_HISTORY_LIMIT
var system_prompt := DEFAULT_SYSTEM_PROMPT
## 流式输出开关（部分自建网关不支持 SSE，关掉后按整段返回）
var stream := true

var temperature: float:
	get:
		return _temperature
	set(value):
		_temperature = clampf(float(value), TEMPERATURE_MIN, TEMPERATURE_MAX)

var max_tokens: int:
	get:
		return _max_tokens
	set(value):
		_max_tokens = clampi(int(value), MAX_TOKENS_MIN, MAX_TOKENS_MAX)

var history_limit: int:
	get:
		return _history_limit
	set(value):
		_history_limit = clampi(int(value), HISTORY_LIMIT_MIN, HISTORY_LIMIT_MAX)

## 存档路径（测试用 use_save_path() 临时改写，绝不能覆盖玩家真实配置）
var save_path := SAVE_PATH


func _ready() -> void:
	load_config()


# ------------------------------ 便捷判定 ------------------------------
## 能发请求的最低条件：有地址 + 有模型。密钥留空也允许（本地 Ollama 等不需要密钥）。
func is_ready() -> bool:
	return not base_url.strip_edges().is_empty() and not model.strip_edges().is_empty()


## 尚未配置密钥且地址不是本机服务时的提示（不阻止请求，只用于界面提示）
func needs_key_hint() -> String:
	var u := base_url.to_lower()
	if api_key.strip_edges().is_empty() and not (u.contains("localhost") or u.contains("127.0.0.1")):
		return "尚未填写 API Key（设置 → AI 助手里配置）"
	return ""


## 拼接 chat/completions 地址（去尾斜杠；已含 chat/completions 时原样使用）
func endpoint() -> String:
	var u := base_url.strip_edges()
	while u.ends_with("/"):
		u = u.substr(0, u.length() - 1)
	if u.ends_with("/chat/completions"):
		return u
	return u + "/chat/completions"


# ------------------------------ 读 / 写 ------------------------------
func save_config(persist: bool = true) -> void:
	if persist:
		var cfg := ConfigFile.new()
		cfg.set_value("ai", "base_url", base_url)
		cfg.set_value("ai", "api_key", api_key)
		cfg.set_value("ai", "model", model)
		cfg.set_value("ai", "temperature", temperature)
		cfg.set_value("ai", "max_tokens", max_tokens)
		cfg.set_value("ai", "history_limit", history_limit)
		cfg.set_value("ai", "system_prompt", system_prompt)
		cfg.set_value("ai", "stream", stream)
		var err := cfg.save(save_path)
		if err != OK:
			push_warning("[AiConfig] 配置保存失败：%s（错误码 %d）" % [save_path, err])
	changed.emit()


func load_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		return
	base_url = _read_string(cfg, "base_url", base_url).strip_edges()
	api_key = _read_string(cfg, "api_key", api_key).strip_edges()
	model = _read_string(cfg, "model", model).strip_edges()
	system_prompt = _read_string(cfg, "system_prompt", system_prompt)
	stream = _read_bool(cfg, "stream", stream)
	temperature = _read_float(cfg, "temperature", temperature)
	max_tokens = _read_int(cfg, "max_tokens", max_tokens)
	history_limit = _read_int(cfg, "history_limit", history_limit)


## 全部恢复默认值（不会自动落盘，由调用方决定）
func restore_defaults() -> void:
	base_url = DEFAULT_BASE_URL
	api_key = ""
	model = DEFAULT_MODEL
	temperature = DEFAULT_TEMPERATURE
	max_tokens = DEFAULT_MAX_TOKENS
	history_limit = DEFAULT_HISTORY_LIMIT
	system_prompt = DEFAULT_SYSTEM_PROMPT
	stream = true


## 测试隔离：把存档路径改到别处（例如 user://test_ai.cfg）
func use_save_path(p: String) -> void:
	save_path = p


func save_exists() -> bool:
	return FileAccess.file_exists(save_path)


# ------------------------------ 配置读取（严格类型） ------------------------------
func _read_bool(cfg: ConfigFile, key: String, fallback: bool) -> bool:
	var v: Variant = cfg.get_value("ai", key, fallback)
	return v if typeof(v) == TYPE_BOOL else fallback


func _read_int(cfg: ConfigFile, key: String, fallback: int) -> int:
	var v: Variant = cfg.get_value("ai", key, fallback)
	if typeof(v) == TYPE_INT:
		return v
	if typeof(v) == TYPE_FLOAT:
		return int(floor(float(v)))
	return fallback


func _read_float(cfg: ConfigFile, key: String, fallback: float) -> float:
	var v: Variant = cfg.get_value("ai", key, fallback)
	return float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else fallback


func _read_string(cfg: ConfigFile, key: String, fallback: String) -> String:
	var v: Variant = cfg.get_value("ai", key, fallback)
	return v if typeof(v) == TYPE_STRING else fallback
