# Kubernetes Fundamentals

Session 9 is a reading list rather than a set of manifests, so rather than restate the docs I
inspected a real cluster and recorded what each architectural claim looks like in practice.

**Cluster:** `kind` v0.30.0, Kubernetes **v1.34.0**, 1 control-plane + 2 workers, containerd
2.1.3, on Docker Desktop (macOS arm64).

## What Kubernetes actually is

A **declarative** system built on **control loops**. You submit the desired state; controllers
continuously compare it to observed state and act on the difference. Nothing is a one-off
command — which is why `kubectl apply` is idempotent and why deleting a pod does not remove it.

That single idea explains most of the behaviour in the other sections: a ReplicaSet recreating
a pod, a Deployment moving two replica counters, a Service's endpoints re-binding after a pod
dies, MetalLB filling in an `EXTERNAL-IP`.

## The control plane, actually running

```bash
$ kubectl get pods -n kube-system -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName
etcd-devops-lab-control-plane                      devops-lab-control-plane
kube-apiserver-devops-lab-control-plane            devops-lab-control-plane
kube-controller-manager-devops-lab-control-plane   devops-lab-control-plane
kube-scheduler-devops-lab-control-plane            devops-lab-control-plane
coredns-66bc5c9577-lc4hw                           devops-lab-control-plane
coredns-66bc5c9577-vgzmd                           devops-lab-control-plane
kube-proxy-nl94m                                   devops-lab-control-plane
kube-proxy-42x4j                                   devops-lab-worker
kube-proxy-wg496                                   devops-lab-worker2
kindnet-976lk                                      devops-lab-control-plane
kindnet-lxjrw                                      devops-lab-worker
kindnet-sc5xm                                      devops-lab-worker2
```

Two groups are visible in that list, and the difference is the architecture:

**Control plane — one copy, on the control-plane node only:**

| Component | Job |
|---|---|
| `kube-apiserver` | the only thing that talks to etcd; every read and write goes through it |
| `etcd` | the datastore — all cluster state, nothing else |
| `kube-scheduler` | picks a node for each unscheduled pod |
| `kube-controller-manager` | runs the control loops (ReplicaSet, endpoints, node, and others) |

**Node agents — one copy per node:**

| Component | Job |
|---|---|
| `kubelet` | starts and watches containers on its node (not a pod here — it runs on the host) |
| `kube-proxy` | writes the iptables rules that implement Services |
| `kindnet` | the CNI plugin; the pod network (Calico/Flannel/Cilium elsewhere) |

`kube-proxy` and `kindnet` are DaemonSets — three copies, one per node. That matches what the
Services section measured: a ClusterIP works from **any** node because every node has a
kube-proxy writing the same rules.

`kubelet` is the notable absence from that list. It runs as a systemd unit on each node rather
than as a pod, because something has to exist before pods can be started.

```bash
$ kubectl cluster-info
Kubernetes control plane is running at https://127.0.0.1:52151
CoreDNS is running at https://127.0.0.1:52151/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

## Everything goes through the API server

```bash
$ kubectl api-resources | wc -l
72 resource kinds
$ kubectl api-versions | wc -l
24 api group-versions
```

72 kinds of object in a stock cluster. The important structural point: **no component talks to
etcd except the API server**, and no component talks to another component directly. The
scheduler does not call the kubelet; it writes `spec.nodeName` and the kubelet notices.

Controllers watch the API and write back to it. That is why `kubectl get events` can
reconstruct a complete causal trail, and why adding a custom controller requires no changes to
anything else.

## The reconciliation loop, observed

```bash
$ kubectl create deployment recon-demo --image=nginx:1.25-alpine --replicas=2
declared replicas : 2
observed replicas : 2
```

Deleting **both** pods behind the controller's back:

```bash
$ kubectl delete pod -l app=recon-demo
pod "recon-demo-7dbc876c79-6lzt2" deleted
pod "recon-demo-7dbc876c79-ct2d2" deleted

$ # 8 seconds later
observed replicas after: 2
```

Nothing instructed it to recreate them. `spec.replicas: 2` is a standing statement about how
the world should be, and the ReplicaSet controller acts on any divergence, forever.

The event trail shows each component doing its own part:

```
Normal  SuccessfulCreate  replicaset/recon-demo-7dbc876c79   Created pod: recon-demo-7dbc876c79-qdrnx
Normal  Scheduled         pod/recon-demo-7dbc876c79-qdrnx    Successfully assigned default/... to devops-lab-worker
Normal  Started           pod/recon-demo-7dbc876c79-qdrnx    Started container nginx
Normal  Killing           pod/recon-demo-7dbc876c79-ct2d2    Stopping container nginx
```

Read in order, that is the whole architecture in four lines:

1. **controller-manager** notices `observed < desired` and creates a Pod object — with no node
   assigned.
2. **scheduler** sees an unscheduled pod, picks a node, writes it back.
3. **kubelet** on that node sees a pod assigned to it and starts the container.
4. Meanwhile the old container is stopped.

No component called another. Each watched the API server and reacted.

```
Scheduled  ... assigned to devops-lab-worker
Scheduled  ... assigned to devops-lab-worker2
```

The scheduler spread the two replicas across both workers — default behaviour, so a single node
failure does not take out every replica.

## Nodes

```bash
$ kubectl get nodes -o custom-columns=NODE:...,VERSION:...,RUNTIME:...,OS:...
NODE                       VERSION   RUNTIME              OS
devops-lab-control-plane   v1.34.0   containerd://2.1.3   Debian GNU/Linux 12 (bookworm)
devops-lab-worker          v1.34.0   containerd://2.1.3   Debian GNU/Linux 12 (bookworm)
devops-lab-worker2         v1.34.0   containerd://2.1.3   Debian GNU/Linux 12 (bookworm)
```

The container runtime is **containerd**, not Docker. Kubernetes talks to runtimes through the
**CRI** interface; Docker support was removed in 1.24. The images are still standard OCI
images — `nginx:1.25-alpine` runs unchanged — but the daemon running them is not Docker, even
on a cluster whose nodes are themselves Docker containers.

### The control-plane taint

```bash
$ kubectl get nodes -o custom-columns=NODE:.metadata.name,TAINTS:.spec.taints[*].key
devops-lab-control-plane   node-role.kubernetes.io/control-plane
devops-lab-worker          <none>
devops-lab-worker2         <none>
```

`NoSchedule`, so ordinary workloads never land on the control-plane node. This one line of
configuration explained two separate observations elsewhere: a DaemonSet reporting `DESIRED 2`
on a 3-node cluster, and a `Pending` pod whose scheduler message read
`1 node(s) had untolerated taint ... 2 Insufficient memory`.

## Why a cluster at all

Docker runs containers on one machine. The Docker sections in this repo stop exactly where
these questions start:

| Question | Docker | Kubernetes |
|---|---|---|
| A container dies at 3am | it stays dead | the controller recreates it |
| One machine is not enough | manual | the scheduler places pods across nodes |
| Deploy a new version with no downtime | scripted by hand | a rolling update primitive |
| A backend's IP keeps changing | hardcode or script | a Service with a stable name |
| Same image, different config per env | rebuild or `-e` flags | ConfigMaps and Secrets |
| One entry point for many services | run your own nginx | Ingress |

## Objects worth knowing on day one

| Object | What it is |
|---|---|
| **Pod** | the scheduling unit — one or more containers sharing a network namespace |
| **ReplicaSet** | keeps N pods running |
| **Deployment** | manages ReplicaSets to give rollouts and rollbacks |
| **DaemonSet** | one pod per (eligible) node |
| **StatefulSet** | ordered pods with stable names and per-pod storage |
| **Job / CronJob** | run to completion, once or on a schedule |
| **Service** | stable name and address in front of a changing set of pods |
| **Ingress** | HTTP routing by host and path into the cluster |
| **ConfigMap / Secret** | configuration and credentials, separate from the image |
| **Namespace** | a scope for names and quotas |

Each is covered with real output in the sections that follow:

- [`09-kubernetes-services/`](../09-kubernetes-services/) — Services, all five types
- [`10-kubernetes-workloads/`](../10-kubernetes-workloads/) — Pods, ReplicaSets, Deployments
- [`11-kubernetes-config-ingress/`](../11-kubernetes-config-ingress/) — ConfigMaps, Secrets, Ingress

## What I took away

- **Nothing calls anything.** Components watch the API server and write back to it. The
  four-line event trail above is the entire architecture, and it is why the system tolerates
  any single controller being down.
- **Desired state is a standing instruction, not a command.** Deleting both pods changed
  nothing about what the cluster was trying to do.
- **`kubectl get events --sort-by=.lastTimestamp` reconstructs causality** — which controller
  acted, what the scheduler decided, what the kubelet did. It is the first place to look when
  something did not happen.
- **One taint explained failures in two other sections.** Cluster-level configuration surfaces
  as confusing workload-level symptoms, so it is worth checking `kubectl get nodes` early.
- **The runtime is containerd, not Docker** — the images are the same, the daemon is not.
