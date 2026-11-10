# Simulates several WoW clients running GuildBankToons.lua on one guild channel.
# Usage: pip install lupa; python3 tests/sync_sim.py GuildBankToons.lua
import sys, random
from lupa import LuaRuntime
SRC=open(sys.argv[1]).read()
clock={'t':1000.0}; SERVER0=1793600000
STUB=r'''
local env=...
local function noop() end
-- Unknown methods are no-ops; fields a template may or may not have (and the addon's own lowercase fields) are nil.
local NILS={TitleText=true,Instructions=true,ScrollBar=true,Text=true}
local Obj={} ; Obj.__index=function(t,k)
  local v=rawget(Obj,k); if v~=nil then return v end
  if NILS[k] or (type(k)=='string' and k:match('^%l')) then return nil end
  return noop
end
function Obj:Show() rawset(self,'_shown',true) end
function Obj:Hide() rawset(self,'_shown',false) end
function Obj:SetShown(v) rawset(self,'_shown',v and true or false) end
function Obj:IsShown() return rawget(self,'_shown')==true end
function Obj:GetHeight() return 300 end
function Obj:GetWidth() return 600 end
function Obj:SetPoint(...) rawset(self,'_point',{...}) end
function Obj:SetText(v) rawset(self,'_text',v) end
function Obj:GetText() return rawget(self,'_text') end
function Obj:SetScript(name,fn) rawset(self,'_'..name,fn) end
function Obj:HookScript(name,fn) rawset(self,'_'..name,fn) end
function Obj:CreateFontString() return setmetatable({},Obj) end
function Obj:CreateTexture() return setmetatable({},Obj) end
function Obj:RegisterEvent(e) self._events[e]=true end
CreateFrame=function() local o=setmetatable({_events={}},Obj); env.frames[#env.frames+1]=o; return o end
UIParent={}; UISpecialFrames={}; SlashCmdList={}
GameTooltip=setmetatable({lines={}},Obj); ItemRefTooltip=nil
function GameTooltip:GetItem() return 'x','|Hitem:'..env.tooltipItem..'|h' end
function GameTooltip:AddDoubleLine(a,b) table.insert(self.lines,tostring(a)..' = '..tostring(b)) end
local function editBox() local t={} t.SetText=function(_,v) t.text=v end t.GetText=function() return t.text end return t end
MailFrame=setmetatable({},Obj); function MailFrame:IsShown() return env.mailOpen end
SendMailNameEditBox=editBox(); SendMailSubjectEditBox=editBox(); SendMailBodyEditBox=editBox()
env.attached={}
-- Like the game: attaching a split straight from the cursor sends the whole stack it came from.
ClickSendMailItemButton=function(i)
  local c=env.cursor
  if not c then return end
  local source=env.bags[c.bag][c.slot]
  local count=c.split and source[2] or c.count
  table.insert(env.attached,{slot=i,from={bag=c.bag,slot=c.slot,count=count,split=c.split}})
  if not c.split then env.bags[c.bag][c.slot]=nil end
  env.cursor=nil
end
GetSendMailItem=function(i)
  if SENDITEMS and SENDITEMS[i] then return 'Item'..SENDITEMS[i][1],SENDITEMS[i][1],nil,SENDITEMS[i][2],1 end
  for _,a in ipairs(env.attached) do if a.slot==i then return 'item' end end
end
SetSendMailMoney=function(c) env.sendMoney=c end
-- A 140x140 minimap; MINIMAP_SHAPE as GetMinimapShape reports it.
Minimap=setmetatable({},Obj)
function Minimap:GetWidth() return 140 end
function Minimap:GetHeight() return 140 end
GetMinimapShape=function() return MINIMAP_SHAPE or 'ROUND' end
-- The guild bank: VAULT={money=, tabs={{name=, hidden=, items={{id,count},...}}, ...}}
GetNumGuildBankTabs=function() return VAULT and #VAULT.tabs or 0 end
GetGuildBankTabInfo=function(t) local tab=VAULT.tabs[t]; return tab.name,'icon',not tab.hidden end
GetGuildBankItemLink=function(t,slot) local it=VAULT.tabs[t].items[slot]; if it then return '|Hitem:'..it[1]..'|h' end end
GetGuildBankItemInfo=function(t,slot) local it=VAULT.tabs[t].items[slot]; if it then return 'tex',it[2] end end
GetGuildBankMoney=function() return VAULT and VAULT.money or 0 end
QueryGuildBankTab=function() end
-- The guild bank log: tabs[t].log={{type,who,itemID,count,days,hours},...}, moneylog={{type,who,copper,days,hours},...}
GetNumGuildBankTransactions=function(t) local tab=VAULT and VAULT.tabs[t]; return tab and tab.log and #tab.log or 0 end
GetGuildBankTransaction=function(t,i) local e=VAULT.tabs[t].log[i]; return e[1],e[2],'|Hitem:'..e[3]..'|h',e[4],nil,nil,0,0,e[5] or 0,e[6] or 0 end
GetNumGuildBankMoneyTransactions=function() return VAULT and VAULT.moneylog and #VAULT.moneylog or 0 end
GetGuildBankMoneyTransaction=function(i) local e=VAULT.moneylog[i]; return e[1],e[2],e[3],0,0,e[4] or 0,e[5] or 0 end
QueryGuildBankLog=function() end
MAX_GUILDBANK_TABS=8
MAX_GUILDBANK_SLOTS_PER_TAB=98
GetSendMailMoney=function() return env.sendMoney or 0 end
-- INBOX: {{sender=, subject=, money=, items={{id,count},...}}, ...}
GetInboxNumItems=function() return INBOX and #INBOX or 0 end
GetInboxHeaderInfo=function(i) local m=INBOX[i]; return nil,nil,m.sender,m.subject,m.money or 0,0,30,#(m.items or {})>0,false,false end
GetInboxItem=function(i,a) local it=INBOX[i].items and INBOX[i].items[a]; if it then return 'Item'..it[1],it[1],nil,it[2],1 end end
ClearCursor=function() env.cursor=nil end
SendMail=function(to) env.mailedTo=to end
hooksecurefunc=function(name,fn) local orig=_G[name]; _G[name]=function(...) local r=orig(...); fn(...); return r end end
C_Timer={After=function(s,fn) env.later(s,fn) end}
C_ChatInfo={SendAddonMessage=function(p,m,c) env.send(p,m,c) return true end, RegisterAddonMessagePrefix=noop,
  SendChatMessage=function(m,kind,_,target) env.whisper(m,kind,target) end}
print=function(s) env.log(tostring(s)) end
GetNumGuildMembers=function() return env.members() end
GetGuildRosterInfo=function(i) return env.member(i) end
StaticPopupDialogs={}
StaticPopup_Show=function(name) env.popup(name) end
PlaySound=noop; SOUNDKIT={TELL_MESSAGE=1}
-- Picking up with a split on the cursor puts it down in that (empty) slot, as in the game. The backpack has 16 slots.
C_Container={PickupContainerItem=function(b,s)
    local c=env.cursor
    if c and c.split then
      local source=env.bags[c.bag][c.slot]
      env.bags[b][s]={source[1],c.count}; source[2]=source[2]-c.count; env.cursor=nil
      return
    end
    local it=env.bags[b][s]
    env.cursor=it and {bag=b,slot=s,count=it[2]} or nil
  end,
  SplitContainerItem=function(b,s,n) env.cursor={bag=b,slot=s,count=n,split=true} end,
  GetContainerNumSlots=function(b) local bag=env.bags[b]; if not bag then return 0 end; return b==0 and 16 or #bag end,
  GetContainerItemInfo=function(b,s) local it=env.bags[b] and env.bags[b][s]; if it then return {itemID=it[1],stackCount=it[2]} end end}
GetItemInfo=function(id) return 'Item'..id,'|Hitem:'..id..'|h',1 end
GetTime=function() return env.now() end
GetServerTime=function() return env.server() end
-- WoW: Forever: UnitName gives the first name and the surname (when the client knows it yet).
UnitName=function() return env.unit,env.surname end
GetBuildInfo=function() return '1.16.1','70425','Nov 1 2026',16001 end
UnitGUID=function() return env.guid end
GetRealmName=function() return 'Nek\'Rosh' end
IsInGuild=function() return true end
GetGuildInfo=function() return 'Verdant' end
GetGuildInfoText=function() return env.guildinfo end
GetMoney=function() return env.gold end
IsInInstance=function() return false end
InCombatLockdown=function() return false end
NUM_BAG_SLOTS=4; NUM_BANKBAGSLOTS=6; BANK_CONTAINER=-1
'''
class Client:
    def __init__(s,name,bus,unit=None):
        s.L=LuaRuntime(unpack_returned_tuples=True); s.name=name; s.bus=bus; s.online=False
        first,_,last=name.partition(' ')
        s.env=s.L.table_from({'frames':s.L.table(),'name':name,'unit':unit or first,'surname':last or None,'guid':'Player-1-'+name.replace(' ',''),'guildinfo':'Bank stuff [GBT:Vault Keeper]','gold':0,'bags':s.L.table()})
        s.env.now=lambda:clock['t']; s.env.server=lambda:int(SERVER0+clock['t'])
        s.env.send=lambda p,m,c: bus.send(s,p,m)
        s.env.later=lambda sec,fn: bus.later(s,sec,fn)
        s.whispers=[]; s.logs=[]; s.popups=[]
        s.env.whisper=lambda m,kind,target: s.whispers.append((kind,target,m))
        s.env.log=lambda m: s.logs.append(m)
        s.env.popup=lambda name: s.popups.append(name)
        s.env.members=lambda: len(bus.roster())
        s.env.member=lambda i: bus.member(i)
        s.L.execute(STUB,s.env) if False else s.L.eval('function(...) '+STUB+' end')(s.env)
        s.saved=None
    def frame(s): return s.env.frames[1]
    def fire(s,ev,*a):
        h=s.frame()['_OnEvent']
        if h: h(s.frame(),ev,*a)
    def login(s):
        s.env.frames=s.L.table(); g=s.L.globals(); g.GuildBankToonsDB=s.saved
        s.L.eval('function(src,name) return assert(load(src,"@GuildBankToons.lua"))(name) end')(SRC,'GuildBankToons')
        s.online=True
        s.fire('ADDON_LOADED','GuildBankToons'); s.fire('PLAYER_LOGIN'); s.fire('GUILD_ROSTER_UPDATE')
    def logout(s):
        s.fire('PLAYER_LOGOUT'); s.saved=s.L.globals().GuildBankToonsDB; s.online=False
        s.L=None if False else s.L
    def tick(s,dt):
        u=s.frame()['_OnUpdate']
        if u: u(s.frame(),dt)
    def setbags(s,items,bank=None):
        t=s.L.table()
        t[0]=s.L.table_from([s.L.table_from(i) for i in items])
        if bank is not None: t[-1]=s.L.table_from([s.L.table_from(i) for i in bank])
        s.env.bags=t
    def snap(s,who='vaultkeeper'):
        db=s.L.globals().GuildBankToonsDB
        g=db and db.guilds["Verdant"]
        b=g and g.banks[who]
        if not b: return None
        return dict(stamp=b.stamp,hash=b.hash,via=b.via,gold=b.gold,bags=dict(b.bags.items()) if b.bags else {},bank=dict(b.bank.items()) if b.bank else {})
class Bus:
    def __init__(s): s.clients=[]; s.timers=[]; s.count=0; s.ranks={}; s.always_online=set(); s.log=[]
    def roster(s):
        return sorted(s.ranks)
    # How Forever writes a character in senders and the roster: First-Surname, sometimes with a realm
    # added (our own, or another ruleset's with digits in it).
    suffix={'Alice':'-NekRosh','Olivia Stone':'-CAMWOWUS2Realm2PvE','Coin Purse':'-NekRosh'}
    def wire(s,name): return name.replace(' ','-')+s.suffix.get(name,'')
    def member(s,i):
        name=s.roster()[int(i)-1]
        online=name in s.always_online or any(c.online and c.name==name for c in s.clients)
        return (s.wire(name),'',s.ranks[name],0,'','','','',online)
    def send(s,frm,p,m):
        s.count+=1; s.log.append((frm.name,m))
        if getattr(frm,'mute',None) and frm.mute(m): return
        sender=s.wire(frm.name)
        for c in s.clients:
            if c.online: c.fire('CHAT_MSG_ADDON',p,m,'GUILD',sender)
    def later(s,c,sec,fn): s.timers.append([clock['t']+sec,c,fn])
    def run(s,seconds):
        end=clock['t']+seconds
        while clock['t']<end:
            clock['t']+=0.05
            for t in [t for t in s.timers if t[0]<=clock['t']]:
                s.timers.remove(t)
                if t[1].online: t[2]()
            for c in s.clients:
                if c.online: c.tick(0.05)
bus=Bus()
bank=Client('Vault Keeper',bus,'Vault'); m1=Client('Alice',bus); m2=Client('Bob',bus); evil=Client('Mallory',bus)
officer=Client('Olivia Stone',bus,'Olivia')
# This client's UnitName gives no surname yet, so it has to learn its full name from its own message.
officer.env.surname=None
gm=Client('Gwen Master',bus,'Gwen'); purse=Client('Coin Purse',bus,'Coin')
bus.clients=[bank,m1,m2,evil,officer,gm,purse]
# Pete is an officer who doesn't run the addon.
bus.ranks={'Vault Keeper':3,'Alice':4,'Bob':4,'Mallory':4,'Olivia Stone':1,'Pete':1,'Gwen Master':0,'Coin Purse':3}; bus.always_online={'Pete'}
ok=True
def check(label,cond):
    global ok; ok&=bool(cond); print(('PASS ' if cond else 'FAIL ')+label)

ids=None
def forms_ok():
    g=bank.L.globals().GuildBankToons
    forms=["Vault Keeper","Vault-Keeper","vault keeper","Vault-Keeper-NekRosh","Vault-Keeper-Nek'Rosh","Vault Keeper-CAMWOWUS2Realm2PvE","Vault-Keeper-CAMWOWUS2Realm2PvE"]
    return all(g.nameId(f)=='vaultkeeper' for f in forms) and g.baseName('Vault-Keeper-CAMWOWUS2Realm2PvE')=='Vault Keeper' and g.nameId('Alice-NekRosh')=='alice'
bank.env.gold=50000; bank.setbags([[2589,20],[2589,20],[14047,5]],bank=[[4306,100]])
bank.login(); m1.login()
bank.fire('BANKFRAME_OPENED'); bus.run(1); bank.fire('BANKFRAME_CLOSED')
bus.run(30)
s=m1.snap(); b=bank.snap()
check('Forever names match in every form the game writes them (First-Surname, spaces, added realms)', forms_ok())
check('UnitName\'s surname gives the full name straight away', bank.L.globals().GuildBankToons and m1.L.globals().GuildBankToonsDB.guilds["Verdant"].banks.vaultkeeper.owner=='Vault Keeper')
check('bank alt learned its surname from its own echo', bank.L.globals().GuildBankToonsDB.knownAs['Player-1-VaultKeeper']=='Vault Keeper')
check('bank alt scanned bags and bank', b and b['bags'].get(2589)==40 and b['bank'].get(4306)==100)
check('online member got snapshot directly from bank alt', s and s['hash']==b['hash'] and s['via'] is None)

bank.logout(); bus.run(5)
m2.login(); bus.run(20)
s2=m2.snap()
check('member logging in later gets relayed copy while bank alt offline', s2 and s2['hash']==b['hash'] and s2['via']=='Alice')

# bank alt changes stuff while Bob offline, Alice online
m2.logout()
bank.login(); bus.run(8)
bank.env.gold=60000; bank.setbags([[2589,5]]); bank.fire('BAG_UPDATE_DELAYED'); bus.run(30)
b2=bank.snap()
check('bank kept from last visit after bag-only rescan', b2['bank'].get(4306)==100 and b2['bags'].get(2589)==5)
check('online member receives push after change', m1.snap()['hash']==b2['hash'])
bank.logout(); m1.logout(); bus.run(2)
m2.login(); bus.run(15)
check('stale member alone keeps old copy (nobody to ask)', m2.snap()['hash']==b['hash'])
m1.login(); bus.run(20)
check('stale member updates when holder of newer copy logs in', m2.snap()['hash']==b2['hash'])

# forgery: Mallory relays a fake newer copy
evil.login(); bus.run(20)
fake_stamp=int(SERVER0+clock['t'])+300
evil.L.execute('''
local q={}
local function send(m) C_ChatInfo.SendAddonMessage('GBTOONS',m,'GUILD') end
''')
# craft fake with valid hash using the addon's own hash fn: easiest is mutate Mallory's copy and send it
evil.L.eval('''function(stamp)
  local g=GuildBankToonsDB.guilds["Verdant"]
  local s=g.banks["vaultkeeper"]
  s.bags={[19019]=1}; s.gold=99999999
  local h=(s.gold)%16777213
  local e={"b:19019:1"}; for _,x in ipairs({}) do end
  for id,c in pairs(s.bank) do e[#e+1]="k:"..id..":"..c end
  table.sort(e)
  for _,x in ipairs(e) do for i=1,#x do h=(h*31+x:byte(i))%16777213 end h=(h*31+10)%16777213 end
  s.hash=h; s.stamp=stamp
  local function send(m) C_ChatInfo.SendAddonMessage('GBTOONS',m,'GUILD') end
  send("B|Vault Keeper-Nek'Rosh|"..stamp.."|"..h.."|"..s.gold.."|0|"..#e)
  send("I|Vault Keeper-Nek'Rosh|"..stamp.."|"..table.concat(e,","))
  send("E|Vault Keeper-Nek'Rosh|"..stamp)
end''')(fake_stamp)
bus.run(5)
check('forged relay is accepted while bank alt offline (known limit)', m1.snap()['bags'].get(19019)==1)
bank.login(); bus.run(30)
fb=bank.snap()
check('bank alt outbids forged copy when it logs in', fb['stamp']>fake_stamp and m1.snap()['hash']==fb['hash'] and m2.snap()['hash']==fb['hash'] and m1.snap()['bags'].get(19019) is None)
far=int(SERVER0+clock['t'])+5000
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"R|Vault Keeper-Nek'Rosh|"..stamp.."|1",'GUILD') end''')(far)
bus.run(10)
check('far-future stamp ignored by members', m1.snap()['hash']==fb['hash'])
check('far-future stamp does not drag the bank character\'s stamp ahead', bank.snap()['stamp']<int(SERVER0+clock['t'])+600)

# --- requests ---
def slash(c,text): c.L.globals().SlashCmdList.GUILDBANKTOONS(text)
def requests_of(c):
    g=c.L.globals().GuildBankToonsDB.guilds["Verdant"]
    return sorted((g.requests.values() if g.requests else []), key=lambda r: r.id)
def latest(c):
    reqs=requests_of(c)
    return max(reqs,key=lambda r: int(r.id.split('-')[1])) if reqs else None
def tooltip(c,item):
    tt=c.L.globals().GameTooltip; c.env.tooltipItem=item
    tt.lines=c.L.table(); tt._OnTooltipSetItem(tt)
    return list(tt.lines.values())
m2.logout()
bank.setbags([[2589,20],[2589,20],[2589,5]]); bank.fire('BAG_UPDATE_DELAYED'); bus.run(15)
officer.login(); bus.run(20)
check('officer learned surname', officer.L.globals().GuildBankToonsDB.knownAs['Player-1-OliviaStone']=='Olivia Stone')
m1.L.globals().GuildBankToonsDB.settings.companion=True
slash(m1,'request 2589 30 for my alt'); bus.run(12)
r=latest(officer)
check('officer receives request', r and r.status=='open' and r.count==30 and r.note=='for my alt')
check('officer client alerted', any('requests 30x' in l for l in officer.logs))
check('requester whispered only the officer without the addon', [w[1] for w in m1.whispers]==["Pete"])
check('requester got the Discord reload prompt', 'GUILDBANKTOONS_RELOAD' in m1.popups)
rid=r.id; stamp=int(r.updated)+5
evil.L.eval("""function(id,stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"Q|Alice-Nek'Rosh|"..id.."|"..stamp.."|approved|Vault Keeper|2589|30|Mallory|Mallory|for my alt",'GUILD') end""")(rid,stamp)
bus.run(3)
check('non-officer cannot approve', latest(officer).status=='open' and latest(m1).status=='open')
slash(m1,'approve 1')
check('requester cannot approve their own', latest(m1).status=='open')
slash(officer,'approve 1'); bus.run(5)
check('approval reaches requester and bank', latest(m1).status=='approved' and latest(bank).status=='approved' and latest(m1).approvedBy=='Olivia Stone')
check('requester told it was approved', any('|cff40ff40approved|r by Olivia Stone' in l for l in m1.logs))
check('bank character told to mail it', any('mail 30x' in l and 'Alice' in l for l in bank.logs))
check('approved items reserved in tooltips', any('15 |cffff8040(30 reserved)|r' in l for l in tooltip(m1,2589)))
bank.env.mailOpen=True; bank.fire('MAIL_SHOW')
slash(bank,'mail'); bus.run(1)
att=[dict(a.items()) for a in bank.env.attached.values()]
cur=[dict(a['from'].items()) for a in att]
check('mail helper addresses the requester', bank.L.globals().SendMailNameEditBox.text=='Alice')
check('mail helper attaches exactly 30, splitting one stack into an empty slot first', sum(c['count'] for c in cur)==30 and len(cur)==3 and not any(c.get('split') for c in cur))
bank.L.globals().SendMail('Alice','Guild bank','hi'); bank.fire('MAIL_SEND_SUCCESS'); bus.run(5)
check('sending the mail marks it mailed everywhere', latest(bank).status=='mailed' and latest(m1).status=='mailed' and latest(officer).status=='mailed')
check('requester told it was mailed', any('was |cffffd100mailed|r' in l for l in m1.logs))
check('reservation released after mailing', not any('reserved' in l for l in tooltip(m1,2589)))
evil.L.eval("""function(id,stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"Q|Alice-Nek'Rosh|"..id.."|"..stamp.."|approved|Vault Keeper|2589|30|Olivia Stone|Olivia Stone|for my alt",'GUILD') end""")(rid,stamp+100)
bus.run(3)
check('a stale approval cannot reopen a mailed request', latest(m1).status=='mailed')
slash(m1,'request 2589 1'); bus.run(10)
slash(bank,'approve 1'); bus.run(5)
check('bank character can approve', latest(officer).status=='approved')
slash(officer,'mailed 1')
check('only the bank character marks mailed', latest(officer).status=='approved')
slash(bank,'mailed 1'); bus.run(5)
check('bank character marks mailed by hand', latest(m1).status=='mailed')
slash(m1,'request 2589 2'); bus.run(10)
slash(m1,'cancel 1'); bus.run(5)
check('requester cancels while waiting', latest(officer).status=='cancelled')
m2.login(); bus.run(20)
check('member offline the whole time catches up at login', len(requests_of(m2))==3 and all(q.status in ('mailed','cancelled') for q in requests_of(m2)))

# --- bank characters set by the guild master ---
def managed(c):
    g=c.L.globals().GuildBankToonsDB.guilds["Verdant"]
    return sorted(g.managed.keys()) if g.managed else []
gm.login(); bus.run(20)
slash(m1,'bank add Coin Purse'); bus.run(5)
check('a member cannot set guild bank characters', managed(officer)==[] and any('Only officers and the guild master' in l for l in m1.logs))
slash(gm,'bank add Coin Purse'); slash(gm,'bank add Spare Change'); bus.run(10)
check('guild master\'s bank list reaches everyone online', all(managed(c)==['coinpurse','sparechange'] for c in (m1,m2,officer,bank)))
purse.env.gold=12345; purse.setbags([[2592,7]],bank=[[2770,40]])
purse.login(); bus.run(3); purse.fire('BANKFRAME_OPENED'); bus.run(1); purse.fire('BANKFRAME_CLOSED'); bus.run(30)
p=m1.snap('coinpurse')
check('a GM-set bank character shares its contents', p and p['bags'].get(2592)==7 and p['bank'].get(2770)==40)
check('guild info bank character still shared alongside it', m1.snap()['hash']==bank.snap()['hash'])
check('tooltips cover every bank character', any('Coin Purse' in l for l in tooltip(m1,2592)))
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"M|Mallory|"..stamp.."|1|1|Mallory",'GUILD') end''')(int(SERVER0+clock['t'])+5)
bus.run(3)
check('a list from someone who is not the guild master is ignored', managed(m1)==['coinpurse','sparechange'])
gm.logout(); m2.logout(); bus.run(2)
m2.saved.guilds["Verdant"].managed=m2.L.table(); m2.saved.guilds["Verdant"].managedStamp=None
m2.login(); bus.run(20)
check('member logging in while the guild master is offline gets the list relayed', managed(m2)==['coinpurse','sparechange'])
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"M|Gwen Master|"..stamp.."|1|1|Mallory",'GUILD') end''')(int(SERVER0+clock['t'])+5)
bus.run(3)
check('a forged guild master list is accepted while the guild master is offline (known limit)', managed(m1)==['mallory'])
gm.login(); bus.run(30)
check('guild master\'s real list wins when they log in', all(managed(c)==['coinpurse','sparechange'] for c in (m1,m2,officer,gm)))
slash(gm,'bank remove Spare Change'); bus.run(10)
check('guild master removes a bank character everywhere', all(managed(c)==['coinpurse'] for c in (m1,m2,officer)))
slash(m1,'remove Coin Purse')
check('members cannot drop a GM-set bank character', managed(m1)==['coinpurse'])

# --- window ---
GBT=lambda c: c.L.globals().GuildBankToons
bank.setbags([[2589,20],[2589,20],[2589,5]]); bank.fire('BAG_UPDATE_DELAYED')
purse.setbags([[2592,7],[2589,5]]); purse.fire('BAG_UPDATE_DELAYED'); bus.run(20)
rows=GBT(m1).itemRows(None,'all','','name')
cloth=[r for r in rows.values() if r.id==2589]
check('items on several toons are totalled with each toon listed', cloth and cloth[0].total==50 and len(cloth[0].toons)==2
      and 'Vault Keeper' in cloth[0].where and 'Coin Purse' in cloth[0].where)
only=[r for r in GBT(m1).itemRows('coinpurse','all','','name').values() if r.id==2589]
check('picking one toon shows only its share', only and only[0].total==5)
check('search filters items', all('2592' in r.name for r in GBT(m1).itemRows(None,'all','item2592','name').values()))
slash(m1,''); bus.run(1)
for tab in ('requests','settings','gm','items'):
    GBT(m1).open(tab); bus.run(1)
for draw in ('refreshItems','refreshRequests','refreshSettings','refreshGM'):
    GBT(m1)[draw]()
GBT(m1).openRequestDialog(cloth[0]); bus.run(1)
check('the request dialog picks the toon with the most available', GBT(m1).bestToon(2589)=='Vault Keeper')
GBT(gm).open('gm'); bus.run(1)
check('every tab draws without errors', True)

# --- donations ---
def donations(c):
    g=c.L.globals().GuildBankToonsDB.guilds["Verdant"]
    return {k:v for k,v in g.donations.items()} if g.donations else {}
m1.env.mailOpen=True; m1.fire('MAIL_SHOW'); bus.run(1)
GBT(m1).startDonation('Vault Keeper',20000,'for the raid')
subject=m1.L.globals().SendMailSubjectEditBox.text
check('donate fills the mail to the bank toon with a reference', m1.L.globals().SendMailNameEditBox.text=='Vault Keeper' and subject.startswith('Guild bank donation #'))
m1.L.execute('SENDITEMS={{2589,20},{2592,3}}')
m1.L.globals().SendMail('Vault Keeper',subject,''); m1.fire('MAIL_SEND_SUCCESS'); bus.run(5)
did=[d for d in donations(officer).values() if d.by=='Alice']
check('a sent donation reaches the guild log as on its way', len(did)==1 and did[0].status=='sent' and did[0]['items'][2589]==20 and did[0].money==20000)
bank.L.execute('INBOX={{sender="Alice", subject=%r, money=20000, items={{2589,20},{2592,3}}}, {sender="Pete", subject="hi", money=0, items={{4306,10}}}}'.replace('%r','"'+subject+'"'))
bank.env.mailOpen=True; bank.fire('MAIL_SHOW'); bus.run(5)
d=[d for d in donations(officer).values() if d.by=='Alice'][0]
check('the bank toon confirms the donation when it opens its mailbox', d.status=='received' and len([x for x in donations(officer).values() if x.by=='Alice'])==1)
check('the donor is thanked when it arrives', any('received your donation' in l for l in m1.logs))
pete=[d for d in donations(officer).values() if 'Pete' in d.by]
check('mail from a guildmate without the addon is logged as a donation', len(pete)==1 and pete[0]['items'][4306]==10 and pete[0].status=='received')
bank.fire('MAIL_INBOX_UPDATE'); bus.run(3)
check('opening the mailbox again logs nothing twice', len(donations(officer))==2)
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"D|Mallory|mallory-x|"..stamp.."|received|Vault Keeper|0|"..stamp.."|19019:1|Mallory|",'GUILD') end''')(int(SERVER0+clock['t']))
bus.run(3)
check('only the bank toon can confirm a donation', 'mallory-x' not in donations(officer))
m2.logout(); bus.run(2); m2.login(); bus.run(25)
check('donations sync to a guildmate who logs in later', len(donations(m2))==2)
GBT(m1).open('donations'); bus.run(1); GBT(m1).refreshDonations()
GBT(m1).open('items'); m1.L.globals().GuildBankToonsDB.ui.view='grid'; GBT(m1).refreshItems()
m1.L.globals().GuildBankToonsDB.ui.view='list'; GBT(m1).refreshItems()
check('donations tab and both bank views draw', True)

# --- asking for the newest copy: offers, one ask, fallback ---
def since(mark,prefix): return [(who,m) for who,m in bus.log[mark:] if m.startswith(prefix)]
def vk(c): return c.L.globals().GuildBankToonsDB.guilds["Verdant"].banks
bank.logout(); bus.run(2)
newest=vk(m1).vaultkeeper.stamp
vk(officer).vaultkeeper.stamp=newest-10
vk(m2).vaultkeeper=None
mark=len(bus.log); slash(m2,'sync'); bus.run(25)
asks=since(mark,'G|Vault Keeper|')
check('the newest copy is asked for, not an older one', len(asks)==1 and 'Olivia' not in asks[0][1])
check('only that one guildmate sends the bank copy', len(since(mark,'B|Vault Keeper|'))==1 and m2.snap()['stamp']==newest)
check('at most 3 guildmates offer the newest copy', len([m for _,m in since(mark,'O|Vault Keeper|') if m.split('|')[2]==str(newest)])<=3)
# Whoever is asked first goes quiet: their copy never goes out.
quiet={}
def mute(c):
    def drop(m):
        if m.startswith('G|Vault Keeper|') and 'who' not in quiet: quiet['who']=m.split('|')[-1]
        return quiet.get('who')==c.name and m[:2] in ('B|','I|','E|')
    return drop
for c in bus.clients: c.mute=mute(c)
vk(m2).vaultkeeper=None
mark=len(bus.log); slash(m2,'sync'); bus.run(30)
asks=since(mark,'G|Vault Keeper|')
check('if the chosen guildmate doesn\'t answer in 2 seconds, the next newest is asked',
      len(asks)==2 and asks[0][1]!=asks[1][1] and m2.snap() and m2.snap()['stamp']==newest)
for c in bus.clients: c.mute=None
bank.login(); bus.run(20)

# --- guild plan: goals, needs and rules ---
def plan(c): return c.L.globals().GuildBankToonsDB.guilds["Verdant"].plan
officer.L.execute("""local p=GuildBankToons.copyPlan()
p.goals.g1={name="Raid fund",target=1000000,toon="*"}
p.wants[2589]=200; p.wants[9999]=5; p.wants[4306]=50
p.rules.autoMax=5; p.rules.autoRank=4; p.rules.limit=100
GuildBankToons.setPlan(p)""")
bus.run(20)
check("an officer's goals, needs and rules reach everyone", all(plan(c) and plan(c).goals.g1 and plan(c).wants[2589]==200 and plan(c).rules.autoMax==5 for c in (m1,m2,bank,gm)))
m1.L.execute('local p=GuildBankToons.copyPlan(); p.wants[2589]=1; GuildBankToons.setPlan(p)'); bus.run(5)
check('members cannot change the plan', plan(officer).wants[2589]==200 and plan(m1).wants[2589]==200)
evil.L.eval("""function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"K|Mallory|"..stamp.."|1|1|w~2589~1",'GUILD') end""")(int(SERVER0+clock['t'])+5)
bus.run(3)
check('a plan from a non-officer is ignored', plan(m2).wants[2589]==200)
needs={r.id:r for r in GBT(m1).itemRows(None,'needs','','name').values()}
check('the Needs view lists wanted items, held or not, with what is short', 9999 in needs and needs[9999].short==5 and needs[2589].short>0)
before=len(requests_of(officer))
slash(m1,'request 2589 2'); bus.run(12)
check('small requests from eligible ranks are approved automatically', latest(officer).status=='approved' and latest(officer).count==2)
slash(m1,'request 2589 90'); bus.run(5)
check('the daily limit stops a request that would go over it', latest(officer).count==2 and any('limit is 100' in l for l in m1.logs))
GBT(m1).createRequest(0,1,'repairs','Vault Keeper'); bus.run(8)
gr=latest(officer)
check('members can request gold', gr.item==0 and gr.count==1)
GBT(officer).setRequestStatus(gr,'approved'); bus.run(8)
bank.env.mailOpen=True; bank.fire('MAIL_SHOW'); bank.env.sendMoney=0
GBT(bank).fillMail(latest(bank)); bus.run(1)
check('the mail helper puts the gold in the mail', bank.env.sendMoney==10000)
bank.L.globals().SendMail('Alice','Guild bank: 1g',''); bank.fire('MAIL_SEND_SUCCESS'); bus.run(8)
out=[e for e in GBT(m1).ledger().values() if e.kind=='out' and e.money==10000]
check('what a bank toon mails goes in the ledger, with what was really in the mail', len(out)==1 and out[0].to=='Alice')
# The first change after logging in goes out whole (the bank toon can't know what others hold); the next is a delta.
bank.setbags([[2589,20],[2589,20],[2589,5],[2592,2]]); bank.fire('BAG_UPDATE_DELAYED'); bus.run(25)
mark=len(bus.log)
bank.setbags([[2589,20],[2589,20],[2589,5],[2592,2]],bank=[[4306,10]]); bank.fire('BANKFRAME_OPENED'); bus.run(1); bank.fire('BANKFRAME_CLOSED'); bus.run(25)
check('a small change goes out as just the changes', len(since(mark,'U|Vault Keeper|'))==1 and len(since(mark,'B|Vault Keeper|'))==0)
check('guildmates apply the changes', m1.snap()['hash']==bank.snap()['hash'] and m1.snap()['bank'].get(4306)==10)
check('officers are told when a wanted item runs low', any('Low stock' in l and '4306' in l for l in officer.logs))
vk(m2).vaultkeeper.stamp=vk(m2).vaultkeeper.stamp-50
bank.setbags([[2589,20],[2589,20],[2589,6]]); bank.fire('BAG_UPDATE_DELAYED'); bus.run(40)
check('a guildmate missing the base copy asks for the whole thing', m2.snap()['hash']==bank.snap()['hash'])
bank.L.execute('INBOX={{sender="Coin Purse", subject="restock", money=0, items={{2592,4}}}}')
bank.fire('MAIL_INBOX_UPDATE'); bus.run(5)
moved=[d for d in donations(officer).values() if d.status=='moved']
check('mail between bank toons is logged as a move, not a donation', len(moved)==1 and moved[0].by=='Coin Purse')
series=list(GBT(m1).goldSeries(30,'*').values())
check('gold history builds up for the chart', series[-1]==GBT(m1).currentGold('*') and series[-1]>0)
inv=GBT(m1).exportText('inventory','csv'); led=GBT(m1).exportText('ledger','csv'); gold=GBT(m1).exportText('gold','csv')
check('inventory export has a column per bank toon', inv.startswith('Item ID,Item,Quality,Available,Reserved,Total') and 'Vault Keeper' in inv.split('\n')[0])
check('ledger export lists donations, moves and mail out', all(k in led for k in ('Donation','Move','Mail out')))
check('gold export has the history', gold.startswith('Date,') and len(gold.split('\n'))>1)
db1=m1.L.globals().GuildBankToonsDB
for tab in ('goals','donations','gm','items'):
    GBT(m1).open(tab); bus.run(0.5)
for sub in ('toons','goals','needs','rules'):
    db1.ui.guildSub=sub; GBT(m1).refreshGuild()
db1.ui.filter='needs'; GBT(m1).refreshItems(); db1.ui.filter='all'
GBT(m1).openExport('ledger'); GBT(m1).refreshExport(); GBT(m1).openGoldRequest()
check('Goals, Ledger and Guild tabs, the export window and gold requests draw', True)

# --- requests for several items, and craft orders (what GuildForge will use) ---
API=lambda c: c.L.globals().GuildBankToonsAPI
bank.setbags([[2589,20],[2589,20],[2589,6],[4306,5]]); bank.fire('BAG_UPDATE_DELAYED'); bus.run(25)
total,per=API(m1).Available(2589)
check('other addons can see the guild bank and what it has, per bank toon', API(m1).version==1 and API(m1).HasBank() and total>0 and per['Vault Keeper']>0)
made,missing,why=API(m1).Request(m1.L.table_from({2589:2,4306:1}),'for bandages','Olivia Stone'); bus.run(10)
r=latest(officer)
check('several items go in one request, as a craft order mailed to the crafter',
      len(list(made.values()))==1 and r['items'] and r['items'][2589]==2 and r['items'][4306]==1 and r.to=='Olivia Stone')
if r.status=='open': GBT(officer).setRequestStatus(r,'approved'); bus.run(8)
bank.env.attached=bank.L.table(); bank.env.mailOpen=True; bank.fire('MAIL_SHOW')
GBT(bank).fillMail([q for q in requests_of(bank) if q.id==r.id][0]); bus.run(2)
att=[dict(dict(a.items())['from'].items()) for a in bank.env.attached.values()]
check('the mail helper addresses a craft order to the crafter, with exactly the items asked for',
      bank.L.globals().SendMailNameEditBox.text=='Olivia Stone' and sorted(a['count'] for a in att)==[1,2])
bank.L.globals().SendMail('Olivia Stone','x',''); bank.fire('MAIL_SEND_SUCCESS'); bus.run(8)
check('the crafter is told the materials are in the mail', any('craft order are in your mail' in l for l in officer.logs) and latest(m1).status=='mailed')
none=API(m1).Request(m1.L.table_from({123456:1}),'x',None)
check('asking for something the bank does not have says so', len(list(none[0].values()))==0 and none[2])

# --- Forever's guild bank ---
# An officer opens it first: nobody of the lowest rank has said what's public yet, so nothing is shared.
officer.L.execute('VAULT={money=1234567,tabs={{name="Mats",items={{2589,40},{2770,200}}},{name="Officers",items={{19019,1}}}}}')
officer.fire('GUILDBANKFRAME_OPENED'); bus.run(5); officer.fire('GUILDBANKFRAME_CLOSED'); bus.run(10)
check('nothing from the guild bank is shared until the lowest rank has said what is public', vk(m1)['*vault1'] is None and vk(officer)['*vault1'] is None)
m2.L.execute('VAULT={money=1234567,tabs={{name="Mats",items={{2589,40},{2770,200}}},{name="Officers",hidden=true,items={{19019,1}}}}}')
m2.fire('GUILDBANKFRAME_OPENED'); bus.run(5); m2.fire('GUILDBANKFRAME_CLOSED'); bus.run(12)
v=vk(m1)['*vault1']
check('opening the guild bank shares each tab you can see, with its gold', v and v.owner=='*vault1:Mats' and v.bank[2770]==200 and v.gold==1234567)
check('tabs your rank cannot see are not shared', vk(m1)['*vault2'] is None)
total,per=API(m1).Available(2770)
check('guild bank tabs count as part of the guild bank (alongside bank toons)', total==240 and per['Guild Bank - Mats']==200 and per['Coin Purse']==40)
check('guild bank gold counts toward the guild\'s gold', GBT(m1).currentGold('*')>=1234567)
GBT(m1).createRequest(2770,10,'ore','*vault1:Mats'); bus.run(10)
vr=latest(officer)
if vr.status=='open': GBT(officer).setRequestStatus(vr,'approved'); bus.run(6)
GBT(bank).setRequestStatus(latest(bank),'mailed'); bus.run(4)
check('a bank toon cannot mark a guild bank request mailed', latest(officer).status=='approved' and latest(officer).bank=='*vault1:Mats')
GBT(officer).setRequestStatus(latest(officer),'mailed'); bus.run(6)
check('an officer marks a guild bank request mailed', latest(m1).status=='mailed')
GBT(m1).open('items'); GBT(m1).refreshItems()

# --- only public guild bank tabs are shared ---
def tabs_of(c): return sorted(b.id for b in GBT(c).bankList().values() if b.id.startswith('*vault'))
officer.fire('GUILDBANKFRAME_OPENED'); bus.run(5); officer.fire('GUILDBANKFRAME_CLOSED'); bus.run(15)
check('an officer opening the guild bank shares only public tabs', vk(m1)['*vault2'] is None and tabs_of(m1)==['*vault1'])
check('a restricted tab is not even kept by the officer who saw it', vk(officer)['*vault2'] is None and API(officer).Available(19019)[0]==0)
check('everyone, guild master included, sees the same public tabs', tabs_of(officer)==tabs_of(gm)==tabs_of(bank)==['*vault1'])
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"W|Mallory|1|"..stamp.."|1:0,2:0",'GUILD') end''')(int(SERVER0+clock['t'])+5)
bus.run(3)
check('a member cannot report for another rank', tabs_of(officer)==['*vault1'])
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"B|*vault2:Officers|"..stamp.."|1|0|0|0",'GUILD')
  C_ChatInfo.SendAddonMessage('GBTOONS',"E|*vault2:Officers|"..stamp,'GUILD') end''')(int(SERVER0+clock['t'])+5)
bus.run(3)
check('a restricted tab sent anyway is ignored', vk(m1)['*vault2'] is None)
purse.logout(); bus.run(2); purse.saved.guilds["Verdant"].vaultView=None; purse.saved.guilds["Verdant"].banks['*vault1']=None
purse.login(); bus.run(30)
check('guildmates who missed it get the public tabs when they log in', tabs_of(purse)==['*vault1'] and vk(purse)['*vault1'].bank[2770]==200)

# --- officers choose the share rank, set up bank toons and name banks ---
officer.L.execute('local p=GuildBankToons.copyPlan(); p.rules.vaultRank=1; GuildBankToons.setPlan(p)'); bus.run(10)
officer.fire('GUILDBANKFRAME_OPENED'); bus.run(5); officer.fire('GUILDBANKFRAME_CLOSED'); bus.run(15)
check('with the share rank set to officers, the officer tab is shared', tabs_of(m1)==['*vault1','*vault2'] and API(m1).Available(19019)[0]==1)
officer.L.execute('local p=GuildBankToons.copyPlan(); p.rules.vaultRank=-1; GuildBankToons.setPlan(p)'); bus.run(10)
check('setting it back to the lowest rank takes the officer tab away from everyone', tabs_of(m1)==['*vault1'] and vk(m1)['*vault2'] is None and vk(officer)['*vault2'] is None)
GBT(officer).gmChange('add','Penny Jar'); bus.run(8)
check('officers can add bank toons', 'pennyjar' in managed(m1))
GBT(officer).gmChange('remove','Penny Jar'); bus.run(8)
check('officers can remove bank toons', 'pennyjar' not in managed(m1))
GBT(officer).setBankLabel('vaultkeeper','Mats & Herbs'); GBT(officer).setBankLabel('*vault1','Crafting mats'); bus.run(8)
check('officers can name banks for the guild', GBT(m1).bankTitle('Vault Keeper')=='Mats & Herbs' and GBT(m1).bankTitle('*vault1:Mats')=='Crafting mats')
check('bank names show where the bank is listed', 'Mats & Herbs' in API(m1).Available(2589)[1] and any('Mats & Herbs' in r.where for r in GBT(m1).itemRows(None,'all','','name').values()))
GBT(m1).setBankLabel('vaultkeeper','Mine now'); bus.run(5)
check('members cannot rename banks', GBT(m2).bankTitle('Vault Keeper')=='Mats & Herbs')

# --- the ledger is what really moved: the guild bank's log, and bank toons' mail in and out ---
def ledger_of(c,status): return [e for e in GBT(c).ledger().values() if e.status==status]
vault_log='''VAULT={money=1234567,moneylog={{"deposit","Alice",50000,0,3},{"repair","Gwen-Master",10000,1,0}},
  tabs={{name="Mats",items={{2589,40},{2770,200}},log={{"deposit","Alice",2589,20,0,2},{"withdraw","Bob-Smith",2770,5,0,5}}},
        {name="Officers",hidden=%s,items={{19019,1}},log={{"deposit","Olivia-Stone",19019,1,0,1}}}}}'''
m2.L.execute(vault_log % 'true')
m2.fire('GUILDBANKFRAME_OPENED'); bus.run(8); m2.fire('GUILDBANKFRAME_CLOSED'); bus.run(10)
dep,wd=ledger_of(m1,'deposit'),ledger_of(m1,'withdraw')
check('guild bank deposits and withdrawals come from the game\'s own log', any(e['items'][2589]==20 and e['from']=='Alice' for e in dep) and any(e['items'][2770]==5 and e.to=='Bob Smith' for e in wd))
check('the guild bank\'s gold log is in the ledger too, repairs as gold out', any(e.money==50000 for e in dep) and any(e.money==10000 and e.to=='Gwen Master' for e in wd))
check('nothing from a restricted tab\'s log is shared', not any(19019 in dict(e['items'].items()) for e in dep+wd))
before=len(dep)+len(wd)
# An officer opens it an hour later: the log's ages have moved on by an hour; nothing is logged twice.
officer.L.execute((vault_log % 'false').replace('0,2}','0,3}').replace('0,5}','0,6}').replace('0,3}},','0,4}},').replace('1,0}}','1,1}}'))
officer.fire('GUILDBANKFRAME_OPENED'); bus.run(8); officer.fire('GUILDBANKFRAME_CLOSED'); bus.run(10)
check('opening the guild bank again doesn\'t log anything twice', len(ledger_of(m1,'deposit'))+len(ledger_of(m1,'withdraw'))==before)
bank.L.execute('INBOX={{sender="Alliance Auction House", subject="Auction successful: Linen Cloth", money=1500}}')
bank.fire('MAIL_INBOX_UPDATE'); bus.run(5)
check('mail from outside the guild is logged as mail in', any(e.money==1500 and e['from']=='Alliance Auction' for e in ledger_of(m1,'mailin')))
bank.env.sendMoney=20000; bank.L.globals().SendMail('Coin Purse','restock',''); bank.fire('MAIL_SEND_SUCCESS'); bus.run(5)
check('mail to another bank toon is left for that toon to log as a move', not any(e.to=='Coin Purse' for e in ledger_of(m1,'mailout')))
check('requests themselves are not in the ledger', not ledger_of(m1,'mailed'))
GBT(m1).open('donations'); GBT(m1).refreshDonations()

# --- the Discord companion reads what the game saved ---
import subprocess, tempfile, os, json as _json
m1.L.execute(r"""
local function ser(v,ind)
  if type(v)=='table' then
    local keys={}
    for k in pairs(v) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    local out={'{'}
    for _,k in ipairs(keys) do
      local key=type(k)=='number' and ('['..k..']') or ('['..string.format('%q',k)..']')
      out[#out+1]=ind..'  '..key..' = '..ser(v[k],ind..'  ')..','
    end
    out[#out+1]=ind..'}'
    return table.concat(out,'\n')
  elseif type(v)=='string' then return string.format('%q',v)
  else return tostring(v) end
end
SAVED='GuildBankToonsDB = '..ser(GuildBankToonsDB,'')..'\n'
""")
tmp=tempfile.mkdtemp()
sv=os.path.join(tmp,'GuildBankToons.lua'); open(sv,'w').write(m1.L.globals().SAVED)
comp=os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])),'..','companion','guildbanktoons_discord.py')
dry=subprocess.run([sys.executable,comp,'--dry-run','--force','--savedvars',sv],capture_output=True,text=True,cwd=tmp)
check('companion dry run reads the save and builds the goals message', dry.returncode==0 and 'Gold goals' in dry.stdout and 'Raid fund' in dry.stdout and 'What the guild needs' in dry.stdout)
check('companion thanks donors', 'donated' in dry.stdout and 'Thank you!' in dry.stdout)
check('companion posts guild bank tabs and craft orders', 'Crafting mats' in dry.stdout and 'craft order' in dry.stdout)
check('companion uses the names officers gave the banks', 'Mats & Herbs' in dry.stdout)
check('the saved file holds no restricted tab, so the companion has none to post', '"*vault2"' not in m1.L.globals().SAVED and 'Guild Bank - Officers' not in dry.stdout)
exp=subprocess.run([sys.executable,comp,'--savedvars',sv,'--export',os.path.join(tmp,'out')],capture_output=True,text=True,cwd=tmp,
                   env={k:v for k,v in os.environ.items() if k!='GUILDBANKTOONS_WEBHOOK'})
files=sorted(os.listdir(os.path.join(tmp,'out'))) if os.path.isdir(os.path.join(tmp,'out')) else []
check('companion writes inventory, ledger and gold CSV files', exp.returncode==0 and files==['gold.csv','inventory.csv','ledger.csv'])
if dry.returncode or exp.returncode: print(dry.stderr[-800:], exp.stderr[-800:])

# --- alts: another character on the bank toon's account with the same first name ---
bank.logout(); bus.run(2)
kept=m1.snap()
bank.name='Vault Smith'; bank.env.guid='Player-1-VaultSmith'; bank.env.surname=None; bus.ranks['Vault Smith']=4
bank.setbags([[19019,1]])
bank.login(); bank.fire('BAG_UPDATE_DELAYED'); bus.run(15)
saved=bank.L.globals().GuildBankToonsDB
check('an alt sharing a first name learns its own full name', saved.knownAs['Player-1-VaultSmith']=='Vault Smith' and saved.knownAs['Player-1-VaultKeeper']=='Vault Keeper')
check('an alt sharing a first name never speaks for the bank toon', m1.snap()['hash']==kept['hash'] and bank.snap() and bank.snap()['hash']==kept['hash'])
bank.logout(); bus.run(2)
bank.name='Vault Keeper'; bank.env.guid='Player-1-VaultKeeper'; bank.env.surname='Keeper'; del bus.ranks['Vault Smith']
bank.setbags([[2589,20],[2589,20],[2589,6]])
bank.login(); bus.run(20)
check('back on the bank toon, it is itself again', bank.L.globals().GuildBankToonsDB.knownAs['Player-1-VaultKeeper']=='Vault Keeper' and m1.snap()['hash']==bank.snap()['hash'])

# --- the minimap button, as in PiggyBank ---
def place(c,angle,shape):
    c.L.execute('MINIMAP_SHAPE=%s; GuildBankToonsDB.ui.minimapAngle=%d' % ('"'+shape+'"', angle))
    GBT(c).placeMinimap()
    return GBT(c).minimapOffset(angle)
import math
x,y=place(m1,205,'ROUND')
check('on a round minimap the button sits on the ring', abs(math.hypot(x,y)-75)<0.01)
x,y=place(m1,225,'SQUARE')
check('on a square minimap the button sits in the corner, inside the edge', abs(x)<=75 and abs(y)<=75 and math.hypot(x,y)>80)
x,y=place(m1,225,'CORNER-BOTTOMLEFT')
check('a round corner of a corner-shaped minimap stays on the ring', abs(math.hypot(x,y)-75)<0.01)
m1.L.execute("MINIMAP_SHAPE=nil")
evil.logout(); bus.run(1)
evil.L.execute('''LIBS={}
LIBS['LibDataBroker-1.1']={NewDataObject=function(self,name,obj) LIBS.obj=obj; return obj end}
LIBS['LibDBIcon-1.0']={Register=function(self,name,obj,db) LIBS.registered=name; LIBS.db=db end,
  GetMinimapButton=function() return nil end, Show=function() LIBS.shown=true end, Hide=function() LIBS.shown=false end}
LibStub=function(name) return LIBS[name] end''')
evil.login(); bus.run(3)
libs=evil.L.globals().LIBS
check('with LibDBIcon loaded by another addon, the button joins it', libs.registered=='Guild Bank Toons' and libs.obj.type=='launcher' and libs.db is not None)
evil.L.globals().GuildBankToonsDB.settings.minimap=False; GBT(evil).placeMinimap()
check('hiding the button in Settings hides it in LibDBIcon too', libs.shown==False and libs.db.hide==True)
evil.L.globals().GuildBankToonsDB.settings.minimap=True; GBT(evil).placeMinimap()

# --- accounts the game flags as trial still try to send (the game decides) ---
m2.L.execute('IsTrialAccount=function() return true end')
slash(m2,'request 2589 1'); bus.run(10)
check('an account flagged as trial is not held back by the addon', latest(officer).by=='Bob' and latest(officer).count==1)
# --- /gbt debug and the message log ---
slash(m1,'debug')
check('/gbt debug shows name, roster, sending and banks', any('roster:' in l and 'found, rank 4' in l for l in m1.logs) and any('bank: ' in l for l in m1.logs))
log=GBT(m1).exportText('log','text')
check('the message log has what was sent, received and rejected', 'sent ' in log and 'got ' in log and 'REJECTED' in log)
m2.L.execute('IsTrialAccount=nil')
m1.fire('ADDON_ACTION_BLOCKED','SomeOtherAddon','CastSpellByName')
m1.fire('ADDON_ACTION_BLOCKED','GuildBankToons','PickupContainerItem'); m1.fire('ADDON_ACTION_FORBIDDEN','GuildBankToons','PickupContainerItem')
log=GBT(m1).exportText('log','text')
check('blocked actions are logged for this addon only', 'BLOCKED by the game (ADDON_ACTION_BLOCKED): PickupContainerItem' in log and 'CastSpellByName' not in log)
check('a blocked function is announced once', sum('The game blocked PickupContainerItem' in l for l in m1.logs)==1)
# --- officers put in requests for members without the addon (asked on Discord) ---
bus.ranks['Dana Field']=4; bus.always_online.add('Dana Field')
for c in (officer,m1,bank): c.fire('GUILD_ROSTER_UPDATE')
def dana(c):
    reqs=c.L.globals().GuildBankToonsDB.guilds["Verdant"].requests
    return [r for _,r in reqs.items() if r.by=='Dana Field']
officer.whispers.clear(); bank.logs.clear()
GBT(officer).createRequest(2589,3,'asked on Discord','Vault Keeper',officer.L.table_from({'member':'dana field'})); bus.run(8)
r=dana(m1)
check('an officer can put in a request for a member without the addon', len(r)==1 and r[0].status=='approved' and r[0].actor=='Olivia Stone' and r[0].count==3)
check('the bank toon is told to mail it to the member', any('Dana Field' in l and 'mail' in l for l in bank.logs))
check('the member is whispered that it was put in', any(w[1]=='Dana-Field' and 'put in your request' in w[2] for w in officer.whispers))
GBT(m1).createRequest(2589,1,'','Vault Keeper',m1.L.table_from({'member':'Dana Field'})); bus.run(8)
check('members cannot put in requests for others', len(dana(officer))==1)
GBT(officer).createRequest(2589,1,'','Vault Keeper',officer.L.table_from({'member':'Nobody Here'})); bus.run(8)
check('a request for someone not in the guild is refused', any('no guild member called Nobody Here' in l for l in officer.logs))
# Forever blocks reading the guild info in combat: don't try then, read it once combat ends.
tagged=lambda: m1.L.globals().GuildBankToonsDB.guilds["Verdant"].tagged
m1.L.execute('InCombatLockdown=function() return true end'); m1.env.guildinfo='Bank stuff [GBT:Vault Keeper] [GBT:Spare Vault]'
m1.fire('GUILD_ROSTER_UPDATE')
check('guild info is not read in combat', tagged()['sparevault'] is None)
m1.L.execute('InCombatLockdown=function() return false end'); m1.fire('PLAYER_REGEN_ENABLED')
check('guild info is read when combat ends', tagged()['sparevault']=='Spare Vault')
m1.fire('ADDON_ACTION_BLOCKED','GuildBankToons','GetGuildText()')
check('a guild info block out of combat stops further reads, quietly', GBT(m1).tagsBlocked and not any('GetGuildText' in l for l in m1.logs))
print('messages sent total:',bus.count)
sys.exit(0 if ok else 1)
