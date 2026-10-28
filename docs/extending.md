# 扩展指南：不改内核，给游戏加东西

> 面向「下次优化游戏」的人（包括未来的你）。所有扩展点都在这里；
> 本文里的路径都是相对项目根目录的 `res://` 路径。
> 约定：**能靠丢文件解决的事，就不该改代码**。

目录：

1. [扩展包（mods/）—— 一次把机制 / 卡牌 / 美术 / 语音 / 特效全接进来](#1-扩展包mods)
2. [加一个机制（关键字）](#2-加一个机制关键字)
3. [加一条卡牌效果](#3-加一条卡牌效果)
4. [加一个触发时机（照影之诗的誘発能力）](#4-加一个触发时机)
5. [加一个条件指标（觉醒 / 共鸣 / 复仇这类判定）](#5-加一个条件指标)
6. [加卡图 / 卡背 / 特效（只改文件名）](#6-加卡图--卡背--特效)
7. [加语音（通用音效 + 卡牌语音）](#7-加语音)
8. [加表现动画](#8-加表现动画)
9. [自检与测试](#9-自检与测试)

---

## 1. 扩展包（mods/）

在 `mods/<包名>/`（或 `user://mods/<包名>/`，后者适合给玩家单独发补丁）放一个 `mod.json`：

```json
{
  "id": "example",
  "name": "示例扩展包",
  "version": "1.0",
  "enabled": true,
  "cards": ["cards.json"],
  "mechanics": ["mechanics.gd"],
  "vfx": [{ "id": "starlight", "name": "星辰", "color": "#7dd3fc" }],
  "card_voice_dirs": ["card_voice"],
  "card_art_dir": "card_art",
  "card_back": "card_back.png",
  "background": "bg.png",
  "voice_dirs": ["voice"],
  "voice_map": "voice_map.json"
}
```

| 字段 | 作用 |
| --- | --- |
| `id` | 唯一 id；重复时**后发现的覆盖先发现的**（`user://mods` 优先于 `res://mods`） |
| `enabled` | `false` = 临时禁用这个包（不用删文件） |
| `cards` | 卡牌 JSON **数组**文件（格式同 `data/default_cards.json`，可用简写键 `name` / `type` / `desc` / `pack`） |
| `mechanics` | GDScript 文件，见第 2、3 节 |
| `mechanic_defs` | 免代码的声明式机制（只能配引擎内置标志位），形如 `{"key":"x","name":"X","desc":"…","flags":[]}` |
| `vfx` | 追加出牌特效（id / 显示名 / 颜色） |
| `card_voice_dirs` | 追加「按卡 id 的语音目录」 |
| `card_art_dir` | 追加「按卡 id 命名的卡图目录」 |
| `voice_dirs` | 追加通用音效目录（文件名 = 事件名，覆盖内置事件） |

装载结果看启动日志的 `[Mods] 共装载 N 个扩展包：…`；代码里读 `Mods.report()`。

**扩展包的卡牌不会写进 `user://cards.json`**：删掉扩展包它们就干净地消失，
不会在存档里留下孤儿卡。它们每次启动都由扩展包重新注入。

现成例子：`mods/example/`（5 张卡 + 2 个机制 + 1 条效果 + 2 个特效）。

---

## 2. 加一个机制（关键字）

机制 = **关键字 + 名称 + 说明 + 钩子 + 标志位**，登记一处就自动出现在卡表面板 / 卡面文字里。

### 只在扩展包里加（推荐，不动内核）

```gdscript
# mods/example/mechanics.gd
extends RefCounted

func register(mod) -> void:
    mod.register_mechanic(mod.next_keyword_id(), "追击", "pursuit",
        "攻击随从后，对敌方主战者追加 1 点伤害。",
        {"on_attack": _on_attack}, [])   # 钩子表；空 = 纯登记

func _on_attack(ev: Dictionary) -> void:
    var gm = ev.get("gm")
    var src: BoardUnit = ev.get("source")
    ...
```

卡表里写 `"keywords": ["pursuit"]` 即可生效。

### 加进内核（内置机制，所有人默认都有）

按 README 的「如何新增一个机制（3 步）」，或本项目的实际做法（新增「觉醒」时就是这么做的）：

1. `scripts/CardData.gd`：`enum Keyword` 加一个 ID，并在 `KEYWORD_NAMES` / `KEYWORD_KEYS` 各补一行；
2. `scripts/Mechanics.gd` 的「新增机制就在这里加」区块加一行 `_reg(...)`；
3. 卡表 `keywords` 写 key。

### 引擎会派发的钩子（挂别的名字永远不会被调用）

`modify_damage` / `on_damage_dealt` / `on_damaged` / `on_attack` / `on_death` /
`on_turn_start` / `can_be_targeted`

### 声明式标志位（一行注册，不用写代码）

`cannot_attack`、`no_attack_cost`、`untargetable_by_foe`、`immune_damage`、
`only_one_damage`、`immune_ability_destroy`、`immune_ability_damage`、`immune_collision_damage`

> `Mechanics.audit()` 会校验「枚举 / 注册表 / 名称表 / key 表 / 标志位 / 钩子名」是否一致，
> 写错名字会被自检当场抓住（`tools/ext_arch_test.gd`、`tools/mechanics_api_test.gd` 都会断言它干净）。

### 互斥规则

两个机制同时挂在同一个单位上会互相拆台时，用 `_reg_conflict(A, B)` 登记；
运行时被赋予的那一个会**覆盖**先到的那个。冻结这类非词条状态写在 `Mechanics.status_conflicts()`。

---

## 3. 加一条卡牌效果

效果 = **ID + 名称 + 卡面文本模板 + 默认目标 + 执行函数**，注册后自动获得
卡面文本、悬停详情、管理员面板下拉与 AI 评估。

```gdscript
func register(mod) -> void:
    mod.register_effect("mod_draw_heal", "抽牌并治疗", "抽 {v} 张牌，并为自己的主战者恢复 {v} 点生命",
        CardData.Targeting.NONE, _fx_draw_heal)

func _fx_draw_heal(ctx) -> void:
    var n: int = maxi(1, int(ctx.value))
    ctx.draw(ctx.caster_pid, n)     # 抽牌
    ctx.heal_hero(ctx.caster_pid, n) # 回血
```

`ctx`（`scripts/EffectContext.gd`）提供：`damage_unit / damage_hero / damage_target / heal_unit /
heal_hero / heal_target / buff_unit / kill_unit / summon / summon_copy / trigger_entrance /
copy_unit_to_deck / copy_hand_to_deck / raise_hand_cost / summon_from_deck / draw / add_armor /
add_mana / add_mana_crystal / grant_keyword / freeze_unit / silence_unit / return_to_hand /
ally_minions / enemy_minions / all_minions / random_enemy_minion / random_ally_minion`，
字段 `caster_pid / value / token_id / target / card / source_unit / src / turns`。

文本模板里的 `{v}` 会替换成效果数值；卡面文本与实际结算用的是同一套口径。

---

## 4. 加一个触发时机

触发时机 = 一张卡在某个时刻自动结算一条效果链（影之诗的「誘発能力」）。
数据在卡表的 `triggers` 里：

```json
"triggers": [ { "on": "attack", "effects": [ { "id": "damage_hero", "value": 1 } ] } ]
```

现有时机（`scripts/CardTriggers.gd`）：`play` 入场 / `summon` 被召唤 / `leave` 离场 /
`invoke` 瞬念召唤 / `vanish` 消失 / `turn_start` 我方回合开始 / `turn_end` 我方回合结束 /
`attack` **攻击时** / `damaged` **受到伤害时**。

**加一个新时机 = 两行 + 一个派发点**：

```gdscript
const EV_HEALED := "healed"
_reg_event(EV_HEALED, "被治疗时", CAT_ON_FIELD)
```

然后在 `GameManager` 对应的结算路径上调一次
`CardTriggers.fire_unit(self, pid, unit, CardTriggers.EV_HEALED)`。

---

## 5. 加一个条件指标

条件指标 = 「量 + 比较符 + 阈值」，效果链的每条效果、瞬念召唤、融合条件都能用它。

```gdscript
# scripts/EffectConditions.gd
_reg("own_hero_hp", "我方主战者生命", "<=", func(gm, pid, _troop) -> int:
    var p: PlayerState = gm.get_player(pid)
    return p.hero_hp if p != null else 0)
```

现有指标：兵种进场数（本局 / 本回合）/ 场上该兵种数 / 离场数 / 被破坏数 / 墓地张数 /
墓地该兵种数，以及本轮新增的 **我方主战者生命 / 敌方主战者生命 / 主战者生命上限 /
我方牌库张数 / 我方手牌张数 / 我方场上单位数**。

比较符六种由 `_ops` 统一提供（`<= >= = != < >`），不用为「≤ N」和「≥ N」各写一个 ID。

---

## 6. 加卡图 / 卡背 / 特效

优先级：**按卡 id 命名的文件** ＞ 卡图映射表 ＞ 卡表里的 `art_path` ＞ 散列兜底。

| 素材 | 放哪 | 生效方式 |
| --- | --- | --- |
| 卡图（自备） | `assets/art/card_art/<卡 id>.png` | 丢进去这张卡就换图，不用动卡表 |
| 卡图（扩展包） | 扩展包 `card_art_dir` 里的 `<卡 id>.png` | 同上 |
| 卡图（逆向导入） | `assets/sv/card_art/*.png` + `data/card_art_map.json` | `tools/import_sv_art.gd` 生成映射，**一卡一图** |
| **卡背** | `assets/art/card_back.png` / `assets/sv/card_back.png`，或扩展包 `card_back` | 抽牌堆、敌方手牌、飞牌一起换 |
| 场景背景 | 管理员面板「美术」，或扩展包 `background` | 竞技区背景图 |
| **战场预设** | `assets/art/board/*.png`（png / jpg / webp） | 目录里的**第一张**自动成为竞技区背景（有背景图时竞技区面板自动放半透明把图透出来）；管理员面板里显式选过的背景优先 |
| 出牌特效 | `assets/art/vfx/<特效 id>/`（可放 `color.txt`：一行 `#rrggbb`），或扩展包 `vfx` | 自动出现在管理员面板的「出牌特效」下拉里 |

支持的扩展名：png / jpg / jpeg / webp。

---

## 7. 加语音

### 通用音效（事件音）

放 `assets/art/voice/<事件名>.wav`，或扩展包 `voice_dirs` 里的同名文件。
事件名见 `SoundFx._EVENTS`：`play_card / attack / damage / heal / turn_start / button / draw /
win / lose / error / play / summon / death …`（不在内置表里的事件名也能**绑定并播放**，
只是没有合成音兜底）。

优先级：`assets/sv/voice` ＜ `assets/art/voice` ＜ 扩展包追加的目录（靠后的覆盖靠前的）。
WAV **免 `.import`**：拷进去就能播（`AudioStreamWAV.load_from_file` 兜底）。

### 卡牌语音（按卡）

两种写法，都用 `scripts/CardVoice.gd`（自动加载名 `Voice`）：

1. **目录约定**：`<素材根>/<卡 id>/<事件>*.wav`
   例：`mods/example/card_voice/mod_pursuer/play_01.wav`、`.../attack_01.wav`、`.../attack_02.wav`
   （同一事件多个文件 → 随机挑一个）
2. **显式映射**：`data/voice_map.json` / `user://voice_map.json` / 扩展包 `voice_map`
   ```json
   { "mod_pursuer": { "play": "res://.../a.wav", "attack": "res://.../b.wav" } }
   ```

事件名：`play / summon / attack / death / skill / damage / turn / win / lose`。
没有配语音的卡自动回落到通用音效，**不会报错也不会静音整局**。
开关在设置面板的「卡牌语音」（`GameSettings.card_voice`）。

代码里播放：`Voice.play_or("attack", card.id, "attack")`（语音优先，回落到通用攻击音）。

---

## 8. 加表现动画

对局里的四类卡片操作动画集中在 `scripts/BattleFx.gd`（`Main` 挂了一层）：

| 接口 | 时机 | 表现 |
| --- | --- | --- |
| `play_card(from, to, card)` | 从手牌打出 | 卡面从手牌飞向落点，缩小 + 轻微旋转，落地闪一下 |
| `death(center, size, card)` | 被破坏 / 消失 | 卡面上飘 + 淡出 + 碎裂 + 放射碎片 + 冲击环 |
| `summon(center, size)` | 被效果召唤入场 | 落点扩散光环 + 卡面弹一下 |
| `burst(center, size, color)` | 通用碎裂（无卡面） | 碎片 + 冲击环 |

* 动画用**绝对时钟**推进（低帧率不漂移），并跟随设置里的「动画速度」（0 = 不播、立即完成）；
* `Main` 用「上一帧的随从快照」发现消失 / 新出现的单位，所以**任何来源**的死亡与召唤都会播动画，
  不需要在每个效果实现里手动调用；
* 想在别处播：`battle_fx().play_card(...)`；测试可用 `advance_for_test(秒)` 拨表，不用真等。

抽牌的 0.65s 时序（0.40s 翻牌 + 0.25s 入手）与伤害飘字「卡堆」是照原版逆向复刻的，
见 `scripts/DeckPile.gd` / `scripts/FloatText.gd` 与 `docs/shadowverse-*.md`，改动前请先读那几份报告。

---

## 9. 自检与测试

```powershell
$env:APPDATA = "$env:TEMP\dsh-godot-userdata"     # 受限环境：把 user:// 指到可写目录
$godot = 'D:\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe'
& $godot --path . --headless --log-file "$env:TEMP\t.log" --script res://tools/ext_arch_test.gd
```

| 脚本 | 覆盖 |
| --- | --- |
| `tools/ext_arch_test.gd` | 扩展包装载 / 运行期关键字 / 运行期效果 / 特效 / 卡背 / 卡图映射 / 卡牌语音 / BattleFx / 觉醒 / 新触发时机 / 新条件指标 |
| `tools/mechanics_api_test.gd` | 机制注册表一致性（`Mechanics.audit()`） |
| `tools/smoke_test.gd` | 核心玩法冒烟 |
| `tools/ai_assistant_test.gd` | AI 助手浮窗（配置 / 客户端 / 工具 / 调度 / 界面 / 集成）——见 `docs/ai-assistant.md` |
| `tools/import_sv_art.gd` | 从 `D:\逆向工程` 导入卡图（+ 卡图映射表）与语音 |

改动过界面 / 动画以后，用 `tools/screenshot.gd`、`tools/vfx_screenshot.gd` 存真实渲染截图核对
（需要窗口）。

> AI 助手的接口配置与加工具的方法见 [`docs/ai-assistant.md`](ai-assistant.md)。
