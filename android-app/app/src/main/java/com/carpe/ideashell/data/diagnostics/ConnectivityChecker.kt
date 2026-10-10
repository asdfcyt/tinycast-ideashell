package com.carpe.ideashell.data.diagnostics

import com.carpe.ideashell.data.mcp.McpClient
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** 要检查的服务，以及它需要具备的工具（取自桌面插件实际用到的接口） */
enum class McpTarget(
    val label: String,
    val requiredTools: List<String>,
    val probeTool: String,
) {
    IDEASHELL(
        label = "闪念贝壳",
        requiredTools = listOf(
            "note_create", "note_update", "note_detail", "note_search", "recent_notes",
            "folder_list", "todo_create", "todo_list", "todo_update",
        ),
        probeTool = "recent_notes",
    ),
    DIDA(
        label = "滴答清单",
        requiredTools = listOf(
            "list_projects", "list_undone_tasks_by_date", "create_task",
            "update_task", "complete_task", "get_task_by_id",
        ),
        probeTool = "list_projects",
    ),
}

data class StepResult(
    val title: String,
    val ok: Boolean,
    val detail: String,
    val millis: Long,
)

/** M0 连通性检查：握手 → 工具清单 → 一次只读的真实调用。每一步独立计时。 */
class ConnectivityChecker {

    suspend fun run(client: McpClient, target: McpTarget): List<StepResult> {
        val steps = mutableListOf<StepResult>()

        val handshake = step("握手") {
            client.reset()
            client.initialize()
            true to "成功 · 返回格式 ${client.lastTransport} · 会话 ${if (client.hasSession) "已建立" else "无（服务端未返回 Mcp-Session-Id）"}"
        }
        steps += handshake
        if (!handshake.ok) return steps

        val tools = step("工具清单") {
            val list = client.listTools()
            val names = list.map { it.name }.toSet()
            val missing = target.requiredTools.filterNot { it in names }
            if (list.isEmpty()) {
                false to "没有取到任何工具"
            } else if (missing.isEmpty()) {
                true to "共 ${list.size} 个工具，需要的 ${target.requiredTools.size} 个都在"
            } else {
                false to "共 ${list.size} 个工具，缺少：${missing.joinToString("、")}"
            }
        }
        steps += tools

        steps += step("只读调用 ${target.probeTool}") {
            val args = when (target) {
                McpTarget.IDEASHELL -> buildJsonObject { put("limit", 3) }
                McpTarget.DIDA -> buildJsonObject {}
            }
            val result = client.callTool(target.probeTool, args)
            val preview = result.text.replace('\n', ' ').take(PREVIEW_CHARS)
            val summary = "返回 ${result.text.length} 字 · 格式 ${client.lastTransport}"
            if (result.isError) {
                false to "服务端返回错误：$preview"
            } else {
                true to "$summary\n预览：$preview"
            }
        }
        return steps
    }

    private suspend fun step(title: String, block: suspend () -> Pair<Boolean, String>): StepResult {
        val start = System.nanoTime()
        return try {
            val (ok, detail) = block()
            StepResult(title, ok, detail, elapsedMs(start))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            StepResult(title, false, e.message ?: e::class.java.simpleName, elapsedMs(start))
        }
    }

    private fun elapsedMs(startNanos: Long) = (System.nanoTime() - startNanos) / 1_000_000

    private companion object {
        const val PREVIEW_CHARS = 160
    }
}
