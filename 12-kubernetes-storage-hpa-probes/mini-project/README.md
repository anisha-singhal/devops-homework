# Mini Project — Production-Ready Kubernetes Web App

Name: **Anisha Singhal** · Enrollment: **10020** · Session 13, Task 3

Persistent storage, autoscaling and the full probe triage, deployed together on the 3-node kind
cluster. Every block below is real output, including three results that did not match what the
brief predicted.

## What is deployed

```
                       [ Service: web-service ]  ClusterIP 10.96.15.77
                                   │ :80
            ┌──────────────────────┼──────────────────────┐
            ▼                      ▼                      ▼
     [ web-app pod ]        [ web-app pod ]        [ web-app pod ]
      startup probe          startup probe          startup probe
      readiness probe        readiness probe        readiness probe
      liveness probe         liveness probe         liveness probe
      cpu req 100m           cpu req 100m           cpu req 100m
            └──────────────────────┼──────────────────────┘
                                   │ all mount /data
                                   ▼
                    [ PVC: web-data, 500Mi, RWO ]
                                   │
                    [ StorageClass: standard → rancher.io/local-path ]
                                   │
                    [ PV: pvc-961b…, nodeAffinity → devops-lab-worker2 ]

                    [ HPA: 2–5 replicas, target 50% CPU ] ← metrics-server
```

| File | Object |
|---|---|
| [`namespace.yaml`](namespace.yaml) | namespace `production-webapp` |
| [`pvc.yaml`](pvc.yaml) | 500Mi RWO claim |
| [`deployment.yaml`](deployment.yaml) | 2 replicas, three probes, resource requests/limits |
| [`service.yaml`](service.yaml) | ClusterIP on port 80 |
| [`hpa.yaml`](hpa.yaml) | autoscaler, min 2 / max 5 / 50% CPU |

The cluster needed metrics-server, which kind does not ship:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

`--kubelet-insecure-tls` is needed because kind's kubelet serving certificates are self-signed.
Without it metrics-server runs but never scrapes, and the HPA sits at `<unknown>` forever —
which looks exactly like a broken HPA.

## Deploy

```
$ kubectl apply -f namespace.yaml -f pvc.yaml
namespace/production-webapp created
persistentvolumeclaim/web-data created

$ kubectl get pvc -n production-webapp
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
web-data   Pending                                      standard       0s
```

**`Pending` is correct here, not a failure.** The default StorageClass is
`WaitForFirstConsumer`, so no volume is created until a pod needs one — it is waiting for a
scheduling decision, not failing to find storage.

```
$ kubectl apply -f deployment.yaml -f service.yaml -f hpa.yaml
deployment.apps/web-app created
service/web-service created
horizontalpodautoscaler.autoscaling/web-app-hpa created

$ kubectl get pvc -n production-webapp
NAME       STATUS   VOLUME                                     CAPACITY   STORAGECLASS
web-data   Bound    pvc-961b3869-51e0-4cc9-9d3e-71b438c27639   500Mi      standard
```

Bound as soon as a pod was scheduled. The PV that appeared:

```
$ kubectl get pv
NAME                                       CAPACITY   RECLAIM   STATUS   CLAIM      NODE
pvc-961b3869-51e0-4cc9-9d3e-71b438c27639   500Mi      Delete    Bound    web-data   devops-lab-worker2
```

The **NODE** column is `nodeAffinity` on the PV, and it decides everything that follows.

## Task 1 — storage persistence

```
$ POD=$(kubectl get pods -n production-webapp -l app=web-app -o jsonpath='{.items[0].metadata.name}')
$ kubectl exec -n production-webapp $POD -- sh -c 'echo "Student: Anisha Singhal (10020)" > /data/student.txt; date >> /data/student.txt'
$ kubectl exec -n production-webapp $POD -- cat /data/student.txt
Student: Anisha Singhal (10020)
Wed Oct  7 18:30:48 UTC 2026
```

Delete that pod outright:

```
$ kubectl delete pod -n production-webapp web-app-5b6bd49dd5-p5mzh
pod "web-app-5b6bd49dd5-p5mzh" deleted
```

The replacement has a different name — it is a different pod, not a restart:

```
$ kubectl get pods -n production-webapp
NAME                       READY   STATUS    RESTARTS   AGE
web-app-5b6bd49dd5-g9rht   1/1     Running   0          27s   ← new
web-app-5b6bd49dd5-pn8hf   1/1     Running   0          69s

$ kubectl exec -n production-webapp web-app-5b6bd49dd5-g9rht -- cat /data/student.txt
Student: Anisha Singhal (10020)
Wed Oct  7 18:30:48 UTC 2026
```

**The data survived.** With `emptyDir` it would not have — compare
[01-volumes](../01-volumes/README.md#emptydir).

### Unexpected result 1 — RWO is per node, not per pod

The brief implies one pod uses the volume. Both do:

```
$ kubectl exec -n production-webapp web-app-5b6bd49dd5-pn8hf -- cat /data/student.txt
Student: Anisha Singhal (10020)
Wed Oct  7 18:30:48 UTC 2026
```

A second, entirely separate pod reads the file the first one wrote. `ReadWriteOnce` restricts a
volume to **one node**; any number of pods on that node may mount it simultaneously.
`ReadWriteOncePod` is the mode that means one pod.

This is a real-world hazard: two replicas of a database writing the same files would corrupt
them, and the access mode does not prevent it.

## Task 2 — Service verification

```
$ kubectl get svc,endpointslice -n production-webapp
service/web-service   ClusterIP   10.96.15.77   80/TCP

NAME                                      ADDRESSTYPE   PORTS   ENDPOINTS
endpointslice.../web-service-6gflg        IPv4          80      10.244.1.4,10.244.1.6
```

```
$ kubectl run curl-probe -n production-webapp --image=curlimages/curl --rm -i --restart=Never -- \
    curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://web-service
HTTP 200
```

The endpoint list holds exactly the pods whose **readiness** probe is passing — the Service
tracks readiness, not existence.

## Task 3 — HPA scaling

Baseline, once metrics-server had data:

```
$ kubectl get hpa -n production-webapp
NAME          REFERENCE            TARGETS       MINPODS   MAXPODS   REPLICAS
web-app-hpa   Deployment/web-app   cpu: 1%/50%   2         5         2

$ kubectl top pods -n production-webapp
web-app-5b6bd49dd5-g9rht   1m    11Mi
web-app-5b6bd49dd5-pn8hf   1m    11Mi
```

Four load generators (one was not enough to push nginx past 50% of a 100m request):

```bash
for i in 1 2 3 4; do
  kubectl run load-generator-$i -n production-webapp --image=busybox:1.36 --restart=Never -- \
    /bin/sh -c "while true; do wget -q -O- http://web-service > /dev/null; done"
done
```

### Scale out

```
TIME      HPA TARGETS   REPLICAS
00:02:00  1%/50%        2
00:02:20  35%/50%       2
00:02:40  172%/50%      4      ← first scale-up
00:03:00  130%/50%      5      ← hit max
00:03:21  53%/50%       5
00:04:21  46%/50%       5
```

Two to five in **about 40 seconds**. The HPA's own account:

```
$ kubectl describe hpa web-app-hpa -n production-webapp
Conditions:
  AbleToScale     True    ReadyForNewScale  recommended size matches current size
  ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count
  ScalingLimited  True    TooManyReplicas   the desired replica count is more than the maximum

Events:
  Warning  FailedGetResourceMetric   7m35s (x2)  no metrics returned from resource metrics API
  Warning  FailedGetResourceMetric   7m20s       did not receive metrics for targeted pods (pods might be unready)
  Normal   SuccessfulRescale         5m50s       New size: 4; reason: cpu resource utilization above target
  Normal   SuccessfulRescale         5m35s       New size: 5; reason: cpu resource utilization above target
```

Three things worth reading there:

- `ScalingLimited: TooManyReplicas` — utilisation stayed near 60% because the HPA **wanted more
  than 5** and was capped. A persistently-above-target HPA is not broken, it is maxed out.
- The early `FailedGetResourceMetric` warnings are the `<unknown>` phase before metrics-server
  had a scrape. They are warnings, not errors, and they resolve themselves.
- The jump went 2 → 4 → 5, not 2 → 3 → 4 → 5. The HPA computes
  `ceil(current × currentMetric / targetMetric)` and moves in one step: at 172% of a 50% target
  it asked for `ceil(2 × 172/50)` = 7, clamped to 5.

### Unexpected result 2 — the HPA cannot spread across nodes

```
$ kubectl get pods -n production-webapp -l app=web-app -o wide
web-app-5b6bd49dd5-c284p   devops-lab-worker2
web-app-5b6bd49dd5-g9rht   devops-lab-worker2
web-app-5b6bd49dd5-gf8rk   devops-lab-worker2
web-app-5b6bd49dd5-pn8hf   devops-lab-worker2
web-app-5b6bd49dd5-rb7kv   devops-lab-worker2
```

**All five on one node**, on a 3-node cluster with two idle workers. The PV's `nodeAffinity`
pins every pod that mounts it to `devops-lab-worker2`.

This is a genuine design conflict, not a kind quirk: a Deployment with an RWO volume and an HPA
can only scale as far as **one node's** spare capacity, and loses every replica if that node
fails. The combination looks correct in YAML and is wrong in architecture. Real answers are
networked RWX storage, or a StatefulSet giving each replica its own volume, or keeping the web
tier stateless and pushing state to a database.

### Scale down

```
$ kubectl delete pod -n production-webapp load-generator-{1,2,3,4}

TIME      HPA TARGETS   REPLICAS
00:08:58  67%/50%       5
00:09:28  28%/50%       5
00:09:58  1%/50%        5   ← load is already gone
00:10:58  1%/50%        5
00:11:58  1%/50%        5
00:12:58  1%/50%        5
00:13:58  1%/50%        5
00:14:29  1%/50%        3   ← ~4.5 minutes later
00:14:59  1%/50%        2
```

### Unexpected result 3 — scale-down took 4.5 minutes at 1% CPU

CPU hit 1% at 00:09:58 and nothing happened until 00:14:29. That is the
`--horizontal-pod-autoscaler-downscale-stabilization` window, **5 minutes by default**: the HPA
takes the *highest* recommendation from the last 5 minutes, so it cannot scale down until the
busy readings age out.

Scaling up is immediate; scaling down is deliberately slow, because flapping costs more than a
few idle pods. Watching for 2 minutes and concluding "the HPA is broken" is the wrong call, and
is the behaviour the asymmetry is designed to produce.

## Probes

All three are configured on the container, and they answer different questions:

| Probe | Question | On failure |
|---|---|---|
| `startupProbe` | has it finished starting? | restart the container; **suspends the other two** until it passes |
| `readinessProbe` | can it take traffic? | remove the pod IP from the Service endpoints — **no restart** |
| `livenessProbe` | is it still working? | restart the container |

`failureThreshold: 30, periodSeconds: 2` on the startup probe gives a slow starter 60 seconds
without the liveness probe killing it mid-boot. That is the whole reason startup probes exist —
before them, a generous `initialDelaySeconds` on liveness was the only option, and it delayed
detection of real failures for the entire life of the pod.

The readiness/liveness distinction matters under load: a pod that is briefly overwhelmed should
be **removed from the endpoint list and left alone**, not restarted. Pointing a liveness probe
at an endpoint that gets slow under load turns a traffic spike into a restart storm.

## Troubleshooting notes from this run

| Symptom | Cause | Fix |
|---|---|---|
| HPA `TARGETS: <unknown>/50%` | metrics-server absent, or no `resources.requests.cpu` | install it; the HPA computes a **percentage of the request**, so with no request there is nothing to be a percentage of |
| metrics-server pod runs but never scrapes | kind's self-signed kubelet certs | `--kubelet-insecure-tls` |
| PVC `Pending` | `WaitForFirstConsumer` waiting for a pod — or genuinely no default StorageClass | `kubectl describe pvc`; the events distinguish them |
| All pods on one node | PV `nodeAffinity` from a node-local volume | expected; rethink storage if spreading matters |
| HPA stuck above target | `ScalingLimited: TooManyReplicas` | raise `maxReplicas` |

## Cleanup

```bash
kubectl delete namespace production-webapp
```

Deleting the namespace deletes the PVC, and the StorageClass's `reclaimPolicy: Delete` then
destroys the PV **and the data**. `Retain` is what you want for anything real.

## What I took away

- **`ReadWriteOnce` means one node.** Two pods shared the volume and the API never objected.
- **An RWO volume plus an HPA is an architectural contradiction** that YAML validation cannot
  catch — all five replicas on one node of three.
- **Scale up is fast, scale down takes 5 minutes**, by design.
- **`ScalingLimited: TooManyReplicas` is the condition to read** before assuming an HPA is
  misbehaving.
- **An HPA target is a percentage of the CPU *request***, which is why omitting requests makes
  autoscaling impossible rather than merely imprecise.
