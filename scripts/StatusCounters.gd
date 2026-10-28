class_name StatusCounters
extends RefCounted
## 状态计数的**文案与配色定义**：牌库 / 手牌 / 墓地 / 疲劳（护甲改由主战者框的血量徽章旁显示）。
##
## 这里原来是一个 5 枚徽章的 HBox 控件；英雄区改成主战者框（`HeroFrame`）之后，
## 计数格画在头像盘里，于是只保留「文案 + 颜色 + 关键状态变色」这一个定义处，
## 由 `HeroFrame` 使用 —— 避免两块地方各写一套颜色而慢慢漂移。

const COLOR_DECK := Color("#90caf9")
const COLOR_HAND := Color("#ffcc80")
const COLOR_GRAVE := Color("#b39ddb")
const COLOR_FATIGUE := Color("#ef9a9a")
const COLOR_ARMOR := Color("#cfd8dc")
const COLOR_DIM := Color("#78909c")
const COLOR_WARN := Color("#ff8a65")


static func deck_text(p: PlayerState) -> String:
	return "牌%d" % p.deck.size()


static func hand_text(p: PlayerState) -> String:
	return "手%d" % p.hand.size()


static func grave_text(p: PlayerState) -> String:
	return "墓%d" % p.graveyard.size()


static func fatigue_text(p: PlayerState) -> String:
	return "疲%d" % p.fatigue


static func deck_color(p: PlayerState) -> Color:
	return COLOR_WARN if p.deck.is_empty() else COLOR_DECK


static func hand_color(p: PlayerState, hand_limit: int) -> Color:
	return COLOR_WARN if p.hand.size() >= hand_limit else COLOR_HAND


static func grave_color(p: PlayerState) -> Color:
	return COLOR_GRAVE if not p.graveyard.is_empty() else COLOR_DIM


static func fatigue_color(p: PlayerState) -> Color:
	return COLOR_FATIGUE if p.fatigue > 0 else COLOR_DIM


static func armor_color(p: PlayerState) -> Color:
	return COLOR_ARMOR if p.armor > 0 else COLOR_DIM
