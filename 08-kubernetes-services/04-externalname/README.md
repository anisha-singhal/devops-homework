# ExternalName — A Service That Is Only a DNS Alias

Exercise `04-externalname`. This service type is unlike the other four: it creates **no proxy,
no virtual IP, and no endpoints**. It is a CNAME record and nothing else.

## What gets created

```bash
kubectl apply -f service.yaml -f client-pod.yaml
kubectl get svc external-database-service
```

```
NAME                        TYPE           CLUSTER-IP   EXTERNAL-IP        PORT(S)   AGE
external-database-service   ExternalName   <none>       nencyravaliya.me   <none>    7s
```

Every column that matters for the other types is empty:

```
  type        : ExternalName
  externalName: nencyravaliya.me
  clusterIP   : ""          <- no virtual IP
  selector    : ""          <- matches no pods
```

```bash
$ kubectl get endpointslices -l kubernetes.io/service-name=external-database-service
No resources found in default namespace.
```

**Not an empty endpoint list — no EndpointSlice object at all.** For the other service types,
empty endpoints is a bug (see the ClusterIP troubleshooting section). Here it is correct:
there is nothing to route to, because ExternalName never routes anything. kube-proxy writes no
iptables rules for it.

## What it actually does

```bash
$ kubectl exec dns-test-client -- nslookup external-database-service
external-database-service.default.svc.cluster.local	canonical name = nencyravaliya.me
```

CoreDNS answers with a **CNAME**. The client then resolves that name itself and connects
directly to the external host. Traffic never passes through the cluster network — which is
also why an ExternalName service cannot do TLS termination, health checking, or load
balancing. It is an alias.

## The course's target domain is dead

Following the exercise as written, the request fails:

```bash
$ kubectl exec dns-test-client -- curl --max-time 12 https://external-database-service/
command terminated with exit code 6      # curl: could not resolve host
```

Before blaming the Service, I checked whether the CNAME target resolves at all:

```bash
# from the macOS host, nothing to do with Kubernetes
$ dig +short nencyravaliya.me A
(0 records)
$ dig +short nencyravaliya.me NS
(none)
```

```bash
# from inside the pod
$ kubectl exec dns-test-client -- nslookup nencyravaliya.me
** server can't find nencyravaliya.me: NXDOMAIN
```

And a control test proving CoreDNS resolves external names fine:

```bash
$ kubectl exec dns-test-client -- nslookup example.com
Name:	example.com
Address: 172.66.147.243
```

So: **`nencyravaliya.me` has no A records and no NS records — the domain does not resolve for
anyone.** The ExternalName service is working perfectly; it is handing back a CNAME to a name
that leads nowhere.

This is a genuinely useful failure to have seen. An ExternalName service **cannot validate its
own target.** It will happily alias a typo or an expired domain, report no error, create no
event, and show `Running`-equivalent health forever. The failure only ever appears at the
client, as a DNS error.

## Proving the mechanism against a target that resolves

`service-working.yaml` points the same construct at a live domain:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-web-service
spec:
  type: ExternalName
  externalName: example.com
```

Now the whole chain resolves:

```bash
$ kubectl exec dns-test-client -- nslookup external-web-service.default.svc.cluster.local
external-web-service.default.svc.cluster.local	canonical name = example.com
Name:	example.com
Address: 172.66.147.243
Name:	example.com
Address: 104.20.23.154
```

And a real request through the in-cluster name reaches the external host:

```bash
$ kubectl exec dns-test-client -- curl -o /dev/null -w "HTTP %{http_code}  remote_ip=%{remote_ip}\n" \
    -H "Host: example.com" http://external-web-service/
HTTP 200  remote_ip=172.66.147.243
```

`remote_ip` is one of the public addresses `example.com` resolves to — confirming the pod
connected straight out to the internet, with the cluster doing nothing but the name lookup.

```
NAME                        TYPE           CLUSTER-IP   EXTERNAL-IP        PORT(S)   AGE
external-database-service   ExternalName   <none>       nencyravaliya.me   <none>    44s
external-web-service        ExternalName   <none>       example.com        <none>    3s
```

## Where this is genuinely useful

The point is **indirection at the DNS layer**. An application can be written to talk to
`payments-db` in every environment, while the service definition decides what that means:

| Environment | Service definition |
|---|---|
| dev | `ExternalName` → `dev-db.example.com` |
| staging | `ExternalName` → `staging-rds.amazonaws.com` |
| prod | a real `ClusterIP` in front of an in-cluster database |

Migrating a managed database into the cluster later becomes a change to one Service object,
with no application redeploy and no config change. That is the case for using it.

## The `Host` header gotcha

The `-H "Host: example.com"` above is not decoration. The pod connects to the external server
but sends whatever hostname it was given in the URL. Virtual-hosted servers and TLS
certificates both key off that name, so an ExternalName alias commonly produces a 404 or a
certificate mismatch even when DNS is perfect. HTTPS makes this worse: the TLS SNI will say
`external-web-service`, which no public certificate covers.

## Cleanup

```bash
kubectl delete -f service.yaml -f service-working.yaml -f client-pod.yaml
```
