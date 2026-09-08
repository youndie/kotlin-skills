# Module layout and build-file skeletons

Trimmed from the reference project. Coordinates come from a version catalog; only the parts that
carry a decision are shown, each with the reason.

## settings.gradle.kts

```kotlin
rootProject.name = "Mani"
enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")

pluginManagement {
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google { /* same filters */ }
        mavenCentral()
        // Any extra repository gets a content filter. Without one Gradle asks it about EVERY
        // new dependency, and on the day the host is unreachable it disables the repository and
        // fails resolution for coordinates that were never there.
        maven("https://jogamp.org/deployment/maven") {
            content { includeGroupByRegex("org\\.jogamp.*") }
        }
    }
}

include(":composeApp")
include(":androidApp")
include(":iosApp")
include(":server")
include(":server-common")
include(":server-native")
include(":shared")
```

## shared/build.gradle.kts

```kotlin
plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.androidKotlinMultiplatformLibrary)
    alias(libs.plugins.pluginSerialization)
}

kotlin {
    android { namespace = "io.github.youndie.mani.shared"; /* sdk versions from the catalog */ }
    iosArm64()
    iosSimulatorArm64()
    jvm()
    // For the native server: the contract is one for the client and both server builds, and
    // without this target :server-common cannot link.
    linuxX64()
    wasmJs { browser() }   // no dev server: a library has no page to serve

    sourceSets {
        commonMain.dependencies {
            // `api`, not `implementation`: Transaction.amount is a bignum type, so it is part
            // of the public contract. Consumers would otherwise declare the same dependency
            // themselves and drift apart on versions.
            api(libs.bignum)
            api(libs.ktor.client.resources)
            api(libs.kotlinx.datetime)
            api(libs.kotlinx.serialization.json)
        }
        commonTest.dependencies { api(libs.kotlin.test) }
    }
}
```

## server-common/build.gradle.kts

```kotlin
plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.pluginSerialization)
}

/*
 * Server code: routes, storage ports, configuration, authentication.
 *
 * The module has no `main` and builds no image; that is the job of :server (JVM) and
 * :server-native. Not aesthetics: the Ktor Gradle plugin, jib and `application` only work with
 * `kotlinJvm`, and the native build needs its own Dockerfile.
 *
 * Exactly one thing here is platform-specific: reading environment variables. Everything else,
 * token signing and password hashing included, is shared: both builds must compute the signature
 * and the hash with ONE body of code, or a token issued by one is refused by the other — silently.
 */
val productVersion = providers.gradleProperty("mani.version")

val generateVersion by tasks.registering {
    val version = productVersion
    val output = layout.buildDirectory.dir("generated/version/commonMain/kotlin")
    inputs.property("version", version)
    outputs.dir(output)
    doLast {
        val file = output.get().file("io/github/youndie/mani/ManiVersion.kt").asFile
        file.parentFile.mkdirs()
        file.writeText(
            """
            package io.github.youndie.mani

            /** Product version. Generated from `mani.version` in `gradle.properties`. */
            const val MANI_VERSION: String = "${version.get()}"

            """.trimIndent(),
        )
    }
}

kotlin {
    jvm()
    linuxX64()

    sourceSets {
        commonMain { kotlin.srcDir(generateVersion) }
        commonMain.dependencies {
            api(projects.shared)
            api(libs.ktor.server.core)
            api(libs.ktor.server.auth)
            implementation(libs.ktor.server.resources)
            implementation(libs.ktor.serialization.kotlinx.json)
            implementation(libs.ktor.server.content.negotiation)
            implementation(libs.ktor.server.cors)
            implementation(libs.ktor.server.status.pages)
            api(libs.koin.core)
            implementation(libs.koin.ktor)
            implementation(libs.cryptography.core)
            implementation(libs.cryptography.random)
        }
        jvmMain.dependencies { implementation(libs.cryptography.provider.jdk) }
        // The crypto provider must be declared in EVERY build: without it
        // CryptographyProvider.Default fails on first use, i.e. on the first login, not at build.
        val linuxX64Main by getting {
            dependencies { implementation(libs.cryptography.provider.openssl3) }
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(libs.kotlinx.coroutines.test)
        }
        jvmTest.dependencies {
            // A reference, not a product dependency: tokens used to be issued by java-jwt, and its
            // signature proves the new verifier still accepts refresh tokens already in the database.
            implementation(libs.auth0.java.jwt)
        }
    }
}
```

## server/build.gradle.kts (JVM build)

```kotlin
plugins {
    alias(libs.plugins.kotlinJvm)
    alias(libs.plugins.ktor)
    alias(libs.plugins.pluginSerialization)
    application
}

/*
 * A thin wrapper since the native build appeared: `main`, storage implementations on the official
 * driver, and image packaging. It stays because it is the build that compiles on macOS, and it
 * keeps the common module honest: whatever stops compiling for the JVM breaks here.
 */
val productVersion = providers.gradleProperty("mani.version").get()
val buildNumber = providers.gradleProperty("BUILD_NUMBER").getOrElse("snapshot")
version = "$productVersion.$buildNumber"   // one number for the product, a suffix per build

application { mainClass.set("io.github.youndie.mani.ApplicationKt") }

dependencies {
    implementation(projects.shared)
    implementation(projects.serverCommon)
    implementation(libs.ktor.server.cio)
    implementation(libs.mongodb.driver.kotlin.coroutine)
    implementation(libs.koin.ktor)
    implementation(libs.koin.logger.slf4j)
    implementation(libs.logback)

    testImplementation(libs.ktor.server.tests)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.koin.test)
    testImplementation(libs.de.flapdoodle.embed.mongo)
}
```

## server-native/build.gradle.kts

```kotlin
import org.jetbrains.kotlin.gradle.plugin.mpp.NativeBuildType

plugins {
    alias(libs.plugins.kotlinMultiplatform)
    alias(libs.plugins.pluginSerialization)
}

/*
 * One target, linuxX64 only: the native driver publishes for it and nothing else. Consequence:
 * this module builds and is checked on Linux only; macOS cannot link it.
 */
kotlin {
    linuxX64 {
        binaries {
            executable {
                entryPoint = "io.github.youndie.mani.main"
                baseName = "mani"
            }
            // Tests run in RELEASE too. Kotlin/Native omits type-cast checks in release builds,
            // so code that fails with a catchable ClassCastException in debug reaches undefined
            // behaviour in release. The image ships the release binary.
            test(listOf(NativeBuildType.RELEASE))
        }
        testRuns.create("release") {
            setExecutionSourceFrom(binaries.getTest(NativeBuildType.RELEASE))
        }
    }

    sourceSets {
        val linuxX64Main by getting {
            dependencies {
                implementation(projects.serverCommon)
                implementation(projects.shared)
                implementation(libs.ktor.server.cio)
                implementation(libs.koin.ktor)
                implementation(libs.mongkn.core)          // the native MongoDB binding
                implementation(libs.kotlinx.io.core)      // static files are read by hand
                // Declared AGAIN although it arrives transitively: relying on someone else's
                // `implementation` loses the provider silently the day that dependency moves,
                // and a missing provider fails the first login, not the build.
                implementation(libs.cryptography.provider.openssl3)
            }
        }
        val linuxX64Test by getting {
            dependencies {
                implementation(libs.kotlin.test)
                implementation(libs.kotlinx.coroutines.test)
                implementation(libs.ktor.server.tests)   // testApplication exists on native
                implementation(libs.ktor.client.content.negotiation)
                implementation(libs.koin.test)
            }
        }
    }
}
```

## composeApp/build.gradle.kts (the parts with a decision)

```kotlin
kotlin {
    android { namespace = "io.github.youndie.mani"; /* ... */ }
    iosArm64(); iosSimulatorArm64()
    jvm("desktop")
    wasmJs { outputModuleName = "mani"; browser { /* webpack config */ }; binaries.executable() }

    sourceSets {
        commonMain.dependencies {
            api(projects.shared)
            // Declared here, not inherited from :shared: immutable collections are for screen
            // states, and the contract has no use for them.
            implementation(libs.kotlinx.collections.immutable)
            implementation(libs.ktor.client.core)
            implementation(libs.ktor.client.auth)
            implementation(libs.ktor.client.content.negotiation)
            implementation(project.dependencies.platform(libs.koin.bom))
            implementation(libs.koin.compose)
            implementation(libs.koin.compose.viewmodel)
            implementation(libs.navigation.compose)
            implementation(libs.androidx.lifecycle.viewmodel)
            implementation(libs.multiplatform.settings)
        }
        commonTest.dependencies {
            implementation(libs.kotlin.test)
            implementation(compose.uiTest)
        }
        val desktopTest by getting {
            dependencies {
                implementation(compose.desktop.currentOs)
                implementation(compose.uiTest)
                implementation(libs.ktor.client.mock)
                implementation(libs.koin.test)
                implementation(libs.multiplatform.settings.test)
            }
        }
        androidMain.dependencies { implementation(libs.ktor.client.okhttp); implementation(libs.koin.android) }
        val desktopMain by getting { dependencies { implementation(libs.ktor.client.cio) } }
        iosMain.dependencies { implementation(libs.ktor.client.darwin) }
    }
}

compose.desktop {
    application {
        mainClass = "io.github.youndie.mani.MainKt"
        nativeDistributions {
            // The same version that /health reports and the image tag carries.
            packageVersion = providers.gradleProperty("mani.version").get()
        }
    }
}

// PINNED, NOT DERIVED. By default the resources package is built from the project group and the
// module name; setting a group later renamed it under a hundred imports.
compose.resources {
    packageOfResClass = "mani.composeapp.generated.resources"
}
```

## Platform launchers

```kotlin
// androidApp: the only thing Android contributes to the graph is its Context.
setContent {
    App(
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        platformModules = listOf(module { single<Context> { this@MainActivity } }),
    )
}

// desktop
fun main() = application { AppTheme { AppFrame(::exitApplication, title = "Mani") { App() } } }

// wasmJs: bind the nav controller to browser history so back/forward and the address bar work.
fun main() {
    ComposeViewport(document.body!!) {
        App(onNavHostReady = { window.bindToNavigation(it) })
    }
}

// iOS: the name is what Swift calls; renaming it breaks the other side.
@Suppress("ktlint:standard:function-naming")
fun MainViewController() = ComposeUIViewController { App() }
```
