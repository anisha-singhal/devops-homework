# Kubernetes Networking & Services

All five Kubernetes Service types, each deployed and tested on a local cluster. Every command
output below and in the sub-folders is real.

**Cluster:** `kind` v0.30.0, Kubernetes **v1.34.0**, 1 control-plane + 2 workers, on Docker
Desktop (macOS arm64). Multi-node on purpose — a single node hides load balancing across
nodes, which is most of what a Service does.

```yaml
# kind-cluster.yaml
nodes:
  - role: control-plane
    kubeadmConfigPatches:                 # label needed by the ingress controller
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - { containerPort: 80,    hostPort: 80 }      # ingress
      - { containerPort: 443,   hostPort: 443 }
      - { containerPort: 30080, hostPort: 30080 }   # NodePort exercise
  - role: worker
  - role: worker
```

## The exercises

| # | Type | What it demonstrates |
|---|---|---|
| [01](01-clusterip/) | `ClusterIP` | internal VIP, CoreDNS, kube-proxy iptables, endpoint churn, empty-endpoint debugging |
| [02](02-nodeport/) | `NodePort` | a port on **every** node, the three-port model, why you would not ship it |
| [03](03-loadbalancer/) | `LoadBalancer` | `<pending>` with no cloud provider, then made real with MetalLB |
| [04](04-externalname/) | `ExternalName` | a CNAME with no proxy, no VIP, no endpoints |
| [05](05-headless/) | Headless | `clusterIP: None`, DNS returns every pod IP, StatefulSet identity |

## The written tasks

| Task | Folder | Covers |
|---|---|---|
| 2 | [comparisons/](comparisons/) | Deployment vs ReplicaSet · Deployment vs DaemonSet vs StatefulSet · ReplicaSet vs Service — each demonstrated on the cluster, not asserted |
| 3 | [fqdn/](fqdn/) | FQDN structure, Service DNS, the search path, namespace isolation, SRV records, the `ndots:5` tax |
| 4 | [coredns/](coredns/) | what CoreDNS is, the Corefile line by line, query resolution from its own logs, a deliberate DNS outage and recovery |

## How they relate

They are not five alternatives — they are layers:

```
ClusterIP        internal VIP, kube-proxy load balances
   +
NodePort         ... plus a port on every node          (still has a ClusterIP)
   +
LoadBalancer     ... plus an external IP                (still has a NodePort: 80:32499/TCP)

ExternalName     none of the above - a DNS CNAME, no traffic through the cluster
Headless         clusterIP: None - DNS only, the client picks the pod
```

The LoadBalancer service in exercise 03 shows `80:32499/TCP` — it was allocated a NodePort
automatically, because a cloud load balancer's job is to forward to one.

## Comparison

| Type | ClusterIP | Selector | Endpoints | DNS returns | Reachable from |
|---|---|---|---|---|---|
| `ClusterIP` | allocated | yes | pod IPs | one VIP | inside cluster |
| `NodePort` | allocated | yes | pod IPs | one VIP | any node's IP:30000-32767 |
| `LoadBalancer` | allocated | yes | pod IPs | one VIP | an external IP |
| `ExternalName` | none | no | **none** | a CNAME | wherever the target is |
| Headless | **None** | yes | pod IPs | **every pod IP** | inside cluster, per pod |

## Findings worth keeping

- **Load balancing is random, not round-robin.** 60 requests through a ClusterIP split
  24/19/17, and the kube-proxy rule explains exactly why: `--probability 0.333`, then `0.5` of
  the remainder, then the rest. Per-connection fairness is statistical only.
  → [01](01-clusterip/README.md#how-it-works-underneath)

- **A Service is not a process.** Nothing listens on a ClusterIP. It is netfilter rules on
  every node, rewritten whenever endpoints change. → [01](01-clusterip/README.md#how-it-works-underneath)

- **NodePort answers on nodes running zero pods.** The control-plane node had none of the
  app's pods and still returned HTTP 200 on :30080. → [02](02-nodeport/README.md#it-listens-on-every-node--including-nodes-with-no-pods)

- **`<pending>` with no events means nobody is watching**, not that something failed. A
  `type: LoadBalancer` service only writes a request; a cloud-controller has to fulfil it.
  MetalLB is that missing controller. → [03](03-loadbalancer/README.md#the-default-result-pending-forever)

- **ExternalName cannot validate its own target.** The course manifest points at
  `nencyravaliya.me`, which has **no A and no NS records** — the domain does not resolve for
  anyone. The Service reports perfect health regardless; the failure only ever surfaces at the
  client. → [04](04-externalname/README.md#the-courses-target-domain-is-dead)

- **Empty endpoints means opposite things depending on type.** For ClusterIP it is a bug —
  usually a selector that does not match (label selectors are case-sensitive, and Kubernetes
  never warns). For ExternalName there is no EndpointSlice at all, and that is correct.
  → [01](01-clusterip/README.md#troubleshooting-empty-endpoints-reproduced)

- **StatefulSet identity survives the pod.** Deleting `web-stateful-1` brought back the same
  *name* with a new IP, and its per-pod DNS record followed. A Deployment's replacement gets a
  brand-new random name. → [05](05-headless/README.md#stable-identity-across-a-restart)

- **`v1 Endpoints` is deprecated in Kubernetes 1.33+.** `kubectl get endpoints` still works but
  warns; `EndpointSlice` is the current object.

- **`nslookup` exiting 1 does not mean DNS failed** — the search-domain misses produce NXDOMAIN
  noise around a successful answer. Read the output, not the exit code.

## Cleanup

```bash
kind delete cluster --name devops-lab
```
