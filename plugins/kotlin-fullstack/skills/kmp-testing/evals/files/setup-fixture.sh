#!/usr/bin/env bash
# One fixture, three shapes. $1 is the directory to build in, $2 the case.
#
# Each shape is the code a test is about to be written for, and nothing else. Nothing here
# builds, and no case asks for a run: what is graded is the test that was written, or the
# commands that were named, and the reason given.
set -euo pipefail
dir="$1"; shape="${2:-derived-vm}"
mkdir -p "$dir"

case "$shape" in
  derived-vm)
    # A view model whose state is behind stateIn(WhileSubscribed): `.value` stays at the initial
    # value until something collects.
    src="$dir/composeApp/src/commonMain/kotlin/app/feature/accounts"
    mkdir -p "$src" "$dir/composeApp/src/commonTest/kotlin/app/feature/accounts"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

A Compose Multiplatform client: Android, iOS, desktop and wasmJs. `composeApp/src/commonTest`
compiles for every target. Test dependencies already present: kotlin-test, kotlinx-coroutines-test.
EOF
    cat > "$src/Accounts.kt" <<'EOF'
package app.feature.accounts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class Account(val id: Long, val name: String, val approved: Boolean)

interface AccountRepository {
    fun observeAccounts(): Flow<List<Account>>
    suspend fun refreshAccounts()
}

class ObserveAccountsUseCase(private val accounts: AccountRepository) {
    operator fun invoke(): Flow<List<Account>> = accounts.observeAccounts()
}

class RefreshAccountsUseCase(private val accounts: AccountRepository) {
    suspend operator fun invoke(): Result<Unit> = runCatching { accounts.refreshAccounts() }
}

data class AccountsUiState(val items: List<Account> = emptyList(), val total: Int = 0, val onlyApproved: Boolean = true, val loading: Boolean = false)

class AccountsViewModel(observeAccounts: ObserveAccountsUseCase, private val refreshAccounts: RefreshAccountsUseCase) : ViewModel() {
    private val onlyApproved = MutableStateFlow(true)
    private val loading = MutableStateFlow(false)

    val uiState: StateFlow<AccountsUiState> =
        combine(observeAccounts(), onlyApproved, loading) { accounts, only, busy ->
            AccountsUiState(accounts.filter { !only || it.approved }, accounts.size, only, busy)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), AccountsUiState(loading = true))

    init { viewModelScope.launch { loading.value = true; refreshAccounts(); loading.value = false } }

    fun showAll(all: Boolean) { onlyApproved.value = !all }
}
EOF
    ;;

  goldens)
    # A module with screenshot goldens, and a label that has just changed by a word.
    src="$dir/composeApp/src/commonMain/kotlin/app/checkout"
    mkdir -p "$src" "$dir/composeApp/src/desktopTest/snapshots" "$dir/composeApp/src/desktopTest/kotlin/app/checkout"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

Screenshot goldens live in `composeApp/src/desktopTest/snapshots` and are verified in CI on
Linux by `./gradlew :composeApp:viddikVerify`. The fixtures render with the bundled font.
EOF
    cat > "$dir/composeApp/build.gradle.kts" <<'EOF'
plugins {
    kotlin("multiplatform")
    id("org.jetbrains.compose")
    id("io.github.youndie.viddik") version "0.7.0"
}

kotlin { jvm("desktop") }

viddik {
    // The page fixtures are full screens; edge noise of the display face needed a wider share.
    tolerancePercent = 0.3
}
EOF
    cat > "$src/CheckoutBar.kt" <<'EOF'
package app.checkout

import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

@Composable
fun CheckoutBar(onBuy: () -> Unit = {}) {
    Button(onClick = onBuy) { Text("Buy now") }   // was "Buy" until this change
}
EOF
    cat > "$dir/composeApp/src/desktopTest/kotlin/app/checkout/CheckoutFixtures.kt" <<'EOF'
package app.checkout

import androidx.compose.runtime.Composable
import io.github.youndie.viddik.annotations.ViddikScreenshot

@ViddikScreenshot(name = "Bar", group = "Checkout", width = 390, height = 96)
@Composable
fun CheckoutBarFixture() = CheckoutBar()

@ViddikScreenshot(name = "Page", group = "Checkout", width = 390, height = 844)
@Composable
fun CheckoutPageFixture() = CheckoutPage()

@Composable
fun CheckoutPage() { /* the whole screen, with CheckoutBar at the bottom */ CheckoutBar() }
EOF
    : > "$dir/composeApp/src/desktopTest/snapshots/Checkout_Bar.png"
    : > "$dir/composeApp/src/desktopTest/snapshots/Checkout_Page.png"
    ;;

  money-storage)
    # A port, one implementation, and a column whose type is the thing worth guarding.
    src="$dir/server/src/main/kotlin/app/feature/order"
    mkdir -p "$src" "$dir/server/src/test/kotlin/app/feature/order" "$dir/server/src/main/resources/db/migration"
    cat > "$dir/CLAUDE.md" <<'EOF'
# fixture

A Ktor server on the JVM over PostgreSQL (JDBC, HikariCP, Flyway). Test dependencies already
present: kotlin-test, kotlinx-coroutines-test, Testcontainers' PostgreSQL module.
EOF
    cat > "$dir/server/src/main/resources/db/migration/V1__orders.sql" <<'EOF'
create table orders (
    id       text primary key,
    owner_id text not null,
    total    numeric(12, 2) not null
);
EOF
    cat > "$src/Orders.kt" <<'EOF'
package app.feature.order

import java.math.BigDecimal
import javax.sql.DataSource

data class Order(val id: String, val ownerId: String, val total: BigDecimal)

interface OrderRepository {
    suspend fun save(order: Order)
    suspend fun find(ownerId: String, id: String): Order?
}

class JdbcOrderRepository(private val dataSource: DataSource) : OrderRepository {
    override suspend fun save(order: Order) {
        dataSource.connection.use { c ->
            c.prepareStatement("insert into orders (id, owner_id, total) values (?, ?, ?)").use {
                it.setString(1, order.id); it.setString(2, order.ownerId); it.setBigDecimal(3, order.total); it.executeUpdate()
            }
        }
    }

    override suspend fun find(ownerId: String, id: String): Order? =
        dataSource.connection.use { c ->
            c.prepareStatement("select id, owner_id, total from orders where owner_id = ? and id = ?").use {
                it.setString(1, ownerId); it.setString(2, id)
                it.executeQuery().use { rows -> if (rows.next()) Order(rows.getString(1), rows.getString(2), rows.getBigDecimal(3)) else null }
            }
        }
}
EOF
    ;;

  *) echo "unknown shape: $shape" >&2; exit 2 ;;
esac
