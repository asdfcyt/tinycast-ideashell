/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** API Key - 闪念贝壳 MCP API Key（在闪念贝壳 设置 → MCP 中获取） */
  "apiKey": string,
  /** Daily Note Folder - Daily Note 存放的文件夹名称（大小写、空格、末尾 s 不敏感，如 Daily Notes / Dailynotes 视为同一个；找不到时会自动创建） */
  "dailyNoteFolder": string,
  /** Daily Note Title Format - Daily Note 标题格式，使用 YYYY-MM-DD 等占位符 */
  "dailyNoteTitleFormat": string,
  /** Default Tags - 创建笔记时默认添加的标签（逗号分隔） */
  "defaultTags": string,
  /** Templates - 自定义模板，多个用 ; 分隔。语法：名称:字段1,字段2+,字段3 #标签 @文件夹（字段名后加 + 为多行）。例：刻印:作品,印文,感受+,问题+ #篆刻 #练习 @篆刻练习; 体重:体重,备注 #体重。与内置模板（练习 / 阅读 / 决策 / 复盘 / 指标）同名则覆盖内置。 */
  "templates": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `smart-capture` command */
  export type SmartCapture = ExtensionPreferences & {}
  /** Preferences accessible in the `template-capture` command */
  export type TemplateCapture = ExtensionPreferences & {}
  /** Preferences accessible in the `clip-selection` command */
  export type ClipSelection = ExtensionPreferences & {}
  /** Preferences accessible in the `notes` command */
  export type Notes = ExtensionPreferences & {}
  /** Preferences accessible in the `manage-todos` command */
  export type ManageTodos = ExtensionPreferences & {}
  /** Preferences accessible in the `todos-menu` command */
  export type TodosMenu = ExtensionPreferences & {}
  /** Preferences accessible in the `save-files` command */
  export type SaveFiles = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `smart-capture` command */
  export type SmartCapture = {
  /** 记点什么…（留空=表单） */
  "text": string
}
  /** Arguments passed to the `template-capture` command */
  export type TemplateCapture = {
  /** 模板名（留空=选择） */
  "name": string
}
  /** Arguments passed to the `clip-selection` command */
  export type ClipSelection = {
  /** 批注 / #标签 / @文件夹（可选） */
  "note": string
}
  /** Arguments passed to the `notes` command */
  export type Notes = {
  /** 搜索笔记…（昨天 / 日记 / 档案 名字） */
  "query": string
}
  /** Arguments passed to the `manage-todos` command */
  export type ManageTodos = {
  /** 快速添加待办…（留空=打开列表） */
  "text": string
}
  /** Arguments passed to the `todos-menu` command */
  export type TodosMenu = {}
  /** Arguments passed to the `save-files` command */
  export type SaveFiles = {}
}

