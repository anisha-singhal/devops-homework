# Complete CI/CD & DevSecOps

Session 17. Security scanning wired into the pipeline, with an explicit gate.

The course's demo app has no vulnerabilities, so every scanner would report clean and the
output would teach nothing. Instead this section scans a **deliberately flawed sample**
([`vulnerable-app/`](vulnerable-app/)) and its **corrected version**
([`fixed-app/`](fixed-app/)), so every tool below has real findings and a measurable
before/after.

> `vulnerable-app/` exists only as a scan target. Each flaw is a textbook pattern these
> tools detect. `fixed-app/` is the version to copy.

Live workflow: [`.github/workflows/devsecops.yml`](../.github/workflows/devsecops.yml)

## The four scan types

| Scan | Question | Tool used |
|---|---|---|
| **SAST** | is *my code* unsafe? | `bandit` |
| **SCA** | are *my dependencies* vulnerable? | `pip-audit` |
| **Secret scanning** | did I commit a credential? | `gitleaks` |
| **Container scanning** | is my *image* or Dockerfile unsafe? | `trivy` |

They catch different things, and none substitutes for another.

## SAST — bandit

```bash
$ bandit -r vulnerable-app/
```

```
  HIGH     B602  subprocess call with shell=True identified, security issue
  HIGH     B201  A Flask app appears to be run with debug=True
  MEDIUM   B608  Possible SQL injection vector through string-based query construction
  MEDIUM   B307  Use of possibly insecure function - consider using safer ast.literal_eval
  MEDIUM   B301  Pickle and modules that wrap it can be unsafe
  MEDIUM   B104  Possible binding to all interfaces
  LOW      B105  Possible hardcoded password: 'AKIAIOSFODNN7EXAMPLE'
  LOW      B105  Possible hardcoded password: 'SuperSecret123!'
  LOW      B403  pickle module imported
  LOW      B404  subprocess module imported

  total: 10 findings
```

Each maps to a line of source and a real attack:

| ID | The code | The attack |
|---|---|---|
| B602 | `subprocess.check_output("ping -c 1 " + host, shell=True)` | `?host=8.8.8.8;%20cat%20/etc/passwd` |
| B201 | `app.run(debug=True)` | the Werkzeug console executes arbitrary Python |
| B608 | `"... WHERE id = '" + user_id + "'"` | `?id=1'%20OR%20'1'='1` |
| B307 | `eval(request.args.get("expr"))` | `?expr=__import__('os').system('...')` |
| B301 | `pickle.loads(request.data)` | a crafted pickle runs code on deserialisation |

**Severity is not the same as exploitability.** B608 (SQL injection) is rated MEDIUM here with
*Low confidence*, because bandit can only see string concatenation and cannot know the value is
attacker-controlled. It is arguably the most dangerous line in the file. A gate set at
"HIGH only" would let it through — which is why SAST output needs reading, not just thresholding.

### After the fix

```
  HIGH: 0   total: 3
    LOW  B404  subprocess module imported
    LOW  B607  Starting a process with a partial executable path
    LOW  B603  subprocess call - check for execution of untrusted input
```

10 → 3, and the three that remain are informational: the module is still imported and the
command is still `ping`, but `shell=False` with an argument list means the injection is gone.

One finding was **accepted rather than fixed**:

```python
app.run(host="0.0.0.0", port=5000, debug=False)  # nosec B104
```

Binding to `0.0.0.0` is required inside a container — the pod network is the real boundary.
`# nosec` records that decision **in the code**, where a reviewer sees it, instead of in
someone's memory.

## SCA — pip-audit

```bash
$ pip-audit -r vulnerable-app/requirements.txt
```

```
Name     Version  ID                 Fix Versions
flask    0.12.2   PYSEC-2019-179     1.0
flask    0.12.2   PYSEC-2023-62      2.2.5,2.3.2
jinja2   2.10     PYSEC-2021-66      2.11.3
werkzeug 0.14.1   PYSEC-2023-221     2.3.8,3.0.1
werkzeug 0.14.1   GHSA-g6x2-hccm-hh4m 3.1.9
pyyaml   5.1      PYSEC-2020-176     5.2b1
requests 2.19.1   PYSEC-2018-28      2.20.0
...
```

**28 CVEs across 5 packages, in code nobody here wrote.** This is the category SAST cannot
see — the application source is irrelevant; the risk arrived through `requirements.txt`.

### The fixed version is better, not clean

```bash
$ pip-audit -r fixed-app/requirements.txt
requests 2.32.5  PYSEC-2026-2275  2.33.0
urllib3  2.6.3   PYSEC-2026-142   2.7.0
urllib3  2.6.3   PYSEC-2026-4177  2.8.0
click    8.1.8   PYSEC-2026-2132  8.3.3
```

Every direct dependency was pinned to a current release, and CVEs remain — in **`urllib3`** and
**`click`**, which appear nowhere in `requirements.txt`. They are **transitive**: pulled in by
`requests` and `flask`.

That is the honest state of dependency scanning. You do not control your whole tree, patching
a transitive dependency means waiting for the parent to bump its constraint (or pinning it
yourself and risking incompatibility), and **"zero CVEs" is rarely achievable** on a real
application. The useful policy is a severity threshold plus a documented exception list, not a
clean report.

## Secret scanning — gitleaks

```bash
$ gitleaks detect --no-git --source vulnerable-app
  total: 0 secrets
```

**Zero findings — on a file containing two hardcoded credentials that bandit flagged.**

The reason: `AKIAIOSFODNN7EXAMPLE` is AWS's own documentation example key, and gitleaks
explicitly allowlists it. `SuperSecret123!` matches no high-entropy rule.

Verifying the scanner is not simply broken, against four non-allowlisted dummy values:

```
  github-pat                     line 4
  total: 1
```

**1 of 4 detected.** The GitHub PAT has a distinctive prefix and checksum; the others did not
trip a rule.

Two lessons, and the second is the important one:

- Secret scanners work on **known patterns**. A credential with no recognisable shape — a
  database password, an internal API key, a private key pasted as one line — can pass straight
  through.
- **A clean secret scan is not evidence that there are no secrets.** It is evidence that
  nothing matched the ruleset. Combining it with SAST helps: bandit caught both hardcoded
  values here that gitleaks missed.

In CI the scan runs with `fetch-depth: 0`, because `gitleaks detect` scans **history** — a
secret that was committed and later removed is still in the repository and still compromised.

## Container scanning — trivy

### Dockerfile misconfiguration

```bash
$ trivy config vulnerable-app/
Tests: 24 (SUCCESSES: 23, FAILURES: 1)

DS-0002 (HIGH): Specify at least 1 USER command in Dockerfile with non-root user as argument
```

The container runs as root. Combined with a container escape, root in the container is root on
the node.

```bash
$ trivy config fixed-app/
Tests: 27 (SUCCESSES: 26, FAILURES: 1)
Failures: 1 (LOW: 1, HIGH: 0, CRITICAL: 0)
```

Fixed by three lines:

```dockerfile
RUN useradd --create-home --shell /bin/bash appuser
RUN chown -R appuser:appuser /app
USER appuser
```

### Base image CVEs — the biggest single lever

```bash
$ trivy image --severity HIGH,CRITICAL python:3.9
python:3.9 (debian 13.1)
Total: 2265 (HIGH: 2031, CRITICAL: 234)

$ trivy image --severity HIGH,CRITICAL python:3.13-slim
python:3.13-slim (debian 13.7)
Total: 44 (HIGH: 44, CRITICAL: 0)
```

**2265 → 44, a 98% reduction, from one line of the Dockerfile.** No application code changed.

`python:3.9` is an old tag on a full Debian image carrying compilers, package managers and
libraries the app never calls. Every one of them is attack surface and shows up in a scan.
`-slim` drops most of it; `-alpine` or `distroless` drop more.

This connects directly to the multi-stage work in
[`06-dockerfiles-and-images`](../06-dockerfiles-and-images/README.md): the argument there was
image size, and the security argument turns out to be the same argument. **A smaller image is
a smaller attack surface**, and a shipped compiler is a tool for whoever gets in.

## The security gate

Scanning without a gate is a report nobody reads. The gate in
[`devsecops.yml`](../.github/workflows/devsecops.yml):

```yaml
- name: Scan the fixed app - must have zero HIGH findings
  run: |
    bandit -r 16-devsecops/fixed-app/ -f json -o bandit.json || true
    high=$(python -c "import json;print(sum(1 for r in json.load(open('bandit.json'))['results'] if r['issue_severity']=='HIGH'))")
    echo "HIGH severity findings: $high"
    test "$high" -eq 0
```

Design decisions, each a trade-off:

- **Gate on HIGH/CRITICAL, report everything else.** Gating on LOW blocks every merge on
  informational findings, and the predictable result is that someone disables the gate.
- **`|| true` on the scan, then an explicit check.** bandit exits non-zero when it finds
  anything at all; the gate needs to decide *which* findings matter, not just "any".
- **`if: always()` on artifact upload**, so the report survives a failed run — the failure is
  exactly when you want to read it.
- **The vulnerable sample is scanned but not gated**, with its findings printed. A scan whose
  failure is expected must not fail the build, or the signal is lost.

## Three failures the pipeline found, and what each one meant

### gitleaks found 6 secrets the filesystem scan missed

The local scan of `vulnerable-app/` reported 0. In CI, with `fetch-depth: 0`, it reported 6 —
and they were somewhere else entirely:

```
kubernetes-secret-yaml   11-kubernetes-config-ingress/02-secret/db-secret.yaml:2
generic-api-key          11-kubernetes-config-ingress/02-secret/db-secret.yaml:12
generic-api-key          11-kubernetes-config-ingress/02-secret/README.md:64
generic-api-key          11-kubernetes-config-ingress/04-full-demo/secret.yaml:13
kubernetes-secret-yaml   11-kubernetes-config-ingress/04-full-demo/secret.yaml:2
generic-api-key          11-kubernetes-config-ingress/README.md:45
```

**The Kubernetes Secret manifests from session 12**, committed to git with base64 credentials
in them. The detection is entirely correct — and it demonstrates that session's own lesson from
the other direction. Session 12 argued that base64 is encoding, not encryption; here a scanner
treats those files as leaked credentials, because that is what they are.

This is the real reason `sealed-secrets`, `external-secrets` and SOPS exist: a plain Secret
manifest cannot safely live in a git repository.

These are course exercise values (`POSTGRES_PASSWORD = "secretpassword"`), so they were
allowlisted — with the reason written into [`.gitleaks.toml`](../.gitleaks.toml) rather than
left implicit:

```toml
# They are allowlisted here because they are course exercise values,
# published deliberately to demonstrate that base64 is encoding and not
# encryption. No real credential is involved.
[allowlist]
paths = [ "11-kubernetes-config-ingress/02-secret/db-secret\.yaml", ... ]
```

Anything not on that list still fails the build. **An accepted finding should be a reviewable
line in a config file, not a disabled scan.**

It also settles the earlier question: the filesystem scan missed these because it only looked
at one directory. **Scan scope is as important as the ruleset.**

### The trivy job never ran at all

```
##[error]Unable to resolve action `aquasecurity/trivy-action@0.28.0`, unable to find version `0.28.0`
```

The job failed at **Set up job** — before a single scan executed. A pinned third-party action
tag that does not exist fails the build in a way that looks like a security failure and is not.

Fixed by installing the binary directly:

```yaml
- run: |
    curl -sL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
      | sh -s -- -b /usr/local/bin v0.75.0
```

Worth stating the trade-off rather than pretending it is a pure win: a pinned action is easier
to read and gets Dependabot updates; a `curl | sh` install removes a dependency on a third
party's tagging discipline but pins a version you now maintain yourself. For a security job
specifically, fewer third-party actions in the supply chain is the safer default — a
compromised action runs with your `GITHUB_TOKEN`.

### A third failure, later: a bad rule I wrote myself

Adding the capstone project (session 21) broke the gitleaks job again — three findings:

```
kubernetes-secret-yaml   20-final-project/taskboard/helm/taskboard/templates/postgres.yaml:2
    match: kind: Secret
curl-auth-user           19-monitoring-gitops/README.md:128
    match: curl -u admin:admin
curl-auth-user           19-monitoring-gitops/README.md:136
```

Two of the three came from a rule **I had added to `.gitleaks.toml` myself**:

```toml
[[rules]]
id = "kubernetes-secret-yaml"
regex = '''kind:\s*Secret'''
```

That matches every Kubernetes Secret **manifest**. A manifest is an object type, not a
credential — and the file it flagged contains no secret at all:

```yaml
stringData:
  password: {{ .Values.postgres.password | quote }}
```

A template placeholder. The rule was pure false positive, and it was mine.

**The rule was deleted rather than allowlisted.** A detection that fires on every occurrence of
a common keyword produces noise, and noise is how a scanner gets ignored — the exact failure
mode the gate design above was trying to avoid. gitleaks' built-in rules already detect real
credential patterns by entropy, known key prefixes and checksums, which is what actually
distinguishes a secret from the word "Secret".

The third finding, `curl -u admin:admin`, is Grafana's documented default login appearing in a
prose example. That one *is* an allowlist case, and it is recorded as such:

```toml
regexes = [
  # Grafana's documented default login, used in curl examples in prose.
  '''admin:admin''',
]
```

The distinction is worth keeping: **allowlist a real pattern that is genuinely acceptable here;
delete a rule that was never measuring anything.** Allowlisting the bad rule would have left it
firing on every future Secret manifest in the repo.

### After the fixes

```
success   SAST (bandit)
success   SCA (pip-audit)
success   Secret scanning (gitleaks)
success   Container scanning (trivy)
```

## What I took away

- **The four scans are not interchangeable.** Bandit found two hardcoded credentials that
  gitleaks missed; pip-audit found 28 CVEs that bandit cannot see; trivy found 2265 that live
  in neither the code nor `requirements.txt`.
- **Severity ratings are about the scanner's confidence, not the risk.** SQL injection came out
  MEDIUM/Low-confidence because static analysis cannot prove the input is attacker-controlled.
- **A clean secret scan proves only that nothing matched the ruleset** — 1 of 4 test values
  detected, and 0 of 2 real ones in the sample.
- **You cannot fix your whole dependency tree.** Pinning every direct dependency to current
  still left CVEs in `urllib3` and `click`, two levels down.
- **Base image choice beat every other control by an order of magnitude** — 2265 → 44 from one
  line, and it is the same change that makes the image smaller.
- **A scanner is only as good as its rules, and a bad rule is worse than none.** A
  `kind: Secret` rule I wrote flagged a template placeholder and nothing real; it was deleted,
  not allowlisted.
- **Scan scope matters as much as the ruleset.** The same tool found 0 against a directory and
  6 against git history — and the 6 were real.
- **A gate that blocks on everything gets switched off.** HIGH/CRITICAL blocks, the rest is
  reported, and exceptions are recorded as `# nosec` in the code where a reviewer sees them.
