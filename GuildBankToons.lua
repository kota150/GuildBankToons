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
-- Officers designate bank characters by adding this tag to the guild info text, e.g. [GBT:Bankalt-Realm].
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
local OpenChat=(ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat

local function settings() return db and db.settings or {} end
local function log(s,always)
  if not always and settings().quiet then return end
  print('|cffd8aa55Guild Bank Toons:|r '..tostring(s))
end
-- Server time, so stamps from different players' machines compare fairly.
local function now() return (GetServerTime and GetServerTime()) or (time and time()) or 0 end
local function realm() return (GetRealmName and GetRealmName()) or 'Unknown' end
local cachedPlayer
-- WoW: Forever adds surnames, and UnitName may not match the name other players see on our messages.
-- GV.learnOwnName() records the name the server puts on our own messages, keyed by UnitName.
local function playerName()
  if cachedPlayer then return cachedPlayer end
  local name=UnitName('player')
  if name and not isSecret(name) then
    local learned=db and db.knownAs[name..'-'..realm()]
    cachedPlayer=learned or name
  end
  return cachedPlayer
end
local function key() return (playerName() or 'Unknown')..'-'..realm() end
-- Message headers drop spaces and punctuation from realm names ("Nek'Rosh" -> "NekRosh"), so compare letters and digits only.
local function normalizeRealm(server) return (server or ''):gsub('[^%w]',''):lower() end
local function splitName(name)
  if type(name)~='string' or isSecret(name) then return nil end
  -- Strip a suffix naming our own realm first, so hyphens in surnames or realm names don't split wrongly.
  local own=normalizeRealm(realm())
  local start=1
  while true do
    local dash=name:find('-',start,true)
    if not dash then break end
    if normalizeRealm(name:sub(dash+1))==own then return name:sub(1,dash-1),realm() end
    start=dash+1
  end
  local character,server=name:match('^([^-]+)%-(.+)$')
  if not character then return name,realm() end
  return character,server
end
local function nameId(name)
  local character,server=splitName(name)
  if not character then return nil end
  return character:gsub('%s',''):lower()..'-'..normalizeRealm(server)
end
-- "Bob" for your own realm, "Bob-Faerlina" for anyone from another realm.
local function displayName(name)
  local character,server=splitName(name)
  if not character then return name end
  if normalizeRealm(server)==normalizeRealm(realm()) then return character end
  return character..'-'..server:gsub('%s','')
end
local function myId() return nameId(key()) end
-- Our own guild addon messages echo back with the sender name the server uses for us.
function GV.learnOwnName(sender)
  local character=splitName(sender)
  local base=UnitName('player')
  if not character or character==cachedPlayer or not base or isSecret(base) then return end
  cachedPlayer=character
  db.knownAs[base..'-'..realm()]=character
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
  db.ui=db.ui or {}
  db.ui.filter=db.ui.filter or 'all'
  db.settings=db.settings or {}
  if db.settings.tooltips==nil then db.settings.tooltips=true end
  if db.settings.quiet==nil then db.settings.quiet=false end
end
-- Guild names are only unique per realm.
local function guildKey()
  if not (IsInGuild and IsInGuild()) or not GetGuildInfo then return nil end
  local name=GetGuildInfo('player')
  if type(name)~='string' or isSecret(name) or name=='' then return nil end
  return name..' - '..realm()
end
-- banks: id -> snapshot; tagged: bank characters from the guild info text; extra: ones added with /gbt add.
function GV.guild()
  local name=db and guildKey()
  if not name then return nil end
  local g=db.guilds[name]
  if not g then g={banks={},tagged={},extra={}}; db.guilds[name]=g end
  return g
end
function GV.isBank(id)
  local g=GV.guild()
  return (g and id and (g.tagged[id] or g.extra[id])) and true or false
end
function GV.bankList()
  local g=GV.guild()
  local list,seen={},{}
  if not g then return list end
  for _,source in ipairs({g.tagged,g.extra}) do
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
  local tagged,changed={},false
  for name in text:gmatch(TAG_PATTERN) do
    local id=nameId(name)
    if id then tagged[id]=name; if not g.tagged[id] then changed=true end end
  end
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
  local a,b,_,_,_,_,link,_,_,id=GetSlotInfo(bag,slot)
  if type(a)=='table' then return a.itemID,a.stackCount end
  if id then return id,b end
  if type(link)=='string' then return tonumber(link:match('item:(%d+)')),b end
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
  local g,me=GV.guild(),myId()
  if not g or not GV.isBank(me) then return end
  local old=g.banks[me] or {}
  local snap={owner=key(),bags=GV.scanContainers(GV.bagIds()),bank=old.bank or {},bankStamp=old.bankStamp or 0,gold=(GetMoney and GetMoney()) or 0}
  if bankOpen then snap.bank=GV.scanContainers(GV.bankIds()); snap.bankStamp=now() end
  snap.hash=GV.hash(snap)
  if snap.hash==old.hash then
    if bankOpen then old.bankStamp=snap.bankStamp end
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
-- Protocol (guild addon channel, '|' separated; origin is the bank character's Name-Realm):
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
  local origin=(snap and snap.owner) or g.tagged[id] or g.extra[id]
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
      if not mine then return end
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
      if mine and stamp>=myStamp and hash~=myHash then GV.outbid(id,stamp) end
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

-- Window ------------------------------------------------------------------------------------------
local function selectedBank(banks)
  for _,bank in ipairs(banks) do if bank.id==db.ui.bank then return bank end end
  local first=banks[1]
  db.ui.bank=first and first.id
  return first
end
function GV.askFor(id,owner)
  if not OpenChat then return end
  local name,link=GV.itemInfo(id)
  OpenChat('/w '..displayName(owner)..' Hi! Could I get '..(link or name or ('item '..id))..' from the guild bank?')
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
  r:SetScript('OnEnter',function(self)
    GameTooltip:SetOwner(self,'ANCHOR_RIGHT')
    if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.id) else GameTooltip:SetHyperlink('item:'..self.id) end
    GameTooltip:AddLine('Shift-click to link. Ctrl-click to ask the bank.',.6,.6,.6)
    GameTooltip:Show()
  end)
  r:SetScript('OnLeave',function() GameTooltip:Hide() end)
  r:SetScript('OnClick',function(self)
    if IsShiftKeyDown() then
      local _,link=GV.itemInfo(self.id)
      if link and InsertChatLink then InsertChatLink(link) end
    elseif IsControlKeyDown() then
      GV.askFor(self.id,self.owner)
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
    b:SetScript('OnClick',function(self) db.ui.bank=self.id; requestUpdate() end)
    ui.bankButtons[i]=b
  end
  local search=CreateFrame('EditBox',nil,f,'InputBoxTemplate')
  search:SetSize(190,20); search:SetPoint('TOPLEFT',20,-60); search:SetAutoFocus(false)
  search:SetScript('OnTextChanged',function() requestUpdate() end)
  search:SetScript('OnEscapePressed',search.ClearFocus); search:SetScript('OnEnterPressed',search.ClearFocus)
  local hint=search:CreateFontString(nil,'OVERLAY','GameFontDisableSmall'); hint:SetPoint('LEFT',4,0); hint:SetText('Search items')
  search:HookScript('OnTextChanged',function(self) hint:SetShown(self:GetText()=='') end)
  ui.search=search
  ui.filterButtons={}
  for i,filter in ipairs({'all','bags','bank'}) do
    local b=CreateFrame('Button',nil,f,'UIPanelButtonTemplate')
    b:SetSize(60,22); b:SetPoint('TOPLEFT',230+(i-1)*63,-59)
    b:SetText(filter=='all' and 'All' or (filter=='bags' and 'Bags' or 'Bank'))
    b.filter=filter
    b:SetScript('OnClick',function(self) db.ui.filter=self.filter; requestUpdate() end)
    ui.filterButtons[i]=b
  end
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
  if not window or not window:IsShown() then return end
  local g=GV.guild()
  local banks=GV.bankList()
  local bank=selectedBank(banks)
  for i,b in ipairs(ui.bankButtons) do
    local entry=banks[i]
    b:SetShown(entry~=nil)
    if entry then
      b.id=entry.id; b:SetText(displayName(entry.name))
      if entry.id==db.ui.bank then b:LockHighlight() else b:UnlockHighlight() end
    end
  end
  for _,b in ipairs(ui.filterButtons) do
    if b.filter==db.ui.filter then b:LockHighlight() else b:UnlockHighlight() end
  end
  local snap=g and bank and g.banks[bank.id]
  local list={}
  if not g then
    ui.info:SetText(''); ui.empty:SetText('Join a guild to see its bank.')
  elseif not bank then
    ui.info:SetText('')
    ui.empty:SetText('No bank characters yet.\n\nAn officer adds |cffffd100[GBT:Name-Realm]|r to the guild info, or type |cffffd100/gbt add Name|r to follow one yourself.')
  elseif not snap then
    ui.info:SetText(displayName(bank.name))
    ui.empty:SetText('Waiting for '..displayName(bank.name)..'\'s contents.\n\nThey arrive when the bank character, or a guildmate who has seen them, is online.')
  else
    local via=snap.via and (' via '..snap.via) or ''
    local bankNote=(snap.bankStamp or 0)==0 and '  |cffff8040bank not opened yet|r' or ''
    ui.info:SetText((GetCoinTextureString and GetCoinTextureString(snap.gold or 0) or ((snap.gold or 0)..'c'))..'   |cff909090updated '..ago(snap.stamp)..via..'|r'..bankNote)
    local filter,term=db.ui.filter,(ui.search:GetText() or ''):lower()
    local merged={}
    if filter~='bank' then for id,count in pairs(snap.bags or {}) do merged[id]={bags=count,bank=0} end end
    if filter~='bags' then
      for id,count in pairs(snap.bank or {}) do merged[id]=merged[id] or {bags=0,bank=0}; merged[id].bank=count end
    end
    for id,counts in pairs(merged) do
      local name,_,quality,icon=GV.itemInfo(id)
      local label=name or ('Item #'..id)
      if term=='' or label:lower():find(term,1,true) then
        list[#list+1]={id=id,name=label,quality=quality,icon=icon,bags=counts.bags,bank=counts.bank}
      end
    end
    table.sort(list,function(a,b) return a.name<b.name end)
    ui.empty:SetText(#list==0 and (term~='' and 'Nothing matches.' or 'Empty.') or '')
  end
  for i,item in ipairs(list) do
    local r=GV.row(i)
    r.id,r.owner=item.id,snap.owner
    r.icon:SetTexture(item.icon or 'Interface\\Icons\\INV_Misc_QuestionMark')
    r.name:SetText(item.name)
    local color=ITEM_QUALITY_COLORS and item.quality and ITEM_QUALITY_COLORS[item.quality]
    if color then r.name:SetTextColor(color.r,color.g,color.b) else r.name:SetTextColor(1,1,1) end
    local where={}
    if item.bags>0 and db.ui.filter=='all' and item.bank>0 then where[#where+1]='bags '..item.bags; where[#where+1]='bank '..item.bank end
    r.where:SetText(table.concat(where,' · '))
    r.count:SetText(item.bags+item.bank)
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
      tooltip:AddDoubleLine('|cffd8aa55Guild bank|r ('..displayName(snap.owner)..')',count,1,1,1,1,1,1)
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
  for _,bank in ipairs(GV.bankList()) do
    local snap=g.banks[bank.id]
    local source=g.tagged[bank.id] and 'guild info' or '/gbt add'
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
  elseif command=='sync' then GV.syncAll(); log('Asked the guild for the latest bank contents.',true)
  elseif command=='status' then GV.status()
  elseif command=='add' or command=='remove' then
    local id=nameId(arg)
    if not g or not id or arg=='' then log('Usage: /gbt '..command..' Name-Realm (you must be in a guild).',true); return end
    if command=='add' then
      g.extra[id]=arg; log('Following '..arg..'. Run this on the bank character too, or have an officer tag it in the guild info.',true)
    elseif g.tagged[id] then
      log(arg..' is tagged in the guild info; an officer has to remove the tag there.',true); return
    else
      g.extra[id]=nil; log('Stopped following '..arg..'.',true)
    end
    GV.banksChanged()
  elseif command=='tag' then
    log('Add this to the guild info (Guild > Guild Information): |cffffd100[GBT:'..(arg~='' and arg or key())..']|r',true)
  elseif command=='tooltips' then
    db.settings.tooltips=not db.settings.tooltips
    log('Item tooltips '..(db.settings.tooltips and 'on' or 'off')..'.',true)
  elseif command=='quiet' then
    db.settings.quiet=not db.settings.quiet
    log('Quiet mode '..(db.settings.quiet and 'on' or 'off')..'.',true)
  else
    log('/gbt opens the window; sync asks for the latest contents; status lists bank characters; add/remove Name follows a bank character just for you; tag Name prints the guild info tag; tooltips and quiet toggle those.',true)
  end
end

-- Events -----------------------------------------------------------------------------------------
local function requestRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
  elseif GuildRoster then GuildRoster() end
end
local function rescanSoon(delay) if GV.isBank(myId()) then GV.schedule('scan',delay or 1,GV.scanSelf) end end
local function setBankOpen(open)
  if open then bankOpen=true; rescanSoon(0.5)
  else GV.scanSelf(); bankOpen=false end
end
for _,event in ipairs({'ADDON_LOADED','PLAYER_LOGIN','PLAYER_LOGOUT','PLAYER_GUILD_UPDATE','GUILD_ROSTER_UPDATE',
  'BAG_UPDATE_DELAYED','PLAYER_MONEY','BANKFRAME_OPENED','BANKFRAME_CLOSED','PLAYERBANKSLOTS_CHANGED',
  'PLAYER_INTERACTION_MANAGER_FRAME_SHOW','PLAYER_INTERACTION_MANAGER_FRAME_HIDE','GET_ITEM_INFO_RECEIVED','CHAT_MSG_ADDON'}) do
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
    requestRoster()
    log('v'..VERSION..' loaded. Type /gbt to open the guild bank.')
    -- Probe first so our name matches what guildmates see before the real sync goes out.
    later(2,function() GV.queue('V|'..key()..'|'..VERSION) end)
    later(5,function() syncReady=true; GV.readTags(); GV.syncAll() end)
  elseif event=='PLAYER_LOGOUT' then
    -- SavedVariables are written now, which is what the Discord companion picks up.
    if db then GV.scanSelf() end
  elseif event=='PLAYER_GUILD_UPDATE' then
    requestRoster(); requestUpdate()
  elseif event=='GUILD_ROSTER_UPDATE' then
    GV.readTags()
  elseif event=='BAG_UPDATE_DELAYED' or event=='PLAYER_MONEY' or event=='PLAYERBANKSLOTS_CHANGED' then
    rescanSoon()
  elseif event=='BANKFRAME_OPENED' then setBankOpen(true)
  elseif event=='BANKFRAME_CLOSED' then setBankOpen(false)
  elseif event=='PLAYER_INTERACTION_MANAGER_FRAME_SHOW' then if isBanker(...) then setBankOpen(true) end
  elseif event=='PLAYER_INTERACTION_MANAGER_FRAME_HIDE' then if isBanker(...) and bankOpen then setBankOpen(false) end
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
