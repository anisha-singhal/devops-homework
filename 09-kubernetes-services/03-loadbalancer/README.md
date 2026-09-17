# LoadBalancer — and What Happens Without a Cloud Provider

Exercise `03-loadbalancer`. The interesting part of this one is that it **does not work** on a
local cluster by default, and the reason is worth understanding.

## The default result: `<pending>`, forever

```bash
kubectl apply -f app-deployment.yaml -f service.yaml
kubectl get svc web-service-loadbalancer
```

```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-service-loadbalancer   LoadBalancer   10.96.165.17   <pending>     80:32499/TCP   2s
```

Fifteen seconds later, unchanged:

```
web-service-loadbalancer   LoadBalancer   10.96.165.17   <pending>     80:32499/TCP   18s
```

```bash
$ kubectl describe svc web-service-loadbalancer | grep -i events
Events:                   <none>
```

**No events at all** — and that is the diagnosis. `<pending>` with events would mean something
tried and failed. `<pending>` with *nothing* means **no controller is even watching**.

A `type: LoadBalancer` service does not create a load balancer. It writes a request into the
API and waits for a cloud-controller-manager to notice. On EKS that controller calls AWS and
gets an ELB; on GKE it calls Google. On kind, nobody is listening, so the field stays empty
indefinitely. The service is not broken — it is **unfulfilled**.

Note what it *did* get: `80:32499/TCP`. Kubernetes allocated a NodePort automatically. A
LoadBalancer service is a **superset** of NodePort, which is a superset of ClusterIP — each
type adds a layer rather than replacing one. The cloud LB's job is only to forward to that
node port.

## Making it real with MetalLB

Rather than stop at `<pending>`, I installed **MetalLB**, which is the standard answer for
bare-metal and local clusters — it is the missing controller.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
kubectl wait -n metallb-system --for=condition=Ready pod --selector=app=metallb --timeout=300s
```

It needs a pool of addresses it is allowed to hand out. Those must be routable on the network
the nodes sit on — for kind that is the `kind` docker network:

```bash
$ docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'
fc00:f853:ccd:e793::/64 172.20.0.0/16
```

```yaml
# metallb-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - 172.20.255.200-172.20.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
```

The range sits high in `172.20.0.0/16`, away from the node addresses (`172.20.0.2-4`) that
Docker assigns, so the two cannot collide.

## The same service, now fulfilled

Nothing about the Service manifest changed. Within two seconds of the pool existing:

```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)        AGE
web-service-loadbalancer   LoadBalancer   10.96.165.17   172.20.255.200   80:32499/TCP   91s
```

And the events that were absent before:

```
Type    Reason        From                Message
----    ------        ----                -------
Normal  IPAllocated   metallb-controller  Assigned IP ["172.20.255.200"]
Normal  nodeAssigned  metallb-speaker     announcing from node "devops-lab-worker" with protocol "layer2"
```

Two distinct steps, which is exactly how a cloud LB works too: **allocate** an address, then
**advertise** a path to it. In layer-2 mode one node answers ARP for that IP and becomes the
entry point; if it dies, another speaker takes over.

## Traffic through the external IP

```bash
$ curl http://172.20.255.200
<h1>LoadBalancer: served by web-app-loadbalancer-7f4b888fc7-8pggs</h1>
```

30 requests, spread over all three pods:

```
   9 served by web-app-loadbalancer-7f4b888fc7-8pggs
   8 served by web-app-loadbalancer-7f4b888fc7-k6dhn
  13 served by web-app-loadbalancer-7f4b888fc7-t9w6r
```

## One honest limitation

```bash
# from the macOS host
$ curl --max-time 6 http://172.20.255.200
HTTP 000  (unreachable)
```

This works from inside the kind network and **not** from macOS. Docker Desktop runs containers
in a Linux VM and does not route the host to the docker bridge network, so `172.20.255.200` is
reachable from the nodes and from other containers but not from the Mac. On a Linux host with
Docker running natively, this same setup *is* reachable directly.

That is a limitation of the environment, not of MetalLB or of the manifest — and it is why no
browser screenshot is included for this exercise. The NodePort exercise gets one because kind's
`extraPortMappings` bridge that gap explicitly; there is no equivalent for an arbitrary
MetalLB address.

## Cost, which is the real-world constraint

On a cloud provider **each `type: LoadBalancer` service provisions its own load balancer**,
each with a monthly bill. Ten microservices exposed this way is ten load balancers. This is the
single biggest reason production clusters put one Ingress controller behind one LoadBalancer
and route everything through it by hostname and path — covered in the Ingress section.

## Cleanup

```bash
kubectl delete -f service.yaml -f app-deployment.yaml
kubectl delete -f metallb-pool.yaml      # leave MetalLB itself installed for the Ingress work
```
