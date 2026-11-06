# In-game test checklist (WoW Forever)

`tests/sync_sim.py` covers the sync logic, but it can't draw real frames or talk to a real server. Run through this on Forever with at least two accounts in the same guild (or one account and a willing guildmate), and note anything that looks off.

You need: the guild master (or an officer), one bank toon, and one ordinary member. `/gbt status` shows which name the addon is using for you and how many messages it has sent, received, rejected and still has queued.

## 1. Loading

- [ ] The AddOns list shows *Forever - Guild Bank Toons* and it isn't marked out of date. If it is, run `/dump select(4, GetBuildInfo())` and put that number in `GuildBankToons_Forever.toc` and `GuildBankToons.toc`.
- [ ] The minimap button shows and opens the window. It's also in the AddOns menu and under Options → AddOns.
- [ ] `/gbt status` shows your **full name** (first name and surname) within a few seconds of logging in.

## 2. The window

- [ ] All six tabs sit under the window and switch pages; the selected one looks selected.
- [ ] The window drags, resizes from the bottom-right corner, and comes back the same size and place after `/reload`.
- [ ] Settings → Window size changes the scale; Reset window puts it back.
- [ ] Search boxes show their hint text and a clear (×) button.
- [ ] Long lists scroll with the mouse wheel and the scroll bar.

## 3. Bank toons (guild master)

- [ ] Guild tab → Bank toons: add the bank toon. The member sees it appear within a few seconds.
- [ ] Log in on the bank toon, open its bank once, close it. The member's Bank tab fills in with the right items and gold.
- [ ] Bag view: icons, quality borders and counts look right; hovering shows each toon's share. List view shows the same.
- [ ] Log the bank toon out. A member who logs in afterwards still gets the contents (relayed by someone who saw them).

## 4. Requests

- [ ] Member clicks an item, requests 1, with a note. Officers with the addon get an alert; officers without it get a whisper.
- [ ] Officer approves it. The member is told; the item shows as reserved.
- [ ] On the bank toon at a mailbox: the mail helper lists it; **Fill** addresses the mail and attaches exactly the right count (try one that needs a stack split). Sending marks it mailed everywhere and it shows in the Ledger as *Mailed out*.
- [ ] **Request gold** on the Bank tab: approve it, and check the mail helper puts the gold in the mail's money field.

## 5. Donations

- [ ] Member at a mailbox: the Donate panel appears beside the mail window (not overlapping it).
- [ ] **Fill in the mail** switches to Send Mail with the recipient, subject and note filled in, and the gold in the money field.
- [ ] Right-click items to attach them; the panel lists them. **Send donation** sends it, and the Ledger shows it as *On its way*.
- [ ] Bank toon opens its mailbox: the donation turns *Received* for everyone and the member gets a thank-you. **Check how the mail shows the sender's name** (first name only, or first and last); the addon matches either, but tell us which.
- [ ] Mail the bank toon something *without* using the panel (or from a character without the addon): it's logged as a donation when the bank toon opens the mail.

## 6. Forever's guild bank and craft orders

- [ ] As an officer, open the guild bank before anyone of the lowest rank has: nothing from it is shared yet.
- [ ] As a member of the lowest rank, open the guild bank and close it. Within a few seconds, guildmates see each public tab in the Bank tab's sidebar ("Guild Bank - <tab name>"), with the right items, and the guild bank's gold on the Goals tab.
- [ ] As an officer, open the guild bank again: an officer-only tab doesn't appear for anyone (not even the officer), and `/gbt status` doesn't list it.
- [ ] Request an item from a guild bank tab. An officer approves it, takes it out, and at a mailbox the mail helper lists it; sending marks it mailed.
- [ ] With GuildForge installed: request materials for a recipe as a craft order to a crafter. The bank toon's mail goes to the crafter with every item; the crafter is told to craft it and mail it to you.

## 7. Goals, needs and rules (officer)

- [ ] Guild tab → Goals: add a gold goal. The Goals tab shows it as a line across the chart and as a progress bar, on the member's client too.
- [ ] Guild tab → Needs: shift-click an item into the box, set an amount, add it. Bank tab → Needs lists it. Alt-click an item on the Bank tab to change it.
- [ ] Donate panel (as the member, with a needed item in your bags): **Add needed items** attaches it.
- [ ] Take a needed item out of the bank toon until it's below the target: the officer gets a *Low stock* alert.
- [ ] Guild tab → Rules: set automatic approval for small requests and request 1 of something as the member. It's approved without anyone clicking.

## 8. Export and Discord

- [ ] Export on the Bank and Ledger tabs: the text is selected; Ctrl+C copies it; it pastes cleanly into a spreadsheet as CSV.
- [ ] On the PC running the companion, `/gbt companion` is on, and after a `/reload` the Discord channel gets the bank messages, the goals message, and a thank-you for the received donation.

## 9. Limits and busy times

- [ ] In an instance in combat, make a request; it should go out once combat ends.
- [ ] With several guildmates online, log in on a fresh character (or after deleting `WTF/.../SavedVariables/GuildBankToons.lua`). Everything should arrive within a minute or so, and `/gbt status` shouldn't show a large *rejected* count.
- [ ] Watch for "addon message throttled" or disconnects while lots is happening. If you see any, note what you were doing.
