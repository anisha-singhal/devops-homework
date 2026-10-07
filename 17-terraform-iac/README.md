# Terraform & Infrastructure as Code

Session 18. Terraform **v1.9.8**.

The course manifests provision AWS S3 buckets, which needs credentials and bills a real
account. This section does two things instead:

- [`aws-reference/`](aws-reference/) — the course's AWS config, **validated** (`init`,
  `validate`, `fmt`) without applying anything.
- [`local-lab/`](local-lab/) — an equivalent lab using the `docker`, `local` and `random`
  providers, taken through the **complete** `init → plan → apply → destroy` cycle against real
  resources, at zero cost.

Validating a config proves it parses and type-checks. It does not prove it works. Running the
full cycle on something I can actually create does, so both are here.

## Why IaC at all

Every earlier section configured things by running commands — `docker run`, `kubectl apply`,
`helm install`. Those are **imperative**: a sequence of steps, with the current state living in
the operator's head and in shell history.

Terraform is **declarative**. The file describes the desired end state; Terraform computes the
difference against reality and closes it. The practical consequences are idempotence, drift
detection and a reviewable diff before anything changes — all demonstrated below.

## The AWS config, validated

```bash
$ cd aws-reference && terraform init
Terraform has been successfully initialized!

$ terraform validate
Success! The configuration is valid.

$ terraform fmt -check
  formatting OK
```

`init` downloaded the AWS provider and needed **no credentials** — provider plugins are
fetched from the registry, not from the cloud.

`plan` is where it stops:

```
operation error ec2imds: GetMetadata, exceeded maximum number of attempts, 3,
request send failed, Get "http://169.254.169.254/latest/meta-data/iam/security-credentials/":
dial tcp 169.254.169.254:80: connect: host is down
```

That error is worth reading. `169.254.169.254` is the **EC2 instance metadata service** — the
*last* source in the AWS provider's credential chain, after environment variables, the shared
credentials file and SSO. It only answers on an EC2 instance. So "host is down" means
**every credential source was tried and none existed**, not that something is broken.

`plan` needs credentials because it **refreshes**: it asks AWS what currently exists before
computing a diff. `validate` is offline and only checks syntax, types and references.

No AWS resources were created. Doing so would require credentials and would bill the account.

## The local lab: the full cycle, for real

```hcl
provider "docker" {}        # talks to the local daemon - no account, no cost

resource "docker_container" "web" {
  count = var.replica_count
  name  = "${local.name_prefix}-web-${count.index}"
  image = docker_image.nginx.image_id
  ports { internal = 80, external = var.base_port + count.index }
  volumes {
    host_path      = abspath(local_file.index.filename)
    container_path = "/usr/share/nginx/html/index.html"
    read_only      = true
  }
}
```

### init → plan → apply

```bash
$ terraform init
- Installing kreuzwerker/docker v3.9.0...
- Installing hashicorp/local v2.9.1...
- Installing hashicorp/random v3.9.1...
Terraform has been successfully initialized!

$ terraform plan
Plan: 5 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + urls = [
      + "http://localhost:8101",
      + "http://localhost:8102",
    ]
```

Note what the plan already knows and what it does not: the URLs are computed from variables, so
they print now; `container_names` shows `(known after apply)` because it depends on a random
string that does not exist yet.

```bash
$ terraform apply -auto-approve
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:
container_names = ["dev-tf-nu9lg-web-0", "dev-tf-nu9lg-web-1"]
image_id        = "sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10"
urls            = ["http://localhost:8101", "http://localhost:8102"]
```

```
NAMES                STATUS   PORTS
dev-tf-nu9lg-web-1   Up       0.0.0.0:8102->80/tcp
dev-tf-nu9lg-web-0   Up       0.0.0.0:8101->80/tcp
```

```bash
$ curl http://localhost:8101
<h1>Provisioned by Terraform</h1>
```

![nginx container provisioned by Terraform](screenshots/terraform-nginx.png)

### Idempotence

```bash
$ terraform apply -auto-approve
No changes. Your infrastructure matches the configuration.
Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
```

Running it twice does nothing the second time. A shell script that ran `docker run` twice would
fail on a name conflict — that difference is the whole point of declarative tooling.

### Drift detection

```bash
$ docker rm -f dev-tf-nu9lg-web-0        # change made outside Terraform

$ terraform plan
  # docker_container.web[0] will be created
Plan: 1 to add, 0 to change, 0 to destroy.

$ terraform apply -auto-approve
docker_container.web[0]: Creation complete after 1s
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

Terraform compared state to reality, found the container missing, and recreated exactly the
one that was gone. This is what makes `terraform plan` useful in CI: it reports what has
drifted since the last apply, including changes nobody recorded.

### Scaling, and an implicit dependency

```bash
$ terraform apply -var replica_count=4
Plan: 3 to add, 0 to change, 1 to destroy.
```

**3 added and 1 destroyed**, for what looked like "add two containers". The extra pair is
`local_file.index`, whose content embeds `${var.replica_count}`:

```bash
$ terraform plan -var replica_count=5
  # docker_container.web[4] will be created
  # local_file.index must be replaced
Plan: 2 to add, 0 to change, 1 to destroy.
```

Changing the variable changed the file's content, so the file had to be replaced. Nothing in
the config *says* the file depends on the replica count — Terraform worked it out from the
interpolation. **The dependency graph is inferred from references**, which is powerful and
means a plan can touch resources you were not thinking about. It is also the reason to read a
plan rather than skim the summary line.

```
dev-tf-nu9lg-web-0  0.0.0.0:8101->80/tcp
dev-tf-nu9lg-web-1  0.0.0.0:8102->80/tcp
dev-tf-nu9lg-web-2  0.0.0.0:8103->80/tcp
dev-tf-nu9lg-web-3  0.0.0.0:8104->80/tcp
```

### Variable validation

```hcl
variable "replica_count" {
  validation {
    condition     = var.replica_count >= 1 && var.replica_count <= 5
    error_message = "replica_count must be between 1 and 5."
  }
}
```

```bash
$ terraform plan -var replica_count=9
Error: Invalid value for variable

$ terraform plan -var environment=production
Error: Invalid value for variable
```

The second is the better example: `production` is rejected because the allowed set is
`["dev", "staging", "prod"]`. Catching a typo at plan time costs nothing; catching it after
apply means a mislabelled environment in production.

### State

```bash
$ terraform state list
docker_container.web[0]
docker_container.web[1]
docker_container.web[2]
docker_container.web[3]
docker_image.nginx
local_file.index
random_string.suffix
```

```
  version        : 4
  terraform      : 1.9.8
  serial         : 14          (bumps on every write)
  outputs        : ['container_names', 'image_id', 'urls']
```

State is the mapping from configuration to real-world IDs. Without it Terraform cannot know
that `docker_container.web[0]` *is* container `34e2f5f0aa57`, and so cannot tell an update from
a create.

Two consequences that matter in a team:

- **State contains secrets in plain text.** Any value a resource returns — a generated password,
  a connection string — is stored as-is. `terraform.tfstate` is in `.gitignore` here for that
  reason, and the real answer is a remote backend with encryption and access control.
- **`serial` is the concurrency guard.** Two people applying at once is how state gets
  corrupted, which is what remote backends with locking (S3 + DynamoDB, Terraform Cloud) exist
  to prevent.

### destroy

```bash
$ terraform destroy -auto-approve
Destroy complete! Resources: 7 destroyed.

$ docker ps -a --filter "label=managed-by=terraform"
  (nothing)

state resources now: 0
```

Everything removed in dependency order — containers before the image, because the containers
referenced it. The same graph that built it, reversed.

## Command reference

| Command | Purpose |
|---|---|
| `terraform init` | download providers, prepare the working directory |
| `terraform validate` | syntax and type check, offline |
| `terraform fmt` | canonical formatting (`-check` in CI) |
| `terraform plan` | diff desired vs actual; needs provider credentials |
| `terraform plan -out=f` | save a plan so `apply` executes exactly it |
| `terraform apply` | make reality match the config |
| `terraform destroy` | remove everything in state |
| `terraform state list` | what is tracked |
| `terraform output` | read output values (`-json` for scripts) |
| `terraform import` | adopt an existing resource into state |

## What I took away

- **`validate` is offline, `plan` is not.** `plan` refreshes real state, which is why it needed
  AWS credentials and why the error pointed at the EC2 metadata service — the last link in the
  credential chain.
- **Idempotence is the deliverable.** The second apply changed nothing; a shell script doing the
  same work would have failed on a name collision.
- **Drift detection is the feature you cannot script easily.** Terraform noticed a manually
  deleted container and recreated exactly that one.
- **The dependency graph is inferred from references, not declared.** Changing `replica_count`
  replaced a file nothing appeared to connect to it — read the plan, not the summary.
- **`validation` blocks catch typos at plan time**, which is the cheapest possible moment.
- **State holds secrets in plain text**, so it belongs in an encrypted remote backend with
  locking, never in git.

## Cleanup

```bash
cd local-lab && terraform destroy -auto-approve
```
