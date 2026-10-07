# CI/CD & GitHub Actions

Session 16. Rather than copy hello-world workflows, the pipelines here **actually run against
this repository** on every push. The workflow files live in
[`.github/workflows/`](../.github/workflows/) because that path is where GitHub looks for them.

Live runs: <https://github.com/anisha-singhal/devops-homework/actions>

## CI vs CD

| | Continuous Integration | Continuous Delivery / Deployment |
|---|---|---|
| Question | "does this change break anything?" | "can this change reach users safely?" |
| Trigger | every push / PR | a green build on a release branch |
| Output | pass/fail + artifacts | a deployed environment |
| Failure cost | a red check | a rollback |

**Delivery** means every green build is *deployable* and a human presses the button.
**Deployment** means it ships automatically. The distinction is a policy decision, not a
technical one.

## The pipeline built here

[`ci.yml`](../.github/workflows/ci.yml) — four jobs, fan-out then fan-in:

```
       push / PR / workflow_dispatch
                  │
      ┌───────────┼───────────┐        three jobs start in PARALLEL
      ▼           ▼           ▼        (no `needs:`)
 shellcheck  k8s-manifests  dockerfiles
      └───────────┼───────────┘
                  ▼                    waits for all three
                build                  (`needs: [...]`)
                  │
                  ▼
            artifact upload
```

- **shellcheck** — lints `02-shell-scripting/sysinfo.sh`
- **k8s-manifests** — validates every manifest against the real Kubernetes schema with
  `kubeconform`
- **dockerfiles** — runs `hadolint` over every `Dockerfile`
- **build** — builds all six Docker Fundamentals images and uploads a size report

### Result

```
success   Validate Kubernetes manifests
success   Lint shell scripts
success   Lint Dockerfiles
success   Build images
```

```
Summary: 91 resources found in 88 files - Valid: 88, Invalid: 0, Errors: 0, Skipped: 3
sysinfo.sh passed shellcheck
```

Every Kubernetes manifest written across sessions 9–15 validates against the upstream schema.

## The first run failed, and that was the useful part

```
success   Lint shell scripts
failure   Validate Kubernetes manifests
success   Lint Dockerfiles
skipped   Build images
```

```
./14-helm/myapp/Chart.yaml       - failed validation: error while parsing: missing 'kind' key
./14-helm/myapp/values.yaml      - failed validation: error while parsing: missing 'kind' key
./14-helm/values-prod.yaml       - failed validation: error while parsing: missing 'kind' key
./07-docker-networking-volumes/compose-stack/docker-compose.yml - missing 'kind' key
Summary: 95 resources found in 92 files - Valid: 88, Invalid: 0, Errors: 4
```

**`Invalid: 0`.** No manifest was wrong — my `find` was too broad. Chart.yaml, Helm values and
docker-compose.yml are all YAML and none of them are Kubernetes objects, so kubeconform
correctly refused them.

The fix was to the filter, not the manifests:

```bash
  | grep -v '/templates/'      # Helm templates - not valid YAML until rendered
  | grep -v '/Chart.yaml'      # Helm chart metadata
  | grep -v '/values'          # Helm values
  | grep -v 'docker-compose'   # a different schema entirely
```

Two things this demonstrates properly:

- **`needs:` gates on success.** `build` was **skipped**, not failed — one red job stopped the
  expensive step from running at all. That is the entire economic argument for ordering a
  pipeline cheap-checks-first.
- **A failing pipeline is usually the pipeline's fault first.** The instinct is to go fix the
  code; the summary line said the code was already fine.

## Jobs, steps, and what runs where

```yaml
jobs:
  shellcheck:                 # a JOB: its own fresh VM, its own filesystem
    runs-on: ubuntu-latest
    steps:                    # STEPS: sequential, sharing that VM
      - uses: actions/checkout@v4
      - run: shellcheck ...
```

- **Jobs are isolated.** Each gets a clean runner. Nothing on disk in `shellcheck` is visible to
  `build` — which is exactly why artifacts exist.
- **Steps share a filesystem**, and run in order, stopping at the first failure.
- **`uses:` is a prebuilt action**, `run:` is a shell command.
- **`actions/checkout@v4` is not optional** — the runner starts with an empty workspace. A
  workflow that forgets it fails with "no such file or directory" on its own repo.

## Triggers

```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:          # a "Run workflow" button in the Actions tab
```

[`matrix.yml`](../.github/workflows/matrix.yml) adds a **path filter**:

```yaml
on:
  push:
    paths:
      - '02-shell-scripting/**'
      - '.github/workflows/matrix.yml'
```

It ran on the push that created it — because the workflow file itself is in its own path list.
Including the workflow in its own filter is deliberate: otherwise you cannot test a change to
it without touching an unrelated file.

Other triggers worth knowing: `schedule:` with cron, `release:`, `issue_comment:`, and
`workflow_call:` for reusable workflows.

## Matrix strategy

```yaml
strategy:
  fail-fast: false
  matrix:
    python-version: ['3.11', '3.12', '3.13']
```

One job definition, three parallel runs — the Flask app is parsed on each Python version.

**`fail-fast: false` matters.** The default is `true`, which cancels every other matrix leg the
moment one fails. That is efficient and it hides information: with three versions failing you
would only ever see the first. For a compatibility matrix, you want all the results.

## Artifacts

Jobs cannot see each other's files, so anything that must outlive a job is uploaded:

```yaml
- uses: actions/upload-artifact@v4
  with:
    name: image-sizes
    path: 05-docker-fundamentals/image-sizes.txt
    retention-days: 7
```

```
image-sizes  226 bytes  expires 2026-10-14
```

`retention-days` is worth setting — the default is 90 days, and artifacts count against storage
quota.

## Secrets

Not used in these workflows, because there is nothing to authenticate to — and that is the
right call rather than inventing a fake secret. The mechanism:

```yaml
- run: ./deploy.sh
  env:
    API_TOKEN: ${{ secrets.API_TOKEN }}
```

- Set under **Settings → Secrets and variables → Actions**.
- Masked in logs — printing one shows `***`.
- **Not available to workflows triggered by a PR from a fork**, which is a deliberate defence
  against someone opening a PR that exfiltrates them.
- `GITHUB_TOKEN` is injected automatically, scoped to the repository, and expires with the run.

Masking is not security. A secret passed into a build is readable by anything that build runs.

## An unexpected result worth recording

The build job printed image sizes that do not match the ones measured locally in
[`05-docker-fundamentals`](../05-docker-fundamentals/README.md):

| Image | Local (Apple Silicon, arm64) | CI runner (ubuntu-latest, amd64) |
|---|---|---|
| `hw-nginx-app` | 75.9 MB | **48.2 MB** |
| `hw-react-app` | 76.1 MB | **48.4 MB** |
| `hw-apache-app` | 105 MB | **73.1 MB** |
| `hw-python-app` | 234 MB | **131 MB** |
| `hw-nodejs-app` | 232 MB | **169 MB** |
| `hw-java-app` | 555 MB | **364 MB** |

**Identical Dockerfiles, 30–45% smaller on amd64.** The arm64 variants of these base images are
genuinely larger — different compiled binaries, and in Java's case a substantially bigger JDK
layer.

The lesson is that **image size is architecture-specific**, so a size budget measured on a
developer laptop does not transfer to the CI runner or to production. It also means "it built
on my machine" and "it built in CI" are different builds, which is the original argument for
having CI at all.

## What I took away

- **`needs:` skips rather than fails downstream jobs**, so cheap checks first is a real saving:
  one lint failure meant the six image builds never started.
- **The pipeline is usually the thing that is broken.** `Invalid: 0` with 4 errors said the
  manifests were fine and my file filter was not.
- **Jobs share nothing.** Separate VMs, separate filesystems — artifacts are the only way
  across, and `actions/checkout` is needed in every job that touches the code.
- **`fail-fast: false` is what makes a matrix informative.** The default hides every failure
  after the first.
- **The same Dockerfile produces a different image on a different architecture** — measured, not
  assumed, and a 191 MB difference on the Java image.

## Cleanup

Nothing to clean up — workflows live in the repo and runs are free on public repositories.
To stop them: delete the files, or disable from the Actions tab.
