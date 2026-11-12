---
name: kmp-shared-contract
description: "Design or change the wire contract between a Ktor server and Kotlin clients: @Resource path classes and DTOs in a shared module, money and date serializers, what stays out of the contract, status codes, an error envelope with codes, wire Json settings, the checklist for changing a route or a field. Use for 'add/rename an endpoint's path or DTO', 'add a field to the model', 'client and server disagree', the shared/contract/api module."
---

# The shared wire contract

One module, compiled into every client target and every server build, holds **the description of
what the two sides exchange**. Its property, and the reason it exists: you cannot rename a path or
a field on one side and forget the other, because there is only one side. The reference
implementation is `:shared` in [mani](https://github.com/youndie/mani).

## Step 0. Check the project first

1. Find the contract module (`shared`, `core`, `api`, `contract`). Read one existing resource
   with its DTOs and copy that style. **The project's conventions win** over this file.
2. Check that the client uses `ktor-client-resources` and the server `ktor-server-resources`. If
   one side still builds paths from strings, do not fix everything at once: introduce the
   `@Resource` on the route you are touching and leave the rest for a separate change.
3. If there is no contract module at all, create it as described in `kmp-project-structure`,
   with every target the product has.

Related skills: the server side of a route is `ktor-server-feature`, the client side is
`compose-client-feature`, checking both is `kmp-testing`.

## One class, two uses

```kotlin
// :shared — the only place a path is written
@Resource("/transactions")
class TransactionResource {
    @Resource("/{id}")
    class ById(val parent: TransactionResource = TransactionResource(), val id: String)
}
```

```kotlin
// server: the class parses the path
patch<TransactionResource.ById> { path ->
    val new = call.receive<Transaction>().copy(id = path.id)
    ...
}
```

```kotlin
// client: the same class builds the URL
httpClient.patch(TransactionResource.ById(id = params.id)) { setBody(params) }
```

A string path on the second side is a copy of the contract that rots silently: a rename compiles
and fails at runtime, for a user. With a shared `@Resource` it fails at compile time, and query
parameters stop being assembled by hand. Sub-resources nest with a `parent` parameter that has a
default, so `AuthResource.Refresh()` is enough on the client. Query parameters are constructor
properties with defaults:

```kotlin
@Resource("/orders")
class OrdersResource(val page: Int? = null, val pageSize: Int? = null, val search: String? = null) {
    @Resource("{id}")
    class ById(val parent: OrdersResource = OrdersResource(), val id: String)
}
// server: get<OrdersResource> { r -> r.page ?: 0 }   client: httpClient.get(OrdersResource(page = 2))
```

The same argument applies to DTOs: **give a path, not a copy**. A local "copy of the response so I
do not have to touch the shared module" is not a compromise, it is a future bug.

## What belongs in the contract

| In | Why |
|---|---|
| `@Resource` classes, one file per subject area | the path exists once |
| request and response DTOs, `@Serializable data class` | the shape exists once |
| enums that travel on the wire (`Transaction.Period`) | both sides switch on them |
| serializers for wire types (money as a decimal string) | both sides must agree byte for byte |
| pure functions **both** sides need (the balance simulation in the reference) | the only place where both get the same answer |

## What stays out, and where it goes instead

| Out | Why | Where |
|---|---|---|
| the server's address | a server has no use for its own address; a module called the contract should be one | the client (`Constants.kt` plus a runtime override) |
| the record owner's id (`userId`) | ownership is a server-side notion; the client never sees it | a server-side `Record` type next to the port |
| validation and business rules | the form is a convenience; the boundary is the server | a `xProblem()` function and typed use-case errors in the server's feature package |
| repository interfaces, use cases, exceptions | the contract describes the wire, not how a side is layered; otherwise the client depends on the server's layering | each side's own feature package |
| UI state, formatting | presentation | the client |
| the storage document shape | the database is a third party to the contract | each server build's `data/` |

On the client the contract class is the **DTO**. A small app may use it as its domain model
and say so; a larger one maps it into a domain model at the data layer (DTO → entity → domain),
so an API rename does not ripple through every screen, and so ids and money can be typed
(`value class`, a `Money` type) even though the wire carries strings. A client concern (a marker
interface such as `WithId` so a generic repository can find the id) does **not** go into the
contract: it is a client-side abstraction leaking into the shared module.

The `Record` split is worth spelling out. The reference has three shapes of one entity:
`Transaction` (wire, in `:shared`), `TransactionRecord` (server-common: adds `userId` and
`categoryId`), and `TransactionDb` (one per storage implementation, with the driver's types).
Mapping happens at each edge, and none of the three leaks into the others.

## Model conventions

- `id: String`, issued by the server. The client sends `""` on create; the server ignores the
  body's id on update (see the status conventions below).
- **Money is a decimal, serialised as a string.** `typealias BigDecimalSerializable =
  @Serializable(with = BigDecimalSerializer::class) BigDecimal` keeps the annotation in one
  place. A `Double` on the wire loses cents; a JSON number is parsed as a double by half the
  clients in the world. The storage side has its own serializer (`decimal128` in BSON): the wire
  format and the storage format are different decisions, and the contract owns only the first.
- **Dates are `kotlinx.datetime.LocalDate`**, serialised as ISO strings. Instants only where a
  moment in time is meant.
- **Defaults on new fields** (`val category: Category = Category.default`), so an older client
  keeps parsing a newer server's answer and vice versa. The client's `Json` sets
  `ignoreUnknownKeys = true`; the server's `Json` does **not** set `isLenient`, because a server
  that guesses what an unquoted body meant serves only whoever bypasses the real clients.
- **The wire `Json` is configured once per side and the settings are a contract decision.**
  Server: `encodeDefaults = true` (kotlinx does not write defaulted fields, and a typed client
  where the field is mandatory fails to parse), `explicitNulls = false` or `true` chosen once
  (absent vs `null` is a different document for a generated client), `ignoreUnknownKeys = true`,
  and **no `isLenient`**. Client: `ignoreUnknownKeys = true`. Two entry points with different
  settings are two wire formats, and nothing but the client notices.
- **A sentinel in the contract is a product decision.** `Category.default = Category("0",
  "Default")` is what the server substitutes when a record's category no longer exists. Write
  such a decision down where the sentinel is declared; a reader otherwise takes it for a
  placeholder.

## Status-code conventions

This table is the one place the decision lives; the server skill links here. Keep whatever the
project already does, but make sure each answer below has *a* decision.

| Situation | Answer | Why |
|---|---|---|
| created | `201` with the created entity, ids and substitutions filled in | the client replaces its optimistic copy with the server's |
| a validation rule refused the input | `400` with a **human-readable text that says what to fix** | the form shows the text as is |
| the body or a path parameter did not parse | `400 Malformed request`, one generic text | details would describe the server's internals |
| no token, wrong kind of token, expired | `401` with one fixed text | the client's refresh logic keys on the code, not the text |
| not yours **or** does not exist | one status for both, everywhere in the service: `404` when the tenant is in every filter and the two are indistinguishable anyway; `403` in the reference, which checks ownership explicitly | different answers would say which ids are taken |
| the refresh token was refused | `401`: the session is over; **any other failure leaves the session alone** | a `500` on the server does not end a session |
| created but not readable by its own id | `500` | a storage failure, not a client error; it is reported |

**The id of the record being changed comes from the path, never from the body.** The reverse
was a real hole: ownership checked against the path, the write addressed by the body, and a
stranger's record rewritten with a `200`.

## An error is a code, and the status is its fallback

A text under a status is enough while a client only ever *shows* a refusal. The moment it has to
*act* on one — mark the field, decide whether to recover, tell apart two refusals that share a
status — it needs something to switch on, and that is a contract type:

```kotlin
@Serializable enum class ErrorCode { @SerialName("validation_failed") ValidationFailed, @SerialName("guest_not_found") GuestNotFound, /* … */ }

@Serializable data class ErrorBody(val code: ErrorCode, val message: String, val field: String? = null, val fields: List<FieldError> = emptyList())
@Serializable data class FieldError(val field: String, val code: ErrorCode, val message: String)
```

- **The client tells cases apart by `code`, never by the message and never by the status alone.**
  One storefront answered `401` both for "no credentials where a customer is needed" and for "a
  guest id this server never issued". The client recovered from every `401` by asking for a new
  guest, so a guest who opened a customer's page by its address lost their cart — under a prompt
  saying the cart would come along (haul B-115). It now replaces its guest on `guest_not_found` only.
- **One function maps a code to its status**, an exhaustive `when` with no `else`, and every
  refusal goes through one `respondError`: a new code does not compile until somebody has decided
  its status. With codes carrying the meaning, the statuses can be finer than the table above
  without a client depending on them — `409` for a conflict with the current state (out of stock,
  a key reused), `422` for a well-formed request a rule refuses (a promo expired).
- **`message` is still written for a person and still says what to fix**; `field` and `fields`
  say where, so a refused form marks every field in one round trip.
- **Keep "try again later" and "this is a bug" apart**: `unavailable` (`503`, a dependency is
  down; not reported, the outage is said once by whoever met it) and `internal` (`500`, reported,
  nothing of the exception in the body).
- **The status has to be right on its own, because the body is not always an `ErrorBody`.** A
  proxy answers with its own page; and an enum does not decode a name it has never seen, so a
  client built before a code existed fails to parse the body. The decode is wrapped, its failure
  is not an error of its own, and the client falls back to the status. A client that ships apart
  from its server — a store build, not a bundle the server serves — will meet codes it does not know.

The server half — an error that carries its code, the single mapping, and what the catch-all
reports — is in
[`ktor-server-feature`](../ktor-server-feature/examples/use-cases-and-errors.md#when-the-contract-carries-error-codes).

## Health as part of the contract

Two resources, two questions (`/health` and `/health/ready`; the paths are the contract's, the
server skill only links here):

- `GET /health` answers **which build is running**: `Health(build, version, uptimeSeconds)`. No
  authentication, no dependencies touched: a liveness probe must not depend on the database, or
  a database outage restarts every replica and fixes nothing.
- `GET /health/ready` answers **whether the server can serve**: one cheap round trip to storage,
  `503` if it fails. A pod without a database should stop receiving traffic, not restart.

The client can show the `/health` answer (the reference welcome screen prints
`ktor · kotlin/native · 1.4.2`): the claim "the native build is what you are talking to" is then a
live fact rather than a README sentence.

## When the server draws the screens

In a server-driven client (every screen a component tree the server builds; kompot is the toolkit
here) the URL-building half of "one class, two uses" has no user: the client does not build an
address, it follows the one an action in the tree carries. The paths are then **the server's
strings**, written once in an object per feature beside its routing (`CartPaths.LINE`,
`CartPaths.line(skuId)`) and handed out inside the tree. What the contract module still holds is
what both sides still share: the components on the wire, the command bodies, `ErrorCode`.

Two things follow. The greps in the checklist below read the other way round: string routes on
the server are expected, and what must stay empty is a path literal in the **client**. And the
few addresses a client needs *before* it has a tree — the screen prefix, the header, the session
endpoints — are the old rule again: they are shared, so they belong in the contract module. The
reference storefront spells that handful on each side and relies on its end-to-end walks to keep
them equal, which is the copy this skill warns about, however short. Building the trees
themselves is `kompot-layout`, in kompot's own repository.

## Checklist: changing a route

1. Change the `@Resource` class or the DTO in the contract module. Add defaults to new fields.
2. Build every consumer: both server builds and the client. The compiler now lists every call site.
3. Update the server route (`ktor-server-feature`) and the client data source
   (`compose-client-feature`).
4. If the change reaches storage, update **every** storage implementation and the raw-document
   test in each build (`kmp-testing`, "storage is tested against a real database").
5. If the repository keeps an API reference (`docs/api/endpoint-*.md`), update the route table,
   the status codes and the auth tier in the same change.
6. Run the grep that guards the whole thing: no route registered by a string path on the
   server, no request built from a string path on the client. First confirm the grep finds the
   typed calls (positive control), then that the string forms are absent:

```bash
grep -rnE --include='*.kt' '\b(get|post|put|patch|delete)<' server*/src | head -3     # typed routes exist
grep -rnE --include='*.kt' '\b(get|post|put|patch|delete|route)\("/' server*/src        # must be empty (health excepted)
grep -rnE --include='*.kt' '\.(get|post|put|patch|delete)\("' client*/src composeApp/src  # must be empty
```

7. Do not delete a resource because nobody calls it yet without checking the handler: a resource
   declared in the contract with no handler on the server is a promise the server does not keep.
   The reference had one (`/users/current`); the fix is either a handler or a deletion, not silence.

## Checklist: adding a field to a model

1. Default value in the DTO.
2. Server: the validation function (`Rules.kt`) if the field has constraints; the `Record` type;
   the mapping in each storage implementation; the document class of each build.
3. Client: the UI state and the form, if the user edits it.
4. A test that reads the **raw** stored document in each build if the field's storage type
   matters (money, ids, dates): a test that goes through `find` passes on a diverged format too,
   because it writes and reads the same wrong way.

## Dependencies of the contract module

`api` for every library whose types appear in public signatures: the decimal library, the date
library, `ktor-resources`, `kotlinx-serialization`. Consumers otherwise declare their own copies
and drift apart on versions. Nothing else: no HTTP client, no server, no DI, no UI.

The three-way example (resource, server route, client data source) is in
[examples/resource-and-both-sides.md](examples/resource-and-both-sides.md).
