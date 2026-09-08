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

## View model: fakes of the use cases, the derived state collected

```kotlin
private class FakeRefreshAccountsUseCase(var result: Result<Unit> = Result.success(Unit)) : RefreshAccountsUseCase {
    var calls = 0
    override suspend fun invoke(params: Unit): Result<Unit> { calls++; return result }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AccountsListViewModelTest {
    private val testDispatcher = StandardTestDispatcher()
    private val accounts = MutableStateFlow<List<Account>>(emptyList())
    private val currencies = MutableStateFlow<List<Currency>>(emptyList())
    private val refresh = FakeRefreshAccountsUseCase()

    @BeforeTest fun setUp() = Dispatchers.setMain(testDispatcher)   // before the view model exists
    @AfterTest fun tearDown() = Dispatchers.resetMain()

    private fun createViewModel() = AccountsListViewModel(
        observeAccountsUseCase = ObservableUseCase { accounts },
        refreshAccountsUseCase = refresh,
        observeCurrenciesUseCase = ObservableUseCase { currencies },
    )

    /** The derivation: what comes out of the combine for a given input. */
    @Test
    fun `uiState should filter out unapproved accounts`() = runTest(testDispatcher) {
        accounts.value = listOf(account(1, state = ACTIVE), account(2, state = OPENING), account(3, state = CLOSED))
        val viewModel = createViewModel()

        viewModel.uiState.test {
            var state = awaitItem()
            while (state.totalAccounts == 0) state = awaitItem()

            assertEquals(1, state.items.size)
            assertEquals(3, state.totalAccounts)
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** The flags: an action flips one flag and erases nothing. */
    @Test
    fun `refresh failure should set the error and keep the list`() = runTest(testDispatcher) {
        accounts.value = listOf(account(1, state = ACTIVE))
        refresh.result = Result.failure(NoNetworkError())
        val viewModel = createViewModel()

        viewModel.uiState.test {
            var state = awaitItem()
            while (state.errorMessage == null) state = awaitItem()

            assertEquals(1, state.items.size, "the error erased the list")
            assertFalse(state.loading)
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** The events: an action leaves through events, not through the state. */
    @Test
    fun `AccountClick should emit OpenAccount`() = runTest(testDispatcher) {
        val viewModel = createViewModel()

        viewModel.events.test {
            viewModel.onAction(AccountsListUiAction.AccountClick(99L))
            assertEquals(AccountsListUiEvent.OpenAccount(99L), awaitItem())
        }
    }

    /**
     * The trap: a stateIn(WhileSubscribed) state stays at initialValue until collected.
     * Without the collector below, `.value` is the initial loading state forever and the assertion
     * would pass against it — for the wrong reason.
     */
    @Test
    fun `reading value needs a collector`() = runTest(testDispatcher) {
        accounts.value = listOf(account(1, state = ACTIVE))
        val viewModel = createViewModel()
        backgroundScope.launch { viewModel.uiState.collect {} }

        while (viewModel.uiState.value.totalAccounts == 0) runCurrent()

        assertEquals(1, viewModel.uiState.value.items.size)
    }
}
```

## The mapper, as a pure function

```kotlin
class AccountsUiMapperTest {
    @Test
    fun `account number is grouped for reading`() {
        val item = AccountsUiMapper.toListItem(account(number = "20208000100000000001"))
        assertEquals("20208 000 1 00000000 001", item.accountNumber)
    }

    @Test
    fun `an unknown kind falls back to the primary label instead of crashing`() {
        val item = AccountsUiMapper.toListItem(account(kind = AccountKind.Other("brand-new")))
        assertEquals(AccountStatusKindUi.Primary, item.type.kind)
    }
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

## Compose UI on the stateless Content

Rendering from fixtures, wiring through an action recorder:

```kotlin
@OptIn(ExperimentalTestApi::class)
class AccountsListContentTest {
    @Test
    fun `data state shows the items`() = runComposeUiTest {
        setContent { AppTheme { AccountsListContent(state = AccountsListUiState(items = AccountsListPreviews.items, totalAccounts = 2)) } }

        onNodeWithText("Main account").assertExists()
    }

    @Test
    fun `filter button sends FiltersSheetShow`() = runComposeUiTest {
        val actions = mutableListOf<AccountsListUiAction>()
        setContent { AppTheme { AccountsListContent(state = AccountsListUiState(), onAction = { actions += it }) } }

        onNodeWithContentDescription("Show filters").performClick()

        assertEquals(listOf(AccountsListUiAction.FiltersSheetShow), actions)
    }

    @Test
    fun `the filters sheet is reachable because it lives in the Content`() = runComposeUiTest {
        setContent { AppTheme { AccountsListContent(state = AccountsListUiState(filtersSheetVisible = true)) } }

        onNodeWithTag("filtersSheet").assertIsDisplayed()
    }
}
```

A form driven from outside, so the test shows the form reflects state rather than keeping its own:

```kotlin
val stateFlow = MutableStateFlow(AuthContentState(username = "", password = ""))
runComposeUiTest {
    setContent {
        val state by stateFlow.collectAsState()
        AuthContent(state = state, onAction = { action ->
            when (action) {
                is AuthAction.UsernameChanged -> stateFlow.update { it.copy(username = action.value) }
                else -> Unit
            }
        })
    }
    onNodeWithTag("username").performTextInput("TESTER")
    assertEquals("TESTER", stateFlow.value.username)
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
            chart = { expanded -> Chart(ChartUi(days = fixedDays, currency = Currency.Usd, todayIndexProvider = { 30 }), expanded = expanded) },
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
            ),
        )
    }
}
