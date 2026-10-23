import json, os, shutil, subprocess, sys, unittest, zipfile

import helpers
from helpers import REPO, Case, git, git_repo
from sert import VERSION, release as pack
from sert.util import SertError

DIST_TOML = '[dist]\npaths = ["default.project.json", "src"]\nbranch = "dist"\nname = "Thing"\nversion = "1.2.3"\n'


class PackAndDistTest(Case):
    def copy_repo(self, name):
        return helpers.copy_repo(self.tmp / name)

    def test_pack_reproducibility_pyz_license_and_edges(self):
        first, second = self.copy_repo("a"), self.copy_repo("b")
        os.utime(second / "src/init.luau", (1, 1))
        (second / "python/sert/__pycache__").mkdir()
        (second / "python/sert/__pycache__/x.pyc").write_bytes(b"junk")
        a, b = pack.build(first, self.tmp / "out-a"), pack.build(second, self.tmp / "out-b")
        self.assertEqual((a, sorted(a)), (b, [f"sert-{VERSION}.pyz", f"sert-{VERSION}.zip"]))
        self.assertIn(f"{a[f'sert-{VERSION}.zip']}  sert-{VERSION}.zip\n", (self.tmp / "out-a/SHA256SUMS").read_text())

        license_bytes = (REPO / "LICENSE.txt").read_bytes()
        with zipfile.ZipFile(self.tmp / f"out-a/sert-{VERSION}.zip") as zf:
            names = zf.namelist()
            self.assertEqual((names, names[:2], zf.read("LICENSE.txt")), (sorted(names), ["LICENSE.txt", "default.project.json"], license_bytes))
            self.assertTrue(all(i.date_time == (1980, 1, 1, 0, 0, 0) for i in zf.infolist()))

        pyz = self.tmp / f"out-a/sert-{VERSION}.pyz"
        self.assertEqual(subprocess.run([sys.executable, str(pyz), "--version"], capture_output=True, text=True).stdout.strip(), f"sert {VERSION}")
        with zipfile.ZipFile(pyz) as zf:
            self.assertEqual((zf.read("sert/_stub/sert.py"), zf.read("sert/LICENSE.txt")), ((REPO / "tools/sert.py").read_bytes(), license_bytes))
            self.assertFalse(any("__pycache__" in n for n in zf.namelist()))

        consumer = self.project('[lint]\nstub = true\n', name="consumer")
        (consumer / "tools").mkdir()
        shutil.copy(REPO / "tools/sert.py", consumer / "tools/sert.py")
        self.assertEqual(subprocess.run([sys.executable, str(pyz), "lint", "--root", str(consumer), "--skip", "sourcemap", "--skip", "analyze", "--skip", "stylua", "--skip", "selene", "--dry-run"], capture_output=True).returncode, 0)

        (first / "LICENSE.txt").unlink()
        with self.assertRaisesRegex(SertError, r"pack: LICENSE.txt not found"):
            pack.build(first, self.tmp / "out-missing")
        with self.assertRaisesRegex(SertError, r"pack: LICENSE.txt not found"):
            pack.pyz_entries(first)

        project = json.loads((REPO / "default.project.json").read_text())
        self.assertEqual((project["name"], project["tree"]), ("sert", {"$path": "src"}))

        pack.write_zip(self.tmp / "hello.zip", [("hello.txt", b"world")], prefix=b"#!/bin/sh\n")
        self.assertTrue((self.tmp / "hello.zip").read_bytes().startswith(b"#!/bin/sh\n"))
        self.assertEqual(self.sert("pack", "--root", second, "--out", "custom-dist")[0], 0)
        with self.assertRaisesRegex(SertError, r"pack: nonexistent-dir not found"):
            pack.tree_files(second, ["nonexistent-dir"])
        (second / "python/sert/__init__.py").write_text("# no version\n")
        with self.assertRaisesRegex(SertError, r"pack: no VERSION ="):
            pack.version_of(second)

    def test_dist_commits_revs_identities_and_packages(self):
        root = git_repo(self.tmp / "repo")
        (root / "sert.toml").write_text(DIST_TOML)
        (root / "default.project.json").write_text("{}\n")
        (root / "src").mkdir()
        (root / "src/init.luau").write_text("return 1\n")
        (root / "test.luau").write_text("-- not shipped\n")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "one")

        def state():
            return (git(root, "rev-parse", "HEAD"), git(root, "symbolic-ref", "HEAD"), git(root, "status", "--porcelain"), git(root, "ls-files", "-s"))

        before = state()
        self.assertEqual((self.sert("dist", "--root", root, "--dry-run")[0], git(root, "branch", "--list", "dist")), (0, ""))
        self.assertEqual(self.sert("dist", "--root", root)[0], 0)
        first = git(root, "rev-parse", "dist")
        self.assertEqual(git(root, "log", "-1", "--format=%s", "dist"), f"dist: Thing 1.2.3 (from {before[0]})")
        self.assertEqual((git(root, "ls-tree", "-r", "--name-only", "dist").split(), state()), (["default.project.json", "src/init.luau"], before))
        self.assertIn("up to date", self.sert("dist", "--root", root)[1])

        (root / "test.luau").write_text("-- changed\n")
        git(root, "commit", "-qam", "two")
        self.sert("dist", "--root", root)
        self.assertEqual(git(root, "rev-parse", "dist"), first)

        (root / "src/init.luau").write_text("return 2\n")
        git(root, "commit", "-qam", "three")
        (root / "src/init.luau").write_text("return 3 -- uncommitted\n")
        self.assertEqual(self.sert("dist", "--root", root)[0], 0)
        self.assertEqual((git(root, "rev-parse", "dist^"), git(root, "show", "dist:src/init.luau")), (first, "return 2"))

        (root / "src/init.luau").write_text("return 2\n")
        self.assertEqual(self.sert("dist", "--root", root, "--from", before[0])[0], 0)
        self.assertEqual(git(root, "show", "dist:src/init.luau"), "return 1")

        (root / "sert.toml").write_text(DIST_TOML.replace('["default.project.json", "src"]', '"src"'))
        self.assertEqual(self.sert("dist", "--root", root, "--dry-run")[0], 0)
        (root / "sert.toml").write_text(DIST_TOML.replace('"src"]', '"src", "nope"]'))
        self.assertEqual(self.sert("dist", "--root", root)[0], 2)
        (root / "sert.toml").write_text(DIST_TOML)

        self.setenv("GIT_AUTHOR_NAME", "github-actions[bot]")
        self.setenv("GIT_AUTHOR_EMAIL", "bot@example.com")
        (root / "src/init.luau").write_text("return 3\n")
        git(root, "commit", "-qam", "four")
        self.sert("dist", "--root", root)
        self.assertEqual(git(root, "log", "-1", "--format=%an <%ae>", "dist"), "github-actions[bot] <bot@example.com>")

        (root / "src/init.luau").write_text('return "4.5.6"\n')
        (root / "wally.toml").write_text('[package]\nname = "owner/thing"\nversion = "4.5.6"\n')
        base = DIST_TOML.replace('version = "1.2.3"\n', "")
        (root / "sert.toml").write_text(base)
        git(root, "add", "-A")
        git(root, "commit", "-qm", "wally version")
        self.assertEqual(self.sert("release", "dist", "--root", root)[0], 0)
        self.assertIn("dist: Thing 4.5.6 (from", git(root, "log", "-1", "--format=%s", "dist"))
        (root / "src/init.luau").write_text('return "5.0.0"\n')
        git(root, "commit", "-qam", "explicit version")
        self.assertEqual(self.sert("dist", "--root", root, "--version", "5.0.0")[0], 0)
        self.assertIn("dist: Thing 5.0.0 (from", git(root, "log", "-1", "--format=%s", "dist"))
        (root / "sert.toml").write_text("[dist]\n")
        self.assertEqual(self.sert("dist", "--root", root)[0], 2)

        (root / "sert.toml").write_text(DIST_TOML)
        git(root, "branch", "-D", "dist")
        git(root, "config", "--unset", "user.name")
        git(root, "config", "--unset", "user.email")
        home = self.tmp / "home"
        home.mkdir()
        for k, v in (("HOME", str(home)), ("XDG_CONFIG_HOME", str(home)), ("GIT_CONFIG_NOSYSTEM", "1"), ("EMAIL", None),
                     ("GIT_AUTHOR_NAME", None), ("GIT_AUTHOR_EMAIL", None), ("GIT_COMMITTER_NAME", None), ("GIT_COMMITTER_EMAIL", None)):
            self.setenv(k, v)
        git(root, "config", "user.useConfigOnly", "true")
        self.assertEqual(self.sert("dist", "--root", root)[0], 0)
        self.assertEqual(git(root, "log", "-1", "--format=%an <%ae>", "dist"), "sert <sert@localhost>")


if __name__ == "__main__":
    unittest.main()
