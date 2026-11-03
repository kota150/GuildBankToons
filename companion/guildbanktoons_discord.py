#!/usr/bin/env python3
"""Forever - Guild Bank Toons Discord companion.

Reads the addon's SavedVariables (GuildBankToons.lua) file (written when you log out or /reload) and keeps one Discord
message per guild bank character up to date through a webhook. Any guildmate running the addon has a
copy of the bank, so anyone can run this, not just whoever plays the bank character.

Python 3.8+, standard library only.

    python3 guildbanktoons_discord.py --dry-run            # print what would be posted
    python3 guildbanktoons_discord.py                      # post or update once
    python3 guildbanktoons_discord.py --watch              # keep running, update after every logout/reload

Settings come from guildbanktoons.json next to this script (see guildbanktoons.example.json), overridden by
command-line flags. The webhook URL can also come from the GUILDBANKTOONS_WEBHOOK environment variable.
"""

import argparse
import datetime
import glob
import json
import os
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "guildbanktoons.json")
STATE_PATH = os.path.join(HERE, ".guildbanktoons_state.json")
USER_AGENT = "GuildBankToons-Companion (https://github.com/kota150, 1.0)"
DEFAULT_WOW_DIRS = [
    "/Applications/World of Warcraft",
    "C:/Program Files (x86)/World of Warcraft",
    "C:/Program Files/World of Warcraft",
]
FLAVORS = ["_forever_", "_classic_era_"]

# Discord limits: 4096 characters per embed description, 6000 across all embeds in a message.
DESCRIPTION_LIMIT = 4000
MESSAGE_LIMIT = 5800


# --- SavedVariables (Lua) parser ------------------------------------------------------------------

class LuaParser:
    """Parses the subset of Lua that WoW writes to SavedVariables: `Name = value` assignments of
    tables, strings, numbers, booleans and nil."""

    def __init__(self, text):
        self.s = text
        self.i = 0

    def error(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise ValueError(f"SavedVariables parse error on line {line}: {msg}")

    def skip(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                end = s.find("\n", self.i)
                self.i = n if end < 0 else end + 1
            else:
                break

    def peek(self):
        self.skip()
        return self.s[self.i] if self.i < len(self.s) else ""

    def expect(self, ch):
        if self.peek() != ch:
            self.error(f"expected {ch!r}")
        self.i += 1

    def name(self):
        self.skip()
        start = self.i
        while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] == "_"):
            self.i += 1
        if start == self.i:
            self.error("expected a name")
        return self.s[start:self.i]

    def string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}
        while True:
            if self.i >= len(self.s):
                self.error("unterminated string")
            c = self.s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                nxt = self.s[self.i + 1]
                if nxt.isdigit():
                    j = self.i + 1
                    while j < self.i + 4 and j < len(self.s) and self.s[j].isdigit():
                        j += 1
                    out.append(chr(int(self.s[self.i + 1:j])))
                    self.i = j
                    continue
                out.append(escapes.get(nxt, nxt))
                self.i += 2
                continue
            out.append(c)
            self.i += 1

    def number(self):
        start = self.i
        if self.s[self.i] == "-":
            self.i += 1
        while self.i < len(self.s) and (self.s[self.i].isalnum() or self.s[self.i] in ".+-"):
            if self.s[self.i] in "+-" and self.s[self.i - 1] not in "eE":
                break
            self.i += 1
        raw = self.s[start:self.i]
        try:
            return int(raw, 0)
        except ValueError:
            return float(raw)

    def value(self):
        c = self.peek()
        if c == "{":
            return self.table()
        if c in "\"'":
            return self.string()
        if c.isdigit() or c in "-.":
            return self.number()
        word = self.name()
        if word == "true":
            return True
        if word == "false":
            return False
        if word == "nil":
            return None
        self.error(f"unexpected {word!r}")

    def table(self):
        self.expect("{")
        result, index = {}, 1
        while self.peek() != "}":
            if self.peek() == "[":
                self.i += 1
                k = self.value()
                self.expect("]")
                self.expect("=")
                result[k] = self.value()
            else:
                save = self.i
                c = self.peek()
                if c.isalpha() or c == "_":
                    word = self.name()
                    if self.peek() == "=":
                        self.i += 1
                        result[word] = self.value()
                    else:
                        self.i = save
                        result[index] = self.value()
                        index += 1
                else:
                    result[index] = self.value()
                    index += 1
            if self.peek() in ",;":
                self.i += 1
        self.expect("}")
        return result

    def document(self):
        out = {}
        while self.peek():
            name = self.name()
            self.expect("=")
            out[name] = self.value()
        return out


def load_saved_variables(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return LuaParser(f.read()).document()


# --- Building the Discord messages ----------------------------------------------------------------

def find_saved_variables(wow_dir, account=None):
    dirs = [wow_dir] if wow_dir else DEFAULT_WOW_DIRS
    found = []
    for base in dirs:
        for flavor in FLAVORS:
            pattern = os.path.join(base, flavor, "WTF", "Account", account or "*", "SavedVariables", "GuildBankToons.lua")
            found.extend(glob.glob(pattern))
    # Most recently written first: that's the copy from the latest logout.
    return sorted(found, key=os.path.getmtime, reverse=True)


def money(copper):
    copper = int(copper or 0)
    g, s, c = copper // 10000, (copper // 100) % 100, copper % 100
    return f"{g:,}g {s}s {c}c"


def designated(guild):
    """Bank characters the guild has designated: tagged in guild info, or followed with /gbt add."""
    ids = {}
    for source in ("tagged", "extra"):
        for bank_id, name in (guild.get(source) or {}).items():
            ids.setdefault(bank_id, name)
    return ids


def item_lines(items, names, link_base):
    rows = []
    for item_id, count in (items or {}).items():
        info = names.get(item_id) or names.get(str(item_id)) or {}
        name = info.get("n") or f"Item #{item_id}"
        label = f"[{name}]({link_base}{item_id})" if link_base else name
        rows.append((name.lower(), f"{label} ×{count}"))
    rows.sort()
    return [text for _, text in rows]


def fit(lines, limit):
    """Joins lines up to `limit` characters, noting how many were left out."""
    out, used = [], 0
    for i, line in enumerate(lines):
        if used + len(line) + 1 > limit - 40:
            out.append(f"…and {len(lines) - i} more (open /gbt in game)")
            break
        out.append(line)
        used += len(line) + 1
    return "\n".join(out) or "Empty."


def build_message(guild_name, snap, names, link_base):
    owner = snap.get("owner", "?")
    stamp = int(snap.get("stamp") or 0)
    bank_stamp = int(snap.get("bankStamp") or 0)
    footer = "Guild Bank Toons snapshot" + (f" via {snap['via']}" if snap.get("via") else " from the bank character")
    summary = {
        "title": f"🏦 {owner.split('-')[0]}",
        "description": f"**Gold:** {money(snap.get('gold'))}\n**Guild:** {guild_name}"
                       + ("" if bank_stamp else "\n_Bank not opened yet on this character._"),
        "color": 0xD8AA55,
        "footer": {"text": footer},
    }
    if stamp:
        summary["timestamp"] = datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat()
    embeds = [summary]
    budget = MESSAGE_LIMIT - len(summary["title"]) - len(summary["description"]) - len(footer)
    sections = [(title, item_lines(snap.get(field), names, link_base)) for title, field in (("Bags", "bags"), ("Bank", "bank"))]
    sections = [(title, lines) for title, lines in sections if lines]
    for n, (title, lines) in enumerate(sections):
        # Split what's left evenly; a short first section leaves more room for the next.
        limit = min(DESCRIPTION_LIMIT, max(200, budget // (len(sections) - n)))
        text = fit(lines, limit)
        budget -= len(text) + len(title) + 10
        embeds.append({"title": f"{title} ({len(lines)})", "description": text, "color": 0x4A6B3A})
    return {"username": "Guild Bank", "embeds": embeds, "allowed_mentions": {"parse": []}}


# --- Discord webhook -------------------------------------------------------------------------------

def request(method, url, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def publish(webhook, message_id, payload):
    """Edits the existing message, or posts a new one if there isn't one (or it was deleted)."""
    base = webhook.split("?")[0].rstrip("/")
    if message_id:
        try:
            request("PATCH", f"{base}/messages/{message_id}", payload)
            return message_id
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    return request("POST", f"{base}?wait=true", payload)["id"]


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def run_once(args, state):
    path = args.savedvars or (find_saved_variables(args.wow_dir, args.account) or [None])[0]
    if not path or not os.path.exists(path):
        sys.exit("Couldn't find GuildBankToons.lua in SavedVariables. Pass --savedvars or --wow-dir.")
    data = load_saved_variables(path).get("GuildBankToonsDB") or {}
    names = data.get("items") or {}
    changed = 0
    for guild_name, guild in (data.get("guilds") or {}).items():
        if args.guild and args.guild.lower() not in guild_name.lower():
            continue
        banks = guild.get("banks") or {}
        for bank_id in designated(guild):
            snap = banks.get(bank_id)
            if not snap:
                continue
            slot = f"{guild_name}|{bank_id}"
            seen = state.setdefault(slot, {})
            if not args.force and seen.get("stamp") == snap.get("stamp") and seen.get("hash") == snap.get("hash"):
                continue
            payload = build_message(guild_name, snap, names, args.link_base)
            if args.dry_run:
                print(json.dumps(payload, indent=2, ensure_ascii=False))
                continue
            seen["message"] = publish(args.webhook, seen.get("message"), payload)
            seen["stamp"], seen["hash"] = snap.get("stamp"), snap.get("hash")
            changed += 1
            print(f"Updated Discord for {snap.get('owner')} ({guild_name}).")
            time.sleep(1)  # stay well inside the webhook rate limit
    if not args.dry_run:
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
    return path, changed


def main():
    config = load_json(CONFIG_PATH, {})
    p = argparse.ArgumentParser(description="Post Forever - Guild Bank Toons bank contents to Discord.")
    p.add_argument("--webhook", default=os.environ.get("GUILDBANKTOONS_WEBHOOK") or config.get("webhook"))
    p.add_argument("--savedvars", default=config.get("savedvars"), help="path to SavedVariables/GuildBankToons.lua")
    p.add_argument("--wow-dir", default=config.get("wow_dir"), help="World of Warcraft install folder")
    p.add_argument("--account", default=config.get("account"), help="WTF account folder name")
    p.add_argument("--guild", default=config.get("guild"), help="only post guilds whose name contains this")
    p.add_argument("--link-base", default=config.get("link_base", ""),
                   help="item link prefix, e.g. https://www.wowhead.com/classic/item= (blank: plain names)")
    p.add_argument("--watch", action="store_true", help="keep running and update after every save")
    p.add_argument("--interval", type=int, default=config.get("interval", 15), help="seconds between checks")
    p.add_argument("--dry-run", action="store_true", help="print the messages instead of posting")
    p.add_argument("--force", action="store_true", help="post even if nothing changed")
    args = p.parse_args()
    if not args.webhook and not args.dry_run:
        sys.exit("No webhook URL. Set it in guildbanktoons.json, GUILDBANKTOONS_WEBHOOK, or --webhook.")

    state = load_json(STATE_PATH, {})
    path, _ = run_once(args, state)
    if not args.watch:
        return
    print(f"Watching {path} (Ctrl-C to stop).")
    last = os.path.getmtime(path)
    while True:
        time.sleep(args.interval)
        try:
            mtime = os.path.getmtime(path)
            if mtime != last:
                time.sleep(2)  # let WoW finish writing the file
                last = mtime
                run_once(args, state)
        except (OSError, ValueError, urllib.error.URLError) as e:
            print(f"Skipped an update: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
