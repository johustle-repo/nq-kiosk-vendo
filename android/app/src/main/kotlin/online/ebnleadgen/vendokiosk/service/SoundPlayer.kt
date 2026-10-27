package online.ebnleadgen.vendokiosk.service

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.util.Log
import online.ebnleadgen.vendokiosk.core.SoundCue
import online.ebnleadgen.vendokiosk.kiosk.KioskDeviceAdminReceiver

/**
 * Short system tones for the customer: a coin chime and time warnings. Uses
 * the notification volume, so the administrator controls loudness and a
 * silent tablet stays silent. No sound files are bundled.
 */
class SoundPlayer {
    private val main = Handler(Looper.getMainLooper())
    private var tones: ToneGenerator? = null

    fun play(cue: SoundCue) = main.post {
        try {
            val g = tones ?: ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90).also { tones = it }
            when (cue) {
                SoundCue.COIN -> g.startTone(ToneGenerator.TONE_PROP_ACK, 300)
                SoundCue.FIVE_MINUTES -> g.startTone(ToneGenerator.TONE_PROP_BEEP2, 400)
                SoundCue.ONE_MINUTE -> repeat(3) { i -> main.postDelayed({ g.startTone(ToneGenerator.TONE_PROP_BEEP, 200) }, i * 350L) }
                SoundCue.TIME_UP -> g.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 600)
            }
        } catch (e: RuntimeException) {
            // ToneGenerator fails when audio is unavailable; sounds are optional.
            Log.w(KioskDeviceAdminReceiver.TAG, "Tone failed: $e")
            tones = null
        }
    }
}
