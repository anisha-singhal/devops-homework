# DynamoDB and RDS — Database Services

Name: **Anisha Singhal** · Enrollment: **10020**

Two managed database services that sit at opposite ends of the same trade-off: RDS gives you a
familiar relational engine and asks you to manage its capacity; DynamoDB gives you predictable
scale and asks you to design around its access patterns up front.

---

# DynamoDB

## NoSQL

A fully managed key-value and document store. No servers, no version upgrades, no connection
pool. It is **serverless in the real sense** — there is no instance to size, and single-digit
millisecond latency holds whether the table has a thousand items or a billion.

What you give up: joins, `GROUP BY`, arbitrary `WHERE`, and foreign keys. There is no query
planner to rescue a badly shaped query, which is why DynamoDB is designed **access-pattern
first** — you write down the queries the application will make, then design the keys to serve
them. That is the exact inverse of relational modelling, and the main reason teams struggle with
it.

## Tables

A table holds items. Unlike SQL, a table has **no fixed schema** beyond its key attributes —
two items in the same table can carry completely different fields. Capacity comes in two modes:

| Mode | Billing | Use when |
|---|---|---|
| On-demand | per request | spiky or unknown traffic, new apps |
| Provisioned | per RCU/WCU per hour | steady, predictable traffic (cheaper, can autoscale) |

## Items

A single record, identified by its primary key, capped at **400 KB** including attribute names.
Large blobs go to S3 with the key stored in the item.

## Attributes

Typed fields: scalar (`S`, `N`, `B`, `BOOL`, `NULL`), document (`M` map, `L` list), set
(`SS`, `NS`, `BS`). Nesting is allowed; only the key attributes must be declared when creating
the table.

## Partition key

The hash key. DynamoDB hashes it to choose a physical partition, which is why key design *is*
performance design:

- **High cardinality and even access** → traffic spreads across partitions.
- A key like `status` with three values, or a date that every write shares, creates a **hot
  partition** — one partition throttles while the table looks idle in aggregate. The usual fix
  is suffixing (`2026-10-07#7`) to spread writes.

## Sort key

Optional second half of a composite primary key. Items with the same partition key are stored
**sorted** by it, and that is what makes range queries possible:

```
PK = USER#10020,  SK = ORDER#2026-01-15
PK = USER#10020,  SK = ORDER#2026-03-02
PK = USER#10020,  SK = PROFILE
```

`Query` on `PK = USER#10020 AND begins_with(SK, "ORDER#")` returns that user's orders in date
order, reading only what it returns.

The critical distinction:

- **`Query`** uses the partition key, reads only matching items — fast, cheap, scales.
- **`Scan`** reads **every item in the table** and filters afterwards — you pay for all of it.
  A `Scan` in a request path is nearly always a modelling mistake.

Secondary indexes extend this: a **LSI** adds an alternative sort key within the same partition
(must be created with the table), a **GSI** allows an entirely different partition key, with its
own capacity and eventual consistency.

## Use cases

Session stores, shopping carts, user profiles, IoT telemetry, leaderboards, event sourcing —
anything with a known key-based access pattern and a need for scale. **Not** for ad-hoc
analytics, reporting, or anything where the queries are not known in advance.

---

# RDS

## Relational database

Managed relational databases: AWS runs the host, patching, backups, failover and replication; you
keep schema, queries and indexes. It is the same engine you would run yourself, with the operational
burden removed — not a different database.

## Supported engines

PostgreSQL, MySQL, MariaDB, Oracle, SQL Server, and **Aurora** (AWS's own MySQL- and
PostgreSQL-compatible engine with a distributed storage layer, up to ~5× MySQL throughput, and
storage that auto-grows). Aurora Serverless v2 scales capacity in fine-grained steps for variable
load.

## DB instances

Sized like EC2 (`db.t3.micro`, `db.r6g.large`) with storage chosen separately (gp3 or io1).
Important properties:

- **Storage can grow but never shrink.** Over-provisioning is a permanent bill; storage
  autoscaling handles growth.
- **Scaling instance class requires a reboot** — a few minutes of downtime unless Multi-AZ lets
  it fail over.
- Read **replicas** scale reads; the writer stays single. Horizontal write scaling is not an RDS
  feature.

## Security

- Put it in **private subnets** via a DB subnet group, with no `0.0.0.0/0` route at all.
- Security group allowing only the app tier's security group on 5432/3306 — not a CIDR.
- **Encryption at rest** must be chosen **at creation**; enabling it later means a snapshot,
  restore to a new encrypted instance, and a cutover.
- TLS in transit, enforced with `rds.force_ssl`.
- **IAM database authentication** or **Secrets Manager** with automatic rotation, instead of a
  password in an environment variable.
- `publicly_accessible = false`, always.

## Backups

- **Automated backups**: daily snapshot plus transaction logs, giving **point-in-time recovery**
  to any second within the retention window (1–35 days). Retention `0` disables it — and is the
  default in some tooling.
- **Manual snapshots**: kept until you delete them, and they survive deletion of the instance.
- Restoring always creates a **new instance**; it never restores in place. Recovery planning has
  to account for the new endpoint.

## Multi-AZ

A **synchronous standby** in another Availability Zone. It is for availability, not performance —
you cannot read from it. Failover is automatic (typically 60–120 seconds) and works by repointing
the DNS endpoint, which is why applications must connect by endpoint name and not by cached IP.

Multi-AZ roughly doubles cost. Multi-AZ **DB cluster** deployments add two readable standbys and
faster failover.

## Read replicas

**Asynchronous** copies that serve read traffic. They can be in another AZ or region, can be
promoted to standalone primaries, and are replication-lagged — so read-after-write through a
replica may miss the write.

| | Multi-AZ standby | Read replica |
|---|---|---|
| Replication | synchronous | asynchronous |
| Readable | no | yes |
| Purpose | availability | read scaling / DR |
| Failover | automatic | manual promotion |

## Use cases

Anything needing transactions, joins, or an existing relational schema: order systems, financial
records, CMS backends, reporting. The [capstone project](../../../20-final-project/README.md)
uses PostgreSQL for exactly this reason.

---

## Choosing between them

| | DynamoDB | RDS |
|---|---|---|
| Model | key-value / document | relational |
| Schema | per-item | fixed, migrated |
| Queries | known access patterns only | ad-hoc SQL |
| Joins / transactions | limited | full ACID |
| Scaling | automatic, horizontal | vertical; reads via replicas |
| Ops | none | patch windows, parameter groups, sizing |
| Latency at scale | flat | degrades without tuning |
| Cost shape | per request | per instance-hour, running or not |

A reasonable rule: **relational by default**, DynamoDB when the access pattern is narrow and the
scale or latency requirement is extreme.

## What I took away

- **DynamoDB forces the design work to the front.** You cannot add a query later the way you can
  add a SQL `WHERE` clause.
- **`Scan` is the expensive mistake**, and it looks fine on a table with 100 rows.
- **Hot partitions throttle a table that looks idle in aggregate** — the metric to watch is
  per-partition, not table-level.
- **Multi-AZ is not read scaling.** The standby is invisible; conflating it with a read replica is
  the classic interview trap.
- **Two RDS decisions are effectively permanent**: encryption at rest, and storage you can grow
  but never shrink.
