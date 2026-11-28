#!/usr/bin/env python3
"""Un-Ninja Bank (formerly Forever - Guild Bank Toons) Discord companion.

Reads the addon's SavedVariables (GuildBankToons.lua) file (written when you log out or /reload) and keeps one Discord
message per guild bank character up to date through a webhook. New item requests get their own message
(optionally pinging an officer role), updated when approved, mailed or denied, and approvals post a
separate message that can ping whoever mails for the bank. Any guildmate running the addon has a
copy of the bank, so anyone can run this, not just whoever plays the bank character. Several officers can
run it at once: with a sync message (`--invite` sets one up), every copy edits the same Discord messages
instead of posting its own. install.py sets it up on another officer's PC from the invite code.

It also thanks each donor once the bank toon receives their donation, keeps a Goals message up to date
(gold with a two-week trend, each gold goal, the items the guild needs, and this week's top donors), and
can write the bank, the ledger and the gold history to CSV files.

Python 3.8+, standard library only.

    python3 guildbanktoons_discord.py --dry-run            # print what would be posted
    python3 guildbanktoons_discord.py                      # post or update once
    python3 guildbanktoons_discord.py --watch              # keep running, update after every logout/reload
    python3 guildbanktoons_discord.py --export exports     # write inventory.csv, ledger.csv and gold.csv
    python3 guildbanktoons_discord.py --invite             # an invite code for install.py on another officer's PC

Settings come from guildbanktoons.json next to this script (see guildbanktoons.example.json), overridden by
command-line flags. The webhook URL can also come from the GUILDBANKTOONS_WEBHOOK environment variable.
"""

import argparse
import base64
import csv
import datetime
import glob
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

VERSION = "1.0.8"
# Settings and state sit next to the script, or next to the .exe when it's built for Windows.
HERE = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, "frozen", False) else __file__))
CONFIG_PATH = os.path.join(HERE, "guildbanktoons.json")
STATE_PATH = os.path.join(HERE, ".guildbanktoons_state.json")
PID_PATH = os.path.join(HERE, ".guildbanktoons.pid")
SYNC_FILE = "un-ninja-bank-sync.json"
SYNC_TEXT = ("🔄 Un-Ninja Bank companion sync. Please leave this message here: the companions on officers' PCs keep "
             "track of the bank's Discord messages in it, so they all edit the same ones.")
INVITE_PREFIX = "UNB1:"
# What an invite code carries: the Discord side only. Each PC finds its own WoW folder.
INVITE_KEYS = ["webhook", "requests_webhook", "donations_webhook", "summary_webhook", "sync_webhook", "sync_message",
               "guild", "link_base", "ping_role", "approval_ping", "no_requests", "no_donations", "no_summary"]
USER_AGENT = f"GuildBankToons-Companion (https://github.com/kota150, {VERSION})"
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


def vault_public(guild, tab):
    """Whether guild bank tab `tab` is shared: the rank officers chose (Rules: vaultRank; the lowest reported rank
    by default), or a lower one, reported seeing it. The addon only saves shared tabs; this is a second check
    before anything goes to Discord or a file."""
    views = {int(r): v for r, v in (guild.get("vaultView") or {}).items()}
    if not views:
        return False
    rank = int(((guild.get("plan") or {}).get("rules") or {}).get("vaultRank", -1))
    if rank < 0 or rank > max(views):
        rank = max(views)
    return any(r >= rank and ((v.get("tabs") or {}).get(tab)) for r, v in views.items())


def bank_title(guild, name):
    """A bank's name as the guild shows it: the display name officers gave it, else the toon's or tab's name."""
    return ((guild.get("plan") or {}).get("labels") or {}).get(name_id(name)) or short(name)


def designated(guild):
    """Bank characters the guild has designated (set by the guild master, tagged in guild info, or followed with
    /gbt add), then the guild bank's public tabs, which the addon saves as *vault<tab>."""
    ids = {}
    for source in ("managed", "tagged", "extra"):
        for bank_id, name in (guild.get(source) or {}).items():
            ids.setdefault(bank_id, name)
    vault = sorted((k for k in (guild.get("banks") or {}) if str(k).startswith("*vault")), key=lambda k: int(re.sub(r"\D", "", k) or 0))
    for bank_id in vault:
        if vault_public(guild, int(re.sub(r"\D", "", bank_id))):
            ids.setdefault(bank_id, guild["banks"][bank_id].get("owner") or bank_id)
    return ids


def item_lines(items, names, link_base, reserved=None):
    rows = []
    for item_id, count in (items or {}).items():
        info = names.get(item_id) or names.get(str(item_id)) or {}
        name = info.get("n") or f"Item #{item_id}"
        label = f"[{name}]({link_base}{item_id})" if link_base else name
        held = (reserved or {}).get(item_id, 0)
        rows.append((name.lower(), f"{label} ×{count}" + (f" ({held} reserved)" if held else "")))
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


def build_message(guild_name, snap, names, link_base, reserved=None, title=None):
    owner = snap.get("owner", "?")
    stamp = int(snap.get("stamp") or 0)
    bank_stamp = int(snap.get("bankStamp") or 0)
    footer = "Un-Ninja Bank snapshot" + (f" via {snap['via']}" if snap.get("via") else " from the bank character")
    summary = {
        "title": f"🏦 {title or short(owner)}" + (f" ({short(owner)})" if title and title != short(owner) else ""),
        "description": f"**Gold:** {money(snap.get('gold'))}\n**Guild:** {guild_name}"
                       + ("" if bank_stamp else "\n_Bank not opened yet on this character._"),
        "color": 0xD8AA55,
        "footer": {"text": footer},
    }
    if stamp:
        summary["timestamp"] = datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat()
    embeds = [summary]
    budget = MESSAGE_LIMIT - len(summary["title"]) - len(summary["description"]) - len(footer)
    sections = [(title, item_lines(snap.get(field), names, link_base, reserved)) for title, field in (("Bags", "bags"), ("Bank", "bank"))]
    sections = [(title, lines) for title, lines in sections if lines]
    for n, (title, lines) in enumerate(sections):
        # Split what's left evenly; a short first section leaves more room for the next.
        limit = min(DESCRIPTION_LIMIT, max(200, budget // (len(sections) - n)))
        text = fit(lines, limit)
        budget -= len(text) + len(title) + 10
        embeds.append({"title": f"{title} ({len(lines)})", "description": text, "color": 0x4A6B3A})
    return {"username": "Guild Bank", "embeds": embeds, "allowed_mentions": {"parse": []}}


STATUS_TEXT = {"approved": "✅ Approved", "denied": "❌ Denied", "mailed": "📬 Mailed", "cancelled": "🚫 Cancelled"}
FINAL = {"denied", "mailed", "cancelled"}
STAGE = {"open": 0, "approved": 1, "mailed": 2, "denied": 2, "cancelled": 2}


def short(name):
    """A character's name for display. WoW: Forever names are first name and surname ("Vault Keeper", sometimes
    written "Vault-Keeper"); the addon saves them without realms, but a realm the game adds always has digits.
    Guild bank tabs are saved as *vault<tab>:<tab name>."""
    vault = re.match(r"^\*vault(\d+)(?::(.*))?$", name or "")
    if vault:
        return f"Guild Bank - {vault.group(2) or 'Tab ' + vault.group(1)}"
    name = re.sub(r"-[^-]*\d.*$", "", name or "?")
    return name.replace("-", " ").strip() or "?"


def name_id(name):
    """Same identity the addon uses: first name and surname, ignoring case, spaces and dashes (*vault<tab> for tabs)."""
    vault = re.match(r"^(\*vault\d+)", name or "")
    if vault:
        return vault.group(1)
    return re.sub(r"[\s-]", "", short(name)).lower()


def mentions(text):
    """allowed_mentions for the <@user> and <@&role> mentions in text, so only those ping."""
    users = re.findall(r"<@!?(\d+)>", text or "")
    roles = re.findall(r"<@&(\d+)>", text or "")
    return {"parse": [], "users": users, "roles": roles}


def item_name(names, item_id):
    info = names.get(item_id) or names.get(str(item_id)) or {}
    return info.get("n") or f"Item #{item_id}"


def request_what(req, names, link_base):
    """'**20×** [Linen Cloth]' for items; requests for gold use item 0 with the count in whole gold; requests for
    several items keep them in `items`."""
    item_id = req.get("item")
    if not item_id:
        return f"**{req.get('count')}g**"
    if req.get("items"):
        parts = []
        for iid, count in sorted(req["items"].items(), key=lambda kv: -int(kv[1])):
            name = item_name(names, iid)
            parts.append(f"**{count}×** " + (f"[{name}]({link_base}{iid})" if link_base else f"**{name}**"))
        return ", ".join(parts)
    name = item_name(names, item_id)
    item = f"[{name}]({link_base}{item_id})" if link_base else f"**{name}**"
    return f"**{req.get('count')}×** {item}"


def request_line(req, names, link_base):
    line = f"📦 **{short(req.get('by'))}** requests {request_what(req, names, link_base)} from **{short(req.get('bank'))}**"
    if req.get("to"):
        line += f" for a craft order (mailed to **{short(req['to'])}**)"
    if req.get("note"):
        line += f' ("{req["note"]}")'
    return line


def build_request_message(req, names, link_base, ping_role):
    """One Discord message per request: pings the officer role while waiting for approval, shows the
    approval while it waits to be mailed, and is struck through once mailed, denied or cancelled."""
    line = request_line(req, names, link_base)
    status = req.get("status")
    if status == "open":
        mention = f"<@&{ping_role}> " if ping_role else ""
        return {"username": "Guild Bank", "content": mention + line, "allowed_mentions": mentions(mention)}
    actor = short(req.get("actor"))
    if status == "approved":
        text = f"{line}\n✅ Approved by {actor}, waiting for {short(req.get('bank'))} to mail it"
        return {"username": "Guild Bank", "content": text, "allowed_mentions": {"parse": []}}
    closed = f"{STATUS_TEXT.get(status, status)} by {actor}"
    if status == "mailed" and req.get("approvedBy"):
        closed += f" (approved by {short(req['approvedBy'])})"
    return {"username": "Guild Bank", "content": f"~~{line}~~\n{closed}", "allowed_mentions": {"parse": []}}


def build_approval_ping(req, names, link_base, approval_ping):
    """A separate message when a request is approved: edits don't notify anyone, new messages do."""
    if not req.get("item"):
        what = f"{req.get('count')}g"
    elif req.get("items"):
        what = ", ".join(f"{c}× {item_name(names, i)}" for i, c in req["items"].items())
    else:
        what = f"{req.get('count')}× {item_name(names, req.get('item'))}"
    who = "an officer (from the guild bank)" if str(req.get("bank", "")).startswith("*vault") else f"**{short(req.get('bank'))}**"
    text = (f"{approval_ping + ' ' if approval_ping else ''}✅ Approved by {short(req.get('actor'))}: "
            f"{who}, please mail **{what}** to **{short(req.get('to') or req.get('by'))}**.")
    return {"username": "Guild Bank", "content": text, "allowed_mentions": mentions(approval_ping)}


def reserved_by_bank(guild):
    """bank id -> {item id: count} approved but not yet mailed."""
    out = {}
    for req in (guild.get("requests") or {}).values():
        if req.get("status") == "approved" and req.get("item"):
            items = out.setdefault(name_id(req.get("bank")), {})
            for item_id, count in (req.get("items") or {req.get("item"): req.get("count")}).items():
                items[item_id] = items.get(item_id, 0) + int(count or 0)
    return out


def donation_items(entry, names, limit=None):
    """'20× Linen Cloth, 3× Silk Cloth, 2g 0s 0c', biggest stacks first."""
    items = sorted((entry.get("items") or {}).items(), key=lambda kv: (-int(kv[1]), int(kv[0])))
    parts = [f"{count}× {item_name(names, item_id)}" for item_id, count in items]
    if limit and len(parts) > limit:
        parts = parts[:limit] + [f"{len(parts) - limit} more"]
    if int(entry.get("money") or 0) > 0:
        parts.append(money(entry["money"]))
    return ", ".join(parts) or "nothing"


def build_donation_message(donation, names):
    text = (f"🎁 **{short(donation.get('by'))}** donated {donation_items(donation, names, 6)} to "
            f"**{short(donation.get('bank'))}**. Thank you!")
    if donation.get("note"):
        text += f' ("{donation["note"]}")'
    return {"username": "Guild Bank", "content": text, "allowed_mentions": {"parse": []}}


def gold_at(history, stamp):
    """The last gold seen at or before stamp in one bank toon's {1: {1: stamp, 2: copper}, ...} history."""
    best = None
    for entry in sorted((history or {}).values(), key=lambda e: e.get(1, 0)):
        if entry.get(1, 0) <= stamp:
            best = entry.get(2)
    return best


def gold_series(guild, days, now=None):
    """End-of-day total gold across the designated bank toons for the last `days` days (None if unknown)."""
    now = now or time.time()
    end = datetime.datetime.fromtimestamp(now).replace(hour=23, minute=59, second=59).timestamp()
    histories = [(guild.get("gold") or {}).get(bank_id) for bank_id in designated(guild)]
    out = []
    for d in range(days - 1, -1, -1):
        at = min(now, end - d * 86400)
        values = [v for v in (gold_at(h, at) for h in histories) if v is not None]
        out.append(sum(values) if values else None)
    return out


def sparkline(values):
    known = [v for v in values if v is not None]
    if not known:
        return ""
    low, high = min(known), max(known)
    bars = "▁▂▃▄▅▆▇█"
    return "".join(" " if v is None else bars[0 if high == low else int((v - low) / (high - low) * 7)] for v in values)


def progress_bar(fraction, width=12):
    filled = max(0, min(width, round(fraction * width)))
    return "▰" * filled + "▱" * (width - filled)


def current_gold(guild, toon="*"):
    banks = guild.get("banks") or {}
    return sum(int((banks.get(b) or {}).get("gold") or 0) for b in designated(guild) if toon in ("*", b))


def stock(guild):
    """item id -> count available across the designated bank toons, after approved requests."""
    reserved, banks, out = reserved_by_bank(guild), guild.get("banks") or {}, {}
    for bank_id in designated(guild):
        snap = banks.get(bank_id) or {}
        held = {}
        for field in ("bags", "bank"):
            for item_id, count in (snap.get(field) or {}).items():
                held[item_id] = held.get(item_id, 0) + int(count)
        for item_id, count in held.items():
            out[item_id] = out.get(item_id, 0) + max(0, count - reserved.get(bank_id, {}).get(item_id, 0))
    return out


def top_donors(guild, days=7, now=None):
    now = now or time.time()
    totals = {}
    for d in (guild.get("donations") or {}).values():
        # Donations: by mail, or straight into the guild bank.
        if d.get("status") in ("received", "sent", "deposit") and now - int(d.get("created") or 0) <= days * 86400:
            t = totals.setdefault(short(d.get("by")), [0, 0, 0])
            t[0] += 1
            t[1] += sum(int(c) for c in (d.get("items") or {}).values())
            t[2] += int(d.get("money") or 0)
    return sorted(totals.items(), key=lambda kv: (-kv[1][1], -kv[1][2], kv[0]))


def build_summary_message(guild_name, guild, names):
    """The Goals message: gold and its trend, gold goals, what the guild needs, and this week's donors."""
    plan = guild.get("plan") or {}
    series = gold_series(guild, 14)
    gold = current_gold(guild)
    week_ago = series[-8] if len(series) >= 8 else None
    lines = [f"**Gold:** {money(gold)}"]
    if week_ago is not None:
        change = gold - week_ago
        lines.append(f"**Last 7 days:** {'+' if change >= 0 else '-'}{money(abs(change))}")
    spark = sparkline(series)
    if spark.strip():
        lines.append(f"`{spark}` last 14 days")
    embeds = [{"title": f"🏦 {guild_name}: guild bank goals", "description": "\n".join(lines), "color": 0xD8AA55}]
    goals = sorted((plan.get("goals") or {}).values(), key=lambda g: int(g.get("target") or 0))
    if goals:
        rows = []
        banks = guild.get("banks") or {}
        for goal in goals:
            target = int(goal.get("target") or 0)
            toon = goal.get("toon") or "*"
            have = current_gold(guild, toon)
            who = "" if toon == "*" else f" ({short((banks.get(toon) or {}).get('owner') or toon)})"
            frac = have / target if target else 1
            rows.append(f"**{goal.get('name') or 'Goal'}**{who}\n{progress_bar(frac)} {money(have).split(' ')[0]} / "
                        f"{money(target).split(' ')[0]} ({round(frac * 100)}%)")
        embeds.append({"title": "Gold goals", "description": fit(rows, DESCRIPTION_LIMIT // 2), "color": 0x40A040})
    wants = plan.get("wants") or {}
    if wants:
        have = stock(guild)
        rows = []
        for item_id, target in wants.items():
            n = have.get(item_id, have.get(str(item_id), 0))
            rows.append((n / int(target) if int(target) else 1, f"{progress_bar(n / int(target) if int(target) else 1, 8)} "
                         f"**{item_name(names, item_id)}** {n} / {target}" + (f" (need {int(target) - n})" if n < int(target) else " ✅")))
        rows.sort(key=lambda r: r[0])
        embeds.append({"title": "What the guild needs", "description": fit([r[1] for r in rows], 1500), "color": 0xFF8040})
    donors = top_donors(guild)
    if donors:
        rows = [f"**{name}**: {n} donation{'s' if n != 1 else ''}, {items} items" + (f", {money(copper)}" if copper else "")
                for name, (n, items, copper) in donors[:10]]
        embeds.append({"title": "Top donors this week", "description": "\n".join(rows), "color": 0x8A6AD8})
    return {"username": "Guild Bank", "embeds": embeds, "allowed_mentions": {"parse": []}}


# --- CSV export -----------------------------------------------------------------------------------

def day(stamp):
    return datetime.datetime.fromtimestamp(int(stamp or 0)).strftime("%Y-%m-%d")


def export_csv(data, folder, guild_filter=None):
    """Writes inventory.csv, ledger.csv and gold.csv (one set per guild, the guild's name in front when there are several)."""
    os.makedirs(folder, exist_ok=True)
    names = data.get("items") or {}
    guilds = [(n, g) for n, g in (data.get("guilds") or {}).items() if not guild_filter or guild_filter.lower() in n.lower()]
    written = []
    for guild_name, guild in guilds:
        prefix = "" if len(guilds) == 1 else re.sub(r"[^A-Za-z0-9]+", "_", guild_name) + "_"
        banks, bank_ids = guild.get("banks") or {}, list(designated(guild))
        toon_names = [bank_title(guild, (banks.get(b) or {}).get("owner") or designated(guild)[b]) for b in bank_ids]
        reserved, wants = reserved_by_bank(guild), (guild.get("plan") or {}).get("wants") or {}
        rows = {}
        for col, bank_id in enumerate(bank_ids):
            snap = banks.get(bank_id) or {}
            for field in ("bags", "bank"):
                for item_id, count in (snap.get(field) or {}).items():
                    row = rows.setdefault(item_id, {"held": [0] * len(bank_ids), "reserved": 0})
                    row["held"][col] += int(count)
            for item_id, count in reserved.get(bank_id, {}).items():
                if item_id in rows:
                    rows[item_id]["reserved"] += count
        path = os.path.join(folder, prefix + "inventory.csv")
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["Item ID", "Item", "Quality", "Available", "Reserved", "Total", *toon_names, "Guild wants"])
            for item_id, row in sorted(rows.items(), key=lambda kv: item_name(names, kv[0]).lower()):
                total = sum(row["held"])
                info = names.get(item_id) or names.get(str(item_id)) or {}
                w.writerow([item_id, item_name(names, item_id), info.get("q", ""), max(0, total - row["reserved"]),
                            row["reserved"], total, *row["held"], wants.get(item_id, wants.get(str(item_id), ""))])
        written.append(path)
        # What really moved: bank toons' mail in and out, and the guild bank's own log.
        kinds = {"sent": "Donation", "received": "Donation", "mailin": "Mail in", "moved": "Move",
                 "mailout": "Mail out", "deposit": "Guild bank deposit", "withdraw": "Guild bank withdrawal"}
        ledger = []
        for d in (guild.get("donations") or {}).values():
            status = d.get("status")
            out = status in ("mailout", "withdraw")
            frm, to = (d.get("bank"), d.get("by")) if out else (d.get("by"), d.get("bank"))
            ledger.append((int(d.get("created") or 0), kinds.get(status, status), bank_title(guild, frm), bank_title(guild, to),
                           donation_items({"items": d.get("items")}, names) if d.get("items") else "",
                           money(d["money"]) if int(d.get("money") or 0) else "", status, d.get("note") or ""))
        path = os.path.join(folder, prefix + "ledger.csv")
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["Date", "Type", "From", "To", "Items", "Gold", "Status", "Note"])
            for row in sorted(ledger, reverse=True):
                w.writerow([day(row[0]), *row[1:]])
        written.append(path)
        path = os.path.join(folder, prefix + "gold.csv")
        with open(path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["Date", *toon_names, "Total"])
            histories = [(guild.get("gold") or {}).get(b) for b in bank_ids]
            now = time.time()
            end = datetime.datetime.fromtimestamp(now).replace(hour=23, minute=59, second=59).timestamp()
            for d in range(89, -1, -1):
                at = min(now, end - d * 86400)
                values = [gold_at(h, at) for h in histories]
                if any(v is not None for v in values):
                    w.writerow([day(at), *["" if v is None else int(v) // 10000 for v in values],
                                sum(int(v) for v in values if v is not None) // 10000])
        written.append(path)
    return written


# --- Discord webhook -------------------------------------------------------------------------------

def multipart(payload, filename, data):
    """payload_json plus one file, the way Discord takes attachments."""
    boundary = "unninjabank" + os.urandom(8).hex()
    body = (f'--{boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\n'
            f'Content-Type: application/json\r\n\r\n').encode() + json.dumps(payload).encode() + b"\r\n"
    body += (f'--{boundary}\r\nContent-Disposition: form-data; name="files[0]"; filename="{filename}"\r\n'
             f'Content-Type: application/json\r\n\r\n').encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def request(method, url, payload=None, file=None):
    if file:
        data, ctype = multipart(payload, *file)
    else:
        data, ctype = (json.dumps(payload).encode() if payload is not None else None), "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": ctype, "User-Agent": USER_AGENT})
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


def delete_message(webhook, message_id):
    try:
        request("DELETE", f"{webhook.split('?')[0].rstrip('/')}/messages/{message_id}")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise


# --- Sharing the message list between officers' PCs ------------------------------------------------
# Webhooks can only find messages they're given the ID of, so the PCs keep their state (which Discord message
# is which bank, request or thank-you) as a file attached to one message, the sync message, which every invite
# names. Each run reads it first and writes it back after posting.

def sync_load(webhook, message_id):
    """The shared state, {} if the message has none yet, or None if the message is gone."""
    base = webhook.split("?")[0].rstrip("/")
    try:
        msg = request("GET", f"{base}/messages/{message_id}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise
    for att in msg.get("attachments") or []:
        if att.get("filename") == SYNC_FILE:
            req = urllib.request.Request(att["url"], headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=20) as resp:
                return json.loads(resp.read() or b"{}")
    return {}


def sync_save(webhook, message_id, state):
    """Replaces the sync message's file (or posts a new sync message); returns its ID."""
    base = webhook.split("?")[0].rstrip("/")
    data = json.dumps(state, separators=(",", ":")).encode()
    payload = {"content": SYNC_TEXT, "attachments": [{"id": 0, "filename": SYNC_FILE}], "allowed_mentions": {"parse": []}}
    if message_id:
        try:
            request("PATCH", f"{base}/messages/{message_id}", payload, (SYNC_FILE, data))
            return message_id
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
    payload.update(username="Guild Bank", flags=4096)  # 4096: post without a notification
    return request("POST", f"{base}?wait=true", payload, (SYNC_FILE, data))["id"]


def get_path(state, key):
    for part in key[:-1]:
        state = (state or {}).get(part) or {}
    return (state or {}).get(key[-1])


def set_path(state, key, value):
    for part in key[:-1]:
        state = state.setdefault(part, {})
    state[key[-1]] = value


def message_of(entry):
    return entry.get("message") if isinstance(entry, dict) else entry


def merge_state(remote, ours, touched):
    """Puts what this run posted (touched: key -> (posted a new message?, webhook, the message it had before)) into
    the latest shared state. If another PC posted the same thing in the meantime, theirs is kept and ours is
    returned to delete."""
    out = json.loads(json.dumps(remote or {}))
    duplicates = []
    for key, (created, webhook, before) in touched.items():
        mine, theirs = get_path(ours, key), get_path(out, key)
        if created and message_of(theirs) not in (None, before, message_of(mine)):
            if message_of(mine):
                duplicates.append((webhook, message_of(mine)))
            continue
        set_path(out, key, mine)
    # Requests closed for three months won't change again.
    cutoff = time.time() - 90 * 86400
    requests = out.get("requests") or {}
    for request_id in [r for r, e in requests.items() if e.get("status") in FINAL and (e.get("updated") or 0) < cutoff]:
        del requests[request_id]
    return out, duplicates


def sync_webhook(args):
    return args.sync_webhook or args.webhook


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def locate(args):
    """The SavedVariables file to read, or None if there isn't one yet."""
    path = args.savedvars or (find_saved_variables(args.wow_dir, args.account) or [None])[0]
    return path if path and os.path.exists(path) else None


def missing_message(args):
    # Say exactly what was tried, and whether the settings file was read at all.
    settings = (f"Settings read from {CONFIG_PATH}." if os.path.exists(CONFIG_PATH)
                else f"No settings file at {CONFIG_PATH} (copy guildbanktoons.example.json to that name).")
    if args.savedvars:
        tried = f"There's no file at the savedvars path:\n  {args.savedvars}"
    else:
        dirs = [args.wow_dir] if args.wow_dir else DEFAULT_WOW_DIRS
        tried = "Looked for _forever_/WTF/Account/*/SavedVariables/GuildBankToons.lua (or _classic_era_) under:\n  " + "\n  ".join(dirs)
    return (f"Couldn't find GuildBankToons.lua.\n{tried}\n{settings}\nSet \"savedvars\" to the file's full path, or pass "
            "--savedvars. (WoW writes the file the first time you log out or /reload with the addon on.)")


def freshness(guild):
    """The newest time in this PC's copy of the guild, so an older copy doesn't overwrite a newer one's message."""
    stamps = [int((b or {}).get("stamp") or 0) for b in (guild.get("banks") or {}).values()]
    stamps += [int((d or {}).get("created") or 0) for d in (guild.get("donations") or {}).values()]
    stamps += [int((r or {}).get("updated") or 0) for r in (guild.get("requests") or {}).values()]
    return max(stamps, default=0)


def run_once(args, state, path=None):
    path = path or locate(args)
    if not path:
        sys.exit(missing_message(args))
    data = load_saved_variables(path).get("GuildBankToonsDB") or {}
    # A dry run works from this PC's own list, so it never needs Discord (the installer uses it as a check).
    synced = bool(args.sync_message) and not args.export_only and not args.dry_run
    if synced:
        remote = sync_load(sync_webhook(args), args.sync_message)
        if remote is None:
            print("The sync message is gone from Discord, so this PC can't tell which messages the others posted. "
                  "Run --invite on one PC and reinstall the others with the new code. Posting from this PC's own list "
                  "until then.", file=sys.stderr)
            synced = False
        else:
            state.clear()
            state.update(remote)
    touched = {}  # state key -> (posted a new message?, webhook, previous message) for everything this run changed

    def post(key, webhook, message_id, payload):
        new = publish(webhook, message_id, payload)
        touched[key] = (new != message_id, webhook, message_id)
        return new

    names = data.get("items") or {}
    changed = 0
    for guild_name, guild in (data.get("guilds") or {}).items():
        if args.guild and args.guild.lower() not in guild_name.lower():
            continue
        banks = guild.get("banks") or {}
        reserved = reserved_by_bank(guild)
        for bank_id in designated(guild):
            snap = banks.get(bank_id)
            if not snap:
                continue
            slot = f"{guild_name}|{bank_id}"
            seen = state.setdefault(slot, {})
            held = {str(k): v for k, v in sorted(reserved.get(bank_id, {}).items())}
            title = bank_title(guild, snap.get("owner"))
            if (not args.force and seen.get("stamp") == snap.get("stamp") and seen.get("hash") == snap.get("hash")
                    and seen.get("reserved", {}) == held and seen.get("title", title) == title):
                continue
            if not args.force and int(snap.get("stamp") or 0) < int(seen.get("stamp") or 0):
                continue  # another PC already posted a newer copy
            payload = build_message(guild_name, snap, names, args.link_base, reserved.get(bank_id), title)
            if args.dry_run:
                print(json.dumps(payload, indent=2, ensure_ascii=False))
                continue
            seen["message"] = post((slot,), args.webhook, seen.get("message"), payload)
            seen["stamp"], seen["hash"], seen["reserved"], seen["title"] = snap.get("stamp"), snap.get("hash"), held, title
            changed += 1
            print(f"Updated Discord for {snap.get('owner')} ({guild_name}).")
            time.sleep(1)  # stay well inside the webhook rate limit
        if not args.no_summary:
            slot = f"summary|{guild_name}"
            seen = state.setdefault(slot, {})
            payload = build_summary_message(guild_name, guild, names)
            fingerprint = json.dumps(payload, sort_keys=True)
            fresh = freshness(guild)
            if args.force or (seen.get("fingerprint") != fingerprint and fresh >= int(seen.get("fresh") or 0)):
                if args.dry_run:
                    print(json.dumps(payload, indent=2, ensure_ascii=False))
                else:
                    hook = args.summary_webhook or args.webhook
                    seen["message"] = post((slot,), hook, seen.get("message"), payload)
                    seen["fingerprint"], seen["fresh"] = fingerprint, fresh
                    changed += 1
                    print(f"Updated the goals message for {guild_name}.")
                    time.sleep(1)
        if not args.no_donations:
            thanked = state.get("donations")
            first_run = thanked is None
            thanked = state.setdefault("donations", {})
            donations = sorted((guild.get("donations") or {}).items(), key=lambda kv: kv[1].get("created") or 0)
            for donation_id, donation in donations:
                # Thank donors once the bank toon has the donation; the first run only takes note of old ones.
                if donation.get("status") != "received" or donation_id in thanked:
                    continue
                if first_run and not args.force:
                    thanked[donation_id] = None
                    touched[("donations", donation_id)] = (False, None, None)
                    continue
                payload = build_donation_message(donation, names)
                if args.dry_run:
                    print(json.dumps(payload, indent=2, ensure_ascii=False))
                    continue
                thanked[donation_id] = post(("donations", donation_id), args.donations_webhook or args.webhook, None, payload)
                changed += 1
                print(f"Thanked {donation.get('by')} for a donation to {donation.get('bank')}.")
                time.sleep(1)
        if args.no_requests:
            continue
        posted = state.setdefault("requests", {})
        requests = sorted((guild.get("requests") or {}).items(), key=lambda kv: kv[1].get("updated") or 0)
        for request_id, req in requests:
            seen, status = posted.get(request_id), req.get("status")
            # Finished before this PC ever saw it: nothing to ping about.
            if not args.force and ((seen is None and status in FINAL) or (seen and seen.get("status") == status)):
                continue
            # Another PC already posted a later step (requests only move forward).
            if not args.force and seen and (STAGE.get(status, 0) < STAGE.get(seen.get("status"), 0)
                                            or int(req.get("updated") or 0) < int(seen.get("updated") or 0)):
                continue
            webhook = args.requests_webhook or args.webhook
            payloads = [build_request_message(req, names, args.link_base, args.ping_role)]
            if status == "approved":
                payloads.append(build_approval_ping(req, names, args.link_base, args.approval_ping))
            if args.dry_run:
                for payload in payloads:
                    print(json.dumps(payload, indent=2, ensure_ascii=False))
                continue
            message = post(("requests", request_id), webhook, seen and seen.get("message"), payloads[0])
            if status == "approved":
                publish(webhook, None, payloads[1])
            posted[request_id] = {"message": message, "status": status, "updated": req.get("updated")}
            changed += 1
            print(f"Posted request {req.get('count')}{'g' if not req.get('item') else 'x item ' + str(req.get('item'))} by {req.get('by')} ({status}).")
            time.sleep(1)
    if args.export:
        for written in export_csv(data, args.export, args.guild):
            print(f"Wrote {written}")
    if not args.dry_run and not args.export_only:
        if synced and touched:
            merged, duplicates = merge_state(sync_load(sync_webhook(args), args.sync_message) or {}, state, touched)
            for webhook, message_id in duplicates:
                delete_message(webhook, message_id)
                print("Another PC posted the same message at the same moment; removed this PC's copy.")
            state.clear()
            state.update(merged)
            sync_save(sync_webhook(args), args.sync_message, state)
        with open(STATE_PATH, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
    return path, changed


def invite_code(settings):
    """A code that sets up another officer's companion: the webhooks and Discord settings, base64-encoded."""
    shared = {k: settings[k] for k in INVITE_KEYS if settings.get(k)}
    return INVITE_PREFIX + base64.urlsafe_b64encode(json.dumps(shared, separators=(",", ":")).encode()).decode().rstrip("=")


def read_invite(code):
    code = re.sub(r"\s", "", code or "")
    if not code.startswith(INVITE_PREFIX):
        raise ValueError("That isn't an Un-Ninja Bank invite code (they start with UNB1:).")
    body = code[len(INVITE_PREFIX):]
    try:
        settings = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    except ValueError:
        raise ValueError("That invite code is cut off or mistyped; copy the whole thing again.")
    if not isinstance(settings, dict) or not settings.get("webhook"):
        raise ValueError("That invite code has no webhook in it.")
    return {k: v for k, v in settings.items() if k in INVITE_KEYS}


def make_invite(args):
    """Sets up the sync message if there isn't one, saves its ID in the settings file, and prints the invite code."""
    state = load_json(STATE_PATH, {})
    hook = sync_webhook(args)
    if args.sync_message and sync_load(hook, args.sync_message) is not None:
        print(f"Using the sync message that's already set up ({args.sync_message}).")
    else:
        args.sync_message = sync_save(hook, None, state)
        config = load_json(CONFIG_PATH, {})
        config["sync_message"] = args.sync_message
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)
        print(f"Posted the sync message in Discord ({args.sync_message}) and saved it in {CONFIG_PATH}.")
        print("Leave that message there; deleting it makes every PC start over.")
    print()
    print(invite_code(vars(args)))
    print()
    print("Give that code to officers who'll run the companion; they paste it into the installer. It holds your webhook")
    print("URLs, so send it privately (a DM or an officer-only channel): anyone with it can post as the bank.")


def open_log(path):
    """Sends output to a file (for runs in the background, with no window), keeping it under about a megabyte."""
    try:
        if os.path.getsize(path) > 1_000_000:
            os.replace(path, path + ".old")
    except OSError:
        pass
    log = open(path, "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = log
    print(f"--- {datetime.datetime.now():%Y-%m-%d %H:%M:%S} started")


def main():
    for stream in (sys.stdout, sys.stderr):
        # Windows consoles and pipes default to a code page without emoji.
        if stream is not None and hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    config = load_json(CONFIG_PATH, {})
    p = argparse.ArgumentParser(description="Post Un-Ninja Bank contents to Discord.")
    p.add_argument("--webhook", default=os.environ.get("GUILDBANKTOONS_WEBHOOK") or config.get("webhook"))
    p.add_argument("--savedvars", default=config.get("savedvars"), help="path to SavedVariables/GuildBankToons.lua")
    p.add_argument("--wow-dir", default=config.get("wow_dir"), help="World of Warcraft install folder")
    p.add_argument("--account", default=config.get("account"), help="WTF account folder name")
    p.add_argument("--guild", default=config.get("guild"), help="only post guilds whose name contains this")
    p.add_argument("--link-base", default=config.get("link_base", ""),
                   help="item link prefix, e.g. https://www.wowhead.com/classic/item= (blank: plain names)")
    p.add_argument("--requests-webhook", default=config.get("requests_webhook"),
                   help="separate webhook (channel) for requests; defaults to --webhook")
    p.add_argument("--ping-role", default=config.get("ping_role"), help="Discord role ID to ping for new requests")
    p.add_argument("--approval-ping", default=config.get("approval_ping"),
                   help='mention for approvals, e.g. "<@123>" (a user) or "<@&456>" (a role)')
    p.add_argument("--no-requests", action="store_true", default=config.get("no_requests", False),
                   help="don't post requests")
    p.add_argument("--donations-webhook", default=config.get("donations_webhook"),
                   help="separate webhook (channel) for donation thank-yous; defaults to --webhook")
    p.add_argument("--no-donations", action="store_true", default=config.get("no_donations", False),
                   help="don't post donation thank-yous")
    p.add_argument("--summary-webhook", default=config.get("summary_webhook"),
                   help="separate webhook (channel) for the goals message; defaults to --webhook")
    p.add_argument("--no-summary", action="store_true", default=config.get("no_summary", False),
                   help="don't post the goals message")
    p.add_argument("--export", metavar="FOLDER", default=config.get("export"),
                   help="also write inventory.csv, ledger.csv and gold.csv to this folder after every update")
    p.add_argument("--sync-webhook", default=config.get("sync_webhook"),
                   help="webhook (channel) for the sync message; defaults to --webhook")
    p.add_argument("--sync-message", default=config.get("sync_message"),
                   help="ID of the sync message that lets several PCs share the same Discord messages")
    p.add_argument("--invite", action="store_true", help="print an invite code for install.py on another officer's PC")
    p.add_argument("--log", metavar="FILE", help="write output to this file instead of the screen")
    p.add_argument("--watch", action="store_true", help="keep running and update after every save")
    p.add_argument("--interval", type=int, default=config.get("interval", 15), help="seconds between checks")
    p.add_argument("--dry-run", action="store_true", help="print the messages instead of posting")
    p.add_argument("--force", action="store_true", help="post even if nothing changed")
    args = p.parse_args()
    # Only exporting: no webhook needed and nothing posted.
    args.export_only = bool(args.export) and not args.webhook and not args.dry_run
    if args.export_only:
        args.dry_run = True
        args.no_summary = args.no_donations = args.no_requests = True
    if not args.webhook and not args.dry_run:
        sys.exit("No webhook URL. Set it in guildbanktoons.json, GUILDBANKTOONS_WEBHOOK, or --webhook.")

    if args.log:
        open_log(args.log)
    if args.invite:
        return make_invite(args)

    state = load_json(STATE_PATH, {})
    path = locate(args)
    if not args.watch:
        run_once(args, state, path)
        return
    with open(PID_PATH, "w") as f:
        f.write(str(os.getpid()))
    if not path:
        print(missing_message(args) + "\nWaiting for it to show up.", file=sys.stderr)
        while not path:
            time.sleep(args.interval)
            path = locate(args)
    print(f"Watching {path} (Ctrl-C to stop).")
    last = None
    while True:
        if not args.sync_message:
            # An invite code made while this runs: start sharing without a restart.
            args.sync_message = load_json(CONFIG_PATH, {}).get("sync_message")
        try:
            mtime = os.path.getmtime(path)
            if mtime != last:
                if last is not None:
                    time.sleep(2)  # let WoW finish writing the file
                run_once(args, state, path)
                last = mtime
        except (OSError, ValueError, urllib.error.URLError) as e:
            # Offline or Discord busy: try again on the next check.
            print(f"Skipped an update: {e}", file=sys.stderr)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
