--[[ D-RPS — server/stream.lua
     Segment-Streaming an den Admin-Client (Vertrag v3): je Admin eine Sitzung,
     zuerst ein Manifest (Zeitachse/Roster/Belegung), Nutzdaten erst auf Abruf.

     Invarianten:
     - Chunk gehoert zu GENAU EINEM Segment: dem, in dem er beginnt (Recorder
       schneidet auf der Segmentgrenze). Keine Spanne wieder einbauen.
     - Belegung (barsFor) und Auslieferung (rowsFor) fragen dieselbe Stelle
       unter derselben Segmentnummer; EINE Funktion (fidUseRam) entscheidet den
       Fidelity-RAM-Rueckfall fuer beide.
     - Kein Uebertragungszustand: Einheit ist der einzelne Chunk; jede Nachricht
       traegt vollstaendige Chunks, zwischen Nachrichten wird nichts gehalten.
     - sent ist die Wahrheit: die Abschlussnachricht meldet die WIRKLICH
       gesendeten Chunks (sent/missing/capped); der Client leitet nichts her.
     - Jede Nachricht (auch jede Ablehnung) reicht rid unveraendert zurueck.
     - Auf jede Anfrage genau eine Abschlussnachricht (done=true), sonst denied.
     - Offener Recorder-Chunk geht als 'evopen' (waechst, darf nicht entdoppelt
       werden), nie als 'ev'.
     - Fidelity hat keinen Index -> eigener kleiner .fid-Scan (nur Praefix+Kopf).
     - Zeitbasis os.time() (Wanduhr); GetGameTimer() nur fuer Differenzen, nie
       mit Wanduhrzeit verrechnen. ]]

Stream = {}

local RES = GetCurrentResourceName()
local basePath                       -- absoluter Pfad zu …/archive

-- Rueckfallmodell ohne Aussehen/lebenden Ped. Ueber GetHashKey statt Backtick,
-- damit luac-pruefbar.
local FREEMODE = GetHashKey('mp_m_freemode_01')

local FID_HDR = 14                   -- Kopflaenge eines Fidelity-Chunks

-- Obergrenze plausibler Chunk-Laenge in der .fid; ein beschaedigtes Praefix
-- darf den Scan nicht mit einem Zufallswert weiterspringen lassen.
local MAX_FID_BYTES = 1024 * 1024

local FID_SCAN_YIELD = 400           -- Chunks je Zeitscheibe beim .fid-Scan

-- Gleichzeitig vorgehaltene .fid-Tagesscans. Muss >= voller Roster sein, sonst
-- verdraengt jeder neue Scan einen aelteren und beginnt fuer ihn wieder bei 0.
local FID_CACHE_MAX  = 96
local FID_IDLE       = 600           -- Sekunden ohne Zugriff, dann verfaellt er
local FID_SCAN_WAIT_MS = 1000        -- Geduld, wenn ein anderer Thread scannt

-- Notloesung fuer einen scanning-Merker ohne Thread (Resource-Stop mitten im
-- Scan); sonst bleibt der Tag bis zum Neustart blockiert.
local FID_SCAN_STUCK = 120

-- Deckel fuer Segmente je Manifest (SegIndex.Bars kuerzt selbst bei 4096).
local MAX_SEGMENTS = 4096

-- Gesamtbudget aller bars-Strings eines Manifests; das Manifest muss mit
-- Roster, Meldungen und Aussehen in EIN Netz-Ereignis passen.
local BARS_BUDGET = 160000

local MAX_INFLIGHT   = 4             -- gleichzeitig angenommene Anfragen je Sitzung

-- Wartezeiten: beide zusammen MUESSEN unter dem Client-Timeout (20000) bleiben,
-- sonst arbeitet der Server an einer laengst verworfenen Anfrage.
local TOKEN_WAIT_MS  = 5000          -- Warten auf das Token
local BUSY_WAIT_MS   = 10000         -- Warten auf die vorherige Auslieferung

local SESSION_IDLE   = 1800          -- Sekunden ohne Anfrage, dann wird aufgeraeumt
local ENSURE_WAIT_MS = 8000          -- Geduld beim einmaligen Index-Wiederaufbau
local MAX_ENSURE     = 64            -- Tagesindizes je Manifest, mehr waere Vollscan

-- Zuschlag je Eintrag auf das Nachrichten-Byte-Budget (kind, hash, start,
-- Tabellenrahmen kosten auch bei kleinem data).
local ITEM_OVERHEAD = 64

local ROWS_YIELD = 8                 -- Spieler je Zeitscheibe beim Zusammenstellen

-- ── Zahlwandlung ───────────────────────────────────────────────────────────

--- Verlaesslich zu Integer-Subtyp wandeln (Lua 5.4: math.floor bleibt Float,
--- '&' und '%d' werfen darauf). Unwandelbares wird abgewiesen, nicht geraten.
local function toInt(v)
    local n = tonumber(v)
    if not n then return nil end
    if n ~= n then return nil end
    if n == math.huge or n == -math.huge then return nil end
    return math.tointeger(n) or math.tointeger(math.floor(n))
end

--- Config-Wert als ganze Zahl in festen Grenzen. Config ist buyer-editierbar;
--- Text oder 0 darf keine spaetere Byterechnung sprengen.
local function cfgInt(v, dflt, lo, hi)
    local n = toInt(v) or dflt
    if n < lo then n = lo end
    if n > hi then n = hi end
    return n
end

local function maxBytes()   return cfgInt(Config and Config.SegmentMaxBytes,      262144, 16384, 4194304) end
local function ratePerSec() return cfgInt(Config and Config.SegmentRatePerSec,         8,     1,      60) end
local function windowMins() return cfgInt(Config and Config.SegmentWindowMinutes,     30,     1,    1440) end
local function ramMins()    return cfgInt(Config and Config.RamBufferMinutes,          5,     1,     240) end

-- SPIELER-Deckel je Segment (nicht Nachrichtengroesse). Greift er, traegt die
-- Nachricht capped=true — verschwiegen wird nichts.
local function maxActors()  return cfgInt(Config and Config.SegmentMaxActors,         12,     1,      64) end

-- Eimer darf sich fuellen, solange niemand fragt: ein Zeitleisten-Sprung
-- fordert mehrere Segmente unmittelbar hintereinander.
local function burst() return math.max(2, ratePerSec() * 2) end

local function segSeconds() return Session.SegSeconds() end

-- ── Zuordnung eines Chunks ─────────────────────────────────────────────────

--- Chunk in einer Praesenztabelle vermerken: belegt genau das Segment, in dem
--- er beginnt (kein zweites). Ausserhalb des Bandes faellt weg.
local function mark(pres, startSec, fromSeg, toSeg)
    local s = Session.SegOf(startSec)
    if s >= fromSeg and s <= toSeg then pres[s] = true end
end

--- Aeltestes Segment, das noch im RAM-Ring liegen kann.
local function ramFloorSeg()
    local w = segSeconds()
    return Session.NowSeg() - (((ramMins() * 60) + w - 1) // w) - 1
end

-- ── Fidelity-Index ─────────────────────────────────────────────────────────
-- .fid-Namensregel gehoert archive.lua (dort lokal), hier gespiegelt: jede
-- Aenderung dort muss hier nachgezogen werden.

local function ensureBase()
    if not basePath then
        basePath = GetResourcePath(RES):gsub('//+', '/') .. '/' .. (Config.ArchivePath or 'archive')
    end
    return basePath
end

local function fidFile(hash, sec)
    return ('%s/%s_%08x.fid'):format(ensureBase(), os.date('%Y%m%d', sec), hash & 0xFFFFFFFF)
end

local fidCache, fidCacheN, fidTouch = {}, 0, 0

local function fidEvict()
    if fidCacheN <= FID_CACHE_MAX then return end
    local oldKey, oldTouch
    for k, c in pairs(fidCache) do
        -- Gerade gescannte Eintraege nicht verdraengen: sonst schreibt der Scan
        -- in eine verwaiste Tabelle und der naechste Leser beginnt bei Byte 0.
        if not c.scanning then
            local t = c.touch or 0
            if not oldTouch or t < oldTouch then oldKey, oldTouch = k, t end
        end
    end
    if oldKey then fidCache[oldKey] = nil; fidCacheN = fidCacheN - 1 end
end

--- Der Durchlauf durch eine .fid. Ausgelagert, damit fidDay ihn in pcall
--- fassen kann (Schleife gibt ab, offener Handle).
--- Rueckgabe: frische Eintraege, neue Byteposition, ob abgebrochen wurde.
local function fidScan(f, from, size)
    local fresh, off, n, broke = {}, from, 0, false
    while off + 4 <= size do
        if not f:seek('set', off) then broke = true; break end
        local pre = f:read(4)
        if not pre or #pre < 4 then broke = true; break end
        local len = string.unpack('<I4', pre)
        -- Unplausibel/abgeschnitten: Rest nicht vertrauenswuerdig. Sicheres
        -- behalten, beim naechsten Mal an derselben Stelle erneut versuchen.
        if len < FID_HDR or len > MAX_FID_BYTES or (off + 4 + len) > size then
            broke = true; break
        end

        local head = f:read(FID_HDR)
        if not head or #head < FID_HDR then broke = true; break end
        local hdr = Fidelity.DecodeChunkHeader(head)
        if hdr then
            fresh[#fresh + 1] = { seg = Session.SegOf(hdr.startSec),
                                  e = { startSec = hdr.startSec, off = off, len = len } }
        end

        off = off + 4 + len
        n   = n + 1
        if n % FID_SCAN_YIELD == 0 then Wait(0) end
    end
    return fresh, off, broke
end

--- Einen Tag der .fid-Datei auf Segmente abbilden. Je Chunk nur 4+14 Byte, ab
--- der zuletzt gescannten Byteposition fortgesetzt (laufender Tag waechst).
--- Aufrufer MUSS in eigenem Thread laufen (Schleife gibt ab). In eine LOKALE
--- Liste gebaut und erst am Ende eingehaengt, sonst saehe ein Leser in der
--- Abgabeluecke ein halb gefuelltes Band.
local function fidDay(hash, sec)
    hash = hash & 0xFFFFFFFF
    local dayKey = os.date('%Y%m%d', sec)
    local key    = ('%s:%08x'):format(dayKey, hash)
    local grid   = segSeconds()

    local c = fidCache[key]
    -- Rasterbreite ist nach Session.Init eingefroren; ein abweichender Wert
    -- stammt aus einem frueheren Lauf und ordnete Segmentnummern falsch zu.
    if c and c.grid ~= grid then fidCache[key] = nil; fidCacheN = fidCacheN - 1; c = nil end

    if not c then
        c = { bySeg = {}, bytes = 0, grid = grid, dayKey = dayKey,
              path = fidFile(hash, sec), lastCheck = 0 }
        fidCache[key] = c
        fidCacheN = fidCacheN + 1
        fidTouch  = fidTouch + 1
        c.touch   = fidTouch          -- vor fidEvict setzen, sonst trifft die
        fidEvict()                    -- Verdraengung den frischen Eintrag
    end
    fidTouch = fidTouch + 1
    c.touch  = fidTouch
    c.used   = os.time()

    -- Anderer Thread scannt denselben Tag: kurz warten, dann nehmen was steht
    -- (ein zweiter Scan liefert dasselbe).
    if c.scanning then
        local t0 = GetGameTimer()
        while c.scanning and (GetGameTimer() - t0) < FID_SCAN_WAIT_MS do Wait(10) end
        return c
    end

    if c.final then return c end
    local now = os.time()
    if c.lastCheck == now then return c end     -- hoechstens einmal je Sekunde
    c.lastCheck = now
    local dayOver = (c.dayKey ~= os.date('%Y%m%d', now))

    local f = io.open(c.path, 'rb')
    if not f then
        if dayOver then c.final = true end
        return c
    end
    local size = f:seek('end') or 0
    if size <= c.bytes then
        f:close()
        if dayOver then c.final = true end
        return c
    end

    c.scanning  = true
    c.scanStart = os.time()
    local ok, fresh, off, broke = pcall(fidScan, f, c.bytes, size)
    -- Handle IMMER schliessen, auch nach Abbruch (sonst erschoepfte Dateizeiger).
    pcall(function() f:close() end)
    c.scanning  = nil
    c.scanStart = nil

    if not ok then
        print(('^1[D-RPS] .fid-Scan abgebrochen (%s): %s^0'):format(c.path, tostring(fresh)))
        return c
    end

    -- Erst jetzt einhaengen, samt neuem Byte-Stand (Speichersicht bleibt bis
    -- hier konsistent, nur aelter).
    for i = 1, #fresh do
        local r = fresh[i]
        local l = c.bySeg[r.seg]
        if not l then l = {}; c.bySeg[r.seg] = l end
        l[#l + 1] = r.e
    end
    c.bytes = off
    -- Abgebrochener Scan darf den Tag nicht abschliessen (Rest bliebe unsichtbar).
    if dayOver and not broke then c.final = true end
    return c
end

--- Einen einzelnen Fidelity-Chunk lesen (Gegenstueck zu SegIndex.ReadChunk).
--- Praefix an der gemerkten Stelle MUSS zum gemerkten len passen, sonst hat
--- sich die Datei unter dem Scan veraendert und es wird nichts geliefert.
local function fidRead(hash, e)
    local f = io.open(fidFile(hash, e.startSec), 'rb')
    if not f then return nil end
    if not f:seek('set', e.off) then f:close(); return nil end
    local pre = f:read(4)
    if not pre or #pre < 4 or string.unpack('<I4', pre) ~= e.len then f:close(); return nil end
    local data = f:read(e.len)
    f:close()
    if type(data) ~= 'string' or #data ~= e.len then return nil end
    return data
end

--- Alle .fid-Tagesscans, die einen Sekundenbereich beruehren.
local function fidDaysForSecs(hash, fromSec, toSec)
    if toSec < fromSec then toSec = fromSec end
    local days, seen = {}, {}
    for t = fromSec, toSec, 86400 do
        local k = os.date('%Y%m%d', t)
        if not seen[k] then seen[k] = true; days[#days + 1] = fidDay(hash, t) end
    end
    local kLast = os.date('%Y%m%d', toSec)
    if not seen[kLast] then seen[kLast] = true; days[#days + 1] = fidDay(hash, toSec) end
    return days
end

--- Fidelity-Chunks aus dem RAM-Ring des Reporters. Ohne Disk-Archiv und fuer
--- die juengsten Sekunden die einzige Fidelity-Quelle.
--- Achtung: GetFidelityChunksByHash zieht bei Disk-Archiv die .fid am Stueck;
--- der Aufrufer fragt deshalb vorher fidUseRam.
local function fidRamChunks(hash, live, fromSec, toSec)
    local out = {}
    if not live then return out end
    if type(GetFidelityChunksByHash) ~= 'function' then return out end
    if not (Fidelity and Fidelity.DecodeChunkHeader) then return out end

    local ok, list = pcall(GetFidelityChunksByHash, hash, live, fromSec, toSec)
    if not ok or type(list) ~= 'table' then return out end

    for i = 1, #list do
        local data = list[i]
        if type(data) == 'string' and #data >= FID_HDR then
            local hdr = Fidelity.DecodeChunkHeader(data)
            if hdr and hdr.startSec then
                out[#out + 1] = { startSec = hdr.startSec, data = data }
            end
        end
    end
    return out
end

--- Kennt der Offset-Scan im RAM-Fenster ueberhaupt Fidelity fuer diesen
--- Spieler? Fenster bewusst [RAM-Boden .. jetzt], damit Belegung und
--- Auslieferung dieselbe Antwort bekommen.
local function fidDiskHitsInRam(hash)
    local lo = ramFloorSeg()
    if lo < 0 then lo = 0 end
    local hi = Session.NowSeg()
    if hi < lo then return 0 end

    local first = Session.SecOf(lo)
    local last  = Session.SecOf(hi) + segSeconds() - 1
    local n = 0
    -- Direkter Bereichszugriff statt pairs ueber den ganzen Tagesindex: gefragt
    -- ist nur das RAM-Fenster (Minuten), nicht der ganze Tag.
    for _, c in ipairs(fidDaysForSecs(hash, first, last)) do
        for s = lo, hi do
            local list = c.bySeg[s]
            if list then n = n + #list end
        end
    end
    return n
end

--- GEMEINSAME Regel fuer den Fidelity-RAM-Rueckfall (Belegung und Auslieferung
--- muessen sie identisch nutzen, sonst versprechen/liefern sie Verschiedenes).
local function fidUseRam(hash, live, toSeg)
    if not live then return false end
    if toSeg < ramFloorSeg() then return false end
    if not Config.DiskArchive then return true end
    return fidDiskHitsInRam(hash) == 0
end

--- Fidelity-Eintraege eines Segments: die Chunks, die hier BEGINNEN (bereits
--- unter SegOf(startSec) abgelegt, nur nachgeschlagen).
--- Rueckgabe: Liste und die Menge der schon vergebenen Startsekunden.
local function fidEntries(hash, seg)
    local first = Session.SecOf(seg)
    local last  = first + segSeconds() - 1

    local out, seen = {}, {}
    for _, c in ipairs(fidDaysForSecs(hash, first, last)) do
        for _, e in ipairs(c.bySeg[seg] or {}) do
            if not seen[e.startSec] then
                seen[e.startSec] = true
                out[#out + 1] = e
            end
        end
    end
    table.sort(out, function(x, y) return x.startSec < y.startSec end)
    return out, seen
end

-- ── Sitzungen ──────────────────────────────────────────────────────────────

local sessions = {}       -- [src] = Streaming-Sitzung eines Admins
local building = {}       -- [src] = true, solange ein Manifest gebaut wird
local closeSeq = {}       -- [src] = Zaehler, steigt bei jedem Close

--- Server-ID eines Spielers, aber nur wenn sie noch DENSELBEN Spieler meint
--- (IDs werden nach Disconnect neu vergeben; sonst liefert der Ring unter dem
--- Pseudonym des Gesuchten die Aufzeichnung eines fremden Spielers aus).
local function liveSrcOf(p)
    if not p.id then return nil end
    if not GetPlayerName(p.id) then return nil end
    if RPSPlayerHash(p.id) ~= p.hash then return nil end
    return p.id
end

-- ── Belegung ───────────────────────────────────────────────────────────────

--- Ein Zeichen je Segment: '.' nichts, 'e' nur Evidence, 'f' nur Fidelity,
--- 'b' beides. String statt Tabelle (bei feinem Raster 5760 Eintraege/Spieler).
--- Der RAM-Ring geht mit ein, damit die Zeitleiste auch ohne Disk-Archiv nicht
--- durchgehend leer bleibt.
local function barsFor(hash, id, fromSeg, toSeg)
    local n = toSeg - fromSeg + 1
    local ePres, dPres = {}, {}

    -- Evidence von der Platte. SegIndex.Bars zaehlt je Segment die dort
    -- beginnenden Chunks (dieselbe Zuordnung wie die Auslieferung), parts>0 reicht.
    if SegIndex and SegIndex.Bars then
        local ev = SegIndex.Bars(hash, fromSeg, toSeg)
        for i = 1, #ev do
            if (ev[i].parts or 0) > 0 then ePres[fromSeg + i - 1] = true end
        end
    end

    if id then
        local ring = Recorder.GetRing(id)
        if ring then
            ring:each(function(_, m)
                if m and m.startSec then mark(ePres, m.startSec, fromSeg, toSeg) end
            end)
        end
        -- Offener Chunk nur am Live-Rand; fuer aeltere Baender waere PeekOpen
        -- (baut den Chunk-String neu auf) reine Verschwendung.
        if toSeg >= (Session.NowSeg() - 1) then
            local open, openSec = Recorder.PeekOpen(id)
            if open and openSec then mark(ePres, openSec, fromSeg, toSeg) end
        end
    end

    -- Fidelity von der Platte ueber den Offset-Scan (bySeg schon nach
    -- SegOf(startSec) abgelegt).
    local first = Session.SecOf(fromSeg)
    local last  = Session.SecOf(toSeg) + segSeconds() - 1
    for _, c in ipairs(fidDaysForSecs(hash, first, last)) do
        for s, list in pairs(c.bySeg) do
            if s >= fromSeg and s <= toSeg and #list > 0 then dPres[s] = true end
        end
    end

    -- Fidelity aus dem RAM, nach derselben Regel wie die Auslieferung.
    if id and fidUseRam(hash, id, toSeg) then
        local floorSeg = ramFloorSeg()
        local ramFrom  = Session.SecOf(fromSeg > floorSeg and fromSeg or floorSeg)
        for _, c in ipairs(fidRamChunks(hash, id, ramFrom, last)) do
            mark(dPres, c.startSec, fromSeg, toSeg)
        end
    end

    local out, any = {}, false
    for i = 1, n do
        local seg = fromSeg + i - 1
        local e, d = ePres[seg] or false, dPres[seg] or false
        local ch = '.'
        if e and d then ch = 'b' elseif e then ch = 'e' elseif d then ch = 'f' end
        out[i] = ch
        if ch ~= '.' then any = true end
    end
    return table.concat(out), any
end

--- Fehlende/zu kurze Tagesindizes einmalig aufbauen lassen (sonst zeigt das
--- Band nach Absturz/Nachruesten/Rasterwechsel '.', obwohl Nutzdaten da sind).
--- Aufbau kooperativ in eigenen Threads (SegIndex.Rebuild); hier nur begrenzt
--- warten.
--- Rueckgabe: Pseudonyme, deren Index NICHT fertig wurde (Budget/Geduld) — fuer
--- sie ist die Belegung unbekannt, nicht leer.
local function ensureIndices(players, fromSeg, toSeg)
    local unknown = {}
    if not (SegIndex and SegIndex.Ensure) then return unknown end

    local first = Session.SecOf(fromSeg)
    local last  = Session.SecOf(toSeg) + segSeconds()
    local days, seen = {}, {}
    for t = first, last, 86400 do
        local k = os.date('%Y%m%d', t)
        if not seen[k] then seen[k] = true; days[#days + 1] = t end
    end
    local kLast = os.date('%Y%m%d', last)
    if not seen[kLast] then days[#days + 1] = last end

    local openN, left = 0, MAX_ENSURE
    local pendingOf = {}

    -- Tage aussen, Spieler innen: sonst verbraucht ein Spieler mit vielen Tagen
    -- das ganze Budget und alle folgenden bekommen keinen Index.
    for _, t in ipairs(days) do
        for _, p in ipairs(players) do
            local hash = p.hash & 0xFFFFFFFF
            if left <= 0 then
                unknown[hash] = true
            else
                left  = left - 1
                openN = openN + 1
                pendingOf[hash] = (pendingOf[hash] or 0) + 1
                SegIndex.Ensure(hash, t, function()
                    openN = openN - 1
                    pendingOf[hash] = (pendingOf[hash] or 1) - 1
                end)
            end
        end
    end

    local t0 = GetGameTimer()
    while openN > 0 and (GetGameTimer() - t0) < ENSURE_WAIT_MS do Wait(50) end

    -- Noch offene Aufbauten nach Ablauf der Geduld: ebenfalls 'unbekannt'.
    for _, p in ipairs(players) do
        local hash = p.hash & 0xFFFFFFFF
        if (pendingOf[hash] or 0) > 0 then unknown[hash] = true end
    end
    return unknown
end

-- ── Manifest ───────────────────────────────────────────────────────────────

--- Meldungen als Zeitleisten-Marker. Absolute Unix-Zeit; Umrechnung macht der Client.
local function ticketList()
    local out = {}
    for _, tk in ipairs(Tickets.All()) do
        local names = {}
        for _, nb in ipairs(tk.nearby or {}) do names[#names + 1] = nb.name end
        out[#out + 1] = {
            id           = tk.id,
            t            = tk.t,
            text         = tk.text,
            status       = tk.status or 'open',
            reporter     = tk.reporter and tk.reporter.name or '?',
            reporterId   = tk.reporter and tk.reporter.id or nil,
            reporterHash = tk.reporter and tk.reporter.hash or nil,
            nearby       = names,
            assignedTo   = tk.assignedTo,
            closedBy     = tk.closedBy,
        }
    end
    return out
end

local function incidentList()
    local out = {}
    if not (Detection and Detection.Recent) then return out end
    for _, inc in ipairs(Detection.Recent(50)) do
        out[#out + 1] = {
            id = inc.id, type = inc.type, t = inc.t,
            confidence = inc.confidence,
            summary = inc.data and inc.data.summary or '',
            shooter = inc.involved and inc.involved.shooter,
            victim  = inc.involved and inc.involved.victim,
        }
    end
    return out
end

local function damageList()
    local out = {}
    for _, ev in ipairs(Events.Recent(300)) do
        if ev.type == 'damage' then
            out[#out + 1] = { t = ev.t, shooter = ev.shooter, victim = ev.victim }
        end
    end
    return out
end

--- Modell des Spielers. Ausgeloggt: kein Ped -> gemeldetes Aussehen, sonst Freemode.
local function modelOf(p)
    local src = liveSrcOf(p)
    if src then
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local m = GetEntityModel(ped)
            if m and m ~= 0 then return m end
        end
    end
    local ap = GetAppearanceByHash(p.hash)
    if ap and ap.model then return ap.model end
    return FREEMODE
end

--- Auswahlreihenfolge des Akteursdeckels: Fokus zuerst, dann nach zeitlichem
--- Abstand der Anwesenheit zum Sprungpunkt (bei Gleichstand Rosterreihenfolge).
--- Nicht nach Weltposition: die kennt der Server nur, wenn er genau die
--- Nutzdaten liest, die der Deckel einsparen soll.
local function rankOrder(players, focusHash, jumpSec)
    local rank = {}
    for i, p in ipairs(players) do
        local d
        if p.hash == focusHash then
            d = -1
        else
            d = math.maxinteger
            for _, s in ipairs(p.spans or {}) do
                local a = toInt(s.from) or jumpSec
                local b = toInt(s.to) or jumpSec
                local gap = 0
                if jumpSec < a then gap = a - jumpSec
                elseif jumpSec > b then gap = jumpSec - b end
                if gap < d then d = gap end
            end
        end
        rank[i] = { i = i, hash = p.hash, id = p.id, d = d }
    end
    table.sort(rank, function(x, y)
        if x.d ~= y.d then return x.d < y.d end
        return x.i < y.i
    end)

    local out = {}
    for _, r in ipairs(rank) do out[#out + 1] = { hash = r.hash, id = r.id } end
    return out
end

--- Rueckgabe: Manifest UND die Auslieferungsreihenfolge fuer die Sitzung.
local function buildManifest(src, opts)
    opts = opts or {}
    local segSec = segSeconds()
    local now    = os.time()

    -- Fenster um den Zeitpunkt (bei drei Vierteln der Spanne, damit der Vorlauf
    -- sichtbar ist).
    local center = toInt(opts.centerSec) or now
    local half   = windowMins() * 60
    local toSec  = math.min(now, center + (half // 4))
    local fromSec = toSec - half

    local jumpSec = toInt(opts.jumpT) or center
    if jumpSec < fromSec then jumpSec = fromSec end
    if jumpSec > toSec   then jumpSec = toSec end

    local roster = SessionIndex.Query(fromSec, toSec)
    if #roster == 0 then return nil end

    local fromSeg = Session.SegOf(fromSec)
    local toSeg   = Session.SegOf(toSec)
    if toSeg < fromSeg then toSeg = fromSeg end

    -- Band kostet ein Zeichen je Segment UND Spieler: bei vielen Spielern
    -- Fenster enger ziehen, statt das Manifest ueber ein Netz-Ereignis wachsen zu lassen.
    local allow = BARS_BUDGET // math.max(1, #roster)
    if allow < 32 then allow = 32 end
    if allow > MAX_SEGMENTS then allow = MAX_SEGMENTS end
    if (toSeg - fromSeg + 1) > allow then
        local jumpSeg = Session.SegOf(jumpSec)
        local lo = jumpSeg - (allow // 2)
        if lo < fromSeg then lo = fromSeg end
        if lo + allow - 1 > toSeg then lo = toSeg - allow + 1 end
        if lo < fromSeg then lo = fromSeg end
        fromSeg = lo
        toSeg   = lo + allow - 1
    end

    -- Tagesindizes VOR der Belegung aufbauen, sonst meldet das Band Leere, wo
    -- nur der Index fehlt.
    local unknown = ensureIndices(roster, fromSeg, toSeg)

    local players, lo, hi, anyMaterial = {}, nil, nil, false
    for _, e in ipairs(roster) do
        local hash = e.hash & 0xFFFFFFFF
        local p = { hash = hash, id = e.online and e.src or nil }
        -- Einmal pruefen: ab hier ist p.id eine gueltige Server-ID oder nichts.
        p.id = liveSrcOf(p)
        local bars, any = barsFor(hash, p.id, fromSeg, toSeg)

        -- Leeres Band UND kein Index: Aussage ueber den Index, nicht ueber
        -- Material. Spieler bleibt im Roster, gekennzeichnet statt still weg.
        local unk = (not any) and unknown[hash] or false

        if any or unk then
            p.bars        = bars
            p.barsUnknown = unk or nil
            p.name        = e.name or SessionIndex.NameOf(hash) or ('#%08x'):format(hash)
            p.online      = p.id ~= nil
            p.spans       = e.spans or {}
            players[#players + 1] = p

            if any then
                anyMaterial = true
                local a, b = bars:find('[^%.]'), bars:reverse():find('[^%.]')
                a = a or 1
                b = #bars - (b or #bars) + 1
                if not lo or a < lo then lo = a end
                if not hi or b > hi then hi = b end
            end
        end
        -- Je Spieler abgeben: ein Dutzend in einem Tick summiert sich sichtbar.
        Wait(0)
    end

    if #players == 0 then return nil end

    -- Auf den Bereich mit Material zuschneiden (firstSeg/lastSeg sind laut
    -- Vertrag genau das). Nur unbekannte Baender: volles Fenster bleibt stehen.
    if not anyMaterial then
        lo, hi = 1, toSeg - fromSeg + 1
    end
    lo = lo or 1
    hi = hi or (toSeg - fromSeg + 1)
    local firstSeg = fromSeg + lo - 1
    local lastSeg  = fromSeg + hi - 1
    local firstSec = Session.SecOf(firstSeg)
    local lastSec  = Session.SecOf(lastSeg) + segSec - 1

    local focusHash = toInt(opts.focusHash)
    if focusHash then focusHash = focusHash & 0xFFFFFFFF end

    local hasFocus = false
    for _, p in ipairs(players) do
        if focusHash and p.hash == focusHash then hasFocus = true; break end
    end
    -- Ohne verwertbaren Fokus zeigt die Kamera auf niemanden -> erster Spieler
    -- mit Material.
    if not hasFocus then focusHash = players[1].hash end

    -- Reihenfolge VOR dem Anwesenheits-Zuschnitt: ein Spieler, dessen
    -- Anwesenheit ganz vor dem Fenster liegt, haette danach keine Spanne mehr.
    local order = rankOrder(players, focusHash, jumpSec)

    for _, p in ipairs(players) do
        p.bars  = p.bars:sub(lo, hi)
        p.model = modelOf(p)
        p.appearance = GetAppearanceByHash(p.hash)

        -- Anwesenheit auf das ausgelieferte Fenster begrenzen (keine Abschnitte
        -- ohne Band).
        local sp = {}
        for _, s in ipairs(p.spans) do
            local a = math.max(s.from or firstSec, firstSec)
            local b = math.min(s.to or lastSec, lastSec)
            if b >= a then sp[#sp + 1] = { from = a, to = b } end
        end
        p.spans = sp
    end

    local jumpSeg = Session.SegOf(jumpSec)
    if jumpSeg < firstSeg then jumpSeg = firstSeg end
    if jumpSeg > lastSeg  then jumpSeg = lastSeg end

    return {
        epoch     = Session.Epoch(),
        segSec    = segSec,
        firstSeg  = firstSeg,
        lastSeg   = lastSeg,
        jumpSeg   = jumpSeg,
        -- Genaue Sekunde des Sprungziels (Segment ist grob), fuer den Sprung auf
        -- die Meldung statt auf den Segmentanfang.
        jumpSec   = toInt(opts.jumpT) or nil,
        -- Nummer der Meldung, damit die Oberflaeche sie in der Liste hervorhebt.
        ticketId  = toInt(opts.ticketId) or nil,
        focusHash = focusHash,
        -- Sichtbarer Deckel: erklaert den capped-Merker, statt Vollstaendigkeit
        -- zu behaupten.
        maxActors = maxActors(),
        me        = GetPlayerName(src) or ('Admin ' .. tostring(src)),
        players   = players,
        tickets   = ticketList(),
        incidents = incidentList(),
        damage    = damageList(),
        world     = GetWorldLog(),
    }, order
end

--- Manifest bauen und schicken; legt die Streaming-Sitzung an.
--- opts = { focusHash, centerSec, jumpT }. Laeuft in eigenem Thread (Aufbau
--- gibt ab). Je src nur EIN Aufbau gleichzeitig, sonst ueberschreibt der
--- langsamere die Sitzung des schnelleren.
function Stream.SendManifest(src, opts)
    src = toInt(src)
    if not src or not RPSIsAdmin(src) then return false end

    if building[src] then
        RPSNotify(src, 'Replay', 'Bitte warten',
            'Das vorherige Replay wird noch aufgebaut.', 'CHAR_BLOCKED')
        return false
    end
    building[src] = true

    CreateThread(function()
        local seq = closeSeq[src] or 0
        local ok, m, order = pcall(buildManifest, src, opts)
        building[src] = nil

        if not ok then
            print(('^1[D-RPS] Manifest fehlgeschlagen: %s^0'):format(tostring(m)))
            m, order = nil, nil
        end

        -- Waehrend des Aufbaus geschlossen: Ergebnis gehoert zu keiner Sitzung mehr.
        if (closeSeq[src] or 0) ~= seq then return end

        if not m then
            -- Kein Manifest: nichts zu zeigen. Eine leere Sitzung liesse den
            -- Client auf Segmente warten, die es nicht gibt.
            Stream.Close(src)
            RPSNotify(src, 'Replay', 'Keine Aufzeichnung',
                'Zu diesem Zeitpunkt liegt nichts vor.', 'CHAR_BLOCKED')
            return
        end

        sessions[src] = {
            src      = src,
            -- Deckel-Reihenfolge EINMAL festgehalten: darf zwischen Segmenten
            -- nicht wechseln, sonst zeigt das Replay je Ladezeitpunkt andere Spieler.
            players  = order or {},
            -- Szenenspur: WESSEN Sicht ausgeliefert wird (je Beobachter gefuehrt).
            focusHash = m.focusHash,
            firstSeg = m.firstSeg,
            lastSeg  = m.lastSeg,
            tokens   = burst(),
            tokenAt  = GetGameTimer(),
            inflight = 0,
            busy     = false,
            seen     = os.time(),
        }

        TriggerClientEvent('d-rps:seg:manifest', src, m)
    end)
    return true
end

--- Frisch gemeldetes Aussehen an die Sitzungen verteilen, deren Replay diesen
--- Spieler zeigt (nur betroffene, Abgleich ueber die festgehaltene Spielerliste).
AddEventHandler('d-rps:internal:appearance', function(hash, appearance)
    hash = toInt(hash)
    if not hash then return end
    hash = hash & 0xFFFFFFFF
    for src, sess in pairs(sessions) do
        local wants = false
        for _, p in ipairs(sess.players or {}) do
            if p.hash == hash then wants = true; break end
        end
        if wants then
            TriggerClientEvent('d-rps:appearance', src, hash, appearance)
        end
    end
end)

function Stream.Close(src)
    src = toInt(src)
    if not src then return end
    sessions[src] = nil
    -- Signal an einen laufenden Manifestaufbau, dass sein Ergebnis obsolet ist.
    closeSeq[src] = (closeSeq[src] or 0) + 1
end

-- ── Auslieferung ───────────────────────────────────────────────────────────

--- Den offenen Chunk ERST beim Zusammenstellen holen, nie beim Listenaufbau:
--- ein eingefrorener Schnappschuss endet mitten im Chunk, und geht der Spieler
--- dabei offline (Combat-Log), fehlt der Rest fuer immer.
--- Quellen: noch offen -> im Ring geschlossen -> auf der Platte.
local function openData(hash, live, want)
    local p = { hash = hash, id = live }
    local src = liveSrcOf(p)
    if src then
        local data, sec = Recorder.PeekOpen(src)
        if data and sec == want then return data end

        local ring = Recorder.GetRing(src)
        if ring then
            local found
            ring:each(function(chunk, mt)
                if not found and mt and mt.startSec == want then found = chunk end
            end)
            if found then return found end
        end
    end

    -- Waehrend der Auslieferung offline gegangen: Chunk wurde beim Verlassen
    -- geschlossen, geschrieben und indiziert.
    if SegIndex and SegIndex.Get then
        for _, e in ipairs(SegIndex.Get(hash, Session.SegOf(want))) do
            if e.startSec == want then return SegIndex.ReadChunk(hash, e) end
        end
    end
    return nil
end

--- Was fuer ein Segment auszuliefern waere, ohne Nutzdaten zu lesen: je Spieler
--- eine Evidence- und eine Fidelity-Liste. Dieselbe Regel wie barsFor (Chunk
--- gehoert zu seinem Startsegment, keine Spanne einbauen).
--- Hier greift der Akteursdeckel (waehlt SPIELER nach Sitzungsreihenfolge);
--- zweiter Rueckgabewert sagt, ob er gegriffen hat.
local function rowsFor(sess, seg)
    local segFrom = Session.SecOf(seg)
    local segTo   = segFrom + segSeconds() - 1
    -- Offener Chunk kann hoechstens ein Segment zurueckliegen.
    local nearNow = seg >= (Session.NowSeg() - 1)
    local cap     = maxActors()

    local rows, capped = {}, false
    for n, p in ipairs(sess.players) do
        local ev, seen = {}, {}
        if SegIndex and SegIndex.Get then
            for _, e in ipairs(SegIndex.Get(p.hash, seg)) do
                if not seen[e.startSec] then
                    seen[e.startSec] = true
                    ev[#ev + 1] = { startSec = e.startSec, idx = e }
                end
            end
        end

        local live = liveSrcOf(p)
        if live then
            -- RAM-Ring als Rueckfall (ohne Disk-Archiv, oder Chunk geschrieben
            -- aber noch nicht indiziert).
            local ring = Recorder.GetRing(live)
            if ring then
                ring:each(function(chunk, mt)
                    local s = mt and mt.startSec
                    if s and not seen[s] and Session.SegOf(s) == seg then
                        seen[s] = true
                        ev[#ev + 1] = { startSec = s, data = chunk }
                    end
                end)
            end

            -- Juengstes Segment enthaelt auch den offenen Chunk: hier nur seine
            -- Startsekunde vermerken, Bytes holt openData spaeter frisch.
            if nearNow then
                local open, openSec = Recorder.PeekOpen(live)
                if open and openSec and not seen[openSec] and Session.SegOf(openSec) == seg then
                    seen[openSec] = true
                    ev[#ev + 1] = { startSec = openSec, open = live }
                end
            end
        end
        table.sort(ev, function(a, b) return a.startSec < b.startSec end)

        local raw, fseen = fidEntries(p.hash, seg)
        local fid = {}
        for _, e in ipairs(raw) do
            fid[#fid + 1] = { startSec = e.startSec, fe = e }
        end

        -- RAM-Rueckfall wie bei Evidence, nach derselben Regel (fidUseRam).
        if fidUseRam(p.hash, live, seg) then
            local added = false
            for _, c in ipairs(fidRamChunks(p.hash, live, segFrom, segTo)) do
                if not fseen[c.startSec] and Session.SegOf(c.startSec) == seg then
                    fseen[c.startSec] = true
                    fid[#fid + 1] = { startSec = c.startSec, data = c.data }
                    added = true
                end
            end
            if added then
                table.sort(fid, function(a, b) return a.startSec < b.startSec end)
            end
        end

        if #ev > 0 or #fid > 0 then
            if #rows < cap then
                rows[#rows + 1] = { hash = p.hash, key = tostring(p.hash), ev = ev, fid = fid }
            else
                -- Weiterer Spieler haette Material: Deckel erreicht, Antwort sagt es.
                capped = true
                break
            end
        end

        -- Der Aufbau liest Index und .fid-Kopfdaten; alle paar Spieler abgeben.
        if n % ROWS_YIELD == 0 then Wait(0) end
    end
    return rows, capped
end

-- Nach so vielen gelesenen Weltchunks gibt die Auslieferung einmal ab.
-- Dieselbe Groessenordnung wie ROWS_YIELD im Aufbau der Spielerliste.
local WORLD_YIELD = 8
local worldYield  = 0

--- Die WELTSPUR eines Segments: Fahrzeuge, in denen niemand sass. Laeuft NEBEN
--- der Spielerauswahl: zaehlt nicht gegen den Akteursdeckel (sonst verdraengt
--- ein voller Parkplatz die Beteiligten) und geht nicht in sent ein (sonst
--- wuerde ein fehlendes Auto ein Segment verwerfen).
--- Nicht entdoppelt: je Segment und Fahrzeug genau EIN Chunk, der Client
--- ersetzt seinen Block bei erneuter Lieferung.
local function worldRows(sess, seg)
    local out, bytes = {}, 0

    -- Quelle der Umgebung: 'server' (autoritativ, server/vehicles.lua),
    -- 'client' (reicher, je Beobachter, server/scene.lua) oder 'both'.
    -- Ausgeliefert immer unter kind='world', nur die Quelle unterscheidet sich.
    local src = (Config.Playback and Config.Playback.Source) or 'server'
    local useServer = (src ~= 'client')
    local useClient = (src == 'client' or src == 'both')

    local cap  = cfgInt(Config.World and Config.World.MaxDeliverBytes, 98304, 8192, 1048576)
    local capN = cfgInt(Config.World and Config.World.MaxDeliverChunks, 128, 8, 2048)
    local capped = false

    -- ── Clientsicht ────────────────────────────────────────────────────────
    if useClient and Scene and Scene.Entries and sess and sess.focusHash then
        for _, e in ipairs(Scene.Entries(sess.focusHash, seg)) do
            if #out >= capN or bytes + (e.len or 0) > cap then capped = true; break end
            bytes = bytes + (e.len or 0)
            out[#out + 1] = {
                hash = Protocol.WORLD_HASH, key = 'w', kind = 'world',
                item = { startSec = e.startSec, scene = sess.focusHash, se = e },
            }
        end
    end

    if not useServer then return out, capped, bytes end
    if not (Config.World and Config.World.Vehicles) then return out, capped, bytes end

    if SegIndex and SegIndex.Get then
        for _, e in ipairs(SegIndex.Get(Protocol.WORLD_HASH, seg)) do
            -- Groesse steht im Index -> Auswahl VOR dem Lesen (Deckel nach dem
            -- seek haette die Plattenzeit schon verbraucht).
            if #out >= capN or bytes + (e.len or 0) > cap then
                capped = true
                break
            end
            bytes = bytes + (e.len or 0)
            out[#out + 1] = {
                hash = Protocol.WORLD_HASH, key = 'w', kind = 'world',
                item = { startSec = e.startSec, idx = e },
            }
        end
    end

    -- Live-Rand: der Weltstrom hat keinen RAM-Ring; ohne diesen Griff waere das
    -- juengste Segment erst nach Abschluss sichtbar.
    if WorldVeh and WorldVeh.PeekOpen and seg >= (Session.NowSeg() - 1) then
        local open = WorldVeh.PeekOpen(seg)
        if open and (bytes + #open) <= cap then
            out[#out + 1] = {
                hash = Protocol.WORLD_HASH, key = 'w', kind = 'world',
                item = { startSec = Session.SecOf(seg), data = open },
            }
        elseif open then
            capped = true
        end
    end

    return out, capped, bytes
end

--- Die Positionen in EINE Reihenfolge bringen. Reihum statt spielerweise, damit
--- die erste Nachricht von JEDEM Spieler etwas traegt (Klone sofort sichtbar).
local function flatten(rows)
    local rounds = 0
    for _, r in ipairs(rows) do
        if #r.ev  > rounds then rounds = #r.ev  end
        if #r.fid > rounds then rounds = #r.fid end
    end

    local out = {}
    for i = 1, rounds do
        for _, r in ipairs(rows) do
            if r.ev[i] then
                out[#out + 1] = { hash = r.hash, key = r.key, kind = 'ev', item = r.ev[i] }
            end
            if r.fid[i] then
                out[#out + 1] = { hash = r.hash, key = r.key, kind = 'fid', item = r.fid[i] }
            end
        end
    end
    return out
end

--- Nutzdaten eines Eintrags. Gibt nach jedem Plattenzugriff ab (ein Dutzend
--- seek+read je Tick liesse den Servertick haengen).
local function dataOf(it)
    local e = it.item
    if e.open then return openData(it.hash, e.open, e.startSec) end
    if e.data then return e.data end

    if it.kind == 'world' then
        local d
        if e.scene and e.se then
            -- Aus der Szenenspur des beobachtenden Spielers.
            d = Scene and Scene.Read and Scene.Read(e.scene, e.se) or nil
        else
            d = e.idx and SegIndex.ReadChunk(Protocol.WORLD_HASH, e.idx) or nil
        end
        -- Nicht je Chunk abgeben (Weltchunks klein und zahlreich); gebuendelt.
        worldYield = worldYield + 1
        if worldYield >= WORLD_YIELD then worldYield = 0; Wait(0) end
        return d
    end

    local data
    if it.kind == 'ev' then
        data = e.idx and SegIndex.ReadChunk(it.hash, e.idx) or nil
    else
        data = e.fe and fidRead(it.hash, e.fe) or nil
    end
    Wait(0)
    return data
end

--- Ein Segment ausliefern (Vertrag v3). KEIN Zustand zwischen Nachrichten:
--- Liste einmal gebaut, in diesem Thread abgearbeitet; volles Byte-Budget ->
--- Nachricht raus, naechste beginnt. Nur die letzte traegt done=true.
--- Die Abschlussnachricht traegt die Buchfuehrung (sent/missing), beim
--- Zusammenstellen gezaehlt, nicht geschaetzt.
--- st.done sagt dem Aufrufer, ob die Abschlussnachricht raus ist; bricht serve
--- ab, schickt er eine Ablehnung (Doppeltes verwirft der Client per Schluessel).
local function serve(sess, seg, rid, st)
    local src = sess.src

    local rows, capped = rowsFor(sess, seg)
    -- rowsFor gibt ab: Sitzung zwischenzeitlich geschlossen -> Liste obsolet.
    if sessions[src] ~= sess then return end

    local list = flatten(rows)

    -- Umgebung haengt HINTEN an: so traegt die erste Nachricht weiter von jedem
    -- Beteiligten etwas (Klone sofort), Fahrzeuge kommen danach.
    local wrows, wcapped = worldRows(sess, seg)
    for i = 1, #wrows do list[#list + 1] = wrows[i] end
    local worldSent, worldMissing = 0, 0

    local budget = maxBytes()
    local items, bytes = {}, 0

    -- Buchfuehrung ueber die GANZE Anfrage (Client sammelt alle Nachrichten
    -- einer rid und vergleicht am Ende).
    local sent, missing = {}, 0

    --- Einen mitgeschickten Chunk verbuchen. Alle drei Zaehler anlegen, damit
    --- der Client nirgends mit nil rechnet.
    local function count(key, field)
        local r = sent[key]
        if not r then r = { ev = 0, fid = 0, open = 0 }; sent[key] = r end
        r[field] = r[field] + 1
    end

    local function flush(done)
        if done then st.done = true end
    TriggerClientEvent('d-rps:seg:data', src, {
            seg  = seg,
            -- rid unveraendert in JEDER Nachricht (sonst unterscheidet der
            -- Client Antworten auf verworfene und laufende Anfrage nicht).
            rid  = rid,
            done = done and true or false,
            items = items,
            -- Nur in der Abschlussnachricht, sonst widersprechende Zusagen.
            sent    = done and sent or nil,
            missing = done and missing or nil,
            capped  = done and (capped and true or false) or nil,
            -- Weltspur-Buchfuehrung, getrennt: verwirft kein Segment, sagt nur,
            -- ob die Umgebung vollstaendig ist.
            world        = done and worldSent or nil,
            worldMissing = done and worldMissing or nil,
            worldCapped  = done and (wcapped and true or false) or nil,
        })
        items, bytes = {}, 0
    end

    for i = 1, #list do
        local it   = list[i]
        local data = dataOf(it)
        if sessions[src] ~= sess then return end   -- zwischendurch beendet

        -- Offener Chunk bekommt eine EIGENE Art ('evopen'): er waechst, darf
        -- nicht entdoppelt werden; der Client haelt einen ersetzbaren Platz.
        local kind, field = it.kind, it.kind
        if kind == 'ev' and it.item.open then kind, field = 'evopen', 'open' end

        -- Leere Nutzdaten (Datei verschwunden/beschaedigt) nicht als geliefert
        -- verbuchen, sonst eine Zusage ohne Sample.
        if type(data) == 'string' and #data > 0 then
            -- Erster Eintrag einer Nachricht geht IMMER mit, auch wenn er allein
            -- das Budget reisst.
            if #items > 0 and (bytes + #data + ITEM_OVERHEAD) > budget then
                flush(false)
            end
            items[#items + 1] = {
                kind  = kind,
                -- Schluessel als STRING: eine u32 als Zahlenschluessel wuerde
                -- ueber die Netzgrenze zu einem Array mit Milliarden Luecken.
                hash  = it.key,
                start = it.item.startSec,
                data  = data,
            }
            bytes = bytes + #data + ITEM_OVERHEAD
            -- Weltspur SEPARAT zaehlen: sent hat je Spieler drei feste Zaehler.
            if kind == 'world' then
                worldSent = worldSent + 1
            else
                count(it.key, field)
            end
        else
            if kind == 'world' then
                worldMissing = worldMissing + 1
            else
                missing = missing + 1
            end
        end
    end

    -- Auch das leere Segment bekommt genau eine Nachricht (sonst wartet der
    -- Client auf etwas, das nie kommt).
    flush(true)
end

-- ── Anfragefluten ──────────────────────────────────────────────────────────

--- Token-Eimer je Sitzung. GetGameTimer() nur als Differenz, nie mit Wanduhrzeit.
local function takeToken(sess)
    local now = GetGameTimer()
    local dt  = (now - (sess.tokenAt or now)) / 1000.0
    sess.tokenAt = now
    if dt > 0 then
        sess.tokens = math.min(burst(), (sess.tokens or 0) + dt * ratePerSec())
    end
    if (sess.tokens or 0) < 1.0 then return false end
    sess.tokens = sess.tokens - 1.0
    return true
end

-- ── Netz ───────────────────────────────────────────────────────────────────

-- Gruende, nach denen sich ein erneuter Versuch lohnt (Last, nicht Anliegen):
-- der Client stellt zurueck und zaehlt es NICHT als Fehlversuch.
local RETRY_REASONS = {
    ['auslieferung blockiert']   = true,
    ['zu viele offene anfragen'] = true,
}

--- Ablehnung. Auch sie ist eine Antwort (sonst wartet der Client bis zum
--- Timeout). 'denied' unterscheidet sie von einem wirklich leeren Segment.
local function deny(st, src, seg, rid, why)
    if st then st.done = true end
    why = why or 'abgelehnt'
    TriggerClientEvent('d-rps:seg:data', src, {
        seg = seg, rid = rid, done = true, items = {},
        -- Nichts zugesagt, nichts unlesbar, Deckel nicht gegriffen; massgeblich denied.
        sent = {}, missing = 0, capped = false,
        denied = why, retry = RETRY_REASONS[why] or false,
    })
end

RegisterNetEvent('d-rps:seg:want', function(seg, rid)
    local src  = source
    local segN = toInt(seg)

    -- Unbrauchbare Segmentnummer wird -1, die der Client einfach verwirft.
    local echo = segN or -1

    -- Anfragekennung unveraendert zurueck; -1, wenn unbrauchbar.
    local ridN = toInt(rid) or -1

    -- JEDER Handler prueft die Berechtigung selbst (Archiv ist nach Pseudonym
    -- adressierbar, nicht nach Zugehoerigkeit).
    if not RPSIsAdmin(src) then deny(nil, src, echo, ridN, 'keine berechtigung'); return end

    local sess = sessions[src]
    if not sess then deny(nil, src, echo, ridN, 'keine sitzung'); return end
    if not segN then deny(nil, src, echo, ridN, 'unplausibles segment'); return end

    sess.seen = os.time()

    -- Ausserhalb des Manifests wird nichts gelesen; Antwort geht trotzdem raus.
    if segN < sess.firstSeg or segN > sess.lastSeg then
        deny(nil, src, echo, ridN, 'ausserhalb des manifests')
        return
    end

    -- Mehr als eine Handvoll offener Anfragen kann kein ehrlicher Client haben.
    -- Eine WIEDERHOLTE Anfrage fuer dasselbe Segment ist erlaubt (idempotent,
    -- rid haelt die Versuche auseinander).
    if sess.inflight >= MAX_INFLIGHT then
        -- Vorruebergehend: spaeter erneut versuchen, nicht dauerhaft aufgeben.
        deny(nil, src, echo, ridN, 'zu viele offene anfragen')
        return
    end
    sess.inflight = sess.inflight + 1

    -- Eigener Thread, NICHT inline: die Auslieferung liest von der Platte und gibt ab.
    CreateThread(function()
        local st = { done = false }

        -- Je Sitzung nur ein Segment gleichzeitig: haelt die Plattenzugriffe
        -- eines Admins in einer Reihe.
        local t0 = GetGameTimer()
        while sessions[src] == sess and sess.busy
              and (GetGameTimer() - t0) < BUSY_WAIT_MS do
            Wait(25)
        end

        if sessions[src] ~= sess then
            deny(st, src, segN, ridN, 'sitzung beendet')
        elseif sess.busy then
            print(('^3[D-RPS] Segment %d: vorherige Auslieferung haengt seit %d ms.^0')
                :format(segN, BUSY_WAIT_MS))
            deny(st, src, segN, ridN, 'auslieferung blockiert')
        else
            -- HIER setzen, unmittelbar nach der Pruefung und VOR jedem Wait:
            -- ein Wait dazwischen liesse zwei Threads durch die Pruefung.
            sess.busy = true

            -- Token-Eimer: leer -> warten statt verwerfen (bleibt mit der
            -- Wartezeit oben unter dem Client-Timeout).
            local t1 = GetGameTimer()
            while sessions[src] == sess and not takeToken(sess)
                  and (GetGameTimer() - t1) < TOKEN_WAIT_MS do
                Wait(50)
            end

            if sessions[src] == sess then
                -- pcall: ein Fehler in serve liesse busy sonst dauerhaft stehen.
                local ok, err = pcall(serve, sess, segN, ridN, st)
                if not ok then
                    print(('^1[D-RPS] Segment %d nicht auslieferbar: %s^0')
                        :format(segN, tostring(err)))
                end
            end
            sess.busy = false
        end

        -- Letzte Sicherung der Antwortpflicht: serve kann bei geschlossener
        -- Sitzung ohne Abschlussnachricht zurueckkehren.
        if not st.done then deny(st, src, segN, ridN, 'auslieferung unvollstaendig') end

        sess.inflight = sess.inflight - 1
        if sess.inflight < 0 then sess.inflight = 0 end
    end)
end)

RegisterNetEvent('d-rps:seg:bye', function()
    local src = source
    if not RPSIsAdmin(src) then return end
    Stream.Close(src)
end)

-- Verbindungsverlust schickt kein bye: Sitzung sonst bis zum Neustart liegen.
AddEventHandler('playerDropped', function()
    Stream.Close(source)
end)

-- Aufraeumen, falls weder bye noch Disconnect kommen (Client haengt/neu
-- gestartet), damit sich Sitzungen und Tagesscans nicht ansammeln.
CreateThread(function()
    while true do
        Wait(60000)
        local now = os.time()
        for src, sess in pairs(sessions) do
            if (now - (sess.seen or now)) > SESSION_IDLE then
                sessions[src] = nil
            end
        end
        for k, c in pairs(fidCache) do
            -- scanning-Merker ohne Thread (Resource-Stop im Scan) sonst blockiert.
            if c.scanning and (now - (c.scanStart or now)) > FID_SCAN_STUCK then
                c.scanning, c.scanStart = nil, nil
            end
            if not c.scanning and (now - (c.used or now)) > FID_IDLE then
                fidCache[k] = nil
                fidCacheN = fidCacheN - 1
            end
        end
        -- closeSeq nur behalten, solange Aufbau oder Sitzung ihn braucht.
        for s in pairs(closeSeq) do
            if not sessions[s] and not building[s] then closeSeq[s] = nil end
        end
    end
end)

return Stream
