"""Two officers' companions against a fake Discord webhook: they share one sync message and edit the same
Discord messages, an older save doesn't overwrite a newer one, and the installer sets a PC up from an invite.

    python3 tests/companion_sim.py
"""
import http.server, json, os, re, shutil, subprocess, sys, tempfile, threading, time, uuid

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "companion")
ok = True


def check(name, cond):
    global ok
    ok = ok and bool(cond)
    print(("PASS " if cond else "FAIL ") + name)


# --- a fake Discord webhook ---
messages, files, calls = {}, {}, []


class Discord(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def body(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        ctype = self.headers.get("Content-Type", "")
        if ctype.startswith("multipart/"):
            boundary = ctype.split("boundary=")[1].encode()
            payload, attachment = {}, None
            for part in raw.split(b"--" + boundary):
                if b"\r\n\r\n" not in part: continue
                head, data = part.split(b"\r\n\r\n", 1)
                data = data[:-2]
                if b'name="payload_json"' in head: payload = json.loads(data)
                elif b'name="files[0]"' in head:
                    name = re.search(rb'filename="([^"]+)"', head).group(1).decode()
                    attachment = (name, data)
            return payload, attachment
        return (json.loads(raw) if raw else {}), None

    def send(self, code, obj=None):
        data = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def message(self, mid):
        m = dict(messages[mid]); m["id"] = mid
        return m

    def handle_any(self, method):
        path = self.path.split("?")[0]
        calls.append((method, path))
        if path.startswith("/files/"):
            data = files[path[7:]]
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        m = re.match(r"^/api/webhooks/1/tok(?:/messages/(\d+))?$", path)
        if not m: return self.send(404, {"message": "Unknown Webhook"})
        mid = m.group(1)
        if mid and mid not in messages: return self.send(404, {"message": "Unknown Message"})
        if method == "GET": return self.send(200, self.message(mid))
        if method == "DELETE": del messages[mid]; return self.send(204)
        payload, attachment = self.body()
        msg = messages.get(mid, {}) if mid else {"attachments": []}
        msg.update({k: v for k, v in payload.items() if k in ("content", "embeds")})
        if attachment:
            key = uuid.uuid4().hex
            files[key] = attachment[1]
            msg["attachments"] = [{"id": key, "filename": attachment[0], "url": f"http://127.0.0.1:{PORT}/files/{key}"}]
        if not mid:
            mid = str(len(calls) * 1000 + len(messages) + 1)
        messages[mid] = msg
        self.send(200, self.message(mid))

    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")
    def do_DELETE(self): self.handle_any("DELETE")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Discord)
PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()
HOOK = f"http://127.0.0.1:{PORT}/api/webhooks/1/tok"


# --- two PCs, each with its own copy of the companion and of WoW's saved file ---
T = int(time.time()) - 3600


def saved(stamp, gold, status, updated, donation=False):
    stamp, updated = T + stamp, T + updated
    don = ('["donations"] = { ["d1"] = { ["by"] = "Dana Field", ["bank"] = "Vault Keeper", ["status"] = "received", '
           '["created"] = ' + str(T + 50) + ', ["items"] = { [2589] = 20 } } },') if donation else ""
    return f'''GuildBankToonsDB = {{
  ["items"] = {{ [2589] = {{ ["n"] = "Linen Cloth" }} }},
  ["guilds"] = {{ ["Verdant"] = {{
    ["managed"] = {{ ["vaultkeeper"] = "Vault Keeper" }},
    ["banks"] = {{ ["vaultkeeper"] = {{ ["owner"] = "Vault Keeper", ["stamp"] = {stamp}, ["hash"] = "h{stamp}", ["gold"] = {gold},
                   ["bags"] = {{ [2589] = 40 }} }} }},
    ["requests"] = {{ ["r1"] = {{ ["by"] = "Dana Field", ["bank"] = "Vault Keeper", ["item"] = 2589, ["count"] = 5,
                    ["status"] = "{status}", ["updated"] = {updated}, ["actor"] = "Olivia Stone" }} }},
    {don}
  }} }},
}}
'''


def pc(name):
    d = tempfile.mkdtemp(prefix=name)
    shutil.copy(os.path.join(ROOT, "guildbanktoons_discord.py"), d)
    return d


def run(d, *args, sv=None):
    env = {k: v for k, v in os.environ.items() if k != "GUILDBANKTOONS_WEBHOOK"}
    cmd = [sys.executable, os.path.join(d, "guildbanktoons_discord.py")] + list(args)
    if sv: cmd += ["--savedvars", sv]
    return subprocess.run(cmd, capture_output=True, text=True, cwd=d, env=env, timeout=120)


def write(d, text):
    p = os.path.join(d, "GuildBankToons.lua"); open(p, "w").write(text); return p


def config(d, **kw):
    json.dump(kw, open(os.path.join(d, "guildbanktoons.json"), "w"))


def visible():
    return {mid: m for mid, m in messages.items() if not any(a["filename"] == "un-ninja-bank-sync.json" for a in m["attachments"])}


def shared():
    sync = [m for m in messages.values() if m["attachments"]]
    return json.loads(files[sync[0]["attachments"][0]["id"]]) if sync else None


a, b = pc("pcA"), pc("pcB")
config(a, webhook=HOOK, no_summary=True)
sv_a = write(a, saved(100, 5000, "open", 100))
r = run(a, sv=sv_a)
check("first PC posts the bank and the request", r.returncode == 0 and len(visible()) == 2)
inv = run(a, "--invite")
code = re.search(r"UNB1:\S+", inv.stdout)
check("--invite posts a sync message and prints a code", inv.returncode == 0 and code and shared() is not None)
check("the sync message is saved in the first PC's settings", json.load(open(os.path.join(a, "guildbanktoons.json"))).get("sync_message"))
check("the sync message starts with what the first PC already posted", "r1" in (shared() or {}).get("requests", {}))

sys.path.insert(0, ROOT)
import guildbanktoons_discord as companion
settings = companion.read_invite(code.group(0))
check("the invite carries the webhook and the sync message but no paths", settings["webhook"] == HOOK and settings.get("sync_message")
      and "savedvars" not in settings and settings.get("no_summary"))
try:
    companion.read_invite(code.group(0)[:-6]); bad = False
except ValueError:
    bad = True
check("a cut-off invite code is refused", bad)

config(b, **settings)
sv_b = write(b, saved(200, 9000, "approved", 200))
before = set(visible())
r = run(b, sv=sv_b)
check("second PC edits the same bank and request messages (plus the approval ping)",
      r.returncode == 0 and before <= set(visible()) and len(visible()) == 3, )
bank_msg = shared()[ "Verdant|vaultkeeper"]["message"]
check("bank message shows the newer gold", "0g 90s" in json.dumps(messages[bank_msg]) or "0g 90s 0c" in json.dumps(messages[bank_msg]))
check("request message shows the approval", "Approved by Olivia Stone" in messages[shared()["requests"]["r1"]["message"]]["content"])

# PC A still has the older save; it reloads (same file, a run happens) and must not undo B's work.
r = run(a, sv=write(a, saved(150, 7000, "open", 150)))
check("an older save doesn't overwrite the bank message", "0g 90s" in json.dumps(messages[bank_msg]))
check("an older save doesn't move a request back", "Approved" in messages[shared()["requests"]["r1"]["message"]]["content"] and len(visible()) == 3)

# A catches up: the request is mailed and a donation arrived. One new thank-you, no duplicates anywhere.
run(a, sv=write(a, saved(300, 12000, "mailed", 300)))
run(b, sv=write(b, saved(300, 12000, "mailed", 300, donation=True)))
run(a, sv=write(a, saved(300, 12000, "mailed", 300, donation=True)))
check("the mailed status edits the shared request message", "~~" in messages[shared()["requests"]["r1"]["message"]]["content"])
thanks = [m for m in visible().values() if "donated" in (m.get("content") or "")]
check("a donation is thanked once even though both PCs saw it", len(thanks) == 1)
check("still one bank message across both PCs", sum(1 for m in visible().values() if m.get("embeds")) == 1)

# Both posted the same new message at the same moment: the merge keeps one.
remote = {"requests": {"r9": {"message": "111", "status": "open", "updated": 5}}}
ours = {"requests": {"r9": {"message": "222", "status": "open", "updated": 5}}}
merged, dupes = companion.merge_state(remote, ours, {("requests", "r9"): (True, HOOK, None)})
check("a message two PCs posted at once keeps the first and deletes the other", merged["requests"]["r9"]["message"] == "111" and dupes == [(HOOK, "222")])
merged, dupes = companion.merge_state({"requests": {"r9": {"message": "111"}}}, {"requests": {"r9": {"message": "333"}}},
                                      {("requests", "r9"): (True, HOOK, "111")})
check("a message reposted because it was deleted replaces the old ID", merged["requests"]["r9"]["message"] == "333" and not dupes)

# The sync message was deleted: the PC carries on alone and says so.
sync_id = settings["sync_message"]
del messages[sync_id]
r = run(b, sv=write(b, saved(400, 12000, "mailed", 300, donation=True)))
check("a deleted sync message is reported, not a crash", r.returncode == 0 and "sync message is gone" in r.stderr)

# --- the installer, in a pretend home folder, from an invite code ---
home = tempfile.mkdtemp(prefix="home")
wow = os.path.join(home, "World of Warcraft")
acct = os.path.join(wow, "_forever_", "WTF", "Account", "OFFICER", "SavedVariables")
os.makedirs(acct); open(os.path.join(acct, "GuildBankToons.lua"), "w").write(saved(500, 1, "open", 500))
script = f"""
import sys, builtins
sys.path.insert(0, {ROOT!r})
sys.argv = ["install.py"]
import install
install.TARGET = {os.path.join(home, "UnNinjaBank")!r}
install.CONFIG = install.TARGET + "/guildbanktoons.json"; install.PID = install.TARGET + "/.pid"
install.STARTUP = {os.path.join(home, "startup", "x")!r}
install.wow_folders = lambda: [{wow!r}]
install.start_at_login = lambda: "Pretend autostart."
install.install()
"""
r = subprocess.run([sys.executable, "-c", script], input=code.group(0) + "\n", capture_output=True, text=True, timeout=60)
cfg = os.path.join(home, "UnNinjaBank", "guildbanktoons.json")
installed = json.load(open(cfg)) if os.path.exists(cfg) else {}
check("installer sets up a PC from an invite and finds the saved file", r.returncode == 0 and installed.get("webhook") == HOOK
      and installed.get("savedvars", "").endswith("GuildBankToons.lua") and os.path.exists(os.path.join(home, "UnNinjaBank", "guildbanktoons_discord.py")))
r2 = subprocess.run([sys.executable, "-c", script], input="\n\n", capture_output=True, text=True, timeout=60)
check("running the installer again updates it and keeps the settings", r2.returncode == 0 and json.load(open(cfg)) == installed)
if r.returncode or r2.returncode: print(r.stdout[-1500:], r.stderr[-1500:], r2.stdout[-800:], r2.stderr[-800:])

server.shutdown()
sys.exit(0 if ok else 1)
