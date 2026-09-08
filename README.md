# kotlin-skills

Claude Code skills for Kotlin full-stack work: Kotlin Multiplatform project structure, the
shared wire contract, Ktor servers compiled to the JVM and to Kotlin/Native, Compose Multiplatform
clients, the testing that holds all of it together, and the naming and abstraction conventions
underneath.

Every rule in these skills was paid for in
[mani](https://github.com/youndie/mani-kotlin-fullstack): a budget planner with a Compose client
for Android, iOS, desktop and the browser, one server compiled twice, and one contract module
shared by all of them. The skills describe what worked there and **why**, with the defect that
motivated each rule named next to it. Where a rule is specific to that product, the skill says so.

## Skills

| Skill | Use it when |
|---|---|
| [`kmp-project-structure`](plugins/kotlin-fullstack/skills/kmp-project-structure/SKILL.md) | starting a KMP project, adding a module or target, deciding where a class belongs, shaping packages |
| [`kmp-shared-contract`](plugins/kotlin-fullstack/skills/kmp-shared-contract/SKILL.md) | adding or changing an endpoint or a DTO; anything about how the client and the server talk |
| [`ktor-server-feature`](plugins/kotlin-fullstack/skills/ktor-server-feature/SKILL.md) | a route, a validation rule, a storage port and its per-build implementations, DI, auth, errors |
| [`compose-client-feature`](plugins/kotlin-fullstack/skills/compose-client-feature/SKILL.md) | a screen or feature on the client: repository, use case, view model, Component / Content, navigation, session |
| [`kmp-testing`](plugins/kotlin-fullstack/skills/kmp-testing/SKILL.md) | writing or placing any test; why a green build missed a bug |
| [`kotlin-conventions`](plugins/kotlin-fullstack/skills/kotlin-conventions/SKILL.md) | naming, abstractions, comments, code review |

How they relate:

```
kmp-project-structure  ──▶  kmp-shared-contract  ──▶  ktor-server-feature
        (modules)               (the wire)         ──▶  compose-client-feature
                                                          │
                                                          ▼
                                                     kmp-testing
              kotlin-conventions  (names, abstractions, comments — across all of the above)
```

Each skill starts with a "Step 0": read the project, and let the project's own conventions win
over the skill. The skills are for repositories that have no convention yet, or that are about
to grow a second platform and want to know which rules pay off before that.

## Install

As a plugin, from GitHub:

```bash
claude plugin marketplace add youndie/kotlin-skills
```

```bash
claude plugin install kotlin-fullstack@kotlin-skills
```

The skills then appear as `/kotlin-fullstack:<skill>` and trigger on their own when a task
matches.

Or without the plugin machinery, by linking each skill into your personal skills directory:

```bash
for s in plugins/kotlin-fullstack/skills/*; do ln -s "$(pwd)/$s" ~/.claude/skills/; done
```

## Layout

```
.claude-plugin/marketplace.json          the marketplace: one plugin
plugins/kotlin-fullstack/
  .claude-plugin/plugin.json
  skills/<name>/SKILL.md                 the skill (kept under ~300 lines)
  skills/<name>/examples/*.md            longer code, lifted from the reference project
  skills/<name>/references/*.md          build-file skeletons, grep checklists
```

## Conventions of this repository

- English throughout.
- A rule without a reason is not written down. Where the reason is a defect, the defect is
  described.
- Nothing here describes a particular machine. A quirk that does not reproduce in CI is not a
  rule.
- Code in `examples/` is trimmed from the reference project with comments translated; it is
  illustrative, not a library.

## License

MIT.
