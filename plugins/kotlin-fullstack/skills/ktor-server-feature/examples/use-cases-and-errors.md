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
    private val allocateStock: AllocateStockUseCase,
    private val transactions: TransactionManager,
    private val stockSync: StockSyncService,        // writes an outbox entry; a worker delivers it
    private val logEvent: LogEventUseCase,
) : UseCase<CreateOrderUseCase.Params, Order> {

    override suspend fun invoke(params: Params): Result<Order> = suspendRunCatching {
        if (canCreate(CanCreateOrderUseCase.Params(params.workspaceId)).getOrThrow() is PlanCheck.Denied) {
            throw Error.LimitReached
        }

        val orderId = transactions.withTransaction {
            val usage = allocateStock(
                AllocateStockUseCase.Params(params.order.items, params.workspaceId),
            ).getOrElse { throw it }                     // a nested use case's typed error travels up unchanged
            orders.save(params.order, usage, params.workspaceId)
        } ?: throw CommonError.SaveFailure

        // The outbox carries the id only; the worker rereads the record at delivery time.
        stockSync.enqueue(orderId, params.workspaceId)

        logEvent(
            LogEventUseCase.Params(
                userId = params.userId, workspaceId = params.workspaceId,
                action = AuditAction.CREATE, entityType = EntityType.ORDER, entityId = orderId,
            ),
        )

        orders.getById(orderId, params.workspaceId) ?: throw CommonError.SaveFailure
    }

    /** Named fields: a route cannot pass the caller and the tenant in the wrong order. */
    class Params(val order: CreateOrderParams, val workspaceId: String, val userId: String)

    /** What the route must tell apart. Anything else is a bug and stays an exception. */
    sealed class Error : Exception() {
        data object LimitReached : Error()
    }
}

/** Shared by the feature's use cases. */
sealed class CommonError : Exception() {
    data object SaveFailure : CommonError()
}

class AllocateStockUseCase(/* … */) : UseCase<AllocateStockUseCase.Params, List<StockUsage>> {
    sealed class Error : Exception() {
        data object NotEnoughStock : Error()
        data object StockChanged : Error()
    }
    /* … */
}
```

## One dispatcher per error family

```kotlin
/** Lives next to the stock use cases: every route that can hit them maps them the same way. */
suspend fun RoutingContext.dispatchStockError(error: Throwable) {
    when (error) {
        AllocateStockUseCase.Error.NotEnoughStock -> call.respond(HttpStatusCode.BadRequest, "not enough stock")
        AllocateStockUseCase.Error.StockChanged -> call.respond(HttpStatusCode.Conflict, "stock has changed")
        RestoreStockUseCase.Error.ItemNotFound -> call.respond(HttpStatusCode.NotFound, "stock item not found")
        else -> throw error          // unknown → StatusPages: reported and answered 500
    }
}
```

## The route dispatches the result

```kotlin
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
                    CreateOrderUseCase.Error.LimitReached -> call.respond(HttpStatusCode.BadRequest, ORDER_LIMIT_REACHED)
                    is AllocateStockUseCase.Error -> dispatchStockError(error)
                    CommonError.SaveFailure -> {
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
    private val stock = FakeAllocateStock(result = Result.success(emptyList()))
    private val audit = RecordingLogEvent()
    private val useCase = CreateOrderUseCase(AlwaysAllowed, orders, stock, NoopTransactionManager, FakeStockSync(), audit)

    @Test
    fun `creates the order and logs the event`() = runTest {
        val result = useCase(CreateOrderUseCase.Params(anOrder(), "ws-1", "u-1"))

        assertTrue(result.isSuccess)
        assertEquals(1, orders.saved.size)
        assertEquals(1, audit.events.size)
    }

    @Test
    fun `a stock refusal leaves nothing behind`() = runTest {
        stock.result = Result.failure(AllocateStockUseCase.Error.NotEnoughStock)

        val result = useCase(CreateOrderUseCase.Params(anOrder(), "ws-1", "u-1"))

        assertEquals(AllocateStockUseCase.Error.NotEnoughStock, result.exceptionOrNull())
        assertTrue(orders.saved.isEmpty(), "the order was saved although stock was refused")
        assertTrue(audit.events.isEmpty(), "an event was logged for an order that does not exist")
    }

    @Test
    fun `a save that returns nothing is a SaveFailure`() = runTest {
        orders.saveReturnsNull = true

        assertEquals(CommonError.SaveFailure, useCase(CreateOrderUseCase.Params(anOrder(), "ws-1", "u-1")).exceptionOrNull())
    }
}
```

In a JVM-only suite the fakes may be mocks (`coEvery { … } returns …`, `coVerify(exactly = 0)`);
in a `commonTest` that compiles to native, fakes are the only option, and a fake with a `saved`
list reads better than a verification anyway.
