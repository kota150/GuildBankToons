Un-Ninja Bank - Discord companion
=================================

Posts your guild bank to Discord every time you log out or /reload in WoW: one message per bank
character, a goals message, a message per item request and thank-yous for donations. Several officers
can run it at once; they all edit the same Discord messages.

On Windows, the easy way is "Un-Ninja Bank Companion Setup.exe" from the same GitHub release: it
needs nothing else (if Windows says it "protected your PC", click More info > Run anyway). This zip is
for Macs, Linux, and Windows PCs that have Python.

What you need
  - Python 3.8 or newer: https://www.python.org/downloads/
    (Windows: tick "Add python.exe to PATH" in the installer.)
  - An invite code from the officer who set up your guild's companion. It starts with UNB1:.
    Keep it private: anyone who has it can post in the bank's Discord channels.

Install, or update to a newer version
  Windows: double-click "Install on Windows.bat"
  Mac:     double-click "Install on Mac.command" (the first time: right-click > Open)
  Linux:   run ./install-linux.sh

  Paste the invite code when it asks. It finds WoW's saved file on its own (or asks you for your
  World of Warcraft folder), then runs in the background and starts again whenever you log in to your
  computer. Running a newer installer later updates it and keeps your settings.

In WoW
  Type /gbt companion so the addon offers a one-click reload whenever a request changes.

Setting it up for the first time for your guild
  Make a webhook in Discord (channel settings > Integrations > Webhooks > New Webhook > Copy Webhook
  URL), run the installer, press Enter at the invite code question and paste the webhook URL. Then
  make an invite code for the other officers with:
      python3 guildbanktoons_discord.py --invite
  run in the folder the installer put it in (it prints the path). That also posts a small sync
  message in the channel. Leave it there: it's how every PC knows which messages to edit.

Remove it
  Run the installer with --uninstall (for example: py install.py --uninstall on Windows,
  python3 install.py --uninstall on a Mac or Linux). Messages it already posted stay in Discord.

More: https://github.com/kota150/GuildBankToons#discord
