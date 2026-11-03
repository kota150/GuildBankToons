# Forever - Guild Bank Toons

**Your guild bank character's bags, bank and gold, visible to the whole guild, even while it's offline.** Forever - Guild Bank Toons shares the bank character's contents over guild addon chat. Every guildmate running it keeps a copy and passes it on, so anyone online can show it to anyone else. A companion script posts the same contents to Discord.

Built for **WoW Forever**, and also works on **Classic Era**.

## Setting up

1. **Pick the bank character(s).** An officer adds a tag to the guild info text (Guild → Guild Information):
   ```
   [GBT:Bankalt-YourRealm]
   ```
   Add one tag per bank character. `/gbt tag Name-Realm` prints the tag for you. If your officers don't want to edit the guild info, each member (and the bank character) can type `/gbt add Bankalt-YourRealm` instead.
2. **Log in on the bank character with the addon enabled.** Its bags are read straight away. The bank can only be read while it's open, so **visit the banker once**. After that the bank contents carry over until the next visit.
3. That's it. Guildmates type `/gbt` to browse.

## How offline sharing works

- The bank character records a snapshot with a server-time stamp whenever its bags, bank or gold change, and pushes it to everyone online.
- Every guildmate stores the newest copy they've seen. On login each client says "here's the copy I have". Anyone holding a newer one sends it, and anyone holding an older one asks for it. One random-delayed answer serves the whole guild.
- As long as *someone* who saw the latest copy is online, it reaches everyone else. The window shows how old the copy is and who relayed it.

**Trust.** Addon messages can't be signed, so a guildmate with a modified addon could relay a fake copy while the bank character is offline. The addon limits the damage: copies are only accepted for designated bank characters, stamps far in the future are rejected, and the moment the real bank character logs in its own copy wins and replaces the fake everywhere.

## Features

- **Browse window** (`/gbt`): one button per bank character, search, All / Bags / Bank filters, gold, and how long ago the snapshot was taken.
- **Shift-click** an item to link it in chat. **Ctrl-click** to open a whisper to the bank character asking for it.
- **Item tooltips** show "Guild bank (Bankalt): 40" anywhere you hover that item.

## Commands

| Command | What it does |
| --- | --- |
| `/gbt` | Open or close the window |
| `/gbt sync` | Ask the guild for the latest contents |
| `/gbt status` | List bank characters, how old each copy is, and message counters |
| `/gbt add Name-Realm` / `/gbt remove Name-Realm` | Follow a bank character just for you |
| `/gbt tag Name-Realm` | Print the guild info tag |
| `/gbt tooltips`, `/gbt quiet` | Toggle tooltip lines and chat messages |

## Discord

WoW addons can't reach the internet, and SavedVariables are only written when you **log out or `/reload`**. The companion script in [`companion/`](companion/) reads that file and keeps one Discord message per bank character up to date through a webhook.

Any guildmate who runs the addon has a copy, so the script doesn't have to run on the bank character's PC.

1. In Discord: channel settings → Integrations → Webhooks → New Webhook → copy the URL.
2. Copy `companion/guildbanktoons.example.json` to `companion/guildbanktoons.json` and paste the webhook URL in. That file is git-ignored; keep the URL private, since anyone who has it can post to the channel.
3. Try it without posting:
   ```bash
   python3 companion/guildbanktoons_discord.py --dry-run
   ```
4. Run it for real. Use `--watch` to keep it running and update after every logout or `/reload`:
   ```bash
   python3 companion/guildbanktoons_discord.py --watch
   ```

The script finds `World of Warcraft/_forever_/WTF/Account/*/SavedVariables/GuildBankToons.lua` (or `_classic_era_`) on its own; set `wow_dir`, `account` or `savedvars` in the config if yours lives elsewhere. Set `link_base` (for example `https://www.wowhead.com/classic/item=`) to turn item names into links. It needs Python 3.8 or newer and nothing else.

## Installing

1. Copy the `GuildBankToons` folder into your AddOns folder (the folder keeps that short name; the game lists it as *Forever - Guild Bank Toons*):
   - WoW Forever: `World of Warcraft/_forever_/Interface/AddOns/GuildBankToons`
   - Classic Era: `World of Warcraft/_classic_era_/Interface/AddOns/GuildBankToons`
2. Restart the game (or `/reload`) and enable *Forever - Guild Bank Toons* on the character select AddOns screen.

## Compatibility

- **WoW Forever** (`GuildBankToons_Forever.toc`, interface 16001 from the beta) is the main target. It uses the modern container and item APIs, supports first and last names, and holds guild messages while the game blocks addon chat. If Forever launches with a different interface number, update the TOC.
- **Classic Era** (`GuildBankToons_Vanilla.toc`, interface 11509) runs from the same file.
- The bank scan covers the Classic bank layout and modern bank tabs; containers a client doesn't have are skipped.

## Development

`tests/sync_sim.py` runs several simulated clients on one guild channel (direct sync, relaying while the bank character is offline, catching up, and a forged copy being replaced):

```bash
pip install lupa
```
```bash
python3 tests/sync_sim.py GuildBankToons.lua
```
