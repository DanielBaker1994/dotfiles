#!/usr/bin/env python3
"""Tests for copy-path's text rules: python3 test_copy_path.py"""

import importlib.util
import io
import os
import pty
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.realpath(__file__))
spec = importlib.util.spec_from_file_location("copy_path", os.path.join(HERE, "copy-path.py"))
assert spec and spec.loader
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

CFG = cp.load_config(os.path.join(HERE, "config.toml"))

# real starship screen: an ssh session (remote prompt), then back home
HOME_SERVER = """\
root in 🌐 mediaserver in ~
(INS) ❯ ls
docker-dashboard
root in 🌐 mediaserver in ~
(INS) ❯ pwd
/root
root in 🌐 mediaserver in ~
(INS) ❌ 130 ❯ Read from remote host 10.0.0.84: Connection reset by peer
Connection to 10.0.0.84 closed.
client_loop: send disconnect: Broken pipe
WARNING: ssh is not Homebrew: /opt/homebrew/bin/ssh
~/home_server via 🐍 v3.14.7 took 6h3m38s
(INS) ❯ ls
a                       plex_movies.pdf         Report.py
automation_scripts.sh   plex_tv.pdf             server.csr
docker_commands.sh      PlexAmpPopularLibrar.py server.key
Dockerfile              plexenv                 sync.py
~/home_server via 🐍 v3.14.7
(INS) ❯ """.split("\n")


def cfg(**over):
    c = dict(CFG)
    c.update(over)
    return c


def screen(rows):
    """Rows as pane.read returns them: trailing spaces (after an empty prompt) dropped."""
    return [r.rstrip() for r in rows]


def run(rows, conf=CFG, **kw):
    rows = screen(rows)
    region = cp.find_region(rows, conf)
    return region, cp.find_paths(rows, region, conf, **kw)


def copies(hits):
    return [h.copy for h in hits]


class RegionTest(unittest.TestCase):
    def test_last_output_only(self):
        region, hits = run(HOME_SERVER)
        self.assertEqual((region.start, region.end), (13, 17))
        self.assertEqual(region.command, "ls")
        self.assertEqual(region.dir, "~/home_server")
        self.assertNotIn("/root", copies(hits))
        self.assertNotIn("/opt/homebrew/bin/ssh", copies(hits))

    def test_ssh_prompt_dir(self):
        rows = HOME_SERVER[:6]   # ends at the remote "pwd" prompt
        region, hits = run(rows + ["root in 🌐 mediaserver in ~", "(INS) ❯ "])
        self.assertEqual(region.command, "pwd")
        self.assertEqual(region.dir, "~")
        self.assertEqual(copies(hits), ["/root"])

    def test_no_prompt_is_whole_screen(self):
        rows = ["  see src/app.py for details", "", "  ~/notes/todo.md"]
        region, hits = run(rows)
        self.assertEqual((region.start, region.end), (0, 3))
        self.assertEqual(copies(hits), ["src/app.py", "~/notes/todo.md"])

    def test_agent_pane_is_whole_screen(self):
        region = cp.find_region(HOME_SERVER, CFG, whole_screen=True)
        self.assertEqual(region.start, 0)

    def test_running_command_after_prompt(self):
        rows = ["~/proj", "(INS) ❯ tail -f log/app.log", "wrote build/out.js", ""]
        region, hits = run(rows)
        self.assertEqual((region.start, region.end), (2, 3))
        self.assertEqual(copies(hits), ["~/proj/build/out.js"])

    def test_previous_prompt_scrolled_away(self):
        rows = ["x/y.txt", "~/proj", "(INS) ❯ "]
        region, hits = run(rows)
        self.assertEqual((region.start, region.end), (0, 1))
        self.assertEqual(copies(hits), ["~/proj/x/y.txt"])


class LsTest(unittest.TestCase):
    def test_bare_names_and_dirs(self):
        _, hits = run(HOME_SERVER)
        got = copies(hits)
        for name in ("a", "plexenv", "Dockerfile", "Report.py", "server.key"):
            self.assertIn(f"~/home_server/{name}", got)
        self.assertEqual(len(got), 12)

    def test_plain_bash_remote_prompt(self):
        rows = ["root@box:/var/log# ls", "syslog  nginx  auth.log", "root@box:/var/log# "]
        region, hits = run(rows, cfg(prompt_height=2))
        self.assertEqual(region.dir, "/var/log")
        self.assertEqual(copies(hits), ["/var/log/syslog", "/var/log/nginx", "/var/log/auth.log"])

    def test_long_listing_takes_name_column(self):
        rows = ["~/proj", "(INS) ❯ ls -la",
                "total 48",
                "drwxr-xr-x@  4 dan  staff   128 Sep 27 12:17 herdr",
                "-rw-r--r--@  1 dan  staff  2204 Sep 27 12:44 config.toml",
                "lrwxr-xr-x@  1 dan  staff    46 Sep 26 15:16 cfg -> /etc/herdr/config.toml",
                "~/proj", "(INS) ❯ "]
        _, hits = run(rows)
        self.assertEqual(copies(hits), ["~/proj/herdr", "~/proj/config.toml", "~/proj/cfg",
                                        "/etc/herdr/config.toml"])

    def test_ls_of_other_dir(self):
        rows = ["~/proj/sub", "(INS) ❯ ls ../lib", "util.py  helpers", "~/proj/sub", "(INS) ❯ "]
        _, hits = run(rows)
        self.assertEqual(copies(hits), ["~/proj/lib/util.py", "~/proj/lib/helpers"])

    def test_ls_headers(self):
        rows = ["~/p", "(INS) ❯ ls a b", "a:", "x.txt", "", "b:", "y", "~/p", "(INS) ❯ "]
        _, hits = run(rows)
        self.assertEqual(copies(hits), ["~/p/a", "~/p/a/x.txt", "~/p/b", "~/p/b/y"])

    def test_ls_F_markers(self):
        rows = ["~/p", "(INS) ❯ ls -F", "bin/  run.sh*  link@", "~/p", "(INS) ❯ "]
        _, hits = run(rows)
        self.assertEqual(copies(hits), ["~/p/bin/", "~/p/run.sh", "~/p/link"])


class TokenTest(unittest.TestCase):
    def out(self, command, *lines, **over):
        rows = ["~/p", f"(INS) ❯ {command}", *lines, "~/p", "(INS) ❯ "]
        return copies(run(rows, cfg(**over))[1])

    def test_grep_line_numbers(self):
        self.assertEqual(self.out("rg foo", "src/a.py:12:3: foo()", "b/c.rs:7:foo"),
                         ["~/p/src/a.py", "~/p/b/c.rs"])

    def test_git_status(self):
        self.assertEqual(self.out("git status", "\tmodified:   x/y.py", "\tnew file:   README.md"),
                         ["~/p/x/y.py", "~/p/README.md"])

    def test_rejects_non_paths(self):
        got = self.out("echo", "see https://herdr.dev/x --flag v3.14.7 3.14 2024/01/02",
                       "commit 2927dcf2bc95fe53a7143c040bbdcbcf804d65ed done words here")
        self.assertEqual(got, [])

    def test_bare_words_need_ls(self):
        self.assertEqual(self.out("cat notes", "plexenv Dockerfile"), [])

    def test_quotes_and_punctuation(self):
        self.assertEqual(self.out("make", "error in 'lib/x.c', see (docs/y.md)."),
                         ["~/p/lib/x.c", "~/p/docs/y.md"])

    def test_key_value(self):
        self.assertEqual(self.out("env", "CONFIG=~/.config/app.toml"), ["~/.config/app.toml"])

    def test_dotfiles_only_in_listings(self):
        self.assertEqual(self.out("jq .a", "use .workspace_id or .bashrc"), [])
        self.assertEqual(self.out("ls -a", ".bashrc  .config"), ["~/p/.bashrc", "~/p/.config"])

    def test_single_letter_slashes_are_prose(self):
        self.assertEqual(self.out("rm -i x", "remove? y/N", "or a/bc"), ["~/p/a/bc"])

    def test_without_ps1(self):
        self.assertEqual(self.out("find .", "./a/b.txt", "../c.md", use_ps1=False),
                         ["./a/b.txt", "../c.md"])

    def test_wrapped_path(self):
        rows = ["~/p", "(INS) ❯ echo", "x /very/long/pa", "th/file.txt y", "~/p", "(INS) ❯ "]
        region = cp.find_region(rows, CFG)
        hits = cp.find_paths(rows, region, CFG, wrap_width=15)
        self.assertEqual(copies(hits), ["/very/long/path/file.txt"])
        self.assertEqual(hits[0].spans, [(2, 2, 15), (3, 0, 11)])


class ResolveTest(unittest.TestCase):
    def test_resolve(self):
        c = cfg(use_ps1=True)
        self.assertEqual(cp.resolve("./a", "~/p", None, c), "~/p/a")
        self.assertEqual(cp.resolve("../a", "~/p/q", None, c), "~/p/a")
        self.assertEqual(cp.resolve("a/", "/srv", None, c), "/srv/a/")
        self.assertEqual(cp.resolve("/etc/x", "~/p", None, c), "/etc/x")
        self.assertEqual(cp.resolve("~/x", "/srv", None, c), "~/x")
        self.assertEqual(cp.resolve("~/x", "/srv", "/home/me", c), "/home/me/x")
        self.assertEqual(cp.resolve("~", "/srv", "/home/me", c), "/home/me")
        self.assertEqual(cp.resolve("~bob/x", "/srv", "/home/me", c), "~bob/x")
        self.assertEqual(cp.resolve("a", None, None, c), "a")
        self.assertEqual(cp.resolve("./a", "~/p", "/home/me", cfg(use_ps1=False)), "./a")

    def test_check_exists_is_local_only(self):
        rows = ["$ out", "README.md plexenv"]   # no dir in any prompt
        region = cp.Region(1, 2, "cat", None)
        c = cfg(check_exists=True)
        here = cp.find_paths(rows, region, c, local_cwd=HERE)
        self.assertEqual(copies(here), [os.path.join(HERE, "README.md")])
        # over ssh (no local cwd) a bare word never touches the local disk
        self.assertEqual(copies(cp.find_paths(rows, region, c)), ["README.md"])


class LocalTest(unittest.TestCase):
    """A local pane: every copy is a full path from $HOME / the shell's cwd."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self.tmp.name)
        self.proj = os.path.join(self.home, "code", "proj")
        os.makedirs(os.path.join(self.proj, "src"))
        self.env = mock.patch.dict(os.environ, {"HOME": self.home})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def check(self, prompt, expect, out="./test.txt test.txt ../up.md /etc/hosts ~/notes.md",
              cmd="echo", cwd=None):
        lines = prompt.split("\n")
        rows = screen(lines[:-1] + [lines[-1] + cmd, out] + lines[:-1] + [lines[-1]])
        region = cp.find_region(rows, CFG)
        self.assertEqual((region.start, region.end), (len(lines), len(lines) + 1), "prompt not recognised")
        got = copies(cp.find_paths(rows, region, CFG, local_cwd=cwd or self.proj))
        self.assertEqual(got, expect)
        for path in got:
            self.assertTrue(path.startswith("/"), path)

    def full(self, rel):
        return os.path.normpath(os.path.join(self.proj, rel))

    def test_relative_names_join_the_prompt_dir(self):
        expect = [self.full("test.txt"), self.full("test.txt"), self.full("../up.md"),
                  "/etc/hosts", os.path.join(self.home, "notes.md")]
        for prompt in [
            "~/code/proj via 🐍\n(INS) ❯ ",        # starship (the real one here)
            "~/code/proj\n❯ ",                      # pure
            "~/code/proj ❯ ",
            "bob@mac:~/code/proj$ ",                 # bash
            f"bob@mac:{self.proj}$ ",
            "bob@mac ~/code/proj % ",                # zsh with %~
            "bob@mac proj % ",                       # macOS zsh default (%1~): name only
            "[bob@mac proj]$ ",                      # fedora: name only
            "mac:proj bob$ ",                        # macOS bash default: name only
            "➜  proj git:(main) ✗ ",                 # oh-my-zsh robbyrussell
            "bob@mac ~/c/proj> ",                    # fish: abbreviated parents
            "proj on  main via 🐍 v3.14\n❯ ",        # starship truncated to the repo
            "┌──(bob㉿kali)-[~/code/proj]\n└─$ ",     # kali
            "┌─[bob@parrot]─[~/code/proj]\n└──╼ $",   # parrot
            "bob@PC MINGW64 ~/code/proj (main)\n$ ",  # git bash
            "bash-5.2$ ",                            # no dir at all: the shell's cwd
        ]:
            # bash vi-mode (show-mode-in-prompt) puts "(INS) " on the input row
            lines = prompt.split("\n")
            vi = "\n".join(lines[:-1] + ["(INS) " + lines[-1]])
            vi_venv = "\n".join(lines[:-1] + ["(INS) (venv) " + lines[-1]])
            for p in (prompt, vi, vi_venv):
                with self.subTest(prompt=p):
                    self.check(p, expect)

    def test_partial_dir_after_cd(self):
        """The prompt only showed the tail of its dir and the shell has cd'd since."""
        src = os.path.join(self.proj, "src")
        for prompt, cwd in [
            ("code/proj\n(INS) ❯ ", os.path.dirname(self.proj)),  # starship truncated, then cd ..
            ("code/proj\n(INS) ❯ ", src),                          # … then cd src
            ("…/code/proj on  main\n❯ ", src),
            ("bob@mac ~/c/proj> ", src),                           # fish abbreviation, then cd src
            ("[bob@mac proj]$ ", src),
        ]:
            with self.subTest(prompt=prompt, cwd=cwd):
                self.check(prompt, [self.full("test.txt")], out="test.txt", cwd=cwd)

    def test_ls_in_home(self):
        self.check("~ ❯ ", [os.path.join(self.home, "a.txt")], out="a.txt", cmd="ls",
                   cwd=self.home)

    def test_ls_of_subdir(self):
        self.check("bob@mac proj % ", [self.full("src/x.py")], out="x.py", cmd="ls src")

    def test_name_only_prompt_that_isnt_the_cwd_stays_relative(self):
        # the shell has since cd'd elsewhere: "other" can't be placed, don't invent a path
        rows = ["[bob@mac other]$ cat x", "test.txt", "[bob@mac proj]$ "]
        region = cp.find_region(rows, CFG)
        self.assertEqual(copies(cp.find_paths(rows, region, CFG, local_cwd=self.proj)), ["test.txt"])

    def test_prompt_row_above_is_output_not_header(self):
        rows = ["bash-5.2$ cat f", "/var/log/x.log", "bash-5.2$ "]
        region = cp.find_region(rows, CFG)
        self.assertEqual((region.start, region.end), (1, 2))
        self.assertEqual(copies(cp.find_paths(rows, region, CFG, local_cwd=self.proj)),
                         ["/var/log/x.log"])


class RemoteTest(unittest.TestCase):
    """Over ssh only the prompt's text counts (herdr is never on the remote)."""

    def run_remote(self, prompt, out):
        lines = prompt.split("\n")
        rows = screen(lines[:-1] + [lines[-1] + "ls", out] + lines[:-1] + [lines[-1]])
        region = cp.find_region(rows, CFG)
        return copies(cp.find_paths(rows, region, CFG))   # no local_cwd: remote

    def test_absolute_prompt_dir(self):
        self.assertEqual(self.run_remote("bob@srv:/var/log$ ", "./syslog"), ["/var/log/syslog"])

    def test_root_home(self):
        self.assertEqual(self.run_remote("root@srv:~/app# ", "a.py"), ["/root/app/a.py"])
        self.assertEqual(self.run_remote("root in 🌐 srv in ~\n(INS) ❯ ", "a.py"), ["/root/a.py"])
        self.assertEqual(self.run_remote("┌──(root㉿kali)-[~]\n└─# ", "a.py"), ["/root/a.py"])

    def test_unknown_home_stays_tilde(self):
        # bob's home could be /home/bob, /Users/bob, /var/lib/bob: don't guess
        self.assertEqual(self.run_remote("bob@srv:~/app$ ", "a.py"), ["~/app/a.py"])

    def test_local_cwd_is_never_used(self):
        self.assertEqual(self.run_remote("[bob@srv app]$ ", "a.py"), ["a.py"])
        self.assertEqual(self.run_remote("bash-5.2$ ", "a.py"), ["a.py"])


class PromptEdgeTest(unittest.TestCase):
    def test_bare_dollar_needs_a_header(self):
        # a README with "$ npm i" lines is output, not prompts
        rows = ["~/p", "(INS) ❯ cat README.md", "$ npm i", "see docs/a.md", "~/p", "(INS) ❯ "]
        region, hits = run(rows)
        self.assertEqual((region.start, region.end), (2, 4))
        self.assertEqual(copies(hits), ["~/p/docs/a.md"])

    def test_command_args_are_not_the_dir(self):
        rows = ["bob@PC MINGW64 ~/p", "$ ls /etc", "hosts", "bob@PC MINGW64 ~/p", "$ "]
        region, hits = run(rows)
        self.assertEqual(region.dir, "~/p")
        self.assertEqual(region.command, "ls /etc")
        self.assertEqual(copies(hits), ["/etc/hosts"])

    def test_exit_code_prompt(self):
        rows = ["~/p", "(INS) ❌ 130 ❯ ls", "a.txt", "~/p", "(INS) ❯ "]
        region, _ = run(rows)
        self.assertEqual((region.start, region.end, region.dir), (2, 3, "~/p"))


class ConfigTest(unittest.TestCase):
    def test_config_matches_code_defaults(self):
        for key, value in [("prompt_regex", cp.PROMPT_REGEX), ("bare_prompt_regex", cp.BARE_PROMPT_REGEX),
                           ("ps1_dir_regex", cp.DIR_REGEX), ("ps1_header_regex", cp.HEADER_REGEX),
                           ("remote_commands", cp.REMOTE_COMMANDS)]:
            self.assertEqual(CFG[key], value, key)


class OverlayTest(unittest.TestCase):
    def test_pick_copies_and_returns_at_once(self):
        """No flash, no toast: a completed hint returns as soon as it is typed."""
        rows = ["~/p", "(INS) ❯ ls", "a.txt", "~/p", "(INS) ❯ "]
        region, hits = run(rows)
        hits = cp.assign_labels(hits, CFG["alphabet"])
        full = {"x": 0, "y": 0, "width": 80, "height": 5}
        ui = cp.Overlay(rows, region, hits, {"rect": full, "area": full}, CFG)
        master, slave = pty.openpty()
        # typed once the overlay is in raw mode (setraw flushes earlier input)
        threading.Timer(0.02, os.write, (master, b"a")).start()
        picked = []
        with open(slave, "r") as stdin, \
                mock.patch.object(cp.sys, "stdin", stdin), \
                mock.patch.object(cp.sys, "stdout", io.StringIO()), \
                mock.patch.object(cp.os, "get_terminal_size", return_value=os.terminal_size((80, 5))):
            t = time.monotonic()
            got = ui.run(on_pick=picked.append)
            elapsed = time.monotonic() - t
        os.close(master)
        self.assertEqual(got.copy, "~/p/a.txt")
        self.assertEqual(picked, [got])
        self.assertLess(elapsed, 0.1)   # 20ms of that is the simulated typing


class SpeedTest(unittest.TestCase):
    def test_full_screen_is_fast(self):
        rows = (["~/p", "(INS) ❯ ls -la"] +
                [f"-rw-r--r--@  1 dan  staff  2204 Sep 27 12:44 file{i}.txt" for i in range(200)] +
                ["~/p", "(INS) ❯ "])
        t = time.monotonic()
        _, hits = run(rows, local_cwd=None)
        cp.assign_labels(hits, CFG["alphabet"])
        self.assertLess(time.monotonic() - t, 0.05)
        self.assertEqual(len(hits), 200)


class LabelTest(unittest.TestCase):
    def test_prefix_free(self):
        for n in (1, 25, 26, 60, 200):
            labels = cp.hint_labels(n, CFG["alphabet"])
            self.assertEqual(len(set(labels)), n)
            for a in labels:
                self.assertFalse(any(b != a and b.startswith(a) for b in labels))

    def test_nearest_prompt_gets_first_letter_and_dupes_share(self):
        rows = ["~/p", "(INS) ❯ x", "a.txt b.txt", "a.txt", "~/p", "(INS) ❯ "]
        _, hits = run(rows)
        hits = cp.assign_labels(hits, "asd")
        self.assertEqual([h.label for h in hits], ["a", "s", "a"])


class PromptShapesTest(unittest.TestCase):
    """PS1 + listed name → absolute path, for common prompt shapes."""

    def check(self, prompt, expect, cmd="ls", out="a.txt", dir_=None):
        lines = prompt.split("\n")
        rows = screen(lines[:-1] + [lines[-1] + cmd, out] + lines[:-1] + [lines[-1]])
        region = cp.find_region(rows, CFG)
        self.assertEqual(region.dir, dir_)
        self.assertEqual(copies(cp.find_paths(rows, region, CFG)), expect)

    def test_shapes(self):
        for prompt, dir_ in [
            ("~/proj via 🐍\n❯ ", "~/proj"),
            ("~/proj ❯ ", "~/proj"),
            ("(venv) ~/proj ❯ ", "~/proj"),
            ("bob@box:~/proj$ ", "~/proj"),
            ("(venv) bob@box:~/proj$ ", "~/proj"),
            ("bob@box ~/proj % ", "~/proj"),
            ("bob@box ~/proj $ ", "~/proj"),
            ("~/proj % ", "~/proj"),
            ("~/proj $ ", "~/proj"),
        ]:
            with self.subTest(prompt=prompt):
                self.check(prompt, [dir_ + "/a.txt"], dir_=dir_)

    def test_absolute_dir_and_gt(self):
        self.check("root@box:/var/log# ", ["/var/log/a.txt"], dir_="/var/log")
        self.check("/tmp/x> ", ["/tmp/x/a.txt"], dir_="/tmp/x")

    def test_name_only_prompts(self):
        # the dir as shown; turned into a full path only on a local pane
        self.check("[bob@box proj]$ ", ["a.txt"], dir_="proj")
        self.check("box:proj bob$ ", ["a.txt"], dir_="proj")
        self.check("➜  proj git:(main) ✗ ", ["a.txt"], dir_="proj")

    def test_command_text_is_not_the_prompt_dir(self):
        self.check("~/proj ❯ ", ["~/proj/a.txt"], cmd="echo in /etc", dir_="~/proj")


if __name__ == "__main__":
    unittest.main()
