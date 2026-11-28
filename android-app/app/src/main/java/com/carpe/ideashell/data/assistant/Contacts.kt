package com.carpe.ideashell.data.assistant

import android.content.Context
import android.provider.ContactsContract

/**
 * 按名字在通讯录里找人。语音识别常把名字听成同音字（「晓东」→「小东」）、带上多余的词（「张三的电话」），
 * 所以不用 SQL 的 LIKE，而是把联系人读出来在本地逐个打分：全名一致 > 包含 > 拼音一致 > 拼音包含 / 差一个字母 > 字符大部分相同。
 * 分数相同、又是不同的人时不乱猜，把候选告诉用户。
 */
object Contacts {
    sealed class Result {
        class Found(val name: String, val number: String) : Result()
        class Failed(val message: String) : Result()
    }

    private class Contact(val name: String, val number: String)

    private val NOISE_PREFIX = Regex("^(打电话给|打给|拨打|呼叫|联系|给)")
    private val NOISE_SUFFIX = Regex("(的)?(电话|号码|手机|手机号)$")

    /** 汉字转不带声调的拼音（系统自带的 ICU，没有就退化为只比汉字） */
    private val pinyin: ((String) -> String)? = runCatching {
        val t = android.icu.text.Transliterator.getInstance("Han-Latin; Latin-ASCII")
        val f: (String) -> String = { text -> t.transliterate(text).lowercase().filter { it.isLetterOrDigit() } }
        f
    }.getOrNull()

    fun find(context: Context, query: String): Result {
        val q = clean(query)
        if (q.isEmpty()) return Result.Failed("没有说要打给谁")
        val contacts = try {
            load(context)
        } catch (e: SecurityException) {
            return Result.Failed("通讯录读不了：没有权限，或被系统限制了（设置 → 语音助手 → 通讯录）")
        } catch (e: Exception) {
            return Result.Failed("通讯录读取失败：${e.message ?: e.javaClass.simpleName}")
        }
        if (contacts.isEmpty()) return Result.Failed("通讯录里没有读到任何带号码的联系人（权限已给的话，可能是系统限制了读取，或联系人存在别的账号里没显示）")

        val pq = pinyin?.invoke(q).orEmpty()
        val scored = contacts.map { it to score(clean(it.name), q, pq) }.filter { it.second > 0 }
        if (scored.isEmpty()) return Result.Failed("通讯录里没找到「$query」（共 ${contacts.size} 个联系人）")
        val best = scored.maxOf { it.second }
        val top = scored.filter { it.second == best }
        val names = top.map { it.first.name }.distinct()
        // 同一个人多个号码：取第一个；不同的人且不是完全一致：让用户说得更具体
        if (names.size > 1 && best < 100) {
            return Result.Failed("通讯录里有好几个像「$query」的：${names.take(4).joinToString("、")}，请说全名")
        }
        val pick = top.first().first
        return Result.Found(pick.name, pick.number)
    }

    private fun clean(text: String): String =
        text.trim().replace(Regex("\\s+"), "").lowercase().replace(NOISE_PREFIX, "").replace(NOISE_SUFFIX, "")

    private fun score(name: String, q: String, pq: String): Int {
        if (name.isEmpty()) return 0
        if (name == q) return 100
        if (name.contains(q)) return 90 - (name.length - q.length).coerceAtMost(20)
        if (name.length >= 2 && q.contains(name)) return 80
        val py = pinyin ?: return 0
        val pn = py(name)
        if (pn.isEmpty() || pq.isEmpty()) return 0
        if (pn == pq) return 70
        if (pq.length >= 4 && pn.contains(pq)) return 60
        if (pq.length >= 4 && pn.length >= 4 && editDistance(pn, pq) <= 1) return 50
        // 三个字以上的名字：有一个字听错也认（字符大部分相同）
        if (q.length >= 3 && name.length >= 3) {
            val common = q.count { it in name }
            if (common >= q.length - 1 && common >= name.length - 1) return 40
        }
        return 0
    }

    private fun editDistance(a: String, b: String): Int {
        var prev = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            val cur = IntArray(b.length + 1)
            cur[0] = i
            for (j in 1..b.length) {
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            }
            prev = cur
        }
        return prev[b.length]
    }

    /** 读出所有带号码的联系人（名字 + 号码，按名字排序；同名同号去重） */
    private fun load(context: Context): List<Contact> {
        val out = ArrayList<Contact>()
        val seen = HashSet<String>()
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.NUMBER),
            null,
            null,
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(0)?.trim().orEmpty()
                val number = c.getString(1)?.trim().orEmpty()
                if (name.isEmpty() || number.isEmpty()) continue
                if (seen.add(name + "|" + number.filter { it.isDigit() })) out += Contact(name, number)
            }
        }
        return out
    }
}
