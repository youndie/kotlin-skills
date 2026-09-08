---
name: compose-client-feature
description: "Add or change a screen or feature in a Compose Multiplatform client (Android, iOS, desktop, web): domain/data/ui split, observe-and-refresh repositories, use cases, a view model whose UiState is derived with combine and stateIn plus UiFlags, UiAction in and UiEvent out, Screen/Content split, navigation, session, Koin. Use for 'add a screen', 'add a settings page', 'create a view model', 'show data from the API', 'handle logout', 'add navigation' in Compose code, dashboards included."
---

# A feature in a Compose Multiplatform client

Unidirectional data flow: **domain flows and use cases → a view model that derives one immutable
`UiState` → a stateless Content that renders it and sends `UiAction`s back**. Navigation and
one-shot effects leave the view model as `UiEvent`s. Public reference for the platform mechanics
(navigation, session, offline): [mani](https://github.com/youndie/mani-kotlin-fullstack); the
view-model shape below is the one that scales past a dozen screens, and the reference's older
screens are the counter-example where noted.

## Step 0. Check the project first

1. Find the feature **closest to your task** and copy its layout. Projects rarely agree with
   themselves; where an older screen sets `state.value` by hand and a newer one derives it, copy
   the newer one and do not retrofit the older in passing. **The project's conventions win.**
2. Identify: how features are cut (packages in one module, or `feature-x-domain / -data / -ui`
   Gradle modules), DI (Koin here), navigation (androidx.navigation here; Navigation 3, Voyager,
   Decompose differ in details, not in the layering), whether there is a local database, whether
   there is a base `UseCase` module, an `AppError` hierarchy, a `UiText` type.
3. Read `CLAUDE.md` / `README.md`. When they and existing code disagree, new code follows
   `CLAUDE.md`.
4. If the repository keeps screen documentation with a coverage map checked in CI, the new
   screen's document is part of the same change, and any sentence claiming the feature does not
   exist must go.

The sign the skill was skipped: composables call the HTTP client, state lives in `remember` next
to layout, navigation is `var route by mutableStateOf(...)` with a `when`, and the view model
mutates one big `MutableStateFlow` from twelve places.

Boundaries: the wire shape is `kmp-shared-contract`; tests in detail are `kmp-testing`; module
cutting and build files are `kmp-project-structure`.

## The three layers, and who may see whom

```
feature/<name>/domain     models, repository interfaces, use cases          depends on: other domains, core
feature/<name>/data       repository implementations, DAO/entities, DTO→entity→domain mappers   depends on: domain
feature/<name>/ui         UiState, UiAction, UiEvent, view model, mapper, Screen + Content      depends on: domain
```

`ui` never sees `data`; `data` never sees `ui`; `domain` sees neither. In a small app these are
three packages in one module; past a handful of features they become three Gradle modules per
feature (`feature-x-domain`, `feature-x-data`, `feature-x-ui`) with convention plugins, and the
application module is the only one that sees all of them and wires DI. The rule is the same in
both sizes; the module cut merely makes the compiler enforce it.

A screen that belongs to no single domain (a settings page) is a `ui` feature over the domain
features it uses; the use cases stay in their own domains, registered in *those* modules.

## Domain

**Models are typed, not stringly.** An id is a value class (`@JvmInline value class AccountId(val
value: Long)`); money is a type, not a `Double`; a closed set from the server is a `sealed
interface Kind` with an `Other(raw: String)` fallback so an unknown value survives the trip
instead of crashing the parser. The wire DTO is not the domain model: a small app may use the
shared contract class directly, a large one maps at the data layer so that an API change does
not ripple through every screen.

**Repositories observe and refresh.** The interface names the two verbs and nothing about
transport:

```kotlin
interface AccountRepository {
    fun observeAccounts(clientId: Long): Flow<List<Account>>
    suspend fun refreshAccounts(clientId: Long)
    suspend fun getAccount(accountId: Long): Account?
}
```

`observe` is a `Flow` from the local source of truth (a database table, or an in-memory
`MutableStateFlow` when the app has no database); `refresh` goes to the network, maps, and
writes into that source, and every subscriber sees the change. Transient data that nobody
displays later (a fee calculation, an account check) is returned directly from the network
call; the database is not a ritual.

**Use cases come in two shapes**, and the difference is the return type:

```kotlin
fun interface UseCase<in P, out T> { suspend operator fun invoke(params: P): Result<T> }
fun interface ObservableUseCase<in P, out R> { operator fun invoke(params: P): Flow<R> }

abstract class BaseUseCase<in P, out R> : UseCase<P, R> {
    override suspend fun invoke(params: P): Result<R> = suspendRunCatching { execute(params) }
    protected abstract suspend fun execute(params: P): R
}
```

An **action** (refresh, create, download) is a `UseCase` returning `Result`; the view model folds
it. An **observation** is an `ObservableUseCase` returning a plain `Flow`; a failure in a flow is
an exception in the stream, not a `Result` per element, and a `Flow<Result<T>>` is the smell to
avoid. A use case may call another use case (`getCurrentClientUseCase().getOrThrow()` before
`repository.observeAccounts(client.id)`), which is how "the current client" stays out of every
repository signature. Use cases take no dispatcher and impose no threading; the repository knows
whether it does I/O.

`suspendRunCatching` rethrows `CancellationException`; plain `runCatching` in suspend code turns a
cancelled coroutine into an error on screen.

Use cases are final classes; **the test seam is the repository interface**, and a view-model
test builds the real use cases over fake repositories (`kmp-testing`). What not to build, and
why, is in [examples/feature-skeleton.md](examples/feature-skeleton.md), "What was replaced".

## Data

The repository implementation maps and stores; it does not decide what the screen shows.

```kotlin
class AccountRepositoryImpl(private val api: AccountApi, private val dao: AccountDao) : AccountRepository {
    override fun observeAccounts(clientId: Long): Flow<List<Account>> =
        dao.observeAccounts(clientId).map { entities -> entities.map { it.toDomain() } }

    override suspend fun refreshAccounts(clientId: Long): Unit = runNetworkCatching {   // `: Unit`, or the DAO's return type leaks into the override
        val response = api.getAccounts(GetAccountsRequest(clientId))
        dao.upsertAll(response.accounts.map { it.toEntity(clientId) })
    }
}
```

**Transport failures become domain errors at this boundary**, once: `runNetworkCatching` maps
`IOException` → `NoNetworkError`, `ServerResponseException` → `ServerError(code)`,
`ClientRequestException` → `ClientError(code)`, everything else → `UnknownAppError`, and rethrows
`CancellationException` and errors already mapped. Above this line nothing knows Ktor. A business
envelope (`statusId`, `errorCode`, `message` around the payload) is unwrapped by one handler
that also owns the side effects those codes imply (session expired → terminate the session).

Mappers are extension functions next to the repository: `Dto.toEntity()`, `Entity.toDomain()`,
`Dto.toDomain()` when there is no database. Each is a pure function and gets a test.

Optimistic writes (put the change into the source of truth before the call, roll back on
failure) are a technique for lists the user edits in place; they live inside one repository.

## UI: the view model derives, it does not mutate

```kotlin
class AccountsListViewModel(
    private val observeAccountsUseCase: ObserveAccountsUseCase,
    private val refreshAccountsUseCase: RefreshAccountsUseCase,
    private val observeCurrenciesUseCase: ObserveCurrenciesUseCase,
) : ViewModel() {
    private val mapper = AccountsUiMapper

    private val _events = Channel<AccountsListUiEvent>(Channel.UNLIMITED)
    val events: Flow<AccountsListUiEvent> = _events.receiveAsFlow()

    private val refreshTrigger = Channel<Unit>(Channel.CONFLATED)
    private val filter = MutableStateFlow(AccountsFilter())
    private val uiFlags = MutableStateFlow(UiFlags())

    data class UiFlags(
        val loading: Boolean = false,
        val errorMessage: UiText? = null,
        val filtersSheetVisible: Boolean = false,
        val amountsHidden: Boolean = false,
    )

    /** A failing source is reported into the flags and completes; combine keeps its last value. A catch after stateIn would be too late: the exception has already cancelled viewModelScope. */
    private fun <T> Flow<T>.reported(): Flow<T> = catch { e -> uiFlags.update { it.copy(errorMessage = mapper.toMessage(e)) } }

    val uiState: StateFlow<AccountsListUiState> =
        combine(observeAccountsUseCase(Unit).reported(), observeCurrenciesUseCase(Unit).reported(), filter, uiFlags) { accounts, currencies, filter, flags ->
            val visible = accounts.filter(filter::matches)
            AccountsListUiState(
                items = visible.map(mapper::toListItem).toImmutableList(),
                totalAccounts = accounts.size,
                availableCurrencies = currencies.toImmutableList(),
                filter = filter,
                empty = !filter.isEmpty && visible.isEmpty(),
                loading = flags.loading,
                errorMessage = flags.errorMessage,
                filtersSheetVisible = flags.filtersSheetVisible,
                amountsHidden = flags.amountsHidden,
            )
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), AccountsListUiState(loading = true))

    init {
        // The first load happens because `filter` is a StateFlow and emits its current value on
        // collection; do not also send to refreshTrigger here, or the screen loads twice.
        viewModelScope.launch {
            merge(refreshTrigger.receiveAsFlow(), filter).collectLatest { load() }
        }
    }

    fun onAction(action: AccountsListUiAction) {
        when (action) {
            AccountsListUiAction.Refresh -> refreshTrigger.trySend(Unit)
            is AccountsListUiAction.FilterApply -> filter.value = action.filter
            AccountsListUiAction.FiltersSheetShow -> uiFlags.update { it.copy(filtersSheetVisible = true) }
            AccountsListUiAction.FiltersSheetDismiss -> uiFlags.update { it.copy(filtersSheetVisible = false) }
            AccountsListUiAction.AmountsToggle -> uiFlags.update { it.copy(amountsHidden = !it.amountsHidden) }
            AccountsListUiAction.ErrorDismissed -> uiFlags.update { it.copy(errorMessage = null) }
            is AccountsListUiAction.AccountClick -> _events.trySend(AccountsListUiEvent.OpenAccount(action.id))
        }
    }

    private suspend fun load() {
        uiFlags.update { it.copy(loading = true, errorMessage = null) }
        refreshAccountsUseCase().onFailure { e -> uiFlags.update { it.copy(errorMessage = mapper.toMessage(e)) } }
        uiFlags.update { it.copy(loading = false) }
    }
}
```

The pieces, and why each is where it is:

- **`UiState` is derived, never assigned.** It is a `combine` of domain flows (what exists),
  input flows (what the user chose: filter, selected id, timeframe) and `uiFlags` (what the
  screen is doing), turned into a `StateFlow` with `stateIn`. There is no `state.value = ...`
  anywhere; a change to any source re-derives the whole state, so nothing is stale and nothing
  is overwritten. A preference another screen edits (currency, hidden amounts) is one more flow in
  the `combine`, which is why the main screen shows the new value the moment the user comes back
  from settings.
- **`UiFlags` holds the screen's own booleans**: loading, error, which sheet or dialog is open.
  A small data class updated atomically with `uiFlags.update { it.copy(...) }`, separate from the
  data so that showing a sheet does not touch the list and loading does not erase what was
  loaded. Nested in the view model and flattened into `UiState` for a simple screen; a top-level
  `<Screen>UiFlags` kept as `state.flags` when a screen has many sheets. Fetched data that is
  not a domain flow (a summary computed per selection) lives in its own
  `MutableStateFlow<FetchedData>` and joins the `combine` too. The typed `combine` overloads
  stop at five flows; past that, nest a `combine` or group inputs into a data class.
- **A failing source flow is caught per source, before `combine`** (`.reported()` above): it
  writes the error into the flags and completes, and `combine` keeps its last value. There is
  no recovery after `stateIn`: an uncaught exception there cancels `viewModelScope`.
- **`UiAction` is the only way in**: a sealed interface, one `onAction`. Handlers are named after
  what the person did (`AccountClick`, `FiltersSheetDismiss`), not after what the code does.
- **`UiEvent` is the only way out** for one-shot effects: navigation, a toast, a share sheet. A
  `Channel(UNLIMITED)` exposed as `receiveAsFlow()` rather than a `SharedFlow(replay = 0)`: an
  event sent while no Screen is collecting (a navigation transition, a rotation) is buffered
  and delivered once, where a replay-less flow drops it. The Screen collects it in
  `LaunchedEffect(Unit)`; on Android, collect through `repeatOnLifecycle(STARTED)` if the
  callbacks navigate, so a stopped screen does not. Never a `success: Boolean` in the state that
  a `LaunchedEffect` watches (it fires again after every recomposition until cleared, and
  clearing it is one more action), never a `loggedOut` `StateFlow<Boolean>`, never a
  subscription of the navigation graph to a token.
- **Reloads are `collectLatest` over a trigger**: `merge(refreshTrigger, filter)` so a new
  filter cancels the in-flight load and starts the right one; no `loadJob?.cancel()` bookkeeping.
  When a load depends on several inputs (selected account × timeframe), `combine` them,
  `distinctUntilChanged`, then `collectLatest`.
- **`stateIn(WhileSubscribed(5_000))`** stops the upstream when nobody looks for five seconds
  and restarts it on return: a screen behind another screen stops working, and an Android
  configuration change (shorter than the grace) does not restart the upstream. The subscriber
  has to actually leave, which is why the Screen uses `collectAsStateWithLifecycle`, not
  `collectAsState`. Inputs that must survive process death (a filter, a selected id) come from
  `SavedStateHandle`. In a test `uiState.value` stays at `initialValue` until something
  collects; see `kmp-testing`.
- **A `UiMapper` object** turns domain into UI items: formatting, icons, `UiText` (a resource id
  or a literal, resolved in Compose). It is a pure function with a test; the view model does not
  format, the Content does not compute.
- **Errors reach the UI as `UiText`, mapped from `AppError`** by the mapper, not as
  `throwable.message` (which is English from a library, or null).

Immutable collections (`ImmutableList`) in `UiState`: with strong skipping (the default since
Kotlin 2.0.20) a `List` field no longer prevents skipping, but the state then compares by
instance; an `ImmutableList` gives value equality and documents that nothing mutates it. A
preference worth keeping consistently, not a correctness rule.

## Screen and Content

```kotlin
@Composable
fun AccountsListScreen(
    viewModel: AccountsListViewModel = koinViewModel(),
    onBack: () -> Unit,
    onOpenAccount: (Long) -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            when (event) {
                is AccountsListUiEvent.OpenAccount -> onOpenAccount(event.id)
            }
        }
    }

    AccountsListContent(state = state, onAction = viewModel::onAction, onBack = onBack)
}

@Composable
fun AccountsListContent(
    state: AccountsListUiState,
    onAction: (AccountsListUiAction) -> Unit = {},
    onBack: () -> Unit = {},
    today: LocalDate = today(),
) { /* the tree: sheets and dialogs included, each gated on a flag from the state */ }
```

The **Screen** resolves the view model, collects state, forwards events to callbacks, and
nothing else. The **Content** knows neither the view model nor DI: state in, `onAction` out.
Sheets, dialogs and menus are inside the Content, gated on flags, so a UI test reaches them; a
popup left in the Screen next to the view model is unreachable by any test. Anything drawn from
the clock (`today`) comes in as a parameter with a default, or the golden lives one day.
Presentation-only state (scroll position, a text field's transient value) may stay in `remember`
inside Content; anything with meaning to the view model is in the `UiState`.

**Previews for every state** (loading, empty, data, error, sheet open) live next to the Content,
built from a small fixture object; they double as the fixtures for Content tests and screenshots.

## Navigation

- **The graph is built once.** `NavHost` rebuilds its graph when the builder lambda changes, and
  the lambda changes on every recomposition of the parent; a new graph resets to the start
  destination. Wrap `NavHost` so `createGraph` runs inside `remember`, and keep the test that
  counts builds.
- **The start destination is read once**, in `remember`, and never subscribed to the token.
  Sign-in and sign-out are explicit transitions triggered by events from the screens.
- **Session expiry is an event** (`Flow<Unit>`, `replay = 0`) collected by the nav host; with
  replay every new subscriber would be thrown to the welcome screen.
- Routes with arguments are `@Serializable` classes (typed, `toRoute<T>()` on the entry or on
  the `SavedStateHandle`); plain screens may stay an enum of names in a project that already has
  one. Adding a screen touches the destination, the nav-host entry and the caller's callback,
  plus whatever the project derives from the route (an app-bar title, a "root screen" set).
- **Returning a result to a previous screen** goes through
  `previousBackStackEntry?.savedStateHandle` or a small result store keyed by a string (set on
  the way back, observed and consumed once), not through a shared view model or a global flag.
- In the browser, bind the controller to history (`window.bindToNavigation(navController)` from
  `navigation-compose`) so back / forward and the address bar are real.

Details and the defects behind each rule: [examples/navigation.md](examples/navigation.md).

## Session, network client, offline (reference material)

One `HttpClient` in a Koin module; a bearer `Auth` whose `refreshTokens` delegates to a top-level
function so a mock engine can exercise it; `401` on refresh ends the session, any other failure
leaves it alone. Token storage is the only platform-specific piece. An offline cache with a
timestamp is a technique for the one list the user must see without a network; it is not a
default for every feature. [examples/network-and-session.md](examples/network-and-session.md).

## Koin wiring

- One module per feature layer (`accountsDomainModule`, `accountsDataModule`, `accountsUiModule`)
  or one per feature in a small app; the application module lists them.
- `viewModelOf(::X)`, `singleOf(::X)`, `factoryOf(::X)` resolve **every** constructor parameter,
  defaults included; a constructor with a default parameter gets an explicit lambda, and a
  binding that exists only to satisfy someone else's default (`single { Dispatchers.Default }`)
  is a smell. A view model that needs a dispatcher for heavy mapping takes it as a constructor
  parameter **without a default** and the module binds one; tests pass the test dispatcher.
- Screen view models are registered in the feature's UI module (`viewModelOf(::X)` when every
  parameter is injectable, `viewModel { }` with route parameters), so the graph test sees them.
  Registering a view model inside a composable with `rememberKoinModules` hides it from the
  graph test; if the project already does that, add those view models to the test by hand.
- A use case shared by two screens is registered in its domain module, not in one screen's.
- A view model with route parameters takes them as a `Params` data class through
  `parametersOf`, not as loose primitives:

  ```kotlin
  class AccountDetailsParams(val accountId: Long)
  val accountsUiModule = module { viewModel { (params: AccountDetailsParams) -> AccountDetailsViewModel(params, get(), get()) } }

  // the nav-host entry hands the typed route to the Screen; the Screen builds Params
  composable<AccountRoute> { entry -> AccountDetailsScreen(AccountDetailsParams(entry.toRoute<AccountRoute>().id), onBack = { navController.popBackStack() }) }

  @Composable
  fun AccountDetailsScreen(params: AccountDetailsParams, onBack: () -> Unit,
      viewModel: AccountDetailsViewModel = koinViewModel(parameters = { parametersOf(params) })) { /* … */ }
  ```

  The alternative is `SavedStateHandle.toRoute<AccountRoute>()` inside the view model, with
  `viewModelOf(::X)` resolving the handle; a test then constructs the view model with
  `SavedStateHandle(mapOf(...))` or, simpler, with the `Params` directly.

## Compose pitfalls already paid for

- `Modifier.padding(16.dp).verticalScroll(state)` clips at the padding edge; order it
  `verticalScroll(state).padding(...)`, or take `contentPadding` from the shell.
- One scroll per screen; a `LazyColumn` inside `verticalScroll` fails on infinite height.
- Wide layouts branch inside the Content on `BoxWithConstraints`, so one screenshot set covers
  both.

## Checklist

- [ ] `domain` has the models, the repository interface (observe + refresh) and the use cases; `ui` depends on `domain` only
- [ ] transport errors mapped to `AppError` at the repository; nothing above knows the HTTP client
- [ ] `UiState` derived by `combine` + `stateIn`; no `state.value =`; preferences and selections are flows in the combine
- [ ] `UiFlags` for loading / error / visibility, updated with `update { }`
- [ ] one `onAction(UiAction)` in, one `events: Flow<UiEvent>` out; navigation only through events
- [ ] a `UiMapper` with a test; errors as `UiText`
- [ ] Screen / Content split with sheets and dialogs inside Content; previews for every state
- [ ] navigation entry, title, root set, callbacks; graph built once
- [ ] Koin: no default parameters under `*Of`, view models in the graph test, shared use cases in the domain module
- [ ] tests: mapper, view model over fake repositories (collecting the `stateIn` flow), Content with an `onAction` recorder, screenshots (see `kmp-testing`)

Dependencies the snippets assume: `koin-compose-viewmodel` (`koinViewModel`, `viewModelOf`),
`lifecycle-runtime-compose` (`collectAsStateWithLifecycle`), `navigation-compose`,
`kotlinx-collections-immutable`, `kotlinx-coroutines-core`.

Examples: [examples/feature-skeleton.md](examples/feature-skeleton.md) (domain, data, view
model, state, screen, mapper), [examples/navigation.md](examples/navigation.md),
[examples/network-and-session.md](examples/network-and-session.md).
