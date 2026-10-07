# FQDN — Fully Qualified Domain Names in Kubernetes

Name: **Anisha Singhal** · Enrollment: **10020** · Session 11, Task 3

Every command below was run against the 3-node kind cluster used for the rest of this session,
with two namespaces (`dns-demo`, `dns-other`) so cross-namespace resolution is actually
demonstrable rather than described.

## What an FQDN is

A **fully qualified** domain name specifies a host's complete position in the DNS tree, from the
leaf all the way to the root, leaving nothing to be inferred from context.

```
web.dns-demo.svc.cluster.local.
└┬┘ └──┬───┘ └┬┘ └─────┬─────┘ └ the root (usually written implicitly)
 │     │      │        └ cluster domain
 │     │      └ resource type: svc
 │     └ namespace
 └ service name
```

`web` is *relative* — what it means depends on who is asking.
`web.dns-demo.svc.cluster.local` is absolute and means the same thing from anywhere in the
cluster. That difference is the whole subject.

## Kubernetes Service DNS

Every Service gets an A record the moment it is created, maintained by CoreDNS from the
Kubernetes API — nothing registers itself.

```
$ kubectl -n dns-demo exec dnsclient -- nslookup web.dns-demo.svc.cluster.local
Server:         10.96.0.10
Name:   web.dns-demo.svc.cluster.local
Address: 10.96.235.8
```

`10.96.235.8` is the Service's **ClusterIP**, not a pod. Nothing listens on it — it is a virtual
IP that kube-proxy's iptables rules rewrite, as traced in
[01-clusterip](../01-clusterip/README.md#how-it-works-underneath).

`10.96.0.10` is the `kube-dns` Service, which is itself an ordinary ClusterIP Service in
`kube-system`. DNS in Kubernetes is resolved by a workload in the cluster, reached through the
same mechanism as everything else.

## The naming convention

| Object | Record | Resolves to |
|---|---|---|
| Service | `<svc>.<ns>.svc.cluster.local` | ClusterIP |
| Headless Service | `<svc>.<ns>.svc.cluster.local` | **every** ready pod IP |
| StatefulSet pod | `<pod>.<svc>.<ns>.svc.cluster.local` | that pod's IP |
| Pod (by IP) | `<a-b-c-d>.<ns>.pod.cluster.local` | that pod's IP |
| SRV | `_<port>._<proto>.<svc>.<ns>.svc.cluster.local` | port + target |

`cluster.local` is the default cluster domain, set by `--cluster-domain` on the kubelet. It is
configurable, which is why hardcoding it in application config is a portability bug.

The pod form uses **dashes, not dots**, because dots would create extra labels in the name:

```
$ nslookup 10-244-1-12.dns-demo.pod.cluster.local
Name:   10-244-1-12.dns-demo.pod.cluster.local
Address: 10.244.1.12
```

Reverse lookups work too, which is how `kubectl` and monitoring tools turn an IP back into a
name:

```
$ nslookup 10.96.235.8
8.235.96.10.in-addr.arpa   name = web.dns-demo.svc.cluster.local.
```

## Namespace-based DNS, and the search path

This is where the short names come from. Inside a pod:

```
$ kubectl -n dns-demo exec dnsclient -- cat /etc/resolv.conf
search dns-demo.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

The resolver appends each `search` entry in turn to any name with fewer than `ndots` dots. So
from a pod in `dns-demo`:

```
$ nslookup web
Name:   web.dns-demo.svc.cluster.local
Address: 10.96.235.8
```

`web` worked because `dns-demo.svc.cluster.local` was appended first.

**The same short name fails across namespaces**, and this is worth seeing rather than being told:

```
$ kubectl -n dns-demo exec dnsclient -- nslookup api
** server can't find api: NXDOMAIN
command terminated with exit code 1
```

`api` exists — in `dns-other`. None of the three search domains produce a match, so it is
NXDOMAIN. Qualify it with the namespace and it resolves:

```
$ kubectl -n dns-demo exec dnsclient -- nslookup api.dns-other
Name:   api.dns-other.svc.cluster.local
Address: 10.96.149.231
```

Note that `api.dns-other` is still not fully qualified — `svc.cluster.local` was appended by the
second search entry. Three forms work from here; only one is an FQDN:

| Form | Works from `dns-demo`? | Why |
|---|---|---|
| `api` | **no** | search path never reaches `dns-other` |
| `api.dns-other` | yes | `svc.cluster.local` appended |
| `api.dns-other.svc.cluster.local` | yes | already complete |

## Headless Services return every pod

A Service with `clusterIP: None` has no VIP, so DNS hands back the pods themselves:

```
$ nslookup web-headless.dns-demo.svc.cluster.local
Name:   web-headless.dns-demo.svc.cluster.local
Address: 10.244.1.12
Name:   web-headless.dns-demo.svc.cluster.local
Address: 10.244.2.6
```

Exactly the two pod IPs behind it:

```
$ kubectl -n dns-demo get pods -l app=web -o wide
web-79ffc79c64-6rk5x   10.244.1.12
web-79ffc79c64-m2bm7   10.244.2.6
```

The client now chooses, and load balancing becomes its problem instead of kube-proxy's. That is
what database drivers and gRPC clients want — see [05-headless](../05-headless/README.md).

## SRV records

SRV carries the **port** as well as the host, so a client can discover both:

```
$ dig +noall +answer SRV web.dns-demo.svc.cluster.local
web.dns-demo.svc.cluster.local. 30 IN SRV 0 100 80 web.dns-demo.svc.cluster.local.
```

Reading it: priority `0`, weight `100`, **port `80`**, target host. The `_port._proto.` prefixed
form (`_http._tcp.web...`) only works when the Service's port is **named** — an unnamed port has
no such record, which is why that query returned nothing here.

## The ndots:5 tax

`ndots:5` means any name with **fewer than five dots** gets the search path tried first. Almost
every real domain has fewer. Enabling CoreDNS's `log` plugin shows what a single external lookup
actually costs:

```
$ kubectl -n dns-demo exec dnsclient -- nslookup github.com
```

```
coredns-...-85wsl:
  "A IN github.com.dns-demo.svc.cluster.local." NXDOMAIN  0.000221041s
  "A IN github.com.svc.cluster.local."          NXDOMAIN  0.00007425s
  "A IN github.com."                            NOERROR   3.130325085s
  "AAAA IN github.com."                         NOERROR   0.002183375s
coredns-...-vp7z4:
  "A IN github.com.cluster.local."              NXDOMAIN  0.000123666s
```

**Three NXDOMAIN round trips before the real query.** Four queries to resolve one name, spread
across both CoreDNS replicas. On a service making heavy external calls this is a measurable share
of CoreDNS load and of request latency.

Two fixes:

- End external names with a **trailing dot** — `github.com.` is already absolute, and the search
  path is skipped entirely.
- Set `dnsConfig.options` with a lower `ndots` on pods that mostly talk to the internet:

```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

The default is 5 so that `web.dns-demo.svc` style partial names keep working. It is a trade
between convenience inside the cluster and efficiency outside it.

## Pod-to-Service communication, end to end

What happens when application code opens `http://web`:

1. The resolver sees one dot, fewer than `ndots:5`, so it tries the search path.
2. `web.dns-demo.svc.cluster.local` is sent to `10.96.0.10` — itself a ClusterIP, reached via
   iptables.
3. CoreDNS answers from its watch of the Kubernetes API: `10.96.235.8`.
4. The pod opens a TCP connection to `10.96.235.8:80`.
5. **Nothing listens there.** kube-proxy's iptables rules DNAT the packet to one of the ready
   pod IPs, chosen by `--probability`.
6. The pod replies; conntrack rewrites the source back to the ClusterIP so the client sees a
   coherent connection.

DNS resolves to the Service, not the pod. Pod churn never changes the answer, which is the point
— a pod's IP changes on every restart, and the Service name does not.

## What I took away

- **A short name is a search-path accident, not a name.** It works until the caller moves
  namespace, and then fails as NXDOMAIN with no hint about why.
- **`api` failing and `api.dns-other` succeeding is the entire namespace isolation story in DNS**
  — isolation by inconvenience, not by policy.
- **The nameserver is itself a ClusterIP Service.** DNS is not special infrastructure; it is a
  Deployment behind a Service, which is why killing it breaks the cluster in such an ordinary way.
- **`ndots:5` costs three wasted queries per external lookup**, and the trailing dot is a free fix
  almost nobody uses.
- **Headless returns pods, normal Services return a VIP**, and that single difference decides
  whether load balancing is the client's job or the cluster's.
