---
name: compose-client-feature
description: "Implement or change a screen or feature in a Compose Multiplatform client (Android, iOS, desktop, browser from one source set): the feature package with data / domain / ui layers, repositories as a StateFlow source of truth with optimistic updates, preferences other screens depend on as observed flows, use cases returning Result, view models with an immutable UiState, the stateful Component / stateless Content split, navigation with a graph built once, session and token handling, the Ktor client, offline cache, and Koin wiring with its traps. Use this whenever the user says add a screen, add a settings page, implement a client feature, create a view model, show data from the API, handle logout or session expiry, add navigation, or touches composeApp code — including desktop and web dashboards, not only mobile apps."
---

# A feature in a Compose Multiplatform client

MVVM with use cases and a repository that is the single source of truth, on the stack
**Compose Multiplatform + Koin + Ktor client + androidx.navigation**. The reference is
`:composeApp` in [mani](https://github.com/youndie/mani-kotlin-fullstack): one body of code for
four platforms, with exactly four platform-specific file pairs. The rules that follow were each
paid for with a defect that is named next to the rule.

## Step 0. Check the project first

1. Find the feature **closest to your task** and copy its layout. The reference does not agree
   with itself: `transaction` and `auth` have the full `data / domain / ui / module.kt` tree;
   `health`, `demo` and `currency` are **domain-only features** (use cases and a repository, no
   screen) consumed by other screens; `main` is a screen feature that composes them. All three
   shapes are legitimate; pick by what you are building, not by which is newest.
   **The project's conventions win** over this file.
2. Identify: DI (Koin here), the HTTP client, navigation (androidx.navigation here; Navigation 3,
   Voyager and Decompose differ in the details, not in the layering), whether there is a local
   cache and whether the project keeps a screen list (`ManiScreen`) with titles.
3. Read `CLAUDE.md` / `README.md`. When `CLAUDE.md` and existing code disagree (the language of
   comments, say), new code follows `CLAUDE.md`; existing code is not retrofitted in passing.
4. **Look for a documentation gate.** If `docs/screens/` exists with a coverage map checked in
   CI, the new screen's document and its line in the map are part of the same change, and any
   sentence claiming the feature does not exist ("the product has no currency picker") must go.

This applies to dashboards on desktop and wasm as much as to phones. The sign the skill was
skipped: composables call the HTTP client directly, state lives in `remember` next to layout, and
navigation is `var route by mutableStateOf(...)` with a `when`.

Boundaries: the wire shape is `kmp-shared-contract`; tests in detail are `kmp-testing`.

## The feature package

```
feature/<name>/
  data/
    <Name>RepositoryImpl.kt        the source of truth: StateFlow + optimistic writes
    <Name>NetworkDataSource.kt     HTTP over the shared @Resource classes (when a class is worth it, see below)
    <Name>Cache.kt                 last known answer + when it was taken — only if the feature shows data offline
  domain/
    <Name>Repository.kt            interface; exposes dataStateFlow and anything the screen must know
    <Verb><Name>UseCase.kt         one operation per class
  ui/
    <Name>ViewModel.kt
    model/<Name>UiState.kt         the whole state of the screen, immutable
    component/<Name>Component.kt   stateful wrapper + stateless Content
  module.kt                        this feature's Koin module
```

Screens live with their feature, not in a global `ui` package. **A screen that belongs to no
single domain** (a settings page that today holds one preference and tomorrow three) is its own
screen feature with `ui/` only; the use cases it calls stay in the domain features they belong to,
registered in *those* modules, because a use case shared by two screens registered in one
screen's module takes the other screen down when it is missing.

What stays at the root: `navigation/` (the graph sees every feature), `components/` and `theme/`
(a UI kit with no domain state), `data/` (the HTTP client, session refresh, `ServerException`),
`useCase/` and `uiState/` (the base types below).

## Layers, bottom up

**Data source** — a class per transport, over the contract's `@Resource` classes:
`httpClient.post(TransactionResource()) { setBody(params) }.body()`. A generic
`DataSource<T : WithId>` (create / load / update / delete) fits CRUD-shaped features; the Koin
binding of a generic type must be **named**, see below. A data-source class is **not** worth it
for a single read-only `GET` of a list without ids: the reference's `GetHealthUseCase` takes the
`HttpClient` directly, and that is the precedent to copy for such reads.

**Repository** — the single source of truth the screens observe. For a list, a
`StateFlow<List<T>>` with **optimistic writes and rollback**: put the change into the flow, call
the source, replace the optimistic copy with the server's answer, or roll back and rethrow.
Mutate only through `MutableStateFlow.update { }`: `data.value += x` is a read, an add and a
write in three steps, and concurrent calls lose each other's changes; deleting a selection runs
several coroutines at once, and it was deletions that vanished. Whatever the screen must know
about the data goes on the **interface** (`val showingCacheFrom: StateFlow<Instant?>`), never
only on the implementation.

**A preference other screens format by is a `StateFlow` too**, not a `var`. View models are
scoped to their back-stack entry, so the main screen's view model is alive underneath a settings
screen pushed on top of it; a view model that read the currency once in `init` shows the old
currency when the user comes back. The reference's `CurrentCurrencyRepository { var currency }`
and the `val currency = getCurrentCurrencyUseCase.get()` in its view models are exactly this
defect waiting to happen; a preference that anything renders by is observed and combined into
the state like any other source.

**Use case** — one operation, one class, returns `Result`:

```kotlin
abstract class UseCase<P, T> {
    abstract suspend operator fun invoke(params: P): Result<T>
    suspend fun get(params: P) = invoke(params).getOrThrow()
}
abstract class NonParameterizedUseCase<T> : UseCase<EmptyParams, T>() {
    suspend operator fun invoke() = invoke(EmptyParams)
}
```

Inside, `suspendRunCatching { ... }` and a mapping of the transport failure to a domain
`ServerException(message, cause, status)`. `suspendRunCatching` rethrows `CancellationException`;
plain `runCatching` in suspend code turns a cancelled coroutine into a "network error" on screen.
Never wrap a `Result` in a `Result`. A use case that only exposes a flow (`Observe<X>UseCase`) is
a plain class with a `val observe = repository.dataStateFlow`.

**View model** — `androidx.lifecycle.ViewModel` from `commonMain`, depends on **use cases only**,
never on a repository:

```kotlin
class TransactionsViewModel(
    private val getTransactionsUseCase: GetTransactionsUseCase,
    private val observeCurrentCurrencyUseCase: ObserveCurrentCurrencyUseCase,
    private val deleteTransactionsUseCase: DeleteTransactionsUseCase,
) : ViewModel() {
    private val state = MutableStateFlow(TransactionListUiState(loading = true))
    val observe = state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            getTransactionsUseCase().fold(
                onSuccess = { transactions ->
                    combine(transactions, observeCurrentCurrencyUseCase.observe) { items, currency -> items.toUi(currency) }
                        .collectLatest { ui -> state.update { it.copy(loading = false, data = ui) } }
                },
                onFailure = { throwable -> state.value = TransactionListUiState(unreachable = ServerUnreachableUiState(describe(throwable))) },
            )
        }
    }

    fun onDeleteClicked() { ... }     // one handler per user intent, or one onAction(sealed) entry
}
```

Heavy mapping goes through `flowOn(dispatcher)` or `withContext(dispatcher)`; the dispatcher is a
constructor parameter with a default so tests can pass their own — and see the Koin note on
defaults below.

**UI state** — a `data class` with defaults, **immutable collections** (`ImmutableList`,
`ImmutableMap`) so Compose treats it as stable, derived properties for what the screen computes
(`val valid get() = ...`, `val amountError: String? get() = ...`). A `success` flag the component
turns into navigation belongs to screens that *finish* (a form); a screen that applies on tap has
no `success`. Two offline states are two fields, not two values of one: `showingCacheFrom:
String?` (the last known list is shown, with the time it was taken) and `unreachable:
ServerUnreachableUiState?` (nothing to show; a cause and a retry). The cause is machine-readable
— `HTTP 503 · host · 11:42:07` — because "Network Error" does not distinguish "my wifi" from
"their server". A screen that always has *something* to show (a stored preference) keeps the
stored value visible and shows the cause next to the part that failed.

## Component and Content

Every screen that resolves a view model splits in two:

```kotlin
@Composable
fun TransactionsListComponent(appBarState: MainAppBarState, onTransactionClicked: (String) -> Unit) {
    rememberKoinModules { listOf(module { viewModelOf(::TransactionsViewModel) }) }
    val viewModel = koinViewModel<TransactionsViewModel>()
    val state by viewModel.observe.collectAsStateWithLifecycle()

    TransactionsListContent(state, onTransactionSelected = viewModel::onTransactionSelected, onRetry = viewModel::onRetryClicked) {
        onTransactionClicked(it.id)
    }
}

@Composable
fun TransactionsListContent(state: TransactionListUiState, ..., today: LocalDate = today()) { /* the tree */ }
```

The **Component** owns the view model, collects state, runs `LaunchedEffect`s that touch the
view model (`success` → navigate, `errorMessage` → snackbar), wires lifecycle observers, and
nothing else. The **Content** knows neither the view model nor DI: state in, callbacks out. That
is what screenshot tests and Compose UI tests render, without a graph or a network. Anything
drawn from the clock (`today`) comes in as a parameter with a default, or the golden lives one
day. Presentation-only state (a dropdown being open, scroll position) may stay in `remember`
inside Content; anything with domain meaning (selection, a dialog over a record) is in the
UiState.

The reference is not fully split: its main screen keeps a profile popup with menu items inside
the Component. The consequence is concrete: a menu item there cannot be reached by a Content
test. When you touch such a spot, lift the piece into a stateless composable
(`ProfileMenu(show, onDismiss, onSettings, onLogout)`) rather than adding to the Component.

Events that are not state get their own flow: `loggedOut` is a separate `StateFlow<Boolean>` in
the reference because the screen state is rebuilt from a subscription and a flag inside it was
overwritten on the next emission. The test showed the overwrite.

## Navigation

- **The graph is built once.** `NavHost` rebuilds the graph when its builder lambda changes,
  and the lambda captures everything around it, so it changes on every recomposition of the
  parent; a new graph resets navigation to its start destination. Wrap `NavHost` so that
  `createGraph` runs inside `remember` (`StableNavHost` in the reference), and keep the test that
  counts builds.
- **The start destination is read once, in `remember`, and is not subscribed to the token.**
  Subscribing rebuilt the graph on every token change (sign-in, sandbox, logout) and threw the
  screen elsewhere. Sign-in and sign-out transitions are **explicit** callbacks
  (`onSuccess = { navigateAndClean(Main) }`).
- **Session expiry is an event, not state**: `TokenRepository.expired: Flow<Unit>` with
  `replay = 0`; the nav host collects it and goes to the welcome screen. With replay, every new
  subscriber would be thrown to the welcome screen on the next recomposition.
- `navigateAndClean(route)` pops to the start destination inclusive and re-points the graph's
  start destination, so a later logout does not look for a screen that is no longer in the stack.
- Root screens (welcome, main) show no back arrow even when the stack has an entry below them: a
  set of root screens plus `hasPrevious` decides, not the stack alone.
- Routes with arguments are `@Serializable` classes (`TransactionRoute(val id: String)`): no
  reflection outside the JVM.
- In the browser, bind the controller to history (`window.bindToNavigation`) so back / forward
  and the address bar are real.

**Adding a plain screen** in the reference shape touches: the screen enum (`ManiScreen`), its
`title()` branch (the app bar reads it), the root-screens set (is there a back arrow?), the
`composable(...)` entry in the nav host, the caller's navigation callback, and the back-arrow
test. A screen that applies on tap is left by back only; no "done" transition.

## Network client and session (reference material)

One `HttpClient` in a Koin module with `Resources`, `ContentNegotiation` (`ignoreUnknownKeys`),
`defaultRequest { contentType(Json) }`, and a bearer `Auth` whose `refreshTokens` delegates to a
**top-level function** so a mock engine can exercise it. Refresh answers are sorted by kind: `401`
ends the session (clear tokens, emit `expired`); any other failure leaves the session alone;
success stores the pair. `TokenRepository` is common; only `TokenStorage` is platform-specific,
bound through `expect val authModulePlatform: Module`. All of it, with the defects it encodes, in
[examples/network-and-session.md](examples/network-and-session.md); an ordinary screen does not
touch this layer.

## Offline (only for features that show data offline)

The repository asks the network **always** and falls back to the cache **only when it fails**;
otherwise the app shows yesterday's data with a live connection. On success the cache is
rewritten and `showingCacheFrom` is cleared; on failure the cache is loaded and the timestamp
exposed; `CancellationException` is rethrown first. A missing or corrupt cache is a reason to go
to the network, not to crash. A cache is dead weight for a small list behind a fixed route or for
anything the user can live without until the network is back; the reference caches one thing.

## Koin wiring

```kotlin
val transactionsModule = module {
    singleOf(::AddTransactionUseCase)
    // Generics are erased: DataSource<Category> and DataSource<Transaction> are ONE key to Koin,
    // and the last registration wins for everybody. Bound by name, and a test asserts no unnamed one is back.
    single<DataSource<Transaction>>(named(TRANSACTIONS_SOURCE)) { TransactionsNetworkDataSource(get()) }
    // A separate definition, not constructed inside the cache: the graph check walks constructors
    // and would otherwise not see the dependency.
    single<Settings> { Settings() }
    single<TransactionsCache> { TransactionsCache(get()) }
    single<TransactionRepository> { TransactionRepositoryImpl(get(named(TRANSACTIONS_SOURCE)), get()) }
}
```

- `appModules` is a list of feature modules; `App()` wraps everything in one
  `KoinApplication { modules(appModules + platformModules) }`, so launchers pass only what the
  platform contributes (Android: `single<Context>`).
- Screen view models are registered inside their component with `rememberKoinModules`. They
  never reach the application graph, so the graph test does not see their dependencies; add
  those view models to the test by hand. That is how a missing use case binding once shipped:
  green tests, black screen. Registering a view model **both** in a feature module and in a
  component is the smell to avoid, not a pattern to copy.
- `singleOf` / `factoryOf` / `viewModelOf` resolve every constructor parameter, **defaults
  included**; a constructor with a default parameter gets an explicit lambda. The reference
  works around a default `dispatcher` with `single { Dispatchers.Default }.bind<CoroutineDispatcher>()`
  in one feature's module; a new view model then compiles only because of a binding in another
  feature. Prefer the explicit lambda.
- A use case shared by two screens is registered in the domain feature's module, not in one
  screen's module.

## Compose pitfalls already paid for

- `Modifier.padding(16.dp).verticalScroll(state)` clips the content at the padding edge; order
  it `verticalScroll(state).padding(...)`, or take `contentPadding` from the shell.
- One scroll per screen: a header, a hero and a list scroll together.
- A `LazyColumn` inside `verticalScroll` fails on infinite height; either the lazy container is
  the screen's scroll (with its own `contentPadding` for the FAB and system bars) or the list is
  short enough for a `Column`.
- `remember { @Composable { ... } }` hides composition boundaries from the compiler; a plain
  `@Composable private fun` is easier to reason about when something recomposes wrongly.
- Wide layouts branch inside the Content on `BoxWithConstraints`, not in the Component: the
  screenshot test then covers both.

## Checklist

- [ ] data access over the shared `@Resource` classes; no string path
- [ ] the source of truth is a flow: lists with optimistic writes via `update { }`, preferences as `StateFlow`; nothing reads a value once that another screen can change
- [ ] view model depends on use cases only; `Result` folded, cancellation not swallowed
- [ ] UiState immutable, with defaults; offline / failure states distinct; cause machine-readable
- [ ] Component / Content split, including menus and dialogs; `today` and anything clock-derived as a parameter
- [ ] navigation: enum, title, root set, nav-host entry, caller callback; nothing subscribes the graph to the token
- [ ] Koin: generics named, screen view models added to the graph test, no default params under `*Of`, shared use cases in the domain module
- [ ] docs: the screen document and the coverage map, if the repository has them
- [ ] tests: view model (mutation-checked against the one-shot read), repository against `MockEngine`, Content with `runComposeUiTest`, screenshot on Linux (see `kmp-testing`)

Examples: [examples/feature-skeleton.md](examples/feature-skeleton.md) (repository, use case, view
model, state, component), [examples/navigation.md](examples/navigation.md),
[examples/network-and-session.md](examples/network-and-session.md).
