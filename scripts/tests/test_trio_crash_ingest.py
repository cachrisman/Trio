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
    s._maps["trio-v1.0.2-237-cloudCI"] = None
    s._maps["trio-v1.0.2-237-local"] = None
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
        err_msg = tci.post_events([{"a": 1}], tci.DEFAULT_HOST, TOKEN,
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

        n, err = tci.post_events([{"i": i} for i in range(120)], tci.DEFAULT_HOST, TOKEN, opener)
        self.assertEqual((n, err, sizes), (120, None, [50, 50, 20]))


class StatusEventTests(Base):
    def opener(self, reqs, fail_on=None):
        class Resp:
            status = 202

            def read(self):
                return b""

            def close(self):
                pass

        def op(req, timeout=0):
            reqs.append(req)
            if fail_on is not None and len(reqs) == fail_on:
                raise urllib.error.HTTPError(req.full_url, 500, "err", {},
                                             io.BytesIO(("boom " + TOKEN).encode()))
            return Resp()
        return op

    def test_flag_off_no_crashes_no_posts(self):
        reqs = []
        rc, out, _ = self.run_main([], self.runner(), self.opener(reqs))
        self.assertEqual((rc, reqs), (0, []))
        self.assertNotIn("status=", out)

    def test_flag_on_no_crashes_one_post(self):
        reqs = []
        rc, out, _ = self.run_main(["--status-event"], self.runner(), self.opener(reqs))
        self.assertEqual(rc, 0)
        self.assertEqual(len(reqs), 1)
        events = json.loads(reqs[0].data)
        self.assertEqual(len(events), 1)
        e = events[0]
        self.assertEqual(e["event"], "crash_ingest_run")
        self.assertEqual(e["ingest"], "mac_crash_ingest")
        self.assertEqual(e["device"], "skipped")
        self.assertIs(e["crash_post_error"], False)
        for k in ("files", "bad", "skipped_type", "old", "duplicate", "new", "sent",
                  "unsymbolicated", "deferred"):
            self.assertEqual(e[k], 0)
        self.assertTrue(e["dt"].endswith("Z"))
        self.assertTrue(out.rstrip().endswith(" status=sent"))
        self.assertEqual(e["message"] + " status=sent", out.rstrip())

    def test_flag_on_with_crashes_status_last(self):
        make_ips(self.src, "a.ips")
        make_ips(self.src, "b.ips", incident="INC-2")
        reqs = []
        rc, out, _ = self.run_main(["--status-event"], self.runner(), self.opener(reqs))
        self.assertEqual(rc, 0)
        self.assertEqual(len(reqs), 2)
        crashes = json.loads(reqs[0].data)
        self.assertEqual({e["event"] for e in crashes}, {"crash_report"})
        status = json.loads(reqs[1].data)
        self.assertEqual(len(status), 1)
        self.assertEqual(status[0]["event"], "crash_ingest_run")
        self.assertEqual(status[0]["sent"], len(crashes))
        self.assertEqual(status[0]["new"], 2)
        self.assertEqual(set(tci.load_state(self.state)["incident_ids"]), {"INC-1", "INC-2"})

    def test_status_post_failure(self):
        make_ips(self.src, "a.ips")
        reqs = []
        rc, out, err = self.run_main(["--status-event"], self.runner(),
                                     self.opener(reqs, fail_on=2))
        self.assertEqual(rc, 1)
        self.assertNotIn(TOKEN, out + err)
        self.assertIn("trio-crash-ingest: status post failed", err)
        self.assertTrue(out.rstrip().endswith(" status=failed"))
        self.assertEqual(set(tci.load_state(self.state)["incident_ids"]), {"INC-1"})

    def test_status_failure_no_crashes_leaves_state_untouched(self):
        reqs = []
        rc, _, err = self.run_main(["--status-event"], self.runner(),
                                   self.opener(reqs, fail_on=1))
        self.assertEqual(rc, 1)
        self.assertNotIn(TOKEN, err)
        self.assertEqual(tci.load_state(self.state)["incident_ids"], {})

    def test_dry_run_prints_status_json(self):
        make_ips(self.src, "a.ips")
        reqs = []
        rc, out, _ = self.run_main(["--dry-run", "--status-event"], self.runner(),
                                   self.opener(reqs))
        self.assertEqual(rc, 0)
        self.assertEqual(reqs, [])
        objs = [json.loads(l) for l in out.splitlines() if l.startswith("{")]
        self.assertEqual([o["event"] for o in objs], ["crash_report", "crash_ingest_run"])
        self.assertEqual(objs[1]["new"], 1)
        self.assertFalse(os.path.exists(os.path.join(self.state, "sent.json")))


def _dev(udid, platform="iOS", reality="physical", pairing="paired"):
    return {"hardwareProperties": {"platform": platform, "udid": udid, "reality": reality},
            "connectionProperties": {"pairingState": pairing}}


def _dev_props(udid, platform="iOS", reality="physical", pairing="paired"):
    return {"properties": {"hardware": {"platform": platform, "udid": udid, "reality": reality},
                           "connection": {"pairingState": pairing}}}


def _f(rel, is_dir=False):
    return {"relativePath": rel, "resources": {"isDirectory": is_dir}}


class FakeDevicectl:
    def __init__(self, devices=None, files=None, list_rc=0, files_rc=0,
                 devices_raw=None, fail_copy=(), refuse_existing=False):
        self.refuse_existing = refuse_existing
        self.devices, self.files = devices or [], files or []
        self.list_rc, self.files_rc = list_rc, files_rc
        self.devices_raw, self.fail_copy = devices_raw, fail_copy
        self.calls, self.json_paths = [], []

    def __call__(self, args, timeout=0):
        self.calls.append(args)
        if "--json-output" in args:
            path = args[args.index("--json-output") + 1]
            self.json_paths.append(path)
        if args[2:4] == ["list", "devices"]:
            if self.list_rc == 0:
                with open(path, "w") as f:
                    f.write(self.devices_raw if self.devices_raw is not None
                            else json.dumps({"result": {"devices": self.devices}}))
            return self.list_rc, "", ""
        if args[2:5] == ["device", "info", "files"]:
            if self.files_rc == 0:
                with open(path, "w") as f:
                    json.dump({"result": {"files": self.files}}, f)
            return self.files_rc, "", ""
        if args[2:5] == ["device", "copy", "from"]:
            src = args[args.index("--source") + 1]
            if src in self.fail_copy:
                return 1, "", "boom"
            dst = args[args.index("--destination") + 1]
            if self.refuse_existing and os.path.exists(dst):
                return 1, "", "exists"
            with open(dst, "w") as f:
                f.write("{}")
            return 0, "", ""
        raise AssertionError(args)

    def copies(self):
        return [c for c in self.calls if c[2:5] == ["device", "copy", "from"]]


class DeviceTests(Base):
    def pull(self, fake, **kw):
        self.stg = os.path.join(self.tmp, "state", "stg")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            status = tci.pull_device(self.stg, fake, **kw)
        self.err = err.getvalue()
        return status

    def test_discovery_picks_paired_physical_ios(self):
        fake = FakeDevicectl(devices=[
            _dev("SIM", reality="virtual"), _dev("UNPAIRED", pairing="unpaired"),
            _dev("WATCH", platform="watchOS"), _dev("PHONE")],
            files=[_f("Trio-2026-11-03-073506.ips")])
        self.assertEqual(self.pull(fake), "ok")
        self.assertEqual(fake.copies()[0][fake.copies()[0].index("--device") + 1], "PHONE")
        self.assertIn("device=PHONE listed=1 new=1 copy_failed=0", self.err)
        self.assertTrue(os.path.exists(os.path.join(self.stg, "Trio-2026-11-03-073506.ips")))

    def test_device_flag_skips_discovery(self):
        fake = FakeDevicectl(files=[_f("Trio-a.ips")])
        self.assertEqual(self.pull(fake, device="UDID1"), "ok")
        self.assertFalse(any(c[2:4] == ["list", "devices"] for c in fake.calls))
        self.assertIn("UDID1", fake.calls[0])

    def test_unreachable_cases(self):
        for fake in (FakeDevicectl(devices=[_dev("U", pairing="unpaired")]),
                     FakeDevicectl(list_rc=1),
                     FakeDevicectl(devices_raw="not json"),
                     FakeDevicectl(devices=[_dev("U")], files_rc=1)):
            self.assertEqual(self.pull(fake), "unreachable")
            self.assertEqual(fake.copies(), [])

    def test_filtering(self):
        fake = FakeDevicectl(files=[
            _f("Trio-1.ips"), _f("Trio Watch App-2.ips"),
            _f("ProxiedDevice-ab/Retired/Trio Watch App-3.ips"),
            _f("Other-4.ips"), _f("Trio-5.txt"), _f("Trio-dir.ips", True),
            _f("diskwrites_Trio-7.ips"), _f("Trio-6.diskwrites_resource.ips.gz"),
            _f("JetsamEvent-8.ips")])
        self.assertEqual(self.pull(fake, device="U"), "ok")
        got = sorted(c[c.index("--source") + 1] for c in fake.copies())
        self.assertEqual(got, ["ProxiedDevice-ab/Retired/Trio Watch App-3.ips",
                               "Trio Watch App-2.ips", "Trio-1.ips"])
        self.assertIn("listed=3 new=3", self.err)

    def test_skips_existing_destination(self):
        os.makedirs(os.path.join(self.tmp, "state", "stg"))
        have = os.path.join(self.tmp, "state", "stg", "Trio-1.ips")
        with open(have, "w") as f:
            f.write("old")
        fake = FakeDevicectl(files=[_f("Trio-1.ips"), _f("Trio-2.ips")])
        self.pull(fake, device="U")
        self.assertEqual(len(fake.copies()), 1)
        with open(have) as fh:
            self.assertEqual(fh.read(), "old")
        self.assertIn("listed=2 new=1", self.err)

    def test_rejects_unsafe_paths(self):
        fake = FakeDevicectl(files=[_f("/etc/Trio-1.ips"), _f("../Trio-2.ips"),
                                    _f("a/../../Trio-3.ips"), _f(""), _f("Trio-4\0.ips"),
                                    _f("Trio-ok.ips")])
        self.assertEqual(self.pull(fake, device="U"), "ok")
        self.assertEqual([c[c.index("--source") + 1] for c in fake.copies()], ["Trio-ok.ips"])
        self.assertIn("skipping unsafe path", self.err)

    def test_failed_copy_leaves_no_partial_and_rest_copy(self):
        fake = FakeDevicectl(files=[_f("Trio-1.ips"), _f("Trio-2.ips"), _f("Trio-3.ips")],
                             fail_copy=("Trio-2.ips",))
        self.assertEqual(self.pull(fake, device="U"), "ok")
        names = sorted(os.listdir(self.stg))
        self.assertEqual(names, ["Trio-1.ips", "Trio-3.ips"])
        self.assertIn("new=2 copy_failed=1", self.err)

    def test_all_copies_failed_is_copy_failed(self):
        fake = FakeDevicectl(files=[_f("Trio-1.ips"), _f("Trio-2.ips")],
                             fail_copy=("Trio-1.ips", "Trio-2.ips"))
        self.assertEqual(self.pull(fake, device="U"), "copy_failed")
        self.assertIn("new=0 copy_failed=2", self.err)

    def test_nothing_to_copy_is_ok(self):
        fake = FakeDevicectl(files=[])
        self.assertEqual(self.pull(fake, device="U"), "ok")

    def test_stale_partial_is_removed_before_copy(self):
        os.makedirs(os.path.join(self.tmp, "state", "stg"))
        stale = os.path.join(self.tmp, "state", "stg", "Trio-1.ips.partial")
        with open(stale, "w") as f:
            f.write("junk")
        fake = FakeDevicectl(files=[_f("Trio-1.ips")], refuse_existing=True)
        self.assertEqual(self.pull(fake, device="U"), "ok")
        self.assertEqual(os.listdir(self.stg), ["Trio-1.ips"])

    def test_discovery_properties_schema(self):
        fake = FakeDevicectl(devices=[_dev_props("SIM", reality="virtual"), _dev_props("PHONE")],
                             files=[_f("Trio-1.ips")])
        self.assertEqual(self.pull(fake), "ok")
        self.assertIn("device=PHONE", self.err)

    def test_discovery_deprecated_schema_only(self):
        fake = FakeDevicectl(devices=[_dev("UNPAIRED", pairing="unpaired"), _dev("PHONE")],
                             files=[_f("Trio-1.ips")])
        self.assertEqual(self.pull(fake), "ok")
        self.assertIn("device=PHONE", self.err)

    def test_read_only_verbs_and_temp_cleanup(self):
        fake = FakeDevicectl(devices=[_dev("U")], files=[_f("Trio-1.ips")])
        self.pull(fake)
        for c in fake.calls:
            self.assertEqual(c[:2], ["xcrun", "devicectl"])
            joined = " ".join(c)
            for bad in ("delete", "remove", "uninstall", "copy to"):
                self.assertNotIn(bad, joined)
        self.assertTrue(fake.json_paths)
        for p in fake.json_paths:
            self.assertFalse(os.path.exists(os.path.dirname(p)))
        self.assertEqual(os.listdir(os.path.join(self.tmp, "state")), ["stg"])


class SymbolicatorFetchTests(Base):
    def report(self):
        return tci.parse_ips(make_ips(self.src, "a.ips"))

    def test_missing_release_marker(self):
        sym = tci.Symbolicator(self.cache, "o/r", lambda a, timeout=0: (1, "", "release not found"))
        self.assertEqual(sym.symbolicate(self.report(), [{"uuid": UUID, "base": 1, "offset": 1}]), [None])
        self.assertTrue(os.path.exists(os.path.join(self.cache, "trio-v1.0.2-237-localCI", "MISSING")))

    def test_release_without_dsym_asset_defers_within_grace(self):
        sym = tci.Symbolicator(self.cache, "o/r",
                               lambda a, timeout=0: (1, "", "no assets match the file pattern"),
                               now=lambda: 1000.0)
        with self.assertRaises(tci.Deferred):
            sym.symbolicate(self.report(), [{"uuid": UUID, "base": 1, "offset": 1}])
        d = os.path.join(self.cache, "trio-v1.0.2-237-localCI")
        self.assertTrue(os.path.exists(os.path.join(d, "NOASSET")))
        self.assertFalse(os.path.exists(os.path.join(d, "MISSING")))

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
            if args[0] == "gh" and args[3] != tag:
                return 1, "", "release not found"
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
        orig_allowed = tci.host_allowed
        tci.host_allowed = lambda url: True  # loopback server stands in for BetterStack
        try:
            n, err = tci.post_events([{"a": 1}], "http://127.0.0.1:%d" % srv.server_port, TOKEN)
        finally:
            tci.host_allowed = orig_allowed
            srv.shutdown()
            srv.server_close()
        self.assertEqual(n, 0)
        self.assertIn("307", err)
        self.assertNotIn(TOKEN, err)
        self.assertEqual([p for p, _ in seen], ["/"])  # /other never requested

    def test_redirect_handler_returns_no_request(self):
        h = tci._NoRedirect()
        req = urllib.request.Request(tci.DEFAULT_HOST, data=b"x", method="POST")
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
            if args[0] == "gh" and args[3] != self.TAG:
                return 1, "", "release not found"
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
            if args[0] == "gh" and args[3] != self.TAG:
                return 1, "", "release not found"
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
        sym = tci.Symbolicator(self.cache, "o/r", run)  # next run: Deferred is per-run
        sym.symbolicate(self.report(), items)
        self.assertTrue(os.path.isdir(os.path.join(d, "dsym")))


class HostAllowlistTests(Base):
    def test_accepted(self):
        for u in (tci.DEFAULT_HOST, "https://in.logs.betterstack.com/",
                  "https://s123.eu-nbg-2.betterstackdata.com",
                  "https://s123.eu-nbg-2.betterstackdata.com:443"):
            self.assertTrue(tci.host_allowed(u), u)

    def test_rejected(self):
        for u in ("http://in.logs.betterstack.com",
                  "https://in.logs.betterstack.com@evil.example",
                  "https://evil.example",
                  "https://betterstackdata.com.evil.example",
                  "https://in.logs.betterstack.com:8443",
                  "https://user:pw@in.logs.betterstack.com",
                  "https://in.logs.betterstack.com:bad", ""):
            self.assertFalse(tci.host_allowed(u), u)

    def test_post_events_refuses_bad_host(self):
        def opener(req, timeout=0):
            raise AssertionError("opener must not be called")
        sent, err = tci.post_events([{"a": 1}], "https://evil.example", TOKEN, opener=opener)
        self.assertEqual(sent, 0)
        self.assertIsNotNone(err)

    def test_main_bad_keychain_host(self):
        make_ips(self.src, "a.ips")

        def run(args, timeout=0):
            if args[0] == "security":
                if "betterstack-token" in args:
                    return 0, TOKEN + "\n", ""
                return 0, "https://evil.example\n", ""
            return 1, "", "release not found"

        def opener(req, timeout=0):
            raise AssertionError("opener must not be called")
        rc, _out, err = self.run_main([], runner=run, opener=opener)
        self.assertEqual(rc, 2)
        self.assertIn("refusing", err)


class TagTraversalTests(Base):
    def test_bad_versions_rejected(self):
        for bad in ("../../x", "1/2", ["1"], 5, "", "1."):
            ips = make_ips(self.src, "a.ips", header={"build_version": bad})
            report = tci.parse_ips(ips)
            self.assertEqual(tci.Symbolicator.tags_for(report), [], bad)
            ips = make_ips(self.src, "b.ips", header={"app_version": bad})
            self.assertEqual(tci.Symbolicator.tags_for(tci.parse_ips(ips)), [], bad)

    def test_good_version(self):
        report = tci.parse_ips(make_ips(self.src, "a.ips"))
        self.assertEqual(tci.Symbolicator.tags_for(report),
                         ["trio-v1.0.2-237-localCI", "trio-v1.0.2-237-cloudCI",
                          "trio-v1.0.2-237-local"])

    def test_traversal_unsymbolicated_no_gh_no_files(self):
        calls = []

        def run(args, timeout=0):
            calls.append(args)
            return 1, "", ""
        for bad in ("../../x", "1/2", ["1"]):
            ips = make_ips(self.src, "a.ips", header={"build_version": bad})
            sym = tci.Symbolicator(self.cache, "o/r", run)
            res = sym.symbolicate(tci.parse_ips(ips), [{"uuid": UUID, "base": 1, "offset": 1}])
            self.assertEqual(res, [None])
        self.assertEqual(calls, [])
        self.assertFalse(os.path.exists(self.cache))
        self.assertEqual(sorted(os.listdir(self.tmp)), ["src"])


class TagFallbackTests(Base):
    TAGS = ["trio-v1.0.2-237-localCI", "trio-v1.0.2-237-cloudCI", "trio-v1.0.2-237-local"]
    ITEMS = [{"uuid": UUID.lower(), "base": 4096, "offset": 8}]

    def report(self):
        return tci.parse_ips(make_ips(self.src, "a.ips"))

    def fake(self, outcomes):
        """outcomes: tag -> 'ok' | 'missing' | 'error'. Returns (runner, gh_tags)."""
        gh_tags = []

        def run(args, timeout=0):
            if args[0] == "gh":
                tag = args[3]
                gh_tags.append(tag)
                if outcomes[tag] == "missing":
                    return 1, "", "release not found"
                if outcomes[tag] == "error":
                    return 1, "", "dial tcp: timeout"
                d = args[args.index("-D") + 1]
                with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                    z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                return 0, "UUID: %s (arm64) %s\n" % (UUID, args[-1]), ""
            if args[0] == "atos":
                return 0, "main (in Trio) (App.swift:3)\n", ""
            return 1, "", ""
        return run, gh_tags

    def test_local_used_when_localci_and_cloudci_missing(self):
        run, gh_tags = self.fake({self.TAGS[0]: "missing", self.TAGS[1]: "missing",
                                  self.TAGS[2]: "ok"})
        sym = tci.Symbolicator(self.cache, "o/r", run)
        res = sym.symbolicate(self.report(), self.ITEMS)
        self.assertEqual(res, ["main (in Trio) (App.swift:3)"])
        self.assertEqual(gh_tags, self.TAGS)
        self.assertTrue(os.path.exists(os.path.join(self.cache, self.TAGS[0], "MISSING")))
        self.assertTrue(os.path.isdir(os.path.join(self.cache, self.TAGS[2], "dsym")))
        # resolution is cached per (version, build): no further gh calls
        sym.symbolicate(self.report(), self.ITEMS)
        self.assertEqual(gh_tags, self.TAGS)

    def test_all_present_tags_are_merged(self):
        run, gh_tags = self.fake({self.TAGS[0]: "missing", self.TAGS[1]: "ok",
                                  self.TAGS[2]: "ok"})
        sym = tci.Symbolicator(self.cache, "o/r", run)
        self.assertEqual(sym.symbolicate(self.report(), self.ITEMS), ["main (in Trio) (App.swift:3)"])
        self.assertEqual(gh_tags, self.TAGS)

    def test_localci_without_matching_uuid_falls_through_to_local(self):
        other = "11111111-2222-3333-4444-555555555555"
        gh_tags = []

        def run(args, timeout=0):
            if args[0] == "gh":
                tag = args[3]
                gh_tags.append(tag)
                if tag == self.TAGS[1]:
                    return 1, "", "release not found"
                d = args[args.index("-D") + 1]
                with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                    z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                uuid = UUID if self.TAGS[2] in args[-1] else other
                return 0, "UUID: %s (arm64) %s\n" % (uuid, args[-1]), ""
            if args[0] == "atos":
                return 0, "main (in Trio) (App.swift:3)\n", ""
            return 1, "", ""
        sym = tci.Symbolicator(self.cache, "o/r", run)
        self.assertEqual(sym.symbolicate(self.report(), self.ITEMS), ["main (in Trio) (App.swift:3)"])
        self.assertEqual(gh_tags, self.TAGS)

    def test_all_missing_unsymbolicated(self):
        run, gh_tags = self.fake({t: "missing" for t in self.TAGS})
        sym = tci.Symbolicator(self.cache, "o/r", run)
        self.assertEqual(sym.symbolicate(self.report(), self.ITEMS), [None])
        for t in self.TAGS:
            self.assertTrue(os.path.exists(os.path.join(self.cache, t, "MISSING")), t)

    def test_transient_error_after_missing_defers(self):
        run, gh_tags = self.fake({self.TAGS[0]: "missing", self.TAGS[1]: "error",
                                  self.TAGS[2]: "ok"})
        sym = tci.Symbolicator(self.cache, "o/r", run)
        with self.assertRaises(tci.Deferred):
            sym.symbolicate(self.report(), self.ITEMS)
        self.assertEqual(gh_tags, self.TAGS[:2])  # never fell through to "local"
        self.assertFalse(os.path.exists(os.path.join(self.cache, self.TAGS[1], "MISSING")))


NOASSET_ERR = "no assets match the file pattern"


class NoAssetGraceTests(Base):
    TAG = "trio-v1.0.2-237-localCI"
    ITEMS = [{"uuid": UUID.lower(), "base": 4096, "offset": 8}]

    def d(self):
        return os.path.join(self.cache, self.TAG)

    def marker(self, name):
        return os.path.join(self.d(), name)

    def report(self):
        return tci.parse_ips(make_ips(self.src, "a.ips"))

    def runner_for(self, state, gh_calls=None):
        """state['asset'] toggles whether the localCI release has the dSYM asset."""
        def run(args, timeout=0):
            if args[0] == "security":
                return (0, TOKEN + "\n", "") if "betterstack-token" in args else (1, "", "")
            if args[0] == "gh":
                if gh_calls is not None:
                    gh_calls.append(args[3])
                if args[3] != self.TAG:
                    return 1, "", "release not found"
                if not state["asset"]:
                    return 1, "", NOASSET_ERR
                d = args[args.index("-D") + 1]
                with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                    z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                return 0, "UUID: %s (arm64) %s\n" % (UUID, args[-1]), ""
            if args[0] == "atos":
                return 0, "main (in Trio) (App.swift:3)\n", ""
            return 1, "", ""
        return run

    def test_a_within_grace_report_deferred_not_recorded(self):
        make_ips(self.src, "a.ips")
        rc, out, _ = self.run_main([], self.runner_for({"asset": False}))
        self.assertEqual(rc, 0)
        self.assertIn("new=0", out)
        self.assertIn("sent=0", out)
        self.assertIn("deferred=1", out)
        self.assertEqual(tci.load_state(self.state)["incident_ids"], {})
        self.assertTrue(os.path.exists(self.marker("NOASSET")))
        self.assertFalse(os.path.exists(self.marker("MISSING")))

    def test_b_backdated_noasset_becomes_missing_and_posts_unsymbolicated(self):
        make_ips(self.src, "a.ips")
        os.makedirs(self.d())
        with open(self.marker("NOASSET"), "w") as f:
            f.write("%d\n" % (tci.time.time() - tci.ASSET_GRACE_SECONDS - 60))

        rc, out, _ = self.run_main(["--dry-run"], self.runner_for({"asset": False}))
        self.assertEqual(rc, 0)
        self.assertIn("new=1", out)
        self.assertIn("unsymbolicated=1", out)
        self.assertNotIn("deferred=", out)
        self.assertTrue(os.path.exists(self.marker("MISSING")))

    def test_garbage_noasset_marker_is_rewritten(self):
        os.makedirs(self.d())
        with open(self.marker("NOASSET"), "w") as f:
            f.write("not a number")
        sym = tci.Symbolicator(self.cache, "o/r", self.runner_for({"asset": False}),
                               now=lambda: 5000.0)
        with self.assertRaises(tci.Deferred):
            sym.symbolicate(self.report(), self.ITEMS)
        with open(self.marker("NOASSET")) as f:
            self.assertEqual(float(f.read()), 5000.0)

    def test_noasset_first_seen_not_overwritten(self):
        clock = [1000.0]
        state = {"asset": False}
        run = self.runner_for(state)
        for t in (1000.0, 2000.0):
            clock[0] = t
            sym = tci.Symbolicator(self.cache, "o/r", run, now=lambda: clock[0])
            with self.assertRaises(tci.Deferred):
                sym.symbolicate(self.report(), self.ITEMS)
        with open(self.marker("NOASSET")) as f:
            self.assertEqual(float(f.read()), 1000.0)

    def test_c_asset_appears_on_second_run(self):
        state = {"asset": False}
        run = self.runner_for(state)
        sym1 = tci.Symbolicator(self.cache, "o/r", run)
        with self.assertRaises(tci.Deferred):
            sym1.symbolicate(self.report(), self.ITEMS)
        self.assertTrue(os.path.exists(self.marker("NOASSET")))
        state["asset"] = True
        sym2 = tci.Symbolicator(self.cache, "o/r", run)
        self.assertEqual(sym2.symbolicate(self.report(), self.ITEMS),
                         ["main (in Trio) (App.swift:3)"])
        self.assertFalse(os.path.exists(self.marker("NOASSET")))

    def test_d_release_not_found_is_immediately_missing(self):
        sym = tci.Symbolicator(self.cache, "o/r", lambda a, timeout=0: (1, "", "release not found"))
        self.assertEqual(sym.symbolicate(self.report(), self.ITEMS), [None])
        self.assertTrue(os.path.exists(self.marker("MISSING")))
        self.assertFalse(os.path.exists(self.marker("NOASSET")))

    def test_e_gh_called_once_per_tag_across_reports(self):
        make_ips(self.src, "a.ips", incident="INC-1")
        make_ips(self.src, "b.ips", incident="INC-2")
        gh_calls = []
        rc, out, _ = self.run_main([], self.runner_for({"asset": False}, gh_calls))
        self.assertIn("deferred=2", out)
        self.assertEqual(gh_calls, [self.TAG])

    def test_cleanup_keeps_markers(self):
        os.makedirs(self.d())
        for name in ("MISSING", "NOASSET"):
            with open(self.marker(name), "w") as f:
                f.write("1\n")
        tci.Symbolicator._cleanup(self.d(), os.path.join(self.d(), "dsym"))
        self.assertTrue(os.path.exists(self.marker("MISSING")))
        self.assertTrue(os.path.exists(self.marker("NOASSET")))


class CollisionRuleTests(Base):
    def test_f_localci_wins_uuid_collision(self):
        tags = TagFallbackTests.TAGS
        atos_paths = []

        def run(args, timeout=0):
            if args[0] == "gh":
                d = args[args.index("-D") + 1]
                with zipfile.ZipFile(os.path.join(d, "Trio.app.dSYM.zip"), "w") as z:
                    z.writestr("Trio.app.dSYM/Contents/Resources/DWARF/Trio", "x")
                return 0, "", ""
            if args[0] == "dwarfdump":
                return 0, "UUID: %s (arm64) %s\n" % (UUID, args[-1]), ""
            if args[0] == "atos":
                atos_paths.append(args[args.index("-o") + 1])
                return 0, "main (in Trio) (App.swift:3)\n", ""
            return 1, "", ""
        sym = tci.Symbolicator(self.cache, "o/r", run)
        report = tci.parse_ips(make_ips(self.src, "a.ips"))
        dmap = sym.dsym_map_for(report)
        self.assertIn(os.path.join(self.cache, tags[0], "dsym"), dmap[UUID.lower()][0])
        sym.symbolicate(report, TagFallbackTests.ITEMS)
        self.assertEqual(len(atos_paths), 1)
        self.assertIn(os.sep + tags[0] + os.sep, atos_paths[0])
        for t in tags[1:]:
            self.assertNotIn(os.sep + t + os.sep, atos_paths[0])


if __name__ == "__main__":
    unittest.main()
