# Kubernetes Troubleshooting

Session 14. Five deliberately broken workloads, diagnosed from scratch on a 3-node `kind`
cluster (Kubernetes **v1.34.0**), then fixed. All output is real.

## The triage command

One command sorts five unrelated failures, provided you ask for the right columns:

```bash
kubectl get pods -l tier=triage-gauntlet -o 'custom-columns=\
NAME:.metadata.name,\
PHASE:.status.phase,\
READY:.status.containerStatuses[*].ready,\
RESTARTS:.status.containerStatuses[*].restartCount,\
WAITING:.status.containerStatuses[*].state.waiting.reason,\
TERMINATED:.status.containerStatuses[*].lastState.terminated.reason'
```

```
NAME                     PHASE     READY    RESTARTS   WAITING            TERMINATED
fail-1-crashloop-pod     Running   false    3          CrashLoopBackOff   Error
fail-2-imagepull-pod     Pending   false    0          ImagePullBackOff   <none>
fail-3-pending-pod       Pending   <none>   <none>     <none>             <none>
fail-4-dns-failure-pod   Running   true     0          <none>             <none>
fail-5-oomkilled-pod     Running   false    3          CrashLoopBackOff   OOMKilled
```

Two things in that table are the whole lesson:

- **Rows 1 and 5 have the identical `WAITING` reason** — `CrashLoopBackOff` — and completely
  different causes. The `TERMINATED` column (`Error` vs `OOMKilled`) is what separates them.
  Default `kubectl get pods` shows neither column.
- **Row 4 looks perfectly healthy.** `Running`, `1/1`, 0 restarts — and it is broken.

## Scenario 1 — CrashLoopBackOff from a missing env var

```bash
$ kubectl logs fail-1-crashloop-pod
[FATAL ERROR]: DATABASE_URL environment variable is MISSING!

$ kubectl get pod fail-1-crashloop-pod -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
  reason=Error  exitCode=1
```

The application said exactly what was wrong. **Logs first for any `CrashLoopBackOff`** — a
container that starts and exits has usually printed its reason.

`exitCode=1` means the process chose to exit. Compare with scenario 5.

A caveat worth recording: `kubectl logs --previous` returned
`unable to retrieve container logs for containerd://...` — once the backoff has cycled far
enough, the previous container's logs are gone. During an active crash loop you have a short
window to catch them; after that, the current attempt's logs are all you get.

## Scenario 2 — ImagePullBackOff

```bash
$ kubectl describe pod fail-2-imagepull-pod
Warning  Failed   (x4 over 111s)  kubelet  Error: ErrImagePull
Normal   BackOff  (x6 over 110s)  kubelet  Back-off pulling image "yatri-api-service:v999-invalid-tag-does-not-exist"
Warning  Failed   (x6 over 110s)  kubelet  Error: ImagePullBackOff
```

`ErrImagePull` first (a real attempt failed), then `ImagePullBackOff` (now waiting between
retries). **Logs are useless here** — no container ever started, so there is nothing to log.
`describe` is the tool.

The three causes, in order of likelihood: the tag does not exist (this case), the registry
needs credentials (`imagePullSecrets`), or the image name is misspelled. The event text names
the exact image string, which usually settles it.

Note the phase is `Pending`, not `Running` — a pod whose container never started has not
reached `Running`.

## Scenario 3 — Pending, unschedulable

```bash
$ kubectl describe pod fail-3-pending-pod
Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
  1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: },
  2 Insufficient cpu, 2 Insufficient memory.
```

```
  requests:         cpu=500    memory=1000Gi
  node allocatable: cpu=15     memory=8125988Ki  (~7.75Gi)
```

500 CPUs and 1000Gi against a node with 15 CPUs and 7.75Gi. The scheduler reports **per-node**
reasons: one node excluded by taint, two by resources. Nothing is failing or restarting — an
unschedulable pod waits indefinitely, by design.

`kubectl describe` on a `Pending` pod almost always contains the complete answer.

## Scenario 4 — the dangerous one: broken but healthy-looking

```bash
$ kubectl get pod fail-4-dns-failure-pod
fail-4-dns-failure-pod   1/1   Running   0   114s
```

Every signal `kubectl get` offers says this pod is fine. The logs say otherwise:

```bash
$ kubectl logs fail-4-dns-failure-pod
Attempting connection to internal database...
Process sleeping...
```

The connection attempt produced no success message. Checking the name directly:

```bash
$ kubectl exec fail-4-dns-failure-pod -- nslookup postgres-db-wrong-name.production.svc.cluster.local
** server can't find postgres-db-wrong-name.production.svc.cluster.local: NXDOMAIN

$ kubectl get ns production
Error from server (NotFound): namespaces "production" not found

$ kubectl get svc -A | grep -i postgres
  (no postgres service in any namespace)
```

Three separate problems, any one of which would break it: the service name is wrong, the
namespace does not exist, and no such service exists anywhere.

**Why the pod still reports healthy** is in the manifest:

```yaml
curl -s --connect-timeout 3 http://postgres-db-wrong-name...:5432 || true
```

`|| true` swallows curl's non-zero exit, so the script continued into `sleep 3600` and the
container exited 0 — well, never exited at all. The container is "up". There is no readiness
probe to contradict it.

This is the failure mode that reaches production. The others announce themselves in
`kubectl get`; this one requires someone to read the logs or notice the application
misbehaving. A readiness probe that actually checked the database connection would have turned
this into a visible `0/1`.

**`|| true` in a container entrypoint converts a hard failure into a silent one.**

## Scenario 5 — OOMKilled, masquerading as a crash loop

Identical symptom to scenario 1 in the default view:

```bash
$ kubectl get pod fail-5-oomkilled-pod -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
  reason=OOMKilled  exitCode=137

$ kubectl get pod fail-5-oomkilled-pod -o jsonpath='{.spec.containers[0].resources.limits.memory}'
  20Mi
```

```bash
$ kubectl logs fail-5-oomkilled-pod
  (empty)
```

**Empty logs, because the kernel killed the process mid-execution** — it never got to print
anything. In scenario 1 the app explained itself; here there is nothing to read, and the
absence is itself the clue.

The exit codes are the fastest discriminator:

| Exit code | Meaning |
|---|---|
| `0` | clean exit |
| `1`–`128` | the application exited with that status — read the logs |
| `137` | `128 + 9` → SIGKILL. With `reason=OOMKilled`, the memory limit |
| `143` | `128 + 15` → SIGTERM, usually a normal shutdown or a liveness kill |

The container tried to allocate 100 × 10 MiB against a 20Mi limit. The fix is either a larger
limit or an application that uses less — and deciding which requires knowing whether 20Mi was
a considered number or a copy-paste default.

## The fixes

```bash
$ diff 06-crashloopbackoff/broken-pod.yaml 06-crashloopbackoff/fixed-pod.yaml
<           echo "Something went wrong!"
<           exit 1
>           echo "Application is healthy"
>           sleep 3600

$ diff 07-imagepullbackoff/broken-pod.yaml 07-imagepullbackoff/fixed-pod.yaml
<       image: nginx:this-image-does-not-exist
>       image: nginx:1.27

$ diff 08-pending-pods/broken-pod.yaml 08-pending-pods/fixed-pod.yaml
<   nodeSelector:
<     kubernetes.io/hostname: node-that-does-not-exist
```

```
crash-demo     1/1   Running   0   48s
image-demo     1/1   Running   0   48s
pending-demo   1/1   Running   0   48s
```

The third is worth noting: a `nodeSelector` naming a node that does not exist produces exactly
the same `Pending` as asking for too many resources. Both are "no node satisfies this";
`describe` distinguishes them by saying `didn't match Pod's node affinity/selector` rather than
`Insufficient cpu`.

## A triage order that works

1. **`kubectl get pods`** with the `WAITING` and `TERMINATED` columns — the default output
   hides the field that separates `Error` from `OOMKilled`.
2. **`Pending`? → `kubectl describe`.** The scheduler writes the reason, per node.
3. **`ImagePullBackOff`? → `kubectl describe`.** No container started, so no logs exist.
4. **`CrashLoopBackOff`? → `kubectl logs`**, then the exit code. `137` means stop reading logs
   and look at memory limits.
5. **Looks healthy but is not? → `kubectl logs`, then `kubectl exec`** and test the dependency
   by hand — DNS, then TCP, then the application protocol.
6. **`kubectl get events --sort-by=.lastTimestamp`** when the order of events matters.

## What I took away

- **`CrashLoopBackOff` is a symptom, not a diagnosis.** Two of five scenarios showed it with
  unrelated causes, distinguished only by `lastState.terminated.reason`.
- **Exit 137 means the kernel killed it**, and empty logs are the tell — the process never got
  to explain itself. Exit 1 means the app chose to die and almost certainly said why.
- **`kubectl logs` is useless for `ImagePullBackOff`** and essential for `CrashLoopBackOff`.
  Knowing which tool answers which question is most of the speed.
- **`--previous` logs expire.** During an active crash loop you have a short window.
- **The healthiest-looking pod was the broken one.** `|| true` in an entrypoint turns a failed
  dependency into a container that reports `1/1 Running` forever. Without a readiness probe
  that tests the real dependency, Kubernetes has no way to know.
- **`Pending` is never urgent-looking and always total.** Nothing restarts, nothing errors; the
  pod simply never runs.

## Cleanup

```bash
kubectl delete -f scenarios/scenario-1-crashloop/broken.yaml --ignore-not-found
kubectl delete pods -l tier=triage-gauntlet --ignore-not-found
kubectl delete pod crash-demo image-demo pending-demo --ignore-not-found
```
