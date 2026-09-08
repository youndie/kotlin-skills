# A feature skeleton, bottom up

Trimmed from the reference project's transaction feature; comments translated.

## Base types (root packages `useCase/`, `uiState/`)

```kotlin
abstract class UseCase<P, T> {
    abstract suspend operator fun invoke(params: P): Result<T>
    suspend fun get(params: P) = invoke(params).getOrThrow()
    suspend fun getOrNull(params: P) = invoke(params).getOrNull()
}

abstract class NonParameterizedUseCase<T> : UseCase<EmptyParams, T>() {
    suspend operator fun invoke() = invoke(EmptyParams)
    suspend fun get() = invoke().getOrThrow()
}

object EmptyParams

interface LoadingState { val loading: Boolean; fun load(): LoadingState }
interface ErrorState { val errorMessage: String?; fun showError(message: String): ErrorState }
interface DataState<T> { val data: T; fun showData(data: T): DataState<T> }
interface CommonUiState<T> : DataState<T>, LoadingState, ErrorState

/**
 * @param status the response code, if there was a response. `null` means there was none at all —
 *  "the server said 503" and "the server was never reached" are different troubles.
 */
open class ServerException(
    override val message: String = "Server error",
    override val cause: Throwable? = null,
    val status: Int? = null,
) : Exception(message, cause)
```

## The source of truth

```kotlin
interface DataSource<T : WithId> {
    suspend fun create(params: T): T
    suspend fun load(): List<T>
    suspend fun update(params: T): T?
    suspend fun delete(id: String): Boolean
}

interface StateFlowRepository<T : WithId> {
    val dataStateFlow: StateFlow<List<T>>
    suspend fun load()
    fun getById(id: String): T
    suspend fun create(params: T): T
    suspend fun update(params: T): Boolean
    suspend fun delete(id: String): Boolean
    fun reset()
}

/**
 * The list changes only through MutableStateFlow.update: `data.value += x` is a read, an add and
 * a write in three steps, and concurrent calls overwrite each other. Deleting a selection runs
 * four coroutines at once, so it was deletions that were lost — rows came back until the next load.
 */
abstract class BaseFlowRepository<T : WithId>(private val dataSource: DataSource<T>) : StateFlowRepository<T> {
    private val data = MutableStateFlow(emptyList<T>())
    override val dataStateFlow: StateFlow<List<T>> = data.asStateFlow()

    override suspend fun create(params: T): T {
        data.update { it + params }                       // optimistic
        try {
            val created = dataSource.create(params)
            data.update { it - params + created }         // the server's copy replaces ours
            return created
        } catch (e: Exception) {
            data.update { it - params }                   // rollback
            throw e
        }
    }

    override suspend fun load() = withContext(Dispatchers.Default) { data.value = dataSource.load() }

    /** Substitute the list bypassing the source — for a subclass that shows the cache without a network. */
    protected fun replaceAll(items: List<T>) { data.value = items }

    override fun getById(id: String): T = dataStateFlow.value.first { it.id == id }

    override suspend fun delete(id: String): Boolean {
        val item = dataStateFlow.value.find { it.id == id } ?: return true
        data.update { it - item }
        return try {
            dataSource.delete(id)
        } catch (e: Exception) {
            data.update { it + item }
            throw e
        }
    }

    override fun reset() { data.value = emptyList() }
}
```

```kotlin
interface TransactionRepository : StateFlowRepository<Transaction> {
    /**
     * Not null: there was no network, and what is shown is the last known list, taken at this time.
     * On the interface, not the implementation: the screen must be told, and it must not know the
     * concrete repository class for that.
     */
    val showingCacheFrom: StateFlow<Instant?>
}

/**
 * The rule list with the last known state for when there is no network.
 * Order matters: the network is asked always; the cache steps in only if it refused. Otherwise
 * the app would show yesterday's data with a live connection.
 */
class TransactionRepositoryImpl(
    source: DataSource<Transaction>,
    private val cache: TransactionsCache,
) : BaseFlowRepository<Transaction>(source), TransactionRepository {

    private val staleSince = MutableStateFlow<Instant?>(null)
    override val showingCacheFrom: StateFlow<Instant?> = staleSince.asStateFlow()

    override suspend fun load() {
        try {
            super.load()
            cache.save(dataStateFlow.value)
            staleSince.value = null
        } catch (e: CancellationException) {
            // Cancellation is not a network failure. Without this branch, leaving the screen would
            // substitute the cache and light "showing last known data" with a live connection.
            throw e
        } catch (e: Exception) {
            val cached = cache.load() ?: throw e
            replaceAll(cached.transactions)
            staleSince.value = cached.takenAt
        }
    }
}
```

```kotlin
data class CachedTransactions(val transactions: List<Transaction>, val takenAt: Instant)

/**
 * The last known list. Without it the app shows an empty screen offline, although the data does
 * not change by itself: rules are not an event feed, yesterday's list is still right today.
 * Showing it with a timestamp is more honest than showing nothing.
 */
class TransactionsCache(private val settings: Settings, private val json: Json = Json { ignoreUnknownKeys = true }) {
    fun save(transactions: List<Transaction>) {
        settings.putString(KEY_DATA, json.encodeToString(transactions))
        settings.putLong(KEY_TAKEN_AT, Clock.System.now().toEpochMilliseconds())
    }

    /** `null` — no cache, or a broken one: a reason to go to the network, not to crash. */
    fun load(): CachedTransactions? {
        val raw = settings.getStringOrNull(KEY_DATA) ?: return null
        val takenAt = settings.getLongOrNull(KEY_TAKEN_AT) ?: return null
        return try {
            CachedTransactions(json.decodeFromString(raw), Instant.fromEpochMilliseconds(takenAt))
        } catch (e: Exception) {
            null
        }
    }

    fun clear() { settings.remove(KEY_DATA); settings.remove(KEY_TAKEN_AT) }

    private companion object {
        const val KEY_DATA = "transactions.cache"
        const val KEY_TAKEN_AT = "transactions.cache.takenAt"
    }
}
```

## Use cases

```kotlin
class GetTransactionsUseCase(private val transactionRepository: TransactionRepository) :
    NonParameterizedUseCase<Flow<List<Transaction>>>() {

    /** Forwarded from the repository: the screen must know the data is last-known, not fresh. */
    val showingCacheFrom: StateFlow<Instant?> get() = transactionRepository.showingCacheFrom

    override suspend fun invoke(params: EmptyParams): Result<Flow<List<Transaction>>> = suspendRunCatching {
        transactionRepository.load()
        Result.success(transactionRepository.dataStateFlow)
    }.getOrElse {
        Result.failure(ServerException("Network Error", it, (it as? ResponseException)?.response?.status?.value))
    }
}

class AddTransactionUseCase(private val transactionsRepository: TransactionRepository) : UseCase<Transaction, Boolean>() {
    override suspend operator fun invoke(params: Transaction): Result<Boolean> = suspendRunCatching {
        transactionsRepository.create(params)
        true
    }.fold(
        onSuccess = { Result.success(it) },
        onFailure = { Result.failure(ServerException(message = "Network Error", cause = it)) },
    )
}

/**
 * The last known list without touching the network. The form needs it not to display but to
 * compute how a new rule shifts the run-out day; the screen it came from already loaded the list.
 */
class ObserveTransactionsUseCase(private val transactionRepository: TransactionRepository) {
    val observe = transactionRepository.dataStateFlow
}
```

## UI state

```kotlin
data class TransactionListUiState(
    override val data: ImmutableMap<LocalDate, ImmutableList<TransactionUiItem>> = persistentMapOf(),
    override val loading: Boolean = false,
    override val errorMessage: String? = null,
    val selectedTransactions: ImmutableList<TransactionUiItem> = persistentListOf(),
    val showDeleteDialog: Boolean = false,
    /** Not null: there is no network, and the last known list is shown, taken at this time. */
    val showingCacheFrom: String? = null,
    /** Not null: the server did not answer and there is nothing to show — neither fresh nor saved. */
    val unreachable: ServerUnreachableUiState? = null,
) : CommonUiState<ImmutableMap<LocalDate, ImmutableList<TransactionUiItem>>> {
    override fun load() = copy(loading = true)
    override fun showError(message: String) = copy(errorMessage = message, loading = false)
    override fun showData(data: ImmutableMap<LocalDate, ImmutableList<TransactionUiItem>>) = copy(data = data, loading = false)
}

data class TransactionUiState(
    val id: String = "temp",
    val amount: String = "",
    val income: Boolean = false,        // expense by default: entered more often
    val date: DateDataUiState = DateDataUiState(),
    val categories: ImmutableSet<Category> = persistentSetOf(Category.default),
    val success: Boolean = false,
    val loading: Boolean = false,
    val errorMessage: String? = null,
) {
    /** The date is required: a rule without one does not expand into a calendar. */
    val valid get() = amountError == null && amount.isNotEmpty() && date.value != null

    /** Why the amount is not acceptable — under the field, not in a message at the bottom. */
    val amountError: String? get() = when {
        amount.isEmpty() -> null
        amount.toDoubleOrNull() == null -> "this is not an amount"
        amount.toDouble() == 0.0 -> "an amount is required"
        else -> null
    }
}
```

## View model

```kotlin
class TransactionsViewModel(
    private val getTransactionsUseCase: GetTransactionsUseCase,
    private val getCurrentCurrencyUseCase: GetCurrentCurrencyUseCase,
    private val deleteTransactionsUseCase: DeleteTransactionsUseCase,
) : ViewModel() {

    private val state = MutableStateFlow(TransactionListUiState(loading = true))
    val observe = state.asStateFlow()

    /** The same countdown and retry as the main screen: two screens must not survive one outage differently. */
    private val retries = RetrySchedule(
        scope = viewModelScope,
        onCountdown = { left -> state.update { it.copy(unreachable = it.unreachable?.copy(retryInSeconds = left)) } },
        load = { load() },
    )

    init { load() }

    fun onRetryClicked() = retries.retryNow()

    fun load() {
        viewModelScope.launch {
            state.value = TransactionListUiState(loading = true)
            // A ONE-SHOT READ, kept here as it is in the reference and as a warning: this view model
            // is alive underneath a settings screen pushed on top of it, so a currency changed there
            // is not seen until the screen is rebuilt. A preference other screens format by is a
            // StateFlow combined into the state below, not a value read once.
            val currency = getCurrentCurrencyUseCase.get()

            getTransactionsUseCase().fold(
                onSuccess = { transactionsFlow ->
                    retries.succeeded()
                    combine(transactionsFlow, getTransactionsUseCase.showingCacheFrom) { t, from -> t to from }
                        .mapLatest { (transactions, cacheFrom) -> buildState(transactions, currency, cacheFrom) }
                        .flowOn(Dispatchers.Default)
                        .collectLatest { state.value = it }
                },
                // Nothing to show — neither fresh nor saved. A state of the whole screen, not a line
                // in a corner, and it must carry a cause and a way out.
                onFailure = { throwable ->
                    state.value = TransactionListUiState(unreachable = ServerUnreachableUiState(cause = describe(throwable)))
                    retries.schedule()
                },
            )
        }
    }

    fun onTransactionSelected(item: TransactionUiItem) = state.update { s ->
        val selected = if (item in s.selectedTransactions) s.selectedTransactions - item else s.selectedTransactions + item
        s.copy(selectedTransactions = selected.toImmutableList())
    }

    fun onDeleteClicked() {
        viewModelScope.launch {
            val selected = state.value.selectedTransactions.map { it.id }
            state.update { it.copy(showDeleteDialog = false, selectedTransactions = persistentListOf()) }
            deleteTransactionsUseCase(selected)
        }
    }
}

/**
 * "HTTP 503 · host · 11:42:07". Code, host and time: a person tells "my wifi" from "their server
 * is down", and in a chat this is what makes sense to forward. "Network Error" distinguishes nothing.
 * (In the reference this lives in the main view model's companion object and is `internal`; shown
 * top-level here for brevity.)
 */
internal fun describe(throwable: Throwable, at: LocalTime = nowLocalTime()): String {
    val status = (throwable as? ServerException)?.status?.let { "HTTP $it" } ?: "no response"
    return "$status · ${serverConfig.host} · ${at.format(timeFormat)}"
}
```

A one-shot event that is not screen state:

```kotlin
/**
 * Logout is an event, not screen state. A separate flow because `state` lives under the
 * subscription to the rule list: clearing the token makes it emit again, and a flag inside the
 * state was overwritten at once. The test showed the overwrite.
 */
private val loggedOutState = MutableStateFlow(false)
val loggedOut = loggedOutState.asStateFlow()

fun onLogoutClicked() {
    viewModelScope.launch {
        logoutUseCase()
        state.value = MainUiState()
        loggedOutState.value = true
    }
}
```

## Component and Content

```kotlin
@Composable
fun TransactionsListComponent(
    modifier: Modifier = Modifier,
    appBarState: MainAppBarState = remember { MainAppBarState() },
    onTransactionClicked: (String) -> Unit = {},
) {
    rememberKoinModules { listOf(module { viewModelOf(::TransactionsViewModel) }) }

    val viewModel = koinViewModel<TransactionsViewModel>()
    val state: TransactionListUiState by viewModel.observe.collectAsStateWithLifecycle()

    TransactionDeleteDialog(state.showDeleteDialog, viewModel::onDeleteClicked, viewModel::onDismissDeleteDialog)
    connectToAppBarState(state.selectedTransactions, appBarState, viewModel::onShowDeleteDialogClicked, viewModel::onContextMenuClosed)

    TransactionsListContent(
        state, modifier, appBarState.contextMode,
        onTransactionSelected = viewModel::onTransactionSelected,
        onRetry = viewModel::onRetryClicked,
    ) { onTransactionClicked(it.id) }
}

@Composable
fun TransactionsListContent(
    state: TransactionListUiState,
    modifier: Modifier = Modifier,
    contextMode: Boolean = false,
    onTransactionSelected: (TransactionUiItem) -> Unit = {},
    onRetry: () -> Unit = {},
    // "Today" comes from outside so the screen does not depend on the day it is captured.
    today: LocalDate = today(),
    onTransactionClicked: (TransactionUiItem) -> Unit = {},
) {
    if (state.unreachable != null) {
        ServerUnreachable(state.unreachable, onRetry = onRetry)
        return
    }
    LazyColumn(modifier.fillMaxSize().testTag("transactions")) { /* ... */ }
}
```

Two screens, one form, one base view model: the create and edit screens register different
view models bound to the same base type inside their components:

```kotlin
@Composable
fun AddTransactionComponent(onNavigateBack: () -> Unit) {
    rememberKoinModules { listOf(module { viewModelOf(::AddTransactionViewModel).bind<BaseTransactionViewModel>() }) }
    TransactionComponentImpl(null, onNavigateBack)
}

@Composable
fun EditTransactionComponent(route: TransactionRoute, onNavigateBack: () -> Unit) {
    rememberKoinModules {
        listOf(module {
            viewModel { parameters -> EditTransactionViewModel(transactionId = parameters.get(), get(), get(), get(), get(), get(), get(), get()) }
                .bind<BaseTransactionViewModel>()
        })
    }
    TransactionComponentImpl(route.id, onNavigateBack)
}
```
