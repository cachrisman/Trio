#!/usr/bin/env python3
"""Pull Trio crash reports (.ips) off a paired iPhone, symbolicate them with
the build's dSYMs from GitHub releases, and post one structured JSON event per
crash to BetterStack's HTTP log ingest, deduplicated by incident id.

Python 3.9+ standard library only. Run hourly by launchd as `python3 -I`.
"""

import argparse
import datetime
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
import urllib.error
import urllib.request
import zipfile

DEFAULT_STATE_DIR = "~/Library/Application Support/trio-crash-ingest"
DEFAULT_CACHE_DIR = "~/Library/Caches/trio-crash-ingest"
DEFAULT_HOST = "https://in.logs.betterstack.com"
TRIO_APP_NAMES = {"Trio", "Trio Watch App"}
SYSTEM_PREFIXES = ("/usr/lib", "/System", "/private/preboot")
APP_IMAGE_NAMES = {"Trio", "Trio Watch App"}
BATCH_SIZE = 50
MAX_FRAMES = 40
TIMEOUT_DEVICE = 600


class Deferred(Exception):
    """The report cannot be symbolicated yet; retry on the next run."""


# ---------------------------------------------------------------- subprocess

def run_cmd(args, timeout=120):
    """Run an argument list; return (returncode, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           errors="replace")
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "executable not found: %s" % args[0]
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except OSError as e:
        return 126, "", str(e)


# ------------------------------------------------------------------- parsing

def parse_ips(path):
    """Return {"header", "body", "path", "raw_hash"} or None if unparseable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        first, _, rest = text.partition("\n")
        header = json.loads(first)
        body = json.loads(rest)
    except (OSError, ValueError):
        return None
    if not isinstance(header, dict) or not isinstance(body, dict):
        return None
    return {"header": header, "body": body, "path": path,
            "raw_hash": hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()}


def is_trio_crash(report):
    h = report["header"]
    if str(h.get("bug_type")) != "309":
        return False
    app_name = h.get("app_name")
    if isinstance(app_name, str) and app_name in TRIO_APP_NAMES:
        return True
    bundle = str(h.get("bundleID") or "")
    return bundle.startswith("org.nightscout.") and "trio" in bundle.lower()


def parse_time(value):
    """Parse '2026-11-08 10:39:55.9937 +0100' into an aware datetime or None."""
    if not isinstance(value, str):
        return None
    for fmt in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
        try:
            return datetime.datetime.strptime(value.strip(), fmt)
        except ValueError:
            continue
    return None


def capture_time(report):
    return parse_time(report["body"].get("captureTime")) or parse_time(
        report["header"].get("timestamp"))


def incident_id(report):
    return report["header"].get("incident_id") or "noid-" + report["raw_hash"]


# ---------------------------------------------------------------- state file

def load_state(state_dir):
    try:
        with open(os.path.join(state_dir, "sent.json"), "r", encoding="utf-8") as f:
            data = json.load(f)
        ids = data.get("incident_ids")
        if isinstance(ids, dict):
            return {"incident_ids": ids}
    except (OSError, ValueError, AttributeError):
        pass
    return {"incident_ids": {}}


def save_state(state_dir, state):
    os.makedirs(state_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix="sent.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=1, sort_keys=True)
        os.replace(tmp, os.path.join(state_dir, "sent.json"))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# -------------------------------------------------------------- symbolication

UUID_RE = re.compile(r"UUID:\s*([0-9A-Fa-f-]+)\s*\((\w+)\)")


class Symbolicator:
    """Wraps gh / unzip / dwarfdump / atos. `runner(args, timeout=)` is injectable."""

    def __init__(self, cache_dir, repo, runner=run_cmd):
        self.cache_dir = cache_dir
        self.repo = repo
        self.runner = runner
        self._maps = {}  # tag -> {uuid: (dwarf_path, arch)}

    @staticmethod
    def tag_for(report):
        h = report["header"]
        return "trio-v%s-%s-localCI" % (h.get("app_version"), h.get("build_version"))

    def dsym_map(self, tag):
        if tag in self._maps:
            return self._maps[tag]
        d = os.path.join(self.cache_dir, tag)
        dsym = os.path.join(d, "dsym")
        if os.path.exists(os.path.join(d, "MISSING")):
            self._maps[tag] = {}
        else:
            if not os.path.isdir(dsym):
                self._download(tag, d, dsym)
            self._maps[tag] = self._build_map(dsym) if os.path.isdir(dsym) else {}
        return self._maps[tag]

    def _download(self, tag, d, dsym):
        os.makedirs(d, exist_ok=True)
        zip_path = os.path.join(d, "Trio.app.dSYM.zip")
        self._cleanup(d, dsym)
        rc, out, err = self.runner(
            ["gh", "release", "download", tag, "-R", self.repo, "--clobber",
             "-p", "Trio.app.dSYM.zip", "-D", d], timeout=300)
        if rc != 0:
            text = (out + err).lower()
            if "release not found" in text or "http 404" in text:
                with open(os.path.join(d, "MISSING"), "w") as f:
                    f.write("release not found\n")
                return
            raise Deferred("gh download failed for %s (rc=%s)" % (tag, rc))
        partial = dsym + ".partial"
        try:
            with zipfile.ZipFile(zip_path) as z:
                z.extractall(partial)
            os.replace(partial, dsym)
        except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError) as e:
            self._cleanup(d, dsym)
            raise Deferred("unzip failed for %s: %s" % (tag, e))

    @staticmethod
    def _cleanup(d, dsym):
        """Remove leftovers of an earlier attempt (never the MISSING marker)."""
        try:
            os.unlink(os.path.join(d, "Trio.app.dSYM.zip"))
        except OSError:
            pass
        for p in glob.glob(os.path.join(glob.escape(d), "*.partial")):
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p, ignore_errors=True)
            else:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        shutil.rmtree(dsym, ignore_errors=True)

    def _build_map(self, dsym):
        result = {}
        for root, _dirs, files in os.walk(dsym):
            if not root.endswith(os.path.join("Contents", "Resources", "DWARF")):
                continue
            for name in sorted(files):
                path = os.path.join(root, name)
                rc, out, _err = self.runner(["dwarfdump", "--uuid", path], timeout=60)
                if rc != 0:
                    continue
                for m in UUID_RE.finditer(out):
                    result[m.group(1).lower()] = (path, m.group(2))
        return result

    def symbolicate(self, report, items):
        """items: [{uuid, base, offset}]; returns list of atos strings or None."""
        results = [None] * len(items)
        dmap = self.dsym_map(self.tag_for(report))
        if not dmap:
            return results
        by_image = {}
        for i, it in enumerate(items):
            uuid = str(it.get("uuid") or "").lower()
            if uuid in dmap:
                by_image.setdefault((uuid, it["base"]), []).append(i)
        for (uuid, base), idxs in by_image.items():
            dwarf, arch = dmap[uuid]
            addrs = [hex(base + items[i]["offset"]) for i in idxs]
            rc, out, _err = self.runner(
                ["atos", "-arch", arch, "-o", dwarf, "-l", hex(base)] + addrs, timeout=120)
            lines = out.splitlines()
            if rc != 0 or len(lines) != len(idxs):
                continue
            for i, line in zip(idxs, lines):
                line = line.strip()
                if line and not line.startswith("0x"):
                    results[i] = line
        return results


# --------------------------------------------------------------------- event

def _dict(x):
    return x if isinstance(x, dict) else {}


def _list(x):
    return x if isinstance(x, list) else []


def _str(x):
    return x if isinstance(x, str) else ""


def _addr(x):
    """A usable non-negative 64-bit address/offset, else 0."""
    return x if isinstance(x, int) and not isinstance(x, bool) and 0 <= x < 2 ** 64 else 0


def is_system_image(img):
    path = _str(img.get("path"))
    name = _str(img.get("name"))
    if path:
        return path.startswith(SYSTEM_PREFIXES)
    return not (name in APP_IMAGE_NAMES or "Kit" in name)


def faulting_frames(report, symbolicate_fn):
    """Return (thread, [{index, name, symbol, system, resolved}])."""
    body = report["body"]
    threads = _list(body.get("threads"))
    ft = body.get("faultingThread")
    thread = _dict(threads[ft]) if isinstance(ft, int) and 0 <= ft < len(threads) else {}
    images = _list(body.get("usedImages"))
    raw = _list(thread.get("frames"))
    items, metas = [], []
    for f in raw:
        f = _dict(f)
        ii = f.get("imageIndex")
        img = _dict(images[ii]) if isinstance(ii, int) and 0 <= ii < len(images) else {}
        base = _addr(img.get("base"))
        off = _addr(f.get("imageOffset"))
        items.append({"uuid": _str(img.get("uuid")), "base": base, "offset": off})
        metas.append((f, img, off))
    resolved = symbolicate_fn(report, items) if (symbolicate_fn and items) else [None] * len(items)
    out = []
    for i, ((f, img, off), res) in enumerate(zip(metas, resolved)):
        name = _str(img.get("name")) or "???"
        if res:
            symbol = res
        elif _str(f.get("symbol")):
            symbol = f["symbol"]
            if f.get("symbolLocation") is not None:
                symbol += " + %s" % f["symbolLocation"]
        else:
            symbol = "%s + %s" % (name, off)
        out.append({"index": i, "name": name, "symbol": symbol,
                    "system": is_system_image(img), "resolved": bool(res)})
    return thread, out


def build_event(report, symbolicate_fn=None):
    h, body = report["header"], report["body"]
    thread, frames = faulting_frames(report, symbolicate_fn)
    frame_strs = ["%d %s: %s" % (f["index"], f["name"], f["symbol"]) for f in frames]
    app_frames = [f for f in frames if not f["system"]]
    top = [f["symbol"] for f in app_frames[:3]]
    top_strs = ["%d %s: %s" % (f["index"], f["name"], f["symbol"]) for f in app_frames[:3]]
    symbolicated = any(f["resolved"] and not f["system"] for f in frames)

    cap = capture_time(report)
    launch = parse_time(body.get("procLaunch"))
    now = datetime.datetime.now(datetime.timezone.utc)
    dt = (cap or now).astimezone(datetime.timezone.utc)
    exc = _dict(body.get("exception"))
    term = _dict(body.get("termination"))
    osv = _dict(body.get("osVersion"))
    queue = _str(thread.get("queue"))
    app_name = h.get("app_name") or body.get("procName") or ""
    build = h.get("build_version")

    event = {
        "dt": dt.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "message": 'event=crash_report app="%s" build=%s exception=%s signal=%s queue="%s" top="%s"' % (
            app_name, build, exc.get("type"), exc.get("signal"), queue, " < ".join(top)),
        "event": "crash_report",
        "ingest": "mac_crash_ingest",
        "incident_id": str(incident_id(report)),
        "app_name": app_name,
        "proc_name": body.get("procName"),
        "bundle_id": h.get("bundleID"),
        "app_version": h.get("app_version"),
        "build": build,
        "os_version": "%s (%s)" % (osv.get("train"), osv.get("build")),
        "model": body.get("modelCode"),
        "exception_type": exc.get("type"),
        "exception_signal": exc.get("signal"),
        "exception_codes": exc.get("codes"),
        "termination_indicator": term.get("indicator"),
        "termination_namespace": term.get("namespace"),
        "termination_code": term.get("code"),
        "faulting_thread_index": body.get("faultingThread"),
        "faulting_thread_queue": queue,
        "faulting_thread_name": thread.get("name"),
        "symbolicated": symbolicated,
        "frames": frame_strs[:MAX_FRAMES],
        "top_app_frames": top_strs,
    }
    reasons = term.get("reasons")
    if isinstance(reasons, list) and reasons:
        event["termination_reasons"] = " | ".join(str(r) for r in reasons)
    if cap and launch:
        event["seconds_since_launch"] = round((cap - launch).total_seconds(), 1)
    return event


# ------------------------------------------------------------------- posting

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: urllib would resend Authorization to the target."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def default_opener():
    return urllib.request.build_opener(_NoRedirect).open


def post_events(events, host, token, opener=None, on_batch=None):
    """POST in batches. Returns (events_sent, error_message_or_None).

    on_batch(batch) is called after each successfully posted batch."""
    opener = opener or default_opener()
    url = host.rstrip("/")
    sent = 0

    def scrub(s):
        return s.replace(token, "***") if token else s

    for i in range(0, len(events), BATCH_SIZE):
        batch = events[i:i + BATCH_SIZE]
        req = urllib.request.Request(
            url, data=json.dumps(batch).encode("utf-8"), method="POST",
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + token})
        try:
            resp = opener(req, timeout=30)
            status = getattr(resp, "status", None) or resp.getcode()
            body = ""
            if not 200 <= status < 300:
                body = resp.read().decode("utf-8", "replace")
            try:
                resp.close()
            except Exception:
                pass
        except urllib.error.HTTPError as e:
            status = e.code
            body = ""
            if not 300 <= status < 400:  # redirect bodies/headers: status only
                try:
                    body = e.read().decode("utf-8", "replace")
                except Exception:
                    body = ""
            try:
                e.close()
            except Exception:
                pass
        except Exception as e:  # network errors etc.; never leak the token
            return sent, scrub("post failed: %s" % (getattr(e, "reason", None) or e))
        if not 200 <= status < 300:
            if 300 <= status < 400:
                return sent, "post failed: status %s (redirect refused)" % status
            return sent, scrub("post failed: status %s: %s" % (status, body[:200]))
        sent += len(batch)
        if on_batch:
            on_batch(batch)
    return sent, None


def keychain_get(runner, service, account):
    rc, out, _err = runner(["security", "find-generic-password", "-s", service,
                            "-a", account, "-w"], timeout=30)
    value = out.strip() if rc == 0 else ""
    return value or None


# --------------------------------------------------------------- device pull

def pull_device(staging, runner=run_cmd):
    os.makedirs(staging, exist_ok=True)
    # Always -k: without it idevicecrashreport deletes reports from the phone.
    base = ["idevicecrashreport", "-k"]
    tail = ["-f", "Trio", staging]
    for extra in ([], ["-n"]):
        rc, out, err = runner(base + extra + tail, timeout=TIMEOUT_DEVICE)
        if rc == 0 and "No device" not in (out + err):
            return "ok"
        print("trio-crash-ingest: idevicecrashreport%s failed (rc=%s)" % (
            " -n" if extra else "", rc), file=sys.stderr)
    return "unreachable"


# ---------------------------------------------------------------------- main

def find_ips(root):
    found = []
    for dirpath, _dirs, files in os.walk(root):
        found.extend(os.path.join(dirpath, f) for f in files if f.endswith(".ips"))
    return sorted(found)


def main(argv=None, runner=None, opener=None):
    return _main(argv, runner, opener)


def _main(argv, runner, opener):
    ap = argparse.ArgumentParser(prog="trio-crash-ingest")
    ap.add_argument("--from", dest="from_dirs", action="append", default=[], metavar="DIR")
    ap.add_argument("--no-device", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-age-days", type=float, default=30)
    ap.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    ap.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    ap.add_argument("--repo", default="cachrisman/Trio")
    ap.add_argument("--keychain-service", default="trio-crash-ingest")
    args = ap.parse_args(argv)
    runner = runner or run_cmd
    opener = opener or default_opener()
    state_dir = os.path.expanduser(args.state_dir)
    cache_dir = os.path.expanduser(args.cache_dir)

    os.makedirs(state_dir, exist_ok=True)
    lock = open(os.path.join(state_dir, "lock"), "a")
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        lock.close()
        print("trio-crash-ingest: another run in progress")
        return 0
    try:
        return _run(args, runner, opener, state_dir, cache_dir)
    finally:
        lock.close()  # releases the flock


def _run(args, runner, opener, state_dir, cache_dir):

    token = host = None
    if not args.dry_run:
        token = keychain_get(runner, args.keychain_service, "betterstack-token")
        if not token:
            print("trio-crash-ingest: BetterStack token missing from the login Keychain. Add it with:\n"
                  "  security add-generic-password -s %s -a betterstack-token -w" % args.keychain_service,
                  file=sys.stderr)
            return 2
        host = keychain_get(runner, args.keychain_service, "betterstack-host") or DEFAULT_HOST
        if not host.startswith("https://"):
            print("trio-crash-ingest: refusing non-https BetterStack host", file=sys.stderr)
            return 2

    device = "skipped"
    dirs = list(args.from_dirs)
    if not args.no_device:
        staging = os.path.join(state_dir, "staging")
        device = pull_device(staging, runner)
        dirs.append(staging)

    c = dict(files=0, bad=0, skipped_type=0, old=0, duplicate=0, new=0, sent=0,
             unsymbolicated=0, deferred=0)
    state = load_state(state_dir)
    already = state["incident_ids"]
    seen = set()
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=args.max_age_days)
    sym = Symbolicator(cache_dir, args.repo, runner)
    events = []

    for d in dirs:
        for path in find_ips(d):
            c["files"] += 1
            report = parse_ips(path)
            if report is None:
                c["bad"] += 1
                continue
            if not is_trio_crash(report):
                c["skipped_type"] += 1
                continue
            cap = capture_time(report)
            if cap and cap < cutoff:
                c["old"] += 1
                continue
            try:
                iid = str(incident_id(report))
                if iid in seen or iid in already:
                    c["duplicate"] += 1
                    continue
                seen.add(iid)
                event = build_event(report, sym.symbolicate)
            except Deferred as e:
                print("trio-crash-ingest: deferred %s: %s" % (iid, e), file=sys.stderr)
                c["deferred"] += 1
                continue
            except (KeyError, TypeError, AttributeError, ValueError, IndexError) as e:
                print("trio-crash-ingest: bad report %s: %s" % (path, e), file=sys.stderr)
                c["bad"] += 1
                continue
            c["new"] += 1
            if not event["symbolicated"]:
                c["unsymbolicated"] += 1
            events.append(event)

    rc = 0
    if args.dry_run:
        for e in events:
            print(json.dumps(e, sort_keys=True))
    elif events:
        def persist(batch):
            now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
            for e in batch:
                already[e["incident_id"]] = now
            save_state(state_dir, state)

        n, err = post_events(events, host, token, opener, on_batch=persist)
        c["sent"] = n
        if err:
            print("trio-crash-ingest: " + err, file=sys.stderr)
            rc = 1

    line = ("trio-crash-ingest: device=%s files=%d bad=%d skipped_type=%d old=%d duplicate=%d "
            "new=%d sent=%d unsymbolicated=%d" % (
                device, c["files"], c["bad"], c["skipped_type"], c["old"], c["duplicate"],
                c["new"], c["sent"], c["unsymbolicated"]))
    if c["deferred"]:
        line += " deferred=%d" % c["deferred"]
    print(line)
    return rc


if __name__ == "__main__":
    sys.exit(main())
