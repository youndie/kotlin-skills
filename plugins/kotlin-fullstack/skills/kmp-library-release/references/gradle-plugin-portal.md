# A Gradle plugin: the Plugin Portal, and the marker

A consumer asks for a plugin by id — `plugins { id("io.github.youndie.zavarnik") version "0.1.0" }` —
and Gradle resolves that id through a **marker**, a POM-only artefact at
`<id>:<id>.gradle.plugin:<version>` that points at the jar. With no repository declared in
`pluginManagement`, the only place Gradle looks is the Plugin Portal. Two routes follow:

| route | the consumer writes | used by |
|---|---|---|
| Plugin Portal, through `portal.yaml` | nothing beyond the `plugins { }` line | zavarnik |
| Maven Central, through `central.yaml`, marker included | `mavenCentral()` **in `pluginManagement`** as well as in `dependencyResolutionManagement` | viddik |

**The Portal is the default for a plugin of ours**, because it is the route that asks nothing of the
consumer. The Central route works, and costs a
line every consumer has to know to write: viddik's README opens its setup with "`mavenCentral()` in
both blocks" (viddik `README.md`), because without it the marker is looked for where it is not.

## What the repository does

* applies `com.gradle.plugin-publish` **itself**, in the plugin module, with `website`, `vcsUrl`, and
  `displayName` / `description` / `tags` per plugin. sborka's conventions deliberately do not: the
  metadata is the repository's own, and a convention that put the portal plugin on every consumer's
  classpath would pay for one repository on all of them (sborka `docs/conventions.md`);
* sets `sborka.portal=true` in `gradle.properties` — `portal.yaml` refuses a tree without it, so a
  missing task does not read as a typo in the workflow;
* takes its version from `-PVERSION`, like snapshots and Central.

Then: tag, and `gh workflow run portal.yaml -R youndie/sborka -f repository=youndie/<name> -f ref=vX.Y.Z -f version=X.Y.Z`.
The workflow runs the repository's `check`, then `publishPlugins --validate-only`, then the upload.

**Nothing is staged.** Unlike `central.yaml`, which leaves a deployment for a person to read and
release, `portal.yaml` publishes: for an approved plugin the version is live when the run ends, and
it cannot be replaced. So the irreversible step is the dispatch, and the look comes before it — the
tag names the commit you mean, `check` is green on it, the version is the one you mean (snapshots
`X.Y.Z.N` of the plugin already exist, and the release must sort where you expect).

## What was found on the first release (zavarnik 0.1.0)

* **`--validate-only` needs the key before it checks anything**, so the portal's metadata checks
  cannot be run locally without the secret; the first time they run is the real run.
* **The first version of a new plugin is approved by hand**, usually within days, by email. Until
  then the plugin page answers an error, the id resolves for nobody, and the sborka run is green —
  it uploaded. Later versions of an approved plugin are live at once. A version, once live, cannot
  be replaced.
* **The portal shows configuration-cache compatibility, and Gradle 9.7 writes it as `UNDECLARED`**
  into `META-INF/gradle-plugins/<id>.properties` with no DSL to change it. zavarnik rewrites the
  generated descriptor in a `doLast` on `pluginDescriptors` to `DECLARED_SUPPORTED`, the value
  plugin-publish's own descriptor carries — and it is true only because its tests run with
  `--configuration-cache` (zavarnik `zavarnik-gradle-plugin/build.gradle.kts`).
* **`io.github.<login>` as the id prefix** was accepted without question for the account with that
  GitHub login.
* **The head moves before the next release**: snapshots `0.1.0.N` sort above `0.1.0`.

## The marker takes its group from the id

The marker's groupId **is the plugin id**, not the project's group. Changing `sborka.group` moves the
jar and leaves the marker where it was: viddik's move to `io.github.youndie.viddik` showed, in a
dry `publishToMavenLocal`, the marker still under the old namespace — exactly the one the move was
leaving. Moving the marker means moving the id, which changes the consumer's `plugins { }` line, so
a group migration of a repository with a plugin is a breaking release, not a property edit. Check it
in the local tree: the marker directory is visible there under its own name.

## A plugin depends on other plugins

A published plugin that applies another plugin (ktlint-gradle, say) pulls that one from the Portal,
where Central does not have it. proba's consumer build declares the Portal for this reason; a
consumer that cannot apply the plugin without it does not exist, and modelling one would report
the harness, not the plugin.

## Verify

* `https://plugins.gradle.org/plugin/<id>` lists the version (after approval, for a first one);
* an empty build with only the default `pluginManagement` applies the plugin by id and runs one of
  its tasks — not "the marker resolved", which a marker without its jar also does.
