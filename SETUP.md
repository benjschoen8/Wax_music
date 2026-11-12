# Crate – Flutter setup

## Quick start

```bash
cd crate
./setup.sh        # creates the Android project, installs packages, manifest, minSdk 24
flutter run       # Pixel connected with USB debugging
flutter test      # unit tests
flutter build apk --release
```

`setup.sh` has not been run on a real machine yet. If it fails, use the manual
steps below.

## Manual setup

```bash
flutter create crate --platforms=android      # then copy lib/ and test/ over it
cd crate
flutter pub add youtube_explode_dart shared_preferences just_audio path_provider \
  connectivity_plus:^6.1.5 file_picker:^10.3.8 \
  flutter_foreground_task ffmpeg_kit_flutter_new_audio:^2.5.4
```

1. Replace `android/app/src/main/AndroidManifest.xml` with
   `android_manifest/AndroidManifest.xml`.
2. In `android/app/build.gradle(.kts)` set `minSdk = 24` inside `defaultConfig`.
3. Delete the generated `test/widget_test.dart` (it references a `MyApp`).
4. For the share sheet and saving into Music/, replace `MainActivity.kt` (under
   `android/app/src/main/kotlin/...`) with `android_manifest/MainActivity.kt.body`,
   keeping the first `package ...` line of the generated file. (If you skip
   this, searching still works but songs are saved with plain file writes.)

## Layout

```
lib/main.dart            app shell, tabs, Back handling
lib/state.dart           queue, worker loop, settings, history
lib/downloader.dart      network + FFmpeg + saving (MediaStore / file I/O)
lib/files.dart           pure-Dart path helpers (unit-tested)
lib/share.dart           receives links shared from other apps (Share -> Crate)
lib/preview.dart         listen before downloading (just_audio)
lib/service.dart         foreground-service keep-alive handler
lib/log.dart             in-memory error log (Settings -> Copy error log)
lib/strings.dart         English / 繁體 / 简体 (follows the phone language)
lib/constants.dart
lib/models/track.dart    pure-Dart model (unit-tested)
lib/models/video_ext.dart
lib/pages/               search, queue, settings
test/                    track_test.dart, files_test.dart
android_manifest/        ready-made AndroidManifest.xml + MainActivity.kt.body (Kotlin bridges)
```

## What was verified against package source

The calls the app makes were checked against the actual source of
`youtube_explode_dart` 3.1.0, `flutter_foreground_task` 11.0.3,
`ffmpeg_kit_flutter_new` 4.6.8 and `file_picker` 10.3.8 (names, parameters, return types). That caught
`PlaylistId.parsePlaylistId` returning a `String`, not an object. None of it has
been compiled with Flutter or run on a device.

## How it behaves

- **Format**: YouTube's AAC saved as `.m4a`, not re-encoded. If a video offers
  only WebM/Opus, it is converted to AAC (the only re-encode) instead of
  saving a mislabelled file.
- **Tags**: title, artist and a square cover are written with FFmpeg in
  stream-copy mode. If tagging fails the untagged file is still saved
  (switch it off in Settings to skip FFmpeg entirely).
- **Saving**: folders inside `Music/` (default `Music/Crate`) go through
  MediaStore through a small native bridge (Android 10+); songs appear in music
  apps immediately. On Android 9 or older it falls back to plain file writes. Other folders (e.g. Download) use plain file writes, tested
  when you pick them; a red warning shows if one isn't writable.
- **Background**: a foreground service + notification (with progress) keeps
  downloads alive with the screen off. Pressing Back while downloading
  minimises the app instead of closing it. Swiping the app away stops the
  downloads and the notification; the queue is saved and resumes on the next
  launch (the track in progress restarts from 0%).
- **Share sheet**: in the YouTube app tap Share -> Crate; the link is searched
  (or the playlist expanded) immediately. Needs the replaced MainActivity and
  the manifest's SEND intent-filter (both done by `setup.sh`).
- **Wi-Fi only** (Settings): downloads wait, with a banner in the Queue tab,
  until Wi-Fi or Ethernet is available; the check repeats every 15 s.
- **Parallel downloads** (Settings, 1-3): more lanes are faster but YouTube may
  throttle you; default 1.
- **Cache**: a fully downloaded track is kept in the cache until it is saved,
  so a retry or a restart after a tagging/saving failure doesn't download it
  again. Cache files older than a day are removed at launch.
- **Playlists**: pasting one shows a checkbox per track (all ticked), a
  select all/none toggle and "Add selected". Tap a row to tick it.
- **Search results** show whether a track is in the queue (hourglass) or
  already downloaded (download-done icon). Empty Search tab shows quick tips.
- **Queue**: swipe or tap ✕ to remove, with an Undo for 4 s; tap a failed track
  for the full error (and copy the log); "Find music" button when empty.
- **Finished**: when a whole run completes you get "Done: N saved, M failed"
  with a shortcut to the queue.
- **Retries**: each track retries twice; retries switch YouTube API client
  (default, Android VR, TV). A stalled stream times out after 30 s.
- **History**: a track counts as downloaded only while its file still exists.
  Settings -> Forget downloaded history resets this.
- **Preview**: tap a thumbnail; the smallest audio stream is cached and played.
- **Filters/recents**: length, Topic and result count are remembered, as are
  the last 10 searches. Filters apply to text searches, not pasted playlists.
- **Names/tags**: illegal characters replaced, no leading dot, clipped to 180
  bytes (CJK-safe); "(Official Video)" / "[Lyrics]" noise is removed.
- **Debugging**: Settings -> Copy error log.
- **Theme/language**: follows the system light/dark theme and language.

## Known limits

- A download interrupted *mid-stream* restarts from 0% (YouTube's stream URLs
  make range requests unreliable). Only fully downloaded tracks are reused.
- Anything that depends on YouTube not changing: if downloads start failing,
  run `flutter pub upgrade youtube_explode_dart`.
- FFmpeg Kit is retired upstream; this uses the community fork
  `ffmpeg_kit_flutter_new_audio` (+20–30 MB, Android 7+).
- Release builds shrink code with R8: test `flutter run --release` before
  sharing an APK.
- Pixel tip: Settings -> Apps -> Crate -> Battery -> Unrestricted.
- Downloading from YouTube is against its terms of service: personal use only,
  not for the Play Store.

## Playlists, duplicates, rate limits

- **Playlist search**: turn on the "Playlists" chip, search, tap a playlist to
  list its songs (all ticked), then "Add selected" queues and starts them.
  Pasting a playlist link still works too.
- **Already downloaded**: songs are skipped if Crate downloaded them before
  *or* a file with the same "Artist - Title" name is in the save folder (also
  counts files from before a reinstall). On first use Android asks for
  permission to read audio files; without it only Crate's own files are seen.
  Delete the file and the song becomes downloadable again.
- **"YouTube is limiting this connection"**: YouTube rate-limits IPs that make
  many requests. Wait 15-30 min or switch Wi-Fi <-> mobile data. Crate now
  stops the queue when this happens instead of retrying, and asks YouTube's
  player API directly (no watch page) to be less likely to trigger it.
