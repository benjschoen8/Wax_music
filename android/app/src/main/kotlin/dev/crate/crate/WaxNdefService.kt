// Copy to android/app/src/main/kotlin/dev/crate/crate/WaxNdefService.kt
// (same package as your MainActivity; change the package line if yours differs).
//
// Emulates an NFC Forum Type 4 Tag that serves ONE NDEF message (the playlist
// link). Another phone reading NFC sees an ordinary NDEF tag. Data is served
// only while the "Share playlist" sheet is open (ndefFile != null).
package dev.crate.crate

import android.nfc.cardemulation.HostApduService
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

class WaxNdefService : HostApduService() {

    companion object {
        /** NLEN (2 bytes) + NDEF message, or null when not sharing. */
        @Volatile private var ndefFile: ByteArray? = null
        @Volatile var onDelivered: (() -> Unit)? = null

        private const val MLE = 0xFF // max bytes we return per READ BINARY

        fun setMessage(msg: ByteArray?) {
            ndefFile = if (msg == null || msg.size > 0xFFFD) null
            else byteArrayOf((msg.size shr 8).toByte(), msg.size.toByte()) + msg
        }

        private val AID = byteArrayOf(
            0xD2.toByte(), 0x76, 0x00, 0x00, 0x85.toByte(), 0x01, 0x01
        )
        private val OK = byteArrayOf(0x90.toByte(), 0x00)
        private val NOT_FOUND = byteArrayOf(0x6A, 0x82.toByte())
        private val BAD_OFFSET = byteArrayOf(0x6B, 0x00)
        private val UNSUPPORTED = byteArrayOf(0x6D, 0x00)
    }

    private var appSelected = false
    private var selected = 0 // 0 none, 1 capability container, 2 NDEF file

    private fun capabilityContainer(fileSize: Int) = byteArrayOf(
        0x00, 0x0F,                         // CCLEN = 15
        0x20,                               // mapping version 2.0
        0x00, MLE.toByte(),                 // MLe
        0x00, MLE.toByte(),                 // MLc
        0x04, 0x06,                         // NDEF file control TLV
        0xE1.toByte(), 0x04,                // NDEF file id
        (fileSize shr 8).toByte(), fileSize.toByte(), // max NDEF file size
        0x00,                               // read access: open
        0xFF.toByte()                       // write access: none
    )

    override fun processCommandApdu(apdu: ByteArray, extras: Bundle?): ByteArray {
        val file = ndefFile ?: return NOT_FOUND
        if (apdu.size < 4) return UNSUPPORTED
        val ins = apdu[1].toInt() and 0xFF
        Log.d("WaxNfc", "APDU ins=%02X len=%d".format(ins, apdu.size))

        when (ins) {
            0xA4 -> { // SELECT
                val p1 = apdu[2].toInt() and 0xFF
                val lc = if (apdu.size > 4) apdu[4].toInt() and 0xFF else 0
                if (apdu.size < 5 + lc) return NOT_FOUND
                val data = apdu.copyOfRange(5, 5 + lc)
                if (p1 == 0x04) {
                    return if (data.contentEquals(AID)) {
                        appSelected = true; selected = 0; OK
                    } else NOT_FOUND
                }
                if (p1 == 0x00 && appSelected && data.size == 2) {
                    val id = ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF)
                    return when (id) {
                        0xE103 -> { selected = 1; OK }
                        0xE104 -> { selected = 2; OK }
                        else -> NOT_FOUND
                    }
                }
                return NOT_FOUND
            }
            0xB0 -> { // READ BINARY
                if (!appSelected) return UNSUPPORTED
                val offset = ((apdu[2].toInt() and 0xFF) shl 8) or (apdu[3].toInt() and 0xFF)
                var le = when {
                    apdu.size == 5 -> apdu[4].toInt() and 0xFF
                    apdu.size == 7 && apdu[4].toInt() == 0 ->
                        ((apdu[5].toInt() and 0xFF) shl 8) or (apdu[6].toInt() and 0xFF)
                    else -> 0
                }
                if (le == 0) le = MLE
                le = minOf(le, MLE)
                val src = when (selected) {
                    1 -> capabilityContainer(file.size)
                    2 -> file
                    else -> return NOT_FOUND
                }
                if (offset > src.size) return BAD_OFFSET
                val end = minOf(src.size, offset + le)
                val chunk = src.copyOfRange(offset, end)
                if (selected == 2 && src.size > 2 && end == src.size) {
                    Log.d("WaxNfc", "message fully read (${src.size} bytes)")
                    Handler(Looper.getMainLooper()).post { onDelivered?.invoke() }
                }
                return chunk + OK
            }
        }
        return UNSUPPORTED
    }

    override fun onDeactivated(reason: Int) {
        Log.d("WaxNfc", "deactivated reason=$reason")
        appSelected = false
        selected = 0
    }
}
