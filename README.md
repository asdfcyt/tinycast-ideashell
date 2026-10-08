# 闪念贝壳 (ideashell) 扩展

在 Raycast / Tinycast 中快速记录灵感、写 Daily Note、搜索笔记、管理待办。通过闪念贝壳官方 MCP 接口（`https://api.ideashell.cn/ideashell/mcp`）与你的笔记同步。

## 命令一览

| 命令 | 模式 | 说明 |
| --- | --- | --- |
| **Quick Note** | 无界面 | 搜索栏输入文字，回车即创建一条笔记（标题取前 30 字） |
| **Create Note** | 表单 | 填写标题、正文（Markdown）、标签、文件夹后创建 |
| **Daily Note** | 无界面 | 把内容追加到今天的 Daily Note，不存在则自动创建 |
| **View Daily Note** | 列表 | 浏览 Daily Note 文件夹中的所有日记，左侧日期列表，右侧完整内容预览 |
| **Search Notes** | 列表 | 语义搜索笔记；不输入时显示最近 20 条；左侧列表，右侧全文预览 |
| **Add Todo** | 无界面 | 快速创建待办，支持自然语言日期/时间 |
| **Manage Todos** | 列表 | 按日期分组查看待办，完成 / 恢复 / 编辑 / 新建 |
| **Smart Capture** | 列表 | 万能输入：自动判断是待办 / Daily Note / 笔记，执行前先预览，支持 `#标签` `@文件夹` |
| **Timeline** | 列表 | 时光机：输入「昨天 / 上周 / 10月3日」查看那段时间的笔记和待办，一键复制为 Markdown 日报/周报 |
| **Save Files** | 表单 | 把 Finder 选中的图片 / 音频 / PDF / Office 文件保存为带附件的笔记 |

## 安装与配置

1. 在闪念贝壳 App 中：**设置 → MCP** 获取 API Key。
2. 安装依赖并构建：

   ```bash
   npm install
   npm run build      # 或 npm run dev 进入开发模式
   ```

3. 首次运行任一命令时，在偏好设置中填写：

   | 偏好 | 必填 | 说明 |
   | --- | --- | --- |
   | API Key | 是 | 闪念贝壳 MCP API Key |
   | Daily Note Folder | 否 | Daily Note 所在文件夹，默认 `Daily Notes`。大小写、空格、末尾 `s` 不敏感（`Daily Notes` / `Dailynotes` / `daily-note` 视为同一个）；找不到时自动创建 |
   | Daily Note Title Format | 否 | 预留项，当前 Daily Note 标题固定为 `YYYY-MM-DD` |
   | Default Tags | 否 | 创建笔记时默认附加的标签，逗号分隔 |

### 安装到 Tinycast

Tinycast 的扩展目录为 `~/Library/Application Support/com.tinycast.app/extensions/ideashell`，直接把构建产物输出到该目录即可：

```bash
npx ray build -o "$HOME/Library/Application Support/com.tinycast.app/extensions/ideashell"
```

构建后如未生效，重启 Tinycast。

## Daily Note

- 标题为当天日期，如 `2026-10-08`，存放在 Daily Note 文件夹，带 `daily-note` 标签。
- 每次追加一条列表项，时间加粗、精确到分钟：

  ```markdown
  - **2026-10-08 11:57** 开发成功了闪念贝壳
  - **2026-10-08 11:58** 查看今日日记还需要改进
  ```

- 追加时会自动把当天笔记里旧格式（挤在一行、带秒、无列表符号）的条目整理成上述格式。
- 查找今天的笔记时，优先在 Daily Note 文件夹里按标题日期匹配，其次使用本地缓存的 note_id，因此换设备或清缓存也不会重复创建。
- **View Daily Note** 快捷键：`⌘R` 刷新、`⌘C` 复制正文、`↵` 查看全文。

## 待办

### Add Todo

在参数框里直接输入，日期和时间会被自动识别并从内容中去掉：

| 输入 | 结果 |
| --- | --- |
| `明天 15:00 开会` | 内容「开会」，明天 15:00 |
| `下周五下午3点半 交周报` | 内容「交周报」，下周五 15:30 |
| `10月9日 买车票` | 内容「买车票」，10 月 9 日（已过则按明年） |
| `2026-10-20 续费域名` | 内容「续费域名」，指定日期 |
| `周三 洗车` | 本周三（已过则下周三） |
| `20:30 健身` | 只有时间时，日期默认今天 |
| `给妈妈打电话` | 无日期、无时间 |

支持的写法：

- 日期：`今天/明天/后天/大后天`、`周X / 星期X / 下周X / 下下周X`、`M月D日`、`YYYY-MM-DD`
- 时间：`15:30`、`3点`、`3点半`、`下午3点`、`晚上8点15分`（`下午/晚上` 自动换算为 24 小时制）

### Manage Todos

- 分组：已逾期 / 今天 / 明天 / 之后每个日期 / 无日期 / 最近已完成（20 条）。
- 快捷键：

  | 操作 | 快捷键 |
  | --- | --- |
  | 标记完成 / 恢复未完成 | `↵` |
  | 编辑待办 | `⌘E` |
  | 新建待办（表单） | `⌘N` |
  | 用搜索栏文字直接创建（同样支持自然语言日期） | `⌘↵` |
  | 复制内容 | `⌘⇧C` |
  | 刷新 | `⌘R` |

- 编辑表单里的日期/时间同样支持自然语言（如 `明天`、`下午3点`）。
- 受接口限制，**无法删除待办，也无法清除已设置的日期/时间**；编辑时留空表示保持不变。

## Smart Capture 万能输入

一个输入框，自动判断你想做什么，并在列表里预览三种结果（推荐项排第一，回车即执行）：

| 输入 | 推荐 |
| --- | --- |
| `明天 15:00 开会`、`下周五交周报`、`10月20日 续费域名` | 待办 |
| `待办：续费域名`、`todo 买电池`、`提醒我 喝水` | 待办（强制） |
| `今天试了新的工作流` | 追加到今天的 Daily Note |
| `#读书 @阅读笔记 《穷查理宝典》很有启发` | 笔记（带标签，放入「阅读笔记」文件夹） |
| 多行文本，或超过 100 字 | 笔记 |

- 判断为待办的条件：以「待办 / todo / 提醒」开头，或包含**今天及以后**的明确时间、**明天及以后**的日期（「昨天 3 点开了会」不会被当成待办）。
- `#标签`、`@文件夹` 要求前面是行首或空格（`C#`、邮箱不受影响）；文件夹名同样大小写 / 空格 / 末尾 `s` 不敏感，找不到时会提示并不放入文件夹。
- 输入为空时，如果剪贴板里有文字，会提供「把剪贴板存为笔记 / 追加到 Daily Note」。

## Timeline 时光机

在搜索栏输入时间范围（留空 = 最近 7 天）：

`今天` `昨天` `前天` · `本周` `上周` · `本月` `上月` · `周三` `上周三` · `10月3日` `2026-10-03` · `最近14天` `最近一个月` · `10月1日到10月7日`

- 按天分组，每天先列笔记（带摘要和时间），再列当天待办（可直接勾选完成）。
- 顶部「概览」行 `⌘↵`：把整段时间复制为 Markdown 回顾，格式如下，可直接贴进日报 / 周报：

  ```markdown
  # 上周 回顾

  > 12 条笔记 · 待办完成 5/7

  ## 2026-10-07 周三

  **笔记**

  - 15:33 **书法练习 洛神赋** — 今日书法练习，临写赵孟頫行书……

  **待办**

  - [x] 交周报（15:30）
  ```

- 单次最多回溯 62 天；`recent_notes` 每次最多返回 20 条，插件会自动按时间对半拆分，保证大区间也能取全。
- 待办按其「日期」归入对应的一天；无日期待办不出现在时间线里。

## Save Files 文件收纳

在 Finder 里选中文件后运行该命令（会自动预填），或在表单里手动选择：

| 类型 | 格式 | 限制 |
| --- | --- | --- |
| 图片 | png / jpg / jpeg / gif / webp | 单张 ≤ 5MB，最多 9 张 |
| 图片（自动转换） | heic / heif / tiff / bmp / avif | 用系统 `sips` 转为 JPEG；超过 5MB 的图片也会自动缩小 |
| 音频 | mp3 / m4a / wav / aac | ≤ 25MB，最多 5 个；**不会自动转写**，需在闪念贝壳 App 里手动发起 |
| 文档 | pdf / doc(x) / xls(x) / ppt(x) | ≤ 50MB，最多 5 个 |
| 文本 | txt / md / csv / log / json / xml / yaml / yml | ≤ 5MB（计入文档的 5 个上限） |

- 服务端会自动提取 **pdf / doc / docx / xls / xlsx / txt / md** 的文字，之后用 Search Notes 的语义搜索就能搜到文件里的内容；ppt / csv / json 等只存储、不提取文字。
- 超过数量上限时会提示分批保存；单个文件不合规（过大 / 格式不支持）会被跳过并在提示里说明。

## 使用的 MCP 接口

| 接口 | 用途 |
| --- | --- |
| `note_create` / `note_update` / `note_detail` | 创建（含图片 / 音频 / 文档附件）、更新、读取笔记 |
| `note_search` | 语义搜索 |
| `recent_notes` | 最近的笔记（`limit` 1–20）；Timeline 用它的 `start_time` / `end_time` 区间 |
| `folder_list` / `folder_create` / `folder_notes` | 文件夹列表 / 创建 / 列出文件夹内笔记 |
| `todo_create` / `todo_update` / `todo_list` | 待办的创建 / 更新（含完成状态）/ 查询 |

接口还提供 `unfiled_notes`、`note_move`、`folder_edit`、`speaker_list`、`search_by_speaker`，暂未接入。

## 项目结构

```
src/
├── api.ts               # MCP 客户端 + 笔记 / 文件夹 / 待办 API
├── daily.ts             # Daily Note 文件夹定位、今日笔记查找、追加排版
├── daily-note.ts        # Daily Note 命令
├── daily-note-view.tsx  # View Daily Note 命令
├── search-notes.tsx     # Search Notes 命令
├── quick-note.ts        # Quick Note 命令
├── create-note.tsx      # Create Note 命令
├── add-todo.ts          # Add Todo 命令
├── manage-todos.tsx     # Manage Todos 命令
├── smart-capture.tsx    # Smart Capture 命令
├── timeline.tsx         # Timeline 命令
├── save-files.tsx       # Save Files 命令
├── capture-parse.ts     # 万能输入的意图判断、#标签 / @文件夹 解析
├── time-range.ts        # Timeline 的时间范围解析
├── todo-parse.ts        # 待办自然语言日期 / 时间解析
├── attachments.ts       # 附件分类、sips 转换 / 压缩、数量与大小限制
├── note-detail-view.tsx # 笔记全文页（标题 → 摘要 → 正文）
├── use-note-details.ts  # 列表选中时按需加载并缓存笔记全文
└── utils.ts
assets/extension-icon.png
```

## 开发

```bash
npm run dev        # 开发模式
npm run build      # 构建
npm run lint       # 检查
npm run fix-lint   # 自动修复
```

## 许可

MIT
