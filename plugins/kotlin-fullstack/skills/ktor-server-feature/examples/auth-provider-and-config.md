# A bearer provider of your own, a shared auth service, and configuration from ENV

## The provider (replaces the JVM-only `ktor-server-auth-jwt`)

```kotlin
/**
 * Bearer verification of our own instead of ktor-server-auth-jwt.
 * The Ktor plugin depends on com.auth0:java-jwt and exists on the JVM only. This is the same
 * behaviour on top of TokenService: an invalid or expired token yields 401 with the same text
 * as before, not 500 and not an empty answer.
 */
class ManiJwtProvider internal constructor(config: Config) : AuthenticationProvider(config) {
    private val tokenService = config.tokenService

    override suspend fun onAuthenticate(context: AuthenticationContext) {
        val header = context.call.request.parseAuthorizationHeader()
        val token = (header as? HttpAuthHeader.Single)
            ?.takeIf { it.authScheme.equals("Bearer", ignoreCase = true) }
            ?.blob

        // Access specifically: a refresh token lives a month and sits in the database; it opens no door here.
        val claims = token?.let { tokenService.verify(it, TokenKind.Access) }
        if (claims != null) {
            context.principal(ManiPrincipal(id = claims.id, username = claims.username))
            return
        }

        context.challenge(CHALLENGE_KEY, AuthenticationFailedCause.InvalidCredentials) { challenge, call ->
            call.respond(HttpStatusCode.Unauthorized, "Token is not valid or has expired")
            challenge.complete()
        }
    }

    class Config internal constructor(name: String, internal val tokenService: TokenService) :
        AuthenticationProvider.Config(name)

    internal companion object { const val CHALLENGE_KEY = "ManiJwtAuth" }
}

fun AuthenticationConfig.maniJwt(name: String, tokenService: TokenService) {
    register(ManiJwtProvider(ManiJwtProvider.Config(name, tokenService)))
}
```

## The auth service — an ordinary class in `commonMain`

```kotlin
/**
 * Sign-in and token refresh.
 * An ordinary class in the common part, no expect/actual: nothing here is platform-specific;
 * the whole difference between builds hides behind TokenService and the repositories.
 */
class AuthService(
    private val userRepository: UserRepository,
    private val tokenRepository: TokenRepository,
    private val tokenService: TokenService,
) {
    suspend fun authenticate(loginRequest: LoginParams): Tokens? {
        val foundUser = userRepository.findUserByCredentials(loginRequest) ?: return null
        return newTokens(foundUser).also { tokens ->
            tokenRepository.addToken(userId = foundUser.id, token = tokens.refreshToken)
        }
    }

    suspend fun refreshToken(refreshToken: String): Tokens? {
        val claims = tokenService.verify(refreshToken, TokenKind.Refresh) ?: return null

        // The signature is not enough: the presented refresh token must also be in the database.
        // Otherwise a revoked token would keep working until it expires.
        val foundUser = tokenRepository.findUserByToken(refreshToken) ?: return null
        if (claims.username != foundUser.username) return null

        tokenRepository.removeToken(refreshToken, foundUser.id)
        return newTokens(foundUser).also { tokenRepository.addToken(token = it.refreshToken, userId = foundUser.id) }
    }

    private suspend fun newTokens(user: User): Tokens = Tokens(
        accessToken = tokenService.issue(user.id, user.username, TokenKind.Access),
        refreshToken = tokenService.issue(
            user.id, user.username, TokenKind.Refresh,
            expiration = Clock.System.now().plus(1, DateTimeUnit.MONTH, TimeZone.currentSystemDefault()),
        ),
    )
}
```

Two claims worth copying into any token service: a `kind` claim (access vs refresh), because
without it a refresh token is accepted everywhere an access token is expected and the access
lifetime means nothing; and a random `jti`, because `exp` is stored in seconds and two tokens
issued in the same second would otherwise be byte-identical, making rotation illusory.

## Configuration

```kotlin
/**
 * Server configuration from environment variables, identically on both builds.
 * HOCON is read by JVM-only Ktor code, so the native build cannot use it. The variable names are
 * the ones the deployment manifest already used, so the two builds' configuration converges.
 */
data class ManiConfig(
    val port: Int,
    val mongo: MongoConfig,
    val jwt: JWTConfig,
    /** Directory with the built web app. Empty: no static files are served (handy in tests). */
    val webRoot: String?,
    val development: Boolean,
) {
    companion object {
        fun fromEnv(): ManiConfig = ManiConfig(
            port = readEnv("PORT")?.toIntOrNull() ?: 8080,
            mongo = MongoConfig(
                userName = readEnv("MONGO_USERNAME").orEmpty(),
                password = readEnv("MONGO_PASSWORD").orEmpty(),
                host = readEnv("MONGO_HOST") ?: "localhost",
                database = readEnv("MONGO_DATABASE") ?: "mani",
            ),
            jwt = JWTConfig(
                name = readEnv("JWT_NAME") ?: "auth-jwt",
                secret = signingSecret(readEnv("JWT_SECRET")),
                audience = readEnv("JWT_AUDIENCE") ?: "jwt-audience",
                issuer = readEnv("JWT_ISSUER") ?: "jwt-issuer",
                expirationSeconds = readEnv("JWT_EXPIRATION_SECONDS")?.toLongOrNull() ?: 3600L,
            ),
            webRoot = readEnv("MANI_WEB_ROOT"),
            development = readEnv("MANI_DEVELOPMENT")?.toBooleanStrictOrNull() ?: false,
        )
    }
}

/**
 * The signing secret: from the environment, or random for this process.
 *
 * The previous default was the string "secret", and docker-compose from the README never set the
 * variable: anyone who brought the stand up by the instructions signed tokens with a value printed
 * in the sources. Failing without the variable would be most honest, but it would break
 * `docker compose up` for a benefit a local instance does not have. A random secret keeps the
 * instance working and makes the price visible: a restart logs everyone out, and the line says why.
 *
 * A function of the value rather than `?:` inside fromEnv(): the decision is checked by value in a
 * test, not by the environment of the machine the test runs on.
 */
internal fun signingSecret(fromEnvironment: String?): String {
    if (fromEnvironment != null) return fromEnvironment
    println("JWT_SECRET is not set — tokens are signed with a random per-process secret. A restart logs everyone out.")
    return CryptographyRandom.nextBytes(32).toHex()
}

data class MongoConfig(
    val userName: String = "",
    val password: String = "",
    val host: String = "",
    /** A field, not a constant: tests work in a database of their own. */
    val database: String = "mani",
) {
    /** Credentials are escaped: a password with `@` or `:` otherwise breaks the URL and connects elsewhere. */
    val connectionString: String get() = when {
        userName.isEmpty() -> "mongodb://$host/?w=majority&appName=Mani"
        else -> "mongodb://${userName.encodeURLParameter()}:${password.encodeURLParameter()}@$host/?w=majority&appName=Mani"
    }
}

/** No java.* in commonMain and System.getenv is JVM-only: hence expect/actual. */
expect fun readEnv(name: String): String?

// jvmMain
actual fun readEnv(name: String): String? = System.getenv(name)

// linuxX64Main
@OptIn(ExperimentalForeignApi::class)
actual fun readEnv(name: String): String? = getenv(name)?.toKString()
```


## Configuration, the other two shapes

### Typed HOCON properties on a JVM-only service

```kotlin
// application.conf holds no values of its own: every field is a ${?ENV} substitution
private fun Application.configModule() = module {
    single<MongoConfig> { property<MongoConfig>("ktor.mongo") }
    single<ServiceEndpoints> { property<ServiceEndpoints>("ktor.serviceEndpoints") }
    single<ReservesConfig> { property<ReservesConfig>("ktor.reserves") }
}
```

### ENV through a testable source, on a two-build service

```kotlin
/**
 * Variable names must equal the ones application.conf used, to the letter: the chart already
 * sets them, and both builds must read the same thing. Diverging names would mean switching the
 * image silently changes configuration — the worst kind of rollback.
 */
class ServiceConfig(private val env: EnvSource = EnvSource.Process) {
    val port: Int get() = env.intOrNull("PORT") ?: 8080
    val environment: String get() = env.optional("ENVIRONMENT", "local")
    val mongo: MongoConfig get() = MongoConfig(user = env.optional("MONGO_USER"), password = env.optional("MONGO_PASSWORD"), host = env.optional("MONGO_HOST"))

    /** Required: it signs the handoff token. The service never started without it, and it must not start now. */
    val handoff: HandoffConfig get() = HandoffConfig(secret = env.required("HANDOFF_SECRET"))

    /** null when the key is unset: the gate is closed, and a local run sends nothing anywhere. */
    val reporter: ReporterConfig? get() = env["REPORTER_KEY"]?.takeIf { it.isNotBlank() }?.let { ReporterConfig(it, env.optional("REPORTER_HOST", DEFAULT_HOST), environment) }

    /** The running image's version: one value for /version, the deploy marker and the reporter's release. Read here, not inside the reporter config, or a disabled reporter also loses the version for everyone else. */
    val release: String? get() = env.optional("APP_VERSION").ifBlank { null }

    val corsExtraHosts: List<String> get() = env.optional("CORS_EXTRA_HOSTS").split(',').map { it.trim() }.filter { it.isNotEmpty() }
}

// in a test
val config = ServiceConfig(EnvSource.of(mapOf("HANDOFF_SECRET" to "test", "MONGO_HOST" to "127.0.0.1:27017")))
```

### Secrets without defaults, validated in the constructor

```kotlin
data class ProviderConfig(
    val issuer: String,
    val publicPort: Int,
    val managementPort: Int,
    val masterKeys: List<String>,          // the first encrypts; the rest are accepted during a rotation
    val bootstrapToken: String? = null,
) {
    /** When none is given, a random one for this run, generated HERE so every way of starting behaves the same. */
    val effectiveBootstrapToken: String = bootstrapToken?.takeIf { it.isNotBlank() } ?: Secrets.generate()

    init {
        require(issuer.isNotBlank()) { "issuer is required" }
        require(managementPort != publicPort) { "the management contour must live on a separate port, or it cannot be closed off" }
        require(masterKeys.isNotEmpty() && masterKeys.none { it.isBlank() }) { "MASTER_KEYS is required: at least one non-empty key" }
    }
}

private fun required(name: String): String = optional(name) ?: error(
    "Environment variable $name is required. Secrets deliberately have no defaults: " +
        "a default for a secret is a way to reach production with a default secret.",
)
```

## A test-only auth shim, kept in production code and fenced

```kotlin
/**
 * Lets automation act as an existing user without OAuth — ONLY on the test environment.
 * Active only when ENVIRONMENT == "test" AND a secret is configured (production has none, so the
 * shim is off entirely); every request carries the secret in a header, compared in constant time;
 * the user is an existing id, resolved by lookup — no creation, no call to another service.
 */
data class TestAuthConfig(val enabled: Boolean, val secret: String)

fun ApplicationRequest.testShimUserId(config: TestAuthConfig): String? {
    if (!config.enabled) return null
    val provided = header("X-Test-Secret") ?: return null
    if (!constantTimeEquals(provided, config.secret)) return null
    return header("X-Test-User")?.takeIf { it.isNotBlank() }
}
```

With the shim, `authenticate(JWT, optional = testAuthConfig.enabled)` lets a request without a
bearer reach the access helper, where the shim resolves the user; on production `optional` is
false and nothing changes.
