#!/usr/bin/env bash
# One fixture, two shapes. $1 is the directory to build in, $2 the case.
#
# `two-build` is a server compiled for the JVM and for linuxX64 about to gain a piece of logic;
# `blocking-jvm` is a JVM server with JDBC handlers about to change its engine. Nothing here
# builds, and no case asks for a build.
set -euo pipefail
dir="$1"; shape="${2:-two-build}"
mkdir -p "$dir/gradle"

case "$shape" in
  two-build)
    common="$dir/server-common/src"
    mkdir -p "$common/commonMain/kotlin/app/config" "$common/jvmMain/kotlin/app/config" "$common/linuxX64Main/kotlin/app/config" \
             "$dir/server/src/main/kotlin/app" "$dir/server-native/src/linuxX64Main/kotlin/app"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

One Ktor server compiled twice from one source: `:server` (JVM, Netty) and `:server-native`
(linuxX64, CIO) over `:server-common`, which holds everything but the entry points and storage.
The only `expect` in the project is `readEnv`.
EOF
    cat > "$dir/settings.gradle.kts" <<'EOF'
rootProject.name = "fixture"
include(":shared", ":server-common", ":server", ":server-native")
EOF
    cat > "$dir/gradle/libs.versions.toml" <<'EOF'
[versions]
kotlin = "2.4.20"
ktor = "3.6.0"

[libraries]
ktor-server-core = { module = "io.ktor:ktor-server-core", version.ref = "ktor" }
ktor-server-cio = { module = "io.ktor:ktor-server-cio", version.ref = "ktor" }
ktor-server-netty = { module = "io.ktor:ktor-server-netty", version.ref = "ktor" }
EOF
    cat > "$dir/server-common/build.gradle.kts" <<'EOF'
// The whole server except the entry points and the calls into the database. No `main`, no image.
plugins { kotlin("multiplatform") }

kotlin {
    jvm()
    linuxX64()
    sourceSets {
        commonMain.dependencies { api(libs.ktor.server.core) }
    }
}
EOF
    cat > "$common/commonMain/kotlin/app/config/Env.kt" <<'EOF'
package app.config

/** `System.getenv` on the JVM, `getenv` on POSIX: the one thing here that is a platform API. */
expect fun readEnv(name: String): String?
EOF
    cat > "$common/jvmMain/kotlin/app/config/Env.jvm.kt" <<'EOF'
package app.config

actual fun readEnv(name: String): String? = System.getenv(name)
EOF
    cat > "$common/linuxX64Main/kotlin/app/config/Env.linuxX64.kt" <<'EOF'
package app.config

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import platform.posix.getenv

@OptIn(ExperimentalForeignApi::class)
actual fun readEnv(name: String): String? = getenv(name)?.toKString()
EOF
    ;;

  blocking-jvm)
    src="$dir/server/src/main/kotlin/app"
    mkdir -p "$src"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

A Ktor server on the JVM, one module, deployed as a pod with 2 CPUs. Every handler reads or
writes PostgreSQL through plain JDBC on a HikariCP pool of 20.
EOF
    cat > "$dir/settings.gradle.kts" <<'EOF'
rootProject.name = "fixture"
include(":server")
EOF
    cat > "$src/Application.kt" <<'EOF'
package app

import io.ktor.server.application.Application
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import javax.sql.DataSource

fun main() {
    embeddedServer(CIO, port = 8080) { module(TODO("the pool")) }.start(wait = true)
}

fun Application.module(pool: DataSource) {
    routing {
        get("/orders/{id}") {
            // Blocking JDBC, straight in the handler: about 5 ms per call.
            val title = pool.connection.use { c ->
                c.prepareStatement("select title from orders where id = ?").use {
                    it.setString(1, call.parameters["id"])
                    it.executeQuery().use { rows -> if (rows.next()) rows.getString(1) else null }
                }
            }
            call.respondText(title ?: "none")
        }
    }
}
EOF
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
