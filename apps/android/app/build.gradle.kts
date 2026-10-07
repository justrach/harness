plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// ── Native core (crates/mobile) ─────────────────────────────────────────────────────────────────────────────────
//
// The sync protocol is Rust, shared with the desktop (crates/doc, crates/sync). Gradle builds it twice:
//  - for the host, in cargo's dev profile: the JVM unit tests load that library, and UniFFI reads the Kotlin
//    bindings out of it (the shipped libraries are stripped, so they no longer carry the metadata);
//  - for each Android ABI, in the `mobile` profile, linked with the NDK's clang, into the APK's jniLibs.
// `-Pharness.abis=x86_64` limits the ABIs (CI's emulator job only needs one).

val repoRoot: File = rootProject.projectDir.resolve("../..").canonicalFile
val cargo: String = listOf(System.getenv("CARGO"), System.getProperty("user.home") + "/.cargo/bin/cargo")
    .firstOrNull { it != null && File(it).canExecute() } ?: "cargo"
val hostLibName: String = System.getProperty("os.name").lowercase().let { os ->
    when {
        os.contains("mac") -> "libharness_mobile.dylib"
        os.contains("windows") -> "harness_mobile.dll"
        else -> "libharness_mobile.so"
    }
}
val hostLibDir: File = repoRoot.resolve("target/debug")
val uniffiBindingsDir = layout.buildDirectory.dir("generated/uniffi/kotlin")
val nativeLibsDir = layout.buildDirectory.dir("generated/jniLibs")
val androidTargets = mapOf("arm64-v8a" to "aarch64-linux-android", "x86_64" to "x86_64-linux-android")
val selectedAbis: List<String> = (findProperty("harness.abis") as String?)
    ?.split(',')?.map(String::trim)?.filter(String::isNotEmpty)
    ?: androidTargets.keys.toList()
require(selectedAbis.all(androidTargets::containsKey)) { "harness.abis must be a subset of ${androidTargets.keys}" }

val cargoBuildHost = tasks.register<Exec>("cargoBuildHost") {
    group = "rust"
    description = "Builds the native core for this machine (JVM unit tests and binding generation)."
    workingDir = repoRoot
    commandLine(cargo, "build", "-p", "harness-mobile", "--lib")
}

val generateUniffiBindings = tasks.register<Exec>("generateUniffiBindings") {
    group = "rust"
    description = "Generates the Kotlin bindings for the native core."
    dependsOn(cargoBuildHost)
    workingDir = repoRoot
    val out = uniffiBindingsDir.get().asFile
    // The library is the input: a Rust change rebuilds it, which regenerates the bindings.
    inputs.file(hostLibDir.resolve(hostLibName))
    inputs.file(repoRoot.resolve("crates/mobile/uniffi.toml"))
    outputs.dir(out)
    doFirst { out.deleteRecursively() }
    commandLine(
        cargo, "run", "-q", "-p", "harness-mobile", "--features", "bindgen", "--bin", "uniffi-bindgen", "--",
        "generate", "--library", hostLibDir.resolve(hostLibName).path, "--language", "kotlin",
        "--out-dir", out.path, "--no-format",
    )
}

val cargoBuildAndroid = tasks.register("cargoBuildAndroid") {
    group = "rust"
    description = "Builds the native core for every selected Android ABI into the APK's jniLibs."
}

selectedAbis.forEach { abi ->
    val triple = androidTargets.getValue(abi)
    val envTriple = triple.uppercase().replace('-', '_')
    val task = tasks.register<Exec>("cargoBuild" + abi.split('-', '_').joinToString("") { it.replaceFirstChar(Char::uppercase) }) {
        group = "rust"
        description = "Builds the native core for $abi."
        workingDir = repoRoot
        commandLine(cargo, "build", "-p", "harness-mobile", "--lib", "--profile", "mobile", "--target", triple)
        doFirst {
            val minSdk = android.defaultConfig.minSdk ?: 26
            val hostTag = System.getProperty("os.name").lowercase().let { os ->
                when {
                    os.contains("mac") -> "darwin-x86_64"
                    os.contains("windows") -> "windows-x86_64"
                    else -> "linux-x86_64"
                }
            }
            val bin = android.ndkDirectory.resolve("toolchains/llvm/prebuilt/$hostTag/bin")
            val clang = bin.resolve("$triple$minSdk-clang").path
            environment("CC_${triple.replace('-', '_')}", clang)
            environment("AR_${triple.replace('-', '_')}", bin.resolve("llvm-ar").path)
            environment("CARGO_TARGET_${envTriple}_LINKER", clang)
        }
        doLast {
            copy {
                from(repoRoot.resolve("target/$triple/mobile/libharness_mobile.so"))
                into(nativeLibsDir.get().asFile.resolve(abi))
            }
        }
    }
    cargoBuildAndroid.configure { dependsOn(task) }
}

tasks.named("preBuild") { dependsOn(generateUniffiBindings) }
// Only packaging needs the Android libraries, so a unit-test run never cross-compiles.
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }
    .configureEach { dependsOn(cargoBuildAndroid) }
tasks.withType<Test>().configureEach {
    dependsOn(cargoBuildHost)
    systemProperty("jna.library.path", hostLibDir.path)
}

composeCompiler {
    stabilityConfigurationFiles.add(rootProject.layout.projectDirectory.file("compose-stability.conf"))
}

android {
    namespace = "harness.codegraff.android"
    compileSdk = 35
    // The NDK's clang links the native core (crates/mobile) for each ABI; see the Rust section below.
    ndkVersion = "27.1.12297006"

    defaultConfig {
        applicationId = "harness.codegraff.android"
        minSdk = 26
        targetSdk = 35
        // CI numbers release builds; a local build is 1.
        versionCode = System.getenv("ANDROID_VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Only the ABIs the native core is built for. Without this, the 32-bit folders JNA and androidx bring
        // would let a 32-bit phone install an APK whose core cannot load.
        ndk { abiFilters += selectedAbis }
    }

    signingConfigs {
        // Release signing comes from the environment (repository secrets in CI). Without it the release
        // bundle is built unsigned, which is what a pull request or a fork produces.
        System.getenv("ANDROID_KEYSTORE_FILE")?.let { keystore ->
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release")
        }
        // Release-like build signed with the debug key, for measuring performance
        // on a device or emulator (a debug build is several times slower in Compose).
        create("perf") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
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
    }
    sourceSets.getByName("main") {
        java.srcDir(uniffiBindingsDir)
        jniLibs.srcDir(nativeLibsDir)
    }
    testOptions {
        // The monitor calls Trace and Log, which do nothing on the JVM.
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.compose.material.icons.core)
    implementation(libs.androidx.adaptive)
    implementation(libs.androidx.adaptive.layout)
    implementation(libs.androidx.adaptive.navigation)
    implementation(libs.androidx.profileinstaller)
    implementation(libs.kotlinx.coroutines.core)
    // UniFFI's Kotlin bindings call the native core through JNA: the AAR carries the Android dispatch libraries,
    // the plain jar the desktop ones the JVM unit tests load.
    implementation(libs.jna) { artifact { type = "aar" } }
    testImplementation(libs.jna)

    testImplementation(libs.junit)
    testImplementation(libs.org.json)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    debugImplementation(libs.compose.ui.test.manifest)
    testImplementation(libs.kotlinx.coroutines.test)
}
