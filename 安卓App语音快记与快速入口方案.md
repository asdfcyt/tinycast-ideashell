# 闪念贝壳 · 安卓 App「语音快记 + 更快入口」开发方案

> 本文是调研 + 方案，**尚未开始写代码**。目标：在荣耀 Magic8 Pro（MagicOS）上，做到「一个动作开始录音，说完自动保存到闪念贝壳」，并把现有各个入口再提速。
> 调研时间：2026-10-12。带「待真机验证」的条目无法只靠文档确认。

---

## 一、结论先行

1. **荣耀系统没有给第三方应用开放「一键录音」的接口。** 灵动胶囊里的「录音胶囊」只属于系统录音机；任意门、YOYO 对接都要企业开发者资质和上架审核。**不把荣耀私有能力当作核心依赖**，只用标准安卓接口加荣耀的保活引导。
2. **自己录音完全可行，而且比借系统录音机更快。** 做法是复用现有的透明轻量面板：触发后立刻开始录音，说完静音自动停止，自动保存。
3. **闪念贝壳 MCP 的 `note_create` 本来就支持 `audios` 附件**（扩展里已在用）。但服务端**不会自动转写**。所以方案是：**本机离线转写成文字，当作笔记正文，音频作为附件一起存**。这样你说「明天下午三点开会」，会走现有的万能输入解析，直接变成待办。
4. **转写用端侧 SenseVoice（sherpa-onnx）。** 这是参考 `shengwuji` 的核心做法，中文效果好、速度快。模型约 240MB，**不打进 APK**，首次使用时下载。
5. **更快的入口：**
   - 现有入口加一个麦克风按钮。
   - 通知栏、小部件加「🎙」。
   - 新增「语音快记」磁贴和桌面快捷方式。
   - 接收系统「录音机」分享出来的音频。
   - 可选的音量键 / 耳机键手势（无障碍服务）。
   - 可选的系统「默认笔记应用」角色（锁屏直达）。
6. **建议分三期。** 第一期不依赖转写，两三天就能用上：录音并存为音频笔记。

---

## 二、调研

### 2.1 荣耀系统接口：能不能直接用？

| 能力 | 荣耀提供什么 | 第三方能用吗 | 对本项目的价值 |
| --- | --- | --- | --- |
| **Voice Kit（智慧语音）** | 场景化语音指令、**端侧 ASR**、端侧 NLP、**离线 ASR / TTS** 工具；Maven 坐标 `com.hihonor.mcs:intelligence-voice` | 能，但要先注册荣耀开发者、创建应用、申请权限（官方文档的口径是企业开发者认证） | 理论上能替代自带模型，省下 240MB；**能不能放行个人开发者待确认**，且是否支持长录音转写、离线中文效果没有公开数据。做成**可选适配器**，不做第一选择 |
| **Audio Kit（音频服务）** | 多路录音（系统音 + 环境音）、AI 降噪、低时延耳返 | 同样需要申请权限 | 用不上；标准 `AudioRecord` 够用 |
| **灵动胶囊 · 录音胶囊** | MagicOS 10 起，灵动胶囊支持「轻触开录」 | 公开资料里**没有**第三方接入 API，只覆盖系统录音机 | 无法接入 |
| **任意门 / 快捷服务** | 快捷服务通过 deeplink 跳转到应用指定页面 | 要在智慧服务平台配置并上架 | 应用侧 deeplink 早已接好，见《安卓App开发方案》；新增 `ideashell://record` 即可复用 |
| **YOYO 智能体（A2A）** | YOYO 识别意图后 `POST` 到你配置的 Fulfillment URL，OAuth2 / AK-SK 认证，可返回卡片和 deeplink | 需要企业资质和**公网服务端** | 本项目没有后端，密钥只在用户手机上，**不建议做** |

资料来源：

- [荣耀智慧语音 Voice Kit](https://developer.honor.com/cn/tg/page/tg2022110110100001)
- [Voice Kit SDK 下载](https://developer.honor.com/cn/docs/11018/sdk/android)
- [荣耀音频服务 Audio Kit](https://developer.honor.com/cn/tg/page/tg2022110110100007)
- [MagicOS 10 灵动胶囊场景（IT之家）](https://www.ithome.com/0/901/185.htm)
- [荣耀 A2A 智能体接入](https://developer.honor.com/cn/doc/guides/101708)
- [快捷服务接入指南](https://developer.honor.com/doc/guides/100157)

**结论：** 荣耀侧只做两件事：①保活引导（设置页已有）；②把系统「快捷启动 / 键位映射」指到我们的「应用快捷方式」或 deeplink（`shengwuji` 的文档也是这么处理厂商侧键的）。

### 2.2 标准安卓能做到什么

| 入口 | 机制 | 能直接录音吗 | 限制 / 备注 |
| --- | --- | --- | --- |
| 快速设置磁贴 | `TileService.onClick` → `startActivityAndCollapse` | 能，打开透明面板后立即开录 | 现有磁贴已是这条路径，新增一个独立磁贴即可 |
| 桌面快捷方式 / 小部件 / 通知按钮 | `PendingIntent` 打开面板 Activity | 能 | 用户点击属于允许后台启动 Activity 的场景 |
| **音量键手势** | 无障碍服务 `onKeyEvent`（`canRequestFilterKeyEvents=true` + `FLAG_REQUEST_FILTER_KEY_EVENTS`），返回 `true` 即消费按键 | 服务本身不直接录音，它拉起面板 Activity | 要用户在系统里手动开启无障碍；荣耀可能杀掉服务；电源键等系统保留键拿不到 |
| 耳机线控 / 蓝牙耳机键 | 同一个无障碍服务收 `KEYCODE_HEADSETHOOK` / `MEDIA_PLAY_PAUSE` | 同上 | `shengwuji` 仅在「录音中」才拦截，平时放行 |
| **默认笔记应用角色** | `RoleManager.ROLE_NOTES`；Activity 声明 `ACTION_CREATE_NOTE`、`showWhenLocked`、`turnScreenOn` | 能，锁屏上也能直达 | **是否可用取决于厂商开关 `config_enableDefaultNotes`**（AOSP 默认关）；先 `isRoleAvailable()` 探测，Magic8 Pro 待真机验证 |
| 数字助理角色 | `ROLE_ASSISTANT` / `ACTION_ASSIST` | 能 | 荣耀电源键长按通常给 YOYO，能否改绑待验证；风险高，不做 |
| 系统录音机分享 | 注册 `SEND` `audio/*` | 不录音，**导入已有录音** | 荣耀录音机录完可以直接分享给「闪念」，成本最低 |
| 系统语音输入 | `RecognizerIntent` / `SpeechRecognizer` | 只出文字，不留音频 | 国产机不一定有可用识别服务；离线中文包可用性待验证；基准里离线英文 RTF 约 0.12，慢于 sherpa |

#### 两条硬约束（决定了架构）

1. **麦克风前台服务不能从后台启动。** Android 14 起必须声明 `foregroundServiceType="microphone"` 和权限 `FOREGROUND_SERVICE_MICROPHONE`，且 `RECORD_AUDIO` 是「使用中才有」的权限，**必须在应用有可见 Activity 时启动**。参见 [前台服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types) 与 [后台启动限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)。
   → **所有入口一律「先拉起透明面板 Activity，在 Activity 可见时启动录音服务」**。这条路径同时满足磁贴、快捷方式、通知、小部件、无障碍。
2. **后台启动 Activity 的白名单。** 通知 / 小部件 / 桌面图标的点击没问题；无障碍服务因为被系统以 `BIND_ALLOW_BACKGROUND_ACTIVITY_STARTS` 绑定，也可以拉起面板。参见 [Activity security](https://developer.android.com/guide/components/activities/secure-bal)。
   → 音量键手势可行，不需要悬浮窗权限（`SYSTEM_ALERT_WINDOW`）。`shengwuji` 用悬浮窗是为了「不跳转 App」，我们的透明面板本来就是 `excludeFromRecents` 的轻量窗口，体验接近，权限更少。

### 2.3 闪念贝壳 MCP 对音频的支持

| 项目 | 现状 |
| --- | --- |
| 接口 | `note_create` 的 `audios`：`[{ data: base64, name }]` |
| 格式 / 限制 | mp3 / m4a / wav / aac；单个 ≤ 25MB，最多 5 个 |
| 转写 | **不会自动转写**，要在闪念贝壳 App 里手动发起（见 README「Save Files」） |
| 追加 / 修改 | `note_update` 可以改正文；`note_detail` 可读回 |
| 安卓端现状 | `IdeashellApi.createNote` 目前只带 `images`，要补 `audios` |

由此得到：**转写必须自己做**，否则存进去只是一条没有文字的音频笔记，既搜不到，也进不了待办和日记的自动分流。

### 2.4 参考项目 shengwuji

[shengwuji](https://github.com/fantasyao/shengwuji)（Apache-2.0，Flutter + Kotlin 原生层）是「锤子闪念胶囊」的复刻。以下是值得借鉴的点：

| 它的做法 | 我们怎么用 |
| --- | --- |
| 无障碍服务拦音量键，4 个手势槽位（长按上 / 下、双击上 / 下）× 多种动作，**每次按键实时读配置**，App 没开也生效 | 借鉴槽位模型和状态机（长按阈值默认 400ms、双击窗口 300ms，`wasLongPress` 短路，耳机键仅录音中拦截）。我们动作更少：录音、新建文字笔记、两者的「按住说话」 |
| 「按住说话」：长按达阈值开录，松开同一键停止并转写 | 采纳，做成长按槽位的专属动作 |
| 内置 SenseVoice（sherpa-onnx）+ Silero VAD，识别在常驻 worker 里，PCM 16kHz 单声道 | 采纳；用 Kotlin 版 sherpa-onnx，放到独立线程，不碰主线程 |
| **录音防丢失：先落盘，再转写，失败可重转** | 采纳，是硬性要求：任何情况下录音文件都不能丢 |
| 说完停一下自动停止、录音上限 5 分钟 | 采纳（静音 2 秒自动停，上限默认 5 分钟，可调） |
| 热词替换，后来升级为拼音 / 音素匹配 | 第二期做简单热词表，并**自动并入项目关键词和已有标签**（我们有项目体系，它没有） |
| 悬浮窗胶囊（需悬浮窗 + 无障碍 + 付费） | 暂不做，用透明面板替代；有需要再作为 V3 |
| 模型 229MB 直接打进 APK，首次启动部署 | **不照搬**：改为首次使用时下载，避免 APK 暴涨；下载源和校验见 4.3 |
| 完全不联网 | 我们要联网同步闪念贝壳；音频和模型都在本机，**只把结果上传到用户自己的闪念贝壳** |

---

## 三、整体方案

### 3.1 用户路径

```
触发（磁贴 / 快捷方式 / 通知 🎙 / 小部件 🎙 / 音量键 / 耳机键 / deeplink）
  → 透明面板秒开，立刻开始录音（波形 + 计时）
  → 说完停 2 秒自动结束（也可点「完成」/ 再按一次音量键 / 松开按住说话）
  → 本机转写（通常不到 1 秒）→ 万能输入解析（待办 / 日记 / 笔记）
  → 写入离线队列（毫秒级）→ 面板关闭，Toast「已保存 · 笔记（语音）」+ 一下震动
  → 后台同步到闪念贝壳 / 滴答（带音频附件）
```

沿用刚做的「保存后直接关闭、没有撤销窗口」：保存失败以外，不再多一层确认。语音转写难免有错字，所以要提供一个开关：**转写后先显示文字让我确认**（默认关）。

### 3.2 保存规则

| 转写结果 | 保存为 | 音频附件 |
| --- | --- | --- |
| 以「待办 / 提醒我」开头，或含今天及以后的明确时间 | 待办（走滴答或闪念贝壳） | 不附 |
| 以「日记」开头，或是短句 | 追加到 Daily Note | 不附 |
| 「笔记」开头，或较长（> 100 字 / 多段） | 笔记：标题取首行 ≤30 字，正文是转写文字，标签 = 默认标签 + `#语音` | **附 m4a**（设置里可关；关闭则只存文字） |
| 没有识别出文字（噪音 / 模型没下好 / 转写失败） | 笔记，标题「语音 2026-10-12 16:30」，正文留空 | 附 m4a，之后可在闪念贝壳里手动转写 |

这些规则就是 README 里的「自动判断」，**语音只是多了一个「文字从哪来」的前端**，后面的解析、队列、同步都不改。

### 3.3 模块与改动

```
system/voice/
  VoiceCaptureService.kt     # 前台服务（microphone）：AudioRecord 16kHz 单声道 PCM
                             #   一路喂 VAD（静音自动停），一路编码 AAC → m4a（MediaCodec + MediaMuxer，约 32kbps ≈ 0.25MB/分钟）
  AudioRecorder.kt           # 录音 + 编码，先写盘再说；中途崩溃也保留已写入的文件
  Transcriber.kt             # 接口：suspend fun transcribe(pcm: ShortArray): TranscribeResult
  SherpaTranscriber.kt       # SenseVoice int8 + Silero VAD，arm64-v8a，识别在独立线程
  ModelManager.kt            # 模型下载（断点续传、sha256 校验、存 filesDir/models/）、状态、删除
  HotwordCorrector.kt        # 简单热词替换（二期）；词表 = 用户词表 ∪ 项目关键词 ∪ 已有标签
ui/capture/
  VoicePanel.kt              # 面板上的录音态：波形、计时、完成 / 取消、转写中、失败重试
  QuickCaptureActivity.kt    # 新 action：ACTION_QUICK_VOICE；启动即开录（onResume 里启动前台服务）
system/
  QuickVoiceTileService.kt   # 第二个磁贴「闪念 · 语音」
  VolumeKeyService.kt        # （三期）无障碍服务：槽位 → 动作
data/db/
  CaptureEntity.kt           # 新增 audioPath（和 images 一样，换行分隔、同步成功后删除）、transcribeState
  AppDatabase.kt             # version 2 → 3，加列迁移
data/capture/
  CaptureProcessor.kt        # createNote 带 audios；音频 > 25MB 时提示并拆段
data/ideashell/
  IdeashellApi.kt            # createNote 增加 audios 参数（与 images 同构）
```

关键细节：

- **先落盘再转写。** 录音停止后先把 m4a 和一条 `captures` 记录（`transcribeState=PENDING`）写进队列，再转写；转写失败或进程被杀，下次启动会续做。
- **转写不进主线程，也不阻塞保存。** 转写完成后更新这条记录的正文和类型；如果面板已经关了，就在后台完成。
- **模型常驻策略：** 触发录音的同时在后台预加载模型（240MB int8，加载约 1–2 秒，与录音并行，说完话时基本已就绪）；空闲 60 秒后释放，省内存。
- **耗时预期：** 公开基准里 SenseVoice 在安卓上 30 秒音频约 1.7 秒（RTF≈0.06）。Magic8 Pro 的芯片更强，一般 10 秒内的语音不到 1 秒出字。数据来源见 [VoicePing 基准](https://voiceping.net/en/blog/research-offline-speech-transcription-benchmark/)，**待真机实测**。
- **语言：** SenseVoice 2025-09-09 int8 版支持中 / 英 / 日 / 韩 / 粤，打开 ITN（把「三点半」之类转成规范写法，利于日期解析）。具体开关看 [sherpa-onnx SenseVoice 文档](https://k2-fsa.github.io/sherpa/onnx/sense-voice/index.html)。

### 3.4 入口矩阵（更快、更方便）

| # | 入口 | 触发到开录 | 阶段 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 现有输入面板里加 🎙 | 点一下 | **V1** | 面板里按住说话直接填入文字，不留音频（「听写」模式） |
| 2 | **「闪念 · 语音」磁贴** | 下拉点一下 | **V1** | 复用磁贴机制；Android 14+ 用 `PendingIntent` 版 `startActivityAndCollapse` |
| 3 | 桌面快捷方式「语音记」 | 长按图标 | **V1** | 在 `shortcuts.xml` 加第三项 |
| 4 | **通知栏常驻通知加 🎙 按钮** | 下拉点一下 | **V1** | 已有「回复 / 完成」按钮，再加一个 |
| 5 | 桌面小部件加 🎙 | 一键 | **V1** | 标题栏加按钮 |
| 6 | deeplink `ideashell://record` | 其他应用 / 任意门 / 自动化工具 | **V1** | 与现有 `ideashell://capture` 并列，支持 `?mode=ptt` |
| 7 | **接收「录音机」分享的音频** | 分享 → 闪念 · 音频 | **V0** | 注册 `SEND` / `SEND_MULTIPLE` `audio/*`；mp3 / m4a / wav / aac 直传，其他格式（amr / 3gp 等）先转 AAC；> 25MB 提示 |
| 8 | **音量键手势** | 长按音量下 / 双击音量上 等 | V2 | 无障碍服务，4 槽位 × 动作；含「按住说话」 |
| 9 | 耳机线控 / 蓝牙键 | 按一下 | V2 | 同一个无障碍服务；只在「录音中」拦截 |
| 10 | **系统默认笔记应用（`ROLE_NOTES`）** | 锁屏 / 手写笔 / 系统笔记入口 | V2 | 加 `ACTION_CREATE_NOTE` 的 Activity 别名，`showWhenLocked` + `turnScreenOn`；**先 `isRoleAvailable` 探测**，荣耀不开就不显示该设置项 |
| 11 | 荣耀「快捷启动 / 键位映射」 | 随系统 | V2 | 不写代码，只在设置页提供图文引导：把键位 / 手势映射到「闪念 · 语音」快捷方式（具体菜单名随版本，**待真机确认**） |
| 12 | 悬浮窗胶囊 | 贴边把手 | V3（可选） | 需要 `SYSTEM_ALERT_WINDOW`；Android 15 起从后台启动前台服务还要求有可见的悬浮窗 |
| 13 | 荣耀 Voice Kit 适配器 | — | V3（可选） | 实现 `Transcriber`，拿到权限后替换自带模型 |

**明确不做：**

- **常驻唤醒词。** 需要一直占着麦克风，耗电，系统会一直显示麦克风使用提示，荣耀还会把它当作后台耗电应用。
- **YOYO 智能体。** 理由见 2.1。
- **数字助理角色。** 抢电源键与荣耀 YOYO 冲突。

### 3.5 除了语音，还能更快的几个小点

| 点子 | 说明 | 阶段 |
| --- | --- | --- |
| 面板记住上次的「类型 / 标签」 | 连续记同一类内容时少点一次 | V1 |
| 剪贴板一键记 | 面板打开时检测到剪贴板有新文字，顶部给一个「存剪贴板」按钮（已有读取逻辑，可复用） | V1 |
| 拍照直接存 | 面板里 📷（已有），再补「拍完不进相册、直接队列」 | 已有 |
| 最近标签 / 项目快选 | 顶部放最近用过的 3 个项目标签，点一下就加 | V1 |
| 语音笔记在回顾里可播放 | 时间河里带 🎙 的条目可播放附件（需从笔记详情拿到音频地址，**待确认 MCP 返回字段**） | V2 |

---

## 四、技术细节与风险

### 4.1 权限与清单

- 新增：`RECORD_AUDIO`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_MICROPHONE`；服务声明 `android:foregroundServiceType="microphone"`。
- `POST_NOTIFICATIONS` 已有（前台服务通知需要）。
- 无障碍服务（V2）：`BIND_ACCESSIBILITY_SERVICE`，配置里 `canRequestFilterKeyEvents="true"`、`flagRequestFilterKeyEvents`；说明文字写清楚「只用来识别音量键 / 耳机键手势，不读取屏幕内容」，`canRetrieveWindowContent="false"`。
- 录音时系统会显示麦克风使用提示（绿点），无法也不应绕过；面板里自己也要有明显的「录音中」状态。

### 4.2 荣耀 / MagicOS 适配

- 录音前台服务比常驻通知更不容易被杀，但**无障碍服务**在荣耀上可能被「应用启动管理」「一键清理」杀掉：沿用设置页的保活引导，并在无障碍页加「检测服务是否存活」。
- 前台服务通知要有清晰的标题（「闪念 · 正在录音」），避免被系统当作无意义常驻。
- 后台限制只影响「后台同步是否及时」，**录音本身是前台行为，不受影响**；同步由现有的 WorkManager 队列兜底。

### 4.3 模型分发

| 方案 | 利弊 |
| --- | --- |
| 打进 APK | 首次即用，但 APK 增大约 240MB，不适合分发 |
| **首次使用时下载（推荐）** | APK 小；设置页展示下载进度；模型放 `filesDir/models/`，校验 sha256；失败可重试；可删除 |
| 用户自己放文件 | 太麻烦，不采用 |

模型和 VAD 的来源用 sherpa-onnx 的发布页和 Hugging Face（`csukuangfj/...`）；国内下载慢时需要备用镜像，**具体镜像地址实现时再定**。没下载模型时，语音功能自动降级为 V0：录音 + 音频笔记，不会不可用。

### 4.4 数据与隐私

- 音频只存在本机 `filesDir/voice/`，同步成功后删除（可在设置里选「保留 7 天」）。
- 转写在本机完成，不经过任何第三方。
- 只有保存到闪念贝壳时才会上传，对象是用户自己的账号。
- 日志里不记录转写文本和音频路径以外的内容（沿用现有规则）。

### 4.5 风险清单

| 风险 | 影响 | 应对 |
| --- | --- | --- |
| 前台服务启动被拒（后台启动麦克风） | 录音失败 | 所有入口统一先显示 Activity，再启动服务；失败时面板里明确提示并回退为文字输入 |
| 荣耀不开放 `ROLE_NOTES` | 锁屏直达不可用 | 先探测；不可用就只保留其他入口，不影响主线 |
| 无障碍服务被杀 | 音量键手势失效 | 保活引导 + 存活检测；手势只作为增强入口，磁贴 / 通知始终可用 |
| 人名、项目名识别不准 | 文字有误 | 热词表自动并入项目关键词和标签；笔记正文始终保留原音频，可回听、可在闪念贝壳里重转 |
| 模型占内存 | 低端机卡顿 | 懒加载 + 空闲释放；Magic8 Pro 内存充裕，其他机型可在设置里关闭「预加载」 |
| 录音 > 25MB 上传失败 | 附件丢失 | 默认 AAC 32kbps，25MB ≈ 100 分钟；上限默认 5 分钟；超限自动按 10 分钟分段 |
| 误触（音量键 / 耳机键） | 多余的空录音 | 槽位默认只开一个；录音 < 1 秒或没有人声直接丢弃并轻震提示 |
| 电池 | 持续录音耗电 | 仅按需录音，无常驻麦克风；VAD 静音自动停 |

---

## 五、里程碑

| 阶段 | 内容 | 预估 | 验收 |
| --- | --- | --- | --- |
| **V0 录音与音频笔记（不依赖转写）** | ① `IdeashellApi.createNote` 加 `audios`；`CaptureEntity.audioPath` + 迁移；`CaptureProcessor` 上传；② 分享目标 `audio/*`（录音机分享）；③ 面板里录音态（录 → 停 → 存为音频笔记，先落盘）；④ `VoiceCaptureService`（microphone 前台服务） | 2–3 天 | 录一段 30 秒，闪念贝壳里出现带 m4a 附件的笔记；断网录音，联网后自动同步；从荣耀录音机分享的音频能存成笔记 |
| **V1 离线转写与快速入口** | ① `ModelManager` + `SherpaTranscriber` + Silero VAD；静音自动停；② 转写文字进入万能输入解析，待办 / 日记 / 笔记分流；③ 入口 1–6：面板 🎙、语音磁贴、快捷方式、通知 🎙、小部件 🎙、deeplink；④ 热词（用户词表 + 项目关键词 + 标签）；⑤ 设置：自动停止时长、是否附音频、转写后是否确认、模型管理 | 4–6 天 | 说「明天下午三点交周报」→ 滴答里出现待办；说「今天试了新的工作流」→ 进 Daily Note；说一段长话 → 笔记带原音频；触发到开录 < 400ms（磁贴 / 快捷方式） |
| **V2 硬件键与系统入口** | ① 无障碍服务：音量键 4 槽位 + 按住说话 + 耳机键；② `ROLE_NOTES` 与锁屏直达（探测可用才开）；③ 荣耀键位映射引导；④ 回顾里的语音条目可播放 | 3–4 天 | 灭屏 / 亮屏两种状态下长按音量下键能开录；松手停止；荣耀杀后台后能提示重新开启 |
| **V3 可选** | 悬浮窗胶囊；Voice Kit 适配器；拼音 / 音素级热词 | 按需 | — |

### 待真机验证（Magic8 Pro / MagicOS 11）

1. 磁贴 / 快捷方式触发到录音开始的耗时。
2. 灭屏、锁屏下通知 🎙 按钮的行为（是否需要先解锁）。
3. 荣耀「应用启动管理」对录音前台服务、无障碍服务的影响。
4. `RoleManager.isRoleAvailable(ROLE_NOTES)` 是否为 true。
5. 荣耀录音机分享出来的文件格式 / MIME。
6. SenseVoice 的模型加载耗时和 10 秒语音的转写耗时。
7. Voice Kit 是否对个人开发者开放（看你是否想走这条路）。

---

## 六、需要你拍板的几件事

1. **第一步做到哪？** 建议先做 V0（录音 + 音频笔记，不装模型就能用），再做 V1。
2. **转写后是否直接保存？** 建议默认直接保存（与「去掉撤销窗口」一致），设置里可以改成「先确认文字」。
3. **音频附件默认要不要附？** 建议长笔记默认附，待办 / 日记不附。
4. **音量键手势要不要做？** 它需要无障碍权限，也最容易被荣耀杀掉，建议放到 V2 再看。
5. **模型下载源。** 是否接受首次使用时从 Hugging Face / GitHub 下载 240MB；国内网络慢时，是否有你自己的镜像。
