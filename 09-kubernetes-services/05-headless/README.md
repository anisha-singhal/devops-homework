# Headless Service — DNS Without a Virtual IP

Exercise `05-headless`. Setting one field, `clusterIP: None`, changes what DNS returns and
therefore who decides which pod gets the traffic.

## What makes it headless

```bash
kubectl apply -f service.yaml -f app-statefulset.yaml -f client-pod.yaml
kubectl get svc web-service-headless
```

```
NAME                   TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
web-service-headless   ClusterIP   None         <none>        80/TCP    6s
```

`CLUSTER-IP: None`. The type still says `ClusterIP`, but no virtual IP is allocated, so
kube-proxy writes **no iptables rules** — there is no VIP to DNAT. The Service becomes a pure
DNS construct.

Applying it also prints:

```
Warning: spec.SessionAffinity is ignored for headless services
```

Consistent with the above: session affinity is a kube-proxy feature, and kube-proxy is not
involved.

## The difference, in one comparison

**Headless** — DNS returns every pod IP:

```bash
$ kubectl exec headless-dns-client -- nslookup web-service-headless
Name:	web-service-headless.default.svc.cluster.local
Address: 10.244.1.6
Name:	web-service-headless.default.svc.cluster.local
Address: 10.244.1.7
Name:	web-service-headless.default.svc.cluster.local
Address: 10.244.2.6
```

**Normal ClusterIP** — DNS returns one virtual IP:

```bash
$ kubectl exec headless-dns-client -- nslookup web-service-nodeport
Name:	web-service-nodeport.default.svc.cluster.local
Address: 10.96.119.168
```

That is the entire distinction, and it relocates the load-balancing decision. With a ClusterIP,
the client gets one address and the kernel picks a backend. With a headless service, the
**client** gets the full list and chooses — which is what database drivers, gRPC clients and
cluster-aware applications want, because they maintain their own connection pools, do their own
health tracking, and need to address specific members.

## StatefulSet: stable names, not random hashes

```bash
$ kubectl rollout status statefulset/web-stateful
Waiting for 3 pods to be ready...
Waiting for 2 pods to be ready...
Waiting for 1 pods to be ready...
partitioned roll out complete: 3 new pods have been updated...
```

The countdown is itself a feature — a StatefulSet creates pods **one at a time, in order**,
waiting for each to be Ready. A Deployment starts all replicas at once.

```
NAME             IP           NODE
web-stateful-0   10.244.1.6   devops-lab-worker2
web-stateful-1   10.244.2.6   devops-lab-worker
web-stateful-2   10.244.1.7   devops-lab-worker2
```

Ordinal names `-0`, `-1`, `-2`. Compare with a Deployment's pods from the LoadBalancer
exercise:

```
web-app-loadbalancer-7f4b888fc7-8pggs
web-app-loadbalancer-7f4b888fc7-k6dhn
web-app-loadbalancer-7f4b888fc7-t9w6r
```

## Per-pod DNS

The headless service gives every pod its own resolvable name,
`<pod>.<service>.<namespace>.svc.cluster.local`:

```
  web-stateful-0 -> Address: 10.244.1.6
  web-stateful-1 -> Address: 10.244.2.6
  web-stateful-2 -> Address: 10.244.1.7
```

This only works because the EndpointSlice carries a `hostname` for each endpoint — a field
populated for StatefulSet pods behind a headless service, and absent otherwise:

```
  10.244.1.6  hostname=web-stateful-0
  10.244.2.6  hostname=web-stateful-1
  10.244.1.7  hostname=web-stateful-2
```

Note that endpoints **do** exist here, unlike ExternalName. The service tracks pods normally;
it just publishes them as DNS records instead of proxying to them.

## Stable identity across a restart

```bash
# BEFORE
web-stateful-0   10.244.1.6
web-stateful-1   10.244.2.6
web-stateful-2   10.244.1.7

$ kubectl delete pod web-stateful-1

# AFTER
web-stateful-0   10.244.1.6
web-stateful-1   10.244.2.7     <- same NAME, new IP
web-stateful-2   10.244.1.7
```

```bash
$ kubectl exec headless-dns-client -- nslookup web-stateful-1.web-service-headless.default.svc.cluster.local
Address: 10.244.2.7
```

**The name came back identical and the DNS record followed it to the new IP.** In the
ClusterIP exercise, deleting a Deployment pod produced `...-28lt8` → `...-7m75t`, a completely
new identity. Here the identity is the point: `web-stateful-1` is a durable address for "the
second member of this cluster", and it survives the pod that was implementing it.

That is what makes the pairing work for stateful systems. A Kafka broker, a MySQL replica or a
MongoDB member needs to say "replicate from `db-0`" and have that mean something next week.
Combined with per-pod PersistentVolumeClaims, a replacement pod gets the same name, the same
DNS record and the same disk.

## The five service types, side by side

| Type | ClusterIP | Selector | Endpoints | DNS returns | Reachable from |
|---|---|---|---|---|---|
| `ClusterIP` | allocated | yes | pod IPs | one VIP | inside cluster |
| `NodePort` | allocated | yes | pod IPs | one VIP | any node's IP:30000-32767 |
| `LoadBalancer` | allocated | yes | pod IPs | one VIP | an external IP |
| `ExternalName` | none | no | **none** | a CNAME | wherever the target is |
| **Headless** | **None** | yes | pod IPs | **every pod IP** | inside cluster, per pod |

## Cleanup

```bash
kubectl delete -f client-pod.yaml -f app-statefulset.yaml -f service.yaml
```
