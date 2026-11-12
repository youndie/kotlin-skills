# A screen that is the answer to a request: one writer, no `combine`

Referenced from [SKILL.md](../SKILL.md), "UI: which shape the view model takes".

The screen is the class picker of [shashki](https://github.com/youndie/shashki)'s rider app: a
journey is priced per ride class, the rider picks one and orders. The view model below is that
one **rewritten to the rules of this file**; the tests are the reference's, trimmed. Read on the
reference's `main` on 2026-11-12, all twelve of its view models are this kind of screen — none
has a flow to observe — and they show what happens when the skill names only the derived shape:
twelve of twelve assign `_uiState.value = _uiState.value.copy(…)`, nine put `throwable.message`
on screen, three keep a `Job` to cancel by hand.

## When this shape is the right one

Everything the screen shows is the answer to a request made *for this screen*, and nothing else
in the application edits it: a quote, a receipt, a document upload, one step of a wizard. There
is no local source of truth and no preference shared with another screen, so a `combine` would
have one input — the state itself.

It stops being right the day a second source appears: a setting another screen changes, a list
a repository can `observe`. That source joins as a flow and the state becomes derived
([feature-skeleton.md](feature-skeleton.md)). The two are not mixed in one view model: a derived
`uiState` next to a hand-written one is two writers again.

## The view model

```kotlin
data class ClassPickerUiState(
    val loading: Boolean = true,
    val quotes: ImmutableList<ClassQuote> = persistentListOf(),
    val selected: RideClass = RideClass.ECONOMY,
    val ordering: Boolean = false,
    val error: UiText? = null,
) {
    fun hasCars(rideClass: RideClass) = quotes.any { it.rideClass == rideClass && it.pickupEtaSeconds != null }
}

class ClassPickerViewModel(
    private val quoteJourney: QuoteJourneyUseCase,
    private val requestRide: RequestRideUseCase,
    private val params: ClassPickerParams,
) : ViewModel() {
    private val mapper = ClassPickerUiMapper

    private val _uiState = MutableStateFlow(ClassPickerUiState())
    val uiState: StateFlow<ClassPickerUiState> = _uiState.asStateFlow()

    private val _events = Channel<ClassPickerUiEvent>(Channel.UNLIMITED)
    val events: Flow<ClassPickerUiEvent> = _events.receiveAsFlow()

    private val reload = Channel<Unit>(Channel.CONFLATED)

    init {
        // collectLatest: a Retry while a load is in flight cancels it, so a stale answer cannot
        // arrive second and overwrite a fresh one. No job to keep, nothing to forget to cancel.
        viewModelScope.launch { reload.receiveAsFlow().onStart { emit(Unit) }.collectLatest { load() } }
    }

    fun onAction(action: ClassPickerUiAction) {
        when (action) {
            // A class nobody is driving cannot be selected: the tile still reports the click.
            is ClassPickerUiAction.Select ->
                _uiState.update { if (it.hasCars(action.rideClass)) it.copy(selected = action.rideClass) else it }
            ClassPickerUiAction.Retry -> reload.trySend(Unit)
            ClassPickerUiAction.Order -> order()
        }
    }

    /** Asks again for as long as the caller's scope lives. Called by the Screen, not from `init`. */
    suspend fun watch() {
        while (true) {
            delay(QUOTE_INTERVAL)
            quoteJourney(params.journey).onSuccess(::show)   // a failed poll keeps the screen it has
        }
    }

    private suspend fun load() {
        _uiState.update { it.copy(loading = true, error = null) }
        quoteJourney(params.journey)
            .onSuccess(::show)
            .onFailure { e -> _uiState.update { it.copy(loading = false, error = mapper.toMessage(e)) } }
    }

    private fun show(quotes: JourneyQuotes) = _uiState.update {
        it.copy(
            loading = false,
            quotes = quotes.classes.toImmutableList(),
            selected = quotes.classes.selectable(it.selected),   // the selection follows the cars
        )
    }

    private fun order() {
        // Taken and tested in one step, BEFORE the coroutine starts: under a dispatcher that queues
        // the launch, two taps both pass a check made outside it and the ride is ordered twice.
        if (_uiState.getAndUpdate { it.copy(ordering = true) }.ordering) return
        viewModelScope.launch {
            requestRide(params.order(_uiState.value.selected))
                .onSuccess { _events.trySend(ClassPickerUiEvent.Ordered(it.id)) }
                .onFailure { _events.trySend(ClassPickerUiEvent.Failed(mapper.toMessage(it))) }
            _uiState.update { it.copy(ordering = false) }
        }
    }
}
```

```kotlin
@Composable
fun ClassPickerScreen(viewModel: ClassPickerViewModel = koinViewModel(), onOrdered: (String) -> Unit) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    // The poll lives here, not in the view model: this effect is cancelled when the screen leaves
    // the composition, so a class picker underneath a trip stops asking.
    LaunchedEffect(viewModel) { viewModel.watch() }

    LaunchedEffect(Unit) { viewModel.events.collect { /* Ordered → onOrdered, Failed → snackbar */ } }

    ClassPickerContent(state, viewModel::onAction)
}
```

## The rules, and what each one is for

- **One private `MutableStateFlow`, exposed with `asStateFlow()`, written only through
  `update { }`.** `_uiState.value = _uiState.value.copy(…)` is a read, a copy and a write, and
  this screen already has three writers: the first load in `viewModelScope`, the poll in the
  composition's scope, the order. They stay correct only while every one of them runs on the
  main thread and none suspends between the read and the write; `update` costs nothing and
  stays correct when that stops being true.
- **The screen's own flags are fields of the state.** There is no `UiFlags` holder here: its job
  in the derived shape is to be one more input of the `combine`, and this shape has none.
- **A reload is a trigger collected with `collectLatest`**, with `onStart { emit(Unit) }` for
  the first load. A hand-kept `loadJob?.cancel()` does the same thing with a field that the
  next loader added to the view model has to remember.
- **A flag that guards a request is set before the coroutine is launched**, in the same step
  that tests it (`getAndUpdate`). Set inside the coroutine, it depends on the launch running
  immediately — true on `Dispatchers.Main.immediate`, false under a test dispatcher, which is
  where the second tap gets through first.
- **The three failures are three different answers.** The first load failing goes into the
  state: a screen with no prices has to say why. A poll failing five seconds later says nothing
  and keeps the prices: the rider is looking at an answer that is still the best one known. An
  action failing is an event — a snackbar, once. Collapsing them gives either an empty screen
  after a blip or a silent first load.
- **Errors reach the screen as `UiText` mapped from `AppError`**, in both the state and the
  event. `throwable.message ?: "the server did not answer"` is a library's English or the
  fallback, never the product's words.
- **A poll runs in the composition's scope, not in `viewModelScope`** — a `suspend fun watch()`
  the Screen calls from `LaunchedEffect(viewModel)`. A view model outlives its screen's
  visibility: the entry stays on the back stack under the next screen, so a loop started from
  `init` would have turned the tiles live and then gone on asking under a trip for as long as
  the trip lasted. The defect that asked for the poll was the opposite one: the screen asked
  once, at start, so a rider who opened the application before any driver was online read *no
  cars nearby* until they restarted it — zero requests in sixty seconds of server log
  (shashki B-66). On a platform that keeps a stopped screen composed (Android in the
  background), wrap the call in `repeatOnLifecycle(STARTED)` as for the events.
- **The interval is measured, and written next to its reason.** Five seconds here: the request
  answers in about ten milliseconds and what is being watched is a car arriving within a few
  hundred metres. What goes stale decides what is polled — the wait is a fact about the world,
  the price is arithmetic, and the route is not asked for again at all.

## Tests

`uiState.value` after `advanceUntilIdle()` is a real reading here: nothing is behind a
`stateIn(WhileSubscribed)`, so the caveat in `kmp-testing` about a state that stays at its
initial value does not apply. Events are a buffered `Channel`, so they are read after the fact
with `events.first()` rather than collected alongside.

```kotlin
@Test
fun `a driver who comes online turns the tiles live without a restart`() = runTest(dispatcher) {
    val model = viewModel()
    advanceUntilIdle()
    assertNull(model.uiState.value.quotes.first().pickupEtaSeconds, "the fixture already had a car")

    val watching = backgroundScope.launch { model.watch() }      // the scope the Screen would give it
    rides.quotes = FakeRideRepository.QUOTES
    advanceTimeBy(6.seconds)

    assertEquals(240, model.uiState.value.quotes.first().pickupEtaSeconds, "the screen never asked again")
    watching.cancel()
}

@Test
fun `a failed refresh keeps what is already drawn`() = runTest(dispatcher) {
    val model = viewModel()
    advanceUntilIdle()
    val before = model.uiState.value.quotes

    val watching = backgroundScope.launch { model.watch() }
    rides.failWith = IllegalStateException("the server did not answer")
    advanceTimeBy(6.seconds)

    assertEquals(before, model.uiState.value.quotes, "a failed poll emptied the screen")
    watching.cancel()
}
```

Removing the loop fails the first; making a failed poll write the error fails the second. What
the pair cannot show is the half the design exists for — that the poll *stops* when the screen
is covered — because that is a property of where `watch()` is called from. It is held by the
Screen's own test, or by reading the `LaunchedEffect`; do not move the loop into `init` to make
it easier to reach.
