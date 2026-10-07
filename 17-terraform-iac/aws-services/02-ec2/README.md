# EC2 — Elastic Compute Cloud

Name: **Anisha Singhal** · Enrollment: **10020**

## What EC2 is

Virtual machines rented by the second. You choose a machine image, a size, a network and a
firewall, and AWS gives you a Linux or Windows box you have full root on. EC2 is the oldest
compute service and still the fallback for anything that does not fit a managed service.

Unlike a container, an EC2 instance is **yours to patch**. The shared responsibility line sits
at the hypervisor: AWS keeps the hardware and host running, you own the kernel upwards.

## AMI — Amazon Machine Image

The template an instance boots from: root filesystem snapshot, plus block device mapping,
plus launch permissions. Picking an AMI picks the OS, the pre-installed software, and the
architecture (x86_64 or arm64 — Graviton instances need an arm64 AMI, and a mismatch fails at
launch, not at build).

AMIs are **regional**. An AMI built in ap-south-1 must be copied before it can launch in
us-east-1 — a detail that routinely breaks a first multi-region deployment.

Sources: AWS-provided (Amazon Linux 2023, Ubuntu), Marketplace, community, or your own —
typically built with Packer so that "golden image" is itself code.

## Instance types

Named `family + generation + size`: `t3.micro`, `m6i.large`, `c7g.xlarge`.

| Family | Optimised for | Typical use |
|---|---|---|
| `t` | burstable | dev boxes, low-traffic sites |
| `m` | balanced | general application servers |
| `c` | compute | batch, encoding, CPU-bound APIs |
| `r`, `x` | memory | caches, in-memory databases |
| `i`, `d` | storage | NoSQL, data warehouses |
| `p`, `g`, `inf` | accelerators | ML training and inference |

A suffix `g` means **Graviton** (AWS ARM), usually cheaper per unit of work — if your image and
dependencies are arm64.

The `t` family's catch: it runs on **CPU credits**. Burst above the baseline and credits drain;
at zero the instance is throttled to baseline, or silently billed in unlimited mode. A `t3.micro`
that "got slow after a week" is nearly always exhausted credits.

Pricing models: On-Demand (per second, no commitment), Reserved / Savings Plans (1–3 year
commitment, up to ~70% off), **Spot** (spare capacity, up to ~90% off, reclaimed with 2 minutes'
notice — perfect for stateless workers, fatal for a database).

## Key pairs

An SSH public/private key pair. AWS keeps the public key and injects it into the instance's
`~/.ssh/authorized_keys` at first boot; **you keep the private key and AWS cannot recover it**.
Lose it and you cannot SSH in — recovery means detaching the root volume and attaching it to
another instance.

The modern answer is to avoid key pairs entirely: **SSM Session Manager** gives a shell through
the AWS API, with IAM for authorisation and CloudTrail for audit, and needs no key, no open port
22 and no public IP at all.

## Security Groups

A **stateful** virtual firewall attached to a network interface.

- Rules are **allow-only** — there is no deny rule.
- **Stateful**: allow inbound 443 and the response goes out automatically, no outbound rule
  needed. This is the main difference from a Network ACL.
- Default: all inbound denied, all outbound allowed.
- A rule's source can be a CIDR **or another security group** — "anything in the web SG may
  reach the db SG on 5432" survives autoscaling, where hardcoded IPs do not.

```
Internet ──► web-sg   (inbound 443 from 0.0.0.0/0)
                │
                ▼
             app-sg   (inbound 8080 from web-sg)
                │
                ▼
              db-sg   (inbound 5432 from app-sg)
```

`0.0.0.0/0` on port 22 is the classic finding in every security audit.

## EBS — Elastic Block Store

Network-attached block storage that behaves like a disk and **survives instance termination**
if you ask it to. Volume types:

| Type | Nature | Use |
|---|---|---|
| `gp3` | general SSD, IOPS set independently of size | the default choice |
| `io2` | provisioned IOPS SSD, highest durability | demanding databases |
| `st1` | throughput HDD | logs, big sequential reads |
| `sc1` | cold HDD | archives |

Key properties: an EBS volume lives in **one Availability Zone** and can only attach to an
instance in that AZ; snapshots go to S3 and are the way to move a volume across AZs or regions.
`DeleteOnTermination` defaults to **true for the root volume** — which is how people lose data
by terminating an instance.

**Instance store** is the other kind: physically attached NVMe, very fast, and **erased on stop
or termination**. Scratch space only.

## Public vs private IP

| | Private IP | Public IP | Elastic IP |
|---|---|---|---|
| Range | VPC CIDR (e.g. `10.0.1.25`) | AWS pool | AWS pool, reserved to you |
| Survives stop/start | yes | **no** | yes |
| Reachable from internet | no | yes (with IGW + routing + SG) | yes |
| Cost | free | free while attached | charged when *not* attached |

The instance's OS only ever sees the **private** IP. The public IP is NAT at the edge — which is
why `ip addr` never shows it, and why `hostname -I` confuses people on their first instance.

An instance in a private subnet with no public IP reaches the internet through a **NAT Gateway**
— outbound only. See [VPC](../04-vpc/README.md).

## Instance lifecycle

```
          launch
            │
            ▼
        [pending] ──► [running] ──┬──► [stopping] ──► [stopped] ──► (start) ──► running
                                  │                        │
                                  │                        └──► [terminated]  (gone)
                                  └──► [shutting-down] ──► [terminated]
```

What actually matters:

- **stopped**: no compute charges, **EBS still billed**, public IP lost (Elastic IP kept),
  instance store wiped. The instance can move to different physical hardware on start.
- **terminated**: gone permanently. Root volume deleted if `DeleteOnTermination` is true.
- **reboot**: stays on the same host, keeps its public IP and instance store — it is not a
  stop/start.
- **hibernate**: RAM is written to the root EBS volume and restored on start.

Termination protection exists precisely because "terminate" and "stop" sit next to each other in
the console menu.

## Common use cases

| Need | Shape |
|---|---|
| Legacy app that cannot be containerised | a right-sized `m` instance in a private subnet |
| Bursty batch processing | Spot instances in an Auto Scaling group |
| Self-managed Kubernetes nodes | EC2 in an ASG, joined to the cluster |
| GPU model training | `p`/`g` family, data on EBS or FSx |
| Bastion / jump host | replace it with SSM Session Manager |

## What I took away

- **Stopping is not terminating, and neither is free.** EBS bills while stopped; instance store
  and public IPs are lost on stop.
- **Security groups are stateful and allow-only** — the mental model from iptables does not
  transfer cleanly.
- **Referencing a security group as a source** is what makes rules survive autoscaling.
- **The OS never sees its public IP**, which explains a whole class of "my app binds to the
  wrong address" confusion.
- **`t`-family throttling is invisible** until you look at CPU credit balance.
