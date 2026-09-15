# A repository on Kotlin/Native (sqlx4k)

The shape is the one in [storage-port-and-implementations.md](storage-port-and-implementations.md)
— the port in `domain/`, every line of data access in `data/…Impl` — and the idioms are different
enough to be worth their own file. Stack: Ktor's native engine, SQLite through sqlx4k.

```kotlin
// domain/ProductRepository.kt — suspend throughout, unlike a blocking JVM ORM
interface ProductRepository {
    suspend fun list(ownerId: Long, search: String?): List<Product>
    suspend fun get(ownerId: Long, id: Long): Product
    suspend fun create(ownerId: Long, request: CreateProductRequest): Product
}

// data/ProductRowMapper.kt — the equivalent of a `ResultRow.toProduct()`
object ProductRowMapper : RowMapper<Product> {
    override fun map(row: ResultSet.Row, converters: ValueEncoderRegistry) = Product(
        id = row.get("id").asLong(),
        name = row.get("name").asString(),
        price = row.get("price").asLongOrNull(),
    )
}

// data/ProductRepositoryImpl.kt
class ProductRepositoryImpl(
    private val db: ISQLite,
) : ProductRepository {

    override suspend fun list(ownerId: Long, search: String?): List<Product> =
        TransactionContext.withCurrent(db) {
            fetchAll(
                Statement.create(
                    """
                    SELECT * FROM products
                    WHERE owner_id = :ownerId
                      AND (:search IS NULL OR name LIKE '%' || :search || '%')
                    ORDER BY id DESC
                    """,
                ).apply {
                    bind("ownerId", ownerId)
                    bind("search", search)
                },
                ProductRowMapper,
            ).getOrThrow()
        }

    override suspend fun get(ownerId: Long, id: Long): Product =
        TransactionContext.withCurrent(db) {
            fetchAll(
                Statement.create("SELECT * FROM products WHERE id = :id AND owner_id = :ownerId")
                    .apply { bind("id", id); bind("ownerId", ownerId) },
                ProductRowMapper,
            ).getOrThrow().firstOrNull() ?: throw NotFoundException("Product not found")
        }

    override suspend fun create(ownerId: Long, request: CreateProductRequest): Product =
        TransactionContext.withCurrent(db) {
            execute(
                Statement.create("INSERT INTO products (owner_id, name) VALUES (:ownerId, :name)")
                    .apply { bind("ownerId", ownerId); bind("name", request.name) },
            ).getOrThrow()
            fetchAll(
                Statement.create("SELECT * FROM products WHERE id = last_insert_rowid()"),
                ProductRowMapper,
            ).getOrThrow().first()
        }
}
```

What matters here rather than in the JVM version:

- **The driver's `Result` is unwrapped in the repository** (`.getOrThrow()`), and a domain
  exception leaves it. Returning that `Result` and letting the use case wrap it in its own puts a
  `Result.failure` **inside** a `Result.success`: the central handler never sees it, and the route
  answers `200` with a body describing nothing that happened.
- **Parameters only through `bind`.** A value interpolated into the SQL string is an injection;
  the only things pasted as text are `LIMIT`/`OFFSET`, after `coerceIn`.
- **The owner (or tenant) filter is in every statement**, exactly as on the JVM.
- **No `java.*`**: time is `kotlin.time.Clock.System.now()`, files are okio.

## Wiring it, if the build uses `ktor-server-di` rather than Koin

```kotlin
fun Application.initDi(db: ISQLite) = dependencies {
    provide<ProductRepository> { ProductRepositoryImpl(db) }
    provide<CreateProductUseCase> { CreateProductUseCase(resolve()) }
}

fun Application.configureRouting() = routing {
    route("api") {
        runBlocking { productRoutes(dependencies.resolve(), dependencies.resolve()) }
    }
}
```

`dependencies.resolve()` is **suspend**, which is the whole cost of this option: inside `routing { }`
it needs `runBlocking`, and the dependencies are handed to the routing function as parameters —
there is no equivalent of Koin's `by inject()` inside a route. Context parameters
(`context(dependencies: DependencyRegistry)`, `-Xcontext-parameters`) are the alternative to
threading them, and they tax every new routing function.

One trap from the Koin side that does **not** reproduce here: `singleOf`-style reflection over
constructor parameters does not exist, because everything is assembled by hand in lambdas.

Schema changes are a list of SQL statements plus `PRAGMA user_version`, run under `runBlocking`
before the engine starts, and are only ever made by appending to the end of the list. A new service
is `native-service-bootstrap`'s subject, including the pool size and the journal.
