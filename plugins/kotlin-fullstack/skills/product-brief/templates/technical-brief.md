# Technical brief: <product or feature name>

| | |
|---|---|
| Date | <YYYY-MM-DD> |
| Repository | <new — `<name>`> / <existing — `<url>`, branch `feature/<kebab>`> |
| Platforms | <android, ios, desktop, web; phone / tablet> |
| Stack | <Kotlin Multiplatform: `shared` contract, `server` (JVM + native), `composeApp`> — *decided*, see §8 |
| Documentation | `docs/` inside the repository, docs-bootstrap format |
| Status of this document | a branch artefact under `research/`; deleted before the branch merges |

How the sections become documentation: §8 and §10 are the research document
(`docs/research/research-architecture.md`, the one layer that can exist before the code); §3
feeds the features' business rules; §4 → `features/`, §5 → `screens/`, §6 → `api/`, §7 →
`services/` are drafted in a pull request that stays open and gets its code anchors as the code
lands; §9 becomes the backlog, in whichever of docs-bootstrap's two forms fits its size.

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
decides every repository signature and every role column below; state it once here.

## 4. Features

One block per feature. The scenarios are *target* — intended behaviour, to be verified against
the code before the feature document is merged as `active`.

### feature-<kebab>: <title>

**Overview.** <what the user gets and why, two or three sentences>

**Business rules** (each one checkable):

- <rule>

**Modules:** <module ids from §7>. **Screens:** <screen ids or "none">. **Endpoints:**
<endpoint ids or "none">.

**Scenarios (target):**

- *<happy path>* — Given <…>, when <…>, then <…>.
- *<the interesting failure>* — Given <…>, when <…>, then the system returns `<status>` with `<error>`.

## 5. Screens

The screen and state names are written once, here. The design brief's artboards are copied
from this table; the screen documents' section 1 starts as a copy of it and is re-read from
the real state class before the document goes `active`, so the code is what finally names the
states and this table is what they are held against until then.

### screen-<kebab>: <title> (`<PascalName>`)

| | |
|---|---|
| Platforms | <android, ios, …> |
| Entry | android: <route>; ios: <route>; web: <path> |
| Parent feature | feature-<kebab> |
| Calls | endpoint-<kebab>, … (or "no API") |
| Sizes | <390×844 phone>; <other form factors as answered in the interview, never assumed> |
| Source | filled in by the implementer: the feature directory in the code |

| State | Artboard | What is visible |
|---|---|---|
| Loading | `<PascalName>_Loading` | <…> |
| Empty | `<PascalName>_Empty` | <…> |
| Content | `<PascalName>_Content` | <…> |
| Error | `<PascalName>_Error` | <…> |
| <own state> | `<PascalName>_<State>` | <…> |

Dark variants: <none / every state / listed states> — an artboard `<PascalName>_<State>_Dark`
per listed state; it is the same state, so it is not a row here.

**Actions** (transitions, not states): <tap row → screen-…; pull to refresh; …>.

### 5a. Sample data

The values every artboard, preview, scenario and screenshot fixture shows, so that they all
show the same thing:

| Entity | Values |
|---|---|
| `Client` | <name> |
| `Account` | <two or three rows: names, amounts, currencies> |
| Today | <YYYY-MM-DD, fixed> |

## 6. API

Per feature, every route including internal ones. The tier is who may call it (end user, bot,
service-to-service); the minimum role is checked inside that tier.

### endpoint-<kebab>: <group>

Contract class: `shared: <Resource class>`. Service: `server`.

| Method | Path | Tier | Min role | Request | Response | Errors | In the public schema? |
|---|---|---|---|---|---|---|---|
| `GET` | `/api/v1/accounts` | end user | member | — | list of `AccountDto` | `401` | yes |
| `POST` | `/api/v1/accounts` | end user | owner | `CreateAccountRequest` | `AccountDto` | `400` validation, `403` role, `409` duplicate name | yes |

Wire conventions (once, for the whole product): <json settings; "not yours / does not exist" →
`404` with the tenant filter; error body shape>. These are the decisions `kmp-shared-contract`
records; a brief that leaves them open leaves them to be decided per endpoint.

## 7. Modules and services

| Module | Role | Stack | Storage / config | Depends on | Publishes | New or existing |
|---|---|---|---|---|---|---|
| `shared` | contract: DTOs, routes, error codes | KMP (jvm, native, android, ios, wasm) | — | — | — (a Gradle module of this build; an artifact only when consumed from another repository) | new |
| `server` | HTTP + use cases, compiled to JVM and Linux native | Ktor, Koin | <db>, env: `<VAR>`… | `shared`, <db> | container image | new |
| `composeApp` | the client for every platform | Compose Multiplatform, Koin, navigation | local db: <yes/no> | `shared`, `server` (HTTP) | app binaries | new |

Deploy and environments in one paragraph, if known; otherwise "not decided" — never a guess
dressed as a plan.

## 8. Decisions and hypotheses

Every claim about a library, a version, a platform limit or an existing system, with where it
was verified — or the word *hypothesis*. This table and §10 are the research document.

| Decision / claim | Why | Verified against / *hypothesis* |
|---|---|---|
| Kotlin <x.y>, Compose Multiplatform <x.y> | <the project whose versions this copies, or "latest stable on Maven Central"> | Maven Central listing, <date> |
| <db> | <reason> | *hypothesis* — check driver support on Kotlin/Native before §9 item 2 |
| Bundled font: <family> | goldens and design references must share a family | Google Fonts page, licence <OFL> |
| Screenshot parity: viddik ≥ 0.5.0 (`viddikDesignParity`) | the client items are accepted against the design | <registry listing, date> / *hypothesis* |

## 9. Backlog seeds

Ordered by dependency: whatever others compile against first. Each becomes one backlog item;
the acceptance criterion is an observable result. The stages are the ones `backlog.md` will
list — name them here so the items can carry them.

| Stage id | Stage | What it is |
|---|---|---|
| `stage-1-<kebab>` | <name> | <what is true when it closes> |
| `stage-2-<kebab>` | <name> | <…> |

| # | Title | Priority | Size | Stage | Feature | Blocked by | Acceptance |
|---|---|---|---|---|---|---|---|
| 1 | contract: `AccountDto`, routes, error codes | P1 | S | `stage-1-<kebab>` | feature-<kebab> | — | both `server` builds and `composeApp` compile against `shared` |
| 2 | server: accounts use cases and routes | P1 | M | `stage-1-<kebab>` | feature-<kebab> | 1 | scenarios of §4 pass on the JVM and native builds |
| 3 | design: reference PNGs for `Accounts_*` in `composeApp/src/desktopTest/snapshots/design/` | P1 | S | `stage-1-<kebab>` | feature-<kebab> | — | one PNG per artboard of §5, sizes as in §5 |
| 4 | client: accounts list screen, states per §5 | P1 | M | `stage-1-<kebab>` | feature-<kebab> | 1, 3 | `viddikDesignParity` within tolerance for every `Accounts_*` artboard; goldens recorded |

## 10. Open questions

- [ ] <question, and who answers it>
