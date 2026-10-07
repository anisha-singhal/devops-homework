# VPC — Virtual Private Cloud

Name: **Anisha Singhal** · Enrollment: **10020**

A VPC was actually built with Terraform in [session 19](../../../18-cloud-terraform/README.md) —
that project has the real `plan`/`apply` output for the pieces described here.

## What a VPC is

A logically isolated network inside AWS that you control completely: address range, subnets,
routing, gateways and firewalls. Every EC2 instance, RDS database, Lambda with networking and
EKS node lives in one.

A VPC is **regional** and spans every Availability Zone in that region. Subnets are the part
that is AZ-specific.

Every account gets a **default VPC** per region with public subnets and an internet gateway
already wired. It is convenient and the reason so many tutorials "just work" — and the reason so
many first deployments are accidentally public.

## CIDR

The address range, in CIDR notation. The prefix length is how many bits are fixed:

| CIDR | Addresses | Meaning |
|---|---|---|
| `10.0.0.0/16` | 65,536 | first 16 bits fixed → `10.0.x.x` |
| `10.0.1.0/24` | 256 | first 24 bits fixed → `10.0.1.x` |
| `10.0.1.0/28` | 16 | a very small subnet |

A VPC CIDR must be between `/16` and `/28`, and should come from RFC1918 private space
(`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).

**AWS reserves five addresses in every subnet**: network address, VPC router, DNS, a future
use, and broadcast. So a `/24` gives 251 usable addresses, not 256 — which matters when sizing
subnets for EKS, where every pod consumes an IP.

The decision that is painful to undo: **CIDRs must not overlap** with anything you might peer
with later — other VPCs, the office network, a partner's account. Picking `10.0.0.0/16` because
it is the default, then needing to peer with another `10.0.0.0/16`, means rebuilding.

## Subnets

A slice of the VPC CIDR **bound to one Availability Zone**. Spanning AZs is what makes a system
survive an AZ failure, so production designs use at least two of each kind.

A subnet is "public" or "private" purely by **what its route table says** — there is no flag:

| | Public subnet | Private subnet |
|---|---|---|
| Route to `0.0.0.0/0` | Internet Gateway | NAT Gateway (or nothing) |
| Inbound from internet | possible | impossible |
| Outbound to internet | yes | via NAT only |
| Typical contents | ALB, NAT GW, bastion | app servers, RDS, EKS nodes |

## Route tables

A list of destination CIDR → target. Every subnet is associated with exactly one; unassociated
subnets fall back to the VPC's **main** route table.

Routing is **longest-prefix match**. A local route for the VPC CIDR always exists, cannot be
removed, and always wins over `0.0.0.0/0` — which is why instances in different subnets can
always reach each other without configuration.

```
Public route table                 Private route table
  10.0.0.0/16 → local                10.0.0.0/16 → local
  0.0.0.0/0   → igw-xxxx             0.0.0.0/0   → nat-xxxx
```

That one-line difference is the entire public/private distinction.

## Internet Gateway

A horizontally scaled, highly available component attached **one per VPC**. It does two things:
routes traffic between the VPC and the internet, and performs **NAT between private and public
IPs**.

Three things must all be true for an instance to be reachable from the internet, and missing any
one produces the same silent failure:

1. an Internet Gateway attached to the VPC,
2. a route `0.0.0.0/0 → igw` in the subnet's route table,
3. a public IP or Elastic IP on the instance,

plus security group and NACL rules allowing the traffic. This checklist is the answer to most
"why can't I reach my instance" questions.

## NAT Gateway

Lets private-subnet resources make **outbound** connections (package updates, API calls) while
remaining unreachable from outside.

It is **placed in a public subnet**, needs an Elastic IP, and the private subnet's route table
points `0.0.0.0/0` at it. Putting the NAT Gateway in the private subnet is a classic mistake that
produces a routing loop.

It is also **per-AZ and not free**: roughly $0.045/hour plus $0.045/GB processed. One NAT Gateway
per AZ is the resilient design and triples the cost; one shared NAT Gateway is cheaper and makes
an AZ failure cut off the others. For S3 and DynamoDB specifically, a **VPC Gateway Endpoint**
avoids the NAT charge entirely and is free.

NAT Instances (a self-managed EC2 doing the same job) still exist and are cheaper at small scale,
at the cost of being your problem to patch and scale.

## Security Groups vs Network ACLs

The two firewalls, and the comparison that is asked in every interview:

| | Security Group | Network ACL |
|---|---|---|
| Attaches to | ENI / instance | subnet |
| State | **stateful** — replies allowed automatically | **stateless** — you must allow both directions |
| Rules | allow only | allow **and deny** |
| Evaluation | all rules, any match allows | **in number order**, first match wins |
| Default | deny inbound, allow outbound | default NACL allows everything |

The practical consequence of statelessness: a NACL permitting inbound 443 also needs an outbound
rule for **ephemeral ports** (1024–65535), because the response leaves from a high port. Forgetting
this produces connections that establish and then hang.

In practice security groups do the work; NACLs are a coarse subnet-wide backstop, most often used
to block a specific IP range — something a security group cannot express.

## Public vs private subnet

```
                    Internet
                        │
                   [ IGW ]
                        │
  ┌─────────────────────┴─────────────────────┐   VPC 10.0.0.0/16
  │                                           │
  │  Public subnet 10.0.1.0/24  (AZ-a)        │
  │    ALB, NAT Gateway                       │
  │    route: 0.0.0.0/0 → IGW                 │
  │              │                            │
  │              ▼                            │
  │  Private subnet 10.0.11.0/24 (AZ-a)       │
  │    app servers, EKS nodes                 │
  │    route: 0.0.0.0/0 → NAT                 │
  │              │                            │
  │              ▼                            │
  │  Private subnet 10.0.21.0/24 (AZ-a)       │
  │    RDS - no 0.0.0.0/0 route at all        │
  └───────────────────────────────────────────┘
```

The database tier having **no default route** is deliberate: it cannot reach the internet even
outbound, so a compromised database cannot exfiltrate data or pull down a payload.

## Common use cases

| Need | Shape |
|---|---|
| Standard 3-tier web app | public ALB subnets, private app subnets, isolated DB subnets, ×2 AZ |
| EKS cluster | private subnets for nodes, public for the load balancers; size CIDRs for per-pod IPs |
| Fully private workload | no IGW; VPC endpoints for S3, ECR, CloudWatch |
| Hybrid / on-prem link | Site-to-Site VPN or Direct Connect, non-overlapping CIDRs |
| Connecting two VPCs | peering (simple, non-transitive) or Transit Gateway (hub and spoke) |

## What I took away

- **"Public subnet" is not a property, it is a route.** One line in a route table is the whole
  difference.
- **Five IPs per subnet are reserved**, which makes `/28` subnets nearly useless and matters a lot
  for EKS IP planning.
- **Stateless NACLs need ephemeral-port rules**, and the symptom of forgetting is a hang, not a
  refusal.
- **NAT Gateways are the quiet line item** on a lot of AWS bills, and gateway endpoints remove it
  for S3 and DynamoDB.
- **CIDR choice is close to irreversible** once anything peers with you.
