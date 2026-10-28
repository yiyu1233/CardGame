class_name RoundButton
extends Button
## 圆形按钮：正方形 + 圆角＝半径即为正圆。
## 四种状态的样式与配色集中在这里，供中线两端的两个按钮共用
## （左端「记牌器」、右端「结束回合」），以后要再加中线按钮直接复用即可。

enum Tone {
	GREEN,   ## 主操作（结束回合）
	SLATE,   ## 次要操作（记牌器）
}

const DEFAULT_DIAMETER := 72.0

var tone: int = Tone.GREEN
var diameter: float = DEFAULT_DIAMETER


func _ready() -> void:
	custom_minimum_size = Vector2(diameter, diameter)
	size = custom_minimum_size
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_apply_tone()


## 圆角半径取直径的一半即为正圆
func corner_radius() -> int:
	return int(custom_minimum_size.x * 0.5)


func set_tone(new_tone: int) -> void:
	tone = new_tone
	if is_node_ready():
		_apply_tone()


func _apply_tone() -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		add_theme_stylebox_override(state, _style(state))


func _style(state: String) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if tone == Tone.SLATE:
		match state:
			"hover":
				s.bg_color = Color(0.22, 0.27, 0.34, 1.0)
				s.border_color = Color("#b0bec5")
			"pressed":
				s.bg_color = Color(0.12, 0.15, 0.20, 1.0)
				s.border_color = Color("#78909c")
			"disabled":
				s.bg_color = Color(0.13, 0.15, 0.18, 1.0)
				s.border_color = Color(0.28, 0.31, 0.36, 1.0)
			_:
				s.bg_color = Color(0.16, 0.20, 0.26, 1.0)
				s.border_color = Color("#90a4ae")
	else:
		match state:
			"hover":
				s.bg_color = Color(0.18, 0.42, 0.28, 1.0)
				s.border_color = Color("#81c784")
			"pressed":
				s.bg_color = Color(0.10, 0.24, 0.16, 1.0)
				s.border_color = Color("#4caf50")
			"disabled":
				s.bg_color = Color(0.13, 0.15, 0.18, 1.0)
				s.border_color = Color(0.28, 0.31, 0.36, 1.0)
			_:
				s.bg_color = Color(0.13, 0.32, 0.22, 1.0)
				s.border_color = Color("#66bb6a")
	s.set_border_width_all(2)
	s.set_corner_radius_all(corner_radius())
	return s
