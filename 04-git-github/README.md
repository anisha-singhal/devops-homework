# Git / GitHub Tasks

Both tasks were run in throwaway local repositories so the history could be built from
nothing and inspected at every step. All command output below is real.

```bash
git init -b main
git config user.name  "Anisha Singhal"
git config user.email "anisha.singhal@scalerailabs.com"
```

## Task 1 — `git commit -m` vs `git commit -a -m`

### The difference in one line

`-a` (`--all`) stages every **already-tracked** file that has been modified or deleted, then
commits. It does not touch untracked files, and it ignores whatever you had deliberately
staged.

### Setup: one tracked change, one untracked file

```bash
echo "tracked change one" >> README.md   # README.md is tracked
echo "brand new file" > untracked.txt    # never git add-ed
```

```bash
$ git status --short
 M README.md
?? untracked.txt
```

The two-column format matters for the rest of this task. Column 1 is the **staging area**,
column 2 is the **working tree**. So ` M` = modified but not staged, `M ` = staged, and `??` =
untracked.

### `git commit -m` with nothing staged

```bash
$ git commit -m "try to commit without staging"
On branch main
Changes not staged for commit:
  (use "git add <file>..." to update what will be committed)
  (use "git restore <file>..." to discard changes in working directory)
	modified:   README.md

Untracked files:
  (use "git add <file>..." to include in what will be committed)
	untracked.txt

no changes added to commit (use "git add" and/or "git commit -a")
```

**No commit was created.** `git commit -m` only commits what is in the staging area, and
nothing had been staged. Git even names both ways out in the last line.

### `git commit -a -m`

```bash
$ git commit -a -m "Task1: commit -a -m auto-staged the tracked change"
[main c0a9182] Task1: commit -a -m auto-staged the tracked change
 1 file changed, 1 insertion(+)
```

It worked without any `git add`. But look at what is left behind:

```bash
$ git status --short
?? untracked.txt

$ git show --stat --oneline HEAD
c0a9182 Task1: commit -a -m auto-staged the tracked change
 README.md | 1 +
 1 file changed, 1 insertion(+)
```

**`untracked.txt` is still uncommitted.** `-a` staged the modification to `README.md`, which
git already knew about, and ignored the new file entirely. A new file has to be introduced
with `git add` before git will ever pick it up automatically:

```bash
$ git add untracked.txt
$ git commit -m "Task1: add untracked.txt explicitly with git add"
$ git status --short
(clean)
```

This is the trap in `commit -a -m`: it feels like "commit everything", so a newly created
file silently misses the commit. You then push, and CI fails on a file that exists only on
your machine.

### The second difference: `-a` overrides deliberate staging

This is the part I found more interesting. The staging area lets you commit a *subset* of your
changes — and `-a` throws that away.

Both files modified, only `fileA` staged:

```bash
$ echo "fileA: change I want to commit now" >> fileA.txt
$ echo "fileB: work in progress, NOT ready" >> fileB.txt
$ git add fileA.txt

$ git status --short
M  fileA.txt      <- staged
 M fileB.txt      <- not staged, on purpose
```

`git commit -m` respects it:

```bash
$ git commit -m "Task1: commit -m committed ONLY the staged fileA"
86d08bc Task1: commit -m committed ONLY the staged fileA
 fileA.txt | 1 +
 1 file changed, 1 insertion(+)

$ git status --short
 M fileB.txt      <- still held back, as intended
```

`git commit -a -m` from the identical starting state does not:

```bash
$ git status --short
M  fileA.txt
 M fileB.txt

$ git commit -a -m "Task1: commit -a -m swept up BOTH files"
[main 4c1489d] Task1: commit -a -m swept up BOTH files
 2 files changed, 2 insertions(+)
 fileA.txt | 1 +
 fileB.txt | 1 +

$ git status --short
(clean - nothing held back)
```

The work-in-progress `fileB` went into the commit. Nothing warned me. If I had spent time with
`git add -p` splitting a messy change into clean commits, a single `-a` would undo all of it.

### Comparison

| | `git commit -m` | `git commit -a -m` |
|---|---|---|
| Commits staged changes | yes | yes |
| Stages modified tracked files first | no | yes |
| Includes untracked (new) files | no | **no** |
| Includes deleted tracked files | only if staged | yes |
| Respects partial/deliberate staging | yes | **no** |
| Fails when nothing is staged | yes | commits anything modified |

### Which to use

**`git commit -m` after an explicit `git add`.** It is one extra command and it means the
commit contains exactly what I chose. It is also the only option that works with `git add -p`
for splitting changes into reviewable commits.

**`git commit -a -m`** for a small, single-purpose change where I have already run
`git status` and know the working tree holds nothing else. It is a convenience, not a
default — and it still cannot pick up new files, which is the failure people actually hit.

> Interview phrasing: *`-a` auto-stages tracked files that were modified or deleted, so it
> saves a `git add` — but it never picks up untracked files, and it discards any partial
> staging you had set up. Plain `git commit -m` commits exactly the staging area.*

## Task 2 — `git cherry-pick`

### The scenario

A hotfix was committed on a feature branch, in the middle of unrelated feature work. The
hotfix is needed on `main` **now**, but the features are not ready. Merging the branch would
bring everything; cherry-picking brings one commit.

### Step 1–2: four commits on `main`, then `git log`

```bash
$ git log --oneline --graph
* f5a130f C4: extend app.txt
* 07d35ac C3: add config.txt
* 554ae22 C2: add app.txt
* 9c43bce C1: add README
```

### Step 3–4: a branch, and three commits on it

```bash
$ git checkout -b feature-branch
$ git branch -vv
* feature-branch f5a130f C4: extend app.txt
  main           f5a130f C4: extend app.txt
```

Both point at `f5a130f` — a new branch is just a pointer at the current commit, nothing is
copied.

Then `F1` (a feature), `F2` (the hotfix), `F3` (another feature):

```bash
$ git log --oneline --graph
* db5f33d F3: add signup page
* a0cd2e2 F2: HOTFIX raise timeout to 60 (needed on main urgently)
* 147691b F1: add login page
* f5a130f C4: extend app.txt
...
```

### Step 5: identify the specific commit

`git log` shows branch and shared history together. The `..` range syntax narrows it to
just what is unique to this branch:

```bash
$ git log --oneline main..feature-branch
db5f33d F3: add signup page
a0cd2e2 F2: HOTFIX raise timeout to 60 (needed on main urgently)
147691b F1: add login page
```

`main..feature-branch` reads as "commits reachable from `feature-branch` but not from
`main`" — the three I made. This is the query to use before any cherry-pick, so you pick from
the right set.

```bash
$ git show --stat --oneline a0cd2e2
a0cd2e2 F2: HOTFIX raise timeout to 60 (needed on main urgently)
 config.txt | 1 +
 hotfix.txt | 1 +
 2 files changed, 2 insertions(+)
```

`--stat` before picking is worth the two seconds — it confirms the commit touches only what
you expect.

### Step 6–7: cherry-pick onto `main`

```bash
$ git checkout main
$ git log --oneline
f5a130f C4: extend app.txt
07d35ac C3: add config.txt
554ae22 C2: add app.txt
9c43bce C1: add README

$ ls
README.md app.txt config.txt

$ cat config.txt
config: debug=false
```

```bash
$ git cherry-pick a0cd2e2
[main f365c5c] F2: HOTFIX raise timeout to 60 (needed on main urgently)
 Date: Thu Sep 3 22:44:31 2026 +0530
 2 files changed, 2 insertions(+)
 create mode 100644 hotfix.txt
```

### Step 8: verify

The commit is on `main`:

```bash
$ git log --oneline
f365c5c F2: HOTFIX raise timeout to 60 (needed on main urgently)
f5a130f C4: extend app.txt
07d35ac C3: add config.txt
554ae22 C2: add app.txt
9c43bce C1: add README
```

The change is really in the files:

```bash
$ ls
README.md app.txt config.txt hotfix.txt

$ cat config.txt
config: debug=false
timeout=60

$ cat hotfix.txt
HOTFIX: correct the timeout value from 30 to 60
```

And — the point of the exercise — the other two commits did **not** come along:

```bash
login.txt: NOT on main -- correct, it belongs to F1/F3
signup.txt: NOT on main -- correct, it belongs to F1/F3
```

### What cherry-pick actually does to the commit

The same change now exists on both branches under **different SHAs**:

```bash
on feature-branch : a0cd2e2 F2: HOTFIX raise timeout to 60 (needed on main urgently)
on main           : f365c5c F2: HOTFIX raise timeout to 60 (needed on main urgently)
```

A commit's SHA is a hash of its content *and* its metadata — including its parent. The picked
commit has a different parent (`f5a130f` instead of `147691b`), so it is a **different
commit** that happens to carry the same diff. Cherry-pick copies a change; it does not move a
commit.

The diff itself is provably identical, via `git patch-id`, which hashes the change while
ignoring commit metadata:

```bash
feature-branch patch-id : 7b1821801042
main patch-id           : 7b1821801042
```

The dates show which parts were preserved:

```bash
feature: a0cd2e2  author-date=22:44:31  commit-date=22:44:31
main   : f365c5c  author-date=22:44:31  commit-date=22:44:41
```

**Author date preserved, commit date new.** Git keeps the original authorship — who wrote it
and when — and records the copy as a new commit event ten seconds later. That is why
`git log` on a branch full of cherry-picks can show commits out of chronological order.

`git cherry` uses patch-ids to report which branch commits are already upstream:

```bash
$ git cherry -v main feature-branch
+ 147691b F1: add login page
- a0cd2e2 F2: HOTFIX raise timeout to 60 (needed on main urgently)
+ db5f33d F3: add signup page
```

`-` means "an equivalent change is already on `main`", `+` means "not there yet". Useful
before merging a branch whose commits you have partly picked already.

```bash
$ git log --oneline --graph --all --decorate
* f365c5c (HEAD -> main) F2: HOTFIX raise timeout to 60 (needed on main urgently)
| * db5f33d (feature-branch) F3: add signup page
| * a0cd2e2 F2: HOTFIX raise timeout to 60 (needed on main urgently)
| * 147691b F1: add login page
|/
* f5a130f C4: extend app.txt
* 07d35ac C3: add config.txt
* 554ae22 C2: add app.txt
* 9c43bce C1: add README
```

The duplicated `F2` on both legs is exactly what a cherry-pick looks like in history.

### Cherry-picking into a conflict

Cherry-pick applies a diff to a different starting point, so it can fail. I set that up
deliberately — the same line edited differently on each branch:

```bash
$ git cherry-pick 9061069
Auto-merging app.txt
CONFLICT (content): Merge conflict in app.txt
error: could not apply 9061069... F4: edit the shared line (feature-branch wording)
hint: After resolving the conflicts, mark them with
hint: "git add/rm <pathspec>", then run
hint: "git cherry-pick --continue".
hint: You can instead skip this commit with "git cherry-pick --skip".
hint: To abort and get back to the state before "git cherry-pick",
hint: run "git cherry-pick --abort".
exit code: 1
```

```bash
$ git status --short
UU app.txt
```

`UU` = unmerged, modified on both sides. The markers:

```
app v2 (more features)
<<<<<<< HEAD
MAIN VERSION of the shared line
=======
FEATURE-BRANCH VERSION of the shared line
>>>>>>> 9061069 (F4: edit the shared line (feature-branch wording))
```

Between `<<<<<<< HEAD` and `=======` is what `main` has; between `=======` and `>>>>>>>` is
what the picked commit wants. Resolving means editing the file into its correct final form and
removing all three marker lines.

```bash
$ git add app.txt          # staging the file is how you mark it resolved
$ git cherry-pick --continue
[main bd6ab38] F4: edit the shared line (feature-branch wording)
 1 file changed, 1 insertion(+)
```

The three ways out of a conflicted cherry-pick:

| Command | Effect |
|---|---|
| `git cherry-pick --continue` | after `git add`-ing the resolved files, finish the pick |
| `git cherry-pick --abort` | undo everything, back to the pre-pick state |
| `git cherry-pick --skip` | drop this commit, carry on (when picking a range) |

### Useful forms

| Command | What it does |
|---|---|
| `git cherry-pick <sha>` | copy one commit onto the current branch |
| `git cherry-pick <a> <b> <c>` | several specific commits, in that order |
| `git cherry-pick <a>..<b>` | a range, **excluding** `a` |
| `git cherry-pick <a>^..<b>` | a range **including** `a` |
| `git cherry-pick -n <sha>` | apply the change but do not commit — lets you edit it first |
| `git cherry-pick -x <sha>` | append "(cherry picked from commit …)" to the message |
| `git cherry-pick -e <sha>` | edit the commit message during the pick |

**`-x` is the one to use on shared branches.** It records the original SHA in the message, so
six months later it is possible to tell where a duplicated commit came from. Without it, the
two commits look unrelated.

### When to cherry-pick — and when not to

**Good uses:** a hotfix that must reach a release branch without the features around it;
backporting a single fix to a maintenance branch; recovering one commit from a branch that is
being abandoned.

**Avoid when a merge or rebase would do.** Cherry-picking duplicates commits, and duplicated
history causes real trouble later: if `feature-branch` is eventually merged into `main`, `F2`
exists twice, and git may or may not resolve that cleanly depending on what has happened
since. Merging keeps one commit and one lineage. Cherry-pick is the tool for "I need *this
one* change, *now*, and not the rest" — a deliberate exception, not a workflow.

## Summary

- `-a` auto-stages **tracked** modifications only, and silently discards partial staging.
  New files always need `git add`.
- `main..branch` is how you list the commits that are candidates for a pick.
- A cherry-picked commit gets a **new SHA** and keeps its **original author date**. Identical
  patch-id, different commit — `git cherry -v` is what tells you they match.
- Conflicts are normal, because the diff is being applied to a different base.
  `--continue` / `--abort` / `--skip` are the three exits, and staging the file is what marks
  it resolved.
- Use `-x` on anything shared, so the duplicate is traceable.
