# 原版 Shadowverse 伤害飘字（damage floating number / 卡堆）逆向报告

- 目标：为在 Godot 4 中 1:1 复刻「伤害/治疗飘字」提供实现依据。
- 资料源：`D:\逆向工程\decompiled\Assembly-CSharp\`（5636 个 .cs，Unity 2020.3.18f1，Shadowverse）。
- 约定：本文所有路径均相对 `D:\逆向工程\decompiled\Assembly-CSharp\`；每条结论都给出 `文件:行号`。
- 标注：**【码】** = C# 代码里确定的；**【资源】** = 只在 prefab / 材质 / JSON 配置里，代码看不到（本环境只有反编译 .cs，无法打开 bundle，见 §10 与 §12）。

---

## 0. 结论速览（TL;DR）

1. 飘字本体是**一个 UI 粒子预制体**（每位数一个子 ParticleSystem），数字用 `TextureSheetAnimationModule.startFrame = 数字/16` 从 16 帧数字图集里选帧。代码只负责「选帧 + 排位 + 排序层级 + 2.5 秒后销毁」，**上浮/缩放/淡出全部在 prefab 里**。
   - `Wizard/Battle/View/Vfx/DamageVfxBase.cs:137-155`
2. 伤害数字预制体：`cmn_battle_damage_1`（`DamageVfx.cs:12`）；治疗数字：`cmn_battle_heal_1`（`HealingVfx.cs:5`）；两者共用同一个 `DamageVfxBase`，所以**治疗数字的位数排布、字距、生命周期与伤害数字完全一致**，区别只是预制体、无红闪/无击退/无震屏。
3. **「卡堆」的真相**：`BattleManagerBase.DamageCount` 是一个**全战斗单调递增的计数器**，每播出一个飘字 `++` 一次，并直接赋给数字粒子的 `ParticleSystemRenderer.sortingOrder`。**没有任何位置偏移、没有任何排队/错帧**；同一目标同一帧的多次伤害数字完全重叠，只有 sortingOrder 递增（后出的盖在前面）。全场从 1 开始，**任何地方都不重置**。
   - `BattleManagerBase.cs:403`、`DamageVfxBase.cs:125,148`
4. 数字排布公式（本地 x，单位=容器局部空间，不是像素）：`x_j = j * (-0.26) + digit * 0.26 * 0.5 - 0.13`，等价的 `x_j = 0.13 * (digit - 1 - 2j)`，即**字距恒定 0.26、整体以原点居中、个位在最右(j=0)、高位在左**。
   - `DamageVfxBase.cs:146`（常量在 `:13`）
5. 目标为主战者（Class）时，飘字 **Y 每帧被强制钉在 `卡Y + 0.4`（我方）/ `卡Y - 0.3`（敌方）**，因此 prefab 的上浮位移对主战者飘字无效；随从飘字不钉 Y。
   - `DamageVfxBase.cs:19,21,90-106`
6. 反伤飘字 = 普通飘字 + `StartPosition.y += -0.25 * 击退方向`（`ReflectedDamageVfx.cs:7-9`），其余（红闪、击退、震屏、`cmn_card_damage_*` 打击特效）全部继承。
7. 伤害 ≥ 7 触发震屏 + 强打击特效：`ShakeScreen(value)`（内部 clamp 到 10，位移量 = `10*0.02=0.2`、时长 = `10*0.05+0.2=0.7s`）+ `CMN_CARD_DAMAGE_3`；否则 `CMN_CARD_DAMAGE_1`。
   - `DamageVfx.cs:8,56-64`、`Skill_special_win.cs:8-14,67-74`

---

## 1. 类结构与继承关系（全部来自代码）

```
VfxBase                                  Wizard/Battle/View/Vfx/VfxBase.cs:5
├─ SequentialVfxPlayer                   SequentialVfxPlayer.cs:8
│   └─ DamageVfxBase (abstract, IEffectVfx)   DamageVfxBase.cs:9
│       ├─ DamageVfx              (_effectName = "cmn_battle_damage_1")   DamageVfx.cs:6,12
│       │   └─ ReflectedDamageVfx                                         ReflectedDamageVfx.cs:5
│       └─ HealingVfx             (_effectName = "cmn_battle_heal_1")     HealingVfx.cs:3,5
├─ ParameterChangeVfx                    ParameterChangeVfx.cs:3   （卡面数字缩放，非飘字）
├─ StartBuffVfx / StopBuffVfx            StartBuffVfx.cs:3 / StopBuffVfx.cs:3
└─ RefreshHealthVfx (VfxBase)            RefreshHealthVfx.cs:5
   RefreshAttackVfx (VfxBase)            RefreshAttackVfx.cs:5
```

创建入口（谁 new 出飘字）：`Wizard/Battle/View/Vfx/CardVfxCreatorBase.cs:219-236`，子类覆盖见 §6。
接口声明：`ICardVfxCreator.cs:77,79`。

---

## 2. `DamageVfxBase` 逐项参数（飘字核心）

### 2.1 常量

| 常量 | 值 | 出处 | 含义 |
|---|---|---|---|
| `DAMAGE_ANIMATION_LENGTH` | `2.5f` | `DamageVfxBase.cs:11` | 飘字存活时间（注意：第 90 行用的是字面量 `2.5f`，常量未被引用） |
| `DAMAGE_TEXT_MARGIN` | `0.26f` | `DamageVfxBase.cs:13` | 相邻数字的横向字距 |
| `DAMAGE_MAX_VALUE` | `9999` | `DamageVfxBase.cs:15` | 显示上限（`Mathf.Min(Mathf.Abs(value), 9999)`） |
| `TEXTURE_SHEET_MAX` | `16` | `DamageVfxBase.cs:17` | 数字图集总帧数；选帧为 `digit / 16f` |
| `PLAYER_CLASS_DAMAGE_EFFECT_POSITION` | `0.4f` | `DamageVfxBase.cs:19` | 我方主战者飘字 Y 偏移（+） |
| `ENEMY_CLASS_DAMAGE_EFFECT_POSITION` | `0.3f` | `DamageVfxBase.cs:21` | 敌方主战者飘字 Y 偏移（−） |

### 2.2 构造：资源加载

```csharp
// DamageVfxBase.cs:53-67
protected DamageVfxBase(IBattleCardView targetCardView)
{
    _battleMgr = BattleManagerBase.GetIns();
    _targetCardView = targetCardView;
    string assetTypePath = Toolbox.ResourcesManager.GetAssetTypePath(_effectName, ResourcesManager.AssetLoadPathType.Effect2D);
    Register(new WaitLoadResourceVfx(assetTypePath));          // 先异步加载
    Register(InstantVfx.Create(() =>
    {
        _damageEffect = Toolbox.ResourcesManager.LoadObject(... isfetch: true) as GameObject;
        GameMgr.GetIns().GetEffectMgr().SetUIParticleShader(_damageEffect, () => { IsLoadEnd = true; });
        // SetUIParticleShader: 把子渲染器（名字含 ef_/sp_/img_）的材质从 Effect/Images/Materials/<名字> 载入
        // EffectMgr.cs:662-770（GameObject 重载）, 806-820（AttachMaterialAndShader）；Shader.Find(同名) 重新绑定（保证打包 shader 不被裁掉）
    }));
}
```

- 关键：预制体加载路径 = `Effect/Effects/<_effectName>`（`Cute/ResourcesManager.cs:314-316`）。
- 飘字对象**不挂在卡上**，而是 `Instantiate` 后挂到 `EffectMgr.EffectContainer`（全局 UI 特效容器，prefab `Prefab/Container/_EffectContainer`，`EffectMgr.cs:356,390-391`），再用**世界坐标**摆到卡的位置。

### 2.3 播放 + 生命周期

```csharp
// DamageVfxBase.cs:69-116
protected IEnumerator StartShowValue(int value)
{
    IsEnd = true;                                        // :71 立即标记 vfx 链结束，链条不等 2.5s
    if (BattleManagerBase.GetIns().IsRecovery) {         // :72-77 断线恢复/快进：不创建对象、不 ++、
        OnStartAnimation.Call(value); OnEndAnimation.Call(); yield break;   //   只抛事件
    }
    if (!IsLoadEnd) yield return null;                   // :78-81 等一帧加载
    _numberObject = Object.Instantiate(_damageEffect);   // :82
    _numberObject.transform.parent = GameMgr.GetIns().GetEffectMgr().EffectContainer.transform;  // :83
    if (_battleMgr is NewReplayBattleMgr nrb) nrb.StopEffectObjectList.Add(_numberObject);       // :84-87
    SetupNumberAnimation(value);                         // :88
    float startTime = Time.time;
    while (Time.time < startTime + 2.5f && _numberObject != null)   // :90 固定 2.5s
    {
        Vector3 position = _numberObject.transform.position;
        if (_targetCardView.CardInfo.IsClass)            // :93-103 主战者：每帧钉 Y
            position.y = StartPosition.y + (_targetCardView.CardInfo.IsPlayer ? 0.4f : -0.3f);
        _numberObject.transform.position = position;      // :104 只改 y，x/z 保持 prefab 现状
        yield return null;
    }
    if (_numberObject != null) { ...Destroy(_numberObject); }  // :107-114
    OnEndAnimation.Call();                               // :115
}
```

- `StartPosition`（默认实现）：`_targetCardView.CardWrapObject.transform.position`；空对象时 `Vector3.zero`（`DamageVfxBase.cs:33-43`）。
- 飘字播放是**协程**，由 `BattleCoroutine` 单独跑（`DamageVfx.cs:34`、`HealingVfx.cs:13`），与 vfx 链解耦。

### 2.4 选帧 / 排位 / 排序（「卡堆」核心）

```csharp
// DamageVfxBase.cs:123-157（原文）
protected virtual void SetupNumberAnimation(int value)
{
    _battleMgr.DamageCount++;                                       // :125  ← 卡堆计数自增
    _numberObject.transform.position = StartPosition;               // :126
    _numberObject.SetActive(true);                                 // :127
    int num = Mathf.Min(Mathf.Abs(value), 9999);                   // :128
    List<ParticleSystem> list = new List<ParticleSystem>();
    for (int i = 0; i < _numberObject.transform.childCount; i++)    // :130-133  子物体=位数槽位
        list.Add(_numberObject.transform.GetChild(i).GetComponent<ParticleSystem>());
    for (int j = 0; j < list.Count; j++)
    {
        Transform transform = list[j].transform;
        int digit = MotionUtils.GetDigit(num);                      // :137  位数
        if (j < digit)
        {
            float num2 = Mathf.Floor((float)num / Mathf.Pow(10f, j)) % 10f;   // :140  第 j 位数字(0..9)
            ParticleSystem.TextureSheetAnimationModule tsa = list[j].textureSheetAnimation;
            tsa.startFrame = new ParticleSystem.MinMaxCurve(num2 / 16f);      // :142,145  选帧 = digit/16
            float num3 = (float)j * -0.26f + (float)digit * 0.26f * 0.5f - 0.13f; // :146  横向排位
            transform.localPosition = new Vector3(num3, transform.localPosition.y, transform.localPosition.z); // :147
            list[j].GetComponent<ParticleSystemRenderer>().sortingOrder = _battleMgr.DamageCount;  // :148
            transform.gameObject.SetActive(true);                    // :149
        }
        else transform.gameObject.SetActive(false);                  // :153  多余槽位关闭
    }
    OnStartAnimation.Call(value);                                    // :156  事件（主战者语音/动作、见 §6）
}
```

- 位数：`MotionUtils.GetDigit`（`MotionUtils.cs:293-300`）：`value==0 → 1`，否则 `(int)Mathf.Log10(|value|)+1`。
- 排位等价式：`x_j = 0.26*(-j) + 0.13*(digit-1)`；`j=0` 为个位（最右），`j=digit-1` 为最高位（最左）；所有位以父节点原点为中心对称。
- `sortingOrder` 施加在 **子 ParticleSystemRenderer** 上（不是根），同一次飘字的所有位共享同一个值。
- **注意**：代码从不设置 `sortingLayerName`，只设 order；层级名沿用 prefab/容器默认。全工程 grep `sortingOrder` 确认：给**飘字数字**设 order 的只有这一处；另有一个无关的公共特效池 `Effect.cs:48`（`GetRenderer().sortingOrder = 4`）以及若干 UI/场景代码，均与飘字无关。
- `OnStartAnimation` / `OnEndAnimation` 事件定义：`DamageVfxBase.cs:49-51`。

### 2.5 其他成员

- `HideValue()` 只置 `IsEffectEnd = true`（`:118-121`）；`UpdateEffect()`/`RemoveCheck()` 空实现（`:159-165`）；`DestroyEffect()` 销毁 `_numberObject`（`:167-174`）。

---

## 3. `DamageVfx`（普通伤害飘字）

```csharp
// DamageVfx.cs 关键片段
public const int STRONG_DAMAGE_VALUE = 7;                 // :8
private const float KNOCKBACK_AMOUNT = 0.1f;              // :10
protected override string _effectName => "cmn_battle_damage_1";   // :12

// 构造 :18-26  受击卡红闪
iTween.ColorTo(cardMesh, Hash("color", Color.red, "time", 0f));
iTween.ColorTo(cardMesh, Hash("color", Color.white, "time", 0.2f, "delay", 0.1f));

// 构造 :27-35  → BattleCoroutine.StartCoroutine(StartShowValue(damage))

// :47-65
protected override void SetupNumberAnimation(int value)
{
    base.SetupNumberAnimation(value);
    Transform t = _targetCardView.Transform;
    t.localPosition = new Vector3(t.localPosition.x, _targetCardView.OriginalRootYPosition, t.localPosition.z); // :51
    Vector3 dir = GetKnockbackDirection(_targetCardView);                       // :38-45 敌方=down, 我方=up
    Vector3 position = _targetCardView.Transform.position - dir * 0.1f;         // :53 位移 0.1
    float y = _targetCardView.Transform.parent.InverseTransformPoint(position).y;
    BattleCoroutine.GetInstance().StartCoroutine(KnockbackByDamage(_targetCardView, y, 0.15f)); // :55 时长 0.15s
    if (value >= 7) { Skill_special_win.ShakeScreen(value);                     // :56-58
                      EffectMgr.Start(CMN_CARD_DAMAGE_3, CardWrapObject.transform.position); }
    else            { EffectMgr.Start(CMN_CARD_DAMAGE_1, CardWrapObject.transform.position); } // :63
}
```

- 击退方向语义：`GetKnockbackDirection` 对敌方返回 `Vector3.down`、对我方返回 `Vector3.up`，然后 `position = 原位 - 方向*0.1`，即**向远离对手的一侧（屏幕外方向）推 0.1 单位**（`DamageVfx.cs:38-45,53`）。
- 击退用 Catmull-Rom 样条（`Interp`，`DamageVfx.cs:87-97`），控制点数组 5 个：`{targetY, origY, targetY, origY, targetY}`（`:72`），`moveTime = 0.15f`，每帧 `WaitForEndOfFrame`，曲线段数 = `pts.Length-3 = 2`。结果是 **0.15s 内一次「推出去再回来」**（含 Catmull-Rom 的惯性过冲）。结束后把 `localPosition.y` 复位为 `originalLocalY`（`:84`）。
- 红闪目标：`GetCardMeshGameObject()`（随从=场上的 Normal/Evolve mesh；主战者=`CardWrapObject/Class`），`BattleCardView.cs:566-581`。
- 构造顺序 = [红闪] → [UpdateHandCardsPlayability + 启协程播字]；`IsRecovery` 时红闪与飘字都跳过（`:18`、`:72`）。
- 卡面 Y 复位到 `OriginalRootYPosition`：随从 = `Global.CARD_BASE_POS.y = 0`（`BattleCardView.cs:226`、`Global.cs:406`），主战者 = `Global.CLASS_BATTLE_POSITION_PLAYER/ENEMY.y`（两者都是 `0`，`Global.cs:415-416`；`PlayerClassBattleCardView.cs:14`、`EnemyClassBattleCardView.cs:14`）。

---

## 4. `ReflectedDamageVfx`（反伤飘字）

```csharp
// ReflectedDamageVfx.cs（全文 15 行）
public class ReflectedDamageVfx : DamageVfx
{
    private readonly float DAMAGE_POSITION_OFFSET_Y = -0.25f;                       // :7
    protected override Vector3 StartPosition
        => base.StartPosition + DAMAGE_POSITION_OFFSET_Y * GetKnockbackDirection(_targetCardView);  // :9
    public ReflectedDamageVfx(IBattleCardView targetCardView, int damage)
        : base(targetCardView, damage) { }                                          // :11-14
}
```

- 效果：**唯一差异是飘字起点偏移 0.25**，方向与击退方向同轴：敌方（dir=down）→ 数字上移 0.25；我方（dir=up）→ 数字下移 0.25（即远离目标中心）。
- 其余全部继承 `DamageVfx`：红闪、0.1 击退/0.15s、≥7 震屏、`CMN_CARD_DAMAGE_1/3`。
- 注意：`StartPosition` 是虚属性，`DamageVfxBase.StartShowValue:126` 与 `:97-101` 都用它，所以偏移同时作用于初始位置与主战者 Y 钉位基准。

---

## 5. `HealingVfx`（治疗飘字）

```csharp
// HealingVfx.cs（全文 16 行）
public class HealingVfx : DamageVfxBase
{
    protected override string _effectName => "cmn_battle_heal_1";     // :5
    public HealingVfx(IBattleCardView targetCardView, int heal)
        : base(targetCardView) { Register(InstantVfx.Create(() =>
            BattleCoroutine.GetInstance().StartCoroutine(healingVfx.StartShowValue(heal)))); } // :11-14
}
```

- **直接继承 `DamageVfxBase`（不是 `DamageVfx`）**，因此：无红闪、无击退、无震屏、无 `CMN_CARD_DAMAGE_*`；只有飘字。
- 位数排布 / 字距 0.26 / `startFrame=digit/16` / `sortingOrder=DamageCount` / 2.5s 生命周期 / `DamageCount++` 与伤害飘字**完全相同**（同一份 `SetupNumberAnimation`）。
- 起点 = 卡位置，无偏移；主战者治疗同样吃 `+0.4 / -0.3` 的 Y 钉位（因为钉位在基类 `StartShowValue` 里按 `IsClass` 判断，治疗不例外）。
- 治疗量来源：`HealParam` → `HealLife()` 的**实际回复量**（`BattleCardBase.cs:2788-2793` 返回 `Life - life`），创建链见 §6(e)。

---

## 6. 触发链（谁在什么时候播数字）

### 6.1 创建入口（三处，都在 `CardVfxCreatorBase` 体系内）

```csharp
// CardVfxCreatorBase.cs
:219  public virtual VfxBase CreateDamage(int damage, int currentHealth, int maxHealth, int baseHealth,
                                          bool isReflectedDamage, bool isSkillDamage)
:221      return ParallelVfxPlayer.Create(CreateDamageVfx(damage, isReflectedDamage),
                                           new RefreshHealthVfx(_battleCardView, currentHealth, maxHealth, baseHealth));
:224  protected DamageVfx CreateDamageVfx(int damage, bool isReflectedDamage)
:226      if (!isReflectedDamage) return new DamageVfx(_battleCardView, damage);
:230      return new ReflectedDamageVfx(_battleCardView, damage);
:233  public virtual VfxBase CreateHealing(int healAmount, int currentHealth, int maxHealth, int baseHealth)
:235      return ParallelVfxPlayer.Create(new RefreshHealthVfx(...), new HealingVfx(_battleCardView, healAmount));
```

- 随从（单元卡）覆盖：`UnitCardVfxCreator.cs:17-22`
  ```csharp
  VfxBase vfxBase = base.CreateDamage(...);                     // :19
  WaitVfx waitVfx = WaitVfx.Create(isSkillDamage ? 0f : 0.5f);  // :20  ← 普攻伤害后等待 0.5s；技能伤害不等待
  return SequentialVfxPlayer.Create(vfxBase, waitVfx);          // :21
  ```
- 主战者（Class）覆盖：`ClassCardVfxCreatorBase.cs:46-51`
  ```csharp
  DamageVfx damageVfx = CreateDamageVfx(damage, isReflectedDamage);   // :48
  SetupDamageVfxEvent(damageVfx);                                     // :49 挂 OnStartAnimation → 语音/受击动作
  return SequentialVfxPlayer.Create(damageVfx,
      new RefreshHealthVfx(...), CreateCharacterPanelShake());        // :50（CreateCharacterPanelShake 基类返回 NullVfx，:58-61；
                                                                      //      Player/EnemyClassCardVfxCreator 均未覆盖 → 实际恒为空）
  ```
  主战者 `CreateHealing`：`ClassCardVfxCreatorBase.cs:53-56`（`Parallel(RefreshHealthVfx, HealingVfx)`）。

### 6.2 攻击伤害（普攻）链路

| 步 | 位置 | 说明 |
|---|---|---|
| 1 | `UnitBattleCard.cs:349-353` | `AttackOpponent()` → `target.ApplyDamage(null, damageParam, IsKiller, isReflectedDamage:false, ...)` |
| 2 | `UnitBattleCard.cs:399-422` | `ApplyDamage()`：`isSkillDamage = skill != null`（此处 skill=null → false）`:402` |
| 3 | `UnitBattleCard.cs:404-408` | 反伤判定，命中则递归到对方主战者并置 `isReflectedDamage:true` |
| 4 | `UnitBattleCard.cs:409` | `damageParam.Damage = CalculateFinalDamageAmount(damage, isSkillDamage, isSpellDamage)` |
| 5 | `BattleCardBase.cs:2776-2786` | 最终伤害：全免疫/技能盾/法术盾/攻击盾 → 0；否则减 `GetDamageCutAmount()`、`GetClippingDamage()`、`Mathf.Max(...,0)` |
| 6 | `UnitBattleCard.cs:418` | `VfxCreator.CreateDamage(实际伤害, Life, MaxLife, BaseMaxLife, isReflectedDamage, isSkillDamage)` |
| 7 | `UnitCardVfxCreator.cs:17-22` | `Parallel(DamageVfx, RefreshHealthVfx)` + 尾部 `WaitVfx(0.5)`（`isSkillDamage=false`） |
| 8 | `CardVfxCreatorBase.cs:224-231` | `new DamageVfx` / `new ReflectedDamageVfx` |
| 9 | `DamageVfx.cs:34` → `DamageVfxBase.cs:88,125,148` | 协程播字、`DamageCount++`、`sortingOrder` |

- 时序：攻击者特效 `AttackVfx`（`AttackVfx.cs:31-46,70-74`：黄色闪 `(1,1,0.25)` 瞬时 → 0.2s 回白 delay 0.1；Y 轴 `RotateBy 1.0` / 0.5s / delay 0.1 / easeOutExpo；打击特效 `attackTime` 默认 0.1s，`btl_common_attack_1`）→ 受击者 `DamageVfx`（红闪 + 飘字 + 击退）→ 0.5s 等待。
- 反击（受击方反打）：`NewReplayBattleMgr.cs:1971-1972`（先 `WaitVfx(0.4)`，再攻击动画，再对攻击者出伤害数字）。

### 6.3 技能伤害链路

| 步 | 位置 | 说明 |
|---|---|---|
| 1 | `Skill_damage.cs:200-217` | `TakeDamageSingle()` → `target.ApplyDamage(this, damageParam, ...)`，`skill != null` → `isSkillDamage = true` |
| 2 | `Skill_damage.cs:206-211` | 反伤目标判定（`GetDamageReflectionTarget(isSkillDamage:true)`） |
| 3 | `UnitBattleCard.cs:409-418` / `ClassBattleCardBase.cs:195-205` | 同上，`isSkillDamage=true` |
| 4 | `Skill_damage.cs:152-182` | `MakeSkillVfx()`：**所有目标的 `DamageResult.Vfx` 注册进同一个 `ParallelVfxPlayer`（`:163`）**，即多目标技能**同一帧一起出字** |
| 5 | `UnitCardVfxCreator.cs:20` | 技能伤害 `WaitVfx(0)`，所以技能段与后续段之间没有额外 0.5s |
| 6 | `SkillBase.cs:1201,1259,1283` / `SkillCreator.cs:47,72` | 技能特效时长 `buildInfo._effectTime` 来自卡牌 Master 数据（每张卡不同，**不在代码里**），决定多段技能之间隔多久出下一组数字 |
| 7 | `NewReplayBattleMgr.cs:2399-2408` | 重放/观战路径：`parallelVfxPlayer.Register(targetCards[i].VfxCreator.CreateDamage(damageList[i], ..., isReflectionDamage[i], IsSkillDamage:true))`（多目标并行） |

- 结论：**多段/多目标没有专门的「排队/错位」逻辑**。多目标 = 同一帧并行、各在各自卡位；同一目标的多段伤害是否重叠，取决于上层技能触发间隔（`_effectTime` 等），重叠时只靠 `sortingOrder` 分前后。
- 多目标分摊（`TakeUnfixedDamage`，`Skill_damage.cs:280-309`）注意把主战者挪到末尾，逐个目标扣血；`TakeFixedDamage`（`:260-278`）对所有目标同一数值。

### 6.4 主战者（Class / 领袖）伤害

| 步 | 位置 | 说明 |
|---|---|---|
| 1 | `ClassBattleCardBase.cs:184-217` | `ApplyDamage()`：反伤 → 递归 `isReflectedDamage:true`（`:190-193`） |
| 2 | `ClassBattleCardBase.cs:195` | `CalculateFinalDamageAmount(damage, isSkillDamage, isSpellDamage, parallelVfxPlayer)`（多传一个「生命下限特效」容器，`BattleCardBase.cs:2784`） |
| 3 | `ClassBattleCardBase.cs:203` | `SkillApplyInformation.DamageLife(...)` |
| 4 | `ClassBattleCardBase.cs:205` | `VfxCreator.CreateDamage(..., isReflectedDamage, isSkillDamage)` → `ClassCardVfxCreatorBase.cs:46-51` |
| 5 | `DamageVfxBase.cs:93-103` | 主战者飘字 Y 钉在 `卡Y+0.4`（我方）/`卡Y-0.3`（敌方） |
| 6 | `ClassCardVfxCreatorBase.cs:93-147` | `OnStartAnimation`：伤害 `>=7` 从 `DAMAGE_L_1/L_2` 随机 1 个语音；`<7` 从 `DAMAGE_S_1..3` 随机 1 个；动作 `MotionType.damage`（进化皮肤 `z_damage`）、表情 `FaceType.skin_02` |

- `SetupDamageVfxEvent` 只在主战者侧挂（`ClassCardVfxCreatorBase.cs:49,93-148`），随从不播语音/受击动作。

### 6.5 反伤（Reflection）

```csharp
// BattleCardBase.cs:3752-3759
public BattleCardBase GetDamageReflectionTarget(bool isSkillDamage)
{
    if (SkillApplyInformation.IsReflectionClass &&
        (isSkillDamage || SkillApplyInformation.ReflectionInfoList.Any(b => b.Type == ReflectionInfo.DamageType.ALL)))
        return OpponentBattlePlayer.Class;   // 反给对手主战者
    return this;
}
```

- 递归调用点：`UnitBattleCard.cs:405-407`、`ClassBattleCardBase.cs:190-192`、`Skill_damage.cs:206-217`、`ActionProcessor.cs:625-628`（AI/预演算，不播字）。
- 递归后 `isReflectedDamage = true` → `ReflectedDamageVfx`（§4）。`DamageResult.IsReflectedDamage` 会一路带回去（`BattleCardBase.cs:378-385`）。

### 6.6 治疗 / 吸血

| 步 | 位置 | 说明 |
|---|---|---|
| 1 | `BattleCardBase.cs:2788-2793` | `HealLife()` 返回实际回复量 `Life - life` |
| 2 | `UnitBattleCard.cs:424-435` | 随从：`VfxCreator.CreateHealing(num, ...)` → `Parallel(RefreshHealthVfx, HealingVfx)` |
| 3 | `ClassBattleCardBase.cs:219-235` | 主战者：同款 `CreateHealing`（`ClassCardVfxCreatorBase.cs:53-56`） |
| 4 | `HealParam`（`BattleCardBase.cs:391-409`） | 治疗量先过 `HealModifierList`（按 `OrderCount` 排序），所以飘的是**修正后**数值 |
| 5 | 吸血 `ApplyDrain`（`UnitBattleCard.cs:370-397`） | 回复主战者 → `HealingVfx` + `btl_magic_cure_1`（`se_btl_magic_cure_1`）特效 |
| 6 | 重放：`NewReplayBattleMgr.cs:1979`（吸血）、`:2445`（群体治疗） | 同样走 `CreateHealing` |

### 6.7 恢复/快进（IsRecovery）与重放

- `IsRecovery` 时：飘字不创建、`DamageCount` 不自增、事件照发（`DamageVfxBase.cs:72-77`）；红闪跳过（`DamageVfx.cs:18`）；`WaitVfx.Create` 一律变 0（`WaitVfx.cs:26-32`）；卡面数字缩放动画跳过（`RefreshCardParamScale.cs:45-50,55-58`）；`AttackVfx` 直接返回（`AttackVfx.cs:26-29`）。
- 重放对象登记：`NewReplayBattleMgr.StopEffectObjectList`（`DamageVfxBase.cs:84-87,109-112,169-172`）。

### 6.8 暴击 / 技能伤害的「区别」总结

代码里**没有暴击（crit）概念**，飘字相关的分支只有 3 个开关：

1. `isReflectedDamage`（是否反伤）→ 选 `ReflectedDamageVfx`（位置 −0.25）。
2. `isSkillDamage`（`skill != null`）→ 随从伤害后的 `WaitVfx` 从 0.5s 变 0s（`UnitCardVfxCreator.cs:20`）；主战者语音随机池不受此影响，只看数值 7（`ClassCardVfxCreatorBase.cs:102`）。
3. `value >= 7`（整数最终伤害）→ 震屏 + `CMN_CARD_DAMAGE_3`，否则 `CMN_CARD_DAMAGE_1`（`DamageVfx.cs:56-64`）。

另外「造成/受到伤害次数」用的是另一套字段，别和 `DamageCount` 混淆：`BattleCardBase.ItWasDamagedCounter`（`BattleCardBase.cs:145-181`，自增点 `:2602`，用于狂怒/复仇等条件），`SkillConditionWrath.cs:14,36-38`（`>=7` 即狂怒）。

---

## 7. `BattleManagerBase.DamageCount` = 「卡堆」语义确认

```csharp
// BattleManagerBase.cs:403
public int DamageCount;
```

| 项目 | 结果 | 出处 |
|---|---|---|
| 字段定义 | `public int DamageCount;`（public，非 static，属于本场 BattleManager） | `BattleManagerBase.cs:403` |
| 初值 | 未显式赋值 → `0`（C# 默认） | — |
| **唯一自增点** | `_battleMgr.DamageCount++;`（`SetupNumberAnimation` 开头，**伤害与治疗都走这里**） | `DamageVfxBase.cs:125` |
| **唯一使用点** | `component.sortingOrder = _battleMgr.DamageCount;`（每个数字粒子槽位） | `DamageVfxBase.cs:148` |
| 重置点 | **全工程无**（对 5636 个 .cs 做全文检索 `DamageCount`；其他匹配均为 AI 模拟 / 受伤次数等无关同名字段，见 `Wizard/AIRandomMultiDamageEvaluator.cs:24`、`Wizard/AIVirtualField.cs:121-125`、`BattleCardBase.cs:162-181`） | — |
| `IsRecovery` 时不增 | `StartShowValue` 提前 return，未进入 `SetupNumberAnimation` | `DamageVfxBase.cs:72-77` |

**「卡堆」＝渲染层级堆叠，不是位置堆叠：**

- 每出一个飘字（伤害或治疗）计数器 +1，并把该值作为该次数字所有位粒子的 `sortingOrder`。
- 因此：**后出的数字盖在先出的数字上面**；序号跨越整场战斗，第 1 个数字 order=1，第 2 个 order=2……
- **没有**同目标多段伤害的水平/垂直偏移、**没有**错帧排队、**没有**缓存池复用（每次都 `Instantiate` 一个新对象，`DamageVfxBase.cs:82`）。
- 同一目标同一帧多次伤害 ⇒ 两个数字**完全重合**，只靠 order 决定谁在上层（这也解释了原版里「多段伤害看起来是在同一个位置快速刷新」的观感）。
- 想要 1:1 复刻：Godot 里给每个飘字节点记一个自增 `z_index`（或 `CanvasItem.z_index` / draw order），全战斗单调递增、不重置；不要做位置偏移。

---

## 8. `RefreshHealthVfx` / `RefreshAttackVfx` / 属性变化（**卡面数字**，不是飘字）

> 这一组改的是卡上/主战者面板的 `UILabel`，不是浮空数字。任务里问的「治疗数字颜色/幅度、护甲/属性变化数字」的答案在这里。

### 8.1 缩放动画（数值变化的「弹一下」）

```csharp
// RefreshCardParamScale.cs
private const float SCALEUP_TIME  = 0.1f;    // :7
private const float SCALEDOWN_TIME = 0.1f;   // :9
private const float SCALE = 1.43f;           // :11
// :40-41
iTween.ScaleTo(label, Hash("scale", scaleDefault * 1.43f, "time", 0.1f, "islocal", true,
                           "easetype", iTween.EaseType.easeOutQuad));
iTween.ScaleTo(label, Hash("scale", scaleDefault, "time", 0.1f, "islocal", true,
                           "easetype", iTween.EaseType.easeInQuad, "delay", 0.1f));
```

- 触发条件（`IsNeedScale`，`:45-68`）：非 `IsRecovery`、label 非空、非重放移动、或 `isUpdateForce`、或文本真的变了。
- 幅度：**瞬时放大到 1.43 倍（0.1s easeOutQuad），再在延迟 0.1s 后用 0.1s easeInQuad 回到原尺寸**（总时长 0.3s）。`InitAnim()` 会 `iTween.Stop` + 复位（`:70-78`）。
- 缓存原尺寸：`LabelScaleCache.ScaleDefault`（`:39,76`）。

### 8.2 颜色表（`Global.cs` 静态字段，运行期在 `Global` 静态构造里赋值）

| 用途 | 值 | 出处 |
|---|---|---|
| `CARD_PASSIVE_COLOR` | `Color.red` | `Global.cs:135,370` |
| `CARD_DEFAULT_COLOR` | `Color.white` | `Global.cs:137,371` |
| `CARD_BLESS_EFFECT_COLOR` | `(0.7, 1, 0, 1)` | `Global.cs:141,373` |
| `CARD_POWERDOWN_EFFECT_COLOR` | `(1, 0.8, 0.4)` | `Global.cs:143,374` |
| `CARD_LABEL_FRAME_TEXT_COLOR` | `(1, 0.992, 0.922)` | `Global.cs:145,375` |
| `CARD_LABEL_FRAME_TEXT_RED_COLOR` | `(1, 0.7, 0.7)` | `Global.cs:147,376` |
| `CARD_LABEL_FRAME_ATTACK_COLOR` | `(0.2, 0.2, 0.4)` | `Global.cs:153,379` |
| `CARD_LABEL_FRAME_HEALTH_COLOR` | `(0.4, 0.2, 0.2)` | `Global.cs:155,380` |
| `CARD_LABEL_FRAME_LESS_THAN_MAX_COLOR` | `(0.9, 0.75, 0.7)` | `Global.cs:157,381` |
| `CARD_LABEL_FRAME_LESS_THAN_BASE_COLOR` | `(160/255, 130/255, 70/255)` | `Global.cs:159,382` |

**文字色规则**（`RefreshAttackVfx.GetParameterTextColor`，`RefreshAttackVfx.cs:42-57`；`RefreshHealthVfx.cs:31` **生命值也复用这个函数**）：

1. `current < max` → `CARD_PASSIVE_COLOR`（红）
2. 否则 `current > base` → `CARD_BLESS_EFFECT_COLOR`（黄绿）
3. 否则 `current < base` → `CARD_POWERDOWN_EFFECT_COLOR`（橙）
4. 否则 → `CARD_DEFAULT_COLOR`（白）

**外框色规则**（攻击 `RefreshAttackVfx.cs:59-70`；生命 `RefreshHealthVfx.cs:53-64`）：`current<max` → LESS_THAN_MAX；否则 `current<base` → LESS_THAN_BASE；否则 `ATTACK_COLOR` / `HEALTH_COLOR`。写入 `UILabel.effectColor`（`RefreshCardParamScaleColor.cs:37-42`）。

### 8.3 一次属性变化同时刷新 3 个 UI

- 生命：场上卡 `CardTemplate.LifeLabelTemp`、普通血条 `NormalLifeLabelTemp`、手牌参数 `HandParam._lifeLabel`（`RefreshHealthVfx.cs:30-33`）
- 攻击：`AtkLabelTemp`、`NormalAtkLabelTemp`、`HandParam._attackLabel`（`RefreshAttackVfx.cs:19-22`）
- 三个一起 `Exec()`（`RefreshHealthVfx.cs:36-43`、`RefreshAttackVfx.cs:25-32`），`IsEnd = true` 立即结束。

### 8.4 `ParameterChangeVfx`（属性变化编排）

```csharp
// ParameterChangeVfx.cs:5-18
if (!isDead) {
    parallel.Register(new RefreshHealthVfx(targetCardView, CurrentHealth, MaxHealth, BaseHealth));  // :10
    parallel.Register(new RefreshAttackVfx(targetCardView, CurrentAtk, BaseAtk));                    // :11
    Register(parallel);
    if (!(isEvolve | skipWait)) Register(WaitVfx.Create(0.3f));                                      // :13-16
}
```

- 数据来自 `BattleCardBase.ParameterChangeInformation`；入口 `CardVfxCreatorBase.cs:73-76`。
- 死亡时什么都不播（`isDead`）；进化或 `skipWait` 时省略 0.3s 等待。

### 8.5 Buff/Debuff 特效（无数字）

| 类 | 内容 | 出处 |
|---|---|---|
| `StartBuffVfx` | `EffectMgr.StartBuff(STT_LOOP_UP_1, CardWrapObject)`（循环上升 buff 特效） | `StartBuffVfx.cs:5-11` |
| `StopBuffVfx` | `StopBuff(STT_LOOP_UP_1, ...)` | `StopBuffVfx.cs:5-11` |
| `StartDebuffVfx` / `StopDebuffVfx` | `STT_LOOP_DOWN_1` | `StartDebuffVfx.cs:11`、`StopDebuffVfx.cs:9` |
| `StartBuffInHandVfx` | 手牌：先 `RefreshHealthVfx`+`RefreshAttackVfx`，再特效 `stt_act_costdown_1`（debuff 用 `stt_act_costup_1`），仅我方/管理员可见 | `StartBuffInHandVfx.cs:15-28` |
| 编排 | `CreateChangeBuffStatusVfx` 在 buff 特效后追加 `WaitVfx(0.2f)`（`useWait` 默认 true） | `CardVfxCreatorBase.cs:103-111` |

- 本环境**没有**「护甲/属性变化飘数字」的实现：护盾、攻击/生命修正都只改 label + 播特效，唯一浮空数字是伤害与治疗。
- EP/血条等其他数字动画见 `UpdateEpVfx.cs`、`BattlePlayerVfxCreatorBase.cs:25,37`（不在本次范围）。

---

## 9. 震屏与背景震动数值

```csharp
// Skill_special_win.cs:8-14, 67-74
private const int   SHAKE_SCREEN_MAX_VALUE        = 10;
private const float SHAKE_CAMERA_VECTOR_VALUE     = 0.02f;
private const float SHAKE_CAMERA_TIME_COEFFICIENT = 0.05f;
private const float SHAKE_CAMERA_TIME_OFFSET      = 0.2f;

public static void ShakeScreen(int shakeScreenMinValue = 10)
{
    BattleManagerBase ins = BattleManagerBase.GetIns();
    float num = Mathf.Min(10, shakeScreenMinValue);                       // 上限 10
    BattleCamera camera = ins.Camera;
    ins.VfxMgr.RegisterImmediateVfx(SequentialVfxPlayer.Create(
        camera.ShakeCamera(Vector3.one * (num * 0.02f), num * 0.05f + 0.2f, 0f),  // 幅度 / 时长 / 延迟
        WaitVfx.Create(num * 0.05f + 0.2f),
        camera.ShakeComplete()));
    ins.BackGround.StartFieldShake();                                     // 背景/场地抖动（虚方法）
}
```

| 参数 | 公式 | 默认（`shakeScreenMinValue=10`） |
|---|---|---|
| 相机抖动幅度 | `min(10, v) * 0.02`（`Vector3.one *` 三轴同幅） | `0.2` |
| 相机抖动时长 | `min(10, v) * 0.05 + 0.2` | `0.7s` |
| 延迟 | `0` | `0` |
| 结束后复位 | `camera.ShakeComplete()`：恢复 `BattleCameraPos` / `BattleCameraRot` 并 `iTween.Stop(Camera)` | `BattleCamera.cs:50-58` |

- 实际抖动用 `iTween.ShakePosition(Camera.gameObject, amount, time, delay)`（**世界空间**，未传 `islocal`）（`BattleCamera.cs:30-38`）。
- **飘字触发的震屏**：`DamageVfx.cs:58`，条件 `value >= 7`（`value` 是已修正的最终伤害整数，内部再 clamp 到 10，所以伤害 ≥10 与 10 表现相同）。
- 其他调用点：`Skill_special_win.cs:59`（特殊胜利，默认 10）、`Skill_special_lose.cs:46`、`DeckOutWinVfx.cs:59`、`NewReplayBattleMgr.cs:3818`。
- 背景抖动：`BackGroundBase.StartFieldShake()` → 协程 `RunFieldShake()`，基类是空实现（`BackGroundBase.cs:224-232`），具体晃动幅度在各 Field 子类里；同类还有 `DestroyClassVfx.cs:114` 也会调 `StartFieldShake()`。
- 另有一个独立的「召唤卡震屏」`SummonCardShakeCameraVfx`（`SummonCardShakeCameraVfx.cs:5-7`），与伤害飘字无关。
- 单位卡受击**没有**单独的 screen shake 之外的位移：那 0.1 单位是卡自身击退（§3）。

---

## 10. 资源命名与「代码看不到」的边界

### 10.1 代码里确定的资源路径规则

| 资源类型 | 路径模板 | 出处 |
|---|---|---|
| 特效预制体（Effect2D） | `Effect/Effects/<name>` | `Cute/ResourcesManager.cs:314-316` |
| 特效材质（Effect2DMaterials） | `Effect/Images/Materials/<renderer GameObject 名>` | `Cute/ResourcesManager.cs:317-319` |
| 3D 特效 | `Effect/FBX/<name>` | `Cute/ResourcesManager.cs:320-321` |
| 特效容器 | `Prefab/Container/_EffectContainer` | `EffectMgr.cs:390-391` |
| 战斗特效容器 | `Prefab/Container/_BattleEffectContainer` | `EffectMgr.cs:1181-1183` |

- 飘字预制体名：`cmn_battle_damage_1`（`DamageVfx.cs:12`）、`cmn_battle_heal_1`（`HealingVfx.cs:5`）→ 实际路径 `Effect/Effects/cmn_battle_damage_1`、`Effect/Effects/cmn_battle_heal_1`。
- 数字槽位识别：子渲染器名字含 `ef_` / `sp_` / `img_` 的才会被挂材质与 shader（`EffectMgr.cs:571,684,703`；`AttachMaterialAndShader` 在 `:806-835`）。
- 材质载入后会 `Shader.Find(material.shader.name)` 重新绑定（`EffectMgr.cs:812,818,828,833`）——这是为了打包时 shader 不被裁掉，说明**粒子用的 shader 名藏在材质里**（【资源】）。

### 10.2 你提到的 `cmn_card_damage_1 / cmn_card_damage_3`

- 它们**不是**飘字预制体，而是**受击打击特效**：`DamageVfx.cs:56-64` 通过 `EffectMgr.Start(EffectMgr.EffectType.CMN_CARD_DAMAGE_3 / CMN_CARD_DAMAGE_1, 目标 CardWrapObject 世界坐标)` 播放。
- 枚举定义：`EffectMgr.cs:37-38`（`CMN_CARD_DAMAGE_1`、`CMN_CARD_DAMAGE_3`；注意没有 `_2`）。
- 枚举名 → 预制体路径/缩放/数量/音效的映射**不在代码里**，而在 JSON 配置：战斗特效组由 `SBattleLoad.cs:638` 的 `InitCommonEffect("Json/EffectBattleData", isBattle: true, isField: false, isBattleEffect: true)` 加载，逐条读 `TYPE / PATH / SEPATH / NUM / SCALE_FOLLOW`（`EffectMgr.cs:428-546`，尤其 `:463-473`）。`NUM` = 池化实例数（`Start` 只在找到 `!IsOn()` 的实例时返回，否则返回 null，`EffectMgr.cs:974-1002`）。
- 因此 `cmn_card_damage_1/3` 的**真实 prefab 名、池化数量、音效 cue 名都在 `Json/EffectBattleData` 里** →【资源】。

### 10.3 数字贴图 / 图集

【码】能确定的只有「16 帧的 TextureSheet 数字图集，帧序 = 0..9，用 `startFrame = digit/16f`」（`DamageVfxBase.cs:17,140-145`）。

【资源】看不到的：图集纹理本身、每帧像素尺寸、帧排列方向（应为水平 16 列）、Render Mode（Billboard/Stretched）、材质 shader、Blend 模式、粒子生命周期/速度/大小/颜色曲线、发射器形状、`maxParticles`、`simulationSpace`、`startSize`、`gravityModifier`、`Color over Lifetime`（上浮 + 淡出完全靠这些）。

### 10.4 可用 `D:\逆向工程\tools\extract.py` 的思路

- 现有脚本只做两件事（`tools/extract.py:55-91,95-117`）：
  1. `AssetStudioModCLI.exe <stage> -o <out> -t texture2d -m export --image-format png --unity-version 2020.3.18f1`（`:75-83`）→ 只能导出**贴图**，因此 `cmn_battle_damage_1` 的数字图集**可以**拿到（在游戏的 `a/*.unity3d` bundle 里）；
  2. `vgmstream-cli.exe` 解 `.acb/.awb` 音频（`:99`）。
- 游戏资源根目录硬编码为 `D:\shawdobus\Shadowverse\Shadowverse`，目标 bundle 在 `a/`（`:32,140-149`）。
- 要拿到 **prefab / 材质 / JSON**，需要把 `-t` 换成其它类型（例如 `all` / `gameobject` / `material` / `textasset`）或直接 dump `Json/EffectBattleData`，并对 `Effect/Effects/cmn_battle_damage_1`、`cmn_battle_heal_1`、`cmn_card_damage_1/3` 所在 bundle 单独跑一次——**这一步本会话无法执行**（沙箱里 pwsh 不可用，且我没有写权限去改脚本；只读研究员角色）。

---

## 11. 复刻参数表（可直接照着在 Godot `Control._draw()` 里实现）

### 11.1 时间 / 节奏

| # | 参数 | 值 | 说明 / 出处 | Godot 实现 |
|---|---|---|---|---|
| T1 | 飘字存活 | `2.5 s` | `DamageVfxBase.cs:11,90` | 计时器到 2.5s 后 `queue_free()`；与位移动画解耦 |
| T2 | 出生时机 | 伤害 vfx 步执行的那一帧（`DamageVfxBase.cs:88`） | 普攻=攻击特效后；多目标技能=同一帧 | 在伤害结算处立即 `add_child` |
| T3 | 普攻伤害后的额外等待 | `0.5 s` | `UnitCardVfxCreator.cs:20`（`isSkillDamage=false`） | 用 Timer 卡下一段演出，不影响飘字自身 |
| T4 | 技能伤害后的额外等待 | `0 s` | `UnitCardVfxCreator.cs:20` | 同上 |
| T5 | 受击红闪 | 立刻 `Color.red`，`0.2 s` 回到白，`delay 0.1 s` | `DamageVfx.cs:23-24` | `ColorRect`/材质 modulate Tween：红 → (delay 0.1) → 白 0.2s |
| T6 | 卡击退 | `0.1` 单位位移，`0.15 s`，一次「推出去—回来」（Catmull-Rom 5 点） | `DamageVfx.cs:10,53,55,72` | 用 `Curve`（t=0 原位 → 0.5 位移极值 → 1 原位），方向 = 玩家卡向下 / 敌方卡向上 |
| T7 | 攻击者黄闪 | `Color(1,1,0.25)` 瞬时，`0.2 s` 回白，`delay 0.1` | `AttackVfx.cs:81-82` | 可选 |
| T8 | 攻击者旋转 | Y 轴 `RotateBy 1.0`（一圈），`0.5 s`，`delay 0.1`，easeOutExpo | `AttackVfx.cs:45` | 可选 |
| T9 | 卡面数字缩放 | `1.43×`（0.1s easeOutQuad）→ `delay 0.1 s` → 回原尺寸（0.1s easeInQuad） | `RefreshCardParamScale.cs:7-11,40-41` | Tween scale，总 0.3s |
| T10 | 属性刷新后的等待 | `0.3 s`（`ParameterChangeVfx`，死亡/进化/`skipWait` 时省略） | `ParameterChangeVfx.cs:13-16` | Timer |
| T11 | buff/debuff 特效后等待 | `0.2 s` | `CardVfxCreatorBase.cs:103-111` | Timer |

### 11.2 位置 / 排布

| # | 参数 | 值 | 出处 | Godot 实现 |
|---|---|---|---|---|
| P1 | 锚点 | `CardWrapObject.transform.position`（卡的包裹对象世界坐标） | `DamageVfxBase.cs:33-43` | 取卡节点中心 |
| P2 | 位数 | `0→1`，否则 `floor(log10(|v|))+1` | `MotionUtils.cs:293-300` | `str(abs(v)).length()`（注意 `0` 也是 1 位） |
| P3 | 显示值 | `min(abs(value), 9999)`（伤害/治疗都用 abs） | `DamageVfxBase.cs:128` | `clampi(abs(v),0,9999)` |
| P4 | 数字字距 | `0.26`（单位 = 容器局部空间，≈ 屏幕像素需乘容器缩放） | `DamageVfxBase.cs:13` | 单字宽 `0.26 * S`，`S` = 你的像素换算系数 |
| P5 | 第 j 位 x 偏移 | `x = j*(-0.26) + digit*0.13 - 0.13`，等价 `0.13*(digit-1-2j)` | `DamageVfxBase.cs:146` | `j=0` 为个位(最右)，高位向左；整体居中于锚点 |
| P6 | 主战者 Y | 我方 `卡Y + 0.4`；敌方 `卡Y - 0.3`；**每帧强制**（覆盖上浮动画） | `DamageVfxBase.cs:19,21,97-101` | 每帧 `position.y = card.y ± offset`；注意这会让 prefab 上浮在纵向失效 |
| P7 | 随从 Y | 不钉位，交给上浮动效 | `DamageVfxBase.cs:93` | 自由做上浮 |
| P8 | 反伤偏移 | 沿击退方向 `-0.25`（敌方数字上移、我方数字下移） | `ReflectedDamageVfx.cs:7-9` | `pos += dir * -0.25`，`dir` 同 P9 |
| P9 | 击退方向 | 我方卡 = 上（飘字下移），敌方卡 = 下（飘字上移）；实际位移 `position - dir*0.1` | `DamageVfx.cs:38-45,53` | 玩家卡向下推、敌方卡向上推 |
| P10 | 层级 | `sortingOrder = DamageCount`（全战斗自增，伤害+治疗共用） | `DamageVfxBase.cs:125,148` | `z_index = ++damage_count`（不重置） |
| P11 | 堆叠规则 | **无位置偏移/无排队**；同帧多次伤害完全重合，仅靠层级分前后 | §7 | 不要加 offset；只 `z_index++` |
| P12 | 丢弃规则 | 多余数字位槽位 `SetActive(false)`（子槽位少于位数 → 高位不显示） | `DamageVfxBase.cs:130-133,153` | 预建 N 个数字槽（N ≥ prefab 槽数） |

### 11.3 颜色 / 特效 / 震屏

| # | 参数 | 值 | 出处 |
|---|---|---|---|
| C1 | 伤害数字 | 颜色/造型来自 prefab 材质（【资源】）；代码不改任何颜色 | `DamageVfxBase.cs:141-147` |
| C2 | 治疗数字 | 同上，`cmn_battle_heal_1`（【资源】） | `HealingVfx.cs:5` |
| C3 | 数字选帧 | `startFrame = digit / 16`（16 帧图集，仅用前 10 帧） | `DamageVfxBase.cs:17,142,145` |
| C4 | 打击特效 | 伤害 `>=7` → `CMN_CARD_DAMAGE_3`；否则 `CMN_CARD_DAMAGE_1`；播在目标卡位置 | `DamageVfx.cs:56-64`、`EffectMgr.cs:37-38` |
| C5 | 震屏门槛 | 伤害 `>= 7`（治疗/普通属性变化不震） | `DamageVfx.cs:56` |
| C6 | 震屏幅度 | `min(10, v) * 0.02`，三轴同幅 | `Skill_special_win.cs:10,70,72` |
| C7 | 震屏时长 | `min(10, v) * 0.05 + 0.2` | `Skill_special_win.cs:12,72` |
| C8 | 震屏延迟 | `0`；结束后复位相机 localPosition/euler 并 set 到原值 | `Skill_special_win.cs:72`、`BattleCamera.cs:50-58` |
| C9 | 背景抖动 | `StartFieldShake()`（基类空实现，各场地子类自定） | `Skill_special_win.cs:73`、`BackGroundBase.cs:224-232` |
| C10 | 伤害数字触发语音 | 主战者：`>=7` 从 2 个 L 语音随机；`<7` 从 3 个 S 语音随机 | `ClassCardVfxCreatorBase.cs:102-136` |
| C11 | 卡面文字色 | `current<max`→红 `(1,0,0)`；`>base`→`(0.7,1,0)`；`<base`→`(1,0.8,0.4)`；否则白 | `RefreshAttackVfx.cs:42-57`、`Global.cs:370-374` |
| C12 | 卡面外框色 | `<max`→`(0.9,0.75,0.7)`；`<base`→`(0.627,0.510,0.275)`；否则攻击 `(0.2,0.2,0.4)` / 生命 `(0.4,0.2,0.2)` | `RefreshAttackVfx.cs:59-70`、`RefreshHealthVfx.cs:53-64`、`Global.cs:379-382` |
| C13 | 抑制规则 | `IsRecovery`（断线恢复/快进）：不播飘字、不增计数、无红闪、所有 `WaitVfx` 归零 | `DamageVfxBase.cs:72-77`、`DamageVfx.cs:18`、`WaitVfx.cs:26-32` |

### 11.4 Godot 伪代码骨架

```gdscript
# 伤害飘字：一次伤害 -> 一个 FloatNumber 节点
const LIFETIME := 2.5
const PITCH := 0.26          # 字距（单位空间）
const MAX_VALUE := 9999
const STRONG := 7

var damage_count := 0        # 全场自增，永不重置，等价 BattleManagerBase.DamageCount

func spawn_number(value:int, anchor:Vector2, is_class:bool, is_player:bool, is_reflected:bool):
    damage_count += 1
    var v := mini(absi(value), MAX_VALUE)
    var digit := 1 if v == 0 else int(floor(log(float(v))/log(10.0))) + 1   # GetDigit
    var dir := 1.0 if is_player else -1.0   # 玩家卡(+y向下 in Godot) / 敌方卡
    var pos := anchor
    if is_class:
        pos.y = anchor.y + (0.4 if is_player else -0.3) * SCALE_Y   # 每帧钉位
    if is_reflected:
        pos += Vector2(0, -0.25 * dir * SCALE_Y)   # 沿击退方向 -0.25
    var node := FloatNumber.new()
    node.setup(v, digit, damage_count)   # 内部：第 j 位 x = 0.13*(digit-1-2*j)*SCALE_X
    add_child(node)                       # z_index = damage_count
    node.position = pos
    await get_tree().create_timer(LIFETIME).timeout
    node.queue_free()
```

数字位绘制（`_draw()` 内 / 或 N 个 Sprite 各取图集帧）：

```gdscript
# 图集 16 帧，帧宽 = atlas_w / 16
for j in digit:
    var d := int(floor(v / pow(10, j))) % 10          # DamageVfxBase.cs:140
    var frame_rect := Rect2(d * frame_w, 0, frame_w, atlas_h)   # startFrame = d/16
    var x := j * -PITCH + digit * PITCH * 0.5 - 0.13  # DamageVfxBase.cs:146
    draw_texture_rect_region(atlas, Rect2(origin + Vector2(x*S, 0), size), frame_rect)
```

---

## 12. 明确「代码确定」vs「只有 prefab/贴图/JSON 才有」的部分

### 12.1 【码】代码里 100% 确定（可直接复刻）

- 数值：2.5s 生命周期、0.26 字距、9999 上限、16 帧图集、±0.4/0.3 主战者 Y、反伤 −0.25、击退 0.1/0.15s、红闪 0.2s/delay 0.1、`>=7` 门槛、震屏 `0.02`/`0.05`/`0.2`/clamp 10、卡面缩放 1.43×/0.1s/0.1s + delay 0.1。
- 逻辑：位数计算、位排布公式、`startFrame = digit/16`、`DamageCount++` 与 `sortingOrder`、`DamageCount` 永不重置、无位置堆叠、`IsRecovery` 抑制、触发链与全部调用点/行号。

### 12.2 【资源】只有 prefab / 贴图 / JSON 才有（本环境无法读取）

1. `cmn_battle_damage_1` / `cmn_battle_heal_1` 的**子节点数量**（决定最多显示几位数；代码把「位数 > 槽位数」的多余位直接跳过 → 高位不显示，`DamageVfxBase.cs:130-136`）。
2. 每个数字槽的**粒子参数**：`startLifetime`、`startSpeed`（上浮速度）、`startSize`、`gravityModifier`、`Color over Lifetime`（淡出曲线）、`Size over Lifetime`、`Emission`（是否 `burst` 一次性发射）、`maxParticles`、`simulationSpace`、`Render Mode`、`sortingLayerName`。
3. **数字图集纹理**：帧数排布（推断水平 16 列）、单帧像素尺寸、字体风格、是否有描边/阴影、UV 方向。可用 `extract.py ... assets --name-filter` 思路 + `-t texture2d` 导出（见 §10.4）。
4. **材质/shader 名**：`Effect/Images/Materials/<子物体名>`（`ResourcesManager.cs:317-319`），以及它引用的 Shader（代码只做 `Shader.Find(同名)` 重新绑定，`EffectMgr.cs:812`）。
5. `CMN_CARD_DAMAGE_1` / `CMN_CARD_DAMAGE_3` 的 **真实 prefab 名 / 池化数量 NUM / 音效 SEPATH / SCALE_FOLLOW**：在 `Json/EffectBattleData`（`SBattleLoad.cs:638`、`EffectMgr.cs:463-473`）。
6. 技能特效时长 `_effectTime`（决定多段技能出字的间隔）：来自卡牌 Master（`SkillCreator.cs:47,72`），代码里没有常量。
7. 特效容器的**缩放/相机归属**：飘字的 `0.26 / 0.4 / 0.3 / 0.25` 都是容器局部空间单位，换算到屏幕像素需要 `Prefab/Container/_EffectContainer` 的 transform 与 `UICamera` 参数（【资源】）。

### 12.3 我不确定 / 需要实机验证的点

1. `_EffectContainer` 的 scale，使得「0.26 字距 = 多少像素」无法从代码推出；若美术资源缺失需要按屏幕自适应（建议：以卡宽为基准，字宽 ≈ 卡宽 × 1/4.5 之类的经验值，需对照实机截图校准）。
2. 主战者飘字「每帧钉 Y」是否会让 prefab 的纵向粒子速度看起来被冻结——从代码看是根节点 Y 被钉住，但**粒子相对根节点的本地位移不受影响**，所以视觉上仍会上浮；具体观感需实机确认（代码只能证明根节点 Y 恒定）。
3. `Time.time < startTime + 2.5f` 用的是**非缩放时间**（`Time.time`），暂停/慢放时飘字寿命会跟真实时间走；Godot 复刻时注意 `process_mode` 与 `Engine.time_scale` 的对应关系。
4. `sortingOrder` 只设 order 不设 layer，且容器是 UI 特效容器；在 Godot 里用 `CanvasItem.z_index` 模拟时，若飘字与卡分属不同 `CanvasLayer`，需要把飘字放到与卡同层或更高的层（原版是同一个 UI 容器 + order 覆盖）。
5. `DamageVfxBase.cs:90` 用字面量 `2.5f` 而非常量 `DAMAGE_ANIMATION_LENGTH`，若原版曾改过该常量，二者可能不一致（当前值一致）。
6. 反伤飘字的偏移方向是按击退方向计算的，因此「敌方反伤数字上移 / 我方下移」是我按代码推导，实际观感需确认。
7. `ClassCardVfxCreatorBase.CreateCharacterPanelShake()` 恒返回 `NullVfx`，所以主战者受击没有额外的面板抖动——若实机见到面板抖动，来源可能是 prefab/场地，代码里没有。

---

## 附：本文所有引用位置一览（相对 `D:\逆向工程\decompiled\Assembly-CSharp\`）

- `Wizard/Battle/View/Vfx/DamageVfxBase.cs`（全文 175 行）
- `Wizard/Battle/View/Vfx/DamageVfx.cs`（98 行）
- `Wizard/Battle/View/Vfx/ReflectedDamageVfx.cs`（15 行）
- `Wizard/Battle/View/Vfx/HealingVfx.cs`（16 行）
- `Wizard/Battle/View/Vfx/RefreshHealthVfx.cs`（65 行）、`RefreshAttackVfx.cs`（71）、`RefreshCardParamBase.cs`（30）、`RefreshCardParamScale.cs`（79）、`RefreshCardParamScaleColor.cs`（43）
- `Wizard/Battle/View/Vfx/ParameterChangeVfx.cs`（19）、`StartBuffVfx.cs`（12）、`StopBuffVfx.cs`（12）、`StartBuffInHandVfx.cs`（29）
- `Wizard/Battle/View/Vfx/CardVfxCreatorBase.cs:219-236,73-111`、`ClassCardVfxCreatorBase.cs:46-61,93-148`、`UnitCardVfxCreator.cs:17-22`、`PlayerClassCardVfxCreator.cs`、`EnemyClassCardVfxCreator.cs`
- `Wizard/Battle/View/Vfx/VfxBase.cs`、`SequentialVfxPlayer.cs`、`ParallelVfxPlayer.cs`、`WaitVfx.cs`、`InstantVfx.cs`、`VfxWithLoadingSequential.cs`
- `BattleManagerBase.cs:403`、`BattleCardBase.cs:145-181,346-389,2600-2635,2776-2793,3752-3759`、`UnitBattleCard.cs:349-435`、`ClassBattleCardBase.cs:184-235`
- `Skill_damage.cs:150-182,200-237,260-309,425-464`、`Skill_special_win.cs:8-14,67-74`、`NewReplayBattleMgr.cs:1940-1990,2399-2436,2438-2445`
- `AttackVfx.cs`、`BattleCamera.cs:30-58`、`BackGroundBase.cs:224-232`、`MotionUtils.cs:293-300`
- `EffectMgr.cs:37-38,356,390-391,428-546,549-625,662-770,806-835,974-1002,1181-1183`、`Cute/ResourcesManager.cs:314-321`、`Global.cs:135-159,370-382,406,415-416`、`Wizard/Battle/View/BattleCardView.cs:188-200,226,566-581`
- 资源工具：`D:\逆向工程\tools\extract.py:30-37,55-91,95-117,140-155`
