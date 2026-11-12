#!/usr/bin/env bash
# One fixture, three shapes. $1 is the directory to build in, $2 the case.
#
# Each shape is the smallest client in which the decision the case is about is real: a domain
# layer that already exists, and no screen. Nothing here builds — there is no Gradle wrapper — and
# no case asks for a build: what is graded is the code that was written and the reason given.
set -euo pipefail
dir="$1"; shape="${2:-quotes}"
src="$dir/composeApp/src/commonMain/kotlin/app"
mkdir -p "$src/core"

cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

A Compose Multiplatform client (Android, iOS, desktop). Koin for DI, androidx.navigation,
kotlinx-coroutines. Features live in `composeApp/src/commonMain/kotlin/app/feature/<name>/{domain,data,ui}`.
EOF

cat > "$src/core/UseCase.kt" <<'EOF'
package app.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow

fun interface UseCase<in P, out T> { suspend operator fun invoke(params: P): Result<T> }
fun interface ObservableUseCase<in P, out R> { operator fun invoke(params: P): Flow<R> }

suspend fun <T> suspendRunCatching(block: suspend () -> T): Result<T> =
    try { Result.success(block()) } catch (e: CancellationException) { throw e } catch (e: Throwable) { Result.failure(e) }

sealed class AppError : Exception() {
    class NoNetwork : AppError()
    class Server(val code: Int) : AppError()
    class Unknown : AppError()
}

/** Text for the screen: a resource id or a literal, resolved in Compose. */
sealed interface UiText {
    data class Resource(val key: String) : UiText
    data class Literal(val value: String) : UiText
}
EOF

case "$shape" in
  quotes|quotes-loaded-once)
    # A screen whose every value is the answer to its own request. No flow anywhere in the domain.
    mkdir -p "$src/feature/ride/domain" "$src/feature/ride/ui"
    cat > "$src/feature/ride/domain/Ride.kt" <<'EOF'
package app.feature.ride.domain

import app.core.UseCase
import app.core.suspendRunCatching

enum class RideClass { ECONOMY, COMFORT, BUSINESS }

/** `pickupEtaSeconds` is null when no car of this class is near enough to name a wait. */
data class ClassQuote(val rideClass: RideClass, val priceCents: Long, val pickupEtaSeconds: Int?)
data class Journey(val fromLat: Double, val fromLon: Double, val toLat: Double, val toLon: Double)
data class Ride(val id: String)

interface RideRepository {
    suspend fun quote(journey: Journey): List<ClassQuote>
    suspend fun request(journey: Journey, rideClass: RideClass): Ride
}

class QuoteJourneyUseCase(private val rides: RideRepository) : UseCase<Journey, List<ClassQuote>> {
    override suspend fun invoke(params: Journey) = suspendRunCatching { rides.quote(params) }
}

class RequestRideUseCase(private val rides: RideRepository) : UseCase<RequestRideUseCase.Params, Ride> {
    override suspend fun invoke(params: Params) = suspendRunCatching { rides.request(params.journey, params.rideClass) }
    class Params(val journey: Journey, val rideClass: RideClass)
}
EOF
    if [ "$shape" = quotes-loaded-once ]; then
      # The screen exists and asks once, at start: the defect the case is about.
      cat > "$src/feature/ride/ui/ClassPickerViewModel.kt" <<'EOF'
package app.feature.ride.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.feature.ride.domain.ClassQuote
import app.feature.ride.domain.Journey
import app.feature.ride.domain.QuoteJourneyUseCase
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ClassPickerUiState(val loading: Boolean = true, val quotes: List<ClassQuote> = emptyList())

class ClassPickerViewModel(private val quoteJourney: QuoteJourneyUseCase, private val journey: Journey) : ViewModel() {
    private val _uiState = MutableStateFlow(ClassPickerUiState())
    val uiState: StateFlow<ClassPickerUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            quoteJourney(journey).onSuccess { quotes -> _uiState.update { it.copy(loading = false, quotes = quotes) } }
        }
    }
}
EOF
      cat > "$src/feature/ride/ui/ClassPickerScreen.kt" <<'EOF'
package app.feature.ride.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.koin.compose.viewmodel.koinViewModel

@Composable
fun ClassPickerScreen(viewModel: ClassPickerViewModel = koinViewModel()) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    ClassPickerContent(state)
}

@Composable
fun ClassPickerContent(state: ClassPickerUiState) { /* one row per class: price, wait, or "no cars nearby" */ }
EOF
    fi
    ;;

  accounts)
    # A screen with two sources that outlive it: a list the repository observes, and a preference
    # another screen edits.
    mkdir -p "$src/feature/accounts/domain" "$src/feature/settings/domain"
    cat > "$src/feature/accounts/domain/Accounts.kt" <<'EOF'
package app.feature.accounts.domain

import app.core.ObservableUseCase
import app.core.UseCase
import app.core.suspendRunCatching
import kotlinx.coroutines.flow.Flow

@JvmInline value class AccountId(val value: Long)
data class Account(val id: AccountId, val name: String, val balanceCents: Long, val currency: String)

interface AccountRepository {
    fun observeAccounts(): Flow<List<Account>>
    suspend fun refreshAccounts()
}

class ObserveAccountsUseCase(private val accounts: AccountRepository) : ObservableUseCase<Unit, List<Account>> {
    override fun invoke(params: Unit) = accounts.observeAccounts()
}

class RefreshAccountsUseCase(private val accounts: AccountRepository) : UseCase<Unit, Unit> {
    override suspend fun invoke(params: Unit) = suspendRunCatching { accounts.refreshAccounts() }
}
EOF
    cat > "$src/feature/settings/domain/DisplayCurrency.kt" <<'EOF'
package app.feature.settings.domain

import kotlinx.coroutines.flow.Flow

/** The currency amounts are shown in. Edited on the Settings screen. */
interface DisplayCurrencyRepository {
    fun observeCurrency(): Flow<String>
    suspend fun currentCurrency(): String
    suspend fun setCurrency(currency: String)
}
EOF
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
