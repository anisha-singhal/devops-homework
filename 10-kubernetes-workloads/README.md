# Kubernetes Pods, ReplicaSets & Deployments

Session 10, run on the same 3-node `kind` cluster (Kubernetes **v1.34.0**, 1 control-plane +
2 workers). Everything below was executed; all output is real.

| Folder | Covers |
|---|---|
| [`01-core-objects/`](01-core-objects/) | Pod, ReplicaSet, Deployment, DaemonSet, StatefulSet |
| [`02-pod-lifecycle/`](02-pod-lifecycle/) | all 12 lifecycle scenarios and probe behaviour |
| [`03-deployment-strategies/`](03-deployment-strategies/) | blue-green, canary, recreate |

## Part 1 — The core objects

### Pod: the unit of scheduling, not of containers

`pod.yml` runs **two** containers, `app` (nginx) and `logger` (busybox):

```bash
$ kubectl get pod mypod -o 'custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name,IP:.status.podIP'
mypod   true,true   app,logger   10.244.1.8
```

One IP for two containers. Confirmed from inside each:

```
  app    sees: 10.244.1.8
  logger sees: 10.244.1.8
  pod IP     : 10.244.1.8
```

That is the definition of a Pod: **containers sharing a network namespace** (and so
`localhost`, and the port space). They are co-scheduled on one node and live and die together.
This is why a sidecar can reach the main container on `localhost:80` with no service, and why
two containers in one pod cannot both bind port 80.

```bash
$ kubectl logs mypod -c logger --tail=3
log
log
```

`-c` is required once a pod has more than one container.

### DaemonSet: one pod per node — with an exception

```bash
$ kubectl get ds node-exporter
NAME            DESIRED   CURRENT   READY   AGE
node-exporter   2         2         2       21s
```

**DESIRED is 2 on a 3-node cluster.** Not a bug:

```bash
$ kubectl get nodes -o 'custom-columns=NODE:.metadata.name,TAINTS:.spec.taints[*].key'
devops-lab-control-plane   node-role.kubernetes.io/control-plane
devops-lab-worker          <none>
devops-lab-worker2         <none>
```

The control-plane carries a `NoSchedule` taint, and this DaemonSet declares no toleration, so
it schedules on workers only. A real monitoring agent would add a toleration precisely because
you *do* want metrics from control-plane nodes — a DaemonSet says "every node I am allowed to
run on", not "every node".

### ReplicaSet: self-healing, and nothing else

```bash
$ kubectl get pods -l app=web
myapp-rs-8d5qh
myapp-rs-grffv
myapp-rs-lnlbq

$ kubectl delete pod myapp-rs-8d5qh

$ kubectl get pods -l app=web
myapp-rs-grffv
myapp-rs-lnlbq
myapp-rs-wvjmm     <- replaced automatically
```

The controller reconciles observed state toward `replicas: 3`. Delete one and another appears;
this is the control loop that underpins every workload type.

### The reason Deployments exist

Change the image on a **bare ReplicaSet**:

```bash
$ kubectl set image rs/myapp-rs web=nginx:1.25-alpine

RS template image now: nginx:1.25-alpine
but existing pods still run: nginx
```

**Nothing rolled.** The ReplicaSet updated its template and left the running pods completely
alone — the new image would only appear on pods created later, e.g. after a delete. A
ReplicaSet maintains a count; it has no concept of a release.

The same change on a **Deployment**:

```bash
$ kubectl set image deployment/myapp myapp-container=nginx:1.25-alpine
Waiting for deployment "myapp" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "myapp" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "myapp" rollout to finish: 1 old replicas are pending termination...
deployment "myapp" successfully rolled out
```

```
RS                 DESIRED   READY    IMAGE
myapp-55d8f46968   0         <none>   nginx
myapp-7bf44664     3         3        nginx:1.25-alpine
```

**A second ReplicaSet was created**, scaled up as the first scaled down. The old one was kept
at 0 rather than deleted.

### The ownership chain

```bash
  ReplicaSet myapp-55d8f46968     ownedBy-> Deployment/myapp
  Pod        myapp-55d8f46968-28pbj  ownedBy-> ReplicaSet/myapp-55d8f46968
```

**Deployment → ReplicaSet → Pod.** A Deployment never creates pods; it creates ReplicaSets and
manipulates their replica counts. A "rolling update" is literally two counters moving in
opposite directions — which is why the retained old ReplicaSet *is* the rollback mechanism:

```bash
$ kubectl rollout undo deployment/myapp
```

```
RS                 DESIRED   READY    IMAGE
myapp-55d8f46968   3         3        nginx              <- scaled back up
myapp-7bf44664     0         <none>   nginx:1.25-alpine
```

No image pull, no rebuild — the old ReplicaSet was still there and just needed scaling. That is
why rollback is near-instant.

```bash
$ kubectl rollout history deployment/myapp
REVISION  CHANGE-CAUSE
2         <none>
3         <none>
```

Revision 1 is gone: the undo created revision 3 rather than reverting to 1. Rollbacks move
history forward. (`CHANGE-CAUSE` is empty because `--record` is deprecated; annotate with
`kubernetes.io/change-cause` to populate it.)

The pace came from defaults nobody set:

```
  type          : RollingUpdate
  maxSurge      : 25%
  maxUnavailable: 25%
```

With 3 replicas: at most 4 pods total, at least 2 available — which is exactly the
"1 of 3 → 2 of 3 → 1 old pending termination" progression above.

## Part 2 — Pod lifecycle

All twelve scenarios applied at once, then observed as they settled.

### At t = 90s

```
NAME                        PHASE       READY       RESTARTS   WAITING
lifecycle-running           Running     true        0          <none>
lifecycle-pending           Pending     <none>      <none>     <none>
lifecycle-succeeded         Succeeded   false       0          <none>
lifecycle-failed            Failed      false       0          <none>
lifecycle-crashloop         Running     false       3          CrashLoopBackOff
lifecycle-image-error       Pending     false       0          ImagePullBackOff
lifecycle-readiness         Running     true        0          <none>
lifecycle-liveness          Running     true        1          <none>
lifecycle-startup           Running     true        0          <none>
lifecycle-init              Running     true        0          <none>
lifecycle-multi-container   Running     true,true   0,0        <none>
lifecycle-termination       Running     true        0          <none>
```

### `Running` does not mean healthy

The most important row:

```
  phase  : Running
  ready  : false
  reason : CrashLoopBackOff
```

`lifecycle-crashloop` reports **phase `Running`** while restarting endlessly. Phase describes
where the pod is in its lifecycle, not whether it works. **`READY` is the field that matters** —
it is what puts a pod into a Service's endpoint list. A dashboard that alerts on phase alone
will happily show green through an outage.

There are only five phases — `Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`.
`CrashLoopBackOff` and `ImagePullBackOff` are **not phases**; they are container *waiting
reasons*, which is why they appear in a different column.

### `Pending`: the scheduler tells you exactly why

```bash
$ kubectl describe pod lifecycle-pending | grep -A2 Events
Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
  2 Insufficient memory.
```

Two different reasons across three nodes, both stated. The pod requests 9Gi:

```
devops-lab-control-plane   8125988Ki    (~7.75Gi)
devops-lab-worker          8125988Ki
devops-lab-worker2         8125988Ki
```

No node can satisfy it, so it waits forever — Kubernetes does not fail a pod it cannot
schedule. `kubectl describe` is the first command for any `Pending`, and it usually contains
the complete answer.

### `ImagePullBackOff` is the second state, not the first

```
Warning  Failed   (x3 over 81s)  kubelet  Error: ErrImagePull
Normal   BackOff  (x4 over 80s)  kubelet  Back-off pulling image "jakwehrgkaejw:kahsdfgkhj"
Warning  Failed   (x4 over 80s)  kubelet  Error: ImagePullBackOff
```

First `ErrImagePull` (a real attempt failed), then `ImagePullBackOff` (kubelet is now waiting
between retries). Note the phase stayed `Pending` — the container never started, so the pod
never reached `Running`.

### The three probes do three different jobs

**Readiness** — gates traffic, never restarts:

```
lifecycle-readiness   Running   true   restarts=0
```

**Liveness** — restarts the container. The manifest deletes `/tmp/healthy` after 20s:

```
Warning  Unhealthy  (x4 over 86s)  kubelet  Liveness probe failed:
Normal   Killing    (x2 over 81s)  kubelet  Container app failed liveness probe, will be restarted
restart count: 1
```

**Startup** — protects a slow starter. The app sleeps 30s before signalling readiness, and
`failureThreshold: 10 × periodSeconds: 5` gives it 50s:

```
lifecycle-startup   ready=true   restarts=0
```

**Zero restarts.** Without a startup probe, a liveness probe would have killed this container
mid-boot, forever — the classic crash loop on a slow-starting app. The startup probe suspends
liveness until the app is up.

### Init containers run first, to completion

```
  init  : setup -> terminated reason=Completed exit=0
  app   : app   -> running=true
```

```bash
$ kubectl logs lifecycle-init -c setup
Init container running
Init complete
```

The pod sat in `PodInitializing` for 10s. Init containers run **sequentially before** app
containers, and a non-zero exit blocks the pod. That is the ordering primitive for
"wait for the database / fetch config / run migrations".

## Part 3 — Deployment strategies

### Blue-green: an instant switch

Both versions run simultaneously, distinguished by a `slot` label:

```
DEPLOY      READY   IMAGE
app-blue    3       nginx:1.24-alpine
app-green   3       nginx:1.25-alpine
```

The Service selects one of them:

```
  selector: {"app":"myapp","slot":"blue"}
```

I ran continuous traffic (60 requests, 0.2s apart) and flipped the selector to `green`
mid-flight:

```
  20 BLUE ENVIRONMENT
  40 GREEN ENVIRONMENT
```

That is `uniq -c` on the **unsorted** log, so it is two contiguous runs: 20 blue, then 40
green, **no interleaving and no failed requests**. The cutover was atomic — the endpoint list
was recomputed in one step.

The cost is honest: **double the resources** while both slots run. The benefit is that
rollback is the same one-line selector change, with v1 already warm.

### Canary: proportion by pod count

One service selects both deployments through a shared label:

```
app-stable   9 replicas   nginx:1.24-alpine
app-canary   1 replica    nginx:1.25-alpine
  endpoints: 10
```

100 requests:

```
  12 CANARY
  88 STABLE
```

~10%, as designed — 1 of 10 endpoints. Scaling the split is just scaling deployments:

```bash
kubectl scale deploy/app-canary --replicas=3
kubectl scale deploy/app-stable --replicas=7
```

```
  24 CANARY
  76 STABLE
```

Both results sit near their targets without hitting them exactly (12 vs 10, 24 vs 30) — the
same random per-connection selection measured in the Services section. **Traffic share is
statistical, and its granularity is limited by pod count**: 10 pods cannot express 5%. Getting
precise percentages, or routing by header or user, needs a service mesh or an Ingress that
supports weighting — not bare Services.

### Recreate: downtime, by design

```
DEPLOY         STRATEGY   READY
app-recreate   Recreate   3
```

Triggering an update and sampling every 2s:

```
  t+2s   ready=0
  t+4s   ready=0
  t+6s   ready=0
  t+8s   ready=3
```

**Ready hit zero for ~6 seconds.** That is the whole difference from `RollingUpdate`, which
never drops below `replicas - maxUnavailable`. You choose `Recreate` when two versions must
*not* run at once — an incompatible schema migration, or a single-writer lock on a volume.

### Comparison

| Strategy | Downtime | Extra resources | Rollback | Use when |
|---|---|---|---|---|
| `RollingUpdate` (default) | none | +25% (maxSurge) | scale the old RS back up | most services |
| Blue-green | none | **2×** | flip the selector back | you want an instant, tested cutover |
| Canary | none | +1 pod upward | scale canary to 0 | you want real traffic to validate a release |
| `Recreate` | **yes** | none | redeploy old version | versions cannot coexist |

## What I took away

- **A Deployment never creates pods.** Deployment → ReplicaSet → Pod, verified through
  `ownerReferences`. A rolling update is two replica counters moving in opposite directions.
- **`kubectl set image` on a ReplicaSet rolls nothing.** Running pods keep the old image. That
  single experiment explains why Deployments exist.
- **Rollback is fast because the old ReplicaSet was never deleted** — it is scaled from 0, with
  no image pull.
- **`Running` is not healthy.** A CrashLoopBackOff pod reports phase `Running`. `READY` is what
  routes traffic; alert on that.
- **`CrashLoopBackOff` and `ImagePullBackOff` are not phases**, they are container waiting
  reasons — which is why they never appear in the `PHASE` column.
- **A startup probe is what stops liveness killing a slow-booting app.** 30s startup, zero
  restarts, because liveness stays suspended until startup succeeds.
- **A DaemonSet means "every node it is allowed on."** The control-plane taint silently
  reduced DESIRED from 3 to 2.
- **Canary percentages are pod-count arithmetic**, and the realised split wanders (12% for a
  10% target) because backend selection is random per connection.

## Cleanup

```bash
kubectl delete -f 01-core-objects/ -f 02-pod-lifecycle/ --ignore-not-found
kubectl delete -f 03-deployment-strategies/blue-green/ -f 03-deployment-strategies/canary/ -f 03-deployment-strategies/recreate/ --ignore-not-found
```
