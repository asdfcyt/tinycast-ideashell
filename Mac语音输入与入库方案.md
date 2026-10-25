# 拾忆 Mac · 语音输入与入库方案

> 状态：P1–P3 已实现（见下方「八、开发清单」里还没做的项）。参考 [Typefree](https://github.com/kdsz001/typefree)（GPL-3.0，只借鉴交互思路，不拷代码）和安卓端已落地的实现，见 `安卓App语音输入与意图整理方案.md`。

## 一、目标

在任何 App 里按一个全局快捷键开始说话，说完后 AI 把口语整理成「待办 / 日记 / 笔记」（含日期时间、优先级、标签，一句话多件事拆成多条），**预览确认后直接入库**，不用打开主窗口。

核心体验：说一句是一句；任何一步失败，话都不丢。

## 二、调研结论

### Typefree 做了什么
按住快捷键 / 鼠标说话 → 识别（火山引擎）→ AI 整理（通义千问）→ 输入到光标处。另有词库纠错、历史记录、口令（「用英文」）、下拖锁定 / 拖远取消。

**取舍**：拾忆的终点是「入库」而不是「打字到光标」，所以不做光标输入（P3 才作为可选项）；其余思路（识别与整理分家、口令走规则、纠错学习、失败回退）沿用。

### 安卓端已有的，可直接移植
| 安卓端模块 | 作用 | Mac 对应 |
|---|---|---|
| `VoiceIntents.systemPrompt / parse` | 一次调用输出 待办 / 日记 / 笔记 / 问 AI / 追加 / 改·完成·删·查待办，多条拆分 | `VoiceIntent.swift`（提示词与解析规则保持一致） |
| `VoiceIntents.fixRelativeTime` | 「半小时后」本地精确计算，不信模型心算 | 复用 `TodoParser.findAfterDuration`（Mac 已有） |
| `SpeechCleaner` + 口令 | 去语气词、「追加到上一条笔记」本地识别 | `SpeechCleaner.swift` |
| `Lexicon` | 热词 + 替换规则 + 纠错学习 | `Lexicon.swift`（P2） |
| `TencentAsr` | 腾讯云一句话识别 + 热词 | `TencentAsr.swift`（P2，可选） |

### Mac 端已具备
`LlmClient`（OpenAI 兼容，已有 Key 设置）、`TodoParser`、`submitCapture`（待办 → 滴答 / 日记 / 笔记入库）、全局热键 `GlobalHotkey`、悬浮窗 `QuickAddPanel`。**缺的只有：录音、语音识别、语音提示词与预览界面。**

### 识别引擎（本机实测）
- `SFSpeechRecognizer` zh-CN：**支持离线识别且当前可用**。
- macOS 26 新 `SpeechTranscriber`：可用（目标系统 macOS 14，需 `#available(macOS 26)` 判断）。
- 结论：Mac 不必像安卓那样依赖腾讯云；P1 用系统离线识别（实时出字、零费用、不上传音频），中文专有名词不够准时 P2 加腾讯云可选。

## 三、整体流程

```
全局热键（默认 ⌃⌥V）
  → 顶部小胶囊「正在听…」+ 波形 + 实时文字
  → 再按一次 / 回车 结束；Esc 取消（P2：按住说话、松手结束）
  → 识别原文 → 词库替换 + 本地口令
  → LLM 一次整理：去口语 / 断句标点 / 类型 / 日期时间 / 优先级 / 标签；多件事拆多条
  → 本地校验（相对时间用 TodoParser 精算）
  → 预览卡片：每条 类型 + 内容 + 时间；3 秒倒计时自动入库
      可点改内容 / 切类型 / 删除某条 / 看原始转写；点任意处暂停倒计时
  → submitCapture 入库 → 结果提示 → 自动消失
任一步失败 → 回退「原始转写 + 本地规则（TodoParser / CaptureParser）」，仍可入库；原文先落草稿
```

## 四、关键原则（沿用安卓端）

1. **话不丢**：识别完立刻把原文存草稿；网络 / LLM 失败回退到原文，不阻塞记录。
2. **日期本地算**：相对时间（半小时后）由 `TodoParser` 精算；LLM 只负责理解和给出推算结果，本地做格式校验。
3. **口令走规则**：类型指定、追加到上一条等口令用规则识别，不让模型猜。
4. **默认先预览再入库**：语音误识别风险高于打字；设置里可开「说完直接入库」。
5. **没配 LLM Key 也能用**：只走本地规则。

## 五、技术选型与模块

| 环节 | 方案 | 说明 |
|---|---|---|
| 录音 | `AVAudioEngine` 16kHz 单声道，最长 60 秒 | Info.plist 加 `NSMicrophoneUsageDescription` |
| 识别 P1 | `SFSpeechRecognizer` 离线流式 | 加 `NSSpeechRecognitionUsageDescription`；热词用 `contextualStrings` |
| 识别 P2 | 腾讯云一句话识别（可选） | 设置里填 SecretId / Key（同安卓）；松手后一次返回 |
| 整理 | `LlmClient.chatJSON` + `VoiceIntent.swift` | 提示词 / 解析与安卓一致，两端行为统一 |
| 入库 | `submitCapture` | 不改现有入库逻辑 |
| UI | 新增 `VoicePanel`（复用 `QuickAddPanel` 的悬浮窗机制） | 录音阶段无需键盘；预览阶段要编辑时再激活应用 |
| 热键 | `GlobalHotkey` 新增第三个 id；P2 加 `kEventHotKeyReleased` 支持按住说话 | 设置页复用 `QuickAddHotkeyRow` 的录制 UI |

新增文件（拟）：`Core/VoiceRecorder.swift`、`Core/SpeechEngine.swift`、`Core/VoiceIntent.swift`、`Core/SpeechCleaner.swift`、`Core/VoiceCapture.swift`（流程编排）、`Views/VoicePanel.swift`、`Views/VoiceHotkeyRow.swift`。

## 六、分阶段

### P1：说出来就入库（最小可用）
- 热键 → 录音 → Apple 离线识别（实时文字）→ LLM 整理（新建待办 / 日记 / 笔记，支持拆多条）→ 预览 3 秒 → 入库。
- 设置页：热键、麦克风 / 语音识别权限状态、「说完直接入库」开关。
- 失败回退与草稿保留。

### P2：越用越准
- 词库 + 纠错学习（预览里点修正误识别词，记入替换规则 / 热词）。
- 腾讯云识别可选；按住说话模式。
- 历史记录（保留原始转写，可对照 / 撤回整理）。
- 「追加到上一条笔记」。

### P3：与安卓对齐 + 扩展
- 口令扩展：改 / 完成 / 删除 / 查待办、问 AI。
- 可选「同时输入到光标处」（Typefree 主玩法，需要辅助功能权限）。
- 实测对比 macOS 26 `SpeechTranscriber` 与 `SFSpeechRecognizer`。

## 七、风险与待确认

1. **权限与签名**：麦克风 / 语音识别权限绑定应用签名。`build.sh` 优先用本机 Apple Development 证书，权限可保持；退到 ad-hoc 签名则每次重编译都会重新授权。
2. **隐私**：转写文字会发给你配置的 AI 服务（与安卓一致），设置里需写明；没填 Key 时只走本地。
3. **中文离线识别准确率**：专有名词一般，P1 实测后决定是否把腾讯云提前。
4. **热键松开事件**：现有 Carbon 热键只处理「按下」，按住说话需新增「松开」事件（可行）。
5. **唤出时主窗口闪现**：语音面板和万能输入窗一样用「不激活应用」的悬浮窗（Raycast / Alfred 同类做法），别的 App 保持前台，主窗口不会被带出来；输入法靠显式激活输入框的输入上下文（`inputContext.activate()`）。
6. **GPL**：Typefree、Sayso 只借鉴思路；自家安卓代码移植无许可问题。

## 八、开发清单（待做）

- [ ] **5. 按前台 App 调语气**：录音开始时取前台 App 名（`NSWorkspace.frontmostApplication`），随转写一起交给 AI；微信 / 备忘录口语化，邮件 / 文档书面化，编辑器里按代码注释风格。设置里可关，也可按 App 自定义语气（默认表 + 覆盖）。
- [ ] **6. 指令 / 改写模式**：选中一段文字后按快捷键，说「改正式一点 / 翻译成英文 / 缩短」，用辅助功能读取选中内容 → AI 改写 → 替换选中文字（保留撤销；读不到选中内容时退回剪贴板方案）。需要辅助功能权限。
- [ ] **7. 只输入模式（不入库）**：独立快捷键，整理后的文字只输入到光标处，不进滴答 / 闪念贝壳。例如右 ⌥ = 入库，右 ⌘ = 只输入；复用 `VoicePaster`，预览可跳过。
