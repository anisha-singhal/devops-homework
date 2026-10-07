# Kubernetes Object Comparison

Name: **Anisha Singhal** · Enrollment: **10020** · Session 11, Task 2

Three comparisons that are usually answered from memory. Each one below was instead **run on the
3-node kind cluster** in namespace `cmp`, and the output is what settles the argument.

---

# 1. Deployment vs ReplicaSet

## Purpose

| | ReplicaSet | Deployment |
|---|---|---|
| Answers | "are N copies running right now?" | "how do I get from version A to version B safely?" |
| Scope | a single pod template | a sequence of pod templates over time |
| You write | rarely, almost never by hand | nearly always |

## Pod management

Both maintain a replica count by watching pods matching a selector, and both own their pods
through `ownerReferences`. The difference is a layer of indirection — a Deployment does not
manage pods at all:

```
$ kubectl -n cmp get rs cmp-deploy-dcdf6c955 \
    -o jsonpath='{.metadata.name} owned by {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'
cmp-deploy-dcdf6c955 owned by Deployment/cmp-deploy

$ kubectl -n cmp get pod cmp-deploy-dcdf6c955-52zkp \
    -o jsonpath='{.metadata.name} owned by {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'
cmp-deploy-dcdf6c955-52zkp owned by ReplicaSet/cmp-deploy-dcdf6c955
```

**Deployment → ReplicaSet → Pod.** Deleting a pod makes the *ReplicaSet* replace it; the
Deployment is not involved.

## Scaling

Identical in effect — both just change a number. `kubectl scale` works on either.

## Rolling updates

This is the only real difference, and it is decisive. Changing a Deployment's image creates a
**second ReplicaSet** and shifts replicas between the two:

```
$ kubectl -n cmp set image deployment/cmp-deploy web=nginx:1.27-alpine
$ kubectl -n cmp rollout status deployment/cmp-deploy
deployment "cmp-deploy" successfully rolled out

$ kubectl -n cmp get rs -l app=cmp-deploy
cmp-deploy-6f9648b68d  desired=3 current=3 ready=3     ← new
cmp-deploy-dcdf6c955   desired=0 current=0 ready=0     ← old, kept for rollback
```

The old ReplicaSet is **kept at zero**, which is what makes rollback instant — it is a scale-up
of something that already exists:

```
$ kubectl -n cmp rollout history deployment/cmp-deploy
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

A bare ReplicaSet has none of this. Changing its template does **nothing to running pods**:

```
$ kubectl -n cmp set image rs/bare-rs web=nginx:1.27-alpine
replicaset.apps/bare-rs image updated

$ kubectl -n cmp get pods -l app=bare-rs -o custom-columns=NAME:.metadata.name,IMAGE:...
bare-rs-pmzhj  nginx:1.26-alpine
bare-rs-rlg9m  nginx:1.26-alpine
```

Still **1.26** — the template applies to pods created *from now on*, and no existing pod is
replaced. The new image appears only if a pod happens to die. And rollback is not merely
unavailable, it does not exist as a concept:

```
$ kubectl -n cmp rollout history rs/bare-rs
error: no history viewer has been implemented for "ReplicaSet.apps"
```

## The relationship

A Deployment is a **controller of ReplicaSets**, each ReplicaSet pinned to one pod template.
Changing the template creates a new ReplicaSet; updates and rollbacks are both just moving
replicas between them. `revisionHistoryLimit` (default 10) decides how many old ones are kept.

**Use a Deployment.** A bare ReplicaSet is for understanding the mechanism, not for running
anything.

---

# 2. Deployment vs DaemonSet vs StatefulSet

## Use cases

| | Deployment | DaemonSet | StatefulSet |
|---|---|---|---|
| For | stateless, interchangeable replicas | one agent per node | stateful, individually identified pods |
| Examples | web servers, APIs, workers | log shippers, CNI, node-exporter, kube-proxy | PostgreSQL, Kafka, Zookeeper, Elasticsearch |

## Pod creation

The counts tell the story. Same cluster, three controllers:

```
$ kubectl -n cmp get pods -o wide
cmp-deploy-dcdf6c955-52zkp   devops-lab-worker
cmp-deploy-dcdf6c955-hgkt4   devops-lab-worker2
cmp-deploy-dcdf6c955-v6mt4   devops-lab-worker2     ← 3 replicas, placement is the scheduler's choice
cmp-ds-qkmpc                 devops-lab-worker
cmp-ds-w5r8b                 devops-lab-worker2     ← exactly one per eligible node
cmp-sts-0                    devops-lab-worker2
cmp-sts-1                    devops-lab-worker
cmp-sts-2                    devops-lab-worker2     ← ordinal names, created 0 → 1 → 2
```

- **Deployment**: random name suffixes, any node, created all at once.
- **DaemonSet**: no replica count at all — the count *is* the node count.
- **StatefulSet**: ordinal names, created strictly in order, each waiting for the previous.

The DaemonSet reported `DESIRED 2` on a **3-node** cluster:

```
$ kubectl -n cmp get ds cmp-ds
NAME     DESIRED   CURRENT   READY
cmp-ds   2         2         2
```

Because the control-plane node is tainted, and the DaemonSet does not tolerate it:

```
$ kubectl get node devops-lab-control-plane -o jsonpath='{.spec.taints}'
[{"effect":"NoSchedule","key":"node-role.kubernetes.io/control-plane"}]
```

"One per node" means one per **schedulable, tolerated** node. A real log shipper adds a
toleration so it covers control-plane nodes too — otherwise you silently lose their logs.

## Scaling

| | Deployment | DaemonSet | StatefulSet |
|---|---|---|---|
| `kubectl scale` | yes | **no** — add or remove nodes | yes |
| Order | all at once | per node, as nodes join | strictly sequential |
| Scale down | arbitrary pods | with the node | highest ordinal first |

StatefulSet ordering is the point: scaling a 3-node database to 2 must remove member 2, not a
random one.

## Networking

| | Deployment | DaemonSet | StatefulSet |
|---|---|---|---|
| Typical Service | ClusterIP, load balanced | often none, or `hostPort` | **headless**, `clusterIP: None` |
| Per-pod DNS | no | no | **yes** |
| Addressed as | one VIP | the node | each pod individually |

A StatefulSet pod is individually resolvable:

```
$ nslookup cmp-sts-0.cmp-sts.cmp.svc.cluster.local
Address: 10.244.1.18
```

That is `<pod>.<service>.<ns>.svc.cluster.local`. It is how a replica tells its primary apart
from its peers — see [fqdn/](../fqdn/README.md).

## Storage

| | Deployment | DaemonSet | StatefulSet |
|---|---|---|---|
| Volumes | all replicas share one PVC, if any | usually `hostPath` into the node | **one PVC per pod**, created automatically |
| Mechanism | `persistentVolumeClaim` | `hostPath` | `volumeClaimTemplates` |
| On delete | PVC stays | n/a | **PVC survives the pod and the StatefulSet** |

`volumeClaimTemplates` generated one claim per pod, with no PVC written by hand:

```
$ kubectl -n cmp get pvc
data-cmp-sts-0   Bound   100Mi
data-cmp-sts-1   Bound   100Mi
data-cmp-sts-2   Bound   100Mi
```

The naming is `<template>-<pod>`, which is what lets a replacement pod find its own volume again.

## Identity: the experiment that makes it concrete

Delete a Deployment pod — **new name, new IP**, nothing is remembered:

```
before:  cmp-deploy-dcdf6c955-52zkp  10.244.2.10
after :  cmp-deploy-dcdf6c955-78pnm  10.244.2.14
```

Delete a StatefulSet pod — **same name, new IP, same volume**:

```
before:  cmp-sts-1  10.244.2.13
after :  cmp-sts-1  10.244.2.15

$ kubectl -n cmp get pod cmp-sts-1 -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}'
data-cmp-sts-1
```

**The IP changed in both cases.** What a StatefulSet preserves is the *name*, the *DNS record*
and the *volume* — never the IP. Anything that caches a pod IP is broken either way, which is
exactly why the stable identity is a DNS name.

---

# 3. ReplicaSet vs Service

These are not alternatives. They solve different halves of one problem, and a working
application needs both.

## ReplicaSet's responsibility

**Lifecycle.** Keep N pods matching this selector alive. It watches, counts, creates and deletes.
It has no opinion about traffic, and nothing outside it can address what it created.

## Service's responsibility

**Addressing.** Provide one stable name and VIP, discover which pods are currently ready, and
distribute connections among them. It creates nothing and restarts nothing — delete every pod
behind a Service and the Service is perfectly healthy with zero endpoints.

| | ReplicaSet | Service |
|---|---|---|
| Keeps pods running | **yes** | no |
| Stable address | no | **yes** |
| Knows about readiness | only to report it | **uses it** to route |
| Still exists if pods vanish | recreates them | yes, with no endpoints |
| Implemented by | a control-plane controller | kube-proxy, as iptables rules on every node |

## Why a Service is required

Because pod IPs are disposable. From the test above, deleting one pod changed its IP from
`10.244.2.10` to `10.244.2.14`. Any client holding the old address is now talking to nothing.

A ReplicaSet will faithfully keep three pods alive and give you **no way to reach them** that
survives a restart. The Service's selector is re-evaluated continuously, so the set of endpoints
tracks reality:

```
$ kubectl -n dns-demo get endpointslice
web-service-6gflg   IPv4   80   10.244.1.4,10.244.1.6
```

Note that both objects use **label selectors independently**. The ReplicaSet selects pods to
own; the Service selects pods to route to. They are not connected, they merely tend to agree —
which is why a typo in one selector produces a Service with no endpoints while the pods are
perfectly healthy. That failure, and how to spot it, is reproduced in
[01-clusterip](../01-clusterip/README.md#troubleshooting-empty-endpoints-reproduced).

## How traffic reaches a Pod

```
client pod
   │  http://web
   ▼
CoreDNS  ───────────► web.dns-demo.svc.cluster.local → 10.96.235.8 (ClusterIP)
   │
   ▼
10.96.235.8:80  ── nothing listens here ──
   │
   ▼
kube-proxy iptables rules on the client's own node
   │  DNAT, chosen by --probability
   ▼
10.244.1.4:80   (a ready pod, placed there by the ReplicaSet)
```

Five mechanisms, each needing the previous one:

1. **ReplicaSet** creates the pods.
2. **Readiness probes** decide which are fit to serve.
3. **EndpointSlice** controller lists the ready pods matching the Service selector.
4. **kube-proxy** turns that list into iptables rules on every node.
5. **CoreDNS** maps the Service name to the ClusterIP.

Break any one and the symptom looks identical from the client: a connection that fails. The
diagnostic order is the reverse — check endpoints first, because that is where selector and
readiness bugs both surface.

---

## What I took away

- **A Deployment's entire value is the second ReplicaSet.** Scaling is identical; update and
  rollback are not, and `set image` on a bare ReplicaSet silently changes nothing.
- **"One pod per node" has an asterisk** — taints and tolerations, and a DaemonSet reporting
  `DESIRED 2` on a 3-node cluster looks healthy while missing a node entirely.
- **StatefulSet identity is name, DNS and volume — never IP.** Both pod types got a new IP on
  restart.
- **ReplicaSet and Service both select pods, independently.** Nothing enforces that the two
  selectors agree, and that is the most common silent breakage in Kubernetes networking.
- **A Service is not a process.** It is rules on every node, which is why a Service with no
  backing pods is still "healthy".
