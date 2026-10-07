# IAM — Identity and Access Management

Name: **Anisha Singhal** · Enrollment: **10020**

## What IAM is

IAM answers one question on every single AWS API call: **is this principal allowed to perform
this action on this resource, under these conditions?** Every call — console click, CLI
command, SDK call, `terraform apply` — is signed, and the signature identifies a principal
whose permissions are evaluated before anything happens.

IAM is **global**, not regional. A user created "in" ap-south-1 is the same user everywhere.
It is also free.

## Users

A user is a long-lived identity for a **person or an external system**. It has:

- a name,
- optionally a console password,
- optionally **access keys** (an access key ID + secret access key) for programmatic use.

Access keys are the dangerous part. They do not expire, they are static strings, and they are
the single most common cause of AWS breaches — committed to a repo, pasted into a ticket,
baked into an AMI. This is why the secret scanning in [session 17](../../../16-devsecops/) has
a rule for `AKIA[0-9A-Z]{16}`.

The root user is a special case: created with the account, has permissions that cannot be
restricted, and should be given MFA and then never used.

## Groups

A group is a **bucket of users that policies attach to**. Groups cannot be nested, cannot be
principals (nothing assumes a group), and exist purely so permissions are managed per-role
rather than per-person.

```
Group: developers  →  policy: ReadOnlyAccess + S3 write on dev buckets
  ├── anisha
  ├── ravi
  └── priya
```

Adding a seventh developer is one action instead of one-policy-per-person drift.

## Roles

A role is an identity with permissions but **no credentials of its own**. Something *assumes*
it and receives temporary credentials (typically valid 1 hour, max 12) via STS.

This is the single most important IAM concept, because it removes static secrets:

| Who assumes it | Instead of |
|---|---|
| An EC2 instance (instance profile) | access keys in `~/.aws/credentials` on the box |
| A Lambda function | keys in environment variables |
| An EKS pod (IRSA) | a Kubernetes Secret holding keys |
| A user in another AWS account | a second set of user credentials |
| GitHub Actions (OIDC) | long-lived keys in repository secrets |

A role has **two** policies, and conflating them is the usual beginner mistake:

- a **trust policy** — *who may assume this role* (the `Principal`),
- **permission policies** — *what the role may do once assumed*.

"Access denied" on `sts:AssumeRole` is a trust policy problem. "Access denied" on `s3:GetObject`
afterwards is a permission policy problem.

The EC2 metadata endpoint `169.254.169.254` is how an instance picks up its role's credentials
— which is exactly the error seen in [session 18's AWS reference run](../../README.md): the
provider tried every credential source, and metadata was the last one.

## Policies

JSON documents, attached to users, groups or roles. The core shape:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadDevBucket",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-dev-bucket",
        "arn:aws:s3:::my-dev-bucket/*"
      ],
      "Condition": {
        "IpAddress": { "aws:SourceIp": "203.0.113.0/24" }
      }
    }
  ]
}
```

Two details that bite:

- **The bucket and its objects are different ARNs.** `ListBucket` acts on
  `arn:aws:s3:::my-dev-bucket`; `GetObject` acts on `arn:aws:s3:::my-dev-bucket/*`. Granting
  only the first produces "access denied" on every object.
- `"Version": "2012-10-17"` is a **policy language version**, not a date you choose. It is
  always that string.

Types:

| Type | Managed by | Reusable |
|---|---|---|
| AWS managed | AWS | yes, across accounts |
| Customer managed | you | yes, within the account |
| Inline | you | no — embedded in one identity, dies with it |

## Permissions evaluation

The rules, in order:

1. **Implicit deny** — everything is denied unless something allows it.
2. An **explicit Allow** grants access.
3. An **explicit Deny** overrides every Allow, anywhere. It cannot be overruled.

So an SCP or a boundary with `"Effect": "Deny"` wins regardless of how many admin policies the
user has. This is the mechanism behind "even our admins cannot delete the audit bucket".

## Least privilege

Grant the minimum actions on the minimum resources, and widen only when something actually
breaks. In practice:

- Start from a deny-all position and add actions named in the failures.
- Prefer `s3:GetObject` on one bucket over `s3:*` on `*`.
- Use **IAM Access Analyzer** to generate a policy from CloudTrail history — what was actually
  called over 90 days, rather than what someone guessed would be needed.
- Treat `"Action": "*"` with `"Resource": "*"` as an incident waiting to happen.

The tension is real: least privilege costs iterations of "denied → add → retry". Wildcards are
faster on day one and unexplainable on day 400.

## Best practices

- **Never use the root user.** Enable MFA on it, store the credentials offline.
- **Roles over users** for anything that is not a human.
- **MFA on every human account.**
- **No access keys on EC2/ECS/EKS/Lambda** — use the instance profile or IRSA.
- **Rotate what must exist**, and delete keys with no recent `LastUsed` date.
- **Permission boundaries** to cap what a delegated admin can grant.
- **CloudTrail on, everywhere** — IAM without an audit log is unverifiable.
- **Identity Center (SSO) over IAM users** for humans in any organisation with more than a few.

## Common use cases

| Need | Shape |
|---|---|
| App on EC2 reads from S3 | role + instance profile, `s3:GetObject` on one bucket prefix |
| CI deploys to EKS | GitHub OIDC → role, no stored keys |
| Contractor gets read-only for 2 weeks | role with a conditioned trust policy, not a user |
| Cross-account access | role in account B trusting account A's principal |
| Developers get prod read, dev write | two groups, two customer-managed policies |

## What I took away

- **A role is not "a user without a password".** It is credentials generated on demand and
  expiring on their own, which is why it removes the leak risk rather than reducing it.
- **Trust policy and permission policy answer different questions**, and the error messages
  look alike.
- **Explicit deny always wins** — that is what makes guardrails actually guard.
- **The IAM failure mode is silence.** Over-permissive policies never produce an error; they
  produce a breach later.
