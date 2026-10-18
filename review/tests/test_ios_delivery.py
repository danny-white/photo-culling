"""iOS delivery uses temp directories only; no trial.db or remote Mac is needed."""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import Mock, patch

from flask import Flask

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "review"))
import mobile

SCRIPT = ROOT / "ios" / "build-ipa.sh"


class IosDelivery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.ios = self.root / "ios"
        self.ios.mkdir()
        self.static = self.root / "static"
        self.static.mkdir()
        (self.static / "index.html").write_text("<!doctype html><title>Culling Bay</title>")
        # Decoys prove the iOS routes win over the static catch-all.
        (self.static / "ios").mkdir()
        for name in ("latest.json", "source.json", "CullingBay.ipa", "private.txt"):
            (self.static / "ios" / name).write_text("static decoy")
        (self.static / "server.py").write_text("outside ios secret")
        self.client = self.make_app().test_client()

    def make_app(self, default_dir=False):
        app = Flask(__name__)
        app.testing = True
        # Same blueprint wiring as MobileApi, with search warmup stubbed: these routes
        # need no photo data. Any unexpected DB access fails the test.
        unavailable_db = Mock(side_effect=AssertionError("delivery must not access a database"))
        with patch.object(mobile.search, "Search"):
            app.register_blueprint(mobile.make_blueprint(
                db_ro=unavailable_db, anno=unavailable_db, pc=Mock(), cache_dir=self.root,
                static_dir=self.static, state_dir=self.root / "state", inbox=self.root / "inbox",
                check_mount=False, **({} if default_dir else {"ios_dir": self.ios})))
        return app

    def build(self, symlink=False):
        self.payload = b"fake unsigned ipa\x00\xff"
        (self.ios / "CullingBay-123.ipa").write_bytes(self.payload)
        if symlink:
            (self.ios / "CullingBay.ipa").symlink_to("CullingBay-123.ipa")
        else:
            (self.ios / "CullingBay.ipa").write_bytes(self.payload)
        for number in (9, 122):
            (self.ios / f"CullingBay-{number}.ipa").write_bytes(b"older build")
        self.metadata = {"version": "0.1", "build": 123, "git": "394eb7c-dirty",
                         "built_at": "2026-10-19T21:30:00-07:00", "bytes": len(self.payload),
                         "sha256": hashlib.sha256(self.payload).hexdigest(),
                         "file": "CullingBay-123.ipa"}
        (self.ios / "latest.json").write_text(json.dumps(self.metadata))

    def test_no_build(self):
        self.assertIn(b"No build yet", self.client.get("/m/ios/").data)
        for name in ("CullingBay.ipa", "latest.json", "source.json"):
            with self.subTest(name=name), self.client.get(f"/m/ios/{name}") as response:
                self.assertEqual(response.status_code, 404)
                self.assertIsInstance(response.json["error"], str)

    def test_page_metadata_and_previous_builds(self):
        self.build()
        response = self.client.get("/m/ios/")
        self.assertEqual(response.status_code, 200)
        text = response.get_data(as_text=True)
        for value in ("0.1", "123", "394eb7c-dirty", "Download CullingBay.ipa",
                      "CullingBay-122.ipa", "CullingBay-9.ipa", "Share → SideStore",
                      "plain-HTTP", "color-scheme: light dark", str(len(self.payload))):
            self.assertIn(value, text)
        self.assertIn(datetime.fromisoformat(self.metadata["built_at"]).astimezone()
                      .strftime("%Y-%m-%d %H:%M:%S %Z"), text)
        self.assertLess(text.index("CullingBay-122.ipa"), text.index("CullingBay-9.ipa"))
        self.assertNotIn("CullingBay-123.ipa", text)
        self.assertEqual(response.headers["Cache-Control"], "no-cache")

    def test_download_headers_bytes_and_kept_file(self):
        self.build()
        for name, payload in (("CullingBay.ipa", self.payload), ("CullingBay-9.ipa", b"older build")):
            with self.subTest(name=name), self.client.get(f"/m/ios/{name}") as response:
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.data, payload)
                self.assertEqual(response.mimetype, "application/octet-stream")
                self.assertEqual(response.headers["Cache-Control"], "no-cache")
                self.assertEqual(response.headers["Content-Disposition"], f"attachment; filename={name}")

    def test_latest_json_and_conditional_requests(self):
        self.build()
        response = self.client.get("/m/ios/latest.json")
        self.assertEqual(response.json, self.metadata)
        self.assertEqual(response.headers["Cache-Control"], "no-cache")
        self.assertEqual(self.client.get("/m/ios/latest.json", headers={
            "If-None-Match": response.headers["ETag"]}).status_code, 304)

    def test_source_uses_request_host_and_versioned_download(self):
        self.build()
        response = self.client.get("/m/ios/source.json", base_url="http://phone.test:8765")
        self.assertEqual(response.status_code, 200)
        source = response.json
        self.assertEqual(source["name"], "Culling Bay")
        self.assertIn("identifier", source)
        app, = source["apps"]
        self.assertEqual(app["bundleIdentifier"], "co.dannywhite.cullingbay")
        self.assertTrue(app["developerName"])
        self.assertTrue(app["localizedDescription"])
        version, = app["versions"]
        self.assertEqual(version, {"version": "0.1", "buildVersion": "123",
                                  "date": self.metadata["built_at"], "size": len(self.payload),
                                  "downloadURL": "http://phone.test:8765/m/ios/CullingBay-123.ipa"})
        for name in ("version", "downloadURL", "size"):
            self.assertEqual(app[name], version[name])
        self.assertEqual(app["versionDate"], version["date"])

    def test_path_tricks_and_unknown_files_do_not_fall_through(self):
        self.build()
        for path in ("../server.py", "CullingBay-1.ipa/../x", "%2e%2e/server.py",
                     "%2e%2e%2fserver.py", "/etc/passwd", "private.txt", "CullingBay-abc.ipa"):
            with self.subTest(path=path), self.client.get("/m/ios/" + path) as response:
                self.assertEqual(response.status_code, 404)
                self.assertNotIn(b"outside ios secret", response.data)
                self.assertNotIn(b"static decoy", response.data)

    def test_symlinks_only_resolve_inside_delivery_directory(self):
        self.build(symlink=True)
        with self.client.get("/m/ios/CullingBay.ipa") as response:
            self.assertEqual(response.data, self.payload)
        for name in ("CullingBay.ipa", "latest.json", "CullingBay-122.ipa"):
            (self.ios / name).unlink()
            (self.ios / name).symlink_to(self.static / "server.py")
            with self.client.get("/m/ios/" + name) as response:
                self.assertEqual(response.status_code, 404)
        self.assertNotIn(b"CullingBay-122.ipa", self.client.get("/m/ios/").data)

    def test_metadata_paths_and_html_are_not_trusted(self):
        self.build()
        for invalid in ([], {**self.metadata, "file": "../server.py"},
                        {**self.metadata, "built_at": "invalid"}):
            (self.ios / "latest.json").write_text(json.dumps(invalid))
            self.assertEqual(self.client.get("/m/ios/latest.json").status_code, 404)
        self.metadata["git"] = "<script>alert(1)</script>"
        (self.ios / "latest.json").write_text(json.dumps(self.metadata))
        self.assertIn(b"&lt;script&gt;", self.client.get("/m/ios/").data)

    def test_default_ios_directory_and_existing_shell(self):
        self.build()
        client = self.make_app(default_dir=True).test_client()
        self.assertEqual(client.get("/m/ios/latest.json").json, self.metadata)
        with client.get("/m/") as response:
            self.assertEqual(response.status_code, 200)
            self.assertIn(b"<title>Culling Bay</title>", response.data)


class IpaBuildScript(unittest.TestCase):
    def test_bash_syntax_including_remote_scripts(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True, capture_output=True)
        text = SCRIPT.read_text()
        for marker in ("MAC_BUILD", "MAC_SCREENSHOT"):
            body = text.split(f"<<'{marker}'\n", 1)[1].split(f"\n{marker}\n", 1)[0]
            subprocess.run(["bash", "-n"], input=body, text=True, check=True, capture_output=True)

    def test_dry_run_never_runs_remote_commands_or_writes_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("ssh", "scp", "rsync"):
                stub = root / name
                stub.write_text("#!/bin/sh\necho 'REMOTE COMMAND EXECUTED' >&2\nexit 99\n")
                stub.chmod(0o755)
            out = root / "space and 'quote; $(touch never)"
            result = subprocess.run(["bash", str(SCRIPT), "--dry-run", "--test", "--screenshot",
                                     "--host", "builder@example.test", "--out", str(out)],
                                    env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}"},
                                    cwd=root, check=True, text=True, capture_output=True)
            for command in ("rsync", "HostKeyAlias=192.168.1.75", "builder@example.test",
                            "zsh", "swift test", "xcodegen generate", "xcodebuild",
                            "CURRENT_PROJECT_VERSION=", "CODE_SIGNING_ALLOWED=NO",
                            "scp", "build/CullingBay.ipa", "latest.json", "sha256",
                            "iphonesimulator", "simctl", "http://100.82.57.4:8000/m/ios/"):
                self.assertIn(command, result.stdout)
            self.assertFalse(out.exists())
            self.assertEqual({p.name for p in root.iterdir()}, {"ssh", "scp", "rsync"})

    def test_publication_metadata_atomic_targets_and_retention(self):
        # Exercise the exact local publishing code without invoking ssh or a fake Mac.
        publish = SCRIPT.read_text().split("<<'PUBLISH'\n", 1)[1].split("\nPUBLISH\n", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for number in range(1, 8):
                (out / f"CullingBay-{number}.ipa").write_bytes(b"old")
            (out / "CullingBay-not-a-build.ipa").write_bytes(b"keep me")
            stage = out / ".delivery.test"
            stage.mkdir()
            payload = b"unsigned ipa payload"
            for number in (8, 8, 2):  # A rebuild, then an older branch must remain downloadable.
                (stage / "CullingBay.ipa").write_bytes(payload)
                (stage / "version.txt").write_text("0.1\n")
                subprocess.run([sys.executable, "-", str(out), str(stage), str(number), "abc123-dirty"],
                               input=publish, text=True, check=True, capture_output=True)
                metadata = json.loads((out / "latest.json").read_text())
                self.assertEqual(metadata["version"], "0.1")
                self.assertEqual(metadata["build"], number)
                self.assertEqual(metadata["file"], f"CullingBay-{number}.ipa")
                self.assertEqual(metadata["git"], "abc123-dirty")
                self.assertEqual(metadata["bytes"], len(payload))
                self.assertEqual(metadata["sha256"], hashlib.sha256(payload).hexdigest())
                self.assertIsNotNone(datetime.fromisoformat(metadata["built_at"]).tzinfo)
                self.assertEqual((out / "CullingBay.ipa").read_bytes(), payload)
                self.assertEqual((out / metadata["file"]).read_bytes(), payload)
                self.assertEqual(len(list(out.glob("CullingBay-[0-9]*.ipa"))), 5)
                self.assertEqual((out / "CullingBay-not-a-build.ipa").read_bytes(), b"keep me")
            self.assertEqual({p.name for p in out.glob("CullingBay-[0-9]*.ipa")},
                             {f"CullingBay-{n}.ipa" for n in (2, 5, 6, 7, 8)})


if __name__ == "__main__":
    unittest.main()
