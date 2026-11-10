"""PreToolUse hook for Edit and Write: draws the proposed change inline in the Neovim
whose cwd holds the file (nvim/lua/config/review.lua) and waits for `ga` (allow) or `gr` (deny).

Lock files and git-ignored files go through without a diff; a generated file is denied (regenerate it).
There is no timer: the hook waits for a decision for as long as that Neovim runs (settings.json gives it a day).
Anything that goes wrong (no Neovim, no cwd match, an edit that cannot be applied, Neovim quitting)
prints nothing, so Claude Code's normal permission flow carries on. Every outcome, including
those, is one line in LOG.
"""
import fcntl
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import traceback
from functools import partial

LOG = os.path.expanduser("~/.local/state/claude-review/review.jsonl")
LOCKFILES = {"lazy-lock.json", "go.sum", "package-lock.json", "pnpm-lock.yaml"}
GENERATED = re.compile(r"Code generated .* DO NOT EDIT|@generated")


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
    for s in glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "nvim.*/*/nvim.*.0")):
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


def git(path, *args):
    d = path
    while not os.path.isdir(d):
        d = os.path.dirname(d)
    try:
        return subprocess.run(["git", "-C", d, *args], capture_output=True, text=True, timeout=5, check=False)
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


def take_turn(base):
    """Edits to one file are reviewed one at a time: blocks until the edit before ours is decided."""
    lock = open(base + ".lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    return lock


def main():
    started = time.time()
    hook = json.load(sys.stdin)
    inp = hook["tool_input"]
    path = os.path.realpath(inp["file_path"])
    note = partial(log, file=path, tool=hook["tool_name"], agent=hook.get("agent_id"))
    sock = socket_for(path)
    if not sock:
        return note("fallthrough", reason="no Neovim holds this file")
    if nvim(sock, "get(g:, 'claude_review_auto', v:false) ? 1 : 0") == "1":
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
    base = os.path.join(tempfile.gettempdir(), "cs-review-" + hashlib.sha1(path.encode()).hexdigest()[:12])
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
    nvim(sock, "luaeval(\"require('config.autocmds').sync()\")")
    fd, newfile = tempfile.mkstemp(prefix="cs-review-")
    result = newfile + ".result"
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        if nvim(sock, review("propose", path, newfile, result, why(hook))) != "1":
            return note("fallthrough", reason="Neovim did not draw the review")
        # Detached from our stdio: a child holding the stdout pipe open past our
        # exit makes Claude Code see the verdict without an end-of-stream and
        # refuse it ("stdio went quiet before end-of-stream").
        subprocess.Popen(["afplay", "/System/Library/Sounds/Ping.aiff"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        while os.path.exists(sock):
            if os.path.exists(result):
                with open(result) as f:
                    line = f.read().strip()
                waited = round(time.time() - started, 1)
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
                if line:
                    reason = line[len("reject"):].strip()
                    note("rejected", waited=waited, reason=reason)
                    return verdict(False, "Rejected in Neovim" + (f": {reason}" if reason else ""))
            time.sleep(0.2)
        # a Neovim that quit has nothing left to review, so it falls through
        note("fallthrough", reason="Neovim quit during the review")
    finally:
        for p in (newfile, result):
            if os.path.exists(p):
                os.remove(p)


if __name__ == "__main__":
    try:
        main()
    except Exception:  # whatever breaks, the edit must still get Claude Code's normal flow
        log("error", error=traceback.format_exc()[-600:])
