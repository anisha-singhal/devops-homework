# Session 18 — Task 1: Terraform S3 demo

Name: **Anisha Singhal** · Enrollment: **10020**

An S3 bucket built with Terraform, taken through the full lifecycle: `init` → `fmt` →
`validate` → `plan` → `apply` → `show` → `output` → `destroy`. Everything below is real
terminal output, including one failure that took a while to understand.

## Where this actually runs

A real AWS account was never used. The provider is pointed at **LocalStack** on
`localhost:4566` — the same `hashicorp/aws` provider, the same resource schemas, the same
signed API calls, answered by a container instead of by AWS. Nothing is billed, and
`apply`/`destroy` are genuinely executed rather than described.

```bash
docker run -d --name localstack-s3 -p 4566:4566 -e SERVICES=s3 localstack/localstack:3.8
```

Switching to real AWS means deleting the four `skip_*` lines and the `endpoints` block in
[`provider.tf`](provider.tf), then exporting credentials. No resource definition changes.

## Files

| File | Holds |
|---|---|
| [`provider.tf`](provider.tf) | `terraform` block, provider version pin, LocalStack endpoints |
| [`variables.tf`](variables.tf) | inputs, with validation rules |
| [`main.tf`](main.tf) | the bucket and its six companion resources |
| [`outputs.tf`](outputs.tf) | what the module exposes |
| [`terraform.tfvars`](terraform.tfvars) | values for this run, loaded automatically |

## One bucket is seven resources

The thing worth noticing in `main.tf` is how little `aws_s3_bucket` does by itself:

```hcl
resource "aws_s3_bucket" "demo" {
  bucket = local.bucket
  tags   = merge(local.common_tags, { Name = local.bucket })
}
```

Versioning, encryption, public-access blocking and lifecycle are **separate resources**.
AWS provider v4 removed them as inline blocks, which is why so many older tutorials fail
with `Unsupported block type` — the syntax they show was deleted, not deprecated.

Bucket names also live in one global namespace shared by every AWS account on earth, so
`random_string.suffix` is appended rather than hardcoding a name that is already taken.

## init

```
$ terraform init

Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
- Finding latest version of hashicorp/random...
- Installing hashicorp/random v3.9.1...
- Installed hashicorp/random v3.9.1 (signed by HashiCorp)
- Installing hashicorp/aws v5.100.0...
- Installed hashicorp/aws v5.100.0 (signed by HashiCorp)

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default [...]

Terraform has been successfully initialized!
```

`init` needs **no credentials**. Plugins come from the registry, not from the cloud. That is
also why `.terraform.lock.hcl` is committed here while `.terraform/` and `*.tfstate` are
gitignored — the lock file is the reproducibility guarantee, the state file may contain
secrets.

## fmt and validate

```
$ terraform fmt -check -diff
$ echo $?
0

$ terraform validate
Success! The configuration is valid.
```

Both are **offline**. `validate` checks syntax, types and references; it never contacts AWS,
so a configuration can validate perfectly and still fail at apply.

## plan

```
$ terraform plan -out=tfplan
[...]
Plan: 7 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + bucket_arn        = (known after apply)
  + bucket_name       = (known after apply)
  + bucket_region     = (known after apply)
  + object_etag       = (known after apply)
  + object_key        = "hello.txt"
  + versioning_status = "Enabled"
```

`object_key` is known now; `bucket_name` is not, because it depends on a random value that
does not exist yet. Saving to `-out=tfplan` means `apply` executes *exactly* this plan
rather than recomputing one.

## apply

```
$ terraform apply tfplan
random_string.suffix: Creation complete after 0s [id=v42ip9]
aws_s3_bucket.demo: Creating...
aws_s3_bucket.demo: Creation complete after 0s [id=session18-s3-demo-v42ip9]
aws_s3_bucket_server_side_encryption_configuration.demo: Creating...
aws_s3_bucket_public_access_block.demo: Creating...
aws_s3_bucket_versioning.demo: Creating...
aws_s3_object.readme: Creating...
aws_s3_bucket_server_side_encryption_configuration.demo: Creation complete after 0s
aws_s3_bucket_public_access_block.demo: Creation complete after 0s
aws_s3_object.readme: Creation complete after 0s [id=hello.txt]
aws_s3_bucket_versioning.demo: Creation complete after 1s

Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
```

The four sub-resources start **in parallel** — Terraform derived from
`bucket = aws_s3_bucket.demo.id` that each depends on the bucket and on nothing else.
Dependencies come from references, not from file order.

## show and output

```
$ terraform show
# aws_s3_bucket.demo:
resource "aws_s3_bucket" "demo" {
    arn                         = "arn:aws:s3:::session18-s3-demo-v42ip9"
    bucket                      = "session18-s3-demo-v42ip9"
    bucket_domain_name          = "session18-s3-demo-v42ip9.s3.amazonaws.com"
    bucket_regional_domain_name = "session18-s3-demo-v42ip9.s3.ap-south-1.amazonaws.com"
    force_destroy               = false
    hosted_zone_id              = "Z11RGJOFQNVJUP"
    object_lock_enabled         = false
    region                      = "ap-south-1"
    request_payer               = "BucketOwner"
    tags                        = {
        "Environment" = "dev"
        "ManagedBy"   = "terraform"
        "Name"        = "session18-s3-demo-v42ip9"
        "Project"     = "session18-terraform-iac"
    }
```

`show` prints far more than was written — `hosted_zone_id`, `request_payer` and the rest are
attributes AWS filled in. State records the *whole* object, not just the managed arguments.

```
$ terraform output
bucket_arn        = "arn:aws:s3:::session18-s3-demo-v42ip9"
bucket_name       = "session18-s3-demo-v42ip9"
bucket_region     = "ap-south-1"
object_etag       = "e474962b7cf4085320a013607ebb2d25"
object_key        = "hello.txt"
versioning_status = "Enabled"
```

`versioning_status` is deliberately read back from
`aws_s3_bucket_versioning.demo.versioning_configuration[0].status` rather than from
`var.enable_versioning`, so it reports what **exists**, not what was asked for.

And the bucket is genuinely there:

```
$ aws --endpoint-url=http://localhost:4566 s3 ls s3://session18-s3-demo-v42ip9/
2026-10-07 23:53:31         58 hello.txt

$ aws --endpoint-url=http://localhost:4566 s3 cp s3://session18-s3-demo-v42ip9/hello.txt -
Provisioned by Terraform for session 18.
environment: dev
```

## Running plan twice changes nothing

```
$ terraform plan
No changes. Your infrastructure matches the configuration.
```

This is the whole point of declarative infrastructure. `apply` is not a script that runs
again; it is a diff that is already empty.

## Drift: someone changes it by hand

Encryption was deleted outside Terraform, the way a hurried engineer would in the console:

```
$ aws --endpoint-url=http://localhost:4566 s3api delete-bucket-encryption \
    --bucket session18-s3-demo-v42ip9
```

```
$ terraform plan
  # aws_s3_bucket_server_side_encryption_configuration.demo will be created
  + resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
      + bucket = "session18-s3-demo-v42ip9"
      + rule {
          + apply_server_side_encryption_by_default {
              + sse_algorithm = "AES256"
            }
        }
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```

Terraform noticed during the **refresh** phase, before computing the diff — it asked AWS what
exists rather than trusting state. That refresh is exactly why `plan` needs credentials while
`validate` does not. `apply` put the encryption back.

## What versioning actually buys

The object was overwritten twice, outside Terraform:

```
$ aws --endpoint-url=http://localhost:4566 s3api list-object-versions \
    --bucket session18-s3-demo-v42ip9 --prefix hello.txt

| IsLatest |    Key     | Size  |              VersionId              |
+----------+------------+-------+-------------------------------------+
|  True    |  hello.txt |  12   |  BCJrnR0qQhkZEplzeq.SVPER2Z9TYulM   |
|  False   |  hello.txt |  13   |  LX2bCciRNT.zvoib8VOD1ciCCiSUcnhj   |
|  False   |  hello.txt |  58   |  RtYTwqyd2cssNzjzNQfJmDtF28oosD8J   |
```

All three writes survive. Without versioning there would be one row and the original 58-byte
object would be unrecoverable. Note the cost implication: **you are billed for all three.**
That is what the lifecycle rule below exists to contain.

Terraform noticed that overwrite too:

```
$ terraform plan
  # aws_s3_object.readme will be updated in-place
  ~ resource "aws_s3_object" "readme" {
      ~ etag         = "e474962b7cf4085320a013607ebb2d25" -> "35fb68b1b75a45831bc5dbe4370def36"
      ~ content_type = "binary/octet-stream" -> "text/plain"
      ~ version_id   = "BCJrnR0qQhkZEplzeq.SVPER2Z9TYulM" -> (known after apply)
```

The ETag is the MD5 of the content for a single-part upload, so content drift is detectable
without downloading the object.

## The lifecycle rule that would not converge

`aws_s3_bucket_lifecycle_configuration` is written in `main.tf` but guarded by
`count = var.enable_lifecycle_rule ? 1 : 0`, defaulting to **false**. That is not laziness —
it took three experiments to work out why.

Applying it against LocalStack always ended the same way:

```
aws_s3_bucket_lifecycle_configuration.demo: Still creating... [2m50s elapsed]

Error: creating S3 Bucket (session18-s3-demo-v4ssxd) Lifecycle Configuration

While waiting: timeout while waiting for state to become 'true'
(last state: 'false', timeout: 3m0s)
```

The misleading part: **the rule was written correctly.**

```
$ aws --endpoint-url=http://localhost:4566 s3api get-bucket-lifecycle-configuration \
    --bucket session18-s3-demo-v4ssxd
{
    "Rules": [
        {
            "ID": "expire-noncurrent-versions",
            "Filter": { "Prefix": "" },
            "Status": "Enabled",
            "NoncurrentVersionExpiration": { "NoncurrentDays": 30 },
            "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
        }
    ]
}
```

So the `PUT` worked and the `GET` returns exactly what was asked for. Something after the
write was failing.

**Two wrong guesses first.** I thought `filter {}` serialised differently from the
`Filter{Prefix:""}` LocalStack echoed back, so I set `prefix = ""` explicitly — same timeout.
Then I guessed the empty prefix was being normalised away, so I tried `prefix = "logs/"` on a
minimal one-rule bucket — same timeout. Neither guess was right.

`TF_LOG=DEBUG` settled it. The waiter polls happily and gets valid answers:

```
$ grep 'tf_resource_type=aws_s3_bucket_lifecycle_configuration' tflog.txt \
    | grep 'HTTP Response Received' | grep -o 'http.status_code=[0-9]*' | sort | uniq -c
  10 http.status_code=200
```

```xml
<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Rule><Expiration><Days>1</Days></Expiration><ID>simple</ID>
  <Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status></Rule>
</LifecycleConfiguration>
```

HTTP 200, correct rule, every time — and the waiter still reports `false`.

The answer is in the provider source. `waitLifecycleConfigEquals` calls `lifecycleConfigEqual`,
which compares two things: the rules (by `reflect.DeepEqual`) **and
`TransitionDefaultMinimumObjectSize`**. That second field is a 2024 addition to the S3 API;
real AWS returns `all_storage_classes_128K`, and the provider defaults to expecting it.

**LocalStack never returns the field at all** — look at the XML above, there is no
`<TransitionDefaultMinimumObjectSize>` element. So the comparison is
`"all_storage_classes_128K" != ""`, forever, and the create times out after exactly 3 minutes
on a resource that was written successfully in the first second.

This is a LocalStack fidelity gap, not a configuration error. The rule is correct and the
`count` guard flips to `true` for real AWS:

```bash
terraform apply -var enable_lifecycle_rule=true
```

Two things I will not forget from this:
- **"Timeout waiting for state" rarely means the write failed.** It means a post-write
  consistency check never agreed. Check the resource out-of-band before touching the config.
- **An emulator's gaps are invisible until they are not.** LocalStack was faithful enough for
  six of seven resources, and a single missing XML element broke the seventh in a way whose
  error message pointed nowhere near the cause.

## destroy

```
$ terraform destroy
aws_s3_bucket_versioning.demo: Destroying...
aws_s3_object.readme: Destroying... [id=hello.txt]
aws_s3_bucket_server_side_encryption_configuration.demo: Destruction complete after 0s
aws_s3_bucket_versioning.demo: Destruction complete after 0s
aws_s3_bucket_public_access_block.demo: Destruction complete after 0s
aws_s3_object.readme: Destruction complete after 0s
aws_s3_bucket.demo: Destroying... [id=session18-s3-demo-v42ip9]
aws_s3_bucket.demo: Destruction complete after 0s
random_string.suffix: Destroying... [id=v42ip9]
random_string.suffix: Destruction complete after 0s

Destroy complete! Resources: 6 destroyed.
```

```
$ aws --endpoint-url=http://localhost:4566 s3 ls
(no demo bucket)
```

Destruction runs in **reverse dependency order** — sub-resources first, bucket last, random
suffix after that.

One caveat LocalStack hides: this bucket still held three object versions, and **real AWS
would have refused** with `BucketNotEmpty`, because `force_destroy = false` and Terraform only
deletes the object versions it manages. On real AWS you would need `force_destroy = true` or
an explicit purge first. LocalStack deleted it anyway — another place where passing locally
would not mean passing in production.

## Command reference

| Command | Needs credentials? | Does |
|---|---|---|
| `terraform init` | no | downloads providers, writes the lock file |
| `terraform fmt` | no | rewrites files to canonical style |
| `terraform validate` | no | syntax, types, references |
| `terraform plan` | **yes** | refreshes real state, then diffs |
| `terraform apply` | yes | executes the diff |
| `terraform show` | no | prints state in readable form |
| `terraform output` | no | prints output values |
| `terraform state list` | no | lists managed resource addresses |
| `terraform destroy` | yes | removes everything in state |

## What I took away

- **`validate` passing means nothing about `apply` succeeding.** It is offline. The lifecycle
  resource validated perfectly and then failed for three minutes.
- **`plan` needs credentials because it refreshes first.** That refresh is the entire drift
  detection mechanism — disabling encryption by hand showed up without Terraform being told.
- **The bucket resource is a shell.** Seven resources describe one bucket, and the security
  that matters — encryption, public access block — lives in the companions, not the bucket.
- **State records more than you wrote**, which is why state files are treated as sensitive and
  gitignored while the lock file is committed.
