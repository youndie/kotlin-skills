# Client tests: view model, networking, Compose UI, screenshots, the graph

## A fake repository of the observe/refresh shape, and the view model over real use cases

```kotlin
class FakeAccountRepository : AccountRepository, CurrencyRepository {
    val accounts = MutableStateFlow<List<Account>>(emptyList())
    val currencies = MutableStateFlow<List<Currency>>(emptyList())
    var refreshResult: Result<Unit> = Result.success(Unit)
    var refreshCalls = 0

    override fun observeAccounts(clientId: Long): Flow<List<Account>> = accounts
    override suspend fun refreshAccounts(clientId: Long) { refreshCalls++; refreshResult.getOrThrow() }
    override suspend fun getAccount(accountId: Long): Account? = accounts.value.firstOrNull { it.id.value == accountId }
    override fun observeCurrencies(): Flow<List<Currency>> = currencies
}
```

```kotlin
@OptIn(ExperimentalCoroutinesApi::class)
class AccountsListViewModelTest {
    private val testDispatcher = StandardTestDispatcher()
    private val repository = FakeAccountRepository()

    @BeforeTest fun setUp() = Dispatchers.setMain(testDispatcher)   // before the view model exists
    @AfterTest fun tearDown() = Dispatchers.resetMain()

    /** Real use cases over the fake: the test covers them too, and nothing needs mocking. */
    private fun createViewModel() = AccountsListViewModel(
        observeAccountsUseCase = ObserveAccountsUseCase(repository),
        refreshAccountsUseCase = RefreshAccountsUseCase(repository),
        observeCurrenciesUseCase = ObserveCurrenciesUseCase(repository),
    )

    /** The derivation: what comes out of the combine for a given input. */
    @Test
    fun `uiState should filter out unapproved accounts`() = runTest(testDispatcher) {
        repository.accounts.value = listOf(account(1, state = ACTIVE), account(2, state = OPENING), account(3, state = CLOSED))
        val viewModel = createViewModel()

        viewModel.uiState.test {
            var state = awaitItem()
            while (state.totalAccounts == 0) state = awaitItem()

            assertEquals(1, state.items.size)
            assertEquals(3, state.totalAccounts)
            cancelAndIgnoreRemainingEvents()
        }
    }

    /** The flags: a failed refresh sets the error and erases nothing. */
    @Test
    fun `refresh failure should set the error and keep the list`() = runTest(testDispatcher) {
        repository.accounts.value = listOf(account(1, state = ACTIVE))
        repository.refreshResult = Result.failure(NoNetworkError())
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
     * The trap: a stateIn(WhileSubscribed) state stays at initialValue until collected. Without
     * the collector below `.value` is the initial loading state forever, and an assertion against
     * it would pass for the wrong reason. The loop is bounded: a loop that never becomes true
     * never suspends, and runTest's timeout cannot end it.
     */
    @Test
    fun `reading value needs a collector`() = runTest(testDispatcher) {
        repository.accounts.value = listOf(account(1, state = ACTIVE))
        val viewModel = createViewModel()
        backgroundScope.launch { viewModel.uiState.collect {} }

        var spins = 0
        while (viewModel.uiState.value.totalAccounts == 0) {
            check(spins++ < 100) { "the derived state never received the accounts" }
            runCurrent()
        }

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
 * The graph builds and every screen's view model resolves. View models are registered in the
 * feature's UI module, so verify() sees them together with everything they inject.
 */
class ClientKoinModuleTest {
    @OptIn(KoinExperimentalAPI::class)
    @Test
    fun checkKoinModule() {
        module { includes(appModules) }.verify(
            extraTypes = listOf(HttpClientEngine::class, HttpClientConfig::class),   // supplied by the HttpClient builder, not the graph
        )
    }

    /** verify() is static; this one creates. A defaulted or nullable constructor parameter only shows up here. */
    @Test
    fun viewModelsResolve() {
        val koin = koinApplication { modules(appModules) }.koin
        koin.get<AccountsListViewModel>()
        koin.get<AccountDetailsViewModel> { parametersOf(AccountDetailsParams(accountId = 1L)) }
    }
}
```

If the project registers view models inside composables with `rememberKoinModules`, they never
reach `appModules`, and the test above is blind to them: add `viewModelOf(::X)` for each such
view model to the module under test by hand, and keep a comment saying why the list exists. A
missing use-case binding once shipped that way: green tests, black screen on opening the main
screen.
