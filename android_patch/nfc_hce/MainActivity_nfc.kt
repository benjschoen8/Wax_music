// Merge into MainActivity.kt, inside configureFlutterEngine(...).
// Imports: android.nfc.NfcAdapter, android.content.pm.PackageManager,
//          io.flutter.plugin.common.MethodChannel

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
