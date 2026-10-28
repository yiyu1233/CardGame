示例扩展包 —— 卡牌语音目录
================================

把某个事件的语音按「卡 id + 事件名」命名放进这里即可（**免导入、拷进来就播**）：

    mods/example/card_voice/mod_pursuer/play_01.wav
    mods/example/card_voice/mod_pursuer/attack_01.wav
    mods/example/card_voice/mod_pursuer/attack_02.wav     ← 同一事件多个文件会随机挑一个
    mods/example/card_voice/mod_ritual/death.wav

规则（实现见 scripts/CardVoice.gd）：
  * 目录名 = 卡牌 id；文件名 = `<事件>.wav` 或 `<事件>_<任意后缀>.wav`；
  * 事件名：play / summon / attack / death / skill / damage / turn / win / lose；
  * 没有配语音的卡会自动回落到通用音效（SoundFx），不会报错也不会静音整局。

也可以改用「显式映射」：在 mod.json 里写 "voice_map": "voice_map.json"，
内容形如 { "mod_pursuer": { "play": "res://.../a.wav", "attack": "res://.../b.wav" } }。

本目录故意留空（不放占位 wav）：没有文件时这条卡就走通用音效。
要试听效果，把任意 .wav 按上面的命名丢进来即可。
