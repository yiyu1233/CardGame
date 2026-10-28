extends RefCounted
## 示例扩展包的机制 / 效果注册脚本。
##
## 契约（见 `scripts/ModLoader.gd` 文件头）：
##   * 实现 `register(mod)`（优先）或 `_register()`；
##   * `mod.register_mechanic(id, 名称, key, 说明, 钩子表, 标志位)` —— 登记机制（关键字）
##   * `mod.register_effect(id, 名称, 文本模板, 默认目标, Callable)` —— 登记一条卡牌效果
##   * 想手写 ID 就从 `CardData.MOD_KEYWORD_BASE`（=1000）起往上取，绝不会撞到内置枚举。
##
## 引擎**会派发**的钩子（挂别的名字 = 永远不会被调用，`Mechanics.audit()` 会报错）：
##   modify_damage / on_damage_dealt / on_damaged / on_attack / on_death / on_turn_start / can_be_targeted
##
## 钩子签名 `func(ev: Dictionary) -> void`，`ev` 常用键：
##   gm / source / source_pid / target / target_pid / unit / amount / keyword / hook / allowed
##
## 扩展包自己的状态放 `gm.mod_state`（GameManager 专门留给扩展包的一个字典，
## 不用去改内核字段，联机快照也不会带上它）。


## 扩展包的机制 ID（从 MOD_KEYWORD_BASE 起，绝不与内置 1–15 冲突）
const KW_PURSUIT := CardData.MOD_KEYWORD_BASE + 1   ## 追击
const KW_SOUL_DRAIN := CardData.MOD_KEYWORD_BASE + 2 ## 噬魂


func register(mod) -> void:
	# ---- ① 追击：攻击随从后，对敌方主战者追加 1 点伤害（自己的每回合最多一次）----
	mod.register_mechanic(KW_PURSUIT, "追击", "pursuit",
		"攻击随从后，对敌方主战者追加 1 点伤害（每个自己的回合最多一次）。",
		{"on_attack": _hook_pursuit}, [])

	# ---- ② 噬魂：这张卡死亡时，为你的主战者恢复 2 点生命 ----
	mod.register_mechanic(KW_SOUL_DRAIN, "噬魂", "soul_drain",
		"这张卡被破坏时，为你的主战者恢复 2 点生命。",
		{"on_death": _hook_soul_drain}, [])

	# ---- ③ 效果：抽牌并治疗（演示 register_effect 的 Callable 契约）----
	mod.register_effect("mod_draw_heal", "抽牌并治疗", "抽 {v} 张牌，为主战者恢复 {v} 点生命",
		CardData.Targeting.NONE, _fx_draw_heal)


# ============================== 钩子实现 ==============================

## 追击：只在「攻击随从」之后追加（攻击英雄那一击本身已经是打脸，不重复）
func _hook_pursuit(ev: Dictionary) -> void:
	var gm = ev.get("gm")
	var src: BoardUnit = ev.get("source")
	if gm == null or src == null:
		return
	var target_pid: int = int(ev.get("target_pid", -1))
	if target_pid == src.owner_id:          # target_pid < 0 = 打的随从；等于自己 = 异常
		return
	if _pursuit_used(gm, src):
		return
	_mark_pursuit_used(gm, src)
	gm.log_line("  「%s」追击：对敌方主战者追加 1 点伤害" % src.data.card_name)
	gm.damage_player(1 - src.owner_id, 1)


## 噬魂：死亡时给主战者回血
func _hook_soul_drain(ev: Dictionary) -> void:
	var gm = ev.get("gm")
	var dead: BoardUnit = ev.get("unit")
	if gm == null or dead == null:
		return
	var pid: int = int(ev.get("pid", dead.owner_id))
	gm.log_line("  「%s」噬魂：主战者恢复 2 点生命" % dead.data.card_name)
	gm.heal_player(pid, 2)


## 效果：抽 {value} 张牌，并为自己的主战者恢复等量生命
func _fx_draw_heal(ctx) -> void:
	var n: int = int(ctx.value)
	if n <= 0:
		n = 1
	ctx.draw(ctx.caster_pid, n)
	ctx.heal_hero(ctx.caster_pid, n)


# ============================== 每回合一次的记账（放 gm.mod_state） ==============================

func _pursuit_key(gm, u: BoardUnit) -> String:
	return "%d:%d" % [u.unit_id, int(gm.turn_count)]


func _pursuit_used(gm, u: BoardUnit) -> bool:
	return gm.mod_state.has(_pursuit_key(gm, u))


func _mark_pursuit_used(gm, u: BoardUnit) -> void:
	gm.mod_state[_pursuit_key(gm, u)] = true
