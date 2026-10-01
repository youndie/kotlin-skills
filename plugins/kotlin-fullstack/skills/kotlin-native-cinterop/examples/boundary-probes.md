# Probes of the boundary: what cinterop and the runtime actually do

Referenced from steps 4, 5 and 8 of [SKILL.md](../SKILL.md). Written for this repository. Each probe
is a few lines that settle a claim the portfolio had carried as a sentence. They ran on 2026-10-02 on
**macosArm64 with Kotlin/Native 2.4.20**, using the distribution's own tools (`cinterop`,
`kotlinc-native`, `klib dump-metadata`). The output is quoted as observed. Where a result could
depend on the target's calling convention, the text says so. Run them again on the target you ship
before you lean on one.

```bash
K=~/.konan/kotlin-native-prebuilt-<host>-2.4.20/bin     # the distribution Gradle already downloaded
$K/cinterop -def t.def -o t                               # → t.klib
$K/kotlinc-native t.kt -l t.klib -o t                     # → t.kexe
```

## An exception thrown out of a callback

```c
// t.def
package = t
---
#include <pthread.h>
typedef void (*cb_t)(int);
static int call_cb(cb_t cb) { cb(1); return 42; }                       /* on the caller's thread */
static void *thr(void *p) { ((cb_t)p)(2); return 0; }
static int call_on_thread(cb_t cb) {                                     /* on a thread C created  */
    pthread_t t; pthread_create(&t, 0, thr, (void *)cb); return pthread_join(t, 0);
}
```

```kotlin
// t.kt
val thrower = staticCFunction { x: Int -> if (x > 0) throw IllegalStateException("boom $x") }

fun main(args: Array<String>) {
    if (args.firstOrNull() == "thread") {
        println("thread: before"); val r = call_on_thread(thrower); println("thread: after r=$r")
    } else {
        try { println("same: returned ${call_cb(thrower)}") } catch (e: Throwable) { println("same: caught ${e.message}") }
    }
}
```

```
$ ./t.kexe
same: caught boom 1                                   exit 0
$ ./t.kexe thread
thread: before
Uncaught Kotlin exception: kotlin.IllegalStateException: boom 2
    at 1   t.kexe   thr + 19
    at 2   libsystem_pthread.dylib   _pthread_start + 135   exit 134
```

**On a thread Kotlin owns, the exception unwinds through the C frames to whoever called into C**,
and the C code in between never finishes. The `return 42` never ran. In a real library that is a
lock still held, a queue half-updated, a poll loop that never returns. **On a thread the C library
created, nobody is above the callback**, so the process ends. Neither outcome is "nothing happens".

## Variadic functions

```kotlin
memScoped {
    val buf = allocArray<ByteVar>(256)
    snprintf(buf, 256u, "%d %ld %f %s %lu", 42, 1234567890123L, 3.5, "str", 18446744073709551615UL)
    println(buf.toKString())
    snprintf(buf, 256u, "%f", 1.5f)
    println("float: " + buf.toKString())
}
```

```
42 1234567890123 3.500000 str 18446744073709551615
float: 1.500000
```

`klib dump-metadata` on `platform.posix` shows the shape:
`fun snprintf(…, __format: String?, vararg variadicArguments: Any?): Int`. Int, Long, Double, a
Kotlin `String` (passed as a C string) and ULong arrived intact. A `Float` was promoted to `double`,
as C's default promotions require. **Nothing checks the types against what the callee reads**: each
argument's C type comes from the Kotlin value. A Kotlin `Int` where the callee reads `size_t` or
`int64_t` is a bug no compiler reports. Whether it shows depends on the target's variadic calling
convention, and this probe ran on one target only.

## Macros

```c
// m.h, bound with headers = m/m.h
#define M_TLS1_2_VERSION 0x0303
#define M_ERROR_WANT_READ 2
#define M_SET_HOST(s, n) ((s) + (n))
```

`klib dump-metadata` of the result:

```
public final const val M_TLS1_2_VERSION: kotlin/Int /* = 771 */
public final const val M_ERROR_WANT_READ: kotlin/Int /* = 2 */
```

and no `M_SET_HOST`. **Object-like macros with a constant value arrive as `const val`. Function-like
macros are invisible** and need a `static` C function after `---`.

## `noStringConversion` takes every `const char*` of the function

```properties
package = probe
noStringConversion = put_string
---
static int put_string(const char *key, const char *value, size_t len) { … }
```

```
fun put_string(key: CValuesRef<ByteVar>?, value: CValuesRef<ByteVar>?, len: ULong): Int
```

Both parameters lose the `String` conversion, not only the one that needed it. A call passes
`key.cstr` (or `key.cstr.ptr` inside `memScoped`).

## Where linker options and archives have to be written

One header, one function, `libz3.a` holding it. The cinterop tool was run three ways, and then a
consumer executable was linked against each klib with no options of its own:

| How the library was named | cinterop said | manifest | `included/` | consumer link |
|---|---|---|---|---|
| `-linker-option -lz3` (what `cinterops { linkerOpts(…) }` turns into) | `warning: -linker-option(s)/-linkerOpts option is not supported by cinterop. Please add linker options to .def file or binary compilation instead.` | no `linkerOpts` | — | **fails**: `Undefined symbols … z_add` |
| `-staticLibrary libz3.a -libraryPath <dir>` (what `extraOpts("-staticLibrary", …)` passes) | nothing | **no `staticLibraries` key** | `libz3.a` | links, prints 42 |
| `staticLibraries = libz3.a` in the `.def`, `-libraryPath <dir>` | nothing | `staticLibraries=libz3.a` | `libz3.a` | links, prints 42 |

So a consumer can link a klib whose manifest names no archive. The reliable reading is `included/`.

## One host, another target's klib

On the Mac, `z.c` was compiled for Linux with the distribution's own clang and sysroot. Then a
`linux_x64` cinterop and a `linux_x64` executable were built from that archive:

```bash
L=~/.konan/dependencies/llvm-21-aarch64-macos-essentials-97/bin
SR=~/.konan/dependencies/x86_64-unknown-linux-gnu-gcc-8.3.0-glibc-2.19-kernel-4.9-2/x86_64-unknown-linux-gnu/sysroot
$L/clang --target=x86_64-unknown-linux-gnu --sysroot=$SR -fPIC -O2 -c z.c -o lin/z.o && $L/llvm-ar rcs lin/libz3.a lin/z.o
$K/cinterop -target linux_x64 -def z2.def -compiler-option -I$PWD/inc -o lx -libraryPath $PWD/lin
$K/kotlinc-native -target linux_x64 use.kt -l lx.klib -o use_lx
```

```
default/targets/linux_x64/included/libz3.a
use_lx.kexe: ELF 64-bit LSB executable, x86-64, … interpreter /lib64/ld-linux-x86-64.so.2
```

**A cinterop needs the target's headers and archives, not the target's host.** A bundle is a set of
files. It can be built where it must be built (a Linux image, an arm64 runner) and then handed to the
one host that publishes every target. kafkakn already does this between architectures: its arm64
bundle is built on arm64 Docker, and Kotlin cross-compiles `linuxArm64` on x86-64 (research §2.28).
The binary above was linked, not run, because a Mac cannot run it. A system-library binding cannot
take this route: the Mac has no Linux `libssl-dev` to hand over.

## `usePinned` on an empty array

```
ByteArray(0).usePinned { it.addressOf(0) }   →   ArrayIndexOutOfBoundsException
```

Check for an empty array before taking an address. If a `StableRef` or anything else that must be
released was created first, release it on that path.
