---
name: ktor-server-feature
description: "Implement or change a feature on a Ktor server: a route, a validation rule, a storage port and its implementations, DI wiring, auth, error mapping and configuration — in a codebase where the server is compiled to the JVM and to Kotlin/Native from one source set, or may be one day. Covers the feature package, `by inject` routing, ownership checks on reads and writes, id-from-path, explicit auth tiers, StatusPages, ENV configuration, per-build storage modules and the document-shape compatibility between them, and which suite a route test belongs in. Use this whenever the user says add an endpoint, add a route, implement a server feature, add a repository, fix a 500, or touches server-common / server / server-native code. Not for bringing a brand-new service up from nothing."
---

# A feature on a Ktor server compiled twice

The server in the reference product ([mani](https://github.com/youndie/mani-kotlin-fullstack))
lives in `:server-common` (jvm + linuxX64) and is compiled twice: `:server` on the official
MongoDB driver, `:server-native` on a native binding. Every rule below follows from one fact:
**only code with two implementations can diverge**, so the second implementation is confined to
storage, and everything else is written once.

If the project has a single JVM build, the layering still applies; the "second build" rules are
what to keep in mind so that a native build stays possible.

## Step 0. Check the project first

1. **Check the contract module before anything else.** Most `{id}` routes reuse an existing
   `ById` resource, and most "new" fields already have a DTO. If the resource is really new, its
   shape is `kmp-shared-contract`.
2. Find the routing function nearest to your task (`grep -rn "fun Routing\." server-common`) and
   the `docs/api/` document of that resource if the repository keeps one; copy **their** layout
   and naming. `git log` on the feature directory usually surfaces cross-cutting refactors, not
   the newest feature. **The project's conventions win** over this file.
3. Identify: DI (Koin here; `by inject` in routing functions), the storage driver per build, how
   errors become responses (`StatusPages`), how the caller is read (`call.currentUserId()`), and
   which test harness each build has.
4. **Grep the documentation for claims about the thing you are adding**, including negative ones
   ("there is no route for…"). In a repository with a documentation gate, a stale "there is no…"
   fails CI as surely as a missing table row.

Boundaries: the wire shape is `kmp-shared-contract`; tests in detail are `kmp-testing`; a new
service from scratch is outside this skill.

## The feature package

```
server-common/src/commonMain/kotlin/<root>/feature/<name>/
  <Name>Routing.kt        fun Routing.<name>Routing()      (the reference also has one *Router.kt; the function name is what matters)
  Rules.kt                fun <name>Problem(x): String?   validation, pure
  data/<Name>Repository.kt   the port (interface) + <Name>Record if the stored shape differs from the wire
  data/<Name>Service.kt   orchestration both builds share (AuthService, DemoService)

server/src/main/kotlin/<root>/feature/<name>/data/
  Mongo<Name>Repository.kt, <Name>Db.kt                    JVM implementation
server-native/src/linuxX64Main/kotlin/<root>/feature/<name>/data/
  Mongkn<Name>Repository.kt                                native implementation (documents in db/DbModel.kt)
```

The implementation class is prefixed by **the technology**, not by `Impl`: two builds mean two
implementations, and `Mongo` / `Mongkn` says which one you are reading.

## A route

```kotlin
fun Routing.transactionRouting() {
    val transactionRepository by inject<TransactionRepository>()
    val categoryRepository by inject<CategoryRepository>()
    val jwtConfig by inject<JWTConfig>()

    authenticate(jwtConfig.name) {
        get<TransactionResource.ById> { path ->
            val userId = call.currentUserId()
            val record = transactionRepository.getById(path.id)
            // 403 for "not yours" and "does not exist" alike: different answers would say which ids are taken.
            if (record?.userId != userId) {
                call.respond(HttpStatusCode.Forbidden)
                return@get
            }
            // The same record→wire mapping the list uses. Forgetting a substitution here returns a
            // record with a default category, and breaks nothing.
            call.respond(HttpStatusCode.OK, record.toTransaction(categoryRepository.getByUser(userId)))
        }

        patch<TransactionResource.ById> { path ->
            // The id comes from the path; the body's id is overwritten.
            val new = call.receive<Transaction>().copy(id = path.id)

            val problem = transactionProblem(new)
            if (problem != null) {
                call.respond(HttpStatusCode.BadRequest, problem)
                return@patch
            }

            val userId = call.currentUserId()
            if (transactionRepository.getById(path.id)?.userId != userId) {
                call.respond(HttpStatusCode.Forbidden)
                return@patch
            }
            transactionRepository.update(new, userId)
            call.respond(HttpStatusCode.OK, new)
        }
    }
}
```

The shape of every handler: **receive (writes only) → validate (writes only) → who is calling →
ownership → repository → respond through the same mapping the list uses.** Dependencies are
resolved once per routing function with `by inject`, not per request.

Rules that were each paid for with a real defect:

- **The id of the record being changed comes from the path.** `.copy(id = path.id)` on the
  received body. Ownership used to be checked against the path while the write was addressed by
  the body: a stranger's record was rewritten with a `200`.
- **"Not yours" and "does not exist" answer the same** (`403`), and **no `404` branch follows an
  ownership check**. Different answers would reveal which ids are taken. (The reference has one
  older route that still adds a `404` after the check; do not copy it.)
- **Ownership on reads is the comparison in the route**: `record?.userId != userId`, where the
  port's `getById` returns the record with its owner. The port does not take the owner for reads;
  the record carries it.
- **Ownership on writes is also in the write filter of every implementation**: `replaceOne(and(_id
  == id, userId == caller))`. The route already refuses a foreign record; the filter makes the
  next `update` call from another place safe by default. Two conditions on the same field need
  an explicit `and(...)`, or the second silently evicts the first.
- **`currentUserId()` throws outside `authenticate`.** A request without a principal never
  reaches a handler inside `authenticate`; a missing principal therefore means an unprotected
  route, a wiring mistake, and it must be loud (a `500`). The earlier version answered `401` and
  returned an empty string without stopping the handler, and the empty string would have gone
  into storage as the owner.
- **Validation sits on the server even when the form already prevents it.** A form is a
  convenience; behind it is open HTTP, and "the client will not send that" is a statement about
  the client. Validate **where data enters** (create, update, registration), never on reads or
  on sign-in: records and names created before a rule exist and must not be evicted by it.

## Validation: a pure function that returns the problem

```kotlin
/**
 * What is wrong with this rule, or `null` if nothing.
 * The text is returned to the client and shown to a person: English, and it says what to fix.
 */
fun transactionProblem(transaction: Transaction): String? {
    val until = transaction.until   // smart casts do not cross module boundaries
    return when {
        transaction.amount.signum() <= 0 -> "Amount must be greater than zero"
        until != null && until < transaction.date -> "The end date cannot be earlier than the start date"
        transaction.comment.length > MAX_COMMENT_LENGTH -> "Comment must be at most $MAX_COMMENT_LENGTH characters long"
        else -> null
    }
}
```

No exceptions, no framework: a function the route calls and a test calls at each boundary.

## Auth tiers are chosen per route, explicitly

A route without a chosen tier still has one: whatever the default gives it, usually "open". Decide
at implementation time and write it down (in the route's KDoc, and in `docs/api/` if it exists).

| Tier | How it looks | Which routes |
|---|---|---|
| open | outside `authenticate { }` | sign-up, sign-in, refresh, health, a public sandbox entry |
| bearer access token | `authenticate(jwtConfig.name) { }` | everything that belongs to a user |
| per-record ownership | the same token **plus** the owner comparison in the handler (and the write filter) | everything with an id in the path |

`authenticate` proves the caller is *somebody*; it says nothing about the record being *theirs*.
When the framework's auth plugin is JVM-only (as `ktor-server-auth-jwt` is), write a small
`AuthenticationProvider` over your own token service that verifies the token **of the right
kind** (a refresh token opens no door); see
[examples/auth-provider-and-config.md](examples/auth-provider-and-config.md).

## Status codes the routes answer with

| Situation | Answer |
|---|---|
| created | `201` with the created entity, ids and substitutions filled in |
| read or changed | `200` with the entity through the same mapping as the list |
| a validation rule refused the input | `400` with the text from `xProblem()` |
| body or path parameter did not parse (`BadRequestException`, `IllegalArgumentException`, `SerializationException`) | `400 Malformed request`, one generic text, from `StatusPages` |
| no token, wrong kind, expired | `401` with one fixed text, from the auth provider |
| not yours or does not exist | `403`, the same for both |
| anything else | `500` plus one `println` line: the common source set has no logger, and in a container stdout is the log |

`StatusPages` rethrows `CancellationException` first: a request the client abandoned is neither
a `500` nor a log line. The server's `Json` is declared **without `isLenient`**. CORS is installed
only in development mode. The full plugin block and the assembly order (plugins → Koin → auth
taken from the graph → routing, callable from `testApplication` with a config passed in) are in
[examples/routing-and-app.md](examples/routing-and-app.md).

## Storage: ports in common, one implementation per build

The port is an interface in `commonMain`, in domain terms, returning a `Record` type when the
stored shape differs from the wire shape (it carries `userId`, which the contract does not).
Each build module has a storage module function that binds every port to that build's driver,
plus a `StorageHealth` that makes one real round trip (`ping`; asking the client whether it is
"connected" is useless, it believes so until the first failure).

**The two implementations must agree on the stored representation, not on their class shapes.**
Both builds write the same database; a divergence breaks nothing loudly, the query simply finds
nothing. Ids are stored as the driver's native id type (`ObjectId`, not a string), money as the
database's decimal type (`decimal128`, not text), collection names as constants with the same
value in each build. The check is a test that reads the **raw document** in each build.

Simple reads with no side effects go straight from the repository to the route; a service class
in `commonMain` appears when two or more repositories must be orchestrated, and it is an ordinary
class, never `expect/actual`. Full port, both implementations and both storage modules:
[examples/storage-port-and-implementations.md](examples/storage-port-and-implementations.md).

Configuration comes from the environment through one `Config.fromEnv()` with `readEnv` as the
only `expect`; secrets and escaping are covered in `kmp-project-structure` and in the same
example file.

## What Kotlin/Native takes away, and what replaces it

| Not available in `commonMain` | Use instead |
|---|---|
| `java.*` (`File`, `java.time`, reflection, `System.getenv`) | `kotlinx-io`, `kotlinx-datetime`, `kotlin.time`, `expect readEnv` |
| HOCON (`application.conf`) | environment variables |
| `ktor-server-auth-jwt`, `java-jwt` | your own `TokenService` over `cryptography-kotlin` (keep `java-jwt` in `jvmTest` as the compatibility reference) |
| `CallLogging`, slf4j | `println` to stdout |
| `ktor-server-compression`, `staticResources` | pre-compressed files baked into the image, served from a directory scanned once at startup |
| mocking libraries in shared tests | hand-written fakes |

Available on native: `ktor-server-test-host`, `ktor-client-mock`, Koin (`koin-ktor` publishes
for `linuxX64`), `kotlinx-coroutines-test`. Type checks happen at the edge: an invalid `ObjectId`
is rejected by the driver's constructor on the JVM and by a serializer on native; all they share
is how the refusal becomes a `400`, so a malformed-id test exists in **each** build.

Koin: register with an explicit lambda when a constructor has a default parameter (`singleOf`
resolves every parameter, defaults included, and fails at runtime); a ready object goes in as
`single { config }`; the graph gets a test **per build** because the storage modules differ.

## Where the tests go

| What changed | Test | Suite |
|---|---|---|
| a route, even one that adds nothing to the port | an HTTP test on the build's harness (`testApplication` + a real database); the malformed-id case too | `:server:test` **and** `:server-native:linuxX64Test`, with KDocs pointing at each other |
| validation, a token rule, a service over ports | a plain test with fakes | `:server-common:commonTest` (runs on both platforms) |
| a storage implementation, a document field | a raw-document test | the build's suite, one per build |
| a new binding | the graph test of each build resolves it | `:server:test`, `:server-native:linuxX64Test` |

A route test is never a shared test: it needs the assembled application and the database, and the
reference keeps `commonTest` free of `ktor-server-test-host` on purpose. Then **mutate**: undo the
ownership check and confirm the `403` tests go red in both builds and nothing else does.

## Checklist before the change is done

- [ ] the resource and DTOs live in the contract module; no string path in the server
- [ ] the tier of every new route is explicit, and written where the project records tiers
- [ ] the id comes from the path; reads compare `record.userId` in the route; writes also carry the owner in the filter of every implementation — **or** the port is unchanged and this line says so
- [ ] validation is a `xProblem()` function with tests at the boundaries (writes only)
- [ ] responses go through the same record→wire mapping as the list
- [ ] both storage implementations and both storage modules updated — **or** unchanged, stated
- [ ] a route test in each build; a raw-document test if the stored shape changed
- [ ] the graph test of each build still resolves every port
- [ ] documentation that asserts anything about this route updated, including "there is no…" claims
- [ ] executed, with fresh result files (`find . -path '*/build/test-results/*' -newermt '-5 minutes'`), one task per invocation:

```bash
./gradlew :server-common:jvmTest :server:test
```

```bash
./gradlew :server-common:linuxX64Test
./gradlew :server-native:linuxX64Test
./gradlew :server-native:linuxX64ReleaseTest   # mandatory: the image ships the release binary
```
