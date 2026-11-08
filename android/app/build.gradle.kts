import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val workspaceDir = rootProject.projectDir.parentFile
val rustCoreDir = workspaceDir.resolve("native/getfor_core")
val rustJniDir = layout.buildDirectory.dir("rustJniLibs")
val releaseKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")

data class RustAndroidTarget(
    val abi: String,
    val rustTarget: String,
    val clangPrefix: String,
)

val rustAndroidTargets =
    listOf(
        RustAndroidTarget("arm64-v8a", "aarch64-linux-android", "aarch64-linux-android"),
        RustAndroidTarget("x86_64", "x86_64-linux-android", "x86_64-linux-android"),
    )

android {
    namespace = "com.ysh0566.getfor"
    compileSdk = flutter.compileSdkVersion
    // NDK r28 aligns native libraries for Android devices with 16 KB pages.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.ysh0566.getfor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeystorePath != null) {
            create("release") {
                storeFile = file(releaseKeystorePath)
                storePassword = requireNotNull(System.getenv("ANDROID_KEYSTORE_PASSWORD"))
                keyAlias = requireNotNull(System.getenv("ANDROID_KEY_ALIAS"))
                keyPassword = requireNotNull(System.getenv("ANDROID_KEY_PASSWORD"))
            }
        }
    }

    buildTypes {
        release {
            // CI restores the persistent signing key from Secrets; local builds keep their current key.
            signingConfig = signingConfigs.getByName(if (releaseKeystorePath != null) "release" else "debug")
        }
    }
}

dependencies {
    implementation("androidx.credentials:credentials:1.6.0")
    testImplementation("junit:junit:4.13.2")
}

android.buildTypes.configureEach {
    // Flutter seeds all default ABIs on each build type; V1 intentionally excludes 32-bit Arm.
    ndk.abiFilters.clear()
    ndk.abiFilters += listOf("arm64-v8a", "x86_64")
}

val hostTag =
    when {
        System.getProperty("os.name").startsWith("Mac") -> "darwin-x86_64"
        System.getProperty("os.name").startsWith("Windows") -> "windows-x86_64"
        else -> "linux-x86_64"
    }
val clangSuffix = if (hostTag.startsWith("windows")) ".cmd" else ""
val sdkProperties = Properties().apply {
    rootProject.file("local.properties").inputStream().use { load(it) }
}
val androidSdkDir = file(requireNotNull(sdkProperties.getProperty("sdk.dir")))
val androidNdkDir = androidSdkDir.resolve("ndk/${android.ndkVersion}")

val rustBuildTasks =
    rustAndroidTargets.map { target ->
        tasks.register<Exec>("buildRust${target.abi.replace("-", "_")}") {
            val outputDirectory = rustJniDir.map { it.dir(target.abi) }
            val outputLibrary = outputDirectory.map { it.file("libgetfor_core.so") }
            val linker =
                androidNdkDir.resolve(
                    "toolchains/llvm/prebuilt/$hostTag/bin/${target.clangPrefix}${android.defaultConfig.minSdk}-clang$clangSuffix",
                )
            val archiver =
                androidNdkDir.resolve(
                    "toolchains/llvm/prebuilt/$hostTag/bin/llvm-ar${if (hostTag.startsWith("windows")) ".exe" else ""}",
                )
            val rustEnvironmentTarget = target.rustTarget.uppercase().replace("-", "_")
            val ccEnvironmentTarget = target.rustTarget.replace("-", "_")

            inputs.files(
                rustCoreDir.resolve("Cargo.toml"),
                rustCoreDir.resolve("Cargo.lock"),
                fileTree(rustCoreDir.resolve("src")),
            )
            inputs.property("ndkVersion", android.ndkVersion)
            inputs.property("rustLinkFlags", "16kb-pages")
            outputs.file(outputLibrary)
            workingDir(workspaceDir)
            environment(
                "CARGO_TARGET_${rustEnvironmentTarget}_LINKER",
                linker.absolutePath,
            )
            environment("CC_$ccEnvironmentTarget", linker.absolutePath)
            environment("AR_$ccEnvironmentTarget", archiver.absolutePath)
            // Cargo links Rust cdylibs directly, so pass the page alignment flags explicitly.
            environment(
                "CARGO_TARGET_${rustEnvironmentTarget}_RUSTFLAGS",
                "-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384",
            )
            commandLine(
                "cargo",
                "build",
                "--manifest-path",
                rustCoreDir.resolve("Cargo.toml").absolutePath,
                "--target",
                target.rustTarget,
                "--release",
            )
            doLast {
                copy {
                    from(rustCoreDir.resolve("target/${target.rustTarget}/release/libgetfor_core.so"))
                    into(outputDirectory.get().asFile)
                }
            }
        }
    }

android.sourceSets.getByName("main").jniLibs.srcDir(rustJniDir)
tasks.named("preBuild").configure { dependsOn(rustBuildTasks) }

flutter {
    source = "../.."
}
