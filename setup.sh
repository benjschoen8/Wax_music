#!/usr/bin/env bash
# One-shot setup: ./setup.sh   (run from this folder, Flutter on PATH)
# Generates the Android project around lib/ + test/, installs the packages,
# installs the ready-made AndroidManifest and sets minSdk 24.
set -euo pipefail
cd "$(dirname "$0")"
command -v flutter >/dev/null || { echo "flutter is not on PATH"; exit 1; }

# flutter create writes its own lib/ and test/: keep ours.
rm -rf .lib_backup .test_backup
cp -r lib .lib_backup
cp -r test .test_backup
flutter create --platforms=android --project-name crate --org dev.crate .
rm -rf lib test
mv .lib_backup lib
mv .test_backup test

flutter pub remove media_store_plus >/dev/null 2>&1 || true   # left over from an older zip
flutter pub add youtube_explode_dart shared_preferences just_audio path_provider \
  connectivity_plus:^6.1.5 file_picker:^10.3.8 flutter_foreground_task \
  ffmpeg_kit_flutter_new_audio:^2.5.4

# Use the bundled, patched youtube_explode_dart (fixes "Invalid radix-10 number ... Streamed").
grep -q "^dependency_overrides:" pubspec.yaml || printf "\ndependency_overrides:\n  youtube_explode_dart:\n    path: third_party/youtube_explode_dart\n" >> pubspec.yaml

cp android_manifest/AndroidManifest.xml android/app/src/main/AndroidManifest.xml

# Share-sheet bridge: replace the generated MainActivity (keeping its package line).
ACT=$(find android/app/src/main -name 'MainActivity.kt' | head -n1)
if [ -n "$ACT" ]; then
  PKG=$(grep -m1 '^package ' "$ACT")
  { echo "$PKG"; echo; cat android_manifest/MainActivity.kt.body; } > "$ACT"
else
  echo "WARNING: MainActivity.kt not found; share-sheet intake not installed"
fi

# (media_store_plus was removed: its Android code is too old to build.
# Saving to Music/ now uses the small bridge in MainActivity.kt.)
K=android/app/build.gradle.kts
G=android/app/build.gradle

# FFmpeg Kit needs minSdk 24 (works for both build.gradle.kts and build.gradle).
for f in "$K" "$G"; do
  [ -f "$f" ] && perl -pi -e 's/minSdk = flutter\.minSdkVersion/minSdk = 24/; s/minSdkVersion flutter\.minSdkVersion/minSdkVersion 24/' "$f"
done
grep -n "minSdk" android/app/build.gradle* || echo "WARNING: set minSdk to 24 manually"

flutter pub get
echo
echo "Done. Connect the Pixel (USB debugging on) and run:  flutter run"
