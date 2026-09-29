#!/usr/bin/env python3
"""Tests for copy-path's text rules: python3 test_copy_path.py"""

import importlib.util
import os
import unittest

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


def run(rows, conf=CFG, **kw):
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
        self.assertEqual(cp.resolve("./a", "~/p", c), "~/p/a")
        self.assertEqual(cp.resolve("../a", "~/p/q", c), "~/p/a")
        self.assertEqual(cp.resolve("a/", "/srv", c), "/srv/a/")
        self.assertEqual(cp.resolve("/etc/x", "~/p", c), "/etc/x")
        self.assertEqual(cp.resolve("~/x", "/srv", c), "~/x")
        self.assertEqual(cp.resolve("a", None, c), "a")
        self.assertEqual(cp.resolve("./a", "~/p", cfg(use_ps1=False)), "./a")
        self.assertEqual(cp.resolve("a", "~/p", cfg(use_ps1=True, expand_home=True)),
                         os.path.expanduser("~/p/a"))

    def test_cwd_fallback_and_exists_are_local_only(self):
        rows = ["$ out", "README.md plexenv"]   # no dir in any prompt
        region = cp.Region(1, 2, "cat", None)
        c = cfg(cwd_fallback=True, check_exists=True, prompt_regex=r"^\$ ")
        here = cp.find_paths(rows, region, c, pane_cwd=HERE)
        self.assertEqual(copies(here), [os.path.join(HERE, "README.md")])
        self.assertEqual(copies(cp.find_paths(rows, region, cfg(), pane_cwd=HERE)), ["README.md"])
        # check_exists never runs when the prompt dir isn't the local cwd (ssh)
        self.assertFalse(cp.local_base("/root", HERE))
        self.assertTrue(cp.local_base(HERE, HERE))


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
        rows = lines[:-1] + [lines[-1] + cmd, out] + lines[:-1] + [lines[-1]]
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

    def test_basename_only_prompt_stays_relative(self):
        self.check("[bob@box proj]$ ", ["a.txt"])

    def test_command_text_is_not_the_prompt_dir(self):
        self.check("~/proj ❯ ", ["~/proj/a.txt"], cmd="echo in /etc", dir_="~/proj")


if __name__ == "__main__":
    unittest.main()
