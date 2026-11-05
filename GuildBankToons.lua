-- Forever - Guild Bank Toons (folder GuildBankToons) - built for WoW: Forever; also loads on Classic Era and retail. Shares the bags, bank and gold of the guild's bank characters
-- over guild addon chat. Every guildmate keeps a copy and passes it on, so the bank stays browsable while
-- the bank character is offline. The SavedVariables file doubles as the export for the Discord companion.
-- Look the addon up by the folder WoW loaded it from: the modern lookup errors on an unknown name.
local addonName=...
local GetMetadata=(C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local VERSION
if GetMetadata and type(addonName)=='string' then
  local ok,value=pcall(GetMetadata,addonName,'Version')
  if ok then VERSION=value end
end
if type(VERSION)~='string' or VERSION:find('@',1,true) then VERSION='dev' end
VERSION=VERSION:gsub('^v','')
-- Helper functions live in one table: WoW's Lua allows at most 200 locals at the top of a file.
local GV={}
-- Other addons (and the tests) can reach the addon's functions here.
GuildBankToons=GV
-- Hidden guild addon-message channel.
local PREFIX='GBTOONS'
-- Officers designate bank characters by adding this tag to the guild info text, e.g. [GBT:Vault Keeper].
local TAG_PATTERN='%[GBT:%s*([^%]]-)%s*%]'
-- Relayed snapshots stamped further ahead of server time than this are treated as forged.
local MAX_FUTURE=600
local frame=CreateFrame('Frame')
local window
local ui={}
local db
-- Outgoing messages: urgent (small control messages, answers someone is waiting for) go before bulk.
local queue, urgent, timers, pending = {}, {}, {}, {}
local lastSent, lastSentAt = {}, {}
-- A bank toon's last broadcast of its own contents, which its next change is sent against.
local lastBroadcast = {}
local function copyTable(t) local c={} for k,v in pairs(t or {}) do c[k]=v end return c end
local sent, received, rejected = 0, 0, 0
local bankOpen, syncReady = false, false
local updatePending, sinceUpdate = false, 0
-- The game allows each addon prefix a burst of 10 messages, then 1 a second.
local allowance, sendFailures = 10, 0

-- WoW: Forever runs on the modern (Midnight-era) API where many Classic globals moved into C_ namespaces.
-- Resolve each once so the same file runs on Classic Era and Forever.
local function isSecret(value) return type(issecretvalue)=='function' and issecretvalue(value) end
local GetItemInfo=GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemIcon=GetItemIcon or (C_Item and C_Item.GetItemIconByID)
local RequestItem=C_Item and C_Item.RequestLoadItemDataByID
local GetNumSlots=(C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetSlotInfo=(C_Container and C_Container.GetContainerItemInfo) or GetContainerItemInfo
local GetGuildText=GetGuildInfoText or (C_GuildInfo and C_GuildInfo.GetGuildInfoText)
local InsertChatLink=(ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink

local function settings() return db and db.settings or {} end
local function log(s,always)
  if not always and settings().quiet then return end
  print('|cffd8aa55Guild Bank Toons:|r '..tostring(s))
end
-- Server time, so stamps from different players' machines compare fairly.
local function now() return (GetServerTime and GetServerTime()) or (time and time()) or 0 end
local cachedPlayer
-- WoW: Forever characters are known by first name and surname. Identity is that name alone: any
-- "-Realm" the server appends to a sender is dropped, and spaces and case don't matter.
local function baseName(name)
  if type(name)~='string' or isSecret(name) then return nil end
  local character=name:match('^([^-]+)') or name
  character=character:gsub('^%s+',''):gsub('%s+$','')
  if character=='' then return nil end
  return character
end
local function nameId(name)
  local character=baseName(name)
  return character and character:gsub('%s',''):lower()
end
local function displayName(name) return baseName(name) or name end
-- UnitName may return only the first name; GV.learnOwnName() records the full name the server puts on
-- our own messages, keyed by UnitName.
local function playerName()
  if cachedPlayer then return cachedPlayer end
  local name=UnitName('player')
  if name and not isSecret(name) then
    cachedPlayer=(db and db.knownAs[name]) or name
  end
  return cachedPlayer
end
local function key() return playerName() or 'Unknown' end
local function myId() return nameId(key()) end
-- Our own guild addon messages echo back with the sender name the server uses for us.
function GV.learnOwnName(sender)
  local character=baseName(sender)
  local base=UnitName('player')
  if not character or character==cachedPlayer or not base or isSecret(base) then return end
  cachedPlayer=character
  db.knownAs[base]=character
end
local function senderMatches(sender,who)
  if isSecret(sender) then return false end
  local id=nameId(sender)
  return id~=nil and id==nameId(who)
end
local function ago(stamp)
  local s=math.max(0,now()-(stamp or 0))
  if s<90 then return 'just now' end
  if s<5400 then return math.floor(s/60+0.5)..'m ago' end
  if s<129600 then return math.floor(s/3600+0.5)..'h ago' end
  return math.floor(s/86400+0.5)..'d ago'
end
local function requestUpdate() updatePending=true end

-- Timers by key: schedule replaces a pending one (debounce), once keeps it (first caller wins), cancel drops it.
function GV.schedule(name,delay,fn) timers[name]={at=GetTime()+delay,fn=fn} end
function GV.once(name,delay,fn) if not timers[name] then GV.schedule(name,delay,fn) end end
function GV.cancel(name) timers[name]=nil end
local function later(seconds,fn)
  if C_Timer and C_Timer.After then C_Timer.After(seconds,fn) else fn() end
end

function GV.initDB()
  GuildBankToonsDB=GuildBankToonsDB or {}
  db=GuildBankToonsDB
  db.schema=1
  db.guilds=db.guilds or {}
  -- Item names and qualities seen by this client, so the Discord export can name items.
  db.items=db.items or {}
  db.knownAs=db.knownAs or {}
  -- UnitName -> {items, stamp}: this account's characters' last bank visit.
  db.ownBank=db.ownBank or {}
  db.ui=db.ui or {}
  db.ui.filter=db.ui.filter or 'all'
  db.ui.reqFilter=db.ui.reqFilter or 'active'
  db.ui.sort=db.ui.sort or 'name'
  db.ui.donFilter=db.ui.donFilter or 'all'
  db.ui.view=db.ui.view or 'grid'
  if db.ui.donFilter=='week' then db.ui.donFilter='all' end
  db.ui.chartDays=db.ui.chartDays or 30
  db.ui.guildSub=db.ui.guildSub or 'toons'
  db.ui.exportKind=db.ui.exportKind or 'inventory'
  db.ui.exportFormat=db.ui.exportFormat or 'csv'
  db.settings=db.settings or {}
  if db.settings.tooltips==nil then db.settings.tooltips=true end
  if db.settings.quiet==nil then db.settings.quiet=false end
  if db.settings.minimap==nil then db.settings.minimap=true end
  -- The Donate panel beside the mail window, for everyone who isn't a bank toon.
  if db.settings.donate==nil then db.settings.donate=true end
  if db.settings.lowStock==nil then db.settings.lowStock=true end
  -- Whisper online officers who don't run the addon when you make a request.
  if db.settings.whispers==nil then db.settings.whispers=true end
  -- Offer a /reload after request changes so the Discord companion on this PC posts them.
  if db.settings.companion==nil then db.settings.companion=false end
  -- On bank characters: show the mail helper at mailboxes, and optionally fill the first approved request.
  if db.settings.mailHelper==nil then db.settings.mailHelper=true end
  if db.settings.autofill==nil then db.settings.autofill=false end
end
local function guildKey()
  if not (IsInGuild and IsInGuild()) or not GetGuildInfo then return nil end
  local name=GetGuildInfo('player')
  if type(name)~='string' or isSecret(name) or name=='' then return nil end
  return name
end
-- banks: id -> snapshot; tagged: bank characters from the guild info text; extra: ones added with /gbt add;
-- managed: ones the guild master set with /gbt bank add (managedBy, managedStamp say who and when);
-- requests: id -> request; officerRank: highest rank index (0 = guild master) that counts as an officer.
function GV.guild()
  local name=db and guildKey()
  if not name then return nil end
  local g=db.guilds[name]
  if not g then g={banks={},tagged={},extra={}}; db.guilds[name]=g end
  g.requests=g.requests or {}
  g.managed=g.managed or {}
  g.donations=g.donations or {}
  return g
end
function GV.isBank(id)
  local g=GV.guild()
  return (g and id and (g.managed[id] or g.tagged[id] or g.extra[id])) and true or false
end
function GV.bankList()
  local g=GV.guild()
  local list,seen={},{}
  if not g then return list end
  for _,source in ipairs({g.managed,g.tagged,g.extra}) do
    for id,name in pairs(source) do
      if not seen[id] then
        seen[id]=true
        list[#list+1]={id=id,name=(g.banks[id] and g.banks[id].owner) or name}
      end
    end
  end
  table.sort(list,function(a,b) return a.name<b.name end)
  return list
end
function GV.readTags()
  local g=GV.guild()
  if not g or not GetGuildText then return end
  local text=GetGuildText()
  -- An empty guild info usually means the roster hasn't loaded yet; keep what we knew.
  if type(text)~='string' or isSecret(text) or text=='' then return end
  local tagged,changed,officers={},false,nil
  for name in text:gmatch(TAG_PATTERN) do
    -- [GBT:officers=2] sets which ranks count as officers (0 is the guild master).
    local rank=name:match('^officers%s*=%s*(%d+)$')
    local id=not rank and nameId(name)
    if rank then officers=tonumber(rank)
    elseif id then tagged[id]=name; if not g.tagged[id] then changed=true end end
  end
  g.officerRank=officers
  for id in pairs(g.tagged) do if not tagged[id] then changed=true end end
  g.tagged=tagged
  if changed then GV.banksChanged() end
end
function GV.banksChanged()
  requestUpdate()
  if syncReady then GV.syncAll() end
end

-- Snapshot ---------------------------------------------------------------------------------------
-- Older clients return several values; newer ones return a table.
function GV.slotItem(bag,slot)
  local a,b,c,_,_,_,link,_,_,id=GetSlotInfo(bag,slot)
  if type(a)=='table' then return a.itemID,a.stackCount,a.isLocked end
  if id then return id,b,c end
  if type(link)=='string' then return tonumber(link:match('item:(%d+)')),b,c end
end
function GV.bagIds()
  local list={}
  for bag=0,(NUM_BAG_SLOTS or 4) do list[#list+1]=bag end
  return list
end
-- Scan both the Classic layout (main bank + bank bags) and modern bank tabs; containers that don't
-- exist on this client report no slots and are skipped.
function GV.bankIds()
  local list,seen={},{}
  local function add(id) if id and not seen[id] then seen[id]=true; list[#list+1]=id end end
  local E=Enum and Enum.BagIndex
  add(E and E.Bank); add(BANK_CONTAINER or -1)
  local first=(NUM_BAG_SLOTS or 4)+1
  for bag=first,first+(NUM_BANKBAGSLOTS or 6)-1 do add(bag) end
  if E then for i=1,6 do add(E['CharacterBankTab_'..i]) end end
  return list
end
function GV.scanContainers(ids)
  local items={}
  if not (GetNumSlots and GetSlotInfo) then return items end
  for _,bag in ipairs(ids) do
    local ok,slots=pcall(GetNumSlots,bag)
    if ok and type(slots)=='number' and not isSecret(slots) then
      for slot=1,slots do
        local id,count=GV.slotItem(bag,slot)
        if id and not isSecret(id) then items[id]=(items[id] or 0)+(tonumber(count) or 1) end
      end
    end
  end
  return items
end
-- Sorted "b:itemID:count" (bags) and "k:itemID:count" (bank) entries; the wire format and the hash input.
function GV.entries(snap)
  local list={}
  for id,count in pairs(snap.bags or {}) do list[#list+1]='b:'..id..':'..count end
  for id,count in pairs(snap.bank or {}) do list[#list+1]='k:'..id..':'..count end
  table.sort(list)
  return list
end
function GV.hash(snap)
  local h=(snap.gold or 0)%16777213
  for _,entry in ipairs(GV.entries(snap)) do
    for i=1,#entry do h=(h*31+entry:byte(i))%16777213 end
    h=(h*31+10)%16777213
  end
  return h
end
-- On a bank character: rebuild its own snapshot. The bank is only readable while it's open, so its
-- contents carry over from the last visit.
function GV.scanSelf()
  -- Keep this character's last bank visit even before we know it's a bank character: the full name
  -- (with surname) only arrives a moment after login, and a quick visit then shouldn't be lost.
  local unit=UnitName('player')
  if isSecret(unit) then unit=nil end
  if bankOpen and unit then db.ownBank[unit]={items=GV.scanContainers(GV.bankIds()),stamp=now()} end
  local g,me=GV.guild(),myId()
  if not g or not GV.isBank(me) then return end
  local old=g.banks[me] or {}
  local visit=unit and db.ownBank[unit]
  local snap={owner=key(),bags=GV.scanContainers(GV.bagIds()),bank=old.bank or {},bankStamp=old.bankStamp or 0,gold=(GetMoney and GetMoney()) or 0}
  if visit and visit.stamp>snap.bankStamp then snap.bank,snap.bankStamp=visit.items,visit.stamp end
  snap.hash=GV.hash(snap)
  if snap.hash==old.hash then
    old.bankStamp=snap.bankStamp
    return
  end
  snap.stamp=math.max(now(),(old.stamp or 0)+1)
  snap.received=snap.stamp
  g.banks[me]=snap
  GV.prime(snap); requestUpdate()
  GV.recordGold(me,snap.stamp,snap.gold)
  -- Wait for sorting or a mail run to settle, then push the new contents to everyone online.
  GV.schedule('push',10,function() GV.pushSnapshot(me) end)
end
-- Item names and qualities, remembered so offline views and the Discord export can show them.
function GV.itemInfo(id)
  local name,link,quality,_,_,_,_,_,_,icon=GetItemInfo(id)
  if name and not isSecret(name) then
    db.items[id]={n=name,q=quality}
    return name,link,quality,icon
  end
  if RequestItem then pcall(RequestItem,id) end
  local cached=db.items[id]
  return cached and cached.n,nil,cached and cached.q,GetItemIcon and GetItemIcon(id)
end
-- Items still loading; GET_ITEM_INFO_RECEIVED caches only these, not every item the client sees.
local loadingItems={}
function GV.prime(snap)
  for _,items in ipairs({snap.bags or {},snap.bank or {}}) do
    for id in pairs(items) do if not GV.itemInfo(id) then loadingItems[id]=true end end
  end
end

-- Messaging --------------------------------------------------------------------------------------
-- Protocol (guild addon channel, '|' separated; origin is the bank character's name):
--   V|me|version                  login probe; our own echo tells us the name others see on our messages
--   R|origin|stamp|hash           "this is the copy I hold of origin"; anyone with a newer one offers it
--   B|origin|stamp|hash|gold|bankStamp|count, then I|origin|stamp|entries..., then E|origin|stamp
-- Anyone holding a snapshot can send it, so it spreads while the bank character is offline. Who sends is
-- settled by offers (O) and one ask (G): see "Asking for the newest copy" below.
-- WoW: Forever blocks outgoing addon messages in some situations, such as combat in instances.
function GV.messagingBlocked()
  local C=C_ChatInfo
  if not C then return false end
  local inInstance=IsInInstance and IsInInstance()
  local inCombat=InCombatLockdown and InCombatLockdown()
  if not inInstance and not inCombat then return false end
  for _,name in ipairs({'AreOutgoingAddonChatMessagesRestricted','InChatMessagingLockdown'}) do
    local check=C[name]
    if check and check()==true then return true end
  end
  return false
end
-- Forever doesn't let trial accounts send addon messages: they can browse what guildmates share, nothing more.
function GV.isTrial()
  for _,check in ipairs({IsTrialAccount,IsVeteranTrialAccount}) do
    if type(check)=='function' and check()==true then return true end
  end
  return false
end
-- onSent runs once the message has actually gone out (it may wait behind others and the game's limit).
function GV.queue(payload,isUrgent,onSent)
  if GV.isTrial() then return end
  local lane=isUrgent and urgent or queue
  if #lane<500 then lane[#lane+1]={payload,onSent} end
end
function GV.queued() return #queue+#urgent end
-- Returns false when the client throttled the message so it's retried.
function GV.rawSend(payload)
  if not (IsInGuild and IsInGuild()) then return true end
  local fn=(C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  if not fn then return true end
  local result=fn(PREFIX,payload,'GUILD')
  if result==false or (type(result)=='number' and result~=0) then return false end
  sent=sent+1
  return true
end
function GV.sendRequest(id)
  local g=GV.guild()
  if not g then return end
  local snap=g.banks[id]
  local origin=(snap and snap.owner) or g.managed[id] or g.tagged[id] or g.extra[id]
  if not origin then return end
  GV.queue('R|'..origin..'|'..(snap and snap.stamp or 0)..'|'..(snap and snap.hash or 0),true)
  -- A bank toon's own copy is the real one, so it only announces it; everyone else collects offers.
  if id~=myId() then GV.collect(origin) end
end
-- asked: someone asked us for it by name (G), so send it straight away even if we sent it recently.
function GV.sendSnapshot(id,asked)
  local g=GV.guild()
  local snap=g and g.banks[id]
  if not snap or not snap.stamp then return end
  -- Guild messages reach everyone, so one broadcast answers every request that arrives meanwhile.
  if not asked and lastSent[id]==snap.stamp and GetTime()-(lastSentAt[id] or 0)<30 then return end
  lastSent[id],lastSentAt[id]=snap.stamp,GetTime()
  local origin,stamp=snap.owner,snap.stamp
  local entries=GV.entries(snap)
  if id==myId() then lastBroadcast[id]={stamp=stamp,bags=copyTable(snap.bags),bank=copyTable(snap.bank)} end
  GV.queue(table.concat({'B',origin,stamp,snap.hash,snap.gold or 0,snap.bankStamp or 0,#entries},'|'),asked)
  GV.queueEntries('I|'..origin..'|'..stamp..'|',entries,asked)
  GV.queue('E|'..origin..'|'..stamp,asked)
end
function GV.queueEntries(head,entries,asked)
  local chunk,length={},#head
  for _,entry in ipairs(entries) do
    if length+#entry+1>250 then
      GV.queue(head..table.concat(chunk,','),asked)
      chunk,length={},#head
    end
    chunk[#chunk+1]=entry; length=length+#entry+1
  end
  if #chunk>0 then GV.queue(head..table.concat(chunk,','),asked) end
end
-- A bank toon's own change: when it's small, send only what changed since its last broadcast.
--   U|origin|stamp|baseStamp|hash|gold|bankStamp|count, then I (count 0 = gone), then E
-- Guildmates holding the base copy apply it; anyone else asks for the whole copy.
function GV.pushSnapshot(id)
  local g=GV.guild()
  local snap,base=g and g.banks[id],lastBroadcast[id]
  if not snap then return end
  if not base or base.stamp>=snap.stamp then GV.sendSnapshot(id); return end
  local changes={}
  local function diff(kind,old,new)
    for item,count in pairs(new or {}) do if old[item]~=count then changes[#changes+1]=kind..':'..item..':'..count end end
    for item in pairs(old) do if not (new or {})[item] then changes[#changes+1]=kind..':'..item..':0' end end
  end
  diff('b',base.bags,snap.bags); diff('k',base.bank,snap.bank)
  if #changes*2>#GV.entries(snap) then GV.sendSnapshot(id); return end
  table.sort(changes)
  lastSent[id],lastSentAt[id]=snap.stamp,GetTime()
  lastBroadcast[id]={stamp=snap.stamp,bags=copyTable(snap.bags),bank=copyTable(snap.bank)}
  local origin,stamp=snap.owner,snap.stamp
  GV.queue(table.concat({'U',origin,stamp,base.stamp,snap.hash,snap.gold or 0,snap.bankStamp or 0,#changes},'|'))
  GV.queueEntries('I|'..origin..'|'..stamp..'|',changes)
  GV.queue('E|'..origin..'|'..stamp)
end
-- Ask for every bank character; a bank character announces its own copy the same way.
function GV.syncAll()
  local me=myId()
  if GV.isBank(me) then GV.scanSelf() end
  for _,bank in ipairs(GV.bankList()) do GV.sendRequest(bank.id) end
end
-- A different copy of our own bank is going around (stale, or forged): re-stamp ours above it.
function GV.outbid(id,stamp)
  local snap=GV.guild().banks[id]
  if not snap then return end
  snap.stamp=math.max(now(),stamp+1)
  lastSent[id]=nil
  GV.once('send:'..id,0.5,function() GV.sendSnapshot(id) end)
end
local function plausible(stamp) return stamp<=now()+MAX_FUTURE end

-- Asking for the newest copy ------------------------------------------------------------------------
-- An ask (R for a bank toon, S for the guild master's list, L for requests and donations) says what we hold.
-- Guildmates holding something newer offer it with one small message (O), each after a short random wait,
-- and stay quiet once 3 others have offered something at least as new (enough to have a backup). After 5 seconds the asker picks the
-- newest offer (the bank toon's own, on a tie) and asks just that guildmate to send it (G). If they haven't
-- started within 2 seconds of the ask going out, it asks whoever has the next newest copy.
--   O|topic|stamp|hash        topic: a bank toon's name, *list (requests and donations) or *gm (bank list)
--   G|topic|stamp|target      "target, send me your copy"; for *list, stamp is what we already hold
local OFFER_WAIT,ANSWER_WAIT,ENOUGH_OFFERS=5,2,3
local offersHeard={} -- topic id -> offers heard at least as new as ours since we planned to offer
local collecting={} -- topic id -> {topic=, offers={}, since=, asked=, at=}
local function topicId(topic) return topic:sub(1,1)=='*' and topic or nameId(topic) end
-- The stamp (and hash) of what we hold on a topic.
function GV.held(id)
  local g=GV.guild()
  if not g then return 0,0 end
  if id=='*list' then return GV.newestStamp(),0 end
  if id=='*gm' then return g.managedStamp or 0,0 end
  if id=='*plan' then return GV.plan().stamp or 0,0 end
  local snap=g.banks[id]
  return snap and snap.stamp or 0,snap and snap.hash or 0
end
function GV.collect(topic,since)
  local id=topicId(topic)
  if not id then return end
  local c=collecting[id]
  if c and GetTime()-c.at<30 then return end
  collecting[id]={topic=topic,offers={},since=since,at=GetTime()}
  GV.schedule('pick:'..id,OFFER_WAIT,function() GV.pickOffer(id) end)
end
function GV.pickOffer(id)
  local c=collecting[id]
  if not c then return end
  local held=c.since or GV.held(id)
  local best,at
  for i,o in ipairs(c.offers) do
    if o.stamp>held and (not best or o.stamp>best.stamp or (o.stamp==best.stamp and o.owner and not best.owner)) then best,at=o,i end
  end
  if not best then
    collecting[id]=nil
    if id=='*list' then GV.finishListening() end
    return
  end
  table.remove(c.offers,at)
  c.asked=best
  GV.queue('G|'..c.topic..'|'..held..'|'..best.name,true,function()
    GV.schedule('answer:'..id,ANSWER_WAIT,function() c.asked=nil; GV.pickOffer(id) end)
  end)
end
-- What we asked for started arriving, from them or anyone else: stop waiting.
function GV.answered(id,senderId,stamp)
  local c=collecting[id]
  if not c or not c.asked then return end
  if senderId==c.asked.from or (stamp and stamp>=c.asked.stamp) then
    GV.cancel('answer:'..id)
    collecting[id]=nil
  end
end
-- Someone asked about a topic and holds `theirs`: offer ours if it's newer. The bank toon offers its own
-- copy first; everyone else waits a moment so one offer usually covers it.
function GV.maybeOffer(topic,theirs)
  local id=topicId(topic)
  if not id or GV.held(id)<=theirs then return end
  if not timers['offer:'..id] then offersHeard[id]=0 end
  GV.once('offer:'..id,(id==myId()) and 0.2 or (0.3+math.random()*2.5),function()
    local stamp,hash=GV.held(id)
    if stamp>theirs and (offersHeard[id] or 0)<ENOUGH_OFFERS then GV.queue('O|'..topic..'|'..stamp..'|'..hash,true) end
  end)
end
function GV.onOfferMessage(action,topic,rest,sender)
  local g,id=GV.guild(),topicId(topic)
  local senderId=(not isSecret(sender) and nameId(sender)) or nil
  if not g or not id or not senderId or senderId==myId() then return end
  if id:sub(1,1)~='*' and not GV.isBank(id) then return end
  if action=='O' then
    local stamp,hash=rest:match('^(%d+)|?(%d*)$')
    stamp,hash=tonumber(stamp),tonumber(hash) or 0
    if not stamp or not plausible(stamp) then return end
    local mine,myHash=GV.held(id)
    if stamp>=mine then offersHeard[id]=(offersHeard[id] or 0)+1 end
    -- A different copy of our own bank is on offer (stale, or forged): ours replaces it.
    if id==myId() then
      if g.banks[id] and stamp>=mine and hash~=myHash then GV.outbid(id,stamp) end
      return
    end
    local c=collecting[id]
    if c and not c.asked then
      c.offers[#c.offers+1]={from=senderId,name=displayName(sender),stamp=stamp,owner=senderMatches(sender,topic)}
    end
  elseif action=='G' then
    local stamp,target=rest:match('^(%d+)|(.+)$')
    if not stamp or nameId(target)~=myId() then return end
    stamp=tonumber(stamp)
    if id=='*list' then
      -- Several guildmates logging in at once: answer for the one who has the least.
      GV.listSince=math.min(GV.listSince or stamp,stamp)
      GV.once('reqlist',0.1,function() local since=GV.listSince; GV.listSince=nil; GV.sendRequestList(since) end)
    elseif id=='*gm' then GV.once('list:send',0.1,function() GV.sendManaged(true) end)
    elseif id=='*plan' then GV.once('plan:send',0.1,function() GV.sendPlan(true) end)
    else GV.once('send:'..id,0.1,function() GV.sendSnapshot(id,true) end) end
  end
end
function GV.onMessage(msg,sender)
  local action,origin,rest=msg:match('^(%u)|([^|]+)|?(.*)$')
  if not action then return end
  if action=='V' then
    if origin==key() and not isSecret(sender) then GV.learnOwnName(sender) end
    return
  end
  if action=='Q' or action=='L' or action=='P' or action=='A' or action=='D' then GV.onRequestMessage(action,origin,rest,sender); return end
  if action=='S' or action=='M' then GV.onListMessage(action,origin,rest,sender); return end
  if action=='O' or action=='G' then GV.onOfferMessage(action,origin,rest,sender); return end
  if action=='C' or action=='K' then GV.onPlanMessage(action,origin,rest,sender); return end
  local g,id=GV.guild(),nameId(origin)
  if not g or not id or not GV.isBank(id) then return end
  local senderId=(not isSecret(sender) and nameId(sender)) or '?'
  if senderId==myId() then return end
  local mine=g.banks[id]
  local myStamp,myHash=mine and mine.stamp or 0,mine and mine.hash or 0
  local iAmOwner=id==myId()
  local fromOwner=senderMatches(sender,origin)
  if action=='R' then
    local stamp,hash=rest:match('^(%d+)|?(%d*)$')
    stamp,hash=tonumber(stamp),tonumber(hash)
    if not stamp then return end
    if iAmOwner then
      -- Never outbid a forged far-future stamp: ours would jump past what everyone else accepts.
      if not mine or not plausible(stamp) then return end
      if stamp>myStamp or (stamp==myStamp and stamp>0 and hash~=myHash) then GV.outbid(id,stamp)
      elseif stamp<myStamp then GV.maybeOffer(origin,stamp) end
    elseif stamp>myStamp then
      -- They hold something newer than us: ask, and they'll offer it.
      if plausible(stamp) then GV.once('ask:'..id,1+math.random()*3,function() GV.sendRequest(id) end) end
    elseif stamp<myStamp then
      GV.maybeOffer(origin,stamp)
    else
      -- Someone holding our copy already asked; whatever answers them reaches us too.
      GV.cancel('ask:'..id)
    end
  elseif action=='B' or action=='U' then
    local stamp,base,hash,gold,bankStamp,count
    if action=='B' then stamp,hash,gold,bankStamp,count=rest:match('^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$')
    else stamp,base,hash,gold,bankStamp,count=rest:match('^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$') end
    stamp,hash=tonumber(stamp),tonumber(hash)
    if not stamp then return end
    if stamp>=myStamp then GV.cancel('send:'..id); GV.cancel('offer:'..id) end
    if stamp>myStamp then GV.cancel('ask:'..id) end
    GV.answered(id,senderId,stamp)
    if iAmOwner then
      if mine and plausible(stamp) and stamp>=myStamp and hash~=myHash then GV.outbid(id,stamp) end
      return
    end
    -- The bank character's own copy always wins; relayed copies must be newer than ours.
    local wanted=stamp>myStamp or (fromOwner and hash~=myHash)
    if not wanted or not plausible(stamp) then return end
    pending[id..'|'..senderId]={stamp=stamp,hash=hash,gold=tonumber(gold),bankStamp=tonumber(bankStamp),count=tonumber(count),
      bags={},bank={},n=0,owner=origin,fromOwner=fromOwner,via=not isSecret(sender) and displayName(sender) or nil,base=tonumber(base)}
  elseif action=='I' then
    local p=pending[id..'|'..senderId]
    local stamp,list=rest:match('^(%d+)|(.*)$')
    if not p or tonumber(stamp)~=p.stamp then return end
    for where,item,count in list:gmatch('([bk]):(%d+):(%d+)') do
      local target=(where=='b') and p.bags or p.bank
      target[tonumber(item)]=tonumber(count)
      p.n=p.n+1
    end
  elseif action=='E' then
    local slot=id..'|'..senderId
    local p=pending[slot]
    if not p or tonumber(rest)~=p.stamp then return end
    pending[slot]=nil
    local bags,bank=p.bags,p.bank
    if p.base then
      local cur=g.banks[id]
      if not cur or cur.stamp~=p.base then
        -- We missed the copy these changes build on: ask for the whole thing.
        GV.once('ask:'..id,1+math.random()*2,function() GV.sendRequest(id) end)
        return
      end
      bags,bank=copyTable(cur.bags),copyTable(cur.bank)
      for item,n in pairs(p.bags) do bags[item]=(n>0) and n or nil end
      for item,n in pairs(p.bank) do bank[item]=(n>0) and n or nil end
    end
    local snap={owner=p.owner,stamp=p.stamp,gold=p.gold,bankStamp=p.bankStamp,bags=bags,bank=bank,
      via=(not p.fromOwner) and p.via or nil,received=now()}
    snap.hash=GV.hash(snap)
    -- A dropped or mangled message leaves the snapshot incomplete; the next sync fetches it again.
    if p.n~=p.count or snap.hash~=p.hash then rejected=rejected+1; return end
    local current=g.banks[id]
    if current and current.stamp>=snap.stamp and not (p.fromOwner and current.hash~=snap.hash) then return end
    g.banks[id]=snap
    received=received+1
    GV.recordGold(id,snap.stamp,snap.gold)
    GV.prime(snap); requestUpdate()
  end
end

-- Requests ---------------------------------------------------------------------------------------
-- A guildmate asks for items from a bank character. An officer, the guild master or the bank character
-- approves or denies it. Approved items are reserved (they come off the available counts) until the bank
-- character mails them, which closes the request. Every client keeps the guild's requests, so people see
-- ones made while they were offline, and the Discord companion can post them.
--   Q|requester|id|updated|status|bank|itemID|count|actor|approvedBy|note   one request (new or changed)
--   L|me              just logged in: one guildmate replies with every request it holds
--   P|me|count        "my next count Q messages are my whole list" (other would-be repliers stand down)
--   A|officer|id      an approver's client saw a new request; the requester whispers only officers who don't ack
local REQUEST_KEEP_ACTIVE=30*86400
local REQUEST_KEEP_CLOSED=7*86400
local STATUSES={open='Waiting for approval',approved='Approved, waiting to be mailed',denied='Denied',mailed='Mailed',cancelled='Cancelled'}
-- Requests only move forward: open -> approved -> mailed, open or approved -> denied, open -> cancelled.
local STAGE={open=0,approved=1,denied=2,mailed=2,cancelled=2}
local roster={} -- nameId -> {name=, rank=, online=}
local acks={} -- request id -> set of officer ids whose client acknowledged it
local listening -- the full list asked for at login: {from=, left=, seen={id=updated}}
local lastReloadPrompt=-1000
local SendChat=(C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
local function clean(value,size) return (tostring(value or ''):gsub('[|\r\n]',' '):sub(1,size)) end
local function isActive(r) return r.status=='open' or r.status=='approved' end
function GV.readRoster()
  if not (GetNumGuildMembers and GetGuildRosterInfo) then return end
  for id in pairs(roster) do roster[id]=nil end
  for i=1,(GetNumGuildMembers() or 0) do
    local name,_,rankIndex,_,_,_,_,_,online=GetGuildRosterInfo(i)
    local id=not isSecret(name) and nameId(name)
    if id then roster[id]={name=name,rank=rankIndex,online=online and true or false} end
  end
  -- A bank list that arrived before the roster could vouch for its sender.
  local d=GV.deferredList
  if d and next(roster) then GV.deferredList=nil; GV.applyManaged(d.gm,d.stamp,d.names) end
  local pd=GV.deferredPlan
  if pd and next(roster) then GV.deferredPlan=nil; GV.applyPlan(pd.by,pd.stamp,pd.text) end
end
-- Officers are ranks 0 (guild master) through officerRank.
function GV.isOfficer(id)
  local g,member=GV.guild(),id and roster[id]
  if not (g and member and type(member.rank)=='number' and not isSecret(member.rank)) then return false end
  return member.rank<=(g.officerRank or 1)
end
-- Officers, the guild master and bank characters approve and deny.
function GV.isApprover(id) return GV.isOfficer(id) or GV.isBank(id) end
-- Whether actor may move request r from status `from` (nil: we haven't seen it before) to `to`.
function GV.allowed(r,from,to,actor)
  if not actor or not STAGE[to] or (from and STAGE[to]<=STAGE[from]) then return false end
  if to=='open' then return from==nil and actor==nameId(r.by) end
  if to=='approved' or to=='denied' then return GV.isApprover(actor) end
  if to=='mailed' then return (from==nil or from=='approved') and actor==nameId(r.bank) end
  if to=='cancelled' then return (from==nil or from=='open') and actor==nameId(r.by) end
  return false
end
function GV.requestPayload(r)
  local payload=table.concat({'Q',r.by,r.id,r.updated,r.status,r.bank,r.item,r.count,r.actor or '',r.approvedBy or '',r.note or ''},'|')
  return payload:sub(1,254)
end
-- Mailed requests are the guild's withdrawals log, so they're kept as long as donations.
local function keepFor(r)
  if isActive(r) then return REQUEST_KEEP_ACTIVE end
  return r.status=='mailed' and 60*86400 or REQUEST_KEEP_CLOSED
end
function GV.pruneRequests()
  local g=GV.guild()
  if not g then return end
  for id,r in pairs(g.requests) do if now()-(r.updated or 0)>keepFor(r) then g.requests[id]=nil end end
end
-- Waiting for approval first, then approved (waiting to be mailed), then recently closed ones.
function GV.requestList()
  local g,list=GV.guild(),{}
  if not g then return list end
  for _,r in pairs(g.requests) do list[#list+1]=r end
  table.sort(list,function(a,b)
    if STAGE[a.status]~=STAGE[b.status] then return STAGE[a.status]<STAGE[b.status] end
    if isActive(a) then return a.id<b.id end
    return a.updated>b.updated
  end)
  return list
end
function GV.activeRequestCount()
  local n=0
  for _,r in ipairs(GV.requestList()) do if isActive(r) then n=n+1 end end
  return n
end
-- itemID -> count approved but not yet mailed from this bank character.
function GV.reserved(bankId)
  local g,out=GV.guild(),{}
  if not g then return out end
  for _,r in pairs(g.requests) do
    if r.status=='approved' and nameId(r.bank)==bankId then out[r.item]=(out[r.item] or 0)+r.count end
  end
  return out
end
function GV.available(bankId,item)
  local g=GV.guild()
  local snap=g and g.banks[bankId]
  if not snap then return 0 end
  if item==0 then return math.max(0,math.floor((snap.gold or 0)/10000)-(GV.reserved(bankId)[0] or 0)) end
  local held=(snap.bags and snap.bags[item] or 0)+(snap.bank and snap.bank[item] or 0)
  return math.max(0,held-(GV.reserved(bankId)[item] or 0))
end
-- Requests for gold use item 0, with the count in whole gold.
function GV.requestLabel(r,plain)
  if r.item==0 then return r.count..'g' end
  local name,link=GV.itemInfo(r.item)
  return r.count..'x '..((not plain and link) or name or ('item #'..r.item))
end
function GV.describe(r,plain)
  return GV.requestLabel(r,plain)..' from '..displayName(r.bank)..((r.note or '')~='' and (' - '..r.note) or '')
end
function GV.requestCreated(r) return tonumber(r.id:match('%-(%d+)%-%d+$')) or r.updated end
-- Items one member asked for in the last day, not counting denied or cancelled requests or gold.
function GV.requestedToday(id)
  local g,n=GV.guild(),0
  if not g then return 0 end
  for _,r in pairs(g.requests) do
    if nameId(r.by)==id and r.item~=0 and r.status~='denied' and r.status~='cancelled' and now()-GV.requestCreated(r)<86400 then n=n+r.count end
  end
  return n
end
-- Officers can let small requests through without waiting: an approver's client online approves them.
-- The bank toon goes first, officers a little later, so usually only one approval goes out.
function GV.autoApprove(r)
  local max=GV.rule('autoMax')
  if max<=0 or r.item==0 or r.count>max or not GV.isApprover(myId()) then return end
  local member=roster[nameId(r.by)]
  if not member or type(member.rank)~='number' or isSecret(member.rank) or member.rank>GV.rule('autoRank') then return end
  local limit=GV.rule('limit')
  if limit>0 and GV.requestedToday(nameId(r.by))>limit then return end
  if GV.available(nameId(r.bank),r.item)<r.count then return end
  GV.once('auto:'..r.id,(nameId(r.bank)==myId()) and 1 or (2+math.random()*3),function()
    local cur=GV.guild().requests[r.id]
    if cur and cur.status=='open' and GV.setRequestStatus(cur,'approved') then
      log('Approved automatically under the guild\'s rules: '..displayName(cur.by)..', '..GV.describe(cur)..'.')
    end
  end)
end
function GV.promptReload()
  if not settings().companion or not StaticPopup_Show or GetTime()-lastReloadPrompt<120 then return end
  if InCombatLockdown and InCombatLockdown() then return end
  lastReloadPrompt=GetTime()
  StaticPopup_Show('GUILDBANKTOONS_RELOAD')
end
function GV.alert(text)
  log(text,true)
  if PlaySound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then pcall(PlaySound,SOUNDKIT.TELL_MESSAGE) end
end
-- Tell the people a change concerns: approvers about new requests, the requester about every decision,
-- and the bank character about what it needs to mail.
function GV.notify(r,isNew,relayed)
  local me=myId()
  local requester,bank=nameId(r.by),nameId(r.bank)
  local who=displayName(r.actor or '?')
  if r.status=='open' then
    if isNew and not relayed and GV.isApprover(me) then
      GV.queue('A|'..key()..'|'..r.id)
      GV.alert('|cffffd100'..displayName(r.by)..'|r requests '..GV.describe(r)..'. Type |cffffd100/gbt requests|r to approve or deny it.')
    end
  elseif r.status=='approved' then
    if requester==me then GV.alert('Your request for '..GV.describe(r)..' was |cff40ff40approved|r by '..who..'. '..displayName(r.bank)..' will mail it.') end
    if bank==me then GV.alert('Approved by '..who..': mail '..GV.describe(r)..' to |cffffd100'..displayName(r.by)..'|r. Open a mailbox to use the mail helper.') end
  elseif requester==me and r.status~='cancelled' then
    GV.alert('Your request for '..GV.describe(r)..' was |cffffd100'..STATUSES[r.status]:lower()..'|r by '..who..'.')
  end
  if not relayed or not isNew then GV.promptReload() end
end
-- Merges one request. Returns true when it changed something.
function GV.acceptRequest(r,relayed)
  local g=GV.guild()
  if not g or not nameId(r.by) or not STAGE[r.status] or not r.item or r.count<1 or not plausible(r.updated) then return false end
  if now()-r.updated>keepFor(r) then return false end
  local mine=g.requests[r.id]
  if mine and mine.updated>=r.updated then return false end
  local from=mine and mine.status
  if from and STAGE[r.status]<=STAGE[from] then return false end
  local actor=(r.status=='open') and nameId(r.by) or nameId(r.actor)
  -- Until the roster loads nobody's rank can be checked, so approvals and denials are taken on trust.
  local trusted=(r.status=='approved' or r.status=='denied') and next(roster)==nil and actor~=nil
  if not trusted and not GV.allowed(r,from,r.status,actor) then rejected=rejected+1; return false end
  g.requests[r.id]=r
  if r.item>0 and not GV.itemInfo(r.item) then loadingItems[r.item]=true end
  requestUpdate()
  GV.notify(r,mine==nil,relayed)
  if mine==nil and r.status=='open' then GV.autoApprove(r) end
  return true
end
function GV.createRequest(item,count,note,bank)
  local g=GV.guild()
  if not g then return end
  if GV.isTrial() then log('Trial accounts can\'t send requests in WoW Forever; ask a guildmate to request it for you.',true); return end
  if item==0 and GV.rule('gold')==0 then log('The guild isn\'t taking gold requests right now.',true); return end
  local limit=GV.rule('limit')
  if limit>0 and item~=0 then
    local used=GV.requestedToday(myId())
    if used+count>limit then
      log('The guild\'s limit is '..limit..' items a day per member, and you\'ve asked for '..used..' in the last 24 hours.',true)
      return
    end
  end
  local r={id=myId()..'-'..now()..'-'..math.random(100,999),by=key(),updated=now(),status='open',
    bank=bank,item=item,count=math.max(1,math.min(9999,count)),note=clean(note,80)}
  g.requests[r.id]=r
  acks[r.id]={}
  GV.queue(GV.requestPayload(r))
  requestUpdate()
  log('Requested '..GV.describe(r)..'.',true)
  -- Give approvers' clients a few seconds to acknowledge before whispering the ones that didn't.
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
  GV.schedule('whisper:'..r.id,6,function() GV.whisperOfficers(r) end)
  GV.promptReload()
end
function GV.whisperOfficers(r)
  GV.readRoster()
  local seen,me,targets,acked=acks[r.id] or {},myId(),{},0
  for id,member in pairs(roster) do
    if member.online and id~=me and GV.isOfficer(id) then
      if seen[id] then acked=acked+1 else targets[#targets+1]=member.name end
    end
  end
  table.sort(targets)
  if #targets==0 then
    if acked==0 then log('No officers are online right now; they\'ll see the request when they log in.',true) end
    return
  end
  if not settings().whispers or not SendChat then return end
  local text='[Guild Bank] '..displayName(r.by)..' requests '..GV.describe(r)
  local told={}
  for i=1,math.min(3,#targets) do
    if pcall(SendChat,text,'WHISPER',nil,targets[i]) then told[#told+1]=displayName(targets[i]) end
  end
  if #told>0 then log('Whispered '..table.concat(told,', ')..' (officers without the addon).',true) end
end
function GV.setRequestStatus(r,status)
  if not GV.allowed(r,r.status,status,myId()) then
    log('You can\'t mark that request '..STATUSES[status]:lower()..'.',true)
    return false
  end
  local copy={}
  for k,v in pairs(r) do copy[k]=v end
  copy.status,copy.actor,copy.updated=status,key(),math.max(now(),r.updated+1)
  if status=='approved' then copy.approvedBy=key() end
  GV.guild().requests[r.id]=copy
  GV.queue(GV.requestPayload(copy))
  requestUpdate()
  GV.notify(copy,false,false)
  return true
end
-- Requests and donations changed after `since`, oldest first; a little slack covers clocks that disagree.
function GV.changedSince(since)
  local list={}
  for _,r in ipairs(GV.requestList()) do if r.updated>since-120 then list[#list+1]={r.updated,GV.requestPayload(r),r.id} end end
  for _,d in ipairs(GV.donationList()) do if d.updated>since-120 then list[#list+1]={d.updated,GV.donationPayload(d),d.id} end end
  table.sort(list,function(a,b) return a[1]<b[1] end)
  return list
end
function GV.newestStamp()
  local newest=0
  for _,r in ipairs(GV.requestList()) do newest=math.max(newest,r.updated or 0) end
  for _,d in ipairs(GV.donationList()) do newest=math.max(newest,d.updated or 0) end
  return newest
end
function GV.sendRequestList(since)
  GV.pruneRequests(); GV.pruneDonations()
  local list=GV.changedSince(since or 0)
  GV.queue('P|'..key()..'|'..#list,true)
  for _,entry in ipairs(list) do GV.queue(entry[2]) end
end
-- After the login reply, send back anything we have that the replier didn't, then say what's waiting.
function GV.finishListening()
  local heard=listening
  listening=nil
  GV.cancel('listen')
  if not heard then return end
  local me=myId()
  local waiting,toMail=0,0
  if heard.from then
    for _,entry in ipairs(GV.changedSince(heard.since)) do
      if (heard.seen[entry[3]] or -1)<entry[1] then GV.queue(entry[2]) end
    end
  end
  for _,r in ipairs(GV.requestList()) do
    if r.status=='open' then waiting=waiting+1 end
    if r.status=='approved' and nameId(r.bank)==me then toMail=toMail+1 end
  end
  if waiting>0 and GV.isApprover(me) then
    GV.alert(waiting..' guild bank request'..(waiting==1 and '' or 's')..' waiting for approval. Type |cffffd100/gbt requests|r to see them.')
  end
  if toMail>0 then GV.alert(toMail..' approved request'..(toMail==1 and '' or 's')..' to mail. Open a mailbox to use the mail helper.') end
end
function GV.syncRequests()
  GV.pruneRequests(); GV.pruneDonations()
  local since=GV.newestStamp()
  listening={seen={},since=since}
  GV.queue('L|'..key()..'|'..since,true)
  GV.collect('*list',since)
  -- A reply that stalls partway still ends, so the login summary shows.
  GV.schedule('listen',120,GV.finishListening)
end
function GV.onRequestMessage(action,origin,rest,sender)
  local senderId=(not isSecret(sender) and nameId(sender)) or '?'
  if senderId==myId() or not GV.guild() then return end
  if action=='L' then
    GV.maybeOffer('*list',tonumber(rest) or 0)
  elseif action=='P' then
    local c=collecting['*list']
    local mine=c and c.asked and c.asked.from==senderId
    GV.answered('*list',senderId)
    if mine and listening and not listening.from then
      listening.from,listening.left=senderId,tonumber(rest) or 0
      if listening.left<=0 then GV.finishListening() end
    end
  elseif action=='A' then
    if acks[rest] and senderMatches(sender,origin) then acks[rest][nameId(origin)]=true end
  elseif action=='Q' then
    local id,updated,status,bank,item,count,actor,approvedBy,note=rest:match('^([^|]+)|(%d+)|(%a+)|([^|]+)|(%d+)|(%d+)|([^|]*)|([^|]*)|?(.*)$')
    if not id then return end
    local r={id=id,by=origin,updated=tonumber(updated),status=status,bank=bank,item=tonumber(item),count=tonumber(count),
      actor=actor~='' and actor or nil,approvedBy=approvedBy~='' and approvedBy or nil,note=note}
    local fromList=listening and listening.from==senderId
    -- Anyone may pass a request on; only the requester's own message counts as brand new (and alerts).
    GV.acceptRequest(r,not senderMatches(sender,origin))
    if fromList then
      listening.seen[id]=r.updated
      listening.left=listening.left-1
      if listening.left<=0 then GV.finishListening() end
    end
  elseif action=='D' then
    local d=GV.parseDonation(origin,rest)
    if not d then return end
    GV.acceptDonation(d)
    if listening and listening.from==senderId then
      listening.seen[d.id]=d.updated
      listening.left=listening.left-1
      if listening.left<=0 then GV.finishListening() end
    end
  end
end
if StaticPopupDialogs then
  StaticPopupDialogs.GUILDBANKTOONS_WANT={
    text='How many %s does the guild want? (0 removes it from the list)',
    button1=OKAY or 'OK',button2=CANCEL or 'Cancel',hasEditBox=true,timeout=0,whileDead=true,hideOnEscape=true,
    OnShow=function(self,data)
      local box=self.editBox or self.EditBox
      if box then box:SetText(tostring((data and data.want) or '')); box:HighlightText() end
    end,
    OnAccept=function(self,data)
      local box=self.editBox or self.EditBox
      GV.setWant(data.item,tonumber(box and box:GetText() or '') or 0)
    end,
  }
  StaticPopupDialogs.GUILDBANKTOONS_CLEAR={
    text='Remove every bank toon you set for the guild?',
    button1=YES or 'Yes',button2=NO or 'No',timeout=0,whileDead=true,hideOnEscape=true,
    OnAccept=function() GV.gmChange('clear') end,
  }
  StaticPopupDialogs.GUILDBANKTOONS_RELOAD={
    text='Guild bank requests changed. Reload now so the Discord companion on this PC posts them?',
    button1='Reload',button2='Later',timeout=0,whileDead=true,hideOnEscape=true,
    OnAccept=function() if ReloadUI then ReloadUI() end end,
  }
end

-- Bank characters set by the guild master ------------------------------------------------------------
-- The guild master runs /gbt bank add Name. The list goes to the whole guild and is relayed like the bank
-- contents, so guildmates who log in while the guild master is offline still get it.
--   S|me|stamp                          "this is the bank list I hold; send yours if it's newer"
--   M|gm|stamp|part|total|name,name...  the guild master's whole list, split over `total` messages
local MAX_MANAGED=20
local managedSync={parts={},sentStamp=nil,sentAt=0}
function GV.isGM(id)
  local member=id and roster[id]
  return (member and type(member.rank)=='number' and not isSecret(member.rank) and member.rank==0) and true or false
end
function GV.managedNames(g)
  local names={}
  for _,name in pairs(g.managed) do names[#names+1]=name end
  table.sort(names,function(a,b) return nameId(a)<nameId(b) end)
  return names
end
local function listKey(set)
  local ids={}
  for id in pairs(set) do ids[#ids+1]=id end
  table.sort(ids)
  return table.concat(ids,',')
end
function GV.askManaged()
  local g=GV.guild()
  if not g then return end
  GV.queue('S|'..key()..'|'..(g.managedStamp or 0),true)
  GV.collect('*gm')
end
function GV.sendManaged(asked)
  local g=GV.guild()
  if not g or not g.managedStamp or not g.managedBy then return end
  if not asked and managedSync.sentStamp==g.managedStamp and GetTime()-managedSync.sentAt<30 then return end
  managedSync.sentStamp,managedSync.sentAt=g.managedStamp,GetTime()
  local chunks,chunk,length={},{},0
  for _,name in ipairs(GV.managedNames(g)) do
    if length+#name+1>200 then chunks[#chunks+1]=table.concat(chunk,','); chunk,length={},0 end
    chunk[#chunk+1]=name; length=length+#name+1
  end
  chunks[#chunks+1]=table.concat(chunk,',')
  local head='M|'..g.managedBy..'|'..g.managedStamp..'|'
  for i,text in ipairs(chunks) do GV.queue(head..i..'|'..#chunks..'|'..text,asked) end
end
-- On the guild master's client: replace the list and send it to everyone.
function GV.setManaged(set)
  local g=GV.guild()
  g.managed,g.managedBy,g.managedStamp=set,key(),math.max(now(),(g.managedStamp or 0)+1)
  managedSync.sentStamp=nil
  GV.sendManaged()
  GV.banksChanged()
end
function GV.applyManaged(gm,stamp,names)
  local g=GV.guild()
  if not g then return end
  local set={}
  for name in names:gmatch('[^,]+') do
    local id=nameId(name)
    if id then set[id]=baseName(name) end
  end
  local mine=g.managedStamp or 0
  if nameId(gm)==myId() and g.managedStamp then
    -- We're the guild master and hold the real list: re-stamp it above a different copy going around.
    if plausible(stamp) and stamp>=mine and listKey(set)~=listKey(g.managed) then
      g.managedStamp=stamp+1; managedSync.sentStamp=nil
      GV.once('list:send',0.5,GV.sendManaged)
    end
    return
  end
  if stamp<=mine or not plausible(stamp) then return end
  -- Only the guild master's list counts; wait for the roster before deciding.
  if next(roster)==nil then GV.deferredList={gm=gm,stamp=stamp,names=names}; return end
  if not GV.isGM(nameId(gm)) then rejected=rejected+1; return end
  g.managed,g.managedBy,g.managedStamp=set,displayName(gm),stamp
  GV.banksChanged()
end
function GV.onListMessage(action,origin,rest,sender)
  local g=GV.guild()
  local senderId=(not isSecret(sender) and nameId(sender)) or '?'
  if not g or senderId==myId() then return end
  local mine=g.managedStamp or 0
  if action=='S' then
    local stamp=tonumber(rest)
    if not stamp then return end
    if stamp<mine then GV.maybeOffer('*gm',stamp)
    elseif stamp>mine then if plausible(stamp) then GV.once('list:ask',1+math.random()*3,GV.askManaged) end
    else GV.cancel('list:ask') end
    return
  end
  local stamp,part,total,names=rest:match('^(%d+)|(%d+)|(%d+)|(.*)$')
  stamp,part,total=tonumber(stamp),tonumber(part),tonumber(total)
  if not stamp or part<1 or total<1 or total>10 or part>total then return end
  if stamp>=mine then GV.cancel('list:send'); GV.cancel('offer:*gm') end
  if stamp>mine then GV.cancel('list:ask') end
  GV.answered('*gm',senderId,stamp)
  local slot=stamp..'|'..(nameId(origin) or '?')..'|'..senderId
  local p=managedSync.parts[slot] or {total=total,names={},got=0}
  managedSync.parts[slot]=p
  if p.total~=total or p.names[part] then return end
  p.names[part]=names; p.got=p.got+1
  if p.got<total then return end
  managedSync.parts[slot]=nil
  GV.applyManaged(origin,stamp,table.concat(p.names,','))
end
-- /gbt bank add|remove|clear|list
function GV.bankCommand(arg)
  local g=GV.guild()
  if not g then log('You must be in a guild.',true); return end
  local verb,name=arg:match('^(%S*)%s*(.-)$')
  verb=(verb or ''):lower()
  if verb=='' or verb=='list' then
    local names=GV.managedNames(g)
    if #names==0 then log('The guild master hasn\'t set any bank characters with /gbt bank add.',true)
    else log('Bank characters set by '..displayName(g.managedBy or '?')..' ('..ago(g.managedStamp)..'): '..table.concat(names,', '),true) end
    return
  end
  if verb~='add' and verb~='remove' and verb~='clear' then
    log('Usage: /gbt bank add First Last, /gbt bank remove First Last, /gbt bank clear, /gbt bank list.',true); return
  end
  GV.gmChange(verb,name)
end
-- Adds, removes or clears the guild's bank toons; guild master only. Returns true when the list changed.
function GV.gmChange(verb,name)
  local g=GV.guild()
  if not g then log('You must be in a guild.',true); return false end
  name=name or ''
  GV.readRoster()
  if next(roster)==nil then
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    log('The guild roster hasn\'t loaded yet; try again in a moment.',true); return false
  end
  if not GV.isGM(myId()) then
    log('Only the guild master can set the guild\'s bank characters. You can follow one just for yourself in Settings.',true); return false
  end
  local set,count={},0
  for id,n in pairs(g.managed) do set[id]=n; count=count+1 end
  local id=nameId(name)
  if verb=='clear' then
    set={}
    log('Cleared the guild\'s bank characters.',true)
  elseif not id or name:find('[|,]') then
    log('Enter the bank toon\'s full name, First Last.',true); return false
  elseif verb=='add' then
    if set[id] then log(displayName(name)..' is already a bank character.',true); return false end
    if count>=MAX_MANAGED then log('That\'s the limit of '..MAX_MANAGED..' bank characters.',true); return false end
    set[id]=baseName(name)
    log('Added '..baseName(name)..' as a guild bank character. Log in on it with the addon and visit the banker once.',true)
  else
    if not set[id] then log(displayName(name)..' isn\'t one of the guild\'s bank characters.',true); return false end
    set[id]=nil
    log('Removed '..displayName(name)..' from the guild\'s bank characters.',true)
  end
  GV.setManaged(set)
  return true
end

-- Guild plan: gold goals, wanted items and request rules -----------------------------------------------
-- Officers and the guild master set these on the Guild tab. Like the bank list, the newest version goes to
-- the whole guild and is passed along while whoever changed it is offline.
--   C|me|stamp                        "this is the plan I hold"; anyone with a newer one offers it
--   K|officer|stamp|part|total|data   the whole plan as ;-separated entries, split over `total` messages:
--     g~id~toon~copper~name (toon: a bank toon's id, or * for all of them)   w~itemID~target   r~rule~number
local RULE_DEFAULTS={limit=0,autoMax=0,autoRank=0,gold=1}
local planParts={}
function GV.plan()
  local g=GV.guild()
  if not g then return {goals={},wants={},rules={}} end
  g.plan=g.plan or {goals={},wants={},rules={}}
  return g.plan
end
function GV.rule(name)
  local value=GV.plan().rules[name]
  if value==nil then return RULE_DEFAULTS[name] end
  return value
end
local function planClean(text) return (tostring(text or ''):gsub('[;~|\r\n]',' '):sub(1,40)) end
function GV.encodePlan(p)
  local entries={}
  for id,goal in pairs(p.goals) do entries[#entries+1]=table.concat({'g',id,goal.toon or '*',goal.target,planClean(goal.name)},'~') end
  for item,target in pairs(p.wants) do entries[#entries+1]='w~'..item..'~'..target end
  for name,value in pairs(p.rules) do entries[#entries+1]='r~'..name..'~'..value end
  table.sort(entries)
  return entries
end
function GV.decodePlan(text)
  local p={goals={},wants={},rules={}}
  for entry in text:gmatch('[^;]+') do
    local kind,a,b,c,d=entry:match('^(%a)~([^~]*)~?([^~]*)~?([^~]*)~?(.*)$')
    if kind=='g' and a~='' and tonumber(c) then p.goals[a]={toon=b~='' and b or '*',target=tonumber(c),name=d}
    elseif kind=='w' and tonumber(a) and tonumber(b) then p.wants[tonumber(a)]=tonumber(b)
    elseif kind=='r' and RULE_DEFAULTS[a]~=nil and tonumber(b) then p.rules[a]=tonumber(b) end
  end
  return p
end
function GV.copyPlan()
  local p,copy=GV.plan(),{goals={},wants={},rules={}}
  for id,goal in pairs(p.goals) do copy.goals[id]={toon=goal.toon,target=goal.target,name=goal.name} end
  for item,target in pairs(p.wants) do copy.wants[item]=target end
  for name,value in pairs(p.rules) do copy.rules[name]=value end
  return copy
end
function GV.sendPlan(asked)
  local p=GV.plan()
  if not p.stamp or not p.by then return end
  if not asked and planParts.sentStamp==p.stamp and GetTime()-(planParts.sentAt or 0)<30 then return end
  planParts.sentStamp,planParts.sentAt=p.stamp,GetTime()
  local chunks,chunk,length={},{},0
  for _,entry in ipairs(GV.encodePlan(p)) do
    if length+#entry+1>200 and #chunk>0 then chunks[#chunks+1]=table.concat(chunk,';'); chunk,length={},0 end
    chunk[#chunk+1]=entry; length=length+#entry+1
  end
  chunks[#chunks+1]=table.concat(chunk,';')
  local head='K|'..p.by..'|'..p.stamp..'|'
  for i,text in ipairs(chunks) do GV.queue(head..i..'|'..#chunks..'|'..text,asked) end
end
function GV.askPlan()
  if not GV.guild() then return end
  GV.queue('C|'..key()..'|'..(GV.plan().stamp or 0),true)
  GV.collect('*plan')
end
-- On an officer's client: save a changed plan (from GV.copyPlan) and send it to everyone.
function GV.setPlan(p)
  GV.readRoster()
  if not GV.isOfficer(myId()) then log('Only officers and the guild master can change goals, needs and rules.',true); return false end
  p.by,p.stamp=key(),math.max(now(),(GV.plan().stamp or 0)+1)
  GV.guild().plan=p
  planParts.sentStamp=nil
  GV.sendPlan(); requestUpdate()
  return true
end
function GV.applyPlan(by,stamp,text)
  local g=GV.guild()
  if not g then return end
  local p,mine=GV.decodePlan(text),GV.plan()
  if nameId(by)==myId() and mine.stamp and mine.by and nameId(mine.by)==myId() then
    -- We made the newest plan: re-stamp ours above a different copy going around.
    if plausible(stamp) and stamp>=mine.stamp and table.concat(GV.encodePlan(p),';')~=table.concat(GV.encodePlan(mine),';') then
      mine.stamp=stamp+1; planParts.sentStamp=nil
      GV.once('plan:send',0.5,GV.sendPlan)
    end
    return
  end
  if stamp<=(mine.stamp or 0) or not plausible(stamp) then return end
  -- Only an officer's plan counts; wait for the roster before deciding.
  if next(roster)==nil then GV.deferredPlan={by=by,stamp=stamp,text=text}; return end
  if not GV.isOfficer(nameId(by)) then rejected=rejected+1; return end
  p.by,p.stamp=displayName(by),stamp
  g.plan=p
  requestUpdate()
end
function GV.onPlanMessage(action,origin,rest,sender)
  local senderId=(not isSecret(sender) and nameId(sender)) or '?'
  if senderId==myId() or not GV.guild() then return end
  local mine=GV.plan().stamp or 0
  if action=='C' then
    local stamp=tonumber(rest)
    if not stamp then return end
    if stamp<mine then GV.maybeOffer('*plan',stamp)
    elseif stamp>mine and plausible(stamp) then GV.once('plan:ask',1+math.random()*3,GV.askPlan) end
    return
  end
  local stamp,part,total,text=rest:match('^(%d+)|(%d+)|(%d+)|(.*)$')
  stamp,part,total=tonumber(stamp),tonumber(part),tonumber(total)
  if not stamp or part<1 or total<1 or total>20 or part>total then return end
  if stamp>=mine then GV.cancel('plan:send'); GV.cancel('offer:*plan') end
  if stamp>mine then GV.cancel('plan:ask') end
  GV.answered('*plan',senderId,stamp)
  local slot=stamp..'|'..(nameId(origin) or '?')..'|'..senderId
  local p=planParts[slot] or {total=total,texts={},got=0}
  planParts[slot]=p
  if p.total~=total or p.texts[part] then return end
  p.texts[part]=text; p.got=p.got+1
  if p.got<total then return end
  planParts[slot]=nil
  GV.applyPlan(origin,stamp,table.concat(p.texts,';'))
end
-- How many of an item are available across all bank toons, and how many the guild still needs.
function GV.stockOf(item)
  local n=0
  for _,bank in ipairs(GV.bankList()) do n=n+GV.available(bank.id,item) end
  return n
end
function GV.shortfall(item)
  local target=GV.plan().wants[item]
  if not target then return 0 end
  return math.max(0,target-GV.stockOf(item))
end
-- Officers hear when a wanted item drops below what the guild wants. Only drops after the first look this
-- session count, so logging in doesn't list everything that's already short.
local shortSeen
function GV.checkStock()
  if not syncReady or not GV.guild() then return end
  local first=shortSeen==nil
  shortSeen=shortSeen or {}
  local tell=not first and settings().lowStock and GV.isOfficer(myId())
  for item,target in pairs(GV.plan().wants) do
    local have=GV.stockOf(item)
    if have<target then
      if tell and not shortSeen[item] then
        local name,link=GV.itemInfo(item)
        GV.alert('Low stock: '..(link or name or ('item #'..item))..' is down to '..have..' (the guild wants '..target..').')
      end
      shortSeen[item]=true
    else
      shortSeen[item]=nil
    end
  end
end

-- Gold over time --------------------------------------------------------------------------------------
-- Each client notes a bank toon's gold whenever a new copy arrives, so the Goals tab can chart it.
--   g.gold[bankId] = { {stamp, copper}, ... } oldest first
local GOLD_KEEP=90*86400
function GV.recordGold(id,stamp,gold)
  local g=GV.guild()
  if not g or not id or not stamp or not gold then return end
  g.gold=g.gold or {}
  local list=g.gold[id] or {}
  g.gold[id]=list
  local last=list[#list]
  if last and stamp<=last[1] then return end
  if last and last[2]==gold and stamp-last[1]<6*3600 then return end
  list[#list+1]={stamp,gold}
  while #list>400 or (#list>1 and now()-list[1][1]>GOLD_KEEP) do table.remove(list,1) end
end
-- A bank toon's gold at time t, as last seen then (nil if we hadn't seen it yet).
function GV.goldAt(id,t)
  local list=GV.guild() and GV.guild().gold and GV.guild().gold[id]
  if not list then return nil end
  for i=#list,1,-1 do if list[i][1]<=t then return list[i][2] end end
  return nil
end
-- Gold now: one bank toon's, or all of them for toon '*'.
function GV.currentGold(toon)
  local g,total=GV.guild(),0
  if not g then return 0 end
  for _,bank in ipairs(GV.bankList()) do
    if toon=='*' or toon==nil or toon==bank.id then total=total+((g.banks[bank.id] and g.banks[bank.id].gold) or 0) end
  end
  return total
end
-- End-of-day gold for the last `days` days, oldest first; false where nothing was known yet.
function GV.goldSeries(days,toon)
  local ids={}
  for _,bank in ipairs(GV.bankList()) do if toon=='*' or toon==nil or toon==bank.id then ids[#ids+1]=bank.id end end
  local stamp=now()
  local dayEnd=stamp
  if date and time then
    local t=date('*t',stamp)
    t.hour,t.min,t.sec=23,59,59
    dayEnd=time(t)
  end
  local out={}
  for d=days-1,0,-1 do
    local at=math.min(stamp,dayEnd-d*86400)
    local total,known=0,false
    for _,id in ipairs(ids) do
      local v=GV.goldAt(id,at)
      if v then total=total+v; known=true end
    end
    out[#out+1]=known and total or false
  end
  return out
end

-- Mail helper --------------------------------------------------------------------------------------
-- On a bank character at a mailbox: a panel beside the mail window lists approved requests to mail.
-- Fill opens Send Mail, addresses it and attaches the items from your bags (splitting a stack when the
-- count needs it). Sending it, with the panel's Send button or the game's, marks the request mailed.
-- The game only sends mail on a click, so the last step is always yours.
local PickupItem=(C_Container and C_Container.PickupContainerItem) or PickupContainerItem
local SplitItem=(C_Container and C_Container.SplitContainerItem) or SplitContainerItem
local mailFilled -- {id=, name=}: the request the Send Mail form was filled for
local lastMailTo -- recipient of the last SendMail call
function GV.toMail()
  local me,list=myId(),{}
  for _,r in ipairs(GV.requestList()) do if r.status=='approved' and nameId(r.bank)==me then list[#list+1]=r end end
  return list
end
local function mailBodyBox()
  if SendMailBodyEditBox then return SendMailBodyEditBox end
  if MailEditBox and MailEditBox.GetEditBox then return MailEditBox:GetEditBox() end
end
-- Attaches exactly `count` of item from the bags: whole stacks first, then one split for the rest.
function GV.attachItems(item,count)
  if not (PickupItem and ClickSendMailItemButton) then return false,'This client can\'t attach mail items from an addon.' end
  if ClearCursor then ClearCursor() end
  local stacks,have={},0
  for _,bag in ipairs(GV.bagIds()) do
    local ok,slots=pcall(GetNumSlots,bag)
    if ok and type(slots)=='number' and not isSecret(slots) then
      for slot=1,slots do
        local id,stack,locked=GV.slotItem(bag,slot)
        if id==item and not locked then stacks[#stacks+1]={bag=bag,slot=slot,count=stack or 1}; have=have+(stack or 1) end
      end
    end
  end
  if have<count then return false,'Only '..have..' in your bags. Take the rest out of the bank first.' end
  table.sort(stacks,function(a,b) return a.count>b.count end)
  local maxSlots,used=ATTACHMENTS_MAX_SEND or 12,0
  local function nextSlot()
    while used<maxSlots do
      used=used+1
      if not (GetSendMailItem and GetSendMailItem(used)) then return used end
    end
  end
  local left,partial=count,nil
  for _,s in ipairs(stacks) do
    if left==0 then break end
    if s.count<=left then
      local slotIndex=nextSlot()
      if not slotIndex then return false,'Out of attachment slots; send this mail and fill again for the rest.' end
      PickupItem(s.bag,s.slot); ClickSendMailItemButton(slotIndex)
      left=left-s.count
    elseif not partial then
      partial=s
    end
  end
  if left>0 then
    local slotIndex=nextSlot()
    if not slotIndex or not SplitItem then return false,'Couldn\'t split a stack; attach the last '..left..' by hand.' end
    SplitItem(partial.bag,partial.slot,left); ClickSendMailItemButton(slotIndex)
  end
  return true
end
function GV.fillMail(r)
  if not (MailFrame and MailFrame:IsShown()) then log('Open a mailbox first.',true); return end
  if r.status~='approved' or nameId(r.bank)~=myId() then log('Only approved requests for this bank character can be mailed here.',true); return end
  if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick,nil,2) elseif MailFrameTab2 then MailFrameTab2:Click() end
  local name=displayName(r.by)
  if SendMailNameEditBox then SendMailNameEditBox:SetText(name) end
  if SendMailSubjectEditBox then
    SendMailSubjectEditBox:SetText(('Guild bank: '..GV.requestLabel(r,true)):sub(1,64))
  end
  local body=mailBodyBox()
  if body then body:SetText('Approved by '..displayName(r.approvedBy or r.actor or '?')..'.'..((r.note or '')~='' and (' Your note: '..r.note) or '')) end
  local ok,err
  if r.item==0 then
    local copper=r.count*10000
    if ((GetMoney and GetMoney()) or 0)<copper then ok,err=false,'This toon doesn\'t have '..r.count..'g.'
    else
      if MoneyInputFrame_SetCopper and SendMailMoney then MoneyInputFrame_SetCopper(SendMailMoney,copper)
      elseif SetSendMailMoney then SetSendMailMoney(copper) end
      ok=true
    end
  else
    ok,err=GV.attachItems(r.item,r.count)
  end
  mailFilled={id=r.id,name=name}
  if ok then log('Mail to '..name..' is ready. Check it, then press Send.',true) else log(err,true) end
  requestUpdate()
end
function GV.sendFilled()
  if not mailFilled then log('Press Fill on a request first.',true); return end
  if SendMailMailButton and SendMailMailButton.Click then SendMailMailButton:Click()
  elseif SendMail then
    local subject=SendMailSubjectEditBox and SendMailSubjectEditBox:GetText() or 'Guild bank'
    local body=mailBodyBox()
    SendMail(mailFilled.name,subject,body and body:GetText() or '')
  end
end
-- MAIL_SEND_SUCCESS: if the mail went to the person we filled it for, that request is mailed.
function GV.mailSent()
  GV.donationSent()
  local filled=mailFilled
  mailFilled=nil
  if not filled or not lastMailTo or nameId(lastMailTo)~=nameId(filled.name) then return end
  local g=GV.guild()
  local r=g and g.requests[filled.id]
  if r and r.status=='approved' and GV.setRequestStatus(r,'mailed') then log('Marked '..GV.describe(r)..' as mailed.',true) end
end
function GV.hookMail()
  if hooksecurefunc and SendMail then hooksecurefunc('SendMail',function(to) lastMailTo=to; GV.captureSend() end) end
end
function GV.buildMailHelper()
  if ui.mail or not MailFrame then return end
  local f=CreateFrame('Frame','GuildBankToonsMailHelper',MailFrame,'BasicFrameTemplateWithInset')
  f:SetSize(320,260); f:SetPoint('TOPLEFT',MailFrame,'TOPRIGHT',4,0)
  local title=f.TitleText or f:CreateFontString(nil,'OVERLAY','GameFontHighlight')
  if not f.TitleText then title:SetPoint('TOP',0,-6) end
  title:SetText('Guild bank: approved to mail')
  f.rows={}
  for i=1,7 do
    local row=CreateFrame('Frame',nil,f)
    row:SetSize(300,30); row:SetPoint('TOPLEFT',10,-30-(i-1)*31)
    row.text=row:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
    row.text:SetPoint('LEFT',0,0); row.text:SetWidth(186); row.text:SetJustifyH('LEFT')
    row.fill=CreateFrame('Button',nil,row,'UIPanelButtonTemplate'); row.fill:SetSize(54,20); row.fill:SetPoint('RIGHT',-58,0); row.fill:SetText('Fill')
    row.send=CreateFrame('Button',nil,row,'UIPanelButtonTemplate'); row.send:SetSize(54,20); row.send:SetPoint('RIGHT',0,0); row.send:SetText('Send')
    row.fill:SetScript('OnClick',function() GV.fillMail(row.request) end)
    row.send:SetScript('OnClick',function()
      if not (mailFilled and mailFilled.id==row.request.id) then GV.fillMail(row.request); log('Check the mail, then press Send again.',true); return end
      GV.sendFilled()
    end)
    f.rows[i]=row
  end
  f.empty=f:CreateFontString(nil,'OVERLAY','GameFontDisable')
  f.empty:SetPoint('TOPLEFT',14,-36); f.empty:SetWidth(290); f.empty:SetJustifyH('LEFT')
  f.empty:SetText('No approved requests to mail.')
  ui.mail=f
end
function GV.refreshMailHelper()
  local f=ui.mail
  if not f or not f:IsShown() then return end
  local list=GV.toMail()
  for i,row in ipairs(f.rows) do
    local r=list[i]
    row:SetShown(r~=nil)
    if r then
      row.request=r
      local name=GV.requestLabel(r,true):gsub('^%d+x ','')
      local marker=(mailFilled and mailFilled.id==r.id) and '|cff40ff40> |r' or ''
      row.text:SetText(marker..(r.item==0 and r.count..'g' or r.count..'x '..name)..'\n|cff909090to '..displayName(r.by)..((r.note or '')~='' and (' - '..r.note) or '')..'|r')
    end
  end
  f.empty:SetShown(#list==0)
end
-- Bank toons get the mail helper and log donations waiting in the mailbox; everyone else gets the Donate panel.
function GV.mailOpened()
  if not GV.isBank(myId()) then
    if not settings().donate or #GV.bankList()==0 then return end
    GV.buildDonatePanel()
    if ui.donate then ui.donate:Show(); GV.refreshDonatePanel() end
    return
  end
  GV.schedule('inbox',1,GV.scanInbox)
  if not settings().mailHelper then return end
  GV.buildMailHelper()
  if not ui.mail then return end
  ui.mail:Show(); GV.refreshMailHelper()
  local list=GV.toMail()
  if #list>0 and settings().autofill then later(0.3,function() GV.fillMail(list[1]) end) end
end

-- Donations ---------------------------------------------------------------------------------------
-- Guildmates donate by mail. The Donate panel at a mailbox addresses the mail to a bank toon with a
-- reference in the subject. Once it's sent the donor's client logs it as on its way, and when the bank toon
-- opens its mailbox it confirms it as received. Mail a bank toon gets from a guildmate without the addon is
-- logged as well. Everyone keeps the log, and it syncs at login along with the requests.
--   D|donor|id|updated|status|bank|copper|created|itemID:count,...|actor|note
local DONATION_KEEP=60*86400
local DONATION_SUBJECT='Guild bank donation'
local donating -- {ref=, bank=, note=}: the donation the Send Mail form was filled for
local sentMail -- {items=, money=}: what the Send Mail form held when it was sent
function GV.donationPayload(d)
  local items={}
  for id,count in pairs(d.items or {}) do items[#items+1]=id..':'..count end
  table.sort(items)
  local function build(note)
    return table.concat({'D',d.by,d.id,d.updated,d.status,d.bank,d.money or 0,d.created,table.concat(items,','),d.actor or '',note},'|')
  end
  -- The note gives way first, then the last attachments, so the message fits.
  while #build('')>254 and #items>0 do items[#items]=nil end
  return build(d.note or ''):sub(1,254)
end
function GV.donationList()
  local g,list=GV.guild(),{}
  if not g then return list end
  for _,d in pairs(g.donations) do list[#list+1]=d end
  table.sort(list,function(a,b) if a.created~=b.created then return a.created>b.created end return a.id<b.id end)
  return list
end
function GV.pruneDonations()
  local g=GV.guild()
  if not g then return end
  for id,d in pairs(g.donations) do if now()-(d.updated or 0)>DONATION_KEEP then g.donations[id]=nil end end
end
-- "20x Linen Cloth, 5x Copper Ore, 2g": biggest stacks first, `max` items then "N more".
function GV.describeDonation(d,max)
  local ids,parts={},{}
  for id in pairs(d.items or {}) do ids[#ids+1]=id end
  table.sort(ids,function(a,b) if d.items[a]~=d.items[b] then return d.items[a]>d.items[b] end return a<b end)
  for i,id in ipairs(ids) do
    if max and i>max then parts[#parts+1]=(#ids-max)..' more'; break end
    parts[#parts+1]=d.items[id]..'x '..(GV.itemInfo(id) or ('item #'..id))
  end
  if (d.money or 0)>0 then parts[#parts+1]=GV.money(d.money) end
  return #parts>0 and table.concat(parts,', ') or 'nothing'
end
-- Merges one log entry. Returns true when it changed something.
function GV.acceptDonation(d)
  local g=GV.guild()
  if not g or not nameId(d.by) or not nameId(d.bank) or (d.status~='sent' and d.status~='received' and d.status~='moved') then return false end
  if not plausible(d.updated) or now()-d.updated>DONATION_KEEP then return false end
  local mine=g.donations[d.id]
  if mine and (mine.updated>=d.updated or mine.status~='sent') then return false end
  -- Only the donor says it's on its way; only the bank toon it went to says it arrived.
  local actor=nameId(d.actor or d.by)
  -- A move between bank toons is logged by the toon that received it.
  local ok=(d.status=='sent' and actor==nameId(d.by)) or (d.status=='received' and actor==nameId(d.bank) and GV.isBank(actor))
    or (d.status=='moved' and actor==nameId(d.bank) and GV.isBank(actor) and GV.isBank(nameId(d.by)))
  if not ok then rejected=rejected+1; return false end
  g.donations[d.id]=d
  for id in pairs(d.items) do if not GV.itemInfo(id) then loadingItems[id]=true end end
  requestUpdate()
  if d.status=='received' and nameId(d.by)==myId() and not (mine and mine.status=='received') then
    GV.alert(displayName(d.bank)..' received your donation of '..GV.describeDonation(d,4)..'. Thank you!')
  end
  return true
end
function GV.parseDonation(origin,rest)
  local id,updated,status,bank,money,created,items,actor,note=rest:match('^([^|]+)|(%d+)|(%a+)|([^|]+)|(%d+)|(%d+)|([^|]*)|([^|]*)|?(.*)$')
  if not id then return nil end
  local d={id=id,by=origin,updated=tonumber(updated),status=status,bank=bank,money=tonumber(money),created=tonumber(created),
    items={},actor=actor~='' and actor or nil,note=note}
  for item,count in items:gmatch('(%d+):(%d+)') do d.items[tonumber(item)]=tonumber(count) end
  return d
end
local function newRef()
  local chars,ref='0123456789abcdefghijklmnopqrstuvwxyz',''
  for _=1,6 do
    local i=math.random(1,36)
    ref=ref..chars:sub(i,i)
  end
  return ref
end
-- Fills Send Mail for a donation: the bank toon, a subject with the reference, the note and any gold.
-- The donor attaches items the game's usual way (right-click them in the bags) and presses Send.
function GV.startDonation(bank,copper,note)
  if not (MailFrame and MailFrame:IsShown()) then log('Open a mailbox first.',true); return end
  if MailFrameTab_OnClick then pcall(MailFrameTab_OnClick,nil,2) elseif MailFrameTab2 then MailFrameTab2:Click() end
  donating={ref=newRef(),bank=bank,note=clean(note,80)}
  if SendMailNameEditBox then SendMailNameEditBox:SetText(displayName(bank)) end
  if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText(DONATION_SUBJECT..' #'..donating.ref) end
  local body=mailBodyBox()
  if body then body:SetText((donating.note~='' and (donating.note..'\n\n') or '')..'Sent with Guild Bank Toons.') end
  if copper and copper>0 then
    if MoneyInputFrame_SetCopper and SendMailMoney then MoneyInputFrame_SetCopper(SendMailMoney,copper)
    elseif SetSendMailMoney then SetSendMailMoney(copper) end
  end
  if GV.isTrial() then
    log('Trial accounts can\'t add to the donation log in WoW Forever, but '..displayName(bank)..' will log it when they open the mail.',true)
  end
  log('Mail to '..displayName(bank)..' is ready. Right-click items in your bags to attach them, then press Send.',true)
  requestUpdate()
end
function GV.donating() return donating end
-- What the Send Mail form holds: itemID -> count, and copper.
function GV.sendMailContents()
  local items,money={},(GetSendMailMoney and GetSendMailMoney()) or 0
  if GetSendMailItem then
    for i=1,(ATTACHMENTS_MAX_SEND or 12) do
      local name,id,_,count=GetSendMailItem(i)
      if name and type(id)~='number' and GetSendMailItemLink then
        local link=GetSendMailItemLink(i)
        id=type(link)=='string' and tonumber(link:match('item:(%d+)'))
      end
      if type(id)=='number' then items[id]=(items[id] or 0)+(tonumber(count) or 1) end
    end
  end
  return items,money
end
function GV.captureSend()
  if not donating then return end
  local items,money=GV.sendMailContents()
  sentMail={items=items,money=money}
end
-- MAIL_SEND_SUCCESS: a donation mail went out, so log it as on its way.
function GV.donationSent()
  local d,contents=donating,sentMail
  donating,sentMail=nil,nil
  local g=GV.guild()
  if not g or not d or not contents or not lastMailTo or nameId(lastMailTo)~=nameId(d.bank) then return end
  if not next(contents.items) and contents.money==0 then return end
  local entry={id=myId()..'-'..d.ref,by=key(),bank=d.bank,items=contents.items,money=contents.money,note=d.note,
    created=now(),updated=now(),status='sent',actor=key()}
  g.donations[entry.id]=entry
  GV.queue(GV.donationPayload(entry))
  requestUpdate()
  log('Thank you! Your donation to '..displayName(d.bank)..' is in the guild\'s donation log: '..GV.describeDonation(entry,4)..'.',true)
end
-- The roster id for a mail sender, who may show up by first name only.
function GV.senderId(sender)
  local id=nameId(sender)
  if not id or roster[id] then return id end
  local first,found=baseName(sender):lower(),nil
  for rid,member in pairs(roster) do
    local name=baseName(member.name)
    if name and name:lower():match('^(%S+)')==first then
      if found then return nil end
      found=rid
    end
  end
  return found
end
local function mailKey(text)
  local h=0
  for i=1,#text do h=(h*31+text:byte(i))%16777213 end
  return string.format('%x',h)
end
-- On a bank toon: confirm donations waiting in the mailbox, and log mail from guildmates without the addon.
-- Mail from other bank toons (moving stock around), returned mail and COD mail don't count.
function GV.scanInbox()
  local g,me=GV.guild(),myId()
  if not g or not GV.isBank(me) or not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxItem) then return end
  GV.readRoster()
  if next(roster)==nil then return end
  for i=1,(GetInboxNumItems() or 0) do
    local _,_,sender,subject,money,cod,_,hasItem,_,returned=GetInboxHeaderInfo(i)
    local from=not isSecret(sender) and GV.senderId(sender)
    if from and from~=me and not returned and (cod or 0)==0 and ((money or 0)>0 or hasItem) then
      -- Mail from another bank toon is stock moving between them, not a donation.
      local moved=GV.isBank(from)
      local title=(type(subject)=='string' and not isSecret(subject)) and subject or ''
      local ref=title:match('^'..DONATION_SUBJECT..' #(%w+)')
      local items,parts={},{}
      for a=1,(ATTACHMENTS_MAX_RECEIVE or 16) do
        local _,item,_,count=GetInboxItem(i,a)
        if type(item)=='number' then
          items[item]=(items[item] or 0)+(tonumber(count) or 1)
          parts[#parts+1]=item..':'..(tonumber(count) or 1)
        end
      end
      local id=from..'-'..(ref or ('m'..mailKey(title..'|'..(money or 0)..'|'..table.concat(parts,','))))
      local known=g.donations[id]
      if not known or known.status=='sent' then
        local d={id=id,by=(known and known.by) or displayName(roster[from].name),bank=key(),items=items,money=money or 0,
          note=(known and known.note) or '',created=(known and known.created) or now(),
          updated=math.max(now(),known and (known.updated+1) or 0),status=moved and 'moved' or 'received',actor=key()}
        g.donations[id]=d
        GV.queue(GV.donationPayload(d))
        requestUpdate()
        log((moved and 'Logged stock moved from ' or 'Logged a donation from ')..displayName(d.by)..': '..GV.describeDonation(d,4)..'.',true)
      end
    end
  end
end

-- Window ------------------------------------------------------------------------------------------
-- Game-style tabs under the window: Bank, Requests, Donations, Settings and Guild Master. The Bank tab lists
-- the bank toons down the side and their items beside them like a bag, totalled across toons; hover an item,
-- or switch to the list, to see each toon's share.
-- The window moves, resizes and scales, and remembers all three, so it fits any screen.
local TABS={{key='items',label='Bank'},{key='requests',label='Requests'},{key='donations',label='Ledger'},{key='goals',label='Goals'},
  {key='settings',label='Settings'},{key='gm',label='Guild'}}
local ITEM_ROW_H=36
local SIDEBAR_W=176
local MUTED,ORANGE,GREEN,YELLOW='|cff8c8c8c','|cffff8040','|cff40ff40','|cffffd100'
local SORT_ORDER,SORTS={'name','count','quality'},{name='Name',count='Count',quality='Quality'}
local STATUS_SHORT={open=YELLOW..'Waiting|r',approved=GREEN..'Approved|r',mailed=MUTED..'Mailed|r',denied='|cffff6060Denied|r',cancelled=MUTED..'Cancelled|r'}
local QUESTION_ICON='Interface\\Icons\\INV_Misc_QuestionMark'

-- Widgets ---------------------------------------------------------------------------------------------
-- Templates differ between Classic Era and the modern client; take the first one this client has.
function GV.make(kind,parent,templates,name)
  for _,template in ipairs(templates or {}) do
    local ok,f=pcall(CreateFrame,kind,name,parent,template)
    if ok and f then return f,template end
  end
  return CreateFrame(kind,name,parent)
end
local function label(parent,font,justify,wrap)
  local s=parent:CreateFontString(nil,'OVERLAY',font or 'GameFontHighlightSmall')
  s:SetJustifyH(justify or 'LEFT')
  if s.SetWordWrap then s:SetWordWrap(wrap and true or false) end
  return s
end
local function button(parent,text,width)
  local b=GV.make('Button',parent,{'UIPanelButtonTemplate'})
  b:SetSize(width or 80,22); b:SetText(text)
  return b
end
local function editBox(parent,width,hint,search)
  local box=GV.make('EditBox',parent,search and {'SearchBoxTemplate','InputBoxTemplate'} or {'InputBoxTemplate'})
  box:SetSize(width,20); box:SetAutoFocus(false)
  if box.Instructions then box.Instructions:SetText(hint)
  else
    local text=label(box,'GameFontDisableSmall'); text:SetPoint('LEFT',4,0); text:SetText(hint)
    box:HookScript('OnTextChanged',function(self) text:SetShown((self:GetText() or '')=='') end)
  end
  box:HookScript('OnEscapePressed',function(self) self:ClearFocus() end)
  return box
end
local function enable(widget,on) if on then widget:Enable() else widget:Disable() end end
-- A row of buttons where one is picked, like the game's own filter buttons.
local function segmented(parent,options,get,set,width)
  local group={}
  for i,option in ipairs(options) do
    local b=button(parent,option[2],width)
    b.value=option[1]
    if i>1 then b:SetPoint('LEFT',group[i-1],'RIGHT',2,0) end
    b:SetScript('OnClick',function(self) set(self.value); requestUpdate() end)
    group[i]=b
  end
  function group.refresh() for _,b in ipairs(group) do if b.value==get() then b:LockHighlight() else b:UnlockHighlight() end end end
  return group
end
-- Pins a segmented group's right edge `gap` from the parent's top right corner.
local function pinRight(group,parent,width,gap)
  group[1]:SetPoint('TOPRIGHT',parent,'TOPRIGHT',-(gap+(#group-1)*(width+2)),0)
end
function GV.money(copper)
  if GetCoinTextureString then return GetCoinTextureString(copper) end
  return math.floor(copper/10000)..'g '..(math.floor(copper/100)%100)..'s '..(copper%100)..'c'
end
-- A scrolling list that only builds the rows that fit, so long banks stay quick. build(row) makes a row's
-- parts once; draw(row,entry) fills it. Rows sit in `parent`; the scroll bar takes `gutter` on the right.
-- Scroll templates on some clients find their scroll bar by the frame's global name, so each list gets one.
local listCount=0
function GV.makeList(parent,rowHeight,build,draw,gutter,plain)
  local list={rows={},data={}}
  listCount=listCount+1
  local scroll=GV.make('ScrollFrame',parent,{'FauxScrollFrameTemplate'},'GuildBankToonsList'..listCount)
  scroll:SetPoint('TOPLEFT'); scroll:SetPoint('BOTTOMRIGHT',-(gutter or 26),0)
  local function update() list:Update() end
  scroll:SetScript('OnVerticalScroll',function(self,offset)
    if FauxScrollFrame_OnVerticalScroll then FauxScrollFrame_OnVerticalScroll(self,offset,rowHeight,update) end
  end)
  function list:Update()
    local visible=math.max(1,math.floor((parent:GetHeight() or 0)/rowHeight))
    for i=#self.rows+1,visible do
      local row=CreateFrame('Button',nil,parent)
      row:SetHeight(rowHeight)
      row:SetPoint('TOPLEFT',0,-(i-1)*rowHeight); row:SetPoint('RIGHT',scroll,'RIGHT',0,0)
      if not plain then
        local stripe=row:CreateTexture(nil,'BACKGROUND'); stripe:SetAllPoints()
        stripe:SetColorTexture(1,1,1,(i%2==0) and .035 or 0)
        local glow=row:CreateTexture(nil,'HIGHLIGHT'); glow:SetAllPoints(); glow:SetColorTexture(1,.82,0,.08)
      end
      build(row)
      self.rows[i]=row
    end
    local offset=(FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(scroll)) or 0
    if offset>0 and offset>#self.data-visible then
      offset=math.max(0,#self.data-visible)
      if FauxScrollFrame_SetOffset then FauxScrollFrame_SetOffset(scroll,offset) end
      if scroll.ScrollBar then scroll.ScrollBar:SetValue(offset*rowHeight) end
    end
    if FauxScrollFrame_Update then FauxScrollFrame_Update(scroll,#self.data,visible,rowHeight) end
    for i,row in ipairs(self.rows) do
      local entry=i<=visible and self.data[offset+i] or nil
      row.entry=entry
      if entry then draw(row,entry); row:Show() else row:Hide() end
    end
  end
  function list:SetData(data) self.data=data; self:Update() end
  return list
end
-- Icon, a name line and a detail line: the shape of every item and request row.
local function itemRowParts(row)
  row.icon=row:CreateTexture(nil,'ARTWORK'); row.icon:SetSize(28,28); row.icon:SetPoint('LEFT',6,0)
  row.icon:SetTexCoord(.07,.93,.07,.93)
  row.name=label(row,'GameFontNormal'); row.name:SetPoint('TOPLEFT',row.icon,'TOPRIGHT',10,-1)
  row.detail=label(row,'GameFontHighlightSmall'); row.detail:SetPoint('BOTTOMLEFT',row.icon,'BOTTOMRIGHT',10,1)
end
local function qualityColor(fontString,quality,dim)
  local c=ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
  if dim then fontString:SetTextColor(.5,.5,.5) elseif c then fontString:SetTextColor(c.r,c.g,c.b) else fontString:SetTextColor(1,1,1) end
end
local function linkItem(item)
  local _,link=GV.itemInfo(item)
  if link and InsertChatLink then InsertChatLink(link) end
end
-- The game's own item tooltip, with our lines instead of the generic ones the tooltip hook adds.
local function itemTooltip(owner,item)
  GameTooltip:SetOwner(owner,'ANCHOR_RIGHT')
  ui.ownTooltip=true
  if GameTooltip.SetItemByID then GameTooltip:SetItemByID(item) else GameTooltip:SetHyperlink('item:'..item) end
  ui.ownTooltip=false
  GameTooltip:AddLine(' ')
end

-- Shared by the Ledger tab and gold requests.
local COIN_ICON='Interface\\Icons\\INV_Misc_Coin_01'
local WEEK=7*86400

-- Donate panel ------------------------------------------------------------------------------------
-- Beside the mail window for everyone who isn't a bank toon: pick a bank toon, add gold and a note,
-- fill in the mail, attach items from your bags, send.
function GV.buildDonatePanel()
  if ui.donate or not MailFrame then return end
  local f=GV.make('Frame',MailFrame,{'BasicFrameTemplateWithInset'},'GuildBankToonsDonatePanel')
  f:SetSize(300,360); f:SetPoint('TOPLEFT',MailFrame,'TOPRIGHT',4,0)
  local title=f.TitleText or label(f,'GameFontHighlight','CENTER')
  if not f.TitleText then title:SetPoint('TOP',0,-6) end
  title:SetText('Donate to the guild bank')
  f.intro=label(f,'GameFontHighlightSmall','LEFT',true); f.intro:SetPoint('TOPLEFT',16,-32); f.intro:SetPoint('RIGHT',-16,0)
  f.intro:SetText('Send items or gold to a bank toon. Every donation shows in the guild\'s Donations log.')
  f.to=label(f,'GameFontNormal'); f.to:SetPoint('TOPLEFT',16,-66); f.to:SetText('Send to')
  f.choices={}
  f.goldLabel=label(f,'GameFontNormal'); f.goldLabel:SetText('Gold')
  f.gold=editBox(f,70,'0'); f.gold:SetNumeric(true); f.gold:SetMaxLetters(6)
  f.noteLabel=label(f,'GameFontNormal'); f.noteLabel:SetText('Note')
  f.note=editBox(f,180,'Optional'); f.note:SetMaxLetters(80)
  f.fill=button(f,'Fill in the mail',150)
  f.fill:SetScript('OnClick',function()
    local bank=f.banks[f.choice]
    if not bank then return end
    GV.startDonation(bank.name,(tonumber(f.gold:GetText() or '') or 0)*10000,f.note:GetText() or '')
  end)
  f.steps=label(f,'GameFontHighlightSmall','LEFT',true); f.steps:SetPoint('RIGHT',-16,0)
  f.attached=label(f,'GameFontHighlightSmall','LEFT',true); f.attached:SetPoint('RIGHT',-16,0)
  f.needs=label(f,'GameFontHighlightSmall','LEFT',true); f.needs:SetPoint('RIGHT',-16,0)
  f.addNeeded=button(f,'Add needed items',150)
  f.addNeeded:SetScript('OnClick',GV.addNeededItems)
  f.send=button(f,'Send donation',150)
  f.send:SetScript('OnClick',function() if SendMailMailButton and SendMailMailButton.Click then SendMailMailButton:Click() end end)
  ui.donate=f
end
function GV.refreshDonatePanel()
  local f=ui.donate
  if not f or not f:IsShown() then return end
  local g=GV.guild()
  f.banks={}
  for _,bank in ipairs(GV.bankList()) do
    f.banks[#f.banks+1]={id=bank.id,name=(g.banks[bank.id] and g.banks[bank.id].owner) or bank.name}
  end
  f.choice=1
  for i,bank in ipairs(f.banks) do if bank.id==db.ui.donateTo then f.choice=i end end
  local y=-88
  for i,bank in ipairs(f.banks) do
    local radio=f.choices[i]
    if not radio then
      radio=GV.make('CheckButton',f,{'UIRadioButtonTemplate'})
      radio:SetSize(16,16)
      radio.label=label(radio,'GameFontHighlight'); radio.label:SetPoint('LEFT',radio,'RIGHT',6,0)
      radio:SetScript('OnClick',function(self) db.ui.donateTo=self.id; requestUpdate() end)
      f.choices[i]=radio
    end
    radio.id=bank.id
    radio:ClearAllPoints(); radio:SetPoint('TOPLEFT',20,y)
    radio.label:SetText(displayName(bank.name)); radio:SetChecked(i==f.choice); radio:Show()
    y=y-22
  end
  for i=#f.banks+1,#f.choices do f.choices[i]:Hide() end
  f.goldLabel:ClearAllPoints(); f.goldLabel:SetPoint('TOPLEFT',16,y-12)
  f.gold:ClearAllPoints(); f.gold:SetPoint('LEFT',f.goldLabel,'LEFT',60,0)
  f.noteLabel:ClearAllPoints(); f.noteLabel:SetPoint('TOPLEFT',16,y-42)
  f.note:ClearAllPoints(); f.note:SetPoint('LEFT',f.noteLabel,'LEFT',60,0)
  f.fill:ClearAllPoints(); f.fill:SetPoint('TOPLEFT',16,y-72)
  local pending=GV.donating()
  f.steps:ClearAllPoints(); f.steps:SetPoint('TOPLEFT',16,y-104)
  local items,money={},0
  if pending then items,money=GV.sendMailContents() end
  local has=next(items)~=nil or money>0
  if not pending then
    f.steps:SetText(MUTED..'1. Pick a bank toon and press Fill in the mail.\n2. Right-click items in your bags to attach them.\n3. Press Send donation.|r')
  else
    f.steps:SetText('Donating to '..YELLOW..displayName(pending.bank)..'|r. Right-click items in your bags to attach them.')
  end
  f.attached:ClearAllPoints(); f.attached:SetPoint('TOPLEFT',f.steps,'BOTTOMLEFT',0,-8)
  f.attached:SetText(pending and (has and ('Attached: '..GV.describeDonation({items=items,money=money},5)) or (MUTED..'Nothing attached yet.|r')) or '')
  -- What the guild wants, so donors know what helps most.
  local wanted={}
  for i,e in ipairs(GV.needEntries()) do
    if i>4 or e.have>=e.target then break end
    wanted[#wanted+1]=e.name..' ('..(e.target-e.have)..')'
  end
  f.needs:ClearAllPoints(); f.needs:SetPoint('TOPLEFT',f.attached,'BOTTOMLEFT',0,-10)
  f.needs:SetText(#wanted>0 and (YELLOW..'The guild needs:|r '..table.concat(wanted,', ')) or '')
  local inBags=pending and #GV.neededInBags()>0
  f.addNeeded:ClearAllPoints(); f.addNeeded:SetPoint('BOTTOMLEFT',16,42); f.addNeeded:SetShown(inBags and true or false)
  f.send:ClearAllPoints(); f.send:SetPoint('BOTTOMLEFT',16,14)
  enable(f.send,pending~=nil and has)
  enable(f.fill,#f.banks>0)
  f:SetHeight(math.max(340,-y+290))
end

-- Bag view of the Bank tab -------------------------------------------------------------------------
-- Items as slots, like a bag or the bank: icon, quality border and the count available.
local SLOT,SLOT_GAP,MAX_COLUMNS=37,5,24
function GV.buildSlotRow(row)
  row.slots={}
  for c=1,MAX_COLUMNS do
    local slot=CreateFrame('Button',nil,row)
    slot:SetSize(SLOT,SLOT); slot:SetPoint('LEFT',4+(c-1)*(SLOT+SLOT_GAP),0)
    local back=slot:CreateTexture(nil,'BACKGROUND'); back:SetAllPoints(); back:SetTexture('Interface\\PaperDoll\\UI-Backpack-EmptySlot')
    slot.icon=slot:CreateTexture(nil,'ARTWORK'); slot.icon:SetAllPoints()
    local frame=slot:CreateTexture(nil,'OVERLAY'); frame:SetSize(64,64); frame:SetPoint('CENTER',0,-1)
    frame:SetTexture('Interface\\Buttons\\UI-Quickslot2')
    slot.glow=slot:CreateTexture(nil,'OVERLAY'); slot.glow:SetSize(68,68); slot.glow:SetPoint('CENTER')
    slot.glow:SetTexture('Interface\\Buttons\\UI-ActionButton-Border'); slot.glow:SetBlendMode('ADD')
    slot.count=label(slot,'NumberFontNormal','RIGHT'); slot.count:SetPoint('BOTTOMRIGHT',-3,3)
    slot:SetHighlightTexture('Interface\\Buttons\\ButtonHilight-Square','ADD')
    slot:SetScript('OnEnter',function(self) if self.entry then GV.itemEntryTooltip(self,self.entry) end end)
    slot:SetScript('OnLeave',function() GameTooltip:Hide() end)
    slot:SetScript('OnClick',function(self) if self.entry then GV.itemEntryClick(self.entry) end end)
    row.slots[c]=slot
  end
end
function GV.drawSlotRow(row,chunk)
  for c,slot in ipairs(row.slots) do
    local e=chunk[c]
    slot.entry=e
    slot:SetShown(e~=nil)
    if e then
      slot.icon:SetTexture(e.icon or QUESTION_ICON)
      if slot.icon.SetDesaturated then slot.icon:SetDesaturated(e.available<=0) end
      slot.count:SetText(e.available>1 and e.available or (e.available==1 and '' or '0'))
      local q=ITEM_QUALITY_COLORS and e.quality and e.quality>=2 and ITEM_QUALITY_COLORS[e.quality]
      if q then slot.glow:SetVertexColor(q.r,q.g,q.b); slot.glow:Show() else slot.glow:Hide() end
    end
  end
end
-- Splits the item list into rows of as many slots as fit the width.
function GV.slotRows(list,width)
  local columns=math.max(1,math.min(MAX_COLUMNS,math.floor(((width or 0)-30)/(SLOT+SLOT_GAP))))
  local rows={}
  for i,e in ipairs(list) do
    local r=math.floor((i-1)/columns)+1
    rows[r]=rows[r] or {}
    rows[r][#rows[r]+1]=e
  end
  return rows
end

-- Bank tab ----------------------------------------------------------------------------------------
-- One entry per item across the bank toons shown (all, or the one picked in the sidebar): how many are
-- available in total, and each toon's share, so 5 on one toon and 40 on another reads as 45 with both listed.
-- where: all, bags, bank, or needs (the guild's wanted items, most needed first, held or not).
function GV.itemRows(bankId,where,term,sort)
  local g,all,byItem=GV.guild(),{},{}
  if not g then return all end
  local needs=where=='needs'
  if needs then where='all' end
  for _,bank in ipairs(GV.bankList()) do
    local snap=g.banks[bank.id]
    if snap and (not bankId or bank.id==bankId) then
      -- Approved requests hold their items until mailed, so the All view shows what's still available.
      local reserved=where=='all' and GV.reserved(bank.id) or {}
      local items={}
      if where~='bank' then for id,count in pairs(snap.bags or {}) do items[id]={bags=count,bank=0} end end
      if where~='bags' then
        for id,count in pairs(snap.bank or {}) do items[id]=items[id] or {bags=0,bank=0}; items[id].bank=count end
      end
      for id,c in pairs(items) do
        local e=byItem[id]
        if not e then e={id=id,total=0,available=0,reserved=0,toons={}}; byItem[id]=e; all[#all+1]=e end
        local held=c.bags+c.bank
        local held_back=math.min(held,reserved[id] or 0)
        e.toons[#e.toons+1]={id=bank.id,name=snap.owner or bank.name,bags=c.bags,bank=c.bank,reserved=held_back,available=held-held_back}
        e.total=e.total+held; e.reserved=e.reserved+held_back; e.available=e.available+held-held_back
      end
    end
  end
  local wants=GV.plan().wants
  if needs then
    for item in pairs(wants) do
      if not byItem[item] then
        local e={id=item,total=0,available=0,reserved=0,toons={}}
        byItem[item]=e; all[#all+1]=e
      end
    end
  end
  local shown={}
  for _,e in ipairs(all) do
    local name,_,quality,icon=GV.itemInfo(e.id)
    e.name,e.quality,e.icon=name or ('Item #'..e.id),quality or 1,icon
    e.want=wants[e.id]
    e.short=e.want and GV.shortfall(e.id) or 0
    if (term=='' or e.name:lower():find(term,1,true)) and (not needs or e.want) then
      table.sort(e.toons,function(a,b) if a.available~=b.available then return a.available>b.available end return a.name<b.name end)
      local parts={}
      if needs then
        parts[#parts+1]=(e.short>0 and (ORANGE..'need '..e.short..'|r') or (GREEN..'enough|r'))..MUTED..' (wants '..e.want..')|r'
      end
      if bankId then
        local t=e.toons[1]
        if t and t.bags>0 then parts[#parts+1]=MUTED..'Bags|r '..t.bags end
        if t and t.bank>0 then parts[#parts+1]=MUTED..'Bank|r '..t.bank end
      else
        for _,t in ipairs(e.toons) do parts[#parts+1]=MUTED..displayName(t.name)..'|r '..(t.bags+t.bank) end
      end
      e.where=table.concat(parts,MUTED..'   ·   |r')
      shown[#shown+1]=e
    end
  end
  table.sort(shown,function(a,b)
    if needs and a.short~=b.short then return a.short>b.short end
    if sort=='count' and a.available~=b.available then return a.available>b.available end
    if sort=='quality' and a.quality~=b.quality then return a.quality>b.quality end
    return a.name<b.name
  end)
  return shown
end
-- The toon to request an item from: the one picked in the sidebar if it has some, else the one with the most.
function GV.bestToon(item)
  local g,best,most=GV.guild(),nil,0
  if not g then return nil end
  for _,bank in ipairs(GV.bankList()) do
    local n=GV.available(bank.id,item)
    if n>0 and (bank.id==db.ui.bank or n>most) then
      best,most=(g.banks[bank.id] and g.banks[bank.id].owner) or bank.name,n
      if bank.id==db.ui.bank then break end
    end
  end
  return best
end
function GV.buildItemsPage(page)
  local side=CreateFrame('Frame',nil,page)
  side:SetPoint('TOPLEFT'); side:SetPoint('BOTTOMLEFT'); side:SetWidth(SIDEBAR_W)
  local shade=side:CreateTexture(nil,'BACKGROUND'); shade:SetAllPoints(); shade:SetColorTexture(0,0,0,.25)
  local heading=label(side,'GameFontNormal'); heading:SetPoint('TOPLEFT',10,-8); heading:SetText('Bank toons')
  local area=CreateFrame('Frame',nil,side); area:SetPoint('TOPLEFT',0,-28); area:SetPoint('BOTTOMRIGHT',0,4)
  ui.toonList=GV.makeList(area,40,function(row)
    row.selected=row:CreateTexture(nil,'BORDER'); row.selected:SetAllPoints(); row.selected:SetColorTexture(1,.82,0,.12)
    row.bar=row:CreateTexture(nil,'ARTWORK'); row.bar:SetPoint('TOPLEFT'); row.bar:SetPoint('BOTTOMLEFT'); row.bar:SetWidth(3)
    row.bar:SetColorTexture(1,.82,0,.9)
    row.name=label(row,'GameFontHighlight'); row.name:SetPoint('TOPLEFT',12,-5); row.name:SetPoint('RIGHT',-4,0)
    row.detail=label(row,'GameFontHighlightSmall'); row.detail:SetPoint('BOTTOMLEFT',12,6); row.detail:SetPoint('RIGHT',-4,0)
    row:SetScript('OnClick',function(self) db.ui.bank=self.entry.id; requestUpdate() end)
  end,function(row,toon)
    local on=db.ui.bank==toon.id
    row.selected:SetShown(on); row.bar:SetShown(on)
    row.name:SetText(toon.label); row.detail:SetText(toon.detail)
  end,22)
  local main=CreateFrame('Frame',nil,page)
  main:SetPoint('TOPLEFT',side,'TOPRIGHT',10,0); main:SetPoint('BOTTOMRIGHT')
  ui.view=segmented(main,{{'grid','Bag'},{'list','List'}},function() return db.ui.view end,function(v) db.ui.view=v end,46)
  pinRight(ui.view,main,46,24)
  ui.sort=button(main,'Sort: Name',96); ui.sort:SetPoint('TOPRIGHT',ui.view[1],'TOPLEFT',-8,0)
  ui.sort:SetScript('OnClick',function()
    local at=1
    for i,k in ipairs(SORT_ORDER) do if k==db.ui.sort then at=i end end
    db.ui.sort=SORT_ORDER[at%#SORT_ORDER+1]; requestUpdate()
  end)
  ui.where=segmented(main,{{'all','All'},{'bags','Bags'},{'bank','Bank'},{'needs','Needs'}},function() return db.ui.filter end,function(v) db.ui.filter=v end,50)
  ui.where[1]:SetPoint('TOPRIGHT',ui.sort,'TOPLEFT',-(8+3*52),0)
  ui.search=editBox(main,160,'Search items',true)
  ui.search:SetPoint('TOPLEFT',8,-1); ui.search:SetPoint('RIGHT',ui.where[1],'LEFT',-12,0)
  ui.search:HookScript('OnTextChanged',function() requestUpdate() end)
  ui.summary=label(main,'GameFontHighlightSmall'); ui.summary:SetPoint('TOPLEFT',4,-32); ui.summary:SetPoint('RIGHT',-24,0)
  local list=CreateFrame('Frame',nil,main); list:SetPoint('TOPLEFT',0,-52); list:SetPoint('BOTTOMRIGHT',0,22)
  ui.listBox=CreateFrame('Frame',nil,list); ui.listBox:SetAllPoints()
  ui.gridBox=CreateFrame('Frame',nil,list); ui.gridBox:SetAllPoints()
  ui.itemList=GV.makeList(ui.listBox,ITEM_ROW_H,GV.buildItemRow,GV.drawItemRow)
  ui.itemGrid=GV.makeList(ui.gridBox,SLOT+SLOT_GAP,GV.buildSlotRow,GV.drawSlotRow,26,true)
  ui.itemsEmpty=label(list,'GameFontDisable','CENTER',true); ui.itemsEmpty:SetPoint('TOPLEFT',20,-40); ui.itemsEmpty:SetPoint('RIGHT',-46,0)
  -- Gold along the bottom, like a bag's money line.
  ui.money=label(main,'GameFontHighlight','RIGHT'); ui.money:SetPoint('BOTTOMRIGHT',-26,4)
  ui.goldRequest=button(main,'Request gold',110); ui.goldRequest:SetHeight(20); ui.goldRequest:SetPoint('RIGHT',ui.money,'LEFT',-12,0)
  ui.goldRequest:SetScript('OnClick',GV.openGoldRequest)
  local export=button(main,'Export',70); export:SetHeight(20); export:SetPoint('RIGHT',ui.goldRequest,'LEFT',-6,0)
  export:SetScript('OnClick',function() GV.openExport('inventory') end)
  local hint=label(main,'GameFontDisableSmall'); hint:SetPoint('BOTTOMLEFT',4,5); hint:SetPoint('RIGHT',export,'LEFT',-8,0)
  hint:SetText('Click an item to request it   ·   Shift-click to link it   ·   Hover to see each toon\'s share')
end
-- Hovering an item, as a slot or a list row: the game's tooltip plus each toon's share.
function GV.itemEntryTooltip(owner,e)
    itemTooltip(owner,e.id)
    for _,t in ipairs(e.toons) do
      local parts={}
      if t.bags>0 then parts[#parts+1]='bags '..t.bags end
      if t.bank>0 then parts[#parts+1]='bank '..t.bank end
      if t.reserved>0 then parts[#parts+1]=ORANGE..t.reserved..' reserved|r' end
      GameTooltip:AddDoubleLine(displayName(t.name),table.concat(parts,', '),1,.82,0,1,1,1)
    end
    if e.want then GameTooltip:AddDoubleLine('The guild wants',e.want..(e.short>0 and (ORANGE..' (need '..e.short..')|r') or ''),1,.82,0,1,1,1) end
    GameTooltip:AddLine('Click to request   ·   Shift-click to link'..(GV.isOfficer(myId()) and '   ·   Alt-click to set how many the guild wants' or ''),.6,.6,.6,true)
    GameTooltip:Show()
end
function GV.itemEntryClick(e)
  if IsShiftKeyDown() then linkItem(e.id)
  elseif IsAltKeyDown and IsAltKeyDown() and GV.isOfficer(myId()) then
    if StaticPopup_Show then StaticPopup_Show('GUILDBANKTOONS_WANT',e.name,nil,{item=e.id,want=e.want}) end
  else GV.openRequestDialog(e) end
end
function GV.buildItemRow(row)
  itemRowParts(row)
  row.count=label(row,'GameFontHighlightLarge','RIGHT')
  row.held=label(row,'GameFontHighlightSmall','RIGHT'); row.held:SetPoint('BOTTOMRIGHT',-10,4)
  row.name:SetPoint('RIGHT',-90,0); row.detail:SetPoint('RIGHT',-90,0)
  row:SetScript('OnEnter',function(self) if self.entry then GV.itemEntryTooltip(self,self.entry) end end)
  row:SetScript('OnLeave',function() GameTooltip:Hide() end)
  row:SetScript('OnClick',function(self) if self.entry then GV.itemEntryClick(self.entry) end end)
end
function GV.drawItemRow(row,e)
  row.icon:SetTexture(e.icon or QUESTION_ICON)
  row.name:SetText(e.name); qualityColor(row.name,e.quality,e.available<=0)
  row.detail:SetText(e.where)
  row.count:SetText(e.available)
  row.count:ClearAllPoints()
  if db.ui.filter=='needs' and e.want then
    row.count:SetPoint('TOPRIGHT',-10,-3)
    row.held:SetText(MUTED..'of '..e.want..'|r'); row.held:Show()
  elseif e.reserved>0 then
    row.count:SetPoint('TOPRIGHT',-10,-3)
    row.held:SetText(ORANGE..e.reserved..' reserved|r'); row.held:Show()
  else
    row.count:SetPoint('RIGHT',-10,0); row.held:Hide()
  end
end
function GV.refreshItems()
  local g=GV.guild()
  local banks=GV.bankList()
  local picked=false
  for _,bank in ipairs(banks) do if bank.id==db.ui.bank then picked=true end end
  if not picked then db.ui.bank=nil end
  local toons,gold,withData={},0,0
  for _,bank in ipairs(banks) do
    local snap=g.banks[bank.id]
    if snap then gold=gold+(snap.gold or 0); withData=withData+1 end
    toons[#toons+1]={id=bank.id,label=displayName(bank.name),
      detail=snap and (GV.money(snap.gold or 0)..'  '..MUTED..ago(snap.stamp)..'|r') or (MUTED..'waiting for contents|r')}
  end
  if #banks>0 then
    table.insert(toons,1,{id=nil,label='All bank toons',detail=GV.money(gold)..'  '..MUTED..#banks..(#banks==1 and ' toon' or ' toons')..'|r'})
  end
  ui.toonList:SetData(toons)
  ui.where.refresh()
  ui.sort:SetText('Sort: '..SORTS[db.ui.sort or 'name'])
  local term=(ui.search:GetText() or ''):lower()
  local list=g and GV.itemRows(db.ui.bank,db.ui.filter,term,db.ui.sort or 'name') or {}
  ui.view.refresh()
  -- Needs read best as a list: each row says how many more the guild wants.
  local grid=db.ui.view~='list' and db.ui.filter~='needs'
  ui.goldRequest:SetShown(GV.rule('gold')==1 and #banks>0)
  ui.listBox:SetShown(not grid); ui.gridBox:SetShown(grid)
  if grid then ui.itemGrid:SetData(GV.slotRows(list,ui.gridBox:GetWidth())) else ui.itemList:SetData(list) end
  local snap=g and db.ui.bank and g.banks[db.ui.bank]
  ui.money:SetText((g and #banks>0) and GV.money(snap and (snap.gold or 0) or gold) or '')
  if not g or #banks==0 then ui.summary:SetText('')
  elseif db.ui.bank and snap then
    local notes={GV.money(snap.gold or 0),MUTED..'updated '..ago(snap.stamp)..(snap.via and (' via '..snap.via) or '')..'|r'}
    if (snap.bankStamp or 0)==0 then notes[#notes+1]=ORANGE..'bank not opened yet|r' end
    table.remove(notes,1)
    ui.summary:SetText(displayName(snap.owner)..'   ·   '..table.concat(notes,'   ·   '))
  elseif db.ui.bank then ui.summary:SetText('')
  else
    ui.summary:SetText(#list..(#list==1 and ' item' or ' items')..'   ·   '..withData..' of '..#banks..' bank toons reporting')
  end
  local empty=''
  if not g then empty='Join a guild to see its bank.'
  elseif #banks==0 then
    empty='No bank toons yet.\n\nThe guild master adds them on the '..YELLOW..'Guild Master|r tab. You can also follow one just for yourself under '..YELLOW..'Settings|r.'
  elseif db.ui.bank and not snap then
    empty='Waiting for this toon\'s contents.\n\nThey arrive when the toon, or a guildmate who has seen them, is online.'
  elseif #list==0 then
    empty=(term~='' and ('Nothing matches "'..term..'".'))
      or (db.ui.filter=='needs' and 'The guild hasn\'t listed any wanted items yet. Officers add them on the Guild tab, or Alt-click an item here.')
      or (withData==0 and 'Waiting for the bank toons\' contents.') or 'Empty.'
  end
  ui.itemsEmpty:SetText(empty)
end

-- Request dialog ------------------------------------------------------------------------------------
-- Pick which toon to ask (with how many each has available), how many, and an optional note.
function GV.buildRequestDialog()
  local d=GV.make('Frame',UIParent,{'BasicFrameTemplateWithInset'},'GuildBankToonsRequestDialog')
  d:SetSize(340,260); d:SetPoint('CENTER',UIParent,'CENTER',0,80)
  d:SetFrameStrata('DIALOG'); d:SetToplevel(true); d:SetClampedToScreen(true)
  d:SetMovable(true); d:EnableMouse(true); d:RegisterForDrag('LeftButton')
  d:SetScript('OnDragStart',d.StartMoving); d:SetScript('OnDragStop',d.StopMovingOrSizing)
  table.insert(UISpecialFrames,'GuildBankToonsRequestDialog')
  local title=d.TitleText or label(d,'GameFontHighlight','CENTER')
  if not d.TitleText then title:SetPoint('TOP',0,-6) end
  title:SetText('Request from the guild bank')
  d.icon=d:CreateTexture(nil,'ARTWORK'); d.icon:SetSize(36,36); d.icon:SetPoint('TOPLEFT',18,-36)
  d.name=label(d,'GameFontNormalLarge'); d.name:SetPoint('TOPLEFT',d.icon,'TOPRIGHT',10,-2); d.name:SetPoint('RIGHT',-16,0)
  d.total=label(d,'GameFontHighlightSmall'); d.total:SetPoint('TOPLEFT',d.name,'BOTTOMLEFT',0,-4)
  d.from=label(d,'GameFontNormal'); d.from:SetPoint('TOPLEFT',18,-86); d.from:SetText('From')
  d.choices={}
  d.amountLabel=label(d,'GameFontNormal'); d.amountLabel:SetText('How many')
  d.amount=editBox(d,56,''); d.amount:SetNumeric(true); d.amount:SetMaxLetters(4)
  d.unit=label(d,'GameFontHighlight'); d.unit:SetPoint('LEFT',d.amount,'RIGHT',2,0)
  d.max=button(d,'Max',50); d.max:SetPoint('LEFT',d.amount,'RIGHT',18,0)
  d.max:SetScript('OnClick',function() local t=d.toons[d.choice]; if t then d.amount:SetText(t.available) end end)
  d.noteLabel=label(d,'GameFontNormal'); d.noteLabel:SetText('Note')
  d.note=editBox(d,210,'Optional, e.g. "for my alt"'); d.note:SetMaxLetters(80)
  d.warning=label(d,'GameFontRedSmall')
  d.ok=button(d,'Request',110); d.ok:SetPoint('BOTTOMRIGHT',-16,14)
  d.cancel=button(d,CANCEL or 'Cancel',90); d.cancel:SetPoint('RIGHT',d.ok,'LEFT',-8,0)
  d.ok:SetScript('OnClick',GV.submitRequest); d.cancel:SetScript('OnClick',function() d:Hide() end)
  d.amount:HookScript('OnTextChanged',GV.checkRequest)
  d.amount:SetScript('OnEnterPressed',GV.submitRequest); d.note:SetScript('OnEnterPressed',GV.submitRequest)
  ui.request=d
end
function GV.checkRequest()
  local d=ui.request
  local n=tonumber(d.amount:GetText() or '') or 0
  local t=d.toons[d.choice]
  for i,radio in ipairs(d.choices) do radio:SetChecked(i==d.choice) end
  local warning=''
  if GV.isTrial() then warning='Trial accounts can\'t send requests in WoW Forever.'
  elseif not t then warning='Nobody has this item right now.'
  elseif n<1 then warning='Enter how many you need.'
  elseif n>t.available then warning='Only '..t.available..' available on '..displayName(t.name)..'.' end
  d.warning:SetText(warning)
  enable(d.ok,warning=='')
  return warning==''
end
function GV.openRequestDialog(e)
  if not ui.request then GV.buildRequestDialog() end
  local d=ui.request
  d.item,d.toons,d.choice=e.id,{},1
  d.unit:SetText(e.unit or '')
  for _,t in ipairs(e.toons) do if t.available>0 then d.toons[#d.toons+1]=t end end
  for i,t in ipairs(d.toons) do if t.id==db.ui.bank then d.choice=i end end
  d.icon:SetTexture(e.icon or QUESTION_ICON)
  d.name:SetText(e.name); qualityColor(d.name,e.quality)
  d.total:SetText(e.available..(e.unit or '')..' available in total'..(e.reserved>0 and (MUTED..'   ('..e.reserved..' reserved)|r') or ''))
  local y=-108
  for i,t in ipairs(d.toons) do
    local radio=d.choices[i]
    if not radio then
      radio=GV.make('CheckButton',d,{'UIRadioButtonTemplate'})
      radio:SetSize(16,16)
      radio.label=label(radio,'GameFontHighlight'); radio.label:SetPoint('LEFT',radio,'RIGHT',6,0)
      radio:SetScript('OnClick',function(self) d.choice=self.index; GV.checkRequest() end)
      d.choices[i]=radio
    end
    radio.index=i
    radio:ClearAllPoints(); radio:SetPoint('TOPLEFT',22,y)
    radio.label:SetText(displayName(t.name)..'   '..MUTED..t.available..(e.unit or '')..' available|r')
    radio:Show()
    y=y-22
  end
  for i=#d.toons+1,#d.choices do d.choices[i]:Hide() end
  if #d.toons==0 then y=y-4 end
  d.amountLabel:ClearAllPoints(); d.amountLabel:SetPoint('TOPLEFT',18,y-12)
  d.amount:ClearAllPoints(); d.amount:SetPoint('LEFT',d.amountLabel,'LEFT',90,0)
  d.noteLabel:ClearAllPoints(); d.noteLabel:SetPoint('TOPLEFT',18,y-44)
  d.note:ClearAllPoints(); d.note:SetPoint('LEFT',d.noteLabel,'LEFT',90,0)
  d.warning:ClearAllPoints(); d.warning:SetPoint('TOPLEFT',18,y-72)
  d:SetHeight(-y+130)
  d.amount:SetText('1'); d.note:SetText('')
  d:Show(); GV.checkRequest()
  d.amount:SetFocus(); d.amount:HighlightText()
end
function GV.submitRequest()
  local d=ui.request
  if not GV.checkRequest() then return end
  local t=d.toons[d.choice]
  GV.createRequest(d.item,tonumber(d.amount:GetText()),d.note:GetText() or '',t.name)
  d:Hide()
end

-- Requests tab ------------------------------------------------------------------------------------
function GV.buildRequestsPage(page)
  ui.reqFilter=segmented(page,{{'active','Active'},{'mine','Mine'},{'all','All'}},
    function() return db.ui.reqFilter end,function(v) db.ui.reqFilter=v end,64)
  pinRight(ui.reqFilter,page,64,24)
  ui.reqSearch=editBox(page,200,'Search item, name or note',true)
  ui.reqSearch:SetPoint('TOPLEFT',8,-1); ui.reqSearch:SetPoint('RIGHT',ui.reqFilter[1],'LEFT',-12,0)
  ui.reqSearch:HookScript('OnTextChanged',function() requestUpdate() end)
  ui.reqInfo=label(page,'GameFontHighlightSmall'); ui.reqInfo:SetPoint('TOPLEFT',4,-32); ui.reqInfo:SetPoint('RIGHT',-24,0)
  local list=CreateFrame('Frame',nil,page); list:SetPoint('TOPLEFT',0,-52); list:SetPoint('BOTTOMRIGHT')
  ui.reqList=GV.makeList(list,ITEM_ROW_H,GV.buildRequestRow,GV.drawRequestRow)
  ui.reqEmpty=label(list,'GameFontDisable','CENTER',true); ui.reqEmpty:SetPoint('TOPLEFT',20,-40); ui.reqEmpty:SetPoint('RIGHT',-46,0)
end
function GV.buildRequestRow(row)
  itemRowParts(row)
  row.actions={}
  for n=1,2 do
    local b=button(row,'',72); b:SetHeight(20); b:SetPoint('RIGHT',-(8+(2-n)*76),0)
    b:SetScript('OnClick',function(self) GV.setRequestStatus(row.entry,self.status) end)
    row.actions[n]=b
  end
  row.status=label(row,'GameFontHighlightSmall','RIGHT')
  row.name:SetPoint('RIGHT',row.status,'LEFT',-10,0); row.detail:SetPoint('RIGHT',row.status,'LEFT',-10,0)
  row:SetScript('OnEnter',function(self)
    local q=self.entry
    if not q then return end
    itemTooltip(self,q.item)
    GameTooltip:AddLine('Requested by '..displayName(q.by)..' from '..displayName(q.bank)..', '..ago(tonumber(q.id:match('%-(%d+)%-%d+$')) or q.updated),1,1,1)
    if (q.note or '')~='' then GameTooltip:AddLine('"'..q.note..'"',1,.82,0,true) end
    if q.status=='open' then GameTooltip:AddLine(STATUSES.open,.6,.6,.6)
    else GameTooltip:AddLine(STATUSES[q.status]..' by '..displayName(q.actor or '?'),.6,.6,.6) end
    if q.status=='mailed' and q.approvedBy then GameTooltip:AddLine('Approved by '..displayName(q.approvedBy),.6,.6,.6) end
    GameTooltip:AddLine('Shift-click to link',.6,.6,.6)
    GameTooltip:Show()
  end)
  row:SetScript('OnLeave',function() GameTooltip:Hide() end)
  row:SetScript('OnClick',function(self) if self.entry and IsShiftKeyDown() then linkItem(self.entry.item) end end)
end
function GV.drawRequestRow(row,q)
  local name,_,quality,icon=GV.itemInfo(q.item)
  row.icon:SetTexture(icon or QUESTION_ICON)
  row.name:SetText(q.count..'x '..(name or ('Item #'..q.item))); qualityColor(row.name,quality,not isActive(q))
  local parts={displayName(q.by)..MUTED..' from |r'..displayName(q.bank),MUTED..ago(tonumber(q.id:match('%-(%d+)%-%d+$')) or q.updated)..'|r'}
  if (q.note or '')~='' then parts[#parts+1]=MUTED..'"'..q.note..'"|r' end
  row.detail:SetText(table.concat(parts,MUTED..'   ·   |r'))
  local specs,me={},myId()
  for _,spec in ipairs({{'Approve','approved'},{'Mailed','mailed'},{'Deny','denied'},{'Cancel','cancelled'}}) do
    if #specs<2 and GV.allowed(q,q.status,spec[2],me) then specs[#specs+1]=spec end
  end
  for n,b in ipairs(row.actions) do
    local spec=specs[n-(2-#specs)]
    b:SetShown(spec~=nil)
    if spec then b:SetText(spec[1]); b.status=spec[2] end
  end
  row.status:ClearAllPoints(); row.status:SetPoint('RIGHT',-(12+#specs*76),0)
  row.status:SetText(STATUS_SHORT[q.status] or q.status)
end
function GV.refreshRequests()
  ui.reqFilter.refresh()
  local me,term,filter=myId(),(ui.reqSearch:GetText() or ''):lower(),db.ui.reqFilter
  local list,waiting,toMail={},0,0
  for _,q in ipairs(GV.requestList()) do
    if q.status=='open' then waiting=waiting+1 end
    if q.status=='approved' then toMail=toMail+1 end
    local keep=filter=='all' or (filter=='active' and isActive(q)) or (filter=='mine' and (nameId(q.by)==me or nameId(q.bank)==me))
    if keep and term~='' then
      local name=GV.itemInfo(q.item) or ''
      local text=(name..' '..q.by..' '..q.bank..' '..(q.note or '')):lower()
      keep=text:find(term,1,true)~=nil
    end
    if keep then list[#list+1]=q end
  end
  ui.reqList:SetData(list)
  local who=GV.isApprover(me) and 'You can approve or deny requests.' or 'Click an item on the Bank tab to request it.'
  ui.reqInfo:SetText(YELLOW..waiting..'|r waiting for approval   ·   '..GREEN..toMail..'|r approved, waiting to be mailed   ·   '..MUTED..who..'|r')
  local empty=''
  if #list==0 then empty=term~='' and ('Nothing matches "'..term..'".') or (filter=='active' and 'No open requests.' or 'No requests.') end
  ui.reqEmpty:SetText(empty)
end

-- Settings tab ------------------------------------------------------------------------------------
-- Following a bank toon just for yourself, without the guild master's list or the guild info.
function GV.follow(name,on)
  local g,id=GV.guild(),nameId(name)
  if not g then log('You must be in a guild.',true); return false end
  if not id or name:find('[|,]') then log('Enter the bank toon\'s full name, First Last.',true); return false end
  if on then
    g.extra[id]=baseName(name); log('Following '..baseName(name)..' just for you.',true)
  elseif g.managed[id] then
    log(displayName(name)..' was set by the guild master, who can remove it on the Guild Master tab.',true); return false
  elseif g.tagged[id] then
    log(displayName(name)..' is tagged in the guild info; an officer has to remove the tag there.',true); return false
  else
    g.extra[id]=nil; log('Stopped following '..displayName(name)..'.',true)
  end
  GV.banksChanged()
  return true
end
function GV.buildSettingsPage(page)
  local scroll=GV.make('ScrollFrame',page,{'UIPanelScrollFrameTemplate'},'GuildBankToonsSettingsScroll')
  scroll:SetPoint('TOPLEFT'); scroll:SetPoint('BOTTOMRIGHT',-26,0)
  local c=CreateFrame('Frame',nil,scroll); c:SetSize(480,700)
  scroll:SetScrollChild(c)
  scroll:HookScript('OnSizeChanged',function(_,width) if width then c:SetWidth(width) end end)
  ui.checks={}
  local y=-4
  local function heading(text)
    local h=label(c,'GameFontNormal'); h:SetPoint('TOPLEFT',4,y); h:SetText(text)
    local line=c:CreateTexture(nil,'ARTWORK'); line:SetColorTexture(1,.82,0,.2); line:SetHeight(1)
    line:SetPoint('TOPLEFT',4,y-18); line:SetPoint('RIGHT',c,'RIGHT',-8,0)
    y=y-28
  end
  local function check(field,text,note,changed)
    local box=GV.make('CheckButton',c,{'UICheckButtonTemplate','InterfaceOptionsCheckButtonTemplate'})
    box:SetSize(26,26); box:SetPoint('TOPLEFT',4,y)
    local caption=label(c,'GameFontHighlight'); caption:SetPoint('LEFT',box,'RIGHT',4,1); caption:SetText(text)
    box.field=field
    box:SetScript('OnClick',function(self)
      db.settings[field]=self:GetChecked() and true or false
      if changed then changed() end
      requestUpdate()
    end)
    ui.checks[#ui.checks+1]=box
    y=y-24
    if note then
      local n=label(c,'GameFontDisableSmall','LEFT',true); n:SetPoint('TOPLEFT',34,y+2); n:SetPoint('RIGHT',c,'RIGHT',-8,0); n:SetText(note)
      y=y-16
    end
    y=y-6
  end
  heading('Display')
  check('tooltips','Show guild bank counts on item tooltips','Hover any item to see how many each bank toon has.')
  check('minimap','Show the minimap button',nil,function() GV.placeMinimap() end)
  check('quiet','Quiet mode','Only important messages in chat: requests and decisions.')
  local size=label(c,'GameFontHighlight'); size:SetPoint('TOPLEFT',10,y-4); size:SetText('Window size')
  local smaller=button(c,'-',26); smaller:SetPoint('LEFT',size,'LEFT',110,0)
  ui.scaleText=label(c,'GameFontHighlight','CENTER'); ui.scaleText:SetWidth(48); ui.scaleText:SetPoint('LEFT',smaller,'RIGHT',4,0)
  local bigger=button(c,'+',26); bigger:SetPoint('LEFT',ui.scaleText,'RIGHT',4,0)
  local reset=button(c,'Reset window',110); reset:SetPoint('LEFT',bigger,'RIGHT',12,0)
  smaller:SetScript('OnClick',function() GV.setScale((db.ui.scale or 1)-.05) end)
  bigger:SetScript('OnClick',function() GV.setScale((db.ui.scale or 1)+.05) end)
  reset:SetScript('OnClick',function() db.ui.point,db.ui.w,db.ui.h,db.ui.scale=nil,nil,nil,1; GV.placeWindow(); requestUpdate() end)
  y=y-40
  heading('Requests')
  check('whispers','Whisper officers who don\'t have the addon','When you make a request, up to 3 online officers without the addon get a whisper.')
  check('companion','Offer a reload when requests change','Turn on where the Discord companion runs, so it posts requests right away.')
  check('lowStock','Tell me when a wanted item runs low','For officers: a chat alert when stock of something on the guild\'s wanted list drops below the target.')
  check('donate','Show the Donate panel at mailboxes','Send items or gold to a bank toon in a few clicks; it goes in the Donations log.')
  heading('When playing a bank toon')
  check('mailHelper','Show the mail helper at mailboxes','Lists approved requests beside the mail window and fills in each mail.')
  check('autofill','Fill the first approved request when a mailbox opens')
  heading('Follow a bank toon just for me')
  local note=label(c,'GameFontDisableSmall','LEFT',true); note:SetPoint('TOPLEFT',8,y); note:SetPoint('RIGHT',c,'RIGHT',-8,0)
  note:SetText('Only you see toons you follow here. To add one for the whole guild, ask the guild master.')
  y=y-22
  ui.followName=editBox(c,200,'First Last'); ui.followName:SetPoint('TOPLEFT',14,y)
  local follow=button(c,'Follow',90); follow:SetPoint('LEFT',ui.followName,'RIGHT',10,0)
  local function doFollow()
    if GV.follow(ui.followName:GetText() or '',true) then ui.followName:SetText(''); ui.followName:ClearFocus() end
  end
  follow:SetScript('OnClick',doFollow); ui.followName:SetScript('OnEnterPressed',doFollow)
  y=y-30
  ui.followRows={}
  for i=1,8 do
    local row=CreateFrame('Frame',nil,c); row:SetSize(300,22); row:SetPoint('TOPLEFT',12,y-(i-1)*24)
    row.name=label(row,'GameFontHighlight'); row.name:SetPoint('LEFT',4,0)
    row.remove=button(row,'Stop following',120); row.remove:SetHeight(20); row.remove:SetPoint('RIGHT',0,0)
    row.remove:SetScript('OnClick',function() GV.follow(row.toon,false); requestUpdate() end)
    ui.followRows[i]=row
  end
  ui.followNone=label(c,'GameFontDisableSmall'); ui.followNone:SetPoint('TOPLEFT',16,y-4); ui.followNone:SetText('You aren\'t following any extra toons.')
  ui.followAnchor=y
  ui.syncHeading=label(c,'GameFontNormal')
  ui.syncButton=button(c,'Sync now',100)
  ui.syncButton:SetScript('OnClick',function() GV.syncAll(); GV.askManaged(); GV.askPlan(); log('Asked the guild for the latest bank contents.',true) end)
  ui.statusText=label(c,'GameFontHighlightSmall','LEFT',true); ui.statusText:SetPoint('RIGHT',c,'RIGHT',-8,0)
  ui.settingsContent=c
end
function GV.setScale(scale)
  db.ui.scale=math.max(.7,math.min(1.4,math.floor(scale*20+.5)/20))
  if window then window:SetScale(db.ui.scale) end
  requestUpdate()
end
function GV.refreshSettings()
  for _,box in ipairs(ui.checks) do box:SetChecked(db.settings[box.field] and true or false) end
  ui.scaleText:SetText(math.floor((db.ui.scale or 1)*100+.5)..'%')
  local g,followed=GV.guild(),{}
  if g then for _,name in pairs(g.extra) do followed[#followed+1]=name end end
  table.sort(followed)
  for i,row in ipairs(ui.followRows) do
    row.toon=followed[i]
    row:SetShown(followed[i]~=nil)
    if followed[i] then row.name:SetText(displayName(followed[i])) end
  end
  ui.followNone:SetShown(#followed==0)
  -- The sync section moves up under however many followed toons there are.
  local y=ui.followAnchor-math.max(1,math.min(#followed,#ui.followRows))*24-16
  ui.syncHeading:ClearAllPoints(); ui.syncHeading:SetPoint('TOPLEFT',4,y); ui.syncHeading:SetText('Sync')
  ui.syncButton:ClearAllPoints(); ui.syncButton:SetPoint('TOPLEFT',10,y-24)
  ui.statusText:ClearAllPoints(); ui.statusText:SetPoint('TOPLEFT',10,y-54)
  ui.statusText:SetText(string.format('Version %s   ·   playing %s%s\nMessages sent %d, received %d, rejected %d, waiting to send %d',
    VERSION,key(),(GV.isBank(myId()) and ' (a bank toon)' or '')..(GV.isTrial() and ' (trial account: browse only)' or ''),sent,received,rejected,GV.queued()))
  ui.settingsContent:SetHeight(-y+100)
end

-- Guild Master tab --------------------------------------------------------------------------------
function GV.buildGMPage(page)
  local title=label(page,'GameFontNormalLarge'); title:SetPoint('TOPLEFT',6,-4); title:SetText('Bank toons for the whole guild')
  ui.gmInfo=label(page,'GameFontHighlightSmall','LEFT',true); ui.gmInfo:SetPoint('TOPLEFT',6,-28); ui.gmInfo:SetPoint('RIGHT',-24,0)
  ui.gmName=editBox(page,220,'First Last of the bank toon'); ui.gmName:SetPoint('TOPLEFT',12,-64)
  ui.gmAdd=button(page,'Add bank toon',130); ui.gmAdd:SetPoint('LEFT',ui.gmName,'RIGHT',10,0)
  local function add()
    if GV.gmChange('add',ui.gmName:GetText() or '') then ui.gmName:SetText(''); ui.gmName:ClearFocus() end
  end
  ui.gmAdd:SetScript('OnClick',add); ui.gmName:SetScript('OnEnterPressed',add)
  local list=CreateFrame('Frame',nil,page); list:SetPoint('TOPLEFT',0,-96); list:SetPoint('BOTTOMRIGHT',0,52)
  ui.gmList=GV.makeList(list,ITEM_ROW_H,function(row)
    row.name=label(row,'GameFontHighlight'); row.name:SetPoint('TOPLEFT',12,-4)
    row.detail=label(row,'GameFontHighlightSmall'); row.detail:SetPoint('BOTTOMLEFT',12,5)
    row.remove=button(row,'Remove',80); row.remove:SetHeight(20); row.remove:SetPoint('RIGHT',-8,0)
    row.name:SetPoint('RIGHT',row.remove,'LEFT',-8,0); row.detail:SetPoint('RIGHT',row.remove,'LEFT',-8,0)
    row.remove:SetScript('OnClick',function(self) GV.gmChange('remove',self:GetParent().entry.name) end)
  end,function(row,toon)
    row.name:SetText(displayName(toon.name))
    local snap=toon.snap
    row.detail:SetText(snap and (GV.money(snap.gold or 0)..'   '..MUTED..'·   updated '..ago(snap.stamp)..'|r')
      or (MUTED..'Waiting for this toon to log in with the addon and visit the banker.|r'))
    row.remove:SetShown(toon.canEdit)
  end)
  ui.gmEmpty=label(list,'GameFontDisable','CENTER',true); ui.gmEmpty:SetPoint('TOPLEFT',20,-30); ui.gmEmpty:SetPoint('RIGHT',-46,0)
  ui.gmClear=button(page,'Remove all',110); ui.gmClear:SetPoint('BOTTOMRIGHT',-24,24)
  ui.gmClear:SetScript('OnClick',function() if StaticPopup_Show then StaticPopup_Show('GUILDBANKTOONS_CLEAR') end end)
  ui.gmFooter=label(page,'GameFontDisableSmall','LEFT',true); ui.gmFooter:SetPoint('BOTTOMLEFT',6,4); ui.gmFooter:SetPoint('RIGHT',-24,0)
end
function GV.refreshGM()
  local g=GV.guild()
  if not g then ui.gmInfo:SetText('Join a guild to manage its bank toons.'); ui.gmList:SetData({}); return end
  GV.readRoster()
  local gm=GV.isGM(myId())
  local set=g.managedStamp and ('Last changed by '..displayName(g.managedBy or '?')..', '..ago(g.managedStamp)..'.') or 'Nothing set yet.'
  if gm then
    ui.gmInfo:SetText('You\'re the guild master. Toons you add here show up for everyone in the guild, including guildmates who log in while you\'re offline. '..MUTED..set..'|r')
  else
    ui.gmInfo:SetText('Only the guild master can change this list; everyone in the guild sees it. '..MUTED..set..'|r')
  end
  ui.gmName:SetShown(gm); ui.gmAdd:SetShown(gm); ui.gmClear:SetShown(gm)
  local list={}
  for _,name in ipairs(GV.managedNames(g)) do list[#list+1]={name=name,snap=g.banks[nameId(name)],canEdit=gm} end
  ui.gmList:SetData(list)
  enable(ui.gmClear,#list>0)
  ui.gmEmpty:SetText(#list==0 and (gm and 'Add the guild\'s first bank toon above. Then log in on it with the addon and visit the banker once.' or 'The guild master hasn\'t added any bank toons here yet.') or '')
  local tagged={}
  for id,name in pairs(g.tagged) do if not g.managed[id] then tagged[#tagged+1]=displayName(name) end end
  table.sort(tagged)
  local footer='Officers (ranks 0-'..(g.officerRank or 1)..') approve requests; add [GBT:officers=N] to the guild info to change that.'
  if #tagged>0 then footer='Also from the guild info: '..table.concat(tagged,', ')..'.   '..footer end
  ui.gmFooter:SetText(footer)
end

-- Ledger tab --------------------------------------------------------------------------------------
-- Everything that came in (donations, and stock moved between bank toons) and went out (mailed requests),
-- newest first. Kind: in, move or out.
function GV.ledger()
  local g,list=GV.guild(),{}
  if not g then return list end
  for _,d in ipairs(GV.donationList()) do
    list[#list+1]={kind=d.status=='moved' and 'move' or 'in',from=d.by,to=d.bank,items=d.items,money=d.money or 0,
      when=d.created,status=d.status,note=d.note,updated=d.updated}
  end
  for _,r in pairs(g.requests) do
    if r.status=='mailed' then
      list[#list+1]={kind='out',from=r.bank,to=r.by,items=r.item>0 and {[r.item]=r.count} or {},money=r.item==0 and r.count*10000 or 0,
        when=r.updated,status='mailed',note=r.note,approvedBy=r.approvedBy,updated=r.updated}
    end
  end
  table.sort(list,function(a,b) if a.when~=b.when then return a.when>b.when end return a.from<b.from end)
  return list
end
local LEDGER_STATUS={received=GREEN..'Received|r',sent=YELLOW..'On its way|r',moved='|cff80b0ffMoved|r',mailed=ORANGE..'Mailed out|r'}
function GV.buildDonationsPage(page)
  ui.donFilter=segmented(page,{{'all','All'},{'in','In'},{'out','Out'},{'mine','Mine'}},
    function() return db.ui.donFilter end,function(v) db.ui.donFilter=v end,60)
  pinRight(ui.donFilter,page,60,24)
  ui.donSearch=editBox(page,200,'Search name, bank toon or item',true)
  ui.donSearch:SetPoint('TOPLEFT',8,-1); ui.donSearch:SetPoint('RIGHT',ui.donFilter[1],'LEFT',-12,0)
  ui.donSearch:HookScript('OnTextChanged',function() requestUpdate() end)
  ui.donInfo=label(page,'GameFontHighlightSmall'); ui.donInfo:SetPoint('TOPLEFT',4,-32); ui.donInfo:SetPoint('RIGHT',-24,0)
  local list=CreateFrame('Frame',nil,page); list:SetPoint('TOPLEFT',0,-52); list:SetPoint('BOTTOMRIGHT',0,26)
  ui.donList=GV.makeList(list,ITEM_ROW_H,GV.buildDonationRow,GV.drawDonationRow)
  ui.donEmpty=label(list,'GameFontDisable','CENTER',true); ui.donEmpty:SetPoint('TOPLEFT',20,-40); ui.donEmpty:SetPoint('RIGHT',-46,0)
  local export=button(page,'Export',90); export:SetPoint('BOTTOMRIGHT',-24,0)
  export:SetScript('OnClick',function() GV.openExport('ledger') end)
  local hint=label(page,'GameFontDisableSmall'); hint:SetPoint('BOTTOMLEFT',4,5); hint:SetPoint('RIGHT',export,'LEFT',-8,0)
  hint:SetText('To donate, open any mailbox and use the Donate panel beside the mail window.')
end
local function firstItem(e)
  local best
  for id,count in pairs(e.items or {}) do if not best or count>e.items[best] then best=id end end
  return best
end
function GV.buildDonationRow(row)
  itemRowParts(row)
  row.status=label(row,'GameFontHighlightSmall','RIGHT'); row.status:SetPoint('TOPRIGHT',-10,-5)
  row.when=label(row,'GameFontDisableSmall','RIGHT'); row.when:SetPoint('BOTTOMRIGHT',-10,5)
  row.name:SetPoint('RIGHT',-110,0); row.detail:SetPoint('RIGHT',-110,0)
  row:SetScript('OnEnter',function(self)
    local e=self.entry
    if not e then return end
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    local title=({['in']='Donation from ',move='Moved from ',out='Mailed out from '})[e.kind]
    GameTooltip:AddLine(title..displayName(e.from)..' to '..displayName(e.to))
    local ids={}
    for id in pairs(e.items) do ids[#ids+1]=id end
    table.sort(ids,function(a,b) return e.items[a]>e.items[b] end)
    for _,id in ipairs(ids) do
      local name,_,quality=GV.itemInfo(id)
      local c=ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
      GameTooltip:AddDoubleLine(name or ('Item #'..id),e.items[id],c and c.r or 1,c and c.g or 1,c and c.b or 1,1,1,1)
    end
    if e.money>0 then GameTooltip:AddDoubleLine('Gold',GV.money(e.money),1,1,1,1,1,1) end
    if (e.note or '')~='' then GameTooltip:AddLine('"'..e.note..'"',1,.82,0,true) end
    if e.kind=='out' and e.approvedBy then GameTooltip:AddLine('Approved by '..displayName(e.approvedBy),.6,.6,.6) end
    if e.status=='sent' then GameTooltip:AddLine('Sent '..ago(e.when)..'; '..displayName(e.to)..' hasn\'t opened it yet',.6,.6,.6)
    elseif e.kind~='out' then GameTooltip:AddLine('Received by '..displayName(e.to)..', '..ago(e.updated),.6,.6,.6) end
    GameTooltip:Show()
  end)
  row:SetScript('OnLeave',function() GameTooltip:Hide() end)
end
function GV.drawDonationRow(row,e)
  local item,icon=firstItem(e),nil
  if item then icon=select(4,GV.itemInfo(item)) end
  row.icon:SetTexture(item and (icon or QUESTION_ICON) or COIN_ICON)
  row.name:SetText(displayName(e.from)..MUTED..'  to  |r'..displayName(e.to)); row.name:SetTextColor(1,1,1)
  row.detail:SetText(GV.describeDonation(e,3))
  row.status:SetText(LEDGER_STATUS[e.status] or e.status)
  row.when:SetText(ago(e.when))
end
function GV.refreshDonations()
  ui.donFilter.refresh()
  local me,term,filter=myId(),(ui.donSearch:GetText() or ''):lower(),db.ui.donFilter
  local list,donations,donors,gold,out={},0,{},0,0
  for _,e in ipairs(GV.ledger()) do
    if now()-e.when<=WEEK then
      if e.kind=='in' then donations=donations+1; donors[nameId(e.from)]=true; gold=gold+e.money end
      if e.kind=='out' then out=out+1 end
    end
    local keep=filter=='all' or (filter=='in' and e.kind=='in') or (filter=='out' and e.kind=='out')
      or (filter=='mine' and (nameId(e.from)==me or nameId(e.to)==me))
    if keep and term~='' then
      keep=(e.from..' '..e.to..' '..(e.note or '')..' '..GV.describeDonation(e)):lower():find(term,1,true)~=nil
    end
    if keep then list[#list+1]=e end
  end
  local people=0
  for _ in pairs(donors) do people=people+1 end
  ui.donList:SetData(list)
  ui.donInfo:SetText('This week: '..YELLOW..donations..'|r donation'..(donations==1 and '' or 's')..' from '..YELLOW..people..'|r guildmate'..(people==1 and '' or 's')
    ..(gold>0 and (' ('..GV.money(gold)..')') or '')..'   ·   '..ORANGE..out..'|r mailed out   ·   '..MUTED..'Thank you, everyone!|r')
  local empty=''
  if #list==0 then
    empty=term~='' and ('Nothing matches "'..term..'".') or 'Nothing here yet.\n\nOpen any mailbox and use the Donate panel to send items or gold to a bank toon.'
  end
  ui.donEmpty:SetText(empty)
end

-- Goals tab -------------------------------------------------------------------------------------------
-- The guild bank's gold over time as a bar chart with the goals drawn across it, then each goal's progress
-- and the items the guild needs most.
function GV.buildGoalsPage(page)
  ui.goldNow=label(page,'GameFontNormalLarge'); ui.goldNow:SetPoint('TOPLEFT',6,-4)
  ui.goldChange=label(page,'GameFontHighlightSmall'); ui.goldChange:SetPoint('TOPLEFT',6,-28)
  ui.chartDays=segmented(page,{{30,'30 days'},{90,'90 days'}},function() return db.ui.chartDays end,function(v) db.ui.chartDays=v end,72)
  pinRight(ui.chartDays,page,72,24)
  local chart=CreateFrame('Frame',nil,page)
  chart:SetPoint('TOPLEFT',0,-50); chart:SetPoint('RIGHT',-24,0); chart:SetHeight(170)
  local shade=chart:CreateTexture(nil,'BACKGROUND'); shade:SetAllPoints(); shade:SetColorTexture(0,0,0,.3)
  chart.bars,chart.lines={},{}
  chart.top=label(chart,'GameFontDisableSmall'); chart.top:SetPoint('TOPLEFT',6,-4)
  chart.from=label(chart,'GameFontDisableSmall'); chart.from:SetPoint('BOTTOMLEFT',6,2)
  chart.to=label(chart,'GameFontDisableSmall','RIGHT'); chart.to:SetPoint('BOTTOMRIGHT',-6,2); chart.to:SetText('Today')
  chart.empty=label(chart,'GameFontDisable','CENTER'); chart.empty:SetPoint('CENTER')
  ui.chart=chart
  local list=CreateFrame('Frame',nil,page); list:SetPoint('TOPLEFT',0,-230); list:SetPoint('BOTTOMRIGHT')
  ui.goalList=GV.makeList(list,40,function(row)
    row.name=label(row,'GameFontHighlight'); row.name:SetPoint('TOPLEFT',10,-4); row.name:SetPoint('RIGHT',-170,0)
    row.detail=label(row,'GameFontHighlightSmall'); row.detail:SetPoint('BOTTOMLEFT',10,5); row.detail:SetPoint('RIGHT',-170,0)
    row.heading=label(row,'GameFontNormal'); row.heading:SetPoint('BOTTOMLEFT',4,6)
    row.bar=CreateFrame('StatusBar',nil,row); row.bar:SetSize(150,14); row.bar:SetPoint('RIGHT',-10,0)
    row.bar:SetStatusBarTexture('Interface\\TargetingFrame\\UI-StatusBar'); row.bar:SetMinMaxValues(0,1)
    local back=row.bar:CreateTexture(nil,'BACKGROUND'); back:SetAllPoints(); back:SetColorTexture(0,0,0,.5)
  end,function(row,e)
    row.heading:SetShown(e.heading~=nil); row.name:SetShown(e.heading==nil); row.detail:SetShown(e.heading==nil); row.bar:SetShown(e.heading==nil)
    if e.heading then row.heading:SetText(e.heading); return end
    row.name:SetText(e.name); row.detail:SetText(e.detail)
    row.bar:SetValue(math.min(1,e.progress))
    if e.progress>=1 then row.bar:SetStatusBarColor(.25,.8,.25) else row.bar:SetStatusBarColor(1,.75,.1) end
  end)
end
-- One goal's current gold and progress (0 to 1).
function GV.goalProgress(goal)
  local have=GV.currentGold(goal.toon)
  return have,(goal.target>0) and have/goal.target or 1
end
local function toonName(id)
  if not id or id=='*' then return 'All bank toons' end
  for _,bank in ipairs(GV.bankList()) do if bank.id==id then return displayName(bank.name) end end
  return id
end
function GV.goalEntries()
  local list={}
  for id,goal in pairs(GV.plan().goals) do
    local have,progress=GV.goalProgress(goal)
    list[#list+1]={id=id,goal=goal,name=goal.name..MUTED..'   '..toonName(goal.toon)..'|r',progress=progress,
      detail=GV.money(have)..MUTED..' of |r'..GV.money(goal.target)..MUTED..'   ('..math.floor(progress*100+.5)..'%)|r'}
  end
  table.sort(list,function(a,b) if a.goal.target~=b.goal.target then return a.goal.target<b.goal.target end return a.id<b.id end)
  return list
end
function GV.needEntries()
  local list={}
  for item,target in pairs(GV.plan().wants) do
    local name,_,quality,icon=GV.itemInfo(item)
    local have=GV.stockOf(item)
    list[#list+1]={item=item,target=target,icon=icon,quality=quality,name=name or ('Item #'..item),have=have,
      progress=target>0 and have/target or 1,detail=have..MUTED..' of |r'..target..(have<target and (ORANGE..'   need '..(target-have)..'|r') or (GREEN..'   enough|r'))}
  end
  table.sort(list,function(a,b) if a.progress~=b.progress then return a.progress<b.progress end return a.name<b.name end)
  return list
end
function GV.refreshChart()
  local chart,days=ui.chart,db.ui.chartDays or 30
  local series=GV.goldSeries(days,'*')
  local top,known=0,false
  for _,v in ipairs(series) do if v then top=math.max(top,v); known=true end end
  local goals={}
  for _,goal in pairs(GV.plan().goals) do
    if goal.toon=='*' then goals[#goals+1]=goal; top=math.max(top,goal.target) end
  end
  top=math.max(top,10000)*1.1
  local width=(chart:GetWidth() or 600)-12
  local height=(chart:GetHeight() or 170)-34
  local step=width/days
  for i=1,days do
    local bar=chart.bars[i]
    if not bar then
      bar=CreateFrame('Button',nil,chart)
      bar.fill=bar:CreateTexture(nil,'ARTWORK'); bar.fill:SetAllPoints()
      bar:SetScript('OnEnter',function(self)
        GameTooltip:SetOwner(self,'ANCHOR_TOP')
        GameTooltip:AddLine(self.day)
        GameTooltip:AddLine(GV.money(self.value),1,1,1)
        GameTooltip:Show()
      end)
      bar:SetScript('OnLeave',function() GameTooltip:Hide() end)
      chart.bars[i]=bar
    end
    local v=series[i]
    bar:ClearAllPoints()
    bar:SetPoint('BOTTOMLEFT',6+(i-1)*step,16)
    bar:SetWidth(math.max(2,step-2))
    bar:SetShown(v and true or false)
    if v then
      bar:SetHeight(math.max(1,v/top*height))
      bar.value=v
      bar.day=date and date('%b %d',now()-(days-i)*86400) or ('Day '..i)
      bar.fill:SetColorTexture(1,.78,.2,i==days and .9 or .55)
    end
  end
  for i=days+1,#chart.bars do chart.bars[i]:Hide() end
  for i,goal in ipairs(goals) do
    local line=chart.lines[i]
    if not line then
      line=chart:CreateTexture(nil,'OVERLAY'); line:SetHeight(1)
      line.text=label(chart,'GameFontHighlightSmall','RIGHT')
      chart.lines[i]=line
    end
    local y=16+goal.target/top*height
    line:ClearAllPoints(); line:SetPoint('BOTTOMLEFT',6,y); line:SetPoint('RIGHT',chart,'RIGHT',-6,0)
    line:SetColorTexture(.4,1,.4,.7); line:Show()
    line.text:ClearAllPoints(); line.text:SetPoint('BOTTOMRIGHT',chart,'BOTTOMRIGHT',-8,y+2)
    line.text:SetText(goal.name..'  '..GV.money(goal.target)); line.text:Show()
  end
  for i=#goals+1,#chart.lines do chart.lines[i]:Hide(); chart.lines[i].text:Hide() end
  chart.top:SetText(GV.money(math.floor(top)))
  chart.from:SetText(days..' days ago')
  chart.empty:SetText(known and '' or 'No gold history yet. It builds up as bank toons report in.')
end
function GV.refreshGoals()
  ui.chartDays.refresh()
  local now7=GV.goldSeries(8,'*')
  local current=GV.currentGold('*')
  ui.goldNow:SetText('Guild bank gold: '..GV.money(current))
  local week=now7[1]
  if week then
    local change=current-week
    ui.goldChange:SetText((change>=0 and (GREEN..'+') or (ORANGE..'-'))..GV.money(math.abs(change))..'|r'..MUTED..' in the last 7 days|r')
  else
    ui.goldChange:SetText(MUTED..'Change over the last 7 days shows once there\'s a week of history.|r')
  end
  GV.refreshChart()
  local list={}
  local goals,needs=GV.goalEntries(),GV.needEntries()
  list[#list+1]={heading='Goals'}
  for _,e in ipairs(goals) do list[#list+1]=e end
  if #goals==0 then list[#list+1]={name=MUTED..'No goals yet.|r',detail=MUTED..'Officers add them on the Guild tab.|r',progress=0} end
  list[#list+1]={heading='What the guild needs'}
  for i,e in ipairs(needs) do if i<=8 then list[#list+1]=e end end
  if #needs==0 then list[#list+1]={name=MUTED..'No wanted items yet.|r',detail=MUTED..'Officers add them on the Guild tab.|r',progress=0} end
  ui.goalList:SetData(list)
end

-- Guild tab: goal, need and rule editors ------------------------------------------------------------------
-- Everyone can see these; only officers and the guild master can change them.
local function canPlan() return GV.isOfficer(myId()) end
local function readOnly(info)
  info:SetText(canPlan() and 'Changes go to everyone in the guild.' or 'Only officers and the guild master can change these; everyone sees them.')
end
function GV.buildGoalEditor(page)
  ui.goalInfo=label(page,'GameFontHighlightSmall','LEFT',true); ui.goalInfo:SetPoint('TOPLEFT',6,-2); ui.goalInfo:SetPoint('RIGHT',-24,0)
  ui.goalName=editBox(page,200,'Goal, e.g. Raid consumables'); ui.goalName:SetPoint('TOPLEFT',12,-28); ui.goalName:SetMaxLetters(40)
  ui.goalGold=editBox(page,80,'Gold'); ui.goalGold:SetPoint('LEFT',ui.goalName,'RIGHT',10,0); ui.goalGold:SetNumeric(true); ui.goalGold:SetMaxLetters(7)
  ui.goalToon=button(page,'For: All bank toons',170); ui.goalToon:SetPoint('LEFT',ui.goalGold,'RIGHT',10,0)
  ui.goalToon:SetScript('OnClick',function()
    local ids={'*'}
    for _,bank in ipairs(GV.bankList()) do ids[#ids+1]=bank.id end
    local at=1
    for i,id in ipairs(ids) do if id==(ui.goalToon.toon or '*') then at=i end end
    ui.goalToon.toon=ids[at%#ids+1]; requestUpdate()
  end)
  ui.goalAdd=button(page,'Add goal',100); ui.goalAdd:SetPoint('LEFT',ui.goalToon,'RIGHT',10,0)
  ui.goalAdd:SetScript('OnClick',function()
    local name,gold=(ui.goalName:GetText() or ''):gsub('^%s+',''):gsub('%s+$',''),tonumber(ui.goalGold:GetText() or '')
    if name=='' or not gold or gold<1 then log('Give the goal a name and an amount of gold.',true); return end
    local p=GV.copyPlan()
    local id=tostring(now()%100000)..math.random(10,99)
    p.goals[id]={name=planClean(name),target=gold*10000,toon=ui.goalToon.toon or '*'}
    if GV.setPlan(p) then ui.goalName:SetText(''); ui.goalGold:SetText('') end
  end)
  local list=CreateFrame('Frame',nil,page); list:SetPoint('TOPLEFT',0,-60); list:SetPoint('BOTTOMRIGHT')
  ui.goalEditList=GV.makeList(list,40,function(row)
    row.name=label(row,'GameFontHighlight'); row.name:SetPoint('TOPLEFT',10,-4); row.name:SetPoint('RIGHT',-100,0)
    row.detail=label(row,'GameFontHighlightSmall'); row.detail:SetPoint('BOTTOMLEFT',10,5); row.detail:SetPoint('RIGHT',-100,0)
    row.remove=button(row,'Remove',80); row.remove:SetHeight(20); row.remove:SetPoint('RIGHT',-8,0)
    row.remove:SetScript('OnClick',function(self)
      local p=GV.copyPlan(); p.goals[self:GetParent().entry.id]=nil; GV.setPlan(p)
    end)
  end,function(row,e)
    row.name:SetText(e.name); row.detail:SetText(e.detail); row.remove:SetShown(canPlan())
  end)
  ui.goalEditEmpty=label(list,'GameFontDisable','CENTER',true); ui.goalEditEmpty:SetPoint('TOPLEFT',20,-30); ui.goalEditEmpty:SetPoint('RIGHT',-46,0)
end
function GV.refreshGoalEditor()
  readOnly(ui.goalInfo)
  for _,w in ipairs({ui.goalName,ui.goalGold,ui.goalToon,ui.goalAdd}) do w:SetShown(canPlan()) end
  ui.goalToon:SetText('For: '..toonName(ui.goalToon.toon))
  local list=GV.goalEntries()
  ui.goalEditList:SetData(list)
  ui.goalEditEmpty:SetText(#list==0 and 'No goals yet. Gold goals show on the Goals tab with a chart, and on Discord.' or '')
end
-- Fills the Needs editor's item box when an item is shift-clicked while it has the focus.
function GV.hookItemBox()
  local function fill(text)
    if ui.needItem and ui.needItem:IsShown() and ui.needItem.HasFocus and ui.needItem:HasFocus() and type(text)=='string' then
      ui.needItem:SetText(text)
    end
  end
  if not hooksecurefunc then return end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil,'InsertLink',fill)
  elseif ChatEdit_InsertLink then hooksecurefunc('ChatEdit_InsertLink',fill) end
end
function GV.setWant(item,count)
  local p=GV.copyPlan()
  p.wants[item]=(count and count>0) and count or nil
  return GV.setPlan(p)
end
function GV.buildNeedEditor(page)
  ui.needInfo=label(page,'GameFontHighlightSmall','LEFT',true); ui.needInfo:SetPoint('TOPLEFT',6,-2); ui.needInfo:SetPoint('RIGHT',-24,0)
  ui.needItem=editBox(page,240,'Shift-click an item, or type its ID'); ui.needItem:SetPoint('TOPLEFT',12,-28)
  ui.needCount=editBox(page,70,'How many'); ui.needCount:SetPoint('LEFT',ui.needItem,'RIGHT',10,0); ui.needCount:SetNumeric(true); ui.needCount:SetMaxLetters(5)
  ui.needAdd=button(page,'Add or update',120); ui.needAdd:SetPoint('LEFT',ui.needCount,'RIGHT',10,0)
  ui.needAdd:SetScript('OnClick',function()
    local text=ui.needItem:GetText() or ''
    local item=tonumber(text:match('item:(%d+)') or text:match('^%s*(%d+)%s*$'))
    local count=tonumber(ui.needCount:GetText() or '')
    if not item or not count then log('Shift-click an item into the box (or type its ID) and say how many the guild wants.',true); return end
    if GV.setWant(item,count) then ui.needItem:SetText(''); ui.needCount:SetText('') end
  end)
  local list=CreateFrame('Frame',nil,page); list:SetPoint('TOPLEFT',0,-60); list:SetPoint('BOTTOMRIGHT')
  ui.needEditList=GV.makeList(list,ITEM_ROW_H,function(row)
    itemRowParts(row)
    row.remove=button(row,'Remove',80); row.remove:SetHeight(20); row.remove:SetPoint('RIGHT',-8,0)
    row.name:SetPoint('RIGHT',-100,0); row.detail:SetPoint('RIGHT',-100,0)
    row.remove:SetScript('OnClick',function(self) GV.setWant(self:GetParent().entry.item,0) end)
  end,function(row,e)
    row.icon:SetTexture(e.icon or QUESTION_ICON)
    row.name:SetText(e.name); qualityColor(row.name,e.quality)
    row.detail:SetText(e.detail); row.remove:SetShown(canPlan())
  end)
  ui.needEditEmpty=label(list,'GameFontDisable','CENTER',true); ui.needEditEmpty:SetPoint('TOPLEFT',20,-30); ui.needEditEmpty:SetPoint('RIGHT',-46,0)
end
function GV.refreshNeedEditor()
  readOnly(ui.needInfo)
  for _,w in ipairs({ui.needItem,ui.needCount,ui.needAdd}) do w:SetShown(canPlan()) end
  local list=GV.needEntries()
  ui.needEditList:SetData(list)
  ui.needEditEmpty:SetText(#list==0 and 'No wanted items yet. They show on the Bank tab under Needs, in the Donate panel, and on Discord. Officers can also Alt-click an item on the Bank tab.' or '')
end
local RULE_FIELDS={
  {'limit','Daily limit per member','Most items one member can request in 24 hours. 0 means no limit.'},
  {'autoMax','Approve small requests automatically','Requests of up to this many items are approved without waiting. 0 turns it off.'},
  {'autoRank','...for ranks 0 to','Which ranks get automatic approval (0 is the guild master; higher numbers are lower ranks).'},
}
function GV.buildRulesEditor(page)
  ui.ruleInfo=label(page,'GameFontHighlightSmall','LEFT',true); ui.ruleInfo:SetPoint('TOPLEFT',6,-2); ui.ruleInfo:SetPoint('RIGHT',-24,0)
  ui.ruleBoxes={}
  local y=-30
  for _,field in ipairs(RULE_FIELDS) do
    local name=label(page,'GameFontHighlight'); name:SetPoint('TOPLEFT',10,y); name:SetText(field[2])
    local box=editBox(page,60,'0'); box:SetPoint('TOPLEFT',290,y+3); box:SetNumeric(true); box:SetMaxLetters(4)
    local note=label(page,'GameFontDisableSmall','LEFT',true); note:SetPoint('TOPLEFT',10,y-17); note:SetPoint('RIGHT',-24,0); note:SetText(field[3])
    box.rule=field[1]
    ui.ruleBoxes[#ui.ruleBoxes+1]=box
    y=y-48
  end
  ui.ruleGold=GV.make('CheckButton',page,{'UICheckButtonTemplate','InterfaceOptionsCheckButtonTemplate'})
  ui.ruleGold:SetSize(26,26); ui.ruleGold:SetPoint('TOPLEFT',6,y)
  local caption=label(page,'GameFontHighlight'); caption:SetPoint('LEFT',ui.ruleGold,'RIGHT',4,1); caption:SetText('Members can request gold')
  ui.ruleSave=button(page,'Save rules',120); ui.ruleSave:SetPoint('TOPLEFT',10,y-40)
  ui.ruleSave:SetScript('OnClick',function()
    local p=GV.copyPlan()
    for _,box in ipairs(ui.ruleBoxes) do p.rules[box.rule]=tonumber(box:GetText() or '') or 0 end
    p.rules.gold=ui.ruleGold:GetChecked() and 1 or 0
    if GV.setPlan(p) then ui.rulesDirty=false; log('Saved the guild\'s request rules.',true) end
  end)
  for _,box in ipairs(ui.ruleBoxes) do box:HookScript('OnTextChanged',function(_,user) if user then ui.rulesDirty=true end end) end
  ui.ruleGold:HookScript('OnClick',function() ui.rulesDirty=true end)
end
function GV.refreshRulesEditor()
  readOnly(ui.ruleInfo)
  local edit=canPlan()
  ui.ruleSave:SetShown(edit)
  if edit then ui.ruleGold:Enable() else ui.ruleGold:Disable() end
  -- Don't overwrite what an officer is typing.
  if ui.rulesDirty then return end
  for _,box in ipairs(ui.ruleBoxes) do
    box:SetText(tostring(GV.rule(box.rule)))
    if edit then box:Enable() else box:Disable() end
  end
  ui.ruleGold:SetChecked(GV.rule('gold')==1)
end
function GV.buildGuildPage(page)
  ui.guildNav=segmented(page,{{'toons','Bank toons'},{'goals','Goals'},{'needs','Needs'},{'rules','Rules'}},
    function() return db.ui.guildSub end,function(v) db.ui.guildSub=v end,96)
  ui.guildNav[1]:SetPoint('TOPLEFT',4,0)
  ui.guildSubs={}
  for _,key in ipairs({'toons','goals','needs','rules'}) do
    local sub=CreateFrame('Frame',nil,page); sub:SetPoint('TOPLEFT',0,-32); sub:SetPoint('BOTTOMRIGHT')
    ui.guildSubs[key]=sub
  end
  GV.buildGMPage(ui.guildSubs.toons)
  GV.buildGoalEditor(ui.guildSubs.goals)
  GV.buildNeedEditor(ui.guildSubs.needs)
  GV.buildRulesEditor(ui.guildSubs.rules)
end
function GV.refreshGuild()
  ui.guildNav.refresh()
  local sub=ui.guildSubs[db.ui.guildSub] and db.ui.guildSub or 'toons'
  for key,frame in pairs(ui.guildSubs) do frame:SetShown(key==sub) end
  if sub=='goals' then GV.refreshGoalEditor() elseif sub=='needs' then GV.refreshNeedEditor()
  elseif sub=='rules' then GV.refreshRulesEditor() else GV.refreshGM() end
end

-- Export ----------------------------------------------------------------------------------------------
-- Addons can't save files or use the clipboard, so the export is text in a box, selected, ready for Ctrl+C.
local function csvField(value)
  value=tostring(value==nil and '' or value)
  if value:find('[,"\n]') then value='"'..value:gsub('"','""')..'"' end
  return value
end
local function csvLine(fields)
  local out={}
  for i,v in ipairs(fields) do out[i]=csvField(v) end
  return table.concat(out,',')
end
local function day(stamp) return date and date('%Y-%m-%d',stamp) or tostring(stamp) end
local function plainMoney(copper)
  copper=math.floor(copper or 0)
  return math.floor(copper/10000)..'g '..(math.floor(copper/100)%100)..'s '..(copper%100)..'c'
end
function GV.exportText(kind,format)
  local banks,lines=GV.bankList(),{}
  local csv=format=='csv'
  if kind=='inventory' then
    local rows=GV.itemRows(nil,'all','','name')
    local wants=GV.plan().wants
    if csv then
      local head={'Item ID','Item','Quality','Available','Reserved','Total'}
      for _,bank in ipairs(banks) do head[#head+1]=displayName(bank.name) end
      head[#head+1]='Guild wants'
      lines[1]=csvLine(head)
      for _,e in ipairs(rows) do
        local held={}
        for _,t in ipairs(e.toons) do held[t.id]=t.bags+t.bank end
        local fields={e.id,e.name,e.quality,e.available,e.reserved,e.total}
        for _,bank in ipairs(banks) do fields[#fields+1]=held[bank.id] or 0 end
        fields[#fields+1]=wants[e.id] or ''
        lines[#lines+1]=csvLine(fields)
      end
    else
      lines[1]='Guild bank, '..day(now())..' ('..plainMoney(GV.currentGold('*'))..')'
      for _,e in ipairs(rows) do
        local parts={}
        for _,t in ipairs(e.toons) do parts[#parts+1]=displayName(t.name)..' '..(t.bags+t.bank) end
        lines[#lines+1]=e.name..': '..e.available..((e.reserved>0) and (' ('..e.reserved..' reserved)') or '')..' - '..table.concat(parts,', ')
      end
    end
  elseif kind=='ledger' then
    if csv then lines[1]=csvLine({'Date','Type','From','To','Items','Gold','Status','Note'}) end
    for _,e in ipairs(GV.ledger()) do
      local items=GV.describeDonation({items=e.items,money=0})
      if csv then
        lines[#lines+1]=csvLine({day(e.when),({['in']='Donation',move='Move',out='Withdrawal'})[e.kind],displayName(e.from),displayName(e.to),
          items=='nothing' and '' or items,e.money>0 and plainMoney(e.money) or '',e.status,e.note or ''})
      else
        local what=GV.describeDonation({items=e.items,money=0})
        if what=='nothing' then what='' end
        if e.money>0 then what=(what~='' and (what..' and ') or '')..plainMoney(e.money) end
        local verb=({['in']=' donated ',move=' moved ',out=' mailed out '})[e.kind]
        lines[#lines+1]=day(e.when)..': '..displayName(e.from)..verb..what..' to '..displayName(e.to)..(e.status=='sent' and ' (on its way)' or '')
      end
    end
  else
    local series={}
    for _,bank in ipairs(banks) do series[#series+1]=GV.goldSeries(90,bank.id) end
    local total=GV.goldSeries(90,'*')
    if csv then
      local head={'Date'}
      for _,bank in ipairs(banks) do head[#head+1]=displayName(bank.name) end
      head[#head+1]='Total'
      lines[1]=csvLine(head)
    end
    for i=1,90 do
      if total[i] then
        local date_=day(now()-(90-i)*86400)
        if csv then
          local fields={date_}
          for b=1,#banks do fields[#fields+1]=series[b][i] and math.floor(series[b][i]/10000) or '' end
          fields[#fields+1]=math.floor(total[i]/10000)
          lines[#lines+1]=csvLine(fields)
        else
          lines[#lines+1]=date_..': '..plainMoney(total[i])
        end
      end
    end
  end
  return table.concat(lines,'\n')
end
function GV.buildExportDialog()
  local d=GV.make('Frame',UIParent,{'BasicFrameTemplateWithInset'},'GuildBankToonsExport')
  d:SetSize(600,440); d:SetPoint('CENTER'); d:SetFrameStrata('DIALOG'); d:SetToplevel(true); d:SetClampedToScreen(true)
  d:SetMovable(true); d:EnableMouse(true); d:RegisterForDrag('LeftButton')
  d:SetScript('OnDragStart',d.StartMoving); d:SetScript('OnDragStop',d.StopMovingOrSizing)
  table.insert(UISpecialFrames,'GuildBankToonsExport')
  local title=d.TitleText or label(d,'GameFontHighlight','CENTER')
  if not d.TitleText then title:SetPoint('TOP',0,-6) end
  title:SetText('Export')
  d.kind=segmented(d,{{'inventory','Inventory'},{'ledger','Ledger'},{'gold','Gold history'}},function() return db.ui.exportKind end,function(v) db.ui.exportKind=v end,104)
  d.kind[1]:SetPoint('TOPLEFT',14,-32)
  d.format=segmented(d,{{'csv','CSV'},{'text','Text'}},function() return db.ui.exportFormat end,function(v) db.ui.exportFormat=v end,60)
  d.format[1]:SetPoint('TOPRIGHT',d,'TOPRIGHT',-(16+62),-32)
  local scroll=GV.make('ScrollFrame',d,{'UIPanelScrollFrameTemplate'},'GuildBankToonsExportScroll')
  scroll:SetPoint('TOPLEFT',16,-64); scroll:SetPoint('BOTTOMRIGHT',-34,40)
  local box=CreateFrame('EditBox',nil,scroll)
  box:SetMultiLine(true); box:SetAutoFocus(false); box:SetWidth(540); box:SetMaxLetters(0)
  box:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  box:SetScript('OnEscapePressed',function() d:Hide() end)
  -- Read-only: typing puts the export back, still selected.
  box:SetScript('OnTextChanged',function(self,user) if user then self:SetText(d.text or ''); self:HighlightText() end end)
  scroll:SetScrollChild(box)
  d.box=box
  local hint=label(d,'GameFontDisableSmall'); hint:SetPoint('BOTTOMLEFT',16,14)
  hint:SetText('Press Ctrl+C to copy, then paste into a spreadsheet, Discord or a text file.')
  ui.export=d
end
function GV.refreshExport()
  local d=ui.export
  if not d or not d:IsShown() then return end
  d.kind.refresh(); d.format.refresh()
  local wanted=db.ui.exportKind..'|'..db.ui.exportFormat
  if d.shownKey==wanted then return end
  d.shownKey=wanted
  d.text=GV.exportText(db.ui.exportKind,db.ui.exportFormat)
  d.box:SetText(d.text); d.box:SetFocus(); d.box:HighlightText()
end
function GV.openExport(kind)
  if not ui.export then GV.buildExportDialog() end
  db.ui.exportKind=kind or db.ui.exportKind
  ui.export.shownKey=nil
  ui.export:Show()
  GV.refreshExport()
end

-- Request gold ----------------------------------------------------------------------------------------
function GV.openGoldRequest()
  local g=GV.guild()
  if not g then return end
  if GV.rule('gold')==0 then log('The guild isn\'t taking gold requests right now.',true); return end
  local e={id=0,name='Gold',icon=COIN_ICON,quality=1,available=0,reserved=GV.reservedGold(),unit='g',toons={}}
  for _,bank in ipairs(GV.bankList()) do
    local snap=g.banks[bank.id]
    if snap then
      local n=GV.available(bank.id,0)
      e.toons[#e.toons+1]={id=bank.id,name=snap.owner or bank.name,available=n}
      e.available=e.available+n
    end
  end
  table.sort(e.toons,function(a,b) return a.available>b.available end)
  GV.openRequestDialog(e)
end
function GV.reservedGold()
  local n=0
  for _,bank in ipairs(GV.bankList()) do n=n+(GV.reserved(bank.id)[0] or 0) end
  return n
end

-- Donate: add what the guild needs --------------------------------------------------------------------------
-- Attaches wanted items from your bags, up to what the guild still needs of each.
function GV.neededInBags()
  local bags,out=GV.scanContainers(GV.bagIds()),{}
  for item in pairs(GV.plan().wants) do
    local short=GV.shortfall(item)
    if short>0 and (bags[item] or 0)>0 then out[#out+1]={item=item,count=math.min(short,bags[item])} end
  end
  table.sort(out,function(a,b) return a.count>b.count end)
  return out
end
function GV.addNeededItems()
  local added={}
  for _,need in ipairs(GV.neededInBags()) do
    local ok,err=GV.attachItems(need.item,need.count)
    if not ok then log(err,true); break end
    added[#added+1]=need.count..'x '..(GV.itemInfo(need.item) or ('item #'..need.item))
  end
  if #added>0 then log('Attached what the guild needs: '..table.concat(added,', ')..'.',true)
  else log('Nothing in your bags is on the guild\'s wanted list right now.',true) end
  requestUpdate()
end

-- Frame -------------------------------------------------------------------------------------------
local function screenSize()
  local w=UIParent and UIParent.GetWidth and UIParent:GetWidth()
  local h=UIParent and UIParent.GetHeight and UIParent:GetHeight()
  return w or 1280,h or 800
end
function GV.saveWindow()
  local point,_,relative,x,y=window:GetPoint()
  if point then db.ui.point={point,relative,x,y} end
  local w,h=window:GetSize()
  if w and h then db.ui.w,db.ui.h=math.floor(w+.5),math.floor(h+.5) end
end
-- Restores the saved place, size and scale; the default fits small screens too.
function GV.placeWindow()
  local s=db.ui
  local sw,sh=screenSize()
  window:ClearAllPoints()
  window:SetScale(s.scale or 1)
  window:SetSize(s.w or math.min(860,sw-60),s.h or math.min(580,sh-160))
  if s.point then window:SetPoint(s.point[1],UIParent,s.point[2],s.point[3],s.point[4])
  else window:SetPoint('CENTER',UIParent,'CENTER',0,40) end
end
function GV.buildWindow()
  local f=GV.make('Frame',UIParent,{'BasicFrameTemplateWithInset'},'GuildBankToonsFrame')
  window=f
  f:SetFrameStrata('HIGH'); f:SetToplevel(true); f:SetClampedToScreen(true)
  f:SetMovable(true); f:SetResizable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton')
  if f.SetResizeBounds then f:SetResizeBounds(780,440,1600,1200)
  elseif f.SetMinResize then f:SetMinResize(780,440); f:SetMaxResize(1600,1200) end
  f:SetScript('OnDragStart',f.StartMoving)
  f:SetScript('OnDragStop',function(self) self:StopMovingOrSizing(); GV.saveWindow() end)
  f:SetScript('OnSizeChanged',function() requestUpdate() end)
  f:SetScript('OnShow',function() requestUpdate() end)
  table.insert(UISpecialFrames,'GuildBankToonsFrame')
  local title=f.TitleText or label(f,'GameFontHighlight','CENTER')
  if not f.TitleText then title:SetPoint('TOP',0,-6) end
  title:SetText('Forever - Guild Bank Toons')
  local grip=CreateFrame('Button',nil,f)
  grip:SetSize(16,16); grip:SetPoint('BOTTOMRIGHT',-4,4); grip:SetFrameLevel((f:GetFrameLevel() or 0)+10)
  grip:SetNormalTexture('Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up')
  grip:SetHighlightTexture('Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight')
  grip:SetPushedTexture('Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down')
  grip:SetScript('OnMouseDown',function() f:StartSizing('BOTTOMRIGHT') end)
  grip:SetScript('OnMouseUp',function() f:StopMovingOrSizing(); GV.saveWindow(); requestUpdate() end)
  -- Tabs hang under the window like the character window's.
  ui.tabs={}
  for i,tab in ipairs(TABS) do
    local b,template=GV.make('Button',f,{'PanelTabButtonTemplate','CharacterFrameTabButtonTemplate'},'GuildBankToonsFrameTab'..i)
    b:SetID(i); b.key=tab.key; b:SetText(tab.label)
    if i==1 then b:SetPoint('TOPLEFT',f,'BOTTOMLEFT',12,2)
    else b:SetPoint('LEFT',ui.tabs[i-1],'RIGHT',template=='CharacterFrameTabButtonTemplate' and -16 or 3,0) end
    b:SetScript('OnClick',function(self)
      if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound,SOUNDKIT.IG_CHARACTER_INFO_TAB) end
      GV.showTab(self.key)
    end)
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize,b,0) end
    ui.tabs[i]=b
  end
  f.Tabs=ui.tabs
  if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs,f,#ui.tabs) end
  ui.pages={}
  for _,tab in ipairs(TABS) do
    local page=CreateFrame('Frame',nil,f)
    page:SetPoint('TOPLEFT',12,-32); page:SetPoint('BOTTOMRIGHT',-10,10)
    page:Hide()
    ui.pages[tab.key]=page
  end
  GV.buildItemsPage(ui.pages.items)
  GV.buildRequestsPage(ui.pages.requests)
  GV.buildDonationsPage(ui.pages.donations)
  GV.buildGoalsPage(ui.pages.goals)
  GV.buildSettingsPage(ui.pages.settings)
  GV.buildGuildPage(ui.pages.gm)
  GV.placeWindow()
  f:Hide()
end
function GV.showTab(key)
  if not ui.pages[key] then key='items' end
  db.ui.mode=key
  for i,b in ipairs(ui.tabs) do
    if b.key==key and PanelTemplates_SetTab then pcall(PanelTemplates_SetTab,window,i) end
  end
  for k,page in pairs(ui.pages) do page:SetShown(k==key) end
  requestUpdate()
end
function GV.open(tab)
  if not window then GV.buildWindow() end
  window:Show()
  GV.showTab(tab or db.ui.mode)
end
function GV.toggle()
  if window and window:IsShown() then window:Hide() else GV.open() end
end
function GuildBankToons_OnCompartmentClick() GV.toggle() end
function GV.refresh()
  updatePending=false; sinceUpdate=0
  GV.checkStock()
  GV.refreshMailHelper()
  GV.refreshDonatePanel()
  GV.refreshExport()
  if not window or not window:IsShown() then return end
  local open=GV.guild() and GV.activeRequestCount() or 0
  local tab=ui.tabs[2]
  local text=open>0 and ('Requests ('..open..')') or 'Requests'
  if tab:GetText()~=text then
    tab:SetText(text)
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize,tab,0) end
  end
  local mode=db.ui.mode
  if mode=='requests' then GV.refreshRequests()
  elseif mode=='donations' then GV.refreshDonations()
  elseif mode=='goals' then GV.refreshGoals()
  elseif mode=='settings' then GV.refreshSettings()
  elseif mode=='gm' then GV.refreshGuild()
  else GV.refreshItems() end
end

-- Minimap button and the game's AddOns options ---------------------------------------------------------
function GV.buildMinimapButton()
  if ui.minimap or not Minimap then return end
  local b=CreateFrame('Button','GuildBankToonsMinimapButton',Minimap)
  b:SetSize(31,31); b:SetFrameStrata('MEDIUM'); b:SetFrameLevel(8)
  b:SetHighlightTexture('Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight')
  local back=b:CreateTexture(nil,'BACKGROUND'); back:SetSize(20,20); back:SetPoint('TOPLEFT',7,-5)
  back:SetTexture('Interface\\Minimap\\UI-Minimap-Background')
  local icon=b:CreateTexture(nil,'ARTWORK'); icon:SetSize(17,17); icon:SetPoint('TOPLEFT',7,-6)
  icon:SetTexture('Interface\\Icons\\INV_Misc_Bag_10_Blue')
  local border=b:CreateTexture(nil,'OVERLAY'); border:SetSize(53,53); border:SetPoint('TOPLEFT')
  border:SetTexture('Interface\\Minimap\\MiniMap-TrackingBorder')
  b:RegisterForDrag('LeftButton')
  b:SetScript('OnDragStart',function(self) self:SetScript('OnUpdate',GV.dragMinimap) end)
  b:SetScript('OnDragStop',function(self) self:SetScript('OnUpdate',nil) end)
  b:SetScript('OnClick',function() GV.toggle() end)
  b:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_LEFT')
    GameTooltip:AddLine('Guild Bank Toons')
    local open=GV.guild() and GV.activeRequestCount() or 0
    if open>0 then GameTooltip:AddLine(open..' active request'..(open==1 and '' or 's'),1,1,1) end
    GameTooltip:AddLine('Click to open. Drag to move.',.6,.6,.6)
    GameTooltip:Show()
  end)
  b:SetScript('OnLeave',function() GameTooltip:Hide() end)
  ui.minimap=b
  GV.placeMinimap()
end
function GV.dragMinimap()
  local mx,my=Minimap:GetCenter()
  local x,y=GetCursorPosition()
  local scale=Minimap:GetEffectiveScale()
  local atan2=math.atan2 or math.atan
  db.ui.minimapAngle=math.deg(atan2(y/scale-my,x/scale-mx))
  GV.placeMinimap()
end
function GV.placeMinimap()
  local b=ui.minimap
  if not b then return end
  local angle=math.rad(db.ui.minimapAngle or 205)
  local radius=((Minimap:GetWidth() or 140)/2)+10
  b:ClearAllPoints(); b:SetPoint('CENTER',Minimap,'CENTER',math.cos(angle)*radius,math.sin(angle)*radius)
  b:SetShown(settings().minimap and true or false)
end
-- A page under the game's Options > AddOns that opens the Settings tab.
function GV.registerOptions()
  local panel=CreateFrame('Frame')
  panel.name='Forever - Guild Bank Toons'
  local title=label(panel,'GameFontNormalLarge'); title:SetPoint('TOPLEFT',16,-16); title:SetText(panel.name)
  local text=label(panel,'GameFontHighlight','LEFT',true); text:SetPoint('TOPLEFT',16,-46); text:SetPoint('RIGHT',-16,0)
  text:SetText('All of the addon\'s settings are on the Settings tab of its window. The guild master manages bank toons on the Guild Master tab.')
  local open=button(panel,'Open settings',150); open:SetPoint('TOPLEFT',16,-84)
  open:SetScript('OnClick',function()
    for _,frame in ipairs({SettingsPanel,InterfaceOptionsFrame}) do
      if frame and frame:IsShown() and HideUIPanel then HideUIPanel(frame) end
    end
    GV.open('settings')
  end)
  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel,panel.name))
  elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
  end
end

-- Item tooltips: "Guild bank (Bankalt): 40" on any item a bank character holds.
function GV.addTooltipLines(tooltip,id,show)
  if not db or ui.ownTooltip or not settings().tooltips or type(id)~='number' or isSecret(id) then return end
  local g=GV.guild()
  if not g then return end
  local added=false
  for bankId,snap in pairs(g.banks) do
    local count=(snap.bags and snap.bags[id] or 0)+(snap.bank and snap.bank[id] or 0)
    if count>0 and GV.isBank(bankId) then
      local reserved=GV.reserved(bankId)[id] or 0
      local text=reserved>0 and (math.max(0,count-reserved)..' |cffff8040('..reserved..' reserved)|r') or count
      tooltip:AddDoubleLine('|cffd8aa55Guild bank|r ('..displayName(snap.owner)..')',text,1,1,1,1,1,1)
      added=true
    end
  end
  if added and show then tooltip:Show() end
end
function GV.hookTooltips()
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item,function(tooltip,data)
      if tooltip~=GameTooltip and tooltip~=ItemRefTooltip then return end
      if type(data)=='table' and not isSecret(data.id) then GV.addTooltipLines(tooltip,data.id) end
    end)
    return
  end
  for _,tooltip in ipairs({GameTooltip,ItemRefTooltip}) do
    if tooltip and tooltip.HookScript then
      tooltip:HookScript('OnTooltipSetItem',function(self)
        local _,link=self:GetItem()
        local id=type(link)=='string' and not isSecret(link) and tonumber(link:match('item:(%d+)'))
        GV.addTooltipLines(self,id,true)
      end)
    end
  end
end

-- Slash commands ---------------------------------------------------------------------------------
function GV.status()
  local g=GV.guild()
  log(string.format('v%s; guild=%s; you=%s%s; sent=%d received=%d rejected=%d queued=%d',VERSION,tostring(guildKey()),key(),
    GV.isBank(myId()) and ' (bank character)' or '',sent,received,rejected,GV.queued()),true)
  if g then
    log(string.format('  %d active requests; officers are ranks 0-%d%s',GV.activeRequestCount(),g.officerRank or 1,
      GV.isApprover(myId()) and ' (you can approve)' or ''),true)
  end
  for _,bank in ipairs(GV.bankList()) do
    local snap=g.banks[bank.id]
    local source=(g.managed[bank.id] and 'set by guild master') or (g.tagged[bank.id] and 'guild info') or '/gbt add'
    if snap then
      local count=#GV.entries(snap)
      log(string.format('  %s (%s): %d stacks, updated %s%s',displayName(bank.name),source,count,ago(snap.stamp),snap.via and (' via '..snap.via) or ''),true)
    else
      log('  '..displayName(bank.name)..' ('..source..'): no copy yet',true)
    end
  end
end
SLASH_GUILDBANKTOONS1='/guildbanktoons'
SLASH_GUILDBANKTOONS2='/gbt'
SlashCmdList.GUILDBANKTOONS=function(input)
  local command,arg=(input or ''):match('^%s*(%S*)%s*(.-)%s*$')
  command=(command or ''):lower()
  if not db then return end
  local g=GV.guild()
  if command=='' then GV.toggle()
  elseif command=='sync' then GV.syncAll(); GV.askManaged(); GV.askPlan(); log('Asked the guild for the latest bank contents.',true)
  elseif command=='status' then GV.status()
  elseif command=='add' or command=='remove' then GV.follow(arg,command=='add')
  elseif command=='settings' or command=='options' or command=='config' then GV.open('settings')
  elseif command=='gm' then GV.open('gm')
  elseif command=='donations' or command=='ledger' then GV.open('donations')
  elseif command=='goals' then GV.open('goals')
  elseif command=='export' then GV.openExport(arg~='' and arg or nil)
  elseif command=='bank' or command=='banks' then GV.bankCommand(arg)
  elseif command=='tag' then
    log('Add this to the guild info (Guild > Guild Information): |cffffd100[GBT:'..(arg~='' and arg or key())..']|r',true)
  elseif command=='requests' then
    GV.open('requests')
    local list=GV.requestList()
    for i,r in ipairs(list) do
      if isActive(r) then log(i..'. '..displayName(r.by)..': '..GV.describe(r)..' |cff909090('..STATUSES[r.status]:lower()..')|r',true) end
    end
    if GV.activeRequestCount()>0 then log('Use /gbt approve N, deny N, mailed N, cancel N, or mail N at a mailbox.',true) end
  elseif command=='request' then
    -- /gbt request [item link or ID] [count] [note]
    local item,after=arg:match('item:(%d+)[^%]]*%]|h|r%s*(.*)$')
    if not item then item,after=arg:match('^(%d+)%s*(.*)$') end
    local count,note=(after or ''):match('^(%d*)%s*(.-)$')
    if not item then log('Usage: /gbt request [item link] 20 optional note. Or click the item in the window.',true); return end
    local owner=GV.bestToon(tonumber(item))
    if not owner then log('No bank toon has that item available.',true); return end
    GV.createRequest(tonumber(item),tonumber(count) or 1,note,owner)
  elseif command=='approve' or command=='deny' or command=='mailed' or command=='cancel' then
    local status=({approve='approved',deny='denied',mailed='mailed',cancel='cancelled'})[command]
    local r=GV.requestList()[tonumber(arg) or 0]
    if not r or not isActive(r) then log('No open request '..arg..'. /gbt requests lists them.',true); return end
    if not GV.allowed(r,r.status,status,myId()) then
      log('Officers, the guild master and bank characters approve or deny; the bank character marks approved requests mailed; requesters can cancel their own while waiting.',true)
      return
    end
    if GV.setRequestStatus(r,status) then log(STATUSES[status]..': '..GV.describe(r),true) end
  elseif command=='mail' then
    local r=GV.requestList()[tonumber(arg) or 0] or GV.toMail()[1]
    if not r then log('Nothing approved to mail.',true); return end
    GV.fillMail(r)
  elseif command=='mailhelper' or command=='autofill' then
    local field=command=='mailhelper' and 'mailHelper' or 'autofill'
    db.settings[field]=not db.settings[field]
    log((command=='mailhelper' and 'Mail helper' or 'Filling the first approved request when you open a mailbox')..' '..(db.settings[field] and 'on' or 'off')..'.',true)
  elseif command=='whispers' then
    db.settings.whispers=not db.settings.whispers
    log('Whispering officers without the addon '..(db.settings.whispers and 'on' or 'off')..'.',true)
  elseif command=='companion' then
    db.settings.companion=not db.settings.companion
    log('Reload prompt for the Discord companion '..(db.settings.companion and 'on' or 'off')..'.',true)
  elseif command=='tooltips' then
    db.settings.tooltips=not db.settings.tooltips
    log('Item tooltips '..(db.settings.tooltips and 'on' or 'off')..'.',true)
  elseif command=='quiet' then
    db.settings.quiet=not db.settings.quiet
    log('Quiet mode '..(db.settings.quiet and 'on' or 'off')..'.',true)
  else
    log('Everything is in the window: /gbt opens it, /gbt settings and /gbt gm jump to those tabs. Also: sync asks for the latest contents; status lists bank characters; bank add/remove/clear Name sets the guild\'s bank characters (guild master); requests lists requests; request [item] 20 note asks for something; approve/deny/mailed/cancel N updates one; mail N fills a mail at a mailbox; mailhelper and autofill toggle the mail helper; add/remove Name follows a bank character just for you; tag Name prints the guild info tag; whispers, companion, tooltips and quiet toggle those.',true)
  end
end

-- Events -----------------------------------------------------------------------------------------
local function requestRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
  elseif GuildRoster then GuildRoster() end
end
local function rescanSoon(delay) if bankOpen or GV.isBank(myId()) then GV.schedule('scan',delay or 1,GV.scanSelf) end end
local function setBankOpen(open)
  if open then bankOpen=true; rescanSoon(0.5)
  else GV.scanSelf(); bankOpen=false end
end
for _,event in ipairs({'ADDON_LOADED','PLAYER_LOGIN','PLAYER_LOGOUT','PLAYER_GUILD_UPDATE','GUILD_ROSTER_UPDATE',
  'BAG_UPDATE_DELAYED','PLAYER_MONEY','BANKFRAME_OPENED','BANKFRAME_CLOSED','PLAYERBANKSLOTS_CHANGED',
  'PLAYER_INTERACTION_MANAGER_FRAME_SHOW','PLAYER_INTERACTION_MANAGER_FRAME_HIDE','GET_ITEM_INFO_RECEIVED','CHAT_MSG_ADDON',
  'MAIL_SHOW','MAIL_CLOSED','MAIL_SEND_SUCCESS','MAIL_FAILED','MAIL_INBOX_UPDATE','MAIL_SEND_INFO_UPDATE'}) do
  pcall(frame.RegisterEvent,frame,event)
end
local function isBanker(kind)
  return Enum and Enum.PlayerInteractionType and kind==Enum.PlayerInteractionType.Banker
end
frame:SetScript('OnEvent',function(_,event,...)
  if event=='ADDON_LOADED' then
    if ...==addonName then GV.initDB() end
  elseif event=='PLAYER_LOGIN' then
    if not db then GV.initDB() end
    local register=(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
    if register then register(PREFIX) end
    GV.hookTooltips()
    GV.hookMail()
    GV.buildMinimapButton()
    GV.hookItemBox()
    pcall(GV.registerOptions)
    requestRoster()
    log('v'..VERSION..' loaded. Type /gbt to open the guild bank.')
    if GV.isTrial() then
      log('This is a trial account. WoW Forever doesn\'t let trial accounts send addon messages, so you can browse what guildmates share but can\'t make requests or share a bank toon.',true)
    end
    -- Probe first so our name matches what guildmates see before the real sync goes out.
    later(2,function() GV.queue('V|'..key()..'|'..VERSION) end)
    later(5,function() syncReady=true; GV.readTags(); GV.readRoster(); GV.syncAll(); GV.askManaged(); GV.askPlan() end)
    later(7,GV.syncRequests)
  elseif event=='PLAYER_LOGOUT' then
    -- SavedVariables are written now, which is what the Discord companion picks up.
    if db then GV.scanSelf() end
  elseif event=='PLAYER_GUILD_UPDATE' then
    requestRoster(); requestUpdate()
  elseif event=='GUILD_ROSTER_UPDATE' then
    GV.readTags(); GV.readRoster()
  elseif event=='BAG_UPDATE_DELAYED' or event=='PLAYER_MONEY' or event=='PLAYERBANKSLOTS_CHANGED' then
    rescanSoon()
  elseif event=='BANKFRAME_OPENED' then setBankOpen(true)
  elseif event=='BANKFRAME_CLOSED' then setBankOpen(false)
  elseif event=='PLAYER_INTERACTION_MANAGER_FRAME_SHOW' then if isBanker(...) then setBankOpen(true) end
  elseif event=='PLAYER_INTERACTION_MANAGER_FRAME_HIDE' then if isBanker(...) and bankOpen then setBankOpen(false) end
  elseif event=='MAIL_SHOW' then GV.mailOpened()
  elseif event=='MAIL_CLOSED' then
    if ui.mail then ui.mail:Hide() end
    if ui.donate then ui.donate:Hide() end
  elseif event=='MAIL_INBOX_UPDATE' then if GV.isBank(myId()) then GV.schedule('inbox',1,GV.scanInbox) end
  elseif event=='MAIL_SEND_INFO_UPDATE' then requestUpdate()
  elseif event=='MAIL_SEND_SUCCESS' then GV.mailSent()
  elseif event=='MAIL_FAILED' then if mailFilled then log('That mail didn\'t send; the request is still waiting to be mailed.',true) end
  elseif event=='GET_ITEM_INFO_RECEIVED' then
    local id=...
    if db and type(id)=='number' and not isSecret(id) and loadingItems[id] then loadingItems[id]=nil; GV.itemInfo(id) end
    requestUpdate()
  elseif event=='CHAT_MSG_ADDON' then
    local prefix,msg,channel,sender=...
    if prefix==PREFIX and channel=='GUILD' and type(msg)=='string' and not isSecret(msg) and db then GV.onMessage(msg,sender) end
  end
end)
frame:SetScript('OnUpdate',function(_,elapsed)
  if next(timers) then
    local t,due=GetTime(),{}
    for name,timer in pairs(timers) do if t>=timer.at then due[#due+1]=name end end
    for _,name in ipairs(due) do
      local timer=timers[name]
      timers[name]=nil
      if timer then timer.fn() end
    end
  end
  allowance=math.min(10,allowance+elapsed)
  local lane=(#urgent>0 and urgent) or queue
  if #lane>0 and allowance>=1 and not GV.messagingBlocked() then
    local item=lane[1]
    if GV.rawSend(item[1]) then
      table.remove(lane,1); allowance=allowance-1; sendFailures=0
      if item[2] then item[2]() end
    else
      -- Throttled anyway (the server sets the real limit): wait for the allowance to refill. A message
      -- that keeps failing is dropped so it can't stall the queue.
      allowance=0; sendFailures=sendFailures+1
      if sendFailures>=5 then table.remove(lane,1); sendFailures=0 end
    end
  end
  sinceUpdate=sinceUpdate+elapsed
  if updatePending and sinceUpdate>=0.2 then GV.refresh() end
end)
