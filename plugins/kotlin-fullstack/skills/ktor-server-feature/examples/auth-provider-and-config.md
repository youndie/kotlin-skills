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
