# A route harness over a real database, and the tests that use it

## JVM: the shared harness

```kotlin
/**
 * The server brought up exactly as in production, over a real mongod.
 *
 * Shared by every test in :server. It used to be a copy in each test class — three of them, and
 * a fix would have been needed in all at once.
 *
 * @param database a database of its own per run: tests do not interfere with each other
 * @param overrides modules declared after the shared ones. Koin takes the last definition, so this
 *   swaps one dependency rather than assembling a second graph
 * @param block the test body; the mongod address comes as a parameter for those who check not the
 *   server's answer but what remained in the database
 */
internal fun maniTest(
    database: String = "mani-test",
    overrides: List<Module> = emptyList(),
    block: suspend ApplicationTestBuilder.(mongoUri: String) -> Unit,
) {
    val running = Mongod.instance().start(Version.V8_0_3)
    try {
        val address = running.current().serverAddress.toString()
        val config = ManiConfig(port = 0, mongo = MongoConfig(host = address, database = database), jwt = JWTConfig(), webRoot = null, development = false)

        testApplication {
            application {
                configureManiPlugins(config)
                install(Koin) { modules(listOf(coreModule(config), mongoStorageModule(config.mongo)) + overrides) }
                configureManiAuth(config, get<TokenService>())
                routing { maniApiRouting() }
            }
            block("mongodb://$address")
        }
    } finally {
        stopKoin()
        running.close()
    }
}

/** Creates a user and returns their access token. */
internal suspend fun HttpClient.signIn(name: String, password: String): String {
    val credentials = maniJson.encodeToString(LoginParams.serializer(), LoginParams(name, password))
    val signup = post("/users") { contentType(ContentType.Application.Json); setBody(credentials) }
    val response = post("/auth") { contentType(ContentType.Application.Json); setBody(credentials) }
    // The registration refusal is visible only here: without it sign-in answers 404 and the test
    // reads as "no such route", although the problem is the password or a taken name.
    assertEquals(HttpStatusCode.OK, response.status, "sign-in refused; registration answered ${signup.status}: ${signup.bodyAsText()}")
    return maniJson.decodeFromString(Tokens.serializer(), response.bodyAsText()).accessToken
}

internal suspend fun HttpClient.createTransaction(token: String, comment: String): Transaction { /* POST /transactions */ }
internal suspend fun HttpClient.patchTransaction(token: String, path: String, body: Transaction): HttpResponse { /* PATCH */ }
internal suspend fun HttpClient.transactions(token: String): List<Transaction> { /* GET */ }
```

## The ownership test (JVM); its twin lives in the native suite

```kotlin
/**
 * One record, one owner, checked on the JVM build.
 *
 * The same cases are checked by ManiApiTest in :server-native, and that is not duplication: the
 * route is shared, but the write filter belongs to each storage implementation. The hole lived
 * precisely on the seam between shared code and an implementation, and one check on one build is
 * not enough — the second implementation can be fixed while the first stays open.
 */
class OwnershipTest {

    /**
     * The id is edited by the path, not by the body.
     * Ownership looked at path.id while the document to write was chosen by the body's id: a PATCH
     * to YOUR OWN record with a stranger's in the body rewrote theirs, changing the owner to the
     * caller. The answer was 200, so from outside everything looked fine.
     */
    @Test
    fun `a stranger cannot patch a foreign transaction through the id in the body`() = maniTest {
        val client = createClient { }
        val owner = client.signIn("owner", "hunter22")
        val stranger = client.signIn("stranger", "hunter22")
        val theirs = client.createTransaction(owner, "theirs")
        val mine = client.createTransaction(stranger, "mine")

        // Head on: a foreign id in the path. Closed before.
        assertEquals(HttpStatusCode.Forbidden, client.patchTransaction(stranger, path = theirs.id, body = theirs.copy(comment = "stolen")).status)

        // Around: own id in the path, a foreign one in the body.
        assertEquals(HttpStatusCode.OK, client.patchTransaction(stranger, path = mine.id, body = theirs.copy(comment = "stolen")).status)

        val ownersNow = client.transactions(owner)
        assertEquals(1, ownersNow.size, "the foreign record changed owner")
        assertEquals("theirs", ownersNow.single().comment, "the foreign record was rewritten")
        // And one's own record is edited: the path decides what is written.
        assertEquals(listOf("stolen"), client.transactions(stranger).map { it.comment })
    }
}
```

## Native: a database alongside, one per run

```kotlin
/**
 * A real mongod, not a fake. Everything that could break here breaks SILENTLY: a filter on _id as
 * a string finds nothing, an amount as a string is written without error, a missing
 * @SerialName("_id") gives the document a stray key. A unit test with a fake storage sees none of
 * these; only the server does.
 *
 * The address comes from MANI_TEST_MONGO_HOST, defaulting to the local one. Each run works in ITS
 * OWN database, so tests do not interfere and do not touch the stand's database.
 */
object TestMongo {
    val host: String get() = readEnv("MANI_TEST_MONGO_HOST") ?: "127.0.0.1:27017"
    fun uniqueDatabaseName(prefix: String): String = "mani_test_${prefix}_${BsonObjectId.generate().hex}"
    fun client(): MongoClient = MongoClient("mongodb://$host/?w=majority&appName=ManiTest")
    fun config(webRoot: String? = null): ManiConfig = ManiConfig(port = 0, mongo = MongoConfig(host = host), jwt = JWTConfig(secret = "test-secret"), webRoot = webRoot, development = false)
}

/** Acceptance of the native build as a whole: HTTP, JSON, DI, token issue and check, the database — through the same maniModule that goes into the image. */
class ManiApiTest {
    private fun withMani(block: suspend ApiScope.() -> Unit) {
        val config = TestMongo.config().let { it.copy(mongo = it.mongo.copy(database = TestMongo.uniqueDatabaseName("api"))) }
        testApplication {
            application { maniModule(config) }
            val http = createClient { install(ContentNegotiation) { json(Json { ignoreUnknownKeys = true }) } }
            try {
                ApiScope(http).block()
            } finally {
                // The test's database is taken along: many runs, one mongod.
                TestMongo.client().use { it.getDatabase(config.mongo.database).drop() }
            }
        }
    }

    // No comma in the name: Kotlin/Native rejects it when compiling the test.
    @Test
    fun `register then login then use the token`() = runBlocking { withMani { /* ... */ } }
}
```

## A route that forgot `authenticate`

```kotlin
/**
 * A route that forgot `authenticate` does not answer as if the owner were known.
 * currentUserId() used to answer 401 and an EMPTY STRING without stopping the handler: the empty
 * owner went into storage and the next `respond` landed on top of the answer already sent. Now the
 * call throws, and the failure must look like a 500 — a server error, not a request error.
 * No storage is needed: it never gets that far. Only StatusPages from configureManiPlugins.
 */
class UnprotectedRouteTest {
    @Test
    fun `a route outside authenticate cannot ask who is calling`() = runBlocking {
        testApplication {
            application {
                configureManiPlugins(TestMongo.config())
                routing { get("/leak") { call.respond(call.currentUserId()) } }
            }
            // Were the empty owner to come back, this would be 200 with an empty body.
            assertEquals(HttpStatusCode.InternalServerError, client.get("/leak").status)
        }
    }
}
```

## The graph, per build

```kotlin
/**
 * The JVM build's graph assembles as a whole. Dependencies are CREATED, not checked by reflection:
 * verify() walks constructors and trips over ManiConfig, which is put into the graph as a ready
 * object. Creation is also stricter — it catches a mistyped port binding. No Mongo connection
 * arises: the driver connects lazily, on the first operation. The native build has its own such
 * test: the storage modules differ.
 */
class ServerKoinModuleTest {
    @Test
    fun checkKoinModule() {
        val koin = startKoin { modules(coreModule(config), mongoStorageModule(config.mongo)) }.koin
        assertNotNull(koin.get<TokenService>())
        assertNotNull(koin.get<UserRepository>())
        assertNotNull(koin.get<TransactionRepository>())
        koin.get<MongoClient>().close()
    }
}

// native: checkModules is deprecated in favour of verify(), but verify() rests on reflection and exists on the JVM only.
class DiNativeTest {
    @Suppress("DEPRECATION")
    @Test
    fun checkKoinModule() {
        val config = TestMongo.config()
        startKoin { modules(coreModule(config), mongknStorageModule(config.mongo)) }.checkModules()
    }
}
```


## A harness for a service with use cases, roles and a tenant header

```kotlin
/** A stub verifier: any HS256 token signed with "test" is accepted; the principal is built from its claims. */
fun Application.configureTestAuth() {
    install(Authentication) {
        jwt(JWT_AUTH) {
            verifier { JWT.require(Algorithm.HMAC256("test")).build() }
            validate { credential -> OidcPrincipal(JWTPrincipal(credential.payload), azp = "orders-web", email = "owner@example.test", roles = emptySet()) }
        }
    }
}

const val WORKSPACE = "64a1b2c3d4e5f60718293a4b"
val token: String = JWT.create().withClaim("azp", "orders-web").withClaim("email", "owner@example.test").sign(Algorithm.HMAC256("test"))

/** The caller of every test: an owner of the test workspace. Override with a lower role to test a gate. */
fun authModuleWithRole(role: Role = Role.OWNER) = module {
    single<GetOrCreateUserUseCase> {
        FakeGetOrCreateUser(User(id = "u-1", roles = listOf(WorkspaceRole(WORKSPACE, role))))
    }
}

fun ApplicationTestBuilder.createTestClient() = createClient {
    install(Resources)
    install(ContentNegotiation) { json(Json { ignoreUnknownKeys = true }) }
    defaultRequest {
        url.encodedPath = "/api/orders-app/"
        contentType(ContentType.Application.Json)
        header(HttpHeaders.Authorization, "Bearer $token")
        if (headers["X-Workspace-Id"] == null) header("X-Workspace-Id", WORKSPACE)
    }
}

fun Application.configureTestApplication(modules: List<Module>) {
    configureTestAuth()
    install(Koin) { modules(modules) }
    configurePlugins()
    configureRouting()
}
```

```kotlin
class OrdersRoutePostTest {
    @Test
    fun `an order is created`() = testApplication {
        client = createTestClient()
        val useCase = FakeCreateOrder(result = Result.success(anOrder()))
        application { configureTestApplication(listOf(module { single<CreateOrderUseCase> { useCase } }, authModuleWithRole())) }

        val response = client.post(OrdersResource()) { setBody(anOrderParams()) }

        assertEquals(HttpStatusCode.Created, response.status)
        assertEquals(WORKSPACE, useCase.lastParams?.workspaceId, "the tenant did not reach the use case from the header")
    }

    /** The gate: a viewer cannot create. The route is the same; the role module differs. */
    @Test
    fun `a viewer is refused`() = testApplication {
        client = createTestClient()
        application { configureTestApplication(listOf(module { single<CreateOrderUseCase> { FakeCreateOrder() } }, authModuleWithRole(Role.VIEWER))) }

        assertEquals(HttpStatusCode.Forbidden, client.post(OrdersResource()) { setBody(anOrderParams()) }.status)
    }

    @Test
    fun `a limit refusal is a 400 with the limit text`() = testApplication {
        client = createTestClient()
        val useCase = FakeCreateOrder(result = Result.failure(CreateOrderUseCase.Error.LimitReached))
        application { configureTestApplication(listOf(module { single<CreateOrderUseCase> { useCase } }, authModuleWithRole())) }

        val response = client.post(OrdersResource()) { setBody(anOrderParams()) }

        assertEquals(HttpStatusCode.BadRequest, response.status)
        assertEquals(ORDER_LIMIT_REACHED, response.bodyAsText())
    }
}
```

## A real database per test class (JVM) and a URL from the environment (native)

```kotlin
/**
 * One embedded mongod per test class. This is the documented exception to "kotlin.test only":
 * a per-class fixture needs JUnit 5's @BeforeAll/@AfterAll (kotlin.test has @BeforeTest per
 * test, and starting mongod per test costs seconds each). It stays in a JVM-only suite, where
 * the constraint that motivates kotlin.test does not apply.
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
abstract class BaseMongoRepositoryTest {
    private lateinit var running: TransitionWalker.ReachedState<RunningMongodProcess>
    protected lateinit var client: MongoClient
    protected abstract val collectionName: String
    protected val db get() = client.getDatabase("test")

    @BeforeAll fun startMongo() {
        running = Mongod.instance().start(Version.V8_0_3)
        client = MongoClient.create("mongodb://${running.current().serverAddress}")
        runBlocking { db.createCollection(collectionName) }
    }

    @AfterAll fun stopMongo() { running.close(); client.close() }
}
```

```kotlin
// linuxX64Test — the address is the environment's, with a default for a local docker run
val mongoTestUrl: String = readEnv("TEST_MONGO_URL") ?: "mongodb://127.0.0.1:27017"

class MongknOrderRepositoryTest {
    @Test
    fun `update upserts on the first call and replaces on the second`() = runBlocking {   // runBlocking: real time
        MongoClient(mongoTestUrl).use { client ->
            val db = client.getDatabase("orders_test")
            db.getCollection("orders").drop()
            val repository = MongknOrderRepository(db)

            repository.update(anOrder(id = ID, comment = "first"))
            repository.update(anOrder(id = ID, comment = "second"))

            assertEquals("second", repository.getById(ID, WORKSPACE)?.comment)
            assertEquals(1L, db.getCollection("orders").countDocuments(), "one document, not two")
            db.getCollection("orders").drop()
        }
    }
}
```
