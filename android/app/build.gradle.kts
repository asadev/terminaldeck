import java.io.File
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

/**
 * The installer, carried into the APK from the one file this repo ships it as.
 *
 * `scripts/install-headless.sh` is what the desktop uploads over SFTP and what iOS references
 * straight out of `project.yml`. The phone now runs it over its own SSH connection — see
 * `servers/ScriptLibrary.kt` — so it has to be in the APK, and copying it here rather than keeping
 * a second copy under `assets/` means a change to the installer reaches all three clients in the
 * commit that makes it.
 *
 * A typed task with a declared output directory rather than a plain `Copy`, because of how it is
 * wired below. `sourceSets.assets.srcDir(<a Copy provider>)` was tried first and **silently ships
 * an APK without the file**: the directory is added to the source set, nothing tells
 * `mergeDebugAssets` that a task produces it, the task never runs, and the only symptom is an
 * Install button that reports *"this copy of the app does not carry the installer"* on a phone.
 * Measured, by unzipping the APK. `addGeneratedSourceDirectory` is the API that carries the
 * dependency with it, and it takes a `DirectoryProperty`.
 */
abstract class CopyHeadlessInstaller : DefaultTask() {

    @get:InputFile
    abstract val source: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val target = outputDir.get().asFile
        target.mkdirs()
        source.get().asFile.copyTo(File(target, "install-headless.sh"), overwrite = true)
    }
}

val installerAssets = tasks.register<CopyHeadlessInstaller>("copyHeadlessInstaller") {
    source.set(rootProject.file("../scripts/install-headless.sh"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(
            installerAssets,
            CopyHeadlessInstaller::outputDir,
        )
    }
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
        versionCode = 4
        /**
         * **This number decides which host a server gets**, so it is not cosmetic and it is not
         * allowed to lag the repo.
         *
         * `ServerScripts.hostPackage` derives the release asset from it —
         * `releases/download/v<versionName>/terminaldeck-<versionName>.tgz` — so an install from
         * this phone puts exactly this version on somebody's server. Measured on a bare Hetzner box
         * on 2026-08-24, with this left at 0.10.0 while the repo was 0.10.1: the install succeeded,
         * systemd started it, the card said *"is a machine of its own now"* — and the connect step
         * then drew a refusal, because the `Server address` block `status` prints landed in
         * **v0.10.1** (`src/headless/cli.ts`, first tagged there) and a server address is the only
         * thing a phone can dial. Every step reported success and the flow dead-ended.
         *
         * iOS carries `MARKETING_VERSION: "0.10.1"` in `ios/project.yml` for the same reason. When
         * one moves, this moves.
         */
        versionName = "0.10.1"

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
        /*
         * BouncyCastle ships multi-release jars, and sshj pulls two more of them beside the one
         * this app already had — `bcpkix` and `bcutil` next to `bcprov`. All three carry the same
         * `META-INF/versions/9/OSGI-INF/MANIFEST.MF`, and `mergeDebugJavaResource` refuses a
         * three-way duplicate with an error naming a file nothing in this app reads. Excluded
         * rather than picked-first: it is OSGi metadata for a container Android is not.
         */
        resources.excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF"
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
    implementation(libs.sshj)

    testImplementation(libs.junit)
    // The upload pump is a coroutine driven by acknowledgements, so its tests need a scheduler they
    // can drive rather than a clock they have to wait on.
    testImplementation(libs.kotlinx.coroutines.test)
    // See the note in libs.versions.toml: the credential-isolation test needs a real socket.
    testImplementation(libs.mockwebserver)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
}
