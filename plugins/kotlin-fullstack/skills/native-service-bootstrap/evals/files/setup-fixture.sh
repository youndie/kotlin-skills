#!/usr/bin/env bash
# One fixture, several shapes. $1 is the directory to build in, $2 the case.
#
# Deliberately NOT a copy of keel: these cases are about what the agent decides, and handing it a
# finished service would let it copy an answer rather than reach one. What each shape carries is the
# smallest context in which the decision is real.
set -euo pipefail
dir="$1"; shape="${2:-empty}"
mkdir -p "$dir" && cd "$dir"

case "$shape" in
  empty)
    # Nothing. The agent is asked to stand a service up.
    ;;

  running-service)
    # A service that already builds, so a case can ask for a change rather than a creation.
    mkdir -p server/src/commonMain/kotlin/app
    cat > settings.gradle.kts <<'EOF'
rootProject.name = "fixture"
include(":server")
EOF
    cat > server/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.10"
}

kotlin {
    jvm()
    linuxX64 { binaries.executable { entryPoint = "app.main" } }
}
EOF
    cat > server/src/commonMain/kotlin/app/Main.kt <<'EOF'
package app

fun main() {
    println("fixture")
}
EOF
    ;;

  sweep-loop)
    # A background loop that will be asked to do work and handle failure.
    mkdir -p server/src/commonMain/kotlin/app
    cat > server/src/commonMain/kotlin/app/Outbox.kt <<'EOF'
package app

interface Outbox {
    suspend fun pending(limit: Int): List<String>

    suspend fun settle(id: String)
}
EOF
    ;;
esac

git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=eval@example.invalid -c user.name=eval commit -qm "fixture" 2>/dev/null || true
