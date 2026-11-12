# Android hardening checklist (files not included in the zip)

The zip only contains `lib/`, so these settings could not be applied directly.
Please apply them in your project; each one closes a specific risk.

## `android/app/src/main/AndroidManifest.xml`

On the `<application>` element:

```xml
<application
    android:allowBackup="false"
    android:fullBackupContent="false"
    android:dataExtractionRules="@xml/data_extraction_rules"
    android:usesCleartextTraffic="false"
    android:networkSecurityConfig="@xml/network_security_config"
    ... >
```

* `allowBackup=false` / `dataExtractionRules`: keeps `shared_preferences`
  (library, queue, history) out of cloud/adb backups. (Session cookies are now
  in the encrypted store, but there is still no reason to back up app data.)
* `usesCleartextTraffic=false` + the config below: refuse plain `http://`
  everywhere, as a backstop to the https-only checks in Dart.

`res/xml/data_extraction_rules.xml`:

```xml
<data-extraction-rules>
    <cloud-backup><exclude domain="sharedpref" path="."/></cloud-backup>
    <device-transfer><exclude domain="sharedpref" path="."/></device-transfer>
</data-extraction-rules>
```

`res/xml/network_security_config.xml`:

```xml
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors><certificates src="system"/></trust-anchors>
    </base-config>
</network-security-config>
```

## Exported components / intent filters

* `MainActivity` must be the only `android:exported="true"` activity.
* Keep the `SEND text/plain` and `wax://playlist` filters as narrow as they
  are today; do not add a generic `VIEW https` filter. Everything arriving
  there is re-validated in Dart (`extractUrl`, `decodePlaylist`), and playlist
  imports need an explicit confirmation tap.
* Do not set `android:debuggable="true"` in release builds, and keep
  `android:requestLegacyExternalStorage` unset (scoped storage is the point).

## Build

* `minSdkVersion 23` or higher (required by `flutter_secure_storage`).
* Release builds: `flutter build apk --release --obfuscate --split-debug-info=build/symbols`
  and enable R8 (`minifyEnabled true`, `shrinkResources true`).
* Add ProGuard keep rules only for what actually breaks; don't use a blanket `-keep class **`.

## MainActivity.kt

Merge the updated `MainActivity_delete_scan.kt` snippet. `delete` and `scan` now
canonicalise the path and refuse anything that is not an audio file under
`/storage/` or `/sdcard/`.
