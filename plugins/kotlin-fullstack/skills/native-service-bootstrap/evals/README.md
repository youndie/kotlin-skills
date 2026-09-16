# What this suite checks

Five cases, and **three of them are defects a real service hit** rather than behaviours somebody
thought a model might get wrong. That distinction is the whole design: an expectation invented at a
desk tends to describe the happy path, and the happy path is not where this skill's value is.

| case | where it comes from |
|---|---|
| `outbound-tls-decides-the-image` | the first service built from keel was a webhook relay. `ktor-client-cio` compiled, linked and resolved, and the first `https` request failed at runtime with *TLS sessions are not supported on Native platform* |
| `cancellation-is-not-swallowed` | the same service's forwarder had `runCatching { sweep() }` in its loop. sborka's rule set failed the build: cancelling the scope would have left it sweeping against a store the release stage was closing |
| `nothing-closes-in-applicationstopping` | the reason kore exists — `EmbeddedServer.stop` runs its steps in the opposite order on the two platforms, so the same source closes a pool before the drain on one and after it on the other |
| `native-service-block-before-the-targets` | the convention reads `entryPoint` when the target declares its binary, and a block placed after fails with a message naming neither the ordering nor the block |
| `health-is-not-readiness` | `/health` is an alias for liveness, so a chart pointing readiness there gets a probe that cannot fail while the process is alive |

## What an expectation is allowed to be

**Observable.** A route, a status, a file that exists, a line that does not, an ordering in a file.
"The service starts" is not checkable by a grader; "the readiness probe points at `/health/ready` and
not at `/health`" is.

Several expectations check that a **reason** appears, not only that code is right. That is deliberate
for a skill whose stated value is "gotchas already paid for": an agent that writes the right
dependency without knowing why will write the wrong one the next time the context shifts slightly.

## The fixtures are deliberately not keel

`setup-fixture.sh` builds the smallest context in which each decision is real — an empty directory, a
service that builds, or one interface. Handing the agent a finished keel would let it copy an answer
rather than reach one, and every case here is about a decision rather than a transcription.

Run them with `claude plugin eval` against this plugin.
