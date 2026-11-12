// Add to the existing MethodChannel handler in
// android/app/src/main/kotlin/dev/crate/crate/MainActivity.kt
// (channel name: "crate/media"). Your MainActivity.kt was not in the zip, so
// this is a snippet to merge, not a drop-in file.
//
// Needed imports:
//   import android.media.MediaScannerConnection
//   import android.provider.MediaStore
//   import java.io.File

// --- inside the `when (call.method)` block -------------------------------
"delete" -> {
    val path = call.argument<String>("path")
    result.success(deleteAudio(path))
}
"scan" -> {
    val path = call.argument<String>("path")
    if (path == null || !isSafeAudioPath(path)) {
        result.success(false)
    } else {
        MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null, null)
        result.success(true)
    }
}

// --- add as methods of MainActivity --------------------------------------
/**
 * Only absolute paths to audio files under shared storage, with no ".."
 * segments after canonicalisation. Mirrors isSafeAudioPath() in files.dart so a
 * bad path is refused on both sides of the bridge.
 */
private val audioExts = setOf("m4a", "mp3", "opus", "ogg", "flac", "wav", "aac", "webm")

private fun isSafeAudioPath(path: String?): Boolean {
    if (path == null || path.contains('\u0000')) return false
    return try {
        val f = File(path).canonicalFile
        val p = f.path
        (p.startsWith("/storage/") || p.startsWith("/sdcard/")) &&
            f.extension.lowercase() in audioExts
    } catch (e: Exception) {
        false
    }
}

/**
 * Removes the MediaStore row and the file. Works for files this app created
 * (everything saved through the "save" method). For audio owned by another
 * app Android throws a SecurityException (RecoverableSecurityException on
 * API 29); we return false and Dart shows an honest "couldn't delete" message.
 */
private fun deleteAudio(path: String?): Boolean {
    if (!isSafeAudioPath(path)) return false
    val safe = File(path!!).canonicalPath
    return try {
        contentResolver.delete(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            "${MediaStore.Audio.Media.DATA}=?",
            arrayOf(safe)
        )
        !File(safe).exists()
    } catch (e: SecurityException) {
        false
    }
}
