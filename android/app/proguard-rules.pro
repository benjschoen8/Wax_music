# ProGuard / R8 rules for Crate

# Flutter Engine & Plugins JNI
-keep class io.flutter.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.embedding.**  { *; }

# Keep Crate native bridge & MainActivity
-keep class dev.crate.crate.** { *; }

# flutter_foreground_task Service & Receiver
-keep class com.pravera.flutter_foreground_task.** { *; }
-keepclassmembers class com.pravera.flutter_foreground_task.** { *; }

# audio_service & just_audio_background
-keep class com.ryanheise.audioservice.** { *; }
-keepclassmembers class com.ryanheise.audioservice.** { *; }

# just_audio & audio player background service
-keep class com.ryanheise.just_audio.** { *; }
-keepclassmembers class com.ryanheise.just_audio.** { *; }

# MediaSession and Android media support
-keep class androidx.media.** { *; }
-keep class androidx.media.app.** { *; }
-keep class android.support.v4.media.** { *; }
-keep class android.support.v4.media.session.** { *; }

# ffmpeg-kit native binaries and JNI bindings
-keep class com.arthenica.ffmpegkit.** { *; }
-keepclassmembers class com.arthenica.ffmpegkit.** { *; }

# webview_flutter
-keep class io.flutter.plugins.webviewflutter.** { *; }

# shared_preferences
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# file_picker
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# connectivity_plus
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# Suppress warnings from platform dependencies
-dontwarn io.flutter.**
-dontwarn com.arthenica.ffmpegkit.**
