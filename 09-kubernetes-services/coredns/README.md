# CoreDNS

Name: **Anisha Singhal** · Enrollment: **10020** · Session 11, Task 4

All output below is from the 3-node kind cluster used for this session, including a deliberate
DNS outage and its recovery.

## What CoreDNS is

A general-purpose DNS server written in Go, built entirely from **plugins** chained together.
It is a CNCF graduated project and has been the Kubernetes default since 1.13, replacing
`kube-dns`.

Inside a cluster it runs as an ordinary Deployment in `kube-system`, fronted by an ordinary
Service:

```
$ kubectl -n kube-system get deployment coredns
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           38m

$ kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
coredns-66bc5c9577-85wsl   Running   10.244.0.3   devops-lab-control-plane
coredns-66bc5c9577-vp7z4   Running   10.244.0.2   devops-lab-control-plane

$ kubectl -n kube-system get svc kube-dns
NAME       TYPE        CLUSTER-IP   PORT(S)
kube-dns   ClusterIP   10.96.0.10   53/UDP,53/TCP,9153/TCP
```

The Service is still called `kube-dns` for backward compatibility — the name outlived the
implementation it referred to.

`10.96.0.10` is the address every pod has in `/etc/resolv.conf`. There is nothing privileged
about it: it is a ClusterIP like any other, reached through kube-proxy's iptables rules.

## Why Kubernetes uses it

`kube-dns` was three containers (`kubedns`, `dnsmasq`, `sidecar`) wired together. CoreDNS
replaced it with one process, and the reasons were practical:

| | kube-dns | CoreDNS |
|---|---|---|
| Processes | 3 containers | 1 |
| Config | flags across components | one Corefile |
| Extending it | fork something | add a plugin line |
| Memory | higher | lower |
| Known issues | dnsmasq CVEs, cache quirks | — |

The deeper reason is the plugin model. Stub domains, custom rewrites, per-zone forwarding and
Prometheus metrics are all one line in a config file rather than a separate component.

## How Service discovery works

The `kubernetes` plugin **watches the Kubernetes API** for Services and EndpointSlices and
answers from that in-memory view. Nothing registers itself with DNS, and there is no zone file.

```
Service created
      │
      ▼
  API server ──watch──► CoreDNS (kubernetes plugin)
                              │
                              ▼
                     in-memory records
                              │
   pod query ───► 10.96.0.10 ─┘───► answer
```

Consequences worth internalising:

- A Service is resolvable **immediately**, no propagation delay.
- Records have a **30-second TTL** here (`ttl 30` in the Corefile), so a stale cached answer can
  outlive a deleted Service by that long.
- If CoreDNS cannot reach the API server, it serves an increasingly stale view rather than
  failing loudly.

## The Corefile

The entire configuration, stored in a ConfigMap:

```
$ kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

Line by line:

| Directive | Does |
|---|---|
| `.:53` | serve all zones on port 53 |
| `errors` | log errors to stdout |
| `health` / `ready` | liveness and readiness endpoints; `lameduck 5s` keeps serving 5s after SIGTERM so in-flight queries finish |
| `kubernetes cluster.local …` | the Service discovery plugin, authoritative for `cluster.local` and reverse zones |
| `pods insecure` | enables `<ip-dashes>.<ns>.pod.cluster.local` records |
| `fallthrough in-addr.arpa ip6.arpa` | reverse lookups it cannot answer pass to the next plugin instead of returning NXDOMAIN |
| `ttl 30` | TTL on cluster records |
| `prometheus :9153` | metrics endpoint |
| `forward . /etc/resolv.conf` | everything non-cluster goes upstream, to the node's own resolver |
| `cache 30` | cache responses for 30s |
| `loop` | detects a forwarding loop and crashes on purpose, rather than melting |
| `reload` | watches the ConfigMap and reloads without a restart |
| `loadbalance` | shuffles A records in responses |

**Plugin order in the file is not execution order** — CoreDNS uses a fixed chain order compiled
in. Rearranging lines does not rearrange behaviour, which surprises people trying to "put cache
first".

The `reload` plugin is genuinely useful: editing the ConfigMap takes effect within a couple of
minutes with no pod restart. That is how the `log` plugin was switched on for the experiment
below and switched off again afterwards.

Common customisations:

```
# send one domain to a specific resolver
corp.internal:53 {
    forward . 10.0.0.53
}

# rewrite one name to another
rewrite name legacy.default.svc.cluster.local web.dns-demo.svc.cluster.local
```

## How DNS queries are resolved

Adding `log` to the Corefile makes the whole path visible. One lookup of `github.com` from a pod
in `dns-demo`:

```
"A IN github.com.dns-demo.svc.cluster.local." NXDOMAIN  0.000221041s
"A IN github.com.svc.cluster.local."          NXDOMAIN  0.00007425s
"A IN github.com.cluster.local."              NXDOMAIN  0.000123666s
"A IN github.com."                            NOERROR   3.130325085s
"AAAA IN github.com."                         NOERROR   0.002183375s
```

Three things to read out of that:

1. **Three search-domain misses before the real query**, caused by `ndots:5`. Explained in
   [fqdn/README.md](../fqdn/README.md#the-ndots5-tax).
2. The cluster-local NXDOMAINs take **~0.1 ms** — answered from memory. The upstream query took
   **3.1 seconds** on a cold cache. Internal and external resolution are not remotely comparable
   in cost.
3. The queries were spread across **both CoreDNS replicas**, because the client reaches them
   through a ClusterIP and kube-proxy picks a backend per query.

The decision CoreDNS makes for each query is simply whether the name falls inside
`cluster.local` (answer authoritatively from the API watch) or outside it (`forward` upstream,
then `cache`).

## Metrics

The `prometheus :9153` line exposes everything needed to monitor DNS health:

```
$ curl -s http://10.96.0.10:9153/metrics | grep -E 'coredns_dns_requests_total|coredns_cache'
coredns_cache_misses_total{server="dns://:53",zones="."} 10
coredns_dns_requests_total{proto="udp",type="A",zone="."} 2
coredns_dns_requests_total{proto="udp",type="AAAA",zone="."} 1
coredns_dns_requests_total{proto="udp",type="PTR",zone="."} 1
```

Worth alerting on: `coredns_dns_responses_total{rcode="SERVFAIL"}`, request duration
percentiles, and the cache hit ratio. The session 20 Prometheus setup scrapes exactly this kind
of endpoint — see [19-monitoring-gitops](../../19-monitoring-gitops/README.md).

## Troubleshooting DNS issues

### The commands

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns          # are they running?
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50    # errors? loop detected?
kubectl -n kube-system get svc kube-dns                       # ClusterIP present?
kubectl -n kube-system get endpointslice -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system get configmap coredns -o yaml          # Corefile sane?
kubectl exec -it <pod> -- cat /etc/resolv.conf                # right nameserver and search?
kubectl exec -it <pod> -- nslookup kubernetes.default         # the always-present Service
```

`kubernetes.default.svc.cluster.local` is the useful test target — it exists in every cluster, so
a failure there is never about the application's own Services.

### A real outage, induced on purpose

```
$ kubectl -n kube-system scale deployment coredns --replicas=0
deployment.apps/coredns scaled
```

The symptom an application sees:

```
$ kubectl -n dns-demo exec dnsclient -- nslookup web
;; communications error to 10.96.0.10#53: connection refused
;; no servers could be reached
command terminated with exit code 1
```

**`connection refused`, not a timeout** — and that distinction is the diagnosis. The Service
still exists:

```
$ kubectl -n kube-system get svc kube-dns
kube-dns   ClusterIP   10.96.0.10   53/UDP,53/TCP,9153/TCP
```

but it has no endpoints:

```
$ kubectl -n kube-system get endpointslice -l kubernetes.io/service-name=kube-dns \
    -o jsonpath='{.items[*].endpoints}'
null
```

With zero endpoints, kube-proxy installs a **REJECT** rule rather than leaving packets to be
dropped, so the client is refused immediately instead of hanging. Reading it the other way: a
DNS **timeout** points at network policy, a security group or a node problem; a **refusal**
points at endpoints, and therefore at pods or selectors.

Recovery:

```
$ kubectl -n kube-system scale deployment coredns --replicas=2
$ kubectl -n kube-system rollout status deployment/coredns
deployment "coredns" successfully rolled out

$ kubectl -n dns-demo exec dnsclient -- nslookup web
Name:   web.dns-demo.svc.cluster.local
Address: 10.96.235.8
```

### Symptom table

| Symptom | Likely cause | Check |
|---|---|---|
| `connection refused` on :53 | CoreDNS has no ready pods | `get endpointslice -l kubernetes.io/service-name=kube-dns` |
| Query **times out** | NetworkPolicy, node networking, or kube-proxy | `get networkpolicy -A`, kube-proxy logs |
| NXDOMAIN for a Service that exists | wrong namespace in the name, or a selector matching nothing | `get endpointslice -n <ns>` |
| Resolves to the wrong IP | stale cache within the 30s TTL | wait, or check `cache` settings |
| CoreDNS `CrashLoopBackOff` with "Loop detected" | node `/etc/resolv.conf` points back at the cluster DNS | fix the node resolver or set `resolvConf` on the kubelet |
| Everything slow but working | `ndots:5` search tax, or an unreachable upstream | enable `log`, read the NXDOMAIN pattern |
| `nslookup` exits 1 but prints an answer | search-domain NXDOMAIN noise | read the output, not the exit code |

### Scaling and placement

Two replicas is the kind default, and in this cluster **both landed on the control-plane node** —
so a single node failure would take all cluster DNS with it. Production clusters use
`cluster-proportional-autoscaler`, a `PodDisruptionBudget`, and anti-affinity to spread replicas
across nodes. Worth checking on any cluster before trusting its DNS.

NodeLocal DNSCache is the next step at scale: a DaemonSet caching on every node, which removes a
network hop and absorbs the `ndots` tax locally.

## What I took away

- **CoreDNS is a normal workload**, which is why it fails in completely normal ways — no
  endpoints, bad config, crash loop.
- **`connection refused` vs timeout is the fastest DNS triage split there is**, and it falls out
  of how kube-proxy handles an empty endpoint list.
- **The Corefile is the whole configuration**, and `reload` means changing it needs no restart.
- **Cluster lookups are ~0.1 ms, upstream ones can be seconds.** Those are different systems
  sharing one resolver address.
- **Both replicas on one node is a single point of failure** that a healthy-looking `2/2 Ready`
  completely hides.
