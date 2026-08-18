--[[ ===========================================================================
    D-RPS — server/segindex.lua
    Offset-Index ueber die Tagesarchive: statt Vollscan der .drps-Datei je Abruf
    ein f:seek + ein read auf EIN Segment.

    Je Tag/Spieler eine kleine .idx-Datei neben der .drps; flach im archive/
    (kein mkdir auf dem Zielserver, siehe archive.lua).
        archive/YYYYMMDD_<hash8>.idx / .drps

    Satzformat: FESTE Laenge je Satz (nur so sequenziell ohne Parser lesbar,
    Neustart haengt am Ende an, abgeschnittener letzter Satz schadet den
    vorherigen nicht):
        magic ver seg fileOff len nSamples startSec segSec epoch
    segSec+epoch stehen im Satz, weil eine Segmentnummer erst mit (Breite,
    Epoche) eine Zeitangabe ist; bei Abweichung wird der Tagesindex neu gebaut.
    Raster/Epoche kommen aus session.lua (einzige Autoritaet). fileOff zeigt auf
    das LAENGENPRAEFIX, damit es gegen len geprueft werden kann.
=========================================================================== ]]

SegIndex = {}

local RES      = GetCurrentResourceName()
local basePath                      -- absoluter Pfad zu …/archive
local ready    = false

-- ── Satzformat ─────────────────────────────────────────────────────────────

local REC_FMT   = '<I1 I1 I4 I4 I4 I2 I4 I2 I4'
local REC_MAGIC = 0xD6              -- bewusst NICHT Protocol.MAGIC (0xD5): faellt
                                    -- auf, falls versehentlich auf .drps angesetzt
-- v3: seg-Breite UND Nullpunkt im Satz. Beides noetig, weil eine Nummer erst
-- mit (Breite, Epoche) eine Zeitangabe ist. Version waechst mit der Satzlaenge.
local REC_VER   = 3
-- Aus dem Formatstring abgeleitet, damit Konstante und Format nicht auseinanderlaufen.
local REC_SIZE  = #string.pack(REC_FMT, 0, 0, 0, 0, 0, 0, 0, 0, 0)

-- Kopflaenge eines Chunks, abgeleitet (Kopf ist gewachsen und wird es wieder).
local HDR_LEN = 14
do
    -- Ladereihenfolge-Pruefung: faellt sonst erst beim ersten Wiederaufbau auf.
    if Protocol and Protocol.EncodeChunkHeader then
        local ok, s = pcall(Protocol.EncodeChunkHeader, 0, 0, 0, 0)
        if ok and type(s) == 'string' and #s > 0 then HDR_LEN = #s end
    end
end

-- Obergrenze fuer eine plausible Chunk-Laenge; ein beschaedigtes Praefix soll
-- den Wiederaufbau sauber abbrechen statt zufaellig weiterzuspringen.
local MAX_CHUNK_BYTES = 4 * 1024 * 1024

local SCAN_YIELD  = 500             -- Chunks je Zeitscheibe beim Wiederaufbau
local CACHE_MAX   = 32              -- gleichzeitig vorgehaltene Tages-Indizes
local MAX_BARS    = 4096            -- Deckel fuer Bars (siehe dort)

-- Zeitraum eines Loeschverlangens. Bewusst identisch mit Archive.PurgeHash,
-- sonst blieben Index oder Nutzdaten teilweise stehen.
local function purgeDays()
    local d = tonumber(Config and Config.RetentionDays) or 0
    d = math.floor(d)
    if d < 0 then d = 0 end
    return d + 95
end

-- ── Zahlwandlung ───────────────────────────────────────────────────────────

--- Verlaesslich zu einem Integer-Subtyp wandeln; sonst werfen '&' und
--- string.pack auf einem Float. Nicht Wandelbares bekommt den Vorgabewert.
local function toInt(v, dflt)
    local n = tonumber(v)
    if not n then return dflt end
    n = math.tointeger(n) or math.tointeger(math.floor(n))
    if not n then return dflt end
    return n
end

-- ── Zeitraster ─────────────────────────────────────────────────────────────
-- Ein Segment ist ein festes Zeitfenster. Wo Session geladen ist, gilt dessen
-- Raster und dessen Epoche; nur ohne Session wird ab der Unix-Epoche gerechnet.

local function segSeconds()
    local n
    if Session and Session.SegSeconds then n = tonumber(Session.SegSeconds()) end
    if not n then n = tonumber(Config and Config.DiskChunkSeconds) end
    n = toInt(n, 60)
    if n < 1 then n = 60 end
    if n > 65535 then n = 65535 end   -- Feld ist u16
    return n
end

--- Nullpunkt der Zeitachse. Gehoert in jeden Satz, siehe REC_VER.
local function segEpoch()
    if Session and Session.Epoch then return toInt(Session.Epoch(), 0) & 0xFFFFFFFF end
    return 0
end

--- Segmentnummer zu einer Wanduhr-Sekunde. Session ist die EINZIGE Autoritaet
--- fuer das Raster (zwei Wahrheiten waeren schlimmer als keine).
function SegIndex.SegOf(sec)
    return Session.SegOf(sec)
end

--- Erste Wanduhr-Sekunde eines Segments.
function SegIndex.SecOf(seg)
    return Session.SecOf(seg)
end

-- ── Pfade ──────────────────────────────────────────────────────────────────
-- .drps-Namensregel gespiegelt aus archive.lua (dort lokal); Aenderung dort hier nachziehen.

local function dayFile(hash, sec)
    return ('%s/%s_%08x.drps'):format(basePath, os.date('%Y%m%d', sec), hash & 0xFFFFFFFF)
end

local function idxFile(hash, sec)
    return ('%s/%s_%08x.idx'):format(basePath, os.date('%Y%m%d', sec), hash & 0xFFFFFFFF)
end

--- Groesse einer Datei in Byte, 0 wenn sie fehlt (kein stat, also seek('end')).
local function fileSize(path)
    local f = io.open(path, 'rb')
    if not f then return 0 end
    local n = f:seek('end') or 0
    f:close()
    return n
end

--- Eine Indexdatei entfernen. os.remove ist auf manchen Hostern gesperrt; dann
--- auf 0 Byte kuerzen (leerer Index = kein Index, wird bei Bedarf neu gebaut).
local function dropIdxFile(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()

    if type(os.remove) == 'function' then
        -- os.remove meldet Fehlschlag ueber Rueckgabewert, nicht Ausnahme.
        local ok, res = pcall(os.remove, path)
        if ok and res then return true end
    end

    local g = io.open(path, 'wb')
    if not g then return false end
    g:write('')
    return g:close() and true or false
end

-- ── Tages-Index im Speicher ────────────────────────────────────────────────
-- Ein Tag ist unter 30 KB; einmal je Tag/Spieler einlesen und im Speicher
-- halten, der laufende Tag wird nur am Ende nachgelesen.

local cache   = {}                  -- [dayKey:hash] = { bySeg, bytes, covered, … }
local cacheN  = 0
local touchN  = 0

-- Vor loadDay deklariert (Rasterbruch dort prueft, ob ein Rebuild laeuft).
local building = {}                 -- [idxPfad] = true, solange ein Rebuild laeuft
local pending  = {}                 -- [idxPfad] = Saetze, die waehrenddessen anfielen

local function cacheKey(hash, sec)
    return ('%s:%08x'):format(os.date('%Y%m%d', sec), hash & 0xFFFFFFFF)
end

local function evictIfNeeded()
    if cacheN <= CACHE_MAX then return end
    local oldKey, oldTouch
    for k, e in pairs(cache) do
        -- (e.touch or 0): ein Eintrag ohne touch rechnete sonst 'nil < number'.
        local t = e.touch or 0
        if not oldTouch or t < oldTouch then oldKey, oldTouch = k, t end
    end
    if oldKey then cache[oldKey] = nil; cacheN = cacheN - 1 end
end

--- Einen Satz in die Speichersicht einhaengen.
local function addEntry(c, seg, fileOff, len, nSamples, startSec)
    local list = c.bySeg[seg]
    if not list then list = {}; c.bySeg[seg] = list end
    list[#list + 1] = {
        seg = seg, fileOff = fileOff, len = len,
        nSamples = nSamples, startSec = startSec,
    }
    local endOff = fileOff + 4 + len
    if endOff > c.covered then c.covered = endOff end
    -- Groesster Chunk: NeedsRebuild braucht ihn als Toleranzmass.
    if len > (c.maxLen or 0) then c.maxLen = len end
end

--- Rohbytes eines Indexstroms in die Speichersicht uebernehmen. Gibt die Anzahl
--- uebernommener Saetze zurueck, bei Rasterbruch zusaetzlich dessen Breite.
local function absorb(c, data, grid, ep)
    local n, pos = 0, 1
    while pos + REC_SIZE - 1 <= #data do
        local magic, ver, seg, off, len, ns, startSec, ss, ee = string.unpack(REC_FMT, data, pos)
        pos = pos + REC_SIZE
        -- Fremde/aeltere Saetze ueberspringen (halb beschriebene Datei ist normal).
        if magic == REC_MAGIC and ver == REC_VER then
            -- Raster ODER Nullpunkt geaendert: ab hier andere Sekunden. Sofort
            -- abbrechen und melden.
            if ss ~= grid or ee ~= ep then return n, ss end
            addEntry(c, seg, off, len, ns, startSec)
            n = n + 1
        end
    end
    return n
end

--- Tages-Index laden oder aus dem Speicher holen. Fuer den laufenden Tag nur
--- den angewachsenen Rest nachlesen (f:seek), kein Vollscan.
local function loadDay(hash, sec)
    local key = cacheKey(hash, sec)
    local c   = cache[key]
    if not c then
        c = { bySeg = {}, bytes = 0, covered = 0, maxLen = 0, lastCheck = 0,
              path = idxFile(hash, sec), dayKey = os.date('%Y%m%d', sec) }
        cache[key] = c
        cacheN = cacheN + 1
        -- touch MUSS vor evictIfNeeded stehen, sonst rechnet die Verdraengung
        -- 'nil < number' auf dem frischen Eintrag.
        touchN  = touchN + 1
        c.touch = touchN
        evictIfNeeded()
    end
    touchN  = touchN + 1
    c.touch = touchN

    -- Abgeschlossener Tag: genau einmal gelesen. Laufender Tag: hoechstens einmal
    -- je Sekunde (sonst 1440 Dateioeffnungen je Bandabruf).
    if c.final then return c end
    local now = os.time()
    if c.lastCheck == now then return c end
    c.lastCheck = now
    if c.dayKey ~= os.date('%Y%m%d', now) then c.final = true end

    local f = io.open(c.path, 'rb')
    if not f then return c end

    local size = f:seek('end') or 0
    if size <= c.bytes then f:close(); return c end

    -- Auf ganze Satzgrenze zurueck: ein abgeschnittener letzter Satz darf den
    -- Rest nicht verschieben.
    local usable = size - (size % REC_SIZE)
    if usable <= c.bytes then f:close(); return c end

    f:seek('set', c.bytes)
    local data = f:read(usable - c.bytes)
    f:close()
    if type(data) == 'string' then
        local grid = segSeconds()
        local _, otherGrid = absorb(c, data, grid, segEpoch())
        if otherGrid then
            -- Rasterbruch: Index durchgehend falsch. Speichersicht und Datei
            -- verwerfen, Aufbau anstossen, laut melden.
            print(('^3[D-RPS] Segment-Index %s stammt aus einem anderen Raster '
                .. '(%ds statt %ds) — wird verworfen und neu aufgebaut.^0'):format(
                c.path:match('[^/]+$') or c.path, otherGrid, grid))
            c.bySeg, c.bytes, c.covered, c.maxLen = {}, 0, 0, 0
            if not building[c.path] then
                dropIdxFile(c.path)
                -- Ergebnis holt der naechste Leser.
                if SegIndex.Rebuild then SegIndex.Rebuild(hash, sec) end
            end
            return c
        end
        c.bytes = c.bytes + #data
    end
    return c
end

-- ── Schreiben ──────────────────────────────────────────────────────────────

--- Einen Satz anhaengen und dabei die Satzgrenze herstellen. true bei Schreiben
--- UND Schliessen.
--- 'r+b' statt 'ab', weil der Leser auf ein Vielfaches der Satzlaenge abrundet:
--- ein abgeschnittener letzter Satz wuerde beim blossen Anhaengen jeden spaeteren
--- Satz verschieben. Io kann nicht kuerzen, also ueber den Rumpf schreiben.
local function appendRec(path, rec)
    local f = io.open(path, 'r+b')
    if f then
        local size = f:seek('end') or 0
        local rest = size % REC_SIZE
        if rest ~= 0 then
            if not f:seek('set', size - rest) then f:close(); return false end
        end
        local wrote  = f:write(rec)
        local closed = f:close()
        return (wrote and closed) and true or false
    end

    -- Datei gibt es noch nicht: 'r+b' legt nichts an, 'ab' schon.
    f = io.open(path, 'ab')
    if not f then return false end
    local wrote  = f:write(rec)
    local closed = f:close()
    return (wrote and closed) and true or false
end

--- Einen geschriebenen Chunk vermerken. Aufrufer ist der Schreibpfad, direkt
--- nachdem der Chunk auf der Platte steht.
function SegIndex.Note(playerHash, seg, fileOff, len, nSamples, startSec)
    if not ready then return false end
    if type(fileOff) ~= 'number' or type(len) ~= 'number' then return false end

    fileOff = toInt(fileOff, -1)
    len     = toInt(len, -1)
    -- Felder sind u32/u16; ein Wert ausserhalb werfe in string.pack. Abweisen.
    if fileOff < 0 or fileOff > 0xFFFFFFFF then return false end
    if len <= 0 or len > 0xFFFFFFFF then return false end

    startSec = toInt(startSec, os.time())
    seg      = toInt(seg, SegIndex.SegOf(startSec))
    nSamples = math.min(65535, math.max(0, toInt(nSamples, 0)))

    local grid = segSeconds()
    -- Hash pruefen: nil/Float knallte sonst in der Bit-Operation, mitten im
    -- Recorder-Schreibpfad.
    local hash = toInt(playerHash, -1)
    if hash < 0 then return false end
    hash = hash & 0xFFFFFFFF
    local rec  = string.pack(REC_FMT, REC_MAGIC, REC_VER,
        seg & 0xFFFFFFFF, fileOff, len, nSamples, startSec & 0xFFFFFFFF,
        grid, segEpoch())

    local path = idxFile(hash, startSec)

    -- Waehrend eines Wiederaufbaus wird die Datei neu geschrieben; neue Saetze
    -- zurueckstellen und danach anhaengen, sonst gehen sie verloren.
    if building[path] then
        local q = pending[path]
        if not q then q = {}; pending[path] = q end
        q[#q + 1] = { rec = rec, seg = seg, fileOff = fileOff, len = len,
                      nSamples = nSamples, startSec = startSec, hash = hash }
        return true
    end

    -- Erst schreiben und pruefen, dann buchen: sonst behauptet c.bytes einen
    -- Stand, den die Datei nie hatte, und der naechste Lesevorgang setzt falsch auf.
    if not appendRec(path, rec) then
        if Config.Debug then print('^3[D-RPS] Segment-Index nicht schreibbar: ' .. path .. '^0') end
        return false
    end

    -- Speichersicht direkt mitfuehren (Abruf nach dem Schreiben ohne Dateizugriff).
    local c = cache[cacheKey(hash, startSec)]
    if c then
        addEntry(c, seg, fileOff, len, nSamples, startSec)
        c.bytes = c.bytes + REC_SIZE
    end
    return true
end

-- ── Lesen ──────────────────────────────────────────────────────────────────

--- Eintraege eines Segments. Rueckgabe IMMER eine Liste: zwei Note-Aufrufe fuer
--- dasselbe (hash, seg) sind normal (Chunk-Abschluss mitten im Segment), ein
--- Einzelsatz verloere den ersten Teil.
function SegIndex.Get(playerHash, seg)
    if not ready then return {} end
    local hash = playerHash & 0xFFFFFFFF
    local out  = {}

    -- Ein Segment kann ueber Mitternacht reichen (Breite kein Teiler von 86400);
    -- dann liegen seine Chunks in zwei Tagesdateien.
    local a = SegIndex.SecOf(seg)
    local b = a + segSeconds() - 1
    local dayA = os.date('%Y%m%d', a)

    local c = loadDay(hash, a)
    for _, e in ipairs(c.bySeg[seg] or {}) do out[#out + 1] = e end

    if os.date('%Y%m%d', b) ~= dayA then
        local c2 = loadDay(hash, b)
        for _, e in ipairs(c2.bySeg[seg] or {}) do out[#out + 1] = e end
    end

    table.sort(out, function(x, y) return x.startSec < y.startSec end)
    return out
end

--- Einen einzelnen Chunk anhand eines Get-Eintrags lesen (seek + read statt Vollscan).
function SegIndex.ReadChunk(playerHash, e)
    if not ready or type(e) ~= 'table' then return nil end
    local f = io.open(dayFile(playerHash & 0xFFFFFFFF, e.startSec), 'rb')
    if not f then return nil end

    if not f:seek('set', e.fileOff) then f:close(); return nil end
    local pre = f:read(4)
    if not pre or #pre < 4 then f:close(); return nil end

    -- Laengenpraefix MUSS dem gespeicherten len entsprechen; sonst hat sich die
    -- Datei unter dem Index veraendert (Retention/Neuaufbau) — nichts liefern.
    if string.unpack('<I4', pre) ~= e.len then f:close(); return nil end

    local data = f:read(e.len)
    f:close()
    if type(data) ~= 'string' or #data ~= e.len then return nil end
    return data
end

--- Alle Chunks eines Segments, fertig gelesen.
--- Rueckgabe wie Archive.ReadRange: Liste aus { startSec, data }.
function SegIndex.ReadSeg(playerHash, seg)
    local out = {}
    for _, e in ipairs(SegIndex.Get(playerHash, seg)) do
        local data = SegIndex.ReadChunk(playerHash, e)
        if data then out[#out + 1] = { startSec = e.startSec, data = data } end
    end
    return out
end

--- Belegung je Segment fuer die Zeitleiste, OHNE Nutzdaten zu lesen.
--- Rueckgabe: dichte Liste, Index i = Segment fromSeg + i - 1, je Eintrag
--- { n, bytes, parts }; leere Segmente bleiben als Luecke drin.
--- Zweiter Wert: { maxN, totalBytes, from, to } zum Skalieren.
function SegIndex.Bars(playerHash, fromSeg, toSeg)
    local bars, meta = {}, { maxN = 0, totalBytes = 0, from = fromSeg, to = toSeg }
    if not ready or not fromSeg or not toSeg or toSeg < fromSeg then return bars, meta end

    -- Deckel gegen einen Aufruf ueber Jahre: lieber ein gekuerztes Band.
    if (toSeg - fromSeg + 1) > MAX_BARS then
        toSeg   = fromSeg + MAX_BARS - 1
        meta.to = toSeg
        meta.truncated = true
    end

    -- Betroffene Tagesindizes EINMAL laden statt je Segment.
    local hash, days = playerHash & 0xFFFFFFFF, {}
    local first, last = SegIndex.SecOf(fromSeg), SegIndex.SecOf(toSeg) + segSeconds()
    local seen = {}
    for t = first, last, 86400 do
        local k = os.date('%Y%m%d', t)
        if not seen[k] then seen[k] = true; days[#days + 1] = loadDay(hash, t) end
    end
    local lastKey = os.date('%Y%m%d', last)
    if not seen[lastKey] then days[#days + 1] = loadDay(hash, last) end

    for seg = fromSeg, toSeg do
        local n, bytes, parts = 0, 0, 0
        for _, c in ipairs(days) do
            for _, e in ipairs(c.bySeg[seg] or {}) do
                n     = n + (e.nSamples or 0)
                bytes = bytes + (e.len or 0)
                parts = parts + 1
            end
        end
        bars[#bars + 1] = { n = n, bytes = bytes, parts = parts }
        if n > meta.maxN then meta.maxN = n end
        meta.totalBytes = meta.totalBytes + bytes
    end
    return bars, meta
end

-- ── Wiederaufbau ───────────────────────────────────────────────────────────

--- Passt der Index noch zur Nutzdatei? Vergleicht covered (bis wohin der Index
--- reicht) mit der .drps-Groesse. Zu kurz ist normal nach Absturz/Nachruesten.
function SegIndex.NeedsRebuild(playerHash, sec)
    if not ready then return false, 'nicht bereit' end
    local hash = playerHash & 0xFFFFFFFF
    local dSize = fileSize(dayFile(hash, sec))

    if dSize == 0 then
        -- 0-Byte-Tagesdatei ist normal nach Retention/Loeschen ohne os.remove.
        -- Ein zurueckgebliebener Index meldete darauf noch Treffer, muss also als
        -- aufbaubeduerftig gelten, damit Rebuild ihn entfernt.
        if fileSize(idxFile(hash, sec)) > 0 then
            return true, 'Tagesdatei leer, Index veraltet'
        end
        return false, 'keine Tagesdatei'
    end

    local c = loadDay(hash, sec)
    if c.bytes == 0 then return true, 'kein Index' end

    -- Toleranz von einem Chunk: zwischen Nutzdaten- und Indexschreiben laufen
    -- beide legitim um Praefix + einen ganzen Chunk auseinander. Mass ist der
    -- groesste bisher gesehene Chunk des Tages.
    local tolerance = 4 + (c.maxLen or 0)
    if c.covered + tolerance < dSize then
        return true, ('Index deckt %d von %d Byte'):format(c.covered, dSize)
    end
    return false, 'aktuell'
end

--- Der eigentliche Wiederaufbau, ausgelagert fuer den pcall in SegIndex.Rebuild.
--- Gibt (geschriebeneSaetze, fehlertext, tagesIndex) zurueck.
local function runRebuild(hash, sec, srcPath, dstPath)
    local recs, count, scanned = {}, 0, 0
    local err
    local grid = segSeconds()

    local f = io.open(srcPath, 'rb')
    if f then
        local size = f:seek('end') or 0
        f:seek('set', 0)
        -- Offsets sind u32; ein defektes Dateisystem darf hier keinen pack-Fehler
        -- ausloesen.
        if size > 0xFFFFFFFF then size = 0; err = 'Tagesdatei zu gross fuer u32-Offsets' end

        local off = 0
        while off + 4 <= size do
            local pre = f:read(4)
            if not pre or #pre < 4 then break end
            local len = string.unpack('<I4', pre)

            -- Unplausible Laenge: Rest der Datei nicht mehr vertrauenswuerdig.
            if len < HDR_LEN or len > MAX_CHUNK_BYTES or (off + 4 + len) > size then
                err = 'abgeschnitten oder beschaedigt ab Offset ' .. off
                break
            end

            local head = f:read(HDR_LEN)
            if not head or #head < HDR_LEN then break end
            local hdr = Protocol.DecodeChunkHeader(head)
            if hdr then
                count = count + 1
                recs[count] = string.pack(REC_FMT, REC_MAGIC, REC_VER,
                    SegIndex.SegOf(hdr.startSec) & 0xFFFFFFFF, off, len,
                    math.min(65535, math.max(0, toInt(hdr.nSamples, 0))),
                    toInt(hdr.startSec, 0) & 0xFFFFFFFF, grid, segEpoch())
            end

            off = off + 4 + len
            if not f:seek('set', off) then break end
            scanned = scanned + 1
            if scanned % SCAN_YIELD == 0 then Wait(0) end
        end
        f:close()
    else
        err = 'keine Tagesdatei'
    end

    -- Neu schreiben statt anhaengen (halber Index waere schlimmer als keiner),
    -- in Bloecken, damit der Thread abgibt.
    local written = 0
    if count > 0 then
        local out = io.open(dstPath, 'wb')
        if out then
            local failed = false
            local i = 1
            while i <= count do
                local j = math.min(i + SCAN_YIELD - 1, count)
                -- write und close pruefen, sonst gilt ein Torso als Erfolg.
                if not out:write(table.concat(recs, '', i, j)) then failed = true; break end
                written = j
                i = j + 1
                if i <= count then Wait(0) end
            end
            if not out:close() then failed = true end
            if failed then
                written = 0
                err = err or 'Index nicht vollstaendig schreibbar'
                dropIdxFile(dstPath)
            end
        else
            err = err or 'Index nicht schreibbar'
        end
    elseif fileSize(dstPath) > 0 then
        -- Kein Satz, aber eine Indexdatei da: Nutzdaten sind weg/gekuerzt. Index
        -- entfernen, sonst beauskunftet er Material, das es nicht mehr gibt.
        dropIdxFile(dstPath)
        err = err or 'Nutzdaten fehlen — Index entfernt'
    end

    -- Speichersicht verwerfen und aus dem frischen Stand neu aufbauen.
    local key = cacheKey(hash, sec)
    if cache[key] then cache[key] = nil; cacheN = cacheN - 1 end
    local c = loadDay(hash, sec)

    return written, err, c
end

--- Index einer Tagesdatei neu aufbauen. Laeuft KOOPERATIV in eigenem Thread:
--- je Chunk nur Praefix + Kopf lesen, Rest per seek ueberspringen, alle
--- SCAN_YIELD Chunks abgeben (synchron blockierte er den Serverstart).
--- onDone(anzahlSaetze, fehlertext) wird genau einmal gerufen.
function SegIndex.Rebuild(playerHash, sec, onDone)
    local function done(n, err)
        if type(onDone) == 'function' then pcall(onDone, n, err) end
    end
    if not ready then done(0, 'nicht bereit'); return false end

    local hash    = playerHash & 0xFFFFFFFF
    local srcPath = dayFile(hash, sec)
    local dstPath = idxFile(hash, sec)

    if building[dstPath] then done(0, 'laeuft bereits'); return false end
    building[dstPath] = true

    CreateThread(function()
        -- Rumpf in pcall: bricht er ohne diesen Rahmen ab, bleibt die Sperre je
        -- Tagesdatei dauerhaft stehen und onDone kommt nie.
        local ok, written, err, c = pcall(runRebuild, hash, sec, srcPath, dstPath)
        if not ok then
            -- Bei einem Fehlschlag traegt der zweite Rueckgabewert den Fehlertext.
            err     = 'Ausnahme im Wiederaufbau: ' .. tostring(written)
            written = 0
            c       = nil
        end

        building[dstPath] = nil

        -- Waehrend des Scans angefallene Saetze nachtragen; schon erfasste
        -- (fileOff unter der Scan-Grenze) verwerfen, sonst doppelt im Index.
        local q = pending[dstPath]
        pending[dstPath] = nil
        if q and #q > 0 then
            if c then
                -- Ueber appendRec (stellt die Satzgrenze her), nicht direkt an
                -- das echte Dateiende: ein Torso verschoebe sonst alle Folgesaetze.
                local okAll = true
                for _, p in ipairs(q) do
                    if p.fileOff >= c.covered then
                        if not appendRec(dstPath, p.rec) then okAll = false; break end
                        addEntry(c, p.seg, p.fileOff, p.len, p.nSamples, p.startSec)
                        c.bytes = c.bytes + REC_SIZE
                    end
                end
                if not okAll then err = err or 'Nachtrag unvollstaendig' end
            else
                -- Ohne gueltige Speichersicht nicht entscheidbar, was der Scan
                -- schon hat; verwerfen (zu kurz erkennt NeedsRebuild spaeter).
                err = (err or '') .. (' (%d Saetze verworfen)'):format(#q)
            end
        end

        if Config.Debug then
            print(('^5[D-RPS]^0 Segment-Index %s: %d Saetze%s'):format(
                dstPath:match('[^/]+$') or dstPath, written,
                err and (' (' .. err .. ')') or ''))
        end
        done(written, err)
    end)

    return true
end

--- Index nur aufbauen, wenn er fehlt oder zu kurz ist.
function SegIndex.Ensure(playerHash, sec, onDone)
    local need, why = SegIndex.NeedsRebuild(playerHash, sec)
    if not need then
        if type(onDone) == 'function' then pcall(onDone, 0, why) end
        return false
    end
    return SegIndex.Rebuild(playerHash, sec, onDone)
end

-- ── Loeschen ───────────────────────────────────────────────────────────────

--- Den Index EINES Tages entfernen (Loeschverlangen nach Art. 17). Der Index
--- nennt je Segment Zeitpunkt/Datenmenge/Anzahl, also personenbezogene Angaben,
--- und muss mit weg. Zeitraum identisch mit Archive.PurgeHash.
function SegIndex.ForgetDay(playerHash, sec)
    if not ready then return 0 end
    local hash = toInt(playerHash, -1)
    if hash < 0 then return 0 end
    hash = hash & 0xFFFFFFFF

    local path = idxFile(hash, sec)
    pending[path] = nil
    local key = cacheKey(hash, sec)
    if cache[key] then cache[key] = nil; cacheN = cacheN - 1 end
    return dropIdxFile(path) and 1 or 0
end

function SegIndex.Forget(playerHash)
    local hash    = playerHash & 0xFFFFFFFF
    local removed = 0

    if ready then
        local now = os.time()
        for d = 0, purgeDays() do
            local sec  = now - (d * 86400)
            local path = idxFile(hash, sec)
            -- Zurueckgestellte Saetze mit entfernen, sonst schriebe der Nachtrag
            -- den geloeschten Bestand zurueck.
            pending[path] = nil
            if dropIdxFile(path) then removed = removed + 1 end
        end
    end

    -- Speichersicht zuletzt, sonst liest ein Leser die Datei erneut ein.
    local suffix = ('%08x'):format(hash)
    for k in pairs(cache) do
        if k:sub(-#suffix) == suffix then cache[k] = nil; cacheN = cacheN - 1 end
    end

    return removed
end

-- ── Init ───────────────────────────────────────────────────────────────────

--- Ermittelt nur den Pfad und prueft die Schreibbarkeit. Nichts anlegen, nichts
--- scannen (welcher Tag/Spieler gebraucht wird, weiss erst der Leser via Ensure).
function SegIndex.Init()
    if not Config.DiskArchive then return false end

    -- Ohne Session keine Zeitachse; dann bedeutet eine Segmentnummer nichts.
    if not (Session and Session.Epoch and Session.SegOf) then
        print('^1[D-RPS] Segment-Index braucht server/session.lua — Ladereihenfolge im fxmanifest pruefen.^0')
        return false
    end

    basePath = GetResourcePath(RES):gsub('//+', '/') .. '/' .. Config.ArchivePath

    -- Schreibtest ueber eine modul-eigene Datei; archive/ kommt mit der Resource
    -- und laesst sich nicht anlegen (siehe archive.lua).
    local probe = basePath .. '/.segindex'
    local f = io.open(probe, 'ab')
    if not f then
        print('^3[D-RPS] Segment-Index nicht schreibbar — Archivzugriff faellt auf Vollscan zurueck.^0')
        return false
    end
    f:close()

    ready = true
    return true
end

return SegIndex
