-- Forever - Guild Bank Toons (folder GuildBankToons) - WoW: Forever + Classic Era. Shares the bags, bank and gold of the guild's bank characters
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
-- Hidden guild addon-message channel.
local PREFIX='GBTOONS'
-- Officers designate bank characters by adding this tag to the guild info text, e.g. [GBT:Vault Keeper].
local TAG_PATTERN='%[GBT:%s*([^%]]-)%s*%]'
-- Relayed snapshots stamped further ahead of server time than this are treated as forged.
local MAX_FUTURE=600
local ROW_H=20
local frame=CreateFrame('Frame')
local window
local ui, rows = {}, {}
local db
local queue, timers, pending = {}, {}, {}
local lastSent, lastSentAt = {}, {}
local sent, received, rejected = 0, 0, 0
local bankOpen, syncReady = false, false
local updatePending, sinceUpdate = false, 0
local sinceSend, sendFailures = 0, 0

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
  db.settings=db.settings or {}
  if db.settings.tooltips==nil then db.settings.tooltips=true end
  if db.settings.quiet==nil then db.settings.quiet=false end
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
  -- Wait for sorting or a mail run to settle, then push the new contents to everyone online.
  GV.schedule('push',10,function() GV.sendSnapshot(me) end)
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
--   R|origin|stamp|hash           "this is the copy I hold of origin; send it if yours is newer"
--   B|origin|stamp|hash|gold|bankStamp|count, then I|origin|stamp|entries..., then E|origin|stamp
-- Anyone holding a snapshot answers, so it spreads while the bank character is offline. A random delay
-- plus cancelling when someone else answers first keeps one broadcast per request.
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
function GV.queue(payload)
  if #queue<500 then queue[#queue+1]=payload end
end
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
  GV.queue('R|'..origin..'|'..(snap and snap.stamp or 0)..'|'..(snap and snap.hash or 0))
end
function GV.sendSnapshot(id)
  local g=GV.guild()
  local snap=g and g.banks[id]
  if not snap or not snap.stamp then return end
  -- Guild messages reach everyone, so one broadcast answers every request that arrives meanwhile.
  if lastSent[id]==snap.stamp and GetTime()-(lastSentAt[id] or 0)<30 then return end
  lastSent[id],lastSentAt[id]=snap.stamp,GetTime()
  local origin,stamp=snap.owner,snap.stamp
  local entries=GV.entries(snap)
  GV.queue(table.concat({'B',origin,stamp,snap.hash,snap.gold or 0,snap.bankStamp or 0,#entries},'|'))
  local head='I|'..origin..'|'..stamp..'|'
  local chunk,length={},#head
  for _,entry in ipairs(entries) do
    if length+#entry+1>250 then
      GV.queue(head..table.concat(chunk,','))
      chunk,length={},#head
    end
    chunk[#chunk+1]=entry; length=length+#entry+1
  end
  if #chunk>0 then GV.queue(head..table.concat(chunk,',')) end
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
function GV.onMessage(msg,sender)
  local action,origin,rest=msg:match('^(%u)|([^|]+)|?(.*)$')
  if not action then return end
  if action=='V' then
    if origin==key() and not isSecret(sender) then GV.learnOwnName(sender) end
    return
  end
  if action=='Q' or action=='L' or action=='P' or action=='A' then GV.onRequestMessage(action,origin,rest,sender); return end
  if action=='S' or action=='M' then GV.onListMessage(action,origin,rest,sender); return end
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
      elseif stamp<myStamp then GV.once('send:'..id,0.5,function() GV.sendSnapshot(id) end) end
    elseif stamp>myStamp then
      if plausible(stamp) then GV.once('ask:'..id,1+math.random()*3,function() GV.sendRequest(id) end) end
    elseif stamp<myStamp then
      GV.once('send:'..id,1+math.random()*4,function() GV.sendSnapshot(id) end)
    else
      -- Someone holding our copy already asked; whatever answers them reaches us too.
      GV.cancel('ask:'..id)
    end
  elseif action=='B' then
    local stamp,hash,gold,bankStamp,count=rest:match('^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)$')
    stamp,hash=tonumber(stamp),tonumber(hash)
    if not stamp then return end
    if stamp>=myStamp then GV.cancel('send:'..id) end
    if stamp>myStamp then GV.cancel('ask:'..id) end
    if iAmOwner then
      if mine and plausible(stamp) and stamp>=myStamp and hash~=myHash then GV.outbid(id,stamp) end
      return
    end
    -- The bank character's own copy always wins; relayed copies must be newer than ours.
    local wanted=stamp>myStamp or (fromOwner and hash~=myHash)
    if not wanted or not plausible(stamp) then return end
    pending[id..'|'..senderId]={stamp=stamp,hash=hash,gold=tonumber(gold),bankStamp=tonumber(bankStamp),count=tonumber(count),
      bags={},bank={},n=0,owner=origin,fromOwner=fromOwner,via=not isSecret(sender) and displayName(sender) or nil}
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
    local snap={owner=p.owner,stamp=p.stamp,gold=p.gold,bankStamp=p.bankStamp,bags=p.bags,bank=p.bank,
      via=(not p.fromOwner) and p.via or nil,received=now()}
    snap.hash=GV.hash(snap)
    -- A dropped or mangled message leaves the snapshot incomplete; the next sync fetches it again.
    if p.n~=p.count or snap.hash~=p.hash then rejected=rejected+1; return end
    local current=g.banks[id]
    if current and current.stamp>=snap.stamp and not (p.fromOwner and current.hash~=snap.hash) then return end
    g.banks[id]=snap
    received=received+1
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
local function keepFor(r) return isActive(r) and REQUEST_KEEP_ACTIVE or REQUEST_KEEP_CLOSED end
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
  local held=(snap.bags and snap.bags[item] or 0)+(snap.bank and snap.bank[item] or 0)
  return math.max(0,held-(GV.reserved(bankId)[item] or 0))
end
function GV.describe(r,plain)
  local name,link=GV.itemInfo(r.item)
  local item=(not plain and link) or name or ('item #'..r.item)
  return r.count..'x '..item..' from '..displayName(r.bank)..((r.note or '')~='' and (' - '..r.note) or '')
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
  if not GV.itemInfo(r.item) then loadingItems[r.item]=true end
  requestUpdate()
  GV.notify(r,mine==nil,relayed)
  return true
end
function GV.createRequest(item,count,note,bank)
  local g=GV.guild()
  if not g then return end
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
function GV.sendRequestList()
  GV.pruneRequests()
  local list=GV.requestList()
  GV.queue('P|'..key()..'|'..#list)
  for _,r in ipairs(list) do GV.queue(GV.requestPayload(r)) end
end
-- After the login reply, send back anything we have that the replier didn't, then say what's waiting.
function GV.finishListening()
  local heard=listening
  listening=nil
  GV.cancel('listen')
  if not heard or not heard.from then return end
  local me=myId()
  local waiting,toMail=0,0
  for _,r in ipairs(GV.requestList()) do
    if (heard.seen[r.id] or -1)<r.updated then GV.queue(GV.requestPayload(r)) end
    if r.status=='open' then waiting=waiting+1 end
    if r.status=='approved' and nameId(r.bank)==me then toMail=toMail+1 end
  end
  if waiting>0 and GV.isApprover(me) then
    GV.alert(waiting..' guild bank request'..(waiting==1 and '' or 's')..' waiting for approval. Type |cffffd100/gbt requests|r to see them.')
  end
  if toMail>0 then GV.alert(toMail..' approved request'..(toMail==1 and '' or 's')..' to mail. Open a mailbox to use the mail helper.') end
end
function GV.syncRequests()
  GV.pruneRequests()
  listening={seen={}}
  GV.queue('L|'..key())
  -- Nobody answered: no one with the addon is online, so there's nobody to catch up with.
  GV.schedule('listen',15,function() listening=nil end)
end
function GV.onRequestMessage(action,origin,rest,sender)
  local senderId=(not isSecret(sender) and nameId(sender)) or '?'
  if senderId==myId() or not GV.guild() then return end
  if action=='L' then
    GV.once('reqlist',1+math.random()*4,GV.sendRequestList)
  elseif action=='P' then
    GV.cancel('reqlist')
    if listening and not listening.from then
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
  end
end
if StaticPopupDialogs then
  StaticPopupDialogs.GUILDBANKTOONS_REQUEST={
    text='Request %s from %s\n\nHow many? Add a note after the number if you like ("20 for my alt").',
    button1='Request',button2=CANCEL or 'Cancel',hasEditBox=true,timeout=0,whileDead=true,hideOnEscape=true,
    OnShow=function(self)
      local box=self.editBox or self.EditBox
      if box then box:SetText('1'); box:HighlightText() end
    end,
    OnAccept=function(self,data)
      local box=self.editBox or self.EditBox
      local text=box and box:GetText() or ''
      local count=tonumber(text:match('^%s*(%d+)')) or 1
      GV.createRequest(data.item,count,(text:gsub('^%s*%d*%s*','')),data.bank)
    end,
    EditBoxOnEnterPressed=function(self)
      local popup=self:GetParent()
      StaticPopupDialogs.GUILDBANKTOONS_REQUEST.OnAccept(popup,popup.data)
      popup:Hide()
    end,
    EditBoxOnEscapePressed=function(self) self:GetParent():Hide() end,
  }
  StaticPopupDialogs.GUILDBANKTOONS_RELOAD={
    text='Guild bank requests changed. Reload now so the Discord companion on this PC posts them?',
    button1='Reload',button2='Later',timeout=0,whileDead=true,hideOnEscape=true,
    OnAccept=function() if ReloadUI then ReloadUI() end end,
  }
end
function GV.promptRequest(item,bank)
  if not StaticPopup_Show then return end
  local name,link=GV.itemInfo(item)
  local label=(link or name or ('item #'..item))..' ('..GV.available(nameId(bank),item)..' available)'
  StaticPopup_Show('GUILDBANKTOONS_REQUEST',label,displayName(bank),{item=item,bank=bank})
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
  if g then GV.queue('S|'..key()..'|'..(g.managedStamp or 0)) end
end
function GV.sendManaged()
  local g=GV.guild()
  if not g or not g.managedStamp or not g.managedBy then return end
  if managedSync.sentStamp==g.managedStamp and GetTime()-managedSync.sentAt<30 then return end
  managedSync.sentStamp,managedSync.sentAt=g.managedStamp,GetTime()
  local chunks,chunk,length={},{},0
  for _,name in ipairs(GV.managedNames(g)) do
    if length+#name+1>200 then chunks[#chunks+1]=table.concat(chunk,','); chunk,length={},0 end
    chunk[#chunk+1]=name; length=length+#name+1
  end
  chunks[#chunks+1]=table.concat(chunk,',')
  local head='M|'..g.managedBy..'|'..g.managedStamp..'|'
  for i,text in ipairs(chunks) do GV.queue(head..i..'|'..#chunks..'|'..text) end
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
    if stamp<mine then GV.once('list:send',1+math.random()*4,GV.sendManaged)
    elseif stamp>mine then if plausible(stamp) then GV.once('list:ask',1+math.random()*3,GV.askManaged) end
    else GV.cancel('list:ask') end
    return
  end
  local stamp,part,total,names=rest:match('^(%d+)|(%d+)|(%d+)|(.*)$')
  stamp,part,total=tonumber(stamp),tonumber(part),tonumber(total)
  if not stamp or part<1 or total<1 or total>10 or part>total then return end
  if stamp>=mine then GV.cancel('list:send') end
  if stamp>mine then GV.cancel('list:ask') end
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
  GV.readRoster()
  if next(roster)==nil then
    if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    log('The guild roster hasn\'t loaded yet; try again in a moment.',true); return
  end
  if not GV.isGM(myId()) then
    log('Only the guild master can set the guild\'s bank characters. /gbt add Name follows one just for you.',true); return
  end
  local set,count={},0
  for id,n in pairs(g.managed) do set[id]=n; count=count+1 end
  local id=nameId(name)
  if verb=='clear' then
    set={}
    log('Cleared the guild\'s bank characters.',true)
  elseif not id or name:find('[|,]') then
    log('Usage: /gbt bank '..verb..' First Last',true); return
  elseif verb=='add' then
    if set[id] then log(displayName(name)..' is already a bank character.',true); return end
    if count>=MAX_MANAGED then log('That\'s the limit of '..MAX_MANAGED..' bank characters.',true); return end
    set[id]=baseName(name)
    log('Added '..baseName(name)..' as a guild bank character. Log in on it with the addon and visit the banker once.',true)
  else
    if not set[id] then log(displayName(name)..' isn\'t one of the guild\'s bank characters.',true); return end
    set[id]=nil
    log('Removed '..displayName(name)..' from the guild\'s bank characters.',true)
  end
  GV.setManaged(set)
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
    SendMailSubjectEditBox:SetText(('Guild bank: '..r.count..'x '..(GV.itemInfo(r.item) or ('item '..r.item))):sub(1,64))
  end
  local body=mailBodyBox()
  if body then body:SetText('Approved by '..displayName(r.approvedBy or r.actor or '?')..'.'..((r.note or '')~='' and (' Your note: '..r.note) or '')) end
  local ok,err=GV.attachItems(r.item,r.count)
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
  local filled=mailFilled
  mailFilled=nil
  if not filled or not lastMailTo or nameId(lastMailTo)~=nameId(filled.name) then return end
  local g=GV.guild()
  local r=g and g.requests[filled.id]
  if r and r.status=='approved' and GV.setRequestStatus(r,'mailed') then log('Marked '..GV.describe(r)..' as mailed.',true) end
end
function GV.hookMail()
  if hooksecurefunc and SendMail then hooksecurefunc('SendMail',function(to) lastMailTo=to end) end
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
      local name=GV.itemInfo(r.item) or ('item #'..r.item)
      local marker=(mailFilled and mailFilled.id==r.id) and '|cff40ff40> |r' or ''
      row.text:SetText(marker..r.count..'x '..name..'\n|cff909090to '..displayName(r.by)..((r.note or '')~='' and (' - '..r.note) or '')..'|r')
    end
  end
  f.empty:SetShown(#list==0)
end
function GV.mailOpened()
  if not settings().mailHelper or not GV.isBank(myId()) then return end
  GV.buildMailHelper()
  if not ui.mail then return end
  ui.mail:Show(); GV.refreshMailHelper()
  local list=GV.toMail()
  if #list>0 and settings().autofill then later(0.3,function() GV.fillMail(list[1]) end) end
end

-- Window ------------------------------------------------------------------------------------------
local function selectedBank(banks)
  for _,bank in ipairs(banks) do if bank.id==db.ui.bank then return bank end end
  local first=banks[1]
  db.ui.bank=first and first.id
  return first
end
function GV.row(i)
  if rows[i] then return rows[i] end
  local r=CreateFrame('Button',nil,ui.content)
  r:SetSize(400,ROW_H); r:SetPoint('TOPLEFT',0,-(i-1)*ROW_H)
  r:SetHighlightTexture('Interface\\QuestFrame\\UI-QuestTitleHighlight','ADD')
  r.icon=r:CreateTexture(nil,'ARTWORK'); r.icon:SetSize(16,16); r.icon:SetPoint('LEFT',2,0)
  r.name=r:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  r.name:SetPoint('LEFT',r.icon,'RIGHT',6,0); r.name:SetWidth(230); r.name:SetJustifyH('LEFT')
  r.where=r:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); r.where:SetPoint('RIGHT',-60,0)
  r.count=r:CreateFontString(nil,'OVERLAY','GameFontNormalSmall'); r.count:SetPoint('RIGHT',-6,0)
  -- Approve / Deny / Mailed / Cancel in the Requests view, whichever this player may use.
  r.actions={}
  for n=1,2 do
    local b=CreateFrame('Button',nil,r,'UIPanelButtonTemplate')
    b:SetSize(60,18); b:SetPoint('RIGHT',-2-(2-n)*62,0)
    b:SetScript('OnClick',function(self) GV.setRequestStatus(r.request,self.status) end)
    r.actions[n]=b
  end
  r:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.id) else GameTooltip:SetHyperlink('item:'..self.id) end
    local q=self.request
    if q then
      GameTooltip:AddLine(' ')
      GameTooltip:AddLine('Requested by '..displayName(q.by)..' '..ago(tonumber(q.id:match('%-(%d+)%-%d+$')) or q.updated),1,1,1)
      if (q.note or '')~='' then GameTooltip:AddLine('"'..q.note..'"',1,.82,0,true) end
      if q.status=='open' then GameTooltip:AddLine(STATUSES.open,.6,.6,.6)
      else GameTooltip:AddLine(STATUSES[q.status]..' by '..displayName(q.actor or '?'),.6,.6,.6) end
      if q.status=='mailed' and q.approvedBy then GameTooltip:AddLine('Approved by '..displayName(q.approvedBy),.6,.6,.6) end
      GameTooltip:AddLine('Shift-click to link.',.6,.6,.6)
    else
      GameTooltip:AddLine('Shift-click to link. Ctrl-click to request it.',.6,.6,.6)
    end
    GameTooltip:Show()
  end)
  r:SetScript('OnLeave',function() GameTooltip:Hide() end)
  r:SetScript('OnClick',function(self)
    if IsShiftKeyDown() then
      local _,link=GV.itemInfo(self.id)
      if link and InsertChatLink then InsertChatLink(link) end
    elseif IsControlKeyDown() and not self.request then
      GV.promptRequest(self.id,self.owner)
    end
  end)
  rows[i]=r
  return r
end
function GV.buildWindow()
  local f=CreateFrame('Frame','GuildBankToonsFrame',UIParent,'BasicFrameTemplateWithInset')
  f:SetSize(460,500); f:SetPoint('CENTER'); f:SetFrameStrata('HIGH'); f:SetClampedToScreen(true)
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag('LeftButton')
  f:SetScript('OnDragStart',f.StartMoving); f:SetScript('OnDragStop',f.StopMovingOrSizing)
  f:SetScript('OnShow',function() requestUpdate() end)
  tinsert(UISpecialFrames,'GuildBankToonsFrame')
  local title=f.TitleText or f:CreateFontString(nil,'OVERLAY','GameFontHighlight')
  if not f.TitleText then title:SetPoint('TOP',0,-6) end
  title:SetText('Forever - Guild Bank Toons')
  ui.bankButtons={}
  for i=1,5 do
    local b=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
    b:SetSize(84,22); b:SetPoint('TOPLEFT',12+(i-1)*87,-30)
    b:SetScript('OnClick',function(self)
      if self.pages then db.ui.page=(db.ui.page or 1)%self.pages+1
      else db.ui.bank=self.id; db.ui.mode='items' end
      requestUpdate()
    end)
    ui.bankButtons[i]=b
  end
  local search=CreateFrame('EditBox',nil,f,'InputBoxTemplate')
  search:SetSize(160,20); search:SetPoint('TOPLEFT',20,-60); search:SetAutoFocus(false)
  search:SetScript('OnTextChanged',function() requestUpdate() end)
  search:SetScript('OnEscapePressed',search.ClearFocus); search:SetScript('OnEnterPressed',search.ClearFocus)
  local hint=search:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); hint:SetPoint('LEFT',4,0); hint:SetText('Search items')
  search:HookScript('OnTextChanged',function(self) hint:SetShown(self:GetText()=='') end)
  ui.search=search
  ui.filterButtons={}
  for i,filter in ipairs({'all','bags','bank'}) do
    local b=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
    b:SetSize(55,22); b:SetPoint('TOPLEFT',192+(i-1)*58,-59)
    b:SetText(filter=='all' and 'All' or (filter=='bags' and 'Bags' or 'Bank'))
    b.filter=filter
    b:SetScript('OnClick',function(self) db.ui.filter=self.filter; db.ui.mode='items'; requestUpdate() end)
    ui.filterButtons[i]=b
  end
  ui.requestsButton=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
  ui.requestsButton:SetSize(84,22); ui.requestsButton:SetPoint('TOPLEFT',368,-59)
  ui.requestsButton:SetScript('OnClick',function() db.ui.mode=(db.ui.mode=='requests') and 'items' or 'requests'; requestUpdate() end)
  ui.info=f:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
  ui.info:SetPoint('TOPLEFT',16,-88); ui.info:SetPoint('RIGHT',-16,0); ui.info:SetJustifyH('LEFT')
  local scroll=CreateFrame('ScrollFrame',nil,f,'UIPanelScrollFrameTemplate')
  scroll:SetPoint('TOPLEFT',12,-108); scroll:SetPoint('BOTTOMRIGHT',-32,12)
  ui.content=CreateFrame('Frame',nil,scroll); ui.content:SetSize(400,1)
  scroll:SetScrollChild(ui.content)
  ui.empty=ui.content:CreateFontString(nil,'OVERLAY','GameFontDisable')
  ui.empty:SetPoint('TOPLEFT',8,-12); ui.empty:SetWidth(380); ui.empty:SetJustifyH('LEFT')
  window=f
  f:Hide()
end
function GV.refresh()
  updatePending=false; sinceUpdate=0
  GV.refreshMailHelper()
  if not window or not window:IsShown() then return end
  local g=GV.guild()
  local banks=GV.bankList()
  local bank=selectedBank(banks)
  -- More than five bank characters: four per page, and the last button turns the page.
  local perPage=#banks>#ui.bankButtons and #ui.bankButtons-1 or #ui.bankButtons
  local pages=math.max(1,math.ceil(#banks/perPage))
  local page=math.min(db.ui.page or 1,pages)
  db.ui.page=page
  for i,b in ipairs(ui.bankButtons) do
    local entry=banks[(page-1)*perPage+i]
    b.pages=nil
    if i>perPage then entry=nil end
    b:SetShown(entry~=nil)
    if i>perPage then
      b.pages=pages; b:SetText('More '..page..'/'..pages); b:UnlockHighlight(); b:Show()
    elseif entry then
      b.id=entry.id; b:SetText(displayName(entry.name))
      if entry.id==db.ui.bank then b:LockHighlight() else b:UnlockHighlight() end
    end
  end
  local showRequests=db.ui.mode=='requests'
  for _,b in ipairs(ui.filterButtons) do
    if b.filter==db.ui.filter and not showRequests then b:LockHighlight() else b:UnlockHighlight() end
  end
  local open=g and GV.activeRequestCount() or 0
  ui.requestsButton:SetText(open>0 and ('Requests ('..open..')') or 'Requests')
  if showRequests then ui.requestsButton:LockHighlight() else ui.requestsButton:UnlockHighlight() end
  local snap=g and bank and g.banks[bank.id]
  local list={}
  if g and showRequests then
    local me,term=myId(),(ui.search:GetText() or ''):lower()
    ui.info:SetText(GV.isApprover(me) and 'You can approve or deny requests. Approved items are reserved until mailed.' or 'Ctrl-click an item in a bank to request it.')
    for _,q in ipairs(GV.requestList()) do
      local name,_,quality,icon=GV.itemInfo(q.item)
      local label=q.count..'x '..(name or ('Item #'..q.item))
      if term=='' or label:lower():find(term,1,true) or q.by:lower():find(term,1,true) then
        list[#list+1]={id=q.item,name=label,quality=quality,icon=icon,request=q,owner=q.bank}
      end
    end
    ui.empty:SetText(#list==0 and 'No requests.' or '')
  elseif not g then
    ui.info:SetText(''); ui.empty:SetText('Join a guild to see its bank.')
  elseif not bank then
    ui.info:SetText('')
    ui.empty:SetText('No bank characters yet.\n\nThe guild master types |cffffd100/gbt bank add First Last|r, or an officer adds |cffffd100[GBT:First Last]|r to the guild info. Type |cffffd100/gbt add Name|r to follow one just for yourself.')
  elseif not snap then
    ui.info:SetText(displayName(bank.name))
    ui.empty:SetText('Waiting for '..displayName(bank.name)..'\'s contents.\n\nThey arrive when the bank character, or a guildmate who has seen them, is online.')
  else
    local via=snap.via and (' via '..snap.via) or ''
    local bankNote=(snap.bankStamp or 0)==0 and '  |cffff8040bank not opened yet|r' or ''
    ui.info:SetText((GetCoinTextureString and GetCoinTextureString(snap.gold or 0) or ((snap.gold or 0)..'c'))..'   |cff909090updated '..ago(snap.stamp)..via..'|r'..bankNote)
    local filter,term=db.ui.filter,(ui.search:GetText() or ''):lower()
    -- Approved requests hold their items until mailed, so the All view shows what's still available.
    local reserved=filter=='all' and GV.reserved(bank.id) or {}
    local merged={}
    if filter~='bank' then for id,count in pairs(snap.bags or {}) do merged[id]={bags=count,bank=0} end end
    if filter~='bags' then
      for id,count in pairs(snap.bank or {}) do merged[id]=merged[id] or {bags=0,bank=0}; merged[id].bank=count end
    end
    for id,counts in pairs(merged) do
      local name,_,quality,icon=GV.itemInfo(id)
      local label=name or ('Item #'..id)
      if term=='' or label:lower():find(term,1,true) then
        list[#list+1]={id=id,name=label,quality=quality,icon=icon,bags=counts.bags,bank=counts.bank,reserved=reserved[id] or 0}
      end
    end
    table.sort(list,function(a,b) return a.name<b.name end)
    ui.empty:SetText(#list==0 and (term~='' and 'Nothing matches.' or 'Empty.') or '')
  end
  local me=myId()
  for i,item in ipairs(list) do
    local r=GV.row(i)
    local q=item.request
    r.id,r.owner,r.request=item.id,item.owner or snap.owner,q
    r.icon:SetTexture(item.icon or 'Interface\\Icons\\INV_Misc_QuestionMark')
    r.name:SetText(item.name)
    local color=ITEM_QUALITY_COLORS and item.quality and ITEM_QUALITY_COLORS[item.quality]
    if color then r.name:SetTextColor(color.r,color.g,color.b) else r.name:SetTextColor(1,1,1) end
    if (q and not isActive(q)) or (not q and item.bags+item.bank-item.reserved<=0) then r.name:SetTextColor(.5,.5,.5) end
    r.where:ClearAllPoints()
    for _,b in ipairs(r.actions) do b:Hide() end
    if q then
      local buttons={}
      for _,spec in ipairs({{'Approve','approved'},{'Mailed','mailed'},{'Deny','denied'},{'Cancel','cancelled'}}) do
        if #buttons<2 and GV.allowed(q,q.status,spec[2],me) then buttons[#buttons+1]=spec end
      end
      for n,spec in ipairs(buttons) do
        local b=r.actions[3-#buttons+n-1]
        b:SetText(spec[1]); b.status=spec[2]; b:Show()
      end
      r.where:SetPoint('RIGHT',-6-#buttons*62,0)
      local stateText=({open='',approved=' · |cff40ff40approved|r'})[q.status] or (' · '..q.status)
      r.where:SetText(displayName(q.by)..stateText)
      r.count:SetText('')
    else
      r.where:SetPoint('RIGHT',-60,0)
      local where={}
      if item.bags>0 and db.ui.filter=='all' and item.bank>0 then where[#where+1]='bags '..item.bags; where[#where+1]='bank '..item.bank end
      if item.reserved>0 then where[#where+1]='|cffff8040'..item.reserved..' reserved|r' end
      r.where:SetText(table.concat(where,' · '))
      r.count:SetText(math.max(0,item.bags+item.bank-item.reserved))
    end
    r:Show()
  end
  for i=#list+1,#rows do rows[i]:Hide() end
  ui.content:SetHeight(math.max(1,#list*ROW_H))
end
function GV.toggle()
  if not window then GV.buildWindow() end
  window:SetShown(not window:IsShown())
end
function GuildBankToons_OnCompartmentClick() GV.toggle() end

-- Item tooltips: "Guild bank (Bankalt): 40" on any item a bank character holds.
function GV.addTooltipLines(tooltip,id,show)
  if not db or not settings().tooltips or type(id)~='number' or isSecret(id) then return end
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
    GV.isBank(myId()) and ' (bank character)' or '',sent,received,rejected,#queue),true)
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
  elseif command=='sync' then GV.syncAll(); GV.askManaged(); log('Asked the guild for the latest bank contents.',true)
  elseif command=='status' then GV.status()
  elseif command=='add' or command=='remove' then
    local id=nameId(arg)
    if not g or not id or arg=='' then log('Usage: /gbt '..command..' First Last (you must be in a guild).',true); return end
    if command=='add' then
      g.extra[id]=arg; log('Following '..arg..'. Run this on the bank character too, or have an officer tag it in the guild info.',true)
    elseif g.managed[id] then
      log(arg..' was set by the guild master, who can remove it with /gbt bank remove.',true); return
    elseif g.tagged[id] then
      log(arg..' is tagged in the guild info; an officer has to remove the tag there.',true); return
    else
      g.extra[id]=nil; log('Stopped following '..arg..'.',true)
    end
    GV.banksChanged()
  elseif command=='bank' or command=='banks' then GV.bankCommand(arg)
  elseif command=='tag' then
    log('Add this to the guild info (Guild > Guild Information): |cffffd100[GBT:'..(arg~='' and arg or key())..']|r',true)
  elseif command=='requests' then
    if not window then GV.buildWindow() end
    db.ui.mode='requests'; window:Show(); requestUpdate()
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
    local bank=selectedBank(GV.bankList())
    local owner=bank and ((g.banks[bank.id] and g.banks[bank.id].owner) or bank.name)
    if not item or not owner then log('Usage: /gbt request [item link] 20 optional note (asks the bank selected in the window).',true); return end
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
    log('/gbt opens the window; sync asks for the latest contents; status lists bank characters; bank add/remove/clear Name sets the guild\'s bank characters (guild master); requests lists requests; request [item] 20 note asks for something; approve/deny/mailed/cancel N updates one; mail N fills a mail at a mailbox; mailhelper and autofill toggle the mail helper; add/remove Name follows a bank character just for you; tag Name prints the guild info tag; whispers, companion, tooltips and quiet toggle those.',true)
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
  'MAIL_SHOW','MAIL_CLOSED','MAIL_SEND_SUCCESS','MAIL_FAILED'}) do
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
    requestRoster()
    log('v'..VERSION..' loaded. Type /gbt to open the guild bank.')
    -- Probe first so our name matches what guildmates see before the real sync goes out.
    later(2,function() GV.queue('V|'..key()..'|'..VERSION) end)
    later(5,function() syncReady=true; GV.readTags(); GV.readRoster(); GV.syncAll(); GV.askManaged() end)
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
  elseif event=='MAIL_CLOSED' then if ui.mail then ui.mail:Hide() end
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
  if #queue>0 and not GV.messagingBlocked() then
    sinceSend=sinceSend+elapsed
    if sinceSend>=0.2 then
      sinceSend=0
      if GV.rawSend(queue[1]) then
        table.remove(queue,1); sendFailures=0
      else
        -- Throttled messages go through on a later try; one that keeps failing is dropped so it can't stall the queue.
        sendFailures=sendFailures+1
        if sendFailures>=5 then table.remove(queue,1); sendFailures=0 end
        sinceSend=-1
      end
    end
  end
  sinceUpdate=sinceUpdate+elapsed
  if updatePending and sinceUpdate>=0.2 then GV.refresh() end
end)
