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
  title: string;
  summary?: string;
  tags?: string[];
  folder?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface NoteDetail extends NoteInfo {
  body?: string;
}

export interface FolderInfo {
  id: string;
  name: string;
  emoji?: string;
}

// ── Public API ──

export async function createNote(opts: {
  title: string;
  body: string;
  summary?: string;
  tags?: string[];
  folder?: string;
}): Promise<string> {
  const args: Record<string, unknown> = {
    title: opts.title,
    body: opts.body,
  };
  if (opts.summary) args.summary = opts.summary;
  if (opts.tags && opts.tags.length > 0) args.tags = opts.tags;
  if (opts.folder) args.folder = opts.folder;

  const resp = await callTool("note_create", args);
  const text = extractText(resp);
  return text;
}

export async function updateNote(opts: {
  id: string;
  title?: string;
  body?: string;
  summary?: string;
  tags?: string[];
}): Promise<string> {
  const args: Record<string, unknown> = { id: opts.id };
  if (opts.title !== undefined) args.title = opts.title;
  if (opts.body !== undefined) args.body = opts.body;
  if (opts.summary !== undefined) args.summary = opts.summary;
  if (opts.tags !== undefined) args.tags = opts.tags;

  const resp = await callTool("note_update", args);
  return extractText(resp);
}

export async function searchNotes(query: string): Promise<NoteInfo[]> {
  const resp = await callTool("note_search", { query });
  try {
    return parseJsonResult<NoteInfo[]>(resp);
  } catch {
    const text = extractText(resp);
    if (!text) return [];
    return [{ id: "", title: text }];
  }
}

export async function getRecentNotes(opts?: { days?: number }): Promise<NoteInfo[]> {
  const args: Record<string, unknown> = {};
  if (opts?.days) args.days = opts.days;
  const resp = await callTool("recent_notes", args);
  try {
    return parseJsonResult<NoteInfo[]>(resp);
  } catch {
    return [];
  }
}

export async function getNoteDetail(id: string): Promise<NoteDetail> {
  const resp = await callTool("note_detail", { id });
  return parseJsonResult<NoteDetail>(resp);
}

export async function listFolders(): Promise<FolderInfo[]> {
  const resp = await callTool("folder_list", {});
  try {
    return parseJsonResult<FolderInfo[]>(resp);
  } catch {
    return [];
  }
}

export async function createFolder(name: string): Promise<string> {
  const resp = await callTool("folder_create", { name });
  return extractText(resp);
}

export async function listTodos(opts?: { completed?: boolean }): Promise<unknown[]> {
  const args: Record<string, unknown> = {};
  if (opts?.completed !== undefined) args.completed = opts.completed;
  const resp = await callTool("todo_list", args);
  try {
    return parseJsonResult<unknown[]>(resp);
  } catch {
    return [];
  }
}
