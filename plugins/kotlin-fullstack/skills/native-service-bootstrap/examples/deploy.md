# Example: the image, publishing, the chart

Everything below is taken from a running [metrik](https://github.com/youndie/metrik), not invented. Names are
replaced with `<name>`.

## Dockerfile: the binary from outside, static files pre-compressed

```dockerfile
# The native binary: no JVM, no runtime in the image. It is built outside (CI on a linux runner) and
# only copied in here — building Kotlin/Native inside docker would take tens of minutes.
FROM debian:bookworm-slim AS web

RUN apt-get update \
 && apt-get install -y --no-install-recommends gzip \
 && rm -rf /var/lib/apt/lists/*

COPY composeApp/build/dist/wasmJs/productionExecutable/ /web/

# Compressed once here rather than on every request: there is no compression plugin for
# Kotlin/Native, so the server serves a ready .gz sitting next to the file.
RUN find /web -type f \( -name '*.js' -o -name '*.wasm' -o -name '*.html' -o -name '*.css' \
      -o -name '*.json' -o -name '*.svg' \) -exec gzip -k9 {} +

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY server/build/bin/linuxX64/releaseExecutable/server.kexe /usr/local/bin/<name>
COPY --from=web /web /usr/share/<name>/web

# The database is one file; its directory has to be a persistent volume.
VOLUME ["/data"]
ENV <NAME>_DB_PATH=/data/<name>.db
ENV <NAME>_WEB_ROOT=/usr/share/<name>/web

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/<name>"]
```

The first stage is only needed if the service serves static files. Without it, the second half of the
file is the whole thing.

## Publish workflow

```yaml
name: Publish images
on:
  push:
    branches: [main]
    tags: ["v*"]
  workflow_dispatch:

env:
  REGISTRY: ghcr.io

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: 21 }
      - uses: gradle/actions/setup-gradle@v4

      - uses: actions/cache@v4
        with:
          path: ~/.konan
          key: konan-${{ runner.os }}-${{ hashFiles('gradle/libs.versions.toml') }}
          restore-keys: konan-${{ runner.os }}-

      # The artifacts are built here, not inside docker.
      - name: Build native binary
        run: ./gradlew :server:linkReleaseExecutableLinuxX64

      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ github.repository_owner }}/<name>
          # latest=auto follows the repository's default branch; if that is not main, the latest tag
          # has to be set explicitly — latest is what the README promises.
          tags: |
            type=ref,event=branch
            type=ref,event=tag
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

      - uses: docker/build-push-action@v6
        with:
          context: .
          file: deploy/server.Dockerfile
          push: true
          tags: ${{ steps.meta.outputs.tags }}
```

## The chart: what exactly to check

The structure (`charts/<name>/`): `Chart.yaml`, `values.yaml`, `README.md`,
`templates/{deployment,service,ingress,ingressroute,pvc,secret}.yaml`.

**The secret through `secretKeyRef`, never as a value in values:**

```yaml
env:
  - name: <NAME>_INGEST_KEY
    valueFrom:
      secretKeyRef:
        name: {{ .Release.Name }}-<name>
        key: ingest-key
```

The repository is versioned and the token is a credential; as a side effect it is also invisible in
`kubectl get deployment -o yaml` and in the Helm history.

**Probes on `/health`** — liveness and readiness. A native binary starts in milliseconds, so long
`initialDelaySeconds` values are unnecessary and only mask problems.

**A PVC for `/data`** — the only state the service has.

**Machine routes around the middleware.** If forward-auth sits in front of the service, ingest and
MCP get their own bypass route — and it is created **only when the token is set**:

```yaml
{{- if .Values.mcp.token }}
# a separate route with no forward-auth middleware
{{- end }}
```

No token, no secret, no route, no bypass. Off by default rather than open.

## Running the native binary locally

```bash
<NAME>_INGEST_KEY=dev-key <NAME>_DB_PATH=/tmp/<name>.db \
  ./server/build/bin/macosArm64/releaseExecutable/server.kexe
```

With a required variable missing the process must die — that is the check, not an inconvenience.
