---
name: kmp-project-structure
description: "Lay out or restructure a Kotlin Multiplatform full-stack project: which Gradle modules to create (a shared wire contract, a Compose Multiplatform client, a server-common module and one module per server build), which targets each module takes, what belongs in commonMain versus a platform source set, how feature packages are shaped across modules, and where configuration and the product version live. Use this whenever the user starts a new KMP project, adds a module or a target, asks where a class or file belongs, wants to split or merge modules, or asks about package structure — even when they only say 'set up the project' or 'organise the code'."
---

# Kotlin Multiplatform project structure

The shape below is the one that works when the same code has to run in several places at once:
a Compose client on Android, iOS, desktop and the browser; a Ktor server compiled both to the
JVM and to a native Linux binary; and one contract shared by all of them. The reference
implementation is [mani](https://github.com/youndie/mani-kotlin-fullstack). Where a rule is
specific to that product, this file says so; everything else transfers.

## Step 0. Check the project first

This skill is generic and does not know the repository in front of you.

1. Read `settings.gradle.kts`, the root `build.gradle.kts`, `gradle/libs.versions.toml` and
   `CLAUDE.md` / `README.md`. If modules and conventions already exist, **the project's
   conventions win** over anything written here. Extend the existing shape; do not reorganise
   working code without being asked.
2. Find the feature **closest to what you are adding** in each module and copy its layout. A
   living project rarely agrees with itself (the reference has full `data / domain / ui`
   features next to domain-only ones with no screen); pick the shape that fits the task, not
   the newest file.
3. Only when there is nothing to copy, use the layout below as is.
4. If the repository keeps documentation with a coverage map checked in CI, a new module or
   screen needs its document and its line in the map in the same change.

Related skills: the contents of the contract module are in `kmp-shared-contract`; a server
feature inside an existing server is `ktor-server-feature`; a client screen is
`compose-client-feature`; tests are `kmp-testing`; naming is `kotlin-conventions`.

## The module map

| Module | What it is | Targets |
|---|---|---|
| `:shared` | the wire contract and nothing else: `@Resource` classes, DTOs, serializers, pure functions both sides need | every target the product has: android, ios, jvm, wasmJs, linuxX64 |
| `:composeApp` | the whole interface, one body of code | android, ios, desktop (jvm), wasmJs |
| `:server-common` | the whole server **except** the calls into the database: routes, validation, auth, config, the DI graph, the storage **ports** | jvm, linuxX64 |
| `:server` | the JVM build: `main`, storage implementations on the JVM driver, image packaging | jvm |
| `:server-native` | the native build: `main`, storage implementations on a native driver, its own Dockerfile | linuxX64 |
| `:androidApp`, `:iosApp` | thin launchers with no logic; they call `App()` and nothing else | |

Why each boundary exists:

- **`:shared` is a contract, so it must be one.** Anything a server has no use for (its own
  address) or a client has no use for (the record owner's id) is not a contract and goes
  elsewhere. See `kmp-shared-contract`.
- **The server is compiled twice from one source, not written twice.** Only code with two
  implementations can diverge; confining the second implementation to the storage module confines
  the risk to one module. The JVM build also stays the one that compiles on macOS, so a Mac does
  not need a Linux machine for every run.
- **`:server-common` has no `main` and builds no image.** The Ktor Gradle plugin, jib and
  `application` work only with `kotlinJvm` and do not apply to a KMP module; the native build
  needs its own Dockerfile anyway. Each build module owns entry point, storage module and packaging.
- **Launchers carry nothing.** `App(platformModules = ...)` is the whole contract between a
  launcher and the app. Android passes its `Context` in through a Koin module; desktop and wasm
  each call `App()` from their own `main`.

A single-target project (JVM server only, Android only) keeps the same package shape inside fewer
modules; the boundaries above are worth drawing the day a second target appears, not before.

**A server that ships as a library** (an identity provider, a platform component other services
embed) cuts further, and the cut follows the same rule, "a module per thing that can vary":

| Module | What it is |
|---|---|
| `:core` | domain: models, the storage **ports** (`port/`), `TransactionManager`, use cases by feature, the DI modules that bind them; no driver, no HTTP |
| `:crypto`, `:shared-*` | pure libraries the core depends on, and the contracts consumers import |
| `:storage-<driver>-core`, `:storage-<driver>-<db>` | the repositories written against one driver, and one thin module per database bringing its driver and its schema; a native binary cannot link two drivers |
| `:server` | the Ktor surface: routes, plugins, the two engines; it knows `:core` and nothing about drivers |
| `:server-boot` | the composition root function (`runService(storage = …, authMethods = …)`) and the environment reading |
| `:auth-<method>` | optional capabilities as modules: present on the classpath means available, absent means impossible |
| `:distribution-*` | one `Main.kt` and one dependency list each; the dependency list **is** the feature set |
| `:cli`, `:client` | consumers of the shared contracts, built in the same repository so they cannot drift |

The property this buys: a capability that is not in the distribution's dependency list cannot be
switched on by any configuration, because the code is not in the binary.

## The one rule that shapes the source sets

**Everything that is not bound to a platform API lives in `commonMain`.** Every `expect/actual`
pair you add is two implementations that will diverge silently: the compiler checks the signature
and never the behaviour. A token signed by one implementation and refused by the other shows up on
the day of deployment, not at build time.

Count the pairs and be able to justify each. The reference product has exactly these:

| `expect` | Why it cannot be common |
|---|---|
| `readEnv(name)` on the server | `System.getenv` is JVM-only, `getenv` is POSIX |
| `serverBuildKind()` on the server | the one thing the two builds are *supposed* to answer differently (`"jvm"` / `"kotlin/native"`) |
| `TokenStorageImpl` + `authModulePlatform` on the client | every platform has its own secret store; the browser has `localStorage` |
| `platformServerConfig()` on the client | the browser reads the server address from the page origin; phones cannot |
| the entry point (`main.kt`, `MainViewController`, `MainActivity`) | each platform starts differently |

The test for a candidate pair: *if the two actuals drift apart, who notices and when?* If the
answer is "a user, later", write one common implementation instead. Token signing, password
hashing, JWT parsing, validation, routing and configuration are all common in the reference
product, on top of libraries that publish native artefacts (`cryptography-kotlin` with the
`-prebuilt` OpenSSL provider, `kotlinx-datetime`, `kotlinx-serialization`).

The price of the rule: a library with no Kotlin/Native artefact is evicted from the common source
set. That is how `ktor-server-auth-jwt`, `ktor-server-compression`, `CallLogging`, HOCON
configuration and Koin's slf4j logger left the reference server. Check the artefact's targets
before depending on it from `commonMain`; a `-jvm`-suffixed coordinate in a KMP module is the
usual sign that somebody did not.

## Feature-first packages, the same root everywhere

Every module uses **the same root package** (`io.github.youndie.mani` in the reference). A
feature then has the same directory in every module it touches, and one `grep` for
`feature/transaction` finds the contract, the routes, both storage implementations and the
screens. A module-specific root (`...mani.server`, `...mani.client`) buys nothing and breaks that.

```
shared/src/commonMain/kotlin/<root>/
  feature/<name>/          <Name>Resource.kt, DTOs, enums
  utilz/                   serializers, suspendRunCatching
  today.kt                 pure functions both sides need

server-common/src/commonMain/kotlin/<root>/
  ManiApp.kt               coreModule(), configurePlugins(), configureAuth(), apiRouting()
  config/                  Config.fromEnv(), expect readEnv
  security/                token service, bearer provider, encoding helpers
  feature/<name>/          <Name>Routing.kt, Rules.kt, data/<Name>Repository.kt (the port)
server/src/main/kotlin/<root>/
  Application.kt           main + module()
  MongoStorageModule.kt    the ports bound to this build's driver
  feature/<name>/data/     Mongo<Name>Repository.kt, <Name>Db.kt
server-native/src/linuxX64Main/kotlin/<root>/
  Main.kt                  main + appModule(config)
  MongknStorageModule.kt
  db/DbModel.kt            documents + BSON serializers
  feature/<name>/data/     Mongkn<Name>Repository.kt

composeApp/src/commonMain/kotlin/<root>/
  App.kt                   KoinApplication + theme + scaffold
  appModule.kt             the list of feature modules
  navigation/              nav host, screen list, back-arrow rule
  core/                    UseCase / ObservableUseCase, AppError, runNetworkCatching, UiText
  network/                 HttpClient module, session refresh
  components/  theme/      cross-feature UI kit
  feature/<name>/
    domain/                models, repository interface, use cases
    data/                  repository impl, entities/DAO, mappers
    ui/                    UiState, UiAction, UiEvent, view model, mapper, Screen + Content
    module.kt              this feature's Koin module
composeApp/src/<platform>Main/kotlin/<root>/
  network/ServerConfigPlatform.<platform>.kt
  feature/auth/TokenStorageImpl.kt, authModulePlatform.kt
```

**When the client outgrows one module**, the same three layers become three Gradle modules per
feature, and the compiler enforces the dependency rule the packages could only suggest:

```
feature/<name>-domain/   plugin: <company>.kmp-library     depends on: core, other *-domain
feature/<name>-data/     plugin: <company>.module-data     depends on: <name>-domain, core network/database
feature/<name>-ui/       plugin: <company>.module-ui       depends on: <name>-domain, uikit; NEVER on *-data
app/                     the only module that sees every layer; wires DI, hosts navigation
core/<concern>/          usecase, network, database, uikit, di — one module per concern
build-logic/             includeBuild with the convention plugins the three layers apply
```

A `ui` module that depends on a `data` module is the wiring error the split exists to make
impossible. Cut modules when a feature is touched by more than one person or when build times
say so, not on day one.

What is **not** a feature and stays at the root (or in `core:*` modules): security,
configuration, navigation, theme, the network client, the base use-case types, the error
hierarchy. The test: a package at the root is one that several features import and none owns.

## Build conventions that keep the modules honest

- **One version catalog** (`gradle/libs.versions.toml`); every module reads it. Comments in the
  catalog explain the non-obvious pins (why a coordinate has no `-jvm` suffix, why a test-only
  reference library is there).
- **`api` for types that appear in the contract's public signatures.** If `Transaction.amount`
  is a `BigDecimal` from a library, `:shared` declares that library with `api`, or every consumer
  must declare it too and the versions drift apart silently.
- **Declare the crypto provider in every build module**, not only where it arrives
  transitively. A missing provider does not fail the build; it fails the first login.
- **One product version.** `mani.version` in `gradle.properties` is the only number: a Gradle task
  generates a `const val` from it into `:server-common`, the `/health` route reports it, the image
  tag is `<version>.<build number>`, and the desktop package uses it. Two version lines end with
  an image whose `/health` names the previous release.
- **Pin the generated resources package** (`compose.resources { packageOfResClass = ... }`). By
  default it is derived from the project group, and setting a group later renames the package
  under a hundred imports.
- **Vendored code is excluded from the formatter by path**, in the module where it lives, with the
  reason next to the exclusion.
- **`.editorconfig` records every deviation with a reason** (why the filename rule is off, why
  Composable names are capitalised). A rule without a reason gets "fixed" by the next reader.
- **Kotlin/Native release tests are a separate test run** (`testRuns.create("release")`); see
  `kmp-testing` for why that run is mandatory.

## Configuration

Both server builds read **the environment**, through one `Config.fromEnv()` in `commonMain` with
`readEnv` as the only `expect`. HOCON is read by JVM-only Ktor code, so a second configuration
mechanism would be the first thing to diverge. Conventions worth copying:

- a `data class` per concern (`MongoConfig`, `JWTConfig`) nested in one `Config`, so tests build
  a config in code rather than by setting variables;
- a decision that depends on a value (what to do when `JWT_SECRET` is unset) lives in a small
  named function that takes the value as a parameter, so a test checks the decision without
  touching the environment of the machine it runs on;
- an unset secret is **a random per-process value plus a line on stdout**, not an insecure literal
  default and not a refusal to start: the instance keeps working locally, the price (a restart
  logs everyone out) is visible, and production sets the variable;
- credentials are URL-escaped before they go into a connection string; a password with `@` or
  `:` otherwise sends the connection somewhere else.

On the client the server address is resolved at runtime where the platform can answer (the
browser: the page's origin; desktop: an environment variable) and falls back to a compiled-in
default kept in the client, not in the contract.

## What not to do

- **Do not introduce a second product version**, a second configuration source, or a second
  implementation of anything that is not a platform API.
- **Do not put the server address, the record owner, or business rules into `:shared`.**
- **Do not let a build module depend on another build module.** `:server` and `:server-native`
  know `:server-common` and `:shared`; they do not know each other.
- **Do not bump a native-linked system library's version in one place only.** The CI runner,
  the deploy runner and the image base are a pair through the shared library's soname; a mismatch
  surfaces as a missing symbol on the first call, on the deployed instance.
- **Do not describe your own workstation in the repository.** A Gradle quirk that reproduces on
  one machine and not in CI belongs in your notes, not in `CLAUDE.md`.

## Deliverables when you set a project up

1. `settings.gradle.kts` with the module list and repository filters (`content { includeGroup }`
   on any non-central repository, or one unreachable host disables resolution for everything).
2. One `build.gradle.kts` per module with a header comment saying what the module is and what is
   deliberately not in it.
3. `CLAUDE.md` with the module table, the rules that have already been paid for, and the commands
   that run on every pull request.
4. The empty feature directories are **not** created up front; the first feature creates them.

For a fuller tree with the build-file skeletons of each module, read
[references/module-layout.md](references/module-layout.md).
