# S3 — Simple Storage Service

Name: **Anisha Singhal** · Enrollment: **10020**

Everything in this document was exercised for real in
[`terraform-s3-demo/`](../../terraform-s3-demo/README.md) against LocalStack — the versioning,
encryption, public-access and lifecycle sections there have actual command output.

## What S3 is

**Object** storage, not block and not file. You `PUT` and `GET` whole objects by key over HTTP;
there is no partial write, no append, and no filesystem underneath. Durability is quoted at
eleven nines (99.999999999%) because every object is replicated across at least three
Availability Zones.

The consequences of "object, not file" are the ones people trip on:

- **No in-place edit.** Changing one byte means re-uploading the whole object.
- **No real directories.** `logs/2026/app.log` is one flat key; the console renders `/` as
  folders, and `ListObjects` with a prefix and delimiter fakes the tree.
- **Not a POSIX filesystem.** Mounting S3 and running a database on it ends badly.

## Buckets

The top-level container. Three things matter:

- **The name is globally unique across every AWS account on earth.** Not per-account, not
  per-region. This is why the demo appends a random suffix instead of hardcoding a name.
- Names are DNS-compatible: 3–63 characters, lowercase, digits and hyphens.
- A bucket **lives in one region**, even though its name is global. Data stays there unless you
  replicate it.

There is a soft limit of 100 buckets per account — buckets are an organisational unit, prefixes
are the scaling unit.

## Objects

An object is key + value + metadata, up to **5 TB**. Single `PUT` is capped at 5 GB; beyond
that you must use multipart upload (and multipart uploads that are started and abandoned keep
billing invisibly, which is what the demo's `abort_incomplete_multipart_upload` rule cleans up).

The **ETag** is the MD5 of the content for single-part uploads, which is why Terraform can
detect that an object changed without downloading it:

```
~ etag = "e474962b7cf4085320a013607ebb2d25" -> "35fb68b1b75a45831bc5dbe4370def36"
```

For multipart uploads the ETag is a hash-of-hashes with a `-N` suffix and is *not* the file's MD5.

## Storage classes

| Class | For | Retrieval | Min duration |
|---|---|---|---|
| Standard | hot data | instant | none |
| Intelligent-Tiering | unknown/changing access | instant | none |
| Standard-IA | infrequent, needs instant access | instant, per-GB fee | 30 days |
| One Zone-IA | same, but recreatable | instant | 30 days |
| Glacier Instant Retrieval | archive, rare instant reads | instant | 90 days |
| Glacier Flexible Retrieval | archive | minutes–hours | 90 days |
| Glacier Deep Archive | compliance, 7–10 year | up to 12 hours | 180 days |

The trap is the **minimum billing duration**. Writing an object to Standard-IA and deleting it
after 3 days bills 30 days. Lifecycle transitions into IA for short-lived data cost more than
leaving it in Standard. Intelligent-Tiering exists precisely so you do not have to guess.

## Versioning

Off by default, and **once enabled can only be suspended, never disabled**.

With versioning on:
- an overwrite creates a new version and keeps the old,
- a delete writes a **delete marker** — the object disappears from listings but the data remains.

Demonstrated in the Terraform demo with three writes to one key:

```
| IsLatest |    Key     | Size  |              VersionId              |
|  True    |  hello.txt |  12   |  BCJrnR0qQhkZEplzeq.SVPER2Z9TYulM   |
|  False   |  hello.txt |  13   |  LX2bCciRNT.zvoib8VOD1ciCCiSUcnhj   |
|  False   |  hello.txt |  58   |  RtYTwqyd2cssNzjzNQfJmDtF28oosD8J   |
```

This is the defence against both accidental deletion and ransomware — but **you are billed for
every version**, which is why versioning and lifecycle rules belong together.

It is also why emptying a versioned bucket is harder than it looks: deleting the objects leaves
the versions, and `DeleteBucket` then fails with `BucketNotEmpty`.

## Lifecycle policies

Rules that transition or expire objects by age, evaluated once a day.

```hcl
rule {
  id     = "expire-noncurrent-versions"
  status = "Enabled"
  filter { prefix = "" }

  noncurrent_version_expiration { noncurrent_days = 30 }
  abort_incomplete_multipart_upload { days_after_initiation = 7 }
}
```

A realistic full policy: Standard for 30 days → Standard-IA for 60 → Glacier for 275 → expire at
one year, with noncurrent versions expiring far sooner than current ones.

The incomplete-multipart rule is the one everyone forgets. Abandoned parts are invisible in the
console's object list and billed indefinitely.

## Encryption

**At rest** — always on now; every new object is encrypted by default with SSE-S3:

| Mode | Key held by | Use when |
|---|---|---|
| SSE-S3 (AES256) | AWS, invisible | the default; free |
| SSE-KMS | your KMS key | you need an audit trail of key use, or per-key access control |
| DSSE-KMS | KMS, applied twice | specific compliance regimes |
| SSE-C | you send it on each request | you must hold the keys yourself |

SSE-KMS costs per request and is subject to KMS throttling, which shows up as `ThrottlingException`
on high-throughput workloads.

**In transit** — TLS. Enforce it with a bucket policy denying `aws:SecureTransport = false`,
because S3 will otherwise accept plain HTTP.

## Bucket policies and public access

Access can come from four directions: IAM identity policies, **bucket policies** (resource-based,
JSON on the bucket), ACLs (legacy, now disabled by default), and presigned URLs (time-limited,
signed with the caller's credentials — the right way to hand a browser one file).

Above all of them sits **Block Public Access**, four independent switches:

```hcl
block_public_acls       = true
block_public_policy     = true
ignore_public_acls      = true
restrict_public_buckets = true
```

These **override** any ACL or bucket policy that would make data public. Essentially every "company
leaks data in open S3 bucket" headline is this setting being off. It is on by default for new
buckets since 2023; leave it on and serve public content through CloudFront with an Origin Access
Control instead.

A bucket policy denying unencrypted transport:

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": ["arn:aws:s3:::my-bucket", "arn:aws:s3:::my-bucket/*"],
  "Condition": { "Bool": { "aws:SecureTransport": "false" } }
}
```

Note both ARNs again — the bucket and its objects are separate resources, as in
[IAM](../01-iam/README.md).

## Common use cases

| Need | Shape |
|---|---|
| Static website | S3 + CloudFront + OAC, bucket itself private |
| Application uploads | presigned PUT URLs, so files never pass through your server |
| Data lake | Parquet partitioned by prefix, queried by Athena |
| Backups | versioning + lifecycle to Glacier + Object Lock for immutability |
| Terraform remote state | versioned, encrypted bucket with state locking |
| Log sink | ALB/CloudTrail/VPC flow logs, lifecycle-expired |

## What I took away

- **The bucket resource is nearly empty.** Everything that matters — versioning, encryption,
  public access, lifecycle — is a separate resource, which is both why the Terraform demo creates
  seven objects for one bucket and why a bucket can be misconfigured while looking fine.
- **Versioning is a cost decision as much as a safety one.** Without lifecycle rules it grows
  forever.
- **Minimum storage durations make "cheaper" classes more expensive** for short-lived data.
- **Block Public Access is the setting that actually matters**, and it overrides everything below
  it.
