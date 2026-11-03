# Changelog: Forever - Guild Bank Toons

## [Unreleased]

### Added
- First version: shares designated bank characters' bags, bank and gold over guild addon chat, with guildmates relaying copies so the bank stays visible while the bank character is offline.
- Guild-wide bank characters set by the guild master (up to 20). The list syncs to every guildmate and is relayed while the guild master is offline; guild info tags and personal follows still work alongside it.
- Window with game-style tabs along the bottom: Bank, Requests, Settings and Guild Master. Resizable and scalable, and it remembers its place. Opens from a minimap button, the AddOns menu, Options → AddOns, or `/gbt`.
- Bank tab: bank toons in a sidebar, items totalled across toons with each toon's share shown, search, Bags/Bank filters and sorting. Item tooltips show guild bank counts anywhere in the game.
- Request dialog: click an item, pick the toon, amount and note.
- Settings tab for every option, and a Guild Master tab to add and remove the guild's bank toons without slash commands.
- Requests: Ctrl-click an item (or `/gbt request`) to ask for it. Officers, the guild master and bank characters approve or deny; approvers with the addon get an alert, officers without it get a whisper. Approved items are reserved (taken off the available counts) until the bank character mails them, which closes the request. Requests sync to guildmates who log in later.
- Mail helper for bank characters: lists approved requests at the mailbox, fills in the recipient, subject and note, and attaches the exact count from your bags. Sending the mail marks the request mailed.
- Discord companion script that posts each bank character to a webhook message and keeps it updated, plus one message per request that can ping an officer role, a separate approval ping for whoever mails, and a strike-through once it's mailed, denied or cancelled.
