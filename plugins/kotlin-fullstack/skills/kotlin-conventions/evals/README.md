# What this suite checks

Two cases.

| case | where it comes from |
|---|---|
| `a-review-finds-what-was-paid-for` | the review checklist. Every planted defect is a line of it, and each line is there because it happened: a tenant read from the body, a role compared by `ordinal` when declaration order was the opposite of privilege, a refusal log that printed the token, a cancelled coroutine surfacing as an error because of `runCatching`, a base state whose `setError()` erased the data on screen, a comma in a backticked test name that only the native compilation rejects |
| `a-dependency-is-not-an-expect` | the count of `expect/actual` pairs. The prompt proposes the wrong shape in the user's own words, which is how it arrives in practice; an `expect` for something a test wants to substitute is two implementations the compiler checks for signature and never for behaviour |

## What an expectation is allowed to be

The first case grades a **ranking** as well as a list. A review that reports the missing
`@Suppress` reason above the token in the log has found everything and understood nothing, and
the last expectation is there for that.

The second case grades a refusal of the prompt's own proposal, with its reason. An answer that
adds the `expect class` as asked is not wrong Kotlin; it is the answer this skill exists to
change.

The fixtures do not build: no Gradle wrapper, and no case asks for a build.

## Not run yet

This suite has not been run: there is no baseline, and no evidence yet that an expectation can
fail. Run it once without the skill before trusting a green run with it.

`evals.json` follows the skill-creator shape, as the other suites in this repository do, and is
run by skill-creator's eval loop.
