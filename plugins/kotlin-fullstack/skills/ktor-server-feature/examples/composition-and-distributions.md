# The composition root, isolated containers and distributions

How a server is assembled when it is more than one `Application.module()`: a library-style
identity provider that ships as several distributions, and a service that runs on two engines.

## A composition root function

```kotlin
/**
 * Distributions differ in ONE thing: which sign-in methods they carry. Everything else lives
 * here, or two entry points drift apart in how they read the environment and in start-up order.
 *
 * @param storage comes from outside rather than being chosen here: wiring it through an ORM once
 *   made the shared start-up JVM-only. No default on purpose — a default would bring the
 *   dependency back.
 * @param observability whatever a distribution attaches to the public engine: metrics, a tracer,
 *   nothing. A parameter, because a provider that fails to start over unreachable telemetry
 *   takes sign-in down for a graph.
 * @param reporter where unexpected failures go; the default is the log, not silence.
 * @param authMethods assembled INSIDE the container: a method may need repositories.
 */
fun runService(
    storage: (ServiceConfig) -> Module,
    observability: Application.() -> Unit = {},
    reporter: ErrorReporter = ErrorReporter.Logging,
    authMethods: Scope.() -> List<AuthMethod>,
) {
    val config = loadConfig()
    service(
        config = config,
        storage = module {
            includes(storage(config))
            single { AuthMethodRegistry(authMethods()) }   // wired by a line in the build, not by reflection
        },
        observability = observability,
        reporter = reporter,
    ).start(wait = true)
}
```

A distribution is then two files: a `Main.kt` calling `runService(storage = { sqlStorageModule(it) })
{ listOf(PasswordAuthMethod(get(), get())) }` and a build file whose dependency list **is** the
feature set. A method that is not on the classpath cannot be switched on by any configuration.

## An isolated container and two engines

```kotlin
class Service(
    private val application: KoinApplication,
    private val public: EmbeddedServer<*, *>,
    private val management: EmbeddedServer<*, *>,
) {
    val koin: Koin get() = application.koin

    fun start(wait: Boolean = false) {
        management.start(wait = false)
        public.start(wait = wait)
    }

    fun stop() {
        public.stop()
        management.stop()
        application.close()          // OUR container, not the global one
    }
}

fun service(config: ServiceConfig, storage: Module, observability: Application.() -> Unit = {}, reporter: ErrorReporter): Service {
    // An isolated container, not the global startKoin: the global one made two servers in one
    // JVM impossible (KoinApplicationAlreadyStarted), and stopKoin on one tore the container
    // out from under the other. A suite where every class raises its own server failed from
    // this every other run, and the failure looked random.
    val application = koinApplication {
        modules(coreModule(config), domainModule(), storage, module { single { reporter } })
    }
    val koin = application.koin

    return Service(
        application = application,
        // Two engines rather than one with two connectors: the management routes physically do
        // not exist on the public port. A request to /admin from outside is a 404, not a 403 —
        // the existence of a management contour is not confirmed.
        public = embeddedServer(CIO, port = config.publicPort) { publicModule(koin); observability() },
        management = embeddedServer(CIO, port = config.managementPort) { managementModule(koin) },
    )
}

private fun Application.commonPlugins() {
    install(Resources)
    install(ContentNegotiation) {
        json(Json {
            ignoreUnknownKeys = true
            explicitNulls = false
            // kotlinx does NOT write defaults. Without this a response arrives without its
            // defaulted fields, and a typed client where the field is mandatory fails to parse.
            // Only a test against a real client catches it.
            encodeDefaults = true
        })
    }
}

fun Application.publicModule(koin: Koin) { commonPlugins(); healthRoutes(koin.get()); apiRoutes(koin) }
fun Application.managementModule(koin: Koin) { commonPlugins(); healthRoutes(koin.get()); adminRoutes(koin) }
```

With two engines `install(Koin)` is not used: it raises one container per Ktor application, and
the graph must stay single. Dependencies are handed to the routes explicitly (`adminRoutes(koin)`),
which also removes the question "which container did this come from" in tests.

## A gate over a whole branch, as a plugin

```kotlin
val AdminAuth = createRouteScopedPlugin("AdminAuth", ::AdminAuthConfig) {
    val access = requireNotNull(pluginConfig.access) { "AdminAuth without AdminAccess" }

    onCall { call ->
        val presented = call.request.header("Authorization")?.removePrefix("Bearer ")?.trim()
            ?: call.request.header("X-Service-Token")
        if (!access.accepts(presented)) {
            // Neither a reason nor a hint: "wrong token" and "bootstrap already closed" look the same.
            call.respond(HttpStatusCode.Unauthorized, ErrorView("unauthorized"))
        }
    }
}

fun Application.adminRoutes(koin: Koin) {
    routing {
        // The gate covers the whole /admin branch rather than each handler: forgetting it on one
        // route is a matter of time, and the price is highest here. The resources carry the
        // /admin prefix themselves and Ktor reuses the node, so the plugin applies to them too.
        route("/admin") { install(AdminAuth) { access = koin.get() } }
        tenantRoutes(koin)
        clientRoutes(koin)
    }
}
```

## The two-build service: the entry points share the plugin code

```kotlin
// jvmMain — Application.module() from EngineMain
fun Application.module() {
    install(Koin) { slf4jLogger(); modules(appModules()) }
    configureReporter(get())
    configureCors(get<ServiceConfig>().corsExtraHosts)
    configureLogging()
    install(Resources)
    install(ContentNegotiation) { json(serviceJson) }
    configureStatusPages(get())
    configureAuth(get(), validate = ::accessAllowed)   // the rule is shared, not rewritten here
    configureRouting()
    startWorkers()
}

// linuxX64Main — main()
fun main() {
    val config = ServiceConfig()
    embeddedServer(CIO, port = config.port) {
        install(Koin) { modules(nativeAppModules(config)) }
        launch {
            // On Kotlin/Native an unhandled exception in a coroutine kills the PROCESS, with a
            // core dump. Start-up work is wrapped and reported; the service comes up with a red
            // readiness rather than not at all.
            runCatching { ensureStorageReady(getKoin()) }
                .onFailure { getKoin().get<ErrorReporter>().report(it); log.error("storage not ready", it) }
        }
        config.reporter?.let { startReporter(it) }        // gated on its key
        configureStatusPages(getKoin().get())
        configureCors(config.corsExtraHosts)
        install(CallLog)                                   // CallLogging is JVM-only
        install(Resources)
        install(ContentNegotiation) { json(serviceJson) }  // the SAME Json object as the JVM build
        configureAuth(config.oidc, validate = ::accessAllowed)
        config.metrics?.let { install(Metrics) { apiKey = it.apiKey } }
        routing { nativeRoutes() }
    }.start(wait = true)
}
```

The list of what drifted when the two entry points each had their own copy: CORS missing on one
build (the browser's request never arrived, no log, no report), `explicitNulls` different (a
different response format for the generated client), `StatusPages` collapsing everything into
`500`. None of the three fails a build or a test; they are noticed after switching the image.
