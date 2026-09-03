# Linux Fundamentals

Every command below was actually run and the real output is pasted in. The lab is an
`ubuntu:24.04` container (hostname `ubuntu-lab`) on Docker Desktop, because the host machine
is macOS and these are Linux-specific behaviours — `journalctl` and `adduser` do not exist on
macOS at all.

```bash
docker run -d --name ubuntu-lab --hostname ubuntu-lab ubuntu:24.04 sleep infinity
docker exec -it ubuntu-lab bash
```

## Task 1 — Soft links vs hard links

### The idea

A filename in Linux is not the file. A directory entry maps a *name* to an **inode**, and the
inode is what actually owns the metadata and the data blocks. Both link types exploit that
indirection, in different places:

- **Hard link** — a second directory entry pointing at the *same inode*. There is no
  "original" and no "copy"; both names are equal peers. The inode's link count goes up, and
  the data is only freed when that count reaches zero.
- **Soft (symbolic) link** — a small separate file, with its own inode, whose *contents* are
  a path string. Resolving it is a second lookup. If the target disappears, the link remains
  and points at nothing.

| | Hard link | Soft link |
|---|---|---|
| What it stores | the same inode | a path, as text |
| Own inode? | no — shares the target's | yes |
| Bumps the target's link count | yes | no |
| Survives deleting the original name | yes, data stays reachable | no, becomes dangling |
| Works across filesystems | no | yes |
| Can point at a directory | no | yes |
| `ls -l` first column | `-` (regular file) | `l`, and shows `-> target` |

### Creating both

```bash
echo "line one" > notes.txt
ln    notes.txt notes-hard.txt      # hard link
ln -s notes.txt notes-soft.txt      # soft link -- note the -s
ls -li                              # -i prints inode numbers
```

```
3512197 -rw-r--r-- 2 root root 9 Sep  3 17:03 notes-hard.txt
3512200 lrwxrwxrwx 1 root root 9 Sep  3 17:03 notes-soft.txt -> notes.txt
3512197 -rw-r--r-- 2 root root 9 Sep  3 17:03 notes.txt
```

Three things to read off that output:

- `notes.txt` and `notes-hard.txt` share inode **3512197**. They are the same file.
- Their link count is **2** (the column after the permissions). `notes-soft.txt` has its own
  inode **3512200** and a count of 1.
- The soft link's type character is `l` and its size is 9 bytes — exactly the length of the
  string `notes.txt`. It literally stores the path.

```bash
stat -c "%n  inode=%i  links=%h  size=%s  type=%F" notes.txt notes-hard.txt notes-soft.txt
```

```
notes.txt  inode=3512197  links=2  size=9  type=regular file
notes-hard.txt  inode=3512197  links=2  size=9  type=regular file
notes-soft.txt  inode=3512200  links=1  size=9  type=symbolic link
```

### Writing through either link

```bash
echo "line two (written through the hard link)" >> notes-hard.txt
echo "line three (written through the soft link)" >> notes-soft.txt
cat notes.txt
```

```
line one
line two (written through the hard link)
line three (written through the soft link)
```

Both writes land in the same file. While both links resolve, they are interchangeable for
reading and writing — the difference only shows up when the target is removed.

### Deleting the original — the part that matters

```bash
rm notes.txt
ls -li
```

```
3512197 -rw-r--r-- 1 root root 93 Sep  3 17:03 notes-hard.txt
3512200 lrwxrwxrwx 1 root root  9 Sep  3 17:03 notes-soft.txt -> notes.txt
```

The hard link still has all the data:

```bash
$ cat notes-hard.txt
line one
line two (written through the hard link)
line three (written through the soft link)

$ stat -c "%n links=%h" notes-hard.txt
notes-hard.txt links=1
```

The link count dropped from 2 to 1. `rm` did not delete a file — it removed a *name* and
decremented the count. The data survives because one name still refers to the inode.

The soft link is now broken:

```bash
$ cat notes-soft.txt
cat: notes-soft.txt: No such file or directory

$ readlink notes-soft.txt
notes.txt

$ test -e notes-soft.txt && echo exists || echo "target does NOT exist (broken symlink)"
target does NOT exist (broken symlink)
```

The link itself is intact — `readlink` still reports `notes.txt`, and `ls` still lists it.
What is gone is the thing at the end of the path. This is why a dangling symlink is
confusing in practice: the link is visibly there, and only following it fails.

### The two hard-link restrictions

```bash
$ ln /root/linkdemo/notes-hard.txt /dev/shm/hard-across
ln: failed to create hard link '/dev/shm/hard-across' => '/root/linkdemo/notes-hard.txt': Invalid cross-device link

$ ln -s /root/linkdemo/notes-hard.txt /dev/shm/soft-across
soft link across filesystems: OK
```

```bash
$ ln /root/linkdemo/adir /root/linkdemo/dir-hard
ln: /root/linkdemo/adir: hard link not allowed for directory

$ ln -s /root/linkdemo/adir /root/linkdemo/dir-soft
soft link to a directory: OK
```

Both errors follow from the mechanism, not from an arbitrary rule:

- **`Invalid cross-device link`** — inode numbers are only unique *within* a filesystem.
  A hard link is an inode reference, so it cannot point outside its own filesystem. A soft
  link stores a path, and paths are global, so it can point anywhere.
- **`hard link not allowed for directory`** — hard-linking directories would let you build
  a cycle in the directory tree, and tools that walk it (`find`, `rm -r`) would loop forever.
  The kernel forbids it. `.` and `..` are the kernel's own exceptions.

### Removing links

```bash
$ unlink notes-soft.txt      # or just rm; unlink is the single-file form
```

`unlink` is the syscall name, and `rm` is a wrapper around it. Removing a link never touches
the target — for a soft link you remove the pointer, for a hard link you decrement a count.

### Interview answer, condensed

> A hard link is another name for the same inode, so the file has two equal names and the
> data lives until the last one is removed. A soft link is a small file containing a path,
> resolved at access time, so it can cross filesystems and point at directories, but it
> breaks if the target moves or is deleted. Use a soft link by default — it is visible,
> flexible, and its failure is obvious. Use a hard link when you need the data to survive
> deletion of the original name, and when everything is on one filesystem.

## Task 2 — `useradd` vs `adduser`

They are not two implementations of the same thing — one is a layer on top of the other.

```bash
$ which adduser
/usr/sbin/adduser

$ head -1 /usr/sbin/adduser
#! /usr/bin/perl
```

`adduser` is a **Perl script** shipped by Debian/Ubuntu that calls `useradd` underneath.
`useradd` is the low-level binary from `shadow-utils`, and it does exactly what its flags say
and nothing else.

> The stock `ubuntu:24.04` image does not include `adduser` — it had to be installed with
> `apt-get install adduser` first. Worth knowing when writing Dockerfiles: inside a container
> `useradd` is usually the only one available, which is one reason it is the right choice
> there.

### `useradd`, run properly

```bash
$ useradd -m -s /bin/bash devuser1
$ id devuser1
uid=1001(devuser1) gid=1001(devuser1) groups=1001(devuser1)

$ grep devuser1 /etc/passwd
devuser1:x:1001:1001::/home/devuser1:/bin/bash

$ ls -la /home/devuser1
-rw-r--r-- 1 devuser1 devuser1  220 Mar 31  2024 .bash_logout
-rw-r--r-- 1 devuser1 devuser1 3771 Mar 31  2024 .bashrc
-rw-r--r-- 1 devuser1 devuser1  807 Mar 31  2024 .profile
```

Note the empty GECOS field (the `::`) and that the password field in `/etc/shadow` is `!` —
the account is locked, with no password set.

### `useradd` with no flags — the trap

```bash
$ useradd devuser3
$ grep devuser3 /etc/passwd
devuser3:x:1003:1003::/home/devuser3:/bin/sh

$ ls -d /home/devuser3
ls: cannot access '/home/devuser3': No such file or directory
```

This is the failure mode to remember. `/etc/passwd` **claims** the home directory is
`/home/devuser3`, but `-m` was not passed, so it was never created. The user can log in and
lands in a directory that does not exist. The shell also defaulted to `/bin/sh`, not bash.
Nothing errors — you just get a subtly broken account.

### `adduser`

```bash
$ adduser --disabled-password --gecos "Dev User Two" devuser2
info: Adding user `devuser2' ...
info: Selecting UID/GID from range 1000 to 59999 ...
info: Adding new group `devuser2' (1002) ...
info: Adding new user `devuser2' (1002) with group `devuser2 (1002)' ...
info: Creating home directory `/home/devuser2' ...
info: Copying files from `/etc/skel' ...
info: Adding new user `devuser2' to supplemental / extra groups `users' ...
info: Adding user `devuser2' to group `users' ...
```

It narrates every step, and each one is a thing `useradd` would have needed a flag for. It
also added the user to the extra `users` group, which `useradd` did not:

```bash
$ id devuser2
uid=1002(devuser2) gid=1002(devuser2) groups=1002(devuser2),100(users)

$ grep devuser2 /etc/passwd
devuser2:x:1002:1002:Dev User Two,,,:/home/devuser2:/bin/bash
```

The GECOS field now holds `Dev User Two,,,`. `--disabled-password` and `--gecos` were passed
only to keep the run non-interactive; without them `adduser` prompts for a password and the
full-name fields.

### Side by side

```
USER       UID    HOME                   SHELL        GROUPS
devuser1   1001   /home/devuser1         /bin/bash    devuser1
devuser2   1002   /home/devuser2         /bin/bash    devuser2,users
devuser3   1003   /home/devuser3         /bin/sh      devuser3      <- home does not exist
```

### Which one on Ubuntu?

**`adduser` for interactive admin work.** It follows Debian policy, leaves the account
usable in one step, and there is no flag to forget. This is the one to reach for at a
terminal.

**`useradd` in scripts, Dockerfiles and anything portable.** It never prompts, so it cannot
hang a CI job, and it exists on every Linux distribution — `adduser` is Debian-family only
(on RHEL, `adduser` is just a symlink to `useradd`, which behaves differently again). The
price is that you must spell out `-m` and `-s` yourself.

Cleanup: `userdel -r devuser1` / `deluser --remove-home devuser2`. The `-r` and
`--remove-home` matter — without them the home directory is orphaned on disk.

## Task 3 — `journalctl`

`journalctl` reads the binary log that `systemd-journald` maintains. Instead of grepping
`/var/log/*.log` and hoping the format is consistent, the journal is structured: every entry
carries indexed metadata (unit, PID, priority, boot ID, timestamp), so you filter on fields
instead of parsing text.

### Getting a real systemd to test against

A normal container has no init system, so there is no journal to read. To do this task
honestly I built a small image with systemd and cron and ran systemd as PID 1:

```dockerfile
FROM ubuntu:24.04
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv cron && apt-get clean
CMD ["/usr/lib/systemd/systemd"]
```

```bash
docker run -d --name systemd-lab --hostname ubuntu-lab --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw hw-systemd
```

`--privileged`, the host cgroup namespace and the cgroup mount are all required — systemd
needs to manage cgroups, which a default container is not allowed to do.

```bash
$ systemctl is-system-running
running
$ ps -p 1 -o comm=
systemd
```

### Reading a specific service's log

```bash
$ systemctl restart cron
$ systemctl --no-pager --lines=0 status cron
● cron.service - Regular background program processing daemon
     Loaded: loaded (/usr/lib/systemd/system/cron.service; enabled; preset: enabled)
     Active: active (running) since Thu 2026-09-03 17:05:08 UTC; 3ms ago
       Docs: man:cron(8)
   Main PID: 109 (cron)
      Tasks: 1 (limit: 9520)
```

```bash
$ journalctl --no-pager -u cron
Sep 03 17:04:57 ubuntu-lab systemd[1]: Started cron.service - Regular background program processing daemon.
Sep 03 17:04:57 ubuntu-lab cron[79]: (CRON) INFO (pidfile fd = 3)
Sep 03 17:04:57 ubuntu-lab cron[79]: (CRON) INFO (Running @reboot jobs)
Sep 03 17:05:08 ubuntu-lab systemd[1]: Stopping cron.service - Regular background program processing daemon...
Sep 03 17:05:08 ubuntu-lab systemd[1]: cron.service: Deactivated successfully.
Sep 03 17:05:08 ubuntu-lab systemd[1]: Stopped cron.service - Regular background program processing daemon.
Sep 03 17:05:08 ubuntu-lab systemd[1]: Started cron.service - Regular background program processing daemon.
Sep 03 17:05:08 ubuntu-lab cron[109]: (CRON) INFO (pidfile fd = 3)
Sep 03 17:05:08 ubuntu-lab cron[109]: (CRON) INFO (Skipping @reboot jobs -- not system startup)
```

The `-u cron` filter interleaves two sources: `systemd[1]` lifecycle messages and cron's own
`cron[109]` output. That combination is the main reason to use `journalctl` over a log file —
you see the service's own logging *and* what the init system did to it, in one ordered
stream. The stop/start pair from the restart is visible, and the PID changes from 79 to 109.

Also note the last line: `Skipping @reboot jobs -- not system startup`, versus
`Running @reboot jobs` on the first start. Cron correctly distinguished a restart from a
boot.

### The filters worth knowing

```bash
$ journalctl --no-pager -p err -b
-- No entries --
```

Priority `err` or worse for this boot: nothing had failed. **`-- No entries --` is a useful
result, not a broken command** — it is the fastest way to answer "did anything go wrong?".

```bash
$ journalctl --no-pager --since "2 minutes ago" -n 3
Sep 03 17:05:08 ubuntu-lab cron[109]: (CRON) INFO (pidfile fd = 3)
Sep 03 17:05:08 ubuntu-lab cron[109]: (CRON) INFO (Skipping @reboot jobs -- not system startup)
```

`--since` takes plain English (`"2 minutes ago"`, `today`, `yesterday`) as well as timestamps.

```bash
$ journalctl --no-pager -u cron -n 1 -o json-pretty
{
	"_MACHINE_ID" : "3753eaca1c4d4ec8a147ed65f136062a",
	"_EXE" : "/usr/sbin/cron",
	"_COMM" : "(cron)",
	"_HOSTNAME" : "ubuntu-lab",
	"SYSLOG_FACILITY" : "9",
	"PRIORITY" : "6",
	"SYSLOG_IDENTIFIER" : "cron",
	"_SYSTEMD_CGROUP" : "/system.slice/cron.service",
	"_TRANSPORT" : "syslog",
	...
}
```

This is what "structured log" actually means. The human-readable line is one field
(`MESSAGE`); everything else is indexed metadata. Every filter flag is just a query against
one of these fields — `-u` matches `_SYSTEMD_UNIT`, `-p` matches `PRIORITY`. Once that clicks,
the flags stop needing memorisation, and `-o json` becomes the way to pipe the journal into
`jq` or a log shipper.

```bash
$ journalctl --no-pager --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
  0 9d53d9def78c4a38a200bd2a73108c97 Thu 2026-09-03 17:04:57 UTC Thu 2026-09-03 17:05:08 UTC

$ journalctl --disk-usage
Archived and active journals take up 8.0M in the file system.
```

`--list-boots` indexes boots so you can ask for the previous one with `-b -1` — the standard
move when investigating a crash, since the interesting logs are in the boot that ended.

One quirk of doing this in a container:

```bash
$ journalctl --no-pager -k -n 3
Sep 03 17:04:57 ubuntu-lab kernel: docker0: port 4(vethd40d13c) entered forwarding state
```

`-k` shows *kernel* messages, and a container shares the host's kernel — so this is the Docker
Desktop VM's kernel talking about the veth interface created for this very container. The
journal is the container's, but the kernel underneath is not.

### Reference

| Command | What it gives you |
|---|---|
| `journalctl -u nginx` | one unit's log |
| `journalctl -u nginx -f` | follow it live, like `tail -f` |
| `journalctl -b` / `-b -1` | this boot / the previous boot |
| `journalctl -n 50` | last 50 entries |
| `journalctl -p err` | priority err and worse |
| `journalctl --since "1 hour ago"` | time window; pairs with `--until` |
| `journalctl -k` | kernel ring buffer |
| `journalctl -o json` | structured output for `jq` |
| `journalctl --no-pager` | plain output, for scripts |
| `journalctl --disk-usage` | how much disk the journal holds |
| `journalctl --vacuum-time=7d` | delete entries older than 7 days |

`--no-pager` is the one that saves the most time in practice — without it, output goes to
`less` and hangs any non-interactive script.

## Task 4 — Command cheat sheet

Grouped by the question I am trying to answer, with a practice session at the end.

**Where am I / what is here**

| Command | Notes |
|---|---|
| `pwd` | print working directory |
| `ls -la` | long listing, includes dotfiles |
| `cd -` | jump back to the previous directory |
| `tree -L 2` | directory tree, two levels deep |
| `find . -name "*.log"` | search by name; add `-type f`, `-mtime -1` |
| `du -sh *` | size of each entry here |
| `df -h` | free space per filesystem |

**Creating, copying, removing**

| Command | Notes |
|---|---|
| `mkdir -p a/b/c` | whole nested path in one call |
| `touch file` | create empty, or bump the timestamp |
| `cp -r src dst` | `-r` for directories |
| `mv old new` | move *and* rename — same operation |
| `rm -rf dir` | recursive, no prompting; check `pwd` first |
| `ln -s target link` | symlink (Task 1) |

**Reading files**

| Command | Notes |
|---|---|
| `cat file` | whole file |
| `less file` | page through; `/` search, `q` quit |
| `head -n 5` / `tail -n 5` | first / last lines |
| `tail -f log` | follow a growing file |
| `grep -rn "text" .` | recursive, with line numbers |
| `wc -l file` | count lines |
| `sort`, `uniq -c`, `cut -d: -f1` | the pipeline workhorses |

**Permissions and ownership**

| Command | Notes |
|---|---|
| `chmod 640 file` | owner rw, group r, others none |
| `chmod +x script.sh` | make executable |
| `chown user:group file` | change owner and group |
| `umask` | default mask for new files |
| `stat file` | inode, links, exact permissions |

**Users and identity**

| Command | Notes |
|---|---|
| `whoami` / `id` | who am I, uid and groups |
| `useradd -m -s /bin/bash u` | create a user (Task 2) |
| `passwd u` | set a password |
| `su - u` | switch user, login shell |
| `sudo -u u cmd` | run one command as someone else |

**Processes and resources**

| Command | Notes |
|---|---|
| `ps aux` | every process; pipe into `grep` |
| `top` / `htop` | live view |
| `kill -15 PID` | ask it to exit; `-9` to force |
| `free -h` | memory |
| `uname -a` | kernel and architecture |
| `uptime` | load averages |

**Networking** — see [`../03-networking-fundamentals/`](../03-networking-fundamentals/)

| Command | Notes |
|---|---|
| `ip a` / `ip route` | interfaces / routing table |
| `ss -tulpn` | listening sockets and their processes |
| `ping -c 4 host` | reachability |
| `curl -I url` | headers only |

**Services and logs**

| Command | Notes |
|---|---|
| `systemctl status unit` | is it running |
| `systemctl restart unit` | restart it |
| `systemctl enable --now unit` | start now, and at boot |
| `journalctl -u unit -f` | follow its log (Task 3) |

**Packages and archives**

| Command | Notes |
|---|---|
| `apt update && apt install pkg` | Debian/Ubuntu |
| `tar -czf out.tgz dir` | create a gzip tarball |
| `tar -xzf out.tgz` | extract it |
| `tar -tzf out.tgz` | list contents without extracting |
| `man cmd` / `cmd --help` | the built-in documentation |
| `history \| grep ssh` | find that command you ran last week |

### Practice session

```bash
$ mkdir -p a/b/c && find a -type d
a a/b a/b/c

$ find . -name "*.log"
./logs/app.log

$ grep -rn "ERROR" .
./logs/app.log:1:ERROR disk full
./logs/app.log:3:ERROR timeout

$ grep -c ERROR logs/app.log
2
$ wc -l < logs/app.log
4
```

`grep -c` counts *matching lines* (2) while `wc -l` counts all lines (4) — an easy pair to
confuse when writing a quick log check.

```bash
$ chmod 640 report.txt; chmod +x notes.md
$ stat -c "%n  %A  %a  owner=%U:%G" report.txt notes.md
report.txt  -rw-r-----  640  owner=root:root
notes.md  -rwxr-xr-x  755  owner=root:root

$ umask
0022
```

`chmod +x` produced **755**, not 700 — `+x` adds the execute bit for everyone, because the
file was already 644 from the default `umask` of `0022`. `umask` subtracts from 666 for files
and 777 for directories, which is where 644 and 755 come from.

```bash
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
overlay         911G  258G  607G  30% /

$ free -h
               total        used        free      shared  buff/cache   available
Mem:           7.7Gi       1.3Gi       111Mi       1.3Mi       6.5Gi       6.4Gi

$ uname -a
Linux ubuntu-lab 6.12.76-linuxkit #1 SMP Wed May 13 14:27:18 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux

$ uptime
 17:05:28 up 14 min,  0 user,  load average: 2.06, 1.56, 0.84
```

Two container details visible here. The root filesystem is `overlay` — Docker's layered
filesystem, not a real disk. And the kernel is `linuxkit`, the Docker Desktop VM's kernel,
confirming the container is not running on macOS directly.

Reading `free -h` correctly: `free` shows 111 Mi, which looks alarming, but `available`
is 6.4 Gi. The difference is `buff/cache` — 6.5 Gi of page cache that Linux hands back on
demand. **`available` is the number that matters**; low `free` on a healthy Linux box is
normal, not a problem.

```bash
$ ps aux | head -2
USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root           1  0.0  0.0   2272  1224 ?        Ss   17:03   0:00 sleep infinity
```

PID 1 is `sleep infinity`, not `init`. In `ubuntu-lab` there is no init system at all — which
is exactly why Task 3 needed a separate container with systemd as PID 1.

```bash
$ tar -czf logs.tgz logs && du -h logs.tgz
4.0K    logs.tgz
$ tar -tzf logs.tgz
logs/
logs/app.log
```

## Takeaways

- **`rm` removes names, not files.** The inode and its data go when the last link is gone.
  Task 1 makes this concrete, and it explains why a running process can keep a deleted file's
  disk space occupied.
- **`useradd` without `-m` produces a broken account silently** — `/etc/passwd` promises a
  home directory that does not exist. `adduser` cannot make that mistake.
- **The journal is a database, not a text file.** Once `-o json-pretty` shows the fields, the
  filter flags become obvious rather than memorised.
- **Read `available`, not `free`.** Cached memory is not used memory.
- **Container-specific detail leaks into every command** — `overlay` in `df`, `linuxkit` in
  `uname`, `sleep infinity` as PID 1, the host's veth in `journalctl -k`. Useful for knowing
  when you are looking at the container and when you are looking through it.
