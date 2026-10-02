#!/usr/bin/env bash
# One fixture, several shapes. $1 is the directory to build in, $2 the case.
#
# Each shape is the smallest context in which a decision this skill is about is real, and each one
# reproduces a defect that shipped somewhere public (see ../README.md). The C library is fictional
# (`ev`, `db`): a known library's name would let the agent answer from memory of that library rather
# than from the shape in front of it. Nothing here needs to build — the cases grade decisions and
# code, not a link on the grader's machine.
set -euo pipefail
dir="$1"; shape="${2:?shape}"
mkdir -p "$dir" && cd "$dir"

common_settings() {
    cat > settings.gradle.kts <<'EOF'
rootProject.name = "fixture"
include(":ev-core")
EOF
}

case "$shape" in
  bundle-binding)
    # kafkakn B-13 in miniature: the archives are named as linker options on the module's OWN
    # binaries, so its tests link and a stranger's build will not.
    common_settings
    mkdir -p ev-core/src/nativeInterop/cinterop ev-core/src/linuxX64Main/kotlin/ev ci/ev
    cat > ev-core/src/nativeInterop/cinterop/ev.def <<'EOF'
headers = ev/ev.h
headerFilter = ev/**
package = ev.c
EOF
    cat > ev-core/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
    `maven-publish`
}

group = "org.example.ev"
version = "0.1.0"

// Built by ci/ev/build.sh: libev.a plus a static OpenSSL, into a cache outside the tree.
val bundle = "${System.getProperty("user.home")}/.cache/ev/bundle"

kotlin {
    jvm()
    linuxX64 {
        compilations.getByName("main").cinterops.create("ev") {
            definitionFile.set(file("src/nativeInterop/cinterop/ev.def"))
            includeDirs("$bundle/include")
        }
        binaries.all {
            linkerOpts("$bundle/lib/libev.a", "$bundle/lib/libssl.a", "$bundle/lib/libcrypto.a")
        }
    }
}
EOF
    cat > ev-core/src/linuxX64Main/kotlin/ev/Ev.kt <<'EOF'
package ev

import kotlinx.cinterop.ExperimentalForeignApi

@OptIn(ExperimentalForeignApi::class)
class Ev {
    private val handle = checkNotNull(ev.c.ev_new()) { "ev_new failed" }

    fun close() = ev.c.ev_destroy(handle)
}
EOF
    cat > ci/ev/build.sh <<'EOF'
#!/usr/bin/env bash
# Builds libev and a static OpenSSL into ~/.cache/ev/bundle (lib/, include/). Not shown.
set -euo pipefail
echo "bundle at $HOME/.cache/ev/bundle"
EOF
    chmod +x ci/ev/build.sh
    ;;

  host-built)
    # kafkakn research §1.3: a C library built by the host compiler on a current distribution,
    # linked against Kotlin/Native's glibc 2.19 sysroot.
    common_settings
    mkdir -p ev-core/src/nativeInterop/cinterop ci/ev
    cat > ev-core/src/nativeInterop/cinterop/ev.def <<'EOF'
headers = ev/ev.h
headerFilter = ev/**
package = ev.c
staticLibraries = libev.a
EOF
    cat > ci/ev/build.sh <<'EOF'
#!/usr/bin/env bash
# Runs on the CI runner (ubuntu-24.04, gcc 13, glibc 2.39).
#
# ev's configure picks C11 <threads.h> when the libc has it and otherwise falls back to the
# tinycthread copy it bundles (src/tinycthread.c); getentropy() is used only under HAVE_GETENTROPY.
set -euo pipefail
VERSION=2.4.0
OUT="$HOME/.cache/ev/bundle"
curl -sfL -o /tmp/ev.tar.gz "https://example.org/ev/ev-$VERSION.tar.gz"
mkdir -p /tmp/ev && tar xzf /tmp/ev.tar.gz -C /tmp/ev --strip-components=1
cd /tmp/ev
./configure --prefix="$OUT" --enable-static --disable-shared
make -j"$(nproc)" && make install
EOF
    chmod +x ci/ev/build.sh
    cat > link-error.txt <<'EOF'
> Task :ev-core:linkDebugTestLinuxX64 FAILED
e: /home/runner/.konan/dependencies/llvm-21-x86_64-linux-essentials/bin/ld.lld invocation reported errors

ld.lld: error: undefined symbol: mtx_lock
>>> referenced by rdthread.c in archive /home/runner/.cache/ev/bundle/lib/libev.a
ld.lld: error: undefined symbol: thrd_create
>>> referenced by rdthread.c in archive /home/runner/.cache/ev/bundle/lib/libev.a
ld.lld: error: undefined symbol: strlcpy
>>> referenced by evconf.c in archive /home/runner/.cache/ev/bundle/lib/libev.a
ld.lld: error: undefined symbol: getentropy
>>> referenced by evrand.c in archive /home/runner/.cache/ev/bundle/lib/libev.a
ld.lld: error: undefined symbol: __isoc23_strtol
>>> referenced by evconf.c in archive /home/runner/.cache/ev/bundle/lib/libev.a
EOF
    ;;

  variadic-header)
    # librdkafka's rd_kafka_producev / rd_kafka_produceva, renamed: a variadic function whose
    # argument list is built by macros, and a non-variadic sibling taking an array.
    common_settings
    mkdir -p ev-core/src/nativeInterop/cinterop ev-core/src/linuxX64Main/kotlin/ev include/ev
    cat > include/ev/ev.h <<'EOF'
#include <stddef.h>
#include <stdint.h>

typedef struct ev_s ev_t;

typedef enum {
    EV_VTYPE_END = 0,
    EV_VTYPE_TOPIC,      /* const char *            */
    EV_VTYPE_VALUE,      /* const void *, size_t    */
    EV_VTYPE_PARTITION,  /* int32_t                 */
    EV_VTYPE_TIMESTAMP   /* int64_t, milliseconds   */
} ev_vtype_t;

#define EV_V_END             EV_VTYPE_END
#define EV_V_TOPIC(t)        EV_VTYPE_TOPIC, (const char *)(t)
#define EV_V_VALUE(p, len)   EV_VTYPE_VALUE, (const void *)(p), (size_t)(len)
#define EV_V_PARTITION(p)    EV_VTYPE_PARTITION, (int32_t)(p)
#define EV_V_TIMESTAMP(ts)   EV_VTYPE_TIMESTAMP, (int64_t)(ts)

/* Emits one event. Tag/value pairs built with the EV_V_* macros, terminated by EV_V_END.
   The payload is copied before the call returns. Returns 0 or a negative error code. */
int ev_emit(ev_t *ev, ...);

typedef struct {
    ev_vtype_t vtype;
    union {
        const char *topic;
        struct { const void *ptr; size_t size; } value;
        int32_t partition;
        int64_t timestamp;
    } u;
} ev_vu_t;

/* The same as ev_emit, with the pairs as an array of `count` elements (no terminator).
   The payload is copied before the call returns. */
int ev_emitv(ev_t *ev, const ev_vu_t *vus, size_t count);

const char *ev_strerror(int code);   /* static storage; never freed */
EOF
    cat > ev-core/src/nativeInterop/cinterop/ev.def <<'EOF'
headers = ev/ev.h
headerFilter = ev/**
package = ev.c
staticLibraries = libev.a
EOF
    cat > ev-core/src/linuxX64Main/kotlin/ev/Ev.kt <<'EOF'
package ev

import kotlinx.cinterop.CPointer
import kotlinx.cinterop.ExperimentalForeignApi

@OptIn(ExperimentalForeignApi::class)
class Ev(internal val handle: CPointer<ev.c.ev_t>)
EOF
    ;;

  blocking-probe)
    # mongkn research §1.12 and a JVM readiness probe in one service: withTimeout around a blocking
    # call, measured to answer after the call rather than after the timeout.
    mkdir -p server/src/linuxX64Main/kotlin/app server/src/nativeInterop/cinterop include/db
    cat > server/src/nativeInterop/cinterop/db.def <<'EOF'
headers = db/db.h
headerFilter = db/**
package = db.c
staticLibraries = libdb.a
EOF
    cat > include/db/db.h <<'EOF'
typedef struct db_s db_t;

/* Round trip to the server. BLOCKS the calling thread until the server answers or the
   connection's timeout expires (default: 30 000 ms). Returns 0 when the server answered. */
int db_ping(db_t *db);

/* Sets the timeout every blocking call on this connection observes, in milliseconds. */
int db_set_timeout_ms(db_t *db, int timeout_ms);
EOF
    cat > server/src/linuxX64Main/kotlin/app/Readiness.kt <<'EOF'
package app

import db.c.db_ping
import db.c.db_t
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration.Companion.seconds

/** Behind GET /health/ready. Must answer within 2 seconds: the probe's timeout is 10. */
@OptIn(ExperimentalForeignApi::class)
class Readiness(private val db: CPointer<db_t>) {
    suspend fun ready(): Boolean =
        withTimeoutOrNull(2.seconds) {
            withContext(Dispatchers.IO) { db_ping(db) == 0 }
        } ?: false
}
EOF
    ;;

  static-scratch)
    # sborka research §1.5c / katcher#55: a static binary in `scratch` that serves health checks
    # and fails the first page that goes through a charset.
    mkdir -p server
    cat > server/build.gradle.kts <<'EOF'
plugins {
    kotlin("multiplatform") version "2.4.20"
}

kotlin {
    linuxX64 {
        binaries.executable {
            entryPoint = "app.main"
            // The static recipe, ABBREVIATED for this case: the real one also overrides five
            // konan.properties keys (-Xoverride-konan-properties), without which this line does not
            // link. The case is about what the image needs once the binary exists.
            linkerOpts("-static", "--no-dynamic-linker", "-L/usr/lib/x86_64-linux-gnu")
        }
    }
    sourceSets {
        linuxX64Main.dependencies {
            implementation("io.ktor:ktor-server-cio:3.6.0")
            implementation("io.ktor:ktor-client-curl:3.6.0")   // outbound calls to a payment API, https
        }
    }
}
EOF
    cat > Dockerfile <<'EOF'
FROM gradle:9.7.1-jdk25-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends g++ && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN gradle --no-daemon :server:linkReleaseExecutableLinuxX64

FROM scratch
COPY --from=build /src/server/build/bin/linuxX64/releaseExecutable/server.kexe /server
ENTRYPOINT ["/server"]
EOF
    cat > smoke.log <<'EOF'
$ docker run -d -p 8080:8080 app:static
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/health
200
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/login
200
$ curl -s -o /dev/null -w '%{http_code}\n' -b session=… 'localhost:8080/orders?q=a%20b'
500
$ docker logs <container>
kotlin.IllegalArgumentException: Failed to open iconv for charset UTF-8 with error code 22
    at io.ktor.http#encodeURLParameter
EOF
    ;;

  *)
    echo "unknown shape: $shape" >&2
    exit 2
    ;;
esac

git init -q 2>/dev/null || true
git add -A 2>/dev/null || true
git -c user.email=eval@example.invalid -c user.name=eval commit -qm "fixture" 2>/dev/null || true
