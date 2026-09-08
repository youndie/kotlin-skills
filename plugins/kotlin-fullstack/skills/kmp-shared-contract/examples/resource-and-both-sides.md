# One resource, both sides

Trimmed from the reference project; comments translated. The three files below are the whole
lifecycle of a path: declared once, parsed on the server, built on the client.

## `:shared` — the contract

```kotlin
package io.github.youndie.mani.feature.transaction

import io.ktor.resources.Resource
import kotlinx.datetime.LocalDate
import kotlinx.serialization.Serializable

@Resource("/transactions")
class TransactionResource {
    @Resource("/{id}")
    class ById(val parent: TransactionResource = TransactionResource(), val id: String)
}

@Serializable
data class Transaction(
    val id: String,
    val amount: BigDecimalSerializable,
    val income: Boolean,
    val date: LocalDate,
    val until: LocalDate?,
    val period: Period,
    val comment: String,
    val category: Category = Category.default,   // default: an older client keeps parsing
) {
    enum class Period { OneTime, Day, Week, TwoWeek, Month, ThreeMonth, HalfYear, Year }
}

@Serializable
data class Category(val id: String, val name: String) {
    companion object {
        /**
         * What the server substitutes when a record's category no longer exists.
         * A product decision, not a placeholder: a deleted category looks like "Default"
         * rather than like an error.
         */
        val default = Category("0", "Default")
    }
}

/** The sign comes from `income`, not from the amount; the server refuses negative amounts. */
val Transaction.amountSigned get() = amount * (if (income) 1 else -1).toBigDecimal()
```

```kotlin
package io.github.youndie.mani.utilz.bigdecimal

typealias BigDecimalSerializable = @Serializable(with = BigDecimalSerializer::class) BigDecimal

/** Money on the wire is a decimal string: a JSON number would be parsed as a double somewhere. */
object BigDecimalSerializer : KSerializer<BigDecimal> {
    override val descriptor = PrimitiveSerialDescriptor("BigDecimal", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: BigDecimal) = encoder.encodeString(value.toPlainString())
    override fun deserialize(decoder: Decoder): BigDecimal = decoder.decodeString().toBigDecimal()
}
```

## `:server-common` — the route parses the path

```kotlin
fun Routing.transactionRouting() {
    val transactionRepository by inject<TransactionRepository>()
    val categoryRepository by inject<CategoryRepository>()
    val jwtConfig by inject<JWTConfig>()

    authenticate(jwtConfig.name) {
        post<TransactionResource> {
            val transaction = call.receive<Transaction>()

            val problem = transactionProblem(transaction)
            if (problem != null) {
                call.respond(HttpStatusCode.BadRequest, problem)
                return@post
            }

            val userId = call.currentUserId()
            val categories = categoryRepository.getByUser(userId)
            val id = transactionRepository.create(transaction, userId)
            val added = transactionRepository.getById(id) ?: run {
                call.respond(HttpStatusCode.NotFound)
                return@post
            }

            call.respond(HttpStatusCode.Created, added.toTransaction(categories))
        }

        patch<TransactionResource.ById> { path ->
            // The id comes ONLY from the path. The body arrives with an id of its own, and it used
            // to select the document to write while ownership was checked against path.id:
            // PATCH /transactions/<mine> with a stranger's id in the body rewrote theirs.
            val new = call.receive<Transaction>().copy(id = path.id)

            val problem = transactionProblem(new)
            if (problem != null) {
                call.respond(HttpStatusCode.BadRequest, problem)
                return@patch
            }

            val userId = call.currentUserId()
            val old = transactionRepository.getById(path.id)

            // 403 for "not yours" and for "does not exist" alike: different answers would say
            // which ids are taken.
            if (old?.userId != userId) {
                call.respond(HttpStatusCode.Forbidden)
                return@patch
            }
            transactionRepository.update(new, userId)
            call.respond(HttpStatusCode.OK, new)
        }
    }
}
```

## `:composeApp` — the client's API class builds the URL

```kotlin
/** The only class on the client that knows the HTTP client for this resource. */
class RulesApi(private val httpClient: HttpClient) {

    suspend fun list(): List<Transaction> =
        httpClient.get(TransactionResource()).body()

    suspend fun create(rule: Transaction): Transaction =
        httpClient.post(TransactionResource()) { setBody(rule) }.body()

    suspend fun update(rule: Transaction): Transaction =
        httpClient.patch(TransactionResource.ById(id = rule.id)) { setBody(rule) }.body()

    suspend fun delete(id: String) {
        httpClient.delete(TransactionResource.ById(id = id))
    }
}
```

The repository calls this class inside `runNetworkCatching` and maps the wire class to the
domain model; see `compose-client-feature`.

## The health pair

```kotlin
/**
 * `GET /health` — which build is answering. No authentication: it is the shop window, not data.
 * Touches no dependencies on purpose: the liveness probe looks at it, and liveness must not
 * depend on the database, or a database outage restarts every pod and fixes nothing.
 */
@Resource("/health")
class HealthResource {
    /**
     * `GET /health/ready` — can the server serve: storage answers.
     * Separate because the questions differ: "the process is alive" and "the process has
     * something to work with" are not the same, and confusing them is expensive — a pod without
     * a database should stop receiving traffic, not restart.
     */
    @Resource("ready")
    class Ready(val parent: HealthResource = HealthResource())
}

/**
 * @param build which build answered: `jvm` or `kotlin/native`
 * @param version the product version
 * @param uptimeSeconds how long this build has been running
 */
@Serializable
data class Health(val build: String, val version: String, val uptimeSeconds: Long)
```
