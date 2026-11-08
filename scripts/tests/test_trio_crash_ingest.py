import contextlib
import fcntl
import importlib.util
import io
import json
import os
import tempfile
import unittest
import urllib.error
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "trio-crash-ingest.py")
spec = importlib.util.spec_from_file_location("trio_crash_ingest", SCRIPT)
tci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tci)

TOKEN = "s3cr3t-token-value"
UUID = "04F19366-638A-3F5C-BE30-52C8A70D3F23"
OLD_ARGS = ["--max-age-days", "100000"]


def make_ips(directory, name, header=None, body=None, incident="INC-1"):
    h = {"app_name": "Trio Watch App", "app_version": "1.0.2", "build_version": "237",
         "bug_type": "309", "bundleID": "org.nightscout.TEAM.trio.watchkitapp",
         "incident_id": incident, "os_version": "watchOS 26", "timestamp": "2026-11-08 10:40:00.00 +0100"}
    h.update(header or {})
    b = {
        "captureTime": "2026-11-08 10:39:55.9937 +0100",
        "procLaunch": "2026-11-08 10:39:45.9937 +0100",
        "procName": "Trio Watch App",
        "modelCode": "Watch8,1",
        "osVersion": {"train": "watchOS 26.1", "build": "23S1"},
        "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "codes": "0x1"},
        "termination": {"indicator": "Segmentation fault", "namespace": "SIGNAL", "code": 11,
                        "reasons": ["a", "b"]},
        "faultingThread": 1,
        "threads": [
            {"frames": []},
            {"queue": "com.apple.main-thread", "name": "main", "triggered": True, "frames": [
                {"imageIndex": 0, "imageOffset": 16, "symbol": "libsystem_kernel", "symbolLocation": 8},
                {"imageIndex": 1, "imageOffset": 256},
                {"imageIndex": 1, "imageOffset": 512},
                {"imageIndex": 2, "imageOffset": 64, "symbol": "swift_retain", "symbolLocation": 4},
            ]},
        ],
        "usedImages": [
            {"uuid": "aaaa", "base": 4096, "name": "libsystem_kernel.dylib",
             "path": "/usr/lib/system/libsystem_kernel.dylib"},
            {"uuid": UUID, "base": 1048576, "name": "Trio Watch App", "arch": "arm64"},
            {"uuid": "bbbb", "base": 8192, "name": "libswiftCore.dylib",
             "path": "/usr/lib/swift/libswiftCore.dylib"},
        ],
    }
    b.update(body or {})
    path = os.path.join(directory, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(json.dumps(h) + "\n" + json.dumps(b))
    return path


class FakeAtosRunner:
    def __init__(self):
        self.calls = []

    def __call__(self, args, timeout=0):
        self.calls.append(args)
        addrs = args[args.index("-l") + 2:]
        return 0, "".join("func_%s (in Trio) (F.swift:1)\n" % a for a in addrs), ""


def prefilled_symbolicator(runner):
    s = tci.Symbolicator("/nonexistent", "o/r", runner)
    s._maps["trio-v1.0.2-237-localCI"] = {UUID.lower(): ("/dw/Trio", "arm64")}
    return s


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.src = os.path.join(self.tmp, "src")
        self.state = os.path.join(self.tmp, "state")
        self.cache = os.path.join(self.tmp, "cache")
        os.makedirs(self.src)

    def tearDown(self):
        self._tmp.cleanup()

    def run_main(self, extra, runner=None, opener=None):
        argv = ["--no-device", "--from", self.src, "--state-dir", self.state,
                "--cache-dir", self.cache] + OLD_ARGS + extra
        out, err = io.StringIO(), io.StringIO()
        if runner is None:  # never reach real gh/security/atos from a test
            runner = self.runner()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = tci.main(argv, runner=runner, opener=opener)
        return rc, out.getvalue(), err.getvalue()

    def runner(self, gh=(1, "", "release not found")):
        def run(args, timeout=0):
            if args[0] == "security":
                return (0, TOKEN + "\n", "") if "betterstack-token" in args else (1, "", "")
            if args[0] == "gh":
                return gh
            return 1, "", ""
        return run


class ParsingTests(Base):
    def test_parse_and_filter(self):
        p = make_ips(self.src, "a.ips")
        r = tci.parse_ips(p)
        self.assertEqual(r["header"]["app_version"], "1.0.2")
        self.assertIn("threads", r["body"])
        self.assertTrue(tci.is_trio_crash(r))
        bad = os.path.join(self.src, "bad.ips")
        with open(bad, "w") as f:
            f.write("not json\nnope")
        self.assertIsNone(tci.parse_ips(bad))

    def test_filtering(self):
        r = tci.parse_ips(make_ips(self.src, "b.ips", header={"bug_type": "225"}))
        self.assertFalse(tci.is_trio_crash(r))
        r = tci.parse_ips(make_ips(self.src, "c.ips", header={"app_name": "Other", "bundleID": "com.x.y"}))
        self.assertFalse(tci.is_trio_crash(r))
        r = tci.parse_ips(make_ips(self.src, "d.ips", header={"app_name": "Other"}))
        self.assertTrue(tci.is_trio_crash(r))  # nightscout bundle containing "trio"
        r = tci.parse_ips(make_ips(self.src, "e.ips", header={"app_name": ["Trio"], "bundleID": "com.x.y"}))
        self.assertFalse(tci.is_trio_crash(r))  # unhashable app_name must not raise

    def test_counts_bad_and_skipped(self):
        make_ips(self.src, "a.ips")
        make_ips(self.src, "b.ips", header={"bug_type": "225"}, incident="INC-2")
        with open(os.path.join(self.src, "bad.ips"), "w") as f:
            f.write("garbage")
        rc, out, _ = self.run_main(["--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("files=3 bad=1 skipped_type=1 old=0 duplicate=0 new=1 sent=0 unsymbolicated=1", out)


class EventTests(Base):
    def test_dt_and_seconds_since_launch(self):
        ev = tci.build_event(tci.parse_ips(make_ips(self.src, "a.ips")))
        self.assertEqual(ev["dt"], "2026-11-08T09:39:55.993Z")
        self.assertEqual(ev["seconds_since_launch"], 10.0)
        self.assertEqual(ev["termination_reasons"], "a | b")
        self.assertEqual(ev["os_version"], "watchOS 26.1 (23S1)")

    def test_missing_launch_omits_seconds(self):
        ev = tci.build_event(tci.parse_ips(make_ips(self.src, "a.ips", body={"procLaunch": None})))
        self.assertNotIn("seconds_since_launch", ev)

    def test_symbolicated_frames_batched_per_image(self):
        runner = FakeAtosRunner()
        sym = prefilled_symbolicator(runner)
        ev = tci.build_event(tci.parse_ips(make_ips(self.src, "a.ips")), sym.symbolicate)
        self.assertEqual(len(runner.calls), 1)
        call = runner.calls[0]
        self.assertEqual(call[:7], ["atos", "-arch", "arm64", "-o", "/dw/Trio", "-l", hex(1048576)])
        self.assertEqual(call[7:], [hex(1048576 + 256), hex(1048576 + 512)])
        self.assertTrue(ev["symbolicated"])
        self.assertEqual(ev["frames"][1], "1 Trio Watch App: func_%s (in Trio) (F.swift:1)" % hex(1048576 + 256))
        self.assertEqual(ev["frames"][2].split(": ")[1], "func_%s (in Trio) (F.swift:1)" % hex(1048576 + 512))
        self.assertEqual(ev["frames"][0], "0 libsystem_kernel.dylib: libsystem_kernel + 8")
        self.assertEqual(len(ev["top_app_frames"]), 2)
        self.assertIn(' < ', ev["message"])
        self.assertTrue(ev["message"].startswith(
            'event=crash_report app="Trio Watch App" build=237 exception=EXC_BAD_ACCESS signal=SIGSEGV '
            'queue="com.apple.main-thread" top="func_'))

    def test_unsymbolicated_fallback(self):
        ev = tci.build_event(tci.parse_ips(make_ips(self.src, "a.ips")), None)
        self.assertFalse(ev["symbolicated"])
        self.assertEqual(ev["frames"][1], "1 Trio Watch App: Trio Watch App + 256")
        self.assertEqual(ev["frames"][3], "3 libswiftCore.dylib: swift_retain + 4")
        self.assertEqual(ev["top_app_frames"], ["1 Trio Watch App: Trio Watch App + 256",
                                                "2 Trio Watch App: Trio Watch App + 512"])
        self.assertIn('top="Trio Watch App + 256 < Trio Watch App + 512"', ev["message"])


class RunTests(Base):
    def test_duplicate_across_files(self):
        make_ips(self.src, "a.ips")
        make_ips(self.src, "sub/ProxiedDevice-x/a2.ips")
        rc, out, _ = self.run_main(["--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("duplicate=1 new=1", out)
        self.assertEqual(len([l for l in out.splitlines() if l.startswith("{")]), 1)

    def test_already_sent_skipped(self):
        make_ips(self.src, "a.ips")
        os.makedirs(self.state)
        with open(os.path.join(self.state, "sent.json"), "w") as f:
            json.dump({"incident_ids": {"INC-1": "2026-11-08T00:00:00"}}, f)
        calls = []
        rc, out, _ = self.run_main([], self.runner(), lambda *a, **k: calls.append(a))
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])
        self.assertIn("duplicate=1 new=0 sent=0", out)

    def test_dry_run_no_state_no_post(self):
        make_ips(self.src, "a.ips")
        calls = []
        rc, out, _ = self.run_main(["--dry-run"], self.runner(), lambda *a, **k: calls.append(a))
        self.assertEqual(rc, 0)
        self.assertEqual(calls, [])
        self.assertFalse(os.path.exists(os.path.join(self.state, "sent.json")))

    def test_success_marks_ids(self):
        make_ips(self.src, "a.ips")
        reqs = []

        class Resp:
            status = 202

            def read(self):
                return b""

            def close(self):
                pass

        def opener(req, timeout=0):
            reqs.append(req)
            return Resp()

        rc, out, _ = self.run_main([], self.runner(), opener)
        self.assertEqual(rc, 0)
        self.assertIn("sent=1", out)
        self.assertEqual(reqs[0].get_header("Authorization"), "Bearer " + TOKEN)
        self.assertEqual(len(json.loads(reqs[0].data)), 1)
        self.assertIn("INC-1", tci.load_state(self.state)["incident_ids"])

    def test_post_failure(self):
        make_ips(self.src, "a.ips")

        def opener(req, timeout=0):
            raise urllib.error.HTTPError(req.full_url, 500, "err", {},
                                         io.BytesIO(("boom " + TOKEN + " " + "x" * 500).encode()))

        rc, out, err = self.run_main([], self.runner(), opener)
        self.assertEqual(rc, 1)
        self.assertNotIn(TOKEN, out + err)
        self.assertIn("500", err)
        self.assertNotIn("INC-1", tci.load_state(self.state)["incident_ids"])

    def test_network_error_does_not_leak_token(self):
        err_msg = tci.post_events([{"a": 1}], "https://h", TOKEN,
                                  lambda req, timeout=0: (_ for _ in ()).throw(OSError("bad " + TOKEN)))[1]
        self.assertNotIn(TOKEN, err_msg)

    def test_missing_token_exit_2(self):
        make_ips(self.src, "a.ips")
        rc, out, err = self.run_main([], lambda args, timeout=0: (44, "", ""))
        self.assertEqual(rc, 2)
        self.assertIn("security add-generic-password -s trio-crash-ingest -a betterstack-token -w", err)

    def test_batches_of_50(self):
        sizes = []

        class Resp:
            status = 200

            def read(self):
                return b""

        def opener(req, timeout=0):
            sizes.append(len(json.loads(req.data)))
            return Resp()

        n, err = tci.post_events([{"i": i} for i in range(120)], "https://h", TOKEN, opener)
        self.assertEqual((n, err, sizes), (120, None, [50, 50, 20]))


class DeviceTests(Base):
    def test_k_always_and_retry_with_n(self):
        calls = []

        def run(args, timeout=0):
            calls.append(args)
            return (1, "", "No device found") if len(calls) == 1 else (0, "", "")

        with contextlib.redirect_stderr(io.StringIO()):
            status = tci.pull_device(os.path.join(self.tmp, "stg"), run)
        self.assertEqual(status, "ok")
        self.assertEqual(len(calls), 2)
        for c in calls:
            self.assertIn("-k", c)
            self.assertNotIn("--remove-all", c)
        self.assertNotIn("-n", calls[0])
        self.assertIn("-n", calls[1])

    def test_unreachable(self):
        with contextlib.redirect_stderr(io.StringIO()):
            status = tci.pull_device(os.path.join(self.tmp, "stg"), lambda a, timeout=0: (1, "No device", ""))
        self.assertEqual(status, "unreachable")


class SymbolicatorFetchTests(Base):
    def report(self):
        return tci.parse_ips(make_ips(self.src, "a.ips"))

    def test_missing_release_marker(self):
        sym = tci.Symbolicator(self.cache, "o/r", lambda a, timeout=0: (1, "", "release not found"))
        self.assertEqual(sym.symbolicate(self.report(), [{"uuid": UUID, "base": 1, "offset": 1}]), [None])
        self.assertTrue(os.path.exists(os.path.join(self.cache, "trio-v1.0.2-237-localCI", "MISSING")))

    def test_release_without_dsym_asset_is_missing(self):
        sym = tci.Symbolicator(self.cache, "o/r",
                               lambda a, timeout=0: (1, "", "no assets match the file pattern"))
        self.assertEqual(sym.symbolicate(self.report(), [{"uuid": UUID, "base": 1, "offset": 1}]), [None])
        self.assertTrue(os.path.exists(os.path.join(self.cache, "trio-v1.0.2-237-localCI", "MISSING")))

    def test_other_gh_error_defers(self):
        sym = tci.Symbolicator(self.cache, "o/r", lambda a, timeout=0: (1, "", "dial tcp: timeout"))
        with self.assertRaises(tci.Deferred):
            sym.symbolicate(self.report(), [{"uuid": UUID, "base": 1, "offset": 1}])
        self.assertFalse(os.path.exists(os.path.join(self.cache, "trio-v1.0.2-237-localCI", "MISSING")))

    def test_deferred_in_main(self):
        make_ips(self.src, "a.ips")
        rc, out, _ = self.run_main(["--dry-run"], lambda a, timeout=0: (1, "", "network down"))
        self.assertEqual(rc, 0)
        self.assertIn("new=0", out)
        self.assertIn("deferred=1", out)

    def test_download_unzip_and_atos(self):
        tag = "trio-v1.0.2-237-localCI"
        calls = []

        def run(args, timeout=0):
            calls.append(args[0])
            if args[0] == "gh":
                d = args[args.index("-D") + 1]
                with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                    z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                return 0, "UUID: %s (arm64) %s\n" % (UUID, args[-1]), ""
            if args[0] == "atos":
                return 0, "main (in Trio) (App.swift:3)\n", ""
            return 1, "", ""

        sym = tci.Symbolicator(self.cache, "o/r", run)
        res = sym.symbolicate(self.report(), [{"uuid": UUID.lower(), "base": 4096, "offset": 8}])
        self.assertEqual(res, ["main (in Trio) (App.swift:3)"])
        self.assertEqual(calls, ["gh", "dwarfdump", "atos"])
        self.assertTrue(os.path.isdir(os.path.join(self.cache, tag, "dsym")))


class RedirectTests(Base):
    def test_default_opener_refuses_redirect_and_keeps_token_home(self):
        import http.server
        import threading

        seen = []

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append((self.path, self.headers.get("Authorization")))
                self.send_response(307)
                self.send_header("Location", "/other")
                self.end_headers()

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        th = threading.Thread(target=srv.serve_forever, daemon=True)
        th.start()
        try:
            n, err = tci.post_events([{"a": 1}], "http://127.0.0.1:%d" % srv.server_port, TOKEN)
        finally:
            srv.shutdown()
            srv.server_close()
        self.assertEqual(n, 0)
        self.assertIn("307", err)
        self.assertNotIn(TOKEN, err)
        self.assertEqual([p for p, _ in seen], ["/"])  # /other never requested

    def test_redirect_handler_returns_no_request(self):
        h = tci._NoRedirect()
        req = urllib.request.Request("https://h", data=b"x", method="POST")
        self.assertIsNone(h.redirect_request(req, None, 302, "Found", {}, "http://evil/"))


class PersistenceAndLockTests(Base):
    def test_state_saved_after_each_batch(self):
        for i in range(3):
            make_ips(self.src, "a%d.ips" % i, incident="INC-%d" % i)
        saved = []
        orig = tci.save_state

        def spy(state_dir, state):
            saved.append(sorted(state["incident_ids"]))
            orig(state_dir, state)

        class Resp:
            status = 200

            def read(self):
                return b""

        calls = []

        def opener(req, timeout=0):
            calls.append(1)
            if len(calls) == 2:
                raise OSError("down")
            return Resp()

        old_bs = tci.BATCH_SIZE
        tci.BATCH_SIZE = 2
        tci.save_state = spy
        try:
            for i in range(3, 5):
                make_ips(self.src, "a%d.ips" % i, incident="INC-%d" % i)
            rc, _, _ = self.run_main([], self.runner(), opener)
        finally:
            tci.BATCH_SIZE = old_bs
            tci.save_state = orig
        self.assertEqual(rc, 1)
        self.assertEqual(len(saved), 1)  # first batch persisted before second failed
        self.assertEqual(len(tci.load_state(self.state)["incident_ids"]), 2)

    def test_lock_held_exits_zero(self):
        make_ips(self.src, "a.ips")
        os.makedirs(self.state)
        with open(os.path.join(self.state, "lock"), "a") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            calls = []
            rc, out, _ = self.run_main([], self.runner(), lambda *a, **k: calls.append(a))
        self.assertEqual(rc, 0)
        self.assertIn("trio-crash-ingest: another run in progress", out)
        self.assertEqual(calls, [])
        # lock released after a normal run
        rc, out, _ = self.run_main(["--dry-run"])
        self.assertNotIn("another run", out)

    def test_dry_run_takes_lock(self):
        make_ips(self.src, "a.ips")
        os.makedirs(self.state)
        with open(os.path.join(self.state, "lock"), "a") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            rc, out, _ = self.run_main(["--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("another run in progress", out)


class MalformedReportTests(Base):
    def test_wrong_nested_types_do_not_raise(self):
        bodies = [
            {"threads": "nope"},
            {"threads": [5, None], "faultingThread": 0},
            {"threads": [{"frames": "x"}], "faultingThread": 0},
            {"threads": [{"frames": [1, None, "s"]}], "faultingThread": 0},
            {"threads": [{"frames": [{"imageIndex": "0", "imageOffset": "9"}]}], "faultingThread": 0},
            {"threads": [{"frames": [{"imageIndex": 99, "imageOffset": -5}]}], "faultingThread": 0},
            {"threads": [{"frames": [{"imageIndex": 0, "imageOffset": 2 ** 80, "symbol": 7}]}],
             "faultingThread": 0, "usedImages": [None]},
            {"threads": [{"frames": [{"imageIndex": 0}], "queue": 3}], "faultingThread": 0,
             "usedImages": [{"path": 5, "name": 6, "uuid": 7, "base": "x"}]},
            {"exception": "x", "termination": [], "osVersion": 3},
        ]
        for i, b in enumerate(bodies):
            r = tci.parse_ips(make_ips(self.src, "m%d.ips" % i, body=b))
            ev = tci.build_event(r, prefilled_symbolicator(FakeAtosRunner()).symbolicate)
            self.assertEqual(ev["event"], "crash_report")

    def test_main_tolerates_odd_typed_fields(self):
        make_ips(self.src, "a.ips", incident="INC-A", header={"incident_id": ["unhashable"]})
        make_ips(self.src, "b.ips", incident="INC-B", body={"captureTime": 5, "procLaunch": 5,
                                                              "exception": {"type": []}})
        make_ips(self.src, "c.ips", incident="INC-C")
        rc, out, _ = self.run_main(["--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("new=3", out)  # odd-typed fields are tolerated, not fatal

    def test_main_catches_event_errors(self):
        make_ips(self.src, "a.ips", incident="INC-A")
        make_ips(self.src, "b.ips", incident="INC-B")
        orig = tci.build_event

        def boom(report, fn=None):
            if report["header"]["incident_id"] == "INC-A":
                raise IndexError("x")
            return orig(report, fn)

        tci.build_event = boom
        try:
            rc, out, _ = self.run_main(["--dry-run"])
        finally:
            tci.build_event = orig
        self.assertEqual(rc, 0)
        self.assertIn("bad=1", out)
        self.assertIn("new=1", out)


class DownloadRecoveryTests(Base):
    TAG = "trio-v1.0.2-237-localCI"

    def report(self):
        return tci.parse_ips(make_ips(self.src, "a.ips"))

    def test_leftovers_removed_and_clobber_passed(self):
        d = os.path.join(self.cache, self.TAG)
        os.makedirs(os.path.join(d, "dsym.partial", "junk"))
        with open(os.path.join(d, "Trio.app.dSYM.zip"), "w") as f:
            f.write("stale")
        with open(os.path.join(d, "other.partial"), "w") as f:
            f.write("x")
        gh_args = []

        def run(args, timeout=0):
            if args[0] == "gh":
                gh_args.append(args)
                self.assertFalse(os.path.exists(os.path.join(d, "Trio.app.dSYM.zip")))
                self.assertFalse(os.path.exists(os.path.join(d, "dsym.partial")))
                self.assertFalse(os.path.exists(os.path.join(d, "other.partial")))
                with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                    z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                return 0, "UUID: %s (arm64) %s\n" % (UUID, args[-1]), ""
            return 1, "", ""

        sym = tci.Symbolicator(self.cache, "o/r", run)
        sym.symbolicate(self.report(), [{"uuid": UUID, "base": 1, "offset": 1}])
        self.assertIn("--clobber", gh_args[0])
        self.assertTrue(os.path.isdir(os.path.join(d, "dsym")))

    def test_bad_zip_cleans_up_and_defers_then_retry_works(self):
        d = os.path.join(self.cache, self.TAG)
        state = {"good": False}

        def run(args, timeout=0):
            if args[0] == "gh":
                with open(os.path.join(d, "Trio.app.dSYM.zip"), "wb") as f:
                    if not state["good"]:
                        f.write(b"not a zip")
                if state["good"]:
                    with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                        z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                return 0, "UUID: %s (arm64) %s\n" % (UUID, args[-1]), ""
            return 1, "", ""

        sym = tci.Symbolicator(self.cache, "o/r", run)
        items = [{"uuid": UUID, "base": 1, "offset": 1}]
        with self.assertRaises(tci.Deferred):
            sym.symbolicate(self.report(), items)
        self.assertFalse(os.path.exists(os.path.join(d, "Trio.app.dSYM.zip")))
        self.assertFalse(os.path.exists(os.path.join(d, "dsym")))
        self.assertFalse(os.path.exists(os.path.join(d, "MISSING")))
        state["good"] = True
        sym.symbolicate(self.report(), items)
        self.assertTrue(os.path.isdir(os.path.join(d, "dsym")))


if __name__ == "__main__":
    unittest.main()
