# The HTTP client, session refresh and token storage

```kotlin
val networkModule = module {
    single<HttpClient> {
        HttpClient {
            install(Resources)
            install(ContentNegotiation) { json(Json { ignoreUnknownKeys = true; isLenient = true }) }
            install(Auth) {
                bearer {
                    // realm filters WWW-Authenticate challenges: refresh runs only for this realm.
                    realm = serverConfig.host
                    loadTokens { get<TokenRepository>().getToken() }
                    refreshTokens { refreshSession(get(), get()) { markAsRefreshTokenRequest() } }
                }
            }
            defaultRequest {
                contentType(ContentType.Application.Json)
                url {
                    protocol = if (serverConfig.scheme == "http") URLProtocol.HTTP else URLProtocol.HTTPS
                    host = serverConfig.host
                    serverConfig.port?.toIntOrNull()?.let { port = it }
                }
            }
        }
    }
}
```

```kotlin
/**
 * Exchanges the refresh token for a new pair.
 *
 * A function of its own rather than the body of `refreshTokens { }`: there it is checked only by
 * a live server; here by a mock engine, the same way everything else in this layer is checked.
 *
 * @param markAsRefreshRequest "this is the refresh request". A parameter because
 *   markAsRefreshTokenRequest() is a member of the refreshTokens scope and does not exist outside
 *   it. Without the mark the plugin would try to refresh the token for the refresh request itself — a loop.
 * @return the new pair, or null if the session could not be extended
 */
internal suspend fun refreshSession(
    httpClient: HttpClient,
    tokenRepository: TokenRepository,
    markAsRefreshRequest: HttpRequestBuilder.() -> Unit = {},
): BearerTokens? {
    val refreshToken = tokenRepository.getToken().refreshToken
    if (refreshToken.isNullOrEmpty()) return null

    val response = httpClient.post(AuthResource.Refresh()) {
        markAsRefreshRequest()
        setBody(RefreshParams(refreshToken))
    }

    // The server refused the token: the session is over, and that has to be SAID, not only recorded.
    // Previously the tokens were cleared and the body was read anyway — and a 401 has none. The
    // parse failed, and what surfaced was a network failure: "server unreachable" with a countdown
    // and three retries, with no way to the welcome screen.
    if (response.status == HttpStatusCode.Unauthorized) {
        tokenRepository.expire()
        return null
    }

    // Any other refusal is no reason to log out: a 500 on the server does not end a session.
    // Ktor stops retrying on null, the original request returns 401, and the screen shows the refusal.
    if (!response.status.isSuccess()) return null

    val tokens = response.body<Tokens>()
    tokenRepository.set(accessToken = tokens.accessToken, refreshToken = tokens.refreshToken)
    return tokenRepository.getToken()
}
```

```kotlin
interface TokenRepository {
    fun getToken(): BearerTokens
    fun set(accessToken: String = getToken().accessToken, refreshToken: String = getToken().refreshToken.orEmpty())
    fun observeToken(): StateFlow<BearerTokens>

    /**
     * The session ended without the person's doing: the server refused the refresh token.
     * An event, not state. Navigation must not subscribe to the token itself — that was done, and
     * every arrival of a token rebuilt the graph and reset the screen to the start destination.
     */
    val expired: Flow<Unit>

    /** Mark the session as over: clears the tokens and raises [expired]. */
    fun expire()
}

class TokenRepositoryCommon(private val storage: TokenStorage) : TokenRepository {
    private val token = MutableStateFlow(storage.load() ?: BearerTokens("", ""))

    /**
     * No replay: an expired session is news of one moment. With replay it would reach every new
     * subscriber, i.e. throw the person to the welcome screen on the next rebuild of the screen.
     */
    private val expiredEvents = MutableSharedFlow<Unit>(replay = 0, extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val expired: Flow<Unit> = expiredEvents.asSharedFlow()

    override fun getToken(): BearerTokens = token.value

    override fun set(accessToken: String, refreshToken: String) {
        token.value = BearerTokens(accessToken, refreshToken)
        storage.save(token.value)
    }

    override fun expire() {
        set("", "")
        expiredEvents.tryEmit(Unit)
    }

    override fun observeToken(): StateFlow<BearerTokens> = token.asStateFlow()
}
```

```kotlin
// commonMain
interface TokenStorage {
    fun load(): BearerTokens?
    fun save(bearerTokens: BearerTokens)
}

expect val authModulePlatform: Module

val authModule = module {
    single<TokenStorage> { TokenStorageCommon() }       // a no-op default for platforms without a store
    single<TokenRepository> { TokenRepositoryCommon(get()) }
    // Included AFTER the default on purpose: Koin keeps the last definition of a type, so the
    // platform's TokenStorage wins. Move this line above the default and every platform loses
    // its tokens on restart, silently.
    includes(authModulePlatform)
    singleOf(::LogoutUseCase)
    // Here, not in the sign-in screen's module: AuthViewModel is shared by sign-in and sign-up,
    // and an unregistered dependency would take down both screens, not one.
    singleOf(::StartDemoUseCase).bind<DemoUseCase>()
}

// androidMain
actual val authModulePlatform: Module = module {
    single<TokenStorage> { TokenStorageImpl(PreferenceManager.getDefaultSharedPreferences(get<Context>())) }
}

// wasmJsMain — localStorage: a single-page app without cookie sessions has nowhere better to put them
class TokenStorageImpl : TokenStorage {
    override fun load() = BearerTokens(
        window.localStorage[BearerTokens::accessToken.name].orEmpty(),
        window.localStorage[BearerTokens::refreshToken.name].orEmpty(),
    )
    override fun save(bearerTokens: BearerTokens) {
        window.localStorage[BearerTokens::accessToken.name] = bearerTokens.accessToken
        window.localStorage[BearerTokens::refreshToken.name] = bearerTokens.refreshToken.orEmpty()
    }
}
```

The server address, resolved at runtime where the platform can answer:

```kotlin
/** Where the client goes for the API — decided at launch, not at build. `null` means "nothing to say": the compiled-in default is used. */
expect fun platformServerConfig(): ServerConfig?

val serverConfig: ServerConfig by lazy { platformServerConfig() ?: currentServerConfig }

// wasmJs: the API lives where the page came from — the same process serves both.
actual fun platformServerConfig(): ServerConfig? {
    val location = window.location
    val host = location.hostname.ifEmpty { return null }
    return ServerConfig(name = "Origin", scheme = location.protocol.removeSuffix(":").ifEmpty { "http" }, host = host, port = location.port.ifEmpty { null })
}

// android: on a phone the address is set by the build; there is nothing to substitute it from.
actual fun platformServerConfig(): ServerConfig? = null
```
