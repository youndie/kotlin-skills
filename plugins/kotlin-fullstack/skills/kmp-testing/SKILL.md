---
name: kmp-testing
description: "Write, place and run tests in a Kotlin Multiplatform project with a Ktor server and a Compose client: which suite a test belongs in, kotlin.test, fakes versus mocks, storage against a real database through the raw document, one test per build, view-model tests over stateIn, MockEngine, Compose UI tests on Content, screenshots, Koin graph tests, mutation checks. Use for 'write a test', 'add coverage', 'test the view model / route / repository / screen', 'why did the green build miss this bug'."
---

# Testing a Kotlin Multiplatform product

One source tree builds several artefacts: clients for four platforms and a server compiled twice.
That is what makes testing here different from the usual: **shared code does not have one test
suite**, and where a test lives is decided by the platforms it must run on. The reference is
`docs/TESTING.md` in [mani](https://github.com/youndie/mani-kotlin-fullstack); the server-side
traps come from larger services and are written generically.

Map: the first half is common and server (stack, placement, naming, fakes, storage, two builds);
the client starts at "Client: view models". Read the half that applies.

## Step 0. Check the project first

1. Open the nearest test of the same layer and copy its style: the harness, the naming, the
   fakes it already has. **The project's conventions win** over this file.
2. Check what the test source sets already depend on (`kotlinx-coroutines-test`,
   `ktor-server-test-host`, `ktor-client-mock`, `koin-test`, `compose.uiTest`, a screenshot
   plugin, an embedded database). **Do not add a test library for one test**; a hand-written fake
   is almost always cheaper, and in a shared suite a JVM-only library makes the test JVM-only.
3. Find the shared harness (`maniTest`, `TestMongo`, a `Harness` composable) and start from it;
   do not write a second one.

## The stack

| For | Use |
|---|---|
| annotations and assertions | `kotlin.test` — never `org.junit`, including in JVM-only tests; `org.junit` nails a test to the JVM and moving it later means rewriting it. The one documented exception: a per-class database fixture, which `kotlin.test` cannot express (`@BeforeAll`) |
| coroutines | `kotlinx-coroutines-test` (`runTest`, `StandardTestDispatcher`, `runCurrent`) |
| server routes | `ktor-server-test-host` (`testApplication`) — published for native targets too |
| client networking | `ktor-client-mock` (`MockEngine`) |
| a database for server tests | an embedded `mongod` on the JVM (flapdoodle); a containerised one for the native build |
| the dependency graph | a test that **resolves** every injected type from `koinApplication { }`; `koin-test`'s `verify()` only as a cheap first pass |
| client settings | `multiplatform-settings-test` (`MapSettings`) |
| screens | `compose.uiTest` (`runComposeUiTest`) |
| screenshots | [viddik](https://github.com/youndie/viddik) or whatever the project has |

Two libraries need a decision per suite rather than a habit. **A mocking library** is JVM-only:
in a suite that also compiles to native, a single `mockk()` makes the test JVM-only and leaves
the build that ships unchecked, so shared suites use hand-written fakes. In a JVM-only suite
(an Android-only client, a `jvmTest` of a UI module) mocks are acceptable for wide interfaces;
even there a fake that holds state usually reads better than `coVerify(exactly = 1)`. **A
Flow-testing library** (Turbine is multiplatform) is a convenience, not a requirement: a
`StateFlow` can be read with `runCurrent()` and `.value`; Turbine (`app.cash.turbine`) earns its
place when the *sequence* of states matters or when the state is a `stateIn(WhileSubscribed)`
flow (see the view-model section).

## Where a test lives

| Suite | Runs on | Covers |
|---|---|---|
| `:shared:jvmTest` (or `commonTest`) | JVM | the contract: pure functions, serializers, the demo seed |
| `:server-common:commonTest` | JVM **and** native | shared server code: tokens, hashing, validation, services with fakes |
| `:server-common:jvmTest` | JVM | anything needing `java.*` or a reference implementation (a token signed by the old library) |
| `:server:test` | JVM | the JVM build end to end against a real database: routes, storage, DI |
| `:server-native:linuxX64Test` + `linuxX64ReleaseTest` | native, debug **and release** | the native build end to end |
| `:composeApp:desktopTest` | JVM | view models, use cases, cache, token storage, the Koin graph — once is enough |
| `:composeApp:commonTest` | desktop, wasm, iOS | what breaks per platform: navigation graph stability, number formatting, Content tests |

The table is the reference's; in a project cut into `feature-x-domain / -data / -ui` modules
each module has its own `commonTest` or `jvmTest`, and the rules are the same per module.

Rules of placement:

1. Shared server code goes in `commonTest` of the common module: it then runs on both platforms
   and catches the difference between them.
2. A storage implementation is tested in its own build's suite; the implementations share no code.
3. Client logic is tested once, on desktop; running it four times buys nothing. A test goes to
   `commonTest` only when the platform is the variable.

## Naming and the shape of a test

A name is an English sentence in backticks stating the property under test:

```kotlin
@Test fun `a stranger cannot patch a foreign transaction through the id in the body`()
@Test fun `a rule the product cannot honour is refused`()
```

**No commas** in a backticked name: the Kotlin/Native test compilation rejects them
(`Name contains illegal characters`), and only the native target fails, so a JVM run does not
catch it. A long, listy name goes camelCase.

Above the test, a KDoc naming **the failure the test guards**, not restating the code:

```kotlin
/**
 * The id is taken from the path, not from the body.
 *
 * Ownership was checked against `path.id` while the document to write was picked by the `id` in
 * the body: a PATCH to YOUR OWN record with a stranger's in the body rewrote theirs and moved it
 * to the caller. It answered 200 while doing it, so from outside everything looked fine.
 */
```

Six months on, the value of a test is what it catches; the mechanics are visible in the body. No
failure to name means asking what the test is guarding at all. Assertions carry a message whenever
"did not match" does not explain itself: `assertEquals(1, ownersNow.size, "the foreign record
changed owner")`.

## Fakes instead of mocks

A fake is an ordinary class implementing a port, living in the test suite next to whoever uses it.

```kotlin
private class FakeUserRepository(initial: List<User>) : UserRepository {
    val stored = initial.toMutableList()
    var searchedPrefix: String? = null

    override suspend fun findByUsernamePrefix(prefix: String): List<User> {
        searchedPrefix = prefix
        return stored.filter { it.username.startsWith(prefix) }
    }
    override suspend fun delete(userId: String) { stored.removeAll { it.id == userId } }
    // ...the rest of the port
}
```

What it buys: **the compiler watches the contract** (change the port and every fake stops
compiling, showing which tests went stale); **a fake holds state** (`stored` after the run shows
what survived, so "was this called" rarely needs asserting); **it runs everywhere**. A failure
switch (`shouldCrash: () -> Boolean`) turns one fake into the failing variant.

Keep a fake `private` in its file while one test uses it; making it public invites bending it to
a second case. When a second test needs it, move it to its own file in the same suite. Swapping
one dependency inside an assembled graph is not a fake's job: use a Koin module declared after
the shared ones (Koin takes the last definition).

## Storage is tested against a real database, through the raw document

Everything that can break in storage breaks **silently**: a filter on `_id` sent as a string
matches nothing; an amount written as text is stored without complaint and read back as the
wrong type. A fake answers correctly in both cases. And a test that goes through `find` passes on
a diverged format too, because it writes and reads the same wrong way. So:

```kotlin
@Test
fun `transaction lands in mongo with an ObjectId and a decimal amount`() = maniTest { mongoUri ->
    val token = client.signIn("shape", "hunter22")
    val created = client.createTransaction(token, amount = "1234.56")

    MongoClient.create(mongoUri).use { mongo ->
        val raw = mongo.getDatabase("mani-test").getCollection<Document>(TRANSACTION_COLLECTION)
            .find(Filters.eq("_id", ObjectId(created.id))).firstOrNull()

        assertNotNull(raw, "not found by ObjectId — the id was stored as another type")
        assertTrue(raw["_id"] is ObjectId)
        assertTrue(raw["amount"] is Decimal128, "amount must be decimal128, not ${raw["amount"]}")
    }

    // Positive control: we looked at that record, not at an empty collection.
    assertEquals("1234.56", client.transactions(token).single().amount.toPlainString())
}
```

The harness (`maniTest` in the reference) starts the database, assembles the application
**exactly as production does** with a config built in code, exposes `overrides` for Koin modules,
and hosts the client helpers (`signIn`, `createTransaction`, ...). A new test starts from those.
On native the database runs alongside; each run works in its own database
(`uniqueDatabaseName`) and drops it afterwards. A negative result needs a positive control: after
asserting something is absent, assert something that proves you looked in the right place.

Three traps from services with more history:

- **The database address on native comes from the environment**, never a hardcoded port. A
  hardcoded `127.0.0.1:27017` on a shared runner was somebody else's container: while it ran the
  suite was green, when it stopped every test failed on a server-selection timeout, and no code
  change had anything to do with it. CI starts its own database and hands the port over; the
  default stays for a local `docker run`.
- **`runBlocking`, not `runTest`, for a real database on native.** Inside `runTest` time is
  virtual, and a driver that bounds its wait with a timeout in the caller's context sees the
  deadline fire instantly while the database is still answering. On the JVM the same code steps
  onto `Dispatchers.IO` and lands in real time, which is why only the native run failed.
- **SQLite tests use a file, not `:memory:`**, deleted before opening: an in-memory database
  belongs to the connection that opened it, and a pool hands out more than one, so migrations
  land in one connection's database and queries go to another, empty one ("no such table").

**Route tests on a service with use cases** swap the use case for a fake (or a mock in a JVM-only
suite) through an override module and stub the token verifier; the harness's client sets the
tenant header and the bearer by default. What is worth a test per route: the happy status, each
typed error's status, and **the tier**: the same route mounted for a role below `min` answers
`403` (an override module that grants a lower role makes that a one-liner). A route reached
without the header must answer `400`, not `500`.

## Two builds mean two checks

> **Shared code is tested once. Code with two implementations is tested twice.**

Routes, services, validation and token issuing need a single test in the shared suite. Storage,
and anything that reaches a driver, needs a test in each build: the ownership hole lived on the
seam between a shared route and a write filter belonging to each implementation, and fixing one
would have left the other open. Paired tests point at each other in their KDoc, or the second one
is lost when the first is edited.

**The release run of the native build is mandatory.** Kotlin/Native omits type-cast checks in
release builds; code that fails with a catchable exception in debug reaches undefined behaviour
in release. A route answered `500` on the deployed instance with a fully green run: the test
binary was the debug one, and the image ships the release one.

## Client: view models

The view model is built **directly**, with **real use cases over fake repositories**: use cases
are final classes and thin, the repository interface is the seam that already exists for them,
and the test then covers the use case too. (In a JVM-only suite a mock of the use case class is
acceptable; a suite that compiles to native cannot mock.) `Dispatchers.setMain` is replaced
**before** construction: `init` already launches into `viewModelScope`.

```kotlin
private val repository = FakeAccountRepository()                 // observe/refresh shape; holds a MutableStateFlow
private fun createViewModel() = AccountsListViewModel(
    observeAccountsUseCase = ObserveAccountsUseCase(repository),
    refreshAccountsUseCase = RefreshAccountsUseCase(repository),
    observeCurrenciesUseCase = ObserveCurrenciesUseCase(repository),
)

@Test
fun `uiState should filter out unapproved accounts`() = runTest(testDispatcher) {
    repository.accounts.value = listOf(approved, open, closed)
    val viewModel = createViewModel()

    viewModel.uiState.test {                                      // Turbine
        var state = awaitItem()
        while (state.totalAccounts == 0) state = awaitItem()   // skip the initial value and the loading states

        assertEquals(1, state.items.size)
        cancelAndIgnoreRemainingEvents()                        // a StateFlow never completes
    }
}

@Test
fun `AccountClick should emit OpenAccount event`() = runTest(testDispatcher) {
    val viewModel = createViewModel()
    viewModel.events.test {
        viewModel.onAction(AccountsListUiAction.AccountClick(99L))
        assertEquals(AccountsListUiEvent.OpenAccount(99L), awaitItem())
    }
}
```

**A `stateIn(WhileSubscribed)` state does nothing until somebody collects it.** Reading
`viewModel.uiState.value` after `runCurrent()` returns the `initialValue` forever, because the
upstream `combine` has not started. Collect it: `uiState.test { }`, or
`backgroundScope.launch { viewModel.uiState.collect {} }` and then `runCurrent()` and `.value`.
The test that "passes" against the initial value guards nothing.

Wait with a loop over a condition, not with `advanceTimeBy` and a guessed number: the condition
describes what you wait for, the number describes today's implementation. Bound the loop (an
iteration cap with a message): a `while (...) runCurrent()` that never becomes true never
suspends either, so `runTest`'s timeout cannot end it and the suite hangs. The three things worth
a test per screen: the derivation (push values into the fake flows, assert the derived state),
the flags (an action flips a flag and only that flag), and the events (an action emits the right
event and nothing lands in the state). The mapper is tested on its own, as a pure function.

## Client: networking

`MockEngine`, not a live server — and **the test client must mirror the production one**: the
same `Resources`, `ContentNegotiation` and `defaultRequest { contentType(Json) }`. A missing
default content type makes the request fail before it is sent, and the test then fails somewhere
other than the bug. Logic that lives inside the client's configuration (`refreshTokens { }`) is
extracted into a function so the mock engine can reach it; whatever the function cannot call for
itself comes in as a parameter.

## Compose: screens

Test the **stateless Content** with `runComposeUiTest` (in a multiplatform suite; a JVM-only
Android module may keep its JUnit rule): it receives a ready state and callbacks, no view model
enters. Two shapes of test: **rendering** (a fixture state from the previews object; assert what
is on screen for loading, empty, data, error, sheet open) and **wiring** (an `onAction` recorder
list; click, assert the recorded action). Drive a form with a `MutableStateFlow` collected in
`setContent` and updated by the test, so the test shows the form reflects state rather than
storing its own. Find nodes by `testTag` or `contentDescription`, not by visible text — copy
changes, tags do not. The exception is text that **is** the property under test.

Two platform traps: in the browser use `awaitIdle()` rather than `waitForIdle()` as the barrier
after a state change (one event loop; the blocking wait starves the work it waits for); a popup
that animates in may need `waitUntil` with a longer timeout, and a test that is flaky only in a
headless browser belongs in `desktopTest` with a KDoc saying why.

## Screenshots

Screens are captured in their stateless form with a fixed state, inside a `Harness` composable
that applies the theme. Names in ASCII (the tool replaces non-ASCII with underscores, and two
names would collapse into one file). Anything drawn from the clock takes `today` as a parameter,
or the golden lives until midnight. A chart that resolves a view model is substituted with a
ready-made state through a parameter.

**Bundle the font, or record and verify on one operating system.** Text drawn in a host font
renders differently on macOS and Linux by 1–4 % of the pixels, past any tolerance worth
keeping. viddik makes goldens portable once the fixture's theme bundles a face —
`viddikTypography()` or the project's own font through `normalizeVerticalMetrics()` — and its
own suite verifies on three operating systems that way; a project that has not done that has
host-specific goldens, and those do not belong in a merge gate, which is why the comparison is
a separate task from `test`. Keep the tolerance strict (viddik's default is 0.05 % of pixels
with a ±2 channel allowance; a colour change once slipped through a looser one). **Look at the
goldens after recording**, or a bug becomes the reference. The gap between a screen and the
design it was built to is a different comparison with its own tolerance: `design-to-compose`.

## The Koin graph

A missing binding is otherwise found not by a test but by a black screen on the client, and on
the server by a `500` on **one** route while the pod starts healthy and `/health` stays green:
Koin creates a `single` on first use, so a use case whose constructor has a defaulted clock
parameter registered with `singleOf` fails at the first sign-in, not at start-up. The test that
closes that gap **resolves** every type the routes inject, and its list is maintained by hand:
it is exactly as useful as the list is complete. Three traps:

1. `verify()` walks only the modules you list; view models registered inside components via
   `rememberKoinModules` never reach it and are added to the check by hand.
2. Generic types are erased: `Repository<Category>` and `Repository<Transaction>` are one key
   to the container, and the last registration wins for everybody. The fix is a concrete
   interface per aggregate; if a generic binding must exist, bind it by name and keep a test
   that the unnamed binding does not come back.
3. `verify()` skips constructor parameters with defaults **and nullable ones** (it treats them
   as optional and never looks for a binding); only resolving by type
   (`koinApplication { modules(...) }.koin.get<T>()`) sees them. Proven by reintroducing the bug. On the server, resolve every port
   in each build's test (creation is stricter than reflection); on native use `checkModules()`.

## Running

The set that runs on every pull request, and the native set on Linux with a real database:

```bash
./gradlew ktlintCheck :shared:jvmTest :server-common:jvmTest :server:test :composeApp:desktopTest :composeApp:wasmJsTest
```

```bash
./gradlew :server-common:linuxX64Test :server-native:linuxX64Test :server-native:linuxX64ReleaseTest
```

Traps that turn a green run into an unchecked one:

- **A pipeline swallows the exit code.** `./gradlew ... | tail` returns the status of `tail`.
  Write the output to a file and check `$?` before filtering anything.
- **`--rerun` applies only to the task it follows.** `./gradlew a b c --rerun` re-runs `c`
  alone; force one task per invocation.
- **Trust the timestamps of the result files, not `BUILD SUCCESSFUL`**:
  `find . -path '*/build/test-results/*' -name '*.xml' -newermt '-5 minutes' | wc -l`.
- **The wasm test task needs a browser** (`ChromeHeadless`); without one it fails at launch even
  though the compilation succeeded.

## Test the test

A green test does not prove it guards anything. Check a new test by **mutation**: undo the
change, confirm the test goes red, and that it is the one going red. If the mutation breaks
**more** tests than expected, the change reaches further than the commit message claims; if it
breaks **nothing**, the test is not guarding what it was written for (the reference learned that
a body-parsing check passed without `StatusPages`: Ktor already answered that way, and the test
actually guarded that the blanket handler does not spoil it — the KDoc had to be corrected). And
the reverse: an assertion that cannot fail (`assertTrue` derived from a status just asserted) is
not a check.

Examples: [examples/route-harness.md](examples/route-harness.md),
[examples/fakes-and-use-case-tests.md](examples/fakes-and-use-case-tests.md),
[examples/client-tests.md](examples/client-tests.md).
