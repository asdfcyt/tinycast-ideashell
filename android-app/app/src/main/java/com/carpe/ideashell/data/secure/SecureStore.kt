package com.carpe.ideashell.data.secure

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 用 Android Keystore 里的 AES-256-GCM 密钥加密敏感字符串（API Key / 口令），
 * 密文存在普通 SharedPreferences 里。密钥本身不可导出，换机 / 重装后密文无法解密（读取时返回 null）。
 */
class SecureStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun put(key: String, value: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val packed = b64(cipher.iv) + SEPARATOR + b64(encrypted)
        prefs.edit().putString(key, packed).apply()
    }

    fun get(key: String): String? {
        val packed = prefs.getString(key, null) ?: return null
        return try {
            val (iv, data) = packed.split(SEPARATOR).let { it[0] to it[1] }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, unb64(iv)))
            String(cipher.doFinal(unb64(data)), Charsets.UTF_8)
        } catch (_: Exception) {
            // 密钥失效 / 数据损坏：当作没有保存，让用户重新填写
            null
        }
    }

    fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun b64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)
    private fun unb64(text: String): ByteArray = Base64.decode(text, Base64.NO_WRAP)

    private companion object {
        const val PREFS_NAME = "secure_store"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "ideashell_secure_store_key"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
        const val SEPARATOR = ":"
    }
}
