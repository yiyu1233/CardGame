extends RefCounted
## 卡面 / 牌背样式的**唯一来源**：手里的牌、敌方手牌的卡背、抽牌堆的牌背与飞牌都取这一套数值，
## 所以「牌堆里的牌」和「手里的牌」看起来是同一种牌（观感统一，不会一套深蓝一套灰绿）。
##
## 用法：`const CardSkin := preload("res://scripts/CardSkin.gd")`（刻意不写 `class_name`：
## 新增全局类名要等编辑器重新扫描项目才会生效，用 preload 在任何环境都能立刻跑起来）。
##
## 数值出处（逆向报告 `docs/shadowverse-battle-ui.md` §13.7 配色表）：
##   · `攻 label 描边 (0.2,0.2,0.4)`（Global.cs:379）→ 牌背底色
##   · `关键词高亮 [ffcd45] / 按下 [00d2e4]`（BattlePlayerView.cs:35,1000）→ 纹章与内描边
##   · `卡面默认文字 white`（Global.cs:371）→ 外描边
##   · `卡面失效灰 (0.2,0.2,0.2)`（Global.cs:372）→ deckout / 空牌堆
## 圆角比例取 `UiSkin.CARD_RADIUS = 10` 与手牌卡宽 118 的比（≈0.085），
## 于是缩小的牌背（牌堆 / 敌方手牌）与手里的牌圆角观感一致。

## 手牌卡的基准尺寸与宽高比（`scenes/Card.tscn` 的 CARD_SIZE = 118×170）。
## 牌堆的牌背按这个比例等比缩小，于是它看起来就是「同一张牌」。
const CARD_W := 118.0
const CARD_H := 170.0
const CARD_RATIO := CARD_W / CARD_H          ## ≈ 0.694

const RADIUS_RATIO := 0.085                  ## 圆角 = 短边 × 该比例（与 UiSkin.CARD_RADIUS 同口径）
const BORDER_W := 2

const BACK_BG := Color(0.2, 0.2, 0.4)
const BACK_INNER := Color(0.11, 0.11, 0.22)
const BACK_EDGE := Color(1, 1, 1, 0.5)
const BACK_TRIM := Color("#00d2e4")
const BACK_GOLD := Color("#ffcd45")
const DECKOUT_BG := Color(0.2, 0.2, 0.2)
const DECKOUT_INNER := Color(0.12, 0.12, 0.12)
const DECKOUT_EDGE := Color(1, 1, 1, 0.35)
const DECKOUT_TRIM := Color(1, 1, 1, 0.55)
const EMPTY_HINT := Color(0.2, 0.2, 0.2, 0.5)


## 按短边等比的圆角半径（像素），最小 3px
static func radius_for(size: Vector2) -> float:
	return maxf(3.0, minf(size.x, size.y) * RADIUS_RATIO)


## 牌堆 / 敌方手牌用的**牌背尺寸**：宽 `width`，高按手牌卡宽高比 → 与手里的牌同形
static func back_size(width: float) -> Vector2:
	return Vector2(width, width / CARD_RATIO)


## 牌背的 StyleBox（给 Panel 类控件用：敌方手牌卡背、其它需要样式框的地方）
static func back_style(size: Vector2) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = BACK_BG
	st.border_color = BACK_EDGE
	st.border_width_left = BORDER_W
	st.border_width_top = BORDER_W
	st.border_width_right = BORDER_W
	st.border_width_bottom = BORDER_W
	st.set_corner_radius_all(maxi(3, int(round(radius_for(size)))))
	st.anti_aliasing = true
	return st


## 牌背的「内板」样式（叠在底色上压出层次；与牌堆绘制的内板同色）
static func back_inner_style(size: Vector2) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = BACK_INNER
	st.border_color = BACK_TRIM
	st.set_border_width_all(BORDER_W)
	st.set_corner_radius_all(maxi(2, int(round(radius_for(size) * 0.7))))
	st.anti_aliasing = true
	return st
