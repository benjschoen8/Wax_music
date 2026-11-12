# Delete song / Edit metadata: changes

## Dart (lib/)
- **widgets/track_actions_sheet.dart**: "Edit metadata" and "Delete song" are now two
  visible buttons directly under the song header (shown for any downloaded/library song),
  not rows buried in the list. The sheet is scrollable so nothing is clipped on small screens.
- **state.dart `deleteFromLibrary`** now returns `bool`. It stops playback of that song,
  deletes the file first, and only removes the song from the library if the file is really
  gone. Failure shows an error instead of "Song deleted". Also clears duplicate-detection keys.
- **state.dart `updateTrackMetadata`** now returns `({Track track, bool retagFailed})` and
  asks MediaStore to rescan after a successful retag.
- **downloader.dart `retagFile`** is crash-safe: builds the new file in the temp folder,
  verifies it, moves the original aside as `.bak`, copies the new file in, and restores the
  original on any failure. The old version deleted the original before renaming.
- **widgets/edit_metadata_dialog.dart**: tells the user when the file's tags could not be
  written (the in-app edit is still kept).
- **media_store.dart**: new `delete(path)` and `rescan(path)`. Both fall back gracefully
  when the native side lacks them (file I/O fallback for delete).
- **strings.dart**: 3 new strings, Traditional + Simplified Chinese.

- **Fix (2nd pass):** the delete result message used the closed sheet's context and would
  never have appeared; it now uses the navigator's context. Error text shortened to fit
  the 2-line snackbar and shown for 4 s.

- **UX pass 3:**
  - Downloads: a failed row now says "Download failed, tap to retry" and tapping it retries
    (before, it opened a log dialog). The raw error text moved behind a new info button.
  - Mini player: controls are 44 dp (were 36 dp, and compact density shrank them further).
    On screens narrower than 380 dp the quick-download shortcut is hidden to make room.

## Android (manual step)
`android_patch/MainActivity_delete_scan.kt` is a snippet to merge into your
`MainActivity.kt` (not included in the zip). Without it, delete falls back to plain
`File.delete()`, which may fail on scoped storage; the app will then report the failure.

## Not verified
Flutter/Dart were not available where this was edited, so `flutter analyze` / `flutter test`
have NOT been run. Run both before shipping.
Not done: undo for delete, multi-select delete, cover-art / lyrics editing.

---

# Security pass

## Fixed
- **Session cookies encrypted at rest** (`browser_auth.dart`, `pubspec.yaml`): the
  YouTube/Google login cookies were stored in plain SharedPreferences. They now live in
  `flutter_secure_storage` (Android Keystore). Existing installs are migrated once and the
  plaintext copy is deleted. If secure storage fails, the session stays in memory only; it
  never falls back to plaintext. Sign-out wipes the encrypted copy too.
- **WebView JS bridge treated as untrusted** (`browser_auth.dart`): messages are accepted only
  for a PO-token request the app itself started, with a strict video-id format, token format
  and size cap. A page/iframe can no longer inject tokens or large payloads into the caches.
- **Narrower sign-in allowlist**: removed `goo.gl`, `g.co`, `*.googleusercontent.com` and
  `*.googleapis.com` as navigable hosts (redirectors / user-content hosts).
  If a sign-in step ever breaks, the log shows the blocked host; add back only that host.
- **Logs no longer contain URL query strings** (`log.dart`): sign-in/player URLs can carry
  session identifiers. Added `AppLog.redactUrl` and more redaction patterns (key, visitor data).
- **Destructive file ops are path-guarded** (`files.dart`, `media_store.dart`, `downloader.dart`,
  Kotlin patch): delete / rescan / retag only accept absolute, `..`-free audio files under
  `/storage` or `/sdcard`, on both the Dart and native side. Also fixes the `.lrc` name
  derivation so a dot in a folder name can't target another file.
- **FFmpeg runs with `-protocol_whitelist file`**: a crafted "audio" file (HLS/concat playlist)
  can't make FFmpeg read other local files or open network connections.
- **Download hardening**: audio streams must be https on `*.googlevideo.com` and <= 1 GiB;
  cover-art download refuses redirects and caps size at 10 MB; lyrics responses capped at
  2 MB and local `.lrc` files at 1 MB.
- **Thumbnails**: every Track thumbnail (saved data, shared playlists, search) is restricted to
  https on YouTube/Google image CDNs (`Track.sanitizeThumb`), so a crafted playlist or edited
  saved data can't make the app contact an arbitrary server.

## Also fixed (found while reviewing)
- A JavaScript syntax error in the PO-token script (`final pr = ...`; `final` is Dart, not JS)
  made the **entire** minting script fail to parse. Changed to `const`. This turns the
  PO-token / playerResponse path on for the first time, so test downloads that hit 403.
- Removed a duplicated status-check block in `Downloader.rawStream`.

## You must do (not in the zip)
See `android_patch/ANDROID_HARDENING.md`: `allowBackup=false`, no cleartext traffic,
`minSdk 23`, release obfuscation, and merge the updated Kotlin snippet.

## Not verified
Flutter/Dart weren't available and pub.dev was unreachable, so nothing was compiled or run.
Run `flutter pub get && flutter analyze && flutter test` (new tests: `test/security_test.dart`).
`flutter_secure_storage ^9.2.4` was chosen from memory; bump if pub suggests otherwise.
`third_party/youtube_explode_dart` was not in the zip, so the cookie header the library
sends was not reviewed: confirm it only goes to youtube.com / googlevideo.com hosts.

## Security pass 2
- **Google session cookies were being sent to the media CDN** (`preview.dart`): the streaming
  player attached the full `Cookie` header to the googlevideo URL. Stream URLs are signed, so
  it is not needed; removed, and the URL host is now verified (https + `*.googlevideo.com`)
  before use (`Downloader.isTrustedStreamUrl`, shared with downloads).
- **Playlist-import zip-bomb guard did not work** (`playlist_sharing.dart`): the size check ran in
  a callback that only fires after the whole payload was already inflated. Replaced with a sink
  that aborts the moment 512 KB is exceeded. Test included.
- **Save folder is allow-listed** (`files.dart`, `state.dart`): only absolute, `..`-free paths on
  `/storage/` or `/sdcard` are accepted, both when choosing a folder and when loading the saved
  one at startup (the old deny-list missed e.g. `/data`).
- **YouTube Music search** (`ytm_search.dart`): redirects are not followed while the session
  cookie is attached.
- **`trp()` template injection**: placeholders are filled in one pass, so a song/playlist title
  containing `{n}` can no longer be re-expanded into another value.
- Library scan skips `.lrc` files over 1 MB.

Reviewed, no change needed: NFC write path, share intake / `extractUrl`, FFmpeg argument
passing (argument list, no shell), file-name sanitising, TLS (no `badCertificateCallback`).
Not fixable from the zip: Android manifest items (see `android_patch/ANDROID_HARDENING.md`) and
`third_party/youtube_explode_dart`.

## Security pass 3 (re-scan)
- Re-verified every earlier edit by diff; no regressions found. No hard-coded secrets, no
  debug-only code paths, no shell/process execution, no other `Cookie` senders, no other
  remote-image loaders outside `Track.sanitizeThumb`, no regexes with exponential backtracking.
- **Uncaught errors are now logged through `AppLog`** (`main.dart`), which redacts cookies,
  tokens and URL queries, instead of raw exception text (e.g. signed stream URLs) going to the
  device log.
- Remaining items are outside the zip (Android manifest, `third_party/youtube_explode_dart`).

## Security pass 4
- **Bounded in-memory caches** (new `lib/cache.dart`, `putBounded`): PO tokens, player responses
  (max 5; they can be 2 MB each and the fixed JS now fills them), stream manifests, lyrics,
  search/album/artist caches. Previously they only grew.
- **User-edited metadata is clipped and control-character-stripped** (<= 200 chars) before it
  reaches file names, FFmpeg arguments and saved data.
- No new vulnerabilities found in the remaining UI files (library, home, now-playing, sheets).

## UX scan
Checked: translation coverage (all 281 strings used in code exist in both Chinese maps),
empty/loading/error states, destructive-action confirmations, icon-button labels, tap targets.
- Choosing a save folder outside shared storage now says "Cannot write to that folder. Pick one
  inside Music or Download." (my allow-list had reused the misleading "system directory" text).
- "Clear download history" now offers **Undo** (5 s) instead of being instant and permanent.
- The Google sign-in sheet's close button now has a tooltip / screen-reader label.
Not changed (judgement calls): compact-density chips/buttons in search are < 48 dp visually
(tap area is still padded by Material); if encrypted cookie storage fails the user is silently
signed out on next launch (logged, but no message).

## Scan (static, no compile)
- **Search errors no longer show raw exception text** (`SocketException: Failed host lookup ...`,
  library stack-style messages). All five search/artist/album/playlist error paths now use
  `Downloader.friendly()`, e.g. "No connection. Tap retry." The existing Retry button is kept.
  Also avoids exposing internal URLs/details in the UI.

---

# Fix: album downloads fetched the music-video cut instead of the audio (Topic) track

Symptom: album track listed as 4:40 ("Love From the Other Side", Fall Out Boy) downloaded
as the 5:27 music-video audio.

- **playlist_search.dart `loadAlbum`**: when an album row has both a row id and a play-button
  id, the play-button id is used if YouTube Music tags it `MUSIC_VIDEO_TYPE_ATV` (audio release).
- **downloader.dart `fetch`**: new length guard. If the stream's length (size / bitrate) is more
  than 15 s and 8 % away from the listed track length, the id is treated as a music video, the
  audio release is looked up and the download retries with it. If none is found it downloads the
  original as before. Library/duplicate keys still use the original id.
- **ytm_search.dart `resolveAudioId`**: finds the "- Topic" release with the same title and a
  length within 3 s of the listed one (prefers the same album).
- Also looks for the audio release when the track has no listed length and isn't a "- Topic" upload.
- Log lines `stream is ~Ns but track is Ms` / `using audio version <id>` show when it fires.

Not verified: no Flutter/Dart or access to music.youtube.com here; run `flutter analyze`
and test the Fall Out Boy album.

---

# Fix: NFC playlist sharing did nothing between two phones

Cause: the sender ran an NFC *reader* session waiting for a writable sticker, so a second phone
(which is not a tag) was never written to, and the receiving side had no NFC code at all.
Android Beam, which used to do phone-to-phone push, no longer exists.

- **Sender** (`playlist_sharing.dart`): now emulates an NFC Type 4 tag (Host Card Emulation) that
  serves the `wax://playlist?...` link as an NDEF URI record while "Share playlist" is open.
  "Transferred" shows when the other phone has read the whole message.
- **Receiver**: Library > Import playlist > **Receive via NFC** reads that tag and imports it.
  Works with normal NFC stickers holding a wax:// link too.
- **Native part (required, not in the zip):** `android_patch/nfc_hce/` has `WaxNdefService.kt`,
  `wax_apdu_service.xml`, manifest entries and the `crate/nfc` channel snippet for MainActivity.
  Without it the sheet shows NFC as unavailable and QR still works.
- Both phones need NFC on; the sender needs card emulation (most Android phones have it).
  Keep screens on and unlocked, backs together, hold ~1 s.
- 4 new strings (Traditional + Simplified Chinese).
Not verified: not compiled or tested on devices; run `flutter analyze` and test on two phones.

---

# Fix: songs deleted outside the app stayed in the library

The scan only removed missing `local_*` songs. Downloaded songs (YouTube ids) and finished
downloads in the queue were never checked. Now `scanLocalStorage` (state.dart) removes any song
whose file is gone and not seen in the scan, and the Library list (library_page.dart) hides done
downloads whose file no longer exists. A song is kept if its folder is unreachable (SD card
removed / permission lost), so a failed scan can't wipe the library. Pull-to-refresh in Library
runs the scan. Playlists keep their entries. Not compiled or tested here.

---

# NFC follow-up: receiver read + smaller payload + logging

- Receiver now falls back to `NdefAndroid.getNdefMessage()` when Android's cached NDEF message is
  empty (`readNdefMessage` never existed in nfc_manager 4.3.0; `getNdefMessage` is the real method).
- NFC payload no longer includes thumbnail URLs (`encodePlaylist(withThumbs: false)`), roughly
  halving the message so the phones only need to stay together briefly. QR/links keep thumbnails.
- Logging: app log lines starting `NFC` and Android logcat tag `WaxNfc` (APDU, fully read,
  deactivated reason). Re-copy `android_patch/nfc_hce/WaxNdefService.kt`.

---

# NFC: share sheet now says why NFC isn't active

The pill silently fell back to "Scan QR code" whenever NFC could not start. It now shows the
reason (bridge not installed, no NFC, NFC off, no card emulation, too large). Re-merge
`android_patch/nfc_hce/MainActivity_nfc.kt` (new `status` method) for the exact reason; with the
old bridge it shows a generic message.

Size: ~28 bytes per track in the NFC link (no thumbnails). The 65,000 byte limit would allow about
2,300 tracks, above the app's 1,000 track cap, so it does not bind in practice.

---

# Library: multi-select for bulk edit / delete

- Long-press a song (All songs, or inside an artist/album) to start selecting; tap to toggle.
  Long-press an artist row or album card to select all its songs; tap to toggle the group
  (check marks / partial state shown). Bar at top: cancel, select all (current list), Edit, Delete.
- Delete: confirms, then removes the files like the single-song delete (reports failures).
- Edit: one song opens the normal dialog; several open a bulk dialog for Artist and/or Album
  (blank = keep each song's value) with a progress bar; tags in the files are rewritten.
- Long-press on a song no longer opens the actions sheet (use the ⋮ button). Playlist detail
  screens are unchanged.
- Back button / Cancel leaves selection mode. Not compiled or tested here.
