---
name: ktor-server-feature
description: "Implement or change a feature on a Ktor server: a route, a use case with typed errors, a validation rule, a storage port and its implementations, transactions, tenancy and role gates, DI wiring, error mapping, background workers and configuration — in a codebase compiled to the JVM, to Kotlin/Native, or to both from one source set. Covers the feature package, `by inject` routing, auth tiers decided at the mount, ownership and tenant filters, `StatusPages` with an error reporter, ENV or HOCON configuration, per-build storage modules and document-shape compatibility, OpenAPI from route descriptions, and which suite a test belongs in. Use this whenever the user says add an endpoint, add a route, implement a server feature, add a use case, add a repository, fix a 500, add a worker, or touches server / server-common / server-native / core code. Not for bringing a brand-new service up from nothing."
---

# A feature on a Ktor server

The shape below is what several Ktor services converged on: a JVM service on MongoDB, a service
compiled to both the JVM and Kotlin/Native, and a Kotlin/Native library-style server on SQL. The
public reference for the two-build mechanics is
[mani](https://github.com/youndie/mani-kotlin-fullstack); the use-case, tenancy and error shapes
come from larger services and are described generically. Every rule that follows names the defect
that paid for it.

## Step 0. Check the project first

1. **Check the contract module before anything else.** Most `{id}` routes reuse an existing
   `ById` resource; most "new" fields already have a DTO. A really new resource is
   `kmp-shared-contract`.
2. Find the routing function nearest to your task (`grep -rn "fun Route\.\|fun Routing\." server`)
   and its `docs/api/` document if the repository keeps one; copy **their** layout. `git log` on a
   feature directory surfaces cross-cutting refactors, not the newest feature.
   **The project's conventions win** over this file.
3. Identify: DI (Koin: `by inject` in routing functions, or dependencies passed in), whether
   there is a `UseCase` base type and where (`core:use-case` or a package), the tenancy helper
   (`withAccess`, `withUserAccess`, `shopId()`), how errors become responses (`StatusPages` plus
   a reporter), configuration source (ENV or HOCON), the storage driver per build, whether the
   OpenAPI spec is generated and checked in CI, and which test harness each build has.
4. **Grep the documentation for claims about the thing you are adding**, including negative ones
   ("there is no route for…"). With a documentation gate, a stale sentence fails CI as surely as
   a missing table row.
5. **Decide the tier of the new route before writing it** (see "Tiers are decided at the mount").

Boundaries: the wire shape is `kmp-shared-contract`; tests in detail are `kmp-testing`; a new
service from scratch is outside this skill.

## The feature package

```
feature/<name>/
  <Name>Module.kt          Koin module of the feature
  <Name>Routing.kt         fun Route.<name>Routing()  — tier-agnostic; mounted by the app
  <Name>Handlers.kt        (optional) handler bodies shared by two route declarations
  domain/
    <Verb><Name>UseCase.kt one class per operation; nested Params and Error
    <Name>Repository.kt    the port
  data/
    <Name>RepositoryImpl.kt / <Driver><Name>Repository.kt   one per driver
    Models.kt              <Name>Db documents + mappers, internal
```

In a service compiled twice the package is split by source set: routing, use cases and ports in
`commonMain`; one `data/` per driver in `jvmMain` and `linuxX64Main`; the feature module in each
build's source set, because it names the driver. The implementation class is prefixed by the
**driver** (`Mongo…`, `Mongkn…`, `Sqlx4k…`), not by `Impl`, when there is more than one; `Impl`
is honest when there is one.

## Use cases carry the business operation

```kotlin
fun interface UseCase<in P, out T> { suspend operator fun invoke(params: P): Result<T> }

class CreateOrderUseCase(
    private val canCreate: CanCreateOrderUseCase,          // a use case may call use cases
    private val orders: OrderRepository,
    private val stock: AllocateInventoryUseCase,
    private val transactions: TransactionManager,
    private val audit: LogEventUseCase,
) : UseCase<CreateOrderUseCase.Params, Order> {

    override suspend fun invoke(params: Params): Result<Order> = suspendRunCatching {
        if (canCreate(CanCreateOrderUseCase.Params(params.workspaceId)).getOrThrow() is PlanCheck.Denied) throw Error.LimitReached

        val id = transactions.withTransaction {
            val usage = inventory(AllocateInventoryUseCase.Params(params.order.items, params.workspaceId)).getOrThrow()
            orders.save(params.order, usage, params.workspaceId)
        } ?: throw CommonError.SaveFailure

        audit(LogEventUseCase.Params(params.userId, params.workspaceId, AuditAction.CREATE, id))
        orders.getById(id, params.workspaceId) ?: throw CommonError.SaveFailure
    }

    class Params(val order: CreateOrderParams, val workspaceId: String, val userId: String)

    sealed class Error : Exception() {
        data object LimitReached : Error()
    }
}
```

- **One operation, one class**, returning `Result` through `suspendRunCatching` (which lets
  `CancellationException` through). `Params` is a nested class so a route cannot pass arguments
  in the wrong order, and it carries the **caller and the tenant** as data, never read from a
  call inside the use case.
- **Failures the route must tell apart are typed**: a nested `sealed class Error` per use case,
  plus a small `CommonError` shared by the feature (`SaveFailure`). They are thrown inside the
  `suspendRunCatching` and become `Result.failure`; a route dispatches them with `when`. An
  untyped `RuntimeException("Out of stock")` forces the route to match on a message.
- **Orchestration lives here, not in the route**: plan or quota checks, the transaction, the
  audit event, the outbox entry for the next service. A route that does three of those is a use
  case written in the wrong file.
- A use case that only reads and has no rules is not worth a class: routes may call a repository
  directly for a plain `GET`. The moment a read has a tenant rule or a plan check, it is a use case.
- No dispatcher in a use case; the repository knows whether it does I/O.

Validation comes in two shapes and both are used: a **pure function** for input shape
(`fun orderProblem(params): String?`, returns the text to show, tested at each boundary), and
**typed use-case errors** for business rules that need data (`LimitReached`, `NotEnoughInventory`).

## A route: mount, access, receive, use case, dispatch

```kotlin
fun Route.ordersRouting() {
    val createOrder by inject<CreateOrderUseCase>()
    val orders by inject<OrderRepository>()

    get<OrdersResource.ById> { path ->
        withAccess { (_, workspaceId) ->
            orders.getById(path.id, workspaceId)?.let { call.respond(it) } ?: call.respond(HttpStatusCode.NotFound)
        }
    }.describe { workspaceHeader(); jsonResponse<Order>() }

    post<OrdersResource> {
        withAccess(min = Role.MANAGER) { (user, workspaceId) ->
            val params = call.receive<CreateOrderParams>()
            orderProblem(params)?.let { call.respond(HttpStatusCode.BadRequest, it); return@withAccess }

            createOrder(CreateOrderUseCase.Params(params, workspaceId, user.id))
                .onSuccess { call.respond(HttpStatusCode.Created, it) }
                .onFailure { error ->
                    when (error) {
                        CreateOrderUseCase.Error.LimitReached -> call.respond(HttpStatusCode.BadRequest, LIMIT_REACHED)
                        is AllocateInventoryUseCase.Error -> dispatchInventoryError(error)   // one dispatcher per error family
                        CommonError.SaveFailure -> call.respond(HttpStatusCode.InternalServerError, "saving error")
                        else -> throw error                                         // StatusPages: report + 500
                    }
                }
        }
    }.describe { workspaceHeader(); jsonBody<CreateOrderParams>(); jsonResponse<Order>(201) }
}
```

Every handler: **access → receive → shape-validate → use case → dispatch the typed result**.
Dependencies are resolved once per routing function with `by inject`, not per request; a
routing function knows nothing about which mount or tier it is under.

Rules paid for with real defects:

- **The tenant and the caller come from the access helper, never from the body**, and the tenant
  goes into **every** repository method (`getById(id, workspaceId)`), so a query for a record of
  another tenant matches nothing. The id of a changed record comes from the path; ownership was
  once checked against the path while the write was addressed by the body.
- **"Not yours" and "does not exist" answer the same** on user-facing routes (`403` or `404`,
  but one of them, consistently); different answers reveal which ids exist.
- **A typed error the route does not know is rethrown**, not swallowed into a generic `400`:
  swallowing turns a bug into a client error and hides it from the reporter.
- **Route-family error dispatchers** (`dispatchInventoryError`) live next to the use cases whose
  errors they map, and every `when` over a sealed error is exhaustive without `else` except for
  the rethrow.
- **The reporter sees failures the route dispatches too** when they are unexpected (`SaveFailure`
  is a `500` and is reported); a business refusal (`LimitReached`) is not.

## Tiers are decided at the mount

A routing function is mounted **by the application**, possibly more than once, under a tier:

```kotlin
routing {
    healthRouting()
    route("/api") {
        versionRouting()
        authenticate(JWT) {
            route("/orders-app") { ordersRouting(); itemsRouting() }        // user-facing: withAccess inside
        }
    }
    authenticate(JWT) {
        withRole("orders:bot") { route("/bot") { ordersRouting(); itemsRouting() } }   // same routes, another client
        withAnyRole("orders:shop", "orders:admin") { route("/internal") { internalOrdersRouting() } }  // trusted service
    }
}
```

| Tier | Gate | Tenant scoping |
|---|---|---|
| user-facing | `authenticate` at the mount, `withAccess(min)` inside every handler | per user: the helper checks the caller holds a role in the tenant named by the header |
| another client of the same routes (a bot) | `authenticate` + `withRole` at the mount | the same handlers; the helper resolves the user differently by the token's `azp` |
| service-to-service | `authenticate` + `withRole` / `withAnyRole` at the mount | the tenant header is read **raw on purpose**: the calling service acts across tenants and the role is the gate |
| management | a separate engine on a separate port, plus a token plugin over the whole branch | outside is a `404`, not a `403`: the contour's existence is not confirmed |
| open | outside `authenticate` | health, version, callbacks a third party redirects to |

A raw tenant header is a leak only on a route whose sole gate is "authenticated". Decide the
tier first; a route without a chosen tier has whatever the default gives it, usually open.

**Role gates are route-scoped plugins**, not `if`s in handlers: a plugin on `AuthenticationChecked`
that answers `403` (never `401`: `401` means "present a token" and provokes a re-login). The
transparent route selector the plugin hangs on must be a **class instance per call**, not an
`object`: `createChild` reuses a child with an equal selector, and two neighbouring gates on one
node fail with a duplicate-plugin exception **at start-up**, as a crash loop.

**The access helper** (`withAccess(min) { (user, tenantId) -> }`) resolves the caller from the
principal (by `azp`: an email for a human client, a header for a bot client), loads their roles,
compares against the minimum by an explicit **rank**, never by `Enum.ordinal` (declaration order
was the opposite of privilege), and on refusal **logs the route and the required role, never the
token**. A bare `403` without that line read as "the tenant was not created".

Dependencies a helper needs on every call (the user lookup) come from DI inside the helper or as
context parameters; **context parameters on every routing function** (`context(users: …) fun
Route.x()`) are a real option but a tax on every new route, and one service moved away from them.

## Errors become responses in one place, and are reported

```kotlin
fun Application.configureStatusPages(reporter: ErrorReporter) {
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            if (cause is CancellationException) throw cause
            reporter.report(cause)                       // anything that got here nobody expected — 400s included

            val clientStatus = cause.clientErrorStatus()   // Ktor's BadRequest/NotFound/… → their status, shared across services
                ?: when (cause) { is IllegalArgumentException -> HttpStatusCode.BadRequest; is NoSuchElementException -> HttpStatusCode.NotFound; else -> null }

            if (clientStatus != null) {
                call.application.log.info("${call.request.httpMethod.value} ${call.request.path()} → ${clientStatus.value}: ${cause.message}")
                call.respond(clientStatus, mapOf("error" to (cause.message ?: "Bad request")))
            } else {
                call.application.log.error("unhandled: ${call.request.httpMethod.value} ${call.request.path()}", cause)
                call.respond(HttpStatusCode.InternalServerError, mapOf("error" to "Internal server error"))   // no message: it describes the server
            }
        }
    }
}
```

- **Ktor's own exceptions keep their status.** Catching `Throwable` turns a malformed
  authorization header or a missing tenant header into a `500`, which lands in the error budget
  and the reporter as an outage. A shared `clientErrorStatus()` helper maps them once for every
  service; a `when` copied per service drifted.
- **`ErrorReporter` is a `fun interface` bound in DI**, not `expect fun report()`: a reporter is a
  dependency, substituted in tests (`Recording`, `Noop`) and disabled in utilities, and `expect`
  cannot be substituted. Its default is **the log, not silence**: telemetry sits behind an
  environment gate, and a silent default meant an installation without a key lost every fault.
- **Log first, then report**, with the whole exception: a reporter that caches to disk inside the
  container left `kubectl logs` empty on a crash. The same on start-up: catch at `main`, print to
  stderr, rethrow.
- **Plugin configuration is written once** and applied by both builds (`Json` settings, CORS,
  `StatusPages`): `explicitNulls` and `encodeDefaults` set differently in two entry points are a
  different wire format for a generated client, and nothing but the client notices. A CORS
  refusal is silent by nature; a small plugin that logs the refused origin on `ResponseSent` turns
  "the form does nothing" into a line.

## Storage: ports in common, one implementation per driver

```kotlin
interface OrderRepository {
    suspend fun getById(id: String, workspaceId: String): Order?
    suspend fun page(workspaceId: String, filter: OrderFilter, sorting: OrderSorting, page: Int, pageSize: Int): Page<Order>
    suspend fun save(order: CreateOrderParams, usage: List<InventoryUsage>, workspaceId: String): String?
    suspend fun softDelete(id: String, workspaceId: String): Boolean
}

interface TransactionManager { suspend fun <T> withTransaction(block: suspend () -> T): T }
object NoopTransactionManager : TransactionManager { override suspend fun <T> withTransaction(block: suspend () -> T) = block() }

fun interface StorageHealth { suspend fun isReachable(): Boolean }
```

- **The tenant is in every signature and every filter.** `Filters.and(eq("_id", id),
  eq("workspaceId", ws))` on reads and writes alike; a route may check ownership too, the filter
  makes the next caller safe by default.
- **The transaction is a port with no handle in the signature**: the carrier travels in the
  `CoroutineContext` on the adapter side (a Mongo session, an SQL transaction context), so the
  domain writes `withTransaction { }` and nothing else. `Noop` for domain tests; the adapter's
  module overrides it. A nested `withTransaction` joins, it does not open a second one.
- **Ports are suspend even when a driver blocks**; the adapter hides the blocking behind
  `Dispatchers.IO`. Making the port synchronous "because the ORM is like that" drags an engine
  detail into the domain.
- **Two drivers must agree on the stored representation**, not on class shapes: ids as the
  driver's id type, money as the database's decimal, collection names as constants. Verified by a
  raw-document test per build.
- Documents are `internal` classes next to the repository with `toDomain()` / `fromDomain()`;
  legacy fields stay readable and are written as `null` when superseded, with the reason.
- **Migrations and indexes run at start-up, explicitly and idempotently**, from a scope the
  application stops on `ApplicationStopping`; not from `init { launch }` of a repository, which
  outlives its creator in tests and races the first requests in production. On Kotlin/Native an
  unhandled exception in a coroutine kills the **process**, so start-up work is wrapped and
  reported. Storage details per driver, including the SQL variant and migration traps, in
  [examples/storage-port-and-implementations.md](examples/storage-port-and-implementations.md).

## Background work has a lifecycle

Outbox workers, schedulers and expiry sweeps are classes with `start()` / `stop()`, resolved from
DI and wired to `ApplicationStarted` / `ApplicationStopping`. Their intervals and back-off are
constructor parameters with defaults, which is why they are registered with an explicit lambda
and not `singleOf`. An outbox carries the **id** of the thing to deliver, and the worker rereads
it at delivery time.

## Configuration and secrets

Two sources are in use and both are fine; pick the project's:

- **Typed HOCON properties** on a JVM-only service: `single<MongoConfig> { property("ktor.mongo") }`
  in a config module, values in `application.conf` as `${?ENV}` substitutions.
- **ENV through a `Config(env: EnvSource)` class** on a two-build service: HOCON is JVM-only, and
  the conf file held no value of its own anyway. `EnvSource.of(map)` makes the config testable
  without touching the machine's environment; variable names must equal the ones the deployment
  already sets, to the letter, or switching builds silently changes configuration.

Secrets: **a required secret has no default** (`required("HANDOFF_SECRET")`, failing at start-up
with a message that says why); a default for a secret is a way to reach production with a default
secret. The exception is a demo whose `docker compose up` must work from the README: a random
per-process secret **plus a printed warning**, never a literal. Optional integrations are gated
on their key (`config.reporter?.let { start(it) }`) so a local run sends nothing anywhere.
Validate in `init { require(...) }` so a bad value fails the constructor, not the first request.

## What Kotlin/Native takes away, and what replaces it

| Not in `commonMain` | Use instead |
|---|---|
| `java.*`, `System.getenv`, HOCON | `kotlinx-io`, `kotlinx-datetime`, `expect readEnv`, ENV config |
| `ktor-server-auth-jwt`, JVM role-gate plugins | your own provider over a shared token verifier; a route-scoped role plugin over the multiplatform principal |
| `CallLogging`, slf4j, JVM-only reporters | a small call-logging plugin; an `ErrorReporter` port |
| `ktor-server-compression`, `staticResources` | pre-compressed files served from a directory scanned once |
| mocking libraries in shared tests | hand-written fakes |

Available on native: `ktor-server-test-host`, `ktor-client-mock`, Koin, `kotlinx-coroutines-test`,
sqlx4k for SQL, a Mongo binding over the C driver. **The release test run is mandatory**:
Kotlin/Native omits type-cast checks in release builds. A vanished database can make a native
query hang rather than fail, which is why liveness never touches storage and readiness does.

## DI and the composition root

- Feature modules are `val <name>Module = module { }`; the application lists them. Config objects
  enter the graph as `single { config.mongo }`.
- **Explicit lambda for any constructor with a default parameter** (clocks, intervals, an
  `HttpClient` a test wants to swap): `singleOf` resolves every parameter and fails **lazily**, at
  the first request of one route, while the pod starts healthy. Three services hit this. A
  `verify()` graph test misses it too (defaults and nullable parameters are skipped); the graph
  test **resolves** every type the routes inject, and the list in that test is maintained by hand.
- A library-style server exposes a **composition root function** (`runService(storage = { config
  -> module }, authMethods = { listOf(...) })`) with an **isolated `koinApplication`** rather than
  the global `startKoin`: two servers in one JVM (tests, two engines) otherwise collide, and one
  `stopKoin` tears the container from under the other. With two engines, `install(Koin)` is not
  used at all; dependencies are handed to the routes explicitly. More in
  [examples/composition-and-distributions.md](examples/composition-and-distributions.md).

## OpenAPI from the routes

When the spec is generated (Ktor's `describe { }` DSL on each route, a `:server-spec` module that
boots an empty application and prints the document), the committed spec is **regenerated in the
same change** and CI fails on a diff; a lint checks every route is present, every secured
operation lists `401`, every `$ref` resolves. Two traps: a single KDoc-style annotation in a file
turns inference **off for the whole file**, and `call.receive` inside a shared handler function is
invisible to inference, so request bodies are declared in `describe`. Internal routes are marked
hidden.

## Health

`/health` answers without touching dependencies (liveness); `/ready` makes one round trip to
storage through `StorageHealth` and returns `503` on failure (readiness). One probe that pings the
database is the older shape and restarts every replica when the database is down.

## Where the tests go

| What changed | Test | Suite |
|---|---|---|
| a route | an HTTP test: the harness stubs the JWT verifier, sets the tenant header by default, and swaps the use case for a fake through an override module; one test per **tier** the route is mounted under (the `403` for a role below `min` included) | the build's suite |
| a use case | fakes of its ports (mocks in a JVM-only suite); success, each typed error, and **that side effects did not happen on failure** | `commonTest` or the JVM suite |
| a repository | against a real database per test class; a raw-document test where the stored shape matters; on native the database URL comes from the **environment**, never a hardcoded port that is somebody else's container | the build's suite |
| the graph | resolve every injected type | one test per build |
| plugins | `testApplication` with a throwing route: Ktor exceptions keep their status, a real failure is a `500` without its message, the reporter saw both | the JVM suite |

Details, harness code and the native traps (`runBlocking` for real-database tests on native, a
file rather than `:memory:` for SQLite) in `kmp-testing`.

## Checklist before the change is done

- [ ] resource and DTOs in the contract module; no string path in the server
- [ ] the tier chosen at the mount; user-facing handlers wrapped in the access helper with an explicit `min` role
- [ ] the tenant and the caller flow from the helper into `Params` and into every repository call
- [ ] business rules in a use case with typed errors; the route dispatches them and rethrows the rest
- [ ] shape validation as a `xProblem()` function, tested at the boundaries
- [ ] every storage implementation and its module updated, or "unchanged" stated
- [ ] a route test per tier; a use-case test per typed error; a raw-document test if the stored shape changed
- [ ] the graph test resolves every new injection; no default parameters under `singleOf`
- [ ] the OpenAPI spec regenerated, if the project generates one; docs updated, "there is no…" claims included
- [ ] executed with fresh result files, one task per invocation, the native release run included

Examples: [examples/routing-and-app.md](examples/routing-and-app.md),
[examples/use-cases-and-errors.md](examples/use-cases-and-errors.md),
[examples/storage-port-and-implementations.md](examples/storage-port-and-implementations.md),
[examples/auth-provider-and-config.md](examples/auth-provider-and-config.md),
[examples/composition-and-distributions.md](examples/composition-and-distributions.md).
