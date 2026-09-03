# DevOps Homework — Anisha Singhal

Coursework for the DevOps module, covering everything through the Docker sessions. One folder
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

## Environment

- **Host:** macOS (Apple Silicon, arm64), Docker Desktop 29.5.2
- **Linux work:** run inside `ubuntu:24.04` containers, since `journalctl`, `adduser`, `ip`
  and `ss` do not exist on macOS. `journalctl` needed a second container running `systemd` as
  PID 1.
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
| Networking: commands + explanations | [`03/networking.md`](03-networking-fundamentals/networking.md) |
| Git: `commit -a -m` vs `commit -m` | [`04/git-tasks.md`](04-git-github/git-tasks.md#task-1--git-commit--m-vs-git-commit--a--m) |
| Git: cherry-pick | [`04/git-tasks.md`](04-git-github/git-tasks.md#task-2--git-cherry-pick) |
| Docker: 6 Hello World apps | [`05`](05-docker-fundamentals/README.md) |
| Docker: multi-stage build on port 8080 | [`06`](06-dockerfiles-and-images/README.md#task-1--build-and-run-the-provided-multi-stage-dockerfile) |
| Docker: deploy 3 application types | [`06`](06-dockerfiles-and-images/README.md#task-3--deploy-three-different-application-types) |
| Docker: container networking, 3 networks | [`07`](07-docker-networking-volumes/README.md#task-1--container-networking-across-three-networks) |
| Docker: host network | [`07`](07-docker-networking-volumes/README.md#task-2--host-network) |
| Docker: bind mount | [`07`](07-docker-networking-volumes/README.md#task-3--bind-mount) |
| Docker: overlay networks | [`07`](07-docker-networking-volumes/README.md#task-4--overlay-networks-research) |
| Docker: remaining session exercises (Compose, named volumes) | [`07`](07-docker-networking-volumes/README.md#session-exercises--docker-compose-and-named-volumes) |

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
  network paths from inside a container. → [`03`](03-networking-fundamentals/networking.md#the-same-traceroute-from-the-macos-host)

- **`traceroute`'s `* * *` is about the probe type, not reachability.** The default UDP probes
  were filtered; `-I` (ICMP) and `-T -p 443` (TCP) both completed instantly. → [`03`](03-networking-fundamentals/networking.md#traceroute--the-path-and-a-lesson-in-probe-types)

- **`rm` removes names, not files.** After deleting the original, the hard link still had all
  the data and its link count had gone from 2 to 1. `Invalid cross-device link` and
  `hard link not allowed for directory` both follow from a hard link being an inode reference.
  → [`01`](01-linux-fundamentals/README.md#task-1--soft-links-vs-hard-links)

- **`git commit -a -m` discards deliberate staging.** With `fileA` staged and `fileB` a
  work-in-progress, `-a` committed both and warned about nothing. It still will not pick up
  untracked files — which is the failure people actually hit. → [`04`](04-git-github/git-tasks.md#the-second-difference--a-overrides-deliberate-staging)

- **`docker compose down` keeps your data; `down -v` deletes it.** Same stack, one character
  apart: 3 rows survived `down` and came back on a brand-new container, while after `down -v`
  even the *table* was gone (`Table 'demo.visits' doesn't exist`). Also learned that plain
  `depends_on` only waits for a container to *start* — `condition: service_healthy` is what
  actually stops an app racing its database.
  → [`07`](07-docker-networking-volumes/README.md#named-volume-vs-bind-mount)

- **`curl -w` turns "it's slow" into a specific problem** by splitting a request into DNS /
  TCP / TLS / server think time / transfer. Three different owners, one command. → [`03`](03-networking-fundamentals/networking.md#curl--speaking-http)

- **Empty output from a diagnostic tool is data.** `ss -tulpn` printed only a header and I
  assumed it was broken in the container. Nothing was listening — the server I thought I had
  started needed `python3`, which was not installed. → [`03`](03-networking-fundamentals/networking.md#ss--sockets)
