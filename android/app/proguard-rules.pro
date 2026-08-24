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

# sshj — the SSH client the phone signs into a bare server with.
#
# Its Ed25519 support is `net.i2p.crypto:eddsa`, which was written against the JDK and reaches for
# `sun.security.x509.X509Key` in one branch of `EdDSAEngine.engineInitVerify`. That class does not
# exist on Android at all, so R8 stops the **release** build outright:
#
#     ERROR: R8: Missing class sun.security.x509.X509Key
#
# The branch is dead here — the keys this app hands it come out of sshj's own readers, never out of
# a `sun.security` type — so the reference is warned away rather than kept. Caught by running
# `assembleRelease`; `assembleDebug` does not minify and says nothing about it.
-dontwarn sun.security.x509.**

# The three optional SLF4J bindings sshj's logging looks for and this app does not ship. Without a
# binding it uses its own no-op logger, which is the intended shape: nothing in this app reads
# sshj's log, and the sentences a person sees come from `servers/SshProblem.kt`.
-dontwarn org.slf4j.impl.**
