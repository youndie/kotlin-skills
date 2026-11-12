# Use cases, typed errors and their dispatch in routes

Generic Kotlin in a fictional "orders" domain, in the shape several services converged on.

## The base type (a `core:use-case` module or a package)

```kotlin
/** A single domain operation. */
fun interface UseCase<in P, out T> {
    suspend operator fun invoke(params: P): Result<T>
}

/** runCatching that lets cancellation through: a cancelled request is not a failure. */
suspend inline fun <T> suspendRunCatching(block: () -> T): Result<T> = try {
    Result.success(block())
} catch (e: CancellationException) {
    throw e
} catch (e: Throwable) {
    Result.failure(e)
}
```

## A use case that orchestrates

```kotlin
class CreateOrderUseCase(
    private val canCreate: CanCreateOrderUseCase,
    private val orders: OrderRepository,
    private val allocateInventory: AllocateInventoryUseCase,
    private val transactions: TransactionManager,
    private val inventorySync: InventorySyncService,        // writes an outbox entry; a worker delivers it
    private val logEvent: LogEventUseCase,
) : UseCase<CreateOrderUseCase.Params, Order> {

    override suspend fun invoke(params: Params): Result<Order> = suspendRunCatching {
        if (canCreate(CanCreateOrderUseCase.Params(params.workspaceId)).getOrThrow() is PlanCheck.Denied) {
            throw Error.LimitReached()
        }

        val orderId = transactions.withTransaction {
            val usage = allocateInventory(
                AllocateInventoryUseCase.Params(params.order.items, params.workspaceId),
            ).getOrElse { throw it }                     // a nested use case's typed error travels up unchanged
            orders.save(params.order, usage, params.workspaceId)
        } ?: throw CommonError.SaveFailure()

        // The outbox carries the id only; the worker rereads the record at delivery time.
        inventorySync.enqueue(orderId, params.workspaceId)

        logEvent(
            LogEventUseCase.Params(
                userId = params.userId, workspaceId = params.workspaceId,
                action = AuditAction.CREATE, entityType = EntityType.ORDER, entityId = orderId,
            ),
        )

        orders.getById(orderId, params.workspaceId) ?: throw CommonError.SaveFailure()
    }

    /** Named fields: a route cannot pass the caller and the tenant in the wrong order. */
    class Params(val order: CreateOrderParams, val workspaceId: String, val userId: String)

    /**
     * What the route must tell apart. Anything else is a bug and stays an exception.
     * Classes, not objects: an `object` exception is one shared instance with one stack trace,
     * and `addSuppressed` on it mutates global state.
     */
    sealed class Error : Exception() {
        class LimitReached : Error()
    }
}

/** Shared by the feature's use cases. */
sealed class CommonError : Exception() {
    class SaveFailure : CommonError()
}

class AllocateInventoryUseCase(/* … */) : UseCase<AllocateInventoryUseCase.Params, List<InventoryUsage>> {
    sealed class Error : Exception() {
        class NotEnoughInventory : Error()
        class InventoryChanged : Error()
    }
    /* … */
}
```

## One dispatcher per error family

```kotlin
/** Lives next to the stock use cases: every route that can hit them maps them the same way. */
suspend fun RoutingContext.dispatchInventoryError(error: Throwable) {
    when (error) {
        is AllocateInventoryUseCase.Error.NotEnoughInventory -> call.respond(HttpStatusCode.BadRequest, "not enough inventory")
        is AllocateInventoryUseCase.Error.InventoryChanged -> call.respond(HttpStatusCode.Conflict, "inventory has changed")
        is ReleaseInventoryUseCase.Error.ItemNotFound -> call.respond(HttpStatusCode.NotFound, "inventory item not found")
        else -> throw error          // unknown → StatusPages: reported and answered 500
    }
}
```

## The route dispatches the result

```kotlin
// inside fun Route.ordersRouting(): createOrder and reporter resolved once with `by inject`
post<OrdersResource> {
    withAccess(min = Role.MANAGER) { (user, workspaceId) ->
        val params = call.receive<CreateOrderParams>()
        orderProblem(params)?.let { problem ->
            call.respond(HttpStatusCode.BadRequest, problem)
            return@withAccess
        }

        createOrder(CreateOrderUseCase.Params(params, workspaceId, user.id))
            .onSuccess { call.respond(HttpStatusCode.Created, it) }
            .onFailure { error ->
                when (error) {
                    is CreateOrderUseCase.Error.LimitReached -> call.respond(HttpStatusCode.BadRequest, ORDER_LIMIT_REACHED)
                    is AllocateInventoryUseCase.Error -> dispatchInventoryError(error)
                    is CommonError.SaveFailure -> {
                        reporter.report(error)                    // unexpected: somebody should look
                        call.respond(HttpStatusCode.InternalServerError, "saving error")
                    }
                    else -> throw error
                }
            }
    }
}
```

What is deliberately **not** here: a `try/catch` in the route (the use case already folded), a
match on `error.message`, a generic `400` for everything (`else -> throw` keeps bugs visible),
and a `500` for a business refusal.

## Shape validation as a pure function

```kotlin
private const val MAX_COMMENT = 200

/** What is wrong with the input, or null. The text is shown to a person and says what to fix. */
fun orderProblem(params: CreateOrderParams): String? = when {
    params.items.isEmpty() -> "An order needs at least one item"
    params.items.any { it.quantity.signum() <= 0 } -> "Quantity must be greater than zero"
    params.comment.length > MAX_COMMENT -> "Comment must be at most $MAX_COMMENT characters long"
    else -> null
}
```

## Testing a use case: every typed error, and the absence of side effects

```kotlin
class CreateOrderUseCaseTest {
    private val orders = FakeOrderRepository()
    private val inventory = FakeAllocateInventory(result = Result.success(emptyList()))
    private val audit = RecordingLogEvent()
    private val useCase = CreateOrderUseCase(AlwaysAllowed, orders, inventory, NoopTransactionManager, FakeInventorySync(), audit)

    @Test
    fun `creates the order and logs the event`() = runTest {
        val result = useCase(CreateOrderUseCase.Params(anOrder(), "ws-1", "u-1"))

        assertTrue(result.isSuccess)
        assertEquals(1, orders.saved.size)
        assertEquals(1, audit.events.size)
    }

    @Test
    fun `a stock refusal leaves nothing behind`() = runTest {
        inventory.result = Result.failure(AllocateInventoryUseCase.Error.NotEnoughInventory())

        val result = useCase(CreateOrderUseCase.Params(anOrder(), "ws-1", "u-1"))

        assertIs<AllocateInventoryUseCase.Error.NotEnoughInventory>(result.exceptionOrNull())
        assertTrue(orders.saved.isEmpty(), "the order was saved although inventory was refused")
        assertTrue(audit.events.isEmpty(), "an event was logged for an order that does not exist")
    }

    @Test
    fun `a save that returns nothing is a SaveFailure`() = runTest {
        orders.saveReturnsNull = true

        assertIs<CommonError.SaveFailure>(useCase(CreateOrderUseCase.Params(anOrder(), "ws-1", "u-1")).exceptionOrNull())
    }
}
```

In a JVM-only suite the fakes may be mocks (`coEvery { … } returns …`, `coVerify(exactly = 0)`);
in a `commonTest` that compiles to native, fakes are the only option, and a fake with a `saved`
list reads better than a verification anyway.

## When the contract carries error codes

The dispatcher above answers with texts. Where the contract has an `ErrorCode` and an `ErrorBody`
(`kmp-shared-contract`, "An error is a code, and the status is its fallback"), each typed error
carries its code, and the mapping to a status is written once. From
[haul](https://github.com/youndie/haul), trimmed:

```kotlin
internal sealed class CartError(val code: ErrorCode, override val message: String, val field: String? = null) : Exception(message) {
    class Invalid(field: String, message: String) : CartError(ErrorCode.ValidationFailed, message, field)
    class OutOfStock(message: String) : CartError(ErrorCode.OutOfStock, message, "quantity")
    class LineNotFound(val skuId: String) : CartError(ErrorCode.LineNotFound, "This item is no longer in your cart")
}

/** The one shape of every refusal. */
internal suspend fun ApplicationCall.respondError(code: ErrorCode, message: String, field: String? = null, status: HttpStatusCode = status(code)) =
    respondText(wireJson.encodeToString(ErrorBody.serializer(), ErrorBody(code, message, field)), ContentType.Application.Json, status)

/** Exhaustive, no `else`: a new code does not compile until its status is decided. */
internal fun status(code: ErrorCode): HttpStatusCode = when (code) {
    ErrorCode.ValidationFailed -> HttpStatusCode.BadRequest
    ErrorCode.Unauthenticated -> HttpStatusCode.Unauthorized
    ErrorCode.LineNotFound -> HttpStatusCode.NotFound
    ErrorCode.OutOfStock -> HttpStatusCode.Conflict
    ErrorCode.Unavailable -> HttpStatusCode.ServiceUnavailable
    ErrorCode.Internal -> HttpStatusCode.InternalServerError
}
```

A route's `when` over a use case's errors then shrinks to `is CartError -> call.respondError(error.code, error.message, error.field)`,
and the rule that an unknown error is rethrown stands as written.

The reference goes one step further, and it is a choice, not the default: its operations throw
the feature's sealed error instead of returning a `Result`, and `StatusPages` maps each **family**
(`exception<CartError> { call, e -> call.respondError(e.code, e.message, e.field) }`), so a route
is three lines and nothing dispatches. It fits a service whose every refusal has a code and whose
routes never need to do anything *but* answer with it. What it gives up is the route's chance to
react to one error differently (retry, compensate, answer `200` with a fallback), and a handler
that has to do that catches the family itself. One exception to the single mapping is written
where it is made: the same `guest_not_found` is `401` on a cart route, where the client replaces
its guest, and `404` on the sign-in merge.

**What the catch-all reports, on a service the public can reach.** The skill's rule is that
whatever reaches `StatusPages` unexpected is reported, `400`s included. On an open storefront
that filled the error tracker with crawlers' malformed queries and with one report per page for
the length of a database outage, so its catch-all sorts three cases: one of Ktor's own client
errors keeps its status and is logged at `info`, not reported; a database that cannot be reached
is `unavailable` / `503`, logged without a stack and not reported — the outage is said once, by
the pool that met it; anything else is `internal` / `500`, logged with its stack **before** it
is reported, and nothing of the exception goes into the body. A client that left mid-answer (a
closed event stream) is neither answered nor reported: nobody is there, and nothing failed.
