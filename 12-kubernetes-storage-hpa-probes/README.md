# Kubernetes Storage, HPA & Probes

Session 13, on a 3-node `kind` cluster (Kubernetes **v1.34.0**) with `metrics-server`
installed — HPA cannot function without it.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# kind's kubelet serving certificates are self-signed, so metrics-server must be told to accept them
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Without that patch, metrics-server runs but never reports, and the HPA sits on
`cpu: <unknown>/50%` forever. That failure looks like a broken HPA and is actually a TLS problem
one layer down.

## Part 1 — emptyDir: scratch space that dies with the pod

```bash
$ kubectl exec emptydir-demo -- sh -c 'echo "written at $(date +%T)" > /data/note.txt; cat /data/note.txt'
written at 10:43:56

$ kubectl delete pod emptydir-demo
$ kubectl apply -f 01-volumes/emptydir-pod.yaml

$ kubectl exec emptydir-demo -- ls -la /data/
total 8
drwxrwxrwx 2 root root 4096 Oct  7 10:43 .
drwxr-xr-x 1 root root 4096 Oct  7 10:43 ..

$ kubectl exec emptydir-demo -- cat /data/note.txt
cat: /data/note.txt: No such file or directory
```

Empty. An `emptyDir` is created when the pod is assigned to a node and deleted when the pod
leaves it. It survives a *container* restart but not a *pod* deletion.

That makes it right for scratch space, caches, and sharing files between containers in one pod
— and wrong for anything you would miss.

## Part 2 — PersistentVolume and PersistentVolumeClaim

### The course manifests do not do what they appear to

Applying the static PV and the PVC together:

```bash
$ kubectl get pv
NAME         CAPACITY   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS
student-pv   1Gi        Retain           Available           <unset>

$ kubectl get pvc
NAME          STATUS    VOLUME   CAPACITY   STORAGECLASS
student-pvc   Pending                       standard
```

**The PVC did not bind to the PV.** The PV sits `Available`, the claim sits `Pending`, and the
claim has acquired a `STORAGECLASS` of `standard` that nobody wrote in the YAML.

The cause is the cluster's default StorageClass:

```bash
$ kubectl get storageclass
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

A PVC with **no** `storageClassName` does not mean "any volume" — it means "use the default
StorageClass". The API server stamped `standard` onto the claim, and a claim asking for
`standard` will never bind to a PV that has no storage class.

### `WaitForFirstConsumer`

The claim stayed `Pending` even after the default class was assigned. Only when a pod actually
mounted it did anything happen:

```bash
$ kubectl apply -f 02-persistent-storage/pod.yaml

$ kubectl get pvc student-pvc
NAME          STATUS   VOLUME                                     CAPACITY   STORAGECLASS
student-pvc   Bound    pvc-ff1905e1-4bfe-4fd2-a62d-39e8b94bdf7a   500Mi      standard
```

```
  provisioner : rancher.io/local-path
  reclaim     : Delete
  path        : /var/local-path-provisioner/pvc-ff1905e1-..._default_student-pvc
  node        : devops-lab-worker2
```

`WaitForFirstConsumer` defers provisioning until the scheduler has picked a node, so the volume
is created on the *same* node as the pod. With `Immediate` binding, a volume can be provisioned
on one node and the pod scheduled onto another, and the pod then cannot start.

A **Pending PVC is normal** under this mode until a consumer appears — not a bug to chase.

### Making the static PV bind

```yaml
spec:
  storageClassName: ""        # opt out of dynamic provisioning entirely
```

```bash
$ kubectl get pvc student-pvc-static
NAME                 STATUS   VOLUME       CAPACITY   STORAGECLASS
student-pvc-static   Bound    student-pv   1Gi

$ kubectl get pv student-pv
student-pv   1Gi   RWO   Retain   Bound   default/student-pvc-static
```

`storageClassName: ""` (empty string) is different from omitting the field. Omitted means
"default class"; empty means "no class, match a static PV". That one distinction is the whole
difference between the course manifests working and silently not working.

Note it bound to a **1Gi** PV for a 500Mi request — binding requires capacity ≥ request, not
equality, and the pod gets the whole 1Gi.

### Data actually persists

```bash
$ kubectl exec storage-demo -- sh -c 'echo "persisted at $(date +%T)" > /data/important.txt'
persisted at 10:44:55

$ kubectl delete pod storage-demo
$ kubectl apply -f 02-persistent-storage/pod.yaml

$ kubectl exec storage-demo -- cat /data/important.txt
persisted at 10:44:55
```

Same file, new pod. This is the whole point, and the direct contrast with emptyDir above.

### Reclaim policies

| Policy | On PVC deletion | Seen on |
|---|---|---|
| `Delete` | the PV **and the data** are destroyed | the dynamically provisioned PV |
| `Retain` | the PV survives as `Released`; data kept, manual cleanup | the static `student-pv` |

The dynamic PV defaulted to `Delete`. Deleting a PVC in a production namespace can therefore
destroy the data with no further confirmation — which is why `Retain` is usual for anything
stateful.

## Part 3 — Probes

Covered in depth in [`10-kubernetes-workloads`](../10-kubernetes-workloads/README.md#the-three-probes-do-three-different-jobs);
what that section asserted but did not prove is the practical consequence of readiness, so this
run measures it.

```bash
$ kubectl expose pod readiness-demo --name=readiness-svc --port=80

$ kubectl get endpointslices -l kubernetes.io/service-name=readiness-svc
  10.244.2.6  ready=true
```

Breaking the probe by moving nginx's index page away, so `GET /` returns 404:

```bash
$ kubectl exec readiness-demo -- sh -c 'mv /usr/share/nginx/html/index.html /tmp/'

  t+5s   ready=true
  t+10s  ready=true
  t+15s  ready=false
```

```
NAME             PHASE     READY   RESTARTS
readiness-demo   Running   false   0

endpoints now:
  10.244.2.6  ready=false
```

Three things in that result:

- **`RESTARTS: 0`.** Readiness never restarts anything — that is liveness's job. A failing
  readiness probe is a pod being quietly taken out of rotation.
- **`PHASE: Running`.** Again, phase is not health.
- **The endpoint is marked `ready=false`**, so kube-proxy stops sending it traffic while the
  pod keeps running and can recover on its own.

It took 15s to flip because the probe config is `periodSeconds: 5` with a default
`failureThreshold: 3` — three consecutive failures. That delay is the window during which a
Service still sends traffic to a pod that can no longer serve it.

## Part 4 — Horizontal Pod Autoscaler

```yaml
minReplicas: 1
maxReplicas: 5
metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 50 }
```

The target Deployment requests `cpu: 100m`. **That request is mandatory** — "50% utilization"
means 50% *of the request*, so an HPA on a container with no CPU request has nothing to compute
against and reports `<unknown>` forever.

### At rest

```
NAME       REFERENCE             TARGETS       MINPODS   MAXPODS   REPLICAS
hpa-demo   Deployment/hpa-demo   cpu: 0%/50%   1         5         1
```

### Under load

Three busybox pods hammering the service in a loop:

```
  t+20s   cpu: 0%/50%     replicas 1    | 194m total
  t+40s   cpu: 201%/50%   replicas 4    | 201m total
  t+60s   cpu: 94%/50%    replicas 4    | 264m total
  t+80s   cpu: 66%/50%    replicas 4    | 199m total
  t+100s  cpu: 45%/50%    replicas 5    | 228m total
  t+120s  cpu: 46%/50%    replicas 5    | 287m total
  ...
  t+240s  cpu: 50%/50%    replicas 5    | 193m total
```

**1 → 4 in a single step.** The HPA does not increment; it computes:

```
desiredReplicas = ceil( currentReplicas × currentMetric / targetMetric )
                = ceil( 1 × 201 / 50 )
                = ceil( 4.02 )
                = 4
```

Then it converged: 94% → 66% → 45% as the extra pods absorbed the same total load, settling at
5 replicas hovering around the 50% target. That is a proportional controller doing exactly what
it should.

```
Normal  SuccessfulRescale  New size: 4; reason: cpu resource utilization (percentage of request) above target
Normal  SuccessfulRescale  New size: 5; reason: cpu resource utilization (percentage of request) above target
```

### Scale-down is deliberately slow

Load generators deleted at t=0:

```
  t+30s   cpu: 36%/50%   replicas 5
  t+90s   cpu: 0%/50%    replicas 5     <- CPU already at zero
  t+180s  cpu: 0%/50%    replicas 5
  t+300s  cpu: 0%/50%    replicas 5
  t+390s  cpu: 0%/50%    replicas 1     <- finally scaled down
```

**CPU reached 0% at t+90s and the replicas did not drop until t+390s** — a five-minute wait
with the metric flat at zero.

That is the `scaleDown` **stabilization window**, 300s by default, versus 0s for scale-up. The
asymmetry is intentional: scaling up late costs you an outage, scaling down early costs you a
thrash cycle when load returns. The HPA takes the maximum recommendation over the window, so
one quiet minute cannot shrink a deployment.

Seeing `replicas: 5` with `cpu: 0%` is therefore **not a stuck HPA** — it is the window
elapsing.

### The errors at startup were real too

```
Warning  FailedGetResourceMetric  failed to get cpu utilization: no metrics returned from resource metrics API
Warning  FailedGetResourceMetric  did not receive metrics for targeted pods (pods might be unready)
```

Both appeared in the first minute, before metrics-server had scraped anything. Transient at
startup; persistent means metrics-server is missing, unhealthy, or (on kind) hitting the TLS
problem patched at the top of this page.

## What I took away

- **An omitted `storageClassName` means "default class", not "any volume".** That is why the
  static PV never bound. `storageClassName: ""` is the opt-out, and it is not the same as
  leaving the field out.
- **A `Pending` PVC under `WaitForFirstConsumer` is correct behaviour**, not a fault — binding
  waits for a pod so the volume lands on the right node.
- **`Delete` is the default reclaim policy for dynamic volumes.** Deleting a PVC can delete the
  data with nothing asking you twice.
- **Readiness gates traffic and never restarts.** 0 restarts, still `Running`, removed from the
  endpoint list — and the 3-failure threshold means a 15s window where traffic still flows to a
  broken pod.
- **HPA scales by ratio, in one jump.** `ceil(1 × 201/50) = 4`, not a gradual climb.
- **Scale-up is instant, scale-down waits 300s.** Flat-zero CPU with replicas still at max is
  the stabilization window, not a bug.
- **An HPA with no CPU *request* on the container can never work** — utilization is a
  percentage of the request.

## Cleanup

```bash
kubectl delete -f 04-hpa/ -f 05-probes/ -f 02-persistent-storage/ -f 01-volumes/ --ignore-not-found
kubectl delete svc readiness-svc --ignore-not-found
```
