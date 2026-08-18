--[[ ===========================================================================
    D-RPS — server/session.lua
    Gemeinsame Zeitachse (Epoche + Raster) fuer Segment-Streaming.

    Grundregeln:
    - Epoche liegt auf der Platte (archive/session.json); eine Segmentnummer ist
      nur mit ihrem Nullpunkt eine Zeitangabe. Eine vorhandene session.json wird
      NIE ueberschrieben, sonst zeigen alte Nummern nach einem Restart woandershin.
    - Zeitbasis ausschliesslich os.time() (Wanduhr). GetGameTimer (Uptime) nie
      mischen. Nur ganze Sekunden und //, damit Segmentnummern ganzzahlig und
      ueber Neustarts monoton bleiben.
=========================================================================== ]]

Session = {}

local RES = GetCurrentResourceName()
local basePath                     -- absoluter Pfad zu …/archive
local epoch    = nil               -- Unix-Sekunde, ab der gerechnet wird
local segSec   = nil               -- eingefrorene Rasterbreite dieses Laufs
local ready    = false
local durable  = false             -- Epoche liegt wirklich auf der Platte?

-- readState()-Ergebnis, einmal gemerkt: die Datei schreibt nur diese Resource,
-- erneutes Lesen bringt nichts.
local probeStatus  = nil
local probeInfo    = nil
local clockWarned  = false

-- Plausibilitaetsgrenzen fuer eine echte Wanduhr (2020-09-13 .. 2100-01-01).
-- Werte ausserhalb stammen aus halb geschriebener Datei oder ungesetzter Uhr.
local MIN_EPOCH = 1600000000
local MAX_EPOCH = 4102444800

-- Deckel fuer die Rasterbreite: unter 5s explodiert die Segmentzahl, ueber 1h
-- ist es kein Streaming mehr.
local MIN_SEG = 5
local MAX_SEG = 3600

local DAY = 86400

local function stateFile()
    return basePath .. '/session.json'
end

local function tmpFile()
    return basePath .. '/session.json.tmp'
end

local function badFile()
    return basePath .. '/session.json.bad'
end

-- ── Ganzzahligkeit ─────────────────────────────────────────────────────────
-- Nur math.tointeger sagt verlaesslich, ob ein Wert als Integer existiert; ein
-- Float knallt spaeter in string.format('%d', ...). Nicht Wandelbares wird
-- abgelehnt statt geraten.

local function toInt(v)
    local n = tonumber(v)
    if not n then return nil end
    if n ~= n then return nil end                      -- NaN
    if n == math.huge or n == -math.huge then return nil end
    return math.tointeger(math.floor(n))
end

-- ── Rasterbreite ───────────────────────────────────────────────────────────
-- Config.SegmentSeconds fehlt noch; bis dahin ist die Chunk-Laenge der Ersatz.

local function computeSeg()
    local C = Config or {}
    local v = toInt(C.SegmentSeconds) or toInt(C.DiskChunkSeconds) or 60
    if v < MIN_SEG then v = MIN_SEG end
    if v > MAX_SEG then v = MAX_SEG end
    return v
end

-- ── Uhr ────────────────────────────────────────────────────────────────────

--- Wanduhr, nur wenn glaubwuerdig. nil = vor NTP gebootet, os.time() unbrauchbar.
local function wallClock()
    local t = toInt(os.time())
    if not t or t < MIN_EPOCH or t > MAX_EPOCH then return nil end
    return t
end

--- Nullpunkt fuer einen frischen Start: Beginn des laufenden UTC-Tages (runde
--- Segmentgrenzen). nil, wenn die Uhr unbrauchbar ist.
local function freshEpoch()
    local now = wallClock()
    if not now then return nil end
    local e = (now // DAY) * DAY
    -- Tagesanfang kann unter MIN_EPOCH rutschen; hier anheben, sonst verwirft
    -- der eigene Leser die Epoche beim naechsten Start.
    if e < MIN_EPOCH then e = MIN_EPOCH end
    return toInt(e)
end

-- ── Persistenz ─────────────────────────────────────────────────────────────

--- Datei schreiben und zur Kontrolle zuruecklesen. write/close/Inhalt werden
--- geprueft, sonst bliebe eine volle Platte unbemerkt (Schreibfehler melden
--- sich erst bei close).
local function writeFile(path, data)
    local f, err = io.open(path, 'wb')
    if not f then return false, tostring(err) end

    local okw, werr = f:write(data)
    if not okw then
        pcall(f.close, f)
        return false, tostring(werr)
    end

    local okc, cerr = f:close()
    if not okc then return false, tostring(cerr) end

    local g = io.open(path, 'rb')
    if not g then return false, 'nach dem Schreiben nicht lesbar' end
    local back = g:read('*a')
    g:close()
    if back ~= data then return false, 'Inhalt weicht nach dem Zuruecklesen ab' end

    return true
end

--- Unbrauchbare Datei fuer die Fehlersuche sichern; Original bleibt liegen.
--- Vorhandene .bad nicht ueberschreiben (erste Fassung ist die aussagekraeftigste).
local function keepBad(raw)
    if type(raw) ~= 'string' or raw == '' then return false end
    local old = io.open(badFile(), 'rb')
    if old then old:close(); return false end
    return (writeFile(badFile(), raw))
end

--- Gespeicherte Epoche lesen. Rueckgabe: status, info
---   'missing' — keine lesbare Datei; frischer Start erlaubt.
---   'bad'     — Datei unplausibel; NICHT ueberschreiben (info.raw, info.why).
---   'ok'      — info.epoch gueltig; info.seg = Raster oder nil;
---               info.clockBack: Epoche liegt vor der Systemuhr.
local function readState()
    local f = io.open(stateFile(), 'rb')
    if not f then return 'missing' end

    local okr, raw = pcall(f.read, f, '*a')
    f:close()
    if not okr or type(raw) ~= 'string' then
        return 'bad', { raw = '', why = 'nicht lesbar' }
    end
    if raw == '' then
        -- 0 Byte = abgebrochener Schreibvorgang; nicht ueberschreiben (sonst aus
        -- "sichtbar kaputt" wird "unbemerkt verschoben").
        return 'bad', { raw = '', why = 'leere Datei' }
    end

    local okj, obj = pcall(json.decode, raw)
    if not okj or type(obj) ~= 'table' then
        return 'bad', { raw = raw, why = 'kein gueltiges JSON' }
    end

    local e = toInt(obj.epoch)
    if not e then
        return 'bad', { raw = raw, why = 'epoch fehlt oder ist keine ganze Zahl' }
    end
    if e < MIN_EPOCH or e > MAX_EPOCH then
        return 'bad', { raw = raw, why = ('epoch %s ausserhalb der Grenzen'):format(tostring(obj.epoch)) }
    end

    -- Epoche in der Zukunft ist KEIN Verwerfungsgrund: meist eine zurueckgestellte
    -- Uhr, dann ist die gespeicherte Zeitachse die richtige.
    local now = toInt(os.time())
    local info = { epoch = e, raw = raw, now = now, clockBack = (now ~= nil and e > now) }

    -- obj.seg genauso hart pruefen wie die Epoche (landet in string.format('%d')).
    if obj.seg ~= nil then
        local s = toInt(obj.seg)
        if s and s >= MIN_SEG and s <= MAX_SEG then
            info.seg = s
        else
            info.segBad = true
        end
    end

    return 'ok', info
end

--- Epoche schreiben. Einziger truncierende Schreibvorgang im Projekt, daher der
--- Umweg ueber eine Nebendatei (schreiben, zuruecklesen, umbenennen). os.rename
--- kann fehlen, deshalb ein Rueckfall.
local function writeState(e, seg)
    e   = toInt(e)
    seg = toInt(seg)
    if not e or not seg then return false end

    -- os.date kann werfen; der Zeitstempel ist nur Lesehilfe, darf das Schreiben
    -- nicht verhindern.
    local okd, created = pcall(os.date, '!%Y-%m-%dT%H:%M:%SZ', e)
    if not okd or type(created) ~= 'string' then created = '' end

    local ok, line = pcall(json.encode, {
        epoch   = e,
        seg     = seg,
        created = created,   -- nur Lesehilfe; gerechnet wird mit epoch
    })
    if not ok or type(line) ~= 'string' or line == '' then return false end

    local final = stateFile()
    local tmp   = tmpFile()

    local okTmp, tmpErr = writeFile(tmp, line)
    if not okTmp then
        -- session.json wurde bis hier nicht angefasst.
        print(('^1[D-RPS] session.json.tmp nicht schreibbar (%s) — Zeitachse bleibt wie sie war.^0')
            :format(tostring(tmpErr)))
        return false
    end

    local renamed = false
    if type(os.rename) == 'function' then
        -- pcall, weil os.rename hier eine wirkungslose Attrappe sein kann.
        local pok, rok = pcall(os.rename, tmp, final)
        if pok and rok then
            renamed = true
            local check = io.open(final, 'rb')
            if check then
                local back = check:read('*a')
                check:close()
                if back == line then return true end
            end
        end
    end

    -- Nach gelungenem Umbenennen ist die Nebendatei weg; der Rueckfall unten
    -- wuerde die korrekt geschriebene session.json truncierend oeffnen und bei
    -- voller Platte als 0-Byte zuruecklassen. Also nicht anfassen.
    if renamed then
        print('^1[D-RPS] session.json nach dem Umbenennen nicht wie geschrieben lesbar.^0')
        print('^1        Die Datei wird NICHT ueberschrieben — bitte von Hand pruefen.^0')
        return false
    end

    -- Rueckfall ohne rename. Vertretbar, weil der geprueft geschriebene Inhalt
    -- noch in der Nebendatei liegt.
    local okFin, finErr = writeFile(final, line)
    if okFin then
        if type(os.remove) == 'function' then pcall(os.remove, tmp) end
        return true
    end

    print(('^1[D-RPS] session.json nicht schreibbar (%s).^0'):format(tostring(finErr)))
    print(('^1        Geprueft geschriebene Fassung liegt unter %s — von Hand umbenennen.^0'):format(tmp))
    return false
end

-- ── API ────────────────────────────────────────────────────────────────────

--- Epoche laden oder anlegen. Mehrfachaufruf ist unschaedlich.
function Session.Init()
    if ready then return epoch end

    segSec = computeSeg()

    -- Ohne Disk-Archiv gibt es keinen Ordner fuer die Epoche.
    if not (Config and Config.DiskArchive) then
        epoch   = freshEpoch() or MIN_EPOCH
        durable = false
        ready   = true
        print('^3[D-RPS] Disk-Archiv aus — Epoche gilt nur fuer diesen Lauf, '
            .. 'Segmentnummern sind nach einem Restart bedeutungslos.^0')
        return epoch
    end

    -- Nur einmal ermitteln (Init() laeuft mehrfach, solange auf die Uhr gewartet wird).
    if not basePath then
        basePath = GetResourcePath(RES):gsub('//+', '/') .. '/' .. Config.ArchivePath
    end

    if not probeStatus then
        probeStatus, probeInfo = readState()
    end
    local status, info = probeStatus, probeInfo

    if status == 'ok' then
        epoch   = info.epoch
        durable = true
        ready   = true

        if info.clockBack then
            -- Nicht korrigieren: die Datei ist der Massstab, die Uhr holt auf.
            print(('^3[D-RPS] Systemuhr (%d) liegt vor der gespeicherten Epoche (%d) zurueck.^0')
                :format(info.now or 0, epoch))
            print('^3        Zeit/NTP pruefen. Die Datei bleibt gueltig und wird nicht angefasst.^0')
        end

        if info.segBad then
            -- Epoche ist in Ordnung; seg-Feld unbrauchbar. Datei nicht anfassen.
            print(('^3[D-RPS] session.json: seg-Feld unbrauchbar (erwartet: ganze Zahl %d..%d).^0')
                :format(MIN_SEG, MAX_SEG))
            print('^3        Rasterwechsel bleibt unbemerkt; Datei wird nicht veraendert.^0')
        elseif info.seg == nil then
            -- Aeltere Datei ohne Feld. Nicht nachtragen: eine GUELTIGE session.json
            -- wird nie ueberschrieben (Abbruch beim truncierenden Schreiben = Verlust).
            print('^3[D-RPS] session.json ohne seg-Feld (aeltere Fassung).^0')
            print('^3        Ein spaeterer Rasterwechsel bleibt unbemerkt. Datei bleibt unveraendert.^0')
        elseif info.seg ~= segSec then
            -- Geaenderte Rasterbreite verschiebt die Segmentgrenzen; nur melden,
            -- nicht schreiben. Alte Nummern meinen danach andere Sekunden.
            print(('^3[D-RPS] Segmentraster geaendert: %ds → %ds. Bereits vergebene '
                .. 'Segmentnummern beziehen sich auf das alte Raster.^0')
                :format(info.seg, segSec))
            print('^3        Der Segment-Index verwirft betroffene Tagesindizes selbst.^0')
        end

        return epoch
    end

    if status == 'bad' then
        -- Bewusst NICHT schreiben: eine frische Epoche widerspraeche allem, was
        -- unter der alten Nummerierung schon im Archiv liegt.
        print(('^1[D-RPS] session.json unbrauchbar (%s) — Zeitachse wird NICHT neu festgeschrieben.^0')
            :format(tostring(info and info.why or '?')))
        print(('^1        Original bleibt unveraendert: %s^0'):format(stateFile()))
        if keepBad(info and info.raw) then
            print(('^1        Kopie zur Ansicht: %s^0'):format(badFile()))
        end
        print('^1        Bis die Datei repariert oder entfernt ist, gilt eine fluechtige Epoche —^0')
        print('^1        Segmentnummern dieses Laufs passen nicht zu frueher geschriebenen.^0')

        epoch   = freshEpoch() or MIN_EPOCH
        durable = false
        ready   = true
        return epoch
    end

    -- status == 'missing': erster Start, Zeitachse anlegen.
    local fresh = freshEpoch()
    if not fresh then
        -- Uhr ungesetzt: nicht festschreiben (der eigene Leser verwuerfe den Wert
        -- naechsten Start). Start verschieben; ready bleibt false, naechster Aufruf
        -- versucht es erneut.
        if not clockWarned then
            clockWarned = true
            print(('^1[D-RPS] Systemuhr unplausibel (os.time() = %s) — Zeitachse noch nicht '
                .. 'festgeschrieben.^0'):format(tostring(os.time())))
            print('^1        Wird nachgeholt, sobald NTP die Uhr gesetzt hat; bis dahin sind '
                .. 'Segmentnummern fluechtig.^0')
        end
        epoch   = MIN_EPOCH   -- Platzhalter, haelt Rechenwege ganzzahlig
        durable = false
        return epoch
    end

    epoch   = fresh
    durable = writeState(epoch, segSec)
    ready   = true
    if not durable then
        -- Ohne Datei beginnt der naechste Start eine neue Zeitachse; laut melden.
        print('^1[D-RPS] session.json nicht schreibbar — Zeitachse gilt nur bis '
            .. 'zum naechsten Restart.^0')
        print('^1        archive/-Ordner pruefen; Segment-Nachladen ist danach unzuverlaessig.^0')
    end

    return epoch
end

--- Init nachziehen, falls die Ladereihenfolge main.lua noch nicht drankommen liess.
local function ensure()
    if not ready then Session.Init() end
    -- MIN_EPOCH statt 0: Epoche 0 erzeugte unbrauchbar grosse Segmentnummern.
    return epoch or MIN_EPOCH
end

--- Unix-Sekunde, ab der gerechnet wird.
function Session.Epoch()
    return ensure()
end

--- Rasterbreite in Sekunden. Nach Init eingefroren (Aenderung im Lauf braeche
--- die Nummerierung schon geschriebener Segmente).
function Session.SegSeconds()
    return segSec or computeSeg()
end

--- Segmentnummer zu einer Unix-Sekunde. Zeitpunkte vor der Epoche und nicht
--- ganzzahlige Eingaben landen bewusst in Segment 0 (keine negativen Nummern).
function Session.SegOf(sec)
    local e = ensure()
    local s
    if sec == nil then s = toInt(os.time()) else s = toInt(sec) end
    if not s or s <= e then return 0 end
    return toInt((s - e) // Session.SegSeconds()) or 0
end

--- Startsekunde eines Segments. Umkehrung von SegOf bis auf die Rasterbreite.
function Session.SecOf(seg)
    local e = ensure()
    local w = Session.SegSeconds()
    local n = toInt(seg) or 0
    if n < 0 then n = 0 end
    -- Deckel gegen Integer-Ueberlauf: e + n * w liefe bei absurder Nummer ins
    -- Negative.
    local nMax = (MAX_EPOCH - e) // w
    if n > nMax then n = nMax end
    return toInt(e + n * w) or e
end

--- Aktuelles Segment.
function Session.NowSeg()
    return Session.SegOf(os.time())
end

--- Sekunden seit der Epoche. Gleiche Klammerung wie SegOf (konsistente Einordnung).
function Session.Rel(sec)
    local e = ensure()
    local s
    if sec == nil then s = toInt(os.time()) else s = toInt(sec) end
    if not s or s <= e then return 0 end
    return s - e
end

return Session
