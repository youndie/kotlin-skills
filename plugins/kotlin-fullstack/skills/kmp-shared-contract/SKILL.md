---
name: kmp-shared-contract
description: "Design or change the wire contract between a Ktor server and its Kotlin clients: `@Resource` path classes and DTOs declared once in a shared module and used by both sides, serializers for money and dates, what must stay out of the contract, status-code conventions, and the checklist for changing a route or a field without breaking a client or a second server build. Use this whenever the user adds, renames or removes an endpoint, adds a field to a model, asks how the client and the server talk to each other, mentions the shared / contract / api module, or reports that the client and the server disagree about a path or a field."
---

# The shared wire contract

One module, compiled into every client target and every server build, holds **the description of
what the two sides exchange**. Its property, and the reason it exists: you cannot rename a path or
a field on one side and forget the other, because there is only one side. The reference
implementation is `:shared` in [mani](https://github.com/youndie/mani-kotlin-fullstack).

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
default, so `AuthResource.Refresh()` is enough on the client.

The same argument applies to DTOs: **give a path, not a copy**. A local "copy of the response so I
do not have to touch the shared module" is not a compromise, it is a future bug.

## What belongs in the contract

| In | Why |
|---|---|
| `@Resource` classes, one file per subject area | the path exists once |
| request and response DTOs, `@Serializable data class` | the shape exists once |
| enums that travel on the wire (`Transaction.Period`) | both sides switch on them |
| serializers for wire types (money as a decimal string) | both sides must agree byte for byte |
| tiny interfaces the model needs (`WithId { val id: String }`) | the model does not compile without them |
| pure functions **both** sides need (the balance simulation in the reference) | the only place where both get the same answer |

## What stays out, and where it goes instead

| Out | Why | Where |
|---|---|---|
| the server's address | a server has no use for its own address; a module called the contract should be one | the client (`Constants.kt` plus a runtime override) |
| the record owner's id (`userId`) | ownership is a server-side notion; the client never sees it | a server-side `Record` type next to the port |
| validation and business rules | the form is a convenience; the boundary is the server | `Rules.kt` in the server's feature package |
| repository interfaces, use cases, exceptions | the contract describes the wire, not how a side is layered; otherwise the client depends on the server's layering | each side's own feature package |
| UI state, formatting | presentation | the client |
| the storage document shape | the database is a third party to the contract | each server build's `data/` |

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
- **A sentinel in the contract is a product decision.** `Category.default = Category("0",
  "Default")` is what the server substitutes when a record's category no longer exists. Write
  such a decision down where the sentinel is declared; a reader otherwise takes it for a
  placeholder.

## Status-code conventions

These are the reference product's; keep whatever the project already does, but make sure each
answer below has *a* decision.

| Situation | Answer | Why |
|---|---|---|
| created | `201` with the created entity, ids and substitutions filled in | the client replaces its optimistic copy with the server's |
| a validation rule refused the input | `400` with a **human-readable text that says what to fix** | the form shows the text as is |
| the body or a path parameter did not parse | `400 Malformed request`, one generic text | details would describe the server's internals |
| no token, wrong kind of token, expired | `401` with one fixed text | the client's refresh logic keys on the code, not the text |
| not yours **or** does not exist | `403`, the same for both | different answers would say which ids are taken |
| the refresh token was refused | `401`: the session is over; **any other failure leaves the session alone** | a `500` on the server does not end a session |

**The id of the record being changed comes from the path, never from the body.** The reverse
was a real hole: ownership checked against the path, the write addressed by the body, and a
stranger's record rewritten with a `200`.

## Health as part of the contract

Two resources, two questions:

- `GET /health` answers **which build is running**: `Health(build, version, uptimeSeconds)`. No
  authentication, no dependencies touched: a liveness probe must not depend on the database, or
  a database outage restarts every replica and fixes nothing.
- `GET /health/ready` answers **whether the server can serve**: one cheap round trip to storage,
  `503` if it fails. A pod without a database should stop receiving traffic, not restart.

The client can show the `/health` answer (the reference welcome screen prints
`ktor · kotlin/native · 1.4.2`): the claim "the native build is what you are talking to" is then a
live fact rather than a README sentence.

## Checklist: changing a route

1. Change the `@Resource` class or the DTO in the contract module. Add defaults to new fields.
2. Build every consumer: both server builds and the client. The compiler now lists every call site.
3. Update the server route (`ktor-server-feature`) and the client data source
   (`compose-client-feature`).
4. If the change reaches storage, update **every** storage implementation and the raw-document
   test in each build (`kmp-testing`, "storage is tested against a real database").
5. If the repository keeps an API reference (`docs/api/endpoint-*.md`), update the route table,
   the status codes and the auth tier in the same change.
6. Run the grep that guards the whole thing: string literals containing your API prefix outside
   the contract module must be zero.

```bash
grep -rn --include='*.kt' '"/api' server*/src composeApp/src | grep -v '/shared/'
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
