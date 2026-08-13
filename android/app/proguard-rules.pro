# kotlinx.serialization keeps its generated serializers on the companion; R8 cannot see the
# reflective lookup that finds them.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class dev.terminaldeck.android.protocol.** {
    *** Companion;
}
-keepclasseswithmembers class dev.terminaldeck.android.protocol.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# OkHttp pulls in optional Conscrypt/BouncyCastle/OpenJSSE providers that are not on Android.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
