import contextlib, functools, http.server, io, json, os, pathlib, shutil, ssl, threading, tomllib, unittest, urllib.error, urllib.request, zipfile
from pathlib import Path
from unittest import mock

from helpers import REPO, Case, git_repo, have, sha, truncating_handler, zip_bytes
from sert import LUAU, LUAU_LSP, VERSION, config, fetch, util
from sert.util import SertError, write_atomic

DEP_ZIP = zip_bytes({"Flux/default.project.json": b"{}", "Flux/src/init.luau": b"return {}\n", "README.md": b"x"})
SERT_ZIP = zip_bytes({"default.project.json": b"{}", "src/init.luau": b"return {}\n"})
SERT_PYZ = b"#!/usr/bin/env python3\nPK-not-really\n"


class FetchAndHttpTest(Case):
    def setUp(self):
        super().setUp()
        self.server = self.release_server()
        self.publish(self.server, "kohltastrophe/flux", "v1.0.0", "Flux-1.0.0.zip", DEP_ZIP)
        self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "sert-0.1.0.zip", SERT_ZIP)
        self.publish(self.server, "kohltastrophe/sert", "v0.1.0", "sert-0.1.0.pyz", SERT_PYZ)

    def toml(self, tag="v1.0.0", extra=""):
        return (
            '[sert]\nversion = "0.1.0"\n'
            f'[deps.flux]\nrepo = "kohltastrophe/flux"\ntag = "{tag}"\nasset = "Flux-1.0.0.zip"\n'
            'strip = "Flux"\n' + extra
        )

    def test_fetch_install_and_cache(self):
        root = self.project(self.toml())
        code, _, err = self.sert("fetch", "--root", root, "--only", "sert", "--only", "deps")
        self.assertEqual(code, 0, err)
        self.assertEqual((root / ".sert/sert/src/init.luau").read_bytes(), b"return {}\n")
        self.assertEqual((root / ".sert/pkg/flux/src/init.luau").read_bytes(), b"return {}\n")
        self.assertFalse((root / ".sert/pkg/flux/README.md").exists())
        self.assertEqual((root / ".sert/bin/sert").read_bytes(), SERT_PYZ)
        self.assertTrue(os.access(root / ".sert/bin/sert", os.X_OK) and (self.tmp / "cache/kohltastrophe/flux/v1.0.0/Flux-1.0.0.zip").is_file())
        (self.server / "kohltastrophe/flux/releases/download/v1.0.0/Flux-1.0.0.zip").unlink()
        code, out, err = self.sert("fetch", "--root", root, "--only", "deps")
        self.assertEqual((code, "up to date" in out), (0, True), err)

        self.setenv("CI", "true")
        ci_root = self.project(self.toml(), name="ci")
        code, _, err = self.sert("fetch", "--root", ci_root, "--only", "deps")
        self.assertEqual(code, 0, err)

    def test_override_mirror_and_archive_safety(self):
        sibling, sert_checkout = self.tmp / "flux-checkout", self.tmp / "sert-checkout"
        for p, text in ((sibling / "src/init.luau", "return 'local'\n"), (sibling / "src/__pycache__/x.pyc", "x"),
                        (sibling / "test/spec.luau", "not packaged\n"), (sibling / "default.project.json", '{"name": "Flux", "tree": {"$path": "src"}}'),
                        (sert_checkout / "src/init.luau", "return 'sert'\n"), (sert_checkout / "default.project.json", "{}"),
                        (sert_checkout / "README.md", "not packaged")):
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)

        root = self.project(self.toml())
        self.assertEqual(self.sert("fetch", "--root", root, "--only", "deps")[0], 0)
        (root / "sert.local.toml").write_text('[override]\nflux = "../flux-checkout"\nsert = "../sert-checkout"\n')
        code, _, err = self.sert("fetch", "--root", root, "--only", "sert", "--only", "deps")
        self.assertEqual((code, "override active: flux" in err), (0, True))
        flux, sert_dir = root / ".sert/pkg/flux", root / ".sert/sert"
        self.assertEqual(sorted(p.relative_to(flux).as_posix() for p in flux.rglob("*") if p.is_file()), [".override", "default.project.json", "src/init.luau"])
        self.assertEqual(((sert_dir / "src/init.luau").read_text(), (sert_dir / "README.md").exists()), ("return 'sert'\n", False))

        cfg = config.load(root)
        self.assertEqual(fetch.refresh_overrides(cfg), 0)
        (sibling / "src/init.luau").write_text("return 'edited locally'\n")
        (sibling / "src/New.luau").write_text("return 1\n")
        (sert_checkout / "src/init.luau").unlink()
        self.assertEqual(fetch.refresh_overrides(cfg), 2)
        self.assertEqual(((flux / "src/init.luau").read_text(), (flux / "src/New.luau").is_file(), (sert_dir / "src/init.luau").exists()), ("return 'edited locally'\n", True, False))

        (root / "sert.local.toml").write_text("")
        self.assertEqual(self.sert("fetch", "--root", root, "--only", "deps")[0], 0)
        self.assertEqual(((flux / ".override").exists(), (flux / "src/init.luau").read_bytes()), (False, b"return {}\n"))
        (root / "sert.local.toml").write_text('[override]\nflux = "../flux-checkout"\n')
        self.setenv("CI", "true")
        self.assertEqual(self.sert("fetch", "--root", root)[0], 2)
        with self.assertRaisesRegex(SertError, r"CI=true"):
            fetch.refresh_overrides(config.load(root))
        self.setenv("CI", None)
        self.assertEqual(self.sert("fetch", "--root", self.project(self.toml(), '[override]\nnope = "../x"\n', name="unk"), "--only", "deps")[0], 2)

        archive = self.tmp / "broken.zip"
        archive.write_bytes(b"not a zip")
        with self.assertRaisesRegex(SertError, r"broken.zip is not a valid zip archive"):
            fetch.extract_zip(archive, self.tmp / "out")
        truncated = self.tmp / "truncated.zip"
        truncated.write_bytes(SERT_ZIP[: len(SERT_ZIP) // 2])
        with self.assertRaises(SertError):
            fetch.install_zip(truncated, sha(SERT_ZIP), self.tmp / "installed")

        bad_zip = zip_bytes({"../evil.txt": b"x"})
        self.publish(self.server, "a/b", "v1", "bad.zip", bad_zip)
        self.assertEqual(self.sert("fetch", "--root", self.project('[deps.bad]\nrepo = "a/b"\ntag = "v1"\nasset = "bad.zip"\n', name="bzip"), "--only", "deps")[0], 2)
        for drive_entry in ("C:/evil.txt", "C:\\evil.txt", "d:evil.txt"):
            with self.assertRaisesRegex(SertError, r"refusing unsafe zip entry"):
                fetch._safe_member(drive_entry, None)
        symlink_zip = self.tmp / "symlink.zip"
        with zipfile.ZipFile(symlink_zip, "w") as zf:
            info = zipfile.ZipInfo("link.txt")
            info.external_attr = (0o120777 << 16)
            zf.writestr(info, "/etc/passwd")
        with self.assertRaisesRegex(SertError, r"symlink\.zip: unsafe zip entry: 'link\.txt'"):
            fetch.extract_zip(symlink_zip, self.tmp / "sym-out")

        src1, dest = self.tmp / "src1", self.tmp / "dest"
        (src1 / "src").mkdir(parents=True)
        f = src1 / "src/a.luau"
        f.write_text("return 1\n")
        self.assertEqual(fetch.mirror(src1, dest, ["src"], full=True), 1)
        st = f.stat()
        f.write_text("return 2\n")
        os.utime(f, ns=(st.st_atime_ns, st.st_mtime_ns + 500))
        self.assertEqual((fetch.mirror(src1, dest, ["src"], full=False), (dest / "src/a.luau").read_text()), (1, "return 2\n"))
        f.unlink()
        (src1 / "src/a.luau").mkdir()
        (src1 / "src/a.luau/init.luau").write_text("return 3\n")
        self.assertEqual((fetch.mirror(src1, dest, ["src"], full=False), (dest / "src/a.luau/init.luau").is_file()), (1, True))
        src2 = self.tmp / "src2"
        (src2 / "src").mkdir(parents=True)
        (src2 / "src/b.luau").write_text("return 4\n")
        self.assertEqual((fetch.mirror(src2, dest, ["src"], full=False), (dest / "src/a.luau").exists()), (1, False))

        utf_src = self.tmp / "José Дмитрий"
        (utf_src / "src").mkdir(parents=True)
        (utf_src / "src/a.luau").write_text("return 1\n")
        self.assertEqual((fetch.mirror(utf_src, self.tmp / "udest", ["src"]), fetch.mirror(utf_src, self.tmp / "udest", ["src"], full=False)), (1, 0))

    def test_ensure_fetched_tools_types_and_concurrency(self):
        root = self.project(self.toml())
        cfg = config.load(root)
        self.assertEqual([w for w, _ in fetch.missing_parts(cfg)], ["sert 0.1.0", "[deps.flux]"])
        with contextlib.redirect_stderr(io.StringIO()):
            fetch.ensure_fetched(cfg)
        self.assertEqual(fetch.missing_parts(cfg), [])
        (root / "sert.toml").write_text(self.toml(tag="v1.0.1"))
        stale = config.load(root)
        self.setenv("SERT_OFFLINE", "1")
        with self.assertRaisesRegex(SertError, r"run `sert fetch`"):
            fetch.ensure_fetched(stale)
        self.setenv("SERT_ROOT", str(root))
        with self.assertRaisesRegex(SertError, r"run `python3 tools/sert\.py fetch`"):
            fetch.ensure_fetched(stale)
        self.setenv("SERT_OFFLINE", None)
        self.setenv("SERT_ROOT", None)

        def pub(version, text):
            _, tag, asset = fetch.tool_asset("luau", version)
            data = zip_bytes({"luau": text}, {"luau": 0o100755})
            self.publish(self.server, "luau-lang/luau", tag, asset, data)

        pub("0.724", b"#!/bin/sh\necho old\n")
        pub("0.725", b"#!/bin/sh\necho new\n")
        troot = self.project('[tools]\nluau = "0.724"\n', name="troot")
        with contextlib.redirect_stderr(io.StringIO()):
            fetch.ensure_fetched(config.load(troot))
        self.assertEqual((troot / ".sert/bin/luau").read_bytes(), b"#!/bin/sh\necho old\n")
        (troot / "sert.toml").write_text('[tools]\nluau = "0.725"\n')
        with contextlib.redirect_stderr(io.StringIO()):
            fetch.ensure_fetched(config.load(troot))
        self.assertEqual((troot / ".sert/bin/luau").read_bytes(), b"#!/bin/sh\necho new\n")

        mroot = self.project("[tools]\n", name="mroot")
        (mroot / ".luaurc").write_text('{"aliases": {"sert": "./.sert/sert/src"}}')
        self.assertEqual(self.sert("fetch", "--root", mroot, "--only", "sert")[0], 2)
        (mroot / ".luaurc").write_text('{"aliases": {"sert": "./src"}}')
        self.assertEqual(self.sert("fetch", "--root", mroot, "--only", "sert")[0], 0)

        raw = self.tmp / "raw"
        defs = raw / "JohnnyMorganz/luau-lsp/1.70.0/scripts/globalTypes.d.luau"
        defs.parent.mkdir(parents=True)
        defs.write_text("declare class Instance\nend\n")
        self.setenv("SERT_RAW_URL", raw.as_uri())
        rroot = self.project("", name="rroot")
        (rroot / "rokit.toml").write_text('[tools]\nluau-lsp = "JohnnyMorganz/luau-lsp@1.70.0"\n')
        self.assertEqual(self.sert("fetch", "--root", rroot, "--only", "types")[0], 0)
        self.assertEqual((rroot / ".sert/types/globalTypes.d.luau").read_text(), "declare class Instance\nend\n")

        archive = self.tmp / "a.zip"
        archive.write_bytes(DEP_ZIP)
        destination = self.tmp / "out/pkg"
        threads = [threading.Thread(target=lambda: fetch.install_zip(archive, "s", destination)) for _ in range(8)]
        for t in threads: t.start()
        for t in threads: t.join()
        self.assertTrue((destination / "Flux/src/init.luau").is_file() and not fetch.install_zip(archive, "s", destination))
        other_dir = self.tmp / "other"
        real_replace = os.replace
        def lose(source, target):
            if Path(source).name != "new":
                return real_replace(source, target)
            fetch.extract_zip(archive, other_dir)
            (other_dir / fetch.MARKER).write_text("t\n")
            real_replace(other_dir, target)
            raise OSError(39, "Directory not empty")
        with mock.patch.object(fetch.os, "replace", lose):
            self.assertFalse(fetch.install_zip(archive, "t", destination))
            with self.assertRaisesRegex(SertError, r"Directory not empty"):
                fetch.install_zip(archive, "u", destination)

    def test_http_errors_truncation_and_write_atomic(self):
        served = self.tmp / "www"
        repo_rel = served / "a/b/releases/download/v1"
        repo_rel.mkdir(parents=True)
        (repo_rel / "a.zip").write_bytes(DEP_ZIP)
        seen = []
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.headers.get("Authorization"))
                return super().do_GET()
            def log_message(self, *args): pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(served)))
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        self.setenv("GITHUB_TOKEN", "secret-token")
        self.setenv("SERT_GITHUB_URL", f"http://127.0.0.1:{server.server_address[1]}")
        self.assertEqual((fetch.fetch_blob("a/b", "v1", "a.zip").read_bytes(), seen), (DEP_ZIP, [None]))
        with self.assertRaisesRegex(SertError, r"HTTP 404"):
            fetch.fetch_blob("a/b", "v1", "missing.zip")
        self.assertEqual((fetch._github_host("https://github.com/x"), fetch._github_host("https://objects.githubusercontent.com/x"), fetch._github_host("https://example.com/github.com")), (True, True, False))

        redirected = fetch._DropAuthOnHostChange().redirect_request(
            urllib.request.Request("https://github.com/a/b", headers={"Authorization": "Bearer secret"}), None, 302, "Found", {}, "https://objects.example.com/blob")
        self.assertFalse(redirected.has_header("Authorization"))

        dir_zip = self.tmp / "dir.zip"
        with zipfile.ZipFile(dir_zip, "w") as zf:
            zf.writestr("sub/", "")
            zf.writestr("sub/file.txt", "hi")
        self.assertEqual(fetch.extract_zip(dir_zip, self.tmp / "extracted", strip="sub"), 1)
        with self.assertRaisesRegex(SertError, r"nothing under strip = 'nonexistent'"):
            fetch.extract_zip(dir_zip, self.tmp / "empty-ext", strip="nonexistent")

        bad_proj = self.tmp / "bad_proj"
        bad_proj.mkdir()
        with self.assertRaisesRegex(SertError, r"has no default\.project\.json"):
            fetch.override_paths("dep", bad_proj, None)
        self.assertEqual(fetch.override_paths("dep", bad_proj, {"paths": ["src/"]}), ["src"])
        self.assertEqual(fetch.override_paths("dep", bad_proj, {"paths": "src"}), ["src"])
        (bad_proj / "default.project.json").write_text('{"name": "DotPkg", "tree": {"$path": "."}}')
        (bad_proj / "init.luau").write_text("return 1\n")
        self.assertEqual(fetch._project_paths(bad_proj / "default.project.json"), [".", "default.project.json"])
        self.assertIn("init.luau", fetch._source_files(bad_proj, fetch._project_paths(bad_proj / "default.project.json")))
        (bad_proj / "default.project.json").write_text("{bad json")
        with self.assertRaisesRegex(SertError, r"override: cannot read"):
            fetch._project_paths(bad_proj / "default.project.json")
        with self.assertRaisesRegex(SertError, r"missing_dir does not exist"):
            fetch._source_files(bad_proj, ["missing_dir"])
        with self.assertRaisesRegex(SertError, r"no_such_source does not exist"):
            fetch.mirror(self.tmp / "no_such_source", self.tmp / "extracted", ["src"])
        self.setenv("SERT_SOURCE", str(self.tmp / "no_such_sert_source"))
        with self.assertRaisesRegex(SertError, r"SERT_SOURCE:.*is not a directory"):
            fetch._sert_source_env()
        self.setenv("SERT_SOURCE", None)

        empty_cfg = config.load(self.project("", name="empty-fetch"))
        for call, pat in (
            (lambda: fetch.sert_assets(empty_cfg), r"\[sert\]\.version is required"),
            (lambda: fetch.dep_spec("x", {"repo": "a/b"}), r"\[deps\.x\] needs tag, asset"),
            (lambda: fetch.tool_asset("unknown_tool", "1.0"), r"unknown tool 'unknown_tool'"),
            (lambda: fetch.tool_asset("luau", "0.724", key="plan9-mips"), r"luau publishes no release for plan9-mips"),
            (lambda: fetch.ensure_types(empty_cfg), r"no globalTypes\.d\.luau"),
        ):
            with self.assertRaisesRegex(SertError, pat):
                call()
        self.assertIsNone(fetch.fetch_types(empty_cfg))

        handler = truncating_handler(b"x" * 1000)
        turl = self.serve(handler) + "/a.zip"
        with self.assertRaisesRegex(SertError, r"IncompleteRead"):
            fetch.download(turl, self.tmp / "a.zip")
        with self.assertRaisesRegex(SertError, r"IncompleteRead"):
            fetch.read_url(turl)
        recovers = truncating_handler(b"x" * 1000, whole_after=1)
        self.assertEqual(fetch.download(self.serve(recovers) + "/a.zip", self.tmp / "a.zip"), sha(b"x" * 1000))

        with self.assertRaises(fetch.NotFound):
            fetch.retrying("https://example.com/f", lambda: (_ for _ in ()).throw(urllib.error.HTTPError("https://example.com/f", 404, "Not Found", {}, None)), sleep=lambda _: None)
        with self.assertRaises(fetch.NotFound):
            fetch.read_url((self.tmp / "nothing").as_uri())
        with self.assertRaisesRegex(SertError, r"certificate verify failed"):
            fetch.retrying("https://example.com/f", lambda: (_ for _ in ()).throw(urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))), sleep=lambda _: None)

        target = self.tmp / "dir/tool"
        target.parent.mkdir()
        write_atomic(target, b"new", 0o755)
        self.assertEqual(target.read_bytes(), b"new")
        with mock.patch.object(os, "replace", side_effect=OSError("busy")), self.assertRaises(OSError):
            write_atomic(target, b"newer")
        self.assertEqual([p.name for p in target.parent.iterdir()], ["tool"])


class InitTest(Case):
    def publish_release_and_tools(self, luau: bytes = b"#!/bin/sh\n"):
        server = self.release_server()
        tag = f"v{VERSION}"
        files = {f"src/{p.relative_to(REPO / 'src').as_posix()}": p.read_bytes() for p in sorted((REPO / "src").rglob("*")) if p.is_file()}
        assets = {f"sert-{VERSION}.zip": zip_bytes(files), f"sert-{VERSION}.pyz": b"#!/usr/bin/env python3\n"}
        hashes = {name: self.publish(server, "kohltastrophe/sert", tag, name, data) for name, data in assets.items()}
        for key, asset in fetch.TOOLS["luau"]["assets"].items():
            repo, t_tag, _ = fetch.tool_asset("luau", LUAU, key)
            self.publish(server, repo, t_tag, asset, zip_bytes({"luau": luau}, {"luau": 0o100755}))
        raw = self.tmp / "raw"
        defs = raw / f"JohnnyMorganz/luau-lsp/{LUAU_LSP}/scripts/{fetch.TYPES_ASSET}"
        defs.parent.mkdir(parents=True, exist_ok=True)
        defs.write_text("declare class Instance\nend\n")
        self.setenv("SERT_RAW_URL", raw.as_uri())
        return hashes

    def test_init_project_aliases_and_starter_spec(self):
        with_src = self.tmp / "with-src"
        (with_src / "src").mkdir(parents=True)
        fetch.init_project(with_src, out=lambda _: None)
        self.assertEqual((with_src / "sert.toml").read_text(encoding="utf-8"), fetch.STARTER_TOML)

        bare = self.tmp / "bare"
        fetch.init_project(bare, out=lambda _: None)
        cfg = config.load(bare)
        self.assertEqual((cfg.get("lint.paths"), cfg.get("coverage.include"), config.problems_in(cfg.shared)), (["test"], ["src"], []))
        self.assertEqual(json.loads((bare / ".luaurc").read_text())["aliases"]["sert"], "./.sert/sert/src")
        (bare / ".luaurc").write_text('{"languageMode": "strict", "aliases": {"sert": ".sert/sert/src", "x": "./x"}}')
        self.assertIn(".luaurc", fetch.init_project(bare, out=lambda _: None))
        self.assertEqual(json.loads((bare / ".luaurc").read_text())["aliases"]["sert"], "./.sert/sert/src")
        self.assertEqual(fetch.init_project(bare, out=lambda _: None), [])
        (bare / ".luaurc").write_text('{"aliases": {"sert": "../vendor/sert/src"}}')
        self.assertEqual(fetch.init_project(bare, out=lambda _: None), [])
        fetch.init_project(bare, force=True, out=lambda _: None)
        self.assertEqual(json.loads((bare / ".luaurc").read_text())["aliases"]["sert"], "./.sert/sert/src")

        self.assertTrue(fetch.STARTER_SPEC.rstrip().endswith("return {}") and "function(g: sert.Gen)" in fetch.STARTER_SPEC)
        anchored = self.tmp / "anchored"
        anchored.mkdir()
        (anchored / ".gitignore").write_text("/.sert/\n/sert.local.toml\n/coverage.out\n/coverage.json\n")
        self.assertFalse(fetch._update_gitignore(anchored))
        rokit = self.tmp / "rokit"
        rokit.mkdir()
        (rokit / "rokit.toml").write_text('[tools]\nluau-lsp = "JohnnyMorganz/luau-lsp@1.70.1"\n')
        self.assertNotIn("luau_lsp", fetch.starter_toml(rokit))

        self.publish_release_and_tools()
        pinned = self.tmp / "pinned"
        fetch.init_project(pinned, out=lambda _: None)
        pcfg = config.load(pinned)
        self.assertEqual(pcfg.get("sert.version"), VERSION)
        self.setenv("CI", "true")
        self.assertEqual(self.sert("fetch", "--root", pinned)[0], 0)
        self.setenv("CI", None)

    @unittest.skipUnless(have("luau"), "luau not on PATH")
    def test_initialized_repo_fetches_and_runs_its_starter_spec(self):
        self.publish_release_and_tools(pathlib.Path(util.which("luau", REPO)).read_bytes())
        root = git_repo(self.tmp / "fresh")
        self.assertEqual(self.sert("init", "--root", root)[0], 0)
        self.setenv("SERT_OFFLINE", "1")
        self.assertEqual(self.sert("run", "--root", root)[0], 2)
        self.setenv("SERT_OFFLINE", None)
        code, _, err = self.sert("run", "--root", root)
        self.assertEqual((code, f"fetch: sert {VERSION}: installed\n" in err), (0, True))
        code, _, err = self.sert("run", "--root", root)
        self.assertEqual((code, "fetch:" in err), (0, False))


if __name__ == "__main__":
    unittest.main()
