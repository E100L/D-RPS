--[[ ===========================================================================
    D-RPS — Dollar Replay System
    client/scene.lua

    Szenenspur: was der Client um sich herum sieht (Ambient-Verkehr/Peds, die
    der Server nicht kennt). VERSUCHSSTAND, standardmaessig aus (Config.Scene.Enabled).
    Ergaenzt den Beweisstrom, ersetzt ihn nicht. Gleiche Bauart wie
    server/vehicles.lua; einziger Unterschied ist die Identitaet (siehe keyOf()).
=========================================================================== ]]

Scene = {}

local floor = math.floor

-- [entityHandle] = Aufzeichnungszustand
local tracked  = {}
local trackedN = 0
local seq      = 0

-- Fertige, noch nicht abgeschickte Chunks
local outbox, outboxN, outboxBytes = {}, 0, 0
local lastUpload = 0

local stat = {
    passes = 0, lastMs = 0.0, maxMs = 0.0, avgMs = 0.0,
    veh = 0, ped = 0, capped = 0,
    samples = 0, skipped = 0, chunks = 0, bytes = 0,
    sent = 0, sentBytes = 0, dropped = 0,
}

-- ── Konfiguration ──────────────────────────────────────────────────────────

local function cfg(key, dflt)
    local s = Config and Config.Scene
    local v = s and s[key]
    if type(v) == 'number' or type(v) == 'boolean' then return v end
    return dflt
end

local function enabled() return cfg('Enabled', false) == true end

-- ── Zeitachse ──────────────────────────────────────────────────────────────
-- Aus client/fidelity.lua, nicht selbst gefuehrt. Siehe RPSClientClock().

local function absSec(nowTimer)
    local _, _, off = RPSClientClock()
    if not off then return nil end
    local ms = nowTimer + off * 1000
    return ms // 1000, ms % 1000
end

local function segOfTimer(nowTimer)
    local ep, ss, off = RPSClientClock()
    if not ep or not ss or not off then return nil end
    local sec = (nowTimer // 1000) + off
    if sec <= ep then return 0 end
    return (sec - ep) // ss
end

-- ── Identitaet ─────────────────────────────────────────────────────────────

--- Stabiler Schluessel einer beobachteten Entitaet: bleibt waehrend ihrer
--- Lebensdauer gleich und kehrt danach nicht wieder. Vernetzte tragen einen
--- Netzwerk-Identifikator (bei allen Clients gleich); rein lokale bekommen
--- einen selbst vergebenen, gesalzen aus Sitzung und Server-ID.
local function keyOf(ent)
    local base
    local okN, isNet = pcall(NetworkGetEntityIsNetworked, ent)
    if okN and isNet then
        local okI, id = pcall(NetworkGetNetworkIdFromEntity, ent)
        if okI and type(id) == 'number' and id ~= 0 then
            base = (id * 2246822519) & 0xFFFFFFFF
        end
    end
    if not base then
        seq = seq + 1
        base = (seq * 40503) & 0xFFFFFFFF
    end

    local ep = select(1, RPSClientClock()) or 0
    local me = GetPlayerServerId(PlayerId()) or 0
    local h = ((ep & 0xFFFFFFFF) * 2654435761) & 0xFFFFFFFF
    h = h ~ ((me * 374761393) & 0xFFFFFFFF)
    h = h ~ base
    h = (h ~ (h >> 15)) & 0xFFFFFFFF
    h = (h * 2654435761) & 0xFFFFFFFF
    if h == 0 or h == Protocol.WORLD_HASH then h = (h + 1) & 0xFFFFFFFF end
    return h
end

-- ── Zustand lesen ──────────────────────────────────────────────────────────

--- Feldbelegung wie in server/vehicles.lua. vehModel traegt bei beiden Arten
--- das Modell; die Art sagt Protocol.FLAG.IS_VEHICLE. Endmarker (vehModel = 0)
--- gilt fuer beide.
local function readEnt(ent, isVeh)
    local c = GetEntityCoords(ent)
    local flags = 0
    local hp, steer, speed, vpitch, vroll = 0, 0.0, 0.0, 0.0, 0.0

    local okS, sp = pcall(GetEntitySpeed, ent)
    if okS and type(sp) == 'number' then speed = sp end
    local okR, rot = pcall(GetEntityRotation, ent, 2)
    if okR and rot then vpitch, vroll = rot.x, rot.y end

    if isVeh then
        flags = flags | Protocol.FLAG.IS_VEHICLE
        local okH, raw = pcall(GetEntityHealth, ent)
        if okH and type(raw) == 'number' then
            hp = floor(math.max(0.0, math.min(1000.0, raw)) / 1000.0 * 255.0 + 0.5)
        end
        if hp > 0 then flags = flags | Protocol.FLAG.ALIVE end
        local okSt, st = pcall(GetVehicleSteeringAngle, ent)
        if okSt and type(st) == 'number' then steer = st end
    else
        local okH, raw = pcall(GetEntityHealth, ent)
        if okH and type(raw) == 'number' then hp = math.min(255, floor(raw)) end

        -- Gewinn der Clientsicht: der Server liest diese Zustaende nicht.
        -- Client-gemeldet, also Treue-Klasse, nie Beweis (Oberflaeche kennzeichnet das).
        if not IsPedDeadOrDying(ent, true) then flags = flags | Protocol.FLAG.ALIVE end
        if IsPedInAnyVehicle(ent, false)     then flags = flags | Protocol.FLAG.IN_VEHICLE end
        if IsPedRagdoll(ent)                 then flags = flags | Protocol.FLAG.RAGDOLL end
        if IsPedWalking(ent)                 then flags = flags | Protocol.FLAG.WALKING end
        if IsPedRunning(ent)                 then flags = flags | Protocol.FLAG.RUNNING end
        if IsPedSprinting(ent)               then flags = flags | Protocol.FLAG.SPRINTING end
        if IsPedJumping(ent)                 then flags = flags | Protocol.FLAG.JUMPING end
        if IsPedInCover(ent, false)          then flags = flags | Protocol.FLAG.IN_COVER end
        if IsPedShooting(ent)                then flags = flags | Protocol.FLAG.SHOOTING end
        if IsPedSwimming(ent)                then flags = flags | Protocol.FLAG.SWIMMING end
        if IsPedFalling(ent)                 then flags = flags | Protocol.FLAG.FALLING end
    end

    return {
        x = c.x, y = c.y, z = c.z,
        heading = GetEntityHeading(ent),
        health = hp, armour = 0,
        flags = flags,
        vehModel = GetEntityModel(ent) & 0xFFFFFFFF, vehSeat = -1,
        camYaw = 0.0, camPitch = 0.0, moveBlend = 0.0,
        steer = steer, speed = speed, vpitch = vpitch, vroll = vroll,
    }
end

-- ── Chunk-Verwaltung ───────────────────────────────────────────────────────

local function beginChunk(r, nowTimer)
    local sec, ms = absSec(nowTimer)
    r.chunkStartSec, r.chunkStartMs = sec or 0, ms or 0
    r.seg = segOfTimer(nowTimer)
end

--- Chunk abschliessen und in die Ausgangsablage legen.
--- `gone` haengt den Endmarker an (vehModel = 0), genau wie die Weltspur.
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

    local chunk = Protocol.EncodeChunkHeader(
                      r.chunkStartSec, r.chunkStartMs, r.key, r.nParts)
                  .. table.concat(r.parts, '', 1, r.nParts)

    -- Ausgangsablage gedeckelt: haengt der Upload, wird das Aelteste verworfen
    -- (Szenenspur ist Beiwerk, darf dem Beweisstrom keine Ressourcen nehmen).
    local capBytes = floor(cfg('MaxBatchBytes', 16384)) * 8
    if outboxBytes + #chunk > capBytes then
        stat.dropped = stat.dropped + 1
    else
        outboxN = outboxN + 1
        outbox[outboxN] = chunk
        outboxBytes = outboxBytes + #chunk
    end

    stat.chunks = stat.chunks + 1
    stat.bytes  = stat.bytes + #chunk

    r.nParts = 0
    r.prev   = nil
end

local function sampleEnt(r, ent, isVeh, nowTimer, heartbeatMs)
    local s = readEnt(ent, isVeh)

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
        return                      -- lastTimer bleibt stehen: dt sammelt sich
    end

    r.nParts = r.nParts + 1
    r.parts[r.nParts] = packed
    r.prev = s
    r.lastTimer = nowTimer
    stat.samples = stat.samples + 1
end

-- ── Durchlauf ──────────────────────────────────────────────────────────────

local function pass(nowTimer)
    local t0 = GetGameTimer()

    local radius      = cfg('Radius', 60.0)
    local maxEnt      = floor(cfg('MaxEntities', 40))
    local heartbeatMs = floor(cfg('HeartbeatMs', 5000))
    local r2          = radius * radius
    -- Loslassgrenze der Hysterese (siehe scan): 30 % weiter als die Aufnahmegrenze.
    local rOut2       = (radius * 1.3) * (radius * 1.3)

    -- Bezugspunkt ist der PED, nicht die Kamera: waehrend einer Wiedergabe steht
    -- die Kamera in der rekonstruierten Szene und saehe die eigenen Klone.
    local pp = PlayerPedId()
    if not pp or pp == 0 or not DoesEntityExist(pp) then return end
    local me = GetEntityCoords(pp)

    local live, nVeh, nPed, nCap = {}, 0, 0, 0

    -- Eigenen Ped nur auslassen, wenn IncludeSelf=false: er steht sonst schon
    -- im Beweisstrom und waere im Replay doppelt. In reiner Clientsicht muss er mit.
    local skipSelf = (cfg('IncludeSelf', true) == false) and pp or nil

    -- GetGamePool liefert eine TABELLE, keinen Iterator.
    local function scan(pool, isVeh)
        if type(pool) ~= 'table' then return end
        for i = 1, #pool do
            local ent = pool[i]
            if ent ~= skipSelf and DoesEntityExist(ent) then
                local c = GetEntityCoords(ent)
                local dx, dy, dz = c.x - me.x, c.y - me.y, c.z - me.z
                local d2 = dx * dx + dy * dy + dz * dz

                -- HYSTERESE: aufgenommen innerhalb des Umkreises, losgelassen erst
                -- deutlich ausserhalb. Sonst zerfaellt eine Fahrt am Rand in viele Spuren.
                local rec = tracked[ent]
                if d2 <= (rec and rOut2 or r2) then
                    if (nVeh + nPed) >= maxEnt then
                        nCap = nCap + 1
                    else
                        if isVeh then nVeh = nVeh + 1 else nPed = nPed + 1 end

                        -- Handles werden wiederverwendet: anderes Modell = andere
                        -- Entitaet, ihre Spur darf die alte nicht fortsetzen.
                        local model = GetEntityModel(ent) & 0xFFFFFFFF
                        if rec and rec.model ~= model then
                            closeChunk(rec, true)
                            tracked[ent] = nil
                            trackedN = trackedN - 1
                            rec = nil
                        end

                        if not rec then
                            rec = { key = keyOf(ent), parts = {}, nParts = 0,
                                    prev = nil, lastTimer = nowTimer,
                                    veh = isVeh, model = model }
                            tracked[ent] = rec
                            trackedN = trackedN + 1
                        end
                        rec.lastSeen = nowTimer
                        live[ent] = true
                    end
                end
            end
        end
    end

    if cfg('Vehicles', true) then scan(GetGamePool('CVehicle'), true) end
    if cfg('Peds', true)     then scan(GetGamePool('CPed'),     false) end

    local nowSeg = segOfTimer(nowTimer)

    local graceMs = floor(cfg('GraceMs', 1500))

    for ent, r in pairs(tracked) do
        -- Segmentgrenze: ein Chunk gehoert zu genau einem Segment; gilt auch fuer
        -- gerade unsichtbare Entitaeten (Wiedergabe ersetzt Block je Segment/Schluessel).
        if nowSeg and r.nParts > 0 and r.seg and r.seg ~= nowSeg then
            closeChunk(r, false)
        end

        if live[ent] then
            sampleEnt(r, ent, r.veh, nowTimer, heartbeatMs)
        elseif DoesEntityExist(ent)
               and (nowTimer - (r.lastSeen or nowTimer)) < graceMs then
            -- Kurz aus dem Umkreis, existiert weiter: nicht schliessen, keinen
            -- Endmarker, kein Sample (sonst interpoliert die Wiedergabe durch Haeuser).
        else
            closeChunk(r, true)     -- wirklich weg: mit Endmarker
            tracked[ent] = nil
            trackedN = trackedN - 1
        end
    end

    local ms = (GetGameTimer() - t0)
    stat.passes = stat.passes + 1
    stat.lastMs = ms
    if ms > stat.maxMs then stat.maxMs = ms end
    stat.avgMs = stat.avgMs + (ms - stat.avgMs) / math.min(stat.passes, 100)
    stat.veh, stat.ped, stat.capped = nVeh, nPed, nCap
end

-- ── Upload ─────────────────────────────────────────────────────────────────

--- Gebuendelt hochladen. Gegenseite (server/scene.lua) noch nicht verdrahtet;
--- bis dahin misst das Modul nur, was anfallen wuerde.
local function upload()
    if outboxN == 0 then return end
    if not cfg('Upload', false) then
        -- Nur messen: Ablage leeren, damit sie nicht mitwaechst.
        outbox, outboxN, outboxBytes = {}, 0, 0
        return
    end

    local payload = table.concat(outbox, '', 1, outboxN)
    stat.sent = stat.sent + outboxN
    stat.sentBytes = stat.sentBytes + #payload
    TriggerServerEvent('d-rps:scene', payload)
    outbox, outboxN, outboxBytes = {}, 0, 0
end

-- ── Oeffentliche Schnittstelle ─────────────────────────────────────────────

function Scene.FlushAll()
    for ent, r in pairs(tracked) do
        closeChunk(r, true)
        tracked[ent] = nil
    end
    trackedN = 0
end

function Scene.Stats()
    local s = {}
    for k, v in pairs(stat) do s[k] = v end
    s.tracked = trackedN
    s.enabled = enabled()
    s.pending = outboxN
    s.pendingBytes = outboxBytes
    return s
end

-- ── Schleife ───────────────────────────────────────────────────────────────

CreateThread(function()
    while true do
        local iv = floor(cfg('IntervalMs', 500))
        if iv < 100 then iv = 100 end
        Wait(iv)

        -- Waehrend einer Wiedergabe wird nicht aufgezeichnet: der Aufzeichner
        -- saehe sonst die Klone des Replays als Umgebung und schriebe sie ins Archiv.
        local replaying = (type(RPSPlaybackActive) == 'function') and RPSPlaybackActive()

        if enabled() and not replaying and RPSClientClock() then
            local ok, err = pcall(pass, GetGameTimer())
            if not ok and Config.Debug then
                print(('^1[D-RPS/scene] Durchlauf fehlgeschlagen: %s^0'):format(tostring(err)))
            end

            local now = GetGameTimer()
            if (now - lastUpload) >= floor(cfg('UploadMs', 2000)) then
                lastUpload = now
                pcall(upload)
            end
        elseif trackedN > 0 then
            -- Beim Oeffnen eines Replays offene Chunks sichern und Verfolgung
            -- fallenlassen; nachher faengt sie sauber neu an.
            Scene.FlushAll()
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Scene.FlushAll()
end)

return Scene
