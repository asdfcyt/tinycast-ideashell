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

async function mcpRequest(body: McpToolCallRequest | McpToolListRequest): Promise<McpResponse> {
  const { apiKey } = getPrefs();

  const res = await fetch(MCP_ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`MCP request failed (${res.status}): ${text}`);
  }

  const data = (await res.json()) as McpResponse;

  if (data.error) {
    throw new Error(`MCP error ${data.error.code}: ${data.error.message}`);
  }

  return data;
}

function callTool(name: string, args: Record<string, unknown>): Promise<McpResponse> {
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
