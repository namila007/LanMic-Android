# JNI: native methods are looked up by name from liblanmic_audio.
-keepclasseswithmembernames class * { native <methods>; }
-keep class me.namila.app.lanmic.pcm_out.** { *; }
# Flutter references Play Core deferred components, which this app does not ship.
-dontwarn com.google.android.play.core.**
