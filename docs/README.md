# 逆向复刻依据（报告目录）

本目录存放「按原版游戏复刻表现层」的**依据报告**。每份报告都从反编译代码里逐条挖出参数，
并标注 `文件:行号` 出处；同时对信息做两类区分：

- **【码】**：C# 代码里 100% 确定的（时长、缓动、公式、常量、调用顺序）；
- **【资源】**：只在 prefab / 贴图 / JSON / AssetBundle 里、反编译代码看不到的部分（已明确列出，避免把猜测当事实）。

| 报告 | 复刻对象 | 对应实现 |
| --- | --- | --- |
| `shadowverse-damage-floattext.md` | 伤害 / 治疗**飘字**与「**卡堆**」（原版 `DamageVfxBase` / `DamageVfx` / `HealingVfx` / `ReflectedDamageVfx`） | [`scripts/FloatText.gd`](../scripts/FloatText.gd)、[`Main._on_amount_shown()`](../scripts/Main.gd) |
| `shadowverse-draw-animation.md` | **抽卡动画**与牌堆（原版 `PlayerDrawCardVfx` / `OpenCardVfx` / `PlayerDrawCardToHandVfx` / `DummyDeckChangeCardVfx` / `SpreadOutVfx` / `HandControlPlayer`） | [`scripts/DeckPile.gd`](../scripts/DeckPile.gd)、[`Main._update_piles()`](../scripts/Main.gd) |
| `shadowverse-battle-ui.md` | **战斗界面布局与控件尺寸**（手牌扇形全套公式与常量、牌堆位置/朝向与假卡偏移、战场格间距、主战者与 PP/EP 面板、状态栏与配色/字号表），并反向验证「原版**没有**横置机制」 | [`Main._layout_hand()`](../scripts/Main.gd)、[`Main._layout_enemy_hand()`](../scripts/Main.gd)、[`Main._update_board()`](../scripts/Main.gd)、[`scripts/DeckPile.gd`](../scripts/DeckPile.gd)、[`scripts/TrackerPanel.gd`](../scripts/TrackerPanel.gd) |

## 一句话结论

- **伤害飘字「卡堆」**：原版 `DamageCount` 是**渲染层级堆叠**（`sortingOrder` 全场自增、从不重置），
  **不是**位置堆叠、也没有排队/错帧 —— 同一帧多次伤害的数字在位置上完全重合，只有前后遮挡关系。
  飘字存活 2.5s、相邻数字等字距 0.26、数字只来自 0-9 的 16 帧图集；≥7 点是「强击」（震屏 + 强打击特效）。
- **抽卡动画**：**0.40s 翻牌（easeOutCirc 位移 / easeOutQuad 旋转 / easeOutExpo 缩放）+ 0.25s 入手
  （easeOutQuad）= 总 0.65s**；牌堆在动画**开始那一帧**就少一张（瞬时，不是等动画结束）；
  翻牌落点用 `num = 宽高比 × 0.9` 的归一化公式（随窗口宽高比自适应）。

## 怎么核对

```powershell
# 行为断言（需窗口）
godot --path . --script res://tools/vfx_shadowverse_test.gd   # 46 项
godot --path . --script res://tools/deck_pile_test.gd         # 26 项（含飞行时间轴）

# 真实渲染截图（需窗口，存到 user:// 并打印绝对路径）
godot --path . --script res://tools/vfx_screenshot.gd         # 飞牌途中 / 7 点强击飘字 / 入手后
```

> 受限环境（`user://` 不可写）可先把 `APPDATA` 指到一个可写目录再运行，例如
> `$env:APPDATA = "$env:TEMP\dsh-godot-userdata"`。

## 有意偏离原版的地方（都在脚本文件头注释里写明）

1. 原版牌堆是「每张牌一个 3D 假卡」（步长 `(-0.1, 0.4, 0.1)`）；本项目沿用 **2D 的「每 5 张一层」** 简化，
   因为按原版比例（0.44% 卡高）算出来只有 0.35px，2D 下看不出厚度。
2. 原版翻牌是 3D 绕 Y 轴旋转到位；2D 用**水平缩放** `abs(1 - 2·flip)` 表现翻面。
3. 原版的数字是 UI 粒子预制体（`cmn_battle_damage_1` / `cmn_battle_heal_1`），粒子参数与图集在资源里；
   本项目用**纯 `_draw()` 逐位绘制数字**复刻同样的排布与节奏，颜色/描边按 2D 可读性调整。
4. 原版音效是 `se_sys_draw` 等外部素材；本项目用 `SoundFx` **代码合成**的事件 `"draw"` 顶上时机。
