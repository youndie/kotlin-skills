---
name: product-brief
description: "Turn a product idea, a feature request or a rough conversation into the two briefs the rest of the pipeline consumes: a technical brief shaped like the docs-bootstrap layers (features with acceptance scenarios, screens with a fixed list of states, endpoints with auth tiers and errors, modules, decisions versus hypotheses, backlog seeds) and a designer brief that names every screen state as an artboard. Use for 'write a brief', 'ТЗ', 'technical specification', 'I have an idea for an app', 'plan this feature', 'brief for the designer', 'what should I give docs-bootstrap / Claude Design', or any conversation that has to end with something a documentation generator and a designer can both start from."
---

# From an idea to two briefs that agree with each other

What comes out is two documents, written from **one list of screens and states**:

```
conversation ──► technical brief ──► docs-bootstrap (research now; features / screens / api / services
                        │                             drafted in an open PR; the backlog)
                        └──► design brief ──► Claude Design canvas ──► design-to-compose
```

The technical brief is shaped like the documentation it will become, so the generator maps
sections to layers instead of guessing. The design brief is the same screens and states, named
the way the screenshot tooling will look for them (`<Screen>_<State>`), with the constraints a
canvas needs to be consumable (static artboards, fixed sizes, the app's font). Everything that
goes wrong later in the pipeline — an artboard for a state nobody documented, a fixture named
differently from its design, a scenario that describes a hope — is a disagreement between these
two documents, and the cheapest place to prevent it is here.

Boundaries: how the documentation tree is laid out and checked is `docs-bootstrap`; how a
canvas is turned into Compose is `design-to-compose`; module layout is `kmp-project-structure`.
This skill decides *what* gets built and states it once.

## Step 0. Take what the conversation already holds

Most of the brief is usually in the chat before the skill is invoked: the idea, who it is for,
the platforms, half the screens. Extract that first and put it in front of the user as a draft,
rather than opening with a questionnaire. Ask only what changes the shape of the work, and ask
it in one message, at most five questions:

1. **Greenfield or an existing repository?** In a repository, the brief describes a delta and
   every claim about existing behaviour is read out of the code, not remembered; the docs tree
   may already exist and the brief extends it.
2. **Platforms and form factors** — which of Android, iOS, desktop, web; phone and/or tablet.
   This decides the artboard sizes and whether there is a `screens/` layer at all.
3. **Who uses it, and are there tiers** — one user, several roles, several tenants. Tenancy
   changes every repository signature and every endpoint's auth column.
4. **What already exists that must be reused** — a design system, a backend, a contract, an
   auth provider. The design brief has to name the font and tokens; "we have a Figma" is a
   pointer the designer follows, "we have nothing" is a decision to record.
5. **What is out of scope for the first version**, stated by the user in their words.

Everything else is a default you take and say out loud in the brief's decisions table.

## Step 1. Fix the vocabulary before writing anything

One page, agreed with the user before the long documents:

- **Entities** — the nouns, each with what identifies it and who owns it (`Account`, id from the
  server, belongs to a `Client`). The names go into the code unchanged (`kotlin-conventions`),
  so pick them now and do not rename later.
- **Features** — verbs the user gets, `feature-<kebab>` ids. A feature is one document with
  several services in it, not one document per service.
- **Screens and their states** — the list the whole pipeline hangs on. Each screen has an id
  (`screen-<kebab>`), a Pascal-case name for the fixtures (`Checkout`), and a **closed list of
  states** with what is visible in each: `Loading`, `Empty`, `Content`, `Error`, plus the
  screen's own (`DeleteDialog`, `FiltersSheet`). A state is something a screenshot can show;
  "tapping a row" is a transition, not a state. The artboard, the reference PNG and the fixture
  will all be called `<Screen>_<State>`, so the names use letters, digits and underscores only.
- **Endpoints** — grouped by feature, `endpoint-<kebab>` ids, each with the tier that may call
  it (end user, bot, service-to-service) and the minimum role inside that tier. A screen that
  has no endpoint and an endpoint no screen calls are both findings.

A disagreement found here costs a sentence. The same disagreement found when the fixture
`Checkout_Empty` has no artboard costs a design round-trip.

## Step 2. Write the technical brief

Copy [templates/technical-brief.md](templates/technical-brief.md) and fill it in order. The rules
that keep it usable by the generator:

- **Verified and assumed are separated, explicitly.** A library, a version, an API's behaviour,
  a platform limit: either it was checked against the artefact (the registry listing, the
  documentation of the version being pinned, the code) and the brief says where, or it is
  labelled *hypothesis*. Memory is not a source; a greenfield brief has fewer facts than it
  feels like it has, and admitting that is the point of the decisions table.
- **Scenarios are written against intended behaviour and marked *target*.** They become the
  acceptance criteria of the feature documents and are verified against the real status codes
  and error strings before the docs pull request merges; a scenario that already names a
  status code in the brief is a design decision, not an observation, and the table says so.
- **Every screen's state list is the one from Step 1, verbatim.** Section 5 of the brief is
  what the design brief copies its artboards from and what the screen documents' section 1
  starts as; before a screen document goes `active`, docs-bootstrap re-reads the states from
  the real state class, and the code is then the authority. Until there is code, this table is
  what everything is held against.
- **Sample data is written once (§5a)**: the names, amounts and the fixed date that the
  scenarios, the artboards, the previews and the fixtures all show. Without it every one of
  those invents its own.
- **Endpoints carry a tier and their errors**, because the shared contract decides both once
  (`kmp-shared-contract`) and a brief that leaves them open leaves them to be decided twice.
- **Modules follow the project's layout skill**, named, not described: `shared` for the
  contract, `server` for the two builds, `composeApp` for the client — or the existing
  repository's names. What is new is listed; what exists is linked.
- **Backlog seeds are ordered by dependency**, whatever others compile against first, each with
  a priority, a size, a stage and the feature it belongs to — the fields a backlog item
  carries, and the stage table `backlog.md` will list. docs-bootstrap chooses the form by
  size (a milestone checklist for a small backlog, one file per item past a few dozen); a seed
  that cannot be phrased as an observable result is not ready to be an item. `blocked_by` names
  seeds only: a design that has to exist first is a seed of its own.

Write it to `research/brief-technical.md` in the repository when there is one, otherwise hand
it over as a document. It is a branch artefact in docs-bootstrap's sense: `research/*.md` is
what its guard refuses on the default branch, so the brief is **deleted before the branch
merges** — by then the research document holds the decisions, the open pull request holds the
drafted layers, and a brief that survived would describe intent as fact the day the first
scenario is corrected.

## Step 3. Write the design brief

`design-to-compose` carries the template with the reason behind each line:
[`../design-to-compose/references/design-brief.md`](../design-to-compose/references/design-brief.md).
One design brief per feature (the template is per feature, and a canvas page is per screen).
Fill its placeholders from the technical brief and nothing else:

- `<product>`, `<feature>` — from the header and the feature block.
- the design system, font and tokens — from the "what exists" answer. On a greenfield there is
  no "existing design system" and no screen document yet: replace the template's two phrases
  with "Material 3 colour and type roles, font `<family>` (§8)" and "the states in §5 of the
  technical brief", so the designer's colours are role names the theme can carry.
- **the artboard list** — every `<Screen>_<State>` from Section 5, grouped per screen with the
  one-line description of what is visible in that state, plus `<Screen>_<State>_Dark` for the
  states Section 5 declares dark variants for.
- **sizes** — the `Sizes` row of each screen in Section 5; `390×844` is the phone default and
  every other form factor is a number the interview produced, not one assumed here.
- **sample data** — §5a, verbatim, with the fixed date.

Write it to `research/brief-design-<feature>.md` next to the technical one, with the same
lifetime. It goes to the designer, or to Claude Design as the request; what comes back is a
canvas, and `design-to-compose` takes it from there.

## Step 4. Check the two against each other, then hand over

Before handing over, in one pass:

- [ ] every screen in the technical brief's Section 5 has an artboard group in the design brief, and every artboard stem in the design brief, `_Dark` stripped, is a state of that screen in Section 5 — same names
- [ ] every feature has at least one scenario, names its modules, and every scenario is marked *target*
- [ ] every screen names its platforms, an entry per platform, its parent feature, and at least one endpoint or an explicit "no API"
- [ ] every endpoint group names its contract class and service; every route has a tier, a minimum role and at least one error
- [ ] §5a has values for every entity the scenarios and screens mention, and a fixed date
- [ ] the decisions table has a *verified against* or *hypothesis* in every row; no bare claims about versions or library behaviour anywhere else
- [ ] backlog seeds are ordered so that nothing depends on a later item
- [ ] nothing private leaks: no internal hostnames, ticket ids or product names the user did not put in the brief

Then say, in a few lines, what to do with each document. The technical brief is research
material for `docs-bootstrap`, started in the repository with the brief in the tree: it writes
the research document from §8 and §10 now, drafts the feature, screen, endpoint and service
documents from §4–§7 in a pull request that stays open until the code gives them their anchors
(its WORKFLOW, phase 1), and seeds the backlog from §9. The design brief goes to the designer
or to Claude Design; the canvas link that comes back is where `design-to-compose` starts.

## What not to do

- **Do not write the documentation instead of the brief.** The brief is a page per layer, with
  ids and lists; the generator writes the documents, and every layer but research needs a path
  into the code to pass its check, which only exists once the code does.
- **Do not invent a state to make a screen look complete.** Four states is normal; a state the
  product does not have becomes an artboard, a fixture and a golden nobody wanted.
- **Do not describe screens in prose only.** A paragraph cannot be checked against a canvas; a
  state list can.
- **Do not decide the architecture in the brief beyond the module names.** Where a class goes
  is `kmp-project-structure`; how a use case is shaped is `ktor-server-feature`. The brief
  names the modules and the decisions that cross them (tenancy, auth, storage) and stops.
- **Do not leave a hypothesis looking like a fact** because the sentence reads better that way.
