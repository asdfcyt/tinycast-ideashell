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
    tools?: Array<{ name: string; description: string; inputSchema: Record<string, unknown> }>;
    isError?: boolean;
  };
  error?: {
    code: number;
    message: string;
  };
}

let requestId = 0;
let sessionId: string | null = null;
let initialized = false;

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

async function ensureInitialized(): Promise<void> {
  if (initialized) return;

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

  await fetch(MCP_ENDPOINT, {
    method: "POST",
    headers: notifyHeaders,
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
    }),
  }).catch(() => {});

  initialized = true;
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

export async function createNote(opts: {
  title: string;
  body: string;
  summary?: string;
  tags?: string[];
  folder?: string;
  source?: string;
}): Promise<string> {
  const args: Record<string, unknown> = {
    title: opts.title,
    content: opts.body,
  };
  if (opts.summary) args.summary = opts.summary;
  if (opts.tags && opts.tags.length > 0) args.tags = opts.tags;
  if (opts.folder) args.folder_id = opts.folder;
  if (opts.source) args.source = opts.source;

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

export async function searchNotes(query: string): Promise<NoteInfo[]> {
  const resp = await callTool("note_search", { query });
  const text = extractText(resp);
  if (!text) return [];
  return parseNotesFromText(text);
}

export async function getRecentNotes(opts?: { limit?: number }): Promise<NoteInfo[]> {
  const args: Record<string, unknown> = {};
  if (opts?.limit) args.limit = opts.limit;
  const resp = await callTool("recent_notes", args);
  const text = extractText(resp);
  if (!text) return [];
  return parseNotesFromText(text);
}

/** Parse notes from the plain-text format returned by note_search / recent_notes */
function parseNotesFromText(text: string): NoteInfo[] {
  // Format: "# Title\nnote_id: xxx\ntime: ...\nsummary: ...\n..."
  // Multiple notes separated by "---"
  const blocks = text.split(/\n---\n/);
  const notes: NoteInfo[] = [];

  for (const block of blocks) {
    const titleMatch = block.match(/^#\s+(.+)/m);
    const idMatch = block.match(/note_id:\s*([a-f0-9]+)/i);
    const summaryMatch = block.match(/summary:\s*(.+)/i);
    const tagsMatch = block.match(/tags:\s*(.+)/i);
    const timeMatch = block.match(/time:\s*(\S+)/i);

    if (titleMatch || idMatch) {
      notes.push({
        id: idMatch ? idMatch[1] : "",
        note_id: idMatch ? idMatch[1] : "",
        title: titleMatch ? titleMatch[1] : "无标题",
        summary: summaryMatch ? summaryMatch[1] : undefined,
        tags: tagsMatch ? tagsMatch[1].split(",").map((t) => t.trim()) : undefined,
        created_at: timeMatch ? timeMatch[1] : undefined,
      });
    }
  }

  return notes;
}

export async function getNoteDetail(noteId: string): Promise<NoteDetail> {
  const resp = await callTool("note_detail", { note_id: noteId, scope: "full" });
  const text = extractText(resp);

  // note_detail returns plain text, not JSON. Parse what we can.
  const titleMatch = text.match(/^#\s+(.+)/m);
  const noteIdMatch = text.match(/note_id:\s*([a-f0-9]+)/i);
  const tagsMatch = text.match(/tags:\s*(.+)/i);
  const summaryMatch = text.match(/summary:\s*(.+)/i);

  // Extract content from ## Memos section
  const memosIdx = text.indexOf("## Memos");
  let content = "";
  if (memosIdx !== -1) {
    const memosText = text.slice(memosIdx + 8).trim();
    // Get content after the first memo header line "**Memo N: ...**\n"
    const memoContentMatch = memosText.match(/\*\*Memo \d+:.*?\*\*\n?([\s\S]*)/);
    if (memoContentMatch) {
      content = memoContentMatch[1].trim();
    }
  }

  return {
    id: noteIdMatch ? noteIdMatch[1] : noteId,
    note_id: noteIdMatch ? noteIdMatch[1] : noteId,
    title: titleMatch ? titleMatch[1] : "",
    summary: summaryMatch ? summaryMatch[1] : undefined,
    tags: tagsMatch ? tagsMatch[1].split(",").map((t) => t.trim()) : undefined,
    content,
    body: content,
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
