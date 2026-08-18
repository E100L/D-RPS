--[[ D-RPS — server/archive.lua
     Disk-Persistenz des 24h-Vollarchivs. Ordner lassen sich zur Laufzeit nicht
     anlegen (os.execute wirkungslos) -> EINE Append-Datei pro Spieler pro Tag im
     mitgelieferten archive/-Ordner; io.open('ab') braucht absoluten Pfad.
     Dateiformat: Folge von [u32 chunkLen][chunk bytes], sequenziell parsbar,
     crash-tolerant (abgeschnittener letzter Chunk beschaedigt vorherige nicht). ]]

Archive = {}

local RES     = GetCurrentResourceName()
local basePath                    -- absoluter Pfad zu …/archive
local canRemove = false           -- os.remove nutzbar? (fuer Retention)
local ready     = false

local function dayFile(playerHash, sec)
    return ('%s/%s_%08x.drps'):format(basePath, os.date('%Y%m%d', sec), playerHash & 0xFFFFFFFF)
end

-- ── Init: Pfad ermitteln, Schreibbarkeit + os.remove pruefen ───────────────
function Archive.Init()
    if not Config.DiskArchive then
        print('^3[D-RPS] Disk-Archiv deaktiviert (Config.DiskArchive = false)^0')
        return false
    end

    local abs = GetResourcePath(RES):gsub('//+', '/')
    basePath  = abs .. '/' .. Config.ArchivePath

    -- Schreibtest im archive/-Ordner
    local testPath = basePath .. '/.writetest'
    local f, err = io.open(testPath, 'wb')
    if not f then
        print(('^1[D-RPS] Archiv NICHT schreibbar: %s^0'):format(tostring(err)))
        print('^1        archive/-Ordner fehlt? Er muss mit dem Resource ausgeliefert werden.^0')
        print('^1        Fallback: nur RAM-Ring (Config.DiskArchive intern false).^0')
        Config.DiskArchive = false
        return false
    end
    f:write('ok'); f:close()

    -- os.remove fuer Retention testen
    canRemove = (type(os.remove) == 'function') and pcall(os.remove, testPath) and true or false
    if not canRemove then
        -- Testdatei leeren, falls remove nicht ging
        local g = io.open(testPath, 'wb'); if g then g:write(''); g:close() end
    end

    ready = true
    print(('^2[D-RPS] Disk-Archiv bereit: %s^0'):format(basePath))
    print(('^2[D-RPS] Retention/os.remove: %s^0'):format(
        canRemove and 'verfuegbar' or '^3nicht verfuegbar — Auto-Loeschung eingeschraenkt^0'))
    return true
end

-- ── Schreiben: geschlossenen Chunk an Tagesdatei anhaengen ─────────────────
--- Rueckgabe: ok, fileOff. Offset = Byteposition des LAENGEN-PRAEFIXES (nicht
--- der Chunk-Bytes), damit der Leser das Praefix gegen die erwartete Laenge
--- pruefen kann und ein veralteter Index nichts statt Fremdbytes liefert.
function Archive.WriteChunk(playerHash, startSec, chunkStr)
    if not ready or not Config.DiskArchive then return false end

    local f, err = io.open(dayFile(playerHash, startSec), 'ab')
    if not f then
        if Config.Debug then print(('^1[D-RPS] Archiv-Append fehlgeschlagen: %s^0'):format(tostring(err))) end
        return false
    end

    -- Offset per seek, nicht ueber mitgefuehrten Zaehler: der ueberlebt keinen
    -- Resource-Restart und der Index zeigte dann still auf falsche Bytes.
    local off = f:seek('end')

    -- Laengen-Praefix + Chunk (sequenzielle Trennung beim Lesen)
    local okW = f:write(string.pack('<I4', #chunkStr))
    if okW then okW = f:write(chunkStr) end
    local okC = f:close()
    if not okW or not okC then return false end

    return true, off
end

-- ── Lesen: Tagesdatei in einzelne Chunks zerlegen ─────────────────────────

--- Alle Chunks einer Tagesdatei, optional auf ein Zeitfenster begrenzt.
function Archive.ReadDayFile(playerHash, sec, fromSec, toSec)
    local path = dayFile(playerHash, sec)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a'); f:close()

    local chunks, pos, n = {}, 1, #data
    while pos + 4 <= n + 1 do
        local len = string.unpack('<I4', data, pos)
        pos = pos + 4
        if pos + len - 1 > n then break end          -- abgeschnittener letzter Chunk
        local chunk = data:sub(pos, pos + len - 1)
        pos = pos + len

        if fromSec then
            -- Nur den Kopf lesen (billig)
            local hdr = Protocol.DecodeChunkHeader(chunk)
            if hdr then
                local endSec = hdr.startSec + Config.DiskChunkSeconds
                if endSec >= fromSec and hdr.startSec <= toSec then
                    chunks[#chunks + 1] = { startSec = hdr.startSec, data = chunk }
                end
            end
        else
            chunks[#chunks + 1] = chunk
        end
    end
    return chunks
end

--- Chunks eines Spielers fuer ein Zeitfenster, ueber Tagesgrenzen hinweg.
--- Gibt eine Liste { startSec, data } in chronologischer Reihenfolge zurueck.
function Archive.ReadRange(playerHash, fromSec, toSec)
    if not ready or not Config.DiskArchive then return {} end

    local out = {}
    -- Ueber Mitternacht: Start einen Tag VOR fromSec, da ein um 23:59:30
    -- begonnener Chunk in den Folgetag reicht, aber in der Vortagsdatei steht.
    local seen = {}
    for t = fromSec - 86400, toSec + 86400, 86400 do
        local day = os.date('%Y%m%d', t)
        if not seen[day] then
            seen[day] = true
            local part = Archive.ReadDayFile(playerHash, t, fromSec, toSec)
            if part then for _, c in ipairs(part) do out[#out + 1] = c end end
        end
        if t > toSec then break end
    end
    table.sort(out, function(a, b) return a.startSec < b.startSec end)
    return out
end

-- ── Fidelity-Strom ─────────────────────────────────────────────────────────
-- Eigene Endung (.fid), damit Beweis- und Optikdaten auf der Platte getrennt
-- bleiben (nur .drps kopieren = nur Beweismaterial).

local function fidFile(playerHash, sec)
    return ('%s/%s_%08x.fid'):format(basePath, os.date('%Y%m%d', sec),
        playerHash & 0xFFFFFFFF)
end

function Archive.WriteFidelity(playerHash, startSec, chunkStr)
    if not ready or not Config.DiskArchive then return false end
    local f = io.open(fidFile(playerHash, startSec), 'ab')
    if not f then return false end
    f:write(string.pack('<I4', #chunkStr))
    f:write(chunkStr)
    f:close()
    return true
end

--- Fidelity-Chunks eines Zeitfensters, ueber Tagesgrenzen hinweg.
function Archive.ReadFidelityRange(playerHash, fromSec, toSec)
    if not ready or not Config.DiskArchive then return {} end

    local out, seen = {}, {}
    for t = fromSec - 86400, toSec + 86400, 86400 do
        local day = os.date('%Y%m%d', t)
        if not seen[day] then
            seen[day] = true
            local f = io.open(fidFile(playerHash, t), 'rb')
            if f then
                local data = f:read('*a'); f:close()
                local pos, n = 1, #data
                while pos + 4 <= n + 1 do
                    local len = string.unpack('<I4', data, pos)
                    pos = pos + 4
                    if pos + len - 1 > n then break end
                    local chunk = data:sub(pos, pos + len - 1)
                    pos = pos + len
                    local hdr = Fidelity.DecodeChunkHeader(chunk)
                    if hdr and hdr.startSec + Config.DiskChunkSeconds >= fromSec
                       and hdr.startSec <= toSec then
                        out[#out + 1] = { startSec = hdr.startSec, data = chunk }
                    end
                end
            end
        end
        if t > toSec then break end
    end
    table.sort(out, function(a, b) return a.startSec < b.startSec end)
    return out
end

-- ── Retention: Tagesdateien aelter als Config.RetentionDays loeschen ───────
-- Ohne readdir gezielt nach Datum loeschen (~90 Tage abgedeckt). Hash-Liste aus
-- dem Sitzungs-Index, nicht dem Recorder — sonst nur die gerade Verbundenen.

--- Datei entfernen; geht os.remove nicht (Hoster sperren es teils), auf 0 Byte
--- kuerzen statt nichts zu tun (zugesagte Loeschfrist).
local function dropFile(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    f:close()

    if canRemove and pcall(os.remove, path) then return true end
    local g = io.open(path, 'wb')
    if g then g:write(''); g:close(); return true end
    return false
end

function Archive.Purge(knownHashes)
    if not ready or Config.RetentionDays <= 0 then return 0 end
    local removed = 0
    for d = Config.RetentionDays + 1, Config.RetentionDays + 90 do
        local sec = os.time() - (d * 86400)
        for h in pairs(knownHashes or {}) do
            -- Beide Stroeme (.drps Beweis, .fid Optik) tragen denselben Personenbezug.
            if dropFile(dayFile(h, sec)) then removed = removed + 1 end
            if dropFile(fidFile(h, sec)) then removed = removed + 1 end
            -- Szenenspur (Clientsicht): gleicher Personenbezug, gleiche Frist.
            if Scene and Scene.FileOf and dropFile(Scene.FileOf(h, sec)) then
                removed = removed + 1
            end
            -- Segment-Index mit weg, sonst beauskunftet er geloeschtes Material.
            if SegIndex and SegIndex.Forget then
                removed = removed + (SegIndex.ForgetDay(h, sec) or 0)
            end
        end
    end
    return removed
end

--- Alles zu einem Pseudonym entfernen (Loeschverlangen Art. 17), ueber den
--- gesamten abgedeckten Zeitraum.
function Archive.PurgeHash(playerHash)
    if not ready then return 0 end
    local removed = 0
    for d = 0, Config.RetentionDays + 95 do
        local sec = os.time() - (d * 86400)
        if dropFile(dayFile(playerHash, sec)) then removed = removed + 1 end
        if dropFile(fidFile(playerHash, sec)) then removed = removed + 1 end
        if Scene and Scene.FileOf and dropFile(Scene.FileOf(playerHash, sec)) then
            removed = removed + 1
        end
    end
    return removed
end

return Archive
