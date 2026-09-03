# Docker Networking & Volumes

Run on macOS (arm64), Docker Desktop 29.5.2. Where macOS behaves differently from Linux —
which it does, sharply, for host networking — that is called out rather than glossed over.

## Task 1 — Container networking across three networks

### Topology

```
        frontend-net (172.20.0.0/16)          backend-net (172.21.0.0/16)
        ┌──────────────────────────┐          ┌──────────────────────────┐
        │  frontend   172.20.0.2   │          │  database   172.21.0.2   │
        │  (nginx:alpine)          │          │  (mysql:8.4)             │
        │                          │          │                          │
        │  backend    172.20.0.3 ──┼──────────┼── backend  172.21.0.3    │
        └──────────────────────────┘          └──────────────────────────┘
                                    monitoring-net  (created, no members)

   frontend ──✓── backend ──✓── database
   frontend ──────────✗──────────  database     (no shared network)
```

`backend` is the only container on two networks, so it is the only path between the frontend
and the database. That is the whole point of the exercise: the frontend has no route to the
database at all, and the isolation is enforced by Docker rather than by the application.

### Setup

```bash
docker network create frontend-net
docker network create backend-net
docker network create monitoring-net

docker run -d --name frontend --network frontend-net nginx:1.27-alpine
docker run -d --name database --network backend-net \
  -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=appdb mysql:8.4
docker run -d --name backend  --network frontend-net alpine:3.21 sleep infinity

# a container can only be given one --network at run time;
# additional networks are attached afterwards
docker network connect backend-net backend
```

`docker network ls`:

```
NETWORK ID     NAME             DRIVER    SCOPE
c62cf9d06b30   backend-net      bridge    local
607f1d91f298   frontend-net     bridge    local
4a63601aad5b   monitoring-net   bridge    local
```

Membership per network:

```
frontend-net     : frontend (172.20.0.2/16) backend (172.20.0.3/16)
backend-net      : database (172.21.0.2/16) backend (172.21.0.3/16)
monitoring-net   :
```

`backend` holds one IP per network it joined:

```bash
$ docker inspect backend --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} -> {{$v.IPAddress}}{{"\n"}}{{end}}'
backend-net -> 172.21.0.3
frontend-net -> 172.20.0.3
```

### Connectivity results

**backend → frontend** (shared `frontend-net`) — reachable:

```
64 bytes from 172.20.0.2: seq=1 ttl=64 time=0.213 ms
--- frontend ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

**backend → database** (shared `backend-net`) — reachable:

```
64 bytes from 172.21.0.2: seq=1 ttl=64 time=0.134 ms
--- database ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

**backend → database:3306** — the MySQL port is open across the network:

```bash
$ docker exec backend nc -z -w 3 database 3306 && echo "PORT 3306 OPEN from backend"
PORT 3306 OPEN from backend
```

**frontend → backend** (shared `frontend-net`) — reachable:

```
--- backend ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

**frontend → database** (no shared network) — blocked:

```bash
$ docker exec frontend ping -c 2 database
ping: bad address 'database'
ping exit code: 1
```

The failure mode is worth reading carefully. It is not "request timed out" — it is
**`bad address`**, a *DNS* failure. Docker's embedded DNS resolver only answers for
containers that share a network with the asking container. From `frontend`, the name
`database` does not resolve at all, so there is never a packet to drop. Isolation happens one
layer earlier than I expected.

### The same result at the application layer

Ping proves ICMP; a real client proves it properly. The same query, run from the two
different networks:

```bash
# on backend-net -- works
$ docker run --rm --network backend-net mysql:8.4 \
    mysql -h database -u root -prootpw -e "SELECT VERSION(); SHOW DATABASES;"
mysql_version
8.4.11
Database
appdb
information_schema
mysql
performance_schema
sys
```

```bash
# on frontend-net -- fails
$ docker run --rm --network frontend-net mysql:8.4 \
    mysql -h database -u root -prootpw --connect-timeout=5 -e "SELECT 1"
ERROR 2005 (HY000): Unknown MySQL server host 'database' (-2)
```

`Unknown MySQL server host` is the MySQL client reporting the same DNS failure. This is the
three-tier pattern working as intended: the database is reachable from the application tier
and invisible to the web tier, with no firewall rules written by hand.

## Task 2 — Host network

```bash
docker run -d --name apache-host --network host httpd:2.4
```

`docker ps` — note the **empty** `PORTS` column:

```
NAMES         IMAGE       STATUS         PORTS
apache-host   httpd:2.4   Up 5 seconds
```

```bash
$ docker inspect apache-host --format 'NetworkMode={{.HostConfig.NetworkMode}} ... IP="..."'
NetworkMode=host  Networks=host  IP="invalid IP"
```

Both details are correct and expected. With `--network host` the container does not get its
own network namespace, so it has **no IP of its own** and there is **nothing to publish** —
`-p` would be meaningless. The process binds port 80 directly in the host's namespace.

### On macOS this is not the machine's port 80

```bash
$ curl --max-time 8 http://localhost:80     # from macOS
HTTP 000
FAILED from macOS host
```

Docker Desktop does not run containers on macOS directly — it runs a Linux VM and the
containers live inside it. `--network host` means *the VM's* network namespace, not the
MacBook's. There is no port to forward, because host mode deliberately bypasses the
port-publishing machinery that normally bridges the VM to macOS. So the container is
genuinely serving on port 80 — just not on a port 80 that macOS can see.

Proof, from a second container sharing that same host namespace:

```bash
$ docker run --rm --network host alpine:3.21 wget -qS -O /dev/null http://localhost:80
  HTTP/1.1 200 OK
  Date: Thu, 03 Sep 2026 17:00:50 GMT
  Server: Apache/2.4.68 (Unix)
  Last-Modified: Fri, 07 Nov 2025 08:23:08 GMT
  ETag: "bf-642fce432f300"
  Accept-Ranges: bytes
```

Apache is up and answering on port 80 in the host namespace. On a **Linux** Docker host this
same command would have worked directly from the terminal, and `curl localhost:80` would have
returned the page — that is the result the task is describing.

### Reaching Apache on port 80 from macOS

To actually meet "access the Apache website on port 80" on this machine, bridge mode with an
explicit publish is the portable way:

```bash
docker stop apache-host          # it was holding port 80 inside the VM
docker run -d --name apache-bridge -p 80:80 httpd:2.4
```

```
NAMES           IMAGE       STATUS         PORTS
apache-bridge   httpd:2.4   Up 4 seconds   0.0.0.0:80->80/tcp, [::]:80->80/tcp
```

```bash
$ curl -s http://localhost:80
<html><head>
<title>It works! Apache httpd</title>
</head><body>
<p>It works!</p>
</body></html>
```

![apache on port 80](screenshots/apache-port80.png)

A side lesson from getting there: the first `-p 80:80` attempt failed with
`failed to bind host port 0.0.0.0:80/tcp: address already in use`. The host-network Apache
was still holding port 80 *inside the VM*. Host mode does not isolate ports, so it collides
with anything else wanting the same one — which is a real cost of using it.

### When host networking is worth it

- No NAT layer, so slightly lower latency and higher throughput — the reason it shows up in
  high-performance networking and packet-capture workloads.
- The container can see the host's real interfaces, needed for tools that sniff traffic or
  for services using dynamic/large port ranges where `-p` is impractical.
- The costs: no network isolation, port collisions with the host, and — as measured above —
  no portability between Linux hosts and Docker Desktop.

## Task 3 — Bind mount

```bash
mkdir site
cat > site/index.html   # <h1>Hello students</h1>

docker run -d --name nginx-bind -p 8090:80 \
  -v "$PWD/site":/usr/share/nginx/html:ro nginx:1.27-alpine
```

The `:ro` suffix mounts it read-only, which is right for static content the container should
serve but never modify.

```bash
$ docker inspect nginx-bind --format '{{range .Mounts}}type={{.Type}} src={{.Source}} dst={{.Destination}} rw={{.RW}}{{end}}'
type=bind src=/Users/Anisha/devops-homework/07-docker-networking-volumes/site dst=/usr/share/nginx/html rw=false
```

Before the edit:

```bash
$ curl -s http://localhost:8090 | grep -o '<h1>.*</h1>'
<h1>Hello students</h1>
```

### Editing the file with the container still running

`index.html` was then rewritten **on the macOS host** — no restart, no rebuild, no
`docker cp`:

```bash
$ curl -s -i http://localhost:8090
HTTP/1.1 200 OK
Server: nginx/1.27.5
Date: Thu, 03 Sep 2026 17:01:50 GMT
Content-Type: text/html
Content-Length: 300
Last-Modified: Thu, 03 Sep 2026 17:01:43 GMT
ETag: "6a99a7f7-12c"

<!doctype html>
<html>
  <head><title>Bind mount demo</title></head>
  <body style="font-family: system-ui; text-align: center; padding-top: 3rem">
    <h1>Hello students - edited live at 22:31 IST</h1>
    <p>This file was changed on the host while the container kept running.</p>
  </body>
</html>
```

The new content is served, and the container never went down:

```bash
$ docker inspect nginx-bind --format 'started at: {{.State.StartedAt}}  restarts: {{.RestartCount}}'
started at: 2026-09-03T17:01:29.928385586Z  restarts: 0
```

Same `StartedAt` as before the edit and `restarts: 0` — this is the same process that was
running beforehand. The updated `Last-Modified` header is nginx reading the host's file
metadata straight through the mount. A bind mount is not a copy: the container is looking at
the host's directory, so a change on either side is the same change.

The read-only flag holds from the inside:

```bash
$ docker exec nginx-bind sh -c 'echo test > /usr/share/nginx/html/probe.txt'
sh: can't create /usr/share/nginx/html/probe.txt: Read-only file system
```

![bind mount serving the edited file](screenshots/bind-mount.png)

One measured detail: a `curl` fired *immediately* after the write came back without the new
text, and the next one had it. On Docker Desktop for macOS the host directory reaches the
container over a virtiofs share, so propagation is fast but not instantaneous. On native
Linux the mount is direct and the change is atomic with the write. Worth knowing before
blaming a hot-reload setup that "sometimes misses" a save.

## Task 4 — Overlay networks (research)

The three networks in Task 1 are `bridge` — the default local driver. A bridge is a virtual
switch on **one** Docker host, so it cannot connect containers on different machines.
`overlay` is the driver that can.

### How it works

An overlay network puts a **VXLAN tunnel** between the participating hosts. A container's
Ethernet frame is wrapped in a UDP packet (port 4789), sent across the physical network to
the host running the destination container, unwrapped there, and delivered. The containers
see one flat L2 segment and address each other by name; the fact that the traffic crossed a
real network in between is invisible to them.

This needs shared state, so overlay requires a cluster with a key-value store of its own —
in practice **Docker Swarm mode** (`docker swarm init` / `docker swarm join`), which keeps
the network and service records in its internal Raft store. This is why `docker network
create -d overlay` fails on a standalone daemon: there is nowhere to keep the membership
data.

Ports that must be open between hosts:

| Port | Protocol | Purpose |
|---|---|---|
| 2377 | TCP | cluster management (managers only) |
| 7946 | TCP + UDP | node discovery and gossip |
| 4789 | UDP | VXLAN data plane |

### Bridge vs overlay

| | bridge | overlay |
|---|---|---|
| Scope | single host | many hosts |
| Backing | Linux bridge + iptables NAT | VXLAN tunnels |
| Needs a cluster | no | yes (Swarm or external KV store) |
| Service discovery | embedded DNS, local | embedded DNS, cluster-wide |
| Built-in encryption | no | yes, `--opt encrypted` (IPsec) |
| `docker network ls` SCOPE | `local` | `swarm` |

### Use cases

- **Multi-host services.** The natural one: a web tier on three nodes talking to a database
  on a fourth, all by container name, without hardcoding node IPs.
- **Scaling and failover.** With a Swarm service, a replica rescheduled onto a different node
  keeps the same network identity. Nothing in the application changes.
- **Cross-host isolation.** Task 1's segmentation, but cluster-wide: a `backend-net` overlay
  can span every node while staying invisible to containers not attached to it.
- **Encrypted east-west traffic.** `--opt encrypted` puts IPsec on the VXLAN tunnels, which
  matters when the hosts talk over a network you do not control.

The honest limitation: I could verify Tasks 1–3 by running them, but overlay needs at least
two Docker hosts, and this is a single-machine setup — so this section is reading and notes,
not measurement. Kubernetes solves the same problem with CNI plugins (Calico, Flannel,
Cilium) rather than Docker's own overlay driver, which is where this leads next in the course.

## Session exercises — Docker Compose and named volumes

Tasks 1–3 were assembled by hand with `docker run` and `docker network connect`. The session
also covers `docker-compose` and **named volumes**, so `compose-stack/` rebuilds the same
three-tier topology declaratively and adds the volume type that Task 3 does not use.

### The stack

```yaml
services:
  frontend:
    image: nginx:1.27-alpine
    ports: ["8095:80"]
    volumes:                                  # bind mounts: host files
      - ./frontend/index.html:/usr/share/nginx/html/index.html:ro
      - ./frontend/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [frontend_net]

  backend:
    build: ./backend
    networks: [frontend_net, backend_net]     # the only service on both
    depends_on:
      database:
        condition: service_healthy

  database:
    image: mysql:8.4
    volumes:
      - db_data:/var/lib/mysql                # named volume: Docker-managed
    networks: [backend_net]
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-prootpw"]
      interval: 5s
      retries: 20

networks:
  frontend_net:
  backend_net:

volumes:
  db_data:
```

The backend is a small Flask app that connects to MySQL, inserts a row into a `visits` table
and returns the row count — so a single HTTP request exercises the whole chain and leaves
evidence in the database.

### One command instead of six

```bash
$ docker compose up -d
 Network compose-stack_backend_net   Created
 Network compose-stack_frontend_net  Created
 Volume compose-stack_db_data        Created
 Container compose-stack-database-1  Started
 Container compose-stack-database-1  Waiting
 Container compose-stack-database-1  Healthy
 Container compose-stack-backend-1   Started
 Container compose-stack-frontend-1  Started
```

```
NAME                       IMAGE                   SERVICE    STATUS
compose-stack-backend-1    compose-stack-backend   backend    Up
compose-stack-database-1   mysql:8.4               database   Up (healthy)
compose-stack-frontend-1   nginx:1.27-alpine       frontend   Up 0.0.0.0:8095->80/tcp
```

Two things compose did that the manual version could not:

- **`database Waiting` → `Healthy` → `backend Started`.** `depends_on: condition:
  service_healthy` blocked the backend until MySQL answered `mysqladmin ping`. In Task 1 I had
  to poll the logs by hand for `ready for connections`. Plain `depends_on` only waits for the
  container to *start*, which is why apps race their database — the healthcheck is what makes
  it actually work.
- **A service can be given several networks at creation.** `docker run` accepts only one, so
  Task 1 needed `docker network connect` as a second step.

Note compose namespaced everything with the project directory: `compose-stack_frontend_net`,
`compose-stack_db_data`. Two projects can use the same service names without colliding.

### The full chain works

```bash
$ curl -s http://localhost:8095/api      # nginx -> flask -> mysql
{"mysql_version":"8.4.11","total_visits":1}
{"mysql_version":"8.4.11","total_visits":2}
{"mysql_version":"8.4.11","total_visits":3}
```

Each request proves nginx proxied to `backend:5000` over `frontend_net`, and the backend
reached `database:3306` over `backend_net`.

The backend also exposes a read-only `/health` route:

```bash
$ curl -s http://localhost:8095/health
{"status":"ok"}
```

`/api` writes a row; `/health` only runs `SELECT 1`. That split matters for the volume test
below — the first version of this stack had `/api` as its only route, so waiting for the stack
to come up meant polling an endpoint that *incremented the counter I was trying to measure*.
A readiness probe has to be side-effect free, or it corrupts what it is checking.

![compose stack frontend](screenshots/compose-stack.png)

The isolation from Task 1 still holds, now without configuring it by hand:

```bash
$ docker compose exec frontend ping -c 1 database
ping: bad address 'database'
```

```
compose-stack_frontend_net : backend, frontend
compose-stack_backend_net  : backend, database
```

### Named volume vs bind mount

This stack uses both, which makes the difference concrete:

```bash
$ docker volume inspect compose-stack_db_data
name=compose-stack_db_data  driver=local  mountpoint=/var/lib/docker/volumes/compose-stack_db_data/_data
```

The mountpoint is inside Docker's own storage, not a path I chose — the opposite of the Task 3
bind mount, which pointed at a directory in this repo.

**Does the data survive losing the containers?**

Three visits, then read the count back with a plain `SELECT` rather than through the endpoint
that writes:

```bash
$ for i in 1 2 3; do curl -s http://localhost:8095/api; done
{"mysql_version":"8.4.11","total_visits":1}
{"mysql_version":"8.4.11","total_visits":2}
{"mysql_version":"8.4.11","total_visits":3}

$ docker compose exec database mysql -u root -prootpw demo -N -e "SELECT COUNT(*) FROM visits;"
3
```

Now destroy the containers:

```bash
$ docker compose down          # containers and networks removed
 Container compose-stack-database-1  Removed
 Network compose-stack_backend_net   Removed

$ docker compose ps
(nothing)

$ docker volume ls -q --filter name=compose-stack_db_data
compose-stack_db_data          <- the volume is still there
```

And bring it back:

```bash
$ docker compose up -d
$ docker compose exec database mysql -u root -prootpw demo -N -e "SELECT COUNT(*) FROM visits;"
3
```

**Still 3.** And it is genuinely a different container:

```
old database container id: 108a95b990f2
new database container id: a440535494d2
```

The MySQL container that wrote those rows no longer exists. The data was never in the
container — it was in the volume all along, and the new container mounted the same one.

**And when the volume is explicitly destroyed:**

```bash
$ docker compose down -v      # -v also removes named volumes
 Volume compose-stack_db_data Removing
 Volume compose-stack_db_data Removed

$ docker volume ls -q --filter name=compose-stack_db_data
                               <- empty: deleted
```

```bash
$ docker compose up -d
$ docker compose exec database mysql -u root -prootpw demo -e "SELECT COUNT(*) FROM visits;"
ERROR 1146 (42S02) at line 1: Table 'demo.visits' doesn't exist
```

Not "zero rows" — **the table is gone entirely.** MySQL re-initialised an empty data
directory, so even the schema the backend had created no longer exists. The next request
recreates it from nothing:

```bash
$ curl -s http://localhost:8095/api
{"mysql_version":"8.4.11","total_visits":1}
```

Back to 1, from a table that had to be created again.

That pair of results is the whole lesson: **`down` keeps your data, `down -v` deletes it.**
`-v` is a single character between "restart the stack" and "lose the database", which is why
it is worth never typing reflexively.

| | Bind mount | Named volume |
|---|---|---|
| Where the data lives | a host path you choose | Docker-managed storage |
| Declared as | `./site:/usr/share/nginx/html` | `db_data:/var/lib/mysql` |
| Editable from the host | yes, directly | not conveniently |
| Survives `docker rm` | yes (it is on the host) | yes |
| Removed by `compose down -v` | no | **yes** |
| Portable across machines | no — the path must exist | yes, Docker recreates it |
| Performance on Docker Desktop | slower (virtiofs share) | native VM filesystem speed |
| Best for | source code, config you edit | database files, uploads, state |

The rule of thumb I took from this: **bind mount what you edit, named-volume what the
application writes.** The frontend's HTML and nginx config are bind mounts because I change
them; MySQL's data directory is a named volume because MySQL owns it, it needs to persist, and
on macOS a bind mount there would also be measurably slower.

### Compose commands used

| Command | What it does |
|---|---|
| `docker compose up -d` | build if needed, create networks/volumes, start in background |
| `docker compose ps` | status of this project's services |
| `docker compose logs -f backend` | follow one service's logs |
| `docker compose exec database mysql ...` | run a command in a running service |
| `docker compose down` | remove containers and networks, **keep** volumes |
| `docker compose down -v` | the above, **and delete** named volumes |
| `docker compose up -d --build` | force a rebuild of `build:` services |


## Cleanup

```bash
# Tasks 1-3, assembled by hand
docker rm -f frontend backend database apache-host apache-bridge nginx-bind
docker network rm frontend-net backend-net monitoring-net

# the compose stack -- one command, and -v to drop the named volume too
cd compose-stack && docker compose down -v
```
