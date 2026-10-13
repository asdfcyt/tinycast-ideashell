package com.carpe.ideashell.ui.revisit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelProvider.AndroidViewModelFactory.Companion.APPLICATION_KEY
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.carpe.ideashell.AppContainer
import com.carpe.ideashell.IdeashellApp
import com.carpe.ideashell.core.revisit.Fsrs
import com.carpe.ideashell.data.db.RevisitEntity
import com.carpe.ideashell.data.revisit.RevisitToday
import com.carpe.ideashell.data.revisit.ThoughtResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

/**
 * 重温页：一次只处理队列最前面的一条。队列本身就是「今天」的计算结果（按最该复习排序、按每日上限截断），
 * 每处理完一条，库里的状态一变，队列自然前进，所以这里不另存一份队列。
 */
class RevisitViewModel(container: AppContainer) : ViewModel() {
    private val repo = container.revisit

    val today: StateFlow<RevisitToday> = repo.today

    /** 刚处理完一条、库里的队列还没更新的短暂间隙里，挡住连点 */
    var busy by mutableStateOf(false)

    /** 上一步操作之前的状态；不为空时标题栏出现「撤销」 */
    var undoItems by mutableStateOf<List<RevisitEntity>>(emptyList())
        private set

    /** 「记一笔」正在保存（要联网读写笔记，可能要几秒）：期间不能再点 */
    var thoughtBusy by mutableStateOf(false)
        private set

    private val _messages = Channel<String>(Channel.BUFFERED)
    val messages: Flow<String> = _messages.receiveAsFlow()

    fun refresh() = repo.refreshDay()

    fun previewDays(item: RevisitEntity, rating: Fsrs.Rating): Int = repo.previewDays(item, rating)

    fun rate(item: RevisitEntity, rating: Fsrs.Rating) = act {
        undoItems = listOfNotNull(repo.rate(item.id, rating))
    }

    /** 今天跳过：明天再出现，不影响记忆曲线 */
    fun skipToday(item: RevisitEntity) = act {
        undoItems = listOfNotNull(repo.get(item.id))
        repo.skipToday(item.id)
    }

    /** 不再重温 */
    fun archive(item: RevisitEntity) = act {
        undoItems = listOfNotNull(repo.get(item.id))
        repo.archive(item.id)
        _messages.trySend("已不再重温这一条")
    }

    /**
     * 重温时记一笔新想法：Daily Note 里的一句会以它为底新建专题笔记，其他笔记追加到原笔记里（详见 [com.carpe.ideashell.data.revisit.RevisitRepository.addThought]）。
     * 失败时提示原因并回调 [onFailed]，由界面把输入还给用户。
     */
    fun addThought(item: RevisitEntity, text: String, onFailed: () -> Unit) {
        if (thoughtBusy) return
        thoughtBusy = true
        viewModelScope.launch {
            try {
                val result = repo.addThought(item.id, text)
                _messages.trySend(
                    when (result) {
                        is ThoughtResult.TopicCreated -> "已以这一条为底新建专题笔记「${result.title}」"
                        is ThoughtResult.TopicAppended -> "已追加到专题笔记"
                        is ThoughtResult.AppendedToSource -> "已记到原笔记的「想法」里"
                    },
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _messages.trySend("没能保存：${e.message ?: "网络异常"}（写的内容还在）")
                onFailed()
            } finally {
                thoughtBusy = false
            }
        }
    }

    /** 积压时的出口：把现在到期的全部推后 7 天 */
    fun postponeAll() {
        viewModelScope.launch {
            val before = repo.postponeAll(7)
            if (before.isEmpty()) {
                _messages.trySend("现在没有到期的内容")
            } else {
                undoItems = before
                _messages.trySend("已把到期的 ${before.size} 条推后 7 天")
            }
        }
    }

    fun undo() {
        val items = undoItems
        if (items.isEmpty()) return
        undoItems = emptyList()
        viewModelScope.launch { repo.restoreAll(items) }
    }

    private fun act(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        viewModelScope.launch {
            block()
            // 兜底：队列正常会在这之前就前进并解除；万一没变也不会一直点不动
            delay(700)
            busy = false
        }
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val app = this[APPLICATION_KEY] as IdeashellApp
                RevisitViewModel(app.container)
            }
        }
    }
}
