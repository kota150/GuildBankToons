# Un-Nina Bank

**Your guild bank character's bags, bank and gold, visible to the whole guild, even while it's offline.** Un-Nina Bank (formerly *Forever - Guild Bank Toons*) shares the bank character's contents over guild addon chat. Every guildmate running it keeps a copy and passes it on, so anyone online can show it to anyone else. A companion script posts the same contents to Discord.

Built for **WoW Forever**. It also loads on Classic Era and retail, but Forever is what it's designed and tested around.

## Setting up

1. **Pick the bank character(s).** The guild can have as many as it likes. The easiest way: the **guild master or an officer** opens the window (minimap button or `/gbt`), goes to the **Guild** tab, types the bank toon's name and presses **Add bank toon**. **Rename** gives a bank toon a name the guild sees ("Mats & Herbs"); officers can also right-click any bank or guild bank tab in the Bank tab's sidebar to name it. The list goes to every guildmate running the addon and is passed along like the bank contents, so people who log in while the guild master is offline still get it. Everyone can see the tab; only officers and the guild master can change it, up to 20 bank toons. (`/gbt bank add|remove|clear|list Name` does the same from chat.)

   Alternatively, an officer can add a tag per bank character to the guild info text (Guild → Guild Information), for example `[GBT:Vault Keeper]`; `/gbt tag` prints it for you. Use the bank character's full name, first name and surname. Case and spaces don't matter, and no realm is needed. Both ways can be used together. Any member can also follow a bank toon just for themselves under **Settings**.
2. **Log in on the bank character with the addon enabled.** Its bags are read straight away. The bank can only be read while it's open, so **visit the banker once**. After that the bank contents carry over until the next visit.
3. **Optional: say who the officers are.** By default ranks 0 and 1 (guild master and the rank below) handle requests. To change it, add `[GBT:officers=2]` to the guild info, which makes ranks 0–2 officers.
4. That's it. Guildmates click the minimap button (or type `/gbt`) to browse.

## Forever's guild bank

WoW Forever's own guild bank shows up too, **public tabs only**. Whenever a guildmate with the addon opens the guild bank, it shares the tabs every member can see, like a bank toon's contents: each gets its own entry in the Bank tab's sidebar ("Guild Bank - Mats"), its items count toward everything (totals, Needs, tooltips, Discord, export), and the guild bank's gold counts toward the guild's gold and gold goals.

**Restricted tabs are never shared.** Officers choose which rank's view is shared: Guild tab → Rules → *Share guild bank tabs that this rank can see* (the **lowest rank** by default, so only what every member can see). A tab only higher ranks can see stays in the game of whoever opened it: it isn't sent to guildmates, saved, posted to Discord or exported, even when an officer or the guild master opens the guild bank. The game only tells each player which tabs *their own* rank can see, so the addon learns this from members of that rank (or a lower one): once one of them has opened the guild bank (with the addon), the tabs they could see are shared from then on. Until then, nothing from the guild bank is shared. Changing the rank takes effect for everyone: tabs that are no longer shared disappear, and newly shared ones arrive the next time someone who can see them opens the guild bank. (A member of that rank running a modified addon could claim a restricted tab is visible to them; nothing else can make one shared.)

Members can request items from a guild bank tab like from a bank toon. An **officer** takes it out of the guild bank and mails it (the mail helper shows officers these requests at a mailbox). Anyone whose rank can withdraw from that tab can of course still take it themselves. The Donate panel doesn't offer guild bank tabs: deposit into those in person.

## How offline sharing works

- The bank character records a snapshot with a server-time stamp whenever its bags, bank or gold change, and pushes it to everyone online.
- Every guildmate stores the newest copy they've seen. On login each client says "here's the copy I have" for each bank toon, the guild master's list, and the requests and donations.
- **Offers, then one ask.** Guildmates holding something newer reply with a one-line offer saying how new theirs is (at most 3 offers of the same copy, so there's always a backup). After 5 seconds the client picks the newest offer, preferring the bank toon's own copy on a tie, and asks just that guildmate to send it. If they haven't started within 2 seconds, it asks whoever has the next newest copy. Only one full copy is ever sent per catch-up.
- **Paced to the game's limit.** Each player may send 10 addon messages in a burst, then 1 a second. The addon sends at that pace, and short messages (questions, offers, the copy someone is waiting for) go before long transfers.
- As long as *someone* who saw the latest copy is online, it reaches everyone else. The window shows how old the copy is and who relayed it.

**Trust.** Addon messages can't be signed, so a guildmate with a modified addon could relay a fake copy while the bank character is offline. The addon limits the damage: copies are only accepted for designated bank characters, stamps far in the future are rejected, and the moment the real bank character logs in its own copy wins and replaces the fake everywhere. The guild master's bank list works the same way: only a list naming the current guild master is accepted, and the guild master's own list replaces any fake one when they log in.

## Donations

Mail is the main way items reach the bank toons, and every donation goes in a public log.

1. **Donate at any mailbox.** A **Donate to the guild bank** panel opens beside the mail window. Pick a bank toon, add gold and a note if you like, and press **Fill in the mail**: it switches to Send Mail and fills in the recipient, subject and note. Right-click items in your bags to attach them (the panel lists what's attached), then press **Send donation**.
2. **It's logged.** As soon as the mail goes out, the donation shows in everyone's **Ledger** tab as *On its way*.
3. **The bank toon confirms it.** When the bank toon opens its mailbox, the addon checks the mail and marks the donation **Received**, with what actually arrived. The donor gets a thank-you.

4. **Not sure what to give?** The panel lists what the guild needs most, and **Add needed items** attaches anything in your bags that's on the guild's wanted list, up to the amount still needed.

Mail a bank toon gets from a guildmate **without the addon** is logged too, when the bank toon opens it. Mail from another bank toon is logged as a **move**, not a donation; returned mail and COD mail aren't counted. Only the bank toon a donation went to can mark it received. Bank toons don't see the Donate panel; they get the mail helper instead.

## The ledger

The **Ledger** tab is the guild bank's public record: donations in, moves between bank toons, and requests mailed out (withdrawals), newest first. Search by name, bank toon or item, filter *All / In / Out / Mine*, and see this week's totals at the top. Entries are kept for 60 days and sync to guildmates when they log in.

## Goals, needs and rules

Officers and the guild master set these on the **Guild** tab; everyone can see them, and they reach the whole guild the same way the bank list does.

- **Gold goals** ("Raid consumables: 500g"), for all bank toons together or one toon. The **Goals** tab shows the guild bank's gold as a bar chart over the last 30 or 90 days, with each goal drawn across it as a line, plus a progress bar per goal and the change over the last week. Gold history builds up on every guildmate's client as bank toons report in.
- **Needs**: items with a target amount. Shift-click an item into the box (or Alt-click it on the Bank tab). The Bank tab's **Needs** view lists them, most needed first; the Donate panel offers them; officers get a chat alert when one drops below its target.
- **Bank names**: a name the guild sees for any bank toon or guild bank tab, shown in the window, tooltips, requests and on Discord.
- **Which guild bank tabs are shared** (see Forever's guild bank above).
- **Rules** for requests:
  - a **daily limit** of items per member;
  - **automatic approval** for requests up to a set size from chosen ranks (an approver's client online approves them, the bank toon first);
  - whether members can **request gold**. Gold requests are made from the Bank tab's **Request gold** button, approved like any request, and the mail helper puts the gold in the mail.

## Export

**Export** on the Bank and Ledger tabs (or `/gbt export`) opens a window with the inventory (a column per bank toon, plus what the guild wants), the ledger, or the gold history, as CSV or plain text, already selected: press Ctrl+C and paste it into a spreadsheet, Discord or a file. (Addons can't save files or use the clipboard themselves.) The Discord companion can also write the same three as CSV files; see below.

## Requests

Guildmates ask for items, an approver says yes or no, and the bank character mails what was approved.

1. **Ask.** Click an item on the Bank tab. Pick which toon to ask (each shows how many it has available), enter how many and an optional note, and press **Request**. `/gbt request [item link] 20 note` does the same from chat.
2. **Approvers are told.** Officers, the guild master and bank characters can approve. The ones running the addon get a chat alert with a sound right away. After a few seconds, the requester's game whispers up to 3 online officers who *didn't* acknowledge it, which are the ones without the addon. If nobody who can approve is online, the request waits, and they see "N waiting for approval" when they log in.
3. **Approve or deny.** In the window's **Requests** view (or `/gbt approve N`, `/gbt deny N`), press **Approve** or **Deny**. The requester can **Cancel** while it's still waiting.
4. **Approved items are reserved.** An approved request takes its items off the available counts in the window, tooltips and Discord ("15 (30 reserved)"), so nobody else is promised the same stack. It stays in the list as *approved* until it's mailed. The requester and the bank character are both told, and Discord posts a separate message that can ping whoever mails for the bank.
5. **The bank character mails it.** At a mailbox, the **mail helper** opens beside the mail window with every approved request for this bank character. **Fill** switches to Send Mail, addresses it to the requester, fills the subject and note, and attaches exactly the right count from your bags, splitting a stack when needed. Check it and press **Send** (the helper's or the game's). Once the mail goes through, the request is marked **mailed** and the reservation is released. Mailed it some other way? Press **Mailed** in the Requests view.

The game only sends mail on a click, so the last step is always yours.

**Several items in one request.** A request can hold up to 8 different items (one approval, one mail); other addons use this for crafting materials. **Craft orders** have the bank mail the items to a crafter instead of the requester: the crafter is told when they're approved and again when they arrive ("craft it and mail it to Alice"), and the Ledger shows who they went to. Turn on `/gbt autofill` to have the first approved request filled as soon as you open a mailbox. Items have to be in your bags to attach; the helper says so if some are still in the bank.

Requests sync like the bank contents: everyone keeps a copy, and a guildmate logging in catches up from whoever is online. Requests only move forward (waiting → approved → mailed, or denied or cancelled), and each step is only accepted from someone allowed to take it: approvals and denials from officers, the guild master or a bank character, mailed from that request's bank character, cancel from the requester. Anything else is ignored. Active requests expire after 30 days, finished ones after 7.

## Features

- **One window, six tabs** along the bottom, like the game's character window: **Bank**, **Requests**, **Ledger**, **Goals**, **Settings** and **Guild**. Open it from the minimap button, the AddOns menu, Options → AddOns, or `/gbt`. The minimap button joins LibDBIcon when another addon has loaded it (so it lines up with other addons' buttons and works with button-collector and minimap-skin addons, and shows in LibDataBroker displays such as Titan Panel); otherwise it's drawn the same way and follows round, square and corner-shaped minimaps. Drag the corner to resize it, set its size in Settings, and it remembers where you left it.
- **Bank tab**: every bank toon down the side with its gold and how fresh its copy is. Beside them, the items laid out as **bag slots** with icons, quality borders and counts, and gold along the bottom like a bag. With **All bank toons** picked, counts are totals across toons; hover a slot to see each toon's share ("Vault Keeper 40, Coin Purse 5"). Switch to **List** to see the shares on every row. Search, All / Bags / Bank / Needs, sort by name, count or quality, **Export**, and **Request gold**.
- **Click** an item to request it, **Shift-click** to link it in chat. Hover for the game's tooltip plus each toon's bags, bank and reserved counts.
- **Available counts**: what's left after approved requests, with the reserved amount alongside.
- **Requests tab**: search by item, name or note; Active / Mine / All; Approve / Deny / Mailed / Cancel buttons for whoever can use them.
- **Ledger tab**: donations, moves and withdrawals (see The ledger above).
- **Goals tab**: the gold chart, goal progress and what the guild needs.
- **Donate panel** beside the mail window, for everyone who isn't a bank toon.
- **Settings tab**: every option as a checkbox, window size, toons you follow just for yourself, Sync now, and sync counters.
- **Guild tab**: the guild's bank toons (guild master), and gold goals, needs and request rules (officers).
- **Mail helper** at mailboxes on bank characters.
- **Item tooltips** show "Guild bank (Bankalt): 40" anywhere you hover that item.

## Commands

Everything below is also in the window; the commands are there if you prefer chat.

| Command | What it does |
| --- | --- |
| `/gbt` | Open or close the window |
| `/gbt settings`, `/gbt ledger`, `/gbt goals`, `/gbt gm` | Open the Settings, Ledger, Goals or Guild tab |
| `/gbt export` | Open the export window |
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

**Goals on Discord.** One message per guild stays up to date with the bank's gold (with a two-week trend line), each gold goal as a progress bar, what the guild needs, and this week's top donors. Set `summary_webhook` to post it in a different channel, or `no_summary` to turn it off.

**Donations on Discord.** When a bank toon receives a donation, the companion posts a thank-you ("🎁 Alice donated 20× Linen Cloth to Vault Keeper. Thank you!"). Set `donations_webhook` for a different channel, or `no_donations` to turn it off. The first run only takes note of donations already in the log, so it doesn't flood the channel.

**CSV files.** `--export FOLDER` (or `"export"` in the config) writes `inventory.csv`, `ledger.csv` and `gold.csv` after every update. Without a webhook it just writes the files:
```bash
python3 companion/guildbanktoons_discord.py --export exports
```

**Requests on Discord.** Each new request gets its own message, which can ping an officer role (`ping_role`). When it's approved, that message shows who approved it, and a second message goes out saying the bank character should mail it. Set `approval_ping` to ping someone there, as `<@USER_ID>` for a person or `<@&ROLE_ID>` for a role. Once it's mailed, denied or cancelled, the first message is struck through ("📬 Mailed by Vault Keeper (approved by Olivia Stone)"). The bank character's message lists reserved amounts next to its items. To get an ID, enable Developer Mode in Discord, then right-click the user or role → Copy ID. Set `requests_webhook` to post requests in a different channel. Requests that finished before your PC saw them aren't posted.

Because the script only sees what your game has saved, the ping arrives the next time *your* game saves: on logout or `/reload`. On the PC running the script, type `/gbt companion` so the addon offers a one-click reload whenever requests change.

The script finds `World of Warcraft/_forever_/WTF/Account/*/SavedVariables/GuildBankToons.lua` (or `_classic_era_`) on its own; set `wow_dir`, `account` or `savedvars` in the config if yours lives elsewhere. Set `link_base` (for example `https://www.wowhead.com/classic/item=`) to turn item names into links. It needs Python 3.8 or newer and nothing else.

## Installing

Install it from **CurseForge** (the CurseForge app picks the right version for WoW Forever, Classic Era or Retail), or by hand:

1. Copy the `GuildBankToons` folder into your AddOns folder (the folder keeps that short name; the game lists it as *Un-Nina Bank*):
   - **WoW Forever**: `World of Warcraft/_forever_/Interface/AddOns/GuildBankToons`
   - Classic Era: `World of Warcraft/_classic_era_/Interface/AddOns/GuildBankToons`
   - Retail: `World of Warcraft/_retail_/Interface/AddOns/GuildBankToons`
2. Restart the game (or `/reload`) and enable *Un-Nina Bank* on the character select AddOns screen.

## Compatibility

**WoW Forever is the main target.**

- **TOC**: `GuildBankToons_Forever.toc` and the default `GuildBankToons.toc` both declare interface **16001**. Forever recognizes `_Forever` TOC files. If a Forever patch changes the number and the game calls the addon out of date, check it with `/dump select(4, GetBuildInfo())` and update both files.
- **Modern API**: Forever runs on the same UI code as retail Midnight, so the addon uses the `C_Container`, `C_Item`, `C_ChatInfo` and `C_GuildInfo` APIs, retail-style frames and tabs, Options → AddOns, and the AddOns menu button. It respects Midnight's secret values and holds guild messages while the game blocks addon chat (such as combat in instances), sending them afterwards.
- **Names**: characters are identified by first name and surname only, however the game writes them: "Vault Keeper", "Vault-Keeper", or with a realm added ("Vault-Keeper-NekRosh", "Vault-Keeper-CAMWOWUS2Realm2PvE"). Realms are ignored: guildmates on Forever can report different ones. Your own full name comes from the game at login (its surname too); if it's ever missing, the character learns it from its first message to the guild a couple of seconds in. Settings and `/gbt status` show the name it's using. This matches how GuildForge reads Forever names.
- **Alts**: the addon remembers each of your characters separately (by the game's character ID), so alts that share a first name never get mixed up, and a character only acts as a bank toon once it's sure of its own full name. Data is kept per guild (by name on Forever; by guild and realm on Classic Era): alts in the same guild share one copy, alts in other guilds have their own. Settings and the window's size and place are shared by all your characters.
- **Trial accounts**: Forever doesn't let trial accounts send addon messages. The addon doesn't try to guess (the game's trial flags can be set on accounts that send fine); if the game blocks you, you'll still see what guildmates share.

**Also loads on**, with less testing:

- **Classic Era** (`GuildBankToons_Vanilla.toc`, interface 11509). Realms are ignored there too, so two guildmates with the same name on different connected realms would count as one.
- **Retail** (`GuildBankToons_Mainline.toc`, interface 120107 and 120105). If it's flagged out of date, tick *Load out of date AddOns*.

The bank scan covers both the Classic bank layout and modern bank tabs; containers a client doesn't have are skipped.

## For other addons

Other addons (GuildForge, for crafting materials) can use the guild bank through the global `GuildBankToonsAPI`. Check that it exists before using it; functions keep their meaning across versions, and `version` goes up when one is added.

| Function | What it does |
| --- | --- |
| `GuildBankToonsAPI.version` | `1` |
| `HasBank()` | `true` in a guild with at least one bank toon or shared guild bank tab |
| `Available(itemID)` | How many are available (after approved requests), and a table of how many each bank toon or tab has |
| `Request(items, note, mailTo)` | `items` is `{[itemID] = count}`. Asks whichever bank toons have them (one request per toon); `mailTo` makes it a craft order mailed to that crafter. Returns the request IDs, `{[itemID] = count}` the bank couldn't cover, and why nothing was made |
| `Open(tab)` | Opens the window on a tab: `items`, `requests`, `donations`, `goals`, `settings` or `gm` |
| `RegisterCallback(fn)` | Calls `fn()` whenever the bank, requests or plan change |

An addon that uses it should list `## OptionalDeps: GuildBankToons` in its TOC so it loads after this one, and hide anything that depends on it when `GuildBankToonsAPI` is missing or `HasBank()` is false.

## When it isn't syncing

Type **`/gbt debug`**. It shows the name you're sharing as, whether you're found in the guild roster (and your rank), whether the addon's message channel is registered, how many messages were sent, received and rejected, each bank toon with how old your copy is, and the last messages with anything **REJECTED** in red and why. **Settings → Message log** (or `/gbt log`) shows the whole log, ready to copy into Discord or a bug report.

Common causes:
- **No bank toons here yet**: the guild master or an officer adds them on the Guild tab, and the list reaches you from them or a guildmate who has it.
- **The bank toon hasn't shared yet**: log in on it with the addon and open its bank once.
- **"ignored ... not one of this guild's bank toons here"** in the log: you have the bank toon's contents coming in, but not the list that says it's a bank toon. `/gbt sync` asks for it again.
- **Nothing received at all**: check `/gbt debug` on both sides; both need the addon enabled and to be in the same guild.

## Releasing

Same as the author's other addons: push a version tag and the GitHub Actions workflow (`.github/workflows/release.yml`) builds `GuildBankToons.zip` with the BigWigs packager, using `.pkgmeta` (which leaves out `docs`, `tests`, `companion` and other repo-only files) and the matching `CHANGELOG.md` section as release notes.

```bash
git tag v1.0.0
```
```bash
git push origin main v1.0.0
```

It always creates a GitHub release with the ZIP. It also uploads to CurseForge once the repository has a `CF_API_KEY` secret and the TOCs have `## X-Curse-Project-ID:` set. `CURSEFORGE.md` is the project description to paste into CurseForge.

## Development

`tests/sync_sim.py` runs several simulated clients on one guild channel (direct sync, relaying while the bank character is offline, catching up, asking only the guildmate with the newest copy and falling back to the next one when they don't answer, a forged copy being replaced, the guild master's bank list reaching everyone and resisting fakes, donations sent, confirmed by the bank toon, logged from guildmates without the addon and protected from forged confirmations, and requests: alerts, whispers only to officers without the addon, approvals only from approvers, reserved counts, the mail helper attaching the exact count with one split, mailing closing the request, stale copies not reopening it, cancelling, and catching up at login):

```bash
pip install lupa
```
```bash
python3 tests/sync_sim.py GuildBankToons.lua
```

The simulation can't draw real frames or talk to a real server, so [docs/TESTING.md](docs/TESTING.md) is a checklist for trying it on Forever.
