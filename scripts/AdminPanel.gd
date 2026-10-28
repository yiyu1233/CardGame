class_name AdminPanel
extends Window
## 管理员卡牌管理窗口：登录后即可新增、修改、删除卡表中的卡牌。
## 支持：费用 / 类型 / 攻防 / 关键字 / 描述 / 卡面颜色，以及
##   * **效果链**（战吼 / 法术 / 安放）：多条效果**按顺序结算**，可增 / 删 / 上下移动；
##   * **亡语链**：同样多条效果，按顺序结算；
##   * **主动技能**（随从 / 护符 / 城邦）：名称 / 能量点费用 / 目标 / 每回合一次 / 技能自己的效果链。
## 所有改动立即写入 user://cards.json，并对当前对局生效（失效的牌会被移除）。

signal closed()


## ---------------------------------------------------------------------------
## 效果链编辑器：战吼 / 法术 / 安放、亡语、主动技能三处**复用同一套组件**
## ---------------------------------------------------------------------------
## 每个条目一行：效果 OptionButton + 数值 SpinBox + 目标 OptionButton +
## 衍生物 ID LineEdit（仅召唤类效果可见）+ 「↑ / ↓ / 删除」三个小按钮。
## 行在容器里的**先后顺序就是结算顺序**：上移 / 下移直接交换两行的位置（边界时不动）。
## `load_chain()` 按 CardData 的链重建行；`chain()` 按当前行顺序读出链（保存时写回字段）。
class ChainEditor extends VBoxContainer:
	## 效果 ID 注册表（index ↔ id）。每行各自复制一份，未知 ID 只影响它自己那一行。
	var _ids: Array[String] = []
	var _rows: VBoxContainer = null
	## 这一条链的「时机」：用于判断某条效果在这个时机下会不会逻辑失效（标红提示）。
	## 空 = 不做时机检查（技能 / 随机能力池等通用链）。
	var _warning_context := ""
	## 「＋ 添加…」按钮（界面测试可以直接 press）
	var add_button: Button = null
	## 行变化回调：面板用它刷新效果预览
	var _on_changed: Callable = Callable()
	## 载入整条链时静默，载完只通知一次
	var _quiet := false

	func setup(title: String, add_text: String, on_changed: Callable) -> void:
		_ids = CardEffects.ids()
		_on_changed = on_changed
		add_theme_constant_override("separation", 4)

		var head := Label.new()
		head.text = title
		add_child(head)

		_rows = VBoxContainer.new()
		_rows.add_theme_constant_override("separation", 4)
		add_child(_rows)

		add_button = Button.new()
		add_button.text = add_text
		add_button.tooltip_text = "在链尾追加一条效果（结算顺序 = 从上到下）"
		add_button.pressed.connect(func() -> void: add_row())
		add_child(add_button)

	## 按链重建所有行（载入卡片时调用）。空链 → 一行都没有。
	func load_chain(chain: Array) -> void:
		clear_rows()
		_quiet = true
		for e in chain:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = e
			add_row(str(entry.get("id", CardEffects.NONE)), int(entry.get("value", 0)),
				int(entry.get("target", -1)), str(entry.get("token", "")),
				int(entry.get("src", 0)), int(entry.get("turns", 0)),
				EffectConditions.normalized(entry.get("cond", {})))
		_quiet = false
		_notify()

	## 清空所有行（这张卡没有这条链）
	func clear() -> void:
		clear_rows()
		_notify()

	func clear_rows() -> void:
		for box in _rows.get_children():
			_rows.remove_child(box)
			box.queue_free()

	## 追加一条效果（默认「无效果」/ 数值 0 / 默认目标 / 无衍生物 / 来源=牌库 / 不限时 / 无条件）。
	## id 传空串等价于 CardEffects.NONE（该行的下拉框会落到「无效果」）。
	## `cond` 非空时这一条会带上条件（EffectConditions）：不满足就跳过这一条。
	func add_row(id: String = "", value: int = 0, target: int = -1, token: String = "",
			src: int = 0, turns: int = 0, cond: Dictionary = {}) -> void:
		_make_row(id, value, target, token, src, turns, cond)
		_notify()

	## 按**当前行顺序**读出效果链（保存时写回 effects / deathrattle_effects / skill.effects）
	func chain() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for box in _rows.get_children():
			if not box.has_meta("chain_state"):
				continue
			var state: Dictionary = box.get_meta("chain_state")
			var id := _row_id(state)
			var value_spin: SpinBox = state["value_spin"]
			var target_option: OptionButton = state["target_option"]
			var token_edit: LineEdit = state["token_edit"]
			var src_option: OptionButton = state["src_option"]
			var turns_spin: SpinBox = state["turns_spin"]
			var entry := {
				"id": id,
				"value": int(value_spin.value),
				"target": int(target_option.selected),
				# 只有用得上 token 的效果才把它写进链（召唤类 = 衍生物 ID、随机能力 = 池 ID、
				# 赋予技能 / 能力 = 来源卡牌 ID、随机获得类 = 来源范围、
				# 牌库 / 手牌改造 = 区域|目标），其余效果不写脏数据
				"token": token_edit.text.strip_edges() \
					if (CardEffects.needs_token(id) or CardEffects.needs_card_ref(id)
						or CardEffects.needs_pool(id) or CardEffects.needs_scope(id)
						or CardEffects.needs_spec(id)) else "",
			}
			# 两条限定词缀同理：只有声明需要的效果才写进链，避免给无关效果塞脏数据
			if CardEffects.needs_src(id):
				entry["src"] = int(src_option.selected)
			if CardEffects.needs_turns(id):
				entry["turns"] = int(turns_spin.value)
			# 条件（可选）：条件行留空就不写这个键，老卡表的链逐字保持不变
			var cond := _row_cond(state)
			if not cond.is_empty():
				entry["cond"] = cond
			out.append(entry)
		return out

	func row_count() -> int:
		return _rows.get_child_count()

	## 设置「时机」并立刻刷新红色提示（入场 / 离场 / 被召唤 / 融合 / 谢幕…）
	func set_warning_context(ctx: String) -> void:
		_warning_context = ctx
		refresh_warnings()

	## 重新计算每一行的时机警告：有逻辑问题的行整体标红 + 行内红字说明。
	## **只提示、不删除** —— 由管理员看完自行决定是否删掉这一条。
	func refresh_warnings() -> void:
		for i in _rows.get_child_count():
			var entry := entry_at(i)
			var msg := ""
			if _warning_context != "":
				msg = CardEffects.context_warning(str(entry.get("id", "")), _warning_context,
					str(entry.get("token", "")))
			_set_row_warning(i, msg)

	## 第 index 行当前的条目（与 chain() 里那一项完全一致）
	func entry_at(index: int) -> Dictionary:
		var all := chain()
		return all[index] if index >= 0 and index < all.size() else {}

	func _set_row_warning(index: int, msg: String) -> void:
		if index < 0 or index >= _rows.get_child_count():
			return
		var state: Dictionary = _rows.get_child(index).get_meta("chain_state")
		var label: Label = state.get("warn_label")
		if label != null:
			label.text = msg
			label.visible = msg != ""
		var box := _rows.get_child(index) as Control
		if box != null:
			box.modulate = Color(1, 0.72, 0.72) if msg != "" else Color.WHITE

	## 第 index 行的控件字典（供界面测试直接驱动；越界返回空字典）
	func row_state(index: int) -> Dictionary:
		if index < 0 or index >= _rows.get_child_count():
			return {}
		return _rows.get_child(index).get_meta("chain_state")

	## 把第 index 行的效果改成 id（自动带入默认目标、按需显示衍生物输入框）
	func set_row_effect(index: int, id: String) -> void:
		var state := row_state(index)
		if state.is_empty():
			return
		var option: OptionButton = state["id_option"]
		var ids: Array[String] = state["ids"]
		option.selected = _select_effect(option, ids, id)
		_on_effect_picked(state)

	## 上移 / 下移：交换两行的位置（边界时不动）
	func move_row(index: int, delta: int) -> void:
		var n := _rows.get_child_count()
		var to := index + delta
		if index < 0 or index >= n or to < 0 or to >= n:
			return
		_rows.move_child(_rows.get_child(index), to)
		_notify()

	## 删除第 index 行
	func erase_row(index: int) -> void:
		var n := _rows.get_child_count()
		if index < 0 or index >= n:
			return
		var box := _rows.get_child(index)
		_rows.remove_child(box)
		box.queue_free()
		_notify()

	# ---- 内部 ----

	func _make_row(id: String, value: int, target: int, token: String,
			src: int = 0, turns: int = 0, cond: Dictionary = {}) -> void:
		# 一行 = 两小行：① 效果本体（效果 / 数值 / 目标 / 衍生物 / 来源 / 回合数 / 排序）
		#              ② 条件（量 + 兵种 + 比较符 + 阈值；留空 = 无条件）
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		_rows.add_child(box)

		var main := HBoxContainer.new()
		main.add_theme_constant_override("separation", 6)
		box.add_child(main)

		var id_option := OptionButton.new()
		var ids: Array[String] = _ids.duplicate()
		for effect_id in ids:
			id_option.add_item(CardEffects.display_name(effect_id))
		id_option.custom_minimum_size = Vector2(150, 0)
		id_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		id_option.tooltip_text = "这一条的效果（从上到下按顺序结算）"
		main.add_child(id_option)

		var value_spin := SpinBox.new()
		value_spin.min_value = 0
		value_spin.max_value = maxf(30.0, float(value))   # 手改 JSON 的大数值不被静默夹断
		value_spin.step = 1
		value_spin.value = value
		value_spin.custom_minimum_size = Vector2(72, 0)
		value_spin.tooltip_text = "这一条的效果数值"
		main.add_child(value_spin)

		var target_option := OptionButton.new()
		for i in CardData.TARGET_NAMES.size():
			target_option.add_item(CardData.TARGET_NAMES[i])
		target_option.custom_minimum_size = Vector2(132, 0)
		target_option.tooltip_text = "这一条的目标类型"
		main.add_child(target_option)

		var token_edit := LineEdit.new()
		token_edit.placeholder_text = "衍生物 ID（如 t001）"
		token_edit.custom_minimum_size = Vector2(96, 0)
		token_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		token_edit.tooltip_text = "召唤类效果要召唤的衍生物卡牌 ID"
		main.add_child(token_edit)

		# 限定词缀 ①「来源」：检索类效果可以去牌库、墓地，或牌库优先再看墓地
		var src_option := OptionButton.new()
		for n in EffectContext.SOURCE_NAMES:
			src_option.add_item(str(n))
		src_option.custom_minimum_size = Vector2(112, 0)
		src_option.tooltip_text = "来源限定：这一条效果去哪儿翻牌"
		main.add_child(src_option)

		# 限定词缀 ②「持续回合数」：0 = 永久 / 一次性；N = 到目标一方第 N 个回合结束时失效
		var turns_spin := SpinBox.new()
		turns_spin.min_value = 0
		turns_spin.max_value = 10
		turns_spin.step = 1
		turns_spin.value = turns
		turns_spin.custom_minimum_size = Vector2(72, 0)
		turns_spin.tooltip_text = "持续回合数（0 = 永久 / 一次性）"
		main.add_child(turns_spin)

		var up := Button.new()
		up.text = "↑"
		up.tooltip_text = "上移（提前结算）"
		up.custom_minimum_size = Vector2(30, 0)
		main.add_child(up)

		var down := Button.new()
		down.text = "↓"
		down.tooltip_text = "下移（延后结算）"
		down.custom_minimum_size = Vector2(30, 0)
		main.add_child(down)

		var remove := Button.new()
		remove.text = "删除"
		remove.tooltip_text = "删除这一条效果"
		main.add_child(remove)

		# ---- 条件行：不满足就跳过这一条（量由 EffectConditions 注册，兵种由管理员创建）----
		var cond_row := HBoxContainer.new()
		cond_row.add_theme_constant_override("separation", 6)
		box.add_child(cond_row)

		var cond_label := Label.new()
		cond_label.text = "条件"
		cond_label.custom_minimum_size = Vector2(34, 0)
		cond_label.tooltip_text = "不满足就跳过这一条效果（第一项「无条件」= 一定结算）"
		cond_row.add_child(cond_label)

		var cond_metric := OptionButton.new()
		cond_metric.add_item("（无条件）")
		cond_metric.set_item_metadata(0, "")
		var mi := 1
		for m in EffectConditions.metrics():
			cond_metric.add_item(EffectConditions.metric_label(m))
			cond_metric.set_item_metadata(mi, m)
			mi += 1
		cond_metric.custom_minimum_size = Vector2(150, 0)
		cond_metric.tooltip_text = "要读的量（新增一个量只要在 EffectConditions 里注册一行）"
		cond_row.add_child(cond_metric)

		var cond_troop := OptionButton.new()
		var ti := 0
		for e in CardDB.troops:
			var tid := str(e.get("id", ""))
			cond_troop.add_item(str(e.get("name", tid)))
			cond_troop.set_item_metadata(ti, tid)
			ti += 1
		if cond_troop.item_count == 0:
			cond_troop.add_item(CardData.NEUTRAL_TROOP_NAME)
			cond_troop.set_item_metadata(0, CardData.NEUTRAL_TROOP)
		cond_troop.custom_minimum_size = Vector2(110, 0)
		cond_troop.tooltip_text = "条件针对哪个兵种（含内置「中立」；别的兵种在左侧「兵种」面板创建）"
		cond_row.add_child(cond_troop)

		var cond_op := OptionButton.new()
		for op in EffectConditions.OPS:
			cond_op.add_item(EffectConditions.op_symbol(op))
		cond_op.custom_minimum_size = Vector2(64, 0)
		cond_op.tooltip_text = "比较符"
		cond_row.add_child(cond_op)

		var cond_value := SpinBox.new()
		cond_value.min_value = 0
		cond_value.max_value = 99
		cond_value.step = 1
		cond_value.custom_minimum_size = Vector2(72, 0)
		cond_value.tooltip_text = "阈值"
		cond_row.add_child(cond_value)

		# 时机警告：这一条在当前时机（入场 / 离场 / 谢幕…）下会不会逻辑失效。
		# 只标红提示，不自动删除 —— 删不删由管理员决定。
		var warn := Label.new()
		warn.add_theme_color_override("font_color", Color("#ff8a80"))
		warn.add_theme_font_size_override("font_size", 11)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn.visible = false
		box.add_child(warn)

		var state := {
			"box": box,
			"ids": ids,
			"id_option": id_option,
			"value_spin": value_spin,
			"target_option": target_option,
			"token_edit": token_edit,
			"src_option": src_option,
			"turns_spin": turns_spin,
			"up": up,
			"down": down,
			"remove": remove,
			"cond_row": cond_row,
			"cond_metric": cond_metric,
			"cond_troop": cond_troop,
			"cond_op": cond_op,
			"cond_value": cond_value,
			"warn_label": warn,
		}
		box.set_meta("chain_state", state)

		# 载入初值（不触发回调；由 add_row / load_chain 统一通知一次）
		id_option.selected = _select_effect(id_option, ids, id)
		target_option.selected = _resolve_target(id, target)
		token_edit.text = token
		src_option.selected = src
		_select_by_metadata(cond_metric, str(cond.get("metric", "")))
		_select_by_metadata(cond_troop, str(cond.get("troop", CardData.NEUTRAL_TROOP)))
		cond_op.selected = maxi(0, EffectConditions.OPS.find(
			str(cond.get("op", EffectConditions.default_op(str(cond.get("metric", "")))))))
		cond_value.value = int(cond.get("value", 0))
		_apply_row_flags(state)

		id_option.item_selected.connect(func(_i: int) -> void: _on_effect_picked(state))
		value_spin.value_changed.connect(func(_v: float) -> void: _notify())
		target_option.item_selected.connect(func(_i: int) -> void: _notify())
		token_edit.text_changed.connect(func(_t: String) -> void: _notify())
		src_option.item_selected.connect(func(_i: int) -> void: _notify())
		turns_spin.value_changed.connect(func(_v: float) -> void: _notify())
		cond_metric.item_selected.connect(func(_i: int) -> void: _on_cond_metric_picked(state))
		cond_troop.item_selected.connect(func(_i: int) -> void: _notify())
		cond_op.item_selected.connect(func(_i: int) -> void: _notify())
		cond_value.value_changed.connect(func(_v: float) -> void: _notify())
		up.pressed.connect(func() -> void: move_row(_index_of(box), -1))
		down.pressed.connect(func() -> void: move_row(_index_of(box), 1))
		remove.pressed.connect(func() -> void: erase_row(_index_of(box)))

	## 选中效果后自动带入它的默认目标（沿用旧版行为），并按需要显示衍生物输入框
	func _on_effect_picked(state: Dictionary) -> void:
		var id := _row_id(state)
		var target_option: OptionButton = state["target_option"]
		target_option.selected = _resolve_target(id, -1)
		_apply_row_flags(state)
		_notify()

	## 按这一条效果声明的限定词缀显示 / 隐藏控件：
	## 衍生物 ID 只在召唤类效果时需要；来源 / 持续回合数同理，省出横向空间。
	func _apply_row_flags(state: Dictionary) -> void:
		var id := _row_id(state)
		var token_edit: LineEdit = state["token_edit"]
		# 「随机能力」与召唤类效果共用 token 字段（一个填能力池 ID，一个填衍生物 ID），
		# 提示文字按当前效果切换，避免把池子 ID 误填成衍生物。
		var need_token := CardEffects.needs_token(id)
		var need_pool := CardEffects.needs_pool(id)
		var need_card_ref := CardEffects.needs_card_ref(id)
		var need_scope := CardEffects.needs_scope(id)
		var need_spec := CardEffects.needs_spec(id)
		token_edit.visible = need_token or need_pool or need_card_ref or need_scope or need_spec
		token_edit.editable = need_token or need_pool or need_card_ref or need_scope or need_spec
		if need_spec:
			token_edit.placeholder_text = "区域|目标（如 deck|card:t001）"
			token_edit.tooltip_text = "用竖线分隔：替换卡牌 deck|card:t001 、hand|enemy_hand；" \
				+ "破坏牌库 deck|random 、deck|cost:2 、deck|effect:damage；" \
				+ "向牌库加牌 deck|card:t001 、deck|pack:basic,chaos"
		elif need_scope:
			token_edit.placeholder_text = "来源范围（如 board / hand）"
			token_edit.tooltip_text = "随机从哪儿获得：%s；也可以填 pack:<卡包 ID> 或 troop:<兵种 ID>" % \
				" / ".join(CardEffects.scope_ids())
		elif need_pool:
			token_edit.placeholder_text = "能力池 ID（如 chaos）"
			token_edit.tooltip_text = "可用能力池：%s" % ", ".join(AbilityPools.ids())
		elif need_card_ref:
			token_edit.placeholder_text = "卡牌 ID（技能 / 能力来源）"
			token_edit.tooltip_text = "复制哪张卡的主动技能 / 触发能力（填卡表里的卡牌 ID）"
		else:
			token_edit.placeholder_text = "衍生物 ID（如 t001）"
			token_edit.tooltip_text = "召唤类效果要召唤的衍生物卡牌 ID"

		# 数值列：随机获得类 = 抽几个来源；牌库改造 = 张数（破坏筛选时 0 = 所有匹配）
		var value_spin: SpinBox = state["value_spin"]
		if need_spec:
			value_spin.tooltip_text = "张数（「破坏牌库卡牌」的筛选口径下 0 = 所有匹配的卡）"
		elif need_scope:
			value_spin.tooltip_text = "「随机获得技能」固定取 1 个（随从只有一个技能栏）" \
				if id == CardEffects.GAIN_RANDOM_SKILL else "抽几个来源（候选不足时按实际数量）"
		else:
			value_spin.tooltip_text = "这一条的效果数值"

		var src_option: OptionButton = state["src_option"]
		var need_src := CardEffects.needs_src(id)
		src_option.visible = need_src
		if not need_src:
			src_option.selected = 0                    # 换掉效果时把来源复位成「牌库」

		var turns_spin: SpinBox = state["turns_spin"]
		var need_turns := CardEffects.needs_turns(id)
		turns_spin.visible = need_turns
		turns_spin.editable = need_turns
		if not need_turns:
			turns_spin.value = 0                       # 同理：复位成「永久 / 一次性」

		# 条件：量没选时兵种 / 比较符 / 阈值三格禁用（避免「填了却不生效」的困惑）
		var metric_option: OptionButton = state["cond_metric"]
		var metric_meta = metric_option.get_item_metadata(maxi(0, metric_option.selected))
		var has_cond := metric_meta != null and str(metric_meta) != ""
		(state["cond_troop"] as OptionButton).disabled = not has_cond
		(state["cond_op"] as OptionButton).disabled = not has_cond
		(state["cond_value"] as SpinBox).editable = has_cond

	## 条件行读成数据：量没选 → 空字典（= 无条件，不写进链）
	func _row_cond(state: Dictionary) -> Dictionary:
		var metric_option: OptionButton = state["cond_metric"]
		if metric_option.selected < 0:
			return {}
		var metric_meta = metric_option.get_item_metadata(metric_option.selected)
		var metric := "" if metric_meta == null else str(metric_meta)
		if metric == "":
			return {}
		var troop_option: OptionButton = state["cond_troop"]
		var troop_meta = troop_option.get_item_metadata(maxi(0, troop_option.selected))
		var troop := "" if troop_meta == null else str(troop_meta)
		if troop == "":
			troop = CardData.NEUTRAL_TROOP      # 没选兵种 = 中立兵种
		var op_option: OptionButton = state["cond_op"]
		var value_spin: SpinBox = state["cond_value"]
		return {
			"metric": metric,
			"troop": troop,
			"op": EffectConditions.OPS[clampi(op_option.selected, 0, EffectConditions.OPS.size() - 1)],
			"value": int(value_spin.value),
		}

	## 选中条件下拉里 metadata == value 的那一项（找不到 → 第一项）
	static func _select_by_metadata(option: OptionButton, value: String) -> void:
		for i in option.item_count:
			var meta = option.get_item_metadata(i)
			if meta != null and str(meta) == value:
				option.select(i)
				return
		option.select(0)

	## 换了「量」之后：带出这个量的默认比较符，并启用 / 禁用兵种那几格
	func _on_cond_metric_picked(state: Dictionary) -> void:
		var metric_option: OptionButton = state["cond_metric"]
		var metric_meta = metric_option.get_item_metadata(maxi(0, metric_option.selected))
		var metric := "" if metric_meta == null else str(metric_meta)
		if metric != "":
			var op_option: OptionButton = state["cond_op"]
			op_option.selected = maxi(0, EffectConditions.OPS.find(EffectConditions.default_op(metric)))
		_apply_row_flags(state)
		_notify()

	func _row_id(state: Dictionary) -> String:
		var option: OptionButton = state["id_option"]
		var ids: Array[String] = state["ids"]
		var i := option.selected
		return ids[i] if i >= 0 and i < ids.size() else CardEffects.NONE

	func _index_of(box: Node) -> int:
		return _rows.get_children().find(box)

	func _notify() -> void:
		if _quiet:
			return
		refresh_warnings()
		if _on_changed.is_valid():
			_on_changed.call()

	## 条目的目标类型：-1 / 越界 → 用该效果的默认目标（契约：缺省 / -1 表示用默认目标）
	static func _resolve_target(id: String, target: int) -> int:
		if target < 0 or target >= CardData.TARGET_NAMES.size():
			return CardEffects.default_target(id)
		return target

	## 让下拉框选中指定效果 ID。ID 不在注册表里时（手改 JSON / 更新版本的卡表）
	## 临时把它加进这一行的下拉框并选中，避免“选中一下再保存”把未知效果改写成「无效果」。
	static func _select_effect(option: OptionButton, ids: Array[String], id: String) -> int:
		if id == "" or id == CardEffects.NONE:
			return maxi(0, ids.find(CardEffects.NONE))
		var found := ids.find(id)
		if found >= 0:
			return found
		ids.append(id)
		option.add_item("未知效果（%s）" % id)
		return ids.size() - 1


# ------------------------------ 面板成员 ------------------------------

var _list: ItemList
var _count_label: Label
var _id_edit: LineEdit
var _name_edit: LineEdit
var _cost_spin: SpinBox
var _type_option: OptionButton
var _rarity_option: OptionButton                  ## 稀有度（制作卡牌必选）
var _copies_spin: SpinBox                         ## 这张牌组里最多带几张（0 = 自动）
var _attack_spin: SpinBox
var _health_spin: SpinBox
var _token_check: CheckBox
var _keyword_checks: Dictionary = {}    ## CardData.Keyword -> CheckBox
var _desc_edit: TextEdit
var _color_picker: ColorPickerButton
var _status_label: Label
var _effect_preview: Label
## 「保存」按钮：钉在窗口底部（不随表单滚动），供界面测试核对它真的可见 / 在窗口内
var _save_button: Button = null
## 四周边距容器：窗口尺寸按它的最小尺寸来定
var _margin: MarginContainer = null
## 根 VBox / 中间主体 / 表单滚动容器 / 表单本体：用于算「内容理想尺寸」
var _root_vbox: VBoxContainer = null
var _body: HBoxContainer = null
var _form_scroll: ScrollContainer = null
var _form: VBoxContainer = null

## 效果链编辑器（战吼 / 法术 / 安放、亡语、技能链三处复用同一套 ChainEditor 组件）
var _battlecry_editor: ChainEditor = null
var _death_editor: ChainEditor = null
var _skill_editor: ChainEditor = null
## 主动技能编辑器：勾选「启用主动技能」后才展开
var _skill_check: CheckBox = null
var _skill_box: VBoxContainer = null
var _skill_name_edit: LineEdit = null
var _skill_cost_spin: SpinBox = null
var _skill_target_option: OptionButton = null
var _skill_once_check: CheckBox = null
## 技能目标是否被管理员显式选过（没选过时自动跟随技能链里第一条需要选目标的效果）
var _skill_target_touched := false
## 正在按数据回填技能控件（此时的赋值不算「管理员选择」）
var _skill_ui_loading := false

## 瞬念召唤编辑器：勾选后才展开（触发条件 / 数值 / 触发时机 / 效果 / 基础机制）
var _invoke_check: CheckBox = null
var _invoke_box: VBoxContainer = null
var _invoke_metric_option: OptionButton = null
## 兵种类量才用得上：瞬念召唤的条件对着哪个兵种（普通量时整行隐藏）
var _invoke_troop_option: OptionButton = null
var _invoke_troop_label: Label = null
var _invoke_op_option: OptionButton = null
var _invoke_value_spin: SpinBox = null
var _invoke_timing_option: OptionButton = null
var _invoke_editor: ChainEditor = null          ## 瞬念召唤效果链（可留空，与战吼 / 亡语独立）
var _invoke_dest_option: OptionButton = null    ## 基础机制（去向，必选不能为空）

## 融合（手牌里吃掉符合条件的其它手牌 → 获得效果 / 化身）
var _fusion_check: CheckBox = null
var _fusion_box: VBoxContainer = null
var _fusion_count_spin: SpinBox = null
var _fusion_troop_option: OptionButton = null
var _fusion_type_option: OptionButton = null
var _fusion_cost_min_spin: SpinBox = null
var _fusion_cost_max_spin: SpinBox = null
var _fusion_transform_edit: LineEdit = null
var _fusion_req_metric: OptionButton = null
var _fusion_req_op: OptionButton = null
var _fusion_req_value: SpinBox = null
var _fusion_req_troop: OptionButton = null
var _fusion_editor: ChainEditor = null          ## 融合时在手牌里发动的效果
var _fusion_gain_editor: ChainEditor = null     ## 融合后永久获得的效果

## 主战者效果（照影之诗一代的「主战者に付与される効果」）：
## 一张卡可以在某个时机把一条「监听器」挂到主战者身上，之后由引擎在事件发生时结算。
## 这里是「清单 + 选中行编辑」：上面一条清单，下面一排控件 + 一个共享的效果链编辑器。
var _leader_list: ItemList = null
var _leader_grant_option: OptionButton = null
var _leader_event_option: OptionButton = null
var _leader_cost_spin: SpinBox = null
var _leader_turns_spin: SpinBox = null
var _leader_target_option: OptionButton = null
var _leader_editor: ChainEditor = null
var _leader_rows: Array[Dictionary] = []
var _leader_selected := -1
var _leader_loading := false

## 卡牌触发效果（CardTriggers）：这张卡在某个时机自动结算一条效果链。
## 同样是「清单 + 选中行编辑」：清单在上，选中的那条用一个时机下拉 + 一个效果链编辑器。
var _trigger_list: ItemList = null
var _trigger_event_option: OptionButton = null
var _trigger_editor: ChainEditor = null
var _trigger_rows: Array[Dictionary] = []
var _trigger_selected := -1
var _trigger_loading := false

## 卡组规则（全局）：最少 / 最多张数 + 同名卡最大携带数
var _deck_min_spin: SpinBox = null
var _deck_max_spin: SpinBox = null
var _deck_copies_spin: SpinBox = null
var _type_cap_spins: Dictionary = {}    ## CardData.CardType -> SpinBox（该种类总携带上限，0=不限）
var _deck_apply_button: Button = null
var _deck_rules_label: Label = null

## 卡包（全局）：先建卡包、再给卡牌选（影之诗的卡包 / 扩展包）。
## 「指定」模式只认管理员勾选的卡包；「无限」模式所有卡包都能用。
var _pack_list: ItemList = null
var _pack_id_edit: LineEdit = null
var _pack_name_edit: LineEdit = null
var _pack_desc_edit: LineEdit = null
var _pack_color: ColorPickerButton = null
var _pack_hint: Label = null
## 卡牌表单里的「卡包」下拉
var _card_pack_option: OptionButton = null

## 随机能力池（全局）：池子列表 + 随机口径 / 个数范围 + 池内的能力清单（复用 ChainEditor）
var _ability_pool_list: ItemList = null
var _ability_id_edit: LineEdit = null
var _ability_name_edit: LineEdit = null
var _ability_desc_edit: LineEdit = null
var _ability_mode_option: OptionButton = null
var _ability_min_spin: SpinBox = null
var _ability_max_spin: SpinBox = null
var _ability_editor: ChainEditor = null
var _ability_hint: Label = null

## 对战模式规则（指定 / 无限）：两个模式各用各的张数规则 + 限制卡表，互不影响。
var _format_option: OptionButton = null
var _fmt_min_spin: SpinBox = null
var _fmt_max_spin: SpinBox = null
var _fmt_copies_spin: SpinBox = null
var _fmt_cap_spins: Dictionary = {}      ## CardData.CardType -> SpinBox（指定模式的种类上限）
var _fmt_packs_scroll: ScrollContainer = null
var _fmt_packs_box: VBoxContainer = null
var _fmt_pack_checks: Dictionary = {}    ## 卡包 id -> CheckBox（指定模式的可用卡包）
var _fmt_packs_signature := ""           ## 上次重建勾选区时的卡包清单（变了才重建）
var _fmt_limits: Dictionary = {}         ## 当前模式的限制卡表：card_id -> 允许张数（0=禁用）
var _limit_card_option: OptionButton = null
var _limit_spin: SpinBox = null
var _limit_list: ItemList = null
var _fmt_hint: Label = null
var _fmt_mode: String = Formats.UNLIMITED

## 主战者职业（全局）：职业清单 + 编辑表单（id 定下来之后不能改，避免卡牌残留在旧 id 上）
var _hero_class_list: ItemList = null
var _hero_class_id_edit: LineEdit = null
var _hero_class_name_edit: LineEdit = null
var _hero_class_desc_edit: LineEdit = null
var _hero_class_color: ColorPickerButton = null
var _hero_class_hint: Label = null
## 卡牌表单里的「主战者职业」下拉（第一项永远是「中立」）
var _card_class_option: OptionButton = null

## 兵种（全局）：先建兵种、再给卡牌选（影之诗的 士兵 / 指挥官 那类单位分类）
var _troop_list: ItemList = null
var _troop_id_edit: LineEdit = null
var _troop_name_edit: LineEdit = null
var _troop_desc_edit: LineEdit = null
var _troop_color: ColorPickerButton = null
var _troop_hint: Label = null
## 卡牌表单里的「兵种」下拉（含内置「中立」；不选 = 中立）
var _card_troop_option: OptionButton = null
## 卡表检索：关键字输入 + 兵种筛选（与组卡界面共用 CardDB.card_matches 的口径）
var _list_search: LineEdit = null
var _list_troop_filter: OptionButton = null

## 「可信」的宿主区域下限：比这还小（典型是无头模式的 64×64 根窗口）就忽略它
const MIN_HOST_AREA := Vector2i(480, 360)

## 效果预览用的探针卡（只用来调 CardData.chain_text()，不参与保存）
var _text_probe: CardData = null

var _is_new := false


func _ready() -> void:
	title = "卡牌管理（管理员：%s）" % AdminAuth.user_name
	# 表单很高（基础字段 + 效果链 + 亡语链 + 技能 + 关键字 + 描述），窗口必须放得下「保存」那一行：
	# 先留给 _build_ui() 建好控件，再**按内容的最小尺寸**定窗口大小，并按屏幕可用区域夹紧；
	# 屏幕太小放不下时表单区可滚动，而「保存 / 恢复默认 / 状态栏」固定在窗口底部 **永远可见**
	# （见 _build_ui）。用户反馈的「没有保存选项」就是它被裁到窗口之外了。
	unresizable = false
	min_size = Vector2i(720, 420)
	transient = true
	close_requested.connect(_on_close_requested)
	_build_ui()
	# 建好控件后按**内容最小尺寸**定窗口大小（再按屏幕可用区域夹紧）：
	# 这样「保存 / 恢复默认 / 状态栏」这一排一定在窗口里，表单再高也只是内部滚动。
	size = _fit_size(_content_min_size())
	_center_on_screen()
	CardDB.database_changed.connect(_refresh_list)
	# 卡表 / 卡包 / 规则一变，卡包下拉、限制卡候选与模式提示跟着刷新
	CardDB.database_changed.connect(_refresh_format_sources)
	_refresh_list()
	_new_card()


## 宿主窗口（Godot 默认把子窗口「嵌入」到主窗口里渲染，`embed_subwindows`）。
func _find_host_window() -> Window:
	var n: Node = get_parent()
	while n != null:
		if n is Window and n != self:
			return n as Window
		n = n.get_parent()
	return null


## 可用区域：优先用**宿主窗口**的尺寸，其次屏幕可用区域；两者都不可信时返回 (0, 0)（= 不夹紧）。
##
## 为什么要按宿主窗口夹紧：面板坐标是相对宿主视口的，而「比游戏窗口还高」的面板下半部分
## 会被直接裁掉（用户反馈「看不到保存按钮」的根因）。无头测试里宿主窗口只有 64×64
## 这种不可信尺寸，所以加了 MIN_HOST_AREA 兜底，否则窗口会被压成一条。
func _host_area() -> Vector2i:
	var host := _find_host_window()
	if host != null and host.size.x >= MIN_HOST_AREA.x and host.size.y >= MIN_HOST_AREA.y:
		return host.size
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	if usable.x >= MIN_HOST_AREA.x and usable.y >= MIN_HOST_AREA.y:
		return usable
	return Vector2i.ZERO


func _center_on_screen() -> void:
	var area := _host_area()
	if area.x <= 0 or area.y <= 0:
		return
	position = Vector2i(maxi((area.x - size.x) / 2, 0), maxi((area.y - size.y) / 2, 0))


## 内容需要的窗口尺寸：
##   宽 = 外边距容器的最小宽（表单 + 列表并排）；
##   高 = 各段的**理想**高度之和，其中表单区用表单自身的最小高度
##        （滚动容器只会报一个很小的高度，直接用它会得到一个被压扁的窗口）。
func _content_min_size() -> Vector2i:
	if _margin == null or _root_vbox == null:
		return Vector2i(1180, 880)
	var pad: float = 28.0                     # MarginContainer 上下各 14
	var sep: float = float(_root_vbox.get_theme_constant("separation"))
	var need_h: float = 0.0
	var rows := 0
	for child in _root_vbox.get_children():
		var c := child as Control
		if c == null:
			continue
		rows += 1
		if c == _body and _form != null:
			# 表单在滚动容器里：容器本身只报很小的最小高度，
			# 这里改用**表单自身**的高度（否则窗口会被压成一条）
			need_h += maxf(c.get_combined_minimum_size().y, _form.get_combined_minimum_size().y)
		else:
			need_h += c.get_combined_minimum_size().y
	need_h += sep * float(maxi(rows - 1, 0)) + pad
	var need_w: float = _margin.get_combined_minimum_size().x
	return Vector2i(int(ceil(need_w)), int(ceil(need_h)))


## 目标窗口尺寸按**可用区域**（宿主窗口 / 屏幕）夹紧：
## 面板永远开得比游戏窗口小一点，配合内部滚动容器，内容不会跑到窗口外面去。
## 取不到可用区域（无头 / 特殊显示器）时不夹紧，直接按内容尺寸开。
func _fit_size(want: Vector2i) -> Vector2i:
	var area := _host_area()
	var out := want
	if area.x > 0 and area.y > 0:
		out.x = clampi(want.x, 480, maxi(480, area.x - 40))
		out.y = clampi(want.y, 360, maxi(360, area.y - 60))
	return out


# ------------------------------ 界面构建 ------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)
	_margin = margin

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 10)
	margin.add_child(root_vbox)
	_root_vbox = root_vbox

	var top_row := HBoxContainer.new()
	root_vbox.add_child(top_row)
	_count_label = Label.new()
	_count_label.text = "卡牌列表"
	top_row.add_child(_count_label)
	var top_spacer := Control.new()
	top_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(top_spacer)
	var logout_btn := Button.new()
	logout_btn.text = "退出登录"
	logout_btn.pressed.connect(_on_logout_pressed)
	top_row.add_child(logout_btn)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(body)
	_body = body

	# 左栏整体放进滚动容器：卡牌列表 + 卡组规则 + 主战者职业三段内容加起来
	# 可能比窗口还高，滚动保证**任何屏幕尺寸下都不会把下面那段裁到窗口外面**。
	var left_scroll := ScrollContainer.new()
	left_scroll.custom_minimum_size = Vector2(300, 0)
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(left_scroll)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(left)

	# 卡表检索：卡名 / 描述 / 效果文本 / 关键字 / **兵种名**（与组卡界面同一套口径）
	var list_filter_row := HBoxContainer.new()
	list_filter_row.add_theme_constant_override("separation", 6)
	left.add_child(list_filter_row)
	_list_search = LineEdit.new()
	_list_search.placeholder_text = "检索：卡名 / 效果 / 关键字 / 兵种"
	_list_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_search.text_changed.connect(func(_t: String) -> void: _refresh_list())
	list_filter_row.add_child(_list_search)
	_list_troop_filter = OptionButton.new()
	_list_troop_filter.tooltip_text = "按兵种筛选（兵种在下面的「兵种」面板里创建）"
	_list_troop_filter.item_selected.connect(func(_i: int) -> void: _refresh_list())
	list_filter_row.add_child(_list_troop_filter)
	_refresh_troop_filter_options()

	_list = ItemList.new()
	# 定长而不是 EXPAND_FILL：左栏在滚动容器里时撑不满，给个能看清十来张卡的高度即可
	# （留够下面的「卡组规则 + 主战者职业 + 兵种」几段，尽量不用滚动就能看全）
	_list.custom_minimum_size = Vector2(0, 190)
	_list.item_selected.connect(_on_item_selected)
	left.add_child(_list)

	var list_btn_row := HBoxContainer.new()
	list_btn_row.add_theme_constant_override("separation", 8)
	left.add_child(list_btn_row)
	var new_btn := Button.new()
	new_btn.text = "新建卡牌"
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.pressed.connect(_on_new_pressed)
	list_btn_row.add_child(new_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_delete_pressed)
	list_btn_row.add_child(del_btn)

	_build_deck_rules(left)
	_build_format_rules(left)
	_build_hero_class_manager(left)
	_build_troop_manager(left)
	_build_pack_manager(left)
	_build_ability_pool_manager(left)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 8)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 表单放进**滚动容器**：窗口/屏幕再小也能滚到每一个字段（以前放不下时
	# 底部控件会被裁到窗口之外，「保存」按钮因此完全看不见）。
	var form_scroll := ScrollContainer.new()
	form_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	form_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(form_scroll)
	form_scroll.add_child(right)
	_form_scroll = form_scroll
	_form = right

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	right.add_child(grid)

	_id_edit = LineEdit.new()
	_id_edit.editable = false
	_add_row(grid, "卡牌 ID", _id_edit)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "必填"
	_add_row(grid, "卡牌名称", _name_edit)

	_cost_spin = _make_spin(0, 10, 1)
	_add_row(grid, "费用", _cost_spin)

	_type_option = OptionButton.new()
	for t in CardData.TYPE_NAMES:
		_type_option.add_item(t)
	_type_option.item_selected.connect(func(_i: int) -> void:
		_refresh_trigger_event_options()
		_refresh_effect_contexts()
		_update_preview())
	_add_row(grid, "类型", _type_option)

	_rarity_option = OptionButton.new()
	for r in CardData.RARITY_NAMES:
		_rarity_option.add_item(r)
	_rarity_option.tooltip_text = "必选项：决定同名卡默认携带上限（传说=1，其余=全局同名上限）"
	_add_row(grid, "稀有度（必选）", _rarity_option)

	_copies_spin = _make_spin(0, CardDB.MAX_COPIES_LIMIT, 1)
	_copies_spin.value = 0
	_copies_spin.tooltip_text = "这张牌组里最多带几张：0 = 自动（传说 1 / 其余走全局同名上限），>0 = 给这张卡单独设上限"
	_add_row(grid, "携带上限", _copies_spin)

	# 主战者职业：中立 + 管理员添加的所有职业（选项随职业表刷新，见 _refresh_class_options）
	_card_class_option = OptionButton.new()
	_card_class_option.fit_to_longest_item = false
	_add_row(grid, "主战者职业", _card_class_option)
	_refresh_class_options()

	# 兵种：**先在下面的「兵种」面板里建，这里才选得到**（选项随兵种表刷新）
	_card_troop_option = OptionButton.new()
	_card_troop_option.fit_to_longest_item = false
	_card_troop_option.tooltip_text = "单位分类（影之诗的 士兵 / 指挥官 那类）：可被检索，也能当效果链条件"
	_add_row(grid, "兵种", _card_troop_option)
	_refresh_card_troop_options()

	# 卡包：**先在下面的「卡包」面板里建，这里才选得到**（没选 = 基础卡包）
	_card_pack_option = OptionButton.new()
	_card_pack_option.fit_to_longest_item = false
	_card_pack_option.tooltip_text = "这张卡属于哪个卡包：「指定」模式只用管理员勾选的卡包；没选 = 基础卡包"
	_add_row(grid, "卡包", _card_pack_option)
	_refresh_card_pack_options()

	_attack_spin = _make_spin(0, 30, 1)
	_add_row(grid, "攻击力（随从）", _attack_spin)

	_health_spin = _make_spin(0, 30, 1)
	_add_row(grid, "生命值（随从）", _health_spin)

	_color_picker = ColorPickerButton.new()
	_color_picker.custom_minimum_size = Vector2(120, 0)
	_add_row(grid, "卡面颜色", _color_picker)

	# ---- 效果链（战吼 / 法术 / 安放）：多段效果按顺序结算 ----
	_battlecry_editor = ChainEditor.new()
	right.add_child(_battlecry_editor)
	_battlecry_editor.setup("战吼 / 法术 / 安放（多条效果按顺序结算）", "＋ 添加效果", _update_preview)

	# ---- 亡语链：同一套组件 ----
	_death_editor = ChainEditor.new()
	right.add_child(_death_editor)
	_death_editor.setup("谢幕 / 亡语（死亡时结算，多条按顺序）", "＋ 添加谢幕效果", _update_preview)

	# ---- 主动技能 ----
	_build_skill_editor(right)

	# ---- 瞬念召唤 ----
	_build_invoke_editor(right)

	# ---- 融合（手牌里融合） ----
	_build_fusion_editor(right)

	# ---- 主战者效果（照影之诗一代：卡牌给主战者挂全局 / 限时效果） ----
	_build_leader_editor(right)

	# ---- 卡牌触发效果（入场 / 召唤 / 离场 / 瞬念召唤 / 消失 / 回合开始·结束） ----
	_build_trigger_editor(right)

	_effect_preview = Label.new()
	_effect_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effect_preview.add_theme_color_override("font_color", Color("#ffe082"))
	right.add_child(_effect_preview)

	right.add_child(_make_label("关键字"))
	var keyword_row := HBoxContainer.new()
	keyword_row.add_theme_constant_override("separation", 12)
	right.add_child(keyword_row)
	for k in CardData.KEYWORD_NAMES:
		var cb := CheckBox.new()
		cb.text = CardData.KEYWORD_NAMES[k]
		keyword_row.add_child(cb)
		_keyword_checks[k] = cb

	var token_row := HBoxContainer.new()
	right.add_child(token_row)
	_token_check = CheckBox.new()
	_token_check.text = "衍生物（不进入玩家牌库，仅供召唤使用）"
	token_row.add_child(_token_check)

	right.add_child(_make_label("效果描述"))
	_desc_edit = TextEdit.new()
	_desc_edit.custom_minimum_size = Vector2(0, 90)
	_desc_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_desc_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_desc_edit)

	# 「保存」放在**根 VBox 的最后**（不在滚动区里）：无论表单多高、窗口多小，
	# 它和状态栏都钉在窗口底部一直可见——用户反馈的「没有保存选项」就是它被裁到窗口外了。
	var save_row := HBoxContainer.new()
	save_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(save_row)
	_save_button = Button.new()
	_save_button.text = "保存"
	_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_save_button.tooltip_text = "把当前表单写入卡表（新建模式下会生成卡牌 ID）"
	_save_button.pressed.connect(_on_save_pressed)
	save_row.add_child(_save_button)
	var reset_btn := Button.new()
	reset_btn.text = "恢复默认卡表"
	reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_btn.pressed.connect(_on_reset_pressed)
	save_row.add_child(reset_btn)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root_vbox.add_child(_status_label)


## 主动技能编辑器：勾选「启用主动技能」后才展开
## （名称 / 能量点费用 / 技能目标 / 每回合一次 / 技能自己的效果链）。
func _build_skill_editor(parent: VBoxContainer) -> void:
	_skill_check = CheckBox.new()
	_skill_check.text = "启用主动技能（随从 / 护符 / 城邦）"
	_skill_check.toggled.connect(_on_skill_toggled)
	parent.add_child(_skill_check)

	_skill_box = VBoxContainer.new()
	_skill_box.add_theme_constant_override("separation", 4)
	_skill_box.visible = false
	parent.add_child(_skill_box)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	_skill_box.add_child(grid)

	_skill_name_edit = LineEdit.new()
	_skill_name_edit.placeholder_text = "技能名称（如 秘法冲击）"
	_skill_name_edit.text_changed.connect(func(_t: String) -> void: _update_preview())
	_add_row(grid, "技能名称", _skill_name_edit)

	_skill_cost_spin = _make_spin(0, GameManager.MAX_MANA, 1)
	_skill_cost_spin.value = 1
	# PP 上限本来就是 10（回合开始 +1、封顶 10），所以可指定 0–10；0 = 免费技能
	_skill_cost_spin.tooltip_text = "发动这个技能要花掉多少 PP（= 法力 / 能量点），0 = 免费技能"
	_skill_cost_spin.value_changed.connect(func(_v: float) -> void: _update_preview())
	_add_row(grid, "技能花费（PP）", _skill_cost_spin)

	_skill_target_option = OptionButton.new()
	for i in CardData.TARGET_NAMES.size():
		_skill_target_option.add_item(CardData.TARGET_NAMES[i])
	_skill_target_option.item_selected.connect(_on_skill_target_selected)
	_add_row(grid, "技能目标", _skill_target_option)

	_skill_once_check = CheckBox.new()
	_skill_once_check.text = "每回合一次"
	_skill_once_check.button_pressed = true
	_skill_once_check.toggled.connect(func(_p: bool) -> void: _update_preview())
	_skill_box.add_child(_skill_once_check)

	var hint := _make_label("PP = 法力（能量点），发动时由主战者支付；0 = 免费技能")
	hint.add_theme_color_override("font_color", Color("#90caf9"))
	_skill_box.add_child(hint)

	_skill_editor = ChainEditor.new()
	_skill_box.add_child(_skill_editor)
	_skill_editor.setup("技能效果链（多条效果按顺序结算）", "＋ 添加技能效果", _on_skill_changed)


## 瞬念召唤编辑器：卡片**自己**在牌库里满足条件时自动上场。
## 条件是 InvokeConditions 注册的一条（下拉框随注册表自动出现新条件），
## 触发时机决定它在自己回合的哪些检查点被判定：**任意时机** / 我方回合开始 / 我方回合结束。
## 瞬念召唤只在这一方自己的回合结算（对面在动的时候不会被拉出来），所以没有「对手回合」的选项。
func _build_invoke_editor(parent: VBoxContainer) -> void:
	_invoke_check = CheckBox.new()
	_invoke_check.text = "启用瞬念召唤（这张卡在牌库里满足条件时自动上场）"
	_invoke_check.tooltip_text = "它不是战吼：应召上场不结算入场效果；同名卡每个回合只应召一次"
	_invoke_check.toggled.connect(_on_invoke_toggled)
	parent.add_child(_invoke_check)

	_invoke_box = VBoxContainer.new()
	_invoke_box.add_theme_constant_override("separation", 4)
	_invoke_box.visible = false
	parent.add_child(_invoke_box)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	_invoke_box.add_child(grid)

	# 条件 = 「读一个量」+「一个比较符」+「阈值」（与 SV 的 SkillConditionXxx +
	# SkillCompareFuncCreator 同一套模型）：N 个量 × 6 个比较符，不用为每种比法单开一个 ID。
	_invoke_metric_option = OptionButton.new()
	_invoke_metric_option.add_item("（未选择）")
	for mid in InvokeConditions.metrics():
		_invoke_metric_option.add_item(InvokeConditions.metric_label(mid))
		_invoke_metric_option.set_item_metadata(_invoke_metric_option.item_count - 1, mid)
	_invoke_metric_option.tooltip_text = "看哪一个量（随从数 / 生命 / 手牌 / 已打出的牌… / 某兵种的张数）"
	_invoke_metric_option.item_selected.connect(_on_invoke_metric_selected)
	_add_row(grid, "触发条件", _invoke_metric_option)

	# 条件兵种：只有「兵种类量」才显示（兵种由左侧「兵种」面板创建，含内置「中立」）
	_invoke_troop_label = _make_label("条件兵种")
	_invoke_troop_label.visible = false
	grid.add_child(_invoke_troop_label)
	_invoke_troop_option = OptionButton.new()
	_invoke_troop_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var iti := 0
	for e in CardDB.troops:
		var itid := str(e.get("id", ""))
		_invoke_troop_option.add_item(str(e.get("name", itid)))
		_invoke_troop_option.set_item_metadata(iti, itid)
		iti += 1
	if _invoke_troop_option.item_count == 0:
		_invoke_troop_option.add_item(CardData.NEUTRAL_TROOP_NAME)
		_invoke_troop_option.set_item_metadata(0, CardData.NEUTRAL_TROOP)
	_invoke_troop_option.tooltip_text = "这个条件看哪个兵种（「本局该兵种进场数」这类量才用得上）"
	_invoke_troop_option.visible = false
	_invoke_troop_option.item_selected.connect(func(_i: int) -> void: _update_preview())
	grid.add_child(_invoke_troop_option)

	_invoke_op_option = OptionButton.new()
	for o in InvokeConditions.OPS:
		_invoke_op_option.add_item(o)
	_invoke_op_option.tooltip_text = "这个量和阈值的比法"
	_invoke_op_option.item_selected.connect(func(_i: int) -> void: _update_preview())
	_add_row(grid, "比较符", _invoke_op_option)

	_invoke_value_spin = _make_spin(0, 30, 1)
	_invoke_value_spin.value_changed.connect(func(_v: float) -> void: _update_preview())
	_add_row(grid, "阈值", _invoke_value_spin)

	_invoke_timing_option = OptionButton.new()
	for t in InvokeConditions.TIME_NAMES:
		_invoke_timing_option.add_item(t)
	_invoke_timing_option.tooltip_text = "在哪些检查点替它判定"
	_invoke_timing_option.item_selected.connect(func(_i: int) -> void: _update_preview())
	_add_row(grid, "触发时机", _invoke_timing_option)

	# 基础机制（去向）：**必选**，不能为空 —— 应召并结算完瞬念召唤效果之后这张卡留在哪
	_invoke_dest_option = OptionButton.new()
	for d in CardData.INVOKE_DEST_NAMES:
		_invoke_dest_option.add_item(d)
	_invoke_dest_option.tooltip_text = "必选项：应召上场并结算完「瞬念召唤效果」之后，这张卡留在场上 / 返回手牌 / 进入墓地（或由玩家选择）"
	_invoke_dest_option.item_selected.connect(func(_i: int) -> void: _update_preview())
	_add_row(grid, "基础机制（去向）", _invoke_dest_option)

	# 瞬念召唤效果（可留空）：与战吼 / 亡语完全独立的一条效果链，效果结算完再走基础机制
	_invoke_editor = ChainEditor.new()
	_invoke_box.add_child(_invoke_editor)
	_invoke_editor.setup("瞬念召唤效果（可留空；与战吼 / 亡语独立，结算完再执行基础机制）",
		"＋ 添加瞬念召唤效果", _update_preview)

	var hint := _make_label("同名卡（同一个卡 id）的瞬念召唤**每个回合只结算一次**；它不是战吼，应召上场不结算入场效果。\n"
		+ "**没有空置格时它「消失」**（从游戏中移除）；有空置格 → 上场 → 结算上面的效果 → 再执行「基础机制（去向）」。")
	hint.add_theme_color_override("font_color", Color("#90caf9"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_invoke_box.add_child(hint)


func _on_invoke_toggled(pressed: bool) -> void:
	if _invoke_box != null:
		_invoke_box.visible = pressed
	_update_preview()


## 换条件时给一个合理的默认比较符（不是每次都让人重挑一遍比法）
func _on_invoke_metric_selected(_index: int) -> void:
	if _invoke_metric_option.selected > 0:
		var mid := str(_invoke_metric_option.get_item_metadata(_invoke_metric_option.selected))
		var op := InvokeConditions.default_op(mid)
		var idx := InvokeConditions.OPS.find(op)
		if idx >= 0:
			_invoke_op_option.selected = idx
	_sync_invoke_troop_row()
	_update_preview()


## 「条件兵种」整行只在兵种类量时出现（普通量留着一个选不动的兵种框只会让人困惑）
func _sync_invoke_troop_row() -> void:
	var want := false
	if _invoke_metric_option != null and _invoke_metric_option.selected > 0:
		want = InvokeConditions.metric_wants_troop(
			str(_invoke_metric_option.get_item_metadata(_invoke_metric_option.selected)))
	if _invoke_troop_label != null:
		_invoke_troop_label.visible = want
	if _invoke_troop_option != null:
		_invoke_troop_option.visible = want


## 表单里的瞬念召唤配置 → 写回用的 Dictionary（没启用 / 没选条件 → 空字典）
func _invoke_map() -> Dictionary:
	if _invoke_check == null or not _invoke_check.button_pressed:
		return {}
	var mid := ""
	if _invoke_metric_option != null and _invoke_metric_option.selected > 0:
		mid = str(_invoke_metric_option.get_item_metadata(_invoke_metric_option.selected))
	var op := ""
	if _invoke_op_option != null and _invoke_op_option.selected >= 0 \
			and _invoke_op_option.selected < InvokeConditions.OPS.size():
		op = InvokeConditions.OPS[_invoke_op_option.selected]
	var fx: Array = []
	if _invoke_editor != null:
		fx = _invoke_editor.chain()
	var dest: int = CardData.InvokeDest.KEEP
	if _invoke_dest_option != null and _invoke_dest_option.selected >= 0 \
			and _invoke_dest_option.selected < CardData.INVOKE_DEST_NAMES.size():
		dest = _invoke_dest_option.selected
	var out := {
		"enabled": true,
		"metric": mid,
		"op": op,
		"value": int(_invoke_value_spin.value) if _invoke_value_spin != null else 0,
		"timing": int(_invoke_timing_option.selected) if _invoke_timing_option != null else 0,
		"effects": fx,
		"destination": dest,
	}
	# 兵种类量才写 troop（别的量不写，免得卡表里留下用不上的键）
	if InvokeConditions.metric_wants_troop(mid) and _invoke_troop_option != null:
		var meta = _invoke_troop_option.get_item_metadata(maxi(0, _invoke_troop_option.selected))
		var troop := "" if meta == null else str(meta)
		out["troop"] = troop if troop != "" else CardData.NEUTRAL_TROOP
	return out
# ------------------------------ 主战者效果（照影之诗一代） ------------------------------
#
# 一张卡可以在某个时机把一条「监听器」挂到主战者身上：
#   赋予时机（入场 / 离场 / 瞬念召唤 / 召唤 / 消失）× 监听事件（回合开始 / 结束 / 打出 / 抽到 / 离场）
#   × 费用过滤 × 持续回合数 × 效果链。
# 这里用「清单 + 选中行编辑」：上面一条清单，下面一排控件 + 一个共享的效果链编辑器。

func _build_leader_editor(parent: VBoxContainer) -> void:
	var title := _make_label("主战者效果（卡牌在某个时机给主战者挂全局 / 限时效果）")
	title.add_theme_color_override("font_color", Color("#ff8a65"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(title)

	_leader_list = ItemList.new()
	_leader_list.custom_minimum_size = Vector2(0, 72)
	_leader_list.item_selected.connect(_on_leader_selected)
	parent.add_child(_leader_list)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)

	_leader_grant_option = OptionButton.new()
	for g in LeaderEffects.grant_ids():
		_leader_grant_option.add_item(LeaderEffects.grant_label(g))
		_leader_grant_option.set_item_metadata(_leader_grant_option.item_count - 1, g)
	_leader_grant_option.tooltip_text = "这张卡在哪一刻把效果挂给主战者"
	_leader_grant_option.item_selected.connect(func(_i: int) -> void: _on_leader_edited())
	_add_row(grid, "赋予时机", _leader_grant_option)

	_leader_target_option = OptionButton.new()
	for t in LeaderEffects.targets():
		_leader_target_option.add_item(str(t))
	_leader_target_option.tooltip_text = "挂到自己还是对手的主战者身上"
	_leader_target_option.item_selected.connect(func(_i: int) -> void: _on_leader_edited())
	_add_row(grid, "赋予目标", _leader_target_option)

	_leader_event_option = OptionButton.new()
	for e in LeaderEffects.event_ids():
		_leader_event_option.add_item(LeaderEffects.event_label(e))
		_leader_event_option.set_item_metadata(_leader_event_option.item_count - 1, e)
	_leader_event_option.tooltip_text = "挂上之后，主战者在什么时刻结算它"
	_leader_event_option.item_selected.connect(func(_i: int) -> void: _on_leader_edited())
	_add_row(grid, "监听事件", _leader_event_option)

	_leader_cost_spin = _make_spin(-1, 30, 1)
	_leader_cost_spin.tooltip_text = "费用过滤：-1 = 任意；>=0 只在该费用的卡发生上面的事件时触发"
	_leader_cost_spin.value_changed.connect(func(_v: float) -> void: _on_leader_edited())
	_add_row(grid, "费用过滤", _leader_cost_spin)

	_leader_turns_spin = _make_spin(0, 10, 1)
	_leader_turns_spin.tooltip_text = "持续回合数：0 = 本局永久；N = 该主战者再过 N 个自己的回合后失效"
	_leader_turns_spin.value_changed.connect(func(_v: float) -> void: _on_leader_edited())
	_add_row(grid, "持续回合", _leader_turns_spin)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	parent.add_child(btns)
	var add_btn := Button.new()
	add_btn.text = "＋ 新增主战者效果"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(_on_leader_add)
	btns.add_child(add_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_leader_remove)
	btns.add_child(del_btn)

	_leader_editor = ChainEditor.new()
	parent.add_child(_leader_editor)
	_leader_editor.setup("这条主战者效果的效果链（事件发生时按顺序结算）", "＋ 添加效果", _on_leader_edited)

	var hint := _make_label("例：赋予时机「入场（打出）」+ 监听「我方回合开始时」+ 效果「抽 1 张」+ 持续 3 回合\n"
		+ "= 这张卡打出后，我方接下来 3 个回合开始时各抽一张（持续 0 = 本局永久）。\n"
		+ "带费用的监听（打出 / 抽到 / 离场）只对「费用 == 费用过滤」的那张卡生效，-1 = 任意费用。")
	hint.add_theme_color_override("font_color", Color("#90caf9"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(hint)

	_refresh_leader_list()
	_leader_load_row()


func _refresh_leader_list() -> void:
	if _leader_list == null:
		return
	_leader_list.clear()
	for row in _leader_rows:
		var label := LeaderEffects.text(row)
		_leader_list.add_item(label if label != "" else "（空）")
	if _leader_selected >= 0 and _leader_selected < _leader_list.item_count:
		_leader_list.select(_leader_selected)


## 选中某一条 → 先把上一条的改动写回，再回填控件与效果链
func _on_leader_selected(index: int) -> void:
	_leader_flush()
	_leader_selected = index
	_leader_loading = true
	_leader_load_row()
	_leader_loading = false
	_update_preview()


func _leader_load_row() -> void:
	var row: Dictionary = {}
	if _leader_selected >= 0 and _leader_selected < _leader_rows.size():
		row = _leader_rows[_leader_selected]
	var was_loading := _leader_loading
	_leader_loading = true
	_select_option_meta(_leader_grant_option, str(row.get("grant", LeaderEffects.GRANT_PLAY)))
	_select_option_meta(_leader_event_option, str(row.get("on", LeaderEffects.ON_TURN_START)))
	_leader_cost_spin.value = int(row.get("cost", -1))
	_leader_turns_spin.value = int(row.get("turns", 0))
	_leader_target_option.selected = clampi(int(row.get("target", 0)), 0, 1)
	if _leader_editor != null:
		if row.is_empty():
			_leader_editor.clear()
		else:
			_leader_editor.load_chain(row.get("effects", []))
	_leader_loading = was_loading
	_leader_sync_enabled()


## 没选中任何一条时，下面那排控件与效果链都禁用（避免改了却没地方存）
func _leader_sync_enabled() -> void:
	var on := _leader_selected >= 0 and _leader_selected < _leader_rows.size()
	_leader_grant_option.disabled = not on
	_leader_event_option.disabled = not on
	_leader_cost_spin.editable = on
	_leader_turns_spin.editable = on
	_leader_target_option.disabled = not on
	if _leader_editor != null:
		_leader_editor.visible = on


## 控件 / 效果链有改动 → 写回当前行 + 刷新清单文本
func _on_leader_edited() -> void:
	if _leader_loading:
		return
	_leader_flush()
	_refresh_leader_list()
	_update_preview()


func _leader_flush() -> void:
	if _leader_selected < 0 or _leader_selected >= _leader_rows.size():
		return
	_leader_rows[_leader_selected] = {
		"grant": _leader_grant_value(),
		"on": _leader_event_value(),
		"cost": int(_leader_cost_spin.value),
		"turns": int(_leader_turns_spin.value),
		"target": _leader_target_option.selected,
		"effects": _leader_editor.chain() if _leader_editor != null else [],
	}


func _leader_grant_value() -> String:
	if _leader_grant_option == null or _leader_grant_option.selected < 0:
		return LeaderEffects.GRANT_PLAY
	var meta = _leader_grant_option.get_item_metadata(_leader_grant_option.selected)
	return str(meta) if meta != null else LeaderEffects.GRANT_PLAY


func _leader_event_value() -> String:
	if _leader_event_option == null or _leader_event_option.selected < 0:
		return LeaderEffects.ON_TURN_START
	var meta = _leader_event_option.get_item_metadata(_leader_event_option.selected)
	return str(meta) if meta != null else LeaderEffects.ON_TURN_START


func _on_leader_add() -> void:
	_leader_flush()
	_leader_rows.append({
		"grant": LeaderEffects.GRANT_PLAY,
		"on": LeaderEffects.ON_TURN_START,
		"cost": -1,
		"turns": 0,
		"target": 0,
		"effects": [],
	})
	_leader_selected = _leader_rows.size() - 1
	_refresh_leader_list()
	_leader_load_row()
	if _leader_editor != null:
		_leader_editor.add_row()          # 先给一条空效果，直接开始填
	_update_preview()


func _on_leader_remove() -> void:
	if _leader_selected < 0 or _leader_selected >= _leader_rows.size():
		_set_status("请先在上面的清单里选中要删除的主战者效果")
		return
	_leader_rows.remove_at(_leader_selected)
	_leader_selected = clampi(_leader_selected, 0, _leader_rows.size() - 1)
	if _leader_rows.is_empty():
		_leader_selected = -1
	_refresh_leader_list()
	_leader_load_row()
	_update_preview()


## 保存前检查：每条主战者效果的结构 + 它的效果链
func _validate_leader_effects() -> String:
	for i in _leader_rows.size():
		var row: Dictionary = _leader_rows[i]
		var where := "主战者效果第 %d 条" % (i + 1)
		for msg in LeaderEffects.errors(row):
			return "保存失败：%s：%s" % [where, msg]
		var err := _validate_chain(row.get("effects", []), where, true)
		if err != "":
			return err
	return ""


# ------------------------------ 卡牌触发效果（CardTriggers） ------------------------------
#
# 一张卡在某个时机自动结算一条效果链（不需要玩家操作）：
#   入场（打出）/ 召唤入场 / 离场 / 瞬念召唤上场 / 消失 / 我方回合开始 / 我方回合结束。
# 与战吼 / 亡语 / 主战者效果互不冲突，都可以同时配。

func _build_trigger_editor(parent: VBoxContainer) -> void:
	var title := _make_label("触发效果（这张卡在某个时机自动结算一条效果链）")
	title.add_theme_color_override("font_color", Color("#a5d6a7"))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(title)

	_refresh_trigger_event_options()
	_trigger_list = ItemList.new()
	_trigger_list.custom_minimum_size = Vector2(0, 72)
	_trigger_list.item_selected.connect(_on_trigger_selected)
	parent.add_child(_trigger_list)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)

	_trigger_event_option = OptionButton.new()
	_trigger_event_option.tooltip_text = "这张卡在哪一刻自动结算下面这条效果链（按词条大类分组）"
	_trigger_event_option.item_selected.connect(func(_i: int) -> void: _on_trigger_edited())
	_add_row(grid, "触发时机", _trigger_event_option)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 6)
	parent.add_child(btns)
	var add_btn := Button.new()
	add_btn.text = "＋ 新增触发效果"
	add_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_btn.pressed.connect(_on_trigger_add)
	btns.add_child(add_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_trigger_remove)
	btns.add_child(del_btn)

	_trigger_editor = ChainEditor.new()
	parent.add_child(_trigger_editor)
	_trigger_editor.setup("这条触发效果的效果链（时机到了按顺序结算）", "＋ 添加效果", _on_trigger_edited)

	var hint := _make_label("例：时机「召唤入场时」+ 效果「抽 1 张」= 这张卡被召唤上场时抽一张。\n"
		+ "「入场（打出）」只在从手牌打出时结算；「召唤入场」管衍生物 / 复制 / 亡语召唤 / 效果召唤。\n"
		+ "「离场」= 死亡 / 回手 / 进墓地；「消失」= 没有空置格时从游戏中移除。\n"
		+ "「我方回合开始 / 结束」只在这张卡留在场上时结算。")
	hint.add_theme_color_override("font_color", Color("#90caf9"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(hint)

	_refresh_trigger_list()
	_trigger_load_row()


## 触发时机的下拉：按词条大类显示；法术卡只留「瞬念召唤 / 被召唤」两个大类。
## 旧卡表里法术配了别的时机时，仍保留一个「[非法]」项，方便管理员看到并改掉。
func _refresh_trigger_event_options() -> void:
	if _trigger_event_option == null:
		return
	var keep := _trigger_event_value()
	_trigger_event_option.clear()
	var spell := _type_option != null and _type_option.selected == CardData.CardType.SPELL
	# 「非法」旧值只在**确实有触发条目在用**时保留；新建卡 / 切换类型时不要凭空多一项
	var keep_in_use := false
	for row in _trigger_rows:
		if str(row.get("on", "")) == keep:
			keep_in_use = true
			break
	var kept := false
	for e in CardTriggers.event_ids():
		if spell and not CardTriggers.spell_event_allowed(e):
			if e != keep or not keep_in_use:
				continue
			_trigger_event_option.add_item("[非法] " + CardTriggers.dropdown_label(e))
			_trigger_event_option.set_item_metadata(_trigger_event_option.item_count - 1, e)
			kept = true
			continue
		_trigger_event_option.add_item(CardTriggers.dropdown_label(e))
		_trigger_event_option.set_item_metadata(_trigger_event_option.item_count - 1, e)
		if e == keep:
			kept = true
	if not kept:
		_trigger_event_option.select(0)


## 让各条链知道自己的时机：入场 / 谢幕 / 融合 里「复制本随从」等效果会标红提示。
## 触发链的时机逐行不同，由 _trigger_load_row 单独设置。
func _refresh_effect_contexts() -> void:
	if _battlecry_editor != null:
		_battlecry_editor.set_warning_context(
			"play_spell" if _type_option.selected == CardData.CardType.SPELL else "play")
	if _death_editor != null:
		_death_editor.set_warning_context("deathrattle")
	if _fusion_editor != null:
		_fusion_editor.set_warning_context("fusion")
	if _fusion_gain_editor != null:
		_fusion_gain_editor.set_warning_context("fusion")


func _refresh_trigger_list() -> void:
	if _trigger_list == null:
		return
	_trigger_list.clear()
	for row in _trigger_rows:
		var label := CardTriggers.text(row)
		_trigger_list.add_item(label if label != "" else "（空）")
	if _trigger_selected >= 0 and _trigger_selected < _trigger_list.item_count:
		_trigger_list.select(_trigger_selected)


## 选中某一条 → 先把上一条的改动写回，再回填控件与效果链
func _on_trigger_selected(index: int) -> void:
	_trigger_flush()
	_trigger_selected = index
	_trigger_loading = true
	_trigger_load_row()
	_trigger_loading = false
	_update_preview()


func _trigger_load_row() -> void:
	var row: Dictionary = {}
	if _trigger_selected >= 0 and _trigger_selected < _trigger_rows.size():
		row = _trigger_rows[_trigger_selected]
	var was_loading := _trigger_loading
	_trigger_loading = true
	_select_option_meta(_trigger_event_option, str(row.get("on", CardTriggers.EV_PLAY)))
	if _trigger_editor != null:
		if row.is_empty():
			_trigger_editor.clear()
		else:
			_trigger_editor.load_chain(row.get("effects", []))
		# 这一条触发链的时机：用来判断哪些效果在这时一定失效（行内标红，不自动删）
		_trigger_editor.set_warning_context("" if row.is_empty() else _trigger_event_value())
	_trigger_loading = was_loading
	_trigger_sync_enabled()


## 没选中任何一条时，时机下拉与效果链都禁用（避免改了却没地方存）
func _trigger_sync_enabled() -> void:
	var on := _trigger_selected >= 0 and _trigger_selected < _trigger_rows.size()
	_trigger_event_option.disabled = not on
	if _trigger_editor != null:
		_trigger_editor.visible = on


## 控件 / 效果链有改动 → 写回当前行 + 刷新清单文本
func _on_trigger_edited() -> void:
	if _trigger_loading:
		return
	_trigger_flush()
	# 改时机 / 改效果后立刻重算这一行的红色提示（例如把「复制本随从」配到离场时机）
	if _trigger_editor != null:
		_trigger_editor.set_warning_context(_trigger_event_value())
	_refresh_trigger_list()
	_update_preview()


func _trigger_flush() -> void:
	if _trigger_selected < 0 or _trigger_selected >= _trigger_rows.size():
		return
	_trigger_rows[_trigger_selected] = {
		"on": _trigger_event_value(),
		"effects": _trigger_editor.chain() if _trigger_editor != null else [],
	}


func _trigger_event_value() -> String:
	if _trigger_event_option == null or _trigger_event_option.selected < 0:
		return CardTriggers.EV_PLAY
	var meta = _trigger_event_option.get_item_metadata(_trigger_event_option.selected)
	return str(meta) if meta != null else CardTriggers.EV_PLAY


func _on_trigger_add() -> void:
	_trigger_flush()
	_trigger_rows.append({"on": CardTriggers.EV_PLAY, "effects": []})
	_trigger_selected = _trigger_rows.size() - 1
	_refresh_trigger_list()
	_trigger_load_row()
	if _trigger_editor != null:
		_trigger_editor.add_row()          # 先给一条空效果，直接开始填
	_update_preview()


func _on_trigger_remove() -> void:
	if _trigger_selected < 0 or _trigger_selected >= _trigger_rows.size():
		_set_status("请先在上面的清单里选中要删除的触发效果")
		return
	_trigger_rows.remove_at(_trigger_selected)
	_trigger_selected = clampi(_trigger_selected, 0, _trigger_rows.size() - 1)
	if _trigger_rows.is_empty():
		_trigger_selected = -1
	_refresh_trigger_list()
	_trigger_load_row()
	_update_preview()


## 保存前检查：每条触发效果的时机 + 它的效果链（目标与亡语同一口径：触发时自动推导）
func _validate_triggers() -> String:
	for i in _trigger_rows.size():
		var row: Dictionary = _trigger_rows[i]
		var where := "触发效果第 %d 条" % (i + 1)
		if _type_option.selected == CardData.CardType.SPELL \
				and not CardTriggers.spell_event_allowed(str(row.get("on", ""))):
			return "保存失败：%s：法术卡只能配「瞬念召唤 / 被召唤」两个词条大类" % where
		for msg in CardTriggers.errors(row):
			return "保存失败：%s：%s" % [where, msg]
		var err := _validate_chain(row.get("effects", []), where, false)
		if err != "":
			return err
	return ""


func _shortcut_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_S and event.ctrl_pressed:
		_on_save_pressed()
		get_viewport().set_input_as_handled()


func _add_row(grid: GridContainer, text: String, control: Control) -> void:
	grid.add_child(_make_label(text))
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)


func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _make_spin(min_value: float, max_value: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = step
	return s


# ------------------------------ 列表与表单 ------------------------------

func _refresh_list() -> void:
	if _list == null:
		return
	var query := _list_search.text if _list_search != null else ""
	var troop_filter := _selected_filter_troop()
	_list.clear()
	var shown := 0
	for c in CardDB.cards:
		if not CardDB.card_matches(c, query, -1, troop_filter):
			continue
		var label: String = "%s　[%s·%s] %d 费" % [c.card_name, c.rarity_name(), c.type_name(), c.cost]
		if c.is_minion():
			label += " %d/%d" % [c.attack, c.health]
		elif c.is_permanent():
			label += " 耐久 %d" % c.durability()
		if c.is_token:
			label += "（衍生物）"
		elif CardDB.card_class_of(c) != CardData.NEUTRAL_CLASS:
			label += "·%s" % CardDB.hero_class_name(CardDB.card_class_of(c))
		var tid := CardDB.troop_of(c)
		if tid != "":
			label += "·%s" % CardDB.troop_name(tid)
		var pid := CardDB.pack_of(c)
		if pid != CardDB.DEFAULT_PACK:
			label += "·%s" % CardDB.pack_name(pid)
		var idx := _list.add_item(label)
		_list.set_item_metadata(idx, c.id)
		shown += 1
	var head := "卡牌列表（共 %d 张，其中衍生物 %d 张，城邦 %d 种 / 每套牌组最多带 %d 张）" % [
		CardDB.cards.size(), CardDB.token_count(), CardDB.city_card_count(), CardData.CITY_DECK_LIMIT]
	if query.strip_edges() != "" or troop_filter != "":
		head = "检索到 %d / %d 张　" % [shown, CardDB.cards.size()] + head
	_count_label.text = head


func _on_item_selected(index: int) -> void:
	var id := str(_list.get_item_metadata(index))
	var c := CardDB.get_card(id)
	if c != null:
		_load_card(c)


func _load_card(c: CardData) -> void:
	_is_new = false
	_id_edit.text = c.id
	_name_edit.text = c.card_name
	# 卡表可能来自手改 JSON，数值可能超出编辑器默认上限：
	# 不放宽上限的话，“选中一下就保存”会把 12 费 / 40 攻静默改成 10 / 30
	_cost_spin.max_value = maxf(10.0, float(c.cost))
	_cost_spin.value = c.cost
	_type_option.selected = c.card_type
	_rarity_option.selected = clampi(c.rarity, 0, CardData.RARITY_NAMES.size() - 1)
	_copies_spin.value = clampi(c.deck_limit, 0, CardDB.MAX_COPIES_LIMIT)
	# 职业：没登记的职业 id（管理员删了）统一按中立显示
	_select_card_class(CardDB.card_class_of(c))
	# 兵种：没登记的兵种 id（管理员删了）统一按「中立」显示
	_select_card_troop(CardDB.troop_of(c))
	# 卡包：没指定 / 卡包被删了 → 显示基础卡包
	_select_card_pack(CardDB.pack_of(c))
	_attack_spin.max_value = maxf(30.0, float(c.attack))
	_attack_spin.value = c.attack
	_health_spin.max_value = maxf(30.0, float(c.health))
	_health_spin.value = c.health
	# 效果链 / 亡语链：老卡（只有 effect_id / value / target）由 effect_chain() 回落成一条，
	# 保存时会照旧写出一条 effects（兼容性由规则层保证，面板只负责显示与顺序）。
	_battlecry_editor.load_chain(c.effect_chain())
	_death_editor.load_chain(c.deathrattle_chain())
	_load_skill(c)
	_load_invoke(c)
	_load_fusion(c)
	_load_leader_effects(c)
	_load_triggers(c)
	_refresh_effect_contexts()
	_update_preview()
	_token_check.button_pressed = c.is_token
	for k in _keyword_checks:
		var cb: CheckBox = _keyword_checks[k]
		cb.button_pressed = c.keywords.has(k)
	_desc_edit.text = c.description
	_color_picker.color = c.color
	_set_status("正在编辑：%s" % c.card_name)


func _new_card() -> void:
	_is_new = true
	_list.deselect_all()
	_id_edit.text = "（保存时自动生成）"
	_name_edit.text = ""
	# 恢复编辑器默认上限，避免上一次编辑把上限放宽后一直留着
	_cost_spin.max_value = 10.0
	_cost_spin.value = 1
	_type_option.selected = CardData.CardType.MINION
	_rarity_option.selected = CardData.Rarity.COMMON   # 新卡默认普通稀有度
	_copies_spin.value = 0                              # 新卡默认「自动」按稀有度
	_select_card_class(CardData.NEUTRAL_CLASS)     # 新卡默认中立：任何主战者都能带
	_select_card_troop("")                          # 新卡默认中立（要别的兵种先到「兵种」面板建）
	_select_card_pack(CardDB.DEFAULT_PACK)          # 新卡默认基础卡包（要别的包先到「卡包」面板建）
	_attack_spin.max_value = 30.0
	_attack_spin.value = 2
	_health_spin.max_value = 30.0
	_health_spin.value = 2
	_battlecry_editor.clear()
	_death_editor.clear()
	_skill_ui_loading = true
	_skill_check.button_pressed = false
	_skill_box.visible = false
	_skill_name_edit.text = ""
	_skill_cost_spin.value = 1
	_skill_target_option.selected = CardData.Targeting.NONE
	_skill_once_check.button_pressed = true
	_skill_target_touched = false
	_skill_ui_loading = false
	_skill_editor.clear()
	_load_invoke(CardData.new())
	_load_fusion(CardData.new())
	_load_leader_effects(CardData.new())
	_load_triggers(CardData.new())
	_refresh_effect_contexts()
	_token_check.button_pressed = false
	for k in _keyword_checks:
		var cb: CheckBox = _keyword_checks[k]
		cb.button_pressed = false
	_desc_edit.text = ""
	_color_picker.color = Color("#ffb74d")
	_update_preview()
	_set_status("新建模式：填写后点击「保存」")


# ------------------------------ 主动技能 ------------------------------

func _load_skill(c: CardData) -> void:
	var on: bool = c.has_skill()
	# 回填期间不把赋值当成「管理员选择」：技能链里的目标变了仍然自动跟随
	_skill_ui_loading = true
	_skill_target_touched = false
	_skill_check.button_pressed = on
	_skill_box.visible = on
	if on:
		_skill_name_edit.text = c.skill_name()
		_skill_cost_spin.value = clampi(c.skill_cost(), 0, 10)
		_skill_target_option.selected = clampi(c.skill_target(), 0, CardData.TARGET_NAMES.size() - 1)
		_skill_once_check.button_pressed = c.skill_once_per_turn()
	else:
		_skill_name_edit.text = ""
		_skill_cost_spin.value = 1
		_skill_target_option.selected = CardData.Targeting.NONE
		_skill_once_check.button_pressed = true
	_skill_ui_loading = false
	if on:
		_skill_editor.load_chain(c.skill_chain())
	else:
		_skill_editor.clear()


func _on_skill_toggled(pressed: bool) -> void:
	if _skill_box != null:
		_skill_box.visible = pressed
	_update_preview()


## 管理员自己选过技能目标之后，链变化不再覆盖它
func _on_skill_target_selected(_index: int) -> void:
	if not _skill_ui_loading:
		_skill_target_touched = true
	_update_preview()


## 技能链变化：技能目标没被显式选过时，自动跟随技能链里第一条需要选目标的效果，
## 避免出现「技能目标与技能链不一致」的配置错误（与 CardDB 的配置自检同一口径）。
func _on_skill_changed() -> void:
	if not _skill_target_touched and _skill_target_option != null:
		var need := _first_need_target(_skill_editor.chain())
		if need != CardData.Targeting.NONE:
			# 自动带入不算「管理员选择」（Godot 里给 OptionButton.selected 赋值的信号行为
			# 各版本不一致，这里显式挡住，免得自动带入一次之后就不再跟随）
			_skill_ui_loading = true
			_skill_target_option.selected = need
			_skill_ui_loading = false
	_update_preview()


## 主动技能字典（{} = 没有技能）；键与契约一致：name / cost / target / once_per_turn / effects
func _skill_map() -> Dictionary:
	if _skill_check == null or not _skill_check.button_pressed:
		return {}
	return {
		"name": _skill_name_edit.text.strip_edges(),
		"cost": int(_skill_cost_spin.value),
		"target": _skill_target_option.selected,
		"once_per_turn": _skill_once_check.button_pressed,
		"effects": _skill_editor.chain(),
	}


## 卡组规则（全局）：卡组最少/最多张数 + 同名卡最大携带数。
## 这三项决定 `CardDB.build_deck()` 生成的牌库，改完立刻生效并写进 user://deck_rules.cfg。
func _build_deck_rules(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	var title := _make_label("卡组规则（全局）")
	title.add_theme_color_override("font_color", Color("#ffcc80"))
	box.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	_deck_min_spin = _make_spin(1, 999, 1)
	_deck_min_spin.value = CardDB.deck_min
	_add_row(grid, "卡组最少张数", _deck_min_spin)
	_deck_max_spin = _make_spin(1, 999, 1)
	_deck_max_spin.value = CardDB.deck_max
	_add_row(grid, "卡组最多张数", _deck_max_spin)
	_deck_copies_spin = _make_spin(1, CardDB.MAX_COPIES_LIMIT, 1)
	_deck_copies_spin.value = CardDB.max_copies
	_add_row(grid, "同名卡最大携带", _deck_copies_spin)

	# 种类上限：每张牌组里「某一种类」卡的总携带数（0 = 不限），如「法术最多 30 张」
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		var sp := _make_spin(0, CardDB.TYPE_CAP_LIMIT, 1)
		sp.value = int(CardDB.type_cap(t))
		sp.tooltip_text = "每张牌组里「%s」类卡最多带几张（0 = 不限）" % CardData.TYPE_NAMES[t]
		_type_cap_spins[t] = sp
		_add_row(grid, "%s最多带" % CardData.TYPE_NAMES[t], sp)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	_deck_apply_button = Button.new()
	_deck_apply_button.text = "应用卡组规则"
	_deck_apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_deck_apply_button.pressed.connect(_on_apply_deck_rules)
	row.add_child(_deck_apply_button)
	var reset_btn := Button.new()
	reset_btn.text = "恢复默认"
	reset_btn.pressed.connect(_on_reset_deck_rules)
	row.add_child(reset_btn)

	_deck_rules_label = _make_label("")
	_deck_rules_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_deck_rules_label.add_theme_font_size_override("font_size", 12)
	_deck_rules_label.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(_deck_rules_label)
	_refresh_deck_rules_label()


## 把「当前规则 → 实际生成的牌库张数 + 自检告警」写到说明标签里
func _refresh_deck_rules_label() -> void:
	if _deck_rules_label == null:
		return
	var size_now: int = CardDB.build_deck().size()
	var text := "当前生成 %d 张 · 卡池 %d 种 · 区间 %d–%d 张" % [
		size_now, CardDB.collectible_card_count(), CardDB.deck_min, CardDB.deck_max]
	var warns: Array[String] = CardDB.deck_rules_report()
	if not warns.is_empty():
		text += "\n⚠ " + "\n⚠ ".join(warns)
	text += "\n种类上限：" + CardDB._type_caps_text()
	_deck_rules_label.text = text


## 「应用卡组规则」：非法值只提示、不落盘（坏配置绝不生效）
func _on_apply_deck_rules() -> void:
	var want_min := int(_deck_min_spin.value)
	var want_max := int(_deck_max_spin.value)
	var want_copies := int(_deck_copies_spin.value)
	if not CardDB.rules_valid(want_min, want_max, want_copies):
		_set_status("卡组规则不合法：最少不能大于最多、张数与同名携带数都要 ≥ 1（同名最多 %d 张）" % CardDB.MAX_COPIES_LIMIT)
		return
	if not CardDB.set_deck_rules(want_min, want_max, want_copies):
		_set_status("卡组规则保存失败（写入 user://deck_rules.cfg 出错）")
		return
	# 种类上限：每张牌组里某一种类卡的总携带数（0 = 不限）
	var caps: Dictionary = {}
	for t in _type_cap_spins.keys():
		caps[t] = int(_type_cap_spins[t].value)
	if not CardDB.set_type_caps(caps):
		_set_status("种类上限保存失败（每种上限需为 0–%d）" % CardDB.TYPE_CAP_LIMIT)
		return
	var size_now: int = CardDB.build_deck().size()
	_set_status("卡组规则已应用：最少 %d 张 / 最多 %d 张 / 同名卡最多 %d 张 · 种类上限 %s → 当前牌库 %d 张" % [
		want_min, want_max, want_copies, CardDB._type_caps_text(), size_now])
	_refresh_deck_rules_label()


func _on_reset_deck_rules() -> void:
	CardDB.reset_deck_rules()
	_deck_min_spin.value = CardDB.DEFAULT_DECK_MIN
	_deck_max_spin.value = CardDB.DEFAULT_DECK_MAX
	_deck_copies_spin.value = CardDB.COPIES_PER_CARD
	for t in _type_cap_spins.keys():
		_type_cap_spins[t].value = 0
	if not CardDB.set_type_caps({}):
		_set_status("种类上限重置失败")
		return
	_set_status("卡组规则已恢复默认：最少 %d 张 / 最多 %d 张 / 同名卡最多 %d 张 · 各类不限" % [
		CardDB.DEFAULT_DECK_MIN, CardDB.DEFAULT_DECK_MAX, CardDB.COPIES_PER_CARD])
	_refresh_deck_rules_label()


# ------------------------------ 对战模式规则（指定 / 无限） ------------------------------
#
# 用户口径：管理员的规则分「指定 / 无限」两套，**不同模式的限制卡牌互不影响**。
#   * 无限：卡组张数 / 同名 / 种类上限 = 上面那份全局规则；另外一份自己的限制卡表；
#   * 指定：自己的一份张数 / 同名 / 种类上限 + **可用卡包勾选** + 自己的限制卡表。
# 限制卡 = 「这张卡在本模式最多带几张」：0 = 禁用，N = 最多 N 张，不在表里 = 不限制。

func _build_format_rules(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	var title := _make_label("对战模式规则（指定 / 无限）")
	title.add_theme_color_override("font_color", Color("#90caf9"))
	box.add_child(title)
	var note := _make_label("无限模式的张数规则 = 上面那份「卡组规则（全局）」；指定模式在这里单独一套，"
		+ "两个模式的限制卡表互不影响。")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 11)
	note.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(note)

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	box.add_child(mode_row)
	_format_option = OptionButton.new()
	_format_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for m in Formats.mode_ids():
		_format_option.add_item(Formats.mode_label(m))
		_format_option.set_item_metadata(_format_option.item_count - 1, m)
	_format_option.item_selected.connect(_on_format_mode_changed)
	mode_row.add_child(_format_option)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	_fmt_min_spin = _make_spin(1, 999, 1)
	_add_row(grid, "最少张数", _fmt_min_spin)
	_fmt_max_spin = _make_spin(1, 999, 1)
	_add_row(grid, "最多张数", _fmt_max_spin)
	_fmt_copies_spin = _make_spin(1, CardDB.MAX_COPIES_LIMIT, 1)
	_add_row(grid, "同名卡最大携带", _fmt_copies_spin)
	for t in [CardData.CardType.MINION, CardData.CardType.SPELL,
			CardData.CardType.AMULET, CardData.CardType.CITY]:
		var sp := _make_spin(0, CardDB.TYPE_CAP_LIMIT, 1)
		sp.tooltip_text = "每张牌组里「%s」类卡最多带几张（0 = 不限）" % CardData.TYPE_NAMES[t]
		_fmt_cap_spins[t] = sp
		_add_row(grid, "%s最多带" % CardData.TYPE_NAMES[t], sp)

	# 指定模式的可用卡包：只勾选这里打勾的包，卡牌才会出现在组卡界面
	var pack_title := _make_label("指定模式的可用卡包")
	pack_title.add_theme_color_override("font_color", Color("#a5d6a7"))
	box.add_child(pack_title)
	_fmt_packs_scroll = ScrollContainer.new()
	_fmt_packs_scroll.custom_minimum_size = Vector2(0, 92)
	_fmt_packs_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_fmt_packs_scroll)
	_fmt_packs_box = VBoxContainer.new()
	_fmt_packs_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fmt_packs_scroll.add_child(_fmt_packs_box)

	# 限制卡：这张卡在本模式最多带几张（0 = 禁用）
	var limit_title := _make_label("本模式的限制卡（0 = 禁用 / N = 最多 N 张）")
	limit_title.add_theme_color_override("font_color", Color("#ef9a9a"))
	box.add_child(limit_title)
	var limit_row := HBoxContainer.new()
	limit_row.add_theme_constant_override("separation", 6)
	box.add_child(limit_row)
	_limit_card_option = OptionButton.new()
	_limit_card_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_limit_card_option.fit_to_longest_item = false
	limit_row.add_child(_limit_card_option)
	_limit_spin = _make_spin(0, CardDB.MAX_COPIES_LIMIT, 1)
	_limit_spin.value = 0
	limit_row.add_child(_limit_spin)
	var limit_add := Button.new()
	limit_add.text = "设为限制"
	limit_add.pressed.connect(_on_limit_add)
	limit_row.add_child(limit_add)
	var limit_del := Button.new()
	limit_del.text = "解除"
	limit_del.pressed.connect(_on_limit_remove)
	limit_row.add_child(limit_del)

	_limit_list = ItemList.new()
	_limit_list.custom_minimum_size = Vector2(0, 84)
	box.add_child(_limit_list)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var apply_btn := Button.new()
	apply_btn.text = "应用本模式规则"
	apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_btn.pressed.connect(_on_apply_format_rules)
	row.add_child(apply_btn)
	var reset_btn := Button.new()
	reset_btn.text = "恢复本模式默认"
	reset_btn.pressed.connect(_on_reset_format_rules)
	row.add_child(reset_btn)

	_fmt_hint = _make_label("")
	_fmt_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fmt_hint.add_theme_font_size_override("font_size", 12)
	_fmt_hint.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(_fmt_hint)

	# 默认展示无限模式（= 全局规则）；下拉的选中项也同步过去，避免「显示指定、实际在编辑无限」
	_fmt_mode = Formats.UNLIMITED
	for i in _format_option.item_count:
		if str(_format_option.get_item_metadata(i)) == _fmt_mode:
			_format_option.select(i)
			break
	_load_format_controls()


func _on_format_mode_changed(index: int) -> void:
	if _format_option == null or index < 0:
		return
	var meta = _format_option.get_item_metadata(index)
	_fmt_mode = Formats.normalized_mode(str(meta) if meta != null else "")
	_load_format_controls()


## 把当前选中模式的规则回填到控件（无限 = 全局规则；指定 = 它自己那份）
func _load_format_controls() -> void:
	if _fmt_min_spin == null:
		return
	# 控件值跟着当前模式走，下拉选中项也对齐（避免显示与编辑对象不一致）
	for i in _format_option.item_count:
		if str(_format_option.get_item_metadata(i)) == _fmt_mode:
			_format_option.select(i)
			break
	_fmt_min_spin.value = CardDB.mode_deck_min(_fmt_mode)
	_fmt_max_spin.value = CardDB.mode_deck_max(_fmt_mode)
	_fmt_copies_spin.value = CardDB.mode_max_copies(_fmt_mode)
	for t in _fmt_cap_spins.keys():
		_fmt_cap_spins[t].value = CardDB.mode_type_cap(_fmt_mode, int(t))
	_fmt_limits = (CardDB.format_limits.get(_fmt_mode, {}) as Dictionary).duplicate(true)
	_refresh_format_packs()
	_refresh_limit_list()
	_refresh_fmt_hint()
	# 无限模式没有自己的卡包范围（全部卡包），把勾选区置灰
	var rotation := Formats.is_rotation(_fmt_mode)
	_fmt_packs_scroll.modulate = Color(1, 1, 1, 1) if rotation else Color(1, 1, 1, 0.55)


func _refresh_format_packs() -> void:
	if _fmt_packs_box == null:
		return
	for child in _fmt_packs_box.get_children():
		child.queue_free()
	_fmt_pack_checks.clear()
	var allowed: Array = CardDB.rotation_rules.get("packs", []) if Formats.is_rotation(_fmt_mode) \
		else CardDB.pack_ids()
	for e in CardDB.packs:
		var pid := str(e.get("id", ""))
		var cb := CheckBox.new()
		var n := CardDB.pack_card_count(pid)
		cb.text = "%s（%d 种卡）" % [str(e.get("name", pid)), n]
		cb.button_pressed = allowed.has(pid)
		cb.disabled = not Formats.is_rotation(_fmt_mode)   # 无限模式 = 全部卡包，不让改
		_fmt_packs_box.add_child(cb)
		_fmt_pack_checks[pid] = cb
	if CardDB.packs.is_empty():
		var empty := _make_label("还没有卡包：先在下面的「卡包」面板里建。")
		_fmt_packs_box.add_child(empty)
	_fmt_packs_signature = _packs_signature()


func _refresh_limit_list() -> void:
	if _limit_list == null:
		return
	_limit_list.clear()
	for cid in _fmt_limits.keys():
		var id := str(cid)
		var c := CardDB.get_card(id)
		var label := c.card_name if c != null else id
		var n := int(_fmt_limits[cid])
		var text := "%s（%s）→ %s" % [label, id, "禁用" if n <= 0 else "最多 %d 张" % n]
		var idx := _limit_list.add_item(text)
		_limit_list.set_item_metadata(idx, id)


func _refresh_limit_card_options() -> void:
	if _limit_card_option == null:
		return
	var keep := ""
	if _limit_card_option.item_count > 0 and _limit_card_option.selected >= 0:
		var meta = _limit_card_option.get_item_metadata(_limit_card_option.selected)
		keep = "" if meta == null else str(meta)
	_limit_card_option.clear()
	for c in CardDB.cards:
		if c.is_token:
			continue
		_limit_card_option.add_item("%s（%s）" % [c.card_name, c.id])
		_limit_card_option.set_item_metadata(_limit_card_option.item_count - 1, c.id)
	if _limit_card_option.item_count == 0:
		_limit_card_option.add_item("（卡表为空）")
	for i in _limit_card_option.item_count:
		if str(_limit_card_option.get_item_metadata(i)) == keep:
			_limit_card_option.select(i)
			break


func _on_limit_add() -> void:
	if _limit_card_option == null or _limit_card_option.selected < 0:
		return
	var meta = _limit_card_option.get_item_metadata(_limit_card_option.selected)
	var cid := "" if meta == null else str(meta)
	if cid == "":
		_set_status("请先选择要限制的卡牌")
		return
	_fmt_limits[cid] = int(_limit_spin.value)
	_refresh_limit_list()
	_refresh_fmt_hint()
	_set_status("「%s」%s：点「应用本模式规则」后生效" % [
		CardDB.get_card(cid).card_name if CardDB.get_card(cid) != null else cid,
		"已禁用" if _limit_spin.value <= 0 else "最多 %d 张" % int(_limit_spin.value)])


func _on_limit_remove() -> void:
	var picked := _limit_list.get_selected_items()
	if picked.is_empty():
		_set_status("请先在上面的清单里选中要解除的限制")
		return
	var cid := str(_limit_list.get_item_metadata(picked[0]))
	_fmt_limits.erase(cid)
	_refresh_limit_list()
	_refresh_fmt_hint()


func _on_apply_format_rules() -> void:
	var want_min := int(_fmt_min_spin.value)
	var want_max := int(_fmt_max_spin.value)
	var want_copies := int(_fmt_copies_spin.value)
	if not CardDB.rules_valid(want_min, want_max, want_copies):
		_set_status("规则不合法：最少不能大于最多、张数与同名携带数都要 ≥ 1（同名最多 %d 张）" % CardDB.MAX_COPIES_LIMIT)
		return
	var caps: Dictionary = {}
	for t in _fmt_cap_spins.keys():
		caps[t] = int(_fmt_cap_spins[t].value)
	if not CardDB.type_caps_valid(caps):
		_set_status("种类上限不合法：每种上限需为 0–%d" % CardDB.TYPE_CAP_LIMIT)
		return
	if Formats.is_rotation(_fmt_mode):
		var pids: Array[String] = []
		for pid in _fmt_pack_checks.keys():
			if (_fmt_pack_checks[pid] as CheckBox).button_pressed:
				pids.append(str(pid))
		if pids.is_empty():
			_set_status("指定模式至少要勾选一个卡包，否则玩家没有卡可以用")
			return
		if not CardDB.set_rotation_rules(want_min, want_max, want_copies, caps, pids):
			_set_status("指定模式规则保存失败（至少要有一个已登记的卡包）")
			return
	else:
		# 无限模式的张数规则就是全局那份（组卡界面 / 老代码都读它）
		if not CardDB.set_deck_rules(want_min, want_max, want_copies):
			_set_status("卡组规则保存失败（写入 user://deck_rules.cfg 出错）")
			return
		if not CardDB.set_type_caps(caps):
			_set_status("种类上限保存失败（每种上限需为 0–%d）" % CardDB.TYPE_CAP_LIMIT)
			return
	if not CardDB.set_mode_limits(_fmt_mode, _fmt_limits):
		_set_status("限制卡表保存失败")
		return
	_refresh_deck_rules_controls_from_db()
	_set_status("已应用「%s」模式规则：%d–%d 张 / 同名 %d / 限制卡 %d 张" % [
		CardDB.mode_label(_fmt_mode), want_min, want_max, want_copies, _fmt_limits.size()])


func _on_reset_format_rules() -> void:
	if Formats.is_rotation(_fmt_mode):
		if not CardDB.reset_rotation_rules() or not CardDB.clear_mode_limits(_fmt_mode):
			_set_status("恢复指定模式默认规则失败")
			return
		_set_status("指定模式已恢复默认：沿用全局张数规则 + 全部卡包，限制卡表已清空")
	else:
		if not CardDB.reset_deck_rules() or not CardDB.set_type_caps({}) \
				or not CardDB.clear_mode_limits(_fmt_mode):
			_set_status("恢复无限模式默认规则失败")
			return
		_set_status("无限模式（全局）已恢复默认：%d 张起 / 同名 %d 张，限制卡表已清空" % [
			CardDB.DEFAULT_DECK_MIN, CardDB.COPIES_PER_CARD])
	_refresh_deck_rules_controls_from_db()
	_refresh_deck_rules_label()


## 规则被改过之后：把全局那条「卡组规则」面板与模式面板一起拉回最新值
func _refresh_deck_rules_controls_from_db() -> void:
	if _deck_min_spin != null:
		_deck_min_spin.value = CardDB.deck_min
		_deck_max_spin.value = CardDB.deck_max
		_deck_copies_spin.value = CardDB.max_copies
		for t in _type_cap_spins.keys():
			_type_cap_spins[t].value = CardDB.type_cap(int(t))
	_load_format_controls()
	if _deck_rules_label != null:
		_refresh_deck_rules_label()


func _refresh_fmt_hint() -> void:
	if _fmt_hint == null or _fmt_options_ready() == false:
		return
	var size_now: int = CardDB.build_deck(-1, "", _fmt_mode).size()
	var text := "%s模式：当前可生成 %d 张 · 可用卡包 %d 个 · 限制卡 %d 张" % [
		CardDB.mode_label(_fmt_mode), size_now,
		CardDB.mode_allowed_packs(_fmt_mode).size(), _fmt_limits.size()]
	var warns: Array[String] = CardDB.format_report(_fmt_mode)
	if not warns.is_empty():
		text += "\n⚠ " + "\n⚠ ".join(warns)
	_fmt_hint.text = text
	_fmt_hint.tooltip_text = Formats.mode_desc(_fmt_mode)


func _fmt_options_ready() -> bool:
	return _fmt_cap_spins != null and _fmt_packs_box != null


## 卡表 / 卡包 / 规则发生变化后，把所有与模式相关的候选与提示拉回最新（本函数不写盘）
func _refresh_format_sources() -> void:
	if _card_pack_option != null:
		_refresh_card_pack_options()
	_refresh_pack_list()
	_refresh_limit_card_options()
	# 勾选区只在「卡包清单变了」时重建：否则管理员勾了没应用的改动会被刷掉
	if _fmt_packs_box != null and _packs_signature() != _fmt_packs_signature:
		_refresh_format_packs()
	_refresh_fmt_hint()
	if _deck_rules_label != null:
		_refresh_deck_rules_label()


func _packs_signature() -> String:
	return ",".join(CardDB.pack_ids())


# ------------------------------ 主战者职业 ------------------------------
#
# 职业决定「哪个主战者能带哪些卡」：玩家组卡时 **只能用本职业 + 中立** 的卡。
# 删除职业不会留下残值 —— 原本属于它的卡会立刻被改成中立（见 CardDB.remove_hero_class），
# 管理员不需要手动去改每一张卡。

func _build_hero_class_manager(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	var title := _make_label("主战者职业（全局）")
	title.add_theme_color_override("font_color", Color("#80cbc4"))
	box.add_child(title)

	_hero_class_list = ItemList.new()
	_hero_class_list.custom_minimum_size = Vector2(0, 76)
	_hero_class_list.item_selected.connect(_on_hero_class_selected)
	box.add_child(_hero_class_list)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	_hero_class_id_edit = LineEdit.new()
	_hero_class_id_edit.placeholder_text = "英文 id，如 mage"
	_add_row(grid, "职业 ID", _hero_class_id_edit)
	_hero_class_name_edit = LineEdit.new()
	_hero_class_name_edit.placeholder_text = "如：奥术法师"
	_add_row(grid, "职业名称", _hero_class_name_edit)
	_hero_class_desc_edit = LineEdit.new()
	_hero_class_desc_edit.placeholder_text = "一句话简介（可留空）"
	_add_row(grid, "职业简介", _hero_class_desc_edit)
	_hero_class_color = ColorPickerButton.new()
	_hero_class_color.custom_minimum_size = Vector2(90, 0)
	_add_row(grid, "职业配色", _hero_class_color)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var new_btn := Button.new()
	new_btn.text = "新建职业"
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.pressed.connect(_on_hero_class_new)
	row.add_child(new_btn)
	var save_btn := Button.new()
	save_btn.text = "保存修改"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_hero_class_save)
	row.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_hero_class_delete)
	row.add_child(del_btn)

	_hero_class_hint = _make_label("")
	_hero_class_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hero_class_hint.add_theme_font_size_override("font_size", 12)
	_hero_class_hint.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(_hero_class_hint)

	_refresh_hero_class_list()
	_new_hero_class()


func _refresh_hero_class_list() -> void:
	if _hero_class_list == null:
		return
	_hero_class_list.clear()
	for e in CardDB.hero_classes:
		var cid := str(e.get("id", ""))
		var idx := _hero_class_list.add_item("%s　%s（%d 种卡）" % [
			str(e.get("name", cid)), cid, CardDB.class_card_count(cid)])
		_hero_class_list.set_item_metadata(idx, cid)
	if _hero_class_hint != null:
		_hero_class_hint.text = "玩家组卡只能用「本职业 + 中立」的卡；当前中立卡 %d 种。" % CardDB.neutral_card_count()


## 表单回到「新建」状态：ID 可填；选中某个职业后 ID 不可改（避免卡牌残留在旧 ID 上）
func _new_hero_class() -> void:
	if _hero_class_list != null:
		_hero_class_list.deselect_all()
	_hero_class_id_edit.editable = true
	_hero_class_id_edit.text = ""
	_hero_class_name_edit.text = ""
	_hero_class_desc_edit.text = ""
	_hero_class_color.color = Color("#90caf9")


func _on_hero_class_selected(index: int) -> void:
	var cid := str(_hero_class_list.get_item_metadata(index))
	var def := CardDB.hero_class_by_id(cid)
	if def.is_empty():
		return
	_hero_class_id_edit.editable = false
	_hero_class_id_edit.text = cid
	_hero_class_name_edit.text = str(def.get("name", cid))
	_hero_class_desc_edit.text = str(def.get("desc", ""))
	var raw := str(def.get("color", "#90caf9"))
	_hero_class_color.color = Color.html(raw) if Color.html_is_valid(raw) else Color("#90caf9")
	_set_status("正在编辑职业：%s（ID 不可修改）" % str(def.get("name", cid)))


func _on_hero_class_new() -> void:
	_new_hero_class()
	_set_status("新建职业：填好 ID 与名称后点「保存修改」")


func _on_hero_class_save() -> void:
	var cid := _hero_class_id_edit.text.strip_edges()
	if cid == "":
		_set_status("请先填写职业 ID（英文 / 数字 / 下划线，不能以数字开头）")
		return
	var name := _hero_class_name_edit.text.strip_edges()
	var html := "#" + _hero_class_color.color.to_html(false)
	if CardDB.has_hero_class(cid):
		if not CardDB.update_hero_class(cid, name, html, _hero_class_desc_edit.text.strip_edges()):
			_set_status("职业保存失败")
			return
		_set_status("已更新职业「%s」" % CardDB.hero_class_name(cid))
	elif not CardDB.hero_class_id_valid(cid):
		_set_status("职业 ID 不合法：只能用字母 / 数字 / 下划线、不能以数字开头，也不能叫 neutral")
		return
	elif not CardDB.add_hero_class(cid, name, html, _hero_class_desc_edit.text.strip_edges()):
		_set_status("新增职业失败（ID 重复或写法不合法）")
		return
	else:
		_set_status("已新增职业「%s」" % CardDB.hero_class_name(cid))
	_refresh_hero_class_list()
	_refresh_class_options()
	_refresh_list()


func _on_hero_class_delete() -> void:
	var picked := _hero_class_list.get_selected_items()
	if picked.is_empty():
		_set_status("请先在上面的清单里选中要删除的职业")
		return
	var cid := str(_hero_class_list.get_item_metadata(picked[0]))
	var label := CardDB.hero_class_name(cid)
	var changed := CardDB.remove_hero_class(cid)
	if changed < 0:
		_set_status("删除失败：找不到职业 %s" % cid)
		return
	_new_hero_class()
	_refresh_hero_class_list()
	_refresh_class_options()
	_refresh_list()
	_set_status("已删除职业「%s」：%d 张原本属于它的卡已改成中立卡。" % [label, changed])


## 卡牌表单里的「主战者职业」下拉：中立 + 所有职业（删除 / 新增职业后跟着变）
func _refresh_class_options() -> void:
	if _card_class_option == null:
		return
	var keep := CardData.NEUTRAL_CLASS
	if _card_class_option.selected >= 0:
		var now := str(_card_class_option.get_item_metadata(_card_class_option.selected))
		if now != "<null>" and now != "":
			keep = now
	_card_class_option.clear()
	_card_class_option.add_item("中立（所有职业通用）")
	_card_class_option.set_item_metadata(0, CardData.NEUTRAL_CLASS)
	var idx := 1
	for e in CardDB.hero_classes:
		var cid := str(e.get("id", ""))
		_card_class_option.add_item("%s（%d 种卡）" % [str(e.get("name", cid)), CardDB.class_card_count(cid)])
		_card_class_option.set_item_metadata(idx, cid)
		idx += 1
	_select_card_class(keep)


func _select_card_class(cid: String) -> void:
	for i in _card_class_option.item_count:
		if str(_card_class_option.get_item_metadata(i)) == cid:
			_card_class_option.select(i)
			return
	_card_class_option.select(0)


# ------------------------------ 兵种 ------------------------------
#
# 影之诗的「士兵 / 指挥官」那类**单位分类**，由管理员自己建：
#   * 建好之后，卡牌表单的「兵种」下拉才选得到（先建后用）；
#   * 兵种名可以检索（卡表检索 / 组卡界面搜索都认它）；
#   * 兵种能当效果链条件（「本局某兵种进场数 ≥ N」），见 ChainEditor 的条件行。
# 删除兵种不会留下残值：原本挂着它的卡会立刻改成「中立」（CardDB.remove_troop）。

func _build_troop_manager(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	var title := _make_label("兵种（全局）")
	title.add_theme_color_override("font_color", Color("#ffcc80"))
	box.add_child(title)

	_troop_list = ItemList.new()
	_troop_list.custom_minimum_size = Vector2(0, 76)
	_troop_list.item_selected.connect(_on_troop_selected)
	box.add_child(_troop_list)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	_troop_id_edit = LineEdit.new()
	_troop_id_edit.placeholder_text = "英文 id，如 soldier"
	_add_row(grid, "兵种 ID", _troop_id_edit)
	_troop_name_edit = LineEdit.new()
	_troop_name_edit.placeholder_text = "如：士兵"
	_add_row(grid, "兵种名称", _troop_name_edit)
	_troop_desc_edit = LineEdit.new()
	_troop_desc_edit.placeholder_text = "一句话简介（可留空）"
	_add_row(grid, "兵种简介", _troop_desc_edit)
	_troop_color = ColorPickerButton.new()
	_troop_color.custom_minimum_size = Vector2(90, 0)
	_add_row(grid, "兵种配色", _troop_color)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var new_btn := Button.new()
	new_btn.text = "新建兵种"
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.pressed.connect(_on_troop_new)
	row.add_child(new_btn)
	var save_btn := Button.new()
	save_btn.text = "保存修改"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_troop_save)
	row.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_troop_delete)
	row.add_child(del_btn)

	_troop_hint = _make_label("")
	_troop_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_troop_hint.add_theme_font_size_override("font_size", 12)
	_troop_hint.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(_troop_hint)

	_refresh_troop_list()
	_new_troop()


func _refresh_troop_list() -> void:
	if _troop_list == null:
		return
	_troop_list.clear()
	for e in CardDB.troops:
		var tid := str(e.get("id", ""))
		var idx := _troop_list.add_item("%s　%s（%d 种卡）" % [
			str(e.get("name", tid)), tid, CardDB.troop_card_count(tid)])
		_troop_list.set_item_metadata(idx, tid)
	if _troop_hint != null:
		_troop_hint.text = "先建兵种，再在卡牌表单里选：共 %d 个兵种。没选兵种的卡默认算「%s」（内置，不可删除）。兵种可用于检索，也能当效果链条件（如「本局士兵进场 ≥ 3」）。" % [
			CardDB.troops.size(), CardData.NEUTRAL_TROOP_NAME]


func _new_troop() -> void:
	if _troop_list != null:
		_troop_list.deselect_all()
	_troop_id_edit.editable = true
	_troop_id_edit.text = ""
	_troop_name_edit.text = ""
	_troop_desc_edit.text = ""
	_troop_color.color = Color("#ffcc80")


func _on_troop_selected(index: int) -> void:
	var tid := str(_troop_list.get_item_metadata(index))
	var def := CardDB.troop_by_id(tid)
	if def.is_empty():
		return
	_troop_id_edit.editable = false
	_troop_id_edit.text = tid
	_troop_name_edit.text = str(def.get("name", tid))
	_troop_desc_edit.text = str(def.get("desc", ""))
	var raw := str(def.get("color", "#ffcc80"))
	_troop_color.color = Color.html(raw) if Color.html_is_valid(raw) else Color("#ffcc80")
	_set_status("正在编辑兵种：%s（ID 不可修改）" % str(def.get("name", tid)))


func _on_troop_new() -> void:
	_new_troop()
	_set_status("新建兵种：填好 ID 与名称后点「保存修改」")


func _on_troop_save() -> void:
	var tid := _troop_id_edit.text.strip_edges()
	if tid == "":
		_set_status("请先填写兵种 ID（英文 / 数字 / 下划线，不能以数字开头）")
		return
	var name := _troop_name_edit.text.strip_edges()
	var html := "#" + _troop_color.color.to_html(false)
	if CardDB.has_troop(tid):
		if not CardDB.update_troop(tid, name, html, _troop_desc_edit.text.strip_edges()):
			_set_status("兵种保存失败")
			return
		_set_status("已更新兵种「%s」" % CardDB.troop_name(tid))
	elif not CardDB.troop_id_valid(tid):
		_set_status("兵种 ID 不合法：只能用字母 / 数字 / 下划线、不能以数字开头")
		return
	elif not CardDB.add_troop(tid, name, html, _troop_desc_edit.text.strip_edges()):
		_set_status("新增兵种失败（ID 重复或写法不合法）")
		return
	else:
		_set_status("已新增兵种「%s」：现在可以给卡牌选它，也能在效果链条件里用了" % CardDB.troop_name(tid))
	_refresh_troop_list()
	_refresh_card_troop_options()
	_refresh_invoke_troop_options()
	_refresh_troop_filter_options()
	_refresh_list()


func _on_troop_delete() -> void:
	var picked := _troop_list.get_selected_items()
	if picked.is_empty():
		_set_status("请先在上面的清单里选中要删除的兵种")
		return
	var tid := str(_troop_list.get_item_metadata(picked[0]))
	var label := CardDB.troop_name(tid)
	var changed := CardDB.remove_troop(tid)
	if changed == -2:
		_set_status("「%s」是内置兵种，不能删除（没选兵种的卡都归它）" % label)
		return
	if changed < 0:
		_set_status("删除失败：找不到兵种 %s" % tid)
		return
	_new_troop()
	_refresh_troop_list()
	_refresh_card_troop_options()
	_refresh_invoke_troop_options()
	_refresh_troop_filter_options()
	_refresh_list()
	_set_status("已删除兵种「%s」：%d 张原本挂着它的卡已改成「%s」。" % [
		label, changed, CardData.NEUTRAL_TROOP_NAME])


## 卡牌表单的兵种下拉：所有已登记兵种（含内置「中立」，新建 / 删除兵种后跟着变）。
## **没有「无兵种」这一项**：不选就是「中立」兵种（卡表里存 ""，读时由 troop_of 归一）。
func _refresh_card_troop_options() -> void:
	if _card_troop_option == null:
		return
	var keep := _selected_card_troop()
	_card_troop_option.clear()
	var idx := 0
	for e in CardDB.troops:
		var tid := str(e.get("id", ""))
		_card_troop_option.add_item("%s（%d 种卡）" % [str(e.get("name", tid)), CardDB.troop_card_count(tid)])
		_card_troop_option.set_item_metadata(idx, tid)
		idx += 1
	if _card_troop_option.item_count == 0:
		_card_troop_option.add_item(CardData.NEUTRAL_TROOP_NAME)
		_card_troop_option.set_item_metadata(0, CardData.NEUTRAL_TROOP)
	_select_card_troop(keep)


func _select_card_troop(tid: String) -> void:
	if _card_troop_option == null:
		return
	var want := tid if tid != "" else CardData.NEUTRAL_TROOP
	for i in _card_troop_option.item_count:
		if str(_card_troop_option.get_item_metadata(i)) == want:
			_card_troop_option.select(i)
			return
	for i in _card_troop_option.item_count:
		if str(_card_troop_option.get_item_metadata(i)) == CardData.NEUTRAL_TROOP:
			_card_troop_option.select(i)
			return
	_card_troop_option.select(0)


## 选中的兵种 id；「中立」存成 ""（= 没指定兵种，由 troop_of 归一成立）
func _selected_card_troop() -> String:
	if _card_troop_option == null or _card_troop_option.selected < 0:
		return ""
	var meta = _card_troop_option.get_item_metadata(_card_troop_option.selected)
	var tid := "" if meta == null else str(meta)
	return "" if CardDB.is_neutral_troop(tid) else tid


## 卡表检索的兵种筛选下拉：第一项「全部兵种」
func _refresh_troop_filter_options() -> void:
	if _list_troop_filter == null:
		return
	var keep := _selected_filter_troop()
	_list_troop_filter.clear()
	_list_troop_filter.add_item("全部兵种")
	_list_troop_filter.set_item_metadata(0, "")
	var idx := 1
	for e in CardDB.troops:
		var tid := str(e.get("id", ""))
		_list_troop_filter.add_item(str(e.get("name", tid)))
		_list_troop_filter.set_item_metadata(idx, tid)
		idx += 1
	for i in _list_troop_filter.item_count:
		if str(_list_troop_filter.get_item_metadata(i)) == keep:
			_list_troop_filter.select(i)
			return
	_list_troop_filter.select(0)


func _selected_filter_troop() -> String:
	if _list_troop_filter == null or _list_troop_filter.selected < 0:
		return ""
	var meta = _list_troop_filter.get_item_metadata(_list_troop_filter.selected)
	return "" if meta == null else str(meta)


# ------------------------------ 卡包（扩展包） ------------------------------
#
# 卡包是「一张卡属于哪个扩展包」的标签：先在下面建包，再在卡牌表单里选。
# 组卡界面按「指定模式勾选的卡包」过滤卡池；无限模式不看卡包（全部可用）。

func _build_pack_manager(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	var title := _make_label("卡包（全局）")
	title.add_theme_color_override("font_color", Color("#ce93d8"))
	box.add_child(title)

	_pack_list = ItemList.new()
	_pack_list.custom_minimum_size = Vector2(0, 76)
	_pack_list.item_selected.connect(_on_pack_selected)
	box.add_child(_pack_list)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	_pack_id_edit = LineEdit.new()
	_pack_id_edit.placeholder_text = "英文 id，如 classic"
	_add_row(grid, "卡包 ID", _pack_id_edit)
	_pack_name_edit = LineEdit.new()
	_pack_name_edit.placeholder_text = "如：经典卡包"
	_add_row(grid, "卡包名称", _pack_name_edit)
	_pack_desc_edit = LineEdit.new()
	_pack_desc_edit.placeholder_text = "一句话简介（可留空）"
	_add_row(grid, "卡包简介", _pack_desc_edit)
	_pack_color = ColorPickerButton.new()
	_pack_color.custom_minimum_size = Vector2(90, 0)
	_add_row(grid, "卡包配色", _pack_color)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var new_btn := Button.new()
	new_btn.text = "新建卡包"
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.pressed.connect(_on_pack_new)
	row.add_child(new_btn)
	var save_btn := Button.new()
	save_btn.text = "保存修改"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_pack_save)
	row.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_pack_delete)
	row.add_child(del_btn)

	_pack_hint = _make_label("")
	_pack_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pack_hint.add_theme_font_size_override("font_size", 12)
	_pack_hint.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(_pack_hint)

	_refresh_pack_list()
	_new_pack()


func _refresh_pack_list() -> void:
	if _pack_list == null:
		return
	var keep := ""
	var picked := _pack_list.get_selected_items()
	if not picked.is_empty():
		var meta = _pack_list.get_item_metadata(picked[0])
		keep = "" if meta == null else str(meta)
	_pack_list.clear()
	for e in CardDB.packs:
		var pid := str(e.get("id", ""))
		var idx := _pack_list.add_item("%s　%s（%d 种卡）" % [
			str(e.get("name", pid)), pid, CardDB.pack_card_count(pid)])
		_pack_list.set_item_metadata(idx, pid)
		if pid == keep:
			_pack_list.select(idx)
	if _pack_hint != null:
		_pack_hint.text = "先建卡包，再在卡牌表单里选：共 %d 个卡包。「%s」内置不可删除（没选卡包的卡都归它）。" % [
			CardDB.packs.size(), CardDB.pack_name(CardDB.DEFAULT_PACK)]


func _new_pack() -> void:
	if _pack_list != null:
		_pack_list.deselect_all()
	_pack_id_edit.editable = true
	_pack_id_edit.text = ""
	_pack_name_edit.text = ""
	_pack_desc_edit.text = ""
	_pack_color.color = Color("#ce93d8")


func _on_pack_selected(index: int) -> void:
	var meta = _pack_list.get_item_metadata(index)
	var pid := "" if meta == null else str(meta)
	var def := CardDB.pack_by_id(pid)
	if def.is_empty():
		return
	_pack_id_edit.editable = false
	_pack_id_edit.text = pid
	_pack_name_edit.text = str(def.get("name", pid))
	_pack_desc_edit.text = str(def.get("desc", ""))
	var raw := str(def.get("color", CardDB.PACK_COLOR_FALLBACK))
	_pack_color.color = Color.html(raw) if Color.html_is_valid(raw) else Color(CardDB.PACK_COLOR_FALLBACK)
	_set_status("正在编辑卡包：%s（ID 不可修改）" % str(def.get("name", pid)))


func _on_pack_new() -> void:
	_new_pack()
	_set_status("新建卡包：填好 ID 与名称后点「保存修改」")


func _on_pack_save() -> void:
	var pid := _pack_id_edit.text.strip_edges()
	if pid == "":
		_set_status("请先填写卡包 ID（英文 / 数字 / 下划线，不能以数字开头）")
		return
	var pname := _pack_name_edit.text.strip_edges()
	var html := "#" + _pack_color.color.to_html(false)
	if CardDB.has_pack(pid):
		if not CardDB.update_pack(pid, pname, html, _pack_desc_edit.text.strip_edges()):
			_set_status("卡包保存失败")
			return
		_set_status("已更新卡包「%s」" % CardDB.pack_name(pid))
	elif not CardDB.pack_id_valid(pid):
		_set_status("卡包 ID 不合法：只能用字母 / 数字 / 下划线、不能以数字开头")
		return
	elif not CardDB.add_pack(pid, pname, html, _pack_desc_edit.text.strip_edges()):
		_set_status("新增卡包失败（ID 重复或写法不合法）")
		return
	else:
		_set_status("已新增卡包「%s」：现在可以给卡牌选它，并在「指定模式」里勾选" % CardDB.pack_name(pid))
	_refresh_pack_list()
	_refresh_card_pack_options()
	_refresh_format_packs()
	_refresh_fmt_hint()


func _on_pack_delete() -> void:
	var picked := _pack_list.get_selected_items()
	if picked.is_empty():
		_set_status("请先在上面的清单里选中要删除的卡包")
		return
	var meta = _pack_list.get_item_metadata(picked[0])
	var pid := "" if meta == null else str(meta)
	var label := CardDB.pack_name(pid)
	var changed := CardDB.remove_pack(pid)
	if changed == -2:
		_set_status("「%s」是内置卡包，不能删除（没选卡包的卡都归它）" % label)
		return
	if changed < 0:
		_set_status("删除失败：找不到卡包 %s" % pid)
		return
	_new_pack()
	_refresh_pack_list()
	_refresh_card_pack_options()
	_refresh_format_packs()
	_refresh_fmt_hint()
	_refresh_list()
	_set_status("已删除卡包「%s」：%d 张原本属于它的卡已改回「%s」。" % [
		label, changed, CardDB.pack_name(CardDB.DEFAULT_PACK)])


## 卡牌表单的卡包下拉：所有已登记卡包（新建 / 删除卡包后跟着变）
func _refresh_card_pack_options() -> void:
	if _card_pack_option == null:
		return
	var keep := _selected_card_pack()
	_card_pack_option.clear()
	var idx := 0
	for e in CardDB.packs:
		var pid := str(e.get("id", ""))
		_card_pack_option.add_item("%s（%d 种卡）" % [str(e.get("name", pid)), CardDB.pack_card_count(pid)])
		_card_pack_option.set_item_metadata(idx, pid)
		idx += 1
	if _card_pack_option.item_count == 0:
		_card_pack_option.add_item(CardDB.DEFAULT_PACK_NAME)
		_card_pack_option.set_item_metadata(0, CardDB.DEFAULT_PACK)
	_select_card_pack(keep)


func _select_card_pack(pid: String) -> void:
	if _card_pack_option == null:
		return
	var want := pid if pid != "" and CardDB.has_pack(pid) else CardDB.DEFAULT_PACK
	for i in _card_pack_option.item_count:
		if str(_card_pack_option.get_item_metadata(i)) == want:
			_card_pack_option.select(i)
			return
	_card_pack_option.select(0)


## 选中的卡包 id；基础卡包存成 ""（= 没指定卡包，由 pack_of 归一成基础包）
func _selected_card_pack() -> String:
	if _card_pack_option == null or _card_pack_option.selected < 0:
		return ""
	var meta = _card_pack_option.get_item_metadata(_card_pack_option.selected)
	var pid := "" if meta == null else str(meta)
	return "" if pid == CardDB.DEFAULT_PACK else pid


# ------------------------------ 随机能力池（全局） ------------------------------
#
# 一条「随机能力」效果 = 从某个池子里随机抽若干个能力并逐个结算：
#   repeat 可重复获得 / unique 不可重复获得 / order 随机次序触发（个数 0 = 全部）。
# 池子里的每条能力就是一条普通效果，所以「随机破坏对面随从」「随机抽牌」都能直接配。

func _build_ability_pool_manager(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)
	var title := _make_label("随机能力池（全局）")
	title.add_theme_color_override("font_color", Color("#ffab91"))
	box.add_child(title)

	_ability_pool_list = ItemList.new()
	_ability_pool_list.custom_minimum_size = Vector2(0, 76)
	_ability_pool_list.item_selected.connect(_on_ability_pool_selected)
	box.add_child(_ability_pool_list)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	box.add_child(grid)

	_ability_id_edit = LineEdit.new()
	_ability_id_edit.placeholder_text = "英文 id，如 chaos"
	_add_row(grid, "池 ID", _ability_id_edit)
	_ability_name_edit = LineEdit.new()
	_ability_name_edit.placeholder_text = "如：混沌召来"
	_add_row(grid, "池名称", _ability_name_edit)
	_ability_desc_edit = LineEdit.new()
	_ability_desc_edit.placeholder_text = "一句话简介（可留空）"
	_add_row(grid, "池简介", _ability_desc_edit)

	_ability_mode_option = OptionButton.new()
	for m in AbilityPools.mode_ids():
		_ability_mode_option.add_item(AbilityPools.mode_label(m))
		_ability_mode_option.set_item_metadata(_ability_mode_option.item_count - 1, m)
	_ability_mode_option.tooltip_text = "可重复获得 / 不可重复获得 / 随机次序触发（全部按打乱的顺序结算）"
	_ability_mode_option.item_selected.connect(func(_i: int) -> void: _refresh_ability_pool_hint())
	_add_row(grid, "随机口径", _ability_mode_option)

	_ability_min_spin = _make_spin(0, AbilityPools.MAX_COUNT, 1)
	_ability_min_spin.value = 1
	_ability_min_spin.value_changed.connect(func(_v: float) -> void: _refresh_ability_pool_hint())
	_add_row(grid, "最少个数", _ability_min_spin)
	_ability_max_spin = _make_spin(0, AbilityPools.MAX_COUNT, 1)
	_ability_max_spin.value = 2
	_ability_max_spin.tooltip_text = "随机个数上限；「随机次序触发」时填 0 = 全部能力都触发"
	_ability_max_spin.value_changed.connect(func(_v: float) -> void: _refresh_ability_pool_hint())
	_add_row(grid, "最多个数", _ability_max_spin)

	_ability_editor = ChainEditor.new()
	box.add_child(_ability_editor)
	_ability_editor.setup("池中的能力（每条 = 一个能力，按抽到的顺序逐条结算）",
		"＋ 添加能力", _on_ability_pool_edited)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var new_btn := Button.new()
	new_btn.text = "新建池"
	new_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_btn.pressed.connect(_on_ability_pool_new)
	row.add_child(new_btn)
	var save_btn := Button.new()
	save_btn.text = "保存修改"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_ability_pool_save)
	row.add_child(save_btn)
	var del_btn := Button.new()
	del_btn.text = "删除所选"
	del_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_btn.pressed.connect(_on_ability_pool_delete)
	row.add_child(del_btn)

	_ability_hint = _make_label("")
	_ability_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ability_hint.add_theme_font_size_override("font_size", 12)
	_ability_hint.add_theme_color_override("font_color", Color("#b0bec5"))
	box.add_child(_ability_hint)

	_refresh_ability_pool_list()
	_new_ability_pool()


func _refresh_ability_pool_list() -> void:
	if _ability_pool_list == null:
		return
	var keep := ""
	var picked := _ability_pool_list.get_selected_items()
	if not picked.is_empty():
		var meta = _ability_pool_list.get_item_metadata(picked[0])
		keep = "" if meta == null else str(meta)
	_ability_pool_list.clear()
	for p in AbilityPools.all():
		var pid := str(p.get("id", ""))
		var idx := _ability_pool_list.add_item("%s　%s（%d 个能力）" % [
			str(p.get("name", pid)), pid, (p.get("abilities", []) as Array).size()])
		_ability_pool_list.set_item_metadata(idx, pid)
		if pid == keep:
			_ability_pool_list.select(idx)
	_refresh_ability_pool_hint()


func _new_ability_pool() -> void:
	if _ability_pool_list != null:
		_ability_pool_list.deselect_all()
	_ability_id_edit.editable = true
	_ability_id_edit.text = ""
	_ability_name_edit.text = ""
	_ability_desc_edit.text = ""
	_ability_mode_option.select(0)
	_ability_min_spin.value = 1
	_ability_max_spin.value = 2
	if _ability_editor != null:
		_ability_editor.clear()
	_refresh_ability_pool_hint()


func _on_ability_pool_selected(index: int) -> void:
	var meta = _ability_pool_list.get_item_metadata(index)
	var pid := "" if meta == null else str(meta)
	var def := AbilityPools.by_id(pid)
	if def.is_empty():
		return
	_ability_id_edit.editable = false
	_ability_id_edit.text = pid
	_ability_name_edit.text = str(def.get("name", pid))
	_ability_desc_edit.text = str(def.get("desc", ""))
	var mode := str(def.get("mode", AbilityPools.MODE_REPEAT))
	for i in _ability_mode_option.item_count:
		if str(_ability_mode_option.get_item_metadata(i)) == mode:
			_ability_mode_option.select(i)
			break
	_ability_min_spin.value = int(def.get("count_min", 1))
	_ability_max_spin.value = int(def.get("count_max", 1))
	if _ability_editor != null:
		_ability_editor.load_chain(def.get("abilities", []))
	_refresh_ability_pool_hint()
	_set_status("正在编辑随机能力池：%s（ID 不可修改）" % str(def.get("name", pid)))


func _on_ability_pool_new() -> void:
	_new_ability_pool()
	_set_status("新建随机能力池：填好 ID / 名称 / 随机口径与能力清单后点「保存修改」")


func _on_ability_pool_edited() -> void:
	_refresh_ability_pool_hint()
	_update_preview()


func _on_ability_pool_save() -> void:
	var pid := _ability_id_edit.text.strip_edges()
	if pid == "":
		_set_status("请先填写随机能力池 ID（英文 / 数字 / 下划线，不能以数字开头）")
		return
	var def := {
		"id": pid,
		"name": _ability_name_edit.text.strip_edges(),
		"desc": _ability_desc_edit.text.strip_edges(),
		"mode": _ability_mode_value(),
		"count_min": int(_ability_min_spin.value),
		"count_max": int(_ability_max_spin.value),
		"abilities": _ability_editor.chain() if _ability_editor != null else [],
	}
	var errs := AbilityPools.errors(def)
	if not errs.is_empty():
		_set_status("保存失败：" + errs[0])
		return
	var ok := false
	if AbilityPools.has(pid):
		ok = AbilityPools.update_pool(pid, def["name"], def["desc"], def["mode"],
			def["count_min"], def["count_max"], def["abilities"])
	elif not AbilityPools.id_valid(pid):
		_set_status("池 ID 不合法：只能用字母 / 数字 / 下划线、不能以数字开头")
		return
	else:
		ok = AbilityPools.add_pool(pid, def["name"], def["desc"], def["mode"],
			def["count_min"], def["count_max"], def["abilities"])
	if not ok:
		_set_status("随机能力池保存失败（写盘出错）")
		return
	_refresh_ability_pool_list()
	_update_preview()
	_set_status("已保存随机能力池「%s」：%s" % [
		AbilityPools.pool_name(pid), CardEffects.random_pool_text(pid, 0)])


func _on_ability_pool_delete() -> void:
	var picked := _ability_pool_list.get_selected_items()
	if picked.is_empty():
		_set_status("请先在上面的清单里选中要删除的随机能力池")
		return
	var meta = _ability_pool_list.get_item_metadata(picked[0])
	var pid := "" if meta == null else str(meta)
	var label := AbilityPools.pool_name(pid)
	if not AbilityPools.remove_pool(pid):
		_set_status("删除失败：找不到随机能力池 %s" % pid)
		return
	_new_ability_pool()
	_refresh_ability_pool_list()
	_update_preview()
	_set_status("已删除随机能力池「%s」：引用它的卡会在保存 / 自检时提示重选。" % label)


func _ability_mode_value() -> String:
	if _ability_mode_option == null or _ability_mode_option.selected < 0:
		return AbilityPools.MODE_REPEAT
	var meta = _ability_mode_option.get_item_metadata(_ability_mode_option.selected)
	return str(meta) if meta != null else AbilityPools.MODE_REPEAT


## 池子预览：随机口径 + 个数 + 能力清单，保存前就能看出实际效果
func _refresh_ability_pool_hint() -> void:
	if _ability_hint == null:
		return
	var pid := _ability_id_edit.text.strip_edges() if _ability_id_edit != null else ""
	if pid == "":
		_ability_hint.text = "尚未选择池子：在左侧清单里选一个，或点「新建池」。共 %d 个随机能力池。" % AbilityPools.all().size()
		return
	if not AbilityPools.has(pid):
		_ability_hint.text = "新池「%s」尚未保存：保存后才能在卡牌效果「随机能力（能力池）」里选到它。" % pid
		return
	_ability_hint.text = CardEffects.random_pool_text(pid, 0)


## 技能预览行：名称（花费 N PP，每回合一次，目标：X）：效果1 → 效果2
func _skill_line() -> String:
	var name := _skill_name_edit.text.strip_edges()
	if name == "":
		name = "未命名技能"
	var bits := PackedStringArray()
	var cost := int(_skill_cost_spin.value)
	bits.append("免费" if cost <= 0 else "%d PP" % cost)
	if _skill_once_check.button_pressed:
		bits.append("每回合一次")
	bits.append("目标：%s" % CardData.TARGET_NAMES.get(_skill_target_option.selected, "—"))
	var body := ""
	if _skill_editor != null:
		body = _chain_text(_skill_editor.chain())
	if body == "":
		body = "（还没有效果）"
	return "%s（%s）：%s" % [name, ", ".join(bits), body]


# ------------------------------ 效果预览 ------------------------------

func _update_preview() -> void:
	if _effect_preview == null:
		return
	var battlecry: Array[Dictionary] = []
	var deathrattle: Array[Dictionary] = []
	if _battlecry_editor != null:
		battlecry = _battlecry_editor.chain()
	if _death_editor != null:
		deathrattle = _death_editor.chain()
	var lines := PackedStringArray()
	var bc_text := _chain_text(battlecry)
	if bc_text != "":
		lines.append("效果链（战吼 / 法术 / 安放）：" + bc_text)
	var dr_text := _chain_text(deathrattle)
	if dr_text != "":
		lines.append("亡语链：" + dr_text)
	if _skill_check != null and _skill_check.button_pressed:
		lines.append("技能：" + _skill_line())
	var invoke: Dictionary = _invoke_map()
	if not invoke.is_empty():
		var probe := CardData.new()
		probe.invocation = invoke
		var itext := probe.invoke_text()
		if itext != "":
			lines.append(itext)
	# 融合：手牌里吃掉材料 → 获得效果 / 化身
	var fusion_spec := _fusion_to_dict()
	if not fusion_spec.is_empty():
		var fprobe := CardData.new()
		fprobe.fusion = fusion_spec
		var ftext := fprobe.fusion_text()
		if ftext != "":
			lines.append("融合：" + ftext)
	# 主战者效果：把清单里的每一条写成人话（改控件 / 改效果链都实时刷新）
	_leader_flush()
	for row in _leader_rows:
		var ltext := LeaderEffects.text(row)
		if ltext != "":
			lines.append("主战者效果：" + ltext)
	# 触发效果：同样逐条写成人话
	_trigger_flush()
	for row in _trigger_rows:
		var ttext := CardTriggers.text(row)
		if ttext != "":
			lines.append("触发：" + ttext)
	_effect_preview.text = "\n".join(lines)


## 整链文本（按顺序）：由规则层的 CardData.chain_text() 生成
func _chain_text(chain: Array) -> String:
	if chain.is_empty():
		return ""
	if _text_probe == null:
		_text_probe = CardData.new()
	return _text_probe.chain_text(chain)


# ------------------------------ 表单 -> 数据 ------------------------------

func _form_to_data() -> CardData:
	var d := CardData.new()
	d.id = "" if _is_new else _id_edit.text.strip_edges()
	d.card_name = _name_edit.text.strip_edges()
	d.cost = int(_cost_spin.value)
	d.card_type = _type_option.selected
	d.rarity = clampi(_rarity_option.selected, 0, CardData.RARITY_NAMES.size() - 1)
	d.deck_limit = clampi(int(_copies_spin.value), 0, CardDB.MAX_COPIES_LIMIT)
	d.attack = int(_attack_spin.value)
	d.health = int(_health_spin.value)
	# 效果链 / 亡语链 / 主动技能：按**行的当前顺序**写回（链是规则层结算的唯一来源）
	var battlecry: Array[Dictionary] = _battlecry_editor.chain()
	var deathrattle: Array[Dictionary] = _death_editor.chain()
	d.effects = battlecry
	d.deathrattle_effects = deathrattle
	d.skill = _skill_map()
	d.invocation = _invoke_map()
	# 融合：勾选后才写字典（空字典 = 没有融合，老卡表不受影响）
	d.fusion = _fusion_to_dict()
	_leader_flush()
	d.leader_effects = _leader_rows.duplicate(true)
	# 触发效果：清单就是唯一事实来源（空清单 = 这张卡没有触发效果）
	_trigger_flush()
	d.triggers = _trigger_rows.duplicate(true)
	# 旧字段镜像：保持 _form_to_data() 的既有行为（回归测试依赖 effect_id 被原样保留），
	# 取链里第一条真实效果写一份 effect_id / value / target / deathrattle_id / death_value。
	var primary := _primary_entry(battlecry)
	d.effect_id = str(primary.get("id", CardEffects.NONE))
	d.effect = maxi(0, CardData.LEGACY_EFFECT_IDS.find(d.effect_id))
	d.value = int(primary.get("value", 0))
	d.target = int(primary.get("target", CardData.Targeting.NONE))
	d.token_id = _first_token(battlecry, deathrattle)
	var dead := _primary_entry(deathrattle)
	d.deathrattle_id = str(dead.get("id", CardEffects.NONE))
	d.deathrattle = maxi(0, CardData.LEGACY_EFFECT_IDS.find(d.deathrattle_id))
	d.death_value = int(dead.get("value", 0))
	# 再按契约让规则层把老字段与链对齐一次（链为空时它什么都不做，不会把老卡改样）
	d.sync_legacy_from_chains()
	d.is_token = _token_check.button_pressed
	# 主战者职业：读不出下拉选中项（异常 / 没选）时按中立处理，绝不让卡牌挂在空职业上
	var picked_class := ""
	if _card_class_option != null and _card_class_option.selected >= 0:
		picked_class = str(_card_class_option.get_item_metadata(_card_class_option.selected))
	d.class_id = CardData.NEUTRAL_CLASS if picked_class in ["", "<null>"] else picked_class
	# 兵种：下拉列出所有已登记兵种（含「中立」）；选「中立」存成 ""，由 troop_of 归一
	d.troop_id = _selected_card_troop()
	# 卡包：下拉里选的是「已登记卡包」；基础卡包存成 ""，由 pack_of 归一
	d.pack_id = _selected_card_pack()
	d.description = _desc_edit.text
	d.color = _color_picker.color
	var kws: Array[int] = []
	for k in _keyword_checks:
		var cb: CheckBox = _keyword_checks[k]
		if cb.button_pressed:
			kws.append(k)
	d.keywords = kws
	return d


## 链里第一条「真实」效果（旧字段镜像用；整条链都是「无效果」时回落到 none）
func _primary_entry(chain: Array) -> Dictionary:
	for e in chain:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = e
		var id := str(entry.get("id", CardEffects.NONE))
		if id != "" and id != CardEffects.NONE:
			return entry
	return {"id": CardEffects.NONE, "value": 0, "target": CardData.Targeting.NONE, "token": ""}


## 旧版单一 token_id 字段：取链里第一条填了**衍生物** ID 的条目（没有则空串）。
## 池 ID / 来源卡牌 ID / 来源范围都填在 token 里，但它们不是衍生物，不写进老字段。
func _first_token(battlecry: Array, deathrattle: Array) -> String:
	for chain in [battlecry, deathrattle]:
		for e in chain:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = e
			if not CardEffects.needs_token(str(entry.get("id", ""))):
				continue
			var token := str(entry.get("token", "")).strip_edges()
			if token != "":
				return token
	return ""


## 链里第一条需要选目标的效果的目标类型（技能目标用它对齐；没有则「不需要目标」）
func _first_need_target(chain: Array) -> int:
	for e in chain:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = e
		var id := str(entry.get("id", CardEffects.NONE))
		if id == "" or id == CardEffects.NONE or CardEffects.is_aoe(id):
			continue
		var declared := CardEffects.default_target(id)
		if declared == CardData.Targeting.NONE:
			continue
		var got := int(entry.get("target", -1))
		return got if got >= 0 else declared
	return CardData.Targeting.NONE


## 瞬念召唤：按卡数据回填（没有 → 收起）
# ------------------------------ 融合（手牌里融合） ------------------------------

func _build_fusion_editor(parent: VBoxContainer) -> void:
	_fusion_check = CheckBox.new()
	_fusion_check.text = "启用融合（这张卡在手牌里吃掉符合条件的手牌）"
	_fusion_check.tooltip_text = "融合 = 手牌操作：消耗材料 → 触发「融合时」词条 → 在手牌中发动效果 → 获得效果 / 化身"
	_fusion_check.toggled.connect(_on_fusion_toggled)
	parent.add_child(_fusion_check)

	_fusion_box = VBoxContainer.new()
	_fusion_box.add_theme_constant_override("separation", 4)
	_fusion_box.visible = false
	parent.add_child(_fusion_box)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	_fusion_box.add_child(grid)

	_fusion_count_spin = _make_spin(1, 3, 1)
	_fusion_count_spin.value = 1
	_fusion_count_spin.tooltip_text = "每融合一次要吃掉几张材料（1–3）"
	_fusion_count_spin.value_changed.connect(func(_v: float) -> void: _update_preview())
	_add_row(grid, "每次材料数", _fusion_count_spin)

	_fusion_troop_option = OptionButton.new()
	_fusion_troop_option.add_item("不限兵种")
	_fusion_troop_option.set_item_metadata(0, "")
	var fti := 1
	for e in CardDB.troops:
		var ftid := str(e.get("id", ""))
		_fusion_troop_option.add_item(str(e.get("name", ftid)))
		_fusion_troop_option.set_item_metadata(fti, ftid)
		fti += 1
	_fusion_troop_option.tooltip_text = "材料必须属于这个兵种（不限 = 任何手牌都能当材料）"
	_fusion_troop_option.item_selected.connect(func(_i: int) -> void: _update_preview())
	_add_row(grid, "材料兵种", _fusion_troop_option)

	_fusion_type_option = OptionButton.new()
	_fusion_type_option.add_item("不限种类")
	_fusion_type_option.set_item_metadata(0, -1)
	for t in CardData.TYPE_NAMES.size():
		_fusion_type_option.add_item(CardData.TYPE_NAMES[t])
		_fusion_type_option.set_item_metadata(t + 1, t)
	_fusion_type_option.tooltip_text = "材料卡的种类（不限 / 随从 / 法术 / 护符 / 城邦）"
	_fusion_type_option.item_selected.connect(func(_i: int) -> void: _update_preview())
	_add_row(grid, "材料种类", _fusion_type_option)

	_fusion_cost_min_spin = _make_spin(0, 10, 1)
	_fusion_cost_min_spin.value = 0
	_fusion_cost_min_spin.value_changed.connect(func(_v: float) -> void: _update_preview())
	_add_row(grid, "材料最低费", _fusion_cost_min_spin)
	_fusion_cost_max_spin = _make_spin(0, 10, 1)
	_fusion_cost_max_spin.value = 10
	_fusion_cost_max_spin.value_changed.connect(func(_v: float) -> void: _update_preview())
	_add_row(grid, "材料最高费", _fusion_cost_max_spin)

	_fusion_transform_edit = LineEdit.new()
	_fusion_transform_edit.placeholder_text = "融合后变成的卡 id（可留空）"
	_fusion_transform_edit.text_changed.connect(func(_t: String) -> void: _update_preview())
	_add_row(grid, "融合后化身", _fusion_transform_edit)

	# 前置条件：读一个量 + 比较符 + 阈值（兵种类量还要选兵种）——与效果链条件同一套
	_fusion_req_metric = OptionButton.new()
	_fusion_req_metric.add_item("（无条件）")
	_fusion_req_metric.set_item_metadata(0, "")
	var rmi := 1
	for mid in EffectConditions.metrics():
		_fusion_req_metric.add_item(EffectConditions.metric_label(mid))
		_fusion_req_metric.set_item_metadata(rmi, mid)
		rmi += 1
	_fusion_req_metric.tooltip_text = "融合的前置条件（例：本局我方离场数 ≥ 3 / 墓地张数 ≥ 5）"
	_fusion_req_metric.item_selected.connect(func(_i: int) -> void: _sync_fusion_req_row())
	_add_row(grid, "融合条件", _fusion_req_metric)

	_fusion_req_op = OptionButton.new()
	for o in EffectConditions.OPS:
		_fusion_req_op.add_item(o)
	_add_row(grid, "条件比较符", _fusion_req_op)

	_fusion_req_value = _make_spin(0, 99, 1)
	_fusion_req_value.value_changed.connect(func(_v: float) -> void: _update_preview())
	_add_row(grid, "条件阈值", _fusion_req_value)

	_fusion_req_troop = OptionButton.new()
	_fusion_req_troop.add_item("（条件不用兵种）")
	_fusion_req_troop.set_item_metadata(0, "")
	var rti := 1
	for e in CardDB.troops:
		var rtid := str(e.get("id", ""))
		_fusion_req_troop.add_item(str(e.get("name", rtid)))
		_fusion_req_troop.set_item_metadata(rti, rtid)
		rti += 1
	_add_row(grid, "条件兵种", _fusion_req_troop)

	_fusion_editor = ChainEditor.new()
	_fusion_box.add_child(_fusion_editor)
	_fusion_editor.setup("融合时在手牌中发动（每融合一次结算一次）", "＋ 添加手牌效果", _update_preview)

	_fusion_gain_editor = ChainEditor.new()
	_fusion_box.add_child(_fusion_gain_editor)
	_fusion_gain_editor.setup("融合后永久获得的效果（之后打出这张卡时按战吼结算）",
		"＋ 添加获得效果", _update_preview)

	var hint := _make_label("融合是**手牌操作**：材料从手牌进墓地，融合卡留在手牌。\n"
		+ "顺序：触发「融合时」词条 → 结算「融合时发动」→ 追加「获得效果」→ 若填了「融合后化身」则整张换成目标卡。\n"
		+ "法术卡不能配融合（法术只有「瞬念召唤 / 被召唤」两个词条大类）。")
	hint.add_theme_color_override("font_color", Color("#90caf9"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fusion_box.add_child(hint)
	_sync_fusion_req_row()


func _on_fusion_toggled(pressed: bool) -> void:
	if _fusion_box != null:
		_fusion_box.visible = pressed
	_update_preview()


## 「条件兵种」只在兵种类量时可用
func _sync_fusion_req_row() -> void:
	var want := false
	if _fusion_req_metric != null and _fusion_req_metric.selected > 0:
		var mid := str(_fusion_req_metric.get_item_metadata(_fusion_req_metric.selected))
		want = EffectConditions.metric_wants_troop(mid)
	if _fusion_req_troop != null:
		_fusion_req_troop.disabled = not want
		if not want:
			_fusion_req_troop.select(0)
	_update_preview()


func _load_fusion(c: CardData) -> void:
	var on: bool = c != null and c.has_fusion()
	_fusion_check.button_pressed = on
	_fusion_box.visible = on
	if _fusion_editor != null:
		_fusion_editor.clear()
	if _fusion_gain_editor != null:
		_fusion_gain_editor.clear()
	if not on:
		_fusion_count_spin.value = 1
		_fusion_troop_option.select(0)
		_fusion_type_option.select(0)
		_fusion_cost_min_spin.value = 0
		_fusion_cost_max_spin.value = 10
		_fusion_transform_edit.text = ""
		_fusion_req_metric.select(0)
		_fusion_req_op.select(EffectConditions.OPS.find(">="))
		_fusion_req_value.value = 0
		_fusion_req_troop.select(0)
		return
	_fusion_count_spin.value = c.fusion_count()
	var f := c.fusion_filter()
	_select_option_meta(_fusion_troop_option, str(f.get("troop", "")))
	_select_option_meta(_fusion_type_option, str(int(f.get("type", -1))))
	_fusion_cost_min_spin.value = int(f.get("cost_min", 0))
	_fusion_cost_max_spin.value = int(f.get("cost_max", 99))
	_fusion_transform_edit.text = c.fusion_transform()
	_fusion_editor.load_chain(c.fusion_effects())
	_fusion_gain_editor.load_chain(c.fusion_gain())
	var req := c.fusion_require()
	var metric := str(req.get("metric", ""))
	if metric == "":
		_fusion_req_metric.select(0)
		_fusion_req_op.select(EffectConditions.OPS.find(">="))
		_fusion_req_value.value = 0
		_fusion_req_troop.select(0)
	else:
		for i in _fusion_req_metric.item_count:
			if str(_fusion_req_metric.get_item_metadata(i)) == metric:
				_fusion_req_metric.select(i)
				break
		_fusion_req_op.select(maxi(0, EffectConditions.OPS.find(str(req.get("op", ">=")))))
		_fusion_req_value.value = int(req.get("value", 0))
		_select_option_meta(_fusion_req_troop, str(req.get("troop", "")))
	_sync_fusion_req_row()


func _fusion_to_dict() -> Dictionary:
	if _fusion_check == null or not _fusion_check.button_pressed:
		return {}
	var tro := ""
	if _fusion_troop_option.selected >= 0:
		tro = str(_fusion_troop_option.get_item_metadata(_fusion_troop_option.selected))
	var t := -1
	if _fusion_type_option.selected >= 0:
		t = int(_fusion_type_option.get_item_metadata(_fusion_type_option.selected))
	var req: Dictionary = {}
	if _fusion_req_metric.selected > 0:
		var metric := str(_fusion_req_metric.get_item_metadata(_fusion_req_metric.selected))
		req = {"metric": metric, "op": EffectConditions.OPS[maxi(0, _fusion_req_op.selected)],
			"value": int(_fusion_req_value.value)}
		if EffectConditions.metric_wants_troop(metric) and _fusion_req_troop.selected > 0:
			req["troop"] = str(_fusion_req_troop.get_item_metadata(_fusion_req_troop.selected))
	return {
		"enabled": true,
		"count": int(_fusion_count_spin.value),
		"filter": {"troop": tro, "type": t,
			"cost_min": int(_fusion_cost_min_spin.value),
			"cost_max": int(_fusion_cost_max_spin.value)},
		"require": req,
		"effects": _fusion_editor.chain() if _fusion_editor != null else [],
		"gain": _fusion_gain_editor.chain() if _fusion_gain_editor != null else [],
		"transform": _fusion_transform_edit.text.strip_edges(),
	}


func _validate_fusion(data: CardData) -> String:
	if not data.has_fusion():
		return ""
	if data.card_type == CardData.CardType.SPELL:
		return "保存失败：法术卡不能配融合（法术只有「瞬念召唤 / 被召唤」两个词条大类）"
	var f := data.fusion_filter()
	if int(f.get("cost_min", 0)) > int(f.get("cost_max", 99)):
		return "保存失败：融合材料的最低费不能高于最高费"
	var req := data.fusion_require()
	if not EffectConditions.is_empty(req):
		if not EffectConditions.has_metric(str(req.get("metric", ""))):
			return "保存失败：融合条件用了未登记的量"
		if not EffectConditions.has_op(str(req.get("op", ""))):
			return "保存失败：融合条件的比较符不合法"
		var troop := str(req.get("troop", ""))
		if troop != "" and not CardDB.has_troop(troop):
			return "保存失败：融合条件用了未登记的兵种「%s」" % troop
	var tr := data.fusion_transform()
	if tr != "":
		var tpl := CardDB.get_card(tr)
		if tpl == null:
			return "保存失败：融合后化身的卡「%s」不存在" % tr
		if not tpl.is_minion():
			return "保存失败：融合后只能化身成随从（「%s」不是随从）" % tr
	var e1 := _validate_chain(data.fusion_effects(), "融合时发动", false)
	if e1 != "":
		return e1
	var e2 := _validate_chain(data.fusion_gain(), "融合获得", false)
	if e2 != "":
		return e2
	return ""


func _load_invoke(c: CardData) -> void:
	var on: bool = c.has_invocation()
	_invoke_check.button_pressed = on
	_invoke_box.visible = on
	if on:
		_invoke_metric_option.selected = _select_invoke_metric(c.invoke_metric())
		var op_idx := InvokeConditions.OPS.find(c.invoke_op())
		_invoke_op_option.selected = op_idx if op_idx >= 0 else InvokeConditions.OPS.find(
			InvokeConditions.default_op(c.invoke_metric()))
		_invoke_value_spin.value = clampi(c.invoke_value(), 0, 30)
		_invoke_timing_option.selected = c.invoke_timing()
		_invoke_dest_option.selected = clampi(c.invoke_dest(), 0, CardData.INVOKE_DEST_NAMES.size() - 1)
		_select_option_meta(_invoke_troop_option,
			c.invoke_troop() if c.invoke_troop() != "" else CardData.NEUTRAL_TROOP)
		if _invoke_editor != null:
			_invoke_editor.load_chain(c.invoke_effect_chain())
	if not on:
		_invoke_metric_option.selected = 0
		_invoke_op_option.selected = InvokeConditions.OPS.find(InvokeConditions.default_op(""))
		_invoke_value_spin.value = 0
		_invoke_timing_option.selected = InvokeConditions.TIME_ANY
		_invoke_dest_option.selected = CardData.InvokeDest.KEEP
		if _invoke_editor != null:
			_invoke_editor.clear()
	# 回填完再决定「条件兵种」那一行要不要露出来（空卡 / 普通量都藏起来）
	_sync_invoke_troop_row()


## 主战者效果：按卡数据回填清单（没有 → 空清单，下面的控件禁用）
func _load_leader_effects(c: CardData) -> void:
	_leader_rows = []
	if c != null:
		for e in c.leader_effects:
			_leader_rows.append(LeaderEffects.normalized(e))
	_leader_selected = 0 if not _leader_rows.is_empty() else -1
	_refresh_leader_list()
	_leader_load_row()


## 触发效果：按卡数据回填清单（没有 → 空清单，下面的控件禁用）
func _load_triggers(c: CardData) -> void:
	_trigger_rows = []
	if c != null:
		for e in c.triggers:
			var spec := CardTriggers.normalized(e)
			if not spec.is_empty():
				_trigger_rows.append(spec)
	_trigger_selected = 0 if not _trigger_rows.is_empty() else -1
	# 先按新卡的种类重建时机下拉（法术只留「瞬念召唤 / 被召唤」），再回填选中项
	_refresh_trigger_event_options()
	_refresh_trigger_list()
	_trigger_load_row()


## 让条件下拉选中指定「量」（未知 / 空 → 落到「（未选择）」）
## （这里**不**像效果那样临时加入下拉项：没登记的量写回卡表后引擎会当没配，
##   与其留个看不见又保存不回来的条目，不如明确指出来由管理员重选。）
func _select_invoke_metric(mid: String) -> int:
	if mid == "":
		return 0
	for i in _invoke_metric_option.item_count:
		if str(_invoke_metric_option.get_item_metadata(i)) == mid:
			return i
	return 0


## 瞬念召唤的「条件兵种」下拉跟着兵种表刷新（新建 / 删除兵种后调用）
func _refresh_invoke_troop_options() -> void:
	if _invoke_troop_option == null:
		return
	var keep := CardData.NEUTRAL_TROOP
	var meta = _invoke_troop_option.get_item_metadata(maxi(0, _invoke_troop_option.selected))
	if meta != null and str(meta) != "":
		keep = str(meta)
	_invoke_troop_option.clear()
	var i := 0
	for e in CardDB.troops:
		var tid := str(e.get("id", ""))
		_invoke_troop_option.add_item(str(e.get("name", tid)))
		_invoke_troop_option.set_item_metadata(i, tid)
		i += 1
	_select_option_meta(_invoke_troop_option, keep)


## 让下拉选中 metadata == value 的那一项（找不到 → 第一项）
func _select_option_meta(option: OptionButton, value: String) -> void:
	if option == null:
		return
	for i in option.item_count:
		var meta = option.get_item_metadata(i)
		if meta != null and str(meta) == value:
			option.select(i)
			return
	# 下拉还是空的（选项还没填进去）时不要 select(0)：Godot 会报
	# 「Index p_which = 0 is out of bounds (popup->get_item_count() = 0)」
	if option.item_count > 0:
		option.select(0)


## 瞬念召唤的保存前检查：勾了就必须挑一个**已登记的量**和一个比较符，
## 并且只有占场地的卡（随从 / 护符 / 城邦）配它才有意义 —— 法术无处可去。
func _validate_invocation(data: CardData) -> String:
	if not bool(data.invocation.get("enabled", false)):
		return ""
	# 法术也可以：在牌库 / 墓地满足条件时**直接发动**或**进入手牌**（不会上场）。
	var mid := str(data.invocation.get("metric", "")).strip_edges()
	if mid == "":
		return "保存失败：启用了瞬念召唤却没有选触发条件，请在「触发条件」里选一个"
	if not InvokeConditions.has_metric(mid):
		return "保存失败：瞬念召唤的触发条件「%s」未注册，请重新选择" % mid
	# 兵种类量必须有兵种，而且得是登记过的（下拉只列已登记的，手改 JSON 才可能带坏 id）
	if InvokeConditions.metric_wants_troop(mid):
		var troop := str(data.invocation.get("troop", "")).strip_edges()
		if troop != "" and not CardDB.has_troop(troop):
			return "保存失败：瞬念召唤的兵种条件用了未登记的兵种「%s」，请先到「兵种」面板创建它" % troop
	var op := str(data.invocation.get("op", "")).strip_edges()
	if not InvokeConditions.has_op(op):
		return "保存失败：瞬念召唤的比较符「%s」不是 %s 之一，请重新选择" % [
			op, " / ".join(InvokeConditions.OPS)]
	# 基础机制（去向）**必选**，不能为空
	var dest := int(data.invocation.get("destination", CardData.InvokeDest.KEEP))
	if dest < 0 or dest >= CardData.INVOKE_DEST_NAMES.size():
		return "保存失败：请为瞬念召唤选一个「基础机制（去向）」（%s）" % " / ".join(
			CardData.INVOKE_DEST_NAMES)
	return ""


# ------------------------------ 操作 ------------------------------

func _on_new_pressed() -> void:
	_new_card()


func _on_save_pressed() -> void:
	var data := _form_to_data()
	if data.card_name == "":
		_set_status("保存失败：卡牌名称不能为空")
		return
	# 效果链 / 亡语链 / 技能：未知效果 ID、缺衍生物 ID、目标错配都在**写入前**拦下
	# （坏数据不进卡表，卡表里的旧数据也不会被这次保存改坏）
	var chain_err := _validate_chain(data.effects, "战吼 / 法术效果链", true)
	if chain_err != "":
		_set_status(chain_err)
		return
	# 亡语的目标由引擎自动推导（与 CardDB 的配置自检同一口径），只查效果 ID 与衍生物
	var death_err := _validate_chain(data.deathrattle_effects, "亡语链", false)
	if death_err != "":
		_set_status(death_err)
		return
	var skill_err := _validate_skill(data.skill)
	if skill_err != "":
		_set_status(skill_err)
		return
	var invoke_err := _validate_invocation(data)
	if invoke_err != "":
		_set_status(invoke_err)
		return
	# 主战者效果：结构（赋予时机 / 监听事件 / 持续回合）+ 每条的效果链
	var leader_err := _validate_leader_effects()
	if leader_err != "":
		_set_status(leader_err)
		return
	# 触发效果：时机必须已登记 + 每条的效果链
	var trigger_err := _validate_triggers()
	if trigger_err != "":
		_set_status(trigger_err)
		return
	var fusion_err := _validate_fusion(data)
	if fusion_err != "":
		_set_status(fusion_err)
		return
	if _is_new:
		if not CardDB.add_card(data):
			_set_status("保存失败：无法写入卡牌存档（磁盘不可写？），本次改动未生效")
			return
		_is_new = false
		_id_edit.text = data.id
		_set_status("已新增卡牌：%s（ID %s）%s" % [data.card_name, data.id, _config_note(data.id)])
	else:
		if not CardDB.has_id(data.id):
			_set_status("保存失败：找不到 ID 为 %s 的卡牌" % data.id)
			return
		if not CardDB.update_card(data.id, data):
			_set_status("保存失败：无法写入卡牌存档（磁盘不可写？），本次改动未生效")
			return
		_set_status("已保存修改：%s%s" % [data.card_name, _config_note(data.id)])
	# 存档成功后 CardDB 会发出 database_changed → _refresh_list 已刷新，这里不再重复刷新


## 一条效果链的保存前检查（全部通过返回空串）
##   * 未知效果 ID；* 召唤类效果缺衍生物 ID / 衍生物不存在；
##   * 目标错配（沿用既有口径：单体效果配成「不需要目标」就拦下）。
## `check_target` = false 时跳过目标检查（亡语的目标由引擎自动推导）。
func _validate_chain(chain: Array, label: String, check_target: bool) -> String:
	for i in chain.size():
		if typeof(chain[i]) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = chain[i]
		var id := str(entry.get("id", CardEffects.NONE))
		if id == "" or id == CardEffects.NONE:
			continue
		var where := "%s第 %d 条" % [label, i + 1]
		if not CardEffects.has(id):
			return "保存失败：%s是未知效果 ID「%s」，请重新选择效果（或先在 CardEffects 里注册它）" % [where, id]
		# 条件（可选）：结构必须合法，兵种必须已登记（未登记的兵种不会出现在下拉里，
		# 但旧卡表 / 手改 JSON 可能带一个已删除的兵种）
		var cond := EffectConditions.normalized(entry.get("cond", {}))
		var cond_errs := EffectConditions.errors(cond)
		if not cond_errs.is_empty():
			return "保存失败：%s的条件不合规（%s）" % [where, "；".join(cond_errs)]
		var cond_troop := str(cond.get("troop", ""))
		if cond_troop != "" and not CardDB.has_troop(cond_troop):
			return "保存失败：%s的条件用了未登记的兵种「%s」，请先到「兵种」面板创建它" % [where, cond_troop]
		var token := str(entry.get("token", "")).strip_edges()
		if CardEffects.needs_token(id):
			if token == "":
				return "保存失败：%s「%s」需要填写衍生物 ID（如 t001）" % [where, CardEffects.display_name(id)]
			if not CardDB.has_id(token):
				return "保存失败：衍生物 ID「%s」不存在，请先在卡表中创建它" % token
		# 随机能力：同一条 token 字段填的是能力池 ID
		if CardEffects.needs_pool(id):
			if token == "":
				return "保存失败：%s「%s」需要选择随机能力池（先到左侧「随机能力池」面板建一个）" % [
					where, CardEffects.display_name(id)]
			if not AbilityPools.has(token):
				return "保存失败：%s 的随机能力池「%s」不存在，请先在「随机能力池」面板创建它" % [where, token]
		# 赋予技能 / 能力：token 是**来源卡牌 ID**，来源必须存在，而且确实带技能 / 触发能力
		if CardEffects.needs_card_ref(id):
			if token == "":
				return "保存失败：%s「%s」需要选择来源卡牌（填卡表里的卡牌 ID）" % [
					where, CardEffects.display_name(id)]
			var src := CardDB.get_card(token)
			if src == null:
				return "保存失败：%s 的来源卡牌「%s」不存在" % [where, token]
			if id == CardEffects.GRANT_SKILL and not src.has_skill():
				return "保存失败：%s「%s」的来源卡牌「%s」没有主动技能" % [
					where, CardEffects.display_name(id), src.card_name]
			if id == CardEffects.GRANT_ABILITY and not src.has_triggers():
				return "保存失败：%s「%s」的来源卡牌「%s」没有触发能力" % [
					where, CardEffects.display_name(id), src.card_name]
		# 随机获得技能 / 能力 / 效果：token 是**来源范围**（board / hand / pack:xxx ...）
		if CardEffects.needs_scope(id):
			var scope_err := CardEffects.scope_error(token)
			if scope_err != "":
				return "保存失败：%s「%s」：%s" % [
					where, CardEffects.display_name(id), scope_err]
		# 牌库 / 手牌改造：token 是「区域|目标」复合参数
		if CardEffects.needs_spec(id):
			var spec_err := CardEffects.spec_error(id, token)
			if spec_err != "":
				return "保存失败：%s「%s」：%s" % [
					where, CardEffects.display_name(id), spec_err]
		if not check_target or CardEffects.is_aoe(id):
			continue
		var declared := CardEffects.default_target(id)
		var got := int(entry.get("target", -1))
		if got < 0:
			got = declared
		if declared != CardData.Targeting.NONE and got == CardData.Targeting.NONE:
			return "保存失败：%s「%s」需要指定目标，请在目标列中选择（已为你准备默认值：%s）" % [
				where, CardEffects.display_name(id), CardData.TARGET_NAMES[declared]]
	return ""


## 主动技能的保存前检查：启用了技能就必须有实质内容（**PP 花费 0–10 都合法，0 = 免费** +
## 至少一条有效效果），并且技能目标要与技能链里第一条需要选目标的效果一致（与 CardDB 的配置自检同一口径）。
func _validate_skill(skill: Dictionary) -> String:
	if skill.is_empty():
		return ""
	var name := str(skill.get("name", "")).strip_edges()
	var shown := name if name != "" else "未命名技能"
	var chain: Array = skill.get("effects", [])
	if _effective_count(chain) == 0:
		return "保存失败：技能「%s」已启用，但技能效果链里一条效果都没有（至少加一条，或取消勾选「启用主动技能」）" % shown
	var cost := int(skill.get("cost", 0))
	if cost < 0 or cost > GameManager.MAX_MANA:
		return "保存失败：技能「%s」的 PP 花费要在 0–%d 之间（0 = 免费技能；PP 与出牌共用一个资源）" % [
			shown, GameManager.MAX_MANA]
	var chain_err := _validate_chain(chain, "技能效果链", true)
	if chain_err != "":
		return chain_err
	var need := _first_need_target(chain)
	if need != CardData.Targeting.NONE and int(skill.get("target", -1)) != need:
		return "保存失败：技能目标（%s）必须与技能链里需要选目标的那一条一致（应为「%s」）" % [
			CardData.TARGET_NAMES.get(int(skill.get("target", -1)), "未选"),
			CardData.TARGET_NAMES.get(need, "—")]
	return ""


## 链里有多少条「真实」效果（全是「无效果」时为 0）
func _effective_count(chain: Array) -> int:
	var n := 0
	for e in chain:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var id := str((e as Dictionary).get("id", CardEffects.NONE))
		if id != "" and id != CardEffects.NONE:
			n += 1
	return n


## 保存后把这张卡自己的配置问题显示在状态栏（比如效果与目标不匹配）
func _config_note(card_id: String) -> String:
	for e in CardDB.config_errors():
		if e.begins_with(card_id + "「"):
			return "　⚠ " + e
	return ""


func _on_delete_pressed() -> void:
	var selected := _list.get_selected_items()
	if selected.is_empty():
		_set_status("请先选中一张卡牌再删除")
		return
	var index: int = selected[0]
	var id := str(_list.get_item_metadata(index))
	var card := CardDB.get_card(id)
	if card == null:
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "删除卡牌"
	dialog.dialog_text = "确定要删除卡牌「%s」吗？该卡牌会从双方牌库 / 手牌 / 战场中移除。" % card.card_name
	dialog.ok_button_text = "删除"
	dialog.cancel_button_text = "取消"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		if not CardDB.remove_card(id):
			_set_status("删除失败：无法写入卡牌存档（磁盘不可写？），该卡牌仍然存在")
			dialog.queue_free()
			return
		_set_status("已删除卡牌：%s%s" % [card.card_name, _orphan_token_note(card)])
		_new_card()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


## 删除衍生物后提醒哪些卡还在召唤它（这些卡会静默失效）
func _orphan_token_note(deleted: CardData) -> String:
	var affected := PackedStringArray()
	for c in CardDB.cards:
		if _card_uses_token(c, deleted.id):
			affected.append(c.card_name)
	if affected.is_empty():
		return ""
	return "。注意：%s 仍以它为衍生物，请修改这些卡" % ", ".join(affected)


## 这张卡是否（旧字段或任意效果链 / 技能链里）以 token_id 作为衍生物
func _card_uses_token(c: CardData, token_id: String) -> bool:
	if c.token_id == token_id:            # 旧字段（新卡也会镜像一份，见 _form_to_data）
		return true
	for chain in [c.effect_chain(), c.deathrattle_chain(), c.skill_chain()]:
		for e in chain:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var eid := str((e as Dictionary).get("id", ""))
			# 赋予技能 / 能力 / 随机获得类 / 牌库改造的 token 不是衍生物：不参与「删衍生物」提示
			if CardEffects.needs_card_ref(eid) or CardEffects.needs_scope(eid) \
					or CardEffects.needs_spec(eid):
				continue
			if str((e as Dictionary).get("token", "")) == token_id:
				return true
	return false


func _on_reset_pressed() -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "恢复默认卡表"
	dialog.dialog_text = "将丢弃所有管理员改动，恢复为项目内置的初始卡牌，确定继续？"
	add_child(dialog)
	dialog.confirmed.connect(func() -> void:
		if not CardDB.reset_to_default():
			_set_status("恢复失败：内置默认卡表不可用，已保留当前卡表")
		else:
			_set_status("已恢复为默认卡表（原卡表已备份为 cards.json.bak）")
		_new_card()
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()


func _on_logout_pressed() -> void:
	AdminAuth.logout()


func _on_close_requested() -> void:
	closed.emit()
	queue_free()


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
