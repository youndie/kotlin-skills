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

## NUL in text does not survive the native driver

On Kotlin/Native sqlx4k hands a TEXT parameter to its Rust half as a C string, so **a bound value
holding NUL (U+0000) is cut at the NUL, silently**: `"before\u0000after"` is stored as `"before"`
and the statement succeeds. The JVM half binds through JDBC and stores all of it, so a suite that
runs only on the JVM never sees the difference. The same cut applies to a value in a `WHERE`
clause: an id with a NUL in it looks up whatever its prefix names.

**Reading a TEXT that holds NUL kills the process.** Every non-BLOB column crosses back as a C
string too, built with `CString::new(..).unwrap()`; a TEXT with a NUL in it — made by `char(0)`,
written by the JVM half or by any other client — panics there, and the library is built with
`panic = "abort"`, so there is no exception for a repository to catch. Plain text through the same
read is fine, and the JVM half returns `"before\u0000after"` whole.

So **refuse NUL at the API boundary** — `400` before anything is bound, for ids from a path or a
query string as well as for fields in a body — and **keep binary payloads in a BLOB**, which is
bound with its length and keeps every byte. Do not `CAST` a BLOB to TEXT in a `SELECT`: that hands
its NULs to the read above. Each of the three was checked with a probe against sqlx4k 1.13.1 on
`linuxX64` and on the JVM; the first was found by a webhook gateway (youndie/xyk#17).

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
