# Cloud & Terraform in Action

Session 19 — AWS networking built with Terraform.

**No AWS account was used and nothing was billed.** The configuration is the course's, applied
unchanged against **LocalStack** — a container that implements the AWS APIs on
`localhost:4566`. Terraform used the real `hashicorp/aws` provider, made real EC2 API calls, and
got back real AWS-format resource IDs. The only difference is which server answered.

```hcl
provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "http://localhost:4566"
    sts = "http://localhost:4566"
    iam = "http://localhost:4566"
    s3  = "http://localhost:4566"
  }
}
```

```bash
docker run -d --name localstack -p 4566:4566 -e SERVICES=ec2,s3,sts localstack/localstack:3.8
```

This is a genuinely useful technique beyond the homework: it is how you test infrastructure code
in CI without a cloud account, and without the 20-minute feedback loop of creating and deleting
real VPCs.

## Cloud service models

| Model | You manage | Provider manages | Example |
|---|---|---|---|
| **IaaS** | OS, runtime, app, data | hardware, network, virtualisation | EC2, VPC |
| **PaaS** | app, data | everything below | App Runner, Heroku |
| **SaaS** | nothing but configuration | everything | Gmail, Datadog |

Everything in this section is **IaaS** — raw network primitives assembled by hand. That is the
layer Terraform is for; a PaaS hides it.

## Regions and availability zones

A **region** is a geographic location (`ap-south-1` — Mumbai). An **availability zone** is an
isolated datacentre within it (`ap-south-1a`, `-1b`, `-1c`) with independent power, cooling and
networking.

The distinction drives real design decisions:

- **Regions** control latency to users, data residency, and which services exist. They are far
  apart, and cross-region traffic is slow and billed.
- **AZs** are the unit of fault tolerance. They are close enough for synchronous replication,
  so "multi-AZ" is the standard answer to "what if a datacentre fails".

The subnet below is pinned to a single AZ:

```hcl
availability_zone = "${var.aws_region}a"     # ap-south-1a
```

**A subnet exists in exactly one AZ.** That is the key fact — it is why a highly available
design needs one subnet *per* AZ, and why a single-subnet VPC is a single point of failure
regardless of how many instances run in it.

## What Terraform built

```bash
$ terraform apply
aws_vpc.main: Creation complete after 11s [id=vpc-a3f571c4]
aws_internet_gateway.main: Creation complete after 0s [id=igw-b034108f]
aws_route_table.public: Creation complete after 0s [id=rtb-35092df4]
aws_security_group.web: Creation complete after 0s [id=sg-bbe362ca789f89b07]
aws_subnet.public: Creation complete after 10s [id=subnet-505a824a]
aws_route_table_association.public: Creation complete after 0s [id=rtbassoc-a8c3adb3]

Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
```

The ordering is the dependency graph, visible:

```
aws_vpc.main                        created FIRST - everything references it
   ├── aws_internet_gateway.main    these three started together
   ├── aws_subnet.public            (parallel: none depends on another)
   └── aws_security_group.web
         aws_route_table.public     waited for the IGW (it routes to it)
           aws_route_table_association.public   waited for BOTH rt and subnet
```

Terraform parallelised what it could and serialised what it had to, with no ordering declared
anywhere in the config.

## Verified independently with the AWS CLI

Reading the resources back through a different tool, rather than trusting Terraform's own
output:

```bash
$ aws --endpoint-url http://localhost:4566 ec2 describe-vpcs
  vpc-a3f571c4  cidr=10.0.0.0/16  state=available

$ ... describe-subnets
  subnet-505a824a  cidr=10.0.1.0/24  az=ap-south-1a  auto_public_ip=True

$ ... describe-internet-gateways
  igw-b034108f  attached_to=['vpc-a3f571c4']

$ ... describe-route-tables
  rtb-35092df4  10.0.0.0/16    -> local
  rtb-35092df4  0.0.0.0/0      -> igw-b034108f
  associated subnets: ['subnet-505a824a']

$ ... describe-security-groups
  sg-bbe362ca789f89b07  session19-web-sg
    INGRESS  tcp  80-80    from ['0.0.0.0/0']
    INGRESS  tcp  443-443  from ['0.0.0.0/0']
    EGRESS   -1   all      to   ['0.0.0.0/0']
```

## Reading the network

### VPC — `10.0.0.0/16`

A private, isolated network. `/16` gives 65,536 addresses (`10.0.0.0`–`10.0.255.255`), which is
the usual choice because it leaves room to carve subnets without renumbering. Nothing enters or
leaves without something explicitly allowing it.

`enable_dns_hostnames = true` is what makes instances resolvable by name inside the VPC.

### Subnet — `10.0.1.0/24`

A slice of the VPC in one AZ. `/24` = 256 addresses, of which **AWS reserves 5** (network,
VPC router, DNS, future use, broadcast), leaving 251 usable. That reservation is a common
surprise when capacity-planning a small subnet.

### The route table is what makes a subnet "public"

```
  10.0.0.0/16  -> local
  0.0.0.0/0    -> igw-b034108f
```

Two routes, and only one of them is in the Terraform config:

- **`10.0.0.0/16 -> local`** — created by AWS automatically on every route table. It is why
  anything in the VPC can reach anything else in the VPC without configuration, and it cannot
  be removed.
- **`0.0.0.0/0 -> igw`** — the default route, declared in `main.tf`. **This single line is the
  entire difference between a public and a private subnet.**

There is no `public = true` flag. A subnet is public because its route table sends unmatched
traffic to an Internet Gateway, and private because it does not. `map_public_ip_on_launch` only
assigns addresses — without the route, those instances still cannot reach the internet.

### Internet Gateway

```
  igw-b034108f  attached_to=['vpc-a3f571c4']
```

A horizontally scaled, highly available component that performs NAT between public IPs and
private VPC addresses. One per VPC. On its own it does nothing — it has to be *routed to*.

### Security groups

```
  INGRESS  tcp  80-80    from 0.0.0.0/0
  INGRESS  tcp  443-443  from 0.0.0.0/0
  EGRESS   -1   all      to   0.0.0.0/0
```

Security groups are **stateful**: a reply to an allowed inbound request is automatically
allowed out, so there is no need for a matching egress rule per ingress rule. They are also
**allow-only** — there is no deny rule, so anything not listed is denied by omission.

That is the difference from a **NACL**, which is stateless, ordered, and supports explicit deny.
Security groups attach to interfaces; NACLs attach to subnets.

The config here is reasonable for a public web tier and would be wrong for a database:
`0.0.0.0/0` on port 80/443 is the whole internet. A database security group should reference
the *web tier's security group* as its source rather than a CIDR — then the rule keeps working
as instances come and go, with no IP addresses written down anywhere.

The wide-open egress (`-1`, all ports, everywhere) is the AWS default and worth questioning:
it is also the path data takes on the way out during an incident.

## The three-tier pattern this leads to

```
VPC 10.0.0.0/16
├── public subnet  10.0.1.0/24  (AZ a)  -> route 0.0.0.0/0 to IGW   : load balancers
├── private subnet 10.0.2.0/24  (AZ a)  -> route 0.0.0.0/0 to NAT   : application
└── private subnet 10.0.3.0/24  (AZ b)  -> route 0.0.0.0/0 to NAT   : database
```

Same primitives, different route tables. The application tier reaches the internet *outbound*
through a NAT gateway (for package updates) but cannot be reached *inbound*, because no route
points at it from the IGW.

This is the same isolation idea as the Docker three-network topology in
[`07-docker-networking-volumes`](../07-docker-networking-volumes/README.md) and the Kubernetes
namespace/Service boundaries in [`09-kubernetes-services`](../09-kubernetes-services/README.md)
— reachability decided by topology rather than by application configuration.

## Limits of this approach

LocalStack implements the **API**, not the network. The resources are real objects with real
IDs and the Terraform behaves identically, but no packet is ever routed — there is no way to
launch an instance and confirm it reaches the internet through that gateway.

So this validates the **configuration and the workflow**, which is what the exercise is about,
and does not validate connectivity. On real AWS the next step would be an EC2 instance in the
public subnet and an SSH connection to it; that needs an account, a key pair, and a running
instance that bills by the hour.

Being clear about that boundary matters more than the demo: the config being accepted by the
AWS API is not proof that the network works.

## What I took away

- **`0.0.0.0/0 -> igw` is the entire definition of a public subnet.** There is no flag. The
  route table is the switch, and `map_public_ip_on_launch` without it produces instances with
  public IPs that cannot reach anything.
- **AWS adds the `local` route itself**, which is why intra-VPC traffic works with no
  configuration at all.
- **A subnet lives in exactly one AZ**, so multi-AZ availability is a subnet-count decision
  made at design time.
- **Security groups are stateful and allow-only.** No return rules, no deny rules — and
  referencing another security group as a source beats hardcoding CIDRs.
- **A `/24` subnet has 251 usable addresses, not 256** — AWS reserves five.
- **Terraform inferred the entire creation order from references.** VPC first, three resources
  in parallel, then the route table, then the association.
- **LocalStack tests the API contract, not the network.** Useful for CI and for learning;
  not a substitute for a connectivity test.

## Cleanup

```bash
cd vpc && terraform destroy -auto-approve
docker rm -f localstack
```
