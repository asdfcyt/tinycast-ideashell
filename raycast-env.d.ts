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
  "defaultTags": string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `smart-capture` command */
  export type SmartCapture = ExtensionPreferences & {}
  /** Preferences accessible in the `notes` command */
  export type Notes = ExtensionPreferences & {}
  /** Preferences accessible in the `manage-todos` command */
  export type ManageTodos = ExtensionPreferences & {}
  /** Preferences accessible in the `save-files` command */
  export type SaveFiles = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `smart-capture` command */
  export type SmartCapture = {
  /** 记点什么…（留空=剪贴板） */
  "text": string,
  /** 类型 */
  "type": "auto" | "todo" | "daily" | "note" | "clipboard",
  /** 标签/文件夹：#标签 @文件夹（留空=智能） */
  "extra": string
}
  /** Arguments passed to the `notes` command */
  export type Notes = {}
  /** Arguments passed to the `manage-todos` command */
  export type ManageTodos = {}
  /** Arguments passed to the `save-files` command */
  export type SaveFiles = {}
}

