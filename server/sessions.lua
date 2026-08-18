--[[ ===========================================================================
    D-RPS — server/sessions.lua
    Sitzungs-Index: wer war wann online? Liefert auch ausgeloggte Spieler (fuer
    Combat-Log) und die playerHashes vergangener Tage (fuer Archive.Purge).

    Format: eine JSON-Zeile je Ereignis, angehaengt an archive/idx_YYYYMMDD.jsonl
    (crash-tolerant, kein Neuschreiben wie bei tickets.json).
    Datenschutz: nur playerHash (= GetHashKey(license)) und Anzeigename, nie die
    license; fuer Art.-17-Loeschung wird der Hash aus der license neu gerechnet.
=========================================================================== ]]

SessionIndex = {}

local RES      = GetCurrentResourceName()
local basePath                    -- absoluter Pfad zu …/archive
local ready    = false
local bootId   = 0

local HEARTBEAT_SEC = 30          -- Takt der hb-Zeilen
local STALE_SEC     = 120         -- ohne hb laenger als das = Sitzung tot

local live      = {}              -- [src] = { hash, name, since }
local dayCache  = {}              -- [dayKey] = Liste gefalteter Sitzungen
local hashName  = {}              -- [hash]  = zuletzt gesehener Name
local forgotten = {}              -- [hash]  = true (Art.-17-Grabstein)

local function idxFile(sec)
    return ('%s/idx_%s.jsonl'):format(basePath, os.date('%Y%m%d', sec))
end

--- Pseudonym eines Spielers. Einzige Stelle im System, die das rechnet.
function RPSPlayerHash(src)
    local lic = GetPlayerIdentifierByType(src, 'license') or ('src:' .. tostring(src))
    return GetHashKey(lic) & 0xFFFFFFFF
end

--- Hash aus einem Identifier, ohne dass der Spieler online sein muss.
function RPSHashOfIdentifier(id)
    return GetHashKey(tostring(id)) & 0xFFFFFFFF
end

-- ── Schreiben ──────────────────────────────────────────────────────────────

local function append(sec, obj)
    if not ready then return false end
    local ok, line = pcall(json.encode, obj)
    if not ok or type(line) ~= 'string' then return false end
    local f = io.open(idxFile(sec), 'ab')
    if not f then return false end
    f:write(line); f:write('\n'); f:close()
    dayCache[os.date('%Y%m%d', sec)] = nil     -- gefaltete Sicht veraltet
    return true
end

-- ── Lesen ──────────────────────────────────────────────────────────────────

--- Eine Tagesdatei zu Sitzungsintervallen falten.
--- Rueckgabe: { { hash, name, from, to, open, reason }, … }
local function foldDay(dayKey, sec)
    local cached = dayCache[dayKey]
    if cached then return cached end

    local out, openRun = {}, {}
    local f = io.open(idxFile(sec), 'rb')
    if f then
        local data = f:read('*a'); f:close()
        local lastHb = {}
        for line in data:gmatch('[^\n]+') do
            local ok, e = pcall(json.decode, line)
            if ok and type(e) == 'table' and e.e then
                if e.e == 'join' and e.h then
                    -- Offene Sitzung desselben Hashes zuerst schliessen (Reconnect
                    -- ohne sauberes leave).
                    local run = openRun[e.h]
                    if run then run.to = lastHb[e.h] or run.to; run.open = false; run.reason = 'crash' end
                    run = { hash = e.h, name = e.n, from = e.t, to = e.t, open = true }
                    openRun[e.h] = run
                    out[#out + 1] = run
                    if e.n then hashName[e.h] = e.n end

                elseif e.e == 'hb' and type(e.h) == 'table' then
                    for _, h in ipairs(e.h) do
                        lastHb[h] = e.t
                        local run = openRun[h]
                        if run then run.to = e.t end
                    end

                elseif e.e == 'leave' and e.h then
                    local run = openRun[e.h]
                    if run then
                        run.to = e.t; run.open = false; run.reason = e.r
                        openRun[e.h] = nil
                    end

                elseif e.e == 'boot' then
                    -- Server startete neu: alles noch Offene endet hier.
                    for h, run in pairs(openRun) do
                        run.to = lastHb[h] or run.to
                        run.open = false
                        run.reason = 'crash'
                    end
                    openRun = {}

                elseif e.e == 'forget' and e.h then
                    forgotten[e.h] = true
                end
            end
        end

        -- Ohne leave/boot, aber letzter Herzschlag zu lange her: als abgestuerzt
        -- schliessen.
        local now = os.time()
        for h, run in pairs(openRun) do
            if (now - (lastHb[h] or run.to)) > STALE_SEC then
                run.to = lastHb[h] or run.to
                run.open = false
                run.reason = 'crash'
            end
        end
    end

    -- Nur abgeschlossene Tage cachen — der laufende Tag waechst weiter.
    if dayKey ~= os.date('%Y%m%d') then dayCache[dayKey] = out end
    return out
end

-- ── API ────────────────────────────────────────────────────────────────────

function SessionIndex.Init()
    if not Config.DiskArchive then return false end
    basePath = GetResourcePath(RES):gsub('//+', '/') .. '/' .. Config.ArchivePath

    local f = io.open(idxFile(os.time()), 'ab')
    if not f then
        print('^3[D-RPS] Sitzungs-Index nicht schreibbar — ausgeloggte Spieler fehlen im Replay.^0')
        return false
    end
    f:close()
    ready = true

    bootId = os.time()
    append(bootId, { e = 'boot', t = bootId, b = bootId })
    return true
end

--- Spieler betritt die Aufzeichnung. Idempotent.
function SessionIndex.Note(src)
    if not ready or live[src] then return end
    local h = RPSPlayerHash(src)
    local n = GetPlayerName(src) or ('Spieler ' .. src)
    live[src] = { hash = h, name = n, since = os.time() }
    hashName[h] = n
    append(os.time(), { e = 'join', t = os.time(), h = h, n = n, b = bootId })
end

--- Spieler verlaesst die Aufzeichnung.
function SessionIndex.Close(src, reason)
    local s = live[src]
    if not s then return end
    live[src] = nil
    append(os.time(), { e = 'leave', t = os.time(), h = s.hash, r = reason or 'drop' })
end

--- Alle Sitzungen, die das Fenster [fromSec, toSec] beruehren, auch offline.
function SessionIndex.Query(fromSec, toSec)
    local byHash = {}

    if ready then
        for t = fromSec - 86400, toSec + 86400, 86400 do
            local dayKey = os.date('%Y%m%d', t)
            for _, run in ipairs(foldDay(dayKey, t)) do
                if not forgotten[run.hash] and run.to >= fromSec and run.from <= toSec then
                    local e = byHash[run.hash]
                    if not e then
                        e = { hash = run.hash, name = run.name or hashName[run.hash],
                              spans = {}, online = false }
                        byHash[run.hash] = e
                    end
                    e.spans[#e.spans + 1] = {
                        from = math.max(run.from, fromSec),
                        to   = math.min(run.to, toSec),
                    }
                    if run.name then e.name = run.name end
                end
            end
            if t > toSec then break end
        end
    end

    -- Laufende Sitzungen dazumischen (ihr Ende steht noch nicht in der Datei).
    local now = os.time()
    for src, s in pairs(live) do
        if not forgotten[s.hash] and s.since <= toSec and now >= fromSec then
            local e = byHash[s.hash]
            if not e then
                e = { hash = s.hash, name = s.name, spans = {} }
                byHash[s.hash] = e
            end
            e.name   = s.name
            e.online = true
            e.src    = src
            e.spans[#e.spans + 1] = {
                from = math.max(s.since, fromSec),
                to   = math.min(now, toSec),
            }
        end
    end

    -- Ueberlappende/angrenzende Abschnitte zusammenfassen (keine Schnipsel in der UI).
    local out = {}
    for _, e in pairs(byHash) do
        table.sort(e.spans, function(a, b) return a.from < b.from end)
        local merged = {}
        for _, sp in ipairs(e.spans) do
            local last = merged[#merged]
            if last and sp.from <= last.to + HEARTBEAT_SEC * 2 then
                if sp.to > last.to then last.to = sp.to end
            else
                merged[#merged + 1] = { from = sp.from, to = sp.to }
            end
        end
        e.spans = merged
        e.from  = merged[1] and merged[1].from or fromSec
        e.to    = merged[#merged] and merged[#merged].to or fromSec
        out[#out + 1] = e
    end
    table.sort(out, function(a, b) return a.from < b.from end)
    return out
end

--- playerHashes der letzten N Tage (Grundlage fuer Archive.Purge), auch von
--- laengst offline gegangenen Spielern.
function SessionIndex.KnownHashes(days)
    local set = {}
    for _, s in pairs(live) do set[s.hash] = true end
    if not ready then return set end

    local n = math.max(1, days or (Config.RetentionDays + 95))
    for d = 0, n do
        local sec = os.time() - (d * 86400)
        local dayKey = os.date('%Y%m%d', sec)
        for _, run in ipairs(foldDay(dayKey, sec)) do set[run.hash] = true end
    end
    return set
end

--- Anzeigename zu einem Hash, soweit bekannt.
function SessionIndex.NameOf(hash)
    return hashName[hash]
end

--- Loeschverlangen nach Art. 17: Grabstein setzen (Index ist append-only) und
--- die Archivdateien des Pseudonyms entfernen.
function SessionIndex.Forget(hash)
    hash = hash & 0xFFFFFFFF
    forgotten[hash] = true
    hashName[hash]  = nil
    dayCache = {}
    append(os.time(), { e = 'forget', t = os.time(), h = hash })
    return Archive.PurgeHash(hash)
end

-- ── Herzschlag ─────────────────────────────────────────────────────────────
-- Eine Zeile fuer alle Online-Spieler, nicht je Spieler eine.

CreateThread(function()
    while true do
        Wait(HEARTBEAT_SEC * 1000)
        if ready then
            local hs = {}
            for _, s in pairs(live) do hs[#hs + 1] = s.hash end
            if #hs > 0 then append(os.time(), { e = 'hb', t = os.time(), h = hs }) end
        end
    end
end)

return SessionIndex
