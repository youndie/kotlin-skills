# Fakes, and tests of shared server code that run on both platforms

Lives in `server-common/src/commonTest`: it compiles for the JVM and for linuxX64, so nothing
JVM-only may enter.

```kotlin
class DemoSandboxCleanerTest {
    private val now = Instant.fromEpochSeconds(1_800_000_000)

    /** An ObjectId whose first four bytes are the given creation time. */
    private fun objectId(createdAt: Instant): String =
        createdAt.epochSeconds.toString(16).padStart(8, '0') + "0123456789abcdef"

    private fun user(name: String, createdAt: Instant) = User(id = objectId(createdAt), username = name)

    @Test
    fun `expired sandbox goes away with its transactions`() = runTest {
        val expired = user("demo-dead", now - DAY * 2)
        val users = FakeUserRepository(listOf(expired))
        val transactions = FakeTransactionRepository()

        DemoSandboxCleaner(users, transactions).sweep(now)

        assertTrue(users.stored.isEmpty())
        assertEquals(listOf(expired.id), transactions.deletedForUsers)
    }

    @Test
    fun `fresh sandbox stays`() = runTest {
        val fresh = user("demo-alive", now - HOUR)
        val users = FakeUserRepository(listOf(fresh))
        val transactions = FakeTransactionRepository()

        DemoSandboxCleaner(users, transactions).sweep(now)

        assertEquals(listOf(fresh), users.stored)
        assertTrue(transactions.deletedForUsers.isEmpty())
    }

    @Test
    fun `id that is not an ObjectId is left alone`() = runTest {
        // The age of such a record is unknown, and deleting on a guess is not allowed: a foreign
        // key format means the document was created by other code.
        val alien = User(id = "not-an-object-id", username = "demo-alien")
        val users = FakeUserRepository(listOf(alien))

        DemoSandboxCleaner(users, FakeTransactionRepository()).sweep(now)

        assertEquals(listOf(alien), users.stored)
    }

    private companion object {
        val HOUR = 1.hours
        val DAY = 24.hours
    }
}

// Private while one test uses them. When a second test needs them, they move to their own file
// in the same suite rather than being copied.
private class FakeUserRepository(initial: List<User>) : UserRepository {
    val stored = initial.toMutableList()
    var searchedPrefix: String? = null

    override suspend fun save(user: LoginParams): String? = null
    override suspend fun findUserByCredentials(credentials: LoginParams): User? = null
    override suspend fun findUserById(id: String): User? = stored.find { it.id == id }
    override suspend fun findByUsername(userName: String): User? = stored.find { it.username == userName }
    override suspend fun findByUsernamePrefix(prefix: String): List<User> {
        searchedPrefix = prefix
        return stored.filter { it.username.startsWith(prefix) }
    }
    override suspend fun delete(userId: String) { stored.removeAll { it.id == userId } }
}

private class FakeTransactionRepository : TransactionRepository {
    val deletedForUsers = mutableListOf<String>()

    override suspend fun create(transaction: Transaction, userId: String): String = ""
    override suspend fun getByUser(userId: String): List<TransactionRecord> = emptyList()
    override suspend fun getById(id: String): TransactionRecord? = null
    override suspend fun update(transaction: Transaction, userId: String) = Unit
    override suspend fun delete(id: String): Boolean = false
    override suspend fun deleteByUser(userId: String) { deletedForUsers += userId }
}
```

Validation is a pure function, so its boundaries are checked one by one:

```kotlin
/** Boundaries one at a time: a rule that refuses everything looks right on valid input too. */
class RulesTest {
    private val rule = Transaction(id = "", amount = "10".toBigDecimal(), income = false,
        date = LocalDate.parse("2026-09-08"), until = null, period = Transaction.Period.Month, comment = "Rent", category = Category.default)

    @Test
    fun anOrdinaryRulePasses() {
        assertNull(transactionProblem(rule))
        assertNull(transactionProblem(rule.copy(until = rule.date)))
    }

    /** Zero and minus are not pedantry: the sign comes from `income`, so an expense of −100 ADDS a hundred to the forecast. */
    @Test
    fun anAmountMustBePositive() {
        assertNotNull(transactionProblem(rule.copy(amount = "0".toBigDecimal())))
        assertNotNull(transactionProblem(rule.copy(amount = "-100".toBigDecimal())))
        assertNull(transactionProblem(rule.copy(amount = "0.01".toBigDecimal())))
    }

    @Test
    fun theProblemNamesWhatToFix() {
        assertEquals("Amount must be greater than zero", transactionProblem(rule.copy(amount = "0".toBigDecimal())))
    }
}
```
