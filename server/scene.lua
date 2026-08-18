--[[ D-RPS — server/scene.lua
     Eingang und Ablage der Szenenspur (was ein Client um sich sah). VERSUCHSSTAND,
     standardmaessig aus. Getrennt vom Beweispfad; Ablage nach Treuestrom-Muster
     (.scn neben .drps, unter dem ECHTEN Spieler-Pseudonym, kein abgeleiteter Hash,
     sonst kollidiert er mit einer Beweisdatei). Index ist ein SCAN je Tagesdatei.
     Client-gemeldete Daten: geprueft nur zum Schutz des Servers, nicht auf Wahrheit. ]]

Scene = {}

local RES      = GetCurrentResourceName()
local basePath
local floor    = math.floor

-- ── Grenzen ────────────────────────────────────────────────────────────────

local HDR          = 14          -- Protocol-Kopflaenge
local MAX_CHUNK    = 262144      -- ein einzelner Chunk
local SCAN_YIELD   = 64
local CACHE_MAX    = 24

-- Max. Abweichung der gemeldeten Startsekunde von jetzt; sonst schriebe ein
-- Client in fremde Tagesdateien.
local MAX_SKEW_SEC = 120

local function cfg(key, dflt)
    local s = Config and Config.Scene
    local v = s and s[key]
    if type(v) == 'number' or type(v) == 'boolean' then return v end
    return dflt
end

local function enabled()
    return cfg('Enabled', false) == true and cfg('Upload', false) == true
        and (Config and Config.DiskArchive) and true or false
end

local function base()
    if not basePath then
        basePath = GetResourcePath(RES):gsub('//+', '/') .. '/' .. (Config.ArchivePath or 'archive')
    end
    return basePath
end

local function sceneFile(hash, sec)
    return ('%s/%s_%08x.scn'):format(base(), os.date('%Y%m%d', sec), hash & 0xFFFFFFFF)
end

--- Fuer die Loeschfrist: archive.lua kennt die Endung nicht.
function Scene.FileOf(hash, sec) return sceneFile(hash, sec) end

-- ── Zahlen fuer die Diagnose ───────────────────────────────────────────────

local stat = {
    packets = 0, bytes = 0, chunks = 0,
    rejSize = 0, rejRate = 0, rejHeader = 0, rejSkew = 0,
}

-- [src] = { bytes, at, warned }
local quota = {}

-- ── Eingang ────────────────────────────────────────────────────────────────

--- Einen Chunk pruefen (nur Format/Groesse/Zeitlage, nicht Inhalt).
--- Rueckgabe: hdr + Folgeposition, oder nil samt Grund.
local function checkChunk(data, pos)
    local hdr, np = nil, nil
    local ok = pcall(function()
        local head = (pos == 1) and data or string.sub(data, pos, pos + 31)
        hdr, np = Protocol.DecodeChunkHeader(head)
    end)
    if not ok or type(hdr) ~= 'table' or type(np) ~= 'number' then
        return nil, 'kopf'
    end
    if (hdr.nSamples or 0) < 1 or (hdr.nSamples or 0) > 65535 then
        return nil, 'kopf'
    end

    local now = os.time()
    local s   = hdr.startSec or 0
    if s < (now - MAX_SKEW_SEC) or s > (now + MAX_SKEW_SEC) then
        return nil, 'zeit'
    end
    return hdr, pos + (np - 1)
end

RegisterNetEvent('d-rps:scene', function(payload)
    local src = source
    if not enabled() then return end
    if type(payload) ~= 'string' then return end

    -- Groesse begrenzen: ein Upload traegt hoechstens einen Beutel Chunks.
    local maxBatch = floor(cfg('MaxBatchBytes', 16384)) * 8
    if #payload < HDR or #payload > maxBatch then
        stat.rejSize = stat.rejSize + 1
        return
    end

    -- Rate in Byte je Minute (nicht Pakete, sonst per groesserem Paket umgehbar).
    local q = quota[src]
    local now = GetGameTimer()
    if not q then q = { bytes = 0, at = now }; quota[src] = q end
    if (now - q.at) >= 60000 then q.bytes, q.at = 0, now end
    local perMin = floor(cfg('MaxBytesPerMinute', 262144))
    if (q.bytes + #payload) > perMin then
        stat.rejRate = stat.rejRate + 1
        return
    end
    q.bytes = q.bytes + #payload

    local hash = RPSPlayerHash(src)
    if not hash then return end

    stat.packets = stat.packets + 1
    stat.bytes   = stat.bytes + #payload

    -- Paket in Chunks zerlegen, jeden einzeln pruefen/ablegen; ein defekter
    -- Chunk entwertet die davor nicht.
    local pos, n = 1, #payload
    local guard = 0
    while pos + HDR - 1 <= n do
        guard = guard + 1
        if guard > 4096 then break end

        local hdr, nextPos = checkChunk(payload, pos)
        if not hdr then
            if nextPos == 'zeit' then stat.rejSkew = stat.rejSkew + 1
            else stat.rejHeader = stat.rejHeader + 1 end
            break
        end

        -- Chunklaenge in Byte: der Kopf nennt nur die Sample-Zahl, also dekodieren.
        local endPos
        local okD = pcall(function()
            local p, prev = nextPos, nil
            for _ = 1, hdr.nSamples do
                local s, np = Protocol.ApplyStep(payload, p, prev or {})
                prev, p = s, np
            end
            endPos = p
        end)
        if not okD or not endPos or endPos <= pos or endPos > n + 1 then
            stat.rejHeader = stat.rejHeader + 1
            break
        end

        local chunk = string.sub(payload, pos, endPos - 1)
        if #chunk >= HDR and #chunk <= MAX_CHUNK then
            local f = io.open(sceneFile(hash, hdr.startSec), 'ab')
            if f then
                f:write(string.pack('<I4', #chunk))
                f:write(chunk)
                f:close()
                stat.chunks = stat.chunks + 1
            end
        end
        pos = endPos
    end
end)

AddEventHandler('playerDropped', function()
    quota[source] = nil
end)

-- ── Index: Scan je Tagesdatei ──────────────────────────────────────────────

local cache, cacheN = {}, 0

local function evict()
    if cacheN <= CACHE_MAX then return end
    local oldKey, oldTouch
    for k, c in pairs(cache) do
        if not c.scanning then
            local t = c.touch or 0
            if not oldTouch or t < oldTouch then oldKey, oldTouch = k, t end
        end
    end
    if oldKey then cache[oldKey] = nil; cacheN = cacheN - 1 end
end

local touchSeq = 0

--- Einen Tag scannen, fortsetzend (der laufende Tag waechst im Betrieb).
local function dayOf(hash, sec)
    hash = hash & 0xFFFFFFFF
    local key = ('%s:%08x'):format(os.date('%Y%m%d', sec), hash)
    local c = cache[key]
    if not c then
        c = { bySeg = {}, off = 0, scanning = false }
        cache[key] = c; cacheN = cacheN + 1
        evict()
    end
    touchSeq = touchSeq + 1
    c.touch = touchSeq

    if c.scanning then return c end
    c.scanning = true

    pcall(function()
        local f = io.open(sceneFile(hash, sec), 'rb')
        if not f then return end
        local size = f:seek('end') or 0
        local off, n = c.off, 0
        local fresh = {}

        while off + 4 <= size do
            if not f:seek('set', off) then break end
            local pre = f:read(4)
            if not pre or #pre < 4 then break end
            local len = string.unpack('<I4', pre)
            if len < HDR or len > MAX_CHUNK or (off + 4 + len) > size then break end

            local head = f:read(HDR)
            if not head or #head < HDR then break end
            local hdr = Protocol.DecodeChunkHeader(head)
            if hdr then
                fresh[#fresh + 1] = { seg = Session.SegOf(hdr.startSec),
                                      e = { startSec = hdr.startSec, off = off, len = len } }
            end

            off = off + 4 + len
            n = n + 1
            if n % SCAN_YIELD == 0 then Wait(0) end
        end
        f:close()

        -- Erst am Ende einhaengen: die Schleife gibt ab, ein Leser saehe sonst
        -- ein halb gefuelltes Band.
        for i = 1, #fresh do
            local r = fresh[i]
            local L = c.bySeg[r.seg]
            if not L then L = {}; c.bySeg[r.seg] = L end
            L[#L + 1] = r.e
        end
        c.off = off
    end)

    c.scanning = false
    return c
end

--- Alle Eintraege eines Segments. Gegenstueck zu SegIndex.Get.
function Scene.Entries(hash, seg)
    if not enabled() then return {} end
    local first = Session.SecOf(seg)
    local last  = first + Session.SegSeconds() - 1

    local out, seen = {}, {}
    for _, t in ipairs({ first, last }) do
        local c = dayOf(hash, t)
        for _, e in ipairs(c.bySeg[seg] or {}) do
            local k = e.off
            if not seen[k] then seen[k] = true; out[#out + 1] = e end
        end
    end
    table.sort(out, function(x, y) return x.startSec < y.startSec end)
    return out
end

--- Einen Chunk lesen. Laengenpraefix MUSS zum gemerkten len passen, sonst hat
--- sich die Datei unter dem Scan veraendert -> nichts liefern.
function Scene.Read(hash, e)
    local f = io.open(sceneFile(hash & 0xFFFFFFFF, e.startSec), 'rb')
    if not f then return nil end
    if not f:seek('set', e.off) then f:close(); return nil end
    local pre = f:read(4)
    if not pre or #pre < 4 or string.unpack('<I4', pre) ~= e.len then f:close(); return nil end
    local data = f:read(e.len)
    f:close()
    if type(data) ~= 'string' or #data ~= e.len then return nil end
    return data
end

function Scene.Stats()
    local s = {}
    for k, v in pairs(stat) do s[k] = v end
    s.enabled = enabled()
    local days = 0
    for _ in pairs(cache) do days = days + 1 end
    s.days = days
    return s
end

return Scene
