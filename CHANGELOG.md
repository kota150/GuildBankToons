# Changelog: Forever - Guild Bank Toons

## [Unreleased]

### Fixed
- The minimap button lines up with other addons' buttons: it joins LibDBIcon when another addon has loaded it, and otherwise uses LibDBIcon's ring and sizes and follows square and corner-shaped minimaps (it used to float off the edge of a square minimap).
- Alts with the same first name could be taken for each other for a moment at login, and an alt could briefly publish its bags as a bank toon's. Characters are now told apart by their character ID, and nothing is published for a bank toon until the character's full name is confirmed.
- WoW Forever names written as "First-Surname" (and with another ruleset's realm added, like "-CAMWOWUS2Realm2PvE") were cut down to the first name, so two characters sharing a first name were treated as one. Names are now read as first name and surname in every form, the same way GuildForge does, and your own surname comes straight from the game at login. The Discord companion reads them the same way.
- On Classic Era, guilds with the same name on different realms no longer share data. On Forever guilds stay keyed by name, since guildmates report different realms; saved data moves to the right key automatically.

### Added
- Only public guild bank tabs are shared: the ones the guild's lowest rank can see. Restricted tabs never leave the game of whoever opened them (not sent, saved, posted or exported), even for officers and the guild master.
- Forever's guild bank: whoever opens it shares its public tabs, which then count everywhere (totals, Needs, gold goals, Discord, export). Members can request from it; officers mail those.
- Requests can hold several items (one approval, one mail) and can be craft orders, mailed to a crafter who's told what to make and for whom.
- `GuildBankToonsAPI` for other addons such as GuildForge: what the bank has, making requests and craft orders, opening the window, and a change callback.
- Gold goals with a Goals tab: a bar chart of the guild bank's gold over 30 or 90 days with goal lines, progress bars, and the week's change. Goals also show on Discord.
- Needs: officers set target amounts for items. The Bank tab's Needs view, the Donate panel's Add needed items button, and low-stock alerts for officers use them.
- Request rules set by officers: a daily item limit per member, automatic approval of small requests for chosen ranks, and gold requests (with the mail helper filling in the gold).
- Ledger tab (was Donations): donations, moves between bank toons, and mailed-out requests as withdrawals.
- Export window for the inventory, ledger and gold history as CSV or text, ready to copy.
- Bank toons send only what changed when a change is small; guildmates missing the base copy ask for the whole thing.
- Discord companion: a self-updating goals message (gold, trend, goals, needs, top donors), a thank-you post per received donation, and `--export` to write CSV files.
- Catching up asks one guildmate: those with newer copies send a one-line offer, and after 5 seconds the client asks only the one with the newest copy, falling back to the next newest if they don't start within 2 seconds. Sending is paced to the game's addon-message limit, with short messages ahead of long transfers.
- Donations by mail: a Donate panel beside the mail window fills in a donation to a bank toon, and a public Donations tab logs every donation. The bank toon confirms each one when it opens its mailbox, and also logs mail from guildmates without the addon.
- Bank tab laid out like a bag: item slots with icons, quality borders and counts, gold along the bottom, and a List view for each toon's share.
- Built around WoW Forever: the default TOC targets Forever (interface 16001), and trial accounts, which Forever blocks from sending addon messages, get a clear browse-only mode.
- First version: shares designated bank characters' bags, bank and gold over guild addon chat, with guildmates relaying copies so the bank stays visible while the bank character is offline.
- Guild-wide bank characters set by the guild master (up to 20). The list syncs to every guildmate and is relayed while the guild master is offline; guild info tags and personal follows still work alongside it.
- Window with game-style tabs along the bottom: Bank, Requests, Settings and Guild Master. Resizable and scalable, and it remembers its place. Opens from a minimap button, the AddOns menu, Options → AddOns, or `/gbt`.
- Bank tab: bank toons in a sidebar, items totalled across toons with each toon's share shown, search, Bags/Bank filters and sorting. Item tooltips show guild bank counts anywhere in the game.
- Request dialog: click an item, pick the toon, amount and note.
- Settings tab for every option, and a Guild Master tab to add and remove the guild's bank toons without slash commands.
- Requests: Ctrl-click an item (or `/gbt request`) to ask for it. Officers, the guild master and bank characters approve or deny; approvers with the addon get an alert, officers without it get a whisper. Approved items are reserved (taken off the available counts) until the bank character mails them, which closes the request. Requests sync to guildmates who log in later.
- Mail helper for bank characters: lists approved requests at the mailbox, fills in the recipient, subject and note, and attaches the exact count from your bags. Sending the mail marks the request mailed.
- Discord companion script that posts each bank character to a webhook message and keeps it updated, plus one message per request that can ping an officer role, a separate approval ping for whoever mails, and a strike-through once it's mailed, denied or cancelled.
