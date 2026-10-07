# Kubernetes Volumes

Name: **Anisha Singhal** · Enrollment: **10020** · Session 13, Task 1

Six storage concepts, each run on the 3-node kind cluster rather than described. The
manifests are [`emptydir-pod.yaml`](emptydir-pod.yaml) and
[`hostpath-pod.yaml`](hostpath-pod.yaml); PV, PVC and StorageClass use the manifests in
[`../02-persistent-storage/`](../02-persistent-storage/) and
[`../03-storageclass/`](../03-storageclass/).

## The problem all of this solves

A container's filesystem dies with the container. Not with the pod — with the **container**. A
liveness probe restarting a container is enough to lose everything written to it. A volume is
storage with a lifetime decided by something other than the container.

The six options below differ only in **what that something is**.

| Volume type | Lives as long as | Survives container restart | Survives pod delete | Survives node change |
|---|---|---|---|---|
| container FS | the container | **no** | no | no |
| `emptyDir` | the **pod** | yes | no | no |
| `hostPath` | the **node** | yes | yes | **no** |
| PV + PVC | the **claim** | yes | yes | depends on the backend |

---

## emptyDir

An empty directory created when the pod is scheduled, and deleted when the pod is removed from
the node. Shared by every container in the pod.

```yaml
volumes:
  - name: app-storage
    emptyDir: {}
```

```
$ kubectl exec emptydir-demo -- sh -c 'echo "scratch data" > /data/tmp.txt; cat /data/tmp.txt'
scratch data
```

It is a real directory on the node, under the kubelet's pod directory:

```
$ docker exec devops-lab-worker2 ls /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~empty-dir/
app-storage
```

Delete the pod and recreate it from the same manifest:

```
$ kubectl delete pod emptydir-demo && kubectl apply -f emptydir-pod.yaml
$ kubectl exec emptydir-demo -- ls -la /data
total 8
drwxrwxrwx 2 root root 4096 Oct  7 18:49 .
drwxr-xr-x 1 root root 4096 Oct  7 18:49 ..
```

**Empty.** The data was tied to the pod, and a recreated pod is a different pod.

What it is genuinely for:

- **Sharing between containers in one pod** — a sidecar writing where the main container reads.
  This is the common case, and nothing else does it as simply.
- **Scratch space** — caches, temp files, a workspace an init container prepares.
- `emptyDir: { medium: Memory }` makes it a tmpfs — fast, and counted against the pod's memory
  limit, so a runaway write becomes an OOMKill rather than a full disk.

---

## hostPath

Mounts a path **from the node's own filesystem** into the pod.

```yaml
volumes:
  - name: host-storage
    hostPath:
      path: /tmp/hostpath-data
      type: DirectoryOrCreate
```

The mount is genuinely bidirectional. Writing in the pod:

```
$ kubectl exec hostpath-demo -- sh -c 'echo "written from inside the pod" > /data/from-pod.txt'
```

appears on the node, outside Kubernetes entirely:

```
$ docker exec devops-lab-worker2 cat /tmp/hostpath-data/from-pod.txt
written from inside the pod
```

and the reverse works too:

```
$ docker exec devops-lab-worker2 sh -c 'echo "written on the node itself" > /tmp/hostpath-data/from-node.txt'
$ kubectl exec hostpath-demo -- cat /data/from-node.txt
written on the node itself
```

### Why hostPath is a trap

The data belongs to **one node**, and nothing records which. Deleting the pod and recreating it
from the same manifest, pinned to the other worker:

```
$ kubectl get pod hostpath-demo -o jsonpath='{.spec.nodeName}'
devops-lab-worker

$ kubectl exec hostpath-demo -- ls -la /data
total 4
drwxr-xr-x 2 root root   40 Oct  7 18:49 .
drwxr-xr-x 1 root root 4096 Oct  7 18:49 ..
```

Empty — while the data sits untouched on the node it was written on:

```
$ docker exec devops-lab-worker2 ls -l /tmp/hostpath-data/
-rw-r--r-- 1 root root 27 Oct  7 18:49 from-node.txt
-rw-r--r-- 1 root root 28 Oct  7 18:49 from-pod.txt
```

**Same manifest, same path, no error, no data.** `DirectoryOrCreate` helpfully created an empty
directory, so the pod started perfectly and silently lost everything. On a single-node minikube
this never shows up, which is exactly why it reaches production.

It is also a **security hole**: `hostPath: /` with write access is root on the node, and
mounting `/var/run/docker.sock` is container escape. Pod Security Standards' `baseline` and
`restricted` profiles forbid hostPath for this reason.

Legitimate uses are all node-level agents: a log shipper reading `/var/log`, node-exporter
reading `/proc`, a CNI plugin writing `/etc/cni`. In every case the pod is a DaemonSet and the
node *is* the subject.

---

## PersistentVolume

A **cluster-level** storage resource — a piece of real storage (an EBS volume, an NFS export, a
local disk) represented as an API object. It exists independently of any pod, and like a Node it
is not namespaced.

```yaml
apiVersion: v1
kind: PersistentVolume
spec:
  capacity: { storage: 1Gi }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  hostPath: { path: /mnt/data }
```

The field that matters most is **`persistentVolumeReclaimPolicy`**, applied when the claim is
deleted:

| Policy | On claim deletion | Use |
|---|---|---|
| `Delete` | underlying storage destroyed | default for dynamic provisioning |
| `Retain` | PV kept, marked `Released`, data intact, needs manual cleanup | anything you cannot lose |
| `Recycle` | deprecated | — |

`Delete` being the default for dynamically provisioned volumes is how a `kubectl delete pvc`
becomes permanent data loss.

Access modes describe **nodes**, not pods — a distinction proved below:

| Mode | Meaning |
|---|---|
| `ReadWriteOnce` (RWO) | mounted read-write by **one node** |
| `ReadOnlyMany` (ROX) | read-only by many nodes |
| `ReadWriteMany` (RWX) | read-write by many nodes — needs NFS/CephFS/EFS; block storage cannot do it |
| `ReadWriteOncePod` | exactly one **pod**, cluster-wide |

---

## PersistentVolumeClaim

A **request** for storage: size, access mode, optionally a StorageClass. It is namespaced, and
it is what a pod actually references.

```yaml
volumes:
  - name: persistent-storage
    persistentVolumeClaim:
      claimName: web-data
```

The separation is the point. The application author asks for "500Mi, ReadWriteOnce" and never
names a disk, a region or a provider; the cluster administrator decides what satisfies that.
The same manifest runs on kind, EKS and GKE.

Binding is **one-to-one and exclusive** — once a PVC binds a PV, no other claim can use it, even
if the PV is far larger than the request. A PVC `Pending` forever usually means no PV matches on
size, access mode *and* StorageClass, and `kubectl describe pvc` says which.

---

## StorageClass

A named storage *profile*, letting a PVC say what kind of storage it wants without anyone
pre-creating a PV.

```
$ kubectl get sc
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   28m
```

Four fields to read:

- **provisioner** — the CSI driver that creates volumes (`ebs.csi.aws.com`, `rancher.io/local-path`).
- **reclaimPolicy** — inherited by every PV it creates. `Delete` here.
- **volumeBindingMode** — `Immediate` provisions as soon as the PVC is created;
  **`WaitForFirstConsumer`** waits until a pod is scheduled, so the volume is created in the
  right zone or on the right node. Getting this wrong on a multi-AZ cluster creates volumes
  pods cannot reach.
- **allowVolumeExpansion** — whether a PVC can be grown later. `false` here, and it cannot be
  changed retroactively on existing volumes.

`(default)` means a PVC with no `storageClassName` uses it. A cluster with no default
StorageClass leaves such PVCs `Pending` forever with a thoroughly unhelpful event.

---

## Dynamic provisioning

Without it, an administrator pre-creates every PV by hand, and a PVC binds only if one happens
to match. With a StorageClass, the PV is **created on demand**.

From the [mini project](../mini-project/README.md): a 500Mi PVC was applied with no PV
anywhere in the cluster.

```
$ kubectl get pvc -n production-webapp
NAME       STATUS    VOLUME   CAPACITY   STORAGECLASS
web-data   Pending                       standard
```

`Pending` — correct, not broken. The class is `WaitForFirstConsumer`, so nothing happens until a
pod needs it. Once the Deployment was applied:

```
$ kubectl get pvc -n production-webapp
NAME       STATUS   VOLUME                                     CAPACITY   STORAGECLASS
web-data   Bound    pvc-961b3869-51e0-4cc9-9d3e-71b438c27639   500Mi      standard
```

A PV appeared that nobody wrote:

```
$ kubectl get pv
NAME                                       CAPACITY   RECLAIM   STATUS   CLAIM      NODE
pvc-961b3869-51e0-4cc9-9d3e-71b438c27639   500Mi      Delete    Bound    web-data   devops-lab-worker2
```

Note the **NODE** column — `nodeAffinity` pinning the volume to `devops-lab-worker2`. That is
`WaitForFirstConsumer` doing its job, and it has a consequence that caught me out in the mini
project: **every replica of that Deployment must now schedule on worker2**, because the volume
cannot follow them. Five HPA-scaled pods all landed on one node.

So dynamic provisioning solved the hostPath locality problem at the API level — the volume is
found again automatically — but did not make the storage itself portable. Only genuinely
networked storage (EBS across a zone, NFS, EFS) does that.

### RWO is per node, not per pod

Two pods of the same Deployment, both on worker2, mounted the same RWO claim at once:

```
$ kubectl exec web-app-...-g9rht -- cat /data/student.txt
Student: Anisha Singhal (10020)
$ kubectl exec web-app-...-pn8hf -- cat /data/student.txt
Student: Anisha Singhal (10020)
```

This is correct behaviour and surprises almost everyone. `ReadWriteOnce` restricts the volume to
**one node**; any number of pods on that node may share it. `ReadWriteOncePod` is the mode that
means what people assume RWO means.

---

## Choosing

```
Does the data need to outlive the pod?
├── no  ──► emptyDir
└── yes ──► Is this a node-level agent that must read the node itself?
            ├── yes ──► hostPath (DaemonSet only)
            └── no  ──► PVC + StorageClass (dynamic provisioning)
                        └── multiple nodes writing at once? ──► RWX backend (NFS/EFS/CephFS)
```

## What I took away

- **The container filesystem dies on restart, not just on delete.** A liveness probe is enough
  to lose data.
- **hostPath fails silently and completely.** `DirectoryOrCreate` makes a fresh empty directory
  on the new node, so there is no error anywhere — the pod is Running and the data is gone.
- **`Pending` on a `WaitForFirstConsumer` PVC is correct**, and looks identical to the failure
  mode of having no default StorageClass.
- **RWO means one node, not one pod** — multiple pods can and did share it.
- **`WaitForFirstConsumer` pins pods to a node**, which quietly bounds how far a Deployment with
  a PVC can horizontally scale.
- **`reclaimPolicy: Delete` is the default** for dynamic provisioning, which makes
  `kubectl delete pvc` a destructive command.
