--[[ D-RPS — server/reporter.lua
     Nimmt Fidelity-Meldungen der Clients entgegen (Aussehen, Welt, Bewegung),
     haelt sie pro Spieler vor. Rein kosmetisch, getrennt vom Evidence-Layer. ]]

local appearances = {}   -- [hash] = Aussehen
local appStat = { recv = 0, ok = 0, reject = 0, lastReject = '-', lastHash = 0 }

-- Aussehen elementweise pruefen. Fidelity-Daten sind nicht vertrauenswuerdig:
-- nie ungeprueft an eine Native weiterreichen (String an SetPed* toetet den
-- Playback-Thread und laesst Klone stehen).
local function sanitizeAppearance(a)
    if type(a) ~= 'table' then return nil, 'kein table' end
    if type(a.model) ~= 'number' then return nil, 'model fehlt' end
    if type(a.comp) ~= 'table' then return nil, 'comp fehlt' end

    -- Ganzzahl in Grenzen (Indizes, Farben).
    local function num(v, lo, hi)
        if type(v) ~= 'number' or v ~= v then return nil end   -- auch NaN raus
        v = math.floor(v)
        if v < lo or v > hi then return nil end
        return v
    end

    -- Bruchteil in Grenzen, OHNE Abrunden (Gesichtsmischung/-zuege wuerden durch
    -- num zerstoert -> anderer Mensch).
    local function fnum(v, lo, hi)
        if type(v) ~= 'number' or v ~= v then return nil end
        if v < lo or v > hi then return nil end
        return v + 0.0
    end

    -- Flaches Array pruefen; ein Ausreisser wird durch den Default ersetzt, nicht
    -- das ganze Aussehen verworfen.
    local function arr(src, n, lo, hi, dflt, float)
        if type(src) ~= 'table' then return nil end
        local out, any = {}, false
        for i = 1, n do
            -- Explizit statt 'float and fnum() or num()': das Idiom fiele bei
            -- gueltigem fnum-nil auf num zurueck und uebernaehme Muell.
            local v
            if float then v = fnum(src[i], lo, hi) else v = num(src[i], lo, hi) end
            if v then any = true else v = dflt end
            out[i] = v
        end
        return any and out or nil
    end

    -- Vergleiche statt '&': die Bitop auf Nicht-Integer-Float wuerfe (Lua 5.4),
    -- und der Handler ruft sanitize ohne pcall — die Barriere darf nie werfen.
    local mf = math.floor(a.model)
    if mf ~= mf or mf < -0x80000000 or mf > 0xFFFFFFFF then return nil, 'model bereich' end
    local model = mf & 0xFFFFFFFF
    if model == 0 then return nil, 'model 0' end

    -- Skin-Tabelle: flache Abbildung string→Zahl, nur endliche Zahlen, Anzahl
    -- gedeckelt — sonst blaeht ein manipulierter Client die Ablage auf.
    local skin
    if type(a.skin) == 'table' then
        skin = {}
        local cnt = 0
        for k, v in pairs(a.skin) do
            if type(k) == 'string' and type(v) == 'number' and v == v
               and v > -100000 and v < 100000 then
                skin[k] = v
                cnt = cnt + 1
                if cnt >= 300 then break end
            end
        end
        if cnt == 0 then skin = nil end
    end

    -- ALLES FLACH UND 1-BASIERT: 0-indizierte Tabellen ueberleben die Netzgrenze nicht.
    return {
        model = model,
        -- Kleidung: 12 x (drawable, textur, palette). Wertebereich MUSS weit sein
        -- (DLC/Addon-Drawables > 255, sonst Reset auf 0 -> nackte Arme).
        comp  = arr(a.comp, 36,  0, 65535, 0),
        prop  = arr(a.prop, 16, -1, 65535, -1),       -- 8 x (index, textur)
        head  = arr(a.head,  9,  0.0, 45.0, 0.0, true),
        face  = arr(a.face, 20, -1.0, 1.0, 0.0, true),
        over  = arr(a.over, 65,  0.0, 65535.0, 0.0, true),
        hair  = arr(a.hair,  2,  0, 63, 0),
        eyes  = num(a.eyes, 0, 63) or 0,
        -- Wenn vorhanden, ueberstimmt sie im Playback alles obige.
        skin  = skin,
    }

end

RegisterNetEvent('d-rps:reportAppearance', function(a)
    local src = source
    -- Aussehen ist Fidelity-Klasse; derselbe Schalter wie beim Fidelity-Strom.
    if not Config.Fidelity then return end
    appStat.recv = appStat.recv + 1
    local clean, why = sanitizeAppearance(a)
    if not clean then
        appStat.reject = appStat.reject + 1
        appStat.lastReject = why or 'unbekannt'
        return
    end
    appStat.ok = appStat.ok + 1
    local hash = RPSPlayerHash(src)
    appStat.lastHash = hash
    -- Ueber den Hash, nicht src: sonst zeigt das Replay ausgeloggte Spieler als
    -- Standard-Freemode-Modell.
    appearances[hash] = clean

    -- LIVE an offene Replays verteilen (stream.lua): das Manifest holt das
    -- Aussehen nur EINMAL beim Oeffnen, spaeter gemeldete Daten kaemen sonst nie an.
    TriggerEvent('d-rps:internal:appearance', hash, clean)
end)

--- Vom Replay-Stream genutzt: das zuletzt gemeldete Aussehen eines Spielers.
function GetPlayerAppearance(src)
    return appearances[RPSPlayerHash(src)]
end

--- Dasselbe fuer Spieler, die nicht mehr online sind.
function GetAppearanceByHash(hash)
    return appearances[hash]
end

-- == Welt-Zustand (Uhrzeit/Wetter) ==
-- Zeitreihe fuer den Weltzustand je Zeitpunkt. Ein Eintrag alle 10 s, Ring auf
-- 2 h begrenzt. Nur EIN Spieler meldet (serverweit gleich; mehrere Melder
-- ueberfuellten den Ring).
local worldLog     = {}
local worldHead    = 1     -- Ringkopf, damit kein table.remove(…, 1) noetig ist
local worldCount   = 0
local worldReporter = nil
local MAX_WORLD    = math.max(120, math.ceil(Config.ReplayWindowMinutes * 60 / 10) + 60)

local function pickWorldReporter()
    if worldReporter and GetPlayerName(worldReporter) then return end
    worldReporter = nil
    for _, sp in ipairs(GetPlayers()) do worldReporter = tonumber(sp); break end
end

RegisterNetEvent('d-rps:reportWorld', function(w)
    local src = source
    pickWorldReporter()
    if worldReporter and src ~= worldReporter then return end
    if type(w) ~= 'table' or type(w.h) ~= 'number' then return end

    worldLog[worldHead] = {
        t = os.time(),
        h = w.h, m = w.m, s = w.s,
        w1 = w.w1, w2 = w.w2, pct = w.pct,
    }
    worldHead = (worldHead % MAX_WORLD) + 1
    if worldCount < MAX_WORLD then worldCount = worldCount + 1 end
end)

--- Welt-Zustand in chronologischer Reihenfolge.
function GetWorldLog()
    local out = {}
    local start = (worldCount < MAX_WORLD) and 1 or worldHead
    for k = 0, worldCount - 1 do
        out[#out + 1] = worldLog[((start - 1 + k) % MAX_WORLD) + 1]
    end
    return out
end

-- == Fidelity-Strom ==
-- Nur clientseitig bekannt: Bewegung, Blickrichtung, Fahrzeugdetails. Getrennt
-- vom Evidence-Strom; Ausfall laesst das Replay funktionsfaehig.

local fidRing = {}     -- [src] = { chunks = {}, head, count, cap, playerHash }

local function fidRingFor(src)
    local r = fidRing[src]
    if not r then
        r = { chunks = {}, meta = {}, head = 1, count = 0,
              -- Cap ueber Segmentbreite, nicht DiskChunkSeconds (siehe
              -- ringbuffer.lua) — sonst nur halbe Kapazitaet.
              cap = math.max(2, math.ceil(Config.RamBufferMinutes * 60 /
                    math.min((Session and Session.SegSeconds and Session.SegSeconds())
                             or Config.DiskChunkSeconds, Config.DiskChunkSeconds))),
              playerHash = RPSPlayerHash(src) }
        fidRing[src] = r
    end
    return r
end

RegisterNetEvent('d-rps:fidelity', function(chunk)
    local src = source
    if not Config.Fidelity then return end
    if type(chunk) ~= 'string' or #chunk < 14 or #chunk > Config.MaxReporterBytes * 8 then
        return
    end

    -- Kopf pruefen, bevor irgendetwas uebernommen wird.
    local hdr = Fidelity.DecodeChunkHeader(chunk)
    if not hdr then return end

    local r = fidRingFor(src)

    -- Hash und Zeit setzt der Server. Client-Zeit nie mischen: sein ms-Anteil
    -- stammt aus GetGameTimer (Uptime, fremde Epoche) -> Recorder.AbsTime.
    local nowSec, nowMs = Recorder.AbsTime()
    local startSec = nowSec - Config.DiskChunkSeconds
    local startMs  = nowMs

    -- Plausible Client-Angabe innerhalb einer Chunk-Laenge darf feinjustieren
    -- (sie kennt den Chunk-BEGINN, den der Server nicht kennt).
    if type(hdr.startSec) == 'number' and hdr.startSec > 0
       and math.abs(hdr.startSec - startSec) <= Config.DiskChunkSeconds then
        startSec = hdr.startSec
    end

    local fixed = Fidelity.EncodeChunkHeader(startSec, startMs,
                      r.playerHash, hdr.nSamples) .. chunk:sub(15)

    local i = r.head
    r.chunks[i] = fixed
    r.meta[i]   = { startSec = startSec }
    r.head = (i % r.cap) + 1
    if r.count < r.cap then r.count = r.count + 1 end

    Archive.WriteFidelity(r.playerHash, startSec, fixed)
end)

AddEventHandler('playerDropped', function()
    fidRing[source] = nil
    if worldReporter == source then worldReporter = nil end
end)

--- Fidelity-Chunks eines Spielers fuer ein Zeitfenster (Disk + RAM).
--- src darf nil sein — dann kommt alles aus dem Archiv.
function GetFidelityChunksByHash(hash, src, fromSec, toSec)
    local byStart, order = {}, {}

    for _, c in ipairs(Archive.ReadFidelityRange(hash, fromSec, toSec)) do
        if not byStart[c.startSec] then
            byStart[c.startSec] = c.data; order[#order + 1] = c.startSec
        end
    end

    local r = src and fidRing[src]
    if r then
        local start = (r.count < r.cap) and 1 or r.head
        for k = 0, r.count - 1 do
            local i = ((start - 1 + k) % r.cap) + 1
            local m = r.meta[i]
            if r.chunks[i] and m and m.startSec + Config.DiskChunkSeconds >= fromSec
               and m.startSec <= toSec and not byStart[m.startSec] then
                byStart[m.startSec] = r.chunks[i]; order[#order + 1] = m.startSec
            end
        end
    end

    table.sort(order)
    local out = {}
    for _, s in ipairs(order) do out[#out + 1] = byStart[s] end
    return out
end

function GetFidelityChunks(src, fromSec, toSec)
    local r = fidRing[src]
    local hash = r and r.playerHash or RPSPlayerHash(src)
    return GetFidelityChunksByHash(hash, src, fromSec, toSec)
end
