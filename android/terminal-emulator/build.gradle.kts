// Vendored from termux/termux-app (Apache 2.0). The upstream build file is Groovy, publishes to
// Maven, and builds `src/main/jni` with ndk-build for the pty. None of that applies here: this
// module is consumed by source, from one app, and Terminal Deck vendors no native code — see
// VENDORED.md and MODIFICATIONS.md at the root of this directory.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.termux.emulator"
    compileSdk = 35

    defaultConfig {
        minSdk = 26
        consumerProguardFiles("proguard-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        // Upstream code, vendored deliberately unmodified apart from TerminalSession. Lint findings
        // here are findings against Termux, and fixing them silently would make the next rebase a
        // guessing game about which edits were ours.
        checkDependencies = false
        abortOnError = false
    }
}

dependencies {
    implementation(libs.androidx.annotation)
}
