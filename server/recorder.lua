--[[ D-RPS — server/recorder.lua
     Sampelt server-autoritativen Spielerzustand, kodiert als Delta (Protocol),
     akkumuliert in Chunks; volle Chunks wandern in RAM-Ring und Disk-Archiv.
     Nur Evidence-Layer (Position/Health/Fahrzeug/Yaw). ]]

Recorder = {}

local rec       = {}      -- [src] = Aufzeichnungs-Zustand (siehe startPlayer)
local rings     = {}      -- [src] = RingBuffer
Recording       = false   -- global: Master-Schalter

local floor = math.floor

-- WARNUNG: GetGameTimer (Uptime) und os.time (Wanduhr) nie mischen. Versatz
-- einmal bestimmen, jeden Zeitstempel aus DERSELBEN Quelle via Recorder.AbsTime.
local EPOCH_MS = (os.time() * 1000) - GetGameTimer()

-- ── Hilfen ─────────────────────────────────────────────────────────────────

local function playerHash(src)
    return RPSPlayerHash(src)
end

--- Server-autoritativen Zustand eines Peds lesen. Im Fahrzeug wird die
--- Fahrzeug-Bahn aufgezeichnet, damit das Playback das Auto nachbaut.
local function readState(src, ped)
    local hp  = GetEntityHealth(ped)
    local veh = GetVehiclePedIsIn(ped, false)

    local flags = 0
    if hp > 5 then flags = flags | Protocol.FLAG.ALIVE end

    local x, y, z, heading
    local vehModel, vehSeat = 0, -1
    local steer, speed, vpitch, vroll = 0.0, 0.0, 0.0, 0.0

    if veh and veh ~= 0 then
        flags = flags | Protocol.FLAG.IN_VEHICLE
        local vc = GetEntityCoords(veh)
        x, y, z  = vc.x, vc.y, vc.z
        heading  = GetEntityHeading(veh)
        vehModel = GetEntityModel(veh) & 0xFFFFFFFF

        -- Sitzplatz bestimmen. Default ist Fahrersitz (-1); nur wenn ein anderer
        -- Ped nachweislich am Steuer sitzt, Beifahrersitz suchen.
        local okD, driver = pcall(GetPedInVehicleSeat, veh, -1)
        if okD and driver and driver ~= 0 and driver ~= ped then
            vehSeat = 0
            for seat = 0, 6 do
                local okS, occ = pcall(GetPedInVehicleSeat, veh, seat)
                if okS and occ == ped then vehSeat = seat; break end
            end
        else
            vehSeat = -1
            flags = flags | Protocol.FLAG.IS_DRIVER
        end

        -- Fahrzeug-Dynamik (server-autoritativ)
        speed = GetEntitySpeed(veh)
        local okSt, st = pcall(function()
            return Citizen.InvokeNative(0x1382FCEA, veh, Citizen.ResultAsFloat())
        end)
        if okSt and type(st) == 'number' then steer = st end
        local okR, rot = pcall(GetEntityRotation, veh, 2)
        if okR and rot then vpitch, vroll = rot.x, rot.y end
    else
        local c = GetEntityCoords(ped)
        x, y, z  = c.x, c.y, c.z
        heading  = GetEntityHeading(ped)
    end

    -- Kamera-Yaw ist serverseitig verfuegbar (Pitch wird verworfen).
    local camYaw = 0.0
    local okCam, rot = pcall(GetPlayerCameraRotation, src)
    if okCam and rot then camYaw = rot.z end

    return {
        x = x, y = y, z = z, heading = heading,
        health  = math.min(255, floor(hp)),
        armour  = math.min(255, floor(GetPedArmour(ped))),
        flags   = flags,
        vehModel = vehModel, vehSeat = vehSeat,
        camYaw  = camYaw, camPitch = 0.0,   -- Pitch: Platzhalter
        steer = steer, speed = speed, vpitch = vpitch, vroll = vroll,
    }
end

-- ── Chunk-Verwaltung ───────────────────────────────────────────────────────

local function closeChunk(src, r)
    if r.nParts == 0 then return end

    local header = Protocol.EncodeChunkHeader(
        r.chunkStartSec, r.chunkStartMs, r.playerHash, r.nParts)
    local chunk = header .. table.concat(r.parts, '', 1, r.nParts)

    rings[src]:push(chunk, r.chunkStartSec, r.chunkStartMs, r.nParts)

    -- Schreib-Offset in den Segment-Index eintragen, damit ein Segment per seek
    -- gelesen werden kann statt der ganzen Tagesdatei (sonst MB je Abruf im Thread).
    local ok, off = Archive.WriteChunk(r.playerHash, r.chunkStartSec, chunk)
    if ok and off and SegIndex and SegIndex.Note then
        SegIndex.Note(r.playerHash, SegIndex.SegOf(r.chunkStartSec),
                      off, #chunk, r.nParts, r.chunkStartSec)
    end

    -- offenen Chunk zuruecksetzen; naechster Sample wird Keyframe
    r.nParts = 0
    r.prev   = nil
end

--- Chunk-Zeitstempel setzen. Sekunde und Millisekunde aus einer Rechnung
--- (dieselbe Uhr) — sonst laegen Evidence- und Fidelity-Strom versetzt.
local function beginChunk(r, nowTimer)
    local abs = EPOCH_MS + nowTimer
    r.chunkStartSec   = abs // 1000
    r.chunkStartMs    = abs % 1000
    r.chunkStartTimer = nowTimer
    -- Segment, in dem der Chunk beginnt; er verlaesst dieses Segment nie.
    r.seg = (Session and Session.SegOf) and Session.SegOf(r.chunkStartSec) or nil
end

--- Absolute Zeit (Sekunde, Millisekunde) aus dem Uptime-Zaehler.
function Recorder.AbsTime(nowTimer)
    local abs = EPOCH_MS + (nowTimer or GetGameTimer())
    return abs // 1000, abs % 1000
end

--- Einen Spieler einmal sampeln.
local function sampleOne(src, r, nowTimer)
    local ped = r.ped
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        r.ped = GetPlayerPed(src)   -- Handle auffrischen (Respawn etc.)
        return
    end

    local s  = readState(src, ped)
    local dt = nowTimer - r.lastTimer
    if dt > 65535 then dt = 65535 end   -- u16-Deckel

    -- Respawn erkennen: Uebergang tot→lebendig (fuer Spawn-Kill-Detektion)
    if r.prev then
        local wasAlive = (r.prev.flags & Protocol.FLAG.ALIVE) ~= 0
        local isAlive  = (s.flags & Protocol.FLAG.ALIVE) ~= 0
        if isAlive and not wasAlive then TriggerEvent('D-RPS:internal:spawn', src) end
    end

    -- Idle-Drosselung: Bewegung gegen letzten Sample messen
    if Config.IdleAfterSeconds > 0 and r.prev then
        local dx, dy = s.x - r.prev.x, s.y - r.prev.y
        local moved2 = dx * dx + dy * dy
        if moved2 < (Config.IdleMoveThreshold * Config.IdleMoveThreshold) then
            r.idleMs = (r.idleMs or 0) + dt
            if r.idleMs >= Config.IdleAfterSeconds * 1000 then
                r.intervalMs = Config.SampleIntervalIdleMs
            end
        else
            r.idleMs = 0
            r.intervalMs = Config.SampleIntervalMs
        end
    end

    -- Kodieren: erster Sample im Chunk (prev=nil) → Keyframe, sonst Delta
    local packed
    if r.prev then
        packed = Protocol.EncodeDelta(r.prev, s, dt)
    else
        beginChunk(r, nowTimer)
        packed = Protocol.EncodeKeyframe(s, 0)
    end

    r.nParts = r.nParts + 1
    r.parts[r.nParts] = packed
    r.prev = s
    r.lastTimer = nowTimer

    -- Chunk voll?
    if (nowTimer - r.chunkStartTimer) >= (Config.DiskChunkSeconds * 1000) then
        closeChunk(src, r)
    end
end

-- ── Lebenszyklus ───────────────────────────────────────────────────────────

function Recorder.StartPlayer(src)
    if rec[src] then return end
    rec[src] = {
        ped        = GetPlayerPed(src),
        playerHash = playerHash(src),
        parts      = {},
        nParts     = 0,
        prev       = nil,
        lastTimer  = GetGameTimer(),
        intervalMs = Config.SampleIntervalMs,
        idleMs     = 0,
    }
    rings[src] = RingBuffer.new()
    SessionIndex.Note(src)                      -- fuer die Spielerliste im Replay
    TriggerEvent('D-RPS:internal:spawn', src)   -- Join zaehlt als Spawn (Spawn-Kill)
end

function Recorder.StopPlayer(src)
    local r = rec[src]
    if not r then return end
    closeChunk(src, r)          -- offenen Rest sichern
    rec[src]   = nil
    rings[src] = nil
    SessionIndex.Close(src, 'drop')
end

--- Stats fuer /rps_stats und spaeter die UI.
function Recorder.Stats()
    local players, bytes, chunks = 0, 0, 0
    for src, ring in pairs(rings) do
        players = players + 1
        bytes   = bytes + ring.totalBytes
        chunks  = chunks + ring.count
    end
    return { players = players, ramBytes = bytes, ramChunks = chunks }
end

function Recorder.GetRing(src) return rings[src] end

--- Offenen Chunk sofort schliessen (Stop/Disconnect). Zu junge Chunks (<1s)
--- werden NICHT geschlossen: gleiche Startsekunde = gleicher Schluessel, der
--- Leser wuerfe sonst die volle Minute zugunsten des kurzen Chunks weg.
function Recorder.ForceClose(src)
    local r = rec[src]
    if not r or r.nParts == 0 then return false end
    if (GetGameTimer() - (r.chunkStartTimer or 0)) < 1000 then return false end
    closeChunk(src, r)
    return true
end

--- Offenen Chunk lesen, ohne die Delta-Kette zu zerschneiden (Replay-Pfad;
--- ForceClose hier wuerde bei jedem Menueaufruf alle Aufzeichnungen zerhacken).
function Recorder.PeekOpen(src)
    local r = rec[src]
    if not r or r.nParts == 0 then return nil end
    local header = Protocol.EncodeChunkHeader(
        r.chunkStartSec, r.chunkStartMs, r.playerHash, r.nParts)
    return header .. table.concat(r.parts, '', 1, r.nParts), r.chunkStartSec
end

--- Metadaten der laufenden Aufzeichnung eines Spielers (playerHash etc.).
function Recorder.GetRingMeta(src)
    local r = rec[src]
    if not r then return nil end
    return { playerHash = r.playerHash, intervalMs = r.intervalMs }
end

--- playerHash eines Spielers, ohne den Ring anzufassen.
function Recorder.HashOf(src)
    local r = rec[src]
    return r and r.playerHash or nil
end

--- Alle GERADE aufgezeichneten playerHashes. Fuer Retention zu wenig (dort
--- zaehlen auch ausgeloggte) — die kommen aus SessionIndex.KnownHashes().
function Recorder.KnownHashes()
    local set = {}
    for _, r in pairs(rec) do set[r.playerHash] = true end
    return set
end

-- ── Sampling-Loop ──────────────────────────────────────────────────────────
-- Ein Thread laeuft mit dem schnellen Intervall; pro Spieler entscheidet dessen
-- intervalMs, ob gesampelt wird (eigene, ggf. gedrosselte Rate je Spieler).

CreateThread(function()
    while true do
        Wait(Config.SampleIntervalMs)
        if Recording then
            local now = GetGameTimer()

            -- Chunks an der Segmentgrenze schliessen: so gehoert ein Chunk zu
            -- GENAU EINEM Segment (sonst Fehlzuordnung bei Anzeige/Auslieferung/
            -- Client-Verdraengung). Pruefung HIER, nicht in sampleOne, das bei
            -- fehlendem Ped frueh zurueckkehrt und den Chunk offen liesse.
            -- Dieselbe Uhr wie der Chunk-Zeitstempel (Recorder.AbsTime), sonst
            -- faellt der Schnitt ins falsche Segment.
            if Session and Session.SegOf then
                local nowSec = Recorder.AbsTime(now)
                local nowSeg = Session.SegOf(nowSec)
                for src, r in pairs(rec) do
                    if r.nParts > 0 and r.seg and r.seg ~= nowSeg then
                        closeChunk(src, r)
                    end
                end
            end

            for src, r in pairs(rec) do
                if (now - r.lastTimer) >= (r.intervalMs - 5) then
                    sampleOne(src, r, now)
                end
            end
        end
    end
end)

return Recorder
