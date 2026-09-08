# Technical brief: <product or feature name>

| | |
|---|---|
| Date | <YYYY-MM-DD> |
| Repository | <new — `<name>`> / <existing — `<url>`, branch `feature/<kebab>`> |
| Platforms | <android, ios, desktop, web; phone / tablet> |
| Stack | <Kotlin Multiplatform: `shared` contract, `server` (JVM + native), `composeApp`> — *decided*, see §8 |
| Documentation | `docs/` inside the repository, docs-bootstrap format |
| Status of this document | input for docs-bootstrap; delete after the documentation tree exists |

Sections 3–7 map onto the documentation layers one to one (§3 → `research/`, §4 → `features/`,
§5 → `screens/`, §6 → `api/`, §7 → `services/`); §9 becomes the backlog, one file per item.

## 1. Problem and audience

Two paragraphs at most: what the person cannot do today, who they are, what changes for them.
No implementation words.

## 2. Scope

**In the first version:**

- <observable capability>

**Out, on purpose** (the user's words, so nobody re-opens it by accident):

- <capability> — <why not now>

## 3. Domain

| Entity | Identified by | Owned by / tenant | Notes |
|---|---|---|---|
| `Account` | server id | `Client` | <closed set of kinds: …> |

Tenancy: <none / one tenant per user / organisations with roles `owner`, `member`, …>. This
decides every repository signature and every tier column below; state it once here.

## 4. Features

One block per feature. The scenarios are *target* — intended behaviour, to be verified against
the code before the feature document is merged as `active`.

### feature-<kebab>: <title>

**Overview.** <what the user gets and why, two or three sentences>

**Business rules** (each one checkable):

- <rule>

**Screens:** <screen ids or "none">. **Endpoints:** <endpoint ids or "none">.

**Scenarios (target):**

- *<happy path>* — Given <…>, when <…>, then <…>.
- *<the interesting failure>* — Given <…>, when <…>, then the system returns `<status>` with `<error>`.

## 5. Screens

The single source of the screen and state names: the screen documents' section 1, the design
brief's artboards, the screenshot fixtures and the reference PNGs are all copied from here.

### screen-<kebab>: <title> (`<PascalName>`)

| | |
|---|---|
| Entry | <route / tab / deep link> |
| Parent feature | feature-<kebab> |
| Calls | endpoint-<kebab>, … |
| Sizes | <390×844 phone; 1440×900 desktop if it ships> |

| State | Artboard | What is visible |
|---|---|---|
| Loading | `<PascalName>_Loading` | <…> |
| Empty | `<PascalName>_Empty` | <…> |
| Content | `<PascalName>_Content` | <…> |
| Error | `<PascalName>_Error` | <…> |
| <own state> | `<PascalName>_<State>` | <…> |

Dark variants: <none / every state / listed states>.

**Actions** (transitions, not states): <tap row → screen-…; pull to refresh; …>.

## 6. API

Per feature, every route including internal ones, with the tier that may call it.

### endpoint-<kebab>: <group>

| Method | Path | Tier | Request | Response | Errors |
|---|---|---|---|---|---|
| `GET` | `/api/v1/accounts` | end user | — | list of `AccountDto` | `401` |
| `POST` | `/api/v1/accounts` | `owner` | `CreateAccountRequest` | `AccountDto` | `400` validation, `403` role, `409` duplicate name |

Wire conventions (once, for the whole product): <json settings; "not yours / does not exist" →
`404` with the tenant filter; error body shape>. These are the decisions `kmp-shared-contract`
records; a brief that leaves them open leaves them to be decided per endpoint.

## 7. Modules and services

| Module | Role | Stack | Storage / config | New or existing |
|---|---|---|---|---|
| `shared` | contract: DTOs, routes, error codes | KMP (jvm, native, android, ios, wasm) | — | new |
| `server` | HTTP + use cases, compiled to JVM and Linux native | Ktor, Koin | <db>, env: `<VAR>`… | new |
| `composeApp` | the client for every platform | Compose Multiplatform, Koin, navigation | local db: <yes/no> | new |

Deploy and environments in one paragraph, if known; otherwise "not decided" — never a guess
dressed as a plan.

## 8. Decisions and hypotheses

Every claim about a library, a version, a platform limit or an existing system, with where it
was verified — or the word *hypothesis*.

| Decision / claim | Why | Verified against / *hypothesis* |
|---|---|---|
| Kotlin <x.y>, Compose Multiplatform <x.y> | the reference project's line | Maven Central listing, <date> |
| <db> | <reason> | *hypothesis* — check driver support on Kotlin/Native before §9 item 2 |
| Bundled font: <family> | goldens and design references must share a family | Google Fonts page, licence <OFL> |

## 9. Backlog seeds

Ordered by dependency: contract producers first, consumers after. Each becomes one backlog
item; the acceptance criterion is an observable result.

| # | Title | Size | Feature | Blocked by | Acceptance |
|---|---|---|---|---|---|
| 1 | contract: `AccountDto`, routes, error codes | S | feature-<kebab> | — | `shared` publishes; both builds of `server` compile against it |
| 2 | server: accounts use cases and routes | M | feature-<kebab> | 1 | scenarios of §4 pass on the JVM and native builds |
| 3 | client: accounts list screen, states per §5 | M | feature-<kebab> | 1, canvas | `viddikDesignParity` within tolerance for every `Accounts_*` artboard |

## 10. Open questions

- [ ] <question, and who answers it>
