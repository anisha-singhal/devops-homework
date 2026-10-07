# Helm

Session 15, on a 3-node `kind` cluster (Kubernetes **v1.34.0**), Helm **v3.16.3**.

## What Helm is for

The Kubernetes sections before this one applied raw YAML. That works until you need the same
application in dev, staging and production with different replica counts, images, service types
and resource limits — at which point you are maintaining four near-identical copies of the same
manifests and diffing them by eye.

Helm makes the manifests **templates** and the differences **values**. One chart, many
deployments, plus versioned releases you can roll back.

## Chart structure

```
myapp/
  Chart.yaml                      metadata: name, version, appVersion
  values.yaml                     the default values
  .helmignore
  templates/
    deployment.yaml               templated manifests
    service.yaml
    serviceaccount.yaml
    ingress.yaml
    hpa.yaml
    httproute.yaml
    NOTES.txt                     printed after install
    _helpers.tpl                  reusable template snippets (leading _ = not a manifest)
    tests/test-connection.yaml    run by `helm test`
```

Two version fields in `Chart.yaml` that are easy to conflate:

```yaml
version: 0.1.0        # the CHART's version - bump when templates change
appVersion: "1.16.0"  # the APPLICATION's version - the image tag, usually
```

## Lint and render before installing

```bash
$ helm lint ./myapp
==> Linting ./myapp
[INFO] Chart.yaml: icon is recommended
1 chart(s) linted, 0 chart(s) failed
```

```bash
$ helm template demo ./myapp
kind: ServiceAccount
  name: demo-myapp
kind: Service
  name: demo-myapp
  type: ClusterIP
kind: Deployment
  name: demo-myapp
  replicas: 1
          image: "nginx:1.16.0"
```

`helm template` renders locally and talks to no cluster — it is how you see what *would* be
applied. The names are all `demo-myapp`: the release name is prefixed, which is what lets the
same chart be installed several times in one namespace.

## Templating is the point

Same chart, three sets of values:

```bash
$ helm template r ./myapp
  replicas: 1
  image: "nginx:1.16.0"

$ helm template r ./myapp --set replicaCount=5
  replicas: 5
  image: "nginx:1.16.0"

$ helm template r ./myapp -f values-prod.yaml
  type: NodePort
  replicas: 4
  image: "nginx:1.27"
```

Values can also switch whole objects on and off:

```bash
$ helm template r ./myapp | grep -c 'kind: Ingress'
0
$ helm template r ./myapp --set ingress.enabled=true | grep -c 'kind: Ingress'
1
```

`{{- if .Values.ingress.enabled }}` wrapping the file means the Ingress either exists or does
not. With raw YAML, the equivalent is keeping separate directories per environment.

## Install, upgrade, rollback

### Install — revision 1

```bash
$ helm install myapp ./myapp --wait
NAME: myapp
STATUS: deployed
REVISION: 1
```

```
deployment.apps/myapp   1/1
service/myapp           ClusterIP   10.96.225.140   80/TCP
serviceaccount/myapp
```

One command created three objects. `--wait` blocks until they are ready, which is what makes
Helm usable in a pipeline.

### Upgrade — revision 2, via `--set`

```bash
$ helm upgrade myapp ./myapp --set replicaCount=3 --set image.tag=1.27-alpine --wait
REVISION: 2

after: replicas=3 image=nginx:1.27-alpine
```

### Upgrade — revision 3, via a values file

```yaml
# values-prod.yaml
replicaCount: 4
image: { repository: nginx, tag: "1.27" }
service: { type: NodePort }
resources:
  requests: { cpu: 50m, memory: 64Mi }
  limits:   { cpu: 100m, memory: 128Mi }
```

```bash
$ helm upgrade myapp ./myapp -f values-prod.yaml --wait

after: replicas=4 image=nginx:1.27 svc=NodePort
```

A values file is the reviewable form — it lives in git and shows up in a pull request, where a
pile of `--set` flags in someone's shell history does not.

### History

```bash
$ helm history myapp
REVISION  UPDATED                   STATUS      CHART        DESCRIPTION
1         Wed Oct  7 16:36:45 2026  superseded  myapp-0.1.0  Install complete
2         Wed Oct  7 16:37:03 2026  superseded  myapp-0.1.0  Upgrade complete
3         Wed Oct  7 16:37:27 2026  deployed    myapp-0.1.0  Upgrade complete
```

### Rollback

```bash
$ helm rollback myapp 1 --wait
Rollback was a success! Happy Helming!

after rollback: replicas=1 image=nginx:1.16.0 svc=ClusterIP
```

All three values reverted together — replicas, image **and** service type. That is the
difference from `kubectl rollout undo`, which only reverts a Deployment's pod template. Helm
rolls back the whole release: every object the chart manages, in one operation.

```
4  Wed Oct  7 16:37:40 2026  deployed  myapp-0.1.0  Rollback to 1
```

The rollback is **revision 4**, not a return to revision 1. History only moves forward — the
same pattern as `kubectl rollout undo`.

## What a failed upgrade leaves behind

```bash
$ helm upgrade myapp ./myapp --set image.tag=this-tag-does-not-exist --timeout 60s --wait
Error: UPGRADE FAILED: context deadline exceeded
```

```
release status:        failed
deployment image now:  nginx:this-tag-does-not-exist

myapp-64d9855bfb-scx7f   0/1   ErrImagePull   60s
myapp-7f9cfbb987-27p78   1/1   Running        62s
```

Worth reading carefully. The upgrade failed, and:

- The release is left in status **`failed`**.
- **The broken image is still applied** to the Deployment.
- The old pod is **still running**, because the Deployment's rolling update would not kill a
  healthy pod for one that never became ready.

So the application is still serving, but the release is in a broken state and the next
`helm upgrade` starts from there. Someone has to notice and roll back by hand.

### `--atomic` fixes that

```bash
$ helm upgrade myapp ./myapp --set image.tag=this-tag-does-not-exist --atomic --timeout 60s
Error: UPGRADE FAILED: release myapp failed, and has been rolled back due to atomic being set: context deadline exceeded
```

```
NAME    REVISION   STATUS     CHART
myapp   8          deployed   myapp-0.1.0

deployment image: nginx:1.16.0
```

Same failure, same error — but the release is **`deployed`**, not `failed`, and the image is
back to the working one. `--atomic` makes an upgrade all-or-nothing.

```
7  failed      Upgrade "myapp" failed: context deadline exceeded
8  deployed    Rollback to 6
```

The failed attempt is still recorded as revision 7, with the automatic rollback as 8. Nothing
is hidden — it just does not leave the release broken.

**`--atomic --timeout` belongs in every CI deployment step.** Without it, a failed deploy needs
a human; with it, the cluster puts itself back.

## Where Helm 3 keeps its state

```bash
$ kubectl get secrets -l owner=helm
sh.helm.release.v1.myapp.v1   helm.sh/release.v1
sh.helm.release.v1.myapp.v2   helm.sh/release.v1
sh.helm.release.v1.myapp.v3   helm.sh/release.v1
sh.helm.release.v1.myapp.v4   helm.sh/release.v1
sh.helm.release.v1.myapp.v5   helm.sh/release.v1
```

One Secret per revision, in the release's own namespace. There is **no server-side component**
— Helm 2's Tiller is gone, and with it the cluster-admin-by-default security problem. `helm`
is a client that reads and writes ordinary Kubernetes objects, so your RBAC applies to it
unchanged.

It also means release history is per-namespace, and deleting the namespace deletes the history.

## Commands used

| Command | Purpose |
|---|---|
| `helm lint ./chart` | validate chart structure |
| `helm template NAME ./chart` | render locally, no cluster |
| `helm install NAME ./chart --wait` | create a release |
| `helm upgrade NAME ./chart --set k=v` | change values |
| `helm upgrade NAME ./chart -f values.yaml` | change values from a file |
| `helm upgrade ... --atomic --timeout 5m` | roll back automatically on failure |
| `helm list` / `helm list -a` | releases (`-a` includes failed) |
| `helm history NAME` | every revision |
| `helm rollback NAME N` | revert to revision N |
| `helm get values NAME` | the overrides currently in effect |
| `helm get manifest NAME` | the YAML actually applied |
| `helm uninstall NAME` | remove the release |

## What I took away

- **`helm rollback` reverts the whole release**, not just a pod template. One command took
  replicas, image and service type back together — `kubectl rollout undo` cannot do that.
- **A failed upgrade without `--atomic` leaves the release broken and the bad image applied.**
  The app kept serving only because the rolling update refused to kill a healthy pod. `--atomic`
  is the difference between a deploy that fails safe and one that needs a human.
- **Rollbacks move history forward.** "Rollback to 1" became revision 4, and the failed attempt
  stayed in the log as revision 7. Nothing is rewritten.
- **`helm template` is the review tool.** Rendering locally before applying is the Helm
  equivalent of `terraform plan`, and it needs no cluster at all.
- **Helm 3 is just a client.** State lives in one Secret per revision in the namespace, so
  normal RBAC governs it and there is no privileged component to secure.

## Cleanup

```bash
helm uninstall myapp
```
