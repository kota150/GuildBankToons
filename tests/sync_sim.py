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
ClickSendMailItemButton=function(i) table.insert(env.attached,{slot=i,from=env.cursor}); env.cursor=nil end
GetSendMailItem=function(i)
  if SENDITEMS and SENDITEMS[i] then return 'Item'..SENDITEMS[i][1],SENDITEMS[i][1],nil,SENDITEMS[i][2],1 end
  for _,a in ipairs(env.attached) do if a.slot==i then return 'item' end end
end
SetSendMailMoney=function(c) env.sendMoney=c end
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
C_Container={PickupContainerItem=function(b,s) env.cursor={bag=b,slot=s,count=env.bags[b][s][2]} end,
  SplitContainerItem=function(b,s,n) env.cursor={bag=b,slot=s,count=n,split=true} end,
  GetContainerNumSlots=function(b) local bag=env.bags[b]; return bag and #bag or 0 end,
  GetContainerItemInfo=function(b,s) local it=env.bags[b] and env.bags[b][s]; if it then return {itemID=it[1],stackCount=it[2]} end end}
GetItemInfo=function(id) return 'Item'..id,'|Hitem:'..id..'|h',1 end
GetTime=function() return env.now() end
GetServerTime=function() return env.server() end
UnitName=function() return env.unit end
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
        s.env=s.L.table_from({'frames':s.L.table(),'name':name,'unit':unit or name,'guildinfo':'Bank stuff [GBT:Vault Keeper]','gold':0,'bags':s.L.table()})
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
        g=db and db.guilds['Verdant']
        b=g and g.banks[who]
        if not b: return None
        return dict(stamp=b.stamp,hash=b.hash,via=b.via,gold=b.gold,bags=dict(b.bags.items()) if b.bags else {},bank=dict(b.bank.items()) if b.bank else {})
class Bus:
    def __init__(s): s.clients=[]; s.timers=[]; s.count=0; s.ranks={}; s.always_online=set(); s.log=[]
    def roster(s):
        return sorted(s.ranks)
    def member(s,i):
        name=s.roster()[int(i)-1]
        online=name in s.always_online or any(c.online and c.name==name for c in s.clients)
        return (name+"-Nek'Rosh",'',s.ranks[name],0,'','','','',online)
    def send(s,frm,p,m):
        s.count+=1; s.log.append((frm.name,m))
        if getattr(frm,'mute',None) and frm.mute(m): return
        sender=frm.name+'-Nek\'Rosh'
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
gm=Client('Gwen Master',bus,'Gwen'); purse=Client('Coin Purse',bus,'Coin')
bus.clients=[bank,m1,m2,evil,officer,gm,purse]
# Pete is an officer who doesn't run the addon.
bus.ranks={'Vault Keeper':3,'Alice':4,'Bob':4,'Mallory':4,'Olivia Stone':1,'Pete':1,'Gwen Master':0,'Coin Purse':3}; bus.always_online={'Pete'}
ok=True
def check(label,cond):
    global ok; ok&=bool(cond); print(('PASS ' if cond else 'FAIL ')+label)

bank.env.gold=50000; bank.setbags([[2589,20],[2589,20],[14047,5]],bank=[[4306,100]])
bank.login(); m1.login()
bank.fire('BANKFRAME_OPENED'); bus.run(1); bank.fire('BANKFRAME_CLOSED')
bus.run(30)
s=m1.snap(); b=bank.snap()
check('bank alt learned its surname from its own echo', bank.L.globals().GuildBankToonsDB.knownAs.Vault=='Vault Keeper')
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
check('officer learned surname', officer.L.globals().GuildBankToonsDB.knownAs.Olivia=='Olivia Stone')
m1.L.globals().GuildBankToonsDB.settings.companion=True
slash(m1,'request 2589 30 for my alt'); bus.run(12)
r=latest(officer)
check('officer receives request', r and r.status=='open' and r.count==30 and r.note=='for my alt')
check('officer client alerted', any('requests 30x' in l for l in officer.logs))
check('requester whispered only the officer without the addon', [w[1] for w in m1.whispers]==["Pete-Nek'Rosh"])
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
slash(bank,'mail')
att=[dict(a.items()) for a in bank.env.attached.values()]
cur=[dict(a['from'].items()) for a in att]
check('mail helper addresses the requester', bank.L.globals().SendMailNameEditBox.text=='Alice')
check('mail helper attaches exactly 30 with one split', sum(c['count'] for c in cur)==30 and sum(1 for c in cur if c.get('split'))==1 and len(cur)==3)
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
check('a member cannot set guild bank characters', managed(officer)==[] and any('Only the guild master' in l for l in m1.logs))
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
m2.saved.guilds['Verdant'].managed=m2.L.table(); m2.saved.guilds['Verdant'].managedStamp=None
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

# --- trial accounts (Forever blocks their addon messages) ---
before=bus.count; known=len(requests_of(officer))
m2.L.execute('IsTrialAccount=function() return true end')
slash(m2,'request 2589 1'); slash(m2,'sync'); bus.run(10)
check('a trial account sends nothing', len(requests_of(officer))==known and any('Trial accounts' in l for l in m2.logs))
m2.L.execute('IsTrialAccount=nil')
print('messages sent total:',bus.count)
sys.exit(0 if ok else 1)
