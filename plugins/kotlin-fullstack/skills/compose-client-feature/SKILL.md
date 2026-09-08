---
name: compose-client-feature
description: "Implement or change a screen or feature in a Compose Multiplatform client (Android, iOS, desktop, browser from one source set): the domain / data / ui split, repositories with observe-and-refresh over a local source of truth, use cases (Result for actions, Flow for observation), view models whose UiState is derived with combine and stateIn from domain flows plus UiFlags, UiAction in and UiEvent out, the Screen / Content split, UI mappers, error types, navigation with a graph built once, session handling, and Koin wiring with its traps. Use this whenever the user says add a screen, add a settings page, implement a client feature, create a view model, show data from the API, handle logout or session expiry, add navigation, or touches client / composeApp / feature-*-ui code — including desktop and web dashboards, not only mobile apps."
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
   themselves: newer screens follow the shape below, older ones set `state.value` by hand. Copy
   the newer one; do not retrofit the older one in passing. **The project's conventions win.**
2. Identify: how features are cut (packages in one module, or `feature-x-domain / -data / -ui`
   Gradle modules), DI (Koin here), navigation (androidx.navigation here; Navigation 3, Voyager,
   Decompose differ in details, not in the layering), whether there is a local database, whether
   there is a base `UseCase` module, an `AppError` hierarchy, a `UiText` type.
3. Read `CLAUDE.md` / `README.md`. When they and existing code disagree, new code follows
   `CLAUDE.md`.
4. Look for a documentation gate (`docs/screens/`, a coverage map checked in CI): the new
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

What **not** to build: a generic `UseCase<P,T>` base with `get()` that rethrows and `getOrNull()`
(the caller then bypasses `Result` and the error path is untested); a `FlowUseCase` that hardcodes
`Dispatchers.IO` and wraps every emission in `Result` (untestable threading, errors hidden at the
interface); a `DataSource<T : WithId>` plus `BaseFlowRepository<T>` CRUD generic (a marker
interface on the model, erased generics that force named DI bindings, and every feature bent to
the shape of a list).

## Data

The repository implementation maps and stores; it does not decide what the screen shows.

```kotlin
class AccountRepositoryImpl(private val api: AccountApi, private val dao: AccountDao) : AccountRepository {
    override fun observeAccounts(clientId: Long): Flow<List<Account>> =
        dao.observeAccounts(clientId).map { entities -> entities.map { it.toDomain() } }

    override suspend fun refreshAccounts(clientId: Long) = runNetworkCatching {
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
failure) remain a technique for lists the user edits in place; they belong inside one
repository, not in a base class every repository inherits.

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

    val uiState: StateFlow<AccountsListUiState> =
        combine(observeAccountsUseCase(Unit), observeCurrenciesUseCase(Unit), filter, uiFlags) { accounts, currencies, filter, flags ->
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
  loaded. Flatten it into `UiState` for a simple screen; keep it nested as `state.flags` when a
  screen has many sheets. Fetched data that is not a domain flow (a summary computed per
  selection) lives in its own `MutableStateFlow<FetchedData>` and joins the `combine` too.
- **`UiAction` is the only way in**: a sealed interface, one `onAction`. Handlers are named after
  what the person did (`AccountClick`, `FiltersSheetDismiss`), not after what the code does.
- **`UiEvent` is the only way out** for one-shot effects: navigation, a toast, a share sheet. A
  `Channel(UNLIMITED)` exposed as `receiveAsFlow()`; the Screen collects it in
  `LaunchedEffect(Unit)` and calls its navigation callbacks. Never a `success: Boolean` in the
  state that a `LaunchedEffect` watches (it fires again on every recomposition after the flag is
  set, and clearing it is one more action), never a `loggedOut` `StateFlow<Boolean>`, never a
  subscription of the navigation graph to a token.
- **Reloads are `collectLatest` over a trigger**: `merge(refreshTrigger, filter)` so a new
  filter cancels the in-flight load and starts the right one; no `loadJob?.cancel()` bookkeeping.
  When a load depends on several inputs (selected account × timeframe), `combine` them,
  `distinctUntilChanged`, then `collectLatest`.
- **`stateIn(WhileSubscribed(5_000))`** stops the upstream when nobody looks for five seconds
  and restarts it on return, which is what a screen behind another screen wants. It also means
  `uiState.value` in a test stays at `initialValue` until something collects; see `kmp-testing`.
- **A `UiMapper` object** turns domain into UI items: formatting, icons, `UiText` (a resource id
  or a literal, resolved in Compose). It is a pure function with a test; the view model does not
  format, the Content does not compute.
- **Errors reach the UI as `UiText`, mapped from `AppError`** by the mapper, not as
  `throwable.message` (which is English from a library, or null).

Immutable collections (`ImmutableList`) in `UiState` keep it stable for Compose; a `List` field
makes the compiler assume the whole state may change.

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
- Routes with arguments are `@Serializable` classes: no reflection outside the JVM. Adding a
  plain screen touches the screen enum, its title, the root-screens set (back arrow or not), the
  nav-host entry, the caller's callback, and the back-arrow test.
- **Returning a result to a previous screen** goes through a result store keyed by a string
  (set on the way back, observed and consumed once by the caller), not through a shared view
  model or a global flag.
- In the browser, bind the controller to history so back / forward and the address bar are real.

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
  is a smell.
- Screen view models are `viewModel { }` definitions in the feature's UI module, listed in the
  graph test. Registering a view model inside a composable with `rememberKoinModules` hides it
  from the graph test; if the project does that, add those view models to the test by hand.
- A use case shared by two screens is registered in its domain module, not in one screen's.
- A view model with route parameters takes them as a `Params` data class through
  `parametersOf`, not as loose primitives.

## Compose pitfalls already paid for

- `Modifier.padding(16.dp).verticalScroll(state)` clips at the padding edge; order it
  `verticalScroll(state).padding(...)`, or take `contentPadding` from the shell.
- One scroll per screen; a `LazyColumn` inside `verticalScroll` fails on infinite height.
- `remember { @Composable { ... } }` hides composition boundaries; use a named composable.
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
- [ ] tests: mapper, view model (collecting the `stateIn` flow), Content with an `onAction` recorder, screenshots (see `kmp-testing`)

Examples: [examples/feature-skeleton.md](examples/feature-skeleton.md) (domain, data, view
model, state, screen, mapper), [examples/navigation.md](examples/navigation.md),
[examples/network-and-session.md](examples/network-and-session.md).
