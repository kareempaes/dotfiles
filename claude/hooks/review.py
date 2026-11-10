"""PreToolUse hook for Edit and Write: draws the proposed change inline in the Neovim
whose cwd holds the file (nvim/lua/config/review.lua) and waits for `ga` (allow) or `gr` (deny).

Lock files and git-ignored files go through without a diff; a generated file is denied (regenerate it).
There is no timer: the hook waits for a decision for as long as that Neovim runs (settings.json gives it a day).
Anything that goes wrong (no Neovim, no cwd match, an edit that cannot be applied, Neovim quitting)
prints nothing, so Claude Code's normal permission flow carries on. Every outcome, including
those, is one line in LOG.

On Bash it is the PreToolUse and the PostToolUse hook: what a command changes is not known until it has run, so
before() keeps the work tree and after() reviews each file that differs, with the change already on disk. Neovim
writes a reject back, and Claude is told what was undone.
"""
import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from functools import partial

LOG = os.path.expanduser("~/.local/state/claude-review/review.jsonl")
LOCKFILES = {"lazy-lock.json", "go.sum", "package-lock.json", "pnpm-lock.yaml"}
GENERATED = re.compile(r"Code generated .* DO NOT EDIT|@generated")
# Neovim's own rule for its server sockets: in $XDG_RUNTIME_DIR where that is set (Linux), else under $TMPDIR (macOS)
SOCKETS = (os.path.join(os.environ["XDG_RUNTIME_DIR"], "nvim.*.0") if os.environ.get("XDG_RUNTIME_DIR")
           else os.path.join(os.environ.get("TMPDIR", "/tmp"), "nvim.*/*/nvim.*.0"))
PING = (["afplay", "/System/Library/Sounds/Ping.aiff"] if sys.platform == "darwin"
        else ["paplay", "/usr/share/sounds/freedesktop/stereo/message.oga"])
SYNC = "luaeval(\"require('config.autocmds').sync()\")"


def log(event, **kw):
    """One JSON line per outcome. It never raises: a broken log must not break an edit."""
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:
            os.replace(LOG, LOG + ".1")
        with open(LOG, "a") as f:
            f.write(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event, **kw}) + "\n")
    except OSError:
        pass


def nvim(sock, expr):
    out = subprocess.run(["nvim", "--server", sock, "--remote-expr", expr],
                         capture_output=True, text=True, timeout=5)
    return out.stdout.strip()


def review(fn, *args):
    return f"luaeval('require(\"config.review\").{fn}(unpack(_A))', {json.dumps(list(args))})"


def auto(sock):
    return nvim(sock, "get(g:, 'claude_review_auto', v:false) ? 1 : 0") == "1"


def verdict(allow, reason, **extra):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow" if allow else "deny",
        "permissionDecisionReason": reason,
        **extra,
    }}))


def why(hook):
    """The assistant text just before this tool call, or "" when the transcript has not caught up."""
    try:
        with open(hook["transcript_path"], "rb") as f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - 400_000))
            lines = f.read().decode("utf-8", "ignore").splitlines()[1:]
        for line in reversed(lines):
            e = json.loads(line)
            content = (e.get("message") or {}).get("content") or []
            if e.get("type") == "assistant":
                texts = [b["text"].strip() for b in content if b.get("type") == "text" and b["text"].strip()]
                if texts:
                    return texts[-1][:600]
            elif e.get("type") == "user" and (isinstance(content, str) or any(b.get("type") != "tool_result" for b in content)):
                break
    except Exception:  # a missing or odd transcript only costs the reason
        pass
    return ""


def revised(tool, inp, path, new):
    """The tool input that writes `new`, for an edit the user changed in Neovim."""
    if tool == "Write":
        return {**inp, "content": new}
    with open(path, encoding="utf-8", newline="") as f:
        return {**inp, "old_string": f.read(), "new_string": new}


def proposed(tool, inp, path):
    if tool == "Write":
        return inp["content"]
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    if inp["old_string"] not in text:
        raise ValueError("old_string not found")
    return text.replace(inp["old_string"], inp["new_string"], -1 if inp.get("replace_all") else 1)


def socket_for(path):
    best, depth = None, -1
    for s in glob.glob(SOCKETS):
        try:
            cwd = os.path.realpath(nvim(s, "getcwd()"))
        except Exception:  # a dead socket is skipped
            continue
        if path.startswith(cwd.rstrip("/") + "/") and len(cwd) > depth:
            best, depth = s, len(cwd)
    return best


def read(path):
    try:
        with open(path, encoding="utf-8", newline="") as f:
            return f.read()
    except FileNotFoundError:
        return None


def git(path, *args, env=None):
    d = path
    while not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        return subprocess.run(["git", "-C", d, *args], capture_output=True, text=True, timeout=5, check=False, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None


def classify(path):
    """"lock" and "ignored" files pass without a diff, "generated" ones are denied, anything else is reviewed."""
    if os.path.basename(path) in LOCKFILES:
        return "lock"
    ignored = git(path, "check-ignore", "-q", path)
    if ignored and ignored.returncode == 0:
        return "ignored"
    attr = git(path, "check-attr", "linguist-generated", "--", path)
    if GENERATED.search((read(path) or "")[:400]) or (attr and attr.stdout.strip().endswith(("set", "true"))):
        return "generated"


def key(path):
    """Where the lock and the marker of one file's reviews are kept."""
    return os.path.join(tempfile.gettempdir(), "cs-review-" + hashlib.sha1(path.encode()).hexdigest()[:12])


def take_turn(base):
    """Edits to one file are reviewed one at a time: blocks until the edit before ours is decided."""
    lock = open(base + ".lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    return lock


def ping():
    # Detached from our stdio: a child holding the stdout pipe open past our
    # exit makes Claude Code see the verdict without an end-of-stream and
    # refuse it ("stdio went quiet before end-of-stream").
    try:
        subprocess.Popen(PING, stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:  # no player on this system: the review is drawn all the same
        pass


def decision(sock, result):
    """The line Neovim writes when the review ends ("accept" or "reject <reason>"), or None when it quits first."""
    while os.path.exists(sock):
        if os.path.exists(result):
            with open(result) as f:
                line = f.read().strip()
            if line:
                return line
        time.sleep(0.2)


def edit(hook):
    started = time.time()
    inp = hook["tool_input"]
    path = os.path.realpath(inp["file_path"])
    note = partial(log, file=path, tool=hook["tool_name"], agent=hook.get("agent_id"))
    sock = socket_for(path)
    if not sock:
        return note("fallthrough", reason="no Neovim holds this file")
    if auto(sock):
        note("auto")
        return verdict(True, "Auto-accept is on in Neovim")
    kind = classify(path)
    if kind == "generated":
        note("denied", reason="generated file")
        return verdict(False, "This file is generated (a DO NOT EDIT header or linguist-generated): "
                       "regenerate it with the project's generator instead of editing it")
    if kind:
        note("skipped", reason=kind)
        return verdict(True, f"{kind} file, not reviewed")
    base = key(path)
    lock = take_turn(base)  # held until the process exits
    # The edit accepted just before ours is written by Claude Code after its hook exits: wait for it,
    # so the diff is drawn against the file it left.
    marker = base + ".expect"
    if os.path.exists(marker):
        # a marker older than a few seconds is not an edit still being written
        for _ in range(25 if time.time() - os.path.getmtime(marker) < 15 else 0):
            if read(path) == read(marker):
                break
            time.sleep(0.2)
        os.remove(marker)
    text = proposed(hook["tool_name"], inp, path)
    nvim(sock, SYNC)
    fd, newfile = tempfile.mkstemp(prefix="cs-review-")
    result = newfile + ".result"
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        if nvim(sock, review("propose", path, newfile, result, why(hook))) != "1":
            return note("fallthrough", reason="Neovim did not draw the review")
        ping()
        line = decision(sock, result)
        waited = round(time.time() - started, 1)
        if not line:  # a Neovim that quit has nothing left to review, so it falls through
            return note("fallthrough", reason="Neovim quit during the review")
        if line == "accept":
            final = read(newfile)
            if final is None:
                return note("fallthrough", reason="the proposal file vanished before the accept was read")
            with open(base + ".expect", "w", encoding="utf-8", newline="") as f:
                f.write(final)
            if final == text:
                note("accepted", waited=waited)
                return verdict(True, "Accepted in Neovim")
            note("revised", waited=waited)
            return verdict(True, "Accepted in Neovim, with the user's changes",
                           updatedInput=revised(hook["tool_name"], inp, path, final),
                           additionalContext="The user revised this edit in Neovim before it was applied, "
                           "so the file differs from your proposed change. Re-read it before editing it again.")
        reason = line[len("reject"):].strip()
        note("rejected", waited=waited, reason=reason)
        return verdict(False, "Rejected in Neovim" + (f": {reason}" if reason else ""))
    finally:
        for p in (newfile, result):
            if os.path.exists(p):
                os.remove(p)


def scratch(root, keep):
    """The environment in which git keeps its index and new objects in `keep`: the repository is not written to."""
    objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").stdout.strip()
    return {**os.environ, "GIT_INDEX_FILE": os.path.join(keep, "index"),
            "GIT_OBJECT_DIRECTORY": os.path.join(keep, "objects"), "GIT_ALTERNATE_OBJECT_DIRECTORIES": objects}


def snapshot(root, env):
    """The work tree as a git tree: untracked files included, ignored ones not. It raises when git fails."""
    run = partial(subprocess.run, env=env, capture_output=True, text=True, timeout=30, check=True)
    run(["git", "-C", root, "add", "-A"])
    return run(["git", "-C", root, "write-tree"]).stdout.strip()


def before(hook, keep):
    """PreToolUse on Bash: keeps the work tree as it is now, for after() to compare with. Only where a Neovim
    runs and the command starts inside a git repository."""
    root = git(hook["cwd"], "rev-parse", "--show-toplevel")
    if not glob.glob(SOCKETS) or not root or root.returncode:
        return
    root = root.stdout.strip()
    os.mkdir(keep, 0o700)
    os.mkdir(os.path.join(keep, "objects"))
    index = git(root, "rev-parse", "--path-format=absolute", "--git-path", "index").stdout.strip()
    if os.path.exists(index):  # starting from the real index, only files that changed since are read
        shutil.copy(index, os.path.join(keep, "index"))
    state = [root, snapshot(root, scratch(root, keep)), git(root, "rev-parse", "HEAD").stdout.strip()]
    with open(os.path.join(keep, "tree"), "w") as f:
        json.dump(state, f)


def landed(hook, env, root, old, status, rel):
    """Reviews one file a command added, modified or deleted (status A, M, D) since the tree `old`. Returns what
    the user undid, for Claude, or None."""
    path = os.path.join(root, rel)
    note = partial(log, file=path, tool="Bash", agent=hook.get("agent_id"))
    sock = socket_for(path)
    if not sock:
        return note("fallthrough", reason="no Neovim holds this file")
    if auto(sock):
        return note("auto")
    if os.path.islink(path) or os.path.isdir(path):
        return note("skipped", reason="not a file")
    lock = take_turn(key(path))  # held until this file is decided
    fd, newfile = tempfile.mkstemp(prefix="cs-review-")
    os.close(fd)
    oldfile, result = newfile + ".old", newfile + ".result"
    try:
        if status != "A":
            with open(oldfile, "wb") as f:
                subprocess.run(["git", "-C", root, "cat-file", "blob", f"{old}:{rel}"], env=env, stdout=f,
                               timeout=5, check=True)
        if status != "D":
            shutil.copyfile(path, newfile)
        try:
            text = read(newfile)
            read(oldfile)
        except UnicodeDecodeError:
            return note("skipped", reason="binary")
        kind = classify(path)
        if kind:  # a generated file is what its generator just wrote
            return note("skipped", reason=kind)
        nvim(sock, SYNC)
        # an old file makes it the review of a change already on disk; "" says the file did not exist
        if nvim(sock, review("propose", path, newfile, result, why(hook), oldfile if status != "A" else "")) != "1":
            return note("fallthrough", reason="Neovim did not draw the review")
        ping()
        line = decision(sock, result)
        if not line:
            return note("fallthrough", reason="Neovim quit during the review")
        if line == "accept":
            if read(newfile) == text:
                return note("accepted")
            note("revised")
            return f"{rel}: only part of the change was kept, or the user revised it"
        reason = line[len("reject"):].strip()
        note("rejected", reason=reason)
        return f"{rel}: rejected and put back as it was" + (f" ({reason})" if reason else "")
    finally:
        for p in (newfile, oldfile, result):
            if os.path.exists(p):
                os.remove(p)


def after(hook, keep):
    """PostToolUse and PostToolUseFailure (a command that exits non-zero) on Bash: each file that differs from the
    tree before() kept is reviewed in Neovim, one at a time."""
    try:
        if not os.path.exists(os.path.join(keep, "tree")):  # no Neovim then, or not a git repository
            return
        with open(os.path.join(keep, "tree")) as f:
            root, old, head = json.load(f)
        if git(root, "rev-parse", "HEAD").stdout.strip() != head:  # a commit, checkout or pull is not an edit
            return log("skipped", tool="Bash", reason="HEAD moved")
        env = scratch(root, keep)
        changed = git(root, "diff-tree", "-r", "-z", "--no-renames", "--name-status", old, snapshot(root, env),
                      env=env).stdout.split("\0")
        undone = [u for u in (landed(hook, env, root, old, *f) for f in zip(changed[::2], changed[1::2])) if u]
        if undone:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": hook["hook_event_name"],
                "additionalContext": "The user reviewed this command's changes in Neovim. " + "; ".join(undone)
                + ". Read these files again before changing them, and do not repeat a rejected change.",
            }}))
    finally:
        shutil.rmtree(keep, ignore_errors=True)


def main():
    hook = json.load(sys.stdin)
    if hook["tool_name"] != "Bash":
        return edit(hook)
    keep = os.path.join(tempfile.gettempdir(), "cs-bash-" + hook["tool_use_id"])
    (before if hook["hook_event_name"] == "PreToolUse" else after)(hook, keep)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # whatever breaks, the edit must still get Claude Code's normal flow
        log("error", error=traceback.format_exc()[-600:])
