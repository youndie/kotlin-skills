#!/usr/bin/env bash
# One fixture, two shapes. $1 is the directory to build in, $2 the case.
#
# A contract module, a server and a client, each a few files: enough for a path or a refusal to
# exist on more than one side. Nothing here builds, and no case asks for a build.
set -euo pipefail
dir="$1"; shape="${2:-history}"
shared="$dir/shared/src/commonMain/kotlin/app"
server="$dir/server/src/main/kotlin/app"
client="$dir/composeApp/src/commonMain/kotlin/app"
mkdir -p "$shared" "$server" "$client"

cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

`:shared` is the wire contract (every client target and the server compile it). `:server` is a
Ktor 3 server with `ktor-server-resources`; `:composeApp` a Compose Multiplatform client with
`ktor-client-resources`. kotlinx-serialization on both sides.
EOF

case "$shape" in
  history)
    # Typed on both sides already. The case adds a sub-resource; the shortcut is a string path.
    mkdir -p "$shared/feature/transaction" "$server/feature/transaction" "$client/feature/transaction/data"
    cat > "$shared/feature/transaction/Transaction.kt" <<'EOF'
package app.feature.transaction

import io.ktor.resources.Resource
import kotlinx.serialization.Serializable

@Resource("/transactions")
class TransactionResource {
    @Resource("/{id}")
    class ById(val parent: TransactionResource = TransactionResource(), val id: String)
}

/** `amount` is a decimal string: a JSON number loses cents in half the clients in the world. */
@Serializable
data class Transaction(val id: String = "", val amount: String, val comment: String = "")
EOF
    cat > "$server/feature/transaction/TransactionRouting.kt" <<'EOF'
package app.feature.transaction

import io.ktor.http.HttpStatusCode
import io.ktor.server.resources.get
import io.ktor.server.response.respond
import io.ktor.server.routing.Route

interface TransactionRepository {
    suspend fun find(ownerId: String, id: String): Transaction?
    suspend fun list(ownerId: String): List<Transaction>
}

fun Route.transactionRouting(transactions: TransactionRepository, ownerId: suspend () -> String) {
    get<TransactionResource> { call.respond(transactions.list(ownerId())) }
    get<TransactionResource.ById> { path ->
        transactions.find(ownerId(), path.id)?.let { call.respond(it) } ?: call.respond(HttpStatusCode.NotFound)
    }
}
EOF
    cat > "$client/feature/transaction/data/TransactionApi.kt" <<'EOF'
package app.feature.transaction.data

import app.feature.transaction.Transaction
import app.feature.transaction.TransactionResource
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.plugins.resources.get

class TransactionApi(private val http: HttpClient) {
    suspend fun list(): List<Transaction> = http.get(TransactionResource()).body()
    suspend fun byId(id: String): Transaction = http.get(TransactionResource.ById(id = id)).body()
}
EOF
    ;;

  guest-cart)
    # Two refusals under one status, and a client that recovers from the status.
    mkdir -p "$shared/feature/cart" "$server/feature/cart" "$client/feature/identity"
    cat > "$shared/feature/cart/Cart.kt" <<'EOF'
package app.feature.cart

import kotlinx.serialization.Serializable

@Serializable data class CartLine(val skuId: String, val quantity: Int)
@Serializable data class Cart(val lines: List<CartLine> = emptyList())
EOF
    cat > "$server/feature/cart/CartRouting.kt" <<'EOF'
package app.feature.cart

import io.ktor.http.HttpStatusCode
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.get

interface Guests { suspend fun exists(guestId: String): Boolean }
interface Carts { suspend fun of(ownerId: String): Cart }

/**
 * The cart is a guest's (the `X-Guest` header, an id this server issued) or a customer's (a
 * verified token, resolved by [customerId]). Checkout below is the customer's alone.
 */
fun Route.cartRouting(guests: Guests, carts: Carts, customerId: suspend () -> String?) {
    get("/cart") {
        val customer = customerId()
        val guest = call.request.headers["X-Guest"]
        when {
            customer != null -> call.respond(carts.of(customer))
            guest == null -> call.respond(HttpStatusCode.Unauthorized, "no credentials")
            !guests.exists(guest) -> call.respond(HttpStatusCode.Unauthorized, "unknown guest")
            else -> call.respond(carts.of(guest))
        }
    }
    get("/checkout") {
        val customer = customerId() ?: return@get call.respond(HttpStatusCode.Unauthorized, "sign in to check out")
        call.respond(carts.of(customer))
    }
}
EOF
    cat > "$client/feature/identity/Identity.kt" <<'EOF'
package app.feature.identity

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode

/** Sends a request as the current guest; a guest the server no longer knows is replaced. */
class Identity(private val http: HttpClient, private var guestId: String?) {
    suspend fun get(path: String): HttpResponse {
        val response = send(path)
        if (response.status != HttpStatusCode.Unauthorized) return response
        // The stand was reseeded under this browser: ask for a new guest and try once more.
        guestId = http.post("/guests").body<String>()
        return send(path)
    }

    private suspend fun send(path: String): HttpResponse = http.get(path) { guestId?.let { header("X-Guest", it) } }
}
EOF
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
