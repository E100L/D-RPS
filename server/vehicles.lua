--[[ D-RPS — server/vehicles.lua
     Weltspur: vernetzte Fahrzeuge/Peds ohne Insassen, die der Beweisstrom nicht
     kennt. Ablage in EINEM Strom unter Protocol.WORLD_HASH (Chunk = Entitaet =
     Segment). Zeit nur aus Recorder.AbsTime; Stillstand erzeugt keinen Sample;
     Relevanz ueber grobes Zellenraster statt Abstand mal Spielerzahl. ]]

WorldVeh = {}

local floor = math.floor

-- [netId] = Aufzeichnungszustand eines Fahrzeugs
local tracked  = {}
local trackedN = 0

-- Fortlaufende Nummer: verhindert, dass ein wiederverwendeter netId den Strom
-- eines geloeschten Fahrzeugs fortsetzt.
local seq = 0

-- Messwerte fuer /rps_vehdiag.
local stat = {
    passes = 0, lastMs = 0.0, maxMs = 0.0, avgMs = 0.0,
    seen = 0, hot = 0, capped = 0, occupied = 0,
    samples = 0, skipped = 0, chunks = 0, bytes = 0,
}

-- ── Konfiguration ──────────────────────────────────────────────────────────

local function cfg(key, dflt)
    local w = Config and Config.World
    local v = w and w[key]
    if type(v) == 'number' or type(v) == 'boolean' then return v end
    return dflt
end

local function enabled()
    if cfg('Vehicles', true) ~= true then return false end
    -- Ohne Disk-Archiv kein Ablageort: der Weltstrom hat keinen RAM-Ring.
    return (Config and Config.DiskArchive) and true or false
end

-- ── Identitaet ─────────────────────────────────────────────────────────────

--- Schluessel eines Fahrzeugs im Weltstrom: waehrend der Lebensdauer gleich,
--- nach dem Verschwinden nicht wiederkehrend. Aus Sitzungsepoche + laufender
--- Nummer + netId.
local function makeKey(netId)
    seq = seq + 1
    local ep = (Session and Session.Epoch and Session.Epoch()) or 0
    local h = ((ep & 0xFFFFFFFF) * 2654435761) & 0xFFFFFFFF
    h = h ~ (((netId or 0) * 2246822519) & 0xFFFFFFFF)
    h = h ~ ((seq * 40503) & 0xFFFFFFFF)
    h = (h ~ (h >> 15)) & 0xFFFFFFFF
    h = (h * 2654435761) & 0xFFFFFFFF
    -- 0 = "kein Fahrzeug", WORLD_HASH = der Strom selbst; beide meiden.
    if h == 0 or h == Protocol.WORLD_HASH then h = (h + 1) & 0xFFFFFFFF end
    return h
end

--- Stabiler Bezeichner der Entitaet: netId, ersatzweise das Entity-Handle.
local function netOf(veh)
    local ok, id = pcall(NetworkGetNetworkIdFromEntity, veh)
    if ok and type(id) == 'number' and id ~= 0 then return id end
    return veh
end

-- ── Zustand eines Fahrzeugs lesen ──────────────────────────────────────────

--- Zustand eines Fussgaengers, nur server-autoritativ (Position, Heading, HP).
--- Nur skriptgespawnte, vernetzte Peds; die eingebaute Bevoelkerung existiert
--- serverseitig nicht.
local function readPed(ped)
    local c = GetEntityCoords(ped)

    local hp = 0
    local okH, raw = pcall(GetEntityHealth, ped)
    if okH and type(raw) == 'number' then hp = math.min(255, floor(raw)) end

    -- IS_VEHICLE bleibt HIER geloescht: daran trennt die Wiedergabe Ped/Fahrzeug.
    local flags = 0
    if hp > 5 then flags = flags | Protocol.FLAG.ALIVE end

    local okV, veh = pcall(GetVehiclePedIsIn, ped, false)
    if okV and veh and veh ~= 0 then flags = flags | Protocol.FLAG.IN_VEHICLE end

    local speed = 0.0
    local okS, sp = pcall(GetEntitySpeed, ped)
    if okS and type(sp) == 'number' then speed = sp end

    return {
        x = c.x, y = c.y, z = c.z,
        heading = GetEntityHeading(ped),
        health = hp, armour = 0,
        flags = flags,
        vehModel = GetEntityModel(ped) & 0xFFFFFFFF, vehSeat = -1,
        camYaw = 0.0, camPitch = 0.0, moveBlend = 0.0,
        steer = 0.0, speed = speed, vpitch = 0.0, vroll = 0.0,
    }
end

local function readVeh(veh)
    local c = GetEntityCoords(veh)

    -- Karosseriezustand (Fahrzeug-HP 0..1000) auf ein Byte quantisiert.
    local hp = 0
    local okH, raw = pcall(GetEntityHealth, veh)
    if okH and type(raw) == 'number' then
        hp = floor(math.max(0.0, math.min(1000.0, raw)) / 1000.0 * 255.0 + 0.5)
    end

    local flags = Protocol.FLAG.IS_VEHICLE
    if hp > 0 then flags = flags | Protocol.FLAG.ALIVE end

    local steer, vpitch, vroll = 0.0, 0.0, 0.0
    local okSt, st = pcall(function()
        return Citizen.InvokeNative(0x1382FCEA, veh, Citizen.ResultAsFloat())
    end)
    if okSt and type(st) == 'number' then steer = st end
    local okR, rot = pcall(GetEntityRotation, veh, 2)
    if okR and rot then vpitch, vroll = rot.x, rot.y end

    local speed = 0.0
    local okS, sp = pcall(GetEntitySpeed, veh)
    if okS and type(sp) == 'number' then speed = sp end

    return {
        x = c.x, y = c.y, z = c.z,
        heading = GetEntityHeading(veh),
        health = hp, armour = 0,
        flags = flags,
        vehModel = GetEntityModel(veh) & 0xFFFFFFFF, vehSeat = -1,
        camYaw = 0.0, camPitch = 0.0, moveBlend = 0.0,
        steer = steer, speed = speed, vpitch = vpitch, vroll = vroll,
    }
end

-- ── Chunk-Verwaltung ───────────────────────────────────────────────────────

local function beginChunk(r, nowTimer)
    local sec, ms = Recorder.AbsTime(nowTimer)
    r.chunkStartSec = sec
    r.chunkStartMs  = ms
    r.seg = (Session and Session.SegOf) and Session.SegOf(sec) or nil
end

--- Chunk abschliessen. `gone` = Fahrzeug ist WEG (nicht bloss Chunk zu Ende):
--- schreibt einen Endmarker (letzter Sample mit vehModel = 0), sonst zeigt die
--- Wiedergabe das Fahrzeug als "steht still" weiter und baut es beim Einsteigen
--- doppelt.
local function closeChunk(r, gone)
    if r.nParts == 0 then return end

    if gone and r.prev then
        local last = {}
        for k, v in pairs(r.prev) do last[k] = v end
        last.vehModel = 0
        local dt = GetGameTimer() - (r.lastTimer or GetGameTimer())
        if dt < 0 then dt = 0 elseif dt > 60000 then dt = 60000 end
        r.nParts = r.nParts + 1
        r.parts[r.nParts] = Protocol.EncodeDelta(r.prev, last, dt)
    end

    local header = Protocol.EncodeChunkHeader(
        r.chunkStartSec, r.chunkStartMs, r.key, r.nParts)
    local chunk = header .. table.concat(r.parts, '', 1, r.nParts)

    local ok, off = Archive.WriteChunk(Protocol.WORLD_HASH, r.chunkStartSec, chunk)
    if ok and off and SegIndex and SegIndex.Note then
        SegIndex.Note(Protocol.WORLD_HASH, SegIndex.SegOf(r.chunkStartSec),
                      off, #chunk, r.nParts, r.chunkStartSec)
    end

    stat.chunks = stat.chunks + 1
    stat.bytes  = stat.bytes + #chunk

    r.nParts = 0
    r.prev   = nil
end

--- Einen Sample anhaengen — oder verwerfen, wenn die Feldmaske 0 ist (nichts
--- geaendert); dt sammelt sich dann bis zum naechsten echten Sample. Heartbeat
--- erzwingt bei langem Stillstand einen Ankerpunkt (und haelt dt unter u16).
local function sampleVeh(r, ent, nowTimer, heartbeatMs)
    local s = r.isPed and readPed(ent) or readVeh(ent)

    if not r.prev then
        beginChunk(r, nowTimer)
        r.nParts    = 1
        r.parts[1]  = Protocol.EncodeKeyframe(s, 0)
        r.prev      = s
        r.lastTimer = nowTimer
        stat.samples = stat.samples + 1
        return
    end

    local dt = nowTimer - r.lastTimer
    if dt > 60000 then dt = 60000 end

    local packed = Protocol.EncodeDelta(r.prev, s, dt)
    local _, mask = string.unpack('<I2I2', packed)
    if mask == 0 and dt < heartbeatMs then
        stat.skipped = stat.skipped + 1
        return                      -- lastTimer BLEIBT stehen: dt sammelt sich
    end

    r.nParts = r.nParts + 1
    r.parts[r.nParts] = packed
    r.prev = s
    r.lastTimer = nowTimer
    stat.samples = stat.samples + 1
end

-- ── Relevanz ───────────────────────────────────────────────────────────────

--- Grobes Zellenraster um alle Spieler: relevant ist, wessen Zelle oder
--- Nachbarzelle besetzt ist. Bewusst ungenau statt Fahrzeuge mal Spieler.
local function scanPlayers(cell)
    local hot, occupied, playerPeds, nPlayers = {}, {}, {}, 0
    for _, sp in ipairs(GetPlayers()) do
        local src = tonumber(sp)
        local ped = src and GetPlayerPed(src)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            nPlayers = nPlayers + 1
            playerPeds[ped] = true
            local c = GetEntityCoords(ped)
            local cx, cy = floor(c.x / cell), floor(c.y / cell)
            for dx = -1, 1 do
                for dy = -1, 1 do
                    hot[(cx + dx) * 8192 + (cy + dy)] = true
                end
            end
            -- Besetzte Fahrzeuge stehen schon im Beweisstrom -> ausschliessen.
            local v = GetVehiclePedIsIn(ped, false)
            if v and v ~= 0 then occupied[v] = true end
        end
    end
    return hot, occupied, playerPeds, nPlayers
end

-- ── Durchlauf ──────────────────────────────────────────────────────────────

local function pass(nowTimer)
    local t0 = os.clock()

    local cell        = cfg('Radius', 150.0)
    local maxVeh      = floor(cfg('MaxVehicles', 96))
    local heartbeatMs = floor(cfg('HeartbeatMs', 5000))

    local hot, occupied, playerPeds = scanPlayers(cell)

    local live, nHot, nCap, nSeen = {}, 0, 0, 0

    --- Einen Pool durchgehen. Fahrzeuge und Peds nehmen denselben Weg; nur was
    --- gelesen wird, entscheidet r.isPed in sampleVeh.
    local function scan(pool, isPed, cap, skip)
        if type(pool) ~= 'table' then return end
        nSeen = nSeen + #pool
        for i = 1, #pool do
            local ent = pool[i]
            if not skip[ent] and DoesEntityExist(ent) then
                local c = GetEntityCoords(ent)
                if hot[floor(c.x / cell) * 8192 + floor(c.y / cell)] then
                    nHot = nHot + 1
                    if nHot <= cap then
                        local net = netOf(ent)
                        local r = tracked[net]
                        if not r then
                            r = { key = makeKey(net), parts = {}, nParts = 0,
                                  prev = nil, lastTimer = nowTimer, isPed = isPed }
                            tracked[net] = r
                            trackedN = trackedN + 1
                        end
                        r.veh = ent
                        live[net] = true
                    else
                        nCap = nCap + 1
                    end
                end
            end
        end
    end

    if cfg('Vehicles', true) then
        local okV, vehs = pcall(GetAllVehicles)
        if okV and type(vehs) == 'table' then scan(vehs, false, maxVeh, occupied) end
    end

    -- Fussgaenger; Spieler-Peds ausgeschlossen (stehen schon im Beweisstrom).
    if cfg('Peds', true) then
        local okP, peds = pcall(GetAllPeds)
        if okP and type(peds) == 'table' then
            scan(peds, true, maxVeh + floor(cfg('MaxPeds', 64)), playerPeds)
        end
    end

    -- Segmentgrenze wie im Recorder: ein Chunk gehoert zu genau EINEM Segment.
    local nowSeg
    if Session and Session.SegOf then
        nowSeg = Session.SegOf((Recorder.AbsTime(nowTimer)))
    end

    for net, r in pairs(tracked) do
        if live[net] then
            if nowSeg and r.nParts > 0 and r.seg and r.seg ~= nowSeg then
                closeChunk(r)
            end
            sampleVeh(r, r.veh, nowTimer, heartbeatMs)
        else
            -- Weg (geloescht/ausgestreamt/eingestiegen): Rest mit Endmarker
            -- sichern, Schluessel freigeben; ein spaeter gleicher netId wird ein
            -- neues Fahrzeug.
            closeChunk(r, true)
            tracked[net] = nil
            trackedN = trackedN - 1
        end
    end

    local ms = (os.clock() - t0) * 1000.0
    stat.passes = stat.passes + 1
    stat.lastMs = ms
    if ms > stat.maxMs then stat.maxMs = ms end
    stat.avgMs = stat.avgMs + (ms - stat.avgMs) / math.min(stat.passes, 100)
    stat.seen, stat.hot, stat.capped = nSeen, nHot, nCap
    stat.occupied = 0
    for _ in pairs(occupied) do stat.occupied = stat.occupied + 1 end
end

-- ── Oeffentliche Schnittstelle ─────────────────────────────────────────────

--- Alle offenen Chunks schliessen (Resource-Stop, Aufzeichnung aus).
function WorldVeh.FlushAll()
    -- Mit Endmarker: ab hier keine Messung mehr, also auch keine Anwesenheit.
    for net, r in pairs(tracked) do
        closeChunk(r, true)
        tracked[net] = nil
    end
    trackedN = 0
end

--- Offene Chunks des laufenden Segments, aneinandergehaengt. Ohne diesen Griff
--- waere das juengste Segment (kein RAM-Ring) erst nach Abschluss abrufbar.
function WorldVeh.PeekOpen(seg)
    local out, n = {}, 0
    for _, r in pairs(tracked) do
        if r.nParts > 0 and (seg == nil or r.seg == seg) then
            n = n + 1
            out[n] = Protocol.EncodeChunkHeader(
                        r.chunkStartSec, r.chunkStartMs, r.key, r.nParts)
                     .. table.concat(r.parts, '', 1, r.nParts)
        end
    end
    if n == 0 then return nil end
    return table.concat(out, '', 1, n), n
end

--- Segment, in dem gerade offene Chunks liegen (nil, wenn keine).
function WorldVeh.OpenSeg()
    for _, r in pairs(tracked) do
        if r.nParts > 0 and r.seg then return r.seg end
    end
    return nil
end

function WorldVeh.Stats()
    local s = {}
    for k, v in pairs(stat) do s[k] = v end
    s.tracked = trackedN
    s.enabled = enabled()
    return s
end

-- ── Schleife ───────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        local iv = floor(cfg('IntervalMs', 200))
        if iv < 50 then iv = 50 end
        Wait(iv)
        if Recording and enabled() then
            local ok, err = pcall(pass, GetGameTimer())
            if not ok and Config.Debug then
                print(('^1[D-RPS/veh] Durchlauf fehlgeschlagen: %s^0'):format(tostring(err)))
            end
        elseif trackedN > 0 then
            WorldVeh.FlushAll()
        end
    end
end)

return WorldVeh
