# Review greps

Each command finds one class of violation from `kotlin-conventions`. Run from the repository
root; adjust module names to the project. A hit is a reason to look, not automatically a defect.

```bash
# Routes registered by a string path on the server, requests built from a string on the client (rule: the path exists once)
grep -rnE --include='*.kt' '\b(get|post|put|patch|delete|route)\("/' server*/src
grep -rnE --include='*.kt' '\.(get|post|put|patch|delete)\("' client*/src composeApp/src
```

```bash
# JUnit annotations nail a test to the JVM (rule: kotlin.test everywhere)
grep -rln --include='*.kt' 'import org.junit' .
```

```bash
# Mocking libraries in shared test suites (rule: fakes, and commonTest compiles for native)
grep -rln --include='*.kt' -E 'io\.mockk|org\.mockito' . | grep -E 'commonTest|linuxX64Test'
```

```bash
# runCatching in suspend code (rule: suspendRunCatching, cancellation passes through)
grep -rn --include='*.kt' -B3 'runCatching {' . | grep -E 'suspend|launch|withContext' -A3 | grep 'runCatching {' | grep -v suspendRunCatching
```

```bash
# catch (e: Exception) in suspend functions without a CancellationException rethrow above it
grep -rn --include='*.kt' 'catch (e: Exception)' . | while IFS=: read -r f n _; do
  sed -n "$((n-8)),$((n))p" "$f" | grep -q CancellationException || echo "$f:$n"
done
```

```bash
# expect declarations: count them and be able to name each one's platform API
grep -rn --include='*.kt' -E '^\s*expect (fun|val|class|object)' .
```

```bash
# Generic DI bindings without a qualifier (rule: generics are erased, bind by name)
grep -rn --include='*.kt' -E 'single<[A-Za-z]+<[A-Za-z]+>>\s*\{' .
```

```bash
# Constructors with default parameters registered via singleOf/factoryOf/viewModelOf
# (matches single-line constructors only; for multi-line ones read the class, the graph test is the real guard)
grep -rhn --include='*.kt' -oE '(singleOf|factoryOf|viewModelOf)\(::[A-Za-z]+' . | sed 's/.*::/::/' | sort -u | while read -r ref; do
  cls=${ref#::}
  grep -rn --include='*.kt' -E "class $cls\(" . | grep -E '= [^,)]+[,)]' && echo "  ^ $cls has a default parameter and is registered reflectively"
done
```

```bash
# Shared flows mutated in three steps (rule: update { })
grep -rn --include='*.kt' -E '\.value (\+|-)= ' .
```

```bash
# Mutable collection types in UiState classes (rule: immutable collections in states, a consistency preference)
grep -rn --include='*UiState.kt' -E 'val [a-zA-Z]+: (List|Map|Set)<' .
```

```bash
# Commas in backticked test names (Kotlin/Native rejects them at compile time)
grep -rn --include='*.kt' -E 'fun `[^`]*,[^`]*`' .
```

```bash
# Non-Latin text in code, build files and catalogs (rule: English in code)
grep -rnP '[\x{0400}-\x{04FF}]' --include='*.kt' --include='*.kts' --include='*.toml' --include='*.yml' .
```

```bash
# @Suppress without a reason string
grep -rn --include='*.kt' -A1 '@Suppress(' . | grep -E '@Suppress\("[^"]+"\)$'
```

```bash
# Workstation leaks: home paths, private IPs, Windows user paths
grep -rnE '(/Users/|/home/|C:\\Users\\|192\.168\.|10\.0\.)' --include='*.md' --include='*.kt' --include='*.kts' --include='*.yml' .
```
