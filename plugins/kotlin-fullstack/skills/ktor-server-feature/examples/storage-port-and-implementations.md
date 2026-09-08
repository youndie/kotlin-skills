# A storage port and its two implementations

The port lives in `server-common`, the implementations in the build modules. The classes differ;
the stored representation must not.

## The port and the record (`server-common`)

```kotlin
/**
 * A transaction as it lies in storage: with `categoryId`, not with the category itself.
 *
 * Categories are stored inside the user document, so a wire `Transaction` can only be assembled
 * knowing the owner's category list. The route does that: the repository returns the record, the
 * route substitutes the category.
 *
 * The type also exists so that `userId` need not be dragged into the client's `Transaction`: the
 * owner is a server-side notion and not part of the contract.
 */
data class TransactionRecord(
    val id: String,
    val amount: BigDecimalSerializable,
    val income: Boolean,
    val date: LocalDate,
    val until: LocalDate?,
    val period: Transaction.Period,
    val comment: String,
    val userId: String,
    val categoryId: String?,
)

fun TransactionRecord.toTransaction(userCategories: List<Category>): Transaction = Transaction(
    id = id, amount = amount, income = income, date = date, period = period, until = until,
    comment = comment,
    category = userCategories.find { it.id == categoryId } ?: Category.default,
)

interface TransactionRepository {
    suspend fun create(transaction: Transaction, userId: String): String
    suspend fun getByUser(userId: String): List<TransactionRecord>
    suspend fun getById(id: String): TransactionRecord?
    suspend fun update(transaction: Transaction, userId: String)
    suspend fun delete(id: String): Boolean
    suspend fun deleteByUser(userId: String)
}
```

## JVM implementation (`server`)

```kotlin
const val TRANSACTION_COLLECTION = "transaction"

data class TransactionDb(
    @BsonId val id: ObjectId,
    val amount: BigDecimal,          // java.math — the driver writes decimal128
    val income: Boolean,
    val date: String,
    val until: String?,
    val period: String,
    val comment: String,
    val userId: String,
    val categoryId: String?,
)

class MongoTransactionRepository(mongoDatabase: MongoDatabase) : TransactionRepository {
    private val db = mongoDatabase.getCollection<TransactionDb>(TRANSACTION_COLLECTION)

    override suspend fun create(transaction: Transaction, userId: String): String {
        val new = mapToDb(transaction, userId = userId)
        db.insertOne(new)
        return new.id.toHexString()
    }

    override suspend fun getById(id: String): TransactionRecord? =
        db.find(Filters.eq("_id", ObjectId(id))).firstOrNull()?.toRecord()

    override suspend fun getByUser(userId: String): List<TransactionRecord> =
        db.find(Filters.eq(TransactionDb::userId.name, userId)).toList().map { it.toRecord() }

    /**
     * The owner is part of the filter, not only a check in the route.
     *
     * The route already refuses a foreign record, but the condition here is the second line:
     * the next `update` call from another place is safe by default rather than because someone
     * remembered the check. A foreign document simply does not match — matchedCount is zero.
     */
    override suspend fun update(transaction: Transaction, userId: String) {
        val id = ObjectId(transaction.id)
        db.replaceOne(
            Filters.and(Filters.eq("_id", id), Filters.eq(TransactionDb::userId.name, userId)),
            mapToDb(transaction, id, userId),
        )
    }

    override suspend fun delete(id: String): Boolean = db.deleteById(id)
    override suspend fun deleteByUser(userId: String) { db.deleteMany(Filters.eq(TransactionDb::userId.name, userId)) }

    private fun mapToDb(transaction: Transaction, id: ObjectId = ObjectId(), userId: String) = TransactionDb(
        id = id, amount = transaction.amount.toJavaBigDecimal(), income = transaction.income,
        date = transaction.date.toString(), until = transaction.until?.toString(),
        period = transaction.period.name, comment = transaction.comment,
        userId = userId, categoryId = transaction.category.id,
    )

    private fun TransactionDb.toRecord() = TransactionRecord(
        id = id.toHexString(), amount = amount.toPlainString().toBigDecimal(), income = income,
        date = LocalDate.parse(date), until = until?.let(LocalDate::parse),
        period = Transaction.Period.valueOf(period), comment = comment, userId = userId, categoryId = categoryId,
    )
}
```

## Native implementation (`server-native`)

```kotlin
/** Collection names: the same as the JVM build's, both builds use one database. */
const val TRANSACTION_COLLECTION = "transaction"

/**
 * Documents as the JVM build writes them.
 *
 * What must match is the REPRESENTATION on disk, not the shape of the classes: both builds use
 * the same database, and a divergence here does not fail, it silently finds nothing. Two places
 * where that is easy to lose:
 *
 * * `_id` is an ObjectId, not a string. `@SerialName("_id")` gives the name, `StringAsBsonObjectId`
 *   the type. Without the first MongoDB invents its own _id and the field is stored as an ordinary
 *   one; without the second a filter on _id is sent as a string and matches no document;
 * * `amount` is decimal128. The shared BigDecimalSerializer from :shared writes a string because
 *   it was made for JSON; in BSON money has an exact type, and the JVM driver wrote exactly that.
 */
@Serializable
data class TransactionDb(
    @SerialName("_id")
    @Serializable(with = StringAsBsonObjectId::class)
    val id: String,
    @Serializable(with = BigDecimalAsBsonDecimal128::class)
    val amount: BigDecimal,
    val income: Boolean,
    val date: String,
    val until: String? = null,
    val period: String,
    val comment: String,
    val userId: String,
    val categoryId: String? = null,
)

/** Money as BSON decimal128: the type java.math.BigDecimal produces through the official driver. */
object BigDecimalAsBsonDecimal128 : KSerializer<BigDecimal> {
    override val descriptor = PrimitiveSerialDescriptor("BigDecimalAsBsonDecimal128", PrimitiveKind.STRING)

    override fun serialize(encoder: Encoder, value: BigDecimal) {
        val bson = encoder as? BsonEncoder ?: throw SerializationException("amount serialises to BSON only")
        bson.encodeBsonValue(BsonDecimal128(value.toPlainString()))
    }

    override fun deserialize(decoder: Decoder): BigDecimal {
        val bson = decoder as? BsonDecoder ?: throw SerializationException("amount reads from BSON only")
        val value = bson.decodeBsonValue()
        val text = (value as? BsonDecimal128)?.value ?: throw SerializationException("expected decimal128, got $value")
        return text.toBigDecimal()
    }
}

class MongknTransactionRepository(mongoDatabase: MongoDatabase) : TransactionRepository {
    private val db = mongoDatabase.getCollection<TransactionDb>(TRANSACTION_COLLECTION)

    override suspend fun create(transaction: Transaction, userId: String): String {
        val id = BsonObjectId.generate().hex
        db.insertOne(mapToDb(transaction, id, userId))
        return id
    }

    override suspend fun getById(id: String): TransactionRecord? =
        db.find { "_id" eq id }.firstOrNull()?.toRecord()

    /**
     * Same second line of defence as on the JVM.
     * `and(...)` instead of two pairs in one document: two conditions on the same field would
     * collide on the key, and the second would silently evict the first.
     */
    override suspend fun update(transaction: Transaction, userId: String) {
        db.replaceOne(
            filter = filter<TransactionDb> { and("_id" eq transaction.id, TransactionDb::userId eq userId) },
            replacement = mapToDb(transaction, transaction.id, userId),
        )
    }

    override suspend fun delete(id: String): Boolean = db.deleteOne(filter<TransactionDb> { "_id" eq id }).deletedCount > 0
    override suspend fun deleteByUser(userId: String) { db.deleteMany(filter<TransactionDb> { TransactionDb::userId eq userId }) }
    // mapToDb / toRecord as on the JVM, minus the java.math conversions
}
```

## The storage modules

```kotlin
// server (JVM)
fun mongoStorageModule(mongoConfig: MongoConfig): Module = module {
    single<MongoClient> { MongoClient.create(mongoConfig.connectionString) }
    single<MongoDatabase> { get<MongoClient>().getDatabase(mongoConfig.database) }
    single<StorageHealth> {
        val database = get<MongoDatabase>()
        StorageHealth { database.runCommand(Document("ping", 1)); true }
    }
    single { MongoUserRepository(get(), get()) }.bind<UserRepository>()
    single { MongoTokenRepository(get()) }.bind<TokenRepository>()
    single { MongoTransactionRepository(get()) }.bind<TransactionRepository>()
    single { MongoCategoryRepository(get()) }.bind<CategoryRepository>()
}

// server-native — one client per process: it owns the connection pool and its own thread pool
fun mongknStorageModule(mongoConfig: MongoConfig): Module = module {
    single<MongoClient> { MongoClient(mongoConfig.connectionString) }
    single<MongoDatabase> { get<MongoClient>().getDatabase(mongoConfig.database) }
    single<StorageHealth> {
        val database = get<MongoDatabase>()
        StorageHealth { database.runCommand(BsonDocument("ping" to BsonInt32(1))); true }
    }
    single { MongknUserRepository(get(), get()) }.bind<UserRepository>()
    single { MongknTokenRepository(get()) }.bind<TokenRepository>()
    single { MongknTransactionRepository(get()) }.bind<TransactionRepository>()
    single { MongknCategoryRepository(get()) }.bind<CategoryRepository>()
}
```
