# Networking Fundamentals

Every command was run and the real output is pasted below, with what I understood from each.
Two vantage points are used deliberately:

- **`ubuntu-lab`** — an `ubuntu:24.04` container, for the Linux tooling (`ip`, `ss`,
  `traceroute`, `dig`).
- **the macOS host itself** — for comparison, because the two give visibly different answers
  and the difference is instructive.

```bash
docker exec ubuntu-lab bash -c \
  'apt-get install -y iproute2 iputils-ping dnsutils curl wget traceroute net-tools ipcalc'
```

## Part 1 — IP addressing and subnetting

The course notes cover address classes and subnet masks. Rather than redo the arithmetic by
hand, I checked each example with `ipcalc`, which prints the network, the usable host range
and the broadcast address.

### Address classes

| Class | First octet | Default mask | Network / host bits | Usable hosts |
|---|---|---|---|---|
| A | 1–126 | 255.0.0.0 (`/8`) | 8 / 24 | 2²⁴ − 2 = 16,777,214 |
| B | 128–191 | 255.255.0.0 (`/16`) | 16 / 16 | 2¹⁶ − 2 = 65,534 |
| C | 192–223 | 255.255.255.0 (`/24`) | 24 / 8 | 2⁸ − 2 = 254 |
| D | 224–239 | — | multicast | — |
| E | 240–255 | — | experimental | — |

The `− 2` is the network address itself (all host bits 0) and the broadcast address (all host
bits 1). Neither can be assigned to a machine. `127.0.0.0/8` is loopback, which is why class A
stops at 126.

Private ranges (RFC 1918) — not routable on the public internet:

| Range | CIDR | Class |
|---|---|---|
| 10.0.0.0 – 10.255.255.255 | `10.0.0.0/8` | A |
| 172.16.0.0 – 172.31.255.255 | `172.16.0.0/12` | B |
| 192.168.0.0 – 192.168.255.255 | `192.168.0.0/16` | C |

### Worked examples, verified

**Class C, `/24`** — the example from the notes:

```
$ ipcalc -n -b 197.23.45.10/24
Address:   197.23.45.10
Netmask:   255.255.255.0 = 24
Wildcard:  0.0.0.255
=>
Network:   197.23.45.0/24
HostMin:   197.23.45.1
HostMax:   197.23.45.254
Broadcast: 197.23.45.255
Hosts/Net: 254                   Class C
```

24 network bits, 8 host bits, so 2⁸ − 2 = **254** usable hosts, and the broadcast address is
**197.23.45.255**.

**Class A, `/8`**:

```
$ ipcalc -n -b 120.27.1.0/8
Address:   120.27.1.0
Netmask:   255.0.0.0 = 8
Wildcard:  0.255.255.255
=>
Network:   120.0.0.0/8
HostMin:   120.0.0.1
HostMax:   120.255.255.254
Broadcast: 120.255.255.255
Hosts/Net: 16777214              Class A
```

Note that the **network address is `120.0.0.0`, not `120.27.1.0`**. With a `/8` mask only the
first octet is the network part, so the `.27.1` is host bits and gets zeroed. This is the part
of subnetting that catches people out: the address you were given is not necessarily the
network it belongs to.

**A non-classful mask** — the actual LAN this MacBook is on:

```
$ ipcalc -n -b 172.20.2.7/21
Address:   172.20.2.7
Netmask:   255.255.248.0 = 21
Wildcard:  0.0.7.255
=>
Network:   172.20.0.0/21
HostMin:   172.20.0.1
HostMax:   172.20.7.254
Broadcast: 172.20.7.255
Hosts/Net: 2046                   Class B, Private Internet
```

`/21` is 3 bits borrowed from the third octet, giving 2¹¹ − 2 = **2046** hosts and a range
that spans `172.20.0.x` to `172.20.7.x`. Real networks are sized like this — CIDR replaced
strict classes precisely so a network could be any power of two rather than 254 or 65,534
with nothing in between.

**How to do it without a tool:** the mask `/21` leaves 32 − 21 = 11 host bits. The block size
in the third octet is 2^(24−21) = 8, so networks start at .0, .8, .16… and `172.20.2.7` falls
in the block starting at `172.20.0.0`, which ends at `172.20.7.255`.

## Part 2 — The commands

### `ip a` — interfaces and their addresses

```bash
$ ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
...
11: eth0@if76: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65535 qdisc noqueue state UP group default
    link/ether 5e:ba:9e:1f:86:fb brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 172.17.0.4/16 brd 172.17.255.255 scope global eth0
       valid_lft forever preferred_lft forever
```

`ip a` (short for `ip address show`) is the modern replacement for `ifconfig`. What I read off
this:

- **`eth0` has `172.17.0.4/16`** — a private class B address on Docker's default bridge. The
  `/16` and the broadcast `172.17.255.255` match the `ipcalc` maths above.
- **`eth0@if76`** — the `@if76` says this is one end of a veth pair, and its peer is interface
  index 76 in another namespace (on the host side of the bridge). This is exactly how Docker
  wires a container's network: a virtual cable with one end in the container and one on the
  bridge.
- **`<BROADCAST,MULTICAST,UP,LOWER_UP>`** — `UP` is the admin state (someone enabled it),
  `LOWER_UP` is the physical/carrier state. Both present means the link is genuinely usable.
  `UP` without `LOWER_UP` is the signature of a cable-unplugged problem.
- **`mtu 65535`** on eth0 is unusually large — a virtual link with no physical Ethernet
  frame limit. A real NIC would show 1500.
- The `lo` interface is `127.0.0.1/8`, `scope host` — traffic to it never leaves the machine.
- The remaining interfaces (`tunl0`, `gre0`, `sit0`, `ip6tnl0`…) are all `state DOWN`. They
  are tunnel-driver placeholders the kernel registers when the modules load, not real
  interfaces.

`ip -br a` gives the same thing in one line each, which is what I would actually use:

```bash
$ ip -br a
lo               UNKNOWN        127.0.0.1/8 ::1/128
eth0@if76        UP             172.17.0.4/16
```

### `ip route` — where packets go

```bash
$ ip route
default via 172.17.0.1 dev eth0
172.17.0.0/16 dev eth0 proto kernel scope link src 172.17.0.4
```

Two rules, and this is the whole decision process:

1. **`172.17.0.0/16 dev eth0 scope link`** — anything in this subnet is a direct neighbour.
   Send the frame straight out `eth0`, no router involved. `proto kernel` means the kernel
   added this automatically when the address was configured.
2. **`default via 172.17.0.1`** — everything else goes to the gateway at `172.17.0.1`, which
   is Docker's bridge.

Most connectivity problems are one of these two lines being wrong or missing. A machine with
an address but no default route can reach its own subnet and nothing else — which looks like
"DNS is broken" but is not.

For comparison, the macOS host:

```bash
$ route -n get default
    gateway: 172.20.0.1
  interface: en0
```

Same structure, different syntax — BSD `route` instead of `iproute2`.

### `ping` — is it reachable, and how far away

```bash
$ ping -c 4 google.com
PING google.com (142.250.66.14) 56(84) bytes of data.
64 bytes from pnmaaa-ap-in-f14.1e100.net (142.250.66.14): icmp_seq=1 ttl=63 time=111 ms
64 bytes from pnmaaa-ap-in-f14.1e100.net (142.250.66.14): icmp_seq=2 ttl=63 time=24.3 ms
64 bytes from pnmaaa-ap-in-f14.1e100.net (142.250.66.14): icmp_seq=3 ttl=63 time=27.2 ms
64 bytes from pnmaaa-ap-in-f14.1e100.net (142.250.66.14): icmp_seq=4 ttl=63 time=16.6 ms

--- google.com ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3011ms
rtt min/avg/max/mdev = 16.627/44.681/110.646/38.278 ms
```

`ping` sends ICMP echo requests. It proves three things at once: DNS resolved the name, a
route exists, and the target answered.

- **The first packet took 111 ms and the rest 16–27 ms.** That is not a slow network — it is
  the ARP/route lookup and connection setup happening once. Always judge latency on the
  steady-state packets, not the first.
- **`mdev = 38.278`** is the mean deviation, i.e. jitter. It is high here only because of that
  first outlier. For voice or video, jitter matters more than average latency.
- **`ttl=63`** is the useful field. TTL starts at a round number (64 on Linux) and each router
  decrements it by one. 63 means **one hop** away — from the container's point of view, the
  whole internet is one hop, because the Docker VM NATs everything.
- **`0% packet loss`** is the headline. Intermittent loss with good average latency is a
  worse symptom than uniformly high latency.

Pinging the gateway directly separates local from upstream problems:

```bash
$ ping -c 2 172.17.0.1
2 packets transmitted, 2 received, 0% packet loss, time 1044ms
rtt min/avg/max/mdev = 0.119/0.142/0.166/0.023 ms
```

0.14 ms versus 44 ms. If the gateway answers and the internet does not, the fault is upstream,
not local.

### `nslookup` and `dig` — DNS

```bash
$ nslookup github.com
Server:		192.168.65.7
Address:	192.168.65.7#53

Non-authoritative answer:
Name:	github.com
Address: 20.207.73.82
```

- **`Server: 192.168.65.7`** is the resolver being asked — Docker Desktop's internal DNS,
  not a public one.
- **"Non-authoritative answer"** means this came from the resolver's cache or by recursion,
  not from GitHub's own nameservers. Normal; it only matters when you are debugging a record
  you just changed and are being served a stale cached copy.
- **`20.207.73.82`** is a GitHub address in Azure's India region — DNS returned a
  geographically local answer, which is CDN/GeoDNS behaviour.

`dig` gives more control and a more precise answer:

```bash
$ dig +short github.com
20.207.73.82

$ dig github.com A +noall +answer +stats
github.com.		44	IN	A	20.207.73.82
;; Query time: 2 msec
;; SERVER: 192.168.65.7#53(192.168.65.7) (UDP)
;; WHEN: Thu Sep 03 17:09:55 UTC 2026
;; MSG SIZE  rcvd: 54
```

The record reads: name `github.com.` (with the trailing dot — the DNS root), **TTL 44 s**,
class `IN`, type `A`, value `20.207.73.82`. The TTL of 44 is the remaining cache lifetime, so
this answer was already cached and will be re-fetched in 44 seconds. `Query time: 2 msec`
confirms a cache hit rather than a full recursive lookup.

`+short` for scripts, `+noall +answer` for reading, and `dig @8.8.8.8 name` to bypass the local
resolver — that last one is the quickest way to tell "DNS is broken" from "my resolver is
broken".

Where the resolver comes from:

```bash
$ cat /etc/resolv.conf
# Generated by Docker Engine.
nameserver 192.168.65.7
```

Docker writes this file into the container. That is why containers resolve each other by
name — the embedded DNS server intercepts those lookups (as demonstrated in
[`../07-docker-networking-volumes/`](../07-docker-networking-volumes/)).

### `curl` — speaking HTTP

```bash
$ curl -sI https://github.com
HTTP/2 200
date: Thu, 03 Sep 2026 17:09:55 GMT
content-type: text/html; charset=utf-8
etag: W/"2657706fb1bfc4dc7ec59af21142674f"
cache-control: max-age=0, private, must-revalidate
strict-transport-security: max-age=31536000; includeSubdomains; preload
x-frame-options: deny
x-content-type-options: nosniff
```

`-I` sends `HEAD`, so you get headers without the body — the fastest way to check whether a
service is alive and what it says about itself. `HTTP/2`, HSTS, `x-frame-options: deny` and
`nosniff` are all visible without downloading a byte of HTML.

The flag I found most useful is `-w`, which reports where the time actually went:

```bash
$ curl -s -o /dev/null -w 'dns=%{time_namelookup}s tcp=%{time_connect}s tls=%{time_appconnect}s ttfb=%{time_starttransfer}s total=%{time_total}s ip=%{remote_ip} http=%{http_code}\n' https://github.com
dns=0.001725s tcp=0.029674s tls=0.060849s ttfb=0.119380s total=0.239419s ip=20.207.73.82 http=200
```

These are cumulative, so the phases are the differences:

| Phase | Time | What happened |
|---|---|---|
| DNS | 1.7 ms | cached, as `dig` predicted |
| TCP connect | 28 ms | the three-way handshake — one round trip |
| TLS handshake | 31 ms | certificate exchange — roughly another round trip |
| Server think time | 59 ms | request sent to first byte back |
| Body transfer | 120 ms | the rest of the page |

This turns "the site is slow" into a specific answer. Slow DNS, slow TLS and a slow
application are three different problems with three different owners, and this one command
tells them apart.

### `wget` — downloading files

```bash
$ wget https://github.com/robots.txt
HTTP request sent, awaiting response... 200 OK
Length: 2274 (2.2K) [text/plain]
Saving to: 'robots.txt'

     0K ..                                                    100%  192M=0s

2026-09-03 17:10:03 (192 MB/s) - 'robots.txt' saved [2274/2274]

$ ls -l robots.txt
-rw-r--r-- 1 root root 2274 Sep  3 16:18 robots.txt
```

`wget` saves to a file by default and shows a progress bar; `curl` prints to stdout by
default. That is the practical difference — `wget` for fetching files (and `-r` for
recursive mirroring, which curl cannot do), `curl` for inspecting and scripting against APIs.

The "192 MB/s" is not real network throughput — the file is 2.2 KB and finished inside one
round trip, so the figure is measurement noise. Small transfers cannot measure bandwidth.

Note the saved file's timestamp (16:18) is earlier than the download time (17:10): `wget`
preserves the server's `Last-Modified` date by default.

### `ss` — sockets

```bash
$ ss -tulpn
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process
tcp   LISTEN 0      1            0.0.0.0:8000      0.0.0.0:*    users:(("nc",pid=3299,fd=3))
tcp   LISTEN 0      1            0.0.0.0:9000      0.0.0.0:*    users:(("nc",pid=3300,fd=3))
```

The flags: `-t` TCP, `-u` UDP, `-l` listening, `-p` the owning process, `-n` numeric (do not
resolve port 22 to "ssh"). `ss -tulpn` is the one to memorise — it answers "what is listening
on this machine, and which process owns it".

**`0.0.0.0:8000` means all interfaces.** If it said `127.0.0.1:8000` the service would be
unreachable from outside, which is the exact bug described in
[`../05-docker-fundamentals/`](../05-docker-fundamentals/) — the bind address is visible right
here, before you start testing from another machine.

`ss` replaced `netstat`; it reads `/proc/net/*` and the kernel's socket diagnostics directly,
so it is much faster on a busy host.

Established connections instead of listeners:

```bash
$ ss -tn state established
Recv-Q Send-Q Local Address:Port  Peer Address:Port
0      0         172.17.0.4:35548 20.207.73.82:443
```

The full picture of one connection: local `172.17.0.4:35548` (an ephemeral source port) to
`20.207.73.82:443` — the GitHub address DNS gave us, on HTTPS. `Recv-Q`/`Send-Q` at 0 means
nothing is backed up; a persistently non-zero `Send-Q` means the peer is not reading fast
enough.

**A false alarm worth recording:** my first `ss -tulpn` printed only the header row. I assumed
`ss` was broken in the container. It was not — nothing was listening, because the
`python3 -m http.server` I had tried to start did not exist (`python3` is not in the base
image). `ss` was reporting the truth. Empty output from a diagnostic tool is data.

### `netstat -rn` — the legacy view

```bash
$ netstat -rn
Kernel IP routing table
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
0.0.0.0         172.17.0.1      0.0.0.0         UG        0 0          0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U         0 0          0 eth0
```

The same two routes `ip route` showed, in the older format. `0.0.0.0/0.0.0.0` is the default
route, `U` = up, `G` = gateway. Worth being able to read, since `netstat` is what you find on
older systems and in most existing documentation — but `ip route` is the current tool.

### `traceroute` — the path, and a lesson in probe types

The default run failed:

```bash
$ traceroute -m 8 google.com
traceroute to google.com (142.250.66.14), 8 hops max, 60 byte packets
 1  172.17.0.1 (172.17.0.1)  0.016 ms  0.004 ms  0.002 ms
 2  * * *
 3  * * *
 ...
 8  * * *
```

One hop, then nothing. `traceroute` works by sending packets with a deliberately low TTL and
collecting the `ICMP Time Exceeded` replies from each router that drops one. By default on
Linux it sends **UDP** probes to high ports — and those were being discarded silently.

Switching probe type fixed it immediately:

```bash
$ traceroute -I -m 6 -w 2 google.com          # ICMP probes
 1  172.17.0.1 (172.17.0.1)  0.147 ms  3.210 ms  3.213 ms
 2  pnmaaa-ap-in-f14.1e100.net (142.250.66.14)  13.888 ms  13.973 ms  13.852 ms

$ traceroute -T -p 443 -m 6 -w 2 google.com   # TCP SYN to 443
 1  172.17.0.1 (172.17.0.1)  0.445 ms  2.740 ms  2.761 ms
 2  pnmaaa-ap-in-f14.1e100.net (142.250.66.14)  37.342 ms  37.288 ms  37.264 ms
```

**`* * *` does not mean "no route".** It means no ICMP replies came back for that probe type —
usually a firewall or NAT filtering UDP. `-I` (ICMP) and `-T` (TCP SYN) exist for exactly this
reason, and `-T -p 443` is the most likely to survive a hostile network because it looks like
ordinary HTTPS traffic.

### The same traceroute from the macOS host

```bash
$ traceroute -m 10 -q 1 google.com
traceroute to google.com (142.250.66.14), 10 hops max, 40 byte packets
 1  172.20.0.1 (172.20.0.1)  8.737 ms
 2  49.200.242.17 (49.200.242.17)  4.124 ms
 3  128.185.120.53 (128.185.120.53)  8.452 ms
 4  116.119.164.11 (116.119.164.11)  14.809 ms
 5  72.14.197.10 (72.14.197.10)  10.800 ms
 6  142.251.71.193 (142.251.71.193)  19.497 ms
 7  142.251.60.187 (142.251.60.187)  11.389 ms
 8  142.251.60.185 (142.251.60.185)  13.119 ms
 9  172.253.70.167 (172.253.70.167)  17.319 ms
10  pnmaaa-ap-in-f14.1e100.net (142.250.66.14)  14.808 ms
```

**Ten hops from the Mac, two from the container — same destination.** This is the single most
useful thing I learned in this section. The container is not seeing a shorter path; it is
seeing a *hidden* one. Docker Desktop's VM NATs the traffic, so from inside the container the
entire internet appears to be one hop past the bridge. The `ttl=63` in `ping` said the same
thing.

Reading the real path: hop 1 is the local gateway, hop 2 the ISP, hops 5–9 are Google's
network (`72.14.x`, `142.251.x`, `172.253.x` are all Google ranges), and hop 10 is the target.
Latency does not climb monotonically — hop 4 at 14.8 ms is slower than hop 6 at 19.5 ms is
slower than hop 7 at 11.4 ms — because routers deprioritise generating ICMP replies. **A
single slow hop mid-path is usually not the problem;** what matters is a step up that persists
for every hop after it.

The practical consequence: **never debug network paths from inside a container.** You are
measuring the container's view, not the machine's.

### `hostname`

```bash
# in the container
$ hostname       -> ubuntu-lab      # set with --hostname at docker run
$ hostname -i    -> 172.17.0.4      # the address it resolves to
$ hostname -f    -> ubuntu-lab      # FQDN; same, as there is no domain

# on the macOS host
$ hostname       -> MacBook-Pro-4.local
```

The `.local` suffix is mDNS/Bonjour, how macOS advertises itself on a LAN without a DNS
server. `hostname -i` is a quick way to get a machine's own IP in a script, though `ip -br a`
is more reliable when there are several interfaces.

## Part 3 — Something I noticed

The Docker networks I created for
[`../07-docker-networking-volumes/`](../07-docker-networking-volumes/) overlap with this
machine's real LAN:

```
mac en0      : 172.20.2.7/21    -> network 172.20.0.0/21
frontend-net : 172.20.0.0/16
default bridge: 172.17.0.0/16
```

`frontend-net` got `172.20.0.0/16`, which **completely contains** the LAN's
`172.20.0.0/21`. Docker picks bridge subnets from the private `172.16–172.31` range without
knowing what the host's LAN uses, and here it happened to collide.

It caused no problem in these exercises, because containers on `frontend-net` only talked to
each other and to the internet (which is NATed out through a different path). But a container
on that network trying to reach a *real* machine on the office LAN at, say, `172.20.3.50`
would match its own `scope link` route and send the frame to the bridge instead of the
gateway — and the connection would fail with no obvious cause. The fix is to pin the subnet
explicitly:

```bash
docker network create --subnet 10.99.0.0/24 frontend-net
```

I would not have spotted this without running `ipcalc` on both and comparing. Reading the
route table on the host and knowing its mask is what makes the overlap visible.

## Summary

| Command | Answers |
|---|---|
| `ip a` / `ip -br a` | what interfaces exist and their addresses |
| `ip route` | where a packet to a given destination will be sent |
| `ping -c 4 host` | is it reachable, how far (TTL), how stable (loss, mdev) |
| `nslookup` / `dig` | what a name resolves to, from which resolver, cached how long |
| `curl -I` | is the HTTP service alive and what does it advertise |
| `curl -w` | which phase of the request is slow |
| `wget` | download a file, preserving its server timestamp |
| `ss -tulpn` | what is listening, on which address, owned by which process |
| `ss -tn state established` | who am I actually connected to |
| `netstat -rn` | the routing table, legacy format |
| `traceroute -I` / `-T` | the path, when the default UDP probes are filtered |
| `hostname -i` | this machine's own address |
| `ipcalc` | network, host range and broadcast for a CIDR block |

The three things I will actually carry forward:

1. **`ttl=63` and a two-hop traceroute told the same story** — the container's network view is
   NAT-flattened and not the machine's. Diagnose from the host.
2. **`* * *` is about the probe type, not about reachability.** `-I` and `-T -p 443` are the
   fallbacks.
3. **`curl -w` decomposes latency into DNS / TCP / TLS / server / transfer.** One command,
   and "it's slow" becomes a specific, assignable problem.
