# kotlin-skills

Claude Code skills for Kotlin full-stack work: Kotlin Multiplatform project structure, the
shared wire contract, Ktor servers compiled to the JVM and to Kotlin/Native, Compose Multiplatform
clients, the testing that holds all of it together, and the naming and abstraction conventions
underneath.

Two sources, plus one tool. The public source is [mani](https://github.com/youndie/mani-kotlin-fullstack): a
budget planner with a Compose client for Android, iOS, desktop and the browser, one server
compiled twice, and one contract module shared by all of them; its code is the reference for the
two-build mechanics, the contract and the platform plumbing. The larger patterns (use cases with
typed errors, tenancy and role tiers, derived view-model state) come from production services
and apps that are not public; they are described generically, with the defect that motivated
each rule named next to it. Where a rule is specific to one product, the skill says so.
The tool is [viddik](https://github.com/youndie/viddik), the screenshot-testing toolkit the
testing and design skills lean on; `design-to-compose` needs its `viddikDesignParity` task
(viddik 0.5.0 and later).
`product-brief` writes for [docs-bootstrap](https://github.com/youndie/docs-bootstrap), the
documentation format and checks the briefs are shaped for.

## Skills

| Skill | Use it when |
|---|---|
| [`product-brief`](plugins/kotlin-fullstack/skills/product-brief/SKILL.md) | turning an idea or a feature request into a technical brief for docs-bootstrap and a designer brief that agree on every screen and state |
| [`backlog-item`](plugins/kotlin-fullstack/skills/backlog-item/SKILL.md) | advancing a docs-bootstrap backlog one item per run, under `/loop`: pick by rule, implement with the matching skill, docs and status in the same PR |
| [`kmp-project-structure`](plugins/kotlin-fullstack/skills/kmp-project-structure/SKILL.md) | starting a KMP project, adding a module or target, deciding where a class belongs, shaping packages |
| [`kmp-shared-contract`](plugins/kotlin-fullstack/skills/kmp-shared-contract/SKILL.md) | adding or changing an endpoint or a DTO; anything about how the client and the server talk |
| [`ktor-server-feature`](plugins/kotlin-fullstack/skills/ktor-server-feature/SKILL.md) | a route, a validation rule, a storage port and its per-build implementations, DI, auth, errors |
| [`compose-client-feature`](plugins/kotlin-fullstack/skills/compose-client-feature/SKILL.md) | a screen or feature on the client: repository, use case, view model, Component / Content, navigation, session |
| [`design-to-compose`](plugins/kotlin-fullstack/skills/design-to-compose/SKILL.md) | implementing a screen from a Claude Design canvas or design PNGs and proving it matches: reference PNGs, tokens, fixtures, `viddikDesignParity`, the diff loop |
| [`kmp-testing`](plugins/kotlin-fullstack/skills/kmp-testing/SKILL.md) | writing or placing any test; why a green build missed a bug |
| [`kotlin-conventions`](plugins/kotlin-fullstack/skills/kotlin-conventions/SKILL.md) | naming, abstractions, comments, code review |

How they relate:

```
product-brief  ──▶  docs-bootstrap (documentation tree, backlog)  ──▶  backlog-item, under /loop
      └──▶  design brief  ──▶  Claude Design canvas  ──▶  design-to-compose      (one item → one PR, with the skills below)

kmp-project-structure  ──▶  kmp-shared-contract  ──▶  ktor-server-feature
        (modules)               (the wire)         ──▶  compose-client-feature  ◀──  design-to-compose
                                                          │                          (canvas → reference PNGs → parity loop)
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
matches. If you already have personal skills with the same names, the plugin namespace keeps
them apart, but Claude picks between two matching descriptions by description alone; retire or
rename the older one.

Or without the plugin machinery, by linking each skill into your personal skills directory:

```bash
for s in plugins/kotlin-fullstack/skills/*; do ln -s "$(pwd)/$s" ~/.claude/skills/; done
```

## Layout

```
.claude-plugin/marketplace.json          the marketplace: one plugin
plugins/kotlin-fullstack/
  .claude-plugin/plugin.json
  skills/<name>/SKILL.md                 the skill (kept under ~400 lines)
  skills/<name>/examples/*.md            longer code, lifted from the reference project
  skills/<name>/references/*.md          build-file skeletons, grep checklists
  skills/<name>/scripts/*.mjs            small dependency-free tools a skill runs (node)
  skills/<name>/templates/*.md           documents a skill fills in
```

## Conventions of this repository

- English throughout.
- A rule without a reason is not written down. Where the reason is a defect, the defect is
  described.
- Nothing here describes a particular machine. A quirk that does not reproduce in CI is not a
  rule.
- Code in `examples/` is either trimmed from the reference project with comments translated, or
  written for this repository in a fictional domain; each file says which. It is illustrative,
  not a library, and assumes Kotlin 2.2+, Ktor 3.x, Koin 4.x.

## License

MIT.
