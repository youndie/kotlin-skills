# Client tests: view model, networking, Compose UI, screenshots, the graph

## A reusable fake repository (`desktopTest`)

```kotlin
class FakeTransactionsRepository(
    private val shouldCrash: () -> Boolean = { false },
    private val transactions: List<Transaction> = listOf(/* two fixtures */),
) : TransactionRepository {
    private val data = MutableStateFlow(emptyList<Transaction>())
    override val dataStateFlow: StateFlow<List<Transaction>> = data

    override suspend fun load() {
        if (shouldCrash()) throw RuntimeException("fake")
        data.value = transactions
    }
    override fun getById(transactionId: String): Transaction = data.value.first { it.id == transactionId }
    override suspend fun create(params: Transaction): Transaction { if (shouldCrash()) throw RuntimeException("fake"); data.value += params; return params }
    override suspend fun update(params: Transaction): Boolean { data.value = data.value - getById(params.id) + params; return true }
    override suspend fun delete(transactionId: String): Boolean { data.value -= getById(transactionId); return true }
    override fun reset() { data.value = emptyList() }
    override val showingCacheFrom = MutableStateFlow<Instant?>(null)
}
```

## View model

```kotlin
private fun testModule(repository: TransactionRepository) = module {
    single<TransactionRepository> { repository }
    single<GetTransactionsUseCase> { GetTransactionsUseCase(get()) }
    single<GetCurrentCurrencyUseCase> { GetCurrentCurrencyUseCase(get()) }
    single<CurrentCurrencyRepository> { object : CurrentCurrencyRepository { override var currency = Currency.Usd } }
    single<DeleteTransactionsUseCase> { DeleteTransactionsUseCase(get()) }
    single<TransactionsViewModel> { TransactionsViewModel(get(), get(), get()) }
}

@OptIn(ExperimentalCoroutinesApi::class)
class TransactionsViewModelErrorTest : KoinTest {
    private lateinit var viewModel: TransactionsViewModel

    @BeforeTest
    fun setUp() {
        // The dispatcher is replaced BEFORE the model is built: its init already launches into
        // viewModelScope, i.e. onto Main, and a model built before the swap starts on the real one.
        Dispatchers.setMain(StandardTestDispatcher())
        startKoin { modules(testModule(FakeTransactionsRepository({ true }))) }
        viewModel = get()
    }

    /**
     * A network failure is a state of the whole screen, as on the main one.
     * Before, the history showed "Network Error" over an empty list and tried nothing more: an empty
     * list reads as "no rules", although the rules are there and the connection is gone.
     */
    @Test
    fun testLoadTransactionsFailed() = runTest {
        while (viewModel.observe.value.loading) runCurrent()

        val unreachable = assertNotNull(viewModel.observe.value.unreachable, "history stayed silent about the failure")
        assertNotNull(unreachable.cause, "no cause named: by code and host a person tells their network from a foreign server")
        assertTrue(viewModel.observe.value.data.isEmpty())
    }

    @AfterTest
    fun tearDown() { stopKoin(); Dispatchers.resetMain() }
}
```

## Networking with `MockEngine`, mirroring the production client

```kotlin
/**
 * What happens when the server refuses to extend the session.
 * Before, on a 401 the tokens were cleared and the body was parsed anyway — and the parse failed
 * on an empty body. It surfaced as a network failure: "server unreachable" with a countdown, and no
 * way to the welcome screen.
 */
class RefreshSessionTest {
    private class InMemoryStorage(private var tokens: BearerTokens?) : TokenStorage {
        override fun load(): BearerTokens? = tokens
        override fun save(bearerTokens: BearerTokens) { tokens = bearerTokens }
    }

    private fun client(status: HttpStatusCode, body: String) = HttpClient(
        MockEngine { respond(ByteReadChannel(body), status, headersOf("Content-Type", ContentType.Application.Json.toString())) },
    ) {
        install(Resources)
        install(ContentNegotiation) { json(Json { ignoreUnknownKeys = true }) }
        // The same default the production client sets: without it ContentNegotiation does not
        // serialise the body and the request fails before it is sent.
        defaultRequest { contentType(ContentType.Application.Json) }
    }

    private fun repository(refreshToken: String) = TokenRepositoryCommon(InMemoryStorage(BearerTokens("access", refreshToken)))

    @Test
    fun aRefusedRefreshEndsTheSessionAndSaysSo() = runTest {
        val tokens = repository("stale")
        val heard = mutableListOf<Unit>()
        backgroundScope.launch { tokens.expired.collect { heard += it } }
        testScheduler.runCurrent()

        val result = refreshSession(client(HttpStatusCode.Unauthorized, ""), tokens)
        testScheduler.runCurrent()

        assertNull(result, "nothing to extend — there must be no pair")
        assertEquals("", tokens.getToken().refreshToken, "tokens not cleared")
        assertEquals(1, heard.size, "nobody learned the session expired")
    }

    /** A server failure is not the end of the session: a 500 is no reason to log out. */
    @Test
    fun aServerFailureLeavesTheSessionAlone() = runTest {
        val tokens = repository("good")
        val heard = mutableListOf<Unit>()
        backgroundScope.launch { tokens.expired.collect { heard += it } }
        testScheduler.runCurrent()

        assertNull(refreshSession(client(HttpStatusCode.InternalServerError, ""), tokens))
        assertEquals("good", tokens.getToken().refreshToken, "session cancelled because of a server failure")
        assertTrue(heard.isEmpty())
    }
}
```

## Compose UI on the stateless Content (`commonTest`)

```kotlin
/**
 * The credentials form as such: fields, the button, the error line.
 * The component is shared by sign-in and sign-up, so it is checked, not the two screens. State
 * comes from outside and is changed by the test as it goes — showing the form reflects state
 * rather than keeping its own.
 */
class AuthComponentTest {
    @OptIn(ExperimentalTestApi::class)
    @Test
    fun authComponentTest() {
        val stateFlow = MutableStateFlow(AuthComponentUiState(title = "AuthTest", username = "", password = "", buttonText = "Submit", errorMessage = null, loading = false))

        runComposeUiTest {
            setContent {
                val state = stateFlow.collectAsState()
                AuthComponentImpl(
                    state = state.value,
                    onUsernameChanged = { v -> stateFlow.update { it.copy(username = v) } },
                    onPasswordChanged = { v -> stateFlow.update { it.copy(password = v) } },
                    onButtonClicked = { stateFlow.update { it.copy(loading = true) } },
                )
            }

            onNodeWithTag("username").performTextInput("TESTER")
            assertEquals("TESTER", stateFlow.value.username)

            onNodeWithTag("login").performClick()
            assertTrue(stateFlow.value.loading)

            stateFlow.update { it.copy(loading = false, errorMessage = "Error!") }
            onNodeWithTag("errorMessage").assertTextEquals("Error!")
        }
    }
}
```

## Screenshots (`desktopTest`, a separate Gradle task)

```kotlin
/**
 * Screens are captured STATELESS, without dependency injection: otherwise the picture would depend
 * on the network and on what is in the database, and there would be nothing to compare it with.
 * Names in ASCII: the tool replaces non-ASCII with underscores, and two names would collapse.
 */
private const val WIDTH = 393
private const val HEIGHT = 852

@Composable
private fun Harness(content: @Composable () -> Unit) {
    AppTheme(darkTheme = true) { Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) { content() } }
}

/** "Today" for the pictures is pinned, not read from the clock: the day header labels today's row TODAY, and the goldens would live until midnight. */
private val demoToday = LocalDate(2026, 8, 17)

@ViddikScreenshot(name = "home forecast", group = "screens", width = WIDTH, height = HEIGHT)
@Composable
fun HomeForecastScreenshot() {
    Harness {
        MainContent(
            today = demoToday,
            transactions = /* fixed fixtures */,
            filtersState = FiltersState(loading = false, categories = persistentSetOf(Category("1", "Home"))),
            forecast = ForecastUiState.RunsOut("12 October", 60, "4 895 $"),
            // The chart is substituted with a ready state: by default MainContent resolves it
            // through Koin, and a picture must depend on neither the graph nor the network.
            chart = { expanded -> ChartComponent(ChartUi(days = fixedDays, currency = Currency.Usd, todayIndexProvider = { 30 }), expanded = expanded) },
        )
    }
}
```

## The Koin graph on the client

```kotlin
/**
 * verify() walks only the application modules. Screen view models are registered INSIDE components
 * through rememberKoinModules, so their dependencies do not get here: a missing binding is found
 * not by a test but by a black screen in the browser. That happened with SeedUseCase — green tests,
 * and the app died on opening the main screen. Below, those view models are added by hand.
 */
class ClientKoinModuleTest {
    @OptIn(KoinExperimentalAPI::class)
    @Test
    fun checkKoinModule() {
        module {
            includes(appModules)
            viewModelOf(::MainViewModel)
            viewModelOf(::AuthViewModel)
            viewModelOf(::WelcomeViewModel)
        }.verify(
            extraTypes = listOf(
                HttpClientEngine::class,
                HttpClientConfig::class,
                AuthUseCase::class,   // the screen chooses the binding: sign-in gives LoginUseCase, sign-up SignupUseCase
            ),
        )
    }
}

/**
 * Different data sources must not swap places. DataSource<T> is generic and generics are erased:
 * to Koin DataSource<Category> and DataSource<Transaction> are one key, and the last registration
 * wins for everybody. In the browser it looked like ClassCastException on opening the main screen.
 */
class DataSourceBindingTest : KoinTest {
    @AfterTest fun tearDown() = stopKoin()

    @Test
    fun sourcesAreBoundByName() {
        val koin = startKoin { modules(appModules) }.koin
        assertIs<TransactionsNetworkDataSource>(koin.get<DataSource<Transaction>>(named(TRANSACTIONS_SOURCE)))
        assertIs<CategoriesNetworkDataSource>(koin.get<DataSource<Category>>(named(CATEGORIES_SOURCE)))
        // And no source hangs on the unnamed key: that is the one that mixed them up.
        assertNull(koin.getOrNull<DataSource<Transaction>>(), "a data source is bound to the generic interface without a name again")
    }
}
```
