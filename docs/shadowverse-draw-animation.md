# 原版 Shadowverse：抽卡动画 + 牌堆表现 逆向参数报告

> 目的：为在 Godot 4（本项目 D:\CardGame）1:1 复刻「抽 1 张牌 / 抽多张牌 / 牌堆（卡堆）表现 / 手牌插入与扇形重排」提供**可照抄的数值与时间轴**。
>
> **引用约定**：本文所有引用路径都相对于反编译根目录
> `D:\逆向工程\decompiled\Assembly-CSharp\`（下文直接写 `路径:行号`）。
> 例如 `Wizard/Battle/View/Vfx/OpenCardVfx.cs:71` = `D:\逆向工程\decompiled\Assembly-CSharp\Wizard\Battle\View\Vfx\OpenCardVfx.cs` 第 71 行。
>
> **重要前提（先读）**：原版是 Unity 3D 世界 + NGUI（UIGrid/UIAnchor）混合。代码里出现的坐标分属**两个不同空间**：
> 1. `Battle3DContainer` 空间（`OpenCardVfx.MoveCard` 用 `islocal:false` 传世界坐标，落点量级 ≈ 0.4~1.0）；
> 2. `BtlContainer` 空间（`CardHolder=(950,-190,0)`、`HAND_POS_PLAYER=(500,-510,10)`，量级 ≈ 100~1000）。
> `BtlContainer` 是 `Battle3DContainer` 的子物体（`SBattleLoad.cs:839`），两者之间**必然存在缩放**（≈1/1000，见 §10.5 的推断与警告）。
> 因此下面所有数值都原样保留，并标注它属于哪个空间；在 Godot 里复刻时应把「同一空间内的比例关系」作为复刻目标，而不是直接照搬绝对数字。

---

## 0. 结论速览（TL;DR）

- **抽 1 张牌的总时长 ≈ 0.65 秒**（资源加载完成后）：先 0.40s「从牌堆飞向中央并翻开」，再 0.25s「插入手牌并重排」（手牌重排动画正好被 0.25s 等待覆盖），最后瞬时播 `CMN_CARD_DRAW_2` 特效。
- 翻牌三件套（位移/旋转/缩放）**同时开始、时长不同**：位移 0.4s `easeOutCirc`、旋转 0.39s `easeOutQuad`、缩放 0.39s `easeOutExpo`，全部由 iTween 驱动（`OpenCardVfx.cs:71-75`）。
- 卡从「卡背朝上」`localEulerAngles=(0,180,-80)` 开始（`OpenCardVfx.cs:45`），用 `iTween.RotateFrom` 从 `(0,176,-80)` 转到 `(0,-2,0)`（`OpenCardVfx.cs:72-73`）。
- 手牌插入：`HandView.AddCardToView(view, 0.25f)` + `HandControl.AttachCardView(view)`，重排用 **0.25s / easeOutQuad** 的 move+rotate+scale（`PlayerDrawCardToHandVfx.cs:63-64`、`HandControlPlayer.cs:76-86`）。
- 牌堆（卡堆）是**假卡（dummy sleeve 卡）堆**，数量 = `DeckCardList.Count + 1`（+1 张是 `sleeve_deckout` 空牌库指示卡），每张偏移 `(-0.1, 0.4, 0.1) * (idx+1)`（`SBattleLoad.cs:1055-1075`）；每次抽牌由 `DummyDeckChangeCardVfx` 隐藏**最前（index 最小的 active 卡）**一张（`DummyDeckChangeCardVfx.cs:19-45`）。
- 音效名（Cri cue）：抽牌 `se_sys_draw`、翻牌 `se_sys_draw_card_open`、入手 `se_sys_set_card_to_hand`、多张散开 `se_cmn_card_draw_4`（`SoundMgr.cs:90-104`）。
- 特效：`EffectMgr.EffectType.CMN_CARD_DRAW_2 / CMN_CARD_DRAW_4 / CMN_CARD_RARE_1` 只是**枚举键**，真正的 prefab 路径写在资源 `Json/EffectBattleData` 的 `PATH` 字段里（`EffectMgr.cs:428-475`、`SBattleLoad.cs:638`）——**反编译包里没有该 JSON 与 prefab，代码看不到实际资源名**。

---

## 1. 完整调用链：一次「抽 N 张牌」是怎么被拼出来的

### 1.1 回合开始抽牌入口

| 位置 | 内容 |
|---|---|
| `BattlePlayer.cs:207-216` | `TurnStartDrawCard`：`drawCount = (IsGameFirst \|\| Turn != 1) ? 1 : 2` → **先手方、或任何一方非第 1 回合：抽 1 张；后手方第 1 回合：抽 2 张**（后手补偿），随后 `RandomCardDraw(drawCount)` → `CardDrawVfx(...)` |
| `BattleEnemy.cs:129-142` | 敌方同逻辑 |
| `BattleEnemy.cs:144-164` | 敌方 `CardDrawVfx`：`OpponentDrawCardVfx` + `OpponentDrawCardToHandVfx(DrawList, 0.4f, ...)` |
| `BattlePlayer.cs:327-330` | 玩家 `CardDrawVfx` → `m_vfxCreator.CreateCardDraw(cards, isOpenDrawSkill)` |

### 1.2 玩家抽牌的 vfx 组装（关键）

`BattlePlayerVfxCreatorBase.cs:50-68`：

```csharp
public VfxBase CreateCardDraw(IEnumerable<BattleCardBase> cards, bool isOpenDrawSkill)
{
    SequentialVfxPlayer sequentialVfxPlayer = SequentialVfxPlayer.Create();
    foreach (BattleCardBase card in cards) { ... cost 更新 InstantVfx ... }
    sequentialVfxPlayer.Register(new PlayerDrawCardVfx(cards, isOpenDrawSkill));  // 第 65 行
    sequentialVfxPlayer.Register(new PlayerEndDrawVfx(cards));                     // 第 66 行
    return sequentialVfxPlayer;
}
```

`PlayerDrawCardVfx.cs:11-37`（**抽牌翻牌主体**）：

```csharp
public PlayerDrawCardVfx(IEnumerable<BattleCardBase> drawCards, bool isOpenDrawSkill = false)
{
    if (BattleManagerBase.GetIns().IsRecovery) return;              // :13 恢复/回放时整段跳过
    foreach (BattleCardBase drawCard in drawCards)
        drawCard.SetOnDraw(draw: true);                             // :21
    ParallelVfxPlayer parallelVfxPlayer = ParallelVfxPlayer.Create();
    foreach (BattleCardBase card in drawCards)
    {
        int atk  = card.BattleCardView.CardInfo.Atk;
        int life = card.BattleCardView.CardInfo.Life;
        parallelVfxPlayer.Register(InstantVfx.Create(() => {        // :29-33 同步攻/生命
            card.BattleCardView.UpdateOffence(atk);
            card.BattleCardView.UpdateLife(life);
        }));
    }
    Register(parallelVfxPlayer);
    Register(CardOpenVfx(drawCards, isOpenDrawSkill));              // :36
}
```

`PlayerEndDrawVfx.cs:8-23`（**抽牌结束后入手**）：

```csharp
public PlayerEndDrawVfx(IEnumerable<BattleCardBase> drawCards)
{
    if (!drawCards.Any()) return;
    List<BattleCardBase> list = drawCards.ToList();
    Register(list[0].SelfBattlePlayer.MoveToHand(list));            // :15
    Register(InstantVfx.Create(() => {                              // :16-22
        foreach (...) drawCard.SetOnDraw(draw: false);
    }));
}
```

`BattlePlayer.cs:314-325`：`MoveToHand` → 对每张卡 `item.CreateMoveToHandVfx()` 并行（`ParallelVfxPlayer`），再串行一个 `UpdateHandCardsPlayability()`。
`BattleCardBase.cs:2515-2522`：玩家卡 → `new PlayerDrawCardToHandVfx(this)`；敌方卡 → `NullVfx`（敌方走 `OpponentDrawCardToHandVfx`）。

### 1.3 抽牌前的引擎侧行为（会影响时序）

`BattlePlayerBase.cs:3264-3382`（`DrawCards`）：

- `:3274` `int count = DeckCardList.Count;`（**抽之前的**牌库数，用于 `CallOnChangeDeckAfterEvent`）。
- `:3283-3301` 若 `HandCardList.Count >= 9` → 该卡不进手牌，直接送墓（`CEMETERY_TYPE.DECK_DRAW_HAND_OVER`）→ **手牌上限 9 张**。
- `:3303` `parallelVfxPlayer.Register(DrawCard(card, skill, isOpen, isToken, isReservation));`
- `:3304` `parallelVfxPlayer2.Register(card.StartHandEffect());`
- `:3318` `sequentialVfxPlayer.Register(SequentialVfxPlayer.Create(parallelVfxPlayer, parallelVfxPlayer2));`
- `:3379` `vfxWithLoadingSequential.RegisterVfxWithLoading(VfxWithLoading.Create(BattleMgr.LoadCardResources(drawList.ToList())));`

`BattlePlayerBase.cs:2908-2961`（`DrawCard`，**在构造 vfx 时同步执行**，不是播放时）：

```csharp
if (!isToken && DeckCardList.SingleOrDefault(c => c == targetCard) != null) {
    DeckCardList.Remove(targetCard);                       // :2913 从牌库移除
    if (!BattleMgr.IsVirtualBattle) { flag = true;
        StatusPanelControl.SetDeck(DeckCardList.Count); }  // :2917 状态栏牌库数字立刻 -1
}
...
HandCardAddList(targetCard, ...);                          // :2930
```

`BattlePlayerBase.cs:3199-3262`（`DrawManagement`，玩家分支）：

```csharp
if (IsPlayer) {
    sequentialVfxPlayer.Register(new PlayerDrawCardVfx(drawCards, isVisible));   // :3232
    sequentialVfxPlayer.Register(new PlayerEndDrawVfx(drawCards));               // :3233
} else {
    if (!(GameMgr.GetIns().IsAdminWatch & isVisible))
        sequentialVfxPlayer.Register(new OpponentDrawCardVfx(drawCards, isVisible)); // :3239
    sequentialVfxPlayer.Register(new OpponentDrawCardToHandVfx(drawCards, 0.4f, isVisible)); // :3241
}
```

> **时序要点**：`PlayerDrawCardVfx` / `PlayerOpenCardVfx` / `DummyDeckChangeCardVfx` 的构造函数在**播放前**执行，所以 `DummyDeckChangeCardVfx` 里捕获的 `DeckCardList.Count` 是**抽走之后**的数量（`PlayerOpenCardVfx.cs:18`）。而 `StatusPanelControl.SetDeck()` 在构造期就调用了（`:2917`），比动画早。

### 1.4 vfx 播放器语义（理解时序的基础）

| 类 | 语义 | 出处 |
|---|---|---|
| `SequentialVfxPlayer` | 严格串行：前一个 `IsEnd` 才 `Dequeue` 下一个并 `Play()` | `Wizard/Battle/View/Vfx/SequentialVfxPlayer.cs:76-103` |
| `ParallelVfxPlayer` | 全部并行，`IsEnd = All(IsEnd)` | `Wizard/Battle/View/Vfx/ParallelVfxPlayer.cs:12,50-73` |
| `InstantVfx` | `Play()` 里执行 Action 后立刻 `IsEnd = true` | `Wizard/Battle/View/Vfx/InstantVfx.cs:14-18` |
| `WaitVfx` | 计时 `waitTime` 秒；**`IsRecovery` 时构造为 0 秒** | `Wizard/Battle/View/Vfx/WaitVfx.cs:14-32` |
| `NullVfx` | 空 vfx（`Register` 时被过滤，`IsVfxNonEmpty()`） | `SequentialVfxPlayer.cs:105-111` |

> 复刻提示：所有 `WaitVfx.Create(x)` 在「回放/断线恢复」模式下变成 0 秒（`WaitVfx.cs:26-31`），`OpenCardVfx.MoveCard` 在 `IsRecovery` 或手牌不可见时直接返回 `NullVfx`（`OpenCardVfx.cs:63-66`）。

---

## 2. 抽 1 张牌的精确 vfx 序列（含每步秒数）

### 2.1 落点公式（`PlayerDrawCardVfx.CardOpenVfx`）

`PlayerDrawCardVfx.cs:39-63`：

```csharp
float num = (float)Screen.width / (float)Screen.height * 0.9f;      // :45  aspect * 0.9
SequentialVfxPlayer sequentialVfxPlayer = SequentialVfxPlayer.Create();
ParallelVfxPlayer   parallelVfxPlayer   = ParallelVfxPlayer.Create();
List<BattleCardBase> list = drawCards.ToList();
int count = list.Count;
sequentialVfxPlayer.Register(BattleManagerBase.GetIns().LoadCardResources(list));  // :50
for (int i = 0; i < count; i++)
{
    if (isOpenDrawSkill) { parallelVfxPlayer.Register(new OpenDrawSkillVfx(...)); continue; }  // :55
    Vector3 pos = (count > 1)
        ? new Vector3(
            (num / count * i + num / count * 0.5f - num * 0.5f) * (0.5f + count * 0.1f),  // x
            count * 0.02f - 0.25f,                                                        // y
            Mathf.Min(count, 7f) * 0.15f - 1.3f)                                          // z
        : new Vector3(0.25f * num, -0.23f * num, -0.7f);                                  // :58 单张
    parallelVfxPlayer.Register(list[i].Draw(pos));                                        // :59
}
sequentialVfxPlayer.Register(parallelVfxPlayer);
```

数值表（`Screen.width/Screen.height = aspect`，`num = aspect * 0.9`）：

| 张数 count | x | y | z |
|---|---|---|---|
| 1 | `0.25 * num` | `-0.23 * num` | `-0.7` |
| >1 | `(num/count*i + num/(2*count) - num/2) * (0.5 + count*0.1)` | `count*0.02 - 0.25` | `min(count,7)*0.15 - 1.3` |

- 常见手机竖屏 9:16 → `num = 0.50625`：单张落点 `(0.1266, -0.1164, -0.7)`。
- 16:9 横屏 → `num = 1.6`：单张落点 `(0.4, -0.368, -0.7)`。
- 多张时 z 被 `min(count,7)` 截断（`PlayerDrawCardVfx.cs:9` 的 `MAX_Z_POSITION_MULTIPLIER = 7f`；注意代码里用的是硬编码 7f）。

### 2.2 `PlayerOpenCardVfx`（玩家翻牌）

`PlayerOpenCardVfx.cs:5-21` 全文：

```csharp
public class PlayerOpenCardVfx : OpenCardVfx
{
    public PlayerOpenCardVfx(IBattleCardView cardView, Vector3 pos, bool isLegend)
    {
        Init(cardView, pos, isLegend);
        RegisterOpenCardVfx();
    }

    private void RegisterOpenCardVfx()
    {
        bool isPlayer = _cardView.CardInfo.IsPlayer;
        Register(new StopCardMaskVfx(_cardView));                                            // :16
        Register(PrepareMoveCard(_battleManager.CardHolder));                                // :17
        Register(new DummyDeckChangeCardVfx(_cardView.CardInfo.IsPlayer,
                  _battleManager.GetBattlePlayer(isPlayer).DeckCardList.Count));              // :18
        Register(MoveCard());                                                                // :19
    }
}
```

四步全部**串行**，每步含义：

1. **`StopCardMaskVfx`**（`StopCardMaskVfx.cs:14-27`）：把 `CardNormalLodGroup` 每级 LOD 每个材质的 `_Color` 设成 `Color.white`（清除灰化遮罩），瞬时。
2. **`PrepareMoveCard(CardHolder)`**（`OpenCardVfx.cs:34-59`，玩家版）：
   ```csharp
   iTween.Stop(_cardView.GameObject);                       // :38 停掉旧动画
   _cardView.CardWrapObject.transform.localPosition = Vector3.zero;      // :39
   _cardView.CardWrapObject.transform.localEulerAngles = Vector3.zero;   // :40
   _cardView.GameObject.SetActive(false);                   // :41
   _cardView.HideHandCardInfo();                            // :42
   _cardView.GameObject.transform.parent = _battleManager.Battle3DContainer.transform;  // :43
   _cardView.GameObject.transform.position = cardHolder.transform.position;             // :44 ← 起点：牌堆世界位置
   _cardView.GameObject.transform.localEulerAngles = new Vector3(0f, 180f, -80f);       // :45 ← 卡背朝上+倾斜
   _cardView.GameObject.SetActive(true);                    // :46
   _cardView.CardTemplate.CardNormalTemp.gameObject.SetActive(true);        // :47
   _cardView.CardTemplate.FieldNormalMeshTemp.gameObject.SetActive(false);  // :48
   _cardView.CardTemplate.SkillIconTemp.gameObject.SetActive(false);        // :49
   if (_cardView.CardInfo.IsUnit) { ...攻/生命标签切换... }   // :50-57
   ```
   注意：**卡被改挂到 `Battle3DContainer` 下**，所以后面 `MoveCard` 用的是世界坐标。
3. **`DummyDeckChangeCardVfx`**（`DummyDeckChangeCardVfx.cs:19-45`）：按新的 `DeckCardList.Count` 显示/隐藏牌堆假卡，瞬时（`IsEnd = true`）。详见 §6.3。
4. **`MoveCard()`**（`OpenCardVfx.cs:61-83`）—— 核心运动：
   ```csharp
   sequentialVfxPlayer.Register(InstantVfx.Create(() =>
   {
       cardDrawSound();                                                     // :70 se_sys_draw
       iTween.MoveTo(_cardView.GameObject, iTween.Hash("position", _position,
           "time", 0.4f, "islocal", false, "easetype", iTween.EaseType.easeOutCirc));   // :71
       _cardView.GameObject.transform.localEulerAngles = new Vector3(0f, -2f, 0f);      // :72 先摆到"正面"朝向
       iTween.RotateFrom(_cardView.GameObject, iTween.Hash("x", 0f, "y", 176f, "z", -80f,
           "time", 0.39f, "islocal", true, "easetype", iTween.EaseType.easeOutQuad));   // :73
       cardOpenSound();                                                     // :74 se_sys_draw_card_open
       iTween.ScaleTo(_cardView.GameObject, iTween.Hash("x", 1f, "y", 1f, "z", 1f,
           "time", 0.39f, "islocal", true, "easetype", iTween.EaseType.easeOutExpo));   // :75
   }));
   sequentialVfxPlayer.Register(WaitVfx.Create(0.4f));                       // :77 等 0.40s
   sequentialVfxPlayer.Register(InstantVfx.Create(() => PlayCardOpenEffect()));  // :78-81
   ```
   - 位移：世界坐标 → `_position`，**0.4s，easeOutCirc，线性 P0=当前位置**。
   - 旋转：`RotateFrom(x=0, y=176, z=-80)`，即从 `(0,176,-80)` 转到执行前设定的 `(0,-2,0)`，**0.39s**，局部，easeOutQuad。
   - 缩放：`ScaleTo(1,1,1)`，**0.39s**，局部，easeOutExpo（起始 scale 由卡自己被改挂到 `Battle3DContainer` 时的既有值决定；代码里没显式设置起始缩放）。
   - 结束后 `PlayCardOpenEffect()`：**只有传说卡**才播特效（`OpenCardVfx.cs:112-122`）：
     ```csharp
     if (_isLegend) {
         Effect effect = GameMgr.GetIns().GetEffectMgr()
             .Start(EffectMgr.EffectType.CMN_CARD_RARE_1, _cardView.Transform.position);   // :116
         if (effect != null) effect.GetGameObjIns().transform.rotation = _cardView.Transform.rotation;  // :119
     }
     ```
   - **没有**在翻牌阶段播 `CMN_CARD_DRAW_2`；那张特效在「入手」阶段播（§2.4）。

基类常量（`OpenCardVfx.cs:8-12`）：

| 常量 | 值 | 行 |
|---|---|---|
| `CARD_MOVE_TIME` | `0.4f` | `OpenCardVfx.cs:8` |
| `CARD_TURN_TIME` | `0.39f` | `OpenCardVfx.cs:10` |
| `CARD_TRANSFORM_POSITION` | `(0, -50, -300)` | `OpenCardVfx.cs:12` |

`MoveCardCenter()`（`OpenCardVfx.cs:85-110`，仅 `OpenDrawSkillVfx` 用）：位移/旋转/缩放**全部 0.4s**，位移用 `islocal:true` 且目标 `CARD_TRANSFORM_POSITION`，easeOutCirc / easeOutQuad / easeOutExpo 不变，并行 0.4s 等待。

`OpenCardVfx.cs:124-137` 三个音效函数：`cardOpenSoundLg()` = `Se.TYPE.DRAW_CARD_OPEN_LG`（**全工程无调用者，死代码**，grep `cardOpenSoundLg` 只有定义处）、`cardOpenSound()` = `DRAW_CARD_OPEN`、`cardDrawSound()` = `DRAW`。

### 2.3 `OpponentOpenCardVfx`（对手翻牌）

`OpponentOpenCardVfx.cs:13-32`：

```csharp
bool isPlayer = _cardView.CardInfo.IsPlayer;
if (GameMgr.GetIns().IsAdminWatch) {                 // 观战/管理员：和玩家一样翻牌
    Register(new StopCardMaskVfx(_cardView));
    Register(base.PrepareMoveCard(_battleManager.ECardHolder));
    Register(new DummyDeckChangeCardVfx(...));
    Register(MoveCard());                            // 复用基类 0.4s 翻牌
} else {                                             // 正常对战：只做"抽出并停在牌堆上方"，不翻
    Register(PrepareMoveCard(_battleManager.ECardHolder));
    Register(new DummyDeckChangeCardVfx(...));
    Register(InstantVfx.Create(() => IsEnd = true));
}
```

对手版 `PrepareMoveCard`（`OpponentOpenCardVfx.cs:34-46`）与玩家版的差异：

- **不做** `CardWrapObject` 归零、**不调** `HideHandCardInfo`、不切 Unit 标签。
- 起始朝向是 `(0, 180, -100)`（玩家版是 `(0, 180, -80)`），`OpponentOpenCardVfx.cs:42`。
- 只开 `CardNormalTemp`（`:44`）。

`MoveSpin(cardView)`（`OpponentOpenCardVfx.cs:48-53`）：`Se.TYPE.DRAW` + `iTween.RotateTo(z=180, 0.2s, local, easeOutQuad)`——但**该类内无调用者**；实际对手抽牌的翻/旋在 `OpponentDrawCardVfx.MoveSpinVfx`（见 §8.1）。

### 2.4 `PlayerDrawCardToHandVfx`：卡进手牌（0.25s）

`PlayerDrawCardToHandVfx.cs` 全文要点：

```csharp
private const float ADD_CARD_TIME = 0.25f;                       // :30
public PlayerDrawCardToHandVfx(BattleCardBase drawCard)
{
    _card = drawCard;
    Register(Prepare());                                         // :35
    Register(WaitVfx.Create(0.25f));                             // :36 ← 等 0.25s
    Register(OnHand());                                          // :37
    Register(InstantVfx.Create(() => _card.SetOnDraw(draw: false)));  // :38-41
}

private VfxBase Prepare() {
    var sequentialVfxPlayer = SequentialVfxPlayer.Create();
    sequentialVfxPlayer.Register(InstantVfx.Create(() => {       // :47-54
        GameObject pCardPlace = BattleManagerBase.GetIns().PCardPlace;
        _card.BattleCardView.GameObject.SetActive(false);
        _card.BattleCardView.GameObject.transform.parent = pCardPlace.transform;   // :51 ← 改挂 PlayerCardPlace
        MotionUtils.SetLayerAll(_card.BattleCardView.GameObject, 10);              // :52 ← Layer 10
        _card.BattleCardView.GameObject.SetActive(true);
    }));
    if (_card.SelfBattlePlayer.HandCardList.Any(c => c == _card)) {
        sequentialVfxPlayer.Register(InstantVfx.Create(() => {   // :57-65
            if (!BattleManagerBase.GetIns().IsRecovery)
                GameMgr.GetIns().GetSoundMgr().PlaySe(Se.TYPE.SET_CARD_TO_HAND);   // :61
            _card.SelfBattlePlayer.BattleView.HandView.AddCardToView(_card.BattleCardView, 0.25f); // :63
            _card.SelfBattlePlayer.HandControl.AttachCardView(_card.BattleCardView);              // :64
        }));
    } else {
        sequentialVfxPlayer.Register(_card.DestroyInHand(null));  // :69 手牌没进去 → 销毁入手牌特效
    }
    return sequentialVfxPlayer;
}

private VfxBase OnHand() {
    if (_card.SelfBattlePlayer.HandCardList.Any(c => c == _card)) {
        return ParallelVfxPlayer.Create(
            _card.BattleCardView.ShowHandCardInfo(),              // :78 显示手牌信息
            _card.CalcHandCost(),                                 // :78 费用动画
            InstantVfx.Create(() => {                             // :78-86
                if (!BattleManagerBase.GetIns().IsRecovery)
                    GameMgr.GetIns().GetEffectMgr()
                        .Start(EffectMgr.EffectType.CMN_CARD_DRAW_2,
                               _card.BattleCardView.GameObject.transform.position)   // :82
                        .GetGameObjIns().transform.rotation =
                            _card.BattleCardView.GameObject.transform.rotation;      // :83-84
            }));
    }
    return NullVfx.GetInstance();
}
```

`ADD_CARD_TIME = 0.25f` 这个常量在类里定义了但**没有被使用**（`Register(WaitVfx.Create(0.25f))` 是硬编码），`AddCardToView` 实参也是硬编码 `0.25f`。

另一个内部类 `ChangePlayerHandCardParentVfx`（`:8-26`）：仅改父到 `PCardPlace` + Layer 10，被 `BattlePlayerView.cs:1205` 用于「恢复/回放」重建手牌。

### 2.5 时序总表（玩家，1 张，手牌可见，非传说）

| t (s) | 事件 | 出处 |
|---|---|---|
| −（构造期） | `DeckCardList.Remove`；状态栏牌库数 −1；`DummyDeckChangeCardVfx` 捕获新数量 | `BattlePlayerBase.cs:2913,2917`；`PlayerOpenCardVfx.cs:18` |
| −（构造期） | `_cardView.GameObject.SetActive(false)`（`RegisterImmediateVfx`） | `OpenCardVfx.cs:28-31` |
| 0.000 | 资源加载 `LoadCardResources`（已加载则≈1 帧） | `PlayerDrawCardVfx.cs:50` |
| 0.000 | `StopCardMaskVfx`：材质 `_Color=white` | `StopCardMaskVfx.cs:17-25` |
| 0.000 | `PrepareMoveCard`：瞬移到 `CardHolder.position`，`localEulerAngles=(0,180,-80)`，改挂 `Battle3DContainer` | `OpenCardVfx.cs:38-47` |
| 0.000 | `DummyDeckChangeCardVfx`：隐藏 1 张假卡 | `DummyDeckChangeCardVfx.cs:19-45` |
| 0.000 | ▶ `se_sys_draw` | `OpenCardVfx.cs:70` |
| 0.000 | 位移 0.4s easeOutCirc → `pos`；旋转 0.39s easeOutQuad `(0,176,-80)`→`(0,-2,0)`；缩放 0.39s easeOutExpo → 1 | `OpenCardVfx.cs:71-75` |
| 0.000 | ▶ `se_sys_draw_card_open` | `OpenCardVfx.cs:74` |
| 0.400 | 若传说：▶ 特效 `CMN_CARD_RARE_1`（位置=卡位置，旋转=卡旋转） | `OpenCardVfx.cs:112-122` |
| 0.400 | 改挂 `PCardPlace`，Layer 10；▶ `se_sys_set_card_to_hand`；`AddCardToView(view, 0.25f)`（手牌重排 0.25s）；`AttachCardView` | `PlayerDrawCardToHandVfx.cs:47-64` |
| 0.650 | `ShowHandCardInfo` + `CalcHandCost` + ▶ 特效 `CMN_CARD_DRAW_2` | `PlayerDrawCardToHandVfx.cs:78-86` |
| 0.650 | `SetOnDraw(false)` | `PlayerDrawCardToHandVfx.cs:38-41` |

**总时长 ≈ 0.65s**（0.400 翻牌 + 0.250 入手，两段**串行不重叠**；不含资源加载与手牌重排的额外时间）。

---

## 3. 手牌插入与扇形重排

### 3.1 `HandView.AddCardToView` → `RearrangeHand`

`HandViewBase.cs:35-46`：

```csharp
public virtual void AddCardToView(IBattleCardView cardViewToAdd, float deckRearrangeTime, bool isNewReplayMoveTurn = false)
{
    if (!(cardViewToAdd is NullBattleCardView)) {
        if (BattleManagerBase.GetIns().IsRecovery) deckRearrangeTime = 0f;   // :40-42 恢复时无动画
        AddCardToViewWithoutRearrange(cardViewToAdd);                          // :43 加进 list
        RearrangeHand(deckRearrangeTime, isNewReplayMoveTurn);                 // :44
    }
}
```

重排时间常量（`HandViewBase.cs:13-15`）：`REARRANGE_TIME = 0.2f`、`WATCH_REARRANGE_TIME = 0.1f`（两者都未被 `AddCardToView` 使用，实际时间由调用方给：抽牌 0.25/0.4）。
`HideCardFromView` 用 0.2f（`HandViewBase.cs:96-104`）；`HandFocus`/`HandUnfocus` 用 0.2f（`:124-140`）。

`PlayerHandView.cs:72-79`：重排直接转发给 `_handControl.RearrangeHand(time, list)`。

### 3.2 `HandControl.AttachCardView`（改父到「手牌根」）

`HandControl.cs:62-70`：

```csharp
public void AttachCardView(IBattleCardView cardView) {
    if (!(cardView is NullBattleCardView)) {
        cardView.Transform.parent = Transform;      // :66 ← 手牌根节点
        cardView.GameObject.SetActive(false);        // :67
        cardView.GameObject.SetActive(true);         // :68 触发一次刷新
    }
}
```

`HandControl` 构造时把自己的 `localPosition` 设成 `BaseHandPos`（`HandControl.cs:48-60`）：

| 类 | `BaseHandPos` | 出处 |
|---|---|---|
| `HandControlPlayer` | `HAND_POS_PLAYER = (500, -510, 10)` | `HandControlPlayer.cs:13,17` |
| `HandControlEnemy` | `HAND_POS_ENEMY = (-500, 530, 10)` | `HandControlEnemy.cs:8,10` |

手牌根节点 = `BtlContainer/HandDeck`（玩家）/ `EHandDeck`（敌方）（`BattlePlayerView.cs:37`、`BattleEnemyView.cs:11`、`BattlePlayerViewBase.cs:213-215`），并带一个指向 `Battle3DContainer/Camera` 的 `UIAnchor`（`SBattleLoad.cs:1107-1110`）。
`_cardPos/_cardRot/_cardScale` 数组长度 **9**（`HandControl.cs:56-58`），与手牌上限 9 一致。

### 3.3 玩家重排的 iTween 参数

`HandControlPlayer.cs:50-90`：

```csharp
List<IBattleCardView> list = battleCardViewList.Where(c => !c._hasCardEnteredPlayQueue).ToList();  // :52
list = list.FindAll(cardView => !cardView.isHiddenFromHandView);                                   // :53
int num = 0;
RecalculateTRS(list.Count);                                                                        // :55
foreach (IBattleCardView item in list) {
    ... iTween.Stop + 销毁残留 iTween 组件 ...                                                      // :64-69
    iTween.MoveTo(gameObject, Hash("position", _cardPos[num], "time", time,
        "islocal", true, "easetype", iTween.EaseType.easeOutQuad));                                // :76
    iTween.RotateTo(gameObject, Hash("rotation",
        _cardRot[num] + (IsVisibleHand() ? CARD_FRONT_ROTATION : CARD_BACK_ROTATION),
        "time", time, "islocal", true, "easetype", iTween.EaseType.easeOutQuad));                  // :85
    iTween.ScaleTo(gameObject, Hash("scale", _cardScale[num], "time", time,
        "islocal", true, "easetype", iTween.EaseType.easeOutQuad));                                // :86
    num++;
}
```

- **玩家**：三个属性都是 **easeOutQuad**，`time` = 调用方给定（抽牌 0.25 / 敌方入手 0.4 / 普通重排 0.2）。
- **敌方**（`HandControlEnemy.cs:47-49`）：`time > 0` 时 move = `easeInOutQuad`、rotate = `easeInOutQuad`、scale = **`easeInExpo`**；`time <= 0` 直接赋值（`:51-56`）。
- 卡面/卡背：`CARD_FRONT_ROTATION=(0,0,0)`、`CARD_BACK_ROTATION=(0,180,0)`（`HandControlPlayer.cs:9-11`）。

### 3.4 扇形/平铺的完整 TRS 公式

公共常量（`HandTRSCalculatorBase.cs:5-21`）：

```csharp
protected const float HAND_ALL_WIDTH = 700f;   // :5 手牌总展开宽度上限
protected const float CARD_WIDTH     = 200f;   // :7
protected float CalHandAllWidth(int handMax) => Mathf.Min(200f * (handMax - 1), 700f);  // :18-21
```

玩家公共（`HandTRSCalculatorBasePlayer.cs:5-19`）：

```csharp
CARD_ROT   = (0, -5, 0);   HIDE_SCALE = (0.7,0.7,0.7);  ZOOM_SCALE = (1.2,1.2,1.2);
ZOOM_SCALE_WATCH = (1.1,1.1,1.1);  HIDE_POS_Z = 0;  HIDE_POS_Y = 40;  HIDE_POS_Y_WATCH = 23;
ZOOM_POS_Z = -30;
```

`CalcParam`（`HandTRSCalculatorBasePlayer.cs:35-47`）：

```csharp
retRateLtoR = (handMax > 1) ? handIndex / (handMax - 1) : 0f;                  // :26-33
retT2 = (retRateLtoR < 0.5f)
      ? GetEase(retRateLtoR * 2f, easeOutQuad) * 0.5f
      : GetEase(retRateLtoR * 2f - 1f, easeOutQuad) * 0.5f + 0.5f;              // :38-45
retT3 = 1f - Mathf.Abs(retT2 - 0.5f) * 2f;                                     // :46（弧形高度权重，0..1）
```

`MotionUtils.GetEase(t, easeOutQuad) = 1 - (1-t)^2`（`MotionUtils.cs:90-91`）。

**扇形 Fan（玩家，默认布局）** `HandTRSCalculatorPlayerFan.cs:23-45`：

| 状态 | 位置 | 旋转 | 缩放 |
|---|---|---|---|
| Unfocus（常态） | `(_handPos.x + W*0.7*rate - W*0.7*0.5, 40, 0)` | `(0,-5,0)` | `(0.7,0.7,0.7)` |
| Focus（看手牌放大） | `(W*(1+n*0.04)*rate - W*(1+n*0.04)*0.5 + 130, t2*40+40, -30)` | `(cameraRot.x, -5, rate*(-n*1.5) + n*1.5*0.5)` | `(1.2,1.2,1.2)` |

其中 `W = min(200*(n-1),700)`，`n = 手牌数`，`rate = i/(n-1)`，`t2` 见上（中点最高）。
`_handPos` = `HAND_POS_PLAYER`（因为 `HandControlPlayer.CreateHandCardTRSCalculator` 传 `BaseHandPos`，`HandControlPlayer.cs:45-47`）。

**平铺 Flat（设置项 `FIXEDUSE_COST_INFO` 开启或观战时）** `HandTRSCalculatorPlayerFlat.cs:18-47`：

| 状态 | 位置 | 旋转 | 缩放 |
|---|---|---|---|
| Unfocus | `(_handPos.x + W*0.7*rate - W*0.7*0.5, 40 或 23(观战), 0)` | `(0,-5,0)` | `(0.7,0.7,0.7)` |
| Focus | `(W*(1+n*0.05)*rate - W*(1+n*0.05)*0.5 + 65, 115 或 64(观战), -30)` | `(0,-5,0)` | `1.2` / 观战 `1.1` |

**敌方扇形** `HandTRSCalculatorEnemyFan.cs:20-52`（`rate` 是**反向**的：`CalcHandIndexRate = 1 - i/(n-1)`，`HandTRSCalculatorBaseEnemy.cs:26-33`）：

| 状态 | 位置 | 旋转 | 缩放 |
|---|---|---|---|
| Unfocus | `(_handPos.x + W*0.7*rate - W*0.7*0.5, -7.5, 0)`；`IsOpenCard()`（=IsAdminWatch）时 y=-47.5、rot.y=-3 | `(0,183,0)` | `0.7` |
| Focus | `(W*rate - W*0.5, t2*40 - 20, -35)` | `(0, 183, -(rate*(-n*1.5) + n*1.5*0.5))` | `1.1` |

敌方常量（`HandTRSCalculatorBaseEnemy.cs:5-19`）：`OPEN_ROT_Y=-3`、`OPEN_NORMAL_POS_Y=-47.5`、`OPEN_ZOOM_POS_OFFSET_Y=-130`、`HIDE_SCALE=0.7`、`ZOOM_SCALE=1.1`、`HIDE_POS_Y=-7.5`、`CARD_ROT=(0,183,0)`。

---

## 4. 多张散开（SpreadOutVfx）——token/一次抽多张的"排开"表现

`SpreadOutVfx.cs:21-41` 常量：

| 常量 | 值 | 行 |
|---|---|---|
| `Z_SPAWN_OFFSET` | `5f` | 21 |
| `CARD_SORT_TIME` | `0.2f` | 23 |
| `CARD_WAIT_SORT_TIME` | `0.15f` | 25 |
| `BW_MAX` | `700f` | 27 |
| `C_BASE_X` | `200f` | 29 |
| `TOKEN_SPAWN_TIME` | `0.2f` | 31 |
| `FRAME_SPARK_TIME` | `0.1f` | 33 |
| `SPECIAL_TOKEN_FRAME_SPARK_TIME` | `0.8f` | 35 |
| `EFFECT_ALPHA_CARD_MAX` | `30f` | 37 |
| `EFFECT_ALPHA_RATE` | `0.8f` | 39 |
| `EFFECT_ALPHA_OFFSET` | `0.3f` | 41 |

排序落点（`SpreadOutVfx.cs:117-124`，你已知的公式，这里补全 `num3/num4` 的含义）：

```csharp
float num  = Mathf.Min(200f * (cNum - 1), 700f);                        // :119 展开总宽 W
float num2 = (cNum > 1) ? ((float)i / (cNum - 1)) : 0f;                 // :120 归一化序号 rate
float num3 = (num2 < 0.5f)
    ? (MotionUtils.GetEase(num2 * 2f,      easeOutQuad) * 0.5f)          // 左半边：easeOutQuad
    : (MotionUtils.GetEase(num2 * 2f - 1f, easeInQuad ) * 0.5f + 0.5f);  // 右半边：easeInQuad
float num4 = 1f - Mathf.Abs(num3 - 0.5f) * 2f;                          // :122 弧高权重 0..1
return new Vector3(num * num2 - num * 0.5f,                             // x：等距线性排开
                   num4 * 45f - 50f,                                    // y：中间高 45 的弧
                   -330f);                                              // z
```

对比手牌扇形（§3.4）用的是 **easeOutQuad + easeOutQuad**（`HandTRSCalculatorBasePlayer.cs:40-45`），而 SpreadOut 是 **easeOutQuad + easeInQuad**（`SpreadOutVfx.cs:121`）——两者形不同，不要混用。

排序旋转（`SpreadOutVfx.cs:126-131`）：

```csharp
float num  = (cNum > 1) ? ((float)i / (cNum - 1)) : 0f;
float num2 = cNum * 3f * (_isVisible ? 1 : -1);          // 每张 3°，可见时正向
return new Vector3(camRot.x, GetRotationY, num * (0 - num2) + num2 * 0.5f);
```

`GetRotationY`：`_isVisible ? -5f : 180f`（`SpreadOutVfx.cs:45-55`）。

播放（`SpreadOutVfx.cs:59-115`）：

1. `InstantVfx`：所有卡 `SetActive(true)`（`:64-70`）。
2. 每张卡 `iTween.MoveTo(sortPosition, 0.2s, islocal:true, easeInOutQuad)` + `RotateTo(sortRotation, 0.2s, islocal:true, easeInOutQuad)`（`:84-85`）——**0.2s，easeInOutQuad**。
3. 每张（`index < 50`）▶ 特效 `CMN_CARD_DRAW_4`，位置=卡位置，旋转对齐卡，并用 `MotionUtils.ChangeParticleSystemColor` 统一染色（`:87-95`）：
   ```csharp
   float a = Mathf.Clamp01((1f - Mathf.Clamp01((float)drawList.Count / 30f)) * 0.8f + 0.3f);  // :75
   Color effectColor = new Color(1f, 1f, 1f, a);                                             // :76
   ```
   即 **alpha = 1 - clamp01(count/30)，映射到 0.3~1.0**（`EFFECT_ALPHA_RATE=0.8`、`EFFECT_ALPHA_OFFSET=0.3`）：`count=0→a=1.1→clamp 1.0`；`count=30+ → a=0.3`。
4. 若 `count > 1`：先等 0.2s 的并行组结束，再 `WaitVfx.Create(0.15f)`（`:97-101`）。
5. 若 `IsPlaySparkEffect`（默认 true，`:57`）：▶ `se_cmn_card_draw_4`（`Se.TYPE.SYS_CMN_CARD_DRAW_4`）与特效并行（`:105-111`），然后 `WaitVfx.Create(waitTime)`，`waitTime = isSpecialTokenDraw ? 0.8f : 0.1f`（`:102`）。

`DrawTokenVfx`（`DrawTokenVfx.cs:23-58`，token 抽牌专用）：

- 初始摆放（`:36-45`）：`localPosition = (0, -50, -330 + (num-num2)*5f)`（Z_SPAWN_OFFSET=5 逐张错开），`localRotation = Euler(-10, GetRotationY, 1.5)`。
- 最后一张翻面（`:50-52`）：`Euler(10, -180, 1.5)` → `iTween.RotateTo(x=-10, y=GetRotationY, 0.2s, local, easeOutExpo)`。
- 然后 `WaitVfx.Create(0.2f)`（`:54`）→ `CreateSpreadOutVfx(drawList)` → `MoveToHand(drawList)`。
- `CreateAddTokensToHandVfx`（`:60-121`）内手牌重排时间 `HAND_REARRANGE_TIME = 0.3f`（`:9`），之后 `WaitVfx.Create(0.3f)`，再 ▶ `CMN_CARD_DRAW_2`（`:96`），最后 `CreateHideCardMeshesVfx`。

---

## 5. `PlayerEndDrawVfx` 之外的「抽牌后处理」

- `BattlePlayerBase.cs:3257-3260`：`UpdateHandCardsPlayability()`。
- `OpponentDrawCardToHandVfx.cs:84`：`HandViewBase.CreateHideCardMeshesVfx(drawnCards)` → 非管理员时对每张卡 `new ShowCardNumberLabelVfx(card, isShow:false)`（`HandViewBase.cs:172-183`）。
- `OpponentDrawCardToHandVfx.cs:98`：`HandView.ShuffleHand()`（`HandViewBase.cs:91-94` 默认返回 `NullVfx`，敌方可覆写）。

---

## 6. 牌堆（卡堆）本身的视觉

### 6.1 牌堆对象与坐标

| 对象 | 内容 | 出处 |
|---|---|---|
| `BattleManagerBase.CardHolder` | 玩家牌堆根节点 | `BattleManagerBase.cs:321` |
| `BattleManagerBase.ECardHolder` | 敌方牌堆根节点 | `BattleManagerBase.cs:323` |
| `BattleManagerBase.PCardPlace` | 玩家手牌落点容器 `PlayerCardPlace` | `BattleManagerBase.cs:325`、`SBattleLoad.cs:880` |
| 玩家牌堆 collider 尺寸 | `CARDHOLDER_COLL_SIZE = (70, 90, 50)` | `SBattleLoad.cs:77` |
| 玩家牌堆位置/旋转 | `PLAYER_CARDHOLDER_POS = (950,-190,0)`，`PLAYER_CARDHOLDER_ROT = (0,0,80)` | `SBattleLoad.cs:79,81` |
| 敌方牌堆位置/旋转 | `ENEMY_CARDHOLDER_POS = (965,180,0)`，`ENEMY_CARDHOLDER_ROT = (0,0,100)` | `SBattleLoad.cs:83,85` |
| 初始化 | `CardHolder = InitCardHolderObject("CardHolder","CardHolder", PLAYER_..., CARDHOLDER_COLL_SIZE)`；`ECardHolder` 同理 | `SBattleLoad.cs:843-845` |
| `InitCardHolderObject` | `BoxCollider.size = colliderSize`；tag；**`UIGrid.enabled = false`**；`SetActive(true)`；`localPosition = pos`；`eulerAngles = rot`；**`BoxCollider.enabled = false`** | `SBattleLoad.cs:1094-1105` |

牌堆根是 `BtlContainer` 的子物体（`SBattleLoad.cs:1096` `BtlContainer.transform.Find(cardHolderName)`），因此上面的坐标都是 **BtlContainer 局部坐标**。

### 6.2 假卡（dummy 卡背）的创建与堆叠

`SBattleLoad.cs:840-842`：

```csharp
CardBasePool = Toolbox.ResourcesManager.LoadObject(GetAssetTypePath("sleeve_CardBase", AssetLoadPathType.CardDeco, true)) as GameObject;
CardBasePool.name = "CardBase";
CardBasePool.GetComponent<MeshFilter>().sharedMesh =
    Toolbox.ResourcesManager.LoadObject<Mesh>(GetAssetTypePath("sleeve_md_Card", AssetLoadPathType.SleeveMesh, true));
```

创建循环（`SBattleLoad.cs:856-879`）：

```csharp
Material material2 = LoadSleeveMaterial(GetPlayerSleeveId());     // :856 玩家卡背材质
int count = GetCurrentDeckData().Count;                            // :857
for (int i = 0; i < count + 1; i++) {                              // :862 ← 牌库数 + 1 张
    Material texture = (i < count) ? material2 : material;         // :864 最后一张用 deckout 材质
    Vector3 scale = (i < count) ? Global.CARD_BASE_STAY_SCALE
                                : (Global.CARD_BASE_STAY_SCALE * 0.95f);   // :865
    AddDeckCard(i, texture, scale, isPlayer: true);                // :866
}
```

- `material`（第 count 张用）= `sleeve_deckout_M` 材质 + `sleeve_deckout` 贴图（`SBattleLoad.cs:849-851`）。
- `Global.CARD_BASE_STAY_SCALE = (18,18,18)`（`Global.cs:409`）；空牌库指示卡缩放 = **×0.95**。
- `LoadSleeveMaterials(sleeveId)` = 按 sleeveId 取 `SleeveMaterial` 材质，主贴图取 `SleeveTexture`，高级卡背再取 `_MaskTex`（`SBattleLoad.cs:1264-1278`）。

堆叠定位（`SBattleLoad.cs:1055-1075`）：

```csharp
private Vector3 GetDeckCardLocalPosition(int idx)
    => new Vector3(-0.1f, 0.4f, 0.1f) * idx;                        // :1055-1058 每张的偏移步长

public void AddDeckCard(int idx, Material texture, Vector3 scale, bool isPlayer) {
    GameObject gameObject = ...CloneObjectToParent(CardBasePool, Battle3DContainer);
    gameObject.GetComponent<Collider>().enabled = false;             // :1063 牌堆不可点
    gameObject.transform.SetParent(isPlayer ? CardHolder.transform : ECardHolder.transform);  // :1064
    IList<GameObject> holderCards = GetCardParameterListInfo(isPlayer).HolderCards;
    gameObject.name = holderCards.Count.ToString();
    holderCards.Insert(idx, gameObject);                             // :1067
    gameObject.transform.localPosition = GetDeckCardLocalPosition(idx + 1);  // :1068 ← 注意是 idx+1
    gameObject.transform.localRotation = Quaternion.Euler(0f, 0f, 0f);       // :1069
    ... material = texture; _CullMode=2; _ZWriteMode=1 ...           // :1071-1073
    gameObject.transform.localScale = scale;                          // :1074
}
```

> **关键数值**：每张假卡相对前一张的偏移 = **`(-0.1, 0.4, 0.1)`**（在 `CardHolder` 局部空间）。
> 把该向量用 `CardHolder` 的 `(0,0,80°)` 旋转到 `BtlContainer` 空间 ≈ **`(-0.411, -0.029, 0.1)`**（`x' = -0.1·cos80° - 0.4·sin80°`，`y' = -0.1·sin80° + 0.4·cos80°`）——即**主要沿 `CardHolder` 局部 +Y，映射到 BtlContainer 后主要沿 −X**。
> 以 `CARDHOLDER_COLL_SIZE=(70,90,50)` 当作同空间的"卡尺寸"参照：`0.4/90 ≈ 0.44%`/张，40 张总厚 ≈ `16` 单位 ≈ **卡高的 ~18%**。若改用 `CARD_BASE_STAY_SCALE=18` 当卡高参照则是 `2.2%`/张。**两个参照给出的比例差 5 倍**，说明卡的实际网格尺寸在 prefab 里（见 §11）。
> `holderCards` 列表（`BattleManagerBase.CardParameterListInfo`，`BattleManagerBase.cs:19-32`）。索引 0..count-1 是真卡，索引 count 是 deckout 指示卡（`PlayerDeckOutVfx.cs:18` 用 `GetChild(GetMaxDeckCount(true))` 正是这张）。

### 6.3 抽牌时牌堆怎么"少一张"

`DummyDeckChangeCardVfx.cs:19-45`：

```csharp
IList<GameObject> holderCards = BattleManagerBase.GetIns().GetCardParameterListInfo(m_isPlayer).HolderCards;
int num  = _changeCount - (holderCards.Where(s => s.activeSelf).Count() - 1);   // :22
int num2 = holderCards.Where(s => !s.activeSelf).Count();                       // :23 已隐藏张数
if (num > 0) {                                                                  // 需要显示（牌库变多）
    for (int num3 = 0; num3 < num; num3++)
        if (num2 - (num3 + 1) >= 0) holderCards[num2 - (num3 + 1)].SetActive(true);   // :30
        else { BattleManagerBase.GetIns().SBattleLoad.AddDeckCards(num - 1, m_isPlayer); break; }  // :33
} else {                                                                        // 需要隐藏（抽牌）
    for (int num4 = 0; num4 < num * -1; num4++)
        holderCards[num2 + num4].SetActive(false);                              // :41
}
IsEnd = true;                                                                   // :44 瞬时
```

推理出的不变式（可验证）：初始 `count+1` 张全 active；`_changeCount = DeckCardList.Count`（抽后），于是 `num = DeckCardList.Count - (activeSelf - 1)`，稳态时 `activeSelf = DeckCardList.Count + 1`。
→ **可见假卡数 = 牌库真实张数 + 1（那张 deckout 指示卡）**，每次抽牌从**最小 index 的 active 卡**开始隐藏（`:41` 的 `holderCards[num2 + num4]`）。

补牌：`AddDeckCards(addNum, isPlayer)`（`SBattleLoad.cs:1077-1092`）插入到 `Count-1` 位置，然后用 `localPosition - GetDeckCardLocalPosition(j)` 把前面的牌整体回退一格，**堆尾（deckout 卡）保留在新位置**：

```csharp
int idx = GetCardParameterListInfo(isPlayer).HolderCards.Count - 1;   // :1082
AddDeckCard(idx, texture, Global.CARD_BASE_STAY_SCALE, isPlayer);     // :1083
Vector3 localPosition = holderCards[holderCards.Count - 1].transform.localPosition;  // :1086
for (int j = 1; j < holderCards.Count; j++)
    holderCards[holderCards.Count - 1 - j].transform.localPosition = localPosition - GetDeckCardLocalPosition(j);  // :1090
```

牌库耗尽（`PlayerDeckOutVfx.cs:16-32`）：取 `CardHolder` 的第 `GetMaxDeckCount(true)` 个子物体（= deckout 卡），▶ `Se.TYPE.SYS_CMN_CLASS_DECKOUT_1`，改挂 `BtlContainer`、Layer 31，`MoveTo((180,-100,-500), 1s, local, easeInOutExpo)` + `RotateTo((-10,0,0), 1s, local, easeInOutExpo)`；等 1s 后再 `MoveTo((500,50,-200), 0.5s, local, easeInExpo)` + `RotateTo((-10,0,-40), 0.5s, local, easeInExpo)` + `TweenColor` 变红，再等 0.5s 隐藏；并行 ▶ 特效 `CMN_CLASS_DECKOUT_1` + `ShakeCamera(one*0.2f, 0.5f, 0)`（`:33-41`）。

### 6.4 开场的牌堆上堆动画

`OpeningVfx.cs:403-404`：开场先把 `CardHolder`/`ECardHolder` **整体 SetActive(false)**。
`OpeningVfx.cs:232-237`（玩家）/ `:285-290`（敌方）：

```csharp
GameObject cardHolder = BattleManagerBase.GetIns().CardHolder;
cardHolder.SetActive(true);
for (int i = 0; i < cardHolder.transform.childCount; i++)
    iTween.MoveFrom(cardHolder.transform.GetChild(i).gameObject, iTween.Hash(
        "x", Random.value * 100f - 50f, "y", Random.value * 100f - 50f, "z", -200f,
        "time", 0.3f, "delay", (cardHolder.transform.childCount - i) * 0.01f,
        "islocal", true, "easetype", iTween.EaseType.easeOutExpo));
```

→ 每张假卡从「随机 ±50 x/y、z−200 偏移」处飞回原位，**0.3s，easeOutExpo，delay = (childCount - i) * 0.01s**（最多 40+1 张 → 最末 delay ≈ 0.41s）。
之后 `WaitVfx.Create(0.5f)`（`:238`）。

### 6.5 状态栏牌库计数

`PlayerStatusPanelControl.cs:235-239`：

```csharp
public void SetDeck(int num) { DeckLabel.text = num.ToString(); DeckLabelAlwaysDisp.text = num.ToString(); }
```

调用点：抽牌时（`BattlePlayerBase.cs:2917,2937,2967`）、`DeckChangeVfx`（`DeckChangeVfx.cs:14`）、开场（`OpeningVfx.cs:459`）、准备（`PlayerAndEnemyReadyVfx.cs:19-34`，初始 3 张手牌时 `SetDeck(maxDeck - 3)`）。
牌库上限默认 `GetMaxDeckCount() => 40`（`BattleManagerBase.cs:695-698`），网络对战取 `DataMgr.GetDeckMaxCount`（`NetworkBattleManagerBase.cs:226-229`）；开局记录 `cardTotalNum = deck.Count + 1`（`SBattleLoad.cs:1292`）。

---

## 7. 敌方抽牌序列（正常对战看不到翻开）

`OpponentDrawCardVfx.cs:45-74`：

```csharp
float z = 0f, y = 0f, num = 800f;                          // :47-49 默认 x 宽 800
bool isAdminWatch = GameMgr.GetIns().IsAdminWatch;
if (isAdminWatch) {
    num = Screen.width / Screen.height * 0.9f;             // :56
    z = (num2 > 1) ? (Mathf.Min(num2, 7f) * 0.15f - 1.3f) : (-0.7f);   // :57
    y = num2 * 0.02f - 0.15f;                              // :58 ← 玩家版是 -0.25f，这里 -0.15f
}
for (...) {
    if (!isAdminWatch && !_isOpen)
        parallelVfxPlayer.Register(InstantVfx.Create(() => drawCard.BattleCardView.CardTemplate.HideNameLabel())); // :67
    float x = (num / num2 * i + num / num2 * 0.5f - num * 0.5f) * (0.5f + num2 * 0.1f);   // :70
    parallelVfxPlayer.Register(list[i].Draw(new Vector3(x, y, z)));                        // :71
}
return SequentialVfxPlayer.Create(BattleManagerBase.GetIns().LoadCardResources(list), parallelVfxPlayer);  // :73
```

之后 `OpponentDrawCardToHandVfx`（`OpponentDrawCardToHandVfx.cs:9-21` 常量）：

| 常量 | 值 |
|---|---|
| `CARD_OPEN_WAIT_TIME` | `0.3f` |
| `CARD_SORT_OFFSET` | `220f` |
| `FIRST_CARD_POSITION_X` | `180f` |
| `CARD_POSITION_Y` | `50f` |
| `CARD_POSITION_Z` | `-50f` |
| `CARD_MOVE_TIME` | `0.2f` |
| `CARD_ROTATION` | `(-10, 0, 0)` |

主流程（`:32-99`）：每张卡 ▶ `se_sys_set_card_to_hand` + `InPlayView.RemoveCardFromView(..., 0.1f)` + `HandView.AddCardToView(view, inHandTime)` + `HandControl.AttachCardView`（`:39-42`），并加入 `ShowHandCardInfo()`（`:44`）；`isOpenDrawSkill` 时先 `OpenDrawSkillVfx` + `WaitVfx.Create(0.3f)`（`:59-74`）；之后 `WaitVfx.Create(inHandTime)`（`:76`，玩家侧传 **0.4f**，见 `BattlePlayerBase.cs:3241` / `BattleEnemy.cs:162`）→ `SetOnDraw(false)` → `CreateHideCardMeshesVfx` → 观战时 `UpdateHandCardsCost()` → `ShuffleHand()`。
另有未被调用的 `MoveOpenCenter`（`:101-119`）：`iTween.MoveTo/ RotateTo` 到 `(num2 + i*220, 50, -50)`，**0.2s，easeOutCirc**，`num2 = (count%2==1 ? -220 : -110) - 220*((count-1)/2)`。

---

## 8. 起手（Mulligan）抽牌参数——与正常抽牌不同

`PlayerMulliganDrawCardVfx.cs:21-36`：

```csharp
float num = Screen.width / Screen.height * 0.9f;
...
Vector3 pos = new Vector3(num / num2 * i + num / num2 * 0.5f - num * 0.5f,      // 无 (0.5+count*0.1) 放大
                          num2 * 0.02f - 0.25f,
                          num2 * 0.15f - 1.3f);                                  // 无 min(count,7) 截断
parallelVfxPlayer.Register(list[i].Draw(pos));
```

→ 与 `PlayerDrawCardVfx` 的差异：**x 少了 `*(0.5 + count*0.1)` 系数**，**z 不截断到 7**。
`PlayerMulliganDrawVfx.cs:8-27` 时序：抽牌 → `WaitVfx.Create(0.5f)` → `ShowMulliganUI()` → `WaitVfx.Create(0.1f)` → `ShowTimerUI()` → `WaitVfx.Create(0.4f)`（总 1.0s 额外等待）。
调用：`PlayerMulliganCtrl.cs:38`、`NetworkPlayerMulliganCtrl.cs:21`、`WatchPlayerMulliganCtrl.cs:19`。
`MulliganEndVfx.cs:36` → `PlayerEndDrawVfx(HandCardList)`。
起手 3 张：`INIT_HAND_CARD_NUM = 3`（`PlayerAndEnemyReadyVfx.cs:5`），牌库数显示 `maxDeck - 3`（`:19-34`）。

---

## 9. 音效 / 特效 / 资源名对照

### 9.1 音效（`SoundMgr.AssignSe`，`SoundMgr.cs:60-...`）

| 枚举 | Cri cue 名 | 行 | 在抽牌链里何时播 |
|---|---|---|---|
| `Se.TYPE.DRAW` | `se_sys_draw` | `SoundMgr.cs:90` | 翻牌位移开始的瞬间（`OpenCardVfx.cs:70`）；`OpponentOpenCardVfx.cs:51` 也有 |
| `Se.TYPE.DRAW_CARD_OPEN` | `se_sys_draw_card_open` | `SoundMgr.cs:92` | 旋转开始瞬间（`OpenCardVfx.cs:74`） |
| `Se.TYPE.DRAW_CARD_OPEN_LG` | `se_sys_draw_card_open_lg` | `SoundMgr.cs:91` | **无调用者**（`OpenCardVfx.cs:126` 死代码） |
| `Se.TYPE.SET_CARD_TO_HAND` | `se_sys_set_card_to_hand` | `SoundMgr.cs:97` | 卡入手牌瞬间（`PlayerDrawCardToHandVfx.cs:61`；敌方 `OpponentDrawCardToHandVfx.cs:39` 也用它，另有 `SYS_ENEMY_SET_CARD_TO_HAND`→`se_sys_enemy_set_card_to_hand`，`SoundMgr.cs:157`） |
| `Se.TYPE.SYS_CMN_CARD_DRAW_4` | `se_cmn_card_draw_4` | `SoundMgr.cs:104` | 多张散开时（`SpreadOutVfx.cs:108`） |
| `Se.TYPE.SYS_CMN_CLASS_DECKOUT_1` | `se_cmn_class_deckout_1` | `SoundMgr.cs:174` | 牌库耗尽（`PlayerDeckOutVfx.cs:19`） |

枚举序号（`Se.cs:9-140`，`NONE = 0`）：`DRAW = 50`、`DRAW_CARD_OPEN_LG = 51`、`DRAW_CARD_OPEN = 52`、`SET_CARD_TO_HAND = 57`、`SYS_CMN_CARD_DRAW_4 = 96`（= 行号 − 11）。

### 9.2 特效枚举与「实际资源名在哪」

`EffectMgr.EffectType` 定义在 `EffectMgr.cs:12-...`：`NONE=0`（`:14`）、`CMN_CARD_DRAW_2`（`:20`）、`CMN_CARD_DRAW_4`（`:21`）、`CMN_CARD_RARE_1`（`:29`）。

播放入口：
- `EffectMgr.Start(type, pos)`（`EffectMgr.cs:991-1002`）：按枚举在已加载的 `_effectList` 里找**未在播放**的同类型实例并 `Play(pos, obj)`。
- `EffectMgr.Start(type, pos, rot, layer)`（`:974-989`）。

**实际 prefab 路径来自数据表**，不来自代码（`EffectMgr.cs:428-507`）：

```csharp
public List<string> InitCommonEffect(string filePath, bool isBattle = false, ...)
{
    IList list = JsonMgr.GetJSON(filePath);                     // :449
    foreach (IDictionary item2 in list) {
        EffectType type = ToStrType(item2["TYPE"].ToString());  // :463 枚举名
        string sePath = item2["SEPATH"].ToString();              // :464 自带 SE cue 名
        string path   = item2["PATH"].ToString();                // :465 特效 prefab 路径
        num = int.Parse(item2["NUM"].ToString());                // :466 预实例化数量
        ... isFollowScale = item2["SCALE_FOLLOW"] == "1" ...      // :467-470
    }
    ... GetAssetTypePath(path, AssetLoadPathType.Effect2D) ...    // :472
}
```

战斗侧加载：`SBattleLoad.cs:638` `InitCommonEffect("Json/EffectBattleData", isBattle: true, isField: false, isBattleEffect: true)`。
枚举 ← 字符串映射：`EffectMgr.ToStrType`（`:884-886`），即 JSON 里的 `TYPE` 与 C# 枚举名逐字相同（`"CMN_CARD_DRAW_2"`）。
**结论**：`CMN_CARD_DRAW_2 / CMN_CARD_DRAW_4 / CMN_CARD_RARE_1` 只能确认"枚举键 + 播放位置/旋转/染色规则"，**prefab 文件名、粒子数量、时长、SEPATH 都在 `Json/EffectBattleData` 与 AssetBundle 里，反编译包中没有该文件**（已确认：`D:\逆向工程` 下不存在 `EffectBattleData*`、`*.acb`、`cmn_card_draw*` 任何资源）。

播放位置/旋转规则（代码里确定的部分）：

| 场景 | 位置 | 旋转 | 出处 |
|---|---|---|---|
| 单张入手 | 卡位置 | 复制卡的 rotation | `PlayerDrawCardToHandVfx.cs:82-84` |
| 抽到传说（翻开后） | 卡位置 | 复制卡的 rotation | `OpenCardVfx.cs:116-120` |
| 多张散开 | 卡位置 | 复制卡的 rotation + 粒子整体染色 | `SpreadOutVfx.cs:91-93` |
| Token 入手 | 卡位置 | 复制卡的 rotation | `DrawTokenVfx.cs:96-98` |
| 抽牌技能翻开 | 卡位置（传说→`CMN_CARD_RARE_1`，否则`CMN_CARD_DRAW_2`） | 复制卡的 rotation | `OpenDrawSkillVfx.cs:41-46` |
| 从手牌翻开 | 同上二选一 | — | `OpenCardFromHandVfx.cs:40` |

---

## 10. 复刻参数表（可直接照抄到 Godot）

### 10.1 抽 1 张牌的时间轴（玩家，非传说，手牌可见）

| # | 相对时刻 (s) | 动作 | 时长 | 缓动 | 代数/目标 | 出处 |
|---|---|---|---|---|---|---|
| 0 | −（构造） | 牌库 −1、状态栏数字更新 | — | — | `SetDeck(n-1)` | `BattlePlayerBase.cs:2913,2917` |
| 1 | −（构造） | 隐藏 1 张牌堆假卡 | 0 | — | `holderCards[inactiveCount]` | `DummyDeckChangeCardVfx.cs:41` |
| 2 | 0.000 | 卡贴到牌堆顶：`position = CardHolder.position`，`localEulerAngles=(0,180,-80)`，父=`Battle3DContainer` | 0 | — | — | `OpenCardVfx.cs:43-45` |
| 3 | 0.000 | ▶ `se_sys_draw` | — | — | — | `OpenCardVfx.cs:70` |
| 4 | 0.000 | 位移到落点 | **0.40** | **easeOutCirc**（`1-√(1-t²)`，`iTween.cs:4257-4262`） | `pos=(0.25n, -0.23n, -0.7)`，`n=aspect*0.9`；`islocal:false`（世界） | `OpenCardVfx.cs:71`、`PlayerDrawCardVfx.cs:58` |
| 5 | 0.000 | 旋转 `(0,176,-80)`→`(0,-2,0)` | **0.39** | **easeOutQuad**（`1-(1-t)²`） | `iTween.RotateFrom`，`islocal:true` | `OpenCardVfx.cs:72-73` |
| 6 | 0.000 | ▶ `se_sys_draw_card_open` | — | — | — | `OpenCardVfx.cs:74` |
| 7 | 0.000 | 缩放到 `(1,1,1)` | **0.39** | **easeOutExpo**（`1-2^(-10t)`） | `islocal:true` | `OpenCardVfx.cs:75` |
| 8 | 0.400 | 传说才播 ▶ `CMN_CARD_RARE_1` | — | — | 位置/旋转=卡 | `OpenCardVfx.cs:112-122` |
| 9 | 0.400 | 改挂 `PlayerCardPlace`，Layer 10 | 0 | — | — | `PlayerDrawCardToHandVfx.cs:49-53` |
| 10 | 0.400 | ▶ `se_sys_set_card_to_hand` | — | — | — | `PlayerDrawCardToHandVfx.cs:61` |
| 11 | 0.400 | 手牌重排：move+rotate+scale 到 `_cardPos/_cardRot/_cardScale` | **0.25** | 三者均 **easeOutQuad**（玩家） | 见 §10.3 | `PlayerDrawCardToHandVfx.cs:63`、`HandControlPlayer.cs:76,85,86` |
| 12 | 0.650 | `ShowHandCardInfo` + `CalcHandCost` + ▶ `CMN_CARD_DRAW_2` | 0 | — | 位置=卡，旋转=卡 | `PlayerDrawCardToHandVfx.cs:78-86` |
| 13 | 0.650 | `SetOnDraw(false)` | 0 | — | — | `PlayerDrawCardToHandVfx.cs:38-41` |

**总时长 ≈ 0.65 s**（翻牌 0.40 + 入手 0.25）；Godot 里建议：
`easeOutCirc` 自定义 `1.0 - sqrt(1.0 - t*t)`；`easeOutQuad`→`Tween.TRANS_QUAD/EASE_OUT`；`easeInOutQuad`→`TRANS_QUAD/EASE_IN_OUT`；`easeOutExpo`→`TRANS_EXPO/EASE_OUT`；`easeInExpo`→`TRANS_EXPO/EASE_IN`。

### 10.2 位移/旋转/缩放曲线速查

| 用途 | 属性 | 时长 | 缓动 | 坐标系 | 出处 |
|---|---|---|---|---|---|
| 玩家翻牌位移 | position | 0.40 | easeOutCirc | 世界（`islocal:false`） | `OpenCardVfx.cs:71` |
| 玩家翻牌旋转 | localEulerAngles（176/176→-2） | 0.39 | easeOutQuad | 局部 | `OpenCardVfx.cs:73` |
| 玩家翻牌缩放 | scale | 0.39 | easeOutExpo | 局部 | `OpenCardVfx.cs:75` |
| 抽牌技能居中 | position | 0.40 | easeOutCirc | 局部→`(0,-50,-300)` | `OpenCardVfx.cs:95` |
| 抽牌技能旋转/缩放 | rot/scale | 0.40 | easeOutQuad / easeOutExpo | 局部 | `OpenCardVfx.cs:100,105` |
| 多张散开排位 | position/rotation | 0.20 | easeInOutQuad | 局部 | `SpreadOutVfx.cs:84-85` |
| 玩家手牌重排 | pos/rot/scale | 调用方(0.25/0.2/0.4) | 均 easeOutQuad | 局部 | `HandControlPlayer.cs:76,85,86` |
| 敌方手牌重排 | pos/rot | 调用方 | easeInOutQuad | 局部 | `HandControlEnemy.cs:47-48` |
| 敌方手牌重排 | scale | 调用方 | **easeInExpo** | 局部 | `HandControlEnemy.cs:49` |
| 牌堆开场归位 | position | 0.30（delay=(childCount-i)*0.01） | easeOutExpo | 局部 | `OpeningVfx.cs:236` |
| Token 翻开 | rotation | 0.20 | easeOutExpo | 局部 | `DrawTokenVfx.cs:52` |
| 牌库耗尽飞出 | pos/rot | 1.00+0.50 | easeInOutExpo / easeInExpo | 局部 | `PlayerDeckOutVfx.cs:22-27` |

### 10.3 手牌插入与重排规则（可直接实现）

设 `n` = 手牌张数（含新卡），`i` = 0 起序号，`W = min(200*(n-1), 700)`，`rate = i/(n-1)`（n=1 时 0）：

| 布局 | 位置（相对手牌根，手牌根 localPosition = 玩家 `(500,-510,10)` / 敌方 `(-500,530,10)`） | 旋转 | 缩放 |
|---|---|---|---|
| Fan 常态 | `(W*0.7*rate - W*0.35, 40, 0)` | `(0,-5,0)` | `(0.7,0.7,0.7)` |
| Fan 放大 | `(W*(1+0.04n)*rate - W*(1+0.04n)*0.5 + 130, t2*40+40, -30)` | `(camRot.x, -5, rate*(-1.5n) + 0.75n)` | `(1.2,1.2,1.2)` |
| Flat 常态 | `(W*0.7*rate - W*0.35, 40, 0)` | `(0,-5,0)` | `(0.7,0.7,0.7)` |
| Flat 放大 | `(W*(1+0.05n)*rate - W*(1+0.05n)*0.5 + 65, 115, -30)` | `(0,-5,0)` | `(1.2,1.2,1.2)` |
| 敌方 Fan 常态 | `(-500 + W*0.7*rate - W*0.35, -7.5, 0)` | `(0,183,0)` | `(0.7,0.7,0.7)` |
| 敌方 Fan 放大 | `(-500 + W*rate - W*0.5, t2*40-20, -35)` | `(0, 183, -(rate*(-1.5n) + 0.75n))` | `(1.1,1.1,1.1)` |

其中
`t2 = rate<0.5 ? easeOutQuad(2*rate)*0.5 : easeOutQuad(2*rate-1)*0.5 + 0.5`（玩家，`HandTRSCalculatorBasePlayer.cs:35-47`）；
敌方 `CalcParam` 的右半段用 **easeInQuad**（`HandTRSCalculatorBaseEnemy.cs:35-47`），`rate` 反向（`1 - i/(n-1)`）。
新卡插入流程（顺序不能变）：`AddCardToView(view, t)` → 把 view 加入内部列表 → 全列表重算 TRS → 对**每张**卡 `iTween.Stop` + 清残留 → move/rotate/scale 到目标（`HandControlPlayer.cs:64-89`）。再 `AttachCardView` 把 view 改挂到手牌根（`HandControl.cs:62-70`）。
卡面/卡背：rotation 额外加 `(0,0,0)`（可见）或 `(0,180,0)`（不可见）（`HandControlPlayer.cs:9-11,80,85`）。
手牌上限 **9**（`HandCardList.Count >= 9` 时抽到的牌直接送墓，`BattlePlayerBase.cs:3283-3301`）。

### 10.4 牌堆表现参数

| 项目 | 原版值 | 出处 |
|---|---|---|
| 牌堆根位置（BtlContainer 局部） | 玩家 `(950,-190,0)` rotZ 80°；敌方 `(965,180,0)` rotZ 100° | `SBattleLoad.cs:79-85` |
| collider 尺寸 | `(70,90,50)`（随后被 `enabled=false`） | `SBattleLoad.cs:77,1103` |
| 每张假卡偏移 | `(-0.1, 0.4, 0.1) * (idx+1)` | `SBattleLoad.cs:1055-1058,1068` |
| 假卡数量 | `牌库张数 + 1`（+1 = `sleeve_deckout` 指示卡） | `SBattleLoad.cs:862-866` |
| 假卡材质 | 前 count 张 = 玩家/敌方 sleeve 材质；最后 1 张 = `sleeve_deckout_M` + `sleeve_deckout` | `SBattleLoad.cs:849-851,864` |
| 假卡 mesh / prefab | mesh `sleeve_md_Card`（SleeveMesh）；prefab `sleeve_CardBase`（CardDeco） | `SBattleLoad.cs:840-842` |
| 假卡缩放 | `CARD_BASE_STAY_SCALE = (18,18,18)`；deckout 卡 ×0.95 | `Global.cs:409`、`SBattleLoad.cs:865` |
| 材质开关 | `_CullMode=2`，`_ZWriteMode=1` | `SBattleLoad.cs:1072-1073` |
| 假卡不可点 | `Collider.enabled = false`；`CardHolder` 的 `BoxCollider.enabled=false`、`UIGrid.enabled=false` | `SBattleLoad.cs:1063,1099,1103` |
| 抽 1 张 | 隐藏第 `inactiveCount` 个 active 假卡（瞬时，0 秒） | `DummyDeckChangeCardVfx.cs:41` |
| 开场 | 父节点先 SetActive(false)，再 SetActive(true) + 每张 `MoveFrom` 0.3s/delay 0.01s | `OpeningVfx.cs:403-404,233-237` |
| 牌库耗尽 | 取索引 `GetMaxDeckCount()` 的子物体飞出（1.0s + 0.5s），▶ deckout SE/特效 + 相机抖动 | `PlayerDeckOutVfx.cs:18-41` |
| 牌库上限 | 默认 40 | `BattleManagerBase.cs:695-698` |

Godot 落地建议（与本项目现有 `scripts/DeckPile.gd` 对齐）：
- 厚度按「每张 0.4 单位 / 卡高」比例复刻；代码里同空间的卡尺寸参照有两个（collider 90 vs mesh 缩放 18），**建议先用 `0.4 / 90 ≈ 0.44%` 作为薄牌堆，再用 `0.4 / 18 ≈ 2.2%` 作为明显厚度做 A/B 对比**（两者都在 §11 的"prefab 未知项"里）。
- 每张的横向/纵向/前后分量比例为 `(-0.1 : 0.4 : 0.1)`，即**主方向 1、副方向各 0.25**；在 2D 里可映射为「沿主轴每张 1px、另一轴 0.25px」。
- 抽 1 张时**立即**把显示层数减 1（原版是瞬时，不是动画结束时），再加一个独立的"飞牌"图层做 0.4s easeOutCirc 的位移。

### 10.5 世界单位 ↔ 像素 的换算（**必须自行标定**）

- `OpenCardVfx.MoveCard` 把落点当**世界坐标**（`islocal:false`，`OpenCardVfx.cs:71`），而牌堆原始位置 `(950,-190,0)` 是 `BtlContainer` 的**局部坐标**（`SBattleLoad.cs:1096`）；`BtlContainer` 是 `Battle3DContainer` 的子物体（`SBattleLoad.cs:839`），`HandDeck` 还被 `UIAnchor` 绑到 `Battle3DContainer/Camera`（`SBattleLoad.cs:1107-1110`）。
- 由 `950 局部 ≈ 0.95 世界`、`落点 x ≈ 0.4 世界 ≈ 400 局部（= 2 个卡宽）` 推断 `BtlContainer.localScale ≈ 0.001`（**推测，未在代码中赋值，见 §11**）。
- 在 Godot（本项目为 2D Control 坐标）建议的做法：**不照搬绝对值，而是把原版"卡宽 = 200 局部单位"当作锚**，即
  `1 局部单位 = 卡宽像素 / 200`（本项目 `Card`/`DeckPile` 用 `CARD_SIZE=(58,80)` → 约 0.29 px/单位），再把 `HAND_POS_PLAYER=(500,-510,10)`、`CardHolder=(950,-190,0)` 等按此比例映射到屏幕。

---

## 11. 「代码里确定」vs「只有 prefab/贴图里才有」

### 11.1 代码里 100% 确定（可直接实现）

- 所有时长、缓动类型、iTween 参数（`OpenCardVfx.cs:71-75`、`SpreadOutVfx.cs:84-85`、`HandControlPlayer.cs:76-86` 等）。
- 所有公式：落点（`PlayerDrawCardVfx.cs:58`）、扇形/平铺 TRS（§3.4）、散开排序（`SpreadOutVfx.cs:117-131`）。
- 所有枚举与逻辑顺序：`StopCardMask → PrepareMoveCard → DummyDeckChange → MoveCard →(结束) MoveToHand → AddCardToView/AttachCardView → OnHand`。
- 音效 cue 名（`SoundMgr.cs:60-...`）、特效枚举键与播放位置/旋转规则。
- 牌堆假卡数量、偏移步长、材质开关、开场/耗尽流程。
- 缓动曲线数学式：`iTween.cs:4110-4131,4233-4262`（`easeInQuad/easeOutQuad/easeInOutQuad/easeOutExpo/easeOutCirc`），`MotionUtils.cs:39-159`（同名的自定义版本，注意 `MotionUtils.easeOutQuad = 1-(1-t)²` 与 iTween 版一致）。

### 11.2 代码看不到、必须从 prefab/贴图/JSON 取

| 项 | 为什么看不到 | 代码里的线索 |
|---|---|---|
| `CMN_CARD_DRAW_2 / CMN_CARD_DRAW_4 / CMN_CARD_RARE_1` 的 **prefab 路径、粒子参数、自身 SE** | 实际路径写在 `Json/EffectBattleData` 的 `PATH/SEPATH/NUM` 字段（`EffectMgr.cs:463-472`），反编译包中没有该 JSON / AssetBundle | 只知枚举名、播放位置与旋转、`NUM` 决定预实例化数量 |
| `BtlContainer` / `Battle3DContainer` 的 **localScale、相机 FOV/位置** | 来自 `Prefab/Container/_Battle3DContainer`（`SBattleLoad.cs:576-577,834-836`）与 `m_BtlContainer` 序列化字段 | 由 950 局部 ↔ ~0.95 世界推断 ≈0.001；`BattleManagerBase.ChangeCameraFieldOfView(ScreenAspect)`（`SBattleLoad.cs:1130`）说明 FOV 随宽高比变 |
| `sleeve_CardBase` / `sleeve_md_Card` 的 **网格尺寸** | 外部资源 | 缩放 18（`Global.cs:409`）、collider (70,90,50)（`SBattleLoad.cs:77`）；两者互推不一致 → 必须看 prefab |
| `CardHolder`（deck pile 根）的 **自身缩放/子节点结构** | `_BtlContainer` prefab | 只有 `UIGrid.enabled=false`、BoxCollider 尺寸与 enabled=false（`SBattleLoad.cs:1097-1103`） |
| `HandDeck`/`EHandDeck`/`PlayerCardPlace` 的 **prefab 内 localPosition/localScale 与 UIAnchor 参数** | `_BtlContainer` prefab | `HandControl` 会在运行时覆盖 `HandDeck.localPosition = BaseHandPos`（`HandControl.cs:52`）；`PlayerCardPlace` 只被 `Find("PlayerCardPlace")`（`SBattleLoad.cs:880`） |
| 卡牌正/背面 mesh、`CardNormalTemp`/`FieldNormalMeshTemp`/`SkillIconTemp` 的层级与尺寸 | CardFrame prefab（`SBattleLoad.cs:881-883` 加载 `UnitCard/SpellCard/FieldCard`） | 只知道要 SetActive 哪些节点（`OpenCardVfx.cs:47-57`） |
| `shader` 名 | `Custom/Card/Unlit Diffuse`（`SBattleLoad.cs:899`）、`_CullMode/_ZWriteMode/_Color/_MaskTex` 属性名 | 属性名可照抄 |
| iTween 的 `Defaults`（未显式给 `time`/`easetype` 时） | `iTween.cs:64-78`：`time = 1f`（`:66`）、`easeType = easeOutExpo`（`:74`）、`isLocal = false`（`:78`） | 本报告涉及的调用**全部显式给了 time/easetype/islocal**，默认值只影响遗漏处 |
| 恢复/回放模式下的时长 | `WaitVfx.Create` 在 `IsRecovery` 时返回 0（`WaitVfx.cs:26-31`） | 逻辑确定，但"何时进入恢复态"由网络层决定 |

### 11.3 明确的不确定点（建议后续用真机录屏/资源解包验证）

1. `BtlContainer` 的缩放与相机参数（决定落点在屏幕上的实际位置）；§10.1 的 `pos` 在 9:16 竖屏下为 `(0.127, -0.116, -0.7)`，在 16:9 下为 `(0.4, -0.368, -0.7)`——同一份代码对两种宽高比给出不同的"屏幕落点"，说明原版就是按宽高比自适应的，复刻时**务必也用 `viewport_aspect * 0.9` 这个归一化量**，而不是固定像素。
2. `PlayerDrawCardVfx.cs:58` 的落点与 `OpenCardVfx.cs:71` 的世界坐标语义之间隔着一个 `BtlContainer` 缩放；`z=-0.7` 这种"贴着相机"的值暗示卡在相机前方很近距离——需要相机参数才能定标。
3. 牌堆"厚度"的像素级观感（0.4/90 还是 0.4/18，见 §10.4）。
4. 翻牌时 `ScaleTo(1,1,1)` 的**起始缩放值**代码里没有显式设置（取决于卡被改挂到 `Battle3DContainer` 时的既有 scale，可能来自 `CardWrapObject`/prefab）。
5. `CMN_CARD_DRAW_2` 在"翻牌结束"和"入手完成"两处都被用到（前者仅传说走 `CMN_CARD_RARE_1`，后者普通抽牌走 `CMN_CARD_DRAW_2`）；多张散开用 `CMN_CARD_DRAW_4`。三个特效的具体形态、粒子时长、是否带自身 SE 需要解包确认。

---

## 12. 对本项目（Godot / D:\CardGame）的落地映射建议

| 原版 | 本项目现状 | 建议 |
|---|---|---|
| 3D 假卡堆 + `(-0.1,0.4,0.1)` 步长 | `scripts/DeckPile.gd` 用 `LAYER_STEP=3.0px`、`CARDS_PER_LAYER=5`、`MAX_LAYERS=24`（`DeckPile.gd:12-16`） | 原版是「每张一张假卡、抽一张隐藏一张」；若要 1:1，改成每张 1 层、步长 = 卡高×0.44%（`≈0.35px`）会太薄不直观，建议保留"每 N 张一层"的简化但在文档/注释里标注这是**有意偏离** |
| 抽牌瞬时减层 + 0.4s 翻牌动画 + 0.25s 入手 | `DeckPile.animate_draw()` 0.45s 位移+淡出（`DeckPile.gd:16,117-126`） | 可拆成两段：`0.40s` 位移（`easeOutCirc`，必须自定义）+ `0.25s` 入手旋转/缩放（`easeOutQuad`）；总时长对齐 **0.65s** |
| 手牌扇形 `W=min(200(n-1),700)`、`t2` 弧高 40、`rate` 线性 x | `Main.gd:_layout_hand()` 用像素均匀铺开 | 若要复刻扇形，把 `W` 按「卡宽 × (n-1) 封顶 3.5 卡宽」换算，y 加 `t2*40*比例`，rotation 加 `rate*(-1.5n)+0.75n` 度（放大态） |
| 音效 cue | 项目暂无 | 至少补 4 个时机：位移开始（`se_sys_draw`）、旋转开始（`se_sys_draw_card_open`）、入手（`se_sys_set_card_to_hand`）、多张散开（`se_cmn_card_draw_4`） |
| 特效 | 项目暂无 | `CMN_CARD_DRAW_2` 在入手瞬间播、位置=卡位置、旋转=卡旋转；传说用 `CMN_CARD_RARE_1`（翻牌结束时） |
| 「返回/恢复」模式跳过动画 | — | 原版把所有 `WaitVfx` 归零、`OpenCardVfx.MoveCard` 返回空 vfx（`WaitVfx.cs:26-31`、`OpenCardVfx.cs:63-66`），复刻时建议也留一个 `skip_anim` 开关 |

---

### 附：本文引用的核心文件清单

| 文件 | 作用 |
|---|---|
| `PlayerDrawCardVfx.cs` | 玩家抽牌：落点公式 + 并行翻开 |
| `Wizard/Battle/View/Vfx/PlayerOpenCardVfx.cs` | 玩家翻牌四步 |
| `Wizard/Battle/View/Vfx/OpenCardVfx.cs` | 翻牌基类：iTween 参数、常量、音效、传说特效 |
| `Wizard/Battle/View/Vfx/OpponentOpenCardVfx.cs` | 对手翻牌（正常模式不翻） |
| `PlayerDrawCardToHandVfx.cs` | 卡入手牌：0.25s + `CMN_CARD_DRAW_2` |
| `Wizard/Battle/View/Vfx/PlayerEndDrawVfx.cs` | 抽牌结束 → `MoveToHand` |
| `Wizard/Battle/View/Vfx/SpreadOutVfx.cs` | 多张散开排序/特效/音效 |
| `Wizard/Battle/View/Vfx/DrawTokenVfx.cs` | Token 抽牌 + 入手 |
| `Wizard/Battle/View/Vfx/DummyDeckChangeCardVfx.cs` | 牌堆假卡增删 |
| `SBattleLoad.cs` | 牌堆位置/厚度/材质/开场 |
| `HandViewBase.cs` / `PlayerHandView.cs` / `HandControl.cs` / `HandControlPlayer.cs` / `HandControlEnemy.cs` | 手牌插入与重排 |
| `HandTRSCalculator*.cs` | 扇形/平铺 TRS 全部公式与常量 |
| `BattlePlayerBase.cs` / `BattlePlayer.cs` / `BattleEnemy.cs` / `BattlePlayerVfxCreatorBase.cs` | 抽牌调用链与顺序 |
| `SoundMgr.cs` / `Se.cs` | SE cue 名与枚举 |
| `EffectMgr.cs` | 特效枚举与 JSON 驱动的加载方式 |
| `iTween.cs` / `MotionUtils.cs` | 缓动数学式 |
| `Global.cs` | `CARD_BASE_STAY_SCALE` |
