#!/usr/bin/env bash
# One fixture, three shapes. $1 is the directory to build in, $2 the case.
#
# Each shape is the smallest server in which the decision the case is about is real. Nothing here
# builds — there is no Gradle wrapper — and no case asks for a build: what is graded is the code
# that was written and the reason given for it.
set -euo pipefail
dir="$1"; shape="${2:-notes}"
shared="$dir/shared/src/commonMain/kotlin/app"
server="$dir/server/src/main/kotlin/app"
tests="$dir/server/src/test/kotlin/app"
mkdir -p "$shared" "$server" "$tests"

cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

A Ktor 3 server on the JVM with a shared contract module. Koin for DI, kotlinx-serialization,
`ktor-server-resources`. `:shared` holds the `@Resource` classes and DTOs; `:server` the routes,
use cases and storage. Features live in `server/src/main/kotlin/app/feature/<name>/`.
EOF

case "$shape" in
  notes)
    # A read route exists; the case asks for the write. The owner comes from a helper, and the
    # port takes the owner in every signature — or would, if the new method follows the old one.
    mkdir -p "$shared/feature/note" "$server/feature/note/domain" "$server/security"
    cat > "$shared/feature/note/Note.kt" <<'EOF'
package app.feature.note

import io.ktor.resources.Resource
import kotlinx.serialization.Serializable

@Resource("/notes")
class NoteResource {
    @Resource("/{id}")
    class ById(val parent: NoteResource = NoteResource(), val id: String)
}

/** `id` is issued by the server; a client sends "" on create. */
@Serializable
data class Note(val id: String = "", val title: String, val text: String = "")
EOF
    cat > "$server/security/Access.kt" <<'EOF'
package app.security

import io.ktor.server.routing.RoutingContext

class User(val id: String)

/** Resolves the caller from the verified principal; answers 401 itself when there is none. */
suspend fun RoutingContext.withUser(block: suspend (User) -> Unit) { TODO("resolved from the JWT principal") }
EOF
    cat > "$server/feature/note/domain/NoteRepository.kt" <<'EOF'
package app.feature.note.domain

import app.feature.note.Note

/** The owner is in every signature: a note of another user matches nothing. */
interface NoteRepository {
    suspend fun find(ownerId: String, id: String): Note?
    suspend fun list(ownerId: String): List<Note>
}
EOF
    cat > "$server/feature/note/NoteRouting.kt" <<'EOF'
package app.feature.note

import app.feature.note.domain.NoteRepository
import app.security.withUser
import io.ktor.http.HttpStatusCode
import io.ktor.server.resources.get
import io.ktor.server.response.respond
import io.ktor.server.routing.Route
import org.koin.ktor.ext.inject

fun Route.noteRouting() {
    val notes by inject<NoteRepository>()

    get<NoteResource> { withUser { user -> call.respond(notes.list(user.id)) } }

    get<NoteResource.ById> { path ->
        withUser { user ->
            notes.find(user.id, path.id)?.let { call.respond(it) } ?: call.respond(HttpStatusCode.NotFound)
        }
    }
}
EOF
    ;;

  defaulted-parameter)
    # A use case registered with singleOf, and a graph test that is only verify(). The case adds
    # a defaulted lambda parameter — the registration that fails lazily, on one route.
    mkdir -p "$server/feature/order/domain" "$tests/di"
    cat > "$server/feature/order/domain/CreateOrderUseCase.kt" <<'EOF'
package app.feature.order.domain

import java.util.UUID

interface OrderRepository { suspend fun save(id: String, title: String) }

class CreateOrderUseCase(private val orders: OrderRepository) {
    suspend operator fun invoke(title: String): Result<String> = runCatching {
        val id = UUID.randomUUID().toString()
        orders.save(id, title)
        id
    }
}
EOF
    cat > "$server/feature/order/OrderModule.kt" <<'EOF'
package app.feature.order

import app.feature.order.domain.CreateOrderUseCase
import org.koin.core.module.dsl.singleOf
import org.koin.dsl.module

val orderModule = module {
    singleOf(::CreateOrderUseCase)
}
EOF
    cat > "$tests/di/KoinGraphTest.kt" <<'EOF'
package app.di

import app.feature.order.orderModule
import org.koin.test.verify.verify
import kotlin.test.Test

class KoinGraphTest {
    @Test
    fun `every definition can be resolved`() = orderModule.verify(extraTypes = listOf(app.feature.order.domain.OrderRepository::class))
}
EOF
    ;;

  outbox-two-replicas)
    # One replica by construction: a relay with no claim on its rows, started in every process.
    mkdir -p "$server/feature/outbox" "$dir/charts/app" "$server/db"
    cat > "$server/db/Database.kt" <<'EOF'
package app.db

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import org.flywaydb.core.Flyway
import javax.sql.DataSource

fun dataSource(url: String, user: String, password: String, poolSize: Int): HikariDataSource =
    HikariDataSource(HikariConfig().apply { jdbcUrl = url; username = user; this.password = password; maximumPoolSize = poolSize })

fun migrate(dataSource: DataSource) { Flyway.configure().dataSource(dataSource).load().migrate() }
EOF
    cat > "$server/feature/outbox/OutboxRelay.kt" <<'EOF'
package app.feature.outbox

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import javax.sql.DataSource
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

fun interface Publisher { suspend fun publish(id: Long, payload: String) }

/** Publishes rows of `outbox` that are not sent yet, oldest first, then marks them sent. */
class OutboxRelay(private val dataSource: DataSource, private val publisher: Publisher, private val every: Duration = 1.seconds) {
    private var job: Job? = null

    fun start(scope: CoroutineScope) {
        job = scope.launch {
            while (true) {
                dataSource.connection.use { connection ->
                    val rows = connection.createStatement().executeQuery("select id, payload from outbox where sent_at is null order by id limit 50")
                    while (rows.next()) {
                        val id = rows.getLong("id")
                        publisher.publish(id, rows.getString("payload"))
                        connection.createStatement().executeUpdate("update outbox set sent_at = now() where id = $id")
                    }
                }
                delay(every)
            }
        }
    }

    fun stop() { job?.cancel() }
}
EOF
    cat > "$server/Application.kt" <<'EOF'
package app

import app.db.dataSource
import app.db.migrate
import app.feature.outbox.OutboxRelay
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationStarted
import io.ktor.server.application.ApplicationStopping
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer

fun main() {
    val pool = dataSource(System.getenv("DB_URL"), System.getenv("DB_USER"), System.getenv("DB_PASSWORD"), System.getenv("DB_POOL_SIZE")?.toInt() ?: 40)
    migrate(pool)
    embeddedServer(CIO, port = 8080) { module(OutboxRelay(pool, publisher = { _, _ -> TODO("the broker client") })) }.start(wait = true)
}

fun Application.module(relay: OutboxRelay) {
    monitor.subscribe(ApplicationStarted) { relay.start(this) }
    monitor.subscribe(ApplicationStopping) { relay.stop() }
    // … routing …
}
EOF
    cat > "$dir/charts/app/values.yaml" <<'EOF'
server:
  replicas: 1
  dbPoolSize: 40
postgres:
  maxConnections: 100
EOF
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
