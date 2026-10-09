#!/usr/bin/env python3
"""claude-desktop-webext: load several plain MV3 extensions into Claude Desktop (Linux).

Linux counterpart of webext.ps1; both follow docs/SPEC.md and must generate the same
manifest.json for the same input. Python 3.8+, standard library only, no root.

Claude Desktop loads exactly one unpacked extension, from
~/.config/Claude/extensions/fmkadmapgofadopljbjfkapdkoienihi, when REACT_PROFILE=1.
Each tool's extension is kept as a normal folder under
~/.local/share/claude-desktop-webext/web-extensions/<id>/ and that one slot is rebuilt
from all of them. Never modifies Claude itself and never closes Claude.
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import sys

LOADER_VERSION = "0.1.0"
SCHEMA = 1
SLOT_ID = "fmkadmapgofadopljbjfkapdkoienihi"
SLOT_MARKER = ".claude-desktop-webext.json"
DEFAULT_ORDER = 100
ENV_FILE_NAME = "90-claude-desktop-webext.conf"
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
ALLOWED_TOP_KEYS = ["manifest_version", "name", "short_name", "version", "version_name", "description", "author",
                    "homepage_url", "icons", "minimum_chrome_version", "browser_specific_settings", "content_scripts",
                    "permissions"]
ALLOWED_PERMS = ["storage"]
ALLOWED_CS_KEYS = ["matches", "exclude_matches", "include_globs", "exclude_globs", "css", "js", "run_at", "world",
                   "all_frames", "match_about_blank", "match_origin_as_fallback"]
COLORS = {"OK": "\033[32m", "INFO": "\033[90m", "WARN": "\033[33m", "NG": "\033[31m"}


class Abort(Exception):
    def __init__(self, code, message=None):
        super().__init__(message or "")
        self.code = code
        self.message = message


# ---------------------------------------------------------------- JSON helpers
def format_json(value):
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, value):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(format_json(value))


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def copy_verified(src, dst):
    os.makedirs(dst, exist_ok=True)
    for root, _dirs, files in os.walk(src):
        for name in files:
            s = os.path.join(root, name)
            rel = os.path.relpath(s, src)
            d = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d)
            if sha256(s) != sha256(d):
                raise RuntimeError("copy verification failed: " + rel)


class Paths:
    def __init__(self, sandbox):
        self.sandbox = sandbox
        if sandbox:
            home = sandbox
            config = os.path.join(home, ".config")
            data = os.path.join(home, ".local", "share")
            self.etc = os.path.join(sandbox, "etc")
            self.root = sandbox
        else:
            home = os.path.expanduser("~")
            config = os.environ.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
            data = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
            self.etc = "/etc"
            self.root = "/"
        self.home = home
        self.user_data = os.path.join(config, "Claude")
        self.ext_dir = os.path.join(self.user_data, "extensions")
        self.slot = os.path.join(self.ext_dir, SLOT_ID)
        self.env_dir = os.path.join(config, "environment.d")
        self.env_file = os.path.join(self.env_dir, ENV_FILE_NAME)
        self.home_dir = os.path.join(data, "claude-desktop-webext")
        self.store = os.path.join(self.home_dir, "web-extensions")
        self.state_file = os.path.join(self.home_dir, "state.json")
        self.backups = os.path.join(self.home_dir, "backups")
        self.lock_file = os.path.join(self.home_dir, ".lock")


class Loader:
    def __init__(self, args):
        self.args = args
        self.p = Paths(args.sandbox)
        self.undo = []

    def step(self, name):
        if self.args.fail_at == name:
            raise RuntimeError("intentional test failure at: " + name)

    # ------------------------------------------------------------ REACT_PROFILE
    @staticmethod
    def _scan_file(path, env_style):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            return None
        pat = re.compile(r"^\s*REACT_PROFILE\s*(?:DEFAULT\s*=\s*)?=?\s*(.*)$") if env_style == "pam" else \
            re.compile(r"^\s*(?:export\s+)?REACT_PROFILE\s*=\s*(.*?)\s*$")
        value = None
        for line in lines:
            m = pat.match(line)
            if m:
                value = m.group(1).strip().strip('"').strip("'")
        return value

    def react_profile(self):
        """Returns (ours, foreign_user, system) where each is a value or None.
        foreign_user is (value, source)."""
        ours = self._scan_file(self.p.env_file, "sh") if os.path.isfile(self.p.env_file) else None
        foreign = None
        candidates = sorted(glob.glob(os.path.join(self.p.env_dir, "*.conf")))
        candidates = [c for c in candidates if os.path.basename(c) != ENV_FILE_NAME]
        candidates += [os.path.join(self.p.home, n) for n in (".profile", ".bash_profile", ".bashrc", ".zshenv")]
        for c in candidates:
            if os.path.isfile(c):
                v = self._scan_file(c, "sh")
                if v is not None:
                    foreign = (v, c)
                    break
        if foreign is None and os.path.isfile(os.path.join(self.p.home, ".pam_environment")):
            v = self._scan_file(os.path.join(self.p.home, ".pam_environment"), "pam")
            if v is not None:
                foreign = (v, "~/.pam_environment")
        if foreign is None and not self.args.sandbox and ours is None and os.environ.get("REACT_PROFILE") is not None:
            foreign = (os.environ["REACT_PROFILE"], "process environment")
        system = None
        for c in [os.path.join(self.p.etc, "environment")] + sorted(glob.glob(os.path.join(self.p.etc, "environment.d", "*.conf"))):
            if os.path.isfile(c):
                v = self._scan_file(c, "sh")
                if v is not None:
                    system = (v, c)
                    break
        return ours, foreign, system

    # ------------------------------------------------------------ state / config
    def read_state(self):
        s = read_json(self.p.state_file)
        if not isinstance(s, dict):
            s = {"schema": SCHEMA, "generation": 0, "envSetByUs": False, "extensions": {}}
        if int(s.get("schema", 0)) > SCHEMA:
            raise Abort(1, "state.json was written by a newer claude-desktop-webext (schema %s). Update this tool." % s.get("schema"))
        if not isinstance(s.get("extensions"), dict):
            s["extensions"] = {}
        return s

    def save_state(self, state):
        os.makedirs(self.p.home_dir, exist_ok=True)
        write_json(self.p.state_file, state)

    def resolve_request(self):
        a = self.args
        r = {"id": a.id, "source": a.source, "order": a.order, "displayName": None, "tested": [],
             "adoptMarkers": [], "adoptNames": []}
        if a.config:
            c = read_json(a.config)
            if not isinstance(c, dict):
                raise Abort(1, "cannot read config: " + a.config)
            base = os.path.dirname(os.path.abspath(a.config))
            r["id"] = r["id"] or c.get("id")
            if not r["source"] and c.get("source"):
                r["source"] = os.path.join(base, c["source"])
            if r["order"] < 0 and c.get("order") is not None:
                r["order"] = int(c["order"])
            r["displayName"] = c.get("displayName")
            r["tested"] = list((c.get("testedClaudeVersions") or {}).get("linux") or [])
            adopt = c.get("adopt") or {}
            r["adoptMarkers"] = list(adopt.get("markers") or [])
            r["adoptNames"] = list(adopt.get("manifestNames") or [])
        if r["id"] and not ID_RE.match(r["id"]):
            raise Abort(1, "invalid extension id: " + r["id"])
        r["displayName"] = r["displayName"] or r["id"]
        return r

    # ------------------------------------------------------------ validation / merge
    @staticmethod
    def _rel_ok(p):
        if not isinstance(p, str) or not p or "\\" in p or p.startswith("/") or re.match(r"^[A-Za-z]:", p) \
                or "?" in p or "#" in p:
            return False
        return all(seg not in ("", ".", "..") for seg in p.split("/"))

    def test_extension(self, d, ext_id):
        def fail(why):
            return {"ok": False, "reason": why}
        m = read_json(os.path.join(d, "manifest.json"))
        if not isinstance(m, dict):
            return fail("manifest.json missing or not valid JSON")
        if m.get("manifest_version") != 3 or isinstance(m.get("manifest_version"), bool):
            return fail("manifest_version must be 3")
        for k in m:
            if k not in ALLOWED_TOP_KEYS:
                return fail("unsupported manifest key: " + k)
        name = m.get("name")
        if not isinstance(name, str) or "__MSG_" in name:
            return fail("name must be a plain string (no __MSG_ placeholders)")
        perms = m.get("permissions") or []
        if not isinstance(perms, list):
            perms = [perms]
        for p in perms:
            if p not in ALLOWED_PERMS:
                return fail("unsupported permission: " + str(p))
        cs = m.get("content_scripts") or []
        if not isinstance(cs, list):
            cs = [cs]
        if not cs:
            return fail("no content_scripts")
        out = []
        for entry in cs:
            if not isinstance(entry, dict):
                return fail("content_scripts entry is not an object")
            copy = {}
            for k, v in entry.items():
                if k not in ALLOWED_CS_KEYS:
                    return fail("unsupported content_scripts key: " + k)
                if k in ("js", "css"):
                    paths = []
                    for p in (v if isinstance(v, list) else [v]):
                        if not self._rel_ok(p):
                            return fail("invalid %s path: %s" % (k, p))
                        if not os.path.isfile(os.path.join(d, *p.split("/"))):
                            return fail("missing file: " + p)
                        paths.append("ext/%s/%s" % (ext_id, p))
                    v = paths
                elif k == "matches":
                    v = v if isinstance(v, list) else [v]
                    if not v:
                        return fail("content_scripts.matches is empty")
                elif k == "world" and v not in ("MAIN", "ISOLATED"):
                    return fail("invalid world: " + str(v))
                elif k == "run_at" and v not in ("document_start", "document_end", "document_idle"):
                    return fail("invalid run_at: " + str(v))
                copy[k] = v
            if "matches" not in copy:
                return fail("content_scripts entry without matches")
            if "js" not in copy and "css" not in copy:
                return fail("content_scripts entry without js/css")
            out.append(copy)
        return {"ok": True, "reason": None, "version": str(m.get("version", "")), "name": name,
                "scripts": out, "permissions": perms}

    def plan(self, state, generation):
        entries, skipped = [], []
        if os.path.isdir(self.p.store):
            for name in sorted(os.listdir(self.p.store)):
                d = os.path.join(self.p.store, name)
                if name.startswith(".") or not os.path.isdir(d):
                    continue
                meta = state["extensions"].get(name) or {}
                order = int(meta.get("order", DEFAULT_ORDER))
                if not ID_RE.match(name):
                    skipped.append({"id": name, "reason": "invalid folder name"})
                    continue
                t = self.test_extension(d, name)
                if t["ok"]:
                    entries.append({"id": name, "order": order, "dir": d, "test": t})
                else:
                    skipped.append({"id": name, "reason": t["reason"]})
        entries.sort(key=lambda e: (e["order"], e["id"]))
        skipped.sort(key=lambda s: s["id"])
        perms = sorted({p for e in entries for p in e["test"]["permissions"]})
        scripts = [s for e in entries for s in e["test"]["scripts"]]
        ids = [e["id"] for e in entries]
        manifest = {
            "manifest_version": 3,
            "name": "Claude Desktop WebExt",
            "version": "1.%d.%d" % (generation // 65535, generation % 65535),
            "description": "Generated by claude-desktop-webext. Do not edit. Extensions: " + ", ".join(ids),
        }
        if perms:
            manifest["permissions"] = perms
        manifest["content_scripts"] = scripts
        marker = {
            "schema": SCHEMA, "tool": "claude-desktop-webext", "loaderVersion": LOADER_VERSION,
            "generation": generation, "generatedAt": now(),
            "extensions": [{"id": e["id"], "version": e["test"]["version"], "order": e["order"]} for e in entries],
            "skipped": skipped,
        }
        return {"entries": entries, "skipped": skipped, "manifest": manifest, "marker": marker}

    # ------------------------------------------------------------ ownership / findings
    def slot_owner(self, path, req):
        if not os.path.exists(path):
            return "none"
        marker = read_json(os.path.join(path, SLOT_MARKER))
        if isinstance(marker, dict) and marker.get("tool") == "claude-desktop-webext":
            return "ours"
        if req:
            for f in req["adoptMarkers"]:
                if f and os.path.exists(os.path.join(path, f)):
                    return "adoptable"
        man = read_json(os.path.join(path, "manifest.json"))
        name = man.get("name") if isinstance(man, dict) else None
        if req and name and name in req["adoptNames"]:
            return "adoptable"
        if isinstance(name, str) and re.search("React Developer Tools", name):
            return "react-devtools"
        return "unknown"

    def find_app_asars(self):
        if self.args.claude_path:
            path = os.path.abspath(self.args.claude_path)
            if os.path.isfile(path) and os.path.basename(path) == "app.asar":
                return [path]
            base = path if os.path.isdir(path) else os.path.dirname(path)
            if not os.path.exists(path):
                return []
            return [p for p in (os.path.join(base, "resources", "app.asar"),
                               os.path.join(base, "app.asar")) if os.path.isfile(p)]
        pats = ["usr/lib/*laude*/resources/app.asar", "opt/*laude*/resources/app.asar",
                "usr/share/*laude*/resources/app.asar", "usr/lib/*laude*/app.asar", "opt/*laude*/app.asar"]
        return sorted(set(os.path.realpath(hit) for pat in pats
                          for hit in glob.glob(os.path.join(self.p.root, pat)) if os.path.isfile(hit)))

    def findings(self, req, mode):
        out = []

        def add(level, item, detail):
            out.append((level, item, detail))
        add("INFO", "Loader", "claude-desktop-webext %s, Python %s" % (LOADER_VERSION, sys.version.split()[0]))
        candidates = self.find_app_asars()
        for candidate in candidates:
            add("INFO", "Claude candidate", candidate)
        asar = candidates[0] if len(candidates) == 1 else None
        if len(candidates) > 1:
            add("NG", "Claude", "Multiple installations found. Specify --claude-path with the intended executable, directory or app.asar.")
        elif self.args.claude_path and not asar:
            add("NG", "Claude", "--claude-path does not identify an installation containing app.asar.")
        elif not asar:
            add("WARN", "Claude", "Claude Desktop installation (app.asar) was not found in the usual places.")
        else:
            try:
                with open(asar, "rb") as f:
                    has_loader = b"REACT_PROFILE" in f.read()
            except OSError:
                has_loader = None
            if has_loader is None:
                add("NG", "Claude", "Cannot read app.asar to check the loader: " + asar)
            elif has_loader:
                add("OK", "Claude", asar)
            else:
                add("NG", "Claude", asar + " does not contain the REACT_PROFILE loader; this build cannot load extensions.")
        if os.path.isdir(self.p.user_data):
            add("OK", "Claude user data", self.p.user_data)
        else:
            add("NG", "Claude user data", self.p.user_data + " does not exist. Start Claude once first.")
        raw = read_json(self.p.state_file)
        if isinstance(raw, dict) and int(raw.get("schema", 0)) > SCHEMA:
            add("NG", "Loader", "state.json was written by a newer claude-desktop-webext (schema %s). Update this tool." % raw.get("schema"))
            return out
        slot_marker = read_json(os.path.join(self.p.slot, SLOT_MARKER))
        if isinstance(slot_marker, dict) and int(slot_marker.get("schema", 0)) > SCHEMA:
            add("NG", "Loader", "the slot was generated by a newer claude-desktop-webext (schema %s). Update this tool." % slot_marker.get("schema"))
            return out
        owner = self.slot_owner(self.p.slot, req)
        if owner == "none":
            add("OK", "Slot", "empty")
        elif owner == "ours":
            gen = (read_json(os.path.join(self.p.slot, SLOT_MARKER)) or {}).get("generation")
            add("OK", "Slot", "managed by claude-desktop-webext (generation %s)" % gen)
        elif owner == "adoptable":
            add("OK", "Slot", "previous standalone install of %s; it will be moved to backups and taken over" % req["displayName"])
        elif owner == "react-devtools":
            add("NG", "Slot", "the real React DevTools is installed there; it will not be overwritten.")
        elif mode == "rebuild" and self.args.take_over:
            add("WARN", "Slot", "unknown content; --take-over moves it to backups.")
        else:
            add("NG", "Slot", self.p.slot + " is used by another tool. Update that tool to a claude-desktop-webext based version, or remove it.")
        ours, foreign, system = self.react_profile()
        if system:
            add("NG", "REACT_PROFILE (system)", "value '%s' in %s; system-wide settings are not changed." % system)
        if ours is not None:
            add("OK", "REACT_PROFILE (user)", "1 (%s)" % self.p.env_file)
        elif foreign is None:
            add("OK", "REACT_PROFILE (user)", "not set")
        elif foreign[0] == "1":
            add("OK", "REACT_PROFILE (user)", "1 (%s)" % foreign[1])
        else:
            add("NG", "REACT_PROFILE (user)", "value '%s' in %s is used for something else; it will not be changed." % foreign)
        if os.path.exists(self.p.lock_file):
            add("NG", "Lock", self.p.lock_file + " exists. Another install may be running; delete it if not.")
        state = self.read_state()
        pl = self.plan(state, int(state.get("generation", 0)))
        for e in pl["entries"]:
            add("INFO", "Extension " + e["id"], "%s %s (order %d)" % (e["test"]["name"], e["test"]["version"], e["order"]))
        for s in pl["skipped"]:
            add("WARN", "Extension " + s["id"], "skipped: " + s["reason"])
        if not self.args.sandbox:
            running = 0
            for comm in glob.glob("/proc/[0-9]*/comm"):
                try:
                    with open(comm) as f:
                        if "claude" in f.read().lower():
                            running += 1
                except OSError:
                    pass
            add("INFO", "Claude process", "running (%d). Quit Claude completely and start it again afterwards." % running
                if running else "not running")
        return out

    @staticmethod
    def show(findings):
        tty = sys.stdout.isatty()
        for level, item, detail in findings:
            line = "[%-4s] %s: %s" % (level, item, detail)
            print(COLORS[level] + line + "\033[0m" if tty else line)
        print()
        return sum(1 for f in findings if f[0] == "NG")

    def confirm(self, message):
        if self.args.yes:
            return
        try:
            answer = input(message + " Continue? (y/N) ")
        except EOFError:
            answer = ""
        if not re.match(r"^[Yy]", answer):
            print("Cancelled. Nothing was changed.")
            raise Abort(2)

    # ------------------------------------------------------------ transaction
    def move(self, src, dst, undo=True):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.move(src, dst)
        if undo:
            self.undo.insert(0, ("move", dst, src))

    def rollback(self):
        ok = True
        for op in self.undo:
            try:
                if op[0] == "move":
                    if os.path.exists(op[1]):
                        os.makedirs(os.path.dirname(op[2]), exist_ok=True)
                        if os.path.exists(op[2]):
                            raise RuntimeError(op[2] + " already exists")
                        shutil.move(op[1], op[2])
                elif op[0] == "env":
                    self.set_env(op[1], record=False)
                elif op[0] == "bytes":
                    if op[2] is None:
                        if os.path.exists(op[1]):
                            os.remove(op[1])
                    else:
                        with open(op[1], "wb") as f:
                            f.write(op[2])
            except Exception as e:  # noqa: BLE001 - report every failed step
                ok = False
                print("rollback step failed: %s" % e)
        return ok

    def set_env(self, on, record=True, backup_dir=None):
        if on:
            os.makedirs(self.p.env_dir, exist_ok=True)
            with open(self.p.env_file, "w", encoding="utf-8", newline="\n") as f:
                f.write("# Written by claude-desktop-webext. Lets Claude Desktop load the extension slot.\nREACT_PROFILE=1\n")
            if record:
                self.undo.insert(0, ("env", False))
        elif os.path.exists(self.p.env_file):
            if backup_dir and record:
                self.move(self.p.env_file, os.path.join(backup_dir, "env", ENV_FILE_NAME))
            else:
                os.remove(self.p.env_file)

    def update_env(self, state, wanted, backup_dir):
        ours, foreign, _system = self.react_profile()
        if wanted:
            if ours is None and (foreign is None or self.args.adopt_env):
                self.set_env(True)
                state["envSetByUs"] = True
            elif ours is not None:
                state["envSetByUs"] = True
        elif state.get("envSetByUs"):
            if ours is not None:
                self.set_env(False, backup_dir=backup_dir)
                print("Removed " + self.p.env_file + " (moved to backups).")
            state["envSetByUs"] = False
        self.step("env")

    def update_slot(self, state, backup_dir):
        gen = int(state.get("generation", 0)) + 1
        pl = self.plan(state, gen)
        for s in pl["skipped"]:
            print("skipped %s: %s" % (s["id"], s["reason"]))
        had_slot = os.path.exists(self.p.slot)
        staging = None
        if pl["entries"]:
            staging = os.path.join(self.p.ext_dir, ".%s.staging-%s" % (SLOT_ID, new_stamp()))
            os.makedirs(staging)
            self.undo.insert(0, ("move", staging, os.path.join(backup_dir, "slot-failed")))
            for e in pl["entries"]:
                copy_verified(e["dir"], os.path.join(staging, "ext", e["id"]))
            write_json(os.path.join(staging, "manifest.json"), pl["manifest"])
            write_json(os.path.join(staging, SLOT_MARKER), pl["marker"])
        self.step("slot-stage")
        if had_slot:
            self.move(self.p.slot, os.path.join(backup_dir, "slot-previous"))
        self.step("slot-swap")
        if staging:
            os.makedirs(self.p.ext_dir, exist_ok=True)
            shutil.move(staging, self.p.slot)
            self.undo.insert(0, ("move", self.p.slot, os.path.join(backup_dir, "slot-failed-placed")))
        state["generation"] = gen
        return pl

    def transaction(self, label, body):
        os.makedirs(self.p.home_dir, exist_ok=True)
        try:
            fd = os.open(self.p.lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            raise Abort(1, "another operation holds " + self.p.lock_file)
        with os.fdopen(fd, "w") as f:
            f.write(format_json({"pid": os.getpid(), "createdAt": now()}))
        before = None
        if os.path.exists(self.p.state_file):
            with open(self.p.state_file, "rb") as f:
                before = f.read()
        self.undo.insert(0, ("bytes", self.p.state_file, before))
        try:
            body()
            self.step("state")
        except Exception as e:  # noqa: BLE001
            print("Failed: %s" % e)
            print("Restoring the previous state...")
            ok = self.rollback()
            os.remove(self.p.lock_file)
            if not ok:
                print("Manual check needed. Backups are in: " + self.p.backups)
                raise Abort(3)
            print("Restored. Nothing was changed.")
            raise Abort(1)
        os.remove(self.p.lock_file)
        print(label + " completed.")
        print("Quit Claude completely and start it again. If REACT_PROFILE was just added, log out and log in first. "
              "This script never closes Claude.")

    # ------------------------------------------------------------ actions
    def diagnose(self):
        req = self.resolve_request() if (self.args.config or self.args.id) else None
        ng = self.show(self.findings(req, "diagnose"))
        print("Result: %d problem(s) found (NG above)." % ng if ng else "Result: no problems found.")
        print("Diagnose is read-only; nothing was changed.")
        if ng:
            raise Abort(1)

    def install(self):
        req = self.resolve_request()
        if not req["id"] or not req["source"]:
            raise Abort(1, "install needs --config or --id and --source")
        if not os.path.isdir(req["source"]):
            raise Abort(1, "source folder not found: " + req["source"])
        check = self.test_extension(req["source"], req["id"])
        if not check["ok"]:
            raise Abort(1, "The extension cannot be loaded this way: " + check["reason"])
        ng = self.show(self.findings(req, "install"))
        if ng:
            raise Abort(1, "Stopped because of %d problem(s). Nothing was changed." % ng)
        target = os.path.join(self.p.store, req["id"])
        mode = "Update" if os.path.exists(target) else "Install"
        self.confirm("%s %s %s." % (mode, req["displayName"], check["version"]))

        def body():
            stamp = new_stamp()
            backup = os.path.join(self.p.backups, stamp)
            state = self.read_state()
            os.makedirs(self.p.store, exist_ok=True)
            staging = os.path.join(self.p.store, ".%s.staging-%s" % (req["id"], stamp))
            self.undo.insert(0, ("move", staging, os.path.join(backup, "store-failed-" + req["id"])))
            copy_verified(req["source"], staging)
            self.step("copy")
            if os.path.exists(target):
                self.move(target, os.path.join(backup, "store-previous-" + req["id"]))
            shutil.move(staging, target)
            self.undo.insert(0, ("move", target, os.path.join(backup, "store-failed-placed-" + req["id"])))
            old = state["extensions"].get(req["id"]) or {}
            order = req["order"] if req["order"] >= 0 else int(old.get("order", DEFAULT_ORDER))
            state["extensions"][req["id"]] = {
                "displayName": req["displayName"], "version": check["version"], "order": order,
                "installedAt": old.get("installedAt", now()), "updatedAt": now(),
            }
            pl = self.update_slot(state, backup)
            if req["id"] not in [e["id"] for e in pl["entries"]]:
                raise RuntimeError(req["id"] + " was not accepted into the slot")
            self.update_env(state, True, backup)
            self.save_state(state)
        self.transaction(mode, body)

    def uninstall(self):
        req = self.resolve_request()
        if not req["id"]:
            raise Abort(1, "uninstall needs --config or --id")
        target = os.path.join(self.p.store, req["id"])
        state = self.read_state()
        if not os.path.exists(target) and req["id"] not in state["extensions"]:
            print("%s is not installed. Nothing was changed." % req["displayName"])
            return
        if self.show(self.findings(req, "uninstall")):
            raise Abort(1, "Uninstall stopped because of the problems above. Nothing was changed.")
        if self.slot_owner(self.p.slot, None) not in ("ours", "none"):
            raise Abort(1, "The slot is used by another tool; it will not be changed. Nothing was changed.")
        self.confirm("Uninstall %s." % req["displayName"])

        def body():
            backup = os.path.join(self.p.backups, new_stamp())
            st = self.read_state()
            if os.path.exists(target):
                removed = os.path.join(backup, "store-removed-" + req["id"])
                self.move(target, removed)
                print("Moved the extension to %s (not deleted)." % removed)
            st["extensions"].pop(req["id"], None)
            pl = self.update_slot(st, backup)
            self.update_env(st, bool(pl["entries"]), backup)
            self.save_state(st)
        self.transaction("Uninstall", body)

    def rebuild(self):
        ng = self.show(self.findings(None, "rebuild"))
        if ng:
            raise Abort(1, "Stopped because of %d problem(s). Nothing was changed." % ng)
        self.confirm("Rebuild the Claude Desktop extension slot.")

        def body():
            backup = os.path.join(self.p.backups, new_stamp())
            st = self.read_state()
            pl = self.update_slot(st, backup)
            self.update_env(st, bool(pl["entries"]), backup)
            self.save_state(st)
        self.transaction("Rebuild", body)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="webext", description=__doc__.splitlines()[0])
    ap.add_argument("action", nargs="?", default="diagnose", choices=["diagnose", "install", "uninstall", "rebuild"])
    ap.add_argument("--config")
    ap.add_argument("--id")
    ap.add_argument("--source")
    ap.add_argument("--claude-path")
    ap.add_argument("--order", type=int, default=-1)
    ap.add_argument("--adopt-env", action="store_true")
    ap.add_argument("--take-over", action="store_true")
    ap.add_argument("--yes", "-y", action="store_true")
    ap.add_argument("--sandbox")
    ap.add_argument("--fail-at")
    args = ap.parse_args(argv)
    try:
        getattr(Loader(args), args.action)()
    except Abort as e:
        if e.message:
            print(e.message)
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main())
