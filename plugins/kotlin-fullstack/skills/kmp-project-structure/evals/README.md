# What this suite checks

Two cases, each a decision that looks like a preference and has a measured or paid-for answer.

| case | where it comes from |
|---|---|
| `hashing-is-not-an-expect` | the one rule that shapes the source sets. Every `expect/actual` pair is two implementations the compiler checks for signature and never for behaviour; a token signed by one and refused by the other shows up on the day of deployment. The reference project counts its pairs and hashing is not among them |
| `a-blocking-handler-decides-the-engine` | [the engine measurements](https://kotlin.website/blog/three-ktor-engines-under-one-protocol): Netty costs about half of CIO's CPU per request when handlers never block, and is the worst default when they do, because its call group defaults to the processor count |

## What an expectation is allowed to be

Both prompts carry a plan in the user's own words that is reasonable and wrong for this
fixture. What is graded is whether the answer changes the plan and can say why in terms a
reviewer can check — not whether it complies.

The fixtures do not build: no Gradle wrapper, and no case asks for a build.

## Not run yet

This suite has not been run: there is no baseline, and no evidence yet that an expectation can
fail. Run it once without the skill before trusting a green run with it.

`evals.json` follows the skill-creator shape, as the other suites in this repository do, and is
run by skill-creator's eval loop.
