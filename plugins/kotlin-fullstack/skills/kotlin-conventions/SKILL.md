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
| storage implementation | `<Technology><Noun>Repository` | `MongoUserRepository`, `MongknUserRepository` | two builds means two implementations; `Impl` would not say which |
| single-method port | `fun interface <Question>` | `StorageHealth { isReachable() }` | the only common thing between two drivers is the question |
| routing | `fun Routing.<subject>Routing()` in `<Subject>Routing.kt` | `transactionRouting()` | one function per subject, assembled in one place |
| validation | `fun <subject>Problem(x): String?` in `Rules.kt` | `transactionProblem`, `credentialsProblem` | returns the problem or null; no exception vocabulary |
| service (server) | `<Subject>Service`, ordinary class in common | `AuthService`, `DemoService` | orchestration over ports |
| Koin module | `val <feature>Module`, in `module.kt`; storage: `fun <technology>StorageModule(config)` | `authModule`, `mongoStorageModule` | the file name says "this feature's wiring" |
| client data source | `<Noun>NetworkDataSource` | `TransactionsNetworkDataSource` | the transport is in the name |
| client repository | interface `<Noun>Repository`, impl `<Noun>RepositoryImpl` | only one implementation on the client, so `Impl` is honest |
| cache | `<Noun>Cache` | `TransactionsCache` | |
| use case | `<Verb><Noun>UseCase`; observing flows `Observe<Noun>UseCase` | `AddTransactionUseCase`, `ObserveCategoriesUseCase` | one operation per class; the verb is the operation |
| view model | `<Screen>ViewModel`; shared base `Base<Screen>ViewModel` | `TransactionsViewModel`, `BaseTransactionViewModel` | |
| screen state | `<Screen>UiState`, nested states `<Part>UiState` | `TransactionListUiState`, `ServerUnreachableUiState` | |
| user intent | `<Screen>Action` sealed interface; handlers `on<Event>` | `TransactionAction.AmountChanged`, `onDeleteClicked()` | handlers are named after what the person did, not what the code does |
| stateful screen | `<Screen>Component` | `MainComponent` | owns the view model |
| stateless screen | `<Screen>Content` (or `<Screen>ComponentImpl` when it is the same tree) | `MainContent`, `AuthComponentImpl` | state in, callbacks out; what tests render |
| navigation | `<App>Screen` enum for plain routes, `@Serializable class <Noun>Route(val id)` for routes with arguments | `ManiScreen.Main`, `TransactionRoute` | |
| exception | `<Cause>Exception` extending the layer's base | `ServerException(status)`, `UserNotFoundException` | |
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

**A base class is earned by two concrete classes sharing behaviour**, and the shared behaviour
must be the kind that goes wrong when copied: `BaseFlowRepository` exists because the
optimistic-update-with-rollback dance is easy to get subtly wrong twice. A base class for
"structure" alone is a template, not an abstraction.

**A generic type at a DI boundary needs a name.** `DataSource<Category>` and
`DataSource<Transaction>` are one key to any container that erases generics; bind by name and
keep a test that the unnamed binding does not return.

**Three shapes of one entity are not duplication.** Wire (`Transaction`), server-side record
(`TransactionRecord`), stored document (`TransactionDb`): each edge maps, and none leaks across.
Collapsing them puts `userId` into the contract or the driver's `ObjectId` into the client.

**A sentinel value is a decision, not a placeholder.** `Category.default` declared in the
contract with a KDoc saying when the server substitutes it. Undocumented, it reads as a stub and
gets "cleaned up".

**Validation is a pure function that returns the problem.** `fun xProblem(x): String?` — no
exception hierarchy to maintain, trivially testable at each boundary, and the returned text is
what the user sees, so it says what to fix.

**Configuration is a data class built by one `fromEnv()`**, nested per concern, so a test
constructs it in code. A decision about a value is a named function of that value.

## `Result`, exceptions and cancellation

- `Result` at the **use-case boundary** on the client: the view model folds it into state. On the
  server, routes call repositories and services directly and let `StatusPages` map exceptions;
  there is no use-case layer in the reference server, and a small server does not need one.
- Never nest `Result` in `Result`; unwrap with `.getOrThrow()` where the caller expects
  exceptions.
- `suspendRunCatching` everywhere a `runCatching` would sit in suspend code: plain `runCatching`
  swallows `CancellationException`, and a cancelled coroutine then surfaces as a network error on
  screen or as a `500` on the server. Every `catch (e: Exception)` in suspend code is preceded by
  `catch (e: CancellationException) { throw e }`.
- Exceptions carry what a person needs to tell causes apart: `ServerException.status` is
  nullable because "the server said 503" and "the server was never reached" are different.

## Events versus state

State is what a screen shows now; an event is news of one moment. Session expiry, logout, "saved,
close the screen" are events. Model them as a `SharedFlow` with `replay = 0` (or a dedicated
`StateFlow` the consumer resets) — **never** as a field inside a state that is rebuilt by a
subscription, because the next emission overwrites it, and never as a subscription that rebuilds
navigation, because a rebuilt graph resets to its start destination. Both were real defects.

## Immutability and concurrency

- `ImmutableList` / `ImmutableMap` / `ImmutableSet` in every UiState: Compose skips recomposition
  only for stable types.
- Shared mutable flows change through `MutableStateFlow.update { }`; `value += x` is three steps
  and loses concurrent writes.
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
- [ ] a string path or a copied DTO outside the contract module
- [ ] `org.junit` imports; a mocking library in a shared suite
- [ ] `runCatching` in suspend code; `catch (e: Exception)` without a cancellation rethrow above
- [ ] a default parameter on a constructor registered with `singleOf` / `factoryOf`
- [ ] a generic bound to DI without a name
- [ ] `value +=` on a shared flow; a `List` in a UiState
- [ ] a KDoc that restates the name; a `@Suppress` without a reason
- [ ] a comma in a backticked test name; non-English text in code
- [ ] anything that describes your machine rather than the product
