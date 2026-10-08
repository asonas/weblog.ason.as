plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.asonas.weblog.photoinbox"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.asonas.weblog.PhotoInbox"
        minSdk = 26
        targetSdk = 36
        versionCode = providers.gradleProperty("ciVersionCode").orElse("1").get().toInt()
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    signingConfigs {
        if (System.getenv("ANDROID_KEYSTORE_PATH") != null) {
            create("ci") {
                storeFile = file(System.getenv("ANDROID_KEYSTORE_PATH"))
                storeType = "PKCS12"
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = "upload"
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (signingConfigs.findByName("ci") != null) {
                signingConfig = signingConfigs.getByName("ci")
            }
        }
    }

    buildFeatures {
        viewBinding = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    lint {
        disable += "GradleDependency"
    }
}

dependencies {
    constraints {
        implementation("androidx.fragment:fragment:1.8.5") {
            because("Code Scanner pulls Fragment 1.0.0, which is incompatible with Activity Result APIs")
        }
    }
    implementation("androidx.activity:activity-ktx:1.10.0")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.recyclerview:recyclerview:1.4.0")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.work:work-testing:2.10.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
