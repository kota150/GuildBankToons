# Changelog: Forever - Guild Bank Toons

## [Unreleased]

### Added
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
