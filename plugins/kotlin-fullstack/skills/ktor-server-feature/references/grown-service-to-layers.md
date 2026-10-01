# Bringing a grown service to layers

Referenced from [SKILL.md](../SKILL.md). The target state is that file; this is the order of
getting there from a service written straight through, and the part that is easy to get wrong.

Each step is its own commit, with the suite green:

1. **A container and one binding**, routes untouched: one repository moves into `single<T>` /
   `provide<T>` and the composition root resolves it instead of constructing it. Every later one is
   then cheap.
2. **A `@Resource` on the best-documented endpoint.** Put the typed contract first where the
   document has already drifted from the code, or is about to: it is the one step that pays
   immediately.
3. **Extract the interface from the repository** — only once there is a second consumer or a second
   source of data. Against tests that run on a real database, an interface for its own sake does not
   pay for itself.
4. **Name the orchestration a use case.** In a service that grew this way it usually exists already,
   as a facade or a fat handler; this is a rename and a move, not new code.

A dependency that is still constructed by hand before DI starts enters the graph as a value, not as
a construction:

```kotlin
fun ordersModule(legacyPricing: PricingService) = module {
    single { legacyPricing }
    singleOf(::OrderRepositoryImpl).bind<OrderRepository>()
}
```

That is a temporary bridge, deleted when the other feature moves too — not an exception to the
architecture.

What not to do:

- **Do not rewrite everything at once.** Both styles coexist for a while. A large refactor has no
  green point in the middle; a per-feature migration has one after every step.
- **Do not start with interfaces.** The most visible layer and the cheapest in effect.
- **Do not call it "a refactor".** It is a migration towards a contract that is written down; with
  no target state on paper the work turns into taste.
