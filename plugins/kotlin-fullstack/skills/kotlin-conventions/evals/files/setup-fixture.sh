#!/usr/bin/env bash
# One fixture, two shapes. $1 is the directory to build in, $2 the case.
#
# `review` is code with defects planted in it, each one a rule of the skill that was paid for;
# `reporter` is a two-build server about to grow a dependency. Nothing here builds.
set -euo pipefail
dir="$1"; shape="${2:-review}"
mkdir -p "$dir"

case "$shape" in
  review)
    src="$dir/server/src/main/kotlin/app/feature/order"
    client="$dir/composeApp/src/commonMain/kotlin/app/feature/order"
    test="$dir/server-common/src/commonTest/kotlin/app/feature/order"
    mkdir -p "$src" "$client" "$test"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

A Ktor server compiled for the JVM and for linuxX64 (`server-common` is the shared half) and a
Compose Multiplatform client. The pull request under review adds the `order` feature.
EOF
    cat > "$src/OrderRouting.kt" <<'EOF'
package app.feature.order

import io.ktor.http.HttpStatusCode
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import io.ktor.server.routing.post
import kotlinx.serialization.Serializable
import org.slf4j.LoggerFactory

private val log = LoggerFactory.getLogger("orders")

enum class Role { OWNER, MANAGER, VIEWER }

@Serializable data class CreateOrder(val workspaceId: String, val title: String)

class OrderService(private val orders: OrderRepository) {
    suspend fun create(workspaceId: String, title: String): Result<String> = runCatching {
        if (orders.count(workspaceId) >= 100) throw RuntimeException("Limit reached")
        orders.save(workspaceId, title)
    }
}

interface OrderRepository {
    suspend fun count(workspaceId: String): Int
    suspend fun save(workspaceId: String, title: String): String
}

fun Route.orderRouting(service: OrderService, roleOf: suspend (token: String, workspaceId: String) -> Role?) {
    post("/orders") {
        val token = call.request.headers["Authorization"].orEmpty()
        val body = call.receive<CreateOrder>()
        val role = roleOf(token, body.workspaceId)
        if (role == null || role.ordinal > Role.MANAGER.ordinal) {
            log.warn("refused: token=$token")
            call.respond(HttpStatusCode.Forbidden)
            return@post
        }
        service.create(body.workspaceId, body.title)
            .onSuccess { call.respond(HttpStatusCode.Created, it) }
            .onFailure {
                if (it.message == "Limit reached") call.respond(HttpStatusCode.BadRequest, "limit")
                else call.respond(HttpStatusCode.BadRequest, "bad request")
            }
    }
}
EOF
    cat > "$client/OrdersViewModel.kt" <<'EOF'
package app.feature.order

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** Returns the orders. */
interface OrdersSource { fun orders(): Flow<Result<List<String>>> }

open class BaseViewState(val loading: Boolean = false, val error: String? = null)
class OrdersState(val items: List<String> = emptyList(), val saved: Boolean = false, loading: Boolean = false, error: String? = null) : BaseViewState(loading, error)

class OrdersViewModel(private val source: OrdersSource) : ViewModel() {
    val state = MutableStateFlow(OrdersState(loading = true))

    init {
        viewModelScope.launch {
            source.orders().collect { result ->
                try {
                    state.value = OrdersState(items = result.getOrThrow())
                } catch (e: Exception) {
                    state.value = OrdersState(error = e.message)
                }
            }
        }
    }

    @Suppress("UNUSED_PARAMETER")
    fun onSaved(id: String) { state.value = OrdersState(items = state.value.items, saved = true) }
}
EOF
    cat > "$test/OrderServiceTest.kt" <<'EOF'
package app.feature.order

import org.junit.Test
import kotlin.test.assertTrue

class OrderServiceTest {
    @Test
    fun `at the limit, an order is refused`() {
        assertTrue(true)
    }
}
EOF
    ;;

  reporter)
    common="$dir/server-common/src/commonMain/kotlin/app"
    mkdir -p "$common/config" "$dir/server/src/main/kotlin/app" "$dir/server-native/src/linuxX64Main/kotlin/app"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

One Ktor server compiled twice: `:server` (JVM) and `:server-native` (linuxX64) over
`:server-common`, which holds everything but the entry points and storage. Koin for DI.
The only `expect` in the project is `readEnv`.
EOF
    cat > "$common/config/Env.kt" <<'EOF'
package app.config

/** `System.getenv` on the JVM, `getenv` on POSIX: the one thing here that is a platform API. */
expect fun readEnv(name: String): String?
EOF
    cat > "$common/App.kt" <<'EOF'
package app

import io.ktor.http.HttpStatusCode
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.response.respond
import org.koin.dsl.module

fun coreModule() = module {
    // use cases, services
}

fun Application.configurePlugins() {
    install(StatusPages) {
        exception<Throwable> { call, _ -> call.respond(HttpStatusCode.InternalServerError) }
    }
}
EOF
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
