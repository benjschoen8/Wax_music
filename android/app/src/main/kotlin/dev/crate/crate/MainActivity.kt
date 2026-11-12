package dev.crate.crate

import android.nfc.NfcAdapter

import android.content.ContentUris
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.provider.MediaStore
import android.util.Size
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import kotlin.math.absoluteValue

/**
 * Two small bridges to Dart:
 *  - "crate/share": text shared from other apps (ACTION_SEND text/plain)
 *  - "crate/media": saving audio into Music/ through MediaStore (Android 10+),
 *    the supported way to add songs without any storage permission.
 */
class MainActivity : AudioServiceActivity() {
    private var channel: MethodChannel? = null
    private var pending: String? = null
    private var shareIntakeReady = false
    private var askPending: MethodChannel.Result? = null
    private val readCode = 4242

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)


val nfcChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "crate/nfc")
nfcChannel.setMethodCallHandler { call, result ->
    when (call.method) {
        "isAvailable" -> {
            val adapter = NfcAdapter.getDefaultAdapter(this)
            result.success(
                adapter != null && adapter.isEnabled &&
                    packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION)
            )
        }
        "status" -> {
            // Tells Dart why sharing is unavailable (shown in the share sheet).
            val adapter = NfcAdapter.getDefaultAdapter(this)
            result.success(
                when {
                    adapter == null -> "no_nfc"
                    !adapter.isEnabled -> "off"
                    !packageManager.hasSystemFeature(PackageManager.FEATURE_NFC_HOST_CARD_EMULATION) -> "no_hce"
                    else -> "unavailable"
                }
            )
        }
        "startShare" -> {
            val bytes = call.argument<ByteArray>("ndef")
            if (bytes == null || bytes.isEmpty() || bytes.size > 65000) {
                result.success(false)
            } else {
                WaxNdefService.setMessage(bytes)
                WaxNdefService.onDelivered = { nfcChannel.invokeMethod("delivered", null) }
                result.success(true)
            }
        }
        "stopShare" -> {
            WaxNdefService.setMessage(null)
            WaxNdefService.onDelivered = null
            result.success(true)
        }
        else -> result.notImplemented()
    }
}
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        val ch = MethodChannel(messenger, "crate/share")
        ch.setMethodCallHandler { call, result ->
            if (call.method == "getInitial") {
                shareIntakeReady = true
                result.success(pending)
                pending = null
            } else {
                result.notImplemented()
            }
        }
        channel = ch
        // Cold start: Dart isn't listening yet, so keep it until it asks.
        pending = sharedText(intent)

        MethodChannel(messenger, "crate/media").setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(Build.VERSION.SDK_INT >= 29)
                "exists" -> {
                    val name = call.argument<String>("name") ?: ""
                    val rel = call.argument<String>("rel") ?: ""
                    result.success(audioExists(name, rel))
                }
                "canRead" -> result.success(canReadAudio())
                "askRead" -> {
                    if (canReadAudio()) {
                        result.success(true)
                    } else {
                        askPending?.success(false)
                        askPending = result
                        requestPermissions(arrayOf(readPermission()), readCode)
                    }
                }
                "list" -> {
                    val rel = call.argument<String>("rel") ?: ""
                    Thread {
                        val names = try { listAudio(rel) } catch (e: Exception) { emptyList<String>() }
                        runOnUiThread { result.success(names) }
                    }.start()
                }
                "listDetails" -> {
                    val rel = call.argument<String>("rel")
                    Thread {
                        val items = try { listAudioDetails(rel) } catch (e: Exception) { emptyList<Map<String, Any?>>() }
                        runOnUiThread { result.success(items) }
                    }.start()
                }
                "save" -> {
                    val path = call.argument<String>("path") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    val rel = call.argument<String>("rel") ?: ""
                    // Copying a few MB: keep it off the UI thread.
                    Thread {
                        try {
                            val uri = saveAudio(path, name, rel)
                            runOnUiThread { result.success(uri) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("SAVE_FAILED", e.message, null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == readCode) {
            askPending?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            askPending = null
        }
    }

    private fun readPermission() =
        if (Build.VERSION.SDK_INT >= 33) android.Manifest.permission.READ_MEDIA_AUDIO
        else android.Manifest.permission.READ_EXTERNAL_STORAGE

    private fun canReadAudio() =
        checkSelfPermission(readPermission()) == PackageManager.PERMISSION_GRANTED

    /** File names of every audio file in Music/[rel] and its sub-folders (at any depth). */
    private fun listAudio(rel: String): List<String> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val out = ArrayList<String>()
        val path = relativePath(rel).trimEnd('/')
        // Match both exact folder ("Music/Crate/") and any nested sub-folders ("Music/Crate/%")
        val selection = "${MediaStore.Audio.Media.RELATIVE_PATH} = ? OR ${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ? OR ${MediaStore.Audio.Media.RELATIVE_PATH} = ?"
        val selectionArgs = arrayOf("$path/", "$path/%", path)
        contentResolver.query(
            audioCollection(),
            arrayOf(MediaStore.Audio.Media.DISPLAY_NAME),
            selection,
            selectionArgs,
            null
        )?.use { c -> while (c.moveToNext()) out.add(c.getString(0)) }
        return out
    }

    /** Detailed metadata of audio files in local storage (via MediaStore). */
    private fun listAudioDetails(rel: String?): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val projection = mutableListOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA
        )
        if (Build.VERSION.SDK_INT >= 29) {
            projection.add(MediaStore.Audio.Media.RELATIVE_PATH)
        }

        val isMusicFilter = "(${MediaStore.Audio.Media.IS_MUSIC} != 0 OR ${MediaStore.Audio.Media.MIME_TYPE} LIKE 'audio/%' OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE '%.mp3' OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE '%.m4a' OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE '%.flac' OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE '%.opus' OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE '%.ogg' OR ${MediaStore.Audio.Media.DISPLAY_NAME} LIKE '%.wav')"

        var selection = isMusicFilter
        var selectionArgs: Array<String>? = null

        if (!rel.isNullOrBlank() && !rel.equals("all", ignoreCase = true)) {
            val path = relativePath(rel).trimEnd('/')
            if (Build.VERSION.SDK_INT >= 29) {
                selection = "(${MediaStore.Audio.Media.RELATIVE_PATH} = ? OR ${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ? OR ${MediaStore.Audio.Media.RELATIVE_PATH} = ?) AND $isMusicFilter"
                selectionArgs = arrayOf("$path/", "$path/%", path)
            } else {
                selection = "(${MediaStore.Audio.Media.DATA} LIKE ?) AND $isMusicFilter"
                selectionArgs = arrayOf("%/$path/%")
            }
        }

        try {
            val collection = try {
                if (Build.VERSION.SDK_INT >= 29) {
                    MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
                } else {
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                }
            } catch (_: Exception) {
                audioCollection()
            }

            contentResolver.query(
                collection,
                projection.toTypedArray(),
                selection,
                selectionArgs,
                "${MediaStore.Audio.Media.TITLE} ASC"
            )?.use { c ->
                val idCol = c.getColumnIndex(MediaStore.Audio.Media._ID)
                val displayCol = c.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
                val titleCol = c.getColumnIndex(MediaStore.Audio.Media.TITLE)
                val artistCol = c.getColumnIndex(MediaStore.Audio.Media.ARTIST)
                val albumCol = c.getColumnIndex(MediaStore.Audio.Media.ALBUM)
                val durCol = c.getColumnIndex(MediaStore.Audio.Media.DURATION)
                val dataCol = c.getColumnIndex(MediaStore.Audio.Media.DATA)

                while (c.moveToNext()) {
                    val map = HashMap<String, Any?>()
                    val trackId = if (idCol >= 0) c.getLong(idCol).toString() else ""
                    val dataPath = if (dataCol >= 0) c.getString(dataCol) ?: "" else ""
                    if (idCol >= 0) map["id"] = trackId
                    if (displayCol >= 0) map["displayName"] = c.getString(displayCol) ?: ""
                    if (titleCol >= 0) map["title"] = c.getString(titleCol) ?: ""
                    if (artistCol >= 0) map["artist"] = c.getString(artistCol) ?: ""
                    if (albumCol >= 0) map["album"] = c.getString(albumCol) ?: ""
                    if (durCol >= 0) map["durationMs"] = c.getLong(durCol)
                    map["path"] = dataPath
                    if (dataPath.isNotEmpty()) {
                        val (coverPath, embeddedLyrics) = extractLocalCoverAndLyrics(dataPath, trackId)
                        if (coverPath != null) map["coverPath"] = coverPath
                        if (embeddedLyrics != null && embeddedLyrics.isNotBlank()) map["lyrics"] = embeddedLyrics
                    }
                    out.add(map)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("WaxMedia", "listAudioDetails failed", e)
        }
        return out
    }

    /** Extracts companion/embedded album cover art and lyrics for a local audio file. */
    private fun extractLocalCoverAndLyrics(path: String, id: String): Pair<String?, String?> {
        val file = File(path)
        if (!file.exists()) return Pair(null, null)

        var coverPath: String? = null
        var lyrics: String? = null

        // 1. Check if there is an accompanying .lrc file next to the audio file
        val baseNoExt = file.absolutePath.substringBeforeLast('.')
        val lrcFile = File("$baseNoExt.lrc")
        if (lrcFile.exists() && lrcFile.length() > 0) {
            try {
                lyrics = lrcFile.readText()
            } catch (_: Exception) {}
        }

        // 2. Check if there is an accompanying cover image next to the audio file
        for (ext in listOf(".jpg", ".png", ".jpeg", ".webp")) {
            val img = File("$baseNoExt$ext")
            if (img.exists() && img.length() > 0) {
                coverPath = img.absolutePath
                break
            }
        }
        if (coverPath == null) {
            val dir = file.parentFile
            if (dir != null) {
                for (name in listOf("cover.jpg", "cover.png", "folder.jpg", "folder.png")) {
                    val img = File(dir, name)
                    if (img.exists() && img.length() > 0) {
                        coverPath = img.absolutePath
                        break
                    }
                }
            }
        }

        // 3. Extract embedded artwork and metadata via MediaMetadataRetriever
        if (coverPath == null) {
            val mmr = MediaMetadataRetriever()
            try {
                var dataSourceSet = false
                val numId = id.toLongOrNull()
                if (numId != null) {
                    try {
                        val uri = ContentUris.withAppendedId(audioCollection(), numId)
                        contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                            mmr.setDataSource(pfd.fileDescriptor)
                            dataSourceSet = true
                        }
                    } catch (_: Exception) {}
                }
                if (!dataSourceSet && file.exists()) {
                    try {
                        java.io.FileInputStream(file).use { fis ->
                            mmr.setDataSource(fis.fd)
                            dataSourceSet = true
                        }
                    } catch (_: Exception) {}
                }
                if (!dataSourceSet) {
                    mmr.setDataSource(path)
                }

                val pic = mmr.embeddedPicture
                if (pic != null && pic.isNotEmpty()) {
                    // Save companion .jpg right next to the audio file so it's permanent across app wipes
                    val companionJpg = File("$baseNoExt.jpg")
                    try {
                        if (!companionJpg.exists()) {
                            companionJpg.writeBytes(pic)
                            if (companionJpg.exists() && companionJpg.length() > 0) {
                                coverPath = companionJpg.absolutePath
                            }
                        }
                    } catch (_: Exception) {}

                    if (coverPath == null) {
                        val coversDir = File(cacheDir, "covers")
                        coversDir.mkdirs()
                        val outFile = File(coversDir, "${file.name.hashCode().absoluteValue}.jpg")
                        if (!outFile.exists() || outFile.length() != pic.size.toLong()) {
                            outFile.writeBytes(pic)
                        }
                        coverPath = outFile.absolutePath
                    }
                }

                // If no embedded picture, check metadata author/writer or scan file header for YouTube URL or thumbnail URL
                if (coverPath == null) {
                    val author = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_AUTHOR) ?: ""
                    val writer = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_WRITER) ?: ""
                    var combined = "$author $writer"
                    try {
                        if (file.exists() && file.length() > 64) {
                            java.io.RandomAccessFile(file, "r").use { raf ->
                                val readLen = if (file.length() > 131072L) 131072 else file.length().toInt()
                                val buf = ByteArray(readLen)
                                raf.readFully(buf)
                                combined += " " + String(buf, Charsets.ISO_8859_1)
                            }
                        }
                    } catch (_: Exception) {}

                    val thumbMatch = Regex("""https?://(?:i\.ytimg\.com/vi/[a-zA-Z0-9_-]+/(?:maxresdefault|sddefault|hqdefault|mqdefault|default)\.jpg|[a-zA-Z0-9.-]+\.googleusercontent\.com/[^\s"']+)""").find(combined)
                    if (thumbMatch != null) {
                        coverPath = thumbMatch.value
                    } else {
                        val ytMatch = Regex("""(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})""").find(combined)
                        if (ytMatch != null) {
                            val vid = ytMatch.groupValues[1]
                            coverPath = "https://i.ytimg.com/vi/$vid/hqdefault.jpg"
                        }
                    }
                }
            } catch (_: Exception) {
            } finally {
                try { mmr.release() } catch (_: Exception) {}
            }
        }

        // 4. MediaStore thumbnail fallback on Android 10+
        if (coverPath == null && Build.VERSION.SDK_INT >= 29 && id.isNotEmpty()) {
            try {
                val numId = id.toLongOrNull()
                if (numId != null) {
                    val uri = ContentUris.withAppendedId(audioCollection(), numId)
                    val bitmap = contentResolver.loadThumbnail(uri, Size(512, 512), null)
                    val coversDir = File(cacheDir, "covers")
                    coversDir.mkdirs()
                    val outFile = File(coversDir, "${id}.jpg")
                    FileOutputStream(outFile).use { out ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
                    }
                    if (outFile.exists() && outFile.length() > 0) {
                        coverPath = outFile.absolutePath
                    }
                }
            } catch (_: Exception) {}
        }

        return Pair(coverPath, lyrics)
    }

    // App already open (launchMode=singleTop): push straight to Dart.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        sharedText(intent)?.let {
            if (shareIntakeReady) channel?.invokeMethod("shared", it)
            else pending = it
        }
    }

    private fun sharedText(i: Intent?): String? {
        if (i == null) return null
        if (i.action == Intent.ACTION_SEND && i.type == "text/plain") {
            val text = i.getStringExtra(Intent.EXTRA_TEXT)?.trim()
            if (!text.isNullOrEmpty() && text.length <= 16384) {
                return text
            }
        }
        val data = i.dataString?.trim()
        if (!data.isNullOrEmpty() && data.length <= 65536 && (data.startsWith("wax://") || data.startsWith("http://") || data.startsWith("https://"))) {
            return data
        }
        return null
    }

    private fun audioCollection() =
        MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)

    /** "Music/" for the root, "Music/Folder/" for rel = "Folder". Trailing slash
     *  is required: without it MediaStore treats the DISPLAY_NAME as a subdirectory. */
    private fun relativePath(rel: String): String {
        val parts = rel.replace('\\', '/').split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "." && it != ".." }
        val tail = if (parts.firstOrNull()?.equals("Music", ignoreCase = true) == true)
            parts.drop(1) else parts
        return (listOf("Music") + tail).joinToString("/") + "/"
    }

    private fun audioExists(name: String, rel: String): Boolean {
        if (Build.VERSION.SDK_INT < 29) return false
        val path = relativePath(rel).trimEnd('/')
        val selection = "${MediaStore.Audio.Media.DISPLAY_NAME}=? AND (${MediaStore.Audio.Media.RELATIVE_PATH}=? OR ${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ? OR ${MediaStore.Audio.Media.RELATIVE_PATH}=?)"
        val selectionArgs = arrayOf(name, "$path/", "$path/%", path)
        contentResolver.query(
            audioCollection(),
            arrayOf(MediaStore.Audio.Media._ID),
            selection,
            selectionArgs,
            null
        )?.use { return it.moveToFirst() }
        return false
    }

    private fun saveAudio(path: String, name: String, rel: String): String {
        val relPath = relativePath(rel)
        val display = name.substringAfterLast('/').substringAfterLast('\\')
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, display)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp4")
            put(MediaStore.Audio.Media.RELATIVE_PATH, relPath)
            put(MediaStore.Audio.Media.IS_PENDING, 1) // hidden until fully written
        }
        val uri = contentResolver.insert(audioCollection(), values)
            ?: throw IllegalStateException("MediaStore refused the new file")
        try {
            contentResolver.openOutputStream(uri)?.use { o ->
                File(path).inputStream().use { it.copyTo(o) }
            } ?: throw IllegalStateException("Cannot open the new file")

            val done = ContentValues().apply {
                put(MediaStore.Audio.Media.IS_PENDING, 0)
            }
            contentResolver.update(uri, done, null, null)

            // Read back what Android really stored.
            contentResolver.query(
                uri,
                arrayOf(
                    MediaStore.Audio.Media.RELATIVE_PATH,
                    MediaStore.Audio.Media.DISPLAY_NAME
                ),
                null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val gotRel = c.getString(0) ?: ""
                    val gotName = c.getString(1) ?: display
                    if (!gotRel.equals(relPath, ignoreCase = true)) {
                        throw IllegalStateException(
                            "MediaStore stored '$gotRel' instead of '$relPath'"
                        )
                    }
                    return "/storage/emulated/0/$gotRel$gotName"
                }
            }
            return "/storage/emulated/0/$relPath$display"
        } catch (e: Exception) {
            contentResolver.delete(uri, null, null) // never leave a half-written song
            throw e
        }
    }
}
