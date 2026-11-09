#!/usr/bin/env python3
"""PreToolUse guard for Bash: enforce the git rules of this branch (see CLAUDE.md, section 5).

Denies:
  * git push with --force / -f / --force-with-lease / --force-if-includes / +refspec / --mirror / --all /
    --tags / --delete / :refspec;
  * git push to anything but `origin` and branch ALLOWED_BRANCH (a bare `git push` is denied too);
  * git commit -a / --all (also combined short options such as -am);
  * git add . / -A / --all / :/ (add files by name).
Reads the hook JSON on stdin; prints a deny decision as JSON, prints nothing otherwise.
"""
import json
import re
import shlex
import sys

ALLOWED_REMOTE = "origin"
ALLOWED_BRANCH = "core-reset-v5"

GIT_GLOBAL_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "git guard (CLAUDE.md, section 5): " + reason,
        }
    }))
    sys.exit(0)


def segments(cmd):
    # split a shell command into simple commands; quotes are respected well enough for this purpose
    for part in re.split(r"&&|\|\||;|\||\n|\(|\)", cmd):
        part = part.strip()
        if not part:
            continue
        try:
            tokens = shlex.split(part, comments=True)
        except ValueError:
            tokens = part.split()
        yield strip_redirections(tokens)


def strip_redirections(tokens):
    # drop shell redirections: `2>&1`, `>file`, `> file`, `<<EOF`, `&>log`, ...
    out, skip = [], False
    for t in tokens:
        if skip:
            skip = False
            continue
        m = re.match(r"^(\d*|&)(>>?|<<?<?)(&?\d*-?)(.*)$", t)
        if m:
            if m.group(3) == "" and m.group(4) == "":
                skip = True  # target is the next token
            continue
        out.append(t)
    return out


def git_subcommand(tokens):
    # strip env assignments and wrappers, return (subcommand, args) for a git invocation or None
    i = 0
    while i < len(tokens) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[i]) or tokens[i] in ("env", "command", "exec", "time", "nice", "timeout")):
        i += 1
        if i < len(tokens) and tokens[i - 1] == "timeout" and re.match(r"^\d", tokens[i]):
            i += 1
    if i >= len(tokens) or tokens[i].split("/")[-1] != "git":
        return None
    i += 1
    while i < len(tokens) and tokens[i].startswith("-"):
        t = tokens[i]
        i += 1
        if t in GIT_GLOBAL_WITH_ARG:
            i += 1
    if i >= len(tokens):
        return None
    return tokens[i], tokens[i + 1:]


def check_push(args):
    positional = []
    for a in args:
        if a in ("--force", "-f", "--mirror", "--all", "--tags", "--delete", "-d", "--prune") \
                or a.startswith("--force-with-lease") or a.startswith("--force-if-includes"):
            deny(f"`git push {a}` is not allowed (never force push, push only {ALLOWED_BRANCH})")
        if re.match(r"^-[a-zA-Z]*f", a) and not a.startswith("--"):
            deny("`git push -f` is not allowed (never force push)")
        if a.startswith("-"):
            continue
        positional.append(a)
    if len(positional) < 2:
        deny(f"name the remote and branch explicitly: git push -u {ALLOWED_REMOTE} {ALLOWED_BRANCH}")
    remote, refspecs = positional[0], positional[1:]
    if remote != ALLOWED_REMOTE:
        deny(f"push only to remote `{ALLOWED_REMOTE}` (got `{remote}`)")
    for r in refspecs:
        if r.startswith("+") or r.startswith(":"):
            deny(f"refspec `{r}` is a force push or a delete")
        dst = r.split(":", 1)[-1]
        dst = dst[len("refs/heads/"):] if dst.startswith("refs/heads/") else dst
        if dst != ALLOWED_BRANCH:
            deny(f"push only to branch `{ALLOWED_BRANCH}` (got `{r}`); other branches need the user's explicit yes")


def check_commit(args):
    for a in args:
        if a == "--all" or (re.match(r"^-[a-zA-Z]+$", a) and "a" in a[1:]):
            deny("`git commit -a` is not allowed: add files by name")


def check_add(args):
    for a in args:
        if a in (".", "-A", "--all", ":/", "*", "./") or re.match(r"^-[a-zA-Z]*A", a):
            deny(f"`git add {a}` is not allowed: add files by name")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if data.get("tool_name") != "Bash":
        return
    cmd = (data.get("tool_input") or {}).get("command") or ""
    for tokens in segments(cmd):
        sc = git_subcommand(tokens)
        if sc is None:
            continue
        sub, args = sc
        if sub == "push":
            check_push(args)
        elif sub == "commit":
            check_commit(args)
        elif sub == "add":
            check_add(args)


if __name__ == "__main__":
    main()
