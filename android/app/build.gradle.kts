import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

/**
 * The release signing key, if this machine has one.
 *
 * `keystore.properties` and `keystore/` are both gitignored, so a fresh clone has neither and the
 * `signingConfig` below stays null — which makes `assembleRelease` produce an *unsigned* APK.
 *
 * That is the intended failure. The tempting alternative is to fall back to the debug keystore so
 * the build always yields something installable, and it is a trap: the debug key is a well-known
 * keypair that ships with the SDK on every developer's machine, so anyone can forge an update to
 * an app signed with it. An unsigned APK refuses to install and says so; a debug-signed release
 * installs happily and is the bug you find later.
 */
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "dev.terminaldeck.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.terminaldeck.android"

        // API 26 (Android 8.0), and the reasons are all in this module rather than taste:
        //
        //  - `TerminalView`'s autofill path is `@RequiresApi(O)` throughout. Below 26 that code is
        //    dead weight guarded by version checks we would have to keep honest for devices nobody
        //    in this audience owns.
        //  - The transport is TLS to a machine on a tailnet. API 26 is comfortably past the
        //    releases where TLS 1.2 was off by default and where a modern OkHttp needs a security
        //    provider installed at runtime to negotiate anything current.
        //  - `java.time` and the rest of the desugaring surface come for free at 26, so the
        //    protocol layer can be written in plain Kotlin without a desugar config.
        //  - The audience is developers running a coding agent on a Mac. The floor is not what
        //    limits who can install this.
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "0.10.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")

                // v1 as well as v2/v3 because minSdk is 26: APK Signature Scheme v2 arrived in 24,
                // but an APK with no v1 signature at all is refused by some 7.x/8.x installers, and
                // this build claims to run there.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        // For BuildConfig.VERSION_NAME — the one number HostVersion compares against the host's
        // `welcome.appVersion` to decide the single honest "update this server from a desktop"
        // sentence. Nothing else reads BuildConfig.
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    testOptions {
        unitTests {
            /*
             * `android.jar` on the unit-test classpath is stubs, and every method in it throws
             * `Stub!` unless this is set. The types that matter here are deliberately free of
             * Android — the vault is a file and a cipher, the transport is OkHttp, the collection of
             * machines is plain Kotlin — but two leaves are not: `android.util.Log`, which the
             * transport writes to on every error path, and `android.os.Build`, which supplies the
             * default device name. Both are things a test is entitled to have do nothing.
             *
             * It does not make Android testable here, and it is not meant to: anything that needs a
             * real framework belongs in `androidTest`.
             */
            isReturnDefaultValues = true
        }
    }
}

dependencies {
    implementation(project(":terminal-view"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.bouncycastle)

    testImplementation(libs.junit)
    // The upload pump is a coroutine driven by acknowledgements, so its tests need a scheduler they
    // can drive rather than a clock they have to wait on.
    testImplementation(libs.kotlinx.coroutines.test)
    // See the note in libs.versions.toml: the credential-isolation test needs a real socket.
    testImplementation(libs.mockwebserver)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
}
