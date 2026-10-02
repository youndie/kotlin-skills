#!/usr/bin/env bash
# One fixture, several shapes. $1 is the directory to build in, $2 the case.
#
# A fictional library, "ledger", in the smallest shape in which each release decision is real. None
# of it publishes anywhere: the cases are about what the agent decides and checks before and after a
# publish, and a fixture that could reach a real repository would make a wrong answer expensive.
#
# It publishes under the ACCOUNT-wide group `io.github.example`, not a group of its own, on purpose:
# that is the shape in which a path-scoped write token needs one route per coordinate, so a new
# module's first upload can be refused. It is also not on sborka's conventions — a case may have to
# say what that means for a release.
set -euo pipefail
dir="$1"; shape="${2:-library}"
mkdir -p "$dir" && cd "$dir"

library() {
  # A multiplatform library of two published modules: `core` declares a type, `standard` builds on it.
  mkdir -p core/src/commonMain/kotlin/ledger standard/src/commonMain/kotlin/ledger/standard
  cat > settings.gradle.kts <<'EOF'
rootProject.name = "ledger"
include(":core", ":standard")
EOF
  cat > gradle.properties <<'EOF'
version=0.3.0
kotlin.code.style=official
EOF
  cat > core/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
    `maven-publish`
}

group = "io.github.example"

kotlin {
    jvm()
    linuxX64()
}
EOF
  cat > core/src/commonMain/kotlin/ledger/LedgerEntry.kt <<'EOF'
package ledger

/** One line of a ledger. Every entry type the library ships implements this. */
interface LedgerEntry {
    val amountMinor: Long
}
EOF
  cat > standard/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
    `maven-publish`
}

group = "io.github.example"

kotlin {
    jvm()
    linuxX64()

    sourceSets {
        commonMain.dependencies {
            implementation(project(":core"))
        }
    }
}
EOF
  cat > standard/src/commonMain/kotlin/ledger/standard/CashEntry.kt <<'EOF'
package ledger.standard

import ledger.LedgerEntry

/** A cash movement. Public: consumers construct these and pass them around as LedgerEntry. */
class CashEntry(override val amountMinor: Long) : LedgerEntry

fun cash(amountMinor: Long): LedgerEntry = CashEntry(amountMinor)
EOF
}

case "$shape" in
  library)
    # The library as it stands before its first release.
    library
    ;;

  new-module)
    # The same library, plus a third module about to be published for the first time.
    library
    mkdir -p testing/src/commonMain/kotlin/ledger/testing
    cat > settings.gradle.kts <<'EOF'
rootProject.name = "ledger"
include(":core", ":standard", ":testing")
EOF
    cat > testing/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
    `maven-publish`
}

kotlin {
    jvm()
    linuxX64()

    sourceSets {
        commonMain.dependencies {
            api(project(":core"))
        }
    }
}
EOF
    cat > testing/src/commonMain/kotlin/ledger/testing/FakeEntry.kt <<'EOF'
package ledger.testing

import ledger.LedgerEntry

/** A test double consumers use in their own suites. */
class FakeEntry(override val amountMinor: Long = 0) : LedgerEntry
EOF
    ;;

  failed-publish)
    # The log of a snapshot publish that stopped halfway, and the module it stopped on.
    library
    sed -i.bak 's/^version=.*/version=0.1.1/' gradle.properties && rm -f gradle.properties.bak
    cat > settings.gradle.kts <<'EOF'
rootProject.name = "ledger"
include(":core", ":standard", ":reports")
EOF
    mkdir -p reports/src/commonMain/kotlin/ledger/reports
    cat > reports/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
    `maven-publish`
}

group = "io.github.example"

kotlin {
    jvm()
    linuxX64()

    sourceSets {
        commonMain.dependencies {
            api(project(":core"))
        }
    }
}
EOF
    cat > reports/src/commonMain/kotlin/ledger/reports/Totals.kt <<'EOF'
package ledger.reports

import ledger.LedgerEntry

/** The sum of a list of entries, in minor units. */
fun total(entries: List<LedgerEntry>): Long = entries.sumOf { it.amountMinor }
EOF
    cat > publish.log <<'EOF'
> Task :core:publishJvmPublicationToWipRepository
> Task :standard:publishJvmPublicationToWipRepository
> Task :reports:publishJvmPublicationToWipRepository FAILED

FAILURE: Build failed with an exception.

* What went wrong:
Execution failed for task ':reports:publishJvmPublicationToWipRepository'.
> Failed to publish publication 'jvm' to repository 'wip'
   > Could not PUT 'https://snapshots.example.invalid/io/github/example/reports-jvm/0.1.1/reports-jvm-0.1.1.jar'. Received status code 403 from server: Forbidden

BUILD FAILED in 3m 41s
EOF
    cat > NOTES.md <<'EOF'
`:reports` is a module added this week; the run above was its first publish. Since then the
snapshot repository's write token has been re-issued so that it covers the new module's path too.
Version 0.1.1 has not been announced anywhere. The repository accepts any version once and refuses
to overwrite one that is already there.
EOF
    ;;

  consumer-bump)
    # A Ktor service that consumes a library of ours which exposes Ktor through `api`.
    mkdir -p gradle server/src/commonMain/kotlin/app
    cat > settings.gradle.kts <<'EOF'
rootProject.name = "orders"
include(":server")
EOF
    cat > gradle/libs.versions.toml <<'EOF'
[versions]
ktor = "3.5.2"
# Our lifecycle library. 0.1.12 is published; its notes say it is built on Ktor 3.6.0 and that
# `lifecycle-ktor` carries `io.ktor:ktor-server-core` through `api`.
lifecycle = "0.1.4"

[libraries]
ktor-server-core = { module = "io.ktor:ktor-server-core", version.ref = "ktor" }
ktor-server-cio = { module = "io.ktor:ktor-server-cio", version.ref = "ktor" }
ktor-server-content-negotiation = { module = "io.ktor:ktor-server-content-negotiation", version.ref = "ktor" }
ktor-serialization-kotlinx-json = { module = "io.ktor:ktor-serialization-kotlinx-json", version.ref = "ktor" }
lifecycle-ktor = { module = "io.github.example.lifecycle:lifecycle-ktor", version.ref = "lifecycle" }
EOF
    cat > server/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
    kotlin("plugin.serialization") version "2.4.20"
}

kotlin {
    jvm()
    linuxX64 { binaries.executable { entryPoint = "app.main" } }

    sourceSets {
        commonMain.dependencies {
            implementation(libs.ktor.server.core)
            implementation(libs.ktor.server.cio)
            implementation(libs.ktor.server.content.negotiation)
            implementation(libs.ktor.serialization.kotlinx.json)
            implementation(libs.lifecycle.ktor)
        }
    }
}
EOF
    cat > server/src/commonMain/kotlin/app/Orders.kt <<'EOF'
package app

import io.ktor.server.application.Application
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.Serializable

@Serializable
data class NewOrder(val sku: String, val quantity: Int)

fun Application.orders() {
    routing {
        post("/orders") {
            val order = call.receive<NewOrder>()
            call.respond(order)
        }
    }
}
EOF
    ;;

  *)
    # A typo in a case's setup must not hand the agent an empty directory and call it a fixture.
    echo "setup-fixture.sh: unknown shape '$shape'" >&2
    exit 2
    ;;
esac

git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=eval@example.invalid -c user.name=eval commit -qm "fixture" 2>/dev/null || true
