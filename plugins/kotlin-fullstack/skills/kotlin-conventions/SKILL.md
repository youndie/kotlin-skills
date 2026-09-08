---
name: kotlin-conventions
description: "Naming, abstraction and commenting conventions for Kotlin Multiplatform code: how to name resources, routes, storage ports and their implementations, use cases, view models, states, components, DI modules, tests and expect/actual files; when an interface, a base class, a generic or an expect/actual pair is justified and when it is two implementations that will drift; Result at boundaries; events versus state; how to write a KDoc that names the failure it guards or the alternative that was rejected; what must not enter an open repository; and a grep-able review checklist. Use this whenever the user asks how to name something, asks for a code review or a style pass on Kotlin / KMP / Compose / Ktor code, refactors, introduces an abstraction, or asks whether something should be an interface, a base class or expect/actual."
---

# Kotlin conventions: names, abstractions, comments

Extracted from [mani](https://github.com/youndie/mani-kotlin-fullstack), where one root package
spans a contract module, two server builds and a four-platform client. The conventions are the
ones that made that readable; each carries its reason so the next reader can tell a rule from a
habit.

## Step 0. Check the project first

Read `.editorconfig`, `CLAUDE.md` and the newest feature in the module you are in. **The
project's conventions win.** Where the project has no convention for a case, use the one below
and, if the repository keeps a conventions file, record it there in the same change.

## Names by kind

| Kind | Name | Example | Why this shape |
|---|---|---|---|
| path class | `<Subject>Resource`, nested `ById`, sub-paths as nested classes | `TransactionResource.ById`, `AuthResource.Refresh` | reads as the URL tree |
| wire model | the noun, `@Serializable data class` | `Transaction`, `Category`, `Tokens` | it *is* the entity on the wire |
| request DTO | `<Verb>Params` / `<Subject>Params` | `LoginParams`, `RefreshParams` | distinguishes input from the entity |
| stored shape, server-common | `<Noun>Record` | `TransactionRecord` (adds `userId`) | server-side notion, not the contract |
| stored shape, per driver | `<Noun>Db` | `TransactionDb`, `UserDb` | the driver's types live here only |
| storage port | `<Noun>Repository` (interface, in common) | `UserRepository`, `TokenRepository` | domain vocabulary, no driver |
| storage implementation | `<Driver><Noun>Repository` when there is more than one driver; `<Noun>RepositoryImpl` when there is one | `MongoUserRepository`, `MongknUserRepository`, `Sqlx4kUserRepository`; `OrdersRepositoryImpl` | two drivers means two implementations; `Impl` would not say which |
| use case (server) | `<Verb><Noun>UseCase : UseCase<Params, R>` with nested `class Params` and nested `sealed class Error`; feature-wide `CommonError` | `CreateOrderUseCase.Params`, `CreateOrderUseCase.Error.LimitReached`, `CommonError.SaveFailure` | the route dispatches errors by type, never by message |
| error dispatcher | `suspend fun RoutingContext.dispatch<Family>Error(error)` next to the use cases it maps | `dispatchInventoryError` | one mapping per error family, shared by every route that can hit it |
| access helper | `withAccess(min) { (user, tenantId) -> }`, `withUser { }`; tenant header read raw only under a role-gated mount | `withAccess(min = Role.MANAGER)` | the tier is visible at the call site |
| role gate | `withRole(...) { }` / `withAnyRole(...) { }` as route-scoped plugins | | a gate is a mount, not an `if` |
| transaction port | `TransactionManager.withTransaction { }`; `NoopTransactionManager` for tests | | no handle in the signature; the carrier is in the coroutine context |
| ports for cross-cutting effects | `fun interface <Noun>Reporter` / `<Noun>Notifier` with `Logging` / `Noop` companions | `ErrorReporter.Logging`, `ErrorReporter.Noop` | a dependency, substitutable; `expect` is not |
| workers | `<Noun>Worker` / `<Noun>Scheduler` with `start()` / `stop()`, registered with an explicit lambda | `InventorySyncOutboxWorker` | intervals are defaulted parameters |
| single-method port | `fun interface <Question>` | `StorageHealth { isReachable() }` | the only common thing between two drivers is the question |
| routing | `fun Routing.<subject>Routing()` in `<Subject>Routing.kt` | `transactionRouting()` | one function per subject, assembled in one place |
| validation | `fun <subject>Problem(x): String?` in `Rules.kt` | `transactionProblem`, `credentialsProblem` | returns the problem or null; no exception vocabulary |
| service (server) | `<Subject>Service`, ordinary class in common | `AuthService`, `DemoService` | orchestration over ports |
| Koin module | `val <feature>Module`, in `module.kt`; storage: `fun <technology>StorageModule(config)` | `authModule`, `mongoStorageModule` | the file name says "this feature's wiring" |
| client repository | interface `<Noun>Repository` in `domain`, `<Noun>RepositoryImpl` in `data`; methods `observe<Noun>s()` / `refresh<Noun>s()` | `AccountRepository`, `AccountRepositoryImpl` | one implementation on the client, so `Impl` is honest; the two verbs name the source of truth and the network |
| domain model | the noun; ids as value classes; closed sets as sealed interfaces with `Other(raw)` | `Account`, `AccountId`, `AccountKind.Other("")` | typed, not stringly; an unknown server value survives the trip |
| database row | `<Noun>Entity` + `<Noun>Dao` | `AccountEntity`, `AccountDao` | |
| mapper | extension functions `toEntity()` / `toDomain()` / `toDto()` next to the repository; UI side an `object <Screen>UiMapper` | `AccountEntity.toDomain()`, `AccountsUiMapper` | pure functions, each with a test |
| use case, action | `<Verb><Noun>UseCase : BaseUseCase<P, R>` returning `Result` | `RefreshAccountsUseCase`, `DownloadStatementUseCase` | one operation per class; the verb is the operation |
| use case, observation | `Observe<Noun>sUseCase : ObservableUseCase<P, R>` returning `Flow` | `ObserveAccountsUseCase` | a flow is not a `Result` per element |
| errors | `AppError` sealed hierarchy: `NoNetworkError`, `ServerError(code)`, `ClientError(code)`, `UnknownAppError` | | mapped once at the repository; the UI maps them to text |
| view model | `<Screen>ViewModel`; route arguments as `<Screen>Params` | `AccountDetailsViewModel(params: AccountDetailsParams, …)` | |
| screen state | `<Screen>UiState` (derived, immutable); the screen's own booleans in `UiFlags` (nested as `flags` on busy screens) | `AccountsListUiState`, `AccountDetailsUiFlags` | one class per screen, never a shared base state |
| user intent | `<Screen>UiAction` sealed interface, one `onAction()` | `AccountsListUiAction.FilterApply` | named after what the person did |
| one-shot effect | `<Screen>UiEvent` sealed interface, `events: Flow<…>` from a `Channel` | `AccountsListUiEvent.OpenAccount` | navigation and toasts leave the view model here |
| UI item | `<Noun>UiItem`; text as `UiText` | `AccountListUiItem`, `UiText.Resource(...)` | resolved in Compose, testable without it |
| stateful screen | `<Screen>Screen(viewModel, callbacks)` | `AccountsListScreen` | resolves the view model, forwards events |
| stateless screen | `<Screen>Content(state, onAction)` | `AccountsListContent` | state in, actions out; what tests and previews render |
| previews | `<Screen>Previews` object with fixtures + one `@Preview` per state | `AccountsListPreviews` | the fixtures double for Content tests and screenshots |
| navigation | `<App>Screen` enum for plain routes, `@Serializable class <Noun>Route(val id)` for routes with arguments | `ManiScreen.Main`, `TransactionRoute` | |
| expect/actual file | `X.kt` + `X.<platform>.kt`, or the same file name in the platform source set | `ServerConfigPlatform.android.kt` | the IDE and `grep` pair them |
| test class | `<Subject>Test`; paired tests across builds share the subject | `OwnershipTest` (JVM), `ManiApiTest` (native) | |
| test function | an English sentence in backticks, no commas; camelCase when long | `` `a stranger cannot patch a foreign transaction through the id in the body` `` | see `kmp-testing` |
| constants | `SCREAMING_CASE`, private unless shared | `MAX_COMMENT_LENGTH`, `TRANSACTION_COLLECTION` | a collection name shared by two builds is a constant in each with the same value |

Two habits worth adopting whole: **the product's vocabulary in the UI, the model's in the
code** (the interface says "rule", the class is `Transaction`), and **file names follow meaning,
not the one-declaration rule** (`module.kt` is one feature's DI, `sumOf.kt` is a set of
extensions), with the ktlint filename rule disabled and the reason recorded in `.editorconfig`.

## Packages

- One root package for every module (`io.github.youndie.mani`). A feature then has the same
  directory in every module it touches, and one `grep` finds all sides.
- Feature first, layer second: `feature/<name>/{data,domain,ui}`, not `data/<name>`.
- The root holds only what several features import and none owns: `security/`, `config/`,
  `navigation/`, `theme/`, `components/`, `useCase/`, `uiState/`, `utilz/`.
- Vendored third-party code keeps its own package and is excluded from formatting by path, with
  the reason next to the exclusion.

## Language

Everything in code is English: identifiers, comments, KDoc, test names, exception messages,
Gradle task descriptions, refusal texts that reach a user. Commit messages are English and
follow Conventional Commits. The check that catches drift:

```bash
grep -rnP '[\x{0400}-\x{04FF}]' --include='*.kt' --include='*.kts' --include='*.toml' .
```

Test fixtures may legitimately contain non-ASCII (an octets-versus-characters check); the grep
is a review aid, not a gate on its own.

## Abstractions: when each one is earned

**An interface is earned by a second implementation or by a seam a test needs.** Storage ports
have two implementations and are interfaces in the common module. A client repository has one
implementation and an interface because the view-model tests need a fake. A class with one
implementation and no test seam is a class.

**`expect/actual` is earned by a platform API and nothing else.** Two actuals are two
implementations the compiler checks for signature and never for behaviour. Count the pairs; be
able to say what each one's platform API is (`getenv`, `SharedPreferences`, `window.location`,
the entry point). Token signing, hashing, validation, routing and configuration are common.
**A dependency is an interface in DI, not an `expect`**: an error reporter, a notifier, a clock.
`expect` gives exactly one implementation per platform and nothing to substitute in a test; a
`fun interface` with `Logging` and `Noop` companions gives both, and when the JVM-only library
behind it grows a native build, one line in the native module changes.

**A base class is earned by two concrete classes sharing behaviour that goes wrong when
copied**, and it must not own the state. Two shapes that look like reuse and are not:

- *A generic base state* (`BaseViewState(loading, error)`, `CommonUiState<T>`, `DataState<T>`
  with `showData()` / `showError()`). It erases: `setError()` builds a fresh object and the
  data that was on screen disappears; it cannot express "refreshing with data", "empty",
  "sheet open"; and the compiler cannot check that a screen's state has what that screen needs.
  One `data class` per screen, updated with `copy()`, derived from flows. This rule was learned
  by deprecating exactly such a base in a large codebase, with those three reasons written on it.
- *A generic CRUD repository over a marker interface* (`DataSource<T : WithId>`,
  `BaseFlowRepository<T>`). It puts a client concern (`WithId`) into the domain model, forces
  every feature into the shape of a list, and its erased generics make every DI binding need a
  name (`DataSource<Category>` and `DataSource<Transaction>` are one key). Write the repository
  the aggregate needs; share the optimistic-write technique as a pattern, not as a superclass.

**A generic type at a DI boundary needs a name**, and the need for names is itself the signal
that the generic should not be there.

**Three shapes of one entity are not duplication.** Wire (`Transaction`), server-side record
(`TransactionRecord`), stored document (`TransactionDb`): each edge maps, and none leaks across.
Collapsing them puts `userId` into the contract or the driver's `ObjectId` into the client. On
the client the same rule reads DTO → entity → domain → UI item, with an extension-function
mapper at each edge; a small app may skip the domain copy and use the contract class, and says so.

**Domain models are typed.** Ids are value classes, money is a type, closed sets from the server
are sealed interfaces with an `Other(raw)` case. A `String` id and a `Double` amount compile
everywhere and are wrong somewhere.

**A sentinel value is a decision, not a placeholder.** `Category.default` declared in the
contract with a KDoc saying when the server substitutes it. Undocumented, it reads as a stub and
gets "cleaned up".

**Validation is a pure function that returns the problem.** `fun xProblem(x): String?` — no
exception hierarchy to maintain, trivially testable at each boundary, and the returned text is
what the user sees, so it says what to fix.

**Configuration is a data class built by one `fromEnv()`**, nested per concern, so a test
constructs it in code. A decision about a value is a named function of that value.

## `Result`, exceptions and cancellation

- `Result` at the **use-case boundary** on the client, for **actions** only: the view model folds
  it into flags. An **observation** is a plain `Flow`; a `Flow<Result<T>>` hides failures inside
  the stream and forces every collector to unwrap. On the server, routes call repositories and
  services directly and let `StatusPages` map exceptions; a small server has no use-case layer.
- Transport exceptions become a domain `AppError` **once**, at the repository; nothing above the
  data layer imports the HTTP client. The UI maps `AppError` to `UiText`; `throwable.message` is
  a library's English or null.
- On the server, a use case throws **typed** errors inside `suspendRunCatching` (a nested
  `sealed class Error`, `data object` cases) and the route dispatches them with an exhaustive
  `when` that rethrows the unknown; matching on `message` and a generic `400` for everything are
  the two ways a bug becomes a client error and disappears from the reporter.
- Never nest `Result` in `Result`; never give a `UseCase` base a `get()` that rethrows (the
  callers bypass `Result` and the failure path goes untested); never hardcode a dispatcher in a
  use-case base (untestable, and I/O belongs to the repository that does it).
- `suspendRunCatching` everywhere a `runCatching` would sit in suspend code: plain `runCatching`
  swallows `CancellationException`, and a cancelled coroutine then surfaces as a network error on
  screen or as a `500` on the server. Every `catch (e: Exception)` in suspend code is preceded by
  `catch (e: CancellationException) { throw e }`.
- Exceptions carry what a person needs to tell causes apart: `ServerException.status` is
  nullable because "the server said 503" and "the server was never reached" are different.

## Events versus state

State is what a screen shows now; an event is news of one moment. Session expiry, logout, "saved,
close the screen", "open this account" are events. In a view model they are a sealed `UiEvent`
sent through a `Channel` and exposed as `receiveAsFlow()`, collected once by the Screen; outside
view models a `SharedFlow` with `replay = 0`. **Never** a `success: Boolean` or `loggedOut` field
inside a state (the next emission overwrites it, or a `LaunchedEffect` fires on it again), and
never a subscription that rebuilds navigation, because a rebuilt graph resets to its start
destination. All three were real defects.

**State is derived, not assigned.** A view model's `UiState` is a `combine` of domain flows,
input flows and its own `UiFlags`, turned into a `StateFlow` with `stateIn`. `state.value = …`
in more than one place is the sign that two writers will race and one will erase the other.

## Immutability and concurrency

- `ImmutableList` / `ImmutableMap` / `ImmutableSet` in every UiState: Compose skips recomposition
  only for stable types.
- Flows that several coroutines write change through `MutableStateFlow.update { }`; `value += x`
  is three steps and loses concurrent writes. Better still, do not have several writers: derive.
- A resource with a pool (a database client) is one `single` per process; the comment says why.

## Comments and KDoc

A KDoc names **the failure the code guards or the alternative that was rejected**. It does not
restate the signature. Compare:

```kotlin
/** Returns the current user id. */                                   // says nothing the name did not
```

```kotlin
/**
 * Who is calling. Called only inside `authenticate`, where a request without a principal never
 * arrives. A missing principal here therefore means an unprotected route — a wiring mistake — and
 * it must be loud. The previous version returned an empty string, which would have gone into
 * storage as the owner.
 */
```

Other shapes worth keeping:

- **Header comments on build files** say what the module is and what is deliberately *not* in it.
- **A comment on a DI line that looks wrong** (`single<Settings> { Settings() }` as a separate
  definition; `single<T> { ... }` instead of `singleOf`) says which check would break otherwise,
  or the next reader "simplifies" it back.
- **`@Suppress` carries a reason string** next to the rule id, and the reason is about this call
  site, not about the rule.
- **A temporary allowance has a removal condition** in its KDoc (a compatibility branch that is
  removed a month after rollout, and which branch to delete).
- Prose in `docs/` that states a fact about code carries the path to the code; a copy of the code
  rots, a path does not.

## What must not enter an open repository

Names of private projects and their internals; local IP addresses, home paths, internal domains;
credentials of any kind, including the "default" secret in a config file; and **observations
about one workstation** (a Gradle quirk that does not reproduce in CI). The test: *does this
reproduce on a clean machine?* If not, it is a note for your own memory, not for `CLAUDE.md`.
Pull-request titles and bodies count as the repository.

## Review checklist

Run the greps in [references/review-greps.md](references/review-greps.md); each maps to a rule
above. Then read for:

- [ ] a new `expect` without a platform API behind it
- [ ] an interface with one implementation and no test that fakes it
- [ ] a base state, a base view model, or a generic CRUD repository over a marker interface
- [ ] a `Flow<Result<T>>`; a `UseCase` base with a rethrowing `get()`; a hardcoded dispatcher in a base
- [ ] `state.value =` in more than one place of a view model; a `success` or `loggedOut` flag in a state
- [ ] a route reading the tenant from the body, or a repository method without the tenant in its signature
- [ ] a `when` over use-case errors that swallows unknown ones into a `400`; a match on `error.message`
- [ ] a role compared by `ordinal`; a refusal log that prints a token
- [ ] an `expect` for something a test would want to substitute
- [ ] a string path or a copied DTO outside the contract module
- [ ] `org.junit` imports; a mocking library in a shared suite
- [ ] `runCatching` in suspend code; `catch (e: Exception)` without a cancellation rethrow above
- [ ] a default parameter on a constructor registered with `singleOf` / `factoryOf`
- [ ] a generic bound to DI without a name
- [ ] `value +=` on a shared flow; a `List` in a UiState
- [ ] a KDoc that restates the name; a `@Suppress` without a reason
- [ ] a comma in a backticked test name; non-English text in code
- [ ] anything that describes your machine rather than the product
