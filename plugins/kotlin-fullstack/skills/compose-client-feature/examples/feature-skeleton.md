# A feature skeleton, bottom up

A budget-rule feature ("transactions") written in the shape the skill describes. The domain is
the public reference project's; the view-model shape is the one that scales. Everything below is
illustrative Kotlin, not a library.

## Base types (a `core` module or package)

```kotlin
fun interface UseCase<in P, out T> {
    suspend operator fun invoke(params: P): Result<T>
}

fun interface ObservableUseCase<in P, out R> {
    operator fun invoke(params: P): Flow<R>
}

/** Wraps execute() in Result; the only place the try/catch lives. */
abstract class BaseUseCase<in P, out R> : UseCase<P, R> {
    override suspend fun invoke(params: P): Result<R> = suspendRunCatching { execute(params) }
    protected abstract suspend fun execute(params: P): R
}

abstract class BaseNonParametrizedUseCase<out R> : UseCase<Unit, R> {
    override suspend fun invoke(params: Unit): Result<R> = suspendRunCatching { execute() }
    suspend operator fun invoke(): Result<R> = invoke(Unit)
    protected abstract suspend fun execute(): R
}

/** runCatching that lets cancellation through: a cancelled coroutine is not a failure on screen. */
suspend inline fun <T> suspendRunCatching(block: () -> T): Result<T> = try {
    Result.success(block())
} catch (e: CancellationException) {
    throw e
} catch (e: Throwable) {
    Result.failure(e)
}
```

```kotlin
/** What a repository throws. Above the data layer nothing knows the HTTP client. */
sealed class AppError(message: String, cause: Throwable? = null) : Exception(message, cause)
class NoNetworkError(cause: Throwable? = null) : AppError("No network connection", cause)
class ServerError(val code: Int, message: String?, cause: Throwable? = null) : AppError(message ?: "Server error $code", cause)
class ClientError(val code: Int, message: String?, cause: Throwable? = null) : AppError(message ?: "Request refused $code", cause)
class UnknownAppError(message: String?, cause: Throwable? = null) : AppError(message ?: "Unknown error", cause)

/** Maps transport exceptions once, at the repository. Errors already mapped and cancellation pass through. */
suspend inline fun <T> runNetworkCatching(block: suspend () -> T): T = try {
    block()
} catch (e: CancellationException) {
    throw e
} catch (e: AppError) {
    throw e
} catch (e: Exception) {
    throw e.toAppError()
}

fun Exception.toAppError(): AppError = when (this) {
    is IOException -> NoNetworkError(cause = this)
    is ServerResponseException -> ServerError(response.status.value, message, this)
    is ClientRequestException -> ClientError(response.status.value, message, this)
    else -> UnknownAppError(message, this)
}
```

```kotlin
/** Text the UI resolves later: a resource with arguments, or a literal that came from the server. */
sealed interface UiText {
    data class Resource(val id: StringResource, val args: List<Any> = emptyList()) : UiText
    data class Plain(val value: String) : UiText
}

@Composable
fun UiText.resolve(): String = when (this) {
    is UiText.Resource -> stringResource(id, *args.toTypedArray())
    is UiText.Plain -> value
}
```

## Domain

```kotlin
@JvmInline value class RuleId(val value: String)

data class Rule(
    val id: RuleId,
    val amount: Money,
    val income: Boolean,
    val date: LocalDate,
    val until: LocalDate?,
    val period: Period,
    val comment: String,
    val category: Category,
)

interface RuleRepository {
    fun observeRules(): Flow<List<Rule>>
    suspend fun refreshRules()
    suspend fun create(rule: Rule): Rule
    suspend fun update(rule: Rule)
    suspend fun delete(id: RuleId)
}

/** A preference other screens format by: observed, never read once. */
interface DisplayCurrencyRepository {
    fun observe(): Flow<Currency>
    suspend fun set(currency: Currency)
}
```

```kotlin
class ObserveRulesUseCase(private val repository: RuleRepository) : ObservableUseCase<Unit, List<Rule>> {
    override fun invoke(params: Unit): Flow<List<Rule>> = repository.observeRules()
}

class RefreshRulesUseCase(private val repository: RuleRepository) : BaseNonParametrizedUseCase<Unit>() {
    override suspend fun execute() = repository.refreshRules()
}

class DeleteRulesUseCase(private val repository: RuleRepository) : BaseUseCase<List<RuleId>, Unit>() {
    override suspend fun execute(params: List<RuleId>) = params.forEach { repository.delete(it) }
}

class ObserveDisplayCurrencyUseCase(private val repository: DisplayCurrencyRepository) : ObservableUseCase<Unit, Currency> {
    override fun invoke(params: Unit): Flow<Currency> = repository.observe()
}
```

## Data

```kotlin
class RuleRepositoryImpl(
    private val api: RulesApi,          // over the shared @Resource classes
    private val dao: RuleDao,           // the source of truth; an in-memory MutableStateFlow when the app has no database
) : RuleRepository {

    override fun observeRules(): Flow<List<Rule>> = dao.observeAll().map { rows -> rows.map { it.toDomain() } }

    override suspend fun refreshRules() = runNetworkCatching {
        dao.replaceAll(api.list().map { it.toEntity() })
    }

    /** Optimistic: the row is visible before the server answers, and gone again if it refuses. */
    override suspend fun create(rule: Rule): Rule = runNetworkCatching {
        val draft = rule.toEntity(pending = true)
        dao.upsert(draft)
        try {
            val created = api.create(rule.toDto())
            dao.replace(draft.id, created.toEntity())
            created.toDomain()
        } catch (e: Exception) {
            dao.delete(draft.id)
            throw e
        }
    }

    override suspend fun update(rule: Rule) = runNetworkCatching { dao.upsert(api.update(rule.toDto()).toEntity()) }
    override suspend fun delete(id: RuleId) = runNetworkCatching { api.delete(id.value); dao.delete(id.value) }
}

internal fun RuleDto.toEntity(pending: Boolean = false) = RuleEntity(/* ... */)
internal fun RuleEntity.toDomain() = Rule(/* ... */)
internal fun Rule.toDto() = RuleDto(/* ... */)
```

## UI: state, actions, events, mapper

```kotlin
data class RulesListUiState(
    val days: ImmutableMap<LocalDate, ImmutableList<RuleUiItem>> = persistentMapOf(),
    val selected: ImmutableSet<RuleId> = persistentSetOf(),
    val dayBalances: ImmutableMap<LocalDate, String> = persistentMapOf(),
    val loading: Boolean = false,
    val errorMessage: UiText? = null,
    val deleteDialogVisible: Boolean = false,
    /** Not null: the network is down and the list is the last known one, taken at this time. */
    val showingCacheFrom: String? = null,
)

sealed interface RulesListUiAction {
    data object Refresh : RulesListUiAction
    data class RuleClick(val id: RuleId) : RulesListUiAction
    data class RuleToggleSelected(val id: RuleId) : RulesListUiAction
    data object DeleteRequested : RulesListUiAction
    data object DeleteConfirmed : RulesListUiAction
    data object DeleteDismissed : RulesListUiAction
    data object ErrorDismissed : RulesListUiAction
}

sealed interface RulesListUiEvent {
    data class OpenRule(val id: RuleId) : RulesListUiEvent
}

object RulesUiMapper {
    fun toItem(rule: Rule, currency: Currency): RuleUiItem = RuleUiItem(
        id = rule.id,
        title = rule.comment.ifBlank { rule.category.name },
        amount = formatMoney(rule.amount, currency, sign = rule.income),
        period = rule.period.label(),
    )

    fun toMessage(error: Throwable): UiText = when (error) {
        is NoNetworkError -> UiText.Resource(Res.string.error_no_network)
        is ServerError -> UiText.Resource(Res.string.error_server, listOf(error.code))
        is ClientError -> error.message?.let(UiText::Plain) ?: UiText.Resource(Res.string.error_request)
        else -> UiText.Resource(Res.string.error_unknown)
    }
}
```

## The view model

```kotlin
class RulesListViewModel(
    private val observeRulesUseCase: ObserveRulesUseCase,
    private val refreshRulesUseCase: RefreshRulesUseCase,
    private val deleteRulesUseCase: DeleteRulesUseCase,
    private val observeDisplayCurrencyUseCase: ObserveDisplayCurrencyUseCase,
) : ViewModel() {
    private val mapper = RulesUiMapper

    private val _events = Channel<RulesListUiEvent>(Channel.UNLIMITED)
    val events: Flow<RulesListUiEvent> = _events.receiveAsFlow()

    private val refreshTrigger = Channel<Unit>(Channel.CONFLATED)
    private val selected = MutableStateFlow<Set<RuleId>>(emptySet())
    private val uiFlags = MutableStateFlow(UiFlags())

    data class UiFlags(
        val loading: Boolean = false,
        val errorMessage: UiText? = null,
        val deleteDialogVisible: Boolean = false,
    )

    val uiState: StateFlow<RulesListUiState> =
        combine(observeRulesUseCase(Unit), observeDisplayCurrencyUseCase(Unit), selected, uiFlags) { rules, currency, selected, flags ->
            val simulated = rules.simulate()
            RulesListUiState(
                days = simulated.mapValues { (_, day) -> day.map { mapper.toItem(it, currency) }.toImmutableList() }.toImmutableMap(),
                selected = selected.toImmutableSet(),
                dayBalances = buildDayBalances(simulated, currency),
                loading = flags.loading,
                errorMessage = flags.errorMessage,
                deleteDialogVisible = flags.deleteDialogVisible,
            )
        }
            .flowOn(Dispatchers.Default)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), RulesListUiState(loading = true))

    init {
        viewModelScope.launch { refreshTrigger.receiveAsFlow().collectLatest { load() } }
        refreshTrigger.trySend(Unit)
    }

    fun onAction(action: RulesListUiAction) {
        when (action) {
            RulesListUiAction.Refresh -> refreshTrigger.trySend(Unit)
            is RulesListUiAction.RuleClick -> _events.trySend(RulesListUiEvent.OpenRule(action.id))
            is RulesListUiAction.RuleToggleSelected -> selected.update { if (action.id in it) it - action.id else it + action.id }
            RulesListUiAction.DeleteRequested -> uiFlags.update { it.copy(deleteDialogVisible = true) }
            RulesListUiAction.DeleteDismissed -> uiFlags.update { it.copy(deleteDialogVisible = false) }
            RulesListUiAction.DeleteConfirmed -> delete()
            RulesListUiAction.ErrorDismissed -> uiFlags.update { it.copy(errorMessage = null) }
        }
    }

    private suspend fun load() {
        uiFlags.update { it.copy(loading = true, errorMessage = null) }
        refreshRulesUseCase().onFailure { e -> uiFlags.update { it.copy(errorMessage = mapper.toMessage(e)) } }
        uiFlags.update { it.copy(loading = false) }
    }

    private fun delete() {
        val ids = selected.value.toList()
        uiFlags.update { it.copy(deleteDialogVisible = false) }
        selected.value = emptySet()
        viewModelScope.launch {
            deleteRulesUseCase(ids).onFailure { e -> uiFlags.update { it.copy(errorMessage = mapper.toMessage(e)) } }
        }
    }
}
```

What this buys over a hand-mutated `MutableStateFlow<UiState>`:

- a currency changed on another screen re-derives the list the moment the user returns, because
  the currency is a source of the `combine`, not a value read once in `init`;
- a failed refresh keeps the last list on screen, because the error lives in `uiFlags` and the
  list in the domain flow; `state.value = UiState(error = …)` would have erased it;
- deleting a selection cannot lose rows to a race, because nothing does read-modify-write on
  the list; the source of truth is the repository;
- the screen can be tested by pushing values into fake flows and reading one derived state.

## Screen and Content

```kotlin
@Composable
fun RulesListScreen(
    viewModel: RulesListViewModel = koinViewModel(),
    onOpenRule: (RuleId) -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            when (event) {
                is RulesListUiEvent.OpenRule -> onOpenRule(event.id)
            }
        }
    }

    RulesListContent(state = state, onAction = viewModel::onAction)
}

@Composable
fun RulesListContent(
    state: RulesListUiState,
    onAction: (RulesListUiAction) -> Unit = {},
    today: LocalDate = today(),
) {
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(state.errorMessage) {
        state.errorMessage?.let { message ->
            snackbarHostState.showSnackbar(message.resolve())
            onAction(RulesListUiAction.ErrorDismissed)
        }
    }

    if (state.deleteDialogVisible) {
        DeleteRulesDialog(
            count = state.selected.size,
            onConfirm = { onAction(RulesListUiAction.DeleteConfirmed) },
            onDismiss = { onAction(RulesListUiAction.DeleteDismissed) },
        )
    }

    Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize().testTag("rules")) {
            state.days.forEach { (date, rules) ->
                item { DayHeader(date, state.dayBalances[date], isToday = date == today) }
                items(rules, key = { it.id.value }) { rule ->
                    RuleRow(
                        rule,
                        selected = rule.id in state.selected,
                        onClick = { onAction(RulesListUiAction.RuleClick(rule.id)) },
                        onLongClick = { onAction(RulesListUiAction.RuleToggleSelected(rule.id)) },
                    )
                }
            }
        }
    }
}
```

## Previews, which double as fixtures

```kotlin
object RulesListPreviews {
    val items = mapOf(
        LocalDate(2026, 8, 16) to persistentListOf(RuleUiItem(RuleId("rent"), "Rent", "−1 450 $", "monthly")),
        LocalDate(2026, 8, 17) to persistentListOf(RuleUiItem(RuleId("food"), "Groceries", "−145 $", "weekly")),
    ).toImmutableMap()
}

@Preview @Composable private fun Loading() = AppTheme { RulesListContent(RulesListUiState(loading = true)) }
@Preview @Composable private fun Data() = AppTheme { RulesListContent(RulesListUiState(days = RulesListPreviews.items), today = LocalDate(2026, 8, 17)) }
@Preview @Composable private fun Empty() = AppTheme { RulesListContent(RulesListUiState()) }
@Preview @Composable private fun DeleteDialog() = AppTheme { RulesListContent(RulesListUiState(days = RulesListPreviews.items, deleteDialogVisible = true)) }
```

## A screen with several sheets: nested flags

When a screen has four sheets and a dialog, keep the flags as a nested object so the data part
of the state stays readable, and gate every sheet on one boolean:

```kotlin
data class AccountDetailsUiFlags(
    val loading: Boolean = false,
    val errorMessage: UiText? = null,
    val actionsSheetVisible: Boolean = false,
    val periodSheetVisible: Boolean = false,
    val downloadDialogVisible: Boolean = false,
)

@Stable
data class AccountDetailsUiState(
    val accounts: ImmutableList<AccountUiItem> = persistentListOf(),
    val selectedAccountId: AccountId? = null,
    val transactions: ImmutableList<TransactionUiItem> = persistentListOf(),
    val summary: SummaryUiState? = null,
    val flags: AccountDetailsUiFlags = AccountDetailsUiFlags(),
)
```

The view model then has `uiFlags`, `fetchedData` (the summary and transactions fetched per
selection), `dialogsState` (what a sheet is showing) and the input flows (`selectedAccountId`,
`timeframe`) as separate `MutableStateFlow`s, all joined in one `combine`; the load runs in
`combine(selectedAccountId, accounts, timeframe).distinctUntilChanged().collectLatest { }`, so a
change of selection cancels the previous fetch.
