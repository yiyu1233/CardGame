class_name ManaOrbs
extends HBoxContainer
## 法力水晶珠串（参考炉石的法力水晶条 / 影之诗的 PP 珠）。
## 已解锁的水晶区分「本回合可用」（亮）与「已花费」（暗），尚未解锁的显示为空槽，
## 右侧再跟上「3/5」这样的数字，一眼就能看出还剩多少费。
##
## 水晶的「状态判定 + 样式」以静态函数对外提供，供**环绕回合按钮的能量点**
## （`TurnControl`）复用，避免两处各写一套颜色 / 阈值判定而慢慢漂移。

## 与 GameManager.MAX_MANA 对应（布局测试会断言两者一致，改 MAX_MANA 时会提醒）
const ORB_COUNT := 10
const ORB_SIZE := Vector2(11, 11)
## 与 StatusCounters 的徽章字号保持一致，避免同一块信息区两种字号
const VALUE_FONT_SIZE := 12
const ORB_CORNER_RADIUS := 5

const COLOR_READY_BG := Color("#1565c0")
const COLOR_READY_BORDER := Color("#90caf9")
const COLOR_SPENT_BG := Color("#0d2b3e")
const COLOR_SPENT_BORDER := Color("#2f6b85")
const COLOR_LOCKED_BG := Color("#161a20")
const COLOR_LOCKED_BORDER := Color("#39414d")

static var _style_cache: Dictionary = {}

var _orbs: Array[Panel] = []
var _value: Label


func _ready() -> void:
	add_theme_constant_override("separation", 3)
	alignment = BoxContainer.ALIGNMENT_BEGIN
	_build()


## 第 i 颗水晶的状态：ready = 本回合可用，spent = 已花费，locked = 尚未解锁
static func state_of(i: int, mana: int, max_mana: int) -> String:
	if i >= max_mana:
		return "locked"
	return "ready" if i < mana else "spent"


## 状态对应的样式（缓存复用：刷新很频繁，不该每次都新建 StyleBoxFlat）
static func style_for(state: String) -> StyleBoxFlat:
	if _style_cache.has(state):
		return _style_cache[state]
	var s := StyleBoxFlat.new()
	match state:
		"ready":
			s.bg_color = COLOR_READY_BG
			s.border_color = COLOR_READY_BORDER
		"spent":
			s.bg_color = COLOR_SPENT_BG
			s.border_color = COLOR_SPENT_BORDER
		_:
			s.bg_color = COLOR_LOCKED_BG
			s.border_color = COLOR_LOCKED_BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(ORB_CORNER_RADIUS)
	_style_cache[state] = s
	return s


## 数值文字的颜色：还有法力时用亮色，用光时转暗
static func value_color(mana: int) -> Color:
	return COLOR_READY_BORDER if mana > 0 else COLOR_SPENT_BORDER


func _build() -> void:
	if not _orbs.is_empty():
		return
	for _i in ORB_COUNT:
		var orb := Panel.new()
		orb.custom_minimum_size = ORB_SIZE
		orb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(orb)
		_orbs.append(orb)

	_value = Label.new()
	_value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_value.add_theme_font_size_override("font_size", VALUE_FONT_SIZE)
	add_child(_value)


## mana = 当前可用法力；max_mana = 已解锁的水晶数
func setup(mana: int, max_mana: int) -> void:
	if _orbs.is_empty():
		_build()
	for i in _orbs.size():
		_orbs[i].add_theme_stylebox_override("panel", style_for(state_of(i, mana, max_mana)))
	_value.text = "%d/%d" % [mana, max_mana]
	_value.add_theme_color_override("font_color", value_color(mana))
