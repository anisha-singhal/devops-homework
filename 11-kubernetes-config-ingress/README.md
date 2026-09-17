# Kubernetes Ingress, ConfigMaps & Secrets

Session 12, on the same 3-node `kind` cluster (Kubernetes **v1.34.0**). All output is real.

The cluster was built with the two things an ingress controller needs on kind — an
`ingress-ready` node label and host port mappings for 80/443:

```yaml
- role: control-plane
  kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          node-labels: "ingress-ready=true"
  extraPortMappings:
    - { containerPort: 80,  hostPort: 80 }
    - { containerPort: 443, hostPort: 443 }
```

## Part 1 — ConfigMap

```bash
$ kubectl apply -f 01-configmap/app-config.yaml
$ kubectl get cm yatri-app-config -o jsonpath='{.data}'
{
    "DEFAULT_CURRENCY": "INR",
    "ENVIRONMENT": "production",
    "LOG_LEVEL": "INFO",
    "MAX_BOOKING_DAYS": "30",
    "PORT": "5000"
}
```

Plain key/value pairs, stored in the API server, readable by anyone with `get configmap`.
The point is separating configuration from the image: the same container image runs in dev and
production, and only the ConfigMap differs. Rebuild nothing to change a log level.

## Part 2 — Secret, and what it does *not* do

```bash
$ kubectl get secret yatri-db-secret -o jsonpath='{.data}'
{
    "POSTGRES_DB": "eWF0cmlfcHJvZHVjdGlvbl9kYg==",
    "POSTGRES_PASSWORD": "c2VjcmV0cGFzc3dvcmQ=",
    "POSTGRES_USER": "eWF0cmlfYWRtaW4="
}
```

That looks protected. It is not:

```bash
$ kubectl get secret yatri-db-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
secretpassword
```

**Base64 is an encoding, not encryption.** A Secret differs from a ConfigMap in that it is not
printed by default in `kubectl describe`, can be RBAC-restricted separately, and is held in
tmpfs rather than on disk when mounted as a volume. It is *not* secret from anyone who can read
it through the API.

Making it actually secret requires something else — encryption at rest
(`EncryptionConfiguration` on etcd), a KMS provider, or an external store like Vault or an
external-secrets operator — plus RBAC that does not grant `get secrets` broadly.

And note this, from inside a running pod:

```bash
$ kubectl exec <backend-pod> -- env | grep POSTGRES
POSTGRES_DB=yatri_production_db
POSTGRES_PASSWORD=secretpassword
POSTGRES_USER=yatri_admin
```

Injected as an environment variable, the password sits in the container's environment in
**plain text** — visible to any process in the container, to `kubectl exec`, and often to crash
dumps and logging agents. Mounting a Secret as a volume is the safer pattern, because a file
can have permissions and is not inherited by every child process.

### The trailing-newline bug, reproduced

The classic way to break a Secret, straight from the course's troubleshooting notes:

```bash
$ echo "secretpassword"    | base64    ->  c2VjcmV0cGFzc3dvcmQK
$ echo -n "secretpassword" | base64    ->  c2VjcmV0cGFzc3dvcmQ=
```

Different strings. Decoding each:

```
  with    -n : 14 bytes
  without -n : 15 bytes
```

```bash
$ echo "c2VjcmV0cGFzc3dvcmQK" | base64 -d | od -c
0000000   s   e   c   r   e   t   p   a   s   s   w   o   r   d  \n
```

A `\n` on the end. The database gets a 15-character password, rejects it, and every layer
reports "authentication failed" while the YAML looks perfectly correct. The `K` versus `=` at
the end of the base64 string is the only visible tell.

**The fix is to not hand-encode at all:**

```bash
$ kubectl create secret generic demo-safe --from-literal=password='secretpassword' \
    --dry-run=client -o jsonpath='{.data.password}'
c2VjcmV0cGFzc3dvcmQ=
```

`kubectl` does the encoding, so the newline never arises. `stringData:` in a manifest does the
same thing — you write the plain value and the API server encodes it.

## Part 3 — Ingress

### Installing the controller

An Ingress resource does nothing on its own; it is a rule that a controller has to implement.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s
```

```
NAME                                        READY   STATUS      AGE
ingress-nginx-admission-create-hkbxr        0/1     Completed   22s
ingress-nginx-admission-patch-s9h2w         0/1     Completed   22s
ingress-nginx-controller-5587cd7cf6-wl5j4   1/1     Running     22s

NAME    CONTROLLER             PARAMETERS   AGE
nginx   k8s.io/ingress-nginx   <none>       22s
```

The `IngressClass` named `nginx` is what `spec.ingressClassName: nginx` in the manifest binds
to. Without a controller providing that class, an Ingress object is applied successfully and
simply never routes anything — the same "looks healthy, does nothing" failure as a
`LoadBalancer` with no cloud provider.

### The routing rule

```yaml
spec:
  ingressClassName: nginx
  rules:
    - host: yatri.local
      http:
        paths:
          - path: /api(/|$)(.*)
            pathType: ImplementationSpecific
            backend: { service: { name: yatri-backend-service,  port: { number: 80 } } }
          - path: /
            pathType: Prefix
            backend: { service: { name: yatri-frontend-service, port: { number: 80 } } }
```

```bash
$ kubectl get ingress yatri-ingress
NAME            CLASS   HOSTS         ADDRESS     PORTS   AGE
yatri-ingress   nginx   yatri.local   localhost   80      34s
```

`ADDRESS` was empty for the first ~20 seconds and then filled in — the controller writes it back
once it has accepted the rule. An `ADDRESS` that stays empty means no controller adopted the
Ingress, usually a wrong or missing `ingressClassName`.

### Routing verified

**`/` → frontend:**

```bash
$ curl -H "Host: yatri.local" http://localhost/
<title>Welcome to nginx!
<h1>Welcome to nginx!
```

**`/api/` → backend:**

```bash
$ curl -H "Host: yatri.local" http://localhost/api/
Yatri Backend API
=================
ENVIRONMENT     : production
LOG_LEVEL       : INFO
DEFAULT_CURRENCY: INR
POSTGRES_USER   : yatri_admin
POSTGRES_DB     : yatri_production_db
```

One host, one port, two completely different applications — chosen by path. And the backend's
response is itself proof of Parts 1 and 2: every value it prints came from the ConfigMap or the
Secret via `envFrom`.

**Host-based routing:**

```
  Host: wrong.local  -> HTTP 404
  Host: yatri.local  -> HTTP 200
```

The rule is keyed on the `Host` header, not the IP. Same address, same port — a different
header gets a 404 from the controller because no rule matches. That is how one Ingress
controller serves many sites.

### The services behind it stay internal

```bash
$ kubectl get svc yatri-frontend-service yatri-backend-service
NAME                     TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
yatri-frontend-service   ClusterIP   10.96.14.227   <none>        80/TCP    43s
yatri-backend-service    ClusterIP   10.96.78.89    <none>        80/TCP    43s
```

**Both are `ClusterIP` with no external IP.** Neither is individually exposed. This is the
argument for Ingress over `type: LoadBalancer` per service: on a cloud provider those two
services would have meant two load balancers and two bills, and ten microservices would mean
ten. Here one controller fronts everything and routes by host and path.

| | LoadBalancer per service | One Ingress |
|---|---|---|
| Cloud load balancers | one per service | one, total |
| Routing | layer 4 (port) | layer 7 (host + path) |
| TLS | per service | terminated centrally |
| Backing services | must be exposed | stay `ClusterIP` |

### Why there is no browser screenshot here

The rule matches on `Host: yatri.local`, which `curl -H` supplies directly. A browser sends the
host it actually navigated to, so a screenshot would need `yatri.local` added to `/etc/hosts` —
a system-wide change to this machine that the exercise does not require. The curl transcripts
above are the complete evidence; the 404-vs-200 comparison proves the host matching is real and
not incidental.

## What I took away

- **Base64 is encoding, not encryption.** A Secret is only as private as the RBAC in front of
  it, and `kubectl get secret -o jsonpath | base64 -d` is one command.
- **`envFrom` puts secrets in the container's environment in plain text**, where every child
  process and `kubectl exec` can read them. Volume mounts are the safer default.
- **Never hand-encode a secret.** `echo` without `-n` appends `\n`, producing a password one
  byte too long and an authentication error that looks like a wrong password. `kubectl create
  secret` or `stringData:` avoids the class of bug entirely.
- **An Ingress without a controller is inert** — it applies cleanly and routes nothing. The
  symptom is an `ADDRESS` that never fills in, and it is the same shape of failure as a
  `LoadBalancer` service stuck on `<pending>`.
- **Ingress is layer 7, Services are layer 4.** Routing on host and path is what lets one entry
  point serve many applications while every backing service stays `ClusterIP`.

## Cleanup

```bash
kubectl delete -f 03-ingress/ingress-routes.yaml -f 04-full-demo/ -f 02-secret/ -f 01-configmap/
kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml
```
