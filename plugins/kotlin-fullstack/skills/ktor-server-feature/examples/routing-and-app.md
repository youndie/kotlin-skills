# Application assembly, tiers at the mount, the access helper, role gates

The first half is the public reference project (a two-build server, comments translated). The
second half is the multi-tenant shape of larger services, written generically.

## The shared assembly (`server-common`)

```kotlin
/**
 * DI shared by both builds: configuration, tokens, hashing, sign-in.
 *
 * Storage is not here: each build brings its own module. Everything else must be one body of
 * code: a TokenService that drifted apart would mean a token from one build is refused by the other.
 */
fun coreModule(config: ManiConfig): Module = module {
    single<ManiConfig> { config }
    single<JWTConfig> { config.jwt }
    single<MongoConfig> { config.mongo }
    single<TokenService> { TokenService(config.jwt) }
    single<HashingService> { Sha256HashingService() }
    single<AuthService> { AuthService(get(), get(), get()) }
    single<DemoSandboxCleaner> { DemoSandboxCleaner(get(), get()) }
    single<DemoService> { DemoService(get(), get(), get(), get(), get()) }
}

/** Plugins identical for both builds. CORS only in development: on the stand the same server serves the frontend. */
fun Application.configureManiPlugins(config: ManiConfig) {
    if (config.development) {
        install(CORS) {
            allowMethod(HttpMethod.Options); allowMethod(HttpMethod.Post)
            allowMethod(HttpMethod.Patch); allowMethod(HttpMethod.Delete); allowMethod(HttpMethod.Get)
            allowHeader(HttpHeaders.ContentType); allowHeader(HttpHeaders.Authorization)
            exposeHeader(HttpHeaders.Authorization)
            anyHost()
        }
    }

    // What to answer to what the route did not expect. Without this an invalid ObjectId in the
    // path gave 500 — silently on the native build, which has no logger in the common part.
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            if (cause is CancellationException) throw cause
            when (cause) {
                is BadRequestException, is IllegalArgumentException, is SerializationException,
                -> call.respond(HttpStatusCode.BadRequest, "Malformed request")
                else -> {
                    println("mani: ${call.request.httpMethod.value} ${call.request.uri} — $cause")
                    call.respond(HttpStatusCode.InternalServerError)
                }
            }
        }
    }

    install(Resources)
    install(ContentNegotiation) {
        // No `isLenient`: it let bodies arrive unquoted, i.e. the server guessed what the sender
        // meant. Our clients write JSON with a serializer; leniency served only whoever bypasses them.
        json(Json { prettyPrint = true })
    }
}

/** Token verification. A separate call after Koin: TokenService comes out of the graph, not a second instance. */
fun Application.configureManiAuth(config: ManiConfig, tokenService: TokenService) {
    install(Authentication) { maniJwt(config.jwt.name, tokenService) }
}

/** API routes. Static files are served differently by each build and wired by each build. */
fun Routing.maniApiRouting() {
    authRouting()
    categoryRouting()
    demoRouting()
    healthRouting()
    currencyRouting()
    transactionRouting()
    userRouting()
}
```

## The JVM entry point (`server`)

```kotlin
fun main(args: Array<String>) = EngineMain.main(args)

/** The JVM build. The port comes from application.conf via EngineMain; everything else from ENV, same names as native. */
fun Application.module() {
    val config = ManiConfig.fromEnv()
    configureManiPlugins(config)
    install(Koin) {
        slf4jLogger()
        modules(coreModule(config), mongoStorageModule(config.mongo))
    }
    configureManiAuth(config, get<TokenService>())
    configureRouting()
}
```

## The native entry point (`server-native`)

```kotlin
fun main() {
    val config = ManiConfig.fromEnv()
    println("mani: starting on port ${config.port}, mongo ${config.mongo.host}")
    embeddedServer(CIO, port = config.port) { maniModule(config) }.start(wait = true)
}

/** Assembly, as a function of its own so a test can bring it up through testApplication with the wiring that ships. */
fun Application.maniModule(config: ManiConfig) {
    configureManiPlugins(config)
    install(Koin) {
        // Koin's default logger here: koin-logger-slf4j is JVM-only.
        modules(coreModule(config), mongknStorageModule(config.mongo))
    }
    configureManiAuth(config, get<TokenService>())

    // The static directory is read ONCE at startup, not per request: the files are baked into the
    // image and do not change over the life of the process. An empty MANI_WEB_ROOT means a server
    // without a frontend — convenient for tests and local runs.
    val assets = config.webRoot?.let(WebAssets::scan)
    routing {
        maniApiRouting()
        if (assets != null) webRoutes(assets)
    }
}
```

## Who is calling

```kotlin
/** Who came. Put on the call after a successful token check. */
data class ManiPrincipal(val id: String, val username: String)

/**
 * Called ONLY inside `authenticate`, where a request without a principal never arrives: the
 * provider itself answers 401. A missing principal here is not a request state but an
 * unprotected route — a wiring mistake — and it must be loud.
 *
 * The previous version answered 401 and returned an EMPTY STRING without stopping the handler.
 * Inside `authenticate` the branch is dead, but outside it the empty string would go into storage
 * as the owner, and the next `respond` on top of the 401 already sent would throw. The trap was
 * waiting for the first route that forgot `authenticate`.
 */
fun ApplicationCall.currentUserId(): String = principal<ManiPrincipal>()?.id
    ?: error("currentUserId() called outside authenticate: the route is not protected by a token check")
```

## The complete transaction routing

```kotlin
fun Routing.transactionRouting() {
    val transactionRepository by inject<TransactionRepository>()
    val categoryRepository by inject<CategoryRepository>()
    val jwtConfig by inject<JWTConfig>()

    authenticate(jwtConfig.name) {
        post<TransactionResource> {
            val transaction = call.receive<Transaction>()

            val problem = transactionProblem(transaction)
            if (problem != null) {
                call.respond(HttpStatusCode.BadRequest, problem)
                return@post
            }

            val userId = call.currentUserId()

            // Categories are read here, not in the repository: they live in the user document and
            // the transaction repository knows nothing about them. Forgetting this substitution
            // would return every transaction with the default category, breaking nothing.
            val categories = categoryRepository.getByUser(userId)

            val id = transactionRepository.create(transaction, userId)
            val added = transactionRepository.getById(id)
            if (added == null) {
                call.respond(HttpStatusCode.NotFound)
                return@post
            }

            call.respond(HttpStatusCode.Created, added.toTransaction(categories))
        }

        get<TransactionResource> {
            val userId = call.currentUserId()
            val categories = categoryRepository.getByUser(userId)
            call.respond(HttpStatusCode.OK, transactionRepository.getByUser(userId).map { it.toTransaction(categories) })
        }

        patch<TransactionResource.ById> { path ->
            val new = call.receive<Transaction>().copy(id = path.id)

            val problem = transactionProblem(new)
            if (problem != null) {
                call.respond(HttpStatusCode.BadRequest, problem)
                return@patch
            }

            val userId = call.currentUserId()
            val old = transactionRepository.getById(path.id)
            if (old?.userId != userId) {
                call.respond(HttpStatusCode.Forbidden)
                return@patch
            }
            transactionRepository.update(new, userId)
            call.respond(HttpStatusCode.OK, new)
        }

        delete<TransactionResource.ById> { path ->
            val transaction = transactionRepository.getById(path.id)
            if (transaction?.userId != call.currentUserId()) {
                call.respond(HttpStatusCode.Forbidden)
                return@delete
            }
            transactionRepository.delete(path.id)
            call.respond(HttpStatusCode.OK)
        }
    }
}
```

## Health

```kotlin
/** The build kind is the only thing the builds must differ in, hence the only expect/actual in this file. */
expect fun serverBuildKind(): String

private val startedAt = Clock.System.now()

fun Routing.healthRouting() {
    val storageHealth by inject<StorageHealth>()

    // Readiness: one request into the database per probe. A driver failure is "not ready", not 500:
    // the probe needs a status code, not a diagnosis. suspendRunCatching so that a cancelled
    // request is not reported as "the database is down". No timeout of its own on purpose: a wrapper
    // around a blocking call cannot enforce one; the kubelet's timeoutSeconds decides how long to wait.
    get<HealthResource.Ready> {
        val reachable = suspendRunCatching { storageHealth.isReachable() }.getOrElse { false }
        if (reachable) call.respond(HttpStatusCode.OK, "ready")
        else call.respond(HttpStatusCode.ServiceUnavailable, "storage unreachable")
    }

    get<HealthResource> {
        call.respond(Health(build = serverBuildKind(), version = MANI_VERSION,
            uptimeSeconds = (Clock.System.now() - startedAt).inWholeSeconds))
    }
}
```


## Mounting the same routing functions under several tiers

```kotlin
fun Application.configureRouting() {
    routing {
        healthRouting()

        route("/api") {
            versionRouting()
            authenticate(JWT) {
                route("/orders-app") {              // user-facing: every handler wraps itself in withAccess
                    ordersRouting()
                    itemsRouting()
                    staffRouting()
                }
            }
        }

        authenticate(JWT) {
            withRole("orders:bot") {                // another client of the SAME handlers
                route("/bot") {
                    ordersRouting()
                    itemsRouting()
                }
            }

            withAnyRole("orders:shop", "orders:admin") {   // trusted services: the role is the gate,
                route("/internal") {                       // the tenant header is read raw on purpose
                    internalOrdersRouting()
                }
            }
        }
    }
}
```

## The access helper: caller, tenant, minimum role

```kotlin
enum class Role { OWNER, MANAGER, VIEWER }

/**
 * Privilege by explicit rank, NOT Enum.ordinal: the declaration order is the opposite of
 * privilege, and a silent tie to ordinal is a ready-made hole when a role is added.
 */
private val Role.rank: Int get() = when (this) { Role.OWNER -> 3; Role.MANAGER -> 2; Role.VIEWER -> 1 }
fun Role.permits(min: Role): Boolean = rank >= min.rank

data class Access(val user: User, val workspaceId: String)

/** The caller, resolved by who the token says the client is. */
suspend fun RoutingContext.currentUser(): User? {
    val principal = call.principal<OidcPrincipal>() ?: return null
    val users = call.application.get<GetOrCreateUserUseCase>()
    return when (principal.azp) {
        "orders-bot" if "orders:bot" in principal.roles -> users(GetOrCreateUserUseCase.ByExternalId(call.request.header("X-Bot-User") ?: return null)).getOrNull()
        "orders-web" if principal.email != null -> users(GetOrCreateUserUseCase.ByPrincipal(principal)).getOrNull()
        else -> null
    }
}

/**
 * Lets the request through only if the caller holds a role in the workspace named by the header
 * with privileges not below [min]. Reads default to VIEWER, writes raise it to MANAGER, owner
 * operations to OWNER.
 */
suspend inline fun RoutingContext.withAccess(min: Role = Role.VIEWER, crossinline block: suspend (Access) -> Unit) {
    val workspaceId = call.request.header("X-Workspace-Id") ?: throw BadRequestException("Missing X-Workspace-Id")
    val user = currentUser()
    val granted = user?.roles?.any { it.workspaceId == workspaceId && it.role.permits(min) } == true

    if (!granted) {
        // Name the route and the required role; never the token. A bare 403 read as "the
        // workspace was not created", and which role was missing nobody said.
        accessLog.warn("no access: ${call.request.httpMethod.value} ${call.request.path()}, needs $min in $workspaceId")
        call.respond(HttpStatusCode.Forbidden)
        return
    }
    block(Access(user, workspaceId))
}
```

## A role gate as a route-scoped plugin

```kotlin
class RoleRequirement { var roles: Set<String> = emptySet(); var any: Boolean = true }

val RoleAuthorization = createRouteScopedPlugin("RoleAuthorization", ::RoleRequirement) {
    val required = pluginConfig.roles
    val any = pluginConfig.any
    // AuthenticationChecked, not onCall: the principal is parsed by then. Answering here stops
    // the pipeline; the handler body is never reached.
    on(AuthenticationChecked) { call ->
        val granted = call.principal<OidcPrincipal>()?.roles.orEmpty()
        val allowed = if (any) required.any { it in granted } else required.all { it in granted }
        // 403, not 401: 401 means "present a token" and provokes a re-login; the token was understood.
        if (!allowed) call.respond(HttpStatusCode.Forbidden)
    }
}

/**
 * A CLASS, not an object. createChild reuses an existing child with an equal selector, so on a
 * singleton two neighbouring role gates land on one node and the second fails with
 * DuplicatePluginException — at application start, i.e. as a crash loop, not as one refused request.
 */
private class RoleScopeSelector : RouteSelector() {
    override suspend fun evaluate(context: RoutingResolveContext, segmentIndex: Int) = RouteSelectorEvaluation.Transparent
}

private fun Route.roleScope(roles: Array<out String>, any: Boolean, build: Route.() -> Unit): Route =
    createChild(RoleScopeSelector()).apply {
        install(RoleAuthorization) { this.roles = roles.toSet(); this.any = any }
        build()
    }

fun Route.withRole(role: String, build: Route.() -> Unit) = roleScope(arrayOf(role), any = false, build)
fun Route.withAnyRole(vararg roles: String, build: Route.() -> Unit) = roleScope(roles, any = true, build)
```

## StatusPages with a reporter, and a CORS refusal that is no longer silent

```kotlin
fun Application.configureStatusPages(reporter: ErrorReporter) {
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            if (cause is CancellationException) throw cause
            // Before the answer, on any outcome including 400: if it got here, nobody expected it.
            reporter.report(cause)

            val clientStatus = cause.clientErrorStatus()          // Ktor's own: BadRequest→400, NotFound→404, …
                ?: when (cause) {
                    is IllegalArgumentException -> HttpStatusCode.BadRequest
                    is NoSuchElementException -> HttpStatusCode.NotFound
                    else -> null
                }

            val request = "${call.request.httpMethod.value} ${call.request.path()}"
            if (clientStatus != null) {
                call.application.log.info("$request → ${clientStatus.value}: ${cause.message}")
                call.respond(clientStatus, mapOf("error" to (cause.message ?: "Bad request")))
            } else {
                call.application.log.error("unhandled: $request", cause)   // the log first: a reporter that caches to disk leaves kubectl logs empty
                call.respond(HttpStatusCode.InternalServerError, mapOf("error" to "Internal server error"))
            }
        }
    }
}

/**
 * The CORS plugin answers 403 and writes nothing: from outside "the form does nothing", in the
 * request log a lone OPTIONS 403, and which origin was refused nobody says. The sign of a CORS
 * refusal: the request carried Origin and the response has no Access-Control-Allow-Origin.
 * ResponseSent, not onCallRespond: the CORS plugin completes the call earlier.
 */
val CorsRejectionLog = createApplicationPlugin("CorsRejectionLog") {
    on(ResponseSent) { call ->
        val origin = call.request.headers[HttpHeaders.Origin] ?: return@on
        if (call.response.status() == HttpStatusCode.Forbidden && call.response.headers[HttpHeaders.AccessControlAllowOrigin] == null) {
            corsLog.warn("CORS refused origin $origin on ${call.request.httpMethod.value} ${call.request.path()}")
        }
    }
}

/** Where faults go. A fun interface bound in DI: substitutable in tests, disabled in utilities — expect/actual could not be. */
fun interface ErrorReporter {
    fun report(error: Throwable)
    companion object {
        /** The default is the log, not silence: telemetry is gated, and a silent default lost every fault of an installation without a key. */
        val Logging = ErrorReporter { log.error("unhandled failure", it) }
        val Noop = ErrorReporter { }      // tests that check the absence of a reaction
    }
}
```

## Workers with a lifecycle

```kotlin
fun Application.module() {
    // … plugins, Koin, auth, routing …
    val indexes = get<IndexesScope>()
    val outbox = get<StockSyncOutboxWorker>()
    val expiry = get<ReserveExpiryWorker>()

    monitor.subscribe(ApplicationStarted) {
        indexes.launch { migrate(get()) }   // idempotent; survives restarts and several replicas
        outbox.start()
        expiry.start()
    }
    monitor.subscribe(ApplicationStopping) {
        indexes.cancel()
        outbox.stop()
        expiry.stop()
    }
}

fun main(args: Array<String>) {
    // A start-up exception used to vanish: the reporter caught it and cached the report inside
    // the container, the pod died with code 1 and an empty stderr — a silent crash loop.
    try {
        EngineMain.main(args)
    } catch (cause: Throwable) {
        System.err.println("startup failed: ${cause::class.simpleName}: ${cause.message}")
        cause.printStackTrace()
        throw cause
    }
}
```
