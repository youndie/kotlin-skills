# Navigation: a graph built once, explicit transitions, expiry as an event

```kotlin
enum class ManiScreen { Preload, Main, History, Add, Transaction, Welcome, Login, Signup }

/**
 * Screens there is nowhere to go back from: roots, not steps of a path.
 * The main screen after sign-in is such a root, and the back arrow on it lied: behind it was the
 * welcome screen, which cannot be returned to — pressing only removed the arrow.
 */
private val rootScreens = setOf(ManiScreen.Preload, ManiScreen.Main, ManiScreen.Welcome)

/** One entry in the stack is not enough: under a root screen anything may remain (a rebuilt graph, a browser history entry). */
fun shouldShowBack(screen: ManiScreen, hasPrevious: Boolean): Boolean = hasPrevious && screen !in rootScreens

@Serializable
class TransactionRoute(val id: String)
```

```kotlin
/**
 * A NavHost whose graph is assembled once.
 *
 * The ordinary NavHost rebuilds the graph when the builder lambda changes, and installing a new
 * graph resets navigation to the start destination. The lambda captures everything it sees, so it
 * becomes new on any recomposition of the parent — for example when the app bar changes its title.
 * In the app this looked like: sign-in went to the main screen, and the very next recomposition
 * returned to the welcome screen. Screens inside recompose as usual: the graph is frozen, not their content.
 */
@Composable
fun StableNavHost(
    navController: NavHostController,
    startDestination: String,
    modifier: Modifier = Modifier,
    builder: NavGraphBuilder.() -> Unit,
) {
    val graph = remember { navController.createGraph(startDestination = startDestination, builder = builder) }
    NavHost(navController = navController, graph = graph, modifier = modifier)
}

fun NavController.navigateAndClean(route: String) {
    navigate(route = route) { popUpTo(graph.startDestinationRoute!!) { inclusive = true } }
    graph.setStartDestination(route)
}
```

```kotlin
@Composable
fun ManiAppNavHost(navController: NavHostController, appBarState: MainAppBarState, snackbarHostState: SnackbarHostState, onBackClicked: () -> Unit) {
    val tokenRepository = koinInject<TokenRepository>()

    // The token is read ONCE and without a subscription: it only decides which screen to start from.
    // A subscription rebuilt the graph on every arrival of a token (sign-in, sandbox, logout) and
    // silently threw the screen elsewhere. Transitions are made explicitly below.
    val startDestination = remember {
        val authorized = tokenRepository.observeToken().value.refreshToken?.isNotEmpty() == true
        if (authorized) ManiScreen.Main.name else ManiScreen.Welcome.name
    }

    // The session may have ended without the person's doing: the server refused the refresh token.
    // Without this the screen stayed on the main page showing "server unreachable" with a countdown —
    // offering to wait for something not worth waiting for. A subscription to the EVENT, not to the token.
    LaunchedEffect(Unit) {
        tokenRepository.expired.collect {
            if (navController.currentDestination?.route != ManiScreen.Welcome.name) {
                navController.navigateAndClean(ManiScreen.Welcome.name)
            }
        }
    }

    StableNavHost(navController, startDestination, Modifier.fillMaxSize()) {
        composable(ManiScreen.Main.name) {
            MainComponent(
                appBarState, snackbarHostState,
                onTransactionClicked = { navController.navigate(TransactionRoute(it)) },
                onAddTransactionClicked = { navController.navigate(ManiScreen.Add.name) },
                onLoggedOut = { navController.navigateAndClean(ManiScreen.Welcome.name) },
            )
        }
        composable(ManiScreen.Welcome.name) {
            WelcomeComponent(
                appBarState,
                onSignInClicked = { navController.navigate(ManiScreen.Login.name) },
                // The welcome screen leaves the stack and the graph's start destination moves to main —
                // otherwise a later logout would look for something no longer in the stack.
                onSuccess = { navController.navigateAndClean(ManiScreen.Main.name) },
            )
        }
        composable(ManiScreen.Add.name) { AddTransactionComponent { navController.popBackStack() } }
        composable<TransactionRoute> { entry ->
            EditTransactionComponent(entry.toRoute<TransactionRoute>()) { navController.popBackStack() }
        }
    }
}
```

The test that keeps the graph stable (`commonTest`, runs on desktop, wasm and iOS):

```kotlin
@Test
fun graphIsBuiltOnce() = runComposeUiTest {
    var builds = 0
    var tick by mutableStateOf(0)

    setContent {
        val controller = rememberNavController()
        Text("tick $tick")   // a state read above the nav host: its change recomposes this spot, as the app bar does
        StableNavHost(navController = controller, startDestination = "welcome") {
            builds++
            composable("welcome") { Text("welcome screen") }
            composable("main") { Text("main screen") }
        }
    }

    assertEquals(1, builds)
    // awaitIdle, not waitForIdle: in the browser everything shares one event loop, and a blocking
    // waitForIdle spins in it and prevents the very work it waits for.
    tick++; awaitIdle()
    tick++; awaitIdle()
    assertEquals(1, builds, "the graph was rebuilt — navigation will reset to the start destination")
}
```
