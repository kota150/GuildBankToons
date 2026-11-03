# Simulates several WoW clients running GuildBankToons.lua on one guild channel.
# Usage: pip install lupa; python3 tests/sync_sim.py GuildBankToons.lua
import sys, random
from lupa import LuaRuntime
SRC=open(sys.argv[1]).read()
clock={'t':1000.0}; SERVER0=1793600000
STUB=r'''
local env=...
local function noop() end
local Obj={} ; Obj.__index=function(t,k) return rawget(Obj,k) or noop end
function Obj:SetScript(name,fn) rawset(self,'_'..name,fn) end
function Obj:RegisterEvent(e) self._events[e]=true end
function Obj:IsShown() return false end
CreateFrame=function() local o=setmetatable({_events={}},Obj); env.frames[#env.frames+1]=o; return o end
UIParent={}; UISpecialFrames={}; SlashCmdList={}; GameTooltip=setmetatable({},Obj); ItemRefTooltip=GameTooltip
C_Timer={After=function(s,fn) env.later(s,fn) end}
C_ChatInfo={SendAddonMessage=function(p,m,c) env.send(p,m,c) return true end, RegisterAddonMessagePrefix=noop}
C_Container={GetContainerNumSlots=function(b) local bag=env.bags[b]; return bag and #bag or 0 end,
  GetContainerItemInfo=function(b,s) local it=env.bags[b] and env.bags[b][s]; if it then return {itemID=it[1],stackCount=it[2]} end end}
GetItemInfo=function(id) return 'Item'..id,'|Hitem:'..id..'|h',1 end
GetTime=function() return env.now() end
GetServerTime=function() return env.server() end
UnitName=function() return env.name end
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
    def __init__(s,name,bus):
        s.L=LuaRuntime(unpack_returned_tuples=True); s.name=name; s.bus=bus; s.online=False
        s.env=s.L.table_from({'frames':s.L.table(),'name':name,'guildinfo':'Bank stuff [GBT:Bankalt-Nek\'Rosh]','gold':0,'bags':s.L.table()})
        s.env.now=lambda:clock['t']; s.env.server=lambda:int(SERVER0+clock['t'])
        s.env.send=lambda p,m,c: bus.send(s,p,m)
        s.env.later=lambda sec,fn: bus.later(s,sec,fn)
        s.L.execute(STUB,s.env) if False else s.L.eval('function(...) '+STUB+' end')(s.env)
        s.saved=None
    def frame(s): return s.env.frames[1]
    def fire(s,ev,*a):
        h=s.frame()['_OnEvent']
        if h: h(s.frame(),ev,*a)
    def login(s):
        s.env.frames=s.L.table(); g=s.L.globals(); g.GuildBankToonsDB=s.saved
        s.L.eval('function(src,name) return load(src,"@GuildBankToons.lua")(name) end')(SRC,'GuildBankToons')
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
    def snap(s,who='bankalt-nekrosh'):
        db=s.L.globals().GuildBankToonsDB
        g=db and db.guilds['Verdant - Nek\'Rosh']
        b=g and g.banks[who]
        if not b: return None
        return dict(stamp=b.stamp,hash=b.hash,via=b.via,gold=b.gold,bags=dict(b.bags.items()) if b.bags else {},bank=dict(b.bank.items()) if b.bank else {})
class Bus:
    def __init__(s): s.clients=[]; s.timers=[]; s.count=0
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
bank=Client('Bankalt',bus); m1=Client('Alice',bus); m2=Client('Bob',bus); evil=Client('Mallory',bus)
bus.clients=[bank,m1,m2,evil]
ok=True
def check(label,cond):
    global ok; ok&=bool(cond); print(('PASS ' if cond else 'FAIL ')+label)

bank.env.gold=50000; bank.setbags([[2589,20],[2589,20],[14047,5]],bank=[[4306,100]])
bank.login(); m1.login()
bank.fire('BANKFRAME_OPENED'); bus.run(1); bank.fire('BANKFRAME_CLOSED')
bus.run(30)
s=m1.snap(); b=bank.snap()
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
evil.login(); bus.run(10)
fake_stamp=int(SERVER0+clock['t'])+300
evil.L.execute('''
local q={}
local function send(m) C_ChatInfo.SendAddonMessage('GBTOONS',m,'GUILD') end
''')
# craft fake with valid hash using the addon's own hash fn: easiest is mutate Mallory's copy and send it
evil.L.eval('''function(stamp)
  local g=GuildBankToonsDB.guilds["Verdant - Nek'Rosh"]
  local s=g.banks["bankalt-nekrosh"]
  s.bags={[19019]=1}; s.gold=99999999
  local h=(s.gold)%16777213
  local e={"b:19019:1"}; for _,x in ipairs({}) do end
  for id,c in pairs(s.bank) do e[#e+1]="k:"..id..":"..c end
  table.sort(e)
  for _,x in ipairs(e) do for i=1,#x do h=(h*31+x:byte(i))%16777213 end h=(h*31+10)%16777213 end
  s.hash=h; s.stamp=stamp
  local function send(m) C_ChatInfo.SendAddonMessage('GBTOONS',m,'GUILD') end
  send("B|Bankalt-Nek'Rosh|"..stamp.."|"..h.."|"..s.gold.."|0|"..#e)
  send("I|Bankalt-Nek'Rosh|"..stamp.."|"..table.concat(e,","))
  send("E|Bankalt-Nek'Rosh|"..stamp)
end''')(fake_stamp)
bus.run(5)
check('forged relay is accepted while bank alt offline (known limit)', m1.snap()['bags'].get(19019)==1)
bank.login(); bus.run(30)
fb=bank.snap()
check('bank alt outbids forged copy when it logs in', fb['stamp']>fake_stamp and m1.snap()['hash']==fb['hash'] and m2.snap()['hash']==fb['hash'] and m1.snap()['bags'].get(19019) is None)
far=int(SERVER0+clock['t'])+5000
evil.L.eval('''function(stamp) C_ChatInfo.SendAddonMessage('GBTOONS',"R|Bankalt-Nek'Rosh|"..stamp.."|1",'GUILD') end''')(far)
bus.run(10)
check('far-future stamp ignored by members', m1.snap()['hash']==fb['hash'])
print('messages sent total:',bus.count)
sys.exit(0 if ok else 1)
