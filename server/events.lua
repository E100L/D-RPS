--[[ D-RPS — server/events.lua
     Event-Collector: legt server-seitige GTA-Events als zeitgestempelte 'claim's in
     einen Event-Ring, mit unabhaengiger Server-Sicht (Position/Distanz) daneben.
     weaponDamageEvent NIE canceln (CancelEvent-Bug #2395) — D-RPS ist Recorder, nicht Blocker. ]]

Events = {}

local eventLog = {}          -- Ring der juengsten Events (fuer Detection + Timeline)
local MAX_EVENTS = 1000
local listeners  = {}        -- Detection haengt sich hier ein (M2 Schritt 3)

-- == Hilfen ==

-- Signed->Unsigned Hash-Normalisierung: Waffenhashes kommen mal als i32, mal u32; sonst scheitert der Vergleich.
local function normHash(h)
    if not h then return 0 end
    return h < 0 and (h + 0x100000000) or h
end

--- netId der getroffenen Entity → Spieler-src (oder nil, wenn kein Spieler).
local function resolvePlayerByNetId(netId)
    if not netId or netId == 0 then return nil end
    local ok, ent = pcall(NetworkGetEntityFromNetworkId, netId)
    if not ok or not ent or ent == 0 then return nil end
    for _, sp in ipairs(GetPlayers()) do
        local src = tonumber(sp)
        if GetPlayerPed(src) == ent then return src end
    end
    return nil
end

local function playerPos(src)
    local ped = src and GetPlayerPed(src)
    if ped and ped ~= 0 and DoesEntityExist(ped) then return GetEntityCoords(ped) end
    return nil
end

local function dist2d(a, b)
    if not a or not b then return nil end
    return #(vector3(a.x, a.y, 0.0) - vector3(b.x, b.y, 0.0))
end

--- Zentrale Event-Ablage. Stempelt Zeit, ruft Listener (Detection).
local function pushEvent(ev)
    ev.t  = os.time()
    ev.gt = GetGameTimer()
    eventLog[#eventLog + 1] = ev
    if #eventLog > MAX_EVENTS then table.remove(eventLog, 1) end
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], ev)
        if not ok and Config.Debug then print(('^1[D-RPS] Event-Listener-Fehler: %s^0'):format(err)) end
    end
end

--- Detection registriert sich hier.
function Events.OnEvent(fn) listeners[#listeners + 1] = fn end

--- Letzte n Events (Debug / spaeter UI).
function Events.Recent(n)
    n = n or 20
    local out, total = {}, #eventLog
    for i = math.max(1, total - n + 1), total do out[#out + 1] = eventLog[i] end
    return out
end

-- == Event-Hooks ==

-- Waffenschaden. Alle Payload-Felder sind Claims.
AddEventHandler('weaponDamageEvent', function(sender, data)
    local shooter = tonumber(sender)
    local victim  = resolvePlayerByNetId(data.hitGlobalId)
    local sp, vp  = playerPos(shooter), victim and playerPos(victim) or nil

    RPSDiag(('EVENT dmg shooter=%s victim=%s weapon=%08x kill=%s comp=%s'):format(
        tostring(shooter), tostring(victim), normHash(data.weaponType),
        tostring(data.willKill), tostring(data.hitComponent)))

    pushEvent({
        type    = 'damage',
        trust   = 'claim',
        shooter = shooter,
        victim  = victim,                       -- nil bei NPC/Objekt-Treffer
        weapon  = normHash(data.weaponType),
        willKill= data.willKill and true or false,
        silenced= data.silenced and true or false,
        hitComponent = data.hitComponent,        -- Trefferzone
        multiHit = (type(data.hitGlobalIds) == 'table' and #data.hitGlobalIds > 1) or false,
        shooterPos = sp, victimPos = vp,
        dist  = (sp and vp) and #(sp - vp) or nil,   -- 3D-Distanz, server-berechnet
    })

    if shooter and victim then Interactions.RecordDamage(shooter, victim) end
end)

-- Chat: nur Zeitpunkt + Reichweite fuer den Graph. Text optional (Config.RecordChatText). Nie canceln.
AddEventHandler('chatMessage', function(src, _, msg)
    Interactions.RecordChat(src, Config.RecordChatText and msg or nil)
end)

-- Explosionen. Layout ist build-abhaengig — nur stabile Felder lesen.
AddEventHandler('explosionEvent', function(sender, data)
    pushEvent({
        type = 'explosion', trust = 'claim',
        owner = tonumber(sender),
        explosionType = data.explosionType,
        pos = data.posX and vector3(data.posX, data.posY, data.posZ) or nil,
        damageScale = data.damageScale,
    })
end)

-- Waffe erhalten (Spawn-Cheat, wenn ohne Server-Transaktion).
AddEventHandler('giveWeaponEvent', function(sender, data)
    pushEvent({
        type = 'giveWeapon', trust = 'claim',
        ped = tonumber(sender),
        weapon = normHash(data.weaponType),
        ammo = data.ammo,
    })
end)

AddEventHandler('removeAllWeaponsEvent', function(sender)
    pushEvent({ type = 'removeAllWeapons', trust = 'claim', ped = tonumber(sender) })
end)

-- Wurfobjekte/Raketen.
AddEventHandler('startProjectileEvent', function(sender, data)
    pushEvent({
        type = 'projectile', trust = 'claim',
        owner = tonumber(sender),
        weapon = normHash(data.weaponHash),
        pos = data.firePositionX and vector3(data.firePositionX, data.firePositionY, data.firePositionZ) or nil,
    })
end)

-- Entity-Erzeugung: sehr hochfrequent, NICHT in den Event-Log (Flut). Nur pro Owner
-- im gleitenden Fenster zaehlen (Rate-Detektor fuer Spawner).
local spawnCount = {}   -- [owner] = { n, windowStart(ms) }
Events.SpawnRate = spawnCount

AddEventHandler('entityCreating', function(handle)
    local owner = NetworkGetEntityOwner and NetworkGetEntityOwner(handle) or nil
    if not owner then return end
    local now = GetGameTimer()
    local c = spawnCount[owner]
    if not c or (now - c.windowStart) > 5000 then
        spawnCount[owner] = { n = 1, windowStart = now }
    else
        c.n = c.n + 1
    end
end)

return Events
