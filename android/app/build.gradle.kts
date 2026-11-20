import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.oiiqt.android"
    compileSdk = 35

    defaultConfig {
        // 只在 applicationId 上改包名：namespace 决定 R 类与 BuildConfig 的包位置，
        // 连它一起改要同步 60+ 个源文件的 package/import 与 AndroidManifest 的类名，
        // 漏一处就是运行时崩溃；而系统/应用市场认的「包名」只有 applicationId。
        applicationId = "com.moviepilottools.mptools"
        minSdk = 26
        targetSdk = 35
        // 25~27 是 1.0.10 期间的本地测试包（未发布），跳过以免装机时被判定为降级
        // 2026-11-20 重建仓库：对外版本号重新从 1.0.1 起，versionCode 保持单调递增（31），
        // 否则装不上已装的旧包（系统按 versionCode 判降级）
        versionCode = 31
        versionName = "1.0.1"
        resourceConfigurations += listOf("zh", "en")
    }

    signingConfigs {
        // 密钥不随仓库分发：local.properties 配了路径就用它，否则按顺序找仓库内常见位置
        val localProps = Properties().apply {
            val file = rootProject.file("local.properties")
            if (file.exists()) file.inputStream().use { load(it) }
        }
        val keystoreFile = localProps.getProperty("oiiqt.storeFile")?.let { rootProject.file(it) }
            ?: listOf(
                rootProject.file("keystore/oiiqt.jks"),
                file("../keystore/oiiqt.jks")
            ).firstOrNull { it.exists() }
        // 口令一律只从 local.properties 读（该文件不进仓库），代码里不留任何默认口令
        val storePass = localProps.getProperty("oiiqt.storePassword")
        val keyPass = localProps.getProperty("oiiqt.keyPassword")
        val keyAliasName = localProps.getProperty("oiiqt.keyAlias")
        if (keystoreFile != null && storePass != null && keyPass != null && keyAliasName != null) {
            create("release") {
                storeFile = keystoreFile
                storePassword = storePass
                keyAlias = keyAliasName
                keyPassword = keyPass
            }
        } else if (keystoreFile != null) {
            logger.lifecycle("⚠️ 找到 keystore 但 local.properties 缺少 oiiqt.storePassword / keyPassword / keyAlias，release 产物将不签名")
        } else {
            logger.lifecycle("⚠️ 未找到签名密钥 keystore/oiiqt.jks，release 产物将不签名")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            // ⚠️ 这个后缀会让 debug 包变成**另一个 App**（com.moviepilottools.mptools.debug）：
            // 桌面上点开的是正式包 com.moviepilottools.mptools，所以「改了代码却没生效」。
            // 真机测试一律用 assembleRelease + adb install -r，桌面包才是唯一入口。
            applicationIdSuffix = ".debug"
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
        // 「设置 → 关于」直接读真实版本号，避免手写版本和实际包对不上
        buildConfig = true
    }

    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.navigation:navigation-compose:2.8.4")

    // 音乐播放：MediaPlayer 播不了 24bit/高码率 FLAC 的网络流（error 1/-2147483648），
    // 换 ExoPlayer。它还能带请求头、支持 HTTP Range 与更多音频编码。
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-common:1.4.1")
    // MediaSession：锁屏/通知栏播放控制 + 前台播放服务
    implementation("androidx.media3:media3-session:1.4.1")

    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("io.coil-kt:coil-compose:2.7.0")
    // 真背景模糊（玻璃底栏）：Compose 原生只能模糊自己，采样背后内容要靠 Haze。
    // 1.6.x 对应 Compose 1.7（当前 BOM 2024.12.01）；2.x 需要 Compose 1.8+ 故不用。
    implementation("dev.chrisbanes.haze:haze:1.6.10")
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    debugImplementation("androidx.compose.ui:ui-tooling")
}
