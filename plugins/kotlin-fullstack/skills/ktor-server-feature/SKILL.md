---
name: ktor-server-feature
description: "Add or change a route, use case, repository, worker or DI binding on a Kotlin Ktor server (JVM, Kotlin/Native, or both): the feature package, use cases with typed errors, tiers decided at the mount, tenant and ownership filters, StatusPages with an error reporter, per-driver storage, which tests to write. Use for 'add an endpoint', 'add a route', 'implement a server feature', 'fix a 500', 'add a worker' in Ktor code. Not for a new service or the contract itself."
---

# A feature on a Ktor server

Versions assumed: Kotlin 2.2+, Ktor 3.x, Koin 4.x. The shape is what several Ktor services
converged on; the public reference for the two-build mechanics is
[mani](https://github.com/youndie/mani-kotlin-fullstack), and where the reference does something
older than this file, the file says so. Every rule names the defect that paid for it.

## Step 0. Check the project first

1. **Check the contract module before anything else.** Most `{id}` routes reuse an existing
   `ById` resource; most "new" fields already have a DTO. A new resource is `kmp-shared-contract`.
2. Find the routing function nearest to your task (`grep -rn "fun Route\." server`) and its
   `docs/api/` document if the repository keeps one; copy **their** layout. **The project's
   conventions win** over this file.
3. Identify: DI (Koin, `by inject` inside routing functions), the `UseCase` base type and where it
   lives, the access helper (`withAccess`, `withUser`), how errors become responses (`StatusPages`
   plus a reporter), the configuration source (ENV or HOCON), the storage driver per build, whether
   the OpenAPI spec is generated and checked in CI, and the test harness of each build.
4. **Grep the documentation for claims about the thing you are adding**, including negative ones
   ("there is no route for…"). With a documentation gate, a stale sentence fails CI.
5. **Decide the tier of the new route before writing it** (see "Tiers are decided at the mount").

## The procedure for one endpoint

1. Contract: the `@Resource` and DTOs exist or are added (`kmp-shared-contract`).
2. Domain: the use case with its `Params` and typed `Error`, or none for a plain read.
3. Port: a method on the repository interface, tenant in the signature.
4. Data: the method in **every** driver's implementation, tenant in the filter.
5. Route: the handler in the feature's routing function; the function is already mounted under
   its tier, or the mount is added in the application.
6. DI: new classes bound in the feature module; default parameters mean an explicit lambda.
7. Tests: route (per tier), use case (per typed error), repository (raw document if the shape
   changed), the graph test's list extended.
8. Spec and docs regenerated in the same change, if the project has them.

Imports that bite every time: `io.ktor.server.resources.get` (typed), not
`io.ktor.server.routing.get`; `org.koin.ktor.ext.inject` for `by inject` inside a `Route`.

## The feature package

```
feature/<name>/
  <Name>Module.kt          val <name>Module = module { }  — use cases, services; in commonMain
  <Name>Routing.kt         fun Route.<name>Routing()  — tier-agnostic, no authenticate inside
  domain/
    <Verb><Name>UseCase.kt one class per operation; nested Params and Error
    <Name>Repository.kt    the port; tenant in every signature
    Rules.kt               fun <name>Problem(params): String?  — input-shape validation
  data/
    <Driver><Name>Repository.kt   one per driver (Mongo…, Mongkn…, Sqlx4k…); <Name>RepositoryImpl when there is one
    Models.kt              internal <Name>Db documents + toDomain()/fromDomain()
```

In a service compiled twice, `domain/`, the routing and the feature module are in `commonMain`;
each build has its own `data/` and one **storage module** (`mongoStorageModule`,
`mongknStorageModule`) binding every port to that build's driver. The feature module never names
a driver.

## Use cases carry the business operation

```kotlin
class CreateOrderUseCase(/* ports and other use cases */) : UseCase<CreateOrderUseCase.Params, Order> {
    override suspend fun invoke(params: Params): Result<Order> = suspendRunCatching { /* rule → transaction → audit → read back */ }
    class Params(val order: CreateOrderParams, val workspaceId: String, val userId: String)
    sealed class Error : Exception() { class LimitReached : Error() }
}
```

- **One operation, one class**, `UseCase<P, T>` returning `Result` through `suspendRunCatching`
  (which lets `CancellationException` through). `Params` is nested, named fields, and carries
  the **caller and the tenant as data**: a use case never reads a call.
- **Failures the route must tell apart are typed** — a nested `sealed class Error` per use case
  and a feature-wide `CommonError` (`SaveFailure`) — thrown inside `suspendRunCatching`. An
  untyped `RuntimeException("Out of stock")` forces the route to match on a message.
- **Orchestration lives here**: quota checks, the transaction, the audit event, the outbox
  entry. A route doing three of those is a use case in the wrong file.
- A plain read with no rule is not worth a class; the route calls the repository. The moment a
  read has a tenant rule or a plan check, it is a use case.
- No dispatcher in a use case; the repository knows whether it does I/O.

Validation has two shapes, both used: `fun orderProblem(params): String?` for input shape (the
text is what the user sees), typed use-case errors for business rules that need data. The full
use case, its test, and the error dispatcher: [examples/use-cases-and-errors.md](examples/use-cases-and-errors.md).

## A route: access, receive, validate, use case, dispatch

```kotlin
fun Route.ordersRouting() {
    val createOrder by inject<CreateOrderUseCase>()
    val orders by inject<OrderRepository>()
    val reporter by inject<ErrorReporter>()

    get<OrdersResource.ById> { path ->
        withAccess { (_, workspaceId) ->
            orders.getById(path.id, workspaceId)?.let { call.respond(it) } ?: call.respond(HttpStatusCode.NotFound)
        }
    }

    post<OrdersResource> {
        withAccess(min = Role.MANAGER) { (user, workspaceId) ->
            val params = call.receive<CreateOrderParams>()
            orderProblem(params)?.let { call.respond(HttpStatusCode.BadRequest, it); return@withAccess }

            createOrder(CreateOrderUseCase.Params(params, workspaceId, user.id))
                .onSuccess { call.respond(HttpStatusCode.Created, it) }
                .onFailure { error ->
                    when (error) {
                        is CreateOrderUseCase.Error.LimitReached -> call.respond(HttpStatusCode.BadRequest, LIMIT_REACHED)
                        is AllocateInventoryUseCase.Error -> dispatchInventoryError(error)   // one dispatcher per error family
                        is CommonError.SaveFailure -> { reporter.report(error); call.respond(HttpStatusCode.InternalServerError, "saving error") }
                        else -> throw error                                                  // StatusPages: report + 500
                    }
                }
        }
    }
}
```

Dependencies are resolved once per routing function with `by inject`, not per request. The
routing function contains **no `authenticate`**: the application mounts it under a tier. (The
public reference still opens `authenticate` inside its routing functions; that is the older
shape.)

Rules paid for with defects:

- **The tenant and the caller come from the access helper, never from the body**, and the tenant
  goes into **every** repository call, so a record of another tenant matches nothing. The id of a
  changed record comes from the path: ownership was once checked against the path while the write
  was addressed by the body, and a stranger's record was rewritten with a `200`.
- **"Not yours" and "does not exist" get one answer.** Which one is the contract's decision
  (`kmp-shared-contract`, status conventions); with the tenant in every filter it is naturally
  `404`. Two different answers reveal which ids exist.
- **An error the route does not know is rethrown** (`else -> throw error`), not swallowed into a
  `400`: swallowing turns a bug into a client error and hides it from the reporter. Unexpected
  failures the route does map (`SaveFailure` → `500`) are reported by the route.
- **Error-family dispatchers** (`dispatchInventoryError`) live next to the use cases whose errors
  they map, so every route that can hit them answers the same way.

## Tiers are decided at the mount

```kotlin
routing {
    route("/api") {
        authenticate(JWT) { route("/orders-app") { ordersRouting(); itemsRouting() } }   // user-facing: withAccess inside handlers
    }
    authenticate(JWT) {
        withRole("orders:bot") { route("/bot") { ordersRouting() } }                        // the same handlers for another client
        withAnyRole("orders:shop", "orders:admin") { route("/internal") { internalOrdersRouting() } }   // trusted services
    }
}
```

| Tier | Gate | Tenant scoping |
|---|---|---|
| user-facing | `authenticate` at the mount, `withAccess(min)` inside every handler | the helper checks the caller holds a role in the tenant named by the header |
| another client of the same routes (a bot) | `authenticate` + `withRole` at the mount | the same handlers; the helper resolves the user by the token's `azp` |
| service-to-service | `authenticate` + `withRole` / `withAnyRole` at the mount | the tenant header is read **raw on purpose**: the calling service acts across tenants and the role is the gate |
| management | a separate engine on a separate port plus a token plugin over the branch | outside is a `404`, not a `403` |
| open | outside `authenticate` | health, version, third-party callbacks |

A raw tenant header is a leak only on a route whose sole gate is "authenticated". A route
without a chosen tier has whatever the default gives it, usually open.

**`withAccess(min) { (user, tenantId) -> }`** resolves the caller from the principal (by `azp`:
an email for a human client, a header for a bot client), compares their role in the tenant
against `min` by an explicit **rank**, never `Enum.ordinal` (declaration order was the opposite
of privilege), and on refusal answers `403` and **logs the route and the required role, never
the token**: a bare `403` read as "the tenant was not created". **Role gates are route-scoped
plugins** on `AuthenticationChecked`, answering `403`, never `401` (which provokes a re-login).
Their dependencies come from DI inside the helper; prefer that over context parameters on every
routing function, which tax every new route. Code for the helper, the plugin and its selector
trap: [examples/routing-and-app.md](examples/routing-and-app.md).

## Errors become responses in one place, and are reported

`StatusPages` catches `Throwable`, rethrows `CancellationException`, **reports** the cause (if it
got here, nobody expected it, `400`s included), then answers: Ktor's own exceptions keep their
status through a shared `clientErrorStatus()` (a `Throwable` catch otherwise turns a malformed
header into a `500` in the error budget), `IllegalArgumentException` → `400`,
`NoSuchElementException` → `404`, everything else `500` **without the message**, logged first
with the whole exception (a reporter that caches to disk left `kubectl logs` empty on a crash).

`ErrorReporter` is a `fun interface` bound in DI, not an `expect`: substitutable in tests,
disabled in utilities; its default is **the log, not silence**, because telemetry sits behind an
environment gate. Plugin configuration (`Json`, CORS, `StatusPages`) is written **once** and
applied by both builds; `explicitNulls` set differently in two entry points is a different wire
format, and only a generated client notices. A CORS refusal is silent by nature; a small plugin
logging the refused origin turns "the form does nothing" into a line. Code:
[examples/routing-and-app.md](examples/routing-and-app.md).

## Storage: ports in common, one implementation per driver

- **The tenant is in every signature and every filter**, reads and writes alike; a route may
  check ownership too, the filter makes the next caller safe by default.
- **The transaction is a port** (`TransactionManager.withTransaction { }`) with no handle in the
  signature; the carrier travels in the `CoroutineContext` on the adapter side; `Noop` for
  domain tests; a nested call joins.
- **Ports are suspend even when a driver blocks**; the adapter hides the blocking behind
  `Dispatchers.IO`.
- **Two drivers agree on the stored representation**, not on class shapes: ids as the driver's
  id type, money as the database's decimal, collection names as constants; verified by a
  raw-document test per build.
- **Migrations, indexes and seeds run at start-up**, explicitly and idempotently, from a scope
  cancelled on `ApplicationStopping`; never from `init { launch }` of a repository. On
  Kotlin/Native an unhandled exception in a coroutine kills the process, so start-up work is
  wrapped and reported.

Port, both driver implementations, transaction adapters, the SQL variant and the migration traps:
[examples/storage-port-and-implementations.md](examples/storage-port-and-implementations.md).

## DI

- Feature modules bind use cases and services; storage modules bind ports to a driver; the
  application lists them. Config objects enter as `single { config.mongo }`.
- **Explicit lambda for any constructor with a default parameter** (a clock, an interval, an
  `HttpClient` a test swaps): `singleOf` resolves every parameter and fails **lazily**, at the
  first request of one route, while the pod starts healthy. A `verify()` test misses it too
  (defaults and nullable parameters are skipped); the graph test **resolves** every injected type,
  and its list is maintained by hand.

## Where the tests go

| What changed | Test | Suite |
|---|---|---|
| a route | an HTTP test on the harness: stubbed verifier, tenant header by default, the use case swapped through an override module; one per **tier** it is mounted under, the `403` for a role below `min` included | the build's suite |
| a use case | fakes of its ports (mocks in a JVM-only suite): success, each typed error, and that side effects did **not** happen on failure | `commonTest` or the JVM suite |
| a repository | a real database per test class; a raw-document test where the stored shape matters; on native the database URL from the **environment** | the build's suite |
| the graph | resolve every injected type | one per build |
| plugins | `testApplication` with a throwing route: Ktor exceptions keep their status, a real failure is a `500` without its message, the reporter saw both | the JVM suite |

Harness code and the native traps (`runBlocking` for a real database on native, a file rather
than `:memory:` for SQLite) are in `kmp-testing`. Run one Gradle test task per invocation and
trust the timestamps of `build/test-results`, not `BUILD SUCCESSFUL`: an incremental run can
report a task up to date while the XML is from the previous run.

## When the change is bigger than an endpoint

- **Configuration and secrets**: typed HOCON properties on a JVM-only service, an `EnvSource`
  class on a two-build one; a required secret has **no default** and fails start-up with a reason
  (random-with-a-warning is for a README demo only); optional integrations are gated on their
  key; `init { require }` validates. [examples/auth-provider-and-config.md](examples/auth-provider-and-config.md).
- **Background workers** (outbox, schedulers, expiry sweeps): classes with `start()` / `stop()`
  wired to `ApplicationStarted` / `ApplicationStopping`, intervals as defaulted parameters,
  registered with an explicit lambda; an outbox carries the id and the worker rereads the record.
  [examples/routing-and-app.md](examples/routing-and-app.md).
- **Kotlin/Native**: what leaves `commonMain` (`java.*`, HOCON, JVM-only auth and logging
  plugins, mocking libraries) and what replaces it; the **release test run is mandatory** because
  the release binary omits type-cast checks; liveness never touches storage because a vanished
  database can hang a native query. Table in [examples/composition-and-distributions.md](examples/composition-and-distributions.md).
- **A library-style server** (several distributions, two engines): a composition-root function
  with lambdas, an isolated `koinApplication` instead of the global `startKoin`, dependencies
  handed to routes explicitly. Same file.
- **OpenAPI from routes**: Ktor's route description DSL (`describe { }`, Ktor 3.3+ with the
  Ktor compiler plugin for inference) with small project helpers for headers and bodies; the
  committed spec is regenerated in the same change and CI fails on a diff. Two traps: one
  KDoc-style annotation turns inference off for the whole file; `call.receive` inside a shared
  handler function is invisible, so bodies are declared in `describe`. Internal routes are hidden.

## Checklist before the change is done

- [ ] resource and DTOs in the contract module; no string path in the server
- [ ] the tier chosen at the mount; user-facing handlers wrapped in `withAccess` with an explicit `min`
- [ ] the tenant and the caller flow from the helper into `Params` and into every repository call
- [ ] business rules in a use case with typed errors; the route dispatches them and rethrows the rest
- [ ] shape validation as a `xProblem()` function, tested at its boundaries
- [ ] every driver's implementation and its storage module updated, or "unchanged" stated
- [ ] a route test per tier; a use-case test per typed error; a raw-document test if the stored shape changed
- [ ] the graph test resolves every new injection; no default parameters under `singleOf`
- [ ] the OpenAPI spec regenerated and docs updated, "there is no…" claims included
- [ ] executed one test task per invocation with fresh result files, the native release run included
