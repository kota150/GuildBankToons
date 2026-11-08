# Changelog

All notable changes to Un-Nina Bank (formerly Guild Bank Toons) are listed here.

## [1.0.2] - 2026-11-08

### Fixed
- **"Interface actions failed because of this AddOn"** no longer climbs in combat. WoW Forever blocks addons from reading the guild info text during combat; the addon now waits until combat ends to read it.

### Added
- If the game ever blocks something the addon does, it's noted in the message log and `/gbt debug`, and said once in chat, so it can be reported and fixed.

## [1.0.0] - 2026-11-07

First release, as **Un-Nina Bank** (it started out as *Forever - Guild Bank Toons*; the addon folder is still `GuildBankToons`, so nothing else changes). Built for **WoW Forever**; also runs on Classic Era and Retail.

### The guild bank, shared
- **Bank toons:** the guild master or an officer adds the guild's bank characters on the Guild tab (up to 20). Their bags, bank and gold go to every guildmate running the addon, and guildmates pass them along, so the bank stays browsable while the bank toons are offline.
- **Forever's guild bank:** whoever opens it shares the tabs a chosen rank can see (the lowest rank by default, set by officers under Rules). Tabs only higher ranks can see never leave the game of whoever opened them.
- **Bank names:** officers can give any bank toon or guild bank tab a name the guild sees.
- **Item tooltips** show guild bank counts anywhere in the game.

### The window
- Game-style tabs along the bottom: **Bank**, **Requests**, **Ledger**, **Goals**, **Settings** and **Guild**. Resizable and scalable, and it remembers its place. Opens from the minimap button, the AddOns menu, Options → AddOns or `/gbt`.
- **Bank tab:** bank toons and guild bank tabs down the side, items laid out like a bag (icons, quality borders, counts), totals across toons with each toon's share on hover or in the List view, search, Bags / Bank / Needs filters, sorting, gold along the bottom.
- **Export** the inventory, ledger or gold history as CSV or text, ready to copy.
- The minimap button lines up with other addons' buttons (it joins LibDBIcon when another addon has loaded it) and follows square minimaps.

### Requests
- Click an item to request it: pick the bank toon, how many and a note. Officers, the guild master and bank toons approve or deny; approvers with the addon get an alert, officers without it get a whisper.
- Approved items are reserved until mailed. At the mailbox, the bank toon's **mail helper** fills in the mail and attaches exactly the right count, splitting a stack into a free bag slot first when it has to; sending it marks the request mailed.
- **Gold requests**, and requests for **several items** in one mail.
- **Craft orders:** the bank mails the materials to a crafter, who's told what to make and for whom.
- **Rules** set by officers: a daily item limit per member, and automatic approval of small requests for chosen ranks.

### Donations and the ledger
- A **Donate** panel beside the mail window fills in a donation to a bank toon; **Add needed items** attaches anything the guild needs from your bags.
- The bank toon confirms each donation when it opens its mailbox, and also logs mail from guildmates without the addon.
- The **Ledger** is the public record of what really moved: everything bank toons mail out and receive (donations, mail from outside the guild, moves between bank toons), and deposits and withdrawals of items and gold from Forever's guild bank log for shared tabs.

### Goals and needs
- **Gold goals** with a chart of the guild bank's gold over 30 or 90 days, goal lines, progress bars and the week's change.
- **Needs:** officers set target amounts for items; they show in the Bank tab's Needs view, in the Donate panel, and as low-stock alerts for officers.

### Discord companion (optional, not part of the addon download)
- A Python script that keeps one Discord message per bank toon up to date, posts requests (with optional role pings), thanks donors, keeps a goals message current (gold trend, goals, needs, top donors), and can write CSV files.

### Built for WoW Forever
- Reads Forever names as first name and surname in every form the game writes them, ignores realms, and tells your alts apart.
- Syncs politely: guildmates offer what they have and only one sends it, at the game's addon-message pace, holding messages while the game blocks addon chat.
- **`/gbt debug` and a message log** (Settings → Message log) show what's being sent, received and rejected, and why, ready to copy into a bug report.
- **For other addons:** `GuildBankToonsAPI` lets addons such as GuildForge show guild bank stock and request materials.
