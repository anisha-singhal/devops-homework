# DevOps Homework — Anisha Singhal

Coursework for the DevOps module, all 21 sessions: Linux through the final capstone. One folder
per topic, each with its own README containing the commands that were run, their real output,
and screenshots where a browser was involved.

**Name:** Anisha Singhal
**Enrollment number:** 10020

| # | Folder | Topic |
|---|---|---|
| 1 | [`01-linux-fundamentals/`](01-linux-fundamentals/) | Hard vs soft links, `useradd` vs `adduser`, `journalctl`, command cheat sheet |
| 2 | [`02-shell-scripting/`](02-shell-scripting/) | `sysinfo.sh` — variables, `read -p`, `mkdir`/`touch`, output redirection |
| 3 | [`03-networking-fundamentals/`](03-networking-fundamentals/) | IP classes and subnetting, `ip`, `ping`, `dig`, `ss`, `curl`, `traceroute` |
| 4 | [`04-git-github/`](04-git-github/) | `git commit -a -m` vs `-m`, `git cherry-pick` including conflict resolution |
| 5 | [`05-docker-fundamentals/`](05-docker-fundamentals/) | Six Hello World containers: Node.js, Python, Java, Apache, React, Nginx |
| 6 | [`06-dockerfiles-and-images/`](06-dockerfiles-and-images/) | Multi-stage builds, measured against single-stage equivalents |
| 7 | [`07-docker-networking-volumes/`](07-docker-networking-volumes/) | Three-network topology, host networking, bind mounts, overlay networks, Compose + named volumes |
| 8 | [`08-kubernetes-fundamentals/`](08-kubernetes-fundamentals/) | Architecture and the reconciliation loop, observed on a live cluster |
| 9 | [`09-kubernetes-services/`](09-kubernetes-services/) | All five Service types: ClusterIP, NodePort, LoadBalancer, ExternalName, Headless |
| 10 | [`10-kubernetes-workloads/`](10-kubernetes-workloads/) | Pods, ReplicaSets, Deployments, pod lifecycle, rollout strategies |
| 11 | [`11-kubernetes-config-ingress/`](11-kubernetes-config-ingress/) | ConfigMaps, Secrets, Ingress routing by host and path |
| 12 | [`12-kubernetes-storage-hpa-probes/`](12-kubernetes-storage-hpa-probes/) | Volumes, PV/PVC, StorageClasses, probes, HorizontalPodAutoscaler |
| 13 | [`13-kubernetes-troubleshooting/`](13-kubernetes-troubleshooting/) | Five broken workloads diagnosed and fixed |
| 14 | [`14-helm/`](14-helm/) | Charts, templating, install/upgrade/rollback, `--atomic` |
| 15 | [`15-cicd-github-actions/`](15-cicd-github-actions/) | CI pipelines that actually run against this repo |
| 16 | [`16-devsecops/`](16-devsecops/) | SAST, SCA, secret and container scanning with a gate |
| 17 | [`17-terraform-iac/`](17-terraform-iac/) | Terraform init/plan/apply/destroy, state, drift |
| 18 | [`18-cloud-terraform/`](18-cloud-terraform/) | AWS VPC, subnets, routing, security groups |
| 19 | [`19-monitoring-gitops/`](19-monitoring-gitops/) | Prometheus, Grafana, PromQL, ArgoCD GitOps |
| 20 | [`20-final-project/`](20-final-project/) | Capstone: FastAPI + React + Postgres to Kubernetes |

## Environment

- **Host:** macOS (Apple Silicon, arm64), Docker Desktop 29.5.2
- **Linux work:** run inside `ubuntu:24.04` containers, since `journalctl`, `adduser`, `ip`
  and `ss` do not exist on macOS. `journalctl` needed a second container running `systemd` as
  PID 1.
- **Kubernetes:** a 3-node `kind` cluster (1 control-plane, 2 workers), Kubernetes v1.34.0,
  with MetalLB, ingress-nginx, metrics-server and ArgoCD installed as the exercises required.
- **Also used:** Helm 3.16.3, Terraform 1.9.8, LocalStack (AWS APIs locally), Prometheus,
  Grafana, bandit, pip-audit, gitleaks and trivy.
- **Screenshots:** captured with headless Chromium against the running containers.

Where macOS differs from a native Linux Docker host — most sharply with `--network host` —
that difference is documented and explained rather than skipped.

## Assignment coverage

| Assignment task | Where |
|---|---|
| Linux: soft & hard links | [`01`](01-linux-fundamentals/README.md#task-1--soft-links-vs-hard-links) |
| Linux: `adduser` vs `useradd` | [`01`](01-linux-fundamentals/README.md#task-2--useradd-vs-adduser) |
| Linux: `journalctl` | [`01`](01-linux-fundamentals/README.md#task-3--journalctl) |
| Linux: command cheat sheet | [`01`](01-linux-fundamentals/README.md#task-4--command-cheat-sheet) |
| Shell: system information script | [`02/sysinfo.sh`](02-shell-scripting/sysinfo.sh) |
| Networking: commands + explanations | [`03`](03-networking-fundamentals/README.md) |
| Git: `commit -a -m` vs `commit -m` | [`04`](04-git-github/README.md#task-1--git-commit--m-vs-git-commit--a--m) |
| Git: cherry-pick | [`04`](04-git-github/README.md#task-2--git-cherry-pick) |
| Docker: 6 Hello World apps | [`05`](05-docker-fundamentals/README.md) |
| Docker: multi-stage build on port 8080 | [`06`](06-dockerfiles-and-images/README.md#task-1--build-and-run-the-provided-multi-stage-dockerfile) |
| Docker: deploy 3 application types | [`06`](06-dockerfiles-and-images/README.md#task-3--deploy-three-different-application-types) |
| Docker: container networking, 3 networks | [`07`](07-docker-networking-volumes/README.md#task-1--container-networking-across-three-networks) |
| Docker: host network | [`07`](07-docker-networking-volumes/README.md#task-2--host-network) |
| Docker: bind mount | [`07`](07-docker-networking-volumes/README.md#task-3--bind-mount) |
| Docker: overlay networks | [`07`](07-docker-networking-volumes/README.md#task-4--overlay-networks-research) |
| Docker: remaining session exercises (Compose, named volumes) | [`07`](07-docker-networking-volumes/README.md#session-exercises--docker-compose-and-named-volumes) |
| Kubernetes Fundamentals | [`08`](08-kubernetes-fundamentals/README.md) |
| Kubernetes Networking & Services | [`09`](09-kubernetes-services/README.md) |
| — Task 2: object comparisons (Deployment/ReplicaSet/DaemonSet/StatefulSet/Service) | [`09/comparisons`](09-kubernetes-services/comparisons/README.md) |
| — Task 3: FQDN | [`09/fqdn`](09-kubernetes-services/fqdn/README.md) |
| — Task 4: CoreDNS | [`09/coredns`](09-kubernetes-services/coredns/README.md) |
| Kubernetes Pods, ReplicaSets & Deployments | [`10`](10-kubernetes-workloads/README.md) |
| Kubernetes Ingress, ConfigMaps & Secrets | [`11`](11-kubernetes-config-ingress/README.md) |
| Session 13: Kubernetes Storage, HPA & Probes | [`12`](12-kubernetes-storage-hpa-probes/README.md) |
| — Task 1: volumes (emptyDir, hostPath, PV, PVC, StorageClass, dynamic provisioning) | [`12/01-volumes`](12-kubernetes-storage-hpa-probes/01-volumes/README.md) |
| — Task 3: mini project | [`12/mini-project`](12-kubernetes-storage-hpa-probes/mini-project/README.md) |
| Session 14: Kubernetes Troubleshooting | [`13`](13-kubernetes-troubleshooting/README.md) |
| Session 15: Helm | [`14`](14-helm/README.md) |
| Session 16: CI/CD & GitHub Actions | [`15`](15-cicd-github-actions/README.md) |
| Session 17: Complete CI/CD & DevSecOps | [`16`](16-devsecops/README.md) |
| Session 18: Terraform & Infrastructure as Code | [`17`](17-terraform-iac/README.md) |
| — Task 1: `terraform-s3-demo` | [`17/terraform-s3-demo`](17-terraform-iac/terraform-s3-demo/README.md) |
| — Task 2: AWS services (IAM, EC2, S3, VPC, DynamoDB & RDS) | [`17/aws-services`](17-terraform-iac/aws-services/) |
| Session 19: Cloud & Terraform in Action | [`18`](18-cloud-terraform/README.md) |
| Session 20: Monitoring, Observability & GitOps | [`19`](19-monitoring-gitops/README.md) |
| Session 21: Final DevOps Project & Troubleshooting | [`20`](20-final-project/README.md) |

## A few things I actually learned

Rather than a summary of each folder, the results that changed how I think about something:

- **Multi-stage builds are a mechanism, not a guarantee.** The provided multi-stage Dockerfile
  saved 6 MB (2%), because both stages use the same base image. Rewriting the Java app as
  JDK-builds/JRE-runs saved 269 MB (48%) with the identical technique. I only know that
  because I built the single-stage version and compared. → [`06`](06-dockerfiles-and-images/README.md#task-2--how-much-did-the-multi-stage-build-actually-save)

- **Docker network isolation happens at DNS, one layer earlier than I assumed.** The frontend
  container could not reach the database, and the error was `ping: bad address` — a *name
  resolution* failure, not a timeout. Docker's embedded resolver only answers for containers
  sharing a network, so there was never a packet to drop. → [`07`](07-docker-networking-volumes/README.md#connectivity-results)

- **A container's network view is not the machine's.** `traceroute` to the same host: 2 hops
  from inside a container, 10 hops from macOS. Docker Desktop's VM NATs everything, so the
  internet looks one hop away — `ping` said the same thing with `ttl=63`. Never diagnose
  network paths from inside a container. → [`03`](03-networking-fundamentals/README.md#the-same-traceroute-from-the-macos-host)

- **`traceroute`'s `* * *` is about the probe type, not reachability.** The default UDP probes
  were filtered; `-I` (ICMP) and `-T -p 443` (TCP) both completed instantly. → [`03`](03-networking-fundamentals/README.md#traceroute--the-path-and-a-lesson-in-probe-types)

- **`rm` removes names, not files.** After deleting the original, the hard link still had all
  the data and its link count had gone from 2 to 1. `Invalid cross-device link` and
  `hard link not allowed for directory` both follow from a hard link being an inode reference.
  → [`01`](01-linux-fundamentals/README.md#task-1--soft-links-vs-hard-links)

- **`git commit -a -m` discards deliberate staging.** With `fileA` staged and `fileB` a
  work-in-progress, `-a` committed both and warned about nothing. It still will not pick up
  untracked files — which is the failure people actually hit. → [`04`](04-git-github/README.md#the-second-difference--a-overrides-deliberate-staging)

- **`docker compose down` keeps your data; `down -v` deletes it.** Same stack, one character
  apart: 3 rows survived `down` and came back on a brand-new container, while after `down -v`
  even the *table* was gone (`Table 'demo.visits' doesn't exist`). Also learned that plain
  `depends_on` only waits for a container to *start* — `condition: service_healthy` is what
  actually stops an app racing its database.
  → [`07`](07-docker-networking-volumes/README.md#named-volume-vs-bind-mount)

- **A Deployment never creates pods.** Deployment → ReplicaSet → Pod, verified through
  `ownerReferences`. `kubectl set image` on a bare ReplicaSet rolls nothing — running pods keep
  the old image — which is the entire reason Deployments exist.
  → [`10`](10-kubernetes-workloads/README.md#the-reason-deployments-exist)

- **`Running` is not healthy.** A CrashLoopBackOff pod reports phase `Running`; `READY` is the
  field that decides whether it gets traffic. `CrashLoopBackOff` and `ImagePullBackOff` are not
  phases at all. → [`10`](10-kubernetes-workloads/README.md#running-does-not-mean-healthy)

- **Kubernetes Service load balancing is random, not round-robin.** 60 requests split 24/19/17,
  explained exactly by the kube-proxy `--probability` iptables chain.
  → [`09`](09-kubernetes-services/README.md#findings-worth-keeping)

- **Base64 is encoding, not encryption**, and `envFrom` puts a Secret into the container
  environment in plain text. `echo` without `-n` silently appends a newline and produces a
  password one byte too long. → [`11`](11-kubernetes-config-ingress/README.md#part-2--secret-and-what-it-does-not-do)

- **`curl -w` turns "it's slow" into a specific problem** by splitting a request into DNS /
  TCP / TLS / server think time / transfer. Three different owners, one command. → [`03`](03-networking-fundamentals/README.md#curl--speaking-http)

- **`ReadWriteOnce` means one node, not one pod.** Two separate pods of the same Deployment
  mounted the same RWO claim simultaneously and both read the file the other wrote. Worse, the
  PV's `nodeAffinity` pinned all five HPA-scaled replicas to a single node of three — an RWO
  volume plus horizontal autoscaling is an architectural contradiction that YAML validation
  cannot catch. → [`12/mini-project`](12-kubernetes-storage-hpa-probes/mini-project/README.md#unexpected-result-2--the-hpa-cannot-spread-across-nodes)

- **An HPA scales out in seconds and back in minutes, deliberately.** CPU fell to 1% and the
  replica count stayed at 5 for four and a half more minutes — the 5-minute downscale
  stabilization window. Watching for two minutes and concluding it was broken would have been
  the wrong call. → [`12/mini-project`](12-kubernetes-storage-hpa-probes/mini-project/README.md#scale-down)

- **`hostPath` loses data silently and completely.** The same manifest on a different node
  produced a Running pod with an empty directory, because `DirectoryOrCreate` helpfully created
  a new one. No error anywhere. On single-node minikube this never surfaces, which is how it
  reaches production. → [`12/01-volumes`](12-kubernetes-storage-hpa-probes/01-volumes/README.md#why-hostpath-is-a-trap)

- **`ndots:5` costs three wasted DNS queries per external lookup.** CoreDNS's own query log
  showed `github.com` resolved only after NXDOMAIN on three search domains — and the misses took
  0.1 ms while the real query took 3.1 seconds. A trailing dot skips the whole search path and
  almost nobody uses it. → [`09/fqdn`](09-kubernetes-services/fqdn/README.md#the-ndots5-tax)

- **"Timeout waiting for state" rarely means the write failed.** Terraform spent 3 minutes
  failing to create an S3 lifecycle rule that LocalStack had written correctly in the first
  second. Two plausible guesses about rule shape were both wrong; `TF_LOG=DEBUG` plus the
  provider source showed it compares a `TransitionDefaultMinimumObjectSize` field LocalStack
  never returns, so the equality check could never pass.
  → [`17/terraform-s3-demo`](17-terraform-iac/terraform-s3-demo/README.md#the-lifecycle-rule-that-would-not-converge)

- **Empty output from a diagnostic tool is data.** `ss -tulpn` printed only a header and I
  assumed it was broken in the container. Nothing was listening — the server I thought I had
  started needed `python3`, which was not installed. → [`03`](03-networking-fundamentals/README.md#ss--sockets)
