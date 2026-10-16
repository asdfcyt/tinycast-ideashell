package com.carpe.ideashell.system

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * 触感反馈。完成番茄 / 任务时：终端亮起一下清脆的点按，小票出纸时一串细密的「哒哒哒」，
 * 最后「咔」的一声撕票。Android 16 起用包络振动（自己定义强度曲线）；不支持就退回组合触感，再不行退回普通波形。
 */
object Haptics {
    private fun vibrator(context: Context): Vibrator? = runCatching {
        context.getSystemService(VibratorManager::class.java)?.defaultVibrator
    }.getOrNull()?.takeIf { it.hasVibrator() }

    /** 终端亮起：一下点按 */
    fun terminalOn(context: Context) {
        val v = vibrator(context) ?: return
        runCatching {
            val effect = if (v.areAllPrimitivesSupported(VibrationEffect.Composition.PRIMITIVE_CLICK)) {
                VibrationEffect.startComposition().addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 0.6f).compose()
            } else {
                VibrationEffect.createOneShot(25, 120)
            }
            v.vibrate(effect)
        }
    }

    /** 小票出纸（约 1.1 秒）+ 撕票 */
    fun printTicket(context: Context) {
        val v = vibrator(context) ?: return
        runCatching {
            val effect = when {
                Build.VERSION.SDK_INT >= 36 && v.areEnvelopeEffectsSupported() -> envelope(v)
                v.areAllPrimitivesSupported(VibrationEffect.Composition.PRIMITIVE_TICK, VibrationEffect.Composition.PRIMITIVE_CLICK) -> {
                    val c = VibrationEffect.startComposition()
                    repeat(14) { i ->
                        // 出纸越到后面越实
                        c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_TICK, 0.28f + 0.03f * i, if (i == 0) 0 else 55)
                    }
                    c.addPrimitive(VibrationEffect.Composition.PRIMITIVE_CLICK, 0.9f, 90)
                    c.compose()
                }

                else -> {
                    val timings = LongArray(30) { if (it % 2 == 0) 18L else 42L } + longArrayOf(60L, 35L)
                    val amps = IntArray(30) { if (it % 2 == 0) 90 else 0 } + intArrayOf(0, 220)
                    VibrationEffect.createWaveform(timings, amps, -1)
                }
            }
            v.vibrate(effect)
        }
    }

    @androidx.annotation.RequiresApi(36)
    private fun envelope(v: Vibrator): VibrationEffect {
        val info = v.envelopeEffectInfo
        val resonant = v.resonantFrequency.takeIf { !it.isNaN() && it > 0f } ?: 150f
        val profile = v.frequencyProfile
        val f = if (profile != null) resonant.coerceIn(profile.minFrequencyHz, profile.maxFrequencyHz) else resonant
        val maxSize = info?.maxSize ?: 16
        val pairs = ((maxSize - 3) / 2).coerceIn(2, 9)
        val minStep = info?.minControlPointDurationMillis ?: 10L
        fun d(ms: Long) = ms.coerceAtLeast(minStep)
        val b = VibrationEffect.WaveformEnvelopeBuilder().setInitialFrequencyHz(f)
        // 纸一格一格被送出来：强弱交替，越到后面越实
        repeat(pairs) { i ->
            val strength = 0.30f + 0.35f * i / pairs
            b.addControlPoint(strength, f, d(40))
            b.addControlPoint(0.08f, f, d(60))
        }
        // 撕票：一下利落的重音，然后收掉
        b.addControlPoint(0.95f, f, d(30))
        b.addControlPoint(0f, f, d(50))
        return b.build()
    }
}
