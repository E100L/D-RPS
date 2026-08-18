--[[ ===========================================================================
    D-RPS — Pruefstand fuer die WELTSPUR (client/world.lua)

    Laeuft mit plain lua5.4, ohne Netz und ohne Spiel:
        ssh drps "cd <resource> && lua5.4 -" < _test/world_spec.lua

    Anders als der Pruefstand fuer segments.lua benutzt dieser das ECHTE
    Binaerformat: shared/protocol.lua wird geladen, und die Chunks werden genau
    so gebaut, wie server/vehicles.lua sie baut. Genau darum geht es hier —
    Kodierer und Dekodierer der Weltspur sind zwei Fassungen derselben
    Feldreihenfolge, und ein Auseinanderlaufen faellt im Spiel nur als
    "Fahrzeuge stehen falsch" auf, ohne jede Meldung.

    Geprueft wird:
      1. Mehrere Fahrzeuge in EINER Lieferung, getrennt nach Chunk-Kopf
      2. Stillstandsregel des Aufzeichners (Feldmaske 0)
      3. Zeitrechnung ueber uebersprungene Samples hinweg
      4. Ersetzen statt Anhaengen bei erneuter Lieferung
      5. Haltefrist nach dem letzten Sample (Herzschlag)
      6. Fortsetzung im Folgesegment
      7. Auswahl nach Abstand und Deckel
      8. Verdraengung ueber World.Keep
=========================================================================== ]]

-- ── Module finden ──────────────────────────────────────────────────────────

--- Kandidaten der Reihe nach probieren. Bewusst mit einem Zaehler und nicht
--- mit ipairs: ein nicht gesetztes DRPS_* waere ein nil an erster Stelle, und
--- ipairs bricht dort ab, statt weiterzusuchen.
local function find(names)
    for i = 1, names.n do
        local p = names[i]
        if p then
            local f = io.open(p, 'rb')
            if f then f:close() return p end
        end
    end
    return nil
end

local PROTO = find(table.pack(os.getenv('DRPS_PROTOCOL'), 'shared/protocol.lua',
                              '../shared/protocol.lua', './protocol.lua'))
local WORLD = find(table.pack(os.getenv('DRPS_WORLD'), 'client/world.lua',
                              '../client/world.lua', './world.lua'))
if not PROTO or not WORLD then
    io.write('FEHLER: shared/protocol.lua oder client/world.lua nicht gefunden\n')
    os.exit(2)
end

-- ── Stubs ──────────────────────────────────────────────────────────────────

local TIME = 1000
function GetGameTimer() return TIME end

Config = {
    World = { Vehicles = true, HeartbeatMs = 5000 },
    Playback = { MaxWorldVehicles = 20 },
}

assert(loadfile(PROTO))()
assert(loadfile(WORLD))()

-- ── Kleine Pruefsprache ────────────────────────────────────────────────────

local pass, fail, failures = 0, 0, {}

local function ok(cond, what)
    if cond then pass = pass + 1
    else fail = fail + 1; failures[#failures + 1] = what end
end

local function near(a, b, eps, what)
    eps = eps or 0.02
    ok(a and math.abs(a - b) <= eps, ('%s (ist %s, soll %s)')
        :format(what, tostring(a), tostring(b)))
end

-- ── Chunks bauen — GENAU wie server/vehicles.lua ───────────────────────────

local EPOCH  = 1700000000
local SEGSEC = 30

--- Ein Fahrzeug-Sample. Die Feldbelegung entspricht readVeh().
local function vsample(x, y, z, h, speed)
    return {
        x = x, y = y, z = z, heading = h or 0.0,
        health = 200, armour = 0,
        flags = Protocol.FLAG.IS_VEHICLE | Protocol.FLAG.ALIVE,
        vehModel = 0x11111111, vehSeat = -1,
        camYaw = 0.0, camPitch = 0.0, moveBlend = 0.0,
        steer = 0.0, speed = speed or 0.0, vpitch = 0.0, vroll = 0.0,
    }
end

--- Einen Chunk aus einer Folge von { s = sample, dt = ms } bauen.
--- Die Stillstandsregel wird dabei nachgebildet: ein Delta mit Feldmaske 0
--- wird verworfen und sein dt dem naechsten geschriebenen Sample zugeschlagen.
--- Rueckgabe: Chunkstring, Zahl der GESCHRIEBENEN Samples.
--- `gone` haengt den Endmarker an, wie es server/vehicles.lua beim Verschwinden
--- eines Fahrzeugs tut: ein letzter Sample mit vehModel = 0.
local function buildChunk(key, startSec, startMs, steps, heartbeatMs, gone)
    heartbeatMs = heartbeatMs or 5000
    local parts, n, prev, acc = {}, 0, nil, 0

    for _, st in ipairs(steps) do
        if not prev then
            n = n + 1
            parts[n] = Protocol.EncodeKeyframe(st.s, 0)
            prev, acc = st.s, 0
        else
            acc = acc + st.dt
            local packed = Protocol.EncodeDelta(prev, st.s, acc)
            local _, mask = string.unpack('<I2I2', packed)
            if mask ~= 0 or acc >= heartbeatMs then
                n = n + 1
                parts[n] = packed
                prev, acc = st.s, 0
            end
        end
    end

    if gone and prev then
        local last = {}
        for k, v in pairs(prev) do last[k] = v end
        last.vehModel = 0
        n = n + 1
        parts[n] = (Protocol.EncodeDelta(prev, last,
                        type(gone) == 'number' and gone or 0))
    end

    local head = Protocol.EncodeChunkHeader(startSec, startMs, key, n)
    return head .. table.concat(parts, '', 1, n), n
end

--- Eine Lieferung, wie sie der Server schickt: mehrere Chunks in einem Paket.
local function delivery(seg, chunks)
    return { seg = seg, items = { { kind = 'world', data = table.concat(chunks) } } }
end

local function feed(seg, chunks)
    World.Intake(delivery(seg, chunks))
    TIME = TIME + 1
    World.Pump(1000)          -- grosszuegiges Budget: alles in einem Zug
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Mehrere Fahrzeuge in EINER Lieferung
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)

    -- Segment 10 beginnt bei EPOCH + 300.
    local base = EPOCH + 10 * SEGSEC

    -- A faehrt: 5 Samples im Sekundenabstand entlang X.
    local stepsA = {}
    for i = 0, 4 do
        stepsA[#stepsA + 1] = { s = vsample(100.0 + i * 10.0, 200.0, 30.0, 90.0, 10.0),
                                dt = 1000 }
    end
    local cA, nA = buildChunk(0xAAAA1111, base, 0, stepsA)

    -- B steht: derselbe Zustand ueber 20 s. Nur Keyframe + Herzschlaege.
    local stepsB = {}
    for i = 0, 20 do
        stepsB[#stepsB + 1] = { s = vsample(500.0, 600.0, 25.0, 0.0, 0.0), dt = 1000 }
    end
    local cB, nB = buildChunk(0xBBBB2222, base, 0, stepsB)

    feed(10, { cA, cB })

    local s = World.Stats()
    ok(s.chunks == 2, 'zwei Chunks aus EINER Lieferung getrennt')
    ok(s.blocks == 2, 'zwei Bloecke angelegt')
    ok(nA == 5, ('A: alle 5 Samples geschrieben (ist %d)'):format(nA))
    -- 21 Schritte, davon der Keyframe plus ein Herzschlag alle 5 s: 5 Stueck.
    ok(nB <= 6, ('B im Stillstand kostet hoechstens 6 Samples (ist %d)'):format(nB))
    ok(nB >= 2, ('B bekommt Herzschlaege (ist %d)'):format(nB))

    -- Position von A bei t = 2,5 s nach Segmentbeginn → zwischen Sample 3 und 4
    local t = (base - EPOCH) + 2.5
    local n = World.Snapshot(t, 0.0, 0.0, 0.0, 10)
    ok(n == 2, ('beide Fahrzeuge sichtbar (ist %d)'):format(n))

    local seen = {}
    for i = 1, n do local e = World.Get(i); seen[e.key] = e end
    ok(seen[0xAAAA1111] ~= nil, 'A ueber seinen Schluessel auffindbar')
    ok(seen[0xBBBB2222] ~= nil, 'B ueber seinen Schluessel auffindbar')
    if seen[0xAAAA1111] then
        near(seen[0xAAAA1111].x, 125.0, 0.05, 'A interpoliert auf halbem Weg')
        ok(seen[0xAAAA1111].model == 0x11111111, 'Modell aus dem Sample uebernommen')
    end
    if seen[0xBBBB2222] then
        near(seen[0xBBBB2222].x, 500.0, 0.02, 'B steht, wo es stand')
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Stillstandsregel: identischer Zustand erzeugt Feldmaske 0
-- ═══════════════════════════════════════════════════════════════════════════
do
    local s1 = vsample(10.0, 20.0, 30.0, 45.0, 0.0)
    local s2 = vsample(10.0, 20.0, 30.0, 45.0, 0.0)
    local packed = (Protocol.EncodeDelta(s1, s2, 200))
    local dt, mask = string.unpack('<I2I2', packed)
    ok(mask == 0, ('unveraenderter Zustand ergibt Maske 0 (ist 0x%04X)'):format(mask))
    ok(dt == 200, 'dt bleibt erhalten')
    ok(#packed == 4, ('ein solcher Sample ist 4 Byte gross (ist %d)'):format(#packed))

    -- Und die Gegenprobe: 1 cm Bewegung MUSS ein Feld setzen.
    local s3 = vsample(10.01, 20.0, 30.0, 45.0, 0.0)
    local _, m3 = string.unpack('<I2I2', (Protocol.EncodeDelta(s1, s3, 200)))
    ok(m3 & Protocol.F.POS ~= 0, 'ein Zentimeter Bewegung setzt das Positionsfeld')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Zeitrechnung ueber uebersprungene Samples hinweg
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    local base = EPOCH + 20 * SEGSEC

    -- Steht 4 s still, faehrt dann los. Das dt des ersten Bewegungssamples
    -- muss die gesamte Stillstandszeit tragen.
    local steps = {
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 1000 },
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 1000 },
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 1000 },
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 1000 },
        { s = vsample(50.0, 0.0, 10.0, 0.0, 5.0), dt = 1000 },
    }
    local c, n = buildChunk(0xCCCC3333, base, 0, steps)
    ok(n == 2, ('vier stille Samples fallen weg, zwei bleiben (ist %d)'):format(n))

    feed(20, { c })

    -- Bei t = 0 steht es am Ursprung, bei t = 5 s am Ziel, bei 2,5 s auf halbem Weg.
    local t0 = base - EPOCH
    World.Snapshot(t0, 0, 0, 0, 5)
    near(World.Get(1) and World.Get(1).x, 0.0, 0.02, 'Startpunkt stimmt')

    World.Snapshot(t0 + 5.0, 0, 0, 0, 5)
    near(World.Get(1) and World.Get(1).x, 50.0, 0.05, 'Endpunkt nach 5 s stimmt')

    World.Snapshot(t0 + 2.5, 0, 0, 0, 5)
    near(World.Get(1) and World.Get(1).x, 25.0, 0.05,
         'auf halber Strecke — die verworfenen Samples haben ihr dt vererbt')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. Erneute Lieferung ERSETZT, sie haengt nicht an
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    local base = EPOCH + 30 * SEGSEC
    local key  = 0xDDDD4444

    local short = buildChunk(key, base, 0, {
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        { s = vsample(10.0, 0.0, 10.0, 0.0, 5.0), dt = 1000 },
    })
    feed(30, { short })
    ok(World.Stats().blocks == 1, 'ein Block nach der ersten Lieferung')

    -- Der offene Chunk waechst: dieselbe Startsekunde, mehr Samples.
    local long = buildChunk(key, base, 0, {
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        { s = vsample(10.0, 0.0, 10.0, 0.0, 5.0), dt = 1000 },
        { s = vsample(20.0, 0.0, 10.0, 0.0, 5.0), dt = 1000 },
        { s = vsample(30.0, 0.0, 10.0, 0.0, 5.0), dt = 1000 },
    })
    feed(30, { long })

    local s = World.Stats()
    ok(s.blocks == 1, ('immer noch EIN Block, nicht zwei (ist %d)'):format(s.blocks))

    local t0 = base - EPOCH
    World.Snapshot(t0 + 3.0, 0, 0, 0, 5)
    near(World.Get(1) and World.Get(1).x, 30.0, 0.05,
         'die laengere Fassung hat die kuerzere abgeloest')

    -- Und die Zeitspalte darf dabei nicht doppelt belegt sein: bei 1,5 s muss
    -- genau ein Wert herauskommen, nicht der einer angehaengten Dublette.
    World.Snapshot(t0 + 1.5, 0, 0, 0, 5)
    near(World.Get(1) and World.Get(1).x, 15.0, 0.05, 'keine Dublette in der Zeitspalte')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Haltefrist: nach dem letzten Sample gilt der Herzschlag
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    local base = EPOCH + 40 * SEGSEC

    -- Ein Fahrzeug, das nach 2 s verschwindet: der Chunk endet dort.
    local c = buildChunk(0xEEEE5555, base, 0, {
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        { s = vsample(5.0, 0.0, 10.0, 0.0, 2.0), dt = 2000 },
    })
    feed(40, { c })

    local t0 = base - EPOCH
    -- Haltefrist ist HeartbeatMs * 1,5 = 7,5 s.
    ok(World.Snapshot(t0 + 5.0, 0, 0, 0, 5) == 1,
       'innerhalb der Haltefrist noch sichtbar')
    ok(World.Snapshot(t0 + 12.0, 0, 0, 0, 5) == 0,
       'nach der Haltefrist verschwunden — kein Geisterwagen bis Segmentende')
    -- Vor dem ersten Sample darf es nicht zu sehen sein.
    ok(World.Snapshot(t0 - 1.0, 0, 0, 0, 5) == 0,
       'vor dem ersten Sample nicht sichtbar')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. Fortsetzung im Folgesegment haelt ueber die Grenze
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    local key   = 0xF00D6666
    local baseA = EPOCH + 50 * SEGSEC
    local baseB = EPOCH + 51 * SEGSEC

    -- In Segment 50 steht es ganz am Anfang und schweigt danach.
    local cA = buildChunk(key, baseA, 0, {
        { s = vsample(1.0, 1.0, 10.0, 0.0, 0.0), dt = 0 },
    })
    -- In Segment 51 geht es weiter — dasselbe Fahrzeug, derselbe Schluessel.
    local cB = buildChunk(key, baseB, 0, {
        { s = vsample(1.0, 1.0, 10.0, 0.0, 0.0), dt = 0 },
    })

    feed(50, { cA })
    local t0 = baseA - EPOCH
    ok(World.Snapshot(t0 + 20.0, 0, 0, 0, 5) == 0,
       'ohne Folgesegment greift die Haltefrist')

    feed(51, { cB })
    ok(World.Snapshot(t0 + 20.0, 0, 0, 0, 5) == 1,
       'mit Folgesegment bleibt es bis zur Grenze stehen')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. Auswahl nach Abstand und Deckel
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    local base = EPOCH + 60 * SEGSEC

    local chunks = {}
    for i = 1, 8 do
        chunks[#chunks + 1] = buildChunk(0x1000 + i, base, 0, {
            { s = vsample(i * 100.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        })
    end
    feed(60, chunks)
    ok(World.Stats().blocks == 8, 'acht Bloecke')

    local t0 = base - EPOCH
    local n = World.Snapshot(t0, 0.0, 0.0, 10.0, 3)
    ok(n == 3, ('Deckel greift: 3 von 8 (ist %d)'):format(n))

    -- Und zwar die NAECHSTEN drei, aufsteigend sortiert.
    local x1 = World.Get(1) and World.Get(1).x
    local x2 = World.Get(2) and World.Get(2).x
    local x3 = World.Get(3) and World.Get(3).x
    near(x1, 100.0, 0.05, 'naechstes zuerst')
    near(x2, 200.0, 0.05, 'zweitnaechstes danach')
    near(x3, 300.0, 0.05, 'drittnaechstes zuletzt')

    -- Bezugspunkt am anderen Ende: die Reihenfolge muss sich umkehren.
    World.Snapshot(t0, 900.0, 0.0, 10.0, 2)
    near(World.Get(1) and World.Get(1).x, 800.0, 0.05,
         'Auswahl folgt dem Bezugspunkt')

    -- Deckel 0 liefert nichts, ohne zu stolpern.
    ok(World.Snapshot(t0, 0.0, 0.0, 10.0, 0) == 0, 'Deckel 0 liefert nichts')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. Verdraengung
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    for seg = 70, 74 do
        local base = EPOCH + seg * SEGSEC
        feed(seg, { buildChunk(0x2000 + seg, base, 0, {
            { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        }) })
    end
    ok(World.Stats().segs == 5, 'fuenf Segmente im Speicher')

    World.Keep(72, 74)
    local s = World.Stats()
    ok(s.segs == 3, ('nach Keep(72,74) bleiben drei (ist %d)'):format(s.segs))
    ok(s.blocks == 3, ('und drei Bloecke (ist %d)'):format(s.blocks))

    local t70 = 70 * SEGSEC
    ok(World.Snapshot(t70, 0, 0, 0, 5) == 0, 'verdraengtes Segment liefert nichts')

    World.Clear()
    ok(World.Stats().segs == 0, 'Clear raeumt alles')
    ok(World.Snapshot(72 * SEGSEC, 0, 0, 0, 5) == 0, 'nach Clear ist nichts mehr da')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. Endmarker: das Fahrzeug ist WEG, nicht nur still
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)
    local base = EPOCH + 80 * SEGSEC
    local t0   = base - EPOCH

    -- Ohne Marker: nach dem letzten Sample gilt die Haltefrist (7,5 s).
    local ohne = buildChunk(0x9001, base, 0, {
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        { s = vsample(4.0, 0.0, 10.0, 0.0, 2.0), dt = 2000 },
    })
    feed(80, { ohne })
    ok(World.Snapshot(t0 + 5.0, 0, 0, 0, 5) == 1,
       'ohne Endmarker: innerhalb der Haltefrist sichtbar')

    -- Mit Marker: ab dem Markerzeitpunkt sofort weg.
    World.Reset(EPOCH, SEGSEC)
    local mit = buildChunk(0x9002, base, 0, {
        { s = vsample(0.0, 0.0, 10.0, 0.0, 0.0), dt = 0 },
        { s = vsample(4.0, 0.0, 10.0, 0.0, 2.0), dt = 2000 },
    }, 5000, 500)   -- Marker 0,5 s nach dem letzten Sample
    feed(80, { mit })

    ok(World.Snapshot(t0 + 1.0, 0, 0, 0, 5) == 1,
       'mit Endmarker: davor normal sichtbar')
    ok(World.Snapshot(t0 + 3.0, 0, 0, 0, 5) == 0,
       'mit Endmarker: ab dem Marker sofort weg, keine Haltefrist')
    ok(World.Snapshot(t0 + 5.0, 0, 0, 0, 5) == 0,
       'mit Endmarker: bleibt weg')

    -- Und das Modell darf der Marker NICHT ueberschreiben — er traegt 0.
    World.Snapshot(t0 + 1.0, 0, 0, 0, 5)
    local e = World.Get(1)
    ok(e and e.model == 0x11111111,
       ('Modell stammt aus dem ersten Sample, nicht aus dem Marker (ist %s)')
           :format(e and ('0x%08X'):format(e.model) or 'nil'))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. Es wird nichts mehr verworfen — auch nicht ausserhalb des Fensters
-- ═══════════════════════════════════════════════════════════════════════════
do
    World.Reset(EPOCH, SEGSEC)

    -- Das Fenster steht auf einem Bereich; die Lieferung gehoert zum naechsten.
    -- Frueher fiel sie hier heraus, und weil ein geliefertes Segment nie erneut
    -- angefordert wird, war sie damit endgueltig verloren.
    World.Keep(90, 92)
    local base = EPOCH + 93 * SEGSEC
    feed(93, { buildChunk(0x9003, base, 0, {
        { s = vsample(7.0, 7.0, 10.0, 0.0, 0.0), dt = 0 },
    }) })

    ok(World.Stats().blocks == 1,
       'Lieferung ausserhalb des alten Fensters wird angenommen, nicht verworfen')
    ok(World.Snapshot(93 * SEGSEC, 0, 0, 0, 5) == 1,
       'und ist danach abrufbar')

    -- Keep raeumt sie ordentlich ab, sobald das Fenster wirklich weiterrueckt.
    World.Keep(95, 97)
    ok(World.Stats().segs == 0, 'Keep raeumt weiterhin zuverlaessig auf')
end

-- ── Ergebnis ───────────────────────────────────────────────────────────────

io.write(('\n%d bestanden, %d gescheitert\n'):format(pass, fail))
for _, f in ipairs(failures) do io.write('  FEHLER: ' .. f .. '\n') end
os.exit(fail == 0 and 0 or 1)
