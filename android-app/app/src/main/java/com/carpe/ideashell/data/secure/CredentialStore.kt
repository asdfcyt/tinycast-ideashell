package com.carpe.ideashell.data.secure

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

/** 两个服务的访问凭证：闪念贝壳 API Key、滴答清单 API 口令。只存本机（Keystore 加密）。 */
class CredentialStore(private val store: SecureStore) {
    private val cache = ConcurrentHashMap<String, String>()

    private val _ideashellConnected = MutableStateFlow(false)
    private val _didaConnected = MutableStateFlow(false)

    /** 是否已填写闪念贝壳 API Key（界面据此显示「去连接」） */
    val ideashellConnected: StateFlow<Boolean> = _ideashellConnected.asStateFlow()
    val didaConnected: StateFlow<Boolean> = _didaConnected.asStateFlow()

    init {
        _ideashellConnected.value = !ideashellKey.isNullOrBlank()
        _didaConnected.value = !didaToken.isNullOrBlank()
    }

    var ideashellKey: String?
        get() = read(KEY_IDEASHELL)
        set(value) {
            write(KEY_IDEASHELL, value)
            _ideashellConnected.value = !value.isNullOrBlank()
        }

    var didaToken: String?
        get() = read(KEY_DIDA)
        set(value) {
            write(KEY_DIDA, value)
            _didaConnected.value = !value.isNullOrBlank()
        }

    private fun read(key: String): String? {
        cache[key]?.let { return it }
        val value = store.get(key)
        if (value != null) cache[key] = value
        return value
    }

    private fun write(key: String, value: String?) {
        if (value.isNullOrBlank()) {
            cache.remove(key)
            store.remove(key)
        } else {
            val clean = value.trim().removePrefix("Bearer ").trim()
            cache[key] = clean
            store.put(key, clean)
        }
    }

    private companion object {
        const val KEY_IDEASHELL = "ideashell_api_key"
        const val KEY_DIDA = "dida_api_token"
    }
}
