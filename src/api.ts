import { getPreferenceValues } from "@raycast/api";

const MCP_ENDPOINT = "https://api.ideashell.cn/ideashell/mcp";

interface Preferences {
  apiKey: string;
  dailyNoteFolder: string;
  dailyNoteTitleFormat: string;
  defaultTags: string;
}

export function getPrefs(): Preferences {
  return getPreferenceValues<Preferences>();
}

interface McpToolCallRequest {
  jsonrpc: "2.0";
  id: number;
  method: "tools/call";
  params: {
    name: string;
    arguments: Record<string, unknown>;
  };
}

interface McpToolListRequest {
  jsonrpc: "2.0";
  id: number;
  method: "tools/list";
}

interface McpResponse {
  jsonrpc: "2.0";
  id: number;
  result?: {
    content?: Array<{ type: string; text?: string }>;
    tools?: Array<{
      name: string;
      description: string;
      inputSchema: Record<string, unknown>;
    }>;
    isError?: boolean;
  };
  error?: {
    code: number;
    message: string;
  };
}

let requestId = 0;
let sessionId: string | null = null;
let initPromise: Promise<void> | null = null;

async function mcpRequest(body: McpToolCallRequest | McpToolListRequest): Promise<McpResponse> {
  const { apiKey } = getPrefs();

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${apiKey}`,
  };

  if (sessionId) {
    headers["Mcp-Session-Id"] = sessionId;
  }

  const res = await fetch(MCP_ENDPOINT, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`MCP request failed (${res.status}): ${text}`);
  }

  // Track session ID from response
  const newSessionId = res.headers.get("mcp-session-id");
  if (newSessionId) {
    sessionId = newSessionId;
  }

  const contentType = res.headers.get("content-type") || "";

  if (contentType.includes("text/event-stream")) {
    // Parse SSE response — extract the last JSON-RPC message
    const sseText = await res.text();
    const lines = sseText.split("\n");
    let lastData = "";
    for (const line of lines) {
      if (line.startsWith("data: ")) {
        lastData = line.slice(6);
      }
    }
    if (!lastData) {
      throw new Error("No data in SSE response");
    }
    const data = JSON.parse(lastData) as McpResponse;
    if (data.error) {
      throw new Error(`MCP error ${data.error.code}: ${data.error.message}`);
    }
    return data;
  }

  const data = (await res.json()) as McpResponse;

  if (data.error) {
    throw new Error(`MCP error ${data.error.code}: ${data.error.message}`);
  }

  return data;
}

/** 握手只做一次；并发调用共享同一个 Promise（warmUp 与真正的调用不会各握手一次） */
function ensureInitialized(): Promise<void> {
  if (!initPromise) {
    initPromise = doInitialize().catch((e) => {
      initPromise = null;
      throw e;
    });
  }
  return initPromise;
}

async function doInitialize(): Promise<void> {
  const initBody = {
    jsonrpc: "2.0" as const,
    id: ++requestId,
    method: "initialize" as const,
    params: {
      protocolVersion: "2025-03-26",
      capabilities: {},
      clientInfo: { name: "tinycast-ideashell", version: "1.0.0" },
    },
  };

  const { apiKey } = getPrefs();
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${apiKey}`,
  };

  const res = await fetch(MCP_ENDPOINT, {
    method: "POST",
    headers,
    body: JSON.stringify(initBody),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`MCP initialize failed (${res.status}): ${text}`);
  }

  const newSessionId = res.headers.get("mcp-session-id");
  if (newSessionId) {
    sessionId = newSessionId;
  }

  // Parse response (may be SSE or JSON)
  const contentType = res.headers.get("content-type") || "";
  if (contentType.includes("text/event-stream")) {
    const sseText = await res.text();
    // Just consume it; we only need the session ID
    const lines = sseText.split("\n");
    for (const line of lines) {
      if (line.startsWith("data: ")) {
        try {
          const data = JSON.parse(line.slice(6));
          if (data.error) {
            throw new Error(`MCP init error: ${data.error.message}`);
          }
        } catch {
          // ignore parse errors in SSE
        }
      }
    }
  } else {
    await res.json(); // consume
  }

  // Send initialized notification
  const notifyHeaders: Record<string, string> = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${apiKey}`,
  };
  if (sessionId) {
    notifyHeaders["Mcp-Session-Id"] = sessionId;
  }

  // 服务端不要求等这条通知返回，发出去即可，省一次往返
  void fetch(MCP_ENDPOINT, {
    method: "POST",
    headers: notifyHeaders,
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
    }),
  }).catch(() => {});
}

/** 提前完成 MCP 握手（initialize + initialized 通知，约 2 次往返），保存时就不用再等；失败会静默，真正调用时再报错 */
export function warmUp(): void {
  ensureInitialized().catch(() => {});
}

/** Low-level tool call that returns the raw text result */
export async function callToolRaw(name: string, args: Record<string, unknown>): Promise<string> {
  const resp = await callTool(name, args);
  return extractText(resp);
}

async function callTool(name: string, args: Record<string, unknown>): Promise<McpResponse> {
  await ensureInitialized();
  return mcpRequest({
    jsonrpc: "2.0",
    id: ++requestId,
    method: "tools/call",
    params: { name, arguments: args },
  });
}

function extractText(resp: McpResponse): string {
  if (!resp.result?.content) return "";
  return resp.result.content
    .filter((c) => c.type === "text" && c.text)
    .map((c) => c.text!)
    .join("\n");
}

function parseJsonResult<T>(resp: McpResponse): T {
  const text = extractText(resp);
  return JSON.parse(text) as T;
}

// ── Note interfaces ──

export interface NoteInfo {
  id: string;
  note_id?: string;
  title: string;
  summary?: string;
  tags?: string[];
  folder?: string;
  folder_id?: string;
  createdAt?: string;
  updatedAt?: string;
  created_at?: string;
  updated_at?: string;
  /** 接口返回的原始文本块（note_search 含完整正文），仅解析自文本时有值 */
  text?: string;
}

export interface NoteDetail extends NoteInfo {
  body?: string;
  content?: string;
}

export interface FolderInfo {
  id: string;
  folder_id?: string;
  name: string;
  emoji?: string;
}

/** Get the effective ID from a note (handles both id and note_id fields) */
export function getNoteId(note: NoteInfo): string {
  return note.note_id || note.id || "";
}

// ── Public API ──

/** 附件：data 为 base64，name 含扩展名 */
export interface NoteAttachment {
  data: string;
  name: string;
}

/** 标签名里不能有空白，否则 App 会把它拆成多个 */
export function cleanTag(tag: string): string {
  return tag.replace(/^#+/, "").replace(/[\s#]+/g, "");
}

/** 在正文末尾追加一行 `#标签1 #标签2`（已在正文里出现的标签不重复追加） */
export function withInlineTags(body: string, tags: string[]): string {
  const clean = [...new Set(tags.map(cleanTag).filter(Boolean))];
  const missing = clean.filter(
    (t) => !new RegExp(`(^|\\s)#${t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?=\\s|$)`).test(body),
  );
  if (missing.length === 0) return body;
  const line = missing.map((t) => `#${t}`).join(" ");
  return body.trim() ? `${body.replace(/\s+$/, "")}\n\n${line}` : line;
}

export async function createNote(opts: {
  title: string;
  body?: string;
  summary?: string;
  tags?: string[];
  folder?: string;
  source?: string;
  images?: NoteAttachment[];
  audios?: NoteAttachment[];
  documents?: NoteAttachment[];
  /** 把标签以 `#标签` 写进正文末尾（闪念贝壳 App 只识别正文里的行内标签），默认开启 */
  inlineTags?: boolean;
}): Promise<string> {
  const args: Record<string, unknown> = { title: opts.title };
  const content = opts.inlineTags === false ? opts.body : withInlineTags(opts.body ?? "", opts.tags ?? []);
  if (content) args.content = content;
  if (opts.summary) args.summary = opts.summary;
  if (opts.tags && opts.tags.length > 0) args.tags = opts.tags;
  if (opts.folder) args.folder_id = opts.folder;
  if (opts.source) args.source = opts.source;
  if (opts.images?.length) args.images = opts.images;
  if (opts.audios?.length) args.audios = opts.audios;
  if (opts.documents?.length) args.documents = opts.documents;

  const resp = await callTool("note_create", args);
  if (resp.result?.isError) {
    const errMsg = extractText(resp);
    throw new Error(errMsg || "note_create failed");
  }
  return extractText(resp);
}

export async function updateNote(opts: {
  noteId: string;
  title?: string;
  body?: string;
  summary?: string;
  tags?: string[];
}): Promise<string> {
  const args: Record<string, unknown> = { note_id: opts.noteId };
  if (opts.title !== undefined) args.title = opts.title;
  if (opts.body !== undefined) args.content = opts.body;
  if (opts.summary !== undefined) args.summary = opts.summary;
  if (opts.tags !== undefined) args.tags = opts.tags;

  const resp = await callTool("note_update", args);
  if (resp.result?.isError) {
    const errMsg = extractText(resp);
    throw new Error(errMsg || "note_update failed");
  }
  return extractText(resp);
}

export async function searchNotes(query: string, limit = 15): Promise<NoteInfo[]> {
  const resp = await callTool("note_search", {
    query,
    limit: Math.min(Math.max(limit, 1), 20),
  });
  const text = extractText(resp);
  if (!text) return [];
  return parseNotesFromText(text);
}

/** 最近的笔记（按创建时间倒序）。接口 limit 范围 1-20。 */
export async function getRecentNotes(opts?: {
  limit?: number;
  startTime?: string;
  endTime?: string;
}): Promise<NoteInfo[]> {
  const args: Record<string, unknown> = {};
  if (opts?.limit) args.limit = Math.min(Math.max(opts.limit, 1), 20);
  if (opts?.startTime) args.start_time = opts.startTime;
  if (opts?.endTime) args.end_time = opts.endTime;
  const resp = await callTool("recent_notes", args);
  const text = extractText(resp);
  if (!text) return [];
  return parseNotesFromText(text);
}

/**
 * 取出 [start, end) 时间段内创建的全部笔记。
 * recent_notes 单次最多 20 条，但会返回区间总数（"Total notes in this time range: N"），
 * 超过 20 条时把区间对半拆分递归拉取，直到每段都取全（最小粒度 1 小时）。
 */
export async function getNotesInRange(start: Date, end: Date): Promise<{ notes: NoteInfo[]; truncated: boolean }> {
  const HOUR = 3600 * 1000;
  let truncated = false;

  async function walk(s: number, e: number): Promise<NoteInfo[]> {
    const resp = await callTool("recent_notes", {
      start_time: new Date(s).toISOString(),
      end_time: new Date(e).toISOString(),
      limit: 20,
    });
    const text = extractText(resp);
    const notes = text ? parseNotesFromText(text) : [];
    const total = Number(text.match(/Total notes[^:]*:\s*(\d+)/i)?.[1] ?? notes.length);

    if (total <= notes.length) return notes;
    if (e - s <= HOUR) {
      truncated = true;
      return notes;
    }
    const mid = Math.floor((s + e) / 2);
    const [a, b] = await Promise.all([walk(s, mid), walk(mid, e)]);
    return [...a, ...b];
  }

  const all = await walk(start.getTime(), end.getTime());
  const seen = new Set<string>();
  const unique = all.filter((n) => {
    const id = n.note_id || n.id;
    if (!id || seen.has(id)) return false;
    seen.add(id);
    return true;
  });
  unique.sort((a, b) => (b.created_at || "").localeCompare(a.created_at || ""));
  return { notes: unique, truncated };
}

/** 列出某个文件夹中的笔记（folder_notes），返回格式: "- 标题 [note_id: xxx]" */
export async function getNotesByFolder(folderId: string): Promise<NoteInfo[]> {
  const resp = await callTool("folder_notes", { folder_id: folderId });
  if (resp.result?.isError) {
    throw new Error(extractText(resp) || "folder_notes failed");
  }
  const text = extractText(resp);
  if (!text) return [];

  const notes: NoteInfo[] = [];
  const regex = /^-\s+(.+?)\s*\[note_id:\s*([a-f0-9]+)\]\s*$/gm;
  let m;
  while ((m = regex.exec(text)) !== null) {
    notes.push({
      id: m[2],
      note_id: m[2],
      title: m[1].trim(),
      folder_id: folderId,
    });
  }
  return notes;
}

/**
 * Parse notes from the plain-text format returned by note_search / recent_notes.
 * - note_search : "# Title\nnote_id: xxx\ntime: ...\nsummary: ..."
 * - recent_notes: "# Title @ 2026-10-08T03:37:43.156Z\nnote_id: xxx\n<summary or preview>"
 */
function parseNotesFromText(text: string): NoteInfo[] {
  const headerRe = /^# (.+)\nnote_id:\s*([a-f0-9]+)/gm;
  const heads = [...text.matchAll(headerRe)];
  const notes: NoteInfo[] = [];

  heads.forEach((m, i) => {
    const start = m.index ?? 0;
    const end = i + 1 < heads.length ? (heads[i + 1].index ?? text.length) : text.length;
    const block = text.slice(start, end);

    let title = m[1].trim();
    let time: string | undefined;
    const titleTime = title.match(/^(.*?)\s@\s(\d{4}-\d{2}-\d{2}T\S+)$/);
    if (titleTime) {
      title = titleTime[1].trim();
      time = titleTime[2];
    }
    if (!time) time = block.match(/^time:\s*(\S+)/m)?.[1];

    const tagsLine = block.match(/^tags:\s*(.+)$/m)?.[1];
    let summary: string | undefined = block.match(/^summary:\s*(.+)$/m)?.[1];
    if (!summary) {
      // recent_notes：note_id 之后直接跟摘要文本（没有 "summary:" 前缀）
      const after = block.slice(block.indexOf("\n", block.indexOf("note_id:")) + 1);
      summary = after
        .split("\n")
        .map((l) => l.trim())
        .filter((l) => l && !/^(time|tags|summary):/i.test(l) && !l.startsWith("#"))
        .join(" ");
    }
    // 纯语音笔记没有文字摘要，接口返回的是占位文案，不当作摘要
    if (!summary || /^\[No text content\]/i.test(summary)) summary = undefined;

    notes.push({
      id: m[2],
      note_id: m[2],
      title: title || "无标题",
      summary,
      tags: tagsLine
        ? tagsLine
            .split(",")
            .map((t) => t.trim())
            .filter(Boolean)
        : undefined,
      created_at: time,
      text: block,
    });
  });

  return notes;
}

// ── 说话人 ──

export interface Speaker {
  id: string;
  name: string;
  self?: boolean;
}

export async function listSpeakers(): Promise<Speaker[]> {
  const resp = await callTool("speaker_list", {});
  if (resp.result?.isError) return [];
  try {
    const data = JSON.parse(extractText(resp));
    return Array.isArray(data) ? (data as Speaker[]) : [];
  } catch {
    return [];
  }
}

/** 说话人出现过的笔记（录音转写里有此人发言），按时间倒序 */
export async function searchBySpeaker(speakerIds: string[], limit = 20): Promise<NoteInfo[]> {
  const resp = await callTool("search_by_speaker", {
    speaker_ids: speakerIds,
    limit: Math.min(Math.max(limit, 1), 20),
  });
  if (resp.result?.isError) return [];
  return parseNotesFromText(extractText(resp));
}

export async function getNoteDetail(noteId: string): Promise<NoteDetail> {
  const resp = await callTool("note_detail", {
    note_id: noteId,
    scope: "full",
  });
  const text = extractText(resp);

  // note_detail returns plain text, not JSON. Parse what we can.
  const titleMatch = text.match(/^#\s+(.+)/m);
  const noteIdMatch = text.match(/^note_id:\s*([a-f0-9]+)/im);
  const timeMatch = text.match(/^time:\s*(\S+)/im);
  const tagsMatch = text.match(/^tags:\s*(.+)$/im);
  const summaryMatch = text.match(/^summary:\s*(.+)$/im);

  // Extract content from ## Memos section
  const memosIdx = text.indexOf("## Memos");
  let content = "";
  if (memosIdx !== -1) {
    const memosText = text.slice(memosIdx + 8).trim();
    // Get content after the first memo header line "**Memo N: ...**\n"
    const memoContentMatch = memosText.match(/\*\*Memo \d+:.*?\*\*\n?([\s\S]*)/);
    if (memoContentMatch) {
      content = memoContentMatch[1]
        // note_search/note_detail 会在 memo 开头重复一行 summary，去掉
        .replace(/^summary:.*\n?/i, "")
        .trim();
    }
  }

  return {
    id: noteIdMatch ? noteIdMatch[1] : noteId,
    note_id: noteIdMatch ? noteIdMatch[1] : noteId,
    title: titleMatch ? titleMatch[1] : "",
    summary: summaryMatch ? summaryMatch[1] : undefined,
    tags: tagsMatch
      ? tagsMatch[1]
          .split(",")
          .map((t) => t.trim())
          .filter(Boolean)
      : undefined,
    created_at: timeMatch ? timeMatch[1] : undefined,
    content,
    body: content,
    text,
  };
}

export async function listFolders(): Promise<FolderInfo[]> {
  const resp = await callTool("folder_list", {});
  const text = extractText(resp);
  if (!text) return [];

  // Parse plain text format: "- 📁 FolderName [folder_id: xxx]"
  const folders: FolderInfo[] = [];
  const regex = /-\s*(\S*)\s*(.+?)\s*\[folder_id:\s*([a-f0-9]+)\]/gi;
  let m;
  while ((m = regex.exec(text)) !== null) {
    folders.push({
      id: m[3],
      folder_id: m[3],
      emoji: m[1] || undefined,
      name: m[2].trim(),
    });
  }
  return folders;
}

export async function createFolder(name: string): Promise<string> {
  const resp = await callTool("folder_create", { name });
  return extractText(resp);
}

// ── Todo API ──

export interface TodoItem {
  id: string;
  content: string;
  date: string | null;
  time: string | null;
  is_completed: boolean;
}

function parseTodos(text: string): TodoItem[] {
  if (!text.trim()) return [];
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    // 例如 "No todos found."
    return [];
  }
  const list = Array.isArray(data)
    ? data
    : ((data as { todos?: unknown; updated?: unknown })?.todos ?? (data as { updated?: unknown })?.updated);
  return Array.isArray(list) ? (list as TodoItem[]) : [];
}

export async function listTodos(opts?: {
  isCompleted?: boolean;
  dateFrom?: string;
  dateTo?: string;
  keyword?: string;
  limit?: number;
}): Promise<TodoItem[]> {
  const args: Record<string, unknown> = { timezone: localTimezone() };
  if (opts?.isCompleted !== undefined) args.is_completed = opts.isCompleted;
  if (opts?.dateFrom) args.date_from = opts.dateFrom;
  if (opts?.dateTo) args.date_to = opts.dateTo;
  if (opts?.keyword) args.keyword = opts.keyword;
  args.limit = Math.min(Math.max(opts?.limit ?? 100, 1), 200);

  const resp = await callTool("todo_list", args);
  if (resp.result?.isError) throw new Error(extractText(resp) || "todo_list failed");
  return parseTodos(extractText(resp));
}

export async function createTodos(
  items: Array<{ content: string; date?: string; time?: string }>,
): Promise<TodoItem[]> {
  const resp = await callTool("todo_create", {
    items,
    timezone: localTimezone(),
  });
  if (resp.result?.isError) throw new Error(extractText(resp) || "todo_create failed");
  return parseTodos(extractText(resp));
}

export async function updateTodos(
  items: Array<{
    todo_id: string;
    content?: string;
    date?: string;
    time?: string;
    is_completed?: boolean;
  }>,
): Promise<TodoItem[]> {
  const resp = await callTool("todo_update", {
    items,
    timezone: localTimezone(),
  });
  if (resp.result?.isError) throw new Error(extractText(resp) || "todo_update failed");
  return parseTodos(extractText(resp));
}

function localTimezone(): string | undefined {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || undefined;
  } catch {
    return undefined;
  }
}
