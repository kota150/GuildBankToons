# Simulates several WoW clients running GuildBankToons.lua on one guild channel.
# Usage: pip install lupa; python3 tests/sync_sim.py GuildBankToons.lua
import sys, random
from lupa import LuaRuntime
SRC=open(sys.argv[1]).read()
clock={'t':1000.0}; SERVER0=1793600000
STUB=r'''
local env=...
local function noop() end
local Obj={} ; Obj.__index=function(t,k) if k=='TitleText' then return nil end return rawget(Obj,k) or noop end
function Obj:SetScript(name,fn) rawset(self,'_'..name,fn) end
function Obj:HookScript(name,fn) rawset(self,'_'..name,fn) end
function Obj:CreateFontString() return setmetatable({},Obj) end
function Obj:CreateTexture() return setmetatable({},Obj) end
function Obj:RegisterEvent(e) self._events[e]=true end
function Obj:IsShown() return false end
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
GetSendMailItem=function(i) for _,a in ipairs(env.attached) do if a.slot==i then return 'item' end end end
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
    def __init__(s): s.clients=[]; s.timers=[]; s.count=0; s.ranks={}; s.always_online=set()
    def roster(s):
        return sorted(s.ranks)
    def member(s,i):
        name=s.roster()[int(i)-1]
        online=name in s.always_online or any(c.online and c.name==name for c in s.clients)
        return (name+"-Nek'Rosh",'',s.ranks[name],0,'','','','',online)
    def send(s,frm,p,m):
        s.count+=1
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
print('messages sent total:',bus.count)
sys.exit(0 if ok else 1)
