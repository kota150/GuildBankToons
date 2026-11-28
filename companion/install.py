#!/usr/bin/env python3
"""Installs (or updates) the Un-Ninja Bank Discord companion on this PC and starts it whenever you log in.

    python3 install.py              # install, or update an earlier install (keeps its settings)
    python3 install.py --uninstall  # stop it and remove it

On Windows run "Un-Ninja Bank Companion Setup.exe" (this file and the companion built with PyInstaller, so no
Python is needed), or double-click "Install on Windows.bat" if you have Python. On a Mac double-click
"Install on Mac.command", on Linux run install-linux.sh.
Paste the invite code an officer gave you (they get one with `guildbanktoons_discord.py --invite`), or set up a
new webhook. Python 3.8+, standard library only.
"""

import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import time

FROZEN = getattr(sys, "frozen", False)  # the Windows setup .exe
if not FROZEN and sys.version_info < (3, 8):
    sys.exit("The companion needs Python 3.8 or newer. Get it from https://www.python.org/downloads/")

HERE = getattr(sys, "_MEIPASS", None) or os.path.dirname(os.path.abspath(__file__))
SCRIPT = "guildbanktoons_discord.py"
EXE = "UnNinjaBankCompanion.exe"  # the companion on its own, bundled inside the setup .exe
SETUP_EXE = "Un-Ninja Bank Companion Setup.exe"
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\UnNinjaBankCompanion"
NAME = "Un-Ninja Bank companion"
SERVICE = "un-ninja-bank-companion"
LABEL = "com.unninjabank.companion"
HOME = os.path.expanduser("~")

if sys.platform == "win32":
    TARGET = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.join(HOME, "AppData", "Local"), "UnNinjaBank")
    STARTUP = os.path.join(os.environ.get("APPDATA") or "", "Microsoft", "Windows", "Start Menu", "Programs", "Startup",
                           f"{NAME}.vbs")
elif sys.platform == "darwin":
    TARGET = os.path.join(HOME, "Library", "Application Support", "UnNinjaBank")
    STARTUP = os.path.join(HOME, "Library", "LaunchAgents", f"{LABEL}.plist")
else:
    TARGET = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "un-ninja-bank")
    STARTUP = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "systemd", "user",
                           f"{SERVICE}.service")
CONFIG = os.path.join(TARGET, "guildbanktoons.json")
MENU = os.path.join(os.environ.get("APPDATA") or "", "Microsoft", "Windows", "Start Menu", "Programs", "Un-Ninja Bank")
LOG = os.path.join(TARGET, "companion.log")
PID = os.path.join(TARGET, ".guildbanktoons.pid")


def ask(question, default=""):
    try:
        answer = input(f"{question}{f' [{default}]' if default else ''}: ").strip()
    except EOFError:
        raise KeyboardInterrupt  # no more input (the window closed): stop instead of asking forever
    return answer or default


def yes(question, default=True):
    answer = ask(f"{question} ({'Y/n' if default else 'y/N'})").lower()
    return default if not answer else answer.startswith("y")


def wow_folders():
    """Places WoW is usually installed, on every drive on Windows."""
    names = ["World of Warcraft", os.path.join("Program Files (x86)", "World of Warcraft"),
             os.path.join("Program Files", "World of Warcraft"), os.path.join("Games", "World of Warcraft"),
             os.path.join("Battle.net", "World of Warcraft")]
    if sys.platform == "win32":
        roots = [f"{d}:\\" for d in "CDEFGH" if os.path.exists(f"{d}:\\")]
    elif sys.platform == "darwin":
        roots = ["/Applications", os.path.join(HOME, "Applications")]
        names = ["World of Warcraft"]
    else:
        roots = glob.glob(os.path.join(HOME, "Games", "*", "drive_c")) + glob.glob(os.path.join(HOME, ".wine*", "drive_c"))
        roots += glob.glob(os.path.join(HOME, ".local", "share", "Steam", "steamapps", "compatdata", "*", "pfx", "drive_c"))
    return [p for p in (os.path.join(r, n) for r in roots for n in names) if os.path.isdir(p)]


def saved_files(folders):
    found = []
    for folder in folders:
        for flavor in ("_forever_", "_classic_era_", "_retail_"):
            found += glob.glob(os.path.join(folder, flavor, "WTF", "Account", "*", "SavedVariables", "GuildBankToons.lua"))
    return sorted(set(found), key=os.path.getmtime, reverse=True)


def pick_saved_file(current):
    """(savedvars, wow_dir): the GuildBankToons.lua to read, found on its own when there's one, else picked or pointed
    to. If WoW hasn't written it yet, just the WoW folder, and the companion waits for the file."""
    if current and os.path.exists(current) and yes(f"Keep reading {current}?"):
        return current, ""
    found = saved_files(wow_folders())
    while True:
        if len(found) == 1:
            print(f"Found the addon's saved file: {found[0]}")
            return found[0], ""
        if found:
            print("The addon has a saved file for more than one WoW account here. Which one should it read?")
            for i, path in enumerate(found, 1):
                stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(path)))
                print(f"  {i}. {path.split(os.sep)[-3]}  (last saved {stamp})")
            choice = ask("Number", "1")
            if choice.isdigit() and 1 <= int(choice) <= len(found):
                return found[int(choice) - 1], ""
            continue
        print("Couldn't find the addon's saved file. WoW writes it the first time you log out or /reload with")
        print("Un-Ninja Bank turned on.")
        folder = ask("Paste your World of Warcraft folder (the one with _forever_ in it), or press Enter to skip").strip('"')
        if not folder:
            print("Skipped. The companion will start posting once WoW has saved the file.")
            return "", ""
        if not os.path.isdir(folder):
            print(f"There's no folder at {folder}.")
            continue
        found = saved_files([folder])
        if not found:
            print("No saved file in there yet. The companion will start posting once you log out or /reload in WoW.")
            return "", folder


def get_settings(old):
    """Discord settings: from an invite code, kept from the last install, or a new webhook."""
    sys.path.insert(0, HERE)
    import guildbanktoons_discord as companion
    if old.get("webhook") and yes("Keep the Discord settings from your last install?"):
        return {k: old[k] for k in companion.INVITE_KEYS if k in old}
    print("Paste the invite code an officer gave you (it starts with UNB1:).")
    print("Setting up the first PC for your guild? Press Enter to paste a webhook URL instead.")
    while True:
        code = ask("Invite code")
        if not code:
            break
        try:
            return companion.read_invite(code)
        except ValueError as e:
            print(e)
    while True:
        hook = ask("Discord webhook URL (channel settings > Integrations > Webhooks > New Webhook > Copy URL)")
        if hook.startswith("https://") and "/api/webhooks/" in hook:
            return {"webhook": hook}
        print("That doesn't look like a webhook URL (https://discord.com/api/webhooks/...).")


def python_for_background():
    """pythonw on Windows, so no console window stays open."""
    if sys.platform == "win32":
        w = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
        if os.path.exists(w):
            return w
    return sys.executable


def companion_command(background=False):
    """How to run the installed companion: its .exe from the setup, or the script with Python."""
    if FROZEN:
        return [os.path.join(TARGET, EXE)]
    return [python_for_background() if background else sys.executable, os.path.join(TARGET, SCRIPT)]


def stop_running():
    """Stops the copy that's running now, so an update starts fresh."""
    if sys.platform == "darwin" and os.path.exists(STARTUP):
        subprocess.run(["launchctl", "unload", STARTUP], capture_output=True)
    elif sys.platform not in ("win32", "darwin") and shutil.which("systemctl"):
        subprocess.run(["systemctl", "--user", "stop", SERVICE], capture_output=True)
    try:
        pid = int(open(PID).read().strip())
    except (OSError, ValueError):
        return
    if is_companion(pid):
        try:
            os.kill(pid, signal.SIGTERM)
            print("Stopped the companion that was running.")
            time.sleep(1)
        except OSError:
            pass


def is_companion(pid):
    """Whether process `pid` is still the companion (process IDs get reused)."""
    if sys.platform == "win32":
        out = subprocess.run(["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"], capture_output=True, text=True).stdout
        return "python" in out.lower() or EXE.lower() in out.lower()
    out = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    return SCRIPT in out


def start_at_login():
    args = companion_command(background=True) + ["--watch", "--log", LOG]
    os.makedirs(os.path.dirname(STARTUP), exist_ok=True)
    if sys.platform == "win32":
        line = " ".join(f'""{a}""' for a in args)
        with open(STARTUP, "w", encoding="utf-8") as f:
            f.write(f'CreateObject("WScript.Shell").Run "{line}", 0, False\n')
        # Detached, its own process group, no window.
        subprocess.Popen(args, cwd=TARGET, creationflags=0x00000008 | 0x00000200 | 0x08000000)
        windows_extras()
        return "It starts by itself when you log in to Windows."
    if sys.platform == "darwin":
        items = "".join(f"\n    <string>{a.replace('&', '&amp;').replace('<', '&lt;')}</string>" for a in args)
        with open(STARTUP, "w", encoding="utf-8") as f:
            f.write(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array>{items}
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>{TARGET}</string>
</dict>
</plist>
""")
        subprocess.run(["launchctl", "load", STARTUP], check=False)
        return "It starts by itself when you log in to your Mac."
    if not shutil.which("systemctl"):
        os.remove(STARTUP) if os.path.exists(STARTUP) else None
        subprocess.Popen(args, cwd=TARGET, start_new_session=True)
        return "It's running now, but this system has no systemd: run install-linux.sh again after a restart."
    quoted = " ".join(f'"{a}"' for a in args)
    with open(STARTUP, "w", encoding="utf-8") as f:
        f.write(f"""[Unit]
Description={NAME} (posts the guild bank to Discord)
After=network-online.target

[Service]
ExecStart={quoted}
WorkingDirectory={TARGET}
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
""")
    subprocess.run(["systemctl", "--user", "daemon-reload"], check=False)
    subprocess.run(["systemctl", "--user", "enable", "--now", SERVICE], check=False)
    return "It starts by itself when you log in."


def windows_extras():
    """Start menu entries, and an entry in Settings > Apps so it can be removed like any program."""
    os.makedirs(MENU, exist_ok=True)
    run = " ".join(f'"{a}"' for a in companion_command())
    with open(os.path.join(MENU, "Make an invite code.bat"), "w", encoding="utf-8") as f:
        f.write(f'@echo off\r\ncd /d "{TARGET}"\r\n{run} --invite\r\npause\r\n')
    with open(os.path.join(MENU, "Companion log.bat"), "w", encoding="utf-8") as f:
        f.write(f'@echo off\r\nstart "" notepad "{LOG}"\r\n')
    if not FROZEN:
        return
    setup = os.path.join(TARGET, SETUP_EXE)
    with open(os.path.join(MENU, "Uninstall the companion.bat"), "w", encoding="utf-8") as f:
        f.write(f'@echo off\r\n"{setup}" --uninstall\r\n')
    import winreg
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY) as key:
        for name, value in (("DisplayName", NAME), ("Publisher", "Un-Ninja Bank"), ("InstallLocation", TARGET),
                            ("DisplayIcon", os.path.join(TARGET, EXE)), ("UninstallString", f'"{setup}" --uninstall'),
                            ("DisplayVersion", companion_version())):
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, value)
        winreg.SetValueEx(key, "NoModify", 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(key, "NoRepair", 0, winreg.REG_DWORD, 1)


def companion_version():
    sys.path.insert(0, HERE)
    import guildbanktoons_discord as companion
    return getattr(companion, "VERSION", "")


def remove_windows_extras():
    shutil.rmtree(MENU, ignore_errors=True)
    try:
        import winreg
        winreg.DeleteKey(winreg.HKEY_CURRENT_USER, UNINSTALL_KEY)
    except (ImportError, OSError):
        pass


def uninstall():
    stop_running()
    if sys.platform == "win32":
        remove_windows_extras()
    if os.path.exists(STARTUP):
        if sys.platform not in ("win32", "darwin") and shutil.which("systemctl"):
            subprocess.run(["systemctl", "--user", "disable", SERVICE], capture_output=True)
        os.remove(STARTUP)
    if os.path.isdir(TARGET) and yes(f"Delete its settings and log too ({TARGET})?"):
        inside = os.path.abspath(sys.executable).startswith(os.path.abspath(TARGET) + os.sep)
        if FROZEN and inside and sys.platform == "win32":
            # Windows won't delete a running program: remove the folder a moment after this window closes.
            subprocess.Popen(f'cmd /c ping -n 3 127.0.0.1 >nul & rmdir /s /q "{TARGET}"', creationflags=0x08000000)
        else:
            shutil.rmtree(TARGET, ignore_errors=True)
    print(f"Removed the {NAME}. Messages it posted stay in Discord.")


def install():
    source = os.path.join(HERE, EXE if FROZEN else SCRIPT)
    if not os.path.exists(source):
        sys.exit(f"{SCRIPT} has to be in the same folder as install.py. Unzip the whole companion download first.")
    print(f"Installing the {NAME} in {TARGET}")
    old = {}
    if os.path.exists(CONFIG):
        with open(CONFIG, encoding="utf-8") as f:
            old = json.load(f)
        print("Found an earlier install: updating it.")
    settings = get_settings(old)
    saved, wow_dir = pick_saved_file(old.get("savedvars"))
    for key in ("interval", "export"):
        if key in old:
            settings.setdefault(key, old[key])
    if saved:
        settings["savedvars"] = saved
    elif wow_dir:
        settings["wow_dir"] = wow_dir

    stop_running()
    os.makedirs(TARGET, exist_ok=True)
    shutil.copy2(source, os.path.join(TARGET, os.path.basename(source)))
    if FROZEN:
        # Keep a copy of the setup for Settings > Apps > Uninstall.
        if os.path.abspath(sys.executable) != os.path.abspath(os.path.join(TARGET, SETUP_EXE)):
            shutil.copy2(sys.executable, os.path.join(TARGET, SETUP_EXE))
    elif os.path.abspath(HERE) != os.path.abspath(TARGET):
        shutil.copy2(os.path.join(HERE, "install.py"), os.path.join(TARGET, "install.py"))
    with open(CONFIG, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
    if sys.platform != "win32":
        os.chmod(CONFIG, 0o600)  # it holds the webhook URL

    if settings.get("savedvars"):
        check = subprocess.run(companion_command() + ["--dry-run"], cwd=TARGET, capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
        if check.returncode:
            print("The companion couldn't read the saved file:")
            print((check.stderr or check.stdout).strip()[-1500:])
            sys.exit(1)
        print("Read the addon's saved file without problems.")
    how = start_at_login()
    print()
    print(f"Done. The {NAME} is running. {how}")
    print("It updates Discord every time you log out or /reload in WoW. In game, type /gbt companion so the addon")
    print("offers a one-click reload whenever a request changes.")
    print(f"Its log: {LOG}")
    print("To update it later, run the installer from a newer download; it keeps these settings.")
    if settings.get("webhook") and not settings.get("sync_message") and yes(
            "Make an invite code for other officers now? (It posts a small sync message in the channel.)", False):
        stop_running()
        subprocess.run(companion_command() + ["--invite"], cwd=TARGET)
        start_at_login()
    elif sys.platform == "win32":
        print('Start menu > Un-Ninja Bank > "Make an invite code" gives you a code for other officers.')


if __name__ == "__main__":
    try:
        uninstall() if "--uninstall" in sys.argv[1:] else install()
    except KeyboardInterrupt:
        print("\nStopped; nothing more was changed.")
    except SystemExit as e:
        if FROZEN and e.code not in (None, 0):
            print(e.code)
            input("Press Enter to close.")
        raise
    if FROZEN:
        input("\nPress Enter to close.")
