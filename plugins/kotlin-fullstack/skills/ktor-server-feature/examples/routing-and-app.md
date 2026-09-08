# Application assembly and a complete routing function

From the reference project, comments translated.

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
