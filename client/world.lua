--[[ ===========================================================================
    D-RPS — Dollar Replay System
    client/world.lua

    Weltspur (Client): Fahrzeuge ohne Insassen. Eigene Warteschlange/Budget/
    Speicher neben dem Beweisstrom — faellt sie aus, bleibt das Replay nutzbar.
    Je Segment und Fahrzeug genau EIN Chunk; erneute Lieferung ERSETZT.
=========================================================================== ]]

World = {}

local floor  = math.floor
local sqrt   = math.sqrt

-- ── Zustand ────────────────────────────────────────────────────────────────

local byseg   = {}      -- [seg] = { [vkey] = block }
local segList = {}      -- [seg] = true (Verdraengung)
-- Fenstergrenzen von Keep. Nil = noch keine Vorgabe -> alles annehmen.
local winFrom, winTo = nil, nil
local lastDecoded = nil  -- zuletzt dekodiertes Segment (Diagnose)
local epoch   = 0
local segSec  = 30
local ready   = false

-- Rohe, noch nicht dekodierte Lieferungen. Expliziter Tail-Zeiger: '#' ist auf
-- einer Tabelle mit Loechern am Anfang nicht definiert.
local q, qHead, qTail = {}, 1, 0

local stat = { blocks = 0, samples = 0, chunks = 0, dropped = 0, decodeMs = 0.0 }

-- Kuerzester Chunk (Kopflaenge). Alles Kuerzere ist keiner.
local MIN_CHUNK = 14

-- Vorgaenger fuer den ersten Sample (immer Keyframe); ApplyStep liest nur.
local EMPTY = {}

-- ── Kleinkram ──────────────────────────────────────────────────────────────

local function toInt(v)
    if type(v) == 'number' then return math.tointeger(v) or floor(v) end
    if type(v) == 'string' then local n = tonumber(v); return n and (math.tointeger(n) or floor(n)) end
    return nil
end

local function segOf(t)
    local n = floor((tonumber(t) or 0) / segSec)
    return math.tointeger(n) or 0
end

--- Haltezeit nach dem letzten Sample. Bleibt der Heartbeat (spaetestens nach
--- Config.World.HeartbeatMs) aus, ist das Fahrzeug weg. Zuschlag deckt Rundung.
local function holdSeconds()
    local hb = (Config and Config.World and Config.World.HeartbeatMs) or 5000
    return (hb / 1000.0) * 1.5
end

-- ── Dekodierung ────────────────────────────────────────────────────────────

--- Chunk-Kopf an beliebiger Stelle. Eine Lieferung traegt mehrere Chunks
--- hintereinander (alle Fahrzeuge eines Segments in einem Paket).
local function readHeader(data, pos)
    local head = (pos == 1) and data or string.sub(data, pos, pos + 31)
    local hdr, hp = Protocol.DecodeChunkHeader(head)
    if type(hdr) ~= 'table' or type(hp) ~= 'number' then return nil end
    return hdr, pos + (hp - 1)
end

-- Rueckfalldeckel, falls Keep laenger ausbleibt. Fangt nur einen Fehler ab.
local MAX_SEGS = 64

local function newBlock(key)
    return {
        key = key, model = 0, n = 0, cur = 1,
        -- Fahrzeug/Fussgaenger (Flag IS_VEHICLE im ersten Sample), steuert die Wiedergabe.
        isVeh = true,
        -- Endmarker gesetzt (letzter Sample vehModel = 0): trennt "geloescht" von "steht still".
        gone = false,
        t = {}, x = {}, y = {}, z = {}, h = {},
        sp = {}, vp = {}, vr = {}, hp = {}, fl = {},
    }
end

--- Am Deckel Platz schaffen: das Segment mit groesstem Abstand zu keep weicht.
local function capSegments(keep)
    local n = 0
    for _ in pairs(byseg) do n = n + 1 end
    while n > MAX_SEGS do
        local worst, dist = nil, -1
        for seg in pairs(byseg) do
            local d = math.abs(seg - keep)
            if d > dist then worst, dist = seg, d end
        end
        if not worst or worst == keep then return end
        local blocks = byseg[worst]
        if blocks then
            for _ in pairs(blocks) do stat.blocks = stat.blocks - 1 end
        end
        byseg[worst]   = nil
        segList[worst] = nil
        stat.dropped   = stat.dropped + 1
        n = n - 1
    end
end

--- Eine Lieferung dekodieren. Rueckgabe: Anzahl uebernommener Chunks.
--- In pcall: beschaedigte Bytes werfen in string.unpack. Block wird erst am
--- Chunk-Ende eingehaengt (kein halb gefuellter in der Szene).
local function decode(seg, data)
    if type(data) ~= 'string' or #data < MIN_CHUNK then return 0 end

    local into = byseg[seg]
    if not into then
        into = {}; byseg[seg] = into; segList[seg] = true
        capSegments(seg)
        if not byseg[seg] then return 0 end   -- gerade selbst verdraengt
    end

    local taken = 0
    pcall(function()
        local len, pos = #data, 1
        while pos + 13 <= len do
            local hdr, hp = readHeader(data, pos)
            if not hdr then break end

            local key = hdr.playerHash & 0xFFFFFFFF
            local b   = newBlock(key)
            local t   = (hdr.startSec - epoch) + (hdr.startMs or 0) / 1000.0
            local prev, n = EMPTY, 0

            local T, X, Y, Z, H = b.t, b.x, b.y, b.z, b.h
            local SP, VP, VR, HP, FL = b.sp, b.vp, b.vr, b.hp, b.fl

            for _ = 1, hdr.nSamples do
                local s, np = Protocol.ApplyStep(data, hp, prev)
                hp = np
                t  = t + (s.dt or 0) / 1000.0
                n  = n + 1
                -- Modell aus dem ERSTEN Sample: der letzte kann Endmarker (0) sein.
                if n == 1 then
                    b.model = s.vehModel or 0
                    b.isVeh = ((s.flags or 0) & Protocol.FLAG.IS_VEHICLE) ~= 0
                end
                T[n]  = t
                X[n]  = s.x or 0.0
                Y[n]  = s.y or 0.0
                Z[n]  = s.z or 0.0
                H[n]  = s.heading or 0.0
                SP[n] = s.speed or 0.0
                VP[n] = s.vpitch or 0.0
                VR[n] = s.vroll or 0.0
                HP[n] = s.health or 0
                FL[n] = s.flags or 0
                prev  = s
            end

            if n > 0 then
                b.n = n
                -- Endmarker (letzter Sample vehModel = 0): Fahrzeug ist weg.
                if b.model ~= 0 and (prev.vehModel or 0) == 0 then
                    b.gone = true
                end
                if b.model == 0 then b.model = prev.vehModel or 0 end
                -- ERSETZEN, nicht anhaengen: ein Chunk je Segment/Fahrzeug.
                if into[key] then stat.blocks = stat.blocks - 1 end
                into[key] = b
                stat.blocks  = stat.blocks + 1
                stat.samples = stat.samples + n
                taken = taken + 1
            end

            if hp <= pos then break end     -- kein Fortschritt: Endlosschleife
            pos = hp
        end
    end)

    stat.chunks = stat.chunks + taken
    if taken > 0 then lastDecoded = seg end
    return taken
end

-- ── Aufnahme aus dem Netz ──────────────────────────────────────────────────

--- Weltspur aus einer Nachricht herausnehmen (aus Segments.OnData, im Handler).
--- Hier NICHT dekodieren, nur einreihen; Dekodieren macht Pump unter Budget.
--- Eintraege bleiben in d.items (Servernachricht nicht veraendern).
function World.Intake(d)
    if not ready or type(d) ~= 'table' or type(d.items) ~= 'table' then return end
    local seg = toInt(d.seg)
    if not seg then return end

    for i = 1, #d.items do
        local it = d.items[i]
        if type(it) == 'table' and it.kind == 'world'
           and type(it.data) == 'string' and #it.data >= MIN_CHUNK then
            qTail = qTail + 1
            q[qTail] = { seg = seg, data = it.data }
        end
    end
end

--- Dekodieren bis Budget aufgebraucht. Eigenes Budget, damit die Umgebung dem
--- Beweisstrom keine Zeit wegnimmt.
function World.Pump(budgetMs)
    if not ready or qHead > qTail then return end
    local t0 = GetGameTimer()
    local budget = tonumber(budgetMs) or 1.0

    repeat
        local e = q[qHead]
        if not e then break end
        q[qHead] = nil
        qHead = qHead + 1
        -- Keine Fensterpruefung hier: immer annehmen. Ein Segment zu lange zu
        -- halten raeumt Keep ab; faelschlich verworfenes Material ist endgueltig
        -- weg (kein erneutes Anfordern). Gegen Weglaufen sichert der Deckel in decode().
        decode(e.seg, e.data)
    until qHead > qTail or (GetGameTimer() - t0) >= budget

    stat.decodeMs = GetGameTimer() - t0

    if qHead > qTail then q, qHead, qTail = {}, 1, 0 end
end

-- ── Verdraengung ───────────────────────────────────────────────────────────

--- Alles ausserhalb [fromSeg, toSeg] freigeben. Folgt dem Fenster des
--- Spielerpfads, statt ein zweites zu fuehren.
function World.Keep(fromSeg, toSeg)
    if not ready then return end
    local a, b = toInt(fromSeg), toInt(toSeg)
    if not a or not b then return end
    winFrom, winTo = a, b
    for seg in pairs(byseg) do
        if seg < a or seg > b then
            local blocks = byseg[seg]
            if blocks then
                for _ in pairs(blocks) do stat.blocks = stat.blocks - 1 end
            end
            byseg[seg]   = nil
            segList[seg] = nil
        end
    end
end

-- ── Abtasten ───────────────────────────────────────────────────────────────

--- Index i mit t[i] <= tt < t[i+1]. Merker fuer den letzten Treffer, da die
--- Wiedergabe ueberwiegend vorwaerts laeuft.
local function locate(b, tt)
    local T, n = b.t, b.n
    if n == 0 then return nil end
    if tt < T[1] then return nil end
    if n == 1 then return 1 end

    local i = b.cur
    if i < 1 or i > n then i = 1 end
    if T[i] <= tt then
        while i < n and T[i + 1] <= tt do i = i + 1 end
    else
        while i > 1 and T[i] > tt do i = i - 1 end
    end
    b.cur = i
    return i
end

local function lerpAngle(a, c, f)
    local d = (c - a) % 360.0
    if d > 180.0 then d = d - 360.0 end
    return a + d * f
end

-- Wiederverwendete Ausgabeliste (spart ~1400 Objekte/s bei 24 Fahrzeugen, 60 fps).
local snap = {}
local snapN = 0

--- Zustand aller Fahrzeuge zum Zeitpunkt t, nach Abstand sortiert, auf maxN
--- begrenzt. Rueckgabe: Anzahl; Eintraege ueber World.Get(i) bis zum naechsten Aufruf.
function World.Snapshot(t, ox, oy, oz, maxN)
    snapN = 0
    if not ready then return 0 end

    local seg    = segOf(t)
    local blocks = byseg[seg]
    if not blocks then return 0 end

    local nextB = byseg[seg + 1]
    local hold  = holdSeconds()
    local cap   = toInt(maxN) or 24
    -- Deckel 0 ist gueltig ("Umgebung aus"); sonst griffe die Einsortierung auf snap[0].
    if cap < 1 then return 0 end

    for key, b in pairs(blocks) do
        local i = locate(b, t)
        if i then
            local T = b.t
            local x, y, z, h, sp, vp, vr, fl

            if i < b.n then
                local t0, t1 = T[i], T[i + 1]
                local f = (t1 > t0) and ((t - t0) / (t1 - t0)) or 0.0
                if f < 0.0 then f = 0.0 elseif f > 1.0 then f = 1.0 end
                x = b.x[i] + (b.x[i + 1] - b.x[i]) * f
                y = b.y[i] + (b.y[i + 1] - b.y[i]) * f
                z = b.z[i] + (b.z[i + 1] - b.z[i]) * f
                h = lerpAngle(b.h[i], b.h[i + 1], f)
                sp, vp, vr = b.sp[i], b.vp[i], b.vr[i]
            elseif not b.gone then
                -- Hinter dem letzten Sample ohne Endmarker: Zustand gilt weiter,
                -- solange der Herzschlag ihn deckt oder das Folgesegment denselben
                -- Schluessel fortsetzt (Fahrzeug stand nur still).
                local ok = (t - T[b.n]) <= hold
                if not ok and nextB and nextB[key] then ok = true end
                if ok then
                    x, y, z, h = b.x[b.n], b.y[b.n], b.z[b.n], b.h[b.n]
                    sp, vp, vr = b.sp[b.n], b.vp[b.n], b.vr[b.n]
                    fl = b.fl[b.n]
                end
            end

            if x then
                local dx, dy, dz = x - ox, y - oy, z - oz
                local d2 = dx * dx + dy * dy + dz * dz

                -- Einsortieren nach Abstand (billiger als Sammeln+Sortieren, allokiert nichts).
                if snapN < cap or (snapN > 0 and d2 < snap[snapN].d2) then
                    -- Umweg ueber `slot`: die Liste haelt Tabellen-REFERENZEN.
                    -- Direktes Beschreiben von snap[pos] beim Verschieben dupliziert
                    -- die Tabelle (zwei Autos an einer Stelle, eines fehlt).
                    local slot
                    if snapN < cap then
                        snapN = snapN + 1
                        slot = snap[snapN]
                        if type(slot) ~= 'table' then slot = {}; snap[snapN] = slot end
                    else
                        slot = snap[snapN]      -- das entfernteste faellt heraus
                    end

                    local pos = snapN
                    while pos > 1 and snap[pos - 1].d2 > d2 do
                        snap[pos] = snap[pos - 1]
                        pos = pos - 1
                    end
                    snap[pos] = slot

                    slot.key, slot.model, slot.d2 = key, b.model, d2
                    slot.isVeh = b.isVeh
                    slot.x, slot.y, slot.z, slot.h = x, y, z, h
                    slot.speed, slot.pitch, slot.roll = sp, vp, vr
                    slot.flags = fl or 0
                end
            end
        end
    end

    return snapN
end

function World.Get(i)
    if i < 1 or i > snapN then return nil end
    return snap[i]
end

-- ── Lebenszyklus ───────────────────────────────────────────────────────────

function World.Reset(ep, ss)
    byseg, segList = {}, {}
    winFrom, winTo = nil, nil
    q, qHead, qTail = {}, 1, 0
    epoch  = toInt(ep) or 0
    segSec = toInt(ss) or 30
    if segSec < 1 then segSec = 30 end
    ready  = true
    stat = { blocks = 0, samples = 0, chunks = 0, dropped = 0, decodeMs = 0.0 }
end

function World.Clear()
    byseg, segList = {}, {}
    winFrom, winTo = nil, nil
    q, qHead, qTail = {}, 1, 0
    snapN = 0
    ready = false
end

function World.Stats()
    local s = {}
    for k, v in pairs(stat) do s[k] = v end
    s.queued = qTail - qHead + 1
    s.ready  = ready
    s.winFrom, s.winTo = winFrom, winTo
    -- Welche Segmente im Speicher liegen und Bloecke je Segment (Diagnose).
    local segs, lo, hi = 0, nil, nil
    for seg, blocks in pairs(byseg) do
        segs = segs + 1
        if not lo or seg < lo then lo = seg end
        if not hi or seg > hi then hi = seg end
        local n = 0
        for _ in pairs(blocks) do n = n + 1 end
        if not s.sample or n > s.sample.n then s.sample = { seg = seg, n = n } end
    end
    s.segs, s.segLo, s.segHi = segs, lo, hi
    s.lastSeg = lastDecoded
    return s
end

return World
