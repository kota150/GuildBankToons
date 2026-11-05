# Forever - Guild Bank Toons

**Your guild bank character's bags, bank and gold, visible to the whole guild, even while it's offline.** Forever - Guild Bank Toons shares the bank character's contents over guild addon chat. Every guildmate running it keeps a copy and passes it on, so anyone online can show it to anyone else. A companion script posts the same contents to Discord.

Built for **WoW Forever**. It also loads on Classic Era and retail, but Forever is what it's designed and tested around.

## Setting up

1. **Pick the bank character(s).** The guild can have as many as it likes. The easiest way: the **guild master** opens the window (minimap button or `/gbt`), goes to the **Guild Master** tab, types the bank toon's name and presses **Add bank toon**. The list goes to every guildmate running the addon and is passed along like the bank contents, so people who log in while the guild master is offline still get it. Everyone can see the tab; only the guild master (rank 0) can change it, up to 20 bank toons. (`/gbt bank add|remove|clear|list Name` does the same from chat.)

   Alternatively, an officer can add a tag per bank character to the guild info text (Guild → Guild Information), for example `[GBT:Vault Keeper]`; `/gbt tag` prints it for you. Use the bank character's full name, first name and surname. Case and spaces don't matter, and no realm is needed. Both ways can be used together. Any member can also follow a bank toon just for themselves under **Settings**.
2. **Log in on the bank character with the addon enabled.** Its bags are read straight away. The bank can only be read while it's open, so **visit the banker once**. After that the bank contents carry over until the next visit.
3. **Optional: say who the officers are.** By default ranks 0 and 1 (guild master and the rank below) handle requests. To change it, add `[GBT:officers=2]` to the guild info, which makes ranks 0–2 officers.
4. That's it. Guildmates click the minimap button (or type `/gbt`) to browse.

## How offline sharing works

- The bank character records a snapshot with a server-time stamp whenever its bags, bank or gold change, and pushes it to everyone online.
- Every guildmate stores the newest copy they've seen. On login each client says "here's the copy I have". Anyone holding a newer one sends it, and anyone holding an older one asks for it. One random-delayed answer serves the whole guild.
- As long as *someone* who saw the latest copy is online, it reaches everyone else. The window shows how old the copy is and who relayed it.

**Trust.** Addon messages can't be signed, so a guildmate with a modified addon could relay a fake copy while the bank character is offline. The addon limits the damage: copies are only accepted for designated bank characters, stamps far in the future are rejected, and the moment the real bank character logs in its own copy wins and replaces the fake everywhere. The guild master's bank list works the same way: only a list naming the current guild master is accepted, and the guild master's own list replaces any fake one when they log in.

## Donations

Mail is the main way items reach the bank toons, and every donation goes in a public log.

1. **Donate at any mailbox.** A **Donate to the guild bank** panel opens beside the mail window. Pick a bank toon, add gold and a note if you like, and press **Fill in the mail**: it switches to Send Mail and fills in the recipient, subject and note. Right-click items in your bags to attach them (the panel lists what's attached), then press **Send donation**.
2. **It's logged.** As soon as the mail goes out, the donation shows in everyone's **Donations** tab as *On its way*.
3. **The bank toon confirms it.** When the bank toon opens its mailbox, the addon checks the mail and marks the donation **Received**, with what actually arrived. The donor gets a thank-you.

Mail a bank toon gets from a guildmate **without the addon** is logged too, when the bank toon opens it. Mail between bank toons, returned mail and COD mail isn't counted. Only the bank toon a donation went to can mark it received. The **Donations** tab has search (donor, bank toon or item), *All / This week / Mine*, and a weekly summary. The log keeps 60 days and syncs to guildmates when they log in. Bank toons don't see the Donate panel; they get the mail helper instead.

## Requests

Guildmates ask for items, an approver says yes or no, and the bank character mails what was approved.

1. **Ask.** Click an item on the Bank tab. Pick which toon to ask (each shows how many it has available), enter how many and an optional note, and press **Request**. `/gbt request [item link] 20 note` does the same from chat.
2. **Approvers are told.** Officers, the guild master and bank characters can approve. The ones running the addon get a chat alert with a sound right away. After a few seconds, the requester's game whispers up to 3 online officers who *didn't* acknowledge it, which are the ones without the addon. If nobody who can approve is online, the request waits, and they see "N waiting for approval" when they log in.
3. **Approve or deny.** In the window's **Requests** view (or `/gbt approve N`, `/gbt deny N`), press **Approve** or **Deny**. The requester can **Cancel** while it's still waiting.
4. **Approved items are reserved.** An approved request takes its items off the available counts in the window, tooltips and Discord ("15 (30 reserved)"), so nobody else is promised the same stack. It stays in the list as *approved* until it's mailed. The requester and the bank character are both told, and Discord posts a separate message that can ping whoever mails for the bank.
5. **The bank character mails it.** At a mailbox, the **mail helper** opens beside the mail window with every approved request for this bank character. **Fill** switches to Send Mail, addresses it to the requester, fills the subject and note, and attaches exactly the right count from your bags, splitting a stack when needed. Check it and press **Send** (the helper's or the game's). Once the mail goes through, the request is marked **mailed** and the reservation is released. Mailed it some other way? Press **Mailed** in the Requests view.

The game only sends mail on a click, so the last step is always yours. Turn on `/gbt autofill` to have the first approved request filled as soon as you open a mailbox. Items have to be in your bags to attach; the helper says so if some are still in the bank.

Requests sync like the bank contents: everyone keeps a copy, and a guildmate logging in catches up from whoever is online. Requests only move forward (waiting → approved → mailed, or denied or cancelled), and each step is only accepted from someone allowed to take it: approvals and denials from officers, the guild master or a bank character, mailed from that request's bank character, cancel from the requester. Anything else is ignored. Active requests expire after 30 days, finished ones after 7.

## Features

- **One window, five tabs** along the bottom, like the game's character window: **Bank**, **Requests**, **Donations**, **Settings** and **Guild Master**. Open it from the minimap button, the AddOns menu, Options → AddOns, or `/gbt`. Drag the corner to resize it, set its size in Settings, and it remembers where you left it.
- **Bank tab**: every bank toon down the side with its gold and how fresh its copy is. Beside them, the items laid out as **bag slots** with icons, quality borders and counts, and gold along the bottom like a bag. With **All bank toons** picked, counts are totals across toons; hover a slot to see each toon's share ("Vault Keeper 40, Coin Purse 5"). Switch to **List** to see the shares on every row. Search, All / Bags / Bank, and sort by name, count or quality.
- **Click** an item to request it, **Shift-click** to link it in chat. Hover for the game's tooltip plus each toon's bags, bank and reserved counts.
- **Available counts**: what's left after approved requests, with the reserved amount alongside.
- **Requests tab**: search by item, name or note; Active / Mine / All; Approve / Deny / Mailed / Cancel buttons for whoever can use them.
- **Donations tab**: the guild's public donation log (see Donations above).
- **Donate panel** beside the mail window, for everyone who isn't a bank toon.
- **Settings tab**: every option as a checkbox, window size, toons you follow just for yourself, Sync now, and sync counters.
- **Guild Master tab**: the guild's bank toons, with Add, Remove and Remove all for the guild master.
- **Mail helper** at mailboxes on bank characters.
- **Item tooltips** show "Guild bank (Bankalt): 40" anywhere you hover that item.

## Commands

Everything below is also in the window; the commands are there if you prefer chat.

| Command | What it does |
| --- | --- |
| `/gbt` | Open or close the window |
| `/gbt settings`, `/gbt donations`, `/gbt gm` | Open the Settings, Donations or Guild Master tab |
| `/gbt sync` | Ask the guild for the latest contents |
| `/gbt status` | List bank characters, how old each copy is, and message counters |
| `/gbt bank add First Last` / `bank remove First Last` / `bank clear` | Set the guild's bank characters for everyone (guild master only) |
| `/gbt bank list` | Show the bank characters the guild master set |
| `/gbt add First Last` / `/gbt remove First Last` | Follow a bank character just for you |
| `/gbt tag First Last` | Print the guild info tag |
| `/gbt requests` | Show requests (numbered in chat) |
| `/gbt request [item link] 20 note` | Request items from the bank selected in the window |
| `/gbt approve N` / `deny N` | Approve or deny request N (officers, guild master, bank characters) |
| `/gbt mailed N` | Mark approved request N mailed (bank character) |
| `/gbt cancel N` | Cancel your own request while it's waiting |
| `/gbt mail N` | At a mailbox, fill a mail for request N (or the first approved one) |
| `/gbt mailhelper`, `/gbt autofill` | Toggle the mail helper, and filling the first request when a mailbox opens |
| `/gbt whispers` | Toggle whispering officers who don't have the addon |
| `/gbt companion` | Toggle the "reload to post to Discord" prompt (turn on where the Discord companion runs) |
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

**Requests on Discord.** Each new request gets its own message, which can ping an officer role (`ping_role`). When it's approved, that message shows who approved it, and a second message goes out saying the bank character should mail it. Set `approval_ping` to ping someone there, as `<@USER_ID>` for a person or `<@&ROLE_ID>` for a role. Once it's mailed, denied or cancelled, the first message is struck through ("📬 Mailed by Vault Keeper (approved by Olivia Stone)"). The bank character's message lists reserved amounts next to its items. To get an ID, enable Developer Mode in Discord, then right-click the user or role → Copy ID. Set `requests_webhook` to post requests in a different channel. Requests that finished before your PC saw them aren't posted.

Because the script only sees what your game has saved, the ping arrives the next time *your* game saves: on logout or `/reload`. On the PC running the script, type `/gbt companion` so the addon offers a one-click reload whenever requests change.

The script finds `World of Warcraft/_forever_/WTF/Account/*/SavedVariables/GuildBankToons.lua` (or `_classic_era_`) on its own; set `wow_dir`, `account` or `savedvars` in the config if yours lives elsewhere. Set `link_base` (for example `https://www.wowhead.com/classic/item=`) to turn item names into links. It needs Python 3.8 or newer and nothing else.

## Installing

1. Copy the `GuildBankToons` folder into your AddOns folder (the folder keeps that short name; the game lists it as *Forever - Guild Bank Toons*):
   - **WoW Forever**: `World of Warcraft/_forever_/Interface/AddOns/GuildBankToons`
   - Classic Era: `World of Warcraft/_classic_era_/Interface/AddOns/GuildBankToons`
   - Retail: `World of Warcraft/_retail_/Interface/AddOns/GuildBankToons`
2. Restart the game (or `/reload`) and enable *Forever - Guild Bank Toons* on the character select AddOns screen.

## Compatibility

**WoW Forever is the main target.**

- **TOC**: `GuildBankToons_Forever.toc` and the default `GuildBankToons.toc` both declare interface **16001**. Forever recognizes `_Forever` TOC files. If a Forever patch changes the number and the game calls the addon out of date, check it with `/dump select(4, GetBuildInfo())` and update both files.
- **Modern API**: Forever runs on the same UI code as retail Midnight, so the addon uses the `C_Container`, `C_Item`, `C_ChatInfo` and `C_GuildInfo` APIs, retail-style frames and tabs, Options → AddOns, and the AddOns menu button. It respects Midnight's secret values and holds guild messages while the game blocks addon chat (such as combat in instances), sending them afterwards.
- **Names**: characters are identified by first name and surname only. Any realm the game adds is ignored. The game may report only your first name at login, so each character learns its full name from its first message to the guild a couple of seconds in; Settings and `/gbt status` show the name it's using.
- **Trial accounts**: Forever doesn't let trial accounts send addon messages. On a trial account the addon still shows what guildmates share, but it can't make requests or share a bank toon, and it says so when you log in and in the request dialog.

**Also loads on**, with less testing:

- **Classic Era** (`GuildBankToons_Vanilla.toc`, interface 11509). Realms are ignored there too, so two guildmates with the same name on different connected realms would count as one.
- **Retail** (`GuildBankToons_Mainline.toc`, Midnight interface 120000–120007), handy for previewing the window. If it's flagged out of date, tick *Load out of date AddOns*.

The bank scan covers both the Classic bank layout and modern bank tabs; containers a client doesn't have are skipped.

## Development

`tests/sync_sim.py` runs several simulated clients on one guild channel (direct sync, relaying while the bank character is offline, catching up, a forged copy being replaced, the guild master's bank list reaching everyone and resisting fakes, donations sent, confirmed by the bank toon, logged from guildmates without the addon and protected from forged confirmations, and requests: alerts, whispers only to officers without the addon, approvals only from approvers, reserved counts, the mail helper attaching the exact count with one split, mailing closing the request, stale copies not reopening it, cancelling, and catching up at login):

```bash
pip install lupa
```
```bash
python3 tests/sync_sim.py GuildBankToons.lua
```
