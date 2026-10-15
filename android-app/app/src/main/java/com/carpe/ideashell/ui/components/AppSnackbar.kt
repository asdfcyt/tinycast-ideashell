package com.carpe.ideashell.ui.components

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.carpe.ideashell.ui.theme.Brand
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** 全 App 统一的底部提示条：圆角、悬浮；「撤销」之类的按钮用主题橙 */
@Composable
fun AppSnackbarHost(state: SnackbarHostState, modifier: Modifier = Modifier) {
    SnackbarHost(state, modifier) { data ->
        Snackbar(
            snackbarData = data,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            shape = RoundedCornerShape(20.dp),
            containerColor = MaterialTheme.colorScheme.inverseSurface,
            contentColor = MaterialTheme.colorScheme.inverseOnSurface,
            actionColor = Brand.Orange,
            dismissActionContentColor = MaterialTheme.colorScheme.inverseOnSurface,
        )
    }
}

/**
 * 显示一条（通常带「撤销」的）提示，[millis] 毫秒后自己收起。
 * 系统自带的 Short / Long 时长遇到无障碍服务（或带按钮时）可能一直不消失，所以自己计时。
 */
suspend fun SnackbarHostState.showTimed(
    message: String,
    actionLabel: String? = null,
    millis: Long = 3_000,
): SnackbarResult = coroutineScope {
    val timer = launch {
        delay(millis)
        currentSnackbarData?.dismiss()
    }
    val result = showSnackbar(message = message, actionLabel = actionLabel, withDismissAction = false, duration = SnackbarDuration.Indefinite)
    timer.cancel()
    result
}
