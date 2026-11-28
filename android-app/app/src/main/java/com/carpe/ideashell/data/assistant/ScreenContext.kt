package com.carpe.ideashell.data.assistant

import com.carpe.ideashell.system.ExcerptService

/**
 * 「用户现在在看什么」：助手要读屏幕时才取，不会提前上传。
 * 来源按顺序：
 * ① 设为默认助手后，系统呼出助手时交过来的快照 / 开始说话那一刻抓的快照（[offer] / [snapshotNow]，90 秒内有效）；
 * ② 用无障碍服务现读当前窗口的文字（和摘录共用同一个无障碍开关）；
 * ③ 页面读不到文字（阅读类应用常把正文画在自绘控件里）：截屏后用文字识别（OCR）读出来。
 * 截图只放在内存里，识别完就丢；银行 / 支付类应用、拾忆自己的界面都不读。
 */
object ScreenContext {
    class Snapshot(val at: Long, val pkg: String, val label: String, val text: String, val selection: String? = null)

    const val MAX_CHARS = 6000
    private const val FRESH_MS = 90_000L
    private const val ASK_CHARS = 2400

    /** 无障碍读到的文字少于这个数，就怀疑正文是图片 / 自绘内容（工具栏、标题之类的文字可能凑出几十个字），再截屏做文字识别比一比 */
    private const val ENOUGH = 300

    @Volatile
    private var offered: Snapshot? = null

    /** 开始说话时抓的截图（只在页面文字读不到时才抓） */
    private class Shot(val at: Long, val jpeg: ByteArray, val pkg: String)

    @Volatile
    private var shot: Shot? = null

    /** 最近一次读不到屏幕的原因（给助手回答、给用户看） */
    @Volatile
    var lastFailure: String = ""
        private set

    fun offer(pkg: String, label: String, text: String, selection: String? = null) {
        offered = Snapshot(System.currentTimeMillis(), pkg, label, text.take(MAX_CHARS), selection)
    }

    /**
     * 开始说话那一刻抓一份当前屏幕（后台线程调用）：说完再读的话，用户可能已经切走，或者点进了拾忆自己的确认卡片。
     * 文字读得到就只存文字；读不到正文再补一张截图（识别要等真正用到时才做）。刚由系统助手入口交过来的快照（几秒内）不覆盖。
     */
    suspend fun snapshotNow() {
        val o = offered
        if (o != null && System.currentTimeMillis() - o.at < 5_000L) return
        val svc = ExcerptService.instance ?: return
        val live = svc.readScreen()
        if (live != null) offered = live
        if ((live?.text?.length ?: 0) < ENOUGH) {
            val jpeg = svc.screenshotJpeg()
            if (jpeg != null) shot = Shot(System.currentTimeMillis(), jpeg, live?.pkg.orEmpty())
        }
    }

    /**
     * 读取当前屏幕；读不到返回 null（原因在 [lastFailure]）。
     * [ocr]：把截图识别成文字（页面没有可读文字时才会调用）。
     */
    suspend fun read(ocr: suspend (ByteArray) -> String): Snapshot? {
        val now = System.currentTimeMillis()
        val cached = offered?.takeIf { now - it.at < FRESH_MS }
        if (cached != null && cached.text.length >= ENOUGH) return cached
        val svc = ExcerptService.instance
        if (svc == null && cached == null) {
            lastFailure = "没有开启无障碍服务（设置 → 语音助手 → 系统权限 → 无障碍服务）"
            return null
        }
        val live = svc?.readScreen()
        val best = listOfNotNull(cached, live).maxByOrNull { it.text.length }
        if (best != null && best.text.length >= ENOUGH) return best
        // 页面上读到的文字不多（甚至没有）：正文多半是图片 / 自绘内容。用开始说话时抓的截图（或现在截一张）做文字识别，谁的字多用谁
        val img = shot?.takeIf { now - it.at < FRESH_MS }
        val jpeg = img?.jpeg ?: svc?.screenshotJpeg()
        shot = null
        if (jpeg != null) {
            val text = try {
                ocr(jpeg).trim()
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                lastFailure = "截图识别失败：" + (e.message ?: e.javaClass.simpleName)
                ""
            }
            if (text.length >= 8 && text.length > (best?.text?.length ?: 0) + 20) {
                val label = best?.label ?: "当前屏幕"
                return Snapshot(System.currentTimeMillis(), best?.pkg ?: img?.pkg.orEmpty(), label, text.take(MAX_CHARS), best?.selection ?: live?.selection)
            }
            if (best == null) lastFailure = "截图里没有识别出文字（页面可能是纯图片 / 空白）"
        } else if (best == null) {
            lastFailure = svc?.lastReadFailure?.takeIf { it.isNotBlank() } ?: "读不到当前页面"
        }
        return best
    }

    private val REFERS = Regex("这页|这一页|本页|这段|这一段|这篇|这个页面|这个界面|当前页面|当前界面|屏幕|这里写|书中|文中|页面上|上面(写|说)|选中|这句|这张图|这本书|上文|下文|这一章|这章|这部分")

    /** 这句话是不是在说「眼前这页」 */
    fun refersToScreen(question: String): Boolean = REFERS.containsMatchIn(question)

    /**
     * 要把问题转给别的 AI（闪念贝壳）时：说到了「这页 / 这段」，就把当时屏幕上的文字（有选中的优先）一起带上，
     * 否则对面的 AI 根本不知道「这页内容」是什么。没提到屏幕、或读不到屏幕时原样返回。
     */
    suspend fun attachTo(question: String, ocr: suspend (ByteArray) -> String): String {
        if (!refersToScreen(question)) return question
        val snap = read(ocr) ?: return question
        val body = StringBuilder()
        snap.selection?.takeIf { it.isNotBlank() }?.let { body.append("【我选中的文字】\n").append(it.take(ASK_CHARS)).append("\n\n") }
        val left = (ASK_CHARS - body.length).coerceAtLeast(600)
        val page = snap.text.trim()
        body.append("【屏幕上的内容（来自「${snap.label}」）】\n").append(page.take(left))
        if (page.length > left) body.append("\n……（内容较长，已截取前 $left 字）")
        return question.trim() + "\n\n" + body
    }
}
