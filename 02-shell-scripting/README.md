# Shell Scripting — System Information Script

[`sysinfo.sh`](sysinfo.sh) prints system information to the console, prompts for two values,
then creates a directory and writes a report file into it.

## Assignment requirements → where each one is met

| Requirement | In the script |
|---|---|
| Prints the current date | `CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S %Z")`, section 1 |
| Prints the hostname | `HOST_NAME=$(hostname)`, section 2 |
| Prints the username | `USER_NAME=$(whoami)`, section 3 |
| Prints the disk usage | `df -h`, section 5 |
| Prints the running processes | `ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%mem`, section 7 |
| Uses variables | `CURRENT_DATE`, `HOST_NAME`, `USER_NAME`, `KERNEL`, `UPTIME`, `PROCESS_COUNT`, `REPORT_DIR`, `OWNER_NAME`, `REPORT_FILE` |
| Takes user input with `read -p` | two prompts: report directory and owner name |
| Creates a directory with `mkdir` | `mkdir -p "$REPORT_DIR"` |
| Creates a file with `touch` | `touch "$REPORT_FILE"` |
| Stores processes with `>` redirection | `{ ... } > "$REPORT_FILE"`, then `>>` for the rest |

## Running it

The script was run in an `ubuntu:24.04` container, since it uses GNU `ps` and `free`
(see [Portability](#portability) below).

```bash
docker cp sysinfo.sh ubuntu-lab:/root/sysinfo.sh
docker exec -it ubuntu-lab bash -c 'cd /root && bash sysinfo.sh'
```

### Full console output

Answering `devops-reports` and `Anisha Singhal` at the two prompts:

```
===============================================
           SYSTEM INFORMATION REPORT
===============================================

--- 1. Date and time ---
2026-09-03 17:07:58 UTC

--- 2. Hostname ---
ubuntu-lab

--- 3. Current user ---
root  (uid=0, groups: root)

--- 4. Kernel and uptime ---
kernel : Linux 6.12.76-linuxkit
uptime : 17:07:58 up 17 min,  0 user,  load average: 1.38, 1.47, 0.92

--- 5. Disk usage ---
Filesystem      Size  Used Avail Use% Mounted on
overlay         911G  258G  607G  30% /
tmpfs            64M     0   64M   0% /dev
shm              64M     0   64M   0% /dev/shm
/dev/vda1       911G  258G  607G  30% /etc/hosts
tmpfs           3.9G     0  3.9G   0% /proc/scsi
tmpfs           3.9G     0  3.9G   0% /sys/firmware

--- 6. Memory ---
               total        used        free      shared  buff/cache   available
Mem:           7.7Gi       1.4Gi       148Mi       1.3Mi       6.4Gi       6.4Gi
Swap:          1.0Gi          0B       1.0Gi

--- 7. Running processes (top 10 by memory) ---
    PID    PPID USER     %CPU %MEM COMMAND
    392     374 root      0.0  0.0 ps
    374     366 root      0.0  0.0 bash
    366       0 root      0.0  0.0 bash
    393     374 root      0.0  0.0 head
      1       0 root      0.0  0.0 sleep

total processes running: 7

-----------------------------------------------
Enter a directory name for the report [sysinfo-reports]: devops-reports
Enter your name for the report header [root]: Anisha Singhal

-----------------------------------------------
Report written to : devops-reports/processes-20260903-170813.txt
Size              : 4.0K
Lines             : 28
-----------------------------------------------
```

### The generated report file

`mkdir` created the directory, `touch` created the file, and the redirections filled it:

```bash
$ ls -la devops-reports/
-rw-r--r-- 1 root root  993 Sep  3 17:08 processes-20260903-170813.txt

$ cat devops-reports/processes-20260903-170813.txt
System information report
Prepared by : Anisha Singhal
Generated   : 2026-09-03 17:08:13 UTC
Host        : ubuntu-lab
User        : root
Kernel      : Linux 6.12.76-linuxkit
Uptime      : 17:08:13 up 17 min,  0 user,  load average: 1.45, 1.48, 0.94

Disk usage
----------
Filesystem      Size  Used Avail Use% Mounted on
overlay         911G  258G  607G  30% /
tmpfs            64M     0   64M   0% /dev
shm              64M     0   64M   0% /dev/shm
/dev/vda1       911G  258G  607G  30% /etc/hosts
tmpfs           3.9G     0  3.9G   0% /proc/scsi
tmpfs           3.9G     0  3.9G   0% /sys/firmware

Running processes (10 total)
----------------------------------------
    PID    PPID USER     %CPU %MEM COMMAND
    447     423 root      0.0  0.0 ps
    423     422 root      0.0  0.0 bash
    412       0 root      0.0  0.0 bash
    421     412 root      0.0  0.0 sed
    420     412 root      0.0  0.0 script
    422     420 root      0.0  0.0 sh
      1       0 root      0.0  0.0 sleep
```

The console shows only the top 10 processes (piped through `head -11`), while the file gets
the complete list — the point of writing a report rather than just printing one.

### Defaults, when you press Enter twice

```
Enter a directory name for the report [sysinfo-reports]:
Enter your name for the report header [root]:

-----------------------------------------------
Report written to : sysinfo-reports/processes-20260903-170828.txt
```

```bash
$ head -3 sysinfo-reports/*.txt
System information report
Prepared by : root
Generated   : 2026-09-03 17:08:28 UTC
```

The fallback directory `sysinfo-reports` and the fallback name `root` were both used, via
`${REPORT_DIR:-sysinfo-reports}`. This matters because it keeps the script usable from a
pipeline or a cron job, where nobody is there to type an answer.

## Things worth recording

**`read -p` prints nothing when stdin is not a terminal.** Piping input in to test it:

```bash
printf "devops-reports\nAnisha Singhal\n" | bash sysinfo.sh
```

...runs correctly but shows no prompts at all. Bash only writes the `-p` prompt when stdin is
a TTY. To capture the transcript above with the prompts visible, the run was wrapped in a
pseudo-terminal:

```bash
printf "devops-reports\nAnisha Singhal\n" | script -qc "bash sysinfo.sh" /dev/null
```

Good to know before concluding that a prompt "did not fire" in CI.

**`> ` vs `>>`.** The header block uses `>` and everything after it uses `>>`:

```bash
{ echo "System information report"; ... } > "$REPORT_FILE"
df -h >> "$REPORT_FILE"
```

If every line used `>`, each would truncate the file and only the last would survive. Using
`>` once at the top also means a re-run produces a clean report instead of appending to a
stale one.

**Grouping with `{ ... }` beats repeating the redirect.** Eleven `echo ... >> file` lines
open and close the file eleven times; one `{ ... } > file` opens it once. It also makes the
redirection target obvious at a glance.

**`touch` before writing is redundant here** — `>` creates the file anyway. It is in the
script because the assignment asks for it, and it does have a real use: creating a file with
the right permissions or timestamp before anything writes to it.

**`set -u`** aborts on an unset variable instead of silently expanding it to an empty string.
Without it, a typo like `$REPORT_DIRR` would produce `mkdir -p ""` and a confusing error much
later. `${VAR:-default}` still works under `set -u`, which is why the defaults do not trip it.

**Quote every expansion.** `mkdir -p "$REPORT_DIR"` — unquoted, a directory name with a space
becomes two arguments and creates two directories.

## Portability

The script targets Linux. Run on macOS it fails immediately:

```
ps: illegal option -- -
usage: ps [-AaCcEefhjlMmrSTvwXx] [-O fmt | -o fmt] ...
```

macOS ships **BSD** `ps`, which has no `--no-headers` and no `--sort`, and no `free` at all.
GNU coreutils vs BSD userland is the usual reason a working shell script breaks on a
different machine. The fixes, if it needed to run on both:

| Linux (GNU) | macOS (BSD) equivalent |
|---|---|
| `ps -e --no-headers \| wc -l` | `ps -e \| tail -n +2 \| wc -l` |
| `ps -eo ... --sort=-%mem` | `ps -eo ... -m` |
| `free -h` | `vm_stat`, or `top -l 1 \| head -10` |

`date`, `hostname`, `whoami`, `df -h`, `mkdir -p`, `touch` and `read -p` behave the same on
both, so the portable subset is most of the script — it is specifically the process and memory
listing that diverges.
