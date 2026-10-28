# 原版 Shadowverse：战斗界面（Battle UI）布局与控件尺寸 逆向报告

> 目的：为在 Godot 4（本项目 `D:\CardGame`）把战斗 UI **重做成原版样式**提供可照抄的布局/尺寸/观感依据。
> **本报告只写界面与控件**（位置、锚点、尺寸、字号、颜色、动画时长与缓动），**不写玩法机制**。
>
> **引用约定**：所有引用路径相对于反编译根目录
> `D:\逆向工程\decompiled\Assembly-CSharp\`（下文直接写 `路径:行号`）。
> 例：`PlayerStatusPanelControl.cs:235` = `D:\逆向工程\decompiled\Assembly-CSharp\PlayerStatusPanelControl.cs` 第 235 行。
>
> **标注**：
> - **【码】** = C# 代码里确定的（坐标、公式、常量、时长、缓动、sprite 名、字号）。
> - **【资源】** = 只在 prefab / 贴图 / 材质 / AssetBundle 里，反编译 `.cs` 看不到；本环境无法打开 bundle，**不做臆测**，只给代码里的线索。
>
> **重要前提（先读 §1）**：原版是 Unity 3D 世界 + NGUI。战斗界面里的坐标**分属两个空间**，物理量纲完全不同。
> 本报告所有数值都**原样保留**并标注所属空间。

---

## 0. 结论速览（TL;DR）

- 战斗界面分三层：**NGUI UI 层**（`BtlUIContainer`，负责状态栏/按钮/PP/EP/墓地·牌库计数）+ **`BtlContainer` 空间**（牌堆、手牌、战场卡，是一套 100~1000 量级的局部坐标）+ **3D 主战者层**（Spine/3D leader，`Battle3DContainer` 空间，量级 0.1~1）。
  - 【码】`SBattleLoad.cs:830-839`（三个容器的创建与父子关系）、`SBattleLoad.cs:576-580`。
- **牌堆**：`CardHolder`（玩家）/`ECardHolder`（敌方）挂在 `BtlContainer` 下，局部坐标 `(950,-190,0)` rotZ **80°** / `(965,180,0)` rotZ **100°**；假卡 mesh 是**每张一个** `sleeve_CardBase`，逐张偏移 `(-0.1,0.4,0.1)*idx`，缩放 `CARD_BASE_STAY_SCALE=(18,18,18)`。
  - 【码】`SBattleLoad.cs:77-85,843-845,1055-1075`
- **手牌**：手牌根（`HandDeck`/`EHandDeck`）localPosition 由 `HandControl` 在构造时写成 `玩家 (500,-510,10)` / `敌方 (-500,530,10)`；每张卡由 `HandTRSCalculator*` 算 TRS，扇形总宽 `W = min(200*(n-1), 700)`，常态缩放 **0.7**、放大态 **1.2**（敌方 1.1）。
  - 【码】`HandControlPlayer.cs:13`、`HandControlEnemy.cs:8`、`HandControl.cs:52`、`HandTRSCalculatorBase.cs:5-7,18-21`
- **牌库/墓地计数**：是状态栏常驻小面板 `StatusPanelAllwaysDisp` 里的 `DeckLabel/DeckIcon`、`GraveLabel/GraveIcon`，**代码里只给了锚点名和动画位移，具体像素尺寸在 prefab**。
  - 【码】`PlayerStatusPanelControl.cs:32-45,116-128,235-245`；【资源】`Prefab/UI/StatusPanelP|StatusPanelE`
- **PP 珠**：一排 **10 颗** `UISprite`（`PPList[10]`），排列在 `PPPanel/PPIcon` 下，三态由 sprite 名区分：**已用/可用 = `battle_icon_cost_on`**、**未用 = `battle_icon_cost_off`**、**未解锁 = alpha 0（隐藏，不换图）**。单珠直径/间距/prefab 内部排列方式 **【资源】**。
  - 【码】`PlayerStatusPanelControl.cs:54,255-287`、`PlayerStatusPanelControl.cs:266,274,283`
- **EP（进化点）**：`EpPanel` 一张底图 + `EpIcon` + `EpList[3]` 三颗 mini 图标；上限 2（先手）/3（后手），数字显示在 `EpLabel`。本项目不实现，仅作对照。
  - 【码】`PlayerStatusPanelControl.cs:59-63,177-227,300-336`、`BattleManagerBase.cs:279-281,1146-1154`
- **战场随从**：**5 格**（不是 7），单格水平间距 **215**，居中排布；场上卡基准缩放 `CARD_BATTLE_SCALE=(1,1,1)`、`CardObj` 局部缩放 `(3.2,3.2,25)`、in-play 参数标签缩放 `0.07`。
  - 【码】`InPlayCardControl.cs:10-18,29-50,107-114`、`SBattleLoad.cs:312-313,369`
- **横置（rest/tap）：原版没有这个机制**。全代码库没有 `IsRest` / 随从绕 Z 轴 90° 的持久状态；唯一的“旋转”是 `CARD_BATTLE_ROTATION = (-10,0,0)`（卡面绕 X 轴前倾 10°）和打出手牌入场时绕 Y 轴 `RotateAdd(-360°, 0.5s, easeOutExpo)` 的**一次性动画**。见 §8。
  - 【码】`Global.cs:413`、`PlayerPlayQueueView.cs:9,54,118`、`PlayQueueViewBase.cs:168`（反向证据：全库 grep `IsRest|SetRotation` 只命中相机/剧情无关代码）

---

## 1. 坐标系与容器（**必须先看，否则数值会误用**）

### 1.1 三层容器

| 容器 | 创建处 | 父节点 | 用途 | 坐标量级 |
|---|---|---|---|---|
| `BtlUIContainer` | `SBattleLoad.cs:830-831` | UIManager root | 状态栏、按钮、PP/EP、箭头、详情面板（NGUI） | NGUI 像素 |
| `BtlContainer` | `SBattleLoad.cs:839` | `Battle3DContainer` | 牌堆、手牌、战场卡、箭头 | 100~1000（**局部单位**） |
| `Battle3DContainer` | `SBattleLoad.cs:834-836` | `GameManager` | 相机、主战者、`CutInContainer`、`SubParticleContainer` | 0.1~1（世界） |
| `CutInContainer` | `SBattleLoad.cs:837-838` | `GameManager` | 动画期间的插画层（layer 31） | UI |

- 【码】`BattleManagerBase.cs:297`（`public GameObject BtlContainer`）、`SBattleLoad.cs:1138-1139`（`Setup(statusPanel, BtlUIContainer, BtlContainer, Battle3DContainer)`）。
- 【码】`HandDeck`/`EHandDeck` 各挂了一个 `UIAnchor`，`uiCamera` 被指到 `Battle3DContainer/Camera`：
  - `SBattleLoad.cs:1107-1110`
  - `BtlContainer` 自身的 `localScale` **代码里没有赋值** → 【资源】`Prefab/Container/_Battle3DContainer`、`m_BtlContainer`。

### 1.2 两个空间的对照（同一屏幕位置的两种写法）

| 元素 | `BtlContainer` 空间（局部） | 3D 世界空间 |
|---|---|---|
| 玩家主战者根 | — | `WIDGET_POSITION (0,-460,30)`（先手侧） |
| 敌方主战者根 | — | `WIDGET_POSITION (0,490,30)` |
| `Class` mesh | — | `CardObj.localScale (80,80,25)` |
| 玩家手牌根 | `(500,-510,10)` | — |
| 敌方手牌根 | `(-500,530,10)` | — |
| 玩家牌堆 | `(950,-190,0)` rotZ 80° | — |
| 敌方牌堆 | `(965,180,0)` rotZ 100° | — |
| 玩家战场根 | `(prefab) + (0,-110,0)` | — |
| 敌方战场根 | `(prefab) + (0,158,0)` | — |

- 【码】`PlayerSpineClassCharacter.cs:7-13`、`EnemySpineClassCharacter.cs:8-14`、`SpineClassCharacter.cs:96-97`、`HandControlPlayer.cs:13`、`HandControlEnemy.cs:8`、`SBattleLoad.cs:79-85`、`InPlayCardControl.cs:16-18`。
- 注意主战者根的 Y 符号：**Z 轴顺序上是「敌方在 +Y、我方在 -Y」**（`EnemySpineClassCharacter.cs:8` vs `PlayerSpineClassCharacter.cs:7`）。

### 1.3 全局基准常量

| 常量 | 值 | 出处 |
|---|---|---|
| `BASE_SCREEN_WIDTH_SIZE` | `1280` | `Global.cs:95` |
| `BASE_SCREEN_HEIGHT_SIZE` | `640` | `Global.cs:97` |
| `ScreenAspect` 默认 | `1.777f` (16:9) | `GameMgr.cs:67` |
| `NormalFieldOfView` | `60` | `Global.cs:431` |
| `WideFieldOfView` | `70` | `Global.cs:432` |
| `WideFieldOfViewAspectRatioThreshold` | `1.5f` | `Global.cs:281` |
| `ASPECT_RATIO_OVER_16_9` | `1.8f` | `Global.cs:283` |
| 战斗层 | `10`；前置 UI `24`；插画 `31`；`SUB_PARTICLES` 12；`BATTLE_UNDER` 15 | `Global.cs:229-241` |

---

## 2. 抽牌堆（牌堆视觉）

### 2.1 常量与位置

```csharp
// SBattleLoad.cs:77-85   【码】
private static readonly Vector3 CARDHOLDER_COLL_SIZE = new Vector3(70f, 90f, 50f);
private static readonly Vector3 PLAYER_CARDHOLDER_POS = new Vector3(950f, -190f, 0f);
private static readonly Vector3 PLAYER_CARDHOLDER_ROT = new Vector3(0f, 0f, 80f);
private static readonly Vector3 ENEMY_CARDHOLDER_POS  = new Vector3(965f, 180f, 0f);
private static readonly Vector3 ENEMY_CARDHOLDER_ROT  = new Vector3(0f, 0f, 100f);
private static readonly Vector3 NOT_CANCEL_COLIDER_SCALE = new Vector3(5f, 4.4f, 25f);
```

| 项目 | 值 | 出处 |
|---|---|---|
| 玩家牌堆根名 | `CardHolder`（tag `CardHolder`） | `SBattleLoad.cs:843` |
| 敌方牌堆根名 | `ECardHolder`（tag `ECardHolder`） | `SBattleLoad.cs:845` |
| 父节点 | `BtlContainer` | `SBattleLoad.cs:1096` |
| 局部位置 / 欧拉角 | 见上表（80°/100° 绕 Z） | `SBattleLoad.cs:1101-1102` |
| `BoxCollider.size` | `(70,90,50)` | `SBattleLoad.cs:77,1097` |
| `BoxCollider.enabled` | **`false`**（设完尺寸立刻关） | `SBattleLoad.cs:1103` |
| `UIGrid.enabled` | **`false`** | `SBattleLoad.cs:1099` |
| `SetActive(true)` | 建根时就开 | `SBattleLoad.cs:1100` |

### 2.2 每张假卡（dummy sleeve）的放置

```csharp
// SBattleLoad.cs:1055-1075   【码】
private Vector3 GetDeckCardLocalPosition(int idx)
    => new Vector3(-0.1f, 0.4f, 0.1f) * idx;

public void AddDeckCard(int idx, Material texture, Vector3 scale, bool isPlayer)
{
    GameObject gameObject = _gameMgr.GetPrefabMgr().CloneObjectToParent(CardBasePool, _btlMgr.Battle3DContainer);
    gameObject.GetComponent<Collider>().enabled = false;                       // 假卡不可点
    gameObject.transform.SetParent(isPlayer ? _btlMgr.CardHolder.transform : _btlMgr.ECardHolder.transform);
    ...
    gameObject.transform.localPosition = GetDeckCardLocalPosition(idx + 1);    // 注意 +1
    gameObject.transform.localRotation = Quaternion.Euler(0f, 0f, 0f);         // 相对牌堆根
    ...
    gameObject.transform.localScale = scale;
    // :1072-1073 材质开关
    component.material.SetFloat("_CullMode", 2f);
    component.material.SetFloat("_ZWriteMode", 1f);
}
```

| 项目 | 值 | 出处 |
|---|---|---|
| 每张偏移 | `(-0.1, 0.4, 0.1) * (idx+1)` | `SBattleLoad.cs:1055-1058,1068` |
| 假卡本地旋转 | `(0,0,0)`（角度继承牌堆根的 Z 旋转） | `SBattleLoad.cs:1069` |
| 假卡缩放 | 普通卡 `Global.CARD_BASE_STAY_SCALE = (18,18,18)`；`sleeve_deckout` 指示卡 ×`0.95` | `Global.cs:409`、`SBattleLoad.cs:865,877` |
| 假卡数量 | `牌库张数 count + 1`（+1 是 deckout 空牌库指示卡） | `SBattleLoad.cs:862-867,874-879` |
| 假卡 mesh | `sleeve_md_Card`（`SleeveMesh`） | `SBattleLoad.cs:840-842` |
| 假卡 prefab | `sleeve_CardBase`（`CardDeco`），节点名改 `CardBase` | `SBattleLoad.cs:840-841` |
| 材质 | `i < count` → 玩家/敌方 sleeve 材质；`i == count` → `sleeve_deckout_M` + 贴图 `sleeve_deckout` | `SBattleLoad.cs:849-851,856,864,874-877` |
| 材质属性 | `_CullMode=2`、`_ZWriteMode=1` | `SBattleLoad.cs:1072-1073` |
| collider | `Collider.enabled=false`（每次 AddDeckCard 都设） | `SBattleLoad.cs:1063` |
| 牌库上限 | `STANDARD_DECK_CARD_NUM_MAX = 40` | `Global.cs:99` |

### 2.3 牌堆的增删表现

| 行为 | 表现 | 出处 |
|---|---|---|
| 抽走一张 | `DummyDeckChangeCardVfx`：把**最前（index 最小）的 active 卡** `SetActive(false)`，瞬时 0 秒 | `DummyDeckChangeCardVfx.cs:19-45` |
| 凭空减 N 张 | `DummyDeckRemoveCardVfx`：从 `非active 数量` 起连续关 N 张 | `DummyDeckRemoveCardVfx.cs:18-29` |
| 加 N 张 | `SBattleLoad.AddDeckCards`：插到 `Count-1` 前，再把后续每张重排为 `lastPos - step(j)` | `SBattleLoad.cs:1077-1092` |
| 开场 | 父节点先 `SetActive(true)`，每张 `iTween.MoveFrom(x=rand(-50,50), y=rand(-50,50), z=-200, time=0.3s, delay=(childCount-i)*0.01s, islocal, easeOutExpo)` | `OpeningVfx.cs:232-237,285-290` |
| 牌库耗尽 | 取 `GetChild(GetMaxDeckCount())`（即 deckout 指示卡）改挂 `BtlContainer`，`MoveTo((180,-100,-500), 1.0s, easeInOutExpo)` + `RotateTo((-10,0,0), 1.0s, easeInOutExpo)`；随后 `MoveTo((500,50,-200), 0.5s, easeInExpo)` + `RotateTo((-10,0,-40), 0.5s, easeInExpo)` + `TweenColor → red`；再 `SetActive(false)` | `PlayerDeckOutVfx.cs:16-32` |
| 敌方同款 | 结束旋转为 `(-10,0,+40)` | `EnemyDeckOutVfx.cs:23,27` |

### 2.4 牌库计数 UI

**没有独立的“牌库数字”控件类**；它就是状态栏常驻面板上的两个 label：

```csharp
// PlayerStatusPanelControl.cs:32-45   【码】序列化字段
private UISprite DeckIconSprite;
private UISprite GraveIconSprite;
private UILabel  DeckLabel;              // 战斗中显示的牌库数
private UILabel  DeckLabelAlwaysDisp;    // 常驻面板上的牌库数
private UILabel  GraveLabel;
private UILabel  GraveLabelAlwaysDisp;
private UILabel  HandCountLabel;
private UILabel  HandCountLabelAlwaysDisp;
private UISprite HandCountIconSpriteAlwaysDisp;

// :235-253   【码】写值（字号/颜色不在这里，来自 prefab）
public void SetDeck(int num)  { DeckLabel.text = num.ToString();  DeckLabelAlwaysDisp.text  = num.ToString(); }
public void SetGrave(int num) { GraveLabel.text = num.ToString(); GraveLabelAlwaysDisp.text = num.ToString(); }
public void SetHandCount(int num) {
    HandCountLabelAlwaysDisp.text = num.ToString();
    Color color = (HandCountLabelAlwaysDisp.color = ClassInfomationUIBase.GetHandCardCountColor(num));
    HandCountIconSpriteAlwaysDisp.color = color;
}
```

| 项目 | 值 | 出处 |
|---|---|---|
| 赋值入口 | `SetDeck(DeckCardList.Count)`、`SetGrave(CemeteryList.Count)`、`SetHandCount(...)` | `OpeningVfx.cs:459-460`、`BattlePlayerBase.cs:1343-1345`、`DeckChangeVfx.cs:14`、`CemeteryChangeVfx.cs:23` |
| 图标 atlas | `"Battle"`（`CommonPanel`、`GraveIcon`、`DeckIcon` 三处都强制换成该 atlas） | `BattlePlayerViewBase.cs:208,222-223` |
| 手牌数颜色 | 0~6 → `HAND_COUNT_S = (1,1,1,1)` 白；7~8 → `HAND_COUNT_M = (255/256, 205/256, 69/256, 1)` 金黄；9 → `HAND_COUNT_L = (213/256, 5/64, 5/64, 1)` 红 | `ClassInfomationUIBase.cs:60-64,332-343` |
| 常驻面板出现动画 | 从 `默认位置 - up*350` 移到默认位置，`0.5s`，`easeInOutExpo` | `PlayerStatusPanelControl.cs:158-167`、`EnemyStatusPanelControl.cs:174-183` |
| 常驻面板显隐开关 | `BattlePlayerViewBase.AlwaysShowStatusPanel => true`（永远常驻） | `BattlePlayerViewBase.cs:170` |
| 隐藏位移量 | `HIDE_X_VALUE = 310`（PP 面板向右 310）；常驻面板 `350` | `PlayerStatusPanelControl.cs:77-81` |
| prefab | 玩家 `Prefab/UI/StatusPanelP`、敌方 `Prefab/UI/StatusPanelE` | `SBattleLoad.cs:579-580,1138-1139` |
| 锚点节点名 | 玩家 `AnchorL`（+ `AnchorB`）、敌方 `AnchorTR`（+ `AnchorB`） | `BattlePlayerViewBase.cs:205`、`PlayerStatusPanelControl.cs:389`、`EnemyStatusPanelControl.cs:396`、`EpPanel` 路径 `AnchorB/EpPanel`（`:210`） |
| `DeckLabel/GraveLabel` 的 **fontSize / 锚点 / 尺寸** | **【资源】** | 线索：文本是纯数字 `ToString()`；图标是 `UISprite`；atlas 名 `Battle` |
| `CommonPanel`（战斗中临时状态栏） | 玩家 localPos `(-140,-160,0)`、敌方 `(-140, +160, 0)`），建好后 `SetActive(false)` | `BattlePlayerView.cs:139`、`BattleEnemyView.cs:37`、`BattlePlayerViewBase.cs:209` |

---

## 3. 双方手牌布置

### 3.1 手牌根与上限

| 项目 | 值 | 出处 |
|---|---|---|
| 玩家手牌根 pos | `HAND_POS_PLAYER = (500,-510,10)` | `HandControlPlayer.cs:13,17` |
| 敌方手牌根 pos | `HAND_POS_ENEMY = (-500,530,10)` | `HandControlEnemy.cs:8,10` |
| 手牌根何时被写入 | `HandControl` 构造时 `Transform.localPosition = BaseHandPos`；另有 `SetHandPosition()` 再次写 | `HandControl.cs:52,135-138` |
| 手牌根节点名 | 玩家 `HandDeck`、敌方 `EHandDeck` | `BattlePlayerView.cs:37`、`BattleEnemyView.cs:11` |
| 手牌 TRS 缓存长度 | `9`（`_cardPos/_cardRot/_cardScale` 都是 `new Vector3[9]`） | `HandControl.cs:56-58` |
| 手牌上限 | **9**（第 10 张直接进墓地） | `BattlePlayerBase.cs:3283-3301`（本项目已有同结论：`docs/shadowverse-draw-animation.md:100`） |
| 排列方式 | `ArrangeType.Fan`（默认）或 `Flat`；`PlayerPrefsWrapper.FIXEDUSE_COST_INFO` 为真时用 Flat | `HandControl.cs:59`、`PlayerHandView.cs:83,89` |
| 观战模式强制 Flat | `IsWatchBattle → type = ArrangeType.Flat` | `HandControlPlayer.cs:39-42` |

### 3.2 共用常量与公式

```csharp
// HandTRSCalculatorBase.cs:5-21   【码】
protected const float HAND_ALL_WIDTH = 700f;   // 扇形总宽上限
protected const float CARD_WIDTH     = 200f;   // 单卡宽 ← 归一化锚点（见 §12）
protected float CalHandAllWidth(int handMax) => Mathf.Min(200f * (handMax - 1), 700f);   // W
```

```csharp
// HandTRSCalculatorBasePlayer.cs:5-47   【码】玩家
protected static readonly Vector3 CARD_ROT   = new Vector3(0f, -5f, 0f);
protected static readonly Vector3 HIDE_SCALE = new Vector3(0.7f, 0.7f, 0.7f);
protected static readonly Vector3 ZOOM_SCALE = new Vector3(1.2f, 1.2f, 1.2f);
protected static readonly Vector3 ZOOM_SCALE_WATCH = new Vector3(1.1f, 1.1f, 1.1f);
protected const float HIDE_POS_Z = 0f;
protected const float HIDE_POS_Y = 40f;
protected const float HIDE_POS_Y_WATCH = 23f;
protected const float ZOOM_POS_Z = -30f;

protected float CalcHandIndexRate(int handMax, int handIndex)
    => (handMax > 1) ? (float)handIndex / (handMax - 1) : 0f;      // rate：左→右 0→1

protected void CalcParam(int handMax, int handIndex, ref float rate, ref float t2, ref float t3)
{
    rate = CalcHandIndexRate(handMax, handIndex);
    t2 = (rate < 0.5f) ? MotionUtils.GetEase(rate*2f,     MotionUtils.EaseType.easeOutQuad) * 0.5f
                       : MotionUtils.GetEase(rate*2f-1f,  MotionUtils.EaseType.easeOutQuad) * 0.5f + 0.5f;
    t3 = 1f - Mathf.Abs(t2 - 0.5f) * 2f;
}
```

```csharp
// HandTRSCalculatorBaseEnemy.cs:5-47   【码】敌方
protected float OPEN_ROT_Y = -3f;              // 仅观战/管理员“明牌”时用
protected float OPEN_NORMAL_POS_Y = -47.5f;
protected float OPEN_ZOOM_POS_OFFSET_Y = -130f;
protected static readonly Vector3 HIDE_SCALE = new Vector3(0.7f, 0.7f, 0.7f);
protected static readonly Vector3 ZOOM_SCALE = new Vector3(1.1f, 1.1f, 1.1f);
protected const float HIDE_POS_Y = -7.5f;
protected const float HIDE_POS_Z = 0f;
protected static readonly Vector3 CARD_ROT = new Vector3(0f, 183f, 0f);   // 敌方卡背朝玩家

protected float CalcHandIndexRate(...) => (handMax > 1) ? 1f - handIndex/(handMax-1) : 0f;  // rate 反向
// t2：左半 easeOutQuad，右半改 easeInQuad（与玩家不同！）；t3 = |t2-0.5|*2
```

### 3.3 玩家手牌 TRS 公式（逐条）

`W = min(200*(n-1), 700)`，`n = handMax`，`rate = i/(n-1)`。

| 状态 | 位置 retPos（相对手牌根；**已含 `_handPos.x`**） | 旋转 retRot（度） | 缩放 |
|---|---|---|---|
| **Fan 常态 Unfocus** | `( _handPos.x + W*0.7*rate - W*0.7*0.5 , 40 , 0 )` | `(0,-5,0)` | `(0.7,0.7,0.7)` |
| **Fan 放大 Focus** | `( W*(1+n*0.04)*rate - W*(1+n*0.04)*0.5 + 130 , t2*40+40 , -30 )` | `(camRot.x, -5, rate*(-1.5n) + 0.75n)` | `(1.2,1.2,1.2)` |
| **Flat 常态 Unfocus** | `( _handPos.x + W*0.7*rate - W*0.7*0.5 , 40 , 0 )`（观战 y=23） | `(0,-5,0)` | `(0.7,0.7,0.7)` |
| **Flat 放大 Focus** | `( W*(1+n*0.05)*rate - W*(1+n*0.05)*0.5 + 65 , 115 , -30 )`（观战 y=64） | `(0,-5,0)` | 观战 `(1.1,1.1,1.1)`，否则 `(1.2,1.2,1.2)` |

- 【码】`HandTRSCalculatorPlayerFan.cs:5-11,32-43`、`HandTRSCalculatorPlayerFlat.cs:5-11,24-44`。
- 注意：**Fan 的放大位置里没有 `_handPos.x`**（是绝对局部坐标）；Flat 放大同样没有。
- Fan 放大旋转里 `camRot.x = _battleCamera.BattleCameraRot.x`（相机 pitch，随场地变）→ `HandTRSCalculatorPlayerFan.cs:41`。
- Fan 的 `130` 是横向外推（把放大卡抬到屏幕中央偏上），Flat 的 `65` 是它的一半。

### 3.4 敌方手牌 TRS 公式

| 状态 | 位置 retPos | 旋转 retRot（度） | 缩放 |
|---|---|---|---|
| **Enemy Fan 常态** | `( _handPos.x + W*0.7*rate - W*0.7*0.5 , -7.5 , 0 )` | `(0,183,0)` | `(0.7,0.7,0.7)` |
| **Enemy Fan 放大** | `( W*rate - W*0.5 , t2*40 - 20 , -35 )` | `(0, 183, -(rate*(-1.5n) + 0.75n) )` | `(1.1,1.1,1.1)` |
| **Enemy Flat 常态** | `( _handPos.x + W*0.7*rate - W*0.7*0.5 , -7.5 , 0 )` | `(0,183,0)` | `(0.7,0.7,0.7)` |
| **Enemy Flat 放大** | `( W*(1+n*0.05)*rate - W*(1+n*0.05)*0.5 - 80 , -130 , -35 )` | `(0,183,0)` | `(1.1,1.1,1.1)` |
| 明牌（`IsAdminWatch`）叠加 | 常态 `pos.y = -47.5`、`rot.y = -3`；放大 `pos.y += -130`、`rot.y = -3` | — | — |

- 【码】`HandTRSCalculatorEnemyFan.cs:5-13,29-50`、`HandTRSCalculatorEnemyFlat.cs:5-11,24-45`、`HandTRSCalculatorBaseEnemy.cs:49-56`。

### 3.5 重排（缓动）

| 对象 | 属性 | 时长 | 缓动 | 出处 |
|---|---|---|---|---|
| 玩家（正常） | move / rotate / scale | `time`（调用方给，常态 0.2s，抽牌入手 0.25s） | `easeOutQuad` | `HandControlPlayer.cs:76,85-86` |
| 玩家（`isNewReplayMoveTurn`） | 直接赋值，无动画 | — | — | `HandControlPlayer.cs:70-82` |
| 每张卡重排前 | `iTween.Stop(gameObject)` + 销毁残留 `iTween` 组件 | — | — | `HandControlPlayer.cs:64-69` |
| `GetIsOnMove()` 的卡 | 跳过，不参与重排 | — | — | `HandControlPlayer.cs:59-63` |
| 敌方（`time > 0`） | move / rotate | `time` | `easeInOutQuad` | `HandControlEnemy.cs:47-48` |
| 敌方（`time > 0`） | scale | `time` | **`easeInExpo`** | `HandControlEnemy.cs:49` |
| 敌方（`time <= 0`） | 直接赋值 | — | — | `HandControlEnemy.cs:52-56` |
| 手牌 Focus/Unfocus | `RearrangeHand(0.2f)` + `WaitVfx(0.2f)` | `0.2s` | — | `HandViewBase.cs:13,124-140` |
| 观战重排 | `WATCH_REARRANGE_TIME = 0.1f` | `0.1s` | — | `HandViewBase.cs:15` |
| 隐藏一张牌后重排 | `0.2f` | `0.2s` | — | `HandViewBase.cs:98` |
| 切换 Fan/Flat | `ChangeArrangeType(type, 0.3f, list)` | `0.3s` | — | `HandViewBase.cs:187` |

**正/背面**：`HandControlPlayer` 在算好的 `_cardRot` 上再加 `CARD_FRONT_ROTATION = (0,0,0)`（可见）或 `CARD_BACK_ROTATION = (0,180,0)`（不可见）。
- 【码】`HandControlPlayer.cs:9-11,80,85,108`。
- 挂载：`AttachCardView` 会把卡 `parent = 手牌根` 并 `SetActive(false)→SetActive(true)`（强制刷新）——`HandControl.cs:62-70`。

### 3.6 手牌上限 9 的超出手牌处理

- 抽到的第 10 张：**不进手牌**，直接从牌堆送墓（`CEMETERY_TYPE.DECK_DRAW_HAND_OVER`）→ `BattlePlayerBase.cs:3283-3301`。
- 手上线在 UI 上的提示：状态栏手牌数 `HandCountLabelAlwaysDisp` 变红（9 张）→ §2.4。

### 3.7 敌方手牌卡背

| 项目 | 值 | 出处 |
|---|---|---|
| 卡背朝向 | `CARD_ROT.y = 183°`（≈180，敌方卡背正对玩家） | `HandTRSCalculatorBaseEnemy.cs:19` |
| 敌方手牌的卡本体 | **同一个 `UnitCard/SpellCard/FieldCard` prefab**，靠 `HandControl` 的 180° 旋转露背面 | `SBattleLoad.cs:881-883`、`HandControlEnemy.cs:54` |
| 敌方卡背贴图/材质 | **【资源】**：`sleeve` 材质（`GetSleeveMaterial(isPlayer)`） | 线索：`CardTemplate.cs:98-99,157,219`（`NormalCardBaseMeshTemp/EvolCardBaseMeshTemp`）、`SBattleLoad.cs:856,868`（`LoadSleeveMaterial`） |
| 敌方手牌卡背 **单独尺寸** | 无独立尺寸，与玩家手牌同 prefab、同 TRS 公式（缩放 0.7 / 1.1） | `HandTRSCalculatorBaseEnemy.cs:11,13,33,44` |

---

## 4. 记牌器 / 牌库与墓地 / EP·PP 显示（状态栏）

### 4.1 状态栏结构

```
StatusPanelP (Prefab/UI/StatusPanelP)         ← AddUIContainerChildPrefab
└─ AnchorL                                    
   └─ StatusPanel             (CommonPanel, SetActive(false))
      ├─ GraveIcon (UISprite, atlas "Battle")
      └─ DeckIcon  (UISprite, atlas "Battle")
└─ AnchorB
   ├─ PPPanel                 ← TizenEndBtn 被挂到这里
   │  └─ PPIcon / PPSprite / PPLabel / PPLineLabel / PPMaxLabel / PPList[10]
   └─ EpPanel  (UISprite) + EpIcon + EpLabel + EpList[3]
└─ AnchorBL                   ← GetClassInfoAnchor()（玩家）
└─ StatusPanelAllwaysDisp    ← 常驻：DeckLabel(+AlwaysDisp) / GraveLabel(+AlwaysDisp) / HandCountLabel(+AlwaysDisp) / HandCountIconSpriteAlwaysDisp
```

- 【码】`BattlePlayerViewBase.cs:199-224`（`AnchorL`/`StatusPanel`/`EpPanel`/`EpIcon` 的查找）、`PlayerStatusPanelControl.cs:14-75`（序列化字段）、`PlayerStatusPanelControl.cs:387-390`（`AnchorBL`）。
- 敌方对应 `AnchorTR`：`EnemyStatusPanelControl.cs:394-397`。

### 4.2 位置常量

| 控件 | 位置 | 出处 |
|---|---|---|
| 玩家 `EpPanel` | `EP_PANEL_POSITION_PLAYER = (-229, -11.29, 0)` | `Global.cs:417` |
| 玩家 `EpPanel` 移出屏幕 | `default + (0,-300,0) + (0,0,50)` | `PlayerStatusPanelControl.cs:101` |
| 玩家 `EpPanel` Zoom(Flat) | `(-229, 28.7, 0)`；Zoom(Fan) `(-229, 47, 0)` | `PlayerHandView.cs:26-30` |
| 玩家 `PPLabel`（英/德语） | `localPosition += (0,11,0)`；同时隐藏 `PPIcon/PPSprite` | `PlayerStatusPanelControl.cs:105-113` |
| 玩家 `PPPanel` 移出屏幕 | `default + (300,0,0)` | `PlayerStatusPanelControl.cs:124` |
| 敌方 `PPPanel` | 默认 `(原 x, 460, 原 z)` | `EnemyStatusPanelControl.cs:119` |
| 敌方 `PPPanel` 移出 | `default + (0,300,0)`（向上） | `EnemyStatusPanelControl.cs:124,263` |
| 敌方 `EpPanel` | `EP_PANEL_POSITION = (235,-90,0)`；Anya 皮肤 `(207,-90,0)` | `EnemyStatusPanelControl.cs:73-75` |
| 敌方 `EpPanel` 移出 | `default + (0, 350, 0)` | `EnemyStatusPanelControl.cs:101` |
| 敌方 `EpPanel` 的父 | 主战者 Spine 节点（`AttachOtherUI`），PP 面板也改挂主战者节点 | `EnemySpineClassCharacter.cs:47-55` |
| `TurnEndBtn` | 挂在玩家 `AnchorB/PPPanel` 下，localPos `(176.8, -7.5, 0)` | `BattlePlayerView.cs:137-138` |
| `TurnEndBtn` 字号 | 常态/回放 `28`，观战 `25`；`TitleLabel.fontSize` | `TurnEndButtonUI.cs:13-15,153-186` |
| `TurnEndBtn` 隐藏位移 | `+x 200`，`0.5s`，`easeInOutExpo` | `TurnEndButtonUI.cs:126` |
| `HandCount` 小面板（非常驻模式用） | 玩家 `(100,40,0)`、敌方 `(-100,-40,0)`；`FIRST_HAND_COUNT=3` | `ClassInfomationUIBase.cs:10,34,42,279-283` |
| `ClassInformation` 面板（倍化/多人） | 玩家 `(100,100)` / `(100,170)`；跨界 `(100,90)`/`(100,150)`；事件模式 `(100,160)`/`(100,230)`；敌方 `(-100,-100)` | `ClassInfomationUIBase.cs:12-40` |
| 双人倍化 | `DOUBLE_INFO_SCALE = (0.8,0.8,0.8)` | `ClassInfomationUIBase.cs:66` |
| Alert 条 | 尺寸 `(505,60)`；label `(462,28)`；玩家 alert `(168.5,70)`、敌方 `(-155,-70)`；label 玩家 `(-231,0)`、敌方 `(231,0)` | `ClassInfomationUIBase.cs:48-58` |

### 4.3 字体 / 字号 / 颜色

| 项 | 值 | 出处 |
|---|---|---|
| 游戏主字体 | `A-OTF-KaiminTuStd-Bold`（`BASE_GAME_FONT_NAME`） | `Global.cs:285,433` |
| 位图字体 | `FOT-TsukuAOldMinPr6-E` | `Global.cs:287` |
| 卡面数字字体 | 通过 `UIManager.getUIBase_CardManager().SetNumberLabelStyle(label, isFoil)` 换成 `_NormalCardFont` / `_PremiereCardFont`（**字体资源名【资源】**） | `UIBase_CardManager.cs:1754-1774` |
| 卡面数字颜色 | `LifeLabelTemp.color = Color.white`、`effectColor = Global.CARD_LABEL_FRAME_HEALTH_COLOR = (0.4,0.2,0.2)`（0-1）；`AtkLabelTemp.color = white`、`effectColor = CARD_LABEL_FRAME_ATTACK_COLOR = (0.2,0.2,0.4)` | `UnitBattleCardView.cs:228-236`、`Global.cs:379-380` |
| 卡面默认文字色 | `CARD_DEFAULT_COLOR = white` | `SBattleLoad.cs:329-330,364-365`、`Global.cs:371` |
| 卡名（字母语言）字号 | `CARD_NAME_SIZE_ALPHABET_LANGUAGE = 32` | `Global.cs:456,652` |
| 卡名位置 | 2D 短名 `(0,109)`、长名 `(10,109)`；3D 短名 `(0,0)`、长名 `(75,0)`；字母语言再 `+(0,10,0)` | `Global.cs:450-455,620-654` |
| 手牌数颜色 | `S` 白 / `M` 金黄 / `L` 红（数值见 §2.4） | `ClassInfomationUIBase.cs:60-64` |
| **状态栏 `DeckLabel` / `GraveLabel` / `PPLabel` / `EpLabel` 的 fontSize** | **【资源】** | 线索：`PlayerStatusPanelControl.cs:14-75` 全是 `[SerializeField]`，prefab 里配 |

### 4.4 状态栏的入场/退场动画（可照抄）

| 动画 | 参数 | 出处 |
|---|---|---|
| PP 面板入场（玩家） | 先放 `default + (300,0,0)`，`MoveTo(default, 0.5s, easeInOutExpo)` | `PlayerStatusPanelControl.cs:216-218` |
| EP 面板入场（玩家） | 先放 `EpPanelOffScreenPosition`，`MoveTo(default, 0.5s, delay 0.1s, easeInOutExpo)` | `PlayerStatusPanelControl.cs:217-219` |
| PP 面板入场（敌方） | 先放 `default + (0,300,0)`，`MoveTo(default, 0.5s, easeInOutExpo)` | `EnemyStatusPanelControl.cs:261-265` |
| EP 面板入场（敌方） | `MoveTo(EpPanelPosition, 0.5s, delay 0.1s, easeInOutExpo)` | `EnemyStatusPanelControl.cs:250-251` |
| 退场 | 反向（`+300` / `+310` / off-screen），`0.5s`，`easeInOutExpo` | `PlayerStatusPanelControl.cs:229-233`、`EnemyStatusPanelControl.cs:268-272` |
| 常驻面板入场 | `-up*350 → default`，`0.5s`，`easeInOutExpo` | `PlayerStatusPanelControl.cs:163-165`、`EnemyStatusPanelControl.cs:179-181` |
| 状态栏变色 | `TweenColor(StatusPanel / DeckLabel / GraveLabel / DeckIcon / GraveIcon, time, color)` | `PlayerStatusPanelControl.cs:378-385` |

---

## 5. 主战者（Class）框

### 5.1 主战者根的位置与锚点（3D 空间）

| 项 | 玩家 | 敌方 | 出处 |
|---|---|---|---|
| `WIDGET_POSITION` | `(0,-460,30)` | `(0,490,30)` | `PlayerSpineClassCharacter.cs:7`、`EnemySpineClassCharacter.cs:8` |
| `WIDGET_OFFSET_TOP` | `171` | `-1162` | `PlayerSpineClassCharacter.cs:11`、`EnemySpineClassCharacter.cs:12` |
| `WIDGET_OFFSET_BOTTOM` | `71` | `195` | `PlayerSpineClassCharacter.cs:9`、`EnemySpineClassCharacter.cs:10` |
| 底部锚 relative | `0`（target = `Battle3DContainer`） | `0.5`（target = `Battle3DContainer/Camera`） | `PlayerSpineClassCharacter.cs:26-32`、`EnemySpineClassCharacter.cs:38-44` |
| 顶部锚 relative | `0`（同上 target） | `1`（同上 target） | 同上 |
| 主战者根 `localPosition` | `Global.CLASS_BATTLE_POSITION_PLAYER = (0,0,0)` | `Global.CLASS_BATTLE_POSITION_ENEMY = (0,0,0)` | `Global.cs:415-416`、`PlayerSpineClassCharacter.cs:114-117`、`EnemySpineClassCharacter.cs:126-129` |
| Spine 本体位置（相对 Class） | `(0,-0.02,-0.17)` | `(0,-0.36,-0.17)` | `PlayerSpineClassCharacter.cs:49-52`、`EnemySpineClassCharacter.cs:57-60` |
| Spine 缩放修正 | `*1.003125` | `x*0.934`（反转时 `-x*0.934`），再 `*1.003125` | `PlayerSpineClassCharacter.cs:79-82`、`EnemySpineClassCharacter.cs:87-94` |
| 敌方卡面翻面旋转 | — | `Quaternion.Euler(0,-180,180)` | `EnemySpineClassCharacter.cs:131-134` |

### 5.2 Class 节点（头像/框）尺寸

```csharp
// CardCreatorBase.cs:374-381   【码】
if (type == CardBasePrm.CharaType.CLASS) {
    cardTypeBuildInfo.localPosition = isPlayer ? new Vector3(0f, -400f, 30f) : new Vector3(0f, 420f, 30f);
    cardTypeBuildInfo.localScale    = Global.CLASS_BATTLE_SCALE;   // (1,1,1)
    cardTypeBuildInfo.localRotation = Quaternion.identity;
    cardTypeBuildInfo.parent        = ins.Battle3DContainer.transform;
}
```

```csharp
// SpineClassCharacter.cs:58-99   【码】
cardTemplate.CardWrapObjTemp = gameObject3;                       // "ClassObj"
GameObject colliderObj = gameObject2.transform.Find("Collider");
GameObject shield = gameObject3.transform.Find("Shield").gameObject;
shield.transform.localPosition = GetShieldPosition();
shield.transform.localScale    = new Vector3(1.5f, 1.5f, 1f);
GameObject frame = ... "cmn_frame_class_1" ...;
frame.transform.localPosition = new Vector3(0f, 0.1f, 0.15f);
frame.transform.localScale    = new Vector3(6.4f, 6.4f, 20.48f);
GameObject lifeIcon = ... sBattleLoad.LifePoolIcon ...;
lifeIcon.transform.localScale = new Vector3(0.5f, 0.5f, 0.5f);
lifeIcon.transform.parent     = shield.transform;
lifeIcon.transform.localPosition = GetLifeIconPosition();          // (0,0,0.1)
gameObject3.transform.localScale = new Vector3(80f, 80f, 25f);     // "ClassObj"
colliderObj.transform.localScale = new Vector3(80f, 80f, 25f);
```

| 项 | 玩家 | 敌方 | 出处 |
|---|---|---|---|
| `Shield`（头像盘/血条底）位置 | `(2,1.7,0)` | `(1.86,0.4,0)` | `PlayerSpineClassCharacter.cs:64-67`、`EnemySpineClassCharacter.cs:72-75` |
| `Shield` 缩放 | `(1.5,1.5,1)` | 同 | `SpineClassCharacter.cs:68` |
| `ClassObj` / `Collider` 缩放 | `(80,80,25)` | 同 | `SpineClassCharacter.cs:96-97` |
| 光环特效 `cmn_frame_class_1` | pos `(0,0.1,0.15)`，scale `(6.4,6.4,20.48)` | 同 | `SpineClassCharacter.cs:87-89` |
| `LifePoolIcon`（生命数字）缩放 | `(0.5,0.5,0.5)`，父 = `Shield` | 同 | `SpineClassCharacter.cs:93-95` |
| `Life` label 位置 | `GetLifeIconPosition() = (0,0,0.1)` | 同 | `PlayerSpineClassCharacter.cs:69-72` |
| 3D 皮肤（非 Spine）主线 | `Class3dCharacterBase.cs:193-196`：`ClassObj`/`Collider` scale `(80,80,25)`、`lifeIcon.scale (0.5,0.5,0.5)`、`Shield scale (1.5,1.5,1)` | 同 | `Class3dCharacterBase.cs:161-196,352-359` |
| 敌方 3D collider 实际尺寸 | `(3.8,3.9,0.2)` | — | `EnemySpineClassCharacter.cs:24`（Spine 分支里改 Collider.size） |
| 头像盘（盾）= **直径** | **【资源】** `md_Encampment_Shield` + `tx_Encampment_Shield` + `mt_Encampment_Shield`；代码只给 `scale (1.5,1.5,1)` | `SpineClassCharacter.cs:64-69` |
| `Class` mesh | `md_Encampment_Base`（Sn 皮肤 `md_Encampment_sn_Base`）+ 子物体 `md_Encampment_outside`；layer 15 / 10 | `SpineClassCharacter.cs:50-57` |
| 敌方头像反转 | 敌方自己的 mesh 上做 `Quaternion.Euler(0,-180,180)` | `EnemySpineClassCharacter.cs:131-134` |
| `ForecastIcon`（预测图标） | 位置 `(0,2,0)`、缩放 `(0.04,0.04,1)` | `PlayerClassBattleCardView.cs:8`、`ClassBattleCardViewBase.cs:36` |
| 敌方 `ForecastIcon` | 位置 `(0,-1.8,0)` | `EnemyClassBattleCardView.cs:8` |

### 5.3 主战者血量数字的刷新与配色

```csharp
// OpeningVfx.cs:427-444   【码】
classBattleCard.BattleCardView.UpdateLife(classBattleCard.Life);
if (classBattleCard.Life < classBattleCard.MaxLife || classBattleCard.MaxLife > classBattleCard.BaseMaxLife) {
    UILabel lifeLabel = classBattleCard.BattleCardView.CardTemplate.LifeLabelTemp;
    lifeLabel.color       = RefreshAttackVfx.GetParameterTextColor(BaseMaxLife, Life, MaxLife);
    lifeLabel.effectColor = RefreshHealthVfx.GetParameterHealthFrameColor(BaseMaxLife, Life, MaxLife);
}
```

- 【码】血量数字是 `CardTemplate.LifeLabelTemp`（`SpineClassCharacter.cs:99`）；写值走 `BattleCardView.UpdateLife`（`BattleCardView.cs:598-601`）。
- 主战者的 `LifeLabelTemp.localScale` 会被 `BattleCardView.ResetTemplate()` 重置为 `LABEL_SCALE_DEFAULT = (0.07,0.07,0.07)`（`BattleCardView.cs:134,380-384`）。
- **【资源】** `LifePoolIcon` prefab（`Prefab/CardDeco/Life`）：`LifeLabel` 的 fontSize、描边、`UISprite` 底色、圆角；代码只给 `scale 0.5` 与父节点 `Shield`。
- 受击时的数值缩放反馈（通用卡面数字也适用）：`1.0 → ×1.43 → 1.0`，上/下各 `0.1s`，`easeOutQuad` / `easeInQuad`——`RefreshCardParamScale.cs:7-11,33-43`。

### 5.4 `CardWrapObject` / `Class` 节点结构（代码可见部分）

```
UnitCard (prefab)                          SBattleLoad.cs:258-371
└─ CardObj                     ← CardWrapObjTemp，localScale (3.2,3.2,25)   :260,312
   ├─ Normal                   ← CardNormalTemp（LODGroup / 卡面 mesh）
   │   ├─ CardBase             ← CardBasePool，CARD_BASE_POS/ROT/SCALE     :301-306
   │   ├─ Life(Clone) → LifeLabel   pos (-1.61,-2.14,0.2) scale SCALE_CARD_ICON (0.4,0.4,1) rotY 180
   │   ├─ Atk(Clone)  → AtkLabel    pos ( 1.63,-2.14,0.2) scale (0.4,0.4,1)   :360-368
   │   └─ Cost(Clone) → CostLabel   pos ( 1.68, 2.12,0.12)                    :335-339
   ├─ NormalField / EvolField  ← FieldNormalMeshTemp / FieldEvolMeshTemp     :263-264
   ├─ Class                    ← 主战者 mesh（`GetCardMeshGameObject` 返回它）:576-579
   ├─ Life(Clone) → LifeLabel  pos ( 22,-24.5,-0.1) scale (9,9,0.5)  ← in-play 用  :319-325
   ├─ Atk(Clone)  → AtkLabel   pos (-22,-24.5,-0.1) scale (9,9,0.5)  ← in-play 用  :353-359
   ├─ Collider      scale (3.2,3.2,25)                                      :265,313
   ├─ NotCancelCollider scale (5,4.4,25)                                    :266,314
   └─ SkillIcon     pos (1.3,1,0.1) scale (0.01,0.01,0)                     :345-351
```

- 【码】全部来自 `SBattleLoad.cs:256-382`（`CreateUnitCardTemplate`）。
- `LabelScaleCache.ScaleDefault` 是标签的“基准缩放”，用于数值变化动画——`RefreshCardParamScale.cs:39`。
- 【资源】卡面正/背 mesh（`md_card_unit` / `md_card_unit_low` / `md_Card_Unit_n` / `md_Card_Unit_e`）、`CardFrame_F_*` / `CardFrame_BTL_*` 材质（青铜/白银/黄金/传说）——`SBattleLoad.cs:19-74,267-273`。

---

## 6. PP 珠（法力水晶）

### 6.1 结构与数量

```csharp
// PlayerStatusPanelControl.cs:54   【码】
[SerializeField] private UISprite[] PPList;      // prefab 里配了 10 个

// :255-287   【码】
public void SetPp(int num, int max, bool isNewReplayMoveTurn = false)
{
    PPLabel.text    = num.ToString();
    PPMaxLabel.text = max.ToString();
    for (int i = 0; i < 10; i++)
    {
        if (i < max) {
            PPList[i].alpha = 1f;
            if (i < num) {                                  // 已解锁且已使用/可用
                PPList[i].spriteName = "battle_icon_cost_on";
                if (i >= m_beforePpNum && !isNewReplayMoveTurn)
                    m_EfcMgrIns.Start(EffectMgr.EffectType.CMN_UI_COST_2, PPList[i].transform.position);
            } else {                                        // 已解锁但未使用
                PPList[i].spriteName = "battle_icon_cost_off";
                if (i < m_beforePpNum && !isNewReplayMoveTurn)
                    m_EfcMgrIns.Start(EffectMgr.EffectType.CMN_UI_COST_3, PPList[i].transform.position);
            }
        } else {
            PPList[i].alpha = 0f;                           // 未解锁：整颗隐藏
        }
    }
    m_beforePpNum = num;
}
```

| 项目 | 值 | 出处 |
|---|---|---|
| PP 珠总数 | **10**（循环上界 `i < 10`，与 `PPList` 长度一致） | `PlayerStatusPanelControl.cs:259` |
| PP 上限 | `PpTotal` clamp 到 `10` | `BattlePlayerBase.cs:2257-2264` |
| PP 容器 | `PPPanel/PPIcon`（`PPLabel`/`PPLineLabel`/`PPMaxLabel`/`PPSprite` 都在 `PPIcon` 下） | `PlayerStatusPanelControl.cs:108`、`BattleEnemy.cs:122` |
| **态 1：已解锁 + 已用（`i < num`）** | sprite `battle_icon_cost_on`，alpha 1 | `:266` |
| **态 2：已解锁 + 未用（`num <= i < max`）** | sprite `battle_icon_cost_off`，alpha 1 | `:274` |
| **态 3：未解锁（`i >= max`）** | **alpha 0**（不换 sprite，整颗淡出） | `:283` |
| 单珠直径、间距、排列（弧线/直线） | **【资源】**：由 prefab 摆放，代码从不设置 `PPList[i].transform.localPosition` | 反证据：`PlayerStatusPanelControl.cs:255-287` 里只设 `alpha` 与 `spriteName` |
| 数字显示 | `PPLabel`（当前 PP）、`PPMaxLabel`（上限）、`PPLineLabel`（分隔线，成组） | `:45-51,257-258` |
| 英/德语的微调 | 隐藏 `PPIcon/PPSprite`，`PPLabel/PPLineLabel/PPMaxLabel` 各 `+ (0,11,0)` | `:105-113`、`EnemyStatusPanelControl.cs:107-115` |
| 敌方 PP 珠 | `EnemyStatusPanelControl.SetPp` **只写两个 label**，不驱动 sprite（敌方不显示珠） | `EnemyStatusPanelControl.cs:294-298` |
| 敌方 PP 面板位置 | `(原 x, 460, 原 z)`，随主战者 Skin 改挂 | `EnemyStatusPanelControl.cs:119,138-150` |
| 敌方 PP 面板相对主战者 | `PP_PANEL_POSITION = (0,-34.22,-29.25)` | `EnemySpineClassCharacter.cs:14,53` |

### 6.2 PP 变化的特效与动画

| 时机 | 表现 | 出处 |
|---|---|---|
| 新一颗珠亮起 | `CMN_UI_COST_2` 特效在**该珠位置**（仅当 `i` 是本回合新增时） | `PlayerStatusPanelControl.cs:267-270` |
| 一颗珠被消耗 | `CMN_UI_COST_3` 特效在该珠位置 | `:275-278` |
| PP 上限提升（回合开始 +1） | `PlayIncreasePpAnimation(oldPp, newPp)`：对该区间每颗珠播 `CMN_UI_COST_4` | `:289-298` |
| PP 数值刷新节奏 | `PpChangeVfx`：`SetPp` → 刷新手牌费用 → `WaitVfx(0.1f)` | `PpChangeVfx.cs:3-18` |
| 回合开始涨 PP | `PpIncreaseVfx`（同类封装） | `Wizard/Battle/View/Vfx/PpIncreaseVfx.cs:3` |

---

## 7. 战场（随从区）与格子

### 7.1 网格：**5 格**，间距 215

```csharp
// InPlayCardControl.cs:10-18,29-50,107-114   【码】
private const int cMax = 5;                                             // 每方最多 5 张
private const float cBaseX = 215f;                                      // 单格水平间距
private readonly Vector3 PLAYER_FIELDCARD_SPACE = new Vector3(0f, -110f, 0f);   // 玩家战场根相对 BtlContainer
private readonly Vector3 ENEMY_FIELDCARD_SPACE  = new Vector3(0f,  158f, 0f);   // 敌方战场根相对 BtlContainer

// 玩家第 i 格（num = 当前张数，居中）
cPos[i] = new Vector3( 215f * i - 215f * (num - 1) / 2f, 0f, 0f);
// 敌方第 i 格
cPos[i] = new Vector3(-215f * i + 215f * (num - 1) / 2f, 0f, 0f);

public static Vector3 CalcPosition(int cardCount, int index, bool isPlayer)
    => isPlayer ? new Vector3( 215f*index - 215f*(cardCount-1)/2f, 0, 0)
                : new Vector3(-215f*index + 215f*(cardCount-1)/2f, 0, 0);

public Vector3 GetOverflowPosition(int index, bool isPlayer)
    => new Vector3((430f + 215f * (index + 1)) * (isPlayer ? 1f : -1f), 0f, 0f);
```

| 项目 | 值 | 出处 |
|---|---|---|
| 战场根节点名 | 玩家 `FieldCard`、敌方 `EFieldCard`（都在 `BtlContainer` 下） | `BattlePlayerView.cs:39`、`BattleEnemyView.cs:13`、`SBattleLoad.cs:214` |
| 战场根相对 `BtlContainer` 的 Y | 玩家 `-110`、敌方 `+158`（在 `SetInPlayPosition` 里写回自己的 localPosition） | `InPlayCardControl.cs:41,45` |
| 单格 X 间距 | `215` | `InPlayCardControl.cs:12,42,46,111,113` |
| 格数上限 | `5`（`cMax`；`SetInPlayPosition` 里 `if (num >= 5) num = 5`） | `InPlayCardControl.cs:10,31-35` |
| 排布方式 | **按当前张数居中**（不是固定 7 个槽位） | `InPlayCardControl.cs:42,46` |
| 溢出位 | `±(430 + 215*(index+1))` | `InPlayCardControl.cs:101-105` |
| 格间移动 | `Mathf.Lerp(localPosition.x → target.x, t)`，**只动 X**，协程时长 `time`，线性 | `InPlayCardControl.cs:78-94` |
| 父节点 | `cardView.Transform.parent = inPlayCardControl.transform` | `InPlayViewBase.cs:115-118` |
| 单随从卡尺寸 | `CardObj.localScale = (3.2,3.2,25)`；`CARD_BATTLE_SCALE = (1,1,1)` | `SBattleLoad.cs:312,369`、`Global.cs:412` |
| 单随从卡朝向 | `CARD_BATTLE_ROTATION = (-10,0,0)`（绕 X 前倾 10°） | `Global.cs:413`、`PlayerPlayQueueView.cs:54,118` |
| 场上参数标签 | `LifeLabel` `(22,-24.5,-0.1)` scale `(9,9,0.5)`；`AtkLabel` `(-22,-24.5,-0.1)` scale `(9,9,0.5)`；**基准缩放 `0.07`** | `SBattleLoad.cs:319-325,353-359`、`BattleCardView.cs:134,382-383` |
| 随从与主战者纵向距离 | 战场根 Y（玩家 `-110`）↔ 主战者根（3D 空间，量级不同）；**两者不在同一空间，必须用 §12 的比例换算，不能相减** | `InPlayCardControl.cs:16`、`PlayerSpineClassCharacter.cs:7` |
| 手牌根 ↔ 战场根 | 玩家手牌 Y `-510`、战场 Y `-110` → **相差 400 局部单位 = 2 个卡宽** | `HandControlPlayer.cs:13`、`InPlayCardControl.cs:16` |

### 7.2 战斗中的进出场 / 死亡表现（界面层）

| 行为 | 表现 | 出处 |
|---|---|---|
| 手牌打出 → 移到中央 | `RotateAdd(y, -360°, 0.5s, easeOutExpo)` + `ScaleTo(CARD_BATTLE_SCALE, 0.5s, easeOutExpo)`；随后进入 `PlayerSummonCardFocusVfx`（`MoveTo((0,-0.2,-1))` + `RotateAdd(y,-360°)` + `ScaleTo(1,1,1)`，`rearrangeTime`＝`0.5s`（普通）或 `0.2s`（加速）） | `PlayQueueViewBase.cs:159-172`、`PlayerPlayQueueView.cs:9,72,124` |
| 打出瞬间的朝向 | `playedCardView.Transform.rotation = Quaternion.Euler(Global.CARD_BATTLE_ROTATION)` | `PlayerPlayQueueView.cs:54,118` |
| 攻击双方上浮 | `iTween.MoveTo(CardWrapObject, z = -100, time 0.1s, islocal, easeOutExpo)` | `BattleEnemyView.cs:121-127` |
| 普通随从入场（不排队） | 卡走 `CutInContainer`（layer 31），再回到战场 | `PlayerPlayQueueView.cs:84-100` |
| 战场重排时长 | `PlayerInplayView.RearrangeInplay(rearrangeTime)`（调用方给；`0.1s` 用于替换，`0.5s` 用于队列） | `PlayerInplayView.cs:10-17`、`InPlayViewBase.cs:101-113` |
| 死亡/退场 | 由 `VfxBase` 系列驱动（具体在 `*Death*Vfx` / `ReturnCardVfx` 等），本报告不展开玩法侧 | — |

---

## 8. 进化点 / EP（**仅作对照，本项目不实现**）

| 项目 | 值 | 出处 |
|---|---|---|
| 是什么 | 「进化」所需的资源点，UI 上是主战者状态栏里的 `EpPanel` | `PlayerStatusPanelControl.cs:20-26,59-63` |
| UI 位置（玩家） | `EpPanel` 默认 `(-229,-11.29,0)`；放大态 `(-229,28.7,0)`（Flat）/ `(-229,47,0)`（Fan）；屏幕外 = `default + (0,-300,0) + (0,0,50)` | `Global.cs:417`、`PlayerHandView.cs:26-30`、`PlayerStatusPanelControl.cs:101` |
| UI 位置（敌方） | `(235,-90,0)`（Anya 皮肤 `(207,-90,0)`）；屏幕外 `+(0,350,0)` | `EnemyStatusPanelControl.cs:73-75,101` |
| 显示元件 | `EpPanel`（`UISprite` 底图）+ `EpIcon`（`UISprite`）+ `EpLabel`（数字，`evo > 0` 时显示）+ `EpList[3]`（3 颗 mini 图标） | `PlayerStatusPanelControl.cs:59-63` |
| 底图 sprite 名 | `battle_evo_{skin?}{uma_|sn_|}base_01`（EP 上限 3）/ `..._base_02`（上限 2） | `PlayerStatusPanelControl.cs:402-420`、`EnemyStatusPanelControl.cs:409-427` |
| 图标 sprite 名 | `battle_icon_evo_on` / `battle_icon_evo_off`（大）、`battle_icon_evo_on_mini` / `battle_icon_evo_off_mini`（小） | `:304-334` |
| 数值范围 | 先手 `FIRST_PLAYER_EP_NUM = 2`，后手 `SECOND_PLAYER_EP_NUM = 3`；`EpLabel` 显示 `evo`（>0 时） | `BattleManagerBase.cs:279-281,1146-1147` |
| 尚未可用的等待回合 | 先手 `FIRST_PLAYER_EVOLVE_WAIT_TURN = 5`，后手 `4` | `BattleManagerBase.cs:283-285,1146-1147` |
| mini 图标局部位置（玩家，上限 3） | `(1,-0.8)` / `(-17.4,-0.8)`；上限 2 用 `(-11,-0.8)` / `(7.5,-0.8)` / `(26.3,-0.8)` | `PlayerStatusPanelControl.cs:186-192,200-206,344-346` |
| mini 图标局部位置（敌方） | `(5.1,-59.2)` / `(23.8,-59.2)`；或 `(17.1,-59.2)` / `(-1.6,-59.2)` / `(-20.2,-59.2)` | `EnemyStatusPanelControl.cs:203-209,223-229,349-351` |
| 变动特效 | 可用 EP +1 → `CMN_UI_EP_5`（每颗）；消耗 → `CMN_UI_EP_6` + SE `SYS_CMN_UI_EP_6` | `PlayerStatusPanelControl.cs:353-376` |
| 入场动画 | 与 PP 面板同时（`0.5s` + `delay 0.1s`，`easeInOutExpo`） | `PlayerStatusPanelControl.cs:217-219`、`EnemyStatusPanelControl.cs:250-251` |

---

## 9. 横置/朝下、形态等状态表现（**重点：原版无“横置”机制**）

### 9.1 结论

> **原版 Shadowverse 没有「把随从横过来」的对应表现。**全代码库搜索 `IsRest` / `RestRotation` / `SetRotation` / 场上卡绕 Z 轴 90° 的持久状态，**均无命中**（`SetRotation` 只出现在相机、剧情流程图、抽卡界面等与战斗棋盘无关的类里：`Wizard/Scenario2/Player/CameraManager.cs:70`、`Wizard/Story/ChapterSelection/FlowChart/NextChapterLine.cs:205`、`TwoPickCardSelectBase.cs:537` 等）。
> 因此**不要把「横置格」硬套成原版机制**——在报告里应把它标为本项目的自主设计。

**反向证据（原版场上卡会出现的“旋转”，全都是一次性动画，不是状态）**：

| 名称 | 值 | 性质 | 出处 |
|---|---|---|---|
| `CARD_BATTLE_ROTATION` | `(-10, 0, 0)` | **常驻朝向**：场上卡（含主战者）绕 X 轴前倾 10°，营造 3D 透视 | `Global.cs:413`、`PlayerPlayQueueView.cs:54,118` |
| 打出手牌的入场旋转 | `RotateAdd(y, -360°, 0.5s, islocal, easeOutExpo)` | **一次性动画**（打出一张牌绕 Y 转一整圈） | `PlayQueueViewBase.cs:168`、`PlayerPlayQueueView.cs:9,72` |
| 手牌常态旋转 | 玩家 `(0,-5,0)`；敌方 `(0,183,0)` | 常驻（扇形/背面朝向） | `HandTRSCalculatorBasePlayer.cs:5`、`HandTRSCalculatorBaseEnemy.cs:19` |
| 手牌扇形额外 Z 轴倾斜 | `= rate*(-1.5n) + 0.75n`（n=手牌数） | 常驻（扇形张角） | `HandTRSCalculatorPlayerFan.cs:41` |
| 卡面/卡背翻转 | 加 `(0,180,0)` | 常驻（是否可见） | `HandControlPlayer.cs:9-11` |
| 复习/取消技能选择时的抖动 | `RotateTo`(0.15s `easeInCubic`) / `(0.2s easeInQuad → 0.5s delay 0.2 easeOutElastic)` | 一次性动画 | `StopSkillSelectVfx.cs:128-129,156` |
| 技能选择中手牌呼吸 | `RotateTo(x=rand(-5,5)°, loopType=pingPong)` | 循环动画 | `SkillSelectHandCardsVfx.cs:172` |
| 敌方攻击时上浮 | `MoveTo(z=-100, 0.1s, easeOutExpo)` | 一次性动画 | `BattleEnemyView.cs:125` |
| 敌方卡整体镜像 | 主战者/卡面 `Quaternion.Euler(0,-180,180)` | 常驻 | `EnemySpineClassCharacter.cs:131-134`、`Class3dCharacterBase.cs:309-312` |

**变异/形态类状态在 UI 上的表现（供参考，不展开玩法）**：
- `EvolveVfx` / `HighRankEvolveVfx`：进化后切到 `NormalAtkLabelTemp` / `NormalLifeLabelTemp`，把 `AtkLabelTemp/LifeLabelTemp` 的父物体关掉——`EvolveVfx.cs:162-209`、`HighRankEvolveVfx.cs:151-199`。
- 形态切换（metamorphose）：`ChangeInPlayViewVfx.cs:12-33` 把 `CardNormalTemp` 关、`FieldNormalMeshTemp` 开，并把 in-play 版 `AtkLabel/LifeLabel`（父物体）打开。
- 形态/进化后的卡牌缩放：`ScaleTo(Global.CARD_BATTLE_SCALE = (1,1,1))`。

---

## 10. 动画时长与缓动总表

| 对象 | 内容 | 时长 | 缓动 | 出处 |
|---|---|---|---|---|
| 手牌重排（玩家） | move/rotate/scale | 调用方（0.2 / 0.25s） | `easeOutQuad` | `HandControlPlayer.cs:76,85-86` |
| 手牌重排（敌方） | move/rotate | 调用方 | `easeInOutQuad` | `HandControlEnemy.cs:47-48` |
| 手牌重排（敌方） | scale | 调用方 | `easeInExpo` | `HandControlEnemy.cs:49` |
| 手牌 Focus/Unfocus | 位移+等待 | `0.2s` | — | `HandViewBase.cs:124-140` |
| Fan↔Flat 切换 | 全列表重排 | `0.3s` | `easeOutQuad` | `HandViewBase.cs:187` + `HandControlPlayer.cs:76` |
| 战场重排 | 只动 X | 调用方（0.1 / 0.5s） | 线性 `Lerp` | `InPlayCardControl.cs:84-93` |
| 打出牌入场 | `RotateAdd(y,-360)` + `ScaleTo(1,1,1)` | `0.5s` | `easeOutExpo` | `PlayQueueViewBase.cs:168-169` |
| 打出牌聚焦（普通/加速） | `MoveTo((0,-0.2,-1))` + rotate + scale | `0.5s` / `0.2s` | `easeOutExpo` | `PlayerPlayQueueView.cs:72,124`、`PlayerSummonCardFocusVfx.cs:13-15` |
| 攻击上浮 | `MoveTo(z=-100)` | `0.1s` | `easeOutExpo` | `BattleEnemyView.cs:125` |
| 数值变化（攻/血/费用） | scale `1 → ×1.43 → 1` | `0.1s` + `0.1s` | `easeOutQuad` / `easeInQuad` | `RefreshCardParamScale.cs:7-11,40-41` |
| PP 刷新 | `SetPp` → 刷新手牌费用 → wait | `0.1s` | — | `PpChangeVfx.cs:17` |
| PP 面板入场 | 平移 | `0.5s` | `easeInOutExpo` | `PlayerStatusPanelControl.cs:218` |
| EP 面板入场 | 平移 | `0.5s` + `delay 0.1s` | `easeInOutExpo` | `PlayerStatusPanelControl.cs:219` |
| 状态栏常驻面板入场 | 平移 `350` | `0.5s` | `easeInOutExpo` | `PlayerStatusPanelControl.cs:165` |
| 状态栏退场 | 平移 | `0.5s` | `easeInOutExpo` | `PlayerStatusPanelControl.cs:231-232` |
| 状态栏变色 | `TweenColor` | 调用方 | — | `PlayerStatusPanelControl.cs:378-385` |
| `TurnEndBtn` 隐藏 | `+x 200` | `0.5s` | `easeInOutExpo` | `TurnEndButtonUI.cs:126` |
| 主战者出场（我方/敌方） | 光圈飞入 → 牌堆散开 → 落位 | `0.4s` / `0.3s`(delay 0.01s×i) / `0.2s` / `0.5s` | `easeInQuad` / `easeOutExpo` / `easeOutQuad` / `easeOutBounce` + `easeOutElastic` | `OpeningVfx.cs:228,236,244-252,281,289,297-305` |
| 牌堆开场散开 | `MoveFrom(x,y ∈ rand±50, z=-200)` | `0.3s`，逐张 `delay = (count-i)*0.01s` | `easeOutExpo` | `OpeningVfx.cs:236` |
| 牌库耗尽 | → `(180,-100,-500)` → `(500,50,-200)` | `1.0s` + `0.5s` | `easeInOutExpo` → `easeInExpo` | `PlayerDeckOutVfx.cs:22,26` |
| 主战者预测图标 | `ForecastIconScale` | — | — | `ClassBattleCardViewBase.cs:36` |
| 卡面选择/取消旋转 | `RotateTo(z=90→0 之类)` | `0.2s` | `easeInOutQuad` | `ChoiceUtility.cs:112` |

---

## 11. 「代码确定」vs「只有资源里才有」

### 11.1 **【码】** 可 100% 照抄

- 所有位置常量：`CardHolder`/`HandDeck`/`FieldCard`/`WIDGET_POSITION`/`EP_PANEL_POSITION_PLAYER`/`CLASS_BATTLE_POSITION_*`（`SBattleLoad.cs:77-85`、`HandControlPlayer.cs:13`、`HandControlEnemy.cs:8`、`InPlayCardControl.cs:16-18`、`Global.cs:406-429`）。
- 手牌全部 TRS 公式与常量（§3.2-3.4）。
- 战场 5 格 × 215 间距、居中公式、溢出位（`InPlayCardControl.cs:10-18,107-114`）。
- 假卡偏移、数量、缩放、材质开关、collider 开关（`SBattleLoad.cs:1055-1075`）。
- 所有时长 + 缓动 + iTween 参数（§10）。
- PP 珠数（10）、三态 sprite 名与 alpha 规则（`PlayerStatusPanelControl.cs:255-287`）。
- EP 大/小图标 sprite 名、mini 位置、数值范围（§8）。
- 手牌数颜色阈值与颜色（`ClassInfomationUIBase.cs:60-64,332-343`）。
- 卡面数字颜色/描边色（`Global.cs:379-380`、`UnitBattleCardView.cs:228-236`）。
- 全局基准分辨率 `1280×640`、相机 FOV 60/70 与宽高比插值（`Global.cs:95-97,431-432`、`BattleManagerBase.cs:1958-1970`）。

### 11.2 **【资源】** 代码看不到

| 项 | 为什么看不到 | 代码里的线索 |
|---|---|---|
| `PPList[i]` 的 **localPosition / 单珠尺寸 / 排列曲线** | prefab `Prefab/UI/StatusPanelP` 里排的；代码只改 `alpha` + `spriteName` | `PlayerStatusPanelControl.cs:54,255-287`（**从不写 localPosition**）；珠图 `battle_icon_cost_on` / `battle_icon_cost_off`（`Battle` atlas） |
| `DeckLabel/GraveLabel/PPLabel/PPMaxLabel/EpLabel/HandCountLabel` 的 **fontSize / 锚点 / 尺寸 / 颜色** | 全是 `[SerializeField]`，prefab 里配 | `PlayerStatusPanelControl.cs:32-75`；文本来自 `num.ToString()`（`PlayerStatusPanelControl.cs:235-253`） |
| `StatusPanelAllwaysDisp` 与 `CommonPanel` 的 **内部布局** | prefab | 节点名 `GraveIcon` / `DeckIcon` / `StatusPanel`（`BattlePlayerViewBase.cs:207,222-223`） |
| 头像盘（`Shield`）的 **直径 / 贴图** | prefab + `md_Encampment_Shield` / `tx_Encampment_Shield` 网格与贴图 | 代码只给 `Shield.localScale=(1.5,1.5,1)`、`ClassObj.scale=(80,80,25)`、位置 `玩家(2,1.7,0)` / `敌方(1.86,0.4,0)`（`SpineClassCharacter.cs:63-97`、`PlayerSpineClassCharacter.cs:64-67`） |
| `LifePoolIcon`（生命数字）**字号 / 底图 / 描边** | `Prefab/CardDeco/Life` prefab | 代码只给 `scale=(0.5,0.5,0.5)`、父 = `Shield`、label 名 `LifeLabel`、位置 `(0,0,0.1)`（`SpineClassCharacter.cs:92-99`） |
| 卡面 `LifeLabel/AtkLabel/CostLabel` 的 **fontSize / 描边宽度 / 位图字体名** | `Prefab/CardDeco/{Life,Atk,Cost}` + `_NormalCardFont` / `_PremiereCardFont` 位图字体 | 代码只给位置/缩放（`SBattleLoad.cs:319-368`）与字体切换 API（`UIBase_CardManager.cs:1754-1774`） |
| `UnitCard` / `SpellCard` / `FieldCard` prefab 的内部层级与 mesh 尺寸 | `CardFrame` asset | 代码只给出节点名（`CardObj` / `Normal` / `Skill` / `NormalField` / `EvolField` / `Collider` / `NotCancelCollider` / `Class`）与缩放（`SBattleLoad.cs:256-539`） |
| `Collider` 的真实尺寸 | `UnitCard` prefab 里 | 代码只覆盖 `localScale = (3.2,3.2,25)`、`NotCancelCollider scale = (5,4.4,25)`（`SBattleLoad.cs:265-266,313-314`） |
| `BtlContainer` 自身 **localScale** | `Prefab/Container/_Battle3DContainer` / serialized `m_BtlContainer` | 从「手牌根 x=500」「战场间距 215」「卡宽 200」的相对比例反推（见 §12） |
| `Battle3DContainer/Camera` 的位置/朝向 | prefab | `BattleCamera.BattleCameraRot` 在运行时从相机读出（`BattleCamera.cs:26-27`）；FOV 由 `ChangeCameraFieldOfView` 覆盖（`BattleManagerBase.cs:1922-1956`） |
| `battle_icon_evo_*` / `battle_icon_cost_*` / `orb_*` 的贴图内容 | atlas `Battle` | 代码只引用 sprite 名（`PlayerStatusPanelControl.cs:266,274,304-334`） |
| `sleeve_*` 牌背贴图与材质 | `SleeveTexture` / `SleeveMaterial` asset | 代码只给 ID 与 `LoadSleeveMaterial`（`SBattleLoad.cs:745-762,856,868`） |

### 11.3 明确的不确定点

1. **`BtlContainer` 的 localScale 未在代码中赋值**：因此 §12 的换算只能用「卡宽 = 200 局部单位」作为唯一锚点，**比例关系可照抄，绝对像素必须自行标定**。
2. **PP 珠的实际排列**：代码从不设置 PP 珠的 localPosition，所以「弧线还是直线」「单珠直径」「间距」全部来自 prefab，本报告无法给出数值。若要做原版观感，需要解包 `UI/Battle` 相关 atlas 与 `Prefab/UI/StatusPanelP`。
3. **`StatusPanelAllwaysDisp` 上 Deck/Grave/HandCount 三组控件的确切相对位置**：只知道**组内 label + icon** 与**整组的入场位移 350**（`PlayerStatusPanelControl.cs:158-167`）。
4. **主战者头像盘尺寸与生命数字字号**：只有 `Shield scale (1.5,1.5,1)` 和 `LifePoolIcon scale 0.5`，没有 diameter / fontSize。
5. **`Class` 节点（`GetCardMeshGameObject` 返回的 `CardWrapObjTemp/Class`）的真实尺寸**：只知道它挂在 `ClassObj`（scale 80）下，mesh 是 `md_Encampment_Base`。
6. **敌方 PP 珠是否真的不显示**：`EnemyStatusPanelControl.SetPp` 只写 label（`EnemyStatusPanelControl.cs:294-298`），`EnemyStatusPanelControl` 的 `[SerializeField]` 里**没有 `PPList`** —— 所以按代码读，敌方 PP 只有数字。若真机截图显示敌方有珠，说明珠在 `PPPanel` prefab 里是静态图（需真机确认）。
7. **卡面标签的 `LabelScaleCache.ScaleDefault`**：由运行时缓存（`RefreshCardParamScale.cs:39`），只知道会被重置为 `LABEL_SCALE_DEFAULT = 0.07`（且**只对 `LifeLabelTemp/AtkLabelTemp`**，`BattleCardView.cs:380-384`）。

---

## 12. 自适应口径与 2D 像素换算建议

### 12.1 原版按什么自适应

| 机制 | 做法 | 出处 |
|---|---|---|
| **屏幕基准** | `BASE_SCREEN_WIDTH_SIZE = 1280`、`BASE_SCREEN_HEIGHT_SIZE = 640`（16:9 基准） | `Global.cs:95-97` |
| **相机 FOV** | `ScreenAspect`（默认 1.777）→ `fieldOfView = clamp((60+70)/2 * (1 - (aspect-1.5)), 60, 70)`，即 **aspect≥1.5 → 60；aspect≤0.5 → 70；中间线性** | `BattleManagerBase.cs:1958-1970`；`GameMgr.cs:67,166`；`WindowResize.cs:302` |
| **战场/队列落点** | 用 `cutInCamera.ScreenToWorldPoint(屏幕角)` 再 `InverseTransformPoint` 到手牌根 → 加宽高比修正 → `TransformPoint` 回去；修正量：`220, -200*(aspect-1) - 50/(aspect-1)`（顶）/ `140, 50/(aspect-1) + 50*(aspect-1)`（底），`aspect` 下限 `1.333` | `PlayQueueViewBase.cs:43-60,141-157`、`PlayerPlayQueueView.cs:138-146` |
| **`BtlContainer` 内部布局** | **不做自适应**：所有坐标是固定局部单位（`CardHolder` 950、手牌 500、间距 215……），靠 `BtlContainer` 的父级缩放 + UIAnchor 落到屏幕 | `SBattleLoad.cs:839,1096-1110`；`BtlContainer.localScale` 未赋值（§11.3） |
| **NGUI 状态栏** | 由 NGUI 自己的 UIRoot/atlas 缩放负责（【资源】） | `PlayerStatusPanelControl.cs:129-133` |
| **手牌 `rate`** | 与屏幕无关，只与手牌张数有关 | `HandTRSCalculatorBasePlayer.cs:26-33` |

### 12.2 换算到本项目 2D 像素的锚点建议

**唯一可靠的锚点**：

```
原版卡宽 = CARD_WIDTH = 200 局部单位            HandTRSCalculatorBase.cs:7
本项目卡宽（现状）= CARD_SIZE = (58, 80) 像素   见 docs/shadowverse-draw-animation.md:924
=> 1 局部单位 ≈ 58 / 200 = 0.29 px   （若按卡高 80 则 80/200 = 0.40 px）
```

按 `1 单位 = 0.29 px` 的映射（仅作**相对比例**参考，绝对位置需按项目屏幕自行定）：

| 原版量 | 局部单位 | ≈ px（0.29×） | 说明 |
|---|---|---|---|
| 卡宽 | `200` | `58` | 锚点 |
| 手牌总宽上限 `W` | `700` | `203` | = 3.5 卡宽 |
| 玩家手牌根 | `x=500, y=-510` | `(145, -148)` | 相对 `BtlContainer` 原点 |
| 敌方手牌根 | `x=-500, y=530` | `(-145, 154)` | |
| 玩家牌堆 | `(950,-190)` | `(276,-55)` | |
| 敌方牌堆 | `(965,180)` | `(280,52)` | |
| 战场根（玩家/敌方） | `y=-110 / +158` | `-32 / +46` | |
| 战场格间距 | `215` | `62` | = 1.075 卡宽 |
| 手牌常态 y | `40` | `12` | |
| Flat 放大 y | `115`（观战 64） | `33` | |
| Fan 放大 y | `t2*40+40` → `40..80` | `12..23` | |
| 手牌 z（放大） | `-30` | — | 3D 景深，2D 可换成 layer/scale |
| 牌堆每张偏移 | `(-0.1, 0.4, 0.1)` | `(-0.03, 0.12, 0.03)` | 主方向 1 : 副方向 0.25 |
| `Shield` 相对位置 | `(2, 1.7, 0)` | `(0.6, 0.5)` | **在 3D 空间（80 缩放）下，实际比看起来大** |

**更推荐的做法（与现有两份报告一致）**：**不照搬绝对像素，只照搬「以卡宽 200 为基准的比例 + 屏幕宽高比归一化」**。
具体：
1. `1u = card_w_px / 200`（约 `0.29`）。
2. 手牌/战场/牌堆的 X 用 `u * 局部单位` 定位到屏幕；Y 建议按 `viewport_height * (局部Y / 960)` 归一化（因为原版 `BtlContainer` 覆盖一屏约 `±720` 局部单位）。
3. 相机/落点类的自适应继续沿用 `aspect` 归一化量（本项目已有 `viewport_aspect * 0.9` 的写法，见 `docs/shadowverse-draw-animation.md:955`）。
4. 扇形的 rotation/弧高**直接照抄角度与公式**（与像素无关，`°` 与 `局部单位` 换算成 `u` 即可）。

---

## 13. **可直接照抄的尺寸/位置表**

> 单位：除注明外均为**局部单位**（`BtlContainer` 空间）或**度**。
> 坐标系：**右手系，+X 右、+Y 上、+Z 朝相机**（Unity 默认）；手牌/战场/牌堆都在 `BtlContainer` 局部空间。
> 锚点：`BtlContainer` 原点 = 屏幕中心（因为 `BtlContainer` 是 `Battle3DContainer` 的子物体，而 `StatusPanel` 走 NGUI）。

### 13.1 容器与根

| 控件 | 父 | 锚点 | localPosition | localRotation(°) | localScale | 出处 |
|---|---|---|---|---|---|---|
| 玩家牌堆 `CardHolder` | `BtlContainer` | 父原点 | `(950,-190,0)` | `(0,0,80)` | 【资源】 | `SBattleLoad.cs:79-85` |
| 敌方牌堆 `ECardHolder` | `BtlContainer` | 父原点 | `(965,180,0)` | `(0,0,100)` | 【资源】 | `SBattleLoad.cs:83-85` |
| 假卡（第 i 张） | 牌堆根 | 牌堆根 | `(-0.1,0.4,0.1)*(i+1)` | `(0,0,0)` | `(18,18,18)`；deckout 卡 ×0.95 | `SBattleLoad.cs:1055-1075` |
| 玩家手牌根 `HandDeck` | `BtlContainer` | 父原点 + `UIAnchor`(相机) | `(500,-510,10)` | 0 | 【资源】 | `HandControlPlayer.cs:13`、`SBattleLoad.cs:1107-1110` |
| 敌方手牌根 `EHandDeck` | `BtlContainer` | 同上 | `(-500,530,10)` | 0 | 【资源】 | `HandControlEnemy.cs:8` |
| 玩家战场根 `FieldCard` | `BtlContainer` | 父原点 | `(prefabY) + (0,-110,0)` | 0 | 【资源】 | `InPlayCardControl.cs:16,41` |
| 敌方战场根 `EFieldCard` | `BtlContainer` | 父原点 | `(prefabY) + (0,158,0)` | 0 | 【资源】 | `InPlayCardControl.cs:18,45` |
| 玩家主战者根 | `Battle3DContainer` | `UIWidget` top `171`/bottom `71`（target = 容器） | `(0,-460,30)` | 0 | 【资源】 | `PlayerSpineClassCharacter.cs:7-11` |
| 敌方主战者根 | `Battle3DContainer` | `UIWidget` top `-1162`/bottom `195`（target = 相机） | `(0,490,30)` | 0 | 【资源】 | `EnemySpineClassCharacter.cs:8-12` |

### 13.2 手牌（每张卡的 TRS；`n` = 张数，`i` = 索引，`rate = i/(n-1)`，`W = min(200(n-1),700)`，`t2` 见 §3.2）

| 状态 | localPosition | localRotation(°) | localScale | 出处 |
|---|---|---|---|---|
| 玩家 Fan/Flat 常态 | `( +W*0.7*rate - W*0.35 , 40 , 0 )` **← 相对手牌根累加 `_handPos.x`** | `(0,-5,0)` | `(0.7,0.7,0.7)` | `HandTRSCalculatorPlayerFan.cs:34-36`、`...PlayerFlat.cs:26-28` |
| 玩家 Fan 放大 | `( W*(1+0.04n)*rate - W*(1+0.04n)*0.5 + 130 , t2*40+40 , -30 )` | `(camRot.x, -5, rate*(-1.5n)+0.75n)` | `(1.2,1.2,1.2)` | `HandTRSCalculatorPlayerFan.cs:40-42` |
| 玩家 Flat 放大 | `( W*(1+0.05n)*rate - W*(1+0.05n)*0.5 + 65 , 115 , -30 )`（观战 y=64，scale 1.1） | `(0,-5,0)` | `(1.2,1.2,1.2)` | `HandTRSCalculatorPlayerFlat.cs:33-43` |
| 敌方 Fan/Flat 常态 | `( _handPos.x + W*0.7*rate - W*0.35 , -7.5 , 0 )`，`rate = 1 - i/(n-1)` | `(0,183,0)` | `(0.7,0.7,0.7)` | `HandTRSCalculatorEnemyFan.cs:31-33`、`...EnemyFlat.cs:26-28` |
| 敌方 Fan 放大 | `( W*rate - W*0.5 , t2*40-20 , -35 )` | `(0,183, -(rate*(-1.5n)+0.75n) )` | `(1.1,1.1,1.1)` | `HandTRSCalculatorEnemyFan.cs:42-44` |
| 敌方 Flat 放大 | `( W*(1+0.05n)*rate - W*(1+0.05n)*0.5 - 80 , -130 , -35 )` | `(0,183,0)` | `(1.1,1.1,1.1)` | `HandTRSCalculatorEnemyFlat.cs:37-39` |
| 明牌（仅观战/管理员） | 常态 y `-47.5`、放大 y `-130` 再叠加 | 常态 `(0,-3,0)`、放大 `y=-3` | 同上 | `HandTRSCalculatorBaseEnemy.cs:6-9,34-49` |
| 可见/背面叠加 | — | `+ (0,0,0)` 可见 / `+ (0,180,0)` 不可见 | — | `HandControlPlayer.cs:9-11` |

### 13.3 战场格位

| 状态 | localPosition（相对战场根） | 出处 |
|---|---|---|
| 玩家第 i 格（共 num 张） | `( 215*i - 215*(num-1)/2 , 0 , 0 )` | `InPlayCardControl.cs:42,111` |
| 敌方第 i 格（共 num 张） | `( -215*i + 215*(num-1)/2 , 0 , 0 )` | `InPlayCardControl.cs:46,113` |
| 溢出位（玩家/敌方） | `±( 430 + 215*(index+1) , 0 , 0 )` | `InPlayCardControl.cs:101-105` |
| 场上卡朝向 | rotation `(-10,0,0)` | `Global.cs:413` |
| 场上卡缩放 | `(1,1,1)`（`CardObj` 内部再 `(3.2,3.2,25)`） | `Global.cs:412`、`SBattleLoad.cs:312,369` |

### 13.4 卡面内部控件（`UnitCard` prefab 运行时布局）

| 控件 | 父 | localPosition | localRotation | localScale | 出处 |
|---|---|---|---|---|---|
| `CardObj`（`CardWrapObjTemp`） | 卡根 | `(0,0,0)` | `(0,0,0)` | `(3.2,3.2,25)` | `SBattleLoad.cs:312` |
| `Collider` | 卡根 | — | — | `(3.2,3.2,25)` | `SBattleLoad.cs:313` |
| `NotCancelCollider` | 卡根 | — | — | `(5,4.4,25)` | `SBattleLoad.cs:87,314` |
| `CardBase`（`CardBasePool`） | `CardNormalTemp` | `(0,0,0)` | `(0,-180,0)` | `(1,1,1)` | `Global.cs:406-408`、`SBattleLoad.cs:301-306` |
| `NormalLifeLabel` | `CardNormalTemp` | `(-1.61,-2.14,0.2)` | `(0,180,0)` | `(0.4,0.4,1)` | `SBattleLoad.cs:326-334` |
| `NormalAtkLabel` | `CardNormalTemp` | `(1.63,-2.14,0.2)` | — | `(0.4,0.4,1)` | `SBattleLoad.cs:360-368` |
| `NormalCostLabel` | `CardNormalTemp` | `(1.68,2.12,0.12)` | — | `(0.4,0.4,1)` | `SBattleLoad.cs:335-339` |
| `NormalNameLabel` | `CardNormalTemp` | `(0,2,0.2)` | — | `(0.0024,0.0024,1)` | `SBattleLoad.cs:340-344`、`Global.cs:428` |
| in-play `LifeLabel` | `CardObj` | `(22,-24.5,-0.1)` | — | `(9,9,0.5)`，基准再 `×0.07` | `SBattleLoad.cs:319-325`、`BattleCardView.cs:134,382` |
| in-play `AtkLabel` | `CardObj` | `(-22,-24.5,-0.1)` | — | `(9,9,0.5)`，基准再 `×0.07` | `SBattleLoad.cs:353-359`、`BattleCardView.cs:134,383` |
| `SkillIcon` | `CardObj` | `(1.3,1,0.1)` | — | `(0.01,0.01,0)` | `SBattleLoad.cs:345-351` |
| `FrameEffectNormal/Evolve/HandCard` | `CardObj` | `(0,0,0)` | — | `(160,160,20.48)` | `SBattleLoad.cs:274-296,400-412` |
| `NormalField` / `EvolField` mesh | `CardObj` | — | — | — | `SBattleLoad.cs:263-264` |

### 13.5 主战者

| 控件 | localPosition | localScale | 出处 |
|---|---|---|---|
| `ClassObj`（`CardWrapObjTemp`） | `(0,0,0)`（3D 世界） | `(80,80,25)` | `SpineClassCharacter.cs:96` |
| `Collider` | — | `(80,80,25)`；3D 皮肤敌方额外改 `size=(3.8,3.9,0.2)` | `SpineClassCharacter.cs:97`、`EnemySpineClassCharacter.cs:24` |
| `Shield`（头像盘） | 玩家 `(2,1.7,0)`；敌方 `(1.86,0.4,0)` | `(1.5,1.5,1)` | `PlayerSpineClassCharacter.cs:64-67`、`EnemySpineClassCharacter.cs:72-75` |
| `LifePoolIcon`（生命数字） | `(0,0,0.1)`（父 = `Shield`） | `(0.5,0.5,0.5)` | `SpineClassCharacter.cs:92-95`、`PlayerSpineClassCharacter.cs:69-72` |
| `cmn_frame_class_1` 光环 | `(0,0.1,0.15)` | `(6.4,6.4,20.48)` | `SpineClassCharacter.cs:87-89` |
| Spine 本体 | 玩家 `(0,-0.02,-0.17)`；敌方 `(0,-0.36,-0.17)` | `×1.003125`（敌方另 `x*0.934`） | `PlayerSpineClassCharacter.cs:49-52,79-82`、`EnemySpineClassCharacter.cs:57-60,87-94` |
| `MaskImage` | 玩家 `(0,0.12,0)`；敌方 `(0,0.04,0)` | `×0.46`（3D 皮肤分支） | `PlayerSpineClassCharacter.cs:59-62`、`EnemySpineClassCharacter.cs:67-70`、`Class3dCharacterBase.cs:197-208` |
| `ForecastIcon` | 玩家 `(0,2,0)`；敌方 `(0,-1.8,0)` | `(0.04,0.04,1)` | `PlayerClassBattleCardView.cs:8`、`EnemyClassBattleCardView.cs:8`、`ClassBattleCardViewBase.cs:36` |
| 生命数字缩放基准 | `LABEL_SCALE_DEFAULT = (0.07,0.07,0.07)` | — | `BattleCardView.cs:134` |

### 13.6 状态栏 / PP / EP（NGUI，像素）

| 控件 | 位置 | 尺寸 | 出处 |
|---|---|---|---|
| 玩家 `StatusPanelP` | 由 prefab | 【资源】 | `SBattleLoad.cs:579` |
| 玩家 `AnchorL` / `AnchorB` / `AnchorBL` | prefab 内 | — | `BattlePlayerViewBase.cs:205`、`PlayerStatusPanelControl.cs:389` |
| 玩家 `CommonPanel` | `(-140,-160,0)` | 【资源】 | `BattlePlayerView.cs:139` |
| 敌方 `CommonPanel` | `(-140,160,0)` | 【资源】 | `BattleEnemyView.cs:37` |
| 玩家 `EpPanel` 默认 | `(-229,-11.29,0)` | 【资源】 | `Global.cs:417` |
| 玩家 `EpPanel` 移出 | `(-229,-311.29,50)` | — | `PlayerStatusPanelControl.cs:101` |
| 玩家 `EpPanel` 放大（Flat / Fan） | `(-229,28.7,0)` / `(-229,47,0)` | — | `PlayerHandView.cs:26-30` |
| 玩家 `PPPanel` 移出 | `default + (300,0,0)` | — | `PlayerStatusPanelControl.cs:124` |
| 玩家 `TurnEndBtn` | `(176.8,-7.5,0)`（父 = `AnchorB/PPPanel`） | 【资源】 | `BattlePlayerView.cs:137-138` |
| 敌方 `EpPanel` 默认 | `(235,-90,0)`（Anya `(207,-90,0)`） | 【资源】 | `EnemyStatusPanelControl.cs:73-75` |
| 敌方 `PPPanel` 默认 | `(prefabX, 460, prefabZ)` | — | `EnemyStatusPanelControl.cs:119` |
| 敌方 `PPPanel` 相对主战者 | `(0,-34.22,-29.25)` | — | `EnemySpineClassCharacter.cs:14,53` |
| `HandCount`（非常驻模式） | 玩家 `(100,40,0)` / 敌方 `(-100,-40,0)` | 【资源】 | `ClassInfomationUIBase.cs:10,34,279-283` |
| `ClassInformation` 面板 | 玩家 `(100,100)` 或 `(100,170)`；敌方 `(-100,-100)` | 【资源】 | `ClassInfomationUIBase.cs:12-40` |
| Alert 条 | 尺寸 `(505,60)`；label `(462,28)` | — | `ClassInfomationUIBase.cs:56-58` |
| `PPList[10]` | 【资源】（代码不设位置） | 【资源】 | `PlayerStatusPanelControl.cs:54` |

### 13.7 颜色表

| 用途 | 值（R,G,B[,A]） | 出处 |
|---|---|---|
| 卡面默认文字 | `white` | `Global.cs:371` |
| 攻 label 描边 | `(0.2,0.2,0.4)` `CARD_LABEL_FRAME_ATTACK_COLOR` | `Global.cs:379` |
| 血 label 描边 | `(0.4,0.2,0.2)` `CARD_LABEL_FRAME_HEALTH_COLOR` | `Global.cs:380` |
| 小于最大值 | `(0.9,0.75,0.7)` | `Global.cs:381` |
| 小于基础值 | `(160/255,130/255,70/255)` | `Global.cs:382` |
| 可选择框 | `(1, 160/255, 0)` | `Global.cs:388` |
| 可行动框 | `(0,1,160/255)` | `Global.cs:383` |
| 可行动（受限） | `(1,1,0)` | `Global.cs:384` |
| 手牌数 0-6 / 7-8 / 9 | 白 / `(255/256,205/256,69/256,1)` / `(213/256,5/64,5/64,1)` | `ClassInfomationUIBase.cs:60-64` |
| 卡面失效灰 | `(0.2,0.2,0.2)` | `Global.cs:372` |
| 关键词高亮 / 按下 | `[ffcd45]` / `[00d2e4]` | `BattlePlayerView.cs:35,1000` |

### 13.8 字体

| 用途 | 值 | 出处 |
|---|---|---|
| 主字体 | `A-OTF-KaiminTuStd-Bold` | `Global.cs:285,433` |
| 简中 | `DFGBWB7-900` | `Global.cs:315,447` |
| 卡名（字母语言） | `fontSize = 32` | `Global.cs:456,652` |
| `TurnEndBtn` 标题 | `28`（观战 `25`） | `TurnEndButtonUI.cs:13-15,156-180` |
| 飘字（对照，见另一份报告） | 字距 `0.26` | `docs/shadowverse-damage-floattext.md:17` |

---

## 附：本文引用的核心文件清单

| 文件 | 作用 |
|---|---|
| `SBattleLoad.cs` | 三容器创建、牌堆位置/假卡、`UnitCard`/`SpellCard`/`FieldCard` 模板布局 |
| `Global.cs` | 基准分辨率、相机 FOV、`CARD_*` / `CLASS_*` / `EP_PANEL_POSITION_*` 常量、配色 |
| `BattleManagerBase.cs` | `ChangeCameraFieldOfView`、EP 上限常量、`BtlContainer` 字段 |
| `PlayerStatusPanelControl.cs` / `EnemyStatusPanelControl.cs` | 状态栏：Deck/Grave/HandCount、PP、EP 的全部逻辑与动画 |
| `BattlePlayerViewBase.cs` / `BattlePlayerView.cs` / `BattleEnemyView.cs` | 状态栏/手牌/战场/墓地的查找与绑定、`CommonPanel`、`TurnEndBtn` |
| `ClassInfomationUIBase.cs` | 手牌数面板、ClassInformation 位置、手牌数颜色 |
| `HandControl.cs` / `HandControlPlayer.cs` / `HandControlEnemy.cs` | 手牌根位置、重排缓动、正/背面 |
| `HandTRSCalculator*.cs` | 手牌扇形/平铺全部公式与常量 |
| `HandViewBase.cs` / `PlayerHandView.cs` | 重排时长、Focus/Unfocus、`EpPanel`/`LifeIcon` 的放大位移 |
| `InPlayCardControl.cs` / `InPlayViewBase.cs` / `PlayerInplayView.cs` / `EnemyInplayView.cs` | 战场 5 格布局与移动 |
| `Wizard/Battle/View/BattleCardView.cs` / `CardTemplate.cs` | 卡面标签位置/缩放、`Class` 节点、`CardWrapObject` |
| `Wizard/Battle/View/ClassBattleCardViewBase.cs` / `PlayerClassBattleCardView.cs` / `EnemyClassBattleCardView.cs` | 主战者视图与预测图标 |
| `Wizard/Battle/Player/ClassCharacter/*.cs` | 主战者锚点、`Shield`/`LifePoolIcon`/光环尺寸 |
| `CardCreatorBase.cs` / `ClassCardCreator.cs` | `CLASS` 类型的 localPosition/Scale |
| `PlayQueueViewBase.cs` / `PlayerPlayQueueView.cs` | 打出牌入场动画、宽高比修正公式 |
| `Wizard/Battle/View/Vfx/RefreshCardParamScale.cs` | 数值变化的 `1 → ×1.43 → 1` 反馈 |
| `Wizard/Battle/View/Vfx/OpeningVfx.cs` | 开场牌堆散开、主战者出场、状态栏初始化顺序 |
| `Wizard/Battle/View/Vfx/DummyDeck*.cs` / `PlayerDeckOutVfx.cs` / `EnemyDeckOutVfx.cs` | 牌堆增删与耗尽表现 |
| `TurnEndButtonUI.cs` | 回合结束按钮位置/字号/隐藏动画 |
| `UIBase_CardManager.cs` | 卡面数字字体切换 API |
| `docs/shadowverse-draw-animation.md` | 抽牌/牌堆动画（本报告的上游） |
| `docs/shadowverse-damage-floattext.md` | 伤害飘字（数值反馈的对照） |
