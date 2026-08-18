--[[ ===========================================================================
    D-RPS — Pruefstand fuer client/segments.lua (Vertrag v3)

    Laeuft mit plain lua5.4, ohne Netz und ohne Spiel:
        ssh drps "lua5.4 -" < _test/segments_spec.lua

    Alles, was FiveM beitraegt, ist hier gestubbt — Config, Protocol, Fidelity,
    CreateThread, Wait, TriggerServerEvent, RegisterNetEvent, GetGameTimer.
    Die Uhr ist eine schlichte Zahl: der Pruefstand steuert sie selbst, sonst
    haengen Zeitablauf und Wiederholsperre an der Laufzeit des Testlaufs.

    Zwei Kunstgriffe, die im Kopf stehen muessen, weil sie sonst wie ein Fehler
    aussehen:

    1. Der Planer wird stillgelegt. SampleAt setzt bei einem Sprung
       settleAt = jetzt + SegmentSeekSettleMs, und schedule() kehrt vorher
       ergebnislos zurueck. Mit einem absurd grossen SegmentSeekSettleMs und
       EINEM Sprung zu Beginn jedes Falls fordert der Cache also nur noch das
       an, was der Pruefstand ausdruecklich anfordert. Ohne das haengen nach
       jedem Pump fremde Anfragen in inflight, laufen in den Zeitablauf und
       verbrauchen die Fehlversuche der Segmente, um die es gerade geht.

    2. Die Uhr steht waehrend eines Pump-Aufrufs. Damit greift das Dekodier-
       budget nie, und ein Pump arbeitet genau EINEN Auftrag vollstaendig ab.
       Das macht die Faelle abzaehlbar; das Budget selbst ist nicht Gegenstand
       dieser Pruefung.

    Das Chunk-Format der Stubs ist NICHT das echte: 12 Byte Kopf
    (startSec, startMs, nSamples) und feste Samples. Geprueft wird die
    Buchfuehrung von segments.lua, nicht der Kodierer.
=========================================================================== ]]

-- ── Modul finden ───────────────────────────────────────────────────────────
-- Der Pruefstand kommt ueber stdin herein; ein Pfad relativ zum Skript gibt es
-- dann nicht. Deshalb werden Kandidaten der Reihe nach probiert.
local function findModule()
    local cands = {
        (arg and arg[1]) or nil,
        os.getenv('DRPS_SEGMENTS'),
        'client/segments.lua',
        '../client/segments.lua',
        './segments.lua',
        '/tmp/drps/client/segments.lua',
    }
    for i = 1, #cands do
        local p = cands[i]
        if p then
            local f = io.open(p, 'rb')
            if f then f:close() return p end
        end
    end
    io.write('FEHLER: client/segments.lua nicht gefunden\n')
    os.exit(2)
end

-- ── Stubs: FiveM-Umgebung ──────────────────────────────────────────────────

local TIME = 5000                       -- GetGameTimer(), Millisekunden Uptime

function GetGameTimer() return TIME end
function CreateThread(fn) end           -- keine Nebenlaeufigkeit im Pruefstand
function Wait(_) end
function RegisterNetEvent(_, _) end

local wants = {}                        -- alle 'd-rps:seg:want'
local byes  = 0

function TriggerServerEvent(ev, a, b)
    if ev == 'd-rps:seg:want' then
        wants[#wants + 1] = { seg = a, rid = b }
    elseif ev == 'd-rps:seg:bye' then
        byes = byes + 1
    end
end

--- Kennung der JUENGSTEN Anforderung eines Segments.
local function lastRid(seg)
    for i = #wants, 1, -1 do
        if wants[i].seg == seg then return wants[i].rid end
    end
    return nil
end

-- ── Stubs: Config ──────────────────────────────────────────────────────────

local DEFAULTS = {
    SegmentTimeoutMs    = 20000,
    ClientCacheSeconds  = 180,
    PrefetchSeconds     = 30,
    SegmentMaxInFlight  = 3,
    DiskChunkSeconds    = 60,
    DecodeBudgetMs      = 1.5,
    SegmentGapSeconds   = 5.0,
    -- Siehe Kopf, Punkt 1: legt den Planer still.
    SegmentSeekSettleMs = 1000000000,
}

Config = {}

-- ── Stubs: Protocol / Fidelity ─────────────────────────────────────────────
-- Kopf: '<i4i4i4' = startSec, startMs, nSamples (12 Byte).
-- Evidence-Sample:  '<i4fff' = dt(ms), x, y, z          (16 Byte)
-- Fidelity-Sample:  '<i4i4'  = dt(ms), flags            ( 8 Byte)
-- DecodeChunkHeader liest immer ab Position 1 — genau wie die echten Dekoder;
-- segments.lua schneidet fuer jeden weiteren Kopf ein Stueck heraus.

local function decodeHeader(s)
    if type(s) ~= 'string' or #s < 12 then return nil end
    local sec, ms, n = string.unpack('<i4i4i4', s)
    if n < 0 then return nil end
    return { startSec = sec, startMs = ms, nSamples = n }, 13
end

Protocol = {
    DecodeChunkHeader = decodeHeader,
    ApplyStep = function(data, pos, prev)
        local dt, x, y, z, np = string.unpack('<i4fff', data, pos)
        return {
            dt = dt, x = x, y = y, z = z,
            heading = 0.0, health = 200, armour = 0, flags = 0,
            vehModel = 0, vehSeat = -1, camYaw = 0.0, moveBlend = 0.0,
            steer = 0.0, speed = 0.0, vpitch = 0.0, vroll = 0.0,
        }, np
    end,
}

Fidelity = {
    DecodeChunkHeader = decodeHeader,
    ApplyStep = function(data, pos, prev)
        local dt, fl, np = string.unpack('<i4i4', data, pos)
        return {
            dt = dt, flags = fl, camYaw = 0.0, camPitch = 0.0, blend = 0.0,
            heading = 0.0, steer = 0.0, vflags = 0, weapon = 0, ammo = 0,
        }, np
    end,
}

-- ── Testdaten ──────────────────────────────────────────────────────────────

local EPOCH  = 1000000        -- Wanduhr-Sekunde des Nullpunkts
local SEGSEC = 15

--- Evidence-Chunk bauen. dts sind Millisekundenschritte; der Dekodierpfad
--- rechnet t = (startSec - epoch) + dt/1000 + ..., die erwarteten Zeiten werden
--- hier mit DERSELBEN Arithmetik gebildet, damit ein Vergleich exakt ist.
local function evData(relStart, dts)
    local out = { string.pack('<i4i4i4', EPOCH + relStart, 0, #dts) }
    local ts, t = {}, relStart + 0.0
    for i = 1, #dts do
        t = t + dts[i] / 1000.0
        ts[i] = t
        out[#out + 1] = string.pack('<i4fff', dts[i], 1.0 * i, 2.0 * i, 3.0)
    end
    return table.concat(out), ts
end

local function fidData(relStart, dts)
    local out = { string.pack('<i4i4i4', EPOCH + relStart, 0, #dts) }
    local ts, t = {}, relStart + 0.0
    for i = 1, #dts do
        t = t + dts[i] / 1000.0
        ts[i] = t
        out[#out + 1] = string.pack('<i4i4', dts[i], i)
    end
    return table.concat(out), ts
end

--- Ein Eintrag der items-Liste. hash ist ein STRING — genau so verschickt der
--- Server ihn (ein u32-Zahlenschluessel wuerde ueber die Netzgrenze zu einem
--- Array mit Milliarden Luecken).
local function item(kind, hash, relStart, data)
    return { kind = kind, hash = tostring(hash), start = EPOCH + relStart,
             data = data }
end

local H1, H2, H3 = 1001, 2002, 3003

--- Manifest mit frei waehlbaren Spielern.
--- bars: 'b' fuer jedes Segment, wenn nichts anderes gesagt wird.
local function manifest(pls)
    local band = string.rep('b', 10)
    local list = {}
    for i = 1, #pls do
        local q = pls[i]
        list[i] = {
            hash = q.hash, id = i, name = 'P' .. i, online = false, model = 0,
            bars = q.bars or band,
            barsUnknown = q.unknown or false,
            spans = {},
        }
    end
    return { epoch = EPOCH, segSec = SEGSEC, firstSeg = 0, lastSeg = 9,
             jumpSeg = 0, players = list }
end

-- ── Zusicherungen ──────────────────────────────────────────────────────────

local CASE, FAILS = '', {}

local function fail(msg) FAILS[#FAILS + 1] = CASE .. ': ' .. msg end

local function ok(cond, what)
    if not cond then fail(what) end
end

local function eq(got, want, what)
    if got ~= want then
        fail(string.format('%s (ist %s, erwartet %s)',
             what, tostring(got), tostring(want)))
    end
end

local function near(got, want, what)
    if type(got) ~= 'number' or math.abs(got - want) > 1e-6 then
        fail(string.format('%s (ist %s, erwartet %s)',
             what, tostring(got), tostring(want)))
    end
end

--- Die Zeitspalte MUSS streng steigen — daran haengt die binaere Suche in
--- SampleAt. Eine fallende Stelle liefert dort stillschweigend den falschen
--- Zustand, und das sieht aus wie eine Beobachtung.
local function rising(p, what)
    for i = 2, p.n do
        if not (p.sT[i] > p.sT[i - 1]) then
            fail(string.format('%s: sT[%d]=%s nicht > sT[%d]=%s',
                 what, i, tostring(p.sT[i]), i - 1, tostring(p.sT[i - 1])))
            return
        end
    end
    for i = 2, p.fn do
        if not (p.fT[i] > p.fT[i - 1]) then
            fail(string.format('%s: fT[%d] nicht steigend', what, i))
            return
        end
    end
end

-- ── Ablaufhilfen ───────────────────────────────────────────────────────────

local Segments   -- wird nach dem Laden gesetzt

local function fresh(pls, over)
    for k, v in pairs(DEFAULTS) do Config[k] = v end
    if over then for k, v in pairs(over) do Config[k] = v end end
    wants = {}
    assert(Segments.ApplyManifest(manifest(pls)), 'Manifest abgewiesen')
end

--- Sprung setzen: bewegt den Abspielkopf UND legt den Planer stundenlang stumm
--- (siehe Kopf, Punkt 1).
local function seek(hash, t)
    Segments.SampleAt(hash, t)
end

local function send(seg, rid, items, done, extra)
    local d = { seg = seg, rid = rid, items = items or {}, done = done or false }
    if extra then for k, v in pairs(extra) do d[k] = v end end
    Segments.OnData(d)
end

--- Ein Pump arbeitet bei stehender Uhr genau einen Auftrag ab; acht reichen
--- fuer jeden Fall hier mit Abstand.
local function pump(n)
    for _ = 1, (n or 8) do Segments.Pump(100000) end
end

-- ── Volle Segmente ─────────────────────────────────────────────────────────
-- Der Recorder schliesst einen Chunk AN DER SEGMENTGRENZE ab; ein Chunk liegt
-- damit vollstaendig in genau einem Segment. Die alten Faelle haben das nie
-- geprueft: ihre Chunks waren 1,5 s lang bei 15 s Segmentbreite, also lag jeder
-- ohnehin mitten in seinem Segment. Erst ein Chunk, der sein Segment AUSFUELLT,
-- stellt die Frage ueberhaupt.
--
-- Der erste Zustand liegt auf der Segmentgrenze, der letzte 0,1 s davor; die
-- Abstaende bleiben unter Config.SegmentGapSeconds, damit ueber die Naht hinweg
-- interpoliert werden darf. Genau daran ist zu sehen, ob zwei benachbarte
-- Chunks luekenlos aneinanderstossen, ohne dass einer in das Segment des
-- anderen hineinreicht.
local FULL_DTS = { 0, 4000, 4000, 4000, 2900 }   -- +0 +4 +8 +12 +14,9
local FULL_N   = #FULL_DTS

local function fullChunk(seg) return (evData(seg * SEGSEC, FULL_DTS)) end

--- Ein volles Segment anfordern und vollstaendig ausliefern.
local function deliverFull(seg)
    ok(Segments.Request(seg), 'Anforderung ' .. seg)
    send(seg, lastRid(seg), { item('ev', H1, seg * SEGSEC, fullChunk(seg)) },
         true, { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 0 } },
                 missing = 0 })
    pump()
end

--- EIN CHUNK GEHOERT GENAU EINEM SEGMENT — an den Arrays selbst nachgezaehlt.
---
--- Segment fuer Segment werden cnt[seg] Zustaende abgezaehlt; jeder davon MUSS
--- in die Zeitgrenzen genau dieses Segments fallen, und am Ende muessen die
--- Zaehler die Arrays vollstaendig ausschoepfen. Zaehlt es nicht auf, gehoert
--- Material keinem oder zwei Segmenten — und die Verdraengung nimmt dann das
--- Falsche mit. Genau dieser Weg fuehrte zuletzt zu einem Segment, das als
--- vollstaendig gebucht war und keinen einzigen Zustand mehr hielt.
local function layout(p, what)
    local lo, hi = Segments.Window()
    if not lo then
        eq(p.n, 0, what .. ': ohne Fenster liegt kein Zustand mehr da')
        return
    end
    local pos = 0
    for seg = lo, hi do
        local k = p.cnt[seg] or 0
        for j = pos + 1, pos + k do
            local t = p.sT[j]
            if type(t) ~= 'number'
               or t < seg * SEGSEC or t >= (seg + 1) * SEGSEC then
                fail(string.format(
                     '%s: Zustand %d (t=%s) liegt nicht in Segment %d',
                     what, j, tostring(t), seg))
                return
            end
        end
        pos = pos + k
    end
    eq(pos, p.n, what .. ': Segmentzaehler schoepfen die Arrays aus')
end

--- Der letzte Blocker in einem Satz: ein als vollstaendig gebuchtes Segment
--- ohne ein einziges Sample. Fuer JEDES Segment des Bandes gilt danach entweder
--- "gebucht UND belegt" oder "gar nicht gebucht" — dazwischen gibt es nichts,
--- was die Ladespur gruen zeigen duerfte.
local function bookedHasData(p, what)
    local lo, hi = Segments.Window()
    for seg = 0, 9 do
        local st = Segments.SegState(seg)
        if st == 'ok' or st == 'part' then
            ok(lo and seg >= lo and seg <= hi, string.format(
               '%s: Segment %d ist %s, liegt aber nicht im Fenster',
               what, seg, tostring(st)))
            ok((p.cnt[seg] or 0) > 0, string.format(
               '%s: Segment %d gilt als %s, haelt aber keinen Zustand',
               what, seg, tostring(st)))
        end
    end
end

-- ── Faelle ─────────────────────────────────────────────────────────────────

local cases = {}
local function case(name, fn) cases[#cases + 1] = { name = name, fn = fn } end

-- 1) Normalfall: ein Segment in drei Nachrichten.
case('1 Normalfall', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local a = evData(60, { 0, 500, 500 })
    local b = evData(65, { 0, 500, 500 })
    local c = fidData(60, { 0, 1000, 1000 })

    ok(Segments.Request(4), 'Request(4) angenommen')
    local rid = lastRid(4)
    ok(rid ~= nil, 'rid vergeben')

    send(4, rid, { item('ev', H1, 60, a) }, false)
    send(4, rid, { item('ev', H1, 65, b) }, false)
    send(4, rid, { item('fid', H1, 60, c) }, true,
         { sent = { [tostring(H1)] = { ev = 2, fid = 1, open = 0 } },
           missing = 0, capped = false })
    pump()

    local st, cap = Segments.SegState(4)
    eq(st, 'ok', 'SegState nach vollstaendiger Lieferung')
    eq(cap, false, 'nicht gedeckelt')
    ok(Segments.Has(4), 'Has(4)')

    local p = Segments.Player(H1)
    eq(p.n, 6,  'Evidence-Samples')
    eq(p.fn, 3, 'Fidelity-Samples')
    eq(p.cnt[4], 6, 'cnt[4]')
    rising(p, 'Zeitspalte')
    near(p.sT[1], 60.0, 'erster Zeitpunkt')
    near(p.sT[6], 66.0, 'letzter Zeitpunkt')
end)

-- 2) Veraltete Lieferung: Anfrage fallengelassen, neue rid, alte Nachrichten
--    treffen ein.
case('2 veraltete rid', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local a = evData(60, { 0, 500, 500 })
    local b = evData(65, { 0, 500, 500 })

    ok(Segments.Request(4), 'erste Anforderung')
    local rid1 = lastRid(4)
    send(4, rid1, { item('ev', H1, 60, a) }, false)
    pump(1)

    -- Zeitablauf laesst die Anforderung fallen.
    TIME = TIME + 25000
    pump(1)
    eq(Segments.SegState(4), nil, 'nach Zeitablauf nicht mehr in Arbeit')

    ok(Segments.Request(4), 'zweite Anforderung')
    local rid2 = lastRid(4)
    ok(rid2 ~= rid1, 'neue rid unterscheidet sich')

    -- Der Schwanz der alten Lieferung, vollstaendig und mit passendem sent.
    send(4, rid1, { item('ev', H1, 65, b) }, true,
         { sent = { [tostring(H1)] = { ev = 2, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(4), 'load', 'alte Lieferung schliesst nichts ab')
    ok(not Segments.Has(4), 'Segment gilt nicht als geliefert')
    eq(Segments.Player(H1).n, 0, 'kein Sample uebernommen')

    -- Zum Beweis, dass nur die Kennung im Weg stand: dieselben Daten mit rid2.
    send(4, rid2, { item('ev', H1, 60, a), item('ev', H1, 65, b) }, true,
         { sent = { [tostring(H1)] = { ev = 2, fid = 0, open = 0 } },
           missing = 0 })
    pump()
    eq(Segments.SegState(4), 'ok', 'mit passender rid vollstaendig')
    eq(Segments.Player(H1).n, 6, 'Samples jetzt da')
end)

-- 3) sent verspricht 3 Chunks, geliefert werden 2.
case('3 sent unterschritten', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local a = evData(60, { 0, 500, 500 })
    local b = evData(65, { 0, 500, 500 })

    ok(Segments.Request(4), 'Anforderung')
    send(4, lastRid(4), { item('ev', H1, 60, a), item('ev', H1, 65, b) }, true,
         { sent = { [tostring(H1)] = { ev = 3, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(4), nil, 'unvollstaendig, nicht gebucht')
    ok(not Segments.Has(4), 'Has(4) falsch')
    eq(Segments.Player(H1).n, 0, 'Teillieferung zurueckgenommen')
    eq(Segments.Player(H1).cnt[4], nil, 'cnt[4] geraeumt')
    eq(Segments.Request(4), false, 'waehrend der Sperre keine Anfrage')

    TIME = TIME + 800
    eq(Segments.Request(4), true, 'nach der Sperre wieder anforderbar')
end)

-- 4) missing > 0.
case('4 missing', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local a = evData(60, { 0, 500, 500 })
    local b = evData(65, { 0, 500, 500 })

    ok(Segments.Request(4), 'Anforderung')
    send(4, lastRid(4), { item('ev', H1, 60, a), item('ev', H1, 65, b) }, true,
         { sent = { [tostring(H1)] = { ev = 2, fid = 0, open = 0 } },
           missing = 1 })
    pump()

    eq(Segments.SegState(4), nil, 'missing > 0 ist unvollstaendig')
    ok(not Segments.Has(4), 'Has(4) falsch')
    eq(Segments.Player(H1).n, 0, 'nichts uebernommen')

    TIME = TIME + 800
    eq(Segments.Request(4), true, 'erneut anforderbar')
end)

-- 5) denied mit retry = true: KEIN Fehlversuch.
case('5 denied retry', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    -- Vier Runden — deutlich mehr als MAX_TRIES. Wuerde die Last als
    -- Fehlversuch zaehlen, stuende hier spaetestens nach der dritten 'void'.
    for i = 1, 4 do
        eq(Segments.Request(4), true, 'Anforderung ' .. i)
        send(4, lastRid(4), {}, true,
             { denied = 'auslieferung blockiert', retry = true,
               sent = {}, missing = 0, capped = false })
        pump(1)
        local st = Segments.SegState(4)
        ok(st ~= 'void', 'nach Runde ' .. i .. ' nicht void (ist ' ..
           tostring(st) .. ')')
        eq(Segments.Request(4), false, 'Runde ' .. i .. ': Sperre greift')
        TIME = TIME + 800
    end

    eq(Segments.SegState(4), nil, 'weiterhin ungeladen, nicht fehlgeschlagen')
    eq(Segments.Request(4), true, 'bleibt anforderbar')
end)

-- 6) denied mit retry = false, dreimal.
case('6 denied endgueltig', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    for i = 1, 3 do
        eq(Segments.Request(4), true, 'Anforderung ' .. i)
        send(4, lastRid(4), {}, true,
             { denied = 'keine berechtigung', retry = false,
               sent = {}, missing = 0, capped = false })
        pump(1)
        if i < 3 then
            ok(Segments.SegState(4) ~= 'void', 'nach Runde ' .. i .. ' noch nicht void')
        end
    end

    eq(Segments.SegState(4), 'void', 'nach drei Fehlversuchen void')
    ok(not Segments.Has(4), 'Has(4) falsch')
    eq(Segments.Request(4), false, 'void wird nicht mehr angefordert')

    local _, _, _, bad = Segments.Coverage(4, 4)
    eq(bad, 1, 'Coverage zaehlt das Segment als Fehler')
end)

-- 7) Derselbe abgeschlossene Chunk zweimal.
case('7 Doppellieferung', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local a, ts = evData(60, { 0, 500, 500 })

    ok(Segments.Request(4), 'Anforderung')
    send(4, lastRid(4), { item('ev', H1, 60, a), item('ev', H1, 60, a) }, true,
         { sent = { [tostring(H1)] = { ev = 2, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(4), 'ok', 'Segment vollstaendig')
    local p = Segments.Player(H1)
    eq(p.n, 3, 'Chunk genau einmal in den Arrays')
    rising(p, 'Zeitspalte')
    near(p.sT[3], ts[3], 'letzter Zeitpunkt')
end)

-- 8) 'evopen' zweimal, waechst.
case('8 offener Chunk waechst', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local c1 = evData(60, { 0, 500, 500 })            -- 60.0 60.5 61.0
    local o1 = evData(62, { 0, 500, 500 })            -- 62.0 62.5 63.0
    local o2, ot = evData(62, { 0, 500, 500, 500, 500 })  -- .. 64.0

    ok(Segments.Request(4), 'Anforderung 4')
    send(4, lastRid(4), { item('ev', H1, 60, c1), item('evopen', H1, 62, o1) },
         true, { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 1 } },
                 missing = 0 })
    pump()

    local p = Segments.Player(H1)
    eq(Segments.SegState(4), 'ok', 'Segment 4 vollstaendig')
    eq(p.n, 6, 'erste Fassung liegt am Ende')
    eq(p.openN, 3, 'Platz des offenen Chunks belegt')
    eq(p.openStart, EPOCH + 62, 'Startsekunde des Platzes')

    ok(Segments.Request(5), 'Anforderung 5')
    send(5, lastRid(5), { item('evopen', H1, 62, o2) }, true,
         { sent = { [tostring(H1)] = { ev = 0, fid = 0, open = 1 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(5), 'ok', 'Segment 5 vollstaendig')
    eq(p.n, 8, 'nur die juengste Fassung, keine Verdopplung')
    eq(p.openN, 5, 'Platz traegt die neue Laenge')
    eq(p.cnt[4], 3, 'Segment 4 gibt seine Samples des Platzes ab')
    eq(p.cnt[5], 5, 'Segment 5 haelt den Platz')
    rising(p, 'Zeitspalte')
    near(p.sT[8], ot[5], 'letzter Zeitpunkt aus der juengsten Fassung')
end)

-- 9) 'evopen', danach der abgeschlossene 'ev' mit derselben Startsekunde.
case('9 offener Chunk abgeloest', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local c1 = evData(60, { 0, 500, 500 })
    local o1 = evData(62, { 0, 500, 500 })
    local f1, ft = evData(62, { 0, 500, 500, 500, 500 })

    ok(Segments.Request(4), 'Anforderung 4')
    send(4, lastRid(4), { item('ev', H1, 60, c1), item('evopen', H1, 62, o1) },
         true, { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 1 } },
                 missing = 0 })
    pump()

    ok(Segments.Request(5), 'Anforderung 5')
    send(5, lastRid(5), { item('ev', H1, 62, f1) }, true,
         { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    local p = Segments.Player(H1)
    eq(Segments.SegState(5), 'ok', 'Segment 5 vollstaendig')
    eq(p.openStart, nil, 'Platz des offenen Chunks geraeumt')
    eq(p.openN, 0, 'Platz leer')
    eq(p.n, 8, 'genau die abgeschlossene Fassung')
    rising(p, 'Zeitspalte')
    near(p.sT[4], ft[1], 'abgeschlossene Fassung beginnt korrekt')
    near(p.sT[8], ft[5], 'und endet korrekt')
end)

-- 10) Verdraengung und sauberes Nachladen.
case('10 Verdraengung', function()
    -- ClientCacheSeconds 45 / segSec 15 = drei Segmente Platz.
    fresh({ { hash = H1 } }, { ClientCacheSeconds = 45 })
    seek(H1, 95)          -- Abspielkopf in Segment 6

    local data = {}
    for seg = 4, 7 do
        data[seg] = evData(seg * SEGSEC, { 0, 500, 500 })
    end

    for seg = 4, 7 do
        ok(Segments.Request(seg), 'Anforderung ' .. seg)
        send(seg, lastRid(seg), { item('ev', H1, seg * SEGSEC, data[seg]) },
             true, { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 0 } },
                     missing = 0 })
        pump()
    end

    local p = Segments.Player(H1)
    local lo, hi = Segments.Window()
    eq(lo, 5, 'unteres Fensterende nach der Verdraengung')
    eq(hi, 7, 'oberes Fensterende')
    ok(not Segments.Has(4), 'Segment 4 verdraengt')
    eq(p.cnt[4], nil, 'cnt[4] weg')
    eq(p.n, 9, 'Samples des verdraengten Segments raus')

    -- Kopf zurueck auf Segment 5, damit die Verdraengung beim Nachladen am
    -- oberen Ende greift und das gerade Geholte nicht sofort wieder wirft.
    seek(H1, 80)

    eq(Segments.Request(4), true, 'verdraengtes Segment wieder anforderbar')
    send(4, lastRid(4), { item('ev', H1, 4 * SEGSEC, data[4]) }, true,
         { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(4), 'ok', 'laedt wieder sauber')
    eq(p.cnt[4], 3, 'Chunk nicht als Dublette verworfen')
    eq(p.n, 9, 'drei Segmente im Fenster')
    lo, hi = Segments.Window()
    eq(lo, 4, 'Fenster nach vorn erweitert')
    eq(hi, 6, 'oberes Ende verdraengt')
    rising(p, 'Zeitspalte')
    near(p.sT[1], 60.0, 'vorangestelltes Segment liegt vorn')
end)

-- 11) Zeitablauf mitten in der Lieferung.
case('11 Zeitablauf', function()
    fresh({ { hash = H1 } })
    seek(H1, 65)

    local a = evData(60, { 0, 500, 500 })
    local b = evData(65, { 0, 500, 500 })

    ok(Segments.Request(4), 'erste Anforderung')
    send(4, lastRid(4), { item('ev', H1, 60, a) }, false)
    pump(1)

    TIME = TIME + 25000
    pump(1)
    eq(Segments.SegState(4), nil, 'Anforderung freigegeben')
    eq(Segments.Player(H1).n, 0, 'halbe Lieferung nicht dekodiert')

    eq(Segments.Request(4), true, 'Wiederholung moeglich')
    send(4, lastRid(4), { item('ev', H1, 60, a) }, false)
    send(4, lastRid(4), { item('ev', H1, 65, b) }, true,
         { sent = { [tostring(H1)] = { ev = 2, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    local p = Segments.Player(H1)
    eq(Segments.SegState(4), 'ok', 'Wiederholung vollstaendig')
    eq(p.n, 6, 'keine Dopplung durch den ersten Versuch')
    eq(p.cnt[4], 6, 'cnt[4] stimmt')
    rising(p, 'Zeitspalte')
end)

-- 12) barsUnknown: SampleAt liefert nie 'gap'.
case('12 barsUnknown', function()
    -- H1 kennt sein Band, H2 nicht (volles Band, Index unbrauchbar), H3 gar
    -- nichts. Alle drei bekommen dieselben Daten mit einer echten Luecke.
    -- H1s Band ist EHRLICH: Segment 5 wird gleich leer ausgeliefert, also
    -- sagt das Band dort auch nichts zu ('.' an Position 6 = Segment 5).
    -- Mit einem Band, das 'b' verspricht und nichts liefert, meldet der Client
    -- voellig zu Recht 'unvollstaendig' statt 'war nicht da' — das ist der
    -- Widerspruch, den ein Server nie erzeugen wuerde.
    fresh({ { hash = H1, bars = 'bbbbb.bbbb' },
            { hash = H2, unknown = true },
            { hash = H3, unknown = true, bars = '' } })
    seek(H1, 65)

    local a = evData(60, { 0, 500, 500 })    -- 60.0 .. 61.0
    local b = evData(70, { 0, 500, 500 })    -- 70.0 .. 71.0  → Luecke 9 s

    local items = {}
    for _, h in ipairs({ H1, H2, H3 }) do
        items[#items + 1] = item('ev', h, 60, a)
        items[#items + 1] = item('ev', h, 70, b)
    end
    local sent = {}
    for _, h in ipairs({ H1, H2, H3 }) do
        sent[tostring(h)] = { ev = 2, fid = 0, open = 0 }
    end

    ok(Segments.Request(4), 'Anforderung 4')
    send(4, lastRid(4), items, true, { sent = sent, missing = 0 })
    pump()
    -- Segment 5 leer, damit edgeKnown hinter dem letzten Zustand greift.
    ok(Segments.Request(5), 'Anforderung 5')
    send(5, lastRid(5), {}, true, { sent = {}, missing = 0 })
    pump()

    eq(Segments.SegState(4), 'ok', 'Segment 4 vollstaendig')

    -- Der Spieler MIT Band meldet die Luecke — sonst prueft der Rest nichts.
    local _, _, _, s1 = Segments.SampleAt(H1, 65.0)
    eq(s1, 'gap', 'bekanntes Band meldet die Luecke')
    local _, _, _, s1b = Segments.SampleAt(H1, 74.0)
    eq(s1b, 'gap', 'bekanntes Band meldet das Ende')

    -- Ueber das ganze Band: fuer die beiden unbekannten NIE 'gap'.
    local seenStale2, seenStale3, bad = false, false, nil
    local t = 0.0
    while t <= 150.0 do
        local _, _, _, s2 = Segments.SampleAt(H2, t)
        local _, _, _, s3 = Segments.SampleAt(H3, t)
        if s2 == 'gap' then bad = bad or ('H2 bei t=' .. t) end
        if s3 == 'gap' then bad = bad or ('H3 bei t=' .. t) end
        if s2 == 'stale' then seenStale2 = true end
        if s3 == 'stale' then seenStale3 = true end
        t = t + 0.5
    end
    eq(bad, nil, 'barsUnknown liefert nie gap')
    ok(seenStale2, 'H2 meldet stattdessen stale')
    ok(seenStale3, 'H3 meldet stattdessen stale')

    -- Und punktgenau an der Luecke, an der H1 'gap' sagt.
    local _, _, _, g2 = Segments.SampleAt(H2, 65.0)
    eq(g2, 'stale', 'in der Luecke stale statt gap')
end)

-- 13) Der Platz des offenen Chunks gehoert einem FRUEHEREN Segment und wird
--     freigegeben, ohne dass die abgeschlossene Fassung je nachkommt: der
--     Recorder schliesst einen Chunk an der Segmentgrenze ab, die Lieferung
--     eines spaeteren Segments traegt ihn also nie. Was verschwindet, MUSS am
--     Vermerk zu sehen sein — sonst behauptet die Ladespur Vollstaendigkeit und
--     SampleAt meldet eine Abwesenheit, die es nie gab.
case('13 Platz eines frueheren Segments', function()
    fresh({ { hash = H1 } }, { ClientCacheSeconds = 45 })
    seek(H1, 65)

    local c1 = evData(60, { 0, 500, 500 })          -- 60.0 60.5 61.0
    local o1 = evData(62, { 0, 500, 500 })          -- 62.0 62.5 63.0 (Anfang)
    local o2 = evData(75, { 0, 500, 500 })          -- 75.0 75.5 76.0

    ok(Segments.Request(4), 'Anforderung 4')
    send(4, lastRid(4), { item('ev', H1, 60, c1), item('evopen', H1, 62, o1) },
         true, { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 1 } },
                 missing = 0 })
    pump()
    eq(Segments.SegState(4), 'ok', 'Segment 4 zunaechst vollstaendig')

    ok(Segments.Request(5), 'Anforderung 5')
    send(5, lastRid(5), { item('evopen', H1, 75, o2) }, true,
         { sent = { [tostring(H1)] = { ev = 0, fid = 0, open = 1 } },
           missing = 0 })
    pump()

    local p = Segments.Player(H1)
    eq(Segments.SegState(5), 'ok', 'Segment 5 vollstaendig')
    eq(Segments.SegState(4), 'part', 'Segment 4 nicht mehr vollstaendig')
    eq(p.cnt[4], 3, 'cnt[4] zaehlt genau das, was noch liegt')
    eq(p.cnt[5], 3, 'cnt[5] zaehlt den neuen Platz')
    eq(p.n, 6, 'Arrays halten genau beide Reste')
    rising(p, 'Zeitspalte')

    local _, _, _, s = Segments.SampleAt(H1, 63.5)
    eq(s, 'stale', 'fehlendes Material ist kein Beweis fuer Abwesenheit')

    -- Verdraengung am unteren Ende: nimmt sie genau die drei Samples mit?
    seek(H1, 108)
    for seg = 6, 7 do
        local d = evData(seg * SEGSEC, { 0, 500, 500 })
        ok(Segments.Request(seg), 'Anforderung ' .. seg)
        send(seg, lastRid(seg), { item('ev', H1, seg * SEGSEC, d) }, true,
             { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 0 } },
               missing = 0 })
        pump()
    end
    local lo, hi = Segments.Window()
    eq(lo, 5, 'Segment 4 verdraengt')
    eq(hi, 7, 'oberes Fensterende')
    eq(p.cnt[4], nil, 'cnt[4] weg')
    eq(p.miss[4], nil, 'Vermerk faellt mit seinem Segment')
    eq(p.n, 9, 'genau die drei Samples von Segment 4 sind raus')
    near(p.sT[1], 75.0, 'Fenster beginnt bei Segment 5')
    rising(p, 'nach der Verdraengung')
end)

-- 14) Ausrichtung: kein Chunk reicht ueber sein Segment hinaus.
case('14 Ausrichtung: ein Chunk, ein Segment', function()
    fresh({ { hash = H1 } })
    seek(H1, 4 * SEGSEC + 7)
    local p = Segments.Player(H1)

    for seg = 4, 7 do deliverFull(seg) end

    for seg = 4, 7 do
        eq(Segments.SegState(seg), 'ok', 'Segment ' .. seg .. ' vollstaendig')
        eq(p.cnt[seg], FULL_N, 'cnt[' .. seg .. ']')
    end
    eq(p.n, 4 * FULL_N, 'jeder Chunk genau einmal in den Arrays')
    layout(p, 'volle Segmente')
    bookedHasData(p, 'volle Segmente')
    rising(p, 'Zeitspalte')

    -- Die Naht zwischen zwei Chunks. Reichte einer ueber seine Grenze, laege
    -- hier entweder eine Dopplung (fallende Zeitspalte) oder ein Loch.
    near(p.sT[FULL_N], 5 * SEGSEC - 0.1, 'letzter Zustand vor der Grenze')
    near(p.sT[FULL_N + 1], 5 * SEGSEC, 'erster Zustand hinter der Grenze')

    local i1, i2, frac, st = Segments.SampleAt(H1, 5 * SEGSEC - 0.05)
    eq(st, 'ok', 'ueber die Segmentnaht wird interpoliert')
    eq(i1, FULL_N, 'linker Nachbar ist der letzte Zustand davor')
    eq(i2, FULL_N + 1, 'rechter Nachbar der erste danach')
    near(frac, 0.5, 'Anteil zwischen beiden')
end)

-- 15) Verdraengung mit vollen Segmenten. Der Abspielkopf wandert, die
--     Verdraengung greift viermal — und JEDES Segment des Bandes ist danach
--     entweder gebucht UND belegt oder gar nicht gebucht.
case('15 Verdraengung mit vollen Segmenten', function()
    fresh({ { hash = H1 } }, { ClientCacheSeconds = 45 })   -- drei Segmente
    local p = Segments.Player(H1)

    for seg = 4, 9 do
        seek(H1, seg * SEGSEC + 7)      -- der Kopf wandert mit
        deliverFull(seg)
        local at = 'nach Segment ' .. seg
        layout(p, at)
        bookedHasData(p, at)
        rising(p, at)
        local lo, hi = Segments.Window()
        ok(lo and (hi - lo + 1) <= 3, at .. ': Fenster bleibt bei drei (' ..
           tostring(lo) .. '..' .. tostring(hi) .. ')')
    end

    local lo, hi = Segments.Window()
    eq(lo, 7, 'unteres Fensterende')
    eq(hi, 9, 'oberes Fensterende')
    eq(p.n, 3 * FULL_N, 'genau drei volle Segmente im Speicher')
    for seg = 4, 6 do
        eq(Segments.SegState(seg), nil, 'Segment ' .. seg .. ' ist verdraengt')
        eq(p.cnt[seg], nil, 'cnt[' .. seg .. '] weg')
    end
end)

-- 16) Das verdraengte Segment ist wieder anforderbar und laedt sauber nach.
case('16 Nachladen nach der Verdraengung', function()
    fresh({ { hash = H1 } }, { ClientCacheSeconds = 45 })
    local p = Segments.Player(H1)
    for seg = 4, 9 do seek(H1, seg * SEGSEC + 7) deliverFull(seg) end

    eq(Segments.SegState(6), nil, 'Ausgangslage: Segment 6 ist verdraengt')
    eq(p.cnt[6], nil, 'und haelt nichts mehr')

    -- Kopf zurueck, damit die Verdraengung am OBEREN Ende greift und das gerade
    -- Geholte nicht sofort wieder wegwirft.
    seek(H1, 7 * SEGSEC + 7)
    deliverFull(6)

    eq(Segments.SegState(6), 'ok', 'laedt wieder vollstaendig')
    eq(p.cnt[6], FULL_N, 'Chunk nicht als Dublette verworfen')
    local lo, hi = Segments.Window()
    eq(lo, 6, 'Fenster nach vorn erweitert')
    eq(hi, 8, 'oberes Ende verdraengt')
    eq(p.n, 3 * FULL_N, 'weiterhin drei volle Segmente')
    eq(Segments.SegState(9), nil, 'das obere Ende ist nicht mehr gebucht')
    layout(p, 'nach dem Nachladen')
    bookedHasData(p, 'nach dem Nachladen')
    rising(p, 'nach dem Nachladen')
    near(p.sT[1], 6 * SEGSEC, 'das nachgeladene Segment liegt vorn')
end)

-- 17) Coverage behauptet nach der Verdraengung keine Lueckenlosigkeit mehr.
case('17 Coverage nach der Verdraengung', function()
    fresh({ { hash = H1 } }, { ClientCacheSeconds = 45 })
    for seg = 4, 9 do seek(H1, seg * SEGSEC + 7) deliverFull(seg) end

    local ev, fid, total, bad, cap = Segments.Coverage(4, 9)
    eq(total, 6, 'sechs Segmente im Bereich')
    eq(ev, 3, 'nur das Fenster gilt als geliefert')
    eq(fid, 3, 'derselbe Massstab fuer den zweiten Strom')
    eq(bad, 0, 'kein Fehlschlag')
    eq(cap, 0, 'kein Deckel')
    ok(ev < total, 'Coverage meldet nicht mehr lueckenlos')

    local ev2, _, total2 = Segments.Coverage(0, 9)
    eq(total2, 10, 'ueber das ganze Band')
    eq(ev2, 3, 'auch dort zaehlt nur das Fenster')
end)

-- 18) Der Platz des offenen Chunks bekommt keinen Nachfolger im eigenen
--     Segment: die abgeschlossene, laengere Fassung gehoert Segment 4 und kommt
--     mit KEINER spaeteren Lieferung nach. Segment 5 bringt einen ganz anderen
--     Chunk und schiebt sich damit HINTER den Platz. Wer den Platz danach noch
--     fuer das Ende der Arrays haelt, schneidet beim naechsten offenen Chunk
--     fremdes Material heraus — Segment 5 bliebe 'ok' und haette keinen
--     einzigen Zustand mehr.
case('18 Platz ohne Nachfolger im eigenen Segment', function()
    fresh({ { hash = H1 } }, { ClientCacheSeconds = 90 })
    seek(H1, 65)
    local p = Segments.Player(H1)

    local c1 = evData(60, { 0, 500, 500 })    -- 60.0 60.5 61.0  Segment 4
    local o1 = evData(62, { 0, 500, 500 })    -- 62.0 62.5 63.0  offen, Segment 4
    local c2 = evData(75, { 0, 500, 500 })    -- 75.0 75.5 76.0  Segment 5
    local o2 = evData(92, { 0, 500, 500 })    -- 92.0 92.5 93.0  offen, Segment 6

    ok(Segments.Request(4), 'Anforderung 4')
    send(4, lastRid(4), { item('ev', H1, 60, c1), item('evopen', H1, 62, o1) },
         true, { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 1 } },
                 missing = 0 })
    pump()
    eq(Segments.SegState(4), 'ok', 'Segment 4 zunaechst vollstaendig')

    ok(Segments.Request(5), 'Anforderung 5')
    send(5, lastRid(5), { item('ev', H1, 75, c2) }, true,
         { sent = { [tostring(H1)] = { ev = 1, fid = 0, open = 0 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(5), 'ok', 'Segment 5 vollstaendig')
    eq(Segments.SegState(4), 'part', 'der Rest des offenen Chunks kommt nie nach')
    eq(p.cnt[4], 6, 'Segment 4 behaelt seinen Anfang')
    eq(p.cnt[5], 3, 'Segment 5 haelt seinen Chunk')
    eq(p.n, 9, 'nichts verloren')
    layout(p, 'nach Segment 5')

    local _, _, _, s4 = Segments.SampleAt(H1, 63.5)
    eq(s4, 'stale', 'die fehlende Fortsetzung ist kein Beweis fuer Abwesenheit')

    -- Der neue offene Chunk darf NUR seinen eigenen Platz anlegen.
    seek(H1, 95)
    ok(Segments.Request(6), 'Anforderung 6')
    send(6, lastRid(6), { item('evopen', H1, 92, o2) }, true,
         { sent = { [tostring(H1)] = { ev = 0, fid = 0, open = 1 } },
           missing = 0 })
    pump()

    eq(Segments.SegState(6), 'ok', 'Segment 6 vollstaendig')
    eq(p.n, 12, 'der neue Platz nimmt kein fremdes Material mit')
    eq(p.cnt[4], 6, 'Segment 4 unveraendert')
    eq(p.cnt[5], 3, 'Segment 5 haelt seine Zustaende weiter')
    eq(p.cnt[6], 3, 'Segment 6 haelt den Platz')
    layout(p, 'nach Segment 6')
    bookedHasData(p, 'nach Segment 6')
    rising(p, 'nach Segment 6')

    local _, _, _, s5 = Segments.SampleAt(H1, 75.5)
    eq(s5, 'ok', 'Segment 5 ist gebucht UND liefert Zustaende')
end)

-- ── Lauf ───────────────────────────────────────────────────────────────────

local path = findModule()
local chunk = assert(loadfile(path))
Segments = chunk()
assert(type(Segments) == 'table' and Segments.Pump, 'Modul nicht geladen')

local passed = 0
for i = 1, #cases do
    CASE = cases[i].name
    local before = #FAILS
    local okRun, err = pcall(cases[i].fn)
    if not okRun then fail('Ausnahme: ' .. tostring(err)) end
    if #FAILS == before then passed = passed + 1 end
end

if #FAILS == 0 then
    io.write(string.format('OK %d/%d\n', passed, #cases))
    os.exit(0)
end

io.write(string.format('FEHLSCHLAEGE %d/%d bestanden\n', passed, #cases))
for i = 1, #FAILS do io.write('  - ' .. FAILS[i] .. '\n') end
os.exit(1)
