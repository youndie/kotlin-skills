# What this suite checks

Two cases.

| case | where it comes from |
|---|---|
| `a-new-path-is-written-once` | the reason the contract module exists: a path or a DTO copied to the second side compiles after a rename and fails at run time, for a user. The shortcut the case invites — a string path in the client "so the shared module is not touched" — is the one the skill is written against |
| `two-refusals-under-one-status` | [haul](https://github.com/youndie/haul) B-115: the server answered `401` both for a guest on a customer's page and for a guest id it had never issued. The client recovered from every `401` by asking for a new guest, and a guest who opened `/checkout` by its address lost the cart under a prompt saying it would come along |

## What an expectation is allowed to be

Observable in the files written or in the answer. The second case checks both directions of the
fix on purpose: a client that stops replacing a guest altogether passes the bug report and breaks
the case the replacement was written for.

The fixtures do not build: no Gradle wrapper, and no case asks for a build.

## Not run yet

This suite has not been run: there is no baseline, and no evidence yet that an expectation can
fail. Run it once without the skill before trusting a green run with it.

`evals.json` follows the skill-creator shape, as the other suites in this repository do, and is
run by skill-creator's eval loop.
