--[[ D-RPS — client/segments.lua
     Segment-Cache des Clients: haelt nur das sichtbare Zeitfenster im Speicher
     und laedt beim Scrubben nach. Zeitachse aus dem Manifest (Sekunden seit
     m.epoch); Dekodieren laeuft budgetiert in Pump, nie im Ereignis-Handler.
     Zustaende als parallele Zahlenarrays je Spieler (sT, sX, …), nicht als
     Tabellen-Liste. Uebertragungseinheit ist der einzelne Chunk (Vertrag v3);
     Vollstaendigkeit gegen sent, nicht aus bars. 'gap' = echte Abwesenheit,
     'stale' = laedt noch — im Zweifel 'stale'.
     Clientseitig kein os/io: Zeit nur aus GetGameTimer() (Zeitspannen), Wanduhr
     steckt in m.epoch und wird nie mit ihr verrechnet. ]]

Segments = {}

local floor = math.floor
local ceil  = math.ceil

-- ── Feste Groessen ─────────────────────────────────────────────────────────

-- Belegungszeichen eines Segments im bars-String. Als Byte verglichen (string.sub
-- erzeugt je Aufruf ein Objekt, laeuft je Spieler und Bild).
local B_NONE = 46    -- '.'  kein Material
local B_EV   = 101   -- 'e'  nur Evidence
local B_FID  = 102   -- 'f'  nur Fidelity
local B_BOTH = 98    -- 'b'  beides

-- Ab diesem Sprung des Abspielkopfs wird eine Anforderung entprellt (darueber ist
-- es kein Abspielen mehr, sondern ein Ziehen im Datenband).
local SEEK_JUMP_SECONDS = 1.0

-- Wie lange ein Fidelity-Zustand nach vorn gilt; ohne die Grenze traegt ein alter
-- Zustand ueber eine Stromluecke hinweg.
local FID_MAX_AGE = 1.5

-- Kuerzester Chunk (Kopflaenge), den die Dekoder annehmen.
local MIN_CHUNK = 14

-- Notbremse gegen einen nicht endenden Server: mehr Chunks nimmt ein Segment
-- nicht an, es wird dann als 'capped' gefuehrt.
local MAX_SEG_ITEMS = 4096

-- Fehlversuche je Segment bis 'void'. Ein 'void' wird nur durch neues Manifest
-- oder Sprung (clearWindow) wieder scharf gestellt.
local MAX_TRIES = 3

-- Ruhezeit eines Segments nach Absage/unvollstaendiger Lieferung, bevor der Planer
-- es erneut anbietet.
local RETRY_DEFER_MS = 750

-- Deckel fuer Coverage(): ein ueber Stunden gespannter Aufruf darf den Bildthread
-- nicht anhalten.
local MAX_COVER = 8192

-- Feldnamen der Zahlenarrays. Nur fuer die generischen Verschiebungen; der
-- Dekodierpfad schreibt direkt.
local EV_KEYS = {
    'sT', 'sX', 'sY', 'sZ', 'sHeading', 'sHealth', 'sArmour', 'sFlags',
    'sVehModel', 'sVehSeat', 'sCamYaw', 'sBlend', 'sSteer', 'sSpeed',
    'sVPitch', 'sVRoll',
}
local FID_KEYS = {
    'fT', 'fFlags', 'fCamYaw', 'fCamPitch', 'fBlend', 'fHeading',
    'fSteer', 'fVFlags', 'fWeapon', 'fAmmo',
}

-- Vorgaenger des ersten Samples eines Chunks; ApplyStep liest nur daraus, der
-- erste Sample ist Keyframe und ruehrt ihn nicht an.
local EMPTY = {}

-- ── Zustand ────────────────────────────────────────────────────────────────

local man      = nil        -- geprueftes Manifest
local epoch    = 0
local segSec   = 15
local firstSeg = 0
local lastSeg  = 0
local spanSegs = 1          -- Reichweite eines Altbestand-Chunks in Segmenten

local players  = {}         -- [hash] = Spielersatz
local order    = {}         -- stabile Reihenfolge fuer die Oberflaeche

local loadedFrom, loadedTo = nil, nil     -- zusammenhaengendes Fenster
local segHave  = {}         -- [seg] = { ev, fid, capped, void }
local segTry   = {}         -- [seg] = Zahl der Fehlversuche
local segDefer = {}         -- [seg] = Zeitpunkt, ab dem wieder gefragt wird
local busy     = {}         -- [seg] = true, solange dekodiert wird

local inflight  = {}        -- [seg] = { at, rid }
local inflightN = 0

-- Anfragekennung: EIN Zaehler ueber die gesamte Ressourcenlaufzeit. Ein je Segment
-- neu beginnender Zaehler liesse eine Nachricht der vorigen Sitzung auf die erste
-- Anfrage der neuen passen.
local ridSeq   = 0

-- Warteschlangen mit ausdruecklichem Schwanzzeiger: Eintraege werden beim
-- Abarbeiten auf nil gesetzt, '#' ist bei Loechern am Anfang nicht verlaesslich.
local rawQ, rawHead, rawTail = {}, 1, 0   -- rohe Nachrichten
local jobWait = {}          -- [seg] = wie oft zurueckgestellt (Warteablage)
-- Wie oft ein Segment auf seine Luecke warten darf, bevor das Fenster weicht.
local JOB_REQUEUE_MAX = 4
local pend     = {}         -- [seg] = { rid, list, sent, missing, capped, over }
local jobQ, jobHead, jobTail = {}, 1, 0   -- fertige Segmente, bereit zum Dekodieren
local job      = nil        -- laufender Dekodierauftrag

-- Entdopplung: keySeg = welches Segment haelt einen Chunk, segKeys = Gegenrichtung
-- fuer die Freigabe bei Verdraengung.
local keySeg   = {}         -- ['kind:hash:start'] = seg
local segKeys  = {}         -- [seg] = Liste seiner Schluessel

local headT    = 0.0        -- zuletzt abgefragter Abspielkopf
local headDir  = 1
local settleAt = 0          -- Entprellung: vorher wird nichts angefordert

-- ── Kleinkram ──────────────────────────────────────────────────────────────

local function toInt(v)
    local n = tonumber(v)
    if not n or n ~= n then return nil end
    if n == math.huge or n == -math.huge then return nil end
    return math.tointeger(floor(n))
end

--- Config-Wert, der positiv sein muss; faellt bei fehlend/verstellt auf dflt.
local function cfg(key, dflt)
    local v = tonumber(Config and Config[key])
    if not v or v ~= v or v <= 0 then return dflt end
    return v
end

--- Zeitablauf einer Anforderung. Muss ueber der laengsten Wartezeit der Gegenseite
--- liegen, sonst wird die gerade bearbeitete Anfrage abgeraeumt; Ablauf ist kein
--- Schaden (Vertrag idempotent, Anfrage wird wiederholt).
local function reqTimeout()
    return cfg('SegmentTimeoutMs', 20000)
end

local function segOf(t)
    local n = floor((tonumber(t) or 0) / segSec)
    return math.tointeger(n) or 0
end

--- Zeichen eines Segments in einem Belegungs-String. Ausserhalb des Manifests gilt
--- "kein Material" (nie "laedt noch", sonst wartet der Abspielkopf dauerhaft).
local function barAt(s, seg)
    if not s then return B_NONE end
    local k = seg - firstSeg + 1
    if k < 1 or k > #s then return B_NONE end
    return string.byte(s, k) or B_NONE
end

-- v3: Vollstaendigkeit gegen sent, nicht aus p.bars. bars bleibt Anzeigegroesse.

--- Was in diesem Segment liegen KANN, inkl. hereinreichender Altbestand-Chunks.
--- Nur dieser Wert darf ueber 'gap' entscheiden (entschaerft Luecke zu 'stale',
--- behauptet nie eine Anwesenheit, die das Band nicht kennt).
local function touchByte(p, seg)
    return barAt(p.touch, seg)
end

-- ── Entdopplung ────────────────────────────────────────────────────────────

--- Einen Chunk fuer ein Segment beanspruchen. Erst wenn die Samples wirklich in
--- den Arrays liegen. Rueckgabe false = schon bekannt.
local function claimKey(seg, key)
    if keySeg[key] then return false end
    keySeg[key] = seg
    local L = segKeys[seg]
    if not L then L = {} segKeys[seg] = L end
    L[#L + 1] = key
    return true
end

--- Alle Schluessel eines Segments freigeben. Der Besitzvergleich noetig: nach
--- clearWindow kann der Schluessel schon einem anderen Segment gehoeren.
local function releaseKeys(seg)
    local L = segKeys[seg]
    if not L then return end
    for i = 1, #L do
        if keySeg[L[i]] == seg then keySeg[L[i]] = nil end
    end
    segKeys[seg] = nil
end

-- ── Spielersatz ────────────────────────────────────────────────────────────

--- Leerer Satz Zahlenarrays (Spieler und Voranstell-Zwischenspeicher, gleiche
--- Feldnamen, damit der Dekodierpfad nicht unterscheiden muss).
local function newArrays(into)
    into = into or {}
    for i = 1, #EV_KEYS  do into[EV_KEYS[i]]  = {} end
    for i = 1, #FID_KEYS do into[FID_KEYS[i]] = {} end
    into.n, into.fn = 0, 0
    return into
end

--- Verbreiterte Belegung aufbauen: die Reichweite eines Altbestand-Chunks nach
--- hinten in touch eintragen. Einmal je Manifest, linear ueber das Band.
local function buildTouch(p)
    local b = p.bars
    local n = #b
    if n == 0 then p.touch = '' return end

    local out, lastE, lastF = {}, nil, nil
    for k = 1, n do
        local c = string.byte(b, k)
        if c == B_EV  or c == B_BOTH then lastE = k end
        if c == B_FID or c == B_BOTH then lastF = k end
        local e = (lastE ~= nil) and (k - lastE) <= spanSegs
        local f = (lastF ~= nil) and (k - lastF) <= spanSegs
        out[k] = e and (f and 'b' or 'e') or (f and 'f' or '.')
    end
    p.touch = table.concat(out)
end

--- hash kommt geprueft (als Integer) herein: Ablage und Serverantworten bilden
--- ueber toInt auf denselben Wert ab.
local function newPlayer(e, hash)
    local p = newArrays({
        hash   = hash,
        id     = toInt(e.id),
        name   = type(e.name) == 'string' and e.name
                 or ('#%08x'):format(hash & 0xFFFFFFFF),
        online = e.online and true or false,
        model  = toInt(e.model) or 0,
        appearance = type(e.appearance) == 'table' and e.appearance or nil,
        spans  = type(e.spans) == 'table' and e.spans or {},
        bars   = type(e.bars) == 'string' and e.bars or '',
        -- Index nicht aufbaubar: leeres Band ist Aussage ueber den Index, nicht
        -- ueber Material — nie Abwesenheit melden. Beide Namen: 'unknown' intern,
        -- 'barsUnknown' aus dem Manifest (playback.lua liest das Manifestfeld).
        unknown     = e.barsUnknown and true or false,
        barsUnknown = e.barsUnknown and true or false,
        cnt    = {},      -- [seg] = Anzahl Evidence-Samples (nil = nicht geladen)
        fcnt   = {},      -- [seg] = Anzahl Fidelity-Samples
        -- [seg] = true, wenn die Lieferung fuer diesen Spieler hinter sent
        -- zurueckblieb. cnt bleibt exakt (Verdraengung rechnet damit), nur die
        -- Anzeige darf keine Abwesenheit behaupten.
        miss   = {},
        idx    = 1,       -- Suchzeiger Evidence
        fidx   = 1,       -- Suchzeiger Fidelity
        -- Platz des offenen Chunks: Startsekunde, Samples am ENDE der Arrays,
        -- bringendes Segment.
        openStart = nil,
        openN     = 0,
        openSeg   = nil,
    })
    buildTouch(p)
    return p
end

-- ── Chunk-Kopf ─────────────────────────────────────────────────────────────

--- Kopf eines Chunks an beliebiger Stelle lesen. DecodeChunkHeader liest nur ab
--- Position 1; da ein Datenblock mehrere Chunks enthalten kann, wird je weiterem
--- Kopf ein kurzes Stueck herausgeschnitten (ein Objekt je Chunk, nicht je Sample).
local function readEvHeader(data, pos)
    local head = (pos == 1) and data or string.sub(data, pos, pos + 31)
    local hdr, hp = Protocol.DecodeChunkHeader(head)
    if type(hdr) ~= 'table' or type(hp) ~= 'number' then return nil end
    return hdr, pos + (hp - 1)
end

local function readFidHeader(data, pos)
    local head = (pos == 1) and data or string.sub(data, pos, pos + 31)
    local hdr, hp = Fidelity.DecodeChunkHeader(head)
    if type(hdr) ~= 'table' or type(hp) ~= 'number' then return nil end
    return hdr, pos + (hp - 1)
end

-- ── Dekodierung ────────────────────────────────────────────────────────────
-- Direkt in die Zahlenarrays des Ziels; keine Tabelle je Sample. ApplyStep legt
-- zwar intern je Sample eine Tabelle an, die wird sofort ausgelesen und nur als
-- Vorgaenger des naechsten Deltas gehalten (immer genau eine am Leben).

--- Rueckgabe: Anzahl uebernommener Samples.
local function decodeEv(tg, data)
    if type(data) ~= 'string' or #data < MIN_CHUNK then return 0 end
    local n0 = tg.n

    -- pcall: beschaedigte Bytes werfen in string.unpack. tg.n wird erst NACH
    -- einem vollstaendigen Chunk gesetzt (halbe Slots liegen oberhalb der Laenge).
    pcall(function()
        local len, pos = #data, 1
        local T, X, Y, Z, H   = tg.sT, tg.sX, tg.sY, tg.sZ, tg.sHeading
        local HP, AR, FL      = tg.sHealth, tg.sArmour, tg.sFlags
        local VM, VS, CY, BL  = tg.sVehModel, tg.sVehSeat, tg.sCamYaw, tg.sBlend
        local ST, SP, VP, VR  = tg.sSteer, tg.sSpeed, tg.sVPitch, tg.sVRoll

        while pos + 13 <= len do
            local hdr, hp = readEvHeader(data, pos)
            if not hdr then break end

            -- startSec ist Wanduhr-Sekunde, epoch der Nullpunkt; Rest rechnet relativ.
            local t    = (hdr.startSec - epoch) + (hdr.startMs or 0) / 1000.0
            local prev = EMPTY
            local n    = tg.n

            for _ = 1, hdr.nSamples do
                local s, np = Protocol.ApplyStep(data, hp, prev)
                hp = np
                t  = t + (s.dt or 0) / 1000.0
                n  = n + 1
                T[n]  = t
                X[n]  = s.x or 0.0
                Y[n]  = s.y or 0.0
                Z[n]  = s.z or 0.0
                H[n]  = s.heading or 0.0
                HP[n] = s.health or 0
                AR[n] = s.armour or 0
                FL[n] = s.flags or 0
                VM[n] = s.vehModel or 0
                VS[n] = s.vehSeat or -1
                CY[n] = s.camYaw or 0.0
                BL[n] = s.moveBlend or 0.0
                ST[n] = s.steer or 0.0
                SP[n] = s.speed or 0.0
                VP[n] = s.vpitch or 0.0
                VR[n] = s.vroll or 0.0
                prev  = s
            end

            tg.n = n
            if hp <= pos then break end     -- kein Fortschritt: Endlosschleife
            pos = hp
        end
    end)

    return tg.n - n0
end

local function decodeFid(tg, data)
    if type(data) ~= 'string' or #data < MIN_CHUNK then return 0 end
    local n0 = tg.fn

    pcall(function()
        local len, pos = #data, 1
        local T, FL, CY, CP = tg.fT, tg.fFlags, tg.fCamYaw, tg.fCamPitch
        local BL, HD, ST    = tg.fBlend, tg.fHeading, tg.fSteer
        local VF, WP, AM    = tg.fVFlags, tg.fWeapon, tg.fAmmo

        while pos + 13 <= len do
            local hdr, hp = readFidHeader(data, pos)
            if not hdr then break end

            local t    = (hdr.startSec - epoch) + (hdr.startMs or 0) / 1000.0
            local prev = EMPTY
            local n    = tg.fn

            for _ = 1, hdr.nSamples do
                local s, np = Fidelity.ApplyStep(data, hp, prev)
                hp = np
                t  = t + (s.dt or 0) / 1000.0
                n  = n + 1
                T[n]  = t
                FL[n] = s.flags or 0
                CY[n] = s.camYaw or 0.0
                CP[n] = s.camPitch or 0.0
                BL[n] = s.blend or 0.0
                HD[n] = s.heading or 0.0
                ST[n] = s.steer or 0.0
                VF[n] = s.vflags or 0
                WP[n] = s.weapon or 0
                AM[n] = s.ammo or 0
                prev  = s
            end

            tg.fn = n
            if hp <= pos then break end
            pos = hp
        end
    end)

    return tg.fn - n0
end

--- Den ueberlappenden ANFANG eines frisch angehaengten Blocks wegschneiden.
--- Die Zeitspalte muss streng steigen, sonst wird die binaere Suche in SampleAt
--- unbrauchbar. Nur den ueberlappenden Teil verwerfen (Altbestand-Chunks ragen in
--- den Nachbarn hinein), nicht den ganzen Chunk — sonst endlose Neuanforderung.
local function trimLeading(tg, keys, tKey, nKey, n0)
    local total = tg[nKey]
    if total <= n0 or n0 <= 0 then return end
    local last = tg[tKey][n0]
    local j = n0 + 1
    while j <= total and tg[tKey][j] <= last do j = j + 1 end
    if j == n0 + 1 then return end          -- nichts zu schneiden

    local keep = total - j + 1
    if keep > 0 then
        for a = 1, #keys do
            local arr = tg[keys[a]]
            table.move(arr, j, total, n0 + 1, arr)
        end
    end
    tg[nKey] = n0 + keep
end

local function decodeInto(tg, e)
    if e.kind == 'fid' then
        local n0 = tg.fn
        decodeFid(tg, e.data)
        trimLeading(tg, FID_KEYS, 'fT', 'fn', n0)
        return tg.fn - n0
    end

    -- 'ev' und 'evopen' sind derselbe Strom (evopen waechst noch).
    local n0 = tg.n
    decodeEv(tg, e.data)
    trimLeading(tg, EV_KEYS, 'sT', 'n', n0)
    return tg.n - n0
end

-- ── Fenster: anhaengen, voranstellen, verwerfen ────────────────────────────

--- Alles Geladene vergessen. Segmente bleiben anforderbar (kein "gibt es nicht").
--- Fehlversuche fallen weg: ein Sprung stellt 'void' wieder scharf. Entdopplungs-
--- schluessel gehen mit den Arrays weg (unter v3 gehoert hier keiner einer offenen
--- Anforderung).
local function clearWindow()
    for i = 1, #order do
        local p = order[i]
        p.n, p.fn   = 0, 0
        p.cnt, p.fcnt, p.miss = {}, {}, {}
        p.idx, p.fidx = 1, 1
        p.openStart, p.openN, p.openSeg = nil, 0, nil
    end
    keySeg, segKeys = {}, {}
    segHave = {}
    segTry  = {}
    loadedFrom, loadedTo = nil, nil
end

--- Wohin gehoert das Segment? Setzt das Fenster gleich mit fort.
--- 'skip' heisst: schon im Fenster, die Antwort ist ueberfluessig.
local function placeWindow(seg)
    if not loadedFrom then
        loadedFrom, loadedTo = seg, seg
        return 'append'
    end
    if seg == loadedTo + 1 then loadedTo = seg return 'append' end
    if seg == loadedFrom - 1 then loadedFrom = seg return 'prepend' end
    if seg >= loadedFrom and seg <= loadedTo then return 'skip' end

    -- Nicht anschliessend (nur nach Sprung): das alte Fenster laege sonst als Loch
    -- mitten in den Arrays, aber die Zeitspalte muss streng steigen.
    clearWindow()
    loadedFrom, loadedTo = seg, seg
    return 'append'
end

--- Die Fenstergrenze zuruecknehmen. Nur wenn das Segment keine Samples beitrug —
--- dann darf ein spaeterer Versuch es erneut als Rand anhaengen.
local function unplaceWindow(seg)
    if not loadedFrom then return end
    if seg == loadedFrom and seg == loadedTo then
        loadedFrom, loadedTo = nil, nil
    elseif seg == loadedTo then
        loadedTo = seg - 1
    elseif seg == loadedFrom then
        loadedFrom = seg + 1
    end
end

--- Aeltestes Segment am unteren Ende wegwerfen.
local function dropFront()
    local seg = loadedFrom
    for i = 1, #order do
        local p = order[i]
        local k = p.cnt[seg] or 0
        if k > 0 and k <= p.n then
            for j = 1, #EV_KEYS do table.move(p[EV_KEYS[j]], k + 1, p.n, 1) end
            p.n = p.n - k
        end
        local kf = p.fcnt[seg] or 0
        if kf > 0 and kf <= p.fn then
            for j = 1, #FID_KEYS do table.move(p[FID_KEYS[j]], kf + 1, p.fn, 1) end
            p.fn = p.fn - kf
        end
        p.cnt[seg], p.fcnt[seg], p.miss[seg] = nil, nil, nil
        p.idx, p.fidx = 1, 1
        -- Gehoerte der offene Chunk diesem Segment, sind seine Samples mit
        -- weggeschoben; ein Platz auf fehlende Slots schnitte spaeter fremde ab.
        if p.openSeg == seg then p.openStart, p.openN, p.openSeg = nil, 0, nil end
    end
    -- Schluessel freigeben, sonst verwuerfe eine spaetere Lieferung sie als
    -- "schon gesehen" und das Segment bliebe leer.
    releaseKeys(seg)
    segHave[seg] = nil
    loadedFrom = loadedFrom + 1
    if loadedFrom > loadedTo then loadedFrom, loadedTo = nil, nil end
end

--- Juengstes Segment am oberen Ende wegwerfen. Slots bleiben belegt und werden
--- beim naechsten Anhaengen ueberschrieben (Laenge ist durchs Fenster gedeckelt).
local function dropBack()
    local seg = loadedTo
    for i = 1, #order do
        local p = order[i]
        local k = p.cnt[seg] or 0
        if k > 0 then p.n = math.max(0, p.n - k) end
        local kf = p.fcnt[seg] or 0
        if kf > 0 then p.fn = math.max(0, p.fn - kf) end
        p.cnt[seg], p.fcnt[seg], p.miss[seg] = nil, nil, nil
        if p.idx  > p.n  then p.idx  = 1 end
        if p.fidx > p.fn then p.fidx = 1 end
        if p.openSeg == seg then p.openStart, p.openN, p.openSeg = nil, 0, nil end
    end
    releaseKeys(seg)
    segHave[seg] = nil
    loadedTo = loadedTo - 1
    if loadedFrom > loadedTo then loadedFrom, loadedTo = nil, nil end
end

--- Auf Config.ClientCacheSeconds zurueckschneiden. Segment unter dem Abspielkopf
--- und direkte Nachbarn bleiben immer liegen (sonst dauerhaftes 'stale').
local function evict()
    if not loadedFrom then return end
    local maxSegs = floor(cfg('ClientCacheSeconds', 180) / segSec)
    if maxSegs < 3 then maxSegs = 3 end

    local cur = segOf(headT)
    while (loadedTo - loadedFrom + 1) > maxSegs do
        local farLo = (cur - loadedFrom) >= (loadedTo - cur)
        if farLo and loadedFrom < cur - 1 then dropFront()
        elseif (not farLo) and loadedTo > cur + 1 then dropBack()
        elseif loadedFrom < cur - 1 then dropFront()
        elseif loadedTo > cur + 1 then dropBack()
        else break end
        if not loadedFrom then break end
    end
end

-- ── Auftraege ──────────────────────────────────────────────────────────────

--- Chunks einer Nachricht einsammeln (v3): nur gefiltert ablegen, nichts
--- entscheiden. Was hier ausfaellt, fehlt in der Abrechnung gegen sent.
local function take(pk, items)
    if type(items) ~= 'table' then return end
    for i = 1, #items do
        local it = items[i]
        if type(it) == 'table' then
            local kind, data = it.kind, it.data
            local h  = toInt(it.hash)
            local st = toInt(it.start)
            -- hash und start bilden den Schluessel; Spieler ausserhalb des
            -- Manifests hat kein Ziel.
            if (kind == 'ev' or kind == 'evopen' or kind == 'fid')
               and h and players[h] and st
               and type(data) == 'string' and #data >= MIN_CHUNK then
                if #pk.list >= MAX_SEG_ITEMS then
                    -- Notbremse: alles weitere wird verworfen, Segment gilt als
                    -- unvollstaendig.
                    pk.over = true
                else
                    pk.list[#pk.list + 1] =
                        { kind = kind, hash = h, start = st, data = data }
                end
            end
        end
    end
end

--- Einen Fehlversuch buchen. Nach MAX_TRIES gilt das Segment als 'void': nicht
--- mehr angefordert, in der Ladespur als Fehler gezeigt, nie mehr "vollstaendig".
local function failSeg(seg)
    local n = (segTry[seg] or 0) + 1
    segTry[seg] = n
    if n >= MAX_TRIES then
        segHave[seg] = { ev = false, fid = false, void = true }
    end
end

--- Alles zuruecknehmen, was dieser Auftrag beitrug — Voraussetzung fuer die
--- Neuanforderung. Beim Anhaengen wird aus den Arrays abgezogen, beim Voranstellen
--- faellt der Zwischenspeicher mit dem Auftrag weg.
local function discardJob()
    local seg  = job.seg
    local back = job.mode ~= 'prepend'
    for i = 1, #order do
        local p = order[i]
        local a = back and job.add[p.hash] or nil
        if a then
            if a.n  > 0 then p.n  = (p.n  > a.n)  and (p.n  - a.n)  or 0 end
            if a.fn > 0 then p.fn = (p.fn > a.fn) and (p.fn - a.fn) or 0 end
        end
        -- Offener Chunk dieses Auftrags ist mit den Samples weg; ein Platz auf
        -- fehlende Slots schnitte spaeter fremdes Material ab.
        if p.openSeg == seg then p.openStart, p.openN, p.openSeg = nil, 0, nil end
        p.cnt[seg], p.fcnt[seg], p.miss[seg] = nil, nil, nil
        p.idx, p.fidx = 1, 1
    end
    releaseKeys(seg)
    unplaceWindow(seg)
end

--- Vollstaendigkeit nach v3: gegen sent gerechnet (was WIRKLICH in den Arrays
--- liegt), nicht aus bars. Fehlt sent, gilt die Lieferung als unvollstaendig.
--- Wer hinter der Zusage zurueckbleibt, wird gemerkt (shortE/shortF/shortAll) und
--- darf keine Abwesenheit mehr behaupten; missing/Ueberlauf treffen alle.
local function verdict()
    local sent = job.sent
    if job.over or (job.missing or 0) > 0 or type(sent) ~= 'table' then
        job.shortAll = true
        return false, false
    end

    local okE, okF = true, true
    for k, v in pairs(sent) do
        local h = toInt(k)
        -- Spieler ausserhalb des Manifests hat kein Ziel.
        if h and players[h] and type(v) == 'table' then
            -- Genannte Spieler merken (fuer den Akteursdeckel unten).
            job.seen[h] = true
            local g  = job.got[h]
            local ge = g and (g.ev + g.open) or 0
            local gf = g and g.fid or 0
            if ge < (toInt(v.ev) or 0) + (toInt(v.open) or 0) then
                okE = false
                job.shortE[h] = true
            end
            if gf < (toInt(v.fid) or 0) then
                okF = false
                job.shortF[h] = true
            end
        end
    end
    return okE, okF
end

--- Auftrag abschliessen: das Urteil aus verdict() buchen.
local function completeJob()
    local seg = job.seg
    local okE, okF = job.okE, job.okF

    -- Ein vorangestellter Block, den mergePlayer wegen der Zeitspalte verwarf, ist
    -- NICHT geliefert — auch wenn die Abrechnung gegen sent stimmte.
    if job.lost then okE, okF = false, false end

    segHave[seg] = { ev = okE, fid = okF, capped = job.capped or nil }
    segTry[seg]  = nil
    busy[seg]    = nil
    job          = nil

    evict()
end

--- Einen Spieler des Auftrags abschliessen. Beim Voranstellen wird erst jetzt aus
--- dem Zwischenspeicher umgeschichtet (sonst faellt die Zeitspalte waehrend des
--- ueber mehrere Bilder laufenden Auftrags). Je Spieler unteilbar: 26 Arrays,
--- alle oder keins — sonst Zeit aus neuem, Position aus altem Segment.
local function mergePlayer(p)
    local seg = job.seg
    -- Vorbehalt aus der Abrechnung: nicht alles Gesendete kam an.
    local shortE = job.shortAll or job.shortE[p.hash] or false
    local shortF = job.shortAll or job.shortF[p.hash] or false

    -- Akteursdeckel: der Server liefert je Segment hoechstens SegmentMaxActors
    -- Spieler und meldet capped. Wer uebergangen wurde, fehlt in sent, geht also
    -- glatt durch, obwohl kein Zustand ankam — deshalb hier Vorbehalt.
    if job.capped and not job.seen[p.hash] then
        shortE, shortF = true, true
    end
    -- Kein Vorbehalt mehr aus bars: massgeblich ist allein sent. Eine Abweichung
    -- bars<->Auslieferung ist ein Serverproblem, der Client darf nicht daran
    -- haengenbleiben (fruehere Endlosschleife: Segment bei jedem Versuch verworfen).

    if job.mode == 'prepend' then
        local scr = job.scr[p.hash]
        local k   = scr and scr.n or 0
        -- Vorangestelltes muss vor dem Geladenen liegen (Zeitspalte). Bei
        -- Ueberlappung nur den ueberlappenden Teil abschneiden, nicht alles
        -- verwerfen (Altbestand-Chunks ragen ins Fenster).
        if k > 0 and p.n > 0 and scr.sT[k] > p.sT[1] then
            local cut = k
            while cut > 0 and scr.sT[cut] >= p.sT[1] do cut = cut - 1 end
            k = cut
            if k == 0 then
                job.dup = true    -- vollstaendige Dublette, kein Verlust
            end
        end
        if k > 0 then
            for j = 1, #EV_KEYS do
                local key = EV_KEYS[j]
                local a, b = p[key], scr[key]
                table.move(a, 1, p.n, k + 1, a)
                table.move(b, 1, k, 1, a)
            end
            p.n = p.n + k
        end
        local kf = scr and scr.fn or 0
        if kf > 0 and p.fn > 0 and scr.fT[kf] > p.fT[1] then
            local cut = kf
            while cut > 0 and scr.fT[cut] >= p.fT[1] do cut = cut - 1 end
            kf = cut
        end
        if kf > 0 then
            for j = 1, #FID_KEYS do
                local key = FID_KEYS[j]
                local a, b = p[key], scr[key]
                table.move(a, 1, p.fn, kf + 1, a)
                table.move(b, 1, kf, 1, a)
            end
            p.fn = p.fn + kf
        end
        p.cnt[seg], p.fcnt[seg] = k, kf
        p.miss[seg] = (shortE or shortF) or nil
        p.idx, p.fidx = 1, 1
    else
        -- Beim Anhaengen fuehrt der Auftrag selbst mit, was er beitrug (add). Eine
        -- Differenz gegen den Vorstand waere falsch, wenn unterwegs der offene
        -- Chunk geraeumt wurde (Verlust eines anderen Segments).
        local a = job.add[p.hash]
        p.cnt[seg]  = a and a.n  or 0
        p.fcnt[seg] = a and a.fn or 0
        p.miss[seg] = (shortE or shortF) or nil
    end
end

--- Abschlussphase, ein Schritt. Beim Anhaengen alle Spieler in einem Zug; beim
--- Voranstellen ein Spieler je Schritt (26 Verschiebungen), damit Pump das Budget
--- pruefen kann.
local function finishStep()
    local i    = job.fin
    local last = (job.mode == 'prepend') and i or #order

    while i <= last and order[i] do
        mergePlayer(order[i])
        i = i + 1
    end
    job.fin = i

    if job.fin <= #order then return true end
    completeJob()
    return false
end

--- Ist die Luecke zwischen Fenster und diesem Segment noch unterwegs? Nur dann
--- lohnt das Warten; sonst gehoert das Segment woanders hin und das Fenster weicht.
local function gapStillComing(seg)
    if not loadedFrom then return false end
    local lo, hi
    if seg > loadedTo then lo, hi = loadedTo + 1, seg - 1
    elseif seg < loadedFrom then lo, hi = seg + 1, loadedFrom - 1
    else return false end

    for s2 = lo, hi do
        local queued = false
        for i = jobHead, jobTail do
            if jobQ[i] == s2 then queued = true; break end
        end
        if not (inflight[s2] or busy[s2] or queued) then return false end
    end
    return true
end

--- Passt dieses Segment JETZT an das geladene Fenster? Nur direkt anschliessende
--- (die Arrays sind der Zeit nach geordnet).
local function fitsWindow(seg)
    if not loadedFrom then return true end
    return seg == loadedTo + 1 or seg == loadedFrom - 1
        or (seg >= loadedFrom and seg <= loadedTo)
end

local function startJob()
    while not job and jobHead <= jobTail do
        local seg = jobQ[jobHead]

        -- Nicht anschliessende Segmente ZURUECKSTELLEN, nicht verwerfen: bei
        -- parallelen Anfragen treffen Antworten ungeordnet ein; hinten wieder
        -- einreihen, sobald die Luecke eintrifft passt es von selbst. Bleibt sie
        -- aus, greift der normale Zeitablauf-Fehlversuch (nichts geht still verloren).
        if not fitsWindow(seg) and gapStillComing(seg) then
            jobQ[jobHead] = nil
            jobHead = jobHead + 1
            jobTail = jobTail + 1
            jobQ[jobTail] = seg
            return
        end

        jobQ[jobHead] = nil
        jobHead = jobHead + 1

        local pk = pend[seg]
        pend[seg] = nil
        jobWait[seg] = nil
        if not pk then
            -- Kein Paket zum gemeldeten Segment: busy loesen, sonst wiese Request
            -- das Segment fuer den Rest der Sitzung ab.
            busy[seg] = nil
            failSeg(seg)
        else
            local mode = placeWindow(seg)
            if mode == 'skip' then
                -- Mitten im Fenster nicht einsortierbar (Zeitordnung). Als
                -- Fehlversuch zaehlen, sonst endlose Wiederholung.
                busy[seg] = nil
                failSeg(seg)
            else
                -- Sortierung 'ev' < 'evopen' < 'fid': der offene Chunk landet im
                -- Evidence-Strom als LETZTER am Ende der Arrays (ablösbar).
                local list = pk.list
                table.sort(list, function(a, b)
                    if a.hash ~= b.hash then return a.hash < b.hash end
                    if a.kind ~= b.kind then return a.kind < b.kind end
                    return a.start < b.start
                end)
                job = { seg = seg, mode = mode, list = list, i = 1,
                        scr = {}, add = {}, got = {}, fin = nil, any = false,
                        shortE = {}, shortF = {}, shortAll = false, seen = {},
                        sent = pk.sent, missing = pk.missing or 0,
                        capped = pk.capped, over = pk.over }
                -- Je Spieler zwei Zaehler: add (in die Arrays gelegt, fuer
                -- Ruecknahme/cnt) und got (als geliefert gezaehlt, fuer Abrechnung).
                for i = 1, #order do
                    local h = order[i].hash
                    job.add[h] = { n = 0, fn = 0 }
                    job.got[h] = { ev = 0, fid = 0, open = 0 }
                    if mode == 'prepend' then job.scr[h] = newArrays() end
                end
            end
        end
        ::continue::
    end
    if jobHead > 1 and jobHead > jobTail then jobQ, jobHead, jobTail = {}, 1, 0 end
end

--- Die Chunks sind durch: jetzt faellt die Entscheidung ueber das Segment.
--- Rueckgabe false = der Auftrag ist beendet (verworfen).
local function settleJob()
    local seg = job.seg
    local okE, okF = verdict()
    job.okE, job.okF = okE, okF

    if okE and okF then job.fin = 1 return true end

    if job.any and (segTry[seg] or 0) + 1 >= MAX_TRIES then
        -- Letzter Versuch mit vorhandenem Material: behalten als 'part' (nie
        -- vollstaendig), sonst ginge Aufzeichnung verloren.
        job.fin = 1
        return true
    end

    -- Sauber raeumen und spaeter erneut anfordern; die Sperre haelt den Planer
    -- von drei Versuchen in drei Bildern ab.
    discardJob()
    failSeg(seg)
    segDefer[seg] = GetGameTimer() + RETRY_DEFER_MS
    busy[seg] = nil
    job = nil
    return false
end

--- Den Platz des offenen Chunks AUFLOESEN, ohne seine Samples anzutasten. Noetig,
--- sobald ein Chunk eines SPAETEREN Segments dahinter haengt (der Platz liegt dann
--- nicht mehr am Ende). Die Anfangs-Samples bleiben (Beweis ihres Segments), aber
--- der VERMERK muss: Segment auf 'ev = false', geheilt durch Neuanforderung.
local function staleOpen(p)
    local s = p.openSeg
    p.openStart, p.openN, p.openSeg = nil, 0, nil
    if not s then return end
    p.miss[s] = true
    local h = segHave[s]
    if h then h.ev = false end
end

--- Den Platz des offenen Chunks raeumen. newStart = Startsekunde des ersetzenden
--- Chunks. Seine Samples liegen immer am ENDE der Arrays.
local function dropOpen(p, a, newStart)
    local k = p.openN or 0
    local s = p.openSeg
    if k > 0 then
        if k > p.n then k = p.n end
        p.n = p.n - k
        if s == job.seg then
            -- Platz gehoert diesem Auftrag: beim Verwerfen nicht doppelt abziehen.
            if a then a.n = (a.n > k) and (a.n - k) or 0 end
        else
            -- Platz gehoert einem frueheren Segment: dessen Zaehler muss mit,
            -- sonst nimmt die Verdraengung spaeter fremde Slots weg.
            local c = s and p.cnt[s]
            if c then p.cnt[s] = (c > k) and (c - k) or 0 end
            -- Und der VERMERK, wenn der neue Chunk den Zeitraum nicht uebernimmt:
            -- Segment auf 'ev = false', sonst behauptete die Ladespur
            -- Vollstaendigkeit fuer soeben verschwundene Samples.
            if s and newStart ~= p.openStart then
                p.miss[s] = true
                local h = segHave[s]
                if h then h.ev = false end
            end
        end
        if p.idx > p.n then p.idx = 1 end
    end
    p.openStart, p.openN, p.openSeg = nil, 0, nil
end

--- EINEN Schritt des laufenden Auftrags: ein Chunk, oder ein Spieler der
--- Abschlussphase. Rueckgabe false = fuer diesen Aufruf ist nichts mehr zu tun.
local function stepJob()
    if job.fin then return finishStep() end

    local e = job.list[job.i]
    if not e then return settleJob() end    -- Chunks durch, jetzt abrechnen
    job.i = job.i + 1

    local p = players[e.hash]
    if not p then return true end
    local a, g = job.add[e.hash], job.got[e.hash]
    if not a or not g then return true end

    -- ── Der offene Chunk. Er WAECHST und wird deshalb nie entdoppelt. ──────
    if e.kind == 'evopen' then
        if job.mode == 'prepend' then
            -- Vor dem Fenster laege er beim naechsten Wachstum doppelt; gilt als
            -- nicht uebernommen, Segment unvollstaendig (keine Gutschrift ueber die
            -- Grenze).
            return true
        else
            -- ERSETZEN, nie anhaengen: dieselbe Startsekunde traegt jedes Mal eine
            -- laengere Fassung.
            if p.openStart then dropOpen(p, a, e.start) end
            local got = decodeInto(p, e)
            if got > 0 then
                p.openStart, p.openN, p.openSeg = e.start, got, job.seg
                a.n     = a.n + got
                g.open  = g.open + 1
                job.any = true
            end
        end
        return true
    end

    -- ── Abgeschlossene Chunks: entdoppelt ueber kind:hash:start. ──────────
    -- Verglichen gegen DIESES Segment: ein Chunk gehoert genau einem Segment, eine
    -- Gutschrift ueber die Grenze war der v2-Fehler.
    local key = e.kind .. ':' .. e.hash .. ':' .. e.start
    if keySeg[key] == job.seg then
        if e.kind == 'ev' then g.ev = g.ev + 1 else g.fid = g.fid + 1 end
        return true
    end

    -- Die abgeschlossene Fassung loest den offenen Chunk ab (beim Voranstellen
    -- nichts abzuloesen: der Platz gehoert einem anderen Segment).
    if e.kind == 'ev' and job.mode ~= 'prepend' and p.openStart == e.start then
        dropOpen(p, a, e.start)
    end

    local tg  = (job.mode == 'prepend') and job.scr[e.hash] or p
    local got = tg and decodeInto(tg, e) or 0
    if got > 0 then
        -- Erst JETZT gehoert der Schluessel diesem Segment (Samples liegen in den
        -- Arrays); eine Ruecknahme laesst ihn gar nicht entstehen.
        claimKey(job.seg, key)
        if e.kind == 'ev' then
            g.ev = g.ev + 1
            a.n  = a.n + got
            -- Beim Anhaengen liegt dieser Chunk jetzt HINTER dem offenen Platz:
            -- der ist nicht mehr das Ende und wird aufgeloest.
            if job.mode ~= 'prepend' and p.openStart then staleOpen(p) end
        else
            g.fid = g.fid + 1
            a.fn  = a.fn + got
        end
        job.any = true
    end
    return true
end

-- ── Anforderungen ──────────────────────────────────────────────────────────

--- Wieviele Segmente im Voraus holen? Aufgerundet, mindestens eins (Abrundung
--- liesse den Vorrat auf null fallen, sobald Segment > PrefetchSeconds).
local function prefetchSegs()
    local pre = ceil(cfg('PrefetchSeconds', 30) / segSec)
    if pre < 1 then pre = 1 end

    -- Vorrat darf den Cache nicht sprengen, sonst wirft die Verdraengung genau das
    -- Geholte wieder weg.
    local room = floor(cfg('ClientCacheSeconds', 180) / segSec) - 2
    if room < 1 then room = 1 end
    if pre > room then pre = room end
    return pre
end

--- Eine offene Anforderung fallenlassen. Eingesammelte (nie dekodierte) Chunks
--- muessen mit weg. Die rid bleibt: ein spaeter eintreffender Schwanz traegt die
--- alte Kennung und wird verworfen (v2-Fehler).
local function abandon(seg)
    if not inflight[seg] then return end
    inflight[seg] = nil
    inflightN = inflightN - 1
    if inflightN < 0 then inflightN = 0 end
    pend[seg] = nil
end

--- Ein Segment anfordern. Vertrag idempotent; trotzdem abgewiesen, was schon
--- geladen, angefordert, in Arbeit oder gesperrt ist (spart Bandbreite).
function Segments.Request(seg)
    if not man then return false end
    seg = toInt(seg)
    if not seg or seg < firstSeg or seg > lastSeg then return false end
    if segHave[seg] or inflight[seg] or busy[seg] then return false end

    local d = segDefer[seg]
    if d then
        if GetGameTimer() < d then return false end
        segDefer[seg] = nil
    end

    ridSeq = ridSeq + 1
    inflight[seg] = { at = GetGameTimer(), rid = ridSeq }
    inflightN = inflightN + 1
    TriggerServerEvent('d-rps:seg:want', seg, ridSeq)
    return true
end

--- Nach einem Sprung: alles ausserhalb des Fensters verwerfen, sonst belegen
--- veraltete Anfragen den Planer bis zu ihrem Zeitablauf.
local function dropFar(cur)
    local pre = prefetchSegs()
    local lo, hi = cur - pre, cur + pre
    for seg in pairs(inflight) do
        if seg < lo or seg > hi then abandon(seg) end
    end
end

--- Endgueltig fehlgeschlagen? Hinter einem 'void' ist Schluss: ein Segment
--- jenseits der Luecke verwuerfe beim Eintreffen das ganze Fenster.
local function isVoid(seg)
    local h = segHave[seg]
    return h ~= nil and h.void == true
end

--- Planer. Reihenfolge: zuerst Segment unter dem Abspielkopf, dann entgegen der
--- Laufrichtung (Umkehr braucht es sofort), danach in Laufrichtung als Vorrat.
--- Void-Pruefung gilt in BEIDEN Richtungen.
local function schedule(now)
    if not man then return end
    -- Entprellung, sonst feuert ein Ziehen ueber das Band eine Anfrage je Pixel.
    if now < settleAt then return end

    local maxIn = floor(cfg('SegmentMaxInFlight', 3))
    if maxIn < 1 then maxIn = 1 end
    if inflightN >= maxIn then return end

    local cur = segOf(headT)
    local pre = prefetchSegs()

    local function try(seg)
        if inflightN >= maxIn then return true end
        if isVoid(seg) then return false end
        Segments.Request(seg)
        return inflightN >= maxIn
    end

    if try(cur) then return end
    if try(cur - headDir) then return end
    for k = 1, pre do
        local seg = cur + k * headDir
        if isVoid(seg) then break end
        if try(seg) then return end
    end
end

--- Rohe Nachrichten einsortieren (ohne Budget, keine Dekodierung). Ein Segment ist
--- erst mit done = true geliefert; bis dahin verlaengert jede Nachricht die Geduld,
--- nur die abschliessende traegt sent und missing.
local function drain()
    while rawHead <= rawTail do
        local d = rawQ[rawHead]
        rawQ[rawHead] = nil
        rawHead = rawHead + 1

        local seg  = toInt(d.seg)
        local slot = seg and inflight[seg]
        local rid  = toInt(d.rid)

        -- Nur beantworten, was angefordert wurde, und nur mit der Kennung DIESER
        -- Anforderung, sonst wird ein Schwanz als halbes Segment verbucht.
        if slot and rid and rid == slot.rid then
            if d.denied then
                if d.retry then
                    -- Vorruebergehend (Last): KEIN Fehlversuch, nur zurueckstellen.
                    abandon(seg)
                    segDefer[seg] = GetGameTimer() + RETRY_DEFER_MS
                else
                    -- Endgueltig (Berechtigung, unplausibel): Fehlversuch, kein
                    -- leeres Segment.
                    abandon(seg)
                    failSeg(seg)
                end
            else
                local pk = pend[seg]
                -- Kennungswechsel: Reste der vorigen Anforderung gehoeren nicht dazu.
                if not pk or pk.rid ~= rid then
                    pk = { rid = rid, list = {} }
                    pend[seg] = pk
                end
                if d.capped then pk.capped = true end
                take(pk, d.items)

                if d.done then
                    -- Zusage des Servers: einziger Massstab der Vollstaendigkeit.
                    pk.sent    = type(d.sent) == 'table' and d.sent or nil
                    pk.missing = toInt(d.missing) or 0
                    inflight[seg] = nil
                    inflightN = inflightN - 1
                    if inflightN < 0 then inflightN = 0 end
                    busy[seg] = true
                    jobTail = jobTail + 1
                    jobQ[jobTail] = seg
                else
                    slot.at = GetGameTimer()
                end
            end
        end
    end
    if rawHead > 1 then rawQ, rawHead, rawTail = {}, 1, 0 end
end

--- Verwaiste Anforderungen freigeben. Bleibt die Antwort aus, waere der Platz sonst
--- dauerhaft belegt; die Anfrage wird danach idempotent wiederholt.
local function sweep(now)
    local tmo = reqTimeout()
    for seg, e in pairs(inflight) do
        if now - (e.at or 0) > tmo then
            abandon(seg)
            failSeg(seg)
        end
    end
end

-- ── Oeffentliche Schnittstelle ─────────────────────────────────────────────

--- Alles vergessen. Server wird NICHT benachrichtigt (dafuer Bye).
function Segments.Reset()
    man = nil
    epoch, segSec, firstSeg, lastSeg = 0, 15, 0, 0
    spanSegs = 1
    players, order = {}, {}
    segHave, segTry, busy = {}, {}, {}
    segDefer = {}
    inflight, inflightN = {}, 0
    rawQ, rawHead, rawTail = {}, 1, 0
    jobWait = {}
    jobQ, jobHead, jobTail = {}, 1, 0
    pend, job     = {}, nil
    -- ridSeq laeuft BEWUSST weiter (sonst passte eine alte Nachricht auf die erste
    -- Anforderung der neuen Sitzung).
    -- Entdopplung gehoert zur Sitzung, sonst verwuerfe die naechste ihre Chunks.
    keySeg, segKeys = {}, {}
    loadedFrom, loadedTo = nil, nil
    headT, headDir, settleAt = 0.0, 1, 0
    -- Zeitgrenzen zuruecksetzen, sonst zieht die Oberflaeche ein Band ueber eine
    -- Sitzung ohne Daten auf.
    Segments.T0, Segments.T1 = 0, 0
    -- Weltspur haelt eigene Bloecke, sonst zeigte die naechste Sitzung alte Fahrzeuge.
    if World and World.Clear then World.Clear() end
end

--- Sitzung beenden und den Serverzustand freigeben.
function Segments.Bye()
    if man then TriggerServerEvent('d-rps:seg:bye') end
    Segments.Reset()
end

--- Manifest uebernehmen. Ab hier gilt seine Zeitachse.
function Segments.ApplyManifest(m)
    if type(m) ~= 'table' then return false end

    local e  = toInt(m.epoch)
    local ss = toInt(m.segSec)
    local f  = toInt(m.firstSeg)
    local l  = toInt(m.lastSeg)
    -- Unbrauchbares Manifest wird abgewiesen: an diesen vier Werten haengt jede
    -- Segmentnummer und jeder Zeitpunkt.
    if not e or not ss or not f or not l then return false end
    if ss < 1 or l < f then return false end
    if type(m.players) ~= 'table' then return false end

    Segments.Reset()
    man, epoch, segSec, firstSeg, lastSeg = m, e, ss, f, l

    -- Weltspur bekommt denselben Nullpunkt und dasselbe Raster (sonst um Stunden
    -- verschoben).
    if World and World.Reset then World.Reset(e, ss) end

    -- Reichweite eines Altbestand-Chunks in Segmenten (Zeitraum war
    -- [startSec, startSec + DiskChunkSeconds]).
    spanSegs = ceil(cfg('DiskChunkSeconds', 60) / segSec)
    if spanSegs < 1 then spanSegs = 1 end

    for i = 1, #m.players do
        local pl = m.players[i]
        local h  = type(pl) == 'table' and toInt(pl.hash) or nil
        if h and not players[h] then
            local p = newPlayer(pl, h)
            players[h]  = p
            order[#order + 1] = p
        end
    end

    -- Zeitgrenzen der Sitzung, damit die Oberflaeche das Band aufziehen kann.
    Segments.T0 = firstSeg * segSec
    Segments.T1 = (lastSeg + 1) * segSec

    headT   = math.max(Segments.T0, (toInt(m.jumpSeg) or firstSeg) * segSec)
    headDir = 1
    return true
end

--- Nachricht des Servers ENTGEGENNEHMEN — nicht dekodieren (das kostet mehrere ms
--- und ruckelte im Ereignis-Handler). Nur ablegen; Pump arbeitet portioniert ab.
function Segments.OnData(d)
    if not man or type(d) ~= 'table' then return end
    -- Weltspur nimmt sich hier ihre Referenz heraus (dekodiert unter eigenem
    -- Budget, client/world.lua); ein fehlendes Fahrzeug verwirft kein Segment.
    if World and World.Intake then World.Intake(d) end
    rawTail = rawTail + 1
    rawQ[rawTail] = d
end

--- Aus der Playback-Schleife, ganz vorn. Dekodiert bis zum Budget und plant
--- die naechsten Anforderungen.
function Segments.Pump(budgetMs)
    if not man then return end
    local now = GetGameTimer()

    drain()
    sweep(now)

    local budget = tonumber(budgetMs) or cfg('DecodeBudgetMs', 1.5)
    local t0 = now
    repeat
        if not job then startJob() end
        if not job then break end
        if not stepJob() then break end
        -- GetGameTimer liefert ganze ms (1,5 wirkt faktisch bei 2); entscheidend
        -- ist, dass mindestens ein Chunk je Bild faellt.
    until (GetGameTimer() - t0) >= budget

    schedule(GetGameTimer())
end

-- ── Abtasten ───────────────────────────────────────────────────────────────

--- Ist das Segment fuer DIESEN Spieler ausgewertet? cnt wird bei Abschluss gesetzt
--- (auch 0), nil = "noch nichts gesehen". miss[seg] zaehlt wie "noch nichts
--- gesehen": weniger angekommen als gesendet ist kein Beleg fuer Abwesenheit.
local function segReady(p, seg)
    return p.cnt[seg] ~= nil and not p.miss[seg]
end

--- Steht fest, dass jenseits dieser Segmentgrenze nichts mehr kommt? Ausserhalb der
--- Sitzung ja; innerhalb muss das Nachbarsegment geladen sein (ein Nachbar reicht,
--- ein Segment ist mindestens SegmentGapSeconds breit).
local function edgeKnown(p, seg)
    if seg < firstSeg or seg > lastSeg then return true end
    return segReady(p, seg)
end

--- Zustandspaar zum Zeitpunkt t (Sekunden seit der Epoche des Manifests).
--- Rueckgabe: i1, i2, frac, state
---   'ok'    — i1/i2 sind Indizes in die Zahlenarrays des Spielers,
---             frac ist der Interpolationsanteil zwischen beiden.
---   'stale' — laedt noch. Der Klon bleibt stehen, wo er war.
---   'gap'   — es GIBT hier nichts. Der Klon wird ausgeblendet.
--- Kern des Moduls: Interpolation ueber eine Luecke saehe wie Teleport aus, eine
--- Luecke statt Ladezustand behauptete falsche Abwesenheit — im Zweifel 'stale'.
function Segments.SampleAt(hash, t)
    local p = players[hash]
    if not p then return nil, nil, 0.0, 'gap' end

    -- Belegung unbekannt (barsUnknown): Index nicht aufbaubar, keine Abwesenheit
    -- bekannt — jede Luecke wird 'stale'.
    local none = p.unknown and 'stale' or 'gap'

    t = tonumber(t) or 0.0

    -- Abspielkopf mitfuehren (Pump bekommt ihn nicht uebergeben, kein zweiter Weg).
    if t ~= headT then
        local d = t - headT
        if d > 0 then headDir = 1 elseif d < 0 then headDir = -1 end
        if d > SEEK_JUMP_SECONDS or d < -SEEK_JUMP_SECONDS then
            settleAt = GetGameTimer() + floor(cfg('SegmentSeekSettleMs', 120))
            dropFar(segOf(t))
        end
        headT = t
    end

    local seg = segOf(t)

    -- 1. Manifest (mit hereinreichenden Chunks): nur hier darf eine Luecke ohne
    --    Datenlage entstehen.
    local b = touchByte(p, seg)
    if b == B_NONE or b == B_FID then return nil, nil, 0.0, none end

    -- 2. Ladezustand: noch nicht gesehenes Segment ist NIE eine Luecke.
    if not segReady(p, seg) then return nil, nil, 0.0, 'stale' end

    local n = p.n
    -- Manifest verspricht Material, im Fenster liegt keines: Lieferung fehlt.
    if n == 0 then return nil, nil, 0.0, 'stale' end

    local T = p.sT
    if t < T[1] then
        -- Direkt am ersten Zustand: Rand, keine Luecke.
        if T[1] - t <= 0.001 then return 1, 1, 0.0, 'ok' end
        -- Ob davor wirklich nichts war, weiss nur das Vorgaengersegment (fehlt nach
        -- jedem Sprung, weil der Anfangs-Chunk dort beginnt).
        if edgeKnown(p, seg - 1) then return nil, nil, 0.0, none end
        return nil, nil, 0.0, 'stale'
    end

    -- Vorwaerts-Zeiger mit binaerem Rueckfall (Abspielen: ein bis zwei Schritte,
    -- Springen: Binaersuche statt Vollscan).
    local i = p.idx
    if i < 1 or i > n or T[i] > t then
        local lo, hi = 1, n
        while lo < hi do
            local mid = (lo + hi + 1) // 2
            if T[mid] <= t then lo = mid else hi = mid - 1 end
        end
        i = lo
    else
        local steps = 0
        while i < n and T[i + 1] <= t do
            i = i + 1
            steps = steps + 1
            if steps > 64 then
                local lo, hi = i, n
                while lo < hi do
                    local mid = (lo + hi + 1) // 2
                    if T[mid] <= t then lo = mid else hi = mid - 1 end
                end
                i = lo
                break
            end
        end
    end
    p.idx = i

    if i >= n then
        -- Direkt auf dem letzten Zustand: kein Ende, nur kein Nachfolger.
        if t - T[n] <= 0.001 then return n, n, 0.0, 'ok' end
        -- Dahinter entscheidet das FOLGENDE Segment (geladen+leer = Ende, fehlt =
        -- naechster Zustand liegt evtl. dort).
        if edgeKnown(p, seg + 1) then return nil, nil, 0.0, none end
        return nil, nil, 0.0, 'stale'
    end

    local t1, t2 = T[i], T[i + 1]
    local span   = t2 - t1
    if span > cfg('SegmentGapSeconds', 5.0) then
        -- Beide Nachbarn geladen: echte Datenluecke, kein Ladezustand.
        return nil, nil, 0.0, none
    end
    return i, i + 1, (span > 0.0) and ((t - t1) / span) or 0.0, 'ok'
end

--- Index des passenden Fidelity-Zustands, oder nil. Eigener Zeiger (andere Rate);
--- NICHT interpoliert (Bewegungsbits, Waffe, Blinker sind Schaltzustaende).
function Segments.FidAt(hash, t)
    local p = players[hash]
    if not p or p.fn == 0 then return nil end
    t = tonumber(t) or 0.0

    local n, T = p.fn, p.fT
    local i = p.fidx
    if i < 1 or i > n or T[i] > t then
        local lo, hi = 1, n
        while lo < hi do
            local mid = (lo + hi + 1) // 2
            if T[mid] <= t then lo = mid else hi = mid - 1 end
        end
        i = lo
    else
        while i < n and T[i + 1] <= t do i = i + 1 end
    end
    p.fidx = i

    -- Nur bei zeitlicher Passung, sonst haelt ein Nachhall den Klon in einer
    -- Haltung fest, fuer die es keine Meldung gibt.
    local d = t - T[i]
    if d < 0 or d > FID_MAX_AGE then return nil end
    return i
end

--- Ist das Segment geliefert und brauchbar? Sagt NICHTS ueber
--- Vollstaendigkeit — dafuer gibt es SegState und Coverage.
function Segments.Has(seg)
    seg = toInt(seg)
    if not seg then return false end
    local h = segHave[seg]
    return h ~= nil and not h.void
end

--- Zustand eines Segments fuer die Ladespur der Oberflaeche.
--- Rueckgabe: state, capped
---   'ok'   — beide Stroeme fuer JEDEN Spieler, dem das Manifest Material
---            zusagt, vollstaendig geliefert
---   'part' — nur ein Strom, nur ein Teil der Spieler, oder der Akteursdeckel
---            des Servers hat gegriffen
---   'void' — Lieferung endgueltig fehlgeschlagen; wird als FEHLER gezeigt und
---            nicht mehr angefordert
---   'load' — angefordert oder gerade in Arbeit
---   nil    — nicht geladen
---
--- capped (2. Rueckgabewert): bei gegriffenem Deckel fehlen zugesagte Akteure —
--- keine Vollstaendigkeit behaupten.
function Segments.SegState(seg)
    seg = toInt(seg)
    if not seg then return nil end
    local h = segHave[seg]
    if h then
        if h.void then return 'void', false end
        if h.ev and h.fid and not h.capped then return 'ok', false end
        return 'part', h.capped == true
    end
    if busy[seg] or inflight[seg] then return 'load', false end
    return nil
end

--- Abdeckung eines Bereichs, Evidence und Fidelity GETRENNT (Evidence ohne Fidelity
--- ist Normalfall). Void und capped stehen getrennt daneben.
--- Rueckgabe: evSegs, fidSegs, total, voidSegs, cappedSegs
function Segments.Coverage(fromSeg, toSeg)
    local a, b = toInt(fromSeg), toInt(toSeg)
    if not man or not a or not b or b < a then return 0, 0, 0, 0, 0 end
    if a < firstSeg then a = firstSeg end
    if b > lastSeg  then b = lastSeg end
    if b < a then return 0, 0, 0, 0, 0 end
    if (b - a + 1) > MAX_COVER then b = a + MAX_COVER - 1 end

    local ev, fid, total, bad, cap = 0, 0, 0, 0, 0
    for seg = a, b do
        total = total + 1
        local h = segHave[seg]
        if h then
            if h.void then bad = bad + 1 end
            if h.capped then cap = cap + 1 end
            -- Gedeckeltes Segment zaehlt fuer keinen Strom (Akteure fehlen).
            if not h.capped then
                if h.ev  then ev  = ev  + 1 end
                if h.fid then fid = fid + 1 end
            end
        end
    end
    return ev, fid, total, bad, cap
end

-- ── Zugriff fuer die Wiedergabe ────────────────────────────────────────────
-- SampleAt und FidAt liefern INDIZES; die Werte stehen in den Zahlenarrays (eine
-- Tabelle je Sample ist genau das, was dieses Modul vermeidet).

function Segments.Player(hash) return players[hash] end
function Segments.Players()    return order end
function Segments.Manifest()   return man end

--- Geladenes Fenster, fuer die Ladeanzeige im Datenband.
function Segments.Window() return loadedFrom, loadedTo end

RegisterNetEvent('d-rps:seg:manifest', function(m) Segments.ApplyManifest(m) end)
RegisterNetEvent('d-rps:seg:data',     function(d) Segments.OnData(d) end)

--- Innenansicht fuer die Diagnose (Felder sind lokal, daher hier statt playback.lua).
function Segments.Debug(seg, hash)
    local h = segHave[seg]
    -- Zustand OHNE den Abspielkopf anzufassen: SampleAt fuehrt ihn mit und
    -- veraenderte damit die Messung.
    local pState, pn, pBand
    local pl = hash and players[toInt(hash) or -1]
    if pl then
        pn    = pl.n
        pBand = string.char(barAt(pl.bars, seg))
        if pl.unknown then pState = 'unbekannt'
        else
            local tb = touchByte(pl, seg)
            if tb == B_NONE or tb == B_FID then pState = 'gap'
            elseif not segReady(pl, seg) then pState = 'stale'
            else pState = 'ok' end
        end
    end
    return {
        headT    = headT,
        headDir  = headDir,
        pState   = pState,
        pn       = pn,
        pBand    = pBand,
        have     = h and { ev = h.ev, fid = h.fid, capped = h.capped, void = h.void } or nil,
        try      = segTry[seg],
        inflight = inflight[seg] ~= nil,
        inflightN = inflightN,
        busy     = busy[seg] ~= nil,
        pend     = pend[seg] ~= nil,
        settleIn = math.max(0, settleAt - GetGameTimer()),
        queued   = jobTail - jobHead + 1,
        loadedFrom = loadedFrom, loadedTo = loadedTo,
    }
end

return Segments
